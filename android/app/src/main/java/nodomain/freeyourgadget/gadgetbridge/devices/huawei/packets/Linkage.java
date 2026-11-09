/*  Copyright (C) 2026 Awen

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

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiTLV;

/**
 * 服务 0x37 —— 华为运动健康内部叫 linkage / SamplePoint 的那条总线。
 *
 * 逆向依据（反编译的官方 APK，行号对应 jadx 输出）：
 * - 帧编码与 0x17 同一套：发送侧 ypc.b() 用 PROTOCOL_TYPE_5A（ypc.java:138），
 *   payload[0]=serviceId payload[1]=command，TLV 从 payload[2] 起（cnl.java:422-453、yom.java:339）。
 * - 子命令：1=Config 2=Event 3=SamplePoint 4=DictPoint 5=CompactDict（yom.java:257-276）。
 * - 外层 TLV：1=srcPackage 2=dstPackage 3=dictTypeId/eventId 4/5=起止时间或 eventData
 *   10=meta 127=errCode（yom.java:584-614）。
 * - 骑行码表用的是包名对 hw.sport.linkage.device ↔ hw.sport.linkage.app。
 *   手表开启运动并要推送手机时先发 Event：eventId=800400014，eventData 按 nlm 排布
 *   （tag1=workoutType tag2=linkageOperation tag3=linkageTimeStamp tag4=replyCode tag5=currentStatus，
 *   nlm.java:15-21），linkageOperation=0 即"手机请开始联动"。
 * - Event 的 tag2 linkageOperation 值域（nlm.java:29-45 的分发）：
 *   0=startLinkage、1=stopLinkage（＝本轮运动结束）、2=resumeLinkage、3=reportLinkageStatus。
 *   结束提醒就靠 1，另外 SamplePoint 的 operator_type(50004770)=4/0 也是同义信号。
 * - 手机侧唯一的出站就是这条 Event 的回复（fkm.java:274 → nla.java:64-79 → nlt.e() → nlr.java:16）：
 *   包名互换 + 同一 eventId + tag5 内放 `02 01 <opAck> 04 01 <replyCode>`。
 * - SamplePoint 的批包：外层容器 tag6(0x86) 里每个点一个容器 tag7(0x87)，
 *   点内 tag8=dicId（大端最小宽度）tag9=value；值类型按 dicId 硬编码，不依赖 0x34 字典
 *   （yom.java:739-763、nlf.java:58-80）。
 *
 * dicId 表（运动实时＝50004 号字典，fmp.java:60-103 全量 39 项）：
 * 50004396 exercise_duration(秒) / 50004765 distance(米×10) / 50004799 speed(km/h×100) /
 * 50004829 calorie(kcal×1000) / 50004838 hr / 50004979 pace / 50004858 avg_speed /
 * 50004872 avg_pace / 50004395 total_rise(米×10) / 50004774 total_descend / 50004286 altitude(米×10) /
 * 50004254 linkage_cadence / 50004757 linkage_power / 50004770 operator_type /
 * 50004934 linkage_slope / 50004388 latitude / 50004935 longitude
 *
 * 海拔单位是 0.1 米：GT5 室内实测 50004286=00000421（1057），真实海拔约 108 m，
 * 同一包里 distance 也是 ×10（官方 MirrorLinkDataSource.java:73 除以 10）。
 * 官方消费层把海拔/爬升当米直接塞通知栏（hfd.java:56-63、MirrorLinkDataSource.java:121），
 * 那是它自己显示偏大 10 倍，不跟。
 * 50004642 是「最高海拔」不是气压：flt.java 把它交给 olv.r(int)→字段 ab，
 * 由 olv.ad() 读出，消费处就是 MAX_ALTITUDE_DATA（MirrorLinkDataSource.java:81,122）。
 * 整条运动联动链路里没有气压字段：39 项字典（fmp.java:60-103）和所有 dicId→名字表都没有
 * pressure 键，APK 里带 "pressure" 的只有血压/日常健康数据（hiHealthData）。
 *
 * 经纬度不在这张 39 项字典里（fmp.java:60-103），但 SamplePoint 的值照样带：
 * 50004388=纬度、50004935=经度，8 字节大端 IEEE754 double（nlf.java:61-64 的字段名 +
 * cor.e(bytes,-255.0) 的解码宽度，cor.java:211-223），无效值 -255.0。
 * 室内手表发单字节 0xFF 占位，所以只认 8 字节的值，其余一律当没定位。
 */
public class Linkage {
    public static final byte id = 0x37;

    public static final String SPORT_DEVICE_PACKAGE = "hw.sport.linkage.device";
    public static final String SPORT_APP_PACKAGE = "hw.sport.linkage.app";

    public static class Config {
        public static final byte id = 0x01;
    }

    public static class Event {
        public static final byte id = 0x02;

        /**
         * eventId → 处理器与 eventData 字典（官方 nln.java:15-18 的注册表）。
         * 三个 id 的字段宽度不一样，按同一套字典硬读会把时间戳高位读成"运动类型 417"这种鬼值：
         *  LINKAGE_CONTROL 800400014：t1 workoutType(1B) t2 operation(1B) t3 ts(8B)
         *                              t4 replyCode(1B) t5 currentStatus(1B) —— nlm.java:16-20
         *  SPORT_START    800400002：t1 开始时间戳(8B) t2 workoutType(8B)      —— nls.java:16-17
         *  SPORT_PAUSE    800400004：t1 时间戳(8B)     t2 workoutType(8B)      —— nlk.java:16（官方调 pause()）
         */
        public static final int LINKAGE_CONTROL = 800400014;
        public static final int SPORT_START = 800400002;
        public static final int SPORT_PAUSE = 800400004;

        /**
         * 回复手表的联动请求：src/dst 与来包互换，eventId 原样回，
         * eventData 只有 opAck 与 replyCode 两个字段。
         */
        public static class Reply extends HuaweiPacket {
            public Reply(ParamsProvider paramsProvider, String srcPackage, String dstPackage,
                         int eventId, byte eventLevel, byte opAck, byte replyCode) {
                super(paramsProvider);
                this.serviceId = Linkage.id;
                this.commandId = id;
                this.tlv = new HuaweiTLV()
                        .put(0x01, srcPackage)
                        .put(0x02, dstPackage)
                        .put(0x03, eventId)
                        .put(0x04, eventLevel)
                        .put(0x05, new HuaweiTLV()
                                .put(0x02, opAck)
                                .put(0x04, replyCode)
                                .serialize());
                this.complete = true;
            }
        }
    }

    public static class SamplePoint {
        public static final byte id = 0x03;
    }
}
