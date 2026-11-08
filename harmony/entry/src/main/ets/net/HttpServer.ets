import { socket } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { InboxStore } from '../store/InboxStore';
import { FileItem, APP_VERSION } from '../model/Models';

export interface ParsedRequest {
  method: string;
  path: string;
  headers: Record<string, string>;
  contentLength: number;
}

/** 字节工具 */
export class Bytes {
  static concat(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  static ascii(src: Uint8Array, start: number, end: number): string {
    let s: string = '';
    for (let i = start; i < end; i++) {
      s += String.fromCharCode(src[i]);
    }
    return s;
  }

  static indexOfHeadEnd(buf: Uint8Array): number {
    for (let i = 0; i + 3 < buf.length; i++) {
      if (buf[i] === 13 && buf[i + 1] === 10 && buf[i + 2] === 13 && buf[i + 3] === 10) {
        return i;
      }
    }
    return -1;
  }

  static utf8(bytes: Uint8Array): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(bytes);
  }

  static encode(text: string): Uint8Array {
    const encoder: util.TextEncoder = new util.TextEncoder();
    return encoder.encodeInto(text);
  }
}

class HttpConn {
  client: socket.TCPSocketConnection;
  private buffer: Uint8Array = new Uint8Array(0);
  private request: ParsedRequest | null = null;
  private headEnd: number = 0;
  private handled: boolean = false;
  private closed: boolean = false;
  private onRequest: (conn: HttpConn, req: ParsedRequest, body: Uint8Array) => Promise<void>;

  constructor(client: socket.TCPSocketConnection,
              onRequest: (conn: HttpConn, req: ParsedRequest, body: Uint8Array) => Promise<void>) {
    this.client = client;
    this.onRequest = onRequest;
  }

  push(chunk: Uint8Array): void {
    if (this.closed) {
      return;
    }
    this.buffer = Bytes.concat(this.buffer, chunk);
    this.pump();
  }

  private pump(): void {
    if (this.handled) {
      return;
    }
    if (this.request === null) {
      const idx: number = Bytes.indexOfHeadEnd(this.buffer);
      if (idx < 0) {
        if (this.buffer.length > 128 * 1024) {
          this.fail(400, 'bad_request', '请求头过大');
        }
        return;
      }
      const headText: string = Bytes.ascii(this.buffer, 0, idx);
      this.request = HttpServer.parseHead(headText);
      this.headEnd = idx + 4;
      if (this.request === null) {
        this.fail(400, 'bad_request', '无法解析请求行');
        return;
      }
    }
    const req: ParsedRequest = this.request;
    const total: number = this.headEnd + req.contentLength;
    if (this.buffer.length < total) {
      return;
    }
    this.handled = true;
    const body: Uint8Array = this.buffer.slice(this.headEnd, total);
    this.onRequest(this, req, body).catch((e: Error) => {
      this.fail(500, 'internal', e.message);
    });
  }

  async write(data: Uint8Array | string): Promise<void> {
    if (this.closed) {
      return;
    }
    try {
      if (typeof data === 'string') {
        const textOpt: socket.TCPSendOptions = { data: data as string };
        await this.client.send(textOpt);
      } else {
        const arr: Uint8Array = data as Uint8Array;
        const copy: Uint8Array = arr.slice(0);
        const binOpt: socket.TCPSendOptions = { data: copy.buffer as ArrayBuffer };
        await this.client.send(binOpt);
      }
    } catch (e) {
      this.closed = true;
    }
  }

  async fail(status: number, code: string, message: string): Promise<void> {
    await this.respondJson(status, jsonError(code, message));
  }

  async respondJson(status: number, json: string): Promise<void> {
    const body: Uint8Array = Bytes.encode(json);
    const head: string = 'HTTP/1.1 ' + status.toString() + ' ' + HttpServer.reason(status) + '\r\n' +
      'Content-Type: application/json; charset=utf-8\r\n' +
      'Content-Length: ' + body.length.toString() + '\r\n' +
      'Access-Control-Allow-Origin: *\r\n' +
      'Access-Control-Allow-Headers: Content-Type, X-File-Name, X-File-Id, X-File-Size, X-Offset, X-Pin\r\n' +
      'Connection: close\r\n\r\n';
    await this.write(head);
    await this.write(body);
    this.close();
  }

