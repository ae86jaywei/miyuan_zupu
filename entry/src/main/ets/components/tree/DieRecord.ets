import { Person } from '../../model/Person';
import { Theme, Spacing } from '../../theme/Theme';
import { generationLabel } from '../../model/Enums';
import { parseYear } from '../../util/DateUtil';
import { Tag } from '../Tag';
import { GenealogyService } from '../../service/GenealogyService';

/**
 * 牒记式谱：按世序逐人编记，一人一条，文字为体，内容详备。
 */
@Component
export struct DieRecord {
  @Prop person: Person;
  @Prop index: number = 0;
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;

  onDark(): void {
    Theme.use(this.darkMode);
  }
  @Prop showPrivate: boolean = false;
  @Prop highlight: boolean = false;
  onTapPerson: (uid: string) => void = (uid: string): void => {};

  private spouseText(): string {
    return GenealogyService.getInstance().spouseTextOf(this.person.uid);
  }

  private line(prefix: string, value: string): string {
    return value.length > 0 ? prefix + value + '。' : '';
  }

  build() {
    Column() {
      Row() {
        Text(this.person.name)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.person.gender === '女' ? Theme.female : Theme.primary)
        Text('（' + this.person.uid + '）')
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .margin({ left: 4, top: 4 })
        Blank()
        Text(generationLabel(this.person.generation) + (this.person.generationChar.length > 0 ?
          ' · “' + this.person.generationChar + '”字' : ''))
          .fontSize(11)
          .fontColor(Theme.gold)
      }
      .width('100%')

      if (this.spouseText().length > 0) {
        Text('配偶：' + this.spouseText())
          .fontSize(12)
          .fontColor(Theme.female)
          .margin({ top: 2 })
          .width('100%')
      }

      if (this.person.alias.length > 0) {
        Text('曾用名/小名：' + this.person.alias)
          .fontSize(12)
          .fontColor(Theme.inkSecondary)
          .margin({ top: 2 })
          .width('100%')
      }

      Text(this.buildParagraph())
        .fontSize(13.5)
        .lineHeight(23)
        .fontColor(Theme.ink)
        .margin({ top: 6 })
        .width('100%')

      Row() {
        Tag({
          text: this.person.lifeStatus,
          color: this.person.lifeStatus === '已故' ? Theme.deceased : Theme.alive,
          bg: this.person.lifeStatus === '已故' ? Theme.field : '#E6F3EC'
        })
        if (this.person.rank.length > 0) {
          Tag({ text: this.person.rank, color: Theme.primary, bg: Theme.highlightBg }).margin({ left: 6 })
        }
        if (this.person.adoption.length > 0) {
          Tag({ text: this.person.adoption, color: Theme.lost, bg: '#FBF0DC' }).margin({ left: 6 })
        }
        if (this.person.graveLat !== 0) {
          Tag({ text: '有墓葬定位', color: Theme.alive, bg: '#E6F3EC' }).margin({ left: 6 })
        }
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(this.highlight ? Theme.highlightBg : Theme.card)
    .borderRadius(12)
    .border({ width: 0.5, color: Theme.line, style: BorderStyle.Dashed })
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      this.onTapPerson(this.person.uid);
    })
  }

  private buildParagraph(): string {
    const p: Person = this.person;
    // 用“分段拼接”代替逐字加标点，避免出现“男。。，长子。。”这类重复标点
    const head: string[] = [];
    head.push(p.gender === '女' ? '女' : '男');
    if (p.rank.length > 0) {
      head.push(p.rank);
    }
    const by: number = parseYear(p.birthDate);
    const dy: number = parseYear(p.deathDate);
    if (by > 0) {
      head.push(by.toString() + '年' + (p.birthCalendar === '农历' ? '（农历）' : '') + '生');
    }
    if (dy > 0) {
      head.push(dy.toString() + '年' + (p.deathCalendar === '农历' ? '（农历）' : '') + '卒');
    }
    if (p.lifeStatus === '失联') {
      head.push('失联');
    }
    let s: string = head.join('，') + '。';

    const detail: string[] = [];
    if (p.birthPlace.length > 0) {
      detail.push('籍贯：' + p.birthPlace);
    }
    if (p.residence.length > 0) {
      detail.push('居：' + p.residence);
    }
    if (p.education.length > 0) {
      detail.push('学业：' + p.education);
    }
    if (p.occupation.length > 0) {
      detail.push('职业：' + p.occupation);
    }
    if (detail.length > 0) {
      s = s + detail.join('。') + '。';
    }
    if (p.biography.length > 0) {
      s = s + p.biography;
      if (!p.biography.endsWith('。')) {
        s = s + '。';
      }
    }
    if (p.graveInfo.length > 0) {
      s = s + '墓葬：' + p.graveInfo;
      if (!p.graveInfo.endsWith('。')) {
        s = s + '。';
      }
    }
    if (this.showPrivate) {
      if (p.phone.length > 0) {
        s = s + '电话：' + p.phone + '。';
      }
      if (p.wechat.length > 0) {
        s = s + '微信：' + p.wechat + '。';
      }
    }
    return s.length === 0 ? '（生平行实待补）' : s;
  }
}