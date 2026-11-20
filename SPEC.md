# NeoWarp HarmonyOS 7 (API 26) 完整移植适配技术规格

> **修订 v2（界面一致性要求）**：主窗口不再包含任何原生外围 UI（标题栏 / 侧栏 / 任务面板 / 骨架屏 / 原生快捷键层），界面 100% 由离线 Web 站点渲染，与 Windows 版逐字节一致；桌面版 `src-main/windows/*` 的每个独立 `BrowserWindow` 一律改由 `windowStage.createSubWindow()` 的 **OS 级真实子窗口**承载（系统标题栏、可拖动、可缩放、任务栏可见），彻底移除网页版 iframe 浮层与 Dock。各子窗口是独立 ArkWeb，跨窗口 RPC 由 `WindowBus` 在原生层镜像 BroadcastChannel，保证与桌面主进程 IPC 等价。


> 版本：v1.0 · 2026-11-14 · 目标产物：`NeoWarp-0.0.1-harmony.hap`
> 源工程：`/workspace/NeoWarp` @ `ca37a40`（NeoWarp 2.3.0，GPL-3.0，TurboWarp Desktop 衍生）

---

## 1. 目标与约束

| 项 | 要求 |
|---|---|
| 目标平台 | HarmonyOS 7，API 26，Stage 模型，ArkTS |
| 目标设备 | 鸿蒙 PC（含桌面模式/键鼠）、平板、三折叠、阔折叠 |
| 功能范围 | **完整移植桌面版全部功能**，不允许功能裁剪 |
| 运行形态 | **完全离线**：安装后零网络依赖，零联网权限 |
| 开发语言 | ArkTS 为主（原生层），Web 运行时沿用仓库既有 JS 资产（ArkWeb 内执行） |
| 性能 | 针对鸿蒙设备做启动、渲染、内存、折叠态切换、多窗口的专项优化 |
| 交付物 | `.hap` 应用包 + 完整可编译工程源码 |

**不可协商的硬约束**：`module.json5` 中不声明 `ohos.permission.INTERNET`。这不是"默认离线"，而是**由系统权限层强制保证的离线**——即使 Web 运行时内部残留 `fetch` 调用也无法出网，离线属性可被审计验证。

---

## 2. 源系统深度分析（结论 + 证据）

### 2.1 架构

Electron 41 + webpack 4 的多进程应用，三块组成：

- **主进程** `src-main/`（59 文件）：`entrypoint.js` → `index.js` 管生命周期、单实例、session 权限、文件关联；`windows/abstract.js` 是窗口基类，`this.ipc = webContents.mainFrame.ipc`（`abstract.js:46`）逐窗口注册 IPC，而非全局 `ipcMain.handle`。30+ 窗口子类位于 `src-main/windows/`。
- **preload** `src-preload/`（25 文件）：每个文件 `contextBridge.exposeInMainWorld('<Name>Preload', …)`，共 20+ 个全局对象（`EditorPreload`、`TaskManagerPreload`、`AIAssistantPreload`、`CollaborationPreload` …）。方法分 `invoke` / `sendSync` / `send+on` 事件三型。
- **renderer**：两套。① 主 GUI 是 `src-renderer-webpack/editor/`（React + `scratch-gui`，`webpack.config.cjs:66` 入口 → `dist-renderer-webpack/editor/gui/index.js`）；② 20+ 辅助窗口是 `src-renderer/<name>/*.html` 自包含页面（内联 HTML/CSS/JS），经 `tw-*` 自定义协议加载（`src-main/protocols.js`）。
- **离线资产**：`dist-library-files/*.br`、`dist-extensions/*.br`（Brotli，素材库/扩展画廊，`protocols.js:70-85`）、本地 Monaco `src-renderer/extension-editor/vs/`、字体 `font/HarmonyOS_Sans_SC_*.ttf`。

### 2.2 已有的 Web 移植层（决定性发现）

仓库自带 `web/`（29 文件），是**桌面版到浏览器的全量改造层**，不改动桌面源码：

