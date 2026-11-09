use aes_gcm::{aead::Aead, Aes256Gcm, KeyInit, Nonce};
use anyhow::{Context, Result};
use chrono::{Local, TimeZone, Timelike};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::Path;

use crate::api::types::*;
use crate::store;

fn local_day(ts_ms: i64) -> i64 {
    Local
        .timestamp_millis_opt(ts_ms)
        .single()
        .map(|dt| store::epoch_day_of(dt.date_naive()))
        .unwrap_or(ts_ms / 86_400_000)
}

fn sport_label(code: i64) -> &'static str {
    match code {
        1 => "running",
        2 => "walking",
        3 => "cycling",
        4 => "hiking",
        5 => "treadmill",
        6 | 8 => "swimming",
        7 => "indoor_cycling",
        9 => "climbing",
        10 => "trail_running",
        11 => "elliptical",
        12 => "rowing",
        13 => "jump_rope",
        14 | -116 => "strength",
        15 => "stretching",
        16 => "yoga",
        17 => "pilates",
        18 => "dance",
        19 => "spinning",
        20 => "free_training",
        21 => "core",
        22 => "hiit",
        23 => "stepper",
        24 => "walker",
        _ => "workout",
    }
}

#[derive(Default, Clone)]
struct DayAgg {
    steps: i64,
    calories: i64,
    active_calories: i64,
    distance_m: i64,
    active_minutes: i64,
    resting_hr: Option<f64>,
    hrv: Option<f64>,
    stress: Option<f64>,
    spo2: Option<f64>,
    skin_temp: Option<f64>,
    body_temp: Option<f64>,
    respiration: Option<f64>,
    sleep: Option<f64>,
    deep: Option<f64>,
    rem: Option<f64>,
    awake: Option<f64>,
    updated_ms: i64,
}

/// 旧版在线温度接口把两种量混在一起，而且 11-03 之前上传的皮肤温度
/// 在服务端是「皮肤温度 + 2°C」的展示值：
/// - 接口里的 36.x 是核心体温原值，旧版拉取时统一减 2 后存成 34.x；
/// - 接口里的 29.x 是皮肤温度 + 2，旧版减 2 后存成 27.x，恰好是真实腕温；
/// - `isSynced=0` 的行是手表直接上报的皮肤温度，没有偏移。
///
/// 所以只有 `isSynced=1` 且落在 33.5°C 以上的行才是被减坏的核心体温，
/// 需要加回 2°C；33.5°C 以下的低值就是真实腕温，不能再加。
fn corrected_legacy_temperature(value: f64, synced: bool) -> Option<(&'static str, f64)> {
    if !value.is_finite() {
        return None;
    }
    if !synced {
        return (20.0..=42.0)
            .contains(&value)
            .then_some(("skin_temp", value));
    }
    // 核心体温 35.5~42 被减 2 后落在 33.5~40；腕温原值实际在 20~33 左右。
    if (33.5..=40.0).contains(&value) {
        Some(("body_temp", value + 2.0))
    } else if (20.0..33.5).contains(&value) {
        Some(("skin_temp", value))
    } else {
        None
    }
}

/// 把旧版两张温度表还原成 `(指标, 时间戳, 修正值, 旧皮肤温度值)`。
/// 旧值只用于修复时删掉被污染的那条 `skin_temp`。
fn legacy_temperature_points(legacy: &Connection) -> Vec<(&'static str, i64, f64, Option<f64>)> {
    let mut points = Vec::new();
    if let Ok(mut stmt) = legacy
        .prepare("SELECT timestamp, valueCelsiusX100 / 100.0 FROM huawei_body_temperature_records")
    {
        if let Ok(rows) = stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?))) {
            for (ts, value) in rows.flatten() {
                if ts > 0 && (34.0..=42.0).contains(&value) {
                    points.push(("body_temp", ts, value, None));
                }
            }
        }
    }
    if let Ok(mut stmt) = legacy.prepare(
        "SELECT timestamp, valueCelsiusX100 / 100.0, isSynced FROM huawei_temperature_records",
    ) {
        if let Ok(rows) = stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, f64>(1)?,
                r.get::<_, i64>(2).unwrap_or(0),
            ))
        }) {
            for (ts, value, synced) in rows.flatten() {
                if ts <= 0 {
                    continue;
                }
                if synced != 0 {
                    if let Some((metric, corrected)) = corrected_legacy_temperature(value, true) {
                        points.push((metric, ts, corrected, Some(value)));
                    }
                } else if (20.0..=42.0).contains(&value) {
                    points.push(("skin_temp", ts, value, None));
                }
            }
        }
    }
    points
}

fn import_temperature_samples(
    legacy: &Connection,
    days: &mut HashMap<i64, DayAgg>,
    report: &mut LegacyImportReport,
) -> Result<()> {
    let points = legacy_temperature_points(legacy);
    if !points.is_empty() {
        store::with_conn(|conn| {
            let tx = conn.unchecked_transaction()?;
            {
                let mut ins = tx.prepare(
                    "INSERT OR REPLACE INTO metric_points(metric, ts_ms, value, source)
                     VALUES(?1, ?2, ?3, 'legacy')",
                )?;
                for (metric, ts, value, _) in &points {
                    ins.execute(params![metric, ts, value])?;
                    report.samples += 1;
                }
            }
            tx.commit()?;
            Ok(())
        })?;
    }

    let mut acc: HashMap<i64, (f64, i64, f64, i64)> = HashMap::new();
    for (metric, ts, value, _) in points {
        let entry = acc.entry(local_day(ts)).or_insert((0.0, 0, 0.0, 0));
        if metric == "skin_temp" {
            entry.0 += value;
            entry.1 += 1;
        } else {
            entry.2 += value;
            entry.3 += 1;
        }
    }
    for (day, (skin_sum, skin_count, body_sum, body_count)) in acc {
        let agg = days.entry(day).or_default();
        agg.updated_ms = now_ms();
        if skin_count > 0 {
            agg.skin_temp = Some(skin_sum / skin_count as f64);
        }
        if body_count > 0 {
            agg.body_temp = Some(body_sum / body_count as f64);
        }
    }
    Ok(())
}

fn day_bounds(day: i64) -> (i64, i64) {
    let start = Local
        .from_local_datetime(&store::date_of_epoch_day(day).and_hms_opt(0, 0, 0).unwrap())
        .earliest()
        .map(|dt| dt.timestamp_millis())
        .unwrap_or(day * 86_400_000);
    let end = Local
        .from_local_datetime(
            &store::date_of_epoch_day(day + 1)
                .and_hms_opt(0, 0, 0)
                .unwrap(),
        )
        .earliest()
        .map(|dt| dt.timestamp_millis())
        .unwrap_or((day + 1) * 86_400_000);
    (start, end)
}

/// 给已经导入过的用户做一次就地修复：把旧版减 2°C 后混进 `skin_temp`
/// 的核心体温移回 `body_temp`，真实腕温保持原值，并重算当天的日均值。
fn repair_temperature_samples(legacy: &Connection) -> Result<()> {
    let points = legacy_temperature_points(legacy);
    if points.is_empty() {
        return Ok(());
    }
    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        let mut affected_days = HashSet::new();
        {
            let mut del = tx.prepare(
                "DELETE FROM metric_points
                 WHERE metric = 'skin_temp' AND ts_ms = ?1 AND ABS(value - ?2) < 0.001",
            )?;
            let mut ins = tx.prepare(
                "INSERT OR REPLACE INTO metric_points(metric, ts_ms, value, source)
                 VALUES(?1, ?2, ?3, 'legacy')",
            )?;
            for (metric, ts, value, old) in &points {
                if let Some(old) = old {
                    del.execute(params![ts, old])?;
                }
                ins.execute(params![metric, ts, value])?;
                affected_days.insert(local_day(*ts));
            }
        }
        let mut up = tx.prepare(
            "INSERT INTO daily_metrics(date_day, skin_temp_c, body_temp_c, updated_ms)
             VALUES(?1, ?2, ?3, ?4)
             ON CONFLICT(date_day) DO UPDATE SET
                skin_temp_c = excluded.skin_temp_c,
                body_temp_c = excluded.body_temp_c,
                updated_ms = excluded.updated_ms",
        )?;
        for day in affected_days {
            let (start, end) = day_bounds(day);
            let skin: Option<f64> = tx.query_row(
                "SELECT AVG(value) FROM metric_points
                 WHERE metric = 'skin_temp' AND ts_ms >= ?1 AND ts_ms < ?2",
                params![start, end],
                |r| r.get(0),
            )?;
            let body: Option<f64> = tx.query_row(
                "SELECT AVG(value) FROM metric_points
                 WHERE metric = 'body_temp' AND ts_ms >= ?1 AND ts_ms < ?2",
                params![start, end],
                |r| r.get(0),
            )?;
            up.execute(params![day, skin, body, now_ms()])?;
        }
        drop(up);
        tx.commit()?;
        Ok(())
    })
}

pub fn import(db_path: &str, config_json: &str) -> Result<LegacyImportReport> {
    let config: Value = serde_json::from_str(config_json).context("legacy config json")?;
    let legacy = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("open legacy db {db_path}"))?;
    let mut report = LegacyImportReport {
        ok: false,
        already_imported: false,
        message: String::new(),
        days: 0,
        heart_rate_points: 0,
        sleep_sessions: 0,
        workouts: 0,
        weights: 0,
        blood_pressure: 0,
        glucose: 0,
        emotions: 0,
        samples: 0,
        identity: false,
        profile: false,
        goals: false,
    };

    if store::demo_installed() {
        crate::demo::clear_demo()?;
    }
    report.already_imported = store::settings_get("legacy_import_at", "")
        .map(|v| !v.is_empty())
        .unwrap_or(false);

    let mut days: HashMap<i64, DayAgg> = HashMap::new();

    // 1. 每日步数/热量/距离/活动小时
    {
        let mut stmt = legacy.prepare(
            "SELECT dateEpochDay, steps, calories, activeCalories, distanceMeters FROM huawei_daily_fitness",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1).unwrap_or(0),
                r.get::<_, i64>(2).unwrap_or(0),
                r.get::<_, i64>(3).unwrap_or(0),
                r.get::<_, i64>(4).unwrap_or(0),
            ))
        })?;
        for row in rows.flatten() {
            let agg = days.entry(row.0).or_default();
            agg.steps = row.1;
            agg.calories = row.2;
            agg.active_calories = row.3;
            agg.distance_m = row.4;
            agg.updated_ms = now_ms();
            report.days += 1;
        }
    }
    if let Ok(mut stmt) =
        legacy.prepare("SELECT dateEpochDay, durationUserMin FROM huawei_daily_rings")
    {
        if let Ok(rows) = stmt.query_map([], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1).unwrap_or(0)))
        }) {
            for row in rows.flatten() {
                if row.1 > 0 {
                    days.entry(row.0).or_default().active_minutes = row.1;
                }
            }
        }
    }

    // 2. 样本指标（静息心率/HRV/压力/血氧/腕温/体温/呼吸）
    import_avg_samples(
        &legacy,
        "SELECT timestamp, value FROM huawei_resting_hr_records",
        "resting_hr",
        &mut days,
        &mut report,
    )?;
    import_avg_samples(
        &legacy,
        "SELECT timestamp, rmssdMs FROM huawei_hrv_records",
        "hrv",
        &mut days,
        &mut report,
    )?;
    import_avg_samples(
        &legacy,
        "SELECT timestamp, score FROM huawei_stress_records",
        "stress",
        &mut days,
        &mut report,
    )?;
    import_avg_samples(
        &legacy,
        "SELECT timestamp, value FROM huawei_spo2_records",
        "spo2",
        &mut days,
        &mut report,
    )?;
    import_temperature_samples(&legacy, &mut days, &mut report)?;
    import_avg_samples(
        &legacy,
        "SELECT timestamp, avgBreathRate FROM huawei_respiratory_rate_records",
        "respiration",
        &mut days,
        &mut report,
    )?;

    // 3. 心率全量样本
    {
        let mut stmt =
            legacy.prepare("SELECT timestamp, bpm FROM heart_rate_points WHERE bpm > 0")?;
        let mut rows = stmt.query([])?;
        store::with_conn(|conn| {
            let tx = conn.unchecked_transaction()?;
            {
                let mut ins = tx.prepare(
                    "INSERT OR IGNORE INTO heart_rate_points(ts_ms, bpm, synced) VALUES(?1, ?2, 1)",
                )?;
                while let Some(row) = rows.next()? {
                    let ts: i64 = row.get(0)?;
                    let bpm: i64 = row.get(1)?;
                    if ins.execute(params![ts, bpm]).is_ok() {
                        report.heart_rate_points += 1;
                    }
                }
            }
            tx.commit()?;
            Ok(())
        })?;
    }

    // 4. 睡眠：阶段合并成一次睡眠会话
    import_sleep(&legacy, &mut days, &mut report)?;

    // 5. 体重 / 血压 / 血糖 / 心律失常 / 情绪
    import_weights(&legacy, &mut report)?;
    import_hrv(&legacy, &mut report)?;
    import_sleep_hrv(&legacy, &mut days, &mut report)?;
    import_fitness_samples(&legacy)?;
    import_bp(&legacy, &mut report)?;
    import_glucose(&legacy, &mut report)?;
    import_arrhythmia(&legacy, &mut report)?;
    import_emotions(&legacy, &mut report)?;
    import_p2p(&legacy)?;

    // 6. 运动：先迁手表原始记录（带轨迹/心率样本），再迁旧版云端历史汇总。
    import_workouts(&legacy, &mut report)?;
    import_server_workouts(&legacy, &mut report)?;
    import_sessions(&legacy, &mut report)?;
    import_strength(&legacy)?;
    import_training_plan(&legacy)?;
    import_personal_records(&legacy)?;
    if let Some(folder) = Path::new(db_path).parent() {
        import_saved_routes(folder)?;
    }

    // 7. 写回每日聚合
    flush_day_aggregates(&days)?;
    // 旧库里的同一晚可能被手机与手表按不同 source 各写一套，导入会话后
    // 再按区间合并一次，保证原始表和日报表用同一套去重口径。
    store::with_conn(store::dedupe_sleep_session_rows)?;

    // 8. 账号 / 认证 / 资料 / 目标
    let watch = config.get("watch").cloned().unwrap_or(Value::Null);
    let identity = WatchIdentity {
        address: str_of(&watch, "address"),
        name: str_of(&watch, "name"),
        account: str_of(&watch, "account"),
        auth_key: str_of(&watch, "auth_key"),
        fake_android_id: str_of(&watch, "fake_android_id"),
        huawei_address: str_of(&watch, "huawei_address"),
        last_sync_ms: watch.get("last_sync_ms").and_then(|v| v.as_i64()),
        migrated: true,
        ephemeris_url: str_of(&watch, "ephemeris_url"),
    };
    if !identity.address.is_empty() {
        let address = identity.address.clone();
        let name = identity.name.clone();
        let last_sync = identity.last_sync_ms;
        store::save_watch_identity(identity)?;
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO devices(id, name, kind, address, battery, last_sync_ms, connected)
                 VALUES('watch-1', ?1, 'watch', ?2, 0, ?3, 0)
                 ON CONFLICT(id) DO UPDATE SET name = excluded.name, address = excluded.address,
                   last_sync_ms = COALESCE(excluded.last_sync_ms, devices.last_sync_ms)",
                params![name, address, last_sync],
            )?;
            conn.execute("DELETE FROM devices WHERE id = 'legacy-band'", [])?;
            Ok(())
        })?;
        report.identity = true;
    }

    if let Some(profile) = config.get("profile") {
        let gender = str_of(profile, "gender");
        let p = Profile {
            nickname: str_of(profile, "nickname"),
            gender: if gender.eq_ignore_ascii_case("female") {
                "female".into()
            } else {
                "male".into()
            },
            height_cm: profile
                .get("height_cm")
                .and_then(|v| v.as_f64())
                .unwrap_or(170.0),
            weight_kg: profile
                .get("weight_kg")
                .and_then(|v| v.as_f64())
                .unwrap_or(65.0),
            birth_date: str_of(profile, "birth_date"),
            email: String::new(),
        };
        if !p.nickname.is_empty() || p.height_cm > 0.0 {
            store::save_profile(p)?;
            report.profile = true;
        }
    }
    if let Some(goals) = config.get("goals") {
        store::save_goals(Goals {
            steps: goals
                .get("steps")
                .and_then(|v| v.as_i64())
                .unwrap_or(10_000),
            calories: goals
                .get("calories")
                .and_then(|v| v.as_i64())
                .unwrap_or(500),
            active_minutes: goals
                .get("active_minutes")
                .and_then(|v| v.as_i64())
                .unwrap_or(60),
            exercise_minutes: goals
                .get("exercise_minutes")
                .and_then(|v| v.as_i64())
                .unwrap_or(30),
        })?;
        report.goals = true;
    }
    if let Some(heart) = config.get("heart") {
        if let Some(max_hr) = heart.get("max_hr").and_then(|v| v.as_i64()) {
            store::settings_set("max_hr", &max_hr.to_string())?;
        }
        if let Some(resting) = heart.get("resting_hr").and_then(|v| v.as_i64()) {
            store::settings_set("resting_hr_manual", &resting.to_string())?;
        }
    }

    store::settings_set("legacy_import_at", &now_ms().to_string())?;
    store::settings_set("legacy_backfill_v2_done", "1")?;
    store::settings_set("legacy_temp_backfill_done", "1")?;
    store::settings_set("legacy_temp_repair_v1", "1")?;
    store::settings_set("legacy_personal_records_v1", "1")?;
    store::settings_set("legacy_daytime_nap_backfill_v1", "1")?;
    store::settings_set("demo_data", "0")?;
    store::settings_set("device_name", &str_of(&watch, "name"))?;
    report.ok = true;
    report.message = format!(
        "已迁移 {} 天数据、{} 条心率、{} 次睡眠、{} 场运动",
        report.days, report.heart_rate_points, report.sleep_sessions, report.workouts
    );
    Ok(report)
}

fn flush_day_aggregates(days: &HashMap<i64, DayAgg>) -> Result<()> {
    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        {
            let mut ins = tx.prepare(
                "INSERT INTO daily_metrics(
                    date_day, steps, calories, active_calories, distance_m, active_minutes,
                    resting_hr, sleep_minutes, deep_sleep_minutes, rem_sleep_minutes, awake_minutes,
                    hrv_ms, stress, spo2, skin_temp_c, body_temp_c, respiration, updated_ms)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
                 ON CONFLICT(date_day) DO UPDATE SET
                    steps = CASE WHEN excluded.steps > 0 THEN excluded.steps ELSE daily_metrics.steps END,
                    calories = CASE WHEN excluded.calories > 0 THEN excluded.calories ELSE daily_metrics.calories END,
                    active_calories = CASE WHEN excluded.active_calories > 0 THEN excluded.active_calories ELSE daily_metrics.active_calories END,
                    distance_m = CASE WHEN excluded.distance_m > 0 THEN excluded.distance_m ELSE daily_metrics.distance_m END,
                    active_minutes = CASE WHEN excluded.active_minutes > 0 THEN excluded.active_minutes ELSE daily_metrics.active_minutes END,
                    resting_hr = COALESCE(excluded.resting_hr, daily_metrics.resting_hr),
                    sleep_minutes = COALESCE(excluded.sleep_minutes, daily_metrics.sleep_minutes),
                    deep_sleep_minutes = COALESCE(excluded.deep_sleep_minutes, daily_metrics.deep_sleep_minutes),
                    rem_sleep_minutes = COALESCE(excluded.rem_sleep_minutes, daily_metrics.rem_sleep_minutes),
                    awake_minutes = COALESCE(excluded.awake_minutes, daily_metrics.awake_minutes),
                    hrv_ms = COALESCE(excluded.hrv_ms, daily_metrics.hrv_ms),
                    stress = COALESCE(excluded.stress, daily_metrics.stress),
                    spo2 = COALESCE(excluded.spo2, daily_metrics.spo2),
                    skin_temp_c = COALESCE(excluded.skin_temp_c, daily_metrics.skin_temp_c),
                    body_temp_c = COALESCE(excluded.body_temp_c, daily_metrics.body_temp_c),
                    respiration = COALESCE(excluded.respiration, daily_metrics.respiration),
                    updated_ms = excluded.updated_ms",
            )?;
            for (day, d) in days {
                if *day <= 0 {
                    continue;
                }
                ins.execute(params![
                    day,
                    d.steps,
                    d.calories,
                    d.active_calories,
                    d.distance_m,
                    d.active_minutes,
                    d.resting_hr,
                    d.sleep,
                    d.deep,
                    d.rem,
                    d.awake,
                    d.hrv,
                    d.stress,
                    d.spo2,
                    d.skin_temp,
                    d.body_temp,
                    d.respiration,
                    d.updated_ms
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    })
}

fn backfill_temperature_samples(legacy: &Connection) -> Result<()> {
    let mut days: HashMap<i64, DayAgg> = HashMap::new();
    let mut report = LegacyImportReport {
        ok: false,
        already_imported: true,
        message: String::new(),
        days: 0,
        heart_rate_points: 0,
        sleep_sessions: 0,
        workouts: 0,
        weights: 0,
        blood_pressure: 0,
        glucose: 0,
        emotions: 0,
        samples: 0,
        identity: false,
        profile: false,
        goals: false,
    };
    import_temperature_samples(legacy, &mut days, &mut report)?;
    flush_day_aggregates(&days)
}

fn now_ms() -> i64 {
    Local::now().timestamp_millis()
}

fn str_of(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

fn import_avg_samples(
    legacy: &Connection,
    sql: &str,
    metric: &str,
    days: &mut HashMap<i64, DayAgg>,
    report: &mut LegacyImportReport,
) -> Result<()> {
    let mut stmt = match legacy.prepare(sql) {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let mut rows = stmt.query([])?;
    let mut acc: HashMap<i64, (f64, i64)> = HashMap::new();
    let mut points: Vec<(i64, f64)> = Vec::new();
    while let Some(row) = rows.next()? {
        let ts: i64 = match row.get(0) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let value: f64 = match row.get(1) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if !value.is_finite() || value <= 0.0 {
            continue;
        }
        if metric == "skin_temp" && !(20.0..=42.0).contains(&value) {
            continue;
        }
        if metric == "body_temp" && !(34.0..=42.0).contains(&value) {
            continue;
        }
        if metric == "stress" && value > 100.0 {
            continue;
        }
        points.push((ts, value));
        let entry = acc.entry(local_day(ts)).or_insert((0.0, 0));
        entry.0 += value;
        entry.1 += 1;
    }
    if !points.is_empty() {
        store::with_conn(|conn| {
            let tx = conn.unchecked_transaction()?;
            {
                let mut ins = tx.prepare(
                    "INSERT OR REPLACE INTO metric_points(metric, ts_ms, value, source) VALUES(?1, ?2, ?3, 'watch')",
                )?;
                for (ts, value) in &points {
                    ins.execute(params![metric, ts, value])?;
                    report.samples += 1;
                }
            }
            tx.commit()?;
            Ok(())
        })?;
    }
    for (day, (sum, count)) in acc {
        let avg = sum / count as f64;
        let agg = days.entry(day).or_default();
        agg.updated_ms = now_ms();
        match metric {
            "resting_hr" => agg.resting_hr = Some(avg),
            "hrv" => agg.hrv = Some(avg),
            "stress" => agg.stress = Some(avg),
            "spo2" => agg.spo2 = Some(avg),
            "skin_temp" => agg.skin_temp = Some(avg),
            "body_temp" => agg.body_temp = Some(avg),
            "respiration" => agg.respiration = Some(avg),
            _ => {}
        }
    }
    Ok(())
}

#[derive(Default)]
struct Session {
    start: i64,
    end: i64,
    deep: i64,
    light: i64,
    rem: i64,
    awake: i64,
}

fn union_minutes(rows: &[(i64, i64, String)], keep: impl Fn(&str) -> bool) -> i64 {
    let mut spans: Vec<(i64, i64)> = rows
        .iter()
        .filter(|(_, _, stage)| keep(stage))
        .map(|(a, b, _)| (*a, *b))
        .collect();
    if spans.is_empty() {
        return 0;
    }
    spans.sort_unstable();
    let (mut a, mut b) = spans[0];
    let mut total = 0;
    for (x, y) in spans.into_iter().skip(1) {
        if x <= b {
            b = b.max(y);
        } else {
            total += b - a;
            a = x;
            b = y;
        }
    }
    total += b - a;
    total / 60_000
}

fn push_sleep_session(
    out: &mut Vec<(Session, Vec<(i64, i64, String)>)>,
    mut rows: Vec<(i64, i64, String)>,
) {
    rows.sort_by_key(|r| r.0);
    // TruSleep 会额外上报整段 stage='sleep' 的窗口；白天零星分期本身很稀疏，
    // 若整簇一起算会被密度过滤整条丢掉（午睡就是这么丢的）。有锚点窗口时按
    // 窗口切开，锚点内的分期照常统计。
    let mut anchors: Vec<(i64, i64)> = rows
        .iter()
        .filter(|r| r.2 == "sleep")
        .map(|r| (r.0, r.1))
        .collect();
    if !anchors.is_empty() {
        anchors.sort_unstable();
        for (a, b) in merge_sleep_anchors(&anchors) {
            let window: Vec<(i64, i64, String)> = rows
                .iter()
                .filter(|(x, y, stage)| {
                    (stage == "sleep" && *x >= a && *y <= b)
                        || (stage != "sleep" && *x < b && *y > a)
                })
                .map(|(x, y, stage)| ((*x).max(a), (*y).min(b), stage.clone()))
                .collect();
            push_sleep_window(out, window);
        }
        return;
    }
    push_sleep_window(out, rows);
}

/// 旧版 40→41 迁移把手表侧 700013（source 11）和零散片段（source 13）
/// 的阶段码旋转成正确含义，但漏掉了云端历史（source 0）。云端行仍是
/// 旧编码：deep 实际是 light、light 实际是 rem、rem 实际是 deep。
fn corrected_sleep_stage<'a>(stage: &'a str, source: i64) -> &'a str {
    if source != 0 {
        return stage;
    }
    match stage {
        "deep" => "light",
        "light" => "rem",
        "rem" => "deep",
        _ => stage,
    }
}

fn merge_sleep_anchors(anchors: &[(i64, i64)]) -> Vec<(i64, i64)> {
    let mut out: Vec<(i64, i64)> = Vec::new();
    for &(a, b) in anchors {
        if let Some(last) = out.last_mut() {
            if a - last.1 <= 45 * 60_000 {
                last.1 = last.1.max(b);
                continue;
            }
        }
        out.push((a, b));
    }
    out
}

fn push_sleep_window(
    out: &mut Vec<(Session, Vec<(i64, i64, String)>)>,
    rows: Vec<(i64, i64, String)>,
) {
    let sleeping: Vec<&(i64, i64, String)> = rows.iter().filter(|r| r.2 != "awake").collect();
    if sleeping.is_empty() {
        return;
    }
    let start = sleeping.iter().map(|r| r.0).min().unwrap_or(rows[0].0);
    let end = sleeping.iter().map(|r| r.1).max().unwrap_or(rows[0].1);
    let deep = union_minutes(&rows, |stage| stage == "deep");
    let rem = union_minutes(&rows, |stage| stage == "rem");
    let total = union_minutes(&rows, |stage| stage != "awake");
    let wall_min = (end - start) / 60_000;
    // 午睡可以很短；但不能把白天零星 1–3 分钟的打点当成睡眠。
    // 长跨度、低密度的片段（例如 6 小时里只睡着 1 小时）同样丢弃。
    if total < 5 || (wall_min >= 90 && total * 100 < wall_min * 35) {
        return;
    }
    let awake = rows
        .iter()
        .filter(|r| r.2 == "awake")
        .map(|r| (r.1 - r.0) / 60_000)
        .sum();
    out.push((
        Session {
            start,
            end,
            deep,
            light: (total - deep - rem).max(0),
            rem,
            awake,
        },
        rows,
    ));
}

fn source13_nap_candidates(
    rows: Vec<(i64, i64, String)>,
) -> Vec<(Session, Vec<(i64, i64, String)>)> {
    // source 13 是手表的高频分期流：夜间有可信睡眠锚点时只用来细化分期，
    // 但白天午睡经常只有它自己，没有 source 10/11 的 sleep 窗口。
    // 这里只收“短、密、发生在午后”的簇，避免把整天零星打点当成睡眠。
    // 白天分期之间经常有 10~20 分钟的空档；用 10 分钟聚类才不会把一次
    // 小睡和前后零星打点串成假的长片段。
    const NAP_GAP_MS: i64 = 10 * 60_000;
    let mut clusters: Vec<Vec<(i64, i64, String)>> = Vec::new();
    let mut cluster: Vec<(i64, i64, String)> = Vec::new();
    let mut cluster_end = i64::MIN;
    for row in rows {
        if !cluster.is_empty() && row.0 - cluster_end > NAP_GAP_MS {
            clusters.push(std::mem::take(&mut cluster));
            cluster_end = i64::MIN;
        }
        cluster_end = cluster_end.max(row.1);
        cluster.push(row);
    }
    if !cluster.is_empty() {
        clusters.push(cluster);
    }

    let mut out = Vec::new();
    for cluster in clusters {
        let sleeping: Vec<&(i64, i64, String)> =
            cluster.iter().filter(|r| r.2 != "awake").collect();
        if sleeping.is_empty() {
            continue;
        }
        let start = sleeping.iter().map(|r| r.0).min().unwrap_or(0);
        let end = sleeping.iter().map(|r| r.1).max().unwrap_or(0);
        let Some(local_start) = Local.timestamp_millis_opt(start).single() else {
            continue;
        };
        let wall_min = (end - start) / 60_000;
        let total = union_minutes(&cluster, |stage| stage != "awake");
        if !(11..18).contains(&local_start.hour())
            || !(20..=90).contains(&total)
            || wall_min > 120
            || total * 100 < wall_min * 50
        {
            continue;
        }
        push_sleep_window(&mut out, cluster);
    }
    out
}

fn overlap_ms(a_start: i64, a_end: i64, b_start: i64, b_end: i64) -> i64 {
    (a_end.min(b_end) - a_start.max(b_start)).max(0)
}

/// 给已经完成迁移的老用户补一次白天小睡。
///
/// 早期 `import_sleep` 用 45 分钟聚类，会把白天稀疏分期和午睡串成低密度
/// 长片段后丢弃。这里只从旧库 source 13 里补 source 10/11 没有覆盖的小睡，
/// 不删除、不重写现有睡眠会话。插入阶段行是为了让手表下一次
/// `rebuild_sleep_sessions` 时仍能从分期重建出这场小睡。
fn backfill_daytime_naps(legacy: &Connection) -> Result<usize> {
    let mut rows: Vec<(i64, i64, String)> = Vec::new();
    if let Ok(mut stmt) = legacy.prepare(
        "SELECT startTimeMillis, endTimeMillis, stage
         FROM huawei_sleep_records
         WHERE source = 13 AND startTimeMillis > 0 AND endTimeMillis > startTimeMillis
         ORDER BY startTimeMillis",
    ) {
        if let Ok(iter) = stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
            ))
        }) {
            rows.extend(iter.flatten());
        }
    }
    let candidates = source13_nap_candidates(rows);
    if candidates.is_empty() {
        return Ok(0);
    }

    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        let existing: Vec<(i64, i64)> = {
            let mut stmt = tx.prepare("SELECT start_ms, end_ms FROM sleep_sessions")?;
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        let mut inserted: Vec<(i64, i64)> = Vec::new();
        let mut added = 0usize;
        {
            let mut ins_session = tx.prepare(
                "INSERT OR IGNORE INTO sleep_sessions(
                    start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, 'watch')",
            )?;
            let mut ins_stage = tx.prepare(
                "INSERT OR IGNORE INTO sleep_stages(start_ms, end_ms, stage, source)
                 VALUES(?1, ?2, ?3, 'watch')",
            )?;
            for (session, stages) in candidates {
                let overlaps_existing =
                    existing.iter().chain(inserted.iter()).any(|(start, end)| {
                        overlap_ms(session.start, session.end, *start, *end) > 5 * 60_000
                    });
                if overlaps_existing {
                    continue;
                }
                if ins_session.execute(params![
                    session.start,
                    session.end,
                    session.deep as f64,
                    session.light as f64,
                    session.rem as f64,
                    session.awake as f64,
                ])? == 0
                {
                    continue;
                }
                for (start, end, stage) in &stages {
                    ins_stage.execute(params![start, end, stage])?;
                }
                inserted.push((session.start, session.end));
                added += 1;
            }
        }
        tx.commit()?;
        if added > 0 {
            store::recompute_sleep_daily_metrics(conn)?;
        }
        Ok(added)
    })
}

