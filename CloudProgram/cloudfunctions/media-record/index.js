'use strict';
/**
 * 觅源 · 家族协作云函数：media-record
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 */
const S = require('_zupu_shared');

module.exports.handler = S.createHandler('media-record', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  await S.requireMember(familyId, userId, S.ROLE.EDITOR, log);
  const family = await S.getFamily(familyId);
  const media = params.media && typeof params.media === 'object' ? params.media : {};
  const cloudPath = S.str(media, 'cloudPath');
  if (cloudPath.length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '缺少 cloudPath');
  }
  // 云存储路径必须是 {familyId}/{memberIdKey}/{fileName}，防止他人把别人的文件挂到自己谱下
  if (cloudPath.indexOf(familyId + '/') !== 0) {
    throw new S.BizError(S.CODE.FORBIDDEN, '云存储路径不属于该家族', 'bad_path');
  }
  const row = {
    mediaId: S.str(media, 'mediaId') || S.uuid(),
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
