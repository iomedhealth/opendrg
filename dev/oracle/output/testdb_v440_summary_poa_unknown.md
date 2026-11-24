# MS-DRG oracle run summary

- TESTDB: `/Users/gabriel.maeztu/repos/open-grd/target/MS-DRG V44 FY2027 (CMS)/_extract/mainframe/msdrg/MS-DRG440.R0.MF.Java.GenRel.Software_package/CMSDRG440_MF_Java_Misc/TESTDB`
- grouper version: `440` (mode api, numeric parsing strict/wrapper-identical)
- runtime options: poaReportingExempt = UNKNOWN; markingLogicTieBreaker = CLINICAL_SIGNIFICANCE; computeAffectDrg = COMPUTE; trace = false
- records read: 9864; grouped OK: 9864; grouper errors: 0; skipped: 0
- final DRG differs from initial DRG (HAC re-grouping): 73
- DRG 998: 101; DRG 999: 217

## Counts by final return code

| return_code | name | n |
|---|---|---|
| 0 | OK | 9647 |
| 1 | DX_CANNOT_BE_PDX | 48 |
| 7 | INVALID_PDX | 96 |
| 10 | HAC_STATUS_INVALID_POA_N_OR_U | 73 |

## Counts by final MDC

| mdc | n |
|---|---|
| 0 | 217 |
| 1 | 1227 |
| 2 | 121 |
| 3 | 115 |
| 4 | 357 |
| 5 | 1456 |
| 6 | 295 |
| 7 | 80 |
| 8 | 1690 |
| 9 | 519 |
| 10 | 215 |
| 11 | 143 |
| 12 | 45 |
| 13 | 90 |
| 14 | 550 |
| 15 | 105 |
| 16 | 118 |
| 17 | 492 |
| 18 | 67 |
| 19 | 83 |
| 20 | 4 |
| 21 | 847 |
| 22 | 88 |
| 23 | 324 |
| 24 | 398 |
| 25 | 218 |

## Final severity / med-surg / HAC status

| field | value | n |
|---|---|---|
| final_severity | CC | 2100 |
| final_severity | MCC | 2285 |
| final_severity | NONE | 318 |
| final_severity | NON_CC | 5161 |
| final_med_surg | MEDICAL | 5689 |
| final_med_surg | NONE | 318 |
| final_med_surg | SURGICAL | 3857 |
| hac_status | FINAL_DRG_UNGROUPABLE | 73 |
| hac_status | NOT_APPLICABLE | 9791 |

## Top 20 final DRGs

| drg | n |
|---|---|
| 60 | 229 |
| 999 | 217 |
| 914 | 174 |
| 305 | 149 |
| 842 | 141 |
| 923 | 126 |
| 951 | 119 |
| 304 | 117 |
| 768 | 105 |
| 832 | 105 |
| 99 | 104 |
| 970 | 102 |
| 392 | 101 |
| 536 | 101 |
| 547 | 101 |
| 554 | 101 |
| 563 | 101 |
| 566 | 101 |
| 998 | 101 |
| 607 | 100 |

(759 distinct final DRGs)

## Agreement with the expectations embedded in TESTDB

The embedded expectations were produced by CMS with the grouper version selected by discharge date (version id PPPVVVUU in columns 1993-2000). `rtc+drg` compares return code and final DRG; `full` compares the whole 1162-byte output except the version id.

| embedded version id | n | rtc+drg agree | full agree |
|---|---|---|---|
| 00000000 | 2 | 0 | 0 |
| 00139000 | 14 | 13 | 7 |
| 00139100 | 7926 | 6367 | 5937 |
| 00140000 | 186 | 184 | 61 |
| 00140100 | 292 | 274 | 265 |
| 00141000 | 315 | 290 | 290 |
| 00141100 | 62 | 55 | 47 |
| 00142000 | 115 | 104 | 100 |
| 00142100 | 107 | 107 | 106 |
| 00143000 | 748 | 728 | 720 |
| 00143100 | 20 | 19 | 19 |
| 00144000 | 77 | 76 | 76 |
| **all** | 9864 | 8217 (83.3%) | 7628 (77.3%) |
