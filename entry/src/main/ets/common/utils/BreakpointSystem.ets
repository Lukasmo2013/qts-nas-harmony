import { AppConstants } from '../constants/AppConstants';

/**
 * 多设备断点系统。
 *
 * 采用「容器宽度驱动」而非硬编码设备类型：根页面通过 onAreaChange 读取实际
 * 可用宽度（vp），换算为 sm / md / lg 三档后写入 AppStorage('breakpoint')。
 * 手机、平板竖屏、平板横屏、2in1 分屏与自由窗口都能正确响应。
 *
 * HarmonyOS 7 大屏范式：
 * - sm：底部 TabBar，单列内容；
 * - md / lg：持久侧边栏 + 顶部应用栏 + 居中限宽的多栏内容区；
 * - 所有间距、圆角、栅格列数统一由本类下发，避免各页面各写一套魔法数字。
 */
export class BreakpointSystem {
  static readonly SM: string = 'sm';
  static readonly MD: string = 'md';
  static readonly LG: string = 'lg';

  static fromWidth(widthVp: number): string {
    if (widthVp >= AppConstants.BP_LG) {
      return BreakpointSystem.LG;
    }
    if (widthVp >= AppConstants.BP_MD) {
      return BreakpointSystem.MD;
    }
    return BreakpointSystem.SM;
  }

  static isWide(bp: string): boolean {
    return bp === BreakpointSystem.MD || bp === BreakpointSystem.LG;
  }

  static isExtraWide(bp: string): boolean {
    return bp === BreakpointSystem.LG;
  }

  /** 指标栅格列数：手机 2 栏，平板 / 大屏 4 栏通排。 */
  static columns(bp: string): number {
    if (bp === BreakpointSystem.LG) {
      return 4;
    }
    if (bp === BreakpointSystem.MD) {
      return 4;
    }
    return 2;
  }

  /** 主内容分栏列数（用于卡片列表）。 */
  static contentColumns(bp: string): number {
    if (bp === BreakpointSystem.LG) {
      return 3;
    }
    if (bp === BreakpointSystem.MD) {
      return 2;
    }
    return 1;
  }

  static pagePadding(bp: string): number {
    if (bp === BreakpointSystem.LG) {
      return 40;
    }
    if (bp === BreakpointSystem.MD) {
      return 28;
    }
    return 16;
  }

  static sideBarWidth(bp: string): number {
    return bp === BreakpointSystem.LG ? 236 : 208;
  }

  /** 大屏顶部应用栏高度；手机为 0（标题由页面自带 PageHeader 承担）。 */
  static topBarHeight(bp: string): number {
    if (bp === BreakpointSystem.LG) {
      return 72;
    }
    if (bp === BreakpointSystem.MD) {
      return 64;
    }
    return 0;
  }

  /** 栅格间距：大屏留白更大，形成「简约、素雅」的呼吸感。 */
  static contentGap(bp: string): number {
    if (bp === BreakpointSystem.LG) {
      return 24;
    }
    if (bp === BreakpointSystem.MD) {
      return 20;
    }
    return 12;
  }

  static cardRadius(bp: string): number {
    if (bp === BreakpointSystem.LG) {
      return 22;
    }
    if (bp === BreakpointSystem.MD) {
      return 20;
    }
    return 16;
  }

  static cardPadding(bp: string): number {
    if (bp === BreakpointSystem.LG) {
      return 24;
    }
    if (bp === BreakpointSystem.MD) {
      return 20;
    }
    return 16;
  }

  /** 标题字号：大屏使用 HarmonyOS 一级标题 26vp。 */
  static titleSize(bp: string): number {
    return BreakpointSystem.isWide(bp) ? 26 : 22;
  }

  /** 大屏下限制内容最大宽度并居中，避免超宽屏上文字行过长。 */
  static maxContentWidth(bp: string): number {
    if (bp === BreakpointSystem.LG) {
      return 1360;
    }
    if (bp === BreakpointSystem.MD) {
      return 1120;
    }
    return 2400;
  }

  static publish(widthVp: number): void {
    const next: string = BreakpointSystem.fromWidth(widthVp);
    const previous: string | undefined = AppStorage.get<string>(AppConstants.APP_STORAGE_BREAKPOINT);
    if (previous !== next) {
      AppStorage.setOrCreate<string>(AppConstants.APP_STORAGE_BREAKPOINT, next);
    }
  }
}
