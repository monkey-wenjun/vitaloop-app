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
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.TrainingPlan;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.TrainingPlanProto;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.HuaweiP2PManager;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.HuaweiUploadManager;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendFileUploadInfo;

/**
 * 华为训练计划 P2P 服务（逆向自 com.huawei.health 17.0.7.320 的
 * Suggestion_CoursePlanDeviceManager → HiWearEngineFitnessManager 链路）。
 *
 * 身份与官方一致：
 *   srcPackage = hw.unitedevice.fitness（官方 WearEngineModule.FITNESS_MODULE，
 *                与日历服务 hw.unitedevice.calendarapp 同一命名惯例）
 *   dstPackage = in.huawei.fitness（手表侧接收计划的应用）
 *   dstFingerprint = SystemApp
 *
 * 官方编排（PlanSendService）：握手(1) → 手表回 0=已同步 / 2=推全量 / 3=推骨架
 * → pushPlanData(2, 计划骨架+当前周课程) → 手表回结果。完结计划发 7。
 */
public class HuaweiP2PCoursePlanService extends HuaweiBaseP2PService {
    private static final Logger LOG = LoggerFactory.getLogger(HuaweiP2PCoursePlanService.class);

    public static final String MODULE = "hw.unitedevice.fitness";
    private static final String DST_PACKAGE = "in.huawei.fitness";
    private static final String DST_FINGERPRINT = "SystemApp";
    private static final String LOCAL_LANGUAGE = "zh-CN";

    /** 官方 igb 落盘文件名（ifu.d()：msgId + getPlanFileName()），经 0x28 通道上传 */
    private static final String PLAN_FILE_NAME = "planInfo.bin";
    /** 官方路线文件名固定为 NavigationFileParser.BIN_FILE_NAME */
    private static final String ROUTE_FILE_NAME = "byte.bin";

    /** 0x28 全局文件槽的占用者标识（与日历/音乐互斥排队） */
    private static final String SLOT_OWNER_COURSE_PLAN = "courseplan";
    private static final String SLOT_OWNER_ROUTE = "route";

    /** 官方路线名 TLV 上限：1 字节长度，网关侧还会按 UTF-8 截断 */
    private static final int ROUTE_NAME_MAX_BYTES = 60;

    /**
     * 传输层自己出问题时用的错误码。
     * 手表对路线文件回的是"1=接受、其它=拒绝"（官方 RouteTransferDataHolder.setFileResult），
     * 所以失败绝不能借用 1，否则编排侧会把传输失败当成导入手表成功。
     */
    private static final int RESULT_TRANSPORT_ERROR = -1;

    private final AtomicInteger messageId = new AtomicInteger(0);

    /**
     * 结果回调按 (businessType, messageId) 挂起等待。
     * 手表对命令先回 ack（cmdId=3，无载荷），真正的 4 字节结果帧是**另一条**
     * cmdId=2 消息、带手表自己的 sequenceId，基类的 seq 匹配对不上，
     * 只能像官方 dfc 那样按帧头 businessType+messageId 关联（真机实测 2026-11-03）。
     */
    private final Map<Integer, HuaweiP2PCallback> waiters = new ConcurrentHashMap<>();

    /** 最近一次下发的路线文件 msgId；手表的 (bt=6) 结果帧按它关联导入确认，null=无待确认传输 */
    private volatile Integer routeFileMsgId = null;
    /** 手表路线文件结果帧已到达：null=未到，非 null=帧里的 result */
    private volatile Integer routeFileResult = null;
    /** 文件传完后编排侧挂起的"手表导入确认"等待回调 */
    private volatile HuaweiP2PCallback routeAckWaiter = null;

    public HuaweiP2PCoursePlanService(HuaweiP2PManager manager) {
        super(manager);
    }

    public static HuaweiP2PCoursePlanService getRegisteredInstance(HuaweiP2PManager manager) {
        return (HuaweiP2PCoursePlanService) manager.getRegisteredService(MODULE);
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
        LOG.info("HuaweiP2PCoursePlanService registered");
    }

    @Override
    public void unregister() {
        LOG.info("HuaweiP2PCoursePlanService unregistered");
    }

    private int nextMessageId() {
        return messageId.updateAndGet(v -> (v + 1) % 1_000_000);
    }

    private static int waiterKey(int businessType, int msgId) {
        return businessType * 1_000_000 + msgId;
    }

    /** 统一发送：登记结果回调 → ping → command（ack 不带载荷，回调等 handleData 关联触发） */
    private void sendFrame(int businessType, int msgId, byte[] msg, HuaweiP2PCallback callback) {
        if (callback != null) {
            waiters.put(waiterKey(businessType, msgId), callback);
        }
        sendPing((code, data) -> {
            if ((byte) code != (byte) 0xca) {
                LOG.warn("CoursePlan ping failed (bt={}): {}", businessType, code);
                // 立刻结掉等待方：通道不通时让编排侧马上报失败，而不是挂满 20s 才超时
                failWaiter(businessType, msgId);
                return;
            }
            sendCommand(msg, null);
        });
    }

