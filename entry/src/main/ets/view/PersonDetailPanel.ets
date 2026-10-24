import { Person, SpouseRelation, spouseRelationLabel, childStatusLabel, childStatusHint, CONCUBINE_CHILD_TITLE_HINT } from '../model/Person';
import { PersonAvatar } from '../components/PersonAvatar';
import { Tag } from '../components/Tag';
import { InfoRow } from '../components/InfoRow';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { generationLabel } from '../model/Enums';
import { lifeSpan, ageOf, displayDate } from '../util/DateUtil';
import { GenealogyService } from '../service/GenealogyService';
import { EmptyHint } from '../components/EmptyHint';

/**
 * 人物详情面板：展示《关键信息字段》全部字段；
 * 宽屏下作为主从布局的右栏，窄屏下作为全屏对话框。
 */
@Component
export struct PersonDetailPanel {
  @Prop uid: string;
  @Prop showPrivate: boolean = true;
  @Prop narrow: boolean = false;
  onEdit: (uid: string) => void = (uid: string): void => {};
  onClose: () => void = (): void => {};
  onJump: (uid: string) => void = (uid: string): void => {};
  onAddChild: (uid: string) => void = (uid: string): void => {};

  private person(): Person | null {
    return GenealogyService.getInstance().getPerson(this.uid);
  }

  private avatarSize(): number {
    return this.narrow ? 56 : 64;
  }

  @Builder
  RelationChip(p: Person, relation: string) {
    Column() {
      PersonAvatar({ person: p, avatarSize: 34, showRing: false })
      Text(p.name)
        .fontSize(11)
        .fontColor(Theme.ink)
        .maxLines(1)
        .margin({ top: 3 })
      Text(relation)
        .fontSize(9)
        .fontColor(Theme.gold)
    }
    .padding(6)
    .borderRadius(Radius.S)
    .backgroundColor(Theme.field)
    .margin({ right: 8, bottom: 8 })
    .onClick((): void => {
      this.onJump(p.uid);
    })
  }

