package oracle;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * One 2000-byte TESTDB record (layout: PBL-060 table 15, 1-based column positions).
 *
 * <pre>
 *   1-3     AGE              Age on admission, in years
 *   4       SEX              0 unknown, 1 male, 2 female
 *   5-6     DISCHARGE STATUS
 *   7       POALOG           POA logic indicator: X exempt, Z requires POA reporting
 *   8-15    ADATE            Admission date YYYYMMDD (not used by the grouper)
 *   16-23   DDATE            Discharge date YYYYMMDD (used only to select the grouper version)
 *   24-223  DX1-25           25 x 8: 7-char code left-justified + 1-char POA
 *   224-398 PROC1-25         25 x 7
 *   399-598 PRDATES          25 x 8 (blank in TESTDB)
 *   599-637 CLAIM-OPT-DATA   39-byte free-text description
 *   638     DEBUG-IND
 *   639-838 FILLER
 *   839-840 RTC              expected grouper return code
 *   841-842 MDC              expected final MDC
 *   843-846 DRG              expected final DRG
 *   847-851 GRFLGS           expected grouper flags
 *   852-1476 DXFLGS          25 x 25 expected diagnosis flags
 *   1477-1976 PRFLGS         25 x 20 expected procedure flags
 *   1977-2000 BUFF           ancillary buffer: final base DRG(4) sev(1) ms(1) init DRG(4)
 *                            init base DRG(4) init sev(1) init ms(1) version(8)
 * </pre>
 */
public final class TestdbRecord {

  public static final int LRECL = 2000;
  public static final int INPUT_LEN = 638;
  public static final int OUTPUT_START = 839;
  public static final int OUTPUT_LEN = 1162;
  public static final int MAX_DX = 25;
  public static final int MAX_PR = 25;

  public final int claimId;
  public final int rawLength;
  private final String rec;

  private TestdbRecord(int claimId, String line) {
    this.claimId = claimId;
    this.rawLength = line.length();
    if (line.length() < LRECL) {
      StringBuilder sb = new StringBuilder(line);
      while (sb.length() < LRECL) {
        sb.append(' ');
      }
      this.rec = sb.toString();
    } else {
      this.rec = line.substring(0, LRECL);
    }
  }

  public static List<TestdbRecord> readAll(Path file) throws IOException {
    byte[] bytes = Files.readAllBytes(file);
    String text = new String(bytes, StandardCharsets.ISO_8859_1);
    List<TestdbRecord> out = new ArrayList<>();
    int start = 0;
    int id = 0;
    while (start < text.length()) {
      int nl = text.indexOf('\n', start);
      String line = nl < 0 ? text.substring(start) : text.substring(start, nl);
      if (line.endsWith("\r")) {
        line = line.substring(0, line.length() - 1);
      }
      start = nl < 0 ? text.length() : nl + 1;
      if (line.isEmpty() && start >= text.length()) {
        break;
      }
      out.add(new TestdbRecord(++id, line));
    }
    return out;
  }

  /** 1-based inclusive column slice. */
  public String col(int from, int to) {
    return rec.substring(from - 1, to);
  }

  public boolean lengthOk() {
    return rawLength == LRECL;
  }

  public String inputRecord() {
    return rec.substring(0, INPUT_LEN);
  }

  public String embeddedOutput() {
    return rec.substring(OUTPUT_START - 1, OUTPUT_START - 1 + OUTPUT_LEN);
  }

  public String ageRaw() {
    return col(1, 3);
  }

  public String sexRaw() {
    return col(4, 4);
  }

  public String dischargeStatusRaw() {
    return col(5, 6);
  }

  public String poaLogic() {
    return col(7, 7);
  }

  public String admitDate() {
    return col(8, 15);
  }

  public String dischargeDate() {
    return col(16, 23);
  }

  /** 1-based slot. Returns the 7-char code (untrimmed). */
  public String dxCode(int slot) {
    int s = 24 + (slot - 1) * 8;
    return col(s, s + 6);
  }

  public String dxPoa(int slot) {
    int s = 24 + (slot - 1) * 8;
    return col(s + 7, s + 7);
  }

  public String prCode(int slot) {
    int s = 224 + (slot - 1) * 7;
    return col(s, s + 6);
  }

  public String prDate(int slot) {
    int s = 399 + (slot - 1) * 8;
    return col(s, s + 7);
  }

  public String optData() {
    return col(599, 637);
  }

  public String debugInd() {
    return col(638, 638);
  }

  public String filler() {
    return col(639, 838);
  }

  // ---- embedded expected results ----

  public String expRtc() {
    return col(839, 840);
  }

  public String expMdc() {
    return col(841, 842);
  }

  public String expDrg() {
    return col(843, 846);
  }

  public String expGrouperFlags() {
    return col(847, 851);
  }

  public String expDxFlags(int block) {
    int s = 852 + (block - 1) * 25;
    return col(s, s + 24);
  }

  public String expPrFlags(int block) {
    int s = 1477 + (block - 1) * 20;
    return col(s, s + 19);
  }

  public String expFinalBaseDrg() {
    return col(1977, 1980);
  }

  public String expFinalSeverity() {
    return col(1981, 1981);
  }

  public String expFinalMedSurg() {
    return col(1982, 1982);
  }

  public String expInitialDrg() {
    return col(1983, 1986);
  }

  public String expInitialBaseDrg() {
    return col(1987, 1990);
  }

  public String expInitialSeverity() {
    return col(1991, 1991);
  }

  public String expInitialMedSurg() {
    return col(1992, 1992);
  }

  public String expVersionId() {
    return col(1993, 2000);
  }
}
