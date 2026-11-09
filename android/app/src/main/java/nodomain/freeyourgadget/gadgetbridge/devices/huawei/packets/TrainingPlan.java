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

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

import androidx.annotation.Nullable;

/**
 * 华为训练计划下发帧封装（逆向自 com.huawei.health 17.0.7.320）。
 *
 * 官方链路：CoursePlanDeviceManager → HiWearEngineFitnessManager → WearEngine P2P
 * （Gadgetbridge 侧即 serviceId 0x34 P2PCommand），载荷在本帧基础上再走 P2P。
 *
 * 帧结构（全小端）：
 * [36B MsgHeader][业务头（索引表，可空）][protobuf 载荷]
 * MsgHeader: int32 businessType | int32 version(=1) | int32 totalLength(=36+头+载荷)
 *            | int32 businessHeadLength | int32 messageId | 16B 零填充
 * 业务头（官方 ifz 类，仅计划文件消息携带）: int32 计划骨架长度 | int32 条目数
 *            | 条目数 × (int32 课程文件长度, int32 课程类型)
 */
public class TrainingPlan {
    /** 帧头固定长度（官方 dez.e() = 36，写 5 个 int 后剩 16 字节零填充） */
    public static final int HEADER_SIZE = 36;

    // ===== SportHiWearBusinessType（官方枚举原值）=====
    /** 跑步计划握手（AI 健身计划握手也复用此值） */
    public static final int BT_RUN_PLAN_HANDLE_SHAKE = 1;
    /** 跑步计划文件（businessHead 携带课程索引，载荷=PlanInfo+课程文件） */
    public static final int BT_RUN_PLAN_INFO_FILE = 2;
    /** 独立单课程文件 */
    public static final int BT_CUSTOM_COURSE_FILE = 3;
    /** 跑步计划完结 */
    public static final int BT_RUN_PLAN_FINISH = 7;
    /** AI 健身计划文件 */
    public static final int BT_AI_FITNESS_PLAN_INFO_FILE = 21;
    /** AI 健身计划完结 */
    public static final int BT_AI_FITNESS_PLAN_FINISH = 22;
    /** 导入路线握手（官方 SportHiWearBusinessType.TRAJECTORY_HANDLE_SHAKE） */
    public static final int BT_TRAJECTORY_HANDLE_SHAKE = 5;
    /** 导入路线文件（官方 SportHiWearBusinessType.TRAJECTORY_FILE） */
    public static final int BT_TRAJECTORY_FILE = 6;

    // ===== 课程类型（下发设备 protobuf 的 courseType 字段）=====
    // 官方写入点是 FitWorkout.getType()（ijo.java:173、ijm.java:144、
    // BaseCoursePlanDataCustomer.java:47），不是 CourseDataBean.PlanCourseType（0/1/2）——
    // 后者只在手机端过滤用（ijh.java:285），从不进设备包。按 0/1/2 发会让力量课（2）
    // 被手表当成跑步课，2 在官方是 FitWorkout.TYPE_RUN_AC。
    /** 本项目自用哨兵值：比赛日不下发课程文件，按此值过滤（官方课程码里没有 0） */
    public static final int COURSE_TYPE_RACE_DAY = 0;
    /** 官方 FitWorkout.TYPE_RUN_AC：跑步类课程（isRunModelCourse 接受 2/3/4） */
    public static final int COURSE_TYPE_RUN_COURSE = 2;
    /**
     * 官方 FitWorkout.isNewRunCourse()：type==4，分段跑步课的取值——只有 type==4 才走
     * addActions(getCourseActions()) 那条把 RD001/RD002/RD005 逐段编码进 CombineInfo 的
     * 分支（BaseCoursePlanDataCustomer.java:48、ihq.java:37），且 CourseOutLine
     * （ijo.java:173）与 CourseStorageInfo 都写同一个 getType()。
     *
     * 真机（GT 5，2026-11-04 AB 单变量实测）：
     *   type=4 + defineType=0 + version="1"  → 显示成跑步课，点开**能看分段预览**（就用这套）
     *   type=4 + defineType=1 + version="2.0" → 也显示跑步，但点日条目**直接跳进跑步课程**、没预览
     *   type=2（无论 define/version）          → 渲染成力量样式
     * 所以「直接开跑」的开关是 defineType=1（官方 isCustomCourse），不是 type=4；
     * 官方自定义课程编辑器（CustomCourseActivity.java:702-706）会把 type/define/version
     * 三个一起设，照抄就把预览弄没了。生产路径只翻 courseType，defineType 保持 0、version 保持 "1"。
     */
    public static final int COURSE_TYPE_NEW_RUN_COURSE = 4;
    /** 官方 FitWorkout.isEquipmentCourse()：type==5 器械课。手表侧字形未经真机确认 */
    public static final int COURSE_TYPE_STRENGTH_COURSE = 5;

    /** 索引表条目：课程文件长度 + 课程类型（官方 ifz.e） */
    public static class IndexEntry {
        public final int length;
        public final int courseType;

        public IndexEntry(int length, int courseType) {
            this.length = length;
            this.courseType = courseType;
        }
    }

