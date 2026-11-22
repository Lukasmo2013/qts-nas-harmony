import { AppConstants } from './AppConstants';

/**
 * HarmonyOS 7 雾玻璃设计令牌（Frosted Glass Design Tokens）。
 *
 * 设计原则：
 * 1. 基底走「冷调中性灰蓝」，比纯灰多一点空气感，避免大面积发闷发脏；
 * 2. 强调色取清晰的天青蓝 #2E6AD6，白底对比度 5.0:1（满足正文 AA），
 *    只用于按钮 / 选中 / 链接等小面积，不做大面积铺色；
 * 3. 卡片是「悬浮的雾玻璃片」：半透明底 + 系统组分模糊 + 1px 高光描边 + 层叠投影，
 *    透过模糊层能看到页面柔和的渐变底，形成纵深而不是一整块死白；
 * 4. 明暗两套语义色，页面只消费语义色，不写死具体色值；
 * 5. 语义色中不含任何暖黄色相：warning 一律走冷灰蓝，保证整体克制统一；
 * 6. 玻璃层不透明度保持在 0.72 ~ 0.85 区间：既能透出底部渐变形成通透感，
 *    又能阻断系统壁纸 / 设备主题色（常见为暖黄）给整页染色。
 */
export class Theme {
  /** 主强调色：天青蓝。用于按钮、选中态、链接、关键图标。 */
  static readonly PRIMARY: string = '#2E6AD6';
  /** 主强调色的深色端，仅用于渐变与按压态。 */
  static readonly PRIMARY_DEEP: string = '#1F52B0';
  static readonly PRIMARY_SOFT: string = '#E7EFFC';
  /** 大面积低饱和墨蓝：用于图表、指标条，避免紫/橙/青多色并置。 */
  static readonly INK_BLUE: string = '#7E93B8';
  static readonly INK_BLUE_SOFT: string = '#EEF2F9';
  static readonly SUCCESS: string = '#2E8B6B';
  static readonly SUCCESS_SOFT: string = '#E8F5EF';
  /** 注意态：冷灰蓝，不使用暖黄，避免与素雅基调冲突。 */
  static readonly WARNING: string = '#6B7480';
  static readonly WARNING_SOFT: string = '#F0F2F6';
  static readonly DANGER: string = '#C0524C';
  static readonly DANGER_SOFT: string = '#FBEDEC';
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

  /* ---------- 统一的「表面」令牌（卡片 / 底栏 / 顶栏 / 侧栏 / 弹层共用） ----------
   * 全 app 只有一套框：同底色、同描边、同投影色。
   * 任何新增容器都必须从这里取色，避免出现「同一个框两种白、两种描边」。
   * 浅色一律纯白实底：半透明会采样壁纸，暖色壁纸会把卡片染黄。 */
  static surfaceBg(setting: string): string {
    return Theme.isDark(setting) ? '#171A20' : '#FFFFFF';
  }

  static surfaceBorder(setting: string): string {
    return Theme.isDark(setting) ? '#2A2F37' : '#E6E8EC';
  }

  static surfaceShadowColor(setting: string): string {
    return Theme.isDark(setting) ? 'rgba(0,0,0,0.40)' : 'rgba(20,32,58,0.10)';
  }

  /** 卡片 / 弹层投影：r16 / y5。 */
  static surfaceShadow(setting: string): ShadowOptions {
    return {
      radius: 16,
      color: Theme.surfaceShadowColor(setting),
      offsetX: 0,
      offsetY: 5
    };
  }

  /** 悬浮件（底栏）投影：同色同描边，仅半径更大以形成「漂浮」层次。 */
  static floatingShadow(setting: string): ShadowOptions {
    return {
      radius: 22,
      color: Theme.surfaceShadowColor(setting),
      offsetX: 0,
      offsetY: 8
    };
  }

  /* ---------- 基底 ---------- */

