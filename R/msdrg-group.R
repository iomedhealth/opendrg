#' Assign MS-DRGs to claims
#'
#' Re-implements the CMS MS-DRG grouper: codes are marked with CMS attributes,
#' secondary diagnoses are screened for CC/MCC exclusions, and the DRGLOGIC
#' formulas are evaluated in order (pre-MDC rows first, then the principal
#' diagnosis' MDC, with reroutes to the multiple-trauma, HIV and
#' unrelated-OR-procedure MDCs). The grouper runs twice: an *initial* pass with
#' every secondary diagnosis, and a *final* pass in which secondary diagnoses
#' that meet hospital-acquired-condition (HAC) criteria no longer count towards
#' severity.
#'
#' @param claims Data frame with one row per claim: `claim_id`, `sex`
#'   (0 unknown, 1 male, 2 female; `"M"`/`"F"` accepted), `discharge_status`
#'   (two-character UB-04 code), and optionally `age`.
#' @param diagnoses Data frame with one row per diagnosis: `claim_id`, `seq`
#'   (1 = principal diagnosis), `code` (ICD-10-CM, dots optional), and
#'   optionally `poa` (present-on-admission indicator).
#' @param procedures Optional data frame with one row per procedure:
#'   `claim_id`, `seq`, `code` (ICD-10-PCS).
#' @param tables Logic tables from [msdrg_tables()] or [msdrg_import_cms()].
#' @param poa_exempt Hospital's POA-reporting status: `"unknown"` (default,
#'   as in the CMS software), `"non_exempt"` or `"exempt"`.
#' @return A tibble with one row per claim: `drg` (final), `initial_drg`,
#'   `base_drg`, `mdc`, `med_surg`, `severity`, `initial_severity`,
#'   `return_code`, `drg_description`, `mdc_description` and `formula` (the
#'   matched DRGLOGIC formula).
#' @export
msdrg_group <- function(claims, diagnoses, procedures = NULL, tables = msdrg_tables(),
                        poa_exempt = c("unknown", "non_exempt", "exempt")) {
  tbls <- msdrg_tables(tables)
  poa_exempt <- rlang::arg_match(poa_exempt)
  inp <- msdrg_prepare_input(claims, diagnoses, procedures)
  ctx <- msdrg_build_context(inp, tbls)

  initial <- msdrg_run_pass(ctx, tbls, hac_met = NULL)
  hac <- msdrg_hac_pass(ctx, tbls, initial, poa_exempt)
  final <- msdrg_run_pass(ctx, tbls, hac_met = hac$hac_met, skip = hac$ungroupable)

  msdrg_assemble_output(ctx, tbls, initial, final, hac$ungroupable)
}

# ---------------------------------------------------------------------------
# Context: everything the passes need, computed once per claim set.

msdrg_valid_discharge_status <- c(1:7, 20, 21, 30, 43, 50, 51, 61:66, 69, 70, 81:95)
msdrg_xfrnba_status <- c(2, 5, 66, 82, 85, 94)
msdrg_trauma_sites <- c("sthead", "stchest", "stabdom", "stkidney", "sturin", "stpel", "stuplimb", "stlolimb")
msdrg_bilateral_joints <- c("righthip", "rightknee", "rightankle", "lefthip", "leftknee", "leftankle")

