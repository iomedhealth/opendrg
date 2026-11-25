# Feasibility trial: group a sample of inpatient stays from a live OMOP CDM
# (PostgreSQL, `cdm` + `vocabularies` schemas) with opendrg's MS-DRG engine,
# taking every coded diagnosis in turn as the principal diagnosis. Read-only;
# only aggregates are printed, nothing patient-level is written to disk.
#
#   OPENDRG_OMOP_HOST=<host> OPENDRG_OMOP_VAULT_ROLE=<vault db role> \
#     Rscript dev/omop-site-trial.R [n_stays] [from_year]

suppressPackageStartupMessages({
  pkgload::load_all(".", quiet = TRUE)
  library(DBI)
  library(dplyr)
})
args <- commandArgs(trailingOnly = TRUE)
n_stays <- if (length(args) >= 1) as.integer(args[[1]]) else 3000L
from_year <- if (length(args) >= 2) as.integer(args[[2]]) else 2023L

host <- Sys.getenv("OPENDRG_OMOP_HOST")
role <- Sys.getenv("OPENDRG_OMOP_VAULT_ROLE")
if (host == "" || role == "") stop("Set OPENDRG_OMOP_HOST and OPENDRG_OMOP_VAULT_ROLE.")
creds <- jsonlite::fromJSON(system(paste("vault read -format=json", role), intern = TRUE))$data
con <- dbConnect(RPostgres::Postgres(), host = host, port = 5432,
                 dbname = Sys.getenv("OPENDRG_OMOP_DB", "iomed"), user = creds$username, password = creds$password)
on.exit(dbDisconnect(con))
dbExecute(con, "SET statement_timeout = '300s'")

