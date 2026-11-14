/// 首页聚合数据，对应设计稿「体能首页」。
pub struct HomeSummary {
    pub date_epoch_day: i64,
    pub readiness: ReadinessScore,
    pub readiness_history: Vec<ReadinessPoint>,
    pub steps: i64,
    pub steps_goal: i64,
    pub active_calories: i64,
    pub calories_goal: i64,
    pub distance_m: i64,
    pub active_minutes: i64,
    /// 运动时长（分钟）：优先手表锻炼环的 `daily_rings.duration_user_min`，
    /// 三环还没同步上时退回当天本机运动记录的总时长。
    pub exercise_minutes: i64,
    pub exercise_goal_min: i64,
    /// 活跃小时数：单小时步数达到 20 步即记 1 小时。没有逐小时步数样本时为 None，
    /// 宁可在 UI 上显示「--」也不给历史日期编一个 0。
    pub active_hours: Option<i64>,
    pub active_hours_goal: i64,
    /// 跑力指数：华为只统计超过 12 分钟、心率 ≥100bpm 的跑步并按最佳成绩取值，
    /// 我们用跑表同步的 TruSport VO2max 作为同源指标，取近 90 天达标跑步的最优。
    pub running_index: Option<f64>,
    pub resting_hr: Option<i64>,
    pub heart_rate: Option<i64>,
    pub heart_rate_series: Vec<Option<f64>>,
    pub hrv_ms: Option<i64>,
    pub sleep_minutes: Option<i64>,
    pub deep_sleep_minutes: Option<i64>,
    pub sleep_heart_rate: Option<i64>,
    pub spo2: Option<i64>,
    pub stress: Option<i64>,
    pub body_temp_delta: Option<f64>,
    /// 最近一次腕部皮肤温度（°C）与它的读数时间；时间为空表示就是当天。
    pub skin_temp_c: Option<f64>,
    pub skin_temp_at_ms: Option<i64>,
    /// 最近一次核心体温（°C）与它的读数时间；有值时优先于腕温展示。
    pub body_temp_c: Option<f64>,
    pub body_temp_at_ms: Option<i64>,
    pub weight_kg: Option<f64>,
    pub bmi: Option<f64>,
    pub body_fat_percent: Option<f64>,
    pub blood_pressure_systolic: Option<i64>,
    pub blood_pressure_diastolic: Option<i64>,
    pub glucose_mmol: Option<f64>,
    pub respiration: Option<i64>,
    pub arrhythmia_result: Option<i64>,
    pub arrhythmia_at_ms: Option<i64>,
    pub ecg_result: Option<i64>,
    pub ecg_avg_heart_rate: Option<i64>,
    pub ecg_at_ms: Option<i64>,
    pub ecg_duration_sec: Option<i64>,
    pub emotion_status: Option<i64>,
    pub emotion_valence: Option<f64>,
    pub emotion_arousal: Option<f64>,
    pub vo2max: Option<f64>,
    pub weekly_load: i64,
    pub weekly_workouts: i64,
    pub last_sync_ms: Option<i64>,
    pub device_name: Option<String>,
    pub device_battery: Option<i64>,
    pub device_connected: bool,
}

pub struct ReadinessScore {
    pub total: i64,
    pub level: String,
    pub advice: String,
    /// 相对昨天的变化，正数为变好。
    pub trend: i64,
    pub hrv_score: i64,
    pub sleep_score: i64,
    pub rhr_score: i64,
    pub temp_score: i64,
    pub stress_score: i64,
    /// 当天全部运动建议恢复时间累加后的得分；没有运动恢复数据时为 0。
    pub recovery_score: i64,
    /// 当天全部运动建议恢复时间之和（分钟）。
    pub recovery_minutes: i64,
    pub computed_at_ms: i64,
}

pub struct ReadinessWeights {
    pub hrv: i64,
    pub sleep: i64,
    pub rhr: i64,
    pub temp: i64,
    pub stress: i64,
    pub recovery: i64,
}

pub struct ReadinessPoint {
    pub date_epoch_day: i64,
    pub total: i64,
}

pub struct ReadinessDetail {
    pub date_epoch_day: i64,
    pub score: ReadinessScore,
    pub week_average: i64,
    pub history: Vec<ReadinessPoint>,
    pub inputs: ReadinessInputs,
    pub baseline: ReadinessBaseline,
    pub weights: ReadinessWeights,
}

