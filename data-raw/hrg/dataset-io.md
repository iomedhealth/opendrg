# Non-APC datasets — input/output layouts and validation — HRG4+ 2024/25 National Costs Grouper

Sources: official test data and expected results v1.0 (column headers and `_quality_rel.csv`
messages), default RDFs (`Default RDF/HRG4+_default_<DS>.rdf`), User Manual v1.1 (field tables
pp. 62-70, output tables pp. 79-91), Code To Group `Reference Data` (valid values). Everything
below is as used by the verified prototype (NAC 200/200, EM 300/300, ACC 250/250, PCC 250/250,
NCC 300/300, NRD 200/200).

Conventions common to all datasets

* Input is CSV without text qualifiers; column order comes from the RDF; `dummy_field` in the test
  files is an extra, ignored column that is copied to the outputs. Blank cells are empty strings.
* Every dataset writes `[name].csv` (the list of output files), `[name]_quality.csv` (= input
  columns + `RowNo` + one `Code Type|Code|Error Message` field per error, only for rows with
  errors), `[name]_quality_rel.csv` (`RowNo, Iteration, Code Type, Error Message`-style rows:
  `RowNo,Iteration,Code Type,Code,Error Message`) and `[name]_summary.csv` (one row:
  `Grouper Version` = `NC2425_1.0.0`, `Database Version` = `NC2425_20241209`, a record count, an
  error count, `Run Start Date/Time`, `Run End Date/Time`, `Input Filename`, `Output Filename`,
  `RDF path and name`).
* Any validation error on a record makes its HRG `UZ01Z`. The error count in `_summary.csv` is
  the number of records with at least one error.
* Message format `Code Type|Code|Error Message`; `Code` is empty for "is blank" messages.
* `RowNo` = 1-based record number (after sorting where a sort applies).

---

## NAC — Non-Admitted Consultations

**Input columns** (`HRG4+_default_NAC.rdf`; `OPER_nn` up to 99):
`STARTAGE, SEX, MAINSPEF, TRETSPEF, FIRSTATT, OPER_01, OPER_02, …, OPER_12`

**Main output** `[name]_attend.csv`: input columns, then
`RowNo, NAC_HRG, GroupingMethodFlag, DominantProcedure, AttendanceHRG, AttendSSC_Ct, AttendSSC1, AttendSSC2, AttendSSC3, AttendSSC4, AttendSSC5, AttendBP_Ct, AttendBP1, AttendBP2, AttendBP3, AttendBP4, AttendBP5, AttendFlag_Ct, AttendFlag1, AttendFlag2, AttendFlag3, AttendFlag4, AttendFlag5, UnbundledHRGs`
(`AttendanceHRG` blank, the `*_Ct` fields `0`, the `AttendSSC/BP/Flag` fields blank — payment
groupers only; `UnbundledHRGs` = variable number of trailing fields, rehabilitation delivery HRGs
carry `*1`).
Other outputs: `[name]_attend_rel.csv` = input columns + `RowNo, NAC_HRG, GroupingMethodFlag,
DominantProcedure, AttendanceHRG`; `[name]_ub_rel.csv` = `RowNo, Iteration, UnbundledHRGs`;
`_quality`, `_quality_rel`, `_summary` (`Attendance Count`, `Attendance Error Count`). No sort.

**GroupingMethodFlag**: `P` procedure driven (a procedure's own Code To Group row produced the
HRG — includes `X62.x` assessment codes and their `SB97/SC97` pairs), `G` global exception
(Core 5: `SB97Z`, `SC97Z`, `RD97Z`, `RN97Z`, `RD98Z` with LoS 0), `O` outpatient default (Core 6
row of `MAINSPEF` → `WF01`/`WF02`, split by `FIRSTATT`), `U` error.

**Validation**

