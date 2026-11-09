package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Ephemeris;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

import com.awen.running.utils.FileLogger;

public class SendEphemerisParameterConsultRequest extends Request  {
    private Logger LOG = LoggerFactory.getLogger(SendEphemerisParameterConsultRequest.class);

    public SendEphemerisParameterConsultRequest(IHuaweiSupport support) {
        super(support);
        this.serviceId = Ephemeris.id;
        this.commandId = Ephemeris.ParameterConsult.id;
    }

    @Override
    protected List<byte[]> createRequest() throws Request.RequestCreationException {
        try {
            return new Ephemeris.ParameterConsult.Request(this.paramsProvider).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new Request.RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() throws ResponseParseException {
        if (!(receivedPacket instanceof Ephemeris.ParameterConsult.Response))
            throw new ResponseTypeMismatchException(receivedPacket, Ephemeris.ParameterConsult.Response.class);

        Ephemeris.ParameterConsult.Response resp = (Ephemeris.ParameterConsult.Response)receivedPacket;
        if (!resp.hasConsultInfo) {
            // 手表只回状态码不带协商信息 = 它现在不想要数据（手里的还没过期），
            // 不能进上传流程，否则不知道该传哪个 tag 的文件
            FileLogger.INSTANCE.w("SendEphemerisParameterConsultRequest",
                    "星历协商：手表仅回状态码 " + resp.responseCode + "（无协商信息，本次不上传）");
            return;
        }
        supportProvider.getHuaweiEphemerisManager().handleParameterConsultResponse(resp.consultDeviceTime, resp.downloadVersion, resp.downloadTag);
    }
}
