# Proof-of-concept ("hot ETL"): enrich one calendar year of OMOP CDM inpatient
# stays in memory from the hospital's raw coding tables (primary/secondary flag,
# clean CIE-10-ES diagnosis/procedure codes, site discharge lookup) without
# modifying the database, run opendrg::omop_msdrg(..., principal = "status"),
# and evaluate concordance against the hospital's official APR-GRD weights.
# Strictly read-only; prints aggregate summaries only (no patient-level output).
#
#   OPENDRG_OMOP_HOST=<host> OPENDRG_OMOP_VAULT_ROLE=database/creds/<role> \
#     Rscript dev/omop-hot-etl-trial.R [year]
# Or:
#   OPENDRG_OMOP_HOST=<host> OPENDRG_OMOP_USER=<user> \
#     Rscript dev/omop-hot-etl-trial.R [year]

suppressPackageStartupMessages({
  pkgload::load_all(".", quiet = TRUE)
  library(DBI)
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
if (host == "") stop("Set OPENDRG_OMOP_HOST (and OPENDRG_OMOP_VAULT_ROLE or OPENDRG_OMOP_USER).")

if (role != "") {
  creds <- jsonlite::fromJSON(system(paste("vault read -format=json", shQuote(role)), intern = TRUE))$data
  con <- dbConnect(RPostgres::Postgres(), host = host, port = 5432, dbname = dbname,
                   user = creds$username, password = creds$password)
} else if (user != "") {
  con <- dbConnect(RPostgres::Postgres(), host = host, port = 5432, dbname = dbname, user = user)
} else {
  stop("Set either OPENDRG_OMOP_VAULT_ROLE or OPENDRG_OMOP_USER.")
}
on.exit(dbDisconnect(con), add = TRUE)
invisible(dbExecute(con, "SET default_transaction_read_only = on"))
invisible(dbExecute(con, "SET statement_timeout = '120s'"))

t0 <- Sys.time()
stays <- dbGetQuery(con, sprintf("
  SELECT v.visit_occurrence_id, v.person_id, v.visit_concept_id,
         v.visit_start_date, v.visit_end_date,
         v.visit_source_value, v.discharged_to_source_value,
         p.gender_concept_id, p.year_of_birth, p.month_of_birth, p.day_of_birth, p.birth_datetime
  FROM cdm.visit_occurrence v
  JOIN cdm.person p USING (person_id)
  WHERE v.visit_concept_id = 9201
    AND v.visit_start_date >= '%s' AND v.visit_start_date <= '%s'
", start_date, end_date))

deaths <- dbGetQuery(con, sprintf("
  SELECT DISTINCT d.person_id, d.death_date
  FROM cdm.death d
  JOIN cdm.visit_occurrence v USING (person_id)
  WHERE v.visit_concept_id = 9201
    AND v.visit_start_date >= '%s' AND v.visit_start_date <= '%s'
", start_date, end_date))

# Official CIE-10-ES code: codigo_2 strips hospital-local sub-extensions (e.g.
# C67.9XXX.0 -> C67.9); fall back to codigo_1 when codigo_2 is blank.
raw_coding <- dbGetQuery(con, sprintf("
  WITH v_yr AS (
    SELECT visit_occurrence_id, person_id, visit_start_date,
           visit_source_value::bigint AS ep_num
    FROM cdm.visit_occurrence
    WHERE visit_concept_id = 9201
      AND visit_start_date >= '%s' AND visit_start_date <= '%s'
      AND visit_source_value ~ '^[0-9]+$'
  )
  SELECT v_yr.visit_occurrence_id, v_yr.person_id, v_yr.visit_start_date,
         c.codigo AS coding_id, c.orden, c.tipo_diag, c.dpi, c.fecha_proc,
         d.seccion,
         COALESCE(NULLIF(TRIM(d.codigo_2), ''), TRIM(d.codigo_1)) AS cie10_code
  FROM v_yr
  JOIN raw.cod_codifepi c ON c.episodio = v_yr.ep_num
  JOIN raw.cod_diccionario d ON d.codigo = c.codigoelemento
  WHERE d.catalogo = 10
", start_date, end_date))

fac <- dbGetQuery(con, sprintf("
  WITH v_yr AS (
    SELECT visit_occurrence_id, visit_source_value::bigint AS ep_num
    FROM cdm.visit_occurrence
    WHERE visit_concept_id = 9201
      AND visit_start_date >= '%s' AND visit_start_date <= '%s'
      AND visit_source_value ~ '^[0-9]+$'
  )
  SELECT v_yr.visit_occurrence_id, f.cod_grd, f.num_pesogrd, f.cod_cdm, f.cod_exitus
  FROM v_yr
  JOIN raw.fac_epihosp f ON f.cod_episodiohcis = v_yr.ep_num
", start_date, end_date))

tbls <- msdrg_tables("44.0")

dx_rows <- raw_coding |>
  filter(seccion %in% c("D", "E")) |>
  mutate(is_primary = tipo_diag == "P") |>
  arrange(visit_occurrence_id, desc(is_primary), orden, coding_id) |>
  group_by(visit_occurrence_id) |>
  mutate(condition_status_concept_id = if_else(is_primary & row_number() == 1L, 32902L, 32908L)) |>
  ungroup()

pr_rows <- raw_coding |>
  filter(seccion == "P") |>
  mutate(
    norm_code = msdrg_normalize_code(cie10_code),
    is_pcs = norm_code %in% tbls$pr_codes$code
  )

cat(sprintf("Pulled %d stays (%d) in %.1f s | Raw procedures: %d rows across %d stays; valid ICD-10-PCS: %d (%.1f%%) across %d stays (%.1f%%)\n",
            nrow(stays), year, as.numeric(difftime(Sys.time(), t0, units = "secs")),
            nrow(pr_rows), n_distinct(pr_rows$visit_occurrence_id),
            sum(pr_rows$is_pcs), 100 * mean(pr_rows$is_pcs),
            n_distinct(pr_rows$visit_occurrence_id[pr_rows$is_pcs]),
            100 * n_distinct(pr_rows$visit_occurrence_id[pr_rows$is_pcs]) / nrow(stays)))

dx_vocab <- tibble(code = unique(na.omit(dx_rows$cie10_code))) |>
  mutate(concept_id = seq_len(n()), vocabulary_id = "ICD10CM", concept_code = code)
pr_vocab <- tibble(code = unique(na.omit(pr_rows$cie10_code[pr_rows$is_pcs]))) |>
  mutate(concept_id = nrow(dx_vocab) + seq_len(n()), vocabulary_id = "ICD10PCS", concept_code = code)
concept_hot <- bind_rows(
  dx_vocab |> select(concept_id, vocabulary_id, concept_code),
  pr_vocab |> select(concept_id, vocabulary_id, concept_code)
)

# Discharge mapping verified against raw.adm_destinoalta (5 = exitus, 6 = fuga, 7 = H2M)
visit_hot <- stays |>
  mutate(
    discharged_to_concept_id = case_when(
      discharged_to_source_value == "5" ~ 4216643L,
      discharged_to_source_value == "2" ~ 9201L,
      discharged_to_source_value %in% c("3", "6") ~ 4021968L,
      discharged_to_source_value == "7" ~ 38004519L,
      discharged_to_source_value %in% c("1", "4") ~ 8536L,
      TRUE ~ 0L
    )
  ) |>
  select(visit_occurrence_id, person_id, visit_concept_id, visit_start_date, visit_end_date,
         discharged_to_concept_id, discharged_to_source_value)

person_hot <- stays |>
  distinct(person_id, .keep_all = TRUE) |>
  select(person_id, gender_concept_id, year_of_birth, month_of_birth, day_of_birth, birth_datetime)

cond_hot <- dx_rows |>
  left_join(dx_vocab |> select(cie10_code = code, condition_source_concept_id = concept_id), by = "cie10_code") |>
  transmute(
    condition_occurrence_id = coding_id, person_id, visit_occurrence_id,
    condition_concept_id = 0L,
    condition_source_concept_id = coalesce(condition_source_concept_id, 0L),
    condition_status_concept_id, condition_type_concept_id = 32817L,
    condition_start_date = visit_start_date
  )

proc_hot <- pr_rows |>
  left_join(pr_vocab |> select(cie10_code = code, procedure_concept_id = concept_id), by = "cie10_code") |>
  transmute(
    procedure_occurrence_id = coding_id, person_id, visit_occurrence_id,
    procedure_concept_id = coalesce(procedure_concept_id, 0L),
    procedure_source_concept_id = 0L,
    procedure_date = coalesce(suppressWarnings(as.Date(fecha_proc)), visit_start_date)
  )

cdm_hot <- list(
  person = person_hot, visit_occurrence = visit_hot,
  condition_occurrence = cond_hot, procedure_occurrence = proc_hot,
  death = deaths, concept = concept_hot
)
attr(cdm_hot, "cdm_name") <- sprintf("site_%d_hot_etl", year)

t1 <- Sys.time()
res_hot <- omop_msdrg(cdm_hot, tables = tbls, principal = "status")
cat(sprintf("\nomop_msdrg(..., principal = 'status') completed in %.1f s\n",
            as.numeric(difftime(Sys.time(), t1, units = "secs"))))
print(omop_msdrg_quality(res_hot))

cat("\nTop 15 MS-DRGs (RC 0):\n")
print(
  res_hot |>
    filter(return_code == 0L) |>
    count(drg, med_surg, drg_description, sort = TRUE) |>
    head(15) |>
    as.data.frame()
)

cat("\nLOS by MS-DRG severity (RC 0):\n")
print(
  res_hot |>
    filter(return_code == 0L) |>
    group_by(severity) |>
    summarise(stays = n(), median_los = median(los, na.rm = TRUE), mean_los = round(mean(los, na.rm = TRUE), 1), .groups = "drop") |>
    as.data.frame()
)

joined_apr <- res_hot |>
  filter(return_code == 0L) |>
  inner_join(fac |> filter(!is.na(num_pesogrd)), by = "visit_occurrence_id")

if (nrow(joined_apr) > 0L) {
  cat(sprintf("\n=== Concordance with official hospital APR-GRD (n = %d matched stays) ===\n", nrow(joined_apr)))
  print(
    joined_apr |>
      group_by(med_surg, severity) |>
      summarise(
        stays = n(),
        mean_apr_weight = round(mean(num_pesogrd), 3),
        median_apr_weight = round(median(num_pesogrd), 3),
        median_los = median(los, na.rm = TRUE),
        .groups = "drop"
      ) |>
      as.data.frame()
  )
  cat(sprintf("R^2 of log(APR weight) explained by opendrg MS-DRG: %.3f\n",
              summary(lm(log(num_pesogrd + 0.01) ~ factor(drg), data = joined_apr))$r.squared))
  cat(sprintf("R^2 of log(LOS + 1) explained by opendrg MS-DRG:    %.3f (vs hospital APR-GRD: %.3f)\n",
              summary(lm(log(pmax(los, 0) + 1) ~ factor(drg), data = joined_apr))$r.squared,
              summary(lm(log(pmax(los, 0) + 1) ~ factor(cod_grd), data = joined_apr))$r.squared))
}
