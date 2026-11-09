/*
 * 移植自 Gadgetbridge (AGPL-3.0) 的最小用户模型，用于向手表上报用户信息。
 * 后续可改为从 App 的用户资料读取。
 */
package nodomain.freeyourgadget.gadgetbridge.model;

import java.time.LocalDate;

public class ActivityUser {
    public static final int GENDER_UNKNOWN = 0;
    public static final int GENDER_MALE = 1;
    public static final int GENDER_FEMALE = 2;
    public static final int defaultUserStepsGoal = 8000;
    public static final String PREF_USER_STEPS_GOAL = "fitness_goal";

    public int getGender() {
        return GENDER_UNKNOWN;
    }

    public int getHeightCm() {
        return 175;
    }

    public int getWeightKg() {
        return 70;
    }

    public int getAge() {
        return 30;
    }

    public LocalDate getDateOfBirth() {
        return LocalDate.now().minusYears(getAge());
    }
}
