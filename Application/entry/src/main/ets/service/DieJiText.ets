import { Person, SpouseRelation, normalizeSpouseRelation } from '../model/Person';
import { generationLabel } from '../model/Enums';
import { ageOf, parseHistoricalDate, parseYear, formatDateConversion } from '../util/DateConverter';
import { GanZhi } from '../util/LunarUtil';

/**
 * 牒记式谱的公共正文生成器（屏幕 / PDF / Markdown 三端共用）。
 *
 * 按《牒记改版参考》的句式自动串文：
 *   十世，讳景明，字昭远，行二，乃启文公次子。生于……，享年……，终于……。
 *   配孺人李氏，本邑李君德顺之女，生于……。生子三：长承宗、次承业。
 *   公与妣合葬……。
 *
 * 取数原则：全部来自现有字段，缺项即省略对应分句，不编造内容。
 *  - 已故者名前用「讳」，在世者用「名」；
 *  - 生卒全无写「年庚未知」，已故无墓葬写「坟墓未知」；
 *  - 公历日期补干支年；农历/年号原文保留，不改写、不倒推朔望月。
 */

/** 复姓表：牒记「李氏」「欧阳氏」取姓时用 */
const COMPOUND_SURNAMES: string[] = ['欧阳', '太史', '端木', '上官', '司马', '东方', '独孤', '南宫', '万俟',
  '闻人', '夏侯', '诸葛', '尉迟', '公羊', '赫连', '澹台', '皇甫', '宗政', '濮阳', '公冶', '太叔', '申屠',
  '公孙', '慕容', '仲孙', '钟离', '长孙', '宇文', '司徒', '鲜于', '司空', '闾丘', '子车', '亓官', '司寇',
  '巫马', '公西', '颛孙', '壤驷', '公良', '漆雕', '乐正', '宰父', '谷梁', '拓跋', '夹谷', '轩辕', '令狐',
  '段干', '百里', '呼延', '东郭', '南门', '羊舌', '微生', '公户', '公玉', '公仪', '梁丘', '公仲', '公上',
  '公门', '公山', '公坚', '左丘', '公伯', '西门', '公祖', '第五', '公乘', '贯丘', '公皙', '南荣', '东里',
  '东宫', '仲长', '子书', '子桑', '即墨', '达奚', '褚师'];

/**
 * 互引选项：屏幕 / PDF / Markdown 共用。
 * - enabled：是否在姓名后写 UID、在亲属名后写「UID·第N页」；
 * - refs：第一遍排版传 null 用等宽占位页码，第二遍传真实 uid→页码；
 * - crossRef：分卷导出时本卷查不到的亲属，用「第N卷M页」；
 * - withPage：是否带页码。屏幕与 Markdown 无页码概念，只写「（F001）」。
 */
export class DieJiRefOptions {
  enabled: boolean = false;
  refs: Map<string, number> | null = null;
  crossRef: Map<string, string> | null = null;
  withPage: boolean = true;
}

/** 全角空格：牒记正文的唯一断句符（不用句读标点） */
export const DIE_SPACE: string = '\u3000';

/**
 * 姓名在正文中的区间（UTF-16 下标），供屏幕/PDF 做加粗放大。
 * relative=true 表示亲属姓名：只加粗，字号仍用正文四号。
 */
export class DieJiNameRange {
  start: number = 0;
  end: number = 0;
  relative: boolean = false;
}

/** 排行前缀 → 行第序号（长子/次子/三子…；独子/随母子返回 -1） */
function rankIndex(rank: string): number {
  const r: string = rank.trim();
  if (r.length === 0) {
    return -1;
  }
  if (r.indexOf('长') === 0) {
    return 1;
  }
  if (r.indexOf('次') === 0) {
    return 2;
  }
  if (r.indexOf('独') === 0 || r.indexOf('随母') === 0 || r.indexOf('始祖') >= 0) {
    return -1;
  }
  const body: string = r.substring(0, r.length - 1);
  const n: number = cnToNumber(body);
  return n > 0 ? n : -1;
}

const CN_DIGITS: string[] = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];

/** 中文数字（1~99 足够族谱使用） */
function cnNum(n: number): string {
  if (n < 0) {
    return '';
  }
  if (n <= 10) {
    return CN_DIGITS[n];
  }
  if (n < 20) {
    return '十' + CN_DIGITS[n - 10];
  }
  if (n < 100) {
    const ten: string = CN_DIGITS[Math.floor(n / 10)] + '十';
    return n % 10 === 0 ? ten : ten + CN_DIGITS[n % 10];
  }
  return n.toString();
}

function cnToNumber(text: string): number {
  const t: string = text.trim().replace(/廿/g, '二十').replace(/卅/g, '三十');
  if (t.length === 0) {
    return -1;
  }
  let total: number = 0;
  let digit: number = 0;
  for (let i: number = 0; i < t.length; i++) {
    const ch: string = t.charAt(i);
    const d: number = CN_DIGITS.indexOf(ch);
    if (d >= 0 && ch !== '十') {
      digit = d;
      continue;
    }
    if (ch === '十' || ch === '百') {
      const unit: number = ch === '十' ? 10 : 100;
      total = total + (digit === 0 ? 1 : digit) * unit;
      digit = 0;
      continue;
    }
    return -1;
  }
  return total + digit;
}

/** 姓（含复姓） */
function surnameOf(name: string): string {
  const n: string = name.trim();
  if (n.length === 0) {
    return '';
  }
  for (let i: number = 0; i < COMPOUND_SURNAMES.length; i++) {
    if (n.indexOf(COMPOUND_SURNAMES[i]) === 0) {
      return COMPOUND_SURNAMES[i];
    }
  }
  return n.charAt(0);
}

