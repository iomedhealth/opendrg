make_synthetic_omop_tables <- function() {
  person <- tibble::tibble(
    person_id = c(1L, 2L, 3L, 4L, 5L),
    gender_concept_id = c(8507L, 8532L, 8507L, 8532L, 8507L),
    year_of_birth = c(1957L, 1948L, 1970L, 1994L, 1955L),
    month_of_birth = c(3L, 8L, NA_integer_, 6L, 1L),
    day_of_birth = c(15L, 20L, NA_integer_, 30L, 10L),
    birth_datetime = as.POSIXct(c(
      "1957-03-15 00:00:00", "1948-08-20 00:00:00", NA,
      "1994-06-30 00:00:00", "1955-01-10 00:00:00"
    ), tz = "UTC"),
    race_concept_id = 0L,
    ethnicity_concept_id = 0L
  )

  observation_period <- tibble::tibble(
    observation_period_id = 1:5,
    person_id = 1:5,
    observation_period_start_date = as.Date("2020-01-01"),
    observation_period_end_date = as.Date("2025-12-31"),
    period_type_concept_id = 32817L
  )

  visit_occurrence <- tibble::tibble(
    visit_occurrence_id = c(101L, 102L, 103L, 104L, 105L, 106L),
    person_id = c(1L, 2L, 3L, 4L, 5L, 1L),
    visit_concept_id = c(9201L, 9201L, 262L, 9201L, 9201L, 9202L), # 106 is outpatient
    visit_start_date = as.Date(c(
      "2024-05-02", "2024-06-10", "2024-07-01",
      "2024-08-15", "2024-09-01", "2024-05-20"
    )),
    visit_end_date = as.Date(c(
      "2024-05-06", "2024-06-14", "2024-07-03",
      "2024-08-17", "2024-09-05", "2024-05-20"
    )),
    visit_type_concept_id = 32817L,
    discharged_to_concept_id = c(8536L, 0L, 4021968L, 32210L, 0L, 0L),
    discharged_to_source_value = c("1", "5", "3", "1", NA_character_, "1")
  )

  # Visit 101: AMI (I21.4) + E11.9 + N17.9 + PCI (02703ZZ) -> DRG 251
  # Visit 102: AMI (I21.4) + N17.9, died (death table + site code "5") -> DRG 284
  # Visit 103: Alcohol dependence (F10.20), left AMA (concept 4021968 -> "07") -> DRG 894
  # Visit 104: Vaginal delivery (O80) + Z37.0 + delivery proc (10E0XZZ via source concept) -> DRG 807
  # Visit 105: Category header N18 + valid N18.6 + I10 + unrecognised ZZZ999 + NLP row (32858)
  condition_occurrence <- tibble::tibble(
    condition_occurrence_id = 1:14,
    person_id = c(1L, 1L, 1L, 2L, 2L, 3L, 4L, 4L, 5L, 5L, 5L, 5L, 5L, 1L),
    visit_occurrence_id = c(101L, 101L, 101L, 102L, 102L, 103L, 104L, 104L, 105L, 105L, 105L, 105L, 105L, 106L),
    condition_concept_id = c(
      312327L, 201826L, 197320L, 312327L, 197320L, 433753L,
      4092289L, 4014295L, 46271022L, 193782L, 316866L, 0L, 4193704L, 316866L
    ),
    condition_source_concept_id = c(
      1001L, 1002L, 1003L, 1001L, 1003L, 1004L,
      1005L, 1006L, 1007L, 1008L, 1009L, 1010L, 1011L, 1009L
    ),
    condition_status_concept_id = c(
      32902L, 32908L, 32908L, 32903L, 32908L, 32902L,
      32902L, 32908L, 32908L, 32902L, 32908L, 32908L, 32908L, 32902L
    ),
    condition_type_concept_id = c(
      32817L, 32817L, 32817L, 32817L, 32817L, NA_integer_,
      32817L, 32817L, 32817L, 32817L, 32817L, 32817L, 32858L, 32817L
    ),
    condition_start_date = as.Date(c(
      "2024-05-02", "2024-05-02", "2024-05-03",
      "2024-06-10", "2024-06-11",
      "2024-07-01",
      "2024-08-15", "2024-08-15",
      "2024-09-01", "2024-09-01", "2024-09-01", "2024-09-01", "2024-09-01",
      "2024-05-20"
    ))
  )

  procedure_occurrence <- tibble::tibble(
    procedure_occurrence_id = 1:3,
    person_id = c(1L, 4L, 5L),
    visit_occurrence_id = c(101L, 104L, 105L),
    procedure_concept_id = c(2001L, 0L, 0L),        # 101 std PCS, 104 src PCS only, 105 unmapped
    procedure_source_concept_id = c(0L, 2002L, 0L),
    procedure_type_concept_id = 32817L,
    procedure_date = as.Date(c("2024-05-02", "2024-08-15", "2024-09-02"))
  )

  death <- tibble::tibble(
    person_id = 2L,
    death_date = as.Date("2024-06-14"),
    death_type_concept_id = 32817L
  )

  concept <- tibble::tibble(
    concept_id = c(
      1001L, 1002L, 1003L, 1004L, 1005L, 1006L, 1007L, 1008L, 1009L, 1010L, 1011L,
      2001L, 2002L,
      8536L, 4021968L, 32210L
    ),
    concept_name = c(
      "NSTEMI", "T2DM", "AKI", "Alcohol dependence", "Normal delivery",
      "Single liveborn", "CKD header", "ESRD", "Hypertension", "Bogus", "Sepsis NLP",
      "PCI", "Delivery",
      "Home", "AMA", "Discharged to home"
    ),
    domain_id = c(rep("Condition", 11), rep("Procedure", 2), rep("Visit", 3)),
    vocabulary_id = c(
      rep("ICD10CM", 11),
      rep("ICD10PCS", 2),
      "CMS Place of Service", "SNOMED", "UB04 Pt dis status"
    ),
    concept_class_id = "Clinical Finding",
    standard_concept = NA_character_,
    concept_code = c(
      "I21.4", "E11.9", "N17.9", "F10.20", "O80", "Z37.0", "N18", "N18.6", "I10", "ZZZ999", "A41.9",
      "02703ZZ", "10E0XZZ",
      "12", "225928004", "01"
    ),
    valid_start_date = as.Date("1970-01-01"),
    valid_end_date = as.Date("2099-12-31"),
    invalid_reason = NA_character_
  )

  concept_relationship <- tibble::tibble(
    concept_id_1 = c(1001L, 1002L),
    concept_id_2 = c(312327L, 201826L),
    relationship_id = "Maps to",
    valid_start_date = as.Date("1970-01-01"),
    valid_end_date = as.Date("2099-12-31"),
    invalid_reason = NA_character_
  )

  list(
    person = person,
    observation_period = observation_period,
    visit_occurrence = visit_occurrence,
    condition_occurrence = condition_occurrence,
    procedure_occurrence = procedure_occurrence,
    death = death,
    concept = concept,
    concept_relationship = concept_relationship
  )
}

