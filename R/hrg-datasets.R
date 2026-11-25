# HRG4+ grouping for the non-admitted datasets: outpatient attendances (NAC),
# emergency medicine (EM), adult critical care (ACC) and the national renal
# dataset (NRD). Paediatric and neonatal critical care are in hrg-critical.R.

hrg_field_labels_extra <- c(
  FIRSTATT = "First Attendance", AGE = "Age", AEPATIENTGROUP = "Patient Group",
  CCUF = "Critical Care Unit Function", RENALMOD = "Renal Modality", RENALSITE = "Renal Site",
  RENALACCESS = "Renal Access", HBV = "HBV", HCV = "HCV", HIV = "HIV"
)

hrg_valid_age <- function(v, allow_999 = TRUE) {
  a <- suppressWarnings(as.numeric(v))
  !is.na(a) && a == floor(a) && ((a >= 0 && a <= 130) || (allow_999 && a == 999))
}

# ---------------------------------------------------------------------------
# Non-admitted consultations (outpatients)

hrg_group_nac_row <- function(row, tbls) {
  row$EPIDUR <- "0"
  ctx <- hrg_episode_context(row, tbls)
  errs <- character()
  add <- function(type, code, msg) errs <<- c(errs, paste(type, ifelse(is.na(code), "", code), msg, sep = "|"))
  raw_oper <- hrg_norm_code(unlist(row[grep("^OPER_[0-9]+$", names(row))]))
  names(raw_oper) <- grep("^OPER_[0-9]+$", names(row), value = TRUE)
  for (k in seq_along(raw_oper)) {
    if (!is.na(raw_oper[k]) && !raw_oper[k] %in% tbls$opcs_valid) add(names(raw_oper)[k], raw_oper[k], "Procedure is invalid")
  }
  for (f in c("SEX", "MAINSPEF", "TRETSPEF", "FIRSTATT")) {
    v <- ctx$scalars[[f]]
    label <- if (f %in% names(hrg_field_labels)) hrg_field_labels[[f]] else hrg_field_labels_extra[[f]]
    if (is.na(v)) add(f, NA, paste(label, "is blank"))
    else if (!v %in% tbls$field_valid[[f]]) add(f, v, paste(label, "is invalid"))
  }
  if (is.na(ctx$scalars$Age)) add("STARTAGE", NA, "Age is blank")
  else if (!hrg_valid_age(ctx$scalars$Age)) add("STARTAGE", ctx$scalars$Age, "Age is invalid")

  ub <- hrg_unbundle(ctx, tbls, dataset = "nac")
  ctx$consumed <- ub$consumed
  errs <- c(errs, ub$errors)
  ctx$dominant_pos <- hrg_dominant(ctx, tbls)
  ctx$current <- ctx$dominant_pos
  dominant <- if (is.na(ctx$dominant_pos)) NA_character_ else ctx$eff[ctx$dominant_pos]

  root <- NA_character_
  method <- NA_character_
  # Procedure-driven: the dominant first, then the other candidates by hierarchy.
  n <- length(ctx$eff)
  if (n > 0) {
    is_q <- ctx$oper %in% tbls$qualifiers
    attached <- is_q & (cumsum(!is_q) > 0)
    cand <- which(!ctx$consumed & !attached)
    ph <- unname(tbls$proc_hier[ctx$eff[cand]])
    ph[is.na(ph)] <- -1
    cand <- cand[order(-ph, cand)]
    for (pos in cand) {
      pairs <- tbls$c2g_by_key[[paste("Core1", "PROC", ctx$eff[pos], sep = "|")]]
      if (is.null(pairs)) next
      ctx$pdriven <- TRUE
      ctx$current <- pos
      ctx$dominant_pos <- pos
      r <- hrg_eval_pairs(pairs, ctx, tbls)
      ctx$pdriven <- FALSE
      if (!is.na(r)) {
        root <- r
        method <- "P"
        break
      }
      if (!is.na(root)) break
    }
  }
  if (is.na(root)) {
    ctx$current <- NA_integer_
    r <- hrg_eval_pairs(tbls$c2g_by_key[["Core5|N/A|N/A"]], ctx, tbls)
    if (!is.na(r)) {
      root <- r
      method <- "G"
    }
  }
  if (is.na(root) && !is.na(ctx$scalars$MAINSPEF)) {
    r <- hrg_eval_pairs(tbls$c2g_by_key[[paste("Core6", "MAINSPEF", ctx$scalars$MAINSPEF, sep = "|")]], ctx, tbls)
    if (!is.na(r)) {
      root <- r
      method <- "O"
    }
  }
  hrg <- NA_character_
  if (!is.na(root)) {
    if (grepl("^UZ", root)) {
      hrg <- "UZ01Z"
      method <- "U"
      if (root %in% names(hrg_uz_messages)) {
        errs <- c(errs, sprintf("OPER_%02d|%s|%s", ctx$dominant_pos, ctx$oper[ctx$dominant_pos], hrg_uz_messages[[root]]))
      }
    } else {
      hrg <- hrg_split(root, ctx, tbls, pdriven = identical(method, "P"))
    }
  }
  if (length(errs) > 0 || any(ub$hrgs == "UZ01Z")) {
    hrg <- "UZ01Z"
    method <- "U"
  }
  list(hrg = hrg, method = method, dominant = dominant, unbundled = ub$hrgs, errors = errs)
}

