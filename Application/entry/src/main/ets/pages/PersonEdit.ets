import { T, uiFontFamily } from 'common_base';
import { SR } from '../service/ServiceRegistry';

import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { geoLocationManager } from '@kit.LocationKit';
import { sensor } from '@kit.SensorServiceKit';
import { picker } from '@kit.CoreFileKit';
import { Theme, Spacing, Radius } from 'common_base';
import { BackButton } from 'common_ui';
import { SelectField } from 'common_ui';
import { PersonPickerField } from 'common_ui';
import { DateFieldInput } from 'common_ui';
import { PersonFieldForm } from 'common_ui';
import { Breakpoint } from 'common_base';
import { Person, SpouseRelation, createEmptyPerson, clonePerson, cloneSpouseRelation, SPOUSE_RELATIONS, spouseRelationLabel, spouseRelationHint, spouseRelationLevel, normalizeSpouseRelation, childRankOfSpouseRelation, childStatusLabel, childStatusHint, CONCUBINE_CHILD_TITLE_HINT } from 'common_base';
import { GenealogyService } from '../service/GenealogyService';
import { GenealogyStore } from '../store/GenealogyStore';
import { FamilyService } from '../service/FamilyService';
import { EditParams } from 'common_base';
import { IdGenerator } from 'common_base';
import { CALENDAR_OPTIONS, CLAN_RANK_OPTIONS, NATAL_RANK_OPTIONS,
  MARRIAGE_OPTIONS_FEMALE, MARRIAGE_OPTIONS_MALE, GENERATION_LABELS, GENERATION_KEYS, generationLabel } from 'common_base';
import { isBlank } from 'common_base';
import { fieldMetaOf, PARENT_LIFE_STATUS_OPTIONS } from 'common_base';
import { parseDate, ParsedDate, parseHistoricalDate, composeDate, ERA_LIST, eraLabel, eraYearCount } from 'common_dateutil';
import { cnYearText, huangLiText, HuangLi, julianDay, LunarMonthOption, lunarMonthsOfYear, lunarMonthDays, lunarToSolar, SolarDate } from 'common_dateutil';
import { eraYearText, lunarDayName, lunarMonthName, solarToLunar, LunarDate } from 'common_dateutil';
import { CoordParseResult, DateMath, GraveCoordParser, NumTextUtil, PersonMediaUtil } from './personedit/PersonEditUtils';
import { FormLabel, FormToggleRow, GroupHeaderRow, NumberFieldRow } from './personedit/FormWidgets';
import { SpouseSection } from './personedit/SpouseSection';
import { PreviewItem, SidePreview } from './personedit/SidePreview';
import { EraPickerPanel } from './personedit/EraPickerPanel';

/** 第一世（始祖）的排行称谓 */
const ANCESTOR_RANK: string = '第一世（始祖）';

/**
 * 人物编辑页：覆盖《关键信息字段_20261023.xlsx》全部字段，
 * 宽屏双栏（表单 + 实时族谱预览），窄屏单栏。
 */
@Entry
@Component
struct PersonEdit {
  @StorageProp('windowWidth') windowWidth: number = 360;
  @StorageProp('windowHeight') windowHeight: number = 780;
  @State mode: string = 'edit';
  @State originalUid: string = '';
  @State loading: boolean = true;
  @State saving: boolean = false;
  /** 进入页面时的表单快照：返回时据此判断是否有未保存修改 */
  private baseline: string = '';
  /** 姻亲判定缓存：build 每次重绘都要用，避免按配偶反复查人 */
  private natalKey: string = '';
  private natalValue: boolean = false;

