import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { connection } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Beacon, Peer, FileItem, TransferItem, TCP_PORT, stableId, TransferControl, SendOutcome } from '../model/Models';
import { InboxStore } from '../store/InboxStore';
import { HttpServer } from '../net/HttpServer';
import { Discovery } from '../net/Discovery';
import { PeerClient } from '../net/PeerClient';

/**
 * 全局核心：持有收件箱、HTTP 服务端、UDP 发现与传输状态。
 * UI 通过回调订阅，避免 ArkUI 状态与网络线程耦合。
 */
export class LanDropCore {
  private static instance: LanDropCore | null = null;

  static get(): LanDropCore {
    if (LanDropCore.instance === null) {
      LanDropCore.instance = new LanDropCore();
    }
    return LanDropCore.instance;
  }

  private ctx: common.UIAbilityContext | null = null;
  private prefs: preferences.Preferences | null = null;
  private store: InboxStore | null = null;
  private server: HttpServer | null = null;
  private discovery: Discovery | null = null;
  private peerPins: Record<string, string> = {};
  private speedSamples: Map<string, number[]> = new Map<string, number[]>();
  private controls: Map<string, TransferControl> = new Map<string, TransferControl>();
  private transferPeers: Map<string, Peer> = new Map<string, Peer>();
  private transferUris: Map<string, string> = new Map<string, string>();
  private transferSizes: Map<string, number> = new Map<string, number>();
  private inboundMap: Map<string, string> = new Map<string, string>();
  private inboundTicks: Map<string, number> = new Map<string, number>();

  deviceId: string = '';
  deviceName: string = 'HarmonyOS 设备';
  pin: string = '000000';
  pinEnabled: boolean = false;
  port: number = TCP_PORT;
  running: boolean = false;

  peers: Peer[] = [];
  files: FileItem[] = [];
  transfers: TransferItem[] = [];

  onPeers: () => void = () => {
  };
  onFiles: () => void = () => {
  };
  onTransfers: () => void = () => {
  };
  onStatus: (text: string) => void = () => {
  };
  /** 对端要求配对码时通知 UI 弹输入框 */
  onNeedPin: (peer: Peer) => void = () => {
  };

  // MARK: 初始化

  init(context: common.UIAbilityContext): void {
    if (this.ctx !== null) {
      return;
    }
    this.ctx = context;
    const pref: preferences.Preferences = preferences.getPreferencesSync(context, { name: 'landrop' });
    this.prefs = pref;

    let id: string = pref.getSync('deviceId', '') as string;
    if (id.length === 0) {
      id = randomId();
      pref.putSync('deviceId', id);
    }
    this.deviceId = id;

    const savedName: string = pref.getSync('deviceName', '') as string;
    this.deviceName = savedName.length > 0 ? savedName : 'HarmonyOS 设备';
    this.pin = pref.getSync('pin', '000000') as string;
    this.pinEnabled = pref.getSync('pinEnabled', false) as boolean;
    const pins: string = pref.getSync('peerPins', '{}') as string;
    try {
      this.peerPins = JSON.parse(pins) as Record<string, string>;
    } catch (e) {
      this.peerPins = {};
    }

    this.store = new InboxStore(context.filesDir);
    this.server = new HttpServer(this.store);
    this.server.setIdentity(this.deviceId, this.deviceName, this.pin, this.pinEnabled);
    this.server.onUploadProgress = (fileId: string, name: string, received: number, total: number) => {
      this.inboundProgress(fileId, name, received, total);
    };
    this.server.onUploadAborted = (fileId: string) => {
      this.markInbound(fileId, 'cancelled', '对端已取消');
    };
    this.server.setReceiveListener((item: FileItem) => {
      this.files = this.store === null ? [] : this.store.list();
      this.onFiles();
      this.onStatus('收到 ' + item.name);
    });
    this.files = this.store.list();
  }

  get inboxPath(): string {
    return this.store === null ? '' : this.store.inboxPath;
  }

  // MARK: 启动 / 停止

  async start(): Promise<boolean> {
    if (this.running || this.server === null) {
      return this.running;
    }
    try {
      this.server.setIdentity(this.deviceId, this.deviceName, this.pin, this.pinEnabled);
      await this.server.start(this.port);
      this.discovery = new Discovery(this.deviceId, () => this.beacon(), (p: Peer) => this.upsertPeer(p));
      await this.discovery.start();
      this.running = true;
      this.onStatus('正在接收 · 端口 ' + this.port.toString());
      return true;
    } catch (e) {
      this.running = false;
      this.onStatus('启动失败：' + (e as Error).message);
      return false;
    }
  }