#' Group outpatient attendances to HRG4+
#'
#' @param attendances Data frame in the HRG4+ non-admitted consultation layout:
#'   `STARTAGE`, `SEX`, `MAINSPEF`, `TRETSPEF`, `FIRSTATT`, `OPER_01`....
#' @param tables Tables from [hrg_tables()].
#' @return A tibble with `nac_hrg`, `grouping_method` (P/G/O/U),
#'   `dominant_procedure`, `unbundled_hrgs` and `quality` per attendance.
#' @export
hrg_group_nac <- function(attendances, tables = hrg_tables()) {
  tbls <- hrg_tables(tables)
  attendances <- dplyr::mutate(tibble::as_tibble(attendances), dplyr::across(dplyr::everything(), as.character))
  rows <- lapply(seq_len(nrow(attendances)), function(i) hrg_group_nac_row(as.list(attendances[i, ]), tbls))
  tibble::tibble(
    row = seq_along(rows),
    nac_hrg = vapply(rows, function(r) r$hrg, character(1)),
    grouping_method = vapply(rows, function(r) r$method, character(1)),
    dominant_procedure = vapply(rows, function(r) r$dominant, character(1)),
    unbundled_hrgs = vapply(rows, function(r) paste(r$unbundled, collapse = ","), character(1)),
    quality = vapply(rows, function(r) paste(r$errors, collapse = ";"), character(1))
  )
}

# ---------------------------------------------------------------------------
# Emergency medicine

#' Group emergency medicine attendances to HRG4+
#'
#' @param attendances Data frame with `AGE`, `AEPATIENTGROUP`, `INV_01`...,
#'   `TREAT_01`....
#' @param tables Tables from [hrg_tables()].
#' @return A tibble with `em_hrg`, `dominant_investigation`,
#'   `dominant_treatment` and `quality` per attendance.
#' @export
hrg_group_em <- function(attendances, tables = hrg_tables()) {
  tbls <- hrg_tables(tables)
  hier <- tbls$em_hierarchy
  if (is.null(hier)) cli::cli_abort("These tables carry no emergency-medicine hierarchy.")
  inv_h <- stats::setNames(hier$hierarchy[hier$kind == "investigation"], hier$code[hier$kind == "investigation"])
  tr_h <- stats::setNames(hier$hierarchy[hier$kind == "treatment"], hier$code[hier$kind == "treatment"])
  attendances <- dplyr::mutate(tibble::as_tibble(attendances), dplyr::across(dplyr::everything(), as.character))
  one <- function(row) {
    errs <- character()
    inv <- trimws(unlist(row[grep("^INV_[0-9]+$", names(row))]))
    inv <- inv[!is.na(inv) & inv != ""]
    tr <- trimws(unlist(row[grep("^TREAT_[0-9]+$", names(row))]))
    tr <- tr[!is.na(tr) & tr != ""]
    age <- hrg_scalar(row, "AGE")
    if (is.na(age)) errs <- c(errs, "AGE||Age is blank")
    else if (!hrg_valid_age(age, allow_999 = FALSE)) errs <- c(errs, paste0("AGE|", age, "|Age is invalid"))
    for (k in seq_along(inv)) if (!inv[k] %in% names(inv_h)) errs <- c(errs, sprintf("INV_%02d|%s|Investigation is invalid", k, inv[k]))
    for (k in seq_along(tr)) if (!tr[k] %in% names(tr_h)) errs <- c(errs, sprintf("TREAT_%02d|%s|Treatment is invalid", k, tr[k]))
    if (length(inv) == 0 && length(tr) == 0) errs <- c(errs, "INV_01||Investigation is blank", "TREAT_01||Treatment is blank")
    pick <- function(codes, h) {
      codes <- codes[codes %in% names(h)]
      if (length(codes) == 0) return(NA_character_)
      codes[which.max(h[codes])]
    }
    dom_inv <- pick(inv, inv_h)
    dom_tr <- pick(tr, tr_h)
    group <- hrg_scalar(row, "AEPATIENTGROUP")
    if (!is.na(group) && !group %in% tbls$field_valid[["AEPatGroup"]]) {
      errs <- c(errs, paste0("AEPATIENTGROUP|", group, "|Accident and Emergency Classification Code is invalid"))
    }
    root <- NA_character_
    if (!is.na(group) && !is.null(tbls$c2g_by_key[[paste("EM", "AEPatGroup", group, sep = "|")]])) {
      root <- tbls$c2g_by_key[[paste("EM", "AEPatGroup", group, sep = "|")]]$hrg[1]
    } else {
      key <- paste0(if (is.na(dom_inv)) "Blank INV" else paste("I", dom_inv), "+", if (is.na(dom_tr)) "Blank TRE" else paste("T", dom_tr))
      pairs <- tbls$c2g_by_key[[paste("EM", "PROC", key, sep = "|")]]
      if (!is.null(pairs)) root <- pairs$hrg[nrow(pairs)]
    }
    hrg <- if (is.na(root)) NA_character_ else {
      sp <- tbls$split_by_root[[root]]
      if (is.null(sp)) root else sp$hrg[1]
    }
    if (length(errs) > 0 || is.na(hrg)) hrg <- "UZ01Z"
    list(hrg = hrg, inv = dom_inv, tr = dom_tr, errors = errs)
  }
  rows <- lapply(seq_len(nrow(attendances)), function(i) one(as.list(attendances[i, ])))
  tibble::tibble(
    row = seq_along(rows),
    em_hrg = vapply(rows, function(r) r$hrg, character(1)),
    dominant_investigation = vapply(rows, function(r) r$inv, character(1)),
    dominant_treatment = vapply(rows, function(r) r$tr, character(1)),
    quality = vapply(rows, function(r) paste(r$errors, collapse = ";"), character(1))
  )
}

