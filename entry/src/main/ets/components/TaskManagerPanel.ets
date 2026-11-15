/**
 * 任务管理器面板（用户重点模块）
 *
 * 桌面版 src-renderer/task-manager/task-manager.html 的鸿蒙原生等价实现：
 *  - CPU / 内存双指标 + 60 点折线图
 *  - 角色（sprite）资源表
 *  - 数据来自 ArkTS 侧 PerformanceManager 采样，不在 Web 层轮询系统资源
 *  - Apple Design 语言：深色卡片、细分隔线、克制的强调色、无渐变滥用
 */

import { TaskStats, SystemStats, SpriteStat } from '../common/Constants';

interface PanelStats {
  system: SystemStats;
  sprites: SpriteStat[];
  cpuSeries: number[];
  memorySeries: number[];
}

@Component
export struct TaskManagerPanel {
  @Prop statsJson: string = '{}';
  @Prop visible: boolean = false;
  onClose: () => void = () => {};

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  build() {
    if (this.visible) {
      Column() {
        // 头部
        Row() {
          Row() {
            Circle({ width: 7, height: 7 }).fill($r('app.color.success'))
            Text($r('app.string.action_task_manager'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_surface'))
              .margin({ left: 8 })
          }.layoutWeight(1)

          Text('实时')
            .fontSize(10)
            .fontColor($r('app.color.on_surface_secondary'))
            .margin({ right: 12 })

          Text('×')
            .fontSize(16)
            .fontColor($r('app.color.on_surface_secondary'))
            .padding({ left: 8, right: 4 })
            .onClick(() => this.onClose())
        }
        .width('100%')
        .height(44)
        .padding({ left: 16, right: 12 })

        Divider().color($r('app.color.divider')).strokeWidth(0.5)

        // 指标卡
        Row() {
          this.metricCard($r('app.string.stats_cpu'), this.cpuText(), '#0A84FF')
          this.metricCard($r('app.string.stats_memory'), this.memoryText(), '#5E5CE6')
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 14 })

        // 折线图
        Column() {
          Canvas(this.ctx)
            .width('100%')
            .height(96)
            .onReady(() => this.drawChart())
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10 })

        Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ top: 10 })

        // 角色表
        Row() {
          Text('名称').fontSize(10).fontColor($r('app.color.on_surface_secondary')).layoutWeight(1)
          Text('线程').fontSize(10).fontColor($r('app.color.on_surface_secondary')).width(44).textAlign(TextAlign.End)
          Text('CPU').fontSize(10).fontColor($r('app.color.on_surface_secondary')).width(52).textAlign(TextAlign.End)
          Text('内存').fontSize(10).fontColor($r('app.color.on_surface_secondary')).width(64).textAlign(TextAlign.End)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 6 })

