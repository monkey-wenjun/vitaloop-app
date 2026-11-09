# Contributing to Vitaloop

感谢你愿意参与元环。提交代码即表示你同意以本仓库的 AGPL-3.0 协议发布该贡献。

## 开始之前

1. 不要提交健康数据、账号凭据、手表认证 key、`.legacy/` 文件或本地数据库。
2. 新功能先开 issue，说明用户场景、数据来源与隐私影响。
3. 第三方代码、依赖和远程脚本必须能追溯到许可证与上游仓库。
4. UI 改动需要同时检查浅色、深色、窄屏和长文案。
5. 不要提交私有服务地址、服务器 IP、部署口令、签名密钥或生产配置。
6. 提交必须包含 `Signed-off-by: Name <email>`，表示同意 Developer Certificate
   of Origin 1.1。

## 开发环境

- Flutter 3.47+
- Dart 3.13+
- Rust 1.85+
- Android SDK/NDK、JDK 17

```bash
flutter pub get
flutter gen-l10n
flutter analyze
flutter test
cd rust && cargo test
```

## 文案与翻译

- ARB 文件位于 `lib/l10n/`，英文 `app_en.arb` 是模板。
- 旧页面和动态平台消息位于 `assets/i18n/ui_strings.json`，不得在运行时调用在线翻译。
- 所有语言必须保留相同 key 和占位符。
- 不要硬编码新的用户可见中文字符串；核心页面使用 `AppLocalizations`，
  旧页面交给 `LocalizedText`/`tr()`，并补充离线目录。
- 新增语言时同步添加 ARB、`lib/l10n/language_options.dart` 条目和测试。
- 修改 Android 可见文案时同步更新 `values-*` 资源，并检查前台通知和 TTS。

## 提交建议

提交信息使用清晰的动词，例如：

```
feat: redesign sleep stage timeline
fix: prevent localized settings chip overflow
docs: clarify AGPL commercial distribution
```

PR 请说明：

- 改动解决了什么问题；
- 测试过的设备、分辨率和语言；
- 是否影响隐私、权限、网络、健康数据处理或许可证；
- 对应的 issue（如有）。

## 数据与隐私

元环默认离线。任何新增上传、遥测、第三方 SDK 或云端处理都需要显式开关、
隐私说明和用户同意，不能默认开启，也不能把健康数据用于广告画像。
