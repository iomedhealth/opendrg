# HRG4+ admitted-patient-care grouping.
#
# Implements the published HRG4+ logic as documented in NHS England's Code to
# Group workbook, User Manual and Chapter Summaries (see
# dev/notes/hrg4plus-engine-spec.md for the derivation and its verification):
#
#   episode:  validation -> combination codes -> unbundled HRGs (consuming
#             their codes) -> dominant procedure -> core root with precedence
#             burns (B) > multiple trauma (M) > procedure-driven (P) > global
#             exception (G) > diagnosis-driven (D) -> Core 3 escalation ->
#             Group To Split -> PBC
#   spell:    pseudo-record of the dominant episode with the union of the
#             spell's diagnoses and procedures, grouped with the same engine.
#
# Every rule is an ordered (HRG, flag) list evaluated last-satisfied-wins, and
# every flag is a conjunction of Simple Flags conditions.

hrg_cache <- new.env(parent = emptyenv())

#' List the HRG4+ versions bundled with opendrg
#' @return Character vector of version labels such as `"2024-25-nc"`.
#' @export
hrg_versions <- function() {
  files <- list.files(system.file("extdata", "hrg", package = "opendrg"), pattern = "\\.rds$")
  sort(sub("\\.rds$", "", files))
}

#' Load the HRG4+ logic tables for one version
#' @param version Version label, e.g. `"2024-25-nc"`, or an `hrg_tables` object
#'   from [hrg_import_code_to_group()].
#' @return An `hrg_tables` list prepared for the engine.
#' @export
hrg_tables <- function(version = NULL) {
  if (inherits(version, "hrg_tables")) {
    if (is.null(version$prepared)) version <- hrg_prepare_tables(version)
    return(version)
  }
  available <- hrg_versions()
  version <- version %||% available[[length(available)]]
  if (!version %in% available) {
    cli::cli_abort("HRG4+ version {.val {version}} is not bundled. Bundled: {.val {available}}.")
  }
  if (!exists(version, envir = hrg_cache, inherits = FALSE)) {
    path <- system.file("extdata", "hrg", paste0(version, ".rds"), package = "opendrg")
    assign(version, hrg_prepare_tables(readRDS(path)), envir = hrg_cache)
  }
  get(version, envir = hrg_cache, inherits = FALSE)
}

hrg_unbundled_types <- c("Uassess", "UChem1", "UChem2", "UDrugs", "URad", "URadiot1", "URadiot2", "Urehab", "URenal")
hrg_apc_fields <- c("SEX", "CLASSPAT", "ADMISORC", "ADMIMETH", "DISDEST", "DISMETH", "MAINSPEF", "TRETSPEF")
hrg_field_labels <- c(
  SEX = "Sex", CLASSPAT = "Patient Classification", ADMISORC = "Admission Source",
  ADMIMETH = "Admission Method", DISDEST = "Discharge Destination", DISMETH = "Discharge Method",
  MAINSPEF = "Main Specialty Code", TRETSPEF = "Treatment Function Code", EPIDUR = "Episode Duration",
  STARTAGE = "Age"
)
hrg_uz_messages <- c(
  UZ01 = "UZ01 - Invalid Primary Diagnosis", UZ02 = "UZ02 - Poorly Coded Primary Diagnosis",
  UZ03 = "UZ03 - Diagnosis Conflicts with Age", UZ04 = "UZ04 - Diagnosis Conflicts with Anatomical Site",
  UZ05 = "UZ05 - Invalid procedure for Casemix grouping purposes",
  UZ06 = "UZ06 - Poorly coded procedure for Casemix grouping purposes",
  UZ15 = "UZ15 - Burns Error"
)