msdrg_build_context <- function(inp, tbls) {
  claims <- inp$claims

  # --- diagnoses -----------------------------------------------------------
  dx <- msdrg_mark_dx(inp$diagnoses, tbls, claims |> dplyr::select("claim_id", "sex")) |>
    dplyr::left_join(tbls$dx_pattern_severity, by = "pattern") |>
    dplyr::mutate(
      valid = !is.na(.data$pattern),
      severity = dplyr::coalesce(.data$severity, "NCC")
    )
  dx_attr <- msdrg_dx_attrs(inp$diagnoses, tbls)

  pdx <- dx |>
    dplyr::filter(.data$seq == 1L) |>
    dplyr::select("claim_id", pdx_code = "code", pdx_pattern = "pattern", pdx_mdc = "mdc",
                  pdx_sex_conflict = "sex_conflict", pdx_exclusion_group = "exclusion_group",
                  pdx_valid = "valid")
  claims <- claims |>
    dplyr::left_join(pdx, by = "claim_id") |>
    dplyr::mutate(
      pdx_valid = dplyr::coalesce(.data$pdx_valid, FALSE),
      pdx_sex_conflict = dplyr::coalesce(.data$pdx_sex_conflict, FALSE)
    )

  # Secondary diagnoses in CMS "clinical significance" order (MCC, CC, then
  # the rest; ties by code) with exclusion flags.
  sdx <- dx |>
    dplyr::filter(.data$seq > 1L) |>
    dplyr::left_join(claims |> dplyr::select("claim_id", "discharge_status", "pdx_exclusion_group"), by = "claim_id") |>
    dplyr::left_join(tbls$exclusions |> dplyr::mutate(excluded = TRUE),
                     by = c("pdx_exclusion_group" = "exclusion_group", "code")) |>
    dplyr::mutate(excluded = dplyr::coalesce(.data$excluded, FALSE))
  mccalive <- dx_attr |>
    dplyr::filter(.data$attribute == "mccalive") |>
    dplyr::distinct(.data$claim_id, .data$seq) |>
    dplyr::mutate(has_mccalive = TRUE)
  sdx <- sdx |>
    dplyr::left_join(mccalive, by = c("claim_id", "seq")) |>
    dplyr::mutate(
      has_mccalive = dplyr::coalesce(.data$has_mccalive, FALSE),
      death_excl = .data$has_mccalive & !is.na(.data$discharge_status) & .data$discharge_status == "20",
      level = match(.data$severity, c("MCC", "CC"), nomatch = 3L)
    ) |>
    dplyr::arrange(.data$claim_id, .data$level, .data$code) |>
    dplyr::group_by(.data$claim_id) |>
    dplyr::mutate(order = dplyr::row_number()) |>
    dplyr::ungroup() |>
    dplyr::select("claim_id", "seq", "order", "code", "poa", "pattern", "hac_list", "valid",
                  "severity", "level", "excluded", "death_excl", "has_mccalive")

  # --- procedures ----------------------------------------------------------
  pr <- msdrg_mark_pr(inp$procedures, tbls) |>
    dplyr::mutate(valid = !is.na(.data$pattern)) |>
    dplyr::arrange(.data$claim_id, .data$code) |>
    dplyr::group_by(.data$claim_id) |>
    dplyr::mutate(order = dplyr::row_number()) |>
    dplyr::ungroup()
  pr_attr <- msdrg_pr_attrs(pr, tbls)

  # Clusters: a cluster fires when the claim covers every one of its choice
  # slots; it then contributes a virtual procedure code (e.g. "@2250") whose
  # attributes come from PRLIST, and its component codes' own attributes are
  # hidden while grouping in the cluster's restricted MDCs.
  fired <- pr |>
    dplyr::select("claim_id", "code") |>
    dplyr::inner_join(tbls$clusters |> dplyr::select("proc_code", "cluster_code", "choice"),
                      by = c("code" = "proc_code"), relationship = "many-to-many") |>
    dplyr::group_by(.data$claim_id, .data$cluster_code) |>
    dplyr::summarise(n_covered = dplyr::n_distinct(.data$choice), codes = list(unique(.data$code)), .groups = "drop") |>
    dplyr::inner_join(tbls$cluster_defs, by = "cluster_code") |>
    dplyr::filter(.data$n_covered == .data$n_choices)
  cluster_attr <- fired |>
    dplyr::select("claim_id", code = "cluster_code") |>
    dplyr::inner_join(tbls$pr_codes, by = "code") |>
    dplyr::inner_join(tbls$pr_pattern_attrs, by = "pattern", relationship = "many-to-many") |>
    dplyr::transmute(.data$claim_id, seq = NA_integer_, .data$attribute)
  # Component suppression. CMS XORs the restriction bitsets of every fired
  # cluster a code belongs to, so an MDC restricted an even number of times is
  # not suppressed.
  suppression <- fired |>
    dplyr::select("claim_id", "codes", "suppress_mdcs") |>
    tidyr::unnest("codes") |>
    tidyr::unnest("suppress_mdcs") |>
    dplyr::count(.data$claim_id, code = .data$codes, mdc = .data$suppress_mdcs) |>
    dplyr::filter(.data$n %% 2 == 1) |>
    dplyr::select(-"n")

  # ORPROC is implied by the unrelated-OR attributes d468 / d477.
  orproc <- dplyr::bind_rows(pr_attr, cluster_attr) |>
    dplyr::filter(.data$attribute %in% c("d468", "d477")) |>
    dplyr::distinct(.data$claim_id, .data$seq) |>
    dplyr::mutate(attribute = "ORPROC")
  pr_attr_all <- dplyr::bind_rows(pr_attr, cluster_attr, orproc) |>
    dplyr::distinct()
  pr_attr_all <- pr_attr_all |>
    dplyr::left_join(pr |> dplyr::select("claim_id", "seq", "code"), by = c("claim_id", "seq")) |>
    dplyr::left_join(suppression |> dplyr::group_by(.data$claim_id, .data$code) |>
                       dplyr::summarise(suppress = list(.data$mdc), .groups = "drop"),
                     by = c("claim_id", "code")) |>
    dplyr::select("claim_id", "seq", "attribute", "suppress")

  # --- claim-level flags consumed by the computed specials ------------------
  flags <- msdrg_claim_flags(claims, sdx, dx_attr, pr, pr_attr)

  list(claims = claims, dx = dx, dx_attr = dx_attr, sdx = sdx, pr = pr,
       pr_attr = pr_attr_all, flags = flags)
}

