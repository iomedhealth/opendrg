# NHS England HRG4+ 2024/25 National Costs Grouper — Engine Specification for Re-implementation

This document is an implementation contract for re-implementing (in R) the *published* grouping
algorithm of the HRG4+ 2024/25 National Costs Grouper. It is derived **only** from the official
documentation suite and the official test data:

| Abbrev. | Source (all under `/Users/gabriel.maeztu/repos/open-grd/target/HRG4+ 202425 National Costs Grouper/`) |
|---|---|
| `C2G` | `docs/HRG4 202425 National Costs Grouper Code To Group v1.0.xlsx` — the design database (17 sheets). Cited as `C2G:<sheet>`. |
| `UM` | `docs/HRG4 202425 National Costs Grouper User Manual v1.1.pdf` (cited by printed page number `UM p.N`). |
| `CS` | `docs/HRG4 202425 National Costs Grouper Chapter Summaries v1.0.pdf` (cited `CS p.N, <subchapter>`). |
| `SoC` | `docs/HRG4 202425 National Costs Grouper Summary of Changes v1.0.pdf`. |
| `TD` | `docs/_extract/HRG4+ 202425 National Costs Grouper Test Data and Expected Results v1.0/<DATASET>/…` (cited `TD APC row N` = `RowNo` in the `_FCE.csv` / `_sort.csv`). |
| `RDF` | `_extract/Default RDF/*.rdf` (default input layouts). |

**Verification status.** Every rule below marked *[verified]* was implemented in a throw-away R
prototype (not part of the deliverable) and checked against the expected results: the prototype
reproduces **750/750** `FCE_HRG`, `GroupingMethodFlag` and `DominantProcedure`; **477/477**
`SpellHRG`, `SpellGroupingMethodFlag`, `SpellDominantProcedure`, `SpellPDiag`, `SpellSDiag`,
`SpellLOS`, `SpellCCDays` and `SpellReportFlag`; all 83 field/clinical-coding quality messages
(the 20 remaining expected messages are spell-level cross checks, §1.5); all unbundled HRG
multisets (748/750 in exact output order, §5.6); all `FCE_PBC`; and, for the other datasets,
200/200 NAC, 300/300 EM, 200/200 NRD, 250/250 ACC, 300/300 NCC, 250/250 PCC HRGs. Rules marked
*[documented]* come from the PDFs; *[inferred]* rules are not stated anywhere but were required to
reproduce the test data; *[open]* items are listed in §11.

Terminology: **FCE** = finished consultant episode (one input row of APC); **spell** = all rows with
the same `PROCODET`+`PROVSPNO`; **PH** = procedure hierarchy value (`C2G:Hierarchy Lists`,
`List ID = ProcHier`); **DH** = diagnosis hierarchy value (`DiagHier`); **root** = 4-character
HRG root (e.g. `FD10`); **HRG** = 5-character HRG (e.g. `FD10L`); **GMF** = `GroupingMethodFlag`.

---

## 1. Inputs (Admitted Patient Care)

### 1.1 Record layout

Input is a comma-separated ASCII file without text qualifiers (UM p.54). The column order is
defined by a Record Definition File; the default APC RDF (`RDF/HRG4+_default_APC.rdf`) is
`PROCODET, PROVSPNO, EPIORDER, STARTAGE, SEX, CLASSPAT, ADMISORC, ADMIMETH, DISDEST, DISMETH,
EPIDUR, MAINSPEF, NEOCARE, TRETSPEF, DIAG_01..DIAG_14, OPER_01..OPER_12, CRITICALCAREDAYS,
REHABILITATIONDAYS, SPCDAYS`. The number of `DIAG_nn`/`OPER_nn` columns is variable (up to 99,
UM p.59-60); extra columns are carried through unchanged (UM p.35). An RDF may carry a
`Picture` (keep/ignore character positions, `A`/`.`) and `Extract` (characters to delete anywhere)
per field, applied before validation (UM p.43-46); full stops in diagnosis/procedure codes are
removed automatically (UM p.43).

### 1.2 APC input fields

Source: UM p.58-61 (field table), `C2G:Reference Data` (valid values), `C2G:Simple Flags`
(which fields the logic reads).

| Field | Mandatory | Valid values (`C2G:Reference Data`) | Used by logic as DataItem |
|---|---|---|---|
| `PROCODET` | yes | any non-blank string, not validated | spell key, sort key |
| `PROVSPNO` | yes | any non-blank string, not validated | spell key, sort key |
| `EPIORDER` | yes | 0–87 (98, 99 invalid); duplicates within a spell are an error | sort key |
| `STARTAGE` | yes | 0–130 or 999 (not known); whole years | `Age` |
| `SEX` | yes | `0` (retired), `1`, `2`, `9`, `X` | `SEX`; spell consistency |
| `CLASSPAT` | yes | `1`,`2`,`3`,`4`,`5`,`8` | spell consistency only (no flag reads it) |
| `ADMISORC` | yes | 19,29,37,39,40,42,49,51,52,53,54,55,56,65,66,79,85,87,88,98,99 | `ADMISORC`; spell consistency |
| `ADMIMETH` | yes | 11,12,13,21,22,23,24,25,28,31,32,81,82,83,98,99,2A,2B,2C,2D | `ADMIMETH`; spell consistency |
| `DISDEST` | yes | 19,29,30,37,38,40,42,48,49,50,51,52,53,54,55,56,65,66,79,84,85,87,88,89,98,99 | `DISDEST` (spell uses last episode) |
| `DISMETH` | yes | `1`..`9` | `DISMETH` (spell uses last episode) |
| `EPIDUR` | yes | integer 0–99999 (whole days) | `EpiDur` (after adjustment, §7.2) |
| `MAINSPEF` | yes | 89 codes (100…960), see `Reference Data` | `MAINSPEF` |
| `NEOCARE` | no | blank or `0`,`1`,`2`,`3`,`8`,`9` | `NEOCARE` |
| `TRETSPEF` | yes | 180 codes (100…920) | `TRETSPEF` |
| `DIAG_01` | yes | valid ICD-10 code (§1.3) | `Diagnosis` position 1 |
| `DIAG_02..nn` | no | valid ICD-10 code or blank | `Diagnosis` positions 2.. |
| `OPER_01..nn` | no | valid OPCS-4 code or blank | `Procedure` positions 1.. |
| `CRITICALCAREDAYS` | no | 0–99999 or blank | LoS adjustment, `SpellCCDays` |
| `REHABILITATIONDAYS` | no | 0–99999 or blank | LoS adjustment, `*n` multiplier |
| `SPCDAYS` | no | 0–99999 or blank | LoS adjustment, `*n` multiplier, (probably) `EpiDur` position 4 (§3.3) |

Codes in `Reference Data` are strings; some fields accept both zero-padded and unpadded forms
(e.g. `ACC_CCUF` lists `1` and `01`; `CCAC` lists `1` and `01`). For APC fields compare the
trimmed input string with the `Code` column exactly (`ADMIMETH` `2A` is alphanumeric).

### 1.3 Code normalisation

* ICD-10: the design uses 4- or 5-character codes **without the decimal point**; 3-character
  categories carry the filler `X` as 4th character (e.g. `R13X`, `A33X`); 5-character codes are
  the 4th-character code plus a 5th character (e.g. `S3250`, `M0896`, `J9600`). The valid set is
  `C2G:ICD-10` (16,139 codes, ICD-10 4th/5th edition; no dagger/asterisk suffixes exist in the
  design). *[verified]* Input codes are compared after removing full stops and upper-casing; codes
  not in the sheet are invalid (`TD APC` rows 5, 17: `I48X`, `R69X6`, `N180`, `L89X`, `H547`,
  `A09X` are invalid). A code with a dagger/asterisk marker (`D`/`A`) would therefore be invalid
  unless the RDF `Picture`/`Extract` strips it (UM p.43-46) — the grouper has no documented
  dagger/asterisk handling *[open Q13]*.
* OPCS-4: 4 characters without the decimal point (`C2G:OPCS`, 9,921 codes, OPCS-4.2 … 4.10).
* Blank `DIAG_nn`/`OPER_nn` cells are ignored; **positions are counted over the non-blank codes
  in input order** (`OPER_01, OPER_03` populated → positions 1 and 2) — *[inferred]* from the
  flag position semantics; blanks before populated cells do not occur in the test data *[open Q14]*.
* Other fields: compared as trimmed strings (NRD `pos`/`POS` are both accepted, `TD NRD row 10`,
  so upper-case the three blood-borne-virus fields before comparison *[verified]*).

### 1.4 Sorting and spell identification

Before grouping, APC rows are sorted by `PROCODET`, `PROVSPNO`, `EPIORDER` (UM p.58, p.72) and
`RowNo` (1-based position after sorting) is assigned; it links all output files (UM p.71). A
spell = consecutive rows with the same `PROCODET` and `PROVSPNO` (UM p.58). `_sort.csv` of the
test data equals the input order; whether `PROVSPNO` sorts as text or as a number cannot be
told from it *[open Q15]*.

### 1.5 Validation rules and quality messages

Validation never stops processing; all errors of a record are reported together (UM p.92).
Message format `Code Type|Code|Error Message`; `Code` is blank when the error is an absence
(UM p.92-93). Three classes (UM p.93):

**(a) Field validation errors** — produced per episode; any one of them makes the episode
`UZ01Z` with GMF `U` (UM p.92). Messages observed in `TD APC/NAC/EM/NRD/ACC/NCC/PCC …_quality_rel.csv`
and their conditions (all *[verified]* on the test data unless noted):

| Code Type | Message | Condition |
|---|---|---|
| `DIAG_01` | `Primary Diagnosis is blank` | `DIAG_01` empty |
| `DIAG_01` | `Primary Diagnosis is invalid` | `DIAG_01` not in `C2G:ICD-10` |
| `DIAG_nn` (n≥2) | `Secondary Diagnosis is invalid` | non-blank `DIAG_nn` not in `C2G:ICD-10` |
| `OPER_nn` | `Procedure is invalid` | non-blank `OPER_nn` not in `C2G:OPCS` (UM p.92, p.93; not exercised by TD) |
| `SEX` | `Sex is blank` / `Sex is invalid` | blank / not in Reference Data (`3`, `x` are invalid) |
| `CLASSPAT` | `Patient Classification is invalid` (`… is blank` presumed) | not in `1,2,3,4,5,8` |
| `ADMISORC` | `Admission Source is blank` / `… is invalid` | |
| `ADMIMETH` | `Admission Method is invalid` (`… is blank` presumed) | |
| `DISDEST` | `Discharge Destination is blank` (`… is invalid` presumed) | |
| `DISMETH` | `Discharge Method is blank` / `… is invalid` | |
| `EPIDUR` | `Episode Duration is blank` (`… is invalid` presumed for non-integer / >99999) | |
| `MAINSPEF` | `Main Specialty Code is blank` / `… is invalid` | |
| `TRETSPEF` | `Treatment Function Code is blank` / `… is invalid` | |
| `STARTAGE` | `Age is blank` / `Age is invalid` | blank / not 0–130 and not 999 (NAC `132`, EM `131`,`140`,`210` invalid) |
| `NEOCARE` | presumably `Neonatal Level of Care is invalid` | non-blank value not in list *[open Q16: exact text]* |
| `CRITICALCAREDAYS`, `REHABILITATIONDAYS`, `SPCDAYS` | not observed | UM p.60-61 says range 0–99999 or blank *[open Q16]* |
| `EPIORDER` | not observed | 98/99 invalid; duplicate within spell is an error (UM p.58) *[open Q16]* |

