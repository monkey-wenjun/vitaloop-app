# 华为手表配对与 HiChain 认证

Vitaloop 通过经典蓝牙（RFCOMM）直连华为/荣耀手表，认证走 HiChain。整体流程
与 [Gadgetbridge 的 Huawei/Honor 配对指南](https://gadgetbridge.org/basics/pairing/huawei-honor-pairing/)
一致；本页补充 Vitaloop 里的具体操作和常见失败处理。

## 先分清两种情况

| 情况 | 需要什么 | 做法 |
|---|---|---|
| **A. 手表从未绑过官方 App**（或愿意恢复出厂） | 只需手机上的华为账号 | 直接「首次配对」 |
| **B. 手表已绑定华为运动健康 App，不想恢复出厂** | 旧版 App 迁移过来的 HiChain 凭据 | 安装旧版 App 完成迁移，或恢复出厂后重新配对 |

认证 key 是手表在官方 App 首次配对时协商出来的密钥。没有它，Vitaloop 再次
认证会报 **"Authentication key negotiation failed"**（对应 Gadgetbridge 文档
的同名小节），只能恢复出厂或使用已迁移的凭据。

> 公共构建不提供手动录入认证 key 的入口，也不会内置任何私有服务地址。

## A. 首次配对（手表未绑定官方 App）

1. 系统蓝牙里先把手表和手机**配对**（bond），保持手表在场、电量充足。
2. Vitaloop → **手表** 页 → 选择已配对手表 → **连接**。
3. 弹窗里输入**手表当前绑定的华为账号**（邮箱或手机号）。这一步会下发
   `SendExtendedAccountRequest`，账号不对手表不放行数据字典。
4. 手表弹出确认时点 **允许**。之后同步自动进行。

## B. 免恢复出厂：从旧版 App 迁移凭据

如果之前用旧版（awen-sync）配过这块表，Vitaloop 会自动把
`authkey / huawei_account / fake_android_id` 整套凭据迁过来，**无需手动录入**。

迁移后：

1. 打开 **手表** 页，确认「华为账号与认证」中已有账号信息；
2. 选择手表并点击 **连接**；
3. 连接成功后同步自动进行。

> 注意：**不要**在官方 App 里解绑手表——解绑会使认证 key 作废，只能恢复出厂重来。
> 若官方 App 与 Vitaloop 同时抢蓝牙，请先卸载官方 App 或撤销其全部权限。

## 常见失败对照

| 现象 | 原因 | 处理 |
|---|---|---|
| Authentication key negotiation failed | 手表已在官方 App 认证过，本地没有匹配的 key | 从旧版 App 迁移凭据，或手表恢复出厂后重新配对 |
| 连上了但不同步数据 | 华为账号缺失/不对 | 在「华为账号与认证」确认账号，重连一次 |
| 官方 App 和 Vitaloop 反复互踢 | 两端争抢同一连接 | 卸载官方 App 或关闭其后台；每次切换都要重新点连接 |
| 手表弹确认后长时间无响应 | 蓝牙距离/干扰 | 手表贴近手机重试；查看手表页「连接日志」定位卡在哪一步 |

## 相关实现

- 协议栈源码改编自 Gadgetbridge（AGPL-3.0，归属见仓库 NOTICE / THIRD_PARTY_NOTICES）。
- App 内凭据存储：Rust 侧 `WatchIdentity`（address/account/authKey/fakeAndroidId），
  原生侧设备级 SharedPreferences（`authkey`），连接前由 Dart 落盘给协议栈。