# Count how many distinct attributes of `set` a claim accumulates when each
# code, in order, contributes the first attribute of `set` (in `set` order)
# that has not been seen yet. Mirrors CMS's SignificantTrauma/BilateralNode.
msdrg_greedy_distinct <- function(long, set) {
  long <- long |>
    dplyr::filter(.data$attribute %in% set) |>
    dplyr::mutate(rank = match(.data$attribute, set)) |>
    dplyr::arrange(.data$claim_id, .data$order, .data$rank)
  if (nrow(long) == 0) {
    return(tibble::tibble(claim_id = long$claim_id[0], n_found = integer()))
  }
  by_claim <- vctrs::vec_split(long[c("order", "rank")], long$claim_id)
  n_found <- vapply(by_claim$val, function(df) {
    found <- integer()
    for (item in split(df$rank, df$order)) {
      candidate <- item[!item %in% found]
      if (length(candidate) > 0) found <- c(found, candidate[[1]])
      if (length(found) == 2) break
    }
    length(found)
  }, integer(1))
  tibble::tibble(claim_id = by_claim$key, n_found = n_found)
}

msdrg_claim_flags <- function(claims, sdx, dx_attr, pr, pr_attr) {
  status <- suppressWarnings(as.integer(claims$discharge_status))
  valid_status <- !is.na(status) & status %in% msdrg_valid_discharge_status

  dx_order <- dplyr::bind_rows(
    claims |> dplyr::filter(.data$pdx_valid) |> dplyr::transmute(.data$claim_id, seq = 1L, order = 0L),
    sdx |> dplyr::select("claim_id", "seq", "order")
  )
  trauma <- dx_attr |>
    dplyr::inner_join(dx_order, by = c("claim_id", "seq")) |>
    msdrg_greedy_distinct(msdrg_trauma_sites)
  bilateral <- pr_attr |>
    dplyr::inner_join(pr |> dplyr::select("claim_id", "seq", "order"), by = c("claim_id", "seq")) |>
    msdrg_greedy_distinct(msdrg_bilateral_joints)

  pr_count <- function(attrs, weights = NULL) {
    counts <- pr_attr |>
      dplyr::filter(.data$attribute %in% attrs) |>
      dplyr::distinct(.data$claim_id, .data$seq, .data$attribute)
    if (!is.null(weights)) {
      counts$w <- weights[match(counts$attribute, attrs)]
    } else {
      counts$w <- 1L
    }
    counts |>
      dplyr::group_by(.data$claim_id) |>
      dplyr::summarise(n = sum(.data$w), n_attrs = dplyr::n_distinct(.data$attribute), .groups = "drop")
  }
  lookup <- function(tbl, col, default = 0L) {
    v <- tbl[[col]][match(claims$claim_id, tbl$claim_id)]
    dplyr::coalesce(v, default)
  }
  fusion <- pr_count(c("sglantfuse", "sglpostfuse"))
  ant <- pr_count("sglantfuse")
  post1 <- pr_count("sglpostfuse1")
  multfuse <- pr_count(c("sglantfuse", "sglpostfuse1"))
  antsectx <- pr_count("sglantsectXfuse")
  post <- pr_count("sglpostfuse")
  vessels <- pr_count(paste0("vessel", 1:4), weights = 1:4)
  stents <- pr_count(paste0("stent", 1:4), weights = 1:4)

  tibble::tibble(
    claim_id = claims$claim_id,
    sp__INVALID_PDX = !claims$pdx_valid,
    sp__PDX_ECODE = !is.na(claims$pdx_code) & grepl("^[VWXY]", claims$pdx_code),
    sp__INVALID_SEX = claims$sex == 0L & claims$pdx_sex_conflict,
    sp__INVALID_DSTAT = !valid_status,
    sp__ALIVE = is.na(status) | status != 20L,
    sp__DIED = !is.na(status) & status == 20L,
    sp__AMA = !is.na(status) & status == 7L,
    sp__XFRNBA = !is.na(status) & status %in% msdrg_xfrnba_status,
    sp__MDC_20_FALL_THRU = dplyr::coalesce(claims$pdx_mdc, -1L) == 20L,
    sp__MULTST = lookup(trauma, "n_found") >= 2L,
    sp__BILATERAL = lookup(bilateral, "n_found") >= 2L,
    sp__SINGLEFUSIONCTR = lookup(fusion, "n_attrs") == 2L & lookup(fusion, "n") > 2L,
    sp__SGLANTCTR = lookup(ant, "n") > 1L,
    sp__SGLPOST1CTR = lookup(post1, "n") > 1L,
    sp__MULTFUSE = lookup(multfuse, "n") > 1L,
    sp__SGLANTSECTXCTR = lookup(antsectx, "n") > 1L,
    sp__SGLPOSTFUSECTR = lookup(post, "n") > 1L,
    sp__FOUR_VESSELS = lookup(vessels, "n") >= 4L,
    sp__FOUR_STENTS = lookup(stents, "n") >= 4L
  )
}

