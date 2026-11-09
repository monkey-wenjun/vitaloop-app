package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.DeviceConfig
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport

/**
 * 查询手表电量，并在父类把电量写进 GBDevice 之后回调一次调用方。
 *
 * 原生 [GetBatteryLevelRequest] 只更新 GBDevice，App 拿不到这次解析结果；而
 * HuaweiWatchManager 的 batteryLevel StateFlow 之前只在「连接就绪」时读一次
 * gbDevice.batteryLevel，一次连接之内再也不更新 —— 戴着一天下来界面显示的还是
 * 连接那一刻的电量（即"电量同步不准"）。
 *
 * 这里在父类完成解析（含多电池设备）后回调，让上层立刻刷新界面。
 */
class GetBatteryLevelNotifyRequest(
    support: IHuaweiSupport,
    private val onLevelReceived: (Int) -> Unit,
    private val onStatusReceived: ((ByteArray) -> Unit)? = null,
) : GetBatteryLevelRequest(support) {

    override fun processResponse() {
        super.processResponse()
        onLevelReceived(device.batteryLevel)
        val packet = receivedPacket
        if (packet is DeviceConfig.BatteryLevel.Response) {
            packet.status?.let { onStatusReceived?.invoke(it) }
        }
    }
}
