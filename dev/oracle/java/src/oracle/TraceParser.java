package oracle;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Parses the text emitted by the grouper's TraceUtility (runtime option MsdrgOption.TRACE) for one
 * claim. The trace is the only public channel that exposes the procedure clusters recognised on a
 * claim, the per-code attributes, the MDCs visited and the DRG/HAC formulas that matched.
 */
public final class TraceParser {

  public static final class CodeInfo {
    public String kind;          // PDX | SDX | PROC | CLUSTER
    public String code = "";
    public String poa = "";
    public String mdc = "";
    public String dxcat = "";
    public String clinSig = "";
    public String severity = "";
    public String hac = "";
    public List<String> attributes = new ArrayList<>();
    public List<String> clusterIds = new ArrayList<>();
    public String mdcSuppression = "";
    boolean used;
  }

  public static final class Match {
    public String mdc = "";
    public String drg = "";
    public String formula = "";
    public String attributes = "";
  }

  public static final class Pass {
    public final List<String> mdcPath = new ArrayList<>();
    public final List<Match> matches = new ArrayList<>();
  }

  public final List<CodeInfo> codes = new ArrayList<>();
  public final Pass initial = new Pass();
  public final Pass fin = new Pass();
  public final List<String> hacFormulas = new ArrayList<>();

  private static String between(String s, String start, String end) {
    int i = s.indexOf(start);
    if (i < 0) {
      return "";
    }
    i += start.length();
    int j = end == null ? s.length() : s.indexOf(end, i);
    if (j < 0) {
      j = s.length();
    }
    return s.substring(i, j);
  }

  /** value of "\tKEY:..." up to the next tab (or end). */
  private static String field(String line, String key) {
    int i = line.indexOf(key);
    if (i < 0) {
      return "";
    }
    i += key.length();
    int j = line.indexOf('\t', i);
    return (j < 0 ? line.substring(i) : line.substring(i, j)).trim();
  }

  private static List<String> attrs(String bracketed) {
    List<String> out = new ArrayList<>();
    for (String a : bracketed.split("\t")) {
      if (!a.trim().isEmpty()) {
        out.add(a.trim());
      }
    }
    return out;
  }

  private static List<String> listOf(String inner) {
    // inner looks like "Z@7093, Z@0037" or ""
    List<String> out = new ArrayList<>();
    for (String a : inner.split(",")) {
      if (!a.trim().isEmpty()) {
        out.add(a.trim());
      }
    }
    return out;
  }

  /**
   * Value of "KEY:[...]" in a trace line. The grouper nests collections, e.g. "HAC:[[HAC_10]]",
   * "inCluster:[[Z@7093]]", "MDC Suppression:[{10, 29}]"; all wrapping brackets/braces are removed
   * and the elements are returned "|"-joined.
   */
  private static String bracketField(String line, String key) {
    int i = line.indexOf(key + "[");
    if (i < 0) {
      return "";
    }
    i += key.length() + 1;
    int depth = 1;
    int j = i;
    while (j < line.length() && depth > 0) {
      char ch = line.charAt(j);
      if (ch == '[' || ch == '{') {
        depth++;
      } else if (ch == ']' || ch == '}') {
        depth--;
      }
      j++;
    }
    String s = line.substring(i, Math.max(i, j - 1));
    s = s.replaceAll("^[\\[{\\s]+", "").replaceAll("[\\]}\\s]+$", "");
    List<String> parts = new ArrayList<>();
    for (String p : s.split("[,\t]")) {
      if (!p.trim().isEmpty()) {
        parts.add(p.trim());
      }
    }
    return String.join("|", parts);
  }

