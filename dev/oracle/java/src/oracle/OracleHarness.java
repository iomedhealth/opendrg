package oracle;

import gov.agency.msdrg.model.v2.MsdrgGrouperFlags;
import gov.agency.msdrg.model.v2.MsdrgHac;
import gov.agency.msdrg.model.v2.enumeration.MsdrgHospitalStatusOptionFlag;
import gov.agency.msdrg.model.v2.enumeration.MsdrgProcedureHacUsage;
import gov.agency.msdrg.model.v2.transfer.output.MsdrgOutputData;
import gov.agency.msdrg.model.v2.transfer.output.MsdrgOutputDxCode;
import gov.agency.msdrg.model.v2.transfer.output.MsdrgOutputPrCode;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * Runs CMS's MS-DRG Java grouper over the mainframe TESTDB file and writes CSV fixtures.
 *
 * <pre>
 * OracleHarness --testdb FILE --out DIR [--version 440|auto] [--prefix testdb_v440]
 *               [--mode api|wrapper|both] [--lenient-numeric] [--limit N]
 * </pre>
 *
 * mode api     : group with gov.agency.msdrg.v{version}.MsdrgComponent (official Java API)
 * mode wrapper : run CMS's mainframe wrapper gov.cms.grouper.mainframe.Msdrg.processMsdrg on the
 *                638-byte input and compare its 1162-byte output with the expectation embedded
 *                in each TESTDB record (version chosen by discharge date, as on z/OS)
 * mode both    : both, plus API-vs-wrapper comparison
 */
public final class OracleHarness {

  private static final class ApiResult {
    String status = "ok";      // ok | error | skipped
    String message = "";
    int version;               // grouper version used (0 when skipped)
    String legacy;             // 1162-byte mainframe-format rendering of the API output
    MsdrgOutputData out;
  }

  private static final class Args {
    Path testdb;
    Path out;
    String version = "440";
    String prefix;
    String mode = "api";
    boolean lenient = false;
    int limit = Integer.MAX_VALUE;
    String poaStatus = "per-record";   // per-record | NON_EXEMPT | EXEMPT | UNKNOWN
    String suffix = "";                // appended to the expected/trace/comparison file names
    boolean skipInputs = false;
    boolean trace = true;

    MsdrgHospitalStatusOptionFlag forcedPoaStatus() {
      return poaStatus.equals("per-record") ? null : MsdrgHospitalStatusOptionFlag.valueOf(poaStatus);
    }
  }

  public static void main(String[] argv) throws Exception {
    Args a = parse(argv);
    Files.createDirectories(a.out);
    PrintStream log = System.out;

    List<TestdbRecord> records = TestdbRecord.readAll(a.testdb);
    if (records.size() > a.limit) {
      records = new ArrayList<>(records.subList(0, a.limit));
    }
    log.println("records read: " + records.size() + " from " + a.testdb);

    ClaimMapper mapper = new ClaimMapper(a.lenient);
    List<ClaimMapper.Mapped> mapped = new ArrayList<>(records.size());
    for (TestdbRecord r : records) {
      mapped.add(mapper.map(r));
    }

    if (!a.skipInputs) {
      writeInputs(a, records, mapped);
      writeEmbedded(a, records, mapped);
    }

    List<ApiResult> api = null;
    if (a.mode.equals("api") || a.mode.equals("both")) {
      api = runApi(a, records, mapped, log);
    }
    List<String> wrapper = null;
    if (a.mode.equals("wrapper") || a.mode.equals("both")) {
      wrapper = runWrapper(a, records, log);
    }
    if (api != null && wrapper != null) {
      compareApiVsWrapper(a, records, api, wrapper, log);
    }
    if (api != null) {
      String summary = summarize(a, records, mapped, api, wrapper);
      Path sp = a.out.resolve(a.prefix + "_summary" + a.suffix + ".md");
      Files.write(sp, summary.getBytes(StandardCharsets.UTF_8));
      log.println();
      log.println(summary);
      log.println("summary written to " + sp);
    }
    log.println("done.");
  }

