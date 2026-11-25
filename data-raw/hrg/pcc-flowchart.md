# Paediatric Critical Care (XB) grouping flowchart — HRG4+ 2024/25 National Costs Grouper

Source: Chapter Summaries v1.0, Subchapter XB, flowchart on pp. 175-180 and list `XB_ISOLATION`
on pp. 181-185. This logic is **not** in the Code To Group workbook; it is transcribed here in the
exact form evaluated by the verified prototype (250/250 `PCC_HRG` in the official test data).
Node numbers are the numbers printed on the flowchart.

## Inputs used

* `CCUF` — critical care unit function of the day (`4` is accepted as `04`).
* `CCAC_01..CCAC_20` — the set of Critical Care Activity Codes recorded for the day. Single-digit
  values are zero-padded (`1` → `01`) before comparison. "has(x, y, …)" below means *at least one of
  the listed codes is present in the day's set*; "has(a) and has(b)" means both are present.
* `OPER_01..OPER_20` — high-cost-drug OPCS-4 codes of the day (only `X841`, `X842` matter).
* `DIAG_01..DIAG_nn` — ICD-10 codes of the day, normalised (no dot). "diag(…)" = at least one of the
  listed codes is present in **any** diagnosis position.
* History within the critical-care period (steps 25-27) — see "Per-period history" below.

Definitions reused by several nodes:

| Name | Definition |
|---|---|
| `VENT` | has(`51`, `52`, `56`) — invasive ventilation via ET tube, via tracheostomy, or advanced (jet/oscillatory) ventilation |
| `ISOL` | has(`74`) **and** at least one diagnosis (any position) is on the `XB_Isolation` list (`pcc-isolation-list.csv`) |
| `BURN80` | diag(`T318`, `T319`, `T328`, `T329`) — burns/corrosions ≥ 80 % TBSA |
| `BURN50` | diag(`T315`, `T316`, `T317`, `T325`, `T326`, `T327`) — 50-79 % |
| `BURN20` | diag(`T312`, `T313`, `T314`, `T322`, `T323`, `T324`) — 20-49 % |
| `BURN20PLUS` | `BURN20` or `BURN50` or `BURN80` (i.e. `T312`-`T319`, `T322`-`T329`) |
| `GASDRUG` | any `OPER_nn` ∈ {`X841`, `X842`} (medical gases band 1, pulmonary surfactant band 1) |
| `AKI` | diag(`N170`, `N171`, `N172`, `N178`, `N179`, `N990`) |

## Steps (evaluated strictly in this order; the first satisfied step decides)

