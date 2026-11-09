/*
 * 移植自 Gadgetbridge (AGPL-3.0) 的最小工具类
 */
package nodomain.freeyourgadget.gadgetbridge.util;

import nodomain.freeyourgadget.gadgetbridge.model.Alarm;

public class AlarmUtils {
    public static int createRepetitionMask(
            boolean mon, boolean tue, boolean wed, boolean thu,
            boolean fri, boolean sat, boolean sun) {
        return (mon ? Alarm.ALARM_MON : 0) |
                (tue ? Alarm.ALARM_TUE : 0) |
                (wed ? Alarm.ALARM_WED : 0) |
                (thu ? Alarm.ALARM_THU : 0) |
                (fri ? Alarm.ALARM_FRI : 0) |
                (sat ? Alarm.ALARM_SAT : 0) |
                (sun ? Alarm.ALARM_SUN : 0);
    }
}
