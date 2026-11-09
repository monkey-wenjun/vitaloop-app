/*
 * 移植自 Gadgetbridge (AGPL-3.0) 的最小设备模型，仅保留地址/名称/电量字段。
 */
package nodomain.freeyourgadget.gadgetbridge.impl;

import java.util.HashMap;
import java.util.Map;

public class GBDevice {
    private final String address;
    private final String name;
    private int batteryLevel = -1;
    private final Map<Integer, Integer> batteryLevels = new HashMap<>();
    private String firmwareVersion = "";
    private String firmwareVersion2 = "";
    private String model = "";

    public GBDevice(String address, String name) {
        this.address = address;
        this.name = name;
    }

    public String getAddress() {
        return address;
    }

    public String getName() {
        return name;
    }

    public void setBatteryLevel(int level) {
        this.batteryLevel = level;
    }

    public void setBatteryLevel(int level, int index) {
        batteryLevels.put(index, level);
    }

    public int getBatteryLevel() {
        return batteryLevel;
    }

    public void setFirmwareVersion(String version) {
        this.firmwareVersion = version;
    }

    public void setFirmwareVersion2(String version) {
        this.firmwareVersion2 = version;
    }

    public void setModel(String model) {
        this.model = model;
    }
}
