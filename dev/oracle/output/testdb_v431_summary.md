# MS-DRG oracle run summary

- TESTDB: `/Users/gabriel.maeztu/repos/open-grd/target/MS-DRG V44 FY2027 (CMS)/_extract/mainframe/msdrg/MS-DRG440.R0.MF.Java.GenRel.Software_package/CMSDRG440_MF_Java_Misc/TESTDB`
- grouper version: `431` (mode api, numeric parsing strict/wrapper-identical)
- runtime options: poaReportingExempt = per record from TESTDB col 7 (X = EXEMPT, otherwise NON_EXEMPT); markingLogicTieBreaker = CLINICAL_SIGNIFICANCE; computeAffectDrg = COMPUTE; trace = false
- records read: 9864; grouped OK: 9864; grouper errors: 0; skipped: 0
- final DRG differs from initial DRG (HAC re-grouping): 72
- DRG 998: 101; DRG 999: 140

## Counts by final return code

| return_code | name | n |
|---|---|---|
| 0 | OK | 9724 |
| 1 | DX_CANNOT_BE_PDX | 48 |
| 7 | INVALID_PDX | 92 |

## Counts by final MDC

| mdc | n |
|---|---|
| 0 | 140 |
| 1 | 1273 |
| 2 | 121 |
| 3 | 115 |
| 4 | 356 |
| 5 | 1462 |
| 6 | 295 |
| 7 | 80 |
| 8 | 1692 |
| 9 | 519 |
| 10 | 238 |
| 11 | 143 |
| 12 | 45 |
| 13 | 90 |
| 14 | 550 |
| 15 | 105 |
| 16 | 119 |
| 17 | 492 |
| 18 | 67 |
| 19 | 83 |
| 20 | 4 |
| 21 | 845 |
| 22 | 88 |
| 23 | 326 |
| 24 | 398 |
| 25 | 218 |

## Final severity / med-surg / HAC status

| field | value | n |
|---|---|---|
| final_severity | CC | 2104 |
| final_severity | MCC | 2299 |
| final_severity | NONE | 241 |
| final_severity | NON_CC | 5220 |
| final_med_surg | MEDICAL | 5390 |
| final_med_surg | NONE | 241 |
| final_med_surg | SURGICAL | 4233 |
| hac_status | FINAL_DRG_CHANGES | 72 |
| hac_status | NOT_APPLICABLE | 9792 |

## Top 20 final DRGs

| drg | n |
|---|---|
| 60 | 229 |
| 914 | 174 |
| 842 | 141 |
| 983 | 140 |
| 999 | 140 |
| 923 | 127 |
| 951 | 119 |
| 959 | 106 |
| 305 | 105 |
| 768 | 105 |
| 832 | 105 |
| 908 | 104 |
| 304 | 103 |
| 907 | 103 |
| 909 | 103 |
| 99 | 102 |
| 970 | 102 |
| 392 | 101 |
| 536 | 101 |
| 547 | 101 |

(765 distinct final DRGs)

## Agreement with the expectations embedded in TESTDB

The embedded expectations were produced by CMS with the grouper version selected by discharge date (version id PPPVVVUU in columns 1993-2000). `rtc+drg` compares return code and final DRG; `full` compares the whole 1162-byte output except the version id.

| embedded version id | n | rtc+drg agree | full agree |
|---|---|---|---|
| 00000000 | 2 | 0 | 0 |
| 00139000 | 14 | 13 | 7 |
| 00139100 | 7926 | 6855 | 6367 |
| 00140000 | 186 | 184 | 184 |
| 00140100 | 292 | 283 | 274 |
| 00141000 | 315 | 311 | 311 |
| 00141100 | 62 | 57 | 57 |
| 00142000 | 115 | 115 | 115 |
| 00142100 | 107 | 107 | 106 |
| 00143000 | 748 | 748 | 748 |
| 00143100 | 20 | 20 | 20 |
| 00144000 | 77 | 33 | 21 |
| **all** | 9864 | 8726 (88.5%) | 8210 (83.2%) |
