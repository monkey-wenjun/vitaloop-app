use serde_json::{json, Value};

const EARTH_RADIUS_M: f64 = 6_371_000.0;
const DEFAULT_ARRIVAL_RADIUS_M: f64 = 25.0;
const DEFAULT_OFF_ROUTE_M: f64 = 60.0;

#[derive(Clone, Copy)]
struct Point {
    lat: f64,
    lon: f64,
}

#[derive(Clone, Copy)]
struct Projection {
    segment: usize,
    t: f64,
    distance_m: f64,
}

pub fn guidance(route_json: &str, lat: f64, lon: f64, arrival_radius_m: f64) -> String {
    let points = parse_points(route_json);
    if points.len() < 2 || !lat.is_finite() || !lon.is_finite() {
        return json!({
            "ok": false,
            "instruction": "",
            "arrived": false,
            "off_route": false,
            "remaining_m": 0,
            "to_turn_m": 0,
            "progress": 0,
            "segment": 0,
            "turn": "straight",
        })
        .to_string();
    }

    let current = Point { lat, lon };
    let projection = nearest_projection(&points, current);
    let lengths: Vec<f64> = points
        .windows(2)
        .map(|pair| haversine(pair[0], pair[1]))
        .collect();
    let segment = projection.segment;
    let current_segment_length = lengths[segment];
    let after_current = lengths[segment + 1..].iter().sum::<f64>();
    let remaining_m = (current_segment_length * (1.0 - projection.t) + after_current).max(0.0);
    let total_m = lengths.iter().sum::<f64>();
    let progress = if total_m > 0.0 {
        ((total_m - remaining_m) / total_m).clamp(0.0, 1.0)
    } else {
        0.0
    };

    let last = points[points.len() - 1];
    let arrival_radius = if arrival_radius_m > 0.0 {
        arrival_radius_m
    } else {
        DEFAULT_ARRIVAL_RADIUS_M
    };
    let arrived = haversine(current, last) <= arrival_radius
        || (segment + 1 == points.len() - 1 && remaining_m <= arrival_radius);
    let off_route = projection.distance_m > DEFAULT_OFF_ROUTE_M;

    let vertex_index = segment + 1;
    let to_turn_m = if vertex_index < points.len() {
        let along_vertex = current_segment_length * (1.0 - projection.t)
            + lengths[segment + 1..vertex_index].iter().sum::<f64>();
        along_vertex
    } else {
        0.0
    };

    let (turn, turn_text) = turn_at(&points, vertex_index);
    let instruction = if arrived {
        "已到达目的地".to_string()
    } else if off_route {
        "已偏离路线，请返回路线".to_string()
    } else if to_turn_m <= 20.0 && turn != "straight" {
        format!("即将{turn_text}")
    } else if turn == "straight" {
        format!("沿当前路线直行 {}", format_distance(to_turn_m))
    } else {
        format!("前方 {} {}", format_distance(to_turn_m), turn_text)
    };

    json!({
        "ok": true,
        "instruction": instruction,
        "arrived": arrived,
        "off_route": off_route,
        "off_route_m": round1(projection.distance_m),
        "remaining_m": round1(remaining_m),
        "to_turn_m": round1(to_turn_m),
        "progress": round3(progress),
        "segment": segment,
        "turn": turn,
        "turn_text": turn_text,
    })
    .to_string()
}

fn parse_points(json: &str) -> Vec<Point> {
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
            if !lat.is_finite() || !lon.is_finite() || lat.abs() > 85.0 || lon.abs() > 180.0 {
                return None;
            }
            if lat == 0.0 && lon == 0.0 {
                return None;
            }
            Some(Point { lat, lon })
        })
        .collect()
}

fn nearest_projection(points: &[Point], current: Point) -> Projection {
    let mut best = Projection {
        segment: 0,
        t: 0.0,
        distance_m: f64::INFINITY,
    };
    for index in 0..points.len() - 1 {
        let a = to_local(points[index], current);
        let b = to_local(points[index + 1], current);
        let dx = b.0 - a.0;
        let dy = b.1 - a.1;
        let denom = dx * dx + dy * dy;
        let t = if denom <= f64::EPSILON {
            0.0
        } else {
            (-(a.0 * dx + a.1 * dy) / denom).clamp(0.0, 1.0)
        };
        let px = a.0 + dx * t;
        let py = a.1 + dy * t;
        let distance = (px * px + py * py).sqrt();
        if distance < best.distance_m {
            best = Projection {
                segment: index,
                t,
                distance_m: distance,
            };
        }
    }
    best
}

/// 把点投影到以 current 为原点的局部平面（米）。
fn to_local(point: Point, origin: Point) -> (f64, f64) {
    let lat_rad = origin.lat.to_radians();
    let x = (point.lon - origin.lon).to_radians() * EARTH_RADIUS_M * lat_rad.cos();
    let y = (point.lat - origin.lat).to_radians() * EARTH_RADIUS_M;
    (x, y)
}

