import { fileIo, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Person, SpouseRelation, spouseRelationLevel, childStatusLabel } from '../model/Person';
import { Genealogy } from '../model/Genealogy';
import { GenealogyService } from './GenealogyService';
import { csvEscape } from '../util/StringUtil';
import { generationLabel } from '../model/Enums';
import { parseYear } from '../util/DateUtil';

/**
 * 导入导出服务：JSON 全量备份、JSON 公开分享（脱敏）、CSV 表格、Markdown 谱文。
 */
export class ExportService {

  /** Excel 表头（与《关键信息字段》字段名称一致） */
  private static readonly HEADERS: string[] = [
    '世代', '唯一ID', '谱名', '曾用名/小名', '性别', '辈分/字派', '在世状态', '子女身份',
    '出生日期', '逝世日期', '出生地', '现居地', '父亲ID', '母亲ID', '配偶关系', '排行', '过继/出嗣',
    '学历/学位', '职业/职务', '生平简介', '墓葬信息', '手机号', '微信号', '头像'
  ];

  private static fieldOf(p: Person, label: string): string {
    switch (label) {
      case '世代': return p.generation.toString();
      case '唯一ID': return p.uid;
      case '谱名': return p.name;
      case '曾用名/小名': return p.alias;
      case '性别': return p.gender;
      case '辈分/字派': return p.generationChar;
      case '在世状态': return p.lifeStatus;
      case '子女身份': return p.childStatus === '未记' ? '' : p.childStatus;
      case '出生日期': return p.birthCalendar === '农历' ? '农历 ' + p.birthDate : p.birthDate;
      case '逝世日期': return p.deathCalendar === '农历' ? '农历 ' + p.deathDate : p.deathDate;
      case '出生地': return p.birthPlace;
      case '现居地': return p.residence;
      case '父亲ID': return p.fatherId;
      case '母亲ID': return p.motherId;
      case '配偶关系': return ExportService.spousesText(p);
      case '排行': return p.rank;
      case '过继/出嗣': return p.adoption;
      case '学历/学位': return p.education;
      case '职业/职务': return p.occupation;
      case '生平简介': return p.biography;
      case '墓葬信息': return p.graveInfo;
      case '手机号': return p.phone;
      case '微信号': return p.wechat;
      case '头像': return p.avatar;
      default: return '';
    }
  }

  /** 生成 CSV 文本 */
  static toCsv(people: Person[], includePrivate: boolean): string {
    const lines: string[] = [];
    lines.push(ExportService.HEADERS.map((h: string): string => csvEscape(h)).join(','));
    people.forEach((p: Person): void => {
      const row: string[] = [];
      ExportService.HEADERS.forEach((h: string): void => {
        if (!includePrivate && (h === '手机号' || h === '微信号')) {
          row.push(csvEscape(''));
        } else {
          row.push(csvEscape(ExportService.fieldOf(p, h)));
        }
      });
      lines.push(row.join(','));
    });
    return lines.join('\r\n');
  }

  /** 生成 JSON 备份 */
  static toJson(people: Person[], book: Genealogy, includePrivate: boolean): string {
    const rows: Record<string, string | number>[] = [];
    people.forEach((p: Person): void => {
      const r: Record<string, string | number> = {
        '世代': p.generation,
        '唯一ID': p.uid,
        '谱名': p.name,
        '曾用名/小名': p.alias,
        '性别': p.gender,
        '辈分/字派': p.generationChar,
        '在世状态': p.lifeStatus,
        '子女身份': p.childStatus,
        '出生日期': p.birthCalendar === '农历' ? '农历 ' + p.birthDate : p.birthDate,
        '逝世日期': p.deathCalendar === '农历' ? '农历 ' + p.deathDate : p.deathDate,
        '出生地': p.birthPlace,
        '现居地': p.residence,
        '父亲ID': p.fatherId,
        '母亲ID': p.motherId,
        '配偶ID': p.spouseId,
        '配偶关系': ExportService.spousesText(p),
        '排行': p.rank,
        '过继/出嗣': p.adoption,
        '学历/学位': p.education,
        '职业/职务': p.occupation,
        '生平简介': p.biography,
        '墓葬信息': p.graveInfo,
        '墓葬经度': p.graveLng,
        '墓葬纬度': p.graveLat,
        '墓葬海拔': p.graveAltitude,
        '手机号': includePrivate ? p.phone : '',
        '微信号': includePrivate ? p.wechat : '',
        '头像': p.avatar,
        '视频': p.videos,
        '相片': p.photos
      };
      rows.push(r);
    });
    const bookObj: Record<string, string> = {
      '谱名': book.title,
      '姓氏': book.surname,
      '堂号': book.hallName,
      '郡望': book.junwang,
      '始迁祖': book.ancestorName,
      '字派': book.generationPoem,
      '谱序': book.preface,
      '家训': book.familyRules,
      '凡例': book.editingNotes
    };
    const payload: Record<string, Object> = {
      'format': 'hongmeng-genealogy',
      'version': 1,
      'exportedAt': new Date().toISOString(),
      'book': bookObj,
      'people': rows
    };
    return JSON.stringify(payload, null, 2);
  }

