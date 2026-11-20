import { BusinessError, request } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cloudCommon, cloudFunction } from '@kit.CloudFoundationKit';
import auth from '@hw-agconnect/auth';

const TAG: string = '[Genealogy][CloudFn]';
/** 与 AccountService 共用的云状态键（UI 展示用） */
const KEY_CLOUD_READY: string = 'gpCloudReady';
const KEY_CLOUD_MSG: string = 'gpCloudMsg';

/**
 * 云函数调用网关（单例）。
 *
 * 职责：
 * 1. 初始化 cloudCommon（云函数/云存储/云数据库）；
 * 2. 统一附带 accessToken、解析 `{code,message,data}`、翻译调用错误；
 * 3. 不再承载登录与账号信息，那些仍由 AccountService 负责。
 */
export class CloudFunctionClient {
  private static instance: CloudFunctionClient | null = null;
  private cloudInited: boolean = false;

  static getInstance(): CloudFunctionClient {
    if (CloudFunctionClient.instance === null) {
      CloudFunctionClient.instance = new CloudFunctionClient();
    }
    return CloudFunctionClient.instance;
  }

  /** 初始化云开发服务（幂等）：AGC 会话建立后由账号服务调用 */
  initCloud(): void {
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
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.setCloudState(false, '云服务初始化失败：' + (be.message !== undefined ? be.message : String(be.code)));
      hilog.error(0x0000, TAG, 'cloudCommon init failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 调用云函数并返回 `data` 部分（方案 §六）。
   *
   * - 自动附带 accessToken（取不到就不带，由网关认证兜底）；
   * - 统一把 `{code,message,data}` 的 JSON 串解析出来；
   * - code ≠ 200 时抛出 Error（message 为云函数给的中文提示），业务层可直接展示。
   */
  async call(name: string, data: Record<string, Object>,
    timeoutMs: number = 20 * 1000): Promise<Record<string, Object> | null> {
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
    const params: cloudFunction.FunctionParams = {
      name: name,
      version: '$latest',
      timeout: timeoutMs,
      data: payload
    };
    let result: cloudFunction.FunctionResult;
    try {
      result = await cloudFunction.call(params);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'call %{public}s failed: %{public}s', name, JSON.stringify(err));
      throw new Error(CloudFunctionClient.describeFunctionError(be));
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

  private ensureCloudReady(): void {
    if (AppStorage.get<boolean>(KEY_CLOUD_READY) !== true) {
      const msg: string | undefined = AppStorage.get<string>(KEY_CLOUD_MSG);
      const text: string = msg !== undefined ? msg : '';
      throw new Error(text.length > 0 ? text : '云服务未就绪，请先登录华为账号');
    }
  }

  /**
   * 用户凭据 accessToken（方案 §6.0 方案②「端侧显式传 token」）。
   *
   * 取不到就返回空串 —— 云函数侧会自动落到网关认证（方案①）。
   * **任何情况下都不允许把端侧自报的 uid 当鉴权依据。**
   */
  private async getAuthToken(): Promise<string> {
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

  private setCloudState(ready: boolean, message: string): void {
    AppStorage.setOrCreate<boolean>(KEY_CLOUD_READY, ready);
    AppStorage.setOrCreate<string>(KEY_CLOUD_MSG, message);
  }

  /** 把云函数调用错误翻译成用户能看懂的提示 */
  private static describeFunctionError(be: BusinessError): string {
    const msg: string = be.message !== undefined ? be.message : String(be.code);
    if (msg.indexOf('mismatched authType') >= 0) {
      return '云服务认证失败，请稍后重试';
    }
    if (msg.indexOf("doesn't have permission") >= 0 || msg.indexOf('does not have permission') >= 0) {
      return '服务访问被拒绝，请稍后重试';
    }
    if (msg.indexOf('not found') >= 0 || msg.indexOf('NOT_FOUND') >= 0) {
      return '服务暂不可用，请稍后重试';
    }
    const hasCode: boolean = be.code !== undefined && be.code !== 0;
    const code: string = hasCode ? '（' + String(be.code) + '）' : '';
    return '云服务调用失败' + code + '，请稍后重试';
  }
}
