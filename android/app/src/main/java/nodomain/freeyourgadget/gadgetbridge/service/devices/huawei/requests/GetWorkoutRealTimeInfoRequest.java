package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Workout;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

/**
 * 运动数据推送手机：向手表订阅实时运动数据（服务 0x17 命令 0x04）。
 * 订阅成功后手表按秒发命令 0x05 实时帧。
 * 逆向依据：官方 HwWorkoutServiceAw70Manager.getWorkoutRealTimeInfo。
 */
public class GetWorkoutRealTimeInfoRequest extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(GetWorkoutRealTimeInfoRequest.class);

    private final byte sportType;

    public GetWorkoutRealTimeInfoRequest(IHuaweiSupport support, byte sportType) {
        super(support);
        this.serviceId = Workout.id;
        this.commandId = Workout.RealTimeInfo.id;
        this.sportType = sportType;
        this.addToResponse = false;
        // 订阅应答和实时帧都按异步包在 HuaweiWatchManager 解析，请求侧不需要超时
        isSelfQueue = false;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Workout.RealTimeInfo.Request(paramsProvider, sportType).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        LOG.debug("handle GetWorkoutRealTimeInfo");
    }
}
