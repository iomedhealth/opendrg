# DRG grouping in Spain — landscape (November 2026)

What software assigns DRGs in the Spanish National Health System (SNS), who supplies it, and
what that means for opendrg.

## 1. The classification: 3M/Solventum APR-GRD

* The national norm (*Norma Estatal RAE-CMBD*), the national weights and costs (*Pesos y
  Costes hospitalarios del SNS*) and the ambulatory costs are all expressed in **APR-GRD**
  (All Patient Refined DRGs, 3M — now Solventum). Until 2015 the norm used **AP-GRD** v25 on
  CIE-9-MC; the move to CIE-10-ES in 2016 forced the switch to APR because 3M never released an
  AP-GRD for ICD-10 (the 2019 weights report says so explicitly).
* Versions track the CIE-10-ES edition, which in turn is a translation of US ICD-10-CM/PCS
  (Ministry's 2025 methodological note, table reproduced):

  | Data year | CIE-10-ES edition | = ICD-10-CM/PCS | APR-GRD |
  |---|---|---|---|
  | 2016, 2017 | 1st | FY2016 | 32.0 |
  | 2018, 2019 | 2nd | FY2017 | 35.0 |
  | 2020, 2021 | 3rd | FY2018–2019 | 36.0 |
  | 2022, 2023 | 4th | FY2020–2021 | 38.0 |
  | 2024– | 5th (Jan 2024) | FY2022–2023 addenda | 40.0 |

* Outputs per episode in the national register: APR-GRD, CDM (MDC), type (medical/surgical),
  severity level 1–4, mortality-risk level 1–4, plus the Spanish weight and cost for the
  GRD × severity. The Ministry's data-request annex states the GRD fields are computed "bajo
  licencia comercial 3M™ CGS (Core Grouping Software)".
* The APR-GRD logic (definitions manual, grouper) is **proprietary and not published**; it is
  licensed as a binary/API (CGS) — unlike CMS's MS-DRG flat files or NHS England's workbooks.

## 2. Who runs it

* **Ministerio de Sanidad** groups the RAE-CMBD centrally: contract 202505PAO005 "Suministro de
  derechos de uso del Software de agrupación de pacientes en GRD", €223k, awarded June 2025 to
  *Sistemas de Gestión Sanitaria S.A.* (SIGESA) — 2 bids. Its technical specification (PPT,
  signed Feb 2025; copy in `target/Spain/`) is explicit: three years of use and updates of
  **3M Core Grouping Software** licences for **GRD APR** (multi-user, >100 hospitals) and
  **GRD IR** (*International Refined* DRGs, single-user, >100 hospitals, "also used by the
  Ministry for compatibility with previous years' data"; IR has severity/mortality levels
  0–3). Required functions: Windows Server install; a structure editor to map the official
  CMBD layout; interactive one-record grouping; **batch mode** (one input file → one output
  file with CDM, GRD, grouper return codes and code-validation flags, from a Windows UI or the
  command line); a scheduler keyed on date range, code-set version, grouper version and a
  statistics file (weights, mean stay, lower/upper trim points); a code-mapping module to group
  codes of one period with the GRD version of another; and compatibility with the existing CGS
  integrations into the Ministry's SIFCO and RAE-CMBD systems. The IR-GRD fields (`GRD-IR`,
  `Tipo GDR IR`, `Tipo PROCESO IR`) appear in the RAE-CMBD annex for ambulatory contacts.
* **SIGESA** (Madrid SME, est. 1993) is the Spanish distributor of the 3M/Solventum HIS groupers
  and sells its own analytics front-ends on top of them: Decisys-APR, Alcor.GRD → ENARA
  (ENARA APR, ENARA CAL, ENARA Urgencias), Alcor POB (3M CRG, population risk), TeamCoder
  (coding assistant). Public awards in the last three years: 41 contracts, ~€5.65M, 26 public
  bodies (LiciRadar). Regional examples: Osakidetza (CGS licences, €322k), Madrid SERMAS (GRD
  grouping + casemix analytics, two lots), Castilla-La Mancha SESCAM (€457k), Castilla y León
  (€416k), Valencia (CGS **AP, APR and MS** licences, €326k, plus ENARA), Murcia, Aragón,
  Navarra (Decisys CGS-APR), Asturias, Extremadura, Canarias, Cantabria, Andalucía (per-hospital
  minor contracts), INGESA Ceuta/Melilla (APR-GRD lease, €19.8k for two hospitals), CatSalut
  (3M CRG licence, €187k).
* Catalonia's SISCAT hospitals and CatSalut's payment system also use APR-GRD.
* The other analytics player is IQVIA (formerly Iasist; *Hospitales TOP 20* benchmarking), also
  on 3M APR-DRG licences.