/** 名（去掉姓；姓名本身以「氏」结尾时视为只有姓，名留空） */
function givenNameOf(name: string): string {
  const n: string = name.trim();
  const s: string = surnameOf(n);
  let given: string = n.substring(s.length);
  if (given.endsWith('氏')) {
    given = given.substring(0, given.length - 1);
  }
  return given;
}

/** 至少三字时取姓+氏，否则原样 */
function clanName(name: string): string {
  const n: string = name.trim();
  const s: string = surnameOf(n);
  if (s.length === 0) {
    return '';
  }
  if (n.length <= s.length) {
    return n + '氏';
  }
  return s + '氏';
}

/** 籍贯取末级地名（「广东-梅州-兴宁-城西」→「城西」） */
function shortPlace(place: string): string {
  const t: string = place.trim();
  if (t.length === 0) {
    return '';
  }
  const parts: string[] = t.split(/[-/·]/);
  for (let i: number = parts.length - 1; i >= 0; i--) {
    const seg: string = parts[i].trim();
    if (seg.length > 0) {
      return seg;
    }
  }
  return t;
}

/** 干支年（两年字，如「庚申」）；算不出返回空串 */
function ganZhiYear(year: number, month: number, day: number): string {
  if (year <= 0) {
    return '';
  }
  const useLiChun: boolean = month > 0 && day > 0;
  const text: string = GanZhi.yearGanZhi(year, useLiChun, month, day);
  return text.length >= 2 ? text.substring(0, 2) : '';
}

const GAN_ZHI_CHARS: string = '甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥';

