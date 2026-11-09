package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Workout;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

/**
 * 运动数据推送手机：告知手表"手机成为操控端"（服务 0x17 命令 0x01）。
 * 官方在 App 侧运动状态变化时下发，逆向依据 HwExerciseCommandUtil.notifyOperatorStatus。
 */
public class WorkoutSetOperatorRequest extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(WorkoutSetOperatorRequest.class);

    private final byte operatorType;
    private final byte sportType;
    private final byte workoutType;
    private final int startTimeSeconds;

    public WorkoutSetOperatorRequest(IHuaweiSupport support, byte operatorType, byte sportType,
                                     byte workoutType, int startTimeSeconds) {
        super(support);
        this.serviceId = Workout.id;
        this.commandId = Workout.SetOperator.id;
        this.operatorType = operatorType;
        this.sportType = sportType;
        this.workoutType = workoutType;
        this.startTimeSeconds = startTimeSeconds;
        this.addToResponse = false;
        this.isSelfQueue = false;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Workout.SetOperator.Request(paramsProvider, operatorType, sportType,
                    workoutType, startTimeSeconds).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        LOG.debug("handle Workout SetOperator");
    }
}