| Node | Condition | Result |
|---|---|---|
| 1 | `CCUF` not in {`04`, `16`, `17`, `18`, `19`, `92`} | `UZ01Z` ("not a period of paediatric critical care"; reported as `CCUF … is invalid`/`is blank`) |
| 2 | has(`65`) **and** has(`05`, `16`, `51`, `52`, `56`, `66`) | `XB01Z` |
| 3 | `VENT` and `BURN80` | `XB02Z` |
| 4 | `VENT` and has(`63`) | `XB02Z` |
| 5 | `VENT` and `BURN50` | → node 8 |
| 6 | `VENT` and `GASDRUG` | → node 8 |
| 7 | `VENT` and has(`04`, `05`, `16`, `66`, `67`, `72`) | → node 8 |
| 8 | `ISOL` ? | yes `XB02Z` / no `XB03Z` |
| 9 | has(`51`, `52`) and `BURN20` | → node 10 |
| 10 | `ISOL` ? | yes `XB03Z` / no `XB04Z` |
| 11 | has(`51`, `52`) and has(`06`, `64`, `68`, `71`) | → node 13 |
| 12 | has(`56`) | → node 13 |
| 13 | `ISOL` ? | yes `XB03Z` / no `XB04Z` |
| 14 | has(`51`) | → node 17 **(reading of the garbled page: the "Yes" arrow of node 14 joins node 15's "Yes" path into node 17; verified by test rows 10, 30, 33, 38, 53, 69, 197, 199, 229 which expect `XB05Z`, not `XB04Z`)** |
| 15 | has(`52`) and has(`60`, `62`, `85`, `96`) | → node 17 |
| 16 | has(`53`) and has(`04`, `05`, `06`, `16`, `60`, `62`, `63`, `64`, `66`, `67`, `68`, `71`, `72`, `85`, `96`) | → node 17 |
| 17 | `ISOL` ? | yes `XB04Z` / no `XB05Z` |
| 18 | has(`53`) and `GASDRUG` | → node 21 |
| 19 | has(`53`) and `BURN20PLUS` | → node 21 |
| 20 | has(`65`) and has(`06`, `53`) | → node 21 |
| 21 | `ISOL` ? | yes `XB04Z` / no `XB05Z` |
| 22 | has(`65`) | `XB06Z` |
| 23 | has(`04`, `06`, `55`, `60`, `61`, `62`, `63`, `64`, `67`, `69`, `71`, `72`, `85`, `97`) | `XB06Z` |
| 24 | has(`05`, `16`, `66`) and `AKI` | `XB06Z` |
| 25 | has(`13`) and `prev13 < 8` | `XB06Z` |
| 26 | has(`52`) and `run52 < 91` | `XB06Z` |
| 27 | has(`53`) and `run53 < 91` | `XB06Z` |
| 28 | has(`52`, `53`, `57`, `58`, `59`, `70`, `94`, `95`) | `XB07Z` |
| 29 | has(`09`, `80`) **and** has(`50`) **and** has(`73`) | `XB07Z` |
| — | otherwise | `XB09Z` (Paediatric Critical Care, General Care) |

Notes

* Field validation errors (see `dataset-io.md`) make the day `UZ01Z` regardless of the flowchart.
* The transport HRG `XB08Z` is not produced here; it comes from the APC dataset (`TRETSPEF 242`
  + `XB_paedtrans`).
* `XB_Isolation` is only published in the PDF. Three entries are code pairs that must **both** be
  present (`Z944+Z940`, `Z944+Z948`, `A400+M726*`, where `M726*` means any fifth-character code
  `M7260`…`M7269`, per the footnote "* Fifth character code"). The isolation branch was **not
  exercised** by the official test data (the five test days with `CCAC 74` plus an isolation
  diagnosis all resolve before reaching an `ISOL` node), so this list and the pair matching are
  transcribed but unverified.
* Test-data coverage of the nodes (250 days): 1:6, 2:3, 4:1, 5:1, 6:2, 7:8, 9:1, 11:148, 14:10,
  15:2, 16:4, 23:14, 25:3, 26:4, 27:8, 28:4, 29:16, else:15. Nodes 3, 12, 18-22, 24 and every
  `ISOL` branch are unexercised.

## Per-period history and evaluation order (pseudo-code)

```
# 1. sort: stable sort by PROCODET, CCLocalID, CCDate (all compared as text; a blank CCLocalID
#    sorts first, i.e. as the empty string). RowNo = position after sorting.
#    (verified: reproduces the official _sort.csv for PCC and NCC)
# 2. iterate the sorted rows; keep per-period state keyed by (PROCODET, CCLocalID):
#       prev13 : number of earlier days in the period that had CCAC 13
#       run52  : number of immediately preceding consecutive days that had CCAC 52 AND were
#                grouped to XB06Z (reset to 0 by any day without 52 or not grouped XB06Z)
#       run53  : same for CCAC 53
state <- {}
for row in sorted_rows:
    key <- (row.PROCODET, row.CCLocalID)
    st  <- state[key] or {prev13 = 0, run52 = 0, run53 = 0}
    codes <- zero_padded(non-blank CCAC_01..20)
    hrg <- first satisfied node of the table above, using st.prev13 / st.run52 / st.run53
           for nodes 25-27
    if row has validation errors: hrg <- "UZ01Z"
    # update history AFTER grouping the day
    if "13" in codes: st.prev13 <- st.prev13 + 1
    st.run52 <- if ("52" in codes and hrg == "XB06Z") st.run52 + 1 else 0
    st.run53 <- if ("53" in codes and hrg == "XB06Z") st.run53 + 1 else 0
    state[key] <- st
```

Caveat: the User Manual (p. 68) says a new critical-care period starts when the child moves to a
unit with a different `CCUF`. The prototype keys the history by `(PROCODET, CCLocalID)` only and
does not reset it on a `CCUF` change; the thresholds (8 days, 91 days) are never approached in the
test data (max `prev13` reached = 3, max `run53` = 3), so either reading reproduces it. Resetting
the three counters when `CCUF` differs from the previous day of the same key is the documented
behaviour and is the recommended implementation.
