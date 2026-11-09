/*
 * 移植自 Gadgetbridge (AGPL-3.0) 的最小宿主类，提供华为协议需要的上下文与设备偏好。
 */
package nodomain.freeyourgadget.gadgetbridge;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.Locale;

public class GBApplication {
    private static Context context;

    public static void init(Context ctx) {
        context = ctx.getApplicationContext();
    }

    public static Context getContext() {
        return context;
    }

    public static SharedPreferences getDeviceSpecificSharedPrefs(String macAddress) {
        return context.getSharedPreferences("device_" + macAddress, Context.MODE_PRIVATE);
    }

    public static String getLanguage() {
        Locale l = Locale.getDefault();
        return l.getLanguage() + "_" + l.getCountry();
    }
}
