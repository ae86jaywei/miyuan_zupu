import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccountService } from './AccountService';
import { objectList, str } from '../model/FamilyDomain';

const TAG: string = '[Genealogy][Privacy]';

/** 活人隐私字段（只对谱主可见，端侧永不直读云端表） */
export class PrivateContact {
  uid: string = '';
  phone: string = '';
  wechat: string = '';
  residence: string = '';
}

/**
 * 隐私字段服务（方案 §八.6 / §五.9）。
 *
 * 事实前提：协作 Zone 里 phone/wechat/residence 存在 FamilyPrivate，
 * 该对象类型对端侧权限为 **[]**，只有云函数（且调用者是 OWNER）能读到明文。
 * 因此编辑者/只读成员看到的就是空值——这是设计，不是 bug。
 */
export class PrivacyService {
  private static instance: PrivacyService | null = null;
  private cache: Map<string, PrivateContact> = new Map<string, PrivateContact>();

  static getInstance(): PrivacyService {
    if (PrivacyService.instance === null) {
      PrivacyService.instance = new PrivacyService();
    }
    return PrivacyService.instance;
  }

  /** 谱主拉取全部隐私字段并缓存 */
  async loadAll(familyId: string): Promise<number> {
    if (familyId.length === 0 || !AccountService.getInstance().isCloudReady()) {
      return 0;
    }
    try {
      const data: Record<string, Object> | null =
        await AccountService.getInstance().callFunction('family-private-get', { 'familyId': familyId });
      const rows: Record<string, Object>[] = objectList(data, 'privates');
      this.cache.clear();
      for (let i: number = 0; i < rows.length; i++) {
        const c: PrivateContact = new PrivateContact();
        c.uid = str(rows[i], 'uid');
        c.phone = str(rows[i], 'phone');
        c.wechat = str(rows[i], 'wechat');
        c.residence = str(rows[i], 'residence');
        this.cache.set(c.uid.toUpperCase(), c);
      }
      return this.cache.size;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'load private failed: %{public}s', JSON.stringify(err));
      return 0;
    }
  }

  /** 取某人缓存的隐私字段（非谱主恒为空） */
  get(uid: string): PrivateContact {
    const hit: PrivateContact | undefined = this.cache.get(uid.trim().toUpperCase());
    return hit !== undefined ? hit : new PrivateContact();
  }

  clear(): void {
    this.cache.clear();
  }

  /**
   * 「被记录人」查询/更正/删除的处理路径（§八.6 合规红线）。
   * 目前由谱主人工处理 + 审计留痕承接，这里给出入口文案。
   */
  static erasureHint(): string {
    return '若你是谱中被记录的活人，且不希望手机号/微信/现居地出现在云端，请联系谱主删除或更正；' +
      '相关操作会记录在变更日志中（可追溯）。';
  }
}
