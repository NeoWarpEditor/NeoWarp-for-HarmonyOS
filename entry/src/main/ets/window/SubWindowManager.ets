/**
 * 真实子窗口管理器
 *
 * 对应 Windows 版 src-main/windows/*.js 里的每个 BrowserWindow：
 * 设置、编辑器、扩展编辑器、图片编辑器、AI 助手、任务管理器、关于……
 * 全部以 OS 级子窗口呈现（系统标题栏 / 可拖动 / 可缩放 / 任务栏可见），
 * 窗口内部只有铺满的 ArkWeb，不含任何自绘装饰，与桌面版保持同一套渲染内容。
 */

import { window } from '@kit.ArkUI';
import { common, abilityAccessCtrl, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { WindowHost } from '../bridge/NativeServices';
import { WindowBus } from '../common/WindowBus';
import { Runtime } from '../common/Runtime';
import { DeviceSnapshot } from '../common/Constants';

export interface SubWindowConfig {
  key: string;
  title: string;
  url: string;
  width: number;
  height: number;
}

export class SubWindowManager implements WindowHost {
  private static instance: SubWindowManager = new SubWindowManager();
  private stage: window.WindowStage | null = null;
  private context: common.UIAbilityContext | null = null;
  private mainWindow: window.Window | null = null;
  private windows: Map<string, window.Window> = new Map<string, window.Window>();
  private pending: SubWindowConfig[] = [];
  private chain: Promise<void> = Promise.resolve();
  private seq: number = 0;

  private constructor() {}

  static get(): SubWindowManager {
    return SubWindowManager.instance;
  }

  attach(stage: window.WindowStage, context: common.UIAbilityContext, mainWindow: window.Window | null): void {
    this.stage = stage;
    this.context = context;
    this.mainWindow = mainWindow;
  }

  /** 由 pages/SubWindow 在 aboutToAppear 时取走自己的配置（创建已串行化） */
  consumeConfig(): SubWindowConfig | null {
    const config: SubWindowConfig | undefined = this.pending.shift();
    return config === undefined ? null : config;
  }

  /** 子窗口被系统关闭按钮销毁时，由页面回调，保持 Web 侧窗口清单同步 */
  onWindowDestroyed(key: string): void {
    if (key.length === 0) return;
    this.windows.delete(key);
    WindowBus.get().unregister(key);
    this.announceState(key, false);
  }

  // ── WindowHost ────────────────────────────────────────────────────────

  openWindow(key: string, title: string, url: string, width: number, height: number): void {
    const config: SubWindowConfig = {
      key: key, title: title, url: url, width: width, height: height
    };
    this.chain = this.chain
      .then((): Promise<void> => this.doOpen(config))
      .catch((_e: Object): void => {
        // 单个窗口创建失败不影响后续窗口
      });
  }

  closeWindow(key: string): void {
    const sub: window.Window | undefined = this.windows.get(key);
    if (sub === undefined) return;
    this.windows.delete(key);
    WindowBus.get().unregister(key);
    this.announceState(key, false);
    sub.destroyWindow().catch((_e: Object): void => {
      // 已被系统销毁
    });
  }

  focusWindow(key: string): void {
    this.bringToFront(key);
  }

  setTitle(key: string, title: string): void {
    if (key.length > 0) {
      const sub: window.Window | undefined = this.windows.get(key);
      if (sub !== undefined) {
        sub.setWindowTitle(title).catch((_e: Object): void => {
          // 窗口已关闭
        });
        return;
      }
    }
    if (this.mainWindow !== null) {
      this.mainWindow.setWindowTitle(title).catch((_e: Object): void => {
        // 主窗口不可用
      });
    }
  }

  setFullscreen(enabled: boolean): void {
    if (this.mainWindow === null) return;
    this.mainWindow.setWindowLayoutFullScreen(enabled).catch((_e: Object): void => {
      // 自由窗口不支持沉浸式
    });
  }

  hasWindow(key: string): boolean {
    return this.windows.has(key);
  }

  publish(data: string): void {
    const script: string =
      'if (window.NWHarmony && window.NWHarmony.onBusMessage) {' +
      'window.NWHarmony.onBusMessage(' + data + ');' +
      '}';
    WindowBus.get().broadcast(script);
  }

  currentSnapshot(): DeviceSnapshot {
    return Runtime.get().snapshot;
  }

  async requestPermissions(names: string[]): Promise<boolean> {
    if (this.context === null) return false;
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const perms: Permissions[] = names as Permissions[];
      const pending = atManager.requestPermissionsFromUser(this.context, perms) as Promise<PermissionRequestResult>;
      const result: PermissionRequestResult = await pending;
      return result.authResults.every((v: number): boolean => v === 0);
    } catch (_e) {
      return false;
    }
  }

  // ── 内部 ──────────────────────────────────────────────────────────────

  private async doOpen(config: SubWindowConfig): Promise<void> {
    if (this.windows.has(config.key)) {
      await this.bringToFront(config.key);
      return;
    }
    if (this.stage === null) return;
    const safeName: string = 'nw_' + config.key.replace(/[^A-Za-z0-9_]/g, '_');
    const sub: window.Window = await this.stage.createSubWindow(safeName);
    this.pending.push(config);
    // 系统标题栏与窗口按钮，等价于 Electron 默认 frame
    try {
      sub.setWindowDecorVisible(true);
    } catch (_e) {
      // 手机/平板形态无系统装饰，忽略
    }
    try {
      await sub.setWindowTitle(config.title);
    } catch (_e) {
      // 部分形态不支持设置标题
    }
    await sub.setUIContent('pages/SubWindow');
    try {
      await sub.resize(config.width, config.height);
      const offset: number = (this.seq % 6) * 24;
      await sub.moveWindowTo(120 + offset, 80 + offset);
    } catch (_e) {
      // 尺寸受限时保持系统默认值
    }
    this.seq += 1;
    await sub.showWindow();
    this.windows.set(config.key, sub);
    this.announceState(config.key, true);
  }

  private async bringToFront(key: string): Promise<void> {
    const sub: window.Window | undefined = this.windows.get(key);
    if (sub === undefined) return;
    try {
      await sub.showWindow();
    } catch (_e) {
      // 窗口已销毁
    }
  }

  /** 窗口开合状态广播给所有 WebView，保证 NWWindow.has 跨窗口一致 */
  private announceState(key: string, exists: boolean): void {
    const script: string =
      'if (window.NWHarmony && window.NWHarmony.onWindowState) {' +
      'window.NWHarmony.onWindowState(' + JSON.stringify(key) + ', ' + (exists ? 'true' : 'false') + ');' +
      '}';
    WindowBus.get().broadcast(script);
  }
}
