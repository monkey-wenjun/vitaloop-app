/*
 * 移植自 Gadgetbridge (AGPL-3.0) 的最小常量类，仅提供华为协议需要的 BASE_UUID。
 */
package nodomain.freeyourgadget.gadgetbridge.service.btle;

public abstract class AbstractBTLEDeviceSupport {
    public static final String BASE_UUID = "0000%s-0000-1000-8000-00805f9b34fb";
}
