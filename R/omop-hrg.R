# Adapter and one-call grouper from an OMOP CDM (CDMConnector / omopgenerics
# `cdm_reference` or a CohortConstructor `cohort_table`) to NHS England HRG4+
# admitted patient care (APC) episodes & spells (and compatible with PSO APC).
# Queries stay lazy in the database through dplyr/dbplyr; no write schema is
# required.

# Standard OMOP specialty_concept_id -> NHS 3-digit Main Specialty / Treatment
# Function Code (valid in both MAINSPEF and TRETSPEF).
omop_hrg_specialty_map <- c(
  "38004447" = "100", # General Surgery
  "38004474" = "101", # Urology
  "38004496" = "107", # Vascular Surgery
  "38004465" = "110", # Orthopedic Surgery (Trauma & Orthopaedics)
  "38004463" = "130", # Ophthalmology
  "38004464" = "140", # Oral Surgery
  "38004467" = "160", # Plastic Surgery
  "38004497" = "170", # Cardiac Surgery (Cardiothoracic)
  "38004473" = "170", # Thoracic Surgery (Cardiothoracic)
  "38004456" = "300", # Internal Medicine (General Internal Medicine)
  "38004455" = "301", # Gastroenterology
  "38004485" = "302", # Endocrinology
  "38004451" = "320", # Cardiology
  "38004472" = "340", # Pulmonary Disease (Respiratory Medicine)
  "38004484" = "350", # Infectious Disease
  "38004479" = "361", # Nephrology
  "38004458" = "400", # Neurology
  "38004491" = "410", # Rheumatology
  "38004477" = "420", # Pediatric Medicine
  "38004478" = "430", # Geriatric Medicine
  "38004461" = "502", # Obstetrics / Gynecology
  "38004469" = "710", # Psychiatry (Adult Mental Illness)
  "38004470" = "715"  # Geriatric Psychiatry (Old Age Psychiatry)
)

# Standard OMOP discharged_to_concept_id -> NHS DISMETH / DISDEST.
omop_hrg_dismeth_concept_map <- c(
  "4216643"  = "4", # SNOMED: Patient died
  "32218"    = "4", # UB04: Expired
  "32221"    = "4", # UB04: Expired at home
  "4021968"  = "2", # SNOMED: Patient self-discharge against medical advice
  "44814692" = "2", # PCORNet: Against medical advice
  "8536"     = "1", # Home
  "581476"   = "1", # Home Visit
  "32210"    = "1", # UB04: Discharged home
  "9201"     = "1", # Transfer to acute hospital
  "8717"     = "1",
  "32211"    = "1",
  "38004279" = "1",
  "8863"     = "1", # SNF / care home
  "8676"     = "1"
)

omop_hrg_disdest_concept_map <- c(
  "4216643"  = "79", # Died (not applicable)
  "32218"    = "79",
  "32221"    = "79",
  "8536"     = "19", # Usual place of residence
  "581476"   = "19",
  "32210"    = "19",
  "4021968"  = "19",
  "44814692" = "19",
  "9201"     = "51", # NHS other hospital provider (general ward)
  "8717"     = "51",
  "32211"    = "51",
  "38004279" = "51",
  "8863"     = "54", # NHS/care nursing facility
  "8676"     = "54"
)

omop_hrg_admisorc_concept_map <- c(
  "8536"     = "19", # Usual place of residence
  "581476"   = "19",
  "9201"     = "51", # Transfer from acute hospital
  "8717"     = "51",
  "38004279" = "51",
  "8863"     = "54", # Care / nursing home
  "8676"     = "54"
)

# Normalize ICD-10 codes to NHS HRG4+ 4/5-character form: uppercase, strip
# dots/whitespace/dagger/asterisk, and pad 3-character codes with "X" when
# <codeX> is in `valid_codes` (e.g. "I10" -> "I10X", "O80" -> "O80X").
hrg_normalize_icd10 <- function(x, valid_codes) {
  raw <- toupper(gsub("[.+*\u2020[:space:]]", "", as.character(x)))
  raw[!is.na(raw) & raw == ""] <- NA_character_
  padded <- rep(FALSE, length(raw))
  is_three <- !is.na(raw) & nchar(raw) == 3L & !raw %in% valid_codes
  if (any(is_three)) {
    cand <- paste0(raw[is_three], "X")
    ok <- cand %in% valid_codes
    idx <- which(is_three)[ok]
    raw[idx] <- cand[ok]
    padded[idx] <- TRUE
  }
  list(code = raw, padded_x = padded)
}

hrg_normalize_opcs4 <- function(x) {
  out <- toupper(gsub("[.[:space:]]", "", as.character(x)))
  out[!is.na(out) & out == ""] <- NA_character_
  out
}

hrg_icd_header_prefixes <- function(valid_codes) {
  lens <- nchar(valid_codes)
  out <- character()
  for (k in 3:4) {
    sub <- valid_codes[lens > k]
    if (length(sub) > 0L) out <- c(out, unique(substr(sub, 1L, k)))
  }
  setdiff(unique(out), valid_codes)
}

omop_hrg_resolve_admission <- function(visit_concept_id, admit_cid, admit_val,
                                       admission_method_map, admission_source_map,
                                       default_admimeth, default_admisorc) {
  n <- length(visit_concept_id)
  admimeth <- rep(NA_character_, n)
  admisorc <- rep(NA_character_, n)
  source <- rep("default", n)

  if (!is.null(admission_method_map) && length(admission_method_map) > 0L && !is.null(admit_val)) {
    key <- trimws(as.character(admit_val))
    mapped <- trimws(unname(admission_method_map[key]))
    hit <- !is.na(mapped) & mapped != ""
    admimeth[hit] <- mapped[hit]
    source[hit] <- "source_map"
  }
  if (!is.null(admission_source_map) && length(admission_source_map) > 0L && !is.null(admit_val)) {
    key <- trimws(as.character(admit_val))
    mapped <- trimws(unname(admission_source_map[key]))
    hit <- !is.na(mapped) & mapped != ""
    admisorc[hit] <- mapped[hit]
  }

  # Emergency visit concept (262 = ER & Inpatient) or ER admitting source (8870, 9203)
  is_er <- (!is.na(visit_concept_id) & as.integer(visit_concept_id) == 262L) |
    (!is.null(admit_cid) & !is.na(admit_cid) & as.integer(admit_cid) %in% c(8870L, 9203L))
  hit_er <- is.na(admimeth) & is_er
  admimeth[hit_er] <- "21"
  source[hit_er] <- "concept"

  if (!is.null(admit_cid)) {
    mapped_src <- unname(omop_hrg_admisorc_concept_map[omop_id_chr(admit_cid)])
    hit_src <- is.na(admisorc) & !is.na(mapped_src)
    admisorc[hit_src] <- mapped_src[hit_src]
    source[hit_src & source == "default"] <- "concept"
  }

  admimeth[is.na(admimeth)] <- as.character(default_admimeth)
  admisorc[is.na(admisorc)] <- as.character(default_admisorc)
  list(ADMIMETH = admimeth, ADMISORC = admisorc, admission_source = source)
}

omop_hrg_resolve_discharge <- function(died, disc_val, disc_cid,
                                       discharge_method_map, discharge_dest_map,
                                       default_dismeth, default_disdest) {
  n <- length(died)
  dismeth <- rep(NA_character_, n)
  disdest <- rep(NA_character_, n)
  source <- rep("default", n)

  is_dead <- !is.na(died) & died
  dismeth[is_dead] <- "4"
  disdest[is_dead] <- "79"
  source[is_dead] <- "death"

  if (!is.null(discharge_method_map) && length(discharge_method_map) > 0L && !is.null(disc_val)) {
    key <- trimws(as.character(disc_val))
    mapped <- trimws(unname(discharge_method_map[key]))
    hit <- is.na(dismeth) & !is.na(mapped) & mapped != ""
    dismeth[hit] <- mapped[hit]
    source[hit] <- "source_map"
  }
  if (!is.null(discharge_dest_map) && length(discharge_dest_map) > 0L && !is.null(disc_val)) {
    key <- trimws(as.character(disc_val))
    mapped <- trimws(unname(discharge_dest_map[key]))
    hit <- is.na(disdest) & !is.na(mapped) & mapped != ""
    disdest[hit] <- mapped[hit]
    source[hit & source == "default"] <- "source_map"
  }
  # If source_map flagged death (DISMETH == "4") and DISDEST is still unset, use "79".
  dead_by_map <- !is.na(dismeth) & dismeth == "4" & is.na(disdest)
  disdest[dead_by_map] <- "79"

  if (!is.null(disc_cid)) {
    cid_chr <- omop_id_chr(disc_cid)
    m_meth <- unname(omop_hrg_dismeth_concept_map[cid_chr])
    m_dest <- unname(omop_hrg_disdest_concept_map[cid_chr])
    hit_m <- is.na(dismeth) & !is.na(m_meth)
    dismeth[hit_m] <- m_meth[hit_m]
    source[hit_m] <- "concept"
    hit_d <- is.na(disdest) & !is.na(m_dest)
    disdest[hit_d] <- m_dest[hit_d]
    source[hit_d & source == "default"] <- "concept"
  }

  dismeth[is.na(dismeth)] <- as.character(default_dismeth)
  disdest[is.na(disdest)] <- as.character(default_disdest)
  list(DISMETH = dismeth, DISDEST = disdest, discharge_source = source)
}

omop_hrg_resolve_specialty <- function(spec_cid, spec_val, specialty_map,
                                       default_specialty, valid_main, valid_tret) {
  n <- length(spec_cid)
  main <- rep(NA_character_, n)
  tret <- rep(NA_character_, n)
  source <- rep("default", n)

  if (!is.null(spec_val)) {
    key <- trimws(as.character(spec_val))
    if (!is.null(specialty_map) && length(specialty_map) > 0L) {
      mapped <- trimws(unname(specialty_map[key]))
      hit <- !is.na(mapped) & mapped != ""
      main[hit & mapped %in% valid_main] <- mapped[hit & mapped %in% valid_main]
      tret[hit & mapped %in% valid_tret] <- mapped[hit & mapped %in% valid_tret]
      source[hit & (!is.na(main) | !is.na(tret))] <- "source_map"
    }
    # Direct 3-digit NHS TFC / Main Specialty codes already stored in source_value.
    direct_tret <- is.na(tret) & !is.na(key) & key %in% valid_tret
    tret[direct_tret] <- key[direct_tret]
    direct_main <- is.na(main) & !is.na(key) & key %in% valid_main
    main[direct_main] <- key[direct_main]
    source[(direct_tret | direct_main) & source == "default"] <- "source_value"
  }

  if (!is.null(spec_cid)) {
    mapped_cid <- unname(omop_hrg_specialty_map[omop_id_chr(spec_cid)])
    hit_m <- is.na(main) & !is.na(mapped_cid) & mapped_cid %in% valid_main
    main[hit_m] <- mapped_cid[hit_m]
    hit_t <- is.na(tret) & !is.na(mapped_cid) & mapped_cid %in% valid_tret
    tret[hit_t] <- mapped_cid[hit_t]
    source[(hit_m | hit_t) & source == "default"] <- "concept"
  }

  def <- as.character(default_specialty)
  main[is.na(main)] <- def
  tret[is.na(tret)] <- def
  list(MAINSPEF = main, TRETSPEF = tret, specialty_source = source)
}

