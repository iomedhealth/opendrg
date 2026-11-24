package oracle;

import gov.agency.msdrg.model.v2.MsdrgGrouperFlags;
import gov.agency.msdrg.model.v2.MsdrgHac;
import gov.agency.msdrg.model.v2.enumeration.MsdrgCodeSeverityFlag;
import gov.agency.msdrg.model.v2.enumeration.MsdrgHacStatus;
import gov.agency.msdrg.model.v2.enumeration.MsdrgMedSurgType;
import gov.agency.msdrg.model.v2.enumeration.MsdrgProcedureHacUsage;
import gov.agency.msdrg.model.v2.enumeration.MsdrgSeverity;
import gov.agency.msdrg.model.v2.transfer.output.MsdrgOutputData;
import gov.agency.msdrg.model.v2.transfer.output.MsdrgOutputDxCode;
import gov.agency.msdrg.model.v2.transfer.output.MsdrgOutputPrCode;
import java.util.ArrayList;
import java.util.List;

/**
 * Re-creates the 1162-byte mainframe output record (PBL-060 table 28) from the v2 API output,
 * following gov.cms.grouper.mainframe.MsdrgMainframeWrapper (extractFromClaimWithModelV2,
 * mapGrouperFlagOutputWithModelV2, mapDxFlagOutputWithModelV2). Used to compare the API run
 * byte-for-byte against the expectations embedded in TESTDB and against the wrapper itself.
 *
 * <pre>
 *   1-2      RTC            final grouper return code, zero padded
 *   3-4      MDC            final MDC
 *   5-8      DRG            final DRG
 *   9-13     GRFLGS         nHAC(2) finalCcMccImpact(1) initialCcMccImpact(1) hacStatus(1)
 *   14-638   DXFLGS         25 chars per dx: [pdx, sdx...], space filled
 *   639-1138 PRFLGS         20 chars per pr, space filled
 *   1139-1142 final base DRG
 *   1143     final severity level (1 MCC, 2 CC, 3 non-CC, 0 none)
 *   1144     final med/surg (1 medical, 2 surgical, 0 none)
 *   1145-1148 initial DRG
 *   1149-1152 initial base DRG
 *   1153     initial severity level
 *   1154     initial med/surg
 *   1155-1162 version id "001" + VVV + "00"
 * </pre>
 */
public final class LegacyFormat {

  private LegacyFormat() {
  }

  public static String versionId(int version) {
    return "001" + version + "00";
  }

  private static String ccMccImpact(MsdrgSeverity s) {
    if (s == null) {
      return "0";
    }
    String v = String.valueOf(s.getSeverityLevel());
    if (v.equals("5")) {
      return "2";
    }
    if (v.equals("3")) {
      return "0";
    }
    return v;
  }

  public static String hacStatusDigit(MsdrgHacStatus h) {
    if (h == null) {
      return "0";
    }
    switch (h) {
      case FINAL_DRG_NO_CHANGE:
        return "1";
      case FINAL_DRG_CHANGES:
        return "2";
      case FINAL_DRG_UNGROUPABLE:
        return "3";
      default:
        return "0";
    }
  }

  /** The 5-character GRFLGS field (PBL-060 table 5). */
  public static String grouperFlags(MsdrgOutputData out) {
    MsdrgGrouperFlags gf = out.getGrouperFlags();
    StringBuilder sb = new StringBuilder();
    sb.append(String.format("%2d", gf.getNumHacCategoriesSatisfied()).replace(' ', '0'));
    sb.append(ccMccImpact(gf.getFinalDrgSecondaryDxCcMcc()));
    sb.append(ccMccImpact(gf.getInitialDrgSecondaryDxCcMcc()));
    sb.append(hacStatusDigit(gf.getHacStatusValue()));
    return sb.toString();
  }

  /** CC/MCC categorization digit (PBL-060 table 6 position 3). */
  public static String ccMccCategory(MsdrgCodeSeverityFlag fin, MsdrgCodeSeverityFlag ini) {
    if (fin == MsdrgCodeSeverityFlag.NEITHER && ini == MsdrgCodeSeverityFlag.MCC) {
      return "3";
    } else if (fin == MsdrgCodeSeverityFlag.NEITHER && ini == MsdrgCodeSeverityFlag.CC) {
      return "4";
    } else if (fin == MsdrgCodeSeverityFlag.MCC_EXCLUDED) {
      return "5";
    } else if (fin == MsdrgCodeSeverityFlag.CC_EXCLUDED) {
      return "6";
    } else if (fin == MsdrgCodeSeverityFlag.MCC_EXCLUDED_BY_DRG_LOGIC) {
      return "7";
    } else if (fin == MsdrgCodeSeverityFlag.CC_EXCLUDED_BY_DRG_LOGIC) {
      return "8";
    } else if (fin == MsdrgCodeSeverityFlag.MCC && ini == MsdrgCodeSeverityFlag.MCC) {
      return "1";
    } else if (fin == MsdrgCodeSeverityFlag.CC && ini == MsdrgCodeSeverityFlag.CC) {
      return "2";
    }
    return "0";
  }