fn legacy_sleep_max_end(legacy: &Connection) -> Option<i64> {
    // 只能按真正会被重新写入的分期记录算边界。旧库的 `huawei_sleep_bed_records`
    // 可能比分期新好几天（只有入睡/醒来窗口，没有分期），把它算进来会删掉
    // 旧库之后手表新同步的睡眠会话，却没有任何数据可以重建它们。
    let mut stmt = legacy
        .prepare("SELECT MAX(endTimeMillis) FROM huawei_sleep_records")
        .ok()?;
    stmt.query_row([], |r| r.get::<_, Option<i64>>(0)).ok()?
}

fn legacy_bed_max_end(legacy: &Connection) -> Option<i64> {
    let mut stmt = legacy
        .prepare("SELECT MAX(wakeupMillis) FROM huawei_sleep_bed_records")
        .ok()?;
    stmt.query_row([], |r| r.get::<_, Option<i64>>(0)).ok()?
}

fn import_sleep(
    legacy: &Connection,
    days: &mut HashMap<i64, DayAgg>,
    report: &mut LegacyImportReport,
) -> Result<()> {
    // 只清掉旧库快照覆盖到的睡眠，旧库之后手表新同步的睡眠必须保留。
    // 早期这里无条件清空三张表，旧库 mtime 变化触发重导时会把最近几天的
    // 手表睡眠一起删掉。
    let max_end = legacy_sleep_max_end(legacy);
    if let Some(max_end) = max_end {
        store::with_conn(|conn| {
            conn.execute(
                "DELETE FROM sleep_sessions WHERE end_ms <= ?1",
                params![max_end],
            )?;
            conn.execute(
                "DELETE FROM sleep_stages WHERE end_ms <= ?1",
                params![max_end],
            )?;
            Ok(())
        })?;
    }
    if let Some(bed_max_end) = legacy_bed_max_end(legacy) {
        store::with_conn(|conn| {
            conn.execute(
                "DELETE FROM sleep_bed WHERE wake_ms <= ?1",
                params![bed_max_end],
            )?;
            Ok(())
        })?;
    }
    let mut rows: Vec<(i64, i64, String, i64)> = Vec::new();
    if let Ok(mut stmt) = legacy.prepare(
        "SELECT startTimeMillis, endTimeMillis, stage, source FROM huawei_sleep_records ORDER BY startTimeMillis",
    ) {
        if let Ok(iter) = stmt.query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get::<_, String>(2)?, r.get::<_, i64>(3).unwrap_or(0)))
        }) {
            rows.extend(iter.flatten());
        }
    }
    // 夜间睡眠常被手机与手表重复上报，白天小睡则会产生大量碎片（source 13）。
    // 按来源把间隔不超过 45 分钟的片段聚成一次睡眠，再按时间重叠度跨来源去重。
    let mut by_source: std::collections::BTreeMap<i64, Vec<(i64, i64, String)>> =
        std::collections::BTreeMap::new();
    let mut source13_rows = Vec::new();
    for (start, end, stage, source) in rows {
        if start <= 0 || end <= start {
            continue;
        }
        let stage = corrected_sleep_stage(&stage, source).to_string();
        if source == 13 {
            source13_rows.push((start, end, stage));
            continue;
        }
        by_source
            .entry(source)
            .or_default()
            .push((start, end, stage));
    }
    let mut candidates: Vec<(Session, Vec<(i64, i64, String)>)> = Vec::new();
    for intervals in by_source.into_values() {
        let mut cluster: Vec<(i64, i64, String)> = Vec::new();
        let mut cluster_end = i64::MIN;
        for (a, b, stage) in intervals {
            if !cluster.is_empty() && a - cluster_end > 45 * 60_000 {
                push_sleep_session(&mut candidates, std::mem::take(&mut cluster));
                cluster_end = i64::MIN;
            }
            cluster_end = cluster_end.max(b);
            cluster.push((a, b, stage));
        }
        if !cluster.is_empty() {
            push_sleep_session(&mut candidates, cluster);
        }
    }
    candidates.retain(|(s, _)| s.deep + s.light + s.rem > 0);
    // 同一晚有粗细两套记录时，优先保留带深睡/REM 分期的版本，其次保留时长更长的。
    candidates.sort_by_key(|(s, _)| ((s.deep + s.rem == 0) as i32, -(s.deep + s.light + s.rem)));
    let mut kept: Vec<(Session, Vec<(i64, i64, String)>)> = Vec::new();
    for candidate in candidates {
        let duplicate = kept.iter().any(|(existing, _)| {
            let overlap =
                (candidate.0.end.min(existing.end) - candidate.0.start.max(existing.start)).max(0);
            let shorter = (candidate.0.end - candidate.0.start)
                .min(existing.end - existing.start)
                .max(1);
            overlap * 2 > shorter
        });
        if !duplicate {
            kept.push(candidate);
        }
    }
    // source 13 只补可信来源没有覆盖的午后小睡，不参与主睡眠去重排序。
    let mut recovered_naps = source13_nap_candidates(source13_rows);
    recovered_naps.retain(|(candidate, _)| {
        !kept.iter().any(|(existing, _)| {
            let overlap =
                (candidate.end.min(existing.end) - candidate.start.max(existing.start)).max(0);
            let shorter = (candidate.end - candidate.start)
                .min(existing.end - existing.start)
                .max(1);
            overlap * 2 > shorter
        })
    });
    kept.extend(recovered_naps);
    kept.sort_by_key(|(s, _)| s.start);
    let mut by_day: std::collections::BTreeMap<i64, (f64, f64, f64, f64)> =
        std::collections::BTreeMap::new();
    for (s, stage_rows) in kept {
        store::with_conn(|conn| {
            conn.execute(
                "INSERT OR REPLACE INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, 'watch')",
                params![s.start, s.end, s.deep as f64, s.light as f64, s.rem as f64, s.awake as f64],
            )?;
            for (a, b, stage) in &stage_rows {
                conn.execute(
                    "INSERT OR REPLACE INTO sleep_stages(start_ms, end_ms, stage, source) VALUES(?1, ?2, ?3, 'watch')",
                    params![a, b, stage],
                )?;
            }
            Ok(())
        })?;
        report.sleep_sessions += 1;
        let entry = by_day.entry(local_day(s.end)).or_default();
        entry.0 += s.deep as f64;
        entry.1 += s.light as f64;
        entry.2 += s.rem as f64;
        entry.3 += s.awake as f64;
    }
    // 同一天的夜间睡眠和午睡要相加，不能只保留最长的一场。
    for (sleep_day, (deep, light, rem, awake)) in by_day {
        let agg = days.entry(sleep_day).or_default();
        agg.updated_ms = now_ms();
        agg.sleep = Some(deep + light + rem);
        agg.deep = Some(deep);
        agg.rem = Some(rem);
        agg.awake = Some(awake);
    }
    // 在床/入睡时间
    if let Ok(mut stmt) = legacy.prepare(
        "SELECT bedMillis, fallAsleepMillis, wakeupMillis FROM huawei_sleep_bed_records
         WHERE wakeupMillis > 0 AND fallAsleepMillis > 0",
    ) {
        if let Ok(iter) = stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
            ))
        }) {
            for (bed, asleep, wake) in iter.flatten() {
                store::with_conn(|conn| {
                    conn.execute(
                        "INSERT OR REPLACE INTO sleep_bed(session_start_ms, bed_ms, fall_asleep_ms, wake_ms)
                         VALUES(?1, ?2, ?3, ?4)",
                        params![asleep, bed, asleep, wake],
                    )?;
                    Ok(())
                })?;
            }
        }
    }
    Ok(())
}

fn import_weights(legacy: &Connection, report: &mut LegacyImportReport) -> Result<()> {
    let mut stmt = match legacy.prepare(
        "SELECT id, timestamp, weightKg, heightCm, bodyFatPercent, musclePercent, waterPercent,
                fatMassKg, muscleMassKg, waterMassKg, proteinPercent, bonePercent, deviceName,
                proteinMassKg, boneMassKg, skeletalMusclePercent, skeletalMuscleMassKg,
                subcutaneousFatPercent, subcutaneousFatMassKg, resistanceOhm, bodyCompositionModel
         FROM weight_records",
    ) {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let rows = stmt.query_map([], |r| {
        let weight: f64 = r.get(2)?;
        let height: Option<f64> = r.get(3)?;
        let bmi = height
            .filter(|h| *h > 0.0)
            .map(|h| (weight / (h / 100.0).powi(2) * 10.0).round() / 10.0);
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            weight,
            height,
            bmi,
            r.get::<_, Option<f64>>(4)?,
            r.get::<_, Option<f64>>(5)?,
            r.get::<_, Option<f64>>(6)?,
            r.get::<_, Option<f64>>(7)?,
            r.get::<_, Option<f64>>(8)?,
            r.get::<_, Option<f64>>(9)?,
            r.get::<_, Option<f64>>(10)?,
            r.get::<_, Option<f64>>(11)?,
            r.get::<_, Option<String>>(12)?,
            r.get::<_, Option<f64>>(13)?,
            r.get::<_, Option<f64>>(14)?,
            r.get::<_, Option<f64>>(15)?,
            r.get::<_, Option<f64>>(16)?,
            r.get::<_, Option<f64>>(17)?,
            r.get::<_, Option<f64>>(18)?,
            r.get::<_, Option<f64>>(19)?,
            r.get::<_, Option<String>>(20)?,
        ))
    })?;
    let deleted = store::health_tombstone_ids("weight")?;
    for row in rows.flatten() {
        if deleted.contains(&row.0) {
            continue;
        }
        store::with_conn(|conn| {
            conn.execute(
                "INSERT OR REPLACE INTO weight_records(
                    id, timestamp_ms, weight_kg, body_fat_percent, muscle_percent, water_percent, source,
                    height_cm, bmi, fat_mass_kg, muscle_mass_kg, water_mass_kg, protein_percent, bone_percent,
                    device_name, protein_mass_kg, bone_mass_kg, skeletal_muscle_percent,
                    skeletal_muscle_mass_kg, subcutaneous_fat_percent, subcutaneous_fat_mass_kg,
                    resistance_ohm, body_composition_model)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, 'scale', ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
                        ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)",
                params![
                    row.0, row.1, row.2, row.5, row.6, row.7, row.3, row.4, row.8, row.9,
                    row.10, row.11, row.12, row.13, row.14, row.15, row.16, row.17, row.18,
                    row.19, row.20, row.21
                ],
            )?;
            Ok(())
        })?;
        report.weights += 1;
    }
    store::with_conn(dedupe_weights)?;
    Ok(())
}

/// 旧库只有逐条 huawei_hrv_records；新版 hrv_records 保存逐次测量明细。
/// 日均值仍由 import_avg_samples 写进 metric_points/daily_metrics，这里补明细表，
/// 避免「趋势图有历史、记录表只有最近几天」。
fn import_hrv(legacy: &Connection, report: &mut LegacyImportReport) -> Result<()> {
    let mut stmt = match legacy.prepare("SELECT timestamp, rmssdMs FROM huawei_hrv_records") {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let mut rows = stmt.query([])?;
    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        {
            let mut exists =
                tx.prepare("SELECT 1 FROM hrv_records WHERE ABS(at_sec - ?1) <= 60 LIMIT 1")?;
            let mut ins = tx.prepare(
                "INSERT INTO hrv_records(date_day, at_sec, hrv_ms, quality, source)
                 VALUES(?1, ?2, ?3, 'good', 'legacy')",
            )?;
            while let Some(row) = rows.next()? {
                let ts: i64 = match row.get(0) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let value: f64 = match row.get(1) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                if ts <= 0 || !(1.0..=300.0).contains(&value) {
                    continue;
                }
                let at_sec = ts / 1000;
                if exists.exists(params![at_sec])? {
                    continue;
                }
                ins.execute(params![local_day(ts), at_sec, value])?;
                report.samples += 1;
            }
        }
        tx.commit()?;
        Ok(())
    })
}

/// 睡眠详情里的官方夜间 HRV（700013）。avgHrv 是当晚 RMSSD，
/// 比白天零散采样更适合作为当日 HRV 展示；基线字段一并保留，后续计划/恢复度可用。
fn import_sleep_hrv(
    legacy: &Connection,
    days: &mut HashMap<i64, DayAgg>,
    report: &mut LegacyImportReport,
) -> Result<()> {
    let mut stmt = match legacy.prepare(
        "SELECT dateEpochDay, sleepStartMillis, avgHrv, minHrvBaseline,
                maxHrvBaseline, hrvDayToBaseline
         FROM huawei_sleep_hrv_records",
    ) {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0).unwrap_or(0),
            r.get::<_, i64>(1).unwrap_or(0),
            r.get::<_, i64>(2).unwrap_or(-1),
            r.get::<_, i64>(3).unwrap_or(-1),
            r.get::<_, i64>(4).unwrap_or(-1),
            r.get::<_, i64>(5).unwrap_or(-1),
        ))
    })?;
    let mut records = Vec::new();
    for row in rows.flatten() {
        let (day, start_ms, avg, min_base, max_base, day_to_base) = row;
        if avg <= 0 {
            continue;
        }
        let day = if day > 0 {
            day
        } else if start_ms > 0 {
            local_day(start_ms)
        } else {
            continue;
        };
        records.push((day, start_ms, avg, min_base, max_base, day_to_base));
    }
    if records.is_empty() {
        return Ok(());
    }
    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        {
            let mut upsert = tx.prepare(
                "INSERT INTO sleep_hrv_records(
                    date_day, sleep_start_ms, avg_hrv, min_baseline, max_baseline,
                    day_to_baseline, updated_ms)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(date_day) DO UPDATE SET
                    sleep_start_ms = excluded.sleep_start_ms,
                    avg_hrv = excluded.avg_hrv,
                    min_baseline = excluded.min_baseline,
                    max_baseline = excluded.max_baseline,
                    day_to_baseline = excluded.day_to_baseline,
                    updated_ms = excluded.updated_ms",
            )?;
            let mut point = tx.prepare(
                "INSERT OR REPLACE INTO metric_points(metric, ts_ms, value, source)
                 VALUES('hrv', ?1, ?2, 'watch')",
            )?;
            for &(day, start_ms, avg, min_base, max_base, day_to_base) in &records {
                upsert.execute(params![
                    day,
                    start_ms,
                    avg as f64,
                    min_base as f64,
                    max_base as f64,
                    day_to_base as f64,
                    now_ms()
                ])?;
                if start_ms > 0 {
                    point.execute(params![start_ms, avg as f64])?;
                }
                report.samples += 1;
            }
        }
        tx.commit()?;
        Ok(())
    })?;
    for (day, _, avg, _, _, _) in records {
        days.entry(day).or_default().hrv = Some(avg as f64);
    }
    Ok(())
}

/// 旧版逐分钟运动样本。新版只靠它补「哪几个小时动过」和精确小时步数，
/// 已有手表同步的同一秒样本不覆盖。
fn import_fitness_samples(legacy: &Connection) -> Result<()> {
    let mut stmt = match legacy.prepare(
        "SELECT timestamp, steps, calories, distanceMeters
         FROM huawei_fitness_samples WHERE timestamp > 0",
    ) {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let mut rows = stmt.query([])?;
    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        {
            let mut ins = tx.prepare(
                "INSERT OR IGNORE INTO step_samples(ts, steps, calories, distance)
                 VALUES(?1, ?2, ?3, ?4)",
            )?;
            while let Some(row) = rows.next()? {
                let ts: i64 = row.get(0)?;
                let steps: i64 = row.get(1).unwrap_or(0);
                let calories: i64 = row.get(2).unwrap_or(0);
                let distance: i64 = row.get(3).unwrap_or(0);
                if steps <= 0 && calories <= 0 && distance <= 0 {
                    continue;
                }
                ins.execute(params![ts, steps.max(0), calories.max(0), distance.max(0)])?;
            }
        }
        tx.commit()?;
        Ok(())
    })
}

/// 旧版「已保存路线」不是 Room 表，而是 files/saved_routes.json。
/// 旧数据默认是 GCJ-02；明确标成 WGS84 的（手表来源）导入前先转换，
/// 否则在高德底图上会有 300–800 米偏移。
fn import_saved_routes(folder: &Path) -> Result<()> {
    let path = folder.join("saved_routes.json");
    let Ok(raw) = std::fs::read_to_string(path) else {
        return Ok(());
    };
    if raw.trim().is_empty() {
        return Ok(());
    }
    import_saved_routes_json(&raw)
}

fn import_saved_routes_json(raw: &str) -> Result<()> {
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return Ok(());
    };
    let Some(items) = value.as_array() else {
        return Ok(());
    };
    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        {
            let mut insert = tx.prepare(
                "INSERT OR IGNORE INTO saved_routes(
                    id, name, points_json, distance_m, created_ms)
                 VALUES(?1, ?2, ?3, ?4, ?5)",
            )?;
            for item in items {
                let Some(obj) = item.as_object() else {
                    continue;
                };
                let id = obj.get("id").and_then(|v| v.as_str()).unwrap_or("").trim();
                let name = obj
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .trim();
                if id.is_empty() || name.is_empty() {
                    continue;
                }
                let deleted: i64 = tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM saved_route_tombstones WHERE id = ?1)",
                    params![id],
                    |r| r.get(0),
                )?;
                if deleted != 0 {
                    continue;
                }
                let coordinate_system = obj
                    .get("coordinateSystem")
                    .and_then(|v| v.as_str())
                    .unwrap_or("GCJ02");
                let mut points: Vec<[f64; 2]> = Vec::new();
                if let Some(raw_points) = obj.get("points").and_then(|v| v.as_array()) {
                    for point in raw_points {
                        let Some(lat) = point.get("latitude").and_then(|v| v.as_f64()) else {
                            continue;
                        };
                        let Some(lon) = point.get("longitude").and_then(|v| v.as_f64()) else {
                            continue;
                        };
                        if !(-85.0..=85.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) {
                            continue;
                        }
                        if lat.abs() < 0.0001 && lon.abs() < 0.0001 {
                            continue;
                        }
                        let (lat, lon) = if coordinate_system.eq_ignore_ascii_case("WGS84") {
                            let (lon, lat) = wgs84_to_gcj02(lon, lat);
                            (lat, lon)
                        } else {
                            (lat, lon)
                        };
                        points.push([lat, lon]);
                    }
                }
                if points.len() < 2 {
                    continue;
                }
                let mut distance = obj
                    .get("distanceMeters")
                    .and_then(|v| v.as_f64())
                    .unwrap_or(0.0);
                if !distance.is_finite() || distance <= 0.0 {
                    distance = points
                        .windows(2)
                        .map(|w| haversine_m(w[0][0], w[0][1], w[1][0], w[1][1]))
                        .sum();
                }
                let created_ms = obj
                    .get("createdAtMillis")
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0);
                insert.execute(params![
                    id,
                    name,
                    serde_json::to_string(&points).unwrap_or_else(|_| "[]".into()),
                    distance,
                    created_ms
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    })
}

fn wgs84_to_gcj02(lon: f64, lat: f64) -> (f64, f64) {
    if out_of_china(lon, lat) {
        return (lon, lat);
    }
    let dlat = transform_lat(lon - 105.0, lat - 35.0);
    let dlon = transform_lon(lon - 105.0, lat - 35.0);
    let rad_lat = lat / 180.0 * std::f64::consts::PI;
    let mut magic = rad_lat.sin();
    magic = 1.0 - 0.006_693_421_622_965_943 * magic * magic;
    let sqrt_magic = magic.sqrt();
    let dlat = (dlat * 180.0)
        / ((6_378_245.0 * (1.0 - 0.006_693_421_622_965_943)) / (magic * sqrt_magic)
            * std::f64::consts::PI);
    let dlon = (dlon * 180.0) / (6_378_245.0 / sqrt_magic * rad_lat.cos() * std::f64::consts::PI);
    (lon + dlon, lat + dlat)
}

