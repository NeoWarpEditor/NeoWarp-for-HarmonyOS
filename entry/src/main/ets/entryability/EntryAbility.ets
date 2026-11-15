/**
 * NeoWarp EntryAbility · HarmonyOS 7 / API 26 · Stage 模型
 *
 * 职责：
 *  - 预初始化 ArkWeb 引擎（冷启动优化）
 *  - 建立原生服务与偏好存储目录
 *  - 监听折叠状态 / 窗口尺寸 / 前后台 / 内存水位
 *  - 文件关联（.sb3 / .sb2 / .sb / .np1 / .npnp / .viewsb3）拉起
 *  - 折叠切换只更新 Runtime.snapshot，不重建任何 Web 组件
 */

import { UIAbility, Want, AbilityConstant } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { NativeServices } from '../bridge/NativeServices';
import { HarmonyBridge } from '../bridge/HarmonyBridge';
import { Runtime } from '../common/Runtime';
import { DeviceProfile } from '../common/DeviceProfile';

export default class EntryAbility extends UIAbility {
  private runtime: Runtime = Runtime.get();
  private mainWindow: window.Window | null = null;
  private foldListenerRegistered: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 冷启动关键路径：在 UI 首帧之前把 Web 引擎拉起来
    try {
      webview.WebviewController.initializeWebEngine();
    } catch (_e) { /* 引擎已初始化 */ }

    DeviceProfile.probeInputDevices().catch((_e: Object) => { /* 探测失败按无键鼠处理 */ });
    const services = new NativeServices(this.context as common.UIAbilityContext, this.runtime.perf);
    this.runtime.services = services;
    services.initialize().catch((_e: Object) => { /* 目录创建失败由后续 IO 报错 */ });

    if (want.uri !== undefined && want.uri.length > 0) {
      this.runtime.pendingOpenUri = want.uri;
    }
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    if (want.uri !== undefined && want.uri.length > 0) {
      this.runtime.pendingOpenUri = want.uri;
      if (this.runtime.webReady && this.runtime.bridge !== null) {
        this.runtime.bridge.emit('native', 'openUri', JSON.stringify({ uri: want.uri }));
      }
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index').then(() => {
      this.setupWindow(windowStage);
    }).catch((_e: Object) => { /* 加载失败由 Web 层错误回调兜底 */ });
  }

  private setupWindow(windowStage: window.WindowStage): void {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      this.mainWindow = win;
      win.setWindowLayoutFullScreen(true, (_e: Object) => { /* 沉浸式由 ArkUI 处理安全区 */ });

      const rect = win.getWindowProperties().windowRect;
      this.refreshSnapshot(px2vp(rect.width), px2vp(rect.height));

      win.on('windowSizeChange', (size: window.Size) => {
        this.refreshSnapshot(px2vp(size.width), px2vp(size.height));
      });

      if (!this.foldListenerRegistered) {
        display.on('foldStatusChange', (_status: number) => {
          if (this.mainWindow !== null) {
            const r = this.mainWindow.getWindowProperties().windowRect;
            this.refreshSnapshot(px2vp(r.width), px2vp(r.height));
          }
        });
        this.foldListenerRegistered = true;
      }
    } catch (_e) {
      // 窗口能力不可用时退化为静态断点
      this.refreshSnapshot(840, 600);
    }
  }

  /** 只更新形态快照并广播，Web 组件保持同一实例 → 编辑状态不丢失 */
  private refreshSnapshot(widthVp: number, heightVp: number): void {
    const snapshot = DeviceProfile.snapshot(widthVp, heightVp, display.getDefaultDisplaySync().densityDPI / 160);
    this.runtime.snapshot = snapshot;
    this.runtime.perf.applyForm(snapshot.form);
    if (this.runtime.bridge !== null && this.runtime.webReady) {
      this.runtime.bridge.notifyDeviceChange(snapshot);
    }
    // 通知 UI 重排（折痕避让/列数/侧栏），Web 组件保持同一实例
    if (this.runtime.deviceChangeHandler !== null) {
      this.runtime.deviceChangeHandler();
    }
  }

  onForeground(): void {
    this.runtime.perf.onForeground();
    if (this.runtime.bridge !== null) {
      this.runtime.bridge.notifyVisibility(true);
    }
  }

  onBackground(): void {
    this.runtime.perf.onBackground();
    if (this.runtime.bridge !== null) {
      this.runtime.bridge.notifyVisibility(false);
    }
  }

  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    this.runtime.perf.onMemoryLevel(Number(level));
  }

  onWindowStageDestroy(): void {
    if (this.foldListenerRegistered) {
      try { display.off('foldStatusChange'); } catch (_e) { /* no-op */ }
      this.foldListenerRegistered = false;
    }
    this.mainWindow = null;
  }

  onDestroy(): void {
    this.runtime.webReady = false;
  }
}
