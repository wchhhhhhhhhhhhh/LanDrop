export const APP_VERSION: string = '1.0.0';
export const TCP_PORT: number = 47823;
export const UDP_PORT: number = 47824;

export interface Beacon {
  app: string;
  v: number;
  type: string; // probe | announce
  id: string;
  name: string;
  platform: string;
  port: number;
  pin_required: boolean;
}

export class Peer {
  id: string = '';
  name: string = '';
  platform: string = 'harmony';
  host: string = '';
  port: number = TCP_PORT;
  pinRequired: boolean = false;
  lastSeen: number = 0;

  constructor(id: string, name: string, platform: string, host: string, port: number, pinRequired: boolean) {
    this.id = id;
    this.name = name;
    this.platform = platform;
    this.host = host;
    this.port = port;
    this.pinRequired = pinRequired;
    this.lastSeen = Date.now();
  }

  get online(): boolean {
    return Date.now() - this.lastSeen < 30000;
  }
}

export class FileItem {
  id: string = '';
  name: string = '';
  size: number = 0;
  mtime: number = 0;
  kind: string = 'file';
  path: string = '';

  constructor(id: string, name: string, size: number, mtime: number, kind: string, path: string) {
    this.id = id;
    this.name = name;
    this.size = size;
    this.mtime = mtime;
    this.kind = kind;
    this.path = path;
  }
}

export class TransferControl {
  cancel: boolean = false;
  pause: boolean = false;
  offset: number = 0;
  fileId: string = '';
}

/** 一次上传循环的结果：完成 / 暂停 / 取消 / 需要配对码 */
export class SendOutcome {
  ok: boolean = false;
  paused: boolean = false;
  cancelled: boolean = false;
  pinRequired: boolean = false;
}

export class RemoteFile {
  id: string = '';
  name: string = '';
  size: number = 0;
  kind: string = 'file';
}

export class TransferItem {
  id: string = '';
  fileName: string = '';
  peerName: string = '';
  direction: string = 'send';
  sent: number = 0;
  total: number = 0;
  state: string = 'running';
  error: string = '';
  startedAt: number = 0;
  speed: number = 0;

  constructor(fileName: string, peerName: string, direction: string, total: number) {
    this.id = String(Date.now()) + '-' + Math.floor(Math.random() * 100000).toString();
    this.fileName = fileName;
    this.peerName = peerName;
    this.direction = direction;
    this.total = total;
    this.startedAt = Date.now();
  }

  get progress(): number {
    if (this.total <= 0) {
      return 0;
    }
    return Math.min(1, this.sent / this.total);
  }

  clone(): TransferItem {
    const t: TransferItem = new TransferItem(this.fileName, this.peerName, this.direction, this.total);
    t.id = this.id;
    t.sent = this.sent;
    t.state = this.state;
    t.error = this.error;
    t.startedAt = this.startedAt;
    t.speed = this.speed;
    return t;
  }

  get speedText(): string {
    if (this.speed > 1) {
      return formatSize(this.speed) + '/s';
    }
    return '—';
  }
}

export function platformLabel(p: string): string {
  if (p === 'macos') {
    return 'macOS';
  }
  if (p === 'android') {
    return 'Android';
  }
  if (p === 'harmony') {
    return 'HarmonyOS';
  }
  return '未知设备';
}

export function platformIcon(p: string): string {
  if (p === 'macos') {
    return '💻';
  }
  if (p === 'android') {
    return '📱';
  }
  if (p === 'harmony') {
    return '📲';
  }
  return '❓';
}

export function formatSize(bytes: number): string {
  if (bytes < 1000) {
    return bytes.toString() + ' B';
  }
  const units: string[] = ['KB', 'MB', 'GB', 'TB'];
  let value: number = bytes / 1000;
  let idx: number = 0;
  while (value >= 1000 && idx < units.length - 1) {
    value = value / 1000;
    idx++;
  }
  return value.toFixed(value >= 10 ? 0 : 1) + ' ' + units[idx];
}

export function stableId(name: string): string {
  let hash: number = 2166136261;
  for (let i = 0; i < name.length; i++) {
    hash = hash ^ name.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16).padStart(8, '0') + name.length.toString(16);
}
