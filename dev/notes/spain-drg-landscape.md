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
  *Sistemas de Gestión Sanitaria S.A.* (SIGESA) — 2 bids.
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

## 3. Implications for opendrg

1. **The official Spanish grouper cannot be re-implemented from published data.** APR-GRD logic
   is a trade secret; there is no equivalent of DRGLOGIC or the Code to Group workbook. An
   open APR-GRD would mean either a licence agreement with Solventum or reverse engineering a
   licensed binary — neither fits the "published logic tables + engine" model.
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
   hospital receives them), or wrap the site's licensed 3M CGS API — not an opendrg deliverable.

## Sources

* Ministerio de Sanidad, *Costes hospitalarios – Contabilidad analítica*:
  https://www.sanidad.gob.es/estadEstudios/estadisticas/inforRecopilaciones/anaDesarrolloGDR.htm
* *Nota metodológica de Costes 2024*; *Norma Estatal RAE-CMBD 2023 – nota informativa* (March
  2025); *Estimación de pesos y costes de los procesos hospitalarios en el SNS, proyecto 2019*.
* RAE-CMBD data-request annex (2018): "Bajo licencia comercial 3M™ CGS (Core Grouping Software)".
* CIE-10-ES 5.ª edición, Tomo I, introduction (translation of ICD-10-CM, FY2022/2023 addenda).
* BOE-B-2023-29303 (INGESA, 3M APR-GRD licences, awarded to Sistemas de Gestión Sanitaria S.A.).
* Plataforma de Contratación del Sector Público via LiciRadar: SIGESA award history and
  Ministry tender 202505PAO005.
* SIGESA product pages (Solventum APR-GRD, ENARA, Alcor POB/CRG); IOC/Generalitat training
  material on GRD-APR use in SISCAT.
