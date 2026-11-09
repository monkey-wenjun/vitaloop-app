use anyhow::Result;
use chrono::{Local, TimeZone};
use rusqlite::params;

use crate::store::{self, with_conn};

struct Lcg(u64);

impl Lcg {
    fn new(seed: u64) -> Self {
        Self(seed)
    }
    fn next(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        ((self.0 >> 33) as f64) / (u32::MAX as f64)
    }
    fn range(&mut self, min: f64, max: f64) -> f64 {
        min + (max - min) * self.next()
    }
}

fn hourly_ms(day: i64, hour: u32, minute: u32) -> i64 {
    let date = store::date_of_epoch_day(day);
    let dt = Local
        .from_local_datetime(&date.and_hms_opt(hour, minute, 0).unwrap())
        .earliest()
        .or_else(|| {
            Local
                .from_local_datetime(&date.and_hms_opt(hour, minute, 0).unwrap())
                .latest()
        });
    dt.map(|d| d.timestamp_millis()).unwrap_or(day * 86_400_000)
}

fn make_track(start_ms: i64, sport: &str, seed: u64) -> String {
    let center_lat = 30.2741;
    let center_lon = 120.1551;
    let radius_lat = if sport == "cycling" { 0.017 } else { 0.009 };
    let radius_lon = radius_lat * 1.15;
    let points = if sport == "strength" { 0 } else { 140 };
    let mut lcg = Lcg::new(seed);
    let mut out = String::from("[");
    for i in 0..points {
        let t = i as f64 / points as f64 * std::f64::consts::TAU;
        let wobble = 1.0 + 0.08 * (t * 3.0).sin();
        let lat = center_lat + radius_lat * t.sin() * wobble + lcg.range(-0.0004, 0.0004);
        let lon = center_lon + radius_lon * t.cos() * wobble + lcg.range(-0.0004, 0.0004);
        let alt = 12.0 + 8.0 * (t * 2.0).sin() + lcg.range(-1.0, 1.0);
        if i > 0 {
            out.push(',');
        }
        out.push_str(&format!(
            "{{\"lat\":{lat:.6},\"lon\":{lon:.6},\"alt\":{alt:.1},\"ts\":{}}}",
            start_ms + i as i64 * 1000 * 8
        ));
    }
    out.push(']');
    out
}

fn make_samples(start_ms: i64, duration_sec: i64, avg_hr: i64, max_hr: i64, seed: u64) -> String {
    let mut lcg = Lcg::new(seed);
    let count = (duration_sec / 10).max(10);
    let mut out = String::from("[");
    for i in 0..count {
        let progress = i as f64 / count as f64;
        let warmup = (progress * 6.0).min(1.0);
        let wave = (progress * std::f64::consts::TAU * 2.4).sin() * 9.0;
        let hr = (avg_hr as f64 - 8.0) * warmup + wave + lcg.range(-4.0, 4.0) + 8.0;
        let hr = hr.clamp(62.0, max_hr as f64 + 2.0).round() as i64;
        if i > 0 {
            out.push(',');
        }
        out.push_str(&format!("{{\"t\":{},\"hr\":{hr}}}", start_ms + i * 10_000));
    }
    out.push(']');
    out
}

