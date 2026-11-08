# PureTone

面向 iPad mini 5 / iPadOS 26 的个人原生音乐播放器。SwiftUI 界面，C++20 音频核心；公开源代码，GPL-3.0-only。

**当前状态：可在 Windows 编译并验证音频内核；iPad App 的 Xcode 构建、真机路由及局域网联调尚待运行。没有把未进行的验证标为通过。** 见 [验证状态](Docs/VALIDATION.md)。

## 功能

- FLAC 原始整数解码 / MP3 原采样率浮点解码；libsoxr VHQ 仅在输出采样率不同时启用。
- 1–32 段双精度 TPT 参数 EQ，七种滤波器、频率、Q、增益、前置增益、预设和实际响应曲线。
- 8× 真峰值分析、静态防削波增益；实时编辑采用保守余量，停止编辑后分析并校准。
- 原文件曲库、文件夹/专辑/歌手、收藏、歌单、队列、同格式无缝衔接、锁屏/耳机控制。
- Wi-Fi 网页传歌：文件夹拖放、1 MiB 分块、两个文件并行、SHA-256 校验、续传。
- SMB 2/3、WebDAV、HTTP(S)、手动 DLNA ContentDirectory；EQ 旁路支持原文件范围串流，EQ 开启先完整缓存。
- 网易 YRC、QQ QRC、酷狗 KRC、LRCLIB 歌词，逐字→逐行→文本降级、本地歌词、缓存和手动绑定。
- 输出路由、实际采样率、SRC、会话模式和增益诊断。

## 没有 Mac 时获取安装包

1. 在自己的 GitHub 账号中创建**公开空仓库**，上传本工程。音乐、账号凭据、签名证书不上传。
2. 仓库 **Actions → Build and verify PureTone → Run workflow**。首次会从源码编译三个原生依赖。
3. 工作流先运行音频、网页及模拟器测试，再构建真机 App；成功后下载 `PureTone-unsigned-and-reports`。
4. 解压获得 `PureTone-unsigned.ipa` 和 `SHA256SUMS.txt`，按 [Windows 安装说明](Docs/INSTALL-WINDOWS.md) 用 Sideloadly 签名。

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
node --test Tests/Web/*.test.cjs
```

Windows 使用 MinGW-w64 和 Ninja，动态库名为 `libpuretone.dll`；Linux 为 `libpuretone.so`。测试依赖见 `Scripts/requirements-test.txt`。

## 音频边界

非混音会话不等于独占 DAC；请求采样率不等于实际采样率。RemoteIO 无权承诺绕过所有系统处理。App 显示实际信息，模拟耳机口是否失真需要外部设备测量。MP3 的已有编码损失不能恢复，EQ 的预期幅相变化不是“bit-perfect”。

更多实现及校准行为见 [音频设计](Docs/AUDIO.md)、[网络与存储接口](Docs/NETWORK.md)、[开源声明](THIRD_PARTY_NOTICES.md)。