| Field | Valid values | Messages observed (`Code Type|Code|Message`) |
|---|---|---|
| `STARTAGE` | 0-130 or 999 (not known; groups as adult) | `STARTAGE||Age is blank`; `STARTAGE|132|Age is invalid` |
| `SEX` | `0`,`1`,`2`,`9`,`X` (`Reference Data`); case-sensitive | `SEX||Sex is blank`; `SEX|3|Sex is invalid`; `SEX|x|Sex is invalid` |
| `MAINSPEF` | the 89 main specialty codes | `MAINSPEF||Main Specialty Code is blank`; `MAINSPEF|990|Main Specialty Code is invalid` (also `191`) |
| `TRETSPEF` | the 180 treatment function codes | `TRETSPEF||Treatment Function Code is blank`; `TRETSPEF|&|Treatment Function Code is invalid` (also `900`, `830`, `810`) |
| `FIRSTATT` | `1`,`2`,`3`,`4` | `FIRSTATT||First Attendance Status Code is blank`; `FIRSTATT|X|First Attendance Status Code is invalid` (also `5`) |
| `OPER_nn` | valid OPCS-4 or blank | `OPER_nn|code|Procedure is invalid` (UM p. 92; not in the test data) |
| grouping | — | `OPER_01|Y903|UZ05 - Invalid procedure for Casemix grouping purposes` (a qualifier code that is the only/first code and therefore dominant); `OPER_01|U369|UZ06 - Poorly coded procedure for Casemix grouping purposes` (PH-0 unspecified code dominant, e.g. `U369`, `U408`) |

---

## EM — Emergency Medicine

**Input columns** (`HRG4+_default_EM.rdf`; `INV_nn`/`TREAT_nn` up to 99):
`AGE, AEPATIENTGROUP, INV_01, …, INV_12, TREAT_01, …, TREAT_12`
(RDF field labels are `FirstAccidentAndEmergencyInvestigation` … `TwelthAccidentAndEmergencyTreatment`; the CSV headers in the test data are `INV_nn`/`TREAT_nn`.)

**Main output** `[name]_attend.csv`: input columns, then `RowNo, EM_HRG`. Other outputs:
`_quality`, `_quality_rel`, `_summary` (`Attendance Count`, `Attendance Error Count`). No
`_rel`/`_ub` files, no `GroupingMethodFlag`, no sort.

**Grouping** (CS pp. 151-156; hierarchy values in `em-hierarchy.csv`): dominant investigation =
highest hierarchy among the non-blank `INV_nn` (ties → first position); dominant treatment
likewise over `TREAT_nn`; look up Code To Group type `EM`, code `I <inv>+T <treat>`
(`Blank INV+T <treat>` / `I <inv>+Blank TRE` when one side is absent) → `VBnn` → `VBnnZ`.
`AEPATIENTGROUP = 70` (brought in dead) with at least one investigation or treatment → `VB99Z`
(Code To Group `EM` row `70`); with none → the two "is blank" errors → `UZ01Z`.

**Validation**

| Field | Valid values | Messages observed |
|---|---|---|
| `AGE` | 0-130 (validated, not used in grouping) | `AGE|210|Age is invalid` (also `131`, `140`, `160`, `211`); blank presumably `Age is blank` |
| `AEPATIENTGROUP` | blank or `10`,`20`,`30`,`40`,`50`,`60`,`70`,`80` | `AEPATIENTGROUP|0|Accident and Emergency Classification Code is invalid` (also `21`, `90`, `99`) |
| `INV_nn` | blank or one of `01`-`08`,`10`-`24`,`99` — exactly as written, leading zero required (`1`, `2`, `4` are invalid; `09`, `25`, `30`, `80`, `222` invalid) | `INV_01|1|Investigation is invalid` |
| `TREAT_nn` | blank or one of the 92 treatment codes (`011`…`99`), leading zero required | `TREAT_06|51|Treatment is invalid` |
| all `INV_nn` **and** all `TREAT_nn` blank | — | `INV_01||Investigation is blank` **and** `TREAT_01||Treatment is blank` (both reported; a record with investigations but no treatment, or vice versa, is valid) |

---

## ACC — Adult Critical Care

**Input columns** (`HRG4+_default_ACC.rdf`):
`CCUF, BCSD, ACSD, BRSD, ARSD, RSD, NSD, DSD, LSD, CCL2D, CCL3D, CC_Start_Date, CC_Discharge_Date`

**Main output** `[name]_acc.csv`: input columns, then `RowNo, ACC_HRG, Calc_CC_Days,
CC_Warning_Flag`. Other outputs: `_quality`, `_quality_rel`, `_summary` (`ACC Period Count`,
`ACC Period Error Count`). No `GroupingMethodFlag`, no sort. Rules: `acc-rules.md`.

