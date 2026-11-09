/*
 * Ported from Gadgetbridge (AGPL-3.0).
 * Upstream: Freeyourgadget/Gadgetbridge
 */
package nodomain.freeyourgadget.gadgetbridge.devices.huawei;

public class HuaweiSportHRZones {
    private final HeartRateZonesConfig otherHRZonesConfig;
    private final HeartRateZonesConfig sittingHRZonesConfig;
    private final HeartRateZonesConfig uprightHRZonesConfig;
    private final HeartRateZonesConfig swimmingHRZonesConfig;

    public HuaweiSportHRZones(int age) {
        this.uprightHRZonesConfig = new HeartRateZonesConfig(HeartRateZonesConfig.TYPE_UPRIGHT, age);
        this.sittingHRZonesConfig = new HeartRateZonesConfig(HeartRateZonesConfig.TYPE_SITTING, age);
        this.swimmingHRZonesConfig = new HeartRateZonesConfig(HeartRateZonesConfig.TYPE_SWIMMING, age);
        this.otherHRZonesConfig = new HeartRateZonesConfig(HeartRateZonesConfig.TYPE_OTHER, age);
    }

    /**
     * 用 App 侧的静息心率 / 最大心率 / 区间算法生成四张表。
     *
     * 只传 age 的构造会把 calculateMethod 留在默认的 MHR，手表就按 %最大心率判档，
     * 和 App 的储备心率法对不上（36 岁 150bpm：App 判有氧耐力、表判无氧）。
     */
    public HuaweiSportHRZones(int age, int restHeartRate, int maxHeartRate, int calculateMethod) {
        this(age);
        for (HeartRateZonesConfig config : new HeartRateZonesConfig[]{
                uprightHRZonesConfig, sittingHRZonesConfig, swimmingHRZonesConfig, otherHRZonesConfig}) {
            config.applyUserProfile(age, restHeartRate, maxHeartRate, calculateMethod);
        }
    }

    public HeartRateZonesConfig getHRZonesConfigByType(int type) {
        if (type == HeartRateZonesConfig.TYPE_SITTING) return sittingHRZonesConfig;
        if (type == HeartRateZonesConfig.TYPE_SWIMMING) return swimmingHRZonesConfig;
        if (type == HeartRateZonesConfig.TYPE_OTHER) return otherHRZonesConfig;
        return uprightHRZonesConfig;
    }

