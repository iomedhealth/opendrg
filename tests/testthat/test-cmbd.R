rae <- data.frame(
  HISTORIA = c("A1", "A2", "A3", "A4"),
  FECNAC = c("15031957", "01012020", "230845", "1990-06-30"),
  SEXO = c("1", "2", "3", "M"),
  FECINICONT = c("02052024 1130", "02052024 0800", "10/11/2024", "20240705"),
  TIPCONT = "1",
  TIPALT = c("1", "4", "3", "9"),
  D1 = c("I21.4", "I21.4", "F10.20", "O80"),
  D2 = c("E11.9", "N17.9", "", "Z37.0"),
  D3 = c("N17.9", "", NA, ""),
  POAD1 = c("S", "S", "S", "S"),
  POAD2 = c("S", "N", "", "E"),
  POAD3 = c("N", "", "", ""),
  PROC1 = c("02703ZZ", "", "", "10E0XZZ"),
  PROC2 = "",
  PROCEXT1 = c("", "", "", "B2111ZZ"),
  stringsAsFactors = FALSE
)

test_that("RAE-CMBD fields are mapped to the MS-DRG conventions", {
  inp <- cmbd_to_msdrg(rae, id = "HISTORIA")
  expect_named(inp, c("claims", "diagnoses", "procedures"))
  expect_equal(inp$claims$claim_id, rae$HISTORIA)
  expect_equal(inp$claims$age, c(67L, 4L, 79L, 34L))
  expect_equal(inp$claims$sex, c(1L, 2L, 0L, 2L))
  expect_equal(inp$claims$discharge_status, c("01", "20", "07", NA))
  expect_equal(inp$claims$cmbd_discharge, c("1", "4", "3", "9"))
  expect_equal(inp$claims$contact_type, rep("1", 4))
  expect_equal(inp$diagnoses$code, c("I214", "E119", "N179", "I214", "N179", "F1020", "O80", "Z370"))
  expect_equal(inp$diagnoses$poa, c("Y", "Y", "N", "Y", "N", "Y", "Y", "1"))
  expect_equal(inp$diagnoses$seq[inp$diagnoses$claim_id == "A1"], 1:3)
  expect_equal(inp$procedures$code, c("02703ZZ", "10E0XZZ"))
})

test_that("external procedures are excluded unless asked for, and ids default to row numbers", {
  inp <- cmbd_to_msdrg(rae, include_external = TRUE)
  expect_equal(inp$claims$claim_id, 1:4)
  expect_equal(inp$procedures$code[inp$procedures$claim_id == 4], c("10E0XZZ", "B2111ZZ"))
  expect_equal(inp$procedures$seq[inp$procedures$claim_id == 4], 1:2)
})

test_that("the register's date formats and an EDAD column are understood", {
  expect_equal(cmbd_parse_date(c("15031957", "230845", "1990-06-30", "20240705", "10/11/2024", "", NA)),
               as.Date(c("1957-03-15", "1945-08-23", "1990-06-30", "2024-07-05", "2024-11-10", NA, NA)))
  expect_equal(cmbd_age_years(as.Date("2000-02-29"), as.Date(c("2024-02-28", "2024-02-29"))), c(23L, 24L))
  with_age <- cbind(rae, EDAD = c("1", "2", "3", "4"))
  expect_equal(cmbd_to_msdrg(with_age)$claims$age, 1:4)
})

test_that("common column-name variants are recognised and missing essentials are reported", {
  alt <- data.frame(
    EDAD = 70, SEX = "2", TIPALTA = "2", DIAG_01 = "I10", DIAG_02 = "N183", POA_01 = "S", POA_02 = "S", PROC_01 = "5A1D70Z"
  )
  inp <- cmbd_to_msdrg(alt)
  expect_equal(inp$claims$discharge_status, "02")
  expect_equal(inp$diagnoses$code, c("I10", "N183"))
  expect_equal(inp$procedures$code, "5A1D70Z")
  expect_error(cmbd_to_msdrg(data.frame(SEXO = "1", TIPALT = "1", EDAD = 1)), "diagnosis")
  expect_error(cmbd_to_msdrg(data.frame(SEXO = "1", TIPALT = "1", D1 = "I10")), "Age")
  expect_error(cmbd_to_msdrg(rae, id = "D1"), "uniquely")
})

test_that("the adapter output groups directly and the Spanish discharge codes drive the DRG", {
  g <- grouper("msdrg", version = "44.0")
  out <- group(g, cmbd_to_msdrg(rae, id = "HISTORIA"))
  expect_equal(out$claim_id, rae$HISTORIA)
  expect_equal(out$drg, c(251L, 284L, 894L, 807L))   # PCI; AMI expired w CC; left AMA; vaginal delivery
  expect_equal(out$return_code, rep(0L, 4))
  alive <- rae
  alive$TIPALT[2] <- "1"
  expect_equal(group(g, cmbd_to_msdrg(alive))$drg[2], 281L)   # AMI discharged alive w CC
})