# --- 1. sample of inpatient stays with at least one ICD-10-CM coded diagnosis
stays <- dbGetQuery(con, sprintf("
  with v as (
    select v.visit_occurrence_id, v.person_id, v.visit_start_date, v.visit_end_date,
           v.discharged_to_source_value, p.year_of_birth, p.gender_concept_id
    from cdm.visit_occurrence v join cdm.person p using (person_id)
    where v.visit_concept_id = 9201 and v.visit_start_date >= '%d-01-01'
      and exists (select 1 from cdm.condition_occurrence co
                  join vocabularies.concept c on c.concept_id = co.condition_source_concept_id
                  where co.visit_occurrence_id = v.visit_occurrence_id and c.vocabulary_id = 'ICD10CM')
    order by random() limit %d)
  select v.*, exists (select 1 from cdm.death d where d.person_id = v.person_id
                      and d.death_date between v.visit_start_date and v.visit_end_date) as died
  from v", from_year, n_stays))
ids <- paste(stays$visit_occurrence_id, collapse = ",")

dx <- dbGetQuery(con, sprintf("
  select co.visit_occurrence_id, c.concept_code as code
  from cdm.condition_occurrence co join vocabularies.concept c on c.concept_id = co.condition_source_concept_id
  where co.visit_occurrence_id in (%s) and c.vocabulary_id = 'ICD10CM' and co.condition_type_concept_id = 32817
  group by 1, 2", ids))
pr <- dbGetQuery(con, sprintf("
  select po.visit_occurrence_id, c.concept_code as code, c.vocabulary_id, min(po.procedure_date) as procedure_date
  from cdm.procedure_occurrence po join vocabularies.concept c on c.concept_id = po.procedure_concept_id
  where po.visit_occurrence_id in (%s) and c.vocabulary_id in ('ICD10PCS')
  group by 1, 2, 3", ids))

# --- 2. build MS-DRG inputs. Discharge: death table first, then the site's own
#        discharge list (code 5 observed to be exitus at this site); else home.
claims <- stays |>
  transmute(
    stay = visit_occurrence_id,
    age = as.integer(format(visit_start_date, "%Y")) - year_of_birth,
    sex = case_when(gender_concept_id == 8507 ~ 1L, gender_concept_id == 8532 ~ 2L, TRUE ~ 0L),
    discharge_status = case_when(died | discharged_to_source_value == "5" ~ "20",
                                 discharged_to_source_value == "2" ~ "02",
                                 discharged_to_source_value == "3" ~ "07",
                                 TRUE ~ "01"),
    los = as.integer(visit_end_date - visit_start_date)
  )
dx <- dx |> mutate(code = msdrg_normalize_code(code)) |> distinct(visit_occurrence_id, code)
pr <- pr |> mutate(code = msdrg_normalize_code(code)) |> arrange(visit_occurrence_id, procedure_date, code)

# Every coded diagnosis takes a turn as the principal: one claim per candidate.
cand <- dx |> group_by(visit_occurrence_id) |> mutate(k = row_number(), n_dx = n()) |> ungroup()
claims_all <- cand |> select(stay = visit_occurrence_id, k, n_dx) |>
  inner_join(claims, by = "stay") |> mutate(claim_id = paste(stay, k, sep = "#"))
diagnoses_all <- cand |> select(stay = visit_occurrence_id, k, principal = code) |>
  inner_join(dx |> rename(stay = visit_occurrence_id), by = "stay", relationship = "many-to-many") |>
  mutate(claim_id = paste(stay, k, sep = "#")) |>
  group_by(claim_id) |> arrange(code != principal, code, .by_group = TRUE) |> mutate(seq = row_number()) |> ungroup() |>
  select(claim_id, seq, code)
procedures_all <- claims_all |> select(claim_id, stay) |>
  inner_join(pr |> rename(stay = visit_occurrence_id), by = "stay", relationship = "many-to-many") |>
  group_by(claim_id) |> mutate(seq = row_number()) |> ungroup() |> select(claim_id, seq, code)

t0 <- Sys.time()
out <- msdrg_group(claims_all |> select(claim_id, age, sex, discharge_status), diagnoses_all, procedures_all,
                   tables = msdrg_tables("44.0"), poa_exempt = "exempt")
secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
res <- claims_all |> select(claim_id, stay, k, n_dx, los) |> inner_join(out, by = "claim_id")

# --- 3. aggregates only
cat(sprintf("\nInpatient stays sampled (>= %d): %d; coded diagnoses per stay: median %d, mean %.1f; stays with ICD-10-PCS: %d (%.1f%%)\n",
            from_year, nrow(stays), median(cand$n_dx[cand$k == 1]), mean(cand$n_dx[cand$k == 1]),
            n_distinct(pr$visit_occurrence_id), 100 * n_distinct(pr$visit_occurrence_id) / nrow(stays)))
cat(sprintf("Candidate claims grouped: %d in %.1f s (%.0f/s)\n", nrow(out), secs, nrow(out) / secs))
cat("\nReturn codes over candidate claims:\n"); print(table(res$return_code))
cat("\nDischarge status used:\n"); print(table(claims$discharge_status))

per_stay <- res |> filter(return_code == 0) |> group_by(stay, n_dx, los) |>
  summarise(n_cand = n(), n_drg = n_distinct(drg), n_base = n_distinct(base_drg), n_mdc = n_distinct(mdc),
            any_surg = any(med_surg == "S"), modal_drg = names(which.max(table(drg))),
            modal_share = max(table(drg)) / n(), .groups = "drop")
cat(sprintf("\nStays with >= 1 groupable candidate: %d / %d\n", nrow(per_stay), nrow(stays)))
cat(sprintf("Stays where every candidate principal gives the same DRG: %.1f%%; same base DRG: %.1f%%; same MDC: %.1f%%\n",
            100 * mean(per_stay$n_drg == 1), 100 * mean(per_stay$n_base == 1), 100 * mean(per_stay$n_mdc == 1)))
cat(sprintf("Mean share of candidates agreeing with the modal DRG: %.2f; stays with any surgical candidate: %.1f%%\n",
            mean(per_stay$modal_share), 100 * mean(per_stay$any_surg)))
cat("\nDistinct MDCs per stay:\n"); print(table(per_stay$n_mdc))
cat("\nModal DRGs (top 15):\n")
print(res |> filter(return_code == 0) |>
        inner_join(per_stay |> select(stay, modal_drg), by = "stay") |> filter(drg == as.integer(modal_drg)) |>
        distinct(stay, drg, drg_description, med_surg) |> count(drg, med_surg, drg_description, sort = TRUE) |> head(15) |> as.data.frame())
cat("\nMDC of modal DRG:\n")
print(res |> filter(return_code == 0) |> inner_join(per_stay |> select(stay, modal_drg), by = "stay") |>
        filter(drg == as.integer(modal_drg)) |> distinct(stay, mdc, mdc_description) |> count(mdc, mdc_description, sort = TRUE) |> head(10) |> as.data.frame())
cat("\nLOS by severity of modal DRG (median days):\n")
print(res |> filter(return_code == 0) |> inner_join(per_stay |> select(stay, modal_drg), by = "stay") |>
        filter(drg == as.integer(modal_drg)) |> distinct(stay, severity, los) |> group_by(severity) |>
        summarise(stays = n(), median_los = median(los), mean_los = round(mean(los), 1)) |> as.data.frame())
cat("\nPrincipal codes behind non-zero return codes (top 8 each):\n")
print(res |> filter(return_code != 0) |> inner_join(diagnoses_all |> filter(seq == 1) |> select(claim_id, principal = code), by = "claim_id") |>
        count(return_code, principal, sort = TRUE) |> group_by(return_code) |> slice_head(n = 8) |> as.data.frame())
