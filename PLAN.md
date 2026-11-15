# NeoWarp HarmonyOS 7 移植实施计划

> 配套文档：`SPEC.md` · 源工程 `/workspace/NeoWarp` · 工程根 `/workspace/NeoWarpHarmony`
> 目标产物：`dist/NeoWarp-2.3.0-harmony.hap`

---

## 0. 执行原则

1. **spec → plan → 立即开工**，不等待二次确认。
2. 优先复用仓库既有 `web/` 运行时，禁止重写 GUI；ArkTS 只写原生层与性能层。
3. 每个阶段有可验证产物；编译产物（`modules.abc` / `resources.index` / 签名块）必须由真实 HarmonyOS 工具链生成，不得伪造。本轮已达成。
4. 离线属性由「零 INTERNET 权限 + rawfile 内置 + 请求拦截」三重保证，可审计。

---

## 1. 阶段总览

| 阶段 | 名称 | 主要产物 | 状态 |
|---|---|---|---|
| P0 | 源工程深度分析 | 架构/IPC/在线点/障碍点清单 | ✅ 已完成 |
| P1 | 技术规格 | `SPEC.md` | ✅ 已完成 |
| P2 | 工程骨架 | AppScope / entry / 构建配置 / 资源限定词 | ⏳ 本轮立即执行 |
| P3 | 原生桥与运行时 | `HarmonyBridge.ets`、`NativeServices.ets`、`harmony-bridge.js` | ⏳ 本轮立即执行 |
| P4 | ArkUI 壳与多设备适配 | `Index.ets`、`DeviceProfile.ets`、`FoldSafeLayout.ets` 等 | ⏳ 本轮立即执行 |
| P5 | 离线资源与性能 | rawfile 站点、`PerformanceManager.ets`、拦截层 | ⏳ 本轮立即执行 |
| P6 | HAP 构建与验证 | `scripts/build_hap.mjs` + `dist/*.hap` + 校验报告 | ⏳ 本轮立即执行 |
| P7 | SDK 编译 / 签名 / 真机 | `hvigorw assembleHap` + `scripts/sign_hap.mjs` + `dist/*.hap` | ✅ 编译与本地签名已完成；真机验收需华为正式证书 |

---

## 2. 阶段详述

### P2 · 工程骨架（本轮）

| 任务 | 文件 |
|---|---|
| 应用级配置：bundleName `org.neowarp.harmony`、version 2.3.0、图标、名称 | `AppScope/app.json5`、`AppScope/resources/base/element/string.json`、`base/media/app_icon.png` |
| 模块配置：EntryAbility、`deviceTypes`、文件关联 skills、`requestPermissions`（**无 INTERNET**）、`extensionAbilities` | `entry/src/main/module.json5` |
| 工程构建配置（compatibleSdkVersion 26 / runtimeOS HarmonyOS / arkTS） | `build-profile.json5`、`entry/build-profile.json5`、`hvigor-config.json5` |
| 构建脚本与依赖声明 | `hvigorfile.ts`、`entry/hvigorfile.ts`、`oh-package.json5`、`entry/oh-package.json5` |
| 资源限定词：中英文、深浅色、平板/PC 尺寸 | `entry/src/main/resources/{base,en_US,zh_CN,dark}/…` |

**验收**：配置文件 JSON5 语法可解析；`module.json5` 中 `requestPermissions` 不含 INTERNET；`deviceTypes` 覆盖 2in1/tablet/phone。

### P3 · 原生桥与运行时（本轮）

| 任务 | 文件 |
|---|---|
| ArkWeb `javaScriptProxy` 注入 `HarmonyNative.invoke(ns, method, argsJson)`；反向 `runJavaScript` 事件推送 | `entry/src/main/ets/bridge/HarmonyBridge.ets` |
| 显式静态分派（热路径零反射）；fs / crypto / system / theme / window / media / perf / package / distributed 九类服务 | `entry/src/main/ets/bridge/NativeServices.ets` |
| 项目原子写、素材读取、最近项目、设置持久化 | 同上 + `@ohos.file.fs` / `preferences` |
| Web 侧注入层：把 ArkTS 能力注册进 `NW.host`，协议对齐 `web/src/core/10-rpc.js`；**不改任何 shim** | `entry/src/main/resources/rawfile/neowarp/assets/harmony-bridge.js` |
| 离线请求拦截：`tw-*://` / 素材 md5 → rawfile，Brotli 解压 + LRU | `HarmonyBridge.ets` 的 `onInterceptRequest` 实现 |