- `web/build.mjs`（607 行）把 webpack GUI 产物 + `src-renderer/*` 页面组装成静态站点 `dist-web/`，注入 `assets/nw-core.js` 与 `assets/shims/*.js`。
- `web/src/core/10-rpc.js`：同源 `postMessage` + `BroadcastChannel` 双通道 RPC，协议 `{__nw:1, t:'req', id, ns, m, a}` / `t:'res'` / `t:'evt'`。
- `web/src/core/30-host.js`：`NW.host.register(ns, impl)` 服务总线，把 Electron 主进程职责等价实现为浏览器服务（`30-host.js:194-225` 已注册 `desktop` 命名空间）。
- `web/src/shims/*.js`：把 `window.XxxPreload` 的 API 逐个映射到 `NW.rpc.call(ns, method, args)`。
- `web/src/core/40-window-manager.js`：页内浮层窗口管理器，替代 BrowserWindow；`36-app-windows.js` 是窗口路由表。
- `web/src/pwa/`：Service Worker / manifest（部署到静态站点用）。
- `web/README.md:83-89` 明确列出「Electron 主进程 IPC → NW.host / NW.rpc」的等价替换表。

**结论**：桌面版 20+ 窗口、Addon 系统、编译器、Packager、AI 助手、协作、SOLO、task-manager、扩展编辑器等**全部功能已存在 Web 等价实现**。鸿蒙移植的正确路径不是用 ArkUI 重写 GUI（那将重写 scratch-gui 数十万行并必然丢功能），而是：
**ArkTS Stage 原生壳 + ArkWeb 承载 `dist-web/` 离线站点 + ArkTS 原生能力注册为 `NW.host` 服务**。
这样 shims 层零改动即可复用，`完整移植全部功能` 在工程上成立。

### 2.3 在线依赖清单（离线化必须逐一处理）

| 在线点 | 位置 | 处置 |
|---|---|---|
| 更新检查 | `src-main/update-checker.js:10`、`windows/update.js:38` | 鸿蒙侧由应用市场分发，移除/禁用更新窗口的联网分支 |
| Scratch 官方 API / 项目 | `windows/editor.js:188,192` | 离线模式回落到本地项目；素材由 `tw-library` 本地应答 |
| 素材 CDN | `windows/project-running-window.js:109-144` | 已重定向 `tw-library` → 内置 `*.br` |
| 扩展画廊 | `desktop-hoc.jsx:4962-5107` | 已内置 `dist-extensions/*.br` |
| 云变量 | `gui.jsx:28` → `wss://fake-clouddata-server.turbowarp.org` | 假服务器，改为应用内 `BroadcastChannel` 同步（Web 层已实现） |
| AI 代理 / 搜索 | `protocols.js:209,706`、`ai-model-configs.js:46`、`ai-assistant.js:252-318` | 离线版禁用在线推理与 Web 搜索，保留本地 DSL / 提示词 / 项目分析能力 |
| 协作 / 手机远控 | `collaboration-server.js`、`phone-sync.js`、`mobile-preview-server.js` | 桌面版靠局域网 HTTP/WS；Web 层已改为 MQTT 信令 + WebRTC。离线强约束下改为**鸿蒙分布式软总线 / 近场发现**（见 §7.6），无公网 |
| CDN 字体 / 脚本 | `protocols.js:106,114`、`web/build.mjs:46-49` | 默认已全本地（`font/`、`vs/`），禁止 `--monaco-cdn` |
| 构建期下载 | `npm run fetch` | 构建机执行，产物内置，运行时不联网 |

### 2.4 移植障碍点（原生层重写范围）

必须 ArkTS 化的部分，恰好是 `NW.host` 服务总线可以承接的部分：

