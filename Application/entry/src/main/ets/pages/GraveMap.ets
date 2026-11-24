import { T, uiFontFamily } from 'common_base';
import { SR } from '../service/ServiceRegistry';

import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Spacing, Radius } from 'common_base';
import { TS } from 'common_ui';
import { PageNavBar } from 'common_ui';
import { SearchField } from 'common_ui';
import { GraveService } from '../service/GraveService';

import { Person } from 'common_base';
import { GraveCardView } from '../features/GraveCardView';
import { GraveEntry, Role } from 'common_base';
import { RouterUtil } from 'common_base';
import { FlatListSource } from 'common_base';

/**
 * 祭祖寻墓（方案 §五.8、§七 GraveMap）。
 *
 * 数据来自 FamilyGraveLocation，**仅对已加入该家族的成员开放**：
 * 端侧经云函数 grave-list-public 读取，云端按 Membership 校验；
 * 未加入家族时页面不展示任何墓葬数据。同时本地缓存一份，山里没信号也能看（离线寻墓）。
 *
 * 谱主/编辑者录入墓葬前必须知情：坐标对本家族成员可见，且公开后无法撤回。
 */
@Entry
@Component
struct GraveMap {
  /** 订阅简繁设置：切换后重绘（T() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;
  @StorageProp('gpFamilyRole') @Watch('onRoleChange') role: string = '';

  @State keyword: string = '';
  /** 仅内部使用；列表渲染走 graveSource，避免状态变化触发整页重建 */
  private graves: GraveEntry[] = [];
  @State loading: boolean = false;
  @State message: string = '';
  @State familyId: string = '';
  /** 录入面板 */
  @State editingUid: string = '';
  @State editLng: string = '';
  @State editLat: string = '';
  @State editAltitude: string = '';
  @State editName: string = '';
  @State editFacing: string = '';
  @State editRoute: string = '';
  @State editVisibility: string = 'PUBLIC';
  @State editPrecision: string = 'EXACT';
  @State editEvidence: string = '';
  @State busy: boolean = false;
  /** 族人选择列表按需展开：避免进入页面就为全部族人创建 UI 导致主线程卡死 */
  @State pickerOpen: boolean = false;
  private graveSource: FlatListSource<GraveEntry> = new FlatListSource<GraveEntry>();
  private peopleSource: FlatListSource<Person> = new FlatListSource<Person>();

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  /** 加入家族 / 角色变化后立即重算可见性 */
  onRoleChange(): void {
    this.load();
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    this.familyId = SR.genealogy().getBook().familyId;
    // 只持有引用，不拷贝、不创建 UI；展开选择器时再由 LazyForEach 按需渲染
    this.peopleSource.setData(SR.genealogy().getPeople());
    this.load();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: T(message), duration: 2500 });
  }

  private joinedFamily(): boolean {
    return this.role.length > 0 && this.familyId.length > 0;
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.message = '';
    this.graves = [];
    this.graveSource.setData(this.graves);
    if (!this.joinedFamily()) {
      this.message = this.role.length === 0
        ? '祭祖寻墓仅对家族成员开放：请先在「我的家族」创建或加入家族。'
        : '当前族谱尚未接入云家族，加入家族后才能查看祭祖寻墓。';
      this.loading = false;
      return;
    }
    try {
      this.graves = await SR.grave().loadPublic(this.familyId, this.keyword);
      this.graveSource.setData(this.graves);
      if (this.graves.length === 0) {
        this.message = '本谱还没有可查看的墓葬位置。谱主可在下方录入（录入前请知悉：坐标仅家族成员可见）。';
      }
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.message = '读取失败：' + be.message;
    } finally {
      this.loading = false;
    }
  }

  private canEdit(): boolean {
    return this.role === Role.OWNER || this.role === Role.EDITOR;
  }

  /** 选中一位族人后，先做知情确认，再进入录入表单 */
  private startEdit(uid: string): void {
    const p: Person | null = SR.genealogy().getPerson(uid);
    if (p === null) {
      this.toast('本机没有该族人');
      return;
    }
    this.editingUid = uid;
    this.pickerOpen = false;
    this.editLng = p.graveLng !== 0 ? p.graveLng.toString() : '';
    this.editLat = p.graveLat !== 0 ? p.graveLat.toString() : '';
    this.editAltitude = p.graveAltitude !== 0 ? p.graveAltitude.toString() : '';
    this.editName = p.graveInfo;
    this.editFacing = '';
    this.editRoute = '';
    this.editEvidence = '';
    this.editVisibility = 'PUBLIC';
    this.editPrecision = 'EXACT';
    this.getUIContext().showAlertDialog({
      title: T('录入前请确认'),
      message: T('祖墓坐标将进入本家族的寻墓列表，家族成员都能查到，且一旦加入无法自动撤回。') +
        '若家族不希望出现在寻墓列表，请把可见性设为「仅族人可见」——此时该记录会从寻墓列表中真正移除（仍随族人资料同步给成员，而不是对任何人公开）。',
      primaryButton: {
        value: T('我已知悉，继续'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: T('取消'),
        action: (): void => {
          this.editingUid = '';
        }
      }
    });
  }

  private async submitGrave(): Promise<void> {
    if (this.busy || this.editingUid.length === 0) {
      return;
    }
    const lng: number = Number.parseFloat(this.editLng);
    const lat: number = Number.parseFloat(this.editLat);
    if (Number.isNaN(lng) || Number.isNaN(lat)) {
      this.toast('请填写正确的经纬度（可先用地图App取点后手填）');
      return;
    }
    this.busy = true;
    try {
      const grave: Record<string, Object> = {};
      grave['lng'] = lng;
      grave['lat'] = lat;
      grave['altitude'] = Number.parseFloat(this.editAltitude);
      grave['graveName'] = this.editName;
      grave['facing'] = this.editFacing;
      grave['routeNote'] = this.editRoute;
      await SR.grave().updateGrave(this.familyId, this.editingUid, grave, this.editVisibility,
        this.editPrecision, this.editEvidence);
      this.toast('墓葬位置已保存');
      this.editingUid = '';
      await this.load();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.toast('保存失败：' + be.message);
    } finally {
      this.busy = false;
    }
  }

  @Builder
  EditPanel() {
    Column() {
      Text(T('录入墓葬位置：' + this.editingUid)).fontFamily(uiFontFamily())
        .fontSize(14)
        .fontColor(Theme.ink)
        .width('100%')
      Row() {
        TextInput({ text: this.editLng, placeholder: T('经度 lng') }).fontFamily(uiFontFamily())
          .height(34)
          .fontSize(12.5)
          .layoutWeight(1)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .onChange((v: string): void => {
            this.editLng = v;
          })
        TextInput({ text: this.editLat, placeholder: T('纬度 lat') }).fontFamily(uiFontFamily())
          .height(34)
          .fontSize(12.5)
          .layoutWeight(1)
          .margin({ left: Spacing.S })
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .onChange((v: string): void => {
            this.editLat = v;
          })
      }
      .width('100%')
      .margin({ top: Spacing.S })
      TextInput({ text: this.editName, placeholder: T('墓地名（如：XX村后山祖坟）') }).fontFamily(uiFontFamily())
        .height(34)
        .fontSize(12.5)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: Spacing.S })
        .onChange((v: string): void => {
          this.editName = v;
        })
      TextInput({ text: this.editFacing, placeholder: T('朝向（如：坐北朝南）') }).fontFamily(uiFontFamily())
        .height(34)
        .fontSize(12.5)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: Spacing.S })
        .onChange((v: string): void => {
          this.editFacing = v;
        })
      TextInput({ text: this.editRoute, placeholder: T('寻墓路线（如：过石桥左转第三座）') }).fontFamily(uiFontFamily())
        .height(34)
        .fontSize(12.5)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: Spacing.S })
        .onChange((v: string): void => {
          this.editRoute = v;
        })
      Row() {
        Text(T('可见性')).fontFamily(uiFontFamily())
          .fontSize(11.5)
          .fontColor(Theme.inkTertiary)
          .width(64)
        Text(T('寻墓列表')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(this.editVisibility === 'PUBLIC' ? Theme.onPrimary : Theme.inkSecondary)
          .backgroundColor(this.editVisibility === 'PUBLIC' ? Theme.primary : Theme.field)
          .borderRadius(10)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick((): void => {
            this.editVisibility = 'PUBLIC';
          })
        Text(T('仅族人可见')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(this.editVisibility === 'FAMILY_ONLY' ? Theme.onPrimary : Theme.inkSecondary)
          .backgroundColor(this.editVisibility === 'FAMILY_ONLY' ? Theme.primary : Theme.field)
          .borderRadius(10)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .margin({ left: 6 })
          .onClick((): void => {
            this.editVisibility = 'FAMILY_ONLY';
          })
      }
      .width('100%')
      .margin({ top: Spacing.S })
      Row() {
        Text(T('精度')).fontFamily(uiFontFamily())
          .fontSize(11.5)
          .fontColor(Theme.inkTertiary)
          .width(64)
        Text(T('精确')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(this.editPrecision === 'EXACT' ? Theme.onPrimary : Theme.inkSecondary)
          .backgroundColor(this.editPrecision === 'EXACT' ? Theme.primary : Theme.field)
          .borderRadius(10)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick((): void => {
            this.editPrecision = 'EXACT';
          })
        Text(T('模糊约30米')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(this.editPrecision === 'BLURRED' ? Theme.onPrimary : Theme.inkSecondary)
          .backgroundColor(this.editPrecision === 'BLURRED' ? Theme.primary : Theme.field)
          .borderRadius(10)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .margin({ left: 6 })
          .onClick((): void => {
            this.editPrecision = 'BLURRED';
          })
      }
      .width('100%')
      .margin({ top: Spacing.S })
      TextInput({ text: this.editEvidence, placeholder: T('位置变更依据（与旧记录相差>50米时必填）') }).fontFamily(uiFontFamily())
        .height(34)
        .fontSize(12.5)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: Spacing.S })
        .onChange((v: string): void => {
          this.editEvidence = v;
        })
      Row() {
        Button(T('取消')).fontFamily(uiFontFamily())
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .backgroundColor(Theme.field)
          .fontColor(Theme.inkSecondary)
          .onClick((): void => {
            this.editingUid = '';
          })
        Button(T(this.busy ? '保存中…' : '保存')).fontFamily(uiFontFamily())
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .margin({ left: Spacing.S })
          .backgroundColor(Theme.primary)
          .fontColor(Theme.onPrimary)
          .enabled(!this.busy)
          .onClick((): void => {
            this.submitGrave();
          })
      }
      .width('100%')
      .margin({ top: Spacing.M })
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(Theme.card)
    .borderRadius(Radius.L)
    .border({ width: 0.5, color: Theme.line })
    .margin({ bottom: Spacing.M })
  }

  build() {
    Column() {
      PageNavBar({
        title: T('祭祖寻墓'),
        subtitle: '仅家族成员可查看 · 离线可查',
        busy: this.loading,
        onBack: (): void => {
          this.getUIContext().getRouter().back();
        }
      })
      List() {
        ListItem() {
          Column() {
            SearchField({
              text: this.keyword,
              placeholder: '人物名 / 谱名 / 墓地名',
              fontSize: 13.5,
              actionText: '查询',
              onChange: (v: string): void => {
                this.keyword = v;
              },
              onAction: (): void => {
                this.load();
              }
            })
            Row() {
              Text(T('范围：当前家族')).fontFamily(uiFontFamily())
                .fontSize(11.5)
                .fontColor(Theme.inkTertiary)
              Blank()
              Text(T('离线可用：已读取的记录会缓存在本机')).fontFamily(uiFontFamily())
                .fontSize(10)
                .fontColor(Theme.inkTertiary)
            }
            .width('100%')
            .margin({ top: Spacing.S, bottom: Spacing.M })

            if (!this.joinedFamily()) {
              Column() {
                Text(T('🔒 仅家族成员可见')).fontFamily(uiFontFamily())
                  .fontSize(13.5)
                  .fontColor(Theme.ink)
                  .width('100%')
                Text(T('祭祖寻墓不对外开放。请先在「我的家族」创建或使用加入码加入家族，加入后即可查看本家族祖墓位置。')).fontFamily(uiFontFamily())
                  .fontSize(11.5)
                  .fontColor(Theme.inkTertiary)
                  .lineHeight(17)
                  .width('100%')
                  .margin({ top: 4 })
                Button(T('去我的家族'))
                  .fontFamily(uiFontFamily())
                  .fontSize(13)
                  .height(34)
                  .backgroundColor(Theme.primary)
                  .fontColor(Theme.onPrimary)
                  .margin({ top: Spacing.M })
                  .onClick((): void => {
                    RouterUtil.familyHome(this.getUIContext());
                  })
              }
              .width('100%')
              .padding(Spacing.L)
              .backgroundColor(Theme.card)
              .borderRadius(Radius.L)
              .border({ width: 0.5, color: Theme.line })
              .margin({ bottom: Spacing.L })
            }

            if (this.canEdit()) {
              TS({ title: T('录入墓葬位置'), subtitle: '仅谱主/编辑者 · 需先在本机族人资料里录入过坐标', icon: '📍' })
              Column() {
                if (this.editingUid.length === 0) {
                  Text(T('从本机族人中选择一位，把已有的坐标与墓葬说明发布到本家族寻墓列表（或改为仅族人可见）。')).fontFamily(uiFontFamily())
                    .fontSize(11.5)
                    .fontColor(Theme.inkTertiary)
                    .width('100%')
                  Row() {
                    Text(T(this.pickerOpen ? '收起族人列表' : '展开族人列表选择')).fontFamily(uiFontFamily())
                      .fontSize(12)
                      .fontColor(Theme.primary)
                    Blank()
                    Text(T(this.peopleSource.totalCount().toString() + ' 人')).fontFamily(uiFontFamily())
                      .fontSize(10.5)
                      .fontColor(Theme.inkTertiary)
                  }
                  .width('100%')
                  .padding({ top: 8, bottom: 8 })
                  .onClick((): void => {
                    this.pickerOpen = !this.pickerOpen;
                  })
                  if (this.pickerOpen) {
                    List() {
                      LazyForEach(this.peopleSource, (p: Person) => {
                        ListItem() {
                          Row() {
                            Text(T(p.uid + '  ' + p.name)).fontFamily(uiFontFamily())
                              .fontSize(12.5)
                              .fontColor(Theme.ink)
                              .layoutWeight(1)
                            Text(T(p.graveLng !== 0 ? '已有坐标' : '未录坐标')).fontFamily(uiFontFamily())
                              .fontSize(10)
                              .fontColor(p.graveLng !== 0 ? Theme.alive : Theme.inkTertiary)
                              .margin({ right: Spacing.S })
                            Text(T('录入 ›')).fontFamily(uiFontFamily())
                              .fontSize(11.5)
                              .fontColor(Theme.primary)
                              .onClick((): void => {
                                this.startEdit(p.uid);
                              })
                          }
                          .width('100%')
                          .padding({ top: 6, bottom: 6 })
                        }
                      }, (p: Person) => 'gsel_' + p.uid)
                    }
                    .width('100%')
                    .height(200)
                    .cachedCount(4)
                    .scrollBar(BarState.Off)
                    .edgeEffect(EdgeEffect.None)
                  }
                } else {
                  this.EditPanel()
                }
              }
              .width('100%')
              .padding(Spacing.L)
              .backgroundColor(Theme.card)
              .borderRadius(Radius.L)
              .border({ width: 0.5, color: Theme.line })
              .margin({ bottom: Spacing.L })
            }

            if (this.message.length > 0) {
              Text(T(this.message)).fontFamily(uiFontFamily())
                .fontSize(12)
                .fontColor(Theme.inkSecondary)
                .width('100%')
                .padding(Spacing.M)
                .backgroundColor(Theme.highlightBg)
                .borderRadius(Radius.S)
                .margin({ bottom: Spacing.M })
            }
          }
          .width('100%')
        }

        LazyForEach(this.graveSource, (g: GraveEntry) => {
          ListItem() {
            GraveCardView({ g: g })
          }
        }, (g: GraveEntry) => 'grave_' + g.graveId)

        ListItem() {
          Column() {
            Text(T('说明：墓葬位置仅对已加入本家族的成员可见，未加入家族的用户无法查看。谱主可对个别墓穴关闭展示或做约30米模糊处理；关闭后该记录会从寻墓列表中真正移除。')).fontFamily(uiFontFamily())
              .fontSize(10.5)
              .fontColor(Theme.inkTertiary)
              .width('100%')
              .lineHeight(16)
            Column().height(60)
          }
          .width('100%')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L })
      .cachedCount(3)
      .contentEndOffset(16)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.paper)
  }
}
