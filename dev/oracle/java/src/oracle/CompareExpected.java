package oracle;

import java.io.IOException;
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
 * Compares two expected-results CSVs (same layout, keyed by claim_id) and writes one row per claim
 * whose compared columns differ, plus a per-column difference count on stdout.
 *
 * CompareExpected A.csv B.csv OUT.csv [label_a label_b] [col1,col2,...]
 */
public final class CompareExpected {

  private CompareExpected() {
  }

  static final String[] DEFAULT_COLS = {"final_grc", "final_mdc", "final_drg", "final_severity",
      "initial_drg", "hac_status", "num_hac_categories_satisfied", "grouper_flags_mf"};

  public static void main(String[] argv) throws IOException {
    Path fa = Paths.get(argv[0]);
    Path fb = Paths.get(argv[1]);
    Path out = Paths.get(argv[2]);
    String la = argv.length > 3 ? argv[3] : "a";
    String lb = argv.length > 4 ? argv[4] : "b";
    String[] cols = argv.length > 5 ? argv[5].split(",") : DEFAULT_COLS;

    Map<String, String[]> a = read(fa);
    Map<String, String[]> b = read(fb);
    String[] ha = header(fa);
    String[] hb = header(fb);
    Map<String, Integer> ia = index(ha);
    Map<String, Integer> ib = index(hb);
    for (String c : cols) {
      if (!ia.containsKey(c) || !ib.containsKey(c)) {
        throw new IllegalArgumentException("column " + c + " missing in one of the files");
      }
    }
    List<String> hdr = new ArrayList<>();
    hdr.add("claim_id");
    for (String c : cols) {
      hdr.add(c + "_" + la);
      hdr.add(c + "_" + lb);
    }
    hdr.add("differing_columns");
    Map<String, Integer> perCol = new TreeMap<>();
    int differing = 0;
    int compared = 0;
    try (Csv csv = new Csv(out, hdr.toArray(new String[0]))) {
      for (Map.Entry<String, String[]> e : a.entrySet()) {
        String[] rb = b.get(e.getKey());
        if (rb == null) {
          continue;
        }
        compared++;
        List<Object> row = new ArrayList<>();
        row.add(e.getKey());
        List<String> diff = new ArrayList<>();
        for (String c : cols) {
          String va = e.getValue()[ia.get(c)];
          String vb = rb[ib.get(c)];
          row.add(va);
          row.add(vb);
          if (!va.equals(vb)) {
            diff.add(c);
            perCol.merge(c, 1, Integer::sum);
          }
        }
        if (!diff.isEmpty()) {
          differing++;
          row.add(String.join("|", diff));
          csv.row(row.toArray());
        }
      }
    }
    System.out.println("compared " + compared + " claims: " + differing + " differ in at least one of "
        + String.join(",", cols) + " -> " + out);
    for (Map.Entry<String, Integer> e : perCol.entrySet()) {
      System.out.println("  " + e.getKey() + ": " + e.getValue());
    }
  }

  static String[] header(Path f) throws IOException {
    try (var lines = Files.lines(f, StandardCharsets.UTF_8)) {
      return DataDump.parseCsvLine(lines.findFirst().orElse(""));
    }
  }

  static Map<String, Integer> index(String[] header) {
    Map<String, Integer> m = new LinkedHashMap<>();
    for (int i = 0; i < header.length; i++) {
      m.put(header[i], i);
    }
    return m;
  }

  static Map<String, String[]> read(Path f) throws IOException {
    Map<String, String[]> m = new LinkedHashMap<>();
    List<String> lines = Files.readAllLines(f, StandardCharsets.UTF_8);
    for (int i = 1; i < lines.size(); i++) {
      if (lines.get(i).isEmpty()) {
        continue;
      }
      String[] r = DataDump.parseCsvLine(lines.get(i));
      m.put(r[0], r);
    }
    return m;
  }
}
