# Windows 安装与续签

适用：Windows 电脑、iPad mini 5、iPadOS 26、PureTone 0.2.0。使用免费 Apple 账号，经 Sideloadly 签名安装；无需 Mac 或越狱。免费签名通常有效 7 天，需要定期续签。

说明核对日期：2026-11-09。依据 [Sideloadly 官网](https://sideloadly.io/) 和 [官方 FAQ](https://sideloadly.io/faq)；不同版本的按钮位置可能变化，以按钮名称为准。

## 1. 准备安装文件

需要一条支持数据传输的 Lightning 线、联网的 Windows 电脑及可正常登录的个人 Apple 账号。首次安装使用 USB。

- 安装包：[PureTone 0.2.0 未签名 IPA](https://github.com/windbullet/windblower/raw/0291dc52a53f18d3f3254d999ed3e23bd582e4da/PureTone-unsigned.ipa)。本工作区也有 `D:\ios\build\PureTone-0.2.0-unsigned.ipa`。
- 签名工具：[Sideloadly 官网](https://sideloadly.io/)，普通 Windows 10/11 电脑选 Windows 64-bit。
- Apple 组件：按 Sideloadly 官网下载区域的说明，安装其链接的 **Web iTunes 64-bit** 和 **Web iCloud**。

Sideloadly 官方要求 Windows 使用网页版 iTunes/iCloud；若已有 Microsoft Store 版，先按官网提示卸载对应版本，再安装网页版。安装后重启电脑。Apple Devices 能识别设备不等于 Sideloadly 的依赖已经齐全；遇到驱动冲突先按官方 FAQ 检查，不要反复混装多个版本。

IPA 无需解压。可选 SHA-256 校验（PowerShell）：

```powershell
Get-FileHash -Algorithm SHA256 "D:\ios\build\PureTone-0.2.0-unsigned.ipa"
```

本版期望值（不区分大小写）：

```text
a36e643fe5dbd3e8a80c4ecfb2f451836cfe32fed93e557559e1ef3d99066b4e
```

下载到其他文件夹时替换命令中的路径。

## 2. 连接并信任电脑

1. 解锁 iPad，用 Lightning 数据线连接电脑。
2. iPad 显示“要信任此电脑吗”时选择“信任”，输入 iPad 锁屏密码。
3. 打开 iTunes，确认能看到 iPad 设备图标。保持现有同步设置即可。
4. 打开 Sideloadly，在设备选择框（有的版本标为 iDevice）中选择这台 iPad。

显示 `No devices detected` 时，先解决识别问题：保持 iPad 解锁、换 USB 口/数据线、重开 iTunes/Sideloadly，确认“信任此电脑”和 Apple 组件安装完成。首次配对成功前不依赖无线连接。

## 3. 签名并安装

1. 将 IPA 拖到 Sideloadly 的 IPA 图标/文件区域，或点击该区域选择文件。
2. 确认设备为自己的 iPad。
3. 在 Apple ID/Apple Account 一栏填写自己的个人 Apple 账号。
4. 高级选项保持默认；保留应用名称和现有 Bundle ID 设置，保留自动生成标识的方式。原始 Bundle ID 为 `com.puretone.player`，工具可能为免费签名生成派生标识，之后必须保持一致。
5. 点击 **Start / Install**。弹出登录框后输入 Apple 账号的普通密码，完成双重认证。iPad 锁屏密码仅在 iPad 的信任/开发者模式操作中输入。
6. 等待签名、上传和安装完成，看到 **Done / 安装成功**，并在 iPad 桌面或 App 资源库找到 PureTone。

免费账号按 Sideloadly 默认登录流程使用普通账号密码。官方 FAQ 表示“App 专用密码”仅部分支持特定付费开发者配置，不是本教程的免费默认方案。密码和验证码只在你本机的工具/Apple 验证界面使用，不发给开发者。

## 4. 开启开发者模式并信任 App

首次打开若提示“需要开发者模式”：

1. iPad 进入 **设置 → 隐私与安全性 → 开发者模式**。
2. 开启开关，按提示重启。
3. 重启后确认“打开/启用开发者模式”，输入锁屏密码。

若找不到开发者模式，先完成 USB 配对并尝试安装一次，然后重新打开设置；必要时重启 iPad 后查看。

首次打开若提示“未受信任的开发者”：

1. 进入 **设置 → 通用 → VPN 与设备管理**。
2. 在“开发者 App”等分组找到本次签名账号。
3. 点击进入，选择“信任”，按提示确认；验证时保持联网。
4. 再次打开 PureTone。

这两项是不同的系统要求，出现哪一项就完成对应步骤。若该入口尚不存在，先确认 App 已成功安装。

## 5. 导入音乐并试播

建议先导入一首 FLAC 和一首 MP3 验证，再批量传库。

Wi-Fi 传歌：电脑和 iPad 连接同一个可互通的局域网；PureTone 侧栏选择 **Wi-Fi 传歌 → 开启 Wi-Fi 传歌**，允许“本地网络”访问。在电脑 Chrome/Edge 中打开 App 显示的完整 `http://地址:端口`，输入访问码，选择文件或文件夹上传。等待校验和入库完成。iPad 保持 App 前台、屏幕亮着；普通局域网传歌页面用 HTTP，按 App 实际显示输入地址，不自行改为 HTTPS。访客 Wi-Fi/AP 隔离会阻断互访。

系统文件导入：在曲库导入菜单选择 **导入音乐文件** 或 **导入整个文件夹**，从 iPad“文件”中选择来源。若在外部直接复制文件进 PureTone 的 Music 文件夹，回 App 选择 **扫描本机 Music 文件夹**。

第一次试播：插入 3.5 mm 耳机，适中系统音量，先关闭 EQ 播放；打开 **播放链路** 核对源格式、App 处理采样率、会话采样率、RemoteIO 客户端/输出端及 SRC 状态。再开启 EQ，等待完整分析与校准结束，确认出现已生效状态。测试暂停/恢复和锁屏后台播放。

mini 5 的实际耳机路由和系统输出仍待真机确认。显示“硬件端未验证”是缺失回读信息的标记，不是已证明没有 SRC。

## 6. 每 7 天续签

手动续签：建议每 5～6 天操作一次。USB 连接并解锁 iPad，Sideloadly 选择同一个 IPA、同一个 Apple 账号和相同应用标识，再点击 Start/Install 覆盖安装。到期通常只是 App 无法打开，不会自动删除音乐；过期后仍可按此方式续签。**不要先卸载 PureTone**，卸载会移除沙盒中的音乐和资料。

自动续签：安装时启用自动刷新选项（Automatic Refresh），让 Sideloadly Daemon 后台组件运行，电脑在需要刷新时开机且未休眠，并可通过 USB 或已配置的 Wi-Fi 配对访问 iPad。它不是 iPad 脱离电脑自行续签。

配置 Wi-Fi 续签：先完成一次 USB 安装，然后在 **iTunes → iPad → 摘要 → 选项** 中启用“通过 Wi-Fi 与此 iPad 同步”，应用设置。电脑和 iPad 保持同一网络；若无线发现失败，按官方 FAQ 检查 Bonjour 和防火墙许可，或直接改用 USB。PureTone 的网页传歌与 Sideloadly 无线续签是两套独立功能。

更新播放器：将新版 IPA 拖进 Sideloadly，用原账号和原标识覆盖安装。只续签无需重新编译；安装新版才换 IPA。免费账号一般最多同时有 3 个此类侧载 App；其他签名工具安装的 App 也可能占用名额。

## 7. 常见问题

| 现象 | 处理 |
| --- | --- |
| Sideloadly 找不到设备 | 先确认 iTunes 能识别、iPad 已信任电脑、数据线支持传输，再检查官网要求的 Apple 组件。 |
| 密码/双重认证失败 | 先在 Apple 官方页面确认账号能正常登录，完成账号提示；校对电脑和 iPad 日期时间，重开工具，按默认普通密码流程登录。 |
| Anisette/iTunes/iCloud 相关报错 | 按 Sideloadly 官方下载区域和 FAQ 修复 Apple 依赖，重启电脑后再试；保留完整错误文字排查。 |
| 需要开发者模式 | 完成设置中的开关、重启和重启后的再次确认。 |
| 未受信任/无法验证 App | 在 VPN 与设备管理中信任本次开发者，联网验证；过期则续签。 |
| 已达到 3 个 App 限额 | 确认其他侧载 App 的占用；备份后再决定停用/移除哪一个。App ID 注册配额是另一项限制，反复改 Bundle ID 不能可靠解决。 |
| 7 天后打不开 | 同账号、同标识覆盖续签，保留现有 App 数据。 |
| Wi-Fi 传歌网页打不开 | 确认 App 前台、服务器已开启、本地网络权限允许、地址端口正确且无访客网络隔离。 |
| App 打开后闪退或播放失败 | 记录出现阶段、iPadOS 版本、Sideloadly 日志/报错；先保留 App，便于诊断和保护曲库。 |

## 8. 备份

原始音乐位于 **文件 → 我的 iPad → PureTone → Music**，整目录复制到电脑或外部磁盘。

歌单、EQ、曲库索引和歌词：PureTone **播放链路 → 准备资料备份 → 保存资料备份**，导出 JSON，之后通过“恢复资料备份”恢复。原始音乐另行备份；NAS 密码不导出，峰值分析可重建。
