package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Workout;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

/**
 * 运动数据推送手机：主动查询手表的运动操作状态（服务 0x17 命令 0x03）。
 * 用于手表不推通知时的兜底探测：应答里的 operatorType/sportType 决定要不要订阅实时帧。
 * 逆向依据：官方 HwExerciseCommandUtil.getOperatorStatus。
 */
public class GetWorkoutOperatorStatusRequest extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(GetWorkoutOperatorStatusRequest.class);

    public GetWorkoutOperatorStatusRequest(IHuaweiSupport support) {
        super(support);
        this.serviceId = Workout.id;
        this.commandId = Workout.OperatorStatus.id;
        this.addToResponse = false;
        // 应答按异步包在 HuaweiWatchManager 解析，请求侧不需要超时
        isSelfQueue = false;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Workout.OperatorStatus.Request(paramsProvider).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        LOG.debug("handle GetWorkoutOperatorStatus");
    }
}