fn out_of_china(lon: f64, lat: f64) -> bool {
    !(72.004..=137.8347).contains(&lon) || !(0.8293..=55.8271).contains(&lat)
}

fn transform_lat(x: f64, y: f64) -> f64 {
    let mut ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * x.abs().sqrt();
    ret += (20.0 * (6.0 * x * std::f64::consts::PI).sin()
        + 20.0 * (2.0 * x * std::f64::consts::PI).sin())
        * 2.0
        / 3.0;
    ret += (20.0 * (y * std::f64::consts::PI).sin()
        + 40.0 * (y / 3.0 * std::f64::consts::PI).sin())
        * 2.0
        / 3.0;
    ret += (160.0 * (y / 12.0 * std::f64::consts::PI).sin()
        + 320.0 * (y * std::f64::consts::PI / 30.0).sin())
        * 2.0
        / 3.0;
    ret
}

fn transform_lon(x: f64, y: f64) -> f64 {
    let mut ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * x.abs().sqrt();
    ret += (20.0 * (6.0 * x * std::f64::consts::PI).sin()
        + 20.0 * (2.0 * x * std::f64::consts::PI).sin())
        * 2.0
        / 3.0;
    ret += (20.0 * (x * std::f64::consts::PI).sin()
        + 40.0 * (x / 3.0 * std::f64::consts::PI).sin())
        * 2.0
        / 3.0;
    ret += (150.0 * (x / 12.0 * std::f64::consts::PI).sin()
        + 300.0 * (x / 30.0 * std::f64::consts::PI).sin())
        * 2.0
        / 3.0;
    ret
}

// 下面两组 SQL 片段全部是本文件里的常量，不接受任何外部输入。
const BP_SAME: &str = "ABS(k.timestamp_ms - g.timestamp_ms) <= 1000 AND k.systolic = g.systolic AND k.diastolic = g.diastolic AND ifnull(k.pulse, -1) = ifnull(g.pulse, -1)";
const BP_KEEP: &str = "ifnull(k.pulse, -1) DESC, k.timestamp_ms ASC";
const GLUCOSE_SAME: &str = "(k.timestamp_ms + 30000) / 60000 = (g.timestamp_ms + 30000) / 60000 AND abs(k.value - g.value) < 0.001";
const GLUCOSE_KEEP: &str = "k.timestamp_ms ASC";

#[derive(Clone)]
struct StoredWeight {
    id: String,
    timestamp_ms: i64,
    weight_kg: f64,
    body_fat_percent: Option<f64>,
    muscle_percent: Option<f64>,
    water_percent: Option<f64>,
    protein_percent: Option<f64>,
    protein_mass_kg: Option<f64>,
    bone_percent: Option<f64>,
    bone_mass_kg: Option<f64>,
    skeletal_muscle_percent: Option<f64>,
    skeletal_muscle_mass_kg: Option<f64>,
    subcutaneous_fat_percent: Option<f64>,
    subcutaneous_fat_mass_kg: Option<f64>,
    resistance_ohm: Option<f64>,
    body_composition_model: Option<String>,
    source: String,
    height_cm: Option<f64>,
    bmi: Option<f64>,
    fat_mass_kg: Option<f64>,
    muscle_mass_kg: Option<f64>,
    water_mass_kg: Option<f64>,
    device_name: Option<String>,
}

fn fill_if_missing<T: Clone>(dst: &mut Option<T>, src: &Option<T>) {
    if dst.is_none() {
        *dst = src.clone();
    }
}

impl StoredWeight {
    fn merge_missing_from(&mut self, other: &StoredWeight) {
        fill_if_missing(&mut self.body_fat_percent, &other.body_fat_percent);
        fill_if_missing(&mut self.muscle_percent, &other.muscle_percent);
        fill_if_missing(&mut self.water_percent, &other.water_percent);
        fill_if_missing(&mut self.protein_percent, &other.protein_percent);
        fill_if_missing(&mut self.protein_mass_kg, &other.protein_mass_kg);
        fill_if_missing(&mut self.bone_percent, &other.bone_percent);
        fill_if_missing(&mut self.bone_mass_kg, &other.bone_mass_kg);
        fill_if_missing(
            &mut self.skeletal_muscle_percent,
            &other.skeletal_muscle_percent,
        );
        fill_if_missing(
            &mut self.skeletal_muscle_mass_kg,
            &other.skeletal_muscle_mass_kg,
        );
        fill_if_missing(
            &mut self.subcutaneous_fat_percent,
            &other.subcutaneous_fat_percent,
        );
        fill_if_missing(
            &mut self.subcutaneous_fat_mass_kg,
            &other.subcutaneous_fat_mass_kg,
        );
        fill_if_missing(&mut self.resistance_ohm, &other.resistance_ohm);
        fill_if_missing(
            &mut self.body_composition_model,
            &other.body_composition_model,
        );
        fill_if_missing(&mut self.height_cm, &other.height_cm);
        fill_if_missing(&mut self.bmi, &other.bmi);
        fill_if_missing(&mut self.fat_mass_kg, &other.fat_mass_kg);
        fill_if_missing(&mut self.muscle_mass_kg, &other.muscle_mass_kg);
        fill_if_missing(&mut self.water_mass_kg, &other.water_mass_kg);
        fill_if_missing(&mut self.device_name, &other.device_name);
    }
}

/// 体脂秤一次上秤会拆成体重包和体成分包，旧库按毫秒错开写成多条记录。
/// 这里按「体重相同且与聚类起点相差不超过 60 秒」归并：保留最早的时间戳，
/// 但把后续记录里的体成分、阻抗、设备等字段全部补进来，避免越导越少。
pub(crate) fn dedupe_weights(conn: &Connection) -> Result<()> {
    let mut rows = {
        let mut stmt = conn.prepare(
            "SELECT id, timestamp_ms, weight_kg, body_fat_percent, muscle_percent, water_percent,
                    protein_percent, protein_mass_kg, bone_percent, bone_mass_kg,
                    skeletal_muscle_percent, skeletal_muscle_mass_kg,
                    subcutaneous_fat_percent, subcutaneous_fat_mass_kg,
                    resistance_ohm, body_composition_model, source,
                    height_cm, bmi, fat_mass_kg, muscle_mass_kg, water_mass_kg, device_name
             FROM weight_records ORDER BY timestamp_ms ASC, id ASC",
        )?;
        let iter = stmt.query_map([], |r| {
            Ok(StoredWeight {
                id: r.get(0)?,
                timestamp_ms: r.get(1)?,
                weight_kg: r.get(2)?,
                body_fat_percent: r.get(3)?,
                muscle_percent: r.get(4)?,
                water_percent: r.get(5)?,
                protein_percent: r.get(6)?,
                protein_mass_kg: r.get(7)?,
                bone_percent: r.get(8)?,
                bone_mass_kg: r.get(9)?,
                skeletal_muscle_percent: r.get(10)?,
                skeletal_muscle_mass_kg: r.get(11)?,
                subcutaneous_fat_percent: r.get(12)?,
                subcutaneous_fat_mass_kg: r.get(13)?,
                resistance_ohm: r.get(14)?,
                body_composition_model: r.get(15)?,
                source: r.get(16)?,
                height_cm: r.get(17)?,
                bmi: r.get(18)?,
                fat_mass_kg: r.get(19)?,
                muscle_mass_kg: r.get(20)?,
                water_mass_kg: r.get(21)?,
                device_name: r.get(22)?,
            })
        })?;
        iter.collect::<rusqlite::Result<Vec<_>>>()?
    };
    rows.sort_by(|a, b| {
        a.timestamp_ms
            .cmp(&b.timestamp_ms)
            .then_with(|| a.id.cmp(&b.id))
    });

    let mut start = 0;
    while start < rows.len() {
        let mut end = start + 1;
        while end < rows.len()
            && rows[end].timestamp_ms - rows[start].timestamp_ms <= 60_000
            && (rows[end].weight_kg - rows[start].weight_kg).abs() < 0.001
        {
            end += 1;
        }
        if end > start + 1 {
            let mut keeper = rows[start].clone();
            for row in &rows[start + 1..end] {
                keeper.merge_missing_from(row);
            }
            conn.execute(
                "UPDATE weight_records SET
                    timestamp_ms = ?2, weight_kg = ?3, body_fat_percent = ?4,
                    muscle_percent = ?5, water_percent = ?6, protein_percent = ?7,
                    protein_mass_kg = ?8, bone_percent = ?9, bone_mass_kg = ?10,
                    skeletal_muscle_percent = ?11, skeletal_muscle_mass_kg = ?12,
                    subcutaneous_fat_percent = ?13, subcutaneous_fat_mass_kg = ?14,
                    resistance_ohm = ?15, body_composition_model = ?16, source = ?17,
                    height_cm = ?18, bmi = ?19, fat_mass_kg = ?20,
                    muscle_mass_kg = ?21, water_mass_kg = ?22, device_name = ?23
                 WHERE id = ?1",
                params![
                    keeper.id,
                    keeper.timestamp_ms,
                    keeper.weight_kg,
                    keeper.body_fat_percent,
                    keeper.muscle_percent,
                    keeper.water_percent,
                    keeper.protein_percent,
                    keeper.protein_mass_kg,
                    keeper.bone_percent,
                    keeper.bone_mass_kg,
                    keeper.skeletal_muscle_percent,
                    keeper.skeletal_muscle_mass_kg,
                    keeper.subcutaneous_fat_percent,
                    keeper.subcutaneous_fat_mass_kg,
                    keeper.resistance_ohm,
                    keeper.body_composition_model,
                    keeper.source,
                    keeper.height_cm,
                    keeper.bmi,
                    keeper.fat_mass_kg,
                    keeper.muscle_mass_kg,
                    keeper.water_mass_kg,
                    keeper.device_name,
                ],
            )?;
            for row in &rows[start + 1..end] {
                conn.execute("DELETE FROM weight_records WHERE id = ?1", params![row.id])?;
            }
        }
        start = end;
    }
    Ok(())
}

/// 旧库对同一次测量常按毫秒错开的时间戳连写几条读数完全一样的记录，
/// 「全部记录」里就会把一次上秤/一次量血压显示成 5 条。只合并 1 秒内
/// 读数相同的重复包，避免把相隔几秒的真实独立测量误删。
fn dedupe_measurements(
    conn: &Connection,
    table: &'static str,
    same: &'static str,
    prefer: &'static str,
) -> Result<()> {
    conn.execute(
        &format!(
            "DELETE FROM {table} WHERE id NOT IN (
               SELECT (SELECT k.id FROM {table} k WHERE {same} ORDER BY {prefer} LIMIT 1) FROM {table} g
             )"
        ),
        [],
    )?;
    Ok(())
}

fn import_bp(legacy: &Connection, report: &mut LegacyImportReport) -> Result<()> {
    let mut stmt = match legacy
        .prepare("SELECT id, timestamp, systolic, diastolic, pulse FROM blood_pressure_records")
    {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, i64>(2)?,
            r.get::<_, i64>(3)?,
            r.get::<_, Option<i64>>(4)?,
        ))
    })?;
    let deleted = store::health_tombstone_ids("bp")?;
    for row in rows.flatten() {
        if deleted.contains(&row.0) {
            continue;
        }
        // 旧库对同一次测量会连写几条读数相同、时间戳毫秒错开的记录，按 1 秒内同读数去重
        let inserted = store::with_conn(|conn| {
            let dup: i64 = conn.query_row(
                "SELECT count(*) FROM blood_pressure_records
                 WHERE ABS(timestamp_ms - ?1) <= 1000 AND systolic = ?2 AND diastolic = ?3 AND ifnull(pulse, -1) = ifnull(?4, -1)",
                params![row.1, row.2, row.3, row.4],
                |r| r.get(0),
            )?;
            if dup > 0 {
                return Ok(false);
            }
            conn.execute(
                "INSERT OR REPLACE INTO blood_pressure_records(id, timestamp_ms, systolic, diastolic, pulse, source)
                 VALUES(?1, ?2, ?3, ?4, ?5, 'manual')",
                params![row.0, row.1, row.2, row.3, row.4],
            )?;
            Ok(true)
        })?;
        if inserted {
            report.blood_pressure += 1;
        }
    }
    store::with_conn(|conn| dedupe_measurements(conn, "blood_pressure_records", BP_SAME, BP_KEEP))?;
    Ok(())
}

fn import_glucose(legacy: &Connection, report: &mut LegacyImportReport) -> Result<()> {
    let mut stmt = match legacy
        .prepare("SELECT id, timestamp, glucoseValue, measureType FROM blood_glucose_records")
    {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, f64>(2)?,
            r.get::<_, Option<String>>(3)?
                .unwrap_or_else(|| "random".into()),
        ))
    })?;
    let deleted = store::health_tombstone_ids("glucose")?;
    for row in rows.flatten() {
        if deleted.contains(&row.0) {
            continue;
        }
        let inserted = store::with_conn(|conn| {
            let dup: i64 = conn.query_row(
                "SELECT count(*) FROM blood_glucose_records WHERE (timestamp_ms + 30000) / 60000 = (?1 + 30000) / 60000 AND abs(value - ?2) < 0.001",
                params![row.1, row.2],
                |r| r.get(0),
            )?;
            if dup > 0 {
                return Ok(false);
            }
            conn.execute(
                "INSERT OR REPLACE INTO blood_glucose_records(id, timestamp_ms, value, measure_type, source)
                 VALUES(?1, ?2, ?3, ?4, 'manual')",
                params![row.0, row.1, row.2, row.3],
            )?;
            Ok(true)
        })?;
        if inserted {
            report.glucose += 1;
        }
    }
    store::with_conn(|conn| {
        dedupe_measurements(conn, "blood_glucose_records", GLUCOSE_SAME, GLUCOSE_KEEP)
    })?;
    Ok(())
}

fn import_arrhythmia(legacy: &Connection, _report: &mut LegacyImportReport) -> Result<()> {
    let mut stmt = match legacy
        .prepare("SELECT saveTime, resultType, measureType FROM huawei_arrhythmia_records")
    {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, i64>(2).unwrap_or(0),
        ))
    })?;
    for row in rows.flatten() {
        store::with_conn(|conn| {
            conn.execute(
                "INSERT OR REPLACE INTO arrhythmia_records(ts_ms, result_type, measure_type, source)
                 VALUES(?1, ?2, ?3, 'watch')",
                params![row.0, row.1, row.2],
            )?;
            Ok(())
        })?;
    }
    Ok(())
}

fn import_emotions(legacy: &Connection, report: &mut LegacyImportReport) -> Result<()> {
    let mut stmt = match legacy
        .prepare("SELECT timestamp, status, valence, arousal FROM huawei_emotion_records")
    {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, Option<f64>>(2)?,
            r.get::<_, Option<f64>>(3)?,
        ))
    })?;
    for row in rows.flatten() {
        store::with_conn(|conn| {
            conn.execute(
                "INSERT OR REPLACE INTO emotion_records(ts_ms, status, valence, arousal) VALUES(?1, ?2, ?3, ?4)",
                params![row.0, row.1, row.2, row.3],
            )?;
            Ok(())
        })?;
        report.emotions += 1;
    }
    Ok(())
}

/// P2P 字典三类旧数据：睡眠呼吸暂停（500002）、每小时状态（200005）、每日三环（300002）。
/// 旧库缺表时整段跳过，兼容更老的数据库。
fn import_p2p(legacy: &Connection) -> Result<()> {
    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;

        if let Ok(mut stmt) = legacy.prepare("SELECT timestamp, level FROM huawei_apnea_records") {
            if let Ok(rows) = stmt.query_map([], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1).unwrap_or(0)))
            }) {
                for (ts, level) in rows.flatten() {
                    if ts > 0 && (0..=10).contains(&level) {
                        tx.execute(
                            "INSERT OR REPLACE INTO apnea_records(ts_ms, level, source)
                             VALUES(?1, ?2, 'watch')",
                            params![ts, level],
                        )?;
                    }
                }
            }
        }

        if let Ok(mut stmt) =
            legacy.prepare("SELECT timestamp, value FROM huawei_hourly_status_records")
        {
            if let Ok(rows) = stmt.query_map([], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1).unwrap_or(1)))
            }) {
                for (ts, value) in rows.flatten() {
                    if ts > 0 {
                        tx.execute(
                            "INSERT OR REPLACE INTO hourly_status(ts_ms, value) VALUES(?1, ?2)",
                            params![ts, value],
                        )?;
                    }
                }
            }
        }

        if let Ok(mut stmt) = legacy.prepare(
            "SELECT dateEpochDay, dayEndMillis, stepGoal, stepUser, stepGoalState,
                    calorieGoalMilli, calorieUserMilli, calorieGoalState,
                    durationGoalMin, durationUserMin, durationGoalState,
                    activeGoalHours, activeUserHours, activeGoalState
             FROM huawei_daily_rings",
        ) {
            if let Ok(rows) = stmt.query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1).unwrap_or(0),
                    r.get::<_, i64>(2).unwrap_or(0),
                    r.get::<_, i64>(3).unwrap_or(0),
                    r.get::<_, i64>(4).unwrap_or(0),
                    r.get::<_, i64>(5).unwrap_or(0),
                    r.get::<_, i64>(6).unwrap_or(0),
                    r.get::<_, i64>(7).unwrap_or(0),
                    r.get::<_, i64>(8).unwrap_or(0),
                    r.get::<_, i64>(9).unwrap_or(0),
                    r.get::<_, i64>(10).unwrap_or(0),
                    r.get::<_, i64>(11).unwrap_or(0),
                    r.get::<_, i64>(12).unwrap_or(0),
                    r.get::<_, i64>(13).unwrap_or(0),
                ))
            }) {
                for row in rows.flatten() {
                    tx.execute(
                        "INSERT OR REPLACE INTO daily_rings(
                            date_day, day_end_ms, step_goal, step_user, step_state,
                            calorie_goal_milli, calorie_user_milli, calorie_state,
                            duration_goal_min, duration_user_min, duration_state,
                            active_goal_hours, active_user_hours, active_state, updated_ms)
                         VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
                        params![
                            row.0,
                            row.1,
                            row.2,
                            row.3,
                            row.4,
                            row.5,
                            row.6,
                            row.7,
                            row.8,
                            row.9,
                            row.10,
                            row.11,
                            row.12,
                            row.13,
                            now_ms(),
                        ],
                    )?;
                }
            }
        }

        tx.commit()?;
        Ok(())
    })
}

fn legacy_has_column(conn: &Connection, table: &str, column: &str) -> bool {
    let Ok(mut stmt) = conn.prepare(&format!("PRAGMA table_info({table})")) else {
        return false;
    };
    let Ok(rows) = stmt.query_map([], |r| r.get::<_, String>(1)) else {
        return false;
    };
    let found = rows.flatten().any(|name| name.eq_ignore_ascii_case(column));
    found
}

fn import_workouts(legacy: &Connection, report: &mut LegacyImportReport) -> Result<()> {
    let optional = |name: &str| {
        if legacy_has_column(legacy, "huawei_workouts", name) {
            name.to_string()
        } else {
            "NULL".to_string()
        }
    };
    let columns = vec![
        "id".to_string(),
        "workoutNumber".to_string(),
        "startTimeSec".to_string(),
        "endTimeSec".to_string(),
        "durationSec".to_string(),
        "totalTimeSec".to_string(),
        "calories".to_string(),
        optional("activeCalories"),
        "distanceMeters".to_string(),
        "stepCount".to_string(),
        "avgHeartRate".to_string(),
        "maxHeartRate".to_string(),
        "workoutLoad".to_string(),
        "aerobicEffect".to_string(),
        "anaerobicEffect".to_string(),
        "recoveryTime".to_string(),
        optional("maxMET"),
        optional("vo2max"),
        optional("elevationGain"),
        optional("elevationLoss"),
        optional("maxAltitude"),
        optional("minAltitude"),
        optional("maxHeartRatePeak"),
        optional("trackJson"),
        "type".to_string(),
        optional("uploadStatus"),
        optional("statExtendJson"),
        optional("recoveryHeartRates"),
        optional("startTempC"),
        optional("startHumidity"),
        optional("epoc"),
        optional("trainingPoints"),
        optional("hrZoneType"),
        optional("runPaceZone1Min"),
        optional("runPaceZone2Min"),
        optional("runPaceZone3Min"),
        optional("runPaceZone4Min"),
        optional("runPaceZone5Min"),
        optional("runPaceZone5Max"),
        optional("runPaceZone1Time"),
        optional("runPaceZone2Time"),
        optional("runPaceZone3Time"),
        optional("runPaceZone4Time"),
        optional("runPaceZone5Time"),
        optional("algType"),
    ];
    let sql = format!(
        "SELECT {} FROM huawei_workouts ORDER BY startTimeSec",
        columns.join(", ")
    );
    let mut stmt = match legacy.prepare(&sql) {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, i64>(2)?,
            r.get::<_, i64>(3)?,
            r.get::<_, i64>(4).unwrap_or(0),
            r.get::<_, i64>(5).unwrap_or(0),
            r.get::<_, i64>(6).unwrap_or(0),
            r.get::<_, i64>(7).unwrap_or(0),
            r.get::<_, f64>(8).unwrap_or(0.0),
            r.get::<_, i64>(9).unwrap_or(0),
            r.get::<_, i64>(10).unwrap_or(0),
            r.get::<_, i64>(11).unwrap_or(0),
            r.get::<_, i64>(12).unwrap_or(0),
            r.get::<_, f64>(13).unwrap_or(0.0),
            r.get::<_, f64>(14).unwrap_or(0.0),
            r.get::<_, i64>(15).unwrap_or(0),
            r.get::<_, Option<f64>>(16)?,
            r.get::<_, Option<f64>>(17)?,
            r.get::<_, Option<f64>>(18)?,
            r.get::<_, Option<f64>>(19)?,
            r.get::<_, Option<f64>>(20)?,
            r.get::<_, Option<f64>>(21)?,
            r.get::<_, Option<i64>>(22)?,
            r.get::<_, Option<String>>(23)?,
            r.get::<_, i64>(24).unwrap_or(0),
            r.get::<_, Option<i64>>(25)?,
            r.get::<_, Option<String>>(26)?,
            r.get::<_, Option<String>>(27)?,
            r.get::<_, Option<f64>>(28)?,
            r.get::<_, Option<i64>>(29)?,
            r.get::<_, Option<i64>>(30)?,
            r.get::<_, Option<i64>>(31)?,
            r.get::<_, Option<i64>>(32)?,
            r.get::<_, Option<i64>>(33)?,
            r.get::<_, Option<i64>>(34)?,
            r.get::<_, Option<i64>>(35)?,
            r.get::<_, Option<i64>>(36)?,
            r.get::<_, Option<i64>>(37)?,
            r.get::<_, Option<i64>>(38)?,
            r.get::<_, Option<i64>>(39)?,
            r.get::<_, Option<i64>>(40)?,
            r.get::<_, Option<i64>>(41)?,
            r.get::<_, Option<i64>>(42)?,
            r.get::<_, Option<i64>>(43)?,
            r.get::<_, Option<i64>>(44)?,
        ))
    })?;
    let rows: Vec<_> = rows.flatten().collect();
    if rows.is_empty() {
        return Ok(());
    }
    // workoutNumber 在旧库中并不唯一，必须用自增 id 作为主键。
    store::with_conn(|conn| {
        conn.execute("DELETE FROM workouts WHERE id LIKE 'legacy-%'", [])?;
        Ok(())
    })?;
    for row in rows {
        let (
            db_id,
            _number,
            start_sec,
            end_sec,
            duration,
            total_time,
            calories,
            active_calories,
            distance,
            steps,
            avg_hr,
            max_hr,
            load,
            aerobic,
            anaerobic,
            recovery,
            max_met,
            vo2max,
            gain,
            loss,
            max_alt,
            min_alt,
            max_hr_peak,
            track,
            type_code,
            upload,
            stat_extend,
            recovery_hrs,
            start_temp,
            start_humidity,
            epoc,
            training_points,
            _hr_zone_type,
            zone1_min,
            zone2_min,
            zone3_min,
            zone4_min,
            zone5_min,
            zone5_max,
            zone1_time,
            zone2_time,
            zone3_time,
            zone4_time,
            zone5_time,
            alg_type,
        ) = row;
        let stat_extend = stat_extend.filter(|value| !value.trim().is_empty());
        let run_pace_zones = legacy_pace_zones_json(
            [
                zone1_min, zone2_min, zone3_min, zone4_min, zone5_min, zone5_max,
            ],
            [zone1_time, zone2_time, zone3_time, zone4_time, zone5_time],
        );
        let training_points = training_points.filter(|value| *value > 0);
        let epoc = epoc.filter(|value| *value > 0);
        let alg_type = alg_type.filter(|value| *value > 0);
        let track = track.and_then(|raw| normalize_track(&raw));
        // 旧版的 maxMET 以 1e5 为定点存储（899398 表示 8.99），零值视为未采集。
        let max_met = max_met
            .filter(|v| *v > 0.0)
            .map(|v| if v > 1000.0 { v / 100_000.0 } else { v });
        let vo2max = vo2max.filter(|v| *v > 0.0);
        // 旧版样本表以 workouts.id 关联，而不是 workoutNumber。
        let samples = workout_samples(legacy, db_id)?;
        let (dynamics, cadence) = workout_dynamics(legacy, db_id)?;
        let altitude = workout_altitude(legacy, db_id)?;
        let recovery_json = recovery_hrs.and_then(|raw| parse_recovery(&raw));
        let splits_json = workout_splits(legacy, db_id)?;
        let swim_segments = workout_swim_segments(legacy, db_id)?;
        let detail_json = detail_with_segments(stat_extend.as_deref(), swim_segments.as_deref());
        let id = format!("legacy-{db_id}");
        let sport = sport_label(type_code).to_string();
        let avg_pace = if distance > 500.0 && duration > 0 {
            Some(duration as f64 / (distance / 1000.0))
        } else {
            None
        };
        let start_ms = start_sec * 1000;
        let inserted = store::with_conn(|conn| {
            // 手表同步已经存过同一场运动（同类型、开始时间相差 2 分钟内）时，
            // 不再插入 legacy-* 副本，避免列表里同一次运动出现两条。
            let already_synced: Option<(
                String,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
            )> = conn
                .query_row(
                    "SELECT id, track_json, samples_json, dynamics_json,
                            altitude_json, recovery_json, detail_json
                     FROM workouts WHERE id LIKE 'watch-%' AND sport = ?1
                     AND ABS(start_ms - ?2) <= 120000 LIMIT 1",
                    params![sport, start_ms],
                    |r| {
                        Ok((
                            r.get(0)?,
                            r.get(1)?,
                            r.get(2)?,
                            r.get(3)?,
                            r.get(4)?,
                            r.get(5)?,
                            r.get(6)?,
                        ))
                    },
                )
                .optional()?;
            if let Some((
                watch_id,
                existing_track,
                existing_samples,
                existing_dynamics,
                existing_altitude,
                existing_recovery,
                existing_detail,
            )) = already_synced
            {
                let merged_track = store::merge_json_point_series(
                    existing_track.as_deref(),
                    track.as_deref(),
                    "t",
                );
                let merged_samples = store::merge_json_point_series(
                    existing_samples.as_deref(),
                    samples.as_deref(),
                    "t",
                );
                let merged_dynamics = store::merge_json_point_series(
                    existing_dynamics.as_deref(),
                    dynamics.as_deref(),
                    "t",
                );
                let merged_altitude = store::merge_json_point_series(
                    existing_altitude.as_deref(),
                    altitude.as_deref(),
                    "t",
                );
                let merged_recovery =
                    store::richer_json(existing_recovery.as_deref(), recovery_json.as_deref());
                let merged_detail =
                    merge_detail_json(existing_detail.as_deref(), detail_json.as_deref());
                // 手表汇总包没有跑力字段，迁移时把它补到已同步的行上。
                conn.execute(
                    "UPDATE workouts SET vo2max = COALESCE(vo2max, ?2),
                                         max_met = COALESCE(max_met, ?3),
                                         splits_json = COALESCE(?4, splits_json),
                                         training_points = COALESCE(training_points, ?5),
                                         epoc = COALESCE(epoc, ?6),
                                         stat_extend_json = COALESCE(stat_extend_json, ?7),
                                         run_pace_zones_json = COALESCE(run_pace_zones_json, ?8),
                                         max_altitude = COALESCE(max_altitude, ?9),
                                         min_altitude = COALESCE(min_altitude, ?10),
                                         alg_type = COALESCE(alg_type, ?11),
                                         track_json = ?12,
                                         samples_json = ?13,
                                         dynamics_json = ?14,
                                         altitude_json = ?15,
                                         recovery_json = ?16,
                                         detail_json = ?17
                     WHERE id = ?1",
                    params![
                        watch_id,
                        vo2max,
                        max_met,
                        splits_json,
                        training_points,
                        epoc,
                        stat_extend,
                        run_pace_zones,
                        max_alt,
                        min_alt,
                        alg_type,
                        merged_track,
                        merged_samples,
                        merged_dynamics,
                        merged_altitude,
                        merged_recovery,
                        merged_detail,
                    ],
                )?;
                return Ok(false);
            }
            conn.execute(
                "INSERT OR REPLACE INTO workouts(
                    id, source, sport, start_ms, end_ms, distance_m, calories, avg_hr, max_hr, steps, load,
                    aerobic_effect, recovery_time_min, track_json, samples_json, synced, created_ms,
                    type_code, total_time_sec, active_calories, max_met, vo2max, anaerobic_effect,
                    elevation_gain, elevation_loss, avg_pace_sec, cadence, detail_json,
                    dynamics_json, altitude_json, recovery_json, splits_json, start_temp_c, start_humidity,
                    training_points, epoc, stat_extend_json, run_pace_zones_json,
                    max_altitude, min_altitude, alg_type, upload_status)
                 VALUES(?1, 'watch', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 1, ?15,
                    ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29, ?30, ?31, ?32,
                    ?33, ?34, ?35, ?36, ?37, ?38, ?39, ?40)",
                params![
                    id,
                    sport,
                    start_ms,
                    if end_sec > start_sec { end_sec * 1000 } else { (start_sec + duration) * 1000 },
                    distance,
                    calories,
                    avg_hr,
                    max_hr.max(max_hr_peak.unwrap_or(0)),
                    steps,
                    load,
                    aerobic / 10.0,
                    recovery,
                    track,
                    samples,
                    start_ms,
                    type_code,
                    total_time,
                    active_calories,
                    max_met,
                    vo2max,
                    anaerobic / 10.0,
                    gain,
                    loss,
                    avg_pace,
                    cadence,
                    detail_json,
                    dynamics,
                    altitude,
                    recovery_json,
                    splits_json,
                    start_temp,
                    start_humidity,
                    training_points,
                    epoc,
                    stat_extend,
                    run_pace_zones,
                    max_alt,
                    min_alt,
                    alg_type,
                    upload.unwrap_or(0),
                ],
            )?;
            Ok(true)
        })?;
        if inserted {
            report.workouts += 1;
        }
    }
    Ok(())
}