    public byte[] getHRZonesData() {
        HeartRateZonesConfig upright = getHRZonesConfigByType(HeartRateZonesConfig.TYPE_UPRIGHT);
        HeartRateZonesConfig sitting = getHRZonesConfigByType(HeartRateZonesConfig.TYPE_SITTING);
        HeartRateZonesConfig swimming = getHRZonesConfigByType(HeartRateZonesConfig.TYPE_SWIMMING);
        HeartRateZonesConfig other = getHRZonesConfigByType(HeartRateZonesConfig.TYPE_OTHER);

        if (!upright.isValid() || !sitting.isValid() || !swimming.isValid() || !other.isValid()) {
            return null;
        }

        HuaweiTLV tlv = new HuaweiTLV();
        if (upright.hasValidMHRData()) {
            tlv.put(0x02, (byte) upright.getMHRWarmUp())
                    .put(0x03, (byte) upright.getMHRFatBurning())
                    .put(0x04, (byte) upright.getMHRAerobic())
                    .put(0x05, (byte) upright.getMHRAnaerobic())
                    .put(0x06, (byte) upright.getMHRExtreme())
                    .put(0x07, (byte) upright.getMaxHRThreshold())
                    .put(0x08, (byte) (upright.getWarningEnable() ? 1 : 0))
                    .put(0x09, (byte) upright.getWarningHRLimit())
                    .put(0x0a, (byte) upright.getCalculateMethod())
                    .put(0x0b, (byte) upright.getMaxHRThreshold());
        }
        tlv.put(0x0c, (byte) upright.getRestHeartRate());
        if (upright.hasValidHRRData()) {
            tlv.put(0x0d, (byte) upright.getHRRBasicAerobic())
                    .put(0x0e, (byte) upright.getHRRAdvancedAerobic())
                    .put(0x0f, (byte) upright.getHRRLactate())
                    .put(0x10, (byte) upright.getHRRBasicAnaerobic())
                    .put(0x11, (byte) upright.getHRRAdvancedAnaerobic());
        }
        if (upright.hasValidLTHRData()) {
            tlv.put(0x3f, (byte) upright.getLTHRThresholdHeartRate())
                    .put(0x40, (byte) upright.getLTHRAnaerobic())
                    .put(0x41, (byte) upright.getLTHRLactate())
                    .put(0x42, (byte) upright.getLTHRAdvancedAerobic())
                    .put(0x43, (byte) upright.getLTHRBasicAerobic())
                    .put(0x44, (byte) upright.getLTHRWarmUp());
        }

        if (sitting.hasValidMHRData()) {
            tlv.put(0x12, (byte) (sitting.getWarningEnable() ? 1 : 0))
                    .put(0x13, (byte) sitting.getCalculateMethod())
                    .put(0x14, (byte) sitting.getWarningHRLimit())
                    .put(0x15, (byte) sitting.getMHRWarmUp())
                    .put(0x16, (byte) sitting.getMHRFatBurning())
                    .put(0x17, (byte) sitting.getMHRAerobic())
                    .put(0x18, (byte) sitting.getMHRAnaerobic())
                    .put(0x19, (byte) sitting.getMHRExtreme())
                    .put(0x1a, (byte) sitting.getMaxHRThreshold());
        }
        if (sitting.hasValidHRRData()) {
            tlv.put(0x1b, (byte) sitting.getRestHeartRate())
                    .put(0x1c, (byte) sitting.getHRRBasicAerobic())
                    .put(0x1d, (byte) sitting.getHRRAdvancedAerobic())
                    .put(0x1e, (byte) sitting.getHRRLactate())
                    .put(0x1f, (byte) sitting.getHRRBasicAnaerobic())
                    .put(0x20, (byte) sitting.getHRRAdvancedAnaerobic());
        }

        if (swimming.hasValidMHRData()) {
            tlv.put(0x21, (byte) (swimming.getWarningEnable() ? 1 : 0))
                    .put(0x22, (byte) swimming.getCalculateMethod())
                    .put(0x23, (byte) swimming.getWarningHRLimit())
                    .put(0x24, (byte) swimming.getMHRWarmUp())
                    .put(0x25, (byte) swimming.getMHRFatBurning())
                    .put(0x26, (byte) swimming.getMHRAerobic())
                    .put(0x27, (byte) swimming.getMHRAnaerobic())
                    .put(0x28, (byte) swimming.getMHRExtreme())
                    .put(0x29, (byte) swimming.getMaxHRThreshold());
        }
        if (swimming.hasValidHRRData()) {
            tlv.put(0x2a, (byte) swimming.getRestHeartRate())
                    .put(0x2b, (byte) swimming.getHRRBasicAerobic())
                    .put(0x2c, (byte) swimming.getHRRAdvancedAerobic())
                    .put(0x2d, (byte) swimming.getHRRLactate())
                    .put(0x2e, (byte) swimming.getHRRBasicAnaerobic())
                    .put(0x2f, (byte) swimming.getHRRAdvancedAnaerobic());
        }

        if (other.hasValidMHRData()) {
            tlv.put(0x30, (byte) (other.getWarningEnable() ? 1 : 0))
                    .put(0x31, (byte) other.getCalculateMethod())
                    .put(0x32, (byte) other.getWarningHRLimit())
                    .put(0x33, (byte) other.getMHRWarmUp())
                    .put(0x34, (byte) other.getMHRFatBurning())
                    .put(0x35, (byte) other.getMHRAerobic())
                    .put(0x36, (byte) other.getMHRAnaerobic())
                    .put(0x37, (byte) other.getMHRExtreme())
                    .put(0x38, (byte) other.getMaxHRThreshold());
        }
        if (other.hasValidHRRData()) {
            tlv.put(0x39, (byte) other.getRestHeartRate())
                    .put(0x3a, (byte) other.getHRRBasicAerobic())
                    .put(0x3b, (byte) other.getHRRAdvancedAerobic())
                    .put(0x3c, (byte) other.getHRRLactate())
                    .put(0x3d, (byte) other.getHRRBasicAnaerobic())
                    .put(0x3e, (byte) other.getHRRAdvancedAnaerobic());
        }
        return tlv.serialize();
    }
}
