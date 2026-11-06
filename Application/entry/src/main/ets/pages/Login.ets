import { common } from '@kit.AbilityKit';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { BackButton } from '../components/BackButton';
import { AccountService, LoginOutcome } from '../service/AccountService';

/**
 * 华为账号登录页。
 *
 * 交互：
 * 1. 进入页面先尝试静默登录（forceLogin = false），已授权用户无感完成登录；
 * 2. 静默登录失败（如 1001502001 华为账号未登录）时展示手动登录按钮；
 * 3. 首次使用可选择“暂不登录，先本地使用”，之后不再自动弹出登录页。
 */
@Entry
@Component
struct Login {
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;
  @StorageProp('gpLogin') loggedIn: boolean = false;

  @State agreed: boolean = false;
  @State busy: boolean = false;
  @State statusText: string = '';
  @State autoTried: boolean = false;

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    this.autoLogin();
  }

  private hostContext(): common.UIAbilityContext | null {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined || ctx === null) {
      return null;
    }
    return ctx as common.UIAbilityContext;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  /** 进入页面先尝试静默登录 */
  private async autoLogin(): Promise<void> {
    if (this.autoTried) {
      return;
    }
    this.autoTried = true;
    const ctx: common.UIAbilityContext | null = this.hostContext();
    if (ctx === null) {
      this.statusText = '登录环境初始化失败';
      return;
    }
    await AccountService.getInstance().init(ctx);
    this.busy = true;
    this.statusText = '正在尝试静默登录…';
    const outcome: LoginOutcome = await AccountService.getInstance().trySilentLogin();
    this.busy = false;
    if (outcome.success) {
      this.toast('华为账号登录成功');
      this.getUIContext().getRouter().back();
      return;
    }
    this.statusText = outcome.needsManualLogin
      ? '华为账号未登录，请点击下方按钮完成登录'
      : outcome.message;
  }

  /** 手动登录：需先勾选协议 */
  private async manualLogin(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (!this.agreed) {
      this.toast('请先阅读并同意用户协议与隐私政策');
      return;
    }
    const ctx: common.UIAbilityContext | null = this.hostContext();
    if (ctx === null) {
      return;
    }
    await AccountService.getInstance().init(ctx);
    this.busy = true;
    this.statusText = '正在拉起华为账号登录…';
    const outcome: LoginOutcome = await AccountService.getInstance().login();
    this.busy = false;
    this.statusText = outcome.message;
    if (outcome.success) {
      this.toast('华为账号登录成功');
      this.getUIContext().getRouter().back();
    }
  }

  /** 跳过登录，仅使用本地功能 */
  private skip(): void {
    AccountService.getInstance().setLoginSkipped(true);
    this.getUIContext().getRouter().back();
  }

  build() {
    Column() {
      Row() {
        BackButton({
          onBack: (): void => {
            this.getUIContext().getRouter().back();
          }
        })
        Text('华为账号登录')
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
          Column() {
            Text('谱')
              .fontSize(32)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .width(72)
              .height(72)
              .textAlign(TextAlign.Center)
              .backgroundColor(Theme.primary)
              .borderRadius(20)
            Text('登录后可云端备份族谱')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.ink)
              .margin({ top: Spacing.L })
            Text('使用华为账号一键登录，族谱成员、照片与视频将安全保存到云端，换机或重装后可恢复。')
              .fontSize(12)
              .fontColor(Theme.inkTertiary)
              .textAlign(TextAlign.Center)
              .margin({ top: Spacing.S })
              .lineHeight(19)
          }
          .width('100%')
          .padding({ top: Spacing.XXL, bottom: Spacing.XL })

          Column() {
            Row() {
              Checkbox({ name: 'agreement', group: 'login' })
                .select(this.agreed)
                .selectedColor(Theme.primary)
                .onChange((isSelected: boolean): void => {
                  this.agreed = isSelected;
                })
              Text('我已阅读并同意')
                .fontSize(12)
                .fontColor(Theme.inkSecondary)
                .margin({ left: Spacing.XS })
              Text('《用户协议》')
                .fontSize(12)
                .fontColor(Theme.primary)
              Text('与')
                .fontSize(12)
                .fontColor(Theme.inkSecondary)
              Text('《隐私政策》')
                .fontSize(12)
                .fontColor(Theme.primary)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Button(this.busy ? '登录中…' : '华为账号一键登录')
              .width('100%')
              .height(44)
              .fontSize(15)
              .fontColor('#FFFFFF')
              .backgroundColor(this.agreed && !this.busy ? Theme.primary : Theme.inkTertiary)
              .borderRadius(Radius.M)
              .margin({ top: Spacing.L })
              .enabled(this.agreed && !this.busy)
              .onClick((): void => {
                this.manualLogin();
              })

            Button('暂不登录，先本地使用')
              .width('100%')
              .height(44)
              .fontSize(14)
              .fontColor(Theme.inkSecondary)
              .backgroundColor(Theme.field)
              .borderRadius(Radius.M)
              .margin({ top: Spacing.S })
              .enabled(!this.busy)
              .onClick((): void => {
                this.skip();
              })

            if (this.statusText.length > 0) {
              Text(this.statusText)
                .fontSize(11)
                .fontColor(Theme.inkTertiary)
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ top: Spacing.M })
                .maxLines(3)
            }

            Text('登录状态由华为账号服务提供，应用仅保存 UnionID 作为账号标识，不保存 authorizationCode。')
              .fontSize(10)
              .fontColor(Theme.inkTertiary)
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: Spacing.L })
              .lineHeight(16)
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
          .backgroundColor(Theme.card)
          .borderRadius(16)
          .border({ width: 0.5, color: Theme.line })
        }
        .width('100%')
        .constraintSize({ maxWidth: 480 })
        .padding({ left: Spacing.L, right: Spacing.L, bottom: 60 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.paper)
  }
}
