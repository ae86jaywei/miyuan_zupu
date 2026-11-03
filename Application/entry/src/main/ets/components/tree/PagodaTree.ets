import { PersonNode } from '../../model/PersonNode';
import { Theme } from '../../theme/Theme';
import { PersonAvatar } from '../PersonAvatar';
import { generationLabel } from '../../model/Enums';
import { GenealogyService } from '../../service/GenealogyService';

/**
 * 宝塔式谱：上窄下宽，始祖居塔尖，子孙逐代向两侧对称展开。
 * 每一代为一个“层”，层内成员平均分布，层与层之间以金色腰线分割。
 *
 * 不接收 PersonNode[][] 作为 @Prop（环状结构会被深拷贝），
 * 改为接收宗支 uid 列表，在组件内按 version 重建分层数据。
 */
@Component
export struct PagodaTree {
  @Prop @Watch('onChanged') rootUids: string[] = [];
  @Prop @Watch('onChanged') layoutVersion: number = 0;
  @Prop highlightUid: string = '';
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  @Prop compact: boolean = true;
  @State rows: PersonNode[][] = [];
  onTapPerson: (uid: string) => void = (uid: string): void => {};

  aboutToAppear(): void {
    this.rebuildRows();
  }

  onDark(): void {
    Theme.use(this.darkMode);
  }

  onChanged(): void {
    this.rebuildRows();
  }

  private rebuildRows(): void {
    if (this.rootUids.length === 0) {
      this.rows = [];
      return;
    }
    const rows: PersonNode[][] = [];
    const walk = (node: PersonNode): void => {
      const idx: number = node.person.generation - 1;
      while (rows.length <= idx) {
        rows.push([]);
      }
      const exists: boolean = rows[idx].some((n: PersonNode): boolean => n.uid === node.uid);
      if (!exists) {
        rows[idx].push(node);
      }
      node.children.forEach((c: PersonNode): void => {
        walk(c);
      });
    };
    GenealogyService.getInstance().getRoots().forEach((r: PersonNode): void => {
      if (this.rootUids.indexOf(r.uid) >= 0) {
        walk(r);
      }
    });
    this.rows = rows;
  }

  build() {
    Column() {
      ForEach(this.rows, (row: PersonNode[], gi: number) => {
        Column() {
          Row() {
            Text(generationLabel(row.length > 0 ? row[0].person.generation : gi + 1) +
              ' · ' + row.length.toString() + '人')
              .fontSize(10)
              .fontColor(Theme.primary)
              .backgroundColor(Theme.highlightBg)
              .borderRadius(8)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ bottom: 4 })

          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
            ForEach(row, (node: PersonNode) => {
              Column() {
                Stack() {
                  PersonAvatar({ person: node.person, avatarSize: this.compact ? 22 : 26, showRing: node.uid === this.highlightUid })
                }
                .width(this.compact ? 24 : 28)
                .height(this.compact ? 24 : 28)

                Text(node.person.name)
                  .fontSize(this.compact ? 11 : 12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(node.person.gender === '女' ? Theme.female : Theme.ink)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 2 })
                  .width(this.compact ? 56 : 68)
                  .textAlign(TextAlign.Center)

                // 世代徽标
                Text(generationLabel(node.person.generation))
                  .fontSize(8)
                  .fontColor('#FFFFFF')
                  .backgroundColor(node.person.gender === '女' ? Theme.female : Theme.primaryLight)
                  .borderRadius(3)
                  .padding({ left: 3, right: 3 })
                  .margin({ top: 1 })

                // 关联配偶
                if (node.spouseText().length > 0) {
                  Text(node.spouseText())
                    .fontSize(8)
                    .fontColor(Theme.female)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width(this.compact ? 56 : 68)
                    .textAlign(TextAlign.Center)
                    .margin({ top: 1 })
                    .onClick((): void => {
                      if (node.spouse !== null) {
                        this.onTapPerson((node.spouse as PersonNode).uid);
                      }
                    })
                }
              }
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 4, bottom: 4, left: 2, right: 2 })
              .backgroundColor(node.uid === this.highlightUid ? Theme.highlightBg : Color.Transparent)
              .borderRadius(8)
              .onClick((): void => {
                this.onTapPerson(node.uid);
              })
            }, (node: PersonNode) => 'pg_' + node.uid)
          }
          .width('100%')

          // 腰线：宽度随层级递增，形成塔身轮廓
          Row()
            .width((70 + Math.min(gi * 6, 30)).toString() + '%')
            .height(1)
            .backgroundColor(Theme.goldLight)
            .margin({ top: 6, bottom: 6 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }, (row: PersonNode[], gi: number) => 'gen_' + gi.toString())
    }
    .width('100%')
  }
}