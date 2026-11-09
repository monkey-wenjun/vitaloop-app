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
package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

import com.awen.running.utils.FileLogger;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiTLV;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.HuaweiP2PManager;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.HuaweiUploadManager;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendFileUploadInfo;

/**
 * 华为手表离线地图 P2P 服务（逆向自 com.huawei.health 17.0.7.320 的
 * com.huawei.maps.offlinedata.service.device.d）。
 *
 * 与训练计划/路线那条链路**不是同一套封装**：地图载荷不带 36 字节小端业务头，
 * 而是 {@code [1 字节命令号][TLV…]}，TLV 长度为 base-128 变长、整数大端
 * （与我们 HuaweiTLV 的写法一致）。身份换成 mapkit：
 *   srcPackage = hw.unitedevice.mapkit，dstPackage = in.huawei.mapkit，
 *   dstFingerprint = SystemApp。
 *
 * 手表侧要求能力位 201（离线地图，真机 GT 5 实测 true）。
 *
 * 地图包本体是华为 map-drcn 云下发的私有打包矢量瓦片，手机只是转发器：
 * 官方传输阶段只要求"目录里正好一个文件"，不重新校验 hash、不看扩展名，
 * 所以这里同样复用已验证的 0x28 文件通道（fileType=7）原样送出文件字节。
 */
public class HuaweiP2PMapService extends HuaweiBaseP2PService {
    private static final Logger LOG = LoggerFactory.getLogger(HuaweiP2PMapService.class);
    private static final String TAG = "HuaweiP2PMapService";

    public static final String MODULE = "hw.unitedevice.mapkit";
    private static final String DST_PACKAGE = "in.huawei.mapkit";
    private static final String DST_FINGERPRINT = "SystemApp";
    private static final String SLOT_OWNER_MAP = "offlinemap";

    /** 命令号（service/device/consts/b） */
    public static final int CMD_QUERY_REMAIN_SPACE = 0x01;
    public static final int CMD_QUERY_DOWNLOADED_MAP = 0x03;
    public static final int CMD_TRANSMIT_HANDSHAKE = 0x04;
    public static final int CMD_DELETE_MAP = 0x05;
    public static final int CMD_PARSE_FINISH = 0x08;

    /** 业务 TLV 标签 */
    private static final int TAG_POLITICAL = 2;
    private static final int TAG_REQUEST_MARKER = 1;
    private static final int TAG_REMAIN_SPACE = 1;
    private static final int TAG_TOTAL_FRAME_NUM = 4;
    private static final int TAG_FRAME_INDEX = 5;
    private static final int TAG_TOTAL_MAP_NUM = 6;
    private static final int TAG_CITY_ID = 9;
    private static final int TAG_MAP_TYPE = 10;
    private static final int TAG_HANDSHAKE_RESULT = 12;
    private static final int TAG_MAP_SIZE = 13;
    private static final int TAG_SYNC_TYPE = 14;
    private static final int TAG_MSG_ID = 19;
    private static final int TAG_ALLOWED_MAP_COUNT = 20;
    private static final int TAG_PARSE_CODE = 21;
    private static final int TAG_DOWNLOAD_TYPE = 22;

    /** 握手回码（consts/a）：只有 0 表示可以发文件 */
    public static final int MAP_SUCCESS = 0;

    /** 传输层自己出问题时用，不能和手表回码撞车 */
    public static final int RESULT_TRANSPORT_ERROR = -1;
    /** 文件已送达、手表尚未回解析完成帧 */
    public static final int RESULT_DELIVERED = 2;

    /** waiters 的键：命令号本身，文件传输单独占一个键 */
    public static final int KEY_FILE_TRANSFER = 0x100;

    private final Map<Integer, HuaweiP2PCallback> waiters = new ConcurrentHashMap<>();

    /** 官方 tlvtools.b：msgId 从 1 递增、按 10000 取模 */
    private final AtomicInteger messageId = new AtomicInteger(0);

    private int nextMessageId() {
        return messageId.updateAndGet(v -> (v + 1) % 10_000);
    }

