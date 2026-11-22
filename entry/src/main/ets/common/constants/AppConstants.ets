/**
 * 全局常量与枚举定义。
 * 所有跨模块共享的键名、断点阈值、状态枚举集中在此，避免散落的魔法值。
 */

export enum LoginMode {
  QNAP_ID = 'qnapId',
  LOCAL_IP = 'localIp'
}

/**
 * 顶层页面索引。与 AdaptiveShell 的 Swiper 页序严格一致。
 * 「存储」已从导航中移除，其内容并入「我的」页面（SettingsPage）。
 */
export enum PageTab {
  HOME = 0,
  FILES = 1,
  DOCKER = 2,
  PROFILE = 3
}

/** 统一页面状态：所有业务模块共用，驱动 StateView 渲染。 */
export enum LoadState {
  LOADING = 'loading',
  SUCCESS = 'success',
  EMPTY = 'empty',
  ERROR = 'error',
  NO_NETWORK = 'noNetwork',
  NO_PERMISSION = 'noPermission'
}

/** 连接健康度 */
export enum HealthLevel {
  GOOD = 'good',
  WARNING = 'warning',
  ERROR = 'error'
}

export class AppConstants {
  static readonly APP_STORAGE_LANG: string = 'appLanguage';
  static readonly APP_STORAGE_THEME: string = 'appTheme';
  static readonly APP_STORAGE_SESSION: string = 'appSession';
  static readonly APP_STORAGE_BREAKPOINT: string = 'breakpoint';
  static readonly APP_STORAGE_SYSTEM_COLOR: string = 'systemColorMode';
  static readonly APP_STORAGE_NOTIFY: string = 'notificationsEnabled';
  /** 登录页初始登录方式（设置页「切换登录方式」时预置，登录页读取后即时生效）。 */
  static readonly APP_STORAGE_LOGIN_MODE: string = 'loginMode';
  /** 用户上次填写的登录表单（不含密码），用于跨重启保留 IP/端口/账号。 */
  static readonly APP_STORAGE_LOGIN_FORM: string = 'loginForm';

  static readonly LANG_ZH: string = 'zh';
  static readonly LANG_EN: string = 'en';
  static readonly LOGIN_MODE_QID: string = 'qnapId';
  static readonly LOGIN_MODE_IP: string = 'localIp';

  /** 视口宽度断点（vp）：< 600 手机，600~840 平板竖屏，>= 840 平板横屏 / 2in1 */
  static readonly BP_MD: number = 600;
  static readonly BP_LG: number = 840;

  /**
   * 版本号：与 AppScope/app.json5 的 versionName / versionCode 保持一致。
   * 由 `tools/bump_version.py` 统一维护（改一处会同步改两处），不要手改其中一边。
   * 编码规则：major * 1000000 + minor * 1000 + patch（1.2.1 -> 1002001）。
   */
  static readonly VERSION_NAME: string = '2.1.7';
  static readonly VERSION_CODE: string = '2001007';
  /** 构建日期，同样由 bump 脚本写入。 */
  static readonly BUILD_DATE: string = '2026-11-22';
  static readonly BUILD_TAG: string = 'HarmonyOS API 12';
  /** 版权归属。 */
  static readonly COPYRIGHT: string = '© 2026 莫洁安';
  static readonly LICENSE_NAME: string = 'MIT License';

  /**
   * 默认连接配置：首次使用时由用户自行输入。
   * 这里**不预置**任何设备地址、账号或口令（含 base64 形式），避免随包分发任何凭据；
   * 记住登录信息只发生在用户主动勾选后，且口令不落盘。
   */
  static readonly DEFAULT_HOST: string = '';
  static readonly DEFAULT_PORT: number = 5000;
  static readonly DEFAULT_USER: string = '';
  static readonly DEFAULT_PASSWORD: string = '';
}