| Electron / Node 能力 | 使用位置 | ArkTS 替代 |
|---|---|---|
| `fs` 读写项目 / 原子写 | `windows/editor.js:747-819`、`atomic-write-stream.js` | `@ohos.file.fs` + `filePicker` + 应用沙箱 |
| `os.cpus/totalmem/freemem` | `windows/task-manager.js:69-91` | `@ohos.resourceschedule` / `hidebug` + `systemParameter` |
| `crypto` 加密项目 | `windows/editor.js:5` | `@ohos.security.cryptoFramework` |
| `zlib` brotli 解压资产 | `protocols.js` | ArkTS 侧预解压 + `onInterceptRequest` 直接应答 |
| `BrowserWindow` ×30 | `windows/*` | **OS 级真实子窗口**（`createSubWindow` + 系统装饰），窗口内仍是同一份离线页面 |
| `protocol.handle` / CSP | `protocols.js:211-243,694-709` | ArkWeb `onInterceptRequest` + `WebOptions` CSP |
| `nativeTheme` / 深浅色 | `effective-theme.js` | `@ohos.window` + `AppStorage` + 资源限定词 `dark` |
| `Menu` / `before-input-event` 快捷键 | `menu-bar.js`、`abstract.js:232-301` | 由 Web 页面自身处理键盘事件；不新增原生菜单/快捷键层 |
| `Notification` / `clipboard` / `shell` | 多处 | `@ohos.notificationManager` / `pasteboard` / `Want` |
| `child_process.execFile` | `file-associations.js:56` | 移除（Windows 注册表逻辑） |
| `sharp` / scaffolding（原生模块） | `package.json:53` 等 | 构建期用；运行时以 ArkTS 图像处理/内置站点替代 |

---

## 3. 架构决策

```
┌──────────────────────────────────────────────────────────────┐
│  HarmonyOS 7 / API 26 · Stage 模型 · 单 HAP                    │
│                                                              │
│  ┌──────────────────── ArkTS 原生层 ────────────────────────┐ │
│  │ EntryAbility（生命周期/窗口/折叠监听/性能调度）          │ │
│  │ Index.ets（纯 ArkWeb 全屏容器，无任何 ArkUI 装饰）                 │ │
│  │ HarmonyBridge（javaScriptProxy ⇄ NW.host 服务总线）       │ │
│  │ NativeServices：fs / system / theme / window / media /   │ │
│  │                 crypto / perf / package / distributed    │ │
│  │ PerformanceManager（设备分级·帧率·内存·后台挂起）        │ │
│  │ DeviceProfile（PC/平板/三折叠/阔折叠 形态识别与避让）    │ │
│  └───────────────────────┬──────────────────────────────────┘ │
│                          │ javaScriptProxy / runJavaScript     │
│  ┌───────────────────────▼──────────────────────────────────┐ │
│  │ ArkWeb（离线）· rawfile://neowarp/dist-web                │ │
│  │   nw-core.js → harmony-bridge.js（注册原生 ns 服务）      │ │
│  │   shims/*.js → NW.rpc.call(ns, method, args)              │ │
│  │   20+ 窗口页 / scratch-gui / Monaco / task-manager        │ │
│  │   素材库·扩展·字体·Packager 全部随包内置                  │ │
│  └──────────────────────────────────────────────────────────┘ │
│  resources/rawfile/neowarp/**   零 INTERNET 权限                │
└──────────────────────────────────────────────────────────────┘
```

**为什么不用纯 ArkUI 重写**：scratch-gui / scratch-blocks / scratch-vm / scratch-render 构成数十万行、含 WebGL 渲染与积木编译器的成熟 Web 引擎；ArkUI 无等价组件，重写必然造成功能大面积缺失，与「完整移植全部功能」直接冲突。ArkTS 承担全部原生职责与性能优化，Web 引擎在 ArkWeb 中以 AOT 加速的 JS 运行，是唯一能同时满足「功能完整 + 鸿蒙原生 + 离线 + 性能」的方案。

---

## 4. 功能等价矩阵（桌面 → 鸿蒙）

