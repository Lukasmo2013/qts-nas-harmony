import { AppConstants } from './AppConstants';

/**
 * HarmonyOS 7 素雅色板（Elegant / Quiet Design Tokens）。
 *
 * 设计原则：
 * 1. 基底走中性灰白而非蓝调，避免大面积冷色发闷发脏；
 * 2. 强调色取克制的钢蓝 #3D74C4，只用于按钮 / 选中 / 链接等小面积；
 * 3. 卡片以「框」的形式呈现：近白半透明底 + 1px 极淡灰描边 + 极轻投影；
 * 4. 雾玻璃底不透明度提高到 ~95%，避免系统壁纸 / 设备主题色（常见为暖黄）
 *    透过模糊层给整页染上暖色；
 * 5. 明暗两套语义色，页面只消费语义色，不写死具体色值；
 * 6. 语义色中不含任何暖黄色相：warning 一律走冷灰蓝，保证整体克制统一。
 */
export class Theme {
  /** 克制的钢蓝强调色：明暗两套下均保持可读对比度，仅用于可交互元素。 */
  static readonly PRIMARY: string = '#3D74C4';
  static readonly PRIMARY_SOFT: string = '#EDF2F8';
  /** 大面积低饱和墨蓝：用于图表、指标条，避免紫/橙/青多色并置。 */
  static readonly INK_BLUE: string = '#7D93B8';
  static readonly INK_BLUE_SOFT: string = '#EFF2F7';
  static readonly SUCCESS: string = '#4E8C74';
  static readonly SUCCESS_SOFT: string = '#EBF3EF';
  /** 注意态：冷灰蓝，不使用暖黄，避免与「素雅」基调冲突。 */
  static readonly WARNING: string = '#6E7681';
  static readonly WARNING_SOFT: string = '#F1F2F4';
  static readonly DANGER: string = '#B5615C';
  static readonly DANGER_SOFT: string = '#F8EDEC';
  static readonly PURPLE: string = '#7B61FF';
  static readonly CYAN: string = '#00A9C8';

  /** 将「跟随系统」解析为实际明暗模式。colorMode === 1 表示深色。 */
  static effective(setting: string): string {
    if (setting === 'dark') {
      return 'dark';
    }
    if (setting === 'light') {
      return 'light';
    }
    const mode: number | undefined = AppStorage.get<number>(AppConstants.APP_STORAGE_SYSTEM_COLOR);
    return mode === 1 ? 'dark' : 'light';
  }

  static isDark(setting: string): boolean {
    return Theme.effective(setting) === 'dark';
  }

  /** 页面底色：中性灰，比纯白更安静，衬出白色卡片。 */
  static pageBg(setting: string): string {
    return Theme.isDark(setting) ? '#14161A' : '#F4F5F6';
  }

  static cardBg(setting: string): string {
    return Theme.isDark(setting) ? '#1B1E23' : '#FFFFFF';
  }

  /** 次级容器：输入框、内嵌块、选中行。 */
  static subCardBg(setting: string): string {
    return Theme.isDark(setting) ? '#23262C' : '#F1F2F4';
  }

  /** 导航 / 顶栏：与页面底色拉开一档，但不使用纯白刺眼。 */
  static navBg(setting: string): string {
    return Theme.isDark(setting) ? '#17191D' : '#FAFAFB';
  }

  /** 1px 极淡描边，替代重阴影。 */
  static hairline(setting: string): string {
    return Theme.isDark(setting) ? '#282C33' : '#E7E9EC';
  }

  /** 图标底：中性灰，取代原来的高饱和彩色圆形。 */
  static quietIconBg(setting: string): string {
    return Theme.isDark(setting) ? '#242830' : '#F0F1F3';
  }

  static textPrimary(setting: string): string {
    return Theme.isDark(setting) ? '#E9EBEE' : '#25282E';
  }

  static textSecondary(setting: string): string {
    return Theme.isDark(setting) ? '#949AA4' : '#8A8F98';
  }

  static divider(setting: string): string {
    return Theme.isDark(setting) ? '#282C33' : '#ECEEF0';
  }

  static iconTint(setting: string): string {
    return Theme.isDark(setting) ? '#A7ADB6' : '#6F757E';
  }

  static primarySoft(setting: string): string {
    return Theme.isDark(setting) ? '#20304F' : Theme.PRIMARY_SOFT;
  }

  static inkBlueSoft(setting: string): string {
    return Theme.isDark(setting) ? '#252D3D' : Theme.INK_BLUE_SOFT;
  }

  static successSoft(setting: string): string {
    return Theme.isDark(setting) ? '#20362D' : Theme.SUCCESS_SOFT;
  }