    /** 解析出的帧头（官方 dez 字段命名） */
    public static class MsgHeader {
        public int businessType;
        public int version;
        public int totalLength;
        public int businessHeadLength;
        public int messageId;

        public static MsgHeader parse(byte[] buf, int offset) {
            ByteBuffer bb = ByteBuffer.wrap(buf, offset, HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN);
            MsgHeader h = new MsgHeader();
            h.businessType = bb.getInt();
            h.version = bb.getInt();
            h.totalLength = bb.getInt();
            h.businessHeadLength = bb.getInt();
            h.messageId = bb.getInt();
            return h;
        }
    }

    /**
     * 构造完整下发帧。
     *
     * @param businessType   业务类型（BT_* 常量）
     * @param messageId      递增序号（官方 dez.b()，0..999999 循环）
     * @param planDataLength 业务头首字段：计划骨架字节数（官方 igb.b.d() 传 planData.length；
     *                       握手/完结等无业务头消息传 0）
     * @param indexEntries   业务头索引条目；null 或空 = 不带业务头
     * @param payloads       载荷分段：计划文件时依次为 [计划骨架, 课程1, 课程2...]，
     *                       与 indexEntries 一一对应（第一段为计划骨架本身，不在索引内）
     */
    public static byte[] buildMessage(int businessType, int messageId, int planDataLength,
                                      @Nullable List<IndexEntry> indexEntries,
                                      byte[]... payloads) {
        int payloadLength = 0;
        for (byte[] p : payloads) {
            payloadLength += p.length;
        }
        byte[] businessHead = buildBusinessHead(planDataLength, indexEntries);

        ByteBuffer bb = ByteBuffer.allocate(HEADER_SIZE + businessHead.length + payloadLength);
        bb.order(ByteOrder.LITTLE_ENDIAN);
        bb.putInt(businessType);
        bb.putInt(1); // version
        bb.putInt(HEADER_SIZE + businessHead.length + payloadLength);
        bb.putInt(businessHead.length);
        bb.putInt(messageId);
        // 剩余 16 字节 JVM 保证零填充，业务头从偏移 36 开始
        bb.position(HEADER_SIZE);
        bb.put(businessHead);
        for (byte[] p : payloads) {
            bb.put(p);
        }
        return bb.array();
    }

    /** 构造业务头（官方 ifz：int32 计划骨架长度 + int32 条目数 + 条目×(len,type)，全小端） */
    private static byte[] buildBusinessHead(int planDataLength, @Nullable List<IndexEntry> entries) {
        if (entries == null || entries.isEmpty()) {
            return new byte[0];
        }
        ByteBuffer bb = ByteBuffer.allocate(8 + entries.size() * 8);
        bb.order(ByteOrder.LITTLE_ENDIAN);
        bb.putInt(planDataLength); // 官方 igb.b.d()：f.a(planData.length)
        bb.putInt(entries.size());
        for (IndexEntry e : entries) {
            bb.putInt(e.length);
            bb.putInt(e.courseType);
        }
        return bb.array();
    }

    /** 从响应帧提取结果码（官方 dfc：帧头后 4 字节小端 int，1=失败） */
    public static int parseResponseResult(@Nullable byte[] respData) {
        if (respData == null || respData.length < HEADER_SIZE + 4) {
            return Integer.MIN_VALUE;
        }
        return ByteBuffer.wrap(respData, HEADER_SIZE, 4).order(ByteOrder.LITTLE_ENDIAN).getInt();
    }

    /** 手表对握手响应的语义（官方 PlanSendService）：0=已同步，2=推全量，3=推骨架，1=失败 */
    public static final int HANDSHAKE_ALREADY_SYNCED = 0;
    public static final int HANDSHAKE_PUSH_FULL = 2;
    public static final int HANDSHAKE_PUSH_SKELETON = 3;

    /**
     * 构造计划文件消息（官方 igb 布局）：
     * [帧头][业务头][计划骨架][课程1][课程2...]，索引条目与课程段一一对应。
     *
     * @param businessType BT_RUN_PLAN_INFO_FILE 或 BT_AI_FITNESS_PLAN_INFO_FILE
     * @param planData     计划骨架 protobuf（PlanInfo / GeneralPlanInfo）
     * @param courses      课程段（每段：[长度未知→build 后取 length]，含课程类型）
     */
    public static byte[] buildPlanFileMessage(int businessType, int messageId, byte[] planData,
                                              List<IndexedCourse> courses) {
        List<IndexEntry> entries = new ArrayList<>();
        byte[][] payloads = new byte[courses.size() + 1][];
        payloads[0] = planData;
        for (int i = 0; i < courses.size(); i++) {
            IndexedCourse c = courses.get(i);
            entries.add(new IndexEntry(c.data.length, c.courseType));
            payloads[i + 1] = c.data;
        }
        return buildMessage(businessType, messageId, planData.length, entries, payloads);
    }

    /** 课程段：编码后的课程文件 + 课程类型 */
    public static class IndexedCourse {
        public final byte[] data;
        public final int courseType;

        public IndexedCourse(byte[] data, int courseType) {
            this.data = data;
            this.courseType = courseType;
        }
    }
}
