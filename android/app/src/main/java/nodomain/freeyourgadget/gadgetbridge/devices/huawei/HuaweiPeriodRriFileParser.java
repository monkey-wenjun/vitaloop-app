/*  Copyright (C) 2026 awen

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
import java.util.ArrayList;
import java.util.List;

/**
 * rrisqi_data.bin（服务 0x2C 命令 1，fileType 0x10）解析。
 *
 * 布局照抄官方 defpackage/nje.java:16-208：48 字节头 + N 条定长记录。
 * 头 = 8B 文件大小 + 2B bitmap + 2B 版本 + 36B（v3）/1B 每条样本数 + 35B（v1/v2）保留。
 *
 * 只有 v3 有意义：分数是手表算好的，直接落在记录第 12 字节。
 * v1/v2 存的是原始 RR 间期 + SQI，官方要拿到手机上过 native 库 libPressureCalibrate 再算
 * （nje.java:43-48 → njd.java:191），我们不做这件事，所以这两版直接判为不支持。
 */
public class HuaweiPeriodRriFileParser {
    private static final int HEADER_SIZE = 48;
    private static final int STRESS_RECORD_SIZE = 66;
    private static final int VERSION_WITH_WATCH_SCORE = 3;

    public static class StressRecord {
        public final long startTimeSec;
        public final long endTimeSec;
        public final int algorithmVersion;
        public final int score;
        public final int grade;
        public final int calibFlag;
        public final int measureType;

        StressRecord(long startTimeSec, long endTimeSec, int algorithmVersion, int score,
                     int grade, int calibFlag, int measureType) {
            this.startTimeSec = startTimeSec;
            this.endTimeSec = endTimeSec;
            this.algorithmVersion = algorithmVersion;
            this.score = score;
            this.grade = grade;
            this.calibFlag = calibFlag;
            this.measureType = measureType;
        }
    }

    public static final class Result {
        public final int version;
        public final List<StressRecord> records = new ArrayList<>();
        // 被官方那两条校验式毙掉的计数：真机对不上时，先知道是「空槽」还是「字段不在我以为的偏移」
        public int emptyTimeRecords;
        public int zeroAlgorithmVersionRecords;

        Result(int version) {
            this.version = version;
        }
    }

    /** 头部版本；文件不完整时返回 -1 */
    public static int readVersion(byte[] data) {
        if (data == null || data.length < HEADER_SIZE) return -1;
        return ByteBuffer.wrap(data).getShort(10) & 0xFFFF;
    }

    public static Result parse(byte[] data) {
        int version = readVersion(data);
        if (version < 0) {
            throw new IllegalArgumentException("文件比 48B 头还短: " + (data == null ? "null" : data.length));
        }
        Result result = new Result(version);
        if (version != VERSION_WITH_WATCH_SCORE) {
            // v1/v2 需要手机侧算，本项目原则是不塞没算出来的值，这里只回版本号让上层记日志
            return result;
        }
        int body = data.length - HEADER_SIZE;
        if (body % STRESS_RECORD_SIZE != 0) {
            throw new IllegalArgumentException("v3 记录长度不整除: body=" + body);
        }
        int count = body / STRESS_RECORD_SIZE;
        ByteBuffer buffer = ByteBuffer.wrap(data);
        for (int i = 0; i < count; i++) {
            int base = HEADER_SIZE + i * STRESS_RECORD_SIZE;
            // 绝对索引是相对整个数组的 0，不是切片开头：早先按 wrap(data, base, 66).getInt(0)
            // 写，每条记录读到的都是头部那 4 个 0 字节，123 条全被判成空槽
            long startTime = Integer.toUnsignedLong(buffer.getInt(base));
            long endTime = Integer.toUnsignedLong(buffer.getInt(base + 4));
            // 官方同款过滤：起止时间有一为 0 就是手表留的空槽（nje.java:166-176）
            if (startTime == 0 || endTime == 0) {
                result.emptyTimeRecords++;
                continue;
            }
            int algorithmVersion = buffer.getInt(base + 8);
            if (algorithmVersion <= 0) {
                result.zeroAlgorithmVersionRecords++;
                continue;
            }
            result.records.add(new StressRecord(
                    startTime,
                    endTime,
                    algorithmVersion,
                    buffer.get(base + 12) & 0xFF,
                    buffer.get(base + 13) & 0xFF,
                    buffer.get(base + 14) & 0xFF,
                    buffer.get(base + 15) & 0xFF
            ));
        }
        return result;
    }

    /** 只用来在日志里自证「这条算式对得上」：头部声明的条目数 vs 实际字节数 */
    public static String describe(byte[] data) {
        if (data == null) return "null";
        int version = readVersion(data);
        int body = Math.max(0, data.length - HEADER_SIZE);
        if (version == VERSION_WITH_WATCH_SCORE) {
            return "version=3 size=" + data.length + " records=" + (body / STRESS_RECORD_SIZE)
                    + " remainder=" + (body % STRESS_RECORD_SIZE);
        }
        if (version >= 1 && version <= 2) {
            int samplesPerRecord = data.length >= HEADER_SIZE ? (data[12] & 0xFF) : 0;
            int recordSize = samplesPerRecord * 3 + 6;
            return "version=" + version + " size=" + data.length + " samples=" + samplesPerRecord
                    + " recordSize=" + recordSize + " records="
                    + (recordSize > 0 ? body / recordSize : 0);
        }
        return "version=" + version + " size=" + data.length;
    }
}