**(b) Spell validation errors** — cross checks over the episodes of a spell (UM p.93). They are
reported **on every episode of the spell**, they make the **spell** HRG `UZ01Z`/`U`, but they do
**not** change the episode HRGs (`TD APC` rows 473-478 keep `WH04E` while `SpellHRG = UZ01Z`).
Observed messages (`Code` always blank):

| Code Type | Message | Condition (*[inferred]* from TD rows 473-478, 627-628, 679-681, 749-750) |
|---|---|---|
| `SEX` | `Sex is inconsistent in spell` | more than one distinct `SEX` value in the spell |
| `CLASSPAT` | `Patient Classification is inconsistent in spell` | more than one distinct value (an invalid value such as `10` still counts) |
| `ADMISORC` | `Admission Source is inconsistent in spell` (presumed, UM p.59) | more than one distinct value |
| `ADMIMETH` | `Admission Method is inconsistent in spell` | more than one distinct value |
| `STARTAGE` | `Age falls in episodes in the spell` | a later episode (in `EPIORDER` order) has a lower age (75→61) |
| `STARTAGE` | `Age rises by more than expected in the spell` | age increases by more than 1 between episodes (1→21); +1 is accepted (40→41 over 30 episodes). Whether the comparison is consecutive-episode or first-vs-later is *[open Q17]*. |

**(c) Clinical-coding errors** — produced by the grouping logic itself when a `UZnn` root is
reached (§3.6, §6.1). Message texts (UM p.93-95, confirmed in TD): `UZ01 - Invalid Primary
Diagnosis`, `UZ02 - Poorly Coded Primary Diagnosis`, `UZ03 - Diagnosis Conflicts with Age`,
`UZ04 - Diagnosis Conflicts with Anatomical Site`, `UZ05 - Invalid procedure for Casemix grouping
purposes`, `UZ06 - Poorly coded procedure for Casemix grouping purposes`, `UZ15 - Burns Error`,
`UZ11 - Neonatal Critical Care Error`, `UZ13 - ACC grouping error`, `UZ14 - Renal (NRD) Error`,
`UZ21 - CCAC inappropriate in NCC` (text not observed). `Code Type` is the field that carried the
offending code (`DIAG_01` for UZ01-04/15, `OPER_nn` of the offending procedure for UZ05/06).

---

## 2. Reference data model (`C2G` workbook)

All sheets have a header row; read every column as text. Row counts are as in the file.

| Sheet | Rows | Columns / meaning |
|---|---|---|
| `HRG & Subchapters` | 2,900 | `HRG, HRG Description, Core or Unbundled? (Core/Unbundled/Both/EM/NRD), HRG Subchapter, …, HRG Chapter, …`. 2,583 Core, 278 Unbundled (LE 4, RD 47, RN 68, SB 17, SC 29, SD 10, VC 23, XA 6, XB 9, XC 7, XD 58), `UZ01Z` is `Both`, 12 EM, 26 NRD. |
| `OPCS` | 9,921 | `OPCS Code, Description, Introduced in OPCS-4 Version` — the valid OPCS-4 set. |
| `ICD-10` | 16,139 | `ICD-10 Code, Description, ICD-10 Edition` — the valid ICD-10 set. |
| `Reference Data` | 640 | `Grouper Field Name, Description, Code, Relates to Grouper Module(s), Code Description, notes` — valid values per field (§1.2). |
| `Code To Group` | 39,474 | 84 subchapter columns (`AA`…`YR`, `Y` = the row references an HRG root of that subchapter — purely derived, *[verified]* for all rows), then `Code to Group Type, Code Type, Code, Code Description, HRG 1, Flag 1 … HRG 23, Flag 23`. |
| `Group To Split` | 1,274 | `HRG Root, HRG Root Description, HRG 1, Flag 1 … HRG 21, Flag 21`. One row per root; every root referenced by `Code To Group` exists except the pseudo-root `UZ99` (§5.4); every HRG except the XA/XB/XC critical-care HRGs is reachable (those are produced by hard-coded flowcharts, §10). `Flag 1` is always `a`. |
| `Documentation Flags` | 1,338 | `HRG Chapter, HRG Subchapter, Documentation Flag ID, Doc Flag description` — English text for every flag (the only sheet mentioning `a` = "Base HRG"/"Base PBC"). |
| `Simple Flags` | 1,788 | `HRG Chapter, HRG Subchapter, Documentation Flag ID, Flag Order, Function ID, DataItem ID, DataItem Order Min, DataItem Order Max, List ID, Code Value Sum Min` — the formal definition of 1,146 distinct flags (§4). |
| `Hierarchy Lists` | 31,294 | `List ID (DiagHier/ProcHier/NCCHier/PCCHier), Code Type, Code, Code Description, Hierarchy Value`. `ProcHier` covers all 9,921 OPCS codes **and** all 5,080 combination codes; `DiagHier` all 16,139 ICD codes. |
| `Other Lists` | 55,551 | `List ID, Code Type, Code, Code Description, Value` — 347 lists; code types `ICD, OPCS, Combination, Age, EpiDur, SEX, ADMISORC, ADMIMETH, DISDEST, DISMETH, MAINSPEF, TRETSPEF, NEOCARE, FIRSTATT, RenalSite, RenalAccess, RenalBBV`. `Value` populated only for scoring lists (§4.3). |
| `CC Lists` | 158,466 | `List ID, Code Type (ICD), Code, Code Description, Value (1 or 2)` — 44 complication/comorbidity lists, one code at most once per list. |
| `Global Lists` | 1,399 | `List ID (Approach 550 / Site 844 / PNCO 5), Code Type, Code, Description`. `Approach` ∪ `Site` = the 1,394 **qualifier codes** (all PH 0; Y-, Z-, O- codes plus 58 "conversion from" codes such as `W540`, `G060`). |
| `Combination Lists` | 904 | `List ID (CL_…), Code Type, Code, Description` — 157 lists of qualifier codes used by combination definitions. |
| `Combination Code` | 5,080 | `Combination Code, Description, Combination Code Order, Driving Code, Driving Code Description, Qualifier Type 1, Qualifying Code 1, …, Qualifier Type 2, Qualifying Code 2, …` (§5). |
| `PBC Mappings` | 16,139 | `Code to Group Type (PBC1), Code Type (ICD), Code, Description, PBC 1, Flag 1 (a), PBC 2, Flag 2 (q_pbcv)` (§8.1). |
| `PBC Labels` | 57 | `PBC, PBC Label` (includes `PBC02U1 Primary Diagnosis Not Recognised`, `PBC02U2 Unclassified`). |

`Code to Group Type` values and row counts (`C2G:Code To Group`):

| Type | Code Type(s) | Rows | Role |
|---|---|---|---|
| `Core1` | ICD 16,139; OPCS 8,967; Combination 5,052 | 30,158 | standard logic: primary-diagnosis rows and dominant-procedure rows (§3.6) |
| `Core3` | HRG6 (`JB91`…`JB97`) | 7 | burns severity escalation from a dummy root (§3.8) |
| `Core4` | ICD 842; OPCS 2,438; Combination 3,244 | 6,524 | multiple trauma entry (ICD) and intervention score (procedures) (§3.7) |
| `Core5` | `N/A` | 1 | global exceptions (§3.9) |
| `Core6` | MAINSPEF 89 | 89 | outpatient default `WF01`/`WF02` (NAC only, §10.1) |
| `Core7` | `N/A` | 1 | burns entry (§3.8) |
| `EM` | AEPatGroup 1; Combination 2,324 | 2,325 | emergency medicine grid (§10.2) |
| `Renal` | RenalMod 15 | 15 | NRD (§10.6) |
| `Uassess, UChem1, UChem2, UDrugs, URad, URadiot1, URadiot2, Urehab, URenal` | OPCS (+11 Combination in URad) | 6+14+9+96+169+13+9+28+5 | code-driven unbundled HRGs (§6) |
| `UNPCC` | TRETSPEF 242, 422 | 2 | critical-care transport unbundled HRGs (§6.3) |
| `USPC1`, `USPC2` | TRETSPEF 315 | 1+1 | specialist palliative care, inpatient / outpatient (§6.3) |
| `USPC3` | `N/A` | 1 | specialist palliative care support by secondary diagnosis (§6.3) |

