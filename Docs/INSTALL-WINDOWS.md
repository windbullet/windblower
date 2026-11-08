# Windows 安装与续签

1. 从 https://sideloadly.io/ 获取 Windows 官方版本，按其说明安装 Apple 设备驱动。第一次使用 USB 连接 iPad，解锁并选择“信任此电脑”。
2. 从成功的 GitHub Actions 构建下载 IPA。PowerShell 中运行 `Get-FileHash -Algorithm SHA256 .\PureTone-unsigned.ipa`，与交付的 SHA256SUMS.txt 比较。
3. 将 IPA 拖入 Sideloadly，选择你的 iPad，输入你自己的 Apple 账号并完成其登录验证。不要把 Apple 账号密码写进源码或发送给开发者。
4. 安装成功后，按 iPad 提示在“设置 → 隐私与安全性”启用开发者模式（如需要并重启），以及在“设置 → 通用 → VPN 与设备管理”信任开发者。
5. 首次启动导入一首 FLAC / MP3；插入 3.5 mm 耳机，在“播放链路”记录实际输出采样率、模式与输出路由。锁屏后确认仍能播放。

## 续签和更新

- 免费签名一般 7 天到期。到期前让 Windows 电脑运行 Sideloadly 自动刷新组件，并能通过 USB 或同一局域网连接到 iPad。
- 到期不会自动删除音乐，但 App 会打不开。使用同一 Apple 账号、相同应用标识覆盖签名安装；**不要先卸载 App**。
- 只续签无需重新跑 GitHub Actions。代码更新才需要下载新 IPA。
- 切换 Apple 账号、修改 Bundle ID 或卸载会影响沙盒数据保留。先备份再操作。

## 备份

“文件 → 我的 iPad → PureTone → Music”中保留原始音乐；可以整目录复制到电脑或外部磁盘。曲库索引、歌单、EQ 和歌词使用 App“播放链路 → 准备资料备份 → 保存资料备份”导出 JSON，再从“恢复资料备份”合并恢复。峰值分析会重新计算，网络缓存不计入资料备份。

Wi-Fi 传歌需要 App 前台运行，手动锁屏或切换到后台会停止网页服务器；重新打开后使用相同访问码续传。不要把本地 HTTP 传输地址映射到公网。