  /** 生成牒记式 Markdown 谱文 */
  static toMarkdown(people: Person[], book: Genealogy): string {
    const lines: string[] = [];
    lines.push('# ' + book.title);
    if (book.hallName.length > 0) {
      lines.push('');
      lines.push('> ' + book.hallName + ' · ' + book.junwang);
    }
    lines.push('');
    lines.push('## 谱序');
    lines.push('');
    lines.push(book.preface);
    lines.push('');
    lines.push('## 世系');
    lines.push('');
    const sorted: Person[] = people.slice().sort((a: Person, b: Person): number => {
      if (a.generation !== b.generation) {
        return a.generation - b.generation;
      }
      return a.uid.localeCompare(b.uid);
    });
    let lastGen: number = -1;
    sorted.forEach((p: Person): void => {
      if (p.generation !== lastGen) {
        lastGen = p.generation;
        lines.push('');
        lines.push('### ' + generationLabel(p.generation));
        lines.push('');
      }
      const by: number = parseYear(p.birthDate);
      const dy: number = parseYear(p.deathDate);
      let text: string = '**' + p.name + '**（' + p.uid + '）';
      if (p.gender === '女') {
        text = text + '，女';
      }
      if (p.rank.length > 0) {
        text = text + '，' + p.rank;
      }
      if (p.childStatus.length > 0 && p.childStatus !== '未记') {
        text = text + '，' + childStatusLabel(p.childStatus, p.gender);
      }
      const spText: string = ExportService.spouseMarkdown(p, people);
      if (spText.length > 0) {
        text = text + '，' + spText;
      }
      if (p.generationChar.length > 0) {
        text = text + '，字派“' + p.generationChar + '”';
      }
      if (by > 0) {
        text = text + '，' + by + '年生';
      }
      if (dy > 0) {
        text = text + '，' + dy + '年卒';
      }
      if (p.birthPlace.length > 0) {
        text = text + '，籍' + p.birthPlace;
      }
      if (p.education.length > 0) {
        text = text + '，' + p.education;
      }
      if (p.occupation.length > 0) {
        text = text + '，' + p.occupation;
      }
      text = text + '。';
      if (p.biography.length > 0) {
        text = text + p.biography;
      }
      lines.push('- ' + text);
    });
    lines.push('');
    lines.push('## 家训');
    lines.push('');
    lines.push(book.familyRules);
    return lines.join('\n');
  }

