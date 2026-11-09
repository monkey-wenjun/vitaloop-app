package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiCoordinator;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiDictTypes;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiTLV;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.HuaweiP2PManager;

import com.awen.running.utils.FileLogger;

public class HuaweiP2PDataDictionarySyncService extends HuaweiBaseP2PService {
    private final Logger LOG = LoggerFactory.getLogger(HuaweiP2PDataDictionarySyncService.class);
    private static final String TAG = "P2PDict";

    public static final String MODULE = "hw.unitedevice.datadictionarysync";

    private AtomicBoolean serviceAvailable = new AtomicBoolean(false);

    public boolean isAvailable() {
        return serviceAvailable.get();
    }

    // 单个数据字典分类请求的超时：手表不回包时自动跳过，避免同步队列卡死（探测未知分类时尤其重要）
    private static final long REQUEST_TIMEOUT_MS = 8000L;
    // 某分类首次同步（没有游标）时往前要的窗口：手表对 start=0 回空包，必须给真实区间
    private static final long FIRST_SYNC_WINDOW_MS = 7L * 24 * 3600 * 1000;
    private final ScheduledExecutorService timeoutScheduler = Executors.newSingleThreadScheduledExecutor();

    private List<Integer> classesToSync = null;

    // 本次连接内已处理过的数据签名：部分手表（GT5）对“快照类”分类（如 500002 呼吸暂停）
    // 不按游标过滤，同一记录会被反复推送；签名去重后只处理一次，避免同步队列卡在当前分类
    private final Set<String> seenSignatures = new HashSet<>();

    public interface DictionarySyncCallback {
        void onComplete(boolean complete);
    }

    private final Map<Integer, Pending> currentRequests = new HashMap<>();

    public HuaweiP2PDataDictionarySyncService(HuaweiP2PManager manager) {
        super(manager);
        LOG.info("P2PDataDictionarySyncService");
    }

    @Override
    public String getModule() {
        return HuaweiP2PDataDictionarySyncService.MODULE;
    }

    @Override
    public String getPackage() {
        return "hw.watch.health.filesync";
    }

    @Override
    public String getFingerprint() {
        return "SystemApp";
    }

    public static byte[] dictToBytes(int value) {
        return new byte[]{
                (byte) (value >>> 16),
                (byte) (value >>> 8),
                (byte) value};
    }

    public List<Integer> checkSupported(HuaweiCoordinator coordinator, List<Integer> list) {
        List<Integer> result = new ArrayList<>();

        for(Integer cl: list) {
            if((cl == HuaweiDictTypes.BODY_TEMPERATURE_CLASS || cl == HuaweiDictTypes.SKIN_TEMPERATURE_CLASS) && coordinator.supportsTemperature()) {
                result.add(cl);
            } else if(cl == HuaweiDictTypes.BLOOD_PRESSURE_CLASS && coordinator.supportsBloodPressure()) {
                result.add(cl);
            } else if(cl == HuaweiDictTypes.HRV_CLASS && coordinator.supportsHRV()) {
                result.add(cl);
            }
        }
        return result;
    }

    public void startSync(List<Integer> dictClasses, DictionarySyncCallback callback) {
        LOG.info("P2PDataDictionarySyncService startSync {}", dictClasses);
        classesToSync = dictClasses;
        if(classesToSync.isEmpty()) {
            callback.onComplete(false);
            return;
        }
        sendSyncRequest(classesToSync.remove(0), callback);
    }

    private String signature(DictData d) {
        StringBuilder sb = new StringBuilder();
        sb.append(d.getDictClass()).append('|')
                .append(d.getStartTimestamp()).append('|')
                .append(d.getEndTimestamp()).append('|');
        for (DictData.DictDataValue v : d.getData()) {
            sb.append(v.getDataType()).append(':').append(v.getTag()).append(':');
            for (byte b : v.getValue()) {
                sb.append(b & 0xFF).append(',');
            }
            sb.append(';');
        }
        return sb.toString();
    }

    /** 挂起中的请求：回调 + 是否属于 startSync 队列（探测请求不回写游标、也不推进队列） */
    private static class Pending {
        final DictionarySyncCallback callback;
        final boolean chain;
        final byte syncType;

        Pending(DictionarySyncCallback callback, boolean chain, byte syncType) {
            this.callback = callback;
            this.chain = chain;
            this.syncType = syncType;
        }
    }

