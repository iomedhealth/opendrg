# opendrg

<!-- badges: start -->
[![R-CMD-check](https://github.com/iomedhealth/opendrg/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/iomedhealth/opendrg/actions/workflows/R-CMD-check.yaml)
<!-- badges: end -->

**opendrg** is an R package that assigns hospital stays to the *casemix groups*
used for hospital payment and costing — the **MS-DRGs** used by Medicare in the
United States and the **HRG4+** groups and **Prescribed Specialised Services**
flags used by the NHS in England — without the official Windows, mainframe or
Java software. It gives the same answers as the official tools (checked record
by record against their own test data), runs anywhere R runs, and is open
source.

## What is a casemix grouper?

When a patient leaves hospital, the stay is summarised as a handful of codes:
what was wrong with them (diagnoses), what was done to them (procedures), plus
their age and sex, how they were admitted, how they left and how long they
stayed. For example:

| | Code | Meaning |
|---|---|---|
| Main diagnosis | `I21.4` | Heart attack (non-ST-elevation myocardial infarction) |
| Other diagnoses | `E11.9`, `N17.9` | Type 2 diabetes; acute kidney injury |
| Procedure | `02703ZZ` | Widening a blocked coronary artery through the skin (angioplasty) |
| Patient | 67, male, discharged home | |

A **casemix grouper** is a deterministic program that turns those codes into
one of a few hundred (or few thousand) *groups* of stays that are clinically
similar and cost roughly the same to treat. The stay above lands in MS-DRG 251,
*"Percutaneous cardiovascular procedures without intraluminal device without
MCC"*. Take away the angioplasty and it lands in DRG 281, *"Acute myocardial
infarction, discharged alive with CC"*.

Groups matter because they are the unit that hospitals are paid by (a fixed
price per group), the unit they are compared on, and the standard way to adjust
for "how sick the patients were" in research. Different countries use different
systems:

* **United States — MS-DRG** (*Medicare Severity Diagnosis Related Groups*),
  about 770 groups maintained by CMS, the federal Medicare agency.
* **England — HRG4+** (*Healthcare Resource Groups*), about 2,900 groups
  maintained by NHS England's National Casemix Office, covering inpatient stays
  and also outpatient, emergency, critical-care and renal activity.
* **England — Prescribed Specialised Services (PSS)**: not groups but *flags*.
  NHS England directly commissions over 160 specialised services (rare
  cancers, transplants, complex neurosurgery, …) and publishes rules that
  identify which stays and outpatient attendances belong to each service line.

## Why this package exists

The official groupers ship as platform-bound programs: CMS distributes a
mainframe module and a Java library, NHS England a 32-bit Windows desktop
application that reads encrypted data files. That makes grouping awkward to
embed in an analytical pipeline, impossible to run inside a database or on a
Mac/Linux server, and hard to inspect when a result looks wrong.

They also all work the same way: you export the raw patient records to a file,
feed the file to the program, and read the groups back. That is incompatible
with how modern health-data infrastructures are run. In federated research
networks built on the [OMOP Common Data Model](https://ohdsi.github.io/CommonDataModel/)
(OHDSI, DARWIN EU, EHDEN, …) the patient-level data never leaves the hospital's
database: the analysis code travels to the data, runs there, and only
aggregate results come back. A grouper that needs the raw data on a Windows
desktop cannot take part in that; a grouper expressed as tables and dplyr
logic can travel with the study code, run at each site against its
`condition_occurrence` and `procedure_occurrence` tables (in R today, pushed
down into the database through dbplyr as the next step), and still give the
official answer.

The key observation behind opendrg is that both agencies already **publish the
complete grouping logic as data**: CMS as flat files with one formula per DRG,
NHS England as Excel workbooks listing every rule and code list. opendrg
imports those tables unchanged and evaluates them with a small engine. There
are no hand-written grouping rules in the package; a new yearly release is
imported with one function call.

## What is included

| System | Versions bundled | How it is verified |
|---|---|---|
| CMS **MS-DRG** | 43.0 and 43.1 (fiscal year 2026), 44.0 (fiscal year 2027) | All 9,864 claims of CMS's own test database produce the same DRG, MDC, severity and return code as CMS's Java grouper, for every version |
| NHS England **HRG4+** | 2024/25 National Costs, 2025/26 Local Payment | Every record of NHS England's official test data gives the published expected result, for all seven datasets: inpatient episodes and spells, outpatients, emergency medicine, adult / paediatric / neonatal critical care, renal (2,250 records) |
| NHS England **Prescribed Specialised Services** | 2025/26, 2025/26 Version 2 | Every record of NHS England's official sample data gives the published service lines, dominant line and programme of care, for inpatients (300 episodes) and outpatients (200 attendances) |

Also included:

* **OMOP CDM** adapters and groupers for both **MS-DRG** (`omop_to_msdrg()`,
  `omop_msdrg()`, `omop_msdrg_quality()`) and **NHS England HRG4+ / PSO**
  (`omop_to_hrg()`, `omop_hrg()`, `omop_hrg_quality()`) that accept a
  `CDMConnector` `cdm_reference` or `CohortConstructor` `cohort_table` directly,
  execute lazy read-only `dbplyr` queries inside the site's database, and group
  inpatient stays with explicit principal-diagnosis strategies and a
  data-quality report (see [OMOP CDM (`CDMConnector`)](#omop-cdm-cdmconnector)).
* An adapter from the Spanish discharge register (CMBD / RAE-CMBD) to the
  MS-DRG input, a reader for its exchange files and a synthetic 1,000-contact
  extract to try them on (see
  [Spanish hospital data](#spanish-hospital-data-cmbd--rae-cmbd)).

## Installation

```r
# install.packages("remotes")
remotes::install_github("iomedhealth/opendrg")
```

The package depends only on R (≥ 4.1) and the tidyverse core packages. No
Java, .NET or Windows required.

## Quick start

Every system is used the same way: create a `grouper()` for a system and
version, then `group()` your data.

### MS-DRG (United States)

Input is three plain data frames — one row per stay ("claim"), one row per
diagnosis, one row per procedure — which is how such data usually sits in a
database.

```r
library(opendrg)

claims <- data.frame(claim_id = 1, age = 67, sex = "M", discharge_status = "01")
diagnoses <- data.frame(
  claim_id = 1, seq = 1:3,                 # seq 1 = principal (main) diagnosis
  code = c("I21.4", "E11.9", "N17.9"),     # ICD-10-CM; dots optional
  poa  = c("Y", "Y", "N")                  # present on admission?
)
procedures <- data.frame(claim_id = 1, seq = 1, code = "02703ZZ")   # ICD-10-PCS

g <- grouper("msdrg", version = "44.0")
g
#> <opendrg grouper> CMS MS-DRG, version 44.0
#> 768 DRGs, 794 logic rows, 74,966 diagnosis codes, 83,380 procedure codes

res <- group(g, claims, diagnoses, procedures)
res[c("claim_id", "drg", "mdc", "med_surg", "severity", "return_code", "drg_description")]
#>   claim_id   drg   mdc med_surg severity return_code drg_description
#> 1        1   251     5 S        CC                 0 PERCUTANEOUS CARDIOVASCULAR PROCEDURES WITHOUT INTRALUMINAL DEVICE WITHOUT MCC
```

What the output columns mean:

* `drg` — the final MS-DRG; `drg_description` is CMS's title for it.
* `mdc` — the *Major Diagnostic Category*, one of 25 body-system chapters
  (5 = circulatory system) chosen from the principal diagnosis.
* `med_surg` — `S` if an operating-room procedure put the stay on the
  surgical side of the chapter, `M` otherwise.
* `severity` — `MCC`, `CC` or `none`: the most serious secondary diagnosis
  that counted (here the kidney injury is a *complication or comorbidity*,
  which is why the stay is not in the "with MCC" DRG 250).
* `initial_drg` — the DRG before the *hospital-acquired condition* rule: if a
  listed condition was not present on admission (`poa = "N"`) it is ignored
  for severity, so the final `drg` can differ from the initial one.
* `return_code` — 0 means grouped normally; other values explain why a claim
  could not be grouped (invalid principal diagnosis, invalid sex, …), in
  which case `drg` is 998 or 999.

### HRG4+ (England, inpatients)

Input is one row per *episode* — a continuous period under one consultant —
using the standard NHS column names (the same ones the official grouper and
HES/SUS extracts use). Episodes with the same provider code (`PROCODET`) and
spell number (`PROVSPNO`) form one *spell*, i.e. one hospital stay.

```r
episodes <- data.frame(
  PROCODET = "RXX", PROVSPNO = "1001", EPIORDER = "1",     # provider, stay, episode number
  STARTAGE = "72", SEX = "2",                              # 72-year-old woman
  CLASSPAT = "1", ADMISORC = "19", ADMIMETH = "11",        # ordinary admission, elective, from home
  DISDEST = "19", DISMETH = "1", EPIDUR = "4",             # discharged home after 4 nights
  MAINSPEF = "110", TRETSPEF = "110", NEOCARE = "8",       # trauma & orthopaedics
  DIAG_01 = "M161", DIAG_02 = "I10X",                      # hip osteoarthritis; hypertension
  OPER_01 = "W371", OPER_02 = "Z843",                      # cemented total hip replacement; hip joint
  CRITICALCAREDAYS = "0", REHABILITATIONDAYS = "0", SPCDAYS = "0"
)

h <- grouper("hrg4plus", version = "2025-26-lp")
res <- group(h, episodes)
res$episodes[c("fce_hrg", "grouping_method", "dominant_procedure", "spell_hrg", "quality")]
#>   fce_hrg grouping_method dominant_procedure spell_hrg quality
#> 1   HN12F               P               W371     HN12F
```

`HN12F` is *"Very Major Hip Procedures for Non-Trauma with CC Score 0-1"*.
Add a serious comorbidity (say `DIAG_03 = "J440"`, COPD with a chest
infection) and the episode moves to `HN12E`, the *"CC Score 2-3"* split of the
same group.

* `fce_hrg` — the HRG of the episode; `spell_hrg` the HRG of the whole stay,
  repeated on each of its episodes (`res$spells` has one row per stay).
* `grouping_method` — how the HRG was reached: `P` driven by the dominant
  procedure, `D` by the diagnosis, `G` a global exception, `B` burns, `M`
  multiple trauma, `U` could not be grouped.
* `dominant_procedure` — the procedure the grouper considered the most
  significant.
* `unbundled_hrgs` — extra HRGs for components priced separately
  (chemotherapy, radiotherapy, imaging, critical care, …).
* `quality` — empty when the record is valid; otherwise the validation
  message, in which case the HRG is `UZ01Z` ("data invalid for grouping").
  For instance NHS data expects 3-character ICD-10 codes to be padded with
  `X` (`I10X`, not `I10`).

The other six HRG4+ datasets use the same grouper with `dataset =`:
`"nac"` (outpatients), `"em"` (emergency department), `"acc"`, `"pcc"`,
`"ncc"` (adult, paediatric and neonatal critical care) and `"nrd"` (renal
dialysis). Each takes the NHS column layout of that dataset; see
`?hrg_group_nac` etc.

```r
group(h, attendances, dataset = "nac")
```

### Prescribed Specialised Services (England)

Same inpatient layout as above (without the discharge and duration fields).
The output is not a group but the list of specialised service lines the
episode qualifies for, the dominant one, and its *National Programme of Care*
(NPoC). Provider eligibility is part of many rules; the generic code `PSS`
bypasses it, as in the official tool.

```r
episodes <- data.frame(
  PROCODET = "PSS", PROVSPNO = "1001", STARTAGE = "54", SEX = "1", CLASSPAT = "1",
  ADMIMETH = "21", MAINSPEF = "100", TRETSPEF = "100",
  DIAG_01 = "C210",      # cancer of the anus
  OPER_01 = "H334"       # anterior resection of the rectum
)

p <- grouper("pso", version = "2025-26-v2")
res <- group(p, episodes)
res$episodes[c("service_line_list", "service_line", "fce_npoc", "spell_service_line")]
#>   service_line_list service_line fce_npoc spell_service_line
#> 1          NCBPS01J     NCBPS01J      A07           NCBPS01J
```

`NCBPS01J` is *"Specialist cancer services (adults): anal cancer"*, in
programme of care `A07`, *specialised colorectal services*. Outpatient
attendances are flagged with `dataset = "nac"`. The service-line catalogue with
names and hierarchies is in `p$tables$service_lines`.

### Spanish hospital data (CMBD / RAE-CMBD)

Spain's discharge register codes diagnoses and procedures in CIE-10-ES, which
is the Spanish translation of ICD-10-CM/PCS, so Spanish records can be grouped
with the MS-DRG engine as they are. Spain's own payment classification is a
different, proprietary system (3M/Solventum APR-GRD) whose logic is not
published, so it cannot be bundled; MS-DRG gives Spanish data an open,
verifiable casemix classification instead. `cmbd_to_msdrg()` takes the
register's wide layout (RD 69/2015 names such as `D1`..`D20`, `POAD1`..,
`PROC1`.., `SEXO`, `TIPALT`, `FECNAC`, `FECINICONT`, and common variants)
and maps the Spanish code lists to the CMS conventions (sex, destination
after discharge → UB-04 status, POA `S/N/D/I/E` → `Y/N/U/W/1`, age from the
birth date):

```r
rae <- data.frame(
  FECNAC = "15031957", SEXO = "1", FECINICONT = "02052024 1130", TIPCONT = "1",
  TIPALT = "4",                                   # exitus
  D1 = "I21.4", D2 = "E11.9", D3 = "N17.9", POAD1 = "S", POAD2 = "S", POAD3 = "N"
)
group(grouper("msdrg", version = "44.0"), cmbd_to_msdrg(rae))[c("drg", "drg_description")]
#>   drg drg_description
#> 1 284 ACUTE MYOCARDIAL INFARCTION, EXPIRED WITH CC
```

Real extracts are delimited text files in the field order of RD 69/2015, which
no hospital publishes. The package ships a synthetic one instead — a month of
discharges of a fictional general hospital, 1,000 contacts with the casemix,
coding depth and conventions of a real file (deliveries and newborns, heart
failure, pneumonia, sepsis, hip fractures, joint replacements, chemotherapy
admissions, day-hospital sessions, ambulatory surgery, readmissions, ICU stays,
hospital-acquired conditions flagged `POA = N`, ...) but no real patients.
`cmbd_read()` reads such files keeping every field as text:

```r
rae <- cmbd_read(cmbd_example())
rae[, c("HISTORIA", "FECNAC", "SEXO", "FECINICONT", "TIPCONT", "SERVICIO", "TIPALT", "D1", "POAD1", "D2", "PROC1")]
#> # A tibble: 1,000 × 11
#>   HISTORIA FECNAC   SEXO  FECINICONT    TIPCONT SERVICIO TIPALT D1     POAD1 D2     PROC1
#>   <chr>    <chr>    <chr> <chr>         <chr>   <chr>    <chr>  <chr>  <chr> <chr>  <chr>
#> 1 1624857  08011926 1     24042024 2012 1       NML      4      J96.21 S     Z99.81 <NA>
#> 2 6609874  03031940 1     21042024 1728 1       NML      1      J44.1  S     I27.20 5A09457
#> 3 3826608  23111958 2     24042024 1732 1       DIG      1      K80.50 S     E87.1  0FC98ZZ
#> # ℹ 997 more rows

dplyr::count(rae, TIPCONT)   # 1 hospitalisation, 2 home hospitalisation, 3 day hospital, 4 ambulatory surgery
#> # A tibble: 4 × 2
#>   TIPCONT     n
#>   <chr>   <int>
#> 1 1         897
#> 2 2          12
#> 3 3          32
#> 4 4          59

hosp <- dplyr::filter(rae, TIPCONT == "1")
out <- group(grouper("msdrg", version = "44.0"), cmbd_to_msdrg(hosp), poa_exempt = "non_exempt")
dplyr::count(out, drg, drg_description, sort = TRUE)
#> # A tibble: 157 × 3
#>     drg drg_description                                                                         n
#> 1   795 NORMAL NEWBORN                                                                         58
#> 2   807 VAGINAL DELIVERY WITHOUT STERILIZATION OR D&C WITHOUT CC/MCC                           58
#> 3   690 KIDNEY AND URINARY TRACT INFECTIONS WITHOUT MCC                                        38
#> 4   470 MAJOR HIP AND KNEE JOINT REPLACEMENT OR REATTACHMENT OF LOWER EXTREMITY WITHOUT MCC    36
#> 5   203 BRONCHITIS AND ASTHMA WITHOUT CC/MCC                                                   26
#> 6   419 LAPAROSCOPIC CHOLECYSTECTOMY WITHOUT C.D.E. WITHOUT CC/MCC                             23
#> 7   292 HEART FAILURE AND SHOCK WITH CC                                                        22
#> 8   392 ESOPHAGITIS, GASTROENTERITIS AND MISCELLANEOUS DIGESTIVE DISORDERS WITHOUT MCC         22
#> # ℹ 149 more rows
```

DRGs are only meaningful for hospitalisation contacts, hence the filter on
`TIPCONT`; the contact type is carried through in `claims$contact_type`.
Spanish hospitals report present-on-admission for every diagnosis, so pass
`poa_exempt = "non_exempt"`: the grouper then applies CMS's hospital-acquired
condition rules (a pressure ulcer or a fall coded `POAD = N` stops counting
towards severity) instead of, as CMS's software does when a hospital's POA
status is unknown, refusing to group such records (return code 15). Mind
the code-year lag: CIE-10-ES 2024 corresponds to ICD-10-CM/PCS FY2023, and the
synthetic file only uses codes that exist in both FY2023 and the bundled
tables. The generator (`data-raw/cmbd-synthetic.R`) is seeded and documents
every clinical profile, so the file can be regenerated or extended.

### OMOP CDM (`CDMConnector`)

In federated research networks built on the OMOP Common Data Model, data lives
behind a `cdm_reference` created with `CDMConnector::cdmFromCon()` (PostgreSQL,
DuckDB, SQL Server, …) or `omopgenerics::cdmFromTables()`. `omop_msdrg()` — or
equivalently `group(grouper("msdrg"), cdm, ...)` — runs read-only lazy `dbplyr`
queries inside the database (no write schema required), extracts the scoped
inpatient stays, demographics, ICD-10-CM diagnoses, ICD-10-PCS procedures and
discharge disposition, assigns MS-DRGs, and attaches a readiness report
(`omop_msdrg_quality()`):

```r
library(CDMConnector)
library(opendrg)

cdm <- cdmFromCon(con, cdmSchema = "cdm", cdmName = "hospital_a")

# Standard CDM with condition_status_concept_id (32902/32903) populated:
res <- omop_msdrg(cdm, tables = "44.0", start_date = "2024-01-01", end_date = "2024-12-31")
omop_msdrg_quality(res)

# Or via the unified grouper interface, scoped to a CDM cohort table:
g <- grouper("msdrg", version = "44.0")
res <- group(g, cdm, cohort = "study_cohort")
```

Real-world OMOP ETLs frequently omit billing-specific fields, so `omop_to_msdrg()`
and `omop_msdrg()` make every assumption explicit rather than guessing silently:

* **Principal diagnosis (`principal`)**: `"status"` (default) uses OMOP
  primary-diagnosis flags (`condition_status_concept_id` 32902/32903/32901 or
  legacy primary `condition_type_concept_id`) and marks stays without a flag
  ungroupable (return code 7) instead of picking one arbitrarily. When a site
  does not populate primary flags, pass `principal = "codelist"` with
  `principal_codes` (ICD-10-CM codes/prefixes, OMOP concept IDs, or a
  `CodelistGenerator` / `omopgenerics` codelist), `principal = "cohort_codelist"`
  with a `CohortConstructor` concept cohort to use each cohort's attached index
  codelist automatically, `principal = "all"` to evaluate every coded diagnosis
  in turn as a sensitivity analysis, or `principal = "first"` for an explicit
  first-code approximation.
* **`CohortConstructor` cohorts**: pass a `CohortConstructor` `cohort_table`
  directly as the first argument (`omop_to_msdrg(cdm$my_cohort, ...)`,
  `omop_msdrg(cdm$my_cohort, ...)`, or `group(g, cdm$my_cohort, ...)`), or via
  `cohort = "my_cohort"`. Multi-cohort tables keep `cohort_definition_id` and
  `cohort_name`, support filtering by `cohort_id` (IDs or names), and control
  stay matching with `cohort_match = c("overlap", "index", "subject")`.
* **Discharge disposition (`discharge_map`, `default_discharge`)**: resolved in
  order from in-stay mortality in the `death` table (`"20"`), an optional
  per-site `discharge_map` over `discharged_to_source_value`, standard OMOP
  `discharged_to_concept_id` (supporting both CDM v5.4 `discharged_to_*` and
  v5.3 `discharge_to_*` names, plus `UB04 Pt dis status` concepts directly),
  and `default_discharge = "01"` (routine home).
* **Diagnoses & procedures**: reads `ICD10CM` from `condition_source_concept_id`
  (excluding NLP rows `32858` by default; optional `vocabulary_fallback = TRUE` via
  `concept_relationship`), reads `ICD10PCS` from both `procedure_concept_id`
  and `procedure_source_concept_id`, flags stays carrying unmapped local
  procedures (`has_unmapped_pr`), and separates non-billable category-level
  ICD-10-CM headers (e.g. `N18`, `G20`) from unrecognised codes in
  `omop_msdrg_quality()`.

```r
# Real-world site without primary flags and with a site-specific discharge list:
site_discharge <- c("1" = "01", "2" = "02", "3" = "07", "5" = "20", "4" = "03", "6" = "06")
index_codes <- c("C61", "C67", "C64", "N40", "N20", "N17", "N18", "N390", "N13")

res <- group(
  grouper("msdrg", version = "44.0"), cdm,
  start_date = "2024-01-01", end_date = "2024-12-31",
  principal = "codelist", principal_codes = index_codes, unmatched = "drop",
  discharge_map = site_discharge
)
omop_msdrg_quality(res)
#> <opendrg OMOP quality report> CDM: hospital_a (principal = "codelist", MS-DRG v44.0)
#> Stays: 5,126 (3,791 persons); Claims: 2,785
#> Diagnoses: 95.8% of stays coded (median 4, mean 5.0); 0.0% OMOP primary flag; 54.3% principal assigned
#> Procedures: 6.1% with ICD-10-PCS; 84.3% with unmapped procedures
#> Grouped (RC 0): 2,782 / 2,785 claims (99.9%); surgical: 2.7%
#> Diagnosis code validity: category_header=174, valid_billable=24,257
#> Discharge sources: source_map=4,168, default=945, death=13
```

```r
# Working directly with a multi-cohort CohortConstructor table:
cdm$clinical <- CohortConstructor::conceptCohort(
  cdm,
  conceptSet = list(ami = 312327L, aki = 197320L, esrd = 193782L),
  name = "clinical"
)
res <- omop_msdrg(cdm$clinical, principal = "cohort_codelist", cohort_match = "index")
res[c("cohort_name", "visit_occurrence_id", "principal_code", "drg", "drg_description")]
```

```r
# UK / NHS England HRG4+ and PSO directly on an OMOP CDM or CohortConstructor cohort:
# Reads ICD10 (auto-padding 3-char codes with X) + OPCS4, supports spell-level
# or visit_detail (FCE) episodes, provider specialty -> TFC, and death/discharge maps.
res_hrg <- omop_hrg(cdm$uk_cohort, tables = "2025-26-lp", principal = "cohort_codelist")
res_hrg$episodes[c("cohort_name", "visit_occurrence_id", "fce_hrg", "dominant_procedure", "spell_hrg")]
omop_hrg_quality(res_hrg)

# Or via the unified grouper interface for HRG4+ and Prescribed Specialised Services (PSO):
group(grouper("hrg4plus", version = "2025-26-lp"), cdm, episodes = "visit_detail")
group(grouper("pso", version = "2025-26-v2"), cdm$uk_cohort, principal = "cohort_codelist")
```

See `dev/omop-cdm-example.R` for a complete runnable script against a live
PostgreSQL OMOP CDM.

#### OMOP CDM entity-relationship & output schema

The diagram below shows the OMOP CDM v5.3/v5.4 tables (and optional
`CohortConstructor` `cohort_table`) read by `omop_to_msdrg()` / `omop_to_hrg()`
and the resulting casemix outputs (`omop_msdrg()`, `omop_hrg()`, and
`group(grouper("pso"), cdm)`):

```mermaid
erDiagram
    PERSON {
        bigint person_id PK
        int gender_concept_id
        datetime birth_datetime
        int year_of_birth
        int month_of_birth
        int day_of_birth
    }

    DEATH {
        bigint person_id PK "FK -> PERSON (optional)"
        date death_date
    }

    COHORT_TABLE {
        int cohort_definition_id PK "optional CohortConstructor"
        bigint subject_id FK "-> PERSON"
        date cohort_start_date
        date cohort_end_date
        string cohort_name "attr: cohort_set"
        int concept_id "attr: cohort_codelist"
    }

    VISIT_OCCURRENCE {
        bigint visit_occurrence_id PK
        bigint person_id FK
        int visit_concept_id "9201 / 262"
        date visit_start_date
        date visit_end_date
        int discharged_to_concept_id "v5.3: discharge_to_*"
        string discharged_to_source_value
        int admitted_from_concept_id "HRG4+ (v5.3: admitting_source_*)"
        bigint provider_id FK "HRG4+"
        bigint care_site_id FK "HRG4+/PSO"
    }

    VISIT_DETAIL {
        bigint visit_detail_id PK "optional HRG4+ FCEs"
        bigint visit_occurrence_id FK
        date visit_detail_start_date
        date visit_detail_end_date
        bigint provider_id FK
    }

    CONDITION_OCCURRENCE {
        bigint condition_occurrence_id PK
        bigint visit_occurrence_id FK
        bigint visit_detail_id FK "optional HRG4+"
        int condition_source_concept_id FK "ICD10CM / ICD10"
        int condition_concept_id FK "standard / cohort_codelist"
        int condition_status_concept_id "32902 / 32903 / 32901"
        int condition_type_concept_id "excl. 32858 NLP"
        date condition_start_date
    }

    PROCEDURE_OCCURRENCE {
        bigint procedure_occurrence_id PK
        bigint visit_occurrence_id FK
        bigint visit_detail_id FK "optional HRG4+"
        int procedure_concept_id FK "ICD10PCS / OPCS4"
        int procedure_source_concept_id FK "ICD10PCS / OPCS4"
        date procedure_date
    }

    PROVIDER {
        bigint provider_id PK "optional HRG4+/PSO"
        int specialty_concept_id "-> MAINSPEF / TRETSPEF"
        string specialty_source_value
    }

    CARE_SITE {
        bigint care_site_id PK "optional HRG4+/PSO"
        string care_site_source_value "-> PROCODET"
    }

    CONCEPT {
        int concept_id PK
        string vocabulary_id "ICD10CM / ICD10PCS / ICD10 / OPCS4 / UB04"
        string concept_code
    }

    CONCEPT_RELATIONSHIP {
        int concept_id_1 FK "vocabulary_fallback"
        int concept_id_2 FK
        string relationship_id "Maps to"
    }

    OMOP_MSDRG_OUTPUT {
        string claim_id PK
        int cohort_definition_id "optional"
        string cohort_name "optional"
        bigint visit_occurrence_id FK
        bigint person_id FK
        string principal_code
        string principal_source
        int drg
        int initial_drg
        int base_drg
        int mdc
        string med_surg
        string severity
        int return_code
        string drg_description
        bool has_unmapped_pr
    }

    OMOP_HRG_EPISODES {
        string episode_id PK
        int cohort_definition_id "optional"
        string cohort_name "optional"
        bigint visit_occurrence_id FK
        bigint visit_detail_id FK "optional"
        bigint person_id FK
        string fce_hrg
        string grouping_method
        string dominant_procedure
        string unbundled_hrgs
        string fce_pbc
        string spell_hrg
        string service_line "PSO: group(pso)"
        string fce_npoc "PSO: group(pso)"
    }

    OMOP_HRG_SPELLS {
        int spell PK
        string cohort_name "optional"
        bigint visit_occurrence_id FK
        bigint person_id FK
        string spell_hrg
        int spell_episode_count
        num spell_los
        string spell_unbundled_hrgs
        string spell_service_line "PSO: group(pso)"
    }

    PERSON ||--o{ VISIT_OCCURRENCE : "has stays"
    PERSON ||--o| DEATH : "in-stay mortality"
    COHORT_TABLE }o--o{ VISIT_OCCURRENCE : "scopes stays (overlap/index/subject)"
    VISIT_OCCURRENCE ||--o{ VISIT_DETAIL : "FCEs (episodes = visit_detail)"
    VISIT_OCCURRENCE ||--o{ CONDITION_OCCURRENCE : "diagnoses"
    VISIT_OCCURRENCE ||--o{ PROCEDURE_OCCURRENCE : "procedures"
    VISIT_DETAIL |o--o{ CONDITION_OCCURRENCE : "FCE diagnoses"
    VISIT_DETAIL |o--o{ PROCEDURE_OCCURRENCE : "FCE procedures"
    PROVIDER |o--o{ VISIT_OCCURRENCE : "specialty (HRG4+)"
    PROVIDER |o--o{ VISIT_DETAIL : "FCE specialty (HRG4+)"
    CARE_SITE |o--o{ VISIT_OCCURRENCE : "provider code (HRG4+)"
    CONDITION_OCCURRENCE }o--|| CONCEPT : "source / UB04 lookup"
    PROCEDURE_OCCURRENCE }o--|| CONCEPT : "ICD10PCS / OPCS4"
    CONDITION_OCCURRENCE }o--o{ CONCEPT_RELATIONSHIP : "vocabulary_fallback"
    CONCEPT_RELATIONSHIP }o--|| CONCEPT : "Maps to"
    VISIT_OCCURRENCE ||--o{ OMOP_MSDRG_OUTPUT : "omop_msdrg() + quality"
    VISIT_OCCURRENCE ||--o{ OMOP_HRG_SPELLS : "omop_hrg() + quality"
    OMOP_HRG_SPELLS ||--|{ OMOP_HRG_EPISODES : "1..N episodes per spell"
```

## Glossary

| Term | Meaning |
|---|---|
| **Casemix** | The mix of patients a hospital treats, described by groups of similar cost and clinical type. |
| **DRG / MS-DRG** | Diagnosis Related Group; the Medicare Severity version splits many groups three ways by how sick the patient was. |
| **MDC** | Major Diagnostic Category: 25 body-system chapters that organise the DRGs. |
| **CC / MCC** | Complication or Comorbidity / Major CC: secondary diagnoses that raise the expected cost of a stay and move it to a higher-paid DRG. |
| **POA** | Present on admission. Conditions acquired in hospital (POA = N) that are on CMS's hospital-acquired-condition list do not count towards severity. |
| **HRG** | Healthcare Resource Group, the English equivalent of a DRG (e.g. `HN12F`). The first two letters identify the *subchapter* (HN = orthopaedic non-trauma), the digits the *root*, the last letter the *split*. |
| **Episode (FCE)** | Finished Consultant Episode: the part of a stay under one consultant. A stay with several consultants has several episodes. |
| **Spell** | A whole hospital stay, from admission to discharge, made of one or more episodes. HRG4+ groups both the episode and the spell. |
| **Unbundled HRG** | An extra HRG for a separately priced component of care (imaging, chemotherapy, critical care, …) reported alongside the core HRG. |
| **Dominant procedure** | The procedure in an episode with the highest value in NHS England's procedure hierarchy; it drives procedure-based grouping. |
| **CC score** | The HRG4+ complication score computed from the secondary diagnoses, used in many splits. |
| **PBC** | Programme Budgeting Category, a health-condition category NHS England attaches to each episode. |
| **Service line / NPoC** | A prescribed specialised service that NHS England commissions directly (`NCBPS…`), and the National Programme of Care it belongs to (e.g. `A07`). |
| **ICD-10-CM / ICD-10-PCS** | The US diagnosis and procedure classifications used by MS-DRG. |
| **ICD-10 / OPCS-4** | The diagnosis and procedure classifications used by the NHS. |
| **Return code / quality message** | What the grouper tells you when a record cannot be grouped and why. |

## How it works

Both agencies publish the complete grouping logic as data:

* **MS-DRG**: CMS's release contains one boolean formula per DRG (e.g.
  `(PDX:dxc0306) & (MCC)` — *principal diagnosis in category 306 and a major
  complication present*), tables mapping every code to such attributes, the
  CC/MCC exclusion list and procedure clusters. opendrg compiles the formulas
  to dplyr expressions and evaluates them in CMS's order, with the same
  severity, exclusion, cluster and hospital-acquired-condition rules as the
  Java reference implementation.
* **HRG4+**: the *Code to Group* workbook holds the code → HRG-root mapping,
  the root → split rules, a formal definition of every condition flag and
  every code list those flags reference. opendrg forms combination codes,
  derives unbundled HRGs, picks the dominant procedure, applies the
  burns / multiple-trauma / procedure / global-exception / diagnosis
  precedence and the split rules, then groups spells from the dominant
  episode with the union of the spell's codes. A few pieces of logic that NHS
  England publishes only as flowcharts in PDF (emergency-medicine hierarchies,
  the paediatric and neonatal critical-care decision trees) were transcribed
  into `data-raw/hrg/` and are bundled with the tables.
* **Prescribed Specialised Services**: the *Guide to Identification Rules*
  workbook lists, per service line, the rules as conjunctions of code lists
  (diagnosis by position, procedure anywhere or as the dominant procedure,
  code combinations, provider eligibility, age, sex, specialty, admission
  method, attendance and referral source) and the dominance hierarchies.
  opendrg evaluates every rule and picks the dominant line per episode,
  attendance and spell.

New releases are imported with `msdrg_import_cms()`,
`hrg_import_code_to_group()` and `pso_import_rules()`; the engines do not
change. Each version is a self-contained table set of a few hundred kilobytes
and several versions can be used side by side.

## How we know it is right

Grouping logic is only trustworthy if it matches the official software, not
just the documentation. The package test-suite therefore asserts
record-by-record agreement with the official results:

* **MS-DRG**: `dev/oracle/` contains a harness that runs CMS's own Java
  grouper (shipped in the mainframe package) over CMS's 9,864-claim test
  database. The tests require byte-for-byte agreement with that output for
  every bundled version.
* **HRG4+ and PSS**: NHS England publishes test data with expected results for
  every dataset. The tests require every output field of every record to
  match.

`dev/notes/` holds the engine specifications derived from the reference
implementations, including the handful of behaviours the test data does not
exercise. `R CMD check` runs clean on macOS, Windows and Linux through GitHub
Actions.

## What it does not do

* It does not compute **payments** or tariffs: it assigns groups; prices,
  weights and trim points are separate publications.
* MS-DRG covers the grouper only, not the Medicare Code Editor (MCE) edits.
* Classification **descriptions** (what `I21.4` or `W371` mean) are not
  bundled, only the codes the logic needs; DRG, HRG and service-line titles
  are included.
* The HRG4+ and PSS engines are currently row-wise (about 100 records per
  second); MS-DRG groups about 1,200 claims per second. Vectorisation and a
  dbplyr (in-database) backend are planned.

## Licensing

Package code is MIT. Bundled logic tables are derived from publicly released
government data:

* CMS MS-DRG tables are a work of the US federal government (public domain).
* HRG4+ and Prescribed Specialised Services tables are derived from NHS
  England's *Code to Group* and *Guide to Identification Rules* workbooks and
  contain public sector information licensed under the
  [Open Government Licence v3.0](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).
  © NHS England.

## Further reading

* `article/wp_opendrg.pdf` — technical whitepaper describing the design and
  the verification in detail.
* [CMS MS-DRG classifications and software](https://www.cms.gov/medicare/payment/prospective-payment-systems/acute-inpatient-pps/ms-drg-classifications-and-software)
* [NHS England National Casemix Office: groupers and tools](https://digital.nhs.uk/services/national-casemix-office/downloads-groupers-and-tools)
