package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei;

import android.text.TextUtils;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.zip.ZipEntry;
import java.util.zip.ZipException;
import java.util.zip.ZipFile;

import com.awen.running.utils.FileLogger;

import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.Request;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendEphemerisDataRequestResponse;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendEphemerisFileConsultResponse;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendEphemerisFileListResponse;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendEphemerisFileStatusRequest;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendEphemerisFileUploadChunk;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendEphemerisFileUploadDoneResponse;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendEphemerisOperatorResponse;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendEphemerisParameterConsultRequest;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendEphemerisSingleFileInfoResponse;
import nodomain.freeyourgadget.gadgetbridge.util.CheckSums;
import nodomain.freeyourgadget.gadgetbridge.util.CryptoUtils;
import nodomain.freeyourgadget.gadgetbridge.util.StringUtils;

public class HuaweiEphemerisManager {
    private static final Logger LOG = LoggerFactory.getLogger(HuaweiEphemerisManager.class);
    private static final int CHUNK_PROBE_MODES = 6;
    private static final String PREFS = "ephemeris_prefs";
    private static final String KEY_CHUNK_PROBE = "chunk_probe_mode";
    /**
     * 超过该时长的星历不再应答手表（数据太旧没有意义）。
     * 演变：2 小时 → 4 小时 → 12 小时。
     * 12 小时的依据：
     *   1) 手表自己在星历协商里给的是 deviceTime=30000s（≈8.3 小时）；
     *   2) 这批数据是「广播星历 + WUM 预报轨道」生成的，以生成时刻为参考，
     *      预报轨道本身覆盖约两天，数小时内偏差仍可用；
     *   3) 手机短时间连不上星历服务器（外出没网、服务器抖动）时，
     *      宁可发一份稍旧的辅助数据，也好过静默不回应让手表冷启动搜星。
     * 正常在线时 App 仍按 1 小时刷新，所以实际下发的基本都是新数据。
     */
    private static final long SERVE_MAX_AGE_MS = 12 * 60 * 60 * 1000L;
    /** 超过该时长视为偏旧：仍然应答，但记日志提示需要刷新 */
    private static final long FRESH_AGE_MS = 60 * 60 * 1000L;

    /** 下发窗口（毫秒），供设置页展示"还能发多久" */
    public static long getServeMaxAgeMs() {
        return SERVE_MAX_AGE_MS;
    }

    public static class UploadParameters {
        //upload file related data
        private final String protocolVersion;
        private final byte bitmapEnable;
        private final short transferSize;
        private final int maxDataSize;
        private final short timeOut;
        private final byte fileType;

        public UploadParameters(String protocolVersion, byte bitmapEnable, short transferSize, int maxDataSize, short timeOut, byte fileType) {
            this.protocolVersion = protocolVersion;
            this.bitmapEnable = bitmapEnable;
            this.transferSize = transferSize;
            this.maxDataSize = maxDataSize;
            this.timeOut = timeOut;
            this.fileType = fileType;
        }

        public String getProtocolVersion() {
            return protocolVersion;
        }

        public byte getBitmapEnable() {
            return bitmapEnable;
        }

        public short getTransferSize() {
            return transferSize;
        }

        public int getMaxDataSize() {
            return maxDataSize;
        }

        public short getTimeOut() {
            return timeOut;
        }

        public byte getFileType() {
            return fileType;
        }
    }

    public static class RequestInfo {
        private int tagVersion = -1;
        private String tagUUID = null;
        private List<String> tagFiles = null;

        private byte[] currentFileData = null;
        private String currentFileName = null;

        UploadParameters uploadParameters = null;

        private List<String> processedFiles = new ArrayList<>();

        public RequestInfo(int tagVersion, String tagUUID, List<String> tagFiles) {
            this.tagVersion = tagVersion;
            this.tagUUID = tagUUID;
            this.tagFiles = tagFiles;
        }

        public int getTagVersion() {
            return tagVersion;
        }

        public String getTagUUID() {
            return tagUUID;
        }

        public List<String> getTagFiles() {
            return tagFiles;
        }

        public byte[] getCurrentFileData() {
            return currentFileData;
        }

        public String getCurrentFileName() {
            return currentFileName;
        }

        public UploadParameters getUploadParameters() {
            return uploadParameters;
        }

        public void setCurrentFileData(byte[] currentFileData) {
            this.currentFileData = currentFileData;
        }

        public void setCurrentFileName(String currentFileName) {
            this.currentFileName = currentFileName;
        }

        public void setUploadParameters(UploadParameters uploadParameters) {
            this.uploadParameters = uploadParameters;
        }

        public void addProcessedFile(String name) {
            processedFiles.add(name);
        }