function hasGanZhi(text: string): boolean {
  for (let i: number = 0; i < text.length - 1; i++) {
    if (GAN_ZHI_CHARS.indexOf(text.charAt(i)) >= 0 &&
      '子丑寅卯辰巳午未申酉戌亥'.indexOf(text.charAt(i + 1)) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 日期文本：原文保留，公历年月日补转换文本。
 * 农历原文（如「光绪十五年己丑仲秋望日辰时」）不再拼装，避免改写史料。
 * 转换格式：
 *  - 1912 年前：年号+干支年+干支月+干支日（如 弘治己酉年丁丑月乙丑日）
 *  - 1912~1949：民国X年+农历月日（如 民国9年三月廿二日）
 *  - 1949 后：中文数字年+农历月日（如 一九四九年八月初十日）
 */
function dateText(date: string, calendar: string): string {
  const raw: string = date.trim();
  if (raw.length === 0) {
    return '';
  }
  const parsed = parseHistoricalDate(raw);
  // 纯数字公历（1859-02-03）：parseHistoricalDate 的快速路径只取年，
  // 这里单独取全月日，避免「生于1859-02-03（己未年）」这种半截写法。
  const ymd: RegExpMatchArray | null = raw.match(/^([0-9]{3,4})[-/.](\d{1,2})[-/.](\d{1,2})$/);
  if (ymd !== null) {
    const y: number = parseInt(ymd[1], 10);
    const mo: number = parseInt(ymd[2], 10);
    const da: number = parseInt(ymd[3], 10);
    const conv: string = formatDateConversion(y, mo, da);
    return '公元' + y.toString() + '年' + mo.toString() + '月' + da.toString() + '日' +
      (conv.length > 0 ? '（' + conv + '）' : '');
  }
  // 农历原文：保留，不改写
  if (calendar === '农历') {
    return raw;
  }
  // 纯公历（1980-05-20 / 1980/5/20）转成谱牒常见写法
  if (parsed.year > 0 && parsed.month > 0 && parsed.day > 0 &&
    raw.indexOf('年') < 0 && raw.indexOf('月') < 0 && raw.indexOf('日') < 0) {
    const conv: string = formatDateConversion(parsed.year, parsed.month, parsed.day);
    return '公元' + parsed.year.toString() + '年' + parsed.month.toString() + '月' + parsed.day.toString() + '日' +
      (conv.length > 0 ? '（' + conv + '）' : '');
  }
  // 其他公历写法（如 1980年5月20日）：保留原文，追加转换
  if (parsed.year > 0 && parsed.month > 0 && parsed.day > 0) {
    const conv: string = formatDateConversion(parsed.year, parsed.month, parsed.day);
    return conv.length > 0 ? raw + '（' + conv + '）' : raw;
  }
  return raw;
}

/** 夫妻称谓：元配/正室等统称「配」，其余名分（继室、侧室、偏房…）按原称谓 */
function spousePrefix(relation: string): string {
  const r: string = normalizeSpouseRelation(relation);
  if (r === '元配' || r === '正室' || r === '嫡妻' || r === '发妻' || r === '正房' ||
    r === '未记' || r === '夫') {
    return '配';
  }
  return r;
}

/**
 * 关系索引：一次建表，逐人生成牒记时 O(1) 取父母/配偶/子女。
 * 子女按排行（长/次/三…）排序，无排行时按 UID 排。
 */
export class DieJiIndex {
  private byUid: Map<string, Person> = new Map<string, Person>();
  private kids: Map<string, Person[]> = new Map<string, Person[]>();
  /** 反向配偶：丈夫的配偶表里登记了某位妻子，妻子自己的 spouses 可能未回填 */
  private menByWife: Map<string, Person[]> = new Map<string, Person[]>();

  constructor(people: Person[]) {
    for (let i: number = 0; i < people.length; i++) {
      const key: string = people[i].uid.trim().toUpperCase();
      if (key.length > 0 && !this.byUid.has(key)) {
        this.byUid.set(key, people[i]);
      }
    }
    for (let i: number = 0; i < people.length; i++) {
      this.link(people[i].fatherId, people[i]);
      this.link(people[i].motherId, people[i]);
    }
    for (let i: number = 0; i < people.length; i++) {
      const p: Person = people[i];
      if (p.gender !== '男') {
        continue;
      }
      for (let j: number = 0; j < p.spouses.length; j++) {
        const key: string = p.spouses[j].uid.trim().toUpperCase();
        if (key.length === 0) {
          continue;
        }
        const arr: Person[] | undefined = this.menByWife.get(key);
        if (arr === undefined) {
          this.menByWife.set(key, [p]);
        } else {
          arr.push(p);
        }
      }
    }
    this.kids.forEach((arr: Person[]): void => {
      arr.sort((a: Person, b: Person): number => {
        const ra: number = rankIndex(a.rank);
        const rb: number = rankIndex(b.rank);
        const oa: number = ra > 0 ? ra : 999;
        const ob: number = rb > 0 ? rb : 999;
        if (oa !== ob) {
          return oa - ob;
        }
        const ba: number = parseYear(a.birthDate);
        const bb: number = parseYear(b.birthDate);
        if (ba > 0 && bb > 0 && ba !== bb) {
          return ba - bb;
        }
        return a.uid.localeCompare(b.uid);
      });
    });
  }

  private link(parentUid: string, child: Person): void {
    const key: string = parentUid.trim().toUpperCase();
    if (key.length === 0) {
      return;
    }
    const arr: Person[] | undefined = this.kids.get(key);
    if (arr === undefined) {
      this.kids.set(key, [child]);
    } else if (arr.indexOf(child) < 0) {
      arr.push(child);
    }
  }

  person(uid: string): Person | null {
    const p: Person | undefined = this.byUid.get(uid.trim().toUpperCase());
    return p === undefined ? null : p;
  }

  fatherOf(p: Person): Person | null {
    return this.person(p.fatherId);
  }

  childrenOf(uid: string): Person[] {
    const arr: Person[] | undefined = this.kids.get(uid.trim().toUpperCase());
    return arr === undefined ? [] : arr;
  }

  /**
   * 女子的丈夫：先看本人配偶表，再看哪些男性把她登记为配偶。
   * 旧数据常只写单边关系，不补反向就会把有夫之妇误排成未婚女子。
   */
  husbandsOf(p: Person): Person[] {
    const out: Person[] = [];
    for (let i: number = 0; i < p.spouses.length; i++) {
      const sp: Person | null = this.person(p.spouses[i].uid);
      if (sp !== null && sp.gender === '男') {
        out.push(sp);
      }
    }
    const rev: Person[] | undefined = this.menByWife.get(p.uid.trim().toUpperCase());
    if (rev !== undefined) {
      for (let i: number = 0; i < rev.length; i++) {
        let exists: boolean = false;
        for (let j: number = 0; j < out.length; j++) {
          if (out[j].uid.trim().toUpperCase() === rev[i].uid.trim().toUpperCase()) {
            exists = true;
            break;
          }
        }
        if (!exists) {
          out.push(rev[i]);
        }
      }
    }
    return out;
  }

  /** 同父同性别兄弟姊妹中的次序（1 起），找不到父返回 -1 */
  siblingIndex(p: Person): number {
    const father: Person | null = this.fatherOf(p);
    if (father === null) {
      return -1;
    }
    const same: Person[] = this.childrenOf(father.uid).filter((c: Person): boolean =>
      c.gender === p.gender);
    for (let i: number = 0; i < same.length; i++) {
      if (same[i].uid.trim().toUpperCase() === p.uid.trim().toUpperCase()) {
        return i + 1;
      }
    }
    return -1;
  }
}

/** 牒记正文：一个入口，按性别/在世状态/婚姻子女情况自动套用参考句式 */
export class DieJiText {
  /**
   * 生成一名人物的完整牒记段落。
   * 由调用方决定是否再做繁简转换（T）。
   */
  static paragraph(p: Person, idx: DieJiIndex, opts?: DieJiRefOptions): string {
    let raw: string = '';
    if (p.gender === '女') {
      const husband: Person | null = DieJiText.husbandOf(p, idx);
      if (husband !== null) {
        raw = DieJiText.wifeParagraph(p, husband, idx, opts);
      }
    }
    if (raw.length === 0) {
      raw = DieJiText.personParagraph(p, idx, opts);
    }
    // 统一出口去句读标点：三端排版只认全角空格断句
    return DieJiText.plainPunct(raw);
  }

  /**
   * 正文中的姓名区间：
   * - 本人谱名：只标第一次出现（后文重复的名是普通正文，不放大）；
   * - 亲属（父母/配偶/子女/岳父）：只加粗，字号仍为正文四号（relative=true）。
   * 妻妾条目正文只写「姓氏 + 氏」，整名找不到时退化为「吴氏」与「讳名」。
   * idx 缺省时只认本人（兼容无全谱索引的单卡片场景）。
   */
  static nameRanges(p: Person, text: string, idx?: DieJiIndex): DieJiNameRange[] {
    const out: DieJiNameRange[] = [];
    if (text.length === 0) {
      return out;
    }
    // 本人优先占位：同名亲属不会抢走「讳XX公」里的谱名
    DieJiText.markPerson(p.name, text, out, false);
    if (idx !== undefined) {
      const names: string[] = [];
      const father: Person | null = idx.fatherOf(p);
      if (father !== null) {
        DieJiText.addName(names, father.name);
      }
      const mother: Person | null = idx.person(p.motherId);
      if (mother !== null) {
        DieJiText.addName(names, mother.name);
      }
      // 配偶：男性看本人配偶表，女性看双向登记（旧数据常只写单边）
      const spouses: Person[] = p.gender === '女' ? idx.husbandsOf(p) : DieJiText.spousePersons(p, idx);
      for (let i: number = 0; i < spouses.length; i++) {
        const sp: Person = spouses[i];
        DieJiText.addName(names, sp.name);
        // 岳父：「本邑李德顺之女」里的李德顺也是姓名
        const inLaw: Person | null = idx.person(sp.fatherId);
        if (inLaw !== null) {
          DieJiText.addName(names, inLaw.name);
        }
        DieJiText.addName(names, sp.fatherName);
      }
      const kids: Person[] = idx.childrenOf(p.uid);
      for (let i: number = 0; i < kids.length; i++) {
        DieJiText.addName(names, kids[i].name);
      }
      // 长名优先：「家泽霖」先占区间，避免被短名「家泽」切碎
      names.sort((a: string, b: string): number => b.length - a.length);
      for (let i: number = 0; i < names.length; i++) {
        DieJiText.markPerson(names[i], text, out, true);
      }
    }
    return out;
  }

  /** 男性本人的配偶对象（妻子条目另走 husbandsOf） */
  private static spousePersons(p: Person, idx: DieJiIndex): Person[] {
    const out: Person[] = [];
    for (let i: number = 0; i < p.spouses.length; i++) {
      const sp: Person | null = idx.person(p.spouses[i].uid);
      if (sp !== null) {
        out.push(sp);
      }
    }
    return out;
  }

  /** 一个姓名：优先整名，其次「姓氏」，最后「讳名」，每级只标第一次出现 */
  private static markPerson(name: string, text: string, out: DieJiNameRange[],
    relative: boolean): void {
    const full: string = name.trim();
    if (full.length === 0) {
      return;
    }
    if (DieJiText.markFirst(full, text, out, relative)) {
      return;
    }
    const clan: string = clanName(full);
    if (clan.length > 0 && clan !== full) {
      DieJiText.markFirst(clan, text, out, relative);
    }
    const given: string = givenNameOf(full);
    if (given.length >= 2) {
      DieJiText.markFirst(given, text, out, relative);
    }
  }

  /** 标出第一次未占用的出现位置；同一个名字在正文里重复出现时不再加粗 */
  private static markFirst(name: string, text: string, out: DieJiNameRange[],
    relative: boolean): boolean {
    let from: number = 0;
    while (name.length > 0 && from <= text.length - name.length) {
      const at: number = text.indexOf(name, from);
      if (at < 0) {
        return false;
      }
      const end: number = at + name.length;
      if (!DieJiText.overlaps(out, at, end)) {
        const r: DieJiNameRange = new DieJiNameRange();
        r.start = at;
        r.end = end;
        r.relative = relative;
        out.push(r);
        return true;
      }
      from = at + 1;
    }
    return false;
  }

  private static overlaps(out: DieJiNameRange[], start: number, end: number): boolean {
    for (let i: number = 0; i < out.length; i++) {
      if (start < out[i].end && end > out[i].start) {
        return true;
      }
    }
    return false;
  }

  private static addName(list: string[], name: string): void {
    const n: string = name.trim();
    if (n.length === 0 || list.indexOf(n) >= 0) {
      return;
    }
    list.push(n);
  }

  /**
   * 牒记排版标点：不用逗号、句号、顿号、分号，一律以全角空格断句；
   * 冒号保留（「生子四：」「女一：」），括号、书名号、间隔号原样。
   * 屏幕 / PDF / Markdown 共用这一个出口，改这里三端同步。
   */
  static plainPunct(text: string): string {
    let s: string = text;
    s = s.split('，').join(DIE_SPACE);
    s = s.split('。').join(DIE_SPACE);
    s = s.split('、').join(DIE_SPACE);
    s = s.split('；').join(DIE_SPACE);
    // 连续空白（半角空格、换行、制表符、全角空格）压成一个全角空格
    s = s.replace(/[\s\u3000]+/g, DIE_SPACE);
    s = s.replace(/^[\s\u3000]+/, '');
    s = s.replace(/[\s\u3000]+$/, '');
    return s;
  }

  /**
   * 正文中的括号引用区间：本人「（F001）」与亲属「（M001·第2页）」。
   * 屏幕 / PDF 据此把引用排成五号常规字，不参与姓名放大。
   */
  static refRanges(text: string): DieJiNameRange[] {
    const out: DieJiNameRange[] = [];
    let i: number = 0;
    while (i < text.length) {
      const open: number = text.indexOf('（', i);
      if (open < 0) {
        break;
      }
      const close: number = text.indexOf('）', open + 1);
      if (close < 0) {
        break;
      }
      if (DieJiText.isRefBody(text.substring(open + 1, close))) {
        const r: DieJiNameRange = new DieJiNameRange();
        r.start = open;
        r.end = close + 1;
        out.push(r);
      }
      i = close + 1;
    }
    return out;
  }

  /** 「F001」「M002·第2页」「F003·第4卷2页」「F001·另卷」：字母 + 数字 + 可选「·」后缀 */
  private static isRefBody(body: string): boolean {
    let i: number = 0;
    while (i < body.length) {
      const c: number = body.charCodeAt(i);
      const alpha: boolean = (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
      if (!alpha) {
        break;
      }
      i = i + 1;
    }
    if (i === 0 || i > 4) {
      return false;
    }
    let d: number = 0;
    while (i + d < body.length) {
      const c: number = body.charCodeAt(i + d);
      if (c < 48 || c > 57) {
        break;
      }
      d = d + 1;
    }
    if (d === 0) {
      return false;
    }
    const rest: string = body.substring(i + d);
    return rest.length === 0 || rest.charAt(0) === '·';
  }

  /** 本人 UID：PDF 正文标记「谁是谁」 */
  private static uidSuffix(p: Person, opts?: DieJiRefOptions): string {
    if (opts === undefined || !opts.enabled) {
      return '';
    }
    const id: string = p.uid.trim().toUpperCase();
    return id.length > 0 ? '（' + id + '）' : '';
  }

  /** 亲属互引：姓名（UID·第N页）；第一遍用等宽占位串，保证两遍折行数可比 */
  private static refSuffix(target: Person | null, opts?: DieJiRefOptions): string {
    if (target === null || opts === undefined || !opts.enabled) {
      return '';
    }
    const id: string = target.uid.trim().toUpperCase();
    if (id.length === 0) {
      return '';
    }
    // 屏幕 / Markdown 没有页码：只留「（F001）」，避免出现「第00卷0000页」占位
    if (!opts.withPage) {
      return '（' + id + '）';
    }
    let page: string = '';
    if (opts.refs !== null) {
      const n: number | undefined = opts.refs.get(id);
      if (n !== undefined) {
        page = '·第' + n.toString() + '页';
      } else if (opts.crossRef !== null) {
        const cross: string | undefined = opts.crossRef.get(id);
        page = cross === undefined ? '·另卷' : '·' + cross;
      } else {
        page = '·另卷';
      }
    } else {
      page = '·第00卷0000页';
    }
    return '（' + id + page + '）';
  }

  /** 女子所适之夫：取首位男性配偶（含反向登记） */
  private static husbandOf(p: Person, idx: DieJiIndex): Person | null {
    const list: Person[] = idx.husbandsOf(p);
    return list.length > 0 ? list[0] : null;
  }

  private static isDead(p: Person): boolean {
    return p.lifeStatus === '已故';
  }

  private static namePart(p: Person): string {
    return (DieJiText.isDead(p) ? '讳' : '名') + p.name.trim();
  }

  /** 十世（去掉「第」） */
  private static generationText(p: Person): string {
    const g: string = generationLabel(p.generation);
    return g.indexOf('第') === 0 ? g.substring(1) : g;
  }

  /** 行二：仅男性且排行可解析时输出 */
  private static rowText(p: Person): string {
    if (p.gender !== '男') {
      return '';
    }
    const n: number = rankIndex(p.rank);
    return n > 0 ? '行' + cnNum(n) : '';
  }

  /** 「次子/三女」：优先用排行字段，否则按同父同胞次序推算 */
  private static childOrdinal(p: Person, idx: DieJiIndex): string {
    const rank: string = p.rank.trim();
    if (rank === '独子' || rank === '独女') {
      return rank;
    }
    if (rank.length > 0 && rankIndex(rank) > 0) {
      return rank;
    }
    const n: number = idx.siblingIndex(p);
    if (n > 0 && n <= 10) {
      return (n === 1 ? '长' : n === 2 ? '次' : cnNum(n)) + (p.gender === '女' ? '女' : '子');
    }
    return p.gender === '女' ? '女' : '子';
  }

  /** 首句：十世，讳景明，字昭远，号朴庵，行二，乃启文公次子。 */
  private static headSentence(p: Person, idx: DieJiIndex, opts?: DieJiRefOptions): string {
    const parts: string[] = [DieJiText.generationText(p), DieJiText.namePart(p) + DieJiText.uidSuffix(p, opts)];
    if (p.courtesyName.trim().length > 0) {
      parts.push('字' + p.courtesyName.trim());
    }
    if (p.artName.trim().length > 0) {
      parts.push('号' + p.artName.trim());
    }
    const row: string = DieJiText.rowText(p);
    if (row.length > 0) {
      parts.push(row);
    }
    const father: Person | null = idx.fatherOf(p);
    if (father !== null && father.name.trim().length > 0) {
      parts.push('乃' + father.name.trim() + '公' + DieJiText.childOrdinal(p, idx) +
        DieJiText.refSuffix(father, opts));
    }
    return parts.join('，') + '。';
  }

  /** 妣氏条目首句：孺人刘氏，讳秀兰，潭江刘公振邦之女，绍文公原配。 */
  private static wifeHeadSentence(p: Person, husband: Person, idx: DieJiIndex,
    opts?: DieJiRefOptions): string {
    const dead: boolean = DieJiText.isDead(p);
    const relation: string = DieJiText.relationToHusband(p, husband);
    const parts: string[] = [];
    const clan: string = clanName(p.name);
    parts.push((clan.length > 0 ? clan : p.name.trim()) + DieJiText.uidSuffix(p, opts));
    const given: string = givenNameOf(p.name);
    if (given.length > 0) {
      parts.push((dead ? '讳' : '名') + given);
    }
    const parent: string = DieJiText.parentClause(p, idx);
    if (parent.length > 0) {
      const father: Person | null = idx.person(p.fatherId);
      parts.push(shortPlace(p.birthPlace) + parent + DieJiText.refSuffix(father, opts));
    }
    const husbandTitle: string = husband.name.trim() + (DieJiText.isDead(husband) ? '公' : '');
    parts.push(husbandTitle + DieJiText.relationLabel(relation) + DieJiText.refSuffix(husband, opts));
    return parts.join('，') + '。';
  }

  /** 她对丈夫的名分：从丈夫的配偶表里反查 */
  private static relationToHusband(p: Person, husband: Person): string {
    for (let i: number = 0; i < husband.spouses.length; i++) {
      if (husband.spouses[i].uid.trim().toUpperCase() === p.uid.trim().toUpperCase()) {
        return normalizeSpouseRelation(husband.spouses[i].relation);
      }
    }
    for (let i: number = 0; i < p.spouses.length; i++) {
      if (p.spouses[i].uid.trim().toUpperCase() === husband.uid.trim().toUpperCase()) {
        return normalizeSpouseRelation(p.spouses[i].relation);
      }
    }
    return '元配';
  }

  /** 元配→原配（牒记旧写法），其余原样 */
  private static relationLabel(relation: string): string {
    const r: string = normalizeSpouseRelation(relation);
    if (r === '元配') {
      return '原配';
    }
    return r === '未记' ? '原配' : r;
  }

  /** 生卒句：生于…，享年…，终于…；young 时改为殇句 */
  private static lifeSentence(p: Person, young: boolean): string {
    const dead: boolean = DieJiText.isDead(p);
    // 失联/不详：齿录只到生年，享年与去向均记「未知」
    const lost: boolean = p.lifeStatus === '失联' || p.lifeStatus === '不详';
    const bText: string = dateText(p.birthDate, p.birthCalendar);
    const dText: string = dateText(p.deathDate, p.deathCalendar);
    if (bText.length === 0 && dText.length === 0) {
      return lost ? '年庚未知，为' + p.lifeStatus + '。' : '年庚未知。';
    }
    const age: number = ageOf(p.birthDate, p.deathDate, p.lifeStatus);
    const parts: string[] = [];
    if (bText.length > 0) {
      parts.push('生于' + bText);
    }
    if (young) {
      if (dText.length > 0) {
        parts.push('不幸殇于' + dText);
      }
      if (age >= 0) {
        parts.push('年仅' + cnNum(age) + '岁');
      }
    } else {
      if (dead && age >= 0) {
        parts.push('享年' + cnNum(age) + '岁');
      }
      if (dText.length > 0) {
        parts.push((dead ? '终于' : '卒于') + dText);
      }
    }
    const base: string = parts.join('，') + '。';
    return lost ? base + '享年未知，为' + p.lifeStatus + '。' : base;
  }

  /** 妻子父母称谓：优先已录入的父亲，其次自定义父名；再其次母亲 */
  private static parentClause(sp: Person, idx: DieJiIndex): string {
    const father: Person | null = idx.person(sp.fatherId);
    if (father !== null && father.name.trim().length > 0) {
      return father.name.trim() + (DieJiText.isDead(father) ? '公' : '') + '之女';
    }
    if (sp.fatherName.trim().length > 0) {
      return sp.fatherName.trim() + '之女';
    }
    const mother: Person | null = idx.person(sp.motherId);
    if (mother !== null && mother.name.trim().length > 0) {
      return DieJiText.motherClause(mother.name);
    }
    if (sp.motherName.trim().length > 0) {
      return DieJiText.motherClause(sp.motherName);
    }
    return '';
  }

  /** 岳母：王秀兰→王氏讳秀兰之女；王氏/王→王氏之女 */
  private static motherClause(name: string): string {
    const n: string = name.trim();
    const s: string = surnameOf(n);
    if (s.length === 0) {
      return '';
    }
    let given: string = givenNameOf(n);
    return given.length > 0 ? s + '氏讳' + given + '之女' : s + '氏之女';
  }

  /** 配偶句：配李氏，本邑李德顺之女。不写配偶生卒，也不加「孺人」。 */
  private static spouseSentences(p: Person, idx: DieJiIndex, opts?: DieJiRefOptions): string[] {
    const out: string[] = [];
    for (let i: number = 0; i < p.spouses.length; i++) {
      const relation: SpouseRelation = p.spouses[i];
      const sp: Person | null = idx.person(relation.uid);
      if (sp === null) {
        continue;
      }
      const prefix: string = spousePrefix(relation.relation);
      const clan: string = clanName(sp.name);
      let text: string = prefix + (clan.length > 0 ? clan : sp.name.trim()) + DieJiText.refSuffix(sp, opts);
      const parent: string = DieJiText.parentClause(sp, idx);
      if (parent.length > 0) {
        text += '，' + shortPlace(sp.birthPlace) + parent;
      }
      out.push(text + '。');
    }
    return out;
  }

  /** 子女句：生子三：长…、次…；女二：长适…、次适…。 */
  private static childrenSentence(p: Person, idx: DieJiIndex, opts?: DieJiRefOptions): string {
    if (p.childless) {
      return '生子无出。';
    }
    const kids: Person[] = idx.childrenOf(p.uid);
    if (kids.length === 0) {
      return '';
    }
    const sons: Person[] = kids.filter((c: Person): boolean => c.gender === '男');
    const daughters: Person[] = kids.filter((c: Person): boolean => c.gender === '女');
    const groups: string[] = [];
    if (sons.length > 0) {
      const names: string[] = [];
      for (let i: number = 0; i < sons.length; i++) {
        names.push(DieJiText.orderWord(i, sons.length) + sons[i].name.trim() +
          DieJiText.childMarkSuffix(sons[i]) + DieJiText.refSuffix(sons[i], opts));
      }
      groups.push('生子' + cnNum(sons.length) + '：' + names.join('、'));
    }
    if (daughters.length > 0) {
      const names: string[] = [];
      for (let i: number = 0; i < daughters.length; i++) {
        names.push(DieJiText.orderWord(i, daughters.length) +
          DieJiText.daughterMarriage(daughters[i], idx) +
          DieJiText.childMarkSuffix(daughters[i]) + DieJiText.refSuffix(daughters[i], opts));
      }
      groups.push('女' + cnNum(daughters.length) + '：' + names.join('、'));
    }
    return groups.join('；') + '。';
  }

  /** 只有多人时才加长/次/三，单人直接写名 */
  private static orderWord(index: number, total: number): string {
    if (total <= 1) {
      return '';
    }
    return index === 0 ? '长' : index === 1 ? '次' : cnNum(index + 1);
  }

  /** 子女标记后缀：殇/幼殇/早卒/出嗣/兼祧/继子/养子 */
  private static childMarkSuffix(child: Person): string {
    const mark: string = child.childMark.trim();
    if (mark === '未记' || mark.length === 0) return '';
    if (mark === '殇') return '（殇）';
    if (mark === '幼殇') return '（幼殇）';
    if (mark === '早卒') return '（早卒）';
    if (mark === '出嗣') {
      const target: string = child.childMarkTarget.trim();
      return target.length > 0 ? '（出嗣' + target + '）' : '（出嗣）';
    }
    if (mark === '兼祧') {
      const target: string = child.childMarkTarget.trim();
      return target.length > 0 ? '（兼祧' + target + '嗣）' : '（兼祧）';
    }
    if (mark === '继子') {
      const source: string = child.childMarkSource.trim();
      const seq: number = child.childMarkSeq;
      if (source.length > 0 && seq > 0) {
        return '（' + source + '第' + cnNum(seq) + '子入继）';
      }
      if (source.length > 0) return '（' + source + '入继）';
      return '（继子）';
    }
    if (mark === '养子') return '（养子）';
    return '';
  }

  /** 女适某氏；未嫁则写本名 */
  private static daughterMarriage(daughter: Person, idx: DieJiIndex): string {
    const husband: Person | null = DieJiText.husbandOf(daughter, idx);
    if (husband === null) {
      return daughter.name.trim();
    }
    const sur: string = surnameOf(husband.name);
    return '适' + shortPlace(husband.birthPlace) + (sur.length > 0 ? sur + '氏' : husband.name.trim());
  }

  /** 学历/职业：按文言习惯改写，如「学至本科，毕业于华南理工大学，以工程师为业。」 */
  private static careerSentence(p: Person): string {
    const parts: string[] = [];
    const edu: string = DieJiText.educationText(p.education.trim());
    if (edu.length > 0) {
      parts.push(edu);
    }
    if (p.occupation.trim().length > 0) {
      parts.push('以' + p.occupation.trim() + '为业');
    }
    return parts.length > 0 ? parts.join('，') + '。' : '';
  }

  /** 「本科-华南理工大学-计算机」→「学至本科，毕业于华南理工大学，习计算机」 */
  private static educationText(edu: string): string {
    if (edu.length === 0) {
      return '';
    }
    const degrees: string[] = ['小学', '初中', '高中', '中专', '大专', '本科', '硕士', '博士', '研究生'];
    const raw: string[] = edu.split(/[-—·/]/);
    const segs: string[] = [];
    for (let i: number = 0; i < raw.length; i++) {
      const s: string = raw[i].trim();
      if (s.length > 0) {
        segs.push(s);
      }
    }
    if (segs.length === 0) {
      return '';
    }
    const out: string[] = [];
    if (segs.length === 1) {
      return degrees.indexOf(segs[0]) >= 0 ? '学至' + segs[0] : '尝就学于' + segs[0];
    }
    out.push(degrees.indexOf(segs[0]) >= 0 ? '学至' + segs[0] : '尝就学于' + segs[0]);
    out.push('毕业于' + segs[1]);
    if (segs.length >= 3) {
      out.push('习' + segs[2]);
    }
    return out.join('，');
  }

  /** 墓葬定位：东经/北纬/海拔；未定位不写 */
  private static gpsText(p: Person): string {
    if (p.graveLat === 0 && p.graveLng === 0) {
      return '';
    }
    return '坟定位坐标：东经' + p.graveLng.toFixed(6) + '°北纬' + p.graveLat.toFixed(6) +
      '°，海拔' + p.graveAltitude.toFixed(1) + '米';
  }

  /** 墓葬句：合葬/葬/附葬/坟墓未知，后接定位坐标 */
  private static graveSentence(p: Person, idx: DieJiIndex): string {
    const dead: boolean = DieJiText.isDead(p);
    const grave: string = p.graveInfo.trim().replace(/。$/, '');
    const gps: string = DieJiText.gpsText(p);
    let base: string = '';
    if (grave.length > 0) {
      if (grave.indexOf('葬') >= 0) {
        base = grave;
      } else if (p.gender === '男') {
        let wifeGrave: boolean = false;
        for (let i: number = 0; i < p.spouses.length; i++) {
          const sp: Person | null = idx.person(p.spouses[i].uid);
          if (sp !== null && sp.graveInfo.trim().length > 0) {
            wifeGrave = true;
            break;
          }
        }
        base = wifeGrave ? '公与妣合葬' + grave : '葬' + grave;
      } else {
        base = '葬' + grave;
      }
    }
    const parts: string[] = [];
    if (base.length > 0) {
      parts.push(base);
    }
    if (gps.length > 0) {
      parts.push(gps);
    }
    if (parts.length === 0) {
      return dead ? '坟墓未知。' : '';
    }
    return parts.join('。') + '。';
  }

  /** 无配偶 / 无子嗣的旧谱用语 */
  private static heirSentences(p: Person, idx: DieJiIndex): string[] {
    const dead: boolean = DieJiText.isDead(p);
    if (!dead) {
      return [];
    }
    const out: string[] = [];
    const age: number = ageOf(p.birthDate, p.deathDate, p.lifeStatus);
    const hasDate: boolean = p.birthDate.trim().length > 0 || p.deathDate.trim().length > 0;
    const young: boolean = age >= 0 && age <= 15 && p.spouses.length === 0 &&
      idx.childrenOf(p.uid).length === 0;
    if (p.spouses.length === 0 && idx.childrenOf(p.uid).length === 0) {
      if (young) {
        out.push(p.gender === '女' ? '未字' : '未聘');
      } else if (age >= 18 || hasDate) {
        // 年庚全无时不断言「终身未娶」，避免把早夭或无资料者写死
        out.push(p.gender === '女' ? '终身未字' : '终身未娶');
      }
    }
    if (idx.childrenOf(p.uid).length === 0 && p.adoption.trim().length === 0) {
      if (young || age >= 18 || hasDate) {
        out.push('无嗣');
      }
    }
    return out.length === 0 ? [] : [out.join('，') + '。'];
  }

  /** 出继/出嗣：本人被过继给他人（非本人立嗣） */
  private static isOutAdoption(p: Person): boolean {
    const a: string = p.adoption.trim();
    return a.indexOf('出继') >= 0 || a.indexOf('出嗣') >= 0 ||
      a.indexOf('过继自') === 0 || a.indexOf('继与') >= 0;
  }

  /** 过继/出嗣句 */
  private static adoptionSentence(p: Person, idx: DieJiIndex): string {
    const adopt: string = p.adoption.trim().replace(/。$/, '');
    if (adopt.length === 0 || !DieJiText.isOutAdoption(p)) {
      return '';
    }
    const father: Person | null = idx.fatherOf(p);
    if (father !== null && father.name.trim().length > 0) {
      return '原系' + father.name.trim() + '公' + DieJiText.childOrdinal(p, idx) + '，' + adopt + '。';
    }
    return adopt + '。';
  }

  /** 乏嗣而以他人子为嗣：乏嗣，以兄…为嗣。 */
  private static heirByAdoptionSentence(p: Person, idx: DieJiIndex): string {
    const adopt: string = p.adoption.trim().replace(/。$/, '');
    if (adopt.length === 0 || DieJiText.isOutAdoption(p)) {
      return '';
    }
    if (idx.childrenOf(p.uid).length > 0) {
      return '';
    }
    return '乏嗣，' + adopt + '。';
  }

  /** 本支人物（含未婚女子） */
  private static personParagraph(p: Person, idx: DieJiIndex, opts?: DieJiRefOptions): string {
    const dead: boolean = DieJiText.isDead(p);
    const age: number = ageOf(p.birthDate, p.deathDate, p.lifeStatus);
    const young: boolean = dead && age >= 0 && age <= 15 && p.spouses.length === 0 &&
      idx.childrenOf(p.uid).length === 0;
    const s: string[] = [];
    s.push(DieJiText.headSentence(p, idx, opts));
    const adopt: string = DieJiText.adoptionSentence(p, idx);
    if (adopt.length > 0) {
      s.push(adopt);
    }
    s.push(DieJiText.lifeSentence(p, young));
    const career: string = DieJiText.careerSentence(p);
    if (career.length > 0) {
      s.push(career);
    }
    // 生不立传：在世者只记齿录，不写生平赞语
    if (p.lifeStatus !== '在世' && p.biography.trim().length > 0) {
      s.push(p.biography.trim().replace(/。$/, '') + '。');
    }
    const heir: string[] = DieJiText.heirSentences(p, idx);
    for (let i: number = 0; i < heir.length; i++) {
      s.push(heir[i]);
    }
    const spouse: string[] = DieJiText.spouseSentences(p, idx, opts);
    for (let i: number = 0; i < spouse.length; i++) {
      s.push(spouse[i]);
    }
    const kids: string = DieJiText.childrenSentence(p, idx, opts);
    if (kids.length > 0) {
      s.push(kids);
    }
    const heirAdopt: string = DieJiText.heirByAdoptionSentence(p, idx);
    if (heirAdopt.length > 0) {
      s.push(heirAdopt);
    }
    const grave: string = DieJiText.graveSentence(p, idx);
    if (grave.length > 0) {
      s.push(grave);
    }
    return s.join('');
  }

  /** 妣氏条目 */
  private static wifeParagraph(p: Person, husband: Person, idx: DieJiIndex,
    opts?: DieJiRefOptions): string {
    const dead: boolean = DieJiText.isDead(p);
    const age: number = ageOf(p.birthDate, p.deathDate, p.lifeStatus);
    const young: boolean = dead && age >= 0 && age <= 15 && idx.childrenOf(p.uid).length === 0;
    const s: string[] = [];
    s.push(DieJiText.wifeHeadSentence(p, husband, idx, opts));
    s.push(DieJiText.lifeSentence(p, young));
    const career: string = DieJiText.careerSentence(p);
    if (career.length > 0) {
      s.push(career);
    }
    if (p.lifeStatus !== '在世' && p.biography.trim().length > 0) {
      s.push(p.biography.trim().replace(/。$/, '') + '。');
    }
    if (idx.childrenOf(p.uid).length === 0 && dead) {
      const adopt: string = p.adoption.trim().replace(/。$/, '');
      if (adopt.length > 0) {
        s.push(adopt.indexOf('为嗣') >= 0 || adopt.indexOf('以') === 0 ?
          '乏嗣，' + adopt + '。' : '无嗣。');
      } else if (idx.childrenOf(husband.uid).length === 0) {
        // 旧谱常只记父子不记母子：丈夫名下有子女时不轻易断言妻子「无嗣」
        s.push('无嗣。');
      }
    } else {
      const kids: string = DieJiText.childrenSentence(p, idx, opts);
      if (kids.length > 0) {
        s.push(kids);
      }
      const heirAdopt: string = DieJiText.heirByAdoptionSentence(p, idx);
      if (heirAdopt.length > 0) {
        s.push(heirAdopt);
      }
    }
    const grave: string = DieJiText.graveSentence(p, idx);
    if (grave.length > 0) {
      s.push(grave);
    }
    return s.join('');
  }
}