hrg_prepare_tables <- function(tbls) {
  lists <- tbls$lists
  tbls$list_sets <- split(lists$code, lists$list_id)
  tbls$list_values <- split(stats::setNames(lists$value, lists$code), lists$list_id)
  tbls$proc_hier <- stats::setNames(lists$value[lists$list_id == "ProcHier"], lists$code[lists$list_id == "ProcHier"])
  tbls$diag_hier <- stats::setNames(lists$value[lists$list_id == "DiagHier"], lists$code[lists$list_id == "DiagHier"])
  tbls$qualifiers <- unique(lists$code[lists$kind == "global" & lists$list_id %in% c("Approach", "Site")])
  rules <- dplyr::distinct(tbls$flag_rules, .data$flag, .data$order, .data$fn, .data$data_item,
                           .data$pos_min, .data$pos_max, .data$list_id, .data$sum_min)
  tbls$rule_sets <- split(rules, rules$flag)
  c2g <- tbls$code_to_group |>
    dplyr::mutate(class = ifelse(.data$code_type == "ICD", "ICD", ifelse(.data$code_type %in% c("OPCS", "Combination"), "PROC", .data$code_type))) |>
    dplyr::inner_join(tbls$code_to_group_hrgs, by = "row_id", relationship = "many-to-many") |>
    dplyr::arrange(.data$row_id, .data$rank)
  tbls$c2g_by_key <- split(c2g[c("rank", "hrg", "flag")], paste(c2g$type, c2g$class, c2g$code, sep = "|"))
  tbls$split_by_root <- split(tbls$group_to_split_hrgs[c("rank", "hrg", "flag")], tbls$group_to_split_hrgs$root)
  combos <- tbls$combination_codes |> dplyr::arrange(.data$driving_code, dplyr::desc(.data$order))
  tbls$combos_by_driver <- split(combos, combos$driving_code)
  pbc <- tbls$pbc_mappings |> dplyr::filter(.data$code_type == "ICD") |> dplyr::arrange(.data$code, .data$rank)
  tbls$pbc_by_code <- split(pbc[c("rank", "pbc", "flag")] |> dplyr::rename(hrg = "pbc"), pbc$code)
  tbls$icd_valid <- unique(tbls$icd10$code)
  tbls$opcs_valid <- unique(tbls$opcs$code)
  ref <- tbls$reference_data
  tbls$field_valid <- split(ref$code, ref$field)
  tbls$prepared <- TRUE
  tbls
}

hrg_norm_code <- function(x) {
  x <- toupper(gsub("[.[:space:]]", "", as.character(x)))
  x[!is.na(x) & x == ""] <- NA_character_
  x
}

hrg_scalar <- function(row, name) {
  v <- row[[name]]
  if (is.null(v) || length(v) == 0 || is.na(v)) return(NA_character_)
  v <- trimws(as.character(v))
  if (v == "") NA_character_ else v
}

hrg_days <- function(row, name) {
  v <- suppressWarnings(as.numeric(hrg_scalar(row, name)))
  if (is.na(v)) 0 else v
}

# ---------------------------------------------------------------------------
# Episode context

# Qualifier run: contiguous Site/Approach codes immediately after position p.
hrg_qualifier_run <- function(codes, p, tbls) {
  # `tbls` may be the prepared tables or an episode context; both carry $qualifiers.
  run <- integer()
  i <- p + 1L
  while (i <= length(codes) && codes[i] %in% tbls$qualifiers) {
    run <- c(run, i)
    i <- i + 1L
  }
  run
}

hrg_form_combinations <- function(procs, tbls) {
  eff <- procs
  n <- length(procs)
  for (p in seq_len(n)) {
    defs <- tbls$combos_by_driver[[procs[p]]]
    if (is.null(defs)) next
    run <- hrg_qualifier_run(procs, p, tbls)
    others <- setdiff(seq_len(n), p)
    matches <- function(code, type) {
      if (is.na(code)) return(TRUE)
      set <- if (grepl("^CL_", code)) tbls$list_sets[[code]] else code
      positions <- if (identical(type, "Any Position")) others else run
      any(procs[positions] %in% set)
    }
    for (k in seq_len(nrow(defs))) {
      if (matches(defs$qualifying_code_1[k], defs$qualifier_type_1[k]) &&
          matches(defs$qualifying_code_2[k], defs$qualifier_type_2[k])) {
        eff[p] <- defs$combination_code[k]
        break
      }
    }
  }
  eff
}

