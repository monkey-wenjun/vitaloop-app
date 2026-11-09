package nodomain.freeyourgadget.gadgetbridge.devices.huawei;

public class HuaweiDictTypes {
    public static final int BLOOD_PRESSURE_CLASS = 10002;

    public static final int BODY_TEMPERATURE_CLASS = 400011;
    /**
     * 官方字典 400011 = BODY_TEMPERATURE，字段 400011975 bodyTemperature（Double，°C），
     * 官方校验区间 34~42。它是手表算好的真实体温，不需要手机端再加任何偏移
     * （以前按「皮肤温度 +2°C」冒充体温是瞎猜的：400012 的官方校验区间就是 20~42，
     * 华为健康里这张卡在国内版本叫「皮肤温度」，不叫体温）。
     */
    public static final int BODY_TEMPERATURE_VALUE = 400011975;

    public static final int SKIN_TEMPERATURE_CLASS = 400012;
    public static final int SKIN_TEMPERATURE_VALUE = 400012430;

    // 华为健康数据字典：HRV（RMSSD），与上游 Gadgetbridge 反编译协议一致
    public static final int HRV_CLASS = 500044;
    public static final int HRV_RMSSD_VALUE = 500044831;

    // 情绪
    public static final int EMOTION_CLASS = 500031;
    public static final int EMOTION_STATUS_VALUE = 500031195;
    public static final int EMOTION_VALENCE_VALUE = 500031347;
    public static final int EMOTION_ORIGIN_STATUS_VALUE = 500031160;
    public static final int EMOTION_AROUSAL_VALUE = 500031842;

    // 睡眠呼吸暂停
    public static final int SLEEP_APNEA_CLASS = 500002;
    public static final int SLEEP_APNEA_LEVEL_VALUE = 500002847;

    /**
     * 官方在床/睡眠会话（华为健康 assets/dict_config.txt v20221108：typeId 500010 =
     * SLEEP_ON_OFF_BED_RECORD）。四个字段都是 **Long 纪元**，不是 Double —— 以前按 Double
     * 解 500010278，解出来恒为 0，被当成"每日状态"存了下来。
     */
    public static final int SLEEP_ON_OFF_BED_CLASS = 500010;
    public static final int SLEEP_BED_TIME_VALUE = 500010278;
    public static final int SLEEP_RISING_TIME_VALUE = 500010313;
    public static final int SLEEP_FALL_ASLEEP_TIME_VALUE = 500010432;
    public static final int SLEEP_WAKEUP_TIME_VALUE = 500010563;

    /** 每小时状态（200005 = ACTIVE_HOUR，活动小时达标标记，值恒为 1） */
    public static final int HOURLY_STATUS_CLASS = 200005;
    public static final int HOURLY_STATUS_VALUE = 200005528;

    /**
     * 官方每日活动三环（dict_config：typeId 300002 = SPORT_GOAL_ACHIEVEMENT_DATA）。
     * GT 5 实测：每天 23:59:59 落一条当天汇总，只发完整天（今天的块次日才有），
     * 16 个字段全部 tag=10 大端 Double；各环按 目标/实际/达标位/isRing 成组。
     * 单位与官方一致：热量毫卡（官方 Math.round(v/1000)）、锻炼分钟、活动小时。
     */
    public static final int DAILY_RING_CLASS = 300002;
    public static final int RING_STEP_GOAL_VALUE = 300002242;
    public static final int RING_STEP_USER_VALUE = 300002382;
    public static final int RING_STEP_GOAL_STATE_VALUE = 300002106;
    public static final int RING_STEP_IS_RING_VALUE = 300002714;
    public static final int RING_CALORIE_GOAL_VALUE = 300002263;
    public static final int RING_CALORIE_USER_VALUE = 300002409;
    public static final int RING_CALORIE_GOAL_STATE_VALUE = 300002399;
    public static final int RING_CALORIE_IS_RING_VALUE = 300002313;
    public static final int RING_DURATION_GOAL_VALUE = 300002094;
    public static final int RING_DURATION_USER_VALUE = 300002578;
    public static final int RING_DURATION_GOAL_STATE_VALUE = 300002210;
    public static final int RING_DURATION_IS_RING_VALUE = 300002810;
    public static final int RING_ACTIVE_GOAL_VALUE = 300002360;
    public static final int RING_ACTIVE_USER_VALUE = 300002312;
    public static final int RING_ACTIVE_GOAL_STATE_VALUE = 300002496;
    public static final int RING_ACTIVE_IS_RING_VALUE = 300002160;

    // 睡眠详情（TruSleep 序列数据文件，含呼吸率/心率/血氧等每晚统计）
    public static final int SLEEP_DETAILS_CLASS = 700013;

    /**
     * 压力（华为健康 assets/dict_config.json：typeId 500026 = STRESS，syncType 11）
     * field: 500026382 = stressScore(Integer)，500026285 = stressDetail(String)
     */
    public static final int STRESS_CLASS = 500026;
    public static final int STRESS_SCORE_VALUE = 500026382;

    /** 静息心率（dict_config.json：typeId 500024 = RESTING_HEART_RATE） */
    public static final int RESTING_HEART_RATE_CLASS = 500024;
    public static final int RESTING_HEART_RATE_VALUE = 2105;

    /**
     * 脉搏波心律失常分析结果（华为健康 assets/dict_config.txt：typeId 500007 =
     * ARRHYTHMIA_RESULT，category 0 = 单次样本，sensitivityLevel 1 = 医疗敏感数据）。
     *
     * 官方校验式写死在字典里：saveTime &gt; 0、measureType ∈ {0,1}、
     * ppgIrregularHeartbeat ∈ {1,2,3,4,5}，超出即被官方丢弃。
     * 结果码语义取自官方通知装配（defpackage.lld.beforePostActionPpg）：
     * 1=未见明显异常、2=疑似早搏、3=疑似房颤、4=房颤风险、5=早搏风险；
     * 拿到 NMPA（国内医疗器械注册）版本时官方会把 4 折叠成 3、5 折叠成 2
     * （defpackage.fzq.e），也就是国内口径只说「疑似」。
     */
    public static final int ARRHYTHMIA_CLASS = 500007;
    public static final int ARRHYTHMIA_SAVE_TIME_VALUE = 500007278;
    public static final int ARRHYTHMIA_MEASURE_TYPE_VALUE = 500007088;
    public static final int PPG_IRREGULAR_HEARTBEAT_VALUE = 2200;
}
