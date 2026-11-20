/**
 * 跨窗口消息总线（原生侧）
 *
 * Windows 版各 BrowserWindow 通过主进程 IPC 互通；HarmonyOS 上每个子窗口是
 * 独立的 ArkWeb 实例，BroadcastChannel 不跨 WebView 共享，因此由原生层把
 * Web 侧 RPC 消息镜像转发给所有窗口，保证与桌面版等价的功能联动
 * （设置改主题、AI 面板取编辑器代码、扩展编辑器回传结果等）。
 */

import { webview } from '@kit.ArkWeb';

export class WindowBus {
  private static instance: WindowBus = new WindowBus();
  private controllers: Map<string, webview.WebviewController> = new Map<string, webview.WebviewController>();

  private constructor() {}

  static get(): WindowBus {
    return WindowBus.instance;
  }

  register(id: string, controller: webview.WebviewController): void {
    this.controllers.set(id, controller);
  }

  unregister(id: string): void {
    this.controllers.delete(id);
  }

  /** 向全部已注册窗口注入脚本；excludeId 用于跳过发起方 */
  broadcast(script: string, excludeId: string = ''): void {
    this.controllers.forEach((controller: webview.WebviewController, id: string): void => {
      if (id === excludeId) {
        return;
      }
      controller.runJavaScript(script).catch((_e: Object): void => {
        // 页面尚未就绪时丢弃，下一次事件会补偿
      });
    });
  }
}
