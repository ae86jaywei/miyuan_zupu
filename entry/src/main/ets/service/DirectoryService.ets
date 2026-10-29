import { cloudDatabase } from '@kit.CloudFoundationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccountService } from './AccountService';
import { Genealogy } from '../model/Genealogy';
import { DirectoryEntry } from '../model/FamilyDomain';
import { CloudFamilyDirectory } from '../model/FamilyModels';

const TAG: string = '[Genealogy][Directory]';
const ZONE_NAME: string = 'miyuanfamily';
const MAX_ROWS: number = 100;
/** 人数区间枚举（与云侧 MEMBER_COUNT_BANDS 一致，禁止精确人数） */
export const MEMBER_COUNT_BANDS: string[] = ['0-50', '50-100', '100-500', '500-1000', '1000+'];

/** 黄页表单字段（全部为索引元数据，**不含任何人物数据**） */
export class DirectoryForm {
  directoryEnabled: boolean = false;
  surname: string = '';
  region: string = '';
  title: string = '';
  branchSummary: string = '';
  memberCountBand: string = '';
  coverRef: string = '';
  accessHint: string = '需谱主审核后可查看';
}

/**
 * 族谱黄页（方案 §五.11、§十三.4）。
 *
 * 两条铁律：
 *  1. 只读端侧可直读（Authenticated: Read），但它**只含索引元数据**；
 *  2. **默认不可搜**：未上架的谱根本不在表里（关闭 = 云函数物理删除该行），
 *     不存在「写一行 false 靠端侧过滤」的假过滤。
 */
export class DirectoryService {
  private static instance: DirectoryService | null = null;

  static getInstance(): DirectoryService {
    if (DirectoryService.instance === null) {
      DirectoryService.instance = new DirectoryService();
    }
    return DirectoryService.instance;
  }

  /** 搜索黄页（任意登录用户可读，不需要 Membership） */
  async search(keyword: string): Promise<DirectoryEntry[]> {
    const out: DirectoryEntry[] = [];
    if (!AccountService.getInstance().isCloudReady()) {
      return out;
    }
    try {
      const zone: cloudDatabase.DatabaseZone = cloudDatabase.zone(ZONE_NAME);
      const query: cloudDatabase.DatabaseQuery<CloudFamilyDirectory> =
        new cloudDatabase.DatabaseQuery<CloudFamilyDirectory>(CloudFamilyDirectory);
      query.limit(MAX_ROWS);
      const rows: CloudFamilyDirectory[] = await zone.query(query);
      const kw: string = keyword.trim();
      for (let i: number = 0; i < rows.length; i++) {
        const row: CloudFamilyDirectory = rows[i];
        const e: DirectoryEntry = new DirectoryEntry();
        e.dirId = row.dirId !== undefined ? row.dirId : '';
        e.familyId = row.familyId !== undefined ? row.familyId : '';
        e.surname = row.surname !== undefined ? row.surname : '';
        e.region = row.region !== undefined ? row.region : '';
        e.title = row.title !== undefined ? row.title : '';
        e.branchSummary = row.branchSummary !== undefined ? row.branchSummary : '';
        e.memberCountBand = row.memberCountBand !== undefined ? row.memberCountBand : '';
        e.coverRef = row.coverRef !== undefined ? row.coverRef : '';
        e.accessHint = row.accessHint !== undefined ? row.accessHint : '';
        e.updatedAt = row.updatedAt !== undefined ? row.updatedAt : 0;
        if (kw.length === 0 || e.title.indexOf(kw) >= 0 || e.surname.indexOf(kw) >= 0 ||
          e.region.indexOf(kw) >= 0 || e.branchSummary.indexOf(kw) >= 0) {
          out.push(e);
        }
      }
      return out;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'query directory failed: %{public}s', JSON.stringify(err));
      return out;
    }
  }

  /** 是否为已上架的谱（用于本地族谱卡片标注） */
  async isListed(familyId: string): Promise<boolean> {
    if (familyId.length === 0 || !AccountService.getInstance().isCloudReady()) {
      return false;
    }
    try {
      const zone: cloudDatabase.DatabaseZone = cloudDatabase.zone(ZONE_NAME);
      const query: cloudDatabase.DatabaseQuery<CloudFamilyDirectory> =
        new cloudDatabase.DatabaseQuery<CloudFamilyDirectory>(CloudFamilyDirectory);
      query.equalTo('dirId', familyId);
      query.limit(1);
      const rows: CloudFamilyDirectory[] = await zone.query(query);
      return rows.length > 0;
    } catch (err) {
      return false;
    }
  }

  /** 上架 / 更新黄页（仅谱主/编辑者，云侧做字段白名单校验） */
  async upsert(familyId: string, form: DirectoryForm): Promise<void> {
    await AccountService.getInstance().callFunction('directory-upsert', {
      'familyId': familyId,
      'directoryEnabled': form.directoryEnabled,
      'surname': form.surname,
      'region': form.region,
      'title': form.title,
      'branchSummary': form.branchSummary,
      'memberCountBand': form.memberCountBand,
      'coverRef': form.coverRef,
      'accessHint': form.accessHint
    });
  }

  /** 下架（= 云端物理删除黄页行，不是写 false） */
  async remove(familyId: string, form: DirectoryForm): Promise<void> {
    const off: DirectoryForm = new DirectoryForm();
    off.directoryEnabled = false;
    off.title = form.title;
    await this.upsert(familyId, off);
  }

  /** 从本地族谱推导一份默认黄页表单（谱主省事，但仍需其确认后上架） */
  static defaultForm(book: Genealogy): DirectoryForm {
    const f: DirectoryForm = new DirectoryForm();
    f.title = book.title;
    f.surname = book.surname;
    f.branchSummary = book.ancestorName.length > 0 ? ('始迁祖 ' + book.ancestorName) : '';
    f.memberCountBand = '';
    return f;
  }
}