    private void sendSyncRequest(int dictClass, DictionarySyncCallback callback) {
        long startTime = manager.getSupportProvider().getLastDataDictLastTimestamp(dictClass);
        if (startTime > 0) {
            startTime += 1000;
        } else {
            // 该分类从没同步过（prefs 里没有 dict_last_xxx）：不能问 [0, now]，
            // 手表对 start=0 一律回空包（实测 500026 压力 / 500024 静息心率 / 400011 体温都是这样），
            // 按官方保留窗口往前要一段，历史样本才会真的回来
            startTime = System.currentTimeMillis() - FIRST_SYNC_WINDOW_MS;
        }
        sendRequest(dictClass, syncTypeFor(dictClass), startTime, callback, true);
    }

    /**
     * 调试探测：对单个分类按指定 syncType 和窗口发一次请求。
     * 响应仍走正常解析入库，只是不回写游标、不推进 startSync 队列。
     * adb shell am broadcast -a com.awen.running.action.DICT_PROBE --ei class 500026 --ei sync_type 1 --ei days 7
     */
    public void sendProbe(final int dictClass, final byte syncType, final long startTime) {
        if (!serviceAvailable.get()) {
            FileLogger.w(TAG, "字典探测跳过（P2P 未就绪）class=" + dictClass);
            return;
        }
        if (currentRequests.containsKey(dictClass)) {
            FileLogger.w(TAG, "字典探测跳过（该分类还有请求在跑）class=" + dictClass);
            return;
        }
        sendRequest(dictClass, syncType, startTime, new DictionarySyncCallback() {
            @Override
            public void onComplete(boolean complete) {
                FileLogger.i(TAG, "字典探测结束 class=" + dictClass + " complete=" + complete);
            }
        }, false);
    }

    /** 华为健康 assets/dict_config.json 里只有 STRESS(500026) 带 "syncType": 11，其它分类都是 1 */
    private static byte syncTypeFor(int dictClass) {
        return (dictClass == HuaweiDictTypes.STRESS_CLASS) ? (byte) 11 : (byte) 1;
    }

    private void sendRequest(int dictClass, byte syncType, long startTime,
                             DictionarySyncCallback callback, boolean chain) {
        LOG.info("P2PDataDictionarySyncService class {}", dictClass);

        if (!serviceAvailable.get()) {
            LOG.info("P2PDataDictionarySyncService not available");
            callback.onComplete(false);
            return;
        }

        if (currentRequests.containsKey(dictClass)) {
            LOG.info("P2PDataDictionarySyncService current class in progress");
            callback.onComplete(false);
            return;
        }

        HuaweiTLV tlv = new HuaweiTLV()
                .put(0x1, syncType)
                .put(0x2, dictToBytes(dictClass)) //-- skin temperature
                .put(0x5, startTime)
                .put(0x6, System.currentTimeMillis())
                .put(0x0d, (byte) 1);
        byte[] data = tlv.serialize();
        if (data == null) {
            LOG.error("Incorrect data");
            callback.onComplete(false);
            return;
        }
        // 请求体留证：手表对某个分类不回数据时，唯一能区分「协议不对」和「手表没样本」的手段
        FileLogger.i(TAG, "字典请求 class=" + dictClass + " syncType=" + syncType
                + " start=" + startTime + " probe=" + (!chain) + " tlv=" + hex(data));


        ByteBuffer packet = ByteBuffer.allocate(1 + data.length);
        packet.put((byte) 0x1); // type tlv
        packet.put(data);
        packet.flip();

        LOG.info("P2PDataDictionarySyncService send command");
        currentRequests.put(dictClass, new Pending(callback, chain, syncType));
        // 超时保护：手表不回包时移除挂起请求并继续下一个分类
        timeoutScheduler.schedule(() -> {
            Pending pending = currentRequests.remove(dictClass);
            if (pending != null) {
                LOG.info("P2PDataDictionarySyncService class {} timed out, skip", dictClass);
                if (pending.chain) {
                    continueToNextClass(pending.callback, false);
                } else {
                    pending.callback.onComplete(false);
                }
            }
        }, REQUEST_TIMEOUT_MS, TimeUnit.MILLISECONDS);

        // 注意：GT5 对字典请求会先回一个 cmdId=3、code=0xCF 的 ACK，紧接着再发
        // cmdId=2 的数据包（两者同 sequence）。把 0xCF 当拒绝而取消请求，会把后面
        // 真正的数据包丢掉；旧版这里传 null、完全忽略 ACK，只依赖 8 秒超时。
        sendCommand(packet.array(), null);
    }

