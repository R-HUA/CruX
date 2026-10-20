# CruX

CruX 是用 ArkTS 编写的 HarmonyOS 客户端，把真实的 x.com 网页应用装进原生 HarmonyOS 外壳：时间线、搜索、通知、私信、个人主页等内容交给网页，导航、发帖编辑、图片查看、系统交互等"外壳"部分由原生实现。不需要 API Key，登录沿用网页会话。

| 项目 | 值 |
| --- | --- |
| 应用名称 | CruX |
| 包名（bundleName） | `com.crux.web` |
| 版本 | `1.1.0`（versionCode 2） |
| 最低 API | 24（HarmonyOS 6.1.1） |
| 开发语言 / 模型 | ArkTS / Stage 模型 |
| 许可协议 | Apache-2.0 |

## 主要功能

- **五个原生标签页**：首页、探索、通知、私信、我。首页对应 `https://x.com/home`，探索 `/explore`，通知 `/notifications`，私信 `/i/chat`，"我"先确认当前登录账号再打开其个人主页。五个入口共用同一个常驻 WebView，切换标签不会重建网页、也不会丢会话。
- **原生顶栏**：首页顶部是账号头像加"为你推荐 / 正在关注"切换器（点击驱动网页里真实的 tab，而不是伪造切换）；搜索和私信保留官网完整顶栏，其余已支持页面显示原生页面标题与副标题（个人主页显示 `@handle`），左侧按需出现返回箭头，右侧最多一个齿轮。原生顶栏滚动前全透明，随滚动渐变出模糊材质。
- **账号菜单**：点击首页头像展开原生菜单，可进入网页账号切换、个人资料、书签、列表、设置与隐私、页面分享，以及外观和网络设置。
- **搜索**：沿用官网搜索框、候选词和搜索历史，由网页处理输入与结果页跳转。
- **原生发帖**：首页显示发帖悬浮按钮，底部编辑面板提供文字输入、"媒体与更多"、取消和发布操作。发布按钮按网页对当前账号和文本的校验结果启用；提交结果不明确时保留草稿并提示核查。"媒体与更多"切换到完整网页编辑器，账号识别或自动填充失败时仍可进入并复制原草稿。移交时保留按账号保存的原正文，重启后须确认发布结果才能恢复或清除；网页内后续编辑由网页管理。支持 Ctrl/Cmd+Enter 发布、Esc 关闭。
- **帖子详情**：底部标签栏替换为回复栏，点击进入 `/intent/tweet?in_reply_to=<帖子 ID>` 的网页回复流程。
- **未读角标**：优先读取网页已有 `ViewerBadgeCounts` 响应中的通知与聊天计数；没有新鲜响应时，从网页自身导航项读取（`document.title` 的 `(3) …` 前缀作为通知兜底）。显示在标签栏角标上，并同步给桌面图标角标；账号变化后丢弃旧响应。每 30 秒、每次页面跳转和回到前台时刷新；页面尚未上报时保留旧值而非清零。
- **原生图片查看器**：支持帖子图片和个人主页头像，卡片和视频封面可长按查看，封面仅标记为可用尺寸。支持图片翻页、缩放、保存、系统分享和复制链接；加载失败可重试或返回网页查看。下载任务无法确认时，重试会重新加载当前网页，需要重新打开图片。可查看真实 GIF 图片，视频形式的动图由网页播放。
- **系统集成**：站外链接交给系统浏览器，Google / Apple 登录留在应用内；上传媒体使用系统相册选择器；ArkWeb 下载完成后由用户选择保存位置；定位请求先弹原生确认框再申请运行时权限；网页全屏视频接管系统栏。
- **外部分享与链接**：接收系统分享的文字和链接。单独的 X 链接在应用内打开，其他文字和外部链接预填到发帖面板；已有草稿时可选择追加，不会自动发布。支持 `twitter://status?id=123`、`twitter://user?screen_name=alice` 和对应的 `crux://` 链接。已声明 X 网站的 HTTPS 候选打开方式，是否显示选择器取决于来源应用和系统，不属于已验证的 App Linking。暂不接收外部图片分享。
- **加载与刷新**：首次加载显示居中进度指示，之后顶部有 2vp 线性进度条；下拉刷新由 HarmonyOS 的 `Refresh` 容器直接驱动 WebView；主框架加载失败时显示"无法加载 X"错误页，提供重试与网络设置入口。
- **外观设置**：可切换悬浮导航栏、滚动时自动收起导航栏和桌面版网站，并可查看原始网页。原生界面的深浅色跟随网页实际背景。

