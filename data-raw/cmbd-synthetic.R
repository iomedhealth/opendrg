# Build inst/extdata/cmbd/rae-cmbd-synthetic.txt: a synthetic extract of the
# Spanish hospital activity register (RAE-CMBD, Real Decreto 69/2015) in the
# exchange layout hospitals send to their regional health service, one month of
# discharges of a fictional general hospital. Nothing comes from real patients:
# every value is drawn from the clinical profiles below, whose frequencies
# loosely follow the national RAE-CMBD figures and hospital annual reports.
#
# The file follows the 96-field order of the RD 69/2015 exchange layout as laid
# out in the Castilla y León procedure manual (D1/POAD1 .. D20/POAD20 interleaved),
# pipe-delimited with a header line (no physical format is prescribed nationally;
# Andalucía's manual uses "|"). Diagnoses and procedures are CIE-10-ES codes, i.e.
# ICD-10-CM/PCS FY2023 (the edition CIE-10-ES 2024 is based on); every code is
# checked against the bundled MS-DRG v44.0 tables and, when the folder is given,
# against the FY2023 lists. The output is deterministic for a given seed.
#
# Usage: Rscript data-raw/cmbd-synthetic.R [fy2023_dir]
#   fy2023_dir: folder holding icd10cm_codes_2023.txt and icd10pcs_codes_2023.txt from
#   https://www.cms.gov/files/zip/2023-code-descriptions-tabular-order.zip and
#   https://www.cms.gov/files/zip/2023-icd-10-pcs-codes-file.zip

args <- commandArgs(trailingOnly = TRUE)
fy2023_dir <- if (length(args) >= 1) args[[1]] else NULL

pkgload::load_all(".", quiet = TRUE)
set.seed(69015)

`%||%` <- function(a, b) if (is.null(a)) b else a

# ---- sampling helpers --------------------------------------------------------

pick <- function(x) names(x)[sample.int(length(x), 1, prob = x)]
bern <- function(p) stats::runif(1) < p
rlos <- function(spec, min = 1) max(min, round(stats::rlnorm(1, log(spec[1]), spec[2])))
rage <- function(spec) {
  if (is.function(spec)) return(as.integer(spec()))
  if (length(spec) == 1) return(as.integer(spec))
  as.integer(round(min(spec[4], max(spec[3], stats::rnorm(1, spec[1], spec[2])))))
}
mix_age <- function(p_child, child, adult) function() if (bern(p_child)) sample(child[1]:child[2], 1) else rage(adult)
w <- function(...) c(...)

# A bundle: principal diagnosis (first code) with the secondaries, procedures and
# morphology it implies, plus optional overrides of the profile defaults.
b <- function(w, dx, proc = NULL, morph = NULL, poa = NULL, los = NULL, urgent = NULL,
              service = NULL, female = NULL, age = NULL, uci = NULL, exitus = NULL) {
  list(w = w, dx = dx, proc = proc, morph = morph, poa = poa, los = los, urgent = urgent,
       service = service, female = female, age = age, uci = uci, exitus = exitus)
}
opt <- function(code, p, poa = "S", sex = NULL) list(type = "opt", code = code, p = p, poa = poa, sex = sex)
alt <- function(x) list(type = "alt", choices = x)

prof <- function(w, service, age, female = 0.5, pdx, sdx = list(), proc = list(), los = c(4, 0.4),
                 exitus = 0, transfer = 0, social = 0, ama = 0, urgent = 1, uci = 0, uci_days = c(1, 3),
                 surgery = FALSE, tipcont = "1", comorbid = TRUE, hac = TRUE, procedencia = NULL,
                 readmit = 0) {
  list(w = w, service = service, age = age, female = female, pdx = pdx, sdx = sdx, proc = proc,
       los = los, exitus = exitus, transfer = transfer, social = social, ama = ama, urgent = urgent,
       uci = uci, uci_days = uci_days, surgery = surgery, tipcont = tipcont, comorbid = comorbid,
       hac = hac, procedencia = procedencia, readmit = readmit)
}

# ---- comorbidities and hospital-acquired conditions --------------------------

# Chronic conditions by age band (< 40, 40-64, 65+); sex-specific codes carry a sex.
comorbidity_pool <- list(
  list("I10", c(0.04, 0.25, 0.55)), list("E11.9", c(0.02, 0.14, 0.26)), list("E78.5", c(0.02, 0.18, 0.30)),
  list("E66.9", c(0.06, 0.14, 0.10)), list("I48.20", c(0, 0.03, 0.12)), list("I48.0", c(0, 0.02, 0.05)),
  list("N18.30", c(0, 0.03, 0.12)), list("N18.4", c(0, 0.01, 0.03)), list("J44.9", c(0, 0.04, 0.13)),
  list("I25.10", c(0, 0.04, 0.14)), list("I50.9", c(0, 0.01, 0.07)), list("F03.90", c(0, 0.003, 0.10)),
  list("G30.9", c(0, 0, 0.04)), list("K21.9", c(0.03, 0.08, 0.10)), list("E03.9", c(0.02, 0.07, 0.10)),
  list("Z95.0", c(0, 0.005, 0.03)), list("F17.210", c(0.14, 0.22, 0.07)), list("Z87.891", c(0.02, 0.10, 0.22)),
  list("F10.20", c(0.02, 0.05, 0.02)), list("D64.9", c(0.02, 0.04, 0.08)), list("Z86.73", c(0, 0.01, 0.06)),
  list("G47.33", c(0.01, 0.05, 0.05)), list("F32.A", c(0.03, 0.07, 0.07)), list("F41.9", c(0.04, 0.08, 0.05)),
  list("Z79.899", c(0.05, 0.20, 0.35)), list("I69.351", c(0, 0.004, 0.02)), list("E44.0", c(0, 0.01, 0.04)),
  list("Z74.09", c(0, 0, 0.03)), list("Z99.81", c(0, 0.005, 0.02)), list("I73.9", c(0, 0.01, 0.04)),
  list("M81.0", c(0, 0.02, 0.12), "2"), list("N40.0", c(0, 0.03, 0.25), "1"), list("Z66", c(0, 0.002, 0.02)),
  list("Z88.0", c(0.04, 0.07, 0.09)), list("Z85.3", c(0, 0.01, 0.04), "2"),
  list("Z96.651", c(0, 0.01, 0.05)), list("Z95.5", c(0, 0.01, 0.05)), list("Z90.710", c(0, 0.03, 0.08), "2"),
  list("M19.90", c(0, 0.03, 0.12)), list("K57.30", c(0, 0.02, 0.08)), list("E55.9", c(0.02, 0.05, 0.08)),
  list("M10.9", c(0, 0.02, 0.05)), list("I87.2", c(0, 0.02, 0.05)), list("I70.0", c(0, 0.01, 0.05)),
  list("H40.9", c(0, 0.01, 0.04)), list("R54", c(0, 0, 0.04)), list("Z91.81", c(0, 0, 0.05)), list("Z99.3", c(0, 0, 0.02))
)

comorbidities <- function(age, sex) {
  if (age < 18) return(c("J45.909", "E66.9")[c(bern(0.05), bern(0.05))])
  band <- if (age < 40) 1 else if (age < 65) 2 else 3
  out <- character()
  for (item in comorbidity_pool) {
    if (length(item) == 3 && item[[3]] != sex) next
    if (bern(item[[2]][band])) out <- c(out, item[[1]])
  }
  if (any(startsWith(out, "I48")) && bern(0.8)) out <- c(out, "Z79.01")
  if ("E11.9" %in% out && any(startsWith(out, "N18")) && bern(0.5)) out[out == "E11.9"] <- "E11.22"
  if (any(startsWith(out, "E11")) && bern(0.25)) out <- c(out, "Z79.4")
  if ("G30.9" %in% out) out <- c(out, "F02.80")
  if (any(out %in% c("N18.4", "N18.5")) && bern(0.3)) out <- c(out, "D63.1")
  out
}

hospital_acquired <- function(age, los, surgical) {
  out <- character()
  add <- function(code, p) if (bern(p)) out <<- c(out, code)
  add("N17.9", min(0.08, 0.015 + 0.004 * los))
  add("E87.1", 0.02)
  add("E87.6", 0.02)
  add("D62", if (surgical) 0.06 else 0.01)
  if (age >= 70 && los >= 7) add("L89.152", 0.012)
  if (age >= 70 && los >= 10) add("L89.153", 0.004)
  if (age >= 75) add("F05", 0.03)
  if (age >= 75) add("J69.0", 0.01)
  if (los >= 4) add("N39.0", 0.02)
  if (surgical) add("T81.41XA", 0.02)
  if (surgical) add("R33.9", 0.02)
  add("K59.00", 0.03)
  add("I82.401", 0.004)
  add("I26.99", 0.002)
  if (los >= 7) add("A04.72", 0.004)
  out
}

female_only <- "^(C50\\.[0-9]1|O|Z3A|Z37|N8[04]|D25|C5[46]|Z90\\.71)"
male_only <- "^(C61|N4[017])"

# POA-exempt categories (CMS list, abridged): the register records them as "E".
poa_exempt <- "^(Z3[78A]|Z51|Z6[68]|Z7[49]|Z8[67]|Z9[0-9]|O80|O82|O09|Q|[VWXY]|I69|B9[0-4])"

# ---- clinical profiles ---------------------------------------------------------

Z3A_term <- alt(w("Z3A.37" = 8, "Z3A.38" = 22, "Z3A.39" = 35, "Z3A.40" = 28, "Z3A.41" = 7))
falls <- alt(w("W19.XXXA" = 50, "W01.0XXA" = 30, "W18.30XA" = 20))
smoking <- alt(w("F17.210" = 40, "Z87.891" = 45, none = 15))

