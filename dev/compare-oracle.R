# Compare opengrd's MS-DRG output with the CMS Java oracle over TESTDB.
#
# Usage: Rscript dev/compare-oracle.R [n_claims|all] [version]

args <- commandArgs(trailingOnly = TRUE)
n_claims <- if (length(args) >= 1 && args[[1]] != "all") as.integer(args[[1]]) else NA
version <- if (length(args) >= 2) args[[2]] else "44.0"

suppressPackageStartupMessages({
  pkgload::load_all(".", quiet = TRUE)
  library(dplyr)
})

dir <- "dev/oracle/output"
inp <- readr::read_csv(file.path(dir, "testdb_v440_input.csv"), show_col_types = FALSE, guess_max = 1e5)
dx <- readr::read_csv(file.path(dir, "testdb_v440_input_dx.csv"), show_col_types = FALSE, col_types = readr::cols(.default = "c", claim_id = "i", seq = "i"))
pr <- readr::read_csv(file.path(dir, "testdb_v440_input_pr.csv"), show_col_types = FALSE, col_types = readr::cols(.default = "c", claim_id = "i", seq = "i"))
prefix <- paste0("testdb_v", gsub(".", "", version, fixed = TRUE))
exp <- readr::read_csv(file.path(dir, paste0(prefix, "_expected.csv")), show_col_types = FALSE, guess_max = 1e5)

if (!is.na(n_claims)) {
  keep <- head(inp$claim_id, n_claims)
  inp <- inp[inp$claim_id %in% keep, ]
  dx <- dx[dx$claim_id %in% keep, ]
  pr <- pr[pr$claim_id %in% keep, ]
  exp <- exp[exp$claim_id %in% keep, ]
}

claims <- inp |> transmute(claim_id, age, sex = sex_raw, discharge_status = discharge_status_raw)
diagnoses <- dx |> transmute(claim_id, seq = seq + 1L, code, poa)
procedures <- pr |> transmute(claim_id, seq, code)

t0 <- Sys.time()
got <- msdrg_group(claims, diagnoses, procedures, tables = msdrg_tables(version), poa_exempt = "non_exempt")
elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
cat(sprintf("Grouped %d claims in %.1f s (%.0f claims/s)\n", nrow(got), elapsed, nrow(got) / elapsed))

cmp <- exp |>
  select(claim_id, exp_drg = final_drg, exp_initial_drg = initial_drg, exp_mdc = final_mdc,
         exp_rc = final_grc, exp_sev = final_severity, exp_ms = final_med_surg) |>
  inner_join(got, by = "claim_id") |>
  mutate(
    sev = coalesce(severity, "NONE"),
    exp_sev = recode(exp_sev, NON_CC = "NCC"),
    ok_drg = drg == exp_drg,
    ok_initial = initial_drg == exp_initial_drg,
    ok_mdc = mdc == exp_mdc,
    ok_rc = return_code == exp_rc,
    ok_sev = sev == exp_sev
  )

summ <- cmp |> summarise(across(starts_with("ok_"), ~ mean(.x, na.rm = TRUE)), n = n())
print(summ)

bad <- cmp |> filter(!ok_drg | !ok_initial | !ok_mdc | !ok_rc | is.na(ok_drg))
cat(sprintf("\nMismatching claims: %d of %d\n", nrow(bad), nrow(cmp)))
if (nrow(bad) > 0) {
  print(bad |> count(exp_drg, drg, exp_mdc, mdc, sort = TRUE) |> head(25), n = 25)
  cat("\nSample mismatches:\n")
  print(bad |> select(claim_id, exp_drg, drg, exp_initial_drg, initial_drg, exp_mdc, mdc, exp_rc, return_code, exp_sev, sev, formula) |> head(15), width = 200)
}
readr::write_csv(cmp, file.path(dir, paste0("opengrd_vs_oracle_", prefix, ".csv")))