hrg_episode_context <- function(row, tbls) {
  diag <- hrg_norm_code(unlist(row[grep("^DIAG_[0-9]+$", names(row))]))
  diag <- unname(diag[!is.na(diag)])
  oper <- hrg_norm_code(unlist(row[grep("^OPER_[0-9]+$", names(row))]))
  oper <- unname(oper[!is.na(oper)])
  cc_days <- hrg_days(row, "CRITICALCAREDAYS")
  rehab_days <- hrg_days(row, "REHABILITATIONDAYS")
  spc_days <- hrg_days(row, "SPCDAYS")
  epidur_raw <- hrg_scalar(row, "EPIDUR")
  epidur <- suppressWarnings(as.numeric(epidur_raw))
  calc_epidur <- max(0, (if (is.na(epidur)) 0 else epidur) - cc_days - rehab_days - spc_days)
  epidur_invalid <- !is.na(epidur_raw) && is.na(epidur)
  scalars <- list(
    Age = hrg_scalar(row, "STARTAGE"), SEX = hrg_scalar(row, "SEX"),
    ADMISORC = hrg_scalar(row, "ADMISORC"), ADMIMETH = hrg_scalar(row, "ADMIMETH"),
    DISDEST = hrg_scalar(row, "DISDEST"), DISMETH = hrg_scalar(row, "DISMETH"),
    MAINSPEF = hrg_scalar(row, "MAINSPEF"), TRETSPEF = hrg_scalar(row, "TRETSPEF"),
    NEOCARE = hrg_scalar(row, "NEOCARE"), FIRSTATT = hrg_scalar(row, "FIRSTATT"),
    CLASSPAT = hrg_scalar(row, "CLASSPAT"), EPIDUR = hrg_scalar(row, "EPIDUR"),
    RenalSite = hrg_scalar(row, "RENALSITE"), RenalAccess = hrg_scalar(row, "RENALACCESS"),
    RenalBBV = toupper(c(hrg_scalar(row, "HBV"), hrg_scalar(row, "HCV"), hrg_scalar(row, "HIV")))
  )
  if (is.na(scalars$Age)) scalars$Age <- hrg_scalar(row, "AGE")
  list(
    diag = diag, oper = oper, eff = hrg_form_combinations(oper, tbls),
    consumed = rep(FALSE, length(oper)), current = NA_integer_, dominant_pos = NA_integer_,
    pdriven = FALSE, scalars = scalars, qualifiers = tbls$qualifiers,
    epidur_vec = as.character(c(calc_epidur, cc_days, rehab_days, spc_days)),
    calc_epidur = calc_epidur, epidur_invalid = epidur_invalid,
    cc_days = cc_days, rehab_days = rehab_days, spc_days = spc_days
  )
}

# ---------------------------------------------------------------------------
# Flag evaluation

hrg_item_vector <- function(ctx, data_item, fn) {
  switch(data_item,
    Diagnosis = ctx$diag,
    Procedure = {
      if (fn == "RelDataItemInList") {
        p <- ctx$current
        if (is.na(p)) character() else ctx$eff[hrg_qualifier_run(ctx$oper, p, ctx)]
      } else if (fn == "DataItemInList" && ctx$pdriven && !is.na(ctx$dominant_pos)) {
        v <- ctx$eff
        v[ctx$dominant_pos] <- NA_character_
        v
      } else {
        ctx$eff
      }
    },
    Age = ctx$scalars$Age,
    EpiDur = ctx$epidur_vec,
    {
      v <- ctx$scalars[[data_item]]
      if (is.null(v)) NA_character_ else v
    }
  )
}

hrg_eval_rule <- function(rule, ctx, tbls) {
  set <- tbls$list_sets[[rule$list_id]]
  if (is.null(set)) return(FALSE)
  v <- hrg_item_vector(ctx, rule$data_item, rule$fn)
  if (length(v) == 0) return(FALSE)
  hi <- min(rule$pos_max, length(v))
  if (rule$pos_min > hi) return(FALSE)
  v <- v[rule$pos_min:hi]
  v <- v[!is.na(v)]
  switch(rule$fn,
    DataItemInList = , AllDataItemInList = , RelDataItemInList = any(v %in% set),
    SumListValues = {
      vals <- tbls$list_values[[rule$list_id]]
      sum(vals[v[v %in% set]], na.rm = TRUE) >= rule$sum_min
    },
    SumDistinctValues = {
      vals <- tbls$list_values[[rule$list_id]]
      u <- unique(v)
      sum(vals[u[u %in% set]], na.rm = TRUE) >= rule$sum_min
    },
    FALSE
  )
}

