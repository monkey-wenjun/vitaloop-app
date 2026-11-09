use anyhow::Result;
use rusqlite::types::Value;
use rusqlite::OptionalExtension;
use serde_json::{json, Map, Number, Value as JsonValue};
use std::collections::HashSet;

use crate::store;

/// 只同步业务数据。账号、登录态、临时导入游标留在本机。
pub(crate) const TABLES: &[&str] = &[
    "daily_metrics",
    "hrv_records",
    "sleep_hrv_records",
    "sleep_sessions",
    "heart_rate_points",
    "step_samples",
    "weight_records",
    "workouts",
    "workout_tombstones",
    "profile",
    "settings",
    "devices",
    "metric_points",
    "blood_pressure_records",
    "blood_glucose_records",
    "arrhythmia_records",
    "sleep_stages",
    "sleep_bed",
    "emotion_records",
    "equipment",
    "strength_exercises",
    "strength_templates",
    "strength_template_exercises",
    "strength_workout_sets",
    "apnea_records",
    "hourly_status",
    "daily_rings",
    "saved_routes",
    "saved_route_tombstones",
    "health_record_tombstones",
];

const PRIVATE_SETTINGS: &[&str] = &[
    "signed_in",
    "account_email",
    "guest",
    "cloud_account_id",
    "cloud_token",
    "cloud_last_sync_ms",
    "cloud_sync_seq",
    "legacy_import_version",
    "legacy_db_mtime",
    "p2p_backfill_done",
    "legacy_extra_backfill_done",
    "legacy_backfill_v2_done",
];

fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn table_columns(conn: &rusqlite::Connection, table: &str) -> Result<Vec<String>> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({})", quote_ident(table)))?;
    let rows = stmt.query_map([], |r| r.get::<_, String>(1))?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

fn table_pk_columns(conn: &rusqlite::Connection, table: &str) -> Result<Vec<String>> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({})", quote_ident(table)))?;
    let rows = stmt.query_map([], |r| {
        Ok((r.get::<_, String>(1)?, r.get::<_, i64>(5)?))
    })?;
    let mut keys = rows
        .collect::<rusqlite::Result<Vec<_>>>()?
        .into_iter()
        .filter(|(_, pk)| *pk > 0)
        .collect::<Vec<_>>();
    keys.sort_by_key(|(_, pk)| *pk);
    Ok(keys.into_iter().map(|(name, _)| name).collect())
}

/// 给所有同步表装变更触发器。触发器只记主键，不复制整行数据：
/// 增量上传时再按主键回表取当前值，避免心跳/步数这类高频小写入
/// 在变更日志里留下几百份重复的大 JSON。
pub(crate) fn install_sync_triggers(conn: &rusqlite::Connection) -> Result<()> {
    for table in TABLES {
        let pk = table_pk_columns(conn, table)?;
        if pk.is_empty() {
            continue;
        }
        let new_key = pk
            .iter()
            .map(|c| format!("NEW.{}", quote_ident(c)))
            .collect::<Vec<_>>()
            .join(", ");
        let old_key = pk
            .iter()
            .map(|c| format!("OLD.{}", quote_ident(c)))
            .collect::<Vec<_>>()
            .join(", ");
        let qtable = quote_ident(table);
        let name = table.replace('"', "");
        for (suffix, timing, key) in [
            ("ai", "INSERT", &new_key),
            ("au", "UPDATE", &new_key),
            ("ad", "DELETE", &old_key),
        ] {
            let deleted = if suffix == "ad" { 1 } else { 0 };
            let trigger = format!("sync_log_{name}_{suffix}");
            conn.execute_batch(&format!(
                "CREATE TRIGGER IF NOT EXISTS {trigger}
                 AFTER {timing} ON {qtable}
                 BEGIN
                   INSERT INTO sync_changelog(table_name, pk, deleted)
                   VALUES ('{table}', json_array({key}), {deleted});
                 END;"
            ))?;
        }
    }
    Ok(())
}

