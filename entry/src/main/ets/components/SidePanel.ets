/**
 * 侧边操作栏：新建/打开/保存/打包/设置/插件/任务管理器
 * PC 与平板横屏常驻；紧凑与折叠合盖态收起为浮层（由 Index 控制显隐）。
 */

interface MenuEntry {
  id: string;
  label: Resource;
  shortcut: string;
}

@Component
export struct SidePanel {
  @Prop visible: boolean = true;
  @Prop widthVp: number = 260;
  onSelect: (id: string) => void = (_id: string) => {};

  private entries: MenuEntry[] = [
    { id: 'new', label: $r('app.string.action_new'), shortcut: 'Ctrl+N' },
    { id: 'open', label: $r('app.string.action_open'), shortcut: 'Ctrl+O' },
    { id: 'save', label: $r('app.string.action_save'), shortcut: 'Ctrl+S' },
    { id: 'packager', label: $r('app.string.action_packager'), shortcut: 'Ctrl+P' },
    { id: 'settings', label: $r('app.string.action_settings'), shortcut: '' },
    { id: 'addons', label: $r('app.string.action_addons'), shortcut: '' },
    { id: 'task_manager', label: $r('app.string.action_task_manager'), shortcut: 'Ctrl+Shift+M' }
  ];

  build() {
    if (this.visible) {
      Column() {
        Text('NEOWARP')
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface_secondary'))
          .letterSpacing(1.2)
          .margin({ left: 16, top: 18, bottom: 10 })

        ForEach(this.entries, (item: MenuEntry) => {
          Row() {
            Text(item.label)
              .fontSize(13)
              .fontColor($r('app.color.on_surface'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (item.shortcut.length > 0) {
              Text(item.shortcut)
                .fontSize(10)
                .fontColor($r('app.color.on_surface_secondary'))
            }
          }
          .width('100%')
          .height(40)
          .padding({ left: 14, right: 12 })
          .borderRadius(8)
          .stateStyles({
            normal: { .backgroundColor($r('app.color.surface')) },
            pressed: { .backgroundColor($r('app.color.surface_elevated')) }
          })
          .onClick(() => this.onSelect(item.id))
        }, (item: MenuEntry) => item.id)

        Blank()

        // 离线说明
        Column() {
          Text('全部素材 · 扩展 · 字体随包内置')
            .fontSize(11)
            .fontColor($r('app.color.on_surface_secondary'))
          Text('运行时零网络请求')
            .fontSize(11)
            .fontColor($r('app.color.success'))
            .margin({ top: 4 })
        }
        .width('100%')
        .padding(14)
        .alignItems(HorizontalAlign.Start)
      }
      .width(this.widthVp)
      .height('100%')
      .backgroundColor($r('app.color.surface'))
      .borderColor($r('app.color.divider'))
      .borderWidth({ right: 0.5 })
    }
  }
}
