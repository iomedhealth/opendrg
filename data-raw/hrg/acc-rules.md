# Adult Critical Care (XC) grouping rules — HRG4+ 2024/25 National Costs Grouper

Source: Chapter Summaries v1.0, Subchapter XC pp. 187-190 (the flowchart on p. 188 is an image and
is not machine-extractable; the organ-count rule below was reconstructed from the prose on p. 187
and the official test data) and User Manual v1.1 pp. 65-66 (inputs) and p. 86 (outputs). The rules
are stated exactly as the verified prototype implemented them (250/250 `ACC_HRG`, 250/250
`Calc_CC_Days`, all `CC_Warning_Flag` values in the official test data). One HRG per input row
(= one adult critical-care period, not per day).

## Inputs

| Field | Meaning | Valid / handling |
|---|---|---|
| `CCUF` | critical care unit function | `1`,`2`,`3`,`5`,`6`,`7`,`8`,`9`,`01`,`02`,`03`,`05`,`06`,`07`,`08`,`09`,`10`,`11`,`12`,`90`,`91` (`Reference Data`, field `ACC_CCUF`). Anything else (e.g. `04`, `13`, `18`, blank) is an error. |
| `BCSD`, `ACSD`, `BRSD`, `ARSD`, `RSD`, `NSD`, `DSD`, `LSD` | basic/advanced cardiovascular, basic/advanced respiratory, renal, neurological, dermatological, liver support days | integer 0-99999; **blank is treated as 0 without an error** (test row 116) |
| `CCL2D`, `CCL3D` | level 2 / level 3 days | integer 0-99999; blank treated as 0 |
| `CC_Start_Date`, `CC_Discharge_Date` | `YYYYMMDD` | not required for the HRG; used only for `Calc_CC_Days`/`CC_Warning_Flag` |

Gastrointestinal support days are not an input and do not count (CS p. 187). The "Organ Support
Maximum" field is not used (CS p. 187).

## Validation and errors

| Condition | Message (`Code Type|Code|Message`) | Effect |
|---|---|---|
| `CCUF` blank | `CCUF||Critical Care Unit Function is blank` (by analogy with PCC/NCC; not observed) | `UZ01Z` |
| `CCUF` not in the valid list | `CCUF|04|Critical Care Unit Function is invalid` | `UZ01Z` |
| organ count = 0 **and** `CCL2D + CCL3D = 0` (incl. all-blank rows) | `CCUF|01|UZ13 - ACC grouping error` (Code = the CCUF value) | `UZ01Z` |
| non-numeric day field | not observed; treat as invalid (message text unknown) | — |

Date problems are **not** errors: they only set `Calc_CC_Days = -1` and `CC_Warning_Flag = F`
(test rows 55, 107, 158 group normally with a blank start date; row 222 is `UZ01Z` only because it
also has no organ support and no L2/L3 days).

## Organ-count rule and HRG

```
n(x) = integer value of field x, blank -> 0

organs = [ARSD > 0]
       + [BRSD > 0]
       + [ACSD > 0]
       + [BCSD > 0 and BRSD == 0 and ACSD == 0]     # basic cardiovascular support counts only when
       + [RSD  > 0]                                 # it is not accompanied by basic respiratory or
       + [NSD  > 0]                                 # advanced cardiovascular support
       + [DSD  > 0]
       + [LSD  > 0]

if organs == 0 and n(CCL2D) + n(CCL3D) == 0:  -> UZ13 error, ACC_HRG = UZ01Z
else ACC_HRG = { 0: XC07Z, 1: XC06Z, 2: XC05Z, 3: XC04Z, 4: XC03Z, 5: XC02Z, >=6: XC01Z }[organs]
```

Labels: `XC01Z` 6+ organ systems supported … `XC06Z` one organ system supported, `XC07Z` no organ
systems supported (requires at least one level-2 or level-3 day).

Evidence for the basic-cardiovascular clause (all from the official test data): `BCSD 2, BRSD 2`
→ `XC06Z` (1 organ; CS p. 187 "where basic respiratory and basic cardiovascular support occur on
1 day, it is counted as 1 organ"); `BCSD 4, ACSD 1` → `XC06Z`; `BCSD 19, ACSD 3, ARSD 19` →
`XC05Z`; `BCSD 79, BRSD 10, ARSD 69, DSD 1` → `XC04Z`; `ACSD 2, BRSD 2` → `XC05Z` (advanced
cardiovascular and basic respiratory are *not* merged); `BCSD 3, BRSD 3, RSD 3` → `XC05Z`;
`ARSD 1, BRSD 1` → `XC05Z` (basic and advanced respiratory are separate organs, CS p. 189 case A).
Alternative formulas (counting cardiovascular as one organ whenever either field is set, or merging
basic respiratory with basic cardiovascular symmetrically) match only 243/250 or fewer.

## `Calc_CC_Days` and `CC_Warning_Flag` (UM p. 86)

```
start <- parse(CC_Start_Date, "YYYYMMDD"); end <- parse(CC_Discharge_Date, "YYYYMMDD")
Calc_CC_Days <- if (start or end missing/unparseable, or end < start) -1
                else (end - start) in days + 1

CC_Warning_Flag <- "F" if any of:
    Calc_CC_Days == -1
    n(CCL2D) + n(CCL3D) > Calc_CC_Days
    n(ARSD)  + n(BRSD)  > Calc_CC_Days
    n(ARSD)  + n(BRSD)  > n(CCL2D) + n(CCL3D)
  else blank
```

The warning never prevents HRG derivation (UM p. 86). Verified on all 250 test rows (11 flagged:
4 with a blank start date, the others by one of the three inequalities).

## Output (`[name]_acc.csv`)

Input columns, then `RowNo`, `ACC_HRG`, `Calc_CC_Days`, `CC_Warning_Flag`. There is no
`GroupingMethodFlag` for ACC. `RowNo` is the input row number (no sorting is applied to ACC).
