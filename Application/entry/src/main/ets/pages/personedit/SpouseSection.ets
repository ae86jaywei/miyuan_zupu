import { Person, SpouseRelation, SPOUSE_RELATIONS, T, Theme, Spacing, uiFontFamily,
  spouseRelationLabel, spouseRelationHint, childRankOfSpouseRelation } from 'common_base';
import { PersonPickerField, SelectField } from 'common_ui';
import { SR } from '../../service/ServiceRegistry';

/** 配偶关系编辑区：可增删多位配偶，并为每位选择名分 */
@Component
export struct SpouseSection {
  @Prop spouses: SpouseRelation[] = [];
  @Prop selfUid: string = '';
  onAdd: () => void = (): void => {
  };
  onRemove: (index: number) => void = (index: number): void => {
  };
  onChange: (index: number, uid: string, relation: string) => void =
    (index: number, uid: string, relation: string): void => {
    };

  /** 名分下拉文案：称谓（等级），keys 仍为 SPOUSE_RELATIONS */
  private relationOptions(): string[] {
    const labels: string[] = [];
    SPOUSE_RELATIONS.forEach((r: string): void => {
      labels.push(spouseRelationLabel(r));
    });
    return labels;
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text(T('配偶关系')).fontFamily(uiFontFamily()).fontSize(13).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
          Text(T('一夫一妻多妾制：正妻 / 平妻 / 贵妾 / 良妾 / 贱妾 / 外室，按先后顺序记录')).fontFamily(uiFontFamily())
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(T('+ 添加配偶')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(Theme.primary)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .border({ width: 1, color: Theme.primary })
          .onClick((): void => {
            this.onAdd();
          })
      }
      .width('100%')
      .margin({ bottom: Spacing.S })

      if (this.spouses.length === 0) {
        Text(T('尚未录入配偶')).fontFamily(uiFontFamily())
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .padding({ top: 6, bottom: 6 })
      }

      ForEach(this.spouses, (rel: SpouseRelation, idx: number) => {
        Column() {
          Row() {
            Column() {
              PersonPickerField({
                label: '配偶' + (idx + 1).toString(),
                hint: '点击搜索并选择配偶，不可选本人',
                value: rel.uid,
                excludeUid: this.selfUid,
                clearable: true,
                onValue: (v: string): void => {
                  this.onChange(idx, v, rel.relation);
                },
                onSearch: (k: string): Person[] => SR.genealogy().search(k),
                onResolve: (uid: string): Person | null => SR.genealogy().getPerson(uid)
              })
              SelectField({
                label: '名分',
                hint: '选择具体称谓，括号内为其名分等级',
                options: this.relationOptions(),
                keys: SPOUSE_RELATIONS,
                value: rel.relation,
                onValue: (v: string): void => {
                  this.onChange(idx, rel.uid, v);
                }
              })
            }
            .layoutWeight(1)

            Text(T('删除')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.danger)
              .padding({ left: Spacing.M, right: Spacing.S, top: 30, bottom: Spacing.M })
              .onClick((): void => {
                this.onRemove(idx);
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          // 名分含意提示：等级 / 地位 / 所生子女的宗法身份
          Text(T(spouseRelationHint(rel.relation))).fontFamily(uiFontFamily())
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .lineHeight(16)
            .width('100%')
          if (childRankOfSpouseRelation(rel.relation).length > 0) {
            Text(T('所生子女：' + childRankOfSpouseRelation(rel.relation))).fontFamily(uiFontFamily())
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
}