pub struct ReadinessInputs {
    pub hrv_ms: Option<f64>,
    pub sleep_minutes: Option<f64>,
    pub deep_sleep_minutes: Option<f64>,
    pub sleep_awakenings: Option<f64>,
    pub resting_hr: Option<f64>,
    pub skin_temp_c: Option<f64>,
    pub stress: Option<f64>,
    /// 同一本地自然日内所有运动的恢复时间累加，单位分钟。
    pub recovery_minutes: Option<f64>,
}

pub struct ReadinessBaseline {
    pub hrv_ms: Option<f64>,
    pub sleep_minutes: Option<f64>,
    pub resting_hr: Option<f64>,
    pub skin_temp_c: Option<f64>,
    pub stress: Option<f64>,
}

/// 单次达标跑步的跑力样本（华为规则：>12 分钟、心率 ≥100bpm）。
pub struct RunningIndexPoint {
    pub start_ms: i64,
    /// 该次跑步手表估算的 VO2max，作为跑力指数（TruSport 同源）。
    pub rai: f64,
    pub distance_m: f64,
    pub duration_sec: i64,
    pub avg_hr: i64,
}

pub struct WorkoutSummary {
    pub id: String,
    pub sport: String,
    pub source: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_sec: i64,
    pub distance_m: f64,
    pub calories: i64,
    pub avg_hr: i64,
    pub max_hr: i64,
    pub steps: i64,
    pub load: i64,
    pub synced: bool,
}

pub struct WorkoutDetail {
    pub summary: WorkoutSummary,
    pub aerobic_effect: f64,
    pub anaerobic_effect: f64,
    pub recovery_time_min: i64,
    pub max_met: Option<f64>,
    pub vo2max: Option<f64>,
    pub elevation_gain: Option<f64>,
    pub elevation_loss: Option<f64>,
    pub avg_pace_sec: Option<f64>,
    pub cadence: Option<f64>,
    pub track_json: Option<String>,
    pub samples_json: Option<String>,
    pub dynamics_json: Option<String>,
    pub altitude_json: Option<String>,
    pub recovery_json: Option<String>,
    /// 手表官方分段（0x0c）：type=0 为整公里，type=1 为整英里。
    pub splits_json: Option<String>,
    /// 游泳分段（WorkoutSwimSegments）：泳池每段的距离、配速、划水次数与 SWOLF。
    pub swim_segments_json: Option<String>,
    pub start_temp_c: Option<f64>,
    pub start_humidity: Option<i64>,
    /// 手表 tag 0x63：训练积分。
    pub training_points: Option<i64>,
    /// 手表 tag 0x0f：EPOC 原始值。
    pub epoc: Option<i64>,
    /// 手表 0xe7 扩展统计：字段编号 → 原始字符串值的 JSON 对象。
    pub stat_extend_json: Option<String>,
    /// 手表 0x50–0x5a：跑步配速区间，原始秒/公里与各区间秒数。
    pub run_pace_zones_json: Option<String>,
    pub max_altitude: Option<f64>,
    pub min_altitude: Option<f64>,
    pub alg_type: Option<i64>,
    pub upload_status: i64,
}

/// 缺少运动天气、但带有效轨迹起点的记录。由 Rust 先解析首点，
/// 避免 Flutter 为了补天气把整段 track_json 拉过来。
pub struct WorkoutWeatherCandidate {
    pub id: String,
    pub start_ms: i64,
    pub lat: f64,
    pub lon: f64,
    pub start_temp_c: Option<f64>,
    pub start_humidity: Option<i64>,
}

/// 力量训练动作库条目。
pub struct StrengthExercise {
    pub id: i64,
    pub name: String,
    pub muscle_group: String,
    pub equipment: String,
    pub is_custom: bool,
}

/// 模板里的一个动作配置。
pub struct StrengthTemplateExercise {
    pub id: i64,
    pub exercise_id: i64,
    pub exercise_name: String,
    pub order_index: i64,
    pub target_sets: i64,
    pub target_reps: i64,
    pub rest_seconds: i64,
    pub target_weight_kg: Option<f64>,
    pub notes: String,
}

pub struct StrengthTemplate {
    pub id: i64,
    pub name: String,
    pub notes: String,
    pub updated_at_ms: i64,
    pub exercises: Vec<StrengthTemplateExercise>,
}

/// 保存模板时的动作配置（id 传 0 表示新模板）。
pub struct StrengthTemplateExerciseInput {
    pub exercise_id: i64,
    pub target_sets: i64,
    pub target_reps: i64,
    pub rest_seconds: i64,
    pub target_weight_kg: Option<f64>,
    pub notes: String,
}

