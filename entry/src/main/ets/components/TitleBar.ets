/**
 * 顶部标题栏 · Apple Design 语言：克制的层级、细分隔线、无冗余装饰
 * PC 形态显示菜单与形态标签；紧凑形态只保留标题与离线徽章。
 */

@Component
export struct TitleBar {
  @Prop title: string = 'NeoWarp';
  @Prop formLabel: string = '平板';
  @Prop offline: boolean = true;
  @Prop showDesktopChrome: boolean = false;
  onAction: (id: string) => void = (_id: string) => {};

  build() {
    Row() {
      // 应用标识
      Row() {
        Text('N')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .width(26)
          .height(26)
          .textAlign(TextAlign.Center)
          .borderRadius(8)
          .linearGradient({
            angle: 135,
            colors: [['#0A84FF', 0.0], ['#5E5CE6', 1.0]]
          })
        Text(this.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .margin({ left: 10 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(0)

      Blank()

      if (this.showDesktopChrome) {
        this.menuButton($r('app.string.menu_file'), 'menu_file')
        this.menuButton($r('app.string.menu_edit'), 'menu_edit')
        this.menuButton($r('app.string.menu_view'), 'menu_view')
      }

      // 形态标签
      Text(this.formLabel)
        .fontSize(11)
        .fontColor($r('app.color.on_surface_secondary'))
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(6)
        .backgroundColor($r('app.color.surface_elevated'))
        .margin({ right: 8 })

      // 离线徽章：常驻可见，明确「完全离线」
      Row() {
        Circle({ width: 6, height: 6 }).fill($r('app.color.success'))
        Text($r('app.string.action_offline_badge'))
          .fontSize(11)
          .fontColor($r('app.color.success'))
          .margin({ left: 5 })
      }
      .padding({ left: 9, right: 9, top: 4, bottom: 4 })
      .borderRadius(7)
      .backgroundColor($r('app.color.surface_elevated'))
      .margin({ right: 10 })

      Image($r('app.media.ic_task_manager'))
        .width(20)
        .height(20)
        .fillColor($r('app.color.on_surface_secondary'))
        .onClick(() => this.onAction('task_manager'))
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 14 })
    .backgroundColor($r('app.color.surface'))
    .borderColor($r('app.color.divider'))
    .borderWidth({ bottom: 0.5 })
  }

  @Builder
  menuButton(label: Resource, id: string) {
    Text(label)
      .fontSize(12)
      .fontColor($r('app.color.on_surface_secondary'))
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .borderRadius(6)
      .onClick(() => this.onAction(id))
  }
}
