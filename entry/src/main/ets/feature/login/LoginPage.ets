import { AppConstants } from '../../common/constants/AppConstants';
import { Theme } from '../../common/constants/Theme';
import { t, tf, switchLanguage } from '../../common/i18n/I18n';
import { BreakpointSystem } from '../../common/utils/BreakpointSystem';
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import {
  TailscaleService, NasCandidate, TsConnectState
} from '../../service/TailscaleService';
import {
  validateIpv4, validatePort, validateUsername, validatePassword,
} from '../../common/utils/Validators';
import { LoginResult } from '../../model/Models';
import { NasRepository } from '../../service/NasRepository';
import { SessionManager } from '../../service/SessionManager';
import { IdTarget, QnapApi, RouteProbeResult } from '../../service/QnapApi';
import { LegalSheet } from '../../components/LegalSheet';
import { DemoMode } from '../../common/demo/DemoMode';

/** Tailscale 官方登录入口：扩展尚未给出 authUrl 时先展示它，保证登录页必经。 */
const TS_LOGIN_URL: string = 'https://login.tailscale.com/';

/** 跨重启保留的登录表单；故意不包含密码。 */
interface LoginForm {
  host: string;
  port: string;
  scheme: string;
  username: string;
  mode: string;
  tsPickedIp: string;
}

/**
 * 登录模块：支持两种真实接入方式。
 *
 * 1) IP 直连（localIp）：局域网内直接访问 http(s)://<IP>:<端口>，
 *    账号为 QTS 本地账号，认证走 /cgi-bin/authLogin.cgi。
 * 2) QNAP ID（qnapId）：用 myQNAPcloud 域名（<id>.myqnapcloud.com）定位设备，
 *    适合不在同一局域网时使用；认证仍由 QTS 完成，端口支持自动探测。
 *
 * 两种方式的会话都会把 sid / scheme / 密码一并持久化，
 * 否则冷启动后设备会把所有请求判为未认证（表现为页面空白、数据全 0）。
 */
@Component
export struct LoginPage {
  @StorageProp('appLanguage') lang: string = 'zh';
  @StorageProp('appTheme') theme: string = 'system';
  @StorageProp('breakpoint') bp: string = 'sm';
  /** 隐私政策 / 服务条款阅读层：空字符串表示未打开。 */
  @State legalKind: string = '';
  /** 当前登录方式：localIp / qnapId。 */
  @State mode: string = AppConstants.LOGIN_MODE_IP;
  /* ---- IP 直连 ---- */
  @State host: string = AppConstants.DEFAULT_HOST;
  @State port: string = String(AppConstants.DEFAULT_PORT);
  @State httpsOn: boolean = false;
  /* ---- 网页验证登录 ---- */
  @State showWeb: boolean = false;
  @State webUrl: string = '';
  /** 网页验证的当前阶段（读取设备地址时给用户反馈）。 */
  @State webStage: string = '';
  /** 主页面加载失败（弱网 / DNS 失败）：给「重试」入口，而不是一块白屏。 */
  @State webLoadError: boolean = false;
  private webCtl: webview.WebviewController = new webview.WebviewController();
  private webTimer: number = -1;
  /** 选路页轮询计数：云端要 20~25 秒才给出结果，不能一看就走。 */
  private webTries: number = 0;
  /** 已经用过的中继 NAS_SID，避免每次轮询重复建会话。 */
  private relayJarTried: string = '';
  /** 网页里已经采用过的 NAS_SID（同一条会话只采用一次，失败就改走原生登录）。 */
  private relaySidTried: string = '';
  /**
   * 中继原生登录的尝试次数与下次允许时间。
   * 必须退避：失败时每 2 秒重试一次会让 QTS 判为暴力破解，直接把账号锁掉。
   * 6 次之后不再用表单密码登录，只等用户在网页里登录 QTS（拿 NAS_SID 采用）。
   */
  private relayAttempts: number = 0;
  private relayNextAt: number = 0;
  /* ---- Tailscale 内网登录（分步骤向导）----
   * tsPhase 阶段流转：
   *   ''         未开始（普通登录页）
   *   connecting VPN 启动中（进度提示）
   *   auth       Tailscale 登录页（必经）：内嵌 WebView 让用户登录 tailnet
   *   pick       选择或手动填入 NAS 的 tailnet IP
   *   login      输入 NAS 账号密码
   *   logging    正在用内网地址登录 QTS
   */
  @State tsPhase: string = '';
  @State tsStage: string = '';
  /** Tailscale 登录 WebView 的地址：扩展给的 authUrl，或官方登录页兜底。 */
  @State tsAuthUrl: string = '';
  /** tsAuthUrl 是否为扩展给的真实授权 URL（带一次性 key），可随时被更新。 */
  private tsAuthUrlReal: boolean = false;
  /** 上次把授权 URL 装进 WebView 的时间：用于防抖，避免轮询反复重载打断输入。 */
  private tsUrlAppliedAt: number = 0;
  /** 用户已在授权页完成 Tailscale 登录（状态 running），可进入下一步选 IP。 */
  @State tsAuthed: boolean = false;
  /**
   * 引擎异常提示（非空时在登录页内联展示，不覆盖登录页）。
   * 登录页是必经步骤，任何引擎错误都不能把用户踢出这一步。
   */
  @State tsEngineErr: string = '';
  /** 引擎原始状态串（`OK | state=NeedsLogin | loginURLReady=…`），用于页内诊断。 */
  @State tsRawStatus: string = '';
  /** 「下一步」被拦住时的可见提示：没有它，用户会以为按钮坏了。 */
  @State tsAuthBlock: string = '';
  /** 诊断串默认折叠，避免向用户直接暴露引擎内部状态。 */
  @State tsDiagExpanded: boolean = false;
  /** 按 myserver/MyNAS 精确匹配的 NAS 候选（优先展示）。 */
  @State tsCandidates: NasCandidate[] = [];
  /** tailnet 全部在线节点，供「选 IP」步骤展示。 */
  @State tsPeers: NasCandidate[] = [];
  /** 用户在「选 IP」步骤选中或手动填入的 NAS 地址。 */
  @State tsPickedIp: string = '';
  @State tsIpErr: string = '';
  /** 「登录 NAS」步骤的独立账号密码（进入该步骤时用共用凭据预填）。 */
  @State tsUser: string = '';
  @State tsPass: string = '';
  @State tsUserErr: string = '';
  @State tsPassErr: string = '';
  /** NAS 登录失败原因：留在向导内显示，不能清空整个流程。 */
  @State tsLoginErr: string = '';
  private tsTimer: number = -1;
  private tsBusy: boolean = false;
  /** 扩展最后一次心跳时间（取自状态文件 updatedAt），用于判断扩展是否还活着。 */
  private tsLastBeat: number = 0;
  /** 上次自动重连扩展的时间，避免高频重启与系统抢占。 */
  private tsRestartAt: number = 0;
  private tsStartAt: number = 0;
  private tsContext: common.UIAbilityContext | undefined = undefined;
  private tsWebCtl: webview.WebviewController = new webview.WebviewController();

  /**
   * qlink.to 的链接多为 target=_blank；ArkWeb 未配置多窗口时会静默拦截。
   * 门户页阶段注入一次：把 _blank 改成 _self，并接管 window.open 到当前窗口。
   */
  private readonly BLANK_FIX: string =
    "(function(){try{var a=document.querySelectorAll('a[target]');" +
    "for(var i=0;i<a.length;i++){var t=(a[i].getAttribute('target')||'').toLowerCase();" +
    "if(t==='_blank'){a[i].setAttribute('target','_self');}}}catch(e){}" +
    "try{window.open=function(u){if(u){window.location.href=u;}return null;};}catch(e){}})()";

  /* ---- 共用凭据 ---- */
  @State username: string = AppConstants.DEFAULT_USER;
  @State password: string = AppConstants.DEFAULT_PASS;
  /* ---- 状态 ---- */
  @State loading: boolean = false;
  /** 自动选路结果提示（当前使用的接入点），让用户知道为什么填好了地址。 */
  @State routeText: string = '';
  /** 数据层上报的登录阶段（解析 ID / 扫描局域网 / 验证账号），避免长时间无反馈。 */
  @StorageLink('loginStage') loginStage: string = '';
  @State showFailure: boolean = false;
  @State failureTextKey: string = '';
  /** 失败时实际尝试过的 主机:端口，帮助用户判断是名称不对还是端口未开。 */
  @State failureTried: string = '';
  @State errHost: string = '';
  @State errPort: string = '';
  @State errUsername: string = '';
  @State errPassword: string = '';

