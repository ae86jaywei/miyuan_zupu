import { hilog } from '@kit.PerformanceAnalysisKit';
import { relationalStore } from '@kit.ArkData';
import { AccountService } from './AccountService';
import { Genealogy, createEmptyGenealogy } from '../model/Genealogy';
import { GenealogyService } from './GenealogyService';
import { GenealogyStore } from '../store/GenealogyStore';
import {
  AccessKind,
  AccessRequestInfo,
  ChangeRequestInfo,
  FamilySummary,
  MemberInfo,
  Role,
  SyncMode,
  bool,
  canEdit,
  num,
  objectList,
  str
} from '../model/FamilyDomain';
import { OutboxItem, OutboxService } from './OutboxService';

const TAG: string = '[Genealogy][Family]';

/** 申请默认期限（与云侧 VIEW_APPLY_DEFAULT_DAYS 保持一致） */
export const VIEW_APPLY_DEFAULT_DAYS: number = 180;

/**
 * 家族协作服务（单例）。
 *
 * 职责边界（方案 §七）：
 *  - 云函数的**唯一调用封装点**（AccountService.callFunction 之上加业务语义）；
 *  - 家族身份（familyId / 角色 / 分支）的本地缓存与发布（AppStorage + genealogy 表）；
 *  - 写路径编排：在线 → 云函数；离线 → outbox 排队（由 FamilySyncService 补传）；
 *  - 本地族谱在「仅本机 / 已接入云家族」两种模式间切换。
 *
 * 注意：**端侧不直接读写协作 Zone**，所有数据都经云函数（§五.9）。
 */
export class FamilyService {
  private static instance: FamilyService | null = null;

  /** familyId → 我在这部谱里的角色缓存 */
  private roleCache: Map<string, string> = new Map<string, string>();
  private familyCache: Map<string, FamilySummary> = new Map<string, FamilySummary>();

  static readonly KEY_SYNC_MODE: string = 'gpSyncMode';
  static readonly KEY_SYNC_STATUS: string = 'gpSyncStatus';
  static readonly KEY_PENDING_COUNT: string = 'gpPendingCount';
  static readonly KEY_FAMILY_ROLE: string = 'gpFamilyRole';
  static readonly KEY_FAMILY_TITLE: string = 'gpFamilyTitle';
  static readonly KEY_OFFLINE: string = 'gpOffline';

  static getInstance(): FamilyService {
    if (FamilyService.instance === null) {
      FamilyService.instance = new FamilyService();
    }
    return FamilyService.instance;
  }

  // ---------------------------------------------------------------- 模式与缓存

  /** 当前本地族谱是否已接入云家族 */
  syncMode(): string {
    const v: string | undefined = AppStorage.get<string>(FamilyService.KEY_SYNC_MODE);
    return v !== undefined ? v : SyncMode.LOCAL;
  }

  isCloudFamily(): boolean {
    return this.syncMode() !== SyncMode.LOCAL;
  }

  /** 当前家族ID（未接入时取本地族谱上的 familyId） */
  currentFamilyId(): string {
    const id: string = AccountService.getInstance().getFamilyId();
    if (id.length > 0) {
      return id;
    }
    return GenealogyService.getInstance().getBook().familyId;
  }

  /** 我在当前家族的角色（未接入返回空串） */
  currentRole(): string {
    const v: string | undefined = AppStorage.get<string>(FamilyService.KEY_FAMILY_ROLE);
    return v !== undefined ? v : '';
  }

  /** 是否可写（谱主 / 编辑者） */
  canEditCurrent(): boolean {
    return canEdit(this.currentRole());
  }

  isOwnerCurrent(): boolean {
    return this.currentRole() === Role.OWNER;
  }

  roleOf(familyId: string): string {
    const cached: string | undefined = this.roleCache.get(familyId);
    return cached !== undefined ? cached : '';
  }

  /** 发布模式与角色到 AppStorage（主页/设置页订阅） */
  publishState(mode: string, role: string): void {
    AppStorage.setOrCreate<string>(FamilyService.KEY_SYNC_MODE, mode);
    FamilyService.setValue<string>(FamilyService.KEY_FAMILY_ROLE, role);
  }

  /** 同步状态提示（同步中 / 离线待传 / 有冲突） */
  setSyncStatus(text: string): void {
    AppStorage.setOrCreate<string>(FamilyService.KEY_SYNC_STATUS, text);
  }

  syncStatus(): string {
    const v: string | undefined = AppStorage.get<string>(FamilyService.KEY_SYNC_STATUS);
    return v !== undefined ? v : '';
  }