  public static TraceParser parse(String trace) {
    TraceParser t = new TraceParser();
    Pass pass = t.initial;
    String currentMdc = "";
    Match lastMatch = null;
    for (String line : trace.split("\n")) {
      if (line.startsWith("PROC:")) {
        CodeInfo c = new CodeInfo();
        c.kind = "PROC";
        c.code = field(line, "PROC:");
        c.attributes = attrs(between(line, "Attributes:[", "]"));
        c.hac = bracketField(line, "HAC:");
        c.clusterIds = listOf(bracketField(line, "inCluster:").replace('|', ','));
        t.codes.add(c);
      } else if (line.startsWith("CLUSTER:")) {
        CodeInfo c = new CodeInfo();
        c.kind = "CLUSTER";
        c.code = field(line, "CLUSTER:");
        c.attributes = attrs(between(line, "Attributes:[", "]"));
        c.hac = bracketField(line, "HAC:");
        c.mdcSuppression = bracketField(line, "MDC Suppression:");
        t.codes.add(c);
      } else if (line.startsWith("SDX:")) {
        CodeInfo c = new CodeInfo();
        c.kind = "SDX";
        c.code = field(line, "SDX:");
        c.poa = field(line, "POA:");
        c.clinSig = field(line, "clinSig:");
        if (c.clinSig.equals("null")) {
          c.clinSig = "";
        }
        c.attributes = attrs(between(line, "Attributes:[", "]"));
        c.severity = between(line, "Sev:[", "]");
        c.hac = bracketField(line, "HAC:");
        t.codes.add(c);
      } else if (line.startsWith("PDX:")) {
        CodeInfo c = new CodeInfo();
        c.kind = "PDX";
        c.code = field(line, "PDX:");
        c.poa = field(line, "POA:");
        c.mdc = field(line, "MDC:");
        c.dxcat = field(line, "DXCAT:");
        c.attributes = attrs(between(line, "Attributes:[", "]"));
        t.codes.add(c);
      } else if (line.startsWith("\tAnalyzing MDC ")) {
        currentMdc = between(line, "Analyzing MDC ", " with mask").trim();
        pass.mdcPath.add(currentMdc);
      } else if (line.startsWith("\t\t->Match on DRG ")) {
        Match m = new Match();
        m.mdc = currentMdc;
        m.drg = between(line, "->Match on DRG ", " with formula").trim();
        m.formula = between(line, "with formula [", null).replaceAll("\\]$", "").trim();
        lastMatch = m;
        if (!m.formula.equals("null")) {
          pass.matches.add(m);
        }
      } else if (line.startsWith("\t\t\t\t**Matched on attributes:")) {
        if (lastMatch != null) {
          lastMatch.attributes = line.substring(line.indexOf(':') + 1).trim();
        }
      } else if (line.startsWith("\t\t->Match on HAC ")) {
        // traceHac() appends its "\t\t\tSDX :..." detail to the same line without a newline
        String f = between(line, "with formula (", null);
        int tab = f.indexOf('\t');
        if (tab >= 0) {
          f = f.substring(0, tab);
        }
        f = f.trim().replaceAll("\\)$", "");
        t.hacFormulas.add("HAC " + between(line, "->Match on HAC ", " with formula").trim() + " (" + f + ")");
      } else if (line.startsWith("***INITIAL DRG Grouping Results")) {
        pass = t.fin;
        currentMdc = "";
      }
    }
    return t;
  }

  /** First not-yet-consumed trace entry of the given kind and code. */
  public CodeInfo take(String kind, String code) {
    for (CodeInfo c : codes) {
      if (!c.used && c.kind.equals(kind) && c.code.equals(code)) {
        c.used = true;
        return c;
      }
    }
    return null;
  }

  public List<CodeInfo> clusters() {
    List<CodeInfo> out = new ArrayList<>();
    for (CodeInfo c : codes) {
      if (c.kind.equals("CLUSTER")) {
        out.add(c);
      }
    }
    return out;
  }

  public static String join(List<String> l, String sep) {
    return String.join(sep, l);
  }

  public static String matches(Pass p) {
    StringBuilder sb = new StringBuilder();
    for (Match m : p.matches) {
      if (sb.length() > 0) {
        sb.append(';');
      }
      sb.append("MDC").append(m.mdc).append(":DRG").append(m.drg).append(":[").append(m.formula).append(']');
    }
    return sb.toString();
  }

  public static String matchedAttributes(Pass p) {
    StringBuilder sb = new StringBuilder();
    for (Match m : p.matches) {
      if (sb.length() > 0) {
        sb.append(';');
      }
      sb.append(m.attributes);
    }
    return sb.toString();
  }

  public static Map<String, String> clusterSummary(List<CodeInfo> clusters) {
    Map<String, String> m = new LinkedHashMap<>();
    for (CodeInfo c : clusters) {
      m.put(c.code, c.mdcSuppression);
    }
    return m;
  }
}
