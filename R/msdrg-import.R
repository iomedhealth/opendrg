#' Import CMS MS-DRG logic tables from a mainframe "Misc" release folder
#'
#' CMS publishes the full MS-DRG grouper logic as a set of CSV-like flat files
#' inside the mainframe software package (`CMSDRGvvv_MF_Java_Misc/`): the DRG
#' decision formulas (`DRGLOGIC`), diagnosis and procedure attribute patterns
#' (`DXPATERN`, `PRPATERN`), the code-to-pattern maps (`DXLIST`, `PRLIST`), the
#' attribute vocabularies (`DXATTLST`, `PRATTLST`), the CC/MCC exclusion list
#' (`EXCLUSN`), procedure clusters (`PRCLSTRS`) and descriptions (`MDCDSC`,
#' `DRGDSC4`). This function parses them into tidy tables that the opendrg
#' engine evaluates.
#'
#' @param dir Path to the folder containing the flat files.
#' @param version Version label, e.g. `"44.0"`. Stored in the result.
#' @param hac_formulas Optional data frame with columns `hac_number` and
#'   `formula`: the hospital-acquired-condition criteria formulas. CMS ships
#'   these only inside the grouper's binary data, not in the flat files; the
#'   bundled versions carry them. Without them the final DRG ignores HACs.
#' @return A named list of tibbles with class `msdrg_tables`.
#' @export
#' @examples
#' \dontrun{
#' tbls <- msdrg_import_cms("path/to/CMSDRG440_MF_Java_Misc", version = "44.0")
#' }
msdrg_import_cms <- function(dir, version, hac_formulas = NULL) {
  stopifnot(is.character(dir), length(dir) == 1, dir.exists(dir))
  stopifnot(is.character(version), length(version) == 1)
  if (!is.null(hac_formulas)) {
    require_columns(hac_formulas, c("hac_number", "formula"), "hac_formulas")
    hac_formulas <- tibble::tibble(
      hac_number = as.integer(hac_formulas$hac_number),
      formula = as.character(hac_formulas$formula)
    )
  }

  required <- c("DRGLOGIC", "DXPATERN", "PRPATERN", "DXLIST", "PRLIST",
                "DXATTLST", "PRATTLST", "EXCLUSN", "PRCLSTRS", "MDCDSC", "DRGDSC4")
  missing <- required[!file.exists(file.path(dir, required))]
  if (length(missing) > 0) {
    cli::cli_abort("Missing CMS flat file{?s} in {.path {dir}}: {.file {missing}}.")
  }

  read_flat <- function(name) {
    df <- utils::read.csv(
      file.path(dir, name), header = TRUE, colClasses = "character",
      strip.white = TRUE, na.strings = character(), check.names = FALSE, quote = "\""
    )
    names(df) <- tolower(names(df))
    tibble::as_tibble(df)
  }

  # Two-column "key,description" files without a header whose descriptions
  # themselves contain commas: split on the first comma only.
  read_desc <- function(name, key) {
    lines <- readLines(file.path(dir, name), warn = FALSE)
    lines <- trimws(lines[nzchar(trimws(lines))])
    tibble::tibble(
      !!key := stringr::str_extract(lines, "^[^,]*"),
      description = stringr::str_remove(lines, "^[^,]*,")
    )
  }

  split_attrs <- function(tbl, key) {
    tbl |>
      dplyr::select(dplyr::all_of(key), "operand") |>
      dplyr::mutate(attribute = stringr::str_split(.data$operand, stringr::fixed("|"))) |>
      dplyr::select(-"operand") |>
      tidyr::unnest("attribute") |>
      dplyr::filter(.data$attribute != "") |>
      dplyr::distinct()
  }

  drg_logic <- read_flat("DRGLOGIC") |>
    dplyr::transmute(
      row = dplyr::row_number(),
      mdc = as.integer(.data$mdc),
      drg = as.integer(.data$drg),
      med_surg = dplyr::na_if(.data$medsurg, ""),
      base_drg = as.integer(.data$basedrg),
      return_code = as.integer(.data$returncode),
      reroute_mdc = as.integer(.data$reroutemdc),
      formula = .data$formula,
      suppression = dplyr::na_if(.data$suppression, "")
    )

  dx_patterns_raw <- read_flat("DXPATERN")
  dx_patterns <- dx_patterns_raw |>
    dplyr::transmute(
      pattern = as.integer(.data$patternnumber),
      mdc = as.integer(.data$mdc),
      dx_cat = as.integer(.data$dxcat),
      hac = as.integer(.data$hacnumber)
    )
  dx_pattern_attrs <- dx_patterns_raw |>
    dplyr::mutate(pattern = as.integer(.data$patternnumber)) |>
    split_attrs("pattern")

  pr_patterns_raw <- read_flat("PRPATERN")
  pr_pattern_attrs <- pr_patterns_raw |>
    dplyr::mutate(pattern = as.integer(.data$patternnumber)) |>
    split_attrs("pattern")

  dx_codes <- read_flat("DXLIST") |>
    dplyr::transmute(
      code = .data$code,
      gender = as.integer(.data$codegender),
      exclusion_group = as.integer(.data$exclusiongroup),
      pattern = as.integer(.data$patternnumber)
    )

  pr_codes <- read_flat("PRLIST") |>
    dplyr::transmute(code = .data$code, pattern = as.integer(.data$patternnumber))

  dx_attributes <- read_flat("DXATTLST") |>
    dplyr::transmute(id = as.integer(.data$id), attribute = .data$operand,
                     description = .data$description)
  pr_attributes <- read_flat("PRATTLST") |>
    dplyr::transmute(id = as.integer(.data$id), attribute = .data$operand,
                     description = .data$description)

  exclusions <- read_flat("EXCLUSN") |>
    dplyr::transmute(exclusion_group = as.integer(.data$exclusiongroup), code = .data$code)

  clusters <- read_flat("PRCLSTRS") |>
    dplyr::transmute(
      proc_code = .data$proccode,
      cluster_code = .data$clustercode,
      choice = as.integer(.data$choice),
      n_required = as.integer(.data$numrequiredprocs),
      mdc_restriction = dplyr::na_if(.data$mdcrestriction, "")
    )

  mdc_desc <- read_desc("MDCDSC", "mdc") |>
    dplyr::mutate(mdc = as.integer(.data$mdc))
  drg_desc <- read_desc("DRGDSC4", "drg") |>
    dplyr::mutate(drg = as.integer(.data$drg))

  structure(
    list(
      version = version,
      drg_logic = drg_logic,
      dx_codes = dx_codes,
      dx_patterns = dx_patterns,
      dx_pattern_attrs = dx_pattern_attrs,
      pr_codes = pr_codes,
      pr_pattern_attrs = pr_pattern_attrs,
      dx_attributes = dx_attributes,
      pr_attributes = pr_attributes,
      exclusions = exclusions,
      clusters = clusters,
      mdc_desc = mdc_desc,
      drg_desc = drg_desc,
      hac_formulas = hac_formulas
    ),
    class = "msdrg_tables"
  )
}

#' @export
print.msdrg_tables <- function(x, ...) {
  cat(sprintf("<msdrg_tables> version %s\n", x$version))
  tables <- Filter(is.data.frame, x)
  counts <- vapply(tables, nrow, integer(1))
  cat(sprintf("  %-20s %s\n", names(counts), format(counts, big.mark = ",")), sep = "")
  invisible(x)
}
