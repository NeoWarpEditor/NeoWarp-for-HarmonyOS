/* ==========================================================================
 * NeoWarp HarmonyOS 桥接层（Web 侧）
 *
 * 加载顺序：nw-core.js → shims/*.js → harmony-bridge.js（必须最后）
 *
 * 职责：
 *  1) 把 ArkTS 原生能力注册进既有 NW.host 服务总线（web/src/core/30-host.js），
 *     使所有 shim 无需改动即可调用鸿蒙原生能力；
 *  2) polyfill File System Access API → ArkTS 文件桥（ArkWeb 不支持该 API）；
 *  3) 禁用 Service Worker 与外部网络请求（离线强保证的渲染层兜底）；
 *  4) 接收设备形态 / 主题 / 动作 / task-manager 事件；
 *  5) 把 VM 角色统计回传给 ArkTS 侧 task-manager 面板。
 * ========================================================================== */
(function (global) {
  'use strict';

  var NW = global.NW || (global.NW = {});
  var host = global.NWHost || NW.host;
  var rpc = NW.rpc;
  var native = global.HarmonyNative;

  var cachedTaskStats = { system: null, sprites: [] };
  var currentProfile = null;
  var OFFLINE_MESSAGE = '[NeoWarp HarmonyOS] 离线模式：网络请求已被阻止';

  if (!native || typeof native.invoke !== 'function') {
    // 非鸿蒙环境（普通浏览器预览）下保持网页版原有行为，不破坏功能
    global.NWHarmony = { available: false, invoke: function () { return Promise.reject(new Error('HarmonyNative unavailable')); } };
    return;
  }

  /* ------------------------------- 调用封装 ------------------------------- */
  function invoke (ns, method, args) {
    var payload = JSON.stringify(args || {});
    return Promise.resolve(native.invoke(ns, method, payload)).then(function (text) {
      var envelope;
      try { envelope = JSON.parse(text); } catch (e) { throw new Error('桥返回非法 JSON: ' + text); }
      if (!envelope || !envelope.ok) {
        throw new Error('[' + (envelope && envelope.code) + '] ' + (envelope && envelope.message));
      }
      if (!envelope.data) return null;
      try { return JSON.parse(envelope.data); } catch (e) { return envelope.data; }
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
          if (!s) return { cpuPercent: 0, ramUsedMB: 0, usedMemory: 0, totalMemory: 0 };
          var stats = s.system || s;
          return {
            cpuPercent: stats.cpuPercent,
            ramUsedMB: stats.memoryUsedMB,
            usedMemory: stats.memoryUsedMB * 1024 * 1024,
            totalMemory: stats.memoryTotalMB * 1024 * 1024,
            coreCount: stats.coreCount,
            threadCount: stats.threadCount
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
      getMemoryInfo: function () { return invoke('system', 'getMemoryInfo', {}); }
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

    rpc.on('native', 'action', function (payload) {
      if (payload && payload.id) handleAction(payload.id);
    });
    rpc.on('native', 'menu', function (payload) {
      if (payload && payload.id) handleAction(payload.id);
    });
    rpc.on('native', 'window_open', function (payload) {
      if (payload && payload.id) handleWindowOpen(payload.id);
    });
    rpc.on('native', 'openUri', function (payload) {
      if (payload && payload.uri && typeof global.CustomEvent === 'function') {
        global.dispatchEvent(new CustomEvent('neowarp:openUri', { detail: payload }));
      }
    });
  }

  var ACTION_WINDOW = {
    new: 'home', open: 'home', save: 'editor', packager: 'packager',
    settings: 'desktop-settings', addons: 'addons',
    task_manager: 'task-manager', menu_file: 'home', menu_view: 'editor'
  };

  function handleAction (id) {
    if (typeof global.CustomEvent === 'function') {
      global.dispatchEvent(new CustomEvent('neowarp:action', { detail: { id: id } }));
    }
    var key = ACTION_WINDOW[id];
    if (key) handleWindowOpen(key);
  }

  function handleWindowOpen (key) {
    // 优先使用网页版自带的页内浮层窗口管理器；不可用时回落到 iframe 浮层
    if (global.NWWindow && typeof global.NWWindow.open === 'function') {
      try { global.NWWindow.open(key); return; } catch (e) { /* 回落 */ }
    }
    openFallback(key);
  }

  function openFallback (key) {
    var doc = global.document;
    if (!doc || !doc.body) return;
    var id = 'nw-harmony-window';
    var frame = doc.getElementById(id);
    if (!frame) {
      frame = doc.createElement('iframe');
      frame.id = id;
      frame.style.cssText = 'position:fixed;right:16px;bottom:16px;width:420px;height:520px;' +
        'border:1px solid rgba(255,255,255,.14);border-radius:14px;z-index:99999;' +
        'background:#1c1e24;box-shadow:0 18px 60px rgba(0,0,0,.45)';
      doc.body.appendChild(frame);
    }
    frame.src = '../' + key + '/index.html';
  }

  /* ------------------------------ 对外接口 ------------------------------ */
  global.NWHarmony = {
    available: true,
    invoke: invoke,
    profile: function () { return currentProfile; },
    taskStats: function () { return cachedTaskStats; },
    // VM 侧调用：把角色统计推给 ArkTS task-manager 面板
    reportSpriteStats: function (sprites) {
      cachedTaskStats.sprites = sprites || [];
      if (typeof global.CustomEvent === 'function') {
        global.dispatchEvent(new CustomEvent('neowarp:spriteStats', { detail: sprites }));
      }
    }
  };

  // 通知 ArkTS：Web 运行时已就绪，可以开始推送设备形态与采样数据
  if (global.document && global.document.readyState !== 'loading') {
    invoke('perf', 'notifyVisibility', { visible: true }).catch(function () { /* no-op */ });
  } else {
    global.addEventListener('DOMContentLoaded', function () {
      invoke('perf', 'notifyVisibility', { visible: true }).catch(function () { /* no-op */ });
    });
  }
})(window);
