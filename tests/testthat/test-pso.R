fixture <- readRDS(test_path("fixtures", "pso_2025-26.rds"))
tbls <- pso_tables(fixture$version)

test_that("PSO admitted patient care flags match NHS England's expected results", {
  res <- pso_flag_apc(fixture$apc$input, tables = tbls)
  ep <- res$episodes
  exp <- fixture$apc$expected
  expect_equal(nrow(ep), nrow(exp))
  expect_equal(ep$fce_npoc, exp$FCE_NPOC)
  expect_equal(ep$service_line, exp$ServiceLine)
  expect_equal(ep$service_line_list, exp$ServiceLineList)
  expect_equal(ep$spell_npoc, exp$SpellNPOC)
  expect_equal(ep$spell_service_line, exp$SpellServiceLine)
  expect_equal(ep$quality, exp$quality)
  sp <- res$spells[!is.na(res$spells$spell_service_line), ]
  expect_equal(as.character(sp$first_row), fixture$apc$spells$RowNo)
  expect_equal(sp$spell_service_line, fixture$apc$spells$SpellServiceLine)
  expect_equal(sp$spell_npoc, fixture$apc$spells$SpellNPOC)
})

test_that("PSO outpatient flags match NHS England's expected results", {
  got <- pso_flag_nac(fixture$nac$input, tables = tbls)
  exp <- fixture$nac$expected
  expect_equal(got$npoc, exp$NPOC)
  expect_equal(got$service_line, exp$ServiceLine)
  expect_equal(got$quality, exp$quality)
})

test_that("the Version 2 rules differ from Version 1 exactly as published", {
  v2 <- pso_tables("2025-26-v2")
  new_lines <- dplyr::anti_join(v2$service_lines, tbls$service_lines, by = c("setting", "service_line"))
  expect_equal(new_lines$service_line, "NCBPS32B")
  expect_equal(new_lines$setting, "NAC")
  added <- dplyr::anti_join(v2$lists, tbls$lists, by = c("list_id", "code"))
  expect_true(all(c("H043", "RW1", "RPY") %in% added$code))
  removed <- dplyr::anti_join(tbls$lists, v2$lists, by = c("list_id", "code"))
  expect_setequal(paste(removed$list_id, removed$code), c("PS27B_Org RAL", "PS51A_Org RN5"))
  # The sample data has no bone-anchored hearing aid outpatients, so both versions agree on it.
  expect_equal(pso_flag_nac(fixture$nac$input, tables = v2)$service_line, fixture$nac$expected$ServiceLine)
})

test_that("the dominant procedure is the highest-hierarchy code, first on ties", {
  h <- tbls$proc_hier
  high <- names(h)[h == max(h)][1]
  tie <- names(h)[h == h[["H043"]]]
  tie <- tie[tie != "H043"][1]
  ep <- tibble::tibble(
    PROCODET = "PSS", PROVSPNO = c("1", "2", "3"), STARTAGE = "40", SEX = "1", CLASSPAT = "1", ADMIMETH = "11",
    MAINSPEF = "100", TRETSPEF = "100", DIAG_01 = "K509",
    OPER_01 = c("Y532", "H043", tie), OPER_02 = c(high, tie, "H043")
  )
  res <- pso_flag_apc(ep, tables = tbls)
  expect_equal(res$episodes$quality, c("", "", ""))
  expect_equal(res$episodes$dominant_procedure, c(high, "H043", tie))
})

test_that("the generic PSS provider code is on every provider eligibility list", {
  org_lists <- unique(tbls$lists$list_id[tbls$lists$code_type == "Org"])
  expect_true(all(vapply(org_lists, function(l) "PSS" %in% tbls$list_sets[[l]], logical(1))))
  # NCBPS01J (anal cancer) needs a listed primary diagnosis at an eligible provider.
  row <- tibble::tibble(
    PROCODET = c("PSS", "ZZZ"), PROVSPNO = c("1", "2"), STARTAGE = "40", SEX = "1", CLASSPAT = "1", ADMIMETH = "11",
    MAINSPEF = "100", TRETSPEF = "100", DIAG_01 = tbls$list_sets[["PS01J_ICD"]][1], OPER_01 = NA
  )
  res <- pso_flag_apc(row, tables = tbls)
  expect_equal(res$episodes$service_line, c("NCBPS01J", NA))
  expect_equal(res$episodes$fce_npoc, c("A07", NA))
})

test_that("grouper() exposes the PSO engine by dataset", {
  g <- grouper("pso", version = "2025-26")
  expect_s3_class(g, "pso_grouper")
  expect_output(print(g), "Prescribed Specialised Services")
  out <- group(g, fixture$apc$input[1:20, ])
  expect_equal(out$episodes$service_line, fixture$apc$expected$ServiceLine[1:20])
  expect_equal(group(g, fixture$nac$input[1:10, ], dataset = "nac")$service_line, fixture$nac$expected$ServiceLine[1:10])
})