  setPendingCount(n: number): void {
    AppStorage.setOrCreate<number>(FamilyService.KEY_PENDING_COUNT, n);
  }

  pendingCount(): number {
    const v: number | undefined = AppStorage.get<number>(FamilyService.KEY_PENDING_COUNT);
    return v !== undefined ? v : 0;
  }

  /** 统一的 put：先确保 key 存在再赋值，避免 undefined 覆盖已订阅值 */
  private static setValue<T>(key: string, value: T): void {
    if (value === undefined) {
      return;
    }
    AppStorage.setOrCreate<T>(key, value);
    AppStorage.set<T>(key, value);
  }

  // ---------------------------------------------------------------- 家族生命周期

  /**
   * 家族创建成功后绑定到本地族谱。
   * 不触发上传：上传走 FamilyBootstrapService.publishCurrent（用户明确点击「发布到云端」）。
   */
  async bindLocalBook(familyId: string, role: string, title: string, bookKey: number, rev: number): Promise<void> {
    AccountService.getInstance().setFamilyId(familyId);
    const svc: GenealogyService = GenealogyService.getInstance();
    const book: Genealogy = svc.getBook();
    book.familyId = familyId;
    book.syncMode = SyncMode.CLOUD_PENDING;
    book.cloudRev = rev;
    book.familyRole = role;
    if (title.length > 0 && book.title.length === 0) {
      book.title = title;
    }
    await svc.saveBook(book);
    this.roleCache.set(familyId, role);
    this.publishState(SyncMode.CLOUD_PENDING, role);
    FamilyService.setValue<string>(FamilyService.KEY_FAMILY_TITLE, title);
    GenealogyStore.notifyChanged();
  }

  /**
   * 切换当前打开的族谱时，同步家族态（角色 / 同步模式 / familyId）。
   * 由 GenealogyService.saveBook 之后统一调用。
   */
  applyBookFamilyState(): void {
    const book: Genealogy = GenealogyService.getInstance().getBook();
    const familyId: string = book.familyId.length > 0 ? book.familyId : '';
    AccountService.getInstance().setFamilyId(familyId);
    if (familyId.length === 0) {
      this.publishState(SyncMode.LOCAL, '');
      this.setPendingCount(0);
      this.setSyncStatus('');
      return;
    }
    const mode: string = book.syncMode.length > 0 ? book.syncMode : SyncMode.CLOUD_READY;
    this.publishState(mode, book.familyRole);
    this.roleCache.set(familyId, book.familyRole);
    FamilyService.setValue<string>(FamilyService.KEY_FAMILY_TITLE, book.title);
  }

  /** 拉取「我参与的全部家族」 */
  async listMine(): Promise<FamilySummary[]> {
    const data: Record<string, Object> | null = await AccountService.getInstance().callFunction('family-list-mine', {});
    const out: FamilySummary[] = [];
    const rows: Record<string, Object>[] = objectList(data, 'families');
    for (let i: number = 0; i < rows.length; i++) {
      const raw: Record<string, Object> = rows[i];
      const f: FamilySummary = new FamilySummary();
      f.familyId = str(raw, 'familyId');
      f.title = str(raw, 'title');
      f.bookKey = num(raw, 'bookKey');
      f.rev = num(raw, 'rev');
      f.aclVersion = num(raw, 'aclVersion');
      f.directoryEnabled = bool(raw, 'directoryEnabled');
      f.inviteCode = str(raw, 'inviteCode');
      f.role = str(raw, 'role');
      f.membershipStatus = str(raw, 'membershipStatus');
      f.branchRootUid = str(raw, 'branchRootUid');
      f.expireAt = num(raw, 'expireAt');
      f.createdAt = num(raw, 'createdAt');
      f.localBookId = this.findLocalBook(f.familyId);
      this.roleCache.set(f.familyId, f.role);
      this.familyCache.set(f.familyId, f);
      // 云端角色才是权威：与本地不一致时回写（例如谱主被误改后自愈为 OWNER）
      if (f.familyId === this.currentFamilyId() && f.role.length > 0 && f.role !== this.currentRole()) {
        const svc: GenealogyService = GenealogyService.getInstance();
        svc.setBookCloudState(f.familyId, svc.getBook().syncMode, f.role, f.rev);
        this.publishState(svc.getBook().syncMode, f.role);
      }
      out.push(f);
    }
    return out;
  }

