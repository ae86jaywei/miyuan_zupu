/**
 * 族谱主体模型（一部族谱的元信息）。
 *
 * 协作扩展（方案 §五.0 路线 A：1 部谱 = 1 个 familyId）：
 * familyId 由云侧生成，空串表示这部谱只存在于本机（未接入云家族）。
 */
export class Genealogy {
  /** 族谱ID */
  key: number = 0;
  /** 谱名，如：李氏宗谱 */
  title: string = '我的族谱';
  /** 姓氏 */
  surname: string = '';
  /** 堂号，如：陇西堂 */
  hallName: string = '';
  /** 郡望，如：陇西郡 */
  junwang: string = '';
  /** 始迁祖 / 始祖名讳 */
  ancestorName: string = '';
  /** 字派谱（字辈诗），如：德泽承先志 */
  generationPoem: string = '';
  /** 谱序 */
  preface: string = '';
  /** 家训 */
  familyRules: string = '';
  /** 修谱说明/凡例 */
  editingNotes: string = '';
  /** 封面颜色（十六进制） */
  coverColor: string = '#8C2F1E';
  /** 封面纹样：classic / modern / minimal */
  coverPattern: string = 'classic';
  /** 所属母族谱ID（>0 表示本谱是由某人另立的分支） */
  parentBookId: number = 0;
  /** 分支始祖在原族谱中的唯一ID（仅分支谱有效） */
  branchRootUid: string = '';
  /** 创建时间 */
  createdAt: number = 0;
  /** 更新时间 */
  updatedAt: number = 0;
  // ---------------------------------------------------------------- 协作
  /** 云侧家族ID（空 = 仅本机） */
  familyId: string = '';
  /** LOCAL / CLOUD_READY / CLOUD_PENDING（见 FamilyDomain.SyncMode） */
  syncMode: string = '';
  /** 本机最后一次同步到的家族 rev */
  cloudRev: number = 0;
  /** 我在该家族中的角色：OWNER / EDITOR / VIEWER */
  familyRole: string = '';

  /** 是否为已接入云家族的谱 */
  isCloud(): boolean {
    return this.familyId.length > 0;
  }

  /** 供云函数 family-bootstrap / 直写使用的谱元信息 */
  toCloudPayload(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['key'] = this.key;
    out['title'] = this.title;
    out['surname'] = this.surname;
    out['hallName'] = this.hallName;
    out['junwang'] = this.junwang;
    out['ancestorName'] = this.ancestorName;
    out['generationPoem'] = this.generationPoem;
    out['preface'] = this.preface;
    out['familyRules'] = this.familyRules;
    out['editingNotes'] = this.editingNotes;
    out['coverColor'] = this.coverColor;
    out['coverPattern'] = this.coverPattern;
    out['branchRootUid'] = this.branchRootUid;
    out['createdAt'] = this.createdAt;
    out['updatedAt'] = this.updatedAt;
    return out;
  }

  /** 从云侧 payload 还原 */
  static fromCloudPayload(raw: Record<string, Object>): Genealogy {
    const g: Genealogy = createEmptyGenealogy();
    g.key = Number(raw['key'] !== undefined ? raw['key'] : 0);
    g.title = textOf(raw, 'title');
    g.surname = textOf(raw, 'surname');
    g.hallName = textOf(raw, 'hallName');
    g.junwang = textOf(raw, 'junwang');
    g.ancestorName = textOf(raw, 'ancestorName');
    g.generationPoem = textOf(raw, 'generationPoem');
    g.preface = textOf(raw, 'preface');
    g.familyRules = textOf(raw, 'familyRules');
    g.editingNotes = textOf(raw, 'editingNotes');
    g.coverColor = textOf(raw, 'coverColor');
    g.coverPattern = textOf(raw, 'coverPattern');
    g.branchRootUid = textOf(raw, 'branchRootUid');
    g.createdAt = Number(raw['createdAt'] !== undefined ? raw['createdAt'] : 0);
    g.updatedAt = Number(raw['updatedAt'] !== undefined ? raw['updatedAt'] : 0);
    return g;
  }
}

function textOf(raw: Record<string, Object>, key: string): string {
  const v: Object | undefined = raw[key];
  return v === undefined || v === null ? '' : String(v);
}

export function createEmptyGenealogy(): Genealogy {
  const g: Genealogy = new Genealogy();
  g.createdAt = Date.now();
  g.updatedAt = g.createdAt;
  return g;
}
