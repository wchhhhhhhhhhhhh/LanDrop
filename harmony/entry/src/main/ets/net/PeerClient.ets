import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Peer, RemoteFile, formatSize, TransferControl, SendOutcome } from '../model/Models';

interface TextBody {
  text: string;
  name: string;
}

export class UploadResult {
  ok: boolean = false;
  received: number = 0;
  actualOffset: number = -1;
  pinRequired: boolean = false;
  gone: boolean = false;
  message: string = '';
}

export class PeerClient {
  private pin: string = '';
  /** 最近一次传输是否因缺少/错误配对码被拒绝（供 UI 弹配对码框） */
  pinRequiredSeen: boolean = false;

  constructor(pin: string) {
    this.pin = pin;
  }

  private base(peer: Peer): string {
    return 'http://' + peer.host + ':' + peer.port.toString();
  }

  private header(extra: Record<string, string>): Record<string, string> {
    const h: Record<string, string> = {};
    if (this.pin.length > 0) {
      h['X-Pin'] = this.pin;
    }
    const keys: string[] = Object.keys(extra);
    for (let i = 0; i < keys.length; i++) {
      h[keys[i]] = extra[keys[i]];
    }
    return h;
  }

  async pullInfo(peer: Peer): Promise<Record<string, string>> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await request.request(this.base(peer) + '/v1/info', {
        method: http.RequestMethod.GET,
        header: this.header({}),
        connectTimeout: 8000,
        readTimeout: 8000
      });
      const text: string = resp.result as string;
      return JSON.parse(text) as Record<string, string>;
    } finally {
      request.destroy();
    }
  }

  async listFiles(peer: Peer): Promise<RemoteFile[]> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await request.request(this.base(peer) + '/v1/files', {
        method: http.RequestMethod.GET,
        header: this.header({}),
        connectTimeout: 8000,
        readTimeout: 15000
      });
      const text: string = resp.result as string;
      const obj: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const raw: Object[] = obj['files'] as Object[];
      const out: RemoteFile[] = [];
      for (let i = 0; i < raw.length; i++) {
        const m: Record<string, Object> = raw[i] as Record<string, Object>;
        const f: RemoteFile = new RemoteFile();
        f.id = m['id'] as string;
        f.name = m['name'] as string;
        f.size = m['size'] as number;
        f.kind = m['kind'] as string;
        out.push(f);
      }
      return out;
    } finally {
      request.destroy();
    }
  }

  async uploadChunk(peer: Peer, fileId: string, name: string, total: number,
                    offset: number, data: ArrayBuffer): Promise<UploadResult> {
    const result: UploadResult = new UploadResult();
    const request: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await request.request(this.base(peer) + '/v1/upload', {
        method: http.RequestMethod.POST,
        header: this.header(uploadHeaders(name, fileId, total, offset)),
        extraData: data,
        connectTimeout: 10000,
        readTimeout: 120000
      });
      const code: number = resp.responseCode;
      const text: string = resp.result as string;
      if (code === 200) {
        const obj: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
        result.ok = true;
        result.received = obj['received'] as number;
        return result;
      }
      if (code === 409) {
        const obj: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
        result.actualOffset = obj['actual_offset'] as number;
        result.message = 'offset mismatch';
        return result;
      }
      if (code === 401) {
        result.pinRequired = true;
        result.message = '需要配对码';
        return result;
      }
      if (code === 410) {
        result.gone = true;
        result.message = '对端已取消';
        return result;
      }
      result.message = 'HTTP ' + code.toString();
      return result;
    } catch (e) {
      result.message = (e as Error).message;
      return result;
    } finally {
      request.destroy();
    }
  }

  /** 发送本地文件（按 1MB 分块，支持断点续传 / 暂停） */
  async sendFile(peer: Peer, uri: string, displayName: string, total: number,
                 control: TransferControl,
                 onProgress: (sent: number, total: number) => void): Promise<SendOutcome> {
    const out: SendOutcome = new SendOutcome();
    if (control.cancel) {
      out.cancelled = true;
      return out;
    }
    if (control.pause) {
      out.paused = true;
      return out;
    }
    if (control.fileId.length === 0) {
      control.fileId = Date.now().toString() + Math.floor(Math.random() * 100000).toString();
    }
    const fileId: string = control.fileId;
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const chunk: number = 1024 * 1024;
    let offset: number = control.offset;
    let retries: number = 0;
    try {
      // 0 字节文件也要发一次空分片，否则对端永远收不到它
      if (total === 0) {
        const empty: UploadResult = await this.uploadChunk(peer, fileId, displayName, 0, 0, new ArrayBuffer(0));
        if (empty.pinRequired) {
          this.pinRequiredSeen = true;
          out.pinRequired = true;
          return out;
        }
        if (!empty.ok) {
          return out;
        }
        control.offset = 0;
        onProgress(0, 0);
        out.ok = true;
        return out;
      }
      while (offset < total) {
        if (control.cancel) {
          control.offset = offset;
          out.cancelled = true;
          return out;
        }
        if (control.pause) {
          control.offset = offset;
          out.paused = true;
          return out;
        }
        const want: number = Math.min(chunk, total - offset);
        const buf: ArrayBuffer = new ArrayBuffer(want);
        const read: number = fs.readSync(file.fd, buf, { offset: offset, length: want });
        if (read <= 0) {
          break;
        }
        const payload: ArrayBuffer = buf.slice(0, read);
        const res: UploadResult = await this.uploadChunk(peer, fileId, displayName, total, offset, payload);
        if (res.ok) {
          offset += read;
          control.offset = offset;
          retries = 0;
          onProgress(offset, total);
        } else if (res.gone) {
          control.cancel = true;
          out.cancelled = true;
          return out;
        } else if (res.pinRequired) {
          this.pinRequiredSeen = true;
          control.offset = offset;
          out.pinRequired = true;
          return out;
        } else if (res.actualOffset >= 0) {
          offset = res.actualOffset;
          control.offset = offset;
          retries++;
          if (retries > 8) {
            return out;
          }
        } else {
          retries++;
          if (retries > 6) {
            return out;
          }
          await sleep(700);
        }
      }
      out.ok = offset >= total;
      return out;
    } finally {
      fs.closeSync(file);
    }
  }

  /** 通知对端作废这次上传 */
  async cancelUpload(peer: Peer, fileId: string): Promise<void> {
    const request: http.HttpRequest = http.createHttp();
    try {
      await request.request(this.base(peer) + '/v1/cancel', {
        method: http.RequestMethod.POST,
        header: this.header({ 'X-File-Id': fileId }),
        connectTimeout: 5000,
        readTimeout: 5000
      });
    } catch (e) {
      // 对端不可达时交给它的看门狗兜底
    } finally {
      request.destroy();
    }
  }

  async sendText(peer: Peer, text: string, name: string): Promise<boolean> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const bodyObj: TextBody = { text: text, name: name };
      const body: string = JSON.stringify(bodyObj);
      const resp: http.HttpResponse = await request.request(this.base(peer) + '/v1/text', {
        method: http.RequestMethod.POST,
        header: this.header(jsonHeader()),
        extraData: body,
        connectTimeout: 8000,
        readTimeout: 15000
      });
      if (resp.responseCode === 401) {
        this.pinRequiredSeen = true;
      }
      return resp.responseCode === 200;
    } catch (e) {
      return false;
    } finally {
      request.destroy();
    }
  }

  /** 从对方拉取文件到本地路径 */
  async download(peer: Peer, remote: RemoteFile, targetPath: string,
                  onProgress: (sent: number, total: number) => void): Promise<boolean> {
    const chunk: number = 1024 * 1024;
    let offset: number = 0;
    const file = fs.openSync(targetPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      while (offset < remote.size) {
        const end: number = Math.min(offset + chunk - 1, remote.size - 1);
        const request: http.HttpRequest = http.createHttp();
        try {
          const resp: http.HttpResponse = await request.request(
            this.base(peer) + '/v1/files/' + remote.id + '/content', {
              method: http.RequestMethod.GET,
              header: this.header(rangeHeaders(offset, end)),
              expectDataType: http.HttpDataType.ARRAY_BUFFER,
              connectTimeout: 10000,
              readTimeout: 120000
            });
          if (resp.responseCode !== 200 && resp.responseCode !== 206) {
            return false;
          }
          const data: ArrayBuffer = resp.result as ArrayBuffer;
          if (data.byteLength === 0) {
            break;
          }
          fs.writeSync(file.fd, data, { offset: offset });
          offset += data.byteLength;
          onProgress(offset, remote.size);
        } finally {
          request.destroy();
        }
      }
      // 空响应/提前断流不能让调用方误以为下载成功
      return offset === remote.size;
    } finally {
      fs.closeSync(file);
    }
  }
}

export function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

export function describeSize(bytes: number): string {
  return formatSize(bytes);
}

function uploadHeaders(name: string, fileId: string, total: number, offset: number): Record<string, string> {
  const h: Record<string, string> = {
    'X-File-Name': encodeURIComponent(name),
    'X-File-Id': fileId,
    'X-File-Size': total.toString(),
    'X-Offset': offset.toString(),
    'Content-Type': 'application/octet-stream'
  };
  return h;
}

function jsonHeader(): Record<string, string> {
  const h: Record<string, string> = { 'Content-Type': 'application/json' };
  return h;
}

function rangeHeaders(start: number, end: number): Record<string, string> {
  const h: Record<string, string> = { 'Range': 'bytes=' + start.toString() + '-' + end.toString() };
  return h;
}