profiles <- list(
  # -- obstetrics and newborns --
  parto_vaginal = prof(
    w = 55, service = "OBS", age = c(31, 5.5, 16, 46), female = 1, urgent = 0.9, comorbid = FALSE, hac = FALSE,
    pdx = list(b(40, "O80"), b(12, "O70.0", proc = "0HQ9XZZ"), b(12, "O70.1", proc = "0KQM0ZZ"), b(8, "O42.02"),
               b(6, "O48.0"), b(5, "O99.02"), b(4, "O36.5930"), b(5, "O24.420"), b(3, "O13.4"), b(5, "O99.214")),
    sdx = list(alt(w("Z37.0" = 1)), Z3A_term, opt("O99.02", 0.05)),
    proc = list(alt(w("10E0XZZ" = 1)), opt("0W8NXZZ", 0.30), opt("3E033VJ", 0.35), opt("10907ZC", 0.25), opt("3E0R3BZ", 0.55)),
    los = c(2, 0.25)
  ),
  cesarea = prof(
    w = 16, service = "OBS", age = c(32, 5.5, 17, 46), female = 1, urgent = 0.7, comorbid = FALSE, surgery = TRUE,
    pdx = list(b(35, "O34.211"), b(20, "O32.1XX0"), b(15, "O62.0"), b(10, "O76"), b(7, "O14.14"), b(8, "O33.9"), b(5, "O36.5930")),
    sdx = list(alt(w("Z37.0" = 1)), Z3A_term, opt("O99.02", 0.08), opt("O24.420", 0.06), opt("D62", 0.04, "N")),
    proc = list(alt(w("10D00Z1" = 1)), opt("3E0R3BZ", 0.9)),
    los = c(3.5, 0.2)
  ),
  recien_nacido = prof(
    w = 60, service = "NEO", age = 0, female = 0.49, comorbid = FALSE, hac = FALSE, procedencia = w("24" = 1),
    pdx = list(b(75, "Z38.00"), b(25, "Z38.01")),
    sdx = list(opt("P59.9", 0.08), opt("P92.5", 0.03), opt("P70.4", 0.03), opt("P08.1", 0.02), opt("P22.1", 0.02)),
    los = c(2.3, 0.25), exitus = 0.001
  ),
  prematuro = prof(
    w = 6, service = "NEO", age = 0, female = 0.48, comorbid = FALSE, hac = FALSE, procedencia = w("24" = 1),
    pdx = list(b(55, c("Z38.01", "P07.36", "P07.17")), b(25, c("Z38.00", "P07.38", "P07.18")),
               b(20, c("Z38.01", "P07.33", "P07.15", "P22.0"), proc = "5A09457", uci = 1)),
    sdx = list(opt("P59.0", 0.5), opt("P22.1", 0.2), opt("P28.5", 0.1), opt("P36.9", 0.08), opt("P61.2", 0.1), opt("P70.4", 0.15)),
    proc = list(opt("5A09357", 0.25), opt("5A1945Z", 0.08), opt("3E0436Z", 0.3), opt("0BH17EZ", 0.05)),
    los = c(18, 0.5), uci = 0.9, uci_days = c(5, 20), exitus = 0.02, transfer = 0.03
  ),
  gestacion = prof(
    w = 5, service = "OBS", age = c(30, 5.5, 16, 45), female = 1, comorbid = FALSE, hac = FALSE,
    pdx = list(b(30, "O21.1"), b(20, "O20.0"), b(20, "O47.03"), b(15, "O36.8130"), b(15, "O23.43")),
    sdx = list(alt(w("Z3A.08" = 15, "Z3A.12" = 15, "Z3A.20" = 15, "Z3A.28" = 20, "Z3A.32" = 20, "Z3A.35" = 15))),
    los = c(2.5, 0.4)
  ),
  aborto = prof(
    w = 3, service = "GIN", age = c(31, 6, 16, 45), female = 1, urgent = 0.8, comorbid = FALSE, hac = FALSE, surgery = TRUE,
    pdx = list(b(40, "O03.4", proc = "10D17ZZ"), b(30, "O03.9"), b(30, "O02.1", proc = "10A07ZZ")),
    los = c(1, 0.3)
  ),
  # -- cardiology --
  insuf_cardiaca = prof(
    w = 45, service = w(CAR = 55, MIR = 40, GRT = 5), age = c(79, 9, 45, 99), female = 0.52, urgent = 0.92, readmit = 0.12,
    pdx = list(b(25, "I50.9"), b(20, "I50.23"), b(20, "I50.33"), b(8, "I50.21"), b(12, c("I11.0", "I50.23")),
               b(8, c("I11.0", "I50.33")), b(7, c("I13.0", "I50.9", "N18.30"))),
    sdx = list(opt("I48.20", 0.35), opt("J44.9", 0.18), opt("I25.10", 0.25), opt("I27.20", 0.10), opt("D64.9", 0.12),
               opt("E87.1", 0.08), opt("N17.9", 0.06), opt("N17.9", 0.06, "N"), opt("J96.01", 0.22), opt("I35.0", 0.08),
               opt("I34.0", 0.08), opt("Z95.0", 0.05), opt("I42.9", 0.08), opt("E66.9", 0.10), opt("N18.4", 0.08)),
    proc = list(opt("B246ZZZ", 0.25), opt("5A09357", 0.10), opt("5A1945Z", 0.02), opt("30233N1", 0.03), opt("0T9B70Z", 0.05)),
    los = c(8, 0.5), exitus = 0.09, social = 0.03, transfer = 0.01, uci = 0.03
  ),
  iam = prof(
    w = 14, service = "CAR", age = c(66, 12, 35, 95), female = 0.28, urgent = 0.97, uci = 0.5, uci_days = c(1, 3), surgery = TRUE,
    pdx = list(b(20, "I21.09"), b(20, "I21.02"), b(20, "I21.11"), b(40, "I21.4")),
    sdx = list(opt("I25.10", 0.7), opt("E78.5", 0.5), opt("F17.210", 0.3), opt("I50.21", 0.08), opt("I48.0", 0.08),
               opt("N17.9", 0.05), opt("R57.0", 0.03), opt("I46.9", 0.02)),
    proc = list(alt(w("027034Z+4A023N7+B2111ZZ" = 55, "02703DZ+4A023N7+B2111ZZ" = 10, "027134Z+4A023N7+B2111ZZ" = 20, "4A023N7+B2111ZZ" = 15))),
    los = c(5, 0.45), exitus = 0.05
  ),
  arritmia = prof(
    w = 14, service = "CAR", age = c(72, 12, 30, 95), urgent = 0.8,
    pdx = list(b(35, "I48.0"), b(25, "I48.91"), b(10, "I48.11"), b(10, "I48.19"), b(10, "I49.5"), b(10, "I48.20")),
    sdx = list(opt("I50.9", 0.1), opt("Z79.01", 0.4), opt("I25.10", 0.15)),
    proc = list(opt("5A2204Z", 0.25)),
    los = c(3, 0.4), exitus = 0.01
  ),
  marcapasos = prof(
    w = 6, service = "CAR", age = c(80, 8, 60, 97), female = 0.45, urgent = 0.7, surgery = TRUE,
    pdx = list(b(55, "I44.2"), b(35, "I49.5"), b(10, "I44.1")),
    proc = list(alt(w("0JH606Z+02HK3JZ+02H63JZ" = 80, "0JH604Z+02HK3JZ" = 20))),
    los = c(3, 0.4), exitus = 0.005
  ),
  tavi = prof(
    w = 5, service = "CAR", age = c(83, 5, 70, 95), urgent = 0.2, uci = 0.6, uci_days = c(1, 2), surgery = TRUE,
    pdx = list(b(100, "I35.0")),
    sdx = list(opt("I48.20", 0.3), opt("N18.30", 0.2), opt("I25.10", 0.3), opt("I50.9", 0.3)),
    proc = list(alt(w("02RF38Z+4A023N7" = 70, "02RF38Z" = 30))),
    los = c(5, 0.4), exitus = 0.02
  ),
  bypass = prof(
    w = 4, service = "CCA", age = c(67, 8, 45, 82), female = 0.2, urgent = 0.3, uci = 1, uci_days = c(2, 4), surgery = TRUE,
    pdx = list(b(70, "I25.10"), b(30, "I25.110")),
    proc = list(alt(w("02100Z9+021109W+5A1221Z" = 70, "02100Z9+5A1221Z" = 30)), opt("30233N1", 0.3)),
    los = c(10, 0.35), exitus = 0.03
  ),
  sincope_torax = prof(
    w = 12, service = w(CAR = 60, MIR = 40), age = c(65, 18, 18, 97),
    pdx = list(b(50, "R55"), b(12, "I20.0", proc = c("4A023N7", "B2111ZZ")), b(13, "I20.0"), b(15, "R07.9"), b(10, "I20.9")),
    sdx = list(opt("I48.0", 0.1), opt("I25.10", 0.2), opt("E78.5", 0.3)),
    los = c(2.5, 0.4), exitus = 0.003
  ),
  endocarditis = prof(
    w = 2, service = "CAR", age = c(68, 14, 25, 90), uci = 0.2,
    pdx = list(b(60, c("I33.0", "B95.61")), b(40, c("I33.0", "B95.2"))),
    sdx = list(opt("I34.0", 0.4), opt("I50.9", 0.3)),
    proc = list(opt("02HV33Z", 0.5), opt("B246ZZZ", 0.6)),
    los = c(28, 0.3), exitus = 0.15
  ),
  # -- respiratory --
  neumonia = prof(
    w = 45, service = w(NML = 45, MIR = 50, GRT = 5), age = c(74, 15, 18, 99), female = 0.45, uci = 0.05,
    pdx = list(b(55, "J18.9"), b(15, "J18.1"), b(10, "J15.9"), b(8, "J13"), b(7, "J69.0"), b(5, "J12.9")),
    sdx = list(opt("J96.01", 0.2), opt("J96.00", 0.05), opt("E87.1", 0.08), opt("N17.9", 0.07), opt("N17.9", 0.03, "N"),
               opt("J90", 0.06), opt("J44.9", 0.2), opt("I50.9", 0.1), opt("F03.90", 0.1), opt("E86.0", 0.1),
               opt("R13.12", 0.05), opt("Z99.81", 0.05)),
    proc = list(opt("5A09357", 0.05), opt("5A09457", 0.08), opt("5A1945Z", 0.03), opt("0W9930Z", 0.03)),
    los = c(7, 0.5), exitus = 0.10, social = 0.03
  ),
  epoc = prof(
    w = 30, service = w(NML = 70, MIR = 30), age = c(73, 9, 50, 95), female = 0.3, urgent = 0.98, readmit = 0.12,
    pdx = list(b(85, "J44.1"), b(15, c("J44.0", "J20.9"))),
    sdx = list(opt("J96.01", 0.15), opt("J96.02", 0.08), opt("J96.11", 0.1), opt("Z99.81", 0.15), opt("I50.9", 0.12),
               opt("I27.20", 0.1), opt("G47.33", 0.08), smoking),
    proc = list(opt("5A09457", 0.12), opt("5A09357", 0.05)),
    los = c(6, 0.45), exitus = 0.04, social = 0.01
  ),
  insuf_respiratoria = prof(
    w = 12, service = w(NML = 45, MIR = 40, MIV = 15), age = c(78, 11, 50, 99), female = 0.45, uci = 0.15,
    pdx = list(b(60, "J96.01"), b(20, "J96.02"), b(20, "J96.21")),
    sdx = list(opt("J44.9", 0.35), opt("I50.9", 0.25), opt("J18.9", 0.25), opt("E66.01", 0.1), opt("G47.33", 0.12),
               opt("I26.99", 0.05), opt("J90", 0.08), opt("Z99.81", 0.15)),
    proc = list(opt("5A09457", 0.3), opt("5A1945Z", 0.1), opt("5A1955Z", 0.03), opt("0BH17EZ", 0.03)),
    los = c(8, 0.5), exitus = 0.14
  ),
  asma = prof(
    w = 6, service = "NML", age = c(42, 16, 16, 80), female = 0.6,
    pdx = list(b(70, "J45.901"), b(30, "J45.41")),
    sdx = list(opt("J96.01", 0.05), opt("E66.9", 0.15), opt("K21.9", 0.1), opt("J30.9", 0.15)),
    los = c(4, 0.35), exitus = 0.002
  ),
  tep = prof(
    w = 6, service = w(NML = 50, MIR = 50), age = c(68, 15, 25, 95), female = 0.55,
    pdx = list(b(80, "I26.99"), b(10, "I26.02"), b(10, "I26.09")),
    sdx = list(opt("I82.401", 0.15), opt("I82.402", 0.15), alt(w("C34.90" = 4, "C50.919" = 4, "C18.9" = 3, "C61" = 3, none = 86))),
    proc = list(opt("3E03317", 0.03)),
    los = c(7, 0.4), exitus = 0.04
  ),
  covid = prof(
    w = 8, service = w(MIR = 60, NML = 30, INF = 10), age = c(72, 16, 30, 99), uci = 0.06,
    pdx = list(b(70, c("U07.1", "J12.82")), b(10, c("U07.1", "J96.01")), b(20, c("U07.1", "J12.82", "J96.01"))),
    sdx = list(opt("E87.1", 0.05), opt("N17.9", 0.05), opt("R09.02", 0.1)),
    proc = list(opt("5A09457", 0.1), opt("5A1945Z", 0.04)),
    los = c(8, 0.5), exitus = 0.07
  ),
  neumotorax = prof(
    w = 2, service = w(NML = 50, CTO = 50), age = c(28, 8, 16, 50), female = 0.2,
    pdx = list(b(100, "J93.11", proc = "0W9930Z")),
    sdx = list(opt("F17.210", 0.5)),
    los = c(4, 0.4)
  ),
  derrame_pleural = prof(
    w = 2, service = "NML", age = c(72, 12, 40, 95),
    pdx = list(b(100, "J90", proc = "0W9930Z")),
    sdx = list(opt("I50.9", 0.3), opt("C34.90", 0.1)),
    los = c(6, 0.4), exitus = 0.04
  ),
  cancer_pulmon = prof(
    w = 5, service = w(NML = 50, ONC = 40, MIR = 10), age = c(69, 9, 45, 88), female = 0.25, urgent = 0.6, readmit = 0.06,
    pdx = list(b(40, "C34.90"), b(20, "C34.11"), b(20, "C34.31"), b(20, "C34.12")),
    sdx = list(opt("C79.51", 0.15), opt("C79.31", 0.1), opt("C77.1", 0.2), opt("J91.0", 0.2), opt("Z51.5", 0.25),
               opt("J44.9", 0.3), opt("E43", 0.1), opt("G89.3", 0.2), smoking),
    proc = list(opt("0BJ08ZZ", 0.35), opt("0BBK3ZX", 0.25), opt("0W9930Z", 0.1)),
    los = c(9, 0.5), exitus = 0.2, social = 0.05
  ),
  # -- infections --
  sepsis = prof(
    w = 30, service = w(MIR = 65, MIV = 10, GRT = 10, INF = 10, NML = 5), age = c(76, 14, 30, 99), uci = 0.12, readmit = 0.04,
    pdx = list(b(60, "A41.9"), b(20, "A41.51"), b(10, "A41.01"), b(5, "A41.02"), b(5, "A40.3")),
    sdx = list(alt(w("N39.0" = 35, "N10" = 15, "J18.9" = 30, "L03.115" = 8, "K81.0" = 5, "K80.30" = 4, none = 3)),
               opt("R65.20", 0.4), opt("R65.21", 0.12), opt("N17.9", 0.25), opt("E87.1", 0.08), opt("D69.6", 0.08),
               opt("J96.01", 0.1), opt("E86.0", 0.15), opt("F03.90", 0.1), opt("B96.20", 0.2)),
    proc = list(opt("5A1945Z", 0.05), opt("02HV33Z", 0.1), opt("30233N1", 0.05), opt("5A1D70Z", 0.02), opt("0T9B70Z", 0.1)),
    los = c(9, 0.55), exitus = 0.18, social = 0.03
  ),
  itu_joven = prof(
    w = 7, service = w(MIR = 50, URO = 20, GIN = 10, INF = 20), age = c(32, 9, 16, 55), female = 0.9,
    pdx = list(b(70, "N10"), b(30, "N39.0")),
    sdx = list(opt("B96.20", 0.5), opt("E86.0", 0.2)),
    los = c(3, 0.35)
  ),
  itu_mayor = prof(
    w = 23, service = w(MIR = 60, URO = 10, GRT = 25, NEF = 5), age = c(80, 9, 60, 99), female = 0.6, readmit = 0.05,
    pdx = list(b(65, "N39.0"), b(28, "N10"), b(7, "N30.00")),
    sdx = list(opt("B96.20", 0.5), opt("B96.89", 0.1), opt("N40.1", 0.3, sex = "1"), opt("N13.30", 0.05), opt("Z87.440", 0.1),
               opt("N17.9", 0.15), opt("E87.1", 0.08), opt("F03.90", 0.15), opt("E86.0", 0.2), opt("R33.9", 0.1)),
    proc = list(opt("0T9B70Z", 0.15), opt("0T9670Z", 0.03)),
    los = c(5, 0.45), exitus = 0.025, social = 0.04
  ),
  celulitis = prof(
    w = 8, service = w(MIR = 60, DER = 10, CIR = 20, INF = 10), age = c(62, 18, 18, 95), female = 0.45,
    pdx = list(b(40, "L03.115"), b(40, "L03.116"), b(10, "L02.415", proc = "0J9R0ZZ"), b(10, "L03.311")),
    sdx = list(opt("I87.2", 0.15), opt("E66.9", 0.2), opt("I89.0", 0.05), opt("B95.61", 0.1), opt("B95.0", 0.1)),
    los = c(6, 0.45), exitus = 0.01
  ),
  gea_adulto = prof(
    w = 6, service = w(MIR = 60, DIG = 30, INF = 10), age = c(55, 22, 16, 95),
    pdx = list(b(50, "A09"), b(20, "A08.4"), b(15, "A04.72"), b(15, "A02.0")),
    sdx = list(opt("E86.0", 0.5), opt("E87.1", 0.1), opt("N17.9", 0.15), opt("E87.6", 0.1)),
    los = c(4, 0.4), exitus = 0.01
  ),
  fiebre = prof(
    w = 3, service = "MIR", age = c(60, 20, 16, 95),
    pdx = list(b(60, "R50.9"), b(40, "B99.9")),
    los = c(4, 0.4)
  ),
  # -- neurology --
  ictus = prof(
    w = 24, service = w(NRL = 80, MIR = 20), age = c(74, 12, 35, 99), female = 0.48,
    pdx = list(b(30, "I63.9"), b(15, "I63.411"), b(15, "I63.412"), b(10, "I63.511"), b(10, "I63.512"), b(10, "I63.81"), b(10, "I63.30")),
    sdx = list(opt("G81.91", 0.3), opt("G81.94", 0.2), opt("R47.01", 0.2), opt("R13.12", 0.15), opt("R29.810", 0.15),
               opt("I48.20", 0.25), opt("Z86.73", 0.1), opt("J69.0", 0.04, "N"), opt("N39.0", 0.04, "N"), opt("I65.21", 0.1)),
    proc = list(opt("3E03317", 0.15), opt("03CG3ZZ", 0.08), opt("0DH67UZ", 0.08), opt("0DH63UZ", 0.02)),
    los = c(8, 0.5), exitus = 0.11, social = 0.08, transfer = 0.04
  ),
  ait = prof(
    w = 7, service = "NRL", age = c(73, 11, 45, 95),
    pdx = list(b(100, "G45.9")),
    sdx = list(opt("I48.0", 0.1), opt("Z86.73", 0.15), opt("I65.21", 0.1)),
    los = c(3, 0.35), exitus = 0.002
  ),
  hemorragia_cerebral = prof(
    w = 6, service = w(NRL = 50, NRC = 30, MIV = 20), age = c(70, 14, 40, 95), uci = 0.3,
    pdx = list(b(60, "I61.9"), b(20, "I61.0"), b(5, "I62.00", proc = "00C40ZZ"), b(5, "I62.00"), b(10, "I60.9")),
    sdx = list(opt("Z79.01", 0.25), opt("G81.91", 0.15), opt("G81.94", 0.15), opt("R40.20", 0.1), opt("G93.6", 0.1),
               opt("J69.0", 0.05, "N"), opt("G93.5", 0.05)),
    proc = list(opt("5A1945Z", 0.1), opt("5A1955Z", 0.05), opt("009600Z", 0.05), opt("0BH17EZ", 0.05)),
    los = c(10, 0.6), exitus = 0.25, social = 0.1, transfer = 0.05, surgery = c("00C40ZZ", "009600Z")
  ),
  epilepsia = prof(
    w = 6, service = "NRL", age = mix_age(0.25, c(1, 14), c(55, 20, 15, 95)),
    pdx = list(b(50, "G40.909"), b(15, "G40.901"), b(35, "R56.9")),
    sdx = list(opt("F10.20", 0.1), opt("G30.9", 0.08), opt("Z86.73", 0.08)),
    los = c(4, 0.45), exitus = 0.01
  ),
  sindrome_confusional = prof(
    w = 4, service = w(GRT = 50, MIR = 40, PSQ = 10), age = c(84, 7, 65, 100),
    pdx = list(b(100, "F05")),
    sdx = list(opt("F03.90", 0.5), opt("G30.9", 0.2), opt("N39.0", 0.25), opt("E86.0", 0.3), opt("E87.1", 0.15)),
    los = c(8, 0.45), exitus = 0.05, social = 0.15
  ),
  # -- digestive, medical --
  hda = prof(
    w = 12, service = w(DIG = 75, MIR = 20, CIR = 5), age = c(70, 16, 30, 99), female = 0.4,
    pdx = list(b(40, "K92.2"), b(20, "K25.4"), b(15, "K26.4"), b(10, "K92.1"), b(5, "K62.5"), b(10, "K57.31")),
    sdx = list(opt("D62", 0.55), opt("Z79.01", 0.25), opt("Z79.82", 0.2), opt("K70.30", 0.08), opt("N17.9", 0.08),
               opt("B96.81", 0.1), opt("K29.70", 0.1)),
    proc = list(opt("0DJ08ZZ", 0.85), opt("0DJD8ZZ", 0.3), opt("30233N1", 0.45)),
    los = c(5, 0.45), exitus = 0.03
  ),
  pancreatitis = prof(
    w = 8, service = w(DIG = 70, CIR = 30), age = c(62, 17, 25, 95), uci = 0.05,
    pdx = list(b(45, "K85.90"), b(35, c("K85.10", "K80.20")), b(20, c("K85.20", "F10.20"))),
    sdx = list(opt("E87.1", 0.08), opt("N17.9", 0.06), opt("E66.9", 0.12), opt("E87.6", 0.06)),
    proc = list(opt("0FC98ZZ", 0.06), opt("0FT44ZZ", 0.08)),
    los = c(7, 0.45), exitus = 0.02, surgery = "0FT44ZZ"
  ),
  cirrosis = prof(
    w = 6, service = "DIG", age = c(62, 11, 35, 85), female = 0.3, readmit = 0.08,
    pdx = list(b(40, "K70.31"), b(15, "K70.30"), b(20, "K74.60"), b(10, "K72.90"), b(5, "K76.7"), b(10, "I85.11", proc = "06L38CZ")),
    sdx = list(opt("F10.20", 0.55), opt("K76.82", 0.25), opt("E87.1", 0.2), opt("D69.6", 0.2), opt("N17.9", 0.15),
               opt("R18.8", 0.15), opt("K65.2", 0.08), opt("B18.2", 0.1), opt("K76.6", 0.3)),
    proc = list(opt("0W9G3ZZ", 0.45), opt("0DJ08ZZ", 0.3)),
    los = c(9, 0.5), exitus = 0.1
  ),
  obstruccion = prof(
    w = 6, service = w(CIR = 70, DIG = 30), age = c(70, 15, 25, 97),
    pdx = list(b(35, "K56.609"), b(25, "K56.690"), b(20, "K56.51"), b(20, "K56.7")),
    sdx = list(opt("Z90.49", 0.25), opt("E86.0", 0.3), opt("E87.6", 0.15), opt("K56.41", 0.1)),
    proc = list(opt("0DH67UZ", 0.4), opt("0DN84ZZ", 0.1)),
    los = c(6, 0.5), exitus = 0.02, surgery = "0DN84ZZ"
  ),
  diverticulitis = prof(
    w = 6, service = w(DIG = 55, CIR = 45), age = c(65, 15, 30, 95),
    pdx = list(b(70, "K57.32"), b(8, "K57.20"), b(7, "K57.20", proc = "0DTN4ZZ"), b(8, "K51.90"), b(7, "K50.90")),
    sdx = list(opt("E86.0", 0.1)),
    los = c(5, 0.45), exitus = 0.01, surgery = "0DTN4ZZ"
  ),
  via_biliar = prof(
    w = 5, service = w(DIG = 60, CIR = 40), age = c(72, 13, 35, 97),
    pdx = list(b(40, "K80.30"), b(30, "K80.50"), b(30, "K83.09")),
    sdx = list(opt("E87.1", 0.1), opt("R17", 0.2), opt("N17.9", 0.08), opt("K85.10", 0.05)),
    proc = list(opt("0FC98ZZ", 0.7), opt("0F798DZ", 0.25), opt("0FT44ZZ", 0.15)),
    los = c(7, 0.45), exitus = 0.03, surgery = "0FT44ZZ"
  ),
  # -- digestive, surgical --
  colecistectomia_programada = prof(
    w = 20, service = "CIR", age = c(56, 15, 22, 88), female = 0.6, urgent = 0, surgery = TRUE,
    pdx = list(b(60, "K80.10"), b(40, "K80.20")),
    sdx = list(opt("E66.9", 0.15)),
    proc = list(alt(w("0FT44ZZ" = 95, "0FT40ZZ" = 5))),
    los = c(1.8, 0.35)
  ),
  colecistectomia_urgente = prof(
    w = 10, service = "CIR", age = c(60, 16, 22, 92), female = 0.55, surgery = TRUE,
    pdx = list(b(70, "K80.00"), b(30, "K81.0")),
    sdx = list(opt("E66.9", 0.15), opt("K85.10", 0.03)),
    proc = list(alt(w("0FT44ZZ" = 85, "0FT40ZZ" = 15))),
    los = c(5, 0.45), exitus = 0.008
  ),
  apendicectomia = prof(
    w = 14, service = "CIR", age = mix_age(0.25, c(5, 14), c(32, 14, 15, 85)), female = 0.45, surgery = TRUE,
    pdx = list(b(55, "K35.80", los = c(2, 0.3)), b(20, "K35.30", los = c(3.5, 0.3)), b(15, "K35.32", los = c(5, 0.35)),
               b(10, "K35.33", los = c(7, 0.4))),
    sdx = list(opt("E66.9", 0.08)),
    proc = list(alt(w("0DTJ4ZZ" = 85, "0DTJ0ZZ" = 15))),
    exitus = 0.001
  ),
  hernia = prof(
    w = 16, service = "CIR", age = c(62, 15, 25, 90), female = 0.15, urgent = 0.2, surgery = TRUE,
    pdx = list(b(30, "K40.90", proc = "0YQ50ZZ"), b(30, "K40.90", proc = "0YQ60ZZ"), b(8, "K40.30", proc = "0YQ50ZZ", urgent = 1, los = c(3, 0.3)),
               b(7, "K40.31", proc = "0YQ60ZZ", urgent = 1, los = c(3, 0.3)), b(10, "K43.9", proc = "0WUF0JZ"), b(10, "K42.9", proc = "0WQF0ZZ"),
               b(5, "K40.91", proc = "0YU50JZ")),
    los = c(1.2, 0.3), exitus = 0.001
  ),
  cancer_colorrectal = prof(
    w = 10, service = "CIR", age = c(70, 10, 45, 90), female = 0.42, urgent = 0.1, uci = 0.3, uci_days = c(1, 2), surgery = TRUE,
    pdx = list(b(30, "C18.7", proc = "0DTN4ZZ", morph = w("8140/3" = 90, "8480/3" = 10)),
               b(20, "C18.2", proc = "0DTK4ZZ", morph = w("8140/3" = 90, "8480/3" = 10)),
               b(15, "C20", proc = c("0DTP4ZZ", "0D1B0Z4"), morph = "8140/3"),
               b(10, "C20", proc = "0DBP4ZZ", morph = "8140/3"),
               b(10, "C18.9", proc = "0DTN0ZZ", morph = "8140/3"),
               b(15, "C19", proc = "0DTN4ZZ", morph = "8140/3")),
    sdx = list(opt("D63.0", 0.2), opt("C78.7", 0.1), opt("D62", 0.1, "N"), opt("T81.41XA", 0.03, "N"), opt("K56.7", 0.05, "N")),
    proc = list(opt("30233N1", 0.1)),
    los = c(8, 0.4), exitus = 0.02
  ),
  otras_cirugia_digestiva = prof(
    w = 8, service = "CIR", age = c(60, 14, 25, 85), uci = 0.3, surgery = TRUE,
    pdx = list(b(25, "C16.9", proc = "0DT60ZZ", morph = "8140/3", urgent = 0.1, los = c(10, 0.35)),
               b(25, c("E66.01", "Z68.41"), proc = "0DB64Z3", urgent = 0, los = c(2.5, 0.3), female = 0.7, age = c(44, 10, 20, 65)),
               b(30, "K56.51", proc = "0DN84ZZ", urgent = 1, los = c(6, 0.4)),
               b(20, "K25.1", proc = "0DQ60ZZ", urgent = 1, los = c(8, 0.4))),
    sdx = list(opt("D62", 0.08, "N")),
    exitus = 0.02
  ),
  # -- trauma and orthopaedics --
  fractura_cadera = prof(
    w = 16, service = w(TRA = 85, GRT = 15), age = c(84, 8, 65, 103), female = 0.72, surgery = TRUE,
    pdx = list(b(22, "S72.001A", proc = "0SRR0J9"), b(22, "S72.002A", proc = "0SRS0J9"), b(3, "S72.001A", proc = "0SR90J9"),
               b(3, "S72.002A", proc = "0SRB0J9"), b(20, "S72.141A", proc = "0QS606Z"), b(20, "S72.142A", proc = "0QS706Z"),
               b(5, "S72.21XA", proc = "0QS606Z"), b(5, "S72.001A")),
    sdx = list(falls, opt("Y92.009", 0.6), opt("M81.0", 0.3), opt("D62", 0.25, "N"), opt("N17.9", 0.08, "N"), opt("F05", 0.1, "N"),
               opt("N39.0", 0.05, "N"), opt("J69.0", 0.02, "N"), opt("Z79.01", 0.15)),
    proc = list(opt("30233N1", 0.2)),
    los = c(10, 0.4), exitus = 0.05, social = 0.2, transfer = 0.05
  ),
  protesis_rodilla = prof(
    w = 22, service = "TRA", age = c(70, 7, 52, 86), female = 0.65, urgent = 0, surgery = TRUE,
    pdx = list(b(48, "M17.11", proc = "0SRC0J9"), b(48, "M17.12", proc = "0SRD0J9"), b(4, "M17.0", proc = "0SRC0J9")),
    sdx = list(opt("E66.9", 0.3), opt("D62", 0.1, "N")),
    los = c(4, 0.3), exitus = 0.001
  ),
  protesis_cadera = prof(
    w = 14, service = "TRA", age = c(68, 9, 45, 87), urgent = 0, surgery = TRUE,
    pdx = list(b(24, "M16.11", proc = "0SR90J9"), b(24, "M16.12", proc = "0SRB0J9"), b(24, "M16.11", proc = "0SR90JA"),
               b(24, "M16.12", proc = "0SRB0JA"), b(4, "M16.0", proc = "0SR90JA")),
    sdx = list(opt("E66.9", 0.2), opt("D62", 0.1, "N")),
    los = c(4, 0.3), exitus = 0.001
  ),
  otras_fracturas = prof(
    w = 12, service = "TRA", age = mix_age(0.3, c(5, 17), c(62, 20, 18, 95)), female = 0.55, urgent = 0.85,
    pdx = list(b(15, "S52.501A", proc = "0PSH04Z"), b(15, "S52.502A", proc = "0PSJ04Z"), b(15, "S82.61XA", proc = "0QSJ04Z"),
               b(10, "S42.301A", proc = "0PSF04Z"), b(10, "S42.201A", proc = "0PSC04Z"), b(10, "S32.000A"), b(10, "S22.32XA"),
               b(5, "S72.351A", proc = "0QS806Z"), b(10, "S82.201A", proc = "0QSG06Z")),
    sdx = list(alt(w("W19.XXXA" = 45, "W01.0XXA" = 20, "W18.30XA" = 10, "V18.4XXA" = 10, "W10.9XXA" = 5, "V43.52XA" = 10)),
               opt("Y92.009", 0.5), opt("M81.0", 0.15)),
    los = c(4, 0.5), exitus = 0.004, surgery = c("0PSH04Z", "0PSJ04Z", "0QSJ04Z", "0PSF04Z", "0PSC04Z", "0QS806Z", "0QSG06Z")
  ),
  columna = prof(
    w = 8, service = w(TRA = 60, NRC = 40), age = c(60, 13, 25, 85), urgent = 0.2,
    pdx = list(b(25, "M48.062", proc = "0SG00AJ"), b(15, "M48.062", proc = "0QB00ZZ"), b(40, "M51.16", proc = "0SB20ZZ"), b(20, "M54.50", urgent = 1)),
    los = c(4, 0.5), surgery = c("0SG00AJ", "0QB00ZZ", "0SB20ZZ")
  ),
  hombro_rodilla = prof(
    w = 7, service = "TRA", age = c(55, 12, 20, 80), urgent = 0.1, surgery = TRUE,
    pdx = list(b(50, "M75.101", proc = "0LQ04ZZ"), b(50, "S83.511A", proc = "0MQN4ZZ", age = c(30, 9, 16, 55))),
    los = c(1.5, 0.3)
  ),
  # -- urology --
  rtu_prostata = prof(
    w = 9, service = "URO", age = c(72, 7, 58, 90), female = 0, urgent = 0.15, surgery = TRUE,
    pdx = list(b(70, "N40.1", proc = "0VT08ZZ"), b(30, c("N40.1", "R33.8"), proc = "0VB08ZZ")),
    sdx = list(opt("Z87.440", 0.1), opt("D62", 0.05, "N")),
    los = c(3, 0.3)
  ),
  litiasis = prof(
    w = 7, service = "URO", age = c(50, 15, 20, 85), female = 0.4, urgent = 0.6,
    pdx = list(b(25, "N20.0"), b(25, "N20.0", proc = "0TF3XZZ"), b(20, "N20.1", proc = "0TC68ZZ"), b(15, "N20.1", proc = "0T9670Z"),
               b(15, "N13.2", proc = "0T9770Z")),
    sdx = list(opt("N10", 0.1), opt("N39.0", 0.1), opt("N17.9", 0.05)),
    los = c(3, 0.45), surgery = c("0TC68ZZ", "0T9670Z", "0T9770Z")
  ),
  vejiga_rtu = prof(
    w = 8, service = "URO", age = c(72, 9, 50, 92), female = 0.2, urgent = 0.2, surgery = TRUE,
    pdx = list(b(60, "C67.9", proc = "0TBB8ZZ", morph = w("8120/3" = 60, "8130/3" = 40)),
               b(20, "C67.2", proc = "0TBB8ZZ", morph = w("8120/3" = 60, "8130/3" = 40)),
               b(20, "D49.4", proc = "0TBB8ZZ")),
    sdx = list(opt("R31.9", 0.3), opt("Z87.891", 0.3)),
    los = c(3, 0.35)
  ),
  prostatectomia_nefrectomia = prof(
    w = 6, service = "URO", age = c(66, 7, 48, 80), urgent = 0.05, uci = 0.1, surgery = TRUE,
    pdx = list(b(60, "C61", proc = "0VT04ZZ", morph = "8140/3", female = 0), b(40, "C64.1", proc = "0TT04ZZ", morph = "8312/3", female = 0.35)),
    los = c(4, 0.35)
  ),
  # -- gynaecology and breast --
  histerectomia = prof(
    w = 9, service = "GIN", age = c(50, 8, 38, 72), female = 1, urgent = 0.05, surgery = TRUE,
    pdx = list(b(60, "D25.9", proc = "0UT94ZZ"), b(15, "N80.00", proc = "0UT94ZZ"),
               b(25, "C54.1", proc = c("0UT90ZZ", "0UT24ZZ", "0UT74ZZ"), morph = "8380/3", age = c(63, 9, 45, 85))),
    proc = list(opt("0UT24ZZ", 0.3), opt("0UT74ZZ", 0.4)),
    los = c(3, 0.3)
  ),
  mama = prof(
    w = 8, service = w(GIN = 60, CIR = 40), age = c(60, 12, 32, 88), female = 1, urgent = 0.02, surgery = TRUE,
    pdx = list(b(32, "C50.911", proc = c("0HBT0ZZ", "07B50ZX"), morph = w("8500/3" = 85, "8520/3" = 15)),
               b(32, "C50.912", proc = c("0HBU0ZZ", "07B60ZX"), morph = w("8500/3" = 85, "8520/3" = 15)),
               b(18, "C50.911", proc = c("0HTT0ZZ", "07T50ZZ"), morph = w("8500/3" = 85, "8520/3" = 15)),
               b(18, "C50.912", proc = c("0HTU0ZZ", "07T60ZZ"), morph = w("8500/3" = 85, "8520/3" = 15))),
    los = c(2, 0.3)
  ),
  # -- oncology and haematology --
  quimioterapia_ingreso = prof(
    w = 10, service = "ONC", age = c(58, 15, 18, 82), female = 0.48, urgent = 0.1, readmit = 0.1,
    pdx = list(b(25, c("Z51.11", "C92.00"), proc = "3E04305", morph = "9861/3", los = c(26, 0.3), service = "HEM"),
               b(20, c("Z51.11", "C83.30"), proc = "3E03305", morph = "9680/3", los = c(5, 0.3), service = "HEM"),
               b(10, c("Z51.11", "C91.00"), proc = "3E04305", morph = "9811/3", los = c(28, 0.3), service = "HEM", age = c(30, 14, 16, 70)),
               b(15, c("Z51.11", "C90.00"), proc = "3E03305", morph = "9732/3", los = c(4, 0.3), service = "HEM"),
               b(10, c("Z51.11", "C18.9"), proc = "3E03305", morph = "8140/3", los = c(3, 0.3)),
               b(10, c("Z51.11", "C34.90"), proc = "3E03305", morph = "8140/3", los = c(3, 0.3)),
               b(10, c("Z51.11", "C56.9"), proc = "3E03305", morph = "8441/3", los = c(3, 0.3), female = 1)),
    sdx = list(opt("D70.1", 0.15), opt("D61.810", 0.1), opt("R50.81", 0.1), opt("D69.59", 0.1), opt("E86.0", 0.05), opt("D62", 0.05)),
    proc = list(opt("02HV33Z", 0.1), opt("30233N1", 0.15), opt("30233R1", 0.1)),
    exitus = 0.03
  ),
  neutropenia_febril = prof(
    w = 5, service = w(ONC = 65, HEM = 35), age = c(60, 14, 20, 85),
    pdx = list(b(100, c("D70.1", "R50.81", "T45.1X5A"))),
    sdx = list(alt(w("C50.919" = 25, "C34.90" = 20, "C18.9" = 15, "C83.30" = 15, "C92.00" = 10, "C56.9" = 15)),
               opt("N39.0", 0.1), opt("J18.9", 0.15), opt("K12.30", 0.15), opt("E86.0", 0.15)),
    proc = list(opt("02HV33Z", 0.05)),
    los = c(6, 0.4), exitus = 0.04
  ),
  paliativos = prof(
    w = 6, service = w(ONC = 55, MIR = 25, UCP = 20), age = c(72, 12, 35, 97), female = 0.45, urgent = 0.9,
    pdx = list(b(20, "C25.9", morph = "8140/3"), b(25, "C34.90", morph = w("8140/3" = 50, "8070/3" = 35, "8041/3" = 15)),
               b(10, "C16.9", morph = "8140/3"), b(10, "C22.0", morph = "8170/3"), b(10, "C18.9", morph = "8140/3"),
               b(10, "C50.919", morph = "8500/3", female = 1), b(5, "C61", morph = "8140/3", female = 0), b(10, "C71.9", morph = "9440/3")),
    sdx = list(opt("Z51.5", 0.7), opt("C78.7", 0.3), opt("C79.51", 0.2), opt("C78.00", 0.15), opt("C79.31", 0.1), opt("E43", 0.2),
               opt("R18.0", 0.1), opt("G89.3", 0.3), opt("D63.0", 0.2), opt("E87.1", 0.1), opt("N17.9", 0.1), opt("R64", 0.1)),
    proc = list(opt("0W9G3ZZ", 0.1), opt("30233N1", 0.1)),
    los = c(10, 0.55), exitus = 0.5, social = 0.15
  ),
  hematologia = prof(
    w = 3, service = w(HEM = 45, MIR = 40, DIG = 15), age = c(68, 16, 18, 95), urgent = 0.6,
    pdx = list(b(40, "D64.9"), b(30, "D50.9"), b(15, "D69.3"), b(15, "C90.00", morph = "9732/3")),
    sdx = list(opt("N18.4", 0.1), opt("D63.1", 0.05)),
    proc = list(opt("30233N1", 0.6), opt("0DJ08ZZ", 0.3), opt("0DJD8ZZ", 0.3)),
    los = c(4, 0.4), exitus = 0.01
  ),
  # -- endocrine and renal --
  diabetes = prof(
    w = 6, service = w(END = 45, MIR = 55), age = mix_age(0.15, c(10, 17), c(58, 18, 18, 90)),
    pdx = list(b(30, "E11.10"), b(25, "E10.10", age = c(28, 12, 10, 60)), b(25, "E11.65"), b(10, "E11.641"), b(10, "E11.00")),
    sdx = list(opt("E87.1", 0.1), opt("E87.6", 0.1), opt("N17.9", 0.15), opt("Z79.4", 0.6), opt("E87.20", 0.1), opt("E86.0", 0.2)),
    los = c(5, 0.45), exitus = 0.01
  ),
  ira = prof(
    w = 7, service = w(NEF = 50, MIR = 50), age = c(77, 12, 45, 99),
    pdx = list(b(85, "N17.9"), b(15, "N17.0")),
    sdx = list(opt("E86.0", 0.35), opt("E87.1", 0.15), opt("E87.5", 0.2), opt("N18.30", 0.25), opt("N18.4", 0.15), opt("I50.9", 0.2),
               opt("N40.1", 0.15, sex = "1"), opt("R33.9", 0.1), opt("E87.20", 0.1)),
    proc = list(opt("5A1D70Z", 0.08), opt("0T9B70Z", 0.15)),
    los = c(6, 0.45), exitus = 0.04
  ),
  erc_dialisis = prof(
    w = 3, service = "NEF", age = c(70, 12, 40, 92), female = 0.4, urgent = 0.8, readmit = 0.1,
    pdx = list(b(30, c("T82.7XXA", "N18.6", "Z99.2")), b(20, c("T82.49XA", "N18.6", "Z99.2")), b(25, c("E87.70", "N18.6", "Z99.2")),
               b(25, c("E87.5", "N18.6", "Z99.2"))),
    sdx = list(opt("I12.0", 0.6), opt("E11.22", 0.4), opt("D63.1", 0.4), opt("I50.9", 0.25), opt("B95.61", 0.1)),
    proc = list(alt(w("5A1D70Z" = 1)), opt("02HV33Z", 0.3)),
    los = c(7, 0.45), exitus = 0.06
  ),
  otros_endocrino = prof(
    w = 2, service = w(MIR = 60, END = 40), age = c(66, 18, 20, 95),
    pdx = list(b(40, "E87.1"), b(20, "E05.00"), b(15, "E22.2"), b(25, "E16.2")),
    los = c(5, 0.45), exitus = 0.01
  ),
  # -- psychiatry --
  esquizofrenia = prof(
    w = 10, service = "PSQ", age = c(38, 12, 18, 70), female = 0.4, urgent = 0.85, hac = FALSE, readmit = 0.06,
    procedencia = w("21" = 75, "70" = 5, "50" = 10, "27" = 10),
    pdx = list(b(50, "F20.9"), b(20, "F20.0"), b(10, "F25.0"), b(10, "F23"), b(10, "F29")),
    sdx = list(opt("F17.210", 0.5), opt("F12.10", 0.2), opt("F19.10", 0.1), opt("F14.10", 0.08)),
    los = c(18, 0.5), ama = 0.05, transfer = 0.03
  ),
  depresion_bipolar = prof(
    w = 7, service = "PSQ", age = c(50, 18, 18, 88), female = 0.6, urgent = 0.8, hac = FALSE,
    pdx = list(b(30, "F32.2"), b(15, "F33.1"), b(20, "F33.2"), b(20, "F31.2"), b(15, "F31.9")),
    sdx = list(opt("F41.1", 0.15), opt("F60.3", 0.1), opt("R45.851", 0.3), opt("F17.210", 0.3), opt("F10.20", 0.1)),
    proc = list(opt("GZB0ZZZ", 0.05)),
    los = c(14, 0.5), ama = 0.05
  ),
  alcohol_toxicos = prof(
    w = 5, service = w(PSQ = 50, MIR = 40, DIG = 10), age = c(47, 11, 22, 75), female = 0.2, urgent = 0.85, hac = FALSE,
    pdx = list(b(50, "F10.239"), b(15, "F10.20"), b(15, "F10.231"), b(10, "F11.20"), b(10, "F14.20")),
    sdx = list(opt("K70.30", 0.2), opt("E51.2", 0.05), opt("F17.210", 0.6), opt("B18.2", 0.1), opt("K70.10", 0.1), opt("E87.6", 0.1)),
    proc = list(opt("HZ2ZZZZ", 0.6), opt("HZ33ZZZ", 0.2)),
    los = c(7, 0.5), ama = 0.1
  ),
  intento_autolitico = prof(
    w = 3, service = w(MIR = 60, PSQ = 30, MIV = 10), age = c(38, 16, 15, 85), female = 0.6, hac = FALSE,
    pdx = list(b(40, c("T42.4X2A", "F32.A")), b(20, c("T39.1X2A", "F32.A")), b(20, c("T43.222A", "F33.1")),
               b(10, c("T40.1X1A", "F11.20")), b(10, c("T51.0X1A", "F10.129"))),
    sdx = list(opt("F41.9", 0.2), opt("R45.851", 0.5), opt("R40.20", 0.1), opt("F60.3", 0.1)),
    los = c(2, 0.45), transfer = 0.1
  ),
  # -- paediatrics --
  bronquiolitis = prof(
    w = 10, service = "PED", age = function() if (bern(0.85)) 0 else 1, comorbid = FALSE, hac = FALSE, uci = 0.05,
    pdx = list(b(65, "J21.0"), b(35, "J21.9")),
    sdx = list(opt("J96.01", 0.08), opt("R09.02", 0.15), opt("E86.0", 0.1), opt("P07.37", 0.05), opt("H66.90", 0.1)),
    proc = list(opt("5A0935A", 0.2), opt("5A0945A", 0.15), opt("5A0955A", 0.05)),
    los = c(4, 0.4)
  ),
  gea_pediatrica = prof(
    w = 6, service = "PED", age = function() sample(0:6, 1), comorbid = FALSE, hac = FALSE,
    pdx = list(b(40, "A08.4"), b(25, "A08.0"), b(25, "A09"), b(10, "K52.9")),
    sdx = list(opt("E86.0", 0.6), opt("E87.20", 0.1), opt("E87.1", 0.05)),
    los = c(3, 0.35)
  ),
  neumonia_pediatrica = prof(
    w = 7, service = "PED", age = function() sample(1:14, 1), comorbid = FALSE, hac = FALSE,
    pdx = list(b(50, "J18.9"), b(20, "J15.7"), b(15, "J13"), b(10, "J18.1"), b(5, "J86.9", proc = "0W9930Z")),
    sdx = list(opt("J90", 0.05), opt("R09.02", 0.1), opt("J45.909", 0.1)),
    los = c(4, 0.4)
  ),
  asma_pediatrica = prof(
    w = 4, service = "PED", age = function() sample(2:14, 1), comorbid = FALSE, hac = FALSE,
    pdx = list(b(80, "J45.901"), b(20, "J45.21")),
    sdx = list(opt("J30.9", 0.15), opt("R09.02", 0.1)),
    los = c(3, 0.35)
  ),
  otros_pediatria = prof(
    w = 4, service = "PED", age = function() sample(0:10, 1), comorbid = FALSE, hac = FALSE,
    pdx = list(b(40, "R56.00"), b(20, "N39.0"), b(15, "J05.0"), b(10, "L01.00"), b(10, "K59.00"), b(5, "H66.90")),
    sdx = list(opt("B96.20", 0.1)),
    los = c(2, 0.4)
  ),
  # -- other --
  caida_contusion = prof(
    w = 5, service = w(MIR = 40, GRT = 30, NRC = 30), age = c(82, 9, 60, 100),
    pdx = list(b(30, "S06.0X0A"), b(10, "S06.0X1A"), b(20, "S00.93XA"), b(20, "S20.211A"), b(10, "S80.11XA"), b(10, "S06.5X0A")),
    sdx = list(falls, opt("Y92.009", 0.5), opt("Z79.01", 0.3), opt("F03.90", 0.25)),
    los = c(4, 0.5), exitus = 0.02, social = 0.05
  ),
  tvp_vascular = prof(
    w = 4, service = w(ACV = 60, MIR = 40), age = c(68, 15, 25, 95), urgent = 0.8,
    pdx = list(b(40, "I82.401"), b(30, "I82.402"), b(15, "I74.3", proc = "04CK0ZZ"), b(15, "I70.221", proc = "047K3DZ")),
    sdx = list(opt("Z79.01", 0.1), alt(w("C34.90" = 3, "C18.9" = 3, none = 94)), opt("I73.9", 0.2)),
    los = c(6, 0.45), exitus = 0.02, surgery = c("04CK0ZZ", "047K3DZ")
  ),
  pie_diabetico = prof(
    w = 2, service = w(ACV = 50, CIR = 30, END = 20), age = c(70, 10, 45, 90), female = 0.3, surgery = TRUE,
    pdx = list(b(40, c("E11.621", "L97.519"), proc = "0Y6N0Z0"), b(20, c("E11.52", "L97.519"), proc = "0Y6M0Z0"),
               b(20, c("E11.52", "I70.261"), proc = "0Y6H0Z1"), b(20, c("E11.621", "L97.519"), proc = "0HBMXZZ")),
    sdx = list(opt("E11.22", 0.3), opt("N18.4", 0.15), opt("I73.9", 0.2), opt("B95.61", 0.15), opt("Z79.4", 0.5), opt("M86.9", 0.2)),
    los = c(12, 0.5), exitus = 0.03
  ),
  anciano_fragil = prof(
    w = 6, service = w(GRT = 55, MIR = 45), age = c(86, 6, 70, 103), female = 0.6, readmit = 0.05,
    pdx = list(b(20, "E86.0"), b(10, "R53.1"), b(15, "E87.1"), b(10, "I95.9"), b(10, "E44.0"), b(5, "M62.81"), b(15, "J69.0"), b(15, "R41.0")),
    sdx = list(opt("F03.90", 0.4), opt("N39.0", 0.2), opt("Z74.09", 0.2), opt("R26.81", 0.2), opt("L89.152", 0.08), opt("L89.153", 0.03),
               opt("Z91.81", 0.2), opt("E43", 0.1), opt("R13.12", 0.1)),
    los = c(7, 0.5), exitus = 0.08, social = 0.15
  ),
  orl_tiroides = prof(
    w = 8, service = "ORL", age = c(45, 15, 18, 80), urgent = 0.2, surgery = TRUE,
    pdx = list(b(30, "J35.3", proc = "0CTPXZZ", age = function() sample(3:12, 1)), b(20, "J32.9", proc = "09BQ4ZZ"),
               b(20, "E04.1", proc = "0GTK0ZZ", service = "CIR", female = 0.8), b(10, "E04.2", proc = c("0GTK0ZZ", "0GTG0ZZ"), service = "CIR", female = 0.8),
               b(10, "J36", proc = "0C9PXZZ", urgent = 1), b(10, "C32.9", proc = "0CTS0ZZ", morph = "8070/3", female = 0.1, age = c(66, 8, 50, 85), los = c(10, 0.3))),
    los = c(2, 0.45)
  ),
  vascular_mayor = prof(
    w = 3, service = "ACV", age = c(74, 7, 60, 88), female = 0.15, urgent = 0.1, uci = 0.5, uci_days = c(1, 2), surgery = TRUE,
    pdx = list(b(50, "I71.40", proc = "04V03DZ"), b(50, "I65.21", proc = "03CH0ZZ")),
    los = c(5, 0.4), exitus = 0.02
  ),
  # -- other contact types --
  hospitalizacion_domicilio = prof(
    w = 10, service = "HAD", age = c(76, 12, 40, 97), urgent = 0, hac = FALSE, tipcont = "2", procedencia = w("24" = 70, "21" = 20, "10" = 10),
    pdx = list(b(30, "J44.1"), b(25, "I50.9"), b(25, "L03.115"), b(20, c("C34.90", "Z51.5"), morph = "8140/3", exitus = 0.3)),
    los = c(10, 0.4), exitus = 0.05
  ),
  hospital_dia = prof(
    w = 35, service = "ONC", age = c(62, 13, 20, 88), urgent = 0, hac = FALSE, tipcont = "3", procedencia = w("27" = 80, "24" = 20),
    pdx = list(b(30, c("Z51.11", "C50.919"), proc = "3E03305", morph = "8500/3", female = 1),
               b(25, c("Z51.11", "C18.9"), proc = "3E03305", morph = "8140/3"),
               b(15, c("Z51.11", "C34.90"), proc = "3E03305", morph = "8140/3"),
               b(10, c("Z51.11", "C83.30"), proc = "3E03305", morph = "9680/3", service = "HEM"),
               b(10, c("Z51.12", "C34.90"), proc = "3E0330M", morph = "8140/3"),
               b(10, "D50.9", proc = "3E033GC", service = "MIR")),
    los = c(0, 0)
  ),
  cirugia_ambulatoria = prof(
    w = 55, service = "CIR", age = c(60, 15, 18, 90), urgent = 0, hac = FALSE, tipcont = "4", surgery = TRUE, procedencia = w("27" = 1),
    pdx = list(b(17, "H25.11", proc = "08RJ3JZ", age = c(74, 8, 55, 92), service = "OFT"),
               b(18, "H25.12", proc = "08RK3JZ", age = c(74, 8, 55, 92), service = "OFT"),
               b(10, "K40.90", proc = "0YQ50ZZ", age = c(55, 15, 18, 85), female = 0.1),
               b(10, "K40.90", proc = "0YQ60ZZ", age = c(55, 15, 18, 85), female = 0.1),
               b(5, "N47.1", proc = "0VTTXZZ", age = function() sample(2:15, 1), female = 0, service = "CPE"),
               b(8, "G56.01", proc = "01N50ZZ", age = c(55, 12, 25, 80), female = 0.7, service = "TRA"),
               b(8, "M23.231", proc = "0SBC4ZZ", age = c(45, 13, 18, 70), service = "TRA"),
               b(6, "I83.811", proc = "06BQ0ZZ", age = c(52, 12, 25, 80), female = 0.7, service = "ACV"),
               b(5, "D17.1", proc = "0JB70ZZ", age = c(45, 15, 18, 80)),
               b(5, "N84.0", proc = "0UB98ZZ", age = c(48, 10, 30, 70), female = 1, service = "GIN"),
               b(4, "J35.1", proc = "0CTPXZZ", age = function() sample(3:12, 1), service = "ORL"),
               b(2, "Z30.2", proc = "0UL74ZZ", age = c(38, 5, 28, 46), female = 1, service = "GIN")),
    los = c(0, 0)
  )
)

