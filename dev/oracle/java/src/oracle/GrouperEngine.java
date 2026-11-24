package oracle;

import com.mmm.his.cer.foundation.Processable;
import gov.agency.msdrg.model.v2.MsdrgOption;
import gov.agency.msdrg.model.v2.MsdrgRuntimeOption;
import gov.agency.msdrg.model.v2.RuntimeOptions;
import gov.agency.msdrg.model.v2.enumeration.MarkingLogicTieBreaker;
import gov.agency.msdrg.model.v2.enumeration.MsdrgAffectDrgOptionFlag;
import gov.agency.msdrg.model.v2.enumeration.MsdrgHospitalStatusOptionFlag;
import gov.agency.msdrg.model.v2.transfer.MsdrgClaim;
import gov.agency.msdrg.model.v2.transfer.input.MsdrgInput;
import gov.agency.msdrg.model.v2.transfer.output.MsdrgOutputData;
import java.lang.reflect.Constructor;
import java.util.HashMap;
import java.util.Map;
import java.util.function.Consumer;

/**
 * Thin wrapper around gov.agency.msdrg.v{VERSION}.MsdrgComponent (versions 400..440 are bundled in
 * msdrg-core-44.0.0.3.jar; 390/391 use the older v1 model and are not reachable through this API).
 * Components are instantiated by reflection so the version can be a CLI argument.
 *
 * Runtime options (gov.agency.msdrg.model.v2.RuntimeOptions), pinned here:
 *   computeAffectDrg       = COMPUTE
 *   markingLogicTieBreaker = CLINICAL_SIGNIFICANCE
 *   poaReportingExempt     = passed per claim (TESTDB col 7: X = EXEMPT, else NON_EXEMPT), or forced
 * plus MsdrgOption.TRACE, a text consumer that receives the grouper's own processing trace.
 */
public final class GrouperEngine implements AutoCloseable {

  public static final int[] SUPPORTED_VERSIONS = {400, 401, 410, 411, 420, 421, 430, 431, 440};

  private final Map<Integer, Processable<MsdrgClaim, MsdrgOption, MsdrgRuntimeOption>> cache =
      new HashMap<>();
  private final MsdrgRuntimeOption runtimeOption = new MsdrgRuntimeOption();
  private final RuntimeOptions options = new RuntimeOptions();
  private final StringBuilder trace = new StringBuilder();
  private final boolean traceEnabled;

  public GrouperEngine(boolean traceEnabled) {
    this.traceEnabled = traceEnabled;
    options.setComputeAffectDrg(MsdrgAffectDrgOptionFlag.COMPUTE);
    options.setMarkingLogicTieBreaker(MarkingLogicTieBreaker.CLINICAL_SIGNIFICANCE);
    options.setPoaReportingExempt(MsdrgHospitalStatusOptionFlag.NON_EXEMPT);
    runtimeOption.put(MsdrgOption.RUNTIME_OPTION_FLAGS, options);
    if (traceEnabled) {
      Consumer<String> consumer = trace::append;
      runtimeOption.put(MsdrgOption.TRACE, consumer);
    }
  }

  public RuntimeOptions options() {
    return options;
  }

  public static boolean isSupported(int version) {
    for (int v : SUPPORTED_VERSIONS) {
      if (v == version) {
        return true;
      }
    }
    return false;
  }

  public static String componentClassName(int version) {
    return "gov.agency.msdrg.v" + version + ".MsdrgComponent";
  }

  @SuppressWarnings("unchecked")
  private Processable<MsdrgClaim, MsdrgOption, MsdrgRuntimeOption> component(int version)
      throws Exception {
    Processable<MsdrgClaim, MsdrgOption, MsdrgRuntimeOption> c = cache.get(version);
    if (c == null) {
      Class<?> cls = Class.forName(componentClassName(version));
      Constructor<?> ctor = cls.getConstructor(MsdrgRuntimeOption.class);
      c = (Processable<MsdrgClaim, MsdrgOption, MsdrgRuntimeOption>) ctor.newInstance(runtimeOption);
      cache.put(version, c);
    }
    return c;
  }

  /** Value of the component's public static GROUPER_VERSION constant (e.g. 440). */
  public int grouperVersionConstant(int version) throws Exception {
    Class<?> cls = Class.forName(componentClassName(version));
    return cls.getField("GROUPER_VERSION").getInt(null);
  }

  public MsdrgOutputData group(int version, MsdrgInput input,
      MsdrgHospitalStatusOptionFlag hospitalStatus, String claimId) throws Exception {
    Processable<MsdrgClaim, MsdrgOption, MsdrgRuntimeOption> c = component(version);
    options.setPoaReportingExempt(hospitalStatus);
    c.reconfigure(runtimeOption);
    MsdrgClaim claim = new MsdrgClaim(input);
    claim.setClaimId(claimId);
    trace.setLength(0);
    c.process(claim);
    return claim.getOutput().orElseThrow(() -> new IllegalStateException("no output on claim"));
  }

  /** Trace text of the last group() call (empty when tracing is disabled). */
  public String lastTrace() {
    return traceEnabled ? trace.toString() : "";
  }

  @Override
  public void close() {
    for (Processable<MsdrgClaim, MsdrgOption, MsdrgRuntimeOption> c : cache.values()) {
      try {
        c.close();
      } catch (Exception ignored) {
        // nothing to do
      }
    }
    cache.clear();
  }
}
