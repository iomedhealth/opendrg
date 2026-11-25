#' Import the NHS England Prescribed Specialised Services identification rules
#'
#' NHS England publishes, with every release of the Prescribed Specialised
#' Services Operational Tool (PSO), a *Guide to Identification Rules*
#' workbook. Its `Code Sets` sheet lists, for every service line and
#' identification rule, the lists of trigger codes (ICD-10, OPCS-4, provider,
#' specialty, age, ...) and the position each must occupy; `Doc Flags to List
#' Members` names the evaluation function of every list; `Summary` and
#' `Service Line Hierarchy` carry the dominance hierarchies and the National
#' Programme of Care of every service line; and `Code Hierarchy List` is the
#' OPCS-4 hierarchy (borrowed from the HRG4+ Local Payment grouper of the same
#' year) used to pick the dominant procedure. This function parses the
#' workbook into tidy tables for the opendrg engine.
#'
#' The tool validates specialty, sex, patient classification and admission
#' method codes against the same reference data as the Local Payment grouper,
#' so those lists are taken from `reference`; attendance status and referral
#' source values follow the NHS Data Dictionary.
#'
#' @param path Path to the `... Guide to Identification Rules ... .xlsm`
#'   workbook.
#' @param version Version label, e.g. `"2025-26"`.
#' @param reference HRG4+ tables (see [hrg_tables()]) of the matching Local
#'   Payment grouper, used for the specialty, sex, patient classification and
#'   admission method reference lists.
#' @return A named list of tibbles with class `pso_tables`.
#' @export
#' @examples
#' \dontrun{
#' tbls <- pso_import_rules("PSO 202526 Prescribed Services Guide to Identification Rules v1.1.xlsm",
#'                          version = "2025-26", reference = hrg_tables("2025-26-lp"))
#' }
pso_import_rules <- function(path, version, reference = hrg_tables("2025-26-lp")) {
  rlang::check_installed("readxl", reason = "to read the Guide to Identification Rules workbook")
  stopifnot(is.character(path), length(path) == 1, file.exists(path))
  stopifnot(is.character(version), length(version) == 1)
  reference <- hrg_tables(reference)

  sheets <- readxl::excel_sheets(path)
  required <- c("Summary", "Code Sets", "Service Line Hierarchy", "Code Hierarchy List",
                "Doc Flags to List Members")
  missing <- setdiff(required, sheets)
  if (length(missing) > 0) {
    cli::cli_abort("Workbook is missing sheet{?s} {.val {missing}}.")
  }
  rd <- function(sheet, skip = 0, col_names = TRUE) {
    df <- readxl::read_excel(path, sheet = sheet, skip = skip, col_names = col_names,
                             col_types = "text", .name_repair = "minimal")
    names(df) <- trimws(gsub("[\r\n]+", " ", names(df)))
    tibble::as_tibble(df, .name_repair = "minimal")
  }
  clean <- function(x) {
    x <- trimws(as.character(x))
    x[!is.na(x) & x == ""] <- NA_character_
    x
  }

  # --- Code Sets ---------------------------------------------------------------
  cs <- rd("Code Sets", skip = 3)
  cs <- cs |>
    dplyr::transmute(
      setting = clean(.data$Setting),
      service_line = clean(.data[["PS Flag"]]),
      npoc_category = clean(.data[["NPoC Category"]]),
      name = clean(.data[["Prescribed Service Line"]]),
      rule = as.integer(clean(.data[["Identification Rule"]])),
      doc_flag = clean(.data[["Documentation Flag"]]),
      list_id = clean(.data[["List ID"]]),
      code_type = clean(.data[["Code Type"]]),
      position = clean(.data[["Episode Level Qualifying Position (ICD and OPCS only)"]]),
      value = as.integer(clean(.data[["Combination Value"]])),
      code = clean(.data$Code)
    ) |>
    dplyr::filter(!is.na(.data$doc_flag))

  # --- Hierarchies and programmes of care -------------------------------------
  su <- rd("Summary", skip = 4)
  summary_lines <- su |>
    dplyr::transmute(
      setting = clean(.data$Setting),
      service_line = sub(" - (APC|NAC)$", "", clean(.data[["Code / Flag"]])),
      hierarchy = as.integer(clean(.data[["Service line Hierarchy"]]))
    ) |>
    dplyr::filter(!is.na(.data$service_line), !is.na(.data$setting)) |>
    dplyr::distinct()
  slh <- rd("Service Line Hierarchy", skip = 5, col_names = FALSE)
  slh <- tibble::tibble(
    service_line = clean(slh[[1]]), apc_hier = as.integer(clean(slh[[5]])), nac_hier = as.integer(clean(slh[[6]]))
  ) |>
    dplyr::filter(!is.na(.data$service_line))
  check <- summary_lines |>
    dplyr::inner_join(slh, by = "service_line") |>
    dplyr::mutate(sheet = ifelse(.data$setting == "APC", .data$apc_hier, .data$nac_hier)) |>
    dplyr::filter(.data$hierarchy != .data$sheet)
  if (nrow(check) > 0) {
    cli::cli_abort("Summary and Service Line Hierarchy disagree for {.val {check$service_line}}.")
  }
  service_lines <- cs |>
    dplyr::distinct(.data$setting, .data$service_line, .data$npoc_category, .data$name) |>
    dplyr::left_join(summary_lines, by = c("setting", "service_line")) |>
    dplyr::mutate(
      npoc = ifelse(grepl("^[A-Z][0-9]{2} - ", .data$npoc_category), substr(.data$npoc_category, 1, 3), NA_character_),
      npoc_name = ifelse(is.na(.data$npoc), NA_character_, sub("^[A-Z][0-9]{2} - ", "", .data$npoc_category))
    ) |>
    dplyr::select("setting", "service_line", "name", "npoc", "npoc_name", "hierarchy") |>
    dplyr::arrange(.data$setting, .data$service_line)
  if (anyNA(service_lines$hierarchy)) {
    cli::cli_abort("No hierarchy for {.val {service_lines$service_line[is.na(service_lines$hierarchy)]}}.")
  }

  # --- Rules -------------------------------------------------------------------
  fns <- rd("Doc Flags to List Members")
  fns <- fns |>
    dplyr::transmute(
      doc_flag = clean(.data$Documentation_Flag_ID), list_id = clean(.data$List_ID),
      order = as.integer(clean(.data$Flag_Order)), fn = clean(.data$Function_ID)
    ) |>
    dplyr::filter(!is.na(.data$doc_flag)) |>
    dplyr::distinct(.data$doc_flag, .data$list_id, .keep_all = TRUE)
  rules <- cs |>
    dplyr::group_by(.data$setting, .data$service_line, .data$doc_flag, .data$rule, .data$list_id, .data$code_type, .data$position) |>
    dplyr::summarise(needed = if (all(is.na(.data$value))) NA_integer_ else max(.data$value, na.rm = TRUE), .groups = "drop") |>
    dplyr::left_join(fns, by = c("doc_flag", "list_id"))
  if (anyNA(rules$fn)) {
    bad <- rules[is.na(rules$fn), ]
    cli::cli_abort("No evaluation function for {.val {paste(bad$doc_flag, bad$list_id)}}.")
  }
  rules <- rules |>
    dplyr::mutate(fn = dplyr::case_when(
      .data$code_type == "OPCS" & .data$position == "Dominant Procedure" & is.na(.data$needed) ~ "DGVPInList",
      .data$code_type == "OPCS" & .data$position == "Dominant Procedure" ~ "NestedDGVPInList",
      .data$code_type == "OPCS" & !is.na(.data$needed) ~ "NestedDataItemInList",
      TRUE ~ "DataItemInList"
    ), .after = "position") |>
    dplyr::arrange(.data$setting, .data$service_line, .data$doc_flag, .data$order)
  mismatch <- rules |>
    dplyr::inner_join(fns, by = c("doc_flag", "list_id"), suffix = c("", ".sheet")) |>
    dplyr::filter(.data$fn != .data$fn.sheet)
  if (nrow(mismatch) > 0) {
    cli::cli_abort("Code Sets and Doc Flags disagree on the function of {.val {paste(mismatch$doc_flag, mismatch$list_id)}}.")
  }

  # --- Lists -------------------------------------------------------------------
  ages <- cs |>
    dplyr::filter(.data$code_type == "Age") |>
    dplyr::distinct(.data$list_id, .data$code) |>
    dplyr::mutate(
      allow_999 = grepl(", 999$", .data$code),
      range = sub(", 999$", "", .data$code),
      min = as.integer(sub(" - .*$", "", .data$range)),
      max = as.integer(sub("^.* - ", "", .data$range))
    ) |>
    dplyr::select("list_id", "min", "max", "allow_999")
  lists <- cs |>
    dplyr::filter(.data$code_type != "Age") |>
    dplyr::distinct(.data$list_id, .data$code_type, .data$code, .data$value) |>
    dplyr::mutate(code = ifelse(.data$code_type %in% c("ICD", "OPCS"), hrg_norm_code(.data$code), .data$code))
  # The generic provider code "PSS" is on every provider eligibility list
  # (User Manual, "Use of the Generic PSS provider code").
  org_lists <- unique(lists$list_id[lists$code_type == "Org"])
  lists <- dplyr::bind_rows(
    lists,
    tibble::tibble(list_id = org_lists, code_type = "Org", code = "PSS", value = NA_integer_)
  ) |>
    dplyr::arrange(.data$list_id, .data$value, .data$code)

  # --- Classification codes and the procedure hierarchy -----------------------
  ch <- rd("Code Hierarchy List", skip = 11)
  ch <- tibble::tibble(
    list_id = clean(ch[[1]]), code_type = clean(ch[[2]]), code = clean(ch[[3]]),
    hierarchy = as.integer(clean(ch[[5]]))
  )
  icd10 <- ch |> dplyr::filter(.data$list_id == "DiagHier", .data$code_type == "ICD") |> dplyr::distinct(code = hrg_norm_code(.data$code))
  opcs <- ch |>
    dplyr::filter(.data$list_id == "ProcHier", .data$code_type == "OPCS") |>
    dplyr::distinct(code = hrg_norm_code(.data$code), .data$hierarchy)

  # --- Reference data ----------------------------------------------------------
  reference_data <- dplyr::bind_rows(
    tibble::tibble(field = "SEX", code = reference$field_valid$SEX),
    tibble::tibble(field = "CLASSPAT", code = reference$field_valid$CLASSPAT),
    tibble::tibble(field = "ADMIMETH", code = reference$field_valid$ADMIMETH),
    tibble::tibble(field = "MAINSPEF", code = reference$field_valid$MAINSPEF),
    tibble::tibble(field = "TRETSPEF", code = reference$field_valid$TRETSPEF),
    # ATTENDED OR DID NOT ATTEND and SOURCE OF REFERRAL FOR OUT-PATIENTS (NHS Data Dictionary).
    tibble::tibble(field = "ATTENDED", code = as.character(2:7)),
    tibble::tibble(field = "REFSOURC", code = c(sprintf("%02d", c(1:7, 10:17)), "92", "93", "97"))
  )

  structure(
    list(
      version = version,
      service_lines = service_lines,
      rules = rules,
      lists = lists,
      ages = ages,
      icd10 = icd10,
      opcs = opcs,
      reference_data = reference_data
    ),
    class = "pso_tables"
  )
}

#' @export
print.pso_tables <- function(x, ...) {
  cat(sprintf("<pso_tables> Prescribed Specialised Services %s\n", x$version))
  cat(sprintf(
    "%d service lines (%d APC, %d NAC), %d identification rules, %s list entries\n",
    nrow(x$service_lines), sum(x$service_lines$setting == "APC"), sum(x$service_lines$setting == "NAC"),
    length(unique(x$rules$doc_flag)), format(nrow(x$lists), big.mark = ",")
  ))
  invisible(x)
}
