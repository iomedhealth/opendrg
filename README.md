# opendrg

<!-- badges: start -->
[![R-CMD-check](https://github.com/iomedhealth/opendrg/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/iomedhealth/opendrg/actions/workflows/R-CMD-check.yaml)
<!-- badges: end -->

Open, portable implementations of hospital casemix groupers in R.

Casemix groupers assign hospital stays to payment/costing groups — DRGs in the
US, HRGs in England — from diagnosis and procedure codes. The official
implementations ship as platform-specific binaries. `opendrg` re-implements
them as **published logic tables + a small evaluation engine** in plain R, so
grouping can run anywhere R runs, on data frames, and (by design) eventually
inside databases through dbplyr.

| Grouper | Status | Validation |
|---|---|---|
| CMS **MS-DRG** v43.0, v43.1 (FY 2026), v44.0 (FY 2027) | Working | 9,864 / 9,864 CMS TESTDB claims identical to CMS's grouper for every version: final & initial DRG, MDC, return code, severity, HAC handling |
| NHS England **HRG4+** 2024/25 National Costs (admitted patient care) | Working | 750 / 750 official test episodes and 477 / 477 spells identical to NHS England's expected results: episode & spell HRG, grouping method, dominant procedure, unbundled HRGs, PBC |

## Usage

```r
# remotes::install_github("iomedhealth/opendrg")
library(opendrg)

claims <- data.frame(claim_id = 1, age = 67, sex = "M", discharge_status = "01")
diagnoses <- data.frame(
  claim_id = 1, seq = 1:3,                 # seq 1 = principal diagnosis
  code = c("I21.4", "E11.9", "N17.9"),     # ICD-10-CM, dots optional
  poa = c("Y", "Y", "N")                   # present-on-admission indicator
)
procedures <- data.frame(claim_id = 1, seq = 1, code = "02703ZZ")   # ICD-10-PCS

g <- grouper("msdrg", version = "44.0")
group(g, claims, diagnoses, procedures)
#>   claim_id drg initial_drg base_drg mdc med_surg severity return_code ...

# HRG4+ admitted patient care: episodes in the standard APC layout
h <- grouper("hrg4plus", version = "2024-25-nc")
res <- group(h, episodes)      # DIAG_01.., OPER_01.., STARTAGE, SEX, EPIDUR, ...
res$episodes                   # fce_hrg, grouping_method, dominant_procedure, unbundled_hrgs, spell_hrg, ...
res$spells
```

Inputs are long-format data frames (one row per claim / diagnosis /
procedure) so they map directly onto database tables; outputs are one row per
claim.

## How it works

CMS and NHS England both publish the complete grouping logic as data:

* **MS-DRG**: the mainframe release contains `DRGLOGIC` (one boolean formula
  per DRG, e.g. `(PDX:dxc0306) & (MCC)`), diagnosis/procedure attribute
  patterns, the CC/MCC exclusion list and procedure clusters. `opendrg`
  compiles the formulas to dplyr expressions and evaluates them in CMS's order
  (pre-MDC → principal-diagnosis MDC → reroutes), with the same severity,
  exclusion, cluster and hospital-acquired-condition rules as the Java
  reference implementation.
* **HRG4+**: the *Code to Group* workbook contains the code→HRG-root mapping,
  root→split rules, formal condition flags (`Simple Flags`) and every code
  list they reference. `opendrg` forms combination codes, derives unbundled
  HRGs, picks the dominant procedure by hierarchy, applies the burns /
  multiple-trauma / procedure / global-exception / diagnosis precedence and
  the split rules, then groups spells from a pseudo-record of the dominant
  episode — exactly as NHS England's grouper does on its published test data.

New releases are imported with `msdrg_import_cms()` /
`hrg_import_code_to_group()`; the engines do not change.

## Validation

`dev/oracle/` contains a harness that runs CMS's own Java grouper (shipped in
the mainframe package) over CMS's 9,864-claim test database on any JVM. The
package test-suite asserts byte-for-byte agreement with that output.
`dev/notes/` holds the engine specifications extracted from the reference
implementations.

## Licensing

Package code is MIT. Bundled logic tables are derived from publicly released
government data:

* CMS MS-DRG tables are a work of the US federal government (public domain).
* HRG4+ tables are derived from NHS England's *Code to Group* workbooks and
  contain public sector information licensed under the
  [Open Government Licence v3.0](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).
  © NHS England.

ICD-10-CM/PCS, ICD-10 and OPCS-4 **descriptions** are not bundled — only the
codes the logic needs.