## 技术架构与实现要点

- **单一 WebView + 原生外壳**：`pages/MainTabs.ets` 是唯一页面，`HdsNavigation` + `HdsTabs`（`@kit.UIDesignKit`）承载外壳，ArkWeb 的 `Web` 组件以 `RenderMode.ASYNC_RENDER` 常驻在一个 `TabContent` 内。
- **网页与原生桥**：通过 `javaScriptProxy` 向页面注入 `window.otNative`，提供 `onUrlChange`（SPA 路由变化）、`onImages`（图片点击）和 `onTheme`（页面背景）通道。x.com 是单页应用，页面内跳转不触发 `onPageEnd`，因此路由同步依赖注入的 history 钩子。
- **剥离网页自带外壳**：`common/WebChrome.ets` 以字符串形式保存注入的 CSS/JS，隐藏 x.com 自己的顶栏、底部导航、Home 时间线 tab 行和浮动发帖按钮，并把网页字体统一为 HarmonyOS Sans；同时按真实视口换算顶部/底部留白（CSS 变量 `--ot-top-inset` / `--ot-bottom-inset`），让网页内容能正确穿过原生栏。
- **路由分类**：`common/WebConfig.ets` 集中定义所有 x.com 端点、移动端与桌面端 User-Agent，以及 `pathOf`、`routeIndexForUrl`、`isTabRootPath`、`isPostDetailUrl`、`usesNativeNavigation`、`usesNativeHeader` 等判定——只有受支持的业务页面才套原生导航，登录页和未知路由保留原始网页。
- **设计令牌**：`common/Theme.ets` 只放尺寸与字体族，颜色一律走系统资源 `sys.color.ohos_id_color_*`，因此浅色/深色、高对比度由系统适配。关键令牌：触控目标 48vp、底部栏 56vp、悬浮栏 58vp、侧边导航栏 88vp、圆角 16vp、宽屏断点 840vp。
- **网页滚动驱动原生顶栏**：ArkWeb 的滚动由渲染进程持有，外壳把滚动偏移镜像到一个 1vp 隐藏滚动容器，再交给 `HdsNavigation` 的 titleBar 做 32vp 距离内的渐变模糊过渡。
- **本地状态**：`@kit.ArkData` 的 preferences 存两类数据——`opentwit_web`（账号 handle、头像地址、外观开关、按账号的发帖草稿、通知询问标记）和 `opentwit_network`（DoH 配置，含 schema 版本）。
- **会话与调试**：应用切到后台时保存登录会话和草稿，暂停角标轮询及外壳的网页观察器；回到前台恢复。ArkWeb 调试通道仅在调试构建中开启。
- **常用系统能力**：`@kit.NotificationKit`（桌面角标）、`@kit.SensorServiceKit`（切换标签的轻触感反馈，无马达设备自动跳过）、`@kit.ShareKit`、`@kit.MediaLibraryKit`、`@kit.CoreFileKit`、`@kit.NetworkKit`。

## 目录结构

```text
AppScope/                              应用级配置与分层图标
  app.json5                            包名、版本、最低 API
entry/src/main/
  module.json5                         模块、设备类型、Ability、权限声明
  ets/entryability/EntryAbility.ets    启动、ArkWeb 初始化、桌面窗口默认尺寸
  ets/pages/
    MainTabs.ets                       主界面：外壳、WebView、顶栏、标签栏、发帖
    NativeTopBar.ets                   页面标题与返回入口
    NativeBottomBar.ets                底部或侧边标签栏
    ComposerPanel.ets                  原生文字编辑面板
    NativeImageViewer.ets              全屏图片查看器与缩放组件
    NetworkSettingsSheet.ets           网络与安全设置面板
  ets/common/
    WebConfig.ets                      x.com 端点、UA、URL 分类
    WebChrome.ets                      注入的 CSS 与脚本
    WebSystem.ets                      外链、文件选择、分享、下载
    WebMedia.ets                       图片地址解析与点击拦截脚本
    MediaFiles.ets                     原图下载、格式嗅探与缓存
    WebImageDownloads.ets              头像与原图的 ArkWeb 下载、取消及临时文件管理
    NetworkConfig.ets                  DoH 配置、应用与持久化
    DohProbe.ets                       DoH 节点测速
    Theme.ets                          尺寸与字体令牌
  resources/                           base / zh_CN / ar / dark
scripts/                               签名、图标生成、构建联调与静态检查脚本
build-profile.json5                    产品、SDK 版本与模块
oh-package.json5 / entry/oh-package.json5
hvigorfile.ts / entry/hvigorfile.ts / hvigor/hvigor-config.json5
```