fn value_to_json(v: rusqlite::types::ValueRef<'_>) -> JsonValue {
    match v {
        rusqlite::types::ValueRef::Null => JsonValue::Null,
        rusqlite::types::ValueRef::Integer(i) => JsonValue::Number(i.into()),
        rusqlite::types::ValueRef::Real(f) => Number::from_f64(f)
            .map(JsonValue::Number)
            .unwrap_or(JsonValue::Null),
        rusqlite::types::ValueRef::Text(t) => {
            JsonValue::String(String::from_utf8_lossy(t).to_string())
        }
        rusqlite::types::ValueRef::Blob(b) => {
            json!({"$blob": b.iter().map(|v| *v).collect::<Vec<_>>()})
        }
    }
}

pub fn export_account_data() -> Result<String> {
    store::with_conn(|conn| {
        let mut tables = Map::new();
        for table in TABLES {
            let columns = table_columns(conn, table)?;
            if columns.is_empty() {
                continue;
            }
            let select = columns
                .iter()
                .map(|c| quote_ident(c))
                .collect::<Vec<_>>()
                .join(",");
            let key_index = columns.iter().position(|c| c == "key");
            let mut stmt = conn.prepare(&format!("SELECT {select} FROM {}", quote_ident(table)))?;
            let mut rows = stmt.query([])?;
            let mut out_rows: Vec<JsonValue> = Vec::new();
            while let Some(row) = rows.next()? {
                if *table == "settings" {
                    if let Some(index) = key_index {
                        let key = row.get::<_, String>(index).unwrap_or_default();
                        if PRIVATE_SETTINGS.contains(&key.as_str()) {
                            continue;
                        }
                    }
                }
                let mut values = Vec::with_capacity(columns.len());
                for i in 0..columns.len() {
                    values.push(value_to_json(row.get_ref(i)?));
                }
                out_rows.push(JsonValue::Array(values));
            }
            tables.insert(
                table.to_string(),
                json!({"columns": columns, "rows": out_rows}),
            );
        }
        Ok(json!({
            "version": 1,
            "exported_ms": chrono::Utc::now().timestamp_millis(),
            "tables": tables,
        })
        .to_string())
    })
}

/// 本机变更日志里最大的序号。全量上传前先记下来，上传成功后只清到这个
/// 序号，上传期间新写入的数据仍然留给下一轮增量。
pub fn account_delta_max_seq() -> Result<i64> {
    store::with_conn(|conn| {
        Ok(conn.query_row(
            "SELECT COALESCE(MAX(seq), 0) FROM sync_changelog",
            [],
            |r| r.get(0),
        )?)
    })
}

pub fn clear_account_delta(through_seq: i64) -> Result<usize> {
    store::with_conn(|conn| {
        Ok(conn.execute(
            "DELETE FROM sync_changelog WHERE seq <= ?1",
            rusqlite::params![through_seq],
        )?)
    })
}

/// 导出 since_seq 之后的增量：按主键合并同一行的多次修改，只回表取
/// 最终存在的行；删除只带主键。没有变更时 tables 为空。
pub fn export_account_delta(since_seq: i64) -> Result<String> {
    export_account_delta_inner(since_seq, None)
}

/// 分块导出：一次最多处理 [max_entries] 条变更日志，避免积压很多变更时
/// 一次生成几十 MB JSON 把手机内存和网络打满。返回的 max_seq 只推进到
/// 本次实际处理的位置，剩余变更下一轮继续。
pub fn export_account_delta_limited(since_seq: i64, max_entries: i64) -> Result<String> {
    let limit = max_entries.clamp(1, 20_000);
    export_account_delta_inner(since_seq, Some(limit))
}

