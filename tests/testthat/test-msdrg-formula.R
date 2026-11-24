test_that("lexer splits scoped terms, operators and parentheses", {
  toks <- msdrg_formula_lex("(PDX:dxc0306) & ~SDX:hiv | kidneyxp")
  expect_equal(toks$type, c("(", "term", ")", "&", "~", "term", "|", "term"))
  expect_equal(toks$value[toks$type == "term"], c("PDX:dxc0306", "SDX:hiv", "kidneyxp"))
})

test_that("lexer rejects stray characters", {
  expect_error(msdrg_formula_lex("a + b"), "Unexpected character")
  expect_error(msdrg_formula_lex(""), "Empty")
})

test_that("parser honours precedence: ~ binds tighter than &, which binds tighter than |", {
  ast <- msdrg_formula_parse("a | b & ~c")
  expect_equal(ast$type, "or")
  expect_equal(ast$args[[2]]$type, "and")
  expect_equal(ast$args[[2]]$args[[2]]$type, "not")
  expect_equal(msdrg_formula_deparse(ast), "a | b & ~c")

  ast2 <- msdrg_formula_parse("(a | b) & c")
  expect_equal(ast2$type, "and")
  expect_equal(msdrg_formula_deparse(ast2), "(a | b) & c")
})

test_that("parser resolves scopes and rejects unknown ones", {
  ast <- msdrg_formula_parse("ANY:diabetes & (pancxp | NORislets) & ~(kidneyxp & ANY:renalfail)")
  terms <- msdrg_formula_terms(ast)
  expect_setequal(terms$name, c("diabetes", "pancxp", "NORislets", "kidneyxp", "renalfail"))
  expect_equal(terms$scope[terms$name == "diabetes"], "ANY")
  expect_true(is.na(terms$scope[terms$name == "pancxp"]))
  expect_error(msdrg_formula_parse("FOO:bar"), "Unknown scope")
})

test_that("parser reports malformed formulas", {
  expect_error(msdrg_formula_parse("(a & b"), "Expected")
  expect_error(msdrg_formula_parse("a b"), "trailing")
  expect_error(msdrg_formula_parse("a &"), "Expected")
})

test_that("compiled expressions evaluate correctly on a wide claim table", {
  expr <- msdrg_formula_compile(msdrg_formula_parse("(PDX:dxc0306) & (MCC | CC) & ~SDX:hiv"))
  expect_equal(
    rlang::expr_text(expr),
    "pdx__dxc0306 & (pr__MCC | pr__CC) & !sdx__hiv"
  )
  claims <- tibble::tibble(
    pdx__dxc0306 = c(TRUE, TRUE, FALSE, TRUE),
    pr__MCC      = c(TRUE, FALSE, TRUE, FALSE),
    pr__CC       = c(FALSE, TRUE, FALSE, FALSE),
    sdx__hiv     = c(FALSE, TRUE, FALSE, FALSE)
  )
  got <- dplyr::mutate(claims, hit = !!expr)$hit
  expect_equal(got, c(TRUE, FALSE, FALSE, FALSE))
})

test_that("every bundled v44.0 DRGLOGIC formula parses and round-trips", {
  tbls <- readRDS(system.file("extdata", "msdrg", "v440.rds", package = "opendrg"))
  asts <- lapply(tbls$drg_logic$formula, msdrg_formula_parse)
  expect_length(asts, nrow(tbls$drg_logic))
  # Round-trip: deparse(parse(x)) must parse to an identical tree.
  for (i in seq_along(asts)) {
    expect_identical(msdrg_formula_parse(msdrg_formula_deparse(asts[[i]])), asts[[i]])
  }
  terms <- dplyr::bind_rows(lapply(asts, msdrg_formula_terms)) |> dplyr::distinct()
  expect_true(all(is.na(terms$scope) | terms$scope %in% c("PDX", "SDX", "ANY", "ONLY")))
})
