import { cloudDatabase } from '@kit.CloudFoundationKit';

/**
 * 协作 Zone（miyuanfamily）的云数据库对象类型。
 *
 * ⚠️ 字段必须与 AppScope/resources/rawfile/schema.json **逐字一致**，
 * 而 schema.json 只能由 DevEco/AGC 控制台「导出」覆盖，**禁止手写**（否则报 1008230002）。
 * 完整建表清单与步骤见《AGC手动操作步骤方案.md》。
 *
 * 端侧权限（方案 §五.9）：
 *  - FamilyGraveLocation / FamilyDirectory：Authenticated 可 Read（唯二例外）；
 *  - 其余全部 []：端侧**不直接读写**，一律经由云函数（FamilyService / FamilySyncService）。
 */

/** 家族主记录（端侧不直接读，仅作为云函数返回值的承载结构） */
export class CloudFamily extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'Family';
  }

  public familyId: string | undefined;
  public ownerUserId: string | undefined;
  public ownerUnionId: string | undefined;
  public title: string | undefined;
  public bookKey: number | undefined;
  public rev: number | undefined;
  public aclVersion: number | undefined;
  public inviteCode: string | undefined;
  public inviteExpireAt: number | undefined;
  public inviteRole: string | undefined;
  public directoryEnabled: boolean | undefined;
  public directoryUpdatedAt: number | undefined;
  public createdAt: number | undefined;
  public updatedAt: number | undefined;
}

/** 权限唯一真相源（三条门槛最终都只写这张表） */
export class CloudMembership extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'Membership';
  }

  public membershipId: string | undefined;
  public familyId: string | undefined;
  public userId: string | undefined;
  public role: string | undefined;
  public status: string | undefined;
  public branchRootUid: string | undefined;
  public expireAt: number | undefined;
  public nickName: string | undefined;
  public source: string | undefined;
  public joinedAt: number | undefined;
  public revokedAt: number | undefined;
  public updatedAt: number | undefined;
}

/** 协作成员记录（协作 Zone 新表，memberId = {familyId}#{uid}） */
export class CloudCollaborativeMember extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'FamilyMember';
  }

  public memberId: string | undefined;
  public familyId: string | undefined;
  public bookKey: number | undefined;
  public uid: string | undefined;
  public name: string | undefined;
  public generation: number | undefined;
  public parentId: string | undefined;
  /** 只含公开字段的 Person JSON（不含 phone/wechat/residence，也不含墓葬坐标） */
  public payload: string | undefined;
  public privateRef: string | undefined;
  public graveRef: string | undefined;
  public rev: number | undefined;
  public actor: string | undefined;
  public deleted: boolean | undefined;
  public deletedAt: number | undefined;
  public deletedBy: string | undefined;
  public baseRev: number | undefined;
  public updatedAt: number | undefined;
}

/** 谱元信息（替代 books.json 整文件覆盖） */
export class CloudFamilyBook extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'FamilyBook';
  }

  public bookId: string | undefined;
  public familyId: string | undefined;
  public bookKey: number | undefined;
  public title: string | undefined;
  public payload: string | undefined;
  public rev: number | undefined;
  public actor: string | undefined;
  public baseRev: number | undefined;
  public deleted: boolean | undefined;
  public updatedAt: number | undefined;
}

/** 待审变更 */
export class CloudChangeRequest extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'ChangeRequest';
  }

  public requestId: string | undefined;
  public familyId: string | undefined;
  public bookKey: number | undefined;
  public submitterId: string | undefined;
  public submitterName: string | undefined;
  public targetUid: string | undefined;
  public op: string | undefined;
  public patchJson: string | undefined;
  public baseRev: number | undefined;
  public evidence: string | undefined;
  public status: string | undefined;
  public reviewerId: string | undefined;
  public reviewNote: string | undefined;
  public reviewedAt: number | undefined;
  public resultRev: number | undefined;
  public createdAt: number | undefined;
}

/** 审计流水（只追加） */
export class CloudChangeLog extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'ChangeLog';
  }

  public logId: string | undefined;
  public familyId: string | undefined;
  public rev: number | undefined;
  public actor: string | undefined;
  public action: string | undefined;
  public targetMemberId: string | undefined;
  public summary: string | undefined;
  public payload: string | undefined;
  public createdAt: number | undefined;
}

