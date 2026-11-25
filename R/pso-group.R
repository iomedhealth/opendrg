# Prescribed Specialised Services (PSS) identification: the service-line
# flags that NHS England's Operational Tool (PSO) derives for admitted patient
# care episodes and outpatient attendances.
#
# Each identification rule is a conjunction of list conditions (age band,
# provider eligibility, specialty, ICD-10 in a given position, OPCS-4 anywhere
# or as the dominant procedure, code combinations); a service line is flagged
# when any of its rules is satisfied. The dominant service line of a record
# is the flagged one with the highest hierarchy value; a spell's dominant
# service line is the highest across its episodes.

pso_cache <- new.env(parent = emptyenv())

#' List the Prescribed Specialised Services rule versions bundled with opendrg
#' @return Character vector of version labels such as `"2025-26"`.
#' @export
pso_versions <- function() {
  files <- list.files(system.file("extdata", "pso", package = "opendrg"), pattern = "\\.rds$")
  sort(sub("\\.rds$", "", files))
}

#' Load the Prescribed Specialised Services rules for one version
#' @param version Version label, e.g. `"2025-26"`, or a `pso_tables` object
#'   from [pso_import_rules()].
#' @return A `pso_tables` list prepared for the engine.
#' @export
pso_tables <- function(version = NULL) {
  if (inherits(version, "pso_tables")) {
    if (is.null(version$prepared)) version <- pso_prepare_tables(version)
    return(version)
  }
  available <- pso_versions()
  version <- version %||% available[[length(available)]]
  if (!version %in% available) {
    cli::cli_abort("PSO version {.val {version}} is not bundled. Bundled: {.val {available}}.")
  }
  if (!exists(version, envir = pso_cache, inherits = FALSE)) {
    path <- system.file("extdata", "pso", paste0(version, ".rds"), package = "opendrg")
    assign(version, pso_prepare_tables(readRDS(path)), envir = pso_cache)
  }
  get(version, envir = pso_cache, inherits = FALSE)
}

pso_prepare_tables <- function(tbls) {
  tbls$list_sets <- split(tbls$lists$code, tbls$lists$list_id)
  nested <- tbls$lists[!is.na(tbls$lists$value), ]
  tbls$list_by_value <- lapply(split(nested, nested$list_id), function(l) split(l$code, l$value))
  tbls$age_sets <- split(tbls$ages, tbls$ages$list_id)
  rules <- split(tbls$rules, tbls$rules$setting)
  tbls$rule_sets <- lapply(rules, function(r) split(r, r$doc_flag))
  sl <- tbls$service_lines
  tbls$hierarchy <- lapply(split(sl, sl$setting), function(s) stats::setNames(s$hierarchy, s$service_line))
  tbls$npoc <- lapply(split(sl, sl$setting), function(s) stats::setNames(s$npoc, s$service_line))
  tbls$proc_hier <- stats::setNames(tbls$opcs$hierarchy, tbls$opcs$code)
  tbls$icd_valid <- tbls$icd10$code
  tbls$opcs_valid <- tbls$opcs$code
  tbls$field_valid <- split(tbls$reference_data$code, tbls$reference_data$field)
  tbls$prepared <- TRUE
  tbls
}

pso_field_labels <- c(
  PROCODET = "Provider Code", PROVSPNO = "Provider Spell Number", STARTAGE = "Age", SEX = "Sex",
  CLASSPAT = "Patient Classification", ADMIMETH = "Admission Method", MAINSPEF = "Main Specialty Code",
  TRETSPEF = "Treatment Function Code", ATTENDED = "Attendance Status Code", REFSOURC = "Referral Source"
)

# Validate one record; the message order follows the tool's field order.
pso_validate <- function(row, setting, tbls) {
  errs <- character()
  add <- function(field, code, msg) errs <<- c(errs, paste(field, ifelse(is.na(code), "", code), msg, sep = "|"))
  check <- function(field, value, valid = tbls$field_valid[[field]]) {
    if (is.na(value)) add(field, NA, paste(pso_field_labels[[field]], "is blank"))
    else if (!is.null(valid) && !value %in% valid) add(field, value, paste(pso_field_labels[[field]], "is invalid"))
  }
  check("PROCODET", hrg_scalar(row, "PROCODET"), NULL)
  if (setting == "APC") check("PROVSPNO", hrg_scalar(row, "PROVSPNO"), NULL)
  age <- pso_age(row)
  if (is.na(age)) add("STARTAGE", NA, "Age is blank")
  else if (!hrg_valid_age(age)) add("STARTAGE", age, "Age is invalid")
  check("SEX", hrg_scalar(row, "SEX"))
  if (setting == "APC") {
    check("CLASSPAT", hrg_scalar(row, "CLASSPAT"))
    check("ADMIMETH", hrg_scalar(row, "ADMIMETH"))
  } else {
    check("ATTENDED", hrg_scalar(row, "ATTENDED"))
    check("REFSOURC", hrg_scalar(row, "REFSOURC"))
  }
  check("MAINSPEF", hrg_scalar(row, "MAINSPEF"))
  check("TRETSPEF", hrg_scalar(row, "TRETSPEF"))
  diag_cols <- grep("^DIAG_[0-9]+$", names(row), value = TRUE)
  diag <- hrg_norm_code(unlist(row[diag_cols]))
  if (setting == "APC" && (length(diag) == 0 || is.na(diag[1]))) add("DIAG_01", NA, "Primary Diagnosis is blank")
  for (k in seq_along(diag)) {
    if (!is.na(diag[k]) && !diag[k] %in% tbls$icd_valid) {
      add(diag_cols[k], diag[k], paste(if (k == 1) "Primary" else "Secondary", "Diagnosis is invalid"))
    }
  }
  oper_cols <- grep("^OPER_[0-9]+$", names(row), value = TRUE)
  oper <- hrg_norm_code(unlist(row[oper_cols]))
  for (k in seq_along(oper)) {
    if (!is.na(oper[k]) && !oper[k] %in% tbls$opcs_valid) add(oper_cols[k], oper[k], "Procedure is invalid")
  }
  errs
}

