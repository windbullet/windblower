# 网络、存储与歌词接口

## Wi-Fi 上传

HTTP 8080，用户手动启停，授权头 `Authorization: Bearer <六位访问码>`。静态页面可直接打开；所有 `/api/` 接口校验访问码与同源 Origin。

| 接口 | 行为 |
|---|---|
| POST /api/uploads | `{path,size,sha256}` 创建或恢复；返回 `{id,path,size,sha256,offset,completed}` |
| PUT /api/uploads/{id} | 原始 1 MiB 以内分块；`X-Upload-Offset` 必须等于持久化 offset |
| GET /api/uploads/{id} | 查询进度 |
| POST /api/uploads/{id}/complete | 校验字节数和 SHA-256，然后原子移动并入库 |

目录路径拒绝绝对路径、盘符、空组件、`.`、`..` 与 NUL；页面逐块计算 SHA-256，不依赖仅 HTTPS 可用的浏览器 SubtleCrypto。服务端残片在 Application Support/Uploads，不会被曲库扫描为音频。完全相同文件重复上传幂等；同路径不同内容产生新文件名。

## 远程源

SMB 使用 libsmb2/AMSMB2；HTTP/WebDAV/DLNA 使用 URLSession。WebDAV PROPFIND Depth=1，DLNA 以用户提供的设备描述 URL 定位 ContentDirectory，经 SOAP Browse 分页读取 DIDL-Lite。无 SSDP/组播依赖。

原字节源接口 `PTByteSource` 提供长度及随机偏移读取回调。回调仅在解码线程运行；网络页缓存至多八个 1 MiB 块。HTTP 需要 206 Content-Range，不支持时提示完整缓存。EQ 开启时完整下载原资源，并按相同音频内核分析；不会用服务端有损转码维持播放。

完整缓存记录 SHA-256 与远端 ETag/Last-Modified 或 SMB 修改时间及长度；复用前重新确认远端标识和本地哈希，下载前后检查资源是否改变。服务器不给可用标识时重新下载，不默默复用旧缓存。

NAS 密码存于 Keychain，连接参数不包含密码。不忽略 HTTPS 证书错误；HTTP 局域网通过 NSAllowsLocalNetworking 支持。

## 歌词

统一 `Lyrics → [LyricLine → LyricWord]`，时间以秒表示；源格式的毫秒在解析时转换。无逐字时间时不按字数编造时间。在线源为非官方接口，失效时继续尝试其他源，并保留离线缓存与本地伴随歌词。

匹配优先考虑歌名、歌手、时长及 Live/Remix 等版本，之后比较逐字/逐行/文本级别。手动绑定 pinned 保存，不被自动匹配覆盖。LRCLIB 支持 lyricsfile YAML、syncedLyrics、plainLyrics；遵守 Retry-After。

存储文件结构：Documents/Music 为原文件；Application Support/PureTone 下保存 SQLite、封面、歌词和上传状态；Caches/Originals 为可清理的远程原版缓存。