    /** 地图文件传完后挂起的"手表解析完成"等待回调 */
    private volatile HuaweiP2PCallback parseAckWaiter = null;
    /** 解析完成帧先到时暂存的结果，-1=未到 */
    private volatile int parseResult = -1;

    public HuaweiP2PMapService(HuaweiP2PManager manager) {
        super(manager);
    }

    public static HuaweiP2PMapService getRegisteredInstance(HuaweiP2PManager manager) {
        return (HuaweiP2PMapService) manager.getRegisteredService(MODULE);
    }

    @Override
    public String getModule() {
        return MODULE;
    }

    @Override
    public String getPackage() {
        return DST_PACKAGE;
    }

    @Override
    public String getFingerprint() {
        return DST_FINGERPRINT;
    }

    @Override
    public void registered() {
        LOG.info("HuaweiP2PMapService registered");
    }

    @Override
    public void unregister() {
        LOG.info("HuaweiP2PMapService unregistered");
    }

    /** {@code [1 字节命令号][TLV…]} */
    private static byte[] message(int cmd, HuaweiTLV body) {
        byte[] tlv = body == null ? new byte[0] : body.serialize();
        byte[] out = new byte[1 + tlv.length];
        out[0] = (byte) cmd;
        System.arraycopy(tlv, 0, out, 1, tlv.length);
        return out;
    }

    /** ping 通了才发命令：没 ping 过这个 dstPackage 时手表不会建通道 */
    private void sendFrame(int cmd, byte[] msg, HuaweiP2PCallback callback) {
        if (callback != null) {
            waiters.put(cmd, callback);
        }
        sendPing((code, data) -> {
            if ((byte) code != (byte) 0xca) {
                FileLogger.w(TAG, "地图 ping 失败 cmd=" + cmd + " code=" + code);
                failWaiter(cmd);
                return;
            }
            try {
                sendCommand(msg, null);
                FileLogger.i(TAG, "地图帧已发送 cmd=" + cmd + " bytes=" + msg.length);
            } catch (RuntimeException e) {
                // 基类把 IOException 包成 RuntimeException 抛出：不接住的话等待方会挂满超时，
                // 表现出来就是"手表无响应"，实际是我们没发出去
                FileLogger.e(TAG, "地图帧发送异常 cmd=" + cmd, e);
                failWaiter(cmd);
            }
        });
    }

    /** 查询手表剩余可用空间：回调 onResponse(剩余MB, null)。官方帧 = 01 | tag1 len1 value0 */
    public void queryRemainSpace(HuaweiP2PCallback callback) {
        sendFrame(CMD_QUERY_REMAIN_SPACE,
                message(CMD_QUERY_REMAIN_SPACE, new HuaweiTLV().put(TAG_REQUEST_MARKER, (byte) 0)),
                callback);
    }

    /** 查询手表已下载的地图列表：回调 onResponse(0, 原始帧) */
    public void queryDownloadedMaps(HuaweiP2PCallback callback) {
        sendFrame(CMD_QUERY_DOWNLOADED_MAP,
                message(CMD_QUERY_DOWNLOADED_MAP, new HuaweiTLV().put(TAG_MSG_ID, nextMessageId())),
                callback);
    }

    /**
     * 传输握手（cmd 0x04）。官方这些字段全部来自华为云 authenticate 的返回，
     * 本地文件模式下只能给出手表校验得过的最小集合：政治视角固定 CN、
     * 表上允许地图数给一个宽裕的值、mapSize 用文件实际 MB 数。
     * 字段顺序与官方 sendMapHandShake 一致：2, 20, 13, 10, 14, 19, 22。
     * 回调 onResponse(握手回码, 原始帧)，0=可以发文件。
     */
    public void sendTransmitHandshake(int mapSizeMb, int mapType, int syncType,
                                      int downloadType, HuaweiP2PCallback callback) {
        HuaweiTLV body = new HuaweiTLV()
                .put(TAG_POLITICAL, "CN")
                .put(TAG_ALLOWED_MAP_COUNT, "10")
                .put(TAG_MAP_SIZE, (short) mapSizeMb)
                .put(TAG_MAP_TYPE, (byte) mapType)
                .put(TAG_SYNC_TYPE, (byte) syncType)
                .put(TAG_MSG_ID, nextMessageId())
                .put(TAG_DOWNLOAD_TYPE, (byte) downloadType);
        sendFrame(CMD_TRANSMIT_HANDSHAKE, message(CMD_TRANSMIT_HANDSHAKE, body), callback);
    }

