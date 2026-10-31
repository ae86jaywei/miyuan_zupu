/**
 * 家族协作的端侧业务模型（纯数据类 / DTO，不依赖云数据库 API）。
 *
 * 云数据库对象类型见 model/FamilyModels.ets；
 * 云函数返回的 JSON 在这里被解析成强类型对象，供页面与服务使用。
 */

/** 角色 */
export class Role {
  static readonly OWNER: string = 'OWNER';
  static readonly EDITOR: string = 'EDITOR';
  static readonly VIEWER: string = 'VIEWER';
}

/** 成员状态 */
export class MembershipStatus {
  static readonly INVITED: string = 'INVITED';
  static readonly ACTIVE: string = 'ACTIVE';
  static readonly REVOKED: string = 'REVOKED';
  static readonly EXPIRED: string = 'EXPIRED';
}

/** 变更单状态 */
export class ChangeStatus {
  static readonly PENDING: string = 'PENDING';
  static readonly APPROVED: string = 'APPROVED';
  static readonly REJECTED: string = 'REJECTED';
  static readonly SUPERSEDED: string = 'SUPERSEDED';
}

/** 申请类型 / 状态 */
export class AccessKind {
  static readonly VIEW_APPLY: string = 'VIEW_APPLY';
  static readonly JOIN_CLAIM: string = 'JOIN_CLAIM';
}

export class AccessStatus {
  static readonly PENDING: string = 'PENDING';
  static readonly APPROVED: string = 'APPROVED';
  static readonly REJECTED: string = 'REJECTED';
  static readonly EXPIRED: string = 'EXPIRED';
  static readonly CANCELLED: string = 'CANCELLED';
}

/** 本地同步模式：仅本机 / 已有云家族 / 云家族待初始化 */
export class SyncMode {
  static readonly LOCAL: string = 'LOCAL';
  static readonly CLOUD_READY: string = 'CLOUD_READY';
  static readonly CLOUD_PENDING: string = 'CLOUD_PENDING';
}

/** 角色中文名 */
export function roleLabel(role: string): string {
  switch (role) {
    case Role.OWNER: return '谱主';
    case Role.EDITOR: return '编辑者';
    case Role.VIEWER: return '只读成员';
    default: return role.length > 0 ? role : '未知';
  }
}

/** 角色可写判定 */
export function canEdit(role: string): boolean {
  return role === Role.OWNER || role === Role.EDITOR;
}

export function isOwner(role: string): boolean {
  return role === Role.OWNER;
}

/** 成员状态中文名 */
export function membershipStatusLabel(status: string): string {
  switch (status) {
    case MembershipStatus.INVITED: return '已邀请';
    case MembershipStatus.ACTIVE: return '有效';
    case MembershipStatus.REVOKED: return '已撤销';
    case MembershipStatus.EXPIRED: return '已到期';
    default: return status;
  }
}

/** 申请状态中文名 */
export function accessStatusLabel(status: string): string {
  switch (status) {
    case AccessStatus.PENDING: return '待审核';
    case AccessStatus.APPROVED: return '已通过';
    case AccessStatus.REJECTED: return '已拒绝';
    case AccessStatus.EXPIRED: return '已过期';
    case AccessStatus.CANCELLED: return '已取消';
    default: return status;
  }
}

/** 申请类型中文名 */
export function accessKindLabel(kind: string): string {
  return kind === AccessKind.JOIN_CLAIM ? '申请成为族人并认领支系' : '申请查看';
}

/** 变更操作中文名 */
export function opLabel(op: string): string {
  switch (op) {
    case 'ADD': return '新增';
    case 'UPDATE': return '修改';
    case 'DELETE_REQ': return '删除';
    case 'APPEND_TEXT': return '追加段落';
    case 'GRAVE_UPDATE': return '墓葬';
    default: return op;
  }
}

/** 我参与的一部家族（来自 family-list-mine / 本地缓存） */
export class FamilySummary {
  familyId: string = '';
  title: string = '';
  bookKey: number = 0;
  rev: number = 0;
  aclVersion: number = 1;
  directoryEnabled: boolean = false;
  /** 仅 OWNER 能拿到加入码 */
  inviteCode: string = '';
  role: string = '';
  membershipStatus: string = '';
  branchRootUid: string = '';
  /** 0 = 永久 */
  expireAt: number = 0;
  createdAt: number = 0;
  /** 本地族谱（genealogy 表的 id） */
  localBookId: number = 0;
  /** 本机最后一次成功同步到的 rev */
  lastRev: number = 0;
  lastSyncAt: number = 0;
}

/** 成员行（family-acl-list 返回） */
export class MemberInfo {
  userId: string = '';
  role: string = '';
  status: string = '';
  branchRootUid: string = '';
  expireAt: number = 0;
  nickName: string = '';
  source: string = '';
  joinedAt: number = 0;
  revokedAt: number = 0;
  displayName: string = '';

