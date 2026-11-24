package oracle;

import com.google.protobuf.CodedInputStream;
import gov.agency.msdrg.access.Data;
import gov.agency.msdrg.access.DataBlob;
import gov.agency.msdrg.model.v2.MsdrgRuntimeOption;
import gov.agency.msdrg.model.v2.access.ClusterChoices;
import gov.agency.msdrg.model.v2.access.DataAccess;
import gov.agency.msdrg.model.v2.access.HacFormula;
import gov.agency.msdrg.model.v2.access.MsdrgClusterDefinition;
import gov.agency.msdrg.model.v2.access.MsdrgDrgFormula;
import gov.agency.msdrg.model.v2.dao.ClusterAccess;
import gov.agency.msdrg.model.v2.dao.DescriptionAccess;
import gov.agency.msdrg.model.v2.dao.FormulaAccess;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Dumps the grouper's internal tables for one version, as the grouper itself reads them through
 * the msdrg-binary-access DAOs (FormulaAccess, DescriptionAccess, ClusterAccess over DataBlob):
 *
 * <pre>
 * DataDump --version 440 --out DIR [--prclstrs FILE] [--drglogic FILE]
 *   v{VER}_hac_formulas.csv            FormulaAccess.getFormulasForHacList(n), n = 1..30
 *   v{VER}_drg_formulas_from_binary.csv FormulaAccess.getAllFormulaRowsByMdc(mdc), mdc = 0..29
 *   v{VER}_hac_descriptions.csv        DescriptionAccess.getHacDescription(n)
 *   v{VER}_mdc_descriptions.csv        DescriptionAccess.getMdcDescription(mdc)
 *   v{VER}_drg_descriptions.csv        DescriptionAccess.getDrgDescription / getBaseDrgDescription
 *   v{VER}_clusters_from_binary.csv    one row per (cluster_code, choice, proc_code) for the version
 *   v{VER}_clusters_mdc_restriction_map.csv  PRCLSTRS.MDCRESTRICTION token string -> binary MDC set
 * </pre>
 */
public final class DataDump {

  private static final Pattern GRC_TOKEN = Pattern.compile(
      "(?i)(?<![A-Za-z0-9_:@])(invalid_dstat|invalid_pdx|pdx_ecode|invalid_age|invalid_sex)(?![A-Za-z0-9_])");

  private DataDump() {
  }

  public static void main(String[] argv) throws Exception {
    int version = 440;
    Path out = null;
    Path prclstrs = null;
    Path drglogic = null;
    for (int i = 0; i < argv.length; i++) {
      switch (argv[i]) {
        case "--version":
          version = Integer.parseInt(argv[++i]);
          break;
        case "--out":
          out = Paths.get(argv[++i]);
          break;
        case "--prclstrs":
          prclstrs = Paths.get(argv[++i]);
          break;
        case "--drglogic":
          drglogic = Paths.get(argv[++i]);
          break;
        default:
          throw new IllegalArgumentException("unknown argument " + argv[i]);
      }
    }
    if (out == null) {
      throw new IllegalArgumentException("--out is required");
    }
    Files.createDirectories(out);
    String p = "v" + version + "_";

    DataAccess access = DataBlob.getInstance(new MsdrgRuntimeOption());
    FormulaAccess formulaAccess = new FormulaAccess(access, version);
    DescriptionAccess descriptionAccess = new DescriptionAccess(access, version);
    ClusterAccess clusterAccess = new ClusterAccess(access, version);

    dumpHacFormulas(out.resolve(p + "hac_formulas.csv"), formulaAccess, descriptionAccess, version);
    List<MsdrgDrgFormula> drgRows = dumpDrgFormulas(out.resolve(p + "drg_formulas_from_binary.csv"),
        formulaAccess, version);
    dumpDescriptions(out, p, descriptionAccess, version);
    Map<String, ClusterDef> clusters = readClustersFromBlob(version);
    crossCheckClustersWithDao(clusters, access, clusterAccess, version);
    dumpClusters(out.resolve(p + "clusters_from_binary.csv"), clusters, version);
    if (prclstrs != null) {
      compareWithPrclstrs(out.resolve(p + "clusters_mdc_restriction_map.csv"), clusters, prclstrs);
    }
    if (drglogic != null) {
      compareWithDrglogic(drgRows, drglogic);
    }
    System.out.println("done.");
  }