# Build wide DIAG_01..DIAG_nn or OPER_01..OPER_nn character matrix aligned to
# `episode_keys`.
omop_hrg_pivot_codes <- function(episode_keys, df, prefix, min_cols = 1L) {
  n_ep <- length(episode_keys)
  if (nrow(df) == 0L) {
    out <- as.data.frame(
      stats::setNames(replicate(min_cols, rep(NA_character_, n_ep), simplify = FALSE),
                      sprintf("%s_%02d", prefix, seq_len(min_cols))),
      stringsAsFactors = FALSE
    )
    return(tibble::as_tibble(out))
  }
  max_pos <- max(max(df$pos), min_cols)
  mat <- matrix(NA_character_, nrow = n_ep, ncol = max_pos)
  row_idx <- match(df$.ep_key, episode_keys)
  ok <- !is.na(row_idx) & !is.na(df$pos) & df$pos >= 1L & df$pos <= max_pos
  if (any(ok)) {
    mat[cbind(row_idx[ok], df$pos[ok])] <- df$code[ok]
  }
  colnames(mat) <- sprintf("%s_%02d", prefix, seq_len(max_pos))
  tibble::as_tibble(mat)
}

#' Convert an OMOP CDM reference or `CohortConstructor` cohort to HRG4+ APC input
#'
#' Extracts inpatient stays (or finished consultant episodes from
#' `visit_detail`), demographics, ICD-10 diagnoses, OPCS-4 procedures, provider
#' specialties, and admission/discharge fields from a `CDMConnector` /
#' `omopgenerics` `cdm_reference` — or directly from a `CohortConstructor`
#' `cohort_table` — using lazy read-only `dplyr`/`dbplyr` queries, and returns
#' the wide NHS APC episode table expected by [hrg_group_apc()], [pso_flag_apc()]
#' and [group()], together with OMOP provenance metadata and a readiness report.
#'
#' Every UK/NHS mapping assumption is explicit and recorded in `quality`:
#'
#' * **Diagnoses (ICD-10)** are read from `condition_source_concept_id` in
#'   `dx_vocabulary` (default `"ICD10"`). Three-character ICD-10 codes are
#'   automatically padded with `"X"` when the padded code exists in the HRG4+
#'   code table (e.g. `I10` becomes `I10X`). Free-text NLP rows
#'   (`condition_type_concept_id == 32858`) are excluded by default; pass
#'   `vocabulary_fallback = TRUE` to reverse-map standard SNOMED concepts via
#'   `concept_relationship` (`"Maps to"`) for stays without source ICD-10 codes.
#' * **Procedures (OPCS-4)** are read from both `procedure_concept_id` and
#'   `procedure_source_concept_id` in `pr_vocabulary` (default `"OPCS4"`),
#'   preserving recorded `(procedure_date, procedure_occurrence_id)` order so
#'   HRG4+ combination-code qualifier runs (e.g. site/approach `Z`/`Y` codes
#'   after a driving procedure) stay intact. Stays with unmapped procedures are
#'   flagged (`has_unmapped_pr`).
#' * **Episodes (`episodes`)**: `"spell"` (default) creates one episode per
#'   inpatient `visit_occurrence` (`EPIORDER = "1"`, `EPIDUR` = stay length of
#'   stay), matching standard HES-based research practice when `visit_detail`
#'   is absent or holds ward/bed transfers rather than finished consultant
#'   episodes. Set `episodes = "visit_detail"` to build multi-episode spells
#'   from `cdm$visit_detail` (with per-episode `provider_id` specialty lookup
#'   and `visit_detail_id` event linkage).
#' * **Principal diagnosis (`principal`)**: supports the same five explicit
#'   strategies as [omop_to_msdrg()]: `"status"` (default, OMOP primary flag;
#'   episodes without one leave `DIAG_01` blank so HRG4+ returns `UZ01Z`),
#'   `"codelist"` (ICD-10 codes/prefixes or OMOP concept IDs / `CodelistGenerator`
#'   codelist), `"cohort_codelist"` (automatic per-cohort index condition from
#'   a `CohortConstructor` concept cohort), `"all"` (multi-candidate sensitivity
#'   analysis), and `"first"`.
#' * **NHS administrative fields**: `SEX` (1/2/9), `STARTAGE` (0..130 or 999),
#'   `ADMIMETH` / `ADMISORC` (from `visit_concept_id` 262 / `admitted_from_*`
#'   + optional site maps), `DISMETH` / `DISDEST` (in-stay `death` table ->
#'   `DISMETH = "4"`, `DISDEST = "79"`, then optional site maps, then standard
#'   `discharged_to_concept_id`, then defaults `"1"`/`"19"`), and `MAINSPEF` /
#'   `TRETSPEF` (from `provider.specialty_source_value` / `specialty_concept_id`
#'   + optional `specialty_map`, defaulting to `"300"` General Internal Medicine).
#'
#' @inheritParams omop_to_msdrg
#' @param episodes How inpatient spells are split into HRG4+ episodes:
#'   `"spell"` (default, one episode per `visit_occurrence`) or `"visit_detail"`
#'   (one finished consultant episode per `visit_detail` row belonging to the
#'   spell, falling back to one spell-level episode if a stay has no
#'   `visit_detail` rows).
#' @param visit_detail_concept_ids Optional integer vector filtering
#'   `visit_detail.visit_detail_concept_id` when `episodes = "visit_detail"`.
#' @param dx_vocabulary Character vector of diagnosis `vocabulary_id` values in
#'   `concept` (default `"ICD10"`).
#' @param pr_vocabulary Character vector of procedure `vocabulary_id` values in
#'   `concept` (default `"OPCS4"`).
#' @param drop_invalid_secondary Logical; because HRG4+ rejects an entire
#'   episode (`UZ01Z`) if any secondary diagnosis or procedure code is outside
#'   NHS England's valid code tables, `TRUE` (default) drops unrecognised or
#'   category-header secondary diagnoses and invalid OPCS-4 codes while always
#'   keeping `DIAG_01` untouched and recording all dropped codes in `quality`.
#'   Set `FALSE` for strict NHS validation of every secondary/procedure code.
#' @param provider_code Optional explicit NHS provider code (`PROCODET`)
#'   overriding `care_site.care_site_source_value` (e.g. `"PSS"` to bypass
#'   provider eligibility in [pso_flag_apc()]). When `NULL` (default), reads
#'   `care_site_source_value` when available and falls back to
#'   `default_provider`.
#' @param default_provider Default NHS provider code (`PROCODET`) when
#'   `provider_code` is `NULL` and `care_site` does not supply one (default
#'   `"RXX"`).
#' @param default_classpat Default NHS patient classification (`CLASSPAT`,
#'   default `"1"` ordinary admission).
#' @param admission_method_map,admission_source_map Optional named character
#'   vectors mapping `admitted_from_source_value` to NHS `ADMIMETH` / `ADMISORC`.
#' @param default_admimeth,default_admisorc Fallback NHS `ADMIMETH` (default
#'   `"11"`, elective) and `ADMISORC` (default `"19"`, usual residence).
#' @param discharge_method_map,discharge_dest_map Optional named character
#'   vectors mapping `discharged_to_source_value` to NHS `DISMETH` / `DISDEST`.
#' @param default_dismeth,default_disdest Fallback NHS `DISMETH` (default `"1"`)
#'   and `DISDEST` (default `"19"`).
#' @param specialty_map Optional named character vector mapping
#'   `provider.specialty_source_value` to 3-digit NHS `MAINSPEF`/`TRETSPEF`.
#' @param default_specialty Fallback 3-digit NHS specialty code for `MAINSPEF`
#'   and `TRETSPEF` (default `"300"`, General Internal Medicine).
#' @param default_neocare Default NHS `NEOCARE` (default `"8"`, not applicable).
#' @param tables HRG4+ logic tables from [hrg_tables()] or a version label such
#'   as `"2025-26-lp"`.
#' @return An object of class `omop_hrg_input` (a list with `episodes`, `meta`
#'   and `quality`), ready to pass to [hrg_group_apc()], [pso_flag_apc()], or
#'   [group()].
#' @export
#' @examples
#' cdm <- list(
#'   person = tibble::tibble(
#'     person_id = 1L, gender_concept_id = 8532L,
#'     year_of_birth = 1952L, month_of_birth = 3L, day_of_birth = 10L
#'   ),
#'   visit_occurrence = tibble::tibble(
#'     visit_occurrence_id = 1001L, person_id = 1L, visit_concept_id = 9201L,
#'     visit_start_date = as.Date("2024-05-01"), visit_end_date = as.Date("2024-05-05"),
#'     provider_id = 10L, discharged_to_concept_id = 8536L
#'   ),
#'   provider = tibble::tibble(
#'     provider_id = 10L, specialty_concept_id = 38004465L, specialty_source_value = "110"
#'   ),
#'   condition_occurrence = tibble::tibble(
#'     condition_occurrence_id = 1:2, person_id = 1L, visit_occurrence_id = 1001L,
#'     condition_concept_id = c(4079750L, 316866L),
#'     condition_source_concept_id = c(1001L, 1002L),
#'     condition_status_concept_id = c(32902L, 32908L),
#'     condition_type_concept_id = 32817L,
#'     condition_start_date = as.Date("2024-05-01")
#'   ),
#'   procedure_occurrence = tibble::tibble(
#'     procedure_occurrence_id = 1:2, person_id = 1L, visit_occurrence_id = 1001L,
#'     procedure_concept_id = c(2001L, 2002L), procedure_source_concept_id = 0L,
#'     procedure_date = as.Date("2024-05-01")
#'   ),
#'   concept = tibble::tibble(
#'     concept_id = c(1001L, 1002L, 2001L, 2002L),
#'     vocabulary_id = c("ICD10", "ICD10", "OPCS4", "OPCS4"),
#'     concept_code = c("M16.1", "I10", "W37.1", "Z84.3")
#'   )
#' )
#' inp <- omop_to_hrg(cdm, tables = "2025-26-lp")
#' inp
#' out <- group(grouper("hrg4plus", version = "2025-26-lp"), inp)
#' out$episodes[c("fce_hrg", "grouping_method", "dominant_procedure", "spell_hrg")]
omop_to_hrg <- function(
    cdm,
    visit_concept_ids = c(9201L, 262L),
    episodes = c("spell", "visit_detail"),
    visit_detail_concept_ids = NULL,
    cohort = NULL,
    cohort_id = NULL,
    cohort_match = c("overlap", "index", "subject"),
    person_ids = NULL,
    visit_ids = NULL,
    start_date = NULL,
    end_date = NULL,
    n_max = NULL,
    principal = c("status", "codelist", "cohort_codelist", "all", "first"),
    principal_codes = NULL,
    unmatched = c("keep", "drop"),
    primary_status_concept_ids = c(32902L, 32903L, 32901L),
    primary_type_concept_ids = c(44786627L, 38000183L, 38000199L, 38000200L),
    condition_type_concept_ids = NULL,
    exclude_nlp = TRUE,
    dx_vocabulary = "ICD10",
    pr_vocabulary = "OPCS4",
    vocabulary_fallback = FALSE,
    link_by = c("visit_id", "date_overlap"),
    drop_invalid_secondary = TRUE,
    provider_code = NULL,
    default_provider = "RXX",
    default_classpat = "1",
    admission_method_map = NULL,
    admission_source_map = NULL,
    default_admimeth = "11",
    default_admisorc = "19",
    discharge_method_map = NULL,
    discharge_dest_map = NULL,
    default_dismeth = "1",
    default_disdest = "19",
    specialty_map = NULL,
    default_specialty = "300",
    default_neocare = "8",
    tables = hrg_tables()) {
  if (omop_is_cohort_table(cdm)) {
    if (!is.null(cohort)) {
      cli::cli_abort("When {.arg cdm} is a {.cls cohort_table}, do not also pass {.arg cohort}.")
    }
    parent_cdm <- attr(cdm, "cdm_reference")
    if (is.null(parent_cdm)) {
      cli::cli_abort("{.arg cdm} is a {.cls cohort_table} without an attached {.field cdm_reference} attribute.")
    }
    cohort <- cdm
    cdm <- parent_cdm
  }

  omop_validate_cdm(cdm)
  episodes_mode <- rlang::arg_match(episodes)
  cohort_match <- rlang::arg_match(cohort_match)
  principal <- rlang::arg_match(principal)
  unmatched <- rlang::arg_match(unmatched)
  link_by <- rlang::arg_match(link_by)
  tbls <- hrg_tables(tables)
  start_date <- omop_parse_bound_date(start_date, "start_date")
  end_date <- omop_parse_bound_date(end_date, "end_date")

  coh <- omop_resolve_cohort(cdm, cohort, cohort_id)
  parsed_codes <- NULL
  if (principal == "codelist") {
    parsed_codes <- omop_parse_principal_codes(principal_codes)
    if (length(parsed_codes$values) == 0L) {
      cli::cli_abort("{.arg principal_codes} must be a non-empty vector of ICD-10 codes/prefixes or OMOP concept IDs when {.code principal = \"codelist\"}.")
    }
  } else if (principal == "cohort_codelist") {
    if (is.null(coh$tbl)) {
      cli::cli_abort("{.code principal = \"cohort_codelist\"} requires a {.pkg CohortConstructor} cohort (passed as {.arg cdm} or {.arg cohort}).")
    }
    if (is.null(coh$cohort_codelist) || nrow(coh$cohort_codelist) == 0L) {
      cli::cli_abort(c(
        "{.code principal = \"cohort_codelist\"} requires a non-empty {.field cohort_codelist} attribute on the cohort.",
        i = "Cohorts built with {.fn CohortConstructor::conceptCohort} carry a codelist; cohorts such as {.fn CohortConstructor::demographicsCohort} do not.",
        i = "Use {.code principal = \"status\"}, {.code \"codelist\"}, {.code \"all\"} or {.code \"first\"} instead."
      ))
    }
  }

  cdm_name <- attr(cdm, "cdm_name") %||% "unknown"
  built <- omop_build_stays_query(
    cdm, visit_concept_ids, coh$tbl, cohort_match, person_ids, visit_ids,
    start_date, end_date, n_max
  )
  stays_q <- built$stays_q

  # --- 1. Collect stays with extra NHS admin fields (visit_concept_id,
  #        admitted_from_*, provider_id, care_site_id) + person demographics.
  vo_cols <- colnames(cdm$visit_occurrence)
  admit_cid_col <- if ("admitted_from_concept_id" %in% vo_cols) {
    "admitted_from_concept_id"
  } else if ("admitting_source_concept_id" %in% vo_cols) {
    "admitting_source_concept_id"
  } else {
    NULL
  }
  admit_val_col <- if ("admitted_from_source_value" %in% vo_cols) {
    "admitted_from_source_value"
  } else if ("admitting_source_value" %in% vo_cols) {
    "admitting_source_value"
  } else {
    NULL
  }
  extra_vo_cols <- intersect(
    c("visit_concept_id", admit_cid_col, admit_val_col, "provider_id", "care_site_id"),
    vo_cols
  )
  stays_enriched_q <- stays_q
  if (length(extra_vo_cols) > 0L) {
    vo_extra <- cdm$visit_occurrence |>
      dplyr::select("visit_occurrence_id", dplyr::all_of(extra_vo_cols))
    if (!is.null(admit_cid_col) && admit_cid_col != "admitted_from_concept_id") {
      vo_extra <- dplyr::rename(vo_extra, admitted_from_concept_id = dplyr::all_of(admit_cid_col))
    }
    if (!is.null(admit_val_col) && admit_val_col != "admitted_from_source_value") {
      vo_extra <- dplyr::rename(vo_extra, admitted_from_source_value = dplyr::all_of(admit_val_col))
    }
    stays_enriched_q <- dplyr::left_join(stays_enriched_q, vo_extra, by = "visit_occurrence_id")
  }

  p_cols <- colnames(cdm$person)
  p_keep <- intersect(
    c("person_id", "gender_concept_id", "year_of_birth", "month_of_birth", "day_of_birth", "birth_datetime"),
    p_cols
  )
  stays_enriched_q <- dplyr::left_join(
    stays_enriched_q,
    dplyr::select(cdm$person, dplyr::all_of(p_keep)),
    by = "person_id"
  )
  stays <- dplyr::collect(stays_enriched_q)
  stays$.visit_key <- omop_id_chr(stays$visit_occurrence_id)
  stays$.person_key <- omop_id_chr(stays$person_id)
  stays$visit_start_date <- as.Date(stays$visit_start_date)
  stays$visit_end_date <- if (built$has_visit_end) as.Date(stays$visit_end_date) else as.Date(NA)

  # Apply in-memory cohort windows if needed.
  if (!is.null(built$local_cohort) && nrow(stays) > 0L) {
    lc <- built$local_cohort
    by_vid <- isTRUE(lc$.by_vid[[1]])
    if (by_vid) {
      stays <- stays |>
        dplyr::inner_join(
          lc |> dplyr::select(".join_key", "cohort_definition_id") |> dplyr::distinct(),
          by = c(".visit_key" = ".join_key"),
          relationship = "many-to-many"
        )
    } else {
      joined <- stays |>
        dplyr::inner_join(
          lc |> dplyr::select(".join_key", "cohort_definition_id", "cohort_start_date", "cohort_end_date"),
          by = c(".person_key" = ".join_key"),
          relationship = "many-to-many"
        )
      if (cohort_match == "index") {
        joined <- joined |>
          dplyr::filter(
            !is.na(.data$cohort_start_date),
            .data$visit_start_date <= .data$cohort_start_date,
            dplyr::coalesce(.data$visit_end_date, .data$visit_start_date) >= .data$cohort_start_date
          )
      } else if (cohort_match == "overlap" && any(!is.na(lc$cohort_start_date))) {
        joined <- joined |>
          dplyr::filter(
            is.na(.data$cohort_end_date) & .data$visit_start_date >= .data$cohort_start_date |
              !is.na(.data$cohort_end_date) &
                .data$visit_start_date <= .data$cohort_end_date &
                dplyr::coalesce(.data$visit_end_date, .data$visit_start_date) >= .data$cohort_start_date
          )
      }
      stays <- joined |> dplyr::select(-"cohort_start_date", -"cohort_end_date")
    }
    if (built$has_cohort_id) {
      stays <- dplyr::distinct(stays, .data$cohort_definition_id, .data$.visit_key, .keep_all = TRUE)
    } else {
      stays <- stays |>
        dplyr::select(-"cohort_definition_id") |>
        dplyr::distinct(.data$.visit_key, .keep_all = TRUE)
    }
    if (!is.null(built$post_n_max) && dplyr::n_distinct(stays$.visit_key) > built$post_n_max) {
      keep_vids <- stays |>
        dplyr::distinct(.data$visit_occurrence_id, .data$.visit_key) |>
        dplyr::arrange(.data$visit_occurrence_id) |>
        utils::head(built$post_n_max) |>
        dplyr::pull(".visit_key")
      stays <- stays |> dplyr::filter(.data$.visit_key %in% keep_vids)
    }
  }

  has_cohort_id <- built$has_cohort_id && "cohort_definition_id" %in% names(stays)
  has_cohort_name <- has_cohort_id && !is.null(coh$cohort_set) && "cohort_name" %in% names(coh$cohort_set)
  if (has_cohort_id) {
    stays$cohort_definition_id <- as.integer(stays$cohort_definition_id)
    if (has_cohort_name) {
      cset_map <- coh$cohort_set |>
        dplyr::transmute(
          cohort_definition_id = as.integer(.data$cohort_definition_id),
          cohort_name = as.character(.data$cohort_name)
        ) |>
        dplyr::distinct(.data$cohort_definition_id, .keep_all = TRUE)
      stays <- dplyr::left_join(stays, cset_map, by = "cohort_definition_id")
    }
  }

  cohort_cols <- c(
    if (has_cohort_id) "cohort_definition_id",
    if (has_cohort_name) "cohort_name"
  )

  # Empty stay set -> properly typed 0-row output.
  if (nrow(stays) == 0L) {
    empty_ep <- tibble::tibble(
      PROCODET = character(), PROVSPNO = character(), EPIORDER = character(),
      STARTAGE = character(), SEX = character(), CLASSPAT = character(),
      ADMISORC = character(), ADMIMETH = character(), DISDEST = character(),
      DISMETH = character(), EPIDUR = character(), MAINSPEF = character(),
      TRETSPEF = character(), NEOCARE = character(),
      CRITICALCAREDAYS = character(), REHABILITATIONDAYS = character(),
      SPCDAYS = character(), DIAG_01 = character(), OPER_01 = character()
    )
    empty_meta <- tibble::tibble(episode_id = character())
    if (has_cohort_id) empty_meta$cohort_definition_id <- integer()
    if (has_cohort_name) empty_meta$cohort_name <- character()
    empty_meta <- dplyr::bind_cols(
      empty_meta,
      tibble::tibble(
        visit_occurrence_id = stays$visit_occurrence_id[0],
        person_id = stays$person_id[0],
        episode_start_date = as.Date(character()),
        episode_end_date = as.Date(character()),
        principal_code = character(),
        principal_source = character(),
        n_dx = integer(), n_pr = integer(), n_unmapped_pr = integer(),
        has_unmapped_pr = logical(),
        admission_source = character(), discharge_source = character(),
        specialty_source = character()
      )
    )
    if (principal == "all") empty_meta$candidate_index <- integer()
    quality <- list(
      cdm_name = cdm_name,
      episodes_mode = episodes_mode,
      principal_strategy = principal,
      n_stays = 0L, n_episodes = 0L, n_persons = 0L,
      n_episodes_with_dx = 0L, pct_episodes_with_dx = NA_real_,
      median_dx_per_episode = NA_real_, mean_dx_per_episode = NA_real_,
      n_episodes_with_primary_status = 0L, pct_episodes_with_primary_status = NA_real_,
      n_episodes_with_principal = 0L, pct_episodes_with_principal = NA_real_,
      n_episodes_with_pr = 0L, pct_episodes_with_pr = NA_real_,
      n_episodes_with_unmapped_pr = 0L, pct_episodes_with_unmapped_pr = NA_real_,
      n_dx_padded_x = 0L,
      dx_code_validity = tibble::tibble(status = character(), n_rows = integer(), n_codes = integer()),
      opcs_code_validity = tibble::tibble(status = character(), n_rows = integer(), n_codes = integer()),
      discharge_sources = tibble::tibble(discharge_source = character(), n = integer()),
      specialty_sources = tibble::tibble(specialty_source = character(), n = integer())
    )
    return(structure(
      list(episodes = empty_ep, meta = empty_meta, quality = quality),
      class = c("omop_hrg_input", "list")
    ))
  }

  multi_cohort <- has_cohort_id && dplyr::n_distinct(stays$cohort_definition_id) > 1L
  stays$.spell_key <- if (multi_cohort) {
    paste0(stays$cohort_definition_id, ":", stays$.visit_key)
  } else {
    stays$.visit_key
  }
  stays_vids_q <- dplyr::distinct(stays_q, .data$visit_occurrence_id, .keep_all = TRUE)

  # --- 2. Build episodes (either 1 per spell, or FCEs from visit_detail) -----
  use_vd <- episodes_mode == "visit_detail" && "visit_detail" %in% names(cdm)
  if (episodes_mode == "visit_detail" && !"visit_detail" %in% names(cdm)) {
    cli::cli_inform(c(
      "!" = "{.field visit_detail} is not present in {.arg cdm}; falling back to one episode per spell."
    ))
  }
  vd_rows <- tibble::tibble()
  if (use_vd) {
    vd <- cdm$visit_detail
    vd_cols <- colnames(vd)
    if (!"visit_occurrence_id" %in% vd_cols) {
      cli::cli_abort("{.field visit_detail} must contain {.field visit_occurrence_id} when {.code episodes = \"visit_detail\"}.")
    }
    vd_q <- dplyr::semi_join(vd, stays_vids_q, by = "visit_occurrence_id")
    if (!is.null(visit_detail_concept_ids) && "visit_detail_concept_id" %in% vd_cols) {
      vd_q <- omop_filter_in(vd_q, "visit_detail_concept_id", as.integer(visit_detail_concept_ids))
    }
    vd_keep <- intersect(
      c("visit_detail_id", "visit_occurrence_id", "visit_detail_start_date",
        "visit_detail_end_date", "provider_id", "care_site_id"),
      vd_cols
    )
    vd_rows <- vd_q |>
      dplyr::select(dplyr::all_of(vd_keep)) |>
      dplyr::collect()
    if (nrow(vd_rows) > 0L) {
      vd_rows$.visit_key <- omop_id_chr(vd_rows$visit_occurrence_id)
      vd_rows <- vd_rows |> dplyr::filter(.data$.visit_key %in% stays$.visit_key)
    }
  }

  has_vd_episodes <- nrow(vd_rows) > 0L
  if (has_vd_episodes) {
    vd_rows$.vd_key <- omop_id_chr(vd_rows$visit_detail_id)
    vd_rows$episode_start_date <- as.Date(vd_rows$visit_detail_start_date)
    vd_rows$episode_end_date <- if ("visit_detail_end_date" %in% names(vd_rows)) {
      as.Date(vd_rows$visit_detail_end_date)
    } else {
      vd_rows$episode_start_date
    }
    vd_rows <- vd_rows |>
      dplyr::arrange(.data$.visit_key, .data$episode_start_date, .data$visit_detail_id) |>
      dplyr::group_by(.data$.visit_key) |>
      dplyr::mutate(epi_order = dplyr::row_number()) |>
      dplyr::ungroup()

    stays_with_vd <- unique(vd_rows$.visit_key)
    ep_from_vd <- stays |>
      dplyr::filter(.data$.visit_key %in% stays_with_vd) |>
      dplyr::select(-dplyr::any_of(c("provider_id", "care_site_id"))) |>
      dplyr::inner_join(
        vd_rows |> dplyr::select(
          ".visit_key", "visit_detail_id", ".vd_key", "epi_order",
          "episode_start_date", "episode_end_date",
          dplyr::any_of(c("provider_id", "care_site_id"))
        ),
        by = ".visit_key",
        relationship = "many-to-many"
      )
    ep_fallback <- stays |>
      dplyr::filter(!.data$.visit_key %in% stays_with_vd) |>
      dplyr::mutate(
        visit_detail_id = vd_rows$visit_detail_id[NA_integer_],
        .vd_key = NA_character_,
        epi_order = 1L,
        episode_start_date = .data$visit_start_date,
        episode_end_date = .data$visit_end_date
      )
    ep_base <- dplyr::bind_rows(ep_from_vd, ep_fallback) |>
      dplyr::mutate(.ep_unit_key = ifelse(is.na(.data$.vd_key), .data$.spell_key, paste0(.data$.spell_key, "/", .data$.vd_key)))
  } else {
    ep_base <- stays |>
      dplyr::mutate(
        epi_order = 1L,
        episode_start_date = .data$visit_start_date,
        episode_end_date = .data$visit_end_date,
        .vd_key = NA_character_,
        .ep_unit_key = .data$.spell_key
      )
  }

  # --- 3. Collect provider specialty & care_site provider code if present ----
  spec_cid <- rep(NA_integer_, nrow(ep_base))
  spec_val <- rep(NA_character_, nrow(ep_base))
  if ("provider" %in% names(cdm) && "provider_id" %in% names(ep_base)) {
    p_ids <- unique(stats::na.omit(ep_base$provider_id))
    if (length(p_ids) > 0L) {
      pr_cols <- colnames(cdm$provider)
      pr_keep <- intersect(c("provider_id", "specialty_concept_id", "specialty_source_value"), pr_cols)
      prov_tbl <- omop_filter_in(cdm$provider, "provider_id", p_ids) |>
        dplyr::select(dplyr::all_of(pr_keep)) |>
        dplyr::collect()
      if (nrow(prov_tbl) > 0L) {
        prov_tbl$.prov_key <- omop_id_chr(prov_tbl$provider_id)
        m <- match(omop_id_chr(ep_base$provider_id), prov_tbl$.prov_key)
        if ("specialty_concept_id" %in% names(prov_tbl)) spec_cid <- prov_tbl$specialty_concept_id[m]
        if ("specialty_source_value" %in% names(prov_tbl)) spec_val <- prov_tbl$specialty_source_value[m]
      }
    }
  }

  procodet <- rep(as.character(provider_code %||% default_provider), nrow(ep_base))
  if (is.null(provider_code) && "care_site" %in% names(cdm) && "care_site_id" %in% names(ep_base)) {
    cs_ids <- unique(stats::na.omit(ep_base$care_site_id))
    if (length(cs_ids) > 0L) {
      cs_cols <- colnames(cdm$care_site)
      cs_keep <- intersect(c("care_site_id", "care_site_source_value"), cs_cols)
      cs_tbl <- omop_filter_in(cdm$care_site, "care_site_id", cs_ids) |>
        dplyr::select(dplyr::all_of(cs_keep)) |>
        dplyr::collect()
      if (nrow(cs_tbl) > 0L && "care_site_source_value" %in% names(cs_tbl)) {
        cs_tbl$.cs_key <- omop_id_chr(cs_tbl$care_site_id)
        m <- match(omop_id_chr(ep_base$care_site_id), cs_tbl$.cs_key)
        vals <- trimws(as.character(cs_tbl$care_site_source_value[m]))
        ok <- !is.na(vals) & vals != ""
        procodet[ok] <- vals[ok]
      }
    }
  }

  # --- 4. Collect deaths for scoped persons ----------------------------------
  died <- rep(FALSE, nrow(ep_base))
  if ("death" %in% names(cdm)) {
    deaths <- cdm$death |>
      dplyr::semi_join(stays_q, by = "person_id") |>
      dplyr::select("person_id", "death_date") |>
      dplyr::collect()
    if (nrow(deaths) > 0L) {
      deaths$.person_key <- omop_id_chr(deaths$person_id)
      deaths$death_date <- as.Date(deaths$death_date)
      dead_ep <- ep_base |>
        dplyr::distinct(.data$.ep_unit_key, .data$.person_key, .data$episode_start_date, .data$episode_end_date) |>
        dplyr::inner_join(deaths |> dplyr::select(".person_key", "death_date"), by = ".person_key", relationship = "many-to-many") |>
        dplyr::filter(
          !is.na(.data$death_date),
          .data$death_date >= .data$episode_start_date,
          .data$death_date <= dplyr::coalesce(.data$episode_end_date, .data$episode_start_date)
        ) |>
        dplyr::pull(".ep_unit_key") |>
        unique()
      died <- ep_base$.ep_unit_key %in% dead_ep
    }
  }

  # --- 5. Collect ICD-10 diagnoses -------------------------------------------
  co <- cdm$condition_occurrence
  co_cols <- colnames(co)
  if (link_by == "visit_id" && !"visit_occurrence_id" %in% co_cols) {
    cli::cli_abort("{.field visit_occurrence_id} is absent from {.field condition_occurrence}; use {.code link_by = \"date_overlap\"}.")
  }
  co_scoped <- if (link_by == "visit_id") {
    dplyr::semi_join(co, stays_vids_q, by = "visit_occurrence_id")
  } else {
    vo_win <- stays_vids_q |>
      dplyr::select("visit_occurrence_id", "person_id", "visit_start_date", dplyr::any_of("visit_end_date"))
    co_j <- dplyr::inner_join(co |> dplyr::select(-dplyr::any_of("visit_occurrence_id")), vo_win, by = "person_id")
    if (built$has_visit_end) {
      dplyr::filter(
        co_j,
        .data$condition_start_date >= .data$visit_start_date,
        is.na(.data$visit_end_date) | .data$condition_start_date <= .data$visit_end_date
      )
    } else {
      dplyr::filter(co_j, .data$condition_start_date == .data$visit_start_date)
    }
  }
  if (!is.null(condition_type_concept_ids) && "condition_type_concept_id" %in% co_cols) {
    co_scoped <- omop_filter_in(co_scoped, "condition_type_concept_id", as.integer(condition_type_concept_ids))
  } else if (isTRUE(exclude_nlp) && "condition_type_concept_id" %in% co_cols) {
    co_scoped <- dplyr::filter(
      co_scoped,
      is.na(.data$condition_type_concept_id) | .data$condition_type_concept_id != !!omop_nlp_type_concept_id
    )
  }

  dx_keep <- intersect(
    c("visit_occurrence_id", "visit_detail_id", "condition_occurrence_id",
      "condition_start_date", "condition_concept_id", "condition_source_concept_id",
      "condition_status_concept_id", "condition_type_concept_id"),
    colnames(co_scoped)
  )
  dx_concepts_q <- omop_filter_in(cdm$concept, "vocabulary_id", dx_vocabulary) |>
    dplyr::select("concept_id", code = "concept_code")
  dx_raw <- if ("condition_source_concept_id" %in% co_cols) {
    co_scoped |>
      dplyr::inner_join(dx_concepts_q, by = c("condition_source_concept_id" = "concept_id")) |>
      dplyr::select(dplyr::all_of(dx_keep), "code") |>
      dplyr::collect()
  } else {
    tibble::tibble(visit_occurrence_id = stays$visit_occurrence_id[0], code = character())
  }

  if (isTRUE(vocabulary_fallback) && "concept_relationship" %in% names(cdm)) {
    stays_with_src <- if (nrow(dx_raw) > 0L) unique(omop_id_chr(dx_raw$visit_occurrence_id)) else character()
    if (length(stays_with_src) < dplyr::n_distinct(stays$.visit_key)) {
      dx_snomed <- co_scoped |>
        dplyr::inner_join(
          cdm$concept_relationship |>
            dplyr::filter(.data$relationship_id == "Maps to", is.na(.data$invalid_reason)) |>
            dplyr::select("concept_id_1", "concept_id_2"),
          by = c("condition_concept_id" = "concept_id_2")
        ) |>
        dplyr::inner_join(dx_concepts_q, by = c("concept_id_1" = "concept_id")) |>
        dplyr::select(dplyr::all_of(dx_keep), "code") |>
        dplyr::collect()
      if (nrow(dx_snomed) > 0L) {
        dx_snomed$.visit_key <- omop_id_chr(dx_snomed$visit_occurrence_id)
        dx_snomed <- dx_snomed |>
          dplyr::filter(!.data$.visit_key %in% stays_with_src) |>
          dplyr::select(-".visit_key")
        dx_raw <- dplyr::bind_rows(dx_raw, dx_snomed)
      }
    }
  }

  valid_icd <- tbls$icd_valid
  icd_headers <- hrg_icd_header_prefixes(valid_icd)
  n_dx_padded_x <- 0L

  # Assign each diagnosis row to its episode key(s) in `ep_base`.
  link_events_to_episodes <- function(ev, date_col) {
    if (nrow(ev) == 0L) {
      ev$.ep_unit_key <- character()
      return(ev)
    }
    ev$.visit_key <- omop_id_chr(ev$visit_occurrence_id)
    ev <- ev |> dplyr::filter(.data$.visit_key %in% stays$.visit_key)
    if (nrow(ev) == 0L) {
      ev$.ep_unit_key <- character()
      return(ev)
    }
    if (!has_vd_episodes) {
      return(dplyr::inner_join(
        ev,
        ep_base |> dplyr::select(".visit_key", ".ep_unit_key"),
        by = ".visit_key",
        relationship = "many-to-many"
      ))
    }
    has_ev_vd <- "visit_detail_id" %in% names(ev)
    ev$.ev_vd <- if (has_ev_vd) omop_id_chr(ev$visit_detail_id) else NA_character_
    ev$.ev_vd[!is.na(ev$.ev_vd) & ev$.ev_vd %in% c("", "0")] <- NA_character_
    by_vd <- ev |>
      dplyr::filter(!is.na(.data$.ev_vd)) |>
      dplyr::inner_join(
        ep_base |> dplyr::filter(!is.na(.data$.vd_key)) |> dplyr::select(".visit_key", ".vd_key", ".ep_unit_key"),
        by = c(".visit_key", ".ev_vd" = ".vd_key"),
        relationship = "many-to-many"
      )
    no_vd <- ev |> dplyr::filter(is.na(.data$.ev_vd))
    if (nrow(no_vd) > 0L) {
      no_vd$.ev_date <- if (date_col %in% names(no_vd)) as.Date(no_vd[[date_col]]) else as.Date(NA)
      by_date <- no_vd |>
        dplyr::inner_join(
          ep_base |> dplyr::select(".visit_key", ".ep_unit_key", "episode_start_date", "episode_end_date"),
          by = ".visit_key",
          relationship = "many-to-many"
        ) |>
        dplyr::filter(
          is.na(.data$.ev_date) |
            (.data$.ev_date >= .data$episode_start_date &
               .data$.ev_date <= dplyr::coalesce(.data$episode_end_date, .data$episode_start_date))
        ) |>
        dplyr::select(-".ev_date", -"episode_start_date", -"episode_end_date")
    } else {
      by_date <- by_vd[0, ]
    }
    dplyr::bind_rows(by_vd, by_date) |> dplyr::select(-".ev_vd")
  }

  dx_ep_raw <- link_events_to_episodes(dx_raw, "condition_start_date")
  if (nrow(dx_ep_raw) > 0L) {
    norm <- hrg_normalize_icd10(dx_ep_raw$code, valid_icd)
    dx_ep_raw$code <- norm$code
    dx_ep_raw$padded_x <- norm$padded_x
    dx_ep_raw <- dx_ep_raw |> dplyr::filter(!is.na(.data$code))
    is_prim_status <- if ("condition_status_concept_id" %in% names(dx_ep_raw)) {
      !is.na(dx_ep_raw$condition_status_concept_id) &
        as.integer(dx_ep_raw$condition_status_concept_id) %in% as.integer(primary_status_concept_ids)
    } else {
      rep(FALSE, nrow(dx_ep_raw))
    }
    is_prim_type <- if ("condition_type_concept_id" %in% names(dx_ep_raw)) {
      !is.na(dx_ep_raw$condition_type_concept_id) &
        as.integer(dx_ep_raw$condition_type_concept_id) %in% as.integer(primary_type_concept_ids)
    } else {
      rep(FALSE, nrow(dx_ep_raw))
    }
    dx_ep_raw$is_primary <- is_prim_status | is_prim_type
    dx_ep_raw$dx_date <- if ("condition_start_date" %in% names(dx_ep_raw)) as.Date(dx_ep_raw$condition_start_date) else as.Date(NA)
    dx_ep_raw$dx_id_chr <- if ("condition_occurrence_id" %in% names(dx_ep_raw)) omop_id_chr(dx_ep_raw$condition_occurrence_id) else as.character(seq_len(nrow(dx_ep_raw)))
    dx_ep_raw$is_valid <- dx_ep_raw$code %in% valid_icd
    dx_ep_raw$is_header <- !dx_ep_raw$is_valid & dx_ep_raw$code %in% icd_headers
    dx_ep_raw$.cond_cid <- if ("condition_concept_id" %in% names(dx_ep_raw)) as.integer(dx_ep_raw$condition_concept_id) else NA_integer_
    dx_ep_raw$.src_cid <- if ("condition_source_concept_id" %in% names(dx_ep_raw)) as.integer(dx_ep_raw$condition_source_concept_id) else NA_integer_

    dx_dedup <- dx_ep_raw |>
      dplyr::arrange(.data$.ep_unit_key, .data$code, dplyr::desc(.data$is_primary), .data$dx_date, .data$dx_id_chr) |>
      dplyr::distinct(.data$.ep_unit_key, .data$code, .keep_all = TRUE)
    n_dx_padded_x <- sum(dx_dedup$padded_x)
  } else {
    dx_dedup <- tibble::tibble(
      .ep_unit_key = character(), code = character(), is_primary = logical(),
      dx_date = as.Date(character()), dx_id_chr = character(),
      is_valid = logical(), is_header = logical(), padded_x = logical()
    )
  }

  # --- 6. Collect OPCS-4 procedures (preserving recorded order!) -------------
  valid_opcs <- tbls$opcs_valid
  pr_ep <- tibble::tibble(.ep_unit_key = character(), code = character(), pr_date = as.Date(character()), pr_id_chr = character(), is_valid = logical())
  pr_counts <- tibble::tibble(.ep_unit_key = character(), n_pr = integer(), n_unmapped_pr = integer())
  if ("procedure_occurrence" %in% names(cdm)) {
    po <- cdm$procedure_occurrence
    po_cols <- colnames(po)
    if (link_by == "visit_id" && !"visit_occurrence_id" %in% po_cols) {
      cli::cli_abort("{.field visit_occurrence_id} is absent from {.field procedure_occurrence}; use {.code link_by = \"date_overlap\"}.")
    }
    po_scoped <- if (link_by == "visit_id") {
      dplyr::semi_join(po, stays_vids_q, by = "visit_occurrence_id")
    } else {
      vo_win <- stays_vids_q |>
        dplyr::select("visit_occurrence_id", "person_id", "visit_start_date", dplyr::any_of("visit_end_date"))
      po_j <- dplyr::inner_join(po |> dplyr::select(-dplyr::any_of("visit_occurrence_id")), vo_win, by = "person_id")
      if (built$has_visit_end && "procedure_date" %in% po_cols) {
        dplyr::filter(
          po_j,
          .data$procedure_date >= .data$visit_start_date,
          is.na(.data$visit_end_date) | .data$procedure_date <= .data$visit_end_date
        )
      } else if ("procedure_date" %in% po_cols) {
        dplyr::filter(po_j, .data$procedure_date == .data$visit_start_date)
      } else {
        po_j
      }
    }
    opcs_concepts <- omop_filter_in(cdm$concept, "vocabulary_id", pr_vocabulary) |>
      dplyr::select("concept_id", "concept_code")
    po_j <- po_scoped
    if ("procedure_concept_id" %in% po_cols) {
      po_j <- dplyr::left_join(
        po_j,
        dplyr::rename(opcs_concepts, std_code = "concept_code"),
        by = c("procedure_concept_id" = "concept_id")
      )
    }
    if ("procedure_source_concept_id" %in% po_cols) {
      po_j <- dplyr::left_join(
        po_j,
        dplyr::rename(opcs_concepts, src_code = "concept_code"),
        by = c("procedure_source_concept_id" = "concept_id")
      )
    }
    pr_keep <- intersect(
      c("visit_occurrence_id", "visit_detail_id", "procedure_occurrence_id",
        "procedure_date", "std_code", "src_code"),
      colnames(po_j)
    )
    pr_raw <- po_j |>
      dplyr::select(dplyr::all_of(pr_keep)) |>
      dplyr::collect()
    pr_linked <- link_events_to_episodes(pr_raw, "procedure_date")
    if (nrow(pr_linked) > 0L) {
      std_c <- if ("std_code" %in% names(pr_linked)) pr_linked$std_code else rep(NA_character_, nrow(pr_linked))
      src_c <- if ("src_code" %in% names(pr_linked)) pr_linked$src_code else rep(NA_character_, nrow(pr_linked))
      pr_linked$code <- hrg_normalize_opcs4(dplyr::coalesce(std_c, src_c))
      pr_linked$pr_date <- if ("procedure_date" %in% names(pr_linked)) as.Date(pr_linked$procedure_date) else as.Date(NA)
      pr_linked$pr_id_num <- if ("procedure_occurrence_id" %in% names(pr_linked)) seq_len(nrow(pr_linked)) else seq_len(nrow(pr_linked))
      pr_linked$pr_id_chr <- if ("procedure_occurrence_id" %in% names(pr_linked)) omop_id_chr(pr_linked$procedure_occurrence_id) else sprintf("%012d", seq_len(nrow(pr_linked)))
      pr_linked$is_valid <- !is.na(pr_linked$code) & pr_linked$code %in% valid_opcs

      pr_counts <- pr_linked |>
        dplyr::group_by(.data$.ep_unit_key) |>
        dplyr::summarise(
          n_pr = sum(!is.na(.data$code)),
          n_unmapped_pr = sum(is.na(.data$code)),
          .groups = "drop"
        )
      # Preserve recorded procedure order (date, numeric/char procedure_occurrence_id)
      # so OPCS-4 qualifier runs (Z/Y codes) remain adjacent to their driver!
      ord_id <- if ("procedure_occurrence_id" %in% names(pr_linked) && is.numeric(pr_linked$procedure_occurrence_id)) {
        pr_linked$procedure_occurrence_id
      } else {
        pr_linked$pr_id_chr
      }
      pr_linked$.ord_id <- ord_id
      pr_ep <- pr_linked |>
        dplyr::filter(!is.na(.data$code)) |>
        dplyr::arrange(.data$.ep_unit_key, .data$pr_date, .data$.ord_id, .data$code) |>
        dplyr::select(".ep_unit_key", "code", "pr_date", "pr_id_chr", "is_valid")
    }
  }

  # --- 7. Resolve demographics & NHS administrative fields -------------------
  age <- omop_compute_age(
    ep_base$episode_start_date,
    if ("birth_datetime" %in% names(ep_base)) ep_base$birth_datetime else NULL,
    ep_base$year_of_birth,
    if ("month_of_birth" %in% names(ep_base)) ep_base$month_of_birth else NULL,
    if ("day_of_birth" %in% names(ep_base)) ep_base$day_of_birth else NULL
  )
  startage <- ifelse(is.na(age) | age < 0L | age > 130L, "999", as.character(as.integer(age)))
  sex <- dplyr::case_when(
    as.integer(ep_base$gender_concept_id) == 8507L ~ "1",
    as.integer(ep_base$gender_concept_id) == 8532L ~ "2",
    TRUE ~ "9"
  )
  epidur <- as.integer(ep_base$episode_end_date - ep_base$episode_start_date)
  epidur[is.na(epidur) | epidur < 0L] <- 0L

  admit <- omop_hrg_resolve_admission(
    visit_concept_id = if ("visit_concept_id" %in% names(ep_base)) ep_base$visit_concept_id else rep(9201L, nrow(ep_base)),
    admit_cid = if ("admitted_from_concept_id" %in% names(ep_base)) ep_base$admitted_from_concept_id else NULL,
    admit_val = if ("admitted_from_source_value" %in% names(ep_base)) ep_base$admitted_from_source_value else NULL,
    admission_method_map = admission_method_map,
    admission_source_map = admission_source_map,
    default_admimeth = default_admimeth,
    default_admisorc = default_admisorc
  )
  disc <- omop_hrg_resolve_discharge(
    died = died,
    disc_val = if ("discharged_to_source_value" %in% names(ep_base)) ep_base$discharged_to_source_value else NULL,
    disc_cid = if ("discharged_to_concept_id" %in% names(ep_base)) ep_base$discharged_to_concept_id else NULL,
    discharge_method_map = discharge_method_map,
    discharge_dest_map = discharge_dest_map,
    default_dismeth = default_dismeth,
    default_disdest = default_disdest
  )
  spec <- omop_hrg_resolve_specialty(
    spec_cid = spec_cid,
    spec_val = spec_val,
    specialty_map = specialty_map,
    default_specialty = default_specialty,
    valid_main = tbls$field_valid$MAINSPEF,
    valid_tret = tbls$field_valid$TRETSPEF
  )
  dx_counts <- dx_dedup |> dplyr::count(.data$.ep_unit_key, name = "n_dx")

  ep_core <- tibble::tibble(
    .ep_unit_key = ep_base$.ep_unit_key,
    .spell_key = ep_base$.spell_key,
    .visit_key = ep_base$.visit_key,
    visit_occurrence_id = ep_base$visit_occurrence_id,
    person_id = ep_base$person_id,
    episode_start_date = ep_base$episode_start_date,
    episode_end_date = ep_base$episode_end_date,
    PROCODET = procodet,
    PROVSPNO = ep_base$.spell_key,
    EPIORDER = as.character(ep_base$epi_order),
    STARTAGE = startage,
    SEX = sex,
    CLASSPAT = as.character(default_classpat),
    ADMISORC = admit$ADMISORC,
    ADMIMETH = admit$ADMIMETH,
    DISDEST = disc$DISDEST,
    DISMETH = disc$DISMETH,
    EPIDUR = as.character(epidur),
    MAINSPEF = spec$MAINSPEF,
    TRETSPEF = spec$TRETSPEF,
    NEOCARE = as.character(default_neocare),
    CRITICALCAREDAYS = "0",
    REHABILITATIONDAYS = "0",
    SPCDAYS = "0",
    admission_source = admit$admission_source,
    discharge_source = disc$discharge_source,
    specialty_source = spec$specialty_source
  )
  if (has_cohort_id) ep_core$cohort_definition_id <- ep_base$cohort_definition_id
  if (has_cohort_name) ep_core$cohort_name <- ep_base$cohort_name
  if (has_vd_episodes) ep_core$visit_detail_id <- ep_base$visit_detail_id

  ep_core <- ep_core |>
    dplyr::left_join(dx_counts, by = ".ep_unit_key") |>
    dplyr::left_join(pr_counts, by = ".ep_unit_key") |>
    dplyr::mutate(
      n_dx = dplyr::coalesce(.data$n_dx, 0L),
      n_pr = dplyr::coalesce(.data$n_pr, 0L),
      n_unmapped_pr = dplyr::coalesce(.data$n_unmapped_pr, 0L),
      has_unmapped_pr = .data$n_unmapped_pr > 0L
    )

  # --- 8. Apply principal-diagnosis strategy & pivot DIAG_nn / OPER_nn -------
  n_ep_with_primary_status <- dplyr::n_distinct(dx_dedup$.ep_unit_key[dx_dedup$is_primary])

  if (principal == "all") {
    cand <- dx_dedup |>
      dplyr::arrange(.data$.ep_unit_key, dplyr::desc(.data$is_primary), .data$dx_date, .data$code) |>
      dplyr::group_by(.data$.ep_unit_key) |>
      dplyr::mutate(candidate_index = dplyr::row_number()) |>
      dplyr::ungroup() |>
      dplyr::select(".ep_unit_key", "candidate_index", principal_code = "code") |>
      dplyr::mutate(principal_source = "all")

    no_dx_ep <- ep_core |>
      dplyr::filter(.data$n_dx == 0L) |>
      dplyr::transmute(.data$.ep_unit_key, candidate_index = 0L, principal_code = NA_character_, principal_source = "none")

    cand_all <- dplyr::bind_rows(cand, no_dx_ep)
    ep_rows <- ep_core |>
      dplyr::inner_join(cand_all, by = ".ep_unit_key", relationship = "many-to-many") |>
      dplyr::mutate(
        .ep_key = paste0(.data$.ep_unit_key, "#", .data$candidate_index),
        PROVSPNO = paste0(.data$.spell_key, "#", .data$candidate_index)
      )
  } else {
    if (principal == "status") {
      if (n_ep_with_primary_status == 0L && nrow(dx_dedup) > 0L) {
        cli::cli_inform(c(
          "!" = "No primary diagnosis flags found in {.field condition_status_concept_id} (or legacy {.field condition_type_concept_id}).",
          i = "Episodes without a primary diagnosis will leave {.field DIAG_01} blank and group to {.val UZ01Z}.",
          i = "Supply {.code principal = \"codelist\"} with {.arg principal_codes}, {.code principal = \"cohort_codelist\"} (with a {.pkg CohortConstructor} concept cohort), {.code principal = \"all\"} for a multi-candidate sensitivity analysis, or {.code principal = \"first\"}."
        ))
      }
      chosen <- dx_dedup |>
        dplyr::filter(.data$is_primary) |>
        dplyr::arrange(.data$.ep_unit_key, dplyr::desc(.data$is_valid), .data$dx_date, .data$dx_id_chr, .data$code) |>
        dplyr::distinct(.data$.ep_unit_key, .keep_all = TRUE) |>
        dplyr::transmute(.data$.ep_unit_key, principal_code = .data$code, principal_source = "status")
    } else if (principal == "codelist") {
      if (parsed_codes$type == "code") {
        # Match against both normalized (e.g. I10X) and unpadded codes so prefix "I10" matches "I10X".
        m <- omop_match_codelist(dx_dedup$code, parsed_codes$values)
        chosen <- dx_dedup |>
          dplyr::mutate(.rank = m$rank, .exact = m$exact) |>
          dplyr::filter(is.finite(.data$.rank)) |>
          dplyr::arrange(.data$.ep_unit_key, .data$.rank, dplyr::desc(.data$is_valid), dplyr::desc(.data$.exact), .data$dx_date, .data$code) |>
          dplyr::distinct(.data$.ep_unit_key, .keep_all = TRUE) |>
          dplyr::transmute(.data$.ep_unit_key, principal_code = .data$code, principal_source = "codelist")
      } else {
        cids <- parsed_codes$values
        if (nrow(dx_ep_raw) > 0L) {
          r_std <- match(dx_ep_raw$.cond_cid, cids)
          r_src <- match(dx_ep_raw$.src_cid, cids)
          rank <- pmin(dplyr::coalesce(r_std, Inf), dplyr::coalesce(r_src, Inf))
          chosen <- dx_ep_raw |>
            dplyr::mutate(.rank = rank) |>
            dplyr::filter(is.finite(.data$.rank)) |>
            dplyr::arrange(.data$.ep_unit_key, .data$.rank, dplyr::desc(.data$is_valid), .data$dx_date, .data$dx_id_chr, .data$code) |>
            dplyr::distinct(.data$.ep_unit_key, .keep_all = TRUE) |>
            dplyr::transmute(.data$.ep_unit_key, principal_code = .data$code, principal_source = "codelist")
        } else {
          chosen <- tibble::tibble(.ep_unit_key = character(), principal_code = character(), principal_source = character())
        }
      }
    } else if (principal == "cohort_codelist") {
      cc <- coh$cohort_codelist
      if ("codelist_type" %in% names(cc) && any(cc$codelist_type == "index event", na.rm = TRUE)) {
        cc <- dplyr::filter(cc, .data$codelist_type == "index event")
      }
      cc <- cc |>
        dplyr::transmute(
          cohort_definition_id = as.integer(.data$cohort_definition_id),
          concept_id = as.integer(.data$concept_id)
        ) |>
        dplyr::distinct()

      if (nrow(dx_ep_raw) > 0L && has_cohort_id) {
        ep_dx <- ep_core |>
          dplyr::select(".ep_unit_key", "cohort_definition_id") |>
          dplyr::inner_join(
            dx_ep_raw |> dplyr::select(".ep_unit_key", "code", "is_valid", "dx_date", "dx_id_chr", ".cond_cid", ".src_cid"),
            by = ".ep_unit_key",
            relationship = "many-to-many"
          )
        hit_std <- dplyr::inner_join(ep_dx, cc, by = c("cohort_definition_id", ".cond_cid" = "concept_id"))
        hit_src <- dplyr::inner_join(ep_dx, cc, by = c("cohort_definition_id", ".src_cid" = "concept_id"))
        chosen <- dplyr::bind_rows(hit_std, hit_src) |>
          dplyr::arrange(.data$.ep_unit_key, dplyr::desc(.data$is_valid), .data$dx_date, .data$dx_id_chr, .data$code) |>
          dplyr::distinct(.data$.ep_unit_key, .keep_all = TRUE) |>
          dplyr::transmute(.data$.ep_unit_key, principal_code = .data$code, principal_source = "cohort_codelist")
      } else {
        chosen <- tibble::tibble(.ep_unit_key = character(), principal_code = character(), principal_source = character())
      }
    } else {
      chosen <- dx_dedup |>
        dplyr::arrange(.data$.ep_unit_key, dplyr::desc(.data$is_primary), dplyr::desc(.data$is_valid), .data$dx_date, .data$dx_id_chr, .data$code) |>
        dplyr::distinct(.data$.ep_unit_key, .keep_all = TRUE) |>
        dplyr::transmute(.data$.ep_unit_key, principal_code = .data$code, principal_source = "first")
    }

    ep_rows <- ep_core |>
      dplyr::left_join(chosen, by = ".ep_unit_key") |>
      dplyr::mutate(
        .ep_key = .data$.ep_unit_key,
        principal_source = dplyr::coalesce(.data$principal_source, "none")
      )

    if (unmatched == "drop") {
      ep_rows <- ep_rows |> dplyr::filter(.data$principal_source != "none")
    }
  }

  # Deterministic episode ordering.
  if (has_cohort_id && principal == "all") {
    ep_rows <- dplyr::arrange(ep_rows, .data$cohort_definition_id, .data$visit_occurrence_id, as.integer(.data$EPIORDER), .data$candidate_index)
  } else if (has_cohort_id) {
    ep_rows <- dplyr::arrange(ep_rows, .data$cohort_definition_id, .data$visit_occurrence_id, as.integer(.data$EPIORDER))
  } else if (principal == "all") {
    ep_rows <- dplyr::arrange(ep_rows, .data$visit_occurrence_id, as.integer(.data$EPIORDER), .data$candidate_index)
  } else {
    ep_rows <- dplyr::arrange(ep_rows, .data$visit_occurrence_id, as.integer(.data$EPIORDER))
  }

  # Build positioned DIAG_01..DIAG_nn and OPER_01..OPER_nn matrices.
  dx_for_pivot <- dx_dedup |>
    dplyr::inner_join(
      ep_rows |> dplyr::select(".ep_key", ".ep_unit_key", "principal_code"),
      by = ".ep_unit_key",
      relationship = "many-to-many"
    ) |>
    dplyr::mutate(.is_pdx = !is.na(.data$principal_code) & .data$code == .data$principal_code)
  if (isTRUE(drop_invalid_secondary)) {
    dx_for_pivot <- dx_for_pivot |> dplyr::filter(.data$.is_pdx | .data$is_valid)
  }
  dx_for_pivot <- dx_for_pivot |>
    dplyr::arrange(.data$.ep_key, dplyr::desc(.data$.is_pdx), .data$dx_date, .data$code) |>
    dplyr::group_by(.data$.ep_key) |>
    dplyr::mutate(pos = if (any(.data$.is_pdx)) dplyr::row_number() else dplyr::row_number() + 1L) |>
    dplyr::ungroup() |>
    dplyr::select(".ep_key", "pos", "code")

  pr_for_pivot <- pr_ep |>
    dplyr::inner_join(
      ep_rows |> dplyr::select(".ep_key", ".ep_unit_key"),
      by = ".ep_unit_key",
      relationship = "many-to-many"
    )
  if (isTRUE(drop_invalid_secondary)) {
    pr_for_pivot <- pr_for_pivot |> dplyr::filter(.data$is_valid)
  }
  pr_for_pivot <- pr_for_pivot |>
    dplyr::group_by(.data$.ep_key) |>
    dplyr::mutate(pos = dplyr::row_number()) |>
    dplyr::ungroup() |>
    dplyr::select(".ep_key", "pos", "code")

  diag_wide <- omop_hrg_pivot_codes(ep_rows$.ep_key, dx_for_pivot, "DIAG", min_cols = 1L)
  oper_wide <- omop_hrg_pivot_codes(ep_rows$.ep_key, pr_for_pivot, "OPER", min_cols = 1L)

  nhs_cols <- c(
    "PROCODET", "PROVSPNO", "EPIORDER", "STARTAGE", "SEX", "CLASSPAT",
    "ADMISORC", "ADMIMETH", "DISDEST", "DISMETH", "EPIDUR", "MAINSPEF",
    "TRETSPEF", "NEOCARE", "CRITICALCAREDAYS", "REHABILITATIONDAYS", "SPCDAYS"
  )
  episodes_tbl <- dplyr::bind_cols(ep_rows[nhs_cols], diag_wide, oper_wide)

  meta_cols <- c(
    cohort_cols,
    "visit_occurrence_id",
    if (has_vd_episodes) "visit_detail_id",
    "person_id",
    if (principal == "all") "candidate_index",
    "episode_start_date", "episode_end_date",
    "principal_code", "principal_source",
    "n_dx", "n_pr", "n_unmapped_pr", "has_unmapped_pr",
    "admission_source", "discharge_source", "specialty_source"
  )
  meta_tbl <- ep_rows |>
    dplyr::transmute(episode_id = .data$.ep_key, dplyr::across(dplyr::all_of(meta_cols)))

  # --- 9. Quality / readiness summary ----------------------------------------
  unique_ep <- dplyr::distinct(ep_core, .data$.ep_unit_key, .keep_all = TRUE)
  n_ep_total <- nrow(unique_ep)
  n_stays_total <- dplyr::n_distinct(stays$.visit_key)
  n_with_dx <- sum(unique_ep$n_dx > 0L)
  n_with_pr <- sum(unique_ep$n_pr > 0L)
  n_with_unmapped_pr <- sum(unique_ep$has_unmapped_pr)
  n_with_principal <- dplyr::n_distinct(ep_rows$.ep_unit_key[ep_rows$principal_source != "none"])
  dx_per_coded_ep <- unique_ep$n_dx[unique_ep$n_dx > 0L]

  dx_validity <- if (nrow(dx_dedup) > 0L) {
    dx_dedup |>
      dplyr::mutate(status = dplyr::case_when(
        .data$is_valid ~ "valid",
        .data$is_header ~ "category_header",
        TRUE ~ "unrecognised"
      )) |>
      dplyr::group_by(.data$status) |>
      dplyr::summarise(n_rows = dplyr::n(), n_codes = dplyr::n_distinct(.data$code), .groups = "drop")
  } else {
    tibble::tibble(status = character(), n_rows = integer(), n_codes = integer())
  }
  opcs_validity <- if (nrow(pr_ep) > 0L) {
    pr_ep |>
      dplyr::mutate(status = ifelse(.data$is_valid, "valid", "unrecognised")) |>
      dplyr::group_by(.data$status) |>
      dplyr::summarise(n_rows = dplyr::n(), n_codes = dplyr::n_distinct(.data$code), .groups = "drop")
  } else {
    tibble::tibble(status = character(), n_rows = integer(), n_codes = integer())
  }

  quality <- list(
    cdm_name = cdm_name,
    episodes_mode = if (has_vd_episodes) "visit_detail" else "spell",
    principal_strategy = principal,
    n_stays = n_stays_total,
    n_episodes = nrow(episodes_tbl),
    n_persons = dplyr::n_distinct(stays$.person_key),
    n_episodes_with_dx = n_with_dx,
    pct_episodes_with_dx = 100 * n_with_dx / n_ep_total,
    median_dx_per_episode = if (length(dx_per_coded_ep) > 0L) stats::median(dx_per_coded_ep) else NA_real_,
    mean_dx_per_episode = if (length(dx_per_coded_ep) > 0L) mean(dx_per_coded_ep) else NA_real_,
    n_episodes_with_primary_status = n_ep_with_primary_status,
    pct_episodes_with_primary_status = 100 * n_ep_with_primary_status / n_ep_total,
    n_episodes_with_principal = n_with_principal,
    pct_episodes_with_principal = 100 * n_with_principal / n_ep_total,
    n_episodes_with_pr = n_with_pr,
    pct_episodes_with_pr = 100 * n_with_pr / n_ep_total,
    n_episodes_with_unmapped_pr = n_with_unmapped_pr,
    pct_episodes_with_unmapped_pr = 100 * n_with_unmapped_pr / n_ep_total,
    n_dx_padded_x = n_dx_padded_x,
    dx_code_validity = dx_validity,
    opcs_code_validity = opcs_validity,
    discharge_sources = unique_ep |> dplyr::count(.data$discharge_source, sort = TRUE),
    specialty_sources = unique_ep |> dplyr::count(.data$specialty_source, sort = TRUE)
  )
  if (has_cohort_id) {
    quality$cohorts <- ep_rows |>
      dplyr::group_by(dplyr::across(dplyr::all_of(cohort_cols))) |>
      dplyr::summarise(
        n_stays = dplyr::n_distinct(.data$.visit_key),
        n_episodes = dplyr::n(),
        n_with_principal = sum(.data$principal_source != "none"),
        .groups = "drop"
      )
  }

  structure(
    list(episodes = episodes_tbl, meta = meta_tbl, quality = quality),
    class = c("omop_hrg_input", "list")
  )
}

