# HRG4+ paediatric (PCC) and neonatal (NCC) critical care: one HRG per
# critical-care day from the flowcharts NHS England publishes in the Chapter
# Summaries (transcribed in data-raw/hrg/ and bundled with the tables).

hrg_pad2 <- function(x) {
  x <- trimws(as.character(x))
  x[!is.na(x) & grepl("^[0-9]$", x)] <- paste0("0", x[!is.na(x) & grepl("^[0-9]$", x)])
  x
}

hrg_codes_of <- function(row, prefix) {
  v <- trimws(as.character(unlist(row[grep(paste0("^", prefix, "_[0-9]+$"), names(row))])))
  v <- v[!is.na(v) & v != ""]
  unname(v)
}

# Stable sort by provider, local id and date (all as text); blank ids first.
hrg_cc_order <- function(df) {
  order(dplyr::coalesce(df$PROCODET, ""), dplyr::coalesce(df$CCLocalID, ""), dplyr::coalesce(df$CCDate, ""), seq_len(nrow(df)))
}

# ---------------------------------------------------------------------------
# Paediatric critical care

hrg_pcc_day <- function(row, state, tbls) {
  codes <- hrg_pad2(hrg_codes_of(row, "CCAC"))
  oper <- hrg_norm_code(hrg_codes_of(row, "OPER"))
  diag <- hrg_norm_code(hrg_codes_of(row, "DIAG"))
  errs <- character()
  ccuf <- hrg_pad2(hrg_scalar(row, "CCUF"))
  if (is.na(ccuf)) errs <- c(errs, "CCUF||Critical Care Unit Function is blank")
  else if (!ccuf %in% c("04", "16", "17", "18", "19", "92")) errs <- c(errs, paste0("CCUF|", ccuf, "|Critical Care Unit Function is invalid"))
  for (k in seq_along(codes)) {
    if (!codes[k] %in% tbls$field_valid[["CCAC"]]) errs <- c(errs, sprintf("CCAC_%02d|%s|Critical Care Activity Code is invalid", k, codes[k]))
  }
  if (is.na(hrg_scalar(row, "CCDate"))) errs <- c(errs, "CCDate||Critical Care Date is blank")
  else if (is.na(hrg_parse_date(row$CCDate))) errs <- c(errs, paste0("CCDate|", row$CCDate, "|Critical Care Date is invalid"))
  if (is.na(hrg_scalar(row, "DISDATE"))) errs <- c(errs, "DISDATE||Discharge Date is blank")
  else if (is.na(hrg_parse_date(row$DISDATE))) errs <- c(errs, paste0("DISDATE|", row$DISDATE, "|Discharge Date is invalid"))
  dismeth <- hrg_scalar(row, "DISMETH")
  if (is.na(dismeth)) errs <- c(errs, "DISMETH||Discharge Method is blank")
  else if (!dismeth %in% tbls$field_valid[["DISMETH"]]) errs <- c(errs, paste0("DISMETH|", dismeth, "|Discharge Method is invalid"))
  raw_diag <- hrg_norm_code(hrg_codes_of(row, "DIAG"))
  for (k in seq_along(raw_diag)) {
    if (!raw_diag[k] %in% tbls$icd_valid) errs <- c(errs, sprintf("DIAG_%02d|%s|%s Diagnosis is invalid", k, raw_diag[k], if (k == 1) "Primary" else "Secondary"))
  }

  has <- function(...) any(c(...) %in% codes)
  dg <- function(...) any(c(...) %in% diag)
  vent <- has("51", "52", "56")
  isol <- has("74") && hrg_pcc_isolated(diag, tbls)
  burn80 <- dg("T318", "T319", "T328", "T329")
  burn50 <- dg("T315", "T316", "T317", "T325", "T326", "T327")
  burn20 <- dg("T312", "T313", "T314", "T322", "T323", "T324")
  gasdrug <- any(c("X841", "X842") %in% oper)
  aki <- dg("N170", "N171", "N172", "N178", "N179", "N990")

  hrg <- if (length(errs) > 0) {
    "UZ01Z"
  } else if (has("65") && has("05", "16", "51", "52", "56", "66")) {
    "XB01Z"
  } else if (vent && burn80) {
    "XB02Z"
  } else if (vent && has("63")) {
    "XB02Z"
  } else if (vent && (burn50 || gasdrug || has("04", "05", "16", "66", "67", "72"))) {
    if (isol) "XB02Z" else "XB03Z"
  } else if (has("51", "52") && burn20) {
    if (isol) "XB03Z" else "XB04Z"
  } else if ((has("51", "52") && has("06", "64", "68", "71")) || has("56")) {
    if (isol) "XB03Z" else "XB04Z"
  } else if (has("51") || (has("52") && has("60", "62", "85", "96")) ||
             (has("53") && has("04", "05", "06", "16", "60", "62", "63", "64", "66", "67", "68", "71", "72", "85", "96"))) {
    if (isol) "XB04Z" else "XB05Z"
  } else if ((has("53") && gasdrug) || (has("53") && (burn20 || burn50 || burn80)) || (has("65") && has("06", "53"))) {
    if (isol) "XB04Z" else "XB05Z"
  } else if (has("65")) {
    "XB06Z"
  } else if (has("04", "06", "55", "60", "61", "62", "63", "64", "67", "69", "71", "72", "85", "97")) {
    "XB06Z"
  } else if (has("05", "16", "66") && aki) {
    "XB06Z"
  } else if (has("13") && state$prev13 < 8) {
    "XB06Z"
  } else if (has("52") && state$run52 < 91) {
    "XB06Z"
  } else if (has("53") && state$run53 < 91) {
    "XB06Z"
  } else if (has("52", "53", "57", "58", "59", "70", "94", "95")) {
    "XB07Z"
  } else if (has("09", "80") && has("50") && has("73")) {
    "XB07Z"
  } else {
    "XB09Z"
  }

  if ("13" %in% codes) state$prev13 <- state$prev13 + 1
  state$run52 <- if ("52" %in% codes && hrg == "XB06Z") state$run52 + 1 else 0
  state$run53 <- if ("53" %in% codes && hrg == "XB06Z") state$run53 + 1 else 0
  state$ccuf <- ccuf
  list(hrg = hrg, errors = errs, state = state)
}

