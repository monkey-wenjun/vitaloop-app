package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.GBApplication;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiConstants;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.FitnessData;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class SetSkinTemperatureMeasurement extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(SetSkinTemperatureMeasurement.class);

    public SetSkinTemperatureMeasurement(IHuaweiSupport support) {
        super(support);
        this.serviceId = FitnessData.id;
        this.commandId = FitnessData.SkinTemperatureMeasurement.id;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        // 默认开：这里是"每次连接都把开关写回手表"的那条命令，默认 false 等于本 App 主动
        // 关掉了连续皮肤温度测量 —— 实测 400012 从写入默认值那天起再也没有新样本。
        boolean temperatureSwitch = GBApplication
                .getDeviceSpecificSharedPrefs(this.getDevice().getAddress())
                .getBoolean(HuaweiConstants.PREF_HUAWEI_CONTINUOUS_SKIN_TEMPERATURE_MEASUREMENT, true);
        try {
            return new FitnessData.SkinTemperatureMeasurement.Request(paramsProvider, temperatureSwitch).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        LOG.debug("handle Set SkinTemperatureMeasurement");
    }
}
