import { hilog } from '@kit.PerformanceAnalysisKit';
import { relationalStore } from '@kit.ArkData';
import { AccountService } from './AccountService';
import { Genealogy, createEmptyGenealogy, Person } from 'common_base';
import { GenealogyService } from './GenealogyService';
import { GenealogyStore } from '../store/GenealogyStore';
import {
  AccessKind,
  AccessRequestInfo,
  ChangeRequestInfo,
  CloudFamilyInspect,
  FamilySummary,
  MemberInfo,
  Role,
  SyncMode,
  bool,
  canEdit,
  num,
  objectList,
  str
} from 'common_base';
import { OutboxItem, OutboxService } from './OutboxService';
import { CloudFunctionClient } from './CloudFunctionClient';

const TAG: string = '[Genealogy][Family]';

/** 申请默认期限（与云侧 VIEW_APPLY_DEFAULT_DAYS 保持一致） */
export const VIEW_APPLY_DEFAULT_DAYS: number = 180;

/**
 * 家族协作服务（单例）。
 *
 * 职责边界（方案 §七）：
 *  - 家族业务的云函数入口（在 CloudFunctionClient 网关之上加业务语义）；
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

  /**
   * 本地「已删除云家族」墓碑（存 genealogy meta，跨重启保留）。
   *
   * 删除不彻底时云端可能残留 Membership / 族人数据，导致 family-list-mine 仍返回该家族、
   * 端侧又能「导入本机」。墓碑让这些家族彻底从列表消失，并在导入入口做最后一道拦截。
   */
  static readonly TOMBSTONE_KEY: string = 'deleted_family_ids';

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
    const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call('family-list-mine', {});
    const out: FamilySummary[] = [];
    const rows: Record<string, Object>[] = objectList(data, 'families');
    // 已在本机标记删除的家族：即使云端还有 Membership 残留，也不再展示、更不允许导入。
    const tombstones: string[] = await this.deletedFamilyIds();
    for (let i: number = 0; i < rows.length; i++) {
      const raw: Record<string, Object> = rows[i];
      const f: FamilySummary = new FamilySummary();
      f.familyId = str(raw, 'familyId');
      if (tombstones.indexOf(f.familyId) >= 0) {
        continue;
      }
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

  /**
   * 从云端刷新「我在当前家族的角色」。
   *
   * 谱主在「成员与访问申请」里给成员提权/降权后，成员端的可写判定只依赖本地缓存的
   * book.familyRole（发布为 gpFamilyRole）。若不主动刷新，成员端会一直停在旧的「只读」。
   * 返回刷新后的角色（未接入云家族 / 未登录 / 失败时返回当前缓存值）。
   */
  async refreshMyRole(): Promise<string> {
    const familyId: string = this.currentFamilyId();
    if (familyId.length === 0 || !this.isCloudFamily()) {
      return this.currentRole();
    }
    const account: AccountService = AccountService.getInstance();
    if (!account.isLoggedIn() || !account.isCloudReady()) {
      return this.currentRole();
    }
    try {
      const list: FamilySummary[] = await this.listMine();
      for (let i: number = 0; i < list.length; i++) {
        if (list[i].familyId === familyId && list[i].role.length > 0) {
          return list[i].role;
        }
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'refreshMyRole failed: %{public}s', JSON.stringify(err));
    }
    return this.currentRole();
  }

  /** 创建家族：服务端生成 familyId 与加入码，然后绑定到当前本地族谱 */
  async createFamily(title: string, nickName: string): Promise<FamilySummary> {
    const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call('family-create', {
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
    const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call('family-join', {
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
    const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call('family-acl-list',
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

  /**
   * 调整成员角色 / 分支 / 期限 / 状态。
   * 返回云端实际生效的角色：与请求不一致时抛错，避免「提示已设置、实际没变」。
   */
  async updateMember(familyId: string, userId: string, role: string, branchRootUid: string,
    expireAt: number, status: string): Promise<string> {
    const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call('family-acl-set', {
      'familyId': familyId, 'action': 'UPDATE', 'targetUserId': userId, 'role': role,
      'branchRootUid': branchRootUid, 'expireAt': expireAt, 'status': status
    });
    const applied: string = str(data, 'role');
    if (role.length > 0 && applied.length > 0 && applied !== role) {
      throw new Error('角色未能保存（云端当前为 ' + applied + '）');
    }
    return applied.length > 0 ? applied : role;
  }

  /** 轮换加入码（旧码立即失效，对应方案 §八.3 邀请码治理） */
  async rotateInvite(familyId: string, inviteExpireAt: number, inviteRole: string): Promise<string> {
    const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call('family-acl-set', {
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
      // 谱主可能刚把本账号提升为编辑者：先拉一次云端角色，避免仍按旧的「只读」处理
      await this.refreshMyRole();
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
      // 谱主可能刚把本账号提升为编辑者：先拉一次云端角色，避免仍按旧的「只读」处理
      await this.refreshMyRole();
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

  /** 谱主直写（member-direct-write，字段级 LWW）；离线上传队列复用同一参数规则 */
  async directWrite(familyId: string, op: string, uid: string, patchJson: string,
    baseRev: number): Promise<void> {
    await CloudFunctionClient.getInstance().call('member-direct-write', {
      'familyId': familyId,
      'uid': uid,
      'op': op === 'DELETE' ? 'DELETE_REQ' : op,
      'patchJson': patchJson,
      'baseRev': baseRev
    });
  }

  /** 编辑者提交审核（change-submit）；离线上传队列复用同一参数规则 */
  async submitChange(familyId: string, op: string, uid: string, patchJson: string, baseRev: number,
    evidence: string): Promise<void> {
    await CloudFunctionClient.getInstance().call('change-submit', {
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
    const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call(
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
    const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call('change-review', {
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
    const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call('access-request', {
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
    await CloudFunctionClient.getInstance().call('access-review', {
      'requestId': requestId,
      'decision': approve ? 'APPROVED' : 'REJECTED',
      'note': note,
      'grantedRole': grantedRole,
      'expireAt': expireAt
    });
  }

  /** 谱主的待审申请 */
  async listPendingAccess(familyId: string): Promise<AccessRequestInfo[]> {
    const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call('access-list',
      { 'familyId': familyId, 'mode': 'inbox' });
    return FamilyService.parseAccessList(data);
  }

  /** 我的全部申请 */
  async listMyAccess(): Promise<AccessRequestInfo[]> {
    const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call('access-list',
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
    if (await this.isFamilyDeleted(summary.familyId)) {
      throw new Error('该云族谱已删除，无法再导入');
    }
    const svc: GenealogyService = GenealogyService.getInstance();
    const book: Genealogy = await svc.createGenealogy(summary.title.length > 0 ? summary.title : '云端族谱');
    book.familyId = summary.familyId;
    book.syncMode = SyncMode.CLOUD_PENDING;
    book.familyRole = summary.role;
    // 首次接入必须从 rev=0 拉全量基线。若沿用 Family.rev，sync-pull 会走增量路径，
    // 只能拿到「之后的」变更，导入结果必然残缺。
    book.cloudRev = 0;
    await svc.saveBook(book);
    await this.bindLocalBook(summary.familyId, summary.role, summary.title, summary.bookKey, 0);
    return book;
  }

  /**
   * 解散云家族（仅谱主）。会清空该 familyId 下全部云端数据，不可恢复。
   * 成功后：写入本地墓碑（阻止残留数据被再次导入），并解除当前族谱的云绑定。
   */
  async deleteCloudFamily(familyId: string, confirmTitle: string): Promise<void> {
    // 云端按批返回 202（PARTIAL），端侧持续调用直到明确返回 DELETED；
    // 云函数每次调用有自己的时间预算，不能只调一次就认为删完了。
    let rounds: number = 0;
    let removed: number = 0;
    while (true) {
      rounds++;
      try {
        const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call('family-delete', {
          'familyId': familyId,
          'confirmTitle': confirmTitle
        }, 590 * 1000);
        const raw: Object | undefined = data === null ? undefined : data['status'];
        const status: string = raw === undefined ? '' : String(raw);
        const legacy: Object | undefined = data === null ? undefined : data['ok'];
        removed += num(data, 'deleted');
        // 兼容尚未更新的旧版云函数（返回 ok:true 而无 status），避免部署先后顺序造成误判
        if (status === 'DELETED' || legacy === true) {
          break;
        }
        // 明确未完成：继续下一轮；其它未知返回一律报错，绝不当作删除成功
        if (status !== 'PARTIAL') {
          throw new Error('云端未确认删除完成');
        }
        if (rounds >= 300) {
          throw new Error('删除未完成：云端仍有残留（已删除 ' + removed.toString() + ' 条），请稍后重试');
        }
      } catch (err) {
        const e: Error = err as Error;
        const code: number = CloudFunctionClient.errorCode(e);
        if (code === 202) {
          if (rounds >= 300) {
            throw new Error('删除未完成：云端仍有残留（已删除 ' + removed.toString() + ' 条），请稍后重试');
          }
          continue;
        }
        // 云函数可能已在服务端删完、但响应超时；再次确认时云端返回 404「族谱不存在」。
        // 按删除成功处理，但同样写墓碑，防止云端残留的关系把家族重新带回列表。
        if (code === 404 || e.message.indexOf('族谱不存在') >= 0) {
          break;
        }
        throw e;
      }
    }
    await this.markFamilyDeleted(familyId);
    this.unbindCloudFamily(familyId, '已退出云家族');
  }

  // ---------------------------------------------------------------- 已删除家族墓碑

  /** 读取本机记录的「已删除云家族」ID 列表 */
  async deletedFamilyIds(): Promise<string[]> {
    const text: string = await GenealogyService.getInstance().getMetaValue(FamilyService.TOMBSTONE_KEY);
    if (text.length === 0) {
      return [];
    }
    let parsed: string[] = [];
    try {
      parsed = JSON.parse(text) as string[];
    } catch (err) {
      hilog.warn(0x0000, TAG, 'parse deleted family ids failed');
      return [];
    }
    const list: string[] = [];
    if (parsed === null || parsed === undefined) {
      return list;
    }
    for (let i: number = 0; i < parsed.length; i++) {
      const raw: string = parsed[i] === undefined || parsed[i] === null ? '' : String(parsed[i]).trim();
      if (raw.length > 0 && list.indexOf(raw) < 0) {
        list.push(raw);
      }
    }
    return list;
  }

  async isFamilyDeleted(familyId: string): Promise<boolean> {
    if (familyId.length === 0) {
      return false;
    }
    return (await this.deletedFamilyIds()).indexOf(familyId) >= 0;
  }

  /** 记录删除墓碑：保留最近 500 个，避免元信息无限增长 */
  async markFamilyDeleted(familyId: string): Promise<void> {
    if (familyId.length === 0) {
      return;
    }
    const list: string[] = await this.deletedFamilyIds();
    if (list.indexOf(familyId) < 0) {
      list.push(familyId);
    }
    const kept: string[] = list.length > 500 ? list.slice(list.length - 500) : list;
    await GenealogyService.getInstance().setMetaValue(FamilyService.TOMBSTONE_KEY, JSON.stringify(kept));
  }

  /** 重新创建 / 加入同 ID 家族时清除墓碑（正常不会发生，仅作自愈） */
  async clearFamilyDeleted(familyId: string): Promise<void> {
    const list: string[] = await this.deletedFamilyIds();
    const idx: number = list.indexOf(familyId);
    if (idx < 0) {
      return;
    }
    list.splice(idx, 1);
    await GenealogyService.getInstance().setMetaValue(FamilyService.TOMBSTONE_KEY, JSON.stringify(list));
  }

  // ---------------------------------------------------------------- 导入前预检

  /**
   * 云端族谱完整性预检：主表是否存在、族人总数、谱书是否存在。
   *
   * 「删除不彻底」的典型形态是：FamilyBook / FamilyDirectory 已被删，FamilyMember 却残留，
   * 此时导入会把幸存的族人按断裂的父子关系拆成几百个孤立分支。导入前必须先做这一步。
   */
  async inspectCloudFamily(familyId: string): Promise<CloudFamilyInspect> {
    const info: CloudFamilyInspect = new CloudFamilyInspect();
    try {
      const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call('sync-pull', {
        'familyId': familyId, 'sinceRev': 0, 'limit': 1, 'offset': 0
      });
      if (data === null) {
        return info;
      }
      info.exists = true;
      info.memberCount = num(data, 'memberCount');
      const bookRaw: Object | undefined = data['book'];
      info.hasBook = bookRaw !== undefined && bookRaw !== null;
      info.headRev = num(data, 'headRev');
    } catch (err) {
      const e: Error = err as Error;
      const code: number = CloudFunctionClient.errorCode(e);
      if (code === 404 || code === 403 || e.message.indexOf('族谱不存在') >= 0) {
        info.exists = false;
        return info;
      }
      throw e;
    }
    return info;
  }

  /**
   * 导入完成后校验本地数据是否完整，返回空串表示通过。
   * @param expectedMemberCount 云端统计的族人总数（0 表示无法统计，跳过人数校验）
   */
  verifyImportedIntegrity(expectedMemberCount: number): string {
    const people: Person[] = GenealogyService.getInstance().getPeople();
    const total: number = people.length;
    if (expectedMemberCount > 0 && total < expectedMemberCount) {
      return '云端应有 ' + expectedMemberCount.toString() + ' 位族人，实际仅导入 ' + total.toString() +
        ' 位，数据不完整';
    }
    if (total === 0) {
      return '';
    }
    const ids: Set<string> = new Set<string>();
    for (let i: number = 0; i < total; i++) {
      const uid: string = people[i].uid.trim().toUpperCase();
      if (uid.length > 0) {
        ids.add(uid);
      }
    }
    let missingParent: number = 0;
    for (let i: number = 0; i < total; i++) {
      const fid: string = people[i].fatherId.trim().toUpperCase();
      if (fid.length > 0 && !ids.has(fid)) {
        missingParent++;
      }
    }
    // 少量父节点缺失可能是历史脏数据；超过 1% 或 5 人，说明云端父子链已被删除打断，
    // 继续导入只会得到「几百个分支」，直接拒绝。
    if (missingParent >= 5 || missingParent * 100 / total >= 1) {
      return '检测到 ' + missingParent.toString() + ' 位族人的父系记录缺失（云端可能仍有删除残留），' +
        '导入后会断成多个分支，已取消';
    }
    return '';
  }

  /** 解除某家族与本机的绑定（云端已删除或不可用时），避免卡在「已接入但无法同步」 */
  unbindCloudFamily(familyId: string, statusText: string): void {
    this.roleCache.delete(familyId);
    this.familyCache.delete(familyId);
    const svc: GenealogyService = GenealogyService.getInstance();
    if (svc.getBook().familyId === familyId) {
      svc.setBookCloudState('', SyncMode.LOCAL, '', 0);
      this.publishState(SyncMode.LOCAL, '');
      this.setPendingCount(0);
      this.setSyncStatus(statusText);
    }
  }

  /** 空族谱占位（供 UI 判断） */
  static emptyBook(): Genealogy {
    return createEmptyGenealogy();
  }
}