fn export_account_delta_inner(since_seq: i64, limit: Option<i64>) -> Result<String> {
    store::with_conn(|conn| {
        let sql = match limit {
            Some(_) => {
                "SELECT seq, table_name, pk, deleted
                 FROM sync_changelog
                 WHERE seq > ?1
                 ORDER BY seq
                 LIMIT ?2"
            }
            None => {
                "SELECT seq, table_name, pk, deleted
                 FROM sync_changelog
                 WHERE seq > ?1
                 ORDER BY seq"
            }
        };
        let mut stmt = conn.prepare(sql)?;
        let mapper = |r: &rusqlite::Row<'_>| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, i64>(3)? != 0,
            ))
        };
        let rows = match limit {
            Some(limit) => {
                stmt.query_map(rusqlite::params![since_seq, limit], mapper)?
                    .collect::<std::result::Result<Vec<_>, _>>()?
            }
            None => stmt
                .query_map(rusqlite::params![since_seq], mapper)?
                .collect::<std::result::Result<Vec<_>, _>>()?,
        };
        let mut max_seq = since_seq;
        // table -> pk JSON -> (seq, deleted, key values)
        let mut changed: std::collections::HashMap<
            String,
            std::collections::HashMap<String, (i64, bool, Vec<JsonValue>)>,
        > = std::collections::HashMap::new();
        for row in rows {
            let (seq, table, pk, deleted) = row;
            max_seq = max_seq.max(seq);
            let values: Vec<JsonValue> = serde_json::from_str(&pk)?;
            changed
                .entry(table)
                .or_default()
                .insert(pk, (seq, deleted, values));
        }

        let mut tables = Map::new();
        for table in TABLES {
            let Some(entries) = changed.get(*table) else {
                continue;
            };
            let columns = table_columns(conn, table)?;
            let pk_columns = table_pk_columns(conn, table)?;
            if columns.is_empty() || pk_columns.is_empty() {
                continue;
            }
            let mut latest = entries.values().collect::<Vec<_>>();
            latest.sort_by_key(|(seq, _, _)| *seq);
            let mut out_rows = Vec::new();
            let mut deletes = Vec::new();
            for (_, deleted, key) in latest {
                if *table == "settings" && key.len() == 1 {
                    let key = key[0].as_str().unwrap_or_default();
                    if PRIVATE_SETTINGS.contains(&key) {
                        continue;
                    }
                }
                if key.len() != pk_columns.len() {
                    continue;
                }
                if *deleted {
                    deletes.push(JsonValue::Array(key.clone()));
                    continue;
                }
                let where_sql = pk_columns
                    .iter()
                    .enumerate()
                    .map(|(i, c)| format!("{} IS ?{}", quote_ident(c), i + 1))
                    .collect::<Vec<_>>()
                    .join(" AND ");
                let select = columns
                    .iter()
                    .map(|c| quote_ident(c))
                    .collect::<Vec<_>>()
                    .join(",");
                let sql = format!(
                    "SELECT {select} FROM {} WHERE {where_sql}",
                    quote_ident(table)
                );
                let params = key
                    .iter()
                    .map(json_to_value)
                    .collect::<Result<Vec<_>>>()?;
                let mut stmt = conn.prepare(&sql)?;
                let found = stmt
                    .query_row(rusqlite::params_from_iter(params.iter()), |row| {
                        let mut values = Vec::with_capacity(columns.len());
                        for i in 0..columns.len() {
                            values.push(value_to_json(row.get_ref(i)?));
                        }
                        Ok(JsonValue::Array(values))
                    })
                    .optional()?;
                if let Some(values) = found {
                    out_rows.push(values);
                }
            }
            if out_rows.is_empty() && deletes.is_empty() {
                continue;
            }
            tables.insert(
                (*table).to_string(),
                json!({
                    "key": pk_columns,
                    "columns": columns,
                    "rows": out_rows,
                    "deletes": deletes,
                }),
            );
        }
        Ok(json!({
            "version": 2,
            "max_seq": max_seq,
            "tables": tables,
        })
        .to_string())
    })
}

fn json_to_value(v: &JsonValue) -> Result<Value> {
    Ok(match v {
        JsonValue::Null => Value::Null,
        JsonValue::Bool(b) => Value::Integer(if *b { 1 } else { 0 }),
        JsonValue::Number(n) => {
            if let Some(i) = n.as_i64() {
                Value::Integer(i)
            } else {
                Value::Real(n.as_f64().unwrap_or(0.0))
            }
        }
        JsonValue::String(s) => Value::Text(s.clone()),
        JsonValue::Array(a) => Value::Blob(
            a.iter()
                .filter_map(|v| v.as_u64())
                .map(|v| v as u8)
                .collect(),
        ),
        JsonValue::Object(o) => {
            if let Some(JsonValue::Array(a)) = o.get("$blob") {
                Value::Blob(
                    a.iter()
                        .filter_map(|v| v.as_u64())
                        .map(|v| v as u8)
                        .collect(),
                )
            } else {
                Value::Text(v.to_string())
            }
        }
    })
}

