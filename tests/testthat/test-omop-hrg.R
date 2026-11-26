make_synthetic_uk_omop_tables <- function() {
  person <- tibble::tibble(
    person_id = c(1L, 2L, 3L),
    gender_concept_id = c(8532L, 8532L, 8507L),
    year_of_birth = c(1952L, 1952L, 1970L),
    month_of_birth = c(3L, 3L, 2L),
    day_of_birth = c(10L, 10L, 15L),
    birth_datetime = as.POSIXct(c(
      "1952-03-10 00:00:00", "1952-03-10 00:00:00", "1970-02-15 00:00:00"
    ), tz = "UTC"),
    race_concept_id = 0L,
    ethnicity_concept_id = 0L
  )

  observation_period <- tibble::tibble(
    observation_period_id = 1:3,
    person_id = 1:3,
    observation_period_start_date = as.Date("2020-01-01"),
    observation_period_end_date = as.Date("2025-12-31"),
    period_type_concept_id = 32817L
  )

  provider <- tibble::tibble(
    provider_id = c(10L, 20L, 30L),
    specialty_concept_id = c(38004465L, 38004447L, 38004456L), # Ortho 110, Gen Surg 100, Med 300
    specialty_source_value = c("110", NA_character_, "300")
  )

  care_site <- tibble::tibble(
    care_site_id = 1L,
    care_site_source_value = "RXX"
  )

  # Visit 1001: 72F, hip OA (M16.1) + I10 (3-char -> I10X) + W37.1 + Z84.3 -> HN12F
  # Visit 1002: 72F, same hip OA + I10 + J44.0 (COPD w chest infection) + W37.1 + Z84.3 -> HN12E
  # Visit 1003: 54M, ER+IP (262 -> ADMIMETH 21), anal cancer (C21.0) + H33.4, died -> PSO NCBPS01J / A07
  visit_occurrence <- tibble::tibble(
    visit_occurrence_id = c(1001L, 1002L, 1003L),
    person_id = c(1L, 2L, 3L),
    visit_concept_id = c(9201L, 9201L, 262L),
    visit_start_date = as.Date(c("2024-05-01", "2024-06-01", "2024-07-01")),
    visit_end_date = as.Date(c("2024-05-05", "2024-06-05", "2024-07-06")),
    visit_type_concept_id = 32817L,
    provider_id = c(10L, 10L, 20L),
    care_site_id = c(1L, 1L, 1L),
    admitted_from_concept_id = c(8536L, 8536L, 8870L),
    admitted_from_source_value = c("19", "19", "19"),
    discharged_to_concept_id = c(8536L, 8536L, 0L),
    discharged_to_source_value = c("19", "19", NA_character_)
  )

  condition_occurrence <- tibble::tibble(
    condition_occurrence_id = 1:7,
    person_id = c(1L, 1L, 2L, 2L, 2L, 2L, 3L),
    visit_occurrence_id = c(1001L, 1001L, 1002L, 1002L, 1002L, 1002L, 1003L),
    condition_concept_id = c(4079750L, 316866L, 4079750L, 316866L, 255573L, 0L, 4180790L),
    condition_source_concept_id = c(1001L, 1002L, 1001L, 1002L, 1003L, 1005L, 1004L),
    condition_status_concept_id = c(32902L, 32908L, 32902L, 32908L, 32908L, 32908L, 32902L),
    condition_type_concept_id = 32817L,
    condition_start_date = as.Date(c(
      "2024-05-01", "2024-05-01",
      "2024-06-01", "2024-06-01", "2024-06-01", "2024-06-01",
      "2024-07-01"
    )),
    condition_end_date = as.Date(c(
      "2024-05-01", "2024-05-01",
      "2024-06-01", "2024-06-01", "2024-06-01", "2024-06-01",
      "2024-07-01"
    ))
  )

  procedure_occurrence <- tibble::tibble(
    procedure_occurrence_id = 1:6,
    person_id = c(1L, 1L, 2L, 2L, 2L, 3L),
    visit_occurrence_id = c(1001L, 1001L, 1002L, 1002L, 1002L, 1003L),
    procedure_concept_id = c(2001L, 2002L, 2001L, 0L, 0L, 2003L), # row 4 src-only OPCS4, row 5 unmapped
    procedure_source_concept_id = c(0L, 0L, 0L, 2002L, 0L, 0L),
    procedure_type_concept_id = 32817L,
    procedure_date = as.Date(c(
      "2024-05-01", "2024-05-01",
      "2024-06-01", "2024-06-01", "2024-06-02",
      "2024-07-02"
    ))
  )

  death <- tibble::tibble(
    person_id = 3L,
    death_date = as.Date("2024-07-06"),
    death_type_concept_id = 32817L
  )

  concept <- tibble::tibble(
    concept_id = c(
      1001L, 1002L, 1003L, 1004L, 1005L,
      2001L, 2002L, 2003L,
      4079750L, 316866L, 255573L, 4180790L
    ),
    concept_name = c(
      "Hip OA", "Hypertension", "COPD w infection", "Anal cancer", "Hip OA header",
      "Total hip replacement", "Hip joint", "Anterior resection rectum",
      "Hip OA std", "Hypertension std", "COPD std", "Anal cancer std"
    ),
    domain_id = c(rep("Condition", 5), rep("Procedure", 3), rep("Condition", 4)),
    vocabulary_id = c(rep("ICD10", 5), rep("OPCS4", 3), rep("SNOMED", 4)),
    concept_class_id = "Clinical Finding",
    standard_concept = c(rep(NA_character_, 8), rep("S", 4)),
    concept_code = c(
      "M16.1", "I10", "J44.0", "C21.0", "M16",
      "W37.1", "Z84.3", "H33.4",
      "S1", "S2", "S3", "S4"
    ),
    valid_start_date = as.Date("1970-01-01"),
    valid_end_date = as.Date("2099-12-31"),
    invalid_reason = NA_character_
  )

  concept_relationship <- tibble::tibble(
    concept_id_1 = c(1001L, 1002L),
    concept_id_2 = c(4079750L, 316866L),
    relationship_id = "Maps to",
    valid_start_date = as.Date("1970-01-01"),
    valid_end_date = as.Date("2099-12-31"),
    invalid_reason = NA_character_
  )

  vocabulary <- tibble::tibble(
    vocabulary_id = "None", vocabulary_name = "OMOP",
    vocabulary_reference = "", vocabulary_version = "v5.0", vocabulary_concept_id = 0L
  )

  list(
    person = person,
    observation_period = observation_period,
    provider = provider,
    care_site = care_site,
    visit_occurrence = visit_occurrence,
    condition_occurrence = condition_occurrence,
    procedure_occurrence = procedure_occurrence,
    death = death,
    concept = concept,
    concept_relationship = concept_relationship,
    vocabulary = vocabulary
  )
}