  private static Args parse(String[] argv) {
    Args a = new Args();
    for (int i = 0; i < argv.length; i++) {
      String k = argv[i];
      switch (k) {
        case "--testdb":
          a.testdb = Paths.get(argv[++i]);
          break;
        case "--out":
          a.out = Paths.get(argv[++i]);
          break;
        case "--version":
          a.version = argv[++i];
          break;
        case "--prefix":
          a.prefix = argv[++i];
          break;
        case "--mode":
          a.mode = argv[++i];
          break;
        case "--lenient-numeric":
          a.lenient = true;
          break;
        case "--limit":
          a.limit = Integer.parseInt(argv[++i]);
          break;
        case "--poa-status":
          a.poaStatus = argv[++i];
          break;
        case "--suffix":
          a.suffix = argv[++i];
          break;
        case "--skip-inputs":
          a.skipInputs = true;
          break;
        case "--no-trace":
          a.trace = false;
          break;
        default:
          throw new IllegalArgumentException("unknown argument " + k);
      }
    }
    if (!a.poaStatus.equals("per-record")) {
      MsdrgHospitalStatusOptionFlag.valueOf(a.poaStatus); // validates NON_EXEMPT | EXEMPT | UNKNOWN
    }
    if (a.testdb == null || a.out == null) {
      throw new IllegalArgumentException("--testdb and --out are required");
    }
    if (!a.version.equals("auto")) {
      int v = Integer.parseInt(a.version);
      if (!GrouperEngine.isSupported(v)) {
        throw new IllegalArgumentException("unsupported version " + v + "; supported: 400 401 410 411 420 421 430 431 440 or auto");
      }
    }
    if (a.prefix == null) {
      a.prefix = "testdb_v" + a.version;
    }
    if (!a.mode.equals("api") && !a.mode.equals("wrapper") && !a.mode.equals("both")) {
      throw new IllegalArgumentException("--mode must be api, wrapper or both");
    }
    return a;
  }

  // ---------------------------------------------------------------------------------------------
  // Inputs
  // ---------------------------------------------------------------------------------------------

