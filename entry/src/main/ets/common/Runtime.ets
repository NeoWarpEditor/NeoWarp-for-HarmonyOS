/**
 * 应用级运行时单例
 *
 * 用途：EntryAbility 负责生命周期，Index（UI）负责 ArkWeb 与布局，
 * 两者通过此单例共享原生服务、桥与性能调度器，避免组件树层层传参。
 * 所有字段显式类型，热路径无反射、无 any。
 */

import { NativeServices } from '../bridge/NativeServices';
import { HarmonyBridge } from '../bridge/HarmonyBridge';
import { PerformanceManager } from './PerformanceManager';
import { DeviceSnapshot, DeviceForm, FoldState } from './Constants';

export class Runtime {
  private static instance: Runtime = new Runtime();

  readonly perf: PerformanceManager = new PerformanceManager();
  services: NativeServices | null = null;
  bridge: HarmonyBridge | null = null;
  snapshot: DeviceSnapshot = {
    form: DeviceForm.TABLET_LANDSCAPE,
    foldState: FoldState.UNKNOWN,
    widthVp: 840,
    heightVp: 600,
    aspectRatio: 1.4,
    dpr: 2.0,
    creaseRegions: [],
    creaseCount: 0,
    isPc: false,
    hasKeyboard: false
  };
  pendingOpenUri: string = '';
  webReady: boolean = false;

  private constructor() {}

  static get(): Runtime {
    return Runtime.instance;
  }
}
