package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests

import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport

/**
 * 查询手表佩戴状态（离腕/在腕），把父类解出来的状态字节回调给调用方。
 *
 * 父类 [GetWearStatusRequest] 只写日志，[HuaweiWatchManager] 拿不到这次的解析结果，
 * 界面就没法显示。这里在父类解析完成后回调一次，让上层刷新状态。
 */
class GetWearStatusNotifyRequest(
    support: IHuaweiSupport,
    private val onStatusReceived: (Int) -> Unit
) : GetWearStatusRequest(support) {

    override fun processResponse() {
        super.processResponse()
        onStatusReceived(wearStatusCode)
    }
}
