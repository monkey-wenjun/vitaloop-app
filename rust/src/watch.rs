use anyhow::Result;
use chrono::{Local, TimeZone, Timelike};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use crate::store;

fn local_day(ts_ms: i64) -> i64 {
    Local
        .timestamp_millis_opt(ts_ms)
        .single()
        .map(|dt| store::epoch_day_of(dt.date_naive()))
        .unwrap_or(ts_ms / 86_400_000)
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

fn field(ev: &Value, key: &str) -> i64 {
    ev.get(key).and_then(|v| v.as_i64()).unwrap_or(0)
}

/// 华为运动类型编码 → Vitaloop 内部 sport 名（与 legacy.rs 保持一致）。
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

/// 手表直连同步数据入库。
/// events 为 JSON 数组，元素类型：
///   {"t":"hr","ts":ms,"bpm":n}
///   {"t":"spo2","ts":ms,"v":n}
///   {"t":"resting_hr","ts":ms,"v":n}
///   {"t":"step_sample","ts":s,"steps":n,"calories":kcal,"distance":m}
///   {"t":"sleep_segment","start":s,"end":s,"stage":"light|rem|deep|awake|sleep","source":n}
///   {"t":"sleep_bed","session_start":ms,"bed":ms,"fall_asleep":ms,"wake":ms}
///   {"t":"hrv","ts":ms,"v":ms}
///   {"t":"sleep_hrv","ts":ms,"start":ms,"avg":rmssd,"min":n,"max":n,"delta":n}
///   {"t":"respiration","ts":ms,"v":bpm}
///   {"t":"stress","ts":ms,"v":score}
///   {"t":"skin_temp","ts":ms,"v":c}
///   {"t":"body_temp","ts":ms,"v":c}
///   {"t":"emotion","ts":ms,"status":n,"valence":x,"arousal":y}
///   {"t":"arrhythmia","ts":ms,"result":n,"measure_type":n}
///   {"t":"apnea","ts":ms,"level":n}
///   {"t":"active_hour","ts":ms,"v":1}
///   {"t":"daily_ring","end":ms,"step_goal":n,"step_user":n, ...}
///   {"t":"fitness_totals","steps":n,"calories":n,"distance":m}
///   {"t":"weight","ts":ms,"kg":x,"body_fat":p,"muscle":p,"water":p,"source":"scale","device":s}
///   {"t":"device","battery":n,"connected":bool,"name":s,"address":s}
///   {"t":"sync_done","end":s}
pub fn ingest_watch_data(events_json: String) -> Result<String> {
    let events: Vec<Value> = serde_json::from_str::<Value>(&events_json)?
        .get("events")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    if events.is_empty() {
        return Ok(
            json!({"hr":0,"spo2":0,"resting_hr":0,"steps":0,"sleep":0,"totals":0}).to_string(),
        );
    }

    let mut touched_days: std::collections::BTreeSet<i64> = std::collections::BTreeSet::new();
    let mut counts = [0usize; 10]; // hr, spo2, resting_hr, steps, sleep, totals, hrv, stress, temp, other
    let mut workout_count = 0usize;

    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;

        {
            let mut ins_hr = tx.prepare(
                "INSERT OR IGNORE INTO heart_rate_points(ts_ms, bpm, synced) VALUES(?1, ?2, 1)",
            )?;
            let mut ins_metric = tx.prepare("INSERT OR REPLACE INTO metric_points(metric, ts_ms, value, source) VALUES(?1, ?2, ?3, 'watch')")?;
            let mut ins_step = tx.prepare("INSERT OR IGNORE INTO step_samples(ts, steps, calories, distance) VALUES(?1, ?2, ?3, ?4)")?;
            let mut ins_stage = tx.prepare("INSERT OR IGNORE INTO sleep_stages(start_ms, end_ms, stage, source) VALUES(?1, ?2, ?3, 'watch')")?;
            let mut up_daily = tx.prepare(
                "INSERT INTO daily_metrics(date_day, steps, calories, active_calories, distance_m, resting_hr, spo2, updated_ms)
                 VALUES(?1, ?2, ?3, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(date_day) DO UPDATE SET
                    steps = CASE WHEN excluded.steps > 0 THEN excluded.steps ELSE daily_metrics.steps END,
                    calories = CASE WHEN excluded.calories > 0 THEN excluded.calories ELSE daily_metrics.calories END,
                    active_calories = CASE WHEN excluded.active_calories > 0 THEN excluded.active_calories ELSE daily_metrics.active_calories END,
                    distance_m = CASE WHEN excluded.distance_m > 0 THEN excluded.distance_m ELSE daily_metrics.distance_m END,
                    resting_hr = COALESCE(excluded.resting_hr, daily_metrics.resting_hr),
                    spo2 = COALESCE(excluded.spo2, daily_metrics.spo2),
                    updated_ms = excluded.updated_ms
                 WHERE (excluded.steps > 0 AND excluded.steps <> daily_metrics.steps)
                    OR (excluded.calories > 0 AND excluded.calories <> daily_metrics.calories)
                    OR (excluded.active_calories > 0 AND excluded.active_calories <> daily_metrics.active_calories)
                    OR (excluded.distance_m > 0 AND excluded.distance_m <> daily_metrics.distance_m)
                    OR (excluded.resting_hr IS NOT NULL AND excluded.resting_hr IS NOT daily_metrics.resting_hr)
                    OR (excluded.spo2 IS NOT NULL AND excluded.spo2 IS NOT daily_metrics.spo2)",
            )?;
            let mut up_hrv = tx.prepare(
                "INSERT INTO daily_metrics(date_day, hrv_ms, updated_ms)
                 VALUES(?1, ?2, ?3)
                 ON CONFLICT(date_day) DO UPDATE SET
                    hrv_ms = excluded.hrv_ms,
                    updated_ms = excluded.updated_ms
                 WHERE daily_metrics.hrv_ms IS NOT excluded.hrv_ms",
            )?;
            let mut up_stress = tx.prepare(
                "INSERT INTO daily_metrics(date_day, stress, updated_ms)
                 VALUES(?1, ?2, ?3)
                 ON CONFLICT(date_day) DO UPDATE SET
                    stress = excluded.stress,
                    updated_ms = excluded.updated_ms
                 WHERE daily_metrics.stress IS NOT excluded.stress",
            )?;
            let mut up_skin_temp = tx.prepare(
                "INSERT INTO daily_metrics(date_day, skin_temp_c, updated_ms)
                 VALUES(?1, ?2, ?3)
                 ON CONFLICT(date_day) DO UPDATE SET
                    skin_temp_c = excluded.skin_temp_c,
                    updated_ms = excluded.updated_ms
                 WHERE daily_metrics.skin_temp_c IS NOT excluded.skin_temp_c",
            )?;
            let mut up_body_temp = tx.prepare(
                "INSERT INTO daily_metrics(date_day, body_temp_c, updated_ms)
                 VALUES(?1, ?2, ?3)
                 ON CONFLICT(date_day) DO UPDATE SET
                    body_temp_c = excluded.body_temp_c,
                    updated_ms = excluded.updated_ms
                 WHERE daily_metrics.body_temp_c IS NOT excluded.body_temp_c",
            )?;

            for ev in &events {
                let t = ev.get("t").and_then(|v| v.as_str()).unwrap_or("");
                match t {
                    "hr" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let bpm = ev.get("bpm").and_then(|v| v.as_i64()).unwrap_or(0);
                        if ts > 0 && bpm > 0 && ins_hr.execute(params![ts, bpm]).is_ok() {
                            counts[0] += 1;
                        }
                    }
                    "spo2" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let v = ev.get("v").and_then(|v| v.as_f64()).unwrap_or(0.0);
                        if ts > 0 && v > 0.0 {
                            let _ = ins_metric.execute(params!["spo2", ts, v]);
                            counts[1] += 1;
                            let _ = up_daily.execute(params![
                                local_day(ts),
                                0,
                                0,
                                0,
                                Option::<f64>::None,
                                v,
                                now_ms()
                            ]);
                        }
                    }
                    "resting_hr" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let v = ev.get("v").and_then(|v| v.as_f64()).unwrap_or(0.0);
                        if ts > 0 && v > 0.0 {
                            let _ = ins_metric.execute(params!["resting_hr", ts, v]);
                            counts[2] += 1;
                            let _ = up_daily.execute(params![
                                local_day(ts),
                                0,
                                0,
                                0,
                                v,
                                Option::<f64>::None,
                                now_ms()
                            ]);
                        }
                    }
                    "step_sample" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let steps = ev.get("steps").and_then(|v| v.as_i64()).unwrap_or(0);
                        let calories = ev.get("calories").and_then(|v| v.as_i64()).unwrap_or(0);
                        let distance = ev.get("distance").and_then(|v| v.as_i64()).unwrap_or(0);
                        if ts > 0
                            && ins_step
                                .execute(params![ts, steps, calories, distance])
                                .is_ok()
                        {
                            counts[3] += 1;
                            touched_days.insert(local_day(ts * 1000));
                        }
                    }
                    "sleep_segment" => {
                        let start = ev.get("start").and_then(|v| v.as_i64()).unwrap_or(0);
                        let end = ev.get("end").and_then(|v| v.as_i64()).unwrap_or(0);
                        let stage = ev
                            .get("stage")
                            .and_then(|v| v.as_str())
                            .unwrap_or("unknown");
                        if start > 0 && end > start && stage != "unknown" {
                            let _ = ins_stage.execute(params![start * 1000, end * 1000, stage]);
                            counts[4] += 1;
                            touched_days.insert(local_day(start * 1000));
                            touched_days.insert(local_day(end * 1000));
                        }
                    }
                    "sleep_bed" => {
                        let session_start = ev
                            .get("session_start")
                            .and_then(|v| v.as_i64())
                            .unwrap_or(0);
                        let bed = ev.get("bed").and_then(|v| v.as_i64()).filter(|v| *v > 0);
                        let fall_asleep = ev
                            .get("fall_asleep")
                            .and_then(|v| v.as_i64())
                            .filter(|v| *v > 0);
                        let wake = ev.get("wake").and_then(|v| v.as_i64()).filter(|v| *v > 0);
                        if session_start > 0
                            && (bed.is_some() || fall_asleep.is_some() || wake.is_some())
                        {
                            tx.execute(
                                "INSERT INTO sleep_bed(session_start_ms, bed_ms, fall_asleep_ms, wake_ms)
                                 VALUES(?1, ?2, ?3, ?4)
                                 ON CONFLICT(session_start_ms) DO UPDATE SET
                                    bed_ms = CASE
                                        WHEN excluded.bed_ms IS NULL THEN sleep_bed.bed_ms
                                        WHEN sleep_bed.bed_ms IS NULL OR excluded.bed_ms > sleep_bed.bed_ms THEN excluded.bed_ms
                                        ELSE sleep_bed.bed_ms END,
                                    fall_asleep_ms = CASE
                                        WHEN excluded.fall_asleep_ms IS NULL THEN sleep_bed.fall_asleep_ms
                                        WHEN sleep_bed.fall_asleep_ms IS NULL OR excluded.fall_asleep_ms > sleep_bed.fall_asleep_ms THEN excluded.fall_asleep_ms
                                        ELSE sleep_bed.fall_asleep_ms END,
                                    wake_ms = CASE
                                        WHEN excluded.wake_ms IS NULL THEN sleep_bed.wake_ms
                                        WHEN sleep_bed.wake_ms IS NULL OR excluded.wake_ms > sleep_bed.wake_ms THEN excluded.wake_ms
                                        ELSE sleep_bed.wake_ms END",
                                params![session_start, bed, fall_asleep, wake],
                            )?;
                            counts[4] += 1;
                            touched_days.insert(local_day(session_start));
                        }
                    }
                    "hrv" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let value = ev.get("v").and_then(|v| v.as_f64()).unwrap_or(0.0);
                        let heart_rate = ev
                            .get("heart_rate")
                            .and_then(|v| v.as_i64())
                            .filter(|v| *v > 0);
                        let quality = ev.get("quality").and_then(|v| v.as_str()).unwrap_or("good");
                        let source = ev.get("source").and_then(|v| v.as_str()).unwrap_or("watch");
                        if ts > 0 && (1.0..=300.0).contains(&value) {
                            let day = local_day(ts);
                            let at_sec = ts / 1000;
                            tx.execute(
                                "DELETE FROM hrv_records WHERE ABS(at_sec - ?1) <= 60",
                                params![at_sec],
                            )?;
                            tx.execute(
                                "INSERT INTO hrv_records(date_day, at_sec, hrv_ms, heart_rate, quality, source)
                                 VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
                                params![day, at_sec, value, heart_rate, quality, source],
                            )?;
                            tx.execute(
                                "INSERT OR REPLACE INTO metric_points(metric, ts_ms, value, source)
                                 VALUES('hrv', ?1, ?2, ?3)",
                                params![ts, value, source],
                            )?;
                            let _ = up_hrv.execute(params![day, value, now_ms()]);
                            counts[6] += 1;
                        }
                    }
                    "sleep_hrv" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let start_ms = ev.get("start").and_then(|v| v.as_i64()).unwrap_or(0);
                        let avg = ev.get("avg").and_then(|v| v.as_f64()).unwrap_or(0.0);
                        let min = ev.get("min").and_then(|v| v.as_f64()).unwrap_or(-1.0);
                        let max = ev.get("max").and_then(|v| v.as_f64()).unwrap_or(-1.0);
                        let delta = ev.get("delta").and_then(|v| v.as_f64()).unwrap_or(-1.0);
                        if ts > 0 && (1.0..=300.0).contains(&avg) {
                            let day = local_day(ts);
                            tx.execute(
                                "INSERT INTO sleep_hrv_records(
                                    date_day, sleep_start_ms, avg_hrv, min_baseline,
                                    max_baseline, day_to_baseline, updated_ms)
                                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
                                 ON CONFLICT(date_day) DO UPDATE SET
                                    sleep_start_ms = excluded.sleep_start_ms,
                                    avg_hrv = excluded.avg_hrv,
                                    min_baseline = excluded.min_baseline,
                                    max_baseline = excluded.max_baseline,
                                    day_to_baseline = excluded.day_to_baseline,
                                    updated_ms = excluded.updated_ms",
                                params![day, start_ms, avg, min, max, delta, now_ms()],
                            )?;
                            let _ = ins_metric.execute(params!["hrv", ts, avg]);
                            let _ = up_hrv.execute(params![day, avg, now_ms()]);
                            counts[6] += 1;
                        }
                    }
                    "respiration" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let value = ev.get("v").and_then(|v| v.as_f64()).unwrap_or(0.0);
                        if ts > 0 && (4.0..=80.0).contains(&value) {
                            let day = local_day(ts);
                            let _ = ins_metric.execute(params!["respiration", ts, value]);
                            tx.execute(
                                "INSERT INTO daily_metrics(date_day, respiration, updated_ms)
                                 VALUES(?1, ?2, ?3)
                                 ON CONFLICT(date_day) DO UPDATE SET
                                    respiration = excluded.respiration,
                                    updated_ms = excluded.updated_ms",
                                params![day, value, now_ms()],
                            )?;
                            counts[9] += 1;
                        }
                    }
                    "stress" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let value = ev.get("v").and_then(|v| v.as_f64()).unwrap_or(0.0);
                        if ts > 0 && (1.0..=100.0).contains(&value) {
                            let day = local_day(ts);
                            let _ = ins_metric.execute(params!["stress", ts, value]);
                            let _ = up_stress.execute(params![day, value, now_ms()]);
                            counts[7] += 1;
                        }
                    }
                    "skin_temp" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let value = ev.get("v").and_then(|v| v.as_f64()).unwrap_or(0.0);
                        if ts > 0 && (20.0..=42.0).contains(&value) {
                            let day = local_day(ts);
                            let _ = ins_metric.execute(params!["skin_temp", ts, value]);
                            let _ = up_skin_temp.execute(params![day, value, now_ms()]);
                            counts[8] += 1;
                        }
                    }
                    "body_temp" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let value = ev.get("v").and_then(|v| v.as_f64()).unwrap_or(0.0);
                        if ts > 0 && (34.0..=42.0).contains(&value) {
                            let day = local_day(ts);
                            let _ = ins_metric.execute(params!["body_temp", ts, value]);
                            let _ = up_body_temp.execute(params![day, value, now_ms()]);
                            counts[8] += 1;
                        }
                    }
                    "emotion" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let status = ev.get("status").and_then(|v| v.as_i64()).unwrap_or(0);
                        let valence = ev.get("valence").and_then(|v| v.as_f64());
                        let arousal = ev.get("arousal").and_then(|v| v.as_f64());
                        if ts > 0 && (status > 0 || valence.is_some() || arousal.is_some()) {
                            let _ = tx.execute(
                                "INSERT OR REPLACE INTO emotion_records(ts_ms, status, valence, arousal)
                                 VALUES(?1, ?2, ?3, ?4)",
                                params![ts, status, valence, arousal],
                            );
                            counts[9] += 1;
                        }
                    }
                    "arrhythmia" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let result = ev.get("result").and_then(|v| v.as_i64()).unwrap_or(0);
                        let measure_type =
                            ev.get("measure_type").and_then(|v| v.as_i64()).unwrap_or(0);
                        if ts > 0 && (1..=5).contains(&result) {
                            let _ = tx.execute(
                                "INSERT OR REPLACE INTO arrhythmia_records(ts_ms, result_type, measure_type, source)
                                 VALUES(?1, ?2, ?3, 'watch')",
                                params![ts, result, measure_type],
                            );
                            counts[9] += 1;
                        }
                    }
                    "apnea" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let level = ev.get("level").and_then(|v| v.as_i64()).unwrap_or(0);
                        if ts > 0 && (0..=10).contains(&level) {
                            let _ = tx.execute(
                                "INSERT OR REPLACE INTO apnea_records(ts_ms, level, source)
                                 VALUES(?1, ?2, 'watch')",
                                params![ts, level],
                            );
                            counts[9] += 1;
                        }
                    }
                    "active_hour" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
                        let value = ev.get("v").and_then(|v| v.as_i64()).unwrap_or(1);
                        if ts > 0 {
                            let _ = tx.execute(
                                "INSERT OR REPLACE INTO hourly_status(ts_ms, value) VALUES(?1, ?2)",
                                params![ts, value],
                            );
                            counts[9] += 1;
                        }
                    }
                    "daily_ring" => {
                        let end = ev.get("end").and_then(|v| v.as_i64()).unwrap_or(0);
                        if end > 0 {
                            let day = local_day(end);
                            let _ = tx.execute(
                                "INSERT INTO daily_rings(
                                    date_day, day_end_ms, step_goal, step_user, step_state,
                                    calorie_goal_milli, calorie_user_milli, calorie_state,
                                    duration_goal_min, duration_user_min, duration_state,
                                    active_goal_hours, active_user_hours, active_state, updated_ms)
                                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
                                 ON CONFLICT(date_day) DO UPDATE SET
                                    day_end_ms = excluded.day_end_ms,
                                    step_goal = excluded.step_goal,
                                    step_user = excluded.step_user,
                                    step_state = excluded.step_state,
                                    calorie_goal_milli = excluded.calorie_goal_milli,
                                    calorie_user_milli = excluded.calorie_user_milli,
                                    calorie_state = excluded.calorie_state,
                                    duration_goal_min = excluded.duration_goal_min,
                                    duration_user_min = excluded.duration_user_min,
                                    duration_state = excluded.duration_state,
                                    active_goal_hours = excluded.active_goal_hours,
                                    active_user_hours = excluded.active_user_hours,
                                    active_state = excluded.active_state,
                                    updated_ms = excluded.updated_ms",
                                params![
                                    day,
                                    end,
                                    field(ev, "step_goal"),
                                    field(ev, "step_user"),
                                    field(ev, "step_state"),
                                    field(ev, "calorie_goal_milli"),
                                    field(ev, "calorie_user_milli"),
                                    field(ev, "calorie_state"),
                                    field(ev, "duration_goal_min"),
                                    field(ev, "duration_user_min"),
                                    field(ev, "duration_state"),
                                    field(ev, "active_goal_hours"),
                                    field(ev, "active_user_hours"),
                                    field(ev, "active_state"),
                                    now_ms(),
                                ],
                            );
                            counts[9] += 1;
                        }
                    }
                    "fitness_totals" => {
                        let steps = ev.get("steps").and_then(|v| v.as_i64()).unwrap_or(0);
                        let calories = ev.get("calories").and_then(|v| v.as_i64()).unwrap_or(0);
                        let distance = ev.get("distance").and_then(|v| v.as_i64()).unwrap_or(0);
                        let today = local_day(now_ms());
                        let _ = up_daily.execute(params![
                            today,
                            steps,
                            calories,
                            distance,
                            Option::<f64>::None,
                            Option::<f64>::None,
                            now_ms()
                        ]);
                        counts[5] += 1;
                    }
                    // 一轮同步收尾：把时间戳落到库里，否则手表页的「最后一次同步」
                    // 只有内存值，重启进程就退回旧版导入时的时间
                    "sync_done" => {
                        let end = ev.get("end").and_then(|v| v.as_i64()).unwrap_or(0);
                        let at = if end > 0 { end * 1000 } else { now_ms() };
                        let _ = tx.execute(
                            "UPDATE devices SET last_sync_ms = ?1 WHERE id = 'watch-1'",
                            params![at],
                        );
                    }
                    // 体脂秤一次测量会先来体重包、再来阻抗包。
                    // 60 秒内同源的记录合并成一条，避免一次称重存两条。
                    "weight" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or_else(now_ms);
                        let kg = ev.get("kg").and_then(|v| v.as_f64()).unwrap_or(0.0);
                        if ts > 0 && (10.0..=300.0).contains(&kg) {
                            let opt =
                                |k: &str| ev.get(k).and_then(|v| v.as_f64()).filter(|v| *v > 0.0);
                            let body_fat = opt("body_fat");
                            let muscle = opt("muscle");
                            let water = opt("water");
                            let protein = opt("protein");
                            let bone = opt("bone");
                            let fat_mass = opt("fat_mass");
                            let muscle_mass = opt("muscle_mass");
                            let water_mass = opt("water_mass");
                            let height = opt("height_cm");
                            let protein_mass = opt("protein_mass");
                            let bone_mass = opt("bone_mass");
                            let skeletal_muscle = opt("skeletal_muscle");
                            let skeletal_muscle_mass = opt("skeletal_muscle_mass");
                            let subcutaneous_fat = opt("subcutaneous_fat");
                            let subcutaneous_fat_mass = opt("subcutaneous_fat_mass");
                            let resistance = opt("resistance");
                            let model = ev
                                .get("model")
                                .and_then(|v| v.as_str())
                                .filter(|v| !v.is_empty());
                            let bmi = height
                                .map(|h| kg / ((h / 100.0) * (h / 100.0)))
                                .filter(|v| v.is_finite() && *v > 0.0);
                            let source =
                                ev.get("source").and_then(|v| v.as_str()).unwrap_or("scale");
                            let device = ev.get("device").and_then(|v| v.as_str()).unwrap_or("");
                            let existing: Option<String> = {
                                let mut stmt = tx.prepare(
                                    "SELECT id FROM weight_records
                                     WHERE source = ?1 AND timestamp_ms BETWEEN ?2 AND ?3
                                     ORDER BY timestamp_ms DESC LIMIT 1",
                                )?;
                                stmt.query_row(params![source, ts - 60_000, ts + 60_000], |r| {
                                    r.get(0)
                                })
                                .ok()
                            };
                            if let Some(id) = existing {
                                let _ = tx.execute(
                                    "UPDATE weight_records SET
                                        timestamp_ms = ?2,
                                        weight_kg = ?3,
                                        body_fat_percent = COALESCE(?4, body_fat_percent),
                                        muscle_percent = COALESCE(?5, muscle_percent),
                                        water_percent = COALESCE(?6, water_percent),
                                        protein_percent = COALESCE(?7, protein_percent),
                                        bone_percent = COALESCE(?8, bone_percent),
                                        fat_mass_kg = COALESCE(?9, fat_mass_kg),
                                        muscle_mass_kg = COALESCE(?10, muscle_mass_kg),
                                        water_mass_kg = COALESCE(?11, water_mass_kg),
                                        height_cm = COALESCE(?12, height_cm),
                                        bmi = COALESCE(?13, bmi),
                                        device_name = CASE WHEN ?14 <> '' THEN ?14 ELSE device_name END,
                                        protein_mass_kg = COALESCE(?15, protein_mass_kg),
                                        bone_mass_kg = COALESCE(?16, bone_mass_kg),
                                        skeletal_muscle_percent = COALESCE(?17, skeletal_muscle_percent),
                                        skeletal_muscle_mass_kg = COALESCE(?18, skeletal_muscle_mass_kg),
                                        subcutaneous_fat_percent = COALESCE(?19, subcutaneous_fat_percent),
                                        subcutaneous_fat_mass_kg = COALESCE(?20, subcutaneous_fat_mass_kg),
                                        resistance_ohm = COALESCE(?21, resistance_ohm),
                                        body_composition_model = COALESCE(?22, body_composition_model)
                                     WHERE id = ?1",
                                    params![
                                        id, ts, kg, body_fat, muscle, water, protein, bone,
                                        fat_mass, muscle_mass, water_mass, height, bmi, device,
                                        protein_mass, bone_mass, skeletal_muscle,
                                        skeletal_muscle_mass, subcutaneous_fat,
                                        subcutaneous_fat_mass, resistance, model,
                                    ],
                                );
                            } else {
                                let id = format!("scale-{ts}");
                                let _ = tx.execute(
                                    "INSERT OR REPLACE INTO weight_records(
                                        id, timestamp_ms, weight_kg, body_fat_percent, muscle_percent,
                                        water_percent, source, height_cm, bmi, fat_mass_kg,
                                        muscle_mass_kg, water_mass_kg, protein_percent, bone_percent,
                                        device_name, protein_mass_kg, bone_mass_kg,
                                        skeletal_muscle_percent, skeletal_muscle_mass_kg,
                                        subcutaneous_fat_percent, subcutaneous_fat_mass_kg,
                                        resistance_ohm, body_composition_model)
                                     VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                                            ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23)",
                                    params![
                                        id, ts, kg, body_fat, muscle, water, source, height, bmi,
                                        fat_mass, muscle_mass, water_mass, protein, bone, device,
                                        protein_mass, bone_mass, skeletal_muscle,
                                        skeletal_muscle_mass, subcutaneous_fat,
                                        subcutaneous_fat_mass, resistance, model,
                                    ],
                                );
                            }
                            counts[9] += 1;
                        }
                    }
                    // 一条运动攒齐后的完整事件：汇总 + 心率/海拔/动态采样 + 配速 + GPS 轨迹
                    "workout" => {
                        if ingest_workout(&tx, ev)? {
                            workout_count += 1;
                        }
                    }
                    // 连接与同步日志：原生层给什么就存什么，详情页按天分组展示
                    "log" => {
                        let ts = ev.get("ts").and_then(|v| v.as_i64()).unwrap_or_else(now_ms);
                        let msg = ev.get("msg").and_then(|v| v.as_str()).unwrap_or("");
                        if !msg.is_empty() {
                            let _ = tx.execute(
                                "INSERT INTO watch_logs(ts_ms, msg) VALUES(?1, ?2)",
                                params![ts, msg],
                            );
                        }
                    }
                    // 电量与连接状态：name/address 为空时保留库里已有的，battery<0 表示这次没读到
                    "device" => {
                        let battery = ev.get("battery").and_then(|v| v.as_i64()).unwrap_or(-1);
                        let connected = ev
                            .get("connected")
                            .and_then(|v| v.as_bool())
                            .unwrap_or(false);
                        let name = ev.get("name").and_then(|v| v.as_str()).unwrap_or("");
                        let address = ev.get("address").and_then(|v| v.as_str()).unwrap_or("");
                        if let Some(charging) = ev.get("charging").and_then(|v| v.as_bool()) {
                            let _ = tx.execute(
                                "INSERT INTO settings(key, value) VALUES('watch_charging', ?1)
                                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                params![if charging { "1" } else { "0" }],
                            );
                        }
                        let _ = tx.execute(
                            "INSERT INTO devices(id, name, kind, address, battery, last_sync_ms, connected)
                             VALUES('watch-1', ?1, 'watch', ?2, ?3, NULL, ?4)
                             ON CONFLICT(id) DO UPDATE SET
                                name = CASE WHEN excluded.name <> '' THEN excluded.name ELSE devices.name END,
                                address = CASE WHEN excluded.address <> '' THEN excluded.address ELSE devices.address END,
                                battery = CASE WHEN excluded.battery >= 0 THEN excluded.battery ELSE devices.battery END,
                                connected = excluded.connected",
                            params![name, address, battery, connected],
                        )?;
                    }
                    _ => {}
                }
            }
        }

        // 日志只留最近 2000 条：每分钟同步都会写几行，全留着几个月就查不动了
        let _ = tx.execute(
            "DELETE FROM watch_logs WHERE ts_ms < (
                SELECT ts_ms FROM watch_logs ORDER BY ts_ms DESC LIMIT 1 OFFSET 2000
             )",
            [],
        );

        // 1. 步数样本按天聚合回 daily_metrics。
        //    样本下载不全时 SUM 会偏小，而 fitness_totals 是全量日汇总（权威值）。
        //    取 MAX：样本聚合可以补高，但绝不把权威总量拉低（否则手表 9712 步会被 8843 覆盖）。
        {
            let mut stmt = tx.prepare("SELECT ts, steps, calories, distance FROM step_samples")?;
            let mut by_day: std::collections::HashMap<i64, (i64, i64, i64)> =
                std::collections::HashMap::new();
            let rows = stmt.query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                ))
            })?;
            for row in rows {
                let row = row?;
                let day = local_day(row.0 * 1000);
                if touched_days.contains(&day) {
                    let e = by_day.entry(day).or_insert((0, 0, 0));
                    e.0 += row.1;
                    e.1 += row.2;
                    e.2 += row.3;
                }
            }
            drop(stmt);
            let mut up = tx.prepare(
                "INSERT INTO daily_metrics(date_day, steps, calories, active_calories, distance_m, updated_ms)
                 VALUES(?1, ?2, ?3, ?3, ?4, ?5)
                 ON CONFLICT(date_day) DO UPDATE SET
                    steps = MAX(excluded.steps, daily_metrics.steps),
                    calories = MAX(excluded.calories, daily_metrics.calories),
                    active_calories = MAX(excluded.active_calories, daily_metrics.active_calories),
                    distance_m = MAX(excluded.distance_m, daily_metrics.distance_m),
                    updated_ms = excluded.updated_ms",
            )?;
            for (day, (steps, cal, dist)) in by_day {
                let _ = up.execute(params![day, steps, cal, dist, now_ms()]);
            }
        }

        // 2. 睡眠：从 sleep_stages 重建全部会话（数据量小，全量重建幂等）
        if counts[4] > 0 {
            rebuild_sleep_sessions(&tx)?;
        }

        tx.commit()?;
        Ok(())
    })?;

    Ok(json!({
        "hr": counts[0], "spo2": counts[1], "resting_hr": counts[2],
        "steps": counts[3], "sleep": counts[4], "totals": counts[5],
        "hrv": counts[6], "stress": counts[7], "temperature": counts[8],
        "other": counts[9], "workouts": workout_count
    })
    .to_string())
}

