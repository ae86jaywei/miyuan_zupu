'use strict';
/**
 * 觅源 · 家族协作云函数：user-device
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 */
const S = require('_zupu_shared');

module.exports.handler = S.createHandler('user-device', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const action = S.str(params, 'action', 'REGISTER').toUpperCase();
  const now = S.nowMs();
  if (action === 'DELETE') {
    const row = await S.queryOne(S.T.USER_DEVICE, [['userId', '=', userId]]);
    if (row !== null) {
      await S.deleteByType(S.T.USER_DEVICE, [row]);
    }
    return { ok: true };
  }
  const row = {
    deviceId: userId,
    userId: userId,
    pushToken: S.str(params, 'pushToken'),
    platform: S.str(params, 'platform', 'HarmonyOS'),
    updatedAt: now
  };
  await S.upsertOne(S.T.USER_DEVICE, row);
  return { ok: true };

});
