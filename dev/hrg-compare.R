# Compare opendrg's HRG4+ APC grouping with NHS England's official expected results.

suppressPackageStartupMessages({
  pkgload::load_all(".", quiet = TRUE)
  library(dplyr)
})
options(width = 220)

d <- "target/HRG4+ 202425 National Costs Grouper/docs/_extract/HRG4+ 202425 National Costs Grouper Test Data and Expected Results v1.0/APC/"
p <- function(x) paste0(d, "HRG4+ 202425 National Costs Grouper Admitted Patient Care Sample ", x)
rd <- function(x) suppressWarnings(readr::read_csv(p(x), show_col_types = FALSE, col_types = readr::cols(.default = "c")))
fce <- rd("Expected Results_FCE.csv")
spell <- rd("Expected Results_spell.csv")
ub <- rd("Expected Results_ub_rel.csv")
input_cols <- names(fce)[seq_len(which(names(fce) == "RowNo") - 1)]

t0 <- Sys.time()
res <- hrg_group_apc(fce[input_cols], tables = hrg_tables("2024-25-nc"))
cat(sprintf("Grouped %d episodes / %d spells in %.1f s\n", nrow(res$episodes), nrow(res$spells),
            as.numeric(difftime(Sys.time(), t0, units = "secs"))))

exp_ub <- ub |> group_by(RowNo) |> summarise(exp_ub = paste(UnbundledHRGs, collapse = ","), .groups = "drop")
cmp <- fce |>
  select(RowNo, FCE_HRG, GroupingMethodFlag, DominantProcedure, FCE_PBC, CalcEpidur, SpellReportFlag,
         SpellHRG, SpellGroupingMethodFlag, SpellDominantProcedure, SpellPDiag, SpellSDiag, SpellEpisodeCount, SpellLOS,
         DIAG_01, OPER_01, OPER_02, OPER_03, STARTAGE, EPIDUR) |>
  left_join(exp_ub, by = "RowNo") |>
  bind_cols(res$episodes |> select(-row)) |>
  mutate(
    exp_ub = coalesce(exp_ub, ""),
    ok_hrg = fce_hrg == FCE_HRG,
    ok_method = coalesce(grouping_method == GroupingMethodFlag, FALSE),
    ok_dom = coalesce(dominant_procedure == DominantProcedure, is.na(dominant_procedure) & is.na(DominantProcedure)),
    ok_pbc = fce_pbc == FCE_PBC,
    ok_ub = gsub("\\*[0-9]+", "", unbundled_hrgs) == exp_ub,
    ok_epidur = coalesce(as.character(calc_epidur), "") == coalesce(CalcEpidur, ""),
    ok_report = as.character(spell_report_flag) == SpellReportFlag,
    ok_spell_hrg = spell_hrg == SpellHRG,
    ok_spell_method = spell_grouping_method == SpellGroupingMethodFlag,
    ok_spell_dom = coalesce(spell_dominant_procedure == SpellDominantProcedure, is.na(spell_dominant_procedure) & is.na(SpellDominantProcedure)),
    ok_spell_pdiag = coalesce(spell_pdiag == SpellPDiag, is.na(spell_pdiag) & is.na(SpellPDiag)),
    ok_spell_sdiag = coalesce(spell_sdiag == SpellSDiag, is.na(spell_sdiag) & is.na(SpellSDiag)),
    ok_spell_los = as.character(spell_los) == SpellLOS,
    ok_spell_n = as.character(spell_episode_count) == SpellEpisodeCount
  )
summ <- cmp |> summarise(across(starts_with("ok_"), ~ round(100 * mean(.x), 1)))
print(as.data.frame(t(summ)))

for (what in c("ok_hrg", "ok_method", "ok_dom", "ok_ub", "ok_pbc", "ok_spell_hrg")) {
  bad <- cmp |> filter(!.data[[what]])
  if (nrow(bad) > 0) {
    cat(sprintf("\n== %s mismatches: %d\n", what, nrow(bad)))
    print(bad |> select(RowNo, FCE_HRG, fce_hrg, GroupingMethodFlag, grouping_method, DominantProcedure, dominant_procedure,
                        exp_ub, unbundled_hrgs, SpellHRG, spell_hrg, DIAG_01, OPER_01, OPER_02, STARTAGE, EPIDUR) |> head(12), n = 12)
  }
}
readr::write_csv(cmp, "dev/oracle/output/hrg_apc_vs_expected.csv")
