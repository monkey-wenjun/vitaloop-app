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
 * 压力/放松服务 0x20。逆向自华为运动健康：HwStressMgr（defpackage/nid）+
 * StressSendCommandUtil（defpackage/niq），字节依据见 docs/REVERSE_STRESS_TEMPERATURE.md 第 3 节。
 *
 * 为什么需要它：官方 App 的压力值**不走** P2P 数据字典（字典分类 500026 在 GT 5 上
 * 85 次请求全回空），而是走这条命令式通道（另一条是 0x0A 的 PeriodRri 文件）。
 * 服务号 0x20 在整个官方 APK 里只被压力模块用到，归属可以确定。
 */
public class Stress {
    public static final byte id = 0x20;

    /** 外层容器：官方 ege 拼出来是 81 <len> <内层 TLV> */
    public static final int tag_container = 0x81;
    /** 索引列表请求的窗口（秒） */
    public static final int tag_startTime = 0x03;
    public static final int tag_endTime = 0x04;
    /** 明细请求的帧索引（2 字节） */
    public static final int tag_frameIndex = 0x02;
    /** 0x20/1、0x20/3 的应答：容器里 tag 2 = 条数、tag 5 = 帧索引（可重复） */
    public static final int tag_frameCount = 0x02;
    public static final int tag_indexList = 0x05;
    /** 0x20/2、0x20/4 的应答子容器：4 = 分数、5 = 采样时刻（秒）、6 = 测量类型 */
    public static final int tag_score = 0x04;
    public static final int tag_sampleTime = 0x05;
    public static final int tag_measureType = 0x06;
    /** 应答错误码，官方按 tag 0x7f 判失败 */
    public static final int tag_errorCode = 0x7f;

    private static HuaweiTLV window(int startTime, int endTime) {
        return new HuaweiTLV()
                .put(tag_startTime, startTime)
                .put(tag_endTime, endTime);
    }

    private static HuaweiTLV frame(short frameIndex) {
        return new HuaweiTLV().put(tag_frameIndex, frameIndex);
    }

    /** 0x20/1：按窗口要压力帧索引列表 */
    public static class StressFrameIndex {
        public static final byte id = 0x01;

        public static class Request extends HuaweiPacket {
            public Request(ParamsProvider paramsProvider, int startTime, int endTime) {
                super(paramsProvider);
                this.serviceId = Stress.id;
                this.commandId = id;
                this.tlv = new HuaweiTLV().put(tag_container, window(startTime, endTime));
                this.complete = true;
            }
        }
    }

    /** 0x20/2：按索引要一条压力明细（应答字段 4=压力分、5=采样时刻秒、6=测量类型） */
    public static class StressRecordDetail {
        public static final byte id = 0x02;

        public static class Request extends HuaweiPacket {
            public Request(ParamsProvider paramsProvider, short frameIndex) {
                super(paramsProvider);
                this.serviceId = Stress.id;
                this.commandId = id;
                this.tlv = new HuaweiTLV().put(tag_container, frame(frameIndex));
                this.complete = true;
            }
        }
    }

    /** 0x20/3：按窗口要放松（呼吸训练）帧索引列表 */
    public static class RelaxFrameIndex {
        public static final byte id = 0x03;

        public static class Request extends HuaweiPacket {
            public Request(ParamsProvider paramsProvider, int startTime, int endTime) {
                super(paramsProvider);
                this.serviceId = Stress.id;
                this.commandId = id;
                this.tlv = new HuaweiTLV().put(tag_container, window(startTime, endTime));
                this.complete = true;
            }
        }
    }

    /** 0x20/4：按索引要一条放松明细 */
    public static class RelaxRecordDetail {
        public static final byte id = 0x04;

        public static class Request extends HuaweiPacket {
            public Request(ParamsProvider paramsProvider, short frameIndex) {
                super(paramsProvider);
                this.serviceId = Stress.id;
                this.commandId = id;
                this.tlv = new HuaweiTLV().put(tag_container, frame(frameIndex));
                this.complete = true;
            }
        }
    }
}
