# Changelog

## Unreleased

### Fixed

- 手表不再固定显示「年龄 30、最大心率 195」：断开 Gadgetbridge 里写死的
  `ActivityUser`（30 岁 / 175cm / 70kg / 性别未知），连接时改用本人档案
  （生日、身高、体重、性别）通过 `FitnessData UserInfo (0x07/0x02)` 上报；
  连接就绪后再补发一次，档案或最大心率设置变化时立即重发。
- 心率区间按真实年龄、静息心率与最大心率下发，不再使用固定值。
- 修正 `DebugRequest` 在无 TLV 时的空指针。

### Added

- adb 协议探针：仅 `android.permission.DUMP` 可触发，用于对照实验华为手表的
  原始命令与应答（抓包/逆向调试用，不参与正常业务）。

## 0.1.1 — 2026-11-16

### Added

- Added running-dynamics grades and advice for vertical oscillation and left/right
  ground-contact balance, with boundary tests.
- Made workout-detail long screenshots explicit as “分享长图”, capped very tall
  captures at an 18-megapixel budget, and kept the original scroll position after capture.
- Redesigned sleep detail with score hero, stage timeline, composition, HRV and apnea cards.
- Added day/week/month sleep views with responsive two-column layouts.
- Added complete automatic and manual localization for every Flutter page, dialog,
  dynamic message, Android notification, app label and TTS voice.
- Added contributor, security and code-of-conduct documentation.
- Added alternative destination routes and an in-navigation route switcher.
- Added a default MapLibre/Protomaps PMTiles map with Liberty light and dark
  styles, orange tracks, numbered kilometer labels, and road names.

### Changed

- Added light- and dark-theme screenshots and linked the Gadgetbridge
  Huawei/Honor pairing guide from the bilingual READMEs.
- Synced the latest private-repository sleep and sync fixes while keeping the
  public build free of private domains and release credentials.
- Prepared a sanitized public repository with bilingual READMEs, privacy and
  permission documentation, third-party notices, CI, Dependabot, issue/PR
  templates, and environment-based cloud/signing configuration.
- Removed default private cloud and ephemeris endpoints from the public build.
- Documented environment-based Android release signing, arm64 build guidance,
  certificate verification, and the in-place `adb install -r` flow in
  `docs/RELEASE_SIGNING.md`.
- Split sleep data models, controller, style tokens, chart painters and widgets into
  separate files.
- Clarified AGPL-3.0 commercial and network-service obligations.

### Fixed

- Workout screenshots now ask “长图 / 当前页”; long capture includes the map,
  measures the fully expanded lazy list before composing, overlaps each frame,
  waits for cards to render, hides share/export controls, and saves to
  `Pictures/Vitaloop`.
- Confirmed `sportHeartPosture=1` is the standing/upright posture selector, not
  reserve-heart-rate mode; the raw technical field is now hidden from the workout
  summary.
- Moved kilometer splits to the end of workout details, corrected field
  `300010037` to “运动心率表现”, and clarified that “训练积分” is a raw watch
  training-points value rather than load, EPOC or calories.
- Destination navigation now reroutes from the current position after a sustained
  off-route period; imported fixed routes remain unchanged.
- Declared the Android vibrate permission so watch-triggered find-phone alerts
  can ring and vibrate reliably.
- Removed confusing POI dots and dashed administrative boundaries from workout
  maps.
- Prevented translated settings chips and long sleep labels from overflowing narrow screens.
