import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { Beacon, Peer, UDP_PORT } from '../model/Models';

/** UDP 广播发现：probe / announce */
export class Discovery {
  private udp: socket.UDPSocket | null = null;
  private timer: number = -1;
  private running: boolean = false;
  private selfId: string = '';
  private onPeer: (peer: Peer) => void;
  private buildBeacon: () => Beacon;

  constructor(selfId: string, buildBeacon: () => Beacon, onPeer: (peer: Peer) => void) {
    this.selfId = selfId;
    this.buildBeacon = buildBeacon;
    this.onPeer = onPeer;
  }

  get isRunning(): boolean {
    return this.running;
  }

  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
    const bindAddr: socket.NetAddress = { address: '0.0.0.0', port: UDP_PORT, family: 1 };
    await udp.bind(bindAddr);
    const extra: socket.UDPExtraOptions = { broadcast: true, reuseAddress: true, receiveBufferSize: 65536 };
    await udp.setExtraOptions(extra);
    udp.on('message', (info: socket.SocketMessageInfo) => {
      this.handleMessage(info);
    });
    udp.on('error', () => {
      // 网络切换时可能触发，忽略
    });
    this.udp = udp;
    this.running = true;
    this.probe();
    this.timer = setInterval(() => {
      this.probe();
    }, 15000);
  }

  stop(): void {
    this.running = false;
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.udp !== null) {
      try {
        this.udp.off('message');
        this.udp.close();
      } catch (e) {
        // 已关闭
      }
      this.udp = null;
    }
  }

  probe(): void {
    if (this.udp === null) {
      return;
    }
    const beacon: Beacon = this.buildBeacon();
    beacon.type = 'probe';
    const payload: string = JSON.stringify(beacon);
    const targets: string[] = ['255.255.255.255'];
    for (let i = 0; i < targets.length; i++) {
      const target: socket.NetAddress = { address: targets[i], port: UDP_PORT, family: 1 };
      const opt: socket.UDPSendOptions = { data: payload, address: target };
      this.udp.send(opt).catch(() => {
        // 部分网卡不允许广播
      });
    }
  }

  private handleMessage(info: socket.SocketMessageInfo): void {
    let text: string = '';
    try {
      text = util_decode(info);
    } catch (e) {
      return;
    }
    if (text.length === 0) {
      return;
    }
    let beacon: Beacon;
    try {
      beacon = JSON.parse(text) as Beacon;
    } catch (e) {
      return;
    }
    if (beacon.app !== 'landrop' || beacon.id.length === 0 || beacon.id === this.selfId) {
      return;
    }
    if (beacon.type === 'probe') {
      const peer: Peer = new Peer(beacon.id, beacon.name, beacon.platform,
        info.remoteInfo.address, beacon.port, beacon.pin_required);
      this.onPeer(peer);
      const reply: Beacon = this.buildBeacon();
      reply.type = 'announce';
      if (this.udp !== null) {
        const target: socket.NetAddress = { address: info.remoteInfo.address, port: UDP_PORT, family: 1 };
        const opt: socket.UDPSendOptions = { data: JSON.stringify(reply), address: target };
        this.udp.send(opt).catch(() => {
        });
      }
    } else if (beacon.type === 'announce') {
      const peer: Peer = new Peer(beacon.id, beacon.name, beacon.platform,
        info.remoteInfo.address, beacon.port, beacon.pin_required);
      this.onPeer(peer);
    }
  }
}

function util_decode(info: socket.SocketMessageInfo): string {
  // 必须按 UTF-8 解码：逐字节 String.fromCharCode 会把中文设备名变成乱码
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
  return decoder.decodeToString(new Uint8Array(info.message));
}
