import { window } from '@kit.ArkUI';
import { LanDropCore } from '../common/LanDropCore';
import { TransferItem } from '../model/Models';

/** 2in1 / PC 上的传输悬浮子窗口内容 */
@Entry
@Component
struct HudPage {
  @State transfers: TransferItem[] = [];
  @State running: boolean = false;
  private core: LanDropCore = LanDropCore.get();
  private timer: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.timer = setInterval(() => {
      this.refresh();
    }, 500);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
    }
  }

  private refresh(): void {
    this.transfers = this.core.transfers.slice();
    this.running = this.core.running;
  }

  private close(): void {
    const stage = AppStorage.get<window.WindowStage>('windowStage');
    if (stage !== undefined) {
      stage.getSubWindow().then((list: window.Window[]) => {
        list.forEach((w: window.Window) => {
          w.destroyWindow();
        });
      }).catch(() => {
      });
    }
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text('⇅')
          .fontSize(12).fontColor(Color.White)
          .width(18).height(18).textAlign(TextAlign.Center)
          .backgroundColor('#5E6FF7').borderRadius(9)
        Text(this.transfers.length > 0 ? '正在传输 ' + this.transfers.length.toString() + ' 项' : 'LanDrop')
          .fontSize(11).fontWeight(FontWeight.Medium).layoutWeight(1)
        Text('✕')
          .fontSize(11).fontColor('#98A2B3')
          .onClick(() => {
            this.close();
          })
      }
      .width('100%')

      if (this.transfers.length === 0) {
        Text(this.running ? '暂无进行中的传输' : '未启动')
          .fontSize(10).fontColor('#98A2B3').width('100%')
      } else {
        ForEach(this.transfers.slice(0, 3), (t: TransferItem) => {
          Column({ space: 4 }) {
            Row({ space: 6 }) {
              Text(t.direction === 'send' ? '⬆️' : '⬇️').fontSize(10)
              Text(t.fileName).fontSize(10.5).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (t.state === 'running') {
                Text('取消').fontSize(9).fontColor('#B42318')
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
    .width('100%').height('100%')
    .padding(12)
    .backgroundColor('#F2F4F7')
  }
}