/// 把原生层抛来的一条运动记录落进 workouts 表。
/// 同一条运动重拉时（编号 + 开始时间相同）走 INSERT OR REPLACE，保证幂等。
fn ingest_workout(tx: &rusqlite::Transaction<'_>, ev: &Value) -> Result<bool> {
    let number = ev.get("number").and_then(|v| v.as_i64()).unwrap_or(0);
    let start_sec = ev.get("start").and_then(|v| v.as_i64()).unwrap_or(0);
    if start_sec <= 0 {
        return Ok(false);
    }
    let duration = ev
        .get("duration")
        .and_then(|v| v.as_i64())
        .unwrap_or(0)
        .max(0);
    let end_sec = ev
        .get("end")
        .and_then(|v| v.as_i64())
        .filter(|end| *end > start_sec)
        .unwrap_or(start_sec + duration);
    let distance = ev
        .get("distance")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0)
        .max(0.0);
    let calories = ev
        .get("calories")
        .and_then(|v| v.as_i64())
        .unwrap_or(0)
        .max(0);
    let steps = ev.get("steps").and_then(|v| v.as_i64()).unwrap_or(0).max(0);
    let load = ev.get("load").and_then(|v| v.as_i64()).unwrap_or(0).max(0);
    let recovery_min = ev
        .get("recovery")
        .and_then(|v| v.as_i64())
        .unwrap_or(0)
        .max(0);
    let max_met_raw = ev
        .get("max_met")
        .and_then(|v| v.as_f64())
        .filter(|v| *v > 0.0);
    let gain = ev
        .get("elevation_gain")
        .and_then(|v| v.as_f64())
        .filter(|v| *v > 0.0);
    let loss = ev
        .get("elevation_loss")
        .and_then(|v| v.as_f64())
        .filter(|v| *v > 0.0);
    let type_code = ev.get("type").and_then(|v| v.as_i64()).unwrap_or(0);

    let samples = ev
        .get("samples")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let hr_values: Vec<i64> = samples
        .iter()
        .filter_map(|s| s.get("hr").and_then(|v| v.as_i64()))
        .filter(|bpm| (1..=254).contains(bpm))
        .collect();
    let avg_hr_ev = ev.get("avg_hr").and_then(|v| v.as_i64()).unwrap_or(0);
    let avg_hr = if avg_hr_ev > 0 {
        avg_hr_ev
    } else if hr_values.is_empty() {
        0
    } else {
        hr_values.iter().sum::<i64>() / hr_values.len() as i64
    };
    let max_hr_ev = ev.get("max_hr").and_then(|v| v.as_i64()).unwrap_or(0);
    let max_hr = max_hr_ev.max(hr_values.iter().copied().max().unwrap_or(0));

    let dynamics = ev
        .get("dynamics")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let cadences: Vec<f64> = dynamics
        .iter()
        .filter_map(|d| d.get("cad").and_then(|v| v.as_f64()))
        .filter(|v| *v > 0.0)
        .collect();
    let cadence = if cadences.is_empty() {
        None
    } else {
        Some(cadences.iter().sum::<f64>() / cadences.len() as f64)
    };
    let avg_pace = if distance > 500.0 && duration > 0 {
        Some(duration as f64 / (distance / 1000.0))
    } else {
        None
    };

    let splits = ev.get("splits").cloned().unwrap_or_else(|| json!([]));
    let segments = ev.get("segments").cloned().unwrap_or_else(|| json!([]));
    let splits_json = splits
        .as_array()
        .filter(|a| !a.is_empty())
        .and_then(|_| serde_json::to_string(&splits).ok());
    let segments_json = segments
        .as_array()
        .filter(|a| !a.is_empty())
        .and_then(|_| serde_json::to_string(&segments).ok());
    let detail_json = if splits.as_array().map(|a| a.is_empty()).unwrap_or(true)
        && segments.as_array().map(|a| a.is_empty()).unwrap_or(true)
    {
        None
    } else {
        Some(json!({"splits": splits, "segments": segments}).to_string())
    };
    let samples_json = ev.get("samples").map(|v| v.to_string());
    let altitude_json = ev
        .get("altitude")
        .and_then(|v| v.as_array())
        .filter(|a| !a.is_empty())
        .and_then(|v| serde_json::to_string(v).ok());
    let dynamics_json = ev
        .get("dynamics")
        .and_then(|v| v.as_array())
        .filter(|a| !a.is_empty())
        .and_then(|v| serde_json::to_string(v).ok());
    let track_json = ev
        .get("track")
        .and_then(|v| v.as_array())
        .filter(|a| a.len() > 1)
        .and_then(|v| serde_json::to_string(v).ok());
    let recovery_json = ev
        .get("recovery_hrs")
        .and_then(|v| v.as_array())
        .filter(|a| !a.is_empty())
        .and_then(|v| serde_json::to_string(v).ok());
    let training_points = ev
        .get("training_points")
        .and_then(|v| v.as_i64())
        .filter(|v| *v > 0);
    let epoc = ev.get("epoc").and_then(|v| v.as_i64()).filter(|v| *v > 0);
    let stat_extend_json = ev
        .get("stat_extend")
        .and_then(|v| v.as_object())
        .filter(|m| !m.is_empty())
        .and_then(|v| serde_json::to_string(v).ok());
    let run_pace_zones_json = ev
        .get("run_pace_zones")
        .and_then(|v| v.as_array())
        .filter(|a| !a.is_empty())
        .and_then(|v| serde_json::to_string(v).ok());
    let max_altitude = ev.get("max_altitude").and_then(|v| v.as_f64());
    let min_altitude = ev.get("min_altitude").and_then(|v| v.as_f64());
    let alg_type = ev
        .get("alg_type")
        .and_then(|v| v.as_i64())
        .filter(|v| *v > 0);

    let id = format!("watch-{number}-{start_sec}");
    let sport = sport_label(type_code);
    let start_ms = start_sec * 1000;
    // 旧版导入的行里可能有手表汇总包没有的跑力、最大 MET、EPOC、训练积分和
    // 扩展统计。去重删除前先把它们兜到新行上，否则一次手表同步就会把迁移数据抹掉。
    let carried: Option<(
        Option<f64>,
        Option<f64>,
        Option<i64>,
        Option<i64>,
        Option<String>,
        Option<String>,
        Option<f64>,
        Option<f64>,
        Option<i64>,
    )> = tx
        .query_row(
            "SELECT vo2max, max_met, training_points, epoc, stat_extend_json,
                    run_pace_zones_json, max_altitude, min_altitude, alg_type
             FROM workouts
             WHERE sport = ?1 AND ABS(start_ms - ?2) <= 120000
             ORDER BY CASE WHEN id LIKE 'legacy-%' THEN 0 ELSE 1 END
             LIMIT 1",
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
                    r.get(7)?,
                    r.get(8)?,
                ))
            },
        )
        .optional()?;
    let (
        carried_vo2max,
        carried_max_met,
        carried_training_points,
        carried_epoc,
        carried_stat_extend,
        carried_pace_zones,
        carried_max_altitude,
        carried_min_altitude,
        carried_alg_type,
    ) = carried.unwrap_or((None, None, None, None, None, None, None, None, None));
    let prior_detail: Option<(
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
    )> = tx
        .query_row(
            "SELECT track_json, samples_json, dynamics_json, altitude_json,
                    recovery_json, detail_json, splits_json
             FROM workouts
             WHERE sport = ?1 AND ABS(start_ms - ?2) <= 120000
             ORDER BY CASE WHEN id LIKE 'legacy-%' THEN 0 ELSE 1 END
             LIMIT 1",
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
    let (
        prior_track,
        prior_samples,
        prior_dynamics,
        prior_altitude,
        prior_recovery,
        prior_detail,
        prior_splits,
    ) = prior_detail.unwrap_or((None, None, None, None, None, None, None));
    let track_json =
        store::merge_json_point_series(prior_track.as_deref(), track_json.as_deref(), "t");
    let samples_json =
        store::merge_json_point_series(prior_samples.as_deref(), samples_json.as_deref(), "t");
    let dynamics_json =
        store::merge_json_point_series(prior_dynamics.as_deref(), dynamics_json.as_deref(), "t");
    let altitude_json =
        store::merge_json_point_series(prior_altitude.as_deref(), altitude_json.as_deref(), "t");
    let recovery_json = store::richer_json(prior_recovery.as_deref(), recovery_json.as_deref());
    let detail_json = store::richer_json(prior_detail.as_deref(), detail_json.as_deref());
    let splits_json = store::richer_json(prior_splits.as_deref(), splits_json.as_deref());
    let max_met = max_met_raw
        .map(|v| if v > 1000.0 { v / 100_000.0 } else { v })
        .or(carried_max_met);
    // GT5 不在汇总里单独下发 VO2max，只给实测 maxMET(字段 0x10)。1 MET 按定义就是
    // 静息耗氧 3.5 ml/kg/min，故峰值摄氧量 = maxMET × 3.5，即这场的 VO2max；与
    // legacy 导入同一口径。max_met 此时已是换算后的真实 METs。
    let vo2max = max_met
        .map(|m| m * 3.5)
        .filter(|v| (1.0..=120.0).contains(v))
        .or_else(|| carried_vo2max.filter(|v| (1.0..=120.0).contains(v)));
    // 旧版迁移留下的是 legacy-* 主键，同一场运动会以两套 id 各存一份。
    // 同类型、开始时间相差 2 分钟内视为同一场，保留本次手表同步的完整数据。
    tx.execute(
        "DELETE FROM workouts WHERE id <> ?1 AND sport = ?2 AND ABS(start_ms - ?3) <= 120000",
        params![id, sport, start_ms],
    )?;
    // 手表每次同步都会把同一批运动再发一遍。INSERT OR REPLACE 会删掉再插回
    // 整行（轨迹 JSON 动辄上百 KB），增量同步就会被这批“没变的数据”撑爆。
    // 改成真正的 upsert：内容完全一致时 WHERE 不成立，不产生任何写入。
    tx.execute(
        "INSERT INTO workouts(
            id, source, sport, start_ms, end_ms, distance_m, calories, avg_hr, max_hr, steps, load,
            aerobic_effect, recovery_time_min, track_json, samples_json, synced, created_ms,
            type_code, total_time_sec, active_calories, max_met, vo2max, anaerobic_effect,
            elevation_gain, elevation_loss, avg_pace_sec, cadence, detail_json,
            dynamics_json, altitude_json, recovery_json, training_points, epoc,
            stat_extend_json, run_pace_zones_json, max_altitude, min_altitude, alg_type,
            splits_json)
         VALUES(?1, 'watch', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
            ?11, ?12, ?13, ?14, 1, ?15,
            ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29,
            ?30, ?31, ?32, ?33, ?34, ?35, ?36, ?37)
         ON CONFLICT(id) DO UPDATE SET
            source = excluded.source,
            sport = excluded.sport,
            start_ms = excluded.start_ms,
            end_ms = excluded.end_ms,
            distance_m = excluded.distance_m,
            calories = excluded.calories,
            avg_hr = excluded.avg_hr,
            max_hr = excluded.max_hr,
            steps = excluded.steps,
            load = excluded.load,
            aerobic_effect = excluded.aerobic_effect,
            recovery_time_min = excluded.recovery_time_min,
            track_json = excluded.track_json,
            samples_json = excluded.samples_json,
            synced = excluded.synced,
            type_code = excluded.type_code,
            total_time_sec = excluded.total_time_sec,
            active_calories = excluded.active_calories,
            max_met = excluded.max_met,
            vo2max = excluded.vo2max,
            anaerobic_effect = excluded.anaerobic_effect,
            elevation_gain = excluded.elevation_gain,
            elevation_loss = excluded.elevation_loss,
            avg_pace_sec = excluded.avg_pace_sec,
            cadence = excluded.cadence,
            detail_json = excluded.detail_json,
            dynamics_json = excluded.dynamics_json,
            altitude_json = excluded.altitude_json,
            recovery_json = excluded.recovery_json,
            training_points = excluded.training_points,
            epoc = excluded.epoc,
            stat_extend_json = excluded.stat_extend_json,
            run_pace_zones_json = excluded.run_pace_zones_json,
            max_altitude = excluded.max_altitude,
            min_altitude = excluded.min_altitude,
            alg_type = excluded.alg_type,
            splits_json = excluded.splits_json
         WHERE
            workouts.sport IS NOT excluded.sport OR
            workouts.start_ms IS NOT excluded.start_ms OR
            workouts.end_ms IS NOT excluded.end_ms OR
            workouts.distance_m IS NOT excluded.distance_m OR
            workouts.calories IS NOT excluded.calories OR
            workouts.avg_hr IS NOT excluded.avg_hr OR
            workouts.max_hr IS NOT excluded.max_hr OR
            workouts.steps IS NOT excluded.steps OR
            workouts.load IS NOT excluded.load OR
            workouts.aerobic_effect IS NOT excluded.aerobic_effect OR
            workouts.recovery_time_min IS NOT excluded.recovery_time_min OR
            workouts.track_json IS NOT excluded.track_json OR
            workouts.samples_json IS NOT excluded.samples_json OR
            workouts.type_code IS NOT excluded.type_code OR
            workouts.total_time_sec IS NOT excluded.total_time_sec OR
            workouts.active_calories IS NOT excluded.active_calories OR
            workouts.max_met IS NOT excluded.max_met OR
            workouts.vo2max IS NOT excluded.vo2max OR
            workouts.anaerobic_effect IS NOT excluded.anaerobic_effect OR
            workouts.elevation_gain IS NOT excluded.elevation_gain OR
            workouts.elevation_loss IS NOT excluded.elevation_loss OR
            workouts.avg_pace_sec IS NOT excluded.avg_pace_sec OR
            workouts.cadence IS NOT excluded.cadence OR
            workouts.detail_json IS NOT excluded.detail_json OR
            workouts.dynamics_json IS NOT excluded.dynamics_json OR
            workouts.altitude_json IS NOT excluded.altitude_json OR
            workouts.recovery_json IS NOT excluded.recovery_json OR
            workouts.training_points IS NOT excluded.training_points OR
            workouts.epoc IS NOT excluded.epoc OR
            workouts.stat_extend_json IS NOT excluded.stat_extend_json OR
            workouts.run_pace_zones_json IS NOT excluded.run_pace_zones_json OR
            workouts.max_altitude IS NOT excluded.max_altitude OR
            workouts.min_altitude IS NOT excluded.min_altitude OR
            workouts.alg_type IS NOT excluded.alg_type OR
            workouts.splits_json IS NOT excluded.splits_json",
        params![
            id,
            sport,
            start_ms,
            end_sec * 1000,
            distance,
            calories,
            avg_hr,
            max_hr,
            steps,
            load,
            ev.get("aerobic").and_then(|v| v.as_f64()).unwrap_or(0.0) / 10.0,
            recovery_min,
            track_json,
            samples_json,
            now_ms(),
            type_code,
            ev.get("total_time")
                .and_then(|v| v.as_i64())
                .filter(|v| *v > 0)
                .unwrap_or(duration),
            calories,
            max_met,
            vo2max,
            ev.get("anaerobic").and_then(|v| v.as_f64()).unwrap_or(0.0) / 10.0,
            gain,
            loss,
            avg_pace,
            cadence,
            detail_json,
            dynamics_json,
            altitude_json,
            recovery_json,
            training_points.or(carried_training_points),
            epoc.or(carried_epoc),
            stat_extend_json.or(carried_stat_extend),
            run_pace_zones_json.or(carried_pace_zones),
            max_altitude.or(carried_max_altitude),
            min_altitude.or(carried_min_altitude),
            alg_type.or(carried_alg_type),
            splits_json,
        ],
    )?;
    Ok(true)
}

