# Prescribed Specialised Services Operational Tool (PSO) — engine specification

Verified against NHS England's *PS 2025/26 Operational Tool Sample Data and Expected Results
v1.0* (tool `PSO2526_1.0.0`, database `PSO2526_20250128`): 300/300 APC episodes on every output
field and quality message, 44/44 spell rows, 200/200 NAC attendances. Sources: *PSO 2025/26
Prescribed Services Guide to Identification Rules v1.1.xlsm* (and the *Version 2* workbook),
*PSS 2025/26 Operational Tool User Manual v1.0*, both *Summary of Changes* documents.

## 1. Source tables

| Sheet | Used for | Notes |
|---|---|---|
| `Code Sets` | lists, rules, service lines, NPoC | **Authoritative.** Carries the 2025/26 provider changes (e.g. `RAL` additions), renamed trusts and leading-zero `REFSOURC`. |
| `Doc Flags to List Members` | `Function_ID`, `Flag_Order` per (doc flag, list) | Cross-checked: `Dominant Procedure` ⇔ `DGVPInList`; a combination value ⇔ `Nested…`. |
| `Summary` | service-line hierarchy incl. `CCGPS08S_Exc` (82) | Checked equal to `Service Line Hierarchy` for every NCBPS line. |
| `Code Hierarchy List` | OPCS-4 hierarchy (9,921 codes), valid ICD-10 (16,139) / OPCS-4 | Identical to the HRG4+ 2025/26 Local Payment `ProcHier`. |
| `List Members`, `Codes(W)` | *not used* | Stale 2024/25 dump: lacks `PS34J_OPCS4/5`, the `RAL` additions and the `REFSOURC` leading zero. |

Reference lists for `SEX`, `CLASSPAT`, `ADMIMETH`, `MAINSPEF`, `TRETSPEF` come from the Local
Payment 2025/26 Code to Group reference data (the tool is built on that grouper's database; the
sample's invalid values 3 / 6 / 10 / 832, 990 / 900, 312, R130, 620 are all absent from those
lists and the valid ones present). `ATTENDED` (2–7) and `REFSOURC` (01–07, 10–17, 92, 93, 97)
follow the NHS Data Dictionary (sample: 5, 6 valid; 8, 05 invalid; 01, 02, 03, 05, 10, 11, 14,
17, 97 valid; 08, 5 invalid).

The generic provider code `PSS` is added to every provider eligibility list (User Manual, "Use
of the Generic PSS provider code"); it is not in the workbook.

## 2. Record evaluation

1. **Validation** (message order = field order). APC: `PROCODET` blank, `PROVSPNO` blank,
   `STARTAGE` (input column `AGE` or `STARTAGE`; blank / not an integer in 0–130 or 999),
   `SEX`, `CLASSPAT`, `ADMIMETH`, `MAINSPEF`, `TRETSPEF` (blank / invalid), `DIAG_01` blank →
   "Primary Diagnosis is blank", any `DIAG_nn` not a valid ICD-10 (after removing dots,
   upper-casing; `K632X` is invalid, `C58X` valid), any `OPER_nn` not a valid OPCS-4. NAC:
   `PROCODET`, `STARTAGE`, `SEX`, `ATTENDED` ("Attendance Status Code"), `REFSOURC` ("Referral
   Source"), `MAINSPEF`, `TRETSPEF`, diagnoses (blank allowed), procedures. A record with any
   error gets no service lines.
2. **Dominant procedure** = the OPCS-4 code with the highest hierarchy value, the first recorded
   on ties (qualifier codes have value 0 and are *not* excluded; no combination-code formation).
3. **Rules.** Each documentation flag (`PSxxx_flag[n]`, `_OP_` for NAC) is a conjunction of list
   conditions; a service line is flagged when any of its flags holds:
   * `Age`: `min ≤ age ≤ max`, or `age == 999` when the band says so (`17 - 130, 999`).
   * `Org`: `PROCODET` in the list (exact match).
   * `SEX`, `ADMIMETH`, `MAINSPEF`, `TRETSPEF`, `ATTENDED`, `REFSOURC`: value in the list.
   * `ICD`: `Primary Diagnosis` → `DIAG_01` in list; `Any Position` → any diagnosis;
     `Secondary Diagnoses` → any of `DIAG_02..`.
   * `OPCS` `DataItemInList` (`Dominant or Secondary Procedure` / `Any Position`) → any
     procedure in list; `DGVPInList` (`Dominant Procedure`) → the dominant procedure in list.
   * `NestedDataItemInList`: for every combination value 1..n of the list, at least one
     procedure (any position) carries that value; `NestedDGVPInList`: the dominant procedure
     has value 1 and values 2..n are present anywhere.
4. **Outputs.** `ServiceLineList` = flagged lines, alphabetical, `;`-separated. `ServiceLine`
   = the flagged line with the highest hierarchy of the setting; `NPOC` = its programme of care
   (`B05` of `B05 - CHILDREN AND YOUNG ADULT CANCER SERVICES`).
5. **Spells (APC).** Records sorted by `PROCODET`, then `PROVSPNO`, as strings, blanks first,
   stable; a spell = same (`PROCODET`, `PROVSPNO`). `SpellServiceLine` = highest-hierarchy line
   over all lines of the spell's error-free episodes; error episodes contribute nothing but the
   spell is still output. `_spell.csv` carries the first episode's `RowNo`.

## 3. Version 2 (May 2026)

No algorithm change. Differences from Version 1, all reproduced by the importer and matching
the Summary of Changes: new NAC line `NCBPS32B` (hierarchy 39, shifting 17 NAC lines up by
one), `H043` added to `PS33B_OPCS`, `RW1` → `PS14A_Org`, `RPY` → `PS31Z_OP_Org`, `RAL` removed
from `PS27B_Org`, `RN5` removed from `PS51A_Org`.

## 4. Not exercised by the sample data (open)

* `CCGPS08S_Exc` (hierarchy 82 > `NCBPS08S` 64): modelled as a service line with no NPoC, so
  when it fires it appears in the list and wins the episode / spell dominance. Whether the tool
  prints it under that name is unverified (needs an eligible provider; the sample only uses
  `ZZZ`).
* Provider eligibility is never satisfied in the sample (`ZZZ`), so `Org` conditions and the
  `PSS` bypass are verified only structurally.
* Five-character (non-NHS) provider codes are matched exactly; whether the tool also tries the
  first three characters is unknown.
* Ages 7001–7007 (HRG4+ baby codes) are treated as invalid; the manual asks for whole years.
* `ATTENDED` 2–4, 7 and `REFSOURC` values other than those listed above are validation-only
  assumptions (every NAC rule needs `ATTENDED` 5/6 anyway).
