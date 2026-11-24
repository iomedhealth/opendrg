# CMS MS-DRG Grouper v44.0 (FY2027) — Engine Specification for Re-implementation

This document is an implementation contract derived from the CMS Java grouper (`msdrg-core-44.0.0.3`,
`msdrg-model-v2-2.12.2`, `msdrg-binary-access-1.6.4`). It is written so that the grouper can be
re-implemented (in R) from the human-readable flat tables **without reading the Java again**.

Everything stated here was checked against the Java source. Where the flat files and the runtime
binary could differ, the binary was actually loaded (via `DataBlob`) and diffed against the flat
files; the results are recorded in §8.

## 0. Conventions and sources

Base directory (all paths below are relative to it):
`/Users/gabriel.maeztu/repos/open-grd/target/MS-DRG V44 FY2027 (CMS)/_extract/`

| Abbrev. | Path |
|---|---|
| `CORE/` | `msdrg/src/core/gov/agency/msdrg/v440/` |
| `MODEL/` | `msdrg/src/model/gov/agency/msdrg/model/v2/` |
| `ACCESS/` | `msdrg/src/access/gov/agency/msdrg/access/` |
| `MISC/` | `mainframe/msdrg/MS-DRG440.R0.MF.Java.GenRel.Software_package/CMSDRG440_MF_Java_Misc/` |
| `MFPDF` | `mainframe/msdrg/MS-DRG440.R0.MF.Java.GenRel.Software_package/pbl060_msdrg_MFinstall_ICD10_v440_java.pdf` |
| `APIPDF` | `msdrg/pbl161_msdrg_java_api.pdf` |
| `MFJAR` | `mainframe/msdrg/MS-DRG440.R0.MF.Java.GenRel.Software_package/CMSDRG440_MF_Java_jar/MSDRGMF440.jar` (COBOL/JNI wrapper; only bytecode) |

Citations are `file:line` (line numbers of the extracted sources). "Attribute", "operand" and "list
name" are synonyms (e.g. `d468`, `MCC`, `dxc0511`).

Terminology used throughout:

* **PDX** principal diagnosis, **SDX** secondary diagnosis, **PR** procedure.
* **Mask** = the multiset of `(prefix, name)` attribute entries built from the claim (§4.5).
* **Prefix** ∈ {`PDX`, `SDX`, `ANY`, `ONLY`, `PT`, `NONE`} (`CORE/enumeration/MsdrgAttributePrefix.java:6-12`).
* **Initial pass** = grouping before HAC demotion; **final pass** = grouping after HAC demotion.
* **GRC** = grouper return code (`MODEL/enumeration/MsdrgGrouperReturnCode.java:7-15`).

---

## 1. Input and output model

### 1.1 Input fields (`MODEL/transfer/input/MsdrgInput.java`)

| Field | Java type | Valid values / notes | Used by grouping logic? |
|---|---|---|---|
| `principalDiagnosisCode` | `MsdrgInputDxCode{value:String, poa:GfcPoa}` (Optional) | ICD-10-CM code **without decimal point**, upper-case recommended (binary lookups upper-case the code, `ACCESS/DataBlob.java:548,559`, but the exclusion membership test compares the raw string, `CORE/logic/preprocess/MsdrgExclusions.java:80`). Missing → `"null"` with POA `BLANK` (`CORE/MsdrgComponent.java:46-47,178-179`). | Yes |
| `secondaryDiagnosisCodes` | `List<MsdrgInputDxCode>` | Same encoding; order = claim order. `null` entries become `"null"`/`BLANK` (`MsdrgComponent.java:185-191`). Up to 25 in the mainframe layout; the Java has no limit. | Yes |
| `admissionDiagnosisCode` | `MsdrgInputDxCode` (Optional) | Only validity is reported (`MsdrgAdmitDxGrouperFlag`); never used in grouping (`CORE/logic/preprocess/PdxAttributeProcessor.java:51-55`, `CORE/logic/MsdrgGrouperFlagsResult.java:59-69`). | Flag only |
| `procedureCodes` | `List<MsdrgInputPrCode{value}>` | ICD-10-PCS, 7 chars, order = claim order; first one is the "principal procedure" (`MsdrgComponent.java:214-219`, flag `FIRST_POSITION`). | Yes |
| `sex` | `MsdrgSex` (Optional) | `MALE(1)`, `FEMALE(2)`, `UNKNOWN(-1)`; missing → `UNKNOWN` (`MsdrgComponent.java:200`). | Yes (gender-specific PDX only) |
| `dischargeStatus` | `MsdrgDischargeStatus` (Optional) | See table below; missing/unknown → `NONE(-1)` (`MsdrgComponent.java:199`). | Yes |
| `ageInYears`, `ageDaysAdmit`, `ageDaysDischarge` | `int` | **Not used anywhere in v44.0 logic** (only echoed in trace, `CORE/TraceUtility.java:73-75`). The `invalid_age` GRC node exists (`CORE/logic/ast/MsdrgNodeSupplier.java:72-73`) but no DRGLOGIC row references it and nothing ever puts `invalid_age` on the mask → GRC 3 is unreachable. | No |
| POA (`GfcPoa`, per diagnosis) | enum from `com.mmm.his.cer.foundation` (bytecode only, decoded from `MFJAR`) | `Y`('Y'), `N`('N'), `U`('U'), `W`('W'), `ONE`('1'), `E`('E'), `BLANK`(' '), `INVALID`('\0'). `GfcPoa.fromChar(c, default)` upper-cases `c`, returns the enum with that char, else `default`. The mainframe wrapper uses default `BLANK` for unrecognised characters. | SDX POA only (HAC logic). PDX POA unused. |

Runtime options (`MODEL/RuntimeOptions.java`, validated in `CORE/logic/RuntimeDataValidation.java:20-46`):

| Option | Values | Default | Effect |
|---|---|---|---|
| `poaReportingExempt` (hospital POA status) | `NON_EXEMPT`, `EXEMPT`, `UNKNOWN` | Field default `NON_EXEMPT` (`RuntimeOptions.java:13-14`); if the whole options object or the field is `null`, `RuntimeDataValidation` substitutes `UNKNOWN` (`:27,38`). The API PDF calls `UNKNOWN` the default. The mainframe wrapper sets `EXEMPT` when the POALOG column is `X`, otherwise `NON_EXEMPT`. | HAC processing branch (§6.4). **With `UNKNOWN` almost any claim with a met HAC becomes ungroupable** (§6.4). Use `NON_EXEMPT` to reproduce TESTDB. |
| `computeAffectDrg` | `COMPUTE`, `DO_NOT_COMPUTE` | `COMPUTE` | Whether the "affects DRG" marking links run (§4.8). |
| `markingLogicTieBreaker` | `CLINICAL_SIGNIFICANCE`, `CODE_ORDER` | `CLINICAL_SIGNIFICANCE` | Reorders procedure and SDX lists before grouping (§2.1). Affects tie-breaks **and** several order-dependent formula functions. |

Discharge status enum (`MODEL/enumeration/MsdrgDischargeStatus.java:14-50`): integer code → enum, with
formula strings for three of them.

| Code | Enum | Formula attribute added to mask |
|---|---|---|
| (missing/other) | `NONE(-1)` | `invalid_dstat` |
| 01 | `HOME_SELFCARE_ROUTINE` | — |
| 02 | `SHORT_TERM_HOSPITAL` | `XFRNBA` |
| 03 | `SNF` | — |
| 04 | `CUST_SUPP_CARE` | — |
| 05 | `CANC_CHILD_HOSP` | `XFRNBA` |
| 06 | `HOME_HEALTH_SERVICE` | — |
| 07 | `LEFT_AGAINST_MEDICAL_ADVICE` | `AMA` |
| 20 | `DIED` | `DIED` (and **no** `ALIVE`) |
| 21 | `COURT_LAW_ENFRC` | — |
| 30 | `STILL_A_PATIENT` | — |
| 43 | `FEDERAL_HOSPITAL` | — |
| 50, 51 | `HOSPICE_HOME`, `HOSPICE_MEDICAL_FACILITY` | — |
| 61..66 | `SWING_BED`, `REHAB_FACILITY_REHAB_UNIT`, `LONG_TERM_CARE_HOSPITAL`, `NURSING_FACILITY_MEDICAID_CERTIFIED`, `PSYCH_HOSP_UNIT`, `CRIT_ACC_HOSP` | 66 → `XFRNBA` |
| 69, 70 | `DESIGNATED_DISASTER_ALTERNATIVE_CARE_SITE`, `OTH_INSTITUTION` | — |
| 81..95 | "...with planned readmission" variants of 01–07,21,43,61–66,70 (81,82,83,84,85,86,87,88,89,90,91,92,93,94,95) | 82, 85, 94 → `XFRNBA` |

`ALIVE` is added for every status other than `DIED` — including `NONE` (`CORE/logic/MsdrgMaskBuilder.java:84-96`).
`XFRNBA_INT_SET = {2, 5, 66, 82, 85, 94}` (`MsdrgMaskBuilder.java:29-30`).

### 1.2 Output fields (`MODEL/transfer/output/MsdrgOutput.java`, `MODEL/MsdrgGrouperResult.java`)

Two `MsdrgGrouperResult` objects (initial and final), each with:

| Field | Type | Semantics |
|---|---|---|
| `returnCode` | `MsdrgGrouperReturnCode` | `OK(0)`, `DX_CANNOT_BE_PDX(1)`, `INVALID_SEX(4)`, `INVALID_DISCHARGE_STATUS(5)`, `INVALID_PDX(7)`, `HAC_MISSING_ONE_POA(9)`, `HAC_STATUS_INVALID_POA_N_OR_U(10)`, `HAC_STATUS_INVALID_POA_INVALID_OR_1(11)`, `HAC_STATUS_INVALID_MULT_HACS_POA_NOT_Y_W(15)`. Codes 2, 3, 6 of the mainframe doc never occur in v44 Java (DRG 998 returns `OK`). |
| `drg` | int | 3-digit MS-DRG; 999 = ungroupable (`CORE/logic/MsdrgUtility.java:23`); 998 = "PDX invalid as discharge diagnosis" (a normal DRGLOGIC row, MDC 14). |
| `baseDrg` | int | `BASEDRG` column of the matched row (999 for ungroupable). |
| `mdc` | int | See §7.6 for how it is derived (not simply the PDX MDC). 0 for ungroupable. |
| `medicalOrSurgical` | `MEDICAL(1)`, `SURGICAL(2)`, `NONE(0)` | From the `MEDSURG` column (`CORE/logic/MsdrgGrouperResultReport.java:39-49`). |
| `severity` | `MsdrgSeverity` `MCC(1)`, `CC(2)`, `NON_CC(3)`, `NONE(0)` | The claim severity computed for the matched row (§5); `NONE` for 999 and 998 (`MsdrgGrouperResultReport.java:53-56`). |
| descriptions | String | DRG, base-DRG and MDC descriptions (binary-only mixed-case text; flat files have upper-case variants, §8.11). |

`MsdrgGrouperFlags` (`MODEL/MsdrgGrouperFlags.java`, computed in `CORE/logic/MsdrgGrouperFlagsResult.java:30-54`):

| Field | Semantics |
|---|---|
| `admitDxGrouperFlag` | `DX_NOT_GIVEN` if admit dx missing/empty, `DX_VALID` if it is a known code, else `DX_INVALID`. |
| `initialDrgSecondaryDxCcMcc`, `finalDrgSecondaryDxCcMcc` | `MCC` if the matched formula's accumulated attributes contain `MCC`, `CC` if they contain `CC`, else `NON_CC` (`MsdrgGrouperFlagsResult.java:74-86`). I.e. "did the CC/MCC drive this DRG". |
| `numHacCategoriesSatisfied` | number of distinct HAC numbers with status `HAC_CRITERIA_MET` over all SDX `hacsFlags` (`:91-99`). |
| `hacStatusValue` | `NOT_APPLICABLE` if hospital `EXEMPT` or no HAC met; else `FINAL_DRG_NO_CHANGE` (initial DRG == final DRG), `FINAL_DRG_UNGROUPABLE` (final DRG == 999), `FINAL_DRG_CHANGES` (`:105-121`). |

Per-diagnosis output (`MODEL/MsdrgDiagnosisFlag.java`, built in `CORE/logic/MsdrgCodeFlagsProcessor.java:111-151`):