pub fn seed_demo() -> Result<()> {
    let today = store::today_epoch_day();
    let mut lcg = Lcg::new(0x5EED_2026);

    with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch("DELETE FROM daily_metrics; DELETE FROM hrv_records; DELETE FROM sleep_sessions; DELETE FROM heart_rate_points; DELETE FROM workouts; DELETE FROM weight_records; DELETE FROM devices; DELETE FROM profile;")?;

        for offset in (1..=35).rev() {
            let day = today - offset;
            let (resting, hrv, sleep, deep, stress, temp) = if offset == 1 {
                (60.0, 53.0, 440.0, 90.0, 30.0, 33.45)
            } else {
                (
                    lcg.range(59.5, 62.0),
                    lcg.range(43.0, 50.0),
                    lcg.range(395.0, 465.0),
                    lcg.range(66.0, 98.0),
                    lcg.range(24.0, 38.0),
                    lcg.range(33.25, 33.55),
                )
            };
            let steps = 5200 + (lcg.next() * 6400.0) as i64;
            let active_cal = 260 + (lcg.next() * 380.0) as i64;
            let active_minutes = 18 + (lcg.next() * 48.0) as i64;
            let distance = (steps as f64 * 0.72) as i64;
            tx.execute(
                "INSERT INTO daily_metrics(date_day, steps, calories, active_calories, distance_m, active_minutes,
                    resting_hr, sleep_minutes, deep_sleep_minutes, rem_sleep_minutes, awake_minutes,
                    hrv_ms, stress, spo2, skin_temp_c, updated_ms)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)",
                params![
                    day,
                    steps,
                    active_cal + 1500,
                    active_cal,
                    distance,
                    active_minutes,
                    resting,
                    sleep,
                    deep,
                    sleep * 0.22,
                    18.0,
                    hrv,
                    stress,
                    lcg.range(95.5, 98.5),
                    temp,
                    hourly_ms(day, 8, 0)
                ],
            )?;

            tx.execute(
                "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
                 VALUES(?1,?2,?3,?4,?5,?6,'watch')",
                params![
                    hourly_ms(day - 1, 23, 18),
                    hourly_ms(day, 6, 40),
                    deep,
                    sleep - deep - sleep * 0.22,
                    sleep * 0.22,
                    18.0
                ],
            )?;

            tx.execute(
                "INSERT INTO hrv_records(date_day, at_sec, hrv_ms, heart_rate, stress, quality, source)
                 VALUES(?1,?2,?3,?4,?5,'good','watch')",
                params![
                    day,
                    hourly_ms(day, 6, 30) / 1000,
                    hrv,
                    resting + 2.0,
                    stress
                ],
            )?;

            tx.execute(
                "INSERT OR REPLACE INTO heart_rate_points(ts_ms, bpm, synced) VALUES(?1,?2,1)",
                params![hourly_ms(day, 6, 30), (resting + 3.0).round() as i64],
            )?;
        }

        // 今天：与设计稿一致的示例数据
        tx.execute(
            "INSERT INTO daily_metrics(date_day, steps, calories, active_calories, distance_m, active_minutes,
                resting_hr, sleep_minutes, deep_sleep_minutes, rem_sleep_minutes, awake_minutes,
                hrv_ms, stress, spo2, skin_temp_c, updated_ms)
             VALUES(?1,8432,1986,612,6120,52,59,432,87,96,18,56,28,97,33.75,?2)",
            params![today, hourly_ms(today, 11, 42)],
        )?;
        tx.execute(
            "INSERT INTO sleep_sessions(start_ms, end_ms, deep_min, light_min, rem_min, awake_min, source)
             VALUES(?1,?2,87,249,96,18,'watch')",
            params![hourly_ms(today - 1, 23, 2), hourly_ms(today, 6, 32)],
        )?;
        tx.execute(
            "INSERT INTO hrv_records(date_day, at_sec, hrv_ms, heart_rate, stress, quality, source)
             VALUES(?1,?2,56,61,28,'good','watch')",
            params![today, hourly_ms(today, 6, 30) / 1000],
        )?;

        // 今日心率：睡眠段 + 白天
        for i in 0..288 {
            let ts = hourly_ms(today, 0, 0) + i * 5 * 60_000;
            let bpm = if ts < hourly_ms(today, 6, 30) {
                58 + (lcg.next() * 8.0) as i64
            } else if ts < hourly_ms(today, 8, 0) {
                66 + (lcg.next() * 12.0) as i64
            } else {
                72 + (lcg.next() * 22.0) as i64
            };
            tx.execute(
                "INSERT OR REPLACE INTO heart_rate_points(ts_ms, bpm, synced) VALUES(?1,?2,1)",
                params![ts, bpm],
            )?;
        }

        struct DemoWorkout {
            id: &'static str,
            source: &'static str,
            sport: &'static str,
            day_offset: i64,
            hour: u32,
            minute: u32,
            minutes: i64,
            distance_km: f64,
            calories: i64,
            avg_hr: i64,
            max_hr: i64,
            load: i64,
            synced: bool,
        }

        let workouts = [
            DemoWorkout {
                id: "demo-run-1",
                source: "watch",
                sport: "outdoor_run",
                day_offset: 0,
                hour: 6,
                minute: 12,
                minutes: 32,
                distance_km: 5.24,
                calories: 412,
                avg_hr: 152,
                max_hr: 174,
                load: 96,
                synced: false,
            },
            DemoWorkout {
                id: "demo-strength-1",
                source: "watch",
                sport: "strength",
                day_offset: 0,
                hour: 18,
                minute: 5,
                minutes: 41,
                distance_km: 0.0,
                calories: 260,
                avg_hr: 118,
                max_hr: 146,
                load: 54,
                synced: false,
            },
            DemoWorkout {
                id: "demo-cycle-1",
                source: "phone",
                sport: "cycling",
                day_offset: 1,
                hour: 19,
                minute: 5,
                minutes: 38,
                distance_km: 12.6,
                calories: 380,
                avg_hr: 138,
                max_hr: 166,
                load: 72,
                synced: true,
            },
            DemoWorkout {
                id: "demo-run-2",
                source: "watch",
                sport: "outdoor_run",
                day_offset: 3,
                hour: 7,
                minute: 2,
                minutes: 48,
                distance_km: 8.02,
                calories: 623,
                avg_hr: 149,
                max_hr: 171,
                load: 118,
                synced: true,
            },
            DemoWorkout {
                id: "demo-walk-1",
                source: "phone",
                sport: "walk",
                day_offset: 5,
                hour: 20,
                minute: 10,
                minutes: 42,
                distance_km: 3.6,
                calories: 186,
                avg_hr: 101,
                max_hr: 122,
                load: 28,
                synced: true,
            },
            DemoWorkout {
                id: "demo-run-3",
                source: "watch",
                sport: "outdoor_run",
                day_offset: 8,
                hour: 6,
                minute: 40,
                minutes: 61,
                distance_km: 10.01,
                calories: 788,
                avg_hr: 151,
                max_hr: 178,
                load: 142,
                synced: true,
            },
            DemoWorkout {
                id: "demo-hike-1",
                source: "watch",
                sport: "hiking",
                day_offset: 12,
                hour: 9,
                minute: 0,
                minutes: 130,
                distance_km: 8.6,
                calories: 692,
                avg_hr: 112,
                max_hr: 141,
                load: 88,
                synced: true,
            },
            DemoWorkout {
                id: "demo-run-4",
                source: "watch",
                sport: "indoor_run",
                day_offset: 16,
                hour: 21,
                minute: 15,
                minutes: 30,
                distance_km: 5.0,
                calories: 390,
                avg_hr: 146,
                max_hr: 169,
                load: 82,
                synced: true,
            },
        ];

        for (i, w) in workouts.iter().enumerate() {
            let start = hourly_ms(today - w.day_offset, w.hour, w.minute);
            let end = start + w.minutes * 60_000;
            let track = make_track(start, w.sport, 0xA11CE + i as u64);
            let samples =
                make_samples(start, w.minutes * 60, w.avg_hr, w.max_hr, 0xBEEF + i as u64);
            tx.execute(
                "INSERT INTO workouts(id, source, sport, start_ms, end_ms, distance_m, calories, avg_hr, max_hr,
                    steps, load, aerobic_effect, recovery_time_min, track_json, samples_json, synced, created_ms)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)",
                params![
                    w.id,
                    w.source,
                    w.sport,
                    start,
                    end,
                    w.distance_km * 1000.0,
                    w.calories,
                    w.avg_hr,
                    w.max_hr,
                    (w.distance_km * 1300.0) as i64,
                    w.load,
                    3.1 + (w.load as f64 / 100.0),
                    (w.load / 3).max(6),
                    track,
                    samples,
                    if w.synced { 1 } else { 0 },
                    end
                ],
            )?;
        }

        let weights = [
            (0, 64.8, 17.2, 42.1, 55.4),
            (7, 64.9, 17.4, 41.9, 55.2),
            (14, 65.1, 17.5, 41.8, 55.1),
            (21, 65.3, 17.7, 41.6, 55.0),
            (28, 65.4, 17.8, 41.5, 54.9),
            (35, 65.6, 18.0, 41.3, 54.8),
        ];
        for (offset, kg, fat, muscle, water) in weights {
            tx.execute(
                "INSERT INTO weight_records(id, timestamp_ms, weight_kg, body_fat_percent, muscle_percent, water_percent, source)
                 VALUES(?1,?2,?3,?4,?5,?6,'scale')",
                params![
                    format!("demo-weight-{offset}"),
                    hourly_ms(today - offset, 7, 10),
                    kg,
                    fat,
                    muscle,
                    water
                ],
            )?;
        }

        tx.execute(
            "INSERT OR REPLACE INTO devices(id, name, kind, address, battery, last_sync_ms, connected)
             VALUES('gt5', 'HUAWEI WATCH GT 5', 'watch', 'C8:3F:26:1A:7B:04', 86, ?1, 1)",
            params![hourly_ms(today, 11, 42)],
        )?;
        tx.execute(
            "INSERT OR REPLACE INTO devices(id, name, kind, address, battery, last_sync_ms, connected)
             VALUES('band9', '小米手环 9', 'band', 'E4:AA:5D:88:10:2F', 64, ?1, 0)",
            params![hourly_ms(today - 2, 9, 20)],
        )?;

        tx.execute(
            "INSERT OR REPLACE INTO profile(id, nickname, gender, height_cm, weight_kg, birth_date, email)
             VALUES(1, 'Awen', 'male', 175, 64.8, '1992-04-18', 'hi@example.com')",
            [],
        )?;

        let defaults = [
            ("demo_data", "1"),
            ("theme", "system"),
            ("steps_goal", "10000"),
            ("calories_goal", "500"),
            ("exercise_goal", "30"),
            ("auto_sync", "1"),
            ("unit_distance", "km"),
        ];
        for (k, v) in defaults {
            tx.execute(
                "INSERT INTO settings(key, value) VALUES(?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![k, v],
            )?;
        }

        tx.commit()?;
        Ok(())
    })
}

pub fn clear_demo() -> Result<()> {
    with_conn(|conn| {
        let tx = conn.unchecked_transaction()?;
        let like = "demo-%";
        tx.execute("DELETE FROM workouts WHERE id LIKE ?1", params![like])?;
        tx.execute("DELETE FROM weight_records WHERE id LIKE ?1", params![like])?;
        tx.execute("DELETE FROM devices WHERE id IN ('gt5','band9')", [])?;
        tx.execute("DELETE FROM daily_metrics", [])?;
        tx.execute("DELETE FROM hrv_records", [])?;
        tx.execute("DELETE FROM sleep_sessions", [])?;
        tx.execute("DELETE FROM heart_rate_points", [])?;
        tx.execute("DELETE FROM profile", [])?;
        tx.execute(
            "UPDATE settings SET value = '0' WHERE key = 'demo_data'",
            [],
        )?;
        tx.commit()?;
        Ok(())
    })
}
