# PureTone

面向 iPad mini 5 / iPadOS 26 的个人原生音乐播放器。SwiftUI 界面，C++20 音频核心；公开源代码，GPL-3.0-only。

**当前版本：0.4.1 已生成未签名 IPA，27 项单元测试与 2 项界面测试通过。修复目录别名下的相对路径生成、按原文件哈希恢复失效路径，补充 FLAC 打开错误与文件读取诊断。保留 0.4.0 的 EQ 对数坐标、只读曲线、音乐多选、歌单加歌及歌词修复，音频处理算法不变。用户报告的覆盖更新后播放故障仍需用真机结果确认根因；mini 5 的耳机路由、后台与局域网整机联调仍需验收。** 见 [0.4.1 文件访问](Docs/0.4.1-FILE-ACCESS.md)、[0.4.0 变更](Docs/0.4.0-CHANGES.md)、[验证状态](Docs/VALIDATION.md)。

## 功能

- FLAC 原始整数解码 / MP3 原采样率浮点解码；libsoxr VHQ 仅在输出采样率不同时启用。
- 1–32 段双精度 TPT 参数 EQ，七种滤波器、频率、Q、增益、前置增益和预设；对数频率响应曲线只读，下方滑块和数值输入调参。
- 8× 真峰值分析、静态防削波增益；新参数后台校准后切入，默认 A/B 保持共同前置增益。
- 本地解码/SRC 超满刻度自动测峰并恢复，旁路保留必要的固定源信号衰减，结果缓存用于下次起播。
- 原文件曲库、文件夹/专辑/歌手、收藏、歌单、队列；多选收藏/添加歌单/删除、歌单加号选取现有歌曲、同格式无缝衔接、锁屏/耳机控制。
- Wi-Fi 网页传歌：文件夹拖放、1 MiB 分块、两个文件并行、SHA-256 校验、续传。
- SMB 2/3、WebDAV、HTTP(S)、手动 DLNA ContentDirectory；EQ 旁路支持原文件范围串流，EQ 开启先完整缓存。
- 网易 YRC、QQ QRC、酷狗 KRC、LRCLIB 歌词，逐字→逐行→文本降级、本地/内嵌歌词、缓存、手动搜索绑定和逐源诊断。
- 输出路由、实际采样率、SRC、会话模式和增益诊断。

## 没有 Mac 时获取安装包

1. 在自己的 GitHub 账号中创建**公开空仓库**，上传本工程。音乐、账号凭据、签名证书不上传。
2. 仓库 **Actions → Build and verify PureTone → Run workflow**。首次会从源码编译三个原生依赖。
3. 工作流先运行音频、网页及模拟器测试，再构建真机 App；成功后下载 `PureTone-unsigned-and-reports`。
4. 解压获得 `PureTone-unsigned.ipa` 和 `SHA256SUMS.txt`，按 [Windows 安装说明](Docs/INSTALL-WINDOWS.md) 用 Sideloadly 签名。

本仓库的最近成功安装包与校验值也保存在 [构建产物分支](https://github.com/windbullet/windblower/tree/codex/build-artifacts)。`build.json` 标记安装包对应的源码与构建，`latest.json` 记录最近一次尝试；两者可能属于不同运行。请确认构建和校验值，不把失败尝试误当作新安装包。

0.4.1 测试版本：[未签名 IPA](https://github.com/windbullet/windblower/raw/a0c2d70de43412092f80448dc873b98fbabcfabd/PureTone-unsigned.ipa) · [SHA-256](https://github.com/windbullet/windblower/blob/a0c2d70de43412092f80448dc873b98fbabcfabd/SHA256SUMS.txt) · [构建与测试](https://github.com/windbullet/windblower/actions/runs/44105750870)。更新时使用原 Apple 账号和应用标识覆盖安装，不先卸载。

免费 Apple 账号签名约 7 天有效；续签与重新云编译是两件独立的事。保持同一个 Apple 账号和 Bundle ID，采用覆盖安装保留本机数据。

GitHub 工作流不读取 Apple 账号，不使用付费 macOS 大型运行器。公开仓库标准运行器可免费使用；以账号当前政策为准。

## 构建与测试

macOS + Xcode 26.2 + XcodeGen + CMake：

```bash
python3 Scripts/build_dependencies.py --platform ios
xcodegen generate
xcodebuild build -project PureTone.xcodeproj -scheme PureTone \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO
python3 Scripts/package_ipa.py .build/DerivedData/Build/Products/Release-iphoneos/PureTone.app
```

跨平台音频测试：

```bash
python Scripts/build_dependencies.py --platform host
cmake -S . -B .build/host -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$PWD/Vendor/host"
cmake --build .build/host --parallel 4
ctest --test-dir .build/host --output-on-failure
python Tests/Audio/verify_dsp.py --library .build/host/libpuretone.dylib
python Tests/Audio/verify_codecs.py --library .build/host/libpuretone.dylib
python Tests/Audio/verify_audit.py --library .build/host/libpuretone.dylib
python Tests/Audio/verify_regressions.py --library .build/host/libpuretone.dylib
node --test Tests/Web/*.test.cjs
```

Windows 使用 MinGW-w64 和 Ninja，动态库名为 `libpuretone.dll`；Linux 为 `libpuretone.so`。测试依赖见 `Scripts/requirements-test.txt`。

## 音频边界

非混音会话不等于独占 DAC；请求采样率不等于实际采样率。RemoteIO 无权承诺绕过所有系统处理。App 显示实际信息，模拟耳机口是否失真需要外部设备测量。MP3 的已有编码损失不能恢复，EQ 的预期幅相变化不是“bit-perfect”。

更多实现及校准行为见 [音频设计](Docs/AUDIO.md)、[网络与存储接口](Docs/NETWORK.md)、[开源声明](THIRD_PARTY_NOTICES.md)。