# ---------------------------------------------------------------------------
# Severity per claim for each suppression set, honouring exclusions, death
# exclusions and (final pass) HAC-met codes.

msdrg_severity_columns <- function(ctx, tbls, claim_ids, supp_ids, hac_met) {
  sdx <- ctx$sdx |>
    dplyr::filter(.data$claim_id %in% claim_ids, !.data$excluded, !.data$death_excl)
  if (!is.null(hac_met) && nrow(hac_met) > 0) {
    sdx <- sdx |> dplyr::anti_join(hac_met, by = c("claim_id", "seq"))
  }
  out <- tibble::tibble(claim_id = claim_ids)
  for (id in supp_ids) {
    attrs <- tbls$suppression_sets$attributes[[id]]
    eligible <- sdx
    if (length(attrs) > 0) {
      suppressed <- ctx$dx_attr |>
        dplyr::filter(.data$attribute %in% attrs) |>
        dplyr::distinct(.data$claim_id, .data$seq)
      eligible <- eligible |> dplyr::anti_join(suppressed, by = c("claim_id", "seq"))
    }
    level <- rep(3L, length(claim_ids))
    if (nrow(eligible) > 0) {
      best <- eligible |>
        dplyr::group_by(.data$claim_id) |>
        dplyr::summarise(level = min(.data$level), .groups = "drop")
      level <- dplyr::coalesce(best$level[match(claim_ids, best$claim_id)], 3L)
    }
    out[[paste0("sev__", id)]] <- c("MCC", "CC", "NCC")[level]
  }
  out
}

# ---------------------------------------------------------------------------
# Evaluate one MDC's rows for a set of claims.

msdrg_evaluate_mdc <- function(ctx, tbls, claim_ids, mdc, sev_all) {
  rows <- tbls$logic_by_mdc[[as.character(mdc)]]
  empty <- tibble::tibble(claim_id = claim_ids, row = NA_integer_)
  if (is.null(rows) || length(claim_ids) == 0) {
    return(empty)
  }
  terms <- tbls$terms_by_mdc[[as.character(mdc)]]
  dx_attr <- ctx$dx_attr |> dplyr::filter(.data$claim_id %in% claim_ids)
  pr_attr <- ctx$pr_attr |>
    dplyr::filter(.data$claim_id %in% claim_ids) |>
    dplyr::filter(!vapply(.data$suppress, function(s) mdc %in% s, logical(1)))

  wide <- tibble::tibble(claim_id = claim_ids) |>
    dplyr::left_join(msdrg_wide_dx(claim_ids, dx_attr, terms, ctx), by = "claim_id") |>
    dplyr::left_join(msdrg_wide_pr(claim_ids, pr_attr, terms, exclude = msdrg_specials), by = "claim_id") |>
    dplyr::left_join(ctx$flags, by = "claim_id") |>
    dplyr::left_join(sev_all, by = "claim_id")

  tibble::tibble(claim_id = claim_ids, row = msdrg_first_match(wide, rows))
}