# ---- one contact ---------------------------------------------------------------

medical_services <- c("MIR", "NML", "DIG", "NRL", "CAR", "INF", "END", "NEF", "HEM", "GRT", "ONC")

split_codes <- function(x) unlist(strsplit(x, "+", fixed = TRUE))

draw_contact <- function(name) {
  pr <- profiles[[name]]
  bd <- pr$pdx[[sample.int(length(pr$pdx), 1, prob = vapply(pr$pdx, function(x) x$w, numeric(1)))]]
  age <- rage(bd$age %||% pr$age)
  sex <- if (bern(bd$female %||% pr$female)) "2" else "1"
  dx <- bd$dx
  poa <- bd$poa %||% rep("S", length(dx))
  procs <- bd$proc %||% character()
  morph <- if (is.null(bd$morph)) character() else if (is.null(names(bd$morph))) bd$morph else pick(bd$morph)

  for (it in pr$sdx) {
    if (it$type == "opt") {
      if (!is.null(it$sex) && it$sex != sex) next
      if (bern(it$p)) { dx <- c(dx, it$code); poa <- c(poa, it$poa) }
    } else {
      ch <- pick(it$choices)
      if (ch != "none") { dx <- c(dx, ch); poa <- c(poa, "S") }
    }
  }
  if (any(grepl(female_only, dx))) sex <- "2" else if (any(grepl(male_only, dx))) sex <- "1"
  if (pr$comorbid) {
    cm <- comorbidities(age, sex)
    dx <- c(dx, cm); poa <- c(poa, rep("S", length(cm)))
  }
  for (it in pr$proc) {
    if (it$type == "opt") { if (bern(it$p)) procs <- c(procs, it$code) }
    else { ch <- pick(it$choices); if (nzchar(ch)) procs <- c(procs, split_codes(ch)) }
  }
  procs <- unique(procs)

  los <- if (pr$tipcont %in% c("3", "4")) 0L else as.integer(rlos(bd$los %||% pr$los))
  surgery <- pr$surgery
  surgical <- if (isTRUE(surgery)) length(procs) > 0 else if (is.character(surgery)) any(procs %in% surgery) else FALSE
  if (pr$hac) {
    h <- hospital_acquired(age, los, surgical)
    dx <- c(dx, h); poa <- c(poa, rep("N", length(h)))
  }

  # Tidy the diagnosis list: no duplicates, no contradictory pairs, 20 at most.
  keep <- !duplicated(dx)
  dx <- dx[keep]; poa <- poa[keep]
  drop <- rep(FALSE, length(dx))
  sec <- seq_along(dx) > 1
  has <- function(p) any(grepl(p, dx))
  if (sum(startsWith(dx, "E11")) > 1) drop <- drop | (sec & dx == "E11.9")
  if (sum(startsWith(dx, "I50")) > 1) drop <- drop | (sec & dx == "I50.9")
  if (has("^I1[135]")) drop <- drop | (sec & dx == "I10")
  if (has("^(E66.01)")) drop <- drop | (sec & dx == "E66.9")
  if (has("^G30")) drop <- drop | (sec & dx == "F03.90")
  if ("F17.210" %in% dx) drop <- drop | (sec & dx == "Z87.891")
  for (fam in c("^N18", "^I48", "^F10", "^J44", "^J96", "^N17", "^L89", "^E87\\.[16]", "^C34", "^C18", "^C50", "^J18", "^N39|^N10")) {
    hit <- which(grepl(fam, dx))
    if (length(hit) > 1) drop[hit[-1]] <- TRUE
  }
  dx <- dx[!drop]; poa <- poa[!drop]
  poa[grepl(poa_exempt, dx)] <- "E"
  if (length(dx) > 20) { dx <- dx[1:20]; poa <- poa[1:20] }
  procs <- utils::head(procs, 20)

  service <- bd$service %||% pr$service
  if (!is.character(service)) service <- pick(service)
  if (age < 15 && service %in% medical_services) service <- "PED"
  if (age < 15 && service == "CIR") service <- "CPE"
  if (age < 15 && service == "MIV") service <- "MIP"

  urgent <- bern(bd$urgent %||% pr$urgent)
  p_exitus <- (bd$exitus %||% pr$exitus) * if (age >= 85) 1.5 else 1
  outcome <- pick(w("4" = p_exitus, "2" = pr$transfer, "5" = pr$social, "3" = pr$ama,
                    "1" = max(0, 1 - p_exitus - pr$transfer - pr$social - pr$ama)))
  uci <- pr$tipcont == "1" && (service %in% c("MIV", "MIP", "MIN") || bern(bd$uci %||% pr$uci))
  uci_days <- if (uci) min(max(1L, los), as.integer(round(stats::runif(1, pr$uci_days[1], pr$uci_days[2])))) else NA_integer_

  list(profile = name, tipcont = pr$tipcont, age = age, sex = sex, dx = dx, poa = poa, procs = procs, morph = morph,
       los = los, surgical = surgical, service = service, urgent = urgent, outcome = outcome, uci = uci, uci_days = uci_days,
       procedencia = pr$procedencia, readmit = pr$readmit)
}