hrg_eval_flag <- function(flag, ctx, tbls) {
  if (is.na(flag) || flag == "a") return(TRUE)
  rules <- tbls$rule_sets[[flag]]
  if (is.null(rules)) return(FALSE)
  for (i in seq_len(nrow(rules))) {
    if (!isTRUE(hrg_eval_rule(rules[i, ], ctx, tbls))) return(FALSE)
  }
  TRUE
}

# Last satisfied (HRG, flag) pair wins.
hrg_eval_pairs <- function(pairs, ctx, tbls) {
  if (is.null(pairs) || nrow(pairs) == 0) return(NA_character_)
  for (i in rev(seq_len(nrow(pairs)))) {
    if (hrg_eval_flag(pairs$flag[i], ctx, tbls)) return(pairs$hrg[i])
  }
  NA_character_
}

hrg_split <- function(root, ctx, tbls, pdriven = FALSE) {
  if (is.na(root) || root == "UZ99") return(NA_character_)
  ctx$pdriven <- pdriven
  hrg <- hrg_eval_pairs(tbls$split_by_root[[root]], ctx, tbls)
  if (is.na(hrg)) root else hrg
}

# ---------------------------------------------------------------------------
# Validation (field errors)

hrg_validate_episode <- function(row, ctx, tbls) {
  errs <- character()
  add <- function(type, code, msg) errs <<- c(errs, paste(type, ifelse(is.na(code), "", code), msg, sep = "|"))
  raw_diag <- hrg_norm_code(unlist(row[grep("^DIAG_[0-9]+$", names(row))]))
  names(raw_diag) <- grep("^DIAG_[0-9]+$", names(row), value = TRUE)
  if (is.na(raw_diag[1])) add("DIAG_01", NA, "Primary Diagnosis is blank")
  else if (!raw_diag[1] %in% tbls$icd_valid) add("DIAG_01", raw_diag[1], "Primary Diagnosis is invalid")
  for (k in seq_along(raw_diag)[-1]) {
    if (!is.na(raw_diag[k]) && !raw_diag[k] %in% tbls$icd_valid) add(names(raw_diag)[k], raw_diag[k], "Secondary Diagnosis is invalid")
  }
  raw_oper <- hrg_norm_code(unlist(row[grep("^OPER_[0-9]+$", names(row))]))
  names(raw_oper) <- grep("^OPER_[0-9]+$", names(row), value = TRUE)
  for (k in seq_along(raw_oper)) {
    if (!is.na(raw_oper[k]) && !raw_oper[k] %in% tbls$opcs_valid) add(names(raw_oper)[k], raw_oper[k], "Procedure is invalid")
  }
  for (f in hrg_apc_fields) {
    v <- ctx$scalars[[f]]
    valid <- tbls$field_valid[[f]]
    if (is.na(v)) add(f, NA, paste(hrg_field_labels[[f]], "is blank"))
    else if (!is.null(valid) && !v %in% valid) add(f, v, paste(hrg_field_labels[[f]], "is invalid"))
  }
  age <- ctx$scalars$Age
  if (is.na(age)) add("STARTAGE", NA, "Age is blank")
  else {
    a <- suppressWarnings(as.numeric(age))
    if (is.na(a) || !(a == 999 || (a >= 0 && a <= 130 && a == floor(a)))) add("STARTAGE", age, "Age is invalid")
  }
  if (is.na(ctx$scalars$EPIDUR)) add("EPIDUR", NA, "Episode Duration is blank")
  else if (ctx$epidur_invalid) add("EPIDUR", ctx$scalars$EPIDUR, "Episode Duration is invalid")
  errs
}

# ---------------------------------------------------------------------------
# Unbundled HRGs

