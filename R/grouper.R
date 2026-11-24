#' Create a casemix grouper
#'
#' A grouper object bundles a grouping system, a version of its logic tables
#' and the engine that evaluates them. Pass it to [group()] together with
#' claim data.
#'
#' @param system Grouping system: `"msdrg"` (CMS Medicare Severity DRGs) or
#'   `"hrg4plus"` (NHS England HRG4+, admitted patient care).
#' @param version Version label, e.g. `"44.0"` for MS-DRG FY 2027 or
#'   `"2024-25-nc"` for the HRG4+ 2024/25 National Costs design. Defaults to
#'   the latest bundled version. May also be a table set built with
#'   [msdrg_import_cms()] or [hrg_import_code_to_group()].
#' @return An object of class `opendrg_grouper`.
#' @export
#' @examples
#' g <- grouper("msdrg", version = "44.0")
#' g
grouper <- function(system = c("msdrg", "hrg4plus"), version = NULL) {
  system <- rlang::arg_match(system)
  switch(system,
    msdrg = {
      tbls <- msdrg_tables(version)
      structure(
        list(system = "msdrg", version = tbls$version, tables = tbls),
        class = c("msdrg_grouper", "opendrg_grouper")
      )
    },
    hrg4plus = {
      tbls <- hrg_tables(version)
      structure(
        list(system = "hrg4plus", version = tbls$version, tables = tbls),
        class = c("hrg_grouper", "opendrg_grouper")
      )
    }
  )
}

#' @export
print.opendrg_grouper <- function(x, ...) {
  label <- switch(x$system, msdrg = "CMS MS-DRG", hrg4plus = "NHS England HRG4+", x$system)
  cat(sprintf("<opendrg grouper> %s, version %s\n", label, x$version))
  t <- x$tables
  if (x$system == "msdrg") {
    n_drg <- length(unique(t$drg_logic$drg[t$drg_logic$drg > 0]))
    cat(sprintf(
      "%d DRGs, %d logic rows, %s diagnosis codes, %s procedure codes\n",
      n_drg, nrow(t$drg_logic), format(nrow(t$dx_codes), big.mark = ","),
      format(nrow(t$pr_codes), big.mark = ",")
    ))
  } else {
    cat(sprintf(
      "%s HRGs, %s code mappings, %s flag conditions, %s list entries\n",
      format(nrow(t$hrgs), big.mark = ","), format(nrow(t$code_to_group), big.mark = ","),
      format(nrow(t$flag_rules), big.mark = ","), format(nrow(t$lists), big.mark = ",")
    ))
  }
  invisible(x)
}

#' Assign casemix groups to claims
#'
#' @param grouper A grouper created with [grouper()].
#' @param claims A data frame with one row per claim. See the system-specific
#'   documentation (e.g. [msdrg_group()]) for the required columns.
#' @param diagnoses A data frame with one row per diagnosis code on a claim
#'   (MS-DRG only; HRG4+ episodes carry their codes in `DIAG_nn`/`OPER_nn`
#'   columns).
#' @param procedures A data frame with one row per procedure code on a claim
#'   (MS-DRG only).
#' @param ... Passed on to the system-specific method.
#' @return For MS-DRG, a data frame with one row per claim; for HRG4+, a list
#'   with `episodes` and `spells` data frames (see [hrg_group_apc()]).
#' @export
group <- function(grouper, claims, diagnoses = NULL, procedures = NULL, ...) {
  UseMethod("group")
}

#' @export
group.msdrg_grouper <- function(grouper, claims, diagnoses = NULL, procedures = NULL, ...) {
  msdrg_group(claims, diagnoses, procedures, tables = grouper$tables, ...)
}

#' @export
group.hrg_grouper <- function(grouper, claims, diagnoses = NULL, procedures = NULL, ...) {
  hrg_group_apc(claims, tables = grouper$tables)
}
