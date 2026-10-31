import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { TS } from '../components/TS';
import { PageNavBar } from '../components/PageNavBar';
import { GraveService } from '../service/GraveService';
import { GenealogyService } from '../service/GenealogyService';
import { Person } from '../model/Person';
import { GraveEntry, Role } from '../model/FamilyDomain';
import { RouterUtil } from '../util/RouterUtil';

/**
 * 祭祖寻墓（方案 §五.8、§七 GraveMap）。
 *
 * 数据来自**公开对象类型** FamilyGraveLocation：任意登录用户都能查到祖墓坐标，
 * 不要求先加入家族。同时本地缓存一份，山里没信号也能看（离线寻墓）。
 *
 * 谱主/编辑者录入墓葬前必须知情：坐标对任何人可见，且公开后无法撤回。
 */
@Entry
@Component
struct GraveMap {
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;
  @StorageProp('gpFamilyRole') role: string = '';

  @State keyword: string = '';
  @State onlyMine: boolean = true;
  @State graves: GraveEntry[] = [];
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

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    this.familyId = GenealogyService.getInstance().getBook().familyId;
    this.load();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.message = '';
    try {
      const scope: string = this.onlyMine && this.familyId.length > 0 ? this.familyId : '';
      this.graves = await GraveService.getInstance().loadPublic(scope, this.keyword);
      if (this.graves.length === 0) {
        this.message = this.onlyMine
          ? '本谱还没有公开的墓葬位置。谱主可在下方录入（录入前请知悉：坐标对任何登录用户可见）。'
          : '暂时没有查到祖墓位置记录。';
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
    const p: Person | null = GenealogyService.getInstance().getPerson(uid);
    if (p === null) {
      this.toast('本机没有该族人');
      return;
    }
    this.editingUid = uid;
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
      title: '录入前请确认',
      message: '祖墓坐标将作为公开数据，任何登录用户都能查到，且一旦公开无法撤回。' +
        '若家族不希望对外公开，请把可见性设为「仅族人可见」——此时该记录会从公开表中真正删除，而不是隐藏。',
      primaryButton: {
        value: '我已知悉，继续',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '取消',
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
      await GraveService.getInstance().updateGrave(this.familyId, this.editingUid, grave, this.editVisibility,
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
  GraveCard(g: GraveEntry) {
    Column() {
      Row() {
        Text(g.personName.length > 0 ? g.personName : g.uid)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
        Text(g.generation > 0 ? '第 ' + g.generation.toString() + ' 世' : '')
          .fontSize(11)
          .fontColor(Theme.gold)
      }
      .width('100%')
      if (g.bookTitle.length > 0) {
        Text('《' + g.bookTitle + '》')
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 2 })
          .width('100%')
      }
      if (g.graveName.length > 0) {
        Text('墓地：' + g.graveName)
          .fontSize(12.5)
          .fontColor(Theme.inkSecondary)
          .margin({ top: 4 })
          .width('100%')
      }
      Text('坐标：' + g.locationText() +
        (g.altitude !== 0 ? ' · 海拔 ' + Math.round(g.altitude).toString() + ' 米' : '') +
        (g.precision === 'BLURRED' ? '（已模糊至约30米）' : ''))
        .fontSize(11.5)
        .fontColor(Theme.inkSecondary)
        .margin({ top: 3 })
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
      if (g.facing.length > 0) {
        Text('朝向：' + g.facing)
          .fontSize(11.5)
          .fontColor(Theme.inkSecondary)
          .margin({ top: 2 })
          .width('100%')
      }
      if (g.routeNote.length > 0) {
        Text('寻墓路线：' + g.routeNote)
          .fontSize(11.5)
          .fontColor(Theme.inkSecondary)
          .margin({ top: 2 })
          .width('100%')
      }
      Row() {
        if (g.hasLocation()) {
          Button('导航前往')
            .fontSize(12.5)
            .height(32)
            .backgroundColor(Theme.primary)
            .fontColor('#FFFFFF')
            .onClick((): void => {
              RouterUtil.openMap(g.lng, g.lat, g.personName + ' 墓');
            })
        }
        Blank()
        Text('公开墓葬表 · 更新于 ' + new Date(g.updatedAt).toLocaleDateString())
          .fontSize(9.5)
          .fontColor(Theme.inkTertiary)
      }
      .width('100%')
      .margin({ top: Spacing.S })
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(Theme.card)
    .borderRadius(Radius.L)
    .border({ width: 0.5, color: Theme.line })
    .margin({ bottom: Spacing.M })
  }

  @Builder
  EditPanel() {
    Column() {
      Text('录入墓葬位置：' + this.editingUid)
        .fontSize(14)
        .fontColor(Theme.ink)
        .width('100%')
      Row() {
        TextInput({ text: this.editLng, placeholder: '经度 lng' })
          .height(34)
          .fontSize(12.5)
          .layoutWeight(1)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .onChange((v: string): void => {
            this.editLng = v;
          })
        TextInput({ text: this.editLat, placeholder: '纬度 lat' })
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
      TextInput({ text: this.editName, placeholder: '墓地名（如：XX村后山祖坟）' })
        .height(34)
        .fontSize(12.5)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: Spacing.S })
        .onChange((v: string): void => {
          this.editName = v;
        })
      TextInput({ text: this.editFacing, placeholder: '朝向（如：坐北朝南）' })
        .height(34)
        .fontSize(12.5)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: Spacing.S })
        .onChange((v: string): void => {
          this.editFacing = v;
        })
      TextInput({ text: this.editRoute, placeholder: '寻墓路线（如：过石桥左转第三座）' })
        .height(34)
        .fontSize(12.5)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: Spacing.S })
        .onChange((v: string): void => {
          this.editRoute = v;
        })
      Row() {
        Text('可见性')
          .fontSize(11.5)
          .fontColor(Theme.inkTertiary)
          .width(64)
        Text('公开')
          .fontSize(12)
          .fontColor(this.editVisibility === 'PUBLIC' ? '#FFFFFF' : Theme.inkSecondary)
          .backgroundColor(this.editVisibility === 'PUBLIC' ? Theme.primary : Theme.field)
          .borderRadius(10)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick((): void => {
            this.editVisibility = 'PUBLIC';
          })
        Text('仅族人可见')
          .fontSize(12)
          .fontColor(this.editVisibility === 'FAMILY_ONLY' ? '#FFFFFF' : Theme.inkSecondary)
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
        Text('精度')
          .fontSize(11.5)
          .fontColor(Theme.inkTertiary)
          .width(64)
        Text('精确')
          .fontSize(12)
          .fontColor(this.editPrecision === 'EXACT' ? '#FFFFFF' : Theme.inkSecondary)
          .backgroundColor(this.editPrecision === 'EXACT' ? Theme.primary : Theme.field)
          .borderRadius(10)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick((): void => {
            this.editPrecision = 'EXACT';
          })
        Text('模糊约30米')
          .fontSize(12)
          .fontColor(this.editPrecision === 'BLURRED' ? '#FFFFFF' : Theme.inkSecondary)
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
      TextInput({ text: this.editEvidence, placeholder: '位置变更依据（与旧记录相差>50米时必填）' })
        .height(34)
        .fontSize(12.5)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: Spacing.S })
        .onChange((v: string): void => {
          this.editEvidence = v;
        })
      Row() {
        Button('取消')
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .backgroundColor(Theme.field)
          .fontColor(Theme.inkSecondary)
          .onClick((): void => {
            this.editingUid = '';
          })
        Button(this.busy ? '保存中…' : '保存')
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .margin({ left: Spacing.S })
          .backgroundColor(Theme.primary)
          .fontColor('#FFFFFF')
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
        title: '祭祖寻墓',
        subtitle: '祖墓坐标公开 · 任意登录用户可查',
        busy: this.loading,
        onBack: (): void => {
          this.getUIContext().getRouter().back();
        }
      })
      Scroll() {
        Column() {
          Row() {
            TextInput({ text: this.keyword, placeholder: '人物名 / 谱名 / 墓地名' })
              .height(38)
              .fontSize(13.5)
              .layoutWeight(1)
              .backgroundColor(Theme.field)
              .borderRadius(10)
              .onChange((v: string): void => {
                this.keyword = v;
              })
            Button('查询')
              .fontSize(13)
              .height(38)
              .margin({ left: Spacing.S })
              .backgroundColor(Theme.primary)
              .fontColor('#FFFFFF')
              .onClick((): void => {
                this.load();
              })
          }
          .width('100%')
          Row() {
            Text('只看本谱')
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
            Toggle({ type: ToggleType.Switch, isOn: this.onlyMine })
              .selectedColor(Theme.primary)
              .margin({ left: 6 })
              .onChange((isOn: boolean): void => {
                this.onlyMine = isOn;
                this.load();
              })
            Blank()
            Text('离线可用：已读取的记录会缓存在本机')
              .fontSize(10)
              .fontColor(Theme.inkTertiary)
          }
          .width('100%')
          .margin({ top: Spacing.S, bottom: Spacing.M })

          if (this.canEdit()) {
            TS({ title: '录入墓葬位置', subtitle: '仅谱主/编辑者 · 需先在本机族人资料里录入过坐标', icon: '📍' })
            Column() {
              if (this.editingUid.length === 0) {
                Text('从本机族人中选择一位，把已有的坐标与墓葬说明发布到公开墓葬表（或改为仅族人可见）。')
                  .fontSize(11.5)
                  .fontColor(Theme.inkTertiary)
                  .width('100%')
                Scroll() {
                  Column() {
                    ForEach(GenealogyService.getInstance().getPeople(), (p: Person) => {
                      Row() {
                        Text(p.uid + '  ' + p.name)
                          .fontSize(12.5)
                          .fontColor(Theme.ink)
                          .layoutWeight(1)
                        Text(p.graveLng !== 0 ? '已有坐标' : '未录坐标')
                          .fontSize(10)
                          .fontColor(p.graveLng !== 0 ? Theme.alive : Theme.inkTertiary)
                          .margin({ right: Spacing.S })
                        Text('录入 ›')
                          .fontSize(11.5)
                          .fontColor(Theme.primary)
                          .onClick((): void => {
                            this.startEdit(p.uid);
                          })
                      }
                      .width('100%')
                      .padding({ top: 6, bottom: 6 })
                    }, (p: Person) => 'gsel_' + p.uid)
                  }
                  .width('100%')
                }
                .constraintSize({ maxHeight: 200 })
                .scrollBar(BarState.Off)
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
            Text(this.message)
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .padding(Spacing.M)
              .backgroundColor(Theme.highlightBg)
              .borderRadius(Radius.S)
              .margin({ bottom: Spacing.M })
          }
          ForEach(this.graves, (g: GraveEntry) => {
            this.GraveCard(g)
          }, (g: GraveEntry) => 'grave_' + g.graveId)

          Text('说明：墓葬位置属于公开数据（便于族人祭祖寻墓，不需要先加入家族）。谱主可对个别墓穴关闭公开或做约30米模糊处理；关闭后该记录会从公开表中真正移除。')
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .width('100%')
            .lineHeight(16)
          Column().height(60)
        }
        .width('100%')
        .padding(Spacing.L)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.paper)
  }
}
