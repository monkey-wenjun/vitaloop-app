# Android permissions

Permissions are requested only when the related feature is used. Local-only usage
remains available when optional features are declined.

| Permission | Feature | Optional / fallback |
|---|---|---|
| Internet / network state | optional cloud sync, maps, weather, ephemeris, update | local-only mode works |
| Bluetooth scan/connect | Huawei watch, heart-rate sensors, scale, DJI camera | manual local records still work |
| Fine/coarse location | GPS workout tracks and nearby services | no map track without location |
| Background location | continue an explicitly started workout when the screen is off | foreground-only track |
| Notifications / foreground services | ongoing workout, watch sync, live sharing | background reliability reduced |
| Vibrate | find-phone vibration | ringtone still works without vibration |
| Contacts | optional watch contact sync | feature unavailable |
| Phone state / answer calls | optional watch call notification/control | feature unavailable |
| Calendar read | optional watch calendar sync | feature unavailable |
| Camera / microphone | optional camera remote, voice streaming | feature unavailable |
| Install unknown packages | user-initiated self-update | use the store/manual APK install |
| `WRITE_SECURE_SETTINGS` | optional local proxy automation; normally granted only by adb | skipped when unavailable |

The project does not request a permission as a prerequisite for viewing existing
local data.
