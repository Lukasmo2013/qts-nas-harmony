import { AppConstants } from '../common/constants/AppConstants';
import { DeviceSession } from '../model/Models';
import { QnapApi } from './QnapApi';
import { DemoMode } from '../common/demo/DemoMode';

/**
 * 登录态管理。
 * 会话 JSON 存入 AppStorage，并在 Index 中通过 PersistentStorage 持久化，
 * 因此冷启动可自动恢复登录、退出登录可即时清除。
 *
 * 注意：会话里必须包含 sid / scheme / password 三项——
 * 只持久化 host / port 会导致冷启动后所有请求被设备判为未认证（页面空白）。
 */
export class SessionManager {
  /**
   * 只持久化会话标识，不把账号密码写进设备存储。
   * sid 过期后由用户重新输入密码，避免明文凭据长期留在磁盘上。
   */
  static save(session: DeviceSession): void {
    const safe: DeviceSession = {
      mode: session.mode,
      account: session.account,
      host: session.host,
      port: session.port,
      deviceName: session.deviceName,
      model: session.model,
      firmware: session.firmware,
      serial: session.serial,
      loginAt: session.loginAt,
      sid: session.sid,
      scheme: session.scheme,
      password: '',
      relayCookie: session.relayCookie !== undefined ? session.relayCookie : ''
    };
    AppStorage.setOrCreate<string>(AppConstants.APP_STORAGE_SESSION, JSON.stringify(safe));
  }

  static load(): DeviceSession | null {
    const raw: string | undefined = AppStorage.get<string>(AppConstants.APP_STORAGE_SESSION);
    if (raw === undefined || raw.length === 0) {
      return null;
    }
    try {
      const parsed: DeviceSession = JSON.parse(raw) as DeviceSession;
      if (parsed.deviceName === undefined || parsed.deviceName.length === 0) {
        return null;
      }
      const fixed: DeviceSession = SessionManager.normalize(parsed);
      // 旧版本可能把设备地址写死在会话里；发现没有地址就当无效会话，
      // 交回登录页让用户重新填写，避免连到别人的 NAS。
      if (fixed.host.length === 0) {
        return null;
      }
      return fixed;
    } catch (error) {
      return null;
    }
  }

  /**
   * 兼容旧版会话（没有 sid / scheme / password 字段）：
   * 缺失字段补默认值，保证读取侧不需要到处判空。
   */
  private static normalize(session: DeviceSession): DeviceSession {
    const fixed: DeviceSession = {
      mode: session.mode !== undefined && session.mode.length > 0
        ? session.mode : AppConstants.LOGIN_MODE_IP,
      account: session.account !== undefined ? session.account : '',
      host: session.host !== undefined ? session.host : AppConstants.DEFAULT_HOST,
      port: session.port !== undefined ? session.port : AppConstants.DEFAULT_PORT,
      deviceName: session.deviceName,
      model: session.model !== undefined ? session.model : 'QNAP',
      firmware: session.firmware !== undefined ? session.firmware : '',
      serial: session.serial !== undefined ? session.serial : '',
      loginAt: session.loginAt !== undefined ? session.loginAt : 0,
      sid: session.sid !== undefined ? session.sid : '',
      scheme: session.scheme !== undefined && session.scheme.length > 0 ? session.scheme : 'http',
      password: session.password !== undefined ? session.password : '',
      relayCookie: session.relayCookie !== undefined ? session.relayCookie : ''
    };
    return fixed;
  }

  static isLoggedIn(): boolean {
    return SessionManager.load() !== null;
  }

  /**
   * 冷启动 / 页面重建时把会话注入数据层。
   * 返回 true 表示数据层已拿到可用的 sid（否则调用方应提示重新登录）。
   */
  static restoreToApi(): boolean {
    const session: DeviceSession | null = SessionManager.load();
    if (session === null) {
      return false;
    }
    QnapApi.restore(session);
    return QnapApi.hasSession();
  }