hrg_unbundle <- function(ctx, tbls, dataset = "apc") {
  out <- list()
  errs <- character()
  by_position <- vector("list", length(ctx$eff))
  for (i in seq_along(ctx$eff)) {
    for (type in hrg_unbundled_types) {
      pairs <- tbls$c2g_by_key[[paste(type, "PROC", ctx$eff[i], sep = "|")]]
      if (is.null(pairs)) next
      ctx$current <- i
      root <- hrg_eval_pairs(pairs, ctx, tbls)
      if (is.na(root)) next
      ctx$consumed[i] <- TRUE
      if (grepl("^UZ0[56]$", root)) {
        errs <- c(errs, paste0("OPER_", sprintf("%02d", i), "|", ctx$oper[i], "|", hrg_uz_messages[[root]]))
        by_position[[i]] <- c(by_position[[i]], "UZ01Z")
      } else {
        hrg <- hrg_split(root, ctx, tbls)
        if (type == "Urehab" && grepl("^VC(0[4-9]|[1-4][0-9])", hrg)) {
          hrg <- paste0(hrg, "*", max(1, ctx$rehab_days))
        }
        by_position[[i]] <- c(by_position[[i]], hrg)
      }
    }
  }
  ctx$current <- NA_integer_
  # Field-driven unbundled HRGs.
  tfc <- ctx$scalars$TRETSPEF
  transport <- NULL
  spc <- character()
  if (dataset == "nac") {
    if (!is.na(tfc) && tfc == "315") {
      root <- hrg_eval_pairs(tbls$c2g_by_key[["USPC2|TRETSPEF|315"]], ctx, tbls)
      if (!is.na(root) && root != "UZ99") spc <- c(spc, hrg_split(root, ctx, tbls))
    }
  }
  if (dataset == "apc" && !is.na(tfc) && tfc %in% c("242", "422")) {
    pairs <- tbls$c2g_by_key[[paste("UNPCC", "TRETSPEF", tfc, sep = "|")]]
    root <- hrg_eval_pairs(pairs, ctx, tbls)
    if (!is.na(root)) transport <- hrg_split(root, ctx, tbls)
  }
  if (dataset == "apc" && !is.na(tfc) && tfc == "315") {
    pairs <- tbls$c2g_by_key[[paste("USPC1", "TRETSPEF", "315", sep = "|")]]
    root <- hrg_eval_pairs(pairs, ctx, tbls)
    if (!is.na(root) && root != "UZ99") {
      hrg <- hrg_split(root, ctx, tbls)
      spc <- c(spc, paste0(hrg, "*", if (grepl("^SD01", hrg)) max(1, ctx$spc_days) else 1))
    }
  }
  if (dataset == "apc") {
    pairs <- tbls$c2g_by_key[[paste("USPC3", "N/A", "N/A", sep = "|")]]
    root <- hrg_eval_pairs(pairs, ctx, tbls)
    if (!is.na(root) && root != "UZ99") {
      spc <- c(spc, paste0(hrg_split(root, ctx, tbls), "*1"))
    }
  }
  hrgs <- character()
  for (i in seq_along(by_position)) {
    hrgs <- c(hrgs, by_position[[i]])
    if (i == 1 && !is.null(transport)) hrgs <- c(hrgs, transport)
  }
  if (length(by_position) == 0 && !is.null(transport)) hrgs <- c(hrgs, transport)
  hrgs <- c(hrgs, spc)
  list(hrgs = hrgs, consumed = ctx$consumed, errors = errs)
}

# ---------------------------------------------------------------------------
# Dominant procedure and core grouping

hrg_dominant <- function(ctx, tbls) {
  n <- length(ctx$eff)
  if (n == 0) return(NA_integer_)
  is_q <- ctx$oper %in% tbls$qualifiers
  # A qualifier code preceded by any real code belongs to that code.
  attached <- is_q & (cumsum(!is_q) > 0)
  cand <- which(!ctx$consumed & !attached)
  if (length(cand) == 0) return(NA_integer_)
  ph <- unname(tbls$proc_hier[ctx$eff[cand]])
  ph[is.na(ph)] <- -1
  cand[which.max(ph)]
}