# ---------------------------------------------------------------------------
# One full grouping pass (initial or final).

msdrg_run_pass <- function(ctx, tbls, hac_met = NULL, skip = NULL) {
  logic <- tbls$drg_logic
  claims <- ctx$claims |> dplyr::select("claim_id", "pdx_mdc")
  if (!is.null(skip) && nrow(skip) > 0) {
    claims <- claims |> dplyr::filter(!.data$claim_id %in% skip$claim_id)
  }
  n <- nrow(claims)
  state <- tibble::tibble(
    claim_id = claims$claim_id, pdx_mdc = claims$pdx_mdc,
    done = FALSE, row = NA_integer_, return_code = 0L,
    stops = replicate(n, 0L, simplify = FALSE), severity = NA_character_
  )
  sev_all <- msdrg_severity_columns(ctx, tbls, state$claim_id, tbls$suppression_sets$supp_id, hac_met)

  evaluate <- function(ids, mdcs) {
    out <- vector("list", 0)
    for (m in unique(mdcs)) {
      sel <- ids[mdcs == m]
      out[[length(out) + 1]] <- msdrg_evaluate_mdc(ctx, tbls, sel, m, sev_all)
    }
    dplyr::bind_rows(out)
  }
  apply_match <- function(state, matched) {
    i <- match(matched$claim_id, state$claim_id)
    state$row[i] <- matched$row
    rc <- logic$return_code[matched$row]
    rc[is.na(rc)] <- 0L
    state$return_code[i] <- rc
    state
  }
  row_drg <- function(row) ifelse(is.na(row), 0L, logic$drg[row])
  row_reroute <- function(row) ifelse(is.na(row), 0L, logic$reroute_mdc[row])

  # Stage 1: pre-MDC rows for everyone.
  state <- apply_match(state, evaluate(state$claim_id, rep(0L, n)))
  state$done <- state$return_code != 0L | row_drg(state$row) > 0L

  # Stage 2: reroutes requested by a pre-MDC row (24, 25, 11), up to two hops.
  state <- msdrg_follow_reroutes(state, evaluate, apply_match, logic)

  # Stage 3: principal-diagnosis MDC for claims still open.
  open <- !state$done & !is.na(state$pdx_mdc) & state$pdx_mdc > 0L
  if (any(open)) {
    ids <- state$claim_id[open]
    state <- apply_match(state, evaluate(ids, state$pdx_mdc[open]))
    i <- match(ids, state$claim_id)
    state$stops[i] <- Map(c, state$stops[i], state$pdx_mdc[open])
    state$done[i] <- state$return_code[i] != 0L | row_drg(state$row[i]) > 0L
    # Stage 4: reroutes requested by an MDC row (29), up to two hops.
    state <- msdrg_follow_reroutes(state, evaluate, apply_match, logic)
  }

  # Severity reported with the result is the one computed for the matched row.
  sev_mat <- as.matrix(sev_all[-1])
  supp <- logic$supp_id[state$row]
  has_row <- !is.na(state$row)
  state$severity[has_row] <- sev_mat[cbind(match(state$claim_id[has_row], sev_all$claim_id), supp[has_row])]
  state
}

# Claims whose current match row requests a reroute are evaluated in the
# target MDC; a reroute row there may request one further hop.
msdrg_follow_reroutes <- function(state, evaluate, apply_match, logic) {
  for (hop in 1:2) {
    pending <- !state$done & !is.na(state$row) & logic$reroute_mdc[state$row] != 0L
    if (!any(pending)) break
    ids <- state$claim_id[pending]
    target <- logic$reroute_mdc[state$row[pending]]
    i <- match(ids, state$claim_id)
    if (hop == 1) state$stops[i] <- Map(c, state$stops[i], target)
    state <- apply_match(state, evaluate(ids, target))
    drg <- ifelse(is.na(state$row[i]), 0L, logic$drg[state$row[i]])
    state$done[i] <- state$return_code[i] != 0L | drg > 0L
  }
  state
}

