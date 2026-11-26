# Adapter and one-call grouper from an OMOP CDM (CDMConnector / omopgenerics
# `cdm_reference` or a CohortConstructor `cohort_table`) to CMS MS-DRGs.
# Queries stay lazy in the database through dplyr/dbplyr; only the scoped
# stays, their diagnoses, procedures and deaths are collected into R, with no
# write permissions required on the CDM.

omop_nlp_type_concept_id <- 32858L

# Standard OMOP discharged_to_concept_id -> UB-04 two-character discharge status.
# Concepts from the "UB04 Pt dis status" vocabulary also map directly via their
# concept_code.
omop_discharge_concept_map <- c(
  "4216643"  = "20", # SNOMED: Patient died
  "32218"    = "20", # UB04: Expired
  "32221"    = "40", # UB04: Expired at home
  "4021968"  = "07", # SNOMED: Patient self-discharge against medical advice
  "44814692" = "07", # PCORNet: Against medical advice
  "9201"     = "02", # Visit: Inpatient Visit (transfer to acute hospital)
  "8717"     = "02", # CMS Place of Service: Inpatient Hospital
  "32211"    = "02", # UB04: Transferred to other short-term general hospital
  "38004279" = "02", # NUCC: General Acute Care Hospital
  "8863"     = "03", # CMS Place of Service: Skilled Nursing Facility
  "8676"     = "04", # CMS Place of Service: Nursing Facility
  "38004519" = "06", # Medicare Specialty: Home Health Agency
  "8546"     = "50", # CMS Place of Service: Hospice
  "8920"     = "62", # CMS Place of Service: Comprehensive Inpatient Rehab
  "38004285" = "62", # NUCC: Rehabilitation Hospital
  "38004277" = "63", # NUCC: Long Term Care Hospital
  "8970"     = "63", # CMS Place of Service: Inpatient Long-term Care
  "8971"     = "65", # CMS Place of Service: Inpatient Psychiatric Facility
  "38004284" = "65", # NUCC: Psychiatric Hospital
  "32220"    = "30", # UB04: Still patient
  "44814702" = "30", # PCORNet: Still in hospital
  "8536"     = "01", # CMS Place of Service: Home
  "581476"   = "01", # Visit: Home Visit
  "32210"    = "01"  # UB04: Discharged to home / self care
)

omop_is_cohort_table <- function(x) {
  inherits(x, "cohort_table") || inherits(x, "GeneratedCohortSet")
}

# Convert OMOP IDs (including bit64::integer64) to exact character keys without
# scientific notation or floating-point precision loss.
omop_id_chr <- function(x) {
  if (inherits(x, "integer64")) {
    as.character(x)
  } else if (is.numeric(x)) {
    format(x, scientific = FALSE, trim = TRUE)
  } else {
    as.character(x)
  }
}

# Proper prefixes (lengths 3..6) of valid billable ICD-10-CM codes that are not
# themselves billable; used to separate category-level header codes (e.g. N18)
# from genuinely unrecognised codes.
omop_dx_header_prefixes <- function(valid_codes) {
  lens <- nchar(valid_codes)
  out <- character()
  for (k in 3:6) {
    sub <- valid_codes[lens > k]
    if (length(sub) > 0L) out <- c(out, unique(substr(sub, 1L, k)))
  }
  setdiff(unique(out), valid_codes)
}

omop_filter_in <- function(tbl, col, values) {
  if (length(values) == 1L) {
    val <- values[[1]]
    dplyr::filter(tbl, .data[[col]] == !!val)
  } else {
    dplyr::filter(tbl, .data[[col]] %in% !!values)
  }
}

omop_parse_bound_date <- function(x, arg) {
  if (is.null(x)) return(NULL)
  d <- if (inherits(x, "Date")) x else suppressWarnings(as.Date(x))
  if (length(d) != 1L || is.na(d)) {
    cli::cli_abort("{.arg {arg}} must be a single valid Date or {.val YYYY-MM-DD} string.")
  }
  d
}

omop_validate_cdm <- function(cdm) {
  if (!is.list(cdm)) {
    cli::cli_abort("{.arg cdm} must be a {.cls cdm_reference} (from {.pkg CDMConnector}), a {.cls cohort_table} (from {.pkg CohortConstructor}), or a named list of OMOP tables.")
  }
  required <- c("person", "visit_occurrence", "condition_occurrence", "concept")
  missing <- setdiff(required, names(cdm))
  if (length(missing) > 0L) {
    cli::cli_abort("{.arg cdm} is missing required OMOP table{?s}: {.field {missing}}.")
  }
  invisible(cdm)
}

omop_is_remote <- function(tbl) {
  inherits(tbl, "tbl_sql") || inherits(tbl, "tbl_lazy")
}

omop_same_backend <- function(x, y) {
  rx <- omop_is_remote(x)
  ry <- omop_is_remote(y)
  if (rx != ry) return(FALSE)
  if (!rx) return(TRUE)
  if (requireNamespace("dbplyr", quietly = TRUE)) {
    identical(dbplyr::remote_con(x), dbplyr::remote_con(y))
  } else {
    TRUE
  }
}

omop_compute_age <- function(visit_start_date, birth_datetime, year_of_birth, month_of_birth, day_of_birth) {
  visit_date <- as.Date(visit_start_date)
  birth_date <- rep(as.Date(NA), length(visit_date))
  if (!is.null(birth_datetime)) {
    bd <- as.Date(birth_datetime)
    birth_date[!is.na(bd)] <- bd[!is.na(bd)]
  }
  need_ymd <- is.na(birth_date) & !is.na(year_of_birth) &
    !is.null(month_of_birth) & !is.null(day_of_birth) &
    !is.na(month_of_birth) & !is.na(day_of_birth)
  if (any(need_ymd)) {
    ymd <- suppressWarnings(as.Date(sprintf(
      "%04d-%02d-%02d",
      as.integer(year_of_birth[need_ymd]),
      as.integer(month_of_birth[need_ymd]),
      as.integer(day_of_birth[need_ymd])
    )))
    birth_date[need_ymd] <- ymd
  }
  age <- cmbd_age_years(birth_date, visit_date)
  fallback <- is.na(age) & !is.na(visit_date) & !is.na(year_of_birth)
  if (any(fallback)) {
    age[fallback] <- as.integer(format(visit_date[fallback], "%Y")) - as.integer(year_of_birth[fallback])
  }
  age
}

omop_resolve_discharge <- function(died, disc_source_val, disc_concept_id,
                                   disc_vocab, disc_code,
                                   discharge_map, default_discharge) {
  n <- length(died)
  status <- rep(NA_character_, n)
  source <- rep("missing", n)

  # 1. In-stay mortality from the OMOP death table always takes precedence.
  is_dead <- !is.na(died) & died
  status[is_dead] <- "20"
  source[is_dead] <- "death"

  # 2. User-supplied per-site source-value map.
  if (!is.null(discharge_map) && length(discharge_map) > 0L) {
    if (is.null(names(discharge_map)) || any(names(discharge_map) == "")) {
      cli::cli_abort("{.arg discharge_map} must be a named character vector mapping {.field discharged_to_source_value} to UB-04 codes.")
    }
    key <- trimws(as.character(disc_source_val))
    mapped <- unname(discharge_map[key])
    mapped <- msdrg_normalize_discharge_status(mapped)
    hit <- is.na(status) & !is.na(mapped)
    status[hit] <- mapped[hit]
    source[hit] <- "source_map"
  }

  # 3. Standard OMOP discharged_to_concept_id (direct UB04 vocabulary or lookup).
  if (!is.null(disc_concept_id)) {
    cid_chr <- omop_id_chr(disc_concept_id)
    ub04_direct <- rep(NA_character_, n)
    if (!is.null(disc_vocab) && !is.null(disc_code)) {
      is_ub04 <- !is.na(disc_vocab) & disc_vocab == "UB04 Pt dis status"
      if (any(is_ub04)) {
        norm <- msdrg_normalize_discharge_status(disc_code[is_ub04])
        norm_int <- suppressWarnings(as.integer(norm))
        valid <- !is.na(norm_int) & norm_int %in% msdrg_valid_discharge_status
        ub04_direct[is_ub04][valid] <- norm[valid]
      }
    }
    mapped_cid <- dplyr::coalesce(ub04_direct, unname(omop_discharge_concept_map[cid_chr]))
    hit <- is.na(status) & !is.na(mapped_cid)
    status[hit] <- mapped_cid[hit]
    source[hit] <- "concept"
  }

  # 4. Fallback default discharge status (e.g. "01" routine home).
  if (!is.null(default_discharge) && !is.na(default_discharge)) {
    def <- msdrg_normalize_discharge_status(default_discharge)[[1]]
    miss <- is.na(status)
    status[miss] <- def
    source[miss] <- "default"
  }

  list(discharge_status = status, discharge_source = source)
}

# Parse `principal_codes`: accepts character ICD-10-CM codes/prefixes, numeric
# OMOP concept_ids, CodelistGenerator/omopgenerics codelist objects (named lists
# of integer concept_ids), or data frames with a `concept_id` column.
omop_parse_principal_codes <- function(x) {
  if (is.null(x)) return(list(type = "empty", values = character()))
  if (is.data.frame(x)) {
    if (!"concept_id" %in% names(x)) {
      cli::cli_abort("Data frame supplied to {.arg principal_codes} must contain a {.field concept_id} column.")
    }
    vals <- unique(as.integer(stats::na.omit(x$concept_id)))
    return(list(type = "concept_id", values = vals))
  }
  if (is.list(x)) {
    flat <- unlist(x, use.names = FALSE)
    if (length(flat) == 0L) return(list(type = "empty", values = character()))
    if (is.numeric(flat)) {
      return(list(type = "concept_id", values = unique(as.integer(stats::na.omit(flat)))))
    }
    return(list(type = "code", values = unique(stats::na.omit(msdrg_normalize_code(flat)))))
  }
  if (is.numeric(x)) {
    return(list(type = "concept_id", values = unique(as.integer(stats::na.omit(x)))))
  }
  list(type = "code", values = unique(stats::na.omit(msdrg_normalize_code(x))))
}