        public boolean isAllProcessed() {
            LOG.info("Ephemeris tagFiles: {}", tagFiles.toString());
            LOG.info("Ephemeris processed: {}", processedFiles.toString());
            return processedFiles.size() == tagFiles.size() && new HashSet<>(processedFiles).containsAll(tagFiles);
        }
    }

    private final IHuaweiSupport support;


    private JsonObject availableDataConfig = null;


    private RequestInfo currentRequest = null;

    // 最近一次协商成功的请求信息（version/uuid/files），用于手表在没有重新
    // operator 握手的情况下直接轮询 FileList 时补发文件列表，避免被静默丢弃
    private RequestInfo lastConsultRequest = null;
    // 最近一次协商命中的配置条目名（tag 或 __default__），仅供日志排查
    private String lastConsultEntry = null;
    // 最近一次发出分片时使用的 headerMode，用于一批 100010 只前进一次探测
    private int currentSentChunkMode = -1;

    private int getChunkProbeMode() {
        try {
            android.content.SharedPreferences sp = support.getContext()
                    .getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE);
            // GT5 实测需要 mode 5（1B 序号 + TLV 加密负载）；其它固件若拒绝会自动
            // 前进到 0..4 探测并记住结果
            return Math.max(0, Math.min(CHUNK_PROBE_MODES - 1, sp.getInt(KEY_CHUNK_PROBE, 5)));
        } catch (Exception e) {
            return 5;
        }
    }

    private void setChunkProbeMode(int mode) {
        try {
            android.content.SharedPreferences sp = support.getContext()
                    .getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE);
            sp.edit().putInt(KEY_CHUNK_PROBE, mode).apply();
        } catch (Exception ignored) {
        }
    }


    public HuaweiEphemerisManager(IHuaweiSupport support) {
        this.support = support;
    }

    /** 空壳 PGNSS 占位文件的长度上限（harness 在 seed 覆盖不到的窗口产出的 1008B 全 0 文件） */
    private static final int MIN_PGNSS_ENTRY_BYTES = 1024;

    /**
     * 该 zip 条目能不能真的发给手表。
     *
     * 空壳条目（例如 1008B 全 0 的 HW_PGNSS_GLONASS）算出来 CRC16 = 0，
     * handleSingleFileIncomingRequest 会回 100001 并 cleanupUpload(true) 清掉整轮会话，
     * 手表拿到错误码只能反复重来（2026-09-18 实测：手表 AGPS 进度一直卡 0%，
     * 每 ~87 秒重跑一遍 GPS/BDS，到 GLONASS 就断）。所以这类条目不能出现在 FileList 里，
     * 少发一个星座是可用降级，发一个必然报错的条目会把整轮传星历搞挂。
     */
    private boolean isServableEntry(File file, String name) {
        byte[] data = getZIPFileContent(file, name);
        if (data == null || data.length == 0) return false;
        if (CheckSums.getCRC16(data, 0x0000) == 0) return false;
        String baseName = name.substring(name.lastIndexOf(File.separatorChar) + 1);
        if (baseName.startsWith("HW_PGNSS_") && data.length < MIN_PGNSS_ENTRY_BYTES) return false;
        return true;
    }

    private byte[] getZIPFileContent(File file, String name) {
        byte[] ret = null;
        try {
            ZipFile zipFile = new ZipFile(file);
            Enumeration<? extends ZipEntry> entries = zipFile.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                if (entry.getName().equals(name)) {
                    InputStream inputStream = zipFile.getInputStream(entry);
                    ret = new byte[inputStream.available()];
                    inputStream.read(ret);
                    inputStream.close();
                }
            }
            zipFile.close();
        } catch (ZipException e) {
            LOG.error("zip exception", e);
        } catch (IOException e) {
            LOG.error("zip IO exception", e);
        }
        return ret;
    }

    private boolean checkZIPFileExists(File file, String name) {
        try {
            ZipFile zipFile = new ZipFile(file);
            Enumeration<? extends ZipEntry> entries = zipFile.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                if (!entry.isDirectory() && entry.getName().equals(name)) {
                    return true;
                }
            }
            zipFile.close();
        } catch (ZipException e) {
            LOG.error("zip exception", e);
        } catch (IOException e) {
            LOG.error("zip IO exception", e);
        }
        return false;
    }

    /**
     * 从本地 ephemeris.zip 读取 time + ephemeris_config.json，
     * 文件缺失、生成时间超过 2 小时或解析失败返回 null。
     */
    private JsonObject loadAvailableConfig(File file) {
        try {
            if (file == null || !file.exists()) {
                FileLogger.w("HuaweiEphemerisManager", "星历 operator 请求：本地文件不存在");
                return null;
            }
            byte[] time = getZIPFileContent(file, "time");
            byte[] config = getZIPFileContent(file, "ephemeris_config.json");

            if (time == null || config == null) {
                FileLogger.w("HuaweiEphemerisManager", "星历 operator 请求：zip 内缺少 time 或 ephemeris_config.json");
                return null;
            }

            long fileTime = Long.parseLong(new String(time));
            long ageMs = System.currentTimeMillis() - fileTime;
            if (ageMs > SERVE_MAX_AGE_MS) {
                FileLogger.w("HuaweiEphemerisManager", "星历 operator 请求：文件过期 fileTime=" + fileTime
                        + " 已 " + (ageMs / 60000) + " 分钟");
                return null;
            }
            if (ageMs > FRESH_AGE_MS) {
                // 偏旧但仍能帮手表定位：本次先应答，App 会在后台补新文件
                FileLogger.w("HuaweiEphemerisManager", "星历 operator 请求：文件偏旧（" + (ageMs / 60000)
                        + " 分钟）仍按可用处理 fileTime=" + fileTime);
            }

            JsonObject configJson = JsonParser.parseString(new String(config)).getAsJsonObject();
            FileLogger.i("HuaweiEphemerisManager", "星历 operator 请求：文件有效 fileTime=" + fileTime + " config=" + configJson);
            return configJson;
        } catch (Exception e) {
            FileLogger.e("HuaweiEphemerisManager", "星历 operator 请求：文件或配置解析失败: " + e.getMessage(), e);
            return null;
        }
    }

    public void handleOperatorRequest(byte operationInfo, int operationTime) {
        //TODO:
        // 100007 - no network connection
        if (operationInfo == 1) {
            // NOTE: clear data on new request
            currentRequest = null;

            int responseCode = 100000;
            try {
                File filesDir = support.getContext().getExternalFilesDir(null);
                File file = new File(filesDir, "ephemeris.zip");
                availableDataConfig = loadAvailableConfig(file);
                if (availableDataConfig == null) {
                    // 数据无效时不回应（与 Gadgetbridge 一致），手表会稍后重试
                    return;
                }
            } catch (Exception e) {
                LOG.info("Ephemeris exception file or config processing: {}", e.getMessage());
                availableDataConfig = null;
                FileLogger.e("HuaweiEphemerisManager", "星历 operator 请求处理异常", e);
                return;
            }

            try {
                SendEphemerisOperatorResponse sendEphemerisOperatorResponse = new SendEphemerisOperatorResponse(this.support, responseCode);
                sendEphemerisOperatorResponse.doPerform();
                FileLogger.i("HuaweiEphemerisManager", "星历 operator 响应已发送 code=" + responseCode);

                if (responseCode == 100000) {
                    SendEphemerisParameterConsultRequest sendEphemerisParameterConsultRequest = new SendEphemerisParameterConsultRequest(this.support);
                    sendEphemerisParameterConsultRequest.doPerform();
                    FileLogger.i("HuaweiEphemerisManager", "星历参数协商请求已发送");
                }

            } catch (IOException e) {
                LOG.error("Error send Ephemeris data");
                FileLogger.e("HuaweiEphemerisManager", "星历 operator 响应发送失败", e);
            }
        } else {
            FileLogger.d("HuaweiEphemerisManager", "星历 operator 请求：忽略未知 operationInfo=" + operationInfo + " operationTime=" + operationTime);
        }

        // TODO: operation code == 2 send file download progress
        //   Currently we do not need this code because everything is downloaded already. Maybe needed in the future
        //   0x2: 02
        //   0x3: operationTime
        //   0x4:  from 01 to 06 status
        //   in the container 0x81
    }

    /** 上一次主动推送尝试时刻（进程内），失败重试至少间隔 5 分钟 */
    private long lastProactiveAttemptAt = 0L;
    /** 手表最近一次协商距今不足该时长就跳过主动推送（数据还在它手里，重传 1.37MB 纯耗电） */
    private static final long PROACTIVE_SKIP_AFTER_CONSULT_MS = 30 * 60 * 1000L;
    private static final long PROACTIVE_MIN_RETRY_MS = 5 * 60 * 1000L;
    private static final int PROACTIVE_CONSULT_TIMEOUT_MS = 15000;

    /**
     * 手机主动发起星历参数协商（不经手表 operator 握手）。
     *
     * GT5 只在开运动那一刻才来要星历，1.37MB 只能等开跑后经 RFCOMM 传
     * （实测 ~30s、47KB/s；分片大小与逐块 ACK 节奏由手表在文件协商里定死，
     * 手机端没有提速杠杆），首个定位点就被卡在这 30 秒上。
     * 连接就绪/文件刷新后提前把数据喂给手表，开跑时它手里已有数据。
     *
     * 手表接不接受"没有 operator 请求在前的协商"未经实测：应答则走既有
     * handleParameterConsultResponse 上传流程；不应答则 15s 超时清理，无副作用。
     */
    public void tryProactivePush() {
        long now = System.currentTimeMillis();
        if (now - lastProactiveAttemptAt < PROACTIVE_MIN_RETRY_MS) return;
        if (currentRequest != null) return;
        try {
            long lastConsult = support.getContext()
                    .getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
                    .getLong("last_consult_ms", 0L);
            if (now - lastConsult < PROACTIVE_SKIP_AFTER_CONSULT_MS) return;
        } catch (Exception ignored) {
        }
        try {
            File filesDir = support.getContext().getExternalFilesDir(null);
            File file = new File(filesDir, "ephemeris.zip");
            JsonObject config = loadAvailableConfig(file);
            if (config == null) {
                FileLogger.i("HuaweiEphemerisManager", "星历主动推送：本地无有效文件，跳过");
                return;
            }
            availableDataConfig = config;
            lastProactiveAttemptAt = now;
            SendEphemerisParameterConsultRequest consultRequest = new SendEphemerisParameterConsultRequest(support);
            consultRequest.setupTimeoutUntilNext(PROACTIVE_CONSULT_TIMEOUT_MS);
            consultRequest.setFinalizeReq(new Request.RequestCallback() {
                @Override
                public void timeout(Request request) {
                    // 超时不会自动清注册：残留 handler 会按 svc/cmd 抢走之后手表真发起的
                    // 协商响应，导致同一份 1.37MB 被传两遍。
                    // 注意 RequestCallback 基类里有同名 support 字段（默认 null），
                    // 必须用 HuaweiEphemerisManager.this.support，否则这里 NPE 杀死整个 App。
                    FileLogger.w("HuaweiEphemerisManager", "星历主动推送：协商 15s 无应答，清理请求（手表可能不接受主动协商）");
                    try {
                        HuaweiEphemerisManager.this.support.removeInProgressRequests(request);
                    } catch (Exception e) {
                        FileLogger.e("HuaweiEphemerisManager", "星历主动推送清理失败", e);
                    }
                }
            });
            consultRequest.doPerform();
            FileLogger.i("HuaweiEphemerisManager", "星历主动推送：参数协商已发送（不等手表 operator 请求）");
        } catch (Exception e) {
            FileLogger.e("HuaweiEphemerisManager", "星历主动推送失败", e);
        }
    }

    public void handleParameterConsultResponse(int consultDeviceTime, byte downloadVersion, String downloadTag) {
        LOG.info("consultDeviceTime: {}, downloadVersion: {}, downloadTag: {}", consultDeviceTime, downloadVersion, downloadTag);
        FileLogger.i("HuaweiEphemerisManager", "星历协商响应: tag=" + downloadTag + " version=" + downloadVersion + " deviceTime=" + consultDeviceTime);
        byte status = 0x3; // ready to download
        recordWatchConsult(downloadTag, downloadVersion);

        try {
            File filesDir = support.getContext().getExternalFilesDir(null);
            File file = new File(filesDir, "ephemeris.zip");
            if (!file.exists()) {
                throw new Exception("Ephemeris file does not exists");
            }

            if (availableDataConfig == null) {
                throw new Exception("Ephemeris no config data");
            }

            JsonObject conf = availableDataConfig.getAsJsonObject(downloadTag);

            // 电离层 tag 带经纬度：higeo/v1/gnssIonInfo/<lng>,<lat>/HW_PRECSION_ION
            // 坐标每次都在变，配置里没法逐条写死 —— 这里按前缀匹配到配置里的
            // "higeo/v1/gnssIonInfo" 条目（zip 里放 HW_PRECSION_ION）。
            boolean prefixMatched = false;
            if (conf == null && downloadTag != null) {
                for (String key : availableDataConfig.keySet()) {
                    if ("__default__".equals(key)) continue;
                    if (downloadTag.startsWith(key)) {
                        conf = availableDataConfig.getAsJsonObject(key);
                        prefixMatched = true;
                        LOG.info("Ephemeris tag '{}' matched by prefix '{}'", downloadTag, key);
                        FileLogger.i("HuaweiEphemerisManager",
                                "星历 tag 前缀命中: " + downloadTag + " ← " + key);
                        break;
                    }
                }
            }

            // 自建 zip 用 "__default__" 键兜底，但只对“PGNSS 预测星历”类请求生效：
            // 本机 GT5 会请求两族 tag ——
            //   com.huawei.higeo_dataModule_PGNSSConfig?type=HW_EEV2/HW_PGNSS_PRED（预测星历，我们有数据）
            //   higeo/v1/gnssIonInfo/<经纬度>/HW_PRECSION_ION（电离层，我们的 zip 里没有）
            // 早先对任何未知 tag 都回 __default__，实测手表对“电离层请求收到 PGNSS 文件列表”
            // 并不接受：它会在 20 秒间隔上连续轮询 3 次 FileList（每次进来 40~60 秒）
            // 然后放弃，电离层数据一直拿不到，链路还被白占。
            // 现在：只有 PGNSS 类 tag 回落到 __default__，其余（如 HW_PRECSION_ION）
            // 直接回 0x5 错误，手表立刻跳过，不再空转。
            boolean knownTag = downloadTag != null && availableDataConfig.has(downloadTag);
            if (prefixMatched) knownTag = true;
            boolean pgnssLikeTag = downloadTag != null
                    && downloadTag.toUpperCase(Locale.ROOT).contains("PGNSS");
            boolean fallbackToDefault = conf == null
                    && availableDataConfig.has("__default__")
                    && pgnssLikeTag;
            if (fallbackToDefault) {
                LOG.info("Ephemeris tag '{}' is not configured, falling back to __default__", downloadTag);
                conf = availableDataConfig.getAsJsonObject("__default__");
            }
            if (conf == null) {
                LOG.info("Ephemeris tag '{}' has no matching data, replying error", downloadTag);
                FileLogger.w("HuaweiEphemerisManager",
                        "星历 tag 无对应数据，回错误码（避免手表轮询空转）: " + downloadTag);
                throw new Exception("Ephemeris no config for tag: " + downloadTag);
            }

            int version = conf.get("ver").getAsInt();
            if (!knownTag) {
                // 兜底条目：版本以手表协商为准（我们不知道对该 tag 手表期望哪个版本）
                LOG.info("Ephemeris fallback __default__, accept watch version {}", downloadVersion);
                version = downloadVersion;
            }
            if(version != downloadVersion) {
                throw new Exception("Ephemeris version mismatch");
            }
            String uuid = conf.get("uuid").getAsString();

            if(uuid.isEmpty())
                throw new Exception("Ephemeris uuid is empty");

            JsonArray filesJs = conf.get("files").getAsJsonArray();

            List<String> files = new ArrayList<>();
            List<String> skippedFiles = new ArrayList<>();
            for (int i = 0; i < filesJs.size(); i++) {
                String fl = filesJs.get(i).getAsString();
                if (isServableEntry(file, uuid + File.separator + fl)) {
                    files.add(fl);
                } else {
                    skippedFiles.add(fl);
                }
            }
            if (!skippedFiles.isEmpty()) {
                FileLogger.w("HuaweiEphemerisManager", "星历协商：跳过空壳/不可用条目 " + skippedFiles
                        + "（发出去手表会回 100001 并中止整轮上传）");
            }

            if(files.isEmpty())
                throw new Exception("Ephemeris file list is empty");

            currentRequest = new RequestInfo(downloadVersion, uuid, files);
            lastConsultRequest = currentRequest;
            lastConsultEntry = knownTag ? downloadTag : "__default__";
            FileLogger.i("HuaweiEphemerisManager", "星历协商命中条目=" + lastConsultEntry + " uuid=" + uuid + " files=" + files + " → 状态=可下载(0x3)");

        } catch (Exception e) {
            LOG.error("Ephemeris exception file or config processing", e);
            FileLogger.e("HuaweiEphemerisManager", "星历协商失败（将回 0x5 错误）: " + e.getMessage(), e);
            availableDataConfig = null;
            status = 0x5; //error or timeout
        }

        try {
            SendEphemerisFileStatusRequest sendEphemerisFileStatusRequest = new SendEphemerisFileStatusRequest(this.support, status);
            sendEphemerisFileStatusRequest.doPerform();
        } catch (IOException e) {
            LOG.error("Error to send SendEphemerisFileStatusRequest");
        }
    }

    /**
     * 记录手表最近一次星历协商请求（tag/version），供设置页显示，
     * 用于在不知道本机手表请求参数时调整自建 ephemeris.zip 的配置。
     */
    private void recordWatchConsult(String tag, byte version) {
        try {
            android.content.SharedPreferences sp = support.getContext()
                    .getSharedPreferences("ephemeris_prefs", android.content.Context.MODE_PRIVATE);
            sp.edit()
                    .putString("last_consult_tag", tag)
                    .putInt("last_consult_ver", version)
                    .putLong("last_consult_ms", System.currentTimeMillis())
                    .apply();
        } catch (Exception e) {
            LOG.error("Failed to record ephemeris consult", e);
        }
    }

    //File transfer related
    /**
     * 手表在没有重新 operator 握手的情况下直接轮询 FileList 时，
     * 用上一次协商成功的 version/uuid/files 补发（前提是 zip 仍有效且文件齐全）。
     * GT5 实测：上传完成后每隔约 20s 会再发 FileList 轮询，原实现直接丢弃，
     * 手表拿不到补充数据只能继续慢速搜星。
     */
    private RequestInfo tryRebuildFromLastConsult() {
        if (lastConsultRequest == null) return null;
        try {
            File filesDir = support.getContext().getExternalFilesDir(null);
            File file = new File(filesDir, "ephemeris.zip");
            if (loadAvailableConfig(file) == null) return null;
            if (availableDataConfig == null) return null;
            for (String fl : lastConsultRequest.getTagFiles()) {
                if (!isServableEntry(file, lastConsultRequest.getTagUUID() + File.separator + fl)) {
                    FileLogger.w("HuaweiEphemerisManager", "星历 FileList 补发：zip 内缺少或不可用条目 " + fl);
                    return null;
                }
            }
            FileLogger.i("HuaweiEphemerisManager", "星历 FileList 请求无进行中的会话，用缓存协商补发: entry=" + lastConsultEntry +
                    " version=" + lastConsultRequest.getTagVersion() + " files=" + lastConsultRequest.getTagFiles());
            return new RequestInfo(lastConsultRequest.getTagVersion(), lastConsultRequest.getTagUUID(), lastConsultRequest.getTagFiles());
        } catch (Exception e) {
            FileLogger.e("HuaweiEphemerisManager", "星历 FileList 补发失败", e);
            return null;
        }
    }

    public void handleFileSendRequest(byte fileType, String productId) {
        LOG.info("Ephemeris handleFileSendRequest fileType={} productId={}", fileType, productId);
        FileLogger.i("HuaweiEphemerisManager", "星历 FileList 请求: fileType=" + fileType + " productId=" + productId);
        if(currentRequest == null) {
            currentRequest = tryRebuildFromLastConsult();
        }
        if(currentRequest == null) {
            // 无法补发时明确回错误（100001），不再静默丢弃，避免手表空等
            FileLogger.w("HuaweiEphemerisManager", "星历 FileList 请求被丢弃：无进行中的会话且缓存协商不可用");
            try {
                SendEphemerisFileListResponse errorResponse = new SendEphemerisFileListResponse(this.support, 100001, "");
                errorResponse.doPerform();
            } catch (IOException e) {
                LOG.error("Error to send SendEphemerisFileListResponse");
            }
            return;
        }

        String fileList = "";
        int responseCode = 0;

        if(fileType == 0) {
            //TODO: find all files that name contain productId and send
            LOG.error("Currently not supported. File type: 0");
        } else if(fileType == 1){
            if(currentRequest.getTagVersion() == 0) {
                //TODO: implement this type
                //fileList = "gpslocation.dat";
                LOG.error("Currently not supported. File type 1. Tag version 0");
            } else if (currentRequest.getTagVersion() == 1 || currentRequest.getTagVersion() == 2 || currentRequest.getTagVersion() == 3){
                int i = 0;
                while (i < currentRequest.getTagFiles().size()) {
                    fileList += currentRequest.getTagFiles().get(i);
                    if (i == currentRequest.getTagFiles().size() - 1) {
                        break;
                    }
                    fileList += ";";
                    i++;
                }
            } else {
                LOG.error("Unknown version");
            }
        } else {
            LOG.error("Unknown file id");
        }

        if(TextUtils.isEmpty(fileList)) {
            responseCode = 100001;
            cleanupUpload(true);
        }

        try {
            SendEphemerisFileListResponse sendEphemerisFileListResponse = new SendEphemerisFileListResponse(this.support, responseCode, fileList);
            sendEphemerisFileListResponse.doPerform();
        } catch (IOException e) {
            LOG.error("Error to send SendEphemerisFileListResponse");
        }
    }

    public void handleFileConsultIncomingRequest(int responseCode, String protocolVersion, byte bitmapEnable, short transferSize, int maxDataSize, short timeOut, byte fileType) {
        LOG.info("Ephemeris handleFileConsultIncomingRequest responseCode={} protocolVersion={} bitmapEnable={} transferSize={} maxDataSize={} timeOut={} fileType={}",
                responseCode, protocolVersion, bitmapEnable, transferSize, maxDataSize, timeOut, fileType);
        FileLogger.i("HuaweiEphemerisManager", "星历文件协商: responseCode=" + responseCode + " transferSize=" + transferSize +
                " maxDataSize=" + maxDataSize + " fileType=" + fileType);
        if(currentRequest == null) {
            FileLogger.w("HuaweiEphemerisManager", "星历文件协商被丢弃：无进行中的会话");
            return;
        }

        if (responseCode != 0) {
            LOG.error("Error on handleFileConsultIncomingRequest: {}", responseCode);
            cleanupUpload(true);
            return;
        }

        if (transferSize == 0) {
            LOG.error("transfer size is 0");
            cleanupUpload(true);
            return;
        }

        currentRequest.setUploadParameters(new UploadParameters(protocolVersion, bitmapEnable, transferSize, maxDataSize, timeOut, fileType));

        if((!TextUtils.isEmpty(protocolVersion) && fileType == 0) || fileType == 1) {
            try {
                SendEphemerisFileConsultResponse sendEphemerisFileConsultResponse = new SendEphemerisFileConsultResponse(this.support, 100000);
                sendEphemerisFileConsultResponse.doPerform();
            } catch (IOException e) {
                LOG.error("Error to send SendEphemerisFileConsultResponse");
            }
        } else {
            // I don't know how to  properly process error in this case. Just cleanup.
            cleanupUpload(true);
        }
    }

    public void handleSingleFileIncomingRequest(String filename) {
        LOG.info("Ephemeris handleSingleFileIncomingRequest filename={}", filename);
        if(currentRequest == null || currentRequest.getUploadParameters() == null) {
            cleanupUpload(true);
            return;
        }

        if(TextUtils.isEmpty(filename) || !currentRequest.getTagFiles().contains(filename)) {
            cleanupUpload(true);
            try {
                SendEphemerisSingleFileInfoResponse sendEphemerisSingleFileInfoResponse = new SendEphemerisSingleFileInfoResponse(this.support, 100001, 0, (short) 0);
                sendEphemerisSingleFileInfoResponse.doPerform();
            } catch (IOException e) {
                LOG.error("Error to send sendEphemerisSingleFileInfoResponse");
            }
            return;
        }

        currentRequest.addProcessedFile(filename);

        int responseCode = 0;
        try {

            File filesDir = support.getContext().getExternalFilesDir(null);
            File file = new File(filesDir, "ephemeris.zip");
            if (!file.exists()) {
                throw new Exception("Ephemeris handleSingleFileIncomingRequest file does not exists");
            }

            byte[] currentFileData = getZIPFileContent(file, currentRequest.getTagUUID() + File.separator + filename);
            if (currentFileData == null || currentFileData.length == 0) {
                throw new Exception("Ephemeris handleSingleFileIncomingRequest file is empty");
            }
            currentRequest.setCurrentFileData(currentFileData);
            currentRequest.setCurrentFileName(filename);
        } catch (Exception e) {
            LOG.error("Ephemeris exception handleSingleFileIncomingRequest processing", e);
            cleanupUpload(true);
            responseCode = 100001;
        }

        short crc = 0;
        if(currentRequest.getUploadParameters().getFileType() == 0) {
            //TODO: implement this type
            responseCode = 100001;
        } else if(currentRequest.getUploadParameters().getFileType()  == 1) {
            crc = (short)CheckSums.getCRC16(currentRequest.getCurrentFileData(), 0x0000);
        }

        int size = 0;
        if(currentRequest.getCurrentFileData() == null || crc == 0) {
            responseCode = 100001;
        } else {
            size = currentRequest.getCurrentFileData().length;
        }

        LOG.info("Ephemeris single file response: file={} size={} crc={}", filename, size, String.format("0x%04x", crc));
        FileLogger.i("HuaweiEphemerisManager", "星历单文件信息: file=" + filename + " size=" + size + " crc=" + String.format("0x%04x", crc) + " responseCode=" + responseCode);
        try {
            SendEphemerisSingleFileInfoResponse sendEphemerisSingleFileInfoResponse = new SendEphemerisSingleFileInfoResponse(this.support, responseCode, size, crc);
            sendEphemerisSingleFileInfoResponse.doPerform();
        } catch (IOException e) {
            LOG.error("Error to send SendEphemerisSingleFileInfoResponse");
        }
    }

    public static String getHexDigest(String str) {
        if (TextUtils.isEmpty(str)) {
            return "";
        }
        if (str.contains(":")) {
            str = str.replace(":", "");
        }
        try {
            byte[] data = CryptoUtils.digest(str.getBytes(StandardCharsets.UTF_8));
            return StringUtils.bytesToHex(data);
        } catch (NoSuchAlgorithmException e) {
            LOG.error("EncryptUtil getEncryption :{} ", e.getMessage());
            return "";
        }
    }

    public void handleDataRequestIncomingRequest(int responseCode, String fileName, int offset, int len, byte bitmap) {
        LOG.info("Ephemeris handleDataRequestIncomingRequest responseCode={} fileName={} offset={} len={} bitmap={}",
                responseCode, fileName, offset, len, bitmap);
        if(currentRequest == null || currentRequest.getUploadParameters() == null) {
            cleanupUpload(true);
            return;
        }

        if(offset == -1 || fileName == null || fileName.isEmpty()) {
            cleanupUpload(true);
            return;
        }

        if(!currentRequest.getCurrentFileName().equals(fileName)) {
            cleanupUpload(true);
            return;
        }

        int localResponseCode = 100000;

        String localFilename = "";

        if(currentRequest.getUploadParameters().getFileType() == 0) {
            //TODO: implement this type
            localResponseCode = 100001;
        } else if(currentRequest.getUploadParameters().getFileType() == 1) {
            localFilename = getHexDigest(support.getDeviceMac()) + fileName;
        } else {
            LOG.error("Unsupported type: {}", currentRequest.getUploadParameters().getFileType());
            localResponseCode = 100001;
        }

        try {
            SendEphemerisDataRequestResponse sendEphemerisDataRequestResponse = new SendEphemerisDataRequestResponse(this.support, localResponseCode, localFilename, offset);
            sendEphemerisDataRequestResponse.doPerform();
        } catch (IOException e) {
            LOG.error("Error to send SendEphemerisDataRequestResponse");
        }

        if(localResponseCode == 100000) {
            int dataSize = Math.min(currentRequest.getCurrentFileData().length - offset,currentRequest.getUploadParameters().getMaxDataSize());
            int packetsCount = (int) Math.ceil((double) dataSize / currentRequest.getUploadParameters().getTransferSize());
            byte[] chunk = new byte[dataSize];
            System.arraycopy(currentRequest.getCurrentFileData(), offset, chunk, 0, dataSize);

            try {
                int headerMode = getChunkProbeMode();
                currentSentChunkMode = headerMode;
                LOG.info("Ephemeris send chunk: file={} dataSize={} packets={} transferSize={} responseFilename={} headerMode={}",
                        currentRequest.getCurrentFileName(), dataSize, packetsCount,
                        currentRequest.getUploadParameters().getTransferSize(), localFilename, headerMode);
                FileLogger.i("HuaweiEphemerisManager", "星历发送分片: file=" + currentRequest.getCurrentFileName() +
                        " dataSize=" + dataSize + " packets=" + packetsCount + " headerMode=" + headerMode);
                SendEphemerisFileUploadChunk sendEphemerisFileUploadChunk =
                        new SendEphemerisFileUploadChunk(this.support, chunk,
                                currentRequest.getUploadParameters().getTransferSize(), packetsCount, headerMode);
                sendEphemerisFileUploadChunk.doPerform();
            } catch (IOException e) {
                LOG.error("Error to send SendEphemerisFileUploadChunk");
                FileLogger.e("HuaweiEphemerisManager", "星历分片发送失败", e);
            }
        }
    }

    public void handleFileUploadResponse(int responseCode) {
        LOG.info("handleFileUploadResponse {}", responseCode);
        FileLogger.i("HuaweiEphemerisManager", "星历分片回执: responseCode=" + responseCode);
        if(responseCode != 100000) {
            if (responseCode == 100010) {
                if (getChunkProbeMode() == currentSentChunkMode) {
                    // 分片格式探测：保留会话，等手表重试 DataRequest 时换下一种分片头
                    int next = (getChunkProbeMode() + 1) % CHUNK_PROBE_MODES;
                    setChunkProbeMode(next);
                    LOG.info("Ephemeris chunk rejected (100010), next headerMode={}", next);
                    FileLogger.w("HuaweiEphemerisManager", "星历分片被拒(100010)，切换 headerMode=" + next);
                } else {
                    LOG.info("Ephemeris chunk rejected (100010) for stale batch, keep headerMode={}", getChunkProbeMode());
                    FileLogger.w("HuaweiEphemerisManager", "星历分片被拒(100010)（过期批次），保持 headerMode=" + getChunkProbeMode());
                }
            } else {
                FileLogger.e("HuaweiEphemerisManager", "星历分片回执异常 code=" + responseCode + "，终止本次上传", null);
                cleanupUpload(true);
            }
        }
    }

    public void handleFileDoneRequest(byte uploadResult) {
        LOG.info("handleFileDoneRequest");
        // uploadResult 语义未公开：0 大概率为成功，非 0 原样记录供排查
        FileLogger.i("HuaweiEphemerisManager", "星历上传完成: uploadResult=" + uploadResult);
        cleanupUpload(false);
        try {
            SendEphemerisFileUploadDoneResponse sendEphemerisFileUploadDoneResponse = new SendEphemerisFileUploadDoneResponse(this.support, 100000);
            sendEphemerisFileUploadDoneResponse.doPerform();
        } catch (IOException e) {
            LOG.error("Error to send SendEphemerisFileUploadDoneResponse");
        }
    }

    void cleanupUpload(boolean force) {
        if(currentRequest != null) {
            currentRequest.setCurrentFileName(null);
            currentRequest.setCurrentFileData(null);
            currentRequest.setUploadParameters(null);
            boolean isAllProcessed = currentRequest.isAllProcessed();
            LOG.info("Ephemeris is Done: {}", isAllProcessed);
            if(isAllProcessed || force) {
                currentRequest = null;
                LOG.info("Ephemeris All files uploaded. {} Cleanup...", force?"Force":"");
            }
        }
    }

}
