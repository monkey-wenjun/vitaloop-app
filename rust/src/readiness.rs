use crate::api::types::{
    ReadinessBaseline, ReadinessInputs, ReadinessPoint, ReadinessScore, ReadinessWeights,
};

pub const WEIGHT_HRV: f64 = 0.07;
pub const WEIGHT_SLEEP: f64 = 0.80;
pub const WEIGHT_RHR: f64 = 0.04;
pub const WEIGHT_TEMP: f64 = 0.02;
pub const WEIGHT_STRESS: f64 = 0.03;
pub const WEIGHT_RECOVERY: f64 = 0.04;

const DEFAULT_HRV_BASELINE: f64 = 45.0;
const DEFAULT_RHR_BASELINE: f64 = 60.0;
const DEFAULT_TEMP_BASELINE: f64 = 33.4;
const SLEEP_BASE_SCORE: f64 = 80.0;
const SLEEP_REFERENCE_MINUTES: f64 = 360.0;
const DEEP_REFERENCE_MINUTES: f64 = 120.0;
const SLEEP_POINTS_PER_MINUTE: f64 = 0.15;
const DEEP_POINTS_PER_MINUTE: f64 = 1.00;
const WAKE_PENALTY: f64 = 5.0;

pub fn weights() -> ReadinessWeights {
    ReadinessWeights {
        hrv: (WEIGHT_HRV * 100.0).round() as i64,
        sleep: (WEIGHT_SLEEP * 100.0).round() as i64,
        rhr: (WEIGHT_RHR * 100.0).round() as i64,
        temp: (WEIGHT_TEMP * 100.0).round() as i64,
        stress: (WEIGHT_STRESS * 100.0).round() as i64,
        recovery: (WEIGHT_RECOVERY * 100.0).round() as i64,
    }
}

fn clamp(v: f64) -> f64 {
    v.clamp(0.0, 100.0)
}

pub fn sleep_score(minutes: f64, deep_minutes: f64, awakenings: f64) -> f64 {
    clamp(
        SLEEP_BASE_SCORE
            + (minutes - SLEEP_REFERENCE_MINUTES) * SLEEP_POINTS_PER_MINUTE
            + (deep_minutes - DEEP_REFERENCE_MINUTES) * DEEP_POINTS_PER_MINUTE
            - awakenings.max(0.0) * WAKE_PENALTY,
    )
}

/// HRV 相对个人基线：基线水平 = 50 分，每高出 1% 加 1.5 分。
fn hrv_component(inputs: &ReadinessInputs, baseline: &ReadinessBaseline) -> Option<f64> {
    let hrv = inputs.hrv_ms?;
    if hrv <= 0.0 {
        return None;
    }
    let base = baseline
        .hrv_ms
        .filter(|v| *v > 0.0)
        .unwrap_or(DEFAULT_HRV_BASELINE);
    Some(clamp(50.0 + (hrv / base - 1.0) * 150.0))
}

/// 睡眠：以 6 小时 / 深睡 2 小时为中性点，按分钟连续加减，每次清醒再扣分。
fn sleep_component(inputs: &ReadinessInputs) -> Option<f64> {
    let minutes = inputs.sleep_minutes?;
    if minutes <= 0.0 {
        return None;
    }
    let deep = inputs.deep_sleep_minutes.unwrap_or(0.0).max(0.0);
    Some(sleep_score(
        minutes,
        deep,
        inputs.sleep_awakenings.unwrap_or(0.0),
    ))
}

/// 静息心率：以个人基线为准，每低 1 bpm 加 3 分，每高 1 bpm 减 3 分。
fn rhr_component(inputs: &ReadinessInputs, baseline: &ReadinessBaseline) -> Option<f64> {
    let rhr = inputs.resting_hr?;
    if rhr <= 0.0 {
        return None;
    }
    let base = baseline
        .resting_hr
        .filter(|v| *v > 0.0)
        .unwrap_or(DEFAULT_RHR_BASELINE);
    Some(clamp(75.0 + (base - rhr) * 3.0))
}

