/**
 * 族谱统计模型。
 */
export class GenerationStat {
  generation: number = 1;
  label: string = '';
  total: number = 0;
  male: number = 0;
  female: number = 0;
  alive: number = 0;
  deceased: number = 0;
  /** 该代人数占全部人数的比例（0~1） */
  ratio: number = 0;
}

export class GenealogyStats {
  total: number = 0;
  male: number = 0;
  female: number = 0;
  alive: number = 0;
  deceased: number = 0;
  lost: number = 0;
  /** 世数 */
  maxGeneration: number = 0;
  minGeneration: number = 1;
  /** 配偶数（有配偶字段关系的不同人物数） */
  spouseCount: number = 0;
  /** 已录入出生日期人数 */
  birthdayKnown: number = 0;
  /** 有墓葬GPS记录人数 */
  graveWithGps: number = 0;
  /** 有头像人数 */
  avatarCount: number = 0;
  /** 平均寿命（已故且生卒齐全者的平均年龄） */
  averageLifespan: number = 0;
  /** 各代统计 */
  generations: GenerationStat[] = [];
}
