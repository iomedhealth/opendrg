# OMOP CDM readiness for casemix grouping — live site check (November 2026)

Profile of a production IOMED OMOP CDM (v5.4, PostgreSQL; a Spanish urology–nephrology
hospital, 458k persons, 222k inpatient stays 1984–2026) against what the MS-DRG engine needs,
followed by an end-to-end trial (`dev/omop-site-trial.R`). Read-only; aggregates only. This
is the reference for the `omop_to_msdrg()` design (issue #1).

## 1. What the CDM holds

| Input | Finding | Verdict |
|---|---|---|
| Diagnoses | `condition_source_concept_id` in **ICD10CM** on 2.0M of 5.8M rows; EHR-typed (32817) 4.2M, NLP (32858) 1.5M. **90 % of inpatient stays** have ≥ 1 ICD-10-CM EHR diagnosis; median 3 (2023+: median 5). Local catalogue ids in `condition_source_value`; codes present back to 1984 (local catalogue mapped to ICD-10-CM, not CIE-9 era coding) | Good — source codes are there |
| Principal diagnosis | `condition_status_concept_id` 0/NULL on every row; no order within a stay (hash ids, identical dates), duplicates (same code ×3) | **Absent** |
| POA | none | Absent (use `poa_exempt = "exempt"`) |
| Procedures | 3.8M rows; `procedure_concept_id` = 0 on 3.6M (local catalogue, numeric ids); ICD10PCS standard concepts on 56k rows, ICD9Proc 63k, SNOMED 84k. Since 2018: 86 % of stays have EHR procedures, **84 % have unmapped ones**; only 2.7 % of all stays (6 % of 2023+) carry ICD-10-PCS | **Main gap** — surgical DRGs unreachable until the local procedure catalogue is mapped |
| Discharge | `discharged_to_concept_id` 0 on 99 %; `discharged_to_source_value` carries a **site-specific list** (1 = home 165k; 2 = transfer 2.4k; 3 = voluntary 0.5k; **5 = exitus** 1.5k, not the national CMBD's 4; blank on 52k stays since 2010). `death` table: 354 deaths within stays (incomplete vs code 5) | Usable with a per-site map + death table; cannot assume national `TIPALT` |
| Admission | `admitted_from_source_value`: HOSP 199k, URG 21k, AMB 1k | Usable (needed for HRG only) |
| Demographics | `birth_datetime`, `year/month/day_of_birth` complete; gender 8507/8532, 46 unknown | Complete |
| Episodes | `visit_detail` on 99.5 % of stays, ~42 per stay (ward/bed moves, not consultant episodes); provider specialty on 63 % of 2018+ stays (Oncology, Urology, Transplant, Paediatric urology) | Fine for MS-DRG (unused); HRG episodes would need a rule |
| Access | reader role sees `cdm`, `vocabularies`, `nlp`, `ohdsi_results` only; raw hospital schemas closed, so the principal flag / CMBD cannot be recovered from staging | Adapter must work from `cdm` alone |

Vocabulary: ICD10CM FY2026, ICD10PCS 2026, SNOMED 2025-02 — ahead of the CIE-10-ES edition
the hospital codes with, so no "code newer than grouper" problem with MS-DRG v44.

## 2. End-to-end trial (3,000 random stays from 2023+, MS-DRG v44.0)

Every ICD-10-CM coded diagnosis of a stay was taken in turn as the principal (15,168
candidate claims, grouped in 27 s ≈ 550 claims/s).

* Return codes: 97.8 % grouped; 0.9 % RC 1 (external-cause code `Y83.6` as principal);
  1.4 % RC 7 — **category-level codes** (`N18`, `G20`, `I42.0`, `N17`, `R31`) that the local
  catalogue maps to non-billable ICD-10-CM headers.
* **The DRG is undetermined without the principal diagnosis**: only 10.8 % of stays get the
  same DRG whichever coded diagnosis is principal (same MDC: 12.8 %); on average 37 % of a
  stay's candidates agree with its modal DRG; the typical stay spans 3 MDCs. Taking the modal
  DRG makes "Hypertension without MCC" the commonest group (comorbidity `I10` is on most
  stays) — i.e. plainly wrong for a urology hospital.
* Surgical DRG reachable for 2.6 % of stays (the procedure gap).
* Severity does track LOS even in this setting (median LOS: no CC 2 d, CC 3 d, MCC 5 d).

## 3. Consequences for the adapter

1. Source-code path first (`condition_source_concept_id` ∈ ICD10CM) — it is what this site
   has; the SNOMED reverse-mapping path stays as the fallback for extracts without it.
2. A principal-diagnosis strategy is mandatory and must be explicit: `codelist` (the study's
   index condition) for cohort studies; `all` to report the candidate spread as a sensitivity
   analysis; `none` to mark the stay not groupable. No silent heuristic.
3. Procedures: use ICD10PCS standard/source concepts when present; report the share of stays
   with unmapped procedures as a quality flag. The structural fix is mapping the local
   procedure catalogue (the top 15 local codes cover a large share of inpatient rows).
4. Discharge: `death` table ∪ per-site map of `discharged_to_source_value`; the map is a
   parameter, with the national CMBD list as a documented default only.
5. Age from `birth_datetime` when present, else `year_of_birth`.
6. Validate principal candidates against the grouper's code table and report category-level
   codes separately from genuinely invalid ones.

## 4. ETL requests that would make the output official-grade

* `condition_status_concept_id` = 32902 (primary) / 32908 (secondary) from the hospital's
  CMBD / discharge report.
* Map the local procedure catalogue to ICD-10-PCS (or SNOMED with PCS descendants).
* `discharged_to_concept_id` from the site list, with the list documented in the ETL reference.
* Keep `condition_source_concept_id` at the billable (full-length) ICD-10-CM code.

## 5. Hot-patched 2024 proof-of-concept & APR-GRD concordance (`dev/omop-hot-etl-trial.R`)

Read-only inspection of the hospital's `raw` schema confirmed that all missing fields already
exist upstream and were dropped during ETL:

* `raw.cod_codifepi` carries `tipo_diag` (`P` / `S`) on 100 % of rows (4.27M rows) and `orden = 1`
  on 99.97 % of episodes, plus `dpi` (Spanish RAE-CMBD POA `S/N/D/I/E`).
* `raw.cod_diccionario` (`catalogo = 10`, `seccion = 'P'`) carries 7-character CIE-10-ES /
  ICD-10-PCS codes across 85.1 % of 2024 stays (9,659 / 10,375 procedure rows = 93.1 % valid PCS).
  Crucially, `codigo_1` holds hospital-local sub-extensions on 19.4 % of primary diagnoses
  (`C67.9XXX.0`, `N20.0XXX.1`) and ~11 % of procedures, while **`codigo_2`** holds the clean
  official CIE-10-ES code; using `COALESCE(NULLIF(TRIM(codigo_2), ''), TRIM(codigo_1))` removes
  almost all invalid codes.
* `raw.adm_destinoalta` supplies the exact site discharge list (`1` Domicilio, `2` Traslado,
  `3` Alta voluntaria, `4` Alta in extremis, `5` Paciente Exitus, `6` Fuga, `7` H2M).

Patching the 2024 OMOP tables in memory (read-only) and running `omop_msdrg(..., principal = "status")`
with MS-DRG v44.0 (zero heuristics, 11.8 s):

* **Grouped cleanly (RC 0)**: **5,114 / 5,126 stays (99.8 %)** (up from 0.0 %); only 11 uncoded
  stays and 1 retired code (`I20.8`).
* **Surgical DRG share**: **57.0 %** (2,915 surgical / 2,199 medical, up from 2.7 % under codelist).
  Top DRGs: 661 (kidney/ureter non-neoplasm w/o CC/MCC, 429), 670 (transurethral w/o CC/MCC, 266),
  699 (other kidney/urinary dx w/ CC, 265), 660 (kidney/ureter w/ CC, 241), 714/713 (TURP, 325).
* **Concordance with official hospital APR-GRD (`raw.fac_epihosp`, n = 3,381 matched Jan–Aug 2024 stays)**:
  official APR-GRD weight (`num_pesogrd`) increases monotonically across every `med_surg × severity`
  cell — Medical NCC 0.463 / CC 0.580 / MCC 0.835; Surgical NCC 0.922 / CC 1.188 / MCC 2.173
  (median LOS 2 / 3 / 4 d medical; 2 / 3 / 7 d surgical). `opendrg` MS-DRG explains
  **$R^2 = 0.624$** of $\log(\text{APR weight})$ and **$R^2 = 0.338$** of $\log(\text{LOS} + 1)$
  (vs. **$0.290$** for the hospital's own APR-GRD `cod_grd`).
