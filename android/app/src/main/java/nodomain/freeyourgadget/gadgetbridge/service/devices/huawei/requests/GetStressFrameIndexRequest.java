package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayList;
import java.util.List;

import com.awen.running.utils.FileLogger;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiTLV;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Stress;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

/**
 * 压力通道 A 的探测（服务 0x20 命令 1）：按秒级窗口向手表要压力帧索引列表。
 *
 * 这是取证探针，不是成品链路：GT 5 到底实没实现 0x20，只有发出去才知道 ——
 * 官方 App 的压力不走字典 500026（我们在 GT 5 上请求了 85 次，全是合法空应答）。
 * 应答的原始 TLV 一定落文件日志，字段口径以后靠它认。
 * 完整逆向依据：docs/REVERSE_STRESS_TEMPERATURE.md 第 3 节。
 */
public class GetStressFrameIndexRequest extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(GetStressFrameIndexRequest.class);
    static final String PROBE_TAG = "StressProbe";

    /** 应答里解出来的帧索引；空列表 = 这个窗口手表没有压力样本 */
    public final List<Integer> frameIndices = new ArrayList<>();

    private final int startTime;
    private final int endTime;

    public GetStressFrameIndexRequest(IHuaweiSupport support, int startTime, int endTime) {
        super(support);
        this.serviceId = Stress.id;
        this.commandId = Stress.StressFrameIndex.id;
        this.startTime = startTime;
        this.endTime = endTime;
    }

    @Override
    protected boolean requestSupported() {
        // 和 GetWearStatusRequest 同理：判错能力位会让命令根本没发出去，
        // 探针要的就是「发出去、看手表怎么答」，不支持的手表回错误包即可。
        return true;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Stress.StressFrameIndex.Request(paramsProvider, startTime, endTime).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        HuaweiTLV tlv = receivedPacket.getTlv();
        for (HuaweiTLV scope : scopes(tlv)) {
            for (HuaweiTLV.TLV entry : scope.get()) {
                if (entry.getTag() == Stress.tag_indexList) {
                    Integer value = asInt(entry.getValue());
                    if (value != null) {
                        frameIndices.add(value);
                    }
                }
            }
        }
        FileLogger.INSTANCE.i(PROBE_TAG, "压力帧索引应答(0x20/1) window=" + startTime + ".." + endTime
                + " indices=" + frameIndices + " tlv=" + describeReceivedTlv());
        LOG.debug("handle GetStressFrameIndex: {}", frameIndices);
    }

    /**
     * 官方解法（defpackage/nip.d）是「剥掉包头 → 按容器走 → 容器里 tag 2=条数、tag 5=索引」。
     * 容器 tag 具体是哪个只有真机应答能定，所以顶层和已知容器 tag 都看一遍，不做猜测性解析。
     */
    static List<HuaweiTLV> scopes(HuaweiTLV tlv) {
        List<HuaweiTLV> scopes = new ArrayList<>();
        if (tlv == null) {
            return scopes;
        }
        scopes.add(tlv);
        for (int containerTag : new int[]{0x81, 0x83, 0x84, 0x87, 0x88}) {
            scopes.addAll(tlv.getObjects(containerTag));
        }
        return scopes;
    }

    static Integer asInt(byte[] value) {
        if (value == null || value.length == 0 || value.length > 4) {
            return null;
        }
        int result = 0;
        for (byte b : value) {
            result = (result << 8) | (b & 0xff);
        }
        return result;
    }
}
