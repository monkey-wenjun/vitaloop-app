/*  Copyright (C) 2025 Me7c7

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
package nodomain.freeyourgadget.gadgetbridge.devices.huawei;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/** ecg_analysis_data.bin（服务 0x2C 命令 1，fileType 0x18）解析。 */
public class HuaweiEcgFileParser {
    private static final int HEADER_SIZE = 32;
    private static final int RECORD_HEADER_SIZE = 56;
    private static final int APP_VERSION_SIZE = 32;
    private static final int MAX_DATA_BYTES = 2_400_000;

    public static class EcgParseException extends RuntimeException {
        EcgParseException(String message) {
            super(message);
        }
    }

    public static class EcgData {
        public final long startTimeMs;
        public final long endTimeMs;
        public final String appVersion;
        public final long arrhythmiaType;
        public final int averageHeartRate;
        public final long userSymptoms;
        public final float[] ecgData;

        EcgData(long startTimeMs, long endTimeMs, String appVersion, long arrhythmiaType,
                int averageHeartRate, long userSymptoms, float[] ecgData) {
            this.startTimeMs = startTimeMs;
            this.endTimeMs = endTimeMs;
            this.appVersion = appVersion;
            this.arrhythmiaType = arrhythmiaType;
            this.averageHeartRate = averageHeartRate;
            this.userSymptoms = userSymptoms;
            this.ecgData = ecgData;
        }
    }

    public static final class Result {
        public final int version;
        public final List<EcgData> records = new ArrayList<>();

        Result(int version) {
            this.version = version;
        }
    }

    public static Result parse(byte[] data) {
        if (data == null || data.length < HEADER_SIZE) {
            throw new EcgParseException("文件比 32B 头还短: " + (data == null ? "null" : data.length));
        }
        ByteBuffer buffer = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN);
        int version = buffer.getShort(6) & 0xFFFF;
        Result result = new Result(version);
        if (version != 0) return result;
        buffer.position(HEADER_SIZE);
        int packageNameLength = buffer.get() & 0xFF;
        if (packageNameLength > buffer.remaining()) {
            throw new EcgParseException("包名长度越界: " + packageNameLength);
        }
        buffer.position(buffer.position() + packageNameLength);

        while (buffer.remaining() >= RECORD_HEADER_SIZE) {
            long startTimeMs = checkTime(buffer.getInt() & 0xFFFFFFFFL);
            long endTimeMs = checkTime(buffer.getInt() & 0xFFFFFFFFL);
            if (startTimeMs > endTimeMs) throw new EcgParseException("开始时间晚于结束时间");
            int dataLength = checkDataLength(buffer.getInt() & 0xFFFFFFFFL);
            String appVersion = readString(buffer, APP_VERSION_SIZE);
            long arrhythmiaType = buffer.getInt() & 0xFFFFFFFFL;
            int averageHeartRate = buffer.getShort() & 0xFFFF;
            buffer.getShort();
            long userSymptoms = buffer.getInt() & 0xFFFFFFFFL;
            if (buffer.remaining() < dataLength) {
                throw new EcgParseException("波形不足: need=" + dataLength + ", remain=" + buffer.remaining());
            }
            float[] ecgData = new float[dataLength / 4];
            for (int i = 0; i < ecgData.length; i++) {
                float value = buffer.getFloat();
                ecgData[i] = Float.isNaN(value) ? 0.0f : value;
            }
            result.records.add(new EcgData(startTimeMs, endTimeMs, appVersion, arrhythmiaType,
                    averageHeartRate, userSymptoms, ecgData));
        }
        return result;
    }

    private static long checkTime(long epochSecond) {
        long timeMs = epochSecond * 1000L;
        if (timeMs <= 0 || timeMs > System.currentTimeMillis()) {
            throw new EcgParseException("时间越界: " + epochSecond);
        }
        return timeMs;
    }

    private static int checkDataLength(long length) {
        if (length <= 0 || length > MAX_DATA_BYTES || length % 4 != 0) {
            throw new EcgParseException("波形长度非法: " + length);
        }
        return (int) length;
    }

    private static String readString(ByteBuffer buffer, int length) {
        byte[] bytes = new byte[length];
        buffer.get(bytes);
        return new String(bytes, StandardCharsets.UTF_8).trim();
    }
}
