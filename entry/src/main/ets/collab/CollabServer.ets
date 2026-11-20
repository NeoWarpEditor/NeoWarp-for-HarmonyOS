/**
 * CollabServer —— HarmonyOS 版局域网协作信令服务器
 *
 * 复刻 NeoWarp 桌面版 src-main/collaboration-server.js 的线协议：
 *   - HTTP GET /discover  → 局域网房间发现
 *   - 手写 RFC6455 WebSocket（服务器侧不 mask，客户端 mask 需解 mask）
 *   - 消息：auth / auth-result / chat / project-update /
 *           member-joined / member-left / ping / pong / collaboration-ended
 *
 * 用 ArkTS socket.TCPSocketServer 实现，Windows 桌面版协作者可直接连本服务器。
 */
import { socket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const MAGIC_STRING: string = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const OPCODE_TEXT: number = 0x1;
const OPCODE_CLOSE: number = 0x8;
const OPCODE_PING: number = 0x9;
const OPCODE_PONG: number = 0xA;
const MAX_BUFFER: number = 64 * 1024 * 1024;

interface CollabClientInfo {
  id: number;
  conn: socket.TCPSocketConnection;
  username: string;
  avatar: string;
  authenticated: boolean;
  buffer: number[];
  closed: boolean;
  lastSeen: number;
}

export interface CollabStartOptions {
  password: string;
  port: number;
  permissions: string;
  hostName: string;
  hostAvatar: string;
}

export interface CollabCallbacks {
  onClientJoin: (username: string, avatar: string) => void;
  onClientLeave: (username: string) => void;
  onChatMessage: (msg: string) => void;
  onProjectRequest: (username: string) => void;
  onProjectUpdate: (msg: string) => void;
}

interface ParsedFrame {
  opcode: number;
  payload: number[];
  bytesRead: number;
}

function textEncode(s: string): Uint8Array {
  return new util.TextEncoder().encodeInto(s);
}

function textDecode(b: Uint8Array): string {
  return new util.TextDecoder().decodeToString(b);
}

function bytesToBase64(b: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(b);
}

function wsAccept(key: string): string {
  const md = cryptoFramework.createMd('SHA1');
  md.updateSync({ data: textEncode(key + MAGIC_STRING) });
  return bytesToBase64(md.digestSync().data);
}

/** 组装一个 WebSocket 帧为字节数组 */
function buildFrame(opcode: number, payload: number[]): Uint8Array {
  const header: number[] = [];
  header.push(0x80 | opcode);
  const len: number = payload.length;
  if (len <= 125) {
    header.push(len);
  } else if (len <= 65535) {
    header.push(126, (len >> 8) & 0xff, len & 0xff);
  } else {
    header.push(127, 0, 0, 0, 0, (len >>> 24) & 0xff, (len >>> 16) & 0xff, (len >>> 8) & 0xff, len & 0xff);
  }
  const all: number[] = header.concat(payload);
  const out = new Uint8Array(all.length);
  for (let i = 0; i < all.length; i++) out[i] = all[i];
  return out;
}

export class CollabServer {
  private server: socket.TCPSocketServer | null = null;
  private clients: Map<socket.TCPSocketConnection, CollabClientInfo> = new Map();
  private clientCounter: number = 0;
  private opts: CollabStartOptions | null = null;
  private callbacks: CollabCallbacks | null = null;
  private heartbeatTimer: number = -1;
  private roomId: string = '';
  private listening: boolean = false;

  async start(opts: CollabStartOptions, cb: CollabCallbacks): Promise<boolean> {
    if (this.listening) return false;
    this.opts = opts;
    this.callbacks = cb;
    this.roomId = util.generateRandomUUID(false);
    this.server = socket.constructTCPSocketServerInstance();
    this.bindServerEvents(this.server);
    const addr: socket.NetAddress = { address: '0.0.0.0', port: opts.port };
    try {
      await this.server.listen(addr);
      this.listening = true;
      this.startHeartbeat();
      return true;
    } catch (_e) {
      this.server = null;
      return false;
    }
  }

  private bindServerEvents(srv: socket.TCPSocketServer): void {
    srv.on('connect', (conn: socket.TCPSocketConnection) => {
      const client: CollabClientInfo = {
        id: ++this.clientCounter, conn: conn, username: '', avatar: '',
        authenticated: false, buffer: [], closed: false, lastSeen: Date.now()
      };
      this.bindClientEvents(client);
    });
    srv.on('error', (_e: BusinessError) => { /* listen promise 捕获错误 */ });
  }

  private bindClientEvents(client: CollabClientInfo): void {
    client.conn.on('message', (info: socket.SocketMessageInfo) => {
      this.onData(client, new Uint8Array(info.message));
    });
    client.conn.on('close', () => { this.handleClose(client); });
    client.conn.on('error', () => { this.handleClose(client); });
  }

  private onData(client: CollabClientInfo, chunk: Uint8Array): void {
    client.lastSeen = Date.now();
    if (!client.authenticated && client.buffer.length === 0) {
      for (let i = 0; i < chunk.length; i++) client.buffer.push(chunk[i]);
      const head: string = textDecode(new Uint8Array(client.buffer));
      const sep: number = head.indexOf('\r\n\r\n');
      if (sep < 0) {
        if (client.buffer.length > 64 * 1024) this.dropClient(client);
        return;
      }
      const requestLine: string = head.split('\r\n')[0];
      client.buffer = [];
      if (requestLine.indexOf('/discover') >= 0) {
        this.replyDiscover(client);
        return;
      }
      if (requestLine.indexOf('GET / ') < 0 && requestLine.indexOf('GET /?') < 0) {
        this.dropClient(client);
        return;
      }
      const key: string = this.headerValue(head, 'sec-websocket-key');
      const version: string = this.headerValue(head, 'sec-websocket-version');
      if (key.length === 0 || version !== '13') {
        this.dropClient(client);
        return;
      }
      const response: string =
        'HTTP/1.1 101 Switching Protocols\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        'Sec-WebSocket-Accept: ' + wsAccept(key) + '\r\n\r\n';
      this.sendRaw(client, textEncode(response));
      return;
    }
    for (let i = 0; i < chunk.length; i++) client.buffer.push(chunk[i]);
    if (client.buffer.length > MAX_BUFFER) { this.dropClient(client); return; }
    this.drainFrames(client);
  }

  private headerValue(head: string, name: string): string {
    const lines: string[] = head.split('\r\n');
    for (const line of lines) {
      const idx: number = line.indexOf(':');
      if (idx > 0 && line.slice(0, idx).trim().toLowerCase() === name) {
        return line.slice(idx + 1).trim();
      }
    }
    return '';
  }

  private replyDiscover(client: CollabClientInfo): void {
    const o: CollabStartOptions = this.opts!;
    const info: Record<string, Object> = {
      'ok': true, 'id': this.roomId,
      'roomName': o.hostName + ' 的协作', 'hostName': o.hostName, 'hostAvatar': o.hostAvatar,
      'onlineCount': this.getTotalOnlineCount(), 'port': o.port
    };
    const body: string = JSON.stringify(info);
    const resp: string =
      'HTTP/1.1 200 OK\r\n' +
      'Content-Type: application/json; charset=utf-8\r\n' +
      'Access-Control-Allow-Origin: *\r\n' +
      'Content-Length: ' + textEncode(body).length + '\r\n' +
      'Connection: close\r\n\r\n' + body;
    this.sendRaw(client, textEncode(resp));
    setTimeout(() => { this.dropClient(client); }, 50);
  }

  private drainFrames(client: CollabClientInfo): void {
    while (client.buffer.length >= 2) {
      const frame: ParsedFrame | null = this.parseFrame(client.buffer);
      if (frame === null) break;
      client.buffer.splice(0, frame.bytesRead);
      this.handleFrame(client, frame.opcode, frame.payload);
    }
  }

  private parseFrame(buf: number[]): ParsedFrame | null {
    const b0: number = buf[0];
    const b1: number = buf[1];
    const opcode: number = b0 & 0x0f;
    const masked: boolean = (b1 & 0x80) !== 0;
    let len: number = b1 & 0x7f;
    let offset: number = 2;
    if (len === 126) {
      if (buf.length < 4) return null;
      len = (buf[2] << 8) | buf[3];
      offset = 4;
    } else if (len === 127) {
      if (buf.length < 10) return null;
      len = 0;
      for (let i = 2; i < 10; i++) len = len * 256 + buf[i];
      offset = 10;
    }
    let mask: number[] = [];
    if (masked) {
      if (buf.length < offset + 4) return null;
      mask = buf.slice(offset, offset + 4);
      offset += 4;
    }
    if (buf.length < offset + len) return null;
    const payload: number[] = buf.slice(offset, offset + len);
    if (masked) {
      for (let i = 0; i < payload.length; i++) payload[i] = payload[i] ^ mask[i % 4];
    }
    const result: ParsedFrame = { opcode: opcode, payload: payload, bytesRead: offset + len };
    return result;
  }

  private handleFrame(client: CollabClientInfo, opcode: number, payload: number[]): void {
    if (opcode === OPCODE_CLOSE) { this.handleClose(client); return; }
    if (opcode === OPCODE_PING) { this.sendFrame(client, OPCODE_PONG, payload); return; }
    if (opcode === OPCODE_PONG) { client.lastSeen = Date.now(); return; }
    if (opcode === OPCODE_TEXT) {
      this.handleMessage(client, textDecode(new Uint8Array(payload)));
    }
  }

  private handleMessage(client: CollabClientInfo, text: string): void {
    let msg: Record<string, Object>;
    try { msg = JSON.parse(text) as Record<string, Object>; } catch (_e) { return; }
    const type: string = String(msg['type'] || '');

    if (type === 'ping') {
      client.lastSeen = Date.now();
      this.sendJson(client, { 'type': 'pong', 'onlineCount': this.getTotalOnlineCount() });
      return;
    }
    if (type === 'auth') {
      const given: string = String(msg['password'] == null ? '' : msg['password']);
      const expected: string = this.opts ? this.opts.password : '';
      if (given === expected) {
        client.authenticated = true;
        client.username = this.uniqueUsername(String(msg['nickname'] || '').trim() || ('用户-' + Math.floor(1000 + Math.random() * 9000)));
        client.avatar = String(msg['avatar'] || '').trim() || '👤';
        this.sendJson(client, {
          'type': 'auth-result', 'success': true,
          'permissions': this.opts ? this.opts.permissions : '',
          'username': client.username, 'avatar': client.avatar,
          'onlineCount': this.getTotalOnlineCount(),
          'hostName': this.opts ? this.opts.hostName : '',
          'hostAvatar': this.opts ? this.opts.hostAvatar : '',
          'members': this.getRoster()
        });
        this.broadcastExcept(client, {
          'type': 'member-joined', 'username': client.username, 'avatar': client.avatar,
          'onlineCount': this.getTotalOnlineCount(), 'members': this.getRoster()
        });
        if (this.callbacks !== null) {
          this.callbacks.onClientJoin(client.username, client.avatar);
          this.callbacks.onProjectRequest(client.username);
        }
      } else {
        this.sendJson(client, { 'type': 'auth-result', 'success': false, 'error': '密码错误', 'permissions': '', 'username': '' });
      }
      return;
    }
    if (!client.authenticated) return;
    if (type === 'chat') {
      const data: Record<string, Object> = {
        'type': 'chat', 'from': client.username, 'avatar': client.avatar,
        'text': String(msg['text'] || ''), 'timestamp': Date.now()
      };
      const others: Record<string, Object> = {};
      others['type'] = 'chat'; others['from'] = client.username; others['avatar'] = client.avatar;
      others['text'] = String(msg['text'] || ''); others['timestamp'] = Date.now(); others['isSelf'] = false;
      this.broadcastExcept(client, others);
      const self: Record<string, Object> = {};
      self['type'] = 'chat'; self['from'] = client.username; self['avatar'] = client.avatar;
      self['text'] = String(msg['text'] || ''); self['timestamp'] = Date.now(); self['isSelf'] = true;
      this.sendJson(client, self);
      if (this.callbacks !== null) this.callbacks.onChatMessage(JSON.stringify(others));
      return;
    }
    if (type === 'project-update') {
      const data: Record<string, Object> = {
        'type': 'project-update', 'project': msg['project'], 'from': client.username
      };
      this.broadcastExcept(client, data);
      if (this.callbacks !== null) this.callbacks.onProjectUpdate(JSON.stringify(data));
      return;
    }
  }

  private getRoster(): Record<string, Object>[] {
    const roster: Record<string, Object>[] = [{
      'name': this.opts ? this.opts.hostName : '主机',
      'avatar': this.opts ? this.opts.hostAvatar : '🏠', 'role': 'host'
    }];
    for (const c of this.clients.values()) {
      if (!c.authenticated) continue;
      const member: Record<string, Object> = { 'name': c.username, 'avatar': c.avatar, 'role': 'participant' };
      roster.push(member);
    }
    return roster;
  }

  private getTotalOnlineCount(): number {
    return this.getOnlineCount() + 1;
  }

  private getOnlineCount(): number {
    let n: number = 0;
    for (const c of this.clients.values()) if (c.authenticated) n++;
    return n;
  }

  private uniqueUsername(base: string): string {
    const taken: Map<string, boolean> = new Map();
    for (const c of this.clients.values()) if (c.authenticated && c.username.length > 0) taken.set(c.username, true);
    if (!taken.has(base)) return base;
    let i: number = 2;
    while (taken.has(base + '-' + i)) i++;
    return base + '-' + i;
  }

  broadcastProject(projectJson: string, targetUsername: string): void {
    const data: Record<string, Object> = { 'type': 'project-update', 'project': projectJson };
    for (const c of this.clients.values()) {
      if (!c.authenticated) continue;
      if (targetUsername.length > 0 && c.username !== targetUsername) continue;
      this.sendJson(c, data);
    }
  }

  broadcastChatFromHost(text: string): void {
    const data: Record<string, Object> = {
      'type': 'chat', 'from': this.opts ? this.opts.hostName : '主机',
      'avatar': this.opts ? this.opts.hostAvatar : '🏠',
      'text': text, 'timestamp': Date.now(), 'isSelf': false
    };
    this.broadcast(data);
  }

  private broadcast(msg: Record<string, Object>): void {
    for (const c of this.clients.values()) if (c.authenticated) this.sendJson(c, msg);
  }

  private broadcastExcept(except: CollabClientInfo, msg: Record<string, Object>): void {
    for (const c of this.clients.values()) {
      if (c === except || !c.authenticated) continue;
      this.sendJson(c, msg);
    }
  }

  private sendJson(client: CollabClientInfo, obj: Record<string, Object>): void {
    this.sendFrame(client, OPCODE_TEXT, Array.from(textEncode(JSON.stringify(obj))));
  }

  private sendFrame(client: CollabClientInfo, opcode: number, payload: number[]): void {
    this.sendRaw(client, buildFrame(opcode, payload));
  }

  private sendRaw(client: CollabClientInfo, bytes: Uint8Array): void {
    if (client.closed) return;
    const options: socket.TCPSendOptions = { data: bytes };
    client.conn.send(options).catch(() => { /* 连接已断开 */ });
  }

  private dropClient(client: CollabClientInfo): void {
    try { client.conn.close(); } catch (_e) { /* ignore */ }
  }

  private handleClose(client: CollabClientInfo): void {
    if (client.closed) return;
    client.closed = true;
    this.clients.delete(client.conn);
    if (client.authenticated) {
      this.broadcast({
        'type': 'member-left', 'username': client.username,
        'onlineCount': this.getTotalOnlineCount(), 'members': this.getRoster()
      });
      if (this.callbacks !== null) this.callbacks.onClientLeave(client.username);
    }
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      const now: number = Date.now();
      for (const c of Array.from(this.clients.values())) {
        if (c.closed) continue;
        if (now - c.lastSeen > 65000) {
          this.dropClient(c);
        } else {
          this.sendFrame(c, OPCODE_PING, []);
        }
      }
    }, 30000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer >= 0) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  getInfo(): Record<string, Object> {
    const o: CollabStartOptions = this.opts!;
    const info: Record<string, Object> = {
      'ok': true, 'id': this.roomId,
      'roomName': (o ? o.hostName : '主机') + ' 的协作',
      'hostName': o ? o.hostName : '', 'hostAvatar': o ? o.hostAvatar : '',
      'onlineCount': this.getTotalOnlineCount(), 'port': o ? o.port : 0
    };
    return info;
  }

  getMembers(): Record<string, Object>[] {
    return this.getRoster();
  }

  getOnlineCountTotal(): number {
    return this.getTotalOnlineCount();
  }

  isRunning(): boolean {
    return this.listening;
  }

  end(): void {
    this.stopHeartbeat();
    const endMsg: string = JSON.stringify({ 'type': 'collaboration-ended', 'reason': 'host-ended' });
    for (const c of Array.from(this.clients.values())) {
      this.sendFrame(c, OPCODE_TEXT, Array.from(textEncode(endMsg)));
      this.dropClient(c);
    }
    this.clients.clear();
    if (this.server !== null) {
      try { this.server.off('connect'); } catch (_e) { /* ignore */ }
      this.server = null;
    }
    this.listening = false;
  }
}