  /** 弹出保存对话框并写入文件 */
  static async saveAsFile(context: common.UIAbilityContext, fileName: string, content: string): Promise<void> {
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    options.fileSuffixChoices = [fileName.substring(fileName.lastIndexOf('.'))];
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.save(options);
    if (uris.length === 0) {
      return;
    }
    const file: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
      | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, content);
    fileIo.closeSync(file);
  }

  /** 选择文件并读取文本 */
  static async pickFileText(context: common.UIAbilityContext, suffix: string[]): Promise<string> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = suffix;
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.select(options);
    if (uris.length === 0) {
      return '';
    }
    const file: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
    const stat: fileIo.Stat = fileIo.statSync(file.fd);
    const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    fileIo.readSync(file.fd, buffer);
    fileIo.closeSync(file);
    const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
    return decoder.decodeToString(new Uint8Array(buffer));
  }

  /** 解析 JSON 备份为人物列表 */
  static parseJson(text: string): Person[] {
    const result: Person[] = [];
    if (!text || text.trim().length === 0) {
      return result;
    }
    const data: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
    const arr: Object[] = data['people'] as Object[];
    if (arr === undefined || arr === null) {
      return result;
    }
    arr.forEach((obj: Object): void => {
      const r: Record<string, string> = obj as Record<string, string>;
      const p: Person = new Person();
      p.generation = parseInt(r['世代'] === undefined ? '1' : r['世代'], 10);
      if (isNaN(p.generation)) {
        p.generation = 1;
      }
      p.uid = r['唯一ID'] ?? '';
      p.name = r['谱名'] ?? '';
      p.alias = r['曾用名/小名'] ?? '';
      p.gender = r['性别'] ?? '男';
      p.generationChar = r['辈分/字派'] ?? '';
      p.lifeStatus = r['在世状态'] ?? '在世';
      p.childStatus = r['子女身份'] ?? '未记';
      p.birthDate = r['出生日期'] ?? '';
      p.deathDate = r['逝世日期'] ?? '';
      p.birthPlace = r['出生地'] ?? '';
      p.residence = r['现居地'] ?? '';
      p.fatherId = r['父亲ID'] ?? '';
      p.motherId = r['母亲ID'] ?? '';
      p.spouseId = r['配偶ID'] ?? '';
      p.spouses = ExportService.parseSpouses(r['配偶关系'] ?? '', p.gender);
      ExportService.finalizeSpouses(p);
      p.rank = r['排行'] ?? '';
      p.adoption = r['过继/出嗣'] ?? '';
      p.education = r['学历/学位'] ?? '';
      p.occupation = r['职业/职务'] ?? '';
      p.biography = r['生平简介'] ?? '';
      p.graveInfo = r['墓葬信息'] ?? '';
      p.phone = r['手机号'] ?? '';
      p.wechat = r['微信号'] ?? '';
      p.avatar = r['头像'] ?? '';
      p.videos = r['视频'] ?? '';
      p.photos = r['相片'] ?? '';
      result.push(p);
    });
    return result;
  }

  /** 简易 CSV 解析（支持双引号转义） */
  static parseCsv(text: string): Person[] {
    const result: Person[] = [];
    const rows: string[][] = ExportService.splitCsv(text);
    if (rows.length < 2) {
      return result;
    }
    const header: string[] = rows[0].map((h: string): string => h.trim());
    for (let i: number = 1; i < rows.length; i++) {
      const cells: string[] = rows[i];
      if (cells.length === 0 || cells.every((c: string): boolean => c.trim().length === 0)) {
        continue;
      }
      const p: Person = new Person();
      for (let c: number = 0; c < header.length && c < cells.length; c++) {
        const value: string = cells[c].trim();
        switch (header[c]) {
          case '世代': p.generation = parseInt(value, 10) || 1; break;
          case '唯一ID': p.uid = value; break;
          case '谱名': p.name = value; break;
          case '曾用名/小名': p.alias = value; break;
          case '性别': p.gender = value.length > 0 ? value : '男'; break;
          case '辈分/字派': p.generationChar = value; break;
          case '在世状态': p.lifeStatus = value.length > 0 ? value : '在世'; break;
          case '子女身份': p.childStatus = value.length > 0 ? value : '未记'; break;
          case '出生日期':
            p.birthCalendar = value.indexOf('农历') >= 0 ? '农历' : '公历';
            p.birthDate = value.replace('农历', '').trim();
            break;
          case '逝世日期':
            p.deathCalendar = value.indexOf('农历') >= 0 ? '农历' : '公历';
            p.deathDate = value.replace('农历', '').trim();
            break;
          case '出生地': p.birthPlace = value; break;
          case '现居地': p.residence = value; break;
          case '父亲ID': p.fatherId = value; break;
          case '母亲ID': p.motherId = value; break;
          case '配偶ID': p.spouseId = value; break;
          case '配偶关系': p.spouses = ExportService.parseSpouses(value, p.gender); break;
          case '排行': p.rank = value; break;
          case '过继/出嗣': p.adoption = value; break;
          case '学历/学位': p.education = value; break;
          case '职业/职务': p.occupation = value; break;
          case '生平简介': p.biography = value; break;
          case '墓葬信息': p.graveInfo = value; break;
          case '手机号': p.phone = value; break;
          case '微信号': p.wechat = value; break;
          case '头像': p.avatar = value; break;
          default: break;
        }
      }
      if (p.name.length > 0) {
        ExportService.finalizeSpouses(p);
        result.push(p);
      }
    }
    return result;
  }

  /** 配偶关系序列化：`UID:名分;UID:名分`（兼容旧 spouseId 单值） */
  private static spousesText(p: Person): string {
    const parts: string[] = [];
    p.spouses.forEach((r: SpouseRelation): void => {
      const id: string = r.uid.trim();
      if (id.length > 0) {
        parts.push(id + ':' + (r.relation.trim().length > 0 ? r.relation.trim() : '未记'));
      }
    });
    if (parts.length === 0 && p.spouseId.trim().length > 0) {
      parts.push(p.spouseId.trim() + ':未记');
    }
    return parts.join(';');
  }

  /** 解析配偶关系文本，支持中文分号/冒号，也支持只填 UID */
  private static parseSpouses(value: string, gender: string): SpouseRelation[] {
    const list: SpouseRelation[] = [];
    if (value === undefined || value.trim().length === 0) {
      return list;
    }
    const src: string = value.replace(/；/g, ';').replace(/：/g, ':');
    const items: string[] = src.split(';');
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < items.length; i++) {
      const item: string = items[i].trim();
      if (item.length === 0) {
        continue;
      }
      const idx: number = item.indexOf(':');
      const id: string = (idx >= 0 ? item.substring(0, idx) : item).trim().toUpperCase();
      if (id.length === 0 || seen.has(id)) {
        continue;
      }
      seen.add(id);
      const rel: string = idx >= 0 ? item.substring(idx + 1).trim() : '';
      const r: SpouseRelation = new SpouseRelation();
      r.uid = id;
      r.relation = rel.length > 0 ? rel : (gender === '女' ? '夫' : '未记');
      r.level = spouseRelationLevel(r.relation);
      r.order = list.length + 1;
      list.push(r);
    }
    return list;
  }

  /** 归一化：无配偶关系但有旧 spouseId 时补齐；spouseId 同步为主配偶 */
  private static finalizeSpouses(p: Person): void {
    if (p.spouses.length === 0 && p.spouseId.trim().length > 0) {
      const r: SpouseRelation = new SpouseRelation();
      r.uid = p.spouseId.trim().toUpperCase();
      r.relation = p.gender === '女' ? '夫' : '元配';
      r.level = spouseRelationLevel(r.relation);
      r.order = 1;
      p.spouses = [r];
    }
    p.spouseId = p.spouses.length > 0 ? p.spouses[0].uid : '';
  }

  /** Markdown 谱文中的配偶描述（名分 + 姓名） */
  private static spouseMarkdown(p: Person, people: Person[]): string {
    if (p.spouses.length === 0) {
      return '';
    }
    const parts: string[] = [];
    p.spouses.forEach((r: SpouseRelation): void => {
      let name: string = r.uid;
      for (let i: number = 0; i < people.length; i++) {
        if (people[i].uid.trim().toUpperCase() === r.uid.trim().toUpperCase()) {
          name = people[i].name;
          break;
        }
      }
      const prefix: string = (r.relation === '元配' || r.relation === '未记' || r.relation === '配偶') ?
        '配' : r.relation;
      parts.push(prefix + name);
    });
    return parts.join('、');
  }

  private static splitCsv(text: string): string[][] {
    const rows: string[][] = [];
    let row: string[] = [];
    let cell: string = '';
    let inQuote: boolean = false;
    const src: string = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    // 去掉 BOM，兼容 Excel 导出的 UTF-8 BOM
    const body: string = src.charCodeAt(0) === 0xFEFF ? src.substring(1) : src;
    for (let i: number = 0; i < body.length; i++) {
      const ch: string = body.charAt(i);
      if (inQuote) {
        if (ch === '"') {
          if (i + 1 < body.length && body.charAt(i + 1) === '"') {
            cell = cell + '"';
            i++;
          } else {
            inQuote = false;
          }
        } else {
          cell = cell + ch;
        }
      } else if (ch === '"') {
        inQuote = true;
      } else if (ch === ',') {
        row.push(cell);
        cell = '';
      } else if (ch === '\n') {
        row.push(cell);
        rows.push(row);
        row = [];
        cell = '';
      } else {
        cell = cell + ch;
      }
    }
    if (cell.length > 0 || row.length > 0) {
      row.push(cell);
      rows.push(row);
    }
    return rows;
  }

  /** 写临时文件（导出前可预览） */
  static async writeTemp(context: common.Context, fileName: string, content: string): Promise<string> {
    const dir: string = context.filesDir + '/exports';
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir);
    }
    const path: string = dir + '/' + fileName;
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
      | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, content);
    fileIo.closeSync(file);
    return path;
  }

  static toast(msg: string): void {
    try {
      
    } catch (e) {
      const err = e as BusinessError;
      console.error('toast failed ' + err.message);
    }
  }
}