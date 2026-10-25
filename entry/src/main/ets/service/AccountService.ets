import { authentication } from '@kit.AccountKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError, request } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { cloudCommon } from '@kit.CloudFoundationKit';
import auth from '@hw-agconnect/auth';
import { AuthUser, HwIdCredentialInfo, SignInParam } from '@hw-agconnect/auth';

const TAG: string = '[Genealogy][Account]';

/** 华为账号登录结果 */
export class LoginOutcome {
  success: boolean = false;
  cancelled: boolean = false;
  needsManualLogin: boolean = false;
  message: string = '';
}

/**
 * 华为账号服务（单例）。
 *
 * 职责：
 * 1. 手动登录（forceLogin = true）与静默登录（forceLogin = false）；
 * 2. UnionID → userId（hw-{unionID}）映射，作为云端数据的账号隔离字段；
 * 3. 登录成功后初始化 AGC 认证，供 Cloud DB / Cloud Storage 使用；
 * 4. 登录态与账号信息缓存（不落盘 authorizationCode，仅保存 UnionID 等非敏感标识）。
 */
export class AccountService {
  private static instance: AccountService | null = null;

  private context: common.UIAbilityContext | null = null;
  private prefs: preferences.Preferences | null = null;
  private initPromise: Promise<void> | null = null;
  private agcReady: boolean = false;
  private cloudInited: boolean = false;

  static readonly KEY_LOGIN: string = 'gpLogin';
  static readonly KEY_USER_ID: string = 'gpUserId';
  static readonly KEY_UNION_ID: string = 'gpUnionId';
  static readonly KEY_NICK_NAME: string = 'gpNickName';
  static readonly KEY_CLOUD_READY: string = 'gpCloudReady';
  static readonly KEY_CLOUD_MSG: string = 'gpCloudMsg';

  static getInstance(): AccountService {
    if (AccountService.instance === null) {
      AccountService.instance = new AccountService();
    }
    return AccountService.instance;
  }

  /** 初始化（幂等），需在 UIAbility 启动时调用 */
  init(context: common.UIAbilityContext): Promise<void> {
    if (this.initPromise !== null) {
      return this.initPromise;
    }
    this.context = context;
    this.initPromise = this.doInit();
    return this.initPromise;
  }

  private async doInit(): Promise<void> {
    if (this.context === null) {
      return;
    }
    try {
      const opt: preferences.Options = { name: 'zupu_account' };
      this.prefs = preferences.getPreferencesSync(this.context, opt);
    } catch (err) {
      hilog.error(0x0000, TAG, 'prefs init failed: %{public}s', JSON.stringify(err));
    }
    this.restoreCachedState();
    this.initAgc();
  }