# ---- dates, identifiers and the exchange-file row -------------------------------

month_days <- seq(as.Date("2024-05-01"), as.Date("2024-05-31"), by = "day")
weekday_weight <- c(1, 1, 1, 1, 1, 0.45, 0.3)[as.integer(format(month_days, "%u"))]
rdate <- function() month_days[sample.int(length(month_days), 1, prob = weekday_weight)]
rtime <- function(hours, weights = NULL) sprintf("%02d%02d", sample(hours, 1, prob = weights), sample(0:59, 1))
rtime_between <- function(lo = "0000", hi = "2359") {
  lo_m <- as.integer(substr(lo, 1, 2)) * 60 + as.integer(substr(lo, 3, 4))
  hi_m <- as.integer(substr(hi, 1, 2)) * 60 + as.integer(substr(hi, 3, 4))
  m <- if (hi_m - lo_m < 2) lo_m else sample(seq(lo_m + 1, hi_m - 1), 1)
  sprintf("%02d%02d", m %/% 60, m %% 60)
}
fmt_date <- function(d) format(d, "%d%m%Y")
fmt_datetime <- function(d, hhmm) paste(fmt_date(d), hhmm)
add_hours <- function(d, hhmm, hours) {
  t <- as.POSIXct(paste(format(d), substr(hhmm, 1, 2), substr(hhmm, 3, 4)), format = "%Y-%m-%d %H %M", tz = "UTC") + hours * 3600
  list(date = as.Date(t, tz = "UTC"), hhmm = format(t, "%H%M"))
}

