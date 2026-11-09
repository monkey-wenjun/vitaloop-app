/*  Copyright (C) 2024 Vitalii Tomin

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

package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import java.util.List;

import com.awen.running.utils.FileLogger;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiTLV;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Watchface;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class SendWatchfaceOperation extends Request {
    private String fileName;
    private byte operation;
    public SendWatchfaceOperation(IHuaweiSupport support, String filename, byte operation) {
        super(support);
        this.serviceId = Watchface.id;
        this.commandId = Watchface.WatchfaceOperation.id;
        this.fileName = filename;
        this.operation = operation;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Watchface.WatchfaceOperation.Request(this.paramsProvider, this.fileName, this.operation ).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    /**
     * 上游的 WatchfaceOperation.Response 一个字段都不解析，手表回不回话、有没有办成都看不见，
     * 所以在这里把判据读出来。
     *
     * GT 5-DE1 实测：回包是 {@code 01=标识 02=版本 04=结果 7f=错误码}，判据要两个字段一起看：
     * <ul>
     *   <li>{@code 04=0 且 7f=0} —— 真切了（切到已装的数字 hitopId + 正确版本）；</li>
     *   <li>{@code 04=0 且 7f≠0} —— 这个 id 在手表的表盘表里，但内容没加载起来：推上去的占位表盘
     *       {@code 990000001} 回的就是 {@code 7f=0x000186ae}(100014)；</li>
     *   <li>{@code 04=1} —— 手表表里没有这个 id（用表盘名代替 hitopId、id 不存在、版本对不上都是它）。</li>
     * </ul>
     * 详见 docs/REVERSE_WATCHFACE_PACKAGE.md §11、§12。
     */
    @Override
    protected void processResponse() {
        HuaweiTLV tlv = this.receivedPacket.getTlv();
        byte result = tlv.getByte(0x04, (byte) -1);
        long errorCode = readErrorCode(tlv);
        String verdict;
        if (result != 0) {
            verdict = "未生效（表里没有这个 id）";
        } else if (errorCode != 0) {
            verdict = "id 已登记，但内容加载失败 错误码=" + errorCode;
        } else {
            verdict = "已生效";
        }
        FileLogger.INSTANCE.i("WatchfaceOperation",
                "手表回包 " + verdict + " op=" + operation + " file=" + fileName
                        + " tlv=" + describeReceivedTlv());
    }

    private static long readErrorCode(HuaweiTLV tlv) {
        byte[] raw = tlv.getBytes(0x7f, new byte[0]);
        long value = 0;
        for (byte b : raw) {
            value = (value << 8) | (b & 0xff);
        }
        return value;
    }

}