**Validation**

| Field | Valid values | Messages observed |
|---|---|---|
| `CCUF` | `1`,`2`,`3`,`5`,`6`,`7`,`8`,`9`,`01`,`02`,`03`,`05`,`06`,`07`,`08`,`09`,`10`,`11`,`12`,`90`,`91` | `CCUF|04|Critical Care Unit Function is invalid` (also `13`, `18`); blank presumably `… is blank` |
| `BCSD … LSD`, `CCL2D`, `CCL3D` | integer 0-99999 or blank (blank = 0, no error) | none observed |
| `CC_Start_Date`, `CC_Discharge_Date` | `YYYYMMDD` or blank | never an error; blank/invalid/reversed → `Calc_CC_Days = -1`, `CC_Warning_Flag = F` |
| grouping | no organ support days and `CCL2D + CCL3D = 0` | `CCUF|01|UZ13 - ACC grouping error` (Code = the CCUF value) |

---

## PCC — Paediatric Critical Care

**Input columns** (`HRG4+_default_PCC.rdf`; `DIAG_nn` up to 99):
`PROCODET, CCLocalID, CCDate, DISDATE, DISMETH, CCUF, CCAC_01, …, CCAC_20, OPER_01, …, OPER_20, DIAG_01, …, DIAG_14`

**Sort**: stable sort by `PROCODET`, `CCLocalID`, `CCDate` (text; blank `CCLocalID` first);
`[name]_sort.csv` = sorted input + `RowNo`.

**Main output** `[name]_pcc.csv`: input columns, then `RowNo, PCC_HRG`. Other outputs: `_sort`,
`_quality`, `_quality_rel`, `_summary` (`PCC Record Count`, `PCC Record Error Count`). No
`GroupingMethodFlag`. Rules: `pcc-flowchart.md`, `pcc-isolation-list.csv`.

**Validation**

| Field | Valid values | Messages observed |
|---|---|---|
| `PROCODET`, `CCLocalID` | not validated (a blank `CCLocalID` is accepted) | — |
| `CCDate` | `YYYYMMDD` | `CCDate||Critical Care Date is blank` |
| `DISDATE` | `YYYYMMDD` | `DISDATE||Discharge Date is blank` |
| `DISMETH` | `1`-`9` | `DISMETH||Discharge Method is blank`; `DISMETH|10|Discharge Method is invalid` (also `11`, `12`) |
| `CCUF` | `04`/`4`, `16`, `17`, `18`, `19`, `92` | `CCUF||Critical Care Unit Function is blank`; `CCUF|01|Critical Care Unit Function is invalid` (also `02`) |
| `CCAC_nn` | blank or one of the 77 CCAC codes (padded or unpadded) | `CCAC_01|75|Critical Care Activity Code is invalid` (also `79`, `765`) |
| `OPER_nn` | valid OPCS-4 or blank | `Procedure is invalid` presumed (not observed) |
| `DIAG_01` | valid ICD-10 **or blank** (optional in PCC) | `DIAG_01|J692|Primary Diagnosis is invalid` (also `N180`); no "is blank" error |
| `DIAG_nn` (n ≥ 2) | valid ICD-10 or blank | `DIAG_03|N180|Secondary Diagnosis is invalid` (also `A172`) |
| grouping | `CCUF` outside the list is also the flowchart's node 1 | (reported as the CCUF message above) |

---

## NCC — Neonatal Critical Care

**Input columns** (`HRG4+_default_NCC.rdf`):
`PROCODET, CCLocalID, CCDate, DISDATE, CCUF, AGE_DAYS, DISMETH, GestLen, PERWT, CCAC_01, …, CCAC_20`

**Sort**: stable sort by `PROCODET`, `CCLocalID`, `CCDate` (text); `[name]_sort.csv` = sorted
input + `RowNo`.

**Main output** `[name]_ncc.csv`: input columns, then `RowNo, NCC_HRG`. Other outputs: `_sort`,
`_quality`, `_quality_rel`, `_summary` (`NCC Record Count`, `NCC Record Error Count`). No
`GroupingMethodFlag`. Rules: `ncc-flowchart.md`.

**Validation**