    /**
     * 下发地图文件：0x28 文件通道，fileType=7，字节原样送出（地图文件没有业务头）。
     * 上传完成只代表字节到达，真正的确认是手表回发的 cmd 0x08 解析完成帧。
     * 回调 onResponse(2, null)=已送达，-1=传输失败。
     */
    public void pushMapFile(String fileName, byte[] fileBytes, HuaweiP2PCallback callback) {
        if (callback != null) {
            waiters.put(KEY_FILE_TRANSFER, callback);
        }
        parseResult = -1;
        uploadMapFile(fileName, fileBytes);
    }

    /** 等待手表的 cmd 0x08 解析完成帧；已先到则立刻回调 */
    public void awaitParseAck(HuaweiP2PCallback callback) {
        int settled = parseResult;
        if (settled >= 0) {
            parseResult = -1;
            callback.onResponse(settled, null);
            return;
        }
        parseAckWaiter = callback;
    }

    private void uploadMapFile(String fileName, byte[] fileBytes) {
        HuaweiUploadManager uploadManager = manager.getSupportProvider().getUploadManager();

        HuaweiUploadManager.FileUploadInfo fileInfo = new HuaweiUploadManager.FileUploadInfo();
        fileInfo.setFileType((byte) 7);
        fileInfo.setFileName(fileName);
        fileInfo.setBytes(fileBytes);
        fileInfo.setSrcPackage(getModule());
        fileInfo.setDstPackage(getPackage());
        fileInfo.setSrcFingerprint(getLocalFingerprint());
        fileInfo.setDstFingerprint(getFingerprint());
        fileInfo.setOwner(SLOT_OWNER_MAP);
        fileInfo.setFileUploadCallback(new HuaweiUploadManager.FileUploadCallback() {
            @Override
            public void onUploadStart() {
                FileLogger.i(TAG, "地图文件传输开始: " + fileName + " bytes=" + fileBytes.length);
            }

            @Override
            public void onUploadProgress(int progress) {
            }

            @Override
            public void onUploadComplete() {
                FileLogger.i(TAG, "地图文件已送达手表，等待解析完成帧: " + fileName);
                completeWaiter(KEY_FILE_TRANSFER, RESULT_DELIVERED);
            }

            @Override
            public void onError(int code) {
                FileLogger.w(TAG, "地图文件传输出错: " + code);
                failWaiter(KEY_FILE_TRANSFER);
                notifyParseAck(RESULT_TRANSPORT_ERROR);
            }
        });

        if (!uploadManager.claimFileUploadSlot(fileInfo)) {
            FileLogger.w(TAG, "文件槽被占用，地图未发送: " + uploadManager.getFileUploadOwner());
            failWaiter(KEY_FILE_TRANSFER);
            notifyParseAck(RESULT_TRANSPORT_ERROR);
            return;
        }
        try {
            new SendFileUploadInfo(manager.getSupportProvider(), uploadManager).doPerform();
        } catch (IOException | RuntimeException e) {
            FileLogger.e(TAG, "地图文件上传请求异常", e);
            failWaiter(KEY_FILE_TRANSFER);
            notifyParseAck(RESULT_TRANSPORT_ERROR);
        }
    }

    private void completeWaiter(int key, int result) {
        HuaweiP2PCallback waiter = waiters.remove(key);
        if (waiter != null) {
            waiter.onResponse(result, null);
        }
    }

