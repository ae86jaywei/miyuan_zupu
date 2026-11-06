import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { geoLocationManager } from '@kit.LocationKit';
import { sensor } from '@kit.SensorServiceKit';
import { picker } from '@kit.CoreFileKit';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { BackButton } from '../components/BackButton';
import { Breakpoint } from '../common/Constants';
import { Person, SpouseRelation, createEmptyPerson, clonePerson, cloneSpouseRelation, SPOUSE_RELATIONS, spouseRelationLabel, spouseRelationHint, spouseRelationLevel, childRankOfSpouseRelation, CHILD_STATUS_OPTIONS, childStatusLabel, childStatusHint, CONCUBINE_CHILD_TITLE_HINT } from '../model/Person';
import { GenealogyService } from '../service/GenealogyService';
import { GenealogyStore } from '../store/GenealogyStore';
import { FamilyService } from '../service/FamilyService';
import { EditParams } from '../model/Scope';
import { IdGenerator } from '../util/IdGenerator';
import { GENDER_OPTIONS, LIFE_STATUS_OPTIONS, CALENDAR_OPTIONS, RANK_OPTIONS, generationLabel } from '../model/Enums';
import { isBlank } from '../util/StringUtil';
import { parseDate, ParsedDate, parseHistoricalDate, composeDate, cnYearText, ERA_TABLE } from '../util/DateUtil';
import { huangLiText, HuangLi } from '../util/LunarUtil';

/** 第一世（始祖）的排行称谓 */
const ANCESTOR_RANK: string = '第一世（始祖）';

/**
 * 下拉选择字段（原生 Select）。
 *
 * 这里必须用“子组件 + @Prop”而不是“@Builder 按值传参”：@Builder 的按值参数
 * 在父组件状态变化后不会刷新内部 UI，会导致“选了值但界面仍是默认值、清除无效”。
 *
 * 说明：
 *  - 整块 40vp 高度都可点击（不再用透明 Select + 覆盖层，避免点击落空）；
 *  - 箭头使用 SDK 默认样式，颜色跟随 fontColor，因此浅色 / 深色模式都能自适应；
 *  - options 为显示文案，keys 与之一一对应时 onValue 回传 keys[index]（如人物唯一ID）。
 */
@Component
struct SelectField {
  @Prop label: string = '';
  @Prop hint: string = '';
  @Prop required: boolean = false;
  @Prop options: string[] = [];
  @Prop keys: string[] = [];
  @Prop value: string = '';
  @Prop clearable: boolean = false;
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  onValue: (v: string) => void = (v: string): void => {};

  onDark(): void {
    Theme.use(this.darkMode);
  }

  private buildOptions(): SelectOption[] {
    const list: SelectOption[] = [];
    this.options.forEach((o: string): void => {
      list.push({ value: o });
    });
    return list;
  }

  /** 当前值在选项中的下标（无 keys 时用文案反查，有 keys 时用值反查） */
  private selectedIndex(): number {
    const list: string[] = this.keys.length === this.options.length ? this.keys : this.options;
    const i: number = list.indexOf(this.value);
    return i < 0 ? 0 : i;
  }

  /** 按钮文字：优先显示候选文案，值不在候选中时回退显示原值 */
  private displayText(): string {
    if (this.value.length === 0) {
      return this.clearable ? '未选择' : '请选择';
    }
    const i: number = this.selectedIndex();
    if (i < this.options.length && this.valueAt(i) === this.value) {
      return this.options[i];
    }
    return this.value;
  }

  private valueAt(index: number): string {
    return this.keys.length === this.options.length ? this.keys[index] : this.options[index];
  }