postcodes <- w("47001" = 6, "47002" = 6, "47003" = 6, "47004" = 5, "47005" = 6, "47006" = 5, "47007" = 5, "47008" = 5,
               "47009" = 5, "47010" = 6, "47011" = 5, "47012" = 5, "47013" = 4, "47014" = 6, "47015" = 4, "47016" = 4,
               "47100" = 2, "47130" = 1, "47153" = 2, "47195" = 3, "47300" = 2, "47400" = 3, "47700" = 2, "47800" = 2,
               "34001" = 1, "49001" = 1, "40001" = 1, "53FRA" = 0.3, "53GBR" = 0.3, "53DEU" = 0.2)
countries <- w(ESP = 86, MAR = 4, ROU = 2, COL = 2, ECU = 1, GBR = 1, VEN = 1, CHN = 0.5, PER = 0.5, BGR = 0.5, DOM = 0.5, ZZZ = 1)
rid <- function(n) paste(sample(c(0:9, LETTERS), n, replace = TRUE), collapse = "")

newborn <- function(c) c$age == 0 && c$profile %in% c("recien_nacido", "prematuro")

new_patient <- function(c, admission) {
  regfin <- pick(w("1" = 93, "3" = 3, "5" = 1, "7" = 2, "9" = 1))
  if (regfin == "5" && !any(startsWith(c$dx, "V"))) regfin <- "1"
  birth <- if (newborn(c)) admission
           else if (c$age == 0) admission - sample(20:360, 1)
           else admission - c$age * 365.25 - sample(0:364, 1)
  list(
    tip_cip = if (regfin == "3") "3" else pick(w("2" = 94, "1" = 3, "5" = 1, "6" = 1, "9" = 1)),
    cip = rid(16), historia = sprintf("%07d", sample.int(9999999, 1)),
    sex = c$sex, age = c$age, birth = birth,
    pais = if (newborn(c)) "ESP" else pick(countries),
    cp = pick(postcodes), regfin = regfin
  )
}