pub fn import_account_data(payload: String) -> Result<usize> {
    let parsed: JsonValue = serde_json::from_str(&payload)?;
    let tables = parsed
        .get("tables")
        .and_then(|v| v.as_object())
        .ok_or_else(|| anyhow::anyhow!("missing tables"))?;
    store::with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        let mut imported = 0usize;
        for table in TABLES {
            let Some(block) = tables.get(*table).and_then(|v| v.as_object()) else {
                continue;
            };
            let actual = table_columns(&tx, table)?;
            let actual_set: HashSet<&str> = actual.iter().map(|s| s.as_str()).collect();
            let columns: Vec<String> = block
                .get("columns")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default();
            if columns.is_empty() || columns.iter().any(|c| !actual_set.contains(c.as_str())) {
                continue;
            }
            let placeholders = (1..=columns.len())
                .map(|i| format!("?{i}"))
                .collect::<Vec<_>>()
                .join(",");
            let has_id = columns.iter().any(|c| c == "id");
            let sql = if *table == "weight_records" && has_id {
                // 体脂秤历史行在云端旧快照里可能缺少阻抗/体成分；直接
                // INSERT OR REPLACE 会把本机刚迁移出来的非空字段抹掉。
                // 空值不覆盖本机已有值，非空值仍以云端为准。
                let updates = columns
                    .iter()
                    .filter(|c| c.as_str() != "id")
                    .map(|c| {
                        format!(
                            "{} = COALESCE(excluded.{}, weight_records.{})",
                            quote_ident(c),
                            quote_ident(c),
                            quote_ident(c)
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(",");
                format!(
                    "INSERT INTO {} ({}) VALUES ({}) ON CONFLICT(id) DO UPDATE SET {}",
                    quote_ident(table),
                    columns
                        .iter()
                        .map(|c| quote_ident(c))
                        .collect::<Vec<_>>()
                        .join(","),
                    placeholders,
                    updates
                )
            } else if *table == "workouts" && has_id {
                // 云端旧快照里的同一场运动可能没有轨迹/逐点心率，直接整行
                // REPLACE 会把刚从旧版补拉并迁移出来的 JSON 覆盖成空。
                // 这几个 JSON 列只在云端版本更长（更完整）时才替换。
                let json_columns = [
                    "track_json",
                    "samples_json",
                    "detail_json",
                    "dynamics_json",
                    "altitude_json",
                    "recovery_json",
                ];
                let updates = columns
                    .iter()
                    .filter(|c| c.as_str() != "id")
                    .map(|c| {
                        let col = quote_ident(c);
                        if json_columns.contains(&c.as_str()) {
                            format!(
                                "{col} = CASE WHEN excluded.{col} IS NOT NULL \
                                 AND excluded.{col} <> '' AND excluded.{col} <> '[]' \
                                 AND length(excluded.{col}) >= COALESCE(length(workouts.{col}), 0) \
                                 THEN excluded.{col} ELSE workouts.{col} END"
                            )
                        } else {
                            format!("{col} = excluded.{col}")
                        }
                    })
                    .collect::<Vec<_>>()
                    .join(",");
                format!(
                    "INSERT INTO {} ({}) VALUES ({}) ON CONFLICT(id) DO UPDATE SET {}",
                    quote_ident(table),
                    columns
                        .iter()
                        .map(|c| quote_ident(c))
                        .collect::<Vec<_>>()
                        .join(","),
                    placeholders,
                    updates
                )
            } else {
                format!(
                    "INSERT OR REPLACE INTO {} ({}) VALUES ({})",
                    quote_ident(table),
                    columns
                        .iter()
                        .map(|c| quote_ident(c))
                        .collect::<Vec<_>>()
                        .join(","),
                    placeholders
                )
            };
            let Some(rows) = block.get("rows").and_then(|v| v.as_array()) else {
                continue;
            };
            let key_index = columns.iter().position(|c| c == "key");
            for row in rows {
                let Some(values) = row.as_array() else {
                    continue;
                };
                if values.len() < columns.len() {
                    continue;
                }
                if *table == "settings" {
                    if let Some(idx) = key_index {
                        let key = values[idx].as_str().unwrap_or("");
                        if PRIVATE_SETTINGS.contains(&key) {
                            continue;
                        }
                    }
                }
                let params: Vec<Value> = values[..columns.len()]
                    .iter()
                    .map(json_to_value)
                    .collect::<Result<Vec<_>>>()?;
                tx.execute(&sql, rusqlite::params_from_iter(params.iter()))?;
                imported += 1;
            }
        }
        // 体脂秤一次上秤会拆成毫秒错开的多行，云端旧快照里也可能带着
        // 这些重复行。合并后只保留一条，避免同步一次多出几条。
        crate::legacy::dedupe_weights(&tx)?;
        // 旧版实时同步和手表重建可能把同一晚写成多条高度重叠的睡眠会话。
        // 云端快照原样带回后要先合并，否则每同步一次就多叠一层。
        crate::store::dedupe_sleep_session_rows(&tx)?;
        // 云端快照里可能还留着已删除的运动；墓碑最后统一清理，
        // 本机墓碑也要能压掉这一次从云端带下来的旧行。
        tx.execute(
            "DELETE FROM workouts
             WHERE EXISTS (
               SELECT 1 FROM workout_tombstones t
               WHERE t.sport = workouts.sport
                 AND ABS(t.start_ms - workouts.start_ms) <= 120000
             )",
            [],
        )?;
        // 体重/血压/血糖/路线同样按 id 墓碑清理，避免 A 设备删除后
        // B 设备从云端快照恢复时又冒出来。
        tx.execute(
            "DELETE FROM weight_records
             WHERE id IN (SELECT id FROM health_record_tombstones WHERE kind = 'weight')",
            [],
        )?;
        tx.execute(
            "DELETE FROM blood_pressure_records
             WHERE id IN (SELECT id FROM health_record_tombstones WHERE kind = 'bp')",
            [],
        )?;
        tx.execute(
            "DELETE FROM blood_glucose_records
             WHERE id IN (SELECT id FROM health_record_tombstones WHERE kind = 'glucose')",
            [],
        )?;
        tx.execute(
            "DELETE FROM saved_routes
             WHERE id IN (SELECT id FROM saved_route_tombstones)",
            [],
        )?;
        tx.commit()?;
        Ok(imported)
    })
}

/// 本机有没有值得上传的历史数据（不算空库/示例数据）。
pub fn local_data_count() -> Result<i64> {
    store::with_conn(|conn| {
        let workouts: i64 = conn.query_row("SELECT COUNT(*) FROM workouts", [], |r| r.get(0))?;
        let hr: i64 = conn.query_row("SELECT COUNT(*) FROM heart_rate_points", [], |r| r.get(0))?;
        let metrics: i64 =
            conn.query_row("SELECT COUNT(*) FROM daily_metrics", [], |r| r.get(0))?;
        Ok(workouts + hr + metrics)
    })
}

/// SQLite 的 total_changes() 统计当前连接自打开以来的增删改行数。
/// 每分钟同步前拿它和上次成功同步后的值比较，没写库就不碰 85MB 快照。
pub fn account_data_change_count() -> Result<i64> {
    store::with_conn(|conn| {
        Ok(conn.query_row("SELECT total_changes()", [], |r| r.get(0))?)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blob_roundtrip_shape() {
        let v = json!({"$blob": [1, 2, 255]});
        let out = json_to_value(&v).unwrap();
        match out {
            Value::Blob(b) => assert_eq!(b, vec![1, 2, 255]),
            _ => panic!("not a blob"),
        }
    }

    #[test]
    fn delta_export_only_returns_changes_after_cursor() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = std::env::temp_dir().join(format!(
            "vitaloop-cloud-delta-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        store::open(path.to_str().unwrap()).unwrap();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO heart_rate_points(ts_ms, bpm) VALUES(1000, 70), (2000, 72)",
                [],
            )?;
            conn.execute(
                "INSERT INTO daily_metrics(date_day, steps) VALUES(20000, 1234)",
                [],
            )?;
            Ok(())
        })
        .unwrap();

        let first = export_account_delta(0).unwrap();
        let parsed: JsonValue = serde_json::from_str(&first).unwrap();
        assert!(parsed["tables"]["heart_rate_points"]["rows"]
            .as_array()
            .is_some_and(|rows| rows.len() == 2));
        let cursor = parsed["max_seq"].as_i64().unwrap();
        assert_eq!(clear_account_delta(cursor).unwrap(), 3);

        store::with_conn(|conn| {
            conn.execute(
                "INSERT OR REPLACE INTO settings(key, value)
                 VALUES('cloud_last_sync_ms', '123')",
                [],
            )?;
            Ok(())
        })
        .unwrap();
        let empty = export_account_delta(cursor).unwrap();
        let parsed: JsonValue = serde_json::from_str(&empty).unwrap();
        assert!(parsed["tables"].as_object().unwrap().is_empty());

        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO heart_rate_points(ts_ms, bpm) VALUES(3000, 75)",
                [],
            )?;
            Ok(())
        })
        .unwrap();
        let next = export_account_delta(cursor).unwrap();
        let parsed: JsonValue = serde_json::from_str(&next).unwrap();
        let rows = parsed["tables"]["heart_rate_points"]["rows"]
            .as_array()
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0][0].as_i64(), Some(3000));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn import_drops_rows_covered_by_synced_tombstones() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let source = std::env::temp_dir().join(format!(
            "vitaloop-cloud-tombstone-src-{}.db",
            std::process::id()
        ));
        let target = std::env::temp_dir().join(format!(
            "vitaloop-cloud-tombstone-dst-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&source);
        let _ = std::fs::remove_file(&target);

        store::open(source.to_str().unwrap()).unwrap();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO health_record_tombstones(kind, id, deleted_ms)
                 VALUES('weight', 'weight-gone', 1), ('bp', 'bp-gone', 1),
                       ('glucose', 'glucose-gone', 1)",
                [],
            )?;
            conn.execute(
                "INSERT INTO saved_route_tombstones(id, deleted_ms)
                 VALUES('route-gone', 1)",
                [],
            )?;
            Ok(())
        })
        .unwrap();
        let payload = export_account_data().unwrap();

        store::open(target.to_str().unwrap()).unwrap();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO weight_records(id, timestamp_ms, weight_kg)
                 VALUES('weight-gone', 1, 70)",
                [],
            )?;
            conn.execute(
                "INSERT INTO blood_pressure_records(id, timestamp_ms, systolic, diastolic)
                 VALUES('bp-gone', 1, 120, 80)",
                [],
            )?;
            conn.execute(
                "INSERT INTO blood_glucose_records(id, timestamp_ms, value)
                 VALUES('glucose-gone', 1, 5.5)",
                [],
            )?;
            conn.execute(
                "INSERT INTO saved_routes(id, name) VALUES('route-gone', '旧路线')",
                [],
            )?;
            Ok(())
        })
        .unwrap();

        import_account_data(payload).unwrap();

        let remaining: i64 = store::with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT
                   (SELECT COUNT(*) FROM weight_records) +
                   (SELECT COUNT(*) FROM blood_pressure_records) +
                   (SELECT COUNT(*) FROM blood_glucose_records) +
                   (SELECT COUNT(*) FROM saved_routes)",
                [],
                |r| r.get(0),
            )?)
        })
        .unwrap();
        assert_eq!(remaining, 0, "墓碑没有清掉云端带回的已删除记录");

        let _ = std::fs::remove_file(&source);
        let _ = std::fs::remove_file(&target);
    }

    #[test]
    fn import_keeps_local_body_composition_when_remote_is_null() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let source = std::env::temp_dir().join(format!(
            "vitaloop-cloud-weight-src-{}.db",
            std::process::id()
        ));
        let target = std::env::temp_dir().join(format!(
            "vitaloop-cloud-weight-dst-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&source);
        let _ = std::fs::remove_file(&target);

        store::open(source.to_str().unwrap()).unwrap();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO weight_records(id, timestamp_ms, weight_kg, source)
                 VALUES('w1', 1000, 70.0, 'scale')",
                [],
            )?;
            Ok(())
        })
        .unwrap();
        let payload = export_account_data().unwrap();

        store::open(target.to_str().unwrap()).unwrap();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO weight_records(
                   id, timestamp_ms, weight_kg, body_fat_percent,
                   resistance_ohm, body_composition_model, source)
                 VALUES('w1', 1000, 70.0, 19.5, 570.0, 'segal_3a_male_lt20', 'scale')",
                [],
            )?;
            Ok(())
        })
        .unwrap();

        import_account_data(payload).unwrap();

        let (fat, resistance): (Option<f64>, Option<f64>) = store::with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT body_fat_percent, resistance_ohm FROM weight_records WHERE id='w1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?)
        })
        .unwrap();
        assert_eq!(fat, Some(19.5), "云端空值不应抹掉本机体脂");
        assert_eq!(resistance, Some(570.0), "云端空值不应抹掉本机阻抗");

        let _ = std::fs::remove_file(&source);
        let _ = std::fs::remove_file(&target);
    }

    #[test]
    fn import_keeps_richer_local_workout_track() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let source = std::env::temp_dir().join(format!(
            "vitaloop-cloud-workout-src-{}.db",
            std::process::id()
        ));
        let target = std::env::temp_dir().join(format!(
            "vitaloop-cloud-workout-dst-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&source);
        let _ = std::fs::remove_file(&target);

        store::open(source.to_str().unwrap()).unwrap();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO workouts(
                   id, source, sport, start_ms, end_ms, created_ms, track_json)
                 VALUES('legacy-server-1', 'watch', 'running', 1000, 2000, 1, NULL)",
                [],
            )?;
            Ok(())
        })
        .unwrap();
        let payload = export_account_data().unwrap();

        store::open(target.to_str().unwrap()).unwrap();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO workouts(
                   id, source, sport, start_ms, end_ms, created_ms, track_json)
                 VALUES('legacy-server-1', 'watch', 'running', 1000, 2000, 1, ?1)",
                rusqlite::params![
                    r#"[{"lat":30.1,"lon":120.1,"t":1000},{"lat":30.2,"lon":120.2,"t":2000}]"#
                ],
            )?;
            Ok(())
        })
        .unwrap();

        import_account_data(payload).unwrap();

        let track: Option<String> = store::with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT track_json FROM workouts WHERE id='legacy-server-1'",
                [],
                |r| r.get(0),
            )?)
        })
        .unwrap();
        assert!(
            track.as_deref().unwrap_or("").contains("30.2"),
            "云端旧快照不应覆盖本机更完整的轨迹"
        );

        let _ = std::fs::remove_file(&source);
        let _ = std::fs::remove_file(&target);
    }

    #[test]
    fn import_dedupes_scale_rows_from_remote_snapshot() {
        let _guard = store::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let source = std::env::temp_dir().join(format!(
            "vitaloop-cloud-weight-dup-src-{}.db",
            std::process::id()
        ));
        let target = std::env::temp_dir().join(format!(
            "vitaloop-cloud-weight-dup-dst-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&source);
        let _ = std::fs::remove_file(&target);

        store::open(source.to_str().unwrap()).unwrap();
        store::with_conn(|conn| {
            conn.execute(
                "INSERT INTO weight_records(id, timestamp_ms, weight_kg, source)
                 VALUES('w1', 1000, 70.0, 'scale')",
                [],
            )?;
            conn.execute(
                "INSERT INTO weight_records(
                   id, timestamp_ms, weight_kg, body_fat_percent,
                   resistance_ohm, source)
                 VALUES('w2', 1010, 70.0, 19.5, 570.0, 'scale')",
                [],
            )?;
            Ok(())
        })
        .unwrap();
        let payload = export_account_data().unwrap();

        store::open(target.to_str().unwrap()).unwrap();
        import_account_data(payload).unwrap();

        let (count, resistance): (i64, Option<f64>) = store::with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT COUNT(*), MAX(resistance_ohm) FROM weight_records",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?)
        })
        .unwrap();
        assert_eq!(count, 1, "同一次上秤的重复行应合并");
        assert_eq!(resistance, Some(570.0), "合并时应保留阻抗");

        let _ = std::fs::remove_file(&source);
        let _ = std::fs::remove_file(&target);
    }
}