  static warningSoft(setting: string): string {
    return Theme.isDark(setting) ? '#262A31' : Theme.WARNING_SOFT;
  }

  static dangerSoft(setting: string): string {
    return Theme.isDark(setting) ? '#382624' : Theme.DANGER_SOFT;
  }

  /** 状态标签语义色：success / warning / danger / info */
  static tagForeground(tone: string): string {
    if (tone === 'danger') {
      return Theme.DANGER;
    }
    if (tone === 'warning') {
      return Theme.WARNING;
    }
    if (tone === 'info') {
      return Theme.PRIMARY;
    }
    return Theme.SUCCESS;
  }

  static tagBackground(tone: string, setting: string): string {
    if (tone === 'danger') {
      return Theme.dangerSoft(setting);
    }
    if (tone === 'warning') {
      return Theme.warningSoft(setting);
    }
    if (tone === 'info') {
      return Theme.primarySoft(setting);
    }
    return Theme.successSoft(setting);
  }

  /* ---------- 按钮语义色 ----------
   * HarmonyOS 的 Button 默认使用「系统强调色」（随设备主题变化，可能是暖黄）。
   * 页面内所有按钮一律显式指定下列颜色，保证与素雅色板一致。 */
  static buttonPrimaryBg(setting: string): string {
    return Theme.isDark(setting) ? '#4A83D1' : Theme.PRIMARY;
  }

  static buttonPrimaryFg(setting: string): string {
    return '#FFFFFF';
  }

  /** 次级按钮：中性底 + 细描边，无强调色。 */
  static buttonGhostBg(setting: string): string {
    return Theme.subCardBg(setting);
  }

  static buttonGhostFg(setting: string): string {
    return Theme.textPrimary(setting);
  }

  static buttonDangerBg(setting: string): string {
    return Theme.DANGER;
  }

  /* ---------- 雾玻璃「框」 ----------
   * 底色近乎不透明（~95%），系统模糊只保留轻微通透感；
   * 描边改为可见的极淡灰，使卡片真正呈现为「一个框」而不是一整块白。 */
  static glassBg(setting: string): string {
    return Theme.isDark(setting) ? '#1E222AD9' : '#FFFFFFF2';
  }

  static glassBorder(setting: string): string {
    return Theme.isDark(setting) ? '#2E333B' : '#E2E6EB';
  }

  static glassShadow(setting: string): string {
    return Theme.isDark(setting) ? 'rgba(0,0,0,0.22)' : 'rgba(31,38,51,0.05)';
  }

  /** 页面柔和渐变底：玻璃框模糊它后方，呈现通透大气的观感。
   *  linearGradient 要求 colors 为 [ResourceColor, number][]（颜色 + 位置）元组数组。 */
  static pageGradientColors(setting: string): [string, number][] {
    return Theme.isDark(setting)
      ? [['#16181C', 0.0], ['#0F1114', 1.0]]
      : [['#F4F5F6', 0.0], ['#FAFAFB', 1.0]];
  }

  /* ---------- 悬浮雾玻璃底栏 ----------
   * 底栏是一条独立悬浮的圆角长条：比卡片更通透一点（让渐变色隐约透过），
   * 但依然用高不透明度底色阻断壁纸 / 系统主题色的染色，
   * 并依靠一层可见淡描边 + 柔和投影把它从页面内容上「抬起来」。 */
  static readonly BAR_HEIGHT: number = 62;
  static readonly BAR_RADIUS: number = 26;

  static barBg(setting: string): string {
    return Theme.isDark(setting) ? '#1E222AC4' : '#FFFFFFD6';
  }

  static barBorder(setting: string): string {
    return Theme.isDark(setting) ? '#343A44' : '#DFE3E9';
  }

  /** 底栏投影比卡片更明显，才能形成「悬浮」的层次。 */
  static barShadow(setting: string): string {
    return Theme.isDark(setting) ? 'rgba(0,0,0,0.45)' : 'rgba(31,38,51,0.13)';
  }

  /** 底栏选中项的高亮胶囊底色。 */
  static barActiveBg(setting: string): string {
    return Theme.isDark(setting) ? '#26344D' : '#EAF0F8';
  }

  /** 顶栏 / 侧栏的雾玻璃底（比卡片更淡，保证大面积下不过白）。 */
  static chromeBg(setting: string): string {
    return Theme.isDark(setting) ? '#171A1FC2' : '#FBFBFCD2';
  }

  static chromeBorder(setting: string): string {
    return Theme.isDark(setting) ? '#2A2F37' : '#E6E9ED';
  }
}
