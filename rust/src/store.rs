use anyhow::{anyhow, Context, Result};
use chrono::{Datelike, Duration, Local, NaiveDate, TimeZone};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};

use crate::api::types::*;
use crate::readiness;

static DB: OnceLock<Mutex<Option<Connection>>> = OnceLock::new();

pub const DB_VERSION: i64 = 12;

fn cell() -> &'static Mutex<Option<Connection>> {
    DB.get_or_init(|| Mutex::new(None))
}

pub fn open(path: &str) -> Result<()> {
    let conn = Connection::open(path).with_context(|| format!("open sqlite at {path}"))?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    init_schema(&conn)?;
    *cell().lock().unwrap() = Some(conn);
    Ok(())
}

pub fn with_conn<T>(f: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
    let guard = cell().lock().map_err(|_| anyhow!("store lock poisoned"))?;
    let conn = guard.as_ref().context("store not initialized")?;
    f(conn)
}

pub fn is_open() -> bool {
    cell().lock().map(|g| g.is_some()).unwrap_or(false)
}

fn json_array(raw: &str) -> Option<Vec<serde_json::Value>> {
    let value: serde_json::Value = serde_json::from_str(raw).ok()?;
    let items = value.as_array()?;
    (!items.is_empty()).then(|| items.clone())
}

fn json_point_time(point: &serde_json::Value, time_key: &str) -> Option<i64> {
    point.get(time_key).and_then(|value| value.as_i64())
}

/// 合并两条同源运动明细。两边都有时间戳时按时间取并集；一边缺时间戳
/// （例如手表只回了 3 个汇总点）时保留点数更多的一份，避免旧库几百个
/// GPS/动态采样点被新的汇总包覆盖。
pub(crate) fn merge_json_point_series(
    existing: Option<&str>,
    incoming: Option<&str>,
    time_key: &str,
) -> Option<String> {
    let existing = existing.and_then(json_array);
    let incoming = incoming.and_then(json_array);
    let (existing, incoming) = match (existing, incoming) {
        (Some(existing), Some(incoming)) => (existing, incoming),
        (Some(existing), None) => return serde_json::to_string(&existing).ok(),
        (None, Some(incoming)) => return serde_json::to_string(&incoming).ok(),
        (None, None) => return None,
    };

    let existing_timed = existing
        .iter()
        .all(|point| json_point_time(point, time_key).is_some());
    let incoming_timed = incoming
        .iter()
        .all(|point| json_point_time(point, time_key).is_some());
    if !existing_timed || !incoming_timed {
        let keep_incoming = incoming.len() > existing.len();
        return serde_json::to_string(if keep_incoming { &incoming } else { &existing }).ok();
    }

    let mut merged = existing;
    let mut seen: HashSet<i64> = merged
        .iter()
        .filter_map(|point| json_point_time(point, time_key))
        .collect();
    for point in incoming {
        if let Some(time) = json_point_time(&point, time_key) {
            if seen.insert(time) {
                merged.push(point);
            }
        }
    }
    merged.sort_by_key(|point| json_point_time(point, time_key).unwrap_or(i64::MAX));
    serde_json::to_string(&merged).ok()
}

fn json_weight(raw: &str) -> usize {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(raw) else {
        return 0;
    };
    value
        .as_array()
        .map(Vec::len)
        .or_else(|| value.as_object().map(serde_json::Map::len))
        .unwrap_or(0)
}

/// 没有时间戳的 JSON（恢复心率、分段详情）保留信息更多的一份。
pub(crate) fn richer_json(existing: Option<&str>, incoming: Option<&str>) -> Option<String> {
    match (existing, incoming) {
        (Some(existing), Some(incoming)) => Some(
            if json_weight(incoming) >= json_weight(existing) {
                incoming
            } else {
                existing
            }
            .to_string(),
        ),
        (Some(existing), None) => Some(existing.to_string()),
        (None, Some(incoming)) => Some(incoming.to_string()),
        (None, None) => None,
    }
}

