# Build the testthat fixture for the HRG4+ APC engine from NHS England's
# official test data and expected results (Open Government Licence v3.0).

suppressPackageStartupMessages(library(dplyr))
d <- "target/HRG4+ 202425 National Costs Grouper/docs/_extract/HRG4+ 202425 National Costs Grouper Test Data and Expected Results v1.0/APC/"
p <- function(x) paste0(d, "HRG4+ 202425 National Costs Grouper Admitted Patient Care Sample ", x)
rd <- function(x) suppressWarnings(readr::read_csv(p(x), show_col_types = FALSE, col_types = readr::cols(.default = "c")))
fce <- rd("Expected Results_FCE.csv")
ub <- rd("Expected Results_ub_rel.csv")
input_cols <- names(fce)[seq_len(which(names(fce) == "RowNo") - 1)]
exp_ub <- ub |> group_by(RowNo) |> summarise(unbundled = paste(UnbundledHRGs, collapse = ","), .groups = "drop")

fixture <- list(
  version = "2024-25-nc",
  episodes = fce[input_cols],
  expected = fce |>
    select(RowNo, FCE_HRG, GroupingMethodFlag, DominantProcedure, FCE_PBC, CalcEpidur, SpellReportFlag,
           SpellHRG, SpellGroupingMethodFlag, SpellDominantProcedure, SpellPDiag, SpellSDiag,
           SpellEpisodeCount, SpellLOS) |>
    left_join(exp_ub, by = "RowNo") |>
    mutate(unbundled = coalesce(unbundled, ""))
)
out <- "tests/testthat/fixtures/hrg_2024-25-nc_apc.rds"
saveRDS(fixture, out, compress = "xz")
cat("Wrote", out, "(", round(file.size(out) / 1024), "KB ) with", nrow(fixture$episodes), "episodes\n")