  /** 读取本地缓存的账号标识，避免静默登录完成前界面空白 */
  private restoreCachedState(): void {
    if (this.prefs === null) {
      return;
    }
    try {
      const unionId: string = this.prefs.getSync('unionId', '') as string;
      AppStorage.setOrCreate<string>(AccountService.KEY_UNION_ID, unionId);
      AppStorage.setOrCreate<string>(AccountService.KEY_USER_ID, unionId.length > 0 ? 'hw-' + unionId : '');
      AppStorage.setOrCreate<boolean>(AccountService.KEY_LOGIN, false);
    } catch (err) {
      hilog.error(0x0000, TAG, 'restore state failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 初始化 AGC 认证 SDK；缺少 agconnect-services.json 时标记云端不可用 */
  private initAgc(): void {
    if (this.context === null) {
      return;
    }
    try {
      const bytes: Uint8Array = this.context.resourceManager.getRawFileContentSync('agconnect-services.json');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const json: string = decoder.decodeToString(bytes);
      auth.init(this.context, json);
      this.agcReady = true;
      hilog.info(0x0000, TAG, 'AGC auth init success');
    } catch (err) {
      this.agcReady = false;
      this.setCloudState(false, '未配置 AGC 云服务（缺少 agconnect-services.json）');
      hilog.warn(0x0000, TAG, 'AGC auth init skipped: %{public}s', JSON.stringify(err));
    }
  }

  /** 是否已完成 AGC SDK 初始化 */
  isAgcReady(): boolean {
    return this.agcReady;
  }

  /** 云端能力是否可用（AGC 初始化 + 云开发服务初始化成功） */
  isCloudReady(): boolean {
    return AppStorage.get<boolean>(AccountService.KEY_CLOUD_READY) === true;
  }

  isLoggedIn(): boolean {
    return AppStorage.get<boolean>(AccountService.KEY_LOGIN) === true;
  }

  getUserId(): string {
    const value: string | undefined = AppStorage.get<string>(AccountService.KEY_USER_ID);
    return value !== undefined ? value : '';
  }

  getUnionId(): string {
    const value: string | undefined = AppStorage.get<string>(AccountService.KEY_UNION_ID);
    return value !== undefined ? value : '';
  }

  /** 脱敏展示账号标识 */
  getDisplayId(): string {
    const unionId: string = this.getUnionId();
    if (unionId.length <= 8) {
      return unionId;
    }
    return unionId.substring(0, 4) + '****' + unionId.substring(unionId.length - 4);
  }

  /** 首次使用时可跳过登录，之后不再强制弹出登录页 */
  isLoginSkipped(): boolean {
    if (this.prefs === null) {
      return false;
    }
    try {
      return this.prefs.getSync('loginSkipped', false) as boolean;
    } catch (err) {
      return false;
    }
  }

  setLoginSkipped(skipped: boolean): void {
    if (this.prefs === null) {
      return;
    }
    try {
      this.prefs.putSync('loginSkipped', skipped);
      this.prefs.flush();
    } catch (err) {
      hilog.error(0x0000, TAG, 'save skip flag failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 分享链接使用的族谱ID，UUID 不可猜测 */
  getFamilyId(): string {
    if (this.prefs !== null) {
      try {
        const cached: string = this.prefs.getSync('familyId', '') as string;
        if (cached.length > 0) {
          return cached;
        }
        const created: string = util.generateRandomUUID();
        this.prefs.putSync('familyId', created);
        this.prefs.flush();
        return created;
      } catch (err) {
        hilog.error(0x0000, TAG, 'familyId failed: %{public}s', JSON.stringify(err));
      }
    }
    return util.generateRandomUUID();
  }

  /** 手动登录：会拉起华为账号登录界面 */
  login(): Promise<LoginOutcome> {
    return this.executeLogin(true);
  }

  /** 静默登录：华为账号已登录且与应用上次账号一致时不打扰用户 */
  trySilentLogin(): Promise<LoginOutcome> {
    return this.executeLogin(false);
  }

  private async executeLogin(forceLogin: boolean): Promise<LoginOutcome> {
    const outcome: LoginOutcome = new LoginOutcome();
    if (this.initPromise !== null) {
      await this.initPromise;
    }
    if (this.context === null) {
      outcome.message = '登录上下文未初始化';
      return outcome;
    }
    try {
      const provider: authentication.HuaweiIDProvider = new authentication.HuaweiIDProvider();
      const loginRequest: authentication.LoginWithHuaweiIDRequest = provider.createLoginWithHuaweiIDRequest();
      loginRequest.forceLogin = forceLogin;
      loginRequest.state = util.generateRandomUUID();

      const controller: authentication.AuthenticationController =
        new authentication.AuthenticationController(this.context);
      const response: authentication.AuthenticationResponse = await controller.executeRequest(loginRequest);
      const loginResponse: authentication.LoginWithHuaweiIDResponse =
        response as authentication.LoginWithHuaweiIDResponse;
      if (loginResponse.state !== loginRequest.state) {
        outcome.message = '登录状态校验失败，请重试';
        return outcome;
      }
      const credential: authentication.LoginWithHuaweiIDCredential | undefined = loginResponse.data;
      if (credential === undefined || credential.unionID.length === 0) {
        outcome.message = '未能获取华为账号标识';
        return outcome;
      }
      await this.applyLogin(credential.unionID);
      outcome.success = true;
      outcome.message = '登录成功';
      return outcome;
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'login failed code=%{public}d msg=%{public}s', be.code, be.message);
      if (be.code === 1001502001) {
        outcome.needsManualLogin = true;
        outcome.message = '华为账号未登录，请点击登录按钮完成登录';
      } else if (be.code === 1001502012) {
        outcome.cancelled = true;
        outcome.message = '已取消登录';
      } else if (be.code === 1001500001) {
        outcome.message = '应用指纹校验失败，请检查 AGC 调试/发布证书指纹配置';
      } else {
        outcome.message = '登录失败：' + (be.message !== undefined ? be.message : String(be.code));
      }
      return outcome;
    }
  }

  private async applyLogin(unionId: string): Promise<void> {
    const userId: string = 'hw-' + unionId;
    AppStorage.setOrCreate<string>(AccountService.KEY_UNION_ID, unionId);
    AppStorage.setOrCreate<string>(AccountService.KEY_USER_ID, userId);
    AppStorage.setOrCreate<boolean>(AccountService.KEY_LOGIN, true);
    if (this.prefs !== null) {
      try {
        this.prefs.putSync('unionId', unionId);
        this.prefs.putSync('loginSkipped', false);
        this.prefs.flush();
      } catch (err) {
        hilog.error(0x0000, TAG, 'save login state failed: %{public}s', JSON.stringify(err));
      }
    }
    await this.ensureAgcSession();
  }

  /** 建立 AGC 登录态（云数据库/云存储的访问凭证由 AGC 认证托管） */
  private async ensureAgcSession(): Promise<void> {
    if (!this.agcReady) {
      this.setCloudState(false, '未配置 AGC 云服务（缺少 agconnect-services.json）');
      return;
    }
    try {
      const current: AuthUser | null = await auth.getCurrentUser();
      if (current === null) {
        const credential: HwIdCredentialInfo = { kind: 'hwid' };
        const param: SignInParam = { credentialInfo: credential, autoCreateUser: true };
        await auth.signIn(param);
      }
      this.initCloudCommon();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.setCloudState(false, 'AGC 认证失败：' + (be.message !== undefined ? be.message : '请检查云服务配置'));
      hilog.error(0x0000, TAG, 'agc signIn failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 初始化云开发服务（幂等） */
  private initCloudCommon(): void {
    if (this.cloudInited) {
      this.setCloudState(true, '云端已就绪');
      return;
    }
    try {
      cloudCommon.init({
        region: cloudCommon.CloudRegion.CHINA,
        authProvider: auth.getAuthProvider(),
        functionOptions: {
          timeout: 10 * 1000
        },
        storageOptions: {
          mode: request.agent.Mode.BACKGROUND,
          network: request.agent.Network.ANY
        },
        databaseOptions: {
          schema: 'schema.json'
        }
      });
      this.cloudInited = true;
      this.setCloudState(true, '云端已就绪');
      hilog.info(0x0000, TAG, 'cloudCommon init success');
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.setCloudState(false, '云服务初始化失败：' + (be.message !== undefined ? be.message : String(be.code)));
      hilog.error(0x0000, TAG, 'cloudCommon init failed: %{public}s', JSON.stringify(err));
    }
  }

  private setCloudState(ready: boolean, message: string): void {
    AppStorage.setOrCreate<boolean>(AccountService.KEY_CLOUD_READY, ready);
    AppStorage.setOrCreate<string>(AccountService.KEY_CLOUD_MSG, message);
  }

  getCloudMessage(): string {
    const value: string | undefined = AppStorage.get<string>(AccountService.KEY_CLOUD_MSG);
    return value !== undefined ? value : '';
  }

  /** 退出登录并清理内存中的账号态（云端数据保留，换机登录后可恢复） */
  async logout(): Promise<void> {
    try {
      if (this.agcReady) {
        await auth.signOut();
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'agc signOut failed: %{public}s', JSON.stringify(err));
    }
    AppStorage.setOrCreate<boolean>(AccountService.KEY_LOGIN, false);
    AppStorage.setOrCreate<string>(AccountService.KEY_UNION_ID, '');
    AppStorage.setOrCreate<string>(AccountService.KEY_USER_ID, '');
    this.setCloudState(false, '已退出登录');
    if (this.prefs !== null) {
      try {
        this.prefs.putSync('unionId', '');
        this.prefs.flush();
      } catch (err) {
        hilog.error(0x0000, TAG, 'clear login state failed: %{public}s', JSON.stringify(err));
      }
    }
  }

  getContext(): common.UIAbilityContext | null {
    return this.context;
  }
}
