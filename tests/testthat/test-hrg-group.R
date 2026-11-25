fixture <- readRDS(test_path("fixtures", "hrg_2024-25-nc.rds"))
tbls <- hrg_tables(fixture$version)

test_that("HRG4+ APC episode and spell grouping match NHS England's expected results", {
  res <- hrg_group_apc(fixture$episodes, tables = tbls)
  ep <- res$episodes
  exp <- fixture$expected
  expect_equal(nrow(ep), nrow(exp))
  expect_equal(ep$fce_hrg, exp$FCE_HRG)
  expect_equal(ep$grouping_method, exp$GroupingMethodFlag)
  expect_equal(ep$dominant_procedure, exp$DominantProcedure)
  expect_equal(ep$fce_pbc, exp$FCE_PBC)
  expect_equal(as.character(ep$calc_epidur), exp$CalcEpidur)
  expect_equal(gsub("\\*[0-9]+", "", ep$unbundled_hrgs), exp$unbundled)
  expect_equal(as.character(ep$spell_report_flag), exp$SpellReportFlag)
  expect_equal(ep$spell_hrg, exp$SpellHRG)
  expect_equal(ep$spell_grouping_method, exp$SpellGroupingMethodFlag)
  expect_equal(ep$spell_dominant_procedure, exp$SpellDominantProcedure)
  expect_equal(ep$spell_pdiag, exp$SpellPDiag)
  expect_equal(ep$spell_sdiag, exp$SpellSDiag)
  expect_equal(as.character(ep$spell_episode_count), exp$SpellEpisodeCount)
  expect_equal(as.character(ep$spell_los), exp$SpellLOS)
})

test_that("the 2025/26 Local Payment Grouper tables reproduce the same APC results", {
  res <- hrg_group_apc(fixture$episodes, tables = hrg_tables("2025-26-lp"))
  expect_equal(res$episodes$fce_hrg, fixture$expected$FCE_HRG)
  expect_equal(res$episodes$spell_hrg, fixture$expected$SpellHRG)
})

test_that("outpatient attendances match NHS England's expected results", {
  got <- hrg_group_nac(fixture$nac$input, tables = tbls)
  exp <- fixture$nac$expected
  expect_equal(got$nac_hrg, exp$NAC_HRG)
  expect_equal(got$grouping_method, exp$GroupingMethodFlag)
  expect_equal(got$dominant_procedure, exp$DominantProcedure)
  expect_equal(gsub("\\*[0-9]+", "", got$unbundled_hrgs), exp$unbundled)
})

test_that("emergency medicine attendances match NHS England's expected results", {
  got <- hrg_group_em(fixture$em$input, tables = tbls)
  expect_equal(got$em_hrg, fixture$em$expected$EM_HRG)
})

test_that("adult critical care periods match NHS England's expected results", {
  got <- hrg_group_acc(fixture$acc$input, tables = tbls)
  exp <- fixture$acc$expected
  expect_equal(got$acc_hrg, exp$ACC_HRG)
  expect_equal(as.character(got$calc_cc_days), exp$Calc_CC_Days)
  expect_equal(got$cc_warning_flag, dplyr::coalesce(exp$CC_Warning_Flag, ""))
})

test_that("renal dataset records match NHS England's expected results", {
  got <- hrg_group_nrd(fixture$nrd$input, tables = tbls)
  expect_equal(got$nrd_hrg, fixture$nrd$expected$NRD_HRG)
})

test_that("grouper() exposes the HRG4+ engines by dataset", {
  g <- grouper("hrg4plus", version = "2024-25-nc")
  expect_s3_class(g, "hrg_grouper")
  expect_output(print(g), "HRG4\\+")
  out <- group(g, fixture$episodes[1:5, ])
  expect_equal(out$episodes$fce_hrg, fixture$expected$FCE_HRG[1:5])
  expect_equal(group(g, fixture$nac$input[1:5, ], dataset = "nac")$nac_hrg, fixture$nac$expected$NAC_HRG[1:5])
  expect_equal(group(g, fixture$em$input[1:5, ], dataset = "em")$em_hrg, fixture$em$expected$EM_HRG[1:5])
  expect_equal(group(g, fixture$acc$input[1:5, ], dataset = "acc")$acc_hrg, fixture$acc$expected$ACC_HRG[1:5])
  expect_equal(group(g, fixture$nrd$input[1:5, ], dataset = "nrd")$nrd_hrg, fixture$nrd$expected$NRD_HRG[1:5])
})
