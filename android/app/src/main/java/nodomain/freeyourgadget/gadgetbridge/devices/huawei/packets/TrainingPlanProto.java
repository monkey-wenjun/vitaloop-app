/*  Copyright (C) 2026 Health Sync project

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
package nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;

import androidx.annotation.Nullable;

/**
 * 华为训练计划下发用的极简 proto2 编码器。
 *
 * schema 从 com.huawei.health 17.0.7.320 内嵌 FileDescriptorProto 还原：
 * runPlan.proto（PlanInfo / PlanShakeHandsInfo）与 course.proto（CourseStorageInfo），
 * 见文档 /tmp 反编译记录与 TRAINING_PLAN_TODO.md 第 2 节。
 *
 * 华为的怪癖：proto 里的字符串字段是 repeated uint32，值为 UTF-8 字节序列
 * （官方 dfd.d() 就是 str.getBytes(UTF_8) 逐字节装箱），编码时必须照做。
 * repeated uint32 未声明 packed=true（proto2 默认），因此每个字节独立 tag+varint。
 */
public class TrainingPlanProto {
    private static final int WIRETYPE_VARINT = 0;
    private static final int WIRETYPE_FIXED64 = 1;
    private static final int WIRETYPE_LENGTH_DELIMITED = 2;

    /**
     * 通用 protobuf 消息累积器，按字段顺序写出。
     */
    public static class Message {
        private final ByteArrayOutputStream buf = new ByteArrayOutputStream();

        /** 写一个 varint 字段（uint32/int32/int64/bool 共用；int32 负值按 64 位补码编码） */
        public Message varint(int fieldNumber, long value) {
            writeTag(fieldNumber, WIRETYPE_VARINT);
            writeVarint(value);
            return this;
        }

        /** 写 repeated uint32 的一个元素（unpacked，每个元素独立 tag） */
        public Message uint32Element(int fieldNumber, long value) {
            return varint(fieldNumber, value);
        }

        /** 写 length-delimited 字段（string / bytes / 嵌套 message 共用） */
        public Message bytesField(int fieldNumber, byte[] value) {
            writeTag(fieldNumber, WIRETYPE_LENGTH_DELIMITED);
            writeVarint(value.length);
            for (byte b : value) {
                buf.write(b);
            }
            return this;
        }

        /** 写字符串字段 */
        public Message string(int fieldNumber, @Nullable String value) {
            return bytesField(fieldNumber, value == null ? new byte[0] : value.getBytes(StandardCharsets.UTF_8));
        }

        /** 华为风格字符串：字符串转 UTF-8 字节后作为 repeated uint32 逐字节写出 */
        public Message stringAsUint32List(int fieldNumber, @Nullable String value) {
            if (value == null) {
                return this;
            }
            for (byte b : value.getBytes(StandardCharsets.UTF_8)) {
                uint32Element(fieldNumber, b & 0xFF);
            }
            return this;
        }

        /** 写嵌套消息（传入已编码字节） */
        public Message message(int fieldNumber, byte[] encoded) {
            return bytesField(fieldNumber, encoded);
        }

        public byte[] build() {
            return buf.toByteArray();
        }

        private void writeTag(int fieldNumber, int wireType) {
            writeVarint(((long) fieldNumber << 3) | wireType);
        }

        private void writeVarint(long value) {
            while (true) {
                if ((value & ~0x7FL) == 0) {
                    buf.write((int) value);
                    return;
                }
                buf.write((int) ((value & 0x7F) | 0x80));
                value >>>= 7;
            }
        }
    }

    // ===== PlanShakeHandsInfo（runPlan.proto，握手/完结共用）=====
    // required string planId=1; required string language=2;
    // required uint32 weekStartTime=3; required uint32 punchTimeStamp=4;

    /** 构造握手/完结消息 PlanShakeHandsInfo（时间均为 epoch 秒） */
    public static byte[] buildPlanShakeHandsInfo(String planId, String language, long weekStartTime, long punchTimeStamp) {
        return new Message()
                .string(1, planId)
                .string(2, language)
                .varint(3, weekStartTime)
                .varint(4, punchTimeStamp)
                .build();
    }

    // ===== CourseStorageInfo（course.proto，单课程文件）=====
    // required string exerciseId=1; repeated uint32 exerciseName=2;
    // required uint32 totalMeasurementType=3; required uint32 totalMeasurementValue=4;
    // required string exerciseVersion=5; required uint32 difficult=6; required uint32 usingType=7;
    // required uint32 updateTime=8; required uint32 defineType=9; required uint32 courseType=10;
    // required uint32 actionTotalNum=11; repeated CombineInfo combineInfo=12;
    // CombineInfo: required uint32 repeatNum=1; required uint32 actionNum=2; repeated ActionInfo actionInfo=3;
    // ActionInfo: required string actionId=1; required uint32 measurementType=2;
    //             required uint32 measurementValue=3; required uint32 instensityType=4;
    //             required uint32 instensityValueH=5; required uint32 instensityValueL=6;

    /**
     * 构造单个动作信息（instensity 为官方拼写错误，保持协议原文）。
     * measurementType/measurementValue 用 255/0 表示无目标（官方 convertAction 的兜底分支）。
     */
    public static byte[] buildActionInfo(String actionId, int measurementType, int measurementValue,
                                         int intensityType, int intensityValueH, int intensityValueL) {
        return new Message()
                .string(1, actionId)
                .varint(2, measurementType)
                .varint(3, measurementValue)
                .varint(4, intensityType)
                .varint(5, intensityValueH)
                .varint(6, intensityValueL)
                .build();
    }