# ---------------------------------------------------------------------------
# Adult critical care

hrg_parse_date <- function(x) {
  x <- trimws(as.character(x))
  if (is.na(x) || !grepl("^[0-9]{8}$", x)) return(NA)
  d <- as.Date(x, format = "%Y%m%d")
  if (is.na(d)) NA else d
}

#' Group adult critical care periods to HRG4+
#'
#' @param periods Data frame with `CCUF`, the organ-support day counts
#'   `BCSD`, `ACSD`, `BRSD`, `ARSD`, `RSD`, `NSD`, `DSD`, `LSD`, the level
#'   day counts `CCL2D`, `CCL3D` and `CC_Start_Date`, `CC_Discharge_Date`
#'   (`YYYYMMDD`).
#' @param tables Tables from [hrg_tables()].
#' @return A tibble with `acc_hrg`, `organs`, `calc_cc_days`,
#'   `cc_warning_flag` and `quality` per period.
#' @export
hrg_group_acc <- function(periods, tables = hrg_tables()) {
  tbls <- hrg_tables(tables)
  periods <- dplyr::mutate(tibble::as_tibble(periods), dplyr::across(dplyr::everything(), as.character))
  days_cols <- c("BCSD", "ACSD", "BRSD", "ARSD", "RSD", "NSD", "DSD", "LSD", "CCL2D", "CCL3D")
  one <- function(row) {
    errs <- character()
    ccuf <- hrg_scalar(row, "CCUF")
    if (is.na(ccuf)) errs <- c(errs, "CCUF||Critical Care Unit Function is blank")
    else if (!ccuf %in% tbls$field_valid[["ACC_CCUF"]]) errs <- c(errs, paste0("CCUF|", ccuf, "|Critical Care Unit Function is invalid"))
    d <- list()
    for (col in days_cols) {
      v <- hrg_scalar(row, col)
      n <- suppressWarnings(as.numeric(v))
      if (is.na(v)) n <- 0
      if (is.na(n) || n < 0 || n != floor(n)) {
        errs <- c(errs, paste0(col, "|", v, "|", col, " is invalid"))
        n <- 0
      }
      d[[col]] <- n
    }
    start <- hrg_parse_date(row$CC_Start_Date)
    end <- hrg_parse_date(row$CC_Discharge_Date)
    calc_days <- if (is.na(start) || is.na(end) || end < start) -1 else as.numeric(end - start) + 1
    organs <- (d$ARSD > 0) + (d$BRSD > 0) + (d$ACSD > 0) + (d$BCSD > 0 && d$BRSD == 0 && d$ACSD == 0) +
      (d$RSD > 0) + (d$NSD > 0) + (d$DSD > 0) + (d$LSD > 0)
    hrg <- c("XC07Z", "XC06Z", "XC05Z", "XC04Z", "XC03Z", "XC02Z", "XC01Z")[min(organs, 6) + 1]
    if (organs == 0 && d$CCL2D + d$CCL3D == 0) {
      errs <- c(errs, "CCUF||UZ13 - ACC grouping error")
      hrg <- "UZ01Z"
    }
    if (length(errs) > 0) hrg <- "UZ01Z"
    warn <- calc_days < 0 || d$CCL2D + d$CCL3D > calc_days || d$ARSD + d$BRSD > calc_days || d$ARSD + d$BRSD > d$CCL2D + d$CCL3D
    list(hrg = hrg, organs = organs, calc_days = calc_days, warn = if (warn) "F" else "", errors = errs)
  }
  rows <- lapply(seq_len(nrow(periods)), function(i) one(as.list(periods[i, ])))
  tibble::tibble(
    row = seq_along(rows),
    acc_hrg = vapply(rows, function(r) r$hrg, character(1)),
    organs = vapply(rows, function(r) as.integer(r$organs), integer(1)),
    calc_cc_days = vapply(rows, function(r) r$calc_days, numeric(1)),
    cc_warning_flag = vapply(rows, function(r) r$warn, character(1)),
    quality = vapply(rows, function(r) paste(r$errors, collapse = ";"), character(1))
  )
}