  /** The 25-character per-diagnosis flag block (PBL-060 table 6). */
  public static String dxFlags(MsdrgOutputDxCode dx) {
    if (!dx.isDiagnosisRecognizedByGrouper()) {
      return String.format("%-25d", 0);
    }
    StringBuilder sb = new StringBuilder();
    sb.append('1');
    sb.append(dx.getDiagnosisAffectsDrg().intValue());
    sb.append(ccMccCategory(dx.getFinalSeverityUsage(), dx.getInitialSeverityUsage()));
    List<MsdrgHac> hacs = dx.getHacs();
    for (int i = 0; i < 5; i++) {
      if (i < hacs.size()) {
        MsdrgHac h = hacs.get(i);
        sb.append(String.format("%02d", h.getHacNumber()));
        sb.append(h.getHacStatus().getIntValue());
      } else {
        sb.append("000");
      }
    }
    sb.append("0000000");
    return sb.toString();
  }

  /** The 20-character per-procedure flag block (PBL-060 table 7). */
  public static String prFlags(MsdrgOutputPrCode pr) {
    if (!pr.isProcedureRecognizedByGrouper()) {
      return String.format("%-20d", 0);
    }
    StringBuilder sb = new StringBuilder();
    sb.append('1');
    sb.append(pr.getProcedureAffectsDrg().intValue());
    sb.append(pr.isProcedureIsOperatingRoomProcedure() ? 1 : 0);
    for (MsdrgProcedureHacUsage u : pr.getHacUsage()) {
      sb.append(String.format("%02d", u.getIntValue()));
    }
    while (sb.length() < 20) {
      sb.append('0');
    }
    return sb.toString();
  }

  public static int severityLevel(MsdrgSeverity s) {
    return s == null ? 0 : s.getSeverityLevel();
  }

  public static int medSurgInt(MsdrgMedSurgType t) {
    return t == null ? 0 : t.getIntValue();
  }

  private static String padRight(String s, int width) {
    StringBuilder sb = new StringBuilder(s);
    while (sb.length() < width) {
      sb.append(' ');
    }
    return sb.substring(0, width);
  }

  /** Ordered list of dx outputs as the mainframe reports them: principal first, then secondaries. */
  public static List<MsdrgOutputDxCode> dxOutputs(MsdrgOutputData out) {
    List<MsdrgOutputDxCode> all = new ArrayList<>(out.getSdxOutput());
    all.add(0, out.getPdxOutput());
    return all;
  }

  public static String format(MsdrgOutputData out, int version) {
    StringBuilder sb = new StringBuilder(TestdbRecord.OUTPUT_LEN);
    sb.append(String.format("%02d", out.getFinalGrc().getGrouperReturnCode()));
    sb.append(String.format("%02d", out.getFinalMdc().getValue()));
    sb.append(String.format("%04d", out.getFinalDrg().getValue()));
    sb.append(grouperFlags(out));
    StringBuilder dx = new StringBuilder();
    for (MsdrgOutputDxCode d : dxOutputs(out)) {
      dx.append(dxFlags(d));
    }
    sb.append(padRight(dx.toString(), 625));
    StringBuilder pr = new StringBuilder();
    for (MsdrgOutputPrCode p : out.getProcOutput()) {
      pr.append(prFlags(p));
    }
    sb.append(padRight(pr.toString(), 500));
    sb.append(String.format("%04d", out.getFinalBaseDrg().getValue()));
    sb.append(severityLevel(out.getFinalSeverity()));
    sb.append(medSurgInt(out.getFinalMedSugType()));
    sb.append(String.format("%04d", out.getInitialDrg().getValue()));
    sb.append(String.format("%04d", out.getInitialBaseDrg().getValue()));
    sb.append(severityLevel(out.getInitialSeverity()));
    sb.append(medSurgInt(out.getInitialMedSugType()));
    sb.append(padRight(versionId(version), 8));
    return sb.toString();
  }
}
