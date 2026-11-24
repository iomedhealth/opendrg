# Extracted from test-msdrg-group.R:61

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "opengrd", path = "..")
attach(test_env, warn.conflicts = FALSE)

# prequel ----------------------------------------------------------------------
fixture <- readRDS(test_path("fixtures", "msdrg_v440_testdb.rds"))
group_fixture <- function(ids = NULL) {
  f <- fixture
  if (!is.null(ids)) {
    f$claims <- f$claims[f$claims$claim_id %in% ids, ]
    f$diagnoses <- f$diagnoses[f$diagnoses$claim_id %in% ids, ]
    f$procedures <- f$procedures[f$procedures$claim_id %in% ids, ]
    f$expected <- f$expected[f$expected$claim_id %in% ids, ]
  }
  got <- msdrg_group(f$claims, f$diagnoses, f$procedures,
                     tables = msdrg_tables(f$version), poa_exempt = "non_exempt")
  dplyr::inner_join(f$expected, got, by = "claim_id", suffix = c("_exp", ""))
}

# test -------------------------------------------------------------------------
f <- fixture
affected <- f$expected$claim_id[f$expected$initial_drg != f$expected$drg]
got <- msdrg_group(
    f$claims[f$claims$claim_id %in% affected, ],
    f$diagnoses[f$diagnoses$claim_id %in% affected, ],
    f$procedures[f$procedures$claim_id %in% affected, ],
    tables = msdrg_tables(f$version), poa_exempt = "unknown"
  )
