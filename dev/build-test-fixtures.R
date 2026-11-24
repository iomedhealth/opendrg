# Build the testthat fixture for the MS-DRG engine from the CMS oracle run
# (dev/oracle/). TESTDB is CMS public-domain test data; expected results come
# from CMS's own Java grouper (see dev/oracle/README.md).

suppressPackageStartupMessages(library(dplyr))
dir <- "dev/oracle/output"

inp <- readr::read_csv(file.path(dir, "testdb_v440_input.csv"), show_col_types = FALSE, guess_max = 1e5)
dx <- readr::read_csv(file.path(dir, "testdb_v440_input_dx.csv"), show_col_types = FALSE,
                      col_types = readr::cols(.default = "c", claim_id = "i", seq = "i"))
pr <- readr::read_csv(file.path(dir, "testdb_v440_input_pr.csv"), show_col_types = FALSE,
                      col_types = readr::cols(.default = "c", claim_id = "i", seq = "i"))
exp <- readr::read_csv(file.path(dir, "testdb_v440_expected.csv"), show_col_types = FALSE, guess_max = 1e5)

fixture <- list(
  version = "44.0",
  claims = inp |> transmute(claim_id = as.integer(claim_id), age = as.integer(age), sex = as.integer(sex_raw),
                            discharge_status = discharge_status_raw, hospital_poa_status),
  diagnoses = dx |> transmute(claim_id, seq = seq + 1L, code, poa),
  procedures = pr |> transmute(claim_id, seq, code),
  expected = exp |> transmute(
    claim_id = as.integer(claim_id),
    drg = as.integer(final_drg), initial_drg = as.integer(initial_drg),
    mdc = as.integer(final_mdc), return_code = as.integer(final_grc),
    severity = recode(final_severity, NON_CC = "NCC", NONE = NA_character_),
    initial_severity = recode(initial_severity, NON_CC = "NCC", NONE = NA_character_),
    med_surg = recode(final_med_surg, SURGICAL = "S", MEDICAL = "M", NONE = NA_character_)
  )
)
# Other bundled versions: expected results from the same harness run with
# --version, sampled to keep the test-suite quick.
set.seed(20261124)
sample_ids <- sort(sample(fixture$claims$claim_id, 2000))
fixture$other_versions <- lapply(c("43.1", "43.0"), function(v) {
  prefix <- paste0("testdb_v", gsub(".", "", v, fixed = TRUE))
  e <- readr::read_csv(file.path(dir, paste0(prefix, "_expected.csv")), show_col_types = FALSE, guess_max = 1e5)
  e |> filter(claim_id %in% sample_ids) |> transmute(
    claim_id = as.integer(claim_id), drg = as.integer(final_drg), initial_drg = as.integer(initial_drg),
    mdc = as.integer(final_mdc), return_code = as.integer(final_grc),
    severity = recode(final_severity, NON_CC = "NCC", NONE = NA_character_)
  )
})
names(fixture$other_versions) <- c("43.1", "43.0")

out <- "tests/testthat/fixtures/msdrg_v440_testdb.rds"
dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
saveRDS(fixture, out, compress = "xz")
cat("Wrote", out, "(", round(file.size(out) / 1024), "KB ) with", nrow(fixture$claims), "claims\n")