# XB_Isolation membership; a few entries are code pairs (both required) and
# one uses a fifth-character wildcard.
hrg_pcc_isolated <- function(diag, tbls) {
  entries <- tbls$pcc_isolation
  for (e in entries) {
    parts <- strsplit(e, "+", fixed = TRUE)[[1]]
    ok <- vapply(parts, function(p) {
      if (endsWith(p, "*")) any(startsWith(diag, sub("\\*$", "", p))) else p %in% diag
    }, logical(1))
    if (all(ok)) return(TRUE)
  }
  FALSE
}

#' Group paediatric critical care days to HRG4+
#'
#' One HRG per critical-care day, following the Subchapter XB flowchart.
#' Days are sorted by `PROCODET`, `CCLocalID` and `CCDate`; the per-period
#' history that steps 25-27 need is accumulated along the way and reset when
#' the unit function changes.
#'
#' @param days Data frame in the PCC layout (`PROCODET`, `CCLocalID`,
#'   `CCDate`, `DISDATE`, `DISMETH`, `CCUF`, `CCAC_01`..., `OPER_01`...,
#'   `DIAG_01`...).
#' @param tables Tables from [hrg_tables()].
#' @return A tibble in input order with `pcc_hrg`, `sorted_row` and `quality`.
#' @export
hrg_group_pcc <- function(days, tables = hrg_tables()) {
  tbls <- hrg_tables(tables)
  days <- dplyr::mutate(tibble::as_tibble(days), dplyr::across(dplyr::everything(), as.character))
  for (col in c("PROCODET", "CCLocalID", "CCDate")) if (!col %in% names(days)) days[[col]] <- ""
  ord <- hrg_cc_order(days)
  hrg <- character(nrow(days))
  quality <- character(nrow(days))
  states <- list()
  for (i in ord) {
    row <- as.list(days[i, ])
    key <- paste(dplyr::coalesce(row$PROCODET, ""), dplyr::coalesce(row$CCLocalID, ""), sep = "|")
    st <- states[[key]] %||% list(prev13 = 0, run52 = 0, run53 = 0, ccuf = NA_character_)
    ccuf <- hrg_pad2(hrg_scalar(row, "CCUF"))
    if (!is.na(st$ccuf) && !identical(st$ccuf, ccuf)) st <- list(prev13 = 0, run52 = 0, run53 = 0, ccuf = ccuf)
    res <- hrg_pcc_day(row, st, tbls)
    states[[key]] <- res$state
    hrg[i] <- res$hrg
    quality[i] <- paste(res$errors, collapse = ";")
  }
  tibble::tibble(row = seq_len(nrow(days)), pcc_hrg = hrg, sorted_row = match(seq_len(nrow(days)), ord), quality = quality)
}

# ---------------------------------------------------------------------------
# Neonatal critical care

#' Group neonatal critical care days to HRG4+
#'
#' One HRG per critical-care day, following the Subchapter XA flowchart.
#'
#' @param days Data frame in the NCC layout (`PROCODET`, `CCLocalID`,
#'   `CCDate`, `DISDATE`, `CCUF`, `AGE_DAYS`, `DISMETH`, `GestLen`, `PERWT`,
#'   `CCAC_01`...).
#' @param tables Tables from [hrg_tables()].
#' @return A tibble in input order with `ncc_hrg`, `sorted_row` and `quality`.
#' @export
hrg_group_ncc <- function(days, tables = hrg_tables()) {
  tbls <- hrg_tables(tables)
  days <- dplyr::mutate(tibble::as_tibble(days), dplyr::across(dplyr::everything(), as.character))
  for (col in c("PROCODET", "CCLocalID", "CCDate")) if (!col %in% names(days)) days[[col]] <- ""
  ord <- hrg_cc_order(days)
  rows <- lapply(seq_len(nrow(days)), function(i) hrg_ncc_day(as.list(days[i, ]), tbls))
  tibble::tibble(
    row = seq_len(nrow(days)),
    ncc_hrg = vapply(rows, function(r) r$hrg, character(1)),
    sorted_row = match(seq_len(nrow(days)), ord),
    quality = vapply(rows, function(r) paste(r$errors, collapse = ";"), character(1))
  )
}

