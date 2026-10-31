import { Theme } from '../theme/Theme';
import { Person } from '../model/Person';
import { familyChar } from '../util/StringUtil';

/**
 * 人物头像：有头像用图片，否则用姓氏字做占位。
 */
@Component
export struct PersonAvatar {
  @Prop person: Person;
  @Prop avatarSize: number = 40;
  @Prop showRing: boolean = true;

  build() {
    Stack() {
      if (this.person !== undefined && this.person.avatar !== undefined && this.person.avatar.length > 0) {
        Image(this.person.avatar)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
      } else {
        Text(familyChar(this.person === undefined ? '' : this.person.name))
          .fontSize(this.avatarSize * 0.44)
          .fontColor(this.person !== undefined && this.person.gender === '女' ? Theme.female : Theme.primary)
          .fontWeight(FontWeight.Bold)
      }
    }
    .width(this.avatarSize)
    .height(this.avatarSize)
    .borderRadius(this.avatarSize / 2)
    .backgroundColor(Color.White)
    .clip(true)
    .border({
      width: this.showRing ? 1.5 : 0,
      color: this.person !== undefined && this.person.gender === '女' ? Theme.female : Theme.primary
    })
    .alignContent(Alignment.Center)
  }
}