  @Builder
  GroupHeader(title: string) {
    Row() {
      Row().width(3).height(13).backgroundColor(Theme.gold).borderRadius(2)
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.primary)
        .margin({ left: 6 })
    }
    .width('100%')
    .margin({ top: Spacing.L, bottom: Spacing.XS })
  }

  build() {
    Column() {
      if (this.person() === null) {
        EmptyHint({ icon: '🔍', title: '请选择一位族人', desc: '在谱系图中点击任意人物卡片查看详情' })
      } else {
        Column() {
          // 头部
          Row() {
            PersonAvatar({ person: this.person() as Person, avatarSize: this.avatarSize() })
            Column() {
              Row() {
                Text((this.person() as Person).name)
                  .fontSize(this.narrow ? 20 : 22)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.ink)
                if ((this.person() as Person).gender === '女') {
                  Tag({ text: '女', color: Theme.female, bg: '#FCEEF2' }).margin({ left: 6 })
                }
                Tag({
                  text: (this.person() as Person).lifeStatus,
                  color: (this.person() as Person).lifeStatus === '已故' ? Theme.deceased : Theme.alive,
                  bg: (this.person() as Person).lifeStatus === '已故' ? Theme.field : '#E6F3EC'
                }).margin({ left: 6 })
              }
              Text(generationLabel((this.person() as Person).generation)
                + ((this.person() as Person).generationChar.length > 0 ?
                  ' · “' + (this.person() as Person).generationChar + '”字' : '')
                + ' · ' + (this.person() as Person).uid)
                .fontSize(11.5)
                .fontColor(Theme.inkTertiary)
                .margin({ top: 4 })
              Text(this.lifeText())
                .fontSize(12)
                .fontColor(Theme.inkSecondary)
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: Spacing.M })

            if (this.narrow) {
              Text('✕')
                .fontSize(16)
                .fontColor(Theme.inkTertiary)
                .padding(6)
                .onClick((): void => {
                  this.onClose();
                })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          // 快捷操作
          Row() {
            this.ActionButton('✎ 编辑', Theme.primary, (): void => {
              this.onEdit(this.uid);
            })
            this.ActionButton('＋ 添加子女', Theme.alive, (): void => {
              this.onAddChild(this.uid);
            })
            this.ActionButton('⇱ 共' + this.childCount().toString() + '子', Theme.inkSecondary, (): void => {
            })
          }
          .width('100%')
          .margin({ top: Spacing.M })

          Scroll() {
            Column() {
              // 身份标识
              this.GroupHeader('身份标识')
              InfoRow({ label: '世代', value: generationLabel((this.person() as Person).generation) })
              InfoRow({ label: '唯—ID', value: (this.person() as Person).uid })
              InfoRow({ label: '谱名', value: (this.person() as Person).name })
              if ((this.person() as Person).alias.length > 0) {
                InfoRow({ label: '曾用名/小名', value: (this.person() as Person).alias })
              }
              InfoRow({ label: '性别', value: (this.person() as Person).gender })
              if ((this.person() as Person).generationChar.length > 0) {
                InfoRow({ label: '辈分/字派', value: (this.person() as Person).generationChar })
              }
              InfoRow({ label: '在世状态', value: (this.person() as Person).lifeStatus })
              if ((this.person() as Person).childStatus.length > 0
                && (this.person() as Person).childStatus !== '未记') {
                InfoRow({
                  label: '子女身份',
                  value: childStatusLabel((this.person() as Person).childStatus, (this.person() as Person).gender)
                })
                Column() {
                  Text(childStatusHint((this.person() as Person).childStatus))
                    .fontSize(11)
                    .lineHeight(17)
                    .fontColor(Theme.inkTertiary)
                    .width('100%')
                  if (this.isConcubineChild()) {
                    Text(CONCUBINE_CHILD_TITLE_HINT)
                      .fontSize(11)
                      .lineHeight(17)
                      .fontColor(Theme.gold)
                      .width('100%')
                      .margin({ top: 2 })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding({ left: 84, bottom: 6 })
              }

              // 时间信息
              this.GroupHeader('时间信息')
              if ((this.person() as Person).birthDate.length > 0) {
                InfoRow({
                  label: '出生日期',
                  value: displayDate((this.person() as Person).birthDate, (this.person() as Person).birthCalendar)
                })
              }
              if ((this.person() as Person).deathDate.length > 0) {
                InfoRow({
                  label: '逝世日期',
                  value: displayDate((this.person() as Person).deathDate, (this.person() as Person).deathCalendar)
                })
              }
              if ((this.person() as Person).birthPlace.length > 0) {
                InfoRow({ label: '出生地', value: (this.person() as Person).birthPlace })
              }
              if ((this.person() as Person).residence.length > 0) {
                InfoRow({ label: '现居地', value: (this.person() as Person).residence })
              }

              // 亲属关系
              this.GroupHeader('亲属关系')
              InfoRow({
                label: '父亲',
                value: this.relationText((this.person() as Person).fatherId)
              })
              InfoRow({
                label: '母亲',
                value: this.relationText((this.person() as Person).motherId)
              })
              if ((this.person() as Person).spouses.length > 0) {
                InfoRow({ label: '配偶', value: this.spouseInfoText() })
              }
              if ((this.person() as Person).rank.length > 0) {
                InfoRow({ label: '排行', value: (this.person() as Person).rank })
              }
              if ((this.person() as Person).adoption.length > 0) {
                InfoRow({ label: '过继/出嗣', value: (this.person() as Person).adoption })
              }

              if (this.relativeChips().length > 0) {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.relativeChips(), (item: RelationChipData) => {
                    this.RelationChip(item.person, item.relation)
                  }, (item: RelationChipData) => 'rel_' + item.relation + item.person.uid)
                }
                .width('100%')
                .margin({ top: Spacing.S })
              }

              // 生平履历
              this.GroupHeader('生平履历')
              if ((this.person() as Person).education.length > 0) {
                InfoRow({ label: '学历/学位', value: (this.person() as Person).education })
              }
              if ((this.person() as Person).occupation.length > 0) {
                InfoRow({ label: '职业/职务', value: (this.person() as Person).occupation })
              }
              if ((this.person() as Person).biography.length > 0) {
                Column() {
                  Text('生平简介')
                    .fontSize(12.5)
                    .fontColor(Theme.inkTertiary)
                    .width('100%')
                  Text((this.person() as Person).biography)
                    .fontSize(13.5)
                    .lineHeight(22)
                    .fontColor(Theme.ink)
                    .margin({ top: 4 })
                    .width('100%')
                    .copyOption(CopyOptions.LocalDevice)
                }
                .width('100%')
                .margin({ top: 6 })
              }
              if ((this.person() as Person).graveInfo.length > 0 || (this.person() as Person).graveLat !== 0) {
                Column() {
                  Text('墓葬信息')
                    .fontSize(12.5)
                    .fontColor(Theme.inkTertiary)
                    .width('100%')
                  if ((this.person() as Person).graveInfo.length > 0) {
                    Text((this.person() as Person).graveInfo)
                      .fontSize(13.5)
                      .lineHeight(22)
                      .fontColor(Theme.ink)
                      .margin({ top: 4 })
                      .width('100%')
                  }
                  if ((this.person() as Person).graveLat !== 0) {
                    Row() {
                      Text('📍 GPS')
                        .fontSize(11)
                        .fontColor(Theme.alive)
                      Text('东经 ' + (this.person() as Person).graveLng.toFixed(6) + '° · 北纬 '
                        + (this.person() as Person).graveLat.toFixed(6) + '° · 海拔 '
                        + (this.person() as Person).graveAltitude.toFixed(1) + 'm')
                        .fontSize(11)
                        .fontColor(Theme.inkSecondary)
                        .margin({ left: 6 })
                    }
                    .padding(8)
                    .backgroundColor('#EAF4EE')
                    .borderRadius(Radius.S)
                    .margin({ top: 6 })
                    .width('100%')
                  }
                }
                .width('100%')
                .margin({ top: 6 })
              }

              // 联系方式（隐私）
              if (this.showPrivate) {
                this.GroupHeader('联系方式（隐私）')
                if ((this.person() as Person).phone.length > 0) {
                  InfoRow({ label: '手机号', value: maskPhone((this.person() as Person).phone), privacy: true })
                }
                if ((this.person() as Person).wechat.length > 0) {
                  InfoRow({ label: '微信号', value: (this.person() as Person).wechat, privacy: true })
                }
                if ((this.person() as Person).phone.length === 0 && (this.person() as Person).wechat.length === 0) {
                  InfoRow({ label: '联系方式', value: '未填写', valueColor: Theme.inkTertiary })
                }
              }

              // 图像
              this.GroupHeader('图像信息')
              Column() {
                PersonAvatar({ person: this.person() as Person, avatarSize: 96 })
                Text((this.person() as Person).avatar.length > 0 ? '已设置头像' : '使用姓氏字为默认头像')
                  .fontSize(11)
                  .fontColor(Theme.inkTertiary)
                  .margin({ top: 6 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .margin({ top: Spacing.S, bottom: 80 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: Spacing.L, right: Spacing.L })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: this.narrow ? Spacing.M : 0 })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ActionButton(label: string, color: string, action: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor(color)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(14)
      .border({ width: 1, color: color })
      .margin({ right: 8 })
      .onClick((): void => {
        action();
      })
  }

  private childCount(): number {
    if (this.person() === null) {
      return 0;
    }
    return GenealogyService.getInstance().childrenOf(this.uid).length;
  }

  private relationText(id: string): string {
    if (id === undefined || id.trim().length === 0) {
      return '未录入';
    }
    const p: Person | null = GenealogyService.getInstance().getPerson(id);
    if (p === null) {
      return id + '（该ID未录入）';
    }
    return p.name + '（' + p.uid + '）';
  }

  /** 庶出 / 婢生 / 奸生 需提示礼法称谓 */
  private isConcubineChild(): boolean {
    const p: Person | null = this.person();
    if (p === null) {
      return false;
    }
    return p.childStatus === '庶出' || p.childStatus === '婢生' || p.childStatus === '奸生';
  }

  /** 全部配偶及名分，如：“元配（正妻）：林氏（M001，子女 2）” */
  private spouseInfoText(): string {
    const svc: GenealogyService = GenealogyService.getInstance();
    const parts: string[] = [];
    svc.spousesOf(this.uid).forEach((r: SpouseRelation): void => {
      const sp: Person | null = svc.getPerson(r.uid);
      const childCount: number = svc.childrenWithSpouse(this.uid, r.uid).length;
      const childText: string = childCount > 0 ? '，子女 ' + childCount.toString() : '';
      const nameText: string = sp === null ? r.uid + '（该ID未录入）' :
        sp.name + '（' + sp.uid + childText + '）';
      const rel: string = r.relation.length > 0 ? spouseRelationLabel(r.relation) : '配偶';
      parts.push(rel + '：' + nameText);
    });
    return parts.join('；');
  }

  private lifeText(): string {
    const p: Person | null = this.person();
    if (p === null) {
      return '';
    }
    const span: string = lifeSpan(p.birthDate, p.deathDate, p.lifeStatus);
    const age: number = ageOf(p.birthDate, p.deathDate, p.lifeStatus);
    const ageText: string = age < 0 ? '' : (p.lifeStatus === '已故' ? ' 享年' + age.toString() + '岁' : ' ' + age.toString() + '岁');
    if (span.length === 0) {
      return p.lifeStatus === '在世' ? '生卒未详' : '';
    }
    return span + ageText;
  }

  private relativeChips(): RelationChipData[] {
    const list: RelationChipData[] = [];
    const svc: GenealogyService = GenealogyService.getInstance();
    const father: Person | null = svc.getPerson((this.person() as Person).fatherId);
    const mother: Person | null = svc.getPerson((this.person() as Person).motherId);
    if (father !== null) {
      list.push({ person: father, relation: '父' });
    }
    if (mother !== null) {
      list.push({ person: mother, relation: '母' });
    }
    svc.spousesOf(this.uid).forEach((r: SpouseRelation): void => {
      const sp: Person | null = svc.getPerson(r.uid);
      if (sp !== null) {
        list.push({ person: sp, relation: r.relation.length > 0 ? r.relation : '配偶' });
      }
    });
    svc.siblingsOf(this.uid).forEach((p: Person): void => {
      list.push({ person: p, relation: p.gender === '女' ? '姊妹' : '兄弟' });
    });
    svc.childrenOf(this.uid).forEach((p: Person): void => {
      list.push({ person: p, relation: p.gender === '女' ? '女' : '子' });
    });
    return list;
  }
}

export class RelationChipData {
  person: Person = new Person();
  relation: string = '';
}

export function maskPhone(phone: string): string {
  if (phone === undefined || phone.length < 7) {
    return phone;
  }
  return phone.substring(0, 3) + '****' + phone.substring(phone.length - 4);
}