fn init_schema(conn: &Connection) -> Result<()> {
    let previous_version: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
    conn.execute_batch(
        r#"
CREATE TABLE IF NOT EXISTS daily_metrics(
  date_day INTEGER PRIMARY KEY,
  steps INTEGER NOT NULL DEFAULT 0,
  calories INTEGER NOT NULL DEFAULT 0,
  active_calories INTEGER NOT NULL DEFAULT 0,
  distance_m INTEGER NOT NULL DEFAULT 0,
  active_minutes INTEGER NOT NULL DEFAULT 0,
  resting_hr REAL,
  sleep_minutes REAL,
  deep_sleep_minutes REAL,
  rem_sleep_minutes REAL,
  awake_minutes REAL,
  hrv_ms REAL,
  stress REAL,
  spo2 REAL,
  skin_temp_c REAL,
  updated_ms INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS hrv_records(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  date_day INTEGER NOT NULL,
  at_sec INTEGER NOT NULL,
  hrv_ms REAL NOT NULL,
  heart_rate INTEGER,
  stress INTEGER,
  quality TEXT NOT NULL DEFAULT 'good',
  source TEXT NOT NULL DEFAULT 'device'
);

-- 手表睡眠详情（700013）里的官方夜间 HRV，一晚一条。
CREATE TABLE IF NOT EXISTS sleep_hrv_records(
  date_day INTEGER PRIMARY KEY,
  sleep_start_ms INTEGER NOT NULL DEFAULT 0,
  avg_hrv REAL NOT NULL DEFAULT 0,
  min_baseline REAL NOT NULL DEFAULT -1,
  max_baseline REAL NOT NULL DEFAULT -1,
  day_to_baseline REAL NOT NULL DEFAULT -1,
  updated_ms INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS sleep_sessions(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  deep_min REAL NOT NULL DEFAULT 0,
  light_min REAL NOT NULL DEFAULT 0,
  rem_min REAL NOT NULL DEFAULT 0,
  awake_min REAL NOT NULL DEFAULT 0,
  anchor_min INTEGER,
  source TEXT NOT NULL DEFAULT 'watch'
);

CREATE TABLE IF NOT EXISTS heart_rate_points(
  ts_ms INTEGER PRIMARY KEY,
  bpm INTEGER NOT NULL,
  synced INTEGER NOT NULL DEFAULT 0
);

-- 手表按秒上报的步数样本：每日汇总和「活跃小时数」都从这里重算。
-- 必须在主 schema 建好，否则首次启动（还没有手表同步）查首页会 no such table。
CREATE TABLE IF NOT EXISTS step_samples(
  ts INTEGER PRIMARY KEY,
  steps INTEGER NOT NULL DEFAULT 0,
  calories INTEGER NOT NULL DEFAULT 0,
  distance INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS weight_records(
  id TEXT PRIMARY KEY,
  timestamp_ms INTEGER NOT NULL,
  weight_kg REAL NOT NULL,
  body_fat_percent REAL,
  muscle_percent REAL,
  water_percent REAL,
  protein_percent REAL,
  protein_mass_kg REAL,
  bone_percent REAL,
  bone_mass_kg REAL,
  skeletal_muscle_percent REAL,
  skeletal_muscle_mass_kg REAL,
  subcutaneous_fat_percent REAL,
  subcutaneous_fat_mass_kg REAL,
  resistance_ohm REAL,
  body_composition_model TEXT,
  source TEXT NOT NULL DEFAULT 'scale'
);

CREATE TABLE IF NOT EXISTS workouts(
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL DEFAULT 'watch',
  sport TEXT NOT NULL,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  distance_m REAL NOT NULL DEFAULT 0,
  calories INTEGER NOT NULL DEFAULT 0,
  avg_hr INTEGER NOT NULL DEFAULT 0,
  max_hr INTEGER NOT NULL DEFAULT 0,
  steps INTEGER NOT NULL DEFAULT 0,
  load INTEGER NOT NULL DEFAULT 0,
  aerobic_effect REAL NOT NULL DEFAULT 0,
  recovery_time_min INTEGER NOT NULL DEFAULT 0,
  track_json TEXT,
  samples_json TEXT,
  dynamics_json TEXT,
  altitude_json TEXT,
  recovery_json TEXT,
  start_temp_c REAL,
  start_humidity INTEGER,
  synced INTEGER NOT NULL DEFAULT 0,
  created_ms INTEGER NOT NULL DEFAULT 0
);

-- 用户删掉的运动不能被手表全量同步、旧版数据库重导或云端合并重新写回来。
-- 同类型、开始时间相差 2 分钟内视为同一场，与手表入库的去重规则一致。
CREATE TABLE IF NOT EXISTS workout_tombstones(
  id TEXT PRIMARY KEY,
  sport TEXT NOT NULL,
  start_ms INTEGER NOT NULL,
  workout_number INTEGER,
  deleted_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_workout_tombstones_identity
  ON workout_tombstones(sport, start_ms);

CREATE TRIGGER IF NOT EXISTS workout_tombstone_block_insert
BEFORE INSERT ON workouts
WHEN EXISTS (
  SELECT 1 FROM workout_tombstones
  WHERE sport = NEW.sport AND ABS(start_ms - NEW.start_ms) <= 120000
)
BEGIN
  SELECT RAISE(IGNORE);
END;

CREATE TRIGGER IF NOT EXISTS workout_tombstone_block_update
BEFORE UPDATE ON workouts
WHEN EXISTS (
  SELECT 1 FROM workout_tombstones
  WHERE sport = NEW.sport AND ABS(start_ms - NEW.start_ms) <= 120000
)
BEGIN
  SELECT RAISE(IGNORE);
END;

-- 手动健康记录（体重/血压/血糖）删掉后，旧版数据库重导不能把它们写回来。
CREATE TABLE IF NOT EXISTS health_record_tombstones(
  kind TEXT NOT NULL,
  id TEXT NOT NULL,
  deleted_ms INTEGER NOT NULL,
  PRIMARY KEY(kind, id)
);

CREATE TABLE IF NOT EXISTS profile(
  id INTEGER PRIMARY KEY CHECK(id = 1),
  nickname TEXT NOT NULL DEFAULT '',
  gender TEXT NOT NULL DEFAULT 'male',
  height_cm REAL NOT NULL DEFAULT 170,
  weight_kg REAL NOT NULL DEFAULT 65,
  birth_date TEXT NOT NULL DEFAULT '1990-01-01',
  email TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS settings(
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS devices(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  address TEXT NOT NULL DEFAULT '',
  battery INTEGER NOT NULL DEFAULT 0,
  last_sync_ms INTEGER,
  connected INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS watch_logs(
  ts_ms INTEGER NOT NULL,
  msg TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_watch_logs_ts ON watch_logs(ts_ms DESC);

CREATE INDEX IF NOT EXISTS idx_hrv_day ON hrv_records(date_day);
CREATE INDEX IF NOT EXISTS idx_workout_start ON workouts(start_ms DESC);
CREATE INDEX IF NOT EXISTS idx_sleep_start ON sleep_sessions(start_ms DESC);

CREATE TABLE IF NOT EXISTS metric_points(
  metric TEXT NOT NULL,
  ts_ms INTEGER NOT NULL,
  value REAL NOT NULL,
  source TEXT NOT NULL DEFAULT 'watch',
  PRIMARY KEY(metric, ts_ms)
);
CREATE INDEX IF NOT EXISTS idx_metric_points ON metric_points(metric, ts_ms DESC);

CREATE TABLE IF NOT EXISTS blood_pressure_records(
  id TEXT PRIMARY KEY,
  timestamp_ms INTEGER NOT NULL,
  systolic INTEGER NOT NULL,
  diastolic INTEGER NOT NULL,
  pulse INTEGER,
  source TEXT NOT NULL DEFAULT 'manual'
);

CREATE TABLE IF NOT EXISTS blood_glucose_records(
  id TEXT PRIMARY KEY,
  timestamp_ms INTEGER NOT NULL,
  value REAL NOT NULL,
  measure_type TEXT NOT NULL DEFAULT 'random',
  source TEXT NOT NULL DEFAULT 'manual'
);

CREATE TABLE IF NOT EXISTS arrhythmia_records(
  ts_ms INTEGER PRIMARY KEY,
  result_type INTEGER NOT NULL,
  measure_type INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'watch'
);

CREATE TABLE IF NOT EXISTS sleep_stages(
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  stage TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'watch',
  PRIMARY KEY(start_ms, stage)
);

CREATE TABLE IF NOT EXISTS sleep_bed(
  session_start_ms INTEGER PRIMARY KEY,
  bed_ms INTEGER,
  fall_asleep_ms INTEGER,
  wake_ms INTEGER,
  duration_min INTEGER,
  watch_score INTEGER,
  watch_efficiency INTEGER,
  watch_wake_count INTEGER
);

CREATE TABLE IF NOT EXISTS emotion_records(
  ts_ms INTEGER PRIMARY KEY,
  status INTEGER NOT NULL,
  valence REAL,
  arousal REAL
);

CREATE TABLE IF NOT EXISTS equipment(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  sport TEXT NOT NULL DEFAULT 'other',
  gear_type TEXT NOT NULL DEFAULT 'shoes',
  brand TEXT NOT NULL DEFAULT '',
  model TEXT NOT NULL DEFAULT '',
  purchase_ms INTEGER NOT NULL DEFAULT 0,
  is_active INTEGER NOT NULL DEFAULT 1,
  start_km REAL NOT NULL DEFAULT 0,
  limit_km REAL NOT NULL DEFAULT 800,
  note TEXT NOT NULL DEFAULT '',
  created_ms INTEGER NOT NULL DEFAULT 0
);

-- 力量训练：动作库、模板、模板动作、实际组记录（沿用旧版 com.awen.running 的结构）。
CREATE TABLE IF NOT EXISTS strength_exercises(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  muscle_group TEXT NOT NULL DEFAULT '',
  equipment TEXT NOT NULL DEFAULT '',
  is_custom INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS strength_templates(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  notes TEXT NOT NULL DEFAULT '',
  created_ms INTEGER NOT NULL DEFAULT 0,
  updated_ms INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS strength_template_exercises(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  template_id INTEGER NOT NULL,
  exercise_id INTEGER NOT NULL,
  order_index INTEGER NOT NULL DEFAULT 0,
  target_sets INTEGER NOT NULL DEFAULT 3,
  target_reps INTEGER NOT NULL DEFAULT 12,
  rest_seconds INTEGER NOT NULL DEFAULT 60,
  target_weight_kg REAL,
  notes TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_strength_template_exercises
  ON strength_template_exercises(template_id, order_index);

CREATE TABLE IF NOT EXISTS strength_workout_sets(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  exercise_id INTEGER NOT NULL DEFAULT 0,
  exercise_name TEXT NOT NULL DEFAULT '',
  set_number INTEGER NOT NULL DEFAULT 1,
  weight_kg REAL NOT NULL DEFAULT 0,
  reps INTEGER NOT NULL DEFAULT 0,
  rest_seconds_actual INTEGER NOT NULL DEFAULT 0,
  completed_at_ms INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_strength_sets_session
  ON strength_workout_sets(session_id, id);

-- P2P 字典：睡眠呼吸暂停（500002）、每小时状态（200005）、官方每日三环（300002）。
CREATE TABLE IF NOT EXISTS apnea_records(
  ts_ms INTEGER PRIMARY KEY,
  level INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'watch'
);

CREATE TABLE IF NOT EXISTS hourly_status(
  ts_ms INTEGER PRIMARY KEY,
  value INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS daily_rings(
  date_day INTEGER PRIMARY KEY,
  day_end_ms INTEGER NOT NULL DEFAULT 0,
  step_goal INTEGER NOT NULL DEFAULT 0,
  step_user INTEGER NOT NULL DEFAULT 0,
  step_state INTEGER NOT NULL DEFAULT 0,
  calorie_goal_milli INTEGER NOT NULL DEFAULT 0,
  calorie_user_milli INTEGER NOT NULL DEFAULT 0,
  calorie_state INTEGER NOT NULL DEFAULT 0,
  duration_goal_min INTEGER NOT NULL DEFAULT 0,
  duration_user_min INTEGER NOT NULL DEFAULT 0,
  duration_state INTEGER NOT NULL DEFAULT 0,
  active_goal_hours INTEGER NOT NULL DEFAULT 0,
  active_user_hours INTEGER NOT NULL DEFAULT 0,
  active_state INTEGER NOT NULL DEFAULT 0,
  updated_ms INTEGER NOT NULL DEFAULT 0
);

-- 本机保存的规划路线（点选途经点生成，不依赖在线路径服务）。
CREATE TABLE IF NOT EXISTS saved_routes(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  points_json TEXT NOT NULL DEFAULT '[]',
  distance_m REAL NOT NULL DEFAULT 0,
  created_ms INTEGER NOT NULL DEFAULT 0
);

-- 用户删掉的路线不能被旧版 JSON 重导或云端快照写回来。
CREATE TABLE IF NOT EXISTS saved_route_tombstones(
  id TEXT PRIMARY KEY,
  deleted_ms INTEGER NOT NULL
);

-- 旧版 sport_personal_records 的静态个人纪录。新版能从 workouts 算出的项目
-- 仍然动态算；这里只补历史最佳（尤其是缺分段数据的 5K/10K/半马成绩）。
CREATE TABLE IF NOT EXISTS legacy_personal_records(
  sport TEXT NOT NULL,
  metric TEXT NOT NULL,
  value REAL NOT NULL,
  achieved_ms INTEGER NOT NULL DEFAULT 0,
  workout_id TEXT NOT NULL DEFAULT '',
  PRIMARY KEY(sport, metric)
);

-- 云同步增量游标：只记表名和主键，真正的行内容在导出增量时回表读取。
CREATE TABLE IF NOT EXISTS sync_changelog(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name TEXT NOT NULL,
  pk TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0
);
"#,
    )?;
    for (table, column, decl) in [
        ("daily_metrics", "body_temp_c", "REAL"),
        ("daily_metrics", "respiration", "REAL"),
        ("weight_records", "height_cm", "REAL"),
        ("weight_records", "bmi", "REAL"),
        ("weight_records", "fat_mass_kg", "REAL"),
        ("weight_records", "muscle_mass_kg", "REAL"),
        ("weight_records", "water_mass_kg", "REAL"),
        ("weight_records", "protein_percent", "REAL"),
        ("weight_records", "bone_percent", "REAL"),
        ("weight_records", "device_name", "TEXT"),
        ("weight_records", "protein_mass_kg", "REAL"),
        ("weight_records", "bone_mass_kg", "REAL"),
        ("weight_records", "skeletal_muscle_percent", "REAL"),
        ("weight_records", "skeletal_muscle_mass_kg", "REAL"),
        ("weight_records", "subcutaneous_fat_percent", "REAL"),
        ("weight_records", "subcutaneous_fat_mass_kg", "REAL"),
        ("weight_records", "resistance_ohm", "REAL"),
        ("weight_records", "body_composition_model", "TEXT"),
        ("workouts", "type_code", "INTEGER NOT NULL DEFAULT 0"),
        ("workouts", "total_time_sec", "INTEGER NOT NULL DEFAULT 0"),
        ("workouts", "active_calories", "INTEGER NOT NULL DEFAULT 0"),
        ("workouts", "max_met", "REAL"),
        ("workouts", "vo2max", "REAL"),
        ("workouts", "anaerobic_effect", "REAL NOT NULL DEFAULT 0"),
        ("workouts", "elevation_gain", "REAL"),
        ("workouts", "elevation_loss", "REAL"),
        ("workouts", "avg_pace_sec", "REAL"),
        ("workouts", "cadence", "REAL"),
        ("workouts", "detail_json", "TEXT"),
        ("workouts", "dynamics_json", "TEXT"),
        ("workouts", "altitude_json", "TEXT"),
        ("workouts", "recovery_json", "TEXT"),
        ("workouts", "splits_json", "TEXT"),
        ("workouts", "start_temp_c", "REAL"),
        ("workouts", "start_humidity", "INTEGER"),
        ("workouts", "training_points", "INTEGER"),
        ("workouts", "epoc", "INTEGER"),
        ("workouts", "stat_extend_json", "TEXT"),
        ("workouts", "run_pace_zones_json", "TEXT"),
        ("workouts", "max_altitude", "REAL"),
        ("workouts", "min_altitude", "REAL"),
        ("workouts", "alg_type", "INTEGER"),
        ("workouts", "upload_status", "INTEGER NOT NULL DEFAULT 0"),
        ("equipment", "gear_type", "TEXT NOT NULL DEFAULT 'shoes'"),
        ("equipment", "brand", "TEXT NOT NULL DEFAULT ''"),
        ("equipment", "model", "TEXT NOT NULL DEFAULT ''"),
        ("equipment", "purchase_ms", "INTEGER NOT NULL DEFAULT 0"),
        ("equipment", "is_active", "INTEGER NOT NULL DEFAULT 1"),
        ("sleep_bed", "duration_min", "INTEGER"),
        ("sleep_bed", "watch_score", "INTEGER"),
        ("sleep_bed", "watch_efficiency", "INTEGER"),
        ("sleep_bed", "watch_wake_count", "INTEGER"),
        ("sleep_sessions", "anchor_min", "INTEGER"),
    ] {
        add_column_if_missing(conn, table, column, decl)?;
    }
    // 旧版迁移与手表直连可能各存过同一场运动（legacy-* / watch-* 两套主键）。
    // 同类型且开始时间相差 2 分钟内视为同一条，保留手表同步的完整数据。
    // 旧版独有的跑力（vo2max）手表汇总包没有，删除前先补到手表行上。
    conn.execute(
        "UPDATE workouts
         SET vo2max = (
           SELECT MAX(l.vo2max) FROM workouts l
           WHERE l.id LIKE 'legacy-%'
             AND l.sport = workouts.sport
             AND ABS(l.start_ms - workouts.start_ms) <= 120000
         )
         WHERE id LIKE 'watch-%' AND vo2max IS NULL
           AND EXISTS (
             SELECT 1 FROM workouts l
             WHERE l.id LIKE 'legacy-%'
               AND l.sport = workouts.sport
               AND ABS(l.start_ms - workouts.start_ms) <= 120000
           )",
        [],
    )?;
    // 手表直连行过去只留 0，但汇总里其实带了实测 maxMET。1 MET 恒等于静息耗氧
    // 3.5 ml/kg/min，用它换算出 VO2max 回填历史运动（max_met>1000 是未换算的原始值，
    // 先 /100000）。只在 vo2max 缺失时写，重复打开不会覆盖已有值。
    conn.execute(
        "UPDATE workouts
         SET vo2max = (CASE WHEN max_met > 1000 THEN max_met / 100000.0 ELSE max_met END) * 3.5
         WHERE (vo2max IS NULL OR vo2max = 0)
           AND max_met IS NOT NULL AND max_met > 0
           AND (CASE WHEN max_met > 1000 THEN max_met / 100000.0 ELSE max_met END) * 3.5
                 BETWEEN 1.0 AND 120.0",
        [],
    )?;
    conn.execute(
        "DELETE FROM workouts
         WHERE id LIKE 'legacy-%'
           AND EXISTS (
             SELECT 1 FROM workouts w
             WHERE w.id LIKE 'watch-%'
               AND w.sport = workouts.sport
               AND ABS(w.start_ms - workouts.start_ms) <= 120000
           )",
        [],
    )?;
    // 早期实时同步每次回调都把同一晚写成一条新会话（start_ms 相同、end_ms 越来越长）。
    // 同一 (start_ms, source) 只保留结束时间最晚的一条，并加唯一索引让重建真正幂等。
    conn.execute(
        "DELETE FROM sleep_sessions
         WHERE EXISTS (
           SELECT 1 FROM sleep_sessions AS newer
           WHERE newer.start_ms = sleep_sessions.start_ms
             AND newer.source = sleep_sessions.source
             AND (newer.end_ms > sleep_sessions.end_ms
                  OR (newer.end_ms = sleep_sessions.end_ms AND newer.id > sleep_sessions.id))
         )",
        [],
    )?;
    // 白天稀疏分期曾被串成长达数小时、实际只睡着几十分钟的“假睡眠”。
    // 真实夜间睡眠密度通常 >90%，这里顺手清掉低密度长跨度片段。
    conn.execute(
        "DELETE FROM sleep_sessions
         WHERE (deep_min + light_min + rem_min) < 5
            OR ((end_ms - start_ms) >= 180 * 60000
                AND (deep_min + light_min + rem_min) * 100
                    < ((end_ms - start_ms) / 60000) * 35)",
        [],
    )?;
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_sleep_session_unique
         ON sleep_sessions(start_ms, source)",
        [],
    )?;
    // v4/v5 的睡眠重建都早于「整段 sleep 窗口单独成场」的修复，
    // v5 又只重算日报表、没重写会话，所以 v6 必须再全量重建一次；
    // v6 发布后才发现无锚点午睡（白天只有 light/deep 分期）会被 45 分钟
    // 聚类并进噪声，v7 需要让已经升到 v6 的库也重跑一次。
    if previous_version < 7 {
        let demo = conn
            .query_row(
                "SELECT value FROM settings WHERE key = 'demo_data'",
                [],
                |r| r.get::<_, String>(0),
            )
            .optional()?
            .map(|v| v == "1")
            .unwrap_or(false);
        let stages: i64 = conn.query_row("SELECT COUNT(*) FROM sleep_stages", [], |r| r.get(0))?;
        if !demo && stages > 0 {
            crate::watch::rebuild_sleep_sessions(conn)?;
        } else {
            recompute_sleep_daily_metrics(conn)?;
        }
    }
    if previous_version < 8 {
        // 旧库导入和云端快照各自会写同一晚的会话，start_ms 不同但区间高度重叠。
        // 首页汇总会临时去重，原始表和下一次云端导出却会继续叠加，所以这里落到表里。
        dedupe_sleep_session_rows(conn)?;
    }
    if previous_version < 9 {
        // 手表会把晨间静止误判成一场短“睡眠”。低密度片段即使不到 3 小时
        // 也会把当天总时长抬高；按 90 分钟起算，统一清掉不足 35% 的稀疏窗口。
        conn.execute(
            "DELETE FROM sleep_sessions
             WHERE (deep_min + light_min + rem_min) < 5
                OR ((end_ms - start_ms) >= 90 * 60000
                    AND (deep_min + light_min + rem_min) * 100
                        < ((end_ms - start_ms) / 60000) * 35)",
            [],
        )?;
        recompute_sleep_daily_metrics(conn)?;
    }
    if previous_version < 11 {
        // v11 保存手表 TruSleep 的整段睡眠锚点。用它作为最终总时长，
        // 避免分钟分期四舍五入造成 6h18 在 App 里变成 6h20。
        crate::watch::rebuild_sleep_sessions(conn)?;
    }
    if previous_version < 12 {
        // v11 的重建会跳过「分期字段没变」的会话，导致 anchor_min 一直是 NULL。
        // v12 把锚点纳入变更比较后重跑一次，把已存在的会话补齐。
        crate::watch::rebuild_sleep_sessions(conn)?;
    }
    backfill_sleep_stage_minutes(conn)?;
    // 旧版 maxMET 是 1e5 定点（899398 = 8.99）。早期导入把原值直接落库，
    // 这里做一次幂等归一化，避免运动详情继续显示 899398。
    conn.execute(
        "UPDATE workouts SET max_met = max_met / 100000.0 WHERE max_met > 1000.0",
        [],
    )?;
    // 迁移语句都跑完再装触发器，避免每次启动把幂等迁移误记成用户改动。
    crate::cloud::install_sync_triggers(conn)?;
    conn.pragma_update(None, "user_version", DB_VERSION)?;
    Ok(())
}

/// 早期导入只写了总睡眠时长，深睡/REM 是 0；实时重建拿到分期后，
/// 若当天总时长相同（或更长），把分期分钟数补回 daily_metrics。
fn backfill_sleep_stage_minutes(conn: &Connection) -> Result<()> {
    let mut days = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT date_day, sleep_minutes FROM daily_metrics
             WHERE sleep_minutes IS NOT NULL AND sleep_minutes > 0",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?)))?;
        for row in rows {
            days.push(row?);
        }
    }
    for (day, total) in days {
        let valid: Vec<SleepSessionRow> = sleep_sessions_ending_on(conn, day)?
            .into_iter()
            .filter(SleepSessionRow::valid)
            .collect();
        if valid.is_empty() {
            continue;
        }
        let deep = valid.iter().map(|s| s.deep).sum::<f64>();
        let light = valid.iter().map(|s| s.light).sum::<f64>();
        let rem = valid.iter().map(|s| s.rem).sum::<f64>();
        let awake = valid.iter().map(|s| s.awake).sum::<f64>();
        // 必须和当天总额对得上；旧日报可能只记了主睡眠，和会话合计不一致时不要覆盖。
        if (deep + light + rem - total).abs() > 1.0 {
            continue;
        }
        conn.execute(
            "UPDATE daily_metrics
             SET deep_sleep_minutes = ?2, rem_sleep_minutes = ?3, awake_minutes = ?4
             WHERE date_day = ?1
               AND (COALESCE(deep_sleep_minutes, -1) <> ?2
                    OR COALESCE(rem_sleep_minutes, -1) <> ?3
                    OR COALESCE(awake_minutes, -1) <> ?4)",
            params![day, deep, rem, awake],
        )?;
    }
    Ok(())
}

fn add_column_if_missing(conn: &Connection, table: &str, column: &str, decl: &str) -> Result<()> {
    let exists: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        params![table, column],
        |r| r.get(0),
    )?;
    if exists == 0 {
        conn.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} {decl}"))?;
    }
    Ok(())
}

pub fn today_epoch_day() -> i64 {
    let today = Local::now().date_naive();
    epoch_day_of(today)
}

/// 无手表实时同步时，当天可能还没有任何数据；此时回退到最近 7 天内有数据的一天，
/// 让离线导入的快照仍然可见。仅对“今天”这一语义生效。
pub fn display_day(day: i64) -> Result<i64> {
    with_conn(|conn| {
        let has: i64 = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM daily_metrics WHERE date_day = ?1
               AND (steps > 0 OR resting_hr IS NOT NULL OR sleep_minutes IS NOT NULL OR hrv_ms IS NOT NULL))",
            params![day],
            |r| r.get(0),
        )?;
        if has == 1 {
            return Ok(day);
        }
        let latest: Option<i64> = conn.query_row(
            "SELECT MAX(date_day) FROM daily_metrics WHERE date_day <= ?1
               AND (steps > 0 OR resting_hr IS NOT NULL OR sleep_minutes IS NOT NULL OR hrv_ms IS NOT NULL)",
            params![day],
            |r| r.get(0),
        )?;
        Ok(match latest {
            Some(d) if d < day && day - d <= 7 => d,
            _ => day,
        })
    })
}

pub fn latest_sleep_day() -> Result<Option<i64>> {
    with_conn(|conn| {
        // MAX() 在空表上返回一行 NULL；换成 ORDER BY ... LIMIT 1 会在没有睡眠记录时直接报错
        // 用醒来时间归属“这一晚”，昨晚 23:30 睡到今天 04:52 应算今天。
        let end: Option<i64> =
            conn.query_row("SELECT MAX(end_ms) FROM sleep_sessions", [], |r| r.get(0))?;
        Ok(end.map(local_epoch_day))
    })
}

pub fn epoch_day_of(date: NaiveDate) -> i64 {
    date.signed_duration_since(NaiveDate::from_ymd_opt(1970, 1, 1).unwrap())
        .num_days()
}

pub fn date_of_epoch_day(day: i64) -> NaiveDate {
    NaiveDate::from_ymd_opt(1970, 1, 1).unwrap() + Duration::days(day)
}

fn local_epoch_day(ts_ms: i64) -> i64 {
    chrono::DateTime::from_timestamp_millis(ts_ms)
        .map(|dt| epoch_day_of(dt.with_timezone(&Local).date_naive()))
        .unwrap_or(ts_ms / 86_400_000)
}

fn day_start_ms(day: i64) -> i64 {
    let date = date_of_epoch_day(day);
    let local = Local
        .from_local_datetime(&date.and_hms_opt(0, 0, 0).unwrap())
        .earliest()
        .or_else(|| {
            Local
                .from_local_datetime(&date.and_hms_opt(0, 0, 0).unwrap())
                .latest()
        });
    local
        .map(|dt| dt.timestamp_millis())
        .unwrap_or(day * 86_400_000)
}

fn day_end_ms(day: i64) -> i64 {
    day_start_ms(day + 1)
}

fn now_ms() -> i64 {
    Local::now().timestamp_millis()
}

#[derive(Default, Clone)]
pub struct MetricRow {
    pub steps: i64,
    pub calories: i64,
    pub active_calories: i64,
    pub distance_m: i64,
    pub active_minutes: i64,
    pub resting_hr: Option<f64>,
    pub sleep_minutes: Option<f64>,
    pub deep_sleep_minutes: Option<f64>,
    pub sleep_awakenings: Option<f64>,
    pub rem_sleep_minutes: Option<f64>,
    pub awake_minutes: Option<f64>,
    pub hrv_ms: Option<f64>,
    pub stress: Option<f64>,
    pub spo2: Option<f64>,
    pub skin_temp_c: Option<f64>,
    pub body_temp_c: Option<f64>,
    pub updated_ms: i64,
}

fn metric_row(conn: &Connection, day: i64) -> Result<MetricRow> {
    let row = conn
        .query_row(
            "SELECT steps, calories, active_calories, distance_m, active_minutes, resting_hr,
                    sleep_minutes, deep_sleep_minutes, rem_sleep_minutes, awake_minutes,
                    hrv_ms, stress, spo2, skin_temp_c, body_temp_c, updated_ms
             FROM daily_metrics WHERE date_day = ?1",
            params![day],
            |r| {
                Ok(MetricRow {
                    steps: r.get(0)?,
                    calories: r.get(1)?,
                    active_calories: r.get(2)?,
                    distance_m: r.get(3)?,
                    active_minutes: r.get(4)?,
                    resting_hr: r.get(5)?,
                    sleep_minutes: r.get(6)?,
                    deep_sleep_minutes: r.get(7)?,
                    sleep_awakenings: None,
                    rem_sleep_minutes: r.get(8)?,
                    awake_minutes: r.get(9)?,
                    hrv_ms: r.get(10)?,
                    stress: r.get(11)?,
                    spo2: r.get(12)?,
                    skin_temp_c: r.get(13)?,
                    body_temp_c: r.get(14)?,
                    updated_ms: r.get(15)?,
                })
            },
        )
        .optional()?;
    Ok(row.unwrap_or_default())
}

fn sleep_awakenings_for(conn: &Connection, start_ms: i64, end_ms: i64) -> Result<Option<f64>> {
    let mut stmt = conn.prepare(
        "SELECT start_ms, end_ms FROM sleep_stages
         WHERE stage = 'awake' AND end_ms > ?1 AND start_ms < ?2
         ORDER BY start_ms, end_ms",
    )?;
    let spans = stmt
        .query_map(params![start_ms, end_ms], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if spans.is_empty() {
        return Ok(None);
    }
    let mut count = 0;
    let mut current_end = i64::MIN;
    for (start, end) in spans {
        let start = start.max(start_ms);
        let end = end.min(end_ms);
        if end <= start {
            continue;
        }
        if start > current_end {
            count += 1;
        }
        current_end = current_end.max(end);
    }
    Ok(Some(count as f64))
}

/// 统一的当天指标入口：睡眠以 `sleep_sessions` 为准，避免 daily_metrics
/// 在“主睡眠先到、午睡后到”时停留在旧值。其余字段仍走日报表。
fn metric_row_with_sleep(conn: &Connection, day: i64) -> Result<MetricRow> {
    let mut row = metric_row(conn, day)?;
    if let Some(sleep) = sleep_summary_for(conn, day)? {
        row.sleep_minutes = Some(sleep.total_minutes as f64);
        row.deep_sleep_minutes = Some(sleep.deep_minutes as f64);
        row.sleep_awakenings = sleep_awakenings_for(conn, sleep.start_ms, sleep.end_ms)?;
        row.rem_sleep_minutes = Some(sleep.rem_minutes as f64);
        row.awake_minutes = Some(sleep.awake_minutes as f64);
    }
    Ok(row)
}

fn skin_temp_for(conn: &Connection, day: i64) -> Option<f64> {
    conn.query_row(
        "SELECT value FROM metric_points
         WHERE metric = 'skin_temp' AND ts_ms >= ?1 AND ts_ms < ?2
         ORDER BY ts_ms DESC LIMIT 1",
        params![day_start_ms(day), day_end_ms(day)],
        |r| r.get(0),
    )
    .optional()
    .ok()
    .flatten()
}

fn inputs_of(conn: &Connection, row: &MetricRow, day: i64) -> ReadinessInputs {
    ReadinessInputs {
        hrv_ms: row.hrv_ms,
        sleep_minutes: row.sleep_minutes,
        deep_sleep_minutes: row.deep_sleep_minutes,
        sleep_awakenings: row.sleep_awakenings,
        resting_hr: row.resting_hr,
        skin_temp_c: row.skin_temp_c.or_else(|| skin_temp_for(conn, day)),
        stress: row.stress,
        recovery_minutes: None,
    }
}

/// 同一天内多次运动按恢复时间累加；只有真的带恢复数据的运动才参与。
fn recovery_minutes_for(conn: &Connection, day: i64) -> Result<Option<f64>> {
    let (count, minutes): (i64, i64) = conn.query_row(
        "SELECT COUNT(*), COALESCE(SUM(recovery_time_min), 0)
         FROM workouts
         WHERE start_ms >= ?1 AND start_ms < ?2 AND recovery_time_min > 0",
        params![day_start_ms(day), day_end_ms(day)],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    Ok((count > 0).then_some(minutes as f64))
}

fn readiness_inputs_for(conn: &Connection, row: &MetricRow, day: i64) -> Result<ReadinessInputs> {
    let mut inputs = inputs_of(conn, row, day);
    inputs.recovery_minutes = recovery_minutes_for(conn, day)?;
    Ok(inputs)
}

fn baseline_for(conn: &Connection, day: i64) -> Result<ReadinessBaseline> {
    let mut history = Vec::with_capacity(7);
    for offset in 1..=7 {
        let row = metric_row_with_sleep(conn, day - offset)?;
        if row.updated_ms == 0 {
            continue;
        }
        history.push(inputs_of(conn, &row, day - offset));
    }
    Ok(readiness::baseline_from_history(&history))
}

fn readiness_for(conn: &Connection, day: i64) -> Result<ReadinessScore> {
    let row = metric_row_with_sleep(conn, day)?;
    let baseline = baseline_for(conn, day)?;
    let yesterday = if day > 0 {
        let y_day = day - 1;
        let y_row = metric_row_with_sleep(conn, y_day)?;
        if y_row.updated_ms > 0 {
            let y_base = baseline_for(conn, y_day)?;
            let y_inputs = readiness_inputs_for(conn, &y_row, y_day)?;
            Some(readiness::compute(&y_inputs, &y_base, None, 0).total)
        } else {
            None
        }
    } else {
        None
    };
    let inputs = readiness_inputs_for(conn, &row, day)?;
    let official_sleep_score = sleep_summary_for(conn, day)?
        .map(|summary| summary.score as f64)
        .filter(|value| *value > 0.0);
    Ok(readiness::compute_with_sleep_score(
        &inputs,
        &baseline,
        yesterday,
        now_ms(),
        official_sleep_score,
    ))
}

pub fn home_summary(day: i64) -> Result<HomeSummary> {
    with_conn(|conn| {
        let row = metric_row_with_sleep(conn, day)?;
        let score = readiness_for(conn, day)?;

        let mut history = Vec::with_capacity(7);
        for offset in (0..7).rev() {
            let d = day - offset;
            let s = readiness_for(conn, d)?;
            history.push(ReadinessPoint {
                date_epoch_day: d,
                total: s.total,
            });
        }

        let (weekly_load, weekly_workouts): (i64, i64) = conn.query_row(
            "SELECT COALESCE(SUM(load),0), COUNT(*) FROM workouts WHERE start_ms >= ?1",
            params![day_start_ms(day - 6)],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;

        let device = conn
            .query_row(
                "SELECT name, battery, last_sync_ms, connected FROM devices
                 ORDER BY connected DESC, last_sync_ms DESC LIMIT 1",
                [],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, Option<i64>>(2)?,
                        r.get::<_, i64>(3)?,
                    ))
                },
            )
            .optional()?;

        let sleep_heart_rate: Option<i64> = conn
            .query_row(
                "SELECT AVG(bpm) FROM heart_rate_points WHERE ts_ms >= ?1 AND ts_ms < ?2 AND bpm > 0",
                params![day_start_ms(day), day_end_ms(day)],
                |r| r.get::<_, Option<f64>>(0),
            )
            .optional()?
            .flatten()
            .map(|v| v.round() as i64);

        // 当前心率：最近 36 小时内最新一次采样，和心率详情的口径保持一致。
        // 不能只看 day 窗口：凌晨今天还没有日报数据时，display_day 会回退到昨天，
        // 首页会停在昨天的 77，而详情页已经显示今天刚测的 66。
        let heart_rate_since = now_ms() - 36 * 3_600_000;
        let heart_rate: Option<i64> = conn
            .query_row(
                "SELECT bpm FROM heart_rate_points WHERE ts_ms >= ?1 AND bpm > 0 ORDER BY ts_ms DESC LIMIT 1",
                params![heart_rate_since],
                |r| r.get::<_, f64>(0),
            )
            .optional()?
            .map(|v| v.round() as i64);

        // 当日 24 个小时桶的平均心率，缺数据的时段为 None
        let mut heart_rate_series: Vec<Option<f64>> = vec![None; 24];
        {
            let mut stmt = conn.prepare(
                "SELECT (ts_ms - ?1) / 3600000, AVG(bpm) FROM heart_rate_points
                 WHERE ts_ms >= ?1 AND ts_ms < ?2 AND bpm > 0 GROUP BY 1",
            )?;
            let rows = stmt.query_map(params![day_start_ms(day), day_end_ms(day)], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?))
            })?;
            for row in rows {
                let (hour, avg) = row?;
                if hour >= 0 && hour < 24 {
                    heart_rate_series[hour as usize] = Some(((avg * 10.0).round()) / 10.0);
                }
            }
        }

        // 活动小时数只能靠逐小时步数样本判断：手表同步来的 step_samples 才有这个粒度，
        // 日报里的 active_minutes 是分钟总量，补不出「哪几个小时动过」。
        let mut buckets = [0i64; 24];
        let mut has_hourly = false;
        {
            // step_samples.ts 是秒（手表侧按秒上报），别和 ms 的表混着用同一条参数
            let (start_sec, end_sec) = (day_start_ms(day) / 1000, day_end_ms(day) / 1000);
            let mut stmt = conn.prepare(
                "SELECT (ts - ?1) / 3600, SUM(steps) FROM step_samples
                 WHERE ts >= ?1 AND ts < ?2 AND steps > 0 GROUP BY 1",
            )?;
            let rows = stmt.query_map(params![start_sec, end_sec], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
            })?;
            for row in rows {
                let (hour, steps) = row?;
                if hour >= 0 && hour < 24 {
                    has_hourly = true;
                    buckets[hour as usize] += steps;
                }
            }
        }
        // 优先用官方数据：每日三环里的活动小时数是最准的（手表自己算），
        // 其次是 200005 每小时状态，最后才退回按步数样本估算。
        let official_active_hours: Option<i64> = conn
            .query_row(
                "SELECT active_user_hours FROM daily_rings WHERE date_day = ?1",
                params![day],
                |r| r.get::<_, i64>(0),
            )
            .optional()?
            .filter(|v| *v > 0);
        let hourly_status_hours: i64 = conn.query_row(
            "SELECT COUNT(*) FROM hourly_status WHERE ts_ms >= ?1 AND ts_ms < ?2 AND value > 0",
            params![day_start_ms(day), day_end_ms(day)],
            |r| r.get(0),
        )?;
        let active_hours: Option<i64> = official_active_hours.or_else(|| {
            if hourly_status_hours > 0 {
                Some(hourly_status_hours)
            } else {
                has_hourly.then(|| buckets.iter().filter(|s| **s >= 20).count() as i64)
            }
        });

        let (device_name, device_battery, last_sync_ms, device_connected) = match device {
            Some((name, battery, sync, connected)) => {
                (Some(name), Some(battery), sync, connected != 0)
            }
            None => (None, None, None, false),
        };

        let weight: Option<(f64, Option<f64>, Option<f64>)> = conn
            .query_row(
                "SELECT weight_kg, bmi, body_fat_percent FROM weight_records ORDER BY timestamp_ms DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        let bp: Option<(i64, i64)> = conn
            .query_row(
                "SELECT systolic, diastolic FROM blood_pressure_records ORDER BY timestamp_ms DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let glucose: Option<f64> = conn
            .query_row(
                "SELECT value FROM blood_glucose_records ORDER BY timestamp_ms DESC LIMIT 1",
                [],
                |r| r.get(0),
            )
            .optional()?;
        let respiration: Option<f64> = conn
            .query_row(
                "SELECT respiration FROM daily_metrics WHERE date_day = ?1",
                params![day],
                |r| r.get::<_, Option<f64>>(0),
            )
            .optional()
            .ok()
            .flatten()
            .flatten()
            .or_else(|| metric_day_value(conn, "respiration", day))
            // 呼吸率只在上床那一刻打一个点，夜里跨过零点就落不进「今天」这一行，
            // 但睡眠详情会把它算进昨晚——首页留空会和详情页自相矛盾。
            .or_else(|| latest_metric_value(conn, "respiration"));
        let arrhythmia: Option<(i64, i64)> = conn
            .query_row(
                "SELECT result_type, ts_ms FROM arrhythmia_records ORDER BY ts_ms DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let emotion: Option<(i64, Option<f64>, Option<f64>)> = conn
            .query_row(
                "SELECT status, valence, arousal FROM emotion_records ORDER BY ts_ms DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        let vo2max: Option<f64> = conn
            .query_row(
                "SELECT vo2max FROM workouts WHERE vo2max IS NOT NULL AND vo2max > 0 ORDER BY start_ms DESC LIMIT 1",
                [],
                |r| r.get(0),
            )
            .optional()?;
        let height = profile_height(conn).unwrap_or(170.0);
        let (weight_kg, bmi, body_fat_percent) = match weight {
            Some((w, b, f)) => (
                Some(w),
                b.or_else(|| Some((w / (height / 100.0).powi(2) * 10.0).round() / 10.0)),
                f,
            ),
            None => (None, None, None),
        };
        // 腕部温度一天往往只有一两个点，夜里跨零点或当天还没测就落不进「今天」这行。
        // 详情页能画出来的读数，首页卡片不该空着，所以回落到最近一次测量并带上时间。
        let skin: Option<(f64, i64)> = conn
            .query_row(
                "SELECT value, ts_ms FROM metric_points WHERE metric = 'skin_temp' ORDER BY ts_ms DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let skin_temp_c = skin.map(|(v, _)| v).or(row.skin_temp_c);
        let skin_temp_at_ms = skin.map(|(_, ts)| ts);
        // 腕温只有 28–34°C，不能当核心体温展示。手表同时上报 body_temp 时优先用它；
        // 没有核心体温的老记录才回落到腕温。
        let body: Option<(f64, i64)> = conn
            .query_row(
                "SELECT value, ts_ms FROM metric_points
                 WHERE metric = 'body_temp' AND value BETWEEN 34 AND 42
                 ORDER BY ts_ms DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let body_temp_c = body
            .map(|(v, _)| v)
            .or(row.body_temp_c.filter(|v| (34.0..=42.0).contains(v)));
        let body_temp_at_ms = body.map(|(_, ts)| ts);

        Ok(HomeSummary {
            date_epoch_day: day,
            readiness: score,
            readiness_history: history,
            steps: row.steps,
            steps_goal: setting_i64(conn, "goal_steps", 10_000),
            active_calories: row.active_calories,
            calories_goal: setting_i64(conn, "goal_calories", 500),
            distance_m: row.distance_m,
            active_minutes: row.active_minutes,
            exercise_minutes: exercise_minutes(conn, day)?,
            exercise_goal_min: setting_i64(conn, "goal_exercise_minutes", 30),
            active_hours,
            active_hours_goal: setting_i64(conn, "goal_active_hours", 9),
            running_index: conn
                .query_row(
                    // 华为规则：只认超过 12 分钟、心率 ≥100bpm 的跑步，按最佳成绩划定跑力
                    "SELECT MAX(vo2max) FROM workouts
                     WHERE sport = 'running' AND vo2max > 0 AND avg_hr >= 100
                       AND start_ms >= ?1
                       AND COALESCE(total_time_sec, (end_ms - start_ms) / 1000) >= 720",
                    [day_end_ms(day) - 90 * 86400 * 1000],
                    |r| r.get::<_, Option<f64>>(0),
                )
                .unwrap_or(None),
            // 静息心率要到当天晚些才结算，今天这一行经常还是 NULL。
            // 首页不能因此空着，回落到最近一次已结算值（先日报，再逐点采样）。
            resting_hr: row
                .resting_hr
                .or_else(|| latest_resting_hr(conn, day))
                .map(|v| v.round() as i64),
            heart_rate,
            heart_rate_series,
            hrv_ms: row.hrv_ms.map(|v| v.round() as i64),
            sleep_minutes: row.sleep_minutes.map(|v| v.round() as i64),
            deep_sleep_minutes: row.deep_sleep_minutes.map(|v| v.round() as i64),
            sleep_heart_rate,
            spo2: row.spo2.map(|v| v.round() as i64),
            stress: row.stress.map(|v| v.round() as i64),
            body_temp_delta: skin_temp_c.map(|t| ((t - 33.4) * 10.0).round() / 10.0),
            skin_temp_c,
            skin_temp_at_ms,
            body_temp_c,
            body_temp_at_ms,
            weight_kg,
            bmi,
            body_fat_percent,
            blood_pressure_systolic: bp.map(|v| v.0),
            blood_pressure_diastolic: bp.map(|v| v.1),
            glucose_mmol: glucose,
            respiration: respiration.map(|v| v.round() as i64),
            arrhythmia_result: arrhythmia.map(|v| v.0),
            arrhythmia_at_ms: arrhythmia.map(|v| v.1),
            emotion_status: emotion.as_ref().map(|v| v.0),
            emotion_valence: emotion.as_ref().and_then(|v| v.1),
            emotion_arousal: emotion.as_ref().and_then(|v| v.2),
            vo2max,
            weekly_load,
            weekly_workouts,
            last_sync_ms,
            device_name,
            device_battery,
            device_connected,
        })
    })
}

fn profile_height(conn: &Connection) -> Option<f64> {
    conn.query_row("SELECT height_cm FROM profile WHERE id = 1", [], |r| {
        r.get(0)
    })
    .optional()
    .ok()
    .flatten()
}

fn setting_i64(conn: &Connection, key: &str, fallback: i64) -> i64 {
    conn.query_row(
        "SELECT value FROM settings WHERE key = ?1",
        params![key],
        |r| r.get::<_, String>(0),
    )
    .optional()
    .ok()
    .flatten()
    .and_then(|v| v.parse::<i64>().ok())
    .unwrap_or(fallback)
}

fn setting_f64(conn: &Connection, key: &str, fallback: f64) -> f64 {
    conn.query_row(
        "SELECT value FROM settings WHERE key = ?1",
        params![key],
        |r| r.get::<_, String>(0),
    )
    .optional()
    .ok()
    .flatten()
    .and_then(|v| v.parse::<f64>().ok())
    .unwrap_or(fallback)
}

fn setting_string(conn: &Connection, key: &str, fallback: &str) -> String {
    conn.query_row(
        "SELECT value FROM settings WHERE key = ?1",
        params![key],
        |r| r.get::<_, String>(0),
    )
    .optional()
    .ok()
    .flatten()
    .unwrap_or_else(|| fallback.to_string())
}

fn latest_metric_value(conn: &Connection, metric: &str) -> Option<f64> {
    conn.query_row(
        "SELECT value FROM metric_points WHERE metric = ?1 ORDER BY ts_ms DESC LIMIT 1",
        params![metric],
        |r| r.get::<_, Option<f64>>(0),
    )
    .optional()
    .ok()
    .flatten()
    .flatten()
}

fn latest_resting_hr(conn: &Connection, day: i64) -> Option<f64> {
    conn.query_row(
        "SELECT resting_hr FROM daily_metrics
         WHERE date_day <= ?1 AND resting_hr IS NOT NULL
         ORDER BY date_day DESC LIMIT 1",
        params![day],
        |r| r.get::<_, Option<f64>>(0),
    )
    .optional()
    .ok()
    .flatten()
    .flatten()
    .or_else(|| {
        conn.query_row(
            "SELECT value FROM metric_points
             WHERE metric = 'resting_hr' AND ts_ms < ?1
             ORDER BY ts_ms DESC LIMIT 1",
            params![day_end_ms(day)],
            |r| r.get::<_, Option<f64>>(0),
        )
        .optional()
        .ok()
        .flatten()
        .flatten()
    })
}

fn metric_day_value(conn: &Connection, metric: &str, day: i64) -> Option<f64> {
    conn.query_row(
        "SELECT AVG(value) FROM metric_points WHERE metric = ?1 AND ts_ms >= ?2 AND ts_ms < ?3",
        params![metric, day_start_ms(day), day_end_ms(day)],
        |r| r.get::<_, Option<f64>>(0),
    )
    .optional()
    .ok()
    .flatten()
    .flatten()
}

pub fn readiness_detail(day: i64) -> Result<ReadinessDetail> {
    with_conn(|conn| {
        let row = metric_row_with_sleep(conn, day)?;
        let baseline = baseline_for(conn, day)?;
        let score = readiness_for(conn, day)?;
        let inputs = readiness_inputs_for(conn, &row, day)?;
        let mut history = Vec::with_capacity(7);
        for offset in (0..7).rev() {
            let d = day - offset;
            history.push(ReadinessPoint {
                date_epoch_day: d,
                total: readiness_for(conn, d)?.total,
            });
        }
        Ok(ReadinessDetail {
            date_epoch_day: day,
            score,
            week_average: readiness::average(&history),
            history,
            inputs,
            baseline,
            weights: readiness::weights(),
        })
    })
}

pub fn readiness_series(days: i64) -> Result<Vec<DailyPoint>> {
    with_conn(|conn| {
        let today = today_epoch_day();
        let mut out = Vec::new();
        for offset in (0..days.max(1)).rev() {
            let d = today - offset;
            out.push(DailyPoint {
                date_epoch_day: d,
                value: readiness_for(conn, d)?.total as f64,
            });
        }
        Ok(out)
    })
}

pub fn metric_series(metric: &str, days: i64) -> Result<Vec<DailyPoint>> {
    with_conn(|conn| {
        let today = today_epoch_day();
        let column = match metric {
            "steps" => "steps",
            "calories" => "calories",
            "active_calories" => "active_calories",
            "distance" => "distance_m",
            "resting_hr" => "resting_hr",
            "hrv" => "hrv_ms",
            "sleep" => "sleep_minutes",
            "deep_sleep" => "deep_sleep_minutes",
            "rem_sleep" => "rem_sleep_minutes",
            "awake" => "awake_minutes",
            "stress" => "stress",
            "spo2" => "spo2",
            "temperature" => "skin_temp_c",
            "readiness" => {
                let mut out = Vec::new();
                for offset in (0..days.max(1)).rev() {
                    let d = today - offset;
                    out.push(DailyPoint {
                        date_epoch_day: d,
                        value: readiness_for(conn, d)?.total as f64,
                    });
                }
                return Ok(out);
            }
            other => return Err(anyhow!("unknown metric {other}")),
        };
        let mut out = Vec::new();
        let mut stmt = conn.prepare(&format!(
            "SELECT date_day, {column} FROM daily_metrics WHERE date_day >= ?1 ORDER BY date_day"
        ))?;
        let rows = stmt.query_map(params![today - days.max(1) + 1], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, Option<f64>>(1)?))
        })?;
        for row in rows {
            let (d, v) = row?;
            if let Some(v) = v {
                out.push(DailyPoint {
                    date_epoch_day: d,
                    value: v,
                });
            }
        }
        Ok(out)
    })
}

pub fn metric_days(from_day: i64, to_day: i64) -> Result<Vec<MetricDay>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT date_day, steps, active_calories, resting_hr, hrv_ms, sleep_minutes, stress, spo2, skin_temp_c
             FROM daily_metrics WHERE date_day BETWEEN ?1 AND ?2 ORDER BY date_day",
        )?;
        let rows = stmt.query_map(params![from_day, to_day], |r| {
            Ok(MetricDay {
                date_epoch_day: r.get(0)?,
                steps: r.get(1)?,
                active_calories: r.get(2)?,
                resting_hr: r.get::<_, Option<f64>>(3)?.map(|v| v.round() as i64),
                hrv_ms: r.get::<_, Option<f64>>(4)?.map(|v| v.round() as i64),
                sleep_minutes: r.get::<_, Option<f64>>(5)?.map(|v| v.round() as i64),
                stress: r.get::<_, Option<f64>>(6)?.map(|v| v.round() as i64),
                spo2: r.get::<_, Option<f64>>(7)?.map(|v| v.round() as i64),
                weight_kg: None,
                skin_temp_c: r.get(8)?,
            })
        })?;
        let mut out: Vec<MetricDay> = rows.collect::<rusqlite::Result<_>>()?;
        let weight: Option<f64> = conn
            .query_row(
                "SELECT weight_kg FROM weight_records ORDER BY timestamp_ms DESC LIMIT 1",
                [],
                |r| r.get(0),
            )
            .optional()?;
        for day in out.iter_mut() {
            day.weight_kg = weight;
        }
        Ok(out)
    })
}

#[derive(Clone, Copy)]
struct SleepSessionRow {
    start_ms: i64,
    end_ms: i64,
    deep: f64,
    light: f64,
    rem: f64,
    awake: f64,
    anchor_min: Option<f64>,
}

impl SleepSessionRow {
    fn asleep(&self) -> f64 {
        self.deep + self.light + self.rem
    }

    fn wall_minutes(&self) -> f64 {
        ((self.end_ms - self.start_ms).max(0) as f64) / 60_000.0
    }

    /// 午睡可以短，但白天零星打点不能当睡眠：至少睡着 5 分钟；
    /// 跨度超过 3 小时却只有不到 35% 的时间在睡，也按假睡眠丢掉。
    fn valid(&self) -> bool {
        let asleep = self.asleep();
        asleep >= 5.0
            && !(self.wall_minutes() >= 90.0 && asleep * 100.0 < self.wall_minutes() * 35.0)
    }
}

/// 睡眠按“醒来日”归属：昨晚 23:30 睡到今天 07:00、今天午睡到 13:30，
/// 两场都算今天的睡眠。
fn sleep_sessions_ending_on(conn: &Connection, day: i64) -> Result<Vec<SleepSessionRow>> {
    let mut stmt = conn.prepare(
        "SELECT start_ms, end_ms, deep_min, light_min, rem_min, awake_min, anchor_min
         FROM sleep_sessions WHERE end_ms >= ?1 AND end_ms < ?2 ORDER BY start_ms",
    )?;
    let rows = stmt.query_map(params![day_start_ms(day), day_end_ms(day)], |r| {
        Ok(SleepSessionRow {
            start_ms: r.get(0)?,
            end_ms: r.get(1)?,
            deep: r.get(2)?,
            light: r.get(3)?,
            rem: r.get(4)?,
            awake: r.get(5)?,
            anchor_min: r.get(6)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// 同一晚可能被旧版实时同步、旧库导入、手表重建各写一条，区间高度重叠。
/// 只保留睡得最长的那条，避免把同一场睡眠重复累加。
fn dedupe_sleep_sessions(mut sessions: Vec<SleepSessionRow>) -> Vec<SleepSessionRow> {
    sessions.sort_by_key(|s| s.start_ms);
    let mut out: Vec<SleepSessionRow> = Vec::with_capacity(sessions.len());
    for session in sessions {
        if let Some(prev) = out.last_mut() {
            if session.start_ms < prev.end_ms {
                if session.asleep() > prev.asleep() {
                    *prev = session;
                }
                continue;
            }
        }
        out.push(session);
    }
    out
}

/// 把同一晚被旧库导入、云端快照、手表重建分别写入的重叠会话落到表里。
/// 保留实际睡着时间更长的一条；互不重叠的午睡和主睡眠仍然都保留。
pub(crate) fn dedupe_sleep_session_rows(conn: &Connection) -> Result<()> {
    let mut rows = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT id, start_ms, end_ms, deep_min, light_min, rem_min, awake_min, anchor_min
             FROM sleep_sessions ORDER BY start_ms, end_ms DESC, id",
        )?;
        let iter = stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                SleepSessionRow {
                    start_ms: r.get(1)?,
                    end_ms: r.get(2)?,
                    deep: r.get(3)?,
                    light: r.get(4)?,
                    rem: r.get(5)?,
                    awake: r.get(6)?,
                    anchor_min: r.get(7)?,
                },
            ))
        })?;
        rows.extend(iter.collect::<rusqlite::Result<Vec<_>>>()?);
    }

    let mut kept: Vec<(i64, SleepSessionRow)> = Vec::new();
    let mut remove: Vec<i64> = Vec::new();
    for (id, session) in rows {
        let Some((prev_id, prev)) = kept.last_mut() else {
            kept.push((id, session));
            continue;
        };
        let overlap =
            (session.end_ms.min(prev.end_ms) - session.start_ms.max(prev.start_ms)).max(0);
        let shorter = (session.end_ms - session.start_ms)
            .min(prev.end_ms - prev.start_ms)
            .max(1);
        if overlap * 2 <= shorter {
            kept.push((id, session));
            continue;
        }
        if session.asleep() > prev.asleep() {
            remove.push(*prev_id);
            *prev_id = id;
            *prev = session;
        } else {
            remove.push(id);
        }
    }
    for id in remove {
        conn.execute("DELETE FROM sleep_sessions WHERE id = ?1", params![id])?;
    }
    recompute_sleep_daily_metrics(conn)?;
    Ok(())
}

/// 白天短睡容易被手表按“静止”误判成睡眠。用同段心率做二次确认：
/// 平均心率明显高于静息心率（+20bpm）的片段不算睡眠。
/// 心率样本太少或没有日报静息心率时，仍以手表分期为准。
fn sleep_session_heart_rate_ok(conn: &Connection, session: &SleepSessionRow) -> Result<bool> {
    let (count, avg): (i64, Option<f64>) = conn.query_row(
        "SELECT COUNT(*), AVG(bpm) FROM heart_rate_points
         WHERE ts_ms >= ?1 AND ts_ms < ?2 AND bpm > 0",
        params![session.start_ms, session.end_ms],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let Some(avg) = avg else {
        return Ok(true);
    };
    if count < 5 {
        return Ok(true);
    }
    let day = local_epoch_day(session.end_ms);
    let resting: Option<f64> = conn
        .query_row(
            "SELECT resting_hr FROM daily_metrics WHERE date_day = ?1",
            params![day],
            |r| r.get(0),
        )
        .optional()?
        .flatten();
    let threshold = resting.map(|r| r + 20.0).unwrap_or(75.0).max(70.0);
    Ok(avg <= threshold)
}

fn valid_sleep_sessions_for(conn: &Connection, day: i64) -> Result<Vec<SleepSessionRow>> {
    let mut sessions = Vec::new();
    for session in sleep_sessions_ending_on(conn, day)? {
        if session.valid() && sleep_session_heart_rate_ok(conn, &session)? {
            sessions.push(session);
        }
    }
    Ok(dedupe_sleep_sessions(sessions))
}

#[derive(Clone, Copy)]
struct WatchSleepCorrection {
    duration_min: Option<i64>,
    score: Option<i64>,
    efficiency: Option<i64>,
    wake_count: Option<i64>,
    wake_ms: Option<i64>,
}

fn watch_sleep_correction(
    conn: &Connection,
    session: &SleepSessionRow,
) -> Result<Option<WatchSleepCorrection>> {
    let row = conn
        .query_row(
            "SELECT duration_min, watch_score, watch_efficiency, watch_wake_count, wake_ms
             FROM sleep_bed
             WHERE COALESCE(fall_asleep_ms, bed_ms, session_start_ms)
                   BETWEEN ?1 - 3600000 AND ?2
             ORDER BY ABS(COALESCE(fall_asleep_ms, bed_ms, session_start_ms) - ?1),
                      (watch_score IS NULL),
                      (watch_efficiency IS NULL),
                      (wake_ms IS NULL),
                      session_start_ms DESC
             LIMIT 1",
            params![session.start_ms, session.end_ms],
            |r| {
                Ok(WatchSleepCorrection {
                    duration_min: r.get(0)?,
                    score: r.get(1)?,
                    efficiency: r.get(2)?,
                    wake_count: r.get(3)?,
                    wake_ms: r.get(4)?,
                })
            },
        )
        .optional()?;
    Ok(row)
}

fn sleep_summary_for(conn: &Connection, day: i64) -> Result<Option<SleepSummary>> {
    let sessions = valid_sleep_sessions_for(conn, day)?;
    if sessions.is_empty() {
        return Ok(None);
    }
    let deep = sessions.iter().map(|s| s.deep).sum::<f64>();
    let mut light = sessions.iter().map(|s| s.light).sum::<f64>();
    let mut rem = sessions.iter().map(|s| s.rem).sum::<f64>();
    let awake = sessions.iter().map(|s| s.awake).sum::<f64>();
    let detailed_asleep = deep + light + rem;
    let anchor_asleep = sessions
        .iter()
        .filter_map(|session| session.anchor_min)
        .sum::<f64>();
    let main_asleep = sessions
        .iter()
        .map(|session| session.anchor_min.unwrap_or_else(|| session.asleep()))
        .fold(0.0, f64::max);
    let mut asleep = if anchor_asleep > 0.0 {
        anchor_asleep
    } else {
        detailed_asleep
    };
    if anchor_asleep > detailed_asleep {
        light += anchor_asleep - detailed_asleep;
    } else if anchor_asleep > 0.0 && detailed_asleep > anchor_asleep {
        let mut reduce = detailed_asleep - anchor_asleep;
        let from_light = light.min(reduce);
        light -= from_light;
        reduce -= from_light;
        if reduce > 0.0 {
            rem = (rem - reduce).max(0.0);
        }
    }
    let mut total = asleep + awake;
    let mut efficiency = if total > 0.0 {
        (asleep / total * 100.0).round() as i64
    } else {
        0
    };
    // 主睡眠取最长的一场，用来画睡眠阶段图；午睡只累加到总时长里。
    let main = sessions
        .iter()
        .max_by(|a, b| a.asleep().total_cmp(&b.asleep()))
        .copied()
        .unwrap_or(sessions[0]);
    let mut awakenings = sleep_awakenings_for(conn, main.start_ms, main.end_ms)?.unwrap_or(0.0);
    let mut score = readiness::sleep_score(asleep, deep, awakenings).round() as i64;
    let summary_start = main.start_ms;
    let mut summary_end = main.end_ms;

    // 700013 的分期文件可能在起床后仍晚几分钟才完整。手表摘要里的
    // 睡眠时长和官方评分是最终口径；缺的分期时长先补到浅睡，避免首页
    // 把 6h18 截成 4h44，再用自定义公式算出一个很低的伪分数。
    if let Some(correction) = watch_sleep_correction(conn, &main)? {
        if anchor_asleep <= 0.0 {
            if let Some(minutes) = correction.duration_min.filter(|v| *v > 0) {
                let tracked = asleep.round() as i64;
                let watch_asleep = (minutes as f64 - awake).max(0.0).round() as i64;
                if watch_asleep > tracked {
                    let missing = (watch_asleep - tracked) as f64;
                    light += missing;
                    asleep += missing;
                    total = asleep + awake;
                    efficiency = if total > 0.0 {
                        (asleep / total * 100.0).round() as i64
                    } else {
                        0
                    };
                }
                summary_end = summary_end.max(summary_start + minutes * 60_000);
            }
        }
        if let Some(wake) = correction.wake_ms.filter(|v| *v > summary_start) {
            summary_end = summary_end.max(wake);
        }
        if let Some(count) = correction.wake_count.filter(|v| *v >= 0) {
            awakenings = count as f64;
            score = readiness::sleep_score(asleep, deep, awakenings).round() as i64;
        }
        if let Some(official) = correction.score.filter(|v| (1..=100).contains(v)) {
            score = official;
        }
        if let Some(official) = correction.efficiency.filter(|v| (1..=100).contains(v)) {
            efficiency = official;
        }
    }
    let nap_minutes = (asleep - main_asleep).max(0.0).round() as i64;
    Ok(Some(SleepSummary {
        date_epoch_day: day,
        total_minutes: asleep.round() as i64,
        deep_minutes: deep.round() as i64,
        light_minutes: light.round() as i64,
        rem_minutes: rem.round() as i64,
        awake_minutes: awake.round() as i64,
        nap_minutes,
        start_ms: summary_start,
        end_ms: summary_end,
        efficiency,
        score,
    }))
}

pub fn sleep_summary(day: i64) -> Result<Option<SleepSummary>> {
    with_conn(|conn| sleep_summary_for(conn, day))
}

/// 把睡眠会话重算回日报表。任何写入/删除 sleep_sessions 的路径都要调用，
/// 否则会出现“详情页有午睡、首页还是主睡眠”的两套口径。
pub(crate) fn recompute_sleep_daily_metrics(conn: &Connection) -> Result<()> {
    let mut by_day: std::collections::BTreeMap<i64, Vec<SleepSessionRow>> =
        std::collections::BTreeMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT start_ms, end_ms, deep_min, light_min, rem_min, awake_min, anchor_min
             FROM sleep_sessions",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(SleepSessionRow {
                start_ms: r.get(0)?,
                end_ms: r.get(1)?,
                deep: r.get(2)?,
                light: r.get(3)?,
                rem: r.get(4)?,
                awake: r.get(5)?,
                anchor_min: r.get(6)?,
            })
        })?;
        for row in rows {
            let session = row?;
            by_day
                .entry(local_epoch_day(session.end_ms))
                .or_default()
                .push(session);
        }
    }
    for (day, sessions) in by_day {
        let mut valid = Vec::new();
        for session in sessions {
            if session.valid() && sleep_session_heart_rate_ok(conn, &session)? {
                valid.push(session);
            }
        }
        let sessions = valid;
        let sessions = dedupe_sleep_sessions(sessions);
        if sessions.is_empty() {
            conn.execute(
                "UPDATE daily_metrics
                 SET sleep_minutes = NULL, deep_sleep_minutes = NULL,
                     rem_sleep_minutes = NULL, awake_minutes = NULL
                 WHERE date_day = ?1
                   AND (sleep_minutes IS NOT NULL
                        OR deep_sleep_minutes IS NOT NULL
                        OR rem_sleep_minutes IS NOT NULL
                        OR awake_minutes IS NOT NULL)",
                params![day],
            )?;
            continue;
        }
        let deep = sessions.iter().map(|s| s.deep).sum::<f64>();
        let light = sessions.iter().map(|s| s.light).sum::<f64>();
        let rem = sessions.iter().map(|s| s.rem).sum::<f64>();
        let awake = sessions.iter().map(|s| s.awake).sum::<f64>();
        conn.execute(
            "INSERT INTO daily_metrics(
                date_day, sleep_minutes, deep_sleep_minutes, rem_sleep_minutes,
                awake_minutes, updated_ms)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(date_day) DO UPDATE SET
                sleep_minutes = excluded.sleep_minutes,
                deep_sleep_minutes = excluded.deep_sleep_minutes,
                rem_sleep_minutes = excluded.rem_sleep_minutes,
                awake_minutes = excluded.awake_minutes
             WHERE daily_metrics.sleep_minutes IS NOT excluded.sleep_minutes
                OR daily_metrics.deep_sleep_minutes IS NOT excluded.deep_sleep_minutes
                OR daily_metrics.rem_sleep_minutes IS NOT excluded.rem_sleep_minutes
                OR daily_metrics.awake_minutes IS NOT excluded.awake_minutes",
            params![day, deep + light + rem, deep, rem, awake, now_ms()],
        )?;
    }
    Ok(())
}

