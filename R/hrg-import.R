#' Import NHS England HRG4+ logic tables from a "Code to Group" workbook
#'
#' NHS England publishes, with every HRG4+ grouper release, a *Code to Group*
#' Excel workbook holding the reference data that drives grouping: the HRG
#' catalogue, which codes trigger which subchapters and map to which HRG
#' roots (`Code To Group`), how roots split into final HRGs (`Group To
#' Split`), the formal definition of every condition flag (`Simple Flags`),
#' and the code lists those flags refer to (CC, hierarchy, combination,
#' global and other lists). This function parses the workbook into tidy
#' tables for the opendrg engine.
#'
#' @param path Path to the `... Code To Group ... .xlsx` workbook.
#' @param version Version label, e.g. `"2024-25-nc"` (National Costs 2024/25).
#' @return A named list of tibbles with class `hrg_tables`.
#' @export
#' @examples
#' \dontrun{
#' tbls <- hrg_import_code_to_group("HRG4 202425 National Costs Grouper Code To Group v1.0.xlsx",
#'                                  version = "2024-25-nc")
#' }
hrg_import_code_to_group <- function(path, version) {
  rlang::check_installed("readxl", reason = "to read the Code to Group workbook")
  stopifnot(is.character(path), length(path) == 1, file.exists(path))
  stopifnot(is.character(version), length(version) == 1)

  sheets <- readxl::excel_sheets(path)
  required <- c("HRG & Subchapters", "Code To Group", "Group To Split", "Documentation Flags",
                "Simple Flags", "Hierarchy Lists", "Other Lists", "CC Lists", "Global Lists",
                "Combination Lists", "Combination Code", "Reference Data", "PBC Mappings")
  missing <- setdiff(required, sheets)
  if (length(missing) > 0) {
    cli::cli_abort("Workbook is missing sheet{?s} {.val {missing}}.")
  }
  rd <- function(sheet) {
    df <- readxl::read_excel(path, sheet = sheet, col_types = "text", .name_repair = "minimal")
    names(df) <- trimws(gsub("[\r\n]+", " ", names(df)))
    tibble::as_tibble(df, .name_repair = "minimal")
  }
  clean <- function(x) {
    x <- trimws(as.character(x))
    x[!is.na(x) & x == ""] <- NA_character_
    x
  }
  # "HRG 1, Flag 1, HRG 2, Flag 2, ..." pairs to long format.
  pairs_long <- function(df, id_cols, value_prefix, out_name) {
    n <- sum(grepl(paste0("^", value_prefix, " [0-9]+$"), names(df)))
    purrr::map(seq_len(n), function(i) {
      value <- clean(df[[paste(value_prefix, i)]])
      tibble::tibble(df[id_cols], rank = i, !!out_name := value, flag = clean(df[[paste("Flag", i)]])) |>
        dplyr::filter(!is.na(.data[[out_name]]))
    }) |>
      purrr::list_rbind() |>
      dplyr::arrange(dplyr::across(dplyr::all_of(c(id_cols, "rank"))))
  }

  # --- HRG catalogue ----------------------------------------------------------
  cat_raw <- rd("HRG & Subchapters")
  names(cat_raw)[1] <- "HRG"
  names(cat_raw) <- sub(" Total = [0-9]+$", "", names(cat_raw))
  hrgs <- cat_raw |>
    dplyr::transmute(
      hrg = clean(.data$HRG),
      description = clean(.data[["HRG Description"]]),
      core = clean(.data[["Core or Unbundled?"]]),
      subchapter = clean(.data[["HRG Subchapter"]]),
      subchapter_description = clean(.data[["HRG Subchapter Description"]]),
      chapter = clean(.data[["HRG Chapter"]]),
      chapter_description = clean(.data[["HRG Chapter Description"]])
    ) |>
    dplyr::filter(!is.na(.data$hrg))

  # --- Code To Group ----------------------------------------------------------
  c2g_raw <- rd("Code To Group")
  first_meta <- match("Code to Group Type", names(c2g_raw))
  subchapter_cols <- names(c2g_raw)[seq_len(first_meta - 1)]
  c2g_raw$row_id <- seq_len(nrow(c2g_raw))
  code_to_group <- c2g_raw |>
    dplyr::transmute(
      row_id = .data$row_id,
      type = clean(.data[["Code to Group Type"]]),
      code_type = clean(.data[["Code Type"]]),
      code = clean(.data$Code),
      description = clean(.data[["Code Description"]])
    )
  code_to_group_triggers <- c2g_raw |>
    dplyr::select("row_id", dplyr::all_of(subchapter_cols)) |>
    tidyr::pivot_longer(-"row_id", names_to = "subchapter", values_to = "flag") |>
    dplyr::filter(!is.na(.data$flag), .data$flag != "") |>
    dplyr::select("row_id", "subchapter")
  code_to_group_hrgs <- pairs_long(c2g_raw, "row_id", "HRG", "hrg")

  # --- Group To Split ---------------------------------------------------------
  g2s_raw <- rd("Group To Split")
  group_to_split <- g2s_raw |>
    dplyr::transmute(root = clean(.data[["HRG Root"]]), description = clean(.data[["HRG Root Description"]])) |>
    dplyr::filter(!is.na(.data$root))
  g2s_raw$root <- clean(g2s_raw[["HRG Root"]])
  group_to_split_hrgs <- pairs_long(g2s_raw |> dplyr::filter(!is.na(.data$root)), "root", "HRG", "hrg")

  # --- Flags ------------------------------------------------------------------
  flags <- rd("Documentation Flags") |>
    dplyr::transmute(
      chapter = clean(.data[["HRG Chapter"]]),
      subchapter = clean(.data[["HRG Sub Chapter"]]),
      flag = clean(.data[["Documentation Flag ID"]]),
      description = clean(.data[["Doc Flag description"]])
    ) |>
    dplyr::filter(!is.na(.data$flag))
  flag_rules <- rd("Simple Flags") |>
    dplyr::transmute(
      chapter = clean(.data[["HRG Chapter"]]),
      subchapter = clean(.data[["HRG Subchapter"]]),
      flag = clean(.data[["Documentation Flag ID"]]),
      order = as.integer(.data[["Flag Order"]]),
      fn = clean(.data[["Function ID"]]),
      data_item = clean(.data[["DataItem ID"]]),
      pos_min = as.integer(.data[["DataItem Order Min"]]),
      pos_max = as.integer(.data[["DataItem Order Max"]]),
      list_id = clean(.data[["List ID"]]),
      sum_min = as.numeric(.data[["Code Value Sum Min"]])
    ) |>
    dplyr::filter(!is.na(.data$flag)) |>
    dplyr::arrange(.data$flag, .data$order)

  # --- Lists ------------------------------------------------------------------
  list_sheet <- function(sheet, kind, value_col = NULL) {
    df <- rd(sheet)
    tibble::tibble(
      kind = kind,
      list_id = clean(df[["List ID"]]),
      code_type = clean(df[["Code Type"]]),
      code = clean(df$Code),
      value = if (is.null(value_col)) NA_real_ else suppressWarnings(as.numeric(df[[value_col]])),
      description = clean(df[["Code Description"]])
    ) |>
      dplyr::filter(!is.na(.data$list_id), !is.na(.data$code))
  }
  lists <- dplyr::bind_rows(
    list_sheet("CC Lists", "cc", "Value"),
    list_sheet("Hierarchy Lists", "hierarchy", "Hierarchy Value"),
    list_sheet("Other Lists", "other", "Value"),
    list_sheet("Global Lists", "global"),
    list_sheet("Combination Lists", "combination")
  )

  # --- Combination codes ------------------------------------------------------
  cc_raw <- rd("Combination Code")
  names(cc_raw) <- make.unique(names(cc_raw), sep = "_")
  combination_codes <- cc_raw |>
    dplyr::transmute(
      combination_code = clean(.data[["Combination Code"]]),
      description = clean(.data[["Combination Code Description"]]),
      order = as.integer(.data[["Combination Code Order"]]),
      driving_code = clean(.data[["Driving Code"]]),
      qualifier_type_1 = clean(.data[["Qualifier Type 1"]]),
      qualifying_code_1 = clean(.data[["Qualifying Code 1"]]),
      qualifier_type_2 = clean(.data[["Qualifier Type 2"]]),
      qualifying_code_2 = clean(.data[["Qualifying Code 2"]])
    ) |>
    dplyr::filter(!is.na(.data$combination_code))

  # --- PBC, reference data, code catalogues -----------------------------------
  pbc_raw <- rd("PBC Mappings")
  pbc_raw$row_id <- seq_len(nrow(pbc_raw))
  pbc_mappings <- pbc_raw |>
    dplyr::transmute(row_id = .data$row_id, type = clean(.data[["Code to Group Type"]]),
                     code_type = clean(.data[["Code Type"]]), code = clean(.data$Code)) |>
    dplyr::inner_join(pairs_long(pbc_raw, "row_id", "PBC", "pbc"), by = "row_id") |>
    dplyr::select(-"row_id")

  reference_data <- rd("Reference Data")
  reference_data <- tibble::tibble(
    field = clean(reference_data[["Grouper Field Name"]]),
    description = clean(reference_data$Description),
    code = clean(reference_data$Code),
    module = clean(reference_data[[grep("^Relates to Grouper Module", names(reference_data))[1]]]),
    code_description = clean(reference_data[["Code Description"]])
  ) |>
    dplyr::filter(!is.na(.data$field))

  code_catalogue <- function(sheet, code_col) {
    df <- rd(sheet)
    tibble::tibble(code = clean(df[[code_col]]), description = clean(df[[2]]), introduced = clean(df[[3]])) |>
      dplyr::filter(!is.na(.data$code))
  }
  opcs <- if ("OPCS" %in% sheets) code_catalogue("OPCS", "OPCS Code") else NULL
  icd10 <- if ("ICD-10" %in% sheets) code_catalogue("ICD-10", "ICD-10 Code") else NULL

  structure(
    list(
      version = version,
      hrgs = hrgs,
      code_to_group = code_to_group,
      code_to_group_triggers = code_to_group_triggers,
      code_to_group_hrgs = code_to_group_hrgs,
      group_to_split = group_to_split,
      group_to_split_hrgs = group_to_split_hrgs,
      flags = flags,
      flag_rules = flag_rules,
      lists = lists,
      combination_codes = combination_codes,
      pbc_mappings = pbc_mappings,
      reference_data = reference_data,
      opcs = opcs,
      icd10 = icd10
    ),
    class = "hrg_tables"
  )
}

#' @export
print.hrg_tables <- function(x, ...) {
  cat(sprintf("<hrg_tables> version %s\n", x$version))
  tables <- Filter(is.data.frame, x)
  counts <- vapply(tables, nrow, integer(1))
  cat(sprintf("  %-24s %s\n", names(counts), format(counts, big.mark = ",")), sep = "")
  invisible(x)
}
