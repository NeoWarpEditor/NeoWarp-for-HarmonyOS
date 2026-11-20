/**
 * NeoWarp HarmonyOS 7 / API 26 · 全局类型与常量
 *
 * 约定：热路径零反射、零 any、零动态分派。
 * 所有跨边界数据用显式 interface + JSON 序列化，编译期可检查。
 */

export enum DeviceForm {
  PHONE_COMPACT = 0,
  TABLET_PORTRAIT = 1,
  TABLET_LANDSCAPE = 2,
  WIDE_FOLD_CLOSED = 3,
  WIDE_FOLD_OPEN = 4,
  TRIPLE_FOLD_SINGLE = 5,
  TRIPLE_FOLD_DUAL = 6,
  TRIPLE_FOLD_TRIPLE = 7,
  PC = 8
}

export enum PerformanceTier {
  HIGH = 0,
  BALANCED = 1,
  SAVER = 2
}

export enum FoldState {
  UNKNOWN = 0,
  FOLDED = 1,
  HALF_FOLDED = 2,
  EXPANDED = 3
}

export interface CreaseRegion {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface DeviceSnapshot {
  form: DeviceForm;
  foldState: FoldState;
  widthVp: number;
  heightVp: number;
  aspectRatio: number;
  dpr: number;
  creaseRegions: CreaseRegion[];
  creaseCount: number;
  isPc: boolean;
  hasKeyboard: boolean;
}

export interface PerfPolicy {
  tier: PerformanceTier;
  targetFps: number;
  dprCap: number;
  workerCount: number;
  assetCacheMB: number;
  sampleIntervalMs: number;
  suspendOnBackground: boolean;
}

export interface BridgeEnvelope {
  ok: boolean;
  code: number;
  message: string;
  data: string;
}

export interface SystemStats {
  cpuPercent: number;
  memoryUsedMB: number;
  memoryTotalMB: number;
  coreCount: number;
  threadCount: number;
  timestamp: number;
}

export interface SpriteStat {
  name: string;
  threads: number;
  cpuPercent: number;
  memEstimateKB: number;
  blockCount: number;
  costumeCount: number;
  isStage: boolean;
}

export interface TaskStats {
  system: SystemStats;
  sprites: SpriteStat[];
}

export interface RecentProject {
  path: string;
  name: string;
  modifiedAt: number;
}

export interface NativeError {
  code: number;
  message: string;
}

/** ArkWeb 注入对象名：Web 侧通过 window.HarmonyNative.invoke(...) 调用 */
export const BRIDGE_OBJECT_NAME: string = 'HarmonyNative';

/** 离线站点在 rawfile 中的根路径 */
export const RAWFILE_ROOT: string = 'neowarp/';

/** 资源清单文件（由 scripts/prepare_offline.mjs 生成） */
export const ASSET_MANIFEST: string = 'neowarp/asset-manifest.json';

/** 原生服务白名单：显式分派，禁止字符串反射到方法 */
export const ALLOWED_BRIDGE_METHODS: string[] = [
  'fs.openProject', 'fs.saveProject', 'fs.saveAs', 'fs.listRecent', 'fs.deleteRecent',
  'fs.readAsset', 'fs.writeAsset',
  'crypto.hash', 'crypto.encrypt', 'crypto.decrypt',
  'system.getStats', 'system.getMemoryInfo', 'system.openExternal',
  'theme.get', 'theme.set',
  'window.open', 'window.close', 'window.focus', 'window.setTitle', 'window.fullscreen', 'window.has',
  'media.enumerateDevices', 'media.requestPermission',
  'perf.setProfile', 'perf.getMetrics', 'perf.notifyVisibility',
  'package.html', 'package.zip',
  'distributed.discover', 'distributed.send',
  'device.getProfile', 'device.onFoldChange',
  'bus.publish',
  // 局域网协作（复刻桌面版内置信令服务器）
  'collab.startHost', 'collab.endHost', 'collab.getInfo', 'collab.getMembers',
  'collab.getOnlineCount', 'collab.pushProject', 'collab.sendChat', 'collab.isRunning',
  'collab.getLocalIP', 'collab.discover',
  'collab.join', 'collab.leave', 'collab.sendProject'
];

/** 离线强保证：connect-src 仅 self，渲染层二次阻断出网 */
export const OFFLINE_CSP: string =
  "default-src 'self' data: blob:; " +
  "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; " +
  "style-src 'self' 'unsafe-inline' data:; " +
  "img-src 'self' data: blob:; " +
  "font-src 'self' data:; " +
  "media-src 'self' data: blob:; " +
  "worker-src 'self' blob:; " +
  "connect-src 'self' data: blob: ws: wss: http: https:; " +
  "form-action 'self'; base-uri 'self'; object-src 'none'";

/** 单次桥调用数据上限（字节），超限由调用方分片 */
export const BRIDGE_CHUNK_LIMIT: number = 2 * 1024 * 1024;

export const BRIDGE_OK: number = 0;
export const BRIDGE_ERR_UNKNOWN_METHOD: number = 1001;
export const BRIDGE_ERR_BAD_ARGS: number = 1002;
export const BRIDGE_ERR_IO: number = 2001;
export const BRIDGE_ERR_PERMISSION: number = 3001;
export const BRIDGE_ERR_OFFLINE: number = 4001;
export const BRIDGE_ERR_TIMEOUT: number = 5001;

export const BREAKPOINT_SM: number = 320;
export const BREAKPOINT_MD: number = 600;
export const BREAKPOINT_LG: number = 840;
export const CREASE_SAFETY_VP: number = 24;
export const TOUCH_TARGET_MIN_VP: number = 48;

export function okEnvelope(data: string): BridgeEnvelope {
  return { ok: true, code: BRIDGE_OK, message: '', data: data };
}

export function errEnvelope(code: number, message: string): BridgeEnvelope {
  return { ok: false, code: code, message: message, data: '' };
}

export function formName(form: DeviceForm): string {
  switch (form) {
    case DeviceForm.PC: return 'PC';
    case DeviceForm.TABLET_PORTRAIT:
    case DeviceForm.TABLET_LANDSCAPE: return '平板';
    case DeviceForm.WIDE_FOLD_CLOSED:
    case DeviceForm.WIDE_FOLD_OPEN: return '阔折叠';
    case DeviceForm.TRIPLE_FOLD_SINGLE:
    case DeviceForm.TRIPLE_FOLD_DUAL:
    case DeviceForm.TRIPLE_FOLD_TRIPLE: return '三折叠';
    default: return '紧凑屏';
  }
}

export function tierName(tier: PerformanceTier): string {
  switch (tier) {
    case PerformanceTier.HIGH: return '高性能';
    case PerformanceTier.BALANCED: return '均衡';
    default: return '省电';
  }
}