  /** 创建家族：服务端生成 familyId 与加入码，然后绑定到当前本地族谱 */
  async createFamily(title: string, nickName: string): Promise<FamilySummary> {
    const data: Record<string, Object> | null = await AccountService.getInstance().callFunction('family-create', {
      'title': title,
      'nickName': nickName,
      'unionId': AccountService.getInstance().getUnionId()
    });
    const summary: FamilySummary = new FamilySummary();
    summary.familyId = str(data, 'familyId');
    summary.inviteCode = str(data, 'inviteCode');
    summary.role = str(data, 'role');
    summary.rev = num(data, 'rev');
    summary.title = title;
    if (summary.familyId.length === 0) {
      throw new Error('创建家族失败：云侧未返回 familyId');
    }
    await this.bindLocalBook(summary.familyId, summary.role, title, 0, summary.rev);
    return summary;
  }

  /**
   * 用加入码加入家族（门槛②）。
   * 成功后若本机已有该谱则切换，否则由调用方决定是否新建本地谱。
   */
  async joinFamily(inviteCode: string, nickName: string): Promise<FamilySummary> {
    const data: Record<string, Object> | null = await AccountService.getInstance().callFunction('family-join', {
      'inviteCode': inviteCode.trim().toUpperCase(),
      'nickName': nickName
    });
    const summary: FamilySummary = new FamilySummary();
    summary.familyId = str(data, 'familyId');
    summary.title = str(data, 'title');
    summary.role = str(data, 'role');
    if (summary.familyId.length === 0) {
      throw new Error('加入失败：云侧未返回家族信息');
    }
    this.roleCache.set(summary.familyId, summary.role);
    return summary;
  }

  /** 成员列表（仅谱主） */
  async listMembers(familyId: string): Promise<MemberInfo[]> {
    const data: Record<string, Object> | null = await AccountService.getInstance().callFunction('family-acl-list',
      { 'familyId': familyId });
    const out: MemberInfo[] = [];
    const rows: Record<string, Object>[] = objectList(data, 'memberships');
    for (let i: number = 0; i < rows.length; i++) {
      const m: MemberInfo = MemberInfo.fromJson(rows[i]);
      m.displayName = m.nickName.length > 0 ? m.nickName : m.userId;
      out.push(m);
    }
    return out;
  }

  /** 调整成员角色 / 分支 / 期限 / 状态 */
  async updateMember(familyId: string, userId: string, role: string, branchRootUid: string,
    expireAt: number, status: string): Promise<void> {
    await AccountService.getInstance().callFunction('family-acl-set', {
      'familyId': familyId, 'action': 'UPDATE', 'targetUserId': userId, 'role': role,
      'branchRootUid': branchRootUid, 'expireAt': expireAt, 'status': status
    });
  }

  /** 轮换加入码（旧码立即失效，对应方案 §八.3 邀请码治理） */
  async rotateInvite(familyId: string, inviteExpireAt: number, inviteRole: string): Promise<string> {
    const data: Record<string, Object> | null = await AccountService.getInstance().callFunction('family-acl-set', {
      'familyId': familyId, 'action': 'ROTATE_INVITE', 'inviteExpireAt': inviteExpireAt, 'inviteRole': inviteRole
    });
    return str(data, 'inviteCode');
  }

  // ---------------------------------------------------------------- 写路径

  /**
   * 保存人物后调用：在线则直接上云，离线则入 outbox。
   * @param op ADD / UPDATE / DELETE
   * @param patchJson 字段级 diff（云端审核 / 直写使用）
   */
  async afterPersonSaved(op: string, uid: string, name: string, patchJson: string,
    baseRev: number): Promise<string> {
    const svc: GenealogyService = GenealogyService.getInstance();
    const familyId: string = svc.getBook().familyId;
    if (this.syncMode() === SyncMode.LOCAL || familyId.length === 0) {
      return 'local';
    }
    if (!this.canEditCurrent()) {
      return 'readonly';
    }
    const store: relationalStore.RdbStore | null = svc.getStore();
    // 离线：一律排队，由同步任务补传
    if (this.isOffline() || store === null) {
      return await this.enqueueChange(familyId, op, 'person', uid, name, patchJson, baseRev);
    }
    if (this.syncMode() === SyncMode.CLOUD_PENDING) {
      // 云端还没有这部谱的基线：先排队，等用户点「发布到云端」后一起上传
      return await this.enqueueChange(familyId, op, 'person', uid, name, patchJson, baseRev);
    }
    try {
      if (this.isOwnerCurrent()) {
        await this.directWrite(familyId, op, uid, patchJson, baseRev);
        return 'synced';
      }
      await this.submitChange(familyId, op, uid, patchJson, baseRev, name);
      return 'submitted';
    } catch (err) {
      this.setOffline(true);
      hilog.warn(0x0000, TAG, 'online write failed, queued: %{public}s', JSON.stringify(err));
      return await this.enqueueChange(familyId, op, 'person', uid, name, patchJson, baseRev);
    }
  }