Workflow everywhere is the classic one: extract the CMBD file → run the licensed grouper
(desktop/server) → load the GRD fields back.

## 3. Cross-check against the Solventum *APR DRG Methodology Overview* (v43.0, Oct 2025)

Source: `target/Solventum GRD/grp041_aprdrg_methodology_overview.pdf` (GRP-041). What it
confirms, and where the Spanish deployment differs from the document.

**Confirmed**

* Three outputs per stay — base APR DRG, severity-of-illness subclass 1–4, risk-of-mortality
  subclass 1–4 — exactly the `GRD APR`, `Nivel Severidad`, `Riesgo Mortalidad` fields of the
  RAE-CMBD; 25 MDCs plus pre-MDC (Spain codes it `CDM 0`, "Categoría no válida/Pre-CDM");
  medical/surgical type; 955 = principal diagnosis invalid as discharge diagnosis, 956 =
  ungroupable (both present in the Spanish tables with a single severity level 0 and weight 1).
  Medical/surgical type and MDC agree for every DRG common to both catalogues.
* Spain's *GRD basal* = the base APR DRG; the Spanish weights are published per base DRG and
  per DRG × severity (1,328 rows for 2024), as the methodology prescribes ("the APR DRG in
  conjunction with severity of illness subclass is used for resource use").
* The document is an overview, not a specification: it names the 18 SOI steps, 18 ROM steps,
  the 229 secondary-diagnosis categories and the 15 rerouting types, but none of the code
  lists, levels or DRG-specific modifications. Its licence notice forbids reproduction,
  reverse engineering and derivative works. This settles §4.1 below: the logic is not public.

**Where Spain differs from the document**

* *Version.* The document describes v43.0 (October 2025); the Spanish 2024 norm, weights and
  costs are **v40.0** (`Pesos_Costes_hosp_SNS_GRD_APR_2024.xlsx`, sheets `Basal_2024_v40`,
  `Niveles_Severidad_2024_v40`). Three steps the document marks as retired are still live in
  v40: SOI/ROM Phase I steps 4 (DRG 190 + principal diagnosis) and 6 (non-OR procedures),
  retired in v42.0, and SOI step 16 (DRG + PDX + non-OR procedure), retired in v43.0. The age
  rule of step 3 (0 days–17 years, since v37.0) does apply to v40.
* *Catalogue.* Spain's v40 tables list 335 base DRGs; the v43 list has 337. Nine v40 DRGs no
  longer exist in v43 (56, 57 head trauma coma < 1 h split; 232 fundoplication; 480 major male
  pelvic procedures; 510, 512 radical gynaecologic procedures; 754 depression except major;
  892, 893 HIV) and eleven v43 DRGs do not exist in v40 (60; 299, 300 combined
  anterior/posterior spinal fusion; 428 genetic disorders; 448 percutaneous kidney procedures;
  485 prostatectomy; 761 schizoaffective; 762 obsessive-compulsive; 851 gender-related
  procedures; 864 hospice and palliative care; 891 HIV). v40 already has DRG 11 (CAR-T), new
  to Spain in the 2024 tables, and 770 (left against medical advice) — both without Spanish
  cost data yet. Five DRGs have fewer than four severity rows in the Spanish tables (95, 588,
  841, 910, 911), i.e. the cost estimation dropped empty cells, not the classification.
* *Admission APR DRG (Chapter 3) is not produced.* The RAE-CMBD carries a POA flag for the
  principal and every secondary diagnosis (`POAD1`, `POAD2–POAD20`: S/N/D/I), so the seven-step
  admission DRG would be possible for diagnoses, but the register records only **one procedure
  date** (`FECINT`, the main procedure) rather than a date or day-offset per procedure, which
  step 7 needs. The Ministry publishes only the discharge DRG, severity and mortality risk.
* *Fields the logic expects that Spain does not record.* No birth-weight or gestational-age
  field: the neonatal MDC 15 DRGs (birth-weight bands, "gestational age < 24 wks") must be
  driven by the ICD-10-CM `P07.0-`/`P07.1-`/`P07.2-` codes alone. Discharge status is the Spanish
  `Tipo Alta` (1 home, 2 transfer to another hospital, 3 voluntary discharge, 4 death, …) and
  sex is 1/2/3 indeterminate/9 unknown — the CGS deployment maps these to the US values the
  logic reads (died vs alive for AMI, "left against medical advice" for DRG 770, transfers for
  neonatal 580/581, sex for MDC 12–14; invalid values → 956).
* *Coding lag.* The document's v43 expects FY2026 ICD-10-CM/PCS; Spain's CIE-10-ES 5th edition
  is FY2022–2023 and is grouped with v40, keeping grouper and code set in step (the Ministry's
  version table in §1). Codes created after FY2023 cannot appear in Spanish data.

## 4. Implications for opendrg

1. **The official Spanish grouper cannot be re-implemented from published data.** APR-GRD logic
   is a trade secret; there is no equivalent of DRGLOGIC or the Code to Group workbook. The
   methodology overview (§3) describes the shape of the algorithm — 18 + 18 steps, 229
   secondary-diagnosis categories, 15 rerouting types — but not one code list, and its licence
   forbids derivative works. An open APR-GRD would mean a licence agreement with Solventum;
   reverse engineering a licensed binary is excluded by that licence and does not fit the
   "published logic tables + engine" model either.
2. **Spanish data is natively MS-DRG-groupable.** CIE-10-ES *is* ICD-10-CM/PCS (5th edition =
   FY2022–2023 codes). RAE-CMBD / CMBD extracts and Spanish OMOP sites can therefore run
   opendrg's MS-DRG engine directly (watch the version lag: codes deleted after FY2023 are rare
   but will be flagged invalid by v43/v44; an older bundled version would track CIE-10-ES more
   closely). MS-DRG is not the payment classification in Spain, but it is a legitimate, open,
   verifiable casemix family — and at least Valencia licenses MS-DRG alongside AP/APR.
