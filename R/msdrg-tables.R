# Bundled MS-DRG logic tables, loaded lazily and cached per session.

msdrg_cache <- new.env(parent = emptyenv())

#' List the MS-DRG versions bundled with opendrg
#'
#' @return A character vector of version labels such as `"44.0"`.
#' @export
#' @examples
#' msdrg_versions()
msdrg_versions <- function() {
  files <- list.files(system.file("extdata", "msdrg", package = "opendrg"), pattern = "^v[0-9]+\\.rds$")
  vapply(files, function(f) {
    digits <- sub("^v([0-9]+)\\.rds$", "\\1", f)
    paste0(substr(digits, 1, nchar(digits) - 1), ".", substr(digits, nchar(digits), nchar(digits)))
  }, character(1), USE.NAMES = FALSE) |> sort()
}

#' Load the logic tables for one MS-DRG version
#'
#' Tables are read from the package's `extdata` on first use and cached for
#' the rest of the session. Use [msdrg_import_cms()] to build tables for a
#' version that is not bundled.
#'
#' @param version Version label, e.g. `"44.0"`. Defaults to the latest bundled.
#'   May also be an `msdrg_tables` object from [msdrg_import_cms()].
#' @return An `msdrg_tables` list; see [msdrg_import_cms()] for its elements.
#' @export
msdrg_tables <- function(version = NULL) {
  if (inherits(version, "msdrg_tables")) {
    if (is.null(version$prepared)) version <- msdrg_prepare_tables(version)
    return(version)
  }
  available <- msdrg_versions()
  if (length(available) == 0) {
    cli::cli_abort("No MS-DRG tables are bundled with this installation of opendrg.")
  }
  version <- version %||% available[[length(available)]]
  if (!version %in% available) {
    cli::cli_abort(c(
      "MS-DRG version {.val {version}} is not bundled.",
      i = "Bundled versions: {.val {available}}.",
      i = "Build others with {.fn msdrg_import_cms} and pass the result as {.arg version}."
    ))
  }
  key <- paste0("v", gsub(".", "", version, fixed = TRUE))
  if (!exists(key, envir = msdrg_cache, inherits = FALSE)) {
    path <- system.file("extdata", "msdrg", paste0(key, ".rds"), package = "opendrg")
    assign(key, msdrg_prepare_tables(readRDS(path)), envir = msdrg_cache)
  }
  get(key, envir = msdrg_cache, inherits = FALSE)
}

# Names that are not attributes but computed by the engine (see
# msdrg_special_columns()). Everything else without a scope is a procedure
# attribute.
msdrg_specials <- c(
  "MCC", "CC", "ANYDX",
  "INVALID_DSTAT", "INVALID_PDX", "INVALID_SEX", "PDX_ECODE", "INVALID_AGE",
  "ALIVE", "DIED", "AMA", "XFRNBA",
  "MULTST", "BILATERAL", "SINGLEFUSIONCTR", "SGLANTCTR", "SGLPOST1CTR",
  "MULTFUSE", "SGLANTSECTXCTR", "SGLPOSTFUSECTR", "FOUR_VESSELS", "FOUR_STENTS",
  "MDC_20_FALL_THRU"
)

# Resolver used for DRGLOGIC rows: MCC / CC compare the row-specific severity
# column, other specials map to sp__ columns, the rest to scope columns.
msdrg_row_resolver <- function(supp_id) {
  sev_col <- rlang::sym(paste0("sev__", supp_id))
  function(scope, name) {
    # CMS dispatches `incident` to the only-incident node by name, whatever
    # prefix the formula wrote.
    if (name == "incident") {
      return(rlang::sym("only__incident"))
    }
    if (!is.na(scope)) {
      return(rlang::sym(msdrg_term_column(scope, name)))
    }
    switch(name,
      MCC = rlang::call2("==", sev_col, "MCC"),
      CC = rlang::call2("==", sev_col, "CC"),
      ANYDX = TRUE,
      INVALID_AGE = FALSE,
      if (name %in% msdrg_specials) rlang::sym(paste0("sp__", name)) else rlang::sym(paste0("pr__", name))
    )
  }
}