| 桌面窗口 / 功能 | 鸿蒙实现 | 关键依赖 |
|---|---|---|
| 主编辑器（scratch-gui、编译器、积木、舞台、造型/声音编辑） | ArkWeb `gui/index.html` | WebGL + shims/editor + fs 桥 |
| 主页 Home | ArkWeb `index.html` | recent-projects → ArkTS 存储 |
| 桌面设置、Addon 设置、主题/深色模式 | **OS 级真实子窗口** | `NW.host('desktop')` + ArkTS 主题服务 |
| 扩展编辑器（Monaco） | ArkWeb `extension-editor/` | 本地 `vs/` 全量内置 |
| AI 助手 / SOLO / SOLO Stage | ArkWeb 对应页 | 离线保留本地能力，禁用在线推理 |
| 项目分析 / 图片编辑器 / 迁移 / 待办 / 关于 / 联系 / 隐私 / 安全提示 / 引导 | **OS 级真实子窗口** | 页内窗口管理器 |
| 协作 / 手机预览 / 远程舞台 | ArkWeb 页面 | §7.6 近场通道 |
| Packager（HTML/ZIP/EXE 打包） | ArkWeb standalone.html | 内置 `dist-library-files` |
| **task-manager**（CPU/RAM/角色表/折线图） | ArkWeb 页面 + **ArkTS 系统信息采集** | `NativeServices.system.getStats`，见 §8 |
| 分离舞台 / 全屏 / 多窗口 | **OS 级真实子窗口**（PC 支持多窗口/分屏） | `DeviceProfile` |
| 文件关联 `.sb3/.sb2/.sb/.np1/.npnp/.viewsb3/.js` | `module.json5` `skills`/`uris` + Want 拉起 | ArkTS 文件桥 |
| 素材库 / 扩展画廊 / 字体 | rawfile 内置 + 拦截应答 | `onInterceptRequest` |

---

## 5. 离线化设计

1. **资源内置**：`dist-web/` 全量拷入 `entry/src/main/resources/rawfile/neowarp/`，含 GUI bundle、`*.br` 素材、Monaco `vs/`、字体、vendor、20+ 页面。
2. **加载通道**：ArkWeb 以 `file:///.../rawfile/neowarp/index.html` 或 `resource://rawfile/...` 加载；`onInterceptRequest` 把 `tw-library://`、`tw-extensions://`、`tw-*://` 及素材 md5 请求映射到 rawfile。素材 `*.br` 由 `scripts/prepare_offline.mjs` 在**构建期统一预解压**为普通文件，运行时零解压开销（优于启动期解压），冷资源再按 LRU 缓存。
3. **移除 Service Worker 依赖**：`web/src/pwa/sw.js` 面向 HTTP 站点，在 `file://` 下不可用；改由原生拦截层承担缓存职责，避免 Web 组件 SW 行为差异。
4. **CSP**：通过 ArkWeb `WebOptions` 注入 `default-src 'self' …; connect-src 'self'`，从渲染层二次阻断出网。
5. **权限层**：不申请 INTERNET（§1），系统级兜底。
6. **数据**：项目、设置、最近文件、AI 配置存应用沙箱 + `preferences`，导出/导入走 `filePicker`（无需权限）。

---

## 6. 设备形态适配

### 6.1 断点与形态识别

`DeviceProfile` 综合 `@ohos.display`（`getFoldStatus()`、`getCurrentFoldCreaseRegion()`、屏幕尺寸/DPR）、`@ohos.window`（`getWindowProperties().windowRect`）与资源断点，输出：

| 形态 | 判据 | 布局 |
|---|---|---|
| 平板（竖/横） | md/lg，无折痕 | 侧栏可折叠，舞台优先；横屏双栏 |
| 阔折叠（合） | FOLDED，窄 vp | 单栏 + 底部标签，触控热区 ≥ 48vp |
| 阔折叠（展） | EXPANDED，宽高比接近方形 | 双栏：左积木/右舞台，折痕区避让 |
| 三折叠（单屏态） | 单屏宽度 | 单栏，等同手机布局 |
| 三折叠（双/三屏态） | EXPANDED + 多折痕 / 超宽 vp | 三栏：素材/积木/舞台，折痕区各留 24vp 安全区 |
| 鸿蒙 PC | xl + 键鼠 + 自由窗口 | 系统窗口装饰 + 多个真实子窗口，无自绘菜单栏/面板 |

`display.on('foldStatusChange')` / `window.on('windowSizeChange')` 监听，**切换折叠态不重建 ArkWeb、不丢失编辑状态**，只更新原生性能调度快照，界面由 Web 自行响应式布局，不注入任何原生 UI。

### 6.2 交互适配

- 键鼠：PC 保留 `Ctrl+S/Ctrl+O/Ctrl+Z/Ctrl+Shift+E` 等桌面快捷键（`abstract.js:232-301` 的等价映射）。
- 触控：积木拖拽、舞台缩放、长按右键菜单；所有可点区域 ≥ 48vp。
- 手写笔 / 键盘盖：按系统输入设备能力切换 hover 态与光标。
- 折痕避让：三折叠/阔折叠在折痕区域不放置不可移动的关键控件；画布跨折痕时以 `creaseRegion` 做内容安全边距。

