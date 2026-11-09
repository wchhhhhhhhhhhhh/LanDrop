# LanDrop 局域网传输协议 v1

三端（macOS / Android / HarmonyOS NEXT）共用同一套协议：**UDP 广播发现 + HTTP/1.1 传输**。
全部明文、无需外网、无需账号；可选 6 位配对码。

- TCP 服务端口：`47823`（可配置，发现包内会带真实端口）
- UDP 发现端口：`47824`（广播/单播均可）
- mDNS 服务类型：`_landrop._tcp`（可选，仅 macOS/Android 实现，鸿蒙走 UDP）

## 1. 设备身份

| 字段 | 说明 |
| --- | --- |
| `id` | 设备唯一 ID，16 位小写 hex，随安装生成并持久化 |
| `name` | 用户可见名，默认 "Mac 的 MacBook Air" / "Pixel 8" / "Mate 60" |
| `platform` | `macos` \| `android` \| `harmony` \| `cli` |
| `port` | 本机 HTTP 服务端口 |
| `pin_required` | 是否开启了配对码保护 |

## 2. 设备发现（UDP）

端点 `47824/UDP`，载荷为 UTF-8 JSON（≤ 512 字节），忽略未知字段。

探测（任何设备上线、下拉刷新、每 15s 心跳时发送）：

```json
{"app":"landrop","v":1,"type":"probe","id":"<我的id>","name":"<我的名字>","platform":"macos","port":47823}
```

收到 `probe` 的设备**单播回**自己的信息包（type=announce）：

```json
{"app":"landrop","v":1,"type":"announce","id":"...","name":"...","platform":"android","port":47823,"pin_required":false}
```

**收到 `probe` 或 `announce` 都视为对方在线**：立即把对端加入"附近设备"，`lastSeen` 更新；30s 未更新则从列表移除。
（只认 announce 会导致单向发现：会 probe 的一方永远看不见对方。）
发送方式：向 `255.255.255.255:47824` 以及每个网卡的定向广播地址各发一次；同时向已知对端单播（跨网段/广播被拦时仍可用）。

## 3. HTTP 接口

所有响应带 `Content-Type: application/json; charset=utf-8`（下载除外）。
统一错误体：`{"error":{"code":"...","message":"..."}}`，状态码 4xx/5xx。

开启配对码时，除 `GET /v1/info` 外所有请求必须带 `X-Pin: <6位数字>`，否则 `401 {"error":{"code":"pin_required"}}`。
比较使用固定时间比较，连续 10 次错误后 60s 内拒绝新尝试（`429`）。

### 3.1 `GET /v1/info`

```json
{"app":"landrop","v":1,"id":"...","name":"Mac 的 MacBook Air","platform":"macos",
 "version":"1.0.0","port":47823,"pin_required":false,
 "inbox":"/Users/me/Downloads/LanDrop","free_bytes":123456789}
```

### 3.2 `GET /v1/files`

收件箱内可下载的项目，按 `mtime` 倒序：

```json
{"files":[
  {"id":"f_7f3a","name":"IMG_0001.HEIC","size":2845123,"mime":"image/heic",
   "mtime":1762600000,"kind":"file"},
  {"id":"t_9c11","name":"剪贴板文本.txt","size":1024,"mime":"text/plain",
   "mtime":1762600100,"kind":"text"}
]}
```

`kind=text` 为收到的文本片段落盘成 `.txt`，与普通文件同构，便于直接下载。

### 3.3 `POST /v1/upload`（发送文件）

请求头：

| Header | 必填 | 说明 |
| --- | --- | --- |
| `X-File-Name` | 是 | 原始文件名，**percent-encoded UTF-8**（避免中文/空格/分号问题）；服务端只解码一次 |
| `X-File-Id` | 是 | 客户端生成的上传 ID，用于断点续传；仅允许 `[A-Za-z0-9._-]`，≤64 字节，禁止 `..` |
| `X-File-Size` | 是 | 文件总字节数；0 字节文件必须显式传 `0` |
| `X-Offset` | 否 | 本次字节起始偏移，默认 0；等于服务端已有长度时追加 |
| `Content-Length` | 是 | 本次字节数；最后一块或 0 字节文件可以是 `0` |
| `Content-Type` | 否 | MIME，缺省按扩展名猜 |

响应 `200`：

```json
{"id":"f_7f3a","name":"IMG_0001.HEIC","size":2845123,"received":2845123,"complete":true}
```

- 首次上传：服务端建 `<inbox>/.lan-drop-partials/<X-File-Id>.part`，写完后原子 rename 到 `<inbox>/<name>`（重名自动加 ` (1)`）。
- `X-Offset > 0`：追加写入；偏移与服务端记录不一致返回 `409 {"actual_offset":N}`，客户端据此重传。
- 单次 `Content-Length` 建议 ≤ 8 MiB，分块上传；`complete` 由服务端在 `received == total` 时返回，但客户端可只用 `received` 判断。
- 0 字节文件：发一次 `X-File-Size: 0`、`Content-Length: 0` 的请求，服务端立即落一个空文件并返回 `complete: true`。
- 目标文件名做清洗：去掉路径分隔符、`..`、控制字符，长度截断 200 字节；`X-File-Id` 同样不能用于路径穿越。