    /**
     * 当前分类同步结束（完成或超时），继续下一个分类或整体完成
     */
    private synchronized void continueToNextClass(DictionarySyncCallback callback, boolean complete) {
        if (classesToSync != null && !classesToSync.isEmpty()) {
            sendSyncRequest(classesToSync.remove(0), callback);
        } else {
            classesToSync = null;
            callback.onComplete(complete);
        }
    }

    @Override
    public void registered() {
        sendPing(new HuaweiP2PCallback() {
            @Override
            public void onResponse(int code, byte[] data) {
                if ((byte) code != (byte) 0xca)
                    return;
                serviceAvailable.set(true);
            }
        });

    }

    /**
     * 不重注册、只补发一次 ping 来恢复授权。
     * 重注册会先把 serviceAvailable 清成 false，而 GT5 对紧接着的 ping 有时回一个
     * 解析不了的包，结果整轮同步直接卡死；保留注册、原地补 ping 更稳。
     */
    public void ensureAvailable(HuaweiP2PCallback callback) {
        if (serviceAvailable.get()) {
            callback.onResponse(0xca, null);
            return;
        }
        sendPing(new HuaweiP2PCallback() {
            @Override
            public void onResponse(int code, byte[] data) {
                if ((byte) code == (byte) 0xca) {
                    serviceAvailable.set(true);
                }
                callback.onResponse(code, data);
            }
        });
    }

    @Override
    public void unregister() {
        serviceAvailable.set(false);
        seenSignatures.clear();
    }

    public static class DictData {
        public static class DictDataValue {
            private final int dataType;
            private final byte tag;
            private final byte[] value;

            public DictDataValue(int dataType, byte tag, byte[] value) {
                this.dataType = dataType;
                this.tag = tag;
                this.value = value;
            }

            public int getDataType() {
                return dataType;
            }

            public byte getTag() {
                return tag;
            }

            public byte[] getValue() {
                return value;
            }

            @Override
            public String toString() {
                final StringBuffer sb = new StringBuffer("HuaweiDictDataValue{");
                sb.append("dataType=").append(dataType);
                sb.append(", tag=").append(tag);
                sb.append(", value=");
                if (value == null) sb.append("null");
                else {
                    sb.append('[');
                    for (int i = 0; i < value.length; ++i)
                        sb.append(i == 0 ? "" : ", ").append(value[i]);
                    sb.append(']');
                }
                sb.append('}');
                return sb.toString();
            }
        }


        private final int dictClass;
        private final long startTimestamp;
        private final long endTimestamp;
        private final long modifyTimestamp;
        private final List<DictDataValue> data;

        public DictData(int dictClass, long startTimestamp, long endTimestamp, long modifyTimestamp, List<DictDataValue> data) {
            this.dictClass = dictClass;
            this.startTimestamp = startTimestamp;
            this.endTimestamp = endTimestamp;
            this.modifyTimestamp = modifyTimestamp;
            this.data = data;
        }

        public int getDictClass() { return dictClass; }

        public long getStartTimestamp() {
            return startTimestamp;
        }

        public long getEndTimestamp() {
            return endTimestamp;
        }

        public long getModifyTimestamp() {
            return modifyTimestamp;
        }

        public List<DictDataValue> getData() {
            return data;
        }

        @Override
        public String toString() {
            final StringBuffer sb = new StringBuffer("HuaweiDictSample{");
            sb.append("startTime=").append(startTimestamp);
            sb.append(", endTime=").append(endTimestamp);
            sb.append(", modifyTime=").append(modifyTimestamp);
            sb.append(", data=").append(data);
            sb.append('}');
            return sb.toString();
        }
    }