pso_age <- function(row) {
  a <- hrg_scalar(row, "STARTAGE")
  if (is.na(a)) a <- hrg_scalar(row, "AGE")
  a
}

# Evaluate every identification rule of one setting against one record and
# return the service lines it qualifies for.
pso_flag_record <- function(row, setting, tbls) {
  age <- suppressWarnings(as.numeric(pso_age(row)))
  procodet <- hrg_scalar(row, "PROCODET")
  diag <- hrg_norm_code(unlist(row[grep("^DIAG_[0-9]+$", names(row))]))
  primary <- if (length(diag) > 0) diag[1] else NA_character_
  secondary <- diag[-1][!is.na(diag[-1])]
  diag <- diag[!is.na(diag)]
  oper <- hrg_norm_code(unlist(row[grep("^OPER_[0-9]+$", names(row))]))
  oper <- unname(oper[!is.na(oper)])
  dominant <- NA_character_
  if (length(oper) > 0) {
    h <- unname(tbls$proc_hier[oper])
    h[is.na(h)] <- -1
    dominant <- oper[which.max(h)]
  }
  scalars <- list(
    SEX = hrg_scalar(row, "SEX"), ADMIMETH = hrg_scalar(row, "ADMIMETH"), MAINSPEF = hrg_scalar(row, "MAINSPEF"),
    TRETSPEF = hrg_scalar(row, "TRETSPEF"), ATTENDED = hrg_scalar(row, "ATTENDED"), REFSOURC = hrg_scalar(row, "REFSOURC")
  )

  condition <- function(r) {
    set <- tbls$list_sets[[r$list_id]]
    switch(r$code_type,
      Age = {
        band <- tbls$age_sets[[r$list_id]]
        !is.na(age) && ((age >= band$min && age <= band$max) || (band$allow_999 && age == 999))
      },
      Org = !is.na(procodet) && procodet %in% set,
      ICD = switch(r$position,
        "Primary Diagnosis" = !is.na(primary) && primary %in% set,
        "Secondary Diagnoses" = any(secondary %in% set),
        any(diag %in% set)
      ),
      OPCS = switch(r$fn,
        DGVPInList = !is.na(dominant) && dominant %in% set,
        NestedDataItemInList = {
          by_value <- tbls$list_by_value[[r$list_id]]
          all(vapply(seq_len(r$needed), function(v) any(oper %in% by_value[[as.character(v)]]), logical(1)))
        },
        NestedDGVPInList = {
          by_value <- tbls$list_by_value[[r$list_id]]
          !is.na(dominant) && dominant %in% by_value[["1"]] &&
            all(vapply(seq_len(r$needed)[-1], function(v) any(oper %in% by_value[[as.character(v)]]), logical(1)))
        },
        any(oper %in% set)
      ),
      {
        v <- scalars[[r$code_type]]
        !is.na(v) && v %in% set
      }
    )
  }

  flagged <- character()
  for (rules in tbls$rule_sets[[setting]]) {
    ok <- TRUE
    for (i in seq_len(nrow(rules))) {
      if (!condition(rules[i, ])) {
        ok <- FALSE
        break
      }
    }
    if (ok) flagged <- c(flagged, rules$service_line[1])
  }
  list(service_lines = sort(unique(flagged)), dominant_procedure = dominant)
}

pso_dominant <- function(service_lines, setting, tbls) {
  if (length(service_lines) == 0) return(NA_character_)
  h <- tbls$hierarchy[[setting]][service_lines]
  service_lines[which.max(h)]
}

