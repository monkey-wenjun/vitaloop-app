/*  Copyright (C) 2024 Martin.JM

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


import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Weather;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class SendWeatherStartRequest extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(SendWeatherStartRequest.class);

    public int response = -1;
    private Weather.Settings weatherSettings;

    public SendWeatherStartRequest(IHuaweiSupport support, Weather.Settings weatherSettings) {
        super(support);
        this.serviceId = Weather.id;
        this.commandId = Weather.WeatherStart.id;
        this.weatherSettings = weatherSettings;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Weather.WeatherStart.Request(this.paramsProvider).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() throws ResponseParseException {
        if (receivedPacket instanceof Weather.WeatherStart.Response) {
            if (!((Weather.WeatherStart.Response) receivedPacket).success) {
                this.stopChain();
                LOG.info("Received non-ok status for WeatherStart response");
            } else {
                weatherSettings.weatherSupported = true;
            }
        } else {
            this.stopChain();
            LOG.error("WeatherStart response is not of type WeatherStart response");
        }
    }
}