test_that("omop_msdrg() and omop_to_msdrg() group standard OMOP CDM stays accurately", {
  cdm <- make_synthetic_omop_tables()
  attr(cdm, "cdm_name") <- "synthetic_test"

  inp <- omop_to_msdrg(cdm, tables = "44.0")
  expect_s3_class(inp, "omop_msdrg_input")
  expect_equal(nrow(inp$claims), 5L) # excludes outpatient visit 106
  expect_equal(inp$claims$age, c(67L, 75L, 54L, 30L, 69L))
  expect_equal(inp$claims$sex, c(1L, 2L, 1L, 2L, 1L))
  expect_equal(inp$claims$discharge_status, c("01", "20", "07", "01", "01"))
  expect_equal(inp$claims$discharge_source, c("concept", "death", "concept", "concept", "default"))
  expect_equal(inp$claims$has_unmapped_pr, c(FALSE, FALSE, FALSE, FALSE, TRUE))
  expect_equal(inp$claims$n_pr, c(1L, 0L, 0L, 1L, 0L))
  # NLP row A41.9 excluded by default (condition_type_concept_id == 32858); NA kept on visit 103
  expect_false("A419" %in% inp$diagnoses$code)
  expect_true("F1020" %in% inp$diagnoses$code)

  res <- omop_msdrg(cdm, tables = "44.0")
  expect_equal(res$visit_occurrence_id, 101:105)
  expect_equal(res$return_code, rep(0L, 5))
  expect_equal(res$drg[1:4], c(251L, 284L, 894L, 807L))
  # Visit 105 has primary N18.6 (ESRD) + I10 + N18 header (not MCC/CC) -> DRG 684 (Renal failure w/o CC/MCC)
  expect_equal(res$drg[5], 684L)

  # Including NLP adds A41.9 (sepsis, MCC!) on visit 105, shifting DRG 684 -> 682
  res_nlp <- omop_msdrg(cdm, tables = "44.0", exclude_nlp = FALSE)
  expect_equal(res_nlp$drg[5], 682L)

  # Quality report distinguishes billable, category_header (N18), unrecognised (ZZZ999)
  q <- omop_msdrg_quality(res)
  expect_s3_class(q, "omop_msdrg_quality")
  expect_equal(q$n_stays, 5L)
  expect_equal(q$n_grouped, 5L)
  expect_equal(q$dx_code_validity$n_rows[q$dx_code_validity$status == "category_header"], 1L)
  expect_equal(q$dx_code_validity$n_rows[q$dx_code_validity$status == "unrecognised"], 1L)
  expect_equal(q$top_category_headers$code, "N18")
  expect_output(print(inp), "synthetic_test")
  expect_output(print(q), "Grouped \\(RC 0\\): 5 / 5")
})