/// 已经迁移过的老用户补 0x0c 分段：只更新现有行，不重跑整套运动导入，
/// 避免把用户删掉的 legacy-* 记录又插回来。
fn backfill_workout_splits(legacy: &Connection) -> Result<()> {
    let mut stmt = match legacy
        .prepare("SELECT id, type, startTimeSec FROM huawei_workouts ORDER BY startTimeSec")
    {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let workouts: Vec<(i64, i64, i64)> = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1).unwrap_or(0),
                r.get::<_, i64>(2).unwrap_or(0),
            ))
        })?
        .flatten()
        .collect();
    drop(stmt);

    let mut rows = Vec::new();
    for (db_id, type_code, start_sec) in workouts {
        let Some(splits) = workout_splits(legacy, db_id)? else {
            continue;
        };
        rows.push((
            format!("legacy-{db_id}"),
            sport_label(type_code).to_string(),
            start_sec.saturating_mul(1000),
            splits,
        ));
    }
    if rows.is_empty() {
        return Ok(());
    }

    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        {
            let mut legacy_update =
                tx.prepare("UPDATE workouts SET splits_json = ?2 WHERE id = ?1")?;
            let mut watch_update = tx.prepare(
                "UPDATE workouts
                 SET splits_json = COALESCE(splits_json, ?2)
                 WHERE id LIKE 'watch-%' AND sport = ?3
                   AND ABS(start_ms - ?4) <= 120000",
            )?;
            for (id, sport, start_ms, splits) in &rows {
                legacy_update.execute(params![id, splits])?;
                watch_update.execute(params![splits, sport, start_ms])?;
            }
        }
        tx.commit()?;
        Ok(())
    })
}

fn session_sport(label: &str) -> &'static str {
    let text = label.to_lowercase();
    if text.contains("跑") || text.contains("run") {
        "running"
    } else if text.contains("骑") || text.contains("cycl") {
        "cycling"
    } else if text.contains("徒步") || text.contains("hik") {
        "hiking"
    } else if text.contains("走") || text.contains("walk") {
        "walking"
    } else if text.contains("游") || text.contains("swim") {
        "swimming"
    } else if text.contains("力量") || text.contains("strength") {
        "strength"
    } else {
        "workout"
    }
}

fn haversine_m(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const EARTH_R: f64 = 6_371_000.0;
    let dlat = (lat2 - lat1).to_radians();
    let dlon = (lon2 - lon1).to_radians();
    let a = (dlat / 2.0).sin().powi(2)
        + lat1.to_radians().cos() * lat2.to_radians().cos() * (dlon / 2.0).sin().powi(2);
    2.0 * EARTH_R * a.sqrt().asin()
}

/// 旧版个人纪录是手表侧算好的静态最佳值。新版会从运动明细动态计算大部分
/// 项目，但历史运动缺少分段时算不出 5K/10K/半马成绩，所以把旧纪录全部
/// 保留下来，由 `store::personal_records()` 按“更好才覆盖”合并。
fn import_personal_records(legacy: &Connection) -> Result<()> {
    let mut stmt = match legacy.prepare(
        "SELECT sportType, metric, value, achievedAtSec
         FROM sport_personal_records",
    ) {
        Ok(stmt) => stmt,
        Err(_) => return Ok(()),
    };
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, f64>(2)?,
            r.get::<_, i64>(3)?,
        ))
    })?;
    let mut records: HashMap<(String, String), (f64, i64, bool)> = HashMap::new();
    for row in rows.flatten() {
        let (sport_type, metric, value, achieved_sec) = row;
        let Some((key, _, _, higher_is_better, scale)) =
            store::legacy_personal_record_meta(&metric)
        else {
            continue;
        };
        let value = value * scale;
        if !value.is_finite() || value <= 0.0 || achieved_sec <= 0 {
            continue;
        }
        let group = store::personal_record_group(sport_label(sport_type));
        let slot = records.entry((group, key.to_string()));
        match slot {
            std::collections::hash_map::Entry::Occupied(mut entry) => {
                let (current, _, direction) = entry.get();
                let better = if *direction {
                    value > *current
                } else {
                    value < *current
                };
                if better {
                    entry.insert((value, achieved_sec * 1000, higher_is_better));
                }
            }
            std::collections::hash_map::Entry::Vacant(entry) => {
                entry.insert((value, achieved_sec * 1000, higher_is_better));
            }
        }
    }
    if records.is_empty() {
        return Ok(());
    }

    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        tx.execute("DELETE FROM legacy_personal_records", [])?;
        {
            let mut ins = tx.prepare(
                "INSERT OR REPLACE INTO legacy_personal_records(
                   sport, metric, value, achieved_ms, workout_id
                 ) VALUES(?1, ?2, ?3, ?4, ?5)",
            )?;
            for ((sport, metric), (value, achieved_ms, _)) in records {
                // 新版运动会把 treadmill/climbing 等归一成 running/hiking，
                // 所以按开始时间找候选后再用分组过滤，不能只比 sport 字符串。
                let workout_id = {
                    let mut candidates = tx.prepare(
                        "SELECT id, sport FROM workouts
                         WHERE ABS(start_ms - ?1) <= 120000
                         ORDER BY ABS(start_ms - ?1)",
                    )?;
                    let id = candidates
                        .query_map(params![achieved_ms], |r| {
                            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                        })?
                        .flatten()
                        .find(|(_, workout_sport)| {
                            store::personal_record_group(workout_sport) == sport
                        })
                        .map(|(id, _)| id)
                        .unwrap_or_default();
                    id
                };
                ins.execute(params![sport, metric, value, achieved_ms, workout_id])?;
            }
        }
        tx.commit()?;
        Ok(())
    })
}

/// 旧版手机端自己记录的运动会话（`running_sessions`）。这些记录不在华为
/// `huawei_workouts` 里，之前只迁移手表汇总，用户的手机 GPS 轨迹会整段丢失。
fn import_sessions(legacy: &Connection, report: &mut LegacyImportReport) -> Result<()> {
    let mut stmt = match legacy
        .prepare("SELECT id, startTimeMillis, json FROM running_sessions ORDER BY startTimeMillis")
    {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, String>(2)?,
        ))
    })?;
    for row in rows.flatten() {
        let (old_id, start_column, raw) = row;
        let Ok(value) = serde_json::from_str::<Value>(&raw) else {
            continue;
        };
        let start_ms = value
            .get("startTime")
            .and_then(|v| v.as_i64())
            .unwrap_or(start_column);
        let duration = value
            .get("totalDurationSeconds")
            .and_then(|v| v.as_i64())
            .unwrap_or(0)
            .max(0);
        let end_ms = value
            .get("endTime")
            .and_then(|v| v.as_i64())
            .filter(|end| *end >= start_ms)
            .unwrap_or(start_ms + duration * 1000);
        let activity = value
            .get("activityType")
            .and_then(|v| v.as_str())
            .unwrap_or("骑行");
        let sport = session_sport(activity);
        let template_id = value.get("templateId").and_then(|v| v.as_i64());
        let is_strength = sport == "strength" || template_id.is_some();

        let points = value
            .get("gpsPoints")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let mut track = Vec::new();
        let mut samples = Vec::new();
        let mut distance = value
            .get("totalDistanceMeters")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0)
            .max(0.0);
        let mut computed_distance = 0.0;
        let mut previous: Option<(f64, f64)> = None;
        for point in &points {
            let Some(lat) = point.get("latitude").and_then(|v| v.as_f64()) else {
                continue;
            };
            let Some(lon) = point.get("longitude").and_then(|v| v.as_f64()) else {
                continue;
            };
            if !(-90.0..=90.0).contains(&lat)
                || !(-180.0..=180.0).contains(&lon)
                || (lat.abs() < 0.0001 && lon.abs() < 0.0001)
            {
                continue;
            }
            let ts = point
                .get("timestamp")
                .and_then(|v| v.as_i64())
                .filter(|t| *t > 0)
                .unwrap_or(start_ms);
            let alt = point.get("altitude").and_then(|v| v.as_f64());
            track.push(json!({ "lat": lat, "lon": lon, "t": ts, "alt": alt }));
            if let Some((plat, plon)) = previous {
                computed_distance += haversine_m(plat, plon, lat, lon);
            }
            previous = Some((lat, lon));
            let hr = point.get("heartRate").and_then(|v| v.as_i64()).unwrap_or(0);
            if (20..240).contains(&hr) {
                samples.push(json!({ "t": ts, "hr": hr }));
            }
        }
        if distance <= 0.0 {
            distance = computed_distance;
        }
        let track_json = (track.len() >= 2).then(|| Value::Array(track).to_string());
        let samples_json = (!samples.is_empty()).then(|| Value::Array(samples.clone()).to_string());

        let mut avg_hr = value
            .get("averageHeartRate")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let mut max_hr = value
            .get("maxHeartRate")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        if (avg_hr <= 0 || max_hr <= 0) && !samples.is_empty() {
            let values: Vec<i64> = samples
                .iter()
                .filter_map(|p| p.get("hr").and_then(|v| v.as_i64()))
                .collect();
            if !values.is_empty() {
                if avg_hr <= 0 {
                    avg_hr = values.iter().sum::<i64>() / values.len() as i64;
                }
                if max_hr <= 0 {
                    max_hr = *values.iter().max().unwrap_or(&0);
                }
            }
        }
        let recovery_json = value
            .get("recoveryHeartRate")
            .and_then(|v| v.get("heartRateSamples"))
            .and_then(|v| v.as_array())
            .map(|items| {
                let values: Vec<i64> = items
                    .iter()
                    .filter_map(|p| p.get("heartRate").and_then(|v| v.as_i64()))
                    .filter(|bpm| (20..240).contains(bpm))
                    .collect();
                Value::Array(values.into_iter().map(Value::from).collect()).to_string()
            })
            .filter(|raw| raw != "[]");
        let dynamics_json = value
            .get("powerStatistics")
            .and_then(|v| v.get("powerDataPoints"))
            .and_then(|v| v.as_array())
            .map(|items| {
                let points: Vec<Value> = items
                    .iter()
                    .filter_map(|p| {
                        let power = p.get("power").and_then(|v| v.as_f64())?;
                        let ts = p
                            .get("timestamp")
                            .and_then(|v| v.as_i64())
                            .unwrap_or(start_ms);
                        let speed = p.get("speedKmh").and_then(|v| v.as_f64()).unwrap_or(0.0);
                        Some(json!({ "t": ts, "pwr": power, "spd": speed }))
                    })
                    .collect();
                Value::Array(points).to_string()
            })
            .filter(|raw| raw != "[]");
        let duration_sec = if duration > 0 {
            duration
        } else {
            ((end_ms - start_ms) / 1000).max(0)
        };
        let avg_pace = (distance > 100.0 && duration_sec > 0)
            .then(|| duration_sec as f64 / (distance / 1000.0));
        let calories = value.get("calories").and_then(|v| v.as_i64()).unwrap_or(0);
        let elevation_gain = value
            .get("totalAscent")
            .and_then(|v| v.as_f64())
            .filter(|v| *v > 0.0);
        let id = format!("legacy-session-{old_id}");

        let inserted = store::with_conn(|conn| {
            let mut merged = false;
            if !is_strength {
                let already: Option<(
                    String,
                    Option<String>,
                    Option<String>,
                    Option<String>,
                    Option<String>,
                )> = conn
                    .query_row(
                        "SELECT id, track_json, samples_json, dynamics_json, recovery_json
                         FROM workouts WHERE sport = ?1
                         AND ABS(start_ms - ?2) <= 120000
                         AND id NOT LIKE 'legacy-session-%'
                         ORDER BY CASE WHEN id LIKE 'watch-%' THEN 0 ELSE 1 END,
                                  ABS(start_ms - ?2)
                         LIMIT 1",
                        params![sport, start_ms],
                        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
                    )
                    .optional()?;
                if let Some((
                    existing_id,
                    existing_track,
                    existing_samples,
                    existing_dynamics,
                    existing_recovery,
                )) = already
                {
                    let merged_track = store::merge_json_point_series(
                        existing_track.as_deref(),
                        track_json.as_deref(),
                        "t",
                    );
                    let merged_samples = store::merge_json_point_series(
                        existing_samples.as_deref(),
                        samples_json.as_deref(),
                        "t",
                    );
                    let merged_dynamics = store::merge_json_point_series(
                        existing_dynamics.as_deref(),
                        dynamics_json.as_deref(),
                        "t",
                    );
                    let merged_recovery =
                        store::richer_json(existing_recovery.as_deref(), recovery_json.as_deref());
                    // 手表/云端汇总可能没有手机端录下的 GPS 轨迹、心率样本和
                    // 功率点。同一场运动不再新增副本，但要把这些缺失明细补上。
                    conn.execute(
                        "UPDATE workouts SET
                            distance_m = CASE WHEN distance_m <= 0 AND ?2 > 0
                                              THEN ?2 ELSE distance_m END,
                            calories = CASE WHEN calories <= 0 AND ?3 > 0
                                            THEN ?3 ELSE calories END,
                            avg_hr = CASE WHEN avg_hr <= 0 AND ?4 > 0
                                          THEN ?4 ELSE avg_hr END,
                            max_hr = CASE WHEN max_hr <= 0 AND ?5 > 0
                                          THEN ?5 ELSE max_hr END,
                            total_time_sec = CASE WHEN total_time_sec <= 0 AND ?6 > 0
                                                  THEN ?6 ELSE total_time_sec END,
                            elevation_gain = CASE WHEN (elevation_gain IS NULL OR elevation_gain <= 0)
                                                   AND ?7 > 0
                                                  THEN ?7 ELSE elevation_gain END,
                            avg_pace_sec = COALESCE(avg_pace_sec, ?8),
                            track_json = ?9,
                            samples_json = ?10,
                            dynamics_json = ?11,
                            recovery_json = ?12
                         WHERE id = ?1",
                        params![
                            existing_id,
                            distance,
                            calories,
                            avg_hr,
                            max_hr,
                            duration_sec,
                            elevation_gain,
                            avg_pace,
                            merged_track,
                            merged_samples,
                            merged_dynamics,
                            merged_recovery,
                        ],
                    )?;
                    merged = true;
                }
            }
            if merged {
                return Ok(false);
            }
            conn.execute(
                "INSERT OR REPLACE INTO workouts(
                    id, source, sport, start_ms, end_ms, distance_m, calories, avg_hr, max_hr,
                    steps, load, aerobic_effect, recovery_time_min, track_json, samples_json,
                    synced, created_ms, total_time_sec, elevation_gain, avg_pace_sec,
                    dynamics_json, recovery_json)
                 VALUES(?1, 'phone', ?2, ?3, ?4, ?5, ?6, ?7, ?8,
                    0, 0, 0, 0, ?9, ?10, 1, ?11, ?12, ?13, ?14, ?15, ?16)",
                params![
                    id,
                    sport,
                    start_ms,
                    end_ms,
                    distance,
                    calories,
                    avg_hr,
                    max_hr,
                    track_json,
                    samples_json,
                    start_ms,
                    duration_sec,
                    elevation_gain,
                    avg_pace,
                    dynamics_json,
                    recovery_json,
                ],
            )?;
            Ok(true)
        })?;
        if inserted {
            report.workouts += 1;
        }
    }
    Ok(())
}

/// 旧版力量训练的动作库、模板和组记录。动作/模板按名称去重，避免和
/// 新版首次启动写入的默认模板重复；组记录挂到对应的运动记录 id 上。
fn import_strength(legacy: &Connection) -> Result<()> {
    let exercises: Vec<(i64, String, String, String, bool)> = {
        let Ok(mut stmt) = legacy
            .prepare("SELECT id, name, muscleGroup, equipment, isCustom FROM strength_exercises")
        else {
            return Ok(());
        };
        let rows: Vec<_> = stmt
            .query_map([], |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get::<_, i64>(4).unwrap_or(0) != 0,
                ))
            })?
            .flatten()
            .collect();
        rows
    };
    let templates: Vec<(i64, String, String, i64, i64)> = {
        let Ok(mut stmt) =
            legacy.prepare("SELECT id, name, notes, createdAt, updatedAt FROM strength_templates")
        else {
            return Ok(());
        };
        let rows: Vec<_> = stmt
            .query_map([], |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get::<_, i64>(3).unwrap_or(0),
                    r.get::<_, i64>(4).unwrap_or(0),
                ))
            })?
            .flatten()
            .collect();
        rows
    };
    let template_exercises: Vec<(i64, i64, i64, i64, i64, i64, Option<f64>, String)> = {
        let Ok(mut stmt) = legacy.prepare(
            "SELECT templateId, exerciseId, orderIndex, targetSets, targetReps,
                    restSeconds, targetWeightKg, notes
             FROM strength_template_exercises",
        ) else {
            return Ok(());
        };
        let rows: Vec<_> = stmt
            .query_map([], |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get::<_, i64>(2).unwrap_or(0),
                    r.get::<_, i64>(3).unwrap_or(3),
                    r.get::<_, i64>(4).unwrap_or(12),
                    r.get::<_, i64>(5).unwrap_or(60),
                    r.get(6)?,
                    r.get::<_, String>(7).unwrap_or_default(),
                ))
            })?
            .flatten()
            .collect();
        rows
    };
    let sets: Vec<(String, i64, String, i64, f64, i64, i64, i64)> = {
        let Ok(mut stmt) = legacy.prepare(
            "SELECT sessionId, exerciseId, exerciseName, setNumber, weightKg, reps,
                    restSecondsActual, completedAt
             FROM strength_workout_sets",
        ) else {
            return Ok(());
        };
        let rows: Vec<_> = stmt
            .query_map([], |r| {
                Ok((
                    r.get(0)?,
                    r.get::<_, i64>(1).unwrap_or(0),
                    r.get::<_, String>(2).unwrap_or_default(),
                    r.get::<_, i64>(3).unwrap_or(1),
                    r.get::<_, f64>(4).unwrap_or(0.0),
                    r.get::<_, i64>(5).unwrap_or(0),
                    r.get::<_, i64>(6).unwrap_or(0),
                    r.get::<_, i64>(7).unwrap_or(0),
                ))
            })?
            .flatten()
            .collect();
        rows
    };
    if exercises.is_empty() && templates.is_empty() && sets.is_empty() {
        return Ok(());
    }

    let sessions: HashMap<String, i64> = {
        let Ok(mut stmt) = legacy.prepare("SELECT id, startTimeMillis FROM running_sessions")
        else {
            return Ok(());
        };
        let rows: HashMap<_, _> = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?
            .flatten()
            .collect();
        rows
    };

    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        let mut exercise_ids = HashMap::new();
        for (old_id, name, group, equipment, custom) in &exercises {
            let existing: Option<i64> = tx
                .query_row(
                    "SELECT id FROM strength_exercises WHERE name = ?1 LIMIT 1",
                    params![name],
                    |r| r.get(0),
                )
                .optional()?;
            let id = match existing {
                Some(id) => id,
                None => {
                    tx.execute(
                        "INSERT INTO strength_exercises(name, muscle_group, equipment, is_custom)
                         VALUES(?1, ?2, ?3, ?4)",
                        params![name, group, equipment, if *custom { 1 } else { 0 }],
                    )?;
                    tx.last_insert_rowid()
                }
            };
            exercise_ids.insert(*old_id, id);
        }

        let mut template_ids = HashMap::new();
        for (old_id, name, notes, created, updated) in &templates {
            let existing: Option<i64> = tx
                .query_row(
                    "SELECT id FROM strength_templates WHERE name = ?1 LIMIT 1",
                    params![name],
                    |r| r.get(0),
                )
                .optional()?;
            let id = match existing {
                Some(id) => id,
                None => {
                    tx.execute(
                        "INSERT INTO strength_templates(name, notes, created_ms, updated_ms)
                         VALUES(?1, ?2, ?3, ?4)",
                        params![name, notes, created, updated.max(created)],
                    )?;
                    tx.last_insert_rowid()
                }
            };
            template_ids.insert(*old_id, id);
        }

        for (old_template, old_exercise, order, sets_count, reps, rest, weight, notes) in
            &template_exercises
        {
            let (Some(template_id), Some(exercise_id)) = (
                template_ids.get(old_template),
                exercise_ids.get(old_exercise),
            ) else {
                continue;
            };
            let exists: i64 = tx.query_row(
                "SELECT COUNT(*) FROM strength_template_exercises
                 WHERE template_id = ?1 AND exercise_id = ?2 AND order_index = ?3",
                params![template_id, exercise_id, order],
                |r| r.get(0),
            )?;
            if exists > 0 {
                continue;
            }
            tx.execute(
                "INSERT INTO strength_template_exercises(
                    template_id, exercise_id, order_index, target_sets, target_reps,
                    rest_seconds, target_weight_kg, notes)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    template_id,
                    exercise_id,
                    order,
                    sets_count,
                    reps,
                    rest,
                    weight,
                    notes,
                ],
            )?;
        }

        for (old_session, old_exercise, name, set_number, weight, reps, rest, completed) in &sets {
            let session_id = format!("legacy-session-{old_session}");
            let session_id = if tx
                .query_row(
                    "SELECT id FROM workouts WHERE id = ?1",
                    params![&session_id],
                    |r| r.get::<_, String>(0),
                )
                .optional()?
                .is_some()
            {
                session_id
            } else if let Some(start) = sessions.get(old_session) {
                tx.query_row(
                    "SELECT id FROM workouts WHERE ABS(start_ms - ?1) <= 120000
                     ORDER BY CASE WHEN id LIKE 'legacy-session-%' THEN 1 ELSE 0 END LIMIT 1",
                    params![start],
                    |r| r.get::<_, String>(0),
                )
                .optional()?
                .unwrap_or(session_id)
            } else {
                session_id
            };
            let exercise_id = exercise_ids.get(old_exercise).copied().unwrap_or(0);
            let exists: i64 = tx.query_row(
                "SELECT COUNT(*) FROM strength_workout_sets
                 WHERE session_id = ?1 AND exercise_name = ?2
                   AND set_number = ?3 AND completed_at_ms = ?4",
                params![session_id, name, set_number, completed],
                |r| r.get(0),
            )?;
            if exists > 0 {
                continue;
            }
            tx.execute(
                "INSERT INTO strength_workout_sets(
                    session_id, exercise_id, exercise_name, set_number, weight_kg, reps,
                    rest_seconds_actual, completed_at_ms)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    session_id,
                    exercise_id,
                    name,
                    set_number,
                    weight,
                    reps,
                    rest,
                    completed
                ],
            )?;
        }
        tx.commit()?;
        Ok(())
    })
}