fn workout_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<WorkoutSummary> {
    let start_ms: i64 = r.get("start_ms")?;
    let end_ms: i64 = r.get("end_ms")?;
    Ok(WorkoutSummary {
        id: r.get("id")?,
        sport: r.get("sport")?,
        source: r.get("source")?,
        start_ms,
        end_ms,
        duration_sec: ((end_ms - start_ms).max(0) / 1000),
        distance_m: r.get("distance_m")?,
        calories: r.get("calories")?,
        avg_hr: r.get("avg_hr")?,
        max_hr: r.get("max_hr")?,
        steps: r.get("steps")?,
        load: r.get("load")?,
        synced: r.get::<_, i64>("synced")? != 0,
    })
}

/// 跑力历史：华为规则只认超过 12 分钟、心率 ≥100bpm 的跑步。
pub fn running_index_history(limit: i64) -> Result<Vec<RunningIndexPoint>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT start_ms, vo2max, distance_m,
                    COALESCE(total_time_sec, (end_ms - start_ms) / 1000), avg_hr
             FROM workouts
             WHERE sport = 'running' AND vo2max > 0 AND avg_hr >= 100
               AND COALESCE(total_time_sec, (end_ms - start_ms) / 1000) >= 720
             ORDER BY start_ms DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(RunningIndexPoint {
                start_ms: r.get(0)?,
                rai: r.get(1)?,
                distance_m: r.get(2)?,
                duration_sec: r.get(3)?,
                avg_hr: r.get(4)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

pub fn list_workouts(filter: &str, limit: i64) -> Result<Vec<WorkoutSummary>> {
    with_conn(|conn| {
        let where_clause = match filter {
            "watch" => "WHERE source = 'watch'",
            "phone" => "WHERE source = 'phone'",
            "pending" => "WHERE synced = 0",
            _ => "",
        };
        let mut stmt = conn.prepare(&format!(
            "SELECT * FROM workouts {where_clause} ORDER BY start_ms DESC LIMIT ?1"
        ))?;
        let rows = stmt.query_map(params![limit], workout_from_row)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

/// 手机端记录的一次运动（计时器 / 力量训练等）。返回新运动 id。
pub fn workout_add(
    sport: &str,
    start_ms: i64,
    duration_sec: i64,
    distance_m: f64,
    calories: i64,
    avg_hr: i64,
    max_hr: i64,
    track_json: &str,
) -> Result<String> {
    let sport = sport.trim();
    if sport.is_empty() {
        anyhow::bail!("sport 不能为空");
    }
    let duration_sec = duration_sec.max(1);
    let id = format!("manual-{start_ms}-{}", now_ms());
    with_conn(|conn| {
        conn.execute(
            "INSERT INTO workouts(
                id, source, sport, start_ms, end_ms, distance_m, calories,
                avg_hr, max_hr, synced, created_ms, track_json
             ) VALUES(?1, 'manual', ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1, ?9, NULLIF(?10, ''))",
            params![
                id,
                sport,
                start_ms,
                start_ms + duration_sec * 1000,
                distance_m.max(0.0),
                calories.max(0),
                avg_hr.max(0),
                max_hr.max(0),
                now_ms(),
                track_json,
            ],
        )?;
        Ok(())
    })?;
    Ok(id)
}

pub fn get_workout(id: &str) -> Result<Option<WorkoutDetail>> {
    with_conn(|conn| {
        let detail = conn
            .query_row("SELECT * FROM workouts WHERE id = ?1", params![id], |r| {
                let summary = workout_from_row(r)?;
                let detail_json: Option<String> = r.get("detail_json")?;
                let (detail_splits, swim_segments) = detail_parts(detail_json.as_deref());
                Ok(WorkoutDetail {
                    summary,
                    aerobic_effect: r.get::<_, f64>("aerobic_effect")?,
                    anaerobic_effect: r.get::<_, f64>("anaerobic_effect")?,
                    recovery_time_min: r.get::<_, i64>("recovery_time_min")?,
                    max_met: r.get("max_met")?,
                    vo2max: r.get("vo2max")?,
                    elevation_gain: r.get("elevation_gain")?,
                    elevation_loss: r.get("elevation_loss")?,
                    avg_pace_sec: r.get("avg_pace_sec")?,
                    cadence: r.get("cadence")?,
                    track_json: r.get("track_json")?,
                    samples_json: r.get("samples_json")?,
                    dynamics_json: r.get("dynamics_json")?,
                    altitude_json: r.get("altitude_json")?,
                    recovery_json: r.get("recovery_json")?,
                    splits_json: r.get::<_, Option<String>>("splits_json")?.or(detail_splits),
                    swim_segments_json: swim_segments,
                    start_temp_c: r.get("start_temp_c")?,
                    start_humidity: r.get("start_humidity")?,
                    training_points: r
                        .get::<_, Option<i64>>("training_points")?
                        .filter(|v| *v > 0),
                    epoc: r.get::<_, Option<i64>>("epoc")?.filter(|v| *v > 0),
                    stat_extend_json: r.get("stat_extend_json")?,
                    run_pace_zones_json: r.get("run_pace_zones_json")?,
                    max_altitude: r.get("max_altitude")?,
                    min_altitude: r.get("min_altitude")?,
                    alg_type: r.get::<_, Option<i64>>("alg_type")?.filter(|v| *v > 0),
                    upload_status: r.get::<_, Option<i64>>("upload_status")?.unwrap_or(0),
                })
            })
            .optional()?;
        Ok(detail)
    })
}

/// 新同步把官方配速分段和游泳分段一起塞进 `detail_json`；旧版本和手表原始
/// 分段各有各的字段名，这里统一成详情页认识的结构。
fn detail_parts(raw: Option<&str>) -> (Option<String>, Option<String>) {
    let Some(value) = raw.and_then(|s| serde_json::from_str::<Value>(s).ok()) else {
        return (None, None);
    };
    let splits = value
        .get("splits")
        .and_then(|v| v.as_array())
        .filter(|a| !a.is_empty())
        .map(|items| {
            let normalized: Vec<Value> = items
                .iter()
                .enumerate()
                .filter_map(|(index, item)| {
                    let pace = item.get("pace").and_then(|v| v.as_f64())?;
                    if pace <= 0.0 {
                        return None;
                    }
                    let kind = item.get("type").and_then(|v| v.as_i64()).unwrap_or(0);
                    if kind != 0 && kind != 1 {
                        return None;
                    }
                    Some(json!({
                        "i": item.get("i").and_then(|v| v.as_i64()).unwrap_or(index as i64),
                        "d": item.get("d").or_else(|| item.get("distance")).cloned().unwrap_or(json!(0)),
                        "type": kind,
                        "pace": pace,
                        "point": item.get("point").cloned().unwrap_or(json!(0)),
                        "corr": item.get("corr").cloned().unwrap_or(Value::Null),
                    }))
                })
                .collect();
            Value::Array(normalized).to_string()
        })
        .filter(|s| s != "[]");
    let swim = value
        .get("segments")
        .or_else(|| value.get("swim_segments"))
        .and_then(|v| v.as_array())
        .filter(|a| !a.is_empty())
        .map(|v| Value::Array(v.clone()).to_string());
    (splits, swim)
}

pub fn workout_set_recovery(id: &str, recovery_json: &str) -> Result<()> {
    with_conn(|conn| {
        conn.execute(
            "UPDATE workouts SET recovery_json = ?2 WHERE id = ?1",
            params![id, recovery_json],
        )?;
        Ok(())
    })
}

pub fn workout_track_json(id: &str) -> Result<Option<String>> {
    with_conn(|conn| {
        Ok(conn
            .query_row(
                "SELECT track_json FROM workouts WHERE id = ?1",
                params![id],
                |r| r.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten())
    })
}

/// 手机骑行记录没有手表动态数据，估算后写入功率曲线，并把摘要合并进
/// stat_extend_json（保留手表已有的扩展统计）。
pub fn workout_set_cycling_power(id: &str, dynamics_json: &str, stats_json: &str) -> Result<()> {
    let Some(power_stats) = crate::power::power_stat_extend(stats_json) else {
        anyhow::bail!("invalid cycling power stats");
    };
    with_conn(|conn| {
        let existing: Option<String> = conn
            .query_row(
                "SELECT stat_extend_json FROM workouts WHERE id = ?1",
                params![id],
                |r| r.get(0),
            )
            .optional()?
            .flatten();
        let mut merged = existing
            .as_deref()
            .and_then(|raw| serde_json::from_str::<serde_json::Value>(raw).ok())
            .and_then(|value| value.as_object().cloned())
            .unwrap_or_default();
        for (key, value) in power_stats {
            merged.insert(key, value);
        }
        let updated = conn.execute(
            "UPDATE workouts
             SET dynamics_json = ?2, stat_extend_json = ?3
             WHERE id = ?1",
            params![
                id,
                dynamics_json,
                serde_json::Value::Object(merged).to_string()
            ],
        )?;
        if updated == 0 {
            anyhow::bail!("workout not found: {id}");
        }
        Ok(())
    })
}

pub fn workout_set_weather(id: &str, temp_c: Option<f64>, humidity: Option<i64>) -> Result<()> {
    if temp_c.is_none() && humidity.is_none() {
        return Ok(());
    }
    with_conn(|conn| {
        conn.execute(
            "UPDATE workouts
             SET start_temp_c = COALESCE(?2, start_temp_c),
                 start_humidity = COALESCE(?3, start_humidity)
             WHERE id = ?1",
            params![id, temp_c, humidity],
        )?;
        Ok(())
    })
}

/// 找出还缺温度或湿度、且轨迹里有真实坐标的运动，按时间倒序。
pub fn workouts_missing_weather(limit: i64) -> Result<Vec<WorkoutWeatherCandidate>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, start_ms, start_temp_c, start_humidity, track_json
             FROM workouts
             WHERE track_json IS NOT NULL AND track_json != '' AND track_json != '[]'
               AND (start_temp_c IS NULL OR start_humidity IS NULL)
             ORDER BY start_ms DESC
             LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            let id: String = r.get(0)?;
            let start_ms: i64 = r.get(1)?;
            let start_temp_c: Option<f64> = r.get(2)?;
            let start_humidity: Option<i64> = r.get(3)?;
            let track: String = r.get(4)?;
            let point = parse_track(&track)
                .into_iter()
                .find(|(lat, lon, _, _)| lat.abs() > 0.0001 || lon.abs() > 0.0001);
            Ok(point.map(|(lat, lon, _, _)| WorkoutWeatherCandidate {
                id,
                start_ms,
                lat,
                lon,
                start_temp_c,
                start_humidity,
            }))
        })?;
        let mut out = Vec::new();
        for row in rows {
            if let Some(item) = row? {
                out.push(item);
            }
        }
        Ok(out)
    })
}