  build() {
    Column() {
      Column() {
        Row() {
          Text(this.label).fontSize(13).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
          if (this.required) {
            Text(' *').fontSize(13).fontColor(Theme.danger)
          }
        }
        .width('100%')
        if (this.hint.length > 0) {
          Text(this.hint)
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .width('100%')
            .margin({ top: 1 })
        }
      }
      .width('100%')
      .margin({ bottom: 4 })

      Row() {
        Select(this.buildOptions())
          .selected(this.selectedIndex())
          .value(this.displayText())
          .font({ size: 14, weight: this.value.length > 0 ? FontWeight.Medium : FontWeight.Normal })
          .fontColor(this.value.length > 0 ? Theme.ink : Theme.inkTertiary)
          .optionFont({ size: 14 })
          .optionFontColor(Theme.ink)
          .optionBgColor(Theme.card)
          .selectedOptionFontColor(Theme.primary)
          .selectedOptionBgColor(Theme.highlightBg)
          .menuBackgroundColor(Theme.card)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .height(40)
          .layoutWeight(1)
          .optionWidth(OptionWidthMode.FIT_CONTENT)
          .menuAlign(MenuAlignType.START, { dx: 0, dy: 0 })
          .onSelect((index: number): void => {
            if (index >= 0 && index < this.options.length) {
              this.onValue(this.valueAt(index));
            }
          })
        if (this.clearable && this.value.length > 0) {
          Text('清除')
            .fontSize(12)
            .fontColor(Theme.inkTertiary)
            .padding({ left: Spacing.M, top: 10, bottom: 10 })
            .onClick((): void => {
              this.onValue('');
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .margin({ bottom: Spacing.M })
  }
}

/**
 * 日期输入 + “选择”按钮。
 * 同样使用 @Prop 绑定，日历面板确认后父组件状态变化会立即回填到输入框。
 */
@Component
struct DateFieldInput {
  @Prop label: string = '';
  @Prop hint: string = '';
  @Prop value: string = '';
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  onChange: (v: string) => void = (v: string): void => {};
  onPick: () => void = (): void => {};

  onDark(): void {
    Theme.use(this.darkMode);
  }

  build() {
    Column() {
      Column() {
        Row() {
          Text(this.label).fontSize(13).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        }
        .width('100%')
        if (this.hint.length > 0) {
          Text(this.hint)
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .width('100%')
            .margin({ top: 1 })
        }
      }
      .width('100%')
      .margin({ bottom: 4 })

      Row() {
        TextInput({ text: this.value, placeholder: '点击右侧“选择”，或直接输入' })
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor(Theme.ink)
          .placeholderColor(Theme.inkTertiary)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .onChange((v: string): void => {
            this.onChange(v);
          })
        Text('📅 选择')
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor(Theme.primary)
          .padding({ left: 10, right: 10, top: 11, bottom: 11 })
          .borderRadius(14)
          .margin({ left: Spacing.S })
          .onClick((): void => {
            this.onPick();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .margin({ bottom: Spacing.M })
  }
}

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

  // 字段状态
  @State fGeneration: number = 1;
  @State fUid: string = '';
  /** 唯一ID 是否为自动生成（自动生成的会在切换性别时重新计算） */
  @State uidAuto: boolean = true;
  @State fName: string = '';
  @State fAlias: string = '';
  @State fGender: string = '男';
  @State fGenChar: string = '';
  @State fLifeStatus: string = '在世';
  @State fChildStatus: string = '未记';
  @State fBirthDate: string = '';
  @State fBirthCalendar: string = '公历';
  @State fDeathDate: string = '';
  @State fDeathCalendar: string = '公历';
  @State fBirthPlace: string = '';
  @State fResidence: string = '';
  @State fFatherId: string = '';
  @State fMotherId: string = '';
  /** 配偶关系（可多位：元配 / 继室 / 妾） */
  @State fSpouses: SpouseRelation[] = [];
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
    return GenealogyService.getInstance();
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

  private fill(p: Person): void {
    this.fGeneration = p.generation;
    // 新增时留空，等选择性别后再生成（编辑时保留原 ID）
    this.fUid = p.uid;
    this.uidAuto = p.uid.trim().length === 0;
    this.fName = p.name;
    this.fAlias = p.alias;
    this.fGender = p.gender;
    this.fGenChar = p.generationChar;
    this.fLifeStatus = p.lifeStatus;
    this.fChildStatus = p.childStatus.length > 0 ? p.childStatus : '未记';
    this.fBirthDate = p.birthDate;
    this.fBirthCalendar = p.birthCalendar;
    this.fDeathDate = p.deathDate;
    this.fDeathCalendar = p.deathCalendar;
    this.fBirthPlace = p.birthPlace;
    this.fResidence = p.residence;
    this.fFatherId = p.fatherId;
    this.fMotherId = p.motherId;
    this.fSpouses = p.spouses.map((r: SpouseRelation): SpouseRelation => cloneSpouseRelation(r));
    this.fRank = p.generation === 1 ? ANCESTOR_RANK :
      (p.rank === ANCESTOR_RANK ? '' : p.rank);
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
    p.alias = this.fAlias;
    p.gender = this.fGender;
    p.generationChar = this.fGenChar;
    p.lifeStatus = this.fLifeStatus;
    p.childStatus = this.fChildStatus;
    p.birthDate = this.fBirthDate;
    p.birthCalendar = this.fBirthCalendar;
    p.deathDate = this.fDeathDate;
    p.deathCalendar = this.fDeathCalendar;
    p.birthPlace = this.fBirthPlace;
    p.residence = this.fResidence;
    p.fatherId = this.fFatherId;
    p.motherId = this.fMotherId;
    p.spouses = this.buildSpouses();
    p.spouseId = p.spouses.length > 0 ? p.spouses[0].uid : '';
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
        title: '该编号曾用于已删除族人',
        message: '编号“' + uid + '”曾属于已删除的“' + retiredName + '”。\n\n' +
          '继续使用该编号时，云端仍保留的旧父母/配偶关系可能被挂到当前族人身上，' +
          '合并后世系图会出现重复、重叠或多出宗支。\n\n建议取消后更换编号（留空可由系统自动分配）。',
        primaryButton: {
          value: '取消改号',
          action: (): void => {
          }
        },
        secondaryButton: {
          value: '仍然保存',
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
      // 协作态下说明这次修改的去向：已同步 / 已提交审核 / 离线待传
      this.getUIContext().getPromptAction().showToast({ message: this.saveHint() });
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
    const mode: string = FamilyService.getInstance().syncMode();
    if (mode === 'LOCAL') {
      return '已保存（本谱仅在本机）';
    }
    if (mode === 'CLOUD_PENDING') {
      return '已保存；本谱尚未发布到云端，稍后在「我的家族」发布';
    }
    if (!FamilyService.getInstance().canEditCurrent()) {
      return '已保存到本机；当前角色为只读，未提交云端';
    }
    if (FamilyService.getInstance().isOwnerCurrent()) {
      return '已保存并同步到云端';
    }
    return '已提交，等谱主审核后合入';
  }

  private async remove(): Promise<void> {
    if (this.originalUid.length === 0) {
      return;
    }
    const children: Person[] = this.svc().childrenOf(this.originalUid);
    const tip: string = children.length > 0 ?
      '该人物有 ' + children.length.toString() + ' 位子女，删除后子女将变为“无父/无母”状态。确认删除？' : '确认删除该人物？';
    this.getUIContext().showAlertDialog({
      title: '删除人物',
      message: tip,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.danger,
        action: (): void => {
          this.svc().deletePerson(this.originalUid)
            .then((): void => {
              GenealogyStore.notifyChanged();
              this.getUIContext().getPromptAction().showToast({ message: '已删除' });
              this.getUIContext().getRouter().back();
            })
            .catch((err: BusinessError): void => {
              this.getUIContext().getPromptAction().showToast({ message: '删除失败：' + err.message });
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
      this.getUIContext().getPromptAction().showToast({ message: '选择头像失败：' + err.message });
    }
  }

  /** 照片/视频列表（photos 字段以“;”分隔存储图片与视频 URI） */
  private photoList(): string[] {
    if (this.fPhotos.length === 0) {
      return [];
    }
    return this.fPhotos.split(';').filter((s: string): boolean => s.length > 0);
  }

  private isVideoUri(uri: string): boolean {
    const lower: string = uri.toLowerCase();
    return lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.m4v') ||
      lower.endsWith('.3gp') || lower.endsWith('.avi') || lower.endsWith('.mkv') || lower.endsWith('.webm');
  }

  private appendPhotos(uris: string[]): void {
    if (uris.length === 0) {
      return;
    }
    const joined: string = uris.join(';');
    this.fPhotos = this.fPhotos.length > 0 ? this.fPhotos + ';' + joined : joined;
  }

  private removePhotoAt(index: number): void {
    const list: string[] = this.photoList();
    if (index < 0 || index >= list.length) {
      return;
    }
    list.splice(index, 1);
    this.fPhotos = list.join(';');
  }

  /** “+” 添加来源选择：系统图库 / 文件管理器 */
  private showMediaSourceDialog(): void {
    this.getUIContext().showAlertDialog({
      title: '添加照片/视频',
      message: '请选择添加来源',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '系统图库',
        action: (): void => {
          this.pickPhotos();
        }
      },
      secondaryButton: {
        value: '文件管理器',
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
      this.getUIContext().getPromptAction().showToast({ message: '选择相片失败：' + err.message });
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
      this.getUIContext().getPromptAction().showToast({ message: '选择文件失败：' + err.message });
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
        this.getUIContext().getPromptAction().showToast({ message: '系统定位未开启，请先打开“位置信息”开关' });
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
        this.getUIContext().getPromptAction().showToast({ message: '已拾取当前位置（含海拔）' });
        return;
      }
      if (this.fGraveLat === 0 && this.fGraveLng === 0) {
        this.getUIContext().getPromptAction()
          .showToast({ message: '定位失败（' + lastMsg + '），可手工填写经纬度' });
        return;
      }
      // 重试后仍无海拔：若设备带气压计则用气压换算海拔
      const baroAlt: number = await this.readAltitudeByBarometer();
      if (!isNaN(baroAlt)) {
        this.fGraveAltitude = baroAlt;
        this.getUIContext().getPromptAction()
          .showToast({ message: '已拾取经纬度，海拔由气压计估算（' + baroAlt.toFixed(1) + ' 米）' });
      } else {
        this.getUIContext().getPromptAction()
          .showToast({ message: '已拾取经纬度，海拔暂不可用，请到空旷处重试或手工填写' });
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
      console.error('气压计换算海拔失败：' + (e as BusinessError).message);
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
        console.error('订阅气压计失败：' + (e as BusinessError).message);
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
    const t: string = text.trim();
    if (t.length === 0) {
      return '';
    }
    let lat: number = NaN;
    let lng: number = NaN;
    let alt: number = NaN;

    const altMatch: RegExpMatchArray | null =
      t.match(/(?:海拔|海拔高度|altitude|elevation|alt)\D*(-?\d+(?:\.\d+)?)/i);
    if (altMatch !== null) {
      alt = Number(altMatch[1]);
    }

    const latMatch: RegExpMatchArray | null = t.match(/(?:纬度|latitude|lat)\D*(-?\d+(?:\.\d+)?)/i);
    const lngMatch: RegExpMatchArray | null =
      t.match(/(?:经度|longitude|lng|lon|long)\D*(-?\d+(?:\.\d+)?)/i);
    if (latMatch !== null && lngMatch !== null) {
      lat = Number(latMatch[1]);
      lng = Number(lngMatch[1]);
    } else {
      let x: number = NaN;
      let y: number = NaN;
      const pair: RegExpMatchArray | null = t.match(
        /[?&](?:position|location|ll|q|center|destination|dest|point|latlng|coordinate|coordinates)=(-?\d+(?:\.\d+)?)[,;:]\s*(-?\d+(?:\.\d+)?)/i);
      if (pair !== null) {
        x = Number(pair[1]);
        y = Number(pair[2]);
      } else {
        const nums: RegExpMatchArray | null = t.match(/-?\d+\.\d{3,}/g);
        if (nums !== null && nums.length >= 2) {
          x = Number(nums[0]);
          y = Number(nums[1]);
        }
      }
      if (!isNaN(x) && !isNaN(y)) {
        // 国内地图多为“经度,纬度”；苹果/谷歌多为“纬度,经度”，按量级判断
        if (Math.abs(x) <= 90 && Math.abs(y) > 90) {
          lat = x;
          lng = y;
        } else {
          lng = x;
          lat = y;
        }
      }
    }

    if (isNaN(lat) || isNaN(lng) || (lat === 0 && lng === 0) ||
      Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      return '未识别到经纬度，可粘贴含坐标的分享链接或“经度,纬度”';
    }
    this.fGraveLat = lat;
    this.fGraveLng = lng;
    let hint: string = '已解析：经度 ' + lng.toFixed(6) + '，纬度 ' + lat.toFixed(6);
    if (!isNaN(alt) && alt !== 0) {
      this.fGraveAltitude = alt;
      hint += '，海拔 ' + alt.toFixed(1) + ' 米';
    } else {
      hint += '（链接不含海拔，可手工填写）';
    }
    return hint;
  }

  /** 拉起系统“地图应用选择器”，由用户在已安装的地图应用中选择 */
  private launchMapApp(): void {
    const host: Context | undefined = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    if (this.fGraveLat === 0 && this.fGraveLng === 0) {
      this.getUIContext().getPromptAction()
        .showToast({ message: '请先拾取当前位置，或粘贴地图分享链接解析出坐标' });
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
        console.error('startAbilityByType 失败：' + code.toString() + ' ' + name + ' ' + message);
        this.getUIContext().getPromptAction().showToast({ message: '打开地图失败：' + message });
      }
    };
    const ctx: common.UIAbilityContext = host as common.UIAbilityContext;
    ctx.startAbilityByType('navigation', param, startCallback, (err: BusinessError): void => {
      if (err) {
        this.getUIContext().getPromptAction().showToast({ message: '打开地图失败：' + err.message });
      }
    });
  }

  // ---------------------------------------------------------------- 下拉滑动选择

  private generationOptions(): string[] {
    const list: string[] = [];
    for (let i: number = 1; i <= 40; i++) {
      list.push(generationLabel(i));
    }
    return list;
  }

  /** 世代候选对应的数值键：文案是“第十世”等中文，必须用键回传数值，否则解析不出世代 */
  private generationKeys(): string[] {
    const list: string[] = [];
    for (let i: number = 1; i <= 40; i++) {
      list.push(i.toString());
    }
    return list;
  }

  /** 排行候选：第一世只有“第一世（始祖）”，其余世代为子/女排行 */
  private rankOptions(): string[] {
    if (this.fGeneration === 1) {
      return [ANCESTOR_RANK];
    }
    return RANK_OPTIONS;
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
        // 第一世用“第一世（始祖）”，其余世代恢复子/女排行
        if (this.fGeneration === 1) {
          this.fRank = ANCESTOR_RANK;
        } else if (this.fRank === ANCESTOR_RANK) {
          this.fRank = '';
        }
        break;
      }
      case 'gender': {
        this.fGender = value;
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

  private selectOptions(options: string[]): SelectOption[] {
    const list: SelectOption[] = [];
    options.forEach((o: string): void => {
      list.push({ value: o });
    });
    return list;
  }

  // ---------------------------------------------------------------- 构建

  @Builder
  Label(text: string, required: boolean, hint: string) {
    Column() {
      Row() {
        Text(text).fontSize(13).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        if (required) {
          Text(' *').fontSize(13).fontColor(Theme.danger)
        }
      }
      .width('100%')
      if (hint.length > 0) {
        Text(hint)
          .fontSize(10.5)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .margin({ top: 1 })
      }
    }
    .width('100%')
    .margin({ bottom: 4 })
  }

  @Builder
  TextField(label: string, value: string, hint: string, required: boolean, onChange: (v: string) => void) {
    Column() {
      this.Label(label, required, hint)
      TextInput({ text: value })
        .height(40)
        .fontSize(14)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .onChange((v: string): void => {
          onChange(v);
        })
    }
    .width('100%')
    .margin({ bottom: Spacing.M })
  }

  /**
   * 打开历史日期选择面板。
   *
   * 历史族谱常见“光绪三十一年”“民国二十九年”等纪年，系统日期选择器最早只到 1970，
   * 因此这里自绘“年 / 月 / 日”三段滚轮，范围 936 ~ 2100，覆盖清朝及更早祖先。
   */
  private openDatePicker(label: string, calendar: string, value: string): void {
    const parsed: ParsedDate = parseHistoricalDate(value);
    this.dateTargetLabel = label;
    this.dateCalendar = calendar;
    // 通过字段名区分出生/逝世，避免保存函数引用到状态变量
    this.dateTarget = label.indexOf('逝世') >= 0 ? 'death' : 'birth';
    this.pickYear = parsed.year > 0 ? parsed.year : 1900;
    this.pickMonth = parsed.month > 0 ? parsed.month : 1;
    this.pickDay = parsed.day > 0 ? parsed.day : 1;
    this.buildEraOptions();
    this.eraIndex = 0;
    this.useEra = false;
    this.eraYear = 1;
    this.eraYearIndex = 0;
    this.buildMonthOptions();
    this.refreshDateOptions();
    this.showDatePicker = true;
  }

  /** 生成年/月/日选项并校正日月下标 */
  /** 年号列表（第 0 项为“公历年”） */
  private buildEraOptions(): void {
    if (this.eraOptions.length > 1) {
      return;
    }
    const list: string[] = ['公历年'];
    ERA_TABLE.forEach((e: Array<Object>): void => {
      list.push((e[0] as string) + '年（' + (e[1] as number).toString() + '起）');
    });
    this.eraOptions = list;
  }

  /** 某个年号可选的年数（按到下一个年号或 2100 年计算） */
  private eraYearOptions(): string[] {
    const list: string[] = [];
    if (this.eraIndex <= 0 || this.eraIndex > ERA_TABLE.length) {
      return ['元年'];
    }
    const start: number = ERA_TABLE[this.eraIndex - 1][1];
    const end: number = this.eraIndex - 2 >= 0 ? ERA_TABLE[this.eraIndex - 2][1] - 1 : 2100;
    const max: number = Math.max(Math.min(end, 2100) - start + 1, 1);
    for (let i: number = 1; i <= max; i++) {
      list.push(i === 1 ? '元年' : this.numToCn(i) + '年');
    }
    return list;
  }

  /** 阿拉伯数字转中文（1~99） */
  private numToCn(n: number): string {
    const digits: string = '零一二三四五六七八九';
    if (n <= 10) {
      return n === 10 ? '十' : digits.charAt(n);
    }
    if (n < 20) {
      return '十' + digits.charAt(n % 10);
    }
    const tens: string = digits.charAt(Math.floor(n / 10));
    const ones: number = n % 10;
    return tens + '十' + (ones === 0 ? '' : digits.charAt(ones));
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
    // 先按年份范围校正，再计算该月天数，避免把 936~1799 的历史纪年截断到 1800
    this.pickYear = Math.min(Math.max(this.pickYear, this.MIN_YEAR), this.MAX_YEAR);
    const maxDay: number = this.daysInMonth(this.pickYear, this.pickMonth);
    if (this.pickDay > maxDay) {
      this.pickDay = maxDay;
    }
    this.syncDayOptions();
    this.yearIndex = this.MAX_YEAR - this.pickYear;
    this.monthIndex = this.pickMonth - 1;
    this.dayIndex = this.pickDay - 1;
  }

  private daysInMonth(year: number, month: number): number {
    if (year <= 0) {
      return 30;
    }
    return new Date(year, month, 0).getDate();
  }

  /** 按公历/农历生成月份与日期文案 */
  private buildMonthOptions(): void {
    if (this.dateCalendar === '农历') {
      this.monthOptions = ['正月', '二月', '三月', '四月', '五月', '六月', '七月', '八月', '九月', '十月', '冬月', '腊月'];
    } else {
      const m: string[] = [];
      for (let i: number = 1; i <= 12; i++) {
        m.push(i.toString() + '月');
      }
      this.monthOptions = m;
    }
  }

  private syncDayOptions(): void {
    const days: string[] = [];
    const max: number = this.daysInMonth(this.pickYear, this.pickMonth);
    // 切换年 / 月后日期可能超出当月天数，这里同步收敛，避免生成 2 月 31 日这类非法日期
    if (this.pickDay > max) {
      this.pickDay = max;
    }
    if (this.dayIndex > max - 1) {
      this.dayIndex = max - 1;
    }
    const lunar: string[] = ['初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十',
      '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
      '廿一', '廿二', '廿三', '廿四', '廿五', '廿六', '廿七', '廿八', '廿九', '三十'];
    for (let d: number = 1; d <= max; d++) {
      // 农历按传统写法：初一…三十；个别月份到 31 时写作“卅一日”
      days.push(this.dateCalendar === '农历' ? (d <= 30 ? lunar[d - 1] : '卅一日') : d.toString() + '日');
    }
    this.dayOptions = days;
  }

  /** 确认日期：直接按目标字段写回（不依赖函数型状态） */
  private confirmDate(): void {
    const hl: HuangLi = this.huangLi();
    let text: string = composeDate(this.pickYear, this.pickMonth, this.pickDay, this.dateCalendar);
    if (this.dateCalendar === '农历') {
      // 农历模式下同时保留干支记法，方便对照古谱
      text = text + '（' + hl.year + ' ' + hl.month + ' ' + hl.day + '）';
    }
    if (text.length > 0) {
      if (this.dateTarget === 'death') {
        this.fDeathDate = text;
      } else {
        this.fBirthDate = text;
      }
    }
    this.showDatePicker = false;
  }

  /** 当前所选日期对应的干支黄历 */
  private huangLi(): HuangLi {
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
        Text('取消')
          .fontSize(15)
          .fontColor(Theme.inkTertiary)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
          .onClick((): void => {
            this.showDatePicker = false;
          })
        Text(this.dateTargetLabel)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(2)
          .textAlign(TextAlign.Center)
        Text('确定')
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

      // 当前组合预览：公历 + 干支黄历（如 丙午年（马） 戊戌月 辛未日）
      Column() {
        Text(composeDate(this.pickYear, this.pickMonth, this.pickDay, this.dateCalendar))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.primary)
        Text(this.huangLi().text)
          .fontSize(12.5)
          .fontColor(Theme.gold)
          .margin({ top: 2 })
          .maxLines(2)
          .textAlign(TextAlign.Center)
        Text('节气：' + this.huangLi().term)
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Center)
      .margin({ bottom: 4 })

      // 古历法记年：先选年号，再选第几年；选择后自动换算公历年
      Row() {
        Text('纪年')
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
          .margin({ right: Spacing.S })
        Select(this.selectOptions(this.eraOptions))
          .selected(this.eraIndex)
          .value(this.eraIndex === 0 ? '公历年' : this.eraOptions[this.eraIndex])
          .font({ size: 13 })
          .fontColor(Theme.ink)
          .optionFont({ size: 13 })
          .optionFontColor(Theme.ink)
          .optionBgColor(Theme.card)
          .selectedOptionFontColor(Theme.primary)
          .selectedOptionBgColor(Theme.highlightBg)
          .menuBackgroundColor(Theme.card)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .layoutWeight(1)
          .optionWidth(OptionWidthMode.FIT_CONTENT)
          .onSelect((index: number): void => {
            this.eraIndex = index;
            this.useEra = index > 0;
            if (this.useEra) {
              const start: number = ERA_TABLE[index - 1][1];
              this.pickYear = start + this.eraYear - 1;
              this.refreshDateOptions();
            }
          })
        if (this.useEra) {
          TextPicker({ range: this.eraYearOptions(), selected: this.eraYearIndex })
            .width(110)
            .height(44)
            .onChange((value: string | string[], index: number | number[]): void => {
              const idx: number = Array.isArray(index) ? (index as number[])[0] : (index as number);
              this.eraYearIndex = idx;
              this.eraYear = idx + 1;
              const start: number = ERA_TABLE[this.eraIndex - 1][1];
              this.pickYear = start + this.eraYear - 1;
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
            this.syncDayOptions();
          })
        TextPicker({ range: this.monthOptions, selected: this.monthIndex })
          .layoutWeight(3)
          .height(this.pickerHeight())
          .onChange((value: string | string[], index: number | number[]): void => {
            const idx: number = Array.isArray(index) ? (index as number[])[0] : (index as number);
            this.monthIndex = idx;
            this.pickMonth = idx + 1;
            this.syncDayOptions();
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

      Button('确定日期')
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

  /** 亲属下拉的唯一ID列表（第 0 项为空串，代表“未选择”） */
  private relationUids(genderFilter: string): string[] {
    const uids: string[] = [''];
    this.svc().getPeople().forEach((p: Person): void => {
      if (p.uid === this.originalUid) {
        return;
      }
      if (genderFilter.length > 0 && p.gender !== genderFilter) {
        return;
      }
      uids.push(p.uid);
    });
    return uids;
  }

  /** 亲属下拉的显示文案，与 relationUids 一一对应 */
  private relationLabels(genderFilter: string): string[] {
    const labels: string[] = ['未选择'];
    this.svc().getPeople().forEach((p: Person): void => {
      if (p.uid === this.originalUid) {
        return;
      }
      if (genderFilter.length > 0 && p.gender !== genderFilter) {
        return;
      }
      labels.push(p.name + '（' + p.uid + '）· ' + generationLabel(p.generation));
    });
    return labels;
  }

  /** 名分下拉文案：称谓（等级），keys 仍为 SPOUSE_RELATIONS */
  private spouseRelationOptions(): string[] {
    const labels: string[] = [];
    SPOUSE_RELATIONS.forEach((r: string): void => {
      labels.push(spouseRelationLabel(r));
    });
    return labels;
  }

  private relationValue(value: string): string {
    if (value.length === 0) {
      return '未选择';
    }
    const p: Person | null = this.svc().getPerson(value);
    return p === null ? value : p.name + '（' + p.uid + '）';
  }

  @Builder
  GroupHeader(title: string, icon: string) {
    Row() {
      Text(icon).fontSize(15)
      Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(Theme.primary).margin({ left: 6 })
    }
    .width('100%')
    .padding({ top: Spacing.L, bottom: Spacing.S })
  }

  /** 配偶关系编辑区：可增删多位配偶，并为每位选择名分 */
  @Builder
  SpouseSection() {
    Column() {
      Row() {
        Column() {
          Text('配偶关系').fontSize(13).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
          Text('一夫一妻多妾制：正妻 / 平妻 / 贵妾 / 良妾 / 贱妾 / 外室，按先后顺序记录')
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('+ 添加配偶')
          .fontSize(12)
          .fontColor(Theme.primary)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .border({ width: 1, color: Theme.primary })
          .onClick((): void => {
            this.addSpouse();
          })
      }
      .width('100%')
      .margin({ bottom: Spacing.S })

      if (this.fSpouses.length === 0) {
        Text('尚未录入配偶')
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .padding({ top: 6, bottom: 6 })
      }

      ForEach(this.fSpouses, (rel: SpouseRelation, idx: number) => {
        Column() {
          Row() {
            Column() {
              SelectField({
                label: '配偶' + (idx + 1).toString(),
                hint: '选择配偶的唯一ID',
                options: this.relationLabels(''),
                keys: this.relationUids(''),
                value: rel.uid,
                clearable: true,
                onValue: (v: string): void => {
                  this.updateSpouse(idx, v, rel.relation);
                }
              })
              SelectField({
                label: '名分',
                hint: '选择具体称谓，括号内为其名分等级',
                options: this.spouseRelationOptions(),
                keys: SPOUSE_RELATIONS,
                value: rel.relation,
                onValue: (v: string): void => {
                  this.updateSpouse(idx, rel.uid, v);
                }
              })
            }
            .layoutWeight(1)

            Text('删除')
              .fontSize(12)
              .fontColor(Theme.danger)
              .padding({ left: Spacing.M, right: Spacing.S, top: 30, bottom: Spacing.M })
              .onClick((): void => {
                this.removeSpouse(idx);
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          // 名分含意提示：等级 / 地位 / 所生子女的宗法身份
          Text(spouseRelationHint(rel.relation))
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .lineHeight(16)
            .width('100%')
          if (childRankOfSpouseRelation(rel.relation).length > 0) {
            Text('所生子女：' + childRankOfSpouseRelation(rel.relation))
              .fontSize(10.5)
              .fontColor(Theme.gold)
              .width('100%')
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 4, right: 4, bottom: 6 })
      }, (rel: SpouseRelation) => 'spouse_' + rel.uid + '_' + rel.relation + '_' + rel.order.toString())
    }
    .width('100%')
    .margin({ bottom: Spacing.M })
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
            Text(this.fName.length > 0 ? this.fName.substring(0, 1) : '谱')
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
          Text('点击更换头像')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .backgroundColor(Theme.primary)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick((): void => {
              this.pickAvatar();
            })
          if (this.fAvatar.length > 0) {
            Text('清除')
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
        Text('⚠ ' + this.errorMsg)
          .fontSize(12.5)
          .fontColor(Theme.danger)
          .backgroundColor('#FCEDEA')
          .borderRadius(8)
          .padding(Spacing.M)
          .width('100%')
          .margin({ top: Spacing.M })
      }

      // 身份标识
      this.GroupHeader('身份标识', '🪪')
      Row() {
        Column() {
          this.TextField('谱名', this.fName, '族谱上的正式名字，如：李德明', true, (v: string): void => {
            this.fName = v;
          })
        }
        .layoutWeight(1)
        Column() {
          this.TextField('唯一ID', this.fUid, '选性别后自动生成（男 F / 女 M），也可手工填写', false, (v: string): void => {
            this.fUid = v;
            this.uidAuto = v.trim().length === 0;
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
          SelectField({
            label: '性别',
            hint: '上下滑动选择男 / 女',
            required: true,
            options: GENDER_OPTIONS,
            value: this.fGender,
            onValue: (v: string): void => {
              this.assignValue('gender', v);
            }
          })
        }
        .layoutWeight(1)
        Column() {
          SelectField({
            label: '在世状态',
            hint: '在世 / 已故 / 失联 / 不详',
            required: true,
            options: LIFE_STATUS_OPTIONS,
            value: this.fLifeStatus,
            onValue: (v: string): void => {
              this.assignValue('lifeStatus', v);
            }
          })
        }
        .layoutWeight(1)
        .margin({ left: Spacing.M })
      }

      Column() {
        SelectField({
          label: '子女身份',
          hint: '未记 / 嫡出 / 庶出 / 婢生 / 奸生 / 嗣子 / 养子 / 随母（决定宗法地位与继承顺序）',
          options: CHILD_STATUS_OPTIONS,
          value: this.fChildStatus,
          onValue: (v: string): void => {
            this.assignValue('childStatus', v);
          }
        })
        if (this.fChildStatus !== '未记') {
          Text(childStatusHint(this.fChildStatus))
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .lineHeight(16)
            .width('100%')
        }
        if (this.isConcubineChild()) {
          Text(CONCUBINE_CHILD_TITLE_HINT)
            .fontSize(10.5)
            .fontColor(Theme.gold)
            .lineHeight(16)
            .width('100%')
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      this.TextField('曾用名/小名', this.fAlias, '如有多个用逗号隔开，如：建国, 狗剩', false, (v: string): void => {
        this.fAlias = v;
      })

      // 时间信息
      this.GroupHeader('时间信息', '📅')
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
      this.TextField('出生地', this.fBirthPlace, '省-市-县-乡镇-村，如：广东-梅州-兴宁-罗岗镇', false,
        (v: string): void => {
          this.fBirthPlace = v;
        })
      this.TextField('现居地', this.fResidence, '同上，精确到小区/街道', false, (v: string): void => {
        this.fResidence = v;
      })

      // 亲属关系
      this.GroupHeader('亲属关系', '👪')
      SelectField({
        label: '父亲ID',
        hint: '选择父亲的唯一ID，如：F000；妻/妾等无父母者可留空',
        options: this.relationLabels('男'),
        keys: this.relationUids('男'),
        value: this.fFatherId,
        clearable: true,
        onValue: (v: string): void => {
          this.fFatherId = v;
        }
      })
      SelectField({
        label: '母亲ID',
        hint: '选择母亲的唯一ID，如：M050；妻/妾等无父母者可留空',
        options: this.relationLabels('女'),
        keys: this.relationUids('女'),
        value: this.fMotherId,
        clearable: true,
        onValue: (v: string): void => {
          this.fMotherId = v;
        }
      })
      this.SpouseSection()
      SelectField({
        label: '排行',
        hint: this.fGeneration === 1 ? '第一世为始祖，排行记为“第一世（始祖）”' :
          '第几子/女，上下滑动选择，如：长子、次女',
        options: this.rankOptions(),
        value: this.fRank,
        onValue: (v: string): void => {
          this.assignValue('rank', v);
        }
      })
      this.TextField('过继/出嗣', this.fAdoption, '若有过继，填“过继自XX”或“出嗣给XX”', false,
        (v: string): void => {
          this.fAdoption = v;
        })

      // 生平履历
      this.GroupHeader('生平履历', '📜')
      this.TextField('学历/学位', this.fEducation, '如：本科-华南理工大学', false, (v: string): void => {
        this.fEducation = v;
      })
      this.TextField('职业/职务', this.fOccupation, '如：高级工程师、村支书', false, (v: string): void => {
        this.fOccupation = v;
      })
      Column() {
        this.Label('生平简介', false, '500字以内，记录重大成就、品德、事迹（' + this.fBiography.length.toString() + '/500）')
        TextArea({ text: this.fBiography })
          .height(140)
          .fontSize(14)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .maxLength(500)
          .onChange((v: string): void => {
            this.fBiography = v;
          })
      }
      .width('100%')
      .margin({ bottom: Spacing.M })

      Column() {
        this.Label('墓葬信息', false, '地点、山向、碑文摘要（仅已故者填写）')
        TextArea({ text: this.fGraveInfo })
          .height(80)
          .fontSize(14)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .onChange((v: string): void => {
            this.fGraveInfo = v;
          })

        Column() {
          Row() {
            Text('经度（东经）').fontSize(11).fontColor(Theme.inkTertiary).layoutWeight(1)
          }
          .width('100%')
          TextInput({ text: this.fGraveLng !== 0 ? this.fGraveLng.toFixed(10) : '' })
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
            Text('纬度（北纬）').fontSize(11).fontColor(Theme.inkTertiary).layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 6 })
          TextInput({ text: this.fGraveLat !== 0 ? this.fGraveLat.toFixed(10) : '' })
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
            Text('海拔（米）').fontSize(11).fontColor(Theme.inkTertiary).layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 6 })
          TextInput({ text: this.fGraveAltitude !== 0 ? this.fGraveAltitude.toFixed(1) : '' })
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
            Text('地图定位信息 / 分享链接').fontSize(11).fontColor(Theme.inkTertiary).layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 6 })
          TextInput({ text: this.fGraveMapInfo, placeholder: '粘贴地图分享链接或“经度,纬度”' })
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
            Text(this.mapHint)
              .fontSize(10.5)
              .fontColor(Theme.inkTertiary)
              .width('100%')
              .margin({ top: 4 })
          }
          Row() {
            Text(this.locating ? '⏳ 正在定位…' : '📍 拾取当前位置')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .backgroundColor(Theme.alive)
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(14)
              .onClick((): void => {
                this.pickGraveLocation();
              })
            Text('🗺 地图应用拾取')
              .fontSize(12)
              .fontColor(Theme.primary)
              .backgroundColor(this.isDark ? '#3A3325' : '#F6E7C8')
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(14)
              .margin({ left: Spacing.S })
              .onClick((): void => {
                this.launchMapApp();
              })
            Blank()
            Text(this.fGraveLat !== 0 ? '已定位' : '未定位')
              .fontSize(11)
              .fontColor(this.fGraveLat !== 0 ? Theme.alive : Theme.inkTertiary)
          }
          .width('100%')
          .margin({ top: Spacing.S })
        }
        .width('100%')
        .padding(Spacing.M)
        .backgroundColor(this.isDark ? '#2A2722' : Theme.field)
        .borderRadius(10)
        .margin({ top: Spacing.S })
      }
      .width('100%')
      .margin({ bottom: Spacing.M })

      // 联系方式
      this.GroupHeader('联系方式', '📞')
      Row() {
        Text('🔒 以下为隐私字段，仅管理员可见')
          .fontSize(11)
          .fontColor(Theme.danger)
          .width('100%')
      }
      .margin({ bottom: Spacing.S })
      this.TextField('手机号', this.fPhone, '用于核实信息', false, (v: string): void => {
        this.fPhone = v;
      })
      this.TextField('微信号', this.fWechat, '用于建立家族群或电子族谱推送', false, (v: string): void => {
        this.fWechat = v;
      })

      // 照片视频：预览框 + “+” 添加（系统图库 / 文件管理器）
      Column() {
        Row() {
          Text('照片视频').fontSize(13).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
          Text(this.photoList().length > 0 ? '已添加 ' + this.photoList().length.toString() + ' 项' : '')
            .fontSize(11)
            .fontColor(Theme.inkTertiary)
            .margin({ left: Spacing.S })
          Blank()
          if (this.photoList().length > 0) {
            Text('清空')
              .fontSize(12)
              .fontColor(Theme.inkTertiary)
              .onClick((): void => {
                this.fPhotos = '';
              })
          }
        }
        .width('100%')

        Text('点击“+”从系统图库或文件管理器添加照片、视频')
          .fontSize(10.5)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .margin({ top: 1 })

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.photoList(), (uri: string, index: number) => {
            Stack({ alignContent: Alignment.TopEnd }) {
              if (this.isVideoUri(uri)) {
                Column() {
                  Text('🎬').fontSize(22)
                  Text('视频').fontSize(9).fontColor(Theme.inkTertiary)
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
              Text('×')
                .fontSize(11)
                .fontColor('#FFFFFF')
                .backgroundColor('#99000000')
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
            Text('+').fontSize(28).fontColor(Theme.primary)
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

  @Builder
  SidePreview() {
    Column() {
      Text('族谱预览').fontSize(13).fontColor(Theme.inkTertiary).width('100%')
      Column() {
        Text(this.fName.length > 0 ? this.fName : '未命名')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.fGender === '女' ? Theme.female : Theme.primary)
        Text(generationLabel(this.fGeneration) + ' · ' + (this.fUid.length > 0 ? this.fUid : 'ID 待生成') +
          (this.fGenChar.length > 0 ? ' · “' + this.fGenChar + '”字' : ''))
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 4 })
        Divider().color(Theme.line).margin({ top: 10, bottom: 10 })
        Text(this.previewLine('性别', this.fGender))
        Text(this.previewLine('在世状态', this.fLifeStatus))
        Text(this.previewLine('子女身份', this.fChildStatus === '未记' ? '' :
          childStatusLabel(this.fChildStatus, this.fGender)))
        Text(this.previewLine('出生', this.fBirthDate))
        Text(this.previewLine('逝世', this.fDeathDate))
        Text(this.previewLine('出生地', this.fBirthPlace))
        Text(this.previewLine('现居地', this.fResidence))
        Text(this.previewLine('父亲', this.relationValue(this.fFatherId)))
        Text(this.previewLine('母亲', this.relationValue(this.fMotherId)))
        Text(this.previewLine('配偶', this.spousesPreview()))
        Text(this.previewLine('排行', this.fRank))
        Text(this.previewLine('学历', this.fEducation))
        Text(this.previewLine('职业', this.fOccupation))
        if (this.fBiography.length > 0) {
          Text(this.fBiography)
            .fontSize(12)
            .lineHeight(20)
            .fontColor(Theme.inkSecondary)
            .margin({ top: 8 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(Spacing.L)
      .backgroundColor(Theme.card)
      .borderRadius(Radius.L)
      .border({ width: 0.5, color: Theme.line })
      .margin({ top: Spacing.S })
    }
    .width('100%')
  }

  private previewLine(label: string, value: string): string {
    return value.length > 0 ? label + '：' + value : '';
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
    Column() {
      // 顶栏
      Row() {
        BackButton({
          onBack: (): void => {
            this.getUIContext().getRouter().back();
          }
        })
        Text(this.originalUid.length > 0 ? '编辑族人' : (this.mode === 'child' ? '添加子女' : '新增族人'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
        if (this.originalUid.length > 0) {
          Text('删除')
            .fontSize(13)
            .fontColor(Theme.danger)
            .margin({ right: Spacing.M })
            .onClick((): void => {
              this.remove();
            })
        }
        Button(this.saving ? '保存中…' : '保存')
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
              this.SidePreview()
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