### 3.4 `GET/HEAD /v1/files/{id}/content`（接收文件）

- `HEAD` 返回 `Content-Length`、`Accept-Ranges: bytes`、`ETag`，不返回 body。
- `GET` 支持 `Range: bytes=start-end`，返回 `206` + `Content-Range`；非法范围 `416`。
- 文件名放在 `Content-Disposition: attachment; filename*=UTF-8''<pct>`。

### 3.5 `POST /v1/text`（发送文本/剪贴板）

```json
{"text":"hello","name":"可选的标题"}
```

响应 `200`：`{"id":"t_9c11","name":"hello.txt","size":5}`

### 3.6 `GET /v1/events`（可选，SSE）

`text/event-stream`，事件 `arrive`：

```
event: arrive
data: {"id":"f_7f3a","name":"a.zip","size":123,"platform":"android","at":1762600000}

```

每 20s 发送 `: ping` 保活。客户端可选实现（macOS 已实现，供 UI 实时刷新）。

## 4. 断点续传流程

1. 发送方 `HEAD /v1/files/{id}/content` 拿不到（这是接收方视角），因此续传只针对**上传方向**：
   发送方把文件按 4 MiB 切块，`X-File-Id` 固定，第 n 块 `X-Offset = n*4MiB`。
2. 网络中断后重试同一块：若服务端已写入部分，返回 `409 {"actual_offset":N}`，发送方跳到 `N` 继续。
3. 全部块发完即完成，服务端返回最终 `size`。

## 5. 安全边界

- 明文 HTTP，仅限可信局域网；不提供公网中继。
- 可选 6 位配对码，只防误触不防抓包（协议未加密，README 中已声明）。
- 文件名清洗 + 收件箱目录固定，禁止 `..` 穿越。

## 6. NFC 贴纸（v1）

贴纸是一张普通的 NDEF 标签（NTAG213 及以上），里面只放一条 URI 记录：

```
landrop://tap?v=1&id=<16hex>&n=<名字>&p=<平台>&h=<host>&t=<port>[&k=1]
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `v` | 是 | 载荷版本，当前为 `1` |
| `id` | 是 | 目标设备 id（16 位小写 hex，与发现包一致） |
| `n` | 否 | 设备名，percent-encoding 后的 UTF-8；读不到时用 `/v1/info` 补 |
| `p` | 否 | 平台：`macos` / `android` / `harmony` |
| `h` | 是 | 局域网地址（IPv4，或 `[IPv6]`，或 `*.local`） |
| `t` | 是 | HTTP 端口（写入时取对方当前实际端口，可能不是 47823） |
| `k` | 否 | `1` 表示对方开启配对码；**贴纸不写配对码本身** |

- 所有值都做 percent-encoding，保证纯 ASCII；`&`、`=`、中文都能往返。
- 写入顺序（容量不够时自动降级）：带名字 + AAR → 带名字 → 省略名字。
  AAR 让未启动/未安装的系统知道该拉起哪个应用；省略名字后仍可用 `id` + `/v1/info` 还原。
- 目标写入字节数可用 `ndefBytes()` 估算：`5 + len(uri) + 2`，带 AAR 再 +37。
  NTAG213 可用 144 字节，普通设备名足够。

**读取方（Android）校验顺序**：

1. 只接受 `landrop://tap`、`v=1`、`id` 为 8–32 位 hex、端口 1–65535。
2. `h` 必须是私网地址（10/8、172.16/12、192.168/16、169.254/16、100.64/10、
   IPv6 `fe80::/10` 与 `fc00::/7`、`*.local`）；公网地址/域名一律拒绝，
   避免"捡到一张贴纸就把文件传到公网"。
3. 碰一碰后先请求 `GET /v1/info`，确认返回的 `id` 与贴纸一致，再用返回的
   名字/端口/`pin_required`；不一致即视为贴纸过期或被改写。
4. 对方要求配对码且本机没存过时，在浮层里输入一次（按 `id` 记住）。

**触发方式**：

- 分享优先：相册/文件 → 分享 → LanDrop → 「NFC 碰一碰」→ 读贴纸 → 直接走原来的上传流程。
- 碰优先：直接碰贴纸 → 系统按 `ACTION_NDEF_DISCOVERED`（或 `VIEW landrop://`）
  拉起发送浮层，选完文件再走上传流程。

**安全与限制**：

- 贴纸是"公开的地址名片"：同一物理空间的人都能读到；不含配对码、不含密钥。
- 协议仍是明文 HTTP + 可选配对码；贴纸不能替代配对码保护。
- macOS 没有开放的 NFC 读卡接口：Mac 只能作为"被碰"的目标，
  由手机端写入贴纸（Mac 客户端的「贴纸」面板展示本机载荷供复制）。