---

## 7. 原生桥协议（ArkTS ⇄ Web）

### 7.1 注入与调用

ArkWeb `javaScriptProxy` 注入对象 `HarmonyNative`，暴露异步方法：

```
invoke(ns: string, method: string, argsJson: string): Promise<string>
```

Web 侧 `harmony-bridge.js`（在 `nw-core.js` 之后、shims 之前加载）把 ArkTS 能力注册进既有服务总线：

```
NW.host.register('native', …)   // 系统/文件/窗口/媒体/性能
NW.host.register('device', …)   // 形态、主题、事件
```

shims 通过 `NW.rpc.call(native.*)` 调用，协议与 `web/src/core/10-rpc.js` 完全一致，**无需修改任一 shim**。反向事件由 ArkTS 调用 `webController.runJavaScript("window.NWHost.emit(...)")` 推送。

### 7.2 服务与方法（最小完备集）

| ns | 方法 | ArkTS 实现 |
|---|---|---|
| `native.fs` | `openProject/saveProject/saveAs/listRecent/deleteRecent/readAsset/writeAsset` | `@ohos.file.fs` + `filePicker` + 原子写（临时文件 + rename） |
| `native.crypto` | `encrypt/decrypt/hash` | `cryptoFramework` |
| `native.system` | `getStats/getMemoryInfo/getCpuInfo` | `hidebug` / `systemParameter` / 进程采样 |
| `native.theme` | `get/set/onChange` | `ApplicationContext` 颜色模式 + `AppStorage` |
| `native.window` | `open/close/focus/setTitle/fullscreen/split` | `@ohos.window` + `SubWindowManager` 真实子窗口 |
| `native.media` | `enumerateDevices/requestPermission` | `camera` / `microphone` 权限按需申请 |
| `native.perf` | `setProfile/getMetrics/notifyVisibility` | `PerformanceManager` |
| `native.package` | `packageHtml/packageZip` | 调用内置 standalone 打包器，产物写沙箱 |
| `native.distributed` | `discover/connect/send` | 近场设备发现（§7.6） |

### 7.3 约束

- **热路径零反射**：ArkTS 侧用显式 `switch (ns + '.' + method)` 分派到静态类型方法，不用动态 `any` 映射、不用字符串求值（与 OxiWarp 的编译期保证风格一致）。
- 所有跨边界数据 JSON 序列化，`ArrayBuffer`/二进制走 Base64 或 `ArrayBuffer` 通道，单次 ≤ 2 MB，超限分片。
- 桥调用做来源校验：仅允许 rawfile 来源页面。
- 错误统一为 `{ok:false, code, message}`，不抛异常穿透到 Web 层。

### 7.4 权限

| 权限 | 用途 | 是否申请 |
|---|---|---|
| `ohos.permission.INTERNET` | — | **不申请**（离线硬保证） |
| `ohos.permission.CAMERA` / `MICROPHONE` | 视频侦测 / 响度 / 录音积木 | 按需、运行时申请 |
| ~~`ohos.permission.NOTIFICATION`~~ | 任务完成通知 | API 26 无此预定义权限，已移除；改由 ArkUI 应用内浮层提示，系统通知需正式证书下的 `notificationManager` 能力 |
| `ohos.permission.DISTRIBUTED_DATASYNC` | 近场协作 | 按需（仅同帐号设备） |
| 文件读写 | 沙箱 + filePicker | 无需权限 |

---

## 8. 性能优化（鸿蒙专项）

