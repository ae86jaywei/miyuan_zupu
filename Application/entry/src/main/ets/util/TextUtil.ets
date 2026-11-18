/**
 * 文本工具：中文数字、姓氏拆分、籍贯简称。
 * 与牒记文案解耦，供页面、服务、导出共用，避免各处在 DieJiText 内重复实现。
 */

/** 复姓表：牒记「李氏」「欧阳氏」取姓时用 */
const COMPOUND_SURNAMES: string[] = ['欧阳', '太史', '端木', '上官', '司马', '东方', '独孤', '南宫', '万俟',
  '闻人', '夏侯', '诸葛', '尉迟', '公羊', '赫连', '澹台', '皇甫', '宗政', '濮阳', '公冶', '太叔', '申屠',
  '公孙', '慕容', '仲孙', '钟离', '长孙', '宇文', '司徒', '鲜于', '司空', '闾丘', '子车', '亓官', '司寇',
  '巫马', '公西', '颛孙', '壤驷', '公良', '漆雕', '乐正', '宰父', '谷梁', '拓跋', '夹谷', '轩辕', '令狐',
  '段干', '百里', '呼延', '东郭', '南门', '羊舌', '微生', '公户', '公玉', '公仪', '梁丘', '公仲', '公上',
  '公门', '公山', '公坚', '左丘', '公伯', '西门', '公祖', '第五', '公乘', '贯丘', '公皙', '南荣', '东里',
  '东宫', '仲长', '子书', '子桑', '即墨', '达奚', '褚师'];

export const CN_DIGITS: string[] = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];

/** 中文数字（1~99 足够族谱使用） */
export function cnNum(n: number): string {
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

/** 姓（含复姓） */
export function surnameOf(name: string): string {
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
export function givenNameOf(name: string): string {
  const n: string = name.trim();
  const s: string = surnameOf(n);
  let given: string = n.substring(s.length);
  if (given.endsWith('氏')) {
    given = given.substring(0, given.length - 1);
  }
  return given;
}

/** 至少三字时取姓+氏，否则原样 */
export function clanName(name: string): string {
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
export function shortPlace(place: string): string {
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