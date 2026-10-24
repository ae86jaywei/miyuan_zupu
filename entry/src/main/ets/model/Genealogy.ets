/**
 * 族谱主体模型（一部族谱的元信息）。
 */
export class Genealogy {
  /** 族谱ID */
  key: number = 0;
  /** 谱名，如：李氏宗谱 */
  title: string = '我的族谱';
  /** 姓氏 */
  surname: string = '';
  /** 堂号，如：陇西堂 */
  hallName: string = '';
  /** 郡望，如：陇西郡 */
  junwang: string = '';
  /** 始迁祖 / 始祖名讳 */
  ancestorName: string = '';
  /** 字派谱（字辈诗），如：德泽承先志 */
  generationPoem: string = '';
  /** 谱序 */
  preface: string = '';
  /** 家训 */
  familyRules: string = '';
  /** 修谱说明/凡例 */
  editingNotes: string = '';
  /** 封面颜色（十六进制） */
  coverColor: string = '#8C2F1E';
  /** 封面纹样：classic / modern / minimal */
  coverPattern: string = 'classic';
  /** 创建时间 */
  createdAt: number = 0;
  /** 更新时间 */
  updatedAt: number = 0;
}

export function createEmptyGenealogy(): Genealogy {
  const g: Genealogy = new Genealogy();
  g.createdAt = Date.now();
  g.updatedAt = g.createdAt;
  return g;
}