# ---------------------------------------------------------------------------
# National renal dataset

#' Group renal dialysis records (National Renal Dataset) to HRG4+
#'
#' @param records Data frame with `RENALMOD`, `RENALSITE`, `RENALACCESS`,
#'   `HBV`, `HCV`, `HIV` and `AGE`.
#' @param tables Tables from [hrg_tables()].
#' @return A tibble with `nrd_hrg` and `quality` per record.
#' @export
hrg_group_nrd <- function(records, tables = hrg_tables()) {
  tbls <- hrg_tables(tables)
  records <- dplyr::mutate(tibble::as_tibble(records), dplyr::across(dplyr::everything(), as.character))
  valid_mod <- sprintf("%02d", 1:15)
  one <- function(row) {
    errs <- character()
    ctx <- hrg_episode_context(row, tbls)
    mod <- hrg_scalar(row, "RENALMOD")
    if (is.na(mod)) errs <- c(errs, "RENALMOD||Renal Modality is blank")
    else if (!mod %in% valid_mod) errs <- c(errs, paste0("RENALMOD|", mod, "|Renal Modality is invalid"))
    site <- ctx$scalars$RenalSite
    if (is.na(site)) errs <- c(errs, "RENALSITE||Renal Site is blank")
    else if (!site %in% tbls$field_valid[["RenalSite"]]) errs <- c(errs, paste0("RENALSITE|", site, "|Renal Site is invalid"))
    access <- ctx$scalars$RenalAccess
    if (!is.na(access) && !access %in% tbls$field_valid[["RenalAccess"]]) errs <- c(errs, paste0("RENALACCESS|", access, "|Renal Access is invalid"))
    for (k in seq_along(c("HBV", "HCV", "HIV"))) {
      f <- c("HBV", "HCV", "HIV")[k]
      v <- ctx$scalars$RenalBBV[k]
      if (!is.na(v) && !v %in% c("POS", "NEG", "UNK")) errs <- c(errs, paste0(f, "|", v, "|", f, " is invalid"))
    }
    if (is.na(ctx$scalars$Age)) errs <- c(errs, "AGE||Age is blank")
    else if (!hrg_valid_age(ctx$scalars$Age, allow_999 = FALSE)) errs <- c(errs, paste0("AGE|", ctx$scalars$Age, "|Age is invalid"))
    hrg <- NA_character_
    if (!is.na(mod)) {
      root <- hrg_eval_pairs(tbls$c2g_by_key[[paste("Renal", "RenalMod", mod, sep = "|")]], ctx, tbls)
      if (!is.na(root)) {
        if (grepl("^UZ", root)) {
          errs <- c(errs, paste0("RENALMOD|", mod, "|UZ14 - Renal (NRD) Error"))
          hrg <- "UZ01Z"
        } else {
          hrg <- hrg_split(root, ctx, tbls)
        }
      }
    }
    if (length(errs) > 0 || is.na(hrg)) hrg <- "UZ01Z"
    list(hrg = hrg, errors = errs)
  }
  rows <- lapply(seq_len(nrow(records)), function(i) one(as.list(records[i, ])))
  tibble::tibble(
    row = seq_along(rows),
    nrd_hrg = vapply(rows, function(r) r$hrg, character(1)),
    quality = vapply(rows, function(r) paste(r$errors, collapse = ";"), character(1))
  )
}
