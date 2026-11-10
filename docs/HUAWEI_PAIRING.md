# 华为手表配对与 HiChain 认证

Vitaloop 通过经典蓝牙（RFCOMM）直连华为/荣耀手表，认证走 HiChain。整体流程
与 [Gadgetbridge 的 Huawei/Honor 配对指南](https://gadgetbridge.org/basics/pairing/huawei-honor-pairing/)
一致；本页补充 Vitaloop 里的具体操作和常见失败处理。

## 先分清两种情况

| 情况 | 需要什么 | 做法 |
|---|---|---|
| **A. 手表从未绑过官方 App**（或愿意恢复出厂） | 只需手机上的华为账号 | 直接「首次配对」 |
| **B. 手表已绑定华为运动健康 App，不想恢复出厂** | 手表的 **HiChain 认证 key**（32 字节 hex） | 先取 key，再手动录入 |

认证 key 是手表在官方 App 首次配对时协商出来的密钥。没有它，Vitaloop 再次
认证会报 **"Authentication key negotiation failed"**（对应 Gadgetbridge 文档
的同名小节），只能恢复出厂或补录 key。

## A. 首次配对（手表未绑定官方 App）

1. 系统蓝牙里先把手表和手机**配对**（bond），保持手表在场、电量充足。
2. Vitaloop → **手表** 页 → 选择已配对手表 → **连接**。
3. 弹窗里输入**手表当前绑定的华为账号**（邮箱或手机号）。这一步会下发
   `SendExtendedAccountRequest`，账号不对手表不放行数据字典。
4. 手表弹出确认时点 **允许**。之后同步自动进行。

## B. 免恢复出厂：录入已有认证 key

### 1. 取得认证 key（17 位账号 ID 不再需要，key 本身是 64 个十六进制字符）

任选一种（来自 Gadgetbridge 指南的方法学）：

- **华为云网页（推荐，最简单）**
  1. 浏览器登录 [cloud.huawei.com](https://cloud.huawei.com/)；
  2. 按 F12 打开开发者工具：Firefox 看 **Storage → Cookies**，Chrome/Chromium 看 **Application → Cookies**；
  3. 找到名为 `userId` 的 Cookie，值应为 **17 位数字**——这是账号 ID，仅用于核对身份；
  4. 认证 key 本身请从旧版 App 迁移获取（见下），或抓包 `AuthResponse` 中的 32 字节密钥。
- **旧版 App 迁移**：如果你之前用旧版（awen-sync）配过这块表，Vitaloop 会自动把
  `authkey / huawei_account / fake_android_id` 整套凭据迁过来，**无需手动录入**。
- **root 手机**：root shell 里执行
  `grep old_user_id /data/data/com.huawei.health/shared_prefs/login_data.xml`
  可核对账号 ID；认证 key 在同一 App 的设备级 SharedPreferences（`device_<MAC>.xml` 的 `authkey`）。
- **adb logcat**：官方 App 有时会把 key 打进日志，`adb logcat | grep -i authkey` 碰运气。

### 2. 在 Vitaloop 里录入

1. **手表** 页 → 「华为账号与认证」→ **认证 key** 行 → 点击；
2. 粘贴 64 位十六进制字符串（大小写不限，保存时统一转小写）；
3. 保存后**重新连接手表**生效。

> 注意：**不要**在官方 App 里解绑手表——解绑会使认证 key 作废，只能恢复出厂重来。
> 若官方 App 与 Vitaloop 同时抢蓝牙，请先卸载官方 App 或撤销其全部权限。

## 常见失败对照

| 现象 | 原因 | 处理 |
|---|---|---|
| Authentication key negotiation failed | 手表已在官方 App 认证过，本地没有匹配的 key | 走上面 B 流程补录 key，或手表恢复出厂后重新配对 |
| 连上了但不同步数据 | 华为账号缺失/不对 | 在「华为账号与认证」确认账号，重连一次 |
| 官方 App 和 Vitaloop 反复互踢 | 两端争抢同一连接 | 卸载官方 App 或关闭其后台；每次切换都要重新点连接 |
| 手表弹确认后长时间无响应 | 蓝牙距离/干扰 | 手表贴近手机重试；查看手表页「连接日志」定位卡在哪一步 |

## 相关实现

- 协议栈源码改编自 Gadgetbridge（AGPL-3.0，归属见仓库 NOTICE / THIRD_PARTY_NOTICES）。
- App 内凭据存储：Rust 侧 `WatchIdentity`（address/account/authKey/fakeAndroidId），
  原生侧设备级 SharedPreferences（`authkey`），连接前由 Dart 落盘给协议栈。
