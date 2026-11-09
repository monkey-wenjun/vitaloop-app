use serde_json::{json, Map, Value};

const AIR_DENSITY: f64 = 1.225;
const DRAG_COEFFICIENT: f64 = 0.7;
const FRONTAL_AREA: f64 = 0.5;
const ROLLING_RESISTANCE_COEFF: f64 = 0.004;
const GRAVITY: f64 = 9.81;
const DRIVE_TRAIN_EFFICIENCY: f64 = 0.98;
const DEFAULT_BIKE_WEIGHT_KG: f64 = 10.0;
const FTP_ESTIMATION_FACTOR: f64 = 0.95;

#[derive(Clone, Copy)]
pub struct PowerParams {
    pub rider_weight_kg: f64,
    pub bike_weight_kg: f64,
    pub wind_speed_kmh: f64,
    pub rolling_resistance_coeff: f64,
}

impl Default for PowerParams {
    fn default() -> Self {
        Self {
            rider_weight_kg: 65.0,
            bike_weight_kg: DEFAULT_BIKE_WEIGHT_KG,
            wind_speed_kmh: 0.0,
            rolling_resistance_coeff: ROLLING_RESISTANCE_COEFF,
        }
    }
}

pub fn watts(speed_kmh: f64, gradient_percent: f64, params: PowerParams) -> f64 {
    let speed_ms = (speed_kmh.max(0.0)) / 3.6;
    let total_weight = params.rider_weight_kg.max(1.0) + params.bike_weight_kg.max(0.0);
    let wind_ms = params.wind_speed_kmh / 3.6;
    let relative_wind_ms = speed_ms + wind_ms;

    let air = 0.5 * AIR_DENSITY * DRAG_COEFFICIENT * FRONTAL_AREA * relative_wind_ms.powi(3);
    let rolling = params.rolling_resistance_coeff.max(0.0) * total_weight * GRAVITY * speed_ms;
    let slope = total_weight * GRAVITY * (gradient_percent / 100.0).atan().sin() * speed_ms;

    ((air + rolling + slope) / DRIVE_TRAIN_EFFICIENCY).max(0.0)
}

fn haversine_meters(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const R: f64 = 6_371_000.0;
    let dlat = (lat2 - lat1).to_radians();
    let dlon = (lon2 - lon1).to_radians();
    let a = (dlat / 2.0).sin().powi(2)
        + lat1.to_radians().cos() * lat2.to_radians().cos() * (dlon / 2.0).sin().powi(2);
    2.0 * R * a.sqrt().asin()
}

#[derive(Clone, Copy)]
struct TrackPoint {
    lat: f64,
    lon: f64,
    alt: f64,
    ts_ms: i64,
    speed_kmh: Option<f64>,
}

pub struct PowerAnalysis {
    pub dynamics_json: String,
    pub stats_json: String,
    pub duration_sec: i64,
}