  async respondHead(status: number, headers: string): Promise<void> {
    const head: string = 'HTTP/1.1 ' + status.toString() + ' ' + HttpServer.reason(status) + '\r\n' +
      headers + 'Connection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n';
    await this.write(head);
  }

  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    try {
      this.client.close();
    } catch (e) {
      // 已断开
    }
  }
}

export class HttpServer {
  private server: socket.TCPSocketServer | null = null;
  private store: InboxStore;
  private running: boolean = false;
  private listenPort: number = 0;
  private inboundConns: Map<string, HttpConn> = new Map<string, HttpConn>();
  private pin: string = '';
  private pinRequired: boolean = false;
  private pinFailures: number = 0;
  private pinLockedUntil: number = 0;
  private deviceId: string = '';
  private deviceName: string = '';
  private onReceive: (item: FileItem) => void = () => {};
  /** 接收进度：(fileId, name, 已收, 总) */
  onUploadProgress: (fileId: string, name: string, received: number, total: number) => void = () => {};
  /** 对端取消/断开 */
  onUploadAborted: (fileId: string) => void = () => {};

  constructor(store: InboxStore) {
    this.store = store;
  }

  setIdentity(id: string, name: string, pin: string, pinRequired: boolean): void {
    this.deviceId = id;
    this.deviceName = name;
    this.pin = pin;
    this.pinRequired = pinRequired;
  }

  setReceiveListener(listener: (item: FileItem) => void): void {
    this.onReceive = listener;
  }

  get isRunning(): boolean {
    return this.running;
  }

  async start(port: number): Promise<number> {
    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    const listenAddr: socket.NetAddress = { address: '0.0.0.0', port: port, family: 1 };
    await server.listen(listenAddr);
    server.on('connect', (client: socket.TCPSocketConnection) => {
      const conn: HttpConn = new HttpConn(client, (c: HttpConn, r: ParsedRequest, b: Uint8Array) => {
        return this.dispatch(c, r, b);
      });
      client.on('message', (info: socket.SocketMessageInfo) => {
        conn.push(new Uint8Array(info.message));
      });
      client.on('close', () => {
        conn.close();
      });
    });
    this.server = server;
    this.listenPort = port;
    this.running = true;
    return port;
  }

  /** 本地取消接收：直接关掉这条连接，发送端会立即收到断流 */
  cancelInbound(fileId: string): void {
    const conn: HttpConn | undefined = this.inboundConns.get(fileId);
    this.inboundConns.delete(fileId);
    if (conn !== undefined) {
      conn.close();
    }
  }

  /** 0 = 通过；401 = 配对码错误；429 = 连续错误后被临时锁定 */
  private checkPin(provided: string): number {
    const now: number = Date.now();
    if (now < this.pinLockedUntil) {
      return 429;
    }
    if (constantTimeEquals(provided, this.pin)) {
      this.pinFailures = 0;
      return 0;
    }
    this.pinFailures++;
    if (this.pinFailures >= 10) {
      this.pinLockedUntil = now + 60_000;
      this.pinFailures = 0;
    }
    return 401;
  }

  stop(): void {
    this.running = false;
    if (this.server !== null) {
      this.server.off('connect');
      try {
        this.server.close();
      } catch (e) {
        // 已关闭
      }
      this.server = null;
    }
  }

  // MARK: 解析

  static parseHead(text: string): ParsedRequest | null {
    const lines: string[] = text.split('\r\n');
    if (lines.length === 0) {
      return null;
    }
    const first: string[] = lines[0].split(' ');
    if (first.length < 2) {
      return null;
    }
    const headers: Record<string, string> = {};
    for (let i = 1; i < lines.length; i++) {
      const line: string = lines[i];
      const idx: number = line.indexOf(':');
      if (idx <= 0) {
        continue;
      }
      const key: string = line.substring(0, idx).trim().toLowerCase();
      headers[key] = line.substring(idx + 1).trim();
    }
    const rawLength: string = headers['content-length'] !== undefined ? headers['content-length'] : '0';
    const len: number = parseInt(rawLength, 10);
    return {
      method: first[0].toUpperCase(),
      path: first[1].split('?')[0],
      headers: headers,
      contentLength: isNaN(len) ? 0 : len
    };
  }