hrg_core_root <- function(ctx, tbls) {
  dom <- if (is.na(ctx$dominant_pos)) NA_character_ else ctx$eff[ctx$dominant_pos]
  primary <- if (length(ctx$diag) > 0) ctx$diag[1] else NA_character_
  # Burns (Core 7)
  root <- hrg_eval_pairs(tbls$c2g_by_key[["Core7|N/A|N/A"]], ctx, tbls)
  if (!is.na(root)) return(list(root = root, method = "B"))
  # Multiple trauma (Core 4)
  if (!is.na(primary)) {
    root <- hrg_eval_pairs(tbls$c2g_by_key[[paste("Core4", "ICD", primary, sep = "|")]], ctx, tbls)
    if (!is.na(root)) {
      if (!is.na(dom)) {
        r2 <- hrg_eval_pairs(tbls$c2g_by_key[[paste("Core4", "PROC", dom, sep = "|")]], ctx, tbls)
        if (!is.na(r2)) root <- r2
      }
      return(list(root = root, method = "M"))
    }
  }
  # Procedure-driven (Core 1)
  if (!is.na(dom)) {
    pairs <- tbls$c2g_by_key[[paste("Core1", "PROC", dom, sep = "|")]]
    if (!is.null(pairs)) {
      ctx$pdriven <- TRUE
      root <- hrg_eval_pairs(pairs, ctx, tbls)
      ctx$pdriven <- FALSE
      if (!is.na(root)) return(list(root = root, method = "P"))
    }
  }
  # Global exceptions (Core 5)
  root <- hrg_eval_pairs(tbls$c2g_by_key[["Core5|N/A|N/A"]], ctx, tbls)
  if (!is.na(root)) return(list(root = root, method = "G"))
  # Diagnosis-driven (Core 1)
  if (!is.na(primary)) {
    root <- hrg_eval_pairs(tbls$c2g_by_key[[paste("Core1", "ICD", primary, sep = "|")]], ctx, tbls)
    if (!is.na(root)) return(list(root = root, method = "D"))
  }
  list(root = NA_character_, method = NA_character_)
}

hrg_group_episode <- function(row, tbls) {
  ctx <- hrg_episode_context(row, tbls)
  errs <- hrg_validate_episode(row, ctx, tbls)
  ub <- hrg_unbundle(ctx, tbls)
  ctx$consumed <- ub$consumed
  errs <- c(errs, ub$errors)
  ctx$dominant_pos <- hrg_dominant(ctx, tbls)
  # Subsidiary-code flags (RelDataItemInList) read the dominant's qualifier run
  # from here on.
  ctx$current <- ctx$dominant_pos
  dominant <- if (is.na(ctx$dominant_pos)) NA_character_ else ctx$eff[ctx$dominant_pos]

  core <- hrg_core_root(ctx, tbls)
  root <- core$root
  method <- core$method
  if (!is.na(root)) {
    esc <- hrg_eval_pairs(tbls$c2g_by_key[[paste("Core3", "HRG6", root, sep = "|")]], ctx, tbls)
    if (!is.na(esc)) root <- esc
  }
  hrg <- NA_character_
  if (!is.na(root)) {
    if (grepl("^UZ", root)) {
      hrg <- "UZ01Z"
      method <- "U"
      if (root %in% names(hrg_uz_messages)) {
        field <- if (root %in% c("UZ05", "UZ06")) sprintf("OPER_%02d|%s", ctx$dominant_pos, ctx$oper[ctx$dominant_pos]) else paste0("DIAG_01|", ctx$diag[1])
        errs <- c(errs, paste0(field, "|", hrg_uz_messages[[root]]))
      }
    } else {
      hrg <- hrg_split(root, ctx, tbls, pdriven = identical(method, "P"))
    }
  }
  if (length(errs) > 0 || any(ub$hrgs == "UZ01Z")) {
    hrg <- "UZ01Z"
    method <- "U"
  }
  primary <- if (length(ctx$diag) > 0) ctx$diag[1] else NA_character_
  pbc <- if (is.na(primary)) NA_character_ else hrg_eval_pairs(tbls$pbc_by_code[[primary]], ctx, tbls)
  if (is.na(pbc)) pbc <- "PBC02U1"

  list(
    hrg = hrg, method = method, dominant = dominant, root = root, pbc = pbc,
    calc_epidur = ctx$calc_epidur, cc_days = ctx$cc_days, unbundled = ub$hrgs, errors = errs,
    diag = ctx$diag, oper = ctx$oper, dominant_ph = if (is.na(dominant)) NA_real_ else unname(tbls$proc_hier[dominant]),
    primary_dh = if (is.na(primary)) NA_real_ else unname(tbls$diag_hier[primary])
  )
}

