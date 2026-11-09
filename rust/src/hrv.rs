/// 一次 RR 间期测量的分析结果。
///
/// 原始数据里可能混有电极接触不良产生的异常值；指标只使用 300–2000ms 的
/// 有效间期计算，同时保留异常比例用于判断这次测量能不能保存。
#[derive(Debug, Clone, PartialEq)]
pub struct HrvStats {
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

pub const MIN_RR_MS: i64 = 300;
pub const MAX_RR_MS: i64 = 2000;
pub const MIN_RR_FOR_METRICS: usize = 2;
pub const MIN_RR_FOR_SAVE: usize = 30;

pub fn analyze(rr_intervals: &[i64]) -> HrvStats {
    let rr_count = rr_intervals.len() as i64;
    let valid: Vec<f64> = rr_intervals
        .iter()
        .copied()
        .filter(|value| (MIN_RR_MS..=MAX_RR_MS).contains(value))
        .map(|value| value as f64)
        .collect();
    let valid_rr_count = valid.len() as i64;
    let outlier_count = rr_count - valid_rr_count;
    let has_metrics = valid.len() >= MIN_RR_FOR_METRICS;

    let (rmssd_ms, sdnn_ms, pnn50, average_hr) = if has_metrics {
        metrics(&valid)
    } else {
        (0.0, 0.0, 0.0, 0)
    };

    let outlier_ratio = if rr_count > 0 {
        outlier_count as f64 / rr_count as f64
    } else {
        0.0
    };
    let (quality, quality_label, quality_note) = if rr_count < 10 {
        (
            "insufficient",
            "数据不足",
            "RR 间期少于 10 个，至少连续测量 30 秒后再看结果。",
        )
    } else if !has_metrics || outlier_ratio > 0.20 {
        (
            "poor",
            "数据较差",
            "异常 RR 间期过多，建议擦干皮肤、贴紧心率带电极后重新测量。",
        )
    } else if outlier_ratio > 0.10 {
        (
            "fair",
            "数据一般",
            "有少量异常间期，结果可参考；如需对比趋势建议再测一次。",
        )
    } else {
        ("good", "数据良好", "RR 间期稳定，可以保存为本次 HRV 结果。")
    };

    HrvStats {
        rr_count,
        valid_rr_count,
        outlier_count,
        has_metrics,
        rmssd_ms,
        sdnn_ms,
        pnn50,
        average_hr,
        quality: quality.to_string(),
        quality_label: quality_label.to_string(),
        quality_note: quality_note.to_string(),
        can_save: valid.len() >= MIN_RR_FOR_SAVE && matches!(quality, "good" | "fair"),
    }
}

fn metrics(rr: &[f64]) -> (f64, f64, f64, i64) {
    let mean = rr.iter().sum::<f64>() / rr.len() as f64;
    let sdnn =
        (rr.iter().map(|value| (value - mean).powi(2)).sum::<f64>() / rr.len() as f64).sqrt();

    let diffs: Vec<f64> = rr.windows(2).map(|pair| pair[1] - pair[0]).collect();
    let rmssd = (diffs.iter().map(|diff| diff * diff).sum::<f64>() / diffs.len() as f64).sqrt();
    let nn50 = diffs.iter().filter(|diff| diff.abs() > 50.0).count();
    let pnn50 = nn50 as f64 / diffs.len() as f64 * 100.0;
    let average_hr = (60000.0 / mean).round() as i64;

    (rmssd, sdnn, pnn50, average_hr)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(actual: f64, expected: f64) {
        assert!(
            (actual - expected).abs() < 0.001,
            "expected {expected}, got {actual}"
        );
    }

    #[test]
    fn computes_standard_metrics() {
        let result = analyze(&[1000, 1050, 950, 1000]);
        assert!(result.has_metrics);
        approx(result.rmssd_ms, 70.710_678);
        approx(result.sdnn_ms, 35.355_339);
        approx(result.pnn50, 33.333_333);
        assert_eq!(result.average_hr, 60);
        assert_eq!(result.rr_count, 4);
        assert_eq!(result.valid_rr_count, 4);
        assert_eq!(result.outlier_count, 0);
        assert_eq!(result.quality, "insufficient");
        assert!(!result.can_save);
    }

    #[test]
    fn filters_out_of_range_intervals() {
        let mut rr = vec![1000; 20];
        rr.extend([299, 300, 2000, 2001, 0]);
        let result = analyze(&rr);

        assert_eq!(result.rr_count, 25);
        assert_eq!(result.valid_rr_count, 22);
        assert_eq!(result.outlier_count, 3);
        assert_eq!(result.quality, "fair");
        assert!(!result.can_save);
    }

    #[test]
    fn too_many_outliers_is_poor() {
        let mut rr = vec![1000; 8];
        rr.extend([100, 100, 100]);
        let result = analyze(&rr);

        assert_eq!(result.quality, "poor");
        assert!(!result.can_save);
    }

    #[test]
    fn requires_thirty_valid_intervals_to_save() {
        let rr: Vec<i64> = (0..30).map(|i| 1000 + (i % 2) * 50).collect();
        let result = analyze(&rr);

        assert!(result.can_save);
        assert_eq!(result.quality, "good");
        assert_eq!(result.valid_rr_count, 30);
    }

    #[test]
    fn boundary_values_are_valid() {
        let result = analyze(&[300, 2000, 299, 2001]);
        assert_eq!(result.valid_rr_count, 2);
        assert_eq!(result.outlier_count, 2);
        assert!(result.has_metrics);
    }

    #[test]
    fn empty_input_has_no_metrics() {
        let result = analyze(&[]);
        assert!(!result.has_metrics);
        assert_eq!(result.rr_count, 0);
        assert_eq!(result.valid_rr_count, 0);
        assert_eq!(result.quality, "insufficient");
        assert!(!result.can_save);
        assert_eq!(result.rmssd_ms, 0.0);
    }
}