  // MARK: 路由

  private async dispatch(conn: HttpConn, req: ParsedRequest, body: Uint8Array): Promise<void> {
    if (req.method === 'OPTIONS') {
      await conn.respondHead(204, 'Content-Length: 0\r\n');
      conn.close();
      return;
    }

    if (req.path !== '/v1/info' && this.pinRequired) {
      const provided: string = req.headers['x-pin'] !== undefined ? req.headers['x-pin'] : '';
      const status: number = this.checkPin(provided);
      if (status !== 0) {
        await conn.fail(status, status === 429 ? 'too_many_requests' : 'pin_required',
          status === 429 ? '尝试次数过多，请稍后再试' : '需要配对码');
        return;
      }
    }

    if (req.method === 'GET' && req.path === '/v1/info') {
      const payload: string = '{"app":"landrop","v":1,"id":"' + esc(this.deviceId) +
        '","name":"' + esc(this.deviceName) + '","platform":"harmony","version":"' + APP_VERSION +
        '","port":' + this.listenPort.toString() + ',"pin_required":' + (this.pinRequired ? 'true' : 'false') +
        ',"inbox":"' + esc(this.store.inboxPath) + '"}';
      await conn.respondJson(200, payload);
      return;
    }

    if (req.method === 'GET' && req.path === '/v1/files') {
      const items: FileItem[] = this.store.list();
      const parts: string[] = [];
      for (let i = 0; i < items.length; i++) {
        const it: FileItem = items[i];
        parts.push('{"id":"' + esc(it.id) + '","name":"' + esc(it.name) +
          '","size":' + it.size.toString() +
          ',"mime":"' + (it.kind === 'text' ? 'text/plain' : 'application/octet-stream') +
          '","mtime":' + Math.floor(it.mtime / 1000).toString() +
          ',"kind":"' + esc(it.kind) + '"}');
      }
      await conn.respondJson(200, '{"files":[' + parts.join(',') + ']}');
      return;
    }

    if (req.method === 'POST' && req.path === '/v1/upload') {
      await this.handleUpload(conn, req, body);
      return;
    }

    if (req.method === 'POST' && req.path === '/v1/cancel') {
      const fid: string = req.headers['x-file-id'] !== undefined ? req.headers['x-file-id'] : '';
      if (fid.length > 0) {
        // 真正关掉上传连接，否则发送端会继续把剩余分片发完
        this.cancelInbound(fid);
        this.onUploadAborted(fid);
      }
      await conn.respondJson(200, '{"cancelled":' + (fid.length > 0 ? 'true' : 'false') + '}');
      return;
    }

    if (req.method === 'POST' && req.path === '/v1/text') {
      await this.handleText(conn, body);
      return;
    }

    if (req.path.startsWith('/v1/files/') && req.path.endsWith('/content')) {
      const id: string = req.path.substring('/v1/files/'.length, req.path.length - '/content'.length);
      await this.handleDownload(conn, req, id);
      return;
    }

    await conn.fail(404, 'not_found', '未知接口 ' + req.path);
  }