/// 体温：与个人夜间基线偏差超过 0.3°C 后开始扣分，每 0.1°C 扣 4.5 分。
fn temp_component(inputs: &ReadinessInputs, baseline: &ReadinessBaseline) -> Option<f64> {
    let temp = inputs.skin_temp_c?;
    if temp <= 0.0 {
        return None;
    }
    let base = baseline
        .skin_temp_c
        .filter(|v| *v > 0.0)
        .unwrap_or(DEFAULT_TEMP_BASELINE);
    let deviation = (temp - base).abs();
    Some(clamp(100.0 - (deviation - 0.3).max(0.0) * 45.0))
}

/// 压力：0-100 的压力指数直接反向映射。
fn stress_component(inputs: &ReadinessInputs) -> Option<f64> {
    let stress = inputs.stress?;
    Some(clamp(100.0 - stress))
}

/// 恢复时间：当天多次运动累加，0 分钟为 100 分，每 3 分钟扣 1 分。
fn recovery_component(inputs: &ReadinessInputs) -> Option<f64> {
    let minutes = inputs.recovery_minutes?;
    if minutes < 0.0 {
        return None;
    }
    Some(clamp(100.0 - minutes / 3.0))
}

pub fn level_for(total: i64) -> &'static str {
    // level 只描述状态，advice 才给行动建议；两边都用「适合正常训练」这类话术，
    // 同一张卡上就会出现「适合正常训练」和「控制强度」互相打脸。
    match total {
        85..=100 => "状态极佳",
        75..=84 => "状态良好",
        60..=74 => "状态一般",
        40..=59 => "恢复不足",
        _ => "需要休息",
    }
}

pub fn advice_for(total: i64) -> &'static str {
    match total {
        85..=100 => "可以尝试高强度训练",
        75..=84 => "适合正常训练",
        60..=74 => "控制强度，注意恢复",
        40..=59 => "建议主动恢复",
        _ => "优先休息，避免训练",
    }
}

pub fn level_without_data() -> &'static str {
    "数据不足"
}

