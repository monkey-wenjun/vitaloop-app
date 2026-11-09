package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

import com.awen.running.utils.FileLogger;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.FileDownloadService0A;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

/**
 * 压力通道 B 的探测（服务 0x0A 命令 1，文件类型 0x04 = PeriodRri）。
 *
 * 官方在 defpackage/mum.java:200 逐字节拼出这条请求，载荷是
 * {@code 02 01 04 8F 0C 10 04 <起始秒> 11 04 <结束秒>}；文件里才是手表算好的压力值
 * （v3 记录 66 字节/条，含 score/grade/算法版本，见
 * docs/REVERSE_STRESS_TEMPERATURE.md 第 4 节）。
 *
 * 这里只发请求、只留原始应答，不接现成的下载管线：一是 GT 5 有没有这类文件还是未知，
 * 二是 {@code GetFileDownloadInitRequest} 的应答解法按睡眠/GPS 的 tag 写死，
 * 用它会把「手表到底怎么答」这件事糊掉。
 */
public class ProbePeriodRriFileRequest extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(ProbePeriodRriFileRequest.class);

    private final int startTime;
    private final int endTime;

    public ProbePeriodRriFileRequest(IHuaweiSupport support, int startTime, int endTime) {
        super(support);
        this.serviceId = FileDownloadService0A.id;
        this.commandId = FileDownloadService0A.FileDownloadInit.id;
        this.startTime = startTime;
        this.endTime = endTime;
    }

    @Override
    protected boolean requestSupported() {
        return true;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new FileDownloadService0A.FileDownloadInit.PeriodRriFilesRequest(
                    paramsProvider, startTime, endTime).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        FileLogger.INSTANCE.i(GetStressFrameIndexRequest.PROBE_TAG,
                "PeriodRri 文件应答(0x0A/1 type=04) window=" + startTime + ".." + endTime
                        + " tlv=" + describeReceivedTlv());
        LOG.debug("handle ProbePeriodRriFile");
    }
}
