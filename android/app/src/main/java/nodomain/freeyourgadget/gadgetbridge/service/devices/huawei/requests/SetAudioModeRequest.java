package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Earphones;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class SetAudioModeRequest extends Request {

    private final byte mode;

    public SetAudioModeRequest(IHuaweiSupport supportProvider, byte mode) {
        super(supportProvider);
        this.mode = mode;
        this.serviceId = Earphones.id;
        this.commandId = Earphones.SetAudioModeRequest.id;
        this.addToResponse = false; // Response with different command ID
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Earphones.SetAudioModeRequest(this.paramsProvider, mode).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }
}