test_that("omop_to_hrg() and omop_hrg() group UK OMOP stays into exact HRG4+ groups", {
  cdm <- make_synthetic_uk_omop_tables()
  attr(cdm, "cdm_name") <- "uk_synth"

  inp <- omop_to_hrg(cdm, tables = "2025-26-lp")
  expect_s3_class(inp, "omop_hrg_input")
  expect_equal(nrow(inp$episodes), 3L)
  # 3-char ICD-10 "I10" is padded with "X" -> "I10X"
  expect_equal(inp$episodes$DIAG_01, c("M161", "M161", "C210"))
  expect_equal(inp$episodes$DIAG_02[1], "I10X")
  expect_equal(inp$quality$n_dx_padded_x, 2L)
  # OPCS-4 order preserved: W371 followed by Z843 (both std and src-only)
  expect_equal(inp$episodes$OPER_01, c("W371", "W371", "H334"))
  expect_equal(inp$episodes$OPER_02[1:2], c("Z843", "Z843"))
  # Emergency visit 1003 gets ADMIMETH "21" and death table -> DISMETH "4", DISDEST "79"
  expect_equal(inp$episodes$ADMIMETH, c("11", "11", "21"))
  expect_equal(inp$episodes$DISMETH, c("1", "1", "4"))
  expect_equal(inp$episodes$DISDEST, c("19", "19", "79"))
  # Specialty from provider table: 110 (source_value) and 100 (concept_id 38004447)
  expect_equal(inp$episodes$MAINSPEF, c("110", "110", "100"))
  expect_equal(inp$episodes$TRETSPEF, c("110", "110", "100"))
  # Unmapped procedure flagged on visit 1002
  expect_equal(inp$meta$has_unmapped_pr, c(FALSE, TRUE, FALSE))

  res <- omop_hrg(cdm, tables = "2025-26-lp")
  expect_equal(res$episodes$fce_hrg[1:2], c("HN12F", "HN12E"))
  expect_equal(res$episodes$spell_hrg[1:2], c("HN12F", "HN12E"))
  expect_equal(res$episodes$dominant_procedure[1:2], c("W371", "W371"))
  expect_equal(res$episodes$grouping_method[1:2], c("P", "P"))
  expect_false(res$episodes$fce_hrg[3] == "UZ01Z")
  expect_equal(nrow(res$spells), 3L)

  q <- omop_hrg_quality(res)
  expect_s3_class(q, "omop_hrg_quality")
  expect_equal(q$n_grouped_episodes, 3L)
  expect_equal(q$n_grouped_spells, 3L)
  expect_equal(q$dx_code_validity$n_rows[q$dx_code_validity$status == "category_header"], 1L)
  expect_output(print(inp), "uk_synth")
  expect_output(print(q), "Grouped \\(non-UZ01Z\\): 3 / 3")

  # Strict mode (drop_invalid_secondary = FALSE) keeps category header "M16" -> UZ01Z on visit 1002
  res_strict <- omop_hrg(cdm, tables = "2025-26-lp", drop_invalid_secondary = FALSE)
  expect_equal(res_strict$episodes$fce_hrg[1:2], c("HN12F", "UZ01Z"))
})