/// 旧版训练计划文档和新版结构几乎同构，转换成新 JSON 后直接写入设置。
/// 已经有新计划（或用户手动新建过）时不覆盖。
fn import_training_plan(legacy: &Connection) -> Result<()> {
    if store::settings_get("training_plan_v1", "")
        .map(|v| !v.trim().is_empty())
        .unwrap_or(false)
    {
        return Ok(());
    }
    let row: Option<(String, String, String)> = {
        let Ok(mut stmt) = legacy.prepare(
            "SELECT planId, planName, docJson FROM training_plans
             WHERE status = 0 ORDER BY id DESC LIMIT 1",
        ) else {
            return Ok(());
        };
        stmt.query_row([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .optional()?
    };
    let Some((plan_id, plan_name, doc_json)) = row else {
        return Ok(());
    };
    let Ok(doc) = serde_json::from_str::<Value>(&doc_json) else {
        return Ok(());
    };
    let race_day = doc
        .get("raceEpochDay")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    let start_day = doc
        .get("startEpochDay")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    if race_day <= 0 || start_day <= 0 {
        return Ok(());
    }
    let race_km = doc
        .get("raceDistanceKm")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    let goal = if race_km >= 40.0 {
        "full"
    } else if race_km >= 20.0 {
        "half"
    } else if race_km >= 9.0 {
        "tenK"
    } else {
        "fiveK"
    };
    let goal_label = match goal {
        "full" => "全马",
        "half" => "半马",
        "tenK" => "10K",
        _ => "5K",
    };
    let mut weeks = Vec::new();
    for week in doc
        .get("weeks")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
    {
        let week_num = week.get("weekNum").and_then(|v| v.as_i64()).unwrap_or(0);
        let week_start = week
            .get("startEpochDay")
            .and_then(|v| v.as_i64())
            .unwrap_or(start_day);
        let mut days = Vec::new();
        for day in week
            .get("days")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default()
        {
            let epoch_day = day
                .get("epochDay")
                .and_then(|v| v.as_i64())
                .unwrap_or(week_start);
            let mut sessions = Vec::new();
            for course in day
                .get("courses")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default()
            {
                let kind = course
                    .get("kind")
                    .and_then(|v| v.as_str())
                    .unwrap_or("EASY")
                    .to_lowercase();
                let km = course
                    .get("distanceKm")
                    .and_then(|v| v.as_f64())
                    .unwrap_or(0.0)
                    .round() as i64;
                let minutes = course
                    .get("strengthMinutes")
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0);
                let blocks = course
                    .get("intervalBlocks")
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0);
                sessions.push(json!({ "k": kind, "km": km, "m": minutes, "b": blocks }));
            }
            days.push(json!({
                "d": store::date_of_epoch_day(epoch_day).format("%Y-%m-%d").to_string(),
                "s": sessions,
            }));
        }
        weeks.push(json!({
            "n": week_num,
            "start": store::date_of_epoch_day(week_start).format("%Y-%m-%d").to_string(),
            "days": days,
        }));
    }
    if weeks.is_empty() {
        return Ok(());
    }
    let adjustments: Vec<Value> = doc
        .get("adjustments")
        .and_then(|v| v.as_array())
        .map(|items| {
            items
                .iter()
                .map(|item| {
                    let day = item
                        .get("madeAtEpochDay")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(start_day);
                    json!({
                        "d": store::date_of_epoch_day(day).format("%Y-%m-%d").to_string(),
                        "r": item.get("reason").and_then(|v| v.as_str()).unwrap_or(""),
                        "p": item.get("paceFactor").and_then(|v| v.as_f64()).unwrap_or(1.0),
                        "l": item.get("longRunKm").and_then(|v| v.as_i64()).unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let plan = json!({
        "v": 1,
        "id": plan_id,
        "name": plan_name,
        "goal": goal,
        "race": store::date_of_epoch_day(race_day).format("%Y-%m-%d").to_string(),
        "start": store::date_of_epoch_day(start_day).format("%Y-%m-%d").to_string(),
        "pace": doc.get("basePaceSecPerKm").and_then(|v| v.as_i64()).unwrap_or(360),
        "long": doc.get("longRunKm").and_then(|v| v.as_i64()).unwrap_or(10),
        "created": doc.get("createdAtSec").and_then(|v| v.as_i64()).unwrap_or(0) * 1000,
        "pf": doc.get("paceFactor").and_then(|v| v.as_f64()).unwrap_or(1.0),
        "adapted": doc.get("lastAdaptedEpochDay").and_then(|v| v.as_i64()).unwrap_or(0),
        "punch": doc.get("punchTimeStampSec").and_then(|v| v.as_i64()).unwrap_or(0),
        "adjust": adjustments,
        "weeks": weeks,
    });
    store::settings_set("training_plan_v1", &plan.to_string())?;
    store::settings_set("training_plan_goal", goal_label)?;

    let completions: Vec<(String, i64, i64, i64)> = {
        let Ok(mut stmt) = legacy.prepare(
            "SELECT planId, epochDay, courseIndex, status FROM plan_course_completion
             WHERE planId = ?1",
        ) else {
            return Ok(());
        };
        let rows: Vec<_> = stmt
            .query_map(params![plan_id], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
            })?
            .flatten()
            .collect();
        rows
    };
    if !completions.is_empty() {
        let mut manual = serde_json::Map::new();
        for (course_plan, epoch_day, index, status) in completions {
            let date = store::date_of_epoch_day(epoch_day)
                .format("%Y-%m-%d")
                .to_string();
            let key = format!("{course_plan}|{date}|{index}");
            manual.insert(key, json!(if status == 0 { 0 } else { 2 }));
        }
        store::settings_set(
            "training_plan_manual_completion_v1",
            &Value::Object(manual).to_string(),
        )?;
    }
    Ok(())
}

/// 旧版「运动记录」列表除了手表本地表，还会合并服务端云端历史
/// （`server_workouts`）。这里把云端汇总也落进新版 workouts 表；有缓存详情的
/// 记录顺带恢复明文轨迹和心率点。手表原始记录优先，同一场运动不重复插入。
fn import_server_workouts(legacy: &Connection, report: &mut LegacyImportReport) -> Result<()> {
    let mut stmt = match legacy.prepare(
        "SELECT originalId, name, sportType, recordType, dataSource, startTimeMillis,
                distanceMeters, durationSec, calories, avgBpm, totalClimbM, trainingLoad
         FROM server_workouts ORDER BY startTimeMillis",
    ) {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, Option<String>>(1)?,
            r.get::<_, Option<String>>(2)?,
            r.get::<_, Option<String>>(3)?,
            r.get::<_, Option<String>>(4)?,
            r.get::<_, i64>(5)?,
            r.get::<_, f64>(6).unwrap_or(0.0),
            r.get::<_, i64>(7).unwrap_or(0),
            r.get::<_, i64>(8).unwrap_or(0),
            r.get::<_, i64>(9).unwrap_or(0),
            r.get::<_, f64>(10).unwrap_or(0.0),
            r.get::<_, f64>(11).unwrap_or(0.0),
        ))
    })?;
    let rows: Vec<_> = rows.flatten().collect();
    if rows.is_empty() {
        return Ok(());
    }

    let details = load_server_workout_details(legacy)?;
    store::with_conn(|conn| {
        conn.execute("DELETE FROM workouts WHERE id LIKE 'legacy-server-%'", [])?;
        Ok(())
    })?;

    for row in rows {
        let (
            original_id,
            name,
            sport_type,
            _record_type,
            _data_source,
            start_ms,
            distance_m,
            duration_sec,
            calories,
            avg_hr,
            total_climb_m,
            training_load,
        ) = row;
        if start_ms <= 0 {
            continue;
        }
        let sport = server_sport_label(sport_type.as_deref(), name.as_deref()).to_string();
        let type_code = server_type_code(&sport);
        let duration_sec = duration_sec.max(0);
        let end_ms = start_ms + duration_sec.max(1) * 1000;
        let id = if original_id.trim().is_empty() {
            format!("legacy-server-{start_ms}")
        } else {
            format!("legacy-server-{}", original_id.trim())
        };
        let detail = details.get(original_id.trim());
        let max_hr = detail.and_then(|d| d.max_hr).unwrap_or(0);
        let avg_pace = if distance_m > 500.0 && duration_sec > 0 {
            Some(duration_sec as f64 / (distance_m / 1000.0))
        } else {
            None
        };
        let track = detail.and_then(|d| d.track_json.clone());
        let samples = detail.and_then(|d| d.samples_json.clone());
        let detail_json = detail.and_then(|d| d.detail_json.clone());
        let start_temp = detail.and_then(|d| d.start_temp_c);
        let start_humidity = detail.and_then(|d| d.start_humidity);
        let vo2max = detail.and_then(|d| d.vo2max);
        let max_met = detail.and_then(|d| d.max_met);
        let avg_pace = detail.and_then(|d| d.avg_pace_sec).or(avg_pace);

        let inserted = store::with_conn(|conn| {
            let existing: Option<(String, Option<String>, Option<String>, Option<String>)> = conn
                .query_row(
                    "SELECT id, track_json, samples_json, detail_json FROM workouts
                     WHERE (id LIKE 'watch-%' OR id LIKE 'legacy-%')
                       AND sport = ?1 AND ABS(start_ms - ?2) <= 120000
                     ORDER BY CASE WHEN id LIKE 'watch-%' THEN 0 ELSE 1 END,
                              ABS(start_ms - ?2)
                     LIMIT 1",
                    params![sport, start_ms],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                )
                .optional()?;
            if let Some((existing_id, existing_track, existing_samples, existing_detail)) = existing
            {
                let merged_track = store::merge_json_point_series(
                    existing_track.as_deref(),
                    track.as_deref(),
                    "t",
                );
                let merged_samples = store::merge_json_point_series(
                    existing_samples.as_deref(),
                    samples.as_deref(),
                    "t",
                );
                let merged_detail =
                    store::richer_json(existing_detail.as_deref(), detail_json.as_deref());
                // 已有手表原始记录时只补云端汇总里更完整的字段，绝不覆盖本地值。
                conn.execute(
                    "UPDATE workouts SET
                        distance_m = CASE WHEN distance_m <= 0 AND ?2 > 0 THEN ?2 ELSE distance_m END,
                        calories = CASE WHEN calories <= 0 AND ?3 > 0 THEN ?3 ELSE calories END,
                        active_calories = CASE WHEN active_calories <= 0 AND ?3 > 0 THEN ?3 ELSE active_calories END,
                        avg_hr = CASE WHEN avg_hr <= 0 AND ?4 > 0 THEN ?4 ELSE avg_hr END,
                        max_hr = CASE WHEN max_hr <= 0 AND ?5 > 0 THEN ?5 ELSE max_hr END,
                        load = CASE WHEN load <= 0 AND ?6 > 0 THEN ?6 ELSE load END,
                        elevation_gain = CASE WHEN (elevation_gain IS NULL OR elevation_gain <= 0) AND ?7 > 0
                                              THEN ?7 ELSE elevation_gain END,
                        total_time_sec = CASE WHEN total_time_sec <= 0 AND ?8 > 0 THEN ?8 ELSE total_time_sec END,
                        avg_pace_sec = COALESCE(avg_pace_sec, ?9),
                        track_json = ?10,
                        samples_json = ?11,
                        detail_json = ?12,
                        start_temp_c = COALESCE(start_temp_c, ?13),
                        start_humidity = COALESCE(start_humidity, ?14),
                        vo2max = COALESCE(vo2max, ?15),
                        max_met = COALESCE(max_met, ?16)
                     WHERE id = ?1",
                    params![
                        existing_id,
                        distance_m,
                        calories,
                        avg_hr,
                        max_hr,
                        training_load.round() as i64,
                        total_climb_m,
                        duration_sec,
                        avg_pace,
                        merged_track,
                        merged_samples,
                        merged_detail,
                        start_temp,
                        start_humidity,
                        vo2max,
                        max_met,
                    ],
                )?;
                return Ok(false);
            }
            conn.execute(
                "INSERT OR REPLACE INTO workouts(
                    id, source, sport, start_ms, end_ms, distance_m, calories, avg_hr, max_hr,
                    steps, load, aerobic_effect, recovery_time_min, track_json, samples_json,
                    synced, created_ms, type_code, total_time_sec, active_calories, max_met,
                    vo2max, anaerobic_effect, elevation_gain, elevation_loss, avg_pace_sec,
                    cadence, detail_json, dynamics_json, altitude_json, recovery_json,
                    start_temp_c, start_humidity)
                 VALUES(?1, 'watch', ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0, ?9, 0, 0, ?10, ?11,
                        1, ?12, ?13, ?14, ?6, ?15, ?16, 0, ?17, NULL, ?18, NULL, ?19,
                        NULL, NULL, NULL, ?20, ?21)",
                params![
                    id,
                    sport,
                    start_ms,
                    end_ms,
                    distance_m,
                    calories,
                    avg_hr,
                    max_hr,
                    training_load.round() as i64,
                    track,
                    samples,
                    now_ms(),
                    type_code,
                    duration_sec,
                    max_met,
                    vo2max,
                    total_climb_m,
                    avg_pace,
                    detail_json,
                    start_temp,
                    start_humidity,
                ],
            )?;
            Ok(true)
        })?;
        if inserted {
            report.workouts += 1;
        }
    }
    Ok(())
}

fn server_sport_label(kind: Option<&str>, name: Option<&str>) -> &'static str {
    match kind.unwrap_or("") {
        "1" => "running",
        "2" => "walking",
        "3" => "cycling",
        "4" => "hiking",
        "5" => "strength",
        "6" => "free_training",
        "7" => "indoor_cycling",
        "8" => "jump_rope",
        "9" => "hiking",
        "10" => "trail_running",
        "11" => "swimming",
        _ => {
            let title = name.unwrap_or("");
            if title.contains("骑行") || title.contains("单车") {
                "cycling"
            } else if title.contains("徒步") || title.contains("登山") {
                "hiking"
            } else if title.contains("游泳") {
                "swimming"
            } else if title.contains("力量") {
                "strength"
            } else if title.contains("跳绳") {
                "jump_rope"
            } else if title.contains("跑") {
                "running"
            } else {
                "workout"
            }
        }
    }
}

fn server_type_code(sport: &str) -> i64 {
    match sport {
        "running" => 1,
        "walking" => 2,
        "cycling" => 3,
        "hiking" => 4,
        "treadmill" => 5,
        "swimming" => 6,
        "indoor_cycling" => 7,
        "climbing" => 9,
        "trail_running" => 10,
        "jump_rope" => 13,
        "strength" => 14,
        "free_training" => 20,
        _ => 0,
    }
}

#[derive(Default, Clone)]
struct ServerDetail {
    detail_json: Option<String>,
    track_json: Option<String>,
    samples_json: Option<String>,
    max_hr: Option<i64>,
    max_met: Option<f64>,
    vo2max: Option<f64>,
    start_temp_c: Option<f64>,
    start_humidity: Option<i64>,
    avg_pace_sec: Option<f64>,
}

fn load_server_workout_details(legacy: &Connection) -> Result<HashMap<String, ServerDetail>> {
    let mut out = HashMap::new();
    let mut stmt = match legacy.prepare("SELECT originalId, detailJson FROM server_workout_details")
    {
        Ok(s) => s,
        Err(_) => return Ok(out),
    };
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
    for (id, raw) in rows.flatten() {
        let Ok(value) = serde_json::from_str::<Value>(&raw) else {
            continue;
        };
        let summary = value.get("summary");
        let num = |k: &str| summary.and_then(|s| s.get(k)).and_then(|v| v.as_f64());
        let int = |k: &str| summary.and_then(|s| s.get(k)).and_then(json_i64);
        let distance_km = num("distance_km").unwrap_or(0.0);
        let duration_sec = num("duration_sec").unwrap_or(0.0);
        let max_met = num("max_met").filter(|v| *v > 0.0);
        let vo2max = value
            .get("vo2max")
            .and_then(|v| v.as_f64())
            .filter(|v| (1.0..=120.0).contains(v))
            .or_else(|| {
                max_met
                    .filter(|v| *v > 0.0)
                    .map(|v| v * 3.5 / 65536.0)
                    .filter(|v| (1.0..=120.0).contains(v))
            });
        let start_ms = int("start_time")
            .or_else(|| value.get("start_ms").and_then(json_i64))
            .unwrap_or(0);
        let (track_json, samples_json) = server_track(&value, start_ms);
        out.insert(
            id.trim().to_string(),
            ServerDetail {
                detail_json: Some(raw),
                track_json,
                samples_json,
                max_hr: int("max_bpm").filter(|v| *v > 0),
                max_met,
                vo2max,
                start_temp_c: num("start_temp_c").filter(|v| *v != -999.0),
                start_humidity: int("start_humidity").filter(|v| *v != -999),
                avg_pace_sec: if distance_km > 0.5 && duration_sec > 0.0 {
                    Some(duration_sec / distance_km)
                } else {
                    None
                },
            },
        );
    }
    Ok(out)
}

fn server_track(value: &Value, fallback_start_ms: i64) -> (Option<String>, Option<String>) {
    let Some(points) = value.get("trkpt").and_then(|v| v.as_array()) else {
        return (None, None);
    };
    let mut track = Vec::new();
    let mut heart = Vec::new();
    for point in points {
        let ts = server_point_ts(point, fallback_start_ms);
        if let Some(bpm) = point.get("heart_rate").and_then(json_i64) {
            if (20..240).contains(&bpm) && ts > 0 {
                heart.push(json!({ "t": ts, "hr": bpm }));
            }
        }
        let (lat, lon) = if let Some(coord) = point.get("coord").and_then(|v| v.as_str()) {
            let Some((lat, lon)) = decrypt_track_coord(coord) else {
                continue;
            };
            (lat, lon)
        } else {
            (
                point
                    .get("position_lat")
                    .and_then(|v| v.as_f64())
                    .unwrap_or(0.0),
                point
                    .get("position_long")
                    .and_then(|v| v.as_f64())
                    .unwrap_or(0.0),
            )
        };
        if lat.abs() < 0.0001 || lon.abs() < 0.0001 {
            // 室内运动没有坐标，但 trkpt 里仍带逐点心率；轨迹不画，心率要保留。
            continue;
        }
        let (gcj_lon, gcj_lat) = bd09_to_gcj02(lon, lat);
        let alt = point.get("altitude").and_then(|v| v.as_f64());
        track.push(json!({ "lat": gcj_lat, "lon": gcj_lon, "t": ts, "alt": alt }));
    }
    let track_json = if track.len() >= 2 {
        Some(Value::Array(track).to_string())
    } else {
        None
    };
    let samples_json = if !heart.is_empty() {
        Some(Value::Array(heart).to_string())
    } else {
        None
    };
    (track_json, samples_json)
}

/// 服务端详情里的 trkpt 坐标自 2026-10 起改成 AES-256-GCM 密文
/// （base64(nonce||ciphertext||tag)，plaintext 为 "lat,lng"）。
/// 旧版 App 同样内置这把客户端密钥；这里解密后再按 BD-09 -> GCJ-02 处理。
fn decrypt_track_coord(encoded: &str) -> Option<(f64, f64)> {
    let payload = base64_decode(encoded)?;
    if payload.len() < 12 + 16 {
        return None;
    }
    let key = hex_decode(include_str!("track_coord_key.hex").trim())?;
    if key.len() != 32 {
        return None;
    }
    let cipher = Aes256Gcm::new_from_slice(&key).ok()?;
    let plain = cipher
        .decrypt(Nonce::from_slice(&payload[..12]), &payload[12..])
        .ok()?;
    let text = std::str::from_utf8(&plain).ok()?;
    let (lat, lon) = text.split_once(',')?;
    Some((lat.trim().parse().ok()?, lon.trim().parse().ok()?))
}

fn hex_decode(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(text.len() / 2);
    let bytes = text.as_bytes();
    for pair in bytes.chunks_exact(2) {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push(((hi << 4) | lo) as u8);
    }
    Some(out)
}

fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let mut buffer = 0u32;
    let mut bits = 0u32;
    for byte in text.bytes() {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            b' ' | b'\n' | b'\r' | b'\t' => continue,
            _ => return None,
        } as u32;
        buffer = (buffer << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
        }
    }
    Some(out)
}

fn server_point_ts(point: &Value, fallback_start_ms: i64) -> i64 {
    let raw = point.get("timestamp").and_then(json_i64).unwrap_or(0);
    if raw > 10_000_000_000 {
        raw
    } else if raw > 1_000_000_000 {
        raw * 1000
    } else if let Some(sec) = point.get("sec").and_then(|v| v.as_f64()) {
        fallback_start_ms + (sec * 1000.0).round() as i64
    } else if raw > 0 {
        raw * 1000
    } else {
        fallback_start_ms
    }
}

fn json_i64(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_f64().map(|v| v.round() as i64))
}

fn bd09_to_gcj02(lng: f64, lat: f64) -> (f64, f64) {
    let x = lng - 0.0065;
    let y = lat - 0.006;
    let z = (x * x + y * y).sqrt() - 0.00002 * (y * std::f64::consts::PI * 3000.0 / 180.0).sin();
    let theta = y.atan2(x) - 0.000003 * (x * std::f64::consts::PI * 3000.0 / 180.0).cos();
    (z * theta.cos(), z * theta.sin())
}

fn workout_dynamics(legacy: &Connection, workout: i64) -> Result<(Option<String>, Option<f64>)> {
    let optional = |name: &str| {
        if legacy_has_column(legacy, "huawei_workout_dynamics_samples", name) {
            name.to_string()
        } else {
            "NULL".to_string()
        }
    };
    let columns = [
        "timestamp".to_string(),
        optional("stepRate"),
        optional("cadence"),
        optional("stepLength"),
        optional("groundContactTime"),
        optional("hangTime"),
        optional("rideCadence"),
        optional("cyclingPower"),
        optional("speed"),
        optional("spo2"),
        optional("vo"),
        optional("gtb"),
        optional("vr"),
    ];
    let sql = format!(
        "SELECT {} FROM huawei_workout_dynamics_samples WHERE workoutId = ?1 ORDER BY timestamp",
        columns.join(", ")
    );
    let mut stmt = match legacy.prepare(&sql) {
        Ok(s) => s,
        Err(_) => return Ok((None, None)),
    };
    let rows = stmt.query_map(params![workout], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, i64>(1).unwrap_or(-1),
            r.get::<_, i64>(2).unwrap_or(-1),
            r.get::<_, i64>(3).unwrap_or(-1),
            r.get::<_, i64>(4).unwrap_or(-1),
            r.get::<_, i64>(5).unwrap_or(-1),
            r.get::<_, i64>(6).unwrap_or(-1),
            r.get::<_, i64>(7).unwrap_or(-1),
            r.get::<_, i64>(8).unwrap_or(-1),
            r.get::<_, i64>(9).unwrap_or(-1),
            r.get::<_, Option<f64>>(10)?,
            r.get::<_, Option<f64>>(11)?,
            r.get::<_, Option<f64>>(12)?,
        ))
    })?;
    let mut points = Vec::new();
    let mut cadence_sum = 0.0;
    let mut cadence_count = 0;
    for (
        ts,
        step_rate,
        ride_cadence,
        step_length,
        ground_contact,
        hang_time,
        cadence_raw,
        power,
        speed,
        spo2,
        vo,
        gtb,
        vr,
    ) in rows.flatten()
    {
        let cadence = if step_rate > 0 {
            step_rate
        } else if ride_cadence > 0 {
            ride_cadence
        } else {
            cadence_raw
        };
        if cadence > 0 {
            cadence_sum += cadence as f64;
            cadence_count += 1;
        }
        let has_metric = cadence > 0
            || power > 0
            || speed > 0
            || step_length > 0
            || ground_contact > 0
            || hang_time > 0
            || spo2 > 0
            || vo.unwrap_or(0.0) > 0.0
            || gtb.unwrap_or(0.0) > 0.0
            || vr.unwrap_or(0.0) > 0.0;
        if !has_metric {
            continue;
        }
        let mut point = json!({
            "t": ts * 1000,
            "cad": if cadence > 0 { cadence } else { 0 },
            "pwr": if power > 0 { power } else { 0 },
            "spd": if speed > 0 { speed as f64 * 0.36 } else { 0.0 },
        });
        if step_length > 0 {
            point["sl"] = json!(step_length);
        }
        if ground_contact > 0 {
            point["gct"] = json!(ground_contact);
        }
        if hang_time > 0 {
            point["ht"] = json!(hang_time);
        }
        if spo2 > 0 {
            point["spo2"] = json!(spo2);
        }
        if let Some(value) = vo.filter(|v| *v > 0.0) {
            point["vo"] = json!(value);
        }
        if let Some(value) = gtb.filter(|v| *v > 0.0) {
            point["gtb"] = json!(if value <= 1.0 { value * 100.0 } else { value });
        }
        if let Some(value) = vr.filter(|v| *v > 0.0) {
            point["vr"] = json!(value);
        }
        points.push(point);
    }
    let avg = if cadence_count > 0 {
        Some(cadence_sum / cadence_count as f64)
    } else {
        None
    };
    let json = if points.is_empty() {
        None
    } else {
        Some(Value::Array(points).to_string())
    };
    Ok((json, avg))
}