## 构建与运行

**环境**：HarmonyOS SDK 6.1.1（API 24）作为兼容与目标版本，编译 SDK 为 26.0.0，hvigor 模型版本 26.0.0。工程没有第三方依赖，`oh-package.json5` 的 `dependencies` 为空。

**DevEco Studio**：直接打开工程根目录，选择 `default` 产品与 `debug` 构建模式，运行 `entry` 模块即可。

**命令行（hvigorw）**：

```bash
ohpm install
hvigorw --no-daemon assembleHap --mode module -p product=default -p buildMode=debug
```

正式构建将 `buildMode=debug` 改为 `buildMode=release`；两种模式均保留 API 24 兼容目标。

产物位于 `entry/build/default/outputs/default/entry-default-unsigned.hap`；安装用 `hdc install <hap>`。仓库未提交 `hvigorw` 包装脚本，需要使用 DevEco Studio 自带的 command-line-tools 里的 `hvigorw`。

**签名**：`build-profile.json5` 的 `signingConfigs` 为空，默认产出未签名 HAP。`scripts/sign-hap.sh` 用 SDK `toolchains/lib` 内的 OpenHarmony 测试签名材料（`OpenHarmony.p12`、`hap-sign-tool.jar` 与 profile 模板）完成签名，输出文件名自动跟随 `AppScope/app.json5` 的 versionName，默认写到 `dist/CruX-Web-<versionName>-signed.hap`。可用环境变量覆盖 SDK 路径（`OH_SDK_LIB`）、`JAVA_BIN`、`KEYTOOL_BIN` 以及输入输出路径。这套测试身份只被信任 OpenHarmony 测试根的模拟器/开发设备接受，正式发布需替换为 AGC 签发的证书。

**图标**：`scripts/make-icons.py` 从 `scripts/icon-src/` 的源图重新生成分层图标（`background.png`、`foreground.png`）与 216/512 尺寸的应用图标，需要 Python 3 与 Pillow。

**行为检查**：`scripts/check-*.mjs` 使用 Node 24 和 `node:vm` 执行生产逻辑，覆盖媒体分类与下载、失败重试、草稿移交与恢复、启动异常、导航竞态、角标及网络策略；平台调用由测试替身提供。可逐个执行，例如 `node scripts/check-reliability.mjs`。PR 检查会执行全部脚本；这些检查不能替代设备上的 ArkWeb 回调、登录、相册授权和网络抓包验证。

**其他脚本**：`scripts/` 下还有 JDK/环境变量配置、模拟器启动与 HAP 安装、Previewer 运行、系统镜像导入、设备点击抓屏等辅助脚本，均按 macOS + Huawei command-line-tools 的路径习惯编写（默认 `$HOME/Developer/command-line-tools`），在其他平台上需要自行调整路径。

## 网络与 DoH 设置

应用内置独立的网络与安全面板，入口有三处：首屏加载或加载失败时底部的"设置"胶囊、首页头像菜单中的"网络与安全"，以及错误页上的"网络设置"按钮。