# ---------------------------------------------------------------------------
# Spells

hrg_group_spell <- function(rows, results, tbls) {
  n <- length(results)
  dom_ph <- vapply(results, function(r) if (is.na(r$dominant_ph)) -Inf else r$dominant_ph, numeric(1))
  has_dom <- vapply(results, function(r) !is.na(r$dominant), logical(1))
  if (any(has_dom)) {
    d <- which(has_dom)[which.max(dom_ph[has_dom])]
  } else {
    dh <- vapply(results, function(r) if (is.na(r$primary_dh)) -Inf else r$primary_dh, numeric(1))
    d <- which.max(dh)
  }
  pseudo <- as.list(rows[d, ])
  last <- as.list(rows[n, ])
  pseudo$DISDEST <- last$DISDEST
  pseudo$DISMETH <- last$DISMETH
  spell_los <- sum(vapply(results, function(r) r$calc_epidur, numeric(1)))
  pseudo$EPIDUR <- as.character(spell_los)
  pseudo$CRITICALCAREDAYS <- "0"
  pseudo$REHABILITATIONDAYS <- "0"
  pseudo$SPCDAYS <- "0"
  diags <- unique(c(results[[d]]$diag, unlist(lapply(results[-d], function(r) r$diag))))
  opers <- c(results[[d]]$oper, unlist(lapply(results[-d], function(r) r$oper)))
  pseudo <- pseudo[!grepl("^(DIAG|OPER)_[0-9]+$", names(pseudo))]
  for (i in seq_along(diags)) pseudo[[sprintf("DIAG_%02d", i)]] <- diags[i]
  for (i in seq_along(opers)) pseudo[[sprintf("OPER_%02d", i)]] <- opers[i]
  res <- hrg_group_episode(pseudo, tbls)

  spell_errors <- character()
  for (f in c("SEX", "CLASSPAT", "ADMISORC", "ADMIMETH")) {
    vals <- unique(trimws(as.character(rows[[f]])))
    if (length(vals) > 1) spell_errors <- c(spell_errors, paste0(f, "||", hrg_field_labels[[f]], " is inconsistent in spell"))
  }
  ages <- suppressWarnings(as.numeric(rows$STARTAGE))
  if (n > 1 && all(!is.na(ages))) {
    if (any(diff(ages) < 0)) spell_errors <- c(spell_errors, "STARTAGE||Age falls in episodes in the spell")
    if (any(diff(ages) > 1)) spell_errors <- c(spell_errors, "STARTAGE||Age rises by more than expected in the spell")
  }
  episode_error <- any(vapply(results, function(r) identical(r$hrg, "UZ01Z"), logical(1)))
  hrg <- res$hrg
  method <- res$method
  if (length(spell_errors) > 0 || episode_error) {
    hrg <- "UZ01Z"
    method <- "U"
  }
  pd <- results[[d]]$diag
  list(
    dominant_episode = d, hrg = hrg, method = method, dominant = res$dominant,
    pdiag = if (length(pd) > 0) pd[1] else NA_character_,
    sdiag = if (length(pd) > 1) pd[2] else NA_character_,
    n_episodes = n, los = spell_los,
    cc_days = sum(vapply(results, function(r) r$cc_days, numeric(1))),
    pbc = res$pbc, unbundled = unlist(lapply(results, function(r) r$unbundled)),
    errors = spell_errors
  )
}

# ---------------------------------------------------------------------------

