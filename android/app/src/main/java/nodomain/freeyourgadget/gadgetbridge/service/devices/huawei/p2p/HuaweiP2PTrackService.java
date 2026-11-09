/*
 * Ported from Gadgetbridge (AGPL-3.0).
 * Upstream: Freeyourgadget/Gadgetbridge
 */
package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

import com.awen.running.utils.FileLogger;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HeartRateZonesConfig;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiSportHRZones;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.HuaweiP2PManager;

public class HuaweiP2PTrackService extends HuaweiBaseP2PService {
    private static final Logger LOG = LoggerFactory.getLogger(HuaweiP2PTrackService.class);
    public static final String MODULE = "hw.unitedevice.track";
    private static final int HEADER_LENGTH = 36;

    private int age;
    private int restHeartRate;
    private int maxHeartRate;
    private int counter = 0;

    public HuaweiP2PTrackService(HuaweiP2PManager manager, int age, int restHeartRate, int maxHeartRate) {
        super(manager);
        this.age = Math.max(10, age);
        this.restHeartRate = restHeartRate;
        this.maxHeartRate = maxHeartRate;
    }

    @Override
    public String getModule() {
        return MODULE;
    }

    @Override
    public String getPackage() {
        return "hw.watch.health.p2p";
    }

    @Override
    public String getFingerprint() {
        return "SystemApp";
    }

    @Override
    public void registered() {
        sendHeartZoneConfig();
    }

    @Override
    public void unregister() {
    }

    @Override
    public void handleData(byte[] data) {
        LOG.info("HuaweiP2PTrackService handleData: {}", data == null ? 0 : data.length);
    }

    private synchronized int nextCounter() {
        counter = (counter + 1) % 10000;
        return counter;
    }

    /** 用户在 App 里改了年龄/静息心率/最大心率后按新值重发，不必断开重连。 */
    public void refreshHeartZoneConfig(int age, int restHeartRate, int maxHeartRate) {
        this.age = Math.max(10, age);
        this.restHeartRate = restHeartRate;
        this.maxHeartRate = maxHeartRate;
        sendHeartZoneConfig();
    }

    private void sendHeartZoneConfig() {
        HeartRateZonesConfig upright = new HeartRateZonesConfig(
                HeartRateZonesConfig.TYPE_UPRIGHT, age, restHeartRate, maxHeartRate,
                HeartRateZonesConfig.CALCULATE_METHOD_HRR);
        byte[] data = new HuaweiSportHRZones(age, restHeartRate, maxHeartRate,
                HeartRateZonesConfig.CALCULATE_METHOD_HRR).getHRZonesData();
        if (data == null) {
            LOG.error("Incorrect heart-rate zone config");
            return;
        }
        LOG.info("P2P 心率区间 HRR 边界(bpm): 有氧基础={} 有氧进阶={} 乳酸阈值={} 无氧基础={} 无氧进阶={} 最大心率={}",
                upright.getHRRBasicAerobic(), upright.getHRRAdvancedAerobic(), upright.getHRRLactate(),
                upright.getHRRBasicAnaerobic(), upright.getHRRAdvancedAnaerobic(), upright.getMaxHRThreshold());
        // addLog 只进内存和 logcat，手表侧下发必须落盘才能在日志文件里核对
        FileLogger.INSTANCE.i("HeartRateZones", "P2P 下发心率区间 年龄=" + age
                + " 静息=" + restHeartRate + " 最大=" + maxHeartRate
                + " HRR边界(bpm)=" + upright.getHRRBasicAerobic() + "/"
                + upright.getHRRAdvancedAerobic() + "/" + upright.getHRRLactate() + "/"
                + upright.getHRRBasicAnaerobic() + "/" + upright.getHRRAdvancedAnaerobic());

        ByteBuffer packet = ByteBuffer.allocate(HEADER_LENGTH + data.length);
        packet.order(ByteOrder.LITTLE_ENDIAN);
        packet.putInt(2);
        packet.putInt(1);
        packet.putInt(HEADER_LENGTH + data.length);
        packet.putInt(0);
        packet.putInt(nextCounter());
        packet.put(data);

        LOG.info("HuaweiP2PTrackService sendHeartZoneConfig bytes={}", packet.capacity());
        sendCommand(packet.array(), null);
    }

    public static HuaweiP2PTrackService getRegisteredInstance(HuaweiP2PManager manager) {
        return (HuaweiP2PTrackService) manager.getRegisteredService(MODULE);
    }
}