  stop(): void {
    if (this.discovery !== null) {
      this.discovery.stop();
      this.discovery = null;
    }
    if (this.server !== null) {
      this.server.stop();
    }
    this.running = false;
    this.peers = [];
    this.onPeers();
    this.onStatus('已停止');
  }

  private beacon(): Beacon {
    return {
      app: 'landrop',
      v: 1,
      type: 'announce',
      id: this.deviceId,
      name: this.deviceName,
      platform: 'harmony',
      port: this.port,
      pin_required: this.pinEnabled
    };
  }

  /** 接收方进度：按 fileId 建一条「接收」记录并刷新 */
  private inboundProgress(fileId: string, name: string, received: number, total: number): void {
    let tid: string | undefined = this.inboundMap.get(fileId);
    if (tid === undefined) {
      const t: TransferItem = new TransferItem(name, '远端设备', 'receive', total);
      this.transfers = [t].concat(this.transfers);
      tid = t.id;
      this.inboundMap.set(fileId, tid);
    }
    this.inboundTicks.set(fileId, Date.now());
    const done: boolean = total === 0 || received >= total;
    this.updateTransfer(tid, received, total, done ? 'done' : 'running', '');
    if (done) {
      this.inboundMap.delete(fileId);
      this.inboundTicks.delete(fileId);
    }
  }

