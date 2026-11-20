/**
 * 独立功能窗口页面 —— 等价 Windows 版的一个 BrowserWindow。
 * 页面内只有一个铺满的 ArkWeb，所有可见内容均由离线站点渲染，
 * 标题栏/边框/按钮交给系统窗口装饰，不叠加任何 ArkUI 界面元素。
 */

import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { HarmonyBridge } from '../bridge/HarmonyBridge';
import { NativeServices } from '../bridge/NativeServices';
import { Runtime } from '../common/Runtime';
import { WindowBus } from '../common/WindowBus';
import { BRIDGE_OBJECT_NAME } from '../common/Constants';
import { SubWindowManager, SubWindowConfig } from '../window/SubWindowManager';

@Entry
@Component
struct SubWindow {
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: HarmonyBridge | null = null;
  private busId: string = '';
  @State private src: string = '';

  aboutToAppear(): void {
    const config: SubWindowConfig | null = SubWindowManager.get().consumeConfig();
    if (config === null) {
      return;
    }
    this.busId = config.key;
    // fragment 不影响 rawfile 路径解析，同时把窗口 key 交给 Web 侧桥接层
    this.src = 'resource://rawfile/neowarp/' + config.url + '#nwwin=' + encodeURIComponent(config.key);
    const ctx = getContext(this) as common.UIAbilityContext;
    const services: NativeServices | null = Runtime.get().services;
    if (services !== null) {
      this.bridge = new HarmonyBridge(this.controller, ctx, services, Runtime.get().perf);
    }
    WindowBus.get().register(this.busId, this.controller);
  }

  aboutToDisappear(): void {
    WindowBus.get().unregister(this.busId);
    SubWindowManager.get().onWindowDestroyed(this.busId);
  }

  build() {
    Stack() {
      if (this.src.length > 0) {
        Web({ src: this.src, controller: this.controller })
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
          .width('100%')
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