omop_match_codelist <- function(codes, patterns) {
  # Returns integer rank (index into `patterns`, Inf if no match) and logical
  # exact_match for each code.
  n <- length(codes)
  rank <- rep(Inf, n)
  exact <- rep(FALSE, n)
  for (i in seq_along(patterns)) {
    p <- patterns[[i]]
    is_ex <- codes == p
    is_hit <- is_ex | startsWith(codes, p)
    better <- is_hit & rank == Inf
    rank[better] <- i
    exact[better] <- is_ex[better]
  }
  list(rank = rank, exact = exact)
}

# Resolve a cohort argument (table name in cdm, CohortConstructor cohort_table,
# or plain data frame / tbl) and extract its cohort_set and cohort_codelist
# attributes when present, applying any `cohort_id` filter.
omop_resolve_cohort <- function(cdm, cohort, cohort_id) {
  if (is.null(cohort)) {
    if (!is.null(cohort_id)) {
      cli::cli_abort("{.arg cohort_id} requires {.arg cohort} (or passing a {.cls cohort_table} directly as {.arg cdm}).")
    }
    return(list(tbl = NULL, cohort_set = NULL, cohort_codelist = NULL))
  }
  if (is.character(cohort)) {
    if (length(cohort) != 1L || !cohort %in% names(cdm)) {
      cli::cli_abort("Cohort table {.val {cohort}} was not found in {.arg cdm}.")
    }
    cohort <- cdm[[cohort]]
  }
  if (!inherits(cohort, "tbl") && !is.data.frame(cohort)) {
    cli::cli_abort("{.arg cohort} must be a cohort table name in {.arg cdm}, a {.cls cohort_table}, or a data frame / lazy table.")
  }

  cset_attr <- attr(cohort, "cohort_set")
  cohort_set <- if (!is.null(cset_attr)) dplyr::collect(cset_attr) else NULL
  ccode_attr <- attr(cohort, "cohort_codelist")
  cohort_codelist <- if (!is.null(ccode_attr)) dplyr::collect(ccode_attr) else NULL

  if (!is.null(cohort_id)) {
    if (!"cohort_definition_id" %in% colnames(cohort)) {
      cli::cli_abort("{.arg cohort_id} was supplied, but {.arg cohort} has no {.field cohort_definition_id} column.")
    }
    if (is.character(cohort_id)) {
      if (is.null(cohort_set) || !"cohort_name" %in% names(cohort_set)) {
        cli::cli_abort("Character {.arg cohort_id} requires a {.cls cohort_table} with {.field cohort_set} metadata (e.g. from {.pkg CohortConstructor}).")
      }
      missing_names <- setdiff(cohort_id, cohort_set$cohort_name)
      if (length(missing_names) > 0L) {
        cli::cli_abort("Cohort name{?s} not found in {.field cohort_set}: {.val {missing_names}}.")
      }
      target_ids <- as.integer(cohort_set$cohort_definition_id[match(cohort_id, cohort_set$cohort_name)])
    } else {
      target_ids <- unique(as.integer(stats::na.omit(cohort_id)))
      if (length(target_ids) == 0L) {
        cli::cli_abort("{.arg cohort_id} must contain at least one valid cohort definition ID or cohort name.")
      }
      if (!is.null(cohort_set) && "cohort_definition_id" %in% names(cohort_set)) {
        missing_ids <- setdiff(target_ids, as.integer(cohort_set$cohort_definition_id))
        if (length(missing_ids) > 0L) {
          cli::cli_abort("Cohort definition ID{?s} not found in {.field cohort_set}: {.val {missing_ids}}.")
        }
      }
    }
    cohort <- omop_filter_in(cohort, "cohort_definition_id", target_ids)
    if (!is.null(cohort_set)) {
      cohort_set <- cohort_set |> dplyr::filter(as.integer(.data$cohort_definition_id) %in% target_ids)
    }
    if (!is.null(cohort_codelist)) {
      cohort_codelist <- cohort_codelist |> dplyr::filter(as.integer(.data$cohort_definition_id) %in% target_ids)
    }
  }

  list(tbl = cohort, cohort_set = cohort_set, cohort_codelist = cohort_codelist)
}

# Build the lazy stays query and optional in-memory cohort filter.
omop_build_stays_query <- function(cdm, visit_concept_ids, cohort_tbl, cohort_match,
                                   person_ids, visit_ids, start_date, end_date, n_max) {
  vo <- cdm$visit_occurrence
  vo_cols <- colnames(vo)
  disc_cid_col <- if ("discharged_to_concept_id" %in% vo_cols) {
    "discharged_to_concept_id"
  } else if ("discharge_to_concept_id" %in% vo_cols) {
    "discharge_to_concept_id"
  } else {
    NULL
  }
  disc_val_col <- if ("discharged_to_source_value" %in% vo_cols) {
    "discharged_to_source_value"
  } else if ("discharge_to_source_value" %in% vo_cols) {
    "discharge_to_source_value"
  } else {
    NULL
  }

  q <- vo
  if (!is.null(visit_concept_ids)) {
    q <- omop_filter_in(q, "visit_concept_id", as.integer(visit_concept_ids))
  }
  if (!is.null(visit_ids)) {
    if (length(visit_ids) == 0L) {
      q <- dplyr::filter(q, 1L == 0L)
    } else {
      q <- omop_filter_in(q, "visit_occurrence_id", visit_ids)
    }
  }
  if (!is.null(person_ids)) {
    if (length(person_ids) == 0L) {
      q <- dplyr::filter(q, 1L == 0L)
    } else {
      q <- omop_filter_in(q, "person_id", person_ids)
    }
  }
  if (!is.null(start_date)) {
    q <- dplyr::filter(q, .data$visit_start_date >= !!start_date)
  }
  if (!is.null(end_date)) {
    q <- dplyr::filter(q, .data$visit_start_date <= !!end_date)
  }

  has_cid <- FALSE
  local_cohort <- NULL
  if (!is.null(cohort_tbl)) {
    c_cols <- colnames(cohort_tbl)
    has_vid <- "visit_occurrence_id" %in% c_cols
    has_cid <- "cohort_definition_id" %in% c_cols
    id_col <- if (has_vid) {
      "visit_occurrence_id"
    } else if ("subject_id" %in% c_cols) {
      "subject_id"
    } else if ("person_id" %in% c_cols) {
      "person_id"
    } else {
      cli::cli_abort("{.arg cohort} must contain {.field subject_id}, {.field person_id} or {.field visit_occurrence_id}.")
    }
    has_start <- "cohort_start_date" %in% c_cols
    has_end <- "cohort_end_date" %in% c_cols

    if (omop_same_backend(q, cohort_tbl)) {
      if (has_vid) {
        if (has_cid) {
          c_sub <- dplyr::distinct(dplyr::select(cohort_tbl, "cohort_definition_id", "visit_occurrence_id"))
          q <- dplyr::inner_join(q, c_sub, by = "visit_occurrence_id")
        } else {
          q <- dplyr::semi_join(q, dplyr::select(cohort_tbl, "visit_occurrence_id"), by = "visit_occurrence_id")
        }
      } else if (cohort_match == "subject" || !has_start) {
        if (has_cid) {
          c_ids <- dplyr::distinct(dplyr::select(cohort_tbl, "cohort_definition_id", person_id = dplyr::all_of(id_col)))
          q <- dplyr::inner_join(q, c_ids, by = "person_id")
        } else {
          c_ids <- dplyr::distinct(dplyr::select(cohort_tbl, person_id = dplyr::all_of(id_col)))
          q <- dplyr::semi_join(q, c_ids, by = "person_id")
        }
      } else {
        c_win <- cohort_tbl |>
          dplyr::select(
            dplyr::any_of("cohort_definition_id"),
            person_id = dplyr::all_of(id_col),
            cohort_start_date = "cohort_start_date",
            dplyr::any_of("cohort_end_date")
          )
        q <- dplyr::inner_join(q, c_win, by = "person_id")
        if (cohort_match == "index") {
          if ("visit_end_date" %in% vo_cols) {
            q <- dplyr::filter(
              q,
              .data$visit_start_date <= .data$cohort_start_date,
              dplyr::coalesce(.data$visit_end_date, .data$visit_start_date) >= .data$cohort_start_date
            )
          } else {
            q <- dplyr::filter(q, .data$visit_start_date == .data$cohort_start_date)
          }
        } else if (has_end && "visit_end_date" %in% vo_cols) {
          q <- dplyr::filter(
            q,
            .data$visit_start_date <= .data$cohort_end_date,
            dplyr::coalesce(.data$visit_end_date, .data$visit_start_date) >= .data$cohort_start_date
          )
        } else if (has_end) {
          q <- dplyr::filter(
            q,
            .data$visit_start_date >= .data$cohort_start_date,
            .data$visit_start_date <= .data$cohort_end_date
          )
        } else {
          q <- dplyr::filter(q, .data$visit_start_date >= .data$cohort_start_date)
        }
        q <- dplyr::select(q, -dplyr::any_of(c("cohort_start_date", "cohort_end_date")))
        if (has_cid) {
          q <- dplyr::distinct(q, .data$cohort_definition_id, .data$visit_occurrence_id, .keep_all = TRUE)
        } else {
          q <- dplyr::distinct(q, .data$visit_occurrence_id, .keep_all = TRUE)
        }
      }
    } else {
      # In-memory cohort (or cohort on a different connection) against a remote
      # database: push only unique IDs into SQL (no write permissions needed)
      # and apply cohort_definition_id & date windows after collect().
      c_df <- dplyr::collect(cohort_tbl)
      ids <- unique(c_df[[id_col]])
      if (length(ids) == 0L) {
        q <- dplyr::filter(q, 1L == 0L)
      } else if (has_vid) {
        q <- omop_filter_in(q, "visit_occurrence_id", ids)
      } else {
        q <- omop_filter_in(q, "person_id", ids)
      }
      if (has_cid || (!has_vid && has_start && cohort_match != "subject")) {
        local_cohort <- tibble::tibble(
          .join_key = omop_id_chr(c_df[[id_col]]),
          .by_vid = has_vid,
          cohort_definition_id = if (has_cid) as.integer(c_df$cohort_definition_id) else NA_integer_,
          cohort_start_date = if (has_start) as.Date(c_df$cohort_start_date) else as.Date(NA),
          cohort_end_date = if (has_end) as.Date(c_df$cohort_end_date) else as.Date(NA)
        )
      }
    }
  }

  keep <- c("visit_occurrence_id", "person_id", "visit_start_date")
  if (has_cid && is.null(local_cohort)) keep <- c("cohort_definition_id", keep)
  if ("visit_end_date" %in% vo_cols) keep <- c(keep, "visit_end_date")
  if (!is.null(disc_cid_col)) keep <- c(keep, disc_cid_col)
  if (!is.null(disc_val_col)) keep <- c(keep, disc_val_col)
  q <- dplyr::select(q, dplyr::all_of(keep))
  if (!is.null(disc_cid_col) && disc_cid_col != "discharged_to_concept_id") {
    q <- dplyr::rename(q, discharged_to_concept_id = dplyr::all_of(disc_cid_col))
  }
  if (!is.null(disc_val_col) && disc_val_col != "discharged_to_source_value") {
    q <- dplyr::rename(q, discharged_to_source_value = dplyr::all_of(disc_val_col))
  }

  if (!is.null(n_max)) {
    n_max <- as.integer(n_max)
    if (is.na(n_max) || n_max < 1L) cli::cli_abort("{.arg n_max} must be a positive integer.")
    if (is.null(local_cohort)) {
      if (has_cid) {
        top_vids <- q |>
          dplyr::distinct(.data$visit_occurrence_id) |>
          dplyr::slice_min(.data$visit_occurrence_id, n = n_max, with_ties = FALSE)
        q <- dplyr::semi_join(q, top_vids, by = "visit_occurrence_id")
      } else {
        q <- dplyr::slice_min(q, .data$visit_occurrence_id, n = n_max, with_ties = FALSE)
      }
    }
  }

  list(
    stays_q = q,
    has_visit_end = "visit_end_date" %in% vo_cols,
    has_disc_cid = !is.null(disc_cid_col),
    has_disc_val = !is.null(disc_val_col),
    has_cohort_id = has_cid,
    local_cohort = local_cohort,
    post_n_max = if (!is.null(local_cohort)) n_max else NULL
  )
}

