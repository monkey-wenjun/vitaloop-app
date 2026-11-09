package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import java.util.List;

import com.awen.running.utils.FileLogger;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

/**
 * 调试：按上游的 debug-string DSL 任意发一条命令（svc,cmd,enc,slice,(tag,(type value))...），
 * 只把应答的原始 TLV 记进文件日志，不写库。
 *
 * 用来做「这条命令手表到底认不认」的对照实验：同一个服务换命令号、同一个命令换载荷，
 * 看出的是错误包、空 TLV 还是超时。逆向阶段没有比这更快的判定方式。
 *
 * adb shell am broadcast -a com.awen.running.action.RAW_CMD \
 *   --es req "0x20,0x03,t,t,(0x81,(0x3,I1793098094),(0x4,I1793702894))"
 */
public class RawCommandRequest extends DebugRequest {
    public static final String PROBE_TAG = "RawProbe";

    private final String label;
    private final HuaweiPacket packet;

    public RawCommandRequest(IHuaweiSupport support, String debugString) throws RequestCreationException {
        super(support);
        this.label = debugString;
        this.packet = parseDebugString(debugString);
        // 期望应答按这两个字节匹配，必须跟真实命令一致（基类里 DebugRequest 写死了 0）
        this.serviceId = this.packet.serviceId;
        this.commandId = this.packet.commandId;
        // DebugRequest 把 addToResponse 关掉了，那样应答根本不会路由回来
        this.addToResponse = true;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return packet.serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        FileLogger.i(PROBE_TAG, "原始命令应答 svc=0x" + Integer.toHexString(serviceId & 0xFF)
                + " cmd=0x" + Integer.toHexString(commandId & 0xFF)
                + " req=" + label + " tlv=" + describeReceivedTlv());
    }
}