fn legacy_pace_zones_json(mins: [Option<i64>; 6], times: [Option<i64>; 5]) -> Option<String> {
    let mut zones = Vec::new();
    for index in 0..5 {
        let min = mins[index].filter(|value| *value > 0);
        let max = mins[index + 1].filter(|value| *value > 0);
        let time = times[index].filter(|value| *value >= 0);
        if min.is_none() && max.is_none() && time.is_none() {
            continue;
        }
        zones.push(json!({
            "zone": index + 1,
            "min": min,
            "max": max,
            "time": time,
        }));
    }
    if zones.is_empty() {
        None
    } else {
        Some(Value::Array(zones).to_string())
    }
}

fn workout_altitude(legacy: &Connection, workout: i64) -> Result<Option<String>> {
    let mut stmt = match legacy.prepare(
        "SELECT timestamp, altitude FROM huawei_workout_altitude_samples
         WHERE workoutId = ?1 AND altitude >= 0 ORDER BY timestamp",
    ) {
        Ok(s) => s,
        Err(_) => return Ok(None),
    };
    let rows = stmt.query_map(params![workout], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
    })?;
    let points: Vec<Value> = rows
        .flatten()
        .map(|(ts, alt)| json!({ "t": ts * 1000, "alt": alt }))
        .collect();
    if points.len() < 2 {
        Ok(None)
    } else {
        Ok(Some(Value::Array(points).to_string()))
    }
}

fn parse_recovery(raw: &str) -> Option<String> {
    let values: Vec<i64> = raw
        .split(',')
        .filter_map(|part| part.trim().parse::<i64>().ok())
        .filter(|bpm| *bpm > 20 && *bpm < 240)
        .collect();
    if values.is_empty() {
        None
    } else {
        Some(Value::Array(values.into_iter().map(Value::from).collect()).to_string())
    }
}

fn workout_samples(legacy: &Connection, workout: i64) -> Result<Option<String>> {
    let mut stmt = match legacy.prepare(
        "SELECT timestamp, bpm FROM huawei_workout_hr_samples WHERE workoutId = ?1 AND bpm > 0 ORDER BY timestamp",
    ) {
        Ok(s) => s,
        Err(_) => return Ok(None),
    };
    let rows = stmt.query_map(params![workout], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
    })?;
    let points: Vec<Value> = rows
        .flatten()
        .filter(|(_, bpm)| *bpm > 20 && *bpm < 240)
        .map(|(ts, bpm)| json!({ "t": ts * 1000, "hr": bpm }))
        .collect();
    if points.is_empty() {
        Ok(None)
    } else {
        Ok(Some(Value::Array(points).to_string()))
    }
}

/// 手表 0x0c 配速分页。type=0 是整公里、type=1 是整英里；
/// `pace` 对 type=0 是秒/公里，对 type=1 是秒/英里，展示层按 type 换算。
/// `correction` 是最后不足一整段的余量，单位 0.1 米（4900 = 490 米）。
fn workout_splits(legacy: &Connection, workout: i64) -> Result<Option<String>> {
    let mut stmt = match legacy.prepare(
        "SELECT paceIndex, distance, type, pace, pointIndex, correction
         FROM huawei_workout_pace_samples
         WHERE workoutId = ?1 AND pace > 0 AND type IN (0, 1)
         ORDER BY type, paceIndex",
    ) {
        Ok(s) => s,
        Err(_) => return Ok(None),
    };
    let rows = stmt.query_map(params![workout], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, i64>(1).unwrap_or(-1),
            r.get::<_, i64>(2).unwrap_or(-1),
            r.get::<_, i64>(3).unwrap_or(-1),
            r.get::<_, i64>(4).unwrap_or(0),
            r.get::<_, Option<i64>>(5)?,
        ))
    })?;
    let points: Vec<Value> = rows
        .flatten()
        .filter(|(_, _, kind, pace, _, _)| matches!(kind, 0 | 1) && *pace > 0)
        .map(|(index, distance, kind, pace, point, correction)| {
            json!({
                "i": index,
                "d": distance,
                "type": kind,
                "pace": pace,
                "point": point,
                "corr": correction,
            })
        })
        .collect();
    if points.is_empty() {
        Ok(None)
    } else {
        Ok(Some(Value::Array(points).to_string()))
    }
}

/// 旧版游泳分段（huawei_workout_swim_segments）转成新版 segments JSON。
/// 字段名对齐手表同步和 Flutter 详情页：segment/distance/pace/strokes/swolf。
fn workout_swim_segments(legacy: &Connection, workout: i64) -> Result<Option<String>> {
    let mut stmt = match legacy.prepare(
        "SELECT segment, distanceMeters, paceSecPer100m, strokes, avgSwolf
         FROM huawei_workout_swim_segments
         WHERE workoutId = ?1 AND distanceMeters > 0
         ORDER BY segment",
    ) {
        Ok(s) => s,
        Err(_) => return Ok(None),
    };
    let rows = stmt.query_map(params![workout], |r| {
        Ok((
            r.get::<_, i64>(0).unwrap_or(0),
            r.get::<_, i64>(1).unwrap_or(0),
            r.get::<_, i64>(2).unwrap_or(0),
            r.get::<_, i64>(3).unwrap_or(0),
            r.get::<_, i64>(4).unwrap_or(0),
        ))
    })?;
    let segments: Vec<Value> = rows
        .flatten()
        .filter(|(_, distance, _, _, _)| *distance > 0)
        .map(|(segment, distance, pace, strokes, swolf)| {
            json!({
                "segment": segment,
                "distance": distance,
                "pace": pace,
                "strokes": strokes,
                "swolf": swolf,
            })
        })
        .collect();
    if segments.is_empty() {
        Ok(None)
    } else {
        Ok(Some(Value::Array(segments).to_string()))
    }
}

/// 旧库的 stat_extend 是 detail_json 的主体；游泳分段要补进同一对象，
/// 不能整段覆盖，否则会丢心率区间、训练积分等扩展统计。
fn detail_with_segments(stat_extend: Option<&str>, segments: Option<&str>) -> Option<String> {
    let segments = segments
        .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
        .filter(|value| value.as_array().map(|a| !a.is_empty()).unwrap_or(false));
    let Some(segments) = segments else {
        return stat_extend.map(str::to_string);
    };
    let mut object = stat_extend
        .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    object.insert("segments".to_string(), segments);
    Some(Value::Object(object).to_string())
}

/// 合并已同步行的 detail_json：已有字段优先，只补缺失字段；
/// splits/segments 这类数组按 item 键去重合并。
fn merge_detail_json(existing: Option<&str>, incoming: Option<&str>) -> Option<String> {
    let existing = match existing.and_then(|raw| serde_json::from_str::<Value>(raw).ok()) {
        Some(Value::Object(object)) => object,
        _ => return incoming.map(str::to_string),
    };
    let Some(incoming) = incoming.and_then(|raw| serde_json::from_str::<Value>(raw).ok()) else {
        return Some(Value::Object(existing).to_string());
    };
    let mut merged = existing;
    if let Value::Object(incoming_object) = incoming {
        for (key, value) in incoming_object {
            match merged.get_mut(&key) {
                None => {
                    merged.insert(key, value);
                }
                Some(current) => {
                    if current.as_array().map(|a| a.is_empty()).unwrap_or(true)
                        && value.as_array().map(|a| !a.is_empty()).unwrap_or(false)
                    {
                        *current = value;
                    } else if matches!(key.as_str(), "splits" | "segments" | "swim_segments") {
                        *current = merge_detail_array(current, &value);
                    }
                }
            }
        }
    }
    Some(Value::Object(merged).to_string())
}

fn merge_detail_array(current: &Value, incoming: &Value) -> Value {
    let (Some(mut current), Some(incoming)) = (current.as_array().cloned(), incoming.as_array())
    else {
        return current.clone();
    };
    let item_key = |value: &Value| {
        value
            .get("i")
            .or_else(|| value.get("segment"))
            .and_then(|v| v.as_i64())
    };
    let mut seen: std::collections::HashSet<i64> = current.iter().filter_map(item_key).collect();
    for item in incoming {
        match item_key(item) {
            Some(key) if seen.insert(key) => current.push(item.clone()),
            Some(_) => {}
            None => current.push(item.clone()),
        }
    }
    Value::Array(current)
}

fn normalize_track(raw: &str) -> Option<String> {
    let value: Value = serde_json::from_str(raw).ok()?;
    let items = value.as_array()?;
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        let lat = item.get("lat").and_then(|v| v.as_f64())?;
        let lng = item
            .get("lon")
            .or_else(|| item.get("lng"))
            .and_then(|v| v.as_f64())?;
        if !(-90.0..=90.0).contains(&lat)
            || !(-180.0..=180.0).contains(&lng)
            || (lat.abs() < 0.0001 && lng.abs() < 0.0001)
        {
            continue;
        }
        let ts = item.get("t").and_then(|v| v.as_i64()).unwrap_or(0) * 1000;
        let alt = item.get("alt").and_then(|v| v.as_f64());
        out.push(json!({ "lat": lat, "lon": lng, "t": ts, "alt": alt }));
    }
    if out.len() < 2 {
        None
    } else {
        Some(Value::Array(out).to_string())
    }
}

pub fn legacy_db_available(path: &str) -> bool {
    std::path::Path::new(path).is_file()
}

/// 旧版服务端详情里的轨迹是加密的 coord。早期迁移只认明文
/// position_lat/position_long，导致已经迁移过的用户仍然没有云端轨迹。
/// 这里直接在现有 workouts.detail_json 上补一次，不重跑整库导入，
/// 也不会把用户删掉的运动记录重新插回来。
pub fn backfill_encrypted_workout_tracks() -> Result<i64> {
    if store::settings_get("server_track_decrypt_v1", "")
        .map(|v| v == "1")
        .unwrap_or(false)
    {
        return Ok(0);
    }
    let rows: Vec<(String, String)> = store::with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, detail_json FROM workouts
             WHERE detail_json IS NOT NULL AND detail_json <> ''
               AND (track_json IS NULL OR track_json = '' OR track_json = '[]'
                    OR samples_json IS NULL OR samples_json = '')",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })?;
    let mut updated = 0i64;
    for (id, raw) in rows {
        let Ok(value) = serde_json::from_str::<Value>(&raw) else {
            continue;
        };
        let start_ms = value
            .get("summary")
            .and_then(|s| s.get("start_time"))
            .and_then(|v| v.as_i64())
            .or_else(|| value.get("start_ms").and_then(|v| v.as_i64()))
            .unwrap_or(0);
        let (track, samples) = server_track(&value, start_ms);
        if track.is_none() && samples.is_none() {
            continue;
        }
        updated += store::with_conn(|conn| {
            Ok(conn.execute(
                "UPDATE workouts SET
                    track_json = CASE
                        WHEN (track_json IS NULL OR track_json = '' OR track_json = '[]')
                             AND ?2 IS NOT NULL THEN ?2
                        ELSE track_json END,
                    samples_json = CASE
                        WHEN (samples_json IS NULL OR samples_json = '')
                             AND ?3 IS NOT NULL THEN ?3
                        ELSE samples_json END
                 WHERE id = ?1",
                params![id, track, samples],
            )? as i64)
        })?;
    }
    store::settings_set("server_track_decrypt_v1", "1")?;
    Ok(updated)
}

