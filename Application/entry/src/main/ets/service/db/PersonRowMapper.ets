import { relationalStore } from '@kit.ArkData';
import { Genealogy, Person } from 'common_base';

/** 人物/族谱 与 SQLite 行的映射，纯函数，不持有业务状态 */
export class PersonRowMapper {
  /** Person → 人物表 ValuesBucket；bookId <= 0 时使用调用方传入的当前族谱ID */
  static toValues(p: Person, bookId: number): relationalStore.ValuesBucket {
    const v: relationalStore.ValuesBucket = {
      'book_id': bookId,
      'uid': p.uid,
      'generation': p.generation,
      'name': p.name,
      'courtesy_name': p.courtesyName,
      'art_name': p.artName,
      'alias': p.alias,
      'gender': p.gender,
      'generation_char': p.generationChar,
      'life_status': p.lifeStatus,
      'child_status': p.childStatus,
      'child_mark': p.childMark,
      'child_mark_target': p.childMarkTarget,
      'child_mark_source': p.childMarkSource,
      'child_mark_seq': p.childMarkSeq,
      'childless': p.childless ? 1 : 0,
      'birth_date': p.birthDate,
      'birth_calendar': p.birthCalendar,
      'death_date': p.deathDate,
      'death_calendar': p.deathCalendar,
      'birth_place': p.birthPlace,
      'residence': p.residence,
      'father_id': p.fatherId,
      'father_name': p.fatherName,
      'father_life_status': p.fatherLifeStatus,
      'mother_id': p.motherId,
      'mother_name': p.motherName,
      'mother_life_status': p.motherLifeStatus,
      'spouse_id': p.spouseId,
      'marriage_status': p.marriageStatus,
      'spouse_family': p.spouseFamily,
      'rank': p.rank,
      'adoption': p.adoption,
      'education': p.education,
      'occupation': p.occupation,
      'biography': p.biography,
      'grave_info': p.graveInfo,
      'grave_lng': p.graveLng,
      'grave_lat': p.graveLat,
      'grave_altitude': p.graveAltitude,
      'phone': p.phone,
      'wechat': p.wechat,
      'avatar': p.avatar,
      'videos': p.videos,
      'photos': p.photos,
      'created_at': p.createdAt,
      'updated_at': p.updatedAt,
      'rev': p.rev,
      'base_rev': p.baseRev,
      'dirty': p.dirty ? 1 : 0,
      'deleted_at': p.deletedAt
    };
    return v;
  }

  /** Genealogy → 族谱表 ValuesBucket */
  static bookValues(b: Genealogy): relationalStore.ValuesBucket {
    const v: relationalStore.ValuesBucket = {
      'title': b.title,
      'surname': b.surname,
      'hall_name': b.hallName,
      'junwang': b.junwang,
      'ancestor_name': b.ancestorName,
      'generation_poem': b.generationPoem,
      'preface': b.preface,
      'family_rules': b.familyRules,
      'editing_notes': b.editingNotes,
      'cover_color': b.coverColor,
      'cover_pattern': b.coverPattern,
      'parent_book_id': b.parentBookId,
      'branch_root_uid': b.branchRootUid,
      'parent_book_title': b.parentBookTitle,
      'parent_generation': b.parentGeneration,
      'parent_uid': b.parentUid,
      'parent_name': b.parentName,
      'family_id': b.familyId,
      'sync_mode': b.syncMode,
      'cloud_rev': b.cloudRev,
      'family_role': b.familyRole,
      'created_at': b.createdAt,
      'updated_at': b.updatedAt
    };
    return v;
  }
}
