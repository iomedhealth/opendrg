# End-to-end example: compute MS-DRGs directly from a live OMOP CDM via
# CDMConnector using opendrg::omop_msdrg() and group(grouper("msdrg"), cdm).
# Read-only; prints only aggregate summaries (no patient-level data is printed
# or written to disk).
#
# Connection via HashiCorp Vault (DSP Ops convention):
#   OPENDRG_OMOP_HOST=<host> OPENDRG_OMOP_VAULT_ROLE=database/creds/<role> \
#     Rscript dev/omop-cdm-example.R [year]
#
# Or via standard PostgreSQL credentials (~/.pgpass / PGPASSWORD):
#   OPENDRG_OMOP_HOST=<host> OPENDRG_OMOP_USER=<user> \
#     Rscript dev/omop-cdm-example.R [year]

suppressPackageStartupMessages({
  pkgload::load_all(".", quiet = TRUE)
  library(DBI)
  library(CDMConnector)
  library(dplyr)
})

args <- commandArgs(trailingOnly = TRUE)
year <- if (length(args) >= 1L) as.integer(args[[1]]) else 2024L
start_date <- sprintf("%04d-01-01", year)
end_date   <- sprintf("%04d-12-31", year)

host <- Sys.getenv("OPENDRG_OMOP_HOST")
role <- Sys.getenv("OPENDRG_OMOP_VAULT_ROLE")
user <- Sys.getenv("OPENDRG_OMOP_USER")
dbname <- Sys.getenv("OPENDRG_OMOP_DB", "iomed")
cdm_schema <- Sys.getenv("OPENDRG_OMOP_SCHEMA", "cdm")
cdm_name <- Sys.getenv("OPENDRG_OMOP_NAME", "omop_site")

if (host == "") stop("Set OPENDRG_OMOP_HOST (and OPENDRG_OMOP_VAULT_ROLE or OPENDRG_OMOP_USER).")

if (role != "") {
  creds <- jsonlite::fromJSON(system(paste("vault read -format=json", shQuote(role)), intern = TRUE))$data
  con <- dbConnect(
    RPostgres::Postgres(),
    host = host, port = 5432, dbname = dbname,
    user = creds$username, password = creds$password
  )
} else if (user != "") {
  con <- dbConnect(
    RPostgres::Postgres(),
    host = host, port = 5432, dbname = dbname,
    user = user
  )
} else {
  stop("Set either OPENDRG_OMOP_VAULT_ROLE or OPENDRG_OMOP_USER.")
}
on.exit(dbDisconnect(con), add = TRUE)
invisible(dbExecute(con, "SET default_transaction_read_only = on"))
invisible(dbExecute(con, "SET statement_timeout = '120s'"))

cdm <- suppressWarnings(cdmFromCon(con, cdmSchema = cdm_schema, cdmName = cdm_name))

# Site-specific discharged_to_source_value -> UB-04 mapping (e.g. code 5 = exitus
# at the Spanish urology-nephrology site profiled in dev/notes/omop-site-readiness.md).
site_discharge_map <- c("1" = "01", "2" = "02", "3" = "07", "5" = "20", "4" = "03", "6" = "06")

cat(sprintf("\n=== 1. Readiness check: principal = 'status' (%d inpatient stays) ===\n", year))
t0 <- Sys.time()
res_status <- omop_msdrg(
  cdm,
  tables = "44.0",
  start_date = start_date,
  end_date = end_date,
  discharge_map = site_discharge_map
)
cat(sprintf("Elapsed: %.1f s\n", as.numeric(difftime(Sys.time(), t0, units = "secs"))))
print(omop_msdrg_quality(res_status))

cat(sprintf("\n=== 2. Indication-cohort grouping: principal = 'codelist' (%d) ===\n", year))
# Major urology/nephrology inpatient conditions (ICD-10-CM prefixes).
index_codes <- c("C61", "C67", "C64", "N40", "N20", "N17", "N18", "N390", "N13")
t0 <- Sys.time()
g <- grouper("msdrg", version = "44.0")
res_codelist <- group(
  g, cdm,
  start_date = start_date,
  end_date = end_date,
  principal = "codelist",
  principal_codes = index_codes,
  unmatched = "drop",
  discharge_map = site_discharge_map
)
cat(sprintf("Elapsed: %.1f s\n", as.numeric(difftime(Sys.time(), t0, units = "secs"))))
print(omop_msdrg_quality(res_codelist))

cat("\nTop 10 MS-DRGs (codelist, RC 0):\n")
print(
  res_codelist |>
    filter(return_code == 0L) |>
    count(drg, med_surg, drg_description, sort = TRUE) |>
    head(10) |>
    as.data.frame()
)

cat("\nLength of stay by MS-DRG severity (codelist, RC 0):\n")
print(
  res_codelist |>
    filter(return_code == 0L) |>
    group_by(severity) |>
    summarise(
      stays = n(),
      median_los = median(los, na.rm = TRUE),
      mean_los = round(mean(los, na.rm = TRUE), 1),
      .groups = "drop"
    ) |>
    as.data.frame()
)

cat(sprintf("\n=== 3. Sensitivity analysis: principal = 'all' (%d, n_max = 1000) ===\n", year))
t0 <- Sys.time()
res_all <- omop_msdrg(
  cdm,
  tables = "44.0",
  start_date = start_date,
  end_date = end_date,
  n_max = 1000L,
  principal = "all",
  discharge_map = site_discharge_map
)
cat(sprintf("Elapsed: %.1f s\n", as.numeric(difftime(Sys.time(), t0, units = "secs"))))
print(omop_msdrg_quality(res_all))

per_stay <- res_all |>
  filter(return_code == 0L) |>
  group_by(visit_occurrence_id) |>
  summarise(
    n_cand = n(),
    n_drg = n_distinct(drg),
    n_base = n_distinct(base_drg),
    n_mdc = n_distinct(mdc),
    .groups = "drop"
  )
cat(sprintf(
  "Stays with >= 1 groupable candidate: %d / 1,000; identical DRG: %.1f%%; identical base DRG: %.1f%%; identical MDC: %.1f%%\n",
  nrow(per_stay),
  100 * mean(per_stay$n_drg == 1L),
  100 * mean(per_stay$n_base == 1L),
  100 * mean(per_stay$n_mdc == 1L)
))