    /** 构造动作组合：repeatNum 次重复，内含 actionInfos 各执行一次 */
    public static byte[] buildCombineInfo(int repeatNum, List<byte[]> actionInfos) {
        Message m = new Message()
                .varint(1, repeatNum)
                .varint(2, actionInfos.size());
        for (byte[] action : actionInfos) {
            m.message(3, action);
        }
        return m.build();
    }

    /** 计划内课程 usingType=1，独立下发课程 usingType=0（官方 pushFitRunCourseData/计划内课程的取值） */
    public static final int USING_TYPE_IN_PLAN = 1;
    public static final int USING_TYPE_STANDALONE = 0;

    /** 构造课程文件 CourseStorageInfo；actionTotalNum = 所有组合内动作总数（官方要求 >0，否则手表侧校验不过） */
    public static byte[] buildCourseStorageInfo(String exerciseId, String exerciseName, int totalMeasurementType,
                                                int totalMeasurementValue, String exerciseVersion, int difficult,
                                                int usingType, long updateTime, int defineType, int courseType,
                                                int actionTotalNum, List<byte[]> combineInfos) {
        Message m = new Message()
                .string(1, exerciseId)
                .stringAsUint32List(2, exerciseName)
                .varint(3, totalMeasurementType)
                .varint(4, totalMeasurementValue)
                .string(5, exerciseVersion)
                .varint(6, difficult)
                .varint(7, usingType)
                .varint(8, updateTime)
                .varint(9, defineType)
                .varint(10, courseType)
                .varint(11, actionTotalNum);
        for (byte[] combine : combineInfos) {
            m.message(12, combine);
        }
        return m.build();
    }

    // ===== PlanInfo（runPlan.proto，计划骨架）=====
    // required PlanBasicInfo planBasicInfo=1; repeated WeekPlanBasicInfo weekPlanBasicInfo=2;
    // repeated DayPlanBasicInfo dayPlanBasicInfo=3;
    // PlanBasicInfo: required string planId=1; repeated uint32 planName=2; required string languageType=3;
    //   required uint32 punchTimeStamp=4; required uint32 planTotalDays=5; required uint32 planTotalWeeks=6;
    //   required uint32 planStartTime=7; required int32 zoneOffset=8;
    // WeekPlanBasicInfo: repeated uint32 weekPlanName=1; required uint32 exerciseTimes=2;
    //   required uint32 currentWeekDays=3; required uint32 weekNum=4;
    //   required uint32 weekPlanStartTime=5; required uint32 weekPlanEndTime=6;
    // DayPlanBasicInfo: required uint32 time=1; required uint32 courseNum=2; required uint32 isDayPunch=3;
    //   repeated CourseOutLine dayPlanCourse=4;
    // CourseOutLine: required string courseId=1; repeated uint32 courseName=2; required uint32 updateTime=3;
    //   required uint32 courseType=4; required uint32 isCoursePunch=5;

    /** 构造 PlanInfo（只编当前周，与官方 iga.e() 一致：仅当前周需要更新） */
    public static byte[] buildPlanInfo(String planId, String planName, String language, long punchTimeStamp,
                                       int planTotalDays, int planTotalWeeks, long planStartTime, int zoneOffsetSeconds,
                                       @Nullable String weekPlanName, int exerciseTimes, int currentWeekDays,
                                       int weekNum, long weekPlanStartTime, long weekPlanEndTime,
                                       List<byte[]> dayPlanBasicInfos) {
        byte[] planBasicInfo = new Message()
                .string(1, planId)
                .stringAsUint32List(2, planName)
                .string(3, language)
                .varint(4, punchTimeStamp)
                .varint(5, planTotalDays)
                .varint(6, planTotalWeeks)
                .varint(7, planStartTime)
                .varint(8, zoneOffsetSeconds)
                .build();
        Message root = new Message().message(1, planBasicInfo);
        if (weekPlanName != null) {
            byte[] weekInfo = new Message()
                    .stringAsUint32List(1, weekPlanName)
                    .varint(2, exerciseTimes)
                    .varint(3, currentWeekDays)
                    .varint(4, weekNum)
                    .varint(5, weekPlanStartTime)
                    .varint(6, weekPlanEndTime)
                    .build();
            root.message(2, weekInfo);
        }
        for (byte[] day : dayPlanBasicInfos) {
            root.message(3, day);
        }
        return root.build();
    }

    /** 构造单日课程 DayPlanBasicInfo */
    public static byte[] buildDayPlanBasicInfo(long dayStartEpochSec, int isDayPunch, List<byte[]> courseOutLines) {
        Message m = new Message()
                .varint(1, dayStartEpochSec)
                .varint(2, courseOutLines.size())
                .varint(3, isDayPunch);
        for (byte[] course : courseOutLines) {
            m.message(4, course);
        }
        return m.build();
    }

    /** 构造课程条目 CourseOutLine */
    public static byte[] buildCourseOutLine(String courseId, String courseName, long updateTime,
                                            int courseType, int isCoursePunch) {
        return new Message()
                .string(1, courseId)
                .stringAsUint32List(2, courseName)
                .varint(3, updateTime)
                .varint(4, courseType)
                .varint(5, isCoursePunch)
                .build();
    }
}
