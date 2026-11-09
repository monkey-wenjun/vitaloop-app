package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import java.util.List;

import com.awen.running.utils.FileLogger;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Watchface;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class GetWatchfacePhotoInfo extends Request {
    private final int optionMask;

    public GetWatchfacePhotoInfo(IHuaweiSupport support, int optionMask) {
        super(support);
        this.serviceId = Watchface.id;
        this.commandId = Watchface.WatchfacePhotoInfo.id;
        this.optionMask = optionMask;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Watchface.WatchfacePhotoInfo.Request(this.paramsProvider, this.optionMask).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() throws ResponseParseException {
        if (!(this.receivedPacket instanceof Watchface.WatchfacePhotoInfo.Response))
            throw new ResponseTypeMismatchException(this.receivedPacket, Watchface.WatchfacePhotoInfo.Response.class);

        Watchface.WatchfacePhotoInfo.Response resp = (Watchface.WatchfacePhotoInfo.Response) this.receivedPacket;
        FileLogger.i("WatchfacePhotoInfo",
                "0x27/0x08 相册表盘能力: maxBackgroundImages=" + resp.maxBackgroundImages
                        + " intellectColor=" + resp.supportIntellectColor
                        + " backgroundType=" + resp.backgroundType
                        + " positionIndex=" + resp.positionIndex
                        + " styleIndex=" + resp.styleIndex
                        + " dataIndex=" + resp.dataIndex
                        + " bgImageOption=" + resp.bgImageOption
                        + " portPositionIndex=" + resp.portPositionIndex
                        + " portraitMode=" + resp.portraitMode
                        + " rawTlv=" + resp.rawTlv);
    }
}