  /** 就地结束一条接收记录（不改动已收字节） */
  private markInbound(fileId: string, state: string, error: string): void {
    const tid: string | undefined = this.inboundMap.get(fileId);
    this.inboundMap.delete(fileId);
    this.inboundTicks.delete(fileId);
    if (tid === undefined) {
      return;
    }
    const list: TransferItem[] = this.transfers.slice();
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === tid) {
        const next: TransferItem = list[i].clone();
        next.state = state;
        next.error = error;
        next.speed = 0;
        list[i] = next;
        break;
      }
    }
    this.transfers = list.slice();
    this.onTransfers();
  }

  /** 6s 无数据的接收任务判定断开 */
  pruneInbound(): void {
    const now: number = Date.now();
    const stale: string[] = [];
    this.inboundTicks.forEach((t: number, fid: string) => {
      if (now - t > 6000) {
        stale.push(fid);
      }
    });
    for (let i = 0; i < stale.length; i++) {
      this.markInbound(stale[i], 'failed', '连接超时');
    }
  }

  private upsertPeer(incoming: Peer): void {
    const list: Peer[] = this.peers.slice();
    let found: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === incoming.id) {
        list[i].name = incoming.name;
        list[i].platform = incoming.platform;
        list[i].host = incoming.host;
        list[i].port = incoming.port;
        list[i].pinRequired = incoming.pinRequired;
        list[i].lastSeen = Date.now();
        found = true;
        break;
      }
    }
    if (!found) {
      list.push(incoming);
    }
    list.sort((a: Peer, b: Peer) => a.name.localeCompare(b.name));
    this.peers = list;
    this.onPeers();
  }

  prunePeers(): void {
    const now: number = Date.now();
    const alive: Peer[] = this.peers.filter((p: Peer) => now - p.lastSeen < 30000);
    if (alive.length !== this.peers.length) {
      this.peers = alive;
      this.onPeers();
    }
  }

  probe(): void {
    if (this.discovery !== null) {
      this.discovery.probe();
    }
  }

  async localIp(): Promise<string> {
    try {
      const handle: connection.NetHandle = await connection.getDefaultNet();
      const props: connection.ConnectionProperties = await connection.getConnectionProperties(handle);
      for (let i = 0; i < props.linkAddresses.length; i++) {
        const addr: connection.LinkAddress = props.linkAddresses[i];
        if (addr.address.family === 1 && addr.address.address !== '127.0.0.1') {
          return addr.address.address;
        }
      }
    } catch (e) {
      return '127.0.0.1';
    }
    return '127.0.0.1';
  }

  // MARK: 收件箱

  refreshFiles(): void {
    if (this.store !== null) {
      this.files = this.store.list();
      this.onFiles();
    }
  }

  removeFile(item: FileItem): void {
    if (this.store !== null) {
      this.store.remove(item);
      this.refreshFiles();
    }
  }

  // MARK: 发送

  sendFiles(uris: string[], peer: Peer): void {
    for (let i = 0; i < uris.length; i++) {
      const uri: string = uris[i];
      let name: string = uri.substring(uri.lastIndexOf('/') + 1);
      try {
        name = decodeURIComponent(name);
      } catch (e) {
        // 保留原样
      }
      let size: number = -1;
      try {
        size = fs.statSync(uri).size;
      } catch (e) {
        size = -1;
      }
      if (size < 0) {
        this.onStatus('无法读取 ' + name);
        continue;
      }
      const transfer: TransferItem = new TransferItem(name, peer.name, 'send', size);
      this.transfers = [transfer].concat(this.transfers);
      this.onTransfers();
      const control: TransferControl = new TransferControl();
      this.controls.set(transfer.id, control);
      this.transferPeers.set(transfer.id, peer);
      this.transferUris.set(transfer.id, uri);
      this.transferSizes.set(transfer.id, size);
      this.runUpload(uri, name, size, peer, transfer, control);
    }
  }

  private async runUpload(uri: string, name: string, size: number, peer: Peer,
                          transfer: TransferItem, control: TransferControl): Promise<void> {
    const client: PeerClient = new PeerClient(this.pinFor(peer));
    const res: SendOutcome = await client.sendFile(peer, uri, name, size, control,
      (sent: number, total: number) => {
        this.updateTransfer(transfer.id, sent, total, 'running', '');
      });
    if (res.paused) {
      // 用户暂停（或需要补配对码）：保留 control/uri，点「继续」可原地续传
      this.updateTransfer(transfer.id, control.offset, size, 'paused',
        client.pinRequiredSeen ? '需要配对码' : '');
      if (client.pinRequiredSeen) {
        this.onNeedPin(peer);
      }
      return;
    }
    if (res.pinRequired) {
      this.updateTransfer(transfer.id, control.offset, size, 'paused', '需要配对码');
      this.onNeedPin(peer);
      return;
    }
    this.cleanupOutgoing(transfer.id);
    if (res.ok) {
      this.updateTransfer(transfer.id, size, size, 'done', '');
      this.onStatus('已发送 ' + name);
    } else if (res.cancelled) {
      this.updateTransfer(transfer.id, transfer.sent, transfer.total, 'cancelled', '已取消');
      this.onStatus('已取消 ' + name);
    } else {
      this.updateTransfer(transfer.id, transfer.sent, transfer.total, 'failed', '发送失败');
    }
  }

  private cleanupOutgoing(id: string): void {
    this.controls.delete(id);
    this.transferPeers.delete(id);
    this.transferUris.delete(id);
    this.transferSizes.delete(id);
  }

  sendText(text: string, peer: Peer): void {
    const transfer: TransferItem = new TransferItem('文本 ' + text.length.toString() + ' 字', peer.name, 'send', text.length);
    transfer.state = 'running';
    this.transfers = [transfer].concat(this.transfers);
    this.onTransfers();
    const client: PeerClient = new PeerClient(this.pinFor(peer));
    client.sendText(peer, text, '').then((ok: boolean) => {
      if (!ok && client.pinRequiredSeen) {
        this.updateTransfer(transfer.id, transfer.sent, transfer.total, 'failed', '需要配对码');
        this.onNeedPin(peer);
        return;
      }
      this.updateTransfer(transfer.id, text.length, text.length, ok ? 'done' : 'failed', ok ? '' : '发送失败');
      if (ok) {
        this.onStatus('文本已发送给 ' + peer.name);
      }
    });
  }

  private updateTransfer(id: string, sent: number, total: number, state: string, error: string): void {
    const now: number = Date.now();
    let speed: number = 0;
    const sample: number[] | undefined = this.speedSamples.get(id);
    if (sample !== undefined) {
      const dt: number = now - sample[0];
      if (dt >= 200) {
        speed = Math.max(0, Math.floor((sent - sample[1]) * 1000 / dt));
        this.speedSamples.set(id, [now, sent]);
      }
    } else {
      this.speedSamples.set(id, [now, sent]);
    }

    const list: TransferItem[] = this.transfers.slice();
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        const next: TransferItem = list[i].clone();
        next.sent = sent;
        if (total > 0) {
          next.total = total;
        }
        next.state = state;
        next.error = error;
        if (speed > 0) {
          next.speed = next.speed > 1 ? Math.floor(next.speed * 0.6 + speed * 0.4) : speed;
        }
        if (state === 'done' || state === 'failed' || state === 'paused' || state === 'cancelled') {
          next.speed = 0;
          this.speedSamples.delete(id);
        }
        list[i] = next;
        break;
      }
    }
    this.transfers = list.slice();
    this.onTransfers();
  }

  /** 接收方向本地取消（关闭不会自动断开，靠标记 + 看门狗） */
  cancelReceive(t: TransferItem): void {
    let fid: string = '';
    this.inboundMap.forEach((tid: string, fileId: string) => {
      if (tid === t.id) {
        fid = fileId;
      }
    });
    if (fid.length > 0) {
      if (this.server !== null) {
        this.server.cancelInbound(fid);
      }
      this.markInbound(fid, 'cancelled', '已取消');
    }
    this.onStatus('已取消接收 ' + t.fileName);
  }

  /** 暂停发送：当前分片结束后停在断点 */
  pauseTransfer(t: TransferItem): void {
    const control: TransferControl | undefined = this.controls.get(t.id);
    if (control !== undefined) {
      control.pause = true;
    }
  }

  /** 继续发送：沿用同一个 fileId / offset，服务端按 X-Offset 续传 */
  resumeTransfer(t: TransferItem): void {
    const control: TransferControl | undefined = this.controls.get(t.id);
    const peer: Peer | undefined = this.transferPeers.get(t.id);
    const uri: string | undefined = this.transferUris.get(t.id);
    if (control === undefined || peer === undefined || uri === undefined) {
      return;
    }
    control.pause = false;
    control.cancel = false;
    const size: number = this.transferSizes.get(t.id) !== undefined
      ? this.transferSizes.get(t.id) as number : t.total;
    this.updateTransfer(t.id, t.sent, size, 'running', '');
    this.runUpload(uri, t.fileName, size, peer, t, control);
  }

  cancelTransfer(t: TransferItem): void {
    const control: TransferControl | undefined = this.controls.get(t.id);
    if (control === undefined) {
      this.updateTransfer(t.id, t.sent, t.total, 'cancelled', '已取消');
      return;
    }
    control.cancel = true;
    // 暂停/失败状态下没有正在跑的上传循环，必须就地结束，否则会永远卡住
    if (t.state !== 'running') {
      this.updateTransfer(t.id, t.sent, t.total, 'cancelled', '已取消');
      this.cleanupOutgoing(t.id);
    }
    const peer: Peer | undefined = this.transferPeers.get(t.id);
    if (peer !== undefined && control.fileId.length > 0) {
      const client: PeerClient = new PeerClient(this.pinFor(peer));
      client.cancelUpload(peer, control.fileId);
    }
  }

  // MARK: 配对码

  pinFor(peer: Peer): string {
    const v: string = this.peerPins[peer.id];
    return v === undefined ? '' : v;
  }

  setPeerPin(peerId: string, pin: string): void {
    this.peerPins[peerId] = pin;
    this.persist();
  }

  // MARK: 设置

  applySettings(name: string, pin: string, pinEnabled: boolean): void {
    this.deviceName = name.length > 0 ? name : 'HarmonyOS 设备';
    this.pin = pin.length === 6 ? pin : this.pin;
    this.pinEnabled = pinEnabled;
    if (this.server !== null) {
      this.server.setIdentity(this.deviceId, this.deviceName, this.pin, this.pinEnabled);
    }
    this.persist();
    this.onStatus('设置已保存');
  }

  regeneratePin(): string {
    let p: string = '';
    for (let i = 0; i < 6; i++) {
      p += Math.floor(Math.random() * 10).toString();
    }
    this.pin = p;
    this.persist();
    if (this.server !== null) {
      this.server.setIdentity(this.deviceId, this.deviceName, this.pin, this.pinEnabled);
    }
    return p;
  }

  private persist(): void {
    if (this.prefs === null) {
      return;
    }
    this.prefs.putSync('deviceName', this.deviceName);
    this.prefs.putSync('pin', this.pin);
    this.prefs.putSync('pinEnabled', this.pinEnabled);
    this.prefs.putSync('peerPins', JSON.stringify(this.peerPins));
    this.prefs.flush();
  }
}

function randomId(): string {
  let s: string = '';
  for (let i = 0; i < 16; i++) {
    s += Math.floor(Math.random() * 16).toString(16);
  }
  return s;
}
