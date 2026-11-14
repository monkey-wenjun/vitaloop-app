use crate::api::types::*;
use crate::{demo, legacy, power, store};
use anyhow::Result;
use chrono::TimeZone;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// 打开本地数据库；首次启动时优先导入旧版数据，否则可写入示例数据。
pub fn bootstrap(db_path: String, seed_demo_if_empty: bool) -> Result<AppInfo> {
    if !store::is_open() {
        store::open(&db_path)?;
    }
    let imported = crate::legacy::auto_import_near(&db_path).unwrap_or(None);
    let _ = crate::legacy::backfill_encrypted_workout_tracks();
    if seed_demo_if_empty && imported.is_none() && !store::demo_installed() {
        let empty = store::with_conn(|conn| {
            let count: i64 =
                conn.query_row("SELECT COUNT(*) FROM daily_metrics", [], |r| r.get(0))?;
            Ok(count == 0)
        })?;
        if empty {
            demo::seed_demo()?;
        }
    }
    store::app_info()
}

#[flutter_rust_bridge::frb(sync)]
pub fn today_epoch_day() -> i64 {
    store::today_epoch_day()
}

pub fn get_home_summary(day: i64) -> Result<HomeSummary> {
    let day = if day == 0 {
        store::display_day(store::today_epoch_day())?
    } else {
        day
    };
    store::home_summary(day)
}

pub fn get_readiness_detail(day: i64) -> Result<ReadinessDetail> {
    let day = if day == 0 {
        store::display_day(store::today_epoch_day())?
    } else {
        day
    };
    store::readiness_detail(day)
}

pub fn get_readiness_series(days: i64) -> Result<Vec<DailyPoint>> {
    store::readiness_series(days)
}

/// 从心率带上报的 RR 间期计算 RMSSD/SDNN/pNN50 与数据质量。
pub fn calculate_hrv(rr_intervals: Vec<i64>) -> HrvMetrics {
    let stats = crate::hrv::analyze(&rr_intervals);
    HrvMetrics {
        rr_count: stats.rr_count,
        valid_rr_count: stats.valid_rr_count,
        outlier_count: stats.outlier_count,
        has_metrics: stats.has_metrics,
        rmssd_ms: stats.rmssd_ms,
        sdnn_ms: stats.sdnn_ms,
        pnn50: stats.pnn50,
        average_hr: stats.average_hr,
        quality: stats.quality,
        quality_label: stats.quality_label,
        quality_note: stats.quality_note,
        can_save: stats.can_save,
    }
}

pub fn get_metric_series(metric: String, days: i64) -> Result<Vec<DailyPoint>> {
    store::metric_series(&metric, days)
}

pub fn get_metric_days(from_day: i64, to_day: i64) -> Result<Vec<MetricDay>> {
    store::metric_days(from_day, to_day)
}

pub fn get_sleep_summary(day: i64) -> Result<Option<SleepSummary>> {
    if day != 0 {
        return store::sleep_summary(day);
    }
    match store::latest_sleep_day()? {
        Some(d) => store::sleep_summary(d),
        None => Ok(None),
    }
}

pub fn list_workouts(filter: String, limit: i64) -> Result<Vec<WorkoutSummary>> {
    store::list_workouts(&filter, limit)
}

// ---------- 力量训练 ----------

pub fn list_strength_exercises() -> Result<Vec<StrengthExercise>> {
    store::strength_exercises()
}

pub fn add_strength_exercise(name: String, muscle_group: String, equipment: String) -> Result<i64> {
    store::strength_add_exercise(&name, &muscle_group, &equipment)
}

pub fn list_strength_templates() -> Result<Vec<StrengthTemplate>> {
    store::strength_templates()
}

pub fn save_strength_template(
    id: i64,
    name: String,
    notes: String,
    exercises: Vec<StrengthTemplateExerciseInput>,
) -> Result<i64> {
    store::strength_save_template(id, &name, &notes, &exercises)
}

pub fn delete_strength_template(id: i64) -> Result<()> {
    store::strength_delete_template(id)
}

pub fn save_strength_sets(session_id: String, sets: Vec<StrengthSetInput>) -> Result<()> {
    store::strength_save_sets(&session_id, &sets)
}

