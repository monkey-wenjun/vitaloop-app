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

import java.util.List;

import com.awen.running.utils.FileLogger;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HeartRateZonesConfig;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiCoordinator;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.FitnessData;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class SendHeartRateZonesConfig extends Request {

    private static final String TAG = "HeartRateZones";

    private final int age;
    private final int restHeartRate;
    private final int maxHeartRate;

    public SendHeartRateZonesConfig(IHuaweiSupport support, int age, int restHeartRate, int maxHeartRate) {
        super(support);
        this.age = age;
        this.restHeartRate = restHeartRate;
        this.maxHeartRate = maxHeartRate;
        this.serviceId = FitnessData.id;
        this.commandId = supportProvider.getHuaweiCoordinator().supportsExtendedHeartRateZones() ?
                FitnessData.HeartRateZoneConfigPacket.id_extended :
                FitnessData.HeartRateZoneConfigPacket.id_simple;
    }

    @Override
    protected boolean requestSupported() {
        HuaweiCoordinator coordinator = supportProvider.getHuaweiCoordinator();
        boolean supported = !coordinator.supportsTrack() && coordinator.supportsHeartRateZones();
        if (!supported) {
            FileLogger.INSTANCE.i(TAG, "心率区间未下发: supportsTrack=" + coordinator.supportsTrack()
                    + " supportsHeartRateZones(0x07/0x13)=" + coordinator.supportsHeartRateZones());
        }
        return supported;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            boolean extended = supportProvider.getHuaweiCoordinator().supportsExtendedHeartRateZones();
            HeartRateZonesConfig heartRateZonesConfig = new HeartRateZonesConfig(
                    HeartRateZonesConfig.TYPE_UPRIGHT, age, restHeartRate, maxHeartRate,
                    HeartRateZonesConfig.CALCULATE_METHOD_HRR);
            FileLogger.INSTANCE.i(TAG, "下发心率区间 "
                    + "packet=" + (extended ? "extended(0x21)" : "simple(0x13)")
                    + " 年龄=" + age + " 静息=" + restHeartRate + " 最大=" + maxHeartRate
                    + " HRR边界(bpm)=" + heartRateZonesConfig.getHRRBasicAerobic() + "/"
                    + heartRateZonesConfig.getHRRAdvancedAerobic() + "/"
                    + heartRateZonesConfig.getHRRLactate() + "/"
                    + heartRateZonesConfig.getHRRBasicAnaerobic() + "/"
                    + heartRateZonesConfig.getHRRAdvancedAnaerobic());
            if (extended) {
                return FitnessData.HeartRateZoneConfigPacket.Request.requestExtended(paramsProvider, heartRateZonesConfig).serialize();
            } else {
                return FitnessData.HeartRateZoneConfigPacket.Request.requestSimple(paramsProvider, heartRateZonesConfig).serialize();
            }
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }
}
