package oracle;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/** Minimal RFC-4180 CSV writer (UTF-8, LF line endings, quotes only when needed). */
public final class Csv implements AutoCloseable {

  private final BufferedWriter w;
  private final int ncol;

  public Csv(Path file, String... header) throws IOException {
    this.w = Files.newBufferedWriter(file, StandardCharsets.UTF_8);
    this.ncol = header.length;
    row((Object[]) header);
  }

  public static String q(Object v) {
    if (v == null) {
      return "";
    }
    String s = v.toString();
    boolean needs = s.indexOf(',') >= 0 || s.indexOf('"') >= 0 || s.indexOf('\n') >= 0
        || s.indexOf('\r') >= 0 || (!s.isEmpty() && (s.charAt(0) == ' '
        || s.charAt(s.length() - 1) == ' '));
    if (!needs) {
      return s;
    }
    return "\"" + s.replace("\"", "\"\"") + "\"";
  }

  public void row(Object... cells) throws IOException {
    if (cells.length != ncol) {
      throw new IllegalArgumentException("expected " + ncol + " cells, got " + cells.length);
    }
    StringBuilder sb = new StringBuilder();
    for (int i = 0; i < cells.length; i++) {
      if (i > 0) {
        sb.append(',');
      }
      sb.append(q(cells[i]));
    }
    sb.append('\n');
    w.write(sb.toString());
  }

  @Override
  public void close() throws IOException {
    w.close();
  }
}