#' @export
print.omop_hrg_input <- function(x, ...) {
  q <- x$quality
  cat(sprintf("<opendrg OMOP HRG4+ input> CDM: %s (episodes = \"%s\", principal = \"%s\")\n",
              q$cdm_name, q$episodes_mode, q$principal_strategy))
  cat(sprintf(
    "Stays: %s (%s persons) -> %s episode%s\n",
    format(q$n_stays, big.mark = ","),
    format(q$n_persons, big.mark = ","),
    format(q$n_episodes, big.mark = ","),
    if (q$n_episodes == 1L) "" else "s"
  ))
  if (q$n_stays > 0L) {
    cat(sprintf(
      "Diagnoses (ICD-10): %.1f%% coded (median %.0f, mean %.1f; %s 3-char X-padded); %.1f%% OMOP primary flag; %.1f%% principal assigned\n",
      q$pct_episodes_with_dx, q$median_dx_per_episode, q$mean_dx_per_episode,
      format(q$n_dx_padded_x, big.mark = ",", trim = TRUE),
      q$pct_episodes_with_primary_status, q$pct_episodes_with_principal
    ))
    cat(sprintf(
      "Procedures (OPCS-4): %.1f%% with OPCS-4; %.1f%% with unmapped procedures\n",
      q$pct_episodes_with_pr, q$pct_episodes_with_unmapped_pr
    ))
  }
  invisible(x)
}