/// 一次实际完成的组。
pub struct StrengthSetInput {
    pub exercise_id: i64,
    pub exercise_name: String,
    pub set_number: i64,
    pub weight_kg: f64,
    pub reps: i64,
    pub rest_seconds_actual: i64,
    pub completed_at_ms: i64,
}

pub struct StrengthSet {
    pub id: i64,
    pub session_id: String,
    pub exercise_id: i64,
    pub exercise_name: String,
    pub set_number: i64,
    pub weight_kg: f64,
    pub reps: i64,
    pub rest_seconds_actual: i64,
    pub completed_at_ms: i64,
}

/// 睡眠呼吸暂停（P2P 500002），每条是当晚的风险级别 0–10。
pub struct ApneaRecord {
    pub ts_ms: i64,
    pub level: i64,
}

/// 每小时状态（P2P 200005）：活动小时达标，value 恒为 1。
pub struct HourlyStatusPoint {
    pub ts_ms: i64,
    pub value: i64,
}

/// 官方每日活动三环（P2P 300002）。热量单位是毫卡，和旧版一致。
pub struct DailyRing {
    pub date_epoch_day: i64,
    pub day_end_ms: i64,
    pub step_goal: i64,
    pub step_user: i64,
    pub step_state: i64,
    pub calorie_goal_milli: i64,
    pub calorie_user_milli: i64,
    pub calorie_state: i64,
    pub duration_goal_min: i64,
    pub duration_user_min: i64,
    pub duration_state: i64,
    pub active_goal_hours: i64,
    pub active_user_hours: i64,
    pub active_state: i64,
}

pub struct GeoPoint {
    pub lat: f64,
    pub lon: f64,
}

/// 本机保存的规划路线。
pub struct SavedRoute {
    pub id: String,
    pub name: String,
    pub distance_m: f64,
    pub created_ms: i64,
    pub points: Vec<GeoPoint>,
}

#[derive(Clone)]
pub struct DailyPoint {
    pub date_epoch_day: i64,
    pub value: f64,
}

pub struct MetricDay {
    pub date_epoch_day: i64,
    pub steps: i64,
    pub active_calories: i64,
    pub resting_hr: Option<i64>,
    pub hrv_ms: Option<i64>,
    pub sleep_minutes: Option<i64>,
    pub stress: Option<i64>,
    pub spo2: Option<i64>,
    pub weight_kg: Option<f64>,
    pub skin_temp_c: Option<f64>,
}

pub struct SleepSummary {
    pub date_epoch_day: i64,
    pub total_minutes: i64,
    pub deep_minutes: i64,
    pub light_minutes: i64,
    pub rem_minutes: i64,
    pub awake_minutes: i64,
    /// 当天除主睡眠外累加的午睡/小睡分钟数；为 0 表示只有一场主睡眠。
    pub nap_minutes: i64,
    pub start_ms: i64,
    pub end_ms: i64,
    pub efficiency: i64,
    pub score: i64,
}

pub struct Profile {
    pub nickname: String,
    pub gender: String,
    pub height_cm: f64,
    pub weight_kg: f64,
    pub birth_date: String,
    pub email: String,
}

pub struct DeviceInfo {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub address: String,
    pub battery: i64,
    pub last_sync_ms: Option<i64>,
    pub connected: bool,
}

pub struct WeightEntry {
    pub id: String,
    pub timestamp_ms: i64,
    pub weight_kg: f64,
    pub body_fat_percent: Option<f64>,
    pub muscle_percent: Option<f64>,
    pub water_percent: Option<f64>,
    pub source: String,
    pub height_cm: Option<f64>,
    pub bmi: Option<f64>,
    pub fat_mass_kg: Option<f64>,
    pub muscle_mass_kg: Option<f64>,
    pub water_mass_kg: Option<f64>,
    pub protein_percent: Option<f64>,
    pub protein_mass_kg: Option<f64>,
    pub bone_percent: Option<f64>,
    pub bone_mass_kg: Option<f64>,
    pub skeletal_muscle_percent: Option<f64>,
    pub skeletal_muscle_mass_kg: Option<f64>,
    pub subcutaneous_fat_percent: Option<f64>,
    pub subcutaneous_fat_mass_kg: Option<f64>,
    pub resistance_ohm: Option<f64>,
    pub body_composition_model: Option<String>,
    pub device_name: Option<String>,
}

pub struct MetricSample {
    pub timestamp_ms: i64,
    pub value: f64,
}

