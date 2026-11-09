# LanDrop · 局域网文件互传

[![Release](https://img.shields.io/github/v/release/wchhhhhhhhhhhhh/LanDrop?style=flat-square)](https://github.com/wchhhhhhhhhhhhh/LanDrop/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Android%20%7C%20HarmonyOS-0A84FF?style=flat-square)](#)
[![自愿捐赠](https://img.shields.io/badge/%E8%87%AA%E6%84%BF%E6%8D%90%E8%B5%A0-%E5%BE%AE%E4%BF%A1%E6%94%AF%E4%BB%98-07C160?style=flat-square&logo=wechat&logoColor=white)](DONATE.md)

macOS / Windows / Android / HarmonyOS NEXT 四端原生客户端，共用一套「UDP 广播发现 + HTTP/1.1 传输」协议。
不上云、不登录、不依赖外网，同一 Wi-Fi 下发现即传。

## 下载

- [最新 Release](https://github.com/wchhhhhhhhhhhhh/LanDrop/releases/latest)
- **macOS**：`LanDrop-macOS-1.0.0.zip`（ad-hoc 签名；首次打开如被 Gatekeeper 拦截，请右键 → 打开）
- **Android**：`LanDrop-Android-1.0.0.apk`（release 签名，需允许安装未知来源；装过旧 debug 包请先卸载）
- **HarmonyOS**：`LanDrop-Harmony-1.0.0-unsigned.hap`（未签名，需自行配置证书签名；实验性适配，见下方说明）

源码：

```bash
git clone https://github.com/wchhhhhhhhhhhhh/LanDrop.git
cd LanDrop
```

```
LanDrop/
├── PROTOCOL.md              # 协议规范（发现、接口、断点续传、安全边界）
├── macos/                   # Swift + SwiftUI 原生 macOS 客户端（含无界面 CLI 模式）
├── windows-app/             # C# + WinUI 3 原生 Windows 客户端
├── installer/               # Windows 安装包（Inno Setup）
├── android/                 # Kotlin + Jetpack Compose（前台服务常驻接收）
├── harmony/                 # ArkTS + ArkUI（Stage 模型，HarmonyOS 26 / API 26）
└── .skills/harmony-build/   # 本机实测出来的鸿蒙命令行构建技能
```

## 功能

- 自动发现同一局域网内的设备（UDP 47824 广播，15s 心跳，30s 失效）
- 发送文件：4 MiB 分块、`X-Offset` 断点续传、中文/空格文件名安全
- 接收文件：落盘收件箱，重名自动 `(1)`、`(2)`，原子 rename
- 发送文本：文本落成 `.txt` 进对方收件箱
- 浏览/拉取对方收件箱（macOS、Android 已实现）
- 可选 6 位配对码（固定时间比较 + 连续 10 次错误锁定 60s）
- 实时传输进度 + 速度（滑动平均），收发双向都有记录
- 大文件不“假死”：4 MiB 分块 + 块内进度刷新（手机端每 150ms、Mac 端按 URLSession 写出字节数）；
  手机复制到缓存、连接首包阶段显示「准备中…」，不会长时间停在 0%
- 发送可「暂停 / 继续 / 取消」：暂停即断点，继续按 `X-Offset` 续传，不重传已发送部分
- 选择来源双入口：Android 系统图库（Photo Picker）+ 文件管理器（SAF）；macOS 图片面板 / 任意文件
- **NFC 碰一碰**：在「贴纸」里选设备写入 NTAG 贴纸，之后碰一下贴纸就能发送（见下方说明）
- **分享二级菜单**：相册/文件 → 分享 → LanDrop → 半透明浮层，选「NFC 碰一碰」或附近设备，不跳主界面
- 碰贴纸可直接拉起发送浮层（LanDrop 没打开也行）

## 协议速览

| 项 | 值 |
| --- | --- |
| 发现端口 | `47824/UDP`（probe / announce JSON） |
| 传输端口 | `47823/TCP` HTTP，占用时自动 +1 |
| 接口 | `/v1/info`、`/v1/files`、`/v1/upload`、`/v1/text`、`/v1/files/{id}/content` |
| 续传 | 上传块带 `X-File-Id`/`X-Offset`/`X-File-Size`，偏移冲突返回 `409 {actual_offset}` |
| 下载 | `Range: bytes=`，`206 Partial Content` |

细节见 [PROTOCOL.md](PROTOCOL.md)。

## macOS

```bash
cd macos
swift build            # 需要完整 Xcode（SwiftUI 宏）
./.build/debug/LanDrop # 图形界面

# 无界面模式（做接收端 / 联调 / CI）
./.build/debug/LanDrop --serve --port 47823 --dir ~/Downloads/LanDrop --pin 123456
```

打包成 `.app`：

```bash
cd macos && ./scripts/make_app.sh    # 产出 LanDrop.app
```

- **文件操作**：右上角浮窗和「传输记录」里的每个完成项都能直接「复制」（可粘贴到 Finder）或「打开位置」
  （Finder 中显示）；浮窗鼠标移上去不会自动消失，最多同时显示 3 个完成项，右键还能「拷贝路径」。
- **NFC 贴纸面板**：顶栏「贴纸」查看本机贴纸内容（名字、地址、端口、字节数），可一键复制。
  macOS 没有开放的 NFC 读卡接口，Mac **不能**碰贴纸、也写不了贴纸；贴纸由手机端写入，
  手机碰贴纸后走原有 HTTP 传输。没有手机端时，也可以把复制出来的内容粘进任意 NDEF 写入 App（URI 记录）。

## Windows（WinUI 3）

```powershell
# 需要 Visual Studio 2022/2026（含 UWP 工作负载）+ .NET 10 和 Windows App SDK 1.8 Runtime
msbuild windows-app\LanDrop.csproj /restore /t:Publish `
  /p:Configuration=Release /p:Platform=x64 /p:RuntimeIdentifier=win-x64 `
  /p:SelfContained=true /p:WindowsAppSDKSelfContained=false /p:PublishDir=windows-app\out\

# WinUI 未打包模式只认 resources.pri，构建产物叫 LanDrop.pri，需要补一份
copy windows-app\out\LanDrop.pri windows-app\out\resources.pri
```

- 运行前安装 **Windows App Runtime 1.8**（框架依赖；自包含模式在部分虚拟机上会在托管代码前挂掉）。
- 安装包：`installer\LanDrop.iss` + `instaler\build-installer.ps1`（Inno Setup，装到 `Program Files\LanDrop`，带开始菜单/桌面快捷方式和卸载项）。
- 功能与 macOS 对齐：设备发现、收发文件/文本、进度、收件箱、复制/在文件夹中显示、开机自启、NFC 贴纸内容生成、捐赠入口。

## Android

```bash
cd android
export JAVA_HOME=/Library/Java/JavaVirtualMachines/liberica-jdk-17.jdk/Contents/Home
export ANDROID_HOME=~/AndroidTools/sdk

# 本机调试：使用 AGP 默认 debug 签名
~/AndroidTools/gradle-8.9/bin/gradle assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk

# 正式包：先准备自己的 release keystore
cp keystore.properties.example keystore.properties   # 填入 storeFile / 密码
~/AndroidTools/gradle-8.9/bin/gradle assembleRelease
adb install -r app/build/outputs/apk/release/app-release.apk
```

- 前台服务（`dataSync`）保证息屏/切后台仍能接收，通知栏常驻「正在局域网接收文件」。
- 收件箱：`Android/data/com.landrop.android/files/LanDrop/inbox`，可用系统「打开/分享」导出。
- 最低 API 26（Android 8.0）。
- **正式签名**：`android/keystore/release.keystore` 与 `android/keystore.properties` 已被 `.gitignore` 忽略，不会进仓库；请离线备份，丢失后无法给已安装用户发升级。
- **签名变更**：从 v1.0.0 起 Android 发行包使用独立 release key；之前装过 debug 包的用户需要卸载后重装。
- 已接入系统分享：相册/文件管理器 → 分享 → LanDrop，弹出半透明二级菜单（背后还是相册），
  选「NFC 碰一碰」或附近设备即可发送，不会跳到主界面。
- **NFC 贴纸**：顶部「贴纸」→ 选本机或附近设备 → 把 NTAG213 及以上贴纸靠近手机背面写入。
  写好后：相册/文件 → 分享 → LanDrop → **NFC 碰一碰** → 碰贴纸即发送；
  也可以直接碰贴纸，弹出「选择图片/文件」浮层再发送。
- 贴纸只写设备名、局域网地址、端口和「是否需要配对码」，**不写配对码**；
  读取时只接受私网地址，并会用 `GET /v1/info` 校验设备 id，防止贴纸过期/被改写。


## HarmonyOS NEXT

> **实验性适配**：鸿蒙端目前可以命令行编译，但存在已知 bug、未做性能优化，且未签名 HAP 不能直接安装，**不是开箱即用**。

```bash
cd harmony
cp build-profile.example.json5 build-profile.json5   # 然后按需配置签名
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export HOME="$PWD/.home"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`。

**签名**：未配置 `signingConfigs` 时只能出未签名包，无法 `hdc install`。
在 DevEco Studio 里登录华为账号自动生成调试证书，或在 `build-profile.json5` 里配置 `.p12/.cer/.p7b` 后重新构建。

## 已实测

| 项 | 方式 | 结果 |
| --- | --- | --- |
| macOS 编译 | `swift build` | ✅ |
| `/v1/info` 免 pin | curl | ✅ |
| 无 pin → 401 | curl | ✅ |
| 文本接口 + 中文名 | curl | ✅ |
| 10 MB 分块上传（3 块） | curl | ✅ 落盘 10485760 字节 |
| HEAD / Range 206 / 全量下载 | curl + md5 | ✅ 与原文件一致 |
| 偏移冲突 409 | curl | ✅ 返回 `actual_offset` |
| UDP 发现（接收侧） | 手工 announce | ✅ 出现在附近设备 |
| 鸿蒙编译 | `hvigorw assembleHap` | ✅ BUILD SUCCESSFUL |
| 安卓编译 | `gradle assembleDebug` | ✅ |
| 安卓装机 | `adb install` | ✅ vivo V2199A / Android 14 |
| 安卓接收 100MB | curl 直传 | ✅ 落地 104857600 字节 |
| 图库选择器 | 系统 PhotoPicker | ✅ 打开并回传 URI |
| 接收进度/速度 | 手机 UI | ✅ 显示 `42% · 6.9 MB/s` |
| Release 覆盖安装 | `adb install -r` | ✅ vivo V2199A（同签名升级，数据保留） |
| 分享二级菜单 | 相册 → 分享 → LanDrop | ✅ 半透明浮层，背后仍是相册 |
| NFC 贴纸页面 | 手机 UI | ✅ 目标选择 / 写入页 / NFC 状态 |
| 实体贴纸写入 | 手机 + 贴纸 | ✅ 写入成功（vivo V2199A） |
| 碰贴纸拉起浮层 | `ACTION_NDEF_DISCOVERED` | ✅ 直接进发送浮层，不经过主界面 |
| 分享 → 碰贴纸 → 发送 | 手机 + 贴纸 | ✅ 派发链路走通，文件到达 macOS 收件箱（adb 模拟碰贴纸） |

## 自愿捐赠

LanDrop 免费、无广告、不登录、不上传云端。如果它帮到了你，可以自愿捐赠；不捐赠不影响任何功能。

[![自愿捐赠（微信）](https://img.shields.io/badge/%E8%87%AA%E6%84%BF%E6%8D%90%E8%B5%A0-%E5%BE%AE%E4%BF%A1%E6%94%AF%E4%BB%98-07C160?style=for-the-badge&logo=wechat&logoColor=white)](DONATE.md)

<p><a href="DONATE.md"><img src="docs/donate-wechat.png" alt="微信支付收款码" width="220"></a></p>

> 收款方：皓子(\*\*皓) · 微信支付

## 已知限制

- 明文 HTTP，仅限可信局域网；配对码只防误触，不加密内容。
- 鸿蒙端为前台运行，暂未接入 `ContinuousTask` 后台长时任务。
- 广播发现依赖同一网段；跨网段请用「手动输入 IP」（macOS 已提供入口）。
- Windows 只是还没时间做，正在开发中，很快上线；iOS 暂未实现。协议与实现解耦，补客户端只需按 PROTOCOL.md 实现 HTTP 侧。
- NFC 碰一碰需要实体 NTAG213/215 贴纸；Mac 无 NFC 读卡硬件，只能作为"被碰"的目标。
- NFC 只负责"选设备"，传输仍是局域网 HTTP；贴纸内容被改写时会在碰一碰后校验出来。