| Field | Valid values | Messages observed |
|---|---|---|
| `PROCODET`, `CCLocalID` | not validated | — |
| `CCDate` | `YYYYMMDD` | (`Critical Care Date is blank` presumed) |
| `DISDATE` | `YYYYMMDD` | `DISDATE||Discharge Date is blank` |
| `CCUF` | `13`, `14`, `15` | `CCUF||Critical Care Unit Function is blank`; `CCUF|4|Critical Care Unit Function is invalid` (also `8`, `16`, `+`) |
| `AGE_DAYS` | integer 0-999 | `AGE_DAYS||Age in days is blank` |
| `DISMETH` | `1`-`9` | `DISMETH||Discharge Method is blank`; `DISMETH|&|Discharge Method is invalid` (also `10`) |
| `GestLen` | integer 10-49 | `GestLen||Gestation Length is blank`; `GestLen|99|Gestation Length is invalid` |
| `PERWT` | decimal > 0 and < 10 (kg, up to 3 decimals, leading zeros accepted) | `PERWT||Person Weight is blank`; `PERWT|0|Person Weight is invalid` (also `10.01`, `11.50`, `5&29`, `4/15`) |
| `CCAC_nn` | blank or one of the 77 CCAC codes (padded or unpadded; `2` ≡ `02`) | `CCAC_02|20|Critical Care Activity Code is invalid` (also `75`, `17`) |
| grouping | flowchart node 15 / fall-through | `CCAC_01|99|UZ11 - Neonatal Critical Care Error` (Code = `CCAC_01` value, also `21`) |

---

## NRD — National Renal Dataset (renal dialysis)

**Input columns** (`HRG4+_default_NRD.rdf`, RDF field labels `RenalMod, RenalSite, RenalAccess,
HBV, HCV, HIV, Age`; CSV headers in the test data):
`RENALMOD, RENALSITE, RENALACCESS, HBV, HCV, HIV, AGE`

**Main output** `[name]_renal.csv`: input columns, then `RowNo, NRD_HRG`. Other outputs:
`_quality`, `_quality_rel`, `_summary` (`NRD Record Count`, `NRD Record Error Count`). No
`GroupingMethodFlag`, no sort. One row = one haemodialysis session or one day of peritoneal
dialysis.

**Grouping**: Code To Group type `Renal`, code = `RENALMOD`, evaluated with the generic
HRG/Flag engine (last satisfied pair wins) on data items `RenalSite` = `RENALSITE`,
`RenalAccess` = `RENALACCESS`, `RenalBBV` = (`HBV`, `HCV`, `HIV`) upper-cased (positions 1-3),
`Age` = `AGE`; the root is split by `p` (age ≤ 18 → `…B`, else `…A`). Blank `RENALACCESS` → the
"via haemodialysis catheter" HRGs; blank BBV fields → "without blood-borne virus".

**Validation**

| Field | Valid values | Messages observed |
|---|---|---|
| `RENALMOD` | `01`-`15` (leading zero required) | `RENALMOD|+|Renal Treatment Modality is invalid`; blank presumably `… is blank` |
| `RENALSITE` | `01`-`04` | `RENALSITE||Treatment Supervision Code is blank`; `RENALSITE|08|Treatment Supervision Code is invalid` (also `05`, `&`) |
| `RENALACCESS` | blank or `01`-`07` | `RENALACCESS|4|Type of Dialysis is invalid` (also `09`, `-`) |
| `HBV` | blank, `POS`, `NEG`, `UNK` (case-insensitive: `pos` accepted) | `HBV|UN|Hepatitis B Surface Antigen Status is invalid` |
| `HCV` | as `HBV` | not observed (presumably `Hepatitis C Antibody Status is invalid`) |
| `HIV` | as `HBV` (`neg` accepted) | `HIV|NE|HIV Blood Test is invalid` (also `PO`) |
| `AGE` | integer 0-130 | `AGE||Age is blank`; `AGE|132|Age is invalid` |
| grouping | `RENALMOD` `09`-`15` (transplant, conservative care, recovery, none), or modality `05`-`08` whose `RENALSITE` matches no site flag (blank/invalid site) | `RENALMOD|09|UZ14 - Renal (NRD) Error` (Code = the modality; reported **in addition** to the site message when the site is blank/invalid) → `UZ01Z` |
