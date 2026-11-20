/* ==========================================================================
 * NeoWarp HarmonyOS 桥接层（Web 侧）
 *
 * 加载顺序：nw-core.js → shims/*.js → harmony-bridge.js（必须最后）
 *
 * 职责：
 *  1) 把 ArkTS 原生能力注册进既有 NW.host 服务总线（30-host.js），shim 零改动；
 *  2) polyfill File System Access API → ArkTS 文件桥；
 *  3) 禁用 Service Worker 与外部网络请求（离线强保证的渲染层兜底）；
 *  4) 把页内 iframe 浮层窗口 / window.open 新标签页统一替换为 OS 级真实子窗口，
 *     等价 Windows 版 src-main/windows/*.js 的独立 BrowserWindow；
 *  5) 用原生总线镜像 BroadcastChannel，保证各真实窗口之间的 RPC 联动。
 *
 * 注意：此处不新增任何界面元素，全部可见内容仍由 Web 站点渲染。
 * ========================================================================== */
(function (global) {
  'use strict';

  var NW = global.NW || (global.NW = {});
  var host = global.NWHost || NW.host;
  var rpc = NW.rpc;
  // native 对象在 invoke 中动态获取（见 getNative），此处不缓存，
  // 避免 javaScriptProxy 注入晚于脚本执行导致窗口覆盖未安装。
  var cachedTaskStats = { system: null, sprites: [] };
  var currentProfile = null;
  var OFFLINE_MESSAGE = '[NeoWarp HarmonyOS] 离线模式：网络请求已被阻止';

  /* javaScriptProxy 注入存在时序差：脚本执行时 HarmonyNative 可能尚未挂到 window。
     旧实现此刻直接 return，导致 global.open / NW.openRoute 的「真实子窗口」覆盖
     未安装，openRoute 退回 location.href 整页跳转（主页点 SOLO 变成当前页）。
     这里改为动态获取 + 延迟重试，保证窗口覆盖永远先装上。 */
  function getNative () {
    return global.HarmonyNative && typeof global.HarmonyNative.invoke === 'function'
      ? global.HarmonyNative : null;
  }

  /* ------------------------------- 调用封装 ------------------------------- */
  function invokeRaw (nat, ns, method, payload) {
    return Promise.resolve(nat.invoke(ns, method, payload)).then(function (text) {
      var envelope;
      try { envelope = JSON.parse(text); } catch (e) { throw new Error('桥返回非法 JSON: ' + text); }
      if (!envelope || !envelope.ok) {
        throw new Error('[' + (envelope && envelope.code) + '] ' + (envelope && envelope.message));
      }
      if (!envelope.data) return null;
      try { return JSON.parse(envelope.data); } catch (e) { return envelope.data; }
    });
  }

  /* 等待 native 就绪再真正调用：最多约 2 秒（100 × 20ms）。
     窗口打开等 UI 操作因此不会因注入时序丢失。 */
  function invoke (ns, method, args) {
    var payload = JSON.stringify(args || {});
    return new Promise(function (resolve, reject) {
      var tries = 0;
      function attempt () {
        var nat = getNative();
        if (nat) {
          invokeRaw(nat, ns, method, payload).then(resolve, reject);
        } else if (++tries > 100) {
          reject(new Error('HarmonyNative unavailable: ' + ns + '.' + method));
        } else {
          setTimeout(attempt, 20);
        }
      }
      attempt();
    });
  }

  /* --------------------------- NW.host 服务注册 --------------------------- */
  // 30-host.js 的 register 用 Object.assign 合并同命名空间，因此这里只覆盖
  // 需要原生能力的方法，其余（主题/设置/AI 配置等）保留网页版实现。
  if (host && typeof host.register === 'function') {
    host.register('editor', {
      // 桌面版 task-manager.js:69-91 用 os.cpus() 差分算 CPU；
      // 鸿蒙版改由 ArkTS PerformanceManager 采样，字段做等价映射。
      getSystemStats: function () {
        return invoke('system', 'getStats', {}).then(function (s) {
          // 同时提供桌面版字段（ramUsedMB/ramTotalMB）与字节字段，
          // task-manager.html 读取 ramUsedMB/ramTotalMB，缺一即显示 NaN。
          if (!s) return {
            cpuPercent: 0, ramUsedMB: 0, ramTotalMB: 0,
            usedMemory: 0, totalMemory: 0, coreCount: 0, threadCount: 0
          };
          var stats = s.system || s;
          var usedMB = stats.memoryUsedMB || 0;
          var totalMB = stats.memoryTotalMB || 0;
          return {
            cpuPercent: stats.cpuPercent || 0,
            ramUsedMB: usedMB,
            ramTotalMB: totalMB,
            usedMemory: usedMB * 1024 * 1024,
            totalMemory: totalMB * 1024 * 1024,
            coreCount: stats.coreCount || 0,
            threadCount: stats.threadCount || 0
          };
        });
      },
      // 角色统计由 VM 事件推送到 ArkTS，再由 native.taskStats 事件回传缓存
      getSpriteStats: function () {
        var totalThreads = 0;
        (cachedTaskStats.sprites || []).forEach(function (s) { totalThreads += s.threads || 0; });
        return Promise.resolve({
          sprites: cachedTaskStats.sprites || [],
          totalThreads: totalThreads
        });
      }
    });

    // 命名空间与 ArkTS 白名单一一对应（ns.method），
    // 30-host.js 的分派是 service[data.m]，因此方法必须扁平注册，不能嵌对象。
    host.register('fs', {
      openProject: function () { return invoke('fs', 'openProject', {}); },
      saveProject: function (a) { return invoke('fs', 'saveProject', a || {}); },
      saveAs: function (a) { return invoke('fs', 'saveAs', a || {}); },
      listRecent: function () { return invoke('fs', 'listRecent', {}); },
      readAsset: function (a) { return invoke('fs', 'readAsset', a || {}); },
      writeAsset: function (a) { return invoke('fs', 'writeAsset', a || {}); }
    });
    host.register('system', {
      getStats: function () { return invoke('system', 'getStats', {}); },
      getMemoryInfo: function () { return invoke('system', 'getMemoryInfo', {}); },
      openExternal: function (a) { return invoke('system', 'openExternal', a || {}); }
    });
    host.register('theme', {
      get: function () { return invoke('theme', 'get', {}); },
      set: function (a) { return invoke('theme', 'set', a || {}); }
    });
    host.register('window', {
      open: function (a) { return invoke('window', 'open', a || {}); },
      close: function (a) { return invoke('window', 'close', a || {}); },
      focus: function (a) { return invoke('window', 'focus', a || {}); },
      setTitle: function (a) { return invoke('window', 'setTitle', a || {}); },
      fullscreen: function (a) { return invoke('window', 'fullscreen', a || {}); }
    });
    host.register('media', {
      enumerateDevices: function () { return invoke('media', 'enumerateDevices', {}); },
      requestPermission: function (a) { return invoke('media', 'requestPermission', a || {}); }
    });
    host.register('perf', {
      setProfile: function (a) { return invoke('perf', 'setProfile', a || {}); },
      getMetrics: function () { return invoke('perf', 'getMetrics', {}); },
      notifyVisibility: function (a) { return invoke('perf', 'notifyVisibility', a || {}); }
    });
    host.register('device', {
      getProfile: function () { return invoke('device', 'getProfile', {}); }
    });
    host.register('package', {
      html: function () { return invoke('package', 'html', {}); },
      zip: function () { return invoke('package', 'zip', {}); }
    });

    // ArkTS 通过 NWHost.emit 推事件；包装一层让顶层页面自身也能收到（BroadcastChannel 不会自发自收）
    var originalEmit = host.emit;
    host.emit = function (ns, name, data, except) {
      originalEmit.call(host, ns, name, data, except);
      if (rpc && typeof rpc.emit === 'function') rpc.emit(ns, name, data);
    };
  }

  /* --------------------- File System Access API polyfill --------------------- */
  // ArkWeb 不提供 showOpenFilePicker / showSaveFilePicker；
  // 网页版 editor/misc/image-editor 等 shim 依赖它们，这里透明转接到 ArkTS 文件桥。
  function base64ToBytes (b64) {
    var raw = global.atob(b64);
    var out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out;
  }

  function bytesToBase64 (bytes) {
    var chunk = 0x8000;
    var parts = [];
    for (var i = 0; i < bytes.length; i += chunk) {
      parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + chunk)));
    }
    return global.btoa(parts.join(''));
  }

  function abortError () {
    var e = new Error('用户取消');
    e.name = 'AbortError';
    return e;
  }

  function asBytes (data) {
    if (typeof data === 'string') return Promise.resolve(new TextEncoder().encode(data));
    if (data instanceof ArrayBuffer) return Promise.resolve(new Uint8Array(data));
    if (data && data.buffer instanceof ArrayBuffer) return Promise.resolve(new Uint8Array(data.buffer));
    if (typeof Blob !== 'undefined' && data instanceof Blob) {
      return data.arrayBuffer().then(function (buf) { return new Uint8Array(buf); });
    }
    return Promise.resolve(new Uint8Array(0));
  }

  if (!global.showOpenFilePicker) {
    global.showOpenFilePicker = function (options) {
      return invoke('fs', 'openProject', {}).then(function (result) {
        if (!result || result.cancelled) throw abortError();
        var bytes = base64ToBytes(result.data);
        var file = new File([bytes], result.name);
        return [{
          name: result.name,
          getFile: function () { return Promise.resolve(file); },
          createWritable: function () { return makeWritable(result.name, bytes); }
        }];
      });
    };
  }

  if (!global.showSaveFilePicker) {
    global.showSaveFilePicker = function (options) {
      var suggested = options && options.suggestedName ? options.suggestedName : 'project.sb3';
      return Promise.resolve({
        name: suggested,
        createWritable: function () { return makeWritable(suggested, null); }
      });
    };
  }

  function makeWritable (name, initialBytes) {
    var chunks = [];
    if (initialBytes) chunks.push(initialBytes);
    return Promise.resolve({
      write: function (data) { return asBytes(data).then(function (b) { chunks.push(b); }); },
      close: function () {
        var total = 0;
        chunks.forEach(function (c) { total += c.length; });
        var merged = new Uint8Array(total);
        var offset = 0;
        chunks.forEach(function (c) { merged.set(c, offset); offset += c.length; });
        chunks.length = 0;
        return invoke('fs', 'saveAs', { name: name, data: bytesToBase64(merged) });
      },
      abort: function () { chunks.length = 0; return Promise.resolve(); }
    });
  }

  /* --------------------------- 在线状态语义修正 --------------------------- */
  /* ArkWeb 无 INTERNET 权限，navigator.onLine 可能恒为 false，导致 GUI 误判为
     "离线"并禁用本地功能、弹出离线提示。本应用所有资源均内置于 rawfile，
     本地功能与在线与否无关；统一报告在线，避免误判（issue 1/2）。 */
  try {
    if (global.navigator) {
      Object.defineProperty(global.navigator, 'onLine', {
        configurable: true,
        get: function () { return true; }
      });
    }
  } catch (e) { /* 只读实现下忽略 */ }

  /* --------------------------- 离线强保证（渲染层） --------------------------- */
  // 1) Service Worker 在 file/resource 下不可用，且缓存职责已由原生拦截层承担
  if (global.navigator && global.navigator.serviceWorker) {
    try {
      Object.defineProperty(global.navigator.serviceWorker, 'register', {
        configurable: true,
        value: function () { return Promise.resolve({ scope: '.', active: null }); }
      });
    } catch (e) { /* 只读实现下忽略 */ }
  }

  // 2) 外部 fetch 一律拒绝；Scratch 素材 CDN 请求交给原生拦截层映射到内置 rawfile
  var originalFetch = global.fetch ? global.fetch.bind(global) : null;
  global.fetch = function (input, init) {
    var url = typeof input === 'string' ? input : (input && input.url) || '';
    if (/^https?:\/\//i.test(url)) {
      var isAsset = url.indexOf('assets.scratch.mit.edu') >= 0 ||
        url.indexOf('cdn.assets.scratch.mit.edu') >= 0;
      if (!isAsset) return Promise.reject(new Error(OFFLINE_MESSAGE + ': ' + url));
    }
    if (originalFetch) return originalFetch(input, init);
    return Promise.reject(new Error('fetch unavailable'));
  };

  /* ------------------------------ 事件订阅 ------------------------------ */
  if (rpc && typeof rpc.on === 'function') {
    rpc.on('device', 'profile', function (profile) {
      currentProfile = profile;
      var form = profile && profile.form;
      try {
        global.document.documentElement.setAttribute('data-nw-device-form', String(form));
        global.document.documentElement.setAttribute('data-nw-columns',
          String(profile && profile.columns ? profile.columns : (form >= 5 ? 3 : 2)));
      } catch (e) { /* 文档未就绪 */ }
      if (typeof global.CustomEvent === 'function') {
        global.dispatchEvent(new CustomEvent('neowarp:device', { detail: profile }));
      }
    });

    rpc.on('desktop', 'theme', function (payload) {
      if (payload && payload.theme) {
        try { global.localStorage.setItem('tw:theme', payload.theme); } catch (e) { /* no-op */ }
      }
    });

    rpc.on('native', 'taskStats', function (stats) {
      if (!stats) return;
      cachedTaskStats = {
        system: stats.system || null,
        sprites: stats.sprites || []
      };
    });

    rpc.on('native', 'visibility', function (payload) {
      if (typeof global.CustomEvent === 'function') {
        global.dispatchEvent(new CustomEvent('neowarp:visibility', { detail: payload }));
      }
      // 后台挂起 VM 渲染循环，前台恢复（性能调度）
      if (global.NWVM && typeof global.NWVM.setVisibility === 'function') {
        global.NWVM.setVisibility(!!(payload && payload.visible));
      }
    });

    rpc.on('native', 'openUri', function (payload) {
      if (payload && payload.uri && typeof global.CustomEvent === 'function') {
        global.dispatchEvent(new CustomEvent('neowarp:openUri', { detail: payload }));
      }
    });
  }

  /* ================ 真实系统窗口（替代页内 iframe 浮层 / 新标签页） ================ */
  /* Windows 版每个功能都是独立的 BrowserWindow；HarmonyOS 上由 ArkTS
     createSubWindow 承载，窗口内仍是同一份离线页面，界面完全一致。 */
  var ROUTES = NW.routes || {};
  var winSeq = 0;
  var handles = Object.create(null);
  // 所有窗口共享的窗口存在性表（由原生广播同步，跨 ArkWeb 实例一致）
  var windowStates = Object.create(null);

  /** 任意形式的站内 URL → rawfile 相对路径 */
  function toRelativeUrl (u) {
    var v = String(u || '');
    var m = v.match(/^[a-z][a-z0-9+.-]*:\/\/[^/]*\/(.*)$/i);
    if (m) v = m[1];
    var i = v.indexOf('neowarp/');
    if (i >= 0) v = v.substring(i + 'neowarp/'.length);
    v = v.replace(/^(\.\.\/)+/, '').replace(/^\.\//, '').replace(/^\/+/, '');
    return v.split('?')[0].split('#')[0] || 'index.html';
  }

  function routeKeyForUrl (url) {
    var rel = toRelativeUrl(url);
    var keys = Object.keys(ROUTES);
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i];
      if (ROUTES[k] && toRelativeUrl(ROUTES[k].url) === rel) return k;
    }
    return '';
  }

  function defaultTitle (key) {
    var r = ROUTES[key];
    return (r && r.title) || key;
  }

  /** 兼容 NWWindow.open 的对象参数与旧代码的字符串 key */
  function normalizeWindow (input) {
    var o;
    if (typeof input === 'string') {
      var route = ROUTES[input] || {};
      o = {
        key: input,
        title: route.title || input,
        url: route.url || (input + '/index.html'),
        width: route.width || 980,
        height: route.height || 700
      };
    } else {
      o = input || {};
    }
    var key = o.key || routeKeyForUrl(o.url) || ('nw-win-' + (++winSeq));
    var fallback = ROUTES[key] || {};
    return {
      key: key,
      title: o.title || defaultTitle(key),
      url: toRelativeUrl(o.url || fallback.url || 'index.html'),
      width: o.width || fallback.width || 980,
      height: o.height || fallback.height || 700
    };
  }

  function makeHandle (o) {
    return {
      key: o.key,
      title: o.title,
      url: o.url,
      close: function () { nativeWindowApi.close(o.key); },
      focus: function () { nativeWindowApi.focus(o.key); },
      minimize: function () { /* 由系统窗口管理 */ },
      restore: function () { nativeWindowApi.focus(o.key); },
      toggleMaximize: function () { /* 由系统窗口管理 */ },
      isMinimized: function () { return false; },
      isMaximized: function () { return false; },
      setTitle: function (next) {
        o.title = next;
        invoke('window', 'setTitle', { key: o.key, title: next }).catch(function () {});
      }
    };
  }

  var nativeWindowApi = {
    open: function (options) {
      var o = normalizeWindow(options);
      if (handles[o.key]) {
        invoke('window', 'focus', { key: o.key }).catch(function () {});
        return handles[o.key];
      }
      handles[o.key] = makeHandle(o);
      windowStates[o.key] = true;
      invoke('window', 'open', {
        key: o.key, title: o.title, url: o.url,
        width: o.width, height: o.height
      }).catch(function () { delete handles[o.key]; });
      return handles[o.key];
    },
    close: function (key) {
      delete handles[key];
      delete windowStates[key];
      invoke('window', 'close', { key: key }).catch(function () {});
      return true;
    },
    focus: function (key) {
      invoke('window', 'focus', { key: key }).catch(function () {});
      return !!handles[key];
    },
    has: function (key) { return !!handles[key] || !!windowStates[key]; },
    get: function (key) { return handles[key] || null; },
    closeByFrame: function () {
      // 独立窗口没有 iframe frameWindow；关闭请求落到自己所在的真实窗口
      var key = currentWindowKey();
      if (key) nativeWindowApi.close(key);
      return !!key;
    },
    closeAll: function () {
      Object.keys(handles).forEach(function (k) { nativeWindowApi.close(k); });
    },
    count: function () { return Object.keys(handles).length; }
  };

  // 覆盖 40-window-manager.js 的页内浮层实现
  global.NWWindow = nativeWindowApi;
  NW.window = nativeWindowApi;

  /** 受信任外链白名单：交给系统浏览器打开，不加载进本离线 ArkWeb */
  function openExternal (url) {
    invoke('system', 'openExternal', { url: url }).catch(function () {});
  }
  var TRUSTED_EXTERNAL = /^https?:\/\/(github\.com|www\.github\.com|shiyuan-318\.github\.io|neowarp\.org|scratch\.mit\.edu|turbowarp\.org)($|\/)/i;

  /* 36-app-windows.js 里 newTab 路由走 window.open；这里统一转成真实子窗口。
     返回 truthy，避免其 "弹窗被拦截" 分支把当前窗口整页跳转。 */
  var originalOpen = global.open;
  global.open = function (url, target, features) {
    var raw = String(url || '');
    var external = /^https?:\/\//i.test(raw) && raw.indexOf(global.location.origin) !== 0;
    if (external) {
      if (TRUSTED_EXTERNAL.test(raw)) openExternal(raw);
      return null;   // 不进入本窗口，避免离线 ArkWeb 尝试加载外站
    }
    var rel = toRelativeUrl(raw);
    var key = routeKeyForUrl(rel);
    var route = key ? (ROUTES[key] || {}) : {};
    nativeWindowApi.open({
      key: key || ('nw-tab-' + (++winSeq)),
      title: key ? defaultTitle(key) : rel,
      url: rel,
      width: route.width || 980,
      height: route.height || 700
    });
    return {};
  };

  /* -------- 主页/编辑器所有功能入口统一走「独立 OS 子窗口」--------
     不经过 nw-core.js 的 openRoute：它先试 window.open，失败就退回
     location.href 整页跳转（这正是「点 SOLO 当前页变成 SOLO」的根因）。
     Windows 版每个功能都是独立 BrowserWindow，这里等价实现：无论任何
     情况都弹真实子窗口，绝不改变当前页。home.js 调用 NW.openRoute，
     故覆盖本方法即可拦截主页 SOLO / 编辑器 / 扩展 / 图片 / 设置等全部入口。 */
  function openRouteAsWindow (key, options) {
    var route = ROUTES[key];
    if (!route) return null;
    var merged = Object.assign({}, route, options || {});
    var rel = toRelativeUrl(merged.url || route.url);
    var keyForWin = key || routeKeyForUrl(rel) || ('nw-route-' + (++winSeq));
    var handle = nativeWindowApi.open({
      key: keyForWin,
      title: merged.title || defaultTitle(key),
      url: rel,
      width: merged.width || 980,
      height: merged.height || 700
    });
    return { key: keyForWin, newTab: true, tab: {}, window: handle };
  }
  NW.openRoute = openRouteAsWindow;
  global.NWOpenRoute = openRouteAsWindow;
  if (NW.host) {
    NW.host.register('desktop', {
      openWindow: function (k, o) { return !!openRouteAsWindow(k, o); },
      openDesktopSettings: function () { return !!openRouteAsWindow('desktop-settings'); },
      openExtensionEditor: function () { return !!openRouteAsWindow('extension-editor'); },
      openImageEditor: function () { return !!openRouteAsWindow('image-editor'); },
      openAI: function () { return !!openRouteAsWindow('ai-assistant'); },
      openEditor: function () { return !!openRouteAsWindow('editor'); }
    });
  }

  /** 子窗口页面从 fragment 里取自己的 key，便于 window.close() 精确关闭 */
  function currentWindowKey () {
    try {
      var m = global.location.hash.match(/nwwin=([^&]+)/);
      return m ? decodeURIComponent(m[1]) : '';
    } catch (e) { return ''; }
  }

  global.close = function () {
    var key = currentWindowKey();
    if (key) invoke('window', 'close', { key: key }).catch(function () {});
  };

  /* --------------- 跨窗口 RPC：把 BroadcastChannel 镜像到原生总线 --------------- */
  /* 各子窗口是独立 ArkWeb 实例，BroadcastChannel 不互通；由 ArkTS 转发，
     等价 Windows 版主进程在多个 BrowserWindow 之间代理 IPC。 */
  function installBus () {
    var rpc = NW.rpc;
    if (!rpc || typeof rpc.initChannel !== 'function') return;
    var ch = rpc.initChannel();
    if (!ch || typeof ch.postMessage !== 'function' || ch.__nwMirrored) return;
    var origPost = ch.postMessage.bind(ch);
    ch.postMessage = function (data) {
      var result = origPost(data);
      invoke('bus', 'publish', { data: JSON.stringify(data) }).catch(function () {});
      return result;
    };
    ch.__nwMirrored = true;
  }

  /** 原生转发过来的消息，重新喂回 10-rpc.js / 30-host.js 的通道监听器 */
  function onBusMessage (data) {
    var rpc = NW.rpc;
    if (!rpc || typeof rpc.initChannel !== 'function') return;
    var ch = rpc.initChannel();
    if (!ch || typeof ch.dispatchEvent !== 'function') return;
    try {
      ch.dispatchEvent(new MessageEvent('message', { data: data }));
    } catch (e) { /* 消息格式异常时忽略 */ }
  }

  /** 原生广播的窗口存在性变化，所有窗口据此保持一致 */
  function onWindowState (key, exists) {
    if (exists) {
      windowStates[key] = true;
    } else {
      delete windowStates[key];
      delete handles[key];
    }
  }

  function onWindowClosed (key) {
    onWindowState(key, false);
  }

  /* ------------------------------ 对外接口 ------------------------------ */
  global.NWHarmony = {
    available: true,
    invoke: invoke,
    profile: function () { return currentProfile; },
    taskStats: function () { return cachedTaskStats; },
    onBusMessage: onBusMessage,
    onWindowClosed: onWindowClosed,
    onWindowState: onWindowState,
    openWindow: function (key, options) { return nativeWindowApi.open(options || key); },
    // VM 侧调用：把角色统计推给 ArkTS task-manager 面板
    reportSpriteStats: function (sprites) {
      cachedTaskStats.sprites = sprites || [];
      if (typeof global.CustomEvent === 'function') {
        global.dispatchEvent(new CustomEvent('neowarp:spriteStats', { detail: sprites }));
      }
    }
  };

  installBus();

  /* 主页 GitHub 等外链是 <a href target="_blank">，不会走 window.open。
     ArkWeb 无 INTERNET 权限，直接点击会失败；这里拦截受信任外链，
     交给系统浏览器打开（等价于桌面版 shell.openExternal）。 */
  if (global.document && global.document.addEventListener) {
    global.document.addEventListener('click', function (event) {
      var node = event.target;
      // 向上找最近的 <a>
      while (node && node.tagName && String(node.tagName).toLowerCase() !== 'a') {
        node = node.parentNode;
      }
      if (!node || !node.href) return;
      var href = String(node.href);
      if (!TRUSTED_EXTERNAL.test(href)) return;
      if (event.preventDefault) event.preventDefault();
      openExternal(href);
    }, true);
  }

  // 通知 ArkTS：Web 运行时已就绪，可以开始推送设备形态与采样数据
  if (global.document && global.document.readyState !== 'loading') {
    invoke('perf', 'notifyVisibility', { visible: true }).catch(function () { /* no-op */ });
  } else {
    global.addEventListener('DOMContentLoaded', function () {
      invoke('perf', 'notifyVisibility', { visible: true }).catch(function () { /* no-op */ });
    });
  }
})(window);
