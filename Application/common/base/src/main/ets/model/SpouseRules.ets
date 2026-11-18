import { Person, SpouseRelation, normalizeSpouseRelation, spouseRelationLevel } from './Person';

/**
 * 归一化配偶关系：去空值 / 去重 / 去本人，补齐名分与次序，
 * 并把 spouseId 同步为主配偶（spouses[0]）。
 *
 * 属于模型层的保存前规则：编辑页、导入、云端恢复都走同一套归一化，
 * 避免各处各写一份导致历史数据格式不一致。
 */
export function normalizeSpouseRelations(p: Person): void {
  const list: SpouseRelation[] = [];
  const seen: Set<string> = new Set<string>();
  const self: string = p.uid.trim().toUpperCase();
  p.spouses.forEach((r: SpouseRelation): void => {
    const id: string = r.uid.trim().toUpperCase();
    if (id.length === 0 || id === self || seen.has(id)) {
      return;
    }
    seen.add(id);
    const nr: SpouseRelation = new SpouseRelation();
    nr.uid = id;
    const rawRel: string = r.relation.trim();
    // 历史数据可能把等级写进称谓（如“夫（侧室）”），保存时统一回“夫”
    nr.relation = rawRel.length > 0 ? normalizeSpouseRelation(rawRel) :
      (p.gender === '女' ? '夫' : '未记');
    nr.level = spouseRelationLevel(nr.relation);
    nr.order = list.length + 1;
    list.push(nr);
  });
  const legacy: string = p.spouseId.trim().toUpperCase();
  if (list.length === 0 && legacy.length > 0 && legacy !== self) {
    const nr: SpouseRelation = new SpouseRelation();
    nr.uid = legacy;
    nr.relation = p.gender === '女' ? '夫' : '元配';
    nr.level = spouseRelationLevel(nr.relation);
    nr.order = 1;
    list.push(nr);
  }
  p.spouses = list;
  p.spouseId = list.length > 0 ? list[0].uid : '';
}
