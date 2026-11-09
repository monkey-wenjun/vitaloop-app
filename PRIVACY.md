# Privacy Policy / 隐私说明

English | [简体中文](#简体中文)

## English

Vitaloop is local-first. The public build does not include telemetry, advertising
SDKs, a default cloud server, or a default telehealth endpoint.

### Data stored on the device

- profile and goals;
- heart rate, HRV, SpO2, temperature, weight, blood pressure, and glucose;
- sleep stages and related records;
- workouts, GPS tracks, running dynamics, routes, and training plans;
- app preferences and optional account session tokens.

The data is stored in the app's private SQLite database and app-specific files.

### Optional network features

The user must explicitly configure a server before these features can send data:

- account registration, login, and cloud backup;
- live track sharing;
- voice or camera streaming;
- ephemeris download;
- app update manifest or APK download.

Cloud backup uploads the selected health snapshot to the server configured by the
user. The project maintainer does not operate a default public service in the
public build. A self-hosted operator is responsible for authentication, encryption
in transit, retention, deletion, backups, and access control.

The public default basemap is MapLibre with Protomaps PMTiles derived from
OpenStreetMap. Map tiles, geocoding, road routing, weather, provider switching,
and similar requests are made only when the corresponding screen or function is
used. These requests contain the coordinates or query needed for the feature and
are subject to the selected provider's terms and privacy policy.

### Retention and deletion

Local data remains until the user clears app data, uses an in-app deletion
function where available, or uninstalls the app. Cloud data is controlled by the
server operator. There is no central account or deletion service in the public
project.

### Contact

Open a private report through the repository's Security Advisories page. Do not
post health data, tokens, watch credentials, databases, or server secrets in a
public issue.

## 简体中文

元环以本地优先为原则。公开构建不包含遥测、广告 SDK、默认云服务器或默认远程
医疗接口。

设备本地会保存个人资料、健康指标、睡眠、运动轨迹、训练计划、偏好设置以及用户
主动登录后的会话令牌。未配置服务器时，应用不会上传健康快照。

云同步、实时轨迹、语音/相机推流、星历下载和 App 更新只有在用户或构建者明确配置
地址后才会发起网络请求。自建服务运营者负责鉴权、传输加密、保留期限、删除、备份
和访问控制。

本地数据会保留到用户清除应用数据或卸载应用。云端数据由服务器运营者控制；公开
项目本身不提供集中账号或统一删除服务。

请通过仓库的 Security Advisories 私密报告问题，不要在公开 issue 中发布健康数据、
令牌、手表凭据、数据库或服务器秘密。