# One-off derivations on top of the raw CMS tables that the engine relies on.
msdrg_prepare_tables <- function(tbls) {
  # PDX:dxc0306 means "principal diagnosis whose pattern is MDC 03, category
  # 06"; HACnn marks membership of hospital-acquired-condition list nn. Both
  # are materialized as ordinary diagnosis attributes.
  dxc <- tbls$dx_patterns |>
    dplyr::filter(.data$mdc > 0) |>
    dplyr::transmute(pattern = .data$pattern, attribute = sprintf("dxc%02d%02d", .data$mdc, .data$dx_cat))
  hac <- tbls$dx_patterns |>
    dplyr::filter(.data$hac > 0) |>
    dplyr::transmute(pattern = .data$pattern, attribute = sprintf("HAC%02d", .data$hac))
  # HAC-6 (catheter-associated UTI) codes that are not the catheter-infection
  # codes themselves are the "show" list; CMS's binary carries this as the
  # operand hac06_show, which the flat files omit.
  hac6_sdx <- tbls$dx_pattern_attrs$pattern[tbls$dx_pattern_attrs$attribute == "hac06_sdx"]
  show <- tbls$dx_patterns |>
    dplyr::filter(.data$hac == 6L, !.data$pattern %in% hac6_sdx) |>
    dplyr::transmute(pattern = .data$pattern, attribute = "hac06_show")
  tbls$dx_pattern_attrs <- dplyr::bind_rows(tbls$dx_pattern_attrs, dxc, hac, show) |>
    dplyr::distinct()

  # Per-pattern severity contributed by a diagnosis when it is secondary.
  tbls$dx_pattern_severity <- tbls$dx_pattern_attrs |>
    dplyr::filter(.data$attribute %in% c("MCC", "CC")) |>
    dplyr::group_by(.data$pattern) |>
    dplyr::summarise(severity = if (any(.data$attribute == "MCC")) "MCC" else "CC", .groups = "drop")

  # Cluster definitions: number of choice slots and parsed MDC suppression.
  tbls$cluster_defs <- tbls$clusters |>
    dplyr::group_by(.data$cluster_code) |>
    dplyr::summarise(
      n_choices = dplyr::n_distinct(.data$choice),
      mdc_restriction = dplyr::first(.data$mdc_restriction),
      .groups = "drop"
    ) |>
    dplyr::mutate(suppress_mdcs = lapply(.data$mdc_restriction, msdrg_parse_mdc_restriction))

  # Pre-parse every formula once; compile per row with its severity column.
  logic <- tbls$drg_logic
  supp_keys <- unique(c("", stats::na.omit(logic$suppression)))
  logic$supp_id <- match(ifelse(is.na(logic$suppression), "", logic$suppression), supp_keys)
  logic$ast <- lapply(logic$formula, msdrg_formula_parse)
  logic$expr <- Map(function(ast, id) msdrg_formula_compile(ast, msdrg_row_resolver(id)), logic$ast, logic$supp_id)
  tbls$drg_logic <- logic
  tbls$suppression_sets <- tibble::tibble(
    supp_id = seq_along(supp_keys),
    attributes = lapply(strsplit(supp_keys, "|", fixed = TRUE), function(x) x[nzchar(x)])
  )
  tbls$logic_by_mdc <- split(logic, logic$mdc)
  tbls$terms_by_mdc <- lapply(tbls$logic_by_mdc, msdrg_rows_terms)

  if (!is.null(tbls$hac_formulas)) {
    hac <- tbls$hac_formulas
    hac$ast <- lapply(hac$formula, msdrg_formula_parse)
    hac$expr <- lapply(hac$ast, msdrg_formula_compile, resolver = msdrg_row_resolver(1L))
    tbls$hac_formulas <- hac
    tbls$hac_terms <- msdrg_rows_terms(hac)
  }
  tbls$prepared <- TRUE
  tbls
}

# PRCLSTRS.MDCRESTRICTION: "|"-separated MDC numbers, "F" for the
# unrelated-OR pseudo-MDC 29, "ALL" for MDCs 1-25 plus 29 (never MDC 0).
msdrg_parse_mdc_restriction <- function(x) {
  if (is.na(x) || x == "") {
    return(integer())
  }
  parts <- strsplit(x, "|", fixed = TRUE)[[1]]
  mdcs <- as.integer(parts[grepl("^[0-9]+$", parts)])
  if ("F" %in% parts) mdcs <- c(mdcs, 29L)
  if ("ALL" %in% parts) mdcs <- c(mdcs, 1:25, 29L)
  sort(unique(mdcs))
}
