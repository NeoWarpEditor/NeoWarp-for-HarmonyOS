/**
 * 折痕避让容器
 *
 * 三折叠 / 阔折叠展开态：折痕所在位置留 24vp 安全边距，
 * 关键控件不跨越折痕；折叠切换时只调整 padding，不重建子树。
 */

@Component
export struct FoldSafeLayout {
  @Prop safeLeft: number = 0;
  @Prop safeRight: number = 0;
  @Prop columns: number = 2;
  @Builder
  defaultContent() {}

  @BuilderParam content: () => void = this.defaultContent;

  build() {
    Row() {
      if (this.safeLeft > 0) {
        Row().width(this.safeLeft).height('100%')
      }
      this.content()
      if (this.safeRight > 0) {
        Row().width(this.safeRight).height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }
}