| 层面 | 措施 | 目标 |
|---|---|---|
| 冷启动 | `EntryAbility.onCreate` 预初始化 Web 引擎；`warmup()` 启动时一次构建 rawfile 索引并预热热文件；`.br` 素材构建期已预解压（运行时零解压）；骨架屏占位 | PC ≤ 2.5s / 平板 ≤ 3.5s 首帧 |
| ArkTS | 静态类型 + AOT；热路径显式分派、零 `any`/零反射；`TaskPool` 处理 zip 解压、加密、哈希 | 主线程无阻塞 |
| 渲染 | ArkWeb 硬件加速 + WebGL；按设备档位设 DPR 上限（折叠屏 2.0 / PC 2.5）；折痕展开态避免超宽纹理重分配 | 舞台 60fps(PC) / ≥30fps(移动) |
| 调度 | `PerformanceManager` 依据形态分档（PC 高性能 / 平板均衡 / 折叠合盖省电）；`onBackground` 挂起 VM 循环与轮询；`onForeground` 恢复 | 后台 CPU ≈ 0 |
| task-manager | 采样在 ArkTS 侧 `TaskPool` 完成（不在 Web 层轮询 `os`），1.5s 推送一次；角色统计由 VM 事件总线汇总；折线图 Canvas 按 DPR 与可见性节流重绘 | 采样开销 < 1% CPU |
| 内存 | 大项目分块解析；素材按需解压 + LRU（上限按设备内存档位动态调整）；离屏 Web 浮层及时释放；`onMemoryLevel` 回调主动降缓存 | 峰值受控、无 OOM |
| 折叠切换 | 不重建 Web 组件，界面由 Web 自行重排；切换期间暂停渲染 1 帧后恢复，避免尺寸抖动导致 WebGL 反复重建 | 状态不丢、无闪白 |
| I/O | 项目保存用临时文件 + 原子 rename；写操作合并；素材读取走拦截缓存 | 无写一半损坏 |

---

## 9. 工程结构

```
NeoWarpHarmony/
├── SPEC.md / PLAN.md                 规格与实施计划
├── AppScope/app.json5                应用级配置（bundleName / version / icon）
├── AppScope/resources/               应用图标、名称（zh_CN / en_US / dark）
├── entry/
│   ├── src/main/module.json5          abilities / deviceTypes / skills / 权限
│   ├── src/main/ets/
│   │   ├── entryability/EntryAbility.ets
│   │   ├── pages/Index.ets
│   │   ├── bridge/{HarmonyBridge,NativeServices}.ets
│   │   ├── common/{Constants,DeviceProfile,PerformanceManager}.ets
│   │   └── window/SubWindowManager.ets · common/WindowBus.ets       │
│   ├── src/main/resources/rawfile/neowarp/**   离线 dist-web 全量
│   └── build-profile.json5 / hvigorfile.ts / oh-package.json5
├── build-profile.json5 / hvigorfile.ts / oh-package.json5 / hvigor-config.json5
├── scripts/prepare_offline.mjs       离线站点组装（rawfile）
├── scripts/sign_hap.mjs              SDK 本地 CA 签名 + verify-app
├── scripts/build_hap.mjs             早期归档工具（输出 *-devarchive.hap，勿用于交付）
└── dist/NeoWarp-0.0.1-harmony.hap   目标产物（真实编译 + 签名）
```

`deviceTypes` 覆盖 `["phone","tablet","2in1","tv"?]`——PC 用 `2in1`，三折叠/阔折叠归入 `phone`/`tablet` 并由运行时形态识别细分；**不声明 `tv`/`wearable`**。

---

## 10. 验收标准

| 编号 | 验收项 | 判据 |
|---|---|---|
| A1 | 离线 | 安装包无 INTERNET 权限；运行期抓包 0 出网请求；飞行模式下全部功能可用 |
| A2 | 功能完整 | §4 矩阵所有窗口可打开，主编辑器可新建/打开/保存 `.sb3`、运行/停止、添加扩展、Addon 设置生效 |
| A3 | 打包器 | 离线导出 HTML / ZIP 成功且产物可独立运行 |
| A4 | task-manager | CPU/RAM 曲线与角色表实时刷新，数值与系统一致 |
| A5 | 设备适配 | 6 种形态（PC / 平板横竖 / 阔折叠合展 / 三折叠三态）布局无遮挡、折痕避让生效 |
| A6 | 折叠连续性 | 折叠/展开切换不重启、编辑状态与项目数据不丢失 |
| A7 | 性能 | 冷启动、帧率、内存达 §8 目标；后台 CPU 趋零 |
| A8 | 包体 | HAP 结构合法、`module.json` 可解析、rawfile 资源校验和一致 |

---

## 11. 风险、限制与交付边界