/// 删除一条运动记录及其力量训练组数明细。
pub fn delete_workout(id: &str) -> Result<()> {
    with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        let identity = tx
            .query_row(
                "SELECT sport, start_ms FROM workouts WHERE id = ?1",
                params![id],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)),
            )
            .optional()?;
        if let Some((sport, start_ms)) = identity {
            let workout_number = id
                .strip_prefix("watch-")
                .and_then(|rest| rest.split('-').next())
                .and_then(|n| n.parse::<i64>().ok());
            tx.execute(
                "INSERT OR REPLACE INTO workout_tombstones(
                    id, sport, start_ms, workout_number, deleted_ms
                 ) VALUES(?1, ?2, ?3, ?4, ?5)",
                params![id, sport, start_ms, workout_number, now_ms()],
            )?;
        }
        tx.execute(
            "DELETE FROM strength_workout_sets WHERE session_id = ?1",
            params![id],
        )?;
        tx.execute("DELETE FROM workouts WHERE id = ?1", params![id])?;
        tx.commit()?;
        Ok(())
    })
}

pub fn add_weight_record(weight_kg: f64, body_fat_percent: f64) -> Result<String> {
    if !(20.0..=300.0).contains(&weight_kg) {
        anyhow::bail!("体重需要在 20–300 kg 之间");
    }
    let ts = now_ms();
    let id = format!("manual-weight-{ts}");
    with_conn(|conn| {
        conn.execute(
            "INSERT INTO weight_records(id, timestamp_ms, weight_kg, body_fat_percent, source)
             VALUES(?1, ?2, ?3, ?4, 'manual')",
            params![
                id,
                ts,
                weight_kg,
                if body_fat_percent > 0.0 {
                    Some(body_fat_percent)
                } else {
                    None
                },
            ],
        )?;
        Ok(())
    })?;
    Ok(id)
}

pub fn add_blood_pressure(systolic: i64, diastolic: i64, pulse: i64) -> Result<String> {
    if !(50..=260).contains(&systolic) || !(30..=180).contains(&diastolic) {
        anyhow::bail!("血压数值超出合理范围");
    }
    let ts = now_ms();
    let id = format!("manual-bp-{ts}");
    with_conn(|conn| {
        conn.execute(
            "INSERT INTO blood_pressure_records(id, timestamp_ms, systolic, diastolic, pulse, source)
             VALUES(?1, ?2, ?3, ?4, ?5, 'manual')",
            params![id, ts, systolic, diastolic, if pulse > 0 { Some(pulse) } else { None }],
        )?;
        Ok(())
    })?;
    Ok(id)
}

pub fn add_blood_glucose(value: f64, measure_type: &str) -> Result<String> {
    if !(1.0..=40.0).contains(&value) {
        anyhow::bail!("血糖数值超出合理范围");
    }
    let ts = now_ms();
    let id = format!("manual-glucose-{ts}");
    let kind = if measure_type.trim().is_empty() {
        "random"
    } else {
        measure_type.trim()
    };
    with_conn(|conn| {
        conn.execute(
            "INSERT INTO blood_glucose_records(id, timestamp_ms, value, measure_type, source)
             VALUES(?1, ?2, ?3, ?4, 'manual')",
            params![id, ts, value, kind],
        )?;
        Ok(())
    })?;
    Ok(id)
}

pub fn update_weight_record(id: &str, weight_kg: f64, body_fat_percent: f64) -> Result<()> {
    if !(20.0..=300.0).contains(&weight_kg) {
        anyhow::bail!("体重需要在 20–300 kg 之间");
    }
    with_conn(|conn| {
        conn.execute(
            "UPDATE weight_records SET weight_kg = ?2, body_fat_percent = ?3 WHERE id = ?1",
            params![
                id,
                weight_kg,
                if body_fat_percent > 0.0 {
                    Some(body_fat_percent)
                } else {
                    None
                },
            ],
        )?;
        Ok(())
    })
}

pub fn health_tombstone_ids(kind: &str) -> Result<HashSet<String>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare("SELECT id FROM health_record_tombstones WHERE kind = ?1")?;
        let rows = stmt.query_map(params![kind], |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<HashSet<_>>>()?)
    })
}

fn remember_health_deletion(conn: &Connection, kind: &str, id: &str) -> Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO health_record_tombstones(kind, id, deleted_ms)
         VALUES(?1, ?2, ?3)",
        params![kind, id, now_ms()],
    )?;
    Ok(())
}

pub fn delete_weight_record(id: &str) -> Result<()> {
    with_conn(|conn| {
        remember_health_deletion(conn, "weight", id)?;
        conn.execute("DELETE FROM weight_records WHERE id = ?1", params![id])?;
        Ok(())
    })
}

pub fn update_blood_pressure(id: &str, systolic: i64, diastolic: i64, pulse: i64) -> Result<()> {
    if !(50..=260).contains(&systolic) || !(30..=180).contains(&diastolic) {
        anyhow::bail!("血压数值超出合理范围");
    }
    with_conn(|conn| {
        conn.execute(
            "UPDATE blood_pressure_records SET systolic = ?2, diastolic = ?3, pulse = ?4 WHERE id = ?1",
            params![id, systolic, diastolic, if pulse > 0 { Some(pulse) } else { None }],
        )?;
        Ok(())
    })
}

