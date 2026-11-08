import { common, wantConstant } from '@kit.AbilityKit';
import { picker, fileUri, fileIo as fs } from '@kit.CoreFileKit';
import { promptAction, mediaquery } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { window, display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { unifiedDataChannel, uniformTypeDescriptor } from '@kit.ArkData';
import { LanDropCore } from '../common/LanDropCore';
import { Peer, FileItem, TransferItem, platformLabel, platformIcon, formatSize } from '../model/Models';

@Entry
@Component
struct Index {
  @State peers: Peer[] = [];
  @State files: FileItem[] = [];
  @State transfers: TransferItem[] = [];
  @State running: boolean = false;
  @State status: string = '正在启动…';
  @State localIp: string = '—';
  @State tab: number = 0;
  @State selectedPeerId: string = '';
  @State showSettings: boolean = false;
  @State showText: boolean = false;
  @State textDraft: string = '';
  @State nameDraft: string = '';
  @State pinDraft: string = '';
  @State pinOn: boolean = false;
  @State busy: boolean = false;
  @State isWide: boolean = false;   // 平板/2in1 双栏
  @State isDesktop: boolean = deviceInfo.deviceType === '2in1' || deviceInfo.deviceType === 'pc';
  @State pinPeer: Peer | null = null;   // 需要输入配对码的对端
  @State pinValue: string = '';
  private mqListener: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(min-width: 720vp)');
  private hudOpened: boolean = false;
  @State hudFallback: boolean = true;   // 子窗口创建失败时才用应用内浮层

  private core: LanDropCore = LanDropCore.get();
  private timer: number = -1;
  private ctx: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    this.core.init(this.ctx);

    this.core.onPeers = () => {
      this.peers = this.core.peers.slice();
      if (this.selectedPeerId.length === 0 && this.peers.length > 0) {
        this.selectedPeerId = this.peers[0].id;
      }
    };
    this.core.onFiles = () => {
      this.files = this.core.files.slice();
    };
    this.core.onTransfers = () => {
      this.transfers = this.core.transfers.slice();
    };
    this.core.onStatus = (text: string) => {
      this.status = text;
    };
    this.core.onNeedPin = (peer: Peer) => {
      this.pinValue = '';
      this.pinPeer = peer;
    };

    this.mqListener.on('change', (res: mediaquery.MediaQueryResult) => {
      this.isWide = res.matches;
    });
    this.isWide = this.mqListener.matches;

    this.nameDraft = this.core.deviceName;
    this.pinDraft = this.core.pin;
    this.pinOn = this.core.pinEnabled;

    // 不能只看 deviceType：MatePad Edge 这类二合一上报的是 tablet
    // 手机不尝试；其余设备用能力探测（createSubWindow 成功才保留）
    if (deviceInfo.deviceType !== 'phone') {
      this.openHudWindow();
    }
    this.refreshLocal();
    this.core.start().then((ok: boolean) => {
      this.running = ok;
      this.core.refreshFiles();
      this.files = this.core.files.slice();
    });

    this.timer = setInterval(() => {
      this.core.prunePeers();
      this.core.pruneInbound();
      this.core.refreshFiles();
      this.running = this.core.running;
    }, 5000);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
    }
  }

  /** 2in1/PC：开一个真正的系统子窗口（悬浮在其他应用之上） */
  private async openHudWindow(): Promise<void> {
    if (this.hudOpened) {
      return;
    }
    const stage = AppStorage.get<window.WindowStage>('windowStage');
    if (stage === undefined) {
      return;
    }
    try {
      const hud = await stage.createSubWindow('lanDropHud');
      await hud.setUIContent('pages/HudPage');
      await hud.resize(320, 240);
      const dsp: display.Display = display.getDefaultDisplaySync();
      // 放到右下角，避免系统悬浮窗盖住应用顶栏的发送/设置按钮
      await hud.moveWindowTo(dsp.width - 352, dsp.height - 300);
      await hud.showWindow();
      this.hudOpened = true;
      this.hudFallback = false;
    } catch (e) {
      // 非 2in1 或系统拒绝时静默回退到应用内浮层
      hilog.warn(0x0001, 'LanDrop', 'subwindow unavailable: %{public}s', JSON.stringify(e));
    }
  }

  private async refreshLocal(): Promise<void> {
    this.localIp = await this.core.localIp();
  }

  private openSettings(): void {
    this.nameDraft = this.core.deviceName;
    this.pinDraft = this.core.pin;
    this.pinOn = this.core.pinEnabled;
    this.showSettings = true;
  }

  /** 对端开启配对码且本机还没存过：先弹输入框，避免白白上传失败 */
  private needPin(peer: Peer): boolean {
    if (peer.pinRequired && this.core.pinFor(peer).length === 0) {
      // 配对码弹层必须在最上层；先收起文本弹层，避免两个白色卡片叠在一起
      this.showText = false;
      this.pinValue = '';
      this.pinPeer = peer;
      return true;
    }
    return false;
  }

  /** 系统图库（无需存储权限） */
  private async pickFromGallery(): Promise<void> {
    const peer: Peer | null = this.currentPeer();
    if (peer === null) {
      promptAction.showToast({ message: '先选择一台设备' });
      return;
    }
    if (this.needPin(peer)) {
      return;
    }
    try {
      const photoPicker: picker.PhotoViewPicker = new picker.PhotoViewPicker();
      const result: picker.PhotoSelectResult = await photoPicker.select({
        maxSelectNumber: 9,
        MIMEType: picker.PhotoViewMIMETypes.IMAGE_TYPE
      });
      const uris: string[] = result.photoUris;
      if (uris.length > 0) {
        this.core.sendFiles(uris, peer);
        this.tab = 2;
      }
    } catch (e) {
      promptAction.showToast({ message: '打开图库失败' });
    }
  }

  private async pickAndSend(): Promise<void> {
    const peer: Peer | null = this.currentPeer();
    if (peer === null) {
      promptAction.showToast({ message: '先选择一台设备' });
      return;
    }
    if (this.needPin(peer)) {
      return;
    }
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(getContext(this) as common.UIAbilityContext);
      const uris: string[] = await documentPicker.select({ maxSelectNumber: 9 });
      if (uris.length > 0) {
        this.core.sendFiles(uris, peer);
        this.tab = 2;
      }
    } catch (e) {
      promptAction.showToast({ message: '选择文件失败' });
    }
  }

  private currentPeer(): Peer | null {
    for (let i = 0; i < this.peers.length; i++) {
      if (this.peers[i].id === this.selectedPeerId) {
        return this.peers[i];
      }
    }
    return this.peers.length > 0 ? this.peers[0] : null;
  }

  /** 拖拽直传：把系统拖入的文件发给对应设备 */
  private handleDrop(event: DragEvent, peer: Peer): void {
    const data: unifiedDataChannel.UnifiedData | undefined = event.getData();
    if (data === undefined) {
      return;
    }
    const uris: string[] = [];
    const records: unifiedDataChannel.UnifiedRecord[] = data.getRecords();
    for (let i = 0; i < records.length; i++) {
      const rec: unifiedDataChannel.UnifiedRecord = records[i];
      if (rec.getType() === uniformTypeDescriptor.UniformDataType.FILE) {
        const file: unifiedDataChannel.File = rec as unifiedDataChannel.File;
        if (file.uri.length > 0) {
          uris.push(file.uri);
        }
      }
    }
    if (uris.length > 0) {
      this.core.sendFiles(uris, peer);
      this.tab = 2;
      promptAction.showToast({ message: '已发送给 ' + peer.name });
    }
  }

  /** 另存到系统「下载」（三方应用不能静默写公开目录，必须走系统保存器） */
  private async saveToDownloads(item: FileItem): Promise<void> {
    if (this.ctx === null) {
      return;
    }
    try {
      const savePicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.ctx);
      const uris: string[] = await savePicker.save({ newFileNames: [item.name] });
      if (uris.length === 0) {
        return;
      }
      const src = fs.openSync(item.path, fs.OpenMode.READ_ONLY);
      const dst = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const chunk: number = 1024 * 1024;
        let offset: number = 0;
        const total: number = fs.statSync(item.path).size;
        while (offset < total) {
          const want: number = Math.min(chunk, total - offset);
          const buf: ArrayBuffer = new ArrayBuffer(want);
          const read: number = fs.readSync(src.fd, buf, { offset: offset, length: want });
          if (read <= 0) {
            break;
          }
          fs.writeSync(dst.fd, buf.slice(0, read));
          offset += read;
        }
      } finally {
        fs.closeSync(src);
        fs.closeSync(dst);
      }
      promptAction.showToast({ message: '已保存到下载' });
    } catch (e) {
      promptAction.showToast({ message: '保存失败：' + (e as Error).message });
    }
  }

  private openFile(item: FileItem): void {
    if (this.ctx === null) {
      return;
    }
    // 沙箱文件必须转成 fileUri 并显式授予读权限，否则系统应用打不开
    let uri: string = '';
    try {
      uri = fileUri.getUriFromPath(item.path);
    } catch (e) {
      promptAction.showToast({ message: '路径无效' });
      return;
    }
    this.ctx.startAbility({
      action: 'ohos.want.action.viewData',
      uri: uri,
      type: 'general.file',
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    }).catch(() => {
      promptAction.showToast({ message: '没有可打开该文件的应用' });
    });
  }

  // MARK: - UI

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        this.header()
        if (this.isWide) {
          Row({ space: 0 }) {
            Column() {
              this.devicesPane()
            }
            .width('38%')
            .height('100%')

            Column() {
              this.tabs()
              if (this.tab === 0) {
                Column() { this.transfersPane() }
                  .layoutWeight(1).width('100%')
                  .transition(TransitionEffect.OPACITY.animation({ duration: 180 }).combine(TransitionEffect.translate({ y: 10 }).animation({ duration: 180 })))
              } else if (this.tab === 1) {
                Column() { this.inboxPane() }
                  .layoutWeight(1).width('100%')
                  .transition(TransitionEffect.OPACITY.animation({ duration: 180 }).combine(TransitionEffect.translate({ y: 10 }).animation({ duration: 180 })))
              } else {
                Column() { this.transfersPane() }
                  .layoutWeight(1).width('100%')
                  .transition(TransitionEffect.OPACITY.animation({ duration: 180 }).combine(TransitionEffect.translate({ y: 10 }).animation({ duration: 180 })))
              }
            }
            .layoutWeight(1)
            .height('100%')
            .border({ width: { left: 1 }, color: '#EAECF0' })
          }
          .layoutWeight(1)
          .width('100%')
        } else {
          this.tabs()
          if (this.tab === 0) {
            Column() { this.devicesPane() }
              .layoutWeight(1).width('100%')
              .transition(TransitionEffect.OPACITY.animation({ duration: 180 }).combine(TransitionEffect.translate({ y: 10 }).animation({ duration: 180 })))
          } else if (this.tab === 1) {
            Column() { this.inboxPane() }
              .layoutWeight(1).width('100%')
              .transition(TransitionEffect.OPACITY.animation({ duration: 180 }).combine(TransitionEffect.translate({ y: 10 }).animation({ duration: 180 })))
          } else {
            Column() { this.transfersPane() }
              .layoutWeight(1).width('100%')
              .transition(TransitionEffect.OPACITY.animation({ duration: 180 }).combine(TransitionEffect.translate({ y: 10 }).animation({ duration: 180 })))
          }
        }
        this.bottomBar()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: this.isWide ? 1280 : '100%' })
      .backgroundColor('#F4F5F9')

      if (this.isDesktop && this.hudFallback) {
        Column() {
          this.floatHud()
        }
        .position({ right: 24, bottom: 90 })
        .zIndex(20)
      }

      if (this.showSettings) {
        this.settingsOverlay()
      }
      if (this.showText) {
        this.textOverlay()
      }
      if (this.pinPeer !== null) {
        this.pinOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  header() {
    Row({ space: 12 }) {
      Column() {
        Text('⇅')
          .fontSize(26)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
      }
      .width(52)
      .height(52)
      .borderRadius(26)
      .linearGradient({ angle: 135, colors: [['#4C8DFF', 0.0], ['#8B5CF6', 1.0]] })
      .justifyContent(FlexAlign.Center)

      Column({ space: 4 }) {
        Text(this.core.deviceName)
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#101828')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 8 }) {
          Row({ space: 5 }) {
            Circle().width(7).height(7).fill(this.running ? '#22C55E' : '#9CA3AF')
            Text(this.running ? this.localIp + ':47823' : '未启动')
              .fontSize(11)
              .fontColor('#667085')
          }
          if (this.core.pinEnabled) {
            Text('锁 ' + this.core.pin)
              .fontSize(10)
              .fontColor('#B45309')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor('#FEF3C7')
              .borderRadius(6)
          }
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button(this.running ? '停止' : '启动')
        .fontSize(12)
        .height(30)
        .backgroundColor(this.running ? '#FEE4E2' : '#DCFCE7')
        .fontColor(this.running ? '#B42318' : '#15803D')
        .onClick(() => {
          if (this.running) {
            this.core.stop();
            this.running = false;
          } else {
            this.core.start().then((ok: boolean) => {
              this.running = ok;
              // 不能只看 deviceType：MatePad Edge 这类二合一上报的是 tablet
              // 手机不尝试；其余设备用能力探测（createSubWindow 成功才保留）
              if (deviceInfo.deviceType !== 'phone') {
                this.openHudWindow();
              }
              this.refreshLocal();
            });
          }
        })

      Text('设置')
        .fontSize(11)
        .fontColor('#344054')
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .backgroundColor('#EEF2F6')
        .borderRadius(9)
        .onClick(() => {
          this.openSettings();
        })
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 16, bottom: 14 })
    .backgroundColor(Color.White)
  }

  @Builder
  tabs() {
    Row({ space: 6 }) {
      this.tabButton('设备', 0, this.peers.length > 0 ? this.peers.length.toString() : '')
      this.tabButton('收件箱', 1, this.files.length > 0 ? this.files.length.toString() : '')
      this.tabButton('传输', 2, '')
      Blank()
      if (this.tab === 0) {
        Button('文本')
          .fontSize(12)
          .height(30)
          .backgroundColor('#EEF2F6')
          .fontColor('#344054')
          .onClick(() => {
            if (this.currentPeer() === null) {
              promptAction.showToast({ message: '先选择一台设备' });
              return;
            }
            this.showText = true;
          })
        Button('＋ 发送')
          .fontSize(12)
          .height(30)
          .backgroundColor('#0A84FF')
          .fontColor(Color.White)
          .bindMenu([
            { value: '从图库选择', action: () => { this.pickFromGallery(); } },
            { value: '从文件选择', action: () => { this.pickAndSend(); } }
          ])
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
  }

  @Builder
  tabButton(title: string, index: number, badge: string) {
    Row({ space: 4 }) {
      Text(title)
        .fontSize(12)
        .fontColor(this.tab === index ? Color.White : '#475467')
        .fontWeight(this.tab === index ? FontWeight.Medium : FontWeight.Normal)
      if (badge.length > 0) {
        Text(badge)
          .fontSize(9)
          .fontColor(this.tab === index ? Color.White : '#667085')
          .backgroundColor(this.tab === index ? '#FFFFFF33' : '#EAECF0')
          .padding({ left: 4, right: 4 })
          .borderRadius(4)
      }
    }
    .padding({ left: 12, right: 12, top: 5, bottom: 5 })
    .backgroundColor(this.tab === index ? '#101828' : Color.White)
    .borderRadius(14)
    .onClick(() => {
      this.tab = index;
    })
  }

  @Builder
  devicesPane() {
    if (this.peers.length === 0) {
      this.emptyState('↑↓', '还没有发现设备',
        '确认对方已打开 LanDrop，并和本机连同一个 Wi-Fi。\n鸿蒙端与 Mac/安卓端使用同一套 UDP 广播发现。')
    } else {
      List({ space: 8 }) {
        ForEach(this.peers, (peer: Peer) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(peer.platform === 'macos' ? 'M' : (peer.platform === 'android' ? 'A' : 'H'))
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor('#5E6FF7')
                .width(38)
                .height(38)
                .textAlign(TextAlign.Center)
                .backgroundColor('#EEF1FF')
                .borderRadius(19)

              Column({ space: 2 }) {
                Row({ space: 5 }) {
                  Text(peer.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#101828')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
                  if (peer.pinRequired) {
                    Text('锁').fontSize(9)
                  }
                }
                Text(platformLabel(peer.platform) + ' · ' + peer.host + ':' + peer.port.toString())
                  .fontSize(10)
                  .fontColor('#98A2B3')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Row({ space: 6 }) {
                Button('图库')
                  .fontSize(11)
                  .height(28)
                  .backgroundColor('#EEF2F6')
                  .fontColor('#344054')
                  .onClick(() => {
                    this.selectedPeerId = peer.id;
                    this.pickFromGallery();
                  })
                Button('文件')
                  .fontSize(11)
                  .height(28)
                  .backgroundColor(this.selectedPeerId === peer.id ? '#0A84FF' : '#EEF2F6')
                  .fontColor(this.selectedPeerId === peer.id ? Color.White : '#344054')
                  .onClick(() => {
                    this.selectedPeerId = peer.id;
                    this.pickAndSend();
                  })
              }
            }
            .padding(12)
            .backgroundColor(Color.White)
            .borderRadius(14)
            .border({ width: this.selectedPeerId === peer.id ? 1.5 : 0, color: '#0A84FF' })
            .onClick(() => {
              this.selectedPeerId = peer.id;
            })
            .animation({ duration: 180, curve: Curve.EaseOut })
            .allowDrop([uniformTypeDescriptor.UniformDataType.FILE])
            .onDrop((event: DragEvent, extraParams: string) => {
              this.handleDrop(event, peer);
            })
          }
        }, (peer: Peer) => peer.id)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 14, right: 14, top: 4 })
    }
  }

  @Builder
  inboxPane() {
    if (this.files.length === 0) {
      this.emptyState('↓', '收件箱是空的', '别人发来的文件会出现在这里（应用沙箱 inbox 目录）。')
    } else {
      List({ space: 6 }) {
        ForEach(this.files, (item: FileItem) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(item.kind === 'text' ? 'T' : 'F')
                .fontSize(18)
                .width(34)
                .height(34)
                .textAlign(TextAlign.Center)
                .backgroundColor('#F2F4F7')
                .borderRadius(10)

              Column({ space: 2 }) {
                Text(item.name).fontSize(13).fontColor('#101828').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(formatSize(item.size) + ' · ' + new Date(item.mtime).toLocaleTimeString())
                  .fontSize(10)
                  .fontColor('#98A2B3')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Button('打开')
                .fontSize(11).height(26).backgroundColor('#EEF2F6').fontColor('#344054')
                .onClick(() => {
                  this.openFile(item);
                })
              Button('存到下载')
                .fontSize(11).height(26).backgroundColor('#EEF2F6').fontColor('#344054')
                .onClick(() => {
                  this.saveToDownloads(item);
                })
              Button('删')
                .fontSize(11).height(26).backgroundColor('#FEE4E2').fontColor('#B42318')
                .onClick(() => {
                  this.core.removeFile(item);
                  this.files = this.core.files.slice();
                })
            }
            .padding(11)
            .backgroundColor(Color.White)
            .borderRadius(12)
          }
        }, (item: FileItem) => item.id + item.size.toString())
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 14, right: 14, top: 4 })
    }
  }

  @Builder
  transfersPane() {
    if (this.transfers.length === 0) {
      this.emptyState('↓', '还没有传输记录', '选择设备后点「＋ 发送」，或发送一段文本。')
    } else {
      List({ space: 6 }) {
        ForEach(this.transfers, (t: TransferItem) => {
          ListItem() {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Text(t.direction === 'send' ? '↑' : '↓').fontSize(14).fontColor('#5E6FF7')
                Text(t.fileName)
                  .fontSize(12).fontColor('#101828').layoutWeight(1)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(t.peerName).fontSize(10).fontColor('#98A2B3')
              }
              .width('100%')

              if (t.state === 'running' || t.state === 'paused') {
                Row({ space: 8 }) {
                  Progress({ value: t.progress * 100, total: 100, type: ProgressType.Linear })
                    .color(t.state === 'paused' ? '#F59E0B' : '#0A84FF')
                    .layoutWeight(1)
                    .animation({ duration: 200, curve: Curve.EaseOut })
                  Text(t.state === 'paused'
                    ? ((t.error.length > 0 ? t.error : '已暂停') + ' · ' + Math.round(t.progress * 100).toString() + '%')
                    : Math.round(t.progress * 100).toString() + '% · ' + t.speedText)
                    .fontSize(10).fontColor(t.state === 'paused' ? '#B45309' : '#667085')
                  if (t.direction === 'send') {
                    Text(t.state === 'paused' ? '继续' : '暂停')
                      .fontSize(10).fontColor('#344054')
                      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                      .backgroundColor('#EEF2F6').borderRadius(6)
                      .onClick(() => {
                        if (t.state === 'paused') {
                          this.core.resumeTransfer(t);
                        } else {
                          this.core.pauseTransfer(t);
                        }
                      })
                  }
                  Text('取消')
                    .fontSize(10).fontColor('#B42318')
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .backgroundColor('#FEE4E2').borderRadius(6)
                    .onClick(() => {
                      if (t.direction === 'send') {
                        this.core.cancelTransfer(t);
                      } else {
                        this.core.cancelReceive(t);
                      }
                    })
                }
                .width('100%')
              } else {
                Row({ space: 8 }) {
                  Text(t.state === 'done' ? '已完成 · ' + formatSize(t.total)
                    : (t.error.length > 0 ? t.error : '失败'))
                    .fontSize(10)
                    .fontColor(t.state === 'done' ? '#15803D' : '#B42318')
                    .layoutWeight(1)
                }
                .width('100%')
              }
            }
            .padding(11)
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
          }
        }, (t: TransferItem) => t.id + '_' + Math.round(t.progress * 100).toString() + '_' + t.state)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 14, right: 14, top: 4 })
    }
  }

  /** 类 Mac 的传输悬浮窗（2in1 / PC 默认显示） */
  @Builder
  floatHud() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text('⇅')
          .fontSize(12).fontColor(Color.White)
          .width(18).height(18).textAlign(TextAlign.Center)
          .backgroundColor('#5E6FF7').borderRadius(9)
        Text(this.transfers.length > 0 ? '正在传输 ' + this.transfers.length.toString() + ' 项' : 'LanDrop')
          .fontSize(11).fontWeight(FontWeight.Medium).layoutWeight(1)
        Text(this.running ? '●' : '○')
          .fontSize(10).fontColor(this.running ? '#22C55E' : '#98A2B3')
      }
      .width('100%')

      if (this.transfers.length === 0) {
        Text('暂无进行中的传输')
          .fontSize(10).fontColor('#98A2B3').width('100%')
      } else {
        ForEach(this.transfers.slice(0, 3), (t: TransferItem) => {
          Column({ space: 4 }) {
            Row({ space: 6 }) {
              Text(t.direction === 'send' ? '↑' : '↓').fontSize(10).fontColor('#5E6FF7')
              Text(t.fileName).fontSize(10.5)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (t.state === 'running') {
                Text('取消')
                  .fontSize(9).fontColor('#B42318')
                  .onClick(() => {
                    if (t.direction === 'send') {
                      this.core.cancelTransfer(t);
                    } else {
                      this.core.cancelReceive(t);
                    }
                  })
              }
            }
            .width('100%')
            Progress({ value: t.progress * 100, total: 100, type: ProgressType.Linear })
              .color('#0A84FF').width('100%')
              .animation({ duration: 200, curve: Curve.EaseOut })
            Text(Math.round(t.progress * 100).toString() + '% · ' + t.speedText)
              .fontSize(9).fontColor('#667085').width('100%').textAlign(TextAlign.End)
          }
          .width('100%').padding(8)
          .backgroundColor('#FFFFFF').borderRadius(10)
        }, (t: TransferItem) => t.id + '_' + Math.round(t.progress * 100).toString() + '_' + t.state)
      }
    }
    .width(260)
    .padding(12)
    .backgroundColor('#F2FFFFFF')
    .borderRadius(16)
    .shadow({ radius: 24, color: '#33000000', offsetY: 6 })
    .onClick(() => {
      this.tab = 2;
    })
  }

  @Builder
  emptyState(icon: string, title: string, subtitle: string) {
    Column({ space: 10 }) {
      Text(icon).fontSize(40)
      Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#344054')
      Text(subtitle).fontSize(11).fontColor('#98A2B3').textAlign(TextAlign.Center).lineHeight(17)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding(30)
  }

  @Builder
  bottomBar() {
    Column({ space: 2 }) {
      Text(this.status).fontSize(10).fontColor('#667085')
      Text('收件箱 · ' + this.core.inboxPath)
        .fontSize(9)
        .fontColor('#98A2B3')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 10 })
    .backgroundColor('#EDEFF5')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 弹层

  @Builder
  settingsOverlay() {
    Column() {
      Column({ space: 16 }) {
        Text('设置').fontSize(17).fontWeight(FontWeight.Bold)
        Column({ space: 6 }) {
          Text('设备名').fontSize(11).fontColor('#667085')
          TextInput({ text: this.nameDraft })
            .onChange((v: string) => {
              this.nameDraft = v;
            })
            .height(40)
        }
        .alignItems(HorizontalAlign.Start)

        Row() {
          Column({ space: 2 }) {
            Text('配对码保护').fontSize(13).fontColor('#101828')
            Text('对方发送前需输入 6 位数字').fontSize(10).fontColor('#98A2B3')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.pinOn })
            .onChange((v: boolean) => {
              this.pinOn = v;
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          TextInput({ text: this.pinDraft })
            .height(40)
            .layoutWeight(1)
            .enabled(this.pinOn)
            .onChange((v: string) => {
              this.pinDraft = v;
            })
          Button('换一个')
            .height(40)
            .fontSize(12)
            .backgroundColor('#EEF2F6')
            .fontColor('#344054')
            .onClick(() => {
              this.pinDraft = this.core.regeneratePin();
              this.core.pinEnabled = this.pinOn;
            })
        }

        Text('协议为明文 HTTP，配对码只用于防误触，不加密内容。仅建议在可信局域网使用。')
          .fontSize(10)
          .fontColor('#98A2B3')
          .lineHeight(15)

        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1)
            .height(42)
            .backgroundColor('#EEF2F6')
            .fontColor('#344054')
            .onClick(() => {
              this.showSettings = false;
            })
          Button('保存')
            .layoutWeight(1)
            .height(42)
            .backgroundColor('#0A84FF')
            .onClick(() => {
              this.core.applySettings(this.nameDraft, this.pinDraft, this.pinOn);
              this.showSettings = false;
              promptAction.showToast({ message: '已保存' });
            })
        }
        .width('100%')
      }
      .padding(20)
      .width('88%')
      .backgroundColor(Color.White)
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#00000066')
    .justifyContent(FlexAlign.Center)
    .transition(TransitionEffect.OPACITY.animation({ duration: 180 })
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })))
  }

  @Builder
  pinOverlay() {
    Column() {
      Column({ space: 14 }) {
        Text('输入配对码').fontSize(17).fontWeight(FontWeight.Bold)
        Text('「' + (this.pinPeer === null ? '' : this.pinPeer.name) + '」开启了配对码保护，请输入对方窗口顶部显示的 6 位数字。')
          .fontSize(10)
          .fontColor('#98A2B3')
          .lineHeight(15)
        TextInput({ text: this.pinValue, placeholder: '6 位数字' })
          .type(InputType.Number)
          .maxLength(6)
          .height(44)
          .fontSize(20)
          .textAlign(TextAlign.Center)
          .onChange((v: string) => {
            this.pinValue = v;
          })
        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1)
            .height(42)
            .backgroundColor('#EEF2F6')
            .fontColor('#344054')
            .onClick(() => {
              this.pinPeer = null;
              this.pinValue = '';
            })
          Button('保存')
            .layoutWeight(1)
            .height(42)
            .backgroundColor('#0A84FF')
            .enabled(this.pinValue.length === 6)
            .onClick(() => {
              const peer: Peer | null = this.pinPeer;
              if (peer !== null && this.pinValue.length === 6) {
                this.core.setPeerPin(peer.id, this.pinValue);
                this.pinPeer = null;
                this.pinValue = '';
                promptAction.showToast({ message: '配对码已保存，请重新发送' });
              }
            })
        }
        .width('100%')
      }
      .padding(20)
      .width('88%')
      .backgroundColor(Color.White)
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#00000066')
    .justifyContent(FlexAlign.Center)
    .transition(TransitionEffect.OPACITY.animation({ duration: 180 })
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })))
  }

  @Builder
  textOverlay() {
    Column() {
      Column({ space: 14 }) {
        Text('发送文本').fontSize(17).fontWeight(FontWeight.Bold)
        Text('文本会落成 .txt 存进对方收件箱')
          .fontSize(10)
          .fontColor('#98A2B3')
        TextArea({ text: this.textDraft, placeholder: '链接、验证码、一段配置…' })
          .height(160)
          .onChange((v: string) => {
            this.textDraft = v;
          })
        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1)
            .height(42)
            .backgroundColor('#EEF2F6')
            .fontColor('#344054')
            .onClick(() => {
              this.showText = false;
            })
          Button('发送')
            .layoutWeight(1)
            .height(42)
            .backgroundColor('#0A84FF')
            .enabled(this.textDraft.length > 0)
            .onClick(() => {
              const peer: Peer | null = this.currentPeer();
              if (peer !== null && !this.needPin(peer)) {
                this.core.sendText(this.textDraft, peer);
                this.textDraft = '';
                this.showText = false;
                this.tab = 2;
              }
            })
        }
        .width('100%')
      }
      .padding(20)
      .width('88%')
      .backgroundColor(Color.White)
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#00000066')
    .justifyContent(FlexAlign.Center)
    .transition(TransitionEffect.OPACITY.animation({ duration: 180 })
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })))
  }
}
