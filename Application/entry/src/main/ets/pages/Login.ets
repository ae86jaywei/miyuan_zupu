import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { loginComponentManager, LoginPanel } from '@kit.AccountKit';
import { AccountService, LoginOutcome } from '../service/AccountService';
import { RouterUtil } from '../util/RouterUtil';

/**
 * 华为账号登录页。
 *
 * 使用 Account Kit 提供的原生登录面板组件 LoginPanel：
 * 1. 面板内由华为账号服务原生渲染「华为账号一键登录」按钮与协议勾选框（《用户协议》《隐私政策》《华为账号用户认证协议》）；
 * 2. 协议状态每次进入都重置为未同意，用户必须主动勾选并点击登录，未勾选时由系统弹出原生协议对话框，满足每次登录都要确认协议的要求；
 * 3. 页面不再自动静默登录，保证用户始终能看到并操作登录面板。
 */
@Entry
@Component
struct Login {
  /** 是否显示原生登录面板，由组件内部关闭按钮置为 false */
  @State showPanel: boolean = true;

  private controller: loginComponentManager.LoginPanelController = new loginComponentManager.LoginPanelController();

  private panelParams: loginComponentManager.LoginPanelParams = {
    appInfo: {
      appIcon: $r('app.media.layered_image'),
      appName: $r('app.string.EntryAbility_label'),
      appDescription: $r('app.string.EntryAbility_desc')
    },
    privacyText: [
      {
        type: loginComponentManager.TextType.PLAIN_TEXT,
        text: '我已阅读并同意'
      },
      {
        type: loginComponentManager.TextType.RICH_TEXT,
        text: '《用户协议》',
        tag: 'user_agreement'
      },
      {
        type: loginComponentManager.TextType.PLAIN_TEXT,
        text: '、'
      },
      {
        type: loginComponentManager.TextType.RICH_TEXT,
        text: '《隐私政策》',
        tag: 'privacy_policy'
      },
      {
        type: loginComponentManager.TextType.PLAIN_TEXT,
        text: '和'
      },
      {
        type: loginComponentManager.TextType.RICH_TEXT,
        text: '《华为账号用户认证协议》',
        tag: 'hwid_agreement'
      }
    ],
    loginType: loginComponentManager.LoginType.ID
  };

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined && ctx !== null) {
      AccountService.getInstance().init(ctx as common.UIAbilityContext);
    }
    // 协议状态每次重置为未同意，确保每次登录都需用户主动确认
    this.controller.setAgreementStatus(loginComponentManager.AgreementStatus.NOT_ACCEPTED);
    this.controller.onClickLoginWithHuaweiIDButton(
      (err: BusinessError, data: loginComponentManager.HuaweiIDCredential): void => {
        this.onLoginResult(err, data);
      });
    this.controller.onClickCloseButton((): void => {
      this.showPanel = false;
      this.getUIContext().getRouter().back();
    });
    this.controller.onClickPrivacyText((err: BusinessError, tag: string): void => {
      if (tag === 'user_agreement') {
        RouterUtil.agreement(this.getUIContext(), 'user');
      } else if (tag === 'privacy_policy') {
        RouterUtil.agreement(this.getUIContext(), 'privacy');
      } else {
        this.toast('《华为账号用户认证协议》由华为账号服务提供');
      }
    });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    } catch (err) {
      // 提示失败不影响登录流程
    }
  }

  private async onLoginResult(err: BusinessError, data: loginComponentManager.HuaweiIDCredential): Promise<void> {
    if (err !== undefined && err !== null) {
      if (err.code === 1001502012) {
        this.toast('已取消登录');
      } else if (err.code === 1005300001) {
        this.toast('请先勾选并同意用户协议后再登录');
      } else if (err.code === 1001502001) {
        this.toast('华为账号未登录，请先在系统设置中登录华为账号');
      } else {
        this.toast('登录失败：' + (err.message !== undefined ? err.message : String(err.code)));
      }
      return;
    }
    const unionId: string = data !== undefined && data !== null ? data.unionID : '';
    if (unionId.length === 0) {
      this.toast('未能获取华为账号标识，请重试');
      return;
    }
    const outcome: LoginOutcome = await AccountService.getInstance().loginWithUnionId(unionId);
    if (outcome.success) {
      this.showPanel = false;
      this.toast('华为账号登录成功');
      this.getUIContext().getRouter().back();
    } else {
      this.toast(outcome.message);
    }
  }

  build() {
    Stack() {
      LoginPanel({
        show: $showPanel,
        params: this.panelParams,
        controller: this.controller
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F1E8')
  }
}