| Field | Semantics |
|---|---|
| `diagnosisRecognizedByGrouper` | code found in the diagnosis table (`CodeFlag.VALID`). |
| `diagnosisAffectsDrg` | `MsdrgGroupingImpact` `NONE(0)`, `INITIAL(1)`, `FINAL(2)`, `BOTH(3)` (§4.8). |
| `initialSeverityUsage`, `finalSeverityUsage` | `MsdrgCodeSeverityFlag`: `NEITHER(0,'N')`, `MCC(1,'M')`, `MCC_EXCLUDED_BY_DRG_LOGIC(2,'D')`, `CC_EXCLUDED_BY_DRG_LOGIC(3,'D')`, `CC(5,'C')`, `MCC_EXCLUDED(6,'E')`, `CC_EXCLUDED(7,'E')` (§5.6). |
| `poaErrorCode` | `POA_NOT_CHECKED(0)`, `POA_NOT_RECOGNIZED(1)`, `POA_RECOGNIZED_NOT_POA(3)`, `POA_RECOGNIZED_YES_POA(4)`, `HOSPITAL_EXEMPT(5)` (§6.3). |
| `hacs` | list of `MsdrgHac{hacNumber, hacList, hacStatus, description}` = the SDX's `hacsFlags` (§6.6), sorted by `hacNumber` (`MsdrgCodeFlagsProcessor.java:138-140`). `hacStatus` ∈ `NOT_ON_HAC_LIST(0)`, `HAC_CRITERIA_MET(1)`, `HAC_CRITERIA_NOT_MET(2)`, `HAC_NOT_APPLICABLE_EXCLUSION(3)`, `HAC_NOT_APPLICABLE_EXEMPT(4)`. |

Per-procedure output (`MODEL/MsdrgProcedureFlag.java`, `MsdrgCodeFlagsProcessor.java:156-172`):

| Field | Semantics |
|---|---|
| `procedureRecognizedByGrouper` | code has ≥1 attribute in the procedure table (`CORE/logic/preprocess/ProcedureAttributeProcessor.java:55`). |
| `procedureAffectsDrg` | `MsdrgGroupingImpact` (§4.8). |
| `procedureIsOperatingRoomProcedure` | code has any of attributes `d468`, `d477`, `ornec` (`CORE/model/MsdrgProcedureCode.java:20-21,93-98`). |
| `hacUsage` | set of `MsdrgProcedureHacUsage` `HAC_08(1,8)`, `HAC_10(2,10)`, `HAC_11(3,11)`, `HAC_12(4,12)`, `HAC_13(5,13)`, `HAC_14(6,14)` (§6.5). |

Legacy fixed strings (`toString()`), **Java layout** (differs from mainframe layout, see §1.4):

* `MsdrgGrouperFlags.toString()` (9 chars, `MsdrgGrouperFlags.java:92-141`): `[admit: 0=invalid,1=valid,2=not given][0][final CC/MCC: 1=MCC,5=CC,0][0][0][initial CC/MCC: 1/5/0][numHac tens][numHac ones][hacStatus 0..3]`.
* `MsdrgDiagnosisFlag.toString()` (25 chars, `MsdrgDiagnosisFlag.java:96-147`): if invalid → `"0"` + 24 spaces; else `[1][affects 0-3][finalSeverityUsage int][initialSeverityUsage int][poaErrorCode int]` then for each HAC (triples at positions 5–7, 8–10, 11–13; a 4th would be overwritten by the trailing zero fill): `[status int][hacNumber tens][hacNumber ones]` (hacNumber reported as 0 when status is NOT_MET or EXEMPT **and** `versionFrom == null`; SDX outputs are built with `versionFrom = MSDRG_440`, the PDX output with `null`, `MsdrgCodeFlagsProcessor.java:119-122,142-146`), then zeros to 25.
* `MsdrgProcedureFlag.toString()` (20 chars, `MsdrgProcedureFlag.java:57-90`): invalid → `"0"` + 19 spaces; else `[1][affects][OR 0/1][0][0][0]` then one digit per `hacUsage.intValue()` from position 6, zeros to 20.

### 1.3 TESTDB fixed-width record layout (`MISC/TESTDB`, LRECL 2000, CRLF, 9 864 records)

Source: MFPDF "Table 15" and verified by parsing the file. Positions are 1-based inclusive.

| Cols | Len | Field | Notes |
|---|---|---|---|
| 1–3 | 3 | AGE | right-justified, blank or zero filled (e.g. `040`, `55 `). Unused by grouping. |
| 4 | 1 | SEX | `1` male, `2` female, anything else (`0`, blank) → UNKNOWN. |
| 5–6 | 2 | DISCHARGE STATUS | 2-digit code of §1.1; unknown → `NONE`. |
| 7 | 1 | POALOG | `X` → hospital `EXEMPT`; any other value (`Z`, `Y`, …) → `NON_EXEMPT` (wrapper bytecode `populateClaimWithModelV2`). |
| 8–15 | 8 | ADATE | YYYYMMDD, unused. |
| 16–23 | 8 | DDATE | YYYYMMDD; **selects the grouper version** (v44.0 for ≥ 2026-10-01; see note below). |
| 24–223 | 25×8 | DX1..DX25 | each: 7-char code left-justified blank-padded + 1-char POA. DX1 = PDX. Blank fields are skipped. |
| 224–398 | 25×7 | PROC1..PROC25 | 7-char codes, blank-padded. Blank fields skipped. |
| 399–598 | 25×8 | PRDATES | unused. |
| 599–637 | 39 | CLAIM-OPT-DATA | free text. |
| 638 | 1 | DEBUG-IND | |
| 639–838 | 200 | FILLER | |
| 839–840 | 2 | RTC | expected grouper return code (`00`,`01`,`07`,`98`,`99` occur). `98` = discharge date before 2021-10-01, `99` = invalid date (wrapper, not grouper). |
| 841–842 | 2 | MDC | expected final MDC (`00` for 999). |
| 843–846 | 4 | DRG | expected final DRG, zero padded (`0981`). |
| 847–851 | 5 | GRFLGS | mainframe grouper flags (§1.4). |
| 852–1476 | 25×25 | DXFLGS | mainframe diagnosis flags, one 25-char block per DX position (§1.4). |
| 1477–1976 | 25×20 | PRFLGS | mainframe procedure flags (§1.4). |
| 1977–2000 | 24 | BUFF | ancillary buffer (§1.4). |

**Version caveat.** The wrapper picks the grouper version from DDATE. Only **77 records** have a
v44.0 result (`BUFF` ends in `00144000`); 7 926 records are v39.1, the rest v40.0–v43.1. Only the
v44.0 records are valid regression targets for a v44.0 re-implementation (and the record with
`DDATE=99991231` also maps to v44.0).

Observed input value distributions: POA ∈ {`Y`, `N`, ` `}; SEX ∈ {`1`,`2`,` `,`0`}; DSTAT ∈ {01,02,03,07,20}.

### 1.4 Mainframe output encodings (needed to compare against TESTDB; decoded from `MFJAR` bytecode)

* **GRFLGS** (5): `[numHac 2 digits][final CC/MCC: 1=MCC, 2=CC, 0 otherwise][initial CC/MCC: same][hacStatus: 0 N/A, 1 no change, 2 changed, 3 ungroupable]`.
  The CC/MCC digit is `MsdrgSeverity.getSeverityLevel()` of `(initial|final)DrgSecondaryDxCcMcc` with `3→0`.
* **DXFLGS** (25 per DX; PDX first): invalid → `0` + 24 spaces. Else `[1][affectsDrg 0-3][ccmcc digit]` + up to 5 × (`%02d` hacNumber, 1-digit hacStatus) from `hacs` (missing slots `000`) + `0000000`.
  `ccmcc digit` from `(initialSeverityUsage, finalSeverityUsage)`:
  `0` default; `3` if final `NEITHER` & initial `MCC`; `4` if final `NEITHER` & initial `CC`; `5` final `MCC_EXCLUDED`; `6` final `CC_EXCLUDED`; `7` final `MCC_EXCLUDED_BY_DRG_LOGIC`; `8` final `CC_EXCLUDED_BY_DRG_LOGIC`; `1` if both `MCC`; `2` if both `CC`.
* **PRFLGS** (20 per PR): invalid → `0` + 19 spaces; else `[1][affectsDrg][OR 0/1]` + up to 5 × `%02d` of `MsdrgProcedureHacUsage.intValue()` (1=HAC08 … 6=HAC14), zero padded to 20.
* **BUFF** (24): `0` + 4-digit final DRG + final M/S (0/1/2) + `0` + 3-digit initial DRG + `0` + 4-digit initial DRG + initial M/S + `PPPVVVUU` version (`00144000`).
  The 4-digit DRG = `BASEDRG*10 + severityLevel` where severityLevel is `MCC→1, CC→2, NON_CC→3, NONE→0` (so `9990`, `9980`, `0011`, `9813`). It is the *claim* severity, not whether the DRG splits.
* RTC = final GRC, MDC = final MDC, DRG = final DRG.

### 1.5 Trace facility (optional, `CORE/TraceUtility.java`)

The Java component does not return a trace in the output model; it optionally emits text lines to a
`Consumer<String>` supplied through `MsdrgOption.TRACE` (`CORE/MsdrgComponent.java:64-66`). The lines
(useful for parity debugging) are, in order of emission: claim demographics (`traceClaim`, `:60-80`);
`PROC:`/`CLUSTER:` lines with attributes, HAC usage, cluster ids (`:151-201`); `SDX:` lines with POA,
attributes, severity, HAC attributes (`:116-144`); `PDX:` line with MDC, DXCAT, attributes (`:87-109`);
per evaluated MDC `Analyzing MDC n with mask [...]` (attributes suppressed for that MDC are omitted,
`:265-278`); `->Match on DRG n with formula [...]` + `**Matched on attributes: ...` for pre-MDC and PDX-MDC
matches (`:285-307`; reroute matches are not traced); `***INITIAL DRG Grouping Results` / `***FINAL …`
with GRC, MDC, DRG, M/S, severity (`:236-258`); `***HAC Processing info` (`:314-408`); and
`***Code Marking` listing per-code impact, severity exclusions and HAC statuses (`:433-476`).
Other `MsdrgOption` keys: `RUNTIME_OPTION_FLAGS` (the `RuntimeOptions` object), `CERVAL_REVISION_ID`
(selects a data revision instead of the grouper version; not needed), `CERVAL_TOKEN`,
deprecated `GROUPER_VERSION`/`ICD_VERSION` (`MODEL/MsdrgOption.java`).

---

## 2. Processing chain

### 2.1 Entry point (`CORE/MsdrgComponent.java:97-143`)

1. `RuntimeDataValidation.execute(options)` fills missing option values (§1.1).
2. Build `ProcessingData` (`:174-224`): PDX, admit dx, SDX list (same order as input), sex, discharge status; if procedures exist: list + principal procedure = first element, marked `FIRST_POSITION`.
3. Save original SDX and PR orders (`:104-107`).
4. If tie-breaker is `CLINICAL_SIGNIFICANCE`: **procedures are sorted by code value** (plain `String.compareTo`, i.e. ASCII) (`:109-113`). (SDX are sorted later in `CodeSetup`, §2.3 step 6.)
5. Run the chain (§2.2). The chain is a sequence of links; each returns `(context, continueProcessing)`. If any link returns `continueProcessing=false`, all remaining links are skipped (`CORE/chain/Link.java:50-61`; stream reduction `before.compose(current)` yields execution in listed order, `CORE/chain/GrouperChain.java:73-128`).
6. Restore original SDX/PR order on the processed data (`:129-136`) — outputs are in claim order.
7. Build output (`:152-172`): grouper flags (`MsdrgGrouperFlagsResult`), code flags (`MsdrgCodeFlagsProcessor`, §2.6), initial and final results.

### 2.2 Chain order (`CORE/chain/GrouperChain.java:60-129`)

```
preprocessingLink  = [MsdrgClusters, ProcedureAttributeProcessor, SdxAttributeProcessor,
                      MsdrgExclusions, PdxAttributeProcessor, CodeSetup]
initialGroupingLink= [MsdrgInitialPreGrouping, MsdrgInitialRerouting, MsdrgInitialPdxGrouping,
                      MsdrgInitialRerouting, MsdrgInitialDrgResults]
initialMarking     = [InitialDiagnosisMarking, InitialProcedureMarking,
                      InitialDxFunctionMarking, InitialSgFunctionMarking]
hac                = [MsdrgHacProcessor]
finalGroupingLink  = [MsdrgFinalPreGrouping, MsdrgFinalRerouting, MsdrgFinalPdxGrouping,
                      MsdrgFinalRerouting, MsdrgFinalDrgResults]
finalMarking       = [FinalDiagnosisMarking, FinalProcedureMarking,
                      FinalDxFunctionMarking, FinalSgFunctionMarking]
chain = preprocessingLink → initialGroupingLink → initialMarking → hac → finalGroupingLink → finalMarking
```