  // ---------------------------------------------------------------------------------------------
  // formulas and descriptions (DAO path, exactly what the grouper calls)
  // ---------------------------------------------------------------------------------------------

  static String grcFromFormula(String formula) {
    if (formula == null) {
      return "";
    }
    Set<String> codes = new TreeSet<>();
    Matcher m = GRC_TOKEN.matcher(formula);
    while (m.find()) {
      switch (m.group(1).toLowerCase()) {
        case "invalid_dstat":
          codes.add("5");
          break;
        case "invalid_pdx":
          codes.add("7");
          break;
        case "pdx_ecode":
          codes.add("1");
          break;
        case "invalid_age":
          codes.add("3");
          break;
        case "invalid_sex":
          codes.add("4");
          break;
        default:
          break;
      }
    }
    return codes.isEmpty() ? "0" : String.join("|", codes);
  }

  private static void dumpHacFormulas(Path file, FormulaAccess fa, DescriptionAccess da, int version)
      throws IOException {
    int n = 0;
    try (Csv c = new Csv(file, "grouper_version", "hac_number", "index", "formula",
        "formula_collection_id", "hac_description")) {
      for (int hac = 1; hac <= 30; hac++) {
        List<HacFormula> rows = fa.getFormulasForHacList(hac);
        String desc = da.getHacDescription(hac).orElse("");
        int idx = 0;
        for (HacFormula f : rows) {
          idx++;
          n++;
          c.row(version, hac, idx, f.getFormula(), f.getFormulaCollectionId(), desc);
          if (f.getHacNumber() != hac) {
            System.out.println("WARNING: HacFormula.hacNumber=" + f.getHacNumber() + " under key " + hac);
          }
        }
      }
    }
    System.out.println("hac formulas: " + n + " rows -> " + file);
  }

  private static List<MsdrgDrgFormula> dumpDrgFormulas(Path file, FormulaAccess fa, int version)
      throws IOException {
    List<MsdrgDrgFormula> all = new ArrayList<>();
    try (Csv c = new Csv(file, "grouper_version", "mdc", "rank", "list_index", "drg", "base_drg",
        "surgical", "reroute_mdc", "return_code", "formula", "severity_suppression_operands",
        "drg_severity", "formula_collection_id")) {
      for (int mdc = 0; mdc <= 29; mdc++) {
        List<MsdrgDrgFormula> rows = fa.getAllFormulaRowsByMdc(mdc);
        // the grouper sorts by rank before evaluating (MsdrgFormulaEvaluation.evaluateFormulas)
        List<int[]> order = new ArrayList<>();
        for (int i = 0; i < rows.size(); i++) {
          order.add(new int[] {rows.get(i).getRank(), i});
        }
        order.sort((x, y) -> x[0] != y[0] ? Integer.compare(x[0], y[0]) : Integer.compare(x[1], y[1]));
        for (int[] o : order) {
          MsdrgDrgFormula f = rows.get(o[1]);
          all.add(f);
          Set<String> sup = new TreeSet<>();
          if (f.getSeveritySuppressionOperand() != null) {
            for (String s : f.getSeveritySuppressionOperand()) {
              if (s != null && !s.trim().isEmpty()) {
                sup.add(s.trim());
              }
            }
          }
          c.row(version, mdc, f.getRank(), o[1] + 1, f.getDrg(), f.getBaseDrg(), f.getSurgical(),
              f.getReRouteMdcId(), grcFromFormula(f.getFormula()), f.getFormula(),
              String.join("|", sup), f.getDrgSeverity(), f.getFormulaCollectionId());
          if (f.getMdc() != mdc) {
            System.out.println("WARNING: formula.mdc=" + f.getMdc() + " under key " + mdc);
          }
        }
      }
    }
    System.out.println("drg formulas: " + all.size() + " rows -> " + file);
    return all;
  }