    /**
     * 计划握手：告知手表 planId 与当前周起始，手表返回是否需要推送计划文件。
     * 回调 onResponse(result, frame)：result=0 已同步 / 2 推全量 / 3 推骨架 / 1 失败。
     */
    public void sendHandshake(String planId, long weekStartTimeSec, long punchTimeStampSec,
                              HuaweiP2PCallback callback) {
        int msgId = nextMessageId();
        byte[] shake = TrainingPlanProto.buildPlanShakeHandsInfo(
                planId, LOCAL_LANGUAGE, weekStartTimeSec, punchTimeStampSec);
        byte[] msg = TrainingPlan.buildMessage(
                TrainingPlan.BT_RUN_PLAN_HANDLE_SHAKE, msgId, 0, null, shake);
        sendFrame(TrainingPlan.BT_RUN_PLAN_HANDLE_SHAKE, msgId, msg, callback);
    }

    /**
     * 推送计划文件：计划骨架 + 当前周课程（pushType=2 全量）。
     * 官方把整帧写到 "<msgId>planInfo.bin" 后以 **文件**（xiv type2）下发，真机验证
     * P2P 原始字节帧手表只 ack 不解析（2026-11-03），所以这里与日历同走 0x28 上传通道。
     * 回调 result 非 1 为成功（结果帧仍是手表回发的 P2P 数据帧，按 bt+msgId 关联）。
     */
    public void pushPlanFile(int businessType, byte[] planData, List<TrainingPlan.IndexedCourse> courses,
                             HuaweiP2PCallback callback) {
        int msgId = nextMessageId();
        byte[] msg = TrainingPlan.buildPlanFileMessage(businessType, msgId, planData, courses);
        if (callback != null) {
            waiters.put(waiterKey(businessType, msgId), callback);
        }
        uploadPlanFile(businessType, msgId, msg);
    }

    private void uploadPlanFile(int businessType, int msgId, byte[] framed) {
        HuaweiUploadManager uploadManager = manager.getSupportProvider().getUploadManager();

        HuaweiUploadManager.FileUploadInfo fileInfo = new HuaweiUploadManager.FileUploadInfo();
        fileInfo.setFileType((byte) 7);
        fileInfo.setFileName(msgId + PLAN_FILE_NAME);
        fileInfo.setBytes(framed);
        fileInfo.setSrcPackage(getModule());
        fileInfo.setDstPackage(getPackage());
        fileInfo.setSrcFingerprint(getLocalFingerprint());
        fileInfo.setDstFingerprint(getFingerprint());
        fileInfo.setOwner(SLOT_OWNER_COURSE_PLAN);
        fileInfo.setFileUploadCallback(new HuaweiUploadManager.FileUploadCallback() {
            @Override
            public void onUploadStart() {
                LOG.info("CoursePlan file upload started: {}", msgId + PLAN_FILE_NAME);
            }

            @Override
            public void onUploadProgress(int progress) {
            }

            @Override
            public void onUploadComplete() {
                LOG.info("CoursePlan file upload complete, waiting watch result frame");
            }

            @Override
            public void onError(int code) {
                LOG.error("CoursePlan file upload error: {}", code);
                failWaiter(businessType, msgId);
            }
        });

        if (!uploadManager.claimFileUploadSlot(fileInfo)) {
            LOG.warn("CoursePlan upload deferred, file slot held by {}", uploadManager.getFileUploadOwner());
            failWaiter(businessType, msgId);
            return;
        }
        try {
            SendFileUploadInfo sendFileUploadInfo =
                    new SendFileUploadInfo(manager.getSupportProvider(), uploadManager);
            sendFileUploadInfo.doPerform();
        } catch (IOException e) {
            LOG.error("CoursePlan failed to send file upload info", e);
            failWaiter(businessType, msgId);
        }
    }

    /** 上传失败/让位时立刻结掉等待方（result=1），避免编排侧白等 15s 超时 */
    private void failWaiter(int businessType, int msgId) {
        HuaweiP2PCallback waiter = waiters.remove(waiterKey(businessType, msgId));
        if (waiter != null) {
            waiter.onResponse(1, null);
        }
    }

    /** 路线自己传输失败：用 RESULT_TRANSPORT_ERROR，避免和手表回码 1（已接受）撞车 */
    private void failRouteWaiter(int msgId) {
        HuaweiP2PCallback waiter = waiters.remove(waiterKey(TrainingPlan.BT_TRAJECTORY_FILE, msgId));
        if (waiter != null) {
            waiter.onResponse(RESULT_TRANSPORT_ERROR, null);
        }
    }