struct Session {
    start: i64,
    end: i64,
    deep: i64,
    light: i64,
    rem: i64,
    awake: i64,
    sleep: i64,
}

pub(crate) fn rebuild_sleep_sessions(conn: &Connection) -> Result<()> {
    let mut rows: Vec<(i64, i64, String)> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT start_ms, end_ms, stage FROM sleep_stages ORDER BY start_ms, end_ms",
        )?;
        let iter = stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?;
        rows.extend(iter.flatten());
    }

    // 观察到的分期时间范围：只有和某条历史会话重叠的分期，才有资格
    // 判断「这条会话已经被新的分期数据取代」。旧版迁入/早期同步可能只留下
    // 会话摘要而行分期已被清理，重建时不能因为查不到分期就把摘要删掉。
    let stage_spans: Vec<(i64, i64)> = rows.iter().map(|(a, b, _)| (*a, *b)).collect();
    let fallback_naps = daytime_nap_sessions(&rows);
    let mut sessions: Vec<(Session, Vec<(i64, i64, String)>)> = Vec::new();
    let mut cluster: Vec<(i64, i64, String)> = Vec::new();
    let mut cluster_end = i64::MIN;
    for (a, b, stage) in rows {
        if !cluster.is_empty() && a - cluster_end > 45 * 60_000 {
            push_cluster(&mut sessions, std::mem::take(&mut cluster));
            cluster_end = i64::MIN;
        }
        cluster_end = cluster_end.max(b);
        cluster.push((a, b, stage));
    }
    if !cluster.is_empty() {
        push_cluster(&mut sessions, cluster);
    }

    let mut accepted: Vec<(Session, Vec<(i64, i64, String)>)> = sessions
        .into_iter()
        .filter(|(session, _)| sleep_session_valid(session))
        .collect();
    for nap in fallback_naps {
        let overlaps = accepted.iter().any(|(session, _)| {
            let overlap = (nap.end.min(session.end) - nap.start.max(session.start)).max(0);
            let shorter = (nap.end - nap.start)
                .min(session.end - session.start)
                .max(1);
            overlap * 2 > shorter
        });
        if !overlaps {
            accepted.push((nap, Vec::new()));
        }
    }
    accepted.sort_by_key(|(session, _)| session.start);

    // 手表每分钟都会重发整段睡眠分期。先和现有会话逐字段比一遍，
    // 只写真正变化的行；否则每次同步都会 DELETE+INSERT 上百行，
    // 既放大 SQLite 写入，也会让云端增量里全是重复数据。
    let mut existing: std::collections::HashMap<
        (i64, String),
        (i64, f64, f64, f64, f64),
    > = std::collections::HashMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT start_ms, source, end_ms, deep_min, light_min, rem_min, awake_min
             FROM sleep_sessions",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((
                (r.get::<_, i64>(0)?, r.get::<_, String>(1)?),
                (
                    r.get::<_, i64>(2)?,
                    r.get::<_, f64>(3)?,
                    r.get::<_, f64>(4)?,
                    r.get::<_, f64>(5)?,
                    r.get::<_, f64>(6)?,
                ),
            ))
        })?;
        for row in rows {
            let (key, value) = row?;
            existing.insert(key, value);
        }
    }
    for (s, stage_rows) in &accepted {
        let _ = stage_rows;
        let next = (
            s.end,
            s.deep as f64,
            s.light as f64,
            s.rem as f64,
            s.awake as f64,
        );
        if existing
            .get(&(s.start, "watch".to_string()))
            .is_some_and(|old| {
                old.0 == next.0
                    && (old.1 - next.1).abs() < 1e-9
                    && (old.2 - next.2).abs() < 1e-9
                    && (old.3 - next.3).abs() < 1e-9
                    && (old.4 - next.4).abs() < 1e-9
            })
        {
            existing.remove(&(s.start, "watch".to_string()));
            continue;
        }
        conn.execute(
            "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, 'watch')
             ON CONFLICT(start_ms, source) DO UPDATE SET
                end_ms = excluded.end_ms,
                deep_min = excluded.deep_min,
                light_min = excluded.light_min,
                rem_min = excluded.rem_min,
                awake_min = excluded.awake_min",
            params![s.start, s.end, s.deep as f64, s.light as f64, s.rem as f64, s.awake as f64],
        )?;
        existing.remove(&(s.start, "watch".to_string()));
    }
    for ((start, source), (end, ..)) in &existing {
        // 其余来源（旧版导入等）不归手表分期重建管；原逻辑会连它们一起删。
        if source != "watch" {
            continue;
        }
        if !stage_spans
            .iter()
            .any(|(stage_start, stage_end)| stage_start < end && stage_end > start)
        {
            continue;
        }
        conn.execute(
            "DELETE FROM sleep_sessions WHERE start_ms = ?1 AND source = ?2",
            params![start, source],
        )?;
    }
    // 睡眠时长写入结束日（醒来的那天）；同一天主睡眠和午睡要累加。
    crate::store::recompute_sleep_daily_metrics(conn)?;
    Ok(())
}

