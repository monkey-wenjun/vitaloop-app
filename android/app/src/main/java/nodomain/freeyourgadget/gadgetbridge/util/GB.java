/*
 * 移植自 Gadgetbridge (AGPL-3.0) 的最小工具集，仅包含华为协议层需要的方法。
 * 完整实现见: https://github.com/Freeyourgadget/Gadgetbridge
 */
package nodomain.freeyourgadget.gadgetbridge.util;

import android.util.Log;

public final class GB {

    private static final char[] HEX_CHARS = "0123456789abcdef".toCharArray();
    public static final int ERROR = 0;

    private GB() {
    }

    public static String hexdump(byte[] buffer, int offset, int length) {
        if (length == -1) {
            length = buffer.length - offset;
        }
        char[] hexChars = new char[length * 2];
        for (int i = 0; i < length; i++) {
            int v = buffer[i + offset] & 0xFF;
            hexChars[i * 2] = HEX_CHARS[v >>> 4];
            hexChars[i * 2 + 1] = HEX_CHARS[v & 0x0F];
        }
        return new String(hexChars);
    }

    public static String hexdump(byte[] buffer) {
        return hexdump(buffer, 0, buffer.length);
    }

    public static byte[] hexStringToByteArray(String s) {
        int len = s.length();
        byte[] data = new byte[len / 2];
        for (int i = 0; i < len; i += 2) {
            data[i / 2] = (byte) ((Character.digit(s.charAt(i), 16) << 4)
                    + Character.digit(s.charAt(i + 1), 16));
        }
        return data;
    }

    public static void toast(String message, int duration, int style) {
        Log.e("GB", message);
    }

    public static void toast(String message, int duration, int style, Exception e) {
        Log.e("GB", message, e);
    }
}
