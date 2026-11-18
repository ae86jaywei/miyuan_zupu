import { relationalStore } from '@kit.ArkData';
import { Genealogy, createEmptyGenealogy } from 'common_base';

/**
 * genealogy_book 表行 → Genealogy。
 *
 * 旧库可能缺少后加的列，这里统一按“列不存在取默认值”的方式读取，
 * 避免每个读取点各自判断 getColumnIndex 是否小于 0。
 */
export class BookRowMapper {
  static fromRow(rs: relationalStore.ResultSet): Genealogy {
    const b: Genealogy = createEmptyGenealogy();
    b.key = rs.getLong(rs.getColumnIndex('id'));
    b.title = rs.getString(rs.getColumnIndex('title'));
    b.surname = rs.getString(rs.getColumnIndex('surname'));
    b.hallName = rs.getString(rs.getColumnIndex('hall_name'));
    b.junwang = rs.getString(rs.getColumnIndex('junwang'));
    b.ancestorName = rs.getString(rs.getColumnIndex('ancestor_name'));
    b.generationPoem = rs.getString(rs.getColumnIndex('generation_poem'));
    b.preface = rs.getString(rs.getColumnIndex('preface'));
    b.familyRules = rs.getString(rs.getColumnIndex('family_rules'));
    b.editingNotes = rs.getString(rs.getColumnIndex('editing_notes'));
    b.coverColor = rs.getString(rs.getColumnIndex('cover_color'));
    b.coverPattern = rs.getString(rs.getColumnIndex('cover_pattern'));
    b.parentBookId = rs.getLong(rs.getColumnIndex('parent_book_id'));
    b.branchRootUid = BookRowMapper.textOf(rs, 'branch_root_uid');
    b.parentBookTitle = BookRowMapper.textOf(rs, 'parent_book_title');
    b.parentGeneration = BookRowMapper.longOf(rs, 'parent_generation');
    b.parentUid = BookRowMapper.textOf(rs, 'parent_uid');
    b.parentName = BookRowMapper.textOf(rs, 'parent_name');
    b.familyId = BookRowMapper.textOf(rs, 'family_id');
    b.syncMode = BookRowMapper.textOf(rs, 'sync_mode');
    b.familyRole = BookRowMapper.textOf(rs, 'family_role');
    b.cloudRev = BookRowMapper.longOf(rs, 'cloud_rev');
    b.createdAt = rs.getLong(rs.getColumnIndex('created_at'));
    b.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
    return b;
  }

  /** 读取可能不存在的文本列 */
  private static textOf(rs: relationalStore.ResultSet, column: string): string {
    const idx: number = rs.getColumnIndex(column);
    if (idx < 0) {
      return '';
    }
    const v: string = rs.getString(idx);
    return v === null || v === undefined ? '' : v;
  }

  /** 读取可能不存在的数字列 */
  private static longOf(rs: relationalStore.ResultSet, column: string): number {
    const idx: number = rs.getColumnIndex(column);
    if (idx < 0) {
      return 0;
    }
    return rs.getLong(idx);
  }
}