Note: `CORE/logic/preprocess/MsdrgLifeStatus.java` exists but **is not in the chain**; ignore it.

### 2.3 Preprocessing links

| # | Link | Inputs | Effects on `ProcessingData` |
|---|---|---|---|
| 1 | `MsdrgClusters` (`CORE/logic/preprocess/MsdrgClusters.java:45-134`) | procedure code values | If there are procedures: find all cluster definitions containing any of the codes; for each cluster walk the procedure list in current order; a code satisfies the first choice set containing it; when every choice set of the cluster is satisfied, **break**, create a cluster pseudo-procedure (`MsdrgClusterCode`, value = cluster id), set its `mdcSuppression` bits, and for every procedure whose value is in the set of codes that matched so far (`chosen`), OR the cluster's restriction bits into the procedure's `mdcSuppression` and add the cluster id to its `clusterIds`. Clusters are then **sorted by cluster id**. Each cluster definition is recognised at most once. Codes after the break are not attached even if they are components. |
| 2 | `ProcedureAttributeProcessor` (`…/ProcedureAttributeProcessor.java:36-75`) | procedure values, clusters | For each procedure: attributes := procedure table attributes (prefix `NONE`), **each attribute copies the procedure's `mdcSuppression` bitset**; if the code has `d477` or `d468` add attribute `ORPROC` (also with the suppression bits); `validCode := attributes non-empty`; `isOperatingRoomProcedure := has d468 or d477 or ornec` (`MsdrgProcedureCode.java:71-74,93-98`). For each cluster: attributes from the procedure table keyed by cluster id (**no suppression bits**) + `ORPROC` if d468/d477. |
| 3 | `SdxAttributeProcessor` (`…/SdxAttributeProcessor.java:36-97`) | SDX values | For each SDX: `VALID` flag if code in dx table; `severity` (MCC/CC/NON_CC; unknown code → NON_CC); `attributes` (regular dx operands, prefix `SDX`); `dxCatAttributes` (`dxcMMCC`, prefix `SDX`); `hacAttributes` (prefix `SDX`); if any HAC attribute name starts with upper-case `"HAC"` → `hacs := list of MsdrgHac(hacNumber, hacList)` for the code (§6.1); if HAC attributes contain `hac06_show` → flag `ON_SHOW_LIST`. |
| 4 | `MsdrgExclusions` (`…/MsdrgExclusions.java:31-104`) | PDX value, SDX list, discharge status | Mark `EXCLUDED` on every SDX whose value is in the PDX's exclusion list (exact string compare). If discharge status is `DIED`: additionally mark `DEATH_EXCLUSION` on every SDX with attribute `mccalive` (case-insensitive). |
| 5 | `PdxAttributeProcessor` (`…/PdxAttributeProcessor.java:41-124`) | PDX value, sex | If PDX value is empty: nothing. Else: attributes/dxcat/hac attributes with prefix `PDX`; if a HAC attribute name ends with `hac11_pdx` → `pdx.hacs := [MsdrgHac(11, "hac11_pdx", status NOT_ON_HAC_LIST)]`; `VALID` flag if known; **MDC**: if code is on the gender list → MDC for the claim's sex (`MALE=1`, `FEMALE=2`); if no entry for the sex (only possible for `UNKNOWN=-1`, since all 73 gender codes have both sexes) → flag `SEX_CONFLICT` and MDC := female MDC; else MDC := code's MDC (−1 if unknown). `severity` of PDX is set but unused. Admit dx gets `VALID` flag if known. |
| 6 | `CodeSetup` (`…/CodeSetup.java:19-47`) | SDX list, options | If `CLINICAL_SIGNIFICANCE`: **sort SDX** by `(severity MCC first, then CC, then others) then code value` (`CORE/model/MsdrgDiagnosisCode.java:56-75`). |

### 2.4 Grouping links (shared template classes, `CORE/logic/commonprocess/`)

All grouping links call `GroupingExecutor.group(processingData, hospitalStatus, mdc, …)`
(`GroupingExecutor.java:32-54`): build the mask (§4.5) from the current data, build an `AstContext`
with `diagnosisCodes = [PDX] + SDX` (PDX first), `procedureCodes` = the (possibly sorted) procedure
list (**clusters are not in it**), `mdc`; then evaluate the DRGLOGIC rows of that MDC in rank order
(§7.1). The result is `EvalContainer{matchedFormula, severity}`.

| Link | Behaviour |
|---|---|
| `PreMdcGrouping` (`PreMdcGrouping.java:67-103`) — initial/final `*PreGrouping` | Evaluate MDC 0 rows. If the match carries a GRC ≠ OK → set **both** initial and final results to ungroupable (`MsdrgUtility.setUngroupable`: DRG 999, base 999, MDC 0, severity NONE, med/surg NONE, `MsdrgUtility.java:32-50`) and **stop the chain**. Else store the match as `preMatch` (state → `PDX`), set MDC-stop list `[0]`, store the pass severity. A no-match is stored as an empty match (drg 0, reroute 0). |
| `MdcRerouteGrouping` (`MdcRerouteGrouping.java:76-144`) — `*Rerouting` (runs twice per pass) | If `needReroute()` (`CORE/chain/GroupingContext.java:44-54`: no reroute match yet and the previous-state match (`preMatch` in state PDX, `pdxMatch` in state DONE) has `REROUTEMDC ≠ 0`): evaluate the rows of that MDC; if GRC ≠ OK → ungroupable (both results) and stop; if the new match itself has `REROUTEMDC ≠ 0`, evaluate **that** MDC once more (two levels max; a third-level reroute would be ignored and end in a DRG-0 exception). Store as `rerouteMatch`; append the **first** reroute MDC to the MDC-stop list; store severity. |
| `PdxMdcGrouping` (`PdxMdcGrouping.java:76-120`) — `*PdxGrouping` | Skip if any match already exists (`hasMatch()`). Else evaluate the rows of the PDX's MDC. GRC ≠ OK → ungroupable, PDX impact := NONE, stop. Else store as `pdxMatch` (state → `DONE`), append PDX MDC to the MDC-stop list, store severity. |
| `MsdrgDrgResults` (`MsdrgDrgResults.java:65-104`) — `*DrgResults` | `match := groupingContext.getMatch()` (`GroupingContext.java:145-153`: `rerouteMatch` if non-empty, else `pdxMatch` if state DONE, else `preMatch`). If `match.drg == 999` → result with MDC 0; if `match.drg == 0` → **throws** `FoundationException("Error: DRG of 0 …")` (no row matched); else build the result (§7.6 for MDC). Stored as initial or final result. |

The severity stored by the last executed grouping link of a pass becomes `initialSeverity` /
`finalSeverity` (`ProcessingData`), which feeds `MsdrgGrouperResult.severity`.

### 2.5 HAC link (`CORE/logic/MsdrgHacProcessor.java:77-116`)

Runs between initial marking and final grouping. Evaluates HAC criteria per SDX (§6), may set the
**final** result to ungroupable with GRC 9/10/11/15 and stop the chain (so final grouping and
final marking are skipped, the initial result stays). With hospital `EXEMPT` all HAC statuses become
`HAC_NOT_APPLICABLE_EXEMPT` and POA error code `HOSPITAL_EXEMPT`.

### 2.6 Output assembly (`CORE/logic/MsdrgCodeFlagsProcessor.java:33-64`)

* `didNotReachFinal := finalGroupingContext.isEmpty()`.
* If `didNotReachFinal && initialDrg != 999` (i.e. HAC made the claim ungroupable): for every SDX run `processSeverityFlag(dischargeStatus)` (§5.6 b).
* If initial GRC ∈ {`INVALID_PDX`, `DX_CANNOT_BE_PDX`}: reset the initial (if final not reached) or final severity usage of every SDX to `NEITHER` (no-op in practice, they are already `NEITHER`).
* Build PDX/SDX/PR output objects (§1.2).

---

## 3. Formula language

### 3.1 Lexer (`CORE/utility/farser/lexer/Lexer.java:31-60`, `TokenTypeLookup.java:251-302`, `lexer/drg/DrgFormulaToken.java:18-57`)

Token types: `ATOM`, `SPACE` (`" "`), `LPAREN` `(`, `RPAREN` `)`, `AND` `&` (precedence 1),
`OR` `|` (precedence 2), `NOT` `~`. The delimiter regex is `((?: )+|\)|\(|~|\||&)` compiled
case-insensitively; **only the space character is whitespace** (tabs are not delimiters, but
`String.trim()` strips them at atom boundaries). Everything between delimiters is one ATOM, trimmed;
empty atoms are dropped; SPACE tokens are dropped (`DrgFormulaTokenFactory.java:14-23`).

ATOM splitting (`DrgFormulaTokenFactory.java:33-50`, `DrgLexerToken.java:17-22`): split on `:`;
exactly one `:` → `prefix:value` (both trimmed); none → value; more → `InvalidParameterException`.
Prefix → `MsdrgAttributePrefix.getPrefixFromString` (case-insensitive match of `ANY`, `PDX`, `SDX`,
`ONLY`, `PT`; anything else or no prefix → `NONE`) (`MsdrgAttributePrefix.java:27-34`,
`CORE/logic/FormulaEvaluator.java:130-134`). Identifiers are otherwise **case-sensitive** (attribute
name comparison in `Attribute.equals` is exact; e.g. `NORmvge96h`, `sglantsectXfuse`).

There are no numeric, comparison or set-theory tokens in DRG formulas; a purely numeric atom such as
the binary-only row `5` is just an identifier that never matches. (`utility/farser/lexer/set/*`
and `ast/node/operator/set/*` implement a separate set-algebra language that is **not used** by the
grouper.)

### 3.2 Parser (`CORE/utility/farser/ast/parser/AstDescentParser.java:155-267`)

Recursive descent with numeric precedence ("lower value = binds tighter"): `NOT` applies to a single
factor, `AND` (1) binds tighter than `OR` (2), both left-associative, parentheses group. The effective
grammar is the conventional one:

```
expr   := term ( '|' term )*
term   := factor ( '&' factor )*
factor := ATOM | '(' expr ')' | '~' factor
```

(Implementation detail: inside parentheses the parser passes the enclosing operator precedence
instead of resetting it, but with only two precedence levels every combination still parses as
above; verified by hand for `a&(b|c)`, `a|(b&c)`, `(a|b)&c`, `a|b&c|d`, `~(a|b)`, `~a&b`.)
Malformed input (two adjacent atoms, unbalanced parentheses) is not rejected: the parser silently
stops at the first unexpected token. All 794 v44 formulas are well formed.

### 3.3 Evaluation (`CORE/utility/farser/ast/node/operator/bool/And.java:17`, `Or.java:17`, `Not.java:33-34`)

`And` = Java `&&`, `Or` = `||` — **short-circuit, left to right**; `Not` negates. This matters because
terminal nodes have side effects (attribute accumulation, code flags): a right operand is not
evaluated when the left one already decides the result. Each DRGLOGIC row is evaluated with a fresh
`AstContext` (fresh accumulator) (`CORE/logic/MsdrgFormulaEvaluation.java:62-68`); the code objects,
however, are shared and their flags persist across rows.

Formulas are lexed once and cached; the AST is rebuilt per evaluation (`FormulaEvaluator.java:77-93`).

### 3.4 Terminal node resolution (`CORE/logic/ast/MsdrgNodeSupplier.java:27-104`)

For each ATOM token, the node factory is chosen by the **token value only (prefix ignored,
case-insensitive)** (`NodeFactory.from`, `:96-104`, using `MsdrgSourceLogicLists.from`, which is
`equalsIgnoreCase`, `CORE/enumeration/MsdrgSourceLogicLists.java:59-66`):