test_that("episodes = 'visit_detail' builds multi-episode FCE spells properly", {
  cdm <- make_synthetic_uk_omop_tables()
  # Split visit 1001 into 2 consultant episodes: medical (300) then orthopaedic surgery (110)
  cdm$visit_detail <- tibble::tibble(
    visit_detail_id = c(5001L, 5002L),
    person_id = c(1L, 1L),
    visit_occurrence_id = c(1001L, 1001L),
    visit_detail_concept_id = c(9201L, 9201L),
    visit_detail_start_date = as.Date(c("2024-05-01", "2024-05-03")),
    visit_detail_end_date = as.Date(c("2024-05-03", "2024-05-05")),
    provider_id = c(30L, 10L),
    care_site_id = c(1L, 1L)
  )
  cdm$condition_occurrence$visit_detail_id <- c(5001L, 5001L, NA_integer_, NA_integer_, NA_integer_, NA_integer_, NA_integer_)
  cdm$condition_occurrence <- dplyr::bind_rows(
    cdm$condition_occurrence,
    tibble::tibble(
      condition_occurrence_id = 8L, person_id = 1L, visit_occurrence_id = 1001L,
      visit_detail_id = 5002L, condition_concept_id = 4079750L,
      condition_source_concept_id = 1001L, condition_status_concept_id = 32902L,
      condition_type_concept_id = 32817L,
      condition_start_date = as.Date("2024-05-03"), condition_end_date = as.Date("2024-05-03")
    )
  )
  cdm$procedure_occurrence$visit_detail_id <- c(5002L, 5002L, NA_integer_, NA_integer_, NA_integer_, NA_integer_)

  res <- omop_hrg(cdm, tables = "2025-26-lp", episodes = "visit_detail", visit_ids = 1001L)
  expect_equal(nrow(res$episodes), 2L)
  expect_equal(nrow(res$spells), 1L)
  expect_equal(res$episodes$visit_detail_id, c(5001L, 5002L))
  expect_equal(res$spells$spell_episode_count, 2L)
  expect_equal(res$spells$spell_hrg, "HN12F")
  expect_equal(res$spells$spell_los, 4)
  expect_equal(omop_hrg_quality(res)$episodes_mode, "visit_detail")
})

