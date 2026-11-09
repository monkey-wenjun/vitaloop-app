package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.EphemerisFileUpload;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class SendEphemerisFileUploadDoneResponse extends Request {
    final int responseCode;

    public SendEphemerisFileUploadDoneResponse(IHuaweiSupport support, int responseCode) {
        super(support);
        this.serviceId = EphemerisFileUpload.id;
        this.commandId = EphemerisFileUpload.UploadDone.id;
        this.responseCode = responseCode;
        this.addToResponse = false;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new EphemerisFileUpload.UploadDone.UploadDoneResponse(this.paramsProvider, this.responseCode).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }
}
