# MS-DRG formula language
#
# DRGLOGIC rows carry a boolean formula over "terms", evaluated per claim:
#
#   formula := or
#   or      := and ( "|" and )*
#   and     := unary ( "&" unary )*
#   unary   := "~" unary | primary
#   primary := "(" formula ")" | term
#   term    := [ scope ":" ] identifier        scope in PDX, SDX, ANY, ONLY
#
# Operator precedence (tightest first): ~, &, |.
#
# A term's meaning depends on its scope:
#   PDX:x  the principal diagnosis carries attribute x
#   SDX:x  some secondary diagnosis carries attribute x
#   ANY:x  the principal or some secondary diagnosis carries attribute x
#   ONLY:x every diagnosis on the claim carries attribute x
#   x      (no scope) some procedure carries attribute x, or x is a computed
#          special such as MCC, CC, BILATERAL or an edit flag.
#
# Formulas are compiled to ordinary R boolean expressions over named logical
# columns so that they can be evaluated with dplyr::mutate() in memory or, via
# dbplyr, inside a database.

msdrg_scopes <- c("PDX", "SDX", "ANY", "ONLY")

# Tokenize a formula into a tibble of (type, value) rows.
msdrg_formula_lex <- function(formula) {
  stopifnot(is.character(formula), length(formula) == 1)
  pattern <- "(?:[A-Za-z]+:)?[A-Za-z][A-Za-z0-9_]*|[()&|~]|\\s+|."
  pieces <- regmatches(formula, gregexpr(pattern, formula, perl = TRUE))[[1]]
  pieces <- pieces[!grepl("^\\s+$", pieces)]
  if (length(pieces) == 0) {
    cli::cli_abort("Empty MS-DRG formula.")
  }
  type <- dplyr::case_when(
    pieces %in% c("(", ")", "&", "|", "~") ~ pieces,
    grepl("^(?:[A-Za-z]+:)?[A-Za-z][A-Za-z0-9_]*$", pieces, perl = TRUE) ~ "term",
    TRUE ~ "error"
  )
  bad <- pieces[type == "error"]
  if (length(bad) > 0) {
    cli::cli_abort("Unexpected character{cli::qty(length(bad))}{?s} {.val {bad}} in formula {.code {formula}}.")
  }
  tibble::tibble(type = type, value = pieces)
}

# Parse a formula into an abstract syntax tree of nested lists.
#   list(type = "or"|"and", args = list(...))
#   list(type = "not", arg = ...)
#   list(type = "term", scope = <chr|NA>, name = <chr>)
msdrg_formula_parse <- function(formula) {
  tokens <- msdrg_formula_lex(formula)
  pos <- 1L
  n <- nrow(tokens)

  peek <- function() if (pos <= n) tokens$type[[pos]] else "eof"
  advance <- function() {
    tok <- tokens[pos, ]
    pos <<- pos + 1L
    tok
  }
  expect <- function(type) {
    if (peek() != type) {
      cli::cli_abort(
        "Expected {.val {type}} at token {pos} but found {.val {peek()}} in formula {.code {formula}}."
      )
    }
    advance()
  }

  # n-ary nodes are kept flat: (a & b) & c and a & b & c yield the same tree.
  nary <- function(type, args) {
    if (length(args) == 1) {
      return(args[[1]])
    }
    flat <- list()
    for (arg in args) {
      if (identical(arg$type, type)) flat <- c(flat, arg$args) else flat <- c(flat, list(arg))
    }
    list(type = type, args = flat)
  }
  parse_or <- function() {
    args <- list(parse_and())
    while (peek() == "|") {
      advance()
      args <- c(args, list(parse_and()))
    }
    nary("or", args)
  }
  parse_and <- function() {
    args <- list(parse_unary())
    while (peek() == "&") {
      advance()
      args <- c(args, list(parse_unary()))
    }
    nary("and", args)
  }
  parse_unary <- function() {
    if (peek() == "~") {
      advance()
      return(list(type = "not", arg = parse_unary()))
    }
    parse_primary()
  }
  parse_primary <- function() {
    if (peek() == "(") {
      advance()
      inner <- parse_or()
      expect(")")
      return(inner)
    }
    tok <- expect("term")
    value <- tok$value
    if (grepl(":", value, fixed = TRUE)) {
      scope <- sub(":.*$", "", value)
      name <- sub("^[^:]*:", "", value)
      if (!scope %in% msdrg_scopes) {
        cli::cli_abort("Unknown scope {.val {scope}} in formula {.code {formula}}.")
      }
    } else {
      scope <- NA_character_
      name <- value
    }
    list(type = "term", scope = scope, name = name)
  }

  ast <- parse_or()
  if (peek() != "eof") {
    cli::cli_abort("Unexpected trailing token {.val {tokens$value[[pos]]}} in formula {.code {formula}}.")
  }
  ast
}

# All terms referenced by an AST, as a tibble of (scope, name).
msdrg_formula_terms <- function(ast) {
  walk <- function(node) {
    switch(node$type,
      term = list(c(scope = node$scope, name = node$name)),
      not = walk(node$arg),
      c(lapply(node$args, walk)) |> unlist(recursive = FALSE)
    )
  }
  rows <- walk(ast)
  tibble::tibble(
    scope = vapply(rows, function(r) r[["scope"]], character(1)),
    name = vapply(rows, function(r) r[["name"]], character(1))
  ) |> dplyr::distinct()
}

# Column name used for a term when formulas are evaluated against a wide,
# one-row-per-claim table of logical attribute columns.
msdrg_term_column <- function(scope, name) {
  prefix <- ifelse(is.na(scope), "pr", tolower(scope))
  paste0(prefix, "__", name)
}

# Default term resolver: a term becomes the symbol of its wide-table column.
msdrg_resolve_default <- function(scope, name) {
  rlang::sym(msdrg_term_column(scope, name))
}

# Compile an AST into an R expression over term columns, e.g.
#   (PDX:dxc0306) & (MCC)  ->  pdx__dxc0306 & pr__MCC
# `resolver(scope, name)` returns the expression standing for one term.
msdrg_formula_compile <- function(ast, resolver = msdrg_resolve_default) {
  build <- function(node) {
    switch(node$type,
      term = resolver(node$scope, node$name),
      not = rlang::call2("!", build(node$arg)),
      and = Reduce(function(a, b) rlang::call2("&", a, b), lapply(node$args, build)),
      or = Reduce(function(a, b) rlang::call2("|", a, b), lapply(node$args, build))
    )
  }
  build(ast)
}

# Render an AST back to canonical formula text (used in tests and traces).
msdrg_formula_deparse <- function(ast) {
  render <- function(node, parent = "") {
    switch(node$type,
      term = if (is.na(node$scope)) node$name else paste0(node$scope, ":", node$name),
      not = paste0("~", render(node$arg, "not")),
      and = {
        txt <- paste(vapply(node$args, render, character(1), parent = "and"), collapse = " & ")
        if (parent %in% c("not")) paste0("(", txt, ")") else txt
      },
      or = {
        txt <- paste(vapply(node$args, render, character(1), parent = "or"), collapse = " | ")
        if (parent %in% c("and", "not")) paste0("(", txt, ")") else txt
      }
    )
  }
  render(ast)
}
