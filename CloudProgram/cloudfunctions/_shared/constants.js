'use strict';

/** 协作 Zone 默认名（AGC 控制台创建存储区时保持一致，可用环境变量覆盖） */
const DEFAULT_ZONE = 'miyuanfamily';

/** 对象类型名（与 AppScope/resources/rawfile/schema.json 一致，禁止改名） */
const T = {
  FAMILY: 'Family',
  MEMBERSHIP: 'Membership',
  MEMBER: 'FamilyMember',
  BOOK: 'FamilyBook',
  CHANGE_REQUEST: 'ChangeRequest',
  CHANGE_LOG: 'ChangeLog',
  MEDIA: 'FamilyMedia',
  GRAVE: 'FamilyGraveLocation',
  ACCESS_REQUEST: 'AccessRequest',
  DIRECTORY: 'FamilyDirectory',
  TEXT_SEGMENT: 'FamilyTextSegment',
  USER_DEVICE: 'UserDevice'
};

/** 角色 */
const ROLE = { OWNER: 'OWNER', EDITOR: 'EDITOR', VIEWER: 'VIEWER' };

/** Membership 状态 */
const MEMBERSHIP_STATUS = { INVITED: 'INVITED', ACTIVE: 'ACTIVE', REVOKED: 'REVOKED', EXPIRED: 'EXPIRED' };

/** 变更单状态 */
const CHANGE_STATUS = { PENDING: 'PENDING', APPROVED: 'APPROVED', REJECTED: 'REJECTED', SUPERSEDED: 'SUPERSEDED' };

/** 访问申请类型与状态 */
const ACCESS_KIND = { VIEW_APPLY: 'VIEW_APPLY', JOIN_CLAIM: 'JOIN_CLAIM' };
const ACCESS_STATUS = { PENDING: 'PENDING', APPROVED: 'APPROVED', REJECTED: 'REJECTED', EXPIRED: 'EXPIRED', CANCELLED: 'CANCELLED' };

/** 变更操作类型 */
const OP = { ADD: 'ADD', UPDATE: 'UPDATE', DELETE_REQ: 'DELETE_REQ', APPEND_TEXT: 'APPEND_TEXT' };

/**
 * Person 中「活人隐私字段」—— 绝不允许出现在 FamilyMember.payload（§八.2）。
 * 注意：graveLng/graveLat/graveAltitude/graveInfo 不在此列，它们迁往 FamilyGraveLocation（§五.8）。
 */
const PRIVATE_FIELDS = ['phone', 'wechat', 'residence'];

/** 墓葬坐标字段（迁出 payload） */
const GRAVE_COORD_FIELDS = ['graveLng', 'graveLat', 'graveAltitude'];

/** 长文本字段（APPEND_TEXT 使用分段模型，整块写入时拦截，§九） */
const LONG_TEXT_FIELDS = ['biography', 'preface', 'familyRules', 'editingNotes'];

/** 黄页字段白名单（§五.11 红线：只允许索引元数据，严禁任何人物数据） */
const DIRECTORY_FIELDS = ['surname', 'region', 'title', 'branchSummary', 'memberCountBand', 'coverRef', 'accessHint'];

/** 黄页「近似人物数据」黑名单：出现即拒绝（技术兜底，防止例外二被慢慢撑大） */
const DIRECTORY_FORBIDDEN_KEYS = ['person', 'personName', 'members', 'people', 'genealogy', 'payload',
  'birthDate', 'deathDate', 'fatherId', 'motherId', 'phone', 'wechat', 'residence', 'graveInfo', 'graveLng',
  'graveLat', 'uid', 'generation'];

/** 人数区间枚举（不允许写精确人数） */
const MEMBER_COUNT_BANDS = ['0-50', '50-100', '100-500', '500-1000', '1000+'];

/** 单次请求 payload 上限（2MB 对象限制之内的安全值） */
const MAX_PAYLOAD_BYTES = 900 * 1024;
/** 单次批量写入上限 */
const MAX_BATCH = 100;

/** 门槛①「申请认证」默认期限：180 天（§13.7 W11 已决） */
const VIEW_APPLY_DEFAULT_DAYS = 180;

module.exports = {
  DEFAULT_ZONE,
  T,
  ROLE,
  MEMBERSHIP_STATUS,
  CHANGE_STATUS,
  ACCESS_KIND,
  ACCESS_STATUS,
  OP,
  PRIVATE_FIELDS,
  GRAVE_COORD_FIELDS,
  LONG_TEXT_FIELDS,
  DIRECTORY_FIELDS,
  DIRECTORY_FORBIDDEN_KEYS,
  MEMBER_COUNT_BANDS,
  MAX_PAYLOAD_BYTES,
  MAX_BATCH,
  VIEW_APPLY_DEFAULT_DAYS
};
