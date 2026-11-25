# Compare opendrg's Prescribed Specialised Services flags with the expected
# results NHS England ships with the PSO 2025/26 Operational Tool.

suppressPackageStartupMessages({
  pkgload::load_all(".", quiet = TRUE)
  library(dplyr)
})
options(width = 220)
args <- commandArgs(trailingOnly = TRUE)
version <- if (length(args) >= 1) args[[1]] else "2025-26"
base <- "target/Prescribed Services 2025:26 Operational Tool (PSO) - updated/docs/_extract/PS 202526 Operational Tool Sample Data and Expected Results v1.0/"
rd <- function(path) suppressWarnings(readr::read_csv(path, show_col_types = FALSE, col_types = readr::cols(.default = "c")))
tbls <- pso_tables(version)

report <- function(name, got, exp, cols) {
  cat(sprintf("\n=== %s: %d rows\n", name, nrow(exp)))
  for (nm in names(cols)) {
    g <- coalesce(as.character(got[[nm]]), ""); e <- coalesce(exp[[cols[[nm]]]], "")
    ok <- g == e
    cat(sprintf("  %-20s %5.1f%%  (%d mismatches)\n", nm, 100 * mean(ok), sum(!ok)))
    if (any(!ok)) print(head(tibble(row = which(!ok), expected = e[!ok], got = g[!ok]), 10))
  }
}
quality_report <- function(name, got, qrel) {
  exp <- qrel |> group_by(RowNo) |> summarise(q = paste(`Code Type`, coalesce(Code, ""), `Error Message`, sep = "|", collapse = ";"), .groups = "drop")
  g <- tibble(RowNo = as.character(got$row), got = got$quality) |> left_join(exp, by = "RowNo") |> mutate(q = coalesce(q, ""))
  ok <- g$got == g$q
  cat(sprintf("  %-20s %5.1f%%  (%d mismatches)\n", paste(name, "quality"), 100 * mean(ok), sum(!ok)))
  if (any(!ok)) print(head(g[!ok, ], 10))
}

# APC: the expected FCE file is in the tool's sorted order; feed it as-is.
fce <- rd(paste0(base, "APC Sample Data/PS 202526 Operational Tool APC Expected Results_FCE.csv"))
input_cols <- names(fce)[seq_len(which(names(fce) == "RowNo") - 1)]
res <- pso_flag_apc(fce[input_cols], tables = tbls)
report("APC episodes", res$episodes, fce, c(fce_npoc = "FCE_NPOC", service_line = "ServiceLine", service_line_list = "ServiceLineList",
                                             spell_npoc = "SpellNPOC", spell_service_line = "SpellServiceLine"))
quality_report("APC", res$episodes, rd(paste0(base, "APC Sample Data/PS 202526 Operational Tool APC Expected Results_quality_rel.csv")))
spell_exp <- rd(paste0(base, "APC Sample Data/PS 202526 Operational Tool APC Expected Results_spell.csv"))
sp <- res$spells |> filter(!is.na(spell_service_line)) |> mutate(RowNo = as.character(first_row))
cat(sprintf("  spells with a service line: expected %d, got %d; identical: %s\n", nrow(spell_exp), nrow(sp),
            identical(sp$RowNo, spell_exp$RowNo) && identical(sp$spell_service_line, spell_exp$SpellServiceLine) && identical(sp$spell_npoc, spell_exp$SpellNPOC)))

# NAC
att <- rd(paste0(base, "NAC Sample Data/PS 202526 Operational Tool NAC Expected Results_attend.csv"))
input_cols <- names(att)[seq_len(which(names(att) == "RowNo") - 1)]
got <- pso_flag_nac(att[input_cols], tables = tbls)
report("NAC attendances", got, att, c(npoc = "NPOC", service_line = "ServiceLine"))
quality_report("NAC", got, rd(paste0(base, "NAC Sample Data/PS 202526 Operational Tool NAC Expected Results_quality_rel.csv")))