fn sleep_session_valid(session: &Session) -> bool {
    let asleep = session.deep + session.light + session.rem;
    let wall_min = (session.end - session.start) / 60_000;
    // 白天零星打点会被 45 分钟间隔串成一条很长的“假睡眠”（例如 6 小时里只睡着 1 小时）。
    // 真实夜间睡眠密度通常在 90% 以上；保留短睡，但丢弃低密度的长跨度片段。
    if asleep < 5 || (wall_min >= 90 && asleep * 100 < wall_min * 35) {
        return false;
    }
    // 白天 45 分钟聚类也会把几次零星打点和午睡拼成 1~2 小时的片段。
    // 午睡候选本身要求密度 ≥50%，这类低密度白天片段不能反过来吞掉候选。
    let daytime = Local
        .timestamp_millis_opt(session.start)
        .single()
        .is_some_and(|dt| (11..18).contains(&dt.hour()));
    !(daytime && asleep * 100 < wall_min * 50)
}

fn union_stage_minutes(rows: &[(i64, i64, String)], stage: &str) -> i64 {
    let mut spans: Vec<(i64, i64)> = rows
        .iter()
        .filter(|(_, _, value)| value == stage)
        .map(|(start, end, _)| (*start, *end))
        .collect();
    if spans.is_empty() {
        return 0;
    }
    spans.sort_unstable();
    let (mut start, mut end) = spans[0];
    let mut total = 0;
    for (next_start, next_end) in spans.into_iter().skip(1) {
        if next_start <= end {
            end = end.max(next_end);
        } else {
            total += end - start;
            start = next_start;
            end = next_end;
        }
    }
    (total + end - start) / 60_000
}

