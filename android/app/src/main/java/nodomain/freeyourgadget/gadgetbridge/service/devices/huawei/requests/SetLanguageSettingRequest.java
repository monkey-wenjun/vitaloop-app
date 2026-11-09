/*  Copyright (C) 2024 Damien Gaignon, Martin.JM

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

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Locale;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.LocaleConfig;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.LocaleConfig.SetLanguageSetting;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class SetLanguageSettingRequest extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(SetLanguageSettingRequest.class);

    private final String localeString;
    private final byte measurement;

    public SetLanguageSettingRequest(IHuaweiSupport support, String localeString, byte measurement) {
        super(support);
        this.localeString = localeString;
        this.measurement = measurement;
        this.serviceId = LocaleConfig.id;
        this.commandId = SetLanguageSetting.id;
    }

    @Override
    protected boolean requestSupported() {
        return supportProvider.getHuaweiCoordinator().supportsLanguageSetting();
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new SetLanguageSetting(paramsProvider, localeString.getBytes(StandardCharsets.UTF_8), measurement).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        LOG.debug("handle Set Locale");
    }
}
