package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Workout;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

import com.awen.running.utils.FileLogger;

/**
 * 码表拉取模式第二步：只读一条运动记录的汇总（服务 0x17 命令 0x08）。
 * 与同步链用的 GetWorkoutTotalsRequest 区别是不入库、不续跑轨迹下载，
 * 所以可以三十秒一次反复查，用来显示进行中运动的累计值。
 * 注意不能设 addToResponse=false：响应只投递给注册进 handlers 的请求，
 * 不设就等于这个请求永远收不到应答。
 */
public class WorkoutLiveTotalsRequest extends Request {
    public interface Listener {
        void onTotals(Workout.WorkoutTotals.Response packet);
    }

    private final short workoutNumber;
    private final Listener listener;

    public WorkoutLiveTotalsRequest(IHuaweiSupport support, short workoutNumber, Listener listener) {
        super(support);
        this.serviceId = Workout.id;
        this.commandId = Workout.WorkoutTotals.id;
        this.workoutNumber = workoutNumber;
        this.listener = listener;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Workout.WorkoutTotals.Request(paramsProvider, workoutNumber).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() throws ResponseParseException {
        if (!(receivedPacket instanceof Workout.WorkoutTotals.Response)) {
            FileLogger.INSTANCE.e("WorkoutLiveTotalsRequest", "码表拉取失败（totals 包型不匹配）: "
                    + receivedPacket.getClass().getSimpleName() + " tlv=" + describeReceivedTlv(), null);
            throw new ResponseTypeMismatchException(receivedPacket, Workout.WorkoutTotals.Response.class);
        }

        listener.onTotals((Workout.WorkoutTotals.Response) receivedPacket);
    }
}