make_row <- function(c, patient, discharge = NULL) {
  discharge <- discharge %||% rdate()
  admission <- discharge - c$los
  urgent_inpatient <- c$tipcont == "1" && c$urgent
  adm_time <- if (newborn(c)) rtime(0:23)
              else if (urgent_inpatient) rtime(0:23, c(rep(1, 8), rep(3, 14), 2, 2))
              else if (c$tipcont %in% c("3", "4")) rtime(8:10) else rtime(7:9)
  dis_time <- if (c$outcome == "4") rtime(0:23) else if (c$tipcont %in% c("3", "4")) rtime(12:19) else rtime(10:16, c(1, 2, 3, 3, 2, 1, 1))
  if (c$los == 0 && dis_time <= adm_time) dis_time <- sprintf("%02d%02d", as.integer(substr(adm_time, 1, 2)) + 3, sample(0:59, 1))
  # Time window of a day of the stay: after arrival on the first day, before leaving on the last.
  within_stay <- function(day, lo, hi) {
    rtime_between(if (day == admission) max(lo, adm_time) else lo, if (day == discharge) min(hi, dis_time) else hi)
  }

  procedencia <- if (!is.null(c$procedencia)) pick(c$procedencia)
                 else if (c$tipcont == "1" && c$urgent) pick(w("21" = 88, "50" = 6, "30" = 4, "40" = 2))
                 else pick(w("27" = 80, "10" = 5, "24" = 3, "30" = 12))
  fecinghosp <- if (urgent_inpatient && procedencia %in% c("21", "50", "40")) {
    o <- add_hours(admission, adm_time, stats::runif(1, 2, 14))
    if (o$date > discharge || (o$date == discharge && o$hhmm >= dis_time)) o <- list(date = discharge, hhmm = rtime_between("0000", dis_time))
    fmt_datetime(o$date, o$hhmm)
  } else ""
  fecint <- if (c$surgical) {
    delay <- if (c$urgent) pick(w("0" = 45, "1" = 35, "2" = 15, "3" = 5)) else "0"
    day <- admission + min(as.integer(delay), c$los)
    fmt_datetime(day, within_stay(day, "0800", "2000"))
  } else ""
  dispositivo <- if (c$outcome == "4") "1" else if (c$outcome %in% c("2", "5")) "8"
                 else if (c$tipcont == "3") pick(w("4" = 90, "6" = 10))
                 else if (c$profile %in% c("quimioterapia_ingreso", "neutropenia_febril", "cancer_pulmon", "paliativos")) pick(w("4" = 45, "6" = 45, "3" = 10))
                 else pick(w("6" = 62, "1" = 25, "4" = 2, "3" = 3, "8" = 8))
  procext <- if (procedencia == "30" && c$profile == "iam") "4A023N7" else if (procedencia == "30" && c$profile == "ictus") "B030ZZZ" else ""

  dxs <- c(c$dx, rep("", 20 - length(c$dx)))
  poas <- c(c$poa, rep("", 20 - length(c$poa)))
  prs <- c(c$procs, rep("", 20 - length(c$procs)))
  row <- c(
    TIP_CIP = patient$tip_cip, CIP = patient$cip, HISTORIA = patient$historia, FECNAC = fmt_date(patient$birth), SEXO = patient$sex,
    PAIS_NAC = patient$pais, RESIDE_CP = patient$cp, RESIDE_MUNI = "", REGFIN = patient$regfin,
    FECINICONT = fmt_datetime(admission, adm_time), FECINGHOSP = fecinghosp, TIPCONT = c$tipcont,
    TIPVISITA = if (c$tipcont == "3") c$tipvisita %||% "2" else "",
    PROCEDENCIA = procedencia, CIRCONT = if (c$urgent) "1" else "2", SERVICIO = c$service,
    FECFINCONT = fmt_datetime(discharge, dis_time), TIPALT = c$outcome, DISPOSITIVO_CONTINUIDAD = dispositivo,
    FECINT = fecint, UCI = if (c$tipcont == "1") (if (c$uci) "1" else "2") else "",
    DIAS_UCI = if (c$uci) as.character(c$uci_days) else ""
  )
  row <- c(row, stats::setNames(as.vector(rbind(dxs, poas)), paste0(rep(c("D", "POAD"), 20), rep(1:20, each = 2))))
  row <- c(row, stats::setNames(prs, paste0("PROC", 1:20)))
  row <- c(row, stats::setNames(c(procext, rep("", 5)), paste0("PROCEXT", 1:6)))
  row <- c(row, stats::setNames(c(c$morph, rep("", 6 - length(c$morph))), paste0("M", 1:6)))
  c(row, CEN_SAN = "SYN000001", CCAA = "07")
}

