# Build the testthat fixtures for the HRG4+ engines from NHS England's
# official test data and expected results (Open Government Licence v3.0).

suppressPackageStartupMessages(library(dplyr))
base <- "target/HRG4+ 202425 National Costs Grouper/docs/_extract/HRG4+ 202425 National Costs Grouper Test Data and Expected Results v1.0/"
rd <- function(path) suppressWarnings(readr::read_csv(path, show_col_types = FALSE, col_types = readr::cols(.default = "c")))
files <- function(ds, suffix) list.files(paste0(base, ds), pattern = paste0(suffix, "$"), full.names = TRUE)[1]
drop_dummy <- function(df) df[names(df) != "dummy_field"]
ub_of <- function(ds) rd(files(ds, "_ub_rel.csv")) |> group_by(RowNo) |> summarise(unbundled = paste(UnbundledHRGs, collapse = ","), .groups = "drop")

# APC
fce <- rd(files("APC", "Expected Results_FCE.csv"))
input_cols <- names(fce)[seq_len(which(names(fce) == "RowNo") - 1)]
apc <- list(
  episodes = fce[input_cols],
  expected = fce |>
    select(RowNo, FCE_HRG, GroupingMethodFlag, DominantProcedure, FCE_PBC, CalcEpidur, SpellReportFlag,
           SpellHRG, SpellGroupingMethodFlag, SpellDominantProcedure, SpellPDiag, SpellSDiag,
           SpellEpisodeCount, SpellLOS) |>
    left_join(ub_of("APC"), by = "RowNo") |>
    mutate(unbundled = coalesce(unbundled, ""))
)
nac_exp <- rd(files("NAC", "Expected Results_attend.csv")) |> left_join(ub_of("NAC"), by = "RowNo") |> mutate(unbundled = coalesce(unbundled, ""))
fixture <- list(
  version = "2024-25-nc",
  episodes = apc$episodes, expected = apc$expected,
  nac = list(input = drop_dummy(rd(files("NAC", "Sample Test Data.csv"))),
             expected = nac_exp |> select(NAC_HRG, GroupingMethodFlag, DominantProcedure, unbundled)),
  em = list(input = drop_dummy(rd(files("EM", "Sample Test Data.csv"))),
            expected = rd(files("EM", "Expected Results_attend.csv")) |> select(EM_HRG)),
  acc = list(input = drop_dummy(rd(files("ACC", "Sample Test Data.csv"))),
             expected = rd(files("ACC", "Expected Results_acc.csv")) |> select(ACC_HRG, Calc_CC_Days, CC_Warning_Flag)),
  nrd = list(input = drop_dummy(rd(files("NRD", "Sample Test Data.csv"))),
             expected = rd(files("NRD", "Expected Results_renal.csv")) |> select(NRD_HRG)),
  pcc = list(input = drop_dummy(rd(files("PCC", "Sample Test Data.csv"))),
             expected = rd(files("PCC", "Expected Results_pcc.csv")) |> select(PCC_HRG)),
  ncc = list(input = drop_dummy(rd(files("NCC", "Sample Test Data.csv"))),
             expected = rd(files("NCC", "Expected Results_ncc.csv")) |> select(NCC_HRG))
)
out <- "tests/testthat/fixtures/hrg_2024-25-nc.rds"
saveRDS(fixture, out, compress = "xz")
file.remove("tests/testthat/fixtures/hrg_2024-25-nc_apc.rds")
cat("Wrote", out, "(", round(file.size(out) / 1024), "KB )\n")