  private static void dumpDescriptions(Path out, String p, DescriptionAccess da, int version)
      throws IOException {
    int n = 0;
    try (Csv c = new Csv(out.resolve(p + "hac_descriptions.csv"), "grouper_version", "hac_number",
        "description")) {
      for (int hac = 1; hac <= 30; hac++) {
        Optional<String> d = da.getHacDescription(hac);
        if (d.isPresent()) {
          n++;
          c.row(version, hac, d.get());
        }
      }
    }
    System.out.println("hac descriptions: " + n);
    n = 0;
    try (Csv c = new Csv(out.resolve(p + "mdc_descriptions.csv"), "grouper_version", "mdc",
        "description")) {
      for (int mdc = 0; mdc <= 29; mdc++) {
        Optional<String> d = da.getMdcDescription(mdc);
        if (d.isPresent()) {
          n++;
          c.row(version, mdc, d.get());
        }
      }
    }
    System.out.println("mdc descriptions: " + n);
    n = 0;
    try (Csv c = new Csv(out.resolve(p + "drg_descriptions.csv"), "grouper_version", "drg",
        "description", "base_drg_description")) {
      for (int drg = 0; drg <= 999; drg++) {
        Optional<String> d = da.getDrgDescription(drg);
        Optional<String> b = da.getBaseDrgDescription(drg);
        if (d.isPresent() || b.isPresent()) {
          n++;
          c.row(version, drg, d.orElse(""), b.orElse(""));
        }
      }
    }
    System.out.println("drg descriptions: " + n);
  }

  // ---------------------------------------------------------------------------------------------
  // clusters
  // ---------------------------------------------------------------------------------------------

  static final class ClusterDef {
    final String code;
    final Set<Integer> suppressionMdcs = new TreeSet<>();
    final Map<Integer, List<String>> choices = new TreeMap<>();
    final Set<String> codesFromIndex = new TreeSet<>(); // codes whose code->cluster index lists this cluster

    ClusterDef(String code) {
      this.code = code;
    }
  }

  /** Reads ClustersRoot / CodeToClusterIdRoot straight from runtime_buffers/msdrg_combined.bin. */
  static Map<String, ClusterDef> readClustersFromBlob(int version) throws IOException {
    Map<String, ClusterDef> defs = new TreeMap<>();
    Map<String, List<String>> codeIndex = new TreeMap<>();
    try (InputStream in = DataBlob.class.getResourceAsStream("/runtime_buffers/msdrg_combined.bin")) {
      CodedInputStream cis = CodedInputStream.newInstance(in);
      while (!cis.isAtEnd()) {
        int tag = cis.readTag();
        int field = tag >>> 3;
        if (field == Data.Root.CLUSTERS_FIELD_NUMBER) {
          Data.ClustersRoot root = Data.ClustersRoot.parseFrom(cis.readBytes());
          for (Map.Entry<String, Data.ClusterList> e : root.getClustersMap().entrySet()) {
            for (Data.ClusterData cd : e.getValue().getClusterList()) {
              boolean forVersion = false;
              for (Data.Version v : cd.getVersionsList()) {
                if (v.getNumber() == version) {
                  forVersion = true;
                }
              }
              if (!forVersion) {
                continue;
              }
              ClusterDef d = new ClusterDef(e.getKey());
              d.suppressionMdcs.addAll(cd.getSuppressionMdcsList());
              for (Data.ClusterChoice ch : cd.getChoicesList()) {
                d.choices.put(ch.getChoice(), new ArrayList<>(ch.getCodesList()));
              }
              ClusterDef prev = defs.get(e.getKey());
              if (prev != null) {
                // the blob can carry the same definition several times with overlapping version
                // lists (e.g. Z@1626); only complain when the content actually differs
                if (!prev.suppressionMdcs.equals(d.suppressionMdcs) || !prev.choices.equals(d.choices)) {
                  System.out.println("WARNING: cluster " + e.getKey()
                      + " has conflicting definitions for version " + version);
                } else {
                  duplicateDefinitions++;
                }
                continue;
              }
              defs.put(e.getKey(), d);
            }
          }
        } else if (field == Data.Root.CODETOCLUSTERIDS_FIELD_NUMBER) {
          Data.CodeToClusterIdRoot root = Data.CodeToClusterIdRoot.parseFrom(cis.readBytes());
          for (Map.Entry<String, Data.CodeToClusterInfos> e : root.getCodeToClusterIdsMap().entrySet()) {
            for (Data.CodeToClusterInfo info : e.getValue().getListList()) {
              boolean forVersion = false;
              for (Data.Version v : info.getVersionsList()) {
                if (v.getNumber() == version) {
                  forVersion = true;
                }
              }
              if (forVersion) {
                codeIndex.computeIfAbsent(e.getKey(), k -> new ArrayList<>()).addAll(info.getClusterIdsList());
              }
            }
          }
        } else {
          cis.skipField(tag);
        }
      }
    }
    for (Map.Entry<String, List<String>> e : codeIndex.entrySet()) {
      for (String cid : e.getValue()) {
        ClusterDef d = defs.get(cid);
        if (d == null) {
          System.out.println("WARNING: code " + e.getKey() + " points to unknown cluster " + cid);
        } else {
          d.codesFromIndex.add(e.getKey());
        }
      }
    }
    System.out.println("clusters in binary for version " + version + ": " + defs.size()
        + " (code->cluster index entries: " + codeIndex.size() + " codes; "
        + duplicateDefinitions + " identical duplicate definitions ignored)");
    return defs;
  }