/// 手表有时只上报分钟级 light/deep/rem，不给整段 `sleep` 锚点。
/// 午睡夹在白天静止噪声里时，45 分钟聚类会把它并成一整天低密度片段后丢掉；
/// 这里用更小的 10 分钟间隔重新聚一次，只收午后短而密的片段。
fn daytime_nap_sessions(rows: &[(i64, i64, String)]) -> Vec<Session> {
    const NAP_GAP_MS: i64 = 10 * 60_000;
    let mut out = Vec::new();
    let mut cluster: Vec<(i64, i64, String)> = Vec::new();
    let mut cluster_end = i64::MIN;
    for row in rows {
        // `sleep` 是 TruSleep 的整段锚点，可能和前面的白天碎片只隔几分钟。
        // 它是锚点而不是午睡分期，必须作为硬边界，否则锚点前的真实午睡会
        // 被并进同一个簇后随锚点一起丢掉。
        if row.2 == "sleep" {
            if !cluster.is_empty() {
                push_daytime_nap(&mut out, std::mem::take(&mut cluster));
                cluster_end = i64::MIN;
            }
            continue;
        }
        if !cluster.is_empty() && row.0 - cluster_end > NAP_GAP_MS {
            push_daytime_nap(&mut out, std::mem::take(&mut cluster));
            cluster_end = i64::MIN;
        }
        cluster_end = cluster_end.max(row.1);
        cluster.push(row.clone());
    }
    if !cluster.is_empty() {
        push_daytime_nap(&mut out, cluster);
    }
    out
}

fn push_daytime_nap(out: &mut Vec<Session>, cluster: Vec<(i64, i64, String)>) {
    if cluster.iter().any(|(_, _, stage)| stage == "sleep") {
        return;
    }
    let sleeping: Vec<&(i64, i64, String)> = cluster
        .iter()
        .filter(|(_, _, stage)| stage != "awake")
        .collect();
    if sleeping.is_empty() {
        return;
    }
    let start = sleeping.iter().map(|row| row.0).min().unwrap_or(0);
    let end = sleeping.iter().map(|row| row.1).max().unwrap_or(0);
    let Some(local_start) = Local.timestamp_millis_opt(start).single() else {
        return;
    };
    let deep = union_stage_minutes(&cluster, "deep");
    let rem = union_stage_minutes(&cluster, "rem");
    let light = union_stage_minutes(&cluster, "light");
    let asleep = deep + light + rem;
    let awake = union_stage_minutes(&cluster, "awake");
    let wall_min = (end - start) / 60_000;
    if !(11..18).contains(&local_start.hour())
        || !(20..=90).contains(&asleep)
        || wall_min > 120
        || asleep * 100 < wall_min * 50
    {
        return;
    }
    out.push(Session {
        start,
        end,
        deep,
        light,
        rem,
        awake,
        sleep: 0,
    });
}