  aboutToAppear(): void {
    // 先恢复用户上次填写的 IP / 端口 / 账号（不含密码），再应用设置页的模式预置。
    this.restoreForm();
    const preset: string | undefined = AppStorage.get<string>(AppConstants.APP_STORAGE_LOGIN_MODE);
    if (preset !== undefined && preset.length > 0) {
      this.mode = preset;
    }
    // 根据当前网络探测可达端点，自动优选延迟最低的线路。
    this.autoSelectRoute();
    // 冷启动恢复会话失败（多为中继会话过期）时，数据层会把原因放在这里是，
    // 直接以失败面板展示，用户才知道下一步该点「用网页验证登录」。
    const notice: string | undefined = AppStorage.get<string>('loginNotice');
    if (notice !== undefined && notice.length > 0) {
      this.failureTextKey = notice;
      this.failureTried = '';
      this.showFailure = true;
      AppStorage.setOrCreate<string>('loginNotice', '');
    }
  }

  aboutToDisappear(): void {
    this.stopWebWatch();
    this.stopTsWatch();
  }

  private stopTsWatch(): void {
    if (this.tsTimer >= 0) {
      clearInterval(this.tsTimer);
      this.tsTimer = -1;
    }
    this.tsBusy = false;
  }

  /* ================= 网页验证登录（纯 qlink.to 网页登录） =================
   * 只把 qlink.to 页面交给用户操作：QNAP ID + 二次验证 + NAS 账号密码都在网页里完成。
   * App 不做云端选路、不自动导航、不解析设备链接；
   * 网页完成后从 Cookie 里取 NAS_SID / 中继路由，原生建立会话进 App。
   */

  openWebLogin(): void {
    this.webUrl = 'https://qlink.to/';
    this.webStage = '';
    this.webLoadError = false;
    this.webTries = 0;
    this.relayJarTried = '';
    this.relaySidTried = '';
    this.relayAttempts = 0;
    this.relayNextAt = 0;
    this.showFailure = false;
    this.webCtl = new webview.WebviewController();
    this.showWeb = true;
    this.startWebWatch();
  }

  private startWebWatch(): void {
    this.stopWebWatch();
    this.webTimer = setInterval(() => {
      this.webTick();
    }, 2000);
  }

  private stopWebWatch(): void {
    if (this.webTimer >= 0) {
      clearInterval(this.webTimer);
      this.webTimer = -1;
    }
  }

  /** 定时器安全外壳：单轮异常不能冒泡，否则 unhandled rejection 会闪退。 */
  private async webTick(): Promise<void> {
    try {
      await this.webTickInner();
    } catch (e) {
      // 吞掉单轮异常，保证轮询存活
    }
  }

  /**
   * 纯网页登录模式：只在网页里完成了 NAS 登录（Cookie 里出现 NAS_SID 或
   * 中继路由）时才尝试建会话；其余时间完全把控制权交回网页，不自动跳转。
   */
  private async webTickInner(): Promise<void> {
    if (!this.showWeb) {
      this.stopWebWatch();
      return;
    }
    let url: string = '';
    try {
      url = this.webCtl.getUrl();
    } catch (e) {
      return;
    }
    if (url === undefined || url.length === 0) {
      return;
    }
    this.webTries++;
    const host: string = this.pageHost(url).toLowerCase();
    const isPortal: boolean = host.indexOf('qlink.to') >= 0 ||
      host.indexOf('myqnapcloud.cn') >= 0 || host.indexOf('account.qnap.com') >= 0 ||
      host.indexOf('goto.myqnapcloud.cn') >= 0;
    // qlink.to 的链接默认 target=_blank，ArkWeb 未配多窗口时会静默拦截
    if (isPortal && this.webTries <= 3) {
      try {
        await this.webCtl.runJavaScript(this.BLANK_FIX);
      } catch (e) {
        // 注入失败不影响用户手动操作
      }
      return;
    }
    if (isPortal) {
      this.webStage = 'login.web.qts';
      return;
    }
    // 已离开门户域（中继节点 / QTS 页）→ 尝试复用网页会话
    this.webStage = 'login.web.entering';
    const entered: boolean = await this.tryRelaySession(url);
    if (entered) {
      this.stopWebWatch();
      this.showWeb = false;
      this.webStage = '';
    } else {
      this.webStage = 'login.web.qts';
    }
  }

  /**
   * 从内嵌网页的 Cookie 里取 CloudLink 中继会话，直接进 App。
   *
   * 分工：网页只负责**QNAP ID 登录 + 二次验证**（原生做不到），
   * 一旦进到中继里的设备页（`d2.myqnapcloud.cn/cgi-bin/`），中继路由 Cookie
   * （`qcloud_tunnel_sid` / `qcloud_tunnel_agent_id` / `cloudRelayMode`）就已就位；
   * App 拿这组 Cookie 走一次原生 `authLogin` 就能拿到自己的 NAS_SID，
   * 之后系统信息、监控、文件、容器全部走中继 —— **不需要端口映射**。
   */
  private async tryRelaySession(pageUrl: string): Promise<boolean> {
    // 退避期内直接返回：中继登录失败后不能每 2 秒重试，否则账号会被 QTS 锁掉。
    if (Date.now() < this.relayNextAt) {
      return false;
    }
    let jar: string = '';
    try {
      jar = await webview.WebCookieManager.fetchCookie(pageUrl);
    } catch (e) {
      jar = '';
    }
    // 双通道兜底：HttpOnly Cookie 在部分内核上 fetchCookie 拿不全，
    // 再补一次 document.cookie（非 HttpOnly 部分），两份合并。
    if (jar === undefined) {
      jar = '';
    }
    let docCookie: string = '';
    try {
      docCookie = await this.webCtl.runJavaScript('document.cookie');
    } catch (e) {
      docCookie = '';
    }
    if (docCookie !== undefined && docCookie.length > 0 && jar.indexOf(docCookie) < 0) {
      jar = jar.length > 0 ? (jar + '; ' + docCookie) : docCookie;
    }
    if (jar.length === 0) {
      return false;
    }
    // 必须看到中继路由标志（或网页已登录 QTS 的 NAS_SID）才值得尝试。
    // 门户页自己的 API 子域（api.myqnapcloud.cn 等）也会被网络资源反查出来，
    // 没有这道门会把 6 次登录尝试烧在假节点上，还会把「请在此页面输入 NAS
    // 账号密码」的提示错误地挂在设备列表页上（1.2.4 / 1.2.5 的回归）。
    const hasRelay: boolean = jar.indexOf('qcloud_tunnel') >= 0 ||
      jar.indexOf('cloudRelayMode') >= 0 || jar.indexOf('NAS_SID') >= 0;
    if (!hasRelay) {
      return false;
    }
    if (jar === this.relayJarTried && this.relayAttempts >= 6) {
      return false;   // 同一份 Cookie 且已用尽原生登录次数：只等网页登录产生 NAS_SID
    }
    this.relayJarTried = jar;

    // 拆分 Cookie：中继路由 Cookie 全留，NAS_SID / home 单独处理
    // （NAS_SID 由网页里的 QTS 登录产生，可被 App 直接采用；home 由 App 自己登录时补齐）。
    const kept: string[] = [];
    let nasSid: string = '';
    for (const piece of jar.split(';')) {
      const one: string = piece.trim();
      if (one.length === 0) {
        continue;
      }
      const eq: number = one.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const name: string = one.substring(0, eq);
      if (name === 'NAS_SID') {
        nasSid = one.substring(eq + 1);
        continue;
      }
      if (name === 'home') {
        continue;
      }
      kept.push(one);
    }
    // 中继主机名从当前页面地址取（形如 https://d2.myqnapcloud.cn/cgi-bin/）
    const host: string = this.pageHost(pageUrl);
    if (host.length === 0) {
      return false;
    }

    // ① 用户已经在网页里登录过 QTS（Cookie 里有 NAS_SID）→ 直接沿用这条会话，
    //    不需要密码、也是「网页验证完就能进」最快的一条路。
    if (nasSid.length > 0 && nasSid !== this.relaySidTried) {
      this.relaySidTried = nasSid;
      this.webStage = 'login.web.entering';
      const adopted: LoginResult = await NasRepository.adoptRelay(host, nasSid, kept.join('; '),
        this.username.trim(), this.password);
      if (adopted.success && adopted.session !== null) {
        SessionManager.save(adopted.session);
        return true;
      }
    }

    // ② 否则用中继路由 Cookie + 表单账号密码自己登录（实测可行）。
    //    限次 + 逐次加长间隔：4s、8s、12s… 六次后改为只等网页登录。
    if (this.relayAttempts >= 6) {
      this.webStage = 'login.web.needQts';
      return false;
    }
    this.relayAttempts++;
    this.relayNextAt = Date.now() + 4000 * this.relayAttempts;
    this.webStage = 'login.web.entering';
    const result: LoginResult = await NasRepository.loginViaRelay(host, kept.join('; '),
      this.username.trim(), this.password);
    if (result.success && result.session !== null) {
      SessionManager.save(result.session);
      return true;
    }
    this.failureTextKey = result.errorKey.length > 0 ? result.errorKey : 'login.fail.network';
    this.failureTried = host + ' · 中继会话';
    // 密码被拒 / 中继过期：不再自动重试，提示用户直接在网页里登录 QTS，
    // 一旦网页登录成功，下一轮就会走进 ① 采用 NAS_SID。
    if (result.errorKey === 'login.fail.invalid' || result.errorKey === 'login.fail.relayExpired') {
      this.webStage = 'login.web.needQts';
    } else {
      this.webStage = 'login.web.qts';
    }
    return false;
  }