  private static int duplicateDefinitions = 0;

  /** Re-derives every cluster through the public DAO (as MsdrgClusters does) and compares. */
  static void crossCheckClustersWithDao(Map<String, ClusterDef> defs, DataAccess access,
      ClusterAccess clusterAccess, int version) {
    List<String> allCodes = new ArrayList<>();
    for (ClusterDef d : defs.values()) {
      allCodes.addAll(d.codesFromIndex);
    }
    Set<MsdrgClusterDefinition> daoDefs = clusterAccess.getData(allCodes);
    int ok = 0;
    int bad = 0;
    Set<String> seen = new TreeSet<>();
    for (MsdrgClusterDefinition dd : daoDefs) {
      seen.add(dd.getClusterCode());
      ClusterDef d = defs.get(dd.getClusterCode());
      boolean good = d != null && d.suppressionMdcs.equals(new TreeSet<>(dd.getMdcRestrictions()))
          && d.choices.size() == dd.getChoiceCount();
      if (good) {
        ClusterChoices choices = dd.getChoices();
        for (Map.Entry<Integer, List<String>> ch : d.choices.entrySet()) {
          for (String code : ch.getValue()) {
            Optional<Integer> found = choices.contains(code);
            if (!found.isPresent() || !found.get().equals(ch.getKey())) {
              good = false;
            }
            if (access.getClusterId(code, version).stream().noneMatch(dd.getClusterCode()::equals)) {
              good = false;
            }
          }
        }
      }
      if (good) {
        ok++;
      } else {
        bad++;
        System.out.println("MISMATCH between raw protobuf and DAO for cluster " + dd.getClusterCode());
      }
    }
    for (String code : defs.keySet()) {
      if (!seen.contains(code)) {
        bad++;
        System.out.println("cluster " + code + " not reachable through ClusterAccess.getData");
      }
    }
    System.out.println("cluster DAO cross-check: " + ok + " identical, " + bad + " problems");
  }

  static String joinInts(Set<Integer> s) {
    StringBuilder sb = new StringBuilder();
    for (int i : s) {
      if (sb.length() > 0) {
        sb.append('|');
      }
      sb.append(i);
    }
    return sb.toString();
  }

  private static void dumpClusters(Path file, Map<String, ClusterDef> defs, int version)
      throws IOException {
    int n = 0;
    try (Csv c = new Csv(file, "grouper_version", "cluster_code", "n_choices", "choice", "proc_code",
        "suppression_mdcs", "code_indexed_to_cluster")) {
      for (ClusterDef d : defs.values()) {
        for (Map.Entry<Integer, List<String>> ch : d.choices.entrySet()) {
          for (String code : ch.getValue()) {
            n++;
            c.row(version, d.code, d.choices.size(), ch.getKey(), code, joinInts(d.suppressionMdcs),
                d.codesFromIndex.contains(code));
          }
        }
      }
    }
    System.out.println("cluster rows: " + n + " -> " + file);
  }

