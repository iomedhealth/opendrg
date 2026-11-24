# MS-DRG oracle run summary

- TESTDB: `/Users/gabriel.maeztu/repos/open-grd/target/MS-DRG V44 FY2027 (CMS)/_extract/mainframe/msdrg/MS-DRG440.R0.MF.Java.GenRel.Software_package/CMSDRG440_MF_Java_Misc/TESTDB`
- grouper version: `auto` (mode both, numeric parsing strict/wrapper-identical)
- runtime options: poaReportingExempt = per record from TESTDB col 7 (X = EXEMPT, otherwise NON_EXEMPT); markingLogicTieBreaker = CLINICAL_SIGNIFICANCE; computeAffectDrg = COMPUTE; trace = false
- records read: 9864; grouped OK: 1922; grouper errors: 0; skipped: 7942
- final DRG differs from initial DRG (HAC re-grouping): 27
- DRG 998: 1; DRG 999: 102

## Counts by final return code

| return_code | name | n |
|---|---|---|
| 0 | OK | 1820 |
| 1 | DX_CANNOT_BE_PDX | 45 |
| 7 | INVALID_PDX | 57 |

## Counts by final MDC

| mdc | n |
|---|---|
| 0 | 102 |
| 1 | 393 |
| 2 | 39 |
| 3 | 46 |
| 4 | 57 |
| 5 | 242 |
| 6 | 77 |
| 7 | 49 |
| 8 | 210 |
| 9 | 63 |
| 10 | 99 |
| 11 | 67 |
| 12 | 21 |
| 13 | 27 |
| 14 | 45 |
| 15 | 11 |
| 16 | 15 |
| 17 | 38 |
| 18 | 32 |
| 19 | 17 |
| 20 | 4 |
| 21 | 153 |
| 22 | 6 |
| 23 | 75 |
| 24 | 23 |
| 25 | 11 |

## Final severity / med-surg / HAC status

| field | value | n |
|---|---|---|
| final_severity | CC | 402 |
| final_severity | MCC | 529 |
| final_severity | NONE | 103 |
| final_severity | NON_CC | 888 |
| final_med_surg | MEDICAL | 963 |
| final_med_surg | NONE | 103 |
| final_med_surg | SURGICAL | 856 |
| hac_status | FINAL_DRG_CHANGES | 27 |
| hac_status | NOT_APPLICABLE | 1895 |

## Top 20 final DRGs

| drg | n |
|---|---|
| 60 | 233 |
| 999 | 102 |
| 914 | 72 |
| 951 | 50 |
| 923 | 44 |
| 983 | 39 |
| 57 | 33 |
| 3 | 32 |
| 605 | 20 |
| 628 | 20 |
| 629 | 15 |
| 630 | 15 |
| 10 | 13 |
| 607 | 13 |
| 462 | 11 |
| 495 | 10 |
| 496 | 10 |
| 497 | 10 |
| 518 | 10 |
| 922 | 10 |

(763 distinct final DRGs)

## Agreement with the expectations embedded in TESTDB

The embedded expectations were produced by CMS with the grouper version selected by discharge date (version id PPPVVVUU in columns 1993-2000). `rtc+drg` compares return code and final DRG; `full` compares the whole 1162-byte output except the version id.

| embedded version id | n | rtc+drg agree | full agree |
|---|---|---|---|
| 00140000 | 186 | 186 | 186 |
| 00140100 | 292 | 292 | 292 |
| 00141000 | 315 | 315 | 315 |
| 00141100 | 62 | 62 | 62 |
| 00142000 | 115 | 115 | 115 |
| 00142100 | 107 | 107 | 107 |
| 00143000 | 748 | 748 | 748 |
| 00143100 | 20 | 20 | 20 |
| 00144000 | 77 | 77 | 77 |
| **all** | 1922 | 1922 (100.0%) | 1922 (100.0%) |

## Records skipped by the API run

| n | reason |
|---|---|
| 14 | discharge date selects version 390 which is only available through the mainframe wrapper (v1 model) |
| 7926 | discharge date selects version 391 which is only available through the mainframe wrapper (v1 model) |
| 1 | DateBeforeValidVersionException: Date is before any valid versions |
| 1 | MalformedDateException: Malformed date |