fn haversine(a: Point, b: Point) -> f64 {
    let dlat = (b.lat - a.lat).to_radians();
    let dlon = (b.lon - a.lon).to_radians();
    let h = (dlat / 2.0).sin().powi(2)
        + a.lat.to_radians().cos() * b.lat.to_radians().cos() * (dlon / 2.0).sin().powi(2);
    2.0 * EARTH_RADIUS_M * h.sqrt().asin()
}

fn bearing(a: Point, b: Point) -> f64 {
    let lat1 = a.lat.to_radians();
    let lat2 = b.lat.to_radians();
    let dlon = (b.lon - a.lon).to_radians();
    let y = dlon.sin() * lat2.cos();
    let x = lat1.cos() * lat2.sin() - lat1.sin() * lat2.cos() * dlon.cos();
    y.atan2(x).to_degrees().rem_euclid(360.0)
}

fn normalize_turn(delta: f64) -> f64 {
    let mut value = delta % 360.0;
    if value > 180.0 {
        value -= 360.0;
    } else if value < -180.0 {
        value += 360.0;
    }
    value
}

fn turn_at(points: &[Point], vertex: usize) -> (&'static str, &'static str) {
    if vertex == 0 || vertex + 1 >= points.len() {
        return ("straight", "到达终点");
    }
    let in_bearing = bearing(points[vertex - 1], points[vertex]);
    let out_bearing = bearing(points[vertex], points[vertex + 1]);
    let delta = normalize_turn(out_bearing - in_bearing);
    let abs = delta.abs();
    if abs <= 15.0 {
        ("straight", "直行")
    } else if abs <= 45.0 {
        if delta > 0.0 {
            ("slight_right", "靠右")
        } else {
            ("slight_left", "靠左")
        }
    } else if abs <= 135.0 {
        if delta > 0.0 {
            ("right", "右转")
        } else {
            ("left", "左转")
        }
    } else {
        ("uturn", "掉头")
    }
}

fn format_distance(meters: f64) -> String {
    if meters >= 1000.0 {
        format!("{:.1} 公里", meters / 1000.0)
    } else if meters >= 200.0 {
        format!("{} 米", (meters / 50.0).round() as i64 * 50)
    } else if meters >= 50.0 {
        format!("{} 米", (meters / 10.0).round() as i64 * 10)
    } else if meters >= 10.0 {
        "10 米".to_string()
    } else {
        "前方".to_string()
    }
}

fn round1(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

fn round3(value: f64) -> f64 {
    (value * 1000.0).round() / 1000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn route(points: &[(f64, f64)]) -> String {
        Value::Array(
            points
                .iter()
                .map(|(lat, lon)| json!({"lat": lat, "lon": lon}))
                .collect(),
        )
        .to_string()
    }

    #[test]
    fn straight_route_reports_remaining_and_progress() {
        let raw = route(&[(30.0, 120.0), (30.001, 120.0), (30.002, 120.0)]);
        let result: Value = serde_json::from_str(&guidance(&raw, 30.0005, 120.0, 25.0)).unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(result["turn"], "straight");
        assert!(result["remaining_m"].as_f64().unwrap() > 150.0);
        assert!(result["progress"].as_f64().unwrap() > 0.0);
        assert!(result["instruction"].as_str().unwrap().contains("直行"));
    }

    #[test]
    fn north_then_east_is_a_right_turn() {
        let raw = route(&[(30.0, 120.0), (30.001, 120.0), (30.001, 120.001)]);
        let result: Value = serde_json::from_str(&guidance(&raw, 30.0008, 120.0, 25.0)).unwrap();
        assert_eq!(result["turn"], "right");
        assert!(result["instruction"].as_str().unwrap().contains("右转"));
    }

    #[test]
    fn destination_within_radius_is_arrived() {
        let raw = route(&[(30.0, 120.0), (30.001, 120.0)]);
        let result: Value = serde_json::from_str(&guidance(&raw, 30.00101, 120.0, 25.0)).unwrap();
        assert_eq!(result["arrived"], true);
        assert_eq!(result["instruction"], "已到达目的地");
    }

    #[test]
    fn far_away_point_is_off_route() {
        let raw = route(&[(30.0, 120.0), (30.001, 120.0)]);
        let result: Value = serde_json::from_str(&guidance(&raw, 30.0005, 120.002, 25.0)).unwrap();
        assert_eq!(result["off_route"], true);
        assert!(result["instruction"].as_str().unwrap().contains("偏离"));
    }

    #[test]
    fn malformed_input_returns_not_ok() {
        let result: Value = serde_json::from_str(&guidance("[]", 30.0, 120.0, 25.0)).unwrap();
        assert_eq!(result["ok"], false);
    }
}