pub fn delete_blood_pressure(id: &str) -> Result<()> {
    with_conn(|conn| {
        remember_health_deletion(conn, "bp", id)?;
        conn.execute(
            "DELETE FROM blood_pressure_records WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    })
}

pub fn update_blood_glucose(id: &str, value: f64, measure_type: &str) -> Result<()> {
    if !(1.0..=40.0).contains(&value) {
        anyhow::bail!("血糖数值超出合理范围");
    }
    let kind = if measure_type.trim().is_empty() {
        "random"
    } else {
        measure_type.trim()
    };
    with_conn(|conn| {
        conn.execute(
            "UPDATE blood_glucose_records SET value = ?2, measure_type = ?3 WHERE id = ?1",
            params![id, value, kind],
        )?;
        Ok(())
    })
}

pub fn delete_blood_glucose(id: &str) -> Result<()> {
    with_conn(|conn| {
        remember_health_deletion(conn, "glucose", id)?;
        conn.execute(
            "DELETE FROM blood_glucose_records WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    })
}

pub fn get_profile() -> Result<Profile> {
    with_conn(|conn| {
        let profile = conn
            .query_row(
                "SELECT nickname, gender, height_cm, weight_kg, birth_date, email FROM profile WHERE id = 1",
                [],
                |r| {
                    Ok(Profile {
                        nickname: r.get(0)?,
                        gender: r.get(1)?,
                        height_cm: r.get(2)?,
                        weight_kg: r.get(3)?,
                        birth_date: r.get(4)?,
                        email: r.get(5)?,
                    })
                },
            )
            .optional()?;
        Ok(profile.unwrap_or(Profile {
            nickname: String::new(),
            gender: "male".into(),
            height_cm: 170.0,
            weight_kg: 65.0,
            birth_date: "1990-01-01".into(),
            email: String::new(),
        }))
    })
}

pub fn save_profile(profile: Profile) -> Result<()> {
    with_conn(|conn| {
        conn.execute(
            "INSERT INTO profile(id, nickname, gender, height_cm, weight_kg, birth_date, email)
             VALUES(1, ?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(id) DO UPDATE SET nickname=excluded.nickname, gender=excluded.gender,
               height_cm=excluded.height_cm, weight_kg=excluded.weight_kg,
               birth_date=excluded.birth_date, email=excluded.email",
            params![
                profile.nickname,
                profile.gender,
                profile.height_cm,
                profile.weight_kg,
                profile.birth_date,
                profile.email
            ],
        )?;
        Ok(())
    })
}

pub fn devices() -> Result<Vec<DeviceInfo>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, name, kind, address, battery, last_sync_ms, connected FROM devices
             ORDER BY connected DESC, last_sync_ms DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(DeviceInfo {
                id: r.get(0)?,
                name: r.get(1)?,
                kind: r.get(2)?,
                address: r.get(3)?,
                battery: r.get(4)?,
                last_sync_ms: r.get(5)?,
                connected: r.get::<_, i64>(6)? != 0,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

/// 手表连接与同步日志，最新在前。表由 watch.rs 的 ingest 写入，原生层给什么存什么。
pub fn watch_logs(limit: i64) -> Result<Vec<WatchLog>> {
    with_conn(|conn| {
        let mut stmt =
            conn.prepare("SELECT ts_ms, msg FROM watch_logs ORDER BY ts_ms DESC LIMIT ?1")?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(WatchLog {
                ts_ms: r.get(0)?,
                msg: r.get(1)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

pub fn weights(limit: i64) -> Result<Vec<WeightEntry>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, timestamp_ms, weight_kg, body_fat_percent, muscle_percent, water_percent, source,
                    height_cm, bmi, fat_mass_kg, muscle_mass_kg, water_mass_kg, protein_percent,
                    protein_mass_kg, bone_percent, bone_mass_kg, skeletal_muscle_percent,
                    skeletal_muscle_mass_kg, subcutaneous_fat_percent, subcutaneous_fat_mass_kg,
                    resistance_ohm, body_composition_model, device_name
             FROM weight_records ORDER BY timestamp_ms DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(WeightEntry {
                id: r.get(0)?,
                timestamp_ms: r.get(1)?,
                weight_kg: r.get(2)?,
                body_fat_percent: r.get(3)?,
                muscle_percent: r.get(4)?,
                water_percent: r.get(5)?,
                source: r.get(6)?,
                height_cm: r.get(7)?,
                bmi: r.get(8)?,
                fat_mass_kg: r.get(9)?,
                muscle_mass_kg: r.get(10)?,
                water_mass_kg: r.get(11)?,
                protein_percent: r.get(12)?,
                protein_mass_kg: r.get(13)?,
                bone_percent: r.get(14)?,
                bone_mass_kg: r.get(15)?,
                skeletal_muscle_percent: r.get(16)?,
                skeletal_muscle_mass_kg: r.get(17)?,
                subcutaneous_fat_percent: r.get(18)?,
                subcutaneous_fat_mass_kg: r.get(19)?,
                resistance_ohm: r.get(20)?,
                body_composition_model: r.get(21)?,
                device_name: r.get(22)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

pub fn settings_get(key: &str, fallback: &str) -> Result<String> {
    with_conn(|conn| Ok(setting_string(conn, key, fallback)))
}

/// 装备清单只存「启用时的起始里程和建议更换里程」；已用里程不单独记账，
/// 由同类型运动的历史累计距离减去起始里程推出来，改起始里程时已用里程会跟着变，
/// 不会出现两套各说一套的数字。
pub fn equipment_list() -> Result<Vec<Equipment>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, name, sport, gear_type, brand, model, purchase_ms, is_active,
                    start_km, limit_km, note FROM equipment
             ORDER BY created_ms DESC, id DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(Equipment {
                id: r.get(0)?,
                name: r.get(1)?,
                sport: r.get(2)?,
                gear_type: r.get(3)?,
                brand: r.get(4)?,
                model: r.get(5)?,
                purchase_ms: r.get(6)?,
                is_active: r.get::<_, i64>(7)? != 0,
                start_km: r.get(8)?,
                limit_km: r.get(9)?,
                note: r.get(10)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

fn validate_equipment(name: &str, start_km: f64, limit_km: f64) -> Result<String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err(anyhow!("装备名称不能为空"));
    }
    if !(0.0..=100_000.0).contains(&start_km) {
        return Err(anyhow!("起始里程不能是负数"));
    }
    if !(1.0..=100_000.0).contains(&limit_km) {
        return Err(anyhow!("建议更换里程要在 1 到 100000 公里之间"));
    }
    Ok(trimmed.to_string())
}

pub fn equipment_add(
    name: &str,
    sport: &str,
    gear_type: &str,
    brand: &str,
    model: &str,
    purchase_ms: i64,
    is_active: bool,
    start_km: f64,
    limit_km: f64,
    note: &str,
) -> Result<i64> {
    let name = validate_equipment(name, start_km, limit_km)?;
    with_conn(|conn| {
        conn.execute(
            "INSERT INTO equipment(name, sport, gear_type, brand, model, purchase_ms, is_active,
                                   start_km, limit_km, note, created_ms)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![
                name,
                sport,
                gear_type,
                brand.trim(),
                model.trim(),
                purchase_ms,
                is_active as i64,
                start_km,
                limit_km,
                note.trim(),
                now_ms()
            ],
        )?;
        Ok(conn.last_insert_rowid())
    })
}

pub fn equipment_update(
    id: i64,
    name: &str,
    sport: &str,
    gear_type: &str,
    brand: &str,
    model: &str,
    purchase_ms: i64,
    is_active: bool,
    start_km: f64,
    limit_km: f64,
    note: &str,
) -> Result<()> {
    let name = validate_equipment(name, start_km, limit_km)?;
    with_conn(|conn| {
        conn.execute(
            "UPDATE equipment SET name = ?2, sport = ?3, gear_type = ?4, brand = ?5, model = ?6,
                    purchase_ms = ?7, is_active = ?8, start_km = ?9, limit_km = ?10, note = ?11
             WHERE id = ?1",
            params![
                id,
                name,
                sport,
                gear_type,
                brand.trim(),
                model.trim(),
                purchase_ms,
                is_active as i64,
                start_km,
                limit_km,
                note.trim()
            ],
        )?;
        Ok(())
    })
}

pub fn equipment_delete(id: i64) -> Result<()> {
    with_conn(|conn| {
        conn.execute("DELETE FROM equipment WHERE id = ?1", params![id])?;
        Ok(())
    })
}

fn median(values: &mut Vec<f64>) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mid = values.len() / 2;
    Some(if values.len() % 2 == 0 {
        (values[mid - 1] + values[mid]) / 2.0
    } else {
        values[mid]
    })
}

fn daily_column_series(conn: &Connection, column: &str, days: i64) -> Result<Vec<DailyPoint>> {
    let today = today_epoch_day();
    let mut stmt = conn.prepare(&format!(
        "SELECT date_day, {column} FROM daily_metrics WHERE date_day >= ?1 ORDER BY date_day"
    ))?;
    let rows = stmt.query_map(params![today - days.max(1) + 1], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, Option<f64>>(1)?))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (d, v) = row?;
        if let Some(v) = v {
            out.push(DailyPoint {
                date_epoch_day: d,
                value: v,
            });
        }
    }
    Ok(out)
}

fn point_series(conn: &Connection, metric: &str, days: i64) -> Result<Vec<DailyPoint>> {
    let today = today_epoch_day();
    let from = day_start_ms(today - days.max(1) + 1);
    let mut stmt = conn.prepare(
        "SELECT (ts_ms / 86400000), AVG(value) FROM metric_points
         WHERE metric = ?1 AND ts_ms >= ?2 GROUP BY (ts_ms / 86400000) ORDER BY 1",
    )?;
    let rows = stmt.query_map(params![metric, from], |r| {
        Ok(DailyPoint {
            date_epoch_day: r.get(0)?,
            value: r.get(1)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// 运动时长（分钟）：手表锻炼环 `daily_rings.duration_user_min` 是权威来源；
/// 三环缺失或为 0 时退回当天本机运动记录的总时长。两者都没有 ⇒ None（图表上不画点）。
///
/// `workouts.total_time_sec` 是 `NOT NULL DEFAULT 0`，所以不能直接 COALESCE，
/// 得判 >0，否则没填时长的运动记录会按 0 算、把当天的量抹平。
fn exercise_minutes_opt(conn: &Connection, day: i64) -> Result<Option<i64>> {
    let ring: Option<i64> = conn
        .query_row(
            "SELECT duration_user_min FROM daily_rings WHERE date_day = ?1",
            params![day],
            |r| r.get::<_, i64>(0),
        )
        .optional()?
        .filter(|v| *v > 0);
    let (workouts, recorded_min): (i64, i64) = conn.query_row(
        "SELECT COUNT(*),
                COALESCE(SUM(CASE WHEN total_time_sec > 0 THEN total_time_sec
                                  ELSE MAX(COALESCE(end_ms, start_ms) - start_ms, 0) / 1000 END), 0) / 60
         FROM workouts WHERE start_ms >= ?1 AND start_ms < ?2",
        params![day_start_ms(day), day_end_ms(day)],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let recorded = (workouts > 0).then_some(recorded_min);
    Ok(match (ring, recorded) {
        (Some(ring_min), Some(recorded_min)) => Some(ring_min.max(recorded_min)),
        (Some(v), None) | (None, Some(v)) => Some(v),
        (None, None) => None,
    })
}

fn exercise_minutes(conn: &Connection, day: i64) -> Result<i64> {
    Ok(exercise_minutes_opt(conn, day)?.unwrap_or(0))
}

fn exercise_minute_series(conn: &Connection, days: i64) -> Result<Vec<DailyPoint>> {
    let today = today_epoch_day();
    let mut out = Vec::new();
    for day in (today - days.max(1) + 1)..=today {
        if let Some(value) = exercise_minutes_opt(conn, day)? {
            out.push(DailyPoint {
                date_epoch_day: day,
                value: value as f64,
            });
        }
    }
    Ok(out)
}

pub fn metric_detail(metric: &str, days: i64) -> Result<MetricDetail> {
    with_conn(|conn| {
        let today = today_epoch_day();
        let device = setting_string(conn, "device_name", "HUAWEI WATCH GT 5");
        let (label, unit, description) = match metric {
            "steps" => ("步数", "步", "手表与手机分别计步，合并后按天汇总；目标可在运动目标中调整。"),
            "calories" => ("总消耗", "kcal", "包含基础代谢与活动消耗，由手表的日均代谢估算。"),
            "active_calories" => ("活动热量", "kcal", "仅统计走路、跑步与训练产生的额外消耗。"),
            "distance" => ("距离", "km", "日常步行的等效距离，不含骑行等非步行运动。"),
            "active_minutes" => ("活动时长", "分钟", "中高强度活动累计分钟数，手表每小时结算一次。"),
            "exercise_minutes" => ("运动时长", "分钟", "手表锻炼环累计的运动时长；三环还没同步上时，按本机运动记录的总时长计算。"),
            "resting_hr" => ("静息心率", "bpm", "睡眠期间的最低稳定心率，反映恢复水平。"),
            "hrv" => ("HRV", "ms", "心率变异性（RMSSD），越高说明自主神经恢复越好。"),
            "sleep" => ("睡眠时长", "分钟", "深睡 + 浅睡 + REM 的总时长，不含清醒时间。"),
            "deep_sleep" => ("深睡", "分钟", "深度睡眠占比通常应在 15%–25% 之间。"),
            "stress" => ("压力", "", "由心率变异性推导的压力分值，0–100，越低越放松。"),
            "spo2" => ("血氧", "%", "夜间与白天自动测量，正常范围 95%–100%。"),
            "skin_temp" | "temperature" => ("腕温", "°C", "腕部皮肤温度，用于观察相对基线的变化。"),
            "body_temp" => ("体温", "°C", "核心体温估算，单次测量或夜间连续监测。"),
            "respiration" => ("呼吸频率", "次/分", "睡眠期间的平均呼吸次数。"),
            "weight" => ("体重", "kg", "蓝牙体脂秤或手动记录；同一条记录包含体成分。"),
            "bp" => ("血压", "mmHg", "手动录入或蓝牙血压计同步的收缩压/舒张压。"),
            "glucose" => ("血糖", "mmol/L", "手动或血糖仪录入，支持空腹/餐后等测量类型。"),
            "heart_rate" => ("心率", "bpm", "白天自动测量与运动期间的高频采样。"),
            "emotion" => ("情绪", "", "手表按愉悦度与激活度给出三档：紧张（低愉悦·高兴奋）、一般、平静（高愉悦·低兴奋），每天取最后一次检测。"),
            "vo2max" => ("最大摄氧量", "ml/kg/min", "手表在跑步类运动结束后估算的最大摄氧量，反映有氧耐力；数值越高，同样配速下心肺负担越小。"),
            _ => return Err(anyhow!("unknown metric {metric}")),
        };
        let mut series: Vec<DailyPoint> = match metric {
            "steps" => daily_column_series(conn, "steps", days)?,
            "calories" => daily_column_series(conn, "calories", days)?,
            "active_calories" => daily_column_series(conn, "active_calories", days)?,
            "distance" => daily_column_series(conn, "distance_m", days)?
                .into_iter()
                .map(|p| DailyPoint {
                    date_epoch_day: p.date_epoch_day,
                    value: p.value / 1000.0,
                })
                .collect(),
            "active_minutes" => daily_column_series(conn, "active_minutes", days)?,
            "exercise_minutes" => exercise_minute_series(conn, days)?,
            "resting_hr" => daily_column_series(conn, "resting_hr", days)?,
            "hrv" => daily_column_series(conn, "hrv_ms", days)?,
            "sleep" => daily_column_series(conn, "sleep_minutes", days)?,
            "deep_sleep" => daily_column_series(conn, "deep_sleep_minutes", days)?,
            "stress" => daily_column_series(conn, "stress", days)?,
            "spo2" => daily_column_series(conn, "spo2", days)?,
            "skin_temp" | "temperature" => daily_column_series(conn, "skin_temp_c", days)?,
            "body_temp" => {
                let mut points = point_series(conn, "body_temp", days)?;
                points.retain(|p| (34.0..=42.0).contains(&p.value));
                if points.is_empty() {
                    points = daily_column_series(conn, "body_temp_c", days)?;
                    points.retain(|p| (34.0..=42.0).contains(&p.value));
                }
                points
            }
            "respiration" => point_series(conn, "respiration", days)?,
            "weight" => {
                let mut stmt = conn.prepare(
                    "SELECT timestamp_ms, weight_kg FROM weight_records
                     WHERE timestamp_ms >= ?1 ORDER BY timestamp_ms",
                )?;
                let rows = stmt.query_map(params![day_start_ms(today - days.max(1) + 1)], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?))
                })?;
                let mut last = std::collections::BTreeMap::new();
                for row in rows {
                    let (ts_ms, value) = row?;
                    last.insert(local_epoch_day(ts_ms), value);
                }
                last.into_iter()
                    .map(|(date_epoch_day, value)| DailyPoint {
                        date_epoch_day,
                        value,
                    })
                    .collect()
            }
            "bp" => {
                let mut stmt = conn.prepare(
                    "SELECT timestamp_ms, systolic FROM blood_pressure_records
                     WHERE timestamp_ms >= ?1 ORDER BY timestamp_ms",
                )?;
                let rows = stmt.query_map(params![day_start_ms(today - days.max(1) + 1)], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?))
                })?;
                let mut last = std::collections::BTreeMap::new();
                for row in rows {
                    let (ts_ms, value) = row?;
                    last.insert(local_epoch_day(ts_ms), value);
                }
                last.into_iter()
                    .map(|(date_epoch_day, value)| DailyPoint {
                        date_epoch_day,
                        value,
                    })
                    .collect()
            }
            "glucose" => {
                let mut stmt = conn.prepare(
                    "SELECT timestamp_ms, value FROM blood_glucose_records
                     WHERE timestamp_ms >= ?1 ORDER BY timestamp_ms",
                )?;
                let rows = stmt.query_map(params![day_start_ms(today - days.max(1) + 1)], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?))
                })?;
                let mut last = std::collections::BTreeMap::new();
                for row in rows {
                    let (ts_ms, value) = row?;
                    last.insert(local_epoch_day(ts_ms), value);
                }
                last.into_iter()
                    .map(|(date_epoch_day, value)| DailyPoint {
                        date_epoch_day,
                        value,
                    })
                    .collect()
            }
            "emotion" => {
                let mut stmt = conn.prepare(
                    "SELECT ts_ms, status FROM emotion_records
                     WHERE ts_ms >= ?1 ORDER BY ts_ms",
                )?;
                let rows = stmt.query_map(params![day_start_ms(today - days.max(1) + 1)], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)? as f64))
                })?;
                // 情绪是分类编码（1 紧张 / 2 一般 / 3 平静），取均值会得到一个根本没出现过的状态；
                // 首页卡片用的是当日最后一次检测，这里也必须跟着取最后一次，否则两处会各说一套。
                let mut last: std::collections::BTreeMap<i64, f64> =
                    std::collections::BTreeMap::new();
                for row in rows {
                    let (ts_ms, status) = row?;
                    last.insert(local_epoch_day(ts_ms), status);
                }
                last.into_iter()
                    .map(|(date_epoch_day, value)| DailyPoint {
                        date_epoch_day,
                        value,
                    })
                    .collect()
            }
            "vo2max" => {
                let mut stmt = conn.prepare(
                    "SELECT start_ms, vo2max FROM workouts
                     WHERE vo2max IS NOT NULL AND vo2max > 0 AND start_ms >= ?1 ORDER BY start_ms",
                )?;
                let rows = stmt.query_map(params![day_start_ms(today - days.max(1) + 1)], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?))
                })?;
                let mut last = std::collections::BTreeMap::new();
                for row in rows {
                    let (ts_ms, value) = row?;
                    last.insert(local_epoch_day(ts_ms), value);
                }
                last.into_iter()
                    .map(|(date_epoch_day, value)| DailyPoint {
                        date_epoch_day,
                        value,
                    })
                    .collect()
            }
            "heart_rate" => {
                let from = day_start_ms(today - days.max(1) + 1);
                let mut stmt = conn.prepare(
                    "SELECT ts_ms, bpm FROM heart_rate_points WHERE ts_ms >= ?1 AND bpm > 0 ORDER BY ts_ms",
                )?;
                let rows = stmt.query_map(params![from], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?))
                })?;
                let mut sums: std::collections::BTreeMap<i64, (f64, i64)> =
                    std::collections::BTreeMap::new();
                for row in rows {
                    let (ts_ms, bpm) = row?;
                    let entry = sums.entry(local_epoch_day(ts_ms)).or_insert((0.0, 0));
                    entry.0 += bpm;
                    entry.1 += 1;
                }
                sums.into_iter()
                    .map(|(date_epoch_day, (sum, count))| DailyPoint {
                        date_epoch_day,
                        value: sum / count.max(1) as f64,
                    })
                    .collect()
            }
            _ => Vec::new(),
        };
        series.sort_by_key(|p| p.date_epoch_day);

        let mut samples: Vec<MetricSample> = Vec::new();
        let since = now_ms() - 36 * 3_600_000;
        match metric {
            "heart_rate" => {
                let mut stmt = conn.prepare(
                    "SELECT ts_ms, bpm FROM heart_rate_points WHERE ts_ms >= ?1 AND bpm > 0
                     ORDER BY ts_ms",
                )?;
                let rows = stmt.query_map(params![since], |r| {
                    Ok(MetricSample {
                        timestamp_ms: r.get(0)?,
                        value: r.get::<_, i64>(1)? as f64,
                    })
                })?;
                samples = rows.collect::<rusqlite::Result<Vec<_>>>()?;
            }
            "resting_hr" | "hrv" | "stress" | "spo2" | "skin_temp" | "temperature"
            | "body_temp" | "respiration" => {
                let key = if metric == "temperature" {
                    "skin_temp"
                } else {
                    metric
                };
                let mut stmt = conn.prepare(
                    "SELECT ts_ms, value FROM metric_points WHERE metric = ?1 AND ts_ms >= ?2
                     ORDER BY ts_ms",
                )?;
                let rows = stmt.query_map(params![key, day_start_ms(today)], |r| {
                    Ok(MetricSample {
                        timestamp_ms: r.get(0)?,
                        value: r.get(1)?,
                    })
                })?;
                samples = rows.collect::<rusqlite::Result<Vec<_>>>()?;
                if metric == "body_temp" {
                    samples.retain(|s| (34.0..=42.0).contains(&s.value));
                }
            }
            "emotion" => {
                let mut stmt = conn.prepare(
                    "SELECT ts_ms, status FROM emotion_records WHERE ts_ms >= ?1 ORDER BY ts_ms",
                )?;
                let rows = stmt.query_map(params![day_start_ms(today)], |r| {
                    Ok(MetricSample {
                        timestamp_ms: r.get(0)?,
                        value: r.get::<_, i64>(1)? as f64,
                    })
                })?;
                samples = rows.collect::<rusqlite::Result<Vec<_>>>()?;
            }
            "bp" => {
                let mut stmt = conn.prepare(
                    "SELECT timestamp_ms, systolic FROM blood_pressure_records ORDER BY timestamp_ms DESC LIMIT 30",
                )?;
                let rows = stmt.query_map([], |r| {
                    Ok(MetricSample {
                        timestamp_ms: r.get(0)?,
                        value: r.get::<_, i64>(1)? as f64,
                    })
                })?;
                samples = rows.collect::<rusqlite::Result<Vec<_>>>()?;
                samples.reverse();
            }
            "glucose" => {
                let mut stmt = conn.prepare(
                    "SELECT timestamp_ms, value FROM blood_glucose_records ORDER BY timestamp_ms DESC LIMIT 30",
                )?;
                let rows = stmt.query_map([], |r| {
                    Ok(MetricSample {
                        timestamp_ms: r.get(0)?,
                        value: r.get(1)?,
                    })
                })?;
                samples = rows.collect::<rusqlite::Result<Vec<_>>>()?;
                samples.reverse();
            }
            // 估算值按次产生，不是每天一个：窗口里没有时，用最近一次估算说明「不是没数据，是这个窗口没有」。
            // 图表按自然月汇总，取满一年才能看出训练效果。
            "vo2max" => {
                let mut stmt = conn.prepare(
                    "SELECT start_ms, vo2max FROM workouts
                     WHERE vo2max IS NOT NULL AND vo2max > 0 AND start_ms >= ?1 ORDER BY start_ms",
                )?;
                let rows = stmt.query_map(params![day_start_ms(today - 364)], |r| {
                    Ok(MetricSample {
                        timestamp_ms: r.get(0)?,
                        value: r.get::<_, f64>(1)?,
                    })
                })?;
                samples = rows.collect::<rusqlite::Result<Vec<_>>>()?;
            }
            _ => {}
        }
        // 首页心率卡显示「最新一次采样」，详情页大数字必须用同一条数据；
        // 日均值只用于趋势图。先记下抽稀前的最新采样，避免两处差出十几 bpm。
        let latest_sample = samples.last().map(|s| (s.timestamp_ms, s.value));
        // 36 小时窗口按 1 分钟一个点算是 2160 点，上限给到这个数就不再抽稀，
        // 手表分钟级心率能原样画出；更多（高频运动采样）才按步长压回 ~2160 点。
        if samples.len() > 2160 {
            let step = samples.len() / 2160 + 1;
            samples = samples.into_iter().step_by(step).collect();
        }

        let latest = if metric == "heart_rate" {
            latest_sample.map(|(_, value)| value)
        } else {
            series.last().map(|p| p.value)
        };
        let mut values: Vec<f64> = series.iter().map(|p| p.value).collect();
        let average = if values.is_empty() {
            None
        } else {
            Some(values.iter().sum::<f64>() / values.len() as f64)
        };
        let minimum = values.iter().cloned().fold(None, |acc: Option<f64>, v| {
            Some(acc.map_or(v, |a| a.min(v)))
        });
        let maximum = values.iter().cloned().fold(None, |acc: Option<f64>, v| {
            Some(acc.map_or(v, |a| a.max(v)))
        });
        let mut previous: Vec<f64> = values.iter().rev().skip(1).take(7).cloned().collect();
        let baseline = median(&mut previous);
        let trend = match (latest, baseline) {
            (Some(l), Some(b)) => Some(l - b),
            _ => None,
        };
        values.clear();
        let goal = match metric {
            "steps" => Some(setting_i64(conn, "goal_steps", 10_000) as f64),
            "calories" => Some(setting_i64(conn, "goal_calories", 500) as f64),
            "active_minutes" => Some(setting_i64(conn, "goal_active_minutes", 60) as f64),
            "exercise_minutes" => Some(setting_i64(conn, "goal_exercise_minutes", 30) as f64),
            _ => None,
        };
        let updated_ms = latest_sample.map(|(ts_ms, _)| ts_ms).or_else(|| {
            series
                .last()
                .map(|p| day_start_ms(p.date_epoch_day) + 6 * 3_600_000)
        });
        Ok(MetricDetail {
            metric: metric.to_string(),
            label: label.to_string(),
            unit: unit.to_string(),
            description: description.to_string(),
            source: device,
            days: series.clone(),
            samples,
            latest,
            average,
            minimum,
            maximum,
            baseline,
            trend,
            goal,
            has_data: !series.is_empty(),
            updated_ms,
        })
    })
}

#[derive(Clone)]
struct PersonalRecordWorkout {
    id: String,
    group: String,
    start_ms: i64,
    distance_m: f64,
    duration_sec: i64,
    calories: i64,
    load: i64,
    max_hr: i64,
    elevation_gain: f64,
    splits: Vec<(i64, i64)>,
}

struct PersonalRecordCandidate {
    metric: &'static str,
    label: &'static str,
    value: f64,
    unit: &'static str,
    higher_is_better: bool,
    workout_id: String,
    achieved_ms: i64,
}

pub(crate) fn personal_record_group(sport: &str) -> String {
    match sport {
        "running" | "treadmill" | "trail_running" | "户外跑步" | "跑步" | "室内跑步" => {
            "running"
        }
        "cycling" | "indoor_cycling" | "spinning" | "骑行" => "cycling",
        "walking" | "hiking" | "climbing" | "健走" | "徒步" | "登山" => "hiking",
        "swimming" | "游泳" => "swimming",
        "力量训练" => "strength",
        other => other,
    }
    .to_string()
}

/// 旧版 `sport_personal_records.metric` 到新版个人纪录字段的映射。
/// 返回 `(metric, 文案, 单位, 越高越好, 数值缩放)`；旧版距离以米存储，
/// 新版统一按公里展示，其余字段量纲一致。
pub(crate) fn legacy_personal_record_meta(
    metric: &str,
) -> Option<(&'static str, &'static str, &'static str, bool, f64)> {
    match metric {
        "LONGEST_DISTANCE" => Some(("longest", "最远距离", "km", true, 0.001)),
        "LONGEST_DURATION" => Some(("duration", "最长时间", "秒", true, 1.0)),
        "BEST_AVG_PACE" => Some(("pace", "最佳平均配速", "秒/公里", false, 1.0)),
        "FASTEST_KM_PACE" => Some(("fastest_km", "单公里最快", "秒/公里", false, 1.0)),
        "BEST_5KM_TIME" => Some(("5k", "5 公里最好成绩", "秒", false, 1.0)),
        "BEST_10KM_TIME" => Some(("10k", "10 公里最好成绩", "秒", false, 1.0)),
        "BEST_HALF_MARATHON_TIME" => Some(("half", "半马最好成绩", "秒", false, 1.0)),
        "MAX_CALORIES" => Some(("calories", "单场最高消耗", "kcal", true, 1.0)),
        "MAX_ELEVATION_GAIN" => Some(("elevation", "最大累计爬升", "米", true, 1.0)),
        "MAX_HEART_RATE" => Some(("max_hr", "最高心率", "bpm", true, 1.0)),
        // 已经落库的 `legacy_personal_records` 存的是新版字段名。
        "longest" => Some(("longest", "最远距离", "km", true, 1.0)),
        "duration" => Some(("duration", "最长时间", "秒", true, 1.0)),
        "pace" => Some(("pace", "最佳平均配速", "秒/公里", false, 1.0)),
        "fastest_km" => Some(("fastest_km", "单公里最快", "秒/公里", false, 1.0)),
        "5k" => Some(("5k", "5 公里最好成绩", "秒", false, 1.0)),
        "10k" => Some(("10k", "10 公里最好成绩", "秒", false, 1.0)),
        "half" => Some(("half", "半马最好成绩", "秒", false, 1.0)),
        "full" => Some(("full", "全马最好成绩", "秒", false, 1.0)),
        "calories" => Some(("calories", "单场最高消耗", "kcal", true, 1.0)),
        "elevation" => Some(("elevation", "最大累计爬升", "米", true, 1.0)),
        "max_hr" => Some(("max_hr", "最高心率", "bpm", true, 1.0)),
        "load" => Some(("load", "最高训练负荷", "负荷", true, 1.0)),
        _ => None,
    }
}

fn personal_record_group_rank(group: &str) -> u8 {
    match group {
        "running" => 0,
        "cycling" => 1,
        "hiking" => 2,
        "swimming" => 3,
        _ => 4,
    }
}

fn personal_record_pace_floor(group: &str) -> f64 {
    match group {
        "running" => 240.0,
        "cycling" => 72.0,
        _ => 300.0,
    }
}

fn personal_record_splits(raw: Option<&str>) -> Vec<(i64, i64)> {
    let Some(raw) = raw else {
        return Vec::new();
    };
    let Ok(serde_json::Value::Array(items)) = serde_json::from_str::<serde_json::Value>(raw) else {
        return Vec::new();
    };
    let mut splits = Vec::new();
    for item in items {
        if item.get("type").and_then(|v| v.as_i64()) != Some(0) {
            continue;
        }
        // corr 有值的是最后不足 1 公里的尾段，不能参与 5K/10K 窗口。
        if item.get("corr").and_then(|v| v.as_i64()).unwrap_or(0) > 0 {
            continue;
        }
        let pace = item.get("pace").and_then(|v| v.as_i64()).unwrap_or(0);
        if !(90..=1800).contains(&pace) {
            continue;
        }
        let index = item
            .get("d")
            .and_then(|v| v.as_i64())
            .or_else(|| item.get("i").and_then(|v| v.as_i64()))
            .unwrap_or(0);
        splits.push((index, pace));
    }
    splits.sort_by_key(|s| s.0);
    splits.dedup_by_key(|s| s.0);
    splits
}

fn personal_record_window(splits: &[(i64, i64)], km: usize) -> Option<i64> {
    if splits.len() < km {
        return None;
    }
    let mut best = None;
    for window in splits.windows(km) {
        if window.last()?.0 - window.first()?.0 == km as i64 - 1 {
            let total: i64 = window.iter().map(|s| s.1).sum();
            best = Some(best.map_or(total, |current: i64| current.min(total)));
        }
    }
    best
}

fn merge_personal_record(
    best: &mut HashMap<&'static str, PersonalRecordCandidate>,
    candidate: PersonalRecordCandidate,
) {
    match best.get(candidate.metric) {
        Some(current)
            if if current.higher_is_better {
                current.value >= candidate.value
            } else {
                current.value <= candidate.value
            } => {}
        _ => {
            best.insert(candidate.metric, candidate);
        }
    }
}

fn running_race_window(distance_m: f64) -> Option<(&'static str, &'static str)> {
    match distance_m {
        d if (4950.0..=5450.0).contains(&d) => Some(("5k", "5 公里最好成绩")),
        d if (9900.0..=10500.0).contains(&d) => Some(("10k", "10 公里最好成绩")),
        d if (20900.0..=21600.0).contains(&d) => Some(("half", "半马最好成绩")),
        d if (41800.0..=42800.0).contains(&d) => Some(("full", "全马最好成绩")),
        _ => None,
    }
}

/// 旧版静态纪录只作为「历史最佳」参与合并：新版能从运动明细算出的更好成绩
/// 仍然胜出；旧版独有的 5K/10K/半马成绩则补进来。
fn merge_legacy_personal_records(
    conn: &Connection,
    group: &str,
    best: &mut HashMap<&'static str, PersonalRecordCandidate>,
) -> Result<()> {
    let mut stmt = conn.prepare(
        "SELECT metric, value, achieved_ms, workout_id
         FROM legacy_personal_records WHERE sport = ?1",
    )?;
    let rows = stmt.query_map(params![group], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, f64>(1)?,
            r.get::<_, i64>(2)?,
            r.get::<_, String>(3)?,
        ))
    })?;
    for row in rows {
        let (metric, value, achieved_ms, workout_id) = row?;
        let Some((key, label, unit, higher_is_better, _)) = legacy_personal_record_meta(&metric)
        else {
            continue;
        };
        if !value.is_finite() || value <= 0.0 || achieved_ms <= 0 {
            continue;
        }
        merge_personal_record(
            best,
            PersonalRecordCandidate {
                metric: key,
                label,
                value,
                unit,
                higher_is_better,
                workout_id,
                achieved_ms,
            },
        );
    }
    Ok(())
}

pub fn personal_records() -> Result<Vec<PersonalRecord>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, sport, start_ms, distance_m,
                    COALESCE(NULLIF(total_time_sec, 0), (end_ms - start_ms) / 1000) AS duration_sec,
                    CASE WHEN active_calories > 0 THEN active_calories ELSE calories END AS calories,
                    load, max_hr, COALESCE(elevation_gain, 0), splits_json
             FROM workouts
             ORDER BY start_ms DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(PersonalRecordWorkout {
                id: r.get(0)?,
                group: personal_record_group(&r.get::<_, String>(1)?),
                start_ms: r.get(2)?,
                distance_m: r.get(3)?,
                duration_sec: r.get(4)?,
                calories: r.get(5)?,
                load: r.get(6)?,
                max_hr: r.get(7)?,
                elevation_gain: r.get(8)?,
                splits: personal_record_splits(r.get::<_, Option<String>>(9)?.as_deref()),
            })
        })?;
        let mut by_group: HashMap<String, Vec<PersonalRecordWorkout>> = HashMap::new();
        for row in rows {
            let workout = row?;
            by_group
                .entry(workout.group.clone())
                .or_default()
                .push(workout);
        }
        // 旧版可能记着新版完全没有运动记录的项目的个人纪录（例如游泳）。
        // 这些分组也要参与输出，否则纪录表里有值却永远显示不出来。
        {
            let mut stmt = conn.prepare("SELECT DISTINCT sport FROM legacy_personal_records")?;
            let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
            for group in rows.flatten() {
                by_group.entry(group).or_default();
            }
        }
        let mut group_names: Vec<String> = by_group.keys().cloned().collect();
        group_names.sort_by(|a, b| {
            personal_record_group_rank(a)
                .cmp(&personal_record_group_rank(b))
                .then_with(|| a.cmp(b))
        });

        let metric_order = [
            "longest",
            "duration",
            "pace",
            "fastest_km",
            "5k",
            "10k",
            "half",
            "full",
            "calories",
            "elevation",
            "max_hr",
            "load",
        ];
        let mut out = Vec::new();
        for group in group_names {
            let workouts = &by_group[&group];
            let mut best: HashMap<&'static str, PersonalRecordCandidate> = HashMap::new();
            for w in workouts {
                let mut candidate = |metric, label, value, unit, higher_is_better| {
                    merge_personal_record(
                        &mut best,
                        PersonalRecordCandidate {
                            metric,
                            label,
                            value,
                            unit,
                            higher_is_better,
                            workout_id: w.id.clone(),
                            achieved_ms: w.start_ms,
                        },
                    );
                };
                if w.distance_m > 0.0 {
                    candidate("longest", "最远距离", w.distance_m / 1000.0, "km", true);
                }
                if w.duration_sec > 0 {
                    candidate("duration", "最长时间", w.duration_sec as f64, "秒", true);
                }
                if w.distance_m > 0.0 && w.duration_sec > 0 {
                    let pace = w.duration_sec as f64 * 1000.0 / w.distance_m;
                    if pace >= personal_record_pace_floor(&group) {
                        candidate("pace", "最佳平均配速", pace, "秒/公里", false);
                        if group == "running" {
                            if let Some((metric, label)) = running_race_window(w.distance_m) {
                                candidate(metric, label, w.duration_sec as f64, "秒", false);
                            }
                        }
                    }
                }
                if w.calories > 0 {
                    candidate("calories", "单场最高消耗", w.calories as f64, "kcal", true);
                }
                if w.elevation_gain > 0.0 {
                    candidate("elevation", "最大累计爬升", w.elevation_gain, "米", true);
                }
                if w.max_hr > 0 {
                    candidate("max_hr", "最高心率", w.max_hr as f64, "bpm", true);
                }
                if w.load > 0 {
                    candidate("load", "最高训练负荷", w.load as f64, "负荷", true);
                }
                if group == "running" && !w.splits.is_empty() {
                    if let Some(pace) = w.splits.iter().map(|s| s.1).min() {
                        candidate("fastest_km", "单公里最快", pace as f64, "秒/公里", false);
                    }
                    for (km, metric, label) in [
                        (5, "5k", "5 公里最好成绩"),
                        (10, "10k", "10 公里最好成绩"),
                        (21, "half", "半马最好成绩"),
                        (42, "full", "全马最好成绩"),
                    ] {
                        if let Some(seconds) = personal_record_window(&w.splits, km) {
                            candidate(metric, label, seconds as f64, "秒", false);
                        }
                    }
                }
            }
            merge_legacy_personal_records(conn, &group, &mut best)?;
            for metric in metric_order {
                if let Some(record) = best.remove(metric) {
                    out.push(PersonalRecord {
                        sport: group.clone(),
                        metric: record.metric.into(),
                        label: record.label.into(),
                        value: record.value,
                        unit: record.unit.into(),
                        workout_id: record.workout_id,
                        achieved_ms: record.achieved_ms,
                    });
                }
            }
        }
        Ok(out)
    })
}