#' Flag Prescribed Specialised Services in admitted patient care episodes
#'
#' Applies NHS England's Prescribed Specialised Services identification rules
#' to episodes in the PSO admitted patient care layout and derives, as the
#' Operational Tool does, the service lines each episode qualifies for, the
#' dominant service line and National Programme of Care (NPoC) of the episode
#' and of its spell. Episodes with validation errors get no service lines but
#' their spells are still assessed from the remaining episodes.
#'
#' @param episodes Data frame with one row per episode: `PROCODET`,
#'   `PROVSPNO`, `STARTAGE` (or `AGE`), `SEX`, `CLASSPAT`, `ADMIMETH`,
#'   `MAINSPEF`, `TRETSPEF`, `DIAG_01`..., `OPER_01`....
#' @param tables Rules from [pso_tables()].
#' @return A list with `episodes` (one row per input episode, in input order:
#'   `fce_npoc`, `service_line`, `service_line_list`, `dominant_procedure`,
#'   `quality`, `spell`, `spell_npoc`, `spell_service_line`) and `spells`
#'   (one row per spell).
#' @export
pso_flag_apc <- function(episodes, tables = pso_tables()) {
  tbls <- pso_tables(tables)
  episodes <- dplyr::mutate(tibble::as_tibble(episodes), dplyr::across(dplyr::everything(), as.character))
  for (col in c("PROCODET", "PROVSPNO")) if (!col %in% names(episodes)) episodes[[col]] <- NA_character_
  rows <- lapply(seq_len(nrow(episodes)), function(i) {
    row <- as.list(episodes[i, ])
    errs <- pso_validate(row, "APC", tbls)
    res <- if (length(errs) == 0) pso_flag_record(row, "APC", tbls) else list(service_lines = character(), dominant_procedure = NA_character_)
    res$errors <- errs
    res
  })
  spell_key <- paste(dplyr::coalesce(episodes$PROCODET, ""), dplyr::coalesce(episodes$PROVSPNO, ""), sep = "|")
  spell_ids <- unique(spell_key)
  spell_of_episode <- match(spell_key, spell_ids)
  spells <- lapply(seq_along(spell_ids), function(s) {
    idx <- which(spell_of_episode == s)
    lines <- unique(unlist(lapply(rows[idx], function(r) r$service_lines)))
    dom <- pso_dominant(lines, "APC", tbls)
    list(first_row = idx[1], service_line = dom, npoc = if (is.na(dom)) NA_character_ else unname(tbls$npoc$APC[dom]))
  })
  dominant <- vapply(rows, function(r) pso_dominant(r$service_lines, "APC", tbls), character(1))
  ep <- tibble::tibble(
    row = seq_len(nrow(episodes)),
    fce_npoc = ifelse(is.na(dominant), NA_character_, unname(tbls$npoc$APC[dominant])),
    service_line = dominant,
    service_line_list = vapply(rows, function(r) if (length(r$service_lines) == 0) NA_character_ else paste(r$service_lines, collapse = ";"), character(1)),
    dominant_procedure = vapply(rows, function(r) r$dominant_procedure, character(1)),
    quality = vapply(rows, function(r) paste(r$errors, collapse = ";"), character(1)),
    spell = spell_of_episode
  )
  sp <- tibble::tibble(
    spell = seq_along(spells),
    procodet = episodes$PROCODET[vapply(spells, function(s) s$first_row, integer(1))],
    provspno = episodes$PROVSPNO[vapply(spells, function(s) s$first_row, integer(1))],
    first_row = vapply(spells, function(s) s$first_row, integer(1)),
    spell_npoc = vapply(spells, function(s) s$npoc, character(1)),
    spell_service_line = vapply(spells, function(s) s$service_line, character(1))
  )
  ep <- dplyr::left_join(ep, sp[c("spell", "spell_npoc", "spell_service_line")], by = "spell")
  list(episodes = ep, spells = sp)
}

#' Flag Prescribed Specialised Services in outpatient attendances
#'
#' @param attendances Data frame with one row per attendance: `PROCODET`,
#'   `STARTAGE`, `SEX`, `ATTENDED`, `REFSOURC`, `MAINSPEF`, `TRETSPEF`,
#'   `DIAG_01`..., `OPER_01`....
#' @param tables Rules from [pso_tables()].
#' @return A tibble with `npoc`, `service_line`, `service_line_list`,
#'   `dominant_procedure` and `quality` per attendance.
#' @export
pso_flag_nac <- function(attendances, tables = pso_tables()) {
  tbls <- pso_tables(tables)
  attendances <- dplyr::mutate(tibble::as_tibble(attendances), dplyr::across(dplyr::everything(), as.character))
  rows <- lapply(seq_len(nrow(attendances)), function(i) {
    row <- as.list(attendances[i, ])
    errs <- pso_validate(row, "NAC", tbls)
    res <- if (length(errs) == 0) pso_flag_record(row, "NAC", tbls) else list(service_lines = character(), dominant_procedure = NA_character_)
    res$errors <- errs
    res
  })
  dominant <- vapply(rows, function(r) pso_dominant(r$service_lines, "NAC", tbls), character(1))
  tibble::tibble(
    row = seq_len(nrow(attendances)),
    npoc = ifelse(is.na(dominant), NA_character_, unname(tbls$npoc$NAC[dominant])),
    service_line = dominant,
    service_line_list = vapply(rows, function(r) if (length(r$service_lines) == 0) NA_character_ else paste(r$service_lines, collapse = ";"), character(1)),
    dominant_procedure = vapply(rows, function(r) r$dominant_procedure, character(1)),
    quality = vapply(rows, function(r) paste(r$errors, collapse = ";"), character(1))
  )
}
