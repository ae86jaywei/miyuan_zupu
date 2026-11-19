import { describe, it, expect } from '@ohos/hypium';
import {
  CloudFamilyMember, CloudMemberPayload, FieldChange, Person, SpouseRelation, buildPersonPatch,
  cloudMemberKey, cloudMemberToPerson, createEmptyPerson, displayValue, memberUid,
  parseBookKeyFromMemberId, parsePatchJson, personToCloudMember, personToCloudTombstone,
  readCloudMember
} from 'common_base';
import { CloudMedia, MediaJob } from '../main/ets/service/cloud/CloudMedia';

function person(uid: string, name: string): Person {
  const p: Person = createEmptyPerson();
  p.uid = uid;
  p.name = name;
  return p;
}

function spouse(uid: string, relation: string, order: number): SpouseRelation {
  const r: SpouseRelation = new SpouseRelation();
  r.uid = uid;
  r.relation = relation;
  r.order = order;
  return r;
}

export default function cloudSyncTest() {
  describe('PersonPatch', () => {
    it('deleteReturnsEmptyPatch', 0, () => {
      const p: Person = person('A1', '张三');
      expect(buildPersonPatch(null, p, 'DELETE')).assertEqual('{}');
      expect(buildPersonPatch(p, p, 'DELETE_REQ')).assertEqual('{}');
    });

    it('addOnlyCarriesNonEmptyFields', 0, () => {
      const p: Person = person('A1', '张三');
      p.generation = 2;
      p.childless = true;
      const patch: Map<string, FieldChange> = parsePatchJson(buildPersonPatch(null, p, 'ADD'));

      expect(patch.get('uid')?.a as string).assertEqual('A1');
      expect(patch.get('name')?.a as string).assertEqual('张三');
      expect(patch.get('generation')?.a as number).assertEqual(2);
      expect(patch.get('childless')?.a as boolean).assertTrue();
      // ADD 时 b 一律为空（云端没有旧值）
      expect(patch.get('name')?.b === null).assertTrue();
      // 空字段不进 patch
      expect(patch.get('courtesyName') === undefined).assertTrue();
      expect(patch.get('birthDate') === undefined).assertTrue();
    });

    it('updateCarriesOnlyChangedFields', 0, () => {
      const before: Person = person('A1', '张三');
      const after: Person = person('A1', '张三丰');
      after.birthDate = '1950-01';
      const patch: Map<string, FieldChange> = parsePatchJson(buildPersonPatch(before, after, 'UPDATE'));

      expect(patch.size).assertEqual(2);
      expect(patch.get('name')?.b as string).assertEqual('张三');
      expect(patch.get('name')?.a as string).assertEqual('张三丰');
      expect(patch.get('birthDate')?.b as string).assertEqual('');
      expect(patch.get('birthDate')?.a as string).assertEqual('1950-01');
    });

    it('spousesChangeIsWholeArrayReplace', 0, () => {
      const before: Person = person('A1', '张三');
      const after: Person = person('A1', '张三');
      after.spouses = [spouse('W1', '元配', 1)];
      const patch: Map<string, FieldChange> = parsePatchJson(buildPersonPatch(before, after, 'UPDATE'));

      expect(patch.size).assertEqual(1);
      expect('配偶 ' + displayValue(patch.get('spouses')?.a as Object)).assertEqual('配偶 W1（元配）');
      expect(displayValue(patch.get('spouses')?.b as Object)).assertEqual('（空）');
    });

    it('parsePatchJsonToleratesBadInput', 0, () => {
      expect(parsePatchJson('').size).assertEqual(0);
      expect(parsePatchJson('not-json').size).assertEqual(0);
    });
  });

  describe('CloudMember', () => {
    it('memberKeyRoundTrip', 0, () => {
      expect(cloudMemberKey(0, 'F001')).assertEqual('F001');
      expect(cloudMemberKey(3, 'F001')).assertEqual('b3#F001');
      expect(parseBookKeyFromMemberId('b12#F001')).assertEqual(12);
      expect(parseBookKeyFromMemberId('F001')).assertEqual(0);
      expect(parseBookKeyFromMemberId('b#F001')).assertEqual(0);
      expect(parseBookKeyFromMemberId('b0#F001')).assertEqual(0);
      expect(memberUid('b12#F001')).assertEqual('F001');
      expect(memberUid('F001')).assertEqual('F001');
    });

    it('personToCloudMemberStripsPrivateAndGraveFields', 0, () => {
      const p: Person = person('F001', '李德昌');
      p.generation = 1;
      p.fatherId = 'F000';
      p.courtesyName = '昭远';
      p.phone = '13800000000';
      p.wechat = 'wx_dechang';
      p.residence = '深圳';
      p.graveLng = 114.1;
      p.graveLat = 22.5;
      p.graveAltitude = 30;
      p.updatedAt = 1000;

      const doc: CloudFamilyMember = personToCloudMember(p, 'user1', 2, '李氏宗谱');
      expect(doc.memberId).assertEqual('b2#F001');
      expect(doc.userId).assertEqual('user1');
      expect(doc.name).assertEqual('李德昌');
      expect(doc.generation).assertEqual(1);
      expect(doc.parentId).assertEqual('F000');
      expect(doc.updatedAt).assertEqual(1000);
      expect(doc.deleted === false).assertTrue();

      const read: CloudMemberPayload = readCloudMember(doc);
      expect(read.bookKey).assertEqual(2);
      expect(read.bookTitle).assertEqual('李氏宗谱');
      const sent: Person | null = read.person !== undefined ? read.person : null;
      expect(sent !== null).assertTrue();
      expect(sent?.phone).assertEqual('');
      expect(sent?.wechat).assertEqual('');
      expect(sent?.residence).assertEqual('');
      expect(sent?.graveLng).assertEqual(0);
      expect(sent?.graveLat).assertEqual(0);
      // 非隐私字段原样保留，且本地对象不被脱敏改写
      expect(sent?.courtesyName).assertEqual('昭远');
      expect(p.phone).assertEqual('13800000000');
      expect(p.residence).assertEqual('深圳');
    });

    it('readCloudMemberSupportsLegacyPayload', 0, () => {
      const p: Person = person('F002', '李泽清');
      const doc: CloudFamilyMember = new CloudFamilyMember();
      doc.memberId = 'F002';
      doc.payload = JSON.stringify(p);

      const read: CloudMemberPayload = readCloudMember(doc);
      expect(read.bookKey).assertEqual(0);
      expect(read.person?.name).assertEqual('李泽清');
      expect(read.person?.uid).assertEqual('F002');
    });

    it('tombstoneCarriesNoPerson', 0, () => {
      const p: Person = person('F001', '李德昌');
      p.fatherId = 'F000';
      const doc: CloudFamilyMember = personToCloudTombstone(p, 'user1', 2, '李氏宗谱');

      expect(doc.deleted === true).assertTrue();
      expect(doc.parentId).assertEqual('');
      // 墓碑只保留归属族谱，不携带人物数据；族谱编号仍可从 memberId 前缀解析
      const read: CloudMemberPayload = readCloudMember(doc);
      expect(read.bookKey).assertEqual(2);
      const payload: string = doc.payload !== undefined ? doc.payload : '';
      expect(payload.indexOf('"person":null') > 0).assertTrue();
    });

    it('cloudMemberToPersonFillsDefaults', 0, () => {
      // 只有云端精简字段、没有 payload 的旧记录
      const doc: CloudFamilyMember = new CloudFamilyMember();
      doc.memberId = 'b9#M001';
      doc.name = '林氏';
      const p: Person = cloudMemberToPerson(doc);

      expect(p.uid).assertEqual('M001');
      expect(p.name).assertEqual('林氏');
      expect(p.generation).assertEqual(1);
      expect(p.gender).assertEqual('男');
      expect(p.lifeStatus).assertEqual('在世');
      expect(p.spouses.length).assertEqual(0);
    });

    it('cloudMemberToPersonRestoresSpouses', 0, () => {
      const src: Person = person('F001', '李德昌');
      src.spouses = [spouse('M001', '元配', 1)];
      src.spouseId = 'M001';
      const doc: CloudFamilyMember = personToCloudMember(src, 'user1', 1, '李氏宗谱');
      const p: Person = cloudMemberToPerson(doc);

      expect(p.uid).assertEqual('F001');
      expect(p.name).assertEqual('李德昌');
      expect(p.spouses.length).assertEqual(1);
      expect(p.spouses[0].uid).assertEqual('M001');
      expect(p.spouses[0].relation).assertEqual('元配');
    });
  });

  describe('CloudMedia', () => {
    it('splitUrisSkipsEmptyParts', 0, () => {
      expect(CloudMedia.splitUris('').length).assertEqual(0);
      expect(CloudMedia.splitUris('a;b;;c;').length).assertEqual(3);
      expect(CloudMedia.splitUris('a;b;;c;')[2]).assertEqual('c');
    });

    it('fileNameAndExtensionIgnoreQuery', 0, () => {
      const uri: string = 'file://media/Photo/1/IMG_2026.jpg?width=100';
      expect(CloudMedia.fileNameOf(uri)).assertEqual('IMG_2026.jpg');
      expect(CloudMedia.extensionOf(uri)).assertEqual('jpg');
      expect(CloudMedia.extensionOf('file://media/Photo/1/NOEXT')).assertEqual('');
      expect(CloudMedia.isVideoUri('file://media/Video/1/a.MP4?x=1')).assertTrue();
      expect(CloudMedia.isVideoUri('file://media/Photo/1/a.jpg')).assertFalse();
    });

    it('collectSkipsCloudUrisAndDuplicates', 0, () => {
      const p1: Person = person('F001', '李德昌');
      p1.avatar = 'file://media/Photo/1/avatar.png';
      p1.photos = 'file://media/Photo/1/p1.jpg;cloud://uploaded.jpg;file://media/Video/1/p2.mov;file://media/Photo/1/p1.jpg';
      p1.videos = 'file://media/Video/1/v1.mp4';
      const p2: Person = person('F002', '李泽清');
      // 同一 URI 挂在不同人物下：不同 memberId，不能去重
      p2.avatar = 'file://media/Photo/1/avatar.png';

      const jobs: MediaJob[] = CloudMedia.collect([p1, p2], 1);
      // p1：头像 + 2 张照片 + 1 段视频；p2：头像
      expect(jobs.length).assertEqual(5);
      expect(jobs[0].kind).assertEqual('avatar');
      expect(jobs[0].memberId).assertEqual('b1#F001');
      expect(jobs[0].isVideo === false).assertTrue();
      expect(jobs[1].kind).assertEqual('photo');
      expect(jobs[1].isVideo === false).assertTrue();
      // 视频本体在 photos 字段里时按扩展名识别
      expect(jobs[2].uri).assertEqual('file://media/Video/1/p2.mov');
      expect(jobs[2].isVideo === true).assertTrue();
      expect(jobs[3].kind).assertEqual('video');
      expect(jobs[3].isVideo === true).assertTrue();
      expect(jobs[4].memberId).assertEqual('b1#F002');
    });
  });
}