# ---------------------------------------------------------------------------
# Hospital-acquired conditions. Every secondary diagnosis on a HAC list whose
# POA indicator is not Y/W and which is not CC-excluded is tested against its
# HAC's criteria formula on the claim mask. Met codes are dropped from
# severity in the final pass; invalid POA reporting on met HACs makes the
# claim ungroupable (return codes 9, 10, 11, 15) depending on the hospital's
# POA-reporting status.

msdrg_hac_pass <- function(ctx, tbls, initial, poa_exempt) {
  no_hac <- list(hac_met = ctx$sdx[0, c("claim_id", "seq")],
                 ungroupable = tibble::tibble(claim_id = ctx$claims$claim_id[0], return_code = integer()))
  if (is.null(tbls$hac_formulas) || poa_exempt == "exempt") {
    return(no_hac)
  }
  sdx_hac <- ctx$sdx |>
    dplyr::select("claim_id", "seq", "order", "code", "poa", "excluded", "hac_list") |>
    tidyr::unnest("hac_list") |>
    dplyr::rename(hac = "hac_list")
  # Claims already ungroupable keep that result; CMS stops before HACs.
  failed <- initial$claim_id[initial$return_code != 0L]
  sdx_hac <- sdx_hac |> dplyr::filter(!.data$claim_id %in% failed)
  if (nrow(sdx_hac) == 0) {
    return(no_hac)
  }

  # Criteria formulas on the claim mask (no cluster suppression here).
  ids <- unique(sdx_hac$claim_id)
  terms <- tbls$hac_terms
  dx_attr <- ctx$dx_attr |> dplyr::filter(.data$claim_id %in% ids)
  pr_attr <- ctx$pr_attr |> dplyr::filter(.data$claim_id %in% ids)
  wide <- tibble::tibble(claim_id = ids) |>
    dplyr::left_join(msdrg_wide_dx(ids, dx_attr, terms, ctx), by = "claim_id") |>
    dplyr::left_join(msdrg_wide_pr(ids, pr_attr, terms, exclude = msdrg_specials), by = "claim_id") |>
    dplyr::left_join(ctx$flags, by = "claim_id")
  hits <- purrr::map2_dfr(tbls$hac_formulas$hac_number, tbls$hac_formulas$expr, function(h, expr) {
    tibble::tibble(claim_id = ids, hac = h, hit = dplyr::coalesce(rlang::eval_tidy(expr, data = wide), FALSE))
  })

  show <- dx_attr |>
    dplyr::filter(.data$attribute == "hac06_show") |>
    dplyr::distinct(.data$claim_id, .data$seq) |>
    dplyr::mutate(show = TRUE)
  st <- sdx_hac |>
    dplyr::left_join(hits, by = c("claim_id", "hac")) |>
    dplyr::left_join(show, by = c("claim_id", "seq")) |>
    dplyr::mutate(
      show = dplyr::coalesce(.data$show, FALSE),
      hit = dplyr::coalesce(.data$hit, FALSE),
      poa_yw = !is.na(.data$poa) & .data$poa %in% c("Y", "W"),
      poa_invalid = is.na(.data$poa) | !.data$poa %in% c("Y", "W", "N", "U"),
      evaluated = !.data$poa_yw & !.data$excluded,
      met = .data$evaluated & .data$hit
    ) |>
    dplyr::group_by(.data$claim_id) |>
    dplyr::mutate(
      hac6_anchor = any(.data$met & .data$hac == 6L & !.data$show),
      # UTI "show" codes only count when a catheter-infection code is itself met.
      met = .data$met & !(.data$hac == 6L & .data$show & !.data$hac6_anchor),
      invalid_poa_on_claim = any(.data$evaluated & .data$poa_invalid),
      any_met = any(.data$met)
    ) |>
    dplyr::ungroup()

  met_claims <- st |> dplyr::filter(.data$any_met)
  ungroupable <- no_hac$ungroupable
  if (poa_exempt == "non_exempt") {
    by_hac <- met_claims |>
      dplyr::filter(.data$met) |>
      dplyr::group_by(.data$claim_id, .data$hac) |>
      dplyr::summarise(
        fail = if (dplyr::first(.data$hac) == 6L) {
          dplyr::first(.data$hac6_anchor) && any(.data$poa_invalid)
        } else {
          dplyr::first(.data$invalid_poa_on_claim)
        },
        .groups = "drop"
      ) |>
      dplyr::filter(.data$fail)
    ungroupable <- tibble::tibble(claim_id = unique(by_hac$claim_id), return_code = 9L)
  } else if (poa_exempt == "unknown") {
    n_sdx <- ctx$sdx |> dplyr::count(.data$claim_id, name = "n_sdx")
    first_hac_code <- met_claims |>
      dplyr::arrange(.data$claim_id, .data$order) |>
      dplyr::distinct(.data$claim_id, .keep_all = TRUE) |>
      dplyr::left_join(n_sdx, by = "claim_id") |>
      dplyr::mutate(return_code = dplyr::case_when(
        .data$n_sdx >= 2L ~ 15L,
        !is.na(.data$poa) & .data$poa %in% c("N", "U") ~ 10L,
        .data$poa_invalid ~ 11L,
        TRUE ~ 0L
      )) |>
      dplyr::filter(.data$return_code != 0L)
    ungroupable <- first_hac_code |> dplyr::select("claim_id", "return_code")
  }

  hac_met <- st |>
    dplyr::filter(.data$met) |>
    dplyr::distinct(.data$claim_id, .data$seq)
  list(hac_met = hac_met, ungroupable = ungroupable)
}

