import { Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import nativeBridge from 'libtailscale_ohos.so';

/**
 * Tailscale 系统 VPN 扩展。
 *
 * 设计要点（来自真机验证过的 MeshArc 架构）：
 * 1. 引擎只能在 **VPN 扩展进程** 里持有实例；UI 进程不得再启一个，否则两个
 *    实例争抢同一设备身份，会互相踢下线并无限重连。
 * 2. 登录完成前创建一条 192.0.2.0/24（文档专用网段）的探针 TUN，
 *    不会劫持任何真实流量；等拿到 Tailscale 分配的 100.x 地址后销毁它，
 *    再用 `100.64.0.0/10` 精确路由重建真正的 TUN。
 * 3. `backendRestartWithTun` 把数据面切到 TUN，之后 ArkTS 的 @ohos.net.http
 *    访问 100.x 地址就会走系统 VPN 路由，现有 QnapApi 无需改造。
 *
 * 与 UI 的交接靠沙箱内的状态文件（两个进程同属一个应用，filesDir 相同）。
 */

const STATUS_FILE: string = 'tailscale-status.json';
const CONTROL_FILE: string = 'tailscale-control-url.txt';
const STATE_DIR_NAME: string = 'tailscale';
const VPN_EXISTS_ERROR_CODE: number = 2203002;
const DEFAULT_CONTROL_URL: string = 'https://controlplane.tailscale.com';
/**
 * 等待用户在网页里完成 tailnet 授权的上限（秒）。
 * 原来是 150 秒，实测太短：输账号 + 二次验证很容易超时，一旦超时引擎就永久放弃，
 * 用户即使登录成功也再不会 Running（表现为「点了登录页、下一步却没反应」）。
 */
const AUTH_WAIT_SECONDS: number = 14400;

interface TsStatus {
  state: string;
  detail: string;
  authUrl: string;
  selfIp: string;
  peers: string;
  updatedAt: number;
}

function newStatus(state: string, detail: string): TsStatus {
  const s: TsStatus = {
    state: state,
    detail: detail,
    authUrl: '',
    selfIp: '',
    peers: '[]',
    updatedAt: Date.now()
  };
  return s;
}

export default class TailscaleVpnExtensionAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | undefined = undefined;
  private tunFd: number = -1;
  private destroyed: boolean = false;
  private timer: number = -1;
  private status: TsStatus = newStatus('init', '');

  onCreate(want: Want): void {
    this.writeStatus(this.status);
    this.boot().catch((error: BusinessError) => {
      const code: number = error.code ?? -1;
      this.writeStatus(newStatus('failed', 'boot code=' + code));
    });
  }

  onDestroy(): void {
    this.destroyed = true;
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    try {
      nativeBridge.backendStop();
    } catch (e) {
      // 引擎可能尚未启动
    }
    if (this.tunFd >= 0) {
      this.tunFd = -1;
    }
    const conn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (conn !== undefined) {
      conn.destroy().catch(() => {
        // 扩展退出时系统可能已回收连接
      });
    }
    this.vpnConnection = undefined;
  }

  /**
   * 引擎要求的 deviceModel：优先 marketName（去掉 Huawei 前缀、排除 default），
   * 再回退 productModel。deviceInfo.productModel 在部分真机上为空串，
   * 空串会让 backendStart 报 "requires state directory and device model"。
   */
  private deviceModel(): string {
    const strip = (value: string): string => {
      const v: string = value.trim();
      const low: string = v.toLowerCase();
      if (low === 'huawei') {
        return '';
      }
      if (low.startsWith('huawei ') || low.startsWith('huawei-') || low.startsWith('huawei_')) {
        return v.substring(6).replace(/^[\s_-]+/, '').trim();
      }
      return v;
    };
    const market: string = strip(deviceInfo.marketName);
    if (market.length > 0 && market.toLowerCase() !== 'default') {
      return market;
    }
    const model: string = strip(deviceInfo.productModel);
    // 双保险：极端情况下系统两个字段都为空，给一个稳定非空值，避免引擎再次拒绝。
    return model.length > 0 ? model : 'HarmonyOS-Device';
  }

  /** 引擎要求的 osVersion：优先 majorVersion.seniorVersion，再回退解析 osFullName。 */
  private harmonyOSVersion(): string {
    const major: number = Number(deviceInfo.majorVersion);
    const senior: number = Number(deviceInfo.seniorVersion);
    if (major > 0) {
      return String(major) + '.' + String(Math.max(0, senior));
    }
    const full: string = deviceInfo.osFullName.trim();
    const m: RegExpMatchArray | null = full.match(/(\d+)\.(\d+)/);
    if (m !== null) {
      return m[1] + '.' + m[2];
    }
    const disp: string = deviceInfo.displayVersion.trim();
    return disp.length > 0 ? disp : '5.0';
  }

  private controlUrl(): string {
    try {
      const p: string = this.context.filesDir + '/' + CONTROL_FILE;
      if (fileIo.accessSync(p)) {
        const f: fileIo.File = fileIo.openSync(p, fileIo.OpenMode.READ_ONLY);
        try {
          const buf: ArrayBuffer = new ArrayBuffer(256);
          const n: number = fileIo.readSync(f.fd, buf);
          const bytes: Uint8Array = new Uint8Array(buf, 0, n);
          let text: string = '';
          for (let i: number = 0; i < bytes.length; i++) {
            text += String.fromCharCode(bytes[i]);
          }
          text = text.trim();
          if (text.length > 0) {
            return text;
          }
        } finally {
          fileIo.closeSync(f);
        }
      }
    } catch (e) {
      // 用默认控制面
    }
    return DEFAULT_CONTROL_URL;
  }

  private writeStatus(s: TsStatus): void {
    s.updatedAt = Date.now();
    this.status = s;
    try {
      const p: string = this.context.filesDir + '/' + STATUS_FILE;
      const f: fileIo.File = fileIo.openSync(p,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(f.fd, JSON.stringify(s));
      } finally {
        fileIo.closeSync(f);
      }
    } catch (e) {
      // 状态文件写失败不影响引擎
    }
  }

  private stateDir(): string {
    return this.context.filesDir + '/' + STATE_DIR_NAME;
  }

  /** 引擎首次启动会往该目录写状态文件，必须先建好，否则 backendStart 抛异常。 */
  private ensureStateDir(dir: string): void {
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
    } catch (e) {
      // 目录已存在或权限问题都忽略；真正失败会在 backendStart 里体现
    }
  }

  /**
   * 从 bridge 的原始返回里取出真正的授权 URL。
   * `backendAuthURLAsync()` 的返回可能带 `OK | ` 前缀或包着其它字段，
   * 直接当 WebView 的 src 会加载失败（表现为白屏），所以统一按
   * 「首个 http 开始、到 ' | ' 或换行结束」提取，非 http 一律丢弃。
   */
  private pickAuthUrl(raw: string): string {
    const idx: number = raw.indexOf('http');
    if (idx < 0) {
      return '';
    }
    let url: string = raw.substring(idx).trim();
    const bar: number = url.indexOf(' | ');
    if (bar > 0) {
      url = url.substring(0, bar);
    }
    const nl: number = url.indexOf('\n');
    if (nl > 0) {
      url = url.substring(0, nl);
    }
    url = url.trim();
    return url.startsWith('http') ? url : '';
  }

  /**
   * 取本机节点的授权 URL。
   *
   * 真机实测：`loginURLReady=true` 但 `backendAuthURLAsync()` 拿不到 URL，
   * 网页登录又只是登进官网后台、不会授权本机节点，于是引擎永远 NeedsLogin。
   * 本工程 so 是旧版 bridge（`backendStart` 就曾因 argc 不匹配报"缺参"），
   * 异步封装很可能也与之不匹配，因此再退到同步 `backendAuthURL()`。
   */
  private async fetchAuthUrl(): Promise<string> {
    let raw: string = '';
    try {
      raw = await nativeBridge.backendAuthURLAsync();
    } catch (e) {
      raw = '';
    }
    const fromAsync: string = this.pickAuthUrl(raw);
    if (fromAsync.length > 0) {
      return fromAsync;
    }
    try {
      return this.pickAuthUrl(nativeBridge.backendAuthURL());
    } catch (e) {
      return '';
    }
  }

  /**
   * 是否真的进入了 tailnet。
   * 状态机文本可能滞后（真机出现过已授权、但状态还停在 NeedsLogin 的情况），
   * 因此把「已分配到 tailscaleIPs」也当作入网判据——有 IP 就说明节点已经在网里。
   */
  /**
   * 带重试地取本机 tailnet 地址。
   * 授权刚落地时 LocalBackend 状态会短暂回跳，直接取配置可能失败；
   * 重试 20 秒仍失败才认输，避免把一次性抖动写成永久失败。
   */
  private async fetchVpnConfig(): Promise<string> {
    let last: string = '';
    for (let i: number = 0; i < 20 && !this.destroyed; i++) {
      try {
        last = await nativeBridge.backendVpnConfigAsync();
      } catch (e) {
        last = '';
      }
      if (last.length > 0 && last.indexOf('FAILED') < 0 && last.indexOf('|') > 0) {
        return last;
      }
      await this.sleep(1000);
    }
    return last;
  }

  private isInTailnet(st: string): boolean {
    if (st.indexOf('state=Running') >= 0) {
      return true;
    }
    const m: RegExpMatchArray | null = st.match(/tailscaleIPs=(\d+)/);
    if (m === null) {
      return false;
    }
    return Number(m[1]) > 0;
  }

  private async boot(): Promise<void> {
    this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    this.writeStatus(newStatus('starting', 'vpn connection created'));

    // ① 登录前：文档网段探针 TUN，不碰真实流量
    const probeFd: number = await this.createTun(this.probeConfig());
    if (probeFd < 0) {
      this.writeStatus(newStatus('failed', 'probe tun code=' + probeFd));
      return;
    }
    this.tunFd = probeFd;

    // ② 原生引擎：等价于 set_authkey 之后的 up —— 本次引擎用持久化状态
    // （首次由授权页完成 login，auth key 模式由控制面签发后状态落盘复用）。
    const stateDir: string = this.stateDir();
    this.ensureStateDir(stateDir);
    this.writeStatus(newStatus('starting', 'backend start'));
    let bootText: string = '';
    try {
      // 本工程打包的 libtailscale_ohos.so 是旧版 bridge：backendStart 只接受
      // (stateDir, deviceModel) 两个参数。多传会导致 argc 校验失败，抛
      // "backendStart requires state directory and device model"。
      bootText = nativeBridge.backendStart(stateDir, this.deviceModel());
    } catch (e) {
      const msg: string = e instanceof Error ? (e as Error).message : String(e);
      this.writeStatus(newStatus('failed', 'backend start exception: ' + msg));
      return;
    }
    if (bootText.length === 0 || bootText.indexOf('FAILED') >= 0) {
      this.writeStatus(newStatus('failed', bootText));
      return;
    }

    // ③ 轮询 status_json，直到 Running；NeedsLogin 时把授权 URL 交给 UI。
    // 等待窗口必须给足：用户在网页里输账号、过二次验证很容易超过几分钟，
    // 窗口一到就写 timeout 会让引擎永久放弃，之后即使登录成功也再不会 Running
    // （表现为：登录页里登录完了，点「下一步」永远没反应）。
    let ready: boolean = false;
    for (let i: number = 0; i < AUTH_WAIT_SECONDS && !this.destroyed; i++) {
      await this.sleep(1000);
      let st: string = '';
      try {
        st = nativeBridge.backendStatus();
      } catch (e) {
        st = '';
      }
      if (this.isInTailnet(st)) {
        ready = true;
        break;
      }
      if (st.indexOf('NeedsLogin') >= 0) {
        const authUrl: string = await this.fetchAuthUrl();
        const s: TsStatus = newStatus('needs_login', st);
        s.authUrl = authUrl;
        this.writeStatus(s);
      } else {
        this.writeStatus(newStatus('starting', st));
      }
    }
    if (!ready || this.destroyed) {
      if (!this.destroyed) {
        this.writeStatus(newStatus('timeout',
          'backend not running after ' + AUTH_WAIT_SECONDS + 's'));
      }
      return;
    }

    // ④ 用真实 100.x 地址重建 TUN，再把数据面切过去。
    // 首次授权刚完成时引擎状态会短暂抖动：backendStatus 已报 Running，
    // 紧接着取 VPN config 却返回 "FAILED | VPN config : backend not running"。
    // 真机出现过因这一次抖动就永久写 failed 的情况，所以这里必须重试。
    const cfgText: string = await this.fetchVpnConfig();
    const parts: string[] = cfgText.split('|');
    const ipv4: string = parts.length > 0 ? parts[0] : '';
    const ipv6: string = parts.length > 1 ? parts[1] : '';
    if (ipv4.length === 0 || ipv4.indexOf('FAILED') >= 0) {
      this.writeStatus(newStatus('failed', 'vpn config: ' + cfgText));
      return;
    }
    await this.destroyTun();
    const realFd: number = await this.createTun(this.realConfig(ipv4, ipv6));
    if (realFd < 0) {
      this.writeStatus(newStatus('failed', 'real tun code=' + realFd));
      return;
    }
    this.tunFd = realFd;
    // 数据面切到真实 TUN：之后 App 发往 100.64.0.0/10 的流量才会进 tailnet。
    let restart: string = '';
    try {
      // 旧版 bridge：backendRestartWithTun 接受 (stateDir, deviceModel, fd) 三个参数。
      restart = nativeBridge.backendRestartWithTun(stateDir, this.deviceModel(), realFd);
    } catch (e) {
      const msg: string = e instanceof Error ? (e as Error).message : String(e);
      this.writeStatus(newStatus('failed', 'restart tun exception: ' + msg));
      return;
    }
    for (let i: number = 0; i < 60 && !this.destroyed; i++) {
      await this.sleep(500);
      let st: string = '';
      try {
        st = nativeBridge.backendStatus();
      } catch (e) {
        st = '';
      }
      if (this.isInTailnet(st)) {
        const s: TsStatus = newStatus('running', st);
        s.selfIp = ipv4;
        try {
          s.peers = nativeBridge.backendPeers();
        } catch (e) {
          s.peers = '[]';
        }
        this.writeStatus(s);
        this.startPolling();
        return;
      }
    }
    this.writeStatus(newStatus('failed', 'tun restart: ' + restart));
  }

  private startPolling(): void {
    if (this.timer >= 0) {
      return;
    }
    this.timer = setInterval(() => {
      if (this.destroyed) {
        return;
      }
      try {
        const s: TsStatus = newStatus('running', nativeBridge.backendStatus());
        s.selfIp = this.status.selfIp;
        s.peers = nativeBridge.backendPeers();
        this.writeStatus(s);
      } catch (e) {
        // 单轮失败保留上次状态
      }
    }, 2000);
  }

  private probeConfig(): vpnExtension.VpnConfig {
    const cfg: vpnExtension.VpnConfig = {
      addresses: [{ address: { address: '192.0.2.1', family: 1 }, prefixLength: 32 }],
      routes: [{
        interface: 'vpn-tun',
        destination: { address: { address: '192.0.2.0', family: 1 }, prefixLength: 24 },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: false
      }],
      mtu: 1280,
      isIPv4Accepted: true,
      isIPv6Accepted: false,
      isBlocking: false,
      trustedApplications: ['com.wlt.qnap.nasmanager']
    };
    return cfg;
  }

  private realConfig(ipv4: string, ipv6: string): vpnExtension.VpnConfig {
    const addresses: vpnExtension.LinkAddress[] = [
      { address: { address: ipv4, family: 1 }, prefixLength: 32 }
    ];
    const routes: vpnExtension.RouteInfo[] = [{
      interface: 'vpn-tun',
      destination: { address: { address: '100.64.0.0', family: 1 }, prefixLength: 10 },
      gateway: { address: '0.0.0.0', family: 1 },
      hasGateway: false,
      isDefaultRoute: false
    }];
    const hasV6: boolean = ipv6.length > 0 && ipv6.indexOf(':') > 0;
    if (hasV6) {
      addresses.push({ address: { address: ipv6, family: 2 }, prefixLength: 128 });
      routes.push({
        interface: 'vpn-tun',
        destination: { address: { address: 'fd7a:115c:a1e0::', family: 2 }, prefixLength: 48 },
        gateway: { address: '::', family: 2 },
        hasGateway: false,
        isDefaultRoute: false
      });
    }
    const cfg: vpnExtension.VpnConfig = {
      addresses: addresses,
      routes: routes,
      mtu: 1280,
      isIPv4Accepted: true,
      isIPv6Accepted: hasV6,
      isInternal: true,
      isBlocking: false,
      // 必须用 trustedApplications（VPN 网络白名单）让本应用走 tailnet。
      // 这里原来误用了 blockedApplications（黑名单 = 绕过 VPN），
      // 结果 VPN 连上了、App 自己却被排除在隧道外，访问 100.x 一律失败。
      // isBlocking 在 SDK 里是 TUN fd 的阻塞模式，与"应用是否走 VPN"无关。
      trustedApplications: ['com.wlt.qnap.nasmanager']
    };
    return cfg;
  }

  private async createTun(cfg: vpnExtension.VpnConfig): Promise<number> {
    const conn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (conn === undefined) {
      return -1;
    }
    try {
      return await conn.create(cfg);
    } catch (error) {
      const e: BusinessError = error as BusinessError;
      const code: number = e.code ?? -1;
      // 已有其它 VPN 占着：告诉 UI 明确原因，不盲目替换用户的 VPN
      this.writeStatus(newStatus('failed', 'vpn conflict code=' + code +
        (code === VPN_EXISTS_ERROR_CODE ? ' (another VPN is active)' : '')));
      return -1;
    }
  }

  private async destroyTun(): Promise<void> {
    const conn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (conn === undefined) {
      return;
    }
    try {
      await conn.destroy();
    } catch (e) {
      // 探针 TUN 可能已被系统回收
    }
    this.tunFd = -1;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}
