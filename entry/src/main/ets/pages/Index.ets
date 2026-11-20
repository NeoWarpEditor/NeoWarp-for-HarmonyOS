/**
 * 主窗口 · 纯 ArkWeb 全屏容器
 *
 * 界面 100% 由离线 Web 站点渲染，与 Windows 版完全一致。
 * 原生侧不叠加标题栏、侧栏、任务面板、骨架屏、快捷键层等任何装饰；
 * 独立功能窗口由 SubWindowManager 以 OS 级子窗口承载。
 */

import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { HarmonyBridge } from '../bridge/HarmonyBridge';
import { NativeServices } from '../bridge/NativeServices';
import { Runtime } from '../common/Runtime';
import { WindowBus } from '../common/WindowBus';
import { BRIDGE_OBJECT_NAME } from '../common/Constants';

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: HarmonyBridge | null = null;
  private runtime: Runtime = Runtime.get();

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    let services: NativeServices | null = this.runtime.services;
    if (services === null) {
      services = new NativeServices(ctx, this.runtime.perf);
      this.runtime.services = services;
      services.initialize().catch((_e: Object): void => {
        // 目录创建失败由后续 IO 报错
      });
    }
    this.bridge = new HarmonyBridge(this.controller, ctx, services, this.runtime.perf);
    this.runtime.bridge = this.bridge;
    WindowBus.get().register('main', this.controller);
    this.bridge.warmup().catch((_e: Object): void => {
      // 预热失败不影响正常请求拦截
    });
  }

  aboutToDisappear(): void {
    WindowBus.get().unregister('main');
    this.runtime.webReady = false;
  }

  build() {
    Stack() {
      Web({ src: $rawfile('neowarp/index.html'), controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .imageAccess(true)
        .onlineImageAccess(false)
        .mixedMode(MixedMode.None)
        .zoomAccess(false)
        .horizontalScrollBarAccess(false)
        .verticalScrollBarAccess(false)
        .backgroundColor(Color.Transparent)
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
          this.runtime.webReady = false;
        })
        .onPageEnd(() => {
          this.runtime.webReady = true;
          // 文件关联：等价于桌面版通过 .sb3 拉起应用
          if (this.runtime.pendingOpenUri.length > 0 && this.bridge !== null) {
            this.bridge.emit('native', 'openUri', JSON.stringify({ uri: this.runtime.pendingOpenUri }));
            this.runtime.pendingOpenUri = '';
          }
        })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