pub fn list_strength_sets(session_id: String) -> Result<Vec<StrengthSet>> {
    store::strength_sets(&session_id)
}

// ---------- P2P 字典 ----------

pub fn list_apnea_records(limit: i64) -> Result<Vec<ApneaRecord>> {
    store::apnea_records(limit)
}

pub fn apnea_records_for_day(day: i64) -> Result<Vec<ApneaRecord>> {
    store::apnea_for_day(if day == 0 {
        store::display_day(store::today_epoch_day())?
    } else {
        day
    })
}

pub fn list_hourly_status(day: i64) -> Result<Vec<HourlyStatusPoint>> {
    store::hourly_status(if day == 0 {
        store::display_day(store::today_epoch_day())?
    } else {
        day
    })
}

pub fn list_daily_rings(limit: i64) -> Result<Vec<DailyRing>> {
    store::daily_rings(limit)
}

pub fn get_daily_ring(day: i64) -> Result<Option<DailyRing>> {
    store::daily_ring(day)
}

pub fn list_saved_routes() -> Result<Vec<SavedRoute>> {
    store::saved_routes()
}

pub fn save_saved_route(id: String, name: String, points: Vec<GeoPoint>) -> Result<String> {
    store::save_route(&id, &name, &points)
}

pub fn delete_saved_route(id: String) -> Result<()> {
    store::delete_route(&id)
}

/// 手机端手动记录一次运动，返回新运动 id。
pub fn save_manual_workout(
    sport: String,
    start_ms: i64,
    duration_sec: i64,
    distance_m: f64,
    calories: i64,
    avg_hr: i64,
    max_hr: i64,
    track_json: String,
) -> Result<String> {
    store::workout_add(
        &sport,
        start_ms,
        duration_sec,
        distance_m,
        calories,
        avg_hr,
        max_hr,
        &track_json,
    )
}

pub fn save_workout_recovery(id: String, recovery_json: String) -> Result<()> {
    store::workout_set_recovery(&id, &recovery_json)
}

pub fn set_workout_weather(id: String, temp_c: Option<f64>, humidity: Option<i64>) -> Result<()> {
    store::workout_set_weather(&id, temp_c, humidity)
}

pub fn workouts_missing_weather(limit: i64) -> Result<Vec<WorkoutWeatherCandidate>> {
    store::workouts_missing_weather(limit)
}

pub fn add_weight_record(weight_kg: f64, body_fat_percent: f64) -> Result<String> {
    store::add_weight_record(weight_kg, body_fat_percent)
}

pub fn add_blood_pressure(systolic: i64, diastolic: i64, pulse: i64) -> Result<String> {
    store::add_blood_pressure(systolic, diastolic, pulse)
}

pub fn add_blood_glucose(value: f64, measure_type: String) -> Result<String> {
    store::add_blood_glucose(value, &measure_type)
}

pub fn update_weight_record(id: String, weight_kg: f64, body_fat_percent: f64) -> Result<()> {
    store::update_weight_record(&id, weight_kg, body_fat_percent)
}

pub fn delete_weight_record(id: String) -> Result<()> {
    store::delete_weight_record(&id)
}

pub fn update_blood_pressure(id: String, systolic: i64, diastolic: i64, pulse: i64) -> Result<()> {
    store::update_blood_pressure(&id, systolic, diastolic, pulse)
}

pub fn delete_blood_pressure(id: String) -> Result<()> {
    store::delete_blood_pressure(&id)
}

pub fn update_blood_glucose(id: String, value: f64, measure_type: String) -> Result<()> {
    store::update_blood_glucose(&id, value, &measure_type)
}

pub fn delete_blood_glucose(id: String) -> Result<()> {
    store::delete_blood_glucose(&id)
}

pub fn get_running_index_history(limit: i64) -> Result<Vec<RunningIndexPoint>> {
    store::running_index_history(limit)
}

pub fn get_workout(id: String) -> Result<Option<WorkoutDetail>> {
    store::get_workout(&id)
}

#[flutter_rust_bridge::frb(sync)]
pub fn cycling_power_watts(
    speed_kmh: f64,
    gradient_percent: f64,
    rider_weight_kg: f64,
    bike_weight_kg: f64,
) -> f64 {
    power::watts(
        speed_kmh,
        gradient_percent,
        power::PowerParams {
            rider_weight_kg,
            bike_weight_kg,
            ..power::PowerParams::default()
        },
    )
}

