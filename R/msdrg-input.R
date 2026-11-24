# Input contract for MS-DRG grouping.
#
# Claims are supplied as three long-format data frames so that they map
# directly onto database tables and onto the CMS API's claim object:
#
#   claims:     claim_id, age, sex, discharge_status
#   diagnoses:  claim_id, seq, code, poa      (seq 1 = principal diagnosis)
#   procedures: claim_id, seq, code
#
# Codes are ICD-10-CM / ICD-10-PCS without dots. Sex uses the CMS convention
# (0 unknown, 1 male, 2 female; "M"/"F"/"U" are accepted). Discharge status is
# the two-character UB-04 patient discharge status code ("01", "20", ...).

msdrg_poa_values <- c("Y", "N", "U", "W", "1", "0")

#' Normalize an ICD-10 code for lookup
#'
#' Upper-cases, strips dots and whitespace. `NA` and empty strings stay `NA`.
#' @param x Character vector of codes.
#' @return Character vector.
#' @export
#' @examples
#' msdrg_normalize_code(c("i21.01", " E11.9 ", "0SRC0J9", NA, ""))
msdrg_normalize_code <- function(x) {
  x <- toupper(gsub("[.[:space:]]", "", as.character(x)))
  x[!is.na(x) & x == ""] <- NA_character_
  x
}

msdrg_normalize_sex <- function(x) {
  if (is.numeric(x)) {
    out <- as.integer(x)
  } else {
    key <- toupper(trimws(as.character(x)))
    out <- dplyr::case_when(
      key %in% c("1", "M", "MALE") ~ 1L,
      key %in% c("2", "F", "FEMALE") ~ 2L,
      key %in% c("0", "U", "UNKNOWN", "") | is.na(key) ~ 0L,
      TRUE ~ NA_integer_
    )
  }
  out[is.na(out)] <- 0L
  out
}

msdrg_normalize_discharge_status <- function(x) {
  key <- trimws(as.character(x))
  key <- ifelse(!is.na(key) & grepl("^[0-9]$", key), paste0("0", key), key)
  key[is.na(key) | key == ""] <- NA_character_
  key
}

require_columns <- function(df, cols, what) {
  missing <- setdiff(cols, names(df))
  if (length(missing) > 0) {
    cli::cli_abort("{.arg {what}} is missing required column{?s} {.field {missing}}.")
  }
  invisible(df)
}

# Validate and normalize the three input tables. Returns a list of tibbles.
msdrg_prepare_input <- function(claims, diagnoses, procedures = NULL) {
  require_columns(claims, c("claim_id", "age", "sex", "discharge_status"), "claims")
  require_columns(diagnoses, c("claim_id", "seq", "code"), "diagnoses")
  if (!is.null(procedures)) {
    require_columns(procedures, c("claim_id", "seq", "code"), "procedures")
  }
  if (vctrs::vec_duplicate_any(claims$claim_id)) {
    cli::cli_abort("{.field claim_id} must be unique in {.arg claims}.")
  }

  claims <- tibble::as_tibble(claims) |>
    dplyr::transmute(
      claim_id = .data$claim_id,
      age = as.integer(.data$age),
      sex = msdrg_normalize_sex(.data$sex),
      discharge_status = msdrg_normalize_discharge_status(.data$discharge_status)
    )

  diagnoses <- tibble::as_tibble(diagnoses) |>
    dplyr::transmute(
      claim_id = .data$claim_id,
      seq = as.integer(.data$seq),
      code = msdrg_normalize_code(.data$code),
      poa = if ("poa" %in% names(diagnoses)) toupper(trimws(as.character(.data$poa))) else NA_character_
    ) |>
    dplyr::filter(!is.na(.data$code))
  diagnoses$poa[!is.na(diagnoses$poa) & !diagnoses$poa %in% msdrg_poa_values] <- NA_character_

  unknown_dx_claims <- setdiff(unique(diagnoses$claim_id), claims$claim_id)
  if (length(unknown_dx_claims) > 0) {
    cli::cli_abort("{.arg diagnoses} refers to {length(unknown_dx_claims)} claim_id{?s} absent from {.arg claims}.")
  }
  if (vctrs::vec_duplicate_any(diagnoses[c("claim_id", "seq")])) {
    cli::cli_abort("{.arg diagnoses} has duplicate (claim_id, seq) pairs.")
  }

  procedures <- if (is.null(procedures)) {
    tibble::tibble(claim_id = claims$claim_id[0], seq = integer(), code = character())
  } else {
    tibble::as_tibble(procedures) |>
      dplyr::transmute(
        claim_id = .data$claim_id,
        seq = as.integer(.data$seq),
        code = msdrg_normalize_code(.data$code)
      ) |>
      dplyr::filter(!is.na(.data$code))
  }
  unknown_pr_claims <- setdiff(unique(procedures$claim_id), claims$claim_id)
  if (length(unknown_pr_claims) > 0) {
    cli::cli_abort("{.arg procedures} refers to {length(unknown_pr_claims)} claim_id{?s} absent from {.arg claims}.")
  }

  list(claims = claims, diagnoses = diagnoses, procedures = procedures)
}
