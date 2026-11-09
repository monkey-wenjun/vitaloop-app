package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Workout;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

/**
 * 运动数据推送手机：打开/关闭手表向手机推送运动数据（服务 0x17 命令 0x12）。
 * operatorType=1 打开，0 关闭；这是整条码表通道的前置使能，不发手表不会推。
 * 逆向依据：官方 HwHeartRateManager.openOrCloseReport。
 */
public class WorkoutReportSwitchRequest extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(WorkoutReportSwitchRequest.class);

    private final byte operatorType;

    public WorkoutReportSwitchRequest(IHuaweiSupport support, byte operatorType) {
        super(support);
        this.serviceId = Workout.id;
        this.commandId = Workout.ReportSwitch.id;
        this.operatorType = operatorType;
        this.addToResponse = false;
        // 应答按异步包在 HuaweiWatchManager 解析，请求侧不需要超时
        isSelfQueue = false;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Workout.ReportSwitch.Request(paramsProvider, operatorType).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        LOG.debug("handle WorkoutReportSwitch");
    }
}
