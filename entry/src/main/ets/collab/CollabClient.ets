/**
 * CollabClient —— HarmonyOS 版协作「加入者」网络客户端
 *
 * 连到 Windows 桌面版内置信令服务器（collaboration-server.js）：
 *   TCP 升级 WebSocket（客户端帧必须 mask）→ 发 auth → 收发 JSON 消息。
 * 网络逻辑全在 ArkTS，Web 层只通过 collab.* RPC 驱动。
 */
import { socket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const MAGIC_STRING: string = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const OPCODE_TEXT: number = 0x1;
const OPCODE_PING: number = 0x9;
const OPCODE_PONG: number = 0xA;
const MAX_BUFFER: number = 64 * 1024 * 1024;

export interface CollabJoinOptions {
  ip: string;
  port: number;
  password: string;
  nickname: string;
  avatar: string;
}

export interface CollabClientCallbacks {
  onConnected: (msg: string) => void;
  onMessage: (msg: string) => void;
  onDisconnected: (reason: string) => void;
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

function wsAccept(key: string): string {
  const md = cryptoFramework.createMd('SHA1');
  md.updateSync({ data: textEncode(key + MAGIC_STRING) });
  return new util.Base64Helper().encodeToStringSync(md.digestSync().data);
}

function parseFrame(buf: number[]): ParsedFrame | null {
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

export class CollabClient {
  private sock: socket.TCPSocket | null = null;
  private opts: CollabJoinOptions | null = null;
  private cb: CollabClientCallbacks | null = null;
  private buffer: number[] = [];
  private handshakeDone: boolean = false;
  private connected: boolean = false;
  private pingTimer: number = -1;
  private lastSeen: number = 0;
  private expectedAccept: string = '';

  async join(opts: CollabJoinOptions, cb: CollabClientCallbacks): Promise<boolean> {
    if (this.connected) return false;
    this.opts = opts;
    this.cb = cb;
    this.buffer = [];
    this.handshakeDone = false;
    this.sock = socket.constructTCPSocketInstance();
    this.bindEvents(this.sock);
    const addr: socket.NetAddress = { address: opts.ip, port: opts.port };
    const connectOpts: socket.TCPConnectOptions = { address: addr };
    try {
      await this.sock.connect(connectOpts);
      const keyBytes = new Uint8Array(16);
      for (let i = 0; i < 16; i++) keyBytes[i] = Math.floor(Math.random() * 256);
      const key: string = new util.Base64Helper().encodeToStringSync(keyBytes);
      this.expectedAccept = wsAccept(key);
      const req: string =
        'GET / HTTP/1.1\r\n' +
        'Host: ' + opts.ip + ':' + opts.port + '\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        'Sec-WebSocket-Key: ' + key + '\r\n' +
        'Sec-WebSocket-Version: 13\r\n\r\n';
      this.sendRaw(textEncode(req));
      this.startPing();
      return true;
    } catch (_e) {
      this.sock = null;
      return false;
    }
  }

  private bindEvents(s: socket.TCPSocket): void {
    s.on('message', (info: socket.SocketMessageInfo) => {
      this.onData(new Uint8Array(info.message));
    });
    s.on('close', () => { this.handleDisconnect('连接已关闭'); });
    s.on('error', (_e: BusinessError) => { this.handleDisconnect('连接错误'); });
  }

  private onData(chunk: Uint8Array): void {
    this.lastSeen = Date.now();
    for (let i = 0; i < chunk.length; i++) this.buffer.push(chunk[i]);
    if (!this.handshakeDone) {
      const head: string = textDecode(new Uint8Array(this.buffer));
      const sep: number = head.indexOf('\r\n\r\n');
      if (sep < 0) return;
      const headerPart: string = head.slice(0, sep);
      if (headerPart.indexOf('101') < 0) {
        this.handleDisconnect('服务器拒绝连接');
        return;
      }
      this.buffer.splice(0, sep + 4);
      this.handshakeDone = true;
      this.connected = true;
      const o: CollabJoinOptions = this.opts!;
      this.sendJson({ 'type': 'auth', 'password': o.password, 'nickname': o.nickname, 'avatar': o.avatar });
      if (this.cb !== null) this.cb.onConnected('{}');
    }
    if (this.buffer.length > MAX_BUFFER) { this.handleDisconnect('数据过大'); return; }
    this.drainFrames();
  }

  private drainFrames(): void {
    while (this.buffer.length >= 2) {
      const frame: ParsedFrame | null = parseFrame(this.buffer);
      if (frame === null) break;
      this.buffer.splice(0, frame.bytesRead);
      this.handleFrame(frame.opcode, frame.payload);
    }
  }

  private handleFrame(opcode: number, payload: number[]): void {
    if (opcode === OPCODE_TEXT) {
      const text: string = textDecode(new Uint8Array(payload));
      if (this.cb !== null) this.cb.onMessage(text);
    } else if (opcode === OPCODE_PING) {
      this.sendFrameRaw(OPCODE_PONG, payload);
    }
  }

  /** 回控制帧（服务器 PING 的 PONG），不 mask 由 sendFrame 统一处理 */
  private sendFrameRaw(opcode: number, payload: number[]): void {
    if (!this.connected) return;
    const mask: number[] = [];
    for (let i = 0; i < 4; i++) mask.push(Math.floor(Math.random() * 256));
    const header: number[] = [0x80 | opcode];
    const len: number = payload.length;
    if (len <= 125) header.push(0x80 | len);
    else header.push(0x80 | 126, (len >> 8) & 0xff, len & 0xff);
    const masked: number[] = [];
    for (let i = 0; i < payload.length; i++) masked.push(payload[i] ^ mask[i % 4]);
    const all: number[] = header.concat(mask).concat(masked);
    const out = new Uint8Array(all.length);
    for (let i = 0; i < all.length; i++) out[i] = all[i];
    this.sendRaw(out);
  }

  sendChat(text: string): void {
    this.sendJson({ 'type': 'chat', 'text': text });
  }

  sendProject(project: string): void {
    this.sendJson({ 'type': 'project-update', 'project': project });
  }

  ping(): void {
    this.sendJson({ 'type': 'ping' });
  }

  private sendJson(obj: Record<string, Object>): void {
    this.sendFrame(OPCODE_TEXT, Array.from(textEncode(JSON.stringify(obj))));
  }

  private sendFrame(opcode: number, payload: number[]): void {
    if (!this.connected) return;
    const mask: number[] = [];
    for (let i = 0; i < 4; i++) mask.push(Math.floor(Math.random() * 256));
    const header: number[] = [];
    header.push(0x80 | opcode);
    const len: number = payload.length;
    const maskedBit: number = 0x80;
    if (len <= 125) {
      header.push(maskedBit | len);
    } else if (len <= 65535) {
      header.push(maskedBit | 126, (len >> 8) & 0xff, len & 0xff);
    } else {
      header.push(maskedBit | 127, 0, 0, 0, 0, (len >>> 24) & 0xff, (len >>> 16) & 0xff, (len >>> 8) & 0xff, len & 0xff);
    }
    const masked: number[] = [];
    for (let i = 0; i < payload.length; i++) masked.push(payload[i] ^ mask[i % 4]);
    const all: number[] = header.concat(mask).concat(masked);
    const out = new Uint8Array(all.length);
    for (let i = 0; i < all.length; i++) out[i] = all[i];
    this.sendRaw(out);
  }

  private sendRaw(bytes: Uint8Array): void {
    if (this.sock === null) return;
    const options: socket.TCPSendOptions = { data: bytes };
    this.sock.send(options).catch(() => { /* 连接断开 */ });
  }

  private startPing(): void {
    this.stopPing();
    this.pingTimer = setInterval(() => {
      if (Date.now() - this.lastSeen > 65000) { this.handleDisconnect('连接超时'); return; }
      if (this.connected) this.ping();
    }, 30000);
  }

  private stopPing(): void {
    if (this.pingTimer >= 0) { clearInterval(this.pingTimer); this.pingTimer = -1; }
  }

  private handleDisconnect(reason: string): void {
    const wasConnected: boolean = this.connected;
    this.connected = false;
    this.handshakeDone = false;
    this.stopPing();
    if (this.sock !== null) { try { this.sock.close(); } catch (_e) { /* ignore */ } this.sock = null; }
    if (this.cb !== null) this.cb.onDisconnected(reason);
    void wasConnected;
  }

  isConnected(): boolean {
    return this.connected;
  }

  leave(): void {
    if (this.connected) this.sendJson({ 'type': 'bye' });
    this.stopPing();
    if (this.sock !== null) { try { this.sock.close(); } catch (_e) { /* ignore */ } this.sock = null; }
    this.connected = false;
    this.handshakeDone = false;
  }
}