    @Override
    public void handleData(byte[] data) {
        LOG.info("P2PDataDictionarySyncService handleData: {}", data.length);
        if (data[0] == 1) {
            Pending pending = null;
            try {


                HuaweiTLV tlv = new HuaweiTLV();
                tlv.parse(data, 1, data.length - 1);

                int operation = tlv.getInteger(0x01); ///???
                int dictClass = tlv.getInteger(0x02);

                if(!currentRequests.containsKey(dictClass)) {
                    FileLogger.w(TAG, "字典响应无人等待 class=" + dictClass + " op=" + operation
                            + " len=" + data.length + " raw=" + hex(data));
                    return;
                }
                pending = currentRequests.remove(dictClass);

                if(pending == null || pending.callback == null) {
                    return;
                }
                DictionarySyncCallback callback = pending.callback;

                //NOTE: all tags with high bit set should be parsed as container

                List<DictData> result =  new ArrayList<>();

                for (HuaweiTLV blockTlv : tlv.getObjects(0x83)) {
                    for (HuaweiTLV l : blockTlv.getObjects(0x84)) {
                        //5 - start time, 6 - end time, 0xc - modify time
                        long startTimestamp = l.getLong(0x5);
                        long endTimestamp = 0;
                        long modifyTimestamp = 0;
                        if (l.contains(0x6))
                            endTimestamp = l.getLong(0x6);
                        if (l.contains(0xc))
                            modifyTimestamp = l.getLong(0xc);
                        List<DictData.DictDataValue> dataValues = new ArrayList<>();
                        for (HuaweiTLV l1 : l.getObjects(0x87)) {
                            for (HuaweiTLV ll : l1.getObjects(0x88)) {
                                int type = ll.getInteger(0x9);
                                if (ll.contains(0xa))
                                    dataValues.add(new DictData.DictDataValue(type, (byte) 0xa, ll.getBytes(0xa)));
                                if (ll.contains(0xb))
                                    dataValues.add(new DictData.DictDataValue(type, (byte) 0xb, ll.getBytes(0xb)));
                            }
                        }
                        result.add(new DictData(dictClass, startTimestamp, endTimestamp, modifyTimestamp, dataValues));
                    }
                }

                List<DictData> newData = new ArrayList<>();
                for (DictData d : result) {
                    if (seenSignatures.add(signature(d))) {
                        newData.add(d);
                    }
                }
                // 空包也要留证：手表「应答但没数据」和「应答了数据但被去重吃掉」是两件不同的事，
                // 只有 op + 原始字节能区分（压力 500026 就是这样查证的）
                FileLogger.i(TAG, "字典响应 class=" + dictClass + " op=" + operation
                        + " blocks=" + result.size() + " fresh=" + newData.size()
                        + " len=" + data.length + " raw=" + hex(data));
                manager.getSupportProvider().addDictData(newData);

                if (pending.chain) {
                    if (!newData.isEmpty()) {
                        sendSyncRequest(dictClass, callback);
                    } else {
                        continueToNextClass(callback, true);
                    }
                } else {
                    // 探测：自己按游标翻页，翻到空就结束，不碰 startSync 队列
                    long next = manager.getSupportProvider().getLastDataDictLastTimestamp(dictClass);
                    if (!newData.isEmpty() && next > 0) {
                        sendRequest(dictClass, pending.syncType, next + 1000, callback, false);
                    } else {
                        callback.onComplete(!newData.isEmpty());
                    }
                }
            } catch (HuaweiPacket.MissingTagException e) {
                LOG.error("P2PDataDictionarySyncService parse error", e);
                if (pending != null && pending.callback != null) {
                    pending.callback.onComplete(false);
                }
            }
        }
    }

    /** 单行紧凑十六进制（文件日志用，避免 GB.hexdump 的多行格式把一行记录拆成几十行） */
    private static String hex(byte[] bytes) {
        if (bytes == null) {
            return "null";
        }
        StringBuilder sb = new StringBuilder(Math.min(bytes.length, 240) * 2);
        for (int i = 0; i < bytes.length && i < 120; i++) {
            sb.append(String.format("%02x", bytes[i] & 0xFF));
        }
        if (bytes.length > 120) {
            sb.append("(+").append(bytes.length - 120).append("B more)");
        }
        return sb.toString();
    }

    public static HuaweiP2PDataDictionarySyncService getRegisteredInstance(HuaweiP2PManager manager) {
        return (HuaweiP2PDataDictionarySyncService) manager.getRegisteredService(HuaweiP2PDataDictionarySyncService.MODULE);
    }

}