pub struct MetricDetail {
    pub metric: String,
    pub label: String,
    pub unit: String,
    pub description: String,
    pub source: String,
    pub days: Vec<DailyPoint>,
    pub samples: Vec<MetricSample>,
    pub latest: Option<f64>,
    pub average: Option<f64>,
    pub minimum: Option<f64>,
    pub maximum: Option<f64>,
    pub baseline: Option<f64>,
    pub trend: Option<f64>,
    pub goal: Option<f64>,
    pub has_data: bool,
    pub updated_ms: Option<i64>,
}

pub struct PersonalRecord {
    pub sport: String,
    pub metric: String,
    pub label: String,
    pub value: f64,
    pub unit: String,
    pub workout_id: String,
    pub achieved_ms: i64,
}

pub struct WatchIdentity {
    pub address: String,
    pub name: String,
    pub account: String,
    pub auth_key: String,
    pub fake_android_id: String,
    pub huawei_address: String,
    pub last_sync_ms: Option<i64>,
    pub migrated: bool,

    /// 自托管星历 zip 地址；空表示不主动补星历（手表只能自己搜星冷启动）
    pub ephemeris_url: String,
}

/// 手表连接与同步日志的一行，由原生层抛出、watch.rs 落库。
pub struct WatchLog {
    pub ts_ms: i64,
    pub msg: String,
}

pub struct Goals {
    pub steps: i64,
    pub calories: i64,
    pub active_minutes: i64,
    pub exercise_minutes: i64,
}

pub struct LegacyImportReport {
    pub ok: bool,
    pub already_imported: bool,
    pub message: String,
    pub days: i64,
    pub heart_rate_points: i64,
    pub sleep_sessions: i64,
    pub workouts: i64,
    pub weights: i64,
    pub blood_pressure: i64,
    pub glucose: i64,
    pub emotions: i64,
    pub samples: i64,
    pub identity: bool,
    pub profile: bool,
    pub goals: bool,
}

pub struct BloodPressureEntry {
    pub id: String,
    pub timestamp_ms: i64,
    pub systolic: i64,
    pub diastolic: i64,
    pub pulse: Option<i64>,
}

pub struct GlucoseEntry {
    pub id: String,
    pub timestamp_ms: i64,
    pub value: f64,
    pub measure_type: String,
}

pub struct ArrhythmiaEntry {
    pub timestamp_ms: i64,
    pub result_type: i64,
}

pub struct EcgEntry {
    pub start_ms: i64,
    pub end_ms: i64,
    pub avg_heart_rate: Option<i64>,
    pub arrhythmia_type: Option<i64>,
    pub sample_count: i64,
}

pub struct SleepStage {
    pub start_ms: i64,
    pub end_ms: i64,
    pub stage: String,
}

pub struct SleepDetail {
    pub summary: SleepSummary,
    pub stages: Vec<SleepStage>,
    /// 阶段图的时间轴范围：覆盖上床/醒来以及入睡前的清醒段，比 summary 窗口更宽。
    pub chart_start_ms: i64,
    pub chart_end_ms: i64,
    pub bed_ms: Option<i64>,
    pub fall_asleep_ms: Option<i64>,
    pub wake_ms: Option<i64>,
    pub breathing: Option<f64>,
    /// 手表睡眠详情里的官方夜间 HRV（RMSSD）。
    pub sleep_hrv_avg: Option<f64>,
    pub sleep_hrv_min_baseline: Option<f64>,
    pub sleep_hrv_max_baseline: Option<f64>,
    pub sleep_hrv_day_to_baseline: Option<f64>,
}

pub struct AppInfo {
    pub version: String,
    pub db_version: i64,
    pub demo_data: bool,
}

pub struct HrPoint {
    pub timestamp_ms: i64,
    pub bpm: i64,
}

/// 一次手动 HRV 测量的计算结果。数值为 0 时同时 `has_metrics=false`。
pub struct HrvMetrics {
    pub rr_count: i64,
    pub valid_rr_count: i64,
    pub outlier_count: i64,
    pub has_metrics: bool,
    pub rmssd_ms: f64,
    pub sdnn_ms: f64,
    pub pnn50: f64,
    pub average_hr: i64,
    pub quality: String,
    pub quality_label: String,
    pub quality_note: String,
    pub can_save: bool,
}

/// 用户自己登记的装备（跑鞋、骑行装备、泳池装备…）。
/// start_km 是启用时该运动类型的累计里程，已用里程由当前累计减去它得出。
pub struct Equipment {
    pub id: i64,
    pub name: String,
    pub sport: String,
    pub gear_type: String,
    pub brand: String,
    pub model: String,
    pub purchase_ms: i64,
    pub is_active: bool,
    pub start_km: f64,
    pub limit_km: f64,
    pub note: String,
}
