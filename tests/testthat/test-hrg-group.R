fixture <- readRDS(test_path("fixtures", "hrg_2024-25-nc_apc.rds"))

test_that("HRG4+ APC episode and spell grouping match NHS England's expected results", {
  res <- hrg_group_apc(fixture$episodes, tables = hrg_tables(fixture$version))
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
  expect_equal(nrow(res$spells), length(unique(paste(fixture$episodes$PROCODET, fixture$episodes$PROVSPNO))))
})

test_that("grouper() exposes the HRG4+ engine", {
  g <- grouper("hrg4plus", version = "2024-25-nc")
  expect_s3_class(g, "hrg_grouper")
  expect_output(print(g), "HRG4\\+")
  out <- group(g, fixture$episodes[1:5, ])
  expect_equal(out$episodes$fce_hrg, fixture$expected$FCE_HRG[1:5])
})