  /** 恢复上次填写的登录信息（不含密码），避免每次重启重复输入。 */
  private restoreForm(): void {
    const raw: string | undefined = AppStorage.get<string>(AppConstants.APP_STORAGE_LOGIN_FORM);
    if (raw === undefined || raw.length === 0) {
      return;
    }
    try {
      const form: LoginForm = JSON.parse(raw) as LoginForm;
      if (form.host !== undefined && form.host.length > 0) {
        this.host = form.host;
      }
      if (form.port !== undefined && form.port.length > 0) {
        this.port = form.port;
      }
      this.httpsOn = form.scheme === 'https';
      if (form.username !== undefined) {
        this.username = form.username;
      }
      if (form.tsPickedIp !== undefined && form.tsPickedIp.length > 0) {
        this.tsPickedIp = form.tsPickedIp;
      }
      const preset: string | undefined = AppStorage.get<string>(AppConstants.APP_STORAGE_LOGIN_MODE);
      if ((preset === undefined || preset.length === 0) && form.mode !== undefined &&
        form.mode.length > 0) {
        this.mode = form.mode;
      }
    } catch (e) {
      // 坏配置直接忽略，不阻塞登录页渲染
    }
  }

  /** 保存当前输入；密码不写入持久化存储。 */
  private persistForm(): void {
    const form: LoginForm = {
      host: this.host,
      port: this.port,
      scheme: this.httpsOn ? 'https' : 'http',
      username: this.username,
      mode: this.mode,
      tsPickedIp: this.tsPickedIp
    };
    AppStorage.setOrCreate<string>(AppConstants.APP_STORAGE_LOGIN_FORM, JSON.stringify(form));
  }

