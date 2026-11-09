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
 * 压力通道 A 的探测（服务 0x20 命令 2）：按帧索引要一条压力明细。
 *
 * 官方字段（defpackage/nip.a + nii.java 的 toString）：子容器里
 * tag 4 = stressScore、tag 5 = stressTime（秒）、tag 6 = stressTestType（1/2）。
 * 这里只留证不入库 —— 测量类型的语义（1/2 分别对应官方 HiHealth 2019/2020 的哪一档）
 * 要靠真机字节定下来后再写库，否则只会把猜的值塞进压力表。
 */
public class GetStressRecordDetailRequest extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(GetStressRecordDetailRequest.class);

    /** 一条明细：分数 / 采样时刻（秒）/ 测量类型；解不出来的项为 null */
    public static class Entry {
        public final Integer score;
        public final Long timeSec;
        public final Integer measureType;

        Entry(Integer score, Long timeSec, Integer measureType) {
            this.score = score;
            this.timeSec = timeSec;
            this.measureType = measureType;
        }

        @Override
        public String toString() {
            return "score=" + score + " time=" + timeSec + " type=" + measureType;
        }
    }

    public final List<Entry> entries = new ArrayList<>();

    private final short frameIndex;

    public GetStressRecordDetailRequest(IHuaweiSupport support, short frameIndex) {
        super(support);
        this.serviceId = Stress.id;
        this.commandId = Stress.StressRecordDetail.id;
        this.frameIndex = frameIndex;
    }

    @Override
    protected boolean requestSupported() {
        return true;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Stress.StressRecordDetail.Request(paramsProvider, frameIndex).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        HuaweiTLV tlv = receivedPacket.getTlv();
        for (HuaweiTLV scope : GetStressFrameIndexRequest.scopes(tlv)) {
            Integer score = null;
            Long timeSec = null;
            Integer measureType = null;
            for (HuaweiTLV.TLV entry : scope.get()) {
                Integer value = GetStressFrameIndexRequest.asInt(entry.getValue());
                if (value == null) {
                    continue;
                }
                if (entry.getTag() == Stress.tag_score) {
                    score = value;
                } else if (entry.getTag() == Stress.tag_sampleTime) {
                    timeSec = value.longValue();
                } else if (entry.getTag() == Stress.tag_measureType) {
                    measureType = value;
                }
            }
            if (score != null || timeSec != null || measureType != null) {
                entries.add(new Entry(score, timeSec, measureType));
            }
        }
        FileLogger.INSTANCE.i(GetStressFrameIndexRequest.PROBE_TAG,
                "压力明细应答(0x20/2) frame=" + frameIndex + " entries=" + entries
                        + " tlv=" + describeReceivedTlv());
        LOG.debug("handle GetStressRecordDetail frame={} entries={}", frameIndex, entries);
    }
}