pub fn compute(
    inputs: &ReadinessInputs,
    baseline: &ReadinessBaseline,
    yesterday_total: Option<i64>,
    computed_at_ms: i64,
) -> ReadinessScore {
    let parts = [
        (hrv_component(inputs, baseline), WEIGHT_HRV),
        (sleep_component(inputs), WEIGHT_SLEEP),
        (rhr_component(inputs, baseline), WEIGHT_RHR),
        (temp_component(inputs, baseline), WEIGHT_TEMP),
        (stress_component(inputs), WEIGHT_STRESS),
        (recovery_component(inputs), WEIGHT_RECOVERY),
    ];

    // 恢复时间只修正身体状态，不能单独把准备度抬到 100 分。
    let has_body_data = parts[..5].iter().any(|(score, _)| score.is_some());
    let mut weighted = 0.0;
    let mut weight_sum = 0.0;
    for &(score, weight) in &parts {
        if !has_body_data && weight == WEIGHT_RECOVERY {
            continue;
        }
        if let Some(score) = score {
            weighted += score * weight;
            weight_sum += weight;
        }
    }

    let total = if weight_sum > 0.0 {
        (weighted / weight_sum).round() as i64
    } else {
        0
    };

    let (level, advice) = if weight_sum > 0.0 {
        (level_for(total), advice_for(total))
    } else {
        (level_without_data(), "请先佩戴设备完成一次睡眠与 HRV 监测")
    };

    ReadinessScore {
        total,
        level: level.to_string(),
        advice: advice.to_string(),
        trend: yesterday_total.map(|y| total - y).unwrap_or(0),
        hrv_score: parts[0].0.map(|v| v.round() as i64).unwrap_or(0),
        sleep_score: parts[1].0.map(|v| v.round() as i64).unwrap_or(0),
        rhr_score: parts[2].0.map(|v| v.round() as i64).unwrap_or(0),
        temp_score: parts[3].0.map(|v| v.round() as i64).unwrap_or(0),
        stress_score: parts[4].0.map(|v| v.round() as i64).unwrap_or(0),
        recovery_score: parts[5].0.map(|v| v.round() as i64).unwrap_or(0),
        recovery_minutes: inputs.recovery_minutes.unwrap_or(0.0).round() as i64,
        computed_at_ms,
    }
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

/// 使用最近 7 天（不含今天）的有效值中位数作为个人基线。
pub fn baseline_from_history(history: &[ReadinessInputs]) -> ReadinessBaseline {
    let mut hrv: Vec<f64> = history
        .iter()
        .filter_map(|d| d.hrv_ms.filter(|v| *v > 0.0))
        .collect();
    let mut rhr: Vec<f64> = history
        .iter()
        .filter_map(|d| d.resting_hr.filter(|v| *v > 0.0))
        .collect();
    let mut temp: Vec<f64> = history
        .iter()
        .filter_map(|d| d.skin_temp_c.filter(|v| *v > 0.0))
        .collect();
    let mut stress: Vec<f64> = history.iter().filter_map(|d| d.stress).collect();
    let mut sleep: Vec<f64> = history
        .iter()
        .filter_map(|d| d.sleep_minutes.filter(|v| *v > 0.0))
        .collect();

    ReadinessBaseline {
        hrv_ms: median(&mut hrv),
        sleep_minutes: median(&mut sleep),
        resting_hr: median(&mut rhr),
        skin_temp_c: median(&mut temp),
        stress: median(&mut stress),
    }
}

pub fn average(points: &[ReadinessPoint]) -> i64 {
    if points.is_empty() {
        return 0;
    }
    let sum: i64 = points.iter().map(|p| p.total).sum();
    (sum as f64 / points.len() as f64).round() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full_inputs() -> ReadinessInputs {
        ReadinessInputs {
            hrv_ms: Some(58.0),
            sleep_minutes: Some(432.0),
            deep_sleep_minutes: Some(87.0),
            sleep_awakenings: Some(1.0),
            resting_hr: Some(58.0),
            skin_temp_c: Some(33.6),
            stress: Some(28.0),
            recovery_minutes: Some(60.0),
        }
    }

    fn demo_baseline() -> ReadinessBaseline {
        ReadinessBaseline {
            hrv_ms: Some(47.0),
            sleep_minutes: Some(430.0),
            resting_hr: Some(60.0),
            skin_temp_c: Some(33.4),
            stress: Some(30.0),
        }
    }

    #[test]
    fn weights_sum_to_one() {
        assert!(
            (WEIGHT_HRV
                + WEIGHT_SLEEP
                + WEIGHT_RHR
                + WEIGHT_TEMP
                + WEIGHT_STRESS
                + WEIGHT_RECOVERY
                - 1.0)
                .abs()
                < 1e-9
        );
        let w = weights();
        assert_eq!(w.hrv, 7);
        assert_eq!(w.sleep, 80);
        assert_eq!(w.rhr, 4);
        assert_eq!(w.temp, 2);
        assert_eq!(w.stress, 3);
        assert_eq!(w.recovery, 4);
        assert!(w.sleep >= 80);
    }

    #[test]
    fn demo_day_scores_in_expected_range() {
        let score = compute(&full_inputs(), &demo_baseline(), Some(78), 0);
        assert!(
            (56..=62).contains(&score.total),
            "total was {}",
            score.total
        );
        assert_eq!(score.level, "恢复不足");
        assert!(score.trend < 0);
    }

    #[test]
    fn sleep_thresholds_follow_duration_and_deep_sleep() {
        let excellent = ReadinessInputs {
            sleep_minutes: Some(422.0),
            deep_sleep_minutes: Some(121.0),
            sleep_awakenings: Some(0.0),
            ..full_inputs()
        };
        assert_eq!(sleep_component(&excellent), Some(90.3));

        let poor_deep = ReadinessInputs {
            sleep_minutes: Some(500.0),
            deep_sleep_minutes: Some(59.0),
            sleep_awakenings: Some(0.0),
            ..full_inputs()
        };
        assert!(sleep_component(&poor_deep).unwrap() < 50.0);

        let short_total = ReadinessInputs {
            sleep_minutes: Some(350.0),
            deep_sleep_minutes: Some(130.0),
            sleep_awakenings: Some(0.0),
            ..full_inputs()
        };
        assert_eq!(sleep_component(&short_total).unwrap(), 88.5);

        let exactly_two_hours = ReadinessInputs {
            sleep_minutes: Some(422.0),
            deep_sleep_minutes: Some(120.0),
            sleep_awakenings: Some(0.0),
            ..full_inputs()
        };
        assert_eq!(sleep_component(&exactly_two_hours), Some(89.3));

        let woke_three_times = ReadinessInputs {
            sleep_awakenings: Some(3.0),
            ..excellent
        };
        assert_eq!(sleep_component(&woke_three_times), Some(75.3));
    }

    #[test]
    fn missing_components_are_renormalized() {
        let mut inputs = full_inputs();
        inputs.hrv_ms = None;
        inputs.skin_temp_c = None;
        let score = compute(&inputs, &demo_baseline(), None, 0);
        assert!(score.hrv_score == 0);
        assert!(score.temp_score == 0);
        assert!(score.total > 0);
    }

    #[test]
    fn no_data_does_not_divide_by_zero() {
        let inputs = ReadinessInputs {
            hrv_ms: None,
            sleep_minutes: None,
            deep_sleep_minutes: None,
            sleep_awakenings: None,
            resting_hr: None,
            skin_temp_c: None,
            stress: None,
            recovery_minutes: None,
        };
        let score = compute(&inputs, &demo_baseline(), None, 0);
        assert_eq!(score.total, 0);
        assert_eq!(score.level, "数据不足");
    }

    #[test]
    fn poor_sleep_and_high_stress_lower_score() {
        let good = compute(&full_inputs(), &demo_baseline(), None, 0);
        let bad_inputs = ReadinessInputs {
            sleep_minutes: Some(300.0),
            deep_sleep_minutes: Some(20.0),
            stress: Some(85.0),
            ..full_inputs()
        };
        let bad = compute(&bad_inputs, &demo_baseline(), None, 0);
        assert!(bad.total < good.total);
        assert!(bad.total < 70);
    }

    #[test]
    fn baseline_uses_median() {
        let mut history = Vec::new();
        for (hrv, rhr) in [(60.0, 55.0), (46.0, 61.0), (48.0, 60.0), (47.0, 62.0)] {
            history.push(ReadinessInputs {
                hrv_ms: Some(hrv),
                sleep_minutes: Some(430.0),
                deep_sleep_minutes: None,
                sleep_awakenings: None,
                resting_hr: Some(rhr),
                skin_temp_c: None,
                stress: Some(30.0),
                recovery_minutes: None,
            });
        }
        let baseline = baseline_from_history(&history);
        assert_eq!(baseline.hrv_ms, Some(47.5));
        assert_eq!(baseline.resting_hr, Some(60.5));
    }

    #[test]
    fn trend_is_relative_to_yesterday() {
        let score = compute(&full_inputs(), &demo_baseline(), Some(70), 0);
        assert_eq!(score.trend, score.total - 70);
    }

    #[test]
    fn recovery_minutes_reduce_score_and_are_reported() {
        let mut inputs = full_inputs();
        inputs.recovery_minutes = Some(45.0);
        let score = compute(&inputs, &demo_baseline(), None, 0);
        assert_eq!(score.recovery_score, 85);
        assert_eq!(score.recovery_minutes, 45);
    }

    #[test]
    fn recovery_alone_does_not_create_readiness() {
        let inputs = ReadinessInputs {
            hrv_ms: None,
            sleep_minutes: None,
            deep_sleep_minutes: None,
            sleep_awakenings: None,
            resting_hr: None,
            skin_temp_c: None,
            stress: None,
            recovery_minutes: Some(30.0),
        };
        let score = compute(&inputs, &demo_baseline(), None, 0);
        assert_eq!(score.total, 0);
        assert_eq!(score.level, "数据不足");
        assert_eq!(score.recovery_score, 90);
    }
}
