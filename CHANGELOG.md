# Changelog

## Unreleased

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

### Changed

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
- Prevented translated settings chips and long sleep labels from overflowing narrow screens.