  /**
   * 按当前网络自动选路：上次成功端点 / 已填地址 / 外网地址并发探测，
   * 选延迟最低且返回真实 QTS sysinfo 的端点；都不可达时退回 Tailscale 在线节点。
   */
  private async autoSelectRoute(): Promise<void> {
    const candidates: IdTarget[] = [];
    const addTarget = (target: IdTarget | null): void => {
      if (target === null || target.host.length === 0) {
        return;
      }
      for (const item of candidates) {
        if (item.host === target.host && item.port === target.port && item.scheme === target.scheme) {
          return;
        }
      }
      candidates.push(target);
    };
    addTarget(QnapApi.lastEndpointTarget());
    if (this.host.length > 0 && validateIpv4(this.host).length === 0) {
      const port: number = Number(this.port);
      const target: IdTarget = {
        host: this.host.trim(), port: port > 0 ? port : 5000,
        scheme: this.httpsOn ? 'https' : 'http'
      };
      addTarget(target);
    }
    const wanTargets: IdTarget[] = QnapApi.wanTargets();
    for (const target of wanTargets) {
      addTarget(target);
    }
    if (candidates.length === 0) {
      return;
    }

    const probes: Promise<RouteProbeResult>[] = [];
    for (const target of candidates) {
      probes.push(QnapApi.probeRoute(target.host, target.port, target.scheme));
    }
    try {
      const results: RouteProbeResult[] = await Promise.all(probes);
      let best: RouteProbeResult | null = null;
      for (const result of results) {
        if (!result.ok) {
          continue;
        }
        if (best === null || result.latencyMs < best.latencyMs) {
          best = result;
        }
      }
      if (best !== null) {
        this.host = best.host;
        this.port = String(best.port);
        this.httpsOn = best.scheme === 'https';
        this.mode = AppConstants.LOGIN_MODE_IP;
        this.routeText = tf('login.route.auto', this.lang, best.host + ':' + String(best.port));
        this.persistForm();
        return;
      }
    } catch (e) {
      // 探测失败不改变用户已填信息
    }

    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const state: TsConnectState = TailscaleService.poll(ctx);
      if (state.state === 'running' && state.peers.length > 0) {
        this.mode = AppConstants.LOGIN_MODE_QID;
        this.tsPickedIp = state.peers[0].address;
        this.routeText = t('login.route.tailscale', this.lang);
        this.persistForm();
      }
    } catch (e) {
      // 预览器 / 无 VPN 扩展时保持原登录方式
    }
  }

  isIdMode(): boolean {
    return this.mode === AppConstants.LOGIN_MODE_QID;
  }

  /** 从 URL 提取主机名（去掉协议 / 路径 / 端口）。 */
  private pageHost(url: string): string {
    let rest: string = url;
    const sep: number = rest.indexOf('://');
    if (sep >= 0) {
      rest = rest.substring(sep + 3);
    }
    const slash: number = rest.indexOf('/');
    if (slash >= 0) {
      rest = rest.substring(0, slash);
    }
    const colon: number = rest.indexOf(':');
    if (colon > 0) {
      rest = rest.substring(0, colon);
    }
    return rest;
  }

  selectMode(mode: string): void {
    this.mode = mode;
    this.showFailure = false;
    this.errHost = '';
    this.errPort = '';
    AppStorage.setOrCreate<string>(AppConstants.APP_STORAGE_LOGIN_MODE, mode);
    this.persistForm();
  }

  validateForm(): boolean {
    this.errUsername = validateUsername(this.username);
    this.errPassword = validatePassword(this.password);
    if (this.isIdMode()) {
      // ID 登录 = Tailscale 内网登录：不需要设备名 / 端口 / 外网接入点
      return this.errUsername.length === 0 && this.errPassword.length === 0;
    }
    this.errHost = validateIpv4(this.host);
    this.errPort = validatePort(this.port);
    return this.errHost.length === 0 && this.errPort.length === 0 &&
      this.errUsername.length === 0 && this.errPassword.length === 0;
  }

  /**
   * ID 登录入口第一步：拉起 Tailscale VPN（首次弹系统授权），然后轮询状态。
   * 只负责把 VPN 连起来 + 收集节点；选 IP、输账号密码分别由后续步骤完成。
   */
  private async tailscaleLogin(): Promise<void> {
    this.stopTsWatch();
    this.tsPhase = 'connecting';
    this.tsStage = 'login.ts.starting';
    this.tsAuthUrl = '';
    this.tsAuthUrlReal = false;
    this.tsUrlAppliedAt = 0;
    this.tsAuthed = false;
    this.tsCandidates = [];
    this.tsPeers = [];
    this.tsPickedIp = '';
    this.tsIpErr = '';
    this.tsUserErr = '';
    this.tsPassErr = '';
    this.tsEngineErr = '';
    this.tsLastBeat = 0;
    this.tsRestartAt = 0;
    this.showFailure = false;
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      this.tsContext = ctx;
      // 清掉上一轮残留状态，避免刚进登录页就显示上次的失败信息。
      TailscaleService.clearStaleFailure(ctx);
      await TailscaleService.start(ctx);
    } catch (e) {
      this.resetTsFlow();
      this.failureTextKey = 'login.ts.vpnFailed';
      // 把真实异常带出来：预览器不支持 VpnExtensionAbility、真机缺 VPN 授权、
      // 系统限制等原因都会在这里抛，静默吞掉会让用户只看到一句无信息的失败。
      this.failureTried = e instanceof Error ? e.message : String(e);
      this.showFailure = true;
      return;
    }
    // 登录页是必经步骤：VPN 已拉起就立刻展示 Tailscale 官网登录页。
    // 不等引擎状态——引擎可能仍在 starting，带一次性 key 的 authUrl 稍后到了再替换。
    this.tsPhase = 'auth';
    this.tsAuthUrl = TS_LOGIN_URL;
    this.tsAuthUrlReal = false;
    this.tsStage = 'login.ts.auth';
    this.tsStartAt = Date.now();
    this.tsTimer = setInterval(() => {
      this.tsTick();
    }, 1500);
  }

  /**
   * 轮询 VPN 扩展状态。登录页已在 tailscaleLogin 里直接就位，这里只做三件事：
   *   1. 扩展给出带一次性 key 的 authUrl 时替换官网登录页（换到真正能完成授权的地址）；
   *   2. 引擎 running 时标记 tsAuthed，并收集 tailnet 节点供「选 IP」使用；
   *   3. 引擎异常只写 tsEngineErr 内联提示 + 提供重试，绝不覆盖登录页。
   * 登录页是必经步骤，不能被任何引擎状态跳过。
   */
  private tsTick(): void {
    if (this.tsBusy || this.tsContext === undefined) {
      return;
    }
    if (this.tsPhase !== 'auth') {
      return;
    }
    const st: TsConnectState = TailscaleService.poll(this.tsContext);
    // 原始状态留作页内诊断：NeedsLogin / Starting / Running 一眼可见。
    this.tsRawStatus = st.detail.length > 200 ? st.detail.substring(0, 200) : st.detail;
    this.tsLastBeat = st.updatedAt;

    // 存活检测：扩展正常时每秒写一次状态（running 后 2 秒一次）。
    // 超过 8 秒没心跳 = 扩展已被系统回收，状态文件里只是旧快照；
    // 若继续相信它，就会出现"网页提示 Login successful、页头还写着 NeedsLogin"
    // 这种自相矛盾，用户永远点不动下一步。
    const age: number = st.updatedAt > 0
      ? Date.now() - st.updatedAt
      : (this.tsStartAt > 0 ? Date.now() - this.tsStartAt : 0);
    if (age > 8000) {
      this.tsAuthed = false;
      this.tsEngineErr = t('login.ts.engineDead', this.lang);
      this.tsStage = 'login.ts.auth.wait';
      // 自动重连（15 秒最多一次，避免和系统抢占）
      if (Date.now() - this.tsRestartAt > 15000) {
        this.tsRestartAt = Date.now();
        this.tsRestartEngine();
      }
      return;
    }
    if (st.state === 'failed' || st.state === 'timeout' || st.state === 'stopped') {
      // 保持登录页可见，仅提示引擎异常，由用户决定重试或改用 IP 登录。
      this.stopTsWatch();
      this.tsEngineErr = st.detail;
      this.tsAuthed = false;
      this.tsStage = 'login.ts.auth.wait';
      return;
    }
    if (st.candidates.length > 0 || st.peers.length > 0) {
      this.tsCandidates = st.candidates;
      this.tsPeers = st.peers;
    }
    this.tsEngineErr = '';
    if (st.state === 'running') {
      this.tsAuthed = true;
      this.tsAuthBlock = '';
      // 真实授权 URL 晚到时切过去（官网兜底页 -> 带 key 的授权页）。
      this.tsApplyAuthUrl(st.authUrl);
      this.tsStage = 'login.ts.auth.ok';
      return;
    }
    if (st.state === 'needs_login') {
      this.tsApplyAuthUrl(st.authUrl);
      this.tsAuthed = false;
      this.tsStage = 'login.ts.auth';
      return;
    }
    // starting 等中间态：登录页已可用，仅提示 VPN 仍在建立。
    this.tsAuthed = false;
    this.tsStage = 'login.ts.auth';
  }

  /**
   * ArkUI 的 `Web({ src })` 只在组件创建时取一次 src，之后改绑定的状态不会重新加载。
   * 拿到真实授权 URL 时必须显式 loadUrl，否则页面一直停在上一个地址
   * （真机现象：引擎有授权链接，但网页停在官网后台，怎么登录都不会授权本机）。
   */
  private tsLoadAuthUrl(url: string): void {
    try {
      this.tsWebCtl.loadUrl(url);
    } catch (e) {
      // Web 还没创建完成时会抛：此时创建用的就是 tsAuthUrl 的新值，无需处理
    }
  }

  /**
   * 装载授权 URL。按「地址是否变化」判断而不是一次性标志：
   * 一次性授权链接过期后引擎会给出新链接，若只允许替换一次就会永远卡在旧页。
   * 8 秒防抖避免轮询反复重载打断用户输入。
   */
  private tsApplyAuthUrl(url: string): void {
    if (url.length === 0) {
      return;
    }
    if (url === this.tsAuthUrl && this.tsAuthUrlReal) {
      return;
    }
    const now: number = Date.now();
    if (now - this.tsUrlAppliedAt < 8000) {
      return;
    }
    this.tsUrlAppliedAt = now;
    this.tsAuthUrl = url;
    this.tsAuthUrlReal = true;
    this.tsLoadAuthUrl(url);
  }

  /** 手动重新检测：恢复轮询并立刻拉一次状态（防止定时器已停）。 */
  private tsRecheck(): void {
    if (this.tsContext === undefined) {
      return;
    }
    this.tsAuthBlock = '';
    if (this.tsTimer < 0) {
      this.tsStartAt = Date.now();
      this.tsTimer = setInterval(() => {
        this.tsTick();
      }, 1500);
    }
    this.tsTick();
    if (!this.tsAuthed) {
      this.tsAuthBlock = 'login.ts.auth.stillNeedsLogin';
    }
  }

  /** 扩展是否还活着（8 秒内有心跳）。 */
  private tsAlive(): boolean {
    if (this.tsLastBeat <= 0) {
      return false;
    }
    return Date.now() - this.tsLastBeat < 8000;
  }

  /** 扩展已被回收时重连：失效状态文件不可信，先删掉再拉起扩展。 */
  private async tsRestartEngine(): Promise<void> {
    if (this.tsContext === undefined || this.tsBusy) {
      return;
    }
    this.tsBusy = true;
    try {
      TailscaleService.clearStatus(this.tsContext);
      await TailscaleService.start(this.tsContext);
      this.tsStartAt = Date.now();
      this.tsLastBeat = 0;
    } catch (e) {
      this.tsEngineErr = e instanceof Error ? e.message : String(e);
    } finally {
      this.tsBusy = false;
    }
  }

  /** 引擎异常后重试：扩展还活着时不要盲目重启，先恢复轮询，登录页留在原位。 */
  private async tsRetryEngine(): Promise<void> {
    if (this.tsBusy || this.tsContext === undefined) {
      return;
    }
    this.tsBusy = true;
    this.tsEngineErr = '';
    this.tsAuthBlock = '';
    this.tsStage = 'login.ts.retrying';
    try {
      // 扩展已死：状态文件整体不可信，直接删；还活着则只清失败态。
      if (this.tsAlive()) {
        TailscaleService.clearStaleFailure(this.tsContext);
      } else {
        TailscaleService.clearStatus(this.tsContext);
      }
      await TailscaleService.start(this.tsContext);
      this.tsStartAt = Date.now();
      this.tsLastBeat = 0;
      this.stopTsWatch();
      this.tsTimer = setInterval(() => {
        this.tsTick();
      }, 1500);
    } catch (e) {
      this.tsEngineErr = e instanceof Error ? e.message : String(e);
    } finally {
      this.tsBusy = false;
    }
  }

  /** 兜底出口：VPN 始终连不上时，允许直接用 IP 登录（同一局域网仍可达）。 */
  private tsSkipEngine(): void {
    this.stopTsWatch();
    this.tsEngineErr = '';
    this.tsAuthBlock = '';
    this.tsStage = '';
    this.tsPickedIp = '';
    this.tsIpErr = '';
    this.tsPhase = 'pick';
  }

  /**
   * Tailscale 登录页的「下一步」：
   * - 尚未连上 tailnet：提示用户先在页面里登录，不推进；
   * - 已连上：收集到的节点带到选 IP 步骤。
   */
  private tsAuthNext(): void {
    if (!this.tsAuthed) {
      // 必须给强反馈：原来只改一行小字，用户以为按钮坏了。
      // 同时「跳过 VPN」按钮就在下面，是明确出口。
      this.tsAuthBlock = 'login.ts.auth.blocked';
      this.tsStage = 'login.ts.auth.wait';
      return;
    }
    this.tsAuthBlock = '';
    this.stopTsWatch();
    this.tsAuthUrl = '';
    this.tsStage = '';
    this.tsPickedIp = this.tsCandidates.length === 1 ? this.tsCandidates[0].address : '';
    this.tsIpErr = '';
    this.tsPhase = 'pick';
  }

  /** 从「选 IP」退回 Tailscale 登录页，并恢复状态轮询（否则回去后永远等不到 Running）。 */
  private tsBackToAuth(): void {
    this.tsPhase = 'auth';
    this.tsIpErr = '';
    this.tsAuthBlock = '';
    if (this.tsContext !== undefined) {
      this.stopTsWatch();
      this.tsStartAt = Date.now();
      this.tsTimer = setInterval(() => {
        this.tsTick();
      }, 1500);
    }
  }

  /** 「选 IP」步骤：确认地址合法后进入「登录 NAS」步骤。 */
  private tsConfirmIp(): void {
    const ip: string = this.tsPickedIp.trim();
    this.tsIpErr = validateIpv4(ip);
    if (this.tsIpErr.length > 0) {
      return;
    }
    this.tsPickedIp = ip;
    // 保留用户已保存的账号，避免重复输入；密码始终留空，由当前使用者现场输入。
    this.tsUser = this.username;
    this.tsPass = '';
    this.tsUserErr = '';
    this.tsPassErr = '';
    this.tsLoginErr = '';
    this.tsPhase = 'login';
  }

  /** 点选列表里的节点：填入地址并直接进入「登录 NAS」步骤。 */
  private tsPickCandidate(c: NasCandidate): void {
    this.tsPickedIp = c.address;
    this.tsIpErr = '';
    // 同上：只带账号，不带密码。
    this.tsUser = this.username;
    this.tsPass = '';
    this.tsUserErr = '';
    this.tsPassErr = '';
    this.tsLoginErr = '';
    this.tsPhase = 'login';
  }

  /** 「登录 NAS」步骤：校验账号密码后用 tailnet IP 走原生 QTS 登录。 */
  private async tsFinishTailscale(): Promise<void> {
    if (this.tsBusy) {
      return;
    }
    this.tsUserErr = validateUsername(this.tsUser);
    this.tsPassErr = validatePassword(this.tsPass);
    if (this.tsUserErr.length > 0 || this.tsPassErr.length > 0) {
      return;
    }
    this.tsBusy = true;
    this.tsPhase = 'logging';
    const address: string = this.tsPickedIp;
    try {
      const result: LoginResult = await TailscaleService.login(
        address, this.tsUser.trim(), this.tsPass);
      if (result.success && result.session !== null) {
        SessionManager.save(result.session);
        this.resetTsFlow();
        return;
      }
      // 失败时留在向导内报错：一旦 resetTsFlow，向导连同已填地址/账号都消失，
      // 用户只看到底层表单，观感就是"点登录没反应"。
      this.tsPhase = 'login';
      const netErr: string = result.errorKey.length > 0 ? result.errorKey : 'login.fail.network';
      // 100.x 必须走 Tailscale 隧道。VPN 没连上时"连不上设备"的真实原因是隧道不在，
      // 而不是主机名/端口问题，必须报准确原因，否则用户会一直去查 NAS 设置。
      this.tsLoginErr = (!this.tsAuthed && address.indexOf('100.') === 0)
        ? 'login.ts.vpnNeeded' : netErr;
    } finally {
      this.tsBusy = false;
    }
  }

  /** 返回上一步 / 关闭向导：清空阶段状态。 */
  private resetTsFlow(): void {
    this.stopTsWatch();
    this.tsPhase = '';
    this.tsStage = '';
    this.tsAuthUrl = '';
    this.tsAuthUrlReal = false;
    this.tsUrlAppliedAt = 0;
    this.tsAuthed = false;
    this.tsEngineErr = '';
    this.tsAuthBlock = '';
    this.tsRawStatus = '';
    this.tsLastBeat = 0;
    this.tsRestartAt = 0;
    this.tsCandidates = [];
    this.tsPeers = [];
    this.tsPickedIp = '';
    this.tsIpErr = '';
    this.tsUser = '';
    this.tsPass = '';
    this.tsUserErr = '';
    this.tsPassErr = '';
    this.tsLoginErr = '';
  }

  /**
   * 审核预览入口：写入独立的演示会话，不触发任何真实登录请求。
   * 真实登录 / Tailscale 向导代码完全不动，退出登录会一并关闭预览标记。
   */
  private enterDemo(): void {
    this.resetTsFlow();
    this.showWeb = false;
    this.webLoadError = false;
    this.loading = false;
    this.showFailure = false;
    this.tsDiagExpanded = false;
    AppStorage.setOrCreate<string>('loginNotice', '');
    DemoMode.enter();
    SessionManager.save(DemoMode.session());
  }

  async submit(): Promise<void> {
    if (this.isIdMode()) {
      // ID 登录 = 分步骤向导：先连 VPN，再选 NAS IP，最后单独输账号密码。
      // 此阶段不校验账号密码（那是向导最后一步的事）。
      this.showFailure = false;
      AppStorage.setOrCreate<string>('loginStage', '');
      await this.tailscaleLogin();
      return;
    }
    if (!this.validateForm()) {
      return;
    }
    this.loading = true;
    this.showFailure = false;
    AppStorage.setOrCreate<string>('loginStage', '');
    const result: LoginResult = await NasRepository.login(this.host.trim(), Number(this.port),
      this.username.trim(), this.password, this.httpsOn ? 'https' : 'http');
    this.loading = false;
    AppStorage.setOrCreate<string>('loginStage', '');
    if (result.success && result.session !== null) {
      SessionManager.save(result.session);
      return;
    }
    this.failureTextKey = result.errorKey.length > 0 ? result.errorKey : 'login.fail.network';
    this.failureTried = result.tried !== undefined ? result.tried : '';
    this.showFailure = true;
  }

  @Builder
  fieldLabel(text: string) {
    Text(text)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.textSecondary(this.theme))
      .margin({ bottom: 7, top: 14 })
  }

  @Builder
  fieldError(key: string) {
    if (key.length > 0) {
      Row() {
        Image($r('app.media.ic_warning'))
          .width(13)
          .height(13)
          .fillColor(Theme.DANGER)
        Text(t(key, this.lang))
          .fontSize(11)
          .fontColor(Theme.DANGER)
          .margin({ left: 5 })
      }
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  inputField(value: string, hintKey: string, isPassword: boolean, onChange: (value: string) => void) {
    TextInput({ placeholder: t(hintKey, this.lang), text: value })
      .width('100%')
      .height(46)
      .fontSize(14)
      .fontColor(Theme.textPrimary(this.theme))
      .placeholderColor(Theme.textSecondary(this.theme))
      .caretColor(Theme.PRIMARY)
      .backgroundColor(Theme.subCardBg(this.theme))
      .borderRadius(10)
      .padding({ left: 14, right: 14 })
      .type(isPassword ? InputType.Password : InputType.Normal)
      .onChange((text: string) => {
        onChange(text);
      })
  }

  @Builder
  langSwitch() {
    Row() {
      Image($r('app.media.ic_language'))
        .width(16)
        .height(16)
        .fillColor(Theme.textSecondary(this.theme))
      Text(this.lang === AppConstants.LANG_ZH ? 'EN' : '中')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.theme))
        .margin({ left: 6 })
    }
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(Theme.glassBg(this.theme))
    .backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 1, color: Theme.glassBorder(this.theme) })
    .borderRadius(18)
    .onClick(() => {
      switchLanguage(this.lang === AppConstants.LANG_ZH ? AppConstants.LANG_EN : AppConstants.LANG_ZH);
    })
  }

  /** 登录方式切换：两个等宽胶囊，选中项用玻璃白底 + 主色文字。 */
  @Builder
  modeSwitcher() {
    Row() {
      this.modeButton('login.mode.ip', AppConstants.LOGIN_MODE_IP)
      this.modeButton('login.mode.id', AppConstants.LOGIN_MODE_QID)
    }
    .width('100%')
    .padding(4)
    .backgroundColor(Theme.subCardBg(this.theme))
    .borderRadius(14)
    .margin({ top: 10, bottom: 2 })
  }

  @Builder
  modeButton(labelKey: string, mode: string) {
    Row() {
      Text(t(labelKey, this.lang))
        .fontSize(13)
        .fontWeight(this.mode === mode ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.mode === mode ? Theme.PRIMARY : Theme.textSecondary(this.theme))
    }
    .layoutWeight(1)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.mode === mode ? Theme.cardBg(this.theme) : Color.Transparent)
    .borderRadius(11)
    .onClick(() => {
      this.selectMode(mode);
    })
  }

  @Builder
  brandPanel() {
    Column() {
      Image($r('app.media.app_icon'))
        .width(72)
        .height(72)
        .borderRadius(18)
      Text(t('app.name', this.lang))
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.theme))
        .margin({ top: 20 })
      Text(t('app.tagline', this.lang))
        .fontSize(13)
        .fontColor(Theme.textSecondary(this.theme))
        .margin({ top: 8 })
      Column() {
        Row() {
          Image($r('app.media.ic_shield'))
            .width(16)
            .height(16)
            .fillColor(Theme.PRIMARY)
          Text(t('login.secure.tip', this.lang))
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ left: 8 })
            .layoutWeight(1)
        }
        .width('100%')
        .padding(12)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .margin({ top: 28 })
      .backgroundColor(Theme.primarySoft(this.theme))
      .borderRadius(12)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  ipForm() {
    Column() {
      this.fieldLabel(t('login.ip.address', this.lang))
      this.inputField(this.host, 'login.ip.addressHint', false, (text: string) => {
        this.host = text;
        this.errHost = '';
        this.persistForm();
      })
      this.fieldError(this.errHost)

      Row() {
        Column() {
          this.fieldLabel(t('login.ip.port', this.lang))
          this.inputField(this.port, 'login.ip.portHint', false, (text: string) => {
            this.port = text;
            this.errPort = '';
            this.persistForm();
          })
          this.fieldError(this.errPort)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column() {
          this.fieldLabel(t('login.ip.https', this.lang))
          Row() {
            Toggle({ type: ToggleType.Switch, isOn: this.httpsOn })
              .width(38)
              .height(22)
              .selectedColor(Theme.PRIMARY)
              .switchPointColor('#FFFFFF')
              .onChange((isOn: boolean) => {
                this.httpsOn = isOn;
                this.persistForm();
              })
            Text(this.httpsOn ? 'HTTPS' : 'HTTP')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.theme))
              .margin({ left: 9 })
          }
          .height(46)
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  idForm() {
    Column() {
      Text(t('login.ts.desc', this.lang))
        .fontSize(12)
        .lineHeight(18)
        .fontColor(Theme.textSecondary(this.theme))
        .width('100%')

      Button(t('login.ts.connect', this.lang), { type: ButtonType.Capsule })
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.buttonPrimaryFg(this.theme))
        .backgroundColor(Theme.buttonPrimaryBg(this.theme))
        .borderRadius(11)
        .margin({ top: 12 })
        .onClick(() => {
          this.submit();
        })

      Row() {
        Text(t('login.ts.or', this.lang))
          .fontSize(11)
          .fontColor(Theme.textSecondary(this.theme))
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 12, bottom: 2 })

      Button(t('login.web.btn', this.lang), { type: ButtonType.Capsule })
        .width('100%')
        .height(40)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.PRIMARY)
        .backgroundColor(Theme.subCardBg(this.theme))
        .borderRadius(11)
        .onClick(() => {
          this.openWebLogin();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  credentialForm() {
    Column() {
      Row() {
        Column() {
          this.fieldLabel(t('login.ip.username', this.lang))
          this.inputField(this.username, 'login.ip.usernameHint', false, (text: string) => {
            this.username = text;
            this.errUsername = '';
            this.persistForm();
          })
          this.fieldError(this.errUsername)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      this.fieldLabel(t('login.ip.password', this.lang))
      this.inputField(this.password, 'login.ip.passwordHint', true, (text: string) => {
        this.password = text;
        this.errPassword = '';
      })
      this.fieldError(this.errPassword)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  failurePanel() {
    Column() {
      Row() {
        Image($r('app.media.ic_warning'))
          .width(20)
          .height(20)
          .fillColor(Theme.DANGER)
        Text(t('login.fail.title', this.lang))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.DANGER)
          .margin({ left: 8 })
          .layoutWeight(1)
        Image($r('app.media.ic_close'))
          .width(16)
          .height(16)
          .fillColor(Theme.textSecondary(this.theme))
          .accessibilityText(t('action.close', this.lang))
          .onClick(() => {
            this.showFailure = false;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(t(this.failureTextKey, this.lang))
        .fontSize(12)
        .lineHeight(19)
        .fontColor(Theme.textPrimary(this.theme))
        .margin({ top: 10 })
        .width('100%')

      Text('· ' + t(this.isIdMode() ? 'login.fail.reason.id1' : 'login.fail.reason1', this.lang))
        .fontSize(11)
        .fontColor(Theme.textSecondary(this.theme))
        .margin({ top: 8 })
        .width('100%')
      Text('· ' + t(this.isIdMode() ? 'login.fail.reason.id2' : 'login.fail.reason2', this.lang))
        .fontSize(11)
        .fontColor(Theme.textSecondary(this.theme))
        .margin({ top: 4 })
        .width('100%')

      if (this.failureTried.length > 0) {
        Text(t('login.fail.tried', this.lang) + ' ' + this.failureTried)
          .fontSize(10)
          .lineHeight(16)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 8 })
          .width('100%')
      }

      // VPN 扩展在 DevEco 预览器里根本不存在：明确提示改用真机，
      // 避免把"环境不支持"误判成"Tailscale 登录页没实现"。
      if (this.failureTextKey === 'login.ts.vpnFailed') {
        Text('· ' + t('login.ts.previewHint', this.lang))
          .fontSize(10)
          .lineHeight(16)
          .fontColor(Theme.DANGER)
          .margin({ top: 6 })
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.dangerSoft(this.theme))
    .borderRadius(12)
    .margin({ top: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  formPanel() {
    Column() {
      Text(t('login.title', this.lang))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.theme))
        .width('100%')
      Text(t(this.isIdMode() ? 'login.subtitle.id' : 'login.subtitle', this.lang))
        .fontSize(12)
        .fontColor(Theme.textSecondary(this.theme))
        .margin({ top: 6 })
        .width('100%')

      if (this.routeText.length > 0) {
        Row() {
          Image($r('app.media.ic_check'))
            .width(12)
            .height(12)
            .fillColor(Theme.SUCCESS)
          Text(this.routeText)
            .fontSize(11)
            .fontColor(Theme.SUCCESS)
            .margin({ left: 5 })
        }
        .width('100%')
        .margin({ top: 6 })
      }

      this.modeSwitcher()

      if (this.isIdMode()) {
        // ID 登录 = 分步骤向导：入口按钮在 idForm 里，账号密码在向导最后一步输入。
        this.idForm()
      } else {
        this.ipForm()
        this.credentialForm()

        Button(this.loading ? t('login.connecting', this.lang)
          : t('login.ip.submit', this.lang), { type: ButtonType.Capsule })
          .width('100%')
          .height(46)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.buttonPrimaryFg(this.theme))
          .backgroundColor(Theme.buttonPrimaryBg(this.theme))
          .borderRadius(12)
          .margin({ top: 24 })
          .enabled(!this.loading)
          .opacity(this.loading ? 0.7 : 1)
          .onClick(() => {
            this.submit();
          })
      }

      if (this.loading) {
        Row() {
          LoadingProgress().width(20).height(20).color(Theme.PRIMARY)
          Text(this.loginStage.length > 0 ? t(this.loginStage, this.lang)
            : t('login.connecting', this.lang))
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ left: 8 })
            .layoutWeight(1)
        }
        .margin({ top: 12 })
        .alignItems(VerticalAlign.Center)
      }

      if (this.showFailure) {
        this.failurePanel()
      }

      // 审核预览账号：不连接设备，直接进入内置示例界面，方便应用商店审核。
      Row() {
        Column() {
          Text(t('login.demo.title', this.lang))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.PRIMARY)
          Text(t('login.demo.desc', this.lang))
            .fontSize(9)
            .lineHeight(13)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(t('login.demo.enter', this.lang))
          .fontSize(11)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.PRIMARY)
          .borderRadius(12)
          .accessibilityText(t('login.demo.enter', this.lang))
          .onClick(() => {
            this.enterDemo();
          })
      }
      .width('100%')
      .padding(10)
      .margin({ top: 14 })
      .backgroundColor(Theme.primarySoft(this.theme))
      .borderRadius(12)
      .alignItems(VerticalAlign.Center)

      // 协议必须是可点击入口：静态文字无法满足应用商店"可访问隐私政策"的审核要求。
      Row() {
        Text(t('login.agree', this.lang) + ' ')
          .fontSize(10)
          .fontColor(Theme.textSecondary(this.theme))
        Text(t('login.terms', this.lang))
          .fontSize(10)
          .fontColor(Theme.PRIMARY)
          .onClick(() => {
            this.legalKind = 'terms';
          })
        Text(' ' + t('login.and', this.lang) + ' ')
          .fontSize(10)
          .fontColor(Theme.textSecondary(this.theme))
        Text(t('login.privacy', this.lang))
          .fontSize(10)
          .fontColor(Theme.PRIMARY)
          .onClick(() => {
            this.legalKind = 'privacy';
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ top: 20 })
      .accessibilityText(t('login.agree', this.lang) + t('login.terms', this.lang) +
        t('login.and', this.lang) + t('login.privacy', this.lang))
    }
    .width('100%')
    .padding(22)
    .backgroundColor(Theme.glassBg(this.theme))
    .backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 1, color: Theme.glassBorder(this.theme) })
    .borderRadius(20)
    .shadow({ radius: 20, color: Theme.glassShadow(this.theme), offsetY: 6 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  narrowLayout() {
    Scroll() {
      Column() {
        Row() {
          Column().layoutWeight(1)
          this.langSwitch()
        }
        .width('100%')
        .margin({ bottom: 18 })
        this.brandPanel()
        this.formPanel()
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 28 })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  wideLayout() {
    Row() {
      Column() {
        Row() {
          Column().layoutWeight(1)
          this.langSwitch()
        }
        .width('100%')
        this.brandPanel()
        Column() {
          Text(t('login.secure.tip', this.lang))
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.theme))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .margin({ top: 40 })
      }
      .layoutWeight(1)
      .height('100%')
      .padding({ left: 40, right: 40, top: 32 })
      .justifyContent(FlexAlign.Center)

      Column() {
        Scroll() {
          Column() {
            this.formPanel()
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .align(Alignment.Center)
      }
      .layoutWeight(1)
      .height('100%')
      .padding({ left: 32, right: 40, top: 32, bottom: 32 })
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 网页验证登录的全屏层：顶部标题栏 + 内嵌 mQNAPcloud 页面。 */
  @Builder
  webLayer() {
    Column() {
      Row() {
        Text(t('login.web.title', this.lang))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
          .layoutWeight(1)
        Text(t('login.web.close', this.lang))
          .fontSize(14)
          .fontColor(Theme.PRIMARY)
          .padding({ left: 12, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.stopWebWatch();
            this.showWeb = false;
            this.webStage = '';
          })
      }
      .width('100%')
      .height(50)
      .padding({ left: 16, right: 12 })
      .backgroundColor(Theme.cardBg(this.theme))
      .alignItems(VerticalAlign.Center)

      if (this.webStage.length > 0) {
        Row() {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(Theme.PRIMARY)
          Text(t(this.webStage, this.lang))
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ left: 8 })
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(Theme.cardBg(this.theme))
        .alignItems(VerticalAlign.Center)
      }

      if (this.webLoadError) {
        Column() {
          Image($r('app.media.ic_warning'))
            .width(34)
            .height(34)
            .fillColor(Theme.DANGER)
          Text(t('login.web.error', this.lang))
            .fontSize(13)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 12 })
          Button(t('login.web.retry', this.lang), { type: ButtonType.Capsule })
            .width(120)
            .height(36)
            .fontSize(13)
            .fontColor(Theme.buttonPrimaryFg(this.theme))
            .backgroundColor(Theme.buttonPrimaryBg(this.theme))
            .margin({ top: 16 })
            .onClick(() => {
              this.webLoadError = false;
              this.webCtl.refresh();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(Theme.cardBg(this.theme))
      } else {
        Web({ src: this.webUrl, controller: this.webCtl })
          .width('100%')
          .layoutWeight(1)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .databaseAccess(true)
          .fileAccess(false)
          .onErrorReceive((event) => {
            // 只响应主文档错误：子资源（统计脚本、图标）失败不该打断登录流程
            if (event !== undefined && event.request.isMainFrame()) {
              this.webLoadError = true;
            }
          })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.cardBg(this.theme))
  }

  /** 向导顶部栏：标题 + 关闭（关闭即放弃整个 Tailscale 流程）。 */
  @Builder
  tsHeader(titleKey: string) {
    Row() {
      Text(t(titleKey, this.lang))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.theme))
        .layoutWeight(1)
      Image($r('app.media.ic_close'))
        .width(18)
        .height(18)
        .fillColor(Theme.textSecondary(this.theme))
        .accessibilityText(t('action.close', this.lang))
        .onClick(() => {
          this.resetTsFlow();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  /** 连接中 / 登录中：一个居中的进度提示。 */
  @Builder
  tsProgress(titleKey: string, hintKey: string) {
    Column() {
      this.tsHeader(titleKey)
      Column() {
        LoadingProgress().width(36).height(36).color(Theme.PRIMARY)
        Text(t(hintKey, this.lang))
          .fontSize(13)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 16 })
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding(24)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.cardBg(this.theme))
  }

  /**
   * Tailscale 登录页（必经步骤）：内嵌 WebView 让用户登录 tailnet。
   * 顶部状态随轮询变化：未登录引导登录，已连接则可点下一步。
   */
  @Builder
  tsAuthStep() {
    Column() {
      this.tsHeader('login.ts.auth.title')

      // 状态提示：登录中 / 已连接 / 等待用户在页面里登录
      Text(t(this.tsStage.length > 0 ? this.tsStage : 'login.ts.auth', this.lang))
        .fontSize(12)
        .lineHeight(18)
        .fontColor(this.tsAuthed ? Theme.SUCCESS : Theme.PRIMARY)
        .width('100%')
        .padding({ left: 16, right: 16 })

      // 引擎状态只展示可操作的提示；原始状态串属于内部诊断，不再直接呈现。
      if (!this.tsAuthed && this.tsRawStatus.length > 0) {
        Text(t('login.ts.auth.wait.tip', this.lang))
          .fontSize(10)
          .lineHeight(15)
          .fontColor(Theme.textSecondary(this.theme))
          .width('100%')
          .padding({ left: 16, right: 16, top: 2 })
      }

      // 授权链接状态：这是「登录了官网却不算授权」的判别依据。
      // 未取到 = 网页登录只会登进官网后台，不会授权本机节点。
      if (!this.tsAuthed) {
        Text(this.tsAuthUrlReal
          ? t('login.ts.authLink.state', this.lang) + t('login.ts.authLink.ready', this.lang) + ' ' + this.tsAuthUrl
          : t('login.ts.authLink.state', this.lang) + t('login.ts.authLink.missing', this.lang))
          .fontSize(9)
          .lineHeight(13)
          .fontColor(this.tsAuthUrlReal ? Theme.SUCCESS : Theme.DANGER)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 16, right: 16, top: 2 })
      }

      // 引擎异常：内联在登录页里，不覆盖登录页（登录页必须始终可见）
      if (this.tsEngineErr.length > 0) {
        Column() {
          Row() {
            Image($r('app.media.ic_warning'))
              .width(13)
              .height(13)
              .fillColor(Theme.DANGER)
            Text(t('login.ts.auth.engine', this.lang))
              .fontSize(11)
              .fontColor(Theme.DANGER)
              .layoutWeight(1)
              .margin({ left: 5 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(t('login.ts.engine.friendly', this.lang))
            .fontSize(10)
            .lineHeight(15)
            .fontColor(Theme.textSecondary(this.theme))
            .width('100%')
            .margin({ top: 4 })

          // 诊断信息默认折叠，用户可按需展开查看，避免默认暴露内部错误串。
          if (this.tsDiagExpanded) {
            Text(this.tsEngineErr)
              .fontSize(9)
              .fontColor(Theme.textSecondary(this.theme))
              .maxLines(4)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 4 })
          }
          Text(this.tsDiagExpanded ? t('login.ts.diag.hide', this.lang) : t('login.ts.diag.show', this.lang))
            .fontSize(10)
            .fontColor(Theme.PRIMARY)
            .margin({ top: 4 })
            .accessibilityText(t('login.ts.diag.show', this.lang))
            .onClick(() => {
              this.tsDiagExpanded = !this.tsDiagExpanded;
            })

          Button(t('login.ts.auth.retry', this.lang), { type: ButtonType.Capsule })
            .height(30)
            .fontSize(11)
            .fontColor(Theme.PRIMARY)
            .backgroundColor(Theme.subCardBg(this.theme))
            .margin({ top: 8 })
            .onClick(() => {
              this.tsRetryEngine();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
        .alignItems(HorizontalAlign.Start)
      }

      Web({ src: this.tsAuthUrl.length > 0 ? this.tsAuthUrl : TS_LOGIN_URL,
        controller: this.tsWebCtl })
        .width('100%')
        .layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(true)

      Column() {
        if (!this.tsAuthed) {
          Text(t('login.ts.auth.tip', this.lang))
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
            .width('100%')
            .margin({ bottom: 8 })
        }
        // 点「下一步」被拦住时的显式反馈：没有这段，按钮看起来就是"没反应"。
        if (this.tsAuthBlock.length > 0) {
          Row() {
            Image($r('app.media.ic_warning'))
              .width(13)
              .height(13)
              .fillColor(Theme.DANGER)
            Text(t(this.tsAuthBlock, this.lang))
              .fontSize(11)
              .fontColor(Theme.DANGER)
              .layoutWeight(1)
              .margin({ left: 5 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 8 })
        }
        Button(t('login.ts.nextIp', this.lang), { type: ButtonType.Capsule })
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.buttonPrimaryFg(this.theme))
          .backgroundColor(Theme.buttonPrimaryBg(this.theme))
          .borderRadius(11)
          .onClick(() => {
            this.tsAuthNext();
          })
        if (!this.tsAuthed) {
          Button(t('login.ts.auth.recheck', this.lang), { type: ButtonType.Normal })
            .width('100%')
            .height(34)
            .fontSize(12)
            .fontColor(Theme.PRIMARY)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.tsRecheck();
            })
          // 兜底出口：VPN 始终连不上时仍可用局域网 IP 登录，避免流程死锁。
          Button(t('login.ts.auth.skip', this.lang), { type: ButtonType.Normal })
            .width('100%')
            .height(34)
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.theme))
            .backgroundColor(Color.Transparent)
            .margin({ top: 2 })
            .onClick(() => {
              this.tsSkipEngine();
            })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 10, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.cardBg(this.theme))
  }

  /** 「选 IP」步骤：列出节点（NAS 优先），并允许手动填入地址。 */
  @Builder
  tsPickStep() {
    Column() {
      this.tsHeader('login.ts.pick.title')
      Scroll() {
        Column() {
          Text(t('login.ts.pick.hint', this.lang))
            .fontSize(12)
            .lineHeight(18)
            .fontColor(Theme.textSecondary(this.theme))
            .width('100%')

          if (!this.tsAuthed) {
            Text('· ' + t('login.ts.pick.vpnWarn', this.lang))
              .fontSize(11)
              .lineHeight(16)
              .fontColor(Theme.DANGER)
              .width('100%')
              .margin({ top: 6 })
          }

          // NAS 精确匹配候选优先
          ForEach(this.tsCandidates, (c: NasCandidate) => {
            Button(c.name + ' · ' + c.address)
              .width('100%')
              .height(42)
              .fontSize(13)
              .fontColor(Theme.buttonPrimaryFg(this.theme))
              .backgroundColor(Theme.buttonPrimaryBg(this.theme))
              .borderRadius(10)
              .margin({ top: 10 })
              .onClick(() => {
                this.tsPickCandidate(c);
              })
          }, (c: NasCandidate) => 'nas-' + c.address)

          // 其余 tailnet 节点（排除已展示的 NAS 候选）
          ForEach(this.tsPeers, (c: NasCandidate) => {
            if (!this.tsCandidates.some((n: NasCandidate) => n.address === c.address)) {
              Button(c.name + ' · ' + c.address)
                .width('100%')
                .height(40)
                .fontSize(12)
                .fontColor(Theme.PRIMARY)
                .backgroundColor(Theme.subCardBg(this.theme))
                .borderRadius(10)
                .margin({ top: 8 })
                .onClick(() => {
                  this.tsPickCandidate(c);
                })
            }
          }, (c: NasCandidate) => 'peer-' + c.address)

          this.fieldLabel(t('login.ts.pick.manual', this.lang))
          this.inputField(this.tsPickedIp, 'login.ts.pick.inputHint', false, (text: string) => {
            this.tsPickedIp = text;
            this.tsIpErr = '';
          })
          this.fieldError(this.tsIpErr)

          Button(t('login.ts.next', this.lang), { type: ButtonType.Capsule })
            .width('100%')
            .height(44)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.buttonPrimaryFg(this.theme))
            .backgroundColor(Theme.buttonPrimaryBg(this.theme))
            .borderRadius(11)
            .margin({ top: 20 })
            .onClick(() => {
              this.tsConfirmIp();
            })

          Button(t('login.ts.pick.back', this.lang), { type: ButtonType.Capsule })
            .width('100%')
            .height(40)
            .fontSize(13)
            .fontColor(Theme.PRIMARY)
            .backgroundColor(Theme.subCardBg(this.theme))
            .borderRadius(11)
            .margin({ top: 10 })
            .onClick(() => {
              this.tsBackToAuth();
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 28 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.cardBg(this.theme))
  }

  /** 「登录 NAS」步骤：独立的账号密码界面，地址来自上一步。 */
  @Builder
  tsLoginStep() {
    Column() {
      this.tsHeader('login.ts.login.title')
      Scroll() {
        Column() {
          Text(t('login.ts.login.target', this.lang) + ' ' + this.tsPickedIp)
            .fontSize(13)
            .fontColor(Theme.PRIMARY)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .margin({ top: 6 })

          if (!this.tsAuthed) {
            Text('· ' + t('login.ts.pick.vpnWarn', this.lang))
              .fontSize(10)
              .lineHeight(15)
              .fontColor(Theme.DANGER)
              .width('100%')
              .margin({ top: 4 })
          }

          this.fieldLabel(t('login.ip.username', this.lang))
          this.inputField(this.tsUser, 'login.ip.usernameHint', false, (text: string) => {
            this.tsUser = text;
            this.tsUserErr = '';
          })
          this.fieldError(this.tsUserErr)

          this.fieldLabel(t('login.ip.password', this.lang))
          this.inputField(this.tsPass, 'login.ip.passwordHint', true, (text: string) => {
            this.tsPass = text;
            this.tsPassErr = '';
          })
          this.fieldError(this.tsPassErr)

          // NAS 登录失败原因（留在向导内，不清空已填内容）
          if (this.tsLoginErr.length > 0) {
            Row() {
              Image($r('app.media.ic_warning'))
                .width(13)
                .height(13)
                .fillColor(Theme.DANGER)
              Text(t(this.tsLoginErr, this.lang))
                .fontSize(11)
                .lineHeight(16)
                .fontColor(Theme.DANGER)
                .layoutWeight(1)
                .margin({ left: 5 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ top: 10 })
          }

          Button(t('login.ts.login.submit', this.lang), { type: ButtonType.Capsule })
            .width('100%')
            .height(44)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.buttonPrimaryFg(this.theme))
            .backgroundColor(Theme.buttonPrimaryBg(this.theme))
            .borderRadius(11)
            .margin({ top: 20 })
            .onClick(() => {
              this.tsFinishTailscale();
            })

          Button(t('login.ts.prev', this.lang), { type: ButtonType.Capsule })
            .width('100%')
            .height(40)
            .fontSize(13)
            .fontColor(Theme.PRIMARY)
            .backgroundColor(Theme.subCardBg(this.theme))
            .borderRadius(11)
            .margin({ top: 10 })
            .onClick(() => {
              this.tsPhase = 'pick';
              this.tsUserErr = '';
              this.tsPassErr = '';
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 28 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.cardBg(this.theme))
  }

  /**
   * Tailscale 分步骤向导总容器：
   * connecting（VPN 启动进度）→ auth（Tailscale 登录页，必经）→
   * pick（选/填 IP）→ login（账号密码）→ logging。
   */
  @Builder
  tailscaleLayer() {
    Stack() {
      if (this.tsPhase === 'connecting') {
        this.tsProgress('login.ts.auth.title', 'login.ts.connecting')
      } else if (this.tsPhase === 'auth') {
        this.tsAuthStep()
      } else if (this.tsPhase === 'pick') {
        this.tsPickStep()
      } else if (this.tsPhase === 'login') {
        this.tsLoginStep()
      } else if (this.tsPhase === 'logging') {
        this.tsProgress('login.ts.logging.title', 'login.ts.logging')
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      Column() {
        if (BreakpointSystem.isWide(this.bp)) {
          this.wideLayout()
        } else {
          this.narrowLayout()
        }
      }
      .width('100%')
      .height('100%')
      .linearGradient({
        angle: 135,
        colors: Theme.pageGradientColors(this.theme)
      })

      // 网页验证登录：内嵌 myQNAPcloud 页面完成 QNAP ID 登录（含二次验证），
      // 验证成功后取回设备地址，再回到原生登录进入设备。
      if (this.showWeb) {
        this.webLayer()
      }

      // Tailscale 分步骤向导：VPN 授权 → 选/填 NAS IP → NAS 账号密码 → 进 App
      if (this.tsPhase.length > 0) {
        this.tailscaleLayer()
      }

      // 协议全文层置于最上方，登录流程不必中断即可查阅。
      if (this.legalKind.length > 0) {
        LegalSheet({
          kind: this.legalKind,
          lang: this.lang,
          theme: this.theme,
          onClose: () => {
            this.legalKind = '';
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