    /** 独立下发单课程文件（官方 pushFitRunCourseData，businessType=3） */
    public void pushSingleCourse(byte[] courseData, HuaweiP2PCallback callback) {
        int msgId = nextMessageId();
        byte[] msg = TrainingPlan.buildMessage(
                TrainingPlan.BT_CUSTOM_COURSE_FILE, msgId, 0, null, courseData);
        sendFrame(TrainingPlan.BT_CUSTOM_COURSE_FILE, msgId, msg, callback);
    }

    /**
     * 完结/删除计划（官方 sendFinishPlan）：businessType 7=跑步计划 / 22=AI 健身计划。
     * weekStartTime/punchTimeStamp 官方此处直接取当前时间。
     */
    public void sendFinishPlan(String planId, int businessType, HuaweiP2PCallback callback) {
        int msgId = nextMessageId();
        long nowSec = System.currentTimeMillis() / 1000L;
        byte[] shake = TrainingPlanProto.buildPlanShakeHandsInfo(planId, LOCAL_LANGUAGE, nowSec, nowSec);
        byte[] msg = TrainingPlan.buildMessage(businessType, msgId, 0, null, shake);
        sendFrame(businessType, msgId, msg, callback);
    }

    /**
     * 路线握手：官方 gxy.b(str) 的 TLV = 0x05 + UTF-8 字节数 + 路线名。
     * 手表返回 int32 state + int32 pointMaxNum；state=1 时才允许发路线文件。
     */
    public void sendRouteHandshake(String routeName, HuaweiP2PCallback callback) {
        int msgId = nextMessageId();
        byte[] name = buildRouteNameTlv(routeName);
        byte[] msg = TrainingPlan.buildMessage(
                TrainingPlan.BT_TRAJECTORY_HANDLE_SHAKE, msgId, 0, null, name);
        sendFrame(TrainingPlan.BT_TRAJECTORY_HANDLE_SHAKE, msgId, msg, callback);
    }

    /**
     * 下发路线文件 byte.bin。
     *
     * 官方把 [36 字节帧头][12 字节路线头 + 40×N 轨迹点] 写成文件后走 P2P file 消息；
     * 与训练计划一样，这里复用已验证可用的 0x28 文件通道（真机待确认）。
     * 上传完成只说明字节到达了手表，不代表手表已导入：真正的确认是手表回发的
     * (bt=6, msgId) 结果帧（handleData 关联，官方语义 result=1 才是接受）。传输完成时以
     * result=2 提前通知编排侧"文件已送达、等待手表确认"，避免手表静默时
     * 假报成功——这正是此前"点了推送、手表没反应"的根因之一。
     */
    public void pushRouteFile(byte[] routeData, HuaweiP2PCallback callback) {
        int msgId = nextMessageId();
        byte[] msg = TrainingPlan.buildMessage(
                TrainingPlan.BT_TRAJECTORY_FILE, msgId, 0, null, routeData);
        if (callback != null) {
            waiters.put(waiterKey(TrainingPlan.BT_TRAJECTORY_FILE, msgId), callback);
        }
        routeFileMsgId = msgId;
        routeFileResult = null;
        uploadRouteFile(msgId, msg);
    }

    /**
     * 路线文件传输完成后，等待手表回发的 (bt=6) 导入结果帧。
     * 结果帧已先到 → 立刻以该结果回调；帧不到则不回调，超时由编排侧自行掌握。
     */
    public void awaitRouteAck(HuaweiP2PCallback callback) {
        Integer settled = routeFileResult;
        if (settled != null) {
            callback.onResponse(settled, null);
            return;
        }
        routeAckWaiter = callback;
    }

    private void notifyRouteAck(int result) {
        HuaweiP2PCallback ack = routeAckWaiter;
        routeAckWaiter = null;
        if (ack != null) {
            ack.onResponse(result, null);
        }
    }

    private byte[] buildRouteNameTlv(String routeName) {
        String safeName = routeName == null ? "" : routeName.trim();
        if (safeName.isEmpty()) {
            safeName = "route";
        }
        byte[] raw = safeName.getBytes(StandardCharsets.UTF_8);
        if (raw.length > ROUTE_NAME_MAX_BYTES) {
            // 按 UTF-8 边界截断，避免把中文截成半个字符
            int end = ROUTE_NAME_MAX_BYTES;
            while (end > 0 && (raw[end] & 0xC0) == 0x80) {
                end--;
            }
            byte[] truncated = new byte[end];
            System.arraycopy(raw, 0, truncated, 0, end);
            raw = truncated;
        }
        ByteBuffer bb = ByteBuffer.allocate(2 + raw.length);
        bb.put((byte) 0x05);
        bb.put((byte) raw.length);
        bb.put(raw);
        return bb.array();
    }