# ---- generate ------------------------------------------------------------------

n_total <- 1000
weights <- vapply(profiles, function(p) p$w, numeric(1))
counts <- as.vector(stats::rmultinom(1, n_total, weights))
names(counts) <- names(profiles)

rows <- list()
patients <- list()   # by profile: patients seen so far, with the days of their contacts, for readmissions
for (name in names(profiles)) {
  k <- counts[[name]]
  if (k == 0) next
  i <- 0
  while (i < k) {
    c <- draw_contact(name)
    if (c$tipcont == "3") {
      # Day-hospital patients come for several sessions in the month.
      sessions <- min(k - i, sample(1:4, 1, prob = c(0.35, 0.3, 0.2, 0.15)))
      first <- month_days[sample.int(14, 1)]
      gap <- sample(c(7, 14), 1, prob = c(0.7, 0.3))
      patient <- new_patient(c, first)
      for (s in seq_len(sessions)) {
        c$tipvisita <- if (s == 1 && bern(0.3)) "1" else "2"
        d <- first + (s - 1) * gap
        if (d > max(month_days)) break
        rows[[length(rows) + 1]] <- make_row(c, patient, d)
        i <- i + 1
      }
      next
    }
    linked <- FALSE
    if (c$readmit > 0 && bern(c$readmit) && length(patients[[name]]) > 0) {
      cands <- which(vapply(patients[[name]], function(p) p$patient$sex == c$sex && abs(p$patient$age - c$age) <= 3, logical(1)))
      if (length(cands) > 0) {
        j <- cands[[sample.int(length(cands), 1)]]
        prev <- patients[[name]][[j]]
        for (try in 1:20) {
          d <- rdate()
          days <- seq(d - c$los, d, by = "day")
          if (!any(days %in% prev$days)) {
            c$age <- prev$patient$age
            rows[[length(rows) + 1]] <- make_row(c, prev$patient, d)
            patients[[name]][[j]]$days <- c(prev$days, days)
            linked <- TRUE
            break
          }
        }
      }
    }
    if (!linked) {
      d <- rdate()
      patient <- new_patient(c, d - c$los)
      rows[[length(rows) + 1]] <- make_row(c, patient, d)
      patients[[name]] <- c(patients[[name]], list(list(patient = patient, days = seq(d - c$los, d, by = "day"))))
    }
    i <- i + 1
  }
}

