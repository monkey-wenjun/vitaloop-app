package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.LocaleConfig;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class SetTemperatureUnitSetting extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(SetTemperatureUnitSetting.class);

    private final byte isFahrenheit;

    public SetTemperatureUnitSetting(IHuaweiSupport support, byte isFahrenheit) {
        super(support);
        this.isFahrenheit = isFahrenheit;
        this.serviceId = LocaleConfig.id;
        this.commandId = LocaleConfig.SetTemperatureUnitSetting.id;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new LocaleConfig.SetTemperatureUnitSetting(paramsProvider, isFahrenheit).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        LOG.debug("handle Set Temperature unit");
    }
}
