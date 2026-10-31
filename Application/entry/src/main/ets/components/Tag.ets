/** 标签胶囊 */
@Component
export struct Tag {
  @Prop text: string;
  @Prop color: string;
  @Prop bg: string;
  @Prop dense: boolean = false;

  build() {
    Text(this.text)
      .fontSize(this.dense ? 10 : 11)
      .fontColor(this.color)
      .padding({ left: this.dense ? 5 : 7, right: this.dense ? 5 : 7, top: this.dense ? 1 : 2, bottom: this.dense ? 1 : 2 })
      .backgroundColor(this.bg)
      .borderRadius(6)
      .maxLines(1)
  }
}