3. Spain publishes **weights and costs per APR-GRD × severity** as open data (Portal
   Estadístico), but they are only usable with APR-GRD assignments, i.e. with a licence.
4. If an "official" Spanish casemix is required inside an OMOP federation, the realistic
   options are: ask the site to attach the GRD fields already present in its CMBD (every SNS
   hospital receives them), or wrap the site's licensed 3M CGS batch interface (the PPT shows it
   is file-in/file-out, UI or command line) — not an opendrg deliverable.
5. An MS-DRG run on Spanish data needs a small input adapter — now `cmbd_to_msdrg()` in
   `R/cmbd.R`: `TIPALT` → UB-04 discharge status (1 → 01, 2 → 02, 3 → 07, 4 → 20, 5 → 03,
   8 → 01, 9 → missing), `SEXO` 3/9 → unknown, age from `EDAD` or `FECNAC` and the contact start
   date (the register's ddmmyyyy / ddmmyy / ISO formats), `POAD*` S/N/D/I/E → Y/N/U/W/1,
   `PROCEXT*` optional. The same mapping is what the CGS deployment does internally for APR.

## 5. What a "CMBD" looks like in practice

Two different artefacts go by the name.

**Hospital CMBD reports (published).** Every SNS hospital's annual *memoria* carries a
"Casuística (CMBD)" / "Indicadores de gestión CMBD" section produced from its own grouped
CMBD. Example, Hospital Universitario Virgen Macarena (Sevilla), *Memoria 2023* §3.1.7: 33,703
discharges, adjusted mean stay (EMAF) 7.59 days, IEMA 0.95, mean weight 1.0439, 1,917 deaths,
then "APR GRD más frecuentes" — `560 Parto` 1,515 cases, EM 2.44, EMAf 2.56, IEMA 0.95, weight
0.3128; `194 Insuficiencia cardiaca` 951, 7.91, 8.77, 0.90, 0.793; `139 Otra neumonía` 873 …;
plus the same table per clinical service (cardiology: `174 Intervenciones cardiacas percutáneas
con IAM` 413 cases, weight 1.9541, 45 outliers). Madrid's hospitals use a common template
(*Memoria 2023*, e.g. Ramón y Cajal p. 45 "Casuística (CMBD)", top-25 medical and surgical
GRDs with episodes, %, EM and weight, sourced "CMBD APR GRD 38"). The Ministry's counterpart is
*RAE-CMBD: Actividad y resultados de la hospitalización en el SNS* (annual). These reports are
the *output* of the licensed grouper, never the records.

**The per-episode CMBD file (not published).** Microdata are released only on request
(Ministry form, ~1 month, selected variables; regions likewise). The file hospitals actually
send is specified by each region's procedure manual on top of RD 69/2015: Castilla y León
(public and private layouts, RD names `FECNAC`, `SEXO`, `FECINICONT`, `TIPCONT`, `TIPALT`,
`D1`–`D20`, `POAD1`–`20`, `PROC1`–`20`, `PROCEXT1`–`6`); Andalucía (pipe-delimited `.TXT`
named `HOS<hospital>04<yy>.TXT`, codes written with the dot — `I21.4`, `0016071` — and,
beyond the national model, a **date-time, urgent/scheduled flag and external-centre flag per
procedure** (`FECP1`–`FECP20`), which would make the admission APR DRG of §3 computable there).
`cmbd_to_msdrg()` accepts these layouts; `tests/testthat/test-cmbd.R` holds a four-record
synthetic file in the RD 69/2015 layout.

**The bundled synthetic extract.** `inst/extdata/cmbd/rae-cmbd-synthetic.txt` (read with
`cmbd_read(cmbd_example())`) is a month of discharges of a fictional hospital in the 96-field
RD 69/2015 exchange order (`TIP_CIP` .. `CCAA`, `D`/`POAD` interleaved as in the CyL
public-centre file; pipe-delimited with a header line, since no national physical format is
specified and Andalucía's manual uses `|`): 1,000 contacts, 897 hospitalisations, 12 home
hospitalisation, 32 day-hospital sessions and 59 ambulatory surgeries; discharges 1–31 May
2024 with weekday seasonality, urgent 79%, mean stay 5.9 days, in-hospital mortality 4.3%,
ICU 5.0%, 4.9 diagnoses per hospitalisation, 51% with a procedure, 17 patients with more than
one contact (readmissions, chemotherapy courses). It is generated by
`data-raw/cmbd-synthetic.R` from ~80 clinical profiles (seeded, deterministic) whose weights
follow the national RAE-CMBD casemix and the hospital reports above; every code is checked
against the FY2023 ICD-10-CM/PCS lists (= CIE-10-ES 2024) and the v44.0 tables, POA uses the
register's `S/N/E` (hospital-acquired conditions drawn with `N`, exempt categories with `E`),
`FECINGHOSP` is set only for admissions through urgencias, `FECINT` falls within the stay,
`UCI`/`DIAS_UCI` only for hospitalisations, `M1` carries ICD-O-3 morphology for neoplasms. With
`poa_exempt = "non_exempt"` (Spanish hospitals report POA for every diagnosis) all 897
hospitalisations group with return code 0 into 157 MS-DRGs (top: 795, 807, 690, 470, 203) and
the HAC rules bite where expected (a hospital-acquired stage-3 pressure ulcer, `L89.153` POA
`N`, drops a hip-fracture repair from DRG 480 to 481); with the CMS default `"unknown"` those
records come back with return code 15, as in CMS's software. Grouping it is the README's worked
example for Spain.

## 6. Sources

* Ministerio de Sanidad, *Costes hospitalarios – Contabilidad analítica*:
  https://www.sanidad.gob.es/estadEstudios/estadisticas/inforRecopilaciones/anaDesarrolloGDR.htm
* *Nota metodológica de Costes 2024*; *Norma Estatal RAE-CMBD 2023 – nota informativa* (March
  2025); *Estimación de pesos y costes de los procesos hospitalarios en el SNS, proyecto 2019*.
* RAE-CMBD data-request annex (2018): "Bajo licencia comercial 3M™ CGS (Core Grouping Software)".
* CIE-10-ES 5.ª edición, Tomo I, introduction (translation of ICD-10-CM, FY2022/2023 addenda).
* BOE-B-2023-29303 (INGESA, 3M APR-GRD licences, awarded to Sistemas de Gestión Sanitaria S.A.).
* Ministry tender 202505PAO005: *Pliego de Prescripciones Técnicas* and *Pliego de Cláusulas
  Administrativas* (Plataforma de Contratación del Sector Público; copies in `target/Spain/`).
* Solventum, *APR DRG Methodology Overview*, software version 43.0, GRP-041 (Sept 2025).
* Ministerio de Sanidad, *Pesos y Costes hospitalarios SNS GRD APR 2024* (xlsx, v40).
* Hospital Universitario Virgen Macarena, *Memoria 2023* (hospitalmacarena.es); Comunidad de
  Madrid hospital *Memorias 2023* (Ramón y Cajal, Gregorio Marañón, Clínico San Carlos, …).
* SAS, *Manual de Instrucciones del CMBD de Andalucía 2021*; SACYL, *Manual Procedimiento CMBD
  CyL (adaptación RAE-CMBD)* 2020; Ministerio de Sanidad, *FAQ solicitud de microdatos
  RAE-CMBD/CMBD* (Nov 2026). Copies in `target/Spain/`.
* Plataforma de Contratación del Sector Público via LiciRadar: SIGESA award history and
  Ministry tender 202505PAO005.
* SIGESA product pages (Solventum APR-GRD, ENARA, Alcor POB/CRG); IOC/Generalitat training
  material on GRD-APR use in SISCAT.
