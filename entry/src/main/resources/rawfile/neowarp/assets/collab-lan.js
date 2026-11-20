/* NeoWarp for HarmonyOS —— 局域网协作适配层
 *
 * 把 editor.js 里基于公网 MQTT/WebRTC 的 collab 对象网络层，替换为
 * 复刻桌面版的内置信令服务器协议（经 ArkTS 的 collab.* RPC）。
 *
 * 保留 editor.js 的 collab 对象、state、roster、callbacks 与 GUI 契约不变，
 * 只覆盖"建连 / 收发 / 项目同步"相关方法：
 *   openHost / joinRoom / deliverProjectJSON / sendProjectUpdate / end / leave
 * 并订阅原生推送的 collab 事件驱动 roster / chat / project-update。
 *
 * 这样 GUI 层（onCollab* 回调、sendCollab* 方法）零改动即可与 Windows 桌面版互通。
 */
(function (global) {
  'use strict';

  var NW = global.NW || (global.NW = {});
  var util = NW.util || {};

  function invoke(method, args) {
    // 原生 collab 服务是全局单例（NativeServices），任一窗口调用都操作同一实例。
    // 直接走 HarmonyNative.invoke，绕开跨窗口 RPC 发现，最可靠。
    var nat = global.HarmonyNative;
    if (nat && typeof nat.invoke === 'function') {
      // 注入可能稍晚：最多等待约 2 秒
      return new Promise(function (resolve, reject) {
        var tries = 0;
        function attempt() {
          var n = global.HarmonyNative;
          if (n && typeof n.invoke === 'function') {
            Promise.resolve(n.invoke('collab', method, JSON.stringify(args || {}))).then(function (text) {
              var env;
              try { env = JSON.parse(text); } catch (e) { reject(new Error('非法桥响应')); return; }
              if (!env || !env.ok) { reject(new Error('[' + (env && env.code) + '] ' + (env && env.message))); return; }
              if (!env.data) { resolve(null); return; }
              try { resolve(JSON.parse(env.data)); } catch (e) { resolve(env.data); }
            }, reject);
          } else if (++tries > 100) {
            reject(new Error('HarmonyNative unavailable'));
          } else {
            setTimeout(attempt, 20);
          }
        }
        attempt();
      });
    }
    return Promise.resolve(null);
  }

  /* ---------------- collabNative：collab.* RPC 封装 ---------------- */
  var native = {
    available: function () {
      return !!(global.HarmonyNative && typeof global.HarmonyNative.invoke === 'function');
    },
    startHost: function (opts) { return invoke('startHost', opts); },
    endHost: function () { return invoke('endHost', {}); },
    getInfo: function () { return invoke('getInfo', {}); },
    getMembers: function () { return invoke('getMembers', {}); },
    getLocalIP: function () { return invoke('getLocalIP', {}); },
    pushProject: function (project, target) { return invoke('pushProject', { project: project, target: target || '' }); },
    sendChat: function (text) { return invoke('sendChat', { text: text }); },
    join: function (opts) { return invoke('join', opts); },
    leave: function () { return invoke('leave', {}); },
    sendProject: function (project) { return invoke('sendProject', { project: project }); },
    isRunning: function () { return invoke('isRunning', {}); }
  };
  NW.collabNative = native;

  /* ---------------- 覆盖 editor.js 的 collab 网络层 ---------------- */
  var collab = NW.collab;
  if (!collab) {
    // editor 尚未加载（如主页）：仅提供 native，待协作子窗口加载 editor 后再接管
    return;
  }

  // 统一的"收到服务器消息"处理：驱动 roster / chat / project
  function handleServerMessage(msg) {
    if (!msg || typeof msg !== 'object') return;
    switch (msg.type) {
      case 'auth-result':
        if (msg.success === false) {
          util.toast && util.toast('协作加入失败：' + (msg.error || '未知错误'));
          return;
        }
        collab.roster = msg.members || collab.roster;
        collab.state = {
          isCollaborating: true,
          role: 'participant',
          onlineCount: msg.onlineCount || collab.roster.length,
          permissions: msg.permissions || collab.defaultPermissions
        };
        pushState();
        // 请求房主推送当前项目
        invoke('sendChat', { text: '' }).catch(function () {}); // 保活
        break;
      case 'member-joined':
        collab.roster = msg.members || collab.roster;
        collab.state.onlineCount = msg.onlineCount || collab.roster.length;
        pushState();
        util.toast && util.toast('「' + (msg.username || '协作者') + '」加入了协作');
        break;
      case 'member-left':
        collab.roster = msg.members || collab.roster;
        collab.state.onlineCount = msg.onlineCount || collab.roster.length;
        pushState();
        break;
      case 'chat':
        dispatchCallbacks('collaborationChatMessage', msg);
        break;
      case 'project-update':
        // 项目载入由 editor.js 的 LAN 桥统一处理（applyIncomingProject），此处不重复
        break;
      case 'collaboration-ended':
        util.toast && util.toast('房主已结束协作');
        dispatchCallbacks('collaborationEnded', {});
        resetState();
        break;
      default:
        break;
    }
  }

  function pushState() {
    dispatchCallbacks('collaborationStateChange', Object.assign({}, collab.state));
  }

  function dispatchCallbacks(name, payload) {
    var list = (NW.editorCallbacks && NW.editorCallbacks[name]) || null;
    if (list && list.slice) {
      list.slice().forEach(function (cb) { try { cb(payload); } catch (e) { void e; } });
      return;
    }
    // 兼容 editor.js 暴露的 NW.editor.<onXxx> 注册（回调存于闭包，走 rpc）
    if (NW.rpc && NW.rpc.emit) NW.rpc.emit('collab', name, payload);
  }

  function resetState() {
    collab.mode = null;
    collab.host = null;
    collab.session = null;
    collab.roster = [];
    collab.state = { isCollaborating: false, role: null, onlineCount: 0, permissions: null };
    pushState();
  }

  /* host：开房间 */
  collab.openHost = function (options) {
    var self = this;
    if (this.mode) { util.toast && util.toast('已处于协作会话中'); return Promise.resolve(false); }
    if (!native.available()) { util.toast && util.toast('当前设备不支持协作'); return Promise.resolve(false); }
    var nickname = (options && options.nickname) || this.nickname || '主机';
    return native.startHost({
      password: (options && options.password) || '',
      port: (options && options.port) || 8080,
      permissions: JSON.stringify(this.defaultPermissions || {}),
      hostName: nickname,
      hostAvatar: this.avatar || '🏠'
    }).then(function (result) {
      if (!result || result.ok === false) { util.toast && util.toast('创建房间失败'); return false; }
      self.mode = 'host';
      self.nickname = nickname;
      self.room = result.id;
      self.roster = [{ name: nickname, avatar: self.avatar || '🏠', role: 'host' }];
      self.state = {
        isCollaborating: true, role: 'host', onlineCount: 1,
        permissions: Object.assign({}, self.defaultPermissions || {})
      };
      pushState();
      return { info: result, host: true };
    });
  };

  /* join：加入房间 */
  collab.joinRoom = function (ip, port, nickname, password) {
    var self = this;
    if (this.mode) { util.toast && util.toast('已处于协作会话中'); return Promise.resolve(false); }
    if (!native.available()) { util.toast && util.toast('当前设备不支持协作'); return Promise.resolve(false); }
    return native.join({
      ip: ip, port: port || 8080, password: password || '',
      nickname: nickname || this.nickname || '协作者', avatar: this.avatar || '🙂'
    }).then(function (result) {
      if (!result || result.joined !== true) { util.toast && util.toast('连接主机失败'); return false; }
      self.mode = 'participant';
      self.nickname = nickname || '协作者';
      self.state = {
        isCollaborating: true, role: 'participant', onlineCount: 2,
        permissions: Object.assign({}, self.defaultPermissions || {})
      };
      pushState();
      return true;
    });
  };

  /* openJoin：兼容旧调用（弹房间输入由协作窗口负责，这里直接返回） */
  collab.openJoin = function () {
    return Promise.resolve(true);
  };

  /* 主机导出项目 → 推给对端 */
  collab.deliverProjectJSON = function (json, target) {
    if (this.mode !== 'host') return;
    var str = typeof json === 'string' ? json : JSON.stringify(json);
    native.pushProject(str, target || '');
  };

  /* 参与者本地改动 → 回传主机 */
  collab.sendProjectUpdate = function (json) {
    if (this.mode !== 'participant') return;
    var str = typeof json === 'string' ? json : JSON.stringify(json);
    native.sendProject(str);
  };

  /* 发送聊天 */
  collab.sendChat = function (text) {
    native.sendChat(text);
  };

  collab.end = function () {
    native.endHost();
    util.toast && util.toast('协作已结束');
    resetState();
  };

  collab.leave = function () {
    native.leave();
    resetState();
  };

  collab.getLocalIP = function () { return native.getLocalIP(); };
  collab.getInfo = function () { return native.getInfo(); };

  NW.collabLANReady = true;

  /* ---------------- 订阅原生协作事件 ---------------- */
  function installEventBridge() {
    if (!NW.rpc || typeof NW.rpc.on !== 'function') return;
    NW.rpc.on('collab', 'server-message', function (msg) { handleServerMessage(msg); });
    NW.rpc.on('collab', 'member-joined', function (d) { handleServerMessage({ type: 'member-joined', username: d.username }); });
    NW.rpc.on('collab', 'member-left', function (d) { handleServerMessage({ type: 'member-left', username: d.username }); });
    NW.rpc.on('collab', 'chat', function (d) { handleServerMessage({ type: 'chat', from: d.from, text: d.text, isSelf: d.isSelf }); });
    NW.rpc.on('collab', 'project-request', function (d) {
      // 房主收到请求 → 触发 GUI 导出当前项目
      dispatchCallbacks('collabRequestProjectJSON', { targetUsername: d.username });
    });
    NW.rpc.on('collab', 'project-update', function (d) { handleServerMessage({ type: 'project-update', project: d.project }); });
    NW.rpc.on('collab', 'left', function (d) {
      util.toast && util.toast('协作连接已断开：' + (d.reason || '未知'));
      dispatchCallbacks('collaborationEnded', {});
      resetState();
    });
  }
  installEventBridge();

})(typeof window !== 'undefined' ? window : globalThis);