        Scroll() {
          Column() {
            ForEach(this.sprites(), (item: SpriteStat, index: number) => {
              Row() {
                Text(item.name)
                  .fontSize(12)
                  .fontColor($r('app.color.on_surface'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(String(item.threads))
                  .fontSize(11)
                  .fontColor($r('app.color.on_surface_secondary'))
                  .width(44)
                  .textAlign(TextAlign.End)
                Text(item.cpuPercent.toFixed(1) + '%')
                  .fontSize(11)
                  .fontColor(item.cpuPercent > 60 ? $r('app.color.warning') : $r('app.color.on_surface_secondary'))
                  .width(52)
                  .textAlign(TextAlign.End)
                Text(this.formatKB(item.memEstimateKB))
                  .fontSize(11)
                  .fontColor($r('app.color.on_surface_secondary'))
                  .width(64)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .height(32)
              .padding({ left: 16, right: 16 })
              .backgroundColor(index % 2 === 0 ? '#00000000' : $r('app.color.surface_elevated'))
            }, (item: SpriteStat) => item.name)
          }
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width(340)
      .height('100%')
      .backgroundColor($r('app.color.surface'))
      .borderColor($r('app.color.divider'))
      .borderWidth({ left: 0.5 })
      .shadow({ radius: 16, color: '#66000000', offsetX: -4, offsetY: 0 })
    }
  }

  @Builder
  metricCard(label: Resource, value: string, accent: string) {
    Column() {
      Text(label).fontSize(10).fontColor($r('app.color.on_surface_secondary'))
      Text(value)
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_surface'))
        .margin({ top: 4 })
      Row()
        .width('100%')
        .height(3)
        .borderRadius(2)
        .backgroundColor($r('app.color.surface_elevated'))
        .margin({ top: 8 })
      Row()
        .width(this.metricRatio(value) + '%')
        .height(3)
        .borderRadius(2)
        .backgroundColor(accent)
    }
    .layoutWeight(1)
    .padding(12)
    .backgroundColor($r('app.color.surface_elevated'))
    .borderRadius(10)
    .alignItems(HorizontalAlign.Start)
  }

  private parsed(): PanelStats {
    try {
      const raw = JSON.parse(this.statsJson) as PanelStats;
      return {
        system: raw.system,
        sprites: raw.sprites === undefined ? [] : raw.sprites,
        cpuSeries: raw.cpuSeries === undefined ? [] : raw.cpuSeries,
        memorySeries: raw.memorySeries === undefined ? [] : raw.memorySeries
      };
    } catch (_e) {
      return {
        system: {
          cpuPercent: 0, memoryUsedMB: 0, memoryTotalMB: 0,
          coreCount: 8, threadCount: 1, timestamp: 0
        },
        sprites: [], cpuSeries: [], memorySeries: []
      };
    }
  }

  private cpuText(): string {
    return this.parsed().system.cpuPercent.toFixed(1) + '%';
  }

  private memoryText(): string {
    const s = this.parsed().system;
    return s.memoryTotalMB > 0
      ? (s.memoryUsedMB / 1024).toFixed(1) + '/' + (s.memoryTotalMB / 1024).toFixed(1) + ' GB'
      : '—';
  }

  private sprites(): SpriteStat[] {
    const list = this.parsed().sprites;
    return list === undefined ? [] : list;
  }

  private metricRatio(value: string): number {
    const n: number = parseFloat(value.replace('%', ''));
    return isNaN(n) ? 0 : Math.min(100, Math.max(2, n));
  }

  private formatKB(kb: number): string {
    return kb >= 1024 ? (kb / 1024).toFixed(1) + ' MB' : Math.round(kb) + ' KB';
  }

  /** 双曲线：CPU（蓝）/ 内存（紫），DPR 无关的固定坐标系 */
  private drawChart(): void {
    const w: number = 312;
    const h: number = 96;
    this.ctx.clearRect(0, 0, w, h);

    // 网格
    this.ctx.strokeStyle = '#33FFFFFF';
    this.ctx.lineWidth = 0.5;
    for (let i: number = 1; i < 4; i++) {
      const y: number = (h / 4) * i;
      this.ctx.beginPath();
      this.ctx.moveTo(0, y);
      this.ctx.lineTo(w, y);
      this.ctx.stroke();
    }

    const series: number[][] = this.seriesFromStats();
    const colors: string[] = ['#0A84FF', '#5E5CE6'];
    for (let s: number = 0; s < series.length; s++) {
      const data: number[] = series[s];
      if (data.length < 2) continue;
      this.ctx.beginPath();
      this.ctx.strokeStyle = colors[s];
      this.ctx.lineWidth = 1.6;
      for (let i: number = 0; i < data.length; i++) {
        const x: number = (i / (data.length - 1)) * w;
        const y: number = h - (Math.min(100, Math.max(0, data[i])) / 100) * (h - 8) - 4;
        if (i === 0) this.ctx.moveTo(x, y);
        else this.ctx.lineTo(x, y);
      }
      this.ctx.stroke();
    }
  }

  private seriesFromStats(): number[][] {
    // 60 点历史由 Index 每采样周期下发，与桌面版 MAX_HISTORY=60 一致
    const stats = this.parsed();
    const memNow: number = stats.system.memoryTotalMB > 0
      ? (stats.system.memoryUsedMB / stats.system.memoryTotalMB) * 100 : 0;
    const cpu: number[] = stats.cpuSeries.length >= 2
      ? stats.cpuSeries : [0, stats.system.cpuPercent];
    const mem: number[] = stats.memorySeries.length >= 2
      ? stats.memorySeries : [0, memNow];
    return [cpu, mem];
  }
}
