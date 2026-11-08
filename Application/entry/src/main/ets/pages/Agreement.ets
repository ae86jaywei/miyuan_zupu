import { Theme, Spacing } from '../theme/Theme';
import { BackButton } from '../components/BackButton';
import { AgreementDoc, AgreementParams, AgreementSection, agreementDocOf } from '../model/AgreementDoc';

/**
 * 用户协议 / 隐私政策展示页。
 * 路由参数 type：user = 用户协议，privacy = 隐私政策。
 */
@Entry
@Component
struct Agreement {
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;
  @State doc: AgreementDoc = agreementDocOf('privacy');

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    const params: AgreementParams | undefined =
      this.getUIContext().getRouter().getParams() as AgreementParams | undefined;
    const type: string = params !== undefined && params.type !== undefined ? params.type : 'privacy';
    this.doc = agreementDocOf(type);
  }

  build() {
    Column() {
      Row() {
        BackButton({
          onBack: (): void => {
            this.getUIContext().getRouter().back();
          }
        })
        Text(this.doc.title)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
      }
      .width('100%')
      .height(34)
      .padding({ left: Spacing.S, right: Spacing.L })
      .backgroundColor(Theme.card)
      .border({ width: { bottom: 0.5 }, color: Theme.line })

      Scroll() {
        Column() {
          Text(this.doc.title)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.ink)
            .width('100%')
          Text(this.doc.intro)
            .fontSize(13)
            .fontColor(Theme.inkSecondary)
            .lineHeight(21)
            .width('100%')
            .margin({ top: Spacing.M })

          ForEach(this.doc.sections, (section: AgreementSection) => {
            Column() {
              Text(section.heading)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.ink)
                .width('100%')
              Text(section.body)
                .fontSize(13)
                .fontColor(Theme.inkSecondary)
                .lineHeight(21)
                .width('100%')
                .margin({ top: 8 })
            }
            .width('100%')
            .margin({ top: Spacing.L })
          }, (section: AgreementSection) => section.heading)
        }
        .width('100%')
        .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: 40 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.paper)
  }
}