  static fromJson(raw: Record<string, Object>): MemberInfo {
    const m: MemberInfo = new MemberInfo();
    m.userId = str(raw, 'userId');
    m.role = str(raw, 'role');
    m.status = str(raw, 'status');
    m.branchRootUid = str(raw, 'branchRootUid');
    m.expireAt = num(raw, 'expireAt');
    m.nickName = str(raw, 'nickName');
    m.source = str(raw, 'source');
    m.joinedAt = num(raw, 'joinedAt');
    m.revokedAt = num(raw, 'revokedAt');
    return m;
  }
}

/** 待审 / 已审变更单 */
export class ChangeRequestInfo {
  requestId: string = '';
  familyId: string = '';
  submitterId: string = '';
  submitterName: string = '';
  targetUid: string = '';
  /** 云侧返回的成员名（便于列表展示） */
  targetName: string = '';
  op: string = '';
  /** patchJson 原文，diff 视图自行解析 */
  patchJson: string = '';
  baseRev: number = 0;
  evidence: string = '';
  status: string = '';
  reviewerId: string = '';
  reviewNote: string = '';
  reviewedAt: number = 0;
  createdAt: number = 0;

  static fromJson(raw: Record<string, Object>): ChangeRequestInfo {
    const r: ChangeRequestInfo = new ChangeRequestInfo();
    r.requestId = str(raw, 'requestId');
    r.familyId = str(raw, 'familyId');
    r.submitterId = str(raw, 'submitterId');
    r.submitterName = str(raw, 'submitterName');
    r.targetUid = str(raw, 'targetUid');
    r.targetName = str(raw, 'targetName');
    r.op = str(raw, 'op');
    r.patchJson = str(raw, 'patchJson');
    r.baseRev = num(raw, 'baseRev');
    r.evidence = str(raw, 'evidence');
    r.status = str(raw, 'status');
    r.reviewerId = str(raw, 'reviewerId');
    r.reviewNote = str(raw, 'reviewNote');
    r.reviewedAt = num(raw, 'reviewedAt');
    r.createdAt = num(raw, 'createdAt');
    return r;
  }
}

/** 变更流（sync-pull 返回） */
export class ChangeLogInfo {
  logId: string = '';
  rev: number = 0;
  action: string = '';
  targetMemberId: string = '';
  summary: string = '';
  actor: string = '';
  createdAt: number = 0;

  static fromJson(raw: Record<string, Object>): ChangeLogInfo {
    const c: ChangeLogInfo = new ChangeLogInfo();
    c.logId = str(raw, 'logId');
    c.rev = num(raw, 'rev');
    c.action = str(raw, 'action');
    c.targetMemberId = str(raw, 'targetMemberId');
    c.summary = str(raw, 'summary');
    c.actor = str(raw, 'actor');
    c.createdAt = num(raw, 'createdAt');
    return c;
  }
}

/** 访问申请单 */
export class AccessRequestInfo {
  requestId: string = '';
  familyId: string = '';
  familyTitle: string = '';
  applicantId: string = '';
  applicantName: string = '';
  kind: string = '';
  relationClaim: string = '';
  branchClaimUid: string = '';
  evidence: string = '';
  grantedRole: string = '';
  expireAt: number = 0;
  status: string = '';
  reviewNote: string = '';
  reviewedAt: number = 0;
  createdAt: number = 0;

  static fromJson(raw: Record<string, Object>): AccessRequestInfo {
    const a: AccessRequestInfo = new AccessRequestInfo();
    a.requestId = str(raw, 'requestId');
    a.familyId = str(raw, 'familyId');
    a.familyTitle = str(raw, 'familyTitle');
    a.applicantId = str(raw, 'applicantId');
    a.applicantName = str(raw, 'applicantName');
    a.kind = str(raw, 'kind');
    a.relationClaim = str(raw, 'relationClaim');
    a.branchClaimUid = str(raw, 'branchClaimUid');
    a.evidence = str(raw, 'evidence');
    a.grantedRole = str(raw, 'grantedRole');
    a.expireAt = num(raw, 'expireAt');
    a.status = str(raw, 'status');
    a.reviewNote = str(raw, 'reviewNote');
    a.reviewedAt = num(raw, 'reviewedAt');
    a.createdAt = num(raw, 'createdAt');
    return a;
  }
}

/** 黄页条目（只含索引元数据） */
export class DirectoryEntry {
  dirId: string = '';
  familyId: string = '';
  surname: string = '';
  region: string = '';
  title: string = '';
  branchSummary: string = '';
  memberCountBand: string = '';
  coverRef: string = '';
  accessHint: string = '';
  updatedAt: number = 0;

  static fromJson(raw: Record<string, Object>): DirectoryEntry {
    const d: DirectoryEntry = new DirectoryEntry();
    d.dirId = str(raw, 'dirId');
    d.familyId = str(raw, 'familyId');
    d.surname = str(raw, 'surname');
    d.region = str(raw, 'region');
    d.title = str(raw, 'title');
    d.branchSummary = str(raw, 'branchSummary');
    d.memberCountBand = str(raw, 'memberCountBand');
    d.coverRef = str(raw, 'coverRef');
    d.accessHint = str(raw, 'accessHint');
    d.updatedAt = num(raw, 'updatedAt');
    return d;
  }
}

