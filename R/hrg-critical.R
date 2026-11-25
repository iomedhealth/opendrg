# HRG4+ paediatric (PCC) and neonatal (NCC) critical care: one HRG per
# critical-care day from the hard-coded flowcharts in the Chapter Summaries.

#' Group paediatric critical care days to HRG4+
#' @param days Data frame in the PCC layout (`PROCODET`, `CCLocalID`,
#'   `CCDate`, `DISDATE`, `DISMETH`, `CCUF`, `CCAC_01`..., `OPER_01`...,
#'   `DIAG_01`...).
#' @param tables Tables from [hrg_tables()].
#' @return A tibble with `pcc_hrg` and `quality` per day.
#' @export
hrg_group_pcc <- function(days, tables = hrg_tables()) {
  cli::cli_abort("Paediatric critical care grouping is not implemented yet.")
}

#' Group neonatal critical care days to HRG4+
#' @param days Data frame in the NCC layout (`PROCODET`, `CCLocalID`,
#'   `CCDate`, `DISDATE`, `CCUF`, `AGE_DAYS`, `DISMETH`, `GestLen`, `PERWT`,
#'   `CCAC_01`...).
#' @param tables Tables from [hrg_tables()].
#' @return A tibble with `ncc_hrg` and `quality` per day.
#' @export
hrg_group_ncc <- function(days, tables = hrg_tables()) {
  cli::cli_abort("Neonatal critical care grouping is not implemented yet.")
}
