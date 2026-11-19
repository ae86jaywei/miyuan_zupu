import { webview } from '@kit.ArkWeb';
import { T, uiFontFamily } from 'common_base';
import { Theme, Spacing } from 'common_base';
import { PageHeader } from 'common_ui';
import { OnlineDocParams } from 'common_base';

/**
 * 在线协议页：应用内直接加载服务器上的用户协议 / 隐私声明，不跳系统浏览器。
 * 路由参数：title 标题，url 协议地址。
 */
@Entry
@Component
struct OnlineDoc {
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;
  @State title: string = '';
  @State url: string = '';
  @State failed: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    const params: OnlineDocParams | undefined =
      this.getUIContext().getRouter().getParams() as OnlineDocParams | undefined;
    if (params !== undefined) {
      this.title = params.title !== undefined ? params.title : '';
      this.url = params.url !== undefined ? params.url : '';
    }
  }

  build() {
    Column() {
      PageHeader({
        title: this.title.length > 0 ? this.title : T('在线协议'),
        onBack: (): void => {
          this.getUIContext().getRouter().back();
        }
      })

      if (this.url.length > 0 && !this.failed) {
        Web({ src: this.url, controller: this.controller })
          .width('100%')
          .layoutWeight(1)
          .backgroundColor(Theme.paper)
          .onErrorReceive((): void => {
            this.failed = true;
          })
      } else {
        Column() {
          Text(T(this.failed ? '协议加载失败，请检查网络后重试' : '协议地址无效'))
            .fontFamily(uiFontFamily())
            .fontSize(14)
            .fontColor(Theme.inkSecondary)
        }
        .width('100%')
        .layoutWeight(1)
        .padding(Spacing.L)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.paper)
  }
}
