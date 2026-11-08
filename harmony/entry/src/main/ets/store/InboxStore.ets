import { fileIo as fs } from '@kit.CoreFileKit';
import { FileItem, stableId } from '../model/Models';

/**
 * 收件箱：应用沙箱 filesDir/inbox
 * 上传中的分片放 filesDir/partials/<id>.part，完成后原子 rename 进 inbox
 */
export class InboxStore {
  private dir: string;
  private partialDir: string;

  constructor(filesDir: string) {
    this.dir = filesDir + '/inbox';
    this.partialDir = filesDir + '/partials';
    this.ensureDirs();
  }

  get inboxPath(): string {
    return this.dir;
  }

  private ensureDirs(): void {
    if (!fs.accessSync(this.dir)) {
      fs.mkdirSync(this.dir, true);
    }
    if (!fs.accessSync(this.partialDir)) {
      fs.mkdirSync(this.partialDir, true);
    }
  }

  list(): FileItem[] {
    const result: FileItem[] = [];
    try {
      const names: string[] = fs.listFileSync(this.dir);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (name.startsWith('.')) {
          continue;
        }
        const full: string = this.dir + '/' + name;
        try {
          const st: fs.Stat = fs.statSync(full);
          if (!st.isFile()) {
            continue;
          }
          result.push(new FileItem(
            stableId(name),
            name,
            st.size,
            Math.floor(st.mtime * 1000),
            name.endsWith('.txt') ? 'text' : 'file',
            full
          ));
        } catch (e) {
          // 忽略单个文件的读取错误
        }
      }
    } catch (e) {
      return [];
    }
    result.sort((a: FileItem, b: FileItem) => b.mtime - a.mtime);
    return result;
  }

  find(id: string): FileItem | null {
    const items: FileItem[] = this.list();
    for (let i = 0; i < items.length; i++) {
      if (items[i].id === id) {
        return items[i];
      }
    }
    return null;
  }

  partPath(fileId: string): string {
    // fileId 来自请求头，绝不能直接拼进路径：清理非法字符并附加稳定哈希防碰撞
    const safe: string = fileId.replace(new RegExp('[^A-Za-z0-9_-]', 'g'), '_').substring(0, 64);
    const prefix: string = safe.length > 0 ? safe : 'upload';
    return this.partialDir + '/' + prefix + '-' + stableId(fileId) + '.part';
  }

  partSize(fileId: string): number {
    const p: string = this.partPath(fileId);
    try {
      if (fs.accessSync(p)) {
        return fs.statSync(p).size;
      }
    } catch (e) {
      return 0;
    }
    return 0;
  }

  /** 追加写入一块；返回写入后的总长度 */
  appendChunk(fileId: string, name: string, offset: number, data: ArrayBuffer): number {
    const path: string = this.partPath(fileId);
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    try {
      fs.writeSync(file.fd, data, { offset: offset });
      const st: fs.Stat = fs.statSync(path);
      return st.size;
    } finally {
      fs.closeSync(file);
    }
  }

  /** 完成：把 .part 移入收件箱，重名自动加序号 */
  finish(fileId: string, rawName: string): FileItem {
    const part: string = this.partPath(fileId);
    const safe: string = this.sanitize(rawName);
    const finalName: string = this.uniqueName(safe);
    const target: string = this.dir + '/' + finalName;
    fs.renameSync(part, target);
    const st: fs.Stat = fs.statSync(target);
    return new FileItem(
      stableId(finalName),
      finalName,
      st.size,
      Math.floor(st.mtime * 1000),
      finalName.endsWith('.txt') ? 'text' : 'file',
      target
    );
  }

  saveText(text: string, name: string): FileItem {
    const stamp: string = this.timestamp();
    let base: string = name.length > 0 ? this.sanitize(name) : '文本-' + stamp + '.txt';
    if (!base.endsWith('.txt')) {
      base = base + '.txt';
    }
    const finalName: string = this.uniqueName(base);
    const target: string = this.dir + '/' + finalName;
    const file = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
    const st: fs.Stat = fs.statSync(target);
    return new FileItem(stableId(finalName), finalName, st.size, Math.floor(st.mtime * 1000), 'text', target);
  }

  remove(item: FileItem): void {
    try {
      fs.unlinkSync(item.path);
    } catch (e) {
      // 忽略
    }
  }

  private timestamp(): string {
    const d: Date = new Date();
    const p = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    return d.getFullYear().toString() + p(d.getMonth() + 1) + p(d.getDate()) + '-' +
      p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
  }

  sanitize(raw: string): string {
    // 调用方已经按协议解码过一次，这里只做安全清理，避免二次解码破坏 %xx 文件名
    let s: string = raw;
    s = s.replace(new RegExp('/', 'g'), '_')
      .replace(new RegExp('\\\\', 'g'), '_')
      .replace(new RegExp(':', 'g'), '_')
      .replace(new RegExp('\\.\\.', 'g'), '_')
      .replace(new RegExp('[\\u0000-\\u001f]', 'g'), '');
    s = s.trim();
    if (s.length === 0) {
      s = '未命名-' + this.timestamp();
    }
    if (s.length > 120) {
      s = s.substring(0, 120);
    }
    return s;
  }

  private uniqueName(name: string): string {
    if (!fs.accessSync(this.dir + '/' + name)) {
      return name;
    }
    const dot: number = name.lastIndexOf('.');
    const base: string = dot > 0 ? name.substring(0, dot) : name;
    const ext: string = dot > 0 ? name.substring(dot) : '';
    for (let i = 1; i < 10000; i++) {
      const candidate: string = base + ' (' + i.toString() + ')' + ext;
      if (!fs.accessSync(this.dir + '/' + candidate)) {
        return candidate;
      }
    }
    return base + '-' + Date.now().toString() + ext;
  }
}