- **三种模式**：关闭时使用系统 DNS；自动模式（默认）优先 DoH、失败回退系统 DNS；强制模式要求 DoH，配置应用失败时停止挂载网页，并保留重试与网络设置入口。VPN 自动旁路和图片下载同步分别按对应开关生效。
- **内置节点**：Cloudflare（`https://cloudflare-dns.com/dns-query`，引导 IP 1.1.1.1）、Google Public DNS（8.8.8.8）、AliDNS（223.5.5.5）、DNSPod（1.12.12.12），默认选中 Cloudflare。
- **自定义节点**：最多 8 个，要求 HTTPS 且带路径，可选填 IPv4/IPv6 引导 IP；名称、URL 长度和重复地址都会校验。
- **如何生效**：通过 ArkWeb 的 `WebviewController.setHttpDns` 设置加密 DNS 模式，并用 `setHostIP` / `clearHostIP` 为节点主机名钉住引导 IP（有效期 3600 秒）。必须在 `initializeWebEngine()` 之后、`loadContent` 之前应用，因此 `EntryAbility` 在 `onCreate` 里初始化引擎和网络配置，在 `onWindowStageCreate` 里再补一次 `ensureApplied()`。
- **节点测速**：`DohProbe` 直接构造 DNS A 记录的 wire 格式查询（base64url、`Accept: application/dns-message`）并解析 rcode，结果分为可用（显示毫秒延迟）、不可达、响应无效、解析失败。
- **VPN 感知**：监听网络变化（400ms 防抖），检测到 `BEARER_VPN` 时暂停 DoH，避免与 fake-IP 方案冲突；该自动旁路可在面板中关闭。
- **头像与图片下载**：“同步加速原图下载”开启时，头像和原生查看器共享网页的 ArkWeb 下载通道；原生图片组件只接收下载完成的本地文件，不自行加载远程预览。图片保存在应用缓存中，不弹出文件保存窗口。关闭同步后使用独立 HTTP 下载策略。同步下载失败时不会切换到独立 HTTP；系统 DNS 回退按网页的 DoH 模式配置。
- 配置写在 preferences 的 `opentwit_network`；改动后当前页面会自动重载，让新设置立刻生效。

需要说明的是，DoH 只加密 DNS 查询本身：它不隐藏 TLS SNI、不改变 IP 路由，也不能绕过基于 IP/SNI 的封锁。

## 多语言与多设备适配

- **多语言**：资源分 `base`（英文）、`zh_CN`（简体中文）、`ar`（阿拉伯语）三套，键集保持一致，界面文案跟随系统语言。可带参数，例如节点测速结果是 `%d ms`；未读计数解析还会把阿拉伯-印度数字归一化为拉丁数字，避免阿拉伯语界面下角标失效。
- **设备类型**：`default`、`tablet`、`2in1`；窗口支持全屏、分屏与悬浮，最小窗口 360×480vp。
- **宽屏布局**：以 840vp 为断点，底部标签栏切换为 88vp 的侧边导航栏；断点变化只改状态、不重建 WebView。
- **2in1 桌面**：屏幕宽度达到 1000vp 时，首次启动会把窗口调整为桌面尺寸（屏幕的 85% 宽、90% 高，上限 1440×960vp）并居中，只执行一次，之后尺寸交给窗口管理器记忆；2in1 同时改用桌面 User-Agent，其余设备使用带 `CruX-Web/1.0` 标记的移动端 UA。
- **暗色**：启动窗口背景在 `base` 下为白色、`dark` 下为 `#000000`；应用内颜色全部取自系统资源，网页侧使用 `WebDarkMode.Auto` 跟随。

## 权限说明

`entry/src/main/module.json5` 声明了四项权限，每一项都有对应的用途说明字符串：

| 权限 | 用途 |
| --- | --- |
| `ohos.permission.INTERNET` | 加载 x.com 网页及其资源 |
| `ohos.permission.GET_NETWORK_INFO` | 检测系统 VPN 状态，以便在 VPN 连接时暂停 DoH |
| `ohos.permission.VIBRATE` | 切换标签页时的轻触感反馈 |
| `ohos.permission.LOCATION` | 网页为发布带位置的帖子请求定位时使用；仅在用户于原生确认框中允许后，才向系统申请运行时权限（`usedScene` 为 `EntryAbility`，`inuse`） |

通知权限不在清单中静态声明，而是在第一次需要显示桌面角标时通过 `requestEnableNotification` 询问一次；拒绝后不再打扰，标签栏角标不受影响。

## 版本信息

- 应用版本：`1.1.0`（versionCode `2`），包名 `com.crux.web`
- `minAPIVersion`：24；`compatibleSdkVersion` / `targetSdkVersion`：`6.1.1(24)`；`compileSdkVersion`：`26.0.0`
- hvigor / oh-package `modelVersion`：`26.0.0`
- 模块：单个 `entry` 模块，入口 Ability 为 `EntryAbility`，页面入口为 `pages/MainTabs`
- 运行环境：HarmonyOS（`runtimeOS: HarmonyOS`），Stage 模型

## 许可协议

本项目采用 Apache License 2.0，完整条款见仓库根目录的 `LICENSE` 文件。

CruX 是第三方客户端，与 X Corp. 无隶属关系；应用内展示的内容、账号与数据均来自 x.com 网页服务，相关权利归其各自所有者。
