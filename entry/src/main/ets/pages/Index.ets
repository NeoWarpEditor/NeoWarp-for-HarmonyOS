/**
 * 主页面 · ArkUI 壳 + ArkWeb 离线容器
 *
 * - Web 组件单例：折叠/窗口尺寸变化只重排 ArkUI 布局，绝不重建 → 编辑状态不丢失
 * - javaScriptProxy 注入 HarmonyNative.invoke；onInterceptRequest 做离线资源映射
 * - 断点/折痕/快捷键/后台挂起统一在此编排
 */

import { webview } from '@kit.ArkWeb';
import { common, abilityAccessCtrl, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { HarmonyBridge } from '../bridge/HarmonyBridge';
import { NativeServices } from '../bridge/NativeServices';
import { Runtime } from '../common/Runtime';
import { DeviceProfile } from '../common/DeviceProfile';
import {
  DeviceForm, DeviceSnapshot, BRIDGE_OBJECT_NAME, formName, TaskStats
} from '../common/Constants';
import { TitleBar } from '../components/TitleBar';
import { SidePanel } from '../components/SidePanel';
import { FoldSafeLayout } from '../components/FoldSafeLayout';
import { TaskManagerPanel } from '../components/TaskManagerPanel';

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private runtime: Runtime = Runtime.get();
  private bridge: HarmonyBridge | null = null;
  private statsTimer: number = -1;

  @State private form: DeviceForm = DeviceForm.TABLET_LANDSCAPE;
  @State private formLabel: string = '平板';
  @State private columns: number = 2;
  @State private showChrome: boolean = true;
  @State private sideVisible: boolean = true;
  @State private safeLeft: number = 0;
  @State private safeRight: number = 0;
  @State private taskPanelVisible: boolean = false;
  @State private webReady: boolean = false;
  @State private statsJson: string = '{}';
  @State private title: string = 'NeoWarp';

  aboutToAppear(): void {
    // 折叠态/窗口尺寸变化由 Ability 触发，这里只重排布局（Web 组件不重建）
    this.runtime.deviceChangeHandler = (): void => {
      this.applySnapshot(this.runtime.snapshot);
    };
    const ctx = getContext(this) as common.UIAbilityContext;
    let services: NativeServices | null = this.runtime.services;
    if (services === null) {
      services = new NativeServices(ctx, this.runtime.perf);
      this.runtime.services = services;
      services.initialize().catch((_e: Object) => { /* no-op */ });
    }
    this.bridge = new HarmonyBridge(this.controller, ctx, services, this.runtime.perf);
    this.runtime.bridge = this.bridge;

    // 宿主窗口能力：Web 层的 window.open/close 落到 ArkUI 浮层路由
    services.attachHost({
      openWindow: (key: string, windowTitle: string): void => {
        this.emitAction('window_open', key + '|' + windowTitle);
      },
      closeWindow: (key: string): void => {
        this.emitAction('window_close', key);
      },
      focusWindow: (key: string): void => {
        this.emitAction('window_focus', key);
      },
      setTitle: (t: string): void => {
        this.title = t;
      },
      setFullscreen: (enabled: boolean): void => {
        try {
          const win = window.findWindow('neowarp');
          win.setWindowLayoutFullScreen(enabled, (_e: Object) => { /* no-op */ });
        } catch (_e) { /* 自由窗口不可用 */ }
      },
      requestPermissions: async (names: string[]): Promise<boolean> => {
        try {
          const atManager = abilityAccessCtrl.createAtManager();
          const perms: Permissions[] = names as Permissions[];
          const pending = atManager.requestPermissionsFromUser(ctx, perms) as Promise<PermissionRequestResult>;
          const result: PermissionRequestResult = await pending;
          return result.authResults.every((v: number) => v === 0);
        } catch (_e) {
          return false;
        }
      },
      currentSnapshot: () => this.runtime.snapshot
    });

    this.applySnapshot(this.runtime.snapshot);
    this.bridge.warmup().then(() => {
      // 资源预热完成后再加载页面，减少首帧 IO 抖动
    }).catch((_e: Object) => { /* no-op */ });

    this.startStatsTimer();
  }

  aboutToDisappear(): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
    this.runtime.webReady = false;
    this.runtime.deviceChangeHandler = null;
  }

  build() {
    Column() {
      TitleBar({
        title: this.title,
        formLabel: this.formLabel,
        offline: true,
        showDesktopChrome: this.showChrome,
        onAction: (id: string): void => this.handleAction(id)
      })

      FoldSafeLayout({
        safeLeft: this.safeLeft,
        safeRight: this.safeRight,
        columns: this.columns
      }) {
        Row() {
          SidePanel({
            visible: this.sideVisible,
            widthVp: 260,
            onSelect: (id: string): void => this.handleAction(id)
          })

          Stack() {
            Web({
              src: $rawfile('neowarp/index.html'),
              controller: this.controller
            })
              .javaScriptAccess(true)
              .domStorageAccess(true)
              .fileAccess(true)
              .imageAccess(true)
              .onlineImageAccess(false)
              .mixedMode(MixedMode.None)
              .zoomAccess(false)
              .horizontalScrollBarAccess(false)
              .verticalScrollBarAccess(false)
              .backgroundColor($r('app.color.app_background'))
              .javaScriptProxy({
                object: this.bridge as HarmonyBridge,
                name: BRIDGE_OBJECT_NAME,
                methodList: [],
                asyncMethodList: ['invoke'],
                controller: this.controller
              })
              .onInterceptRequest((event) => {
                if (this.bridge !== null && event.request !== undefined) {
                  return this.bridge.intercept(event.request);
                }
                return null;
              })
              .onPageBegin(() => {
                this.webReady = false;
              })
              .onPageEnd(() => {
                this.webReady = true;
                this.runtime.webReady = true;
                if (this.bridge !== null) {
                  this.bridge.notifyDeviceChange(this.runtime.snapshot);
                  this.bridge.notifyThemeChange('dark');
                  if (this.runtime.pendingOpenUri.length > 0) {
                    this.bridge.emit('native', 'openUri',
                      JSON.stringify({ uri: this.runtime.pendingOpenUri }));
                    this.runtime.pendingOpenUri = '';
                  }
                }
              })
              .onErrorReceive((event) => {
                // 离线资源缺失时给出可见反馈，不静默白屏
                this.title = 'NeoWarp · 资源加载异常';
              })
              .width('100%')
              .height('100%')

            if (!this.webReady) {
              Column() {
                Text('N')
                  .fontSize(30)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
                  .width(64)
                  .height(64)
                  .textAlign(TextAlign.Center)
                  .borderRadius(18)
                  .linearGradient({
                    angle: 135,
                    colors: [['#0A84FF', 0.0], ['#5E5CE6', 1.0]]
                  })
                Text('正在加载离线编辑器…')
                  .fontSize(12)
                  .fontColor($r('app.color.on_surface_secondary'))
                  .margin({ top: 16 })
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .backgroundColor($r('app.color.app_background'))
            }

            if (this.taskPanelVisible) {
              Row() {
                Blank()
                TaskManagerPanel({
                  statsJson: this.statsJson,
                  visible: true,
                  onClose: (): void => { this.taskPanelVisible = false; }
                })
              }
              .width('100%')
              .height('100%')
              .alignItems(VerticalAlign.Top)
            }
          }
          .layoutWeight(1)
          .height('100%')
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
    .focusable(true)
    .onKeyEvent((event: KeyEvent) => this.handleShortcut(event))
  }

  // ── 形态与布局 ────────────────────────────────────────────────────────

  private applySnapshot(snapshot: DeviceSnapshot): void {
    this.form = snapshot.form;
    this.formLabel = formName(snapshot.form);
    this.columns = DeviceProfile.columnCount(snapshot.form);
    this.showChrome = DeviceProfile.showDesktopChrome(snapshot.form);
    this.sideVisible = this.showChrome && this.columns >= 2;
    const padding = DeviceProfile.creasePadding(snapshot);
    this.safeLeft = padding[0];
    this.safeRight = padding[1];
  }

  // 由 EntryAbility 在折叠/尺寸变化时调用（通过 AppStorage 事件亦可）
  private onDeviceChanged(): void {
    this.applySnapshot(this.runtime.snapshot);
  }

  // ── 交互 ──────────────────────────────────────────────────────────────

  private handleAction(id: string): void {
    if (id === 'task_manager') {
      this.taskPanelVisible = !this.taskPanelVisible;
      return;
    }
    if (id === 'menu_file' || id === 'menu_edit' || id === 'menu_view') {
      this.emitAction('menu', id);
      return;
    }
    this.emitAction('action', id);
  }

  private emitAction(kind: string, payload: string): void {
    if (this.bridge !== null && this.webReady) {
      this.bridge.emit('native', kind, JSON.stringify({ id: payload }));
    }
  }

  /** PC 快捷键：与桌面版 abstract.js:232-301 的主要组合一一对应 */
  private handleShortcut(event: KeyEvent): void {
    if (event.type !== KeyType.Down) return;
    // API 26: getModifierKeyState 为可选方法，参数为 Array<string>
    const ctrl: boolean = event.getModifierKeyState?.(['Ctrl']) ?? false;
    const shift: boolean = event.getModifierKeyState?.(['Shift']) ?? false;
    if (!ctrl) return;
    switch (event.keyCode) {
      case 78: // N
        this.handleAction('new'); break;
      case 79: // O
        this.handleAction('open'); break;
      case 83: // S
        this.handleAction('save'); break;
      case 80: // P
        this.handleAction('packager'); break;
      case 77: // M
        if (shift) this.handleAction('task_manager');
        break;
      default: break;
    }
  }

  private startStatsTimer(): void {
    this.statsTimer = setInterval(() => {
      if (!this.runtime.perf.isForeground()) return;
      const stats: TaskStats = this.runtime.perf.sample();
      // 把 60 点历史序列一并下发，task-manager 折线图直接绘制真实采样
      this.statsJson = JSON.stringify({
        system: stats.system,
        sprites: stats.sprites,
        cpuSeries: this.runtime.perf.cpuSeries(),
        memorySeries: this.runtime.perf.memorySeries()
      });
      if (this.bridge !== null && this.webReady) {
        this.bridge.pushTaskStats(stats);
      }
    }, this.runtime.perf.currentPolicy().sampleIntervalMs);
  }
}