#' Group admitted-patient-care episodes and spells to HRG4+
#'
#' Implements the HRG4+ grouping logic published by NHS England for admitted
#' patient care: episode (FCE) HRGs, unbundled HRGs, programme budgeting
#' categories and spell HRGs.
#'
#' @param episodes Data frame in the HRG4+ APC input layout: `PROCODET`,
#'   `PROVSPNO`, `EPIORDER`, `STARTAGE`, `SEX`, `CLASSPAT`, `ADMISORC`,
#'   `ADMIMETH`, `DISDEST`, `DISMETH`, `EPIDUR`, `MAINSPEF`, `NEOCARE`,
#'   `TRETSPEF`, `DIAG_01`..., `OPER_01`..., `CRITICALCAREDAYS`,
#'   `REHABILITATIONDAYS`, `SPCDAYS`.
#' @param tables Tables from [hrg_tables()].
#' @return A list with two tibbles: `episodes` (one row per input episode, in
#'   input order, with `fce_hrg`, `grouping_method`, `dominant_procedure`,
#'   `fce_pbc`, `calc_epidur`, `unbundled_hrgs`, `quality` and the spell
#'   columns repeated) and `spells` (one row per spell).
#' @export
hrg_group_apc <- function(episodes, tables = hrg_tables()) {
  tbls <- hrg_tables(tables)
  episodes <- tibble::as_tibble(episodes)
  episodes <- dplyr::mutate(episodes, dplyr::across(dplyr::everything(), as.character))
  for (col in c("PROCODET", "PROVSPNO", "EPIORDER")) {
    if (!col %in% names(episodes)) episodes[[col]] <- if (col == "EPIORDER") "1" else "1"
  }
  episodes$.row <- seq_len(nrow(episodes))
  results <- lapply(seq_len(nrow(episodes)), function(i) hrg_group_episode(as.list(episodes[i, ]), tbls))

  spell_key <- paste(episodes$PROCODET, episodes$PROVSPNO, sep = "|")
  spell_ids <- unique(spell_key)
  spell_rows <- vector("list", length(spell_ids))
  spell_of_episode <- match(spell_key, spell_ids)
  for (s in seq_along(spell_ids)) {
    idx <- which(spell_of_episode == s)
    idx <- idx[order(suppressWarnings(as.numeric(episodes$EPIORDER[idx])), idx)]
    sp <- hrg_group_spell(episodes[idx, ], results[idx], tbls)
    sp$first_row <- idx[1]
    sp$dominant_row <- idx[sp$dominant_episode]
    sp$key <- spell_ids[s]
    spell_rows[[s]] <- sp
  }

  ep <- tibble::tibble(
    row = episodes$.row,
    fce_hrg = vapply(results, function(r) r$hrg, character(1)),
    grouping_method = vapply(results, function(r) r$method, character(1)),
    dominant_procedure = vapply(results, function(r) r$dominant, character(1)),
    fce_pbc = vapply(results, function(r) r$pbc, character(1)),
    calc_epidur = vapply(results, function(r) r$calc_epidur, numeric(1)),
    unbundled_hrgs = vapply(results, function(r) paste(r$unbundled, collapse = ","), character(1)),
    quality = vapply(results, function(r) paste(r$errors, collapse = ";"), character(1))
  )
  sp_tbl <- tibble::tibble(
    spell = seq_along(spell_rows),
    procodet = episodes$PROCODET[vapply(spell_rows, function(s) s$first_row, integer(1))],
    provspno = episodes$PROVSPNO[vapply(spell_rows, function(s) s$first_row, integer(1))],
    spell_hrg = vapply(spell_rows, function(s) s$hrg, character(1)),
    spell_grouping_method = vapply(spell_rows, function(s) s$method, character(1)),
    spell_dominant_procedure = vapply(spell_rows, function(s) s$dominant, character(1)),
    spell_pdiag = vapply(spell_rows, function(s) s$pdiag, character(1)),
    spell_sdiag = vapply(spell_rows, function(s) s$sdiag, character(1)),
    spell_episode_count = vapply(spell_rows, function(s) s$n_episodes, integer(1)),
    spell_los = vapply(spell_rows, function(s) s$los, numeric(1)),
    spell_pbc = vapply(spell_rows, function(s) s$pbc, character(1)),
    spell_report_row = vapply(spell_rows, function(s) s$dominant_row, integer(1)),
    spell_unbundled_hrgs = vapply(spell_rows, function(s) paste(s$unbundled, collapse = ","), character(1)),
    spell_quality = vapply(spell_rows, function(s) paste(s$errors, collapse = ";"), character(1))
  )
  ep$spell <- spell_of_episode
  ep$spell_report_flag <- as.integer(ep$row == sp_tbl$spell_report_row[ep$spell])
  ep <- dplyr::left_join(ep, sp_tbl |> dplyr::select(-"spell_report_row", -"procodet", -"provspno"), by = "spell")
  list(episodes = ep, spells = sp_tbl)
}
