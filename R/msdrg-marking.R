# Marking: attach CMS attributes to the diagnosis and procedure codes of a claim.
#
# DXLIST maps a diagnosis code to a pattern number (plus its sex restriction
# and CC-exclusion group); DXPATERN gives the pattern's MDC, diagnosis
# category and HAC number, and the attribute operands. PRLIST / PRPATERN do
# the same for procedures. Everything below is a join.
#
# A code can appear more than once in DXLIST: sex-specific codes have one row
# per sex (different MDC), and codes on several HAC lists have one row per HAC
# number. Attributes are unioned across rows; the MDC comes from the row
# matching the claim's sex, falling back to the female row (with a
# sex-conflict flag) when the sex is unknown.

# Diagnoses with their resolved pattern facts. Unknown codes keep NA pattern.
# `sex` is a tibble (claim_id, sex).
msdrg_mark_dx <- function(diagnoses, tbls, sex) {
  rows <- diagnoses |>
    dplyr::left_join(tbls$dx_codes, by = "code", relationship = "many-to-many") |>
    dplyr::left_join(tbls$dx_patterns, by = "pattern") |>
    dplyr::left_join(sex, by = "claim_id")

  rows |>
    dplyr::group_by(.data$claim_id, .data$seq) |>
    dplyr::mutate(
      gendered = any(!is.na(.data$gender) & .data$gender != 0L),
      priority = dplyr::case_when(
        !.data$gendered ~ 0L,
        .data$gender == .data$sex ~ 0L,
        .data$gender == 2L ~ 1L,
        TRUE ~ 2L
      ),
      sex_conflict = .data$gendered & !any(.data$gender == .data$sex),
      hac_list = list(sort(unique(.data$hac[!is.na(.data$hac) & .data$hac > 0L])))
    ) |>
    dplyr::arrange(.data$claim_id, .data$seq, .data$priority, .data$pattern) |>
    dplyr::slice(1) |>
    dplyr::ungroup() |>
    dplyr::select(-"priority", -"gendered", -"sex")
}

# Long table: one row per (claim_id, seq, attribute) for diagnoses, unioned
# over every DXLIST row of the code.
msdrg_dx_attrs <- function(diagnoses, tbls) {
  diagnoses |>
    dplyr::select("claim_id", "seq", "code") |>
    dplyr::inner_join(tbls$dx_codes |> dplyr::select("code", "pattern"), by = "code", relationship = "many-to-many") |>
    dplyr::inner_join(tbls$dx_pattern_attrs, by = "pattern", relationship = "many-to-many") |>
    dplyr::distinct(.data$claim_id, .data$seq, .data$attribute)
}

# Procedures with their pattern. Unknown codes keep NA pattern.
msdrg_mark_pr <- function(procedures, tbls) {
  procedures |>
    dplyr::left_join(tbls$pr_codes, by = "code")
}

# Long table: one row per (claim_id, seq, attribute) for procedures.
msdrg_pr_attrs <- function(marked_pr, tbls) {
  marked_pr |>
    dplyr::filter(!is.na(.data$pattern)) |>
    dplyr::select("claim_id", "seq", "pattern") |>
    dplyr::inner_join(tbls$pr_pattern_attrs, by = "pattern", relationship = "many-to-many") |>
    dplyr::select(-"pattern")
}