pub fn watch_identity() -> Result<WatchIdentity> {
    with_conn(|conn| {
        let fallback_device = conn
            .query_row("SELECT name, address FROM devices ORDER BY connected DESC, last_sync_ms DESC LIMIT 1", [], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })
            .optional()?;
        let (name, address) =
            fallback_device.unwrap_or_else(|| ("HUAWEI WATCH GT 5".into(), String::new()));
        let migrated = !setting_string(conn, "watch_auth_key", "").is_empty();
        Ok(WatchIdentity {
            address: setting_string(conn, "watch_address", &address),
            name: setting_string(conn, "watch_name", &name),
            account: setting_string(conn, "huawei_account", ""),
            auth_key: setting_string(conn, "watch_auth_key", ""),
            fake_android_id: setting_string(conn, "fake_android_id", ""),
            huawei_address: setting_string(conn, "huawei_address", ""),
            last_sync_ms: setting_string(conn, "watch_last_sync", "")
                .parse::<i64>()
                .ok(),
            migrated,
            ephemeris_url: setting_string(conn, "ephemeris_url", ""),
        })
    })
}

pub fn save_watch_identity(identity: WatchIdentity) -> Result<()> {
    with_conn(|conn| {
        let pairs = [
            ("watch_address", identity.address),
            ("watch_name", identity.name),
            ("huawei_account", identity.account),
            ("watch_auth_key", identity.auth_key),
            ("fake_android_id", identity.fake_android_id),
            ("huawei_address", identity.huawei_address),
            (
                "watch_last_sync",
                identity
                    .last_sync_ms
                    .map(|v| v.to_string())
                    .unwrap_or_default(),
            ),
            ("ephemeris_url", identity.ephemeris_url),
        ];
        for (key, value) in pairs {
            conn.execute(
                "INSERT INTO settings(key, value) VALUES(?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, value],
            )?;
        }
        Ok(())
    })
}

pub fn goals() -> Result<Goals> {
    with_conn(|conn| {
        Ok(Goals {
            steps: setting_i64(conn, "goal_steps", 10_000),
            calories: setting_i64(conn, "goal_calories", 500),
            active_minutes: setting_i64(conn, "goal_active_minutes", 60),
            exercise_minutes: setting_i64(conn, "goal_exercise_minutes", 30),
        })
    })
}

pub fn save_goals(goals: Goals) -> Result<()> {
    with_conn(|conn| {
        for (key, value) in [
            ("goal_steps", goals.steps),
            ("goal_calories", goals.calories),
            ("goal_active_minutes", goals.active_minutes),
            ("goal_exercise_minutes", goals.exercise_minutes),
        ] {
            conn.execute(
                "INSERT INTO settings(key, value) VALUES(?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, value.to_string()],
            )?;
        }
        Ok(())
    })
}

pub fn blood_pressure_records(limit: i64) -> Result<Vec<BloodPressureEntry>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, timestamp_ms, systolic, diastolic, pulse FROM blood_pressure_records
             ORDER BY timestamp_ms DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(BloodPressureEntry {
                id: r.get(0)?,
                timestamp_ms: r.get(1)?,
                systolic: r.get(2)?,
                diastolic: r.get(3)?,
                pulse: r.get(4)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

pub fn glucose_records(limit: i64) -> Result<Vec<GlucoseEntry>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, timestamp_ms, value, measure_type FROM blood_glucose_records
             ORDER BY timestamp_ms DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(GlucoseEntry {
                id: r.get(0)?,
                timestamp_ms: r.get(1)?,
                value: r.get(2)?,
                measure_type: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

pub fn arrhythmia_records(limit: i64) -> Result<Vec<ArrhythmiaEntry>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT ts_ms, result_type FROM arrhythmia_records ORDER BY ts_ms DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(ArrhythmiaEntry {
                timestamp_ms: r.get(0)?,
                result_type: r.get(1)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

pub fn sleep_detail(day: i64) -> Result<Option<SleepDetail>> {
    let summary = sleep_summary(day)?;
    let Some(summary) = summary else {
        return Ok(None);
    };
    with_conn(|conn| {
        let bed: Option<(Option<i64>, Option<i64>, Option<i64>)> = conn
            .query_row(
                "SELECT bed_ms, fall_asleep_ms, wake_ms FROM sleep_bed
                 WHERE fall_asleep_ms BETWEEN ?1 - 3600000 AND ?2
                 ORDER BY ABS(fall_asleep_ms - ?1) LIMIT 1",
                params![summary.start_ms, summary.end_ms],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        let bed_ms = bed.and_then(|b| b.0);
        let wake_ms = bed.and_then(|b| b.2);

        // 图表窗口从「上床」画到「醒来」，再留 15 分钟余量，
        // 否则入睡前的清醒段和醒来后的片段会被 summary 窗口裁掉。
        let from = bed_ms.unwrap_or(summary.start_ms).min(summary.start_ms) - 15 * 60_000;
        let to = wake_ms.unwrap_or(summary.end_ms).max(summary.end_ms) + 15 * 60_000;

        let mut stages = Vec::new();
        let mut stmt = conn.prepare(
            "SELECT start_ms, end_ms, stage FROM sleep_stages
             WHERE end_ms > ?1 AND start_ms < ?2 AND end_ms - start_ms < ?3 ORDER BY start_ms",
        )?;
        if let Ok(rows) = stmt.query_map(params![from, to, to - from], |r| {
            Ok(SleepStage {
                start_ms: r.get(0)?,
                end_ms: r.get(1)?,
                stage: r.get(2)?,
            })
        }) {
            for row in rows.flatten() {
                stages.push(row);
            }
        }
        // 手表详情文件可能比最终睡眠摘要少最后一截。若官方摘要已给出
        // 6h18，而分钟级分期只画到 4h44，就用浅睡补上尾部空档，保证
        // 时间轴和顶部总时长一致；下次拿到完整分期时自然被真实数据替代。
        let tracked_sleep_ms: i64 = stages
            .iter()
            .filter(|stage| stage.stage != "awake")
            .map(|stage| (stage.end_ms - stage.start_ms).max(0))
            .sum();
        let missing_ms = summary.total_minutes.saturating_mul(60_000) - tracked_sleep_ms;
        if missing_ms > 60_000 {
            if let Some(last) = stages.last() {
                if summary.end_ms > last.end_ms {
                    stages.push(SleepStage {
                        start_ms: last.end_ms,
                        end_ms: summary.end_ms,
                        stage: "light".into(),
                    });
                }
            }
        }
        // 图表窗口按「上床 → 醒来」画，同时必须罩住所有阶段，
        // 否则醒后那段清醒会被裁掉，画布右端也和标签对不上。
        let chart_start = bed_ms.unwrap_or(summary.start_ms);
        let chart_end = wake_ms.unwrap_or(summary.end_ms);
        let chart_start = stages
            .first()
            .map(|s: &SleepStage| s.start_ms.min(chart_start))
            .unwrap_or(chart_start);
        let chart_end = stages
            .last()
            .map(|s: &SleepStage| s.end_ms.max(chart_end))
            .unwrap_or(chart_end);
        // 呼吸率采样是睡前/睡中零星打的点（常常正好落在上床那一刻），
        // 用 summary 的会话边界去取会整晚取不到，改用「上床 → 醒来」窗口。
        let breathing = point_between(conn, "respiration", chart_start, chart_end);
        let sleep_hrv = conn
            .query_row(
                "SELECT avg_hrv, min_baseline, max_baseline, day_to_baseline
                 FROM sleep_hrv_records WHERE date_day = ?1",
                [day],
                |r| {
                    Ok((
                        r.get::<_, f64>(0)?,
                        r.get::<_, f64>(1)?,
                        r.get::<_, f64>(2)?,
                        r.get::<_, f64>(3)?,
                    ))
                },
            )
            .optional()?;
        let valid = |value: f64| (value >= 0.0).then_some(value);
        Ok(Some(SleepDetail {
            summary,
            stages,
            chart_start_ms: chart_start,
            chart_end_ms: chart_end,
            bed_ms,
            fall_asleep_ms: bed.and_then(|b| b.1),
            wake_ms,
            breathing,
            sleep_hrv_avg: sleep_hrv.map(|v| v.0),
            sleep_hrv_min_baseline: sleep_hrv.and_then(|v| valid(v.1)),
            sleep_hrv_max_baseline: sleep_hrv.and_then(|v| valid(v.2)),
            sleep_hrv_day_to_baseline: sleep_hrv.and_then(|v| valid(v.3)),
        }))
    })
}

fn point_between(conn: &Connection, metric: &str, from: i64, to: i64) -> Option<f64> {
    conn.query_row(
        "SELECT AVG(value) FROM metric_points WHERE metric = ?1 AND ts_ms >= ?2 AND ts_ms <= ?3",
        params![metric, from, to],
        |r| r.get::<_, Option<f64>>(0),
    )
    .optional()
    .ok()
    .flatten()
    .flatten()
}

pub fn settings_set(key: &str, value: &str) -> Result<()> {
    with_conn(|conn| {
        conn.execute(
            "INSERT INTO settings(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    })
}

pub fn export_gpx(id: &str) -> Result<String> {
    let detail = get_workout(id)?.ok_or_else(|| anyhow!("workout not found"))?;
    let track = detail.track_json.unwrap_or_else(|| "[]".into());
    let points: Vec<(f64, f64, f64, i64)> = parse_track(&track);
    let mut xml = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Vitaloop\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n  <trk>\n    <name>",
    );
    xml.push_str(&detail.summary.sport);
    xml.push_str("</name>\n    <trkseg>\n");
    for (lat, lon, alt, ts) in points {
        xml.push_str(&format!(
            "      <trkpt lat=\"{lat:.6}\" lon=\"{lon:.6}\"><ele>{alt:.1}</ele><time>{}</time></trkpt>\n",
            chrono::DateTime::from_timestamp_millis(ts)
                .map(|d| d.to_rfc3339())
                .unwrap_or_default()
        ));
    }
    xml.push_str("    </trkseg>\n  </trk>\n</gpx>\n");
    Ok(xml)
}

pub fn export_tcx(id: &str) -> Result<String> {
    let detail = get_workout(id)?.ok_or_else(|| anyhow!("workout not found"))?;
    let summary = &detail.summary;
    let track = detail.track_json.clone().unwrap_or_else(|| "[]".into());
    let points: Vec<(f64, f64, f64, i64)> = parse_track(&track);
    let samples = parse_hr_samples(detail.samples_json.as_deref());
    let start = chrono::DateTime::from_timestamp_millis(summary.start_ms)
        .map(|d| d.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
        .unwrap_or_default();
    let sport = if summary.sport.contains("cycling")
        || summary.sport.contains("biking")
        || summary.sport.contains("骑行")
    {
        "Biking"
    } else if summary.sport.contains("run") || summary.sport.contains("跑步") {
        "Running"
    } else {
        "Other"
    };

    let mut xml = String::new();
    xml.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    xml.push_str("<TrainingCenterDatabase xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\" ");
    xml.push_str("xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n");
    xml.push_str("  <Activities>\n");
    xml.push_str(&format!("    <Activity Sport=\"{sport}\">\n"));
    xml.push_str(&format!("      <Id>{start}</Id>\n"));
    xml.push_str(&format!("      <Lap StartTime=\"{start}\">\n"));
    xml.push_str(&format!(
        "        <TotalTimeSeconds>{}</TotalTimeSeconds>\n",
        summary.duration_sec
    ));
    xml.push_str(&format!(
        "        <DistanceMeters>{:.1}</DistanceMeters>\n",
        summary.distance_m
    ));
    xml.push_str(&format!(
        "        <Calories>{}</Calories>\n",
        summary.calories
    ));
    xml.push_str("        <Intensity>Active</Intensity>\n");
    xml.push_str("        <TriggerMethod>Manual</TriggerMethod>\n");
    if summary.avg_hr > 0 {
        xml.push_str("        <AverageHeartRateBpm>\n");
        xml.push_str(&format!("          <Value>{}</Value>\n", summary.avg_hr));
        xml.push_str("        </AverageHeartRateBpm>\n");
    }
    if summary.max_hr > 0 {
        xml.push_str("        <MaximumHeartRateBpm>\n");
        xml.push_str(&format!("          <Value>{}</Value>\n", summary.max_hr));
        xml.push_str("        </MaximumHeartRateBpm>\n");
    }
    if !points.is_empty() {
        xml.push_str("        <Track>\n");
        let mut distance = 0.0;
        let mut prev: Option<(f64, f64)> = None;
        for (lat, lon, alt, ts) in &points {
            if let Some((plat, plon)) = prev {
                distance += haversine_meters(plat, plon, *lat, *lon);
            }
            prev = Some((*lat, *lon));
            let time = chrono::DateTime::from_timestamp_millis(*ts)
                .map(|d| d.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
                .unwrap_or_default();
            xml.push_str("          <Trackpoint>\n");
            xml.push_str(&format!("            <Time>{time}</Time>\n"));
            xml.push_str("            <Position>\n");
            xml.push_str(&format!(
                "              <LatitudeDegrees>{lat:.7}</LatitudeDegrees>\n"
            ));
            xml.push_str(&format!(
                "              <LongitudeDegrees>{lon:.7}</LongitudeDegrees>\n"
            ));
            xml.push_str("            </Position>\n");
            xml.push_str(&format!(
                "            <AltitudeMeters>{alt:.1}</AltitudeMeters>\n"
            ));
            xml.push_str(&format!(
                "            <DistanceMeters>{distance:.1}</DistanceMeters>\n"
            ));
            if let Some(hr) = nearest_hr(&samples, *ts) {
                xml.push_str("            <HeartRateBpm>\n");
                xml.push_str(&format!("              <Value>{hr}</Value>\n"));
                xml.push_str("            </HeartRateBpm>\n");
            }
            xml.push_str("          </Trackpoint>\n");
        }
        xml.push_str("        </Track>\n");
    }
    xml.push_str("      </Lap>\n");
    xml.push_str("    </Activity>\n");
    xml.push_str("  </Activities>\n");
    xml.push_str("</TrainingCenterDatabase>\n");
    Ok(xml)
}

fn parse_hr_samples(json: Option<&str>) -> Vec<(i64, i64)> {
    let Some(json) = json else {
        return Vec::new();
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(json) else {
        return Vec::new();
    };
    let Some(items) = value.as_array() else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| {
            let ts = item.get("t").and_then(|v| v.as_i64())?;
            let hr = item.get("hr").and_then(|v| v.as_i64())?;
            (hr > 0).then_some((ts, hr))
        })
        .collect()
}

fn nearest_hr(samples: &[(i64, i64)], ts: i64) -> Option<i64> {
    samples
        .iter()
        .min_by_key(|(sample_ts, _)| (sample_ts - ts).abs())
        .filter(|(sample_ts, _)| (sample_ts - ts).abs() <= 15_000)
        .map(|(_, hr)| *hr)
}

fn haversine_meters(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const R: f64 = 6_371_000.0;
    let dlat = (lat2 - lat1).to_radians();
    let dlon = (lon2 - lon1).to_radians();
    let a = (dlat / 2.0).sin().powi(2)
        + lat1.to_radians().cos() * lat2.to_radians().cos() * (dlon / 2.0).sin().powi(2);
    2.0 * R * a.sqrt().asin()
}

fn parse_track(json: &str) -> Vec<(f64, f64, f64, i64)> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(json) else {
        return Vec::new();
    };
    let Some(items) = value.as_array() else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|p| {
            Some((
                p.get("lat")?.as_f64()?,
                p.get("lon")?.as_f64()?,
                p.get("alt").and_then(|v| v.as_f64()).unwrap_or(0.0),
                p.get("ts").and_then(|v| v.as_i64()).unwrap_or(0),
            ))
        })
        .collect()
}

pub fn demo_installed() -> bool {
    settings_get("demo_data", "0")
        .map(|v| v == "1")
        .unwrap_or(false)
}

pub fn app_info() -> Result<AppInfo> {
    Ok(AppInfo {
        version: env!("CARGO_PKG_VERSION").to_string(),
        db_version: DB_VERSION,
        demo_data: demo_installed(),
    })
}

pub fn local_today() -> (i64, i64) {
    let now = Local::now();
    (today_epoch_day(), now.timestamp_millis())
}

pub fn date_label(day: i64) -> String {
    let d = date_of_epoch_day(day);
    format!("{}月{}日", d.month(), d.day())
}

// ---------- 力量训练 ----------

const DEFAULT_STRENGTH_EXERCISES: &[(&str, &str, &str)] = &[
    ("杠铃卧推", "胸", "杠铃"),
    ("哑铃卧推", "胸", "哑铃"),
    ("上斜杠铃卧推", "胸", "杠铃"),
    ("上斜哑铃卧推", "胸", "哑铃"),
    ("蝴蝶机夹胸", "胸", "器械"),
    ("俯卧撑", "胸", "自重"),
    ("双杠臂屈伸", "胸", "自重"),
    ("引体向上", "背", "自重"),
    ("高位下拉", "背", "器械"),
    ("杠铃划船", "背", "杠铃"),
    ("哑铃单臂划船", "背", "哑铃"),
    ("坐姿绳索划船", "背", "器械"),
    ("硬拉", "背", "杠铃"),
    ("杠铃深蹲", "腿", "杠铃"),
    ("腿举", "腿", "器械"),
    ("哑铃箭步蹲", "腿", "哑铃"),
    ("腿屈伸", "腿", "器械"),
    ("腿弯举", "腿", "器械"),
    ("罗马尼亚硬拉", "腿", "杠铃"),
    ("提踵", "腿", "器械"),
    ("杠铃推举", "肩", "杠铃"),
    ("哑铃推举", "肩", "哑铃"),
    ("哑铃侧平举", "肩", "哑铃"),
    ("哑铃前平举", "肩", "哑铃"),
    ("俯身反向飞鸟", "肩", "哑铃"),
    ("面拉", "肩", "器械"),
    ("杠铃弯举", "臂", "杠铃"),
    ("哑铃弯举", "臂", "哑铃"),
    ("锤式弯举", "臂", "哑铃"),
    ("绳索下压", "臂", "器械"),
    ("仰卧臂屈伸", "臂", "杠铃"),
    ("窄距卧推", "臂", "杠铃"),
    ("平板支撑", "核心", "自重"),
    ("卷腹", "核心", "自重"),
    ("悬垂举腿", "核心", "自重"),
    ("俄罗斯转体", "核心", "自重"),
    ("健腹轮", "核心", "器械"),
    ("死虫式", "核心", "自重"),
    ("波比跳", "全身", "自重"),
    ("壶铃摇摆", "全身", "壶铃"),
    ("高翻", "全身", "杠铃"),
    ("农夫行走", "全身", "哑铃"),
    ("杠铃臀推", "臀", "杠铃"),
    ("臀桥", "臀", "自重"),
    ("保加利亚分腿蹲", "腿", "哑铃"),
];

/// (模板名, 说明, [(动作名, 组, 次, 休息秒)])
const DEFAULT_STRENGTH_TEMPLATES: &[(&str, &str, &[(&str, i64, i64, i64)])] = &[
    (
        "推胸日",
        "以杠铃卧推为主项的推类训练，复合动作先做",
        &[
            ("杠铃卧推", 4, 8, 90),
            ("上斜哑铃卧推", 3, 10, 90),
            ("蝴蝶机夹胸", 3, 12, 60),
            ("双杠臂屈伸", 3, 10, 90),
            ("俯卧撑", 3, 15, 60),
        ],
    ),
    (
        "臀腿日",
        "下肢为主，深蹲/硬拉/臀推三大项",
        &[
            ("杠铃深蹲", 4, 8, 120),
            ("罗马尼亚硬拉", 4, 10, 120),
            ("杠铃臀推", 4, 10, 90),
            ("腿举", 3, 12, 90),
            ("保加利亚分腿蹲", 3, 12, 60),
            ("提踵", 3, 15, 60),
        ],
    ),
    (
        "核心训练",
        "腹肌与核心稳定性训练",
        &[
            ("卷腹", 3, 20, 45),
            ("俄罗斯转体", 3, 20, 45),
            ("悬垂举腿", 3, 12, 60),
            ("健腹轮", 3, 10, 60),
            ("死虫式", 3, 15, 45),
        ],
    ),
    (
        "全身循环",
        "全身复合动作循环，适合完整训练日",
        &[
            ("杠铃深蹲", 3, 10, 90),
            ("杠铃卧推", 3, 10, 90),
            ("引体向上", 3, 8, 90),
            ("杠铃划船", 3, 10, 90),
            ("哑铃推举", 3, 10, 60),
            ("壶铃摇摆", 3, 15, 60),
        ],
    ),
];

/// 首次使用时补默认动作库和 4 套模板；只补缺失，不覆盖用户改动。
pub fn strength_ensure_defaults() -> Result<()> {
    with_conn(|conn| {
        let count: i64 =
            conn.query_row("SELECT COUNT(*) FROM strength_exercises", [], |r| r.get(0))?;
        if count == 0 {
            for (name, group, equipment) in DEFAULT_STRENGTH_EXERCISES {
                conn.execute(
                    "INSERT INTO strength_exercises(name, muscle_group, equipment, is_custom)
                     VALUES(?1, ?2, ?3, 0)",
                    params![name, group, equipment],
                )?;
            }
        }

        let seeded: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = 'strength_templates_seeded'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        if seeded.as_deref() != Some("1") {
            let now = now_ms();
            for (name, notes, exercises) in DEFAULT_STRENGTH_TEMPLATES {
                let exists: i64 = conn.query_row(
                    "SELECT COUNT(*) FROM strength_templates WHERE name = ?1",
                    params![name],
                    |r| r.get(0),
                )?;
                if exists > 0 {
                    continue;
                }
                conn.execute(
                    "INSERT INTO strength_templates(name, notes, created_ms, updated_ms)
                     VALUES(?1, ?2, ?3, ?3)",
                    params![name, notes, now],
                )?;
                let template_id = conn.last_insert_rowid();
                for (index, (exercise_name, sets, reps, rest)) in exercises.iter().enumerate() {
                    let exercise_id: Option<i64> = conn
                        .query_row(
                            "SELECT id FROM strength_exercises WHERE name = ?1 LIMIT 1",
                            params![exercise_name],
                            |r| r.get(0),
                        )
                        .optional()?;
                    let Some(exercise_id) = exercise_id else {
                        continue;
                    };
                    conn.execute(
                        "INSERT INTO strength_template_exercises(
                            template_id, exercise_id, order_index, target_sets,
                            target_reps, rest_seconds)
                         VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
                        params![template_id, exercise_id, index as i64, sets, reps, rest],
                    )?;
                }
            }
            conn.execute(
                "INSERT INTO settings(key, value) VALUES('strength_templates_seeded', '1')
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [],
            )?;
        }
        Ok(())
    })
}

pub fn strength_exercises() -> Result<Vec<StrengthExercise>> {
    strength_ensure_defaults()?;
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, name, muscle_group, equipment, is_custom
             FROM strength_exercises ORDER BY muscle_group, name",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(StrengthExercise {
                id: r.get(0)?,
                name: r.get(1)?,
                muscle_group: r.get(2)?,
                equipment: r.get(3)?,
                is_custom: r.get::<_, i64>(4)? != 0,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    })
}

pub fn strength_add_exercise(name: &str, muscle_group: &str, equipment: &str) -> Result<i64> {
    let name = name.trim();
    if name.is_empty() {
        anyhow::bail!("动作名称不能为空");
    }
    with_conn(|conn| {
        let exists: i64 = conn.query_row(
            "SELECT COUNT(*) FROM strength_exercises WHERE name = ?1",
            params![name],
            |r| r.get(0),
        )?;
        if exists > 0 {
            anyhow::bail!("动作「{name}」已存在");
        }
        conn.execute(
            "INSERT INTO strength_exercises(name, muscle_group, equipment, is_custom)
             VALUES(?1, ?2, ?3, 1)",
            params![name, muscle_group.trim(), equipment.trim()],
        )?;
        Ok(conn.last_insert_rowid())
    })
}

pub fn strength_templates() -> Result<Vec<StrengthTemplate>> {
    strength_ensure_defaults()?;
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, name, notes, updated_ms FROM strength_templates
             ORDER BY updated_ms DESC, id DESC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, i64>(3)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let mut out = Vec::new();
        for (id, name, notes, updated_ms) in rows {
            out.push(StrengthTemplate {
                id,
                name,
                notes,
                updated_at_ms: updated_ms,
                exercises: strength_template_exercises(conn, id)?,
            });
        }
        Ok(out)
    })
}

fn strength_template_exercises(
    conn: &Connection,
    template_id: i64,
) -> Result<Vec<StrengthTemplateExercise>> {
    let mut stmt = conn.prepare(
        "SELECT te.id, te.exercise_id, COALESCE(e.name, ''), te.order_index,
                te.target_sets, te.target_reps, te.rest_seconds,
                te.target_weight_kg, te.notes
         FROM strength_template_exercises te
         LEFT JOIN strength_exercises e ON e.id = te.exercise_id
         WHERE te.template_id = ?1
         ORDER BY te.order_index, te.id",
    )?;
    let rows = stmt.query_map(params![template_id], |r| {
        Ok(StrengthTemplateExercise {
            id: r.get(0)?,
            exercise_id: r.get(1)?,
            exercise_name: r.get(2)?,
            order_index: r.get(3)?,
            target_sets: r.get(4)?,
            target_reps: r.get(5)?,
            rest_seconds: r.get(6)?,
            target_weight_kg: r.get(7)?,
            notes: r.get(8)?,
        })
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn strength_save_template(
    id: i64,
    name: &str,
    notes: &str,
    exercises: &[StrengthTemplateExerciseInput],
) -> Result<i64> {
    let name = name.trim();
    if name.is_empty() {
        anyhow::bail!("模板名称不能为空");
    }
    if exercises.is_empty() {
        anyhow::bail!("模板至少需要一个动作");
    }
    with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        let now = now_ms();
        let template_id = if id > 0 {
            tx.execute(
                "UPDATE strength_templates SET name = ?1, notes = ?2, updated_ms = ?3 WHERE id = ?4",
                params![name, notes.trim(), now, id],
            )?;
            id
        } else {
            tx.execute(
                "INSERT INTO strength_templates(name, notes, created_ms, updated_ms)
                 VALUES(?1, ?2, ?3, ?3)",
                params![name, notes.trim(), now],
            )?;
            tx.last_insert_rowid()
        };
        tx.execute(
            "DELETE FROM strength_template_exercises WHERE template_id = ?1",
            params![template_id],
        )?;
        for (index, item) in exercises.iter().enumerate() {
            tx.execute(
                "INSERT INTO strength_template_exercises(
                    template_id, exercise_id, order_index, target_sets, target_reps,
                    rest_seconds, target_weight_kg, notes)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    template_id,
                    item.exercise_id,
                    index as i64,
                    item.target_sets.clamp(1, 20),
                    item.target_reps.clamp(1, 200),
                    item.rest_seconds.clamp(0, 600),
                    item.target_weight_kg,
                    item.notes.trim(),
                ],
            )?;
        }
        tx.commit()?;
        Ok(template_id)
    })
}

pub fn strength_delete_template(id: i64) -> Result<()> {
    with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        tx.execute(
            "DELETE FROM strength_template_exercises WHERE template_id = ?1",
            params![id],
        )?;
        tx.execute("DELETE FROM strength_templates WHERE id = ?1", params![id])?;
        tx.commit()?;
        Ok(())
    })
}

pub fn strength_save_sets(session_id: &str, sets: &[StrengthSetInput]) -> Result<()> {
    let session_id = session_id.trim();
    if session_id.is_empty() {
        anyhow::bail!("session_id 不能为空");
    }
    with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        for set in sets {
            tx.execute(
                "INSERT INTO strength_workout_sets(
                    session_id, exercise_id, exercise_name, set_number, weight_kg,
                    reps, rest_seconds_actual, completed_at_ms)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    session_id,
                    set.exercise_id,
                    set.exercise_name.trim(),
                    set.set_number.max(1),
                    set.weight_kg.max(0.0),
                    set.reps.max(0),
                    set.rest_seconds_actual.max(0),
                    set.completed_at_ms,
                ],
            )?;
        }
        tx.commit()?;
        Ok(())
    })
}