pub fn analyze_track(
    track_json: &str,
    rider_weight_kg: f64,
    bike_weight_kg: f64,
) -> Option<PowerAnalysis> {
    let points = parse_track(track_json);
    if points.len() < 2 {
        return None;
    }

    let params = PowerParams {
        rider_weight_kg,
        bike_weight_kg,
        ..PowerParams::default()
    };
    let mut dynamics = Vec::with_capacity(points.len().saturating_sub(1));
    let mut powers = Vec::with_capacity(points.len().saturating_sub(1));
    let mut duration_sec = 0.0;
    let mut last_ts = 0_i64;
    let mut previous_gradient = 0.0;

    for pair in points.windows(2) {
        let prev = pair[0];
        let cur = pair[1];
        let dt_sec = (cur.ts_ms - prev.ts_ms) as f64 / 1000.0;
        if !(0.2..=60.0).contains(&dt_sec) {
            continue;
        }
        let distance_m = haversine_meters(prev.lat, prev.lon, cur.lat, cur.lon);
        if distance_m > 200.0 {
            continue;
        }
        let speed_kmh = cur
            .speed_kmh
            .filter(|speed| speed.is_finite() && *speed >= 0.0)
            .unwrap_or(distance_m / dt_sec * 3.6)
            .clamp(0.0, 120.0);
        let gradient = if distance_m >= 1.0 && prev.alt.abs() >= 0.1 && cur.alt.abs() >= 0.1 {
            ((cur.alt - prev.alt) / distance_m * 100.0).clamp(-25.0, 25.0)
        } else {
            previous_gradient
        };
        previous_gradient = gradient;
        let power = watts(speed_kmh, gradient, params);
        powers.push(power);
        duration_sec += dt_sec;
        last_ts = cur.ts_ms;
        dynamics.push(json!({
            "t": cur.ts_ms,
            "pwr": power.round() as i64,
            "spd": round1(speed_kmh),
            "grade": round1(gradient),
        }));
    }

    if powers.len() < 2 || duration_sec <= 0.0 {
        return None;
    }

    let avg = powers.iter().sum::<f64>() / powers.len() as f64;
    let max = powers.iter().copied().fold(0.0_f64, f64::max);
    let normalized = normalized_power(&powers);
    let ftp = estimate_ftp(&powers, duration_sec);
    let intensity_factor = if ftp > 0.0 { normalized / ftp } else { 0.0 };
    let duration_hours = duration_sec / 3600.0;
    let tss = if ftp > 0.0 {
        duration_hours * normalized * intensity_factor / ftp * 100.0
    } else {
        0.0
    };
    let (zone, zone_label) = ftp_zone(avg, ftp);
    let stats = json!({
        "avg_w": avg.round() as i64,
        "max_w": max.round() as i64,
        "np_w": normalized.round() as i64,
        "ftp_w": ftp.round() as i64,
        "if": round2(intensity_factor),
        "tss": tss.round() as i64,
        "zone": zone,
        "zone_label": zone_label,
        "duration_sec": duration_sec.round() as i64,
        "last_ts": last_ts,
    });

    Some(PowerAnalysis {
        dynamics_json: Value::Array(dynamics).to_string(),
        stats_json: stats.to_string(),
        duration_sec: duration_sec.round() as i64,
    })
}

fn parse_track(json: &str) -> Vec<TrackPoint> {
    let Ok(value) = serde_json::from_str::<Value>(json) else {
        return Vec::new();
    };
    let Some(items) = value.as_array() else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| {
            let lat = item.get("lat")?.as_f64()?;
            let lon = item.get("lon")?.as_f64()?;
            if lat.abs() > 85.0 || lon.abs() > 180.0 || (lat == 0.0 && lon == 0.0) {
                return None;
            }
            let ts_ms = item
                .get("ts")
                .or_else(|| item.get("t"))
                .and_then(|value| value.as_i64())
                .filter(|ts| *ts > 0)?;
            Some(TrackPoint {
                lat,
                lon,
                alt: item
                    .get("alt")
                    .and_then(|value| value.as_f64())
                    .unwrap_or(0.0),
                ts_ms,
                speed_kmh: item
                    .get("speed")
                    .and_then(|value| value.as_f64())
                    .map(|speed| speed * 3.6),
            })
        })
        .collect()
}

fn normalized_power(powers: &[f64]) -> f64 {
    if powers.len() < 30 {
        return powers.iter().sum::<f64>() / powers.len() as f64;
    }
    let mut sum = 0.0;
    for window in powers.windows(30) {
        let avg = window.iter().sum::<f64>() / 30.0;
        sum += avg.powi(4);
    }
    (sum / (powers.len() - 29) as f64).powf(0.25)
}

fn estimate_ftp(powers: &[f64], duration_sec: f64) -> f64 {
    if duration_sec < 120.0 {
        return 0.0;
    }
    let window = 20 * 60;
    let effective_window = window.min(powers.len());
    if effective_window >= 30 {
        let mut best = 0.0_f64;
        for start in 0..=powers.len() - effective_window {
            let avg = powers[start..start + effective_window].iter().sum::<f64>()
                / effective_window as f64;
            best = best.max(avg);
        }
        if best > 0.0 {
            return best * FTP_ESTIMATION_FACTOR;
        }
    }
    let avg = powers.iter().sum::<f64>() / powers.len() as f64;
    avg * 1.2
}

fn ftp_zone(power: f64, ftp: f64) -> (i64, &'static str) {
    let percent = if ftp > 0.0 { power / ftp * 100.0 } else { 0.0 };
    if percent <= 55.0 {
        (1, "恢复区")
    } else if percent <= 75.0 {
        (2, "有氧区")
    } else if percent <= 90.0 {
        (3, "节奏区")
    } else if percent <= 105.0 {
        (4, "阈值区")
    } else if percent <= 120.0 {
        (5, "无氧区")
    } else if percent <= 150.0 {
        (6, "最大摄氧区")
    } else {
        (7, "神经肌肉区")
    }
}

