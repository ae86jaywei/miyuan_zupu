import { Person } from '../../model/Person';
import { Theme, Spacing } from '../../theme/Theme';
import { PersonAvatar } from '../PersonAvatar';
import { Tag } from '../Tag';
import { generationLabel } from '../../model/Enums';
import { lifeSpan, ageOf } from '../../util/DateUtil';
import { GenealogyService } from '../../service/GenealogyService';

/**
 * 现代创新式：卡片时间轴。
 * 以世代为轴，世代节点纵向排列，每个世代内以横向卡片（可换行）展示族人。
 */
@Component
export struct ModernTree {
  @Prop groups: Person[][];
  @Prop groupLabels: string[];
  @Prop highlightUid: string = '';
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;

  onDark(): void {
    Theme.use(this.darkMode);
  }
  @Prop minCardWidth: number = 150;
  onTapPerson: (uid: string) => void = (uid: string): void => {};

  private spouseName(p: Person): string {
    if (p.spouseId.length === 0) {
      return '';
    }
    const sp: Person | null = GenealogyService.getInstance().getPerson(p.spouseId);
    return sp === null ? '' : sp.name;
  }

  @Builder
  PersonCard(p: Person) {
    Column() {
      Row() {
        PersonAvatar({ person: p, avatarSize: 36, showRing: p.uid === this.highlightUid })
        Column() {
          Text(p.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(p.gender === '女' ? Theme.female : Theme.ink)
            .maxLines(1)
          Text(lifeSpan(p.birthDate, p.deathDate, p.lifeStatus).length > 0 ?
            lifeSpan(p.birthDate, p.deathDate, p.lifeStatus) : p.uid)
            .fontSize(10)
            .fontColor(Theme.inkTertiary)
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: Spacing.S })
      }
      .width('100%')

      Row() {
        Tag({ text: generationLabel(p.generation), color: '#FFFFFF', bg: Theme.primaryLight, dense: true })
        if (p.generationChar.length > 0) {
          Tag({ text: '字派 ' + p.generationChar, color: Theme.gold, bg: '#FBF4E2', dense: true }).margin({ left: 4 })
        }
        if (p.occupation.length > 0) {
          Tag({ text: p.occupation, color: Theme.inkSecondary, bg: Theme.field, dense: true }).margin({ left: 4 })
        }
      }
      .width('100%')
      .margin({ top: 6 })

      if (this.spouseName(p).length > 0) {
        Row() {
          Text('配偶').fontSize(9).fontColor(Theme.female)
          Text(this.spouseName(p))
            .fontSize(10)
            .fontColor(Theme.inkSecondary)
            .maxLines(1)
            .margin({ left: 4 })
        }
        .width('100%')
        .margin({ top: 4 })
      }

      if (p.biography.length > 0) {
        Text(p.biography)
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
          .width('100%')
      }
    }
    .padding(Spacing.M)
    .backgroundColor(p.uid === this.highlightUid ? Theme.highlightBg : Theme.card)
    .borderRadius(14)
    .border({ width: 0.5, color: p.uid === this.highlightUid ? Theme.gold : Theme.line })
    .shadow({ radius: 8, color: Theme.shadow, offsetY: 2 })
    .alignItems(HorizontalAlign.Start)
    .flexGrow(1)
    .flexBasis(this.minCardWidth)
    .constraintSize({ minWidth: this.minCardWidth })
    .onClick((): void => {
      this.onTapPerson(p.uid);
    })
  }

  build() {
    Row() {
      // 左侧时间轴
      Column() {
        ForEach(this.groups, (grp: Person[], gi: number) => {
          Column() {
            Stack() {
              Circle({ width: 14, height: 14 }).fill(Theme.primary)
              Circle({ width: 6, height: 6 }).fill(Color.White)
            }
            Row()
              .width(2)
              .layoutWeight(1)
              .backgroundColor(grp.length > 1 ? Theme.goldLight : Color.Transparent)
          }
          .width(16)
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
        }, (grp: Person[], gi: number) => 'axis_' + gi.toString())
      }
      .width(16)
      .alignItems(HorizontalAlign.Center)

      Column() {
        ForEach(this.groups, (grp: Person[], gi: number) => {
          Column() {
            Row() {
              Text(this.groupLabels[gi])
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.primary)
              Text(grp.length.toString() + ' 人')
                .fontSize(11)
                .fontColor(Theme.inkTertiary)
                .margin({ left: 6 })
            }
            .width('100%')
            .margin({ bottom: Spacing.S })

            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start }) {
              ForEach(grp, (p: Person) => {
                Column() {
                  this.PersonCard(p)
                }
                .padding({ right: 10, bottom: 10 })
              }, (p: Person) => 'mc_' + p.uid)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ bottom: Spacing.XL })
        }, (grp: Person[], gi: number) => 'mg_' + gi.toString())
      }
      .layoutWeight(1)
      .padding({ left: Spacing.M })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }
}