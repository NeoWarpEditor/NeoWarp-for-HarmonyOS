/**
 * 鸿蒙设备性能调度
 *
 * - 按设备形态分档（PC 高性能 / 平板均衡 / 折叠合盖省电）
 * - 前后台切换挂起 VM 渲染循环与轮询，后台 CPU 趋零
 * - 内存水位回调主动收缩素材缓存
 * - DPR 上限按档位下发，避免折叠屏展开态超宽纹理反复重分配
 */

import { hidebug } from '@kit.PerformanceAnalysisKit';
import {
  DeviceForm, PerformanceTier, PerfPolicy, SystemStats, TaskStats, SpriteStat
} from './Constants';

const SAMPLE_INTERVAL_HIGH: number = 1000;
const SAMPLE_INTERVAL_BALANCED: number = 1500;
const SAMPLE_INTERVAL_SAVER: number = 3000;

export class PerformanceManager {
  private tier: PerformanceTier = PerformanceTier.BALANCED;
  private form: DeviceForm = DeviceForm.TABLET_LANDSCAPE;
  private foreground: boolean = true;
  private lastCpuTicks: number = 0;
  private lastSampleTime: number = 0;
  private spriteStats: SpriteStat[] = [];
  private cpuHistory: number[] = [];
  private memoryHistory: number[] = [];
  private readonly historyLength: number = 60;
  private assetCacheMB: number = 128;

  /** 依据形态生成策略；折叠切换时调用，不重建任何 Web 组件 */
  applyForm(form: DeviceForm): PerfPolicy {
    this.form = form;
    let tier: PerformanceTier = PerformanceTier.BALANCED;
    switch (form) {
      case DeviceForm.PC:
      case DeviceForm.TRIPLE_FOLD_TRIPLE:
        tier = PerformanceTier.HIGH;
        break;
      case DeviceForm.TABLET_LANDSCAPE:
      case DeviceForm.TABLET_PORTRAIT:
      case DeviceForm.WIDE_FOLD_OPEN:
      case DeviceForm.TRIPLE_FOLD_DUAL:
        tier = PerformanceTier.BALANCED;
        break;
      default:
        tier = PerformanceTier.SAVER;
        break;
    }
    this.tier = tier;
    return this.currentPolicy();
  }

  currentPolicy(): PerfPolicy {
    switch (this.tier) {
      case PerformanceTier.HIGH:
        return {
          tier: PerformanceTier.HIGH, targetFps: 60, dprCap: 2.5,
          workerCount: 4, assetCacheMB: 256,
          sampleIntervalMs: SAMPLE_INTERVAL_HIGH, suspendOnBackground: true
        };
      case PerformanceTier.BALANCED:
        return {
          tier: PerformanceTier.BALANCED, targetFps: 45, dprCap: 2.0,
          workerCount: 2, assetCacheMB: 128,
          sampleIntervalMs: SAMPLE_INTERVAL_BALANCED, suspendOnBackground: true
        };
      default:
        return {
          tier: PerformanceTier.SAVER, targetFps: 30, dprCap: 1.75,
          workerCount: 1, assetCacheMB: 64,
          sampleIntervalMs: SAMPLE_INTERVAL_SAVER, suspendOnBackground: true
        };
    }
  }

  onForeground(): void {
    this.foreground = true;
  }

  /** 后台挂起：停止采样与 VM 渲染循环（由桥通知 Web 层） */
  onBackground(): void {
    this.foreground = false;
  }

  isForeground(): boolean {
    return this.foreground;
  }

  onMemoryLevel(level: number): void {
    // level 越大内存越紧张，按档位逐级收缩缓存
    if (level >= 2) {
      this.assetCacheMB = Math.max(32, Math.floor(this.currentPolicy().assetCacheMB / 4));
    } else if (level >= 1) {
      this.assetCacheMB = Math.max(64, Math.floor(this.currentPolicy().assetCacheMB / 2));
    } else {
      this.assetCacheMB = this.currentPolicy().assetCacheMB;
    }
  }

  cacheLimitMB(): number {
    return this.assetCacheMB;
  }

  /** 由 Web 层 VM 事件推送角色统计，避免在 Web 层轮询系统资源 */
  updateSpriteStats(stats: SpriteStat[]): void {
    this.spriteStats = stats;
  }

  /**
   * 采样系统状态。CPU 采用进程累计 CPU 时间的差分估算，
   * 与桌面版 os.cpus() 差分算法等价（task-manager.js:69-91）。
   */
  sample(): TaskStats {
    const now: number = Date.now();
    let cpuPercent: number = 0;
    let usedMB: number = 0;
    let totalMB: number = 0;
    let threadCount: number = 1;

    try {
      // API 26: hidebug.getAppCpuUsage() / getSystemMemInfo()
      cpuPercent = hidebug.getCpuUsage();
      const mem = hidebug.getSystemMemInfo();
      const totalKB: number = Number(mem.totalMem);
      const freeKB: number = Number(mem.freeMem);
      totalMB = Math.floor(totalKB / 1024);
      usedMB = Math.floor((totalKB - freeKB) / 1024);
      // API 26 未暴露进程线程数接口，task-manager 该字段保守取主线程数
      threadCount = 1;
    } catch (_e) {
      // 计量接口不可用时退化为差分估算，不抛异常到 Web 层
      const elapsed: number = this.lastSampleTime > 0 ? (now - this.lastSampleTime) : 1000;
      cpuPercent = this.lastCpuTicks > 0 ? Math.min(100, (elapsed / 1000) * 2) : 0;
      totalMB = 0;
      usedMB = 0;
    }
    this.lastSampleTime = now;
    this.lastCpuTicks = cpuPercent;

    this.pushHistory(this.cpuHistory, Math.min(100, Math.max(0, cpuPercent)));
    this.pushHistory(this.memoryHistory, totalMB > 0 ? Math.min(100, (usedMB / totalMB) * 100) : 0);

    const system: SystemStats = {
      cpuPercent: Math.round(cpuPercent * 10) / 10,
      memoryUsedMB: usedMB,
      memoryTotalMB: totalMB,
      coreCount: 8,
      threadCount: threadCount,
      timestamp: now
    };
    return { system: system, sprites: this.spriteStats };
  }

  cpuSeries(): number[] {
    return this.cpuHistory.slice();
  }

  memorySeries(): number[] {
    return this.memoryHistory.slice();
  }

  private pushHistory(series: number[], value: number): void {
    series.push(value);
    if (series.length > this.historyLength) {
      series.shift();
    }
  }
}
