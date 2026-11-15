/**
 * 设备形态识别：PC / 平板 / 阔折叠 / 三折叠
 *
 * 判据优先级：
 *   1) 折痕数量 + foldStatus  → 区分阔折叠 / 三折叠及其展开态
 *   2) 窗口宽度 vp + 宽高比  → 区分 PC / 平板横竖 / 紧凑屏
 *   3) 输入设备能力            → PC 键鼠特征
 *
 * 所有对外结果是静态类型 DeviceSnapshot，供布局与性能调度共用。
 */

import { display } from '@kit.ArkUI';
import { inputDevice } from '@kit.InputKit';
import {
  DeviceForm, FoldState, CreaseRegion, DeviceSnapshot,
  BREAKPOINT_SM, BREAKPOINT_MD, BREAKPOINT_LG
} from './Constants';

const PC_MIN_WIDTH_VP: number = 1100;
const TRIPLE_MIN_WIDTH_VP: number = 1280;
const WIDE_FOLD_OPEN_MIN_VP: number = 900;
const WIDE_FOLD_ASPECT_MIN: number = 0.85;
const WIDE_FOLD_ASPECT_MAX: number = 1.35;

export class DeviceProfile {
  private static lastFoldState: FoldState = FoldState.UNKNOWN;
  private static cachedHasKeyboard: boolean = false;

  /** 应用启动时探测一次输入设备能力（键鼠/触控），结果缓存 */
  static async probeInputDevices(): Promise<void> {
    try {
      const ids: number[] = await inputDevice.getDeviceIds();
      let hasKeyboard: boolean = false;
      for (const id of ids) {
        const info = await inputDevice.getDeviceInfo(id);
        // API 26: InputDeviceData.sources 为 SourceType 数组；键盘(1)/鼠标(2) 视为 PC 特征
        if (info !== null) {
          for (const source of info.sources) {
            if (Number(source) === 1 || Number(source) === 2) {
              hasKeyboard = true;
              break;
            }
          }
        }
        if (hasKeyboard) {
          break;
        }
      }
      DeviceProfile.cachedHasKeyboard = hasKeyboard;
    } catch (_e) {
      DeviceProfile.cachedHasKeyboard = false;
    }
  }

  static readFoldState(): FoldState {
    try {
      // API 26: display.getFoldStatus(): display.FoldStatus
      const status: number = display.getFoldStatus() as number;
      switch (status) {
        case 1: return FoldState.FOLDED;
        case 2: return FoldState.HALF_FOLDED;
        case 3: return FoldState.EXPANDED;
        default: return FoldState.UNKNOWN;
      }
    } catch (_e) {
      return FoldState.UNKNOWN;
    }
  }

  static readCreaseRegions(): CreaseRegion[] {
    const result: CreaseRegion[] = [];
    try {
      // API 26: display.getCurrentFoldCreaseRegion(): FoldCreaseRegion
      const region = display.getCurrentFoldCreaseRegion();
      if (region !== null && region.creaseRects !== undefined) {
        const rects = region.creaseRects;
        for (const r of rects) {
          result.push({ left: r.left, top: r.top, width: r.width, height: r.height });
        }
      }
    } catch (_e) {
      // 非折叠设备无折痕，返回空数组即可
    }
    return result;
  }

  /**
   * 生成形态快照。widthVp/heightVp 由 window 的 windowRect 换算后传入。
   */
  static snapshot(widthVp: number, heightVp: number, dpr: number): DeviceSnapshot {
    const foldState: FoldState = DeviceProfile.readFoldState();
    const creases: CreaseRegion[] = DeviceProfile.readCreaseRegions();
    const creaseCount: number = creases.length;
    const aspect: number = heightVp > 0 ? widthVp / heightVp : 1;
    const hasKeyboard: boolean = DeviceProfile.cachedHasKeyboard;

    let form: DeviceForm = DeviceForm.PHONE_COMPACT;

    if (creaseCount >= 2 || (creaseCount === 1 && widthVp >= TRIPLE_MIN_WIDTH_VP)) {
      // 三折叠：单屏 / 双屏 / 三屏态
      if (foldState === FoldState.EXPANDED && widthVp >= TRIPLE_MIN_WIDTH_VP) {
        form = DeviceForm.TRIPLE_FOLD_TRIPLE;
      } else if (foldState === FoldState.EXPANDED || foldState === FoldState.HALF_FOLDED) {
        form = DeviceForm.TRIPLE_FOLD_DUAL;
      } else {
        form = DeviceForm.TRIPLE_FOLD_SINGLE;
      }
    } else if (creaseCount === 1) {
      // 阔折叠：展开态接近方形，合盖态窄屏
      const nearSquare: boolean = aspect >= WIDE_FOLD_ASPECT_MIN && aspect <= WIDE_FOLD_ASPECT_MAX;
      if (foldState === FoldState.EXPANDED && widthVp >= WIDE_FOLD_OPEN_MIN_VP && nearSquare) {
        form = DeviceForm.WIDE_FOLD_OPEN;
      } else {
        form = DeviceForm.WIDE_FOLD_CLOSED;
      }
    } else if (widthVp >= PC_MIN_WIDTH_VP && (hasKeyboard || aspect > 1.6)) {
      form = DeviceForm.PC;
    } else if (widthVp >= BREAKPOINT_LG) {
      form = DeviceForm.TABLET_LANDSCAPE;
    } else if (widthVp >= BREAKPOINT_MD) {
      form = aspect > 1.15 ? DeviceForm.TABLET_LANDSCAPE : DeviceForm.TABLET_PORTRAIT;
    } else if (widthVp >= BREAKPOINT_SM) {
      form = DeviceForm.PHONE_COMPACT;
    }

    DeviceProfile.lastFoldState = foldState;
    return {
      form: form,
      foldState: foldState,
      widthVp: widthVp,
      heightVp: heightVp,
      aspectRatio: aspect,
      dpr: dpr,
      creaseRegions: creases,
      creaseCount: creaseCount,
      isPc: form === DeviceForm.PC,
      hasKeyboard: hasKeyboard
    };
  }

  static previousFoldState(): FoldState {
    return DeviceProfile.lastFoldState;
  }

  /** 布局列数：三折叠三屏 / PC 用三栏，展开态双栏，紧凑态单栏 */
  static columnCount(form: DeviceForm): number {
    switch (form) {
      case DeviceForm.TRIPLE_FOLD_TRIPLE:
      case DeviceForm.PC: return 3;
      case DeviceForm.TRIPLE_FOLD_DUAL:
      case DeviceForm.WIDE_FOLD_OPEN:
      case DeviceForm.TABLET_LANDSCAPE: return 2;
      default: return 1;
    }
  }

  /** 是否显示桌面级侧栏与菜单栏 */
  static showDesktopChrome(form: DeviceForm): boolean {
    return form === DeviceForm.PC ||
      form === DeviceForm.TABLET_LANDSCAPE ||
      form === DeviceForm.TRIPLE_FOLD_TRIPLE;
  }

  /** 折痕避让：把折痕映射为左右安全边距（vp） */
  static creasePadding(snapshot: DeviceSnapshot): [number, number] {
    let left: number = 0;
    let right: number = 0;
    const center: number = snapshot.widthVp / 2;
    for (const r of snapshot.creaseRegions) {
      const creaseCenter: number = r.left + r.width / 2;
      if (creaseCenter <= center) {
        left = Math.max(left, 24);
      } else {
        right = Math.max(right, 24);
      }
    }
    return [left, right];
  }
}