test_that("principal strategies and vocabulary_fallback work for omop_hrg()", {
  cdm <- make_synthetic_uk_omop_tables()
  cdm$condition_occurrence$condition_status_concept_id <- 0L

  expect_message(
    res_st <- omop_hrg(cdm, tables = "2025-26-lp", principal = "status", visit_ids = 1001L),
    "No primary diagnosis flags"
  )
  expect_equal(res_st$episodes$fce_hrg, "UZ01Z")

  res_cl <- omop_hrg(cdm, tables = "2025-26-lp", principal = "codelist",
                     principal_codes = c("M16", "C21"), visit_ids = c(1001L, 1003L))
  expect_equal(res_cl$episodes$fce_hrg[1], "HN12F")
  expect_equal(res_cl$episodes$principal_code, c("M161", "C210"))

  res_all <- omop_hrg(cdm, tables = "2025-26-lp", principal = "all", visit_ids = 1001L)
  expect_equal(nrow(res_all$episodes), 2L)
  expect_true("HN12F" %in% res_all$episodes$fce_hrg)

  # SNOMED -> ICD10 reverse-mapping fallback
  cdm_snomed <- make_synthetic_uk_omop_tables()
  cdm_snomed$condition_occurrence$condition_source_concept_id <- 0L
  res_sn <- omop_hrg(cdm_snomed, tables = "2025-26-lp", visit_ids = 1001L, vocabulary_fallback = TRUE)
  expect_equal(res_sn$episodes$fce_hrg, "HN12F")
})

test_that("CDMConnector + DuckDB + CohortConstructor work with HRG4+ and PSO", {
  skip_if_not_installed("CDMConnector")
  skip_if_not_installed("CohortConstructor")
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("omopgenerics")

  tbls <- make_synthetic_uk_omop_tables()
  tbls$condition_occurrence$condition_status_concept_id <- 0L

  con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  for (nm in names(tbls)) {
    DBI::dbWriteTable(con, nm, tbls[[nm]])
  }

  cdm <- CDMConnector::cdmFromCon(con = con, cdmSchema = "main", writeSchema = "main", cdmName = "uk_duckdb")
  cdm$uk_cohort <- CohortConstructor::conceptCohort(
    cdm = cdm,
    conceptSet = list(hip_oa = 4079750L, anal_cancer = 4180790L),
    name = "uk_cohort"
  )

  # Unified group(grouper("hrg4plus"), cdm$uk_cohort, ...) with automatic cohort_codelist
  h <- grouper("hrg4plus", version = "2025-26-lp")
  res <- group(h, cdm$uk_cohort, principal = "cohort_codelist", cohort_match = "index")
  hip <- res$episodes |> dplyr::filter(.data$cohort_name == "hip_oa") |> dplyr::arrange(.data$visit_occurrence_id)
  expect_equal(hip$fce_hrg, c("HN12F", "HN12E"))
  expect_equal(hip$spell_hrg, c("HN12F", "HN12E"))
  expect_equal(nrow(omop_hrg_quality(res)$cohorts), 2L)

  # Unified group(grouper("pso"), cdm$uk_cohort, ...) flags NCBPS01J / A07 for anal cancer!
  p <- grouper("pso", version = "2025-26-v2")
  pso_res <- group(p, cdm$uk_cohort, cohort_id = "anal_cancer",
                   principal = "cohort_codelist", cohort_match = "index")
  expect_equal(pso_res$episodes$service_line, "NCBPS01J")
  expect_equal(pso_res$episodes$fce_npoc, "A07")
  expect_equal(pso_res$episodes$spell_service_line, "NCBPS01J")

  # Empty result sets for both HRG4+ and PSO
  empty_hrg <- group(h, cdm, start_date = "2030-01-01")
  expect_equal(nrow(empty_hrg$episodes), 0L)
  expect_equal(nrow(empty_hrg$spells), 0L)
  empty_pso <- group(p, cdm, start_date = "2030-01-01")
  expect_equal(nrow(empty_pso$episodes), 0L)
  expect_equal(nrow(empty_pso$spells), 0L)
})
