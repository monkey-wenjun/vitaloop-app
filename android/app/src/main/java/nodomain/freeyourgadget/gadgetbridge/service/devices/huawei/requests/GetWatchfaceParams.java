/*  Copyright (C) 2024 Vitalii Tomin

    This file is part of Gadgetbridge.

    Gadgetbridge is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Gadgetbridge is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>. */

package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import java.util.List;

import com.awen.running.utils.FileLogger;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Watchface;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class GetWatchfaceParams extends Request{

    public GetWatchfaceParams(IHuaweiSupport support) {
        super(support);
        this.serviceId = Watchface.id;
        this.commandId = Watchface.WatchfaceParams.id;

    }

    @Override
    protected boolean requestSupported() {
        return supportProvider.getHuaweiCoordinator().supportsWatchfaceParams();
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Watchface.WatchfaceParams.Request(paramsProvider).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() throws ResponseParseException {
        if (!(receivedPacket instanceof Watchface.WatchfaceParams.Response))
            throw new ResponseTypeMismatchException(receivedPacket, Watchface.WatchfaceParams.Response.class);

        Watchface.WatchfaceParams.Response resp = (Watchface.WatchfaceParams.Response)(receivedPacket);
        // 手表在这条命令的回包里带能力位图（华为侧 tag 0x11 → supportCapability）。上游只看 0x01-0x06，
        // 而「要不要给表盘签名」恰恰是这个位图的第 3 位决定的，所以把原始 TLV 全打出来。
        FileLogger.i("WatchfaceParams", "0x27/0x01 原始回包 TLV: " + resp.rawTlv);
        supportProvider.setWatchfaceDeviceParams(resp.params);
    }
}