    private void uploadRouteFile(int msgId, byte[] framed) {
        HuaweiUploadManager uploadManager = manager.getSupportProvider().getUploadManager();

        HuaweiUploadManager.FileUploadInfo fileInfo = new HuaweiUploadManager.FileUploadInfo();
        fileInfo.setFileType((byte) 7);
        fileInfo.setFileName(ROUTE_FILE_NAME);
        fileInfo.setBytes(framed);
        fileInfo.setSrcPackage(getModule());
        fileInfo.setDstPackage(getPackage());
        fileInfo.setSrcFingerprint(getLocalFingerprint());
        fileInfo.setDstFingerprint(getFingerprint());
        fileInfo.setOwner(SLOT_OWNER_ROUTE);
        fileInfo.setFileUploadCallback(new HuaweiUploadManager.FileUploadCallback() {
            @Override
            public void onUploadStart() {
                LOG.info("Route file upload started: {} bytes={}", ROUTE_FILE_NAME, framed.length);
            }

            @Override
            public void onUploadProgress(int progress) {
            }

            @Override
            public void onUploadComplete() {
                LOG.info("Route file upload complete: {} bytes={}, awaiting watch result frame",
                        ROUTE_FILE_NAME, framed.length);
                // 2 = 传输完成、手表尚未确认（不是成功！成功以 handleData 关联到的结果帧为准）
                completeWaiter(TrainingPlan.BT_TRAJECTORY_FILE, msgId, 2);
            }

            @Override
            public void onError(int code) {
                LOG.error("Route file upload error: {}", code);
                routeFileMsgId = null;
                failRouteWaiter(msgId);
                notifyRouteAck(RESULT_TRANSPORT_ERROR);
            }
        });

        if (!uploadManager.claimFileUploadSlot(fileInfo)) {
            LOG.warn("Route upload deferred, file slot held by {}", uploadManager.getFileUploadOwner());
            routeFileMsgId = null;
            failRouteWaiter(msgId);
            notifyRouteAck(RESULT_TRANSPORT_ERROR);
            return;
        }
        try {
            SendFileUploadInfo sendFileUploadInfo =
                    new SendFileUploadInfo(manager.getSupportProvider(), uploadManager);
            sendFileUploadInfo.doPerform();
        } catch (IOException e) {
            LOG.error("Route failed to send file upload info", e);
            routeFileMsgId = null;
            failRouteWaiter(msgId);
            notifyRouteAck(RESULT_TRANSPORT_ERROR);
        }
    }

    private void completeWaiter(int businessType, int msgId, int result) {
        HuaweiP2PCallback waiter = waiters.remove(waiterKey(businessType, msgId));
        if (waiter != null) {
            waiter.onResponse(result, null);
        }
    }

    /** 结果帧按 (businessType, messageId) 唤醒等待方；无等待方视为手表主动推送，记原始帧 */
    @Override
    public void handleData(byte[] data) {
        if (data == null || data.length < TrainingPlan.HEADER_SIZE) {
            LOG.warn("CoursePlan handleData: too short: {}", data == null ? 0 : data.length);
            return;
        }
        TrainingPlan.MsgHeader header = TrainingPlan.MsgHeader.parse(data, 0);
        int result = data.length >= TrainingPlan.HEADER_SIZE + 4
                ? ByteBuffer.wrap(data, TrainingPlan.HEADER_SIZE, 4)
                    .order(ByteOrder.LITTLE_ENDIAN).getInt()
                : Integer.MIN_VALUE;
        // 路线文件结果帧：真机实测(2026-11-05)手表回的是**自己的** msgId（与命令 seq/msgId
        // 都不一致），无法像握手(bt=5)那样按 id 关联；同一时刻只有一个路线传输在飞，
        // 因此待确认阶段收到的 bt=6 帧直接视为导入结果。
        if (header.businessType == TrainingPlan.BT_TRAJECTORY_FILE
                && (routeFileMsgId != null || routeAckWaiter != null)) {
            routeFileMsgId = null;
            routeFileResult = result;
            notifyRouteAck(result);
            LOG.info("Route import result from watch: msgId={} result={}", header.messageId, result);
            return;
        }
        HuaweiP2PCallback waiter = waiters.remove(waiterKey(header.businessType, header.messageId));
        if (waiter != null) {
            LOG.info("CoursePlan response: bt={} msgId={} result={}",
                    header.businessType, header.messageId, result);
            waiter.onResponse(result, data);
            return;
        }
        // 手表主动推送（完成状态回读等）：字段语义待真机抓样补全
        LOG.info("CoursePlan watch push (unmatched): bt={} msgId={} payloadLen={} result={}",
                header.businessType, header.messageId, data.length - TrainingPlan.HEADER_SIZE, result);
    }
}
