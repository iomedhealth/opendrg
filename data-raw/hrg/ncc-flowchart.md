# Neonatal Critical Care (XA) grouping flowchart — HRG4+ 2024/25 National Costs Grouper

Source: Chapter Summaries v1.0, Subchapter XA, flowchart on pp. 168-170 (15 numbered nodes) and
the field table in the User Manual v1.1 pp. 69-70. This logic is **not** in the Code To Group
workbook; it is transcribed in the exact form evaluated by the verified prototype (300/300
`NCC_HRG` in the official test data). One HRG per input row (= one critical-care day).

## Inputs used

* `CCUF` — `13` (NICU), `14` (neonatal transitional care ward), `15` (maternity ward). Single-digit
  values are zero-padded before comparison (there are none that are valid).
* `CCAC_01..CCAC_20` — the day's Critical Care Activity Codes, zero-padded (`2` → `02`). "has(x, y,
  …)" = at least one of the listed codes is present on the day.
* `CCDate`, `DISDATE` — `YYYYMMDD` strings (compared for equality only).
* `DISMETH` — discharge method of the hospital provider spell.
* `AGE_DAYS` — age in whole days on the activity date (integer).
* `GestLen` — gestation length at delivery in completed weeks (integer).
* `PERWT` — birth/person weight in kg (decimal, e.g. `1.26`).

## Validation (field errors → `UZ01Z`; all observed in the official test data)

| Field | Valid | Messages (`Code Type|Code|Message`) |
|---|---|---|
| `CCUF` | `13`, `14`, `15` | `CCUF||Critical Care Unit Function is blank`; `CCUF|4|Critical Care Unit Function is invalid` (also `8`, `16`, `+`) |
| `AGE_DAYS` | integer 0-999 | `AGE_DAYS||Age in days is blank` (invalid-value text not observed; presumably `Age in days is invalid`) |
| `DISMETH` | `1`-`9` | `DISMETH||Discharge Method is blank`; `DISMETH|&|Discharge Method is invalid` (also `10`) |
| `GestLen` | integer 10-49 | `GestLen||Gestation Length is blank`; `GestLen|99|Gestation Length is invalid` |
| `PERWT` | decimal, > 0 and < 10 (kg) | `PERWT||Person Weight is blank`; `PERWT|0|Person Weight is invalid` (also `10.01`, `11.50`, `5&29`, `4/15`) |
| `DISDATE` | `YYYYMMDD` | `DISDATE||Discharge Date is blank` |
| `CCDate` | `YYYYMMDD` | (`CCDate||Critical Care Date is blank` by analogy with PCC; not observed for NCC) |
| `CCAC_nn` | one of the 77 CCAC codes in `Reference Data` (padded or unpadded) | `CCAC_02|20|Critical Care Activity Code is invalid` (also `75`, `17`) |
| `PROCODET`, `CCLocalID` | not validated | — |

Grouping errors: node 15 produces `CCAC_01|<CCAC_01 value>|UZ11 - Neonatal Critical Care Error`
and `UZ01Z` (test rows 240, 244, 253, 254, 284). `UZ21 - CCAC inappropriate in NCC` is documented
(UM p. 95) but not observed.

## Steps (evaluated strictly in this order; the first satisfied step decides)

