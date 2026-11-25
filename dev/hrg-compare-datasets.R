# Compare opendrg's HRG4+ non-admitted datasets with NHS England's expected results.

suppressPackageStartupMessages({
  pkgload::load_all(".", quiet = TRUE)
  library(dplyr)
})
options(width = 220)
base <- "target/HRG4+ 202425 National Costs Grouper/docs/_extract/HRG4+ 202425 National Costs Grouper Test Data and Expected Results v1.0/"
rd <- function(path) suppressWarnings(readr::read_csv(path, show_col_types = FALSE, col_types = readr::cols(.default = "c")))
files <- function(ds, suffix) list.files(paste0(base, ds), pattern = paste0(suffix, "$"), full.names = TRUE)[1]
tbls <- hrg_tables("2024-25-nc")

report <- function(name, got, exp, cols) {
  cat(sprintf("\n=== %s: %d rows\n", name, nrow(exp)))
  for (nm in names(cols)) {
    g <- got[[nm]]; e <- exp[[cols[[nm]]]]
    g <- coalesce(as.character(g), ""); e <- coalesce(e, "")
    ok <- g == e
    cat(sprintf("  %-22s %5.1f%%  (%d mismatches)\n", nm, 100 * mean(ok), sum(!ok)))
    if (any(!ok)) print(head(tibble(row = which(!ok), expected = e[!ok], got = g[!ok]), 8))
  }
}

# NAC
nac_in <- rd(files("NAC", "Sample Test Data.csv")); nac_exp <- rd(files("NAC", "Expected Results_attend.csv"))
ub <- rd(files("NAC", "_ub_rel.csv")) |> group_by(RowNo) |> summarise(ub = paste(UnbundledHRGs, collapse = ","), .groups = "drop")
nac_exp <- nac_exp |> left_join(ub, by = "RowNo") |> mutate(ub = coalesce(ub, ""))
got <- hrg_group_nac(nac_in[names(nac_in) != "dummy_field"], tbls) |> mutate(ub = gsub("\\*[0-9]+", "", unbundled_hrgs))
report("NAC", got, nac_exp, c(nac_hrg = "NAC_HRG", grouping_method = "GroupingMethodFlag", dominant_procedure = "DominantProcedure", ub = "ub"))
nac_q <- rd(files("NAC", "_quality_rel.csv"))
cat("  quality rows expected:", nrow(nac_q), " got:", sum(nchar(got$quality) > 0), "\n")

# EM
em_in <- rd(files("EM", "Sample Test Data.csv")); em_exp <- rd(files("EM", "Expected Results_attend.csv"))
got <- hrg_group_em(em_in[names(em_in) != "dummy_field"], tbls)
report("EM", got, em_exp, c(em_hrg = "EM_HRG"))

# ACC
acc_in <- rd(files("ACC", "Sample Test Data.csv")); acc_exp <- rd(files("ACC", "Expected Results_acc.csv"))
got <- hrg_group_acc(acc_in[names(acc_in) != "dummy_field"], tbls)
report("ACC", got, acc_exp, c(acc_hrg = "ACC_HRG", calc_cc_days = "Calc_CC_Days", cc_warning_flag = "CC_Warning_Flag"))

# NRD
nrd_in <- rd(files("NRD", "Sample Test Data.csv")); nrd_exp <- rd(files("NRD", "Expected Results_renal.csv"))
got <- hrg_group_nrd(nrd_in[names(nrd_in) != "dummy_field"], tbls)
report("NRD", got, nrd_exp, c(nrd_hrg = "NRD_HRG"))