  private static void writeInputs(Args a, List<TestdbRecord> records, List<ClaimMapper.Mapped> mapped)
      throws IOException {
    try (Csv claims = new Csv(a.out.resolve(a.prefix + "_input.csv"),
        "claim_id", "age", "age_raw", "age_parsed", "sex", "sex_raw", "discharge_status",
        "discharge_status_raw", "discharge_status_enum", "poa_logic", "hospital_poa_status",
        "admit_date", "discharge_date", "n_dx", "n_sdx", "n_pr", "principal_dx", "principal_dx_poa",
        "claim_description", "debug_ind", "record_length_ok");
        Csv dx = new Csv(a.out.resolve(a.prefix + "_input_dx.csv"),
            "claim_id", "seq", "slot", "code", "poa", "poa_enum");
        Csv pr = new Csv(a.out.resolve(a.prefix + "_input_pr.csv"),
            "claim_id", "seq", "slot", "code", "date")) {
      for (int i = 0; i < records.size(); i++) {
        TestdbRecord r = records.get(i);
        ClaimMapper.Mapped m = mapped.get(i);
        ClaimMapper.DxEntry pdx = m.hasPrincipal ? m.dx.get(0) : null;
        claims.row(r.claimId, m.ageUsed, r.ageRaw(), m.ageParsed, m.sexUsed.name(), r.sexRaw(),
            m.dischargeStatusInt, r.dischargeStatusRaw(),
            m.dischargeStatusUsed == null ? "" : m.dischargeStatusUsed.name(),
            r.poaLogic(), m.hospitalStatus.name(), r.admitDate(), r.dischargeDate(),
            m.dx.size(), m.hasPrincipal ? m.dx.size() - 1 : m.dx.size(), m.pr.size(),
            pdx == null ? "" : pdx.code, pdx == null ? "" : pdx.poaRaw.trim(),
            r.optData().trim(), r.debugInd().trim(), r.lengthOk());
        for (ClaimMapper.DxEntry d : m.dx) {
          dx.row(r.claimId, d.seq, d.slot, d.code, d.poaRaw.trim(), d.poa.name());
        }
        for (ClaimMapper.PrEntry p : m.pr) {
          pr.row(r.claimId, p.seq, p.slot, p.code, p.date);
        }
      }
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Expectations embedded in TESTDB (produced by CMS on z/OS, version selected by discharge date)
  // ---------------------------------------------------------------------------------------------

  private static Integer parseIntOrNull(String s) {
    try {
      return Integer.parseInt(s.trim());
    } catch (NumberFormatException e) {
      return null;
    }
  }

  private static void writeEmbedded(Args a, List<TestdbRecord> records, List<ClaimMapper.Mapped> mapped)
      throws IOException {
    try (Csv claims = new Csv(a.out.resolve(a.prefix + "_cms_embedded.csv"),
        "claim_id", "version_id", "grouper_version", "rtc", "mdc", "drg", "grouper_flags",
        "num_hac_met", "final_ccmcc_impact", "initial_ccmcc_impact", "hac_status",
        "final_base_drg", "final_severity_level", "final_med_surg", "initial_drg",
        "initial_base_drg", "initial_severity_level", "initial_med_surg", "n_dx_flag_blocks",
        "n_pr_flag_blocks");
        Csv dx = new Csv(a.out.resolve(a.prefix + "_cms_embedded_dx.csv"),
            "claim_id", "seq", "code", "flags", "valid", "affects_drg", "ccmcc_category",
            "hac1_number", "hac1_usage", "hac2_number", "hac2_usage", "hac3_number", "hac3_usage",
            "hac4_number", "hac4_usage", "hac5_number", "hac5_usage");
        Csv pr = new Csv(a.out.resolve(a.prefix + "_cms_embedded_pr.csv"),
            "claim_id", "seq", "code", "flags", "valid", "affects_drg", "is_or_procedure",
            "hac1_usage", "hac2_usage", "hac3_usage", "hac4_usage", "hac5_usage")) {
      for (int i = 0; i < records.size(); i++) {
        TestdbRecord r = records.get(i);
        ClaimMapper.Mapped m = mapped.get(i);
        String ver = r.expVersionId();
        Integer verInt = null;
        if (ver.length() == 8 && !ver.equals("00000000")) {
          verInt = parseIntOrNull(ver.substring(3, 6));
        }
        String gf = r.expGrouperFlags();
        int ndx = 0;
        for (int b = 1; b <= TestdbRecord.MAX_DX; b++) {
          if (!r.expDxFlags(b).trim().isEmpty()) {
            ndx = b;
          }
        }
        int npr = 0;
        for (int b = 1; b <= TestdbRecord.MAX_PR; b++) {
          if (!r.expPrFlags(b).trim().isEmpty()) {
            npr = b;
          }
        }
        claims.row(r.claimId, ver, verInt, parseIntOrNull(r.expRtc()), parseIntOrNull(r.expMdc()),
            parseIntOrNull(r.expDrg()), gf, parseIntOrNull(gf.substring(0, 2)),
            gf.substring(2, 3), gf.substring(3, 4), gf.substring(4, 5),
            parseIntOrNull(r.expFinalBaseDrg()), parseIntOrNull(r.expFinalSeverity()),
            parseIntOrNull(r.expFinalMedSurg()), parseIntOrNull(r.expInitialDrg()),
            parseIntOrNull(r.expInitialBaseDrg()), parseIntOrNull(r.expInitialSeverity()),
            parseIntOrNull(r.expInitialMedSurg()), ndx, npr);
        // flag block b corresponds to dx seq b-1 (block 1 = principal, even when the principal
        // slot is blank: the grouper then reports a "null" pdx block), compacted like the input
        for (int b = 1; b <= ndx; b++) {
          String f = r.expDxFlags(b);
          int seq = b - 1;
          String code = "";
          for (ClaimMapper.DxEntry d : m.dx) {
            if (d.seq == seq) {
              code = d.code;
            }
          }
          boolean valid = f.charAt(0) == '1';
          dx.row(r.claimId, seq, code, f, valid,
              valid ? f.substring(1, 2) : "", valid ? f.substring(2, 3) : "",
              valid ? f.substring(3, 5) : "", valid ? f.substring(5, 6) : "",
              valid ? f.substring(6, 8) : "", valid ? f.substring(8, 9) : "",
              valid ? f.substring(9, 11) : "", valid ? f.substring(11, 12) : "",
              valid ? f.substring(12, 14) : "", valid ? f.substring(14, 15) : "",
              valid ? f.substring(15, 17) : "", valid ? f.substring(17, 18) : "");
        }
        for (int b = 1; b <= npr; b++) {
          String f = r.expPrFlags(b);
          String code = b - 1 < m.pr.size() ? m.pr.get(b - 1).code : "";
          boolean valid = f.charAt(0) == '1';
          pr.row(r.claimId, b, code, f, valid,
              valid ? f.substring(1, 2) : "", valid ? f.substring(2, 3) : "",
              valid ? f.substring(3, 5) : "", valid ? f.substring(5, 7) : "",
              valid ? f.substring(7, 9) : "", valid ? f.substring(9, 11) : "",
              valid ? f.substring(11, 13) : "");
        }
      }
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Official Java API run
  // ---------------------------------------------------------------------------------------------

  private static int versionFor(Args a, TestdbRecord r, ApiResult res) {
    if (!a.version.equals("auto")) {
      return Integer.parseInt(a.version);
    }
    try {
      gov.cms.grouper.mainframe.date.VersionDate vd =
          gov.cms.grouper.mainframe.date.VersionDate.getVersionFromDate(r.dischargeDate());
      int v = vd.getVersion();
      if (!GrouperEngine.isSupported(v)) {
        res.status = "skipped";
        res.message = "discharge date " + r.dischargeDate() + " selects version " + v
            + " which is only available through the mainframe wrapper (v1 model)";
        return 0;
      }
      return v;
    } catch (Exception e) {
      res.status = "skipped";
      res.message = e.getClass().getSimpleName() + ": " + e.getMessage();
      return 0;
    }
  }

  private static String hacsString(List<MsdrgHac> hacs) {
    StringBuilder sb = new StringBuilder();
    for (MsdrgHac h : hacs) {
      if (sb.length() > 0) {
        sb.append(';');
      }
      sb.append(String.format("%02d", h.getHacNumber())).append(':').append(h.getHacStatus().name());
    }
    return sb.toString();
  }

  private static String hacUsageString(java.util.Set<MsdrgProcedureHacUsage> set) {
    StringBuilder sb = new StringBuilder();
    for (MsdrgProcedureHacUsage u : set) {
      if (sb.length() > 0) {
        sb.append(';');
      }
      sb.append(u.name());
    }
    return sb.toString();
  }

  private static List<ApiResult> runApi(Args a, List<TestdbRecord> records,
      List<ClaimMapper.Mapped> mapped, PrintStream log) throws Exception {
    List<ApiResult> results = new ArrayList<>(records.size());
    long t0 = System.nanoTime();
    MsdrgHospitalStatusOptionFlag forced = a.forcedPoaStatus();
    String s = a.suffix;
    try (GrouperEngine engine = new GrouperEngine(a.trace);
        Csv claims = new Csv(a.out.resolve(a.prefix + "_expected" + s + ".csv"),
            "claim_id", "status", "error_message", "grouper_version", "version_id",
            "opt_poa_reporting_exempt", "opt_marking_logic_tie_breaker", "opt_compute_affect_drg",
            "final_grc", "final_grc_name", "final_mdc", "final_drg", "final_base_drg",
            "final_severity", "final_severity_level", "final_med_surg", "final_med_surg_int",
            "final_drg_sdx_severity",
            "initial_grc", "initial_grc_name", "initial_mdc", "initial_drg", "initial_base_drg",
            "initial_severity", "initial_severity_level", "initial_med_surg", "initial_med_surg_int",
            "initial_drg_sdx_severity",
            "drg_changed_by_hac", "hac_status", "num_hac_categories_satisfied", "admit_dx_flag",
            "grouper_flags_api", "grouper_flags_mf", "final_drg_desc", "final_base_drg_desc",
            "final_mdc_desc", "initial_drg_desc");
        Csv dx = new Csv(a.out.resolve(a.prefix + "_expected_dx" + s + ".csv"),
            "claim_id", "seq", "code", "poa_enum", "recognized", "affects_drg", "affects_drg_int",
            "final_severity_usage", "initial_severity_usage", "ccmcc_category_mf",
            "poa_error_code", "n_hacs", "hacs", "flags_api", "flags_mf");
        Csv pr = new Csv(a.out.resolve(a.prefix + "_expected_pr" + s + ".csv"),
            "claim_id", "seq", "code", "recognized", "affects_drg", "affects_drg_int",
            "is_or_procedure", "hac_usage", "cluster_ids", "flags_api", "flags_mf");
        Csv tr = a.trace ? new Csv(a.out.resolve(a.prefix + "_trace" + s + ".csv"),
            "claim_id", "clusters", "initial_mdc_path", "initial_matches",
            "initial_matched_attributes", "final_mdc_path", "final_matches",
            "final_matched_attributes", "hac_formulas_matched") : null;
        Csv trc = a.trace ? new Csv(a.out.resolve(a.prefix + "_trace_codes" + s + ".csv"),
            "claim_id", "kind", "seq", "code", "poa", "mdc", "dxcat", "clin_sig", "severity",
            "hac", "attributes", "cluster_ids", "mdc_suppression") : null) {
      for (int i = 0; i < records.size(); i++) {
        TestdbRecord r = records.get(i);
        ClaimMapper.Mapped m = mapped.get(i);
        ApiResult res = new ApiResult();
        res.version = versionFor(a, r, res);
        MsdrgHospitalStatusOptionFlag hospitalStatus = forced != null ? forced : m.hospitalStatus;
        TraceParser trace = null;
        if (res.status.equals("ok")) {
          try {
            res.out = engine.group(res.version, m.input, hospitalStatus, String.valueOf(r.claimId));
            res.legacy = LegacyFormat.format(res.out, res.version);
            if (a.trace) {
              trace = TraceParser.parse(engine.lastTrace());
            }
          } catch (Throwable t) {
            res.status = "error";
            res.message = t.getClass().getName() + ": " + t.getMessage();
            res.out = null;
          }
        }
        results.add(res);
        if (res.out == null) {
          claims.row(r.claimId, res.status, res.message, res.version == 0 ? "" : res.version, "",
              hospitalStatus.name(), engine.options().getMarkingLogicTieBreaker().name(),
              engine.options().getComputeAffectDrg().name(),
              "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
              "", "", "", "", "", "", "", "");
          continue;
        }
        MsdrgOutputData o = res.out;
        MsdrgGrouperFlags gf = o.getGrouperFlags();
        int finalDrg = o.getFinalDrg().getValue();
        int initialDrg = o.getInitialDrg().getValue();
        claims.row(r.claimId, res.status, "", res.version, LegacyFormat.versionId(res.version),
            hospitalStatus.name(), engine.options().getMarkingLogicTieBreaker().name(),
            engine.options().getComputeAffectDrg().name(),
            o.getFinalGrc().getGrouperReturnCode(), o.getFinalGrc().name(),
            o.getFinalMdc().getValue(), finalDrg, o.getFinalBaseDrg().getValue(),
            o.getFinalSeverity() == null ? "" : o.getFinalSeverity().name(),
            LegacyFormat.severityLevel(o.getFinalSeverity()),
            o.getFinalMedSugType() == null ? "" : o.getFinalMedSugType().name(),
            LegacyFormat.medSurgInt(o.getFinalMedSugType()),
            o.getFinalDrgSdxSeverity() == null ? "" : o.getFinalDrgSdxSeverity().name(),
            o.getInitialGrc().getGrouperReturnCode(), o.getInitialGrc().name(),
            o.getInitialMdc().getValue(), initialDrg, o.getInitialBaseDrg().getValue(),
            o.getInitialSeverity() == null ? "" : o.getInitialSeverity().name(),
            LegacyFormat.severityLevel(o.getInitialSeverity()),
            o.getInitialMedSugType() == null ? "" : o.getInitialMedSugType().name(),
            LegacyFormat.medSurgInt(o.getInitialMedSugType()),
            o.getInitialDrgSdxSeverity() == null ? "" : o.getInitialDrgSdxSeverity().name(),
            finalDrg != initialDrg, o.getHacStatus().name(), o.getNumHacCategoriesSatisfied(),
            gf.getAdmitDxGrouperFlag().name(), gf.toString(), LegacyFormat.grouperFlags(o),
            o.getFinalDrg().getDescription(), o.getFinalBaseDrg().getDescription(),
            o.getFinalMdc().getDescription(), o.getInitialDrg().getDescription());
        // seq 0 is always the principal output (code "null" when the principal slot was blank),
        // so seq numbering lines up with the input file and the mainframe flag blocks
        int seq = 0;
        for (MsdrgOutputDxCode d : LegacyFormat.dxOutputs(o)) {
          dx.row(r.claimId, seq, d.getInputDxCode().getValue(), d.getInputDxCode().getPoa().name(),
              d.isDiagnosisRecognizedByGrouper(), d.getDiagnosisAffectsDrg().name(),
              d.getDiagnosisAffectsDrg().intValue(), d.getFinalSeverityUsage().name(),
              d.getInitialSeverityUsage().name(),
              d.isDiagnosisRecognizedByGrouper()
                  ? LegacyFormat.ccMccCategory(d.getFinalSeverityUsage(), d.getInitialSeverityUsage())
                  : "",
              d.getPoaErrorCode().name(), d.getHacs().size(), hacsString(d.getHacs()),
              d.getLegacyFlagString(), LegacyFormat.dxFlags(d));
          if (trc != null) {
            TraceParser.CodeInfo ci = trace.take(seq == 0 ? "PDX" : "SDX", d.getInputDxCode().getValue());
            if (ci != null) {
              trc.row(r.claimId, ci.kind, seq, ci.code, ci.poa, ci.mdc, ci.dxcat, ci.clinSig,
                  ci.severity, ci.hac, TraceParser.join(ci.attributes, "|"), "", "");
            }
          }
          seq++;
        }
        int pseq = 0;
        for (MsdrgOutputPrCode p : o.getProcOutput()) {
          pseq++;
          TraceParser.CodeInfo ci = trace == null ? null : trace.take("PROC", p.getInputPrCode().getValue());
          String clusterIds = ci == null ? "" : TraceParser.join(ci.clusterIds, "|");
          pr.row(r.claimId, pseq, p.getInputPrCode().getValue(), p.isProcedureRecognizedByGrouper(),
              p.getProcedureAffectsDrg().name(), p.getProcedureAffectsDrg().intValue(),
              p.isProcedureIsOperatingRoomProcedure(), hacUsageString(p.getHacUsage()), clusterIds,
              p.getLegacyFlagString(), LegacyFormat.prFlags(p));
          if (trc != null && ci != null) {
            trc.row(r.claimId, "PROC", pseq, ci.code, "", "", "", "", "", ci.hac,
                TraceParser.join(ci.attributes, "|"), clusterIds, "");
          }
        }
        if (tr != null) {
          StringBuilder cl = new StringBuilder();
          for (TraceParser.CodeInfo c : trace.clusters()) {
            if (cl.length() > 0) {
              cl.append(';');
            }
            cl.append(c.code).append('{').append(c.mdcSuppression).append('}');
            trc.row(r.claimId, "CLUSTER", "", c.code, "", "", "", "", "", c.hac,
                TraceParser.join(c.attributes, "|"), "", c.mdcSuppression);
          }
          tr.row(r.claimId, cl.toString(), TraceParser.join(trace.initial.mdcPath, ">"),
              TraceParser.matches(trace.initial), TraceParser.matchedAttributes(trace.initial),
              TraceParser.join(trace.fin.mdcPath, ">"), TraceParser.matches(trace.fin),
              TraceParser.matchedAttributes(trace.fin), String.join(";", trace.hacFormulas));
        }
        if ((i + 1) % 2000 == 0) {
          log.println("  api: " + (i + 1) + " claims grouped");
        }
      }
    }
    log.println("api run finished in " + (System.nanoTime() - t0) / 1_000_000 + " ms");
    writeApiVsEmbedded(a, records, results);
    return results;
  }

  private static int firstDiff(String x, String y) {
    int n = Math.min(x.length(), y.length());
    for (int i = 0; i < n; i++) {
      if (x.charAt(i) != y.charAt(i)) {
        return i + 1;
      }
    }
    return x.length() == y.length() ? 0 : n + 1;
  }

  private static void writeApiVsEmbedded(Args a, List<TestdbRecord> records, List<ApiResult> api)
      throws IOException {
    try (Csv c = new Csv(a.out.resolve(a.prefix + "_vs_embedded" + a.suffix + ".csv"),
        "claim_id", "api_status", "api_version", "embedded_version", "same_version",
        "embedded_rtc", "api_rtc", "embedded_mdc", "api_mdc", "embedded_drg", "api_drg",
        "rtc_match", "mdc_match", "drg_match", "initial_drg_match", "grouper_flags_match",
        "dx_flags_match", "pr_flags_match", "output_match_excl_version", "first_diff_pos")) {
      for (int i = 0; i < records.size(); i++) {
        TestdbRecord r = records.get(i);
        ApiResult res = api.get(i);
        String emb = r.embeddedOutput();
        Integer embVer = r.expVersionId().equals("00000000") ? null
            : parseIntOrNull(r.expVersionId().substring(3, 6));
        if (res.out == null) {
          c.row(r.claimId, res.status, res.version == 0 ? "" : res.version, embVer, "",
              parseIntOrNull(r.expRtc()), "", parseIntOrNull(r.expMdc()), "",
              parseIntOrNull(r.expDrg()), "", "", "", "", "", "", "", "", "", "");
          continue;
        }
        String leg = res.legacy;
        c.row(r.claimId, res.status, res.version, embVer, embVer != null && embVer == res.version,
            parseIntOrNull(r.expRtc()), res.out.getFinalGrc().getGrouperReturnCode(),
            parseIntOrNull(r.expMdc()), res.out.getFinalMdc().getValue(),
            parseIntOrNull(r.expDrg()), res.out.getFinalDrg().getValue(),
            emb.substring(0, 2).equals(leg.substring(0, 2)),
            emb.substring(2, 4).equals(leg.substring(2, 4)),
            emb.substring(4, 8).equals(leg.substring(4, 8)),
            emb.substring(1144, 1148).equals(leg.substring(1144, 1148)),
            emb.substring(8, 13).equals(leg.substring(8, 13)),
            emb.substring(13, 638).equals(leg.substring(13, 638)),
            emb.substring(638, 1138).equals(leg.substring(638, 1138)),
            emb.substring(0, 1154).equals(leg.substring(0, 1154)),
            firstDiff(emb, leg));
      }
    }
  }

  // ---------------------------------------------------------------------------------------------
  // CMS mainframe wrapper run (install-test replica)
  // ---------------------------------------------------------------------------------------------

  private static List<String> runWrapper(Args a, List<TestdbRecord> records, PrintStream log)
      throws Exception {
    List<String> outs = new ArrayList<>(records.size());
    long t0 = System.nanoTime();
    int match = 0;
    Map<String, Integer> byVersion = new TreeMap<>();
    Map<String, Integer> byVersionMatch = new TreeMap<>();
    try (Csv c = new Csv(a.out.resolve(a.prefix + "_wrapper_vs_embedded.csv"),
        "claim_id", "wrapper_status", "wrapper_rtc", "wrapper_mdc", "wrapper_drg",
        "wrapper_version_id", "embedded_version_id", "match", "first_diff_pos")) {
      for (TestdbRecord r : records) {
        String emb = r.embeddedOutput();
        String res;
        String status = "ok";
        try {
          res = gov.cms.grouper.mainframe.Msdrg.processMsdrg(r.inputRecord());
        } catch (Throwable t) {
          status = "error: " + t.getClass().getName() + ": " + t.getMessage();
          res = "";
        }
        outs.add(res);
        boolean eq = res.equals(emb);
        if (eq) {
          match++;
        }
        String ver = r.expVersionId();
        byVersion.merge(ver, 1, Integer::sum);
        if (eq) {
          byVersionMatch.merge(ver, 1, Integer::sum);
        }
        c.row(r.claimId, status,
            res.length() >= 8 ? res.substring(0, 2) : "",
            res.length() >= 8 ? res.substring(2, 4) : "",
            res.length() >= 8 ? res.substring(4, 8) : "",
            res.length() == TestdbRecord.OUTPUT_LEN ? res.substring(1154) : "",
            ver, eq, firstDiff(emb, res));
      }
    }
    log.println("wrapper run finished in " + (System.nanoTime() - t0) / 1_000_000 + " ms: "
        + match + "/" + records.size() + " records identical to embedded expectation");
    for (String v : byVersion.keySet()) {
      log.println("  version " + v + ": " + byVersionMatch.getOrDefault(v, 0) + "/" + byVersion.get(v));
    }
    return outs;
  }

  private static void compareApiVsWrapper(Args a, List<TestdbRecord> records, List<ApiResult> api,
      List<String> wrapper, PrintStream log) throws IOException {
    int n = 0;
    int match = 0;
    int otherVersion = 0;
    try (Csv c = new Csv(a.out.resolve(a.prefix + "_vs_wrapper" + a.suffix + ".csv"),
        "claim_id", "api_status", "api_version", "wrapper_version_id", "same_version", "match",
        "first_diff_pos")) {
      for (int i = 0; i < records.size(); i++) {
        ApiResult res = api.get(i);
        String w = wrapper.get(i);
        String wver = w.length() == TestdbRecord.OUTPUT_LEN ? w.substring(1154) : "";
        if (res.out == null) {
          c.row(records.get(i).claimId, res.status, "", wver, "", "", "");
          continue;
        }
        boolean sameVersion = wver.equals(LegacyFormat.versionId(res.version));
        boolean eq = res.legacy.equals(w);
        if (sameVersion) {
          n++;
          if (eq) {
            match++;
          }
        } else {
          otherVersion++;
        }
        c.row(records.get(i).claimId, res.status, res.version, wver, sameVersion, eq,
            firstDiff(res.legacy, w));
      }
    }
    log.println("api vs wrapper (1162-byte output, records where both used the same version): "
        + match + "/" + n + " identical; " + otherVersion
        + " records compared against a different wrapper version");
  }

  // ---------------------------------------------------------------------------------------------
  // Summary
  // ---------------------------------------------------------------------------------------------

  private static String summarize(Args a, List<TestdbRecord> records, List<ClaimMapper.Mapped> mapped,
      List<ApiResult> api, List<String> wrapper) {
    StringBuilder sb = new StringBuilder();
    int ok = 0;
    int err = 0;
    int skipped = 0;
    Map<Integer, Integer> byRtc = new TreeMap<>();
    Map<Integer, Integer> byMdc = new TreeMap<>();
    Map<Integer, Integer> byDrg = new TreeMap<>();
    Map<String, Integer> bySev = new TreeMap<>();
    Map<String, Integer> byMedSurg = new TreeMap<>();
    Map<String, Integer> byHac = new TreeMap<>();
    int changed = 0;
    int drg998 = 0;
    int drg999 = 0;
    Map<String, int[]> agreeByVer = new TreeMap<>();
    int agreeAll = 0;
    int cmpAll = 0;
    int agreeAllFull = 0;
    List<String> failures = new ArrayList<>();
    Map<String, Integer> skippedByReason = new LinkedHashMap<>();
    for (int i = 0; i < records.size(); i++) {
      ApiResult r = api.get(i);
      TestdbRecord rec = records.get(i);
      if (r.out == null) {
        if (r.status.equals("error")) {
          err++;
          failures.add("| " + rec.claimId + " | " + r.status + " | "
              + r.message.replace("|", "\\|") + " |");
        } else {
          skipped++;
          String reason = r.message.replaceAll("discharge date \\S+ selects", "discharge date selects");
          skippedByReason.merge(reason, 1, Integer::sum);
        }
        continue;
      }
      ok++;
      MsdrgOutputData o = r.out;
      byRtc.merge(o.getFinalGrc().getGrouperReturnCode(), 1, Integer::sum);
      byMdc.merge(o.getFinalMdc().getValue(), 1, Integer::sum);
      byDrg.merge(o.getFinalDrg().getValue(), 1, Integer::sum);
      bySev.merge(String.valueOf(o.getFinalSeverity()), 1, Integer::sum);
      byMedSurg.merge(String.valueOf(o.getFinalMedSugType()), 1, Integer::sum);
      byHac.merge(o.getHacStatus().name(), 1, Integer::sum);
      int fd = o.getFinalDrg().getValue();
      if (fd != o.getInitialDrg().getValue()) {
        changed++;
      }
      if (fd == 998) {
        drg998++;
      }
      if (fd == 999) {
        drg999++;
      }
      String ver = rec.expVersionId();
      int[] agg = agreeByVer.computeIfAbsent(ver, k -> new int[3]);
      agg[0]++;
      cmpAll++;
      String emb = rec.embeddedOutput();
      if (emb.substring(4, 8).equals(r.legacy.substring(4, 8))
          && emb.substring(0, 2).equals(r.legacy.substring(0, 2))) {
        agg[1]++;
        agreeAll++;
      }
      if (emb.substring(0, 1154).equals(r.legacy.substring(0, 1154))) {
        agg[2]++;
        agreeAllFull++;
      }
    }

    sb.append("# MS-DRG oracle run summary\n\n");
    sb.append("- TESTDB: `").append(a.testdb).append("`\n");
    sb.append("- grouper version: `").append(a.version).append("` (mode ").append(a.mode)
        .append(", numeric parsing ").append(a.lenient ? "lenient" : "strict/wrapper-identical")
        .append(")\n");
    sb.append("- runtime options: poaReportingExempt = ")
        .append(a.poaStatus.equals("per-record")
            ? "per record from TESTDB col 7 (X = EXEMPT, otherwise NON_EXEMPT)" : a.poaStatus)
        .append("; markingLogicTieBreaker = CLINICAL_SIGNIFICANCE; computeAffectDrg = COMPUTE; trace = ")
        .append(a.trace).append("\n");
    sb.append("- records read: ").append(records.size()).append("; grouped OK: ").append(ok)
        .append("; grouper errors: ").append(err).append("; skipped: ").append(skipped).append("\n");
    sb.append("- final DRG differs from initial DRG (HAC re-grouping): ").append(changed).append("\n");
    sb.append("- DRG 998: ").append(drg998).append("; DRG 999: ").append(drg999).append("\n\n");

    sb.append("## Counts by final return code\n\n| return_code | name | n |\n|---|---|---|\n");
    for (Map.Entry<Integer, Integer> e : byRtc.entrySet()) {
      sb.append("| ").append(e.getKey()).append(" | ")
          .append(gov.agency.msdrg.model.v2.enumeration.MsdrgGrouperReturnCode.fromInt(e.getKey()).name())
          .append(" | ").append(e.getValue()).append(" |\n");
    }
    sb.append("\n## Counts by final MDC\n\n| mdc | n |\n|---|---|\n");
    for (Map.Entry<Integer, Integer> e : byMdc.entrySet()) {
      sb.append("| ").append(e.getKey()).append(" | ").append(e.getValue()).append(" |\n");
    }
    sb.append("\n## Final severity / med-surg / HAC status\n\n| field | value | n |\n|---|---|---|\n");
    for (Map.Entry<String, Integer> e : bySev.entrySet()) {
      sb.append("| final_severity | ").append(e.getKey()).append(" | ").append(e.getValue()).append(" |\n");
    }
    for (Map.Entry<String, Integer> e : byMedSurg.entrySet()) {
      sb.append("| final_med_surg | ").append(e.getKey()).append(" | ").append(e.getValue()).append(" |\n");
    }
    for (Map.Entry<String, Integer> e : byHac.entrySet()) {
      sb.append("| hac_status | ").append(e.getKey()).append(" | ").append(e.getValue()).append(" |\n");
    }
    sb.append("\n## Top 20 final DRGs\n\n| drg | n |\n|---|---|\n");
    List<Map.Entry<Integer, Integer>> top = new ArrayList<>(byDrg.entrySet());
    top.sort((x, y) -> y.getValue().equals(x.getValue()) ? Integer.compare(x.getKey(), y.getKey())
        : Integer.compare(y.getValue(), x.getValue()));
    for (int i = 0; i < Math.min(20, top.size()); i++) {
      sb.append("| ").append(top.get(i).getKey()).append(" | ").append(top.get(i).getValue()).append(" |\n");
    }
    sb.append("\n(").append(byDrg.size()).append(" distinct final DRGs)\n");

    sb.append("\n## Agreement with the expectations embedded in TESTDB\n\n");
    sb.append("The embedded expectations were produced by CMS with the grouper version selected by ")
        .append("discharge date (version id PPPVVVUU in columns 1993-2000). `rtc+drg` compares return code ")
        .append("and final DRG; `full` compares the whole 1162-byte output except the version id.\n\n");
    sb.append("| embedded version id | n | rtc+drg agree | full agree |\n|---|---|---|---|\n");
    for (Map.Entry<String, int[]> e : agreeByVer.entrySet()) {
      int[] v = e.getValue();
      sb.append("| ").append(e.getKey()).append(" | ").append(v[0]).append(" | ").append(v[1])
          .append(" | ").append(v[2]).append(" |\n");
    }
    sb.append("| **all** | ").append(cmpAll).append(" | ").append(agreeAll).append(" (")
        .append(String.format("%.1f", 100.0 * agreeAll / Math.max(1, cmpAll))).append("%) | ")
        .append(agreeAllFull).append(" (")
        .append(String.format("%.1f", 100.0 * agreeAllFull / Math.max(1, cmpAll))).append("%) |\n");

    if (!failures.isEmpty()) {
      sb.append("\n## Records that failed in the grouper (API run)\n\n| claim_id | status | reason |\n|---|---|---|\n");
      for (String f : failures) {
        sb.append(f).append('\n');
      }
    }
    if (!skippedByReason.isEmpty()) {
      sb.append("\n## Records skipped by the API run\n\n| n | reason |\n|---|---|\n");
      for (Map.Entry<String, Integer> e : skippedByReason.entrySet()) {
        sb.append("| ").append(e.getValue()).append(" | ").append(e.getKey().replace("|", "\\|"))
            .append(" |\n");
      }
    }
    if (ok + err + skipped != records.size()) {
      sb.append("\nWARNING: ").append(records.size() - ok - err - skipped)
          .append(" records unaccounted for\n");
    }
    return sb.toString();
  }
}