# ---------------------------------------------------------------------------

msdrg_assemble_output <- function(ctx, tbls, initial, final, hac_ungroupable) {
  logic <- tbls$drg_logic
  result_of <- function(state) {
    row <- state$row
    rc <- state$return_code
    drg <- ifelse(rc != 0L, 999L, ifelse(is.na(row), NA_integer_, logic$drg[row]))
    mdc <- vapply(seq_len(nrow(state)), function(k) {
      if (rc[k] != 0L || is.na(drg[k]) || drg[k] == 999L) return(0L)
      stops <- state$stops[[k]]
      last <- stops[length(stops)]
      if (last == 29L) {
        if (24L %in% stops) 24L else if (25L %in% stops) 25L else stops[length(stops) - 1]
      } else if (last != 0L) {
        last
      } else {
        dplyr::coalesce(state$pdx_mdc[k], 0L)
      }
    }, integer(1))
    no_match <- rc != 0L | is.na(row)
    tibble::tibble(
      claim_id = state$claim_id,
      drg = as.integer(drg),
      base_drg = dplyr::if_else(rc != 0L, 999L, logic$base_drg[row]),
      mdc = mdc,
      med_surg = dplyr::if_else(no_match, NA_character_, logic$med_surg[row]),
      severity = dplyr::if_else(no_match | drg == 998L, NA_character_, state$severity),
      return_code = as.integer(rc),
      formula = dplyr::if_else(is.na(row), NA_character_, logic$formula[row])
    )
  }
  fin <- result_of(final)
  ini <- result_of(initial)
  # Claims the HAC pass made ungroupable get DRG 999 with its return code.
  if (nrow(hac_ungroupable) > 0) {
    fin <- dplyr::bind_rows(fin, tibble::tibble(
      claim_id = hac_ungroupable$claim_id, drg = 999L, base_drg = 999L, mdc = 0L,
      med_surg = NA_character_, severity = NA_character_,
      return_code = hac_ungroupable$return_code, formula = NA_character_
    ))
  }
  ctx$claims |>
    dplyr::select("claim_id") |>
    dplyr::left_join(fin, by = "claim_id") |>
    dplyr::left_join(ini |> dplyr::select("claim_id", initial_drg = "drg", initial_severity = "severity"), by = "claim_id") |>
    dplyr::left_join(tbls$drg_desc |> dplyr::rename(drg_description = "description"), by = "drg") |>
    dplyr::left_join(tbls$mdc_desc |> dplyr::rename(mdc_description = "description"), by = "mdc") |>
    dplyr::select("claim_id", "drg", "initial_drg", "base_drg", "mdc", "med_surg", "severity",
                  "initial_severity", "return_code", "drg_description", "mdc_description", "formula")
}