| Token value | Node | Used in v44 DRGLOGIC? |
|---|---|---|
| `MULTST` | `SignificantTrauma` | yes (pre-MDC reroute row, DRG 965) |
| `BILATERAL` | `BilateralNode` | yes (461/462) |
| `SINGLEFUSIONCTR` | `CountThreeNode({sglantfuse, sglpostfuse}, flag FUSION)` | yes (426–428) |
| `MULTFUSE` | `CountFusionsNode({sglantfuse, sglpostfuse1}, FUSION)` | no |
| `SGLANTCTR` | `CountTwoNode({sglantfuse}, FUSION)` | yes (447/448) |
| `SGLPOST1CTR` | `CountTwoNode({sglpostfuse1}, FUSION)` | yes (447/448) |
| `SGLANTSECTXCTR` | `CountFusionsNode({sglantsectXfuse}, FUSION)` | no |
| `SGLPOSTFUSECTR` | `CountFusionsNode({sglpostfuse}, FUSION)` | no |
| `FOUR_VESSELS` | `CountFourNode(vessel1=1,vessel2=2,vessel3=3,vessel4=4; flag VESSEL_4)` | yes (321) |
| `FOUR_STENTS` | `CountFourNode(stent1..4; STENT_4)` | yes (321) |
| `INVALID_DSTAT` | `GrcNode((NONE,"invalid_dstat"), grc 5)` | yes |
| `INVALID_PDX` | `GrcNode((PDX,"invalid_pdx"), grc 7)` | yes |
| `INVALID_SEX` | `GrcNode((NONE,"invalid_sex"), grc 4)` | yes |
| `PDX_ECODE` | `GrcNode((PDX,"pdx_ecode"), grc 1)` | yes |
| `INVALID_AGE` | `GrcNode((NONE,"invalid_age"), grc 3)` | no (unreachable) |
| `MDC_20_FALL_THRU` | `MdcFallThruNode(20, pdx=true)` → true iff first diagnosis (PDX) has MDC 20 | no |
| `incident` (any prefix!) | `OnlyIncidentNode((ONLY,"incident"))` | yes (`ONLY:incident` 795; also `PDX:incident`/`SDX:incident` in 794, see §7.5) |
| anything else | default terminal: `SuppressionContainsNode((prefix, value))` for DRG rows, `ContainsNode` for HAC rows (`FormulaEvaluator.java:48-66,110-122`) | — |

Names in `MsdrgSourceLogicLists` without a factory (`hiv`, `hivmaj`, `stcc`, `NORstent`,
`NORdrugstent`, `ORPROC`, `nonor`, `ANYDX`) are ordinary attributes.

### 3.5 Attribute equality (`CORE/model/Attribute.java:64-108`)

`Attribute(prefix, negated=false, listName)`; `equals` compares `listName` (exact), `negated` (always
false in practice) and `prefix`, with the special rule: a formula/mask attribute with prefix `ANY`
equals an attribute with prefix `ANY`, `PDX` or `SDX` (never `NONE`, `ONLY`, `PT`). Consequences:

* `x` (no prefix) matches only `(NONE,x)` mask entries: procedure/cluster attributes, severity (`MCC`/`CC`), discharge-status words, `ANYDX`, `invalid_dstat`, `invalid_sex`.
* `PDX:x` matches only `(PDX,x)`; `SDX:x` only `(SDX,x)`; `ANY:x` matches `(PDX,x)` or `(SDX,x)`; `ONLY:x` only `(ONLY,x)`.
* `hashCode` uses `(listName, prefix)` without the ANY rule — only matters for `HashSet.contains` calls, which are always `NONE` vs `NONE` in the code. `compareTo` orders by `listName` only (used by `TreeSet`s in marking, §4.8).

### 3.6 Terminal node semantics (`CORE/logic/ast/`)

Let `mask` be the list of mask attributes, `mdc` the MDC being evaluated, `acc` the accumulator.

* **`SuppressionContainsNode(a)`** (`SuppressionContainsNode.java:21-40`): true iff ∃ mask entry `m` with `m.equals(a)` **and** `m.mdcSuppression` does not contain bit `mdc`. On true, `acc += a`. Used for every ordinary identifier in DRG formulas.
* **`ContainsNode(a)`** (`ContainsNode.java:20-26`): true iff `mask.contains(a)` (no suppression); `acc += a`. Used for HAC formulas.
* **`GrcNode(a, grc)`** (`GrcNode.java:25-32`): like `ContainsNode`; additionally sets `context.grc := grc`, which becomes the match's return code (`MsdrgFormulaEvaluation.java:72-75`).
* **`OnlyIncidentNode`** (`OnlyIncidentNode.java:22-35`): `SuppressionContainsNode((ONLY,"incident"))`; when false, marks the **first diagnosis in `diagnosisCodes` (PDX first, then SDX) lacking regular attribute `incident`** with flag `NOT_INCIDENT`.
* **`CountTwoNode(E)`** (`CountTwoNode.java:43-69`): over `procedureCodes` (clusters excluded), for each enum attribute `e ∈ E` present on the code: `count++`, `seen[e]++`. True iff every `e ∈ E` was seen and `count ≥ 2`. On true: `acc += seen attributes`, mark contributing codes `FUSION`.
* **`CountThreeNode(E)`** (`CountThreeNode.java:43-72`): same with `count ≥ 3`. With `E={sglantfuse, sglpostfuse}` this means both attributes present and ≥3 code-attribute hits (e.g. 2 anterior + 1 posterior).
* **`CountFusionsNode(E)`** (`CountFusionsNode.java:41-63`): true iff total hits ≥ 2 (no "all attributes" requirement).
* **`CountFourNode(E with weights)`** (`CountFourNode.java:41-66`): iterate codes **stopping once `count ≥ 4` is reached at the top of the loop**; for each weighted attribute present add its weight. True iff `count ≥ 4`; mark contributing codes (`VESSEL_4`/`STENT_4`), accumulate the attributes seen. (`stent1+stent3`, `stent4`, `stent2+stent2`, … all qualify.)
* **`BilateralNode`** (`BilateralNode.java:19-61`): over procedure codes in order; for each code take the **first** of `righthip, rightknee, rightankle, lefthip, leftknee, leftankle` (enum order) that the code has and that was not found before; stop after 2 found. True iff 2 distinct site attributes found (two *different* sites, not necessarily left/right); mark those codes `BILATERAL`; accumulate both attributes.
* **`SignificantTrauma`** (`SignificantTrauma.java:24-66`): same algorithm over `diagnosisCodes` (PDX first) with attributes `sthead, stchest, stabdom, stkidney, sturin, stpel, stuplimb, stlolimb`, checked with `hasAttribute(name)` (regular attributes, case-insensitive); mark `SIG_TRAUMA`.
* **`MdcFallThruNode`** — unused in v44.

All counting nodes ignore MDC suppression and ignore cluster pseudo-codes.

### 3.7 Identifier → data mapping summary

| Identifier form | Resolved against |
|---|---|
| `PDX:name` | PDX regular attribute, PDX `dxcMMCC`, or PDX HAC attribute named `name` (all three lists are put on the mask with prefix `PDX`, §4.5). |
| `SDX:name` | the same lists of **any** SDX (including excluded/invalid/HAC ones). |
| `ANY:name` | PDX or any SDX. |
| `name` (no prefix) | any procedure attribute (subject to MDC suppression), any cluster attribute, `MCC`/`CC` (claim severity for this row), `ALIVE`/`DIED`/`AMA`/`XFRNBA`/`invalid_dstat`, `ANYDX`, `invalid_sex`, `ORPROC`. |
| `dxcMMCC` | diagnosis category: `MM` = 2-digit MDC, `CC` = 2-digit DXCAT from DXPATERN (e.g. `dxc0306` = MDC 3, DXCAT 6). Only ever used as `PDX:dxc…` in v44. |
| `d468`, `d477`, `d4xx` | ordinary procedure attributes (historic list numbers: `d468` extensive OR, `d477` non-extensive OR, `d484/d485/d486` trauma OR lists). |
| `NOR…` | ordinary procedure attributes whose name starts with `NOR` (non-OR procedure lists). No special handling. |
| `MCC`, `CC` | the claim's computed severity for the row (§5). `NON_CC` is also on the mask but never referenced. |

Worked examples from `MISC/DRGLOGIC` (header `MDC,DRG,MEDSURG,BASEDRG,RETURNCODE,REROUTEMDC,FORMULA,SUPPRESSION`):

* `0,3,S,3,0,0,(ecmo | periphecmo) | ((othtrach | NORtemptrach) & (NORmvge96h | ~PDX:mouthlip) & d468),` — DRG 003: any procedure with `ecmo`/`periphecmo`; or a tracheostomy procedure AND (a ≥96h ventilation procedure OR the PDX is not a face/mouth/neck dx) AND an extensive OR procedure. Parsed as `OR( OR(ecmo,periphecmo), AND( AND( OR(othtrach,NORtemptrach), OR(NORmvge96h, NOT(PDX:mouthlip)) ), d468 ) )`.
* `0,0,,0,0,24,PDX:strauma & MULTST,` — reroute (DRG 0, REROUTEMDC 24) when PDX is a significant trauma code and two distinct trauma body sites are present among PDX+SDX.
* `5,280,M,280,0,0,ALIVE & MCC & ANY:ami,ami` — DRG 280 needs discharge ≠ died, an MCC among SDX **not** carrying attribute `ami` (SUPPRESSION), and an AMI code as PDX or SDX.
* `15,795,M,795,0,0,ONLY:incident,` — normal newborn: PDX has `incident` and every valid SDX has `incident` (§4.5).
* `8,321,S,321,0,0,(arterial | percut) & (NORdrugstent | NORstent) & (MCC | FOUR_STENTS | FOUR_VESSELS),`.

---

## 4. Attribute assignment and marking

### 4.1 Diagnosis attributes from the flat files (DXLIST → DXPATERN)

For a diagnosis code `C`, take all DXLIST rows with `CODE = C` (there can be several: one per
`CODEGENDER` and one per HAC group), and their DXPATERN rows. Derive:

| Derived datum | Rule (verified against the binary for all 74 878 codes, §8.2) |
|---|---|
| valid | `C` appears in DXLIST. |
| `severity` | `MCC` if `MCC` ∈ OPERAND, else `CC` if `CC` ∈ OPERAND, else `NON_CC`. (Identical across the code's rows.) |
| regular `attributes` | OPERAND minus {`MCC`, `CC`} minus operands matching `^hac[0-9]` (case-insensitive). Identical across rows. |
| `dxCatAttributes` | for each row: if `DXCAT ≠ 0`: `sprintf("dxc%02d%02d", MDC, DXCAT)`; if `DXCAT = 0`: nothing. For gender codes the **union** over both gender rows (45 of the 73 gender codes have different DXCAT per sex, and the binary carries both, e.g. A510 → `{dxc1201, dxc1301}`). |
| `hacAttributes` | {`sprintf("HAC%02d", HACNUMBER)` for each row with `HACNUMBER ≠ 0`} ∪ {OPERAND entries matching `^hac[0-9]`} ∪ {`hac06_show` if `HACNUMBER = 6` and `hac06_sdx ∉ OPERAND`}. The last rule reconstructs a binary-only operand (§8.2, §9). |
| `hacNumbers` (for `hacs`) | distinct non-zero `HACNUMBER` values, ascending (binary order; only 7 codes have more than one: `[11,12,13]`). |
| `hacList` name per HAC number | the first element of the binary `hacOperands` list containing the decimal digits of the number (`MODEL/dao/CodeAccess.java:39-61`). Only two names are ever tested by the logic: `"hac06_show"` and `"hac11_pdx"`; so: HAC 6 → `"hac06_show"` for show-list codes, `"hac06_sdx"` otherwise; HAC 11 PDX-only codes → `"hac11_pdx"`; others irrelevant. |
| `mdc` | `MDC` of the (single) non-gender row; for gender codes a map `{1: MDC of CODEGENDER=1 row, 2: MDC of CODEGENDER=2 row}`. |
| exclusion group | `EXCLUSIONGROUP` (identical across rows); 0 = none. |

`PDX`-vs-`SDX` attribute lists are identical in the data (`MODEL/dao/DiagnosisAccess.java:60-74`);
only the prefix given to the attributes differs.

**Only the regular `attributes` list is consulted by `hasAttribute(name)`**
(`CORE/model/MsdrgDiagnosisCode.java:306-322`; the `dxCatAttributes` fallback branch is dead because
`attributes` is never null). `hasAttribute` is case-insensitive. This affects: `mccalive` (§5.2),
severity suppression operands (§5.3), `incident` (§4.5), significant-trauma lists (§3.6), and
"affects DRG" diagnosis marking (§4.8). HAC attributes and `dxc…` attributes are reachable **only**
through the mask.

### 4.2 Procedure attributes (PRLIST → PRPATERN)

For procedure code `P` (one PRLIST row each): attributes := OPERAND minus {`orindic`, `incluster`},
and if `orindic ∈ OPERAND` but neither `d468` nor `d477` is present, add `ornec` (13 codes, §8.3).
`nonor` stays. Procedure codes that are not in PRLIST have no attributes and are invalid.

Cluster ids (`@nnnn` in the flat files, `Z@nnnn` inside the binary) are also keys of PRLIST; their
attributes are derived the same way. The 38 cluster ids present in PRLIST but absent from PRCLSTRS
(`@7302`, `@7307`, `@7486`–`@7521`) can never be produced.

### 4.3 Clusters (PRCLSTRS)

Group rows by `CLUSTERCODE`. For a cluster: choice sets = `{CHOICE → set of PROCCODE}`;
`NUMREQUIREDPROCS` = number of choice sets (always equal in the data); `MDCRESTRICTION` →
suppression bits: `""` → `{99}` (no effect), `"F"` → `{29}`, `"ALL"` → `{1..25, 29}`, `"nn"` → `{nn}`,
`"a|b|F"` → union (verified §8.4). Note `ALL` does **not** include MDC 0, so pre-MDC evaluation is
never suppressed.

### 4.4 Code flags (`CORE/model/MsdrgCode.java:15-35`)

`AFFECTS_DRG`(unused in v44 except by `MdcFallThruNode`), `EXCLUDED`, `VALID`,
`LIMITED_SEVERITY_TRAUMA`/`LIMITED_SEVERITY_HIV` (unused), `SEX_CONFLICT`,
`DOWNGRADE_SEVERITY_SUPPRESSION`, `MARKED_FOR_INITIAL`, `MARKED_FOR_FINAL`, `SIG_TRAUMA`,
`ON_SHOW_LIST`, `DEATH_EXCLUSION`, `CLUSTER` (unused), `BILATERAL`, `VESSEL_4`, `STENT_4`,
`FIRST_POSITION`, `NOT_INCIDENT`, `FUSION`.

### 4.5 Mask construction (`CORE/logic/MsdrgMaskBuilder.java:39-122`)

The mask is a **list** (duplicates allowed) built fresh for every MDC evaluation and for every HAC
formula evaluation, in this order:

1. For each SDX (all of them, including invalid, excluded, HAC): its `attributes`, `dxCatAttributes`, `hacAttributes` (prefix `SDX`).
2. For each procedure: its `attributes` (prefix `NONE`, each carrying that procedure's `mdcSuppression` bitset, including the synthetic `ORPROC`).
3. For each cluster pseudo-code: its `attributes` (prefix `NONE`, **no** suppression).
4. PDX `attributes`, `hacAttributes`, `dxCatAttributes` (prefix `PDX`).
5. `(PDX, invalid_pdx)` if PDX is not `VALID`.
6. `(PDX, pdx_ecode)` if the PDX value matches `^[VWXYvwxy]` (first character), regardless of validity.
7. `(NONE, ALIVE)` if discharge status ≠ `DIED`.
8. `(NONE, <formula string>)` if the discharge status has one (`invalid_dstat`, `AMA`, `DIED`).
9. `(NONE, XFRNBA)` if discharge status ∈ {2, 5, 66, 82, 85, 94}.
10. `(NONE, ANYDX)` always.
11. `(ONLY, incident)` if the PDX has regular attribute `incident` **and** every SDX that is `VALID` has `incident` (invalid SDX are ignored; an empty SDX list qualifies).
12. `(NONE, invalid_sex)` if sex is `UNKNOWN` **and** the PDX was flagged `SEX_CONFLICT` (gender-specific PDX).

The claim-severity attribute `(NONE, "MCC"|"CC"|"NON_CC")` is appended per row by the evaluator
(§5.4), not by the mask builder.

### 4.6 Initial vs final grouping — what differs

The two passes run the identical algorithm on the same mask. The only differences:

* In the final pass, SDX with a met HAC (`isHac`, §6.2) are removed from the severity computation (`MsdrgFormulaEvaluation.java:53-60`). In the initial pass no HAC has been evaluated yet (all statuses `NOT_ON_HAC_LIST`), so nothing is removed.
* Results are stored in separate slots (`initialResult/finalResult`, `initialSeverity/finalSeverity`, `initialGroupingContext/finalGroupingContext`, `initialMdc/finalMdc`).
* The affects-DRG marking links set `MARKED_FOR_INITIAL`/impact `INITIAL` vs `MARKED_FOR_FINAL`/impact `FINAL` (or `BOTH` if already `INITIAL`) (`CORE/logic/marking/Marking.java:26-34`).

If no HAC is met the final pass necessarily reproduces the initial DRG.

### 4.7 `MsdrgMaskAttributes` / `MsdrgMatchedDrgFormula`

`MsdrgMatchedDrgFormula{baseDrg, drg, surgical, reRouteMdcId, formula, matchedAttributes, mask,
grouperReturnCode}` (`CORE/model/MsdrgMatchedDrgFormula.java`). `matchedAttributes` = the accumulator
content of the winning row = every terminal attribute that evaluated **true** during that row's
evaluation (including operands of a `~` that were true, and left operands of failed `&`).
`isEmpty()` ⇔ `baseDrg==0 && drg==0 && reRouteMdcId==0 && formula==null`.

### 4.8 "Affects DRG" marking links (`CORE/logic/marking/`)

All four links are skipped when `computeAffectDrg ≠ COMPUTE`. They run after each pass on that pass's
`GroupingContext.getMatch()` and never change the DRG.

**(a) `DiagnosisMarking`** (`DiagnosisMarking.java:34-105`): `matched := TreeSet(match.matchedAttributes)`
(ordered **and de-duplicated by listName**, §3.5). For each SDX in processing order, for each matched
attribute in that order:

1. if the SDX is already marked in this pass for this very attribute object → drop the attribute, next SDX (effectively dead code: the loop `break`s right after marking, so an SDX is never revisited);
2. skip `(ONLY, incident)`;
3. skip attributes whose prefix is `PDX` or `ANY` **and** which the PDX has as a regular attribute (`hasAttribute(name)`);
4. if name is `MCC`/`CC` (case-insensitive) and the SDX is not `DOWNGRADE_SEVERITY_SUPPRESSION`/`EXCLUDED`/`DEATH_EXCLUSION` and `sdx.severity.name()` equals the name → mark SDX, remember attribute, drop attribute, next SDX;
5. else if prefix is `SDX` or `ANY` and the SDX `hasAttribute(name)` → mark, drop, next SDX.

Thus each matched attribute marks at most the first SDX (in sorted order) that satisfies it, and each
SDX is marked for at most one attribute per pass. The first MCC (resp. CC) SDX in clinical order is the
one credited with `MCC`. `PDX:`-prefixed `dxc…` attributes never mark anything (step 5 needs `SDX`/`ANY`
and `hasAttribute` ignores dxcat). Additionally, if this pass's DRG differs from the initial DRG
(`differentDrgs`, `GroupingContext.java:96-103`; true also when either match is empty), every SDX with
`hasHacs()` (a `hacsFlags` entry with status `HAC_CRITERIA_MET`) is marked — effective only in the final
pass (the initial pass compares the initial context with itself).
Then (`InitialDiagnosisMarking.java:47-83`) the PDX impact is set to `INITIAL` (initial pass, unless
GRC ∈ {5,1,7,4} — unreachable here since GRC≠OK stops the chain) or `BOTH` + both marks (final pass,
`FinalDiagnosisMarking.java:47-92`, unless final GRC ∈ {5, 9, 10, 11, 15}); and the severity usage flags
are computed (§5.6).

**(b) `ProcedureMarking`** (`ProcedureMarking.java:56-145,175-302`): `mdc := match.reRouteMdcId`, or the
PDX MDC if 0; `29` if the matched DRG ∈ {981, 982, 983, 987, 988, 989}. "Suppressed" below means
`procedure.mdcSuppression` contains bit `mdc`.
`procAttrs := matched attributes with prefix NONE except MCC/CC/NON_CC` (this includes
non-procedure words such as `ALIVE`; harmless).

1. `oneProcForAllAttributes`: if `procAttrs` non-empty: (i) the `FIRST_POSITION` procedure, if it is an OR procedure, not suppressed and has all of `procAttrs` → mark it; return true unless it is flagged `FUSION`; (ii) first other procedure (claim/sorted order) not suppressed having all `procAttrs` → mark, return true; (iii) first cluster having all `procAttrs` → mark every procedure whose `clusterIds` contains it (each distinct code value once), return true. Otherwise false.
2. Else for each matched attribute `a` (HashSet order): if `a.name == "revision"` and `completeSystemTieBreaker` (both a non-suppressed procedure and a cluster carry `a`: mark the principal procedure if it has `a`, else the first such procedure; return true) → continue; if ≥2 non-suppressed procedures have `a` and not `markAllFusionCodes` (MDC 8 only: mark every `FUSION` procedure) → mark the principal procedure if it has `a`, is OR and not suppressed, else the first non-principal procedure having `a` not suppressed; else → mark the first non-suppressed procedure having `a`, or if none, every procedure belonging to the first cluster having `a`.
3. `hacMarking` (final pass only, `FinalProcedureMarking.java:61-81`): if final DRG ≠ initial DRG, every procedure with a `hacUsage` entry whose HAC number is met (status `HAC_CRITERIA_MET` on some SDX `hacs`) and not suppressed → mark `FINAL`/`BOTH`.

**(c) `DiagnosisFunctionMarking`** (`DiagnosisFunctionMarking.java:39-99`): on the pass's `preMatch`:
if the PDX is `SIG_TRAUMA` mark it; if the pre-match attributes contain any `st…` trauma attribute, mark
SDX flagged `SIG_TRAUMA` in order until 2 diagnoses (incl. PDX) are marked, then remove the trauma
attributes from the pre-match's attribute set. If the pass's DRG is **794**, mark every SDX flagged
`NOT_INCIDENT`.

**(d) `ProcedureFunctionMarking`** (`ProcedureFunctionMarking.java:57-120`): if the match's attributes
intersect {`stent1..4`}: mark every procedure flagged `STENT_4`; then if attributes ⊇ {`arterial`,
`NORdrugstent`} mark unmarked procedures having both; else if ⊇ {`arterial`, `NORstent`} likewise; remove
stent/arterial/NORdrugstent/NORstent from the match's attribute set. If attributes intersect
{`vessel1..4`}: mark every `VESSEL_4` procedure; remove the vessel attributes.

Impact values: initial pass sets `INITIAL`; final pass sets `BOTH` if already `INITIAL`/`BOTH`, else
`FINAL` (`Marking.java:26-34`, `ProcedureMarking.java:151-159`).

---

## 5. CC/MCC severity determination

### 5.1 Inputs

Per SDX: `severity` (MCC/CC/NON_CC from the dx table; invalid code → NON_CC), flags `EXCLUDED`,
`DEATH_EXCLUSION`, `DOWNGRADE_SEVERITY_SUPPRESSION`, HAC status, regular attributes.

### 5.2 PDX→SDX exclusion (`MsdrgExclusions.java:73-104`)

`EXCLUSN` rows `EXCLUSIONGROUP,CODE`. For the PDX, `g := DXLIST.EXCLUSIONGROUP`; if `g ≠ 0`, every SDX
whose code is in `{CODE | EXCLUSIONGROUP = g}` is flagged `EXCLUDED`. (`g` values 2..2505; many groups
contain the PDX code itself, so an SDX equal to the PDX is excluded.) PDX not in DXLIST → no exclusions.
If discharge status is `DIED`, every SDX with regular attribute `mccalive` (case-insensitive) is
additionally flagged `DEATH_EXCLUSION` ("not an MCC if the patient died"). The `mccalive` codes are
MCCs that count only when alive; there is no "CC alive" concept.

### 5.3 Per-row severity suppression (`CORE/logic/MsdrgSeverityProcessor.java:22-48`)

Evaluated **for every DRGLOGIC row before the row's formula**, with the row's `SUPPRESSION` operands
(set of attribute names, `|`-separated, may be empty), over `nonHacCodes` (all SDX in the initial pass;
SDX minus met-HAC codes in the final pass):

```
for each sdx in nonHacCodes:
    clear DOWNGRADE_SEVERITY_SUPPRESSION
    if sdx.hasAttribute(any suppression operand): set DOWNGRADE_SEVERITY_SUPPRESSION
    candidate iff not DOWNGRADE and not EXCLUDED and not DEATH_EXCLUSION
severity := min over candidates of severity level (MCC=1 < CC=2 < NON_CC=3), default NON_CC
```

Duplicates and POA are irrelevant here. The flag `DOWNGRADE_SEVERITY_SUPPRESSION` therefore reflects the
**last row evaluated** of the pass (= the matched row); met-HAC codes keep whatever the initial pass left.

The 23 distinct suppression operands (`ami, brstmal, curvoth, delvoc, diabetes, extburn, extimm,
fullburn, hiv, hivmaj, hivsig, incident, inhalinj, mcomp, mdc15fallthrough, nbmaj, nonextburn, pneuinf,
preterm, procoma, renalfail, s492, stcc`) are all regular DX attributes (never `dxc…`/HAC names). Typical
use: the condition that *defines* the DRG must not also count as its CC/MCC — e.g. `ami` on DRGs 280–285,
`stcc` ("removed from MDC 24 for MCC/CC") on every MDC 24 row, `hiv|hivmaj` on 974–976,
`nbmaj|preterm` on 791–792, `diabetes|renalfail` on pre-MDC 008/019, `extburn|fullburn` on 927.
The names `hiv`, `hivmaj`, `stcc` also appear in `MsdrgSourceLogicLists` but carry no special behaviour.

### 5.4 Feeding the formula

The row is then evaluated with the mask plus `(NONE, severity.name())` (`"MCC"`, `"CC"` or `"NON_CC"`)
(`MsdrgFormulaEvaluation.java:62-66`). Hence `MCC` in a formula means "the claim severity computed for
this row is MCC"; `(MCC | CC)` means "at least CC"; a formula without `MCC`/`CC` is severity-neutral.
The severity of the matched row becomes the pass's claim severity (`EvalContainer.severity`).

### 5.5 Discharge status interactions

* `mccalive` + `DIED` → `DEATH_EXCLUSION` (§5.2).
* `SDX:mccalive & INVALID_DSTAT` (MDC 0 row 2) → GRC 5 when an `mccalive` SDX exists and the discharge status is missing/invalid; similarly `ANY:ami & INVALID_DSTAT` (MDC 5), and `INVALID_DSTAT` in MDC 15 and MDC 20 (§7.4).

### 5.6 Severity usage flags per SDX

(a) Normal path — `markSeverityFlag(pass)` (`CORE/model/MsdrgDiagnosisCode.java:187-226`), applied by the
diagnosis marking links (the surrounding conditions in `InitialDiagnosisMarking.java:85-100` /
`FinalDiagnosisMarking.java:94-116` only skip cases whose result would be `NEITHER` anyway):

| Condition (first match wins) | initial/final usage |
|---|---|
| `DEATH_EXCLUSION && !EXCLUDED` | `NEITHER` |
| `(DEATH_EXCLUSION ‖ EXCLUDED) && severity == MCC` | `MCC_EXCLUDED` |
| `(DEATH_EXCLUSION ‖ EXCLUDED) && severity == CC` | `CC_EXCLUDED` |
| `DOWNGRADE && MCC` | `MCC_EXCLUDED_BY_DRG_LOGIC` |
| `DOWNGRADE && CC` | `CC_EXCLUDED_BY_DRG_LOGIC` |
| `!EXCLUDED && MCC` | `MCC` |
| `!EXCLUDED && CC` | `CC` |
| otherwise | `NEITHER` |
| **final pass only**, afterwards: `!DOWNGRADE && hasHacs()` | `NEITHER` (overrides) |

(b) HAC-ungroupable path — `processSeverityFlag(dischargeStatus)` (`MsdrgDiagnosisCode.java:233-258`),
used when the final pass was never reached but the initial DRG is real (§2.6): sets **final** usage:
`EXCLUDED` → `MCC_EXCLUDED`/`CC_EXCLUDED`; else `DOWNGRADE` → `…_BY_DRG_LOGIC`; else `mccalive && DIED` →
`NEITHER`; else `hasHacs()` → `NEITHER`; else `MCC`/`CC` by severity (NON_CC unchanged = `NEITHER`).

---

## 6. HAC (hospital-acquired condition) logic

### 6.1 Data

HAC numbers 1–14 (`CORE/enumeration/MsdrgHacCategory.java:7-22`; descriptions are binary-only, §8.11).
HAC formulas are **not in the flat files**; they were dumped from the binary (`DataBlob.getHacFormulas`)
and are, for v44.0 (one formula per HAC, evaluated with plain `ContainsNode`, no suppression):

| HAC | Formula | Meaning |
|---|---|---|
| 1 | `SDX:HAC01` | any SDX with HACNUMBER 1 |
| 2 | `SDX:HAC02` | |
| 3 | `SDX:HAC03` | |
| 4 | `SDX:HAC04` | |
| 5 | `SDX:HAC05` | |
| 6 | `SDX:hac06_sdx \| (SDX:hac06_sdx & SDX:hac06_show)` | ≡ `SDX:hac06_sdx` (a catheter-infection code T83511A/T83518A present) |
| 7 | `SDX:HAC07` | |
| 8 | `SDX:HAC08 & hac08_proc` | |
| 9 | `SDX:HAC09` | |
| 10 | `SDX:HAC10 & hac10_proc` | |
| 11 | `PDX:hac11_pdx & SDX:hac11_sdx & hac11_proc` | |
| 12 | `SDX:HAC12 & hac12_proc` | |
| 13 | `SDX:HAC13 & hac13_proc` | |
| 14 | `SDX:HAC14 & hac14_proc` | |

Because the mask is claim-wide, a HAC-list SDX "meets" its HAC whenever the claim as a whole satisfies
the formula (e.g. HAC 5: every HAC05 SDX with eligible POA is met as soon as any HAC05 SDX is on the
mask — i.e. itself). `hacNN_proc` are procedure attributes (`PRATTLST`).

An SDX has `hacs` (is "on a HAC list") iff one of its HAC attributes starts with upper-case `HAC`
(§2.3 step 3), i.e. iff some DXLIST row for it has `HACNUMBER ≠ 0`; PDX-only `hac11_pdx` codes (E6601,
E66813) have no `hacs` as SDX.

### 6.2 `isHac` (`MsdrgHacProcessor.java:60-74`)

`isHac(sdx) ⇔ hospitalStatus ≠ EXEMPT and some entry of sdx.hacs has status HAC_CRITERIA_MET`. Used
to drop codes from severity in the final pass (§4.6) and in `FinalDiagnosisMarking`.

### 6.3 Evaluation per SDX (`MsdrgHacProcessor.java:129-162`)

For each SDX with non-empty `hacs`, for each `hac` entry:

* POA ∈ {`Y`, `W`} → status `HAC_CRITERIA_NOT_MET`, poaErrorCode `POA_RECOGNIZED_YES_POA`.
* else if SDX is `EXCLUDED` → `HAC_NOT_APPLICABLE_EXCLUSION`, poaErrorCode per POA (`N`/`U` → `POA_RECOGNIZED_NOT_POA`, else `POA_NOT_RECOGNIZED`).
* else → evaluate the HAC formula (§6.1) on the claim mask → `HAC_CRITERIA_MET` / `HAC_CRITERIA_NOT_MET`; poaErrorCode per POA; if POA ∈ {`E`, `BLANK`, `ONE`, `INVALID`} set `hasInvalidPoaOnClaim`; if met: record the SDX under its HAC number; if HAC 6 and the SDX is **not** `ON_SHOW_LIST` → `codeOnHac6ButNotShowList := this code`.

Then (`:164-175`): if no non-show HAC-6 code was met (`codeOnHac6ButNotShowList == null`), every `hac`
whose `hacList == "hac06_show"` is reset to `HAC_CRITERIA_NOT_MET` (UTI "show" codes count only when the
catheter-infection code itself is a HAC).

POA `N`/`U`/`E`/`BLANK`/`ONE`/`INVALID` are all "not present on admission" for criteria purposes; only the
invalid ones (`E`, `BLANK`, `ONE`, `INVALID`) can trigger GRC 9/11/15.

### 6.4 Claim-level outcome by hospital status (`:201-311`)

* **`NON_EXEMPT`**, if any HAC was met: for each met HAC number: HAC 6 → ungroupable if `codeOnHac6ButNotShowList ≠ null` and some met HAC-6 SDX has an invalid POA; any other HAC → ungroupable if `hasInvalidPoaOnClaim` (the inner `dx.hasHacs()` test is always false at this point because `hacsFlags` is still empty). Ungroupable ⇒ **final** result = 999 with GRC **9** (`HAC_MISSING_ONE_POA`), `hacsFlags` updated (§6.6), chain stops.
* **`UNKNOWN`**, if any HAC was met: for the first SDX with `hacs`: if the claim has ≥ 2 SDX (the POA test `poa != Y || poa != W` is always true, so `poaCounter` = number of SDX) → GRC **15**; else if its POA ∈ {`N`, `U`} → GRC **10**; else if POA ∈ {`INVALID`, `ONE`, `BLANK`, `E`} → GRC **11**. In each case the final result is 999 and the chain stops. (I.e. with `UNKNOWN`, a met HAC makes the claim ungroupable unless it is the single SDX with POA Y/W — which cannot be met. Effectively always ungroupable.)
* **`EXEMPT`**: no HAC evaluation outcome is used; all `hacs` statuses → `HAC_NOT_APPLICABLE_EXEMPT`, poaErrorCode → `HOSPITAL_EXEMPT` (`:90-100`); `isHac` false ⇒ final DRG = initial DRG.
* Otherwise the chain continues to final grouping with `isHac` codes demoted.

### 6.5 Procedure HAC usage (`:177-199`)

For every SDX with non-empty `hacs` (regardless of status) and every `hac` with number ∈ {8,10,11,12,13,14},
every procedure having an attribute whose name contains `hacNN_proc` (`hac0N_proc` for N<10) gets
`hacUsage += HAC_NN`. (Set even when the criteria were not met.)

### 6.6 `hacsFlags` (output list) (`updateHacListAfterEvaluation`, `:316-383`)

For each SDX with `hacs`, iterate its `hacs` in order:
`MET` → add (HAC 6 at most once); `NOT_MET` with POA `Y`/`W` → add and **stop** (only the first);
`NOT_APPLICABLE_EXCLUSION` / `NOT_APPLICABLE_EXEMPT` → add; `NOT_MET` with other POA → skip.
If nothing was added, add **all** entries with `hacNumber := 0` (reported as "00"+status).
PDX: if the PDX has `hacs` (hac11_pdx) and some SDX `hacsFlags` has HAC 11 `MET` → PDX `hacsFlags :=
[MsdrgHac(11, status NOT_ON_HAC_LIST)]`.

### 6.7 Suppression mechanism vs HAC

The DRGLOGIC `SUPPRESSION` column and `SuppressionContainsNode` are unrelated to HAC: the former is
severity suppression (§5.3), the latter is cluster MDC-restriction suppression (§3.6). HAC demotion
works solely by removing met-HAC SDX from the severity computation in the final pass.

### 6.8 Initial vs final DRG

Initial DRG = result of the initial pass (no HAC). Final DRG = result of the final pass (met-HAC SDX
removed from severity) or 999 with GRC 9/10/11/15. `MsdrgGrouperFlags.hacStatusValue` summarises the
difference (§1.2).

---

## 7. DRGLOGIC evaluation semantics

### 7.1 Row order and first match (`CORE/logic/MsdrgFormulaEvaluation.java:41-83`)

Rows of one MDC are evaluated in ascending `rank` (binary) = **file order within the MDC in
`MISC/DRGLOGIC`** (verified identical, §8.1). For each row: compute severity (§5.3), build mask + severity,
evaluate; the **first true row wins** and evaluation stops. No row true → empty match → later
`FoundationException` (every MDC in the data ends with catch-all rows such as `PDX:dxc0104`, so a valid
PDX always matches something; an R implementation must treat "no match" as an internal error).

### 7.2 Columns

| Column | Meaning |
|---|---|
| `MDC` | 0 = pre-MDC rows; 1–25 PDX MDCs; 29 = "unrelated OR procedure" pseudo-MDC (rows 981–983, 987–989). |
| `DRG` | the DRG assigned on match; `0` = reroute row; `999` = GRC row; `998` = ordinary row (MDC 14). |
| `MEDSURG` | `M`/`S`/blank → `MEDICAL`/`SURGICAL`/`NONE`. Binary stores `MEDICAL`/`SURGICAL`/`NA`. |
| `BASEDRG` | base DRG (0 for reroute/GRC rows). |
| `RETURNCODE` | GRC for 999 rows (1,4,5,7). In the Java the return code comes from the `GrcNode` in the formula, not from this column (the binary stores DRG 0 and no return code for these rows); the column is consistent with the formula's node. |
| `REROUTEMDC` | if ≠ 0 the match is a reroute: evaluation continues with that MDC's rows (§2.4). |
| `FORMULA` | §3. |
| `SUPPRESSION` | `\|`-separated dx attribute names excluded from the severity computation for this row (§5.3); 56 rows have one. |

### 7.3 Pre-MDC (MDC 0) rows, in order (`MISC/DRGLOGIC` lines 2–25)

GRC rows `SDX:mccalive & INVALID_DSTAT` (5), `INVALID_PDX` (7), `PDX_ECODE` (1); then pre-MDC DRGs
018, 001–002, 003, 007, 004, 014, 005–006, 010, 019, 016–017, 008, 011–013; then reroutes
`PDX:strauma & MULTST` → 24, `PDX:hiv | (PDX:hivsig & SDX:hiv)` → 25, `kidneyxp` → 11; last
`INVALID_SEX` (4). Hence an unknown-sex gender-specific PDX still gets a pre-MDC DRG if one applies.

### 7.4 Reroute rows and GRC rows inside MDCs

* `(d468 | d477)` → 29 appears in MDCs 1–13, 16, 20, 21, 24 (after that MDC's surgical rows, before its medical rows; in MDC 20 it is the first row). Claims with an OR procedure that match no surgical DRG of their MDC go to MDC 29 (DRGs 981–989, which match on `MCC & d468`, `CC & d468`, `d468`, `MCC & d477`, `CC & d477`, `d477`).
* `ANY:ami & INVALID_DSTAT` (GRC 5) in MDC 5 after the surgical rows; `INVALID_DSTAT` first in MDC 15; `INVALID_DSTAT` second in MDC 20 (after the reroute).
* MDC 15 (newborns; PDX MDC 15 only, never rerouted into) rows in order: `INVALID_DSTAT` (GRC 5); 789 `(DIED | XFRNBA)`; 795 `ONLY:incident`; 790 `ANY:extimm` (suppression `extimm`); 791 `ANY:nbmaj & ANY:preterm` (`nbmaj|preterm`); 792 `ANY:preterm` (`nbmaj|preterm`); 793 `ANY:nbmaj` (`nbmaj`); 794 (see §7.5, suppression `incident|mdc15fallthrough`). Newborn DRGs therefore depend on discharge status (`DIED`, transfer `XFRNBA`) and on whether every valid SDX is "incidental".
* MDC 24 (multiple significant trauma) is reached only by reroute (no PDX has MDC 24); its rows 955–959 (trauma OR lists `d484`/`d485`/`d486`, 957–959 split on `MCC`/`CC`; all with suppression `stcc`), reroute `(d468|d477)` → 29, then 963–965 (`PDX:strauma & MCC`, `PDX:strauma & CC`, `PDX:strauma & MULTST`; suppression `stcc`). Because the pre-MDC reroute condition equals row 965, a rerouted claim always matches.
* MDC 25 (HIV) is reached by the pre-MDC reroute `PDX:hiv | (PDX:hivsig & SDX:hiv)` or directly (B20 is the only PDX with MDC 25). Rows: 969 `ANY:hiv & d468 & MCC`, 970 `ANY:hiv & d468`, 974–976 `((PDX:hiv & SDX:hivmaj) | (PDX:hivmaj & SDX:hiv)) [& MCC | & CC]` (suppression `hiv|hivmaj`), 977 `PDX:hiv | ((PDX:hivsig & ~PDX:hivmaj) & SDX:hiv)` (suppression `hiv|hivsig`). No `(d468|d477)` reroute row: HIV claims with other OR procedures stay in MDC 25 (969/970).
* MDC 29 has no reroute/GRC rows; it always matches because the reroute condition `(d468|d477)` implies one of its rows — **except** that the attribute on the mask in MDC 29 may be suppressed by an `F`-restricted cluster; then only the cluster's own `d468`/`d477` can satisfy it (worked example §7.8).

### 7.5 Special rows

* DRG 795 `ONLY:incident` and 794 `(PDX:incident & SDX:mdc15fallthrough) | (PDX:mdc15fallthrough & SDX:incident) | ANY:drg794codes`: because node resolution ignores the prefix (§3.4), all three `…:incident` identifiers are `OnlyIncidentNode`s testing `(ONLY,incident)`. Since 795 precedes 794, the first two clauses of 794 can never be true when 794 is reached; 794 effectively reduces to `ANY:drg794codes`. Reproduce this behaviour (do not "fix" it).
* DRG 998 `PDX:dxc1408` (MDC 14) — a normal row (GRC OK, severity reported `NONE`).
* `MCC & intracran & PDX:hemorrhage` (DRG 20): the first row of MDC 1 shows the usual severity split pattern `MCC & X`, `CC & X`, `X`.

### 7.6 MDC reported in the result (`CORE/logic/commonprocess/MsdrgDrgResults.java:76-96`)

Let `stops` be the pass's MDC-stop list: `[0]` after pre-grouping, then `+ rerouteMdc` (first level
only) and/or `+ pdxMdc`.

* DRG 999 → MDC 0.
* `stops.last == 29` → 24 if `24 ∈ stops`, else 25 if `25 ∈ stops`, else `stops[len-2]` (the MDC the claim was rerouted from — e.g. `[0, 5, 29]` → 5).
* `stops.last ≠ 0` → `stops.last` (e.g. `[0, 24]` → 24, `[0, 25]` → 25, `[0, 11]` → 11, `[0, 6]` → 6).
* `stops.last == 0` (pre-MDC DRG matched) → **the PDX's MDC** (so DRG 001 with PDX I10 reports MDC 05).

### 7.7 Edit return codes

| GRC | Name | Trigger |
|---|---|---|
| 0 | OK | normal, incl. DRG 998 |
| 1 | DX_CANNOT_BE_PDX | PDX value starts with V/W/X/Y (external-cause code; all such codes have MDC 0 and attribute `ecode`) — MDC 0 row `PDX_ECODE` |
| 4 | INVALID_SEX | sex UNKNOWN and PDX gender-specific — MDC 0 last row |
| 5 | INVALID_DISCHARGE_STATUS | discharge status missing/unknown **and** (an `mccalive` SDX, or an AMI dx in MDC 5, or MDC 15, or MDC 20) |
| 7 | INVALID_PDX | PDX missing/empty/not in DXLIST — MDC 0 row 3 |
| 9, 10, 11, 15 | HAC_* | §6.4 (final result only) |

GRC 2, 3, 6 of the mainframe manual do not occur. GRC rows always set DRG 999, base 999, MDC 0,
severity NONE, M/S NONE for **both** initial and final (except HAC ones: final only).

### 7.8 Worked example (TESTDB record 2: PDX `I10`, SDX `A064` POA N, PR `0SPT4JZ`, `0SRV0JZ`; TESTDB expects DRG 981, MDC 05 — computed there by v39.1; the trace below uses the v44.0 tables and reaches the same result)

1. Clusters: `0SPT4JZ`(choice 1) + `0SRV0JZ`(choice 2) form `@7093` (restriction `10|F` → bits {10, 29}). Both procedures get suppression {10,29} and `clusterIds={@7093}`. Cluster attributes (PRPATERN 712 minus orindic): `d468, or_allowed_in_768, oth02, rightknee` (no suppression).
2. PDX I10: MDC 5, `dxc0511`, NON_CC. A064: MCC, not excluded.
3. Pre-MDC rows: none match (no `(d468|d477)` row there; `kidneyxp` etc. absent).
4. MDC 5 rows: surgical rows fail; reroute row `(d468 | d477)`: `d468` from the procedures is not suppressed in MDC 5 (bits {10,29}) → reroute to 29. `stops = [0, 5, 29]`.
5. MDC 29 row 981 `MCC & d468`: severity of the row = MCC (A064); `d468` from the procedures **is** suppressed (bit 29) but the cluster's `d468` is not → match. DRG 981, base 981, surgical.
6. MDC reported: last stop 29, no 24/25 → 5.
7. Marking: `procAttrs = {d468}`; first procedure is OR but suppressed in MDC 29; second suppressed; cluster `@7093` has `d468` → both procedures marked (both show `affects=3` in TESTDB).
8. A064 is credited with `MCC` → `initialDrgSecondaryDxCcMcc = MCC`; its usage flag `MCC`; GRFLGS `00110`.

---

## 8. Flat file formats and binary equivalence

Common properties (`MISC/*`): ASCII, CRLF line endings (every line, including the last), comma-delimited
with a header row (except `MDCDSC`, `DRGDSC3`, `DRGDSC4` which have no header), no trailing spaces, no
blank lines. In `DXATTLST`, `PRATTLST` and `DRGDSC3` fields containing commas are double-quoted
(RFC-4180 style: `"Traumatic Stupor and Coma, Coma < 1 Hour"`) — read with a standard CSV reader. In
`MDCDSC` and `DRGDSC4` descriptions containing commas are **not** quoted — split on the first comma
only. All other files never contain quotes or embedded commas. Strip `\r`.

Verification method: the real binary (`runtime_buffers/msdrg_combined.bin`, loaded with the shipped
`DataBlob` class for version 440) was dumped for every code/cluster/formula and compared with the flat
files. Results per file below. The binary is organised as a protobuf `Root` with fields
1 diagnoses, 2 procedures, 3 codeToClusterIds, 4 exclusionGroups, 5 pdxExclusionGroups, 6 clusters,
7 codeGenderMdcs, 8 formulaRoot, 9 hacFormulaLists, 10 hacInformation, 11 dxPatterns, 12 prPatterns,
13 drgDescriptions, 14 mdcDescription, 15 baseDrgDescriptions, 16 hacDescription
(`ACCESS/Data.java:1120-1510`), every entry tagged with version ranges (`IntRangeMap`), loaded in
`ACCESS/DataBlob.java:113-206`.

### 8.1 DRGLOGIC (794 rows + header)

Columns §7.2. Binary `FormulaItem` has `drg, mdc, baseDrg, surgical, reRouteMdcId, formula,
severitySuppressionOperand[], drgSeverity, grouperReturnCode, versionRanks[]`
(`ACCESS/Data.java:26662-26907`). Equivalence: all 794 flat rows match the binary rows of version 440
in order (rank), DRG/base/medsurg/reroute/formula (modulo whitespace)/suppression. Differences:
(a) the binary has 28 additional **inert** rows absent from the file: one `MDCnn` row per MDC 0–25
(formula is the literal identifier `MDC00`…`MDC25`, never on a mask), `5` in MDC 15, and
`(ANY:ami) & (ami)` in MDC 5 (bare `ami` never matches a diagnosis attribute); all have DRG 0 and
reroute 0 and can never match. (b) GRC rows are stored with DRG 0 in the binary (999 in the file).
(c) binary-only `drgSeverity` (0/1/2/3/9 on 37 rows) and `grouperReturnCode` (never read by the
loader) are unused by the logic.

### 8.2 DXLIST (74 966 rows) + DXPATERN (788 rows) + DXATTLST (66 rows)

`DXLIST`: `CODE,CODEGENDER,EXCLUSIONGROUP,PATTERNNUMBER`. 74 878 distinct codes; 73 codes have two rows
(`CODEGENDER` 1 and 2) and 7 codes have three rows (HAC 11/12/13); all other codes one row with
`CODEGENDER 0`. `DXPATERN`: `PATTERNNUMBER,MDC,DXCAT,HACNUMBER,OPERAND` (`OPERAND` = `|`-separated,
may be empty; `MDC` 0–25; `DXCAT` 0–19; `HACNUMBER` 0–14). `DXATTLST`: `ID,OPERAND,DESCRIPTION`
(ID = historic bit number; all 66 operands are used; includes `CC`, `MCC`).
Derivation rules in §4.1. Equivalence with the binary (`Diagnosis{mdc, severity, operandsPatternNum,
hacOperandsPatternNum, dxCatListPatternNum}` + `HacInfo{hacOperands, hacNumbers}` + `CodeGenderMdc`):
severity, regular attributes, MDC, gender map, HAC numbers and exclusion lists agree for all codes;
dxcat agrees once the `DXCAT=0 → none` rule and the gender union are applied; HAC attributes agree once
`HACnn` is synthesised and — **binary-only information** — `hac06_show` is added for the 14 HAC-6 codes
without `hac06_sdx` (B3741, B3749, N10, N119, N12, N136, N151, N2884, N2885, N2886, N3000, N3001,
N340, N390). The 2 PDX-only `hac11_pdx` codes carry `hacNumbers=[11]` in the binary but `HACNUMBER=0`
in the file; this is irrelevant (no `HAC`-prefixed attribute ⇒ no `hacs`).

### 8.3 PRLIST (83 380 rows) + PRPATERN (1 042 rows) + PRATTLST (234 rows)

`PRLIST`: `CODE,PATTERNNUMBER` (codes include cluster ids `@nnnn`; no duplicates).
`PRPATERN`: `PATTERNNUMBER,OPERAND`. `PRATTLST`: `ID,OPERAND,DESCRIPTION`.
Equivalence: binary attributes = `OPERAND − {orindic, incluster}` for 83 329 codes; for 13 codes
(`02HA0QZ` etc.) the file has `orindic` without `d468`/`d477` and the binary has `ornec` instead
(§4.2). `orindic ⇔ d468 ∨ d477 ∨ ornec`; `nonor ⇔ ¬orindic`; `incluster ⇔` the code is a component of
some cluster in PRCLSTRS. Binary cluster ids carry a `Z` prefix (`Z@0217`); the prefix is an internal
naming choice (keeps cluster ids sorting after real codes) and can be ignored as long as the same id is
used consistently.

### 8.4 PRCLSTRS (8 271 rows)

`PROCCODE,CLUSTERCODE,CHOICE,NUMREQUIREDPROCS,MDCRESTRICTION`; 4 084 clusters; `CHOICE` 1–8;
`NUMREQUIREDPROCS` always equals the number of choice sets; 4 choice sets contain more than one
alternative code. `MDCRESTRICTION` ∈ {``, `F`, `ALL`, `nn`, `nn|F`, `nn|mm|F`, …} → bits per §4.3
(verified against the binary `ClusterData{suppressionMdcs, choices}` for all clusters).

### 8.5 EXCLUSN (172 853 rows)

`EXCLUSIONGROUP,CODE`; 2 340 groups (ids 2..2505; 0 and 1 absent). Binary `ExclusionGroup` +
`PdxExclusionGroup` agree exactly for all PDX.

### 8.6 MDCDSC (25 rows, no header, LRECL 80)

`nn,DESCRIPTION` — **not quoted**: split on the first comma only (descriptions contain commas, e.g.
`03,DISEASES & DISORDERS OF THE EAR, NOSE, MOUTH & THROAT`). Upper-case. Binary additionally has
MDC 0 `Pre-MDC` and 29 `Unrelated Operating Room Procedures (DRGs 981-989)`, mixed case.

### 8.7 DRGDSC3 (768 rows, no header)

`nnn,MDC xxY,DESCRIPTION` where `xx` = 2-digit MDC (blank for pre-MDC/998/999) and `Y` = `P`
(surgical/"procedure") or `M` (medical) or blank; quoted when the description contains commas.
Upper-case; equals the binary DRG descriptions case-insensitively for all 768 DRGs.

### 8.8 DRGDSC4 (1 034 rows, no header)

`nnnn,DESCRIPTION` (unquoted; split on the first comma) — 4-digit statistical DRG = base DRG × 10 + severity digit (1 MCC, 2 CC, 3 non-CC)
for each of the 344 base DRGs with 3 rows, plus `9980` and `9990`. Base-DRG descriptions used by the
Java (`getBaseDrgDescription`) exist **only in the binary** (346 entries, mixed case, without the
"with MCC" suffix); they cannot be reproduced exactly from the flat files.

### 8.9 TESTDB — §1.3.

### 8.10 HAC formulas and HAC descriptions — binary only (§6.1, §8.11).

### 8.11 Information present only in the binary

* HAC formulas (14, listed in §6.1) and HAC descriptions (14).
* `hac06_show` operand (reconstructible, §4.1).
* Base-DRG descriptions, MDC 0/29 descriptions, mixed-case descriptions.
* Inert placeholder DRGLOGIC rows, `drgSeverity`, version-range metadata (`Version` enum V390…V600,
  `ACCESS/Data.java:22-369`), build metadata (`runtime_buffers/msdrg_combined_metadata.txt`: built
  2026-08-25 from "Cerval" data).
* Ordering: the flat file row order **is** the rank order (verified), so nothing is lost.

---

## 9. Open questions / ambiguities

1. **Row 794 dead clauses** (`MISC/DRGLOGIC` line 661; `CORE/logic/ast/MsdrgNodeSupplier.java:96-104`): node resolution by token value only turns `PDX:incident`/`SDX:incident` into `ONLY:incident` tests. Whether CMS intends the literal reading is unknown; this spec mandates the Java behaviour.
2. **`hasAttribute` ignores dxcat/HAC lists** (`CORE/model/MsdrgDiagnosisCode.java:306-322`): the `else if (dxCatAttributes != null)` branch is unreachable. Any future SUPPRESSION operand or significant-trauma list named `dxc…`/`hac…` would silently not work. v44 data never relies on it.
3. **`UNKNOWN` hospital status branch** (`CORE/logic/MsdrgHacProcessor.java:245-304`): the POA counter condition `poa != Y || poa != W` is a tautology, making GRC 15 fire for any claim with ≥2 SDX and a met HAC. Reproduce as-is, but the intended behaviour is unclear.
4. **`dx.hasHacs()` inside the NON_EXEMPT check** (`MsdrgHacProcessor.java:222-230`) is evaluated before `hacsFlags` is populated and is therefore always false; GRC 9 is driven solely by `hasInvalidPoaOnClaim`.
5. **`CodeAccess.getHacsForCode`** (`MODEL/dao/CodeAccess.java:39-61`) indexes `hacNumbers.get(i)` for `i < distinctCount` and picks the operand by `contains(String.valueOf(hacNumber))` (e.g. "1" would match `HAC11`). Correct for v44 data (no duplicates, no HAC 1 with multi-digit operands) but fragile.
6. **Gender-code DXCAT union** (§4.1): the binary carries both sexes' `dxc…` attributes for 45 codes; whether a formula could ever observe the "wrong" sex's dxcat is data-dependent (none does in v44 since those codes group by their own MDC's rows).
7. **Cluster choice iteration order** (`MODEL/access/ClusterChoices.java:contains`, `HashMap` iteration) and the `break` after the first full match in `MsdrgClusters.java:107-131`: a code listed in two choice sets of the same cluster, or components appearing after the cluster is already satisfied, are handled in an order-dependent way. Not exercised by v44 data as far as checked (4 multi-code choice sets).
8. **Marking tie-breaks depend on `HashSet` iteration order** of `matchedAttributes` in `ProcedureMarking` (`ProcedureMarking.java:73`) and in the `TreeSet` listName-dedupe of `DiagnosisMarking` (`:46`). No v44 formula accumulates two attributes with the same name and different prefixes in one evaluation, so the outputs are deterministic in practice; an R implementation should iterate matched attributes in listName order.
9. **Terminal-node side effects on non-matching rows**: `FUSION`, `BILATERAL`, `STENT_4`, `VESSEL_4`, `SIG_TRAUMA`, `NOT_INCIDENT` flags may be set while evaluating rows that ultimately fail (short-circuit permitting). They are consumed only by marking of the matched DRG; the only cross-row leak is `FUSION` in `markAllFusionCodes` (MDC 8). Replicate the flag semantics literally.
10. **Severity of SDX equal to the PDX code**: such an SDX is excluded whenever the PDX's exclusion group lists the PDX itself (18 168 codes); whether this is intended is a CMS data question.
11. **POA character mapping for unrecognised characters**: `GfcPoa.fromChar(c)` defaults to `E`, while the mainframe wrapper defaults to `BLANK`; both are treated identically by the logic (invalid POA). The Java `MsdrgInputDxCode` takes the enum directly, so an R API should expose the enum.
12. **TESTDB reference values** are version-specific (§1.3); only 77 records exercise v44.0, and none of them exercises GRC 4/5/9/10/11/15, HAC 6, bilateral, fusion or stent counters.
13. **Lexer whitespace**: only ASCII space is a delimiter (`CommonTokenType.java:42`). Formulas with tabs/newlines would mis-lex; the v44 file contains none.
14. **`invalid_age` / `MDC_20_FALL_THRU` / `ANYDX` / `ORPROC` / `MULTFUSE` / `SGLANTSECTXCTR` / `SGLPOSTFUSECTR` / `PT:` prefix** are implemented but unused by v44 data; keep them available but untested.

---

## Appendix A — Enumerations (values needed for output)

| Enum (file) | Values |
|---|---|
| `MsdrgSeverity` (`MODEL/enumeration/MsdrgSeverity.java:7-10`) | `MCC(1,"MCC")`, `CC(2,"CC")`, `NON_CC(3,"NCC")`, `NONE(0,"")`; `from(string)` is case-insensitive |
| `MsdrgCodeSeverityFlag` (`…/MsdrgCodeSeverityFlag.java:7-14`) | `MCC(1,'M')`, `MCC_EXCLUDED_BY_DRG_LOGIC(2,'D')`, `CC_EXCLUDED_BY_DRG_LOGIC(3,'D')`, `CC(5,'C')`, `MCC_EXCLUDED(6,'E')`, `CC_EXCLUDED(7,'E')`, `NEITHER(0,'N')` |
| `MsdrgGroupingImpact` (`…/MsdrgGroupingImpact.java:7-10`) | `INITIAL(1)`, `FINAL(2)`, `BOTH(3)`, `NONE(0)` |
| `MsdrgHacUsage` (`…/MsdrgHacUsage.java:9-13`) | `NOT_ON_HAC_LIST(0)`, `HAC_CRITERIA_MET(1)`, `HAC_CRITERIA_NOT_MET(2)`, `HAC_NOT_APPLICABLE_EXCLUSION(3)`, `HAC_NOT_APPLICABLE_EXEMPT(4)` |
| `MsdrgProcedureHacUsage` (`…/MsdrgProcedureHacUsage.java:9-16`) | `HAC_NOT_USED(0,0)`, `HAC_08(1,8)`, `HAC_10(2,10)`, `HAC_11(3,11)`, `HAC_12(4,12)`, `HAC_13(5,13)`, `HAC_14(6,14)`, `BLANK(-1,-1)` |
| `MsdrgPoaErrorCode` (`…/MsdrgPoaErrorCode.java:7-12`) | `POA_NOT_CHECKED(0)`, `POA_NOT_RECOGNIZED(1)`, `POA_RECOGNIZED_NOT_POA(3)`, `POA_RECOGNIZED_YES_POA(4)`, `HOSPITAL_EXEMPT(5)`, `BLANK_DX_NOT_CONSIDERED(-1)` |
| `MsdrgHacStatus` (`…/MsdrgHacStatus.java:7-10`) | `NOT_APPLICABLE`, `FINAL_DRG_NO_CHANGE`, `FINAL_DRG_CHANGES`, `FINAL_DRG_UNGROUPABLE` |
| `MsdrgMedSurgType` (`…/MsdrgMedSurgType.java:8-10`) | `MEDICAL(1)`, `SURGICAL(2)`, `NONE(0)` |
| `MsdrgAdmitDxGrouperFlag` | `DX_INVALID`, `DX_VALID`, `DX_NOT_GIVEN` |
| `MsdrgHacCategory` (`CORE/enumeration/MsdrgHacCategory.java:7-22`) | 1 Foreign object, 2 Air embolism, 3 Blood incompatibility, 4 Pressure ulcers, 5 Falls/trauma, 6 Catheter UTI, 7 Vascular catheter infection, 8 Infection after CABG, 9 Poor glycemic control, 10 DVT/PE after knee/hip, 11 Infection after bariatric surgery, 12 Infection after spine/shoulder/elbow surgery, 13 SSI after CIED, 14 Iatrogenic pneumothorax w/ venous catheterisation |
| `MsdrgOperandType` (`CORE/enumeration/MsdrgOperandType.java`) | DX_LIST 1, PROC_LIST 2, DX_HAC 4, PROC_HAC 5, MDC 6, DX_SEVERITY 7, DX_CATEGORY 8 — documentation only, unused |

## Appendix B — Pseudocode of one grouping pass (R-oriented)

```
group_pass(claim, pass):                      # pass ∈ {initial, final}
  nonHac := if pass==final then SDX[!isHac] else SDX
  stops := [0]
  m := eval_mdc(0)                             # pre-MDC
  if m.grc != 0: return ungroupable(m.grc)     # both results, stop chain
  if m.empty:
      m := eval_mdc(PDX.mdc); stops += PDX.mdc
      if m.grc != 0: return ungroupable(m.grc)
      if m.empty: stop("no row matched")
  if m.reroute != 0:
      r := m.reroute; stops += r
      m := eval_mdc(r); if m.grc != 0: return ungroupable
      if m.reroute != 0: m := eval_mdc(m.reroute); if m.grc != 0: return ungroupable
      if m.empty: stop("no row matched")
  result := (drg=m.drg, base=m.base, medsurg=m.medsurg, severity=m.severity, mdc=report_mdc(stops))

eval_mdc(mdc):
  mask := build_mask()                         # §4.5
  for row in DRGLOGIC[MDC==mdc] in file order:
      sev := severity(nonHac, row.SUPPRESSION) # §5.3 (sets DOWNGRADE flags)
      if evaluate(row.FORMULA, mask + (NONE,sev), mdc): return match(row, sev, acc, grc)
  return empty
```