/** 协作媒体索引（路径 {familyId}/{memberIdKey}/{fileName}） */
export class CloudCollaborativeMedia extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'FamilyMedia';
  }

  public mediaId: string | undefined;
  public familyId: string | undefined;
  public memberId: string | undefined;
  public uid: string | undefined;
  public type: string | undefined;
  public cloudPath: string | undefined;
  public fileName: string | undefined;
  public size: number | undefined;
  public uploadedAt: number | undefined;
  public deleted: boolean | undefined;
  public actor: string | undefined;
}

/**
 * 墓葬位置（**公开可读对象类型之一**，方案 §五.8）。
 * 该表只允许放墓穴位置类字段，严禁加入任何活人信息（§五.9 边界纪律）。
 */
export class CloudGraveLocation extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'FamilyGraveLocation';
  }

  public graveId: string | undefined;
  public familyId: string | undefined;
  public uid: string | undefined;
  public personName: string | undefined;
  public generation: number | undefined;
  public bookTitle: string | undefined;
  public graveName: string | undefined;
  public lng: number | undefined;
  public lat: number | undefined;
  public altitude: number | undefined;
  public facing: string | undefined;
  public bearing: string | undefined;
  public routeNote: string | undefined;
  public photoRefs: string | undefined;
  public visibility: string | undefined;
  public precision: string | undefined;
  public rev: number | undefined;
  public actor: string | undefined;
  public updatedAt: number | undefined;
}

/** 访问申请（门槛①③） */
export class CloudAccessRequest extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'AccessRequest';
  }

  public requestId: string | undefined;
  public familyId: string | undefined;
  public applicantId: string | undefined;
  public applicantName: string | undefined;
  public kind: string | undefined;
  public relationClaim: string | undefined;
  public branchClaimUid: string | undefined;
  public evidence: string | undefined;
  public grantedRole: string | undefined;
  public expireAt: number | undefined;
  public status: string | undefined;
  public reviewerId: string | undefined;
  public reviewNote: string | undefined;
  public reviewedAt: number | undefined;
  public createdAt: number | undefined;
  public rev: number | undefined;
}

/**
 * 族谱黄页索引（**公开可读对象类型之二**，方案 §五.11）。
 * 只允许放谱名/姓氏/地域等索引元数据，严禁任何人物数据；
 * 未上架的谱**根本不在本表**（关闭即物理删除该行）。
 */
export class CloudFamilyDirectory extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'FamilyDirectory';
  }

  public dirId: string | undefined;
  public familyId: string | undefined;
  public surname: string | undefined;
  public region: string | undefined;
  public title: string | undefined;
  public branchSummary: string | undefined;
  public memberCountBand: string | undefined;
  public coverRef: string | undefined;
  public accessHint: string | undefined;
  public createdAt: number | undefined;
  public updatedAt: number | undefined;
  public rev: number | undefined;
  public actor: string | undefined;
}

/** 长文分段（P3 预留） */
export class CloudTextSegment extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'FamilyTextSegment';
  }

  public segmentId: string | undefined;
  public familyId: string | undefined;
  public memberId: string | undefined;
  public field: string | undefined;
  public segOrder: number | undefined;
  public text: string | undefined;
  public actor: string | undefined;
  public rev: number | undefined;
  public createdAt: number | undefined;
}

/** 推送设备（P3 预留） */
export class CloudUserDevice extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'UserDevice';
  }

  public deviceId: string | undefined;
  public userId: string | undefined;
  public pushToken: string | undefined;
  public platform: string | undefined;
  public updatedAt: number | undefined;
}

/** 活人隐私字段包（端侧永不可直读，仅 OWNER 经云函数可取） */
export class CloudFamilyPrivate extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'FamilyPrivate';
  }

  public privateId: string | undefined;
  public familyId: string | undefined;
  public uid: string | undefined;
  public phone: string | undefined;
  public wechat: string | undefined;
  public residence: string | undefined;
  public actor: string | undefined;
  public updatedAt: number | undefined;
}