  /** 谱元信息变更（谱名/堂号/谱序…），走 book 作用域的 outbox 或直写 */
  async afterBookSaved(book: Genealogy): Promise<string> {
    const svc: GenealogyService = GenealogyService.getInstance();
    const familyId: string = book.familyId;
    if (this.syncMode() === SyncMode.LOCAL || familyId.length === 0) {
      return 'local';
    }
    if (!this.canEditCurrent()) {
      return 'readonly';
    }
    const payload: string = JSON.stringify(book.toCloudPayload());
    const store: relationalStore.RdbStore | null = svc.getStore();
    if (store === null || this.isOffline() || this.syncMode() === SyncMode.CLOUD_PENDING) {
      return await this.enqueueChange(familyId, 'UPDATE', 'book', book.key.toString(), book.title,
        payload, book.cloudRev);
    }
    try {
      if (this.isOwnerCurrent()) {
        await this.directWrite(familyId, 'UPDATE', '', payload, book.cloudRev);
        return 'synced';
      }
      await this.submitChange(familyId, 'UPDATE', '', payload, book.cloudRev, book.title);
      return 'submitted';
    } catch (err) {
      this.setOffline(true);
      return await this.enqueueChange(familyId, 'UPDATE', 'book', book.key.toString(), book.title,
        payload, book.cloudRev);
    }
  }

  /** 入队 */
  async enqueueChange(familyId: string, op: string, scope: string, target: string, targetName: string,
    payload: string, baseRev: number): Promise<string> {
    const svc: GenealogyService = GenealogyService.getInstance();
    const store: relationalStore.RdbStore | null = svc.getStore();
    if (store === null) {
      return 'queued-memory';
    }
    const item: OutboxItem = new OutboxItem();
    item.familyId = familyId;
    item.op = op;
    item.scope = scope;
    item.target = target;
    item.targetName = targetName;
    item.payload = payload;
    item.baseRev = baseRev;
    item.createdAt = Date.now();
    await OutboxService.getInstance().enqueue(store, item);
    const count: number = await OutboxService.getInstance().pendingCount(store, familyId);
    this.setPendingCount(count);
    this.setSyncStatus('离线待传 ' + count.toString() + ' 条');
    return 'queued';
  }

  /** 谱主直写（member-direct-write，字段级 LWW） */
  private async directWrite(familyId: string, op: string, uid: string, patchJson: string,
    baseRev: number): Promise<void> {
    await AccountService.getInstance().callFunction('member-direct-write', {
      'familyId': familyId,
      'uid': uid,
      'op': op === 'DELETE' ? 'DELETE_REQ' : op,
      'patchJson': patchJson,
      'baseRev': baseRev
    });
  }

  /** 编辑者提交审核（change-submit） */
  private async submitChange(familyId: string, op: string, uid: string, patchJson: string, baseRev: number,
    evidence: string): Promise<void> {
    await AccountService.getInstance().callFunction('change-submit', {
      'familyId': familyId,
      'op': op === 'DELETE' ? 'DELETE_REQ' : op,
      'targetUid': uid,
      'patchJson': patchJson,
      'baseRev': baseRev,
      'evidence': evidence
    });
  }

  /** 待审变更列表 */
  async listPendingChanges(familyId: string): Promise<ChangeRequestInfo[]> {
    const data: Record<string, Object> | null = await AccountService.getInstance().callFunction(
      'change-list-pending', { 'familyId': familyId });
    const out: ChangeRequestInfo[] = [];
    const rows: Record<string, Object>[] = objectList(data, 'requests');
    for (let i: number = 0; i < rows.length; i++) {
      out.push(ChangeRequestInfo.fromJson(rows[i]));
    }
    return out;
  }

  /** 审批变更（通过 / 拒绝），返回云侧的提示语 */
  async reviewChange(requestId: string, approve: boolean, note: string): Promise<string> {
    const data: Record<string, Object> | null = await AccountService.getInstance().callFunction('change-review', {
      'requestId': requestId, 'decision': approve ? 'APPROVED' : 'REJECTED', 'note': note
    });
    return str(data, 'message');
  }