#' Compute NHS England HRG4+ groups for patients in an OMOP CDM or cohort
#'
#' Given a `cdm_reference` object from `CDMConnector` (or `omopgenerics`) — or
#' directly a `CohortConstructor` `cohort_table` — extracts inpatient episodes
#' with [omop_to_hrg()], groups them with [hrg_group_apc()], and returns a list
#' with `episodes` and `spells` tibbles joining OMOP cohort/patient/visit
#' identifiers with the assigned episode (`fce_hrg`) and spell (`spell_hrg`)
#' HRG4+ groups, unbundled HRGs, dominant procedures, programme budgeting
#' categories, and validation messages.
#'
#' This function can also be invoked through the unified interface via
#' `group(grouper("hrg4plus"), cdm, ...)` or
#' `group(grouper("hrg4plus"), cdm$my_cohort, ...)`.
#'
#' @param cdm A `cdm_reference` object (from `CDMConnector::cdmFromCon()` or
#'   `omopgenerics::cdmFromTables()`), a `CohortConstructor` `cohort_table`, or
#'   a named list of OMOP tables.
#' @param tables HRG4+ logic tables from [hrg_tables()] or a version label such
#'   as `"2025-26-lp"` or `"2024-25-nc"`.
#' @param ... Additional arguments passed to [omop_to_hrg()] (such as
#'   `episodes`, `cohort`, `cohort_id`, `cohort_match`, `start_date`,
#'   `end_date`, `n_max`, `principal`, `principal_codes`, `unmatched`,
#'   `specialty_map`, `admission_method_map`, `discharge_method_map`,
#'   `vocabulary_fallback`, `link_by`).
#' @return A list with `episodes` and `spells` tibbles, with the CDM readiness
#'   and grouping quality report attached (inspect via [omop_hrg_quality()]).
#' @export
#' @examples
#' cdm <- list(
#'   person = tibble::tibble(
#'     person_id = 1L, gender_concept_id = 8532L,
#'     year_of_birth = 1952L, month_of_birth = 3L, day_of_birth = 10L
#'   ),
#'   visit_occurrence = tibble::tibble(
#'     visit_occurrence_id = 1001L, person_id = 1L, visit_concept_id = 9201L,
#'     visit_start_date = as.Date("2024-05-01"), visit_end_date = as.Date("2024-05-05"),
#'     provider_id = 10L, discharged_to_concept_id = 8536L
#'   ),
#'   provider = tibble::tibble(
#'     provider_id = 10L, specialty_concept_id = 38004465L, specialty_source_value = "110"
#'   ),
#'   condition_occurrence = tibble::tibble(
#'     condition_occurrence_id = 1:2, person_id = 1L, visit_occurrence_id = 1001L,
#'     condition_concept_id = c(4079750L, 316866L),
#'     condition_source_concept_id = c(1001L, 1002L),
#'     condition_status_concept_id = c(32902L, 32908L),
#'     condition_type_concept_id = 32817L,
#'     condition_start_date = as.Date("2024-05-01")
#'   ),
#'   procedure_occurrence = tibble::tibble(
#'     procedure_occurrence_id = 1:2, person_id = 1L, visit_occurrence_id = 1001L,
#'     procedure_concept_id = c(2001L, 2002L), procedure_source_concept_id = 0L,
#'     procedure_date = as.Date("2024-05-01")
#'   ),
#'   concept = tibble::tibble(
#'     concept_id = c(1001L, 1002L, 2001L, 2002L),
#'     vocabulary_id = c("ICD10", "ICD10", "OPCS4", "OPCS4"),
#'     concept_code = c("M16.1", "I10", "W37.1", "Z84.3")
#'   )
#' )
#' res <- omop_hrg(cdm, tables = "2025-26-lp")
#' res$episodes[c("person_id", "visit_occurrence_id", "fce_hrg", "dominant_procedure", "spell_hrg")]
#' omop_hrg_quality(res)
omop_hrg <- function(cdm, tables = hrg_tables(), ...) {
  tbls <- hrg_tables(tables)
  inp <- omop_to_hrg(cdm, ..., tables = tbls)

  if (nrow(inp$episodes) == 0L) {
    empty_ep <- dplyr::bind_cols(
      inp$meta,
      tibble::tibble(
        fce_hrg = character(), grouping_method = character(),
        dominant_procedure = character(), fce_pbc = character(),
        calc_epidur = numeric(), unbundled_hrgs = character(),
        quality = character(), spell = integer(), spell_report_flag = integer(),
        spell_hrg = character(), spell_grouping_method = character(),
        spell_dominant_procedure = character(), spell_pdiag = character(),
        spell_sdiag = character(), spell_episode_count = integer(),
        spell_los = numeric(), spell_pbc = character(),
        spell_unbundled_hrgs = character(), spell_quality = character()
      )
    )
    empty_sp <- tibble::tibble(
      spell = integer(), procodet = character(), provspno = character(),
      visit_occurrence_id = inp$meta$visit_occurrence_id[0],
      person_id = inp$meta$person_id[0],
      spell_hrg = character(), spell_grouping_method = character(),
      spell_dominant_procedure = character(), spell_pdiag = character(),
      spell_sdiag = character(), spell_episode_count = integer(),
      spell_los = numeric(), spell_pbc = character(),
      spell_unbundled_hrgs = character(), spell_quality = character()
    )
    out <- list(episodes = empty_ep, spells = empty_sp)
    attr(out, "quality") <- inp$quality
    return(out)
  }

  grouped <- hrg_group_apc(inp$episodes, tables = tbls)
  ep <- dplyr::bind_cols(
    inp$meta,
    dplyr::select(grouped$episodes, -"row")
  )
  spell_meta_cols <- intersect(
    c("cohort_definition_id", "cohort_name", "visit_occurrence_id", "person_id", "candidate_index"),
    names(inp$meta)
  )
  spell_meta <- inp$meta[grouped$spells$spell_report_row, spell_meta_cols, drop = FALSE]
  sp <- dplyr::bind_cols(
    grouped$spells |> dplyr::select("spell", "procodet", "provspno"),
    spell_meta,
    grouped$spells |> dplyr::select(-"spell", -"procodet", -"provspno", -"spell_report_row")
  )

  q <- inp$quality
  q$hrg_version <- tbls$version
  q$n_spells <- nrow(sp)
  q$n_grouped_episodes <- sum(ep$fce_hrg != "UZ01Z", na.rm = TRUE)
  q$pct_grouped_episodes <- 100 * q$n_grouped_episodes / nrow(ep)
  q$n_grouped_spells <- sum(sp$spell_hrg != "UZ01Z", na.rm = TRUE)
  q$pct_grouped_spells <- 100 * q$n_grouped_spells / nrow(sp)
  q$grouping_methods <- ep |> dplyr::count(.data$grouping_method, sort = TRUE)

  out <- list(episodes = ep, spells = sp)
  attr(out, "quality") <- q
  out
}