/// 首次启动时尝试从应用目录下的 `legacy/` 文件夹导入旧版数据。
pub fn auto_import_near(db_path: &str) -> Result<Option<LegacyImportReport>> {
    let Some(dir) = std::path::Path::new(db_path).parent() else {
        return Ok(None);
    };
    let folder = dir.join("legacy");
    let legacy_db = folder.join("health_sync.db");
    if !legacy_db.is_file() {
        return Ok(None);
    }
    let imported = store::settings_get("legacy_import_at", "")
        .map(|v| !v.is_empty())
        .unwrap_or(false);
    if imported {
        // 早期迁移只导入了旧库数据，没有把手表身份写进 settings。设备级
        // device_prefs.xml 里就存着 authkey / huawei_account / fake_android_id，
        // 新版没有它们会把已配对手表误判成首次 HiChain，认证卡在 authenticating。
        backfill_watch_identity(&folder)?;
        // 新版本才接的三类 P2P 数据（呼吸暂停/每小时状态/每日三环）需要给老用户补一次；
        // 只做这一件事，不重跑整套导入，避免重复计算。
        let backfilled = store::settings_get("p2p_backfill_done", "")
            .map(|v| v == "1")
            .unwrap_or(false);
        if !backfilled {
            let legacy = Connection::open_with_flags(&legacy_db, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            import_p2p(&legacy)?;
            store::settings_set("p2p_backfill_done", "1")?;
        }
        // 早期迁移只覆盖了手表汇总和服务端历史，手机端自录轨迹、力量模板和
        // 旧训练计划是后补的；给已经迁移过的用户补一次，避免他们只能重装。
        let extra = store::settings_get("legacy_extra_backfill_done", "")
            .map(|v| v == "1")
            .unwrap_or(false);
        if !extra {
            let legacy = Connection::open_with_flags(&legacy_db, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            let mut report = LegacyImportReport {
                ok: false,
                already_imported: true,
                message: String::new(),
                days: 0,
                heart_rate_points: 0,
                sleep_sessions: 0,
                workouts: 0,
                weights: 0,
                blood_pressure: 0,
                glucose: 0,
                emotions: 0,
                samples: 0,
                identity: false,
                profile: false,
                goals: false,
            };
            import_sessions(&legacy, &mut report)?;
            import_strength(&legacy)?;
            import_training_plan(&legacy)?;
            store::settings_set("legacy_extra_backfill_done", "1")?;
        }
        // v2：睡眠 HRV、逐分钟步数、保存的路线和官方配速分段。老用户只补一次，
        // 且只更新已有运动行，避免重新插入已删除记录。
        let v2 = store::settings_get("legacy_backfill_v2_done", "")
            .map(|v| v == "1")
            .unwrap_or(false);
        if !v2 {
            let legacy = Connection::open_with_flags(&legacy_db, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            let mut days = HashMap::new();
            let mut report = LegacyImportReport {
                ok: false,
                already_imported: true,
                message: String::new(),
                days: 0,
                heart_rate_points: 0,
                sleep_sessions: 0,
                workouts: 0,
                weights: 0,
                blood_pressure: 0,
                glucose: 0,
                emotions: 0,
                samples: 0,
                identity: false,
                profile: false,
                goals: false,
            };
            import_sleep_hrv(&legacy, &mut days, &mut report)?;
            import_fitness_samples(&legacy)?;
            import_saved_routes(&folder)?;
            backfill_workout_splits(&legacy)?;
            flush_day_aggregates(&days)?;
            store::settings_set("legacy_backfill_v2_done", "1")?;
        }
        // 首次迁移后旧库里还可能继续写入腕温/核心体温。这两张表是独立样本，
        // 增量补一次不会重复计算睡眠或运动，也能把最新的腕温带进首页卡片。
        let temps = store::settings_get("legacy_temp_backfill_done", "")
            .map(|v| v == "1")
            .unwrap_or(false);
        if !temps {
            let legacy = Connection::open_with_flags(&legacy_db, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            backfill_temperature_samples(&legacy)?;
            store::settings_set("legacy_temp_backfill_done", "1")?;
        }
        // 旧版在线温度接口统一 -2°C 后写进皮肤温度表，导致 36.x 的核心体温
        // 变成 34.x；29.x 的腕温减 2 后是真实值，不用动。给老用户就地修一次。
        let temp_repair = store::settings_get("legacy_temp_repair_v1", "")
            .map(|v| v == "1")
            .unwrap_or(false);
        if !temp_repair {
            let legacy = Connection::open_with_flags(&legacy_db, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            repair_temperature_samples(&legacy)?;
            store::settings_set("legacy_temp_repair_v1", "1")?;
        }
        // 旧版静态个人纪录（尤其 5K/10K/半马）之前没有导入；给老用户补一次。
        let personal = store::settings_get("legacy_personal_records_v1", "")
            .map(|v| v == "1")
            .unwrap_or(false);
        if !personal {
            let legacy = Connection::open_with_flags(&legacy_db, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            import_personal_records(&legacy)?;
            store::settings_set("legacy_personal_records_v1", "1")?;
        }
        // 早期睡眠导入用 45 分钟聚类，白天小睡容易被并进低密度长片段后丢掉。
        // 只补旧库 source 13 的小睡，不重跑整套导入，避免覆盖后续手表数据。
        let naps = store::settings_get("legacy_daytime_nap_backfill_v1", "")
            .map(|v| v == "1")
            .unwrap_or(false);
        if !naps {
            let legacy = Connection::open_with_flags(&legacy_db, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            backfill_daytime_naps(&legacy)?;
            store::settings_set("legacy_daytime_nap_backfill_v1", "1")?;
        }
        return Ok(None);
    }
    let read = |name: &str| std::fs::read_to_string(folder.join(name)).unwrap_or_default();
    let config = read_prefs_config(
        &read("device_prefs.xml"),
        &read("prefs.xml"),
        &read("user_profile_settings.xml"),
        &read("activity_goals.xml"),
        &read("heart_rate_settings.xml"),
        &read("ephemeris_prefs.xml"),
    );
    let report = import(legacy_db.to_str().unwrap_or_default(), &config)?;
    store::settings_set("p2p_backfill_done", "1")?;
    store::settings_set("legacy_extra_backfill_done", "1")?;
    store::settings_set("legacy_backfill_v2_done", "1")?;
    store::settings_set("legacy_personal_records_v1", "1")?;
    Ok(Some(report))
}

fn backfill_watch_identity(folder: &Path) -> Result<()> {
    let current = store::watch_identity()?;
    if !current.auth_key.is_empty() {
        return Ok(());
    }
    let read = |name: &str| std::fs::read_to_string(folder.join(name)).unwrap_or_default();
    let config: Value = serde_json::from_str(&read_prefs_config(
        &read("device_prefs.xml"),
        &read("prefs.xml"),
        "",
        "",
        "",
        "",
    ))?;
    let watch = config.get("watch").cloned().unwrap_or(Value::Null);
    let auth_key = str_of(&watch, "auth_key");
    if auth_key.is_empty() {
        return Ok(());
    }
    let address = str_of(&watch, "address");
    let name = str_of(&watch, "name");
    store::save_watch_identity(WatchIdentity {
        address: if address.is_empty() {
            current.address
        } else {
            address
        },
        name: if name.is_empty() { current.name } else { name },
        account: str_of(&watch, "account"),
        auth_key,
        fake_android_id: str_of(&watch, "fake_android_id"),
        huawei_address: str_of(&watch, "huawei_address"),
        last_sync_ms: watch.get("last_sync_ms").and_then(|v| v.as_i64()),
        migrated: true,
        ephemeris_url: current.ephemeris_url,
    })?;
    Ok(())
}

pub fn read_prefs_config(
    device_prefs_xml: &str,
    global_prefs_xml: &str,
    profile_xml: &str,
    goals_xml: &str,
    heart_xml: &str,
    ephemeris_xml: &str,
) -> String {
    let device = parse_xml_map(device_prefs_xml);
    let global = parse_xml_map(global_prefs_xml);
    let profile = parse_xml_map(profile_xml);
    let goals = parse_xml_map(goals_xml);
    let heart = parse_xml_map(heart_xml);
    let ephemeris = parse_xml_map(ephemeris_xml);
    let get = |map: &HashMap<String, String>, key: &str| map.get(key).cloned().unwrap_or_default();
    json!({
        "watch": {
            "address": get(&global, "huawei_last_address"),
            "name": get(&global, "huawei_last_name"),
            "account": get(&device, "huawei_account"),
            "auth_key": get(&device, "authkey"),
            "fake_android_id": get(&device, "fake_android_id"),
            "huawei_address": get(&device, "huawei_address"),
            "last_sync_ms": get(&device, "last_sync_start").parse::<i64>().unwrap_or(0),
            // 星历地址在旧版是独立的一个 prefs 文件，用户自己填过一次，不该让他再填第二遍
            "ephemeris_url": get(&ephemeris, "ephemeris_url"),
        },
        "profile": {
            "nickname": get(&profile, "nickname"),
            "gender": get(&profile, "gender"),
            "height_cm": get(&profile, "height_cm").parse::<f64>().unwrap_or(170.0),
            "weight_kg": get(&profile, "weight_kg").parse::<f64>().unwrap_or(65.0),
            "birth_date": get(&profile, "birth_date"),
        },
        "goals": {
            "steps": get(&goals, "steps").parse::<i64>().unwrap_or(10_000),
            "calories": get(&goals, "calories").parse::<i64>().unwrap_or(500),
            "active_minutes": get(&goals, "active_minutes").parse::<i64>().unwrap_or(60),
        },
        "heart": {
            "max_hr": get(&heart, "max_hr").parse::<i64>().unwrap_or(190),
            "resting_hr": get(&heart, "resting_hr").parse::<i64>().unwrap_or(53),
        }
    })
    .to_string()
}

fn parse_xml_map(xml: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut rest = xml;
    while let Some(start) = rest.find("<string name=\"") {
        let after = &rest[start + 14..];
        let Some(name_end) = after.find('"') else {
            break;
        };
        let name = &after[..name_end];
        let Some(tag_end) = after.find('>') else {
            break;
        };
        let Some(value_end) = after[tag_end..].find("</string>") else {
            break;
        };
        let value = &after[tag_end + 1..tag_end + value_end];
        out.insert(name.to_string(), unescape(value));
        rest = &after[tag_end + value_end + 9..];
    }
    let mut rest = xml;
    while let Some(start) = rest.find("<int name=\"") {
        let after = &rest[start + 11..];
        let Some(name_end) = after.find('"') else {
            break;
        };
        let name = &after[..name_end];
        let Some(value_start) = after.find("value=\"") else {
            break;
        };
        let after_value = &after[value_start + 7..];
        let Some(value_end) = after_value.find('"') else {
            break;
        };
        out.insert(name.to_string(), after_value[..value_end].to_string());
        rest = &after_value[value_end..];
    }
    let mut rest = xml;
    while let Some(start) = rest.find("<long name=\"") {
        let after = &rest[start + 12..];
        let Some(name_end) = after.find('"') else {
            break;
        };
        let name = &after[..name_end];
        let Some(value_start) = after.find("value=\"") else {
            break;
        };
        let after_value = &after[value_start + 7..];
        let Some(value_end) = after_value.find('"') else {
            break;
        };
        out.insert(name.to_string(), after_value[..value_end].to_string());
        rest = &after_value[value_end..];
    }
    let mut rest = xml;
    while let Some(start) = rest.find("<float name=\"") {
        let after = &rest[start + 13..];
        let Some(name_end) = after.find('"') else {
            break;
        };
        let name = &after[..name_end];
        let Some(value_start) = after.find("value=\"") else {
            break;
        };
        let after_value = &after[value_start + 7..];
        let Some(value_end) = after_value.find('"') else {
            break;
        };
        out.insert(name.to_string(), after_value[..value_end].to_string());
        rest = &after_value[value_end..];
    }
    out
}

fn unescape(value: &str) -> String {
    value
        .replace("&quot;", "\"")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn swim_segments_are_merged_into_detail_json() {
        let legacy = Connection::open_in_memory().unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE huawei_workout_swim_segments(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    workoutId INTEGER NOT NULL,
                    segment INTEGER NOT NULL,
                    distanceMeters INTEGER NOT NULL,
                    paceSecPer100m INTEGER NOT NULL,
                    strokes INTEGER NOT NULL,
                    avgSwolf INTEGER NOT NULL,
                    timeSec INTEGER NOT NULL,
                    swimType INTEGER NOT NULL
                );
                INSERT INTO huawei_workout_swim_segments
                    (workoutId, segment, distanceMeters, paceSecPer100m, strokes, avgSwolf, timeSec, swimType)
                VALUES (7, 1, 50, 120, 24, 42, 60, 1),
                       (7, 2, 100, 118, 46, 40, 118, 1);",
            )
            .unwrap();

        let segments = workout_swim_segments(&legacy, 7)
            .unwrap()
            .expect("swim segments should be exported");
        let detail = detail_with_segments(Some(r#"{"max_met":8.9}"#), Some(&segments))
            .expect("detail json should be produced");
        let value: Value = serde_json::from_str(&detail).unwrap();
        assert_eq!(value["max_met"], 8.9);
        assert_eq!(value["segments"].as_array().unwrap().len(), 2);
        assert_eq!(value["segments"][1]["distance"], 100);
        assert_eq!(value["segments"][1]["pace"], 118);
        assert_eq!(value["segments"][1]["swolf"], 40);

        let merged = merge_detail_json(
            Some(r#"{"splits":[{"i":1,"pace":300}],"segments":[{"segment":1,"distance":50}]}"#),
            Some(&detail),
        )
        .unwrap();
        let merged: Value = serde_json::from_str(&merged).unwrap();
        assert_eq!(merged["splits"].as_array().unwrap().len(), 1);
        assert_eq!(merged["segments"].as_array().unwrap().len(), 2);
        assert_eq!(merged["max_met"], 8.9);
    }

    #[test]
    fn decrypts_encrypted_server_track_coordinates() {
        let encoded = "AAECAwQFBgcICQoLxZxDrX2nGD8qlnzEcbHzgRJY14+sY5HjQGl+iWy9lnigTJxd";
        let (lat, lon) = decrypt_track_coord(encoded).expect("coord should decrypt");
        assert!((lat - 30.123456).abs() < 1e-6, "lat={lat}");
        assert!((lon - 120.654321).abs() < 1e-6, "lon={lon}");

        let detail = json!({
            "trkpt": [
                {"coord": encoded, "timestamp": 1_793_000_000.0, "heart_rate": 120.0},
                {"coord": encoded, "timestamp": 1_793_000_030.0, "heart_rate": 121.0}
            ]
        });
        let (track, samples) = server_track(&detail, 0);
        let track: Value = serde_json::from_str(track.as_deref().unwrap()).unwrap();
        let samples: Value = serde_json::from_str(samples.as_deref().unwrap()).unwrap();
        assert_eq!(track.as_array().unwrap().len(), 2);
        assert_eq!(samples.as_array().unwrap().len(), 2);
        assert_eq!(samples[0]["t"], 1_793_000_000_000_i64);
        assert_eq!(samples[0]["hr"], 120);
        let lat = track[0]["lat"].as_f64().unwrap();
        let lon = track[0]["lon"].as_f64().unwrap();
        assert!((29.9..30.3).contains(&lat) && (120.4..120.8).contains(&lon));
    }

    #[test]
    fn backfills_encrypted_server_tracks_for_already_migrated_users() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let db = std::env::temp_dir().join(format!(
            "vitaloop-server-track-backfill-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&db);
        store::open(db.to_str().unwrap()).unwrap();

        let encoded = "AAECAwQFBgcICQoLxZxDrX2nGD8qlnzEcbHzgRJY14+sY5HjQGl+iWy9lnigTJxd";
        let detail = json!({
            "summary": {"start_time": 1_793_000_000_i64},
            "trkpt": [
                {"coord": encoded, "timestamp": 1_793_000_000_i64},
                {"coord": encoded, "timestamp": 1_793_000_030_i64}
            ]
        })
        .to_string();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO workouts(id, source, sport, start_ms, end_ms, created_ms, detail_json)
                 VALUES('legacy-server-1793000000', 'watch', 'running',
                        1793000000000, 1793000030000, 1, ?1)",
                params![detail],
            )?;
            Ok(())
        })
        .unwrap();

        assert_eq!(backfill_encrypted_workout_tracks().unwrap(), 1);
        let track: String = store::with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT track_json FROM workouts WHERE id = 'legacy-server-1793000000'",
                [],
                |r| r.get(0),
            )?)
        })
        .unwrap();
        assert!(track.contains("\"lat\"") && track.contains("\"lon\""));
        assert_eq!(backfill_encrypted_workout_tracks().unwrap(), 0);

        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn merges_split_weight_packets_across_minute_boundary() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let db =
            std::env::temp_dir().join(format!("vitaloop-weight-merge-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&db);
        store::open(db.to_str().unwrap()).unwrap();

        let base = 1_793_144_185_359_i64;
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO weight_records(id, timestamp_ms, weight_kg, source)
                 VALUES('weight-basic', ?1, 69.4, 'scale')",
                params![base],
            )?;
            conn.execute(
                "INSERT INTO weight_records(
                    id, timestamp_ms, weight_kg, body_fat_percent, muscle_percent,
                    water_percent, resistance_ohm, body_composition_model, source,
                    device_name)
                 VALUES('weight-full', ?1, 69.4, 28.5, 67.0, 50.1, 587.0,
                        'segal_3b_male_ge20', 'scale', 'AFU-WL-TZ-A1')",
                params![base + 11_342],
            )?;
            conn.execute(
                "INSERT INTO weight_records(id, timestamp_ms, weight_kg, source)
                 VALUES('weight-next-measurement', ?1, 69.4, 'scale')",
                params![base + 60_001],
            )?;
            Ok(())
        })
        .unwrap();

        store::with_conn(dedupe_weights).unwrap();

        let rows = store::weights(10).unwrap();
        assert_eq!(rows.len(), 2, "60 秒内拆分包应合并，超过 60 秒不应误合并");
        let merged = rows
            .iter()
            .find(|row| row.id == "weight-basic")
            .expect("最早时间戳的记录应作为主记录");
        assert_eq!(merged.timestamp_ms, base);
        assert_eq!(merged.body_fat_percent, Some(28.5));
        assert_eq!(merged.resistance_ohm, Some(587.0));
        assert_eq!(merged.device_name.as_deref(), Some("AFU-WL-TZ-A1"));

        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn backfills_temperature_samples_for_already_imported_users() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!(
            "vitaloop-temperature-backfill-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("legacy")).unwrap();
        let legacy_db = dir.join("legacy/health_sync.db");
        let legacy = Connection::open(&legacy_db).unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE huawei_temperature_records(
                    timestamp INTEGER PRIMARY KEY,
                    valueCelsiusX100 INTEGER NOT NULL,
                    isSynced INTEGER NOT NULL DEFAULT 0
                 );
                 CREATE TABLE huawei_body_temperature_records(
                    timestamp INTEGER PRIMARY KEY,
                    valueCelsiusX100 INTEGER NOT NULL
                 );
                 CREATE TABLE sport_personal_records(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    sportType INTEGER NOT NULL,
                    metric TEXT NOT NULL,
                    value REAL NOT NULL,
                    workoutNumber INTEGER NOT NULL,
                    achievedAtSec INTEGER NOT NULL,
                    updatedAtSec INTEGER NOT NULL
                 );
                 INSERT INTO huawei_temperature_records VALUES(1793488800000, 2770, 1);
                 INSERT INTO huawei_temperature_records VALUES(1793697840000, 3440, 1);
                 INSERT INTO huawei_body_temperature_records VALUES(1793697840000, 3640);
                 INSERT INTO sport_personal_records(
                    sportType, metric, value, workoutNumber, achievedAtSec, updatedAtSec
                 ) VALUES(1, 'LONGEST_DISTANCE', 21450, 0, 1790000000, 1790000000);",
            )
            .unwrap();
        drop(legacy);

        let db = dir.join("vitaloop.db");
        store::open(db.to_str().unwrap()).unwrap();
        store::settings_set("legacy_import_at", "1").unwrap();
        store::settings_set("p2p_backfill_done", "1").unwrap();
        store::settings_set("legacy_extra_backfill_done", "1").unwrap();
        store::settings_set("legacy_backfill_v2_done", "1").unwrap();

        auto_import_near(db.to_str().unwrap()).unwrap();

        let (skin, body): (Option<(f64, i64)>, Option<(f64, i64)>) = store::with_conn(|conn| {
            Ok((
                conn.query_row(
                    "SELECT value, ts_ms FROM metric_points
                         WHERE metric = 'skin_temp' ORDER BY ts_ms DESC LIMIT 1",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?,
                conn.query_row(
                    "SELECT value, ts_ms FROM metric_points
                         WHERE metric = 'body_temp' ORDER BY ts_ms DESC LIMIT 1",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?,
            ))
        })
        .unwrap();

        // 服务端 29.7 是「皮肤温度 27.7 + 2」的展示值，旧版减 2 后本来就是
        // 正确的腕温，不能再加回去；34.4 才是核心体温 36.4 被减 2 的脏值。
        assert_eq!(skin, Some((27.7, 1_793_488_800_000)));
        assert_eq!(body, Some((36.4, 1_793_697_840_000)));
        let legacy_record: f64 = store::with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT value FROM legacy_personal_records
                 WHERE sport = 'running' AND metric = 'longest'",
                [],
                |r| r.get(0),
            )?)
        })
        .unwrap();
        assert!(
            (legacy_record - 21.45).abs() < 0.001,
            "已导入用户也应补上旧版个人纪录"
        );
        assert_eq!(
            store::settings_get("legacy_temp_backfill_done", "").unwrap(),
            "1"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn backfills_watch_identity_for_already_imported_users() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!(
            "vitaloop-watch-identity-backfill-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("legacy")).unwrap();
        Connection::open(dir.join("legacy/health_sync.db")).unwrap();
        std::fs::write(
            dir.join("legacy/device_prefs.xml"),
            r#"<?xml version='1.0' encoding='utf-8' standalone='yes' ?><map>
<string name="authkey">00112233445566778899aabbccddeeff</string>
<string name="huawei_account">test@example.com</string>
<string name="fake_android_id">00112233445566778899aabbccddeeff</string>
<string name="huawei_address">B0:FE:E5:D2:3D:E1</string>
<string name="last_sync_start">1793697840000</string>
</map>"#,
        )
        .unwrap();
        std::fs::write(
            dir.join("legacy/prefs.xml"),
            r#"<?xml version='1.0' encoding='utf-8' standalone='yes' ?><map>
<string name="huawei_last_address">B0:FE:E5:D2:3D:E1</string>
<string name="huawei_last_name">HUAWEI WATCH GT 5</string>
</map>"#,
        )
        .unwrap();

        let db = dir.join("vitaloop.db");
        store::open(db.to_str().unwrap()).unwrap();
        for key in [
            "legacy_import_at",
            "p2p_backfill_done",
            "legacy_extra_backfill_done",
            "legacy_backfill_v2_done",
            "legacy_temp_backfill_done",
            "legacy_temp_repair_v1",
            "legacy_personal_records_v1",
        ] {
            store::settings_set(key, "1").unwrap();
        }

        auto_import_near(db.to_str().unwrap()).unwrap();

        let identity = store::watch_identity().unwrap();
        assert_eq!(identity.address, "B0:FE:E5:D2:3D:E1");
        assert_eq!(identity.name, "HUAWEI WATCH GT 5");
        assert_eq!(identity.account, "test@example.com");
        assert_eq!(identity.auth_key, "00112233445566778899aabbccddeeff");
        assert_eq!(identity.fake_android_id, "00112233445566778899aabbccddeeff");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn imports_real_legacy_database() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../.legacy/health_sync.db");
        if !std::path::Path::new(path).is_file() {
            return;
        }
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let db =
            std::env::temp_dir().join(format!("vitaloop-legacy-test-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&db);
        store::open(db.to_str().unwrap()).unwrap();
        let config = read_prefs_config(
            &std::fs::read_to_string(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../.legacy/device_prefs.xml"
            ))
            .unwrap(),
            &std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../.legacy/prefs.xml"))
                .unwrap(),
            &std::fs::read_to_string(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../.legacy/user_profile_settings.xml"
            ))
            .unwrap(),
            &std::fs::read_to_string(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../.legacy/activity_goals.xml"
            ))
            .unwrap(),
            &std::fs::read_to_string(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../.legacy/heart_rate_settings.xml"
            ))
            .unwrap(),
            &std::fs::read_to_string(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../.legacy/ephemeris_prefs.xml"
            ))
            .unwrap_or_default(),
        );
        let report = import(path, &config).unwrap();
        assert!(report.ok, "{}", report.message);
        assert!(
            report.heart_rate_points > 10_000,
            "{}",
            report.heart_rate_points
        );
        assert!(report.sleep_sessions > 10);
        assert!(report.workouts >= 450, "{}", report.workouts);
        assert!(report.identity);
        let identity = store::watch_identity().unwrap();
        assert_eq!(identity.address, "B0:FE:E5:D2:3D:E1");
        assert!(identity.auth_key.starts_with("769a"));
        let temps: (Option<f64>, Option<f64>) = store::with_conn(|c| {
            Ok((
                c.query_row(
                    "SELECT value FROM metric_points
                     WHERE metric = 'skin_temp' ORDER BY ts_ms DESC LIMIT 1",
                    [],
                    |r| r.get(0),
                )
                .optional()?,
                c.query_row(
                    "SELECT value FROM metric_points
                     WHERE metric = 'body_temp' ORDER BY ts_ms DESC LIMIT 1",
                    [],
                    |r| r.get(0),
                )
                .optional()?,
            ))
        })
        .unwrap();
        assert_eq!(
            temps.0,
            Some(27.7),
            "29.7 是皮肤温度 +2 的展示值，真实腕温是 27.7"
        );
        assert_eq!(temps.1, Some(36.4), "核心体温不应被当成腕温");
        eprintln!(
            "report: days={} hr={} sleep={} workouts={} weights={} bp={} glucose={} samples={}",
            report.days,
            report.heart_rate_points,
            report.sleep_sessions,
            report.workouts,
            report.weights,
            report.blood_pressure,
            report.glucose,
            report.samples
        );
        let count: i64 = store::with_conn(|c| {
            Ok(c.query_row("SELECT COUNT(*) FROM weight_records", [], |r| r.get(0))?)
        })
        .unwrap();
        eprintln!("weight rows: {count}");
        assert_eq!(count, 13, "体脂秤拆分包应合并为 13 次测量");
        let health: (i64, i64, i64) = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT (SELECT COUNT(*) FROM blood_pressure_records),
                        (SELECT COUNT(*) FROM blood_glucose_records),
                        (SELECT COUNT(*) FROM hrv_records)",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?)
        })
        .unwrap();
        assert_eq!(health.0, 18, "血压历史迁移后应保留 18 个独立测量时间点");
        assert_eq!(health.1, 6, "血糖历史迁移后应保留 6 次测量");
        assert!(health.2 >= 2000, "HRV 逐条历史没有迁移: {}", health.2);
        let dynamics: i64 = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT json_array_length(dynamics_json) FROM workouts
                 WHERE id = 'legacy-40270'",
                [],
                |r| r.get(0),
            )?)
        })
        .unwrap();
        assert_eq!(dynamics, 412, "40270 的动态采样点应全部迁移");
        let sleep_hrv: (i64, Option<f64>) = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT COUNT(*),
                        (SELECT avg_hrv FROM sleep_hrv_records ORDER BY date_day DESC LIMIT 1)
                 FROM sleep_hrv_records",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?)
        })
        .unwrap();
        assert_eq!(sleep_hrv, (5, Some(54.0)), "官方睡眠 HRV 没有迁移");
        let step_samples: i64 = store::with_conn(|c| {
            Ok(c.query_row("SELECT COUNT(*) FROM step_samples", [], |r| r.get(0))?)
        })
        .unwrap();
        assert!(step_samples > 10_000, "逐分钟步数没有迁移: {step_samples}");
        let splits: Option<String> = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT splits_json FROM workouts WHERE id = 'legacy-40207'",
                [],
                |r| r.get(0),
            )
            .optional()?)
        })
        .unwrap();
        let splits: Value = serde_json::from_str(&splits.expect("40207 官方分段丢失")).unwrap();
        let km: Vec<&Value> = splits
            .as_array()
            .unwrap()
            .iter()
            .filter(|v| v["type"].as_i64() == Some(0))
            .collect();
        assert_eq!(km.len(), 20, "40207 应有 19 个整公里 + 1 个尾段");
        assert_eq!(km.first().unwrap()["pace"].as_i64(), Some(250));
        assert_eq!(km.last().unwrap()["corr"].as_i64(), Some(4900));
        // 11-03 13:09 的 17 分钟午睡必须单独成场，不能被白天碎片裹进长片段后丢掉。
        let nap_from = Local
            .with_ymd_and_hms(2026, 11, 3, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let nap: Option<(i64, f64)> = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT start_ms, deep_min + light_min + rem_min FROM sleep_sessions
                 WHERE start_ms >= ?1 AND start_ms < ?1 + 7200000
                 ORDER BY start_ms LIMIT 1",
                params![nap_from],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?)
        })
        .unwrap();
        let (nap_start, nap_min) = nap.expect("旧库午睡会话丢失");
        assert_eq!((nap_start - nap_from) / 60_000, 69, "午睡起点应为 13:09");
        assert!((15.0..=20.0).contains(&nap_min), "午睡时长不对: {nap_min}");
        // 11-05 的午睡只有 source 13 分期、没有 source 10/11 锚点，也必须恢复。
        let source13_nap_from = Local
            .with_ymd_and_hms(2026, 11, 5, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let source13_nap: (i64, f64) = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT start_ms, deep_min + light_min + rem_min FROM sleep_sessions
                 WHERE start_ms >= ?1 AND start_ms < ?1 + 7200000
                 ORDER BY start_ms LIMIT 1",
                params![source13_nap_from],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?)
        })
        .unwrap();
        assert_eq!(
            (source13_nap.0 - source13_nap_from) / 60_000,
            0,
            "source 13 午睡起点应为 12:00"
        );
        assert!(
            (60.0..=80.0).contains(&source13_nap.1),
            "source 13 午睡时长不对: {}",
            source13_nap.1
        );
        let latest_day: i64 = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT MAX(date_day) FROM daily_metrics WHERE steps > 0",
                [],
                |r| r.get(0),
            )?)
        })
        .unwrap();
        let home = store::home_summary(latest_day).unwrap();
        assert!(home.steps > 0);
        assert!(home.readiness.total > 0);
        assert!(home.weight_kg.is_some());
        let detail = store::metric_detail("heart_rate", 30).unwrap();
        assert!(detail.has_data);
        let latest: (f64, f64, f64) = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT deep_min, light_min, rem_min FROM sleep_sessions ORDER BY start_ms DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?)
        })
        .unwrap();
        assert!(
            latest.0 + latest.2 > 0.0,
            "latest sleep lost stage detail: {latest:?}"
        );
        // 10-28 晚同时有 source 0（云端旧编码）和 source 11（手表正确编码）。
        // 旧版 40→41 迁移只旋转了 11/13，云端 0 的 deep/light/rem 必须在这里补转，
        // 否则会得到 deep=364、light=15 这种明显不合理的分期。
        let cloud_night = Local
            .with_ymd_and_hms(2026, 10, 28, 22, 18, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let corrected: (f64, f64, f64) = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT deep_min, light_min, rem_min FROM sleep_sessions
                 WHERE start_ms = ?1",
                params![cloud_night],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?)
        })
        .unwrap();
        assert_eq!(
            corrected,
            (85.0, 324.0, 55.0),
            "云端睡眠分期没有按手表编码旋转"
        );
        let workouts = store::list_workouts("all", 100).unwrap();
        assert!(workouts.iter().any(|w| w.distance_m > 1000.0));
        let totals: (i64, i64, i64, i64) = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT COUNT(*),
                        SUM(CASE WHEN id LIKE 'legacy-server-%' THEN 1 ELSE 0 END),
                        SUM(CASE WHEN track_json IS NOT NULL AND track_json <> '' THEN 1 ELSE 0 END),
                        SUM(CASE WHEN samples_json IS NOT NULL AND samples_json <> '' THEN 1 ELSE 0 END)
                 FROM workouts",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )?)
        })
        .unwrap();
        assert!(totals.0 >= 450, "workouts={}", totals.0);
        assert!(totals.1 >= 400, "server workouts={}", totals.1);
        assert!(totals.2 >= 40, "tracks={}", totals.2);
        assert!(totals.3 >= 40, "hr samples={}", totals.3);
        let body: (i64, i64, i64) = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT SUM(CASE WHEN skeletal_muscle_percent IS NOT NULL THEN 1 ELSE 0 END),
                        SUM(CASE WHEN resistance_ohm IS NOT NULL THEN 1 ELSE 0 END),
                        SUM(CASE WHEN body_fat_percent IS NOT NULL THEN 1 ELSE 0 END)
                 FROM weight_records",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?)
        })
        .unwrap();
        assert_eq!(body, (13, 13, 13), "体脂、骨骼肌或阻抗字段丢失: {body:?}");
        let newest_weight: (f64, Option<f64>, Option<f64>, Option<String>) =
            store::with_conn(|c| {
                Ok(c.query_row(
                    "SELECT weight_kg, body_fat_percent, resistance_ohm, device_name
                     FROM weight_records ORDER BY timestamp_ms DESC LIMIT 1",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                )?)
            })
            .unwrap();
        assert_eq!(
            newest_weight,
            (69.4, Some(28.5), Some(587.0), Some("AFU-WL-TZ-A1".into()))
        );
        let records = store::personal_records().unwrap();
        assert!(!records.is_empty());
        let running = |metric: &str| {
            records
                .iter()
                .find(|r| r.sport == "running" && r.metric == metric)
                .map(|r| r.value)
                .unwrap_or_else(|| panic!("running {metric} 丢失"))
        };
        assert!((running("5k") - 1767.0).abs() < 0.5);
        assert!((running("10k") - 3638.0).abs() < 0.5);
        assert!((running("half") - 7454.0).abs() < 0.5);
        assert!((running("longest") - 21.45).abs() < 0.01);
        assert!((running("duration") - 9228.0).abs() < 0.5);
        assert!((running("fastest_km") - 373.0).abs() < 0.5);
        assert!((running("pace") - 336.549).abs() < 0.01);
        let cycling = records
            .iter()
            .find(|r| r.sport == "cycling" && r.metric == "longest")
            .expect("cycling 最长距离丢失");
        assert!((cycling.value - 50.03).abs() < 0.01);
        let record = |sport: &str, metric: &str| {
            records
                .iter()
                .find(|r| r.sport == sport && r.metric == metric)
                .map(|r| r.value)
                .unwrap_or_else(|| panic!("{sport} {metric} 丢失"))
        };
        assert!((record("cycling", "pace") - 146.685).abs() < 0.01);
        assert!((record("hiking", "longest") - 6.22).abs() < 0.01);
        assert!((record("hiking", "duration") - 9185.0).abs() < 0.5);
        assert!((record("hiking", "pace") - 601.646).abs() < 0.01);
        assert!((record("strength", "duration") - 2443.0).abs() < 0.5);
        assert!((record("free_training", "duration") - 2803.0).abs() < 0.5);
        assert!((record("jump_rope", "duration") - 1963.0).abs() < 0.5);
        // 旧库没有对应的新版运动（没有游泳记录），静态纪录应独立补进个人纪录页。
        assert!(
            (record("swimming", "duration") - 2803.0).abs() < 0.5,
            "旧版游泳纪录没有合并进个人纪录"
        );
        let legacy_personal: (i64, f64, String) = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT (SELECT COUNT(*) FROM legacy_personal_records),
                        (SELECT value FROM legacy_personal_records
                         WHERE sport = 'swimming' AND metric = 'duration'),
                        (SELECT workout_id FROM legacy_personal_records
                         WHERE sport = 'running' AND metric = '5k')",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?)
        })
        .unwrap();
        assert_eq!(legacy_personal.0, 25, "旧版个人纪录去重后应有 25 项");
        assert!((legacy_personal.1 - 2803.0).abs() < 0.5);
        assert!(
            !legacy_personal.2.is_empty(),
            "旧版 5K 纪录应能关联到对应运动详情"
        );
        let detail_counts: (i64, i64, i64, i64, i64) = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT (SELECT COUNT(DISTINCT id) FROM workouts
                         WHERE splits_json IS NOT NULL AND splits_json <> ''),
                        (SELECT COALESCE(SUM(json_array_length(splits_json)), 0) FROM workouts
                         WHERE splits_json IS NOT NULL AND splits_json <> ''),
                        (SELECT COUNT(*) FROM hourly_status),
                        (SELECT COUNT(*) FROM apnea_records),
                        (SELECT COUNT(*) FROM arrhythmia_records)",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )?)
        })
        .unwrap();
        assert_eq!(
            detail_counts,
            (47, 685, 940, 98, 165),
            "配速分段 / 活动小时 / 呼吸暂停 / 心律失常迁移不完整"
        );
        let emotion_count: i64 = store::with_conn(|c| {
            Ok(c.query_row("SELECT COUNT(*) FROM emotion_records", [], |r| r.get(0))?)
        })
        .unwrap();
        assert_eq!(emotion_count, 2136, "情绪记录迁移不完整");
        let sleep_bed_count: i64 = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT COUNT(*) FROM sleep_bed WHERE bed_ms > 0 AND wake_ms > 0",
                [],
                |r| r.get(0),
            )?)
        })
        .unwrap();
        assert_eq!(sleep_bed_count, 5, "睡眠在床/入睡记录迁移不完整");
        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn legacy_workout_details_merge_into_existing_watch_row() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../.legacy/health_sync.db");
        if !std::path::Path::new(path).is_file() {
            return;
        }
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let db = std::env::temp_dir().join(format!(
            "vitaloop-legacy-watch-merge-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&db);
        store::open(db.to_str().unwrap()).unwrap();
        let summary_dynamics = json!([
            {"cad": 120, "spd": 3.1},
            {"cad": 124, "spd": 3.2},
            {"cad": 122, "spd": 3.3}
        ])
        .to_string();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO workouts(
                    id, source, sport, start_ms, end_ms, dynamics_json)
                 VALUES('watch-40270-1793852649', 'watch', 'running',
                        1793852649000, 1793854723000, ?1)",
                params![summary_dynamics],
            )?;
            Ok(())
        })
        .unwrap();

        let legacy = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        let mut report = LegacyImportReport {
            ok: false,
            already_imported: false,
            message: String::new(),
            days: 0,
            heart_rate_points: 0,
            sleep_sessions: 0,
            workouts: 0,
            weights: 0,
            blood_pressure: 0,
            glucose: 0,
            emotions: 0,
            samples: 0,
            identity: false,
            profile: false,
            goals: false,
        };
        import_workouts(&legacy, &mut report).unwrap();

        let counts: (i64, i64, i64, i64) = store::with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT COUNT(*), json_array_length(samples_json),
                        json_array_length(altitude_json),
                        json_array_length(dynamics_json)
                 FROM workouts WHERE id = 'watch-40270-1793852649'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )?)
        })
        .unwrap();
        assert_eq!(counts, (1, 412, 413, 412));

        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn imports_p2p_tables_from_legacy_database() {
        let legacy_path = concat!(env!("CARGO_MANIFEST_DIR"), "/../.legacy/health_sync.db");
        if !std::path::Path::new(legacy_path).is_file() {
            return;
        }
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let db =
            std::env::temp_dir().join(format!("vitaloop-legacy-p2p-dst-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&db);

        store::open(db.to_str().unwrap()).unwrap();
        import(legacy_path, "{}").unwrap();

        let apnea = store::apnea_records(1000).unwrap();
        assert!(!apnea.is_empty());
        assert!(apnea.iter().all(|r| (0..=10).contains(&r.level)));
        let rings = store::daily_rings(100).unwrap();
        assert!(!rings.is_empty());
        assert!(rings.iter().any(|r| r.step_user > 0));

        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn imports_saved_routes_from_wgs84_and_respects_tombstones() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let db =
            std::env::temp_dir().join(format!("vitaloop-legacy-routes-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&db);
        store::open(db.to_str().unwrap()).unwrap();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO saved_route_tombstones(id, deleted_ms) VALUES('deleted-route', 1)",
                [],
            )?;
            Ok(())
        })
        .unwrap();

        import_saved_routes_json(
            r#"[
              {
                "id": "wgs-route",
                "name": "WGS 路线",
                "coordinateSystem": "WGS84",
                "distanceMeters": 1200,
                "createdAtMillis": 1000,
                "points": [
                  {"latitude": 39.908, "longitude": 116.397},
                  {"latitude": 39.909, "longitude": 116.398}
                ]
              },
              {
                "id": "gcj-route",
                "name": "GCJ 路线",
                "coordinateSystem": "GCJ02",
                "createdAtMillis": 2000,
                "points": [
                  {"latitude": 30.2741, "longitude": 120.1551},
                  {"latitude": 30.2751, "longitude": 120.1561}
                ]
              },
              {
                "id": "deleted-route",
                "name": "已删除",
                "points": [
                  {"latitude": 30.0, "longitude": 120.0},
                  {"latitude": 30.1, "longitude": 120.1}
                ]
              }
            ]"#,
        )
        .unwrap();

        let routes = store::saved_routes().unwrap();
        assert_eq!(routes.len(), 2, "删除过的路线不能复活");
        let wgs = routes.iter().find(|r| r.id == "wgs-route").unwrap();
        assert!(
            (wgs.points[0].lat - 39.908).abs() > 0.0001
                || (wgs.points[0].lon - 116.397).abs() > 0.0001,
            "WGS84 必须转成 GCJ-02"
        );
        assert!(wgs.distance_m > 0.0);
        let gcj = routes.iter().find(|r| r.id == "gcj-route").unwrap();
        assert_eq!(gcj.points[0].lat, 30.2741);
        assert_eq!(gcj.points[0].lon, 120.1551);

        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn imports_phone_sessions_and_strength() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let legacy_path =
            std::env::temp_dir().join(format!("vitaloop-legacy-phone-{}.db", std::process::id()));
        let db = std::env::temp_dir().join(format!(
            "vitaloop-legacy-phone-dst-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);

        let legacy = Connection::open(&legacy_path).unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE running_sessions(
                    id TEXT PRIMARY KEY,
                    startTimeMillis INTEGER NOT NULL,
                    json TEXT NOT NULL
                );
                CREATE TABLE strength_exercises(
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    muscleGroup TEXT NOT NULL,
                    equipment TEXT NOT NULL,
                    isCustom INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE strength_templates(
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    notes TEXT NOT NULL DEFAULT '',
                    createdAt INTEGER NOT NULL DEFAULT 0,
                    updatedAt INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE strength_template_exercises(
                    id INTEGER PRIMARY KEY,
                    templateId INTEGER NOT NULL,
                    exerciseId INTEGER NOT NULL,
                    orderIndex INTEGER NOT NULL DEFAULT 0,
                    targetSets INTEGER NOT NULL DEFAULT 3,
                    targetReps INTEGER NOT NULL DEFAULT 12,
                    restSeconds INTEGER NOT NULL DEFAULT 60,
                    targetWeightKg REAL,
                    notes TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE strength_workout_sets(
                    id INTEGER PRIMARY KEY,
                    sessionId TEXT NOT NULL,
                    exerciseId INTEGER NOT NULL,
                    exerciseName TEXT NOT NULL,
                    setNumber INTEGER NOT NULL,
                    weightKg REAL NOT NULL,
                    reps INTEGER NOT NULL,
                    restSecondsActual INTEGER NOT NULL DEFAULT 0,
                    completedAt INTEGER NOT NULL DEFAULT 0
                );",
            )
            .unwrap();
        let session = json!({
            "id": "s1",
            "startTime": 1_700_000_000_000i64,
            "endTime": 1_700_000_600_000i64,
            "gpsPoints": [
                {"latitude": 30.0, "longitude": 120.0, "altitude": 10.0,
                 "timestamp": 1_700_000_000_000i64, "heartRate": 120},
                {"latitude": 30.001, "longitude": 120.0, "altitude": 11.0,
                 "timestamp": 1_700_000_300_000i64, "heartRate": 130}
            ],
            "totalDistanceMeters": 111.0,
            "totalDurationSeconds": 600,
            "averageHeartRate": 0,
            "maxHeartRate": 0,
            "calories": 80,
            "activityType": "跑步",
            "totalAscent": 12.0
        });
        legacy
            .execute(
                "INSERT INTO running_sessions(id, startTimeMillis, json) VALUES(?1, ?2, ?3)",
                params!["s1", 1_700_000_000_000i64, session.to_string()],
            )
            .unwrap();
        legacy
            .execute(
                "INSERT INTO strength_exercises(id, name, muscleGroup, equipment, isCustom)
                 VALUES(7, '杠铃深蹲', '腿', '杠铃', 0)",
                [],
            )
            .unwrap();
        legacy
            .execute(
                "INSERT INTO strength_templates(id, name, notes, createdAt, updatedAt)
                 VALUES(3, '腿部日', '旧版模板', 1000, 2000)",
                [],
            )
            .unwrap();
        legacy
            .execute(
                "INSERT INTO strength_template_exercises(
                    id, templateId, exerciseId, orderIndex, targetSets, targetReps,
                    restSeconds, targetWeightKg, notes)
                 VALUES(1, 3, 7, 0, 4, 8, 90, 60.0, '')",
                [],
            )
            .unwrap();
        legacy
            .execute(
                "INSERT INTO strength_workout_sets(
                    id, sessionId, exerciseId, exerciseName, setNumber, weightKg, reps,
                    restSecondsActual, completedAt)
                 VALUES(1, 's1', 7, '杠铃深蹲', 1, 60.0, 8, 90, 1_700_000_100_000)",
                [],
            )
            .unwrap();
        drop(legacy);

        store::open(db.to_str().unwrap()).unwrap();
        let legacy =
            Connection::open_with_flags(&legacy_path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        let mut report = LegacyImportReport {
            ok: false,
            already_imported: false,
            message: String::new(),
            days: 0,
            heart_rate_points: 0,
            sleep_sessions: 0,
            workouts: 0,
            weights: 0,
            blood_pressure: 0,
            glucose: 0,
            emotions: 0,
            samples: 0,
            identity: false,
            profile: false,
            goals: false,
        };
        import_sessions(&legacy, &mut report).unwrap();
        import_strength(&legacy).unwrap();

        assert_eq!(report.workouts, 1);
        let workout: (String, f64, i64, i64, i64) = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT sport, distance_m, avg_hr, max_hr,
                        CASE WHEN track_json IS NOT NULL AND samples_json IS NOT NULL THEN 1 ELSE 0 END
                 FROM workouts WHERE id = 'legacy-session-s1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )?)
        })
        .unwrap();
        assert_eq!(workout.0, "running");
        assert!((workout.1 - 111.0).abs() < 1.0);
        assert_eq!(workout.2, 125);
        assert_eq!(workout.3, 130);
        assert_eq!(workout.4, 1);

        let template: (String, i64) = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT t.name,
                        (SELECT COUNT(*) FROM strength_template_exercises e
                         WHERE e.template_id = t.id)
                 FROM strength_templates t WHERE t.name = '腿部日'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?)
        })
        .unwrap();
        assert_eq!(template.0, "腿部日");
        assert_eq!(template.1, 1);
        let set_count: i64 = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT COUNT(*) FROM strength_workout_sets
                 WHERE session_id = 'legacy-session-s1'",
                [],
                |r| r.get(0),
            )?)
        })
        .unwrap();
        assert_eq!(set_count, 1);

        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn merges_phone_details_into_existing_watch_workout() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let legacy_path =
            std::env::temp_dir().join(format!("vitaloop-legacy-merge-{}.db", std::process::id()));
        let db = std::env::temp_dir().join(format!(
            "vitaloop-legacy-merge-dst-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);

        let legacy = Connection::open(&legacy_path).unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE running_sessions(
                    id TEXT PRIMARY KEY,
                    startTimeMillis INTEGER NOT NULL,
                    json TEXT NOT NULL
                );",
            )
            .unwrap();
        let start = 1_700_100_000_000i64;
        let session = json!({
            "id": "merge-session",
            "startTime": start,
            "endTime": start + 900_000,
            "gpsPoints": [
                {"latitude": 30.0, "longitude": 120.0, "altitude": 10.0,
                 "timestamp": start, "heartRate": 120},
                {"latitude": 30.001, "longitude": 120.001, "altitude": 11.0,
                 "timestamp": start + 300_000, "heartRate": 130},
                {"latitude": 30.002, "longitude": 120.002, "altitude": 12.0,
                 "timestamp": start + 600_000, "heartRate": 140}
            ],
            "totalDistanceMeters": 250.0,
            "totalDurationSeconds": 900,
            "averageHeartRate": 130,
            "maxHeartRate": 140,
            "calories": 90,
            "activityType": "跑步",
            "totalAscent": 15.0
        });
        legacy
            .execute(
                "INSERT INTO running_sessions(id, startTimeMillis, json) VALUES(?1, ?2, ?3)",
                params!["merge-session", start, session.to_string()],
            )
            .unwrap();
        drop(legacy);

        store::open(db.to_str().unwrap()).unwrap();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO workouts(
                    id, source, sport, start_ms, end_ms, distance_m, calories,
                    avg_hr, max_hr, synced, created_ms, track_json, samples_json
                 ) VALUES('watch-merge', 'watch', 'running', ?1, ?2, 250.0, 90,
                          130, 140, 1, ?1, NULL, NULL)",
                params![start, start + 900_000],
            )?;
            Ok(())
        })
        .unwrap();

        let legacy =
            Connection::open_with_flags(&legacy_path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        let mut report = LegacyImportReport {
            ok: false,
            already_imported: false,
            message: String::new(),
            days: 0,
            heart_rate_points: 0,
            sleep_sessions: 0,
            workouts: 0,
            weights: 0,
            blood_pressure: 0,
            glucose: 0,
            emotions: 0,
            samples: 0,
            identity: false,
            profile: false,
            goals: false,
        };
        import_sessions(&legacy, &mut report).unwrap();

        assert_eq!(report.workouts, 0);
        let row: (i64, String, String) = store::with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT COUNT(*), track_json, samples_json FROM workouts
                 WHERE sport = 'running' AND ABS(start_ms - ?1) <= 120000",
                params![start],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?)
        })
        .unwrap();
        assert_eq!(row.0, 1, "should not create a duplicate workout");
        assert!(row.1.contains("\"lat\":30.0"), "track missing: {}", row.1);
        assert!(row.2.contains("\"hr\":120"), "samples missing: {}", row.2);

        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn imports_source13_only_afternoon_nap() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let legacy_path =
            std::env::temp_dir().join(format!("vitaloop-legacy-nap-{}.db", std::process::id()));
        let db =
            std::env::temp_dir().join(format!("vitaloop-legacy-nap-dst-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);

        let nap_start = Local
            .with_ymd_and_hms(2026, 11, 5, 13, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let main_start = Local
            .with_ymd_and_hms(2026, 11, 4, 23, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let legacy = Connection::open(&legacy_path).unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE huawei_sleep_records(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    startTimeMillis INTEGER NOT NULL,
                    endTimeMillis INTEGER NOT NULL,
                    stage TEXT NOT NULL,
                    source INTEGER NOT NULL,
                    isSynced INTEGER NOT NULL
                );",
            )
            .unwrap();
        legacy
            .execute(
                "INSERT INTO huawei_sleep_records(
                    startTimeMillis, endTimeMillis, stage, source, isSynced
                 ) VALUES(?1, ?2, 'light', 11, 1)",
                params![main_start, main_start + 8 * 3_600_000],
            )
            .unwrap();
        legacy
            .execute(
                "INSERT INTO huawei_sleep_records(
                    startTimeMillis, endTimeMillis, stage, source, isSynced
                 ) VALUES(?1, ?2, 'light', 13, 1)",
                params![nap_start, nap_start + 38 * 60_000],
            )
            .unwrap();

        store::open(db.to_str().unwrap()).unwrap();
        let mut days = HashMap::new();
        let mut report = LegacyImportReport {
            ok: false,
            already_imported: false,
            message: String::new(),
            days: 0,
            heart_rate_points: 0,
            sleep_sessions: 0,
            workouts: 0,
            weights: 0,
            blood_pressure: 0,
            glucose: 0,
            emotions: 0,
            samples: 0,
            identity: false,
            profile: false,
            goals: false,
        };
        import_sleep(&legacy, &mut days, &mut report).unwrap();

        assert_eq!(report.sleep_sessions, 2, "主睡眠和 source 13 午睡都应迁入");
        let nap: (i64, f64) = store::with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT start_ms, deep_min + light_min + rem_min
                 FROM sleep_sessions WHERE start_ms = ?1",
                params![nap_start],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?)
        })
        .unwrap();
        assert_eq!(nap, (nap_start, 38.0));

        let nap_day = store::epoch_day_of(chrono::NaiveDate::from_ymd_opt(2026, 11, 5).unwrap());
        let summary = store::sleep_summary(nap_day).unwrap().unwrap();
        assert_eq!(summary.nap_minutes, 38, "38 分钟午睡应计入小睡");
        assert_eq!(summary.total_minutes, 8 * 60 + 38, "总睡眠应包含午睡");

        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn backfills_fragmented_source13_naps_once() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let legacy_path = std::env::temp_dir().join(format!(
            "vitaloop-legacy-nap-backfill-{}.db",
            std::process::id()
        ));
        let db = std::env::temp_dir().join(format!(
            "vitaloop-legacy-nap-backfill-dst-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);

        let day = Local
            .with_ymd_and_hms(2026, 11, 5, 0, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let at = |hour: i64, minute: i64| day + (hour * 60 + minute) * 60_000;
        let legacy = Connection::open(&legacy_path).unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE huawei_sleep_records(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    startTimeMillis INTEGER NOT NULL,
                    endTimeMillis INTEGER NOT NULL,
                    stage TEXT NOT NULL,
                    source INTEGER NOT NULL,
                    isSynced INTEGER NOT NULL
                );",
            )
            .unwrap();
        let mut insert = legacy
            .prepare(
                "INSERT INTO huawei_sleep_records(
                    startTimeMillis, endTimeMillis, stage, source, isSynced
                 ) VALUES(?1, ?2, 'light', 13, 1)",
            )
            .unwrap();
        // 一次 36 分钟小睡被拆成三段；20 分钟聚类会被前后零星打点串成
        // 121 分钟低密度片段后丢掉，10 分钟聚类能单独捞出。
        for (start, end) in [
            (at(13, 0), at(13, 12)),
            (at(13, 18), at(13, 30)),
            (at(13, 36), at(13, 48)),
        ] {
            insert.execute(params![start, end]).unwrap();
        }
        for (hour, minute) in [(12, 20), (12, 40), (14, 0), (14, 20)] {
            insert
                .execute(params![at(hour, minute), at(hour, minute) + 60_000])
                .unwrap();
        }
        // 这场已经存在于新版，回填时必须跳过，不能重复。
        insert.execute(params![at(15, 0), at(15, 20)]).unwrap();
        drop(insert);

        store::open(db.to_str().unwrap()).unwrap();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO sleep_sessions(
                    start_ms, end_ms, light_min, source)
                 VALUES(?1, ?2, 30, 'watch')",
                params![at(15, 0), at(15, 30)],
            )?;
            Ok(())
        })
        .unwrap();

        assert_eq!(backfill_daytime_naps(&legacy).unwrap(), 1);
        let sessions: Vec<(i64, f64)> = store::with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT start_ms, deep_min + light_min + rem_min
                 FROM sleep_sessions ORDER BY start_ms",
            )?;
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
        .unwrap();
        assert_eq!(
            sessions,
            vec![(at(13, 0), 36.0), (at(15, 0), 30.0)],
            "只应补缺失的小睡，已有会话保持不变"
        );
        let stages: i64 = store::with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT COUNT(*) FROM sleep_stages WHERE start_ms >= ?1 AND start_ms < ?2",
                params![at(13, 0), at(14, 0)],
                |r| r.get(0),
            )?)
        })
        .unwrap();
        assert_eq!(stages, 3, "小睡分期也要写入，供手表重建使用");

        assert_eq!(
            backfill_daytime_naps(&legacy).unwrap(),
            0,
            "重复执行不能重复插入"
        );

        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn rotates_cloud_sleep_stage_encoding() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let legacy_path = std::env::temp_dir().join(format!(
            "vitaloop-legacy-cloud-sleep-{}.db",
            std::process::id()
        ));
        let db = std::env::temp_dir().join(format!(
            "vitaloop-legacy-cloud-sleep-dst-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);

        let start = Local
            .with_ymd_and_hms(2026, 10, 28, 22, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let legacy = Connection::open(&legacy_path).unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE huawei_sleep_records(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    startTimeMillis INTEGER NOT NULL,
                    endTimeMillis INTEGER NOT NULL,
                    stage TEXT NOT NULL,
                    source INTEGER NOT NULL,
                    isSynced INTEGER NOT NULL
                );",
            )
            .unwrap();
        for (offset_min, minutes, stage) in
            [(0i64, 90i64, "deep"), (90, 30, "light"), (120, 60, "rem")]
        {
            legacy
                .execute(
                    "INSERT INTO huawei_sleep_records(
                        startTimeMillis, endTimeMillis, stage, source, isSynced
                     ) VALUES(?1, ?2, ?3, 0, 1)",
                    params![
                        start + offset_min * 60_000,
                        start + (offset_min + minutes) * 60_000,
                        stage
                    ],
                )
                .unwrap();
        }

        store::open(db.to_str().unwrap()).unwrap();
        let mut days = HashMap::new();
        let mut report = LegacyImportReport {
            ok: false,
            already_imported: false,
            message: String::new(),
            days: 0,
            heart_rate_points: 0,
            sleep_sessions: 0,
            workouts: 0,
            weights: 0,
            blood_pressure: 0,
            glucose: 0,
            emotions: 0,
            samples: 0,
            identity: false,
            profile: false,
            goals: false,
        };
        import_sleep(&legacy, &mut days, &mut report).unwrap();

        let stages: (f64, f64, f64) = store::with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT deep_min, light_min, rem_min FROM sleep_sessions LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?)
        })
        .unwrap();
        assert_eq!(
            stages,
            (60.0, 90.0, 30.0),
            "云端 source=0 的 deep/light/rem 应旋转成手表编码"
        );

        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn import_sleep_preserves_sessions_after_legacy_snapshot() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let legacy_path = std::env::temp_dir().join(format!(
            "vitaloop-legacy-sleep-cutoff-{}.db",
            std::process::id()
        ));
        let db = std::env::temp_dir().join(format!(
            "vitaloop-legacy-sleep-cutoff-dst-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);

        let legacy_start = Local
            .with_ymd_and_hms(2026, 11, 1, 23, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let legacy_end = legacy_start + 7 * 3_600_000;
        // 旧库的睡眠分期只到 11-01，但在床记录已经写到 11-03。边界必须
        // 按分期算，否则会删掉 11-03 之后手表新同步的会话却无法重建。
        let legacy_bed_end = legacy_end + 2 * 24 * 3_600_000;
        let new_start = Local
            .with_ymd_and_hms(2026, 11, 7, 23, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let new_end = new_start + 8 * 3_600_000;

        let legacy = Connection::open(&legacy_path).unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE huawei_sleep_records(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    startTimeMillis INTEGER NOT NULL,
                    endTimeMillis INTEGER NOT NULL,
                    stage TEXT NOT NULL,
                    source INTEGER NOT NULL,
                    isSynced INTEGER NOT NULL
                );
                CREATE TABLE huawei_sleep_bed_records(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    startTimeMillis INTEGER NOT NULL,
                    bedTimeMillis INTEGER,
                    fallAsleepTimeMillis INTEGER,
                    wakeupMillis INTEGER
                );",
            )
            .unwrap();
        legacy
            .execute(
                "INSERT INTO huawei_sleep_records(
                    startTimeMillis, endTimeMillis, stage, source, isSynced
                 ) VALUES(?1, ?2, 'light', 11, 1)",
                params![legacy_start, legacy_end],
            )
            .unwrap();
        legacy
            .execute(
                "INSERT INTO huawei_sleep_bed_records(
                    startTimeMillis, bedTimeMillis, fallAsleepTimeMillis, wakeupMillis
                 ) VALUES(?1, ?1, ?1, ?2)",
                params![legacy_start, legacy_bed_end],
            )
            .unwrap();

        store::open(db.to_str().unwrap()).unwrap();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO sleep_sessions(
                    start_ms, end_ms, light_min, source)
                 VALUES(?1, ?2, 420, 'watch')",
                params![legacy_start, legacy_end],
            )?;
            conn.execute(
                "INSERT INTO sleep_sessions(
                    start_ms, end_ms, light_min, source)
                 VALUES(?1, ?2, 480, 'watch')",
                params![new_start, new_end],
            )?;
            conn.execute(
                "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                 VALUES(?1, ?2, 'light', 'watch')",
                params![legacy_start, legacy_end],
            )?;
            conn.execute(
                "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                 VALUES(?1, ?2, 'light', 'watch')",
                params![new_start, new_end],
            )?;
            conn.execute(
                "INSERT INTO sleep_bed(session_start_ms, bed_ms, fall_asleep_ms, wake_ms)
                 VALUES(?1, ?1, ?1, ?2)",
                params![new_start, new_end],
            )?;
            Ok(())
        })
        .unwrap();

        let mut days = HashMap::new();
        let mut report = LegacyImportReport {
            ok: false,
            already_imported: false,
            message: String::new(),
            days: 0,
            heart_rate_points: 0,
            sleep_sessions: 0,
            workouts: 0,
            weights: 0,
            blood_pressure: 0,
            glucose: 0,
            emotions: 0,
            samples: 0,
            identity: false,
            profile: false,
            goals: false,
        };
        import_sleep(&legacy, &mut days, &mut report).unwrap();

        let (sessions, stages, bed): (i64, i64, i64) = store::with_conn(|conn| {
            Ok((
                conn.query_row(
                    "SELECT COUNT(*) FROM sleep_sessions WHERE start_ms = ?1",
                    params![new_start],
                    |r| r.get(0),
                )?,
                conn.query_row(
                    "SELECT COUNT(*) FROM sleep_stages WHERE start_ms = ?1",
                    params![new_start],
                    |r| r.get(0),
                )?,
                conn.query_row(
                    "SELECT COUNT(*) FROM sleep_bed WHERE session_start_ms = ?1",
                    params![new_start],
                    |r| r.get(0),
                )?,
            ))
        })
        .unwrap();
        assert_eq!(
            (sessions, stages, bed),
            (1, 1, 1),
            "重导旧库时不能删掉旧库覆盖范围之后的手表睡眠"
        );
        let old: i64 = store::with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT COUNT(*) FROM sleep_sessions WHERE start_ms = ?1",
                params![legacy_start],
                |r| r.get(0),
            )?)
        })
        .unwrap();
        assert_eq!(old, 1, "旧库覆盖范围内应由本次导入重建");

        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn import_keeps_bp_readings_seconds_apart_but_merges_packet_duplicates() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let legacy_path =
            std::env::temp_dir().join(format!("vitaloop-legacy-bp-{}.db", std::process::id()));
        let db =
            std::env::temp_dir().join(format!("vitaloop-legacy-bp-dst-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);

        let legacy = Connection::open(&legacy_path).unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE blood_pressure_records(
                    id TEXT PRIMARY KEY,
                    timestamp INTEGER NOT NULL,
                    systolic INTEGER NOT NULL,
                    diastolic INTEGER NOT NULL,
                    pulse INTEGER
                );",
            )
            .unwrap();
        let base = 1_780_000_000_000_i64;
        for (index, offset) in [0_i64, 49, 8_000, 16_000, 24_000, 32_000]
            .into_iter()
            .enumerate()
        {
            legacy
                .execute(
                    "INSERT INTO blood_pressure_records(
                       id, timestamp, systolic, diastolic, pulse)
                     VALUES(?1, ?2, 105, 66, 0)",
                    params![format!("bp-{index}"), base + offset],
                )
                .unwrap();
        }
        drop(legacy);

        store::open(db.to_str().unwrap()).unwrap();
        let legacy =
            Connection::open_with_flags(&legacy_path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        let mut report = LegacyImportReport {
            ok: false,
            already_imported: false,
            message: String::new(),
            days: 0,
            heart_rate_points: 0,
            sleep_sessions: 0,
            workouts: 0,
            weights: 0,
            blood_pressure: 0,
            glucose: 0,
            emotions: 0,
            samples: 0,
            identity: false,
            profile: false,
            goals: false,
        };
        import_bp(&legacy, &mut report).unwrap();

        let count: i64 = store::with_conn(|conn| {
            Ok(
                conn.query_row("SELECT COUNT(*) FROM blood_pressure_records", [], |r| {
                    r.get(0)
                })?,
            )
        })
        .unwrap();
        assert_eq!(count, 5, "相隔几秒的血压测量应保留，毫秒重复包只留一条");

        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn server_track_keeps_indoor_heart_rate_without_coordinates() {
        let detail = json!({
            "summary": {"start_time": 1_793_000_000_i64},
            "trkpt": [
                {"timestamp": 1_793_000_000_i64, "heart_rate": 110.0},
                {"timestamp": 1_793_000_030_i64, "heart_rate": 112.0}
            ]
        });
        let (track, samples) = server_track(&detail, 0);
        assert!(track.is_none(), "无坐标的室内运动不应生成假轨迹");
        let samples: Value = serde_json::from_str(samples.as_deref().unwrap()).unwrap();
        assert_eq!(samples.as_array().unwrap().len(), 2);
        assert_eq!(samples[1]["hr"], 112);
    }

    #[test]
    fn reimport_does_not_restore_deleted_health_records() {
        let _guard = crate::store::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let legacy_path = std::env::temp_dir().join(format!(
            "vitaloop-legacy-tombstone-{}.db",
            std::process::id()
        ));
        let db = std::env::temp_dir().join(format!(
            "vitaloop-legacy-tombstone-dst-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);

        let legacy = Connection::open(&legacy_path).unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE blood_pressure_records(
                    id TEXT PRIMARY KEY,
                    timestamp INTEGER NOT NULL,
                    systolic INTEGER NOT NULL,
                    diastolic INTEGER NOT NULL,
                    pulse INTEGER
                );",
            )
            .unwrap();
        legacy
            .execute(
                "INSERT INTO blood_pressure_records(id, timestamp, systolic, diastolic, pulse)
                 VALUES('bp-1', 1700000000000, 120, 80, 60)",
                [],
            )
            .unwrap();
        drop(legacy);

        store::open(db.to_str().unwrap()).unwrap();
        store::delete_blood_pressure("bp-1").unwrap();

        let legacy =
            Connection::open_with_flags(&legacy_path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        let mut report = LegacyImportReport {
            ok: false,
            already_imported: false,
            message: String::new(),
            days: 0,
            heart_rate_points: 0,
            sleep_sessions: 0,
            workouts: 0,
            weights: 0,
            blood_pressure: 0,
            glucose: 0,
            emotions: 0,
            samples: 0,
            identity: false,
            profile: false,
            goals: false,
        };
        import_bp(&legacy, &mut report).unwrap();

        assert_eq!(report.blood_pressure, 0);
        let count: i64 = store::with_conn(|c| {
            Ok(c.query_row(
                "SELECT COUNT(*) FROM blood_pressure_records WHERE id = 'bp-1'",
                [],
                |r| r.get(0),
            )?)
        })
        .unwrap();
        assert_eq!(count, 0, "deleted record came back after reimport");

        let _ = std::fs::remove_file(&legacy_path);
        let _ = std::fs::remove_file(&db);
    }
}