/// 手机记录的骑行结束后，按轨迹估算功率、标准化功率、FTP、IF、TSS，
/// 写入 dynamics_json 与 stat_extend_json。轨迹点不足时返回 None。
pub fn analyze_cycling_workout(
    id: String,
    rider_weight_kg: f64,
    bike_weight_kg: f64,
) -> Result<Option<String>> {
    let Some(track_json) = store::workout_track_json(&id)? else {
        return Ok(None);
    };
    let Some(analysis) = power::analyze_track(&track_json, rider_weight_kg, bike_weight_kg) else {
        return Ok(None);
    };
    store::workout_set_cycling_power(&id, &analysis.dynamics_json, &analysis.stats_json)?;
    Ok(Some(analysis.stats_json))
}

pub fn delete_workout(id: String) -> Result<()> {
    store::delete_workout(&id)
}

pub fn export_workout_gpx(id: String) -> Result<String> {
    store::export_gpx(&id)
}

pub fn export_workout_tcx(id: String) -> Result<String> {
    store::export_tcx(&id)
}

pub fn get_heart_rate_series(day: i64) -> Result<Vec<HrPoint>> {
    store::with_conn(|conn| {
        let start = store::date_of_epoch_day(day);
        let start_ms = chrono::Local
            .from_local_datetime(&start.and_hms_opt(0, 0, 0).unwrap())
            .earliest()
            .map(|d| d.timestamp_millis())
            .unwrap_or(0);
        let mut stmt = conn.prepare(
            "SELECT ts_ms, bpm FROM heart_rate_points WHERE ts_ms >= ?1 AND ts_ms < ?2 ORDER BY ts_ms",
        )?;
        let rows = stmt.query_map(rusqlite::params![start_ms, start_ms + 86_400_000], |r| {
            Ok(HrPoint {
                timestamp_ms: r.get(0)?,
                bpm: r.get(1)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

pub fn get_profile() -> Result<Profile> {
    store::get_profile()
}

pub fn save_profile(profile: Profile) -> Result<()> {
    store::save_profile(profile)
}

pub fn list_devices() -> Result<Vec<DeviceInfo>> {
    store::devices()
}

pub fn list_weights(limit: i64) -> Result<Vec<WeightEntry>> {
    store::weights(limit)
}

pub fn list_equipment() -> Result<Vec<Equipment>> {
    store::equipment_list()
}

pub fn add_equipment(
    name: String,
    sport: String,
    gear_type: String,
    brand: String,
    model: String,
    purchase_ms: i64,
    is_active: bool,
    start_km: f64,
    limit_km: f64,
    note: String,
) -> Result<i64> {
    store::equipment_add(
        &name,
        &sport,
        &gear_type,
        &brand,
        &model,
        purchase_ms,
        is_active,
        start_km,
        limit_km,
        &note,
    )
}

pub fn update_equipment(
    id: i64,
    name: String,
    sport: String,
    gear_type: String,
    brand: String,
    model: String,
    purchase_ms: i64,
    is_active: bool,
    start_km: f64,
    limit_km: f64,
    note: String,
) -> Result<()> {
    store::equipment_update(
        id,
        &name,
        &sport,
        &gear_type,
        &brand,
        &model,
        purchase_ms,
        is_active,
        start_km,
        limit_km,
        &note,
    )
}

pub fn delete_equipment(id: i64) -> Result<()> {
    store::equipment_delete(id)
}

pub fn get_setting(key: String, fallback: String) -> Result<String> {
    store::settings_get(&key, &fallback)
}

pub fn set_setting(key: String, value: String) -> Result<()> {
    store::settings_set(&key, &value)
}

pub fn seed_demo_data() -> Result<()> {
    demo::seed_demo()
}

pub fn clear_demo_data() -> Result<()> {
    demo::clear_demo()
}

pub fn get_app_info() -> Result<AppInfo> {
    store::app_info()
}

pub fn get_metric_detail(metric: String, days: i64) -> Result<MetricDetail> {
    store::metric_detail(&metric, days.clamp(1, 365))
}

pub fn get_personal_records() -> Result<Vec<PersonalRecord>> {
    store::personal_records()
}

pub fn get_sleep_detail(day: i64) -> Result<Option<SleepDetail>> {
    if day != 0 {
        return store::sleep_detail(day);
    }
    match store::latest_sleep_day()? {
        Some(d) => store::sleep_detail(d),
        None => Ok(None),
    }
}

pub fn get_blood_pressure_records(limit: i64) -> Result<Vec<BloodPressureEntry>> {
    store::blood_pressure_records(limit)
}

pub fn get_glucose_records(limit: i64) -> Result<Vec<GlucoseEntry>> {
    store::glucose_records(limit)
}

pub fn get_arrhythmia_records(limit: i64) -> Result<Vec<ArrhythmiaEntry>> {
    store::arrhythmia_records(limit)
}

pub fn get_ecg_records(limit: i64) -> Result<Vec<EcgEntry>> {
    store::ecg_records(limit)
}

pub fn get_watch_identity() -> Result<WatchIdentity> {
    store::watch_identity()
}

pub fn save_watch_identity(identity: WatchIdentity) -> Result<()> {
    store::save_watch_identity(identity)
}

pub fn get_goals() -> Result<Goals> {
    store::goals()
}

pub fn save_goals(goals: Goals) -> Result<()> {
    store::save_goals(goals)
}

/// 从旧版 com.awen.running 的数据库与配置导入全部历史数据和手表认证信息。
pub fn import_legacy_data(db_path: String, config_json: String) -> Result<LegacyImportReport> {
    legacy::import(&db_path, &config_json)
}

pub fn build_legacy_config(
    device_prefs_xml: String,
    global_prefs_xml: String,
    profile_xml: String,
    goals_xml: String,
    heart_xml: String,
    ephemeris_xml: String,
) -> String {
    legacy::read_prefs_config(
        &device_prefs_xml,
        &global_prefs_xml,
        &profile_xml,
        &goals_xml,
        &heart_xml,
        &ephemeris_xml,
    )
}

pub fn legacy_db_available(path: String) -> bool {
    legacy::legacy_db_available(&path)
}

/// 手表直连同步数据入库（JSON 批量事件）。
pub fn ingest_watch_data(events_json: String) -> Result<String> {
    crate::watch::ingest_watch_data(events_json)
}

/// 导出本机健康数据快照（JSON），供可选账号云同步上传。
pub fn export_account_data() -> Result<String> {
    crate::cloud::export_account_data()
}

/// 把云端健康快照合并回本机；返回写入行数。
pub fn import_account_data(payload: String) -> Result<i64> {
    Ok(crate::cloud::import_account_data(payload)? as i64)
}

/// 导出 since_seq 之后的增量变更（只带变化行/删除主键），供云同步上传。
pub fn export_account_delta(since_seq: i64) -> Result<String> {
    crate::cloud::export_account_delta(since_seq)
}

/// 分块导出增量；一次最多处理 max_entries 条变更，剩余留到下一轮。
pub fn export_account_delta_limited(since_seq: i64, max_entries: i64) -> Result<String> {
    crate::cloud::export_account_delta_limited(since_seq, max_entries)
}

/// 本机同步变更日志的最大序号。
pub fn account_delta_max_seq() -> Result<i64> {
    crate::cloud::account_delta_max_seq()
}

/// 增量上传成功后清掉已确认的变更日志。
pub fn clear_account_delta(through_seq: i64) -> Result<i64> {
    Ok(crate::cloud::clear_account_delta(through_seq)? as i64)
}

/// 本机是否已有历史数据，用于决定首次登录是上传还是拉取。
pub fn local_data_count() -> Result<i64> {
    crate::cloud::local_data_count()
}

/// 当前数据库连接累计写入行数，用于判断自动云同步是否真的有必要。
/// 进程重启后计数会归零，调用方只在本进程内比较。
pub fn account_data_change_count() -> Result<i64> {
    crate::cloud::account_data_change_count()
}

/// 手表连接与同步日志，最新在前。
pub fn get_watch_logs(limit: i64) -> Result<Vec<WatchLog>> {
    store::watch_logs(limit)
}