  private async handleUpload(conn: HttpConn, req: ParsedRequest, body: Uint8Array): Promise<void> {
    const rawName: string = req.headers['x-file-name'] !== undefined ? req.headers['x-file-name'] : '';
    const fileId: string = req.headers['x-file-id'] !== undefined ? req.headers['x-file-id'] : '';
    const hasSize: boolean = req.headers['x-file-size'] !== undefined;
    const totalRaw: string = hasSize ? req.headers['x-file-size'] as string : '';
    const offsetRaw: string = req.headers['x-offset'] !== undefined ? req.headers['x-offset'] : '0';
    const total: number = parseInt(totalRaw, 10);
    const offset: number = parseInt(offsetRaw, 10);
    const name: string = decodeName(rawName);

    if (!isValidFileId(fileId) || name.length === 0 || !hasSize ||
      isNaN(total) || total < 0 || isNaN(offset) || offset < 0) {
      await conn.fail(400, 'bad_upload', '缺少或无效的 X-File-Name / X-File-Id / X-File-Size');
      return;
    }
    // 允许 0 字节文件：只有「声明了非 0 总大小却发送空 body」才是错误
    if (body.length === 0 && total !== 0) {
      await conn.fail(400, 'bad_upload', '空请求体');
      return;
    }
    if (offset + body.length > total) {
      await conn.fail(400, 'bad_range', '块长度超出总大小');
      return;
    }

    this.inboundConns.set(fileId, conn);
    try {
      const existing: number = this.store.partSize(fileId);
      if (offset !== existing) {
        await conn.respondJson(409, '{"error":{"code":"offset_mismatch","message":"偏移不一致"},' +
          '"actual_offset":' + existing.toString() + '}');
        return;
      }

      const received: number = this.store.appendChunk(fileId, name, offset, body.buffer as ArrayBuffer);
      this.onUploadProgress(fileId, name, received, total);
      const complete: boolean = total === 0 || received >= total;

      if (complete) {
        const item: FileItem = this.store.finish(fileId, name);
        this.onReceive(item);
        await conn.respondJson(200, '{"id":"' + esc(item.id) + '","name":"' + esc(item.name) +
          '","size":' + item.size.toString() + ',"received":' + item.size.toString() + ',"complete":true}');
      } else {
        await conn.respondJson(200, '{"id":"","name":"' + esc(name) + '","size":' + total.toString() +
          ',"received":' + received.toString() + ',"complete":false}');
      }
    } finally {
      this.inboundConns.delete(fileId);
    }
  }

  private async handleText(conn: HttpConn, body: Uint8Array): Promise<void> {
    if (body.length === 0 || body.length > 1024 * 1024) {
      await conn.fail(400, 'bad_text', '文本为空或过长（上限 1MB）');
      return;
    }
    try {
      const text: string = Bytes.utf8(body);
      const obj: Record<string, string> = JSON.parse(text) as Record<string, string>;
      const content: string = obj['text'] !== undefined ? obj['text'] : '';
      const name: string = obj['name'] !== undefined ? obj['name'] : '';
      if (content.length === 0) {
        await conn.fail(400, 'bad_text', '文本为空');
        return;
      }
      const item: FileItem = this.store.saveText(content, name);
      this.onReceive(item);
      await conn.respondJson(200, '{"id":"' + esc(item.id) + '","name":"' + esc(item.name) +
        '","size":' + item.size.toString() + '}');
    } catch (e) {
      await conn.fail(400, 'bad_json', '请求体需要 {"text":"..."}');
    }
  }

  private async handleDownload(conn: HttpConn, req: ParsedRequest, id: string): Promise<void> {
    const item: FileItem | null = this.store.find(id);
    if (item === null) {
      await conn.fail(404, 'not_found', '文件不存在');
      return;
    }
    const size: number = item.size;
    let start: number = 0;
    let end: number = size - 1;
    let status: number = 200;

    const range: string = req.headers['range'] !== undefined ? req.headers['range'] : '';
    if (range.length > 0) {
      const parsed: number[] | null = parseRange(range, size);
      if (parsed === null) {
        // 协议要求非法范围返回 416，而不是静默退回整文件 200
        await conn.respondHead(416, 'Content-Length: 0\r\nContent-Range: bytes */' + size.toString() + '\r\n');
        conn.close();
        return;
      }
      start = parsed[0];
      end = parsed[1];
      status = 206;
    }

    const length: number = Math.max(0, end - start + 1);
    const encoded: string = encodeURIComponent(item.name);
    let headers: string = 'Content-Type: application/octet-stream\r\n' +
      'Content-Length: ' + length.toString() + '\r\n' +
      'Accept-Ranges: bytes\r\n' +
      'Content-Disposition: attachment; filename*=UTF-8\'\'' + encoded + '\r\n';
    if (status === 206) {
      headers += 'Content-Range: bytes ' + start.toString() + '-' + end.toString() + '/' + size.toString() + '\r\n';
    }
    await conn.respondHead(status, headers);

    if (req.method === 'HEAD') {
      conn.close();
      return;
    }

    const file = fs.openSync(item.path, fs.OpenMode.READ_ONLY);
    try {
      let position: number = start;
      let remaining: number = length;
      const chunkSize: number = 256 * 1024;
      while (remaining > 0) {
        const want: number = Math.min(chunkSize, remaining);
        const buf: ArrayBuffer = new ArrayBuffer(want);
        const read: number = fs.readSync(file.fd, buf, { offset: position, length: want });
        if (read <= 0) {
          break;
        }
        await conn.write(new Uint8Array(buf.slice(0, read)));
        position += read;
        remaining -= read;
      }
    } finally {
      fs.closeSync(file);
    }
    conn.close();
  }