#' Inspect the CDM readiness and quality report of an OMOP HRG4+ run
#'
#' Extracts the `quality` metadata attached by [omop_to_hrg()] or [omop_hrg()],
#' summarising ICD-10 coding depth and 3-character `X`-padding, OPCS-4 vs
#' unmapped procedures, primary-diagnosis flag coverage, episode mode,
#' discharge/specialty resolution sources, and (after grouping) episode and
#' spell grouping rates.
#'
#' @param x An object returned by [omop_to_hrg()] or [omop_hrg()].
#' @return A list with class `omop_hrg_quality`.
#' @export
omop_hrg_quality <- function(x) {
  q <- if (inherits(x, "omop_hrg_input")) {
    x$quality
  } else {
    attr(x, "quality")
  }
  if (is.null(q)) {
    cli::cli_abort("{.arg x} does not carry an OMOP HRG4+ quality report.")
  }
  structure(q, class = c("omop_hrg_quality", "list"))
}

#' @export
print.omop_hrg_quality <- function(x, ...) {
  ver <- if (!is.null(x$hrg_version)) paste0(", HRG4+ ", x$hrg_version) else ""
  cat(sprintf("<opendrg OMOP HRG4+ quality report> CDM: %s (episodes = \"%s\", principal = \"%s\"%s)\n",
              x$cdm_name, x$episodes_mode, x$principal_strategy, ver))
  cat(sprintf(
    "Stays: %s (%s persons); Episodes: %s%s\n",
    format(x$n_stays, big.mark = ","),
    format(x$n_persons, big.mark = ","),
    format(x$n_episodes, big.mark = ","),
    if (!is.null(x$n_spells)) sprintf("; Spells: %s", format(x$n_spells, big.mark = ",")) else ""
  ))
  if (x$n_stays > 0L) {
    cat(sprintf(
      "Diagnoses (ICD-10): %.1f%% coded (median %.0f, mean %.1f; %s X-padded); %.1f%% OMOP primary flag; %.1f%% principal assigned\n",
      x$pct_episodes_with_dx, x$median_dx_per_episode, x$mean_dx_per_episode,
      format(x$n_dx_padded_x, big.mark = ",", trim = TRUE),
      x$pct_episodes_with_primary_status, x$pct_episodes_with_principal
    ))
    cat(sprintf(
      "Procedures (OPCS-4): %.1f%% with OPCS-4; %.1f%% with unmapped procedures\n",
      x$pct_episodes_with_pr, x$pct_episodes_with_unmapped_pr
    ))
    if (!is.null(x$n_grouped_episodes)) {
      cat(sprintf(
        "Grouped (non-UZ01Z): %s / %s episodes (%.1f%%); %s / %s spells (%.1f%%)\n",
        format(x$n_grouped_episodes, big.mark = ","), format(x$n_episodes, big.mark = ","), x$pct_grouped_episodes,
        format(x$n_grouped_spells, big.mark = ","), format(x$n_spells, big.mark = ","), x$pct_grouped_spells
      ))
    }
    if (nrow(x$dx_code_validity) > 0L) {
      parts <- sprintf("%s=%s", x$dx_code_validity$status, format(x$dx_code_validity$n_rows, big.mark = ",", trim = TRUE))
      cat("ICD-10 validity:", paste(parts, collapse = ", "), "\n")
    }
    if (nrow(x$discharge_sources) > 0L) {
      parts <- sprintf("%s=%s", x$discharge_sources$discharge_source, format(x$discharge_sources$n, big.mark = ",", trim = TRUE))
      cat("Discharge sources:", paste(parts, collapse = ", "), "\n")
    }
    if (nrow(x$specialty_sources) > 0L) {
      parts <- sprintf("%s=%s", x$specialty_sources$specialty_source, format(x$specialty_sources$n, big.mark = ",", trim = TRUE))
      cat("Specialty sources:", paste(parts, collapse = ", "), "\n")
    }
  }
  invisible(x)
}