  /** PRCLSTRS: PROCCODE,CLUSTERCODE,CHOICE,NUMREQUIREDPROCS,MDCRESTRICTION */
  private static void compareWithPrclstrs(Path mapFile, Map<String, ClusterDef> defs, Path prclstrs)
      throws IOException {
    List<String> lines = Files.readAllLines(prclstrs, StandardCharsets.ISO_8859_1);
    Map<String, String> flatRestriction = new TreeMap<>();
    Map<String, Integer> flatRequired = new TreeMap<>();
    Set<String> flatTriples = new TreeSet<>();
    for (int i = 1; i < lines.size(); i++) {
      String line = lines.get(i).trim();
      if (line.isEmpty()) {
        continue;
      }
      String[] f = line.split(",", -1);
      String cluster = "Z" + f[1].trim();
      flatTriples.add(cluster + "," + f[2].trim() + "," + f[0].trim());
      flatRestriction.put(cluster, f.length > 4 ? f[4].trim() : "");
      flatRequired.put(cluster, Integer.parseInt(f[3].trim()));
    }
    Set<String> binTriples = new TreeSet<>();
    for (ClusterDef d : defs.values()) {
      for (Map.Entry<Integer, List<String>> ch : d.choices.entrySet()) {
        for (String code : ch.getValue()) {
          binTriples.add(d.code + "," + ch.getKey() + "," + code);
        }
      }
    }
    Set<String> onlyFlat = new TreeSet<>(flatTriples);
    onlyFlat.removeAll(binTriples);
    Set<String> onlyBin = new TreeSet<>(binTriples);
    onlyBin.removeAll(flatTriples);
    System.out.println("PRCLSTRS vs binary (cluster,choice,code) triples: flat=" + flatTriples.size()
        + " binary=" + binTriples.size() + " only-in-flat=" + onlyFlat.size() + " only-in-binary="
        + onlyBin.size());
    for (String s : onlyFlat) {
      System.out.println("  only in PRCLSTRS: " + s);
    }
    for (String s : onlyBin) {
      System.out.println("  only in binary:   " + s);
    }
    int reqMismatch = 0;
    for (ClusterDef d : defs.values()) {
      Integer req = flatRequired.get(d.code);
      if (req != null && req != d.choices.size()) {
        reqMismatch++;
        System.out.println("  NUMREQUIREDPROCS " + req + " != choices " + d.choices.size() + " for " + d.code);
      }
    }
    System.out.println("NUMREQUIREDPROCS vs number of choices: " + reqMismatch + " mismatches");

    // token string -> set of binary MDC sets seen
    Map<String, Map<String, Integer>> tokenMap = new TreeMap<>();
    for (ClusterDef d : defs.values()) {
      String tok = flatRestriction.get(d.code);
      if (tok == null) {
        continue;
      }
      tokenMap.computeIfAbsent(tok, k -> new TreeMap<>()).merge(joinInts(d.suppressionMdcs), 1, Integer::sum);
    }
    try (Csv c = new Csv(mapFile, "prclstrs_mdcrestriction", "binary_suppression_mdcs", "n_clusters")) {
      for (Map.Entry<String, Map<String, Integer>> e : tokenMap.entrySet()) {
        for (Map.Entry<String, Integer> v : e.getValue().entrySet()) {
          c.row(e.getKey(), v.getKey(), v.getValue());
          System.out.println("  MDCRESTRICTION '" + e.getKey() + "' -> binary {" + v.getKey() + "} (" + v.getValue() + " clusters)");
        }
      }
    }
  }