  // ---------------------------------------------------------------- 访问申请（门槛①③）

  /**
   * 提交申请：服务端按可信身份写 applicantId，端侧只提供展示信息。
   * 返回：'SUBMITTED' | 'DUPLICATED' | 'ALREADY_MEMBER'
   * （已是成员/申请重复时云侧不会新建申请单，此时 requestId 为空）
   */
  async requestAccess(familyId: string, kind: string, relationClaim: string, branchClaimUid: string,
    evidence: string, applicantName: string): Promise<string> {
    const data: Record<string, Object> | null = await AccountService.getInstance().callFunction('access-request', {
      'familyId': familyId,
      'kind': kind,
      'relationClaim': relationClaim,
      'branchClaimUid': branchClaimUid,
      'evidence': evidence,
      'applicantName': applicantName
    });
    const status: string = str(data, 'status').toUpperCase();
    if (status === 'ALREADY_MEMBER') {
      return 'ALREADY_MEMBER';
    }
    if (bool(data, 'duplicated')) {
      return 'DUPLICATED';
    }
    return str(data, 'requestId').length > 0 ? 'SUBMITTED' : 'DUPLICATED';
  }

  /** 审批访问申请（唯一动作 = 写一条 Membership） */
  async reviewAccess(requestId: string, approve: boolean, note: string, grantedRole: string,
    expireAt: number): Promise<void> {
    await AccountService.getInstance().callFunction('access-review', {
      'requestId': requestId,
      'decision': approve ? 'APPROVED' : 'REJECTED',
      'note': note,
      'grantedRole': grantedRole,
      'expireAt': expireAt
    });
  }

  /** 谱主的待审申请 */
  async listPendingAccess(familyId: string): Promise<AccessRequestInfo[]> {
    const data: Record<string, Object> | null = await AccountService.getInstance().callFunction('access-list',
      { 'familyId': familyId, 'mode': 'inbox' });
    return FamilyService.parseAccessList(data);
  }

  /** 我的全部申请 */
  async listMyAccess(): Promise<AccessRequestInfo[]> {
    const data: Record<string, Object> | null = await AccountService.getInstance().callFunction('access-list',
      { 'mode': 'mine' });
    return FamilyService.parseAccessList(data);
  }

  private static parseAccessList(data: Record<string, Object> | null): AccessRequestInfo[] {
    const out: AccessRequestInfo[] = [];
    const rows: Record<string, Object>[] = objectList(data, 'requests');
    for (let i: number = 0; i < rows.length; i++) {
      out.push(AccessRequestInfo.fromJson(rows[i]));
    }
    return out;
  }

  /** 申请默认期限（门槛①：now + 180 天；门槛③：0 永久） */
  static defaultExpireAt(kind: string): number {
    if (kind === AccessKind.JOIN_CLAIM) {
      return 0;
    }
    return Date.now() + VIEW_APPLY_DEFAULT_DAYS * 24 * 3600 * 1000;
  }

  // ---------------------------------------------------------------- 工具

  /** 在本地族谱表中查找对应家族 */
  findLocalBook(familyId: string): number {
    if (familyId.length === 0) {
      return 0;
    }
    const books: Genealogy[] = GenealogyService.getInstance().getBooks();
    for (let i: number = 0; i < books.length; i++) {
      if (books[i].familyId === familyId) {
        return books[i].key;
      }
    }
    return 0;
  }

  isOffline(): boolean {
    return AppStorage.get<boolean>(FamilyService.KEY_OFFLINE) === true;
  }

  setOffline(offline: boolean): void {
    AppStorage.setOrCreate<boolean>(FamilyService.KEY_OFFLINE, offline);
  }

  /** 新建一部「云端家族」的本地占位族谱（加入别人的谱时使用） */
  async createLocalBookForFamily(summary: FamilySummary): Promise<Genealogy> {
    const svc: GenealogyService = GenealogyService.getInstance();
    const book: Genealogy = await svc.createGenealogy(summary.title.length > 0 ? summary.title : '云端族谱');
    book.familyId = summary.familyId;
    book.syncMode = SyncMode.CLOUD_PENDING;
    book.familyRole = summary.role;
    book.cloudRev = summary.rev;
    await svc.saveBook(book);
    await this.bindLocalBook(summary.familyId, summary.role, summary.title, summary.bookKey, summary.rev);
    return book;
  }

  /** 空族谱占位（供 UI 判断） */
  static emptyBook(): Genealogy {
    return createEmptyGenealogy();
  }
}