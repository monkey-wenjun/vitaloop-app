/*
 * 移植自 Gadgetbridge (AGPL-3.0) 的华为能力协商精简版，
 * 仅保留心率/睡眠/认证所需的能力查询，其余功能（音乐/表盘/天气等）已裁剪。
 */
package nodomain.freeyourgadget.gadgetbridge.devices.huawei;

import android.content.Context;
import android.content.SharedPreferences;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.ByteBuffer;
import java.util.TreeMap;

import nodomain.freeyourgadget.gadgetbridge.GBApplication;
import nodomain.freeyourgadget.gadgetbridge.impl.GBDevice;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Alarms;
import nodomain.freeyourgadget.gadgetbridge.util.GB;

/**
 * 华为设备能力协商（精简版）
 * 记录手表上报的支持服务/命令、扩展能力、通知能力等
 */
public class HuaweiCoordinator {
    private static final Logger LOG = LoggerFactory.getLogger(HuaweiCoordinator.class);

    private final TreeMap<Integer, byte[]> commandsPerService = new TreeMap<>();
    private byte[] expandCapabilities = null;
    private byte notificationCapabilities = -0x01;
    private ByteBuffer notificationConstraints = null;
    private boolean supportsTruSleepNewSync = false;
    private boolean supportsGpsNewSync = false;

    public HuaweiCoordinator() {
        // 从本地缓存恢复能力数据，避免每次连接都重新协商
        SharedPreferences prefs = getCapabilitiesSharedPreferences();
        this.expandCapabilities = GB.hexStringToByteArray(
                prefs.getString("expandCapabilities", "00"));
        this.notificationCapabilities = (byte) prefs.getInt("notificationCapabilities", -0x01);
        this.notificationConstraints = ByteBuffer.wrap(GB.hexStringToByteArray(
                prefs.getString("notificationConstraints", "00")));
        for (String key : prefs.getAll().keySet()) {
            try {
                int service = Integer.parseInt(key);
                byte[] commands = GB.hexStringToByteArray(prefs.getString(key, "00"));
                this.commandsPerService.put(service, commands);
            } catch (NumberFormatException ignored) {
                // 非数字 key 的能力项跳过
            }
        }
    }

    private SharedPreferences getCapabilitiesSharedPreferences() {
        return GBApplication.getContext()
                .getSharedPreferences("huawei_capabilities", Context.MODE_PRIVATE);
    }

    private boolean supportsCommandForService(int service, int command) {
        byte[] commands = commandsPerService.get(service);
        if (commands == null) {
            return false;
        }
        for (byte b : commands) {
            if (b == (byte) command) {
                return true;
            }
        }
        return false;
    }

    public boolean supportsExpandCapability(int which) {
        if (expandCapabilities == null) {
            return false;
        }
        if (which >= expandCapabilities.length * 8) {
            return false;
        }
        int capability = 1 << (which % 8);
        return (expandCapabilities[which / 8] & capability) == capability;
    }

    public void saveExpandCapabilities(byte[] capabilities) {
        expandCapabilities = capabilities;
        LOG.info("手表扩展能力位: {}", getExpandCapabilitiesHex());
        getCapabilitiesSharedPreferences().edit()
                .putString("expandCapabilities", getExpandCapabilitiesHex()).apply();
    }

    public String getExpandCapabilitiesHex() {
        return expandCapabilities == null ? "" : GB.hexdump(expandCapabilities);
    }

    public int expandCapabilityBitCount() {
        return expandCapabilities == null ? 0 : expandCapabilities.length * 8;
    }

    public void saveNotificationCapabilities(byte capabilities) {
        notificationCapabilities = capabilities;
        getCapabilitiesSharedPreferences().edit()
                .putInt("notificationCapabilities", (int) capabilities).apply();
    }

    public void saveNotificationConstraints(ByteBuffer constraints) {
        notificationConstraints = constraints;
        getCapabilitiesSharedPreferences().edit()
                .putString("notificationConstraints", GB.hexdump(constraints.array())).apply();
    }

    public void addCommandsForService(int service, byte[] commands) {
        commandsPerService.put(service, commands);
        getCapabilitiesSharedPreferences().edit()
                .putString(String.valueOf(service), GB.hexdump(commands)).apply();
    }

    public void printCommandsPerService() {
        LOG.debug("Commands per service: {}", commandsPerService);
    }