**验收**：`harmony-bridge.js` 覆盖 §7.2 全部 ns；桥错误统一 `{ok:false,code,message}`；二进制分片 ≤ 2MB。

### P4 · ArkUI 壳与多设备适配（本轮）

| 任务 | 文件 |
|---|---|
| 主页面：ArkWeb 容器 + 标题栏 + 侧栏 + 浮层窗口路由 | `entry/src/main/ets/pages/Index.ets` |
| 形态识别：foldStatus / creaseRegion / 窗口尺寸 / DPR → 6 种形态 | `entry/src/main/ets/common/DeviceProfile.ets` |
| 折痕避让与响应式断点布局 | `entry/src/main/ets/components/FoldSafeLayout.ets`、`SidePanel.ets`、`TitleBar.ets` |
| PC 快捷键、菜单、分屏/自由窗口 | `Index.ets` + `EntryAbility.ets` |
| task-manager 原生采样面板（用户重点模块，Apple Design 风格简洁一致） | `entry/src/main/ets/components/TaskManagerPanel.ets` |
| 生命周期：折叠监听、前后台、内存水位、窗口尺寸变化 | `entry/src/main/ets/entryability/EntryAbility.ets` |

**验收**：折叠切换不重建 ArkWeb；状态保持；6 形态布局无遮挡；快捷键映射表覆盖桌面版 `abstract.js:232-301` 主要项。

### P5 · 离线资源与性能（本轮）

| 任务 | 文件 |
|---|---|
| 构建 `dist-web/`：webpack GUI 产物 + `node web/build.mjs` 组装（若依赖安装失败则降级为仓库内可离线资产子集，并在交付说明标注） | `scripts/prepare_offline.mjs` |
| rawfile 全量内置、资源清单与校验和 | `scripts/prepare_offline.mjs` 生成 `rawfile/neowarp/asset-manifest.json` |
| 移除 Service Worker 依赖、CSP 注入、Material/字体全本地 | `HarmonyBridge.ets` + `harmony-bridge.js` |
| 设备性能分档、后台挂起、采样节流、内存水位响应 | `entry/src/main/ets/common/PerformanceManager.ets` |
| 常量与类型定义（无 any、无反射） | `entry/src/main/ets/common/Constants.ets` |

**验收**：rawfile 站点可在本地 HTTP 服务下打开；零外链；资源校验和一致。

### P6 · HAP 构建与验证（本轮）

| 任务 | 文件 |
|---|---|
| HAP 归档构建：ZIP 打包 `module.json` / `pack.info` / `resources/` / rawfile / 资源索引占位（**不伪造 `.abc`**） | `scripts/build_hap.mjs` |
| 结构校验：必需条目、JSON 可解析、权限检查、资源校验和、体积统计 | 同上 `--verify` |
| 产物 | `dist/NeoWarp-2.3.0-harmony.hap` |
| 验证反馈：结构清单 + 可视化截图 | 本轮输出 |

**验收**：`.hap` 可被 `unzip -t` 通过；`module.json` 中无 INTERNET；`asset-manifest` 校验和全部匹配。

### P7 · SDK 编译、签名（已完成）与真机验收（待证书）

本轮已安装 HarmonyOS Command Line Tools 26.0.0.821（API 26）并跑通完整工具链：

```bash
export JAVA_HOME=/root/.sdkman/candidates/java/current          # JDK 21
export PATH=/opt/harmony/command-line-tools/bin:$JAVA_HOME/bin:$PATH
cd /workspace/NeoWarpHarmony

# 1) 真实编译：ArkTS → modules.abc / resources.index / pack.info
hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon
#   产物：entry/build/default/outputs/default/entry-default-unsigned.hap

# 2) 本地 release 签名 + verify-app
node scripts/sign_hap.mjs
#   产物：dist/NeoWarp-2.3.0-harmony.hap（119.52 MB，签名块已验证）
```

