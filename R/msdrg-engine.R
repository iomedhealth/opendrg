# Evaluation core: build a wide, one-row-per-claim table of the logical
# term columns a set of formulas needs, then evaluate the formulas in order
# with first-match-wins semantics.

# Terms referenced by a set of DRGLOGIC rows, as a tibble of (scope, name).
# `incident` always resolves to the ONLY scope (see msdrg_row_resolver()).
msdrg_rows_terms <- function(rows) {
  dplyr::bind_rows(lapply(rows$ast, msdrg_formula_terms)) |>
    dplyr::mutate(scope = ifelse(.data$name == "incident", "ONLY", .data$scope)) |>
    dplyr::distinct()
}

# Scope columns derived from the diagnosis attribute table.
#   pdx__x  the principal diagnosis has x
#   sdx__x  some secondary diagnosis has x
#   any__x  some diagnosis has x
#   only__x the principal diagnosis has x and so does every valid secondary
msdrg_wide_dx <- function(claim_ids, dx_attrs, terms, ctx) {
  dx_terms <- terms[!is.na(terms$scope), ]
  if (nrow(dx_terms) == 0) {
    return(tibble::tibble(claim_id = claim_ids))
  }
  attrs <- dx_attrs |>
    dplyr::filter(.data$attribute %in% unique(dx_terms$name))

  presence <- function(df, prefix, names) {
    wide <- df |>
      dplyr::filter(.data$attribute %in% names) |>
      dplyr::distinct(.data$claim_id, .data$attribute) |>
      dplyr::mutate(value = TRUE) |>
      tidyr::pivot_wider(
        names_from = "attribute", values_from = "value",
        names_prefix = paste0(prefix, "__"), values_fill = FALSE
      )
    ensure_columns(wide, paste0(prefix, "__", names))
  }

  out <- tibble::tibble(claim_id = claim_ids)
  scopes <- split(dx_terms$name, dx_terms$scope)
  if (!is.null(scopes$PDX)) {
    out <- dplyr::left_join(out, presence(dplyr::filter(attrs, .data$seq == 1L), "pdx", scopes$PDX), by = "claim_id")
  }
  if (!is.null(scopes$SDX)) {
    out <- dplyr::left_join(out, presence(dplyr::filter(attrs, .data$seq > 1L), "sdx", scopes$SDX), by = "claim_id")
  }
  if (!is.null(scopes$ANY)) {
    out <- dplyr::left_join(out, presence(attrs, "any", scopes$ANY), by = "claim_id")
  }
  if (!is.null(scopes$ONLY)) {
    n_valid_sdx <- ctx$sdx |>
      dplyr::filter(.data$claim_id %in% claim_ids, .data$valid) |>
      dplyr::count(.data$claim_id, name = "n_sdx")
    pdx_has <- attrs |>
      dplyr::filter(.data$seq == 1L, .data$attribute %in% scopes$ONLY) |>
      dplyr::distinct(.data$claim_id, .data$attribute)
    sdx_with <- attrs |>
      dplyr::filter(.data$seq > 1L, .data$attribute %in% scopes$ONLY) |>
      dplyr::distinct(.data$claim_id, .data$seq, .data$attribute) |>
      dplyr::count(.data$claim_id, .data$attribute, name = "n_with")
    only <- pdx_has |>
      dplyr::left_join(sdx_with, by = c("claim_id", "attribute")) |>
      dplyr::left_join(n_valid_sdx, by = "claim_id") |>
      dplyr::mutate(value = dplyr::coalesce(.data$n_with, 0L) == dplyr::coalesce(.data$n_sdx, 0L)) |>
      dplyr::select("claim_id", "attribute", "value") |>
      tidyr::pivot_wider(
        names_from = "attribute", values_from = "value",
        names_prefix = "only__", values_fill = FALSE
      ) |>
      ensure_columns(paste0("only__", scopes$ONLY))
    out <- dplyr::left_join(out, only, by = "claim_id")
  }
  fill_false(out, setdiff(names(out), "claim_id"))
}

# Procedure scope columns: pr__x when some procedure on the claim has x.
# Names in `exclude` (computed specials) are left to the caller.
msdrg_wide_pr <- function(claim_ids, pr_attrs, terms, exclude = character()) {
  names <- setdiff(unique(terms$name[is.na(terms$scope)]), exclude)
  out <- tibble::tibble(claim_id = claim_ids)
  if (length(names) == 0) {
    return(out)
  }
  wide <- pr_attrs |>
    dplyr::filter(.data$attribute %in% names) |>
    dplyr::distinct(.data$claim_id, .data$attribute) |>
    dplyr::mutate(value = TRUE) |>
    tidyr::pivot_wider(
      names_from = "attribute", values_from = "value",
      names_prefix = "pr__", values_fill = FALSE
    ) |>
    ensure_columns(paste0("pr__", names))
  out |>
    dplyr::left_join(wide, by = "claim_id") |>
    fill_false(paste0("pr__", names))
}

ensure_columns <- function(df, cols) {
  for (col in setdiff(cols, names(df))) {
    df[[col]] <- rep(FALSE, nrow(df))
  }
  df
}

fill_false <- function(df, cols) {
  for (col in cols) {
    df[[col]][is.na(df[[col]])] <- FALSE
  }
  df
}

# Evaluate ordered DRGLOGIC rows against a wide claim table. Returns the
# `row` id of the first row whose formula is TRUE for each claim, or NA.
# Implemented as a single case_when() so the same code can run under dbplyr.
msdrg_first_match <- function(wide, rows) {
  if (nrow(rows) == 0 || nrow(wide) == 0) {
    return(rep(NA_integer_, nrow(wide)))
  }
  # Build `case_when(expr1 ~ row1, expr2 ~ row2, ...)` as an unevaluated call
  # so the formulas are created inside the data mask when injected.
  clauses <- purrr::map2(rows$expr, rows$row, function(expr, row) rlang::call2("~", expr, row))
  cw <- rlang::call2(quote(dplyr::case_when), !!!clauses, .default = NA_integer_)
  dplyr::mutate(wide, .match = !!cw)$.match
}