    public void setSupportsTruSleepNewSync(boolean supportsTruSleepNewSync) {
        this.supportsTruSleepNewSync = supportsTruSleepNewSync;
    }

    public boolean supportsTruSleepNewSync() {
        return supportsTruSleepNewSync;
    }

    public void setSupportsGpsNewSync(boolean supportsGpsNewSync) {
        this.supportsGpsNewSync = supportsGpsNewSync;
    }

    public boolean supportsGpsNewSync() {
        return supportsGpsNewSync;
    }

    public byte getNotificationCapabilities() {
        return notificationCapabilities;
    }

    // ===== 心率/睡眠/认证相关能力查询 =====

    public boolean supportsAcceptAgreement() {
        return supportsCommandForService(0x01, 0x30);
    }

    public boolean supportsSettingRelated() {
        return supportsCommandForService(0x01, 0x31);
    }

    public boolean supportsTimeAndZoneId() {
        return supportsCommandForService(0x01, 0x32);
    }

    public boolean supportsConnectStatus() {
        return supportsCommandForService(0x01, 0x35);
    }

    public boolean supportsExpandCapability() {
        return supportsCommandForService(0x01, 0x37);
    }

    public boolean supportsActivityType() {
        return supportsCommandForService(0x01, 0x12);
    }

    public boolean supportsQueryDndLiftWristDisturbType() {
        return supportsCommandForService(0x01, 0x1d);
    }

    public boolean supportsDoNotDisturb() {
        return supportsCommandForService(0x01, 0x0a);
    }

    public boolean supportsDoNotDisturb(GBDevice gbDevice) {
        return supportsDoNotDisturb();
    }

    public boolean supportsWearLocation() {
        return supportsCommandForService(0x01, 0x1a);
    }

    public boolean supportsWearLocation(GBDevice gbDevice) {
        return supportsWearLocation();
    }

    public boolean supportsRotateToCycleInfo() {
        return supportsCommandForService(0x01, 0x1b);
    }

    public boolean supportsDateFormat() {
        return supportsCommandForService(0x01, 0x04);
    }

    public boolean supportsActivateOnLift() {
        return supportsCommandForService(0x01, 0x09);
    }

    public boolean supportsNotificationAlert() {
        return supportsCommandForService(0x02, 0x01);
    }

    public boolean supportsNotification() {
        return supportsCommandForService(0x02, 0x04);
    }

    public boolean supportsWearMessagePush() {
        return supportsCommandForService(0x02, 0x08);
    }

    public boolean supportsMotionGoal() {
        return supportsCommandForService(0x07, 0x01);
    }

    public boolean supportsActivityReminder() {
        return supportsCommandForService(0x07, 0x07);
    }

    public boolean supportsDeviceReportThreshold() {
        return supportsCommandForService(0x07, 0x0e);
    }

    public boolean supportsHeartRateZones() {
        return supportsCommandForService(0x07, 0x13);
    }

    public boolean supportsExtendedHeartRateZones() {
        return supportsCommandForService(0x07, 0x21);
    }

    public boolean supportsTruSleep() {
        return supportsCommandForService(0x07, 0x16);
    }

    /** 是否支持睡眠详情序列数据文件（字典 700013，含呼吸率等每晚统计） */
    public boolean supportsDictSleepSync() {
        return supportsExpandCapability(143);
    }

    public boolean supportsFitnessRestHeartRate() {
        return supportsCommandForService(0x07, 0x23);
    }

    public boolean supportsRunPaceConfig() {
        return supportsCommandForService(0x07, 0x28);
    }

    public boolean supportsFitnessThresholdValue() {
        return supportsCommandForService(0x07, 0x29);
    }

    public boolean supportsFitnessThresholdValueV2() {
        return supportsExpandCapability(0x9a) || supportsExpandCapability(0x9c);
    }

    public boolean supportsMediumToStrengthThreshold() {
        return supportsCommandForService(0x07, 0x2a);
    }

    public boolean supportsAccountJudgment() {
        return supportsCommandForService(0x1A, 0x05);
    }

    public boolean supportsAccountSwitch() {
        return supportsCommandForService(0x1A, 0x06);
    }

    public boolean supportsDiffAccountPairingOptimization() {
        return supportsExpandCapability() && supportsExpandCapability(0xac);
    }

    public boolean supportsTrack() {
        return supportsExpandCapability() && supportsExpandCapability(0x36);
    }

    public boolean supportsMultiDevice() {
        return supportsExpandCapability() && supportsExpandCapability(109);
    }

