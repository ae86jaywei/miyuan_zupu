'use strict';
/**
 * 觅源 · 家族协作云函数：directory-upsert
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 族谱黄页上架 / 下架（§五.11）。
 * ⚠️ 黄页默认**不可搜**：
 *   - directoryEnabled=true  → 写 Family.directoryEnabled + upsert 黄页行；
 *   - directoryEnabled=false → 置 false 并**物理删除**黄页行（不是写一行 false 靠端侧过滤）。
 * 服务端做字段白名单校验，拒绝任何疑似人物数据。
 */
const S = require('_zupu_shared');

module.exports.handler = S.createHandler('directory-upsert', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  await S.requireMember(familyId, userId, S.ROLE.EDITOR, log);
  const family = await S.getFamily(familyId);
  const enabled = S.bool(params, 'directoryEnabled', family.directoryEnabled === true);

  const fields = {};
  S.DIRECTORY_FIELDS.forEach((k) => {
    if (params[k] !== undefined && params[k] !== null) {
      fields[k] = String(params[k]).trim();
    }
  });
  // 字段白名单兜底：只允许索引元数据，严禁人物数据
  S.assertDirectoryPayload(fields, S.DIRECTORY_FIELDS, S.DIRECTORY_FORBIDDEN_KEYS, S.MEMBER_COUNT_BANDS);

  const now = S.nowMs();
  const dirId = familyId;
  const existing = await S.queryOne(S.T.DIRECTORY, [['dirId', '=', dirId]]);

  family.directoryEnabled = enabled;
  family.directoryUpdatedAt = now;
  family.updatedAt = now;

  if (!enabled) {
    // 下架 = 物理删除该行
    if (existing !== null) {
      await S.deleteByType(S.T.DIRECTORY, [existing]);
    }
    await S.upsertOne(S.T.FAMILY, Object.assign({}, family));
    return { ok: true, directoryEnabled: false, removed: existing !== null };
  }

  const row = {
    dirId: dirId,
    familyId: familyId,
    surname: fields.surname !== undefined ? fields.surname : (existing ? existing.surname : ''),
    region: fields.region !== undefined ? fields.region : (existing ? existing.region : ''),
    title: fields.title !== undefined ? fields.title : (existing ? existing.title : family.title),
    branchSummary: fields.branchSummary !== undefined
      ? fields.branchSummary : (existing ? existing.branchSummary : ''),
    memberCountBand: fields.memberCountBand !== undefined
      ? fields.memberCountBand : (existing ? existing.memberCountBand : ''),
    coverRef: fields.coverRef !== undefined ? fields.coverRef : (existing ? existing.coverRef : ''),
    accessHint: fields.accessHint !== undefined
      ? fields.accessHint : (existing ? existing.accessHint : '需谱主审核后可查看'),
    createdAt: existing ? Number(existing.createdAt || now) : now,
    updatedAt: now,
    rev: Number(family.rev || 0),
    actor: userId
  };
  const res = await S.writeBatch([
    { op: 'upsert', type: S.T.DIRECTORY, objects: [row], label: 'FamilyDirectory' },
    { op: 'upsert', type: S.T.FAMILY, objects: [Object.assign({}, family)], label: 'Family' }
  ], log);
  if (!res.ok) {
    throw new S.BizError(S.CODE.INTERNAL, '黄页写入失败：' + res.done[res.done.length - 1].label);
  }
  return { ok: true, directoryEnabled: true };

});