  /** DRGLOGIC: MDC,DRG,MEDSURG,BASEDRG,RETURNCODE,REROUTEMDC,FORMULA,SUPPRESSION (CSV, quoted fields) */
  private static void compareWithDrglogic(List<MsdrgDrgFormula> binRows, Path drglogic)
      throws IOException {
    List<String> lines = Files.readAllLines(drglogic, StandardCharsets.ISO_8859_1);
    List<String[]> flat = new ArrayList<>();
    for (int i = 1; i < lines.size(); i++) {
      String line = lines.get(i);
      if (line.trim().isEmpty()) {
        continue;
      }
      flat.add(parseCsvLine(line));
    }
    // The binary has one extra "MDCnn" gate row per MDC (formula "MDC05" etc., drg 0) that the
    // flat file does not carry; drop them before the row-by-row comparison.
    List<MsdrgDrgFormula> bin = new ArrayList<>();
    int gates = 0;
    for (MsdrgDrgFormula b : binRows) {
      if (b.getFormula() != null && b.getFormula().trim().matches("MDC\\d\\d")) {
        gates++;
      } else {
        bin.add(b);
      }
    }
    System.out.println("DRGLOGIC rows: " + flat.size() + "; binary formula rows: " + binRows.size()
        + " (" + gates + " MDCnn gate rows excluded -> " + bin.size() + ")");
    // Normalised row keys in the flat file's own encoding:
    //   MDC,DRG,MEDSURG,BASEDRG,RETURNCODE,REROUTEMDC,FORMULA,SUPPRESSION
    // The flat file writes DRG 999 on return-code rows where the binary stores drg 0 (the grouper
    // assigns 999 from the GRC), so error rows are normalised to DRG 999 on both sides.
    List<String> flatKeys = new ArrayList<>();
    for (String[] f : flat) {
      flatKeys.add(String.join(",", f[0].trim(), f[1].trim(), f[2].trim(), f[3].trim(), f[4].trim(),
          f[5].trim(), f[6].trim(), normaliseSuppression(f[7])));
    }
    List<String> binKeys = new ArrayList<>();
    for (MsdrgDrgFormula b : bin) {
      String bsurg = b.getSurgical() == null ? "" : b.getSurgical().trim();
      String medsurg = bsurg.equals("MEDICAL") ? "M" : bsurg.equals("SURGICAL") ? "S" : bsurg.equals("NA") ? "" : bsurg;
      String rc = grcFromFormula(b.getFormula());
      int drg = b.getDrg() == 0 && !rc.equals("0") ? 999 : b.getDrg();
      Set<String> sup = new TreeSet<>();
      if (b.getSeveritySuppressionOperand() != null) {
        for (String s : b.getSeveritySuppressionOperand()) {
          if (s != null && !s.trim().isEmpty()) {
            sup.add(s.trim());
          }
        }
      }
      binKeys.add(String.join(",", String.valueOf(b.getMdc()), String.valueOf(drg), medsurg,
          String.valueOf(b.getBaseDrg()), rc, String.valueOf(b.getReRouteMdcId()),
          b.getFormula() == null ? "" : b.getFormula().trim(), String.join("|", sup)));
    }
    Map<String, Integer> flatCount = new LinkedHashMap<>();
    for (String k : flatKeys) {
      flatCount.merge(k, 1, Integer::sum);
    }
    Map<String, Integer> binCount = new LinkedHashMap<>();
    for (String k : binKeys) {
      binCount.merge(k, 1, Integer::sum);
    }
    List<String> onlyFlat = new ArrayList<>();
    for (Map.Entry<String, Integer> e : flatCount.entrySet()) {
      int d = e.getValue() - binCount.getOrDefault(e.getKey(), 0);
      for (int i = 0; i < d; i++) {
        onlyFlat.add(e.getKey());
      }
    }
    List<String> onlyBin = new ArrayList<>();
    for (Map.Entry<String, Integer> e : binCount.entrySet()) {
      int d = e.getValue() - flatCount.getOrDefault(e.getKey(), 0);
      for (int i = 0; i < d; i++) {
        onlyBin.add(e.getKey());
      }
    }
    for (String s : onlyFlat) {
      System.out.println("  only in DRGLOGIC: " + s);
    }
    for (String s : onlyBin) {
      System.out.println("  only in binary:   " + s);
    }
    // order of the common rows
    List<String> flatCommon = new ArrayList<>();
    for (String k : flatKeys) {
      if (binCount.containsKey(k)) {
        flatCommon.add(k);
      }
    }
    List<String> binCommon = new ArrayList<>();
    for (String k : binKeys) {
      if (flatCount.containsKey(k)) {
        binCommon.add(k);
      }
    }
    boolean sameOrder = flatCommon.equals(binCommon);
    System.out.println("DRGLOGIC vs binary (gate rows excluded; MEDICAL/SURGICAL/NA read as M/S/blank; "
        + "return code derived from GRC tokens; error rows normalised to DRG 999): common rows "
        + flatCommon.size() + ", only in DRGLOGIC " + onlyFlat.size() + ", only in binary " + onlyBin.size()
        + ", evaluation order of common rows identical: " + sameOrder);
  }

  static String normaliseSuppression(String s) {
    Set<String> sup = new TreeSet<>();
    for (String t : s.split("\\|")) {
      if (!t.trim().isEmpty()) {
        sup.add(t.trim());
      }
    }
    return String.join("|", sup);
  }

  static String[] parseCsvLine(String line) {
    List<String> out = new ArrayList<>();
    StringBuilder sb = new StringBuilder();
    boolean q = false;
    for (int i = 0; i < line.length(); i++) {
      char ch = line.charAt(i);
      if (q) {
        if (ch == '"') {
          if (i + 1 < line.length() && line.charAt(i + 1) == '"') {
            sb.append('"');
            i++;
          } else {
            q = false;
          }
        } else {
          sb.append(ch);
        }
      } else if (ch == '"') {
        q = true;
      } else if (ch == ',') {
        out.add(sb.toString());
        sb.setLength(0);
      } else if (ch != '\r') {
        sb.append(ch);
      }
    }
    out.add(sb.toString());
    while (out.size() < 8) {
      out.add("");
    }
    return out.toArray(new String[0]);
  }
}