fn merge_anchor_windows(anchors: &[(i64, i64)]) -> Vec<(i64, i64)> {
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

/// 一个聚类里若带 TruSleep 的整段 `sleep` 窗口，就以窗口为准成场；
/// 窗口外的零星分期只是白天静止噪声，不能把午睡裹进低密度长片段后一起丢掉。
fn push_cluster(
    out: &mut Vec<(Session, Vec<(i64, i64, String)>)>,
    cluster: Vec<(i64, i64, String)>,
) {
    let mut anchors: Vec<(i64, i64)> = cluster
        .iter()
        .filter(|(_, _, stage)| stage == "sleep")
        .map(|(a, b, _)| (*a, *b))
        .collect();
    if anchors.is_empty() {
        push_session(out, cluster);
        return;
    }
    anchors.sort_unstable();
    for (a, b) in merge_anchor_windows(&anchors) {
        let mut s = Session {
            start: a,
            end: b,
            deep: 0,
            light: 0,
            rem: 0,
            awake: 0,
            sleep: 0,
        };
        let clipped: Vec<(i64, i64, String)> = cluster
            .iter()
            .filter_map(|(ra, rb, stage)| {
                let start = (*ra).max(a);
                let end = (*rb).min(b);
                (end > start).then(|| (start, end, stage.clone()))
            })
            .collect();
        s.deep = union_stage_minutes(&clipped, "deep");
        s.light = union_stage_minutes(&clipped, "light");
        s.rem = union_stage_minutes(&clipped, "rem");
        s.awake = union_stage_minutes(&clipped, "awake");
        s.sleep = anchor_union_minutes(&anchors, a, b);
        let detailed = s.deep + s.light + s.rem;
        if s.sleep > detailed {
            s.light += s.sleep - detailed;
        } else if detailed > s.sleep {
            let (deep, light, rem) = scale_stage_total(s.deep, s.light, s.rem, s.sleep);
            s.deep = deep;
            s.light = light;
            s.rem = rem;
        }
        if s.end > s.start && s.deep + s.light + s.rem >= 5 {
            out.push((s, Vec::new()));
        }
    }
}

fn anchor_union_minutes(anchors: &[(i64, i64)], a: i64, b: i64) -> i64 {
    let mut total = 0;
    let mut cur: Option<(i64, i64)> = None;
    for &(x, y) in anchors {
        let x = x.max(a);
        let y = y.min(b);
        if x >= y {
            continue;
        }
        match cur {
            Some((cx, cy)) if x <= cy => cur = Some((cx, cy.max(y))),
            Some((cx, cy)) => {
                total += cy - cx;
                cur = Some((x, y));
            }
            None => cur = Some((x, y)),
        }
    }
    if let Some((cx, cy)) = cur {
        total += cy - cx;
    }
    total / 60_000
}

fn push_session(
    out: &mut Vec<(Session, Vec<(i64, i64, String)>)>,
    cluster: Vec<(i64, i64, String)>,
) {
    let mut s = Session {
        start: i64::MAX,
        end: i64::MIN,
        deep: 0,
        light: 0,
        rem: 0,
        awake: 0,
        sleep: 0,
    };
    for (a, b, stage) in &cluster {
        s.start = s.start.min(*a);
        s.end = s.end.max(*b);
        if stage == "sleep" {
            s.sleep += (b - a) / 60_000;
        }
    }
    s.deep = union_stage_minutes(&cluster, "deep");
    s.light = union_stage_minutes(&cluster, "light");
    s.rem = union_stage_minutes(&cluster, "rem");
    s.awake = union_stage_minutes(&cluster, "awake");
    // TruSleep 状态文件只给整段睡眠窗口，没有分期；把它作为总时长兜底。
    // 同一段若另有分钟级分期，不重复累加，只补“分段合计少于总窗口”的差额。
    let detailed = s.deep + s.light + s.rem;
    if s.sleep > detailed {
        s.light += s.sleep - detailed;
    }
    if s.end > s.start && s.deep + s.light + s.rem > 0 {
        out.push((s, cluster));
    }
}

fn scale_stage_total(deep: i64, light: i64, rem: i64, target: i64) -> (i64, i64, i64) {
    let total = deep + light + rem;
    if total <= 0 || target <= 0 || total <= target {
        return (deep, light, rem);
    }
    let values = [deep, light, rem];
    let mut scaled = values.map(|value| value * target / total);
    let missing = target - scaled.iter().sum::<i64>();
    let mut order: Vec<usize> = (0..3).collect();
    order.sort_by_key(|&index| std::cmp::Reverse(values[index] * target % total));
    for index in order.into_iter().take(missing as usize) {
        scaled[index] += 1;
    }
    (scaled[0], scaled[1], scaled[2])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store;

    #[test]
    fn stage_scaling_preserves_authoritative_total() {
        let (deep, light, rem) = scale_stage_total(154, 299, 124, 537);
        assert_eq!(deep + light + rem, 537);
        assert!(deep <= 154 && light <= 299 && rem <= 124);
    }

    #[test]
    fn ingest_workout_upserts_summary_and_samples() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-watch-test-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let events = json!({
            "events": [{
                "t": "workout",
                "number": 7,
                "type": 1,
                "start": 1_760_000_000i64,
                "end": 1_760_003_600i64,
                "duration": 3600,
                "total_time": 3600,
                "distance": 10_000,
                "calories": 600,
                "steps": 9000,
                "load": 120,
                "aerobic": 35,
                "anaerobic": 12,
                "recovery": 48,
                "max_met": 11.2,
                "elevation_gain": 50,
                "elevation_loss": 40,
                "samples": [{"hr": 140}, {"hr": 150}, {"hr": 160}],
                "altitude": [{"alt": 12.0}, {"alt": 13.5}],
                "dynamics": [{"cad": 180, "pwr": 0}],
                "track": [
                    {"t": 1_760_000_000_000i64, "lat": 31.2, "lon": 121.4, "alt": 12.0},
                    {"t": 1_760_000_060_000i64, "lat": 31.201, "lon": 121.401, "alt": 13.0}
                ],
                "splits": [{"distance": 1000, "pace": 330, "type": 1}],
                "segments": [],
                "recovery_hrs": [150, 130, 110]
            }]
        });

        let out = ingest_watch_data(events.to_string()).unwrap();
        assert!(out.contains("\"workouts\":1"), "{out}");

        let detail = store::get_workout("watch-7-1760000000").unwrap().unwrap();
        assert_eq!(detail.summary.sport, "running");
        assert_eq!(detail.summary.distance_m, 10_000.0);
        assert_eq!(detail.summary.avg_hr, 150);
        assert_eq!(detail.summary.max_hr, 160);
        // 手表只给 maxMET(11.2)，VO2max 按 1 MET ≡ 3.5 ml/kg/min 换算得到 39.2。
        assert_eq!(detail.max_met, Some(11.2));
        assert!((detail.vo2max.unwrap() - 39.2).abs() < 1e-6);
        assert!((detail.aerobic_effect - 3.5).abs() < 1e-6);
        assert!(detail.track_json.as_deref().unwrap().contains("\"lat\""));
        assert!(detail
            .samples_json
            .as_deref()
            .unwrap()
            .contains("\"hr\":150"));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn ingest_step_samples_do_not_lower_authoritative_daily_totals() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-watch-steps-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let now_s = now_ms() / 1000;
        let day = local_day(now_ms());
        let read_steps = || -> i64 {
            store::with_conn(|conn| {
                Ok(conn
                    .query_row(
                        "SELECT steps FROM daily_metrics WHERE date_day = ?1",
                        [day],
                        |r| r.get::<_, i64>(0),
                    )
                    .unwrap_or(0))
            })
            .unwrap()
        };

        // 第一轮：手表全量日汇总 9712 步（权威），同时上传只覆盖 8843 步的采样
        ingest_watch_data(
            json!({"events":[
                {"t":"step_sample","ts":now_s,"steps":8843,"calories":0,"distance":0},
                {"t":"fitness_totals","steps":9712,"calories":640,"distance":7200},
            ]})
            .to_string(),
        )
        .unwrap();
        assert_eq!(read_steps(), 9712, "全量日汇总应作为权威步数入库，不被采样 SUM 拉低");

        // 第二轮：只有采样重新聚合（SUM 偏小），不得把权威值拉低
        ingest_watch_data(
            json!({"events":[
                {"t":"step_sample","ts":now_s + 1,"steps":120,"calories":0,"distance":0},
            ]})
            .to_string(),
        )
        .unwrap();
        assert_eq!(read_steps(), 9712, "采样 SUM 不能覆盖更大的权威日汇总");

        // 权威值本身更新时可以上调
        ingest_watch_data(
            json!({"events":[
                {"t":"fitness_totals","steps":11000,"calories":700,"distance":8000},
            ]})
            .to_string(),
        )
        .unwrap();
        assert_eq!(read_steps(), 11000, "更大的权威日汇总应正常覆盖");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn ingest_workout_replaces_legacy_duplicate() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-watch-dedupe-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let legacy_dynamics = json!([
            {"t": 1_760_000_000_000i64, "cad": 120, "spd": 3.1},
            {"t": 1_760_000_005_000i64, "cad": 121, "spd": 3.2},
            {"t": 1_760_000_010_000i64, "cad": 122, "spd": 3.3},
            {"t": 1_760_000_015_000i64, "cad": 123, "spd": 3.4}
        ])
        .to_string();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO workouts(
                    id, source, sport, start_ms, end_ms, vo2max, dynamics_json)
                 VALUES('legacy-1', 'watch', 'running', 1_760_000_000_000,
                        1_760_003_600_000, 48.0, ?1)",
                params![legacy_dynamics],
            )?;
            Ok(())
        })
        .unwrap();

        let events = json!({
            "events": [{
                "t": "workout",
                "number": 7,
                "type": 1,
                "start": 1_760_000_030i64,
                "end": 1_760_003_600i64,
                "duration": 3570,
                "distance": 10_000,
                "calories": 600,
                "samples": [{"hr": 150}],
                "dynamics": [{"cad": 118, "spd": 3.0}]
            }]
        });
        let out = ingest_watch_data(events.to_string()).unwrap();
        assert!(out.contains("\"workouts\":1"), "{out}");

        let list = store::list_workouts("all", 10).unwrap();
        assert_eq!(list.len(), 1, "duplicate legacy row should be replaced");
        assert!(list[0].id.starts_with("watch-"), "kept {}", list[0].id);
        let detail = store::get_workout(&list[0].id).unwrap().unwrap();
        assert_eq!(
            detail.vo2max,
            Some(48.0),
            "legacy running index should survive"
        );
        let dynamics: Vec<Value> =
            serde_json::from_str(detail.dynamics_json.as_deref().unwrap()).unwrap();
        assert_eq!(
            dynamics.len(),
            4,
            "legacy dynamics should not be overwritten"
        );

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn ingest_respiration_updates_metric_and_daily() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-watch-resp-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let ts = 1_760_000_000_000i64;
        let events = json!({
            "events": [{"t": "respiration", "ts": ts, "v": 14.0}]
        });
        ingest_watch_data(events.to_string()).unwrap();

        store::with_conn(|conn| {
            let point: f64 = conn.query_row(
                "SELECT value FROM metric_points WHERE metric = 'respiration'",
                [],
                |r| r.get(0),
            )?;
            assert!((point - 14.0).abs() < 1e-9);
            let daily: f64 = conn.query_row(
                "SELECT respiration FROM daily_metrics WHERE date_day = ?1",
                [local_day(ts)],
                |r| r.get(0),
            )?;
            assert!((daily - 14.0).abs() < 1e-9);
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn ingest_manual_hrv_keeps_measurement_details() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-watch-manual-hrv-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let ts = 1_760_000_000_000i64;
        let events = json!({
            "events": [{
                "t": "hrv",
                "ts": ts,
                "v": 42.5,
                "heart_rate": 61,
                "quality": "fair",
                "source": "manual"
            }]
        });
        let out = ingest_watch_data(events.to_string()).unwrap();
        assert!(out.contains("\"hrv\":1"), "{out}");

        store::with_conn(|conn| {
            let (value, heart_rate, quality, source): (f64, Option<i64>, String, String) = conn
                .query_row(
                    "SELECT hrv_ms, heart_rate, quality, source
                     FROM hrv_records WHERE date_day = ?1 AND at_sec = ?2",
                    params![local_day(ts), ts / 1000],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                )?;
            assert!((value - 42.5).abs() < 1e-9);
            assert_eq!(heart_rate, Some(61));
            assert_eq!(quality, "fair");
            assert_eq!(source, "manual");

            let (point, point_source): (f64, String) = conn.query_row(
                "SELECT value, source FROM metric_points
                 WHERE metric = 'hrv' AND ts_ms = ?1",
                [ts],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            assert!((point - 42.5).abs() < 1e-9);
            assert_eq!(point_source, "manual");

            let daily: f64 = conn.query_row(
                "SELECT hrv_ms FROM daily_metrics WHERE date_day = ?1",
                [local_day(ts)],
                |r| r.get(0),
            )?;
            assert!((daily - 42.5).abs() < 1e-9);
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn ingest_p2p_apnea_hourly_and_rings() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-watch-p2p-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let day_ms = local_day(1_760_000_000_000i64);
        let events = json!({
            "events": [
                {"t": "apnea", "ts": 1_760_000_000_000i64, "level": 2},
                {"t": "active_hour", "ts": 1_760_003_600_000i64, "v": 1},
                {"t": "daily_ring", "end": 1_760_086_399_000i64,
                 "step_goal": 10000, "step_user": 8123, "step_state": 0,
                 "calorie_goal_milli": 500000, "calorie_user_milli": 420000, "calorie_state": 0,
                 "duration_goal_min": 60, "duration_user_min": 42, "duration_state": 0,
                 "active_goal_hours": 12, "active_user_hours": 9, "active_state": 0}
            ]
        });
        ingest_watch_data(events.to_string()).unwrap();

        let apnea = store::apnea_for_day(day_ms).unwrap();
        assert_eq!(apnea.len(), 1);
        assert_eq!(apnea[0].level, 2);

        let hourly = store::hourly_status(day_ms).unwrap();
        assert_eq!(hourly.len(), 1);

        let ring = store::daily_ring(local_day(1_760_086_399_000i64))
            .unwrap()
            .expect("daily ring");
        assert_eq!(ring.step_user, 8123);
        assert_eq!(ring.calorie_user_milli, 420000);
        assert_eq!(ring.active_user_hours, 9);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn equal_sleep_total_backfills_stage_minutes() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-watch-sleep-stages-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let start = 1_760_000_000i64;
        let day = local_day((start + 7 * 3_600) * 1000);
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO daily_metrics(date_day, sleep_minutes, deep_sleep_minutes, rem_sleep_minutes)
                 VALUES(?1, 420, 0, 0)",
                [day],
            )?;
            Ok(())
        })
        .unwrap();

        let events = json!({
            "events": [
                {"t": "sleep_segment", "start": start, "end": start + 14_400, "stage": "light"},
                {"t": "sleep_segment", "start": start + 14_400, "end": start + 21_600, "stage": "deep"},
                {"t": "sleep_segment", "start": start + 21_600, "end": start + 25_200, "stage": "rem"}
            ]
        });
        ingest_watch_data(events.to_string()).unwrap();

        store::with_conn(|conn| {
            let (total, deep, rem): (f64, f64, f64) = conn.query_row(
                "SELECT sleep_minutes, deep_sleep_minutes, rem_sleep_minutes
                 FROM daily_metrics WHERE date_day = ?1",
                [day],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?;
            assert_eq!(total, 420.0);
            assert_eq!(deep, 120.0);
            assert_eq!(rem, 60.0);
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn rebuild_sleep_sessions_drops_sparse_daytime_fragments() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-watch-sleep-density-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let night = 1_760_000_000i64;
        let day = night + 8 * 3_600;
        let events = json!({
            "events": [
                {"t": "sleep_segment", "start": night, "end": night + 3_600, "stage": "light"},
                {"t": "sleep_segment", "start": night + 3_600, "end": night + 7_200, "stage": "deep"},
                {"t": "sleep_segment", "start": night + 7_200, "end": night + 10_800, "stage": "light"},
                {"t": "sleep_segment", "start": night + 10_800, "end": night + 14_400, "stage": "rem"},
                {"t": "sleep_segment", "start": night + 14_400, "end": night + 18_000, "stage": "light"},
                {"t": "sleep_segment", "start": night + 18_000, "end": night + 21_600, "stage": "deep"},
                {"t": "sleep_segment", "start": night + 21_600, "end": night + 25_200, "stage": "light"},
                // 白天约 7 小时里只有 90 分钟零星分期，且间隔都小于 45 分钟，
                // 会被串成一条低密度长片段（22%），不应被当成一次睡眠。
                {"t": "sleep_segment", "start": day, "end": day + 600, "stage": "light"},
                {"t": "sleep_segment", "start": day + 3_000, "end": day + 3_600, "stage": "light"},
                {"t": "sleep_segment", "start": day + 6_000, "end": day + 6_600, "stage": "deep"},
                {"t": "sleep_segment", "start": day + 9_000, "end": day + 9_600, "stage": "light"},
                {"t": "sleep_segment", "start": day + 12_000, "end": day + 12_600, "stage": "rem"},
                {"t": "sleep_segment", "start": day + 15_000, "end": day + 15_600, "stage": "light"},
                {"t": "sleep_segment", "start": day + 18_000, "end": day + 18_600, "stage": "light"},
                {"t": "sleep_segment", "start": day + 21_000, "end": day + 21_600, "stage": "light"},
                {"t": "sleep_segment", "start": day + 24_000, "end": day + 24_600, "stage": "light"}
            ]
        });
        ingest_watch_data(events.to_string()).unwrap();

        store::with_conn(|conn| {
            let count: i64 =
                conn.query_row("SELECT COUNT(*) FROM sleep_sessions", [], |r| r.get(0))?;
            let start: i64 =
                conn.query_row("SELECT start_ms FROM sleep_sessions", [], |r| r.get(0))?;
            assert_eq!(count, 1);
            assert_eq!(start, night * 1000);
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn rebuild_sleep_sessions_keeps_nap_and_aggregates_daily_total() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-watch-sleep-nap-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let day_start = Local
            .with_ymd_and_hms(2026, 11, 7, 0, 0, 0)
            .single()
            .unwrap()
            .timestamp();
        let night = day_start - 3_600;
        let nap = day_start + 13 * 3_600;
        let events = json!({
            "events": [
                {"t": "sleep_segment", "start": night, "end": day_start + 6 * 3_600, "stage": "light"},
                {"t": "sleep_segment", "start": nap, "end": nap + 17 * 60, "stage": "light"}
            ]
        });
        ingest_watch_data(events.to_string()).unwrap();

        let day = local_day(nap * 1000);
        store::with_conn(|conn| {
            let count: i64 = conn.query_row(
                "SELECT COUNT(*) FROM sleep_sessions WHERE end_ms >= ?1 AND end_ms < ?2",
                params![day_start * 1000, (day_start + 86_400) * 1000],
                |r| r.get(0),
            )?;
            let total: f64 = conn.query_row(
                "SELECT sleep_minutes FROM daily_metrics WHERE date_day = ?1",
                [day],
                |r| r.get(0),
            )?;
            assert_eq!(count, 2, "夜间睡眠和午睡应各保留一场");
            assert!((total - 437.0).abs() < 1.0, "daily total {total}");
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn rebuild_sleep_sessions_keeps_summary_only_history() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-watch-sleep-summary-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        // 2023-11-14 22:00 左右的一次历史主睡眠，只剩摘要，没有分期。
        let old_start = 1_700_000_000_000i64;
        let stage_start = 1_760_000_000_000i64;
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1, ?2, 90, 300, 60, 20, 'watch')",
                params![old_start, old_start + 470 * 60_000],
            )?;
            conn.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1, ?2, 30, 180, 30, 5, 'legacy')",
                params![old_start - 86_400_000, old_start - 86_400_000 + 250 * 60_000],
            )?;
            // 有分期覆盖、但起始时间已被新手表数据修正的旧会话，应该被替换。
            conn.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1, ?2, 10, 60, 0, 0, 'watch')",
                params![stage_start - 10 * 60_000, stage_start + 50 * 60_000],
            )?;
            conn.execute(
                "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                 VALUES(?1, ?2, 'light', 'watch')",
                params![stage_start, stage_start + 60 * 60_000],
            )?;
            Ok(())
        })
        .unwrap();

        store::with_conn(|conn| rebuild_sleep_sessions(conn)).unwrap();

        store::with_conn(|conn| {
            let summary_only: i64 = conn.query_row(
                "SELECT COUNT(*) FROM sleep_sessions WHERE start_ms = ?1 AND source = 'watch'",
                [old_start],
                |r| r.get(0),
            )?;
            let legacy: i64 = conn.query_row(
                "SELECT COUNT(*) FROM sleep_sessions WHERE source = 'legacy'",
                [],
                |r| r.get(0),
            )?;
            let stale: i64 = conn.query_row(
                "SELECT COUNT(*) FROM sleep_sessions WHERE start_ms = ?1 AND source = 'watch'",
                [stage_start - 10 * 60_000],
                |r| r.get(0),
            )?;
            let rebuilt: i64 = conn.query_row(
                "SELECT COUNT(*) FROM sleep_sessions WHERE start_ms = ?1 AND source = 'watch'",
                [stage_start],
                |r| r.get(0),
            )?;
            assert_eq!(summary_only, 1, "无分期的历史睡眠摘要不能丢");
            assert_eq!(legacy, 1, "旧版导入的会话不归手表重建管");
            assert_eq!(stale, 0, "有分期的旧会话应被新数据替换");
            assert_eq!(rebuilt, 1);
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn rebuild_sleep_sessions_keeps_sleep_window_nap_inside_daytime_noise() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-watch-sleep-anchor-nap-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let day = Local
            .with_ymd_and_hms(2026, 11, 7, 0, 0, 0)
            .single()
            .unwrap();
        let day_start = day.timestamp();
        let epoch_day =
            (day.date_naive() - chrono::NaiveDate::from_ymd_opt(1970, 1, 1).unwrap()).num_days();
        let night = day_start - 30 * 60;
        let nap = day_start + 13 * 3_600 + 24 * 60;
        let noon_noise = day_start + 11 * 3_600 + 48 * 60;
        let afternoon_noise = day_start + 14 * 3_600 + 3 * 60;
        let rest_47 = day_start + 16 * 3_600 + 39 * 60;
        let rest_28 = day_start + 19 * 3_600 + 21 * 60;

        store::with_conn(|conn| {
            // 夜间和午睡都只有整段 sleep 窗口，没有分钟级分期。
            for (a, b) in [(night, night + 314 * 60), (nap, nap + 38 * 60)] {
                conn.execute(
                    "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                     VALUES(?1, ?2, 'sleep', 'watch')",
                    params![a * 1000, b * 1000],
                )?;
            }
            // 午睡前后各有一长串零星 light 打点，原来会把午睡裹进低密度长片段。
            for base in [noon_noise, afternoon_noise] {
                for i in 0..10 {
                    let a = base + i * 8 * 60;
                    conn.execute(
                        "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                         VALUES(?1, ?2, 'light', 'watch')",
                        params![a * 1000, (a + 60) * 1000],
                    )?;
                }
            }
            // 下午两次静止误判：47 分钟 88bpm、28 分钟 76bpm。
            conn.execute(
                "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                 VALUES(?1, ?2, 'light', 'watch')",
                params![rest_47 * 1000, (rest_47 + 47 * 60) * 1000],
            )?;
            conn.execute(
                "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                 VALUES(?1, ?2, 'light', 'watch')",
                params![rest_28 * 1000, (rest_28 + 28 * 60) * 1000],
            )?;
            for i in 0..16 {
                conn.execute(
                    "INSERT OR REPLACE INTO heart_rate_points(ts_ms, bpm, synced)
                     VALUES(?1, ?2, 0)",
                    params![(rest_47 + i * 3 * 60) * 1000, 88],
                )?;
            }
            for i in 0..8 {
                conn.execute(
                    "INSERT OR REPLACE INTO heart_rate_points(ts_ms, bpm, synced)
                     VALUES(?1, ?2, 0)",
                    params![(rest_28 + i * 4 * 60) * 1000, 76],
                )?;
            }
            for i in 0..13 {
                conn.execute(
                    "INSERT OR REPLACE INTO heart_rate_points(ts_ms, bpm, synced)
                     VALUES(?1, ?2, 0)",
                    params![(nap + i * 3 * 60) * 1000, 66],
                )?;
            }
            conn.execute(
                "INSERT INTO daily_metrics(date_day, resting_hr, updated_ms)
                 VALUES(?1, 54, 0)",
                [epoch_day],
            )?;

            rebuild_sleep_sessions(conn)?;

            let sessions: Vec<(i64, f64)> = {
                let mut stmt = conn.prepare(
                    "SELECT start_ms, deep_min + light_min + rem_min
                     FROM sleep_sessions ORDER BY start_ms",
                )?;
                let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
                rows.collect::<rusqlite::Result<Vec<_>>>()?
            };
            // sleep_sessions 保留原始会话；47/28 分钟的误判由心率过滤
            // 在汇总时排除，不能影响日报表。
            assert_eq!(sessions.len(), 4, "原始会话: {sessions:?}");
            assert!((sessions[0].1 - 314.0).abs() < 1.0);
            assert_eq!(sessions[1].0, nap * 1000);
            assert!((sessions[1].1 - 38.0).abs() < 1.0);
            let total: f64 = conn.query_row(
                "SELECT sleep_minutes FROM daily_metrics WHERE date_day = ?1",
                [epoch_day],
                |r| r.get(0),
            )?;
            assert!((total - 352.0).abs() < 1.0, "daily total {total}");
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn rebuild_sleep_sessions_recovers_unanchored_dense_nap() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-watch-sleep-regular-nap-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let day_start = Local
            .with_ymd_and_hms(2026, 11, 7, 0, 0, 0)
            .single()
            .unwrap()
            .timestamp();
        let nap = day_start + 13 * 3_600 + 24 * 60;
        store::with_conn(|conn| {
            // 白天静止打点每 30 分钟一个，45 分钟聚类会把午睡并进全天片段；
            // 20 分钟聚类应把 38 分钟午睡单独捞出来。
            for base in [day_start + 8 * 3_600, day_start + 14 * 3_600 + 30 * 60] {
                for i in 0..10 {
                    let start = base + i * 30 * 60;
                    conn.execute(
                        "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                         VALUES(?1, ?2, 'light', 'watch')",
                        params![start * 1000, (start + 60) * 1000],
                    )?;
                }
            }
            conn.execute(
                "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                 VALUES(?1, ?2, 'light', 'watch')",
                params![nap * 1000, (nap + 38 * 60) * 1000],
            )?;
            Ok(())
        })
        .unwrap();

        store::with_conn(|conn| {
            rebuild_sleep_sessions(conn)?;
            let sessions: Vec<(i64, f64)> = {
                let mut stmt = conn.prepare(
                    "SELECT start_ms, deep_min + light_min + rem_min
                     FROM sleep_sessions ORDER BY start_ms",
                )?;
                let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
                rows.collect::<rusqlite::Result<Vec<_>>>()?
            };
            assert!(
                sessions
                    .iter()
                    .any(|(start, minutes)| *start == nap * 1000 && (*minutes - 38.0).abs() < 1.0),
                "38 分钟无锚点午睡丢失: {sessions:?}"
            );
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn rebuild_sleep_sessions_recovers_nap_from_fragmented_daytime_noise() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-watch-sleep-fragmented-nap-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let day = Local
            .with_ymd_and_hms(2026, 11, 7, 0, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let at = |hour: i64, minute: i64| day + (hour * 60 + minute) * 60_000;
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                 VALUES(?1, ?2, 'light', 'watch')",
                params![at(0, 0), at(6, 0)],
            )?;
            for (start, end) in [
                (at(13, 0), at(13, 12)),
                (at(13, 18), at(13, 30)),
                (at(13, 36), at(13, 48)),
            ] {
                conn.execute(
                    "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                     VALUES(?1, ?2, 'light', 'watch')",
                    params![start, end],
                )?;
            }
            for (hour, minute) in [(12, 20), (12, 40), (14, 0), (14, 20)] {
                conn.execute(
                    "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                     VALUES(?1, ?2, 'light', 'watch')",
                    params![at(hour, minute), at(hour, minute) + 60_000],
                )?;
            }
            Ok(())
        })
        .unwrap();

        store::with_conn(|conn| {
            rebuild_sleep_sessions(conn)?;
            let sessions: Vec<(i64, f64)> = {
                let mut stmt = conn.prepare(
                    "SELECT start_ms, deep_min + light_min + rem_min
                     FROM sleep_sessions ORDER BY start_ms",
                )?;
                let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
                rows.collect::<rusqlite::Result<Vec<_>>>()?
            };
            assert!(
                sessions
                    .iter()
                    .any(|(start, minutes)| *start == at(13, 0)
                        && (*minutes - 36.0).abs() < 1.0),
                "碎片化午睡没有从白天噪声里恢复: {sessions:?}"
            );
            assert!(
                sessions
                    .iter()
                    .filter(|(start, _)| *start >= at(11, 0))
                    .all(|(_, minutes)| *minutes < 120.0),
                "白天低密度片段不应吞掉午睡: {sessions:?}"
            );
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn rebuild_sleep_sessions_keeps_nap_before_sleep_anchor() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-watch-sleep-nap-before-anchor-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let day = Local
            .with_ymd_and_hms(2026, 10, 27, 0, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let at = |hour: i64, minute: i64| day + (hour * 60 + minute) * 60_000;
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                 VALUES(?1, ?2, 'light', 'watch')",
                params![at(12, 38), at(13, 38)],
            )?;
            // 锚点和午睡之间只隔 8 分钟，不能被 10 分钟聚类并进同一簇。
            conn.execute(
                "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
                 VALUES(?1, ?2, 'sleep', 'watch')",
                params![at(13, 46), at(13, 59)],
            )?;
            Ok(())
        })
        .unwrap();

        store::with_conn(|conn| {
            rebuild_sleep_sessions(conn)?;
            let sessions: Vec<(i64, f64)> = {
                let mut stmt = conn.prepare(
                    "SELECT start_ms, deep_min + light_min + rem_min
                     FROM sleep_sessions ORDER BY start_ms",
                )?;
                let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
                rows.collect::<rusqlite::Result<Vec<_>>>()?
            };
            assert!(
                sessions
                    .iter()
                    .any(|(start, minutes)| *start == at(12, 38)
                        && (*minutes - 60.0).abs() < 1.0),
                "锚点前的午睡被吞掉了: {sessions:?}"
            );
            assert!(
                sessions
                    .iter()
                    .any(|(start, minutes)| *start == at(13, 46)
                        && (*minutes - 13.0).abs() < 1.0),
                "锚点本身仍应保留: {sessions:?}"
            );
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn ingest_sleep_bed_merges_missing_window_fields() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-watch-sleep-bed-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let start = 1_760_000_000_000i64;
        let events = json!({
            "events": [
                {"t": "sleep_bed", "session_start": start, "bed": start, "fall_asleep": start + 60_000},
                {"t": "sleep_bed", "session_start": start, "wake": start + 8 * 3_600_000}
            ]
        });
        ingest_watch_data(events.to_string()).unwrap();

        store::with_conn(|conn| {
            let (bed, fall_asleep, wake): (Option<i64>, Option<i64>, Option<i64>) = conn
                .query_row(
                "SELECT bed_ms, fall_asleep_ms, wake_ms FROM sleep_bed WHERE session_start_ms = ?1",
                [start],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?;
            assert_eq!(bed, Some(start));
            assert_eq!(fall_asleep, Some(start + 60_000));
            assert_eq!(wake, Some(start + 8 * 3_600_000));
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn ingest_scale_weight_merges_composition_into_one_record() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-watch-scale-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let ts = 1_760_000_000_000i64;
        // 先到体重包，几秒后到阻抗包，应合并成同一条记录。
        ingest_watch_data(
            json!({"events": [{
                "t": "weight", "ts": ts, "kg": 70.2, "source": "scale", "device": "AFU-WL-TZ-A1"
            }]})
            .to_string(),
        )
        .unwrap();
        ingest_watch_data(
            json!({"events": [{
                "t": "weight", "ts": ts + 3_000, "kg": 70.2,
                "body_fat": 21.5, "muscle": 42.3, "water": 55.1,
                "height_cm": 175.0, "source": "scale", "device": "AFU-WL-TZ-A1"
            }]})
            .to_string(),
        )
        .unwrap();

        let weights = store::weights(10).unwrap();
        assert_eq!(weights.len(), 1, "体重包与阻抗包应合并");
        assert_eq!(weights[0].body_fat_percent, Some(21.5));
        assert_eq!(weights[0].muscle_percent, Some(42.3));
        assert_eq!(weights[0].source, "scale");
        assert_eq!(weights[0].device_name.as_deref(), Some("AFU-WL-TZ-A1"));
        let bmi = weights[0].bmi.expect("bmi");
        assert!((bmi - 70.2 / (1.75 * 1.75)).abs() < 1e-6);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn ingest_sleep_hrv_keeps_baseline_fields_and_updates_daily() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-watch-sleep-hrv-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();

        let start = 1_760_000_000_000i64;
        let wake = start + 8 * 3_600_000;
        ingest_watch_data(
            json!({"events": [{
                "t": "sleep_hrv",
                "ts": wake,
                "start": start,
                "avg": 54,
                "min": 45,
                "max": 68,
                "delta": 6
            }]})
            .to_string(),
        )
        .unwrap();

        store::with_conn(|conn| {
            let row: (i64, f64, f64, f64, f64) = conn.query_row(
                "SELECT sleep_start_ms, avg_hrv, min_baseline, max_baseline, day_to_baseline
                 FROM sleep_hrv_records",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )?;
            assert_eq!(row, (start, 54.0, 45.0, 68.0, 6.0));
            let daily: f64 = conn.query_row(
                "SELECT hrv_ms FROM daily_metrics WHERE date_day = ?1",
                params![local_day(wake)],
                |r| r.get(0),
            )?;
            assert_eq!(daily, 54.0);
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }
}