pub fn strength_sets(session_id: &str) -> Result<Vec<StrengthSet>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, session_id, exercise_id, exercise_name, set_number,
                    weight_kg, reps, rest_seconds_actual, completed_at_ms
             FROM strength_workout_sets WHERE session_id = ?1 ORDER BY id",
        )?;
        let rows = stmt.query_map(params![session_id], |r| {
            Ok(StrengthSet {
                id: r.get(0)?,
                session_id: r.get(1)?,
                exercise_id: r.get(2)?,
                exercise_name: r.get(3)?,
                set_number: r.get(4)?,
                weight_kg: r.get(5)?,
                reps: r.get(6)?,
                rest_seconds_actual: r.get(7)?,
                completed_at_ms: r.get(8)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    })
}

// ---------- P2P：呼吸暂停 / 每小时状态 / 每日三环 ----------

pub fn apnea_records(limit: i64) -> Result<Vec<ApneaRecord>> {
    with_conn(|conn| {
        let mut stmt =
            conn.prepare("SELECT ts_ms, level FROM apnea_records ORDER BY ts_ms DESC LIMIT ?1")?;
        let rows = stmt.query_map(params![limit.clamp(1, 1000)], |r| {
            Ok(ApneaRecord {
                ts_ms: r.get(0)?,
                level: r.get(1)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    })
}

pub fn apnea_for_day(day: i64) -> Result<Vec<ApneaRecord>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT ts_ms, level FROM apnea_records
             WHERE ts_ms >= ?1 AND ts_ms < ?2 ORDER BY ts_ms",
        )?;
        // 睡眠按“醒来的那天”归属，23:30 入睡后的呼吸暂停落在零点前；
        // 只看自然日会漏掉前半夜，所以窗口和睡眠会话一样往前多取 12 小时。
        let rows = stmt.query_map(
            params![day_start_ms(day) - 12 * 3_600_000, day_end_ms(day)],
            |r| {
                Ok(ApneaRecord {
                    ts_ms: r.get(0)?,
                    level: r.get(1)?,
                })
            },
        )?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    })
}

pub fn hourly_status(day: i64) -> Result<Vec<HourlyStatusPoint>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT ts_ms, value FROM hourly_status
             WHERE ts_ms >= ?1 AND ts_ms < ?2 ORDER BY ts_ms",
        )?;
        let rows = stmt.query_map(params![day_start_ms(day), day_end_ms(day)], |r| {
            Ok(HourlyStatusPoint {
                ts_ms: r.get(0)?,
                value: r.get(1)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    })
}

pub fn daily_rings(limit: i64) -> Result<Vec<DailyRing>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT date_day, day_end_ms, step_goal, step_user, step_state,
                    calorie_goal_milli, calorie_user_milli, calorie_state,
                    duration_goal_min, duration_user_min, duration_state,
                    active_goal_hours, active_user_hours, active_state
             FROM daily_rings ORDER BY date_day DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit.clamp(1, 1000)], daily_ring_from_row)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    })
}

pub fn daily_ring(day: i64) -> Result<Option<DailyRing>> {
    with_conn(|conn| {
        Ok(conn
            .query_row(
                "SELECT date_day, day_end_ms, step_goal, step_user, step_state,
                    calorie_goal_milli, calorie_user_milli, calorie_state,
                    duration_goal_min, duration_user_min, duration_state,
                    active_goal_hours, active_user_hours, active_state
             FROM daily_rings WHERE date_day = ?1",
                params![day],
                daily_ring_from_row,
            )
            .optional()?)
    })
}

fn daily_ring_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<DailyRing> {
    Ok(DailyRing {
        date_epoch_day: r.get(0)?,
        day_end_ms: r.get(1)?,
        step_goal: r.get(2)?,
        step_user: r.get(3)?,
        step_state: r.get(4)?,
        calorie_goal_milli: r.get(5)?,
        calorie_user_milli: r.get(6)?,
        calorie_state: r.get(7)?,
        duration_goal_min: r.get(8)?,
        duration_user_min: r.get(9)?,
        duration_state: r.get(10)?,
        active_goal_hours: r.get(11)?,
        active_user_hours: r.get(12)?,
        active_state: r.get(13)?,
    })
}

// ---------- 规划路线 ----------

fn haversine_m(a: &GeoPoint, b: &GeoPoint) -> f64 {
    const R: f64 = 6_371_000.0;
    let lat1 = a.lat.to_radians();
    let lat2 = b.lat.to_radians();
    let dlat = lat2 - lat1;
    let dlon = (b.lon - a.lon).to_radians();
    let h = (dlat / 2.0).sin().powi(2) + lat1.cos() * lat2.cos() * (dlon / 2.0).sin().powi(2);
    2.0 * R * h.sqrt().asin()
}

fn route_distance_m(points: &[GeoPoint]) -> f64 {
    points.windows(2).map(|w| haversine_m(&w[0], &w[1])).sum()
}

fn route_points_json(points: &[GeoPoint]) -> String {
    let values: Vec<[f64; 2]> = points.iter().map(|p| [p.lat, p.lon]).collect();
    serde_json::to_string(&values).unwrap_or_else(|_| "[]".to_string())
}

fn parse_route_points(json: &str) -> Vec<GeoPoint> {
    serde_json::from_str::<Vec<[f64; 2]>>(json)
        .unwrap_or_default()
        .into_iter()
        .filter(|p| p[0].abs() <= 85.0 && p[1].abs() <= 180.0)
        .map(|p| GeoPoint {
            lat: p[0],
            lon: p[1],
        })
        .collect()
}

pub fn saved_routes() -> Result<Vec<SavedRoute>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, name, points_json, distance_m, created_ms
             FROM saved_routes ORDER BY created_ms DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, f64>(3)?,
                r.get::<_, i64>(4)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (id, name, points_json, distance_m, created_ms) = row?;
            out.push(SavedRoute {
                id,
                name,
                distance_m,
                created_ms,
                points: parse_route_points(&points_json),
            });
        }
        Ok(out)
    })
}

