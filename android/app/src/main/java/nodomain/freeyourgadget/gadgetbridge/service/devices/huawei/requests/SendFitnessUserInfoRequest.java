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

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.LocalDate;
import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.FitnessData;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.FitnessData.UserInfo;
import com.awen.running.huawei.VitaloopUserProfile;
import com.awen.running.utils.FileLogger;
import nodomain.freeyourgadget.gadgetbridge.model.ActivityUser;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class SendFitnessUserInfoRequest extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(SendFitnessUserInfoRequest.class);

    public SendFitnessUserInfoRequest(IHuaweiSupport support) {
        super(support);
        this.serviceId = FitnessData.id;
        this.commandId = UserInfo.id;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            // Hardcoded values till interface for goal
            ActivityUser activityUser = new ActivityUser();
            byte gender = UserInfo.UserInfoData.GENDER_UNKNOWN;
            if (activityUser.getGender() == ActivityUser.GENDER_FEMALE) {
                gender = UserInfo.UserInfoData.GENDER_FEMALE;
            } else if (activityUser.getGender() == ActivityUser.GENDER_MALE) {
                gender = UserInfo.UserInfoData.GENDER_MALE;
            }

            LocalDate dateOfBirth = activityUser.getDateOfBirth();
            int birthdayEncoded = dateOfBirth.getYear() << 16;
            birthdayEncoded += dateOfBirth.getMonthValue() << 8;
            birthdayEncoded += dateOfBirth.getDayOfMonth();

            int heightCm = activityUser.getHeightCm();
            int weightKg = activityUser.getWeightKg();
            int userAge = activityUser.getAge();
            // 元环有真实资料时优先用它：手表上的年龄/身高/体重就是这条命令刷进去的。
            if (VitaloopUserProfile.INSTANCE.getReady()) {
                userAge = VitaloopUserProfile.INSTANCE.getAge();
                heightCm = VitaloopUserProfile.INSTANCE.getHeightCm();
                weightKg = VitaloopUserProfile.INSTANCE.getWeightKg();
                int birthday = VitaloopUserProfile.INSTANCE.getBirthday();
                if (birthday > 0) {
                    birthdayEncoded = birthday;
                }
                int g = VitaloopUserProfile.INSTANCE.getGender();
                if (g == UserInfo.UserInfoData.GENDER_MALE || g == UserInfo.UserInfoData.GENDER_FEMALE) {
                    gender = (byte) g;
                }
            }
            FileLogger.INSTANCE.i("UserInfo", "上报用户资料 年龄=" + userAge + " 身高=" + heightCm
                    + " 体重=" + weightKg + " 生日=" + Integer.toHexString(birthdayEncoded)
                    + " 性别=" + gender);

            boolean unknownGenderSupported = supportProvider.getHuaweiCoordinator().supportsUnknownGender();
            //TODO: discover Vo2Max capability and retrieve calculate and set proper values. Currently disabled.
            boolean vo2Supported = false;
            int vo2Max = 0;
            int vo2Time = 0;
            boolean precisionWeightSupported = supportProvider.getHuaweiCoordinator().supportsPrecisionWeight();

            UserInfo.UserInfoData userInfoData = new UserInfo.UserInfoData(
                    heightCm,
                    weightKg,
                    userAge,
                    birthdayEncoded,
                    gender,
                    unknownGenderSupported,
                    vo2Supported,
                    vo2Max,
                    vo2Time,
                    precisionWeightSupported);

            return new UserInfo.Request(paramsProvider, userInfoData).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        LOG.debug("handle Send Fitness UserInfo Request");
    }
}
