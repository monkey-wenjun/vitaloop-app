package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Earphones;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class SetPauseWhenRemovedFromEarRequest extends Request {

    private final boolean inEarDetect;

    public SetPauseWhenRemovedFromEarRequest(IHuaweiSupport supportProvider, boolean inEarDetect) {
        super(supportProvider);
        this.inEarDetect = inEarDetect;
        this.serviceId = Earphones.id;
        this.commandId = Earphones.SetPauseWhenRemovedFromEar.id;
        this.addToResponse = false; // Response with different command ID
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Earphones.SetPauseWhenRemovedFromEar(this.paramsProvider, inEarDetect).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }
}
