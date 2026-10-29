import { authentication } from '@kit.AccountKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError, request } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { cloudCommon, cloudFunction } from '@kit.CloudFoundationKit';
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
  /** AGC 可信用户标识（云函数鉴权身份，方案 §6.0） */
  static readonly KEY_AGC_UID: string = 'gpAgcUid';
  /** 家族（族谱）ID，由云侧生成下发；空表示本机仅本地族谱 */
  static readonly KEY_FAMILY_ID: string = 'gpFamilyId';
  /** 当前身份是否已被云函数服务端校验通过 */
  static readonly KEY_IDENTITY_VERIFIED: string = 'gpIdentityVerified';

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

  /**
   * 家族（族谱）ID —— 由**云侧生成并下发**（方案 §五.1、§七）。
   *
   * 旧实现在本机 preferences 里随机生成 UUID 充当 familyId；它在重装/换机后会漂移，
   * 且从未在云端存在过，属于「假的家族身份」，本版已废弃。
   * 现在只有在 family-create / family-join 成功后才会被写入；
   * 未加入任何家族时返回空串，调用方据此走「仅本机」模式。
   */
  getFamilyId(): string {
    const cached: string | undefined = AppStorage.get<string>(AccountService.KEY_FAMILY_ID);
    if (cached !== undefined && cached.length > 0) {
      return cached;
    }
    if (this.prefs !== null) {
      try {
        const stored: string = this.prefs.getSync('familyId', '') as string;
        return stored !== undefined && stored !== null ? stored : '';
      } catch (err) {
        hilog.error(0x0000, TAG, 'familyId failed: %{public}s', JSON.stringify(err));
      }
    }
    return '';
  }

  /** 记录云侧下发的家族ID（family-create / family-join / 同步成功后调用） */
  setFamilyId(familyId: string): void {
    AppStorage.setOrCreate<string>(AccountService.KEY_FAMILY_ID, familyId);
    if (this.prefs !== null) {
      try {
        this.prefs.putSync('familyId', familyId);
        this.prefs.flush();
      } catch (err) {
        hilog.error(0x0000, TAG, 'save familyId failed: %{public}s', JSON.stringify(err));
      }
    }
  }

  /** AGC 可信用户标识（若能从 AGC 认证结果取到） */
  getAgcUid(): string {
    const v: string | undefined = AppStorage.get<string>(AccountService.KEY_AGC_UID);
    return v !== undefined ? v : '';
  }

  /** 身份是否已被服务端校验（点开家族时由 sync-pull 置位） */
  isIdentityVerified(): boolean {
    return AppStorage.get<boolean>(AccountService.KEY_IDENTITY_VERIFIED) === true;
  }

  setIdentityVerified(verified: boolean): void {
    AppStorage.setOrCreate<boolean>(AccountService.KEY_IDENTITY_VERIFIED, verified);
  }

  /**
   * 用户凭据 accessToken（方案 §6.0 方案②「端侧显式传 token」）。
   *
   * 取不到就返回空串 —— 云函数侧会自动落到网关认证（方案①）。
   * **任何情况下都不允许把端侧自报的 uid 当鉴权依据。**
   */
  async getAuthToken(): Promise<string> {
    if (!this.agcReady) {
      return '';
    }
    try {
      const provider: cloudCommon.AuthProvider | undefined = auth.getAuthProvider();
      if (provider === undefined || provider === null) {
        return '';
      }
      const token: string = await provider.getAccessToken(false);
      return token !== undefined && token !== null ? token : '';
    } catch (err) {
      hilog.warn(0x0000, TAG, 'getAccessToken unavailable: %{public}s', JSON.stringify(err));
      return '';
    }
  }

  /**
   * 调用云函数并返回 \`data\` 部分（方案 §六）。
   *
   * - 自动附带 accessToken（取不到就不带，由网关认证兜底）；
   * - 统一把 \`{code,message,data}\` 的 JSON 串解析出来；
   * - code ≠ 200 时抛出 Error（message 为云函数给的中文提示），业务层可直接展示。
   */
  async callFunction(name: string, data: Record<string, Object>): Promise<Record<string, Object> | null> {
    this.ensureCloudReady();
    const payload: Record<string, Object> = {};
    const keys: string[] = Object.keys(data);
    for (let i: number = 0; i < keys.length; i++) {
      payload[keys[i]] = data[keys[i]];
    }
    const token: string = await this.getAuthToken();
    if (token.length > 0) {
      payload['accessToken'] = token;
    }
    const request: cloudFunction.FunctionParams = {
      name: name,
      version: '$latest',
      timeout: 20 * 1000,
      data: payload
    };
    let result: cloudFunction.FunctionResult;
    try {
      result = await cloudFunction.call(request);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'call %{public}s failed: %{public}s', name, JSON.stringify(err));
      throw new Error(AccountService.describeFunctionError(be));
    }
    // cloudFunction.call 的 result.result 既可能是 JSON 字符串，也可能已经是对象，
    // 统一归一化成 Record，避免 String(obj) 得到 "[object Object]"。
    const raw: Object | undefined = result.result;
    if (raw === undefined || raw === null) {
      throw new Error('云函数 ' + name + ' 返回为空');
    }
    let parsed: Record<string, Object>;
    if (typeof raw === 'string') {
      const text: string = raw as string;
      if (text.length === 0) {
        throw new Error('云函数 ' + name + ' 返回为空');
      }
      try {
        parsed = JSON.parse(text) as Record<string, Object>;
      } catch (err) {
        hilog.error(0x0000, TAG, 'call %{public}s bad json: %{public}s', name,
          text.length > 300 ? text.substring(0, 300) : text);
        throw new Error('云函数 ' + name + ' 返回格式异常');
      }
    } else {
      parsed = raw as Record<string, Object>;
    }
    const code: number = Number(parsed['code'] !== undefined ? parsed['code'] : 0);
    const message: string = parsed['message'] !== undefined ? String(parsed['message']) : '';
    if (code !== 200) {
      const reason: string = parsed['reason'] !== undefined ? String(parsed['reason']) : '';
      hilog.warn(0x0000, TAG, 'call %{public}s code=%{public}d reason=%{public}s', name, code, reason);
      const err: Error = new Error(message.length > 0
        ? message : ('云函数 ' + name + ' 失败（' + code.toString() + '）'));
      err.name = 'CloudFunctionError:' + code.toString() + ':' + reason;
      throw err;
    }
    const body: Object | undefined = parsed['data'];
    if (body === undefined || body === null) {
      return null;
    }
    return body as Record<string, Object>;
  }

  /** 把云函数调用错误翻译成用户能看懂的提示（含 AGC 已知错误码） */
  private static describeFunctionError(be: BusinessError): string {
    const msg: string = be.message !== undefined ? be.message : String(be.code);
    if (msg.indexOf('mismatched authType') >= 0) {
      return '云函数认证类型不正确：请在 function-config.json 中把 authType 设为 cloudgw-client';
    }
    if (msg.indexOf("doesn't have permission") >= 0 || msg.indexOf('does not have permission') >= 0) {
      return '云函数调用被拒绝：多为签名配置问题，请确认调试/发布证书指纹已在 AGC 关联';
    }
    if (msg.indexOf('not found') >= 0 || msg.indexOf('NOT_FOUND') >= 0) {
      return '云函数不存在：请在 AGC 控制台或 DevEco 云侧工程中部署该函数';
    }
    return '云函数调用失败：' + msg;
  }

  private ensureCloudReady(): void {
    if (!this.isCloudReady()) {
      const msg: string = this.getCloudMessage();
      throw new Error(msg.length > 0 ? msg : '云服务未就绪，请先登录华为账号');
    }
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