  /** 页面底色：冷调浅灰蓝，衬出悬浮的玻璃卡片。 */
  static pageBg(setting: string): string {
    return Theme.isDark(setting) ? '#0D0F13' : '#F4F5F7';
  }

  static cardBg(setting: string): string {
    return Theme.surfaceBg(setting);
  }

  /** 次级容器：输入框、内嵌块、选中行。 */
  static subCardBg(setting: string): string {
    // 中性浅灰（不带蓝/黄色相）：在白卡片里既能区分区块，又不会让整屏偏色。
    return Theme.isDark(setting) ? '#22262E' : '#F7F8FA';
  }

  /** 导航 / 顶栏：与页面底色拉开一档，但不使用纯白刺眼。 */
  static navBg(setting: string): string {
    return Theme.isDark(setting) ? '#12151A' : '#FAFBFD';
  }

  /** 1px 极淡描边，替代重阴影。 */
  static hairline(setting: string): string {
    return Theme.isDark(setting) ? '#262B34' : '#E8EAED';
  }

  /** 图标底：低饱和冷灰，取代高饱和彩色圆形。 */
  static quietIconBg(setting: string): string {
    return Theme.isDark(setting) ? '#232833' : '#F2F3F5';
  }

  static textPrimary(setting: string): string {
    return Theme.isDark(setting) ? '#EAEDF2' : '#1D2129';
  }

  static textSecondary(setting: string): string {
    return Theme.isDark(setting) ? '#98A0AD' : '#7B8494';
  }

  static divider(setting: string): string {
    return Theme.isDark(setting) ? '#23272F' : '#EDEEF0';
  }

  static iconTint(setting: string): string {
    return Theme.isDark(setting) ? '#A9B1BD' : '#68707E';
  }

  static primarySoft(setting: string): string {
    return Theme.isDark(setting) ? '#1D2C46' : Theme.PRIMARY_SOFT;
  }

  static inkBlueSoft(setting: string): string {
    return Theme.isDark(setting) ? '#252D3D' : Theme.INK_BLUE_SOFT;
  }

  static successSoft(setting: string): string {
    return Theme.isDark(setting) ? '#1C3129' : Theme.SUCCESS_SOFT;
  }

  static warningSoft(setting: string): string {
    return Theme.isDark(setting) ? '#242830' : Theme.WARNING_SOFT;
  }

  static dangerSoft(setting: string): string {
    return Theme.isDark(setting) ? '#3A2523' : Theme.DANGER_SOFT;
  }

  /** 按压反馈底色：任何可点击行 / 卡片按下时统一使用，保证「点了有反应」。 */
  static pressBg(setting: string): string {
    return Theme.isDark(setting) ? '#2A2F3A' : '#E8EEF8';
  }

  /** 弹层遮罩：比纯黑 40% 更柔和，且随主题深浅变化。 */
  static scrim(setting: string): string {
    return Theme.isDark(setting) ? '#00000099' : '#1B243480';
  }

