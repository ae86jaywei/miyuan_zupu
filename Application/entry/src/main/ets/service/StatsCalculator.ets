import { GenealogyStats, GenerationStat, Person, SpouseRelation, generationLabel } from 'common_base';
import { parseYear } from 'common_dateutil';

/**
 * 族谱统计的纯计算部分：不持有状态、不访问数据库，
 * 由 GenealogyService 传入当前谱的人物数组与可选过滤条件。
 */
export class StatsCalculator {
  /** 按世代分组 */
  static groupByGeneration(people: Person[], filterFn?: (p: Person) => boolean): Map<number, Person[]> {
    const map: Map<number, Person[]> = new Map<number, Person[]>();
    people.forEach((p: Person): void => {
      if (filterFn !== undefined && !filterFn(p)) {
        return;
      }
      const g: number = p.generation;
      const arr: Person[] | undefined = map.get(g);
      if (arr === undefined) {
        map.set(g, [p]);
      } else {
        arr.push(p);
      }
    });
    return map;
  }

  /** 全部字派（去重、排序） */
  static generationChars(people: Person[]): string[] {
    const set: Set<string> = new Set<string>();
    people.forEach((p: Person): void => {
      if (p.generationChar.trim().length > 0) {
        set.add(p.generationChar.trim());
      }
    });
    return Array.from(set).sort();
  }

  /** 全量或按条件统计 */
  static compute(people: Person[], filterFn?: (p: Person) => boolean): GenealogyStats {
    const stats: GenealogyStats = new GenealogyStats();
    const filtered: Person[] = filterFn === undefined ? people : people.filter(filterFn);
    const genMap: Map<number, GenerationStat> = new Map<number, GenerationStat>();
    let lifespanSum: number = 0;
    let lifespanCount: number = 0;
    let male: number = 0;
    let female: number = 0;
    let alive: number = 0;
    let deceased: number = 0;
    let lost: number = 0;
    let maxGen: number = 0;
    let minGen: number = 99;
    let birthdayKnown: number = 0;
    let graveWithGps: number = 0;
    let avatarCount: number = 0;
    const spouseSet: Set<string> = new Set<string>();

    filtered.forEach((p: Person): void => {
      if (p.gender === '女') {
        female = female + 1;
      } else {
        male = male + 1;
      }
      if (p.lifeStatus === '已故') {
        deceased = deceased + 1;
      } else if (p.lifeStatus === '失联') {
        lost = lost + 1;
      } else {
        alive = alive + 1;
      }
      if (p.generation > maxGen) {
        maxGen = p.generation;
      }
      if (p.generation > 0 && p.generation < minGen) {
        minGen = p.generation;
      }
      if (p.birthDate.trim().length > 0) {
        birthdayKnown = birthdayKnown + 1;
      }
      if (p.graveLat !== 0 || p.graveLng !== 0) {
        graveWithGps = graveWithGps + 1;
      }
      if (p.avatar.length > 0) {
        avatarCount = avatarCount + 1;
      }
      p.spouses.forEach((r: SpouseRelation): void => {
        if (r.uid.trim().length > 0) {
          spouseSet.add(r.uid.trim().toUpperCase());
        }
      });
      const by: number = parseYear(p.birthDate);
      const dy: number = parseYear(p.deathDate);
      if (by > 0 && dy > by) {
        lifespanSum = lifespanSum + (dy - by);
        lifespanCount = lifespanCount + 1;
      }
      const g: number = p.generation > 0 ? p.generation : 1;
      let gs: GenerationStat | undefined = genMap.get(g);
      if (gs === undefined) {
        gs = new GenerationStat();
        gs.generation = g;
        gs.label = generationLabel(g);
        genMap.set(g, gs);
      }
      gs.total = gs.total + 1;
      if (p.gender === '女') {
        gs.female = gs.female + 1;
      } else {
        gs.male = gs.male + 1;
      }
      if (p.lifeStatus === '已故') {
        gs.deceased = gs.deceased + 1;
      } else {
        gs.alive = gs.alive + 1;
      }
    });

    stats.total = filtered.length;
    stats.male = male;
    stats.female = female;
    stats.alive = alive;
    stats.deceased = deceased;
    stats.lost = lost;
    stats.maxGeneration = maxGen;
    stats.minGeneration = minGen === 99 ? 1 : minGen;
    stats.spouseCount = spouseSet.size;
    stats.birthdayKnown = birthdayKnown;
    stats.graveWithGps = graveWithGps;
    stats.avatarCount = avatarCount;
    stats.averageLifespan = lifespanCount === 0 ? 0 : Math.round(lifespanSum / lifespanCount);

    const gens: GenerationStat[] = [];
    Array.from(genMap.keys()).sort((a: number, b: number): number => a - b).forEach((g: number): void => {
      const gs: GenerationStat = genMap.get(g) as GenerationStat;
      gs.ratio = stats.total === 0 ? 0 : gs.total / stats.total;
      gens.push(gs);
    });
    stats.generations = gens;
    return stats;
  }
}
