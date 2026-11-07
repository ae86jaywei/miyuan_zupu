'use strict';
/**
 * 觅源 · 家族协作云函数：family-bootstrap
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 */
const S = require('./shared');

module.exports.handler = S.createHandler('family-bootstrap', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  await S.requireMember(familyId, userId, S.ROLE.EDITOR, log);
  const family = await S.getFamily(familyId);
  const cursor = S.num(params, 'cursor', 0);
  const persons = Array.isArray(params.persons) ? params.persons : [];
  const book = (params.book && typeof params.book === 'object') ? params.book : null;
  if (persons.length > S.MAX_BATCH) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '单次上传不超过 ' + S.MAX_BATCH + ' 条，请分页调用');
  }
  const seen = new Set();
  const memberRows = [];
  const privateRows = [];
  const graveRows = [];
  const warnings = [];
  let payloadBytes = 0;
  for (let i = 0; i < persons.length; i++) {
    const person = persons[i] || {};
    const uid = S.assertUniqueUid(person.uid);
    if (seen.has(uid)) {
      throw new S.BizError(S.CODE.BAD_REQUEST, '本批次内唯一ID重复：' + uid);
    }
    seen.add(uid);
    const split = S.splitPerson(person);
    payloadBytes += S.assertPayloadSize(JSON.stringify(split.person));
    const hasPrivate = !!(split.privateData.phone || split.privateData.wechat || split.privateData.residence);
    const hasGrave = S.hasGraveData(split.grave);
    // 基线不计入 rev：rev 保持 0，首个真实变更从 1 开始（端侧 sinceRev=0 可全量拉取）
    memberRows.push(S.buildMemberRow({
      familyId: familyId, bookKey: family.bookKey || 0, uid: uid, person: split.person,
      rev: 0, actor: userId, hasPrivate: hasPrivate, hasGrave: hasGrave
    }));
    if (hasPrivate) {
      privateRows.push(S.buildPrivateRow(familyId, uid, split.privateData, userId));
    }
    if (hasGrave) {
      graveRows.push(S.buildGraveRow({
        familyId: familyId, uid: uid, person: split.grave, bookTitle: family.title,
        personName: person.name, generation: person.generation, visibility: 'PUBLIC', precision: 'EXACT',
        rev: 0, actor: userId
      }));
    }
  }
  if (payloadBytes > S.MAX_PAYLOAD_BYTES) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '本批次数据过大，请减小每页条数');
  }
  await S.upsertMany(S.T.MEMBER, memberRows);
  if (privateRows.length > 0) {
    await S.upsertMany(S.T_PRIVATE, privateRows);
  }
  if (graveRows.length > 0) {
    await S.upsertMany(S.T.GRAVE, graveRows);
  }
  if (book !== null) {
    await S.upsertOne(S.T.BOOK, S.buildBookRow({ familyId: familyId, bookKey: family.bookKey || 0, book: book, rev: 0, actor: userId }));
  }
  return { written: memberRows.length, nextCursor: cursor + memberRows.length, warnings: warnings };

});
