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

test_that("grouper() and group() dispatch to the MS-DRG engine", {
  g <- grouper("msdrg", version = "44.0")
  expect_s3_class(g, "msdrg_grouper")
  expect_output(print(g), "44.0")
  out <- group(g, fixture$claims[1:3, ], fixture$diagnoses[fixture$diagnoses$claim_id %in% 1:3, ],
               fixture$procedures[fixture$procedures$claim_id %in% 1:3, ])
  expect_equal(nrow(out), 3)
  expect_named(out, c("claim_id", "drg", "initial_drg", "base_drg", "mdc", "med_surg", "severity",
                      "initial_severity", "return_code", "drg_description", "mdc_description", "formula"))
})

test_that("initial grouping, MDC and return codes match the CMS grouper on all TESTDB claims", {
  cmp <- group_fixture()
  expect_equal(nrow(cmp), nrow(fixture$claims))
  expect_equal(cmp$initial_drg, cmp$initial_drg_exp)
  expect_equal(cmp$mdc, cmp$mdc_exp)
  expect_equal(cmp$return_code, cmp$return_code_exp)
  expect_equal(cmp$initial_severity, cmp$initial_severity_exp)
})

test_that("final grouping matches the CMS grouper on claims without a HAC-driven change", {
  cmp <- group_fixture()
  unaffected <- cmp$initial_drg_exp == cmp$drg_exp
  expect_equal(cmp$drg[unaffected], cmp$drg_exp[unaffected])
  expect_equal(cmp$severity[unaffected], cmp$severity_exp[unaffected])
  expect_equal(cmp$med_surg[unaffected], cmp$med_surg_exp[unaffected])
})

test_that("final grouping honours hospital-acquired conditions", {
  cmp <- group_fixture()
  affected <- cmp$initial_drg_exp != cmp$drg_exp
  expect_gt(sum(affected), 50)
  expect_equal(cmp$drg, cmp$drg_exp)
  expect_equal(cmp$severity, cmp$severity_exp)
  expect_equal(cmp$med_surg, cmp$med_surg_exp)
})

test_that("unknown hospital POA status makes HAC claims ungroupable with return code 10", {
  f <- fixture
  affected <- f$expected$claim_id[f$expected$initial_drg != f$expected$drg]
  got <- msdrg_group(
    f$claims[f$claims$claim_id %in% affected, ],
    f$diagnoses[f$diagnoses$claim_id %in% affected, ],
    f$procedures[f$procedures$claim_id %in% affected, ],
    tables = msdrg_tables(f$version), poa_exempt = "unknown"
  )
  expect_true(all(got$drg == 999L))
  expect_true(all(got$return_code %in% c(10L, 11L, 15L)))
  expect_equal(got$initial_drg, f$expected$initial_drg[match(got$claim_id, f$expected$claim_id)])
})

test_that("older bundled versions match the CMS grouper", {
  for (v in names(fixture$other_versions)) {
    exp <- fixture$other_versions[[v]]
    f <- fixture
    got <- msdrg_group(
      f$claims[f$claims$claim_id %in% exp$claim_id, ],
      f$diagnoses[f$diagnoses$claim_id %in% exp$claim_id, ],
      f$procedures[f$procedures$claim_id %in% exp$claim_id, ],
      tables = msdrg_tables(v), poa_exempt = "non_exempt"
    )
    cmp <- dplyr::inner_join(exp, got, by = "claim_id", suffix = c("_exp", ""))
    expect_equal(nrow(cmp), nrow(exp), info = v)
    expect_equal(cmp$drg, cmp$drg_exp, info = v)
    expect_equal(cmp$initial_drg, cmp$initial_drg_exp, info = v)
    expect_equal(cmp$mdc, cmp$mdc_exp, info = v)
    expect_equal(cmp$return_code, cmp$return_code_exp, info = v)
    expect_equal(cmp$severity, cmp$severity_exp, info = v)
  }
})

test_that("input validation reports missing columns and unknown claims", {
  expect_error(msdrg_group(data.frame(claim_id = 1), fixture$diagnoses[1, ]), "missing required column")
  expect_error(
    msdrg_group(fixture$claims[1, ], data.frame(claim_id = 999, seq = 1, code = "I10")),
    "absent from"
  )
})