out <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
stopifnot(identical(names(out), cmbd_rd69_columns))
ord <- order(as.Date(substr(out$FECFINCONT, 1, 8), "%d%m%Y"), substr(out$FECFINCONT, 10, 13), out$HISTORIA)
out <- out[ord, ]
rownames(out) <- NULL

# ---- checks --------------------------------------------------------------------

tbl <- msdrg_tables("44.0")
dx_used <- unique(unlist(out[paste0("D", 1:20)])); dx_used <- dx_used[nzchar(dx_used)]
pr_used <- unique(unlist(out[c(paste0("PROC", 1:20), paste0("PROCEXT", 1:6))])); pr_used <- pr_used[nzchar(pr_used)]
bad_dx <- setdiff(gsub(".", "", dx_used, fixed = TRUE), tbl$dx_codes$code)
bad_pr <- setdiff(pr_used, tbl$pr_codes$code)
if (length(bad_dx) || length(bad_pr)) stop("Codes not in MS-DRG v44.0: ", paste(c(bad_dx, bad_pr), collapse = " "))
if (!is.null(fy2023_dir)) {
  cm <- substr(readLines(file.path(fy2023_dir, "icd10cm_codes_2023.txt")), 1, 8)
  pcs <- substr(readLines(file.path(fy2023_dir, "icd10pcs_codes_2023.txt")), 1, 7)
  bad_dx <- setdiff(gsub(".", "", dx_used, fixed = TRUE), trimws(cm))
  bad_pr <- setdiff(pr_used, trimws(pcs))
  if (length(bad_dx) || length(bad_pr)) stop("Codes not in FY2023 (CIE-10-ES 2024): ", paste(c(bad_dx, bad_pr), collapse = " "))
  cat("All", length(dx_used), "diagnosis and", length(pr_used), "procedure codes exist in FY2023 and v44.0 tables\n")
}

# ---- write ---------------------------------------------------------------------

dir.create(file.path("inst", "extdata", "cmbd"), recursive = TRUE, showWarnings = FALSE)
path <- file.path("inst", "extdata", "cmbd", "rae-cmbd-synthetic.txt")
utils::write.table(out, path, sep = "|", quote = FALSE, row.names = FALSE, col.names = TRUE, na = "", eol = "\n", fileEncoding = "UTF-8")
cat("Wrote", path, "(", nrow(out), "rows,", ncol(out), "columns,", round(file.size(path) / 1024), "KB )\n")

# ---- summary -------------------------------------------------------------------

rae <- cmbd_read(path)
hosp <- rae[rae$TIPCONT == "1", ]
los <- as.numeric(as.Date(substr(hosp$FECFINCONT, 1, 8), "%d%m%Y") - as.Date(substr(hosp$FECINICONT, 1, 8), "%d%m%Y"))
inp <- cmbd_to_msdrg(hosp)
cat(sprintf("Contacts by type: %s\n", paste(names(table(rae$TIPCONT)), table(rae$TIPCONT), sep = "=", collapse = " ")))
cat(sprintf("Hospitalisations: %d; mean age %.1f; female %.0f%%; urgent %.0f%%; mean stay %.1f days; died %.1f%%; ICU %.1f%%; mean diagnoses %.1f; with procedures %.0f%%\n",
            nrow(hosp), mean(inp$claims$age), 100 * mean(hosp$SEXO == "2"), 100 * mean(hosp$CIRCONT == "1"), mean(los),
            100 * mean(hosp$TIPALT == "4"), 100 * mean(hosp$UCI == "1"), mean(table(inp$diagnoses$claim_id)),
            100 * mean(!is.na(hosp$PROC1))))
g <- group(grouper("msdrg", version = "44.0"), inp, poa_exempt = "non_exempt")
cat("Return codes:", paste(names(table(g$return_code)), table(g$return_code), sep = "=", collapse = " "), "\n")
top <- utils::head(dplyr::count(g, drg, drg_description, sort = TRUE), 15)
print(as.data.frame(top), right = FALSE, row.names = FALSE)
