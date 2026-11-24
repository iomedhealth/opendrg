package oracle;

import com.mmm.his.cer.foundation.model.GfcPoa;
import gov.agency.msdrg.model.v2.enumeration.MsdrgDischargeStatus;
import gov.agency.msdrg.model.v2.enumeration.MsdrgHospitalStatusOptionFlag;
import gov.agency.msdrg.model.v2.enumeration.MsdrgSex;
import gov.agency.msdrg.model.v2.transfer.input.MsdrgInput;
import gov.agency.msdrg.model.v2.transfer.input.MsdrgInputDxCode;
import gov.agency.msdrg.model.v2.transfer.input.MsdrgInputPrCode;
import java.util.ArrayList;
import java.util.List;

/**
 * Maps a TESTDB record to the MS-DRG v2 input model, replicating what CMS's mainframe wrapper
 * (gov.cms.grouper.mainframe.MsdrgMainframeWrapper#populateClaimWithModelV2) does:
 *
 * <ul>
 *   <li>age: Integer.parseInt of the raw 3 bytes; any parse failure leaves the builder default (0)</li>
 *   <li>sex: parseInt; 1 = MALE, 2 = FEMALE, anything else (incl. blank/0) = UNKNOWN</li>
 *   <li>discharge status: parseInt then MsdrgDischargeStatus.getEnumFromInt; parse failure = not set</li>
 *   <li>dx slots: 7-char code trimmed; blank slots are skipped (list is compacted); slot 1 is the
 *       principal dx; POA = 8th char, blank = GfcPoa.BLANK, unknown chars = GfcPoa.BLANK</li>
 *   <li>pr slots: 7-char code trimmed; blank slots skipped</li>
 *   <li>ageDaysAdmit / ageDaysDischarge = -1; admission dx never set</li>
 *   <li>hospital POA status: 'X' = EXEMPT, anything else = NON_EXEMPT</li>
 * </ul>
 *
 * With {@code lenientNumeric} the age/sex/discharge-status fields are trimmed before parsing
 * (so a left-justified "55 " becomes 55 instead of 0). Default is the wrapper-identical strict mode.
 */
public final class ClaimMapper {

  public static final class DxEntry {
    public final int seq;      // 0 = principal, 1.. = secondary (order passed to the grouper)
    public final int slot;     // 1..25 original position in the record
    public final String code;
    public final String poaRaw;
    public final GfcPoa poa;

    DxEntry(int seq, int slot, String code, String poaRaw, GfcPoa poa) {
      this.seq = seq;
      this.slot = slot;
      this.code = code;
      this.poaRaw = poaRaw;
      this.poa = poa;
    }
  }

  public static final class PrEntry {
    public final int seq;      // 1.. order passed to the grouper
    public final int slot;     // 1..25 original position in the record
    public final String code;
    public final String date;

    PrEntry(int seq, int slot, String code, String date) {
      this.seq = seq;
      this.slot = slot;
      this.code = code;
      this.date = date;
    }
  }

  public static final class Mapped {
    public MsdrgInput input;
    public MsdrgHospitalStatusOptionFlag hospitalStatus;
    public int ageUsed;
    public boolean ageParsed;
    public MsdrgSex sexUsed;
    public Integer dischargeStatusInt;      // null when not parseable
    public MsdrgDischargeStatus dischargeStatusUsed; // null when not set / unknown code
    public final List<DxEntry> dx = new ArrayList<>();
    public final List<PrEntry> pr = new ArrayList<>();
    public boolean hasPrincipal;
  }

  private final boolean lenientNumeric;

  public ClaimMapper(boolean lenientNumeric) {
    this.lenientNumeric = lenientNumeric;
  }

  private String num(String raw) {
    return lenientNumeric ? raw.trim() : raw;
  }

  public Mapped map(TestdbRecord r) {
    Mapped m = new Mapped();
    MsdrgInput.MsdrgInputBuilder b = MsdrgInput.builder();

    try {
      m.ageUsed = Integer.parseInt(num(r.ageRaw()));
      m.ageParsed = true;
      b.withAgeInYears(m.ageUsed);
    } catch (NumberFormatException e) {
      m.ageUsed = 0;
      m.ageParsed = false;
    }

    int sexInt;
    try {
      sexInt = Integer.parseInt(num(r.sexRaw()));
    } catch (NumberFormatException e) {
      sexInt = -1;
    }
    switch (sexInt) {
      case 1:
        m.sexUsed = MsdrgSex.MALE;
        break;
      case 2:
        m.sexUsed = MsdrgSex.FEMALE;
        break;
      default:
        m.sexUsed = MsdrgSex.UNKNOWN;
    }
    b.withSex(m.sexUsed);

    try {
      m.dischargeStatusInt = Integer.parseInt(num(r.dischargeStatusRaw()));
      m.dischargeStatusUsed = MsdrgDischargeStatus.getEnumFromInt(m.dischargeStatusInt);
      b.withDischargeStatus(m.dischargeStatusUsed);
    } catch (NumberFormatException e) {
      m.dischargeStatusInt = null;
      m.dischargeStatusUsed = null;
    }

    List<MsdrgInputDxCode> sdx = new ArrayList<>();
    int seq = 0;
    for (int slot = 1; slot <= TestdbRecord.MAX_DX; slot++) {
      String code = r.dxCode(slot).trim();
      if (code.isEmpty()) {
        continue;
      }
      String poaRaw = r.dxPoa(slot);
      GfcPoa poa = GfcPoa.BLANK;
      if (!poaRaw.trim().isEmpty()) {
        poa = GfcPoa.fromChar(poaRaw.charAt(0), GfcPoa.BLANK);
      }
      MsdrgInputDxCode dx = new MsdrgInputDxCode(code, poa);
      if (slot == 1) {
        b.withPrincipalDiagnosisCode(dx);
        m.hasPrincipal = true;
        m.dx.add(new DxEntry(0, slot, code, poaRaw, poa));
      } else {
        sdx.add(dx);
        seq++;
        m.dx.add(new DxEntry(seq, slot, code, poaRaw, poa));
      }
    }
    b.withSecondaryDiagnosisCodes(sdx);

    List<MsdrgInputPrCode> prs = new ArrayList<>();
    int pseq = 0;
    for (int slot = 1; slot <= TestdbRecord.MAX_PR; slot++) {
      String code = r.prCode(slot).trim();
      if (code.isEmpty()) {
        continue;
      }
      prs.add(new MsdrgInputPrCode(code));
      pseq++;
      m.pr.add(new PrEntry(pseq, slot, code, r.prDate(slot).trim()));
    }
    b.withProcedureCodes(prs);

    b.withAgeDaysAdmit(-1);
    b.withAgeDaysDischarge(-1);
    m.input = b.build();

    m.hospitalStatus = "X".equals(r.poaLogic())
        ? MsdrgHospitalStatusOptionFlag.EXEMPT
        : MsdrgHospitalStatusOptionFlag.NON_EXEMPT;
    return m;
  }
}
