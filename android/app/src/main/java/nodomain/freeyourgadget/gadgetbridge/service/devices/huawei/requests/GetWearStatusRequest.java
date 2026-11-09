/*  Copyright (C) 2024 Damien Gaignon

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

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

import com.awen.running.utils.FileLogger;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiTLV;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.DeviceConfig;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.DeviceConfig.WearStatus;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;
import nodomain.freeyourgadget.gadgetbridge.util.StringUtils;

public class GetWearStatusRequest extends Request {
    private static final Logger LOG = LoggerFactory.getLogger(GetWearStatusRequest.class);
    private static final String LOG_TAG = "GetWearStatusRequest";

    public GetWearStatusRequest(IHuaweiSupport support) {
        super(support);
        this.serviceId = DeviceConfig.id;
        this.commandId = WearStatus.id;
    }

    /** 最近一次响应的原始 TLV，日志排查用（出现没见过的取值时靠它认字段） */
    protected String wearStatusDump = "";

    /** tag 0x01 的字节：GT 5 真机实测 0x02=在腕、0x01=离腕；-1 表示响应里没有这一项 */
    protected int wearStatusCode = -1;

    @Override
    protected boolean requestSupported() {
        // 上游这里判的是 supportsMultiDevice()，GT 5 这类单设备手表恒为 false，
        // 命令从未发出去过。改成无条件发送：不支持的手表回一个错误包即可，
        // 卡住的风险由调用方的 setupTimeoutUntilNext 兜底。
        return true;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new WearStatus.Request(paramsProvider).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() {
        // Gadgetbridge 上游把 WearStatus.Response.parseTlv() 留空了，响应体没人解。
        wearStatusDump = dumpTlv(receivedPacket.getTlv());
        wearStatusCode = readStatusCode(receivedPacket.getTlv());
        FileLogger.i(LOG_TAG, "佩戴状态响应(0x01/0x3d): " + wearStatusDump);
        LOG.debug("handle Get Wear Status: {}", wearStatusDump);
    }

    private static int readStatusCode(HuaweiTLV tlv) {
        if (tlv == null) {
            return -1;
        }
        Byte value = tlv.getByte(0x01, (byte) -1);
        return value == null ? -1 : value & 0xFF;
    }

    /** 把 TLV 列表展开成 "tag=0xNN value=HEX | ..." 便于逐次比对 */
    private static String dumpTlv(HuaweiTLV tlv) {
        if (tlv == null) {
            return "(无 TLV)";
        }
        StringBuilder dump = new StringBuilder();
        for (HuaweiTLV.TLV item : tlv.get()) {
            if (dump.length() > 0) {
                dump.append(" | ");
            }
            dump.append("tag=0x")
                    .append(Integer.toHexString(item.getTag() & 0xFF))
                    .append(" value=")
                    .append(StringUtils.bytesToHex(item.getValue()));
        }
        return dump.length() == 0 ? "(空 TLV)" : dump.toString();
    }
}