test_that("principal strategies handle CDMs without primary flags honestly", {
  cdm <- make_synthetic_omop_tables()
  cdm$condition_occurrence$condition_status_concept_id <- 0L

  # 1. Default status strategy refuses to guess silently -> RC 7 on all stays
  expect_message(
    res_status <- omop_msdrg(cdm, tables = "44.0", principal = "status"),
    "No primary diagnosis flags"
  )
  expect_equal(res_status$return_code, rep(7L, 5))
  expect_equal(res_status$drg, rep(999L, 5))
  expect_equal(res_status$principal_source, rep("none", 5))

  # 2. Codelist strategy selects matching billable code over category header (N18.6 over N18)
  res_code <- omop_msdrg(
    cdm, tables = "44.0",
    principal = "codelist", principal_codes = c("I21", "N18"),
    unmatched = "keep"
  )
  expect_equal(res_code$principal_code, c("I214", "I214", NA_character_, NA_character_, "N186"))
  expect_equal(res_code$return_code, c(0L, 0L, 7L, 7L, 0L))
  expect_equal(res_code$drg[c(1, 2, 5)], c(251L, 284L, 684L))

  res_code_drop <- omop_msdrg(
    cdm, tables = "44.0",
    principal = "codelist", principal_codes = c("I21", "N18"),
    unmatched = "drop"
  )
  expect_equal(res_code_drop$visit_occurrence_id, c(101L, 102L, 105L))

  # 3. Sensitivity strategy "all" expands every coded diagnosis per stay
  res_all <- omop_msdrg(cdm, tables = "44.0", principal = "all", visit_ids = c(101L, 102L))
  expect_equal(nrow(res_all), 5L) # 3 dx on 101 + 2 dx on 102
  expect_true("candidate_index" %in% names(res_all))
  expect_true(251L %in% res_all$drg[res_all$visit_occurrence_id == 101L])
  expect_true(284L %in% res_all$drg[res_all$visit_occurrence_id == 102L])

  # 4. Explicit "first" strategy prefers billable codes over headers
  res_first <- omop_msdrg(cdm, tables = "44.0", principal = "first", visit_ids = 105L)
  expect_equal(res_first$principal_code, "N186")
  expect_equal(res_first$return_code, 0L)
})

test_that("discharge_map, death table, v5.3 column names, date_overlap and snomed_fallback work", {
  cdm <- make_synthetic_omop_tables()
  # Remove death table so site-specific discharge_map ("5" = exitus) drives visit 102
  cdm$death <- NULL
  res_map <- omop_msdrg(
    cdm, tables = "44.0",
    visit_ids = 102L,
    discharge_map = c("1" = "01", "5" = "20")
  )
  expect_equal(res_map$discharge_status, "20")
  expect_equal(res_map$discharge_source, "source_map")
  expect_equal(res_map$drg, 284L) # AMI expired with CC

  # Without site map, visit 102 falls back to default "01" -> alive DRG 281
  res_def <- omop_msdrg(cdm, tables = "44.0", visit_ids = 102L)
  expect_equal(res_def$discharge_status, "01")
  expect_equal(res_def$drg, 281L)

  # OMOP v5.3 column names (discharge_to_concept_id / discharge_to_source_value)
  cdm53 <- cdm
  names(cdm53$visit_occurrence) <- sub("^discharged_", "discharge_", names(cdm53$visit_occurrence))
  res53 <- omop_msdrg(cdm53, tables = "44.0", visit_ids = 103L)
  expect_equal(res53$discharge_status, "07")
  expect_equal(res53$drg, 894L)

  # link_by = "date_overlap" works when visit_occurrence_id is absent on clinical tables
  cdm_novid <- cdm
  cdm_novid$condition_occurrence$visit_occurrence_id <- NULL
  cdm_novid$procedure_occurrence$visit_occurrence_id <- NULL
  res_ov <- omop_msdrg(cdm_novid, tables = "44.0", visit_ids = 101L, link_by = "date_overlap")
  expect_equal(res_ov$drg, 251L)

  # snomed_fallback reverse-maps standard SNOMED concepts when source concepts are 0
  cdm_snomed <- cdm
  cdm_snomed$condition_occurrence$condition_source_concept_id <- 0L
  res_snomed <- omop_msdrg(cdm_snomed, tables = "44.0", visit_ids = 101L, snomed_fallback = TRUE)
  expect_equal(res_snomed$return_code, 0L)
  expect_equal(res_snomed$principal_code, "I214")
  expect_equal(res_snomed$drg, 251L)
})

