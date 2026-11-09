# Workout protocol fields

## `sportHeartPosture`

Official Huawei Health APK `17.0.8.320` stores the field as
`300010037 / sportHeartPosture`.

Observed behavior:

- `HeartRateFrag$4.run` reads `getExtendDataInt("sportHeartPosture", -1)`.
- It passes the value as the posture argument to `Track_HeartRateAndStepsUtils`.
- The posture is normalized to `1..4`.
- For `1`, `Track_HeartRateConfigUtils` logs `get standing posture data` and
  receives the standing/upright heart-zone configuration.

Therefore, `1` means **standing/upright posture**, used to select the matching
heart-rate-zone profile. It is not a reserve-heart-rate mode (HRR), maximum-heart-
rate mode, or lactate-threshold mode. Those are separate `classifyMethod` values.

The field is intentionally hidden from the workout summary because the raw
posture identifier has no useful meaning for the user. It remains preserved in
the database and is documented here.

## `trainingPoints`

Workout aggregate tag `0x63` is officially named `trainingPoints`. It is a raw
Huawei training-points value, not workout load, EPOC, calories, or training
effect. The formula is not established by the protocol evidence, so the UI does
not grade it.