  /**
   * 确保数据层处于可用会话状态：
   * 1) 先按持久化的 sid 注入；
   * 2) sid 缺失（旧版本会话）或被设备判为失效时，用留存凭据静默重登一次；
   * 3) 仍失败则返回 false，调用方清除会话回到登录页。
   */
  static async ensureSession(): Promise<boolean> {
    const session: DeviceSession | null = SessionManager.load();
    if (session === null) {
      return false;
    }
    QnapApi.restore(session);
    // ① sid 在、而且真的还能用 → 直接进主界面。
    //    多花一次系统信息请求，换来「进去就能用」：旧实现只判断 sid 非空，
    //    会话其实早已失效，用户进到主界面看到的是全 0 指标和空白列表。
    if (QnapApi.hasSession()) {
      const alive: boolean = await QnapApi.ping();
      if (alive) {
        return true;
      }
    }
    // ② 用留存凭据静默重登。中继模式下同样有效：中继 Cookie 已随会话恢复，
    //    authLogin 带上它就能换到新 sid，不必重新做网页验证。
    if (session.account.length === 0 || session.password.length === 0) {
      SessionManager.publishNotice(QnapApi.relayExpired() ? 'login.fail.relayExpired' : '');
      return false;
    }
    const result = await QnapApi.login(session.host, session.port, session.account,
      session.password, session.scheme);
    if (result.success && result.session !== null) {
      SessionManager.save(result.session);
      return true;
    }
    SessionManager.publishNotice(result.errorKey);
    return false;
  }

  /**
   * 把冷启动失败原因留给登录页展示。
   *
   * 没有它，会话过期时用户只会「突然回到登录页」，不知道是密码错了、
   * 端口没开，还是中继到期需要重新做一次网页验证。
   */
  private static publishNotice(key: string): void {
    AppStorage.setOrCreate<string>('loginNotice', key !== undefined ? key : '');
  }

  /** 会话被设备侧刷新（静默重登拿到新 sid）后回写，避免下次冷启动用到旧 sid。 */
  static refreshSid(): void {
    const session: DeviceSession | null = SessionManager.load();
    const sid: string = QnapApi.currentSid();
    if (session === null || sid.length === 0 || session.sid === sid) {
      return;
    }
    const updated: DeviceSession = {
      mode: session.mode,
      account: session.account,
      host: session.host,
      port: session.port,
      deviceName: session.deviceName,
      model: session.model,
      firmware: session.firmware,
      serial: session.serial,
      loginAt: session.loginAt,
      sid: sid,
      scheme: session.scheme,
      password: session.password,
      relayCookie: session.relayCookie !== undefined ? session.relayCookie : ''
    };
    SessionManager.save(updated);
  }

  static clear(): void {
    // 退出时一并关闭审核预览，演示会话绝不能残留到下一次真实登录。
    DemoMode.exit();
    AppStorage.setOrCreate<string>(AppConstants.APP_STORAGE_SESSION, '');
    // 连这些一并清掉，否则换账号时仍会带着上一个账号的设备地址和相册目录。
    AppStorage.setOrCreate<string>('lastEndpoint', '');
    AppStorage.setOrCreate<string>('wanEndpoint', '');
    AppStorage.setOrCreate<string>('albumRoot', '');
    // 自动备份配置指向上一账号的 NAS 文件夹与手机目录，换账号必须一并清掉。
    AppStorage.setOrCreate<string>('autoBackupConfig', '');
    AppStorage.setOrCreate<string>('loginNotice', '');
    // 显式退出登录视为换使用者：清掉上次填写的账号/IP，避免下一个人看到旧账号。
    AppStorage.setOrCreate<string>(AppConstants.APP_STORAGE_LOGIN_FORM, '');
    QnapApi.resetShareCache();
    // 退出登录必须一并清掉中继 Cookie，否则下一个账号会带着上一个人的路由会话。
    QnapApi.clearRelay();
  }
}