  // 字段状态
  @State fGeneration: number = 1;
  @State fUid: string = '';
  /** 唯一ID 是否为自动生成（自动生成的会在切换性别时重新计算） */
  @State uidAuto: boolean = true;
  @State fName: string = '';
  @State fCourtesyName: string = '';
  @State fArtName: string = '';
  @State fAlias: string = '';
  @State fGender: string = '男';
  @State fGenChar: string = '';
  @State fLifeStatus: string = '在世';
  @State fChildStatus: string = '未记';
  @State fChildMark: string = '未记';
  @State fChildMarkTarget: string = '';
  @State fChildMarkSource: string = '';
  @State fChildMarkSeq: number = 0;
  @State fChildless: boolean = false;
  @State fBirthDate: string = '';
  @State fBirthCalendar: string = '公历';
  @State fDeathDate: string = '';
  @State fDeathCalendar: string = '公历';
  @State fBirthPlace: string = '';
  @State fResidence: string = '';
  @State fFatherId: string = '';
  @State fFatherName: string = '';
  /** 父名（未收录）在世状态：已故者牒记称「吴公忠伟」 */
  @State fFatherLifeStatus: string = '在世';
  @State fMotherId: string = '';
  @State fMotherName: string = '';
  @State fMotherLifeStatus: string = '在世';
  /** 配偶关系（可多位：元配 / 继室 / 妾） */
  @State fSpouses: SpouseRelation[] = [];
  /** 婚配状态：未记/未字/未娶/适人/娶妻/招赘/不详 */
  @State fMarriageStatus: string = '未记';
  /** 夫家/婆家/入赘对象（配偶未收录时填写） */
  @State fSpouseFamily: string = '';
  @State fRank: string = '';
  @State fAdoption: string = '';
  @State fEducation: string = '';
  @State fOccupation: string = '';
  @State fBiography: string = '';
  @State fGraveInfo: string = '';
  @State fGraveLng: number = 0;
  @State fGraveLat: number = 0;
  @State fGraveAltitude: number = 0;
  /** 地图分享链接 / 地图定位信息文本（用于解析经纬度与海拔，不落库） */
  @State fGraveMapInfo: string = '';
  /** 地图链接解析结果提示 */
  @State mapHint: string = '';
  @State fPhone: string = '';
  @State fWechat: string = '';
  @State fAvatar: string = '';
  @State fPhotos: string = '';
  @State fVideos: string = '';
  @State errorMsg: string = '';
  /** 是否处于深色模式（深色下把“选中态”反转为浅色底+深色字，避免白底白字） */
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }
  @State isDark: boolean = false;
  /** 定位/图片相关临时状态 */
  @State locating: boolean = false;
  // ---------------- 历史日期选择面板状态 ----------------
  @State showDatePicker: boolean = false;
  @State dateTargetLabel: string = '';
  @State dateCalendar: string = '公历';
  /** 当前编辑的日期字段标识：'birth' | 'death'，回填时按标识写回对应字段 */
  @State dateTarget: string = 'birth';
  @State pickYear: number = 1900;
  @State pickMonth: number = 1;
  @State pickDay: number = 1;
  /** 农历模式下是否选择闰月 */
  @State pickLeap: boolean = false;
  @State yearIndex: number = 200;
  /** 年份下限（与年号表最早纪年一致：天福元年） */
  private readonly MIN_YEAR: number = 936;
  private readonly MAX_YEAR: number = 2100;
  @State monthIndex: number = 0;
  @State dayIndex: number = 0;
  @State yearOptions: string[] = [];
  /** 古历法记年：年号选择（空串表示直接选公历年） */
  @State eraOptions: string[] = ['公历年'];
  @State eraIndex: number = 0;
  @State eraYear: number = 1;
  @State eraYearIndex: number = 0;
  @State useEra: boolean = false;
  @State monthOptions: string[] = ['1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月', '10月', '11月', '12月'];
  @State dayOptions: string[] = [];
  /** 跳转指定日期输入：年 / 月 / 日 */
  @State jumpYear: string = '';
  @State jumpMonth: string = '';
  @State jumpDay: string = '';
  /** 纪年（年号）选择弹窗是否展开 */
  @State showEraPicker: boolean = false;
  @State mediaNote: string = '';

  onPageShow(): void {
    this.refreshDarkMode();
  }

  /** 从系统配置刷新深浅色（切换后回到本页立即生效） */
  private refreshDarkMode(): void {
    try {
      const host: Context | undefined = this.getUIContext().getHostContext();
      if (host !== undefined && host.resourceManager !== undefined) {
        const dark: boolean = host.resourceManager.getConfigurationSync().colorMode ===
          resourceManager.ColorMode.DARK;
        AppStorage.setOrCreate<boolean>('darkMode', dark);
        this.darkMode = dark;
      }
    } catch (e) {
      // 忽略
    }
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    try {
      const host: Context | undefined = this.getUIContext().getHostContext();
      if (host !== undefined && host.resourceManager !== undefined) {
        // resourceManager.ColorMode.DARK === 0（与 Ability 常量数值一致，避免类型冲突）
        this.isDark = host.resourceManager.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK;
      }
    } catch (e) {
      this.isDark = false;
    }
    const params: EditParams | undefined = this.getUIContext().getRouter().getParams() as EditParams;
    if (params !== undefined) {
      this.mode = params.mode;
      this.originalUid = params.uid;
      this.loadPerson(params);
    } else {
      this.loadPerson({ mode: 'create', uid: '', presetParent: '' });
    }
  }

  private svc(): GenealogyService {
    return SR.genealogy();
  }

  private loadPerson(params: EditParams): void {
    const svc: GenealogyService = this.svc();
    let p: Person = createEmptyPerson();
    if (params.mode === 'edit' && params.uid.length > 0) {
      const exist: Person | null = svc.getPerson(params.uid);
      if (exist !== null) {
        p = clonePerson(exist);
      }
    } else if (params.mode === 'child' && params.presetParent.length > 0) {
      // 新增子女：继承父母的世代与字派
      const parent: Person | null = svc.getPerson(params.presetParent);
      if (parent !== null) {
        p.generation = parent.generation + 1;
        const parentSpouse: string = parent.spouses.length > 0 ? parent.spouses[0].uid : '';
        if (parent.gender === '男') {
          p.fatherId = parent.uid;
          p.motherId = parentSpouse;
        } else {
          p.motherId = parent.uid;
          p.spouseId = '';
          p.fatherId = parentSpouse;
        }
        const chars: string[] = this.poemChars();
        const idx: number = p.generation - 1;
        if (idx >= 0 && idx < chars.length) {
          p.generationChar = chars[idx];
        }
      }
    } else if (params.mode === 'create') {
      const maxGen: number = this.maxGeneration();
      p.generation = maxGen > 0 ? maxGen + 1 : 1;
    }
    this.fill(p);
    this.loading = false;
  }

  private poemChars(): string[] {
    const poem: string = this.svc().getBook().generationPoem;
    return poem.split(/[，,、\s]+/).join('').split('');
  }

  private maxGeneration(): number {
    let m: number = 0;
    this.svc().getPeople().forEach((p: Person): void => {
      if (p.generation > m) {
        m = p.generation;
      }
    });
    return m;
  }

  /**
   * 是否为姻亲（娶回来的妻妾 / 入赘）：本人没有本族父亲，但配偶是本族子女。
   * 姻亲的「排行」表示娘家排行，不能写死「第一世（始祖）」。
   */
  private isNatalOutsider(): boolean {
    let key: string = this.fFatherId.trim().toUpperCase();
    for (let i: number = 0; i < this.fSpouses.length; i++) {
      key = key + '|' + this.fSpouses[i].uid.trim().toUpperCase();
    }
    if (key === this.natalKey) {
      return this.natalValue;
    }
    let result: boolean = false;
    if (this.fFatherId.trim().length === 0) {
      for (let i: number = 0; i < this.fSpouses.length; i++) {
        const id: string = this.fSpouses[i].uid.trim().toUpperCase();
        if (id.length === 0) {
          continue;
        }
        const sp: Person | null = this.svc().getPerson(id);
        if (sp !== null && sp.fatherId.trim().length > 0) {
          result = true;
          break;
        }
      }
    }
    this.natalKey = key;
    this.natalValue = result;
    return result;
  }

  /** 娘家排行候选：按性别只留子/女排行，去掉随母子/随母女 */
  private natalRankOptions(): string[] {
    const list: string[] = [];
    for (let i: number = 0; i < NATAL_RANK_OPTIONS.length; i++) {
      const r: string = NATAL_RANK_OPTIONS[i];
      if (this.fGender === '女' && r.indexOf('子') >= 0) {
        continue;
      }
      if (this.fGender === '男' && r.indexOf('女') >= 0) {
        continue;
      }
      list.push(r);
    }
    return list;
  }

  /**
   * 加载排行：姻亲用娘家排行；本族第一世固定“始祖”；排行只允许子/女排行。
   * 历史数据把“正妻/侧室”等名分误写进排行（女性尤其常见）时直接清空：
   * 身份与排行不是一个意思，只有用户手动选择排行才保留。
   */
  private normalizeRank(p: Person): string {
    if (this.isNatalOutsider()) {
      const natal: string = p.rank.trim();
      return natal.length > 0 && natal !== ANCESTOR_RANK ? natal : '';
    }
    if (p.generation === 1) {
      return ANCESTOR_RANK;
    }
    const rank: string = p.rank.trim();
    if (rank.length === 0 || rank === ANCESTOR_RANK) {
      return '';
    }
    return CLAN_RANK_OPTIONS.indexOf(rank) >= 0 ? rank : '';
  }

  private fill(p: Person): void {
    this.fGeneration = p.generation;
    // 新增时留空，等选择性别后再生成（编辑时保留原 ID）
    this.fUid = p.uid;
    this.uidAuto = p.uid.trim().length === 0;
    this.fName = p.name;
    this.fCourtesyName = p.courtesyName;
    this.fArtName = p.artName;
    this.fAlias = p.alias;
    this.fGender = p.gender;
    this.fGenChar = p.generationChar;
    this.fLifeStatus = p.lifeStatus;
    this.fChildStatus = p.childStatus.length > 0 ? p.childStatus : '未记';
    this.fChildMark = p.childMark.length > 0 ? p.childMark : '未记';
    this.fChildMarkTarget = p.childMarkTarget;
    this.fChildMarkSource = p.childMarkSource;
    this.fChildMarkSeq = p.childMarkSeq;
    this.fChildless = p.childless;
    this.fBirthDate = p.birthDate;
    this.fBirthCalendar = p.birthCalendar;
    this.fDeathDate = p.deathDate;
    this.fDeathCalendar = p.deathCalendar;
    this.fBirthPlace = p.birthPlace;
    this.fResidence = p.residence;
    this.fFatherId = p.fatherId;
    this.fFatherName = p.fatherName;
    this.fFatherLifeStatus = p.fatherLifeStatus.length > 0 ? p.fatherLifeStatus : '在世';
    this.fMotherId = p.motherId;
    this.fMotherName = p.motherName;
    this.fMotherLifeStatus = p.motherLifeStatus.length > 0 ? p.motherLifeStatus : '在世';
    this.fSpouses = p.spouses.map((r: SpouseRelation): SpouseRelation => {
      const c: SpouseRelation = cloneSpouseRelation(r);
      // 历史数据可能把等级写进称谓（如“夫（侧室）”），统一回“夫”，
      // 配偶栏只显示“夫 姓名”，本人身份在“身份”字段单独展示。
      c.relation = normalizeSpouseRelation(c.relation);
      c.level = spouseRelationLevel(c.relation);
      return c;
    });
    this.fMarriageStatus = p.marriageStatus.length > 0 ? p.marriageStatus : '未记';
    this.fSpouseFamily = p.spouseFamily;
    this.fRank = this.normalizeRank(p);
    this.fAdoption = p.adoption;
    this.fEducation = p.education;
    this.fOccupation = p.occupation;
    this.fBiography = p.biography;
    this.fGraveInfo = p.graveInfo;
    this.fGraveLng = p.graveLng;
    this.fGraveLat = p.graveLat;
    this.fGraveAltitude = p.graveAltitude;
    this.fGraveMapInfo = '';
    this.mapHint = '';
    this.fPhone = p.phone;
    this.fWechat = p.wechat;
    this.fAvatar = p.avatar;
    this.fPhotos = p.photos;
    this.fVideos = p.videos;
    // 加载完成后记录基线；之后返回时据此判断是否有未保存修改
    this.baseline = this.formSnapshot();
  }

  private toPerson(): Person {
    const p: Person = createEmptyPerson();
    const exist: Person | null = this.originalUid.length > 0 ? this.svc().getPerson(this.originalUid) : null;
    if (exist !== null) {
      p.key = exist.key;
      p.createdAt = exist.createdAt;
    }
    p.generation = this.fGeneration;
    p.uid = this.fUid.trim().toUpperCase();
    p.name = this.fName.trim();
    p.courtesyName = this.fCourtesyName.trim();
    p.artName = this.fArtName.trim();
    p.alias = this.fAlias;
    p.gender = this.fGender;
    p.generationChar = this.fGenChar;
    p.lifeStatus = this.fLifeStatus;
    p.childStatus = this.fChildStatus;
    p.childMark = this.fChildMark;
    p.childMarkTarget = this.fChildMarkTarget;
    p.childMarkSource = this.fChildMarkSource;
    p.childMarkSeq = this.fChildMarkSeq;
    p.childless = this.fChildless;
    p.birthDate = this.fBirthDate;
    p.birthCalendar = this.fBirthCalendar;
    p.deathDate = this.fDeathDate;
    p.deathCalendar = this.fDeathCalendar;
    p.birthPlace = this.fBirthPlace;
    p.residence = this.fResidence;
    p.fatherId = this.fFatherId;
    p.fatherName = this.fFatherName.trim();
    p.fatherLifeStatus = this.fFatherLifeStatus;
    p.motherId = this.fMotherId;
    p.motherName = this.fMotherName.trim();
    p.motherLifeStatus = this.fMotherLifeStatus;
    p.spouses = this.buildSpouses();
    p.spouseId = p.spouses.length > 0 ? p.spouses[0].uid : '';
    p.marriageStatus = this.fMarriageStatus === '未记' ? '' : this.fMarriageStatus;
    p.spouseFamily = this.showSpouseFamily() ? this.fSpouseFamily.trim() : '';
    p.rank = this.fRank;
    p.adoption = this.fAdoption;
    p.education = this.fEducation;
    p.occupation = this.fOccupation;
    p.biography = this.fBiography;
    p.graveInfo = this.fGraveInfo;
    p.graveLng = this.fGraveLng;
    p.graveLat = this.fGraveLat;
    p.graveAltitude = this.fGraveAltitude;
    p.phone = this.fPhone;
    p.wechat = this.fWechat;
    p.avatar = this.fAvatar;
    p.photos = this.fPhotos;
    p.videos = this.fVideos;
    p.updatedAt = Date.now();
    return p;
  }

  private validate(): string {
    if (isBlank(this.fName)) {
      return '请填写谱名';
    }
    if (this.fBiography.length > 500) {
      return '生平简介不能超过 500 字（当前 ' + this.fBiography.length.toString() + ' 字）';
    }
    // 新增且未填 ID：保存时按性别自动生成，此处跳过校验
    const uidText: string = this.fUid.trim();
    if (uidText.length > 0 && !IdGenerator.isUnique(this.svc().getPeople(), uidText, this.originalUid)) {
      return '唯一ID“' + uidText + '”已被占用，请更换';
    }
    const by: number = parseDate(this.fBirthDate);
    const dy: number = parseDate(this.fDeathDate);
    if (by > 0 && dy > 0 && dy < by) {
      return '逝世日期不能早于出生日期';
    }
    if (uidText.length > 0 && (this.fFatherId.trim().toUpperCase() === uidText.toUpperCase()
      || this.fMotherId.trim().toUpperCase() === uidText.toUpperCase())) {
      return '父亲/母亲ID不能与本人的唯一ID相同';
    }
    if (this.fFatherId.length > 0 && this.svc().getPerson(this.fFatherId) === null) {
      return '父亲ID“' + this.fFatherId + '”不存在，请先录入';
    }
    if (this.fMotherId.length > 0 && this.svc().getPerson(this.fMotherId) === null) {
      return '母亲ID“' + this.fMotherId + '”不存在，请先录入';
    }
    const ownUid: string = this.fUid.trim().toUpperCase();
    const spouseIds: Set<string> = new Set<string>();
    for (let i: number = 0; i < this.fSpouses.length; i++) {
      const id: string = this.fSpouses[i].uid.trim().toUpperCase();
      if (id.length === 0) {
        continue;
      }
      if (id === ownUid) {
        return '配偶不能是本人';
      }
      if (spouseIds.has(id)) {
        return '配偶“' + id + '”重复，请只保留一条';
      }
      spouseIds.add(id);
      if (this.svc().getPerson(id) === null) {
        return '配偶ID“' + id + '”不存在，请先录入';
      }
    }
    return '';
  }

  /** 归一化配偶列表：去空值、统一大写、补齐次序 */
  private buildSpouses(): SpouseRelation[] {
    const list: SpouseRelation[] = [];
    this.fSpouses.forEach((r: SpouseRelation): void => {
      const id: string = r.uid.trim().toUpperCase();
      if (id.length === 0) {
        return;
      }
      const nr: SpouseRelation = new SpouseRelation();
      nr.uid = id;
      nr.relation = r.relation.trim().length > 0 ? r.relation.trim() : '未记';
      nr.level = spouseRelationLevel(nr.relation);
      nr.order = list.length + 1;
      list.push(nr);
    });
    return list;
  }

  private updateSpouse(index: number, uid: string, relation: string): void {
    const list: SpouseRelation[] = [];
    this.fSpouses.forEach((r: SpouseRelation, i: number): void => {
      const nr: SpouseRelation = cloneSpouseRelation(r);
      if (i === index) {
        nr.uid = uid;
        nr.relation = relation;
        nr.level = spouseRelationLevel(relation);
      }
      list.push(nr);
    });
    this.fSpouses = list;
  }

  private addSpouse(): void {
    const rel: SpouseRelation = new SpouseRelation();
    rel.relation = this.fGender === '女' ? '夫' : (this.fSpouses.length === 0 ? '元配' : '侧室');
    rel.level = spouseRelationLevel(rel.relation);
    let maxOrder: number = 0;
    this.fSpouses.forEach((r: SpouseRelation): void => {
      if (r.order > maxOrder) {
        maxOrder = r.order;
      }
    });
    rel.order = maxOrder + 1;
    const list: SpouseRelation[] = this.fSpouses.slice();
    list.push(rel);
    this.fSpouses = list;
  }

  private removeSpouse(index: number): void {
    const list: SpouseRelation[] = this.fSpouses.slice();
    list.splice(index, 1);
    this.fSpouses = list;
  }

  /** 配偶预览文案（含名分与姓名） */
  private spousesPreview(): string {
    const parts: string[] = [];
    this.buildSpouses().forEach((r: SpouseRelation): void => {
      const p: Person | null = this.svc().getPerson(r.uid);
      const nameText: string = p === null ? r.uid : p.name + '（' + p.uid + '）';
      parts.push(spouseRelationLabel(r.relation) + '：' + nameText);
    });
    return parts.length === 0 ? '未选择' : parts.join('；');
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.errorMsg = this.validate();
    if (this.errorMsg.length > 0) {
      return;
    }
    const p: Person = this.toPerson();
    const uid: string = p.uid.trim().toUpperCase();
    const original: string = this.originalUid.trim().toUpperCase();
    const retiredName: string = this.svc().retiredNameOf(uid);
    if (retiredName.length > 0 && original !== uid) {
      // 编号曾被已删除族人使用：继续沿用会让云端遗留关系指向当前族人
      this.getUIContext().showAlertDialog({
        title: T('该编号曾用于已删除族人'),
        message: T('编号“') + uid + '”曾属于已删除的“' + retiredName + '”。\n\n' +
          '继续使用该编号时，云端仍保留的旧父母/配偶关系可能被挂到当前族人身上，' +
          '合并后世系图会出现重复、重叠或多出宗支。\n\n建议取消后更换编号（留空可由系统自动分配）。',
        primaryButton: {
          value: T('取消改号'),
          action: (): void => {
          }
        },
        secondaryButton: {
          value: T('仍然保存'),
          fontColor: Theme.primary,
          action: async (): Promise<void> => {
            await this.doSave(p);
          }
        }
      });
      return;
    }
    await this.doSave(p);
  }

  private async doSave(p: Person): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      if (this.originalUid.length > 0) {
        // 协作：保存前先留一份快照，用于生成字段级 diff（审核页展示旧值 → 新值）
        this.svc().captureBefore(this.originalUid);
        await this.svc().updatePerson(p, this.originalUid);
      } else {
        await this.svc().addPerson(p);
      }
      GenealogyStore.notifyChanged();
      // 保存成功：更新基线，避免返回时再次提示未保存
      this.baseline = this.formSnapshot();
      // 协作态下说明这次修改的去向：已同步 / 已提交审核 / 离线待传
      this.getUIContext().getPromptAction().showToast({ message: T(this.saveHint()) });
      this.getUIContext().getRouter().back();
    } catch (e) {
      const err = e as BusinessError;
      this.errorMsg = '保存失败：' + err.message;
    } finally {
      this.saving = false;
    }
  }

  /** 保存后的去向提示（方案 §十 P1 提交—审核 / §十三 三条门槛） */
  private saveHint(): string {
    const mode: string = SR.family().syncMode();
    if (mode === 'LOCAL') {
      return '已保存（本谱仅在本机）';
    }
    if (mode === 'CLOUD_PENDING') {
      return '已保存；本谱尚未发布到云端，稍后在「我的家族」发布';
    }
    if (!SR.family().canEditCurrent()) {
      return '已保存到本机；当前角色为只读，未提交云端';
    }
    if (SR.family().isOwnerCurrent()) {
      return '已保存并同步到云端';
    }
    return '已提交，等谱主审核后合入';
  }

  /** 当前表单快照：只拼接可编辑字段，避免把加载状态/提示计入脏检查 */
  private formSnapshot(): string {
    const parts: string[] = [
      this.mode, this.fGeneration.toString(), this.fUid, this.fName, this.fCourtesyName,
      this.fArtName, this.fAlias, this.fGender, this.fGenChar, this.fLifeStatus,
      this.fChildStatus, this.fChildMark, this.fChildMarkTarget, this.fChildMarkSource,
      this.fChildMarkSeq.toString(), this.fChildless ? '1' : '0',
      this.fBirthDate, this.fBirthCalendar, this.fDeathDate, this.fDeathCalendar,
      this.fBirthPlace, this.fResidence,
      this.fFatherId, this.fFatherName, this.fFatherLifeStatus,
      this.fMotherId, this.fMotherName, this.fMotherLifeStatus,
      this.fRank, this.fAdoption, this.fEducation, this.fOccupation, this.fBiography,
      this.fMarriageStatus, this.fSpouseFamily,
      this.fGraveInfo, this.fGraveLng.toString(), this.fGraveLat.toString(),
      this.fGraveAltitude.toString(), this.fPhone, this.fWechat,
      this.fAvatar, this.fPhotos, this.fVideos
    ];
    for (let i: number = 0; i < this.fSpouses.length; i = i + 1) {
      const r: SpouseRelation = this.fSpouses[i];
      parts.push(r.uid + '|' + r.relation + '|' + r.level + '|' + r.order.toString());
    }
    return parts.join('\u0001');
  }

  private isDirty(): boolean {
    return this.baseline.length > 0 && this.formSnapshot() !== this.baseline;
  }

  /** 返回前确认：有未保存修改时让用户选择保存或放弃 */
  private confirmExit(): void {
    if (this.loading || !this.isDirty()) {
      this.getUIContext().getRouter().back();
      return;
    }
    this.getUIContext().showAlertDialog({
      title: T('未保存的修改'),
      message: T('当前修改尚未保存，是否保存后再离开？'),
      primaryButton: {
        value: T('保存'),
        action: (): void => {
          this.save();
        }
      },
      secondaryButton: {
        value: T('不保存'),
        fontColor: Theme.danger,
        action: (): void => {
          this.getUIContext().getRouter().back();
        }
      }
    });
  }

  onBackPress(): boolean {
    if (this.loading || !this.isDirty()) {
      return false;
    }
    this.confirmExit();
    return true;
  }

  private async remove(): Promise<void> {
    if (this.originalUid.length === 0) {
      return;
    }
    const children: Person[] = this.svc().childrenOf(this.originalUid);
    const tip: string = children.length > 0 ?
      '该人物有 ' + children.length.toString() + ' 位子女，删除后子女将变为“无父/无母”状态。确认删除？' : '确认删除该人物？';
    this.getUIContext().showAlertDialog({
      title: T('删除人物'),
      message: T(tip),
      primaryButton: {
        value: T('取消'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: T('删除'),
        fontColor: Theme.danger,
        action: (): void => {
          this.svc().deletePerson(this.originalUid)
            .then((): void => {
              GenealogyStore.notifyChanged();
              this.getUIContext().getPromptAction().showToast({ message: T('已删除') });
              this.getUIContext().getRouter().back();
            })
            .catch((err: BusinessError): void => {
              this.getUIContext().getPromptAction().showToast({ message: T('删除失败：') + err.message });
            });
        }
      }
    });
  }

  // ---------------------------------------------------------------- 图片与定位

  private async pickAvatar(): Promise<void> {
    try {
      const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result: photoAccessHelper.PhotoSelectResult = await photoPicker.select(options);
      if (result.photoUris.length > 0) {
        this.fAvatar = result.photoUris[0];
      }
    } catch (e) {
      const err = e as BusinessError;
      this.getUIContext().getPromptAction().showToast({ message: T('选择头像失败：') + err.message });
    }
  }

  /** 照片/视频列表（photos 字段以“;”分隔存储图片与视频 URI） */
  private photoList(): string[] {
    return PersonMediaUtil.listOf(this.fPhotos);
  }

  private isVideoUri(uri: string): boolean {
    return PersonMediaUtil.isVideoUri(uri);
  }

  private appendPhotos(uris: string[]): void {
    this.fPhotos = PersonMediaUtil.append(this.fPhotos, uris);
  }

  private removePhotoAt(index: number): void {
    this.fPhotos = PersonMediaUtil.removeAt(this.fPhotos, index);
  }

  /** “+” 添加来源选择：系统图库 / 文件管理器 */
  private showMediaSourceDialog(): void {
    this.getUIContext().showAlertDialog({
      title: T('添加照片/视频'),
      message: T('请选择添加来源'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: T('系统图库'),
        action: (): void => {
          this.pickPhotos();
        }
      },
      secondaryButton: {
        value: T('文件管理器'),
        action: (): void => {
          this.pickMediaFiles();
        }
      }
    });
  }

  private async pickPhotos(): Promise<void> {
    try {
      const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
      options.maxSelectNumber = 9;
      const result: photoAccessHelper.PhotoSelectResult = await photoPicker.select(options);
      this.appendPhotos(result.photoUris);
    } catch (e) {
      const err = e as BusinessError;
      this.getUIContext().getPromptAction().showToast({ message: T('选择相片失败：') + err.message });
    }
  }

  /** 从文件管理器选择图片/视频 */
  private async pickMediaFiles(): Promise<void> {
    try {
      const host: Context | undefined = this.getUIContext().getHostContext();
      if (host === undefined) {
        return;
      }
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(host);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 9;
      options.fileSuffixFilters = [
        '图片(.png, .jpg, .jpeg, .gif, .webp)|.png,.jpg,.jpeg,.gif,.webp',
        '视频(.mp4, .mov, .m4v, .3gp)|.mp4,.mov,.m4v,.3gp'
      ];
      const uris: string[] = await docPicker.select(options);
      this.appendPhotos(uris);
    } catch (e) {
      const err = e as BusinessError;
      this.getUIContext().getPromptAction().showToast({ message: T('选择文件失败：') + err.message });
    }
  }

  /** 海拔获取最大尝试次数（含首次） */
  private static readonly ALTITUDE_RETRY_MAX: number = 3;
  /** 两次定位尝试之间的间隔（毫秒） */
  private static readonly ALTITUDE_RETRY_DELAY: number = 1000;
  /** 气压计单次读取超时（毫秒） */
  private static readonly BAROMETER_TIMEOUT: number = 3000;

  /** 拾取当前位置作为墓葬GPS（经纬度 + 海拔；海拔缺失时重试，仍失败则回退气压计估算） */
  private async pickGraveLocation(): Promise<void> {
    if (this.locating) {
      return;
    }
    this.locating = true;
    try {
      if (!geoLocationManager.isLocationEnabled()) {
        this.getUIContext().getPromptAction().showToast({ message: T('系统定位未开启，请先打开“位置信息”开关') });
        return;
      }
      let alt: number = NaN;
      let lastMsg: string = '';
      for (let attempt = 0; attempt < PersonEdit.ALTITUDE_RETRY_MAX; attempt++) {
        let fatal: boolean = false;
        try {
          // 高精度 + 导航场景才能拿到 GNSS 高程（FIRST_FIX 通常只有网络定位，无海拔）
          const location: geoLocationManager.Location = await geoLocationManager.getCurrentLocation({
            priority: geoLocationManager.LocationRequestPriority.ACCURACY,
            scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
            maxAccuracy: 50,
            timeoutMs: 10000
          });
          this.fGraveLng = location.longitude;
          this.fGraveLat = location.latitude;
          alt = location.altitude;
          if (!isNaN(alt) && alt !== 0) {
            break;
          }
          lastMsg = '定位结果不含海拔';
        } catch (e) {
          const err = e as BusinessError;
          lastMsg = err.message;
          if (err.code === 201) {
            lastMsg = '未获得定位权限，请在设置中允许';
            fatal = true;
          } else if (err.code === 3301100) {
            lastMsg = '系统定位服务未开启';
            fatal = true;
          }
        }
        // 权限/服务类错误重试无意义，直接退出
        if (fatal || attempt === PersonEdit.ALTITUDE_RETRY_MAX - 1) {
          break;
        }
        await this.delay(PersonEdit.ALTITUDE_RETRY_DELAY);
      }

      if (!isNaN(alt) && alt !== 0) {
        this.fGraveAltitude = alt;
        this.getUIContext().getPromptAction().showToast({ message: T('已拾取当前位置（含海拔）') });
        return;
      }
      if (this.fGraveLat === 0 && this.fGraveLng === 0) {
        this.getUIContext().getPromptAction()
          .showToast({ message: T('定位失败（') + lastMsg + '），可手工填写经纬度' });
        return;
      }
      // 重试后仍无海拔：若设备带气压计则用气压换算海拔
      const baroAlt: number = await this.readAltitudeByBarometer();
      if (!isNaN(baroAlt)) {
        this.fGraveAltitude = baroAlt;
        this.getUIContext().getPromptAction()
          .showToast({ message: T('已拾取经纬度，海拔由气压计估算（') + baroAlt.toFixed(1) + ' 米）' });
      } else {
        this.getUIContext().getPromptAction()
          .showToast({ message: T('已拾取经纬度，海拔暂不可用，请到空旷处重试或手工填写') });
      }
    } finally {
      this.locating = false;
    }
  }

  /** 延时等待 */
  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }

  /** 通过气压计换算海拔（米）；设备不支持气压计或读取失败时返回 NaN */
  private async readAltitudeByBarometer(): Promise<number> {
    try {
      const sensors: sensor.Sensor[] = await sensor.getSensorList();
      let supported: boolean = false;
      for (let i = 0; i < sensors.length; i++) {
        if (sensors[i].sensorId === sensor.SensorId.BAROMETER) {
          supported = true;
          break;
        }
      }
      if (!supported) {
        return NaN;
      }
      const pressure: number = await this.readBarometerPressure();
      if (isNaN(pressure) || pressure <= 0) {
        return NaN;
      }
      // 正常海平面气压约 1013 hPa，超过 2000 视为按 Pa 上报，统一换算为 hPa
      const hPa: number = pressure > 2000 ? pressure / 100 : pressure;
      // 国际标准大气压公式：h = 44330 × (1 - (P / P0) ^ (1 / 5.255))
      const standardPressure: number = 1013.25;
      return 44330 * (1 - Math.pow(hPa / standardPressure, 1 / 5.255));
    } catch (e) {
      return NaN;
    }
  }

  /** 读取一次气压计数据（hPa），超时未上报则返回 NaN */
  private readBarometerPressure(): Promise<number> {
    return new Promise<number>((resolve: (value: number) => void): void => {
      let finished: boolean = false;
      const finish = (value: number): void => {
        if (finished) {
          return;
        }
        finished = true;
        resolve(value);
      };
      try {
        sensor.once(sensor.SensorId.BAROMETER, (data: sensor.BarometerResponse): void => {
          finish(data.pressure);
        });
      } catch (e) {
        finish(NaN);
        return;
      }
      setTimeout((): void => {
        finish(NaN);
      }, PersonEdit.BAROMETER_TIMEOUT);
    });
  }

  /** 解析地图分享链接 / 定位信息文本，写入经纬度与海拔 */
  private applyMapInfo(text: string): void {
    this.fGraveMapInfo = text;
    this.mapHint = this.parseCoordinateText(text);
  }

  private parseCoordinateText(text: string): string {
    const result: CoordParseResult = GraveCoordParser.parse(text);
    if (!result.ok) {
      return result.hint;
    }
    this.fGraveLat = result.lat;
    this.fGraveLng = result.lng;
    if (!isNaN(result.alt) && result.alt !== 0) {
      this.fGraveAltitude = result.alt;
    }
    return result.hint;
  }

  /** 拉起系统“地图应用选择器”，由用户在已安装的地图应用中选择 */
  private launchMapApp(): void {
    const host: Context | undefined = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    if (this.fGraveLat === 0 && this.fGraveLng === 0) {
      this.getUIContext().getPromptAction()
        .showToast({ message: T('请先拾取当前位置，或粘贴地图分享链接解析出坐标') });
      return;
    }
    const param: Record<string, Object> = {
      'sceneType': 1,
      'destinationLatitude': this.fGraveLat,
      'destinationLongitude': this.fGraveLng,
      'destinationName': this.fName.length > 0 ? this.fName + '之墓' : '墓葬位置',
      'vehicleType': 0
    };
    const startCallback: common.AbilityStartCallback = {
      onError: (code: number, name: string, message: string): void => {
        this.getUIContext().getPromptAction().showToast({ message: T('打开地图失败：') + message });
      }
    };
    const ctx: common.UIAbilityContext = host as common.UIAbilityContext;
    ctx.startAbilityByType('navigation', param, startCallback, (err: BusinessError): void => {
      if (err) {
        this.getUIContext().getPromptAction().showToast({ message: T('打开地图失败：') + err.message });
      }
    });
  }

  // ---------------------------------------------------------------- 下拉滑动选择

  private generationOptions(): string[] {
    return GENERATION_LABELS;
  }

  /** 世代候选对应的数值键：文案是“第十世”等中文，必须用键回传数值，否则解析不出世代 */
  private generationKeys(): string[] {
    return GENERATION_KEYS;
  }

  /** 排行候选：姻亲用娘家排行；本族第一世只有“第一世（始祖）”，其余为子/女排行 */
  private rankOptions(): string[] {
    if (this.isNatalOutsider()) {
      return this.natalRankOptions();
    }
    if (this.fGeneration === 1) {
      return [ANCESTOR_RANK];
    }
    return CLAN_RANK_OPTIONS;
  }

  /** 婚配状态候选：按性别区分未字/未娶、适人/娶妻 */
  private marriageOptions(): string[] {
    if (this.fGender === '女') {
      return MARRIAGE_OPTIONS_FEMALE;
    }
    return MARRIAGE_OPTIONS_MALE;
  }

  /** 选了适人/娶妻/招赘，才显示夫家/婆家输入 */
  private showSpouseFamily(): boolean {
    return this.fMarriageStatus === '适人' || this.fMarriageStatus === '娶妻' ||
      this.fMarriageStatus === '招赘';
  }

  private genCharOptions(): string[] {
    const chars: string[] = this.poemChars();
    const extra: string[] = this.svc().generationChars();
    const merged: string[] = [];
    chars.forEach((c: string): void => {
      if (merged.indexOf(c) < 0) {
        merged.push(c);
      }
    });
    extra.forEach((c: string): void => {
      if (merged.indexOf(c) < 0) {
        merged.push(c);
      }
    });
    return merged;
  }

  /** 庶出 / 婢生 / 奸生 需提示“嫡母为母亲、生母称姨娘”的礼法称谓 */
  private isConcubineChild(): boolean {
    return this.fChildStatus === '庶出' || this.fChildStatus === '婢生' || this.fChildStatus === '奸生';
  }

  private assignValue(mode: string, value: string): void {
    switch (mode) {
      case 'generation': {
        const g: number = parseInt(value, 10);
        // 解析失败时保留原世代，绝不回落到第一世
        if (isNaN(g) || g <= 0) {
          break;
        }
        this.fGeneration = g;
        // 姻亲的排行是娘家排行，不随世代写死为“第一世（始祖）”
        if (this.fGeneration === 1 && !this.isNatalOutsider()) {
          this.fRank = ANCESTOR_RANK;
        } else if (this.fRank === ANCESTOR_RANK) {
          this.fRank = '';
        }
        break;
      }
      case 'gender': {
        this.fGender = value;
        // 婚配状态选项随性别变化（未字/适人 ↔ 未娶/娶妻），切换后回到未记
        this.fMarriageStatus = '未记';
        this.fSpouseFamily = '';
        // 新增且 ID 仍为自动生成 → 按新性别重新计算（男 F / 女 M）
        if (this.originalUid.length === 0 && this.uidAuto) {
          this.fUid = this.svc().nextUid(value);
        }
        break;
      }
      case 'genChar':
        this.fGenChar = value;
        break;
      case 'lifeStatus':
        this.fLifeStatus = value;
        break;
      case 'childStatus':
        this.fChildStatus = value;
        break;
      case 'childMark':
        this.fChildMark = value;
        break;
      case 'birthCalendar':
        this.fBirthCalendar = value;
        break;
      case 'deathCalendar':
        this.fDeathCalendar = value;
        break;
      case 'rank':
        this.fRank = value;
        break;
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- 构建


  /**
   * 打开历史日期选择面板。
   *
   * 历史族谱常见“光绪三十一年”“民国二十九年”等纪年，系统日期选择器最早只到 1970，
   * 因此这里自绘“年 / 月 / 日”三段滚轮，范围 936 ~ 2100，覆盖清朝及更早祖先。
   */
  private openDatePicker(label: string, calendar: string, value: string): void {
    let year: number = 0;
    let month: number = 0;
    let day: number = 0;
    // 新版保存的文本同时含农历与公历，必须按当前历法取对应段，避免把农历月日当成公历
    if (calendar === '公历') {
      const full: RegExpMatchArray | null = value.match(/公历\s*(\d{3,4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日/);
      if (full !== null) {
        year = parseInt(full[1], 10);
        month = parseInt(full[2], 10);
        day = parseInt(full[3], 10);
      } else {
        const ymd: RegExpMatchArray | null = value.match(/(\d{3,4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})/);
        if (ymd !== null) {
          year = parseInt(ymd[1], 10);
          month = parseInt(ymd[2], 10);
          day = parseInt(ymd[3], 10);
        }
      }
    }
    if (year <= 0) {
      const parsed: ParsedDate = parseHistoricalDate(value);
      year = parsed.year;
      month = parsed.month;
      day = parsed.day;
    }
    this.dateTargetLabel = label;
    this.dateCalendar = calendar;
    // 通过字段名区分出生/逝世，避免保存函数引用到状态变量
    this.dateTarget = label.indexOf('逝世') >= 0 ? 'death' : 'birth';
    this.pickYear = year > 0 ? year : 1900;
    this.pickMonth = month > 0 ? month : 1;
    this.pickDay = day > 0 ? day : 1;
    // 原文含“闰”时还原为闰月
    this.pickLeap = calendar === '农历' && value.indexOf('闰') >= 0;
    this.buildEraOptions();
    this.eraIndex = 0;
    this.useEra = false;
    this.eraYear = 1;
    this.eraYearIndex = 0;
    this.refreshDateOptions();
    this.showDatePicker = true;
  }

  /** 年号列表（第 0 项为“公历年”） */
  private buildEraOptions(): void {
    if (this.eraOptions.length > 1) {
      return;
    }
    const list: string[] = ['公历年'];
    for (let i: number = 0; i < ERA_LIST.length; i++) {
      list.push(eraLabel(i));
    }
    this.eraOptions = list;
  }

  /** 某个年号可选的年数（按到下一个年号或 2100 年计算） */
  private eraYearOptions(): string[] {
    const list: string[] = [];
    if (this.eraIndex <= 0 || this.eraIndex > ERA_LIST.length) {
      return ['元年'];
    }
    const max: number = eraYearCount(this.eraIndex - 1);
    for (let i: number = 1; i <= max; i++) {
      list.push(i === 1 ? '元年' : this.numToCn(i) + '年');
    }
    return list;
  }

  /** 阿拉伯数字转中文（1~99） */
  private numToCn(n: number): string {
    return NumTextUtil.toCn(n);
  }

  private refreshDateOptions(): void {
    const years: string[] = [];
    // 与年号表最早的天福元年（936）对齐，保证纪年与公历可选范围一致
    // 农历模式按传统写法逐位读年：1900 → 一九零零年
    const lunarMode: boolean = this.dateCalendar === '农历';
    for (let y: number = this.MAX_YEAR; y >= this.MIN_YEAR; y--) {
      years.push(lunarMode ? cnYearText(y) + '年' : y.toString() + '年');
    }
    this.yearOptions = years;
    this.pickYear = Math.min(Math.max(this.pickYear, this.MIN_YEAR), this.MAX_YEAR);
    this.buildMonthOptions();
    this.syncMonthSelection();
    this.syncDayOptions();
    this.yearIndex = this.MAX_YEAR - this.pickYear;
    this.dayIndex = Math.max(this.pickDay - 1, 0);
  }

  private daysInMonth(year: number, month: number, isLeap: boolean): number {
    return DateMath.daysInMonth(year, month, isLeap, this.dateCalendar === '农历');
  }

  /** 按公历/农历生成月份选项（农历含闰月） */
  private buildMonthOptions(): void {
    if (this.dateCalendar === '农历') {
      const months: LunarMonthOption[] = lunarMonthsOfYear(this.pickYear);
      const list: string[] = [];
      for (let i: number = 0; i < months.length; i++) {
        list.push(months[i].label);
      }
      this.monthOptions = list.length > 0 ? list : ['正月'];
    } else {
      const m: string[] = [];
      for (let i: number = 1; i <= 12; i++) {
        m.push(i.toString() + '月');
      }
      this.monthOptions = m;
    }
  }

  /** 让 monthIndex 与 pickMonth / pickLeap 保持一致 */
  private syncMonthSelection(): void {
    if (this.dateCalendar === '农历') {
      const months: LunarMonthOption[] = lunarMonthsOfYear(this.pickYear);
      if (months.length === 0) {
        this.monthIndex = 0;
        return;
      }
      let idx: number = 0;
      for (let i: number = 0; i < months.length; i++) {
        if (months[i].month === this.pickMonth && months[i].isLeap === this.pickLeap) {
          idx = i;
          break;
        }
      }
      this.monthIndex = idx;
      this.pickMonth = months[idx].month;
      this.pickLeap = months[idx].isLeap;
    } else {
      this.pickMonth = Math.min(Math.max(this.pickMonth, 1), 12);
      this.pickLeap = false;
      this.monthIndex = this.pickMonth - 1;
    }
  }

  private syncDayOptions(): void {
    const days: string[] = [];
    const max: number = this.daysInMonth(this.pickYear, this.pickMonth, this.pickLeap);
    // 切换年 / 月后日期可能超出当月天数，这里同步收敛，避免生成 2 月 31 日这类非法日期
    if (this.pickDay > max) {
      this.pickDay = max;
    }
    if (this.pickDay < 1) {
      this.pickDay = 1;
    }
    if (this.dayIndex > max - 1) {
      this.dayIndex = max - 1;
    }
    const lunar: string[] = ['初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十',
      '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
      '廿一', '廿二', '廿三', '廿四', '廿五', '廿六', '廿七', '廿八', '廿九', '三十'];
    for (let d: number = 1; d <= max; d++) {
      // 农历按传统写法：初一…三十
      days.push(this.dateCalendar === '农历' ? lunar[d - 1] : d.toString() + '日');
    }
    this.dayOptions = days;
  }

  /**
   * 生成写回个人信息的完整生卒日期文本（年号 + 干支 + 农历 + 公历）。
   * 例：弘治六年 癸丑年甲寅月丙子日 农历一四九三年正月初十（公历1493年1月27日）
   * 没有年号的日期（936 前 / 1949-10-01 后）只省略年号段。
   */
  private fullDateText(y: number, m: number, d: number): string {
    const solarText: string = '公历' + y.toString() + '年' + m.toString() + '月' + d.toString() + '日';
    const lunar: LunarDate | null = solarToLunar(y, m, d);
    const hl: HuangLi = huangLiText(y, m, d, -1);
    const eraText: string = eraYearText(y, m, d);
    let text: string = eraText.length > 0 ? eraText + ' ' : '';
    text = text + hl.year + hl.month + hl.day;
    if (lunar !== null) {
      // 农历段保留农历年，跨公历年（腊月）回填时才能定位到正确的农历年
      text = text + ' 农历' + cnYearText(lunar.year) + '年' + lunarMonthName(lunar.month, lunar.isLeap) +
        lunarDayName(lunar.day);
    }
    return text + '（' + solarText + '）';
  }

  /** 选择器当前组合将要写入个人信息的完整日期文本 */
  private previewDateText(): string {
    if (this.dateCalendar === '农历') {
      const solar: SolarDate | null = lunarToSolar(this.pickYear, this.pickMonth, this.pickDay, this.pickLeap);
      if (solar !== null) {
        return this.fullDateText(solar.year, solar.month, solar.day);
      }
    } else {
      // 1582 年 10 月 5~14 日不存在，直接写公历年月日，避免生成矛盾的农历/干支
      const missingDay: boolean = this.pickYear === 1582 && this.pickMonth === 10 &&
        this.pickDay >= 5 && this.pickDay <= 14;
      if (!missingDay) {
        return this.fullDateText(this.pickYear, this.pickMonth, this.pickDay);
      }
    }
    return composeDate(this.pickYear, this.pickMonth, this.pickDay, this.dateCalendar, this.pickLeap);
  }

  /** 确认日期：直接按目标字段写回（不依赖函数型状态） */
  private confirmDate(): void {
    const text: string = this.previewDateText();
    if (text.length > 0) {
      if (this.dateTarget === 'death') {
        this.fDeathDate = text;
      } else {
        this.fBirthDate = text;
      }
    }
    this.showDatePicker = false;
  }

  /** 跳到指定日期：解析年/月/日输入并同步到三段滚轮 */
  private jumpToDate(): void {
    const y: number = parseInt(this.jumpYear, 10);
    const m: number = parseInt(this.jumpMonth, 10);
    const d: number = parseInt(this.jumpDay, 10);
    if (isNaN(y) || isNaN(m) || isNaN(d)) {
      this.getUIContext().getPromptAction().showToast({ message: T('请输入有效的年 / 月 / 日') });
      return;
    }
    if (y < this.MIN_YEAR || y > this.MAX_YEAR) {
      this.getUIContext().getPromptAction().showToast({
        message: T('年份范围 ' + this.MIN_YEAR.toString() + '~' + this.MAX_YEAR.toString() + ' 年')
      });
      return;
    }
    if (m < 1 || m > 12) {
      this.getUIContext().getPromptAction().showToast({ message: T('月份需在 1~12 之间') });
      return;
    }
    const maxDay: number = this.dateCalendar === '农历' ?
      lunarMonthDays(y, m, false) : this.daysInMonth(y, m, false);
    if (d < 1 || d > maxDay) {
      this.getUIContext().getPromptAction().showToast({ message: T('该月只有 ' + maxDay.toString() + ' 天') });
      return;
    }
    this.pickYear = y;
    this.pickMonth = m;
    this.pickDay = d;
    this.pickLeap = false;
    // 手动跳到某个公历年即退出年号联动
    this.eraIndex = 0;
    this.useEra = false;
    this.refreshDateOptions();
  }

  /** 选定年号（纪年弹窗回调）：换算为对应公历年并重建日期选项 */
  private selectEra(index: number): void {
    this.eraIndex = index;
    this.useEra = index > 0;
    if (this.useEra) {
      this.eraYear = 1;
      this.eraYearIndex = 0;
      this.pickYear = ERA_LIST[index - 1].firstYear;
      this.refreshDateOptions();
    }
  }

  /** 当前所选日期对应的干支黄历 */
  private huangLi(): HuangLi {
    if (this.dateCalendar === '农历') {
      const solar: SolarDate | null = lunarToSolar(this.pickYear, this.pickMonth, this.pickDay, this.pickLeap);
      if (solar !== null) {
        return huangLiText(solar.year, solar.month, solar.day, -1);
      }
    }
    const y: number = Math.max(this.pickYear, 1);
    return huangLiText(y, this.pickMonth, this.pickDay, -1);
  }

  /** 日期滚轮高度：横屏等矮窗口下压缩，避免日期面板超出屏幕 */
  private pickerHeight(): number {
    return this.windowHeight > 0 && this.windowHeight < 520 ? 120 : 220;
  }

  /** 历史日期选择面板：年 / 月 / 日 三段滚轮 */
  @Builder
  DatePickerPanel() {
    Column() {
      Row() {
        Text(T('取消')).fontFamily(uiFontFamily())
          .fontSize(15)
          .fontColor(Theme.inkTertiary)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
          .onClick((): void => {
            this.showDatePicker = false;
          })
        Text(T(this.dateTargetLabel)).fontFamily(uiFontFamily())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(2)
          .textAlign(TextAlign.Center)
        Text(T('确定')).fontFamily(uiFontFamily())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.primary)
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .onClick((): void => {
            this.confirmDate();
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: Spacing.L, right: Spacing.L })

      // 当前组合预览：即将写入个人信息的“年号 + 干支 + 农历 + 公历”完整文本
      Column() {
        Text(T(this.previewDateText())).fontFamily(uiFontFamily())
          .fontSize(13.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.primary)
          .maxLines(3)
          .textAlign(TextAlign.Center)
        Text(T('节气：' + this.huangLi().term)).fontFamily(uiFontFamily())
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Center)
      .margin({ bottom: 4 })

      // 跳到指定日期：直接输入年月日快速定位，免去滚动上千年的年份滚轮
      Row() {
        Text(T('跳到指定日期')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
          .width(78)
        TextInput({ text: this.jumpYear, placeholder: T('年') })
          .height(34)
          .layoutWeight(3)
          .fontSize(13)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .onChange((v: string): void => {
            this.jumpYear = v;
          })
        TextInput({ text: this.jumpMonth, placeholder: T('月') })
          .height(34)
          .layoutWeight(2)
          .fontSize(13)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .margin({ left: 6 })
          .onChange((v: string): void => {
            this.jumpMonth = v;
          })
        TextInput({ text: this.jumpDay, placeholder: T('日') })
          .height(34)
          .layoutWeight(2)
          .fontSize(13)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .margin({ left: 6 })
          .onChange((v: string): void => {
            this.jumpDay = v;
          })
        Button(T('跳转')).fontFamily(uiFontFamily())
          .height(34)
          .fontSize(13)
          .fontColor(Theme.onPrimary)
          .backgroundColor(Theme.primary)
          .borderRadius(8)
          .margin({ left: 8 })
          .onClick((): void => {
            this.jumpToDate();
          })
      }
      .width('100%')
      .padding({ left: Spacing.M, right: Spacing.M, top: 2, bottom: 2 })

      // 古历法记年：先选年号，再选第几年；选择后自动换算公历年
      Row() {
        Text(T('纪年')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
          .margin({ right: Spacing.S })
        Row() {
          Text(T(this.eraIndex === 0 ? '公历年' : this.eraOptions[this.eraIndex])).fontFamily(uiFontFamily())
            .fontSize(13)
            .fontColor(Theme.ink)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('▾').fontFamily(uiFontFamily())
            .fontSize(12)
            .fontColor(Theme.inkTertiary)
            .margin({ left: 6 })
        }
        .layoutWeight(1)
        .height(44)
        .padding({ left: 10, right: 10 })
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          this.showEraPicker = true;
        })
        if (this.useEra) {
          TextPicker({ range: this.eraYearOptions(), selected: this.eraYearIndex })
            .width(110)
            .height(44)
            .margin({ left: Spacing.S })
            .onChange((value: string | string[], index: number | number[]): void => {
              const idx: number = Array.isArray(index) ? (index as number[])[0] : (index as number);
              this.eraYearIndex = idx;
              this.eraYear = idx + 1;
              this.pickYear = ERA_LIST[this.eraIndex - 1].firstYear + idx;
              this.refreshDateOptions();
            })
        }
      }
      .width('100%')
      .padding({ left: Spacing.M, right: Spacing.M, top: 6 })

      Row() {
        TextPicker({ range: this.yearOptions, selected: this.yearIndex })
          .layoutWeight(4)
          .height(this.pickerHeight())
          .onChange((value: string | string[], index: number | number[]): void => {
            const idx: number = Array.isArray(index) ? (index as number[])[0] : (index as number);
            this.yearIndex = idx;
            this.pickYear = this.MAX_YEAR - idx;
            // 手动改公历年即退出年号联动，避免“年号 + 公历年”两处显示互相矛盾
            this.eraIndex = 0;
            this.useEra = false;
            // 农历闰月随年份变化，换年时重建月份并保持原选择
            this.buildMonthOptions();
            this.syncMonthSelection();
            this.syncDayOptions();
            this.dayIndex = Math.max(this.pickDay - 1, 0);
          })
        TextPicker({ range: this.monthOptions, selected: this.monthIndex })
          .layoutWeight(3)
          .height(this.pickerHeight())
          .onChange((value: string | string[], index: number | number[]): void => {
            const idx: number = Array.isArray(index) ? (index as number[])[0] : (index as number);
            this.monthIndex = idx;
            if (this.dateCalendar === '农历') {
              const months: LunarMonthOption[] = lunarMonthsOfYear(this.pickYear);
              if (idx >= 0 && idx < months.length) {
                this.pickMonth = months[idx].month;
                this.pickLeap = months[idx].isLeap;
              }
            } else {
              this.pickMonth = idx + 1;
              this.pickLeap = false;
            }
            this.syncDayOptions();
            this.dayIndex = Math.max(this.pickDay - 1, 0);
          })
        TextPicker({ range: this.dayOptions, selected: this.dayIndex })
          .layoutWeight(3)
          .height(this.pickerHeight())
          .onChange((value: string | string[], index: number | number[]): void => {
            const idx: number = Array.isArray(index) ? (index as number[])[0] : (index as number);
            this.dayIndex = idx;
            this.pickDay = idx + 1;
          })
      }
      .width('100%')
      .padding({ left: Spacing.M, right: Spacing.M })

      Button(T('确定日期')).fontFamily(uiFontFamily())
        .width('88%')
        .height(44)
        .margin({ top: 8, bottom: 16 })
        .backgroundColor(Theme.primary)
        .fontSize(15)
        .onClick((): void => {
          this.confirmDate();
        })
    }
    .width('100%')
    .backgroundColor(Theme.card)
    .borderRadius({ topLeft: 20, topRight: 20 })
  }

  private previewItem(label: string, value: string): PreviewItem {
    const item: PreviewItem = new PreviewItem();
    item.label = label;
    item.value = value;
    return item;
  }

  /** 右侧预览卡的数据行 */
  private previewItems(): PreviewItem[] {
    const list: PreviewItem[] = [];
    list.push(this.previewItem('性别', this.fGender));
    list.push(this.previewItem('在世状态', this.fLifeStatus));
    list.push(this.previewItem('身份', this.fChildStatus === '未记' ? '' :
      childStatusLabel(this.fChildStatus, this.fGender)));
    list.push(this.previewItem('出生', this.fBirthDate));
    list.push(this.previewItem('逝世', this.fDeathDate));
    list.push(this.previewItem('出生地', this.fBirthPlace));
    list.push(this.previewItem('现居地', this.fResidence));
    list.push(this.previewItem('父亲', this.relationValue(this.fFatherId)));
    list.push(this.previewItem('母亲', this.relationValue(this.fMotherId)));
    list.push(this.previewItem('配偶', this.spousesPreview()));
    list.push(this.previewItem('排行', this.fRank));
    list.push(this.previewItem('学历', this.fEducation));
    list.push(this.previewItem('职业', this.fOccupation));
    return list;
  }

  private relationValue(value: string): string {
    if (value.length === 0) {
      return '未选择';
    }
    const p: Person | null = this.svc().getPerson(value);
    return p === null ? value : p.name + '（' + p.uid + '）';
  }



  @Builder
  FormContent() {
    Column() {
      // 头像
      Column() {
        Stack() {
          if (this.fAvatar.length > 0) {
            Image(this.fAvatar).width(84).height(84).borderRadius(42).objectFit(ImageFit.Cover)
          } else {
            Text(T(this.fName.length > 0 ? this.fName.substring(0, 1) : '谱')).fontFamily(uiFontFamily())
              .fontSize(30)
              .fontColor(Theme.primary)
              .width(84)
              .height(84)
              .textAlign(TextAlign.Center)
              .backgroundColor(Theme.field)
              .borderRadius(42)
          }
        }
        .width(84)
        .height(84)
        .border({ width: 2, color: Theme.gold, radius: 42 })

        Row() {
          Text(T('点击更换头像')).fontFamily(uiFontFamily())
            .fontSize(12)
            .fontColor(Theme.onPrimary)
            .backgroundColor(Theme.primary)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick((): void => {
              this.pickAvatar();
            })
          if (this.fAvatar.length > 0) {
            Text(T('清除')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.inkTertiary)
              .margin({ left: Spacing.M })
              .onClick((): void => {
                this.fAvatar = '';
              })
          }
        }
        .margin({ top: Spacing.S })
      }
      .width('100%')

      if (this.errorMsg.length > 0) {
        Text(T('⚠ ' + this.errorMsg)).fontFamily(uiFontFamily())
          .fontSize(12.5)
          .fontColor(Theme.danger)
          .backgroundColor(Theme.dangerBg)
          .borderRadius(8)
          .padding(Spacing.M)
          .width('100%')
          .margin({ top: Spacing.M })
      }

      // 身份标识
      GroupHeaderRow({ title: '身份标识', icon: '🪪' })
      Row() {
        Column() {
          PersonFieldForm({
            meta: fieldMetaOf('name'),
            value: this.fName,
            required: true,
            onValue: (v: string): void => {
              this.fName = v;
            }
          })
        }
        .layoutWeight(1)
        Column() {
          PersonFieldForm({
            meta: fieldMetaOf('uid'),
            value: this.fUid,
            hint: '选性别后自动生成（男 F / 女 M），也可手工填写',
            onValue: (v: string): void => {
              this.fUid = v;
              this.uidAuto = v.trim().length === 0;
            }
          })
        }
        .layoutWeight(1)
        .margin({ left: Spacing.M })
      }

      Row() {
        Column() {
          SelectField({
            label: '世代',
            hint: '必选。妻/妾等无父母者同样只需选择世代',
            required: true,
            options: this.generationOptions(),
            keys: this.generationKeys(),
            value: this.fGeneration.toString(),
            onValue: (v: string): void => {
              this.assignValue('generation', v);
            }
          })
        }
        .layoutWeight(1)
        Column() {
          SelectField({
            label: '辈分/字派',
            hint: '上下滑动选择所属字辈',
            options: this.genCharOptions(),
            value: this.fGenChar,
            onValue: (v: string): void => {
              this.assignValue('genChar', v);
            }
          })
        }
        .layoutWeight(1)
        .margin({ left: Spacing.M })
      }

      Row() {
        Column() {
          PersonFieldForm({
            meta: fieldMetaOf('gender'),
            value: this.fGender,
            hint: '上下滑动选择男 / 女',
            required: true,
            onValue: (v: string): void => {
              this.assignValue('gender', v);
            }
          })
        }
        .layoutWeight(1)
        Column() {
          PersonFieldForm({
            meta: fieldMetaOf('lifeStatus'),
            value: this.fLifeStatus,
            hint: '在世 / 已故 / 失联 / 不详',
            required: true,
            onValue: (v: string): void => {
              this.assignValue('lifeStatus', v);
            }
          })
        }
        .layoutWeight(1)
        .margin({ left: Spacing.M })
      }

      Column() {
        PersonFieldForm({
          meta: fieldMetaOf('childStatus'),
          value: this.fChildStatus,
          onValue: (v: string): void => {
            this.assignValue('childStatus', v);
          }
        })
        if (this.fChildStatus !== '未记') {
          Text(T(childStatusHint(this.fChildStatus))).fontFamily(uiFontFamily())
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .lineHeight(16)
            .width('100%')
        }
        if (this.isConcubineChild()) {
          Text(T(CONCUBINE_CHILD_TITLE_HINT)).fontFamily(uiFontFamily())
            .fontSize(10.5)
            .fontColor(Theme.gold)
            .lineHeight(16)
            .width('100%')
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      // 婚配状态：未字/未娶/适人/娶妻/招赘，用于牒记「终身未字」「适XX」
      PersonFieldForm({
        meta: fieldMetaOf('marriageStatus'),
        value: this.fMarriageStatus,
        hint: '未记则不写婚配结论；未字/未娶写「终身未字」；适人/娶妻/招赘可写夫家',
        optionsOverride: this.marriageOptions(),
        onValue: (v: string): void => {
          this.fMarriageStatus = v;
        }
      })
      if (this.showSpouseFamily()) {
        PersonFieldForm({
          meta: fieldMetaOf('spouseFamily'),
          value: this.fSpouseFamily,
          onValue: (v: string): void => {
            this.fSpouseFamily = v;
          }
        })
      }

      // 齿录模板新增：子女标记
      Row() {
        Column() {
          PersonFieldForm({
            meta: fieldMetaOf('childMark'),
            value: this.fChildMark,
            hint: '殇/出嗣/兼祧/继子/养子/无出/未记',
            onValue: (v: string): void => {
              this.assignValue('childMark', v);
            }
          })
        }
        .layoutWeight(1)
        Column() {
          PersonFieldForm({
            meta: fieldMetaOf('childMarkTarget'),
            value: this.fChildMarkTarget,
            hint: '出嗣/兼祧时填写所嗣之房支或人名',
            onValue: (v: string): void => {
              this.fChildMarkTarget = v;
            }
          })
        }
        .layoutWeight(1)
        .margin({ left: Spacing.M })
      }
      .width('100%')

      Row() {
        Column() {
          PersonFieldForm({
            meta: fieldMetaOf('childMarkSource'),
            value: this.fChildMarkSource,
            hint: '入继/兼祧时填写来源房支或人名',
            onValue: (v: string): void => {
              this.fChildMarkSource = v;
            }
          })
        }
        .layoutWeight(1)
        Column() {
          NumberFieldRow({
            label: '在源第几子',
            value: this.fChildMarkSeq,
            hint: '入继/兼祧时填写在来源中的排行',
            min: 1,
            max: 99,
            onChange: (v: number): void => {
              this.fChildMarkSeq = v;
            }
          })
        }
        .layoutWeight(1)
        .margin({ left: Spacing.M })
      }
      .width('100%')

      Row() {
        FormToggleRow({
          label: '无出',
          value: this.fChildless,
          hint: '无子女',
          onChange: (v: boolean): void => {
            this.fChildless = v;
          }
        })
      }
      .width('100%')
      .margin({ top: Spacing.S })

      PersonFieldForm({
        meta: fieldMetaOf('alias'),
        value: this.fAlias,
        onValue: (v: string): void => {
          this.fAlias = v;
        }
      })

      Row() {
        Column() {
          PersonFieldForm({
            meta: fieldMetaOf('courtesyName'),
            value: this.fCourtesyName,
            onValue: (v: string): void => {
              this.fCourtesyName = v;
            }
          })
        }
        .layoutWeight(1)
        Column() {
          PersonFieldForm({
            meta: fieldMetaOf('artName'),
            value: this.fArtName,
            onValue: (v: string): void => {
              this.fArtName = v;
            }
          })
        }
        .layoutWeight(1)
        .margin({ left: Spacing.S })
      }
      .width('100%')

      // 时间信息
      GroupHeaderRow({ title: '时间信息', icon: '📅' })
      Row() {
        Column() {
          DateFieldInput({
            label: '出生日期',
            hint: this.fBirthCalendar === '农历' ? '可直接输入：光绪三十一年农历五月廿五' :
              '可直接输入：1980-05-20 或 光绪三十一年',
            value: this.fBirthDate,
            onChange: (v: string): void => {
              this.fBirthDate = v;
            },
            onPick: (): void => {
              this.openDatePicker('出生日期', this.fBirthCalendar, this.fBirthDate);
            }
          })
        }
        .layoutWeight(1)
        Column() {
          SelectField({
            label: '历法',
            hint: '公历 / 农历',
            options: CALENDAR_OPTIONS,
            value: this.fBirthCalendar,
            onValue: (v: string): void => {
              this.assignValue('birthCalendar', v);
            }
          })
        }
        .width(96)
        .margin({ left: Spacing.S })
      }
      if (this.fLifeStatus === '已故') {
        Row() {
          Column() {
            DateFieldInput({
              label: '逝世日期',
              hint: this.fDeathCalendar === '农历' ? '可直接输入：光绪三十一年农历五月廿五' :
                '可直接输入：1980-05-20 或 光绪三十一年',
              value: this.fDeathDate,
              onChange: (v: string): void => {
                this.fDeathDate = v;
              },
              onPick: (): void => {
                this.openDatePicker('逝世日期', this.fDeathCalendar, this.fDeathDate);
              }
            })
          }
          .layoutWeight(1)
          Column() {
            SelectField({
              label: '历法',
              hint: '公历 / 农历',
              options: CALENDAR_OPTIONS,
              value: this.fDeathCalendar,
              onValue: (v: string): void => {
                this.assignValue('deathCalendar', v);
              }
            })
          }
          .width(96)
          .margin({ left: Spacing.S })
        }
      }
      PersonFieldForm({
        meta: fieldMetaOf('birthPlace'),
        value: this.fBirthPlace,
        onValue: (v: string): void => {
          this.fBirthPlace = v;
        }
      })
      PersonFieldForm({
        meta: fieldMetaOf('residence'),
        value: this.fResidence,
        hint: '同上，精确到小区/街道',
        onValue: (v: string): void => {
          this.fResidence = v;
        }
      })

      // 亲属关系
      GroupHeaderRow({ title: '亲属关系', icon: '👪' })
      PersonPickerField({
        label: '父亲ID',
        hint: '点击搜索并选择父亲，如：F000；妻/妾等无父母者可留空',
        value: this.fFatherId,
        genderFilter: '男',
        excludeUid: this.fUid,
        clearable: true,
        onValue: (v: string): void => {
          this.fFatherId = v;
        },
        onSearch: (k: string): Person[] => SR.genealogy().search(k),
        onResolve: (uid: string): Person | null => SR.genealogy().getPerson(uid)
      })
      PersonPickerField({
        label: '母亲ID',
        hint: '点击搜索并选择母亲，如：M050；妻/妾等无父母者可留空',
        value: this.fMotherId,
        genderFilter: '女',
        excludeUid: this.fUid,
        clearable: true,
        onValue: (v: string): void => {
          this.fMotherId = v;
        },
        onSearch: (k: string): Person[] => SR.genealogy().search(k),
        onResolve: (uid: string): Person | null => SR.genealogy().getPerson(uid)
      })
      // 父母未录入族谱时的兜底姓名：妻子的父亲/母亲即丈夫条目中的岳父/岳母
      Row() {
        Column() {
          PersonFieldForm({
            meta: fieldMetaOf('fatherName'),
            value: this.fFatherName,
            hint: '父亲未录入族谱时填写；妻子的父亲即岳父',
            onValue: (v: string): void => {
              this.fFatherName = v;
            }
          })
          SelectField({
            label: '在世状态',
            hint: '',
            options: PARENT_LIFE_STATUS_OPTIONS,
            value: this.fFatherLifeStatus,
            onValue: (v: string): void => {
              this.fFatherLifeStatus = v;
            }
          })
        }
        .layoutWeight(1)
        Column() {
          PersonFieldForm({
            meta: fieldMetaOf('motherName'),
            value: this.fMotherName,
            hint: '母亲未录入族谱时填写；妻子的母亲即岳母',
            onValue: (v: string): void => {
              this.fMotherName = v;
            }
          })
          SelectField({
            label: '在世状态',
            hint: '',
            options: PARENT_LIFE_STATUS_OPTIONS,
            value: this.fMotherLifeStatus,
            onValue: (v: string): void => {
              this.fMotherLifeStatus = v;
            }
          })
        }
        .layoutWeight(1)
        .margin({ left: Spacing.S })
      }
      .width('100%')
      SpouseSection({
        spouses: this.fSpouses,
        selfUid: this.fUid,
        onAdd: (): void => {
          this.addSpouse();
        },
        onRemove: (index: number): void => {
          this.removeSpouse(index);
        },
        onChange: (index: number, uid: string, relation: string): void => {
          this.updateSpouse(index, uid, relation);
        }
      })
      SelectField({
        label: '排行',
        hint: this.isNatalOutsider() ? '填写在娘家的排行' :
          (this.fGeneration === 1 ? '第一世为始祖，排行记为“第一世（始祖）”' :
            '第几子/女，上下滑动选择，如：长子、次女'),
        options: this.rankOptions(),
        value: this.fRank,
        onValue: (v: string): void => {
          this.assignValue('rank', v);
        }
      })
      PersonFieldForm({
        meta: fieldMetaOf('adoption'),
        value: this.fAdoption,
        onValue: (v: string): void => {
          this.fAdoption = v;
        }
      })

      // 生平履历
      GroupHeaderRow({ title: '生平履历', icon: '📜' })
      PersonFieldForm({
        meta: fieldMetaOf('education'),
        value: this.fEducation,
        onValue: (v: string): void => {
          this.fEducation = v;
        }
      })
      PersonFieldForm({
        meta: fieldMetaOf('occupation'),
        value: this.fOccupation,
        onValue: (v: string): void => {
          this.fOccupation = v;
        }
      })
      PersonFieldForm({
        meta: fieldMetaOf('biography'),
        value: this.fBiography,
        multiline: true,
        maxLength: 500,
        textAreaHeight: 140,
        hint: '500字以内，记录重大成就、品德、事迹（' + this.fBiography.length.toString() + '/500）',
        onValue: (v: string): void => {
          this.fBiography = v;
        }
      })

      Column() {
        FormLabel({ text: '墓葬信息', required: false, hint: '地点、山向、碑文摘要（仅已故者填写）' })
        TextArea({ text: this.fGraveInfo }).fontFamily(uiFontFamily())
          .height(80)
          .fontSize(14)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .onChange((v: string): void => {
            this.fGraveInfo = v;
          })

        Column() {
          Row() {
            Text(T('经度（东经）')).fontFamily(uiFontFamily()).fontSize(11).fontColor(Theme.inkTertiary).layoutWeight(1)
          }
          .width('100%')
          TextInput({ text: this.fGraveLng !== 0 ? this.fGraveLng.toFixed(10) : '' }).fontFamily(uiFontFamily())
            .height(36)
            .fontSize(12)
            .fontColor(Theme.ink)
            .placeholderColor(Theme.inkTertiary)
            .backgroundColor(Theme.card)
            .borderRadius(6)
            .onChange((v: string): void => {
              const n: number = parseFloat(v);
              if (!isNaN(n)) {
                this.fGraveLng = n;
              }
            })
          Row() {
            Text(T('纬度（北纬）')).fontFamily(uiFontFamily()).fontSize(11).fontColor(Theme.inkTertiary).layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 6 })
          TextInput({ text: this.fGraveLat !== 0 ? this.fGraveLat.toFixed(10) : '' }).fontFamily(uiFontFamily())
            .height(36)
            .fontSize(12)
            .fontColor(Theme.ink)
            .placeholderColor(Theme.inkTertiary)
            .backgroundColor(Theme.card)
            .borderRadius(6)
            .onChange((v: string): void => {
              const n: number = parseFloat(v);
              if (!isNaN(n)) {
                this.fGraveLat = n;
              }
            })
          Row() {
            Text(T('海拔（米）')).fontFamily(uiFontFamily()).fontSize(11).fontColor(Theme.inkTertiary).layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 6 })
          TextInput({ text: this.fGraveAltitude !== 0 ? this.fGraveAltitude.toFixed(1) : '' }).fontFamily(uiFontFamily())
            .height(36)
            .fontSize(12)
            .fontColor(Theme.ink)
            .placeholderColor(Theme.inkTertiary)
            .backgroundColor(Theme.card)
            .borderRadius(6)
            .onChange((v: string): void => {
              const n: number = parseFloat(v);
              if (!isNaN(n)) {
                this.fGraveAltitude = n;
              }
            })
          Row() {
            Text(T('地图定位信息 / 分享链接')).fontFamily(uiFontFamily()).fontSize(11).fontColor(Theme.inkTertiary).layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 6 })
          TextInput({ text: this.fGraveMapInfo, placeholder: T('粘贴地图分享链接或“经度,纬度”') }).fontFamily(uiFontFamily())
            .height(36)
            .fontSize(12)
            .fontColor(Theme.ink)
            .placeholderColor(Theme.inkTertiary)
            .backgroundColor(Theme.card)
            .borderRadius(6)
            .onChange((v: string): void => {
              this.applyMapInfo(v);
            })
          if (this.mapHint.length > 0) {
            Text(T(this.mapHint)).fontFamily(uiFontFamily())
              .fontSize(10.5)
              .fontColor(Theme.inkTertiary)
              .width('100%')
              .margin({ top: 4 })
          }
          Row() {
            Text(T(this.locating ? '⏳ 正在定位…' : '📍 拾取当前位置')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.onPrimary)
              .backgroundColor(Theme.alive)
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(14)
              .onClick((): void => {
                this.pickGraveLocation();
              })
            Text(T('🗺 地图应用拾取')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.primary)
              .backgroundColor(Theme.goldBg)
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(14)
              .margin({ left: Spacing.S })
              .onClick((): void => {
                this.launchMapApp();
              })
            Blank()
            Text(T(this.fGraveLat !== 0 ? '已定位' : '未定位')).fontFamily(uiFontFamily())
              .fontSize(11)
              .fontColor(this.fGraveLat !== 0 ? Theme.alive : Theme.inkTertiary)
          }
          .width('100%')
          .margin({ top: Spacing.S })
        }
        .width('100%')
        .padding(Spacing.M)
        .backgroundColor(Theme.field)
        .borderRadius(10)
        .margin({ top: Spacing.S })
      }
      .width('100%')
      .margin({ bottom: Spacing.M })

      // 联系方式
      GroupHeaderRow({ title: '联系方式', icon: '📞' })
      Row() {
        Text(T('🔒 以下为隐私字段，仅管理员可见')).fontFamily(uiFontFamily())
          .fontSize(11)
          .fontColor(Theme.danger)
          .width('100%')
      }
      .margin({ bottom: Spacing.S })
      PersonFieldForm({
        meta: fieldMetaOf('phone'),
        value: this.fPhone,
        hint: '用于核实信息',
        onValue: (v: string): void => {
          this.fPhone = v;
        }
      })
      PersonFieldForm({
        meta: fieldMetaOf('wechat'),
        value: this.fWechat,
        onValue: (v: string): void => {
          this.fWechat = v;
        }
      })

      // 照片视频：预览框 + “+” 添加（系统图库 / 文件管理器）
      Column() {
        Row() {
          Text(T('照片视频')).fontFamily(uiFontFamily()).fontSize(13).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
          Text(T(this.photoList().length > 0 ? '已添加 ' + this.photoList().length.toString() + ' 项' : '')).fontFamily(uiFontFamily())
            .fontSize(11)
            .fontColor(Theme.inkTertiary)
            .margin({ left: Spacing.S })
          Blank()
          if (this.photoList().length > 0) {
            Text(T('清空')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.inkTertiary)
              .onClick((): void => {
                this.fPhotos = '';
              })
          }
        }
        .width('100%')

        Text(T('点击“+”从系统图库或文件管理器添加照片、视频')).fontFamily(uiFontFamily())
          .fontSize(10.5)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .margin({ top: 1 })

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.photoList(), (uri: string, index: number) => {
            Stack({ alignContent: Alignment.TopEnd }) {
              if (this.isVideoUri(uri)) {
                Column() {
                  Text(T('🎬')).fontFamily(uiFontFamily()).fontSize(22)
                  Text(T('视频')).fontFamily(uiFontFamily()).fontSize(9).fontColor(Theme.inkTertiary)
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(Theme.field)
                .borderRadius(8)
              } else {
                Image(uri)
                  .width('100%')
                  .height('100%')
                  .objectFit(ImageFit.Cover)
                  .borderRadius(8)
              }
              Text(T('×')).fontFamily(uiFontFamily())
                .fontSize(11)
                .fontColor(Theme.onPrimary)
                .backgroundColor(Theme.scrim)
                .borderRadius(9)
                .width(18)
                .height(18)
                .textAlign(TextAlign.Center)
                .margin({ top: 2, right: 2 })
                .onClick((): void => {
                  this.removePhotoAt(index);
                })
            }
            .width('23%')
            .aspectRatio(1)
            .margin({ right: '2%', bottom: 6 })
          }, (uri: string, index: number): string => uri + '_' + index.toString())

          Column() {
            Text(T('+')).fontFamily(uiFontFamily()).fontSize(28).fontColor(Theme.primary)
          }
          .width('23%')
          .aspectRatio(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .border({ width: 1, color: Theme.line, style: BorderStyle.Dashed })
          .onClick((): void => {
            this.showMediaSourceDialog();
          })
        }
        .width('100%')
        .margin({ top: Spacing.S })
      }
      .width('100%')
      .margin({ bottom: Spacing.M })

      Column().height(120)
    }
    .width('100%')
  }



  build() {
    Stack({ alignContent: Alignment.Bottom }) {
    Column() {
      // 顶栏
      Row() {
        BackButton({
          onBack: (): void => {
            this.confirmExit();
          }
        })
        Text(T(this.originalUid.length > 0 ? '编辑族人' : (this.mode === 'child' ? '添加子女' : '新增族人'))).fontFamily(uiFontFamily())
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
        if (this.originalUid.length > 0) {
          Text(T('删除')).fontFamily(uiFontFamily())
            .fontSize(13)
            .fontColor(Theme.danger)
            .margin({ right: Spacing.M })
            .onClick((): void => {
              this.remove();
            })
        }
        Button(T(this.saving ? '保存中…' : '保存')).fontFamily(uiFontFamily())
          .fontSize(13)
          .height(28)
          .padding({ left: 16, right: 16 })
          .backgroundColor(Theme.primary)
          .enabled(!this.saving)
          .onClick((): void => {
            this.save();
          })
      }
      .width('100%')
      .height(34)
      .padding({ left: Spacing.S, right: Spacing.L })
      .backgroundColor(Theme.card)
      .border({ width: { bottom: 0.5 }, color: Theme.line })

      if (this.loading) {
        Column() {
          LoadingProgress().width(36).height(36).color(Theme.primary)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.windowWidth >= Breakpoint.MD) {
        Row() {
          Scroll() {
            Column() {
              this.FormContent()
            }
            .width('100%')
          }
          .layoutWeight(3)
          .height('100%')
          .scrollBar(BarState.Off)
          .align(Alignment.Top)

          Scroll() {
            Column() {
              SidePreview({
                name: this.fName,
                gender: this.fGender,
                subtitle: generationLabel(this.fGeneration) + ' · ' +
                  (this.fUid.length > 0 ? this.fUid : 'ID 待生成') +
                  (this.fGenChar.length > 0 ? ' · “' + this.fGenChar + '”字' : ''),
                items: this.previewItems(),
                biography: this.fBiography
              })
              Column().height(120)
            }
            .width('100%')
          }
          .layoutWeight(2)
          .height('100%')
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
          .margin({ left: Spacing.XL })
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Spacing.XL, right: Spacing.XL, top: 0 })
        .alignItems(VerticalAlign.Top)
      } else {
        Scroll() {
          Column() {
            this.FormContent()
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.paper)

      // 历史日期选择面板（覆盖在底部）
      if (this.showDatePicker) {
        Column() {
          Blank()
          this.DatePickerPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.35)')
        .onClick((): void => {
          this.showDatePicker = false;
        })
      }

      // 纪年选择弹窗（覆盖在日期面板之上）
      if (this.showEraPicker) {
        Column() {
          Blank()
          EraPickerPanel({
            options: this.eraOptions,
            selected: this.eraIndex,
            onSelect: (idx: number): void => {
              this.selectEra(idx);
            },
            onClose: (): void => {
              this.showEraPicker = false;
            }
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.5)')
        .onClick((): void => {
          this.showEraPicker = false;
        })
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // 本页独立于主界面，旋转/窗口缩放时需自行同步断点，横屏才会切到双栏
      const w: number = Number(newValue.width);
      const h: number = Number(newValue.height);
      if (w > 0 && (Math.abs(w - this.windowWidth) > 1 || Math.abs(h - this.windowHeight) > 1)) {
        AppStorage.setOrCreate<number>('windowWidth', w);
        AppStorage.setOrCreate<number>('windowHeight', h);
      }
    })
  }
}


