# Build the testthat fixture for the Prescribed Specialised Services engine
# from NHS England's official PSO sample data and expected results (Open
# Government Licence v3.0).

suppressPackageStartupMessages(library(dplyr))
base <- "target/Prescribed Services 2025:26 Operational Tool (PSO) - updated/docs/_extract/PS 202526 Operational Tool Sample Data and Expected Results v1.0/"
rd <- function(path) suppressWarnings(readr::read_csv(path, show_col_types = FALSE, col_types = readr::cols(.default = "c")))
quality_of <- function(path) {
  rd(path) |>
    group_by(RowNo) |>
    summarise(quality = paste(`Code Type`, coalesce(Code, ""), `Error Message`, sep = "|", collapse = ";"), .groups = "drop")
}

fce <- rd(paste0(base, "APC Sample Data/PS 202526 Operational Tool APC Expected Results_FCE.csv"))
apc_cols <- names(fce)[seq_len(which(names(fce) == "RowNo") - 1)]
apc_q <- quality_of(paste0(base, "APC Sample Data/PS 202526 Operational Tool APC Expected Results_quality_rel.csv"))
att <- rd(paste0(base, "NAC Sample Data/PS 202526 Operational Tool NAC Expected Results_attend.csv"))
nac_cols <- names(att)[seq_len(which(names(att) == "RowNo") - 1)]
nac_q <- quality_of(paste0(base, "NAC Sample Data/PS 202526 Operational Tool NAC Expected Results_quality_rel.csv"))

fixture <- list(
  version = "2025-26",
  apc = list(
    input = fce[apc_cols],
    expected = fce |>
      select(RowNo, FCE_NPOC, ServiceLine, ServiceLineList, SpellNPOC, SpellServiceLine) |>
      left_join(apc_q, by = "RowNo") |>
      mutate(quality = coalesce(quality, "")),
    spells = rd(paste0(base, "APC Sample Data/PS 202526 Operational Tool APC Expected Results_spell.csv"))
  ),
  nac = list(
    input = att[nac_cols],
    expected = att |>
      select(RowNo, NPOC, ServiceLine) |>
      left_join(nac_q, by = "RowNo") |>
      mutate(quality = coalesce(quality, ""))
  )
)
out <- "tests/testthat/fixtures/pso_2025-26.rds"
saveRDS(fixture, out, compress = "xz")
cat("Wrote", out, "(", round(file.size(out) / 1024), "KB )\n")