  /* ---------- 状态标签 ---------- */

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
   * 页面内所有按钮一律显式指定下列颜色，保证与设计令牌一致。 */
  static buttonPrimaryBg(setting: string): string {
    return Theme.isDark(setting) ? '#3D7AE0' : Theme.PRIMARY;
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

  /**
   * 强调型「浅底按钮」：浅蓝底 + 蓝字。
   * 这是本轮修复白字浅底（#FFFFFF on #EDF2F8）不可见的统一替代方案：
   * 文字与底色同色系，对比度 ≥ 4.5:1，浅色与深色模式下都清晰可读。
   */
  static buttonSoftBg(setting: string): string {
    return Theme.primarySoft(setting);
  }

  static buttonSoftFg(setting: string): string {
    return Theme.isDark(setting) ? '#8FB4F2' : Theme.PRIMARY_DEEP;
  }

  static buttonSoftBorder(setting: string): string {
    return Theme.isDark(setting) ? '#2C4470' : '#CBDDF8';
  }

  /* ---------- 雾玻璃「片」 ----------
   * 底色半透明（明 0.80 / 暗 0.80），叠系统组分模糊；
   * 描边为一圈极淡冷灰，把卡片框成一片「玻璃」而不是一整块白。 */
  static glassBg(setting: string): string {
    // 浅色与卡片完全同一底色；深色保留一点透明度，避免整屏纯黑死板。
    return Theme.isDark(setting) ? '#171A20F2' : Theme.surfaceBg(setting);
  }

  static glassBorder(setting: string): string {
    return Theme.surfaceBorder(setting);
  }

  /** 玻璃片顶缘高光：叠在 1px 描边上，模拟光线掠过玻璃边缘。 */
  static glassHighlight(setting: string): string {
    return Theme.isDark(setting) ? '#FFFFFF14' : '#FFFFFFB0';
  }

  static glassShadow(setting: string): string {
    return Theme.surfaceShadowColor(setting);
  }

  /** 卡片投影：玻璃片用大半径浅投影制造「漂浮」感。 */
  static cardShadow(setting: string): ShadowOptions {
    return Theme.surfaceShadow(setting);
  }

  /**
   * 卡片 / 底栏的模糊档位。
   * 浅色模式一律不做背景模糊：卡片是纯白实底，模糊只会引入壁纸色偏；
   * 深色模式保留 COMPONENT_THICK，维持鸿蒙 7 雾玻璃的通透层次。
   */
  static glassBlur(setting: string): BlurStyle {
    return Theme.isDark(setting) ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE;
  }

  /** 页面柔和渐变底：玻璃片模糊它后方，呈现通透的纵深。
   *  linearGradient 要求 colors 为 [ResourceColor, number][]（颜色 + 位置）元组数组。 */
  static pageGradientColors(setting: string): [string, number][] {
    return Theme.isDark(setting)
      ? [['#151920', 0.0], ['#10131A', 0.45], ['#0A0C10', 1.0]]
      : [['#F7F8FA', 0.0], ['#F2F4F6', 0.5], ['#EDEFF2', 1.0]];
  }

  /** 顶部主视觉渐晕：给页面首屏一点色相层次，不做大面积着色。 */
  static heroGradientColors(setting: string): [string, number][] {
    return Theme.isDark(setting)
      ? [['#1B3358', 0.0], ['#141922', 0.6], ['#00000000', 1.0]]
      : [['#DCE8FB', 0.0], ['#EDF3FC', 0.55], ['#00000000', 1.0]];
  }

  /* ---------- 悬浮雾玻璃底栏 ----------
   * 底栏是一条独立悬浮的圆角长条：比卡片更通透（让渐变隐约透过），
   * 但依然用半透明底阻断壁纸 / 系统主题色染色，
   * 并依靠一层可见淡描边 + 柔和投影把它从页面内容上「抬起来」。 */
  static readonly BAR_HEIGHT: number = 62;
  static readonly BAR_RADIUS: number = 26;

  static barBg(setting: string): string {
    return Theme.surfaceBg(setting);
  }

  static barBorder(setting: string): string {
    return Theme.surfaceBorder(setting);
  }

  /** 底栏投影比卡片更明显，才能形成「悬浮」的层次。 */
  static barShadow(setting: string): string {
    return Theme.surfaceShadowColor(setting);
  }

  /** 底栏选中项的高亮胶囊底色。 */
  static barActiveBg(setting: string): string {
    // 与侧栏选中态同一令牌，保证「选中」在底栏与侧栏看起来是同一个东西。
    return Theme.primarySoft(setting);
  }

  /** 顶栏 / 侧栏的雾玻璃底（比卡片更淡，保证大面积下不过白）。 */
  static chromeBg(setting: string): string {
    return Theme.surfaceBg(setting);
  }

  static chromeBorder(setting: string): string {
    return Theme.isDark(setting) ? '#282D36' : '#E6EAF1';
  }
}
