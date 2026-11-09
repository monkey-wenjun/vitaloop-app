package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Workout;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

/**
 * 运动数据推送手机：应答手表的 OperatorStatus 通知（服务 0x17 命令 0x02，tag 0x7F）。
 * 逆向依据：官方 HwWorkoutServiceAw70Manager.setNotificationStatusResponse。
 */
public class WorkoutNotificationStatusAckRequest extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(WorkoutNotificationStatusAckRequest.class);

    private final byte status;

    public WorkoutNotificationStatusAckRequest(IHuaweiSupport support, byte status) {
        super(support);
        this.serviceId = Workout.id;
        this.commandId = Workout.NotificationStatus.id;
        this.status = status;
        this.addToResponse = false;
        // 应答按异步包在 HuaweiWatchManager 解析，请求侧不需要超时
        isSelfQueue = false;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Workout.NotificationStatus.Ack(paramsProvider, status).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        LOG.debug("handle Workout NotificationStatus ack");
    }
}