hrg_ncc_day <- function(row, tbls) {
  codes <- hrg_pad2(hrg_codes_of(row, "CCAC"))
  errs <- character()
  ccuf <- hrg_pad2(hrg_scalar(row, "CCUF"))
  if (is.na(ccuf)) errs <- c(errs, "CCUF||Critical Care Unit Function is blank")
  else if (!ccuf %in% c("13", "14", "15")) errs <- c(errs, paste0("CCUF|", ccuf, "|Critical Care Unit Function is invalid"))
  age_raw <- hrg_scalar(row, "AGE_DAYS")
  age <- suppressWarnings(as.numeric(age_raw))
  if (is.na(age_raw)) errs <- c(errs, "AGE_DAYS||Age in days is blank")
  else if (is.na(age) || age < 0 || age > 999 || age != floor(age)) errs <- c(errs, paste0("AGE_DAYS|", age_raw, "|Age in days is invalid"))
  dismeth <- hrg_scalar(row, "DISMETH")
  if (is.na(dismeth)) errs <- c(errs, "DISMETH||Discharge Method is blank")
  else if (!dismeth %in% tbls$field_valid[["DISMETH"]]) errs <- c(errs, paste0("DISMETH|", dismeth, "|Discharge Method is invalid"))
  gl_raw <- hrg_scalar(row, "GestLen")
  gl <- suppressWarnings(as.numeric(gl_raw))
  if (is.na(gl_raw)) errs <- c(errs, "GestLen||Gestation Length is blank")
  else if (is.na(gl) || gl < 10 || gl > 49 || gl != floor(gl)) errs <- c(errs, paste0("GestLen|", gl_raw, "|Gestation Length is invalid"))
  wt_raw <- hrg_scalar(row, "PERWT")
  wt <- suppressWarnings(as.numeric(wt_raw))
  if (is.na(wt_raw)) errs <- c(errs, "PERWT||Person Weight is blank")
  else if (is.na(wt) || wt <= 0 || wt >= 10) errs <- c(errs, paste0("PERWT|", wt_raw, "|Person Weight is invalid"))
  if (is.na(hrg_scalar(row, "DISDATE"))) errs <- c(errs, "DISDATE||Discharge Date is blank")
  else if (is.na(hrg_parse_date(row$DISDATE))) errs <- c(errs, paste0("DISDATE|", row$DISDATE, "|Discharge Date is invalid"))
  if (is.na(hrg_scalar(row, "CCDate"))) errs <- c(errs, "CCDate||Critical Care Date is blank")
  else if (is.na(hrg_parse_date(row$CCDate))) errs <- c(errs, paste0("CCDate|", row$CCDate, "|Critical Care Date is invalid"))
  for (k in seq_along(codes)) {
    if (!codes[k] %in% tbls$field_valid[["CCAC"]]) errs <- c(errs, sprintf("CCAC_%02d|%s|Critical Care Activity Code is invalid", k, codes[k]))
  }
  if (length(errs) > 0) return(list(hrg = "UZ01Z", errors = errs))

  has <- function(...) any(c(...) %in% codes)
  special <- function() if (has("21")) "XA04Z" else "XA03Z"
  hrg <- if (identical(hrg_scalar(row, "CCDate"), hrg_scalar(row, "DISDATE")) && identical(dismeth, "4")) {
    "XA01Z"
  } else if (has("07") && has("02", "53", "80")) {
    "XA01Z"
  } else if (has("03") && ccuf == "13") {
    "XA01Z"
  } else if (has("01", "04", "05", "06", "11", "12", "16", "51", "66", "69", "81", "82", "83", "84", "85", "86")) {
    "XA01Z"
  } else if (has("02", "07", "08", "13", "14", "53", "55", "80", "87", "88", "90", "91", "92")) {
    "XA02Z"
  } else if ((age <= 2 && wt <= 2) || (age <= 2 && gl == 35) || (age <= 7 && gl == 34) || gl < 34 ||
             (has("10") && has("28")) || has("09", "23", "24", "29", "89", "93")) {
    special()
  } else if (has("26")) {
    "XA05Z"
  } else if (ccuf == "13" && has("10", "15", "21", "22", "25", "27", "28", "99")) {
    "XA05Z"
  } else {
    errs <- c(errs, paste0("CCAC_01|", if (length(codes) > 0) codes[1] else "", "|UZ11 - Neonatal Critical Care Error"))
    "UZ01Z"
  }
  list(hrg = hrg, errors = errs)
}
