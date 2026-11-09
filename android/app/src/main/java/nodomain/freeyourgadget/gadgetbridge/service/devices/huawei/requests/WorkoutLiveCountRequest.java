package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Workout;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

import com.awen.running.utils.FileLogger;

/**
 * 码表拉取模式第一步：只查最近有哪些运动记录（服务 0x17 命令 0x07），
 * 不走同步链、不入库。结果通过 Listener 回调给调用方。
 */
public class WorkoutLiveCountRequest extends Request {
    public interface Listener {
        void onWorkoutNumber(short workoutNumber);

        /** 窗口内没有记录：调用方要清掉 in-flight 标志，否则下一轮拉取会被这个标志卡住 */
        void onNoWorkoutRecord();
    }

    private final int start;
    private final int end;
    private final Listener listener;

    public WorkoutLiveCountRequest(IHuaweiSupport support, int start, int end, Listener listener) {
        super(support);
        this.serviceId = Workout.id;
        this.commandId = Workout.WorkoutCount.id;
        this.start = start;
        this.end = end;
        this.listener = listener;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Workout.WorkoutCount.Request(paramsProvider, start, end).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() throws ResponseParseException {
        if (!(receivedPacket instanceof Workout.WorkoutCount.Response))
            throw new ResponseTypeMismatchException(receivedPacket, Workout.WorkoutCount.Response.class);

        Workout.WorkoutCount.Response packet = (Workout.WorkoutCount.Response) receivedPacket;
        short newest = -1;
        for (Workout.WorkoutCount.Response.WorkoutNumbers n : packet.workoutNumbers) {
            if (n.workoutNumber > newest) newest = n.workoutNumber;
        }
        if (newest < 0) {
            FileLogger.INSTANCE.w("WorkoutLiveCountRequest", "码表拉取(count): 窗口内没有运动记录，取不到进行中记录");
            listener.onNoWorkoutRecord();
            return;
        }
        FileLogger.INSTANCE.d("WorkoutLiveCountRequest", "码表拉取(count): 应答 " + packet.workoutNumbers.size()
                + " 条，最新编号=" + newest);

        listener.onWorkoutNumber(newest);
    }
}