#' Convert an OMOP CDM reference or `CohortConstructor` cohort to MS-DRG inputs
#'
#' Extracts inpatient stays, demographics, diagnoses, procedures and discharge
#' disposition from a `CDMConnector` / `omopgenerics` `cdm_reference` object
#' — or directly from a `CohortConstructor` `cohort_table` (which carries its
#' parent `cdm_reference`, `cohort_set`, and `cohort_codelist` attributes) —
#' using lazy `dplyr`/`dbplyr` queries inside the database (read-only; no write
#' schema is needed) and returns the three long tables expected by
#' [msdrg_group()] and [group()], together with a structured readiness and
#' data-quality report.
#'
#' Because real-world OMOP CDMs vary in how faithfully they preserve billing
#' fields, every mapping assumption is explicit and recorded in `quality`:
#'
#' * **Diagnoses** are read from `condition_source_concept_id` in the
#'   `ICD10CM` vocabulary (configurable via `dx_vocabulary`). Free-text NLP
#'   extractions (`condition_type_concept_id == 32858`) are excluded by default
#'   (`exclude_nlp = TRUE`). Set `snomed_fallback = TRUE` to reverse-map
#'   standard SNOMED concepts via `concept_relationship` (`"Maps to"`) for
#'   stays that carry no source ICD-10-CM concepts.
#' * **Principal diagnosis** is chosen according to `principal` — never by a
#'   silent heuristic:
#'   - `"status"` (default): uses OMOP primary-diagnosis flags
#'     (`condition_status_concept_id` in `primary_status_concept_ids`, default
#'     32902/32903/32901, or legacy primary `condition_type_concept_id`). Stays
#'     without a primary flag receive no `seq = 1` row and will be marked
#'     ungroupable (return code 7, DRG 999).
#'   - `"codelist"`: uses `principal_codes` — either ICD-10-CM codes/prefixes
#'     (e.g. `c("C61", "N40", "N17")`), OMOP `concept_id`s, or a
#'     `CodelistGenerator` / `omopgenerics` codelist object — choosing the
#'     highest-priority matching code on each stay (preferring valid billable
#'     codes over category headers) as `seq = 1`.
#'   - `"cohort_codelist"`: uses the `cohort_codelist` attribute attached to a
#'     `CohortConstructor` cohort (e.g. from `CohortConstructor::conceptCohort()`)
#'     to automatically select each cohort's defining index condition as the
#'     principal diagnosis for every `(cohort_definition_id, visit_occurrence_id)`.
#'   - `"all"`: sensitivity / multi-candidate mode. Generates one candidate
#'     claim per distinct coded diagnosis on each stay (`claim_id =
#'     "<visit_occurrence_id>#<k>"`), taking every coded diagnosis in turn as
#'     principal so the spread of DRGs can be quantified.
#'   - `"first"`: explicit opt-in heuristic picking the first valid billable
#'     diagnosis on the stay (by date, occurrence ID and code).
#' * **Cohorts (`CohortConstructor`)**: Pass a `CohortConstructor` `cohort_table`
#'   directly as the first argument (`omop_to_msdrg(cdm$my_cohort, ...)`), or
#'   pass `cohort = "my_cohort"` / `cohort = cdm$my_cohort`. Multi-cohort tables
#'   are supported natively: `cohort_id` filters by numeric
#'   `cohort_definition_id` or character `cohort_name`, `cohort_match` controls
#'   whether inpatient stays must `"overlap"` `[cohort_start_date,
#'   cohort_end_date]`, contain the `"index"` date (`cohort_start_date`), or
#'   match by `"subject"`, and `cohort_definition_id` / `cohort_name` are
#'   carried through onto `claims` (preserving distinct
#'   `(cohort_definition_id, visit_occurrence_id)` pairs when a stay belongs to
#'   more than one cohort).
#' * **Procedures** are read from `procedure_concept_id` and
#'   `procedure_source_concept_id` in the `ICD10PCS` vocabulary. Stays with
#'   unmapped or non-PCS procedures are flagged (`has_unmapped_pr`) and
#'   summarised in `quality`.
#' * **Discharge status** is resolved in order: (1) in-stay mortality from the
#'   `death` table (`"20"`), (2) a site-specific `discharge_map` applied to
#'   `discharged_to_source_value`, (3) standard OMOP `discharged_to_concept_id`
#'   (supporting both CDM v5.4 `discharged_to_*` and v5.3 `discharge_to_*`
#'   column names, as well as `UB04 Pt dis status` concepts directly), and
#'   (4) `default_discharge` (default `"01"`, routine discharge home).
#'
#' @param cdm A `cdm_reference` object created by `CDMConnector::cdmFromCon()`
#'   or `omopgenerics::cdmFromTables()`, a `CohortConstructor` / `omopgenerics`
#'   `cohort_table` (whose attached `cdm_reference` is extracted automatically),
#'   or a named list of OMOP tables (`person`, `visit_occurrence`,
#'   `condition_occurrence`, `concept`, and optionally `procedure_occurrence`,
#'   `death`, `concept_relationship`).
#' @param visit_concept_ids Integer vector of `visit_concept_id` values
#'   defining inpatient stays. Defaults to `c(9201L, 262L)` (Inpatient Visit
#'   and ER and Inpatient Visit). Pass `NULL` to keep all visits.
#' @param cohort Optional cohort filter: either the name of a cohort table in
#'   `cdm`, a `CohortConstructor` `cohort_table`, or a data frame / lazy table
#'   with `subject_id` (or `person_id`, or `visit_occurrence_id`) and
#'   optionally `cohort_definition_id`, `cohort_start_date` and
#'   `cohort_end_date`. Omit when passing a `cohort_table` directly as `cdm`.
#' @param cohort_id Optional subset of cohorts to include when `cohort` (or a
#'   `cohort_table` passed as `cdm`) contains multiple `cohort_definition_id`s.
#'   Accepts integer `cohort_definition_id`s or character `cohort_name`s
#'   (resolved against `cohort_set`).
#' @param cohort_match How cohort entries are matched to inpatient stays when
#'   `cohort_start_date` is present: `"overlap"` (default, visit overlaps
#'   `[cohort_start_date, cohort_end_date]`), `"index"` (visit contains
#'   `cohort_start_date`), or `"subject"` (all inpatient stays for subjects in
#'   the cohort).
#' @param person_ids Optional vector of `person_id` values to restrict to.
#' @param visit_ids Optional vector of `visit_occurrence_id` values to restrict
#'   to.
#' @param start_date,end_date Optional inclusive date bounds (`Date` or
#'   `"YYYY-MM-DD"`) on `visit_start_date`.
#' @param n_max Optional positive integer limiting the number of distinct
#'   inpatient stays extracted (ordered deterministically by
#'   `visit_occurrence_id`).
#' @param principal Principal-diagnosis selection strategy: `"status"`
#'   (default), `"codelist"`, `"cohort_codelist"`, `"all"`, or `"first"`. See
#'   Details.
#' @param principal_codes Used when `principal = "codelist"`: a character
#'   vector of ICD-10-CM codes or prefixes (dots optional), an integer vector
#'   of OMOP `concept_id`s, a `CodelistGenerator` / `omopgenerics` codelist
#'   (named list of concept IDs), or a data frame with a `concept_id` column.
#' @param unmatched When `principal` is `"codelist"`, `"cohort_codelist"`, or
#'   `"status"`, whether to `"keep"` (default) stays without a principal
#'   diagnosis (they receive no `seq = 1` row and group to RC 7 / DRG 999) or
#'   `"drop"` them.
#' @param primary_status_concept_ids Integer vector of
#'   `condition_status_concept_id` values denoting a primary diagnosis.
#'   Defaults to `c(32902L, 32903L, 32901L)` (Primary diagnosis, Primary
#'   discharge diagnosis, Primary admission diagnosis).
#' @param primary_type_concept_ids Integer vector of legacy
#'   `condition_type_concept_id` values denoting a primary diagnosis.
#' @param condition_type_concept_ids Optional integer vector restricting
#'   `condition_type_concept_id` (for example `32817L` for EHR records only).
#' @param exclude_nlp Logical; when `condition_type_concept_id` is `NULL`,
#'   exclude NLP-derived conditions (`condition_type_concept_id == 32858L`).
#'   Defaults to `TRUE`.
#' @param dx_vocabulary Vocabulary ID for diagnoses in `concept` (default
#'   `"ICD10CM"`).
#' @param pr_vocabulary Vocabulary ID for procedures in `concept` (default
#'   `"ICD10PCS"`).
#' @param snomed_fallback Logical; if `TRUE` and `concept_relationship` is
#'   present in `cdm`, reverse-map standard `condition_concept_id` values via
#'   `"Maps to"` to `dx_vocabulary` for stays that have no source-concept
#'   diagnoses. Defaults to `FALSE` (reverse mapping is lossy).
#' @param link_by How clinical events are linked to visits: `"visit_id"`
#'   (default, join on `visit_occurrence_id`) or `"date_overlap"` (join on
#'   `person_id` with event date within `[visit_start_date, visit_end_date]`).
#' @param discharge_map Optional named character vector mapping raw
#'   `discharged_to_source_value` strings to two-character UB-04 discharge
#'   status codes (e.g. `c("1" = "01", "2" = "02", "3" = "07", "5" = "20")`).
#' @param default_discharge Fallback UB-04 discharge status when neither the
#'   `death` table, `discharge_map` nor `discharged_to_concept_id` resolves a
#'   status. Defaults to `"01"` (routine discharge home); pass `NA_character_`
#'   to leave unresolved statuses missing.
#' @param tables MS-DRG logic tables from [msdrg_tables()], used to classify
#'   extracted ICD-10-CM codes into billable codes, category-level headers and
#'   unrecognised codes.
#' @return An object of class `omop_msdrg_input` (a list with elements
#'   `claims`, `diagnoses`, `procedures` and `quality`), ready to pass directly
#'   to [msdrg_group()] or [group()].
#' @export
#' @examples
#' cdm <- list(
#'   person = tibble::tibble(
#'     person_id = 1L, gender_concept_id = 8507L,
#'     year_of_birth = 1957L, month_of_birth = 3L, day_of_birth = 15L
#'   ),
#'   visit_occurrence = tibble::tibble(
#'     visit_occurrence_id = 101L, person_id = 1L, visit_concept_id = 9201L,
#'     visit_start_date = as.Date("2024-05-02"), visit_end_date = as.Date("2024-05-06"),
#'     discharged_to_concept_id = 8536L, discharged_to_source_value = "1"
#'   ),
#'   condition_occurrence = tibble::tibble(
#'     condition_occurrence_id = 1:3, person_id = 1L, visit_occurrence_id = 101L,
#'     condition_concept_id = c(312327L, 201826L, 197320L),
#'     condition_source_concept_id = c(1001L, 1002L, 1003L),
#'     condition_status_concept_id = c(32902L, 32908L, 32908L),
#'     condition_type_concept_id = 32817L,
#'     condition_start_date = as.Date("2024-05-02")
#'   ),
#'   procedure_occurrence = tibble::tibble(
#'     procedure_occurrence_id = 1L, person_id = 1L, visit_occurrence_id = 101L,
#'     procedure_concept_id = 2001L, procedure_source_concept_id = 0L,
#'     procedure_date = as.Date("2024-05-02")
#'   ),
#'   concept = tibble::tibble(
#'     concept_id = c(1001L, 1002L, 1003L, 2001L),
#'     vocabulary_id = c("ICD10CM", "ICD10CM", "ICD10CM", "ICD10PCS"),
#'     concept_code = c("I21.4", "E11.9", "N17.9", "02703ZZ")
#'   )
#' )
#' inp <- omop_to_msdrg(cdm)
#' inp
#' out <- group(grouper("msdrg", version = "44.0"), inp, poa_exempt = "exempt")
#' out[c("claim_id", "drg", "severity")]
omop_to_msdrg <- function(
    cdm,
    visit_concept_ids = c(9201L, 262L),
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
    dx_vocabulary = "ICD10CM",
    pr_vocabulary = "ICD10PCS",
    snomed_fallback = FALSE,
    link_by = c("visit_id", "date_overlap"),
    discharge_map = NULL,
    default_discharge = "01",
    tables = msdrg_tables()) {
  # Support passing a CohortConstructor / omopgenerics cohort_table directly as
  # the first argument (extracting its attached cdm_reference).
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
  cohort_match <- rlang::arg_match(cohort_match)
  principal <- rlang::arg_match(principal)
  unmatched <- rlang::arg_match(unmatched)
  link_by <- rlang::arg_match(link_by)
  tbls <- msdrg_tables(tables)
  start_date <- omop_parse_bound_date(start_date, "start_date")
  end_date <- omop_parse_bound_date(end_date, "end_date")

  coh <- omop_resolve_cohort(cdm, cohort, cohort_id)
  parsed_codes <- NULL
  if (principal == "codelist") {
    parsed_codes <- omop_parse_principal_codes(principal_codes)
    if (length(parsed_codes$values) == 0L) {
      cli::cli_abort("{.arg principal_codes} must be a non-empty vector of ICD-10-CM codes/prefixes or OMOP concept IDs when {.code principal = \"codelist\"}.")
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

  # --- 1. Collect scoped stays + person demographics + UB04 discharge concept
  p_cols <- colnames(cdm$person)
  p_keep <- intersect(
    c("person_id", "gender_concept_id", "year_of_birth", "month_of_birth", "day_of_birth", "birth_datetime"),
    p_cols
  )
  stays_full_q <- dplyr::left_join(stays_q, dplyr::select(cdm$person, dplyr::all_of(p_keep)), by = "person_id")
  if (built$has_disc_cid) {
    stays_full_q <- stays_full_q |>
      dplyr::left_join(
        cdm$concept |> dplyr::select("concept_id", disc_vocab = "vocabulary_id", disc_code = "concept_code"),
        by = c("discharged_to_concept_id" = "concept_id")
      )
  }
  stays <- dplyr::collect(stays_full_q)
  stays$.visit_key <- omop_id_chr(stays$visit_occurrence_id)
  stays$.person_key <- omop_id_chr(stays$person_id)
  stays$visit_start_date <- as.Date(stays$visit_start_date)
  stays$visit_end_date <- if (built$has_visit_end) as.Date(stays$visit_end_date) else as.Date(NA)

  # Apply in-memory cohort matching (dates & cohort_definition_id) if needed.
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

  # Handle empty stay set cleanly.
  if (nrow(stays) == 0L) {
    empty_claims <- tibble::tibble(claim_id = character())
    if (has_cohort_id) empty_claims$cohort_definition_id <- integer()
    if (has_cohort_name) empty_claims$cohort_name <- character()
    empty_claims <- dplyr::bind_cols(
      empty_claims,
      tibble::tibble(
        visit_occurrence_id = stays$visit_occurrence_id[0],
        person_id = stays$person_id[0],
        visit_start_date = as.Date(character()),
        visit_end_date = as.Date(character()),
        los = integer(),
        age = integer(),
        sex = integer(),
        discharge_status = character(),
        discharge_source = character(),
        principal_code = character(),
        principal_source = character(),
        n_dx = integer(),
        n_pr = integer(),
        n_unmapped_pr = integer(),
        has_unmapped_pr = logical()
      )
    )
    if (principal == "all") empty_claims$candidate_index <- integer()
    empty_dx <- tibble::tibble(claim_id = character(), seq = integer(), code = character(), poa = character())
    empty_pr <- tibble::tibble(claim_id = character(), seq = integer(), code = character())
    quality <- list(
      cdm_name = cdm_name,
      principal_strategy = principal,
      n_stays = 0L, n_persons = 0L, n_claims = 0L,
      n_stays_with_dx = 0L, pct_stays_with_dx = NA_real_,
      median_dx_per_stay = NA_real_, mean_dx_per_stay = NA_real_,
      n_stays_with_primary_status = 0L, pct_stays_with_primary_status = NA_real_,
      n_stays_with_principal = 0L, pct_stays_with_principal = NA_real_,
      n_stays_with_pr = 0L, pct_stays_with_pr = NA_real_,
      n_stays_with_unmapped_pr = 0L, pct_stays_with_unmapped_pr = NA_real_,
      discharge_sources = tibble::tibble(discharge_source = character(), n = integer()),
      dx_code_validity = tibble::tibble(status = character(), n_rows = integer(), n_codes = integer()),
      top_category_headers = tibble::tibble(code = character(), n_stays = integer())
    )
    return(structure(
      list(claims = empty_claims, diagnoses = empty_dx, procedures = empty_pr, quality = quality),
      class = c("omop_msdrg_input", "list")
    ))
  }

  # Key each stay-in-cohort row uniquely; multi-cohort tables prefix claim_id
  # with "<cohort_definition_id>:" so shared inpatient stays across cohorts stay
  # distinct.
  multi_cohort <- has_cohort_id && dplyr::n_distinct(stays$cohort_definition_id) > 1L
  stays$.stay_key <- if (multi_cohort) {
    paste0(stays$cohort_definition_id, ":", stays$.visit_key)
  } else {
    stays$.visit_key
  }

  # --- 2. Collect deaths for scoped persons ----------------------------------
  died <- rep(FALSE, nrow(stays))
  if ("death" %in% names(cdm)) {
    deaths <- cdm$death |>
      dplyr::semi_join(stays_q, by = "person_id") |>
      dplyr::select("person_id", "death_date") |>
      dplyr::collect()
    if (nrow(deaths) > 0L) {
      deaths$.person_key <- omop_id_chr(deaths$person_id)
      deaths$death_date <- as.Date(deaths$death_date)
      dead_keys <- stays |>
        dplyr::distinct(.data$.visit_key, .data$.person_key, .data$visit_start_date, .data$visit_end_date) |>
        dplyr::inner_join(deaths |> dplyr::select(".person_key", "death_date"), by = ".person_key", relationship = "many-to-many") |>
        dplyr::filter(
          !is.na(.data$death_date),
          .data$death_date >= .data$visit_start_date,
          .data$death_date <= dplyr::coalesce(.data$visit_end_date, .data$visit_start_date)
        ) |>
        dplyr::pull(".visit_key") |>
        unique()
      died <- stays$.visit_key %in% dead_keys
    }
  }

  # --- 3. Collect diagnoses for scoped stays ---------------------------------
  co <- cdm$condition_occurrence
  co_cols <- colnames(co)
  if (link_by == "visit_id" && !"visit_occurrence_id" %in% co_cols) {
    cli::cli_abort("{.field visit_occurrence_id} is absent from {.field condition_occurrence}; use {.code link_by = \"date_overlap\"}.")
  }
  stays_vids_q <- dplyr::distinct(stays_q, .data$visit_occurrence_id, .keep_all = TRUE)
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
    c("visit_occurrence_id", "condition_occurrence_id", "condition_start_date",
      "condition_concept_id", "condition_source_concept_id",
      "condition_status_concept_id", "condition_type_concept_id"),
    colnames(co_scoped)
  )
  dx_raw <- if ("condition_source_concept_id" %in% co_cols) {
    co_scoped |>
      dplyr::inner_join(
        cdm$concept |>
          dplyr::filter(.data$vocabulary_id == !!dx_vocabulary) |>
          dplyr::select("concept_id", code = "concept_code"),
        by = c("condition_source_concept_id" = "concept_id")
      ) |>
      dplyr::select(dplyr::all_of(dx_keep), "code") |>
      dplyr::collect()
  } else {
    tibble::tibble(visit_occurrence_id = stays$visit_occurrence_id[0], code = character())
  }

  # Optional SNOMED -> ICD10CM reverse-mapping fallback for stays with no source
  # ICD-10-CM concepts.
  if (isTRUE(snomed_fallback) && "concept_relationship" %in% names(cdm)) {
    stays_with_src <- if (nrow(dx_raw) > 0L) unique(omop_id_chr(dx_raw$visit_occurrence_id)) else character()
    if (length(stays_with_src) < dplyr::n_distinct(stays$.visit_key)) {
      dx_snomed <- co_scoped |>
        dplyr::inner_join(
          cdm$concept_relationship |>
            dplyr::filter(.data$relationship_id == "Maps to", is.na(.data$invalid_reason)) |>
            dplyr::select("concept_id_1", "concept_id_2"),
          by = c("condition_concept_id" = "concept_id_2")
        ) |>
        dplyr::inner_join(
          cdm$concept |>
            dplyr::filter(.data$vocabulary_id == !!dx_vocabulary) |>
            dplyr::select("concept_id", code = "concept_code"),
          by = c("concept_id_1" = "concept_id")
        ) |>
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

  if (nrow(dx_raw) > 0L) {
    dx_raw$.visit_key <- omop_id_chr(dx_raw$visit_occurrence_id)
    dx_raw <- dx_raw |> dplyr::filter(.data$.visit_key %in% stays$.visit_key)
  } else {
    dx_raw$.visit_key <- character()
  }

  valid_dx_codes <- tbls$dx_codes$code
  header_prefixes <- omop_dx_header_prefixes(valid_dx_codes)

  if (nrow(dx_raw) > 0L) {
    dx_raw$code <- msdrg_normalize_code(dx_raw$code)
    dx_raw <- dx_raw |> dplyr::filter(!is.na(.data$code))
    is_prim_status <- if ("condition_status_concept_id" %in% names(dx_raw)) {
      !is.na(dx_raw$condition_status_concept_id) &
        as.integer(dx_raw$condition_status_concept_id) %in% as.integer(primary_status_concept_ids)
    } else {
      rep(FALSE, nrow(dx_raw))
    }
    is_prim_type <- if ("condition_type_concept_id" %in% names(dx_raw)) {
      !is.na(dx_raw$condition_type_concept_id) &
        as.integer(dx_raw$condition_type_concept_id) %in% as.integer(primary_type_concept_ids)
    } else {
      rep(FALSE, nrow(dx_raw))
    }
    dx_raw$is_primary <- is_prim_status | is_prim_type
    dx_raw$dx_date <- if ("condition_start_date" %in% names(dx_raw)) {
      as.Date(dx_raw$condition_start_date)
    } else {
      as.Date(NA)
    }
    dx_raw$dx_id_chr <- if ("condition_occurrence_id" %in% names(dx_raw)) {
      omop_id_chr(dx_raw$condition_occurrence_id)
    } else {
      as.character(seq_len(nrow(dx_raw)))
    }
    dx_raw$is_billable <- dx_raw$code %in% valid_dx_codes
    dx_raw$is_header <- !dx_raw$is_billable & dx_raw$code %in% header_prefixes
    dx_raw$.cond_cid <- if ("condition_concept_id" %in% names(dx_raw)) as.integer(dx_raw$condition_concept_id) else NA_integer_
    dx_raw$.src_cid <- if ("condition_source_concept_id" %in% names(dx_raw)) as.integer(dx_raw$condition_source_concept_id) else NA_integer_

    # Deduplicate (stay, code), retaining primary flag and earliest date/id.
    dx_dedup <- dx_raw |>
      dplyr::arrange(.data$.visit_key, .data$code, dplyr::desc(.data$is_primary), .data$dx_date, .data$dx_id_chr) |>
      dplyr::distinct(.data$.visit_key, .data$code, .keep_all = TRUE)
  } else {
    dx_dedup <- tibble::tibble(
      .visit_key = character(), code = character(), is_primary = logical(),
      dx_date = as.Date(character()), dx_id_chr = character(),
      is_billable = logical(), is_header = logical()
    )
  }

  # --- 4. Collect procedures for scoped stays --------------------------------
  pr_dedup <- tibble::tibble(.visit_key = character(), code = character(), pr_date = as.Date(character()))
  pr_counts <- tibble::tibble(.visit_key = character(), n_pr = integer(), n_unmapped_pr = integer())
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
    pcs_concepts <- cdm$concept |>
      dplyr::filter(.data$vocabulary_id == !!pr_vocabulary) |>
      dplyr::select("concept_id", "concept_code")
    po_j <- po_scoped
    has_std_pr <- "procedure_concept_id" %in% po_cols
    has_src_pr <- "procedure_source_concept_id" %in% po_cols
    if (has_std_pr) {
      po_j <- dplyr::left_join(
        po_j,
        dplyr::rename(pcs_concepts, std_code = "concept_code"),
        by = c("procedure_concept_id" = "concept_id")
      )
    }
    if (has_src_pr) {
      po_j <- dplyr::left_join(
        po_j,
        dplyr::rename(pcs_concepts, src_code = "concept_code"),
        by = c("procedure_source_concept_id" = "concept_id")
      )
    }
    pr_keep <- intersect(c("visit_occurrence_id", "procedure_date", "std_code", "src_code"), colnames(po_j))
    pr_raw <- po_j |>
      dplyr::select(dplyr::all_of(pr_keep)) |>
      dplyr::collect()
    if (nrow(pr_raw) > 0L) {
      pr_raw$.visit_key <- omop_id_chr(pr_raw$visit_occurrence_id)
      pr_raw <- pr_raw |> dplyr::filter(.data$.visit_key %in% stays$.visit_key)
      std_c <- if ("std_code" %in% names(pr_raw)) pr_raw$std_code else rep(NA_character_, nrow(pr_raw))
      src_c <- if ("src_code" %in% names(pr_raw)) pr_raw$src_code else rep(NA_character_, nrow(pr_raw))
      pr_raw$code <- msdrg_normalize_code(dplyr::coalesce(std_c, src_c))
      pr_raw$pr_date <- if ("procedure_date" %in% names(pr_raw)) as.Date(pr_raw$procedure_date) else as.Date(NA)

      pr_counts <- pr_raw |>
        dplyr::group_by(.data$.visit_key) |>
        dplyr::summarise(
          n_pr = dplyr::n_distinct(.data$code[!is.na(.data$code)]),
          n_unmapped_pr = sum(is.na(.data$code)),
          .groups = "drop"
        )
      pr_dedup <- pr_raw |>
        dplyr::filter(!is.na(.data$code)) |>
        dplyr::arrange(.data$.visit_key, .data$pr_date, .data$code) |>
        dplyr::distinct(.data$.visit_key, .data$code, .keep_all = TRUE) |>
        dplyr::select(".visit_key", "code", "pr_date")
    }
  }

  # --- 5. Assemble stay-level metadata (demographics, discharge, counts) -----
  age <- omop_compute_age(
    stays$visit_start_date,
    if ("birth_datetime" %in% names(stays)) stays$birth_datetime else NULL,
    stays$year_of_birth,
    if ("month_of_birth" %in% names(stays)) stays$month_of_birth else NULL,
    if ("day_of_birth" %in% names(stays)) stays$day_of_birth else NULL
  )
  sex <- dplyr::case_when(
    as.integer(stays$gender_concept_id) == 8507L ~ 1L,
    as.integer(stays$gender_concept_id) == 8532L ~ 2L,
    TRUE ~ 0L
  )
  disc <- omop_resolve_discharge(
    died = died,
    disc_source_val = if ("discharged_to_source_value" %in% names(stays)) stays$discharged_to_source_value else NULL,
    disc_concept_id = if ("discharged_to_concept_id" %in% names(stays)) stays$discharged_to_concept_id else NULL,
    disc_vocab = if ("disc_vocab" %in% names(stays)) stays$disc_vocab else NULL,
    disc_code = if ("disc_code" %in% names(stays)) stays$disc_code else NULL,
    discharge_map = discharge_map,
    default_discharge = default_discharge
  )
  dx_counts <- dx_dedup |> dplyr::count(.data$.visit_key, name = "n_dx")

  base_stays <- tibble::tibble(
    .stay_key = stays$.stay_key,
    .visit_key = stays$.visit_key,
    visit_occurrence_id = stays$visit_occurrence_id,
    person_id = stays$person_id,
    visit_start_date = stays$visit_start_date,
    visit_end_date = stays$visit_end_date,
    los = as.integer(stays$visit_end_date - stays$visit_start_date),
    age = as.integer(age),
    sex = as.integer(sex),
    discharge_status = disc$discharge_status,
    discharge_source = disc$discharge_source
  )
  if (has_cohort_id) base_stays$cohort_definition_id <- stays$cohort_definition_id
  if (has_cohort_name) base_stays$cohort_name <- stays$cohort_name

  base_stays <- base_stays |>
    dplyr::left_join(dx_counts, by = ".visit_key") |>
    dplyr::left_join(pr_counts, by = ".visit_key") |>
    dplyr::mutate(
      n_dx = dplyr::coalesce(.data$n_dx, 0L),
      n_pr = dplyr::coalesce(.data$n_pr, 0L),
      n_unmapped_pr = dplyr::coalesce(.data$n_unmapped_pr, 0L),
      has_unmapped_pr = .data$n_unmapped_pr > 0L
    )

  cohort_cols <- c(
    if (has_cohort_id) "cohort_definition_id",
    if (has_cohort_name) "cohort_name"
  )

  # --- 6. Apply principal-diagnosis strategy ---------------------------------
  n_stays_with_primary_status <- dplyr::n_distinct(dx_dedup$.visit_key[dx_dedup$is_primary])

  if (principal == "all") {
    # One candidate claim per distinct diagnosis on a stay (+ 1 empty claim for
    # stays without diagnoses so no stay is silently lost).
    cand <- dx_dedup |>
      dplyr::arrange(.data$.visit_key, dplyr::desc(.data$is_primary), .data$dx_date, .data$code) |>
      dplyr::group_by(.data$.visit_key) |>
      dplyr::mutate(candidate_index = dplyr::row_number()) |>
      dplyr::ungroup() |>
      dplyr::select(".visit_key", "candidate_index", principal_code = "code") |>
      dplyr::mutate(principal_source = "all")

    no_dx_stays <- base_stays |>
      dplyr::distinct(.data$.visit_key, .data$n_dx) |>
      dplyr::filter(.data$n_dx == 0L) |>
      dplyr::transmute(.data$.visit_key, candidate_index = 0L, principal_code = NA_character_, principal_source = "none")

    cand_all <- dplyr::bind_rows(cand, no_dx_stays)
    claims <- base_stays |>
      dplyr::inner_join(cand_all, by = ".visit_key", relationship = "many-to-many") |>
      dplyr::mutate(claim_id = paste0(.data$.stay_key, "#", .data$candidate_index)) |>
      dplyr::select(
        "claim_id", dplyr::all_of(cohort_cols),
        "visit_occurrence_id", "person_id", "candidate_index",
        "visit_start_date", "visit_end_date", "los", "age", "sex",
        "discharge_status", "discharge_source", "principal_code", "principal_source",
        "n_dx", "n_pr", "n_unmapped_pr", "has_unmapped_pr", ".visit_key"
      )

    diagnoses <- claims |>
      dplyr::filter(.data$principal_source != "none") |>
      dplyr::select("claim_id", ".visit_key", "principal_code") |>
      dplyr::inner_join(dx_dedup |> dplyr::select(".visit_key", "code"), by = ".visit_key", relationship = "many-to-many") |>
      dplyr::arrange(.data$claim_id, .data$code != .data$principal_code, .data$code) |>
      dplyr::group_by(.data$claim_id) |>
      dplyr::mutate(seq = dplyr::row_number(), poa = NA_character_) |>
      dplyr::ungroup() |>
      dplyr::select("claim_id", "seq", "code", "poa")

    procedures <- claims |>
      dplyr::select("claim_id", ".visit_key") |>
      dplyr::inner_join(pr_dedup |> dplyr::select(".visit_key", "code", "pr_date"), by = ".visit_key", relationship = "many-to-many") |>
      dplyr::arrange(.data$claim_id, .data$pr_date, .data$code) |>
      dplyr::group_by(.data$claim_id) |>
      dplyr::mutate(seq = dplyr::row_number()) |>
      dplyr::ungroup() |>
      dplyr::select("claim_id", "seq", "code")
  } else {
    # One claim per stay (or per cohort-stay pair in a multi-cohort table).
    chosen_by_stay <- FALSE
    if (principal == "status") {
      if (n_stays_with_primary_status == 0L && nrow(dx_dedup) > 0L) {
        cli::cli_inform(c(
          "!" = "No primary diagnosis flags found in {.field condition_status_concept_id} (or legacy {.field condition_type_concept_id}).",
          i = "Stays without a principal diagnosis will group to DRG 999 (return code 7).",
          i = "Supply {.code principal = \"codelist\"} with {.arg principal_codes}, {.code principal = \"cohort_codelist\"} (with a {.pkg CohortConstructor} concept cohort), {.code principal = \"all\"} for a multi-candidate sensitivity analysis, or {.code principal = \"first\"}."
        ))
      }
      chosen <- dx_dedup |>
        dplyr::filter(.data$is_primary) |>
        dplyr::arrange(.data$.visit_key, dplyr::desc(.data$is_billable), .data$dx_date, .data$dx_id_chr, .data$code) |>
        dplyr::distinct(.data$.visit_key, .keep_all = TRUE) |>
        dplyr::transmute(.data$.visit_key, principal_code = .data$code, principal_source = "status")
    } else if (principal == "codelist") {
      if (parsed_codes$type == "code") {
        m <- omop_match_codelist(dx_dedup$code, parsed_codes$values)
        chosen <- dx_dedup |>
          dplyr::mutate(.rank = m$rank, .exact = m$exact) |>
          dplyr::filter(is.finite(.data$.rank)) |>
          dplyr::arrange(.data$.visit_key, .data$.rank, dplyr::desc(.data$is_billable), dplyr::desc(.data$.exact), .data$dx_date, .data$code) |>
          dplyr::distinct(.data$.visit_key, .keep_all = TRUE) |>
          dplyr::transmute(.data$.visit_key, principal_code = .data$code, principal_source = "codelist")
      } else {
        # Concept-ID codelist (e.g. CodelistGenerator / omopgenerics codelist).
        cids <- parsed_codes$values
        if (nrow(dx_raw) > 0L) {
          r_std <- match(dx_raw$.cond_cid, cids)
          r_src <- match(dx_raw$.src_cid, cids)
          rank <- pmin(dplyr::coalesce(r_std, Inf), dplyr::coalesce(r_src, Inf))
          chosen <- dx_raw |>
            dplyr::mutate(.rank = rank) |>
            dplyr::filter(is.finite(.data$.rank)) |>
            dplyr::arrange(.data$.visit_key, .data$.rank, dplyr::desc(.data$is_billable), .data$dx_date, .data$dx_id_chr, .data$code) |>
            dplyr::distinct(.data$.visit_key, .keep_all = TRUE) |>
            dplyr::transmute(.data$.visit_key, principal_code = .data$code, principal_source = "codelist")
        } else {
          chosen <- tibble::tibble(.visit_key = character(), principal_code = character(), principal_source = character())
        }
      }
    } else if (principal == "cohort_codelist") {
      # Use CohortConstructor's per-cohort defining concept_ids to choose the
      # principal diagnosis for each (cohort_definition_id, visit_occurrence_id).
      chosen_by_stay <- TRUE
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

      if (nrow(dx_raw) > 0L && has_cohort_id) {
        stay_dx <- base_stays |>
          dplyr::select(".stay_key", ".visit_key", "cohort_definition_id") |>
          dplyr::inner_join(
            dx_raw |> dplyr::select(".visit_key", "code", "is_billable", "dx_date", "dx_id_chr", ".cond_cid", ".src_cid"),
            by = ".visit_key",
            relationship = "many-to-many"
          )
        hit_std <- dplyr::inner_join(stay_dx, cc, by = c("cohort_definition_id", ".cond_cid" = "concept_id"))
        hit_src <- dplyr::inner_join(stay_dx, cc, by = c("cohort_definition_id", ".src_cid" = "concept_id"))
        chosen <- dplyr::bind_rows(hit_std, hit_src) |>
          dplyr::arrange(.data$.stay_key, dplyr::desc(.data$is_billable), .data$dx_date, .data$dx_id_chr, .data$code) |>
          dplyr::distinct(.data$.stay_key, .keep_all = TRUE) |>
          dplyr::transmute(.data$.stay_key, principal_code = .data$code, principal_source = "cohort_codelist")
      } else {
        chosen <- tibble::tibble(.stay_key = character(), principal_code = character(), principal_source = character())
      }
    } else {
      # principal == "first"
      chosen <- dx_dedup |>
        dplyr::arrange(.data$.visit_key, dplyr::desc(.data$is_primary), dplyr::desc(.data$is_billable), .data$dx_date, .data$dx_id_chr, .data$code) |>
        dplyr::distinct(.data$.visit_key, .keep_all = TRUE) |>
        dplyr::transmute(.data$.visit_key, principal_code = .data$code, principal_source = "first")
    }

    join_key <- if (chosen_by_stay) ".stay_key" else ".visit_key"
    claims <- base_stays |>
      dplyr::left_join(chosen, by = join_key) |>
      dplyr::mutate(
        claim_id = .data$.stay_key,
        principal_source = dplyr::coalesce(.data$principal_source, "none")
      ) |>
      dplyr::select(
        "claim_id", dplyr::all_of(cohort_cols),
        "visit_occurrence_id", "person_id",
        "visit_start_date", "visit_end_date", "los", "age", "sex",
        "discharge_status", "discharge_source", "principal_code", "principal_source",
        "n_dx", "n_pr", "n_unmapped_pr", "has_unmapped_pr", ".visit_key"
      )

    if (unmatched == "drop") {
      claims <- claims |> dplyr::filter(.data$principal_source != "none")
    }

    # Diagnoses: principal gets seq = 1; secondary diagnoses get seq = 2, 3, ...
    # Stays with principal_source == "none" start secondary diagnoses at seq = 2
    # so msdrg_group() recognises the absent principal diagnosis (RC 7).
    diagnoses <- dx_dedup |>
      dplyr::inner_join(
        claims |> dplyr::select("claim_id", ".visit_key", "principal_code"),
        by = ".visit_key",
        relationship = "many-to-many"
      ) |>
      dplyr::mutate(.is_pdx = !is.na(.data$principal_code) & .data$code == .data$principal_code) |>
      dplyr::arrange(.data$claim_id, dplyr::desc(.data$.is_pdx), .data$dx_date, .data$code) |>
      dplyr::group_by(.data$claim_id) |>
      dplyr::mutate(
        seq = if (any(.data$.is_pdx)) dplyr::row_number() else dplyr::row_number() + 1L,
        poa = NA_character_
      ) |>
      dplyr::ungroup() |>
      dplyr::select("claim_id", "seq", "code", "poa")

    procedures <- pr_dedup |>
      dplyr::inner_join(
        claims |> dplyr::select("claim_id", ".visit_key"),
        by = ".visit_key",
        relationship = "many-to-many"
      ) |>
      dplyr::arrange(.data$claim_id, .data$pr_date, .data$code) |>
      dplyr::group_by(.data$claim_id) |>
      dplyr::mutate(seq = dplyr::row_number()) |>
      dplyr::ungroup() |>
      dplyr::select("claim_id", "seq", "code")
  }

  # --- 7. Quality / readiness summary ----------------------------------------
  unique_stays <- dplyr::distinct(base_stays, .data$.visit_key, .keep_all = TRUE)
  n_stays_total <- nrow(unique_stays)
  n_with_dx <- sum(unique_stays$n_dx > 0L)
  n_with_pr <- sum(unique_stays$n_pr > 0L)
  n_with_unmapped_pr <- sum(unique_stays$has_unmapped_pr)
  n_with_principal <- dplyr::n_distinct(claims$.visit_key[claims$principal_source != "none"])
  dx_per_coded_stay <- unique_stays$n_dx[unique_stays$n_dx > 0L]

  dx_validity <- if (nrow(dx_dedup) > 0L) {
    dx_dedup |>
      dplyr::mutate(status = dplyr::case_when(
        .data$is_billable ~ "valid_billable",
        .data$is_header ~ "category_header",
        TRUE ~ "unrecognised"
      )) |>
      dplyr::group_by(.data$status) |>
      dplyr::summarise(n_rows = dplyr::n(), n_codes = dplyr::n_distinct(.data$code), .groups = "drop")
  } else {
    tibble::tibble(status = character(), n_rows = integer(), n_codes = integer())
  }
  top_headers <- if (nrow(dx_dedup) > 0L && any(dx_dedup$is_header)) {
    dx_dedup |>
      dplyr::filter(.data$is_header) |>
      dplyr::count(.data$code, name = "n_stays", sort = TRUE) |>
      utils::head(10L)
  } else {
    tibble::tibble(code = character(), n_stays = integer())
  }

  quality <- list(
    cdm_name = cdm_name,
    principal_strategy = principal,
    n_stays = n_stays_total,
    n_persons = dplyr::n_distinct(stays$.person_key),
    n_claims = nrow(claims),
    n_stays_with_dx = n_with_dx,
    pct_stays_with_dx = 100 * n_with_dx / n_stays_total,
    median_dx_per_stay = if (length(dx_per_coded_stay) > 0L) stats::median(dx_per_coded_stay) else NA_real_,
    mean_dx_per_stay = if (length(dx_per_coded_stay) > 0L) mean(dx_per_coded_stay) else NA_real_,
    n_stays_with_primary_status = n_stays_with_primary_status,
    pct_stays_with_primary_status = 100 * n_stays_with_primary_status / n_stays_total,
    n_stays_with_principal = n_with_principal,
    pct_stays_with_principal = 100 * n_with_principal / n_stays_total,
    n_stays_with_pr = n_with_pr,
    pct_stays_with_pr = 100 * n_with_pr / n_stays_total,
    n_stays_with_unmapped_pr = n_with_unmapped_pr,
    pct_stays_with_unmapped_pr = 100 * n_with_unmapped_pr / n_stays_total,
    discharge_sources = unique_stays |> dplyr::count(.data$discharge_source, sort = TRUE),
    dx_code_validity = dx_validity,
    top_category_headers = top_headers
  )
  if (has_cohort_id) {
    quality$cohorts <- claims |>
      dplyr::group_by(dplyr::across(dplyr::all_of(cohort_cols))) |>
      dplyr::summarise(
        n_stays = dplyr::n_distinct(.data$.visit_key),
        n_claims = dplyr::n(),
        n_with_principal = sum(.data$principal_source != "none"),
        .groups = "drop"
      )
  }

  claims <- dplyr::select(claims, -".visit_key")
  if (has_cohort_id && principal == "all") {
    claims <- dplyr::arrange(claims, .data$cohort_definition_id, .data$visit_occurrence_id, .data$candidate_index)
  } else if (has_cohort_id) {
    claims <- dplyr::arrange(claims, .data$cohort_definition_id, .data$visit_occurrence_id)
  } else if (principal == "all") {
    claims <- dplyr::arrange(claims, .data$visit_occurrence_id, .data$candidate_index)
  } else {
    claims <- dplyr::arrange(claims, .data$visit_occurrence_id)
  }

  structure(
    list(claims = claims, diagnoses = diagnoses, procedures = procedures, quality = quality),
    class = c("omop_msdrg_input", "list")
  )
}

#' @export
print.omop_msdrg_input <- function(x, ...) {
  q <- x$quality
  cat(sprintf("<opendrg OMOP MS-DRG input> CDM: %s (principal = \"%s\")\n", q$cdm_name, q$principal_strategy))
  cat(sprintf(
    "Stays: %s (%s persons) -> %s claim%s\n",
    format(q$n_stays, big.mark = ","),
    format(q$n_persons, big.mark = ","),
    format(q$n_claims, big.mark = ","),
    if (q$n_claims == 1L) "" else "s"
  ))
  if (q$n_stays > 0L) {
    cat(sprintf(
      "Diagnoses: %.1f%% of stays coded (median %.0f, mean %.1f); %.1f%% with OMOP primary flag; %.1f%% with principal assigned\n",
      q$pct_stays_with_dx, q$median_dx_per_stay, q$mean_dx_per_stay,
      q$pct_stays_with_primary_status, q$pct_stays_with_principal
    ))
    cat(sprintf(
      "Procedures: %.1f%% of stays with ICD-10-PCS; %.1f%% with unmapped procedures\n",
      q$pct_stays_with_pr, q$pct_stays_with_unmapped_pr
    ))
  }
  invisible(x)
}

#' Compute MS-DRGs for patients in an OMOP CDM or `CohortConstructor` cohort
#'
#' Given a `cdm_reference` object from `CDMConnector` (or `omopgenerics`) — or
#' directly a `CohortConstructor` `cohort_table` — extracts the scoped
#' inpatient stays with [omop_to_msdrg()], groups them with [msdrg_group()],
#' and returns a tibble with one row per stay (or per cohort-stay pair in a
#' multi-cohort table, or per candidate principal diagnosis when
#' `principal = "all"`), combining the OMOP cohort/patient/visit identifiers
#' and quality flags with the assigned MS-DRG.
#'
#' This function can also be invoked through the unified interface via
#' `group(grouper("msdrg"), cdm, ...)` or
#' `group(grouper("msdrg"), cdm$my_cohort, ...)`.
#'
#' @param cdm A `cdm_reference` object (from `CDMConnector::cdmFromCon()` or
#'   `omopgenerics::cdmFromTables()`), a `CohortConstructor` `cohort_table`, or
#'   a named list of OMOP tables.
#' @param tables MS-DRG logic tables from [msdrg_tables()] or a version label
#'   such as `"44.0"`.
#' @param poa_exempt Hospital's POA-reporting status passed to [msdrg_group()].
#'   Defaults to `"exempt"` because standard OMOP CDMs do not carry CMS
#'   present-on-admission indicators.
#' @param ... Additional arguments passed to [omop_to_msdrg()] (such as
#'   `cohort`, `cohort_id`, `cohort_match`, `start_date`, `end_date`, `n_max`,
#'   `principal`, `principal_codes`, `unmatched`, `discharge_map`,
#'   `default_discharge`, `snomed_fallback`, `link_by`).
#' @return A tibble with OMOP stay columns (`claim_id`, optional
#'   `cohort_definition_id` and `cohort_name`, `visit_occurrence_id`,
#'   `person_id`, `visit_start_date`, `visit_end_date`, `los`, `age`, `sex`,
#'   `discharge_status`, `discharge_source`, `principal_code`,
#'   `principal_source`, `n_dx`, `n_pr`, `has_unmapped_pr`, plus
#'   `candidate_index` when `principal = "all"`) and the MS-DRG outputs (`drg`,
#'   `initial_drg`, `base_drg`, `mdc`, `med_surg`, `severity`,
#'   `initial_severity`, `return_code`, `drg_description`, `mdc_description`,
#'   `formula`). The CDM readiness and quality report is attached as an
#'   attribute and can be inspected with [omop_msdrg_quality()].
#' @export
#' @examples
#' cdm <- list(
#'   person = tibble::tibble(
#'     person_id = 1L, gender_concept_id = 8507L,
#'     year_of_birth = 1957L, month_of_birth = 3L, day_of_birth = 15L
#'   ),
#'   visit_occurrence = tibble::tibble(
#'     visit_occurrence_id = 101L, person_id = 1L, visit_concept_id = 9201L,
#'     visit_start_date = as.Date("2024-05-02"), visit_end_date = as.Date("2024-05-06"),
#'     discharged_to_concept_id = 8536L, discharged_to_source_value = "1"
#'   ),
#'   condition_occurrence = tibble::tibble(
#'     condition_occurrence_id = 1:3, person_id = 1L, visit_occurrence_id = 101L,
#'     condition_concept_id = c(312327L, 201826L, 197320L),
#'     condition_source_concept_id = c(1001L, 1002L, 1003L),
#'     condition_status_concept_id = c(32902L, 32908L, 32908L),
#'     condition_type_concept_id = 32817L,
#'     condition_start_date = as.Date("2024-05-02")
#'   ),
#'   procedure_occurrence = tibble::tibble(
#'     procedure_occurrence_id = 1L, person_id = 1L, visit_occurrence_id = 101L,
#'     procedure_concept_id = 2001L, procedure_source_concept_id = 0L,
#'     procedure_date = as.Date("2024-05-02")
#'   ),
#'   concept = tibble::tibble(
#'     concept_id = c(1001L, 1002L, 1003L, 2001L),
#'     vocabulary_id = c("ICD10CM", "ICD10CM", "ICD10CM", "ICD10PCS"),
#'     concept_code = c("I21.4", "E11.9", "N17.9", "02703ZZ")
#'   )
#' )
#' res <- omop_msdrg(cdm, tables = "44.0")
#' res[c("person_id", "visit_occurrence_id", "drg", "severity", "drg_description")]
#' omop_msdrg_quality(res)
omop_msdrg <- function(cdm, tables = msdrg_tables(),
                       poa_exempt = c("exempt", "non_exempt", "unknown"), ...) {
  tbls <- msdrg_tables(tables)
  poa_exempt <- rlang::arg_match(poa_exempt)
  inp <- omop_to_msdrg(cdm, ..., tables = tbls)

  if (nrow(inp$claims) == 0L) {
    empty_drg <- tibble::tibble(
      claim_id = character(), drg = integer(), initial_drg = integer(),
      base_drg = integer(), mdc = integer(), med_surg = character(),
      severity = character(), initial_severity = character(),
      return_code = integer(), drg_description = character(),
      mdc_description = character(), formula = character()
    )
    out <- dplyr::left_join(inp$claims, empty_drg, by = "claim_id")
    attr(out, "quality") <- inp$quality
    return(out)
  }

  grouped <- msdrg_group(inp$claims, inp$diagnoses, inp$procedures, tables = tbls, poa_exempt = poa_exempt)
  out <- inp$claims |>
    dplyr::left_join(grouped, by = "claim_id")

  q <- inp$quality
  q$msdrg_version <- tbls$version
  q$n_grouped <- sum(out$return_code == 0L, na.rm = TRUE)
  q$pct_grouped <- 100 * q$n_grouped / nrow(out)
  q$n_surgical <- sum(out$return_code == 0L & !is.na(out$med_surg) & out$med_surg == "S")
  q$pct_surgical <- if (q$n_grouped > 0L) 100 * q$n_surgical / q$n_grouped else NA_real_
  q$return_codes <- out |> dplyr::count(.data$return_code, sort = TRUE)
  attr(out, "quality") <- q
  out
}

#' Inspect the CDM readiness and quality report of an OMOP MS-DRG run
#'
#' Extracts the `quality` metadata attached by [omop_to_msdrg()] or
#' [omop_msdrg()], summarising diagnosis coding depth, primary-diagnosis flag
#' coverage, category-level ICD-10-CM headers, unmapped procedures, discharge
#' resolution sources and (after grouping) grouping success and surgical share.
#'
#' @param x An object returned by [omop_to_msdrg()] or [omop_msdrg()].
#' @return A list with class `omop_msdrg_quality`.
#' @export
omop_msdrg_quality <- function(x) {
  q <- if (inherits(x, "omop_msdrg_input")) {
    x$quality
  } else {
    attr(x, "quality")
  }
  if (is.null(q)) {
    cli::cli_abort("{.arg x} does not carry an OMOP MS-DRG quality report.")
  }
  structure(q, class = c("omop_msdrg_quality", "list"))
}

#' @export
print.omop_msdrg_quality <- function(x, ...) {
  ver <- if (!is.null(x$msdrg_version)) paste0(", MS-DRG v", x$msdrg_version) else ""
  cat(sprintf("<opendrg OMOP quality report> CDM: %s (principal = \"%s\"%s)\n", x$cdm_name, x$principal_strategy, ver))
  cat(sprintf(
    "Stays: %s (%s persons); Claims: %s\n",
    format(x$n_stays, big.mark = ","),
    format(x$n_persons, big.mark = ","),
    format(x$n_claims, big.mark = ",")
  ))
  if (x$n_stays > 0L) {
    cat(sprintf(
      "Diagnoses: %.1f%% of stays coded (median %.0f, mean %.1f); %.1f%% OMOP primary flag; %.1f%% principal assigned\n",
      x$pct_stays_with_dx, x$median_dx_per_stay, x$mean_dx_per_stay,
      x$pct_stays_with_primary_status, x$pct_stays_with_principal
    ))
    cat(sprintf(
      "Procedures: %.1f%% with ICD-10-PCS; %.1f%% with unmapped procedures\n",
      x$pct_stays_with_pr, x$pct_stays_with_unmapped_pr
    ))
    if (!is.null(x$n_grouped)) {
      cat(sprintf(
        "Grouped (RC 0): %s / %s claims (%.1f%%); surgical: %.1f%%\n",
        format(x$n_grouped, big.mark = ","),
        format(x$n_claims, big.mark = ","),
        x$pct_grouped,
        dplyr::coalesce(x$pct_surgical, 0)
      ))
    }
    if (nrow(x$dx_code_validity) > 0L) {
      parts <- sprintf("%s=%s", x$dx_code_validity$status, format(x$dx_code_validity$n_rows, big.mark = ",", trim = TRUE))
      cat("Diagnosis code validity:", paste(parts, collapse = ", "), "\n")
    }
    if (nrow(x$discharge_sources) > 0L) {
      parts <- sprintf("%s=%s", x$discharge_sources$discharge_source, format(x$discharge_sources$n, big.mark = ",", trim = TRUE))
      cat("Discharge sources:", paste(parts, collapse = ", "), "\n")
    }
  }
  invisible(x)
}