**已完成**：① `ets/modules.abc`（112 KB，真实 ArkTS 编译）；② `resources.index`（资源编译器生成）；③ `pack.info` / `pkgSdkInfo.json`；④ `hap-sign-tool sign-app` + `verify-app` 通过；⑤ 20 个 ArkTS 编译错误全部按 API 26 声明修正（详见 `entry/src/main/ets`）。

**剩余清单（需华为账号与真机）**：① 用华为开发者正式证书与 profile 重签；② 设备 UDID 绑定；③ 真机跑 §10 的 A1–A8 验收（尤其 WebGL、折叠态重排、快捷键）；④ 应用市场上架。

---

## 3. 关键路径与依赖

```
P0 分析 ──> P1 spec ──> P2 骨架 ──┬──> P3 桥 ──────┐
                                  ├──> P4 UI/适配 ─┼──> P5 资源/性能 ──> P6 HAP ──> P7 SDK
                                  └──> 离线资源构建（并行，npm ci + webpack）
```

- 离线资源构建（npm ci → webpack:prod → web/build.mjs）与 P2–P4 **并行**进行，不阻塞 ArkTS 编写。
- P6 只依赖 P2/P3/P4/P5 的文件落盘，不依赖 SDK。

---

## 4. 本轮交付清单

```
/workspace/NeoWarpHarmony/
├── SPEC.md                                  技术规格（深度分析结论）
├── PLAN.md                                  本计划
├── AppScope/…                               应用级配置与资源
├── entry/src/main/ets/…                     ArkTS 源码（壳/桥/适配/性能）
├── entry/src/main/resources/…               资源限定词 + rawfile 离线站点
├── entry/src/main/module.json5              模块配置（零 INTERNET）
├── build-profile.json5 / hvigorfile.ts / oh-package.json5
├── scripts/{prepare_offline,build_hap}.mjs 构建与校验脚本
└── dist/NeoWarp-2.3.0-harmony.hap          目标产物（开发态归档）
```

---

## 5. 风险与回退

| 风险 | 触发条件 | 回退 |
|---|---|---|
| npm ci 依赖 GitHub 源超时 | 源站慢 | 已配置 `ghfast.top` 加速；失败则降级打包仓库内已有离线资产子集并明确标注 |
| ArkWeb 不支持某 Web API | 真机验证 | 在 `harmony-bridge.js` 增加 polyfill 或改走 `native.*` 服务 |
| 折叠态重建 Web 组件 | 窗口尺寸变化 | 布局重排而非组件重建；状态存 `AppStorage` / Web 层内存 |
| HAP 无 `.abc` 不可安装 | 沙箱无 SDK | 明示为开发态归档；P7 在 DevEco 补齐后即可安装 |
| 素材 CDN 不可达 | `assets.scratch.mit.edu` 连接超时 | 本轮 `libraryAssets=0`；在可联网构建机跑 `download-library-files.mjs` 后重跑 `prepare_offline.mjs` 补齐（1304 个，增量+校验） |
| Node 22.13 缺 zstd | 扩展构建报错 | 已在 `dependency-management.js` 加退回未压缩分支，292 个扩展资源已生成并解压 |
| GPLv3 合规遗漏 | 分发时 | 随包保留 `LICENSE`、上游声明与完整源码 |

---

## 6. 里程碑判定

- **M1（已完成）**：SPEC + PLAN + 完整 ArkTS 工程源码 + 1453 个离线 rawfile 资源。
- **M2（已完成）**：HarmonyOS CLI 26.0.0.821 真实编译（`ets/modules.abc` / `resources.index`）+ 本地 release 签名（`verify-app` 通过）+ `dist/NeoWarp-2.3.0-harmony.hap`（119.52 MB / 1465 条目）。
- **M3（待真机）**：华为开发者正式证书重签 + §10 的 A1–A8 实机验收 + 应用市场上架。

> 说明：M2 与 M3 的边界由华为账号与真机决定，不是功能实现的边界。本轮已把「工具链不具备」这一限制彻底消除。