test_that("CDMConnector + DuckDB cdm_reference works end-to-end with group(), cohorts and filters", {
  skip_if_not_installed("CDMConnector")
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("omopgenerics")

  tbls <- make_synthetic_omop_tables()
  con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  for (nm in names(tbls)) {
    DBI::dbWriteTable(con, nm, tbls[[nm]])
  }
  DBI::dbWriteTable(con, "study_cohort", tibble::tibble(
    cohort_definition_id = 1L,
    subject_id = c(1L, 2L),
    cohort_start_date = as.Date(c("2024-05-01", "2024-06-01")),
    cohort_end_date = as.Date(c("2024-05-31", "2024-06-30"))
  ))

  cdm <- CDMConnector::cdmFromCon(
    con = con,
    cdmSchema = "main",
    writeSchema = "main",
    cohortTables = "study_cohort",
    cdmName = "duckdb_synth"
  )

  # Unified group(grouper("msdrg"), cdm, ...) dispatch
  g <- grouper("msdrg", version = "44.0")
  res <- group(g, cdm)
  expect_equal(sort(res$visit_occurrence_id), 101:105)
  expect_equal(res$drg[match(101:104, res$visit_occurrence_id)], c(251L, 284L, 894L, 807L))
  expect_equal(omop_msdrg_quality(res)$cdm_name, "duckdb_synth")

  # Cohort table name inside CDM (executed in SQL)
  res_coh <- omop_msdrg(cdm, tables = "44.0", cohort = "study_cohort")
  expect_equal(sort(res_coh$visit_occurrence_id), c(101L, 102L))
  expect_equal(res_coh$drg[match(c(101L, 102L), res_coh$visit_occurrence_id)], c(251L, 284L))

  # In-memory cohort data frame against remote SQL CDM (read-only safe)
  local_coh <- tibble::tibble(
    subject_id = c(3L, 4L),
    cohort_start_date = as.Date(c("2024-07-01", "2024-08-01")),
    cohort_end_date = as.Date(c("2024-07-10", "2024-08-31"))
  )
  res_lcoh <- omop_msdrg(cdm, tables = "44.0", cohort = local_coh)
  expect_equal(sort(res_lcoh$visit_occurrence_id), c(103L, 104L))
  expect_equal(res_lcoh$drg[match(c(103L, 104L), res_lcoh$visit_occurrence_id)], c(894L, 807L))

  # Date bounds + n_max (deterministic slice_min in SQL)
  res_sub <- omop_msdrg(cdm, tables = "44.0", start_date = "2024-06-01", end_date = "2024-08-31", n_max = 2L)
  expect_equal(res_sub$visit_occurrence_id, c(102L, 103L))
  expect_equal(res_sub$drg, c(284L, 894L))

  # Empty result set returns 0-row tibble cleanly
  res_empty <- omop_msdrg(cdm, tables = "44.0", start_date = "2030-01-01")
  expect_equal(nrow(res_empty), 0L)
  expect_true(all(c("person_id", "visit_occurrence_id", "drg", "return_code") %in% names(res_empty)))
  expect_equal(omop_msdrg_quality(res_empty)$n_stays, 0L)
})

test_that("validation errors are clear", {
  expect_error(omop_to_msdrg("not_a_cdm"), "cdm_reference")
  expect_error(omop_to_msdrg(list(person = tibble::tibble())), "missing required OMOP")
  cdm <- make_synthetic_omop_tables()
  expect_error(omop_to_msdrg(cdm, principal = "codelist"), "principal_codes")
  expect_error(omop_to_msdrg(cdm, cohort = "nonexistent"), "not found")
  expect_error(omop_msdrg_quality(tibble::tibble()), "quality report")
})