    /** 传输失败/让位时立刻结掉等待方，避免编排侧白等超时 */
    private void failWaiter(int key) {
        HuaweiP2PCallback waiter = waiters.remove(key);
        if (waiter != null) {
            waiter.onResponse(RESULT_TRANSPORT_ERROR, null);
        }
    }

    private void notifyParseAck(int result) {
        HuaweiP2PCallback ack = parseAckWaiter;
        parseAckWaiter = null;
        if (ack != null) {
            ack.onResponse(result, null);
        }
    }

    /**
     * 手表回帧：{@code [1 字节命令号][TLV…]}。握手回码在 TLV 12，
     * 解析完成回码在 TLV 21（0=解析成功）。
     */
    @Override
    public void handleData(byte[] data) {
        if (data == null || data.length < 1) {
            FileLogger.w(TAG, "地图帧为空，忽略");
            return;
        }
        int cmd = data[0] & 0xFF;
        HuaweiTLV tlv;
        try {
            tlv = parseBody(data);
        } catch (RuntimeException e) {
            FileLogger.e(TAG, "地图帧 TLV 解析异常 cmd=" + cmd + " len=" + data.length, e);
            return;
        }
        if (tlv == null) {
            FileLogger.w(TAG, "地图帧 TLV 解析失败 cmd=" + cmd + " len=" + data.length);
            return;
        }
        boolean hadWaiter = waiters.containsKey(cmd);
        FileLogger.i(TAG, "地图帧到达 cmd=" + cmd + " len=" + data.length + " 等待方=" + (hadWaiter ? "有" : "无"));

        if (cmd == CMD_PARSE_FINISH) {
            int code = tlv.getAsInteger(TAG_PARSE_CODE, -1);
            FileLogger.i(TAG, "手表地图解析完成: code=" + code
                    + " cityId=" + tlv.getAsInteger(TAG_CITY_ID, -1)
                    + " mapType=" + tlv.getAsInteger(TAG_MAP_TYPE, -1));
            parseResult = code;
            notifyParseAck(code);
            return;
        }

        HuaweiP2PCallback waiter = waiters.remove(cmd);
        if (waiter == null) {
            LOG.info("Map watch push (unmatched): cmd={} tlv={}", cmd, tlv);
            return;
        }
        if (cmd == CMD_QUERY_REMAIN_SPACE) {
            long remain = unsignedValue(tlv.getBytes(TAG_REMAIN_SPACE, new byte[0]));
            // 官方只是把原始值转给 H5（deviceClient.size），单位由页面决定；
            // GT 5 实测回 1122704，按 KB 理解约 1.07 GB，这里原样透出
            LOG.info("Map remain space from watch: raw={}", remain);
            waiter.onResponse((int) Math.min(remain, Integer.MAX_VALUE), null);
            return;
        }
        if (cmd == CMD_QUERY_DOWNLOADED_MAP) {
            int mapCount = tlv.getAsInteger(TAG_TOTAL_MAP_NUM, 0);
            LOG.info("Map downloaded count from watch: {} frames={} index={}",
                    mapCount, tlv.getAsInteger(TAG_TOTAL_FRAME_NUM, 0), tlv.getAsInteger(TAG_FRAME_INDEX, 0));
            waiter.onResponse(mapCount, data);
            return;
        }
        int result = tlv.getAsInteger(TAG_HANDSHAKE_RESULT, MAP_SUCCESS);
        FileLogger.i(TAG, "地图握手回码=" + result + " (cmd=" + cmd + ")");
        waiter.onResponse(result, data);
    }

    private static HuaweiTLV parseBody(byte[] data) {
        HuaweiTLV tlv = new HuaweiTLV();
        try {
            tlv.parse(data, 1, data.length - 1);
        } catch (ArrayIndexOutOfBoundsException e) {
            return null;
        }
        return tlv;
    }

    /** 大端无符号整数，长度 1..8 字节都按原样读 */
    private static long unsignedValue(byte[] bytes) {
        long value = 0;
        for (byte b : bytes) {
            value = (value << 8) | (b & 0xFFL);
        }
        return value;
    }
}
