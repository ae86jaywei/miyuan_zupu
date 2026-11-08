import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AGREEMENT_VERSION } from '../model/AgreementDoc';

const TAG: string = '[Genealogy][Consent]';

/**
 * 隐私同意状态服务：记录用户是否已同意《用户协议》《隐私政策》。
 *
 * 首次启动未同意前，应用不得初始化族谱数据、不得登录账号；
 * 同意后写入本地偏好，后续启动直接进入正常流程。
 */
export class ConsentService {
  private static instance: ConsentService | null = null;
  private static readonly KEY_AGREED: string = 'gpPrivacyAgreed';

  private prefs: preferences.Preferences | null = null;
  private initPromise: Promise<void> | null = null;

  static getInstance(): ConsentService {
    if (ConsentService.instance === null) {
      ConsentService.instance = new ConsentService();
    }
    return ConsentService.instance;
  }

  /** 初始化（幂等），读取已保存的同意状态 */
  init(context: common.UIAbilityContext): Promise<void> {
    if (this.initPromise !== null) {
      return this.initPromise;
    }
    this.initPromise = this.doInit(context);
    return this.initPromise;
  }

  private async doInit(context: common.UIAbilityContext): Promise<void> {
    try {
      const opt: preferences.Options = { name: 'zupu_consent' };
      this.prefs = preferences.getPreferencesSync(context, opt);
      const agreed: boolean = this.prefs.getSync(ConsentService.KEY_AGREED, false) as boolean;
      AppStorage.setOrCreate<boolean>(ConsentService.KEY_AGREED, agreed);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'init failed code=%{public}d msg=%{public}s', be.code, be.message);
      AppStorage.setOrCreate<boolean>(ConsentService.KEY_AGREED, false);
    }
  }

  /** 是否已同意协议 */
  hasAgreed(): boolean {
    const agreed: boolean | undefined = AppStorage.get<boolean>(ConsentService.KEY_AGREED);
    return agreed === true;
  }

  /** 记录同意状态（含协议版本与时间，便于后续版本升级时重新确认） */
  async accept(): Promise<void> {
    AppStorage.setOrCreate<boolean>(ConsentService.KEY_AGREED, true);
    if (this.prefs === null) {
      return;
    }
    try {
      this.prefs.putSync(ConsentService.KEY_AGREED, true);
      this.prefs.putSync('gpPrivacyVersion', AGREEMENT_VERSION);
      this.prefs.putSync('gpPrivacyAgreedAt', new Date().toISOString());
      this.prefs.flush();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'accept failed code=%{public}d msg=%{public}s', be.code, be.message);
    }
  }
}