Every OPCS code appears in exactly one of: a `Core1` row (PH ≥ 3 and the 1,910 PH-0 codes, whose
row is `UZ05[a]` or `UZ06[a]`), an unbundled-type row (PH 2 and the 67 PH-0 "unspecified"
unbundled codes mapped to `UZ06`), or **no row at all** (the 633 PH-1 codes — "Ignored for
grouping", CS p.161). Codes with a `Core1` row may additionally have a `Core4` row. *[verified]*

---

## 3. Episode (FCE) grouping algorithm

### 3.1 Overview and order of operations

For each episode (after sorting, §1.4):

```
group_episode(ep):
  1. errs      <- field validation (§1.5a)                       # does not stop processing
  2. diags     <- non-blank DIAG codes (normalised), positions 1..n
     procs     <- non-blank OPER codes (normalised), positions 1..m
     CalcEpidur<- max(0, EPIDUR - CRITICALCAREDAYS - REHABILITATIONDAYS - SPCDAYS)   (§7.2)
  3. eff       <- form_combination_codes(procs)                  (§5)   # same length as procs
  4. unbundled <- unbundle(eff, ctx)                              (§6)   # also marks "consumed" positions
  5. dom       <- dominant_procedure(eff, consumed)               (§3.4) # may be NA
  6. root/GMF  <- core grouping, first of:                        (§3.5–3.9)
        Core7 burns (B)  >  Core4 multiple trauma (M)  >  Core1 procedure-driven (P)
        >  Core5 global exception (G)  >  Core1 diagnosis-driven (D)
  7. if root has a Core3 row: root <- Core3 escalation(root)      (§3.8)
  8. if root is a UZnn root: HRG <- UZ01Z, add clinical-coding error (§3.6)
     else HRG <- Group To Split(root)                              (§3.10)
  9. if errs non-empty or any unbundled HRG == UZ01Z: HRG <- UZ01Z, GMF <- U   (UM p.92)
 10. FCE_PBC   <- PBC mapping of diags[1]                          (§8.1)
```

The precedence in step 6 is documented for B over Core 1 (CS p.22, DX; CS p.63, JB "irrespective
of the primary diagnosis code or any procedures recorded"), M over "any other grouping logic"
(CS p.148, VA), P over D ("Core 1 procedure-driven grouping takes precedence over Core 1
diagnosis-driven grouping", CS p.21), and G over D ("Core 5 … takes precedence over Core 1 logic",
CS p.22). G is placed **after** P because every Core 5 HRG requires "no (other) significant
procedure" (CS p.22, p.133, p.138, p.127, p.163) *[inferred; B vs M and G vs P are not exercised by
TD — open Q1, Q2]*. Steps 4–5 run even when step 1 found errors (`DominantProcedure` and
`UnbundledHRGs` are still output for `U` episodes, e.g. `TD APC` rows 79, 170) *[verified]*.

### 3.2 GroupingMethodFlag values

`P` procedure driven, `D` diagnosis driven, `B` burns driven, `M` multiple trauma, `G` global
exception, `U` error (UM p.72). NAC additionally has `O` outpatient default (UM p.79, §10.1).

### 3.3 Context ("data items") seen by flags

A flag reads one *DataItem* as a vector of string values with 1-based positions (§4.2):

| DataItem ID | Vector |
|---|---|
| `Diagnosis` | `diags` (position 1 = primary diagnosis) |
| `Procedure` | `eff` (effective procedure codes after combination formation, §5) — with the view restrictions of §4.2 |
| `Age` | `[STARTAGE]` |
| `EpiDur` | `[CalcEpidur, CRITICALCAREDAYS?, REHABILITATIONDAYS?, SPCDAYS]` — position 1 = **adjusted** LoS *[verified: TD rows 67, 70, 71, 72, 74, 134 group correctly only with the adjusted value]*; position 4 is read only by `SD_SPC_Diag_5`/`SD_SPC_HRC_Diag3` ("SPC DAYS = 0", CS p.143) — mapping of positions 2–4 to the three day-count fields in input order is *[inferred; open Q5]* |
| `SEX`, `ADMISORC`, `ADMIMETH`, `DISDEST`, `DISMETH`, `MAINSPEF`, `TRETSPEF`, `NEOCARE`, `FIRSTATT` | the single field value |
| `RenalSite`, `RenalAccess` | the single field value (NRD) |
| `RenalBBV` | `[HBV, HCV, HIV]` upper-cased (NRD; the LD BBV flags read positions 1..3) *[verified]* |

### 3.4 Dominant procedure *[verified on all 750 episodes]*

```
dominant_procedure(eff, consumed):
  candidates <- positions i such that
      not consumed[i]                                   # produced an unbundled HRG (§6.2)
      and not (eff[i] in QUALIFIER and exists j < i with eff[j] not in QUALIFIER)
                                                        # qualifier codes are attached to the
                                                        # preceding real code and never dominant
  if no candidates: return NA
  i* <- the candidate with the highest PH(eff[i]); ties -> lowest position
  return eff[i*]
```

* `QUALIFIER` = `C2G:Global Lists` `Approach` ∪ `Site` (1,394 codes, all PH 0). A qualifier code
  that is not preceded by any non-qualifier code *is* a candidate; alone it groups to `UZ05`
  (`TD NAC` rows 29 and 52: `Y903`/`Y909` as the only code → `DominantProcedure = Y903`, `UZ05`).
  `TD APC` row 54 (`U052` consumed, then `Y981`) → no dominant *[verified]*.
* PH comes from `ProcHier` (combination codes have their own PH, e.g. `W283` PH 1 but
  `W283+FOOT` PH ≥ 5, `TD APC` row 359).
* Codes with PH 1 (ignored for grouping) and unconsumed PH-2 codes **can** be the dominant
  procedure and are reported in `DominantProcedure` (`TD APC` row 55 `X598` PH 1 → GMF `D`;
  rows 255-312 `X403` PH 2 whose `URenal` row failed → `DominantProcedure = X403`, GMF `D`).
  They simply have no `Core1` row, so grouping falls through to diagnosis-driven.
* A PH-0 non-qualifier code (e.g. `A069`, `U378`) as dominant groups to `UZ06`/`UZ05`.
* "The OPCS-4 code with the highest procedure hierarchy value in the record" (CS p.146, UZ05).

### 3.5 Code-To-Group row evaluation (the HRG n / Flag n pairs) *[verified]*

A `Code To Group` row (and a `Group To Split` row) is an ordered list of pairs
`(HRG 1, Flag 1), …, (HRG k, Flag k)` (empty cells end the list). Evaluation:

```
eval_pairs(ctx, pairs):
  for j from k down to 1:            # scan from the LAST pair to the first
      if eval_flag(ctx, Flag j): return HRG j
  return NA                          # no pair satisfied (possible when Flag 1 != 'a')
```

i.e. **the last satisfied pair wins** (equivalently: the first satisfied pair when scanning from
the right). Forward "first satisfied wins" reproduces only 350/750 episodes. The design places
the default `a` first and increasingly specific/higher-resource conditions later, e.g.
`AA22G[a] AA22F[AA_CC_5] AA22E[AA_CC_8] AA22D[AA_CC_11] AA22C[AA_CC_14]` (CC thresholds are
"at least n", so all lower ones are also true) and `K262`: `ED25[a] ED23[ED_CABG] … EC13[p] EC12[…]
EC11[…]` (paediatric/congenital routes override the adult routes). `a` is the always-true base
flag (`C2G:Documentation Flags`: "Base HRG"); it never appears in `Simple Flags`.

**Core1 procedure rows need not contain `a`.** E.g. `X411 → LA05[LoS_0to1]`, `E852 → DZ37[LoS_0]`,
`G451 → FE21[LoS_0to1] FE23[p_LoS_0to1] FE44[…]`. When no pair is satisfied the procedure-driven
step yields nothing and grouping "flips" to diagnosis-driven (the "maximum length of stay logic",
CS p.21 DX, p.9 AA, p.13 BZ …); `DominantProcedure` is still reported and GMF becomes `D`
(`TD APC` row 132: `E852` PH 9, CalcEpidur 2 → `DZ20D`, GMF `D`) *[verified]*.

### 3.6 Core 1 — standard logic *[verified]*

```
core1(ctx, dom, diags):
  # procedure-driven
  if dom is not NA and there is a Core1 row with Code Type OPCS/Combination and Code == dom:
      ctx.pdriven <- TRUE                       # §4.2: 'additional procedure' excludes dom
      root <- eval_pairs(ctx, row);  ctx.pdriven <- FALSE
      if root is not NA: return (root, 'P')
  # (Core 5 is tried here, §3.9)
  # diagnosis-driven
  if diags non-empty and there is a Core1 row with Code Type ICD and Code == diags[1]:
      root <- eval_pairs(ctx, row)              # every ICD row starts with a default pair
      if root is not NA: return (root, 'D')
  return (NA, NA)
```

The same code string can exist as ICD and as OPCS (e.g. `X403`, `K262`, `C712`): look rows up by
`(Code to Group Type, Code Type class, Code)` where the class is `ICD` vs `OPCS|Combination`.

If the resulting root starts with `UZ` it is an error root: `UZ01` (invalid as primary, 3,864 ICD
rows, e.g. `Z509`, `Z511`, all `Z53.-`), `UZ02` (poorly coded, 47), `UZ03` (age conflict, 276 —
rows such as `P050 → UZ03[a] PB04[Age_0to1] PB05[Age_0to1_Ad_OHP]`), `UZ04` (anatomical site, 27),
`UZ15` (burns without TBSA, 84 ICD rows), `UZ05`/`UZ06` (1,490 + 420 OPCS rows, all PH 0). The
episode HRG becomes `UZ01Z`, GMF `U`, and the matching clinical-coding message is added (§1.5c;
`TD APC` rows with `UZ01 - Invalid Primary Diagnosis` and `UZ06` reproduce exactly). `Group To
Split` also contains `UZ01`…`UZ15 → UZ01Z[a]`, so simply splitting the root gives `UZ01Z` too.

Rows exist for every valid ICD code (16,139) — a valid primary diagnosis therefore always yields a
root — so D-grouping can only fail to produce a root when `DIAG_01` is blank/invalid (already an
error).

### 3.7 Core 4 — multiple trauma (GMF `M`) *[verified: TD APC rows 3, 21, 104, 260-264]*

Two kinds of `Core4` rows (`C2G:Code To Group`): 842 ICD rows, each exactly
`VA10[VA_cmpt_<site>]`, and 5,682 OPCS/Combination rows, each exactly
`VA11[a] VA12[VA_p09_18] VA13[VA_p19_29] VA14[VA_p30_44] VA15[VA_pgt44]`.

```
core4(ctx, dom, diags):
  row <- Core4 ICD row for diags[1];  if none: return NA        # primary must be a VA_* injury
  root <- eval_pairs(ctx, row)                                   # VA10 iff a secondary diagnosis
  if root is NA: return NA                                       # is on the complementary list
  if dom not NA and a Core4 OPCS/Combination row exists for dom: # Comp_VA_<site> (CS p.148-149)
      r2 <- eval_pairs(ctx, that row);  if r2 not NA: root <- r2 # VA11..VA15 by procedure score
  return (root, 'M')
```

`VA_cmpt_<site>` = `DataItemInList Diagnosis 2..100000 Comp_VA_<site>` ("at least 2 trauma codes,
one the primary, each a different body site", CS p.148). `VA_p09_18` etc. = `SumListValues
Procedure 1..100000 MT_OPCS_Value ≥ 9/19/30/45` (values 5–13 per code). `Group To Split VA1n`
= `VA1nA[a] VA1nB[VA_d24_32] VA1nC[VA_d33_50] VA1nD[VA_dgt50]` with `SumDistinctValues Diagnosis
1..100000 MT_ICD_Value` (values 3–7) — the grid on CS p.149. Only the dominant procedure's row is
used for the procedure band (not every procedure's row); the score itself sums all procedures.
Spell-level special rule: CS p.148 (§7.5).

### 3.8 Core 7 / Core 3 — burns (GMF `B`) *[verified: TD APC rows 6, 453]*

```
core7(ctx):
  root <- eval_pairs(ctx, the single Core7 row)     # Code Type N/A, Code N/A
  # row: UZ15[JB_2_3Deg] JB91[JB_2_3Deg_TBSA] JB92[JB_23D_TBSA_1to4] JB93[JB_23D_TBSA_5to9]
  #      JB94[JB_23D_TBSA10t14] JB95[JB_23D_TBSA15t19] JB96[JB_2_3Deg_TBSA20]
  #      JB97[JB_2_3Deg_TBSA30] JB61[JB_Died_T_LoS0t2] JB61[JB_Tran_T_LoS0t2]
  if root is NA: return NA                           # no 2nd/3rd-degree burn anywhere -> not burns
  return (root, 'B')
core3(ctx, root):                                    # applied to whatever root step 6 produced
  row <- Core3 row (Code Type HRG6) with Code == root    # exists only for JB91..JB97
  if none: return root
  r <- eval_pairs(ctx, row); return if r is NA then root else r
```

All Core 7 flags look at diagnoses **in any position** (`1..100000`), so a 2nd/3rd-degree burn
recorded as a secondary diagnosis still routes the episode to burns (CS p.63). `UZ15` is produced
when a 2nd/3rd-degree burn has no TBSA code (`JB_TBSA`). The TBSA proxy bands use
`SumDistinctValues` over `JB_TBSA_10_Value`/`JB_TBSA_20_Value` (values ×10: head/neck 15/30,
trunk 30/90 …, CS p.64-65) — only distinct burn codes count (CS p.65). Core 3 rows escalate the
dummy root by age (`Age_60plus`/`Age_80plus`), face/hands/feet count (`JB_FHF_2/3`,
`SumDistinctValues JB_FaceHandsFeet` on positions 1..), CC score (`JB_CC_3/6/9` on positions 2..),
inhalation injury with ventilation and electric burns, combinations thereof, capped at +3 bands
(CS p.66); the `Group To Split` of `JB91`…`JB98` then applies age 0–15 and the intervention score
(`JB_Interv_1` = `DataItemInList JB_Interventions`, `JB_Interv_2` = `SumListValues ≥ 2`). First-degree
and internal burns do not enter Core 7; their ICD `Core1` rows map directly to `JB89/JB90/JB60/
JB94` (CS p.63-66) and are handled by the D path.

### 3.9 Core 5 — global exceptions (GMF `G`) *[verified: TD APC rows 151, 374, 495, 545, 638, 643]*

Single row (`Code Type N/A`): `WH99[WH_PNCO_B] WH50[WH_PNCO_A] RD97[RD_TFC_Rad_LoS_0]
RN97[RN_TFC_Rad_LoS_0] SB97[SB_Chemo_LoS_0] SB97[SB_Z511_LoS_0] SC97[SC_Radio_LoS_0]
SC97[SC_Z510_LoS_0] RD98[RD_TFC_Rad_GA]`. Evaluated with `eval_pairs`; if a root results and no
procedure-driven root was found, the episode is `G`. (`WH99` is a dummy root whose split is
`WH50B[a]`, CS p.164.) The "same day" HRGs require `EpiDur` position 1 (adjusted LoS) = 0 and read
the unbundled codes with `AllDataItemInList` (§4.1) because those codes have already been consumed
by unbundling (`TD APC` row 151: `U055 Y981 Z665`, TFC 812, LoS 0 → `RD97Z`).

Note that `X621/X622/X623/X629` (PH 3/4) carry the same `SB97/SC97` pairs in their own `Core1`
rows (`WF02[a] SB97[SB_Chemo_LoS_0] SC97[SC_Radio_LoS_0]`), so an attendance with `X622` + a
radiotherapy delivery code groups to `SC97Z` with GMF `P` (`TD NAC` row 6).

### 3.10 Group To Split *[verified]*

```
split(ctx, root):
  if root == 'UZ99': return NA                 # indicator pseudo-root, no HRG (§6.3)
  row <- Group To Split row for root           # exactly one; Flag 1 is always 'a'
  ctx.pdriven <- (GMF == 'P')                  # §4.2
  return eval_pairs(ctx, row)                  # never NA because of the 'a' pair
```

Typical split flags: CC-score thresholds (`SumDistinctValues <subchapter>_CC`, positions 2..),
paediatric `p` (= `Age` in `Age_0to18`) and finer age bands (`Age_0to1`, `Age_0to5`, `Age_2to17`,
`Age_0to15`, `Age_60plus`, `Age_80plus`), interventions (`DataItemInList Interventions`,
`SumListValues Interventions ≥ 2`), LoS bands (`WH20`: `LoS_0to4`, `LoS_5to8`), discharge
destination, `FIRSTATT` (WF roots), combinations (`LB_CC_4_Interv`). CC-score flags are "at least
n", so with last-wins the highest satisfied band is chosen.

---

## 4. The flag language (`C2G:Simple Flags`)

### 4.1 Function IDs *[all verified unless noted]*

A flag with `Documentation Flag ID = F` is the **AND** of all rows with that ID (rows are numbered
by `Flag Order`; 434 flags have 2–6 rows). Ten flag IDs (`p`, `LoS_0`, `LoS_0to1`, `LoS_0to2`,
`Age_0to1`, `Age_0to3`, `Age_0to4`, `Age_0to5`, `p_LoS_0`, `p_LoS_0to1`) are repeated verbatim
under several subchapters — de-duplicate on all columns. Each row is evaluated on the vector `V`
of its `DataItem ID` restricted to positions `DataItem Order Min .. DataItem Order Max`
(`100000` = to the end), against `List ID` (looked up in `Other Lists`, `CC Lists`, `Global
Lists`, `Combination Lists` — all 1,146 referenced lists exist in `Other Lists` or `CC Lists`).

| Function ID | Rows | Semantics | `Code Value Sum Min` |
|---|---|---|---|
| `DataItemInList` | 893 | true iff some `V[i]` (i in range) is a code of the list. For `Procedure` see the view rule in §4.2. | unused |
| `AllDataItemInList` | 15 | same test but on the **complete** effective procedure vector, including codes consumed by unbundling (lists: `RD_Unb_DiagImag`, `RN_Unb_NucMed`, `SB_Unb_Chemo`, `SC_Unb_Radio`, `LA_Dialysis_P`, `FF_TPN`, `EY_TOE`, `AA_Adv_Monitor`, `Gen_Anaesthetic`, `RD_Unb_DI_NM`) or the diagnosis vector (`SB_Unb_Chem_Diag` = `Z511`, `SC_Unb_Rad_Diag` = `Z510`). 94% of the procedure-list members are PH-2 unbundled codes; `DataItemInList` lists contain **no** PH-2 code — this is the only observable difference. `TD APC` row 151 fails if consumed codes are hidden. It is *not* "all items are in the list" (`TD` row 151 has `Y981`, `Z665` outside the list). | unused |
| `RelDataItemInList` | 193 | "subsidiary procedure code": true iff a code of the list is in the **qualifier run** of the procedure whose row is being evaluated (the dominant procedure, or the unbundled code) — the contiguous block of qualifier codes (§3.4 `QUALIFIER`) immediately following it, stopping at the next non-qualifier code (`TD APC` row 349: `Q074 Q231 Y752 Z943` — `Y752` is subsidiary to `Q231`, not to the dominant `Q074`, so `MA_Lap` is false). All 139 list members are qualifier codes (`Bilateral`, `Revisional`, `Rev2`, `Gen_Anaesthetic`, `Lap`, `Robot`, `Left`, `Right`, `RD_Post_Cont`, `Stent_Graft` …). | unused |
| `SumListValues` | 189 | sum of `Value` of **every** code occurrence of `V` (in range) found in the list ≥ `Code Value Sum Min`. Includes the dominant procedure ("summed value … inc dominant proc", `Documentation Flags`). Whether duplicate occurrences add up is not decidable from TD *[open Q7]*; the name and CS p.149 ("all relevant procedure codes") suggest they do. | threshold (1–45) |
| `SumDistinctValues` | 498 | sum of `Value` over the **distinct** codes of `V` (in range) found in the list ≥ threshold (`TD APC` row 311 with `H269` twice needs de-duplication). 466 rows are CC scores on `Diagnosis 2..100000` (primary excluded; including it breaks 129 episodes); 32 rows use `1..100000` (burns TBSA/face-hands-feet, `NZ_CC_Delivery_n` "including primary", `PM_PM45_n`, `VA_d*`). | threshold (1–150) |

Lists used with `Age` enumerate every integer age (`Age_0to18` = 0…18, `Age_60plus` = 60…130,
`Age_2to17` = 2…17, `Age_0` = 0); lists used with `EpiDur` enumerate day counts (`LoS_0` = 0,
`LoS_0to1`, `LoS_0to2`, `LoS_0to4`, `LoS_0to7`, `LoS_0to28`, `LoS_5to8`). `STARTAGE = 999` matches
no age list (adult HRGs result, no error). `Diagnosis` positions `1..1` = primary, `2..100000` =
secondaries, `1..100000` = any; `2..2` and `3..3` are used by four flags that look at "the first/
second secondary diagnosis" (`LA_Infection`, `PB_Carrier_Age_0`, `PB_Prophal_Age_0`).

Pseudo-code of the whole flag language (matches the prototype that reproduces the test data):

```
eval_flag(ctx, F):
  if F == 'a': return TRUE
  rows <- distinct Simple Flags rows with Documentation Flag ID == F      # AND over Flag Order
  for r in rows: if not eval_row(ctx, r): return FALSE
  return TRUE

eval_row(ctx, r):
  V <- data_item_vector(ctx, r.DataItemID, r.FunctionID)                   # §3.3 / §4.2
  V <- V[r.OrderMin .. min(r.OrderMax, length(V))]                          # 100000 = to the end
  L <- list members of r.ListID   (Other Lists ∪ CC Lists; Code column, exact string match)
  switch r.FunctionID:
    DataItemInList, AllDataItemInList, RelDataItemInList:
        return any(V in L)
    SumListValues:
        return sum( Value(L, v) for v in V if v in L ) >= r.CodeValueSumMin      # every occurrence
    SumDistinctValues:
        return sum( Value(L, v) for v in unique(V) if v in L ) >= r.CodeValueSumMin
```

**CC score** = `SumDistinctValues` over the subchapter CC list (`C2G:CC Lists`, `Value` 1 or 2 per
code) on `Diagnosis` positions `2..100000`: each *distinct* secondary diagnosis on the list adds
its value once; the primary diagnosis never counts (CS p.38, p.105: "standard grouping logic, where
the primary diagnosis code is not considered") except where the design says so explicitly, which
is implemented as separate flags — `NZ_CC_Delivery_n` (positions `1..`, CS p.105), the FD
`FD_CCn_PDiagCC` pairs (`DataItemInList Diagnosis 1..1 F_PdiagCC` AND a lower CC threshold, CS
p.38) and `PM_PM45_n_CC_m` (CS p.117-118). There is no cap other than the thresholds themselves
(max threshold 16 for CC lists, 150 for the burns TBSA list). A CC flag `XX_CC_n` is true for every
`n` ≤ score, which is why the split rows list the bands in ascending order and the last-wins rule
picks the highest band (§3.5).

### 4.2 The `Procedure` view *[verified]*

* `AllDataItemInList`: full effective vector `eff`.
* `RelDataItemInList`: qualifier run after the code whose row is being evaluated (§4.1).
* `DataItemInList`, `SumListValues`: the vector `eff` **except** that, while evaluating the
  dominant procedure's own `Core1` row and the `Group To Split` of a `P` root, `DataItemInList`
  ignores the dominant procedure's position ("an **additional** procedure code", e.g. `H_VMaj`,
  `GA_Transpl_Panc`; `TD APC` rows 76, 147, 252 etc. — 38 episodes break otherwise). It does
  **not** ignore it when the episode is grouped by diagnosis/burns/trauma (`TD` rows 132, 6, 398:
  the LoS-flipped dominant counts as an "intervention"). `SumListValues` always includes it.
  Unbundled codes, PH-1 codes and qualifier codes remain visible to `DataItemInList` (lists such
  as `Interventions`, `Bilateral`, `Left`, `Right`, `H_Int` contain `Z941`, `Z897`, …).
* A combination code replaces its driving code in `eff`; the qualifier codes that formed it stay
  in `eff` (CS p.56: `Z89.7` and `Z94.1` both still score on `H_Int`; scoring lists contain both
  `A018` (3) and `A018+O461` (8) so replacement avoids double counting).

### 4.3 List sheets used by each function

| Function | Lists (sheet) |
|---|---|
| `DataItemInList` on `Diagnosis` | `Other Lists` (ICD lists: `MA_Endometriosis`, `H_Malignancy`, `Comp_VA_*`, `JB_*`, `PNCO`-like `WH_PNCO_A/B`, `L_AKI` …) |
| `DataItemInList` on `Procedure` | `Other Lists` (OPCS/Combination lists, incl. `Interventions` (3,389 members), `WF_Multi`, `Bilateral`, `Left`, `Right`, `JB_Interventions` …) |
| `DataItemInList` on fields | `Other Lists` lists of type `Age`, `EpiDur`, `SEX` (`M_Female`), `ADMISORC`, `ADMIMETH` (`X_ADMIMETH_TRANS`), `DISDEST` (`JB_Transfer`, `DZ_Dis_Home`), `DISMETH` (`Died`, `Not_Died` = 1,2,3,6,7,8,9, `PB_Stillbirth`), `MAINSPEF`, `TRETSPEF`, `NEOCARE`, `FIRSTATT`, `RenalSite`, `RenalAccess`, `RenalBBV` |
| `SumDistinctValues` | `CC Lists` (44 `*_CC` lists, values 1/2) and the valued `Other Lists` `JB_TBSA_10_Value`, `JB_TBSA_20_Value`, `JB_FaceHandsFeet`, `NZ_CC`, `PM_Canc_Inf_Neut`, `MT_ICD_Value` |
| `SumListValues` | valued `Other Lists`: `AA_Proc_List`, `BZ_Proc_List`, `CA_*`, `DZ_*`, `EC_Proc_List`, `EY_PCI_Proc`, `FF_*`, `GA_*`, `G_*`, `HC_*`, `H_Int/H_Maj/H_Minor/H_VMaj`, `Interventions`, `JA_*`, `JB_Interventions`, `LB_*`, `MT_OPCS_Value` |
| `RelDataItemInList` | `Other Lists` qualifier lists |
| `Combination Code` qualifiers | `Combination Lists` (`CL_*`) |
| never read by flags | `Global Lists` (used by the engine: `Approach`/`Site` = qualifier codes; `PNCO` = the five `Z53.-` codes, informational), `Hierarchy Lists` (PH/DH), `NCCHier`/`PCCHier` (not used by the published flowcharts, §10) |

---

## 5. Combination codes (`C2G:Combination Code`, `Combination Lists`)

A combination code (`A592+ELBOW`, `K262+TAVI`, `U052+Y986`, `W903+IMAGE+HIP`, …) is a virtual
procedure code built from a **driving code** and one or two **qualifying codes**. 1,274 driving
codes have combinations (5,080 rows; 143 with two qualifiers; `Qualifier Type` is `Subsidiary`
except 4 rows with `Any Position`). `Qualifying Code` is either a single OPCS code or a
`CL_…` list from `Combination Lists` (e.g. `CL_Hip`, `CL_Image`, `CL_TAVI`). Every combination
code has its own PH in `ProcHier` (1–41), its own `Core1`/`Core4`/`URad` rows and may appear in
scoring lists.

```
form_combination_codes(procs):
  eff <- procs
  for each position i:
      cands <- Combination Code rows with Driving Code == procs[i],
               sorted by Combination Code Order DESCENDING          # higher order = tried first
      run   <- qualifier run after i (qualifier codes immediately following i, up to the
               next non-qualifier code)                              # 'Subsidiary'
      anyp  <- all other codes in procs                              # 'Any Position'
      for each cand: if every qualifier is matched (code in run/anyp, or any member of the
                     CL_ list in run/anyp): eff[i] <- cand; break    # at most one per position
  return eff
```

* Order *[documented]*: CS p.9/p.84 state the `A70.2` priority 1st `A702+Y032` … 4th `A702+Z112`;
  the sheet holds `Combination Code Order` 4,3,2,1 respectively, so **larger order wins**. The
  site hierarchy "Rib > Spine > Hip > Knee > Shoulder > Elbow > Hand > Foot" (CS p.56) is encoded
  as orders 6…1 for `A592+HIP` … `A592+FOOT` *[verified]*.
* "Subsidiary" = the qualifier run immediately after the driving code *[verified: TD APC row 625
  — `A522 V544 V553 Y535 …`: `Y535` (image control) belongs to `V544`, so `A522+IMAGE` is **not**
  formed and `V544` (PH 15 > `A522` PH 13) is the dominant → `AB16Z`]*; "anywhere after" would
  form `A522+IMAGE` (PH 15, earlier position) and give `AB20Z`.
* Whether a qualifier run is interrupted by a PH-1 "ignored" code or by an unbundled code is not
  exercised *[open Q8]*. The same qualifier may serve several driving codes only if it lies in
  each one's run (it cannot, since runs are disjoint).
* The combination replaces the driving code for: PH, dominant selection, `Core1`/`Core4`/
  unbundled row lookup, list membership and scoring (§4.2). `DominantProcedure` outputs the
  combination code string (`T851+Z941`, `W903+IMAGE+HIP`).
* Combination formation applies to unbundled driving codes too (`U052+Y986` → `RD` row; 7 driving
  codes are PH 2; 11 combination codes are PH 2 and live in `URad`).

---

## 6. Unbundled HRGs

### 6.1 Code-driven unbundled HRGs *[verified]*

For **each position** `i` of `eff` (duplicates included: `U201` twice → `RD51A,RD51A`,
`TD APC` row 342) and each unbundled `Code to Group Type` `T` in {`Uassess`, `UChem1`, `UChem2`,
`UDrugs`, `URad`, `URadiot1`, `URadiot2`, `Urehab`, `URenal`}: if a row `(T, eff[i])` exists,
evaluate it with `eval_pairs` (the "current procedure" for `RelDataItemInList`/"additional" is
position `i`, e.g. `RD_Post_Cont` looks at the qualifier run after the scan code). If a root
results: mark position `i` as **consumed**; if the root is `UZ05`/`UZ06` the unbundled HRG is
`UZ01Z`, the episode becomes `UZ01Z`/`U` and an `OPER_nn|code|UZ06 - …` message is added (`TD`
rows 78-80); otherwise the HRG is `Group To Split(root)`. If no pair is satisfied (e.g. `X403 →
LE01[LE_AKI]` without an AKI diagnosis) nothing is produced and the code is **not** consumed
(it may become the dominant procedure, §3.4).

Subchapters and triggers (CS p.98 LE, p.127 RD, p.129 RN, p.133 SB, p.138 SC, p.158 VC, p.192 XD):

| Type | Codes | HRGs | Notes |
|---|---|---|---|
| `URad` | diagnostic imaging and nuclear medicine OPCS (`U0x`–`U3x`, contrast radiology …) and 11 radionuclide combinations | `RD01`–`RD51` (unbundled; `RD97`/`RD98` are core), `RN*` | splits by subsidiary codes: contrast (`RD_Post_Cont`, `RD_PrePost_Cont`), body areas (`RD_2or3_Area`, `R_2or3_Area`, `RD_4_Area`), duration/mobile (`RD_3Area_20to40m`, `RD_40mins`, `RD_Mob_IntOp`), repositioning (`RD_Repos`); GTS by age (`p`, `Age_0to5`). Unspecified codes (`U019`…) → `UZ06`. |
| `UChem1` | `X701`–`X719` procurement | `SB01`–`SB10`, `SB16` (`X708`); `X709`, `X718`, `X719` → `UZ06` | per cycle |
| `UChem2` | `X721`–`X739` delivery | `SB11`–`SB15`, `SB17`; `X728` → `UZ06` | `SB_Chemo_App` (`A542`) pairs are redundant (same HRG) |
| `UDrugs` | `X74*`, `X81*`–`X98*` high-cost drugs | `XD01`–`XD91` one-to-one; "other/unspecified" → `UZ06` | CS p.192 says one HRG per **distinct** drug code; the engine evaluates per occurrence — duplicates are *[open Q9]* |
| `URadiot1` | `X67*`, `X68*` planning | `SC40`–`SC57` (+`SC_Y921` subsidiary) | |
| `URadiot2` | `X65*`, `X69*` delivery | `SC21`–`SC31` by subsidiary `Y91.x`/`Y80` codes | |
| `Urehab` | `U50*`–`U54*` | `VC04`–`VC42` | per diem via `*n` (§6.4) |
| `Uassess` | `X60*` | `VC01`–`VC03` | per instance, no multiplier |
| `URenal` | `X401`,`X402`,`X403`,`X405`,`X406` | `LE01`/`LE02` (`[LE_AKI]`: AKI diagnosis in any position) | GTS by `p` |

### 6.2 Effect on core grouping

Consumed positions are excluded from the dominant-procedure candidates (§3.4) — this is how
"where the dominant procedure … has a PH value of 2, an unbundled HRG will be derived (in addition
to the core HRG)" (CS p.21) works: `TD APC` row 1 (`U543` only) → `VC04Z` + diagnosis-driven
`FD10L`, `DominantProcedure` blank. They remain visible to `AllDataItemInList` (§4.1).

### 6.3 Field/diagnosis-driven unbundled HRGs (`UNPCC`, `USPC1`, `USPC2`, `USPC3`)

Evaluated once per episode after the code-driven ones:

| Type | Key | Row | Meaning (CS p.141-144 SD; p.166-167 XA; p.173 XB) |
|---|---|---|---|
| `UNPCC` | `TRETSPEF = 242` | `XB08[XB_paedtrans]` | paediatric critical-care transport: ADMIMETH in {28, 81, 2B} and ADMISORC in {51, 87} (`TD APC` rows 137, 455) *[verified]* |
| `UNPCC` | `TRETSPEF = 422` | `XA06[XA_neotrans]` | neonatal transport: + `NEOCARE` in {2, 3} |
| `USPC1` | `TRETSPEF = 315` | `SD01[SD_SPC_Diag_3] UZ99[SD_SPC_HRC_Diag1] SD01[SD_SPC_Diag_4] UZ99[SD_SPC_HRC_Diag2] SD02[SD_SPC_Diag_5] UZ99[SD_SPC_HRC_Diag3]` | inpatient SPC: MAINSPEF 315 + TFC 315 + secondary `Z515` → `SD01` (per diem, `*SPCDAYS`); + `DISMETH 4` → `SD01`; `DISMETH ≠ 4` + `EpiDur[4] = 0` → `SD02` (same day); a primary diagnosis of holiday relief care (`UZ_SD_HRC` = `Z755`) makes the matching `UZ99` pair win → **no** SPC HRG (`UZ99` is an indicator, not an error, CS p.147). Not exercised by TD (rows 459-466 have an invalid primary) *[open Q5]* |
| `USPC2` | `TRETSPEF = 315` (NAC only) | `SD04[SD_MSC_SPC] SD05[SD_MSC_AHP]` | outpatient SPC attendance by MAINSPEF 315 / 950,960 |
| `USPC3` | always (`Code N/A`) | `SD03[SD_SPC_Diag_1] UZ99[SD_SPC_Diag_2]` | hospital SPC support: secondary `Z515` and MAINSPEF ≠ 315 → `SD03` (`TD APC` rows 52-66, 340 … `SD03A*1`) *[verified]*; MAINSPEF 315 without TFC 315 → `UZ99` → nothing |

Critical-care HRGs `XA01`–`XA05`, `XB01`–`XB09`, `XC01`–`XC07` are **not** produced from APC
input; they come from the separate NCC/PCC/ACC datasets (UM p.92; §10).

### 6.4 Output form, `*n` multiplier and ordering

* `UnbundledHRGs` is a variable number of trailing fields in `_FCE.csv`/`_spell.csv` and one row
  per HRG in `_ub_rel.csv` (`RowNo, Iteration, UnbundledHRGs`; `Iteration` consecutive from 1,
  UM p.77).
* Rehabilitation-delivery (`Urehab`, `VC04`…`VC42`) and SPC (`SD01`–`SD05`) HRGs carry a star
  multiplier `*n` = the number of days in `REHABILITATIONDAYS` / `SPCDAYS` respectively; when the
  field is 0 the output is `*1` (`TD`: all `VC..Z*1`, `SD03A*1` with 0 days); `SD02` and `SD03`
  are always `*1` (CS p.142-143). Assessment HRGs `VC01`–`VC03` and all other unbundled HRGs
  carry no multiplier (`TD` row 59: `VC24Z*1,RD40Z,VC03Z`). Whether `*0` or `*n` with n>1 is
  emitted exactly as described is *[open Q10]* (no TD row has days > 0).
* Ordering *[inferred from TD]*: HRGs in `OPER` position order; the `UNPCC` HRG (`XB08Z`) is
  emitted **after the HRGs of `OPER_01`** (rows 137, 455: `RD51C,XB08Z,RD51C,…` and
  `XB08Z,RD20C,…`); `USPC3` (`SD03A*1`) comes last (rows 340, 438). The manual says the order is
  not significant for NAC (UM p.81). The prototype's only mismatches (2/750) are this ordering.
* Errors do not cascade downwards: an episode that is `UZ01Z` keeps its valid unbundled HRGs
  (UM p.92; `TD` row 79: `SB16Z,UZ01Z`).

---

## 7. Spell grouping *[verified on all 477 spells]*

### 7.1 Dominant episode (`SpellReportFlag`)

```
dominant_episode(spell):                   # episodes in EPIORDER order
  if any episode has a (non-NA) DominantProcedure:
      the episode whose DominantProcedure has the highest PH; ties -> earliest episode
  else:
      the episode whose primary diagnosis has the highest DH; ties -> earliest episode
```

The dominant-procedure criterion applies even when that episode was diagnosis-driven
(`TD` spell 4020000079: episode 1 `HE21D` D with `A559` PH 14 beats episode 2 whose primary has
DH 16 > 14). Pure-diagnosis example: spell 4020000140 (`J069` DH 7 vs `O700` DH 12 → episode 2).
`SpellReportFlag = 1` on that episode, `0` elsewhere (UM p.72). Whether a PH-1/unconsumed-PH-2
"dominant" also wins over a diagnosis-only episode with higher DH is untested *[open Q11]*.

### 7.2 Spell pseudo-record and grouping

```
group_spell(spell, episode_results):
  d  <- dominant episode
  pseudo <- copy of episode d with:
      DISDEST, DISMETH  <- from the LAST episode (UM p.59: "the Grouper uses the code from the last episode")
      EPIDUR            <- SpellLOS = sum over episodes of CalcEpidur   (UM p.73)
      CRITICALCAREDAYS = REHABILITATIONDAYS = SPCDAYS <- 0             # already deducted
      DIAG_*            <- diags(d) followed by the diagnoses of the other episodes (episode
                           order), duplicates removed                 # union
      OPER_*            <- procs(d) followed by the procedures of the other episodes (episode order)
  (root, GMF, HRG) <- group_episode(pseudo)          # §3, including combination formation
  if any spell validation error (§1.5b) or any episode HRG == UZ01Z:   HRG <- UZ01Z, GMF <- U
  SpellHRG, SpellGroupingMethodFlag <- HRG, GMF
  SpellDominantProcedure <- dominant of pseudo (== DominantProcedure of d; ties by position)
  SpellPDiag <- diags(d)[1];  SpellSDiag <- diags(d)[2] (blank if none)   # "first secondary diagnosis in the spell"
  SpellEpisodeCount <- n;  SpellLOS as above;  SpellCCDays <- sum CRITICALCAREDAYS
  SpellPBC <- PBC mapping of SpellPDiag on pseudo (§8.1)
```

The union of diagnoses **and** procedures across episodes is required: spell 4020000094 (two
`HE11D` episodes, `M479` and `M473`) → `HE11B` via `HE_Interv_2` (`SumListValues Interventions ≥ 2`
over both episodes' procedures); spell 4020000059 (`GC17J, GC17J, GB06F, GC17J`) → `GB06F` with CC
score 7 from the union of secondaries; 6 spells fail with the dominant episode's codes alone.
Age, `MAINSPEF`, `TRETSPEF`, `ADMISORC`, `ADMIMETH`, `SEX` are taken from the dominant episode
(they are consistent within valid spells; age differs by ≤1 — *[open Q12]*). `SpellPDiag` for a
`U` spell is still the dominant episode's primary (`TD` spell 1005926441: `N179`). Spell-level
unbundled HRGs are simply the concatenation of the episodes' (`_spell.csv` repeats them).

### 7.3 Error cascade

"If any episode within a spell generates a UZ01Z, the spell HRG will be UZ01Z" (UM p.92) —
including episodes made `UZ01Z` by an unbundled `UZ01Z`. Spell validation errors (§1.5b) make the
spell `U` without touching the episodes (`TD` spells 4020000010, 4020000140, 4020000185, 4020000246).

### 7.4 `_spell.csv` / `_spell_rel.csv` fields

`RowNo` (of the first episode), `PROCODET`, `PROVSPNO`, `SpellHRG`, `SpellGroupingMethodFlag`,
`SpellDominantProcedure`, `SpellPDiag`, `SpellSDiag`, `SpellEpisodeCount`, `SpellLOS`,
`ReportingSpellLOS` (blank), `SpellTrimpoint` (blank), `SpellExcessBeddays` (blank),
`SpellCCDays`, `SpellPBC`, `SpellSSC_Ct` (0), `SpellSSCs1-7` (blank), `SpellBP_Ct` (0),
`SpellBP1-7` (blank; payment groupers only), `SpellFlag_Ct` (0), `SpellFlag1-7` (blank),
`UnbundledHRGs` (UM p.74-75). `_FCE.csv` repeats the spell fields on every episode (UM p.72).

### 7.5 Multiple trauma spells

CS p.148: a multi-episode spell is multiple trauma only if the **first** episode's HRG is multiple
trauma; "the multiple trauma HRG of the first episode, that of any later episode(s) and that of
the spell may be different because of the additive nature of the logic". With the pseudo-record of
§7.2 the Core 4 entry test uses the dominant episode's primary diagnosis, which may differ from the
first episode's — no multi-episode trauma spell exists in TD *[open Q3]*.

---

## 8. Other outputs

### 8.1 Programme Budgeting Category (`FCE_PBC`, `SpellPBC`) *[verified 750/750]*

`C2G:PBC Mappings` has one row per ICD code: `PBC 1 [a]` and optionally `PBC 2 [q_pbcv]`
(`q_pbcv` = `DataItemInList Diagnosis 2..100000 PBC_Violence`, 241 assault/violence codes).
`FCE_PBC = eval_pairs(ctx, row of DIAG_01)` (last-wins, same engine); blank or unrecognised
primary diagnosis → `PBC02U1` ("Primary Diagnosis Not Recognised"). The PBC is computed even for
`UZ01Z` episodes (`TD` row 79 `PBC0202C`). `SpellPBC` = the same mapping for `SpellPDiag`
(`TD`: 463/463 valid spells equal the base PBC of `SpellPDiag`; evaluation of `q_pbcv` on the
spell's union of secondaries is the natural reading, untested).

### 8.2 Lengths of stay

* `CalcEpidur = max(0, EPIDUR − CRITICALCAREDAYS − REHABILITATIONDAYS − SPCDAYS)` (UM p.72;
  blank day fields count as 0) *[verified]*. It is the value every `EpiDur` flag reads (§3.3).
* `SpellLOS = Σ CalcEpidur` (UM p.73); `SpellCCDays = Σ CRITICALCAREDAYS` (UM p.73) *[verified]*.
* `ReportingEPIDUR`, `FCETrimpoint`, `FCEExcessBeddays`, `ReportingSpellLOS`, `SpellTrimpoint`,
  `SpellExcessBeddays`: **not populated** by the National Costs Grouper (UM p.72-74). The
  National Costs grouper computes no trimpoints or excess bed days.
* `FCESSC_Ct`/`SpellSSC_Ct` = `0`, `FCESSCs1-7`/`SpellSSCs1-7`, `SpellBP*`, `SpellFlag*` blank;
  `_flag_rel.csv` is produced but empty (payment groupers only, UM p.72-77).

### 8.3 Output files (UM p.72-78)

`[name].csv` (list of files), `_sort.csv` (sorted input + `RowNo`), `_FCE.csv` (input + episode
and spell fields + `UnbundledHRGs`), `_FCE_rel.csv` (`RowNo, FCE_HRG, GroupingMethodFlag,
DominantProcedure, FCE_PBC, CalcEpidur, ReportingEPIDUR, FCETrimpoint, FCEExcessBeddays,
SpellReportFlag`), `_spell.csv`, `_spell_rel.csv`, `_quality.csv` (input + `RowNo` + one
`Code Type|Code|Message` field per error), `_quality_rel.csv` (`RowNo, Iteration, Code Type,
Code, Error Message`), `_flag_rel.csv`, `_ub_rel.csv`, `_summary.csv` (`Grouper Version`
`NC2425_1.0.0`, `Database Version` `NC2425_20241209`, FCE/Spell counts and error counts, run
times, file names). `FCE Error Count` counts episodes with at least one quality row (75 in TD),
`Spell Error Count` spells with `SpellHRG = UZ01Z` (33).

---

## 9. Worked examples (traced by hand through the tables)

Notation: `pairs` are listed as in the sheet; `←` marks the pair chosen by last-wins.

**E1 — `TD APC` row 1, diagnosis-driven with unbundled rehabilitation (GMF `D`).**
Age 68, EPIDUR 13, days 0/0/0 → `CalcEpidur 13`. `DIAG R13X Z501 I209 E119 Z951 Z922 Z880 Z867 Z602`;
`OPER U543` (PH 2). Unbundling: `Urehab U543 → VC04[a]` → consumed; `Group To Split VC04 → VC04Z[a]`;
`REHABILITATIONDAYS = 0` → `VC04Z*1`. No candidates → no dominant. Core7: no 2nd/3rd-degree burn.
Core4: `R13X` has no Core4 row. Core5: nothing satisfied. Core1 ICD `R13X`: `FD10[a] PF26[p]`;
`p` = age in `Age_0to18` false → `FD10` ← , GMF `D`. Split `FD10` (21 pairs): CC score =
`SumDistinctValues FDFEFFYF_CC` over positions 2.. = `I209:1 + Z867:1 + Z602:1 = 3`; no
intervention (`U543` ∉ `Interventions`); `F_PdiagCC` primary flags false; scanning from the end,
the first true pair is `[2] FD10L[FD_CC_3]` (3 ≥ 3) → **`FD10L`**, `FCE_PBC PBC0213A`.

**E2 — row 76, procedure-driven with CC split and "additional procedure" exclusion (GMF `P`).**
Age 82, EPIDUR 12, CRITICALCAREDAYS 3 → `CalcEpidur 9`. `DIAG M179 R55X I482 I269 I10X`;
`OPER W401 Z943`. No combination for `W401`. Dominant `W401` (PH 27; `Z943` is a qualifier).
Core1 OPCS `W401`: `HN22[a] HT22[H_Trauma] HN81[H_VMaj] HT81[H_T_VMaj] HN81[H_2_Maj]
HT81[H_T_2_Maj] HN81[H_Malignancy] HT81[H_T_Malignancy]`. `H_VMaj` = `DataItemInList Procedure
H_VMaj`: the view excludes the dominant's own position, leaving `{Z943}` → false (`W401` itself is
on `H_VMaj`; without the exclusion the result would be `HN81D` ≠ expected). `H_Trauma`
(`HT_Trauma` primary) false, malignancy false, `H_2_Maj` sum 0 → `HN22` ←, GMF `P`. Split `HN22`:
CC `HEHNHT_CC` over positions 2.. = `I482:1 + I269:1 + I10X:1 = 3` → `HN22D[HN_CC_2]` (3 ≥ 2, 4 not
reached) → **`HN22D`**.

**E3 — row 349, subsidiary-run semantics (GMF `P`).** `OPER Q074 Q231 Y752 Z943`, `DIAG N803 N805
N832 N736`, CalcEpidur 1. Dominant `Q074` (PH 23, ties with `Q231` PH 23 → first position). Row
`Q074`: `MA07[a] MA02[MA_Major] MA02[MA_Endometriosis] MA08[MA_Lap] MA28[MA_Major_Lap]
MA28[MA_Endometr_Lap] MA28[MA_Robot] MA06[MA_Malignancy] MA26[MA_Major_Cancer] MA26[MA_Robot_Cancer]
FF50[FF_Maj_Abd_Canc]`. `MA_Lap` = `RelDataItemInList Lap` on the qualifier run after `Q074` — the
run is empty (`Q231` follows immediately), so `Y752` (which follows `Q231`) does not count → all
`*_Lap`/`Robot` pairs false; `MA_Endometriosis` (`N805` in any position) true → `MA02` ←. Split:
`MAMB_CC` secondaries = `N736:1` → `MA02C[a]` → **`MA02C`**. (Treating `Y752` as "anywhere after
the dominant" gives `MA28Z`.)

**E4 — row 625, combination not formed (GMF `P`).** `OPER A522 V544 V553 Y535 Z675 Z676`, `DIAG
M511 …`, CalcEpidur 0. `A522` has combination `A522+IMAGE` (`Subsidiary CL_Image`, order 1): the
run after `A522` is empty (`V544` is a real code) → not formed. Dominant `V544` (PH 15 > `A522`
PH 13). Row `V544`: `AB16[AB_TFC_LoS_0] AB16[AB_PainD_LoS_0]`; `AB_PainD_LoS_0` = primary in
`AB_Paindiag` (`M511` ✓) and `EpiDur[1]=0` ✓ → `AB16` → **`AB16Z`**, `DominantProcedure V544`.

**E5 — row 132, LoS "flip" to diagnosis-driven with intervention (GMF `D`).** EPIDUR 7,
CRITICALCAREDAYS 5 → `CalcEpidur 2`. `OPER E852 L714 Y539 Z943 U201`; `DIAG J81X K703 R18X N179
R600 D649 E119 R798 K860 F171 Z864`. Unbundling: `URad U201 → RD51[a]` → split `RD51A[a]
RD51B[p] RD51C[Age_0to5]` → `RD51A`; consumed. Dominant `E852` (PH 9; `L714` PH 1 lower). Row
`E852`: `DZ37[LoS_0]` — `EpiDur[1]=2` ∉ `LoS_0` → no root (with raw `EPIDUR 7` likewise; with an
unadjusted LoS of 0 the HRG would wrongly be `DZ37A`). Core1 ICD `J81X`: `DZ20[a] PD14[p]` →
`DZ20`, GMF `D`. Split `DZ20`: `DZ20F[a] DZ20E[DZ_CC_6] DZ20D[DZ_Interv]`; `DZ_Interv` =
`DataItemInList Interventions` — the episode is not procedure-driven, so `E852` is **not** excluded
and it is on `Interventions` → **`DZ20D`** (CC 6 not needed). `UnbundledHRGs RD51A`.

**E6 — row 3, multiple trauma (GMF `M`).** `DIAG S4240 S799 Z501 I951 E871 I10X F03X M1399 Z602
Z739 Z751`, `OPER U508` (PH 2 → `Urehab` `VC24Z*1`, consumed; no dominant). Core7: no burn.
Core4 ICD `S4240`: `VA10[VA_cmpt_Upper]` — `Comp_VA_Upper` contains `S799` (lower limb, i.e. a
different site) → `VA10`, GMF `M`; no dominant procedure → no procedure band. Split `VA10`:
`SumDistinctValues MT_ICD_Value` over all positions = `S4240:5 S799:5 I951:4 E871:5 I10X:4 F03X:5
M1399:3 Z739:4 = 35` → `VA10C[VA_d33_50]` → **`VA10C`**.

**E7 — row 6, burns (GMF `B`).** Age 84, CalcEpidur 40, DISDEST 65, DISMETH 1. `DIAG T242 T212
T310 X100 J440 Z751 I959 F03X G819 I694 K579 M199 I679`; `OPER S359 Z504 Z942 Y588 Z504 Z942 S551
Z504 Z942`. Dominant `S359` (PH 15, first of two). Core7 row: `JB_2nd3rd_Degree` ∋ `T242, T212`;
TBSA `T310` (<10%); proxy TBSA `SumDistinctValues JB_TBSA_10_Value` = `T242:20 + T212:30 = 50`
≥ 50 → `JB93[JB_23D_TBSA_5to9]` (bands 10–19% false; `JB61` died/transfer within 2 days false)
→ root `JB93`, GMF `B`. Core3 row `JB93`: CC `JB_CC` secondaries = `J440:2 F03X:2 G819:2 = 6`;
age 84 → scanning from the end, `JB96[JB_Age60_CC_6]` (age ≥ 60 and CC ≥ 6) is the first true pair
→ `JB96`. Split `JB96`: `JB42C[a] JB42B[JB_Interv_1] JB42A[JB_Interv_2] JB51B[Age_0to15]
JB51A[JB_Age0to15_Int1]`; `JB_Interventions` ∋ `S359` (value 1; `S551` not on the list) →
`JB_Interv_1` true, `JB_Interv_2` (sum ≥ 2) false → **`JB42B`**. (`S359`'s own row `JC42[LoS_0to1]`
would have failed anyway.)

**E8 — row 545, global exception (GMF `G`).** No procedures, `DIAG C509 Z530 L905 E119 Z901`,
CalcEpidur 0. Core5 row scanned from the end: `RD98`, `SC97`, `SB97`, `RN97`, `RD97` false (no
imaging/chemo/radiotherapy codes, TFC 800); `WH50[WH_PNCO_A]` (`Z530` as secondary) true →
`WH50`, GMF `G` → split `WH50A[a]` → **`WH50A`**. Row 495 similarly: `X701 X723` both unbundled
(`SB01Z`, `SB12Z`, consumed), no dominant; `SB97[SB_Z511_LoS_0]` (secondary `Z511`, LoS 0) and
`SB97[SB_Chemo_LoS_0]` (`AllDataItemInList SB_Unb_Chemo` sees the consumed `X701`) → **`SB97Z`**.

**E9 — row 79, error via unbundled code (GMF `U`).** `OPER X708 X728`: `UChem1 X708 → SB16Z`;
`UChem2 X728 → UZ06[a]` → unbundled `UZ01Z` + message `OPER_02|X728|UZ06 - Poorly coded procedure
for Casemix grouping purposes`; episode `UZ01Z`/`U`, `DominantProcedure` blank, `UnbundledHRGs
SB16Z,UZ01Z`, `FCE_PBC PBC0202C` (from `C20X`).

**E10 — spell 4020000059 (rows 532-535).** Episodes: `GC17J` (D, no procedure), `GC17J` (D,
`U162` consumed), `GB06F` (P, `J381` PH 21), `GC17J` (D). Dominant episode = 3 (highest PH).
Pseudo-record: diagnoses `K804 K801 K838 R945` + `K802` (union), procedures `J381 Y534 U162 Y981`,
EPIDUR = `SpellLOS` = 2+7+0+1 = 10, DISDEST/DISMETH from episode 4. Dominant `J381` → root `GB06`
(P); split: CC `GAGBGCYG_CC` over secondaries `K801:2 K838:1 R945:1 K802:1 = 5` → `GB06F[GB_CC_4]`
→ **`SpellHRG GB06F`**, `SpellPDiag K804`, `SpellSDiag K801`, `SpellReportFlag` on row 534.

**E11 — spell 4020000094 (rows 574-575).** Two `HE11D` episodes (D; `M479` PH 11 and `M473` PH 11,
both LoS-flipped). Dominant episode 1 (tie → earliest). Pseudo procedures `M479 M473`; split
`HE11`: `HE11B[HE_Interv_2]` = `SumListValues Interventions ≥ 2` → 1+1 = 2 → **`HE11B`**
(the union across episodes is what raises it above the episodes' `HE11D`).

---

## 10. Other datasets (brief)

### 10.1 Non-Admitted Consultations (NAC) *[verified 200/200]*

Input (UM p.62, `RDF`): `STARTAGE, SEX, MAINSPEF, TRETSPEF, FIRSTATT (1-4), OPER_01..nn`; no
diagnoses, one row per attendance. Validation as APC for those fields (`FIRSTATT` blank/invalid,
`STARTAGE 132` invalid). Grouping = the episode algorithm with an empty diagnosis vector and
`EpiDur = 0`:

1. combination codes, unbundling (`USPC2` instead of `USPC1/3`; no `UNPCC`), dominant procedure
   exactly as §3.4–§6 (a lone qualifier code → `UZ05`, `TD NAC` row 29);
2. dominant's `Core1` row → `P` (X62.x assessment codes, PH 3/4, have `Core1` rows `WF01/WF02 …`,
   CS p.161);
3. if that fails, **the next procedure (by PH) that has a `Core1` row is tried** (`TD NAC` row 164:
   `X306` PH 5 row fails on TFC → `X623` PH 4 → `WF02B`, GMF `P`, `DominantProcedure` still `X306`)
   *[inferred; APC never exercises this — open Q4]*;
4. Core5 → `G` (`SC97Z`, `SB97Z`, `RD97Z` with LoS 0);
5. Core6 row for `MAINSPEF` (`WF01[a] WF02[WF_Multi]`, `WF_Multi` = `X622/X623` in any position)
   → GMF `O`; split `WF01/WF02` by `FIRSTATT` (`WF01A[a] WF01B[WF_FirstF2F] WF01C[WF_FUNonF2F]
   WF01D[WF_FirstNonF2F]`, CS p.161).

Outputs `_attend.csv` (`NAC_HRG, GroupingMethodFlag (P/G/O/U), DominantProcedure, AttendanceHRG
(blank), …, UnbundledHRGs`), `_attend_rel`, `_quality`, `_quality_rel`, `_ub_rel`, `_summary`
(UM p.79-81).

### 10.2 Emergency Medicine (EM) *[verified 300/300]*

Input (UM p.63): `AGE` (validated 0–130, not used), `AEPATIENTGROUP` (10…80, optional),
`INV_01..nn` (2-char codes, leading zeros significant: `1` is invalid), `TREAT_01..nn` (2–3 chars).
Algorithm (CS p.151-156): dominant investigation = the investigation code with the highest
hierarchy value in the CS p.152 table (ties → first position); dominant treatment likewise with
the CS p.152-153 table; then look up `C2G:Code To Group` type `EM`, `Code = "I <inv>+T <treat>"`
(`"Blank INV+T …"` when no investigation, `"I …+Blank TRE"` when no treatment) → `VBnn` → `VBnnZ`.
The grid already encodes the category exceptions (e.g. `I 24+T 12 → VB11`, `I 10+T 031 → VB02`).
`AEPATIENTGROUP = 70` with any code → `VB99Z`; no investigation and no treatment → errors
`Investigation is blank` + `Treatment is blank` → `UZ01Z`. The hierarchy tables exist **only in the
PDF** (not in the workbook) and must be transcribed; the values used by the prototype (= CS
p.152-153) are:

* Investigations (code:hierarchy): `01:6 02:3 03:6 04:6 05:5 06:3 07:6 08:6 10:7 11:7 12:7 13:7
  14:6 15:6 16:6 17:4 18:6 19:6 20:6 21:3 22:2 23:6 24:1 99:3`.
* Treatments: `011:4 012:5 02:3 031:6 032:6 033:3 041:4 042:4 043:4 051:4 052:3 06:4 08:5 091:4
  092:4 101:7 102:7 103:7 11:5 12:2 13:5 14:4 15:7 16:7 17:6 181:7 182:7 19:8 20:5 21:3 221:2 222:2
  231:7 232:4 233:4 234:4 235:6 236:4 241:2 242:4 243:4 244:4 245:4 246:4 25:5 27:3 281:7 282:8
  291:7 292:7 30:3 31:3 32:3 33:3 34:3 35:3 36:3 37:4 38:4 39:4 40:5 41:5 42:5 43:4 44:7 45:7 46:7
  47:5 48:7 49:5 50:3 511:4 512:6 513:5 514:4 515:6 516:4 517:3 518:3 519:3 521:5 522:3 53:3 54:5
  551:3 552:8 553:5 554:5 555:7 56:2 57:3 99:1`.

Only the hierarchy values are needed; the complexity categories and the "1 or 0 / 3 or 4"
exceptions on CS p.152-155 are already resolved inside the 2,325 grid rows.

### 10.3 Adult Critical Care (ACC) *[verified 250/250]*

Input (UM p.65-66): `CCUF` (valid: 1-3,5-9 or 01-03,05-12,90,91), day counts `BCSD, ACSD, BRSD,
ARSD, RSD, NSD, DSD, LSD, CCL2D, CCL3D`, `CC_Start_Date`, `CC_Discharge_Date` (YYYYMMDD). One HRG per
critical-care period (CS p.187). The flowchart is an image in CS p.188; the rule reconstructed from
the test data and CS p.187 ("where basic respiratory and basic cardiovascular support occur on 1
day, it is counted as 1 organ") is:

```
organs = [ARSD>0] + [BRSD>0] + [ACSD>0] + [BCSD>0 and BRSD==0 and ACSD==0]
         + [RSD>0] + [NSD>0] + [DSD>0] + [LSD>0]
HRG    = XC07Z,XC06Z,XC05Z,XC04Z,XC03Z,XC02Z,XC01Z for organs 0,1,2,3,4,5,>=6
organs == 0 and CCL2D + CCL3D == 0  -> UZ13 - ACC grouping error -> UZ01Z
```

*[inferred]* — basic cardiovascular support is counted only when neither basic respiratory nor
advanced cardiovascular support is present (CS p.189-190 cases A–F agree). Outputs: `ACC_HRG`,
`Calc_CC_Days = discharge − start + 1` (−1 if invalid), `CC_Warning_Flag` `F` when dates invalid or
`CCL2D+CCL3D > Calc_CC_Days` or `ARSD+BRSD > Calc_CC_Days` or `ARSD+BRSD > CCL2D+CCL3D` (UM p.86).

### 10.4 Paediatric Critical Care (PCC) *[verified 250/250]*

Input (UM p.67-68): `PROCODET, CCLocalID, CCDate, DISDATE, DISMETH, CCUF (04/4,16,17,18,19,92),
CCAC_01..20, OPER_01..20, DIAG_01..nn`; sorted by provider, local id, date; one HRG per day. The
algorithm is the 29-step flowchart on CS p.175-180 (hard-coded; not in the workbook): ordered
tests on the day's CCAC set, burns/isolation diagnoses and high-cost-drug codes `X841/X842`,
with the isolation sub-test (`CCAC 74` + a diagnosis on list `XB_Isolation`, printed on CS
p.181-185 — **not** in the workbook) deciding between adjacent levels; steps 25–27 need history
within the critical-care period (count of previous days with `CCAC 13` < 8; consecutive days at
`XB06Z` with `CCAC 52`/`53` < 91). Reading of the garbled step 14: `CCAC 51` alone → `XB05Z`
(`XB04Z` if isolated) *[verified]*. `XB08Z` transport comes from APC (§6.3).

### 10.5 Neonatal Critical Care (NCC) *[verified 300/300]*

Input (UM p.69-70): `PROCODET, CCLocalID, CCDate, DISDATE, CCUF (13,14,15), AGE_DAYS, DISMETH,
GestLen (10-49), PERWT (0.001-9.999 kg), CCAC_01..20`. Flowchart CS p.168-170 (15 ordered
steps): CCUF not 13/14/15 → `UZ01Z`; `CCDate = DISDATE` and `DISMETH 4` → `XA01Z`; `07` with
`02/53/80` → `XA01Z`; `03` on CCUF 13 → `XA01Z`; intensive-care CCACs → `XA01Z`; high-dependency
CCACs → `XA02Z`; special-care criteria (age ≤2 d & weight ≤2 kg; age ≤2 d & gestation 35; age ≤7 d
& gestation 34; gestation <34; `10`+`28`; `09/23/24/29/89/93`) → `XA04Z` if `CCAC 21` (carer
resident) else `XA03Z`; `26` phototherapy → `XA05Z` *[reading verified by TD rows 61, 245]*;
CCUF 13 with `10/15/21/22/25/27/28/99` → `XA05Z`; CCUF 14/15 with those (or `03`) → `UZ11`
error → `UZ01Z`. `XA06Z` transport comes from APC (§6.3).

### 10.6 National Renal Dataset (NRD) *[verified 200/200]*

Input (UM p.64): `RENALMOD` (01-15, leading zero), `RENALSITE` (01-04), `RENALACCESS` (01-07 or
blank), `HBV`, `HCV`, `HIV` (`POS/NEG/UNK`/blank, case-insensitive), `AGE` (0-130). Row
`C2G:Code To Group` type `Renal`, `Code = RENALMOD`, e.g. `05`: `UZ14[a] LD09[LD_Home]
LD10[LD_Home_AVF] LD05[LD_Sat] LD06[LD_Sat_AVF] LD07[LD_Sat_BBV] LD08[LD_Sat_AVF_BBV] LD01[LD_Hosp]
LD02[LD_Hosp_AVF] LD03[LD_Hosp_BBV] LD04[LD_Hosp_AVF_BBV]` evaluated with the generic engine
(`RenalSite`, `RenalAccess`, `RenalBBV[1..3]` data items; `LD_AVF` = access 03/04/05, `LD_BBV` =
`POS`); `01/02 → LD11`, `03/04 → LD12[a] LD13[LD_Assisted]`, `09`–`15` → `UZ14` (`UZ14 - Renal
(NRD) Error` → `UZ01Z`). Split by `p` (`LDnnA` adult / `LDnnB` child). Matches the flowchart CS
p.89-96.

---

## 11. Open questions (with disambiguating experiments)

Each item names concrete input for the Windows grouper in the VM.

1. **Burns vs multiple trauma precedence (B vs M).** Both are documented as overriding Core 1 but
   not each other. Test: primary `S0660` (head trauma) + secondary `S4240` (upper limb) + `T212`
   (2nd-degree burn of trunk) + `T310`; expected either `VA10x` (M) or `JB4x` (B). The spec
   assumes B first.
2. **Core 5 vs procedure-driven (G vs P).** Test: `DIAG C509, Z530`, `OPER B284` (biopsy, PH ≥ 5),
   EPIDUR 0 — `WH50A` (G) or the breast HRG (P)? Also `X701 X723` + a PH-10 procedure with LoS 0.
   The spec assumes P wins.
3. **Multiple-trauma spells.** A 2-episode spell where only episode 2 (or only episode 1) is
   multiple trauma, and one where both are: confirm "spell is M only if the first episode is M"
   and how the spell diagnosis/procedure scores are accumulated (§7.5).
4. **Fallback to the next procedure in APC.** `OPER X411 (PH 17, LoS_0to1 only) , H223 (PH ≥ 5)`
   with EPIDUR 5 and a renal primary diagnosis: does the APC grouper try `H223` (GMF `P`) as the
   NAC grouper does for `X306/X623`, or flip to D? And what `DominantProcedure` is reported?
5. **`EpiDur` positions 2–4 and SD01/SD02.** `MAINSPEF 315, TRETSPEF 315, DIAG_02 Z515, DISMETH 1`,
   (a) `EPIDUR 5, SPCDAYS 5` → expect `SD01A*5`; (b) `EPIDUR 3, SPCDAYS 0` → `SD02A*1` only if position
   4 = `SPCDAYS`; (c) `EPIDUR 0, SPCDAYS 0`; (d) with `DISMETH 4`. Also primary `Z755` to confirm the
   `UZ99` suppression.
6. **`AllDataItemInList` and the row's own code.** `OPER A114` alone (cortical mapping, on
   `AA_Adv_Monitor`): does its own row's `AA51[AA_Adv_Monitor]` fire (→ `AA51`) or not (→ `AA53`)?
7. **`SumListValues` with duplicate codes.** `OPER W401, W401` (knee replacement twice; `H_Maj`
   value 1 each) → `HN81` (`H_2_Maj`, sum 2) if occurrences add, `HN22` if distinct.
8. **Qualifier run interrupted by an ignored/unbundled code.** `OPER A522, X598 (PH 1), Y535` and
   `OPER A522, U201 (PH 2), Y535`: is `A522+IMAGE` formed?
9. **High-cost drug duplicates.** `OPER X904, X904` → one `XD26Z` (CS p.192) or two?
10. **Star multiplier values.** `REHABILITATIONDAYS 3` with `U543` → `VC04Z*3`? `U543` twice → two
    `VC04Z*3`? Confirm `SD03A` ignores `SPCDAYS`.
11. **Dominant episode with a PH-1/PH-2 "dominant".** Spell: episode 1 `DIAG I639` (DH 17), no
    procedure; episode 2 `DIAG R13X` (DH 11), `OPER X598` (PH 1): which episode gets
    `SpellReportFlag`?
12. **Spell pseudo-record fields.** A valid spell whose episodes differ in `TRETSPEF`/`MAINSPEF`
    (SPC flags) or age (0 vs 1 — `PB` age flags): which episode's values drive the spell split?
13. **Dagger/asterisk and lowercase codes.** `DIAG_01 a000`, `DIAG_02 A000D`: are they normalised
    or rejected?
14. **Blank cells before populated cells.** `OPER_01` blank, `OPER_02 W401, OPER_03 Z943`: do
    positions shift (expected) and is `Z943` still subsidiary to `W401`?
15. **Sort order of `PROVSPNO`.** Spell numbers `9` and `10` in reverse input order: `_sort.csv`
    tells text vs numeric ordering.
16. **Unobserved validation messages.** Values for `NEOCARE 7`, `CRITICALCAREDAYS -1`/`abc`,
    `EPIORDER 98`, duplicate `EPIORDER`, `CLASSPAT` blank, `ADMIMETH` blank, `DISDEST 00`,
    `EPIDUR abc`, `OPER_01 ZZZZ` to capture the exact texts (and whether a day-count error makes
    the episode `UZ01Z`).
17. **Age consistency rule.** Ages 40, 41, 42 across three episodes (each step +1 but total +2):
    error or not? And 40, 40, 42.
18. **Unbundled output order.** Confirm that `XB08Z`/`XA06Z` are emitted after `OPER_01`'s HRGs
    and `SD03*` last (cosmetic; needed only for byte-identical `_ub_rel.csv`).
19. **XB isolation list and ACC formula.** The `XB_Isolation` list is printed only in CS p.181-185
    (including two-code entries such as `A40.0 with M72.6`); confirm how the two-code entries are
    matched. For ACC, a record with `BRSD 0, BCSD 1, ACSD 0, ARSD 1` (expected 2 organs) and
    `BCSD 1, NSD 1` (expected 2) would further corroborate the §10.3 formula.
20. **`STARTAGE 999`.** Confirm it is accepted (no error) and yields adult HRGs.