  static reason(status: number): string {
    if (status === 200) {
      return 'OK';
    }
    if (status === 204) {
      return 'No Content';
    }
    if (status === 206) {
      return 'Partial Content';
    }
    if (status === 400) {
      return 'Bad Request';
    }
    if (status === 401) {
      return 'Unauthorized';
    }
    if (status === 404) {
      return 'Not Found';
    }
    if (status === 409) {
      return 'Conflict';
    }
    if (status === 413) {
      return 'Payload Too Large';
    }
    if (status === 416) {
      return 'Range Not Satisfiable';
    }
    if (status === 429) {
      return 'Too Many Requests';
    }
    return 'Status';
  }
}

/** 文件名在协议里是 percent-encoded UTF-8，服务端只解码一次 */
export function decodeName(raw: string): string {
  try {
    return decodeURIComponent(raw);
  } catch (e) {
    return raw;
  }
}

/** X-File-Id 会参与分片文件名，必须挡住路径穿越字符 */
export function isValidFileId(id: string): boolean {
  if (id.length === 0 || id.length > 64 || id.charAt(0) === '.') {
    return false;
  }
  if (id.indexOf('..') >= 0) {
    return false;
  }
  return new RegExp('^[A-Za-z0-9._-]+$').test(id);
}

/** 解析 Range: bytes=...；返回 [start, end]，非法返回 null（由调用方回 416） */
export function parseRange(range: string, size: number): number[] | null {
  if (!range.startsWith('bytes=') || range.indexOf(',') >= 0) {
    return null;
  }
  const spec: string = range.substring(6).trim();
  const parts: string[] = spec.split('-');
  if (parts.length !== 2) {
    return null;
  }
  if (size <= 0) {
    return null;
  }
  let start: number = 0;
  let end: number = size - 1;
  if (parts[0].length === 0) {
    // bytes=-N：最后 N 字节
    const suffix: number = parseInt(parts[1], 10);
    if (isNaN(suffix) || suffix <= 0) {
      return null;
    }
    start = Math.max(0, size - suffix);
  } else {
    start = parseInt(parts[0], 10);
    if (isNaN(start) || start < 0 || start >= size) {
      return null;
    }
    if (parts[1].length > 0) {
      const rawEnd: number = parseInt(parts[1], 10);
      if (isNaN(rawEnd) || rawEnd < start) {
        return null;
      }
      end = Math.min(rawEnd, size - 1);
    }
  }
  if (start > end) {
    return null;
  }
  return [start, end];
}

export function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) {
    return false;
  }
  let diff: number = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

export function esc(s: string): string {
  let out: string = '';
  for (let i = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c === 92) {
      out += '\\\\';
    } else if (c === 34) {
      out += '\\"';
    } else if (c === 10) {
      out += '\\n';
    } else if (c === 13) {
      out += '\\r';
    } else if (c === 9) {
      out += '\\t';
    } else if (c < 0x20) {
      out += ' ';
    } else {
      out += s.charAt(i);
    }
  }
  return out;
}

export function jsonError(code: string, message: string): string {
  return '{"error":{"code":"' + esc(code) + '","message":"' + esc(message) + '"}}';
}
