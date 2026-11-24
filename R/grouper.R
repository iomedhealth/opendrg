#' Create a casemix grouper
#'
#' A grouper object bundles a grouping system, a version of its logic tables
#' and the engine that evaluates them. Pass it to [group()] together with
#' claim data.
#'
#' @param system Grouping system. Currently `"msdrg"` (CMS Medicare Severity
#'   DRGs). `"hrg4plus"` (NHS England HRG4+) is planned.
#' @param version Version label, e.g. `"44.0"` for MS-DRG FY 2027. Defaults
#'   to the latest bundled version. May also be a table set built with
#'   [msdrg_import_cms()].
#' @return An object of class `opengrd_grouper`.
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
        class = c("msdrg_grouper", "opengrd_grouper")
      )
    },
    hrg4plus = cli::cli_abort("The HRG4+ grouper is not implemented yet.")
  )
}

#' @export
print.opengrd_grouper <- function(x, ...) {
  label <- switch(x$system, msdrg = "CMS MS-DRG", hrg4plus = "NHS England HRG4+", x$system)
  cat(sprintf("<opengrd grouper> %s, version %s\n", label, x$version))
  if (x$system == "msdrg") {
    t <- x$tables
    n_drg <- length(unique(t$drg_logic$drg[t$drg_logic$drg > 0]))
    cat(sprintf(
      "%d DRGs, %d logic rows, %s diagnosis codes, %s procedure codes\n",
      n_drg, nrow(t$drg_logic), format(nrow(t$dx_codes), big.mark = ","),
      format(nrow(t$pr_codes), big.mark = ",")
    ))
  }
  invisible(x)
}

#' Assign casemix groups to claims
#'
#' @param grouper A grouper created with [grouper()].
#' @param claims A data frame with one row per claim. See the system-specific
#'   documentation (e.g. [msdrg_group()]) for the required columns.
#' @param diagnoses A data frame with one row per diagnosis code on a claim.
#' @param procedures A data frame with one row per procedure code on a claim.
#' @param ... Passed on to the system-specific method.
#' @return A data frame with one row per claim and the grouping results.
#' @export
group <- function(grouper, claims, diagnoses, procedures, ...) {
  UseMethod("group")
}

#' @export
group.msdrg_grouper <- function(grouper, claims, diagnoses, procedures, ...) {
  msdrg_group(claims, diagnoses, procedures, tables = grouper$tables, ...)
}