    public boolean supportsUnknownGender() {
        return supportsExpandCapability() && supportsExpandCapability(0x57);
    }

    public boolean supportsPrecisionWeight() {
        return supportsExpandCapability() && supportsExpandCapability(0xb3);
    }

    public boolean supportsTemperature() {
        return supportsExpandCapability(0x1d);
    }

    public boolean supportsBloodPressure() {
        return supportsExpandCapability(0x3b);
    }

    /**
     * Expand capability bit 235：手表支持 HRV（RMSSD）数据字典同步
     * 与上游 Gadgetbridge HuaweiState.supportsHRV() 一致
     */
    public boolean supportsHRV() {
        return supportsExpandCapability(235);
    }

    public boolean supportsPromptPushMessage() {
        return ((notificationCapabilities >> 1) & 1) == 0;
    }

    public boolean supportsWearStatus() {
        return supportsCommandForService(0x01, 0x0f);
    }

    public boolean supportsSetUpDeviceStatus() {
        return supportsCommandForService(0x01, 0x2d);
    }

    // ===== 闹钟能力 =====

    public boolean supportsChangingAlarm() {
        return supportsCommandForService(Alarms.id, 0x03);
    }

    /**
     * 手表事件闹钟槽位数量（上游 Gadgetbridge 固定为 5 个）
     */
    public int getAlarmSlotCount() {
        return 5;
    }

    public boolean supportsSmartAlarm() {
        return supportsCommandForService(Alarms.id, Alarms.SmartAlarmRequest.id);
    }

    // ===== 日历同步能力 =====

    public boolean supportsP2PService() {
        return supportsCommandForService(0x34, 0x01);
    }

    public boolean supportsCalendar() {
        if (supportsExpandCapability())
            return supportsExpandCapability(171) || supportsExpandCapability(184);
        return false;
    }

    public boolean supportsExternalCalendarService() {
        if (supportsExpandCapability())
            return supportsExpandCapability(184);
        return false;
    }

    // ===== 天气同步能力 =====

    public boolean supportsWeather() {
        return true;
    }

    public boolean supportsWeatherUnit() {
        return true;
    }

    public boolean supportsWeatherExtended() {
        return true;
    }

    public boolean supportsWeatherForecasts() {
        return true;
    }

    public boolean supportsWeatherMoonRiseSet() {
        return true;
    }

    public boolean supportsWeatherUvIndex() {
        return false;
    }

    public boolean supportsWeatherErrorSimple() {
        return true;
    }

    public boolean supportsWeatherErrorExtended() {
        return false;
    }

    // ===== 扩展能力（Gadgetbridge 华为协议层完整能力集） =====

    public boolean supportsContacts() {
        return supportsCommandForService(0x03, 0x01);
    }

    public boolean supportsMenstrual() {
        return supportsCommandForService(0x32, 0x01);
    }

    public boolean supportsWatchfaceParams() {
        return supportsCommandForService(0x27, 0x01);
    }

    public boolean supportsAppParams() {
        return supportsCommandForService(0x2a, 0x06);
    }

    public boolean supportsAccount() {
        return supportsCommandForService(0x1a, 0x01);
    }

    public boolean supportsLanguageSetting() {
        return supportsCommandForService(0x0c, 0x01);
    }

    public boolean supportsCameraRemote() {
        return supportsCommandForService(0x01, 0x29);
    }

    public boolean supportsMusic() {
        return supportsCommandForService(0x25, 0x02);
    }

    public boolean supportsMusicUploading() {
        return supportsCommandForService(0x25, 0x04);
    }

    public boolean supportsMoreMusic() {
        if (supportsExpandCapability())
            return supportsExpandCapability(122);
        return false;
    }

    public boolean supportsAutoWorkMode() {
        return supportsCommandForService(0x26, 0x02);
    }

    public boolean supportsSendingGps() {
        return supportsCommandForService(0x18, 0x02);
    }

    public boolean supportsNotificationOnBluetoothLoss() {
        return supportsCommandForService(0x0b, 0x03);
    }

    public boolean supportsSmartAlarm(GBDevice gbDevice) {
        return supportsSmartAlarm();
    }

    public boolean supportsWorkoutsTrustHeartRate() {
        return supportsCommandForService(0x17, 0x17);
    }

    public int getContentLength() {
        return 256;
    }

    public byte getContentFormat() {
        return 0;
    }
}