| Node | Condition | Result |
|---|---|---|
| 1 | `CCUF` not in {`13`, `14`, `15`} | `UZ01Z` ("not a period of neonatal critical care") |
| 2 | `CCDate == DISDATE` **and** `DISMETH == 4` (baby died on this day) | `XA01Z` (reading of the chart: the "Yes" arrow joins the intensive-care outcome; unexercised by the test data) |
| 3 | has(`07`) **and** has(`02`, `53`, `80`) — parenteral nutrition with nCPAP / non-invasive ventilatory support / HHHFT | `XA01Z` |
| 4 | has(`03`) **and** `CCUF == 13` — surgery on a NICU | `XA01Z` |
| 5 | has(`01`, `04`, `05`, `06`, `11`, `12`, `16`, `51`, `66`, `69`, `81`, `82`, `83`, `84`, `85`, `86`) | `XA01Z` Neonatal Critical Care, Intensive Care |
| 6 | has(`02`, `07`, `08`, `13`, `14`, `53`, `55`, `80`, `87`, `88`, `90`, `91`, `92`) | `XA02Z` Neonatal Critical Care, High Dependency |
| 7 | `AGE_DAYS <= 2` and `PERWT <= 2` (kg) | → special care (node S) |
| 8 | `AGE_DAYS <= 2` and `GestLen == 35` | → special care (node S) |
| 9 | `AGE_DAYS <= 7` and `GestLen == 34` | → special care (node S) |
| 10 | `GestLen < 34` | → special care (node S) |
| 11 | has(`10`) **and** has(`28`) — neonatal abstinence syndrome with regular observations | → special care (node S) |
| 12 | has(`09`, `23`, `24`, `29`, `89`, `93`) | → special care (node S) |
| S | has(`21`) (carer resident, caring for baby) ? | yes `XA04Z` Special Care, with External Carer / no `XA03Z` Special Care, without External Carer |
| 13 | has(`26`) — phototherapy | `XA05Z` Neonatology Supported Care **(reading verified by test rows 61 and 245; routing phototherapy to special care instead gives the wrong HRG)** |
| 14 | `CCUF == 13` **and** has(`10`, `15`, `21`, `22`, `25`, `27`, `28`, `99`) | `XA05Z` |
| 15 | `CCUF` in {`14`, `15`} **and** has(`03`, `10`, `15`, `21`, `22`, `25`, `27`, `28`, `99`) | `UZ11` error → `UZ01Z` ("not a period of neonatal critical care") |
| — | otherwise (no CCAC at all, or only codes not listed above, e.g. `03` on CCUF 14/15 is covered by 15) | not reached in the test data; treat as `UZ11` → `UZ01Z` |

Notes

* Nodes 7-12 are *alternative* entries to the same special-care decision S; a day satisfying any of
  them is `XA04Z` if CCAC `21` is present, else `XA03Z`.
* The transport HRG `XA06Z` is not produced here; it comes from the APC dataset (`TRETSPEF 422` +
  `XA_neotrans`: ADMIMETH ∈ {28, 81, 2B}, ADMISORC ∈ {52, 87}, NEOCARE ∈ {2, 3}).
* Test-data coverage (300 days): node 1:6, 3:20, 5:17, 6:40, 7:6, 8:1, 10:154, 12:16, 13:2, 14:33,
  15:5; nodes 2, 4, 9 and 11 are unexercised; CCAC `21` within special care occurs on 5 days.

## Evaluation order and sorting (pseudo-code)

```
# sort: stable sort by PROCODET, CCLocalID, CCDate as text (blank CCLocalID sorts first);
#       RowNo = position after sorting (verified against the official _sort.csv)
for row in sorted_rows:
    if field validation errors: NCC_HRG <- "UZ01Z"; continue
    cuf   <- zero_pad(row.CCUF); codes <- zero_pad(non-blank CCAC_01..20)
    age   <- int(AGE_DAYS); wt <- numeric(PERWT); gl <- int(GestLen)
    if cuf not in {13,14,15}:                                   -> UZ01Z
    if CCDate == DISDATE and DISMETH == "4":                    -> XA01Z
    if has(07) and has(02,53,80):                               -> XA01Z
    if has(03) and cuf == 13:                                   -> XA01Z
    if has(01,04,05,06,11,12,16,51,66,69,81,82,83,84,85,86):    -> XA01Z
    if has(02,07,08,13,14,53,55,80,87,88,90,91,92):             -> XA02Z
    if (age<=2 and wt<=2) or (age<=2 and gl==35) or (age<=7 and gl==34) or gl<34
       or (has(10) and has(28)) or has(09,23,24,29,89,93):      -> if has(21) XA04Z else XA03Z
    if has(26):                                                 -> XA05Z
    if cuf == 13 and has(10,15,21,22,25,27,28,99):              -> XA05Z
    if cuf in {14,15} and has(03,10,15,21,22,25,27,28,99):      -> UZ11 error, UZ01Z
    else:                                                       -> UZ11 error, UZ01Z (unexercised)
```

No per-period history is needed for NCC (every node looks only at the current day).
