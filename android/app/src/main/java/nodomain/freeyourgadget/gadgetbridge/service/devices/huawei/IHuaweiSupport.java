/*
 * 移植自 Gadgetbridge (AGPL-3.0) 的接口抽象，由 App 的 HuaweiWatchManager 实现。
 * 对应原版 HuaweiSupportProvider 的最小方法集，仅保留 BR/EDR 连接与心率/睡眠所需部分。
 */
package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei;

import android.content.Context;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiCoordinatorSupplier;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiCoordinator;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.App;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.GpsAndTime;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.MusicControl;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Watchface;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Weather;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Workout;
import nodomain.freeyourgadget.gadgetbridge.impl.GBDevice;
import nodomain.freeyourgadget.gadgetbridge.impl.GBDeviceMusic;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.HuaweiEphemerisManager;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.HuaweiUploadManager;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p.HuaweiP2PDataDictionarySyncService;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.Request;

public interface IHuaweiSupport {
    HuaweiPacket.ParamsProvider getParamsProvider();

    HuaweiCoordinator getHuaweiCoordinator();

    HuaweiCoordinatorSupplier.HuaweiDeviceType getHuaweiType();

    byte[] getAndroidId();

    byte[] getMacAddress();

    String getDeviceMac();

    GBDevice getDevice();

    byte[] getSecretKey();

    void setSecretKey(byte[] authKey);

    void setProtocolVersion(byte protocolVersion);

    byte getProtocolVersion();

    Context getContext();

    void write(byte[] data);

    void waitMillis(int millis);

    void addInProgressRequest(Request request);

    void removeInProgressRequests(Request... requests);

    void evaluateGBDeviceEvent(Object event);

    boolean startBatteryRunnerDelayed();

    void initializeDynamicServices();

    void addStepData(int timestamp, short steps, short calories, short distance, byte spo, byte heartrate, byte restingHeartRate);

    void addSleepActivity(int timestampStart, int timestampEnd, byte type, byte source);

    void addTotalFitnessData(int steps, int calories, int distance);

    void downloadQueueEmpty(boolean needSync);

    boolean isWorkoutDeleted(int workoutNumber);

    Long addWorkoutTotalsData(Workout.WorkoutTotals.Response packet);

    void addWorkoutSampleData(Long workoutId, List<Workout.WorkoutData.Response.Data> dataList);

    void addWorkoutPaceData(Long workoutId, List<Workout.WorkoutPace.Response.Block> paceList, short number);

    void addWorkoutSwimSegmentsData(Long workoutId, List<Workout.WorkoutSwimSegments.Response.Block> segmentsList, short number);

    void downloadWorkoutGpsFiles(short workoutId, Long databaseId, Runnable extraCallbackAction);

    void endOfWorkoutSync();

    void addDictData(List<HuaweiP2PDataDictionarySyncService.DictData> dictData);

    long getLastDataDictLastTimestamp(int dictClass);

    void onAsyncPacket(HuaweiPacket packet);

    Weather.WeatherIcon openWeatherMapConditionCodeToHuaweiIcon(int conditionCode);

    HuaweiEphemerisManager getHuaweiEphemerisManager();

    HuaweiUploadManager getUploadManager();

    void setGpsParametersResponse(GpsAndTime.GpsParameters.Response response);

    void setInstalledAppList(List<App.InstalledAppInfo> appInfoList);

    void setAppDeviceParams(App.AppDeviceParams params);

    void saveMaxContactsCount(int maxCount);

    void onMusicOperationResponse(int resultCode, int operation, int playlistIndex, String playlistName, List<Integer> musicIds);

    void onMusicInfoParams(MusicControl.MusicInfoParams.Response response);

    void onExtendedMusicInfoParams(MusicControl.ExtendedMusicInfoParams.Response response);

    void onMusicListResponse(int startFrame, int endFrame, List<GBDeviceMusic> musicList);

    void onMusicPlaylistResponse(List<MusicControl.MusicPlaylists.Response.PlaylistData> playlists);

    void onMusicPlaylistMusics(int playlistId, int index, List<Integer> musicIds);

    void setInstalledWatchfaceInfoList(List<Watchface.InstalledWatchfaceInfo> watchfaceInfoList);

    void setWatchfacesNames(java.util.Map<String, String> watchFaceNames);

    void setWatchfaceDeviceParams(Watchface.WatchfaceDeviceParams params);

    byte[] getSerial();

    short getNotificationId();

    void saveAlarmsFromWatch(int[][] alarms);
}