fn round1(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

fn round2(value: f64) -> f64 {
    (value * 100.0).round() / 100.0
}

pub fn power_stat_extend(stats_json: &str) -> Option<Map<String, Value>> {
    let Ok(Value::Object(stats)) = serde_json::from_str::<Value>(stats_json) else {
        return None;
    };
    let mut out = Map::new();
    for (id, key) in [
        ("900001", "avg_w"),
        ("900002", "max_w"),
        ("900003", "np_w"),
        ("900004", "ftp_w"),
        ("900005", "if"),
        ("900006", "tss"),
        ("900007", "zone_label"),
    ] {
        if let Some(value) = stats.get(key) {
            out.insert(id.to_string(), value.clone());
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flat_params() -> PowerParams {
        PowerParams {
            rider_weight_kg: 70.0,
            bike_weight_kg: 10.0,
            ..PowerParams::default()
        }
    }

    #[test]
    fn power_rises_with_speed_and_gradient() {
        let slow = watts(20.0, 0.0, flat_params());
        let fast = watts(40.0, 0.0, flat_params());
        let climb = watts(20.0, 5.0, flat_params());
        assert!(fast > slow);
        assert!(climb > slow);
        assert!(slow > 0.0);
    }

    #[test]
    fn stationary_has_no_positive_power() {
        assert_eq!(watts(0.0, 5.0, flat_params()), 0.0);
        assert_eq!(watts(-1.0, 5.0, flat_params()), 0.0);
    }

    #[test]
    fn analysis_builds_power_series_and_stats() {
        let track = json!([
            {"lat": 30.0, "lon": 120.0, "alt": 10.0, "ts": 1_000_000},
            {"lat": 30.0001, "lon": 120.0, "alt": 10.2, "ts": 1_001_000},
            {"lat": 30.0002, "lon": 120.0, "alt": 10.4, "ts": 1_002_000},
            {"lat": 30.0003, "lon": 120.0, "alt": 10.6, "ts": 1_003_000}
        ])
        .to_string();
        let analysis = analyze_track(&track, 70.0, 10.0).expect("analysis");
        let dynamics: Value = serde_json::from_str(&analysis.dynamics_json).unwrap();
        let stats: Value = serde_json::from_str(&analysis.stats_json).unwrap();
        assert_eq!(dynamics.as_array().unwrap().len(), 3);
        assert!(stats["avg_w"].as_i64().unwrap() > 0);
        assert!(stats["np_w"].as_i64().unwrap() > 0);
        assert_eq!(analysis.duration_sec, 3);
    }

    #[test]
    fn stat_extend_uses_stable_custom_ids() {
        let stats = r#"{"avg_w":180,"max_w":260,"np_w":200,"ftp_w":240,"if":0.83,"tss":42,"zone_label":"节奏区"}"#;
        let extend = power_stat_extend(stats).unwrap();
        assert_eq!(extend["900001"], json!(180));
        assert_eq!(extend["900007"], json!("节奏区"));
    }

    #[test]
    #[ignore]
    fn analysis_long_track_performance() {
        let mut points = Vec::with_capacity(36_000);
        for i in 0..36_000 {
            points.push(json!({
                "lat": 30.0 + i as f64 * 0.0001,
                "lon": 120.0,
                "alt": 10.0 + (i as f64 * 0.01).sin(),
                "ts": 1_000_000_i64 + i as i64 * 1000,
            }));
        }
        let track = Value::Array(points).to_string();
        let started = std::time::Instant::now();
        let analysis = analyze_track(&track, 70.0, 10.0).expect("analysis");
        let peak_rss_kb = std::fs::read_to_string("/proc/self/status")
            .ok()
            .and_then(|status| {
                status.lines().find_map(|line| {
                    let value = line.strip_prefix("VmHWM:")?;
                    value.split_whitespace().next()?.parse::<u64>().ok()
                })
            })
            .unwrap_or(0);
        eprintln!(
            "long track: 36000 points, {} ms, dynamics {} bytes, peak RSS {} KiB",
            started.elapsed().as_millis(),
            analysis.dynamics_json.len(),
            peak_rss_kb
        );
    }
}