1. **工具链与签名边界（本轮实测）**：已在 Ubuntu 沙箱安装 **HarmonyOS Command Line Tools 26.0.0.821（SDK `apiVersion 26` / `HarmonyOS 26.0.0 Release`）** 与 JDK 21，用真实 `hvigorw 6.26.4` 完成 ArkTS 编译（产出 `ets/modules.abc` 112 KB、`resources.index`、`pack.info`），再用 SDK 自带 `hap-sign-tool.jar` 完成本地 release 签名，`verify-app` 返回 `Digest verify result: true` / `Verify success`。交付的 `.hap` **是完整编译 + 签名产物，不再是开发态归档**。
   - **剩余边界**：证书链来自 SDK 内置 OpenHarmony 本地 CA，仅用于开发验证；HarmonyOS 真机分发必须替换为华为开发者正式证书与 profile（含设备 UDID / 上架渠道）。沙箱无华为账号与真机，故未跑 §10 的 A1–A8 实机验收，也未伪造该项结果。
   - 复现命令见 `PLAN.md` 与 `scripts/sign_hap.mjs`；工程配置已按 API 26 真实 schema 校准（SDK 版本字符串 `26.0.0`、`arkTSVersion 1.1`、`modelVersion 6.0.0`、hvigor `6.26.4`）。
2. **ArkWeb 能力差异**：`File System Access API` 在 Web 组件中支持有限，已通过 `native.fs` 桥替代；需实机验证 `BroadcastChannel`、`WebRTC`（离线版已换近场通道）、`OffscreenCanvas`。
3. **Service Worker**：`file://` 下不可用，改由原生拦截层承担（§5.3）。
4. **在线功能**：AI 在线推理、Web 搜索、GitHub 更新检查、公网 MQTT 信令在离线硬约束下不可用，改保留本地等价能力（§2.3）。这是"离线版本"的语义边界，不是功能缺失。
5. **GPL-3.0 合规**：衍生作品分发须继续 GPLv3、保留 `LICENSE` 与版权声明、提供对应源码（含本工程 ArkTS 与随包 Web 资产）；逐项核对 `scratch-gui`、`@turbowarp/extensions`、`monaco-editor` 等上游许可。
6. **签名与分发**：本地 release 签名已完成并通过 `verify-app`（§11.1）。上架前需用华为开发者正式证书重签：替换 `scripts/sign_hap.mjs` 中的 `STORE` / `DIST_CERT` / profile 材料即可，流程不变。
7. **素材库下载（本轮实测缺口）**：`dist-library-files` 共 1304 个 Scratch 官方素材需从 `assets.scratch.mit.edu` 下载，当前构建沙箱到该域连接超时（0/1304）。本轮 HAP 已内置完整 GUI bundle、19 个注入页面、Monaco、字体与 **292 个扩展画廊资源**，但素材库为空。在可访问该 CDN 的构建机执行 `node scripts/download-library-files.mjs`（增量 + MD5/SHA256 校验）后重跑 `prepare_offline.mjs` 即可补齐；`offline-manifest.json` 的 `libraryAssets` 字段用于审计此项。运行时素材请求由 `onInterceptRequest` 映射到 `library/`，缺失素材返回空响应而不出网。
8. **构建期适配（已在构建机完成）**：`scratch-gui` 的两个构建期生成物（`microbit-hex-url.js` 占位、`loader/logo.png` 由根目录恢复）、`@turbowarp/extensions` 在 Node 22.13 缺 `zstdCompressSync` 时退回未压缩内联，均已处理；这些改动只作用于 `node_modules`，不进入交付工程源码。

---

## 12. 备选方案评估（已否决）

| 方案 | 结论 |
|---|---|
| 纯 ArkUI 重写全部 GUI | 否决：scratch-gui/blocks/vm/render 数十万行、WebGL 引擎无法等价重写，必然丢失功能，违反 A2 |
| 直接移植 Electron 主进程到 ArkTS + 保留全部 Web 页面但不用 Web 运行时 | 否决：重复造 `web/` 已完成的 RPC/窗口/存储层，工作量翻倍且无收益 |
| 用 `web/dist-web` + Android 兼容层 | 否决：HarmonyOS NEXT 无 Android 运行时，API 26 不兼容 APK |
| **ArkTS 壳 + ArkWeb + NW.host 服务桥** | **采纳**：功能完整、原生可控、离线可审计、性能可优化 |
