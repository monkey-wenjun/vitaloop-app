package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Linkage;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

import com.awen.running.utils.FileLogger;

/**
 * 回复手表 0x37 的联动请求（服务 0x37 命令 0x02 Event）。
 * 手表开运动并要"推送手机"时先发 Event(linkageOperation=0) 过来，官方唯一的出站就是这条回执；
 * 回执之后设备侧才开始往 hw.sport.linkage.app 推 SamplePoint。
 * 不回执的后果我们已经实测到：整个骑行过程只有一来一回两个包，码表一帧数据都拿不到。
 */
public class LinkageEventReplyRequest extends Request {
    private final int eventId;
    private final byte eventLevel;
    private final byte opAck;
    private final byte replyCode;

    public LinkageEventReplyRequest(IHuaweiSupport support, int eventId, byte eventLevel,
                                   byte opAck, byte replyCode) {
        super(support);
        this.serviceId = Linkage.id;
        this.commandId = Linkage.Event.id;
        this.eventId = eventId;
        this.eventLevel = eventLevel;
        this.opAck = opAck;
        this.replyCode = replyCode;
        // 回执没有应答包：不注册进 handlers，也不挂超时定时器
        this.addToResponse = false;
        this.isSelfQueue = false;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Linkage.Event.Reply(
                    paramsProvider,
                    Linkage.SPORT_APP_PACKAGE,
                    Linkage.SPORT_DEVICE_PACKAGE,
                    this.eventId,
                    this.eventLevel,
                    this.opAck,
                    this.replyCode
            ).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        // 不注册 handlers，不应走到这里
    }

    @Override
    public void doPerform() throws java.io.IOException {
        FileLogger.INSTANCE.i("LinkageEventReplyRequest",
                "回手表联动请求: eventId=" + this.eventId + " level=" + this.eventLevel
                        + " opAck=" + this.opAck + " replyCode=" + this.replyCode);
        super.doPerform();
    }
}
