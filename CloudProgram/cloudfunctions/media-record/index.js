'use strict';
/**
 * 觅源 · 家族协作云函数：media-record
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 */
const S = require('./shared');

/**
 * 规范化云存储相对路径。
 * [SEC-FIX] CWE-22：拒绝反斜杠、绝对路径与 `..` 段，消除路径穿越。
 * 返回空串表示路径非法。
 */
function safeCloudPath(p) {
  const raw = String(p === undefined || p === null ? '' : p).trim();
  if (raw.length === 0 || raw.indexOf('\\') >= 0 || raw.charAt(0) === '/') {
    return '';
  }
  const parts = raw.split('/');
  const out = [];
  for (let i = 0; i < parts.length; i++) {
    const seg = parts[i];
    if (seg === '' || seg === '.') {
      continue;
    }
    if (seg === '..') {
      return '';
    }
    out.push(seg);
  }
  return out.join('/');
}

module.exports.handler = S.createHandler('media-record', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  await S.requireMember(familyId, userId, S.ROLE.EDITOR, log);
  await S.getFamily(familyId);
  const media = params.media && typeof params.media === 'object' ? params.media : {};
  const cloudPath = safeCloudPath(S.str(media, 'cloudPath'));
  if (cloudPath.length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '缺少合法的 cloudPath');
  }
  // [SEC-FIX] CWE-22：规范化后仍必须以 {familyId}/ 开头，且 familyId 不得含分隔符，
  // 防止 familyId/../otherFamily/... 绕过前缀校验。
  if (familyId.indexOf('/') >= 0 || cloudPath.indexOf(familyId + '/') !== 0) {
    throw new S.BizError(S.CODE.FORBIDDEN, '云存储路径不属于该家族', 'bad_path');
  }
  const row = {
    // [SEC-FIX] CWE-639：媒体主键由服务端生成，忽略客户端 mediaId，避免覆盖他人记录。
    mediaId: S.uuid(),
    familyId: familyId,
    memberId: S.str(media, 'memberId'),
    uid: S.normUid(S.str(media, 'uid')),
    type: S.str(media, 'type', 'image'),
    cloudPath: cloudPath,
    fileName: S.str(media, 'fileName'),
    size: S.num(media, 'size', 0),
    uploadedAt: S.nowMs(),
    deleted: false,
    actor: userId
  };
  await S.upsertOne(S.T.MEDIA, row);
  return { ok: true, mediaId: row.mediaId };

});