pub fn save_route(id: &str, name: &str, points: &[GeoPoint]) -> Result<String> {
    let name = name.trim();
    if name.is_empty() {
        anyhow::bail!("路线名称不能为空");
    }
    if points.len() < 2 {
        anyhow::bail!("至少要有起点和终点");
    }
    let id = if id.trim().is_empty() {
        format!("route-{}", now_ms())
    } else {
        id.trim().to_string()
    };
    let distance = route_distance_m(points);
    with_conn(|conn| {
        conn.execute(
            "DELETE FROM saved_route_tombstones WHERE id = ?1",
            params![id],
        )?;
        conn.execute(
            "INSERT INTO saved_routes(id, name, points_json, distance_m, created_ms)
             VALUES(?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                points_json = excluded.points_json,
                distance_m = excluded.distance_m",
            params![id, name, route_points_json(points), distance, now_ms()],
        )?;
        Ok(())
    })?;
    Ok(id)
}

pub fn delete_route(id: &str) -> Result<()> {
    with_conn(|conn| {
        conn.execute(
            "INSERT OR REPLACE INTO saved_route_tombstones(id, deleted_ms)
             VALUES(?1, ?2)",
            params![id, now_ms()],
        )?;
        conn.execute("DELETE FROM saved_routes WHERE id = ?1", params![id])?;
        Ok(())
    })
}

#[cfg(test)]
pub(crate) static TEST_LOCK: Mutex<()> = Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epoch_day_roundtrip() {
        let day = 20_000;
        let date = date_of_epoch_day(day);
        assert_eq!(epoch_day_of(date), day);
    }

    #[test]
    fn merge_json_point_series_keeps_timed_legacy_points() {
        let existing = r#"[{"t":1000,"cad":120},{"t":2000,"cad":121},{"t":3000,"cad":122}]"#;
        let incoming = r#"[{"cad":120},{"cad":124},{"cad":126}]"#;
        let merged = merge_json_point_series(Some(existing), Some(incoming), "t").unwrap();
        let points: Vec<serde_json::Value> = serde_json::from_str(&merged).unwrap();
        assert_eq!(points.len(), 3, "较长的旧明细不能被 3 个汇总点覆盖");
        assert_eq!(points[2]["t"].as_i64(), Some(3000));
    }

    #[test]
    fn merge_json_point_series_unions_overlapping_timestamps() {
        let existing = r#"[{"t":1000,"cad":120},{"t":3000,"cad":122}]"#;
        let incoming = r#"[{"t":2000,"cad":121},{"t":3000,"cad":999}]"#;
        let merged = merge_json_point_series(Some(existing), Some(incoming), "t").unwrap();
        let points: Vec<serde_json::Value> = serde_json::from_str(&merged).unwrap();
        assert_eq!(points.len(), 3);
        assert_eq!(points[2]["cad"].as_i64(), Some(122), "重合时间保留已有值");
    }

    #[test]
    fn workout_detail_exposes_splits_and_swim_segments_from_detail_json() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-test-swim-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();
        with_conn(|conn| {
            conn.execute("DELETE FROM workouts", [])?;
            Ok(())
        })
        .unwrap();
        let id = workout_add(
            "swimming",
            1_700_000_000_000,
            1500,
            1000.0,
            200,
            120,
            150,
            "[]",
        )
        .unwrap();
        let detail = json!({
            "splits": [
                {"i": 0, "distance": 1000, "type": 0, "pace": 300, "point": 0},
                {"i": 1, "distance": 1000, "type": 0, "pace": 310, "point": 4, "corr": 50}
            ],
            "segments": [
                {"segment": 1, "distance": 25, "pace": 120, "strokes": 18, "swolf": 30, "time": 30},
                {"segment": 2, "distance": 50, "pace": 118, "strokes": 36, "swolf": 29, "time": 59}
            ]
        })
        .to_string();
        with_conn(|conn| {
            conn.execute(
                "UPDATE workouts SET detail_json = ?1, sport = 'swimming' WHERE id = ?2",
                params![detail, id],
            )?;
            Ok(())
        })
        .unwrap();

        let workout = get_workout(&id).unwrap().expect("workout exists");
        let splits: Value = serde_json::from_str(workout.splits_json.as_deref().unwrap()).unwrap();
        assert_eq!(splits.as_array().unwrap().len(), 2);
        assert_eq!(splits[1]["corr"], 50);
        let swim: Value =
            serde_json::from_str(workout.swim_segments_json.as_deref().unwrap()).unwrap();
        assert_eq!(swim[0]["swolf"], 30);
        assert_eq!(swim[1]["distance"], 50);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn demo_seed_produces_consistent_home() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!("vitaloop-test-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();
        crate::demo::seed_demo().unwrap();
        let day = today_epoch_day();
        let home = home_summary(day).unwrap();
        assert_eq!(home.steps, 8432);
        assert_eq!(home.resting_hr, Some(59));
        assert_eq!(home.sleep_minutes, Some(432));
        assert!(
            (60..=66).contains(&home.readiness.total),
            "readiness {}",
            home.readiness.total
        );
        assert_eq!(home.readiness.level, "状态一般");
        assert!(home.device_connected);
        assert_eq!(home.device_battery, Some(86));

        let detail = readiness_detail(day).unwrap();
        assert_eq!(detail.history.len(), 7);
        assert!(detail.week_average > 40);

        let workouts = list_workouts("all", 50).unwrap();
        assert_eq!(workouts.len(), 8);
        let pending = list_workouts("pending", 50).unwrap();
        assert_eq!(pending.len(), 2);

        let sleep = sleep_summary(day).unwrap().unwrap();
        assert_eq!(sleep.total_minutes, 432);
        assert_eq!(sleep.deep_minutes, 87);

        let gpx = export_gpx("demo-run-1").unwrap();
        assert!(gpx.contains("<trkpt"));
        let tcx = export_tcx("demo-run-1").unwrap();
        assert!(tcx.contains("<TrainingCenterDatabase"));
        assert!(tcx.contains("<Trackpoint>"));
        assert!(tcx.contains("<HeartRateBpm>"));
        assert!(tcx.contains("<DistanceMeters>"));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn readiness_sums_only_same_day_workout_recovery() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-test-recovery-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = today_epoch_day();
        let start = day_start_ms(day);
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO daily_metrics(
                    date_day, hrv_ms, sleep_minutes, deep_sleep_minutes,
                    resting_hr, skin_temp_c, stress, updated_ms
                 ) VALUES(?1, 56, 432, 87, 59, 33.6, 28, ?2)",
                params![day, start + 8 * 3_600_000],
            )?;
            conn.execute(
                "INSERT INTO workouts(id, sport, start_ms, end_ms, recovery_time_min)
                 VALUES
                    ('recovery-morning', 'run', ?1, ?2, 30),
                    ('recovery-evening', 'strength', ?3, ?4, 15),
                    ('recovery-yesterday', 'run', ?5, ?6, 120)",
                params![
                    start + 7 * 3_600_000,
                    start + 8 * 3_600_000,
                    start + 18 * 3_600_000,
                    start + 19 * 3_600_000,
                    start - 2 * 3_600_000,
                    start - 3_600_000,
                ],
            )?;
            Ok(())
        })
        .unwrap();

        let detail = readiness_detail(day).unwrap();
        assert_eq!(detail.inputs.recovery_minutes, Some(45.0));
        assert_eq!(detail.score.recovery_minutes, 45);
        assert_eq!(detail.score.recovery_score, 85);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn heart_rate_latest_is_last_sample_not_daily_average() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-heart-latest-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let today_start = day_start_ms(today_epoch_day());
        let ts1 = today_start + 10 * 3_600_000;
        let ts2 = ts1 + 60_000;
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO heart_rate_points(ts_ms, bpm) VALUES(?1, 66), (?2, 77)",
                params![ts1, ts2],
            )?;
            Ok(())
        })
        .unwrap();

        let detail = metric_detail("heart_rate", 7).unwrap();
        assert_eq!(detail.latest, Some(77.0));
        assert_eq!(detail.updated_ms, Some(ts2));
        assert_eq!(detail.days.last().map(|p| p.value), Some(71.5));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn sparse_morning_sleep_session_is_invalid() {
        let false_nap = SleepSessionRow {
            start_ms: 0,
            end_ms: 107 * 60_000,
            deep: 0.0,
            light: 28.0,
            rem: 0.0,
            awake: 8.0,
            anchor_min: None,
        };
        assert!(!false_nap.valid());

        let real_night = SleepSessionRow {
            start_ms: 0,
            end_ms: 546 * 60_000,
            deep: 151.0,
            light: 264.0,
            rem: 122.0,
            awake: 41.0,
            anchor_min: None,
        };
        assert!(real_night.valid());
    }

    #[test]
    fn resynced_sparse_morning_session_cannot_raise_sleep_total() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-sparse-resync-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = 20_766;
        let midnight = day_start_ms(day);
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1, ?2, 151, 264, 122, 41, 'watch')",
                params![midnight - 156 * 60_000, midnight + 390 * 60_000],
            )?;
            // 云端/手表再次送回 07:56–09:43、实际只睡 28 分钟的误判窗口。
            conn.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1, ?2, 0, 28, 0, 8, 'watch')",
                params![midnight + 476 * 60_000, midnight + 583 * 60_000],
            )?;
            assert_eq!(sleep_summary_for(conn, day)?.unwrap().total_minutes, 537);
            recompute_sleep_daily_metrics(conn)?;
            let daily: f64 = conn.query_row(
                "SELECT sleep_minutes FROM daily_metrics WHERE date_day = ?1",
                [day],
                |r| r.get(0),
            )?;
            assert_eq!(daily, 537.0);
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn sleep_awakenings_count_merged_episodes() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-sleep-awakenings-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();
        with_conn(|conn| {
            for (start, end) in [
                (0, 5 * 60_000),
                (4 * 60_000, 10 * 60_000),
                (20 * 60_000, 25 * 60_000),
            ] {
                conn.execute(
                    "INSERT INTO sleep_stages(start_ms, end_ms, stage)
                     VALUES(?1, ?2, 'awake')",
                    params![start, end],
                )?;
            }
            assert_eq!(sleep_awakenings_for(conn, 0, 60 * 60_000)?, Some(2.0));
            Ok(())
        })
        .unwrap();
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn day_heart_rate_keeps_every_sample_instead_of_last_ten() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-heart-day-samples-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let start = day_start_ms(today_epoch_day()) + 8 * 3_600_000;
        with_conn(|conn| {
            for i in 0..15 {
                conn.execute(
                    "INSERT INTO heart_rate_points(ts_ms, bpm) VALUES(?1, ?2)",
                    params![start + i * 60_000, 70 + i],
                )?;
            }
            Ok(())
        })
        .unwrap();

        let detail = metric_detail("heart_rate", 1).unwrap();
        let today_samples: Vec<_> = detail
            .samples
            .iter()
            .filter(|s| s.timestamp_ms >= start)
            .collect();
        assert_eq!(today_samples.len(), 15);
        assert_eq!(detail.days.len(), 1);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn fixes_legacy_fixed_point_max_met() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-test-max-met-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO workouts(id, sport, start_ms, end_ms, max_met)
                 VALUES('legacy-1', '户外跑步', 1000, 2000, 899398)",
                [],
            )?;
            Ok(())
        })
        .unwrap();

        open(path.to_str().unwrap()).unwrap();
        with_conn(|conn| {
            let value: f64 = conn.query_row(
                "SELECT max_met FROM workouts WHERE id = 'legacy-1'",
                [],
                |r| r.get(0),
            )?;
            assert!((value - 8.99398).abs() < 1e-6);
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn sleep_summary_prefers_asleep_minutes_over_wall_clock() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-sleep-summary-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = today_epoch_day();
        let day_start = day_start_ms(day);
        // 白天稀疏片段：墙钟 377 分钟，实际只睡着 60 分钟。
        let fragment_start = day_start + 7 * 3_600_000 + 45 * 60_000;
        // 昨晚主睡眠：322 分钟里有 314 分钟睡着。
        let main_start = day_start - 30 * 60_000;
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1, ?2, 0, 60, 0, 0, 'watch'),
                        (?3, ?4, 50, 212, 52, 8, 'watch')",
                params![
                    fragment_start,
                    fragment_start + 377 * 60_000,
                    main_start,
                    main_start + 322 * 60_000
                ],
            )?;
            Ok(())
        })
        .unwrap();

        let summary = sleep_summary(day).unwrap().unwrap();
        assert_eq!(summary.total_minutes, 314);
        assert_eq!(summary.start_ms, main_start);
        assert_eq!(latest_sleep_day().unwrap(), Some(day));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn sleep_summary_uses_watch_duration_and_official_score() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-watch-sleep-score-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = today_epoch_day();
        let start = day_start_ms(day) - 60 * 60_000;
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO sleep_sessions(
                    start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source
                 ) VALUES(?1, ?2, 67, 160, 57, 26, 'watch')",
                params![start, start + 310 * 60_000],
            )?;
            conn.execute(
                "INSERT INTO sleep_bed(
                    session_start_ms, fall_asleep_ms, wake_ms, duration_min,
                    watch_score, watch_efficiency, watch_wake_count
                 ) VALUES(?1, ?1, ?2, 397, 79, 91, 3)",
                params![start, start + 397 * 60_000],
            )?;
            Ok(())
        })
        .unwrap();

        let summary = sleep_summary(day).unwrap().unwrap();
        // 手表时间窗 6h37，其中清醒 26 分钟；睡眠时长为 6h11。
        assert_eq!(summary.total_minutes, 371);
        assert_eq!(summary.score, 79);
        assert_eq!(summary.efficiency, 91);
        assert_eq!(summary.end_ms, start + 397 * 60_000);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn sleep_summary_adds_afternoon_nap_to_main_sleep() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-test-sleep-nap-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = today_epoch_day();
        let day_start = day_start_ms(day);
        let main_start = day_start - 30 * 60_000;
        let main_end = day_start + 6 * 3_600_000;
        let nap_start = day_start + 13 * 3_600_000;
        let nap_end = nap_start + 17 * 60_000;
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1, ?2, 90, 300, 30, 10, 'watch'),
                        (?3, ?4, 0, 17, 0, 0, 'watch')",
                params![main_start, main_end, nap_start, nap_end],
            )?;
            Ok(())
        })
        .unwrap();

        let summary = sleep_summary(day).unwrap().unwrap();
        assert_eq!(summary.total_minutes, 437, "主睡眠 + 17 分钟午睡");
        assert_eq!(summary.nap_minutes, 17);
        // 阶段图仍以主睡眠为窗口，午睡只累加到总时长。
        assert_eq!(summary.start_ms, main_start);
        assert_eq!(summary.end_ms, main_end);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn home_summary_includes_nap_even_when_daily_metrics_is_stale() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-test-home-nap-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = today_epoch_day();
        let day_start = day_start_ms(day);
        let main_start = day_start - 30 * 60_000;
        let main_end = day_start + 6 * 3_600_000;
        let nap_start = day_start + 13 * 3_600_000;
        let nap_end = nap_start + 38 * 60_000;
        with_conn(|conn| {
            // 模拟旧同步只写了主睡眠：日报表 420 分钟，午睡会话后到。
            conn.execute(
                "INSERT INTO daily_metrics(date_day, steps, sleep_minutes, deep_sleep_minutes,
                    rem_sleep_minutes, awake_minutes, updated_ms)
                 VALUES(?1, 100, 420, 90, 30, 10, ?2)",
                params![day, now_ms()],
            )?;
            conn.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1, ?2, 90, 300, 30, 10, 'watch'),
                        (?3, ?4, 0, 38, 0, 0, 'watch')",
                params![main_start, main_end, nap_start, nap_end],
            )?;
            Ok(())
        })
        .unwrap();

        let home = home_summary(day).unwrap();
        assert_eq!(home.sleep_minutes, Some(458), "首页必须带上午睡");
        assert_eq!(home.deep_sleep_minutes, Some(90));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn home_exercise_minutes_uses_training_ring_then_workout_records() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-exercise-min-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = today_epoch_day();
        let day_start = day_start_ms(day);
        let today_minutes = || with_conn(|conn| exercise_minutes(conn, day)).unwrap();

        with_conn(|conn| {
            conn.execute("DELETE FROM workouts", [])?;
            conn.execute("DELETE FROM daily_rings", [])?;
            Ok(())
        })
        .unwrap();
        assert_eq!(today_minutes(), 0, "三环和运动记录都没有时不该编出一个数");

        // 三环还没同步（手动运动 / 当天没同步）⇒ 用运动记录的时长；
        // total_time_sec 是 NOT NULL DEFAULT 0，得靠 start/end 差兜底
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO workouts(id, source, sport, start_ms, end_ms) VALUES(?1, 'manual', 'running', ?2, ?3)",
                params![format!("exercise-{day}"), day_start + 3_600_000, day_start + 3_600_000 + 1_500_000],
            )?;
            Ok(())
        })
        .unwrap();
        assert_eq!(today_minutes(), 25, "25 分钟的运动记录要体现在运动时长上");

        with_conn(|conn| {
            conn.execute(
                "INSERT INTO daily_rings(date_day, duration_user_min) VALUES(?1, 40)",
                params![day],
            )?;
            Ok(())
        })
        .unwrap();
        assert_eq!(today_minutes(), 40, "三环给的锻炼时长优先");

        with_conn(|conn| {
            conn.execute(
                "UPDATE daily_rings SET duration_user_min = 10 WHERE date_day = ?1",
                params![day],
            )?;
            Ok(())
        })
        .unwrap();
        assert_eq!(
            today_minutes(),
            25,
            "三环偏低时不能让刚跑完的 25 分钟变成 10 分钟"
        );

        let home = home_summary(day).unwrap();
        assert_eq!(home.exercise_minutes, 25);
        assert_eq!(
            home.exercise_goal_min, 30,
            "运动时长的进度分母是运动时长目标"
        );

        let detail = metric_detail("exercise_minutes", 7).unwrap();
        assert_eq!(detail.label, "运动时长");
        assert_eq!(detail.days.last().map(|p| p.value), Some(25.0));
        assert_eq!(detail.goal, Some(30.0));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn home_summary_falls_back_to_last_settled_resting_hr() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-home-resting-hr-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = today_epoch_day();
        let yesterday = day - 1;
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO daily_metrics(date_day, resting_hr, updated_ms)
                 VALUES(?1, 53, ?2)",
                params![yesterday, now_ms()],
            )?;
            // 今天只有步数，静息心率还没结算。
            conn.execute(
                "INSERT INTO daily_metrics(date_day, steps, updated_ms)
                 VALUES(?1, 100, ?2)",
                params![day, now_ms()],
            )?;
            Ok(())
        })
        .unwrap();

        let home = home_summary(day).unwrap();
        assert_eq!(home.resting_hr, Some(53), "今天没结算时回落昨天");

        // 日报里完全没有时，再回落到最近一次逐点采样。
        with_conn(|conn| {
            conn.execute(
                "UPDATE daily_metrics SET resting_hr = NULL WHERE date_day = ?1",
                params![yesterday],
            )?;
            conn.execute(
                "INSERT INTO metric_points(metric, ts_ms, value, source)
                 VALUES('resting_hr', ?1, 52, 'watch')",
                params![day_start_ms(yesterday) + 6 * 3_600_000],
            )?;
            Ok(())
        })
        .unwrap();

        let home = home_summary(day).unwrap();
        assert_eq!(home.resting_hr, Some(52), "日报为空时回落采样点");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn home_summary_prefers_core_body_temperature_over_wrist_temperature() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-test-home-temp-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = today_epoch_day();
        let ts = day_start_ms(day) + 8 * 3_600_000;
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO daily_metrics(date_day, steps, skin_temp_c, body_temp_c, updated_ms)
                 VALUES(?1, 100, 28.3, 36.8, ?2)",
                params![day, now_ms()],
            )?;
            conn.execute(
                "INSERT INTO metric_points(metric, ts_ms, value, source)
                 VALUES('skin_temp', ?1, 28.3, 'watch'), ('body_temp', ?1, 36.8, 'watch')",
                params![ts],
            )?;
            Ok(())
        })
        .unwrap();

        let home = home_summary(day).unwrap();
        assert_eq!(home.skin_temp_c, Some(28.3));
        assert_eq!(home.body_temp_c, Some(36.8));
        assert_eq!(home.body_temp_at_ms, Some(ts));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn home_summary_does_not_treat_wrist_temperature_as_core_temperature() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-home-temp-range-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = today_epoch_day();
        let ts = day_start_ms(day) + 8 * 3_600_000;
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO daily_metrics(date_day, steps, skin_temp_c, body_temp_c, updated_ms)
                 VALUES(?1, 100, 28.3, 28.1, ?2)",
                params![day, now_ms()],
            )?;
            conn.execute(
                "INSERT INTO metric_points(metric, ts_ms, value, source)
                 VALUES('skin_temp', ?1, 28.3, 'watch'), ('body_temp', ?1, 28.1, 'watch')",
                params![ts],
            )?;
            Ok(())
        })
        .unwrap();

        let home = home_summary(day).unwrap();
        assert_eq!(home.skin_temp_c, Some(28.3));
        assert_eq!(home.body_temp_c, None, "28°C 是腕温，不能当核心体温");
        assert_eq!(home.body_temp_at_ms, None);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn readiness_uses_wrist_temperature_from_metric_points() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-readiness-skin-temp-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = today_epoch_day();
        let ts = day_start_ms(day) + 8 * 3_600_000;
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO daily_metrics(date_day, steps, updated_ms)
                 VALUES(?1, 100, ?2)",
                params![day, now_ms()],
            )?;
            conn.execute(
                "INSERT INTO metric_points(metric, ts_ms, value, source)
                 VALUES('skin_temp', ?1, 28.3, 'watch')",
                params![ts],
            )?;
            let row = metric_row_with_sleep(conn, day)?;
            let inputs = readiness_inputs_for(conn, &row, day)?;
            assert_eq!(inputs.skin_temp_c, Some(28.3));
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn sleep_summary_rejects_daytime_false_sleep_with_high_heart_rate() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-sleep-hr-filter-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = today_epoch_day();
        let day_start = day_start_ms(day);
        let main_start = day_start - 30 * 60_000;
        let main_end = main_start + 322 * 60_000;
        let nap = (
            day_start + 13 * 3_600_000 + 24 * 60_000,
            day_start + 14 * 3_600_000 + 2 * 60_000,
        );
        let rest = (
            day_start + 16 * 3_600_000 + 39 * 60_000,
            day_start + 17 * 3_600_000 + 53 * 60_000,
        );
        let doze = (
            day_start + 19 * 3_600_000 + 21 * 60_000,
            day_start + 20 * 3_600_000 + 10 * 60_000,
        );
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO daily_metrics(date_day, resting_hr, updated_ms) VALUES(?1, 54, ?2)",
                params![day, now_ms()],
            )?;
            conn.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1, ?2, 50, 212, 52, 8, 'watch'),
                        (?3, ?4, 0, 38, 0, 0, 'watch'),
                        (?5, ?6, 0, 45, 2, 0, 'watch'),
                        (?7, ?8, 0, 23, 0, 0, 'watch')",
                params![
                    main_start, main_end,
                    nap.0, nap.1,
                    rest.0, rest.1,
                    doze.0, doze.1
                ],
            )?;
            for (start, end, bpm) in [
                (main_start, main_end, 57),
                (nap.0, nap.1, 66),
                (rest.0, rest.1, 88),
                (doze.0, doze.1, 80),
            ] {
                for i in 0..10 {
                    let ts = start + (end - start) * i / 10;
                    conn.execute(
                        "INSERT INTO heart_rate_points(ts_ms, bpm) VALUES(?1, ?2)",
                        params![ts, bpm],
                    )?;
                }
            }
            Ok(())
        })
        .unwrap();

        let summary = sleep_summary(day).unwrap().unwrap();
        assert_eq!(summary.total_minutes, 352, "314 主睡眠 + 38 午睡");
        assert_eq!(summary.nap_minutes, 38);

        with_conn(|conn| recompute_sleep_daily_metrics(conn)).unwrap();
        with_conn(|conn| {
            let total: f64 = conn.query_row(
                "SELECT sleep_minutes FROM daily_metrics WHERE date_day = ?1",
                params![day],
                |r| r.get(0),
            )?;
            assert_eq!(total, 352.0);
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn v7_migration_recovers_unanchored_nap_from_v6_database() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-v7-nap-migration-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let conn = Connection::open(&path).unwrap();
        init_schema(&conn).unwrap();

        let day_start = Local
            .with_ymd_and_hms(2026, 11, 7, 0, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let main_start = day_start - 30 * 60_000;
        let main_end = day_start + 7 * 3_600_000;
        let nap_start = day_start + (13 * 3_600 + 24 * 60) * 1000;
        conn.execute(
            "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
             VALUES(?1, ?2, 90, 300, 30, 10, 'watch')",
            params![main_start, main_end],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
             VALUES(?1, ?2, 'sleep', 'watch')",
            params![main_start, main_end],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sleep_stages(start_ms, end_ms, stage, source)
             VALUES(?1, ?2, 'light', 'watch')",
            params![nap_start, nap_start + 38 * 60_000],
        )
        .unwrap();

        // 模拟已经升到 v6、但当时还没有「无锚点午睡」修复的库。
        conn.pragma_update(None, "user_version", 6).unwrap();
        init_schema(&conn).unwrap();

        let sessions: Vec<(i64, f64)> = {
            let mut stmt = conn
                .prepare(
                    "SELECT start_ms, deep_min + light_min + rem_min
                     FROM sleep_sessions ORDER BY start_ms",
                )
                .unwrap();
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
            rows.collect::<rusqlite::Result<Vec<_>>>().unwrap()
        };
        assert_eq!(sessions.len(), 2, "v7 应重建出主睡眠和 38 分钟午睡");
        assert!(
            sessions
                .iter()
                .any(|(start, minutes)| *start == nap_start && (*minutes - 38.0).abs() < 1.0),
            "午睡没有恢复: {sessions:?}"
        );
        let total: f64 = conn
            .query_row(
                "SELECT sleep_minutes FROM daily_metrics WHERE date_day = ?1",
                params![local_epoch_day(main_end)],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(total, 488.0, "450 主睡眠 + 38 午睡");

        drop(conn);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn home_heart_rate_matches_detail_when_display_day_falls_back() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-home-heart-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let today = today_epoch_day();
        let today_start = day_start_ms(today);
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO heart_rate_points(ts_ms, bpm) VALUES(?1, 77), (?2, 66)",
                params![today_start - 2 * 3_600_000, today_start + 8 * 3_600_000],
            )?;
            Ok(())
        })
        .unwrap();

        // 今天还没有日报数据时，首页展示日会回退到昨天；心率仍应取最近一次采样。
        let home = home_summary(today - 1).unwrap();
        let detail = metric_detail("heart_rate", 1).unwrap();
        assert_eq!(home.heart_rate, Some(66));
        assert_eq!(detail.latest, Some(66.0));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn backfills_sleep_stage_minutes_on_open() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-sleep-backfill-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let day = today_epoch_day();
        let start = day_start_ms(day) - 30 * 60_000;
        let later = day_start_ms(day) + 20 * 3_600_000;
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1, ?2, 120, 240, 60, 60, 'watch'),
                        (?3, ?4, 200, 200, 100, 20, 'watch')",
                params![
                    start,
                    start + 480 * 60_000,
                    later,
                    later + 520 * 60_000
                ],
            )?;
            conn.execute(
                "INSERT INTO daily_metrics(date_day, sleep_minutes, deep_sleep_minutes, rem_sleep_minutes)
                 VALUES(?1, 420, 0, 0)",
                [day],
            )?;
            Ok(())
        })
        .unwrap();

        open(path.to_str().unwrap()).unwrap();
        with_conn(|conn| {
            let (deep, rem, awake): (f64, f64, f64) = conn.query_row(
                "SELECT deep_sleep_minutes, rem_sleep_minutes, awake_minutes
                 FROM daily_metrics WHERE date_day = ?1",
                [day],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?;
            assert_eq!(deep, 120.0);
            assert_eq!(rem, 60.0);
            assert_eq!(awake, 60.0);
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn duplicate_sleep_sessions_collapse_to_longest() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-sleep-dedupe-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let start = 1_760_000_000_000i64;
        with_conn(|conn| {
            // 模拟旧版本库：没有唯一索引，实时同步才会反复追加。
            conn.execute("DROP INDEX IF EXISTS idx_sleep_session_unique", [])?;
            conn.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, light_min, source)
                 VALUES(?1, ?2, 30, 'watch'), (?1, ?3, 60, 'watch'), (?1, ?4, 90, 'watch')",
                params![
                    start,
                    start + 30 * 60_000,
                    start + 60 * 60_000,
                    start + 90 * 60_000
                ],
            )?;
            Ok(())
        })
        .unwrap();

        open(path.to_str().unwrap()).unwrap();
        with_conn(|conn| {
            let count: i64 =
                conn.query_row("SELECT COUNT(*) FROM sleep_sessions", [], |r| r.get(0))?;
            let (end, light): (i64, f64) = conn.query_row(
                "SELECT end_ms, light_min FROM sleep_sessions WHERE start_ms = ?1",
                params![start],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            assert_eq!(count, 1);
            assert_eq!(end, start + 90 * 60_000);
            assert_eq!(light, 90.0);

            // 唯一索引生效后，重复重建只会替换，不会继续追加。
            conn.execute(
                "INSERT OR REPLACE INTO sleep_sessions(start_ms, end_ms, light_min, source)
                 VALUES(?1, ?2, 120, 'watch')",
                params![start, start + 120 * 60_000],
            )?;
            let count: i64 =
                conn.query_row("SELECT COUNT(*) FROM sleep_sessions", [], |r| r.get(0))?;
            assert_eq!(count, 1);
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn overlapping_sleep_reimports_collapse_without_losing_nap() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-sleep-overlap-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let start = 1_760_000_000_000i64;
        let end = start + 480 * 60_000;
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, source)
                 VALUES(?1, ?2, 90, 300, 90, 'watch'),
                        (?3, ?2, 90, 300, 90, 'watch'),
                        (?4, ?2, 80, 300, 80, 'watch'),
                        (?5, ?6, 0, 60, 0, 'watch')",
                params![
                    start,
                    end,
                    start + 10 * 60_000,
                    start + 20 * 60_000,
                    start + 12 * 3_600_000,
                    start + 13 * 3_600_000
                ],
            )?;
            Ok(())
        })
        .unwrap();

        with_conn(dedupe_sleep_session_rows).unwrap();
        with_conn(|conn| {
            let count: i64 =
                conn.query_row("SELECT COUNT(*) FROM sleep_sessions", [], |r| r.get(0))?;
            let main_start: i64 = conn.query_row(
                "SELECT start_ms FROM sleep_sessions ORDER BY end_ms - start_ms DESC LIMIT 1",
                [],
                |r| r.get(0),
            )?;
            assert_eq!(count, 2, "重叠的同一晚只保留一条，午睡仍要保留");
            assert_eq!(main_start, start, "保留开始最早、覆盖完整的会话");
            Ok(())
        })
        .unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn manual_measurements_roundtrip() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-test-manual-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        add_weight_record(70.5, 18.0).unwrap();
        let weights = weights(10).unwrap();
        assert_eq!(weights.first().map(|w| w.weight_kg), Some(70.5));

        add_blood_pressure(120, 80, 60).unwrap();
        let bp = blood_pressure_records(10).unwrap();
        assert_eq!(
            bp.first().map(|r| (r.systolic, r.diastolic, r.pulse)),
            Some((120, 80, Some(60)))
        );

        add_blood_glucose(5.6, "fasting").unwrap();
        let glucose = glucose_records(10).unwrap();
        assert_eq!(glucose.first().map(|r| r.value), Some(5.6));
        assert_eq!(
            glucose.first().map(|r| r.measure_type.as_str()),
            Some("fasting")
        );

        assert!(add_weight_record(500.0, 0.0).is_err());
        assert!(add_blood_pressure(10, 200, 0).is_err());
        assert!(add_blood_glucose(100.0, "random").is_err());

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn equipment_fields_roundtrip() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-test-equipment-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let id = equipment_add(
            "Vaporfly",
            "outdoor_run",
            "shoes",
            "Nike",
            "Vaporfly 3",
            1_700_000_000_000,
            true,
            10.0,
            800.0,
            "比赛鞋",
        )
        .unwrap();
        let list = equipment_list().unwrap();
        let item = list.iter().find(|e| e.id == id).unwrap();
        assert_eq!(item.gear_type, "shoes");
        assert_eq!(item.brand, "Nike");
        assert_eq!(item.model, "Vaporfly 3");
        assert_eq!(item.purchase_ms, 1_700_000_000_000);
        assert!(item.is_active);

        equipment_update(
            id,
            "Domane",
            "cycling",
            "bike",
            "Trek",
            "Domane SL5",
            0,
            false,
            0.0,
            5000.0,
            "",
        )
        .unwrap();
        let list = equipment_list().unwrap();
        let item = list.iter().find(|e| e.id == id).unwrap();
        assert_eq!(item.gear_type, "bike");
        assert_eq!(item.brand, "Trek");
        assert!(!item.is_active);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn manual_workout_is_listed_with_its_duration() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-manual-workout-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();
        with_conn(|conn| {
            conn.execute("DELETE FROM workouts", [])?;
            Ok(())
        })
        .unwrap();

        let id = workout_add(
            "户外跑步",
            1_700_000_000_000,
            1800,
            5000.0,
            320,
            140,
            165,
            "[]",
        )
        .unwrap();
        let list = list_workouts("", 10).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, id);
        assert_eq!(list[0].source, "manual");
        assert_eq!(list[0].duration_sec, 1800);
        assert_eq!(list[0].distance_m, 5000.0);
        assert_eq!(list[0].calories, 320);
        assert_eq!(list[0].avg_hr, 140);
        assert_eq!(list[0].max_hr, 165);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn personal_records_group_by_sport_and_use_official_splits() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-personal-records-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();
        with_conn(|conn| {
            conn.execute("DELETE FROM workouts", [])?;
            Ok(())
        })
        .unwrap();

        let run_id = workout_add(
            "running",
            1_700_000_000_000,
            1700,
            5200.0,
            320,
            150,
            170,
            "[]",
        )
        .unwrap();
        let splits = serde_json::json!([
            {"i": 0, "d": 1, "type": 0, "pace": 300, "point": 0, "corr": null},
            {"i": 1, "d": 2, "type": 0, "pace": 310, "point": 0, "corr": null},
            {"i": 2, "d": 3, "type": 0, "pace": 305, "point": 0, "corr": null},
            {"i": 3, "d": 4, "type": 0, "pace": 315, "point": 0, "corr": null},
            {"i": 4, "d": 5, "type": 0, "pace": 320, "point": 0, "corr": null},
            {"i": 5, "d": 5, "type": 0, "pace": 400, "point": 0, "corr": 200}
        ])
        .to_string();
        with_conn(|conn| {
            conn.execute(
                "UPDATE workouts SET total_time_sec = 1700, active_calories = 320,
                                     elevation_gain = 50, splits_json = ?1
                 WHERE id = ?2",
                params![splits, run_id],
            )?;
            Ok(())
        })
        .unwrap();
        let bike_id = workout_add(
            "cycling",
            1_700_003_600_000,
            3600,
            20_000.0,
            500,
            130,
            150,
            "[]",
        )
        .unwrap();
        with_conn(|conn| {
            conn.execute(
                "UPDATE workouts SET elevation_gain = 200 WHERE id = ?1",
                params![bike_id],
            )?;
            Ok(())
        })
        .unwrap();

        let records = personal_records().unwrap();
        let value = |sport: &str, metric: &str| {
            records
                .iter()
                .find(|r| r.sport == sport && r.metric == metric)
                .map(|r| r.value)
        };
        assert!((value("running", "longest").unwrap() - 5.2).abs() < 0.001);
        assert!((value("running", "5k").unwrap() - 1550.0).abs() < 0.5);
        assert!((value("running", "fastest_km").unwrap() - 300.0).abs() < 0.5);
        assert!((value("running", "pace").unwrap() - 326.923).abs() < 0.01);
        assert!((value("cycling", "longest").unwrap() - 20.0).abs() < 0.001);
        assert!((value("cycling", "duration").unwrap() - 3600.0).abs() < 0.5);
        assert_eq!(value("cycling", "5k"), None);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn strength_templates_and_sets_roundtrip() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-test-strength-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let exercises = strength_exercises().unwrap();
        assert_eq!(exercises.len(), DEFAULT_STRENGTH_EXERCISES.len());
        let bench = exercises.iter().find(|e| e.name == "杠铃卧推").unwrap();

        let template_id = strength_save_template(
            0,
            "测试推胸",
            "单元测试",
            &[StrengthTemplateExerciseInput {
                exercise_id: bench.id,
                target_sets: 4,
                target_reps: 8,
                rest_seconds: 90,
                target_weight_kg: Some(60.0),
                notes: String::new(),
            }],
        )
        .unwrap();

        let templates = strength_templates().unwrap();
        let saved = templates.iter().find(|t| t.id == template_id).unwrap();
        assert_eq!(saved.name, "测试推胸");
        assert_eq!(saved.exercises.len(), 1);
        assert_eq!(saved.exercises[0].exercise_name, "杠铃卧推");
        assert_eq!(saved.exercises[0].target_sets, 4);
        assert_eq!(saved.exercises[0].target_weight_kg, Some(60.0));

        strength_save_sets(
            "workout-1",
            &[StrengthSetInput {
                exercise_id: bench.id,
                exercise_name: bench.name.clone(),
                set_number: 1,
                weight_kg: 60.0,
                reps: 8,
                rest_seconds_actual: 90,
                completed_at_ms: 1_700_000_000_000,
            }],
        )
        .unwrap();
        let sets = strength_sets("workout-1").unwrap();
        assert_eq!(sets.len(), 1);
        assert_eq!(sets[0].exercise_name, "杠铃卧推");
        assert_eq!(sets[0].reps, 8);

        strength_delete_template(template_id).unwrap();
        assert!(strength_templates()
            .unwrap()
            .iter()
            .all(|t| t.id != template_id));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn saved_route_roundtrip_and_distance() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path =
            std::env::temp_dir().join(format!("vitaloop-test-routes-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let points = vec![
            GeoPoint {
                lat: 31.2304,
                lon: 121.4737,
            },
            GeoPoint {
                lat: 31.2404,
                lon: 121.4837,
            },
        ];
        let id = save_route("", "滨江环线", &points).unwrap();
        let routes = saved_routes().unwrap();
        let saved = routes.iter().find(|r| r.id == id).unwrap();
        assert_eq!(saved.name, "滨江环线");
        assert_eq!(saved.points.len(), 2);
        // 0.01° 纬度约 1.1 km，纬度+经度各 0.01 应落在 1.1–1.7 km。
        assert!(saved.distance_m > 1_100.0 && saved.distance_m < 1_800.0);

        delete_route(&id).unwrap();
        assert!(saved_routes().unwrap().is_empty());

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn delete_workout_removes_session_and_strength_sets() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-test-delete-workout-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        open(path.to_str().unwrap()).unwrap();

        let id = workout_add("力量训练", 1_700_000_000_000, 600, 0.0, 80, 120, 150, "").unwrap();
        strength_save_sets(
            &id,
            &[StrengthSetInput {
                exercise_id: 1,
                exercise_name: "深蹲".into(),
                set_number: 1,
                weight_kg: 40.0,
                reps: 10,
                rest_seconds_actual: 60,
                completed_at_ms: 1_700_000_000_000,
            }],
        )
        .unwrap();
        assert!(get_workout(&id).unwrap().is_some());
        assert_eq!(strength_sets(&id).unwrap().len(), 1);

        delete_workout(&id).unwrap();
        assert!(get_workout(&id).unwrap().is_none());
        assert!(strength_sets(&id).unwrap().is_empty());
        // 手表全量同步会重发同一场运动：墓碑必须把它挡掉。
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO workouts(id, source, sport, start_ms, end_ms)
                 VALUES('watch-9-1700000030', 'watch', '力量训练', ?1, ?2)",
                params![1_700_000_030_000i64, 1_700_000_630_000i64],
            )?;
            Ok(())
        })
        .unwrap();
        assert!(get_workout("watch-9-1700000030").unwrap().is_none());
        // 两分钟以外的同类型运动不是同一场，不能被误伤。
        let other = workout_add("力量训练", 1_700_000_300_000, 600, 0.0, 80, 120, 150, "").unwrap();
        assert!(get_workout(&other).unwrap().is_some());

        let _ = std::fs::remove_file(&path);
    }
}
