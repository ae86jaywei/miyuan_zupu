import { T, uiFontFamily } from '../service/ScriptService';
import { Theme, Spacing } from 'common_base';
import { PageHeader } from '../components/PageHeader';
import { AgreementDoc, AgreementParams, AgreementSection, agreementDocOf } from 'common_base';

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
      PageHeader({
        title: this.doc.title,
        onBack: (): void => {
          this.getUIContext().getRouter().back();
        }
      })

      Scroll() {
        Column() {
          Text(T(this.doc.title)).fontFamily(uiFontFamily())
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.ink)
            .width('100%')
          Text(T(this.doc.intro)).fontFamily(uiFontFamily())
            .fontSize(13)
            .fontColor(Theme.inkSecondary)
            .lineHeight(21)
            .width('100%')
            .margin({ top: Spacing.M })

          ForEach(this.doc.sections, (section: AgreementSection) => {
            Column() {
              Text(T(section.heading)).fontFamily(uiFontFamily())
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.ink)
                .width('100%')
              Text(T(section.body)).fontFamily(uiFontFamily())
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
