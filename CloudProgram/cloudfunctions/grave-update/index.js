'use strict';
/**
 * 觅源 · 家族协作云函数：grave-update
 */
const S = require('./shared');

/**
 * 取字段值：入参显式提供则用入参；否则沿用已有记录；最后退回默认值。
 * 与原先散落的 `x === undefined ? (existing ? existing.x : def) : x` 完全等价。
 */
function pick(obj, existing, key, def) {
  if (obj[key] !== undefined) {
    return obj[key];
  }
  return existing ? existing[key] : def;
}

/**
 * 取文本字段：入参优先；否则沿用已有记录（空值回退空串）。
 * 等价于 `x === undefined ? ((existing && existing.x) || '') : x`。
 */
function pickText(obj, existing, key) {
  if (obj[key] !== undefined) {
    return obj[key];
  }
  return (existing && existing[key]) || '';
}

module.exports.handler = S.createHandler('grave-update', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  await S.requireMember(familyId, userId, S.ROLE.EDITOR, log);
  const family = await S.getFamily(familyId);
  const uid = S.normUid(S.str(params, 'uid'));
  if (uid.length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '缺少 uid');
  }
  const memberRow = await S.queryOne(S.T.MEMBER, [['memberId', '=', S.memberIdOf(familyId, uid)]]);
  if (memberRow === null) {
    throw new S.BizError(S.CODE.NOT_FOUND, '族人不存在：' + uid);
  }
  const person = S.personOf(memberRow);
  const grave = (params.grave && typeof params.grave === 'object') ? params.grave : {};
  const existing = await S.queryOne(S.T.GRAVE, [['graveId', '=', S.graveRef(familyId, uid)]]);
  const lng = Number(pick(grave, existing, 'lng', 0));
  const lat = Number(pick(grave, existing, 'lat', 0));
  const visibility = S.str(params, 'visibility', (existing && existing.visibility) || 'PUBLIC');
  const precision = S.str(params, 'precision', (existing && existing.precision) || 'EXACT');
  // §九 墓葬坐标：不做 LWW，做「就近优先 + 复议」。相距 > 50m 视为位置变更，必须附证据
  if (existing !== null && lng !== 0 && lat !== 0 && Number(existing.lng) !== 0 && Number(existing.lat) !== 0) {
    const d = S.distanceMeters(Number(existing.lng), Number(existing.lat), lng, lat);
    if (d > 50 && S.str(params, 'evidence').length === 0) {
      throw new S.BizError(S.CODE.CONFLICT,
        '新坐标与已记录位置相差 ' + Math.round(d) + ' 米（超过 50m），请附实地照片或说明后再提交', 'grave_far');
    }
  }
  const allocated = await S.allocate(family, 2, log);
  const newRev = allocated.rev;
  if (visibility === 'FAMILY_ONLY') {
    // 真移出：物理删除公开表中的该行（不是写 visibility 让端侧过滤）
    if (existing !== null) {
      await S.deleteByType(S.T.GRAVE, [existing]);
    }
  } else {
    const row = S.buildGraveRow({
      familyId: familyId,
      uid: uid,
      person: {
        name: person.name,
        generation: person.generation,
        graveInfo: grave.graveName || person.graveInfo,
        graveLng: lng,
        graveLat: lat,
        graveAltitude: pick(grave, existing, 'altitude', 0)
      },
      bookTitle: family.title,
      personName: person.name,
      generation: person.generation,
      graveName: pickText(grave, existing, 'graveName'),
      facing: pickText(grave, existing, 'facing'),
      bearing: pickText(grave, existing, 'bearing'),
      routeNote: pickText(grave, existing, 'routeNote'),
      photoRefs: pickText(grave, existing, 'photoRefs'),
      rev: newRev,
      actor: userId,
      visibility: visibility,
      precision: precision
    });
    await S.upsertOne(S.T.GRAVE, row);
  }
  const memberNew = Object.assign({}, memberRow);
  memberNew.graveRef = visibility === 'FAMILY_ONLY' ? '' : S.graveRef(familyId, uid);
  memberNew.rev = newRev;
  memberNew.actor = userId;
  memberNew.baseRev = newRev;
  memberNew.updatedAt = S.nowMs();
  await S.upsertOne(S.T.MEMBER, memberNew);
  await S.upsertOne(S.T.CHANGE_LOG, S.changeLogRow({
    familyId: familyId, rev: newRev, actor: userId, action: 'GRAVE_UPDATE',
    targetMemberId: memberNew.memberId,
    summary: (visibility === 'FAMILY_ONLY' ? '墓葬信息改为仅族人可见：' : '更新墓葬信息：') + person.name,
    payload: { visibility: visibility, lng: lng, lat: lat, evidence: S.str(params, 'evidence') }
  }));
  return { ok: true, rev: newRev, visibility: visibility, precision: precision };

});