/** 墓葬条目（公开数据） */
export class GraveEntry {
  graveId: string = '';
  familyId: string = '';
  uid: string = '';
  personName: string = '';
  generation: number = 0;
  bookTitle: string = '';
  graveName: string = '';
  lng: number = 0;
  lat: number = 0;
  altitude: number = 0;
  facing: string = '';
  bearing: string = '';
  routeNote: string = '';
  photoRefs: string = '';
  visibility: string = 'PUBLIC';
  precision: string = 'EXACT';
  rev: number = 0;
  updatedAt: number = 0;

  static fromJson(raw: Record<string, Object>): GraveEntry {
    const g: GraveEntry = new GraveEntry();
    g.graveId = str(raw, 'graveId');
    g.familyId = str(raw, 'familyId');
    g.uid = str(raw, 'uid');
    g.personName = str(raw, 'personName');
    g.generation = num(raw, 'generation');
    g.bookTitle = str(raw, 'bookTitle');
    g.graveName = str(raw, 'graveName');
    g.lng = num(raw, 'lng');
    g.lat = num(raw, 'lat');
    g.altitude = num(raw, 'altitude');
    g.facing = str(raw, 'facing');
    g.bearing = str(raw, 'bearing');
    g.routeNote = str(raw, 'routeNote');
    g.photoRefs = str(raw, 'photoRefs');
    g.visibility = str(raw, 'visibility').length > 0 ? str(raw, 'visibility') : 'PUBLIC';
    g.precision = str(raw, 'precision').length > 0 ? str(raw, 'precision') : 'EXACT';
    g.rev = num(raw, 'rev');
    g.updatedAt = num(raw, 'updatedAt');
    return g;
  }

  hasLocation(): boolean {
    return this.lng !== 0 || this.lat !== 0;
  }

  locationText(): string {
    if (!this.hasLocation()) {
      return '未定位';
    }
    return this.lng.toFixed(5) + ', ' + this.lat.toFixed(5);
  }
}

/** 一次同步的结果 */
export class SyncResult {
  ok: boolean = false;
  familyId: string = '';
  role: string = '';
  headRev: number = 0;
  fromRev: number = 0;
  applied: number = 0;
  graves: number = 0;
  deleted: number = 0;
  pendingOutbox: number = 0;
  rejectedOutbox: number = 0;
  /** 本次推送失败（仍待重试）的条数 */
  failedOutbox: number = 0;
  /** 同步结束后仍留在 outbox 的条数（>0 表示没全部传完） */
  remainingOutbox: number = 0;
  conflicts: string[] = [];
  warnings: string[] = [];
  /** 同步过程中发现的ID与亲属关系异常（供界面弹窗提示） */
  integrityIssues: string[] = [];
  /** 因编号对应不同人物而暂缓回放的条数（>0 时云端基线不前进） */
  integrityBlocked: number = 0;
  message: string = '';
}

/** 云函数统一返回体 */
export class CloudFunctionReply {
  code: number = 0;
  message: string = '';
  reason: string = '';
  data: Record<string, Object> | null = null;
}

/** 把 Record 里的字段安全读成字符串 */
export function str(raw: Record<string, Object> | null | undefined, key: string): string {
  if (raw === undefined || raw === null) {
    return '';
  }
  const v: Object | undefined = raw[key];
  if (v === undefined || v === null) {
    return '';
  }
  return String(v);
}

/** 把 Record 里的字段安全读成数字 */
export function num(raw: Record<string, Object> | null | undefined, key: string): number {
  if (raw === undefined || raw === null) {
    return 0;
  }
  const v: Object | undefined = raw[key];
  if (v === undefined || v === null) {
    return 0;
  }
  const n: number = Number(v);
  return Number.isNaN(n) ? 0 : n;
}

/** 把 Record 里的字段安全读成布尔 */
export function bool(raw: Record<string, Object> | null | undefined, key: string): boolean {
  if (raw === undefined || raw === null) {
    return false;
  }
  const v: Object | undefined = raw[key];
  return v === true || v === 'true' || Number(v) === 1;
}

/** 从 JSON 对象里取数组（云函数返回值的各个集合） */
export function objectList(raw: Record<string, Object> | null, key: string): Record<string, Object>[] {
  const out: Record<string, Object>[] = [];
  if (raw === null || raw === undefined) {
    return out;
  }
  const v: Object | undefined = raw[key];
  if (v === undefined || v === null) {
    return out;
  }
  const arr: Object[] = v as Object[];
  if (arr === undefined || arr === null || arr.length === undefined) {
    return out;
  }
  for (let i: number = 0; i < arr.length; i++) {
    out.push(arr[i] as Record<string, Object>);
  }
  return out;
}
