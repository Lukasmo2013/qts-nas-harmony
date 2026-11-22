/**
 * QNAP QTS 真实接口客户端（已对 TS-464C / QTS 5.2.11 实测打通）。
 *
 * 接口契约（全部为真机实测结果）：
 *   - 登录：GET /cgi-bin/authLogin.cgi?user=&pwd=(base64)&service=1 → <authSid>
 *   - 会话：Cookie `NAS_SID=<sid>; home=1`，且 **所有后续请求必须在查询串携带 sid=**，
 *           否则设备返回 <authPassed>0（认证失败），表现为所有指标为 0、列表页空白。
 *           因此 DeviceSession 必须持久化 sid，冷启动时由 restore() 重新注入。
 *   - 系统监控：GET /cgi-bin/management/manaRequest.cgi?subfunc=sysmonitor&sys_cpu_use_v2=1&sys_memory_use=1
 *   - 卷与磁盘：GET /cgi-bin/management/manaRequest.cgi?subfunc=sysmonitor&net_in=1&net_out=1
 *   - 设备信息 / 服务：GET /cgi-bin/sysinfoReq.cgi
 *   - 文件列表：GET /FileStation6/utilRequest.cgi?func=get_list&path=<共享路径>&limit=&offset=&sort=&dir=
 *   - 共享目录：GET /cgi-bin/priv/privRequest.cgi?subfunc=share&read=2
 *   - 文件写操作（实测均为 POST + x-www-form-urlencoded，func 放查询串）：
 *       createdir : dest_path=<父目录> & dest_folder=<新目录名>
 *       rename    : path=<父目录> & source_name=<旧名> & dest_name=<新名>
 *       delete    : path=<父目录> & file_name=<名(可重复)> & file_total=<个数> & v=2 [& force=1]
 *                   不传 force 即移入回收站；成功状态码为 status=1。
 *   - 下载（已真机 4.7MB 往返字节一致）：
 *       GET /FileStation6/utilRequest.cgi?func=download
 *           &source_path=<所在目录> & source_file=<文件名> & isfolder=0 & compress=0
 *           &source_total=1            ← 少了它设备会 200 但返回 0 字节
 *       → 原始文件字节 + Content-Disposition（filename*=utf-8''<百分号编码>）
 *   - 上传（两段式分片，已真机完整验证）：
 *       ① POST ?func=start_chunked_upload&sid=   体 upload_root_dir=<目录>
 *            → {"status":0,"upload_id":"tmpXXXX"}；失败 7=目标目录不可写 4=无权限
 *       ② POST ?func=chunked_upload&sid=&dest_path=&mode=0&dup=Copy&upload_root_dir=
 *               &offset=0&filesize=N&upload_name=&settime=1&mtime=&overwrite=1
 *               &multipart=0&upload_id=<id>
 *            正文 multipart 仅两个字段：fileName（文本）+ file（二进制分片）
 *            **Content-Type 只能写 multipart/form-data、不得带 boundary**（带则 status=9）
 *            → {"status":1,"size":"120","name":"..."}
 *       注意：目标共享目录必须对该账号可写。本机实测 /Public 只读（createdir 亦返回 4），
 *             /Container 可写；设备状态码 4/7/9 一律如实上报，绝不伪装成功。
 *   - 日志：GET /cgi-bin/sys/syslogRequest.cgi?subfunc=get_log （该机型返回 Success=false Error=-3）
 *   - 容器：GET /cgi-bin/container-station/api/v2/docker/containers/json?all=1
 *           该机型未安装 Container Station，全部端点返回 404 —— 必须靠 HTTP 404 判定「未安装」，
 *           与「已安装但列表为空」区分开，否则页面只会显示含糊的空白。
 *
 * 原则：接口不支持 / 未授权时返回空集合或显式的 available=false，
 * 由页面渲染真实空态 / 未安装态，绝不填充假数据、绝不在写操作失败时假装成功。
 */
import http from '@ohos.net.http';
import connection from '@ohos.net.connection';
import {
  DeviceOverview, DeviceSession, LoginResult, FileItem, FileListResult, StorageBundle, StoragePool,
  VolumeInfo, DiskInfo, ContainerInfo, ContainerPort, ContainerListResult, ContainerLogs, EventItem,
  ServiceInfo, ImageInfo, OpResult, DownloadResult
} from '../model/Models';
import { FileNameUtil } from '../common/utils/FileNameUtil';

/** 纯 ASCII base64（密码为 ASCII；等价于 btoa 语义）。 */
function b64encode(s: string): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  let i = 0;
  while (i < s.length) {
    const b0 = s.charCodeAt(i) & 0xFF;
    const b1 = i + 1 < s.length ? s.charCodeAt(i + 1) & 0xFF : 0;
    const b2 = i + 2 < s.length ? s.charCodeAt(i + 2) & 0xFF : 0;
    const e0 = b0 >> 2;
    const e1 = ((b0 & 3) << 4) | (b1 >> 4);
    const e2 = ((b1 & 15) << 2) | (b2 >> 6);
    const e3 = b2 & 63;
    out += chars.charAt(e0) + chars.charAt(e1) +
      (i + 1 < s.length ? chars.charAt(e2) : '=') +
      (i + 2 < s.length ? chars.charAt(e3) : '=');
    i += 3;
  }
  return out;
}

/** 从 QTS XML 中抽取 <tag><![CDATA[...]]></tag> 或 <tag>text</tag> 文本。 */
function cdata(xml: string, tag: string): string {
  const open = '<' + tag + '><![CDATA[';
  let i = xml.indexOf(open);
  if (i >= 0) {
    const start = i + open.length;
    const end = xml.indexOf(']]>', start);
    if (end >= 0) {
      return xml.substring(start, end);
    }
  }
  const o2 = '<' + tag + '>';
  const i2 = xml.indexOf(o2);
  if (i2 >= 0) {
    const s2 = i2 + o2.length;
    const e2 = xml.indexOf('</' + tag + '>', s2);
    if (e2 >= 0) {
      return xml.substring(s2, e2);
    }
  }
  return '';
}

function cdataInt(xml: string, tag: string, fallback: number): number {
  const v = cdata(xml, tag);
  if (v.length === 0) {
    return fallback;
  }
  const n = parseFloat(v);
  return isNaN(n) ? fallback : Math.floor(n);
}

/** 解析百分比字段：QTS 返回形如 "23.1 %"（含空格与百分号）。 */
function cdataPercent(xml: string, tag: string): number {
  const raw = cdata(xml, tag).replace('%', '').trim();
  if (raw.length === 0) {
    return 0;
  }
  const n = parseFloat(raw);
  return isNaN(n) ? 0 : Math.round(n * 10) / 10;
}

/** 抽取同名标签的重复块（如每个 <swap_mem_info> / <service>）。 */
function cdataBlocks(xml: string, tag: string): string[] {
  const blocks: string[] = [];
  const open = '<' + tag + '>';
  const close = '</' + tag + '>';
  let from = 0;
  for (;;) {
    const i = xml.indexOf(open, from);
    if (i < 0) {
      break;
    }
    const end = xml.indexOf(close, i);
    if (end < 0) {
      break;
    }
    blocks.push(xml.substring(i, end + close.length));
    from = end + close.length;
  }
  return blocks;
}

/* ---------- File Station 6 列表响应的显式类型契约 ---------- */
interface FileEntry {
  filename?: string;
  isfolder?: number;
  filesize?: string;
  owner?: string;
  group?: string;
  privilege?: string;
  filetype?: number;
  mt?: string;
  epochmt?: number;
}

interface FileListResp {
  total?: number;
  real_total?: number;
  datas?: FileEntry[];
  status?: number;
  success?: string;
}

/** 写操作响应：{"status":1} 或 {"status":1,"pid":123} 或错误壳。 */
interface OpResp {
  status?: number;
  success?: string;
  size?: string;
  name?: string;
}

/**
 * start_chunked_upload 响应（实测）：
 *   成功 {"status":0,"upload_id":"tmpRIGTuC"}
 *   失败 {"status":7,"upload_id":"---"}   ← 目标目录无写权限 / 打不开临时文件
 */
interface UploadStartResp {
  status?: number;
  upload_id?: string;
}

/* ---------- syslog 响应的显式类型契约 ---------- */
interface EventEntry {
  id?: string;
  idx?: string;
  msg?: string;
  message?: string;
  title?: string;
  severity?: string;
  type?: string;
  detail?: string;
  content?: string;
}

interface EventResp {
  Success?: string | boolean;
  Error?: string;
  datas?: EventEntry[];
  data?: EventEntry[];
}

/* ---------- docker containers/json 响应的显式类型契约 ---------- */
/* ---------- Container Station 5 网关（/container-station/api/v3）响应契约 ----------
   实测样例（TS-464C / CS 5）：
   GET /containers -> {"data":{"items":[{"id":"3672...","name":"lx-sync-server",
     "type":"docker","image":"xcq0607/lxserver:latest","status":"running",
     "portBindings":[{"host":9527,"container":9527,"protocol":"TCP"}],
     "cpu":0.148,"memory":0.016,"project":"lxmusic","startedAt":"2026-11-12T00:05:00Z"}]}}
   GET /images     -> {"data":{"items":[{"id":"sha256:afc8...","tags":["a/b:latest"],
     "created":1791431678,"size":124231695}]}}
   注意：memory 单位是 GB（不是字节），cpu 为核数占比。                          */

interface CsPortBind {
  host?: number;
  container?: number;
  protocol?: string;
  hostIP?: string;
}

interface CsContainer {
  id?: string;
  name?: string;
  type?: string;
  image?: string;
  imageID?: string;
  status?: string;
  cpu?: number;
  memory?: number;
  project?: string;
  startedAt?: string;
  portBindings?: CsPortBind[];
}

interface CsContainerData {
  items?: CsContainer[];
}

interface CsContainerResp {
  data?: CsContainerData;
}

interface CsImage {
  id?: string;
  type?: string;
  tags?: string[];
  repoDigests?: string[];
  created?: number;
  size?: number;
  used?: boolean;
}

interface CsImageData {
  items?: CsImage[];
}

interface CsImageResp {
  data?: CsImageData;
}

/** CS 5 的异步任务（启停 / 重启 / 删除等均以任务形式受理）。 */
interface CsTask {
  id?: string;
  /** 任务状态：`pending` / `running` / `completed` / `failed` / `canceled`。 */
  state?: string;
  category?: string;
  detail?: string;
  progress?: number;
}

interface CsTaskListData {
  items?: CsTask[];
}

interface CsTaskListResp {
  data?: CsTaskListData;
}

/** 容器异步任务响应里的 data 段（ArkTS 不允许把对象字面量当类型用，必须显式声明）。 */
interface CsTaskData {
  taskID?: string;
}

interface CsTaskResp {
  data?: CsTaskData;
}

/** 一次原始 HTTP 往返的结果：保留状态码用于区分「未安装(404)」与「已装但为空(200)」。 */
interface RawResponse {
  status: number;
  body: string;
}

/**
 * 单端点登录探测结果：
 *   ok      认证通过
 *   invalid 密码被拒
 *   portal  该地址是 myQNAPcloud 门户 / CloudLink 节点，不是 QTS
 *   fail    端口不通或不是 QTS API
 */
interface ProbeResult {
  state: string;
  sid: string;
}

/** 最近一次成功登录的接入点（持久化在 AppStorage.lastEndpoint）。 */
interface EndpointRecord {
  host: string;
  port: number;
  scheme: string;
}

/** 登录前的无凭据选路探测结果。 */
export interface RouteProbeResult {
  ok: boolean;
  host: string;
  port: number;
  scheme: string;
  latencyMs: number;
}

/** 本机在默认网络上的 IPv4 链路信息，仅供局域网自动发现使用。 */
interface LanLink {
  ip: string;
  prefix: number;
}

/** 局域网内被判定为 QTS 的候选（ip + 端口）。 */
interface LanHit {
  ip: string;
  port: number;
}

/** 只读窥探持久化会话里的接入点字段（老版本会话没有 lastEndpoint）。 */
interface SessionPeek {
  host?: string;
  port?: number;
  scheme?: string;
}

/** 只读窥探持久化会话里的中继 Cookie（冷启动 / 重新登录时恢复中继模式）。 */
interface SessionRelayPeek {
  relayCookie?: string;
}

export class QnapApi {
  static readonly DEFAULT_PORT: number = 5000;
  /** QNAP ID（myQNAPcloud 域名）接入的默认端口：QTS 标准 HTTPS 端口。 */
  static readonly DEFAULT_ID_PORT: number = 8081;

  private static sid: string = '';
  private static cookie: string = '';
  /**
   * CloudLink 中继会话 Cookie。非空表示当前走中继（如 `d2.myqnapcloud.cn`）：
   * 中继凭这组 Cookie 把请求路由到设备，缺了它只会拿回门户页。
   */
  private static relayCookie: string = '';
  /** 中继主机（如 `d2.myqnapcloud.cn`）。用于判断当前端点是否仍是中继。 */
  private static relayHost: string = '';
  /**
   * 中继路由 Cookie 已失效：请求被打回 myQNAPcloud 门户页。
   * 中继会话有服务端有效期，过期后只能在网页里重新做一次 QNAP ID 验证，
   * 原生 HTTP 无法自行续期 —— 置位后由登录页明确提示，而不是让界面空白。
   */
  private static relayExpiredFlag: boolean = false;
  /** http / https —— ID 模式通过 myQNAPcloud 域名访问必须走 https。 */
  private static scheme: string = 'http';
  /** 已探测确认存在的共享目录（如 ['/Public', '/Container']）。 */
  private static shareCache: string[] = [];
  /** 留存登录凭据，用于 sid 过期时的静默重登（避免页面因会话失效而空白）。 */
  private static authUser: string = '';
  private static authPass: string = '';

  private static headers(): Record<string, string> {
    // cookie 为空时退回中继 Cookie：登录探测 / 首次登录前还没有 sid，
    // 但中继路由 Cookie 必须带上，否则中继只会把请求打成门户页。
    const jar: string = QnapApi.cookie.length > 0 ? QnapApi.cookie : QnapApi.relayCookie;
    return {
      'User-Agent': 'QTS-NAS-Manager/1.0',
      'Cookie': jar,
      'X-Requested-With': 'XMLHttpRequest'
    };
  }

  /** 当前接入点根地址（含 http / https 与端口）。 */
  private static baseUrl(): string {
    return QnapApi.scheme + '://' + QnapApi.h + ':' + String(QnapApi.p);
  }

  /** 统一的 GET：自动附带会话 Cookie 与 sid 查询参数。
   *  QTS 对同一会话的高频请求会限流（返回空响应），因此空结果会退避后重试一次；
   *  若返回「未认证」，用留存的凭据静默重登一次后重试，避免整页空白。 */
  private static async get(url: string, allowRelogin: boolean = true, timeout: number = 15000,
                           withSid: boolean = true): Promise<string> {
    let target = url;
    if (withSid && QnapApi.sid.length > 0 && target.indexOf('sid=') < 0) {
      target += (target.indexOf('?') >= 0 ? '&' : '?') + 'sid=' + QnapApi.sid;
    }
    let body = '';
    for (let attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await QnapApi.delay(400);
      }
      body = await QnapApi.send(target, http.RequestMethod.GET, '', timeout);
      if (body.length > 0) {
        break;
      }
    }
    if (body.length > 0 && allowRelogin && QnapApi.isAuthFailure(body)) {
      const renewed = await QnapApi.relogin();
      if (renewed) {
        return await QnapApi.get(url, false, timeout, withSid);
      }
    }
    // 中继被弹回门户页：多数情况是 sid 过期而路由 Cookie 仍在（中继自己也想让你重登），
    // 用留存凭据补登一次就能继续跑；补登也失败才是真的中继过期。
    if (body.length > 0 && allowRelogin && QnapApi.relayCookie.length > 0 &&
      QnapApi.isPortalBody(body)) {
      const renewed = await QnapApi.relogin();
      if (renewed) {
        return await QnapApi.get(url, false, timeout, withSid);
      }
    }
    return body;
  }

  /** 原始往返：返回状态码 + 响应体，供需要区分 404 的接口使用。 */
  private static async send(url: string, method: http.RequestMethod, payload: string,
                            timeout: number = 15000, contentType: string = ''): Promise<string> {
    const raw = await QnapApi.sendRaw(url, method, payload, timeout, contentType);
    return raw.body;
  }

  private static async sendRaw(url: string, method: http.RequestMethod, payload: string,
                               timeout: number = 15000, contentType: string = '',
                               bearer: boolean = false, binary?: Uint8Array): Promise<RawResponse> {
    const req = http.createHttp();
    try {
      const header: Record<string, string> = QnapApi.headers();
      if (contentType.length > 0) {
        header['Content-Type'] = contentType;
      }
      // Container Station 5 的 REST 网关只认 Bearer token，且实际接受的就是 sid。
      if (bearer && QnapApi.sid.length > 0) {
        header['Authorization'] = 'Bearer ' + QnapApi.sid;
      }
      const options: http.HttpRequestOptions = {
        method: method,
        header: header,
        connectTimeout: timeout,
        readTimeout: timeout
      };
      if (binary !== undefined) {
        // 二进制请求体：http 模块的 extraData 只接受 string | Object | ArrayBuffer，
        // 直接塞 Uint8Array 会被当成普通对象（运行时序列化成 {}），上传必然失败。
        // 这里精确切片成 ArrayBuffer（subarray 视图要按 byteOffset 截）。
        options.extraData = QnapApi.toArrayBuffer(binary);
      } else if (payload.length > 0) {
        options.extraData = payload;
      }
      const resp = await req.request(url, options);
      const raw: RawResponse = {
        status: resp.responseCode,
        body: typeof resp.result === 'string' ? resp.result as string : ''
      };
      QnapApi.noteBody(raw.body);
      return raw;
    } catch (e) {
      const failed: RawResponse = { status: 0, body: '' };
      return failed;
    } finally {
      req.destroy();
    }
  }

  /** 设备以 authPassed=0 / status:3 表示会话无效（sid 缺失或已过期）。 */
  private static isAuthFailure(body: string): boolean {
    return body.indexOf('authPassed><![CDATA[0') >= 0 ||
      body.indexOf('"status":3') >= 0 ||
      body.indexOf('"status": 3') >= 0;
  }

  /** 用留存凭据重新登录，成功后刷新 sid / cookie。 */
  private static async relogin(): Promise<boolean> {
    if (QnapApi.authUser.length === 0 || QnapApi.authPass.length === 0) {
      return false;
    }
    const base = QnapApi.baseUrl();
    const url = base + '/cgi-bin/authLogin.cgi?user=' + encodeURIComponent(QnapApi.authUser) +
      '&pwd=' + encodeURIComponent(b64encode(QnapApi.authPass)) + '&service=1';
    // withSid=false：authLogin 本身不接受旧 sid，中继模式下带上旧 sid 反而可能干扰路由；
    // 中继靠的是路由 Cookie，直连靠的是账号密码。
    const xml = await QnapApi.get(url, false, 15000, false);
    if (xml.length === 0 || !QnapApi.isQtsBody(xml) || cdata(xml, 'authPassed') !== '1') {
      if (xml.length > 0 && QnapApi.relayCookie.length > 0 && QnapApi.isPortalBody(xml)) {
        QnapApi.relayExpiredFlag = true;
      }
      return false;
    }
    QnapApi.applySid(cdata(xml, 'authSid'));
    return true;
  }

  private static applySid(sid: string): void {
    QnapApi.sid = sid;
    // 拿到新 sid 就说明会话是通的，清掉「中继已过期」的标记。
    QnapApi.relayExpiredFlag = false;
    const base: string = 'NAS_SID=' + sid + '; home=1';
    QnapApi.cookie = QnapApi.relayCookie.length > 0
      ? (QnapApi.relayCookie + '; ' + base)
      : base;
  }

  /** 设置中继会话 Cookie（网页验证登录拿到后传入，清空即退出中继模式）。 */
  static setRelayCookie(cookie: string, host: string = ''): void {
    QnapApi.relayCookie = cookie !== undefined && cookie !== null ? cookie : '';
    QnapApi.relayHost = host !== undefined ? host : '';
    QnapApi.relayExpiredFlag = false;
    if (QnapApi.sid.length > 0) {
      QnapApi.applySid(QnapApi.sid);
    }
  }

  /** 中继主机名（非中继模式为空串）。 */
  static currentRelayHost(): string {
    return QnapApi.relayHost;
  }

  /**
   * 从持久化会话里恢复中继 Cookie。
   *
   * 意义：中继 Cookie 只要还没过期，冷启动 / 重新登录时就能直接用，
   * 用户不必每次都重做一遍网页验证（QNAP ID + 二次验证）。
   * 这是「整条链路固化」的关键一步 —— 之前只把 relayCookie 存进会话、
   * 却没有任何地方把它读回来，等于每次启动都退回非中继模式。
   */
  static restoreRelayCookie(): void {
    if (QnapApi.relayCookie.length > 0) {
      return;
    }
    const raw: string | undefined = AppStorage.get<string>('appSession');
    if (raw === undefined || raw.length === 0) {
      return;
    }
    try {
      const peek: SessionRelayPeek = JSON.parse(raw) as SessionRelayPeek;
      if (peek.relayCookie !== undefined && peek.relayCookie.length > 0) {
        QnapApi.relayCookie = peek.relayCookie;
      }
    } catch (e) {
      return;
    }
  }

  /**
   * 会话健康检查：用系统信息接口探一次，确认「sid + 中继 Cookie」这套凭证
   * 还能换回真实 QTS 响应。
   *
   * 冷启动时先跑它，避免带着死会话进主界面 —— 那种情况下首页指标全 0、
   * 文件页空白，用户会以为 App 坏了，其实是会话已过期。
   */
  static async ping(): Promise<boolean> {
    if (QnapApi.h.length === 0) {
      return false;
    }
    const body: string = await QnapApi.get(QnapApi.baseUrl() + '/cgi-bin/sysinfoReq.cgi',
      false, 8000);
    // 三个条件同时成立才算「会话可用」：是 QTS 响应、读得出主机名、不是未认证。
    return QnapApi.isQtsBody(body) && cdata(body, 'hostname').length > 0 &&
      cdata(body, 'authPassed') !== '0';
  }

  /**
   * 登录前探测某个接入点是否为真实可达的 QTS，不带账号密码、不触碰全局会话。
   * 用于「按当前网络自动选最佳路线」：延迟最低且返回真实 sysinfo 的地址优先。
   */
  static async probeRoute(host: string, port: number, scheme: string): Promise<RouteProbeResult> {
    const start: number = Date.now();
    const result: RouteProbeResult = {
      ok: false, host: host, port: port, scheme: scheme, latencyMs: 999999
    };
    if (host.length === 0 || port <= 0) {
      return result;
    }
    try {
      const url: string = scheme + '://' + host + ':' + String(port) + '/cgi-bin/sysinfoReq.cgi';
      const raw = await QnapApi.sendRaw(url, http.RequestMethod.GET, '', 4000, '');
      result.latencyMs = Date.now() - start;
      result.ok = raw.status >= 200 && raw.status < 300 &&
        QnapApi.isQtsBody(raw.body) && cdata(raw.body, 'hostname').length > 0;
    } catch (e) {
      result.latencyMs = Date.now() - start;
    }
    return result;
  }

  /**
   * 通过 CloudLink 中继登录（网页验证只负责 QNAP ID，这一步负责 QTS 自己）。
   *
   * 实测（2026-11）：`https://d2.myqnapcloud.cn/cgi-bin/authLogin.cgi` 只要带上
   * 中继路由 Cookie（`qcloud_tunnel_sid` 等，**不需要** NAS_SID），
   * 就能拿到 `authPassed=1` + 全新的 `authSid`，随后系统信息 / 监控 / 共享目录 /
   * 文件列表 / Container Station 全部返回真实数据。
   * 因此无端口映射时，这就是让全部功能在外网可用的通路。
   */
  static async loginViaRelay(host: string, cookie: string, user: string,
                             password: string): Promise<LoginResult> {
    QnapApi.setRelayCookie(cookie, host);
    const result: LoginResult = await QnapApi.performLogin('qnapId', host, 443, user, password, 'https');
    if (!result.success) {
      // 失败就退出中继模式，避免把无效 Cookie 带到后续请求里
      QnapApi.clearRelay();
      QnapApi.cookie = '';
    }
    return result;
  }

  /**
   * 云 API 直取通道第 1 步：访问一次中继入口，让中继把路由 Cookie 种下来。
   * GET `https://<relay>/?tunnel_agent_id=<id>` → 从响应 Set-Cookie 收集
   * `qcloud_tunnel_sid` / `qcloud_tunnel_agent_id` / `cloudRelayMode` 等名=值段。
   */
  static async fetchTunnelCookieJar(relayHost: string, tunnelAgentId: string): Promise<string> {
    const req = http.createHttp();
    try {
      const header: Record<string, string> = {
        'User-Agent': 'QTS-NAS-Manager/1.0'
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: 15000,
        readTimeout: 15000
      };
      const resp = await req.request(
        'https://' + relayHost + '/?tunnel_agent_id=' + encodeURIComponent(tunnelAgentId), options);
      const parts: string[] = [];
      const hs = resp.header as Record<string, Object>;
      const keys: string[] = Object.keys(hs);
      for (const k of keys) {
        if (k.toLowerCase() !== 'set-cookie') {
          continue;
        }
        const v: Object | undefined = hs[k];
        if (typeof v === 'string') {
          parts.push(v as string);
        } else if (Array.isArray(v)) {
          const arr: string[] = v as string[];
          for (const one of arr) {
            parts.push(one);
          }
        }
      }
      // 只保留「名=值」段，同名取最后一次出现的
      const map: Map<string, string> = new Map();
      for (const one of parts) {
        const first: string = one.split(';')[0].trim();
        const eq: number = first.indexOf('=');
        if (eq > 0) {
          map.set(first.substring(0, eq), first);
        }
      }
      const out: string[] = [];
      map.forEach((v: string) => {
        out.push(v);
      });
      return out.join('; ');
    } catch (e) {
      return '';
    } finally {
      req.destroy();
    }
  }

  /**
   * 云 API 直取通道完整登录：先取中继路由 Cookie，再复用 loginViaRelay 走原生 authLogin。
   * 全程原生 HTTP，不依赖 SmartURL 的 JS 选路页（该页在 WebView 里实测经常解析不到设备）。
   */
  static async loginViaTunnel(relayHost: string, tunnelAgentId: string,
                              user: string, password: string): Promise<LoginResult> {
    const jar: string = await QnapApi.fetchTunnelCookieJar(relayHost, tunnelAgentId);
    if (jar.length === 0) {
      const fail: LoginResult = { success: false, errorKey: 'login.fail.network', session: null };
      return fail;
    }
    return await QnapApi.loginViaRelay(relayHost, jar, user, password);
  }

  /**
   * 用网页验证拿到的中继会话直接建会话（无需再走 authLogin）。
   *
   * 实测通路：`https://d2.myqnapcloud.cn/cgi-bin/<api>?sid=<NAS_SID>` +
   * 中继 Cookie → 返回该设备的真实 QTS 数据（authPassed=1）。
   * 因此这里只需要把 host/scheme/port 定到中继，sid 用网页登录产生的那一个。
   */
  static async adoptRelay(host: string, sid: string, cookie: string, user: string,
                          password: string): Promise<LoginResult> {
    QnapApi.setRelayCookie(cookie, host);
    QnapApi.scheme = 'https';
    return await QnapApi.finishLogin('qnapId', host, 443, 'https', sid, user, password, 15000);
  }

  /** 延时（毫秒），用于限流退避。 */
  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /* ==================== 登录 ==================== */

  /**
   * IP 直连登录。host 可为 IPv4 或主机名；scheme 默认 http。
   * 成功后把 sid / 凭据写入客户端状态，供后续请求与静默重登使用。
   */
  static async login(host: string, port: number, user: string, password: string,
                     scheme: string = 'http'): Promise<LoginResult> {
    return await QnapApi.performLogin('localIp', host, port, user, password, scheme);
  }


  /**
   * 登录阶段（供登录页展示，避免用户面对一个 20 秒没有任何反馈的转圈）：
   * '' / login.stage.domain / login.stage.lan / login.stage.auth
   */
  static setStage(key: string): void {
    AppStorage.setOrCreate<string>('loginStage', key);
  }

  /**
   * 局域网自动发现（ID 登录的最后一级回退，本机实测必需）：
   *
   * 实测事实：`myserver.mycloudnas.com` 能解析到用户公网 IP，但公网只映射了 8081，
   * 而 8081 落点是 **myQNAPcloud 云端门户**（除 /login、/static 外所有路径 302 到 /login），
   * `/cgi-bin/authLogin.cgi` 在公网上根本拿不到 sid。5000 / 443 / 8080 对外全是 refused。
   *
   * 也就是说：只要不在同一局域网且没做 5000 端口映射，云域名拿不到 QTS API。
   * 于是这里补上「同一 Wi-Fi 下直接找设备」——这正是 QNAP ID 用户最常见的真实场景：
   * 家里用 ID 登录，其实设备就在同一个路由下。
   *
   * 安全约束：扫描阶段**只发不带凭据**的探测请求，确认对方是 QTS 之后才发送账号密码，
   * 绝不把用户密码广播给整段局域网；蜂窝网络下直接跳过（拿不到有意义的私网网段）。
   */
  /** 局域网扫描的「边扫边报」结果：loginById 每轮波次后读它，扫到就立刻停手去登录。 */
  private static lanFound: LanHit[] = [];

  private static async scanLanForQts(): Promise<LanHit[]> {
    const link: LanLink | null = await QnapApi.lanLink();
    if (link === null || link.prefix < 24) {
      return [];
    }
    const dot: number = link.ip.lastIndexOf('.');
    if (dot <= 0) {
      return [];
    }
    const base: string = link.ip.substring(0, dot);
    const hosts: string[] = [];
    for (let i = 1; i <= 254; i++) {
      const ip: string = base + '.' + String(i);
      if (ip !== link.ip) {
        hosts.push(ip);
      }
    }
    const found: LanHit[] = [];
    const started: number = Date.now();
    // 并发 40：每批约 1.9 秒（未被占用的地址就是一次 connect 超时）。
    // 本机实测（253 个地址）：第 3 批即命中 192.0.2.10:5000，总耗时 4.4 秒。
    // 扫到即停；最多扫 16 秒，绝不拖死登录流程。
    const batch: number = 40;
    for (let i = 0; i < hosts.length; i += batch) {
      if (Date.now() - started > 16000) {
        break;
      }
      const slice: string[] = hosts.slice(i, i + batch);
      const probes: Promise<LanHit | null>[] = [];
      for (const ip of slice) {
        probes.push(QnapApi.probeQtsQuiet(ip));
      }
      const hits: (LanHit | null)[] = await Promise.all(probes);
      for (const h of hits) {
        if (h !== null) {
          found.push(h);
        }
      }
      if (found.length > 0) {
        // 立刻对外可见：loginById 的域名波次会看到并提前结束。
        QnapApi.lanFound = found;
        break;
      }
    }
    return found;
  }

  /** 取本机默认网络的 IPv4 与子网前缀；Wi-Fi / 有线才返回（蜂窝下扫描没有意义）。 */
  private static async lanLink(): Promise<LanLink | null> {
    try {
      const net: connection.NetHandle = await connection.getDefaultNet();
      if (net === null || net.netId === 0) {
        return null;
      }
      const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
      const caps: connection.NetCapabilities = await connection.getNetCapabilities(net);
      let usable: boolean = false;
      for (const bearer of caps.bearerTypes) {
        if (bearer === connection.NetBearType.BEARER_WIFI ||
          bearer === connection.NetBearType.BEARER_ETHERNET ||
          bearer === connection.NetBearType.BEARER_VPN) {
          usable = true;
        }
      }
      if (!usable) {
        return null;
      }
      for (const entry of props.linkAddresses) {
        const addr: string = entry.address.address;
        if (addr.length === 0 || addr.indexOf(':') >= 0 || addr.indexOf('169.254.') === 0) {
          continue;
        }
        const info: LanLink = { ip: addr, prefix: entry.prefixLength };
        return info;
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  /**
   * 无凭据探测单个 IP 是否为 QTS。
   * 两个常见 http 端口（5000 本机在用 / 8080 出厂默认）**并发**探测，把每批耗时压到 1 秒级。
   *
   * **判据必须是 `QDocRoot`，不能是 `authPassed`**（真机实测 2026-11-12）：
   *   不带凭据的 `GET /cgi-bin/authLogin.cgi` 返回的是「环境探测」XML，
   *   内容为 `<QDocRoot version="1.0"><hostname>MyNAS</hostname>
   *   <webAccessPort>5000</webAccessPort>…` —— **整份 2093 字节里根本没有 authPassed**。
   *   （只有带上正确/错误账号密码时才会出现 authPassed=1 / 0。）
   *   旧判据要求 body 含 authPassed，于是每一个地址都被判成「不是 QTS」，
   *   局域网扫描永远返回空 —— 这就是 ID 登录一直失败的真正原因。
   */
  private static async probeQtsQuiet(ip: string): Promise<LanHit | null> {
    const ports: number[] = [5000, 8080];
    const probes: Promise<RawResponse>[] = [];
    for (const port of ports) {
      const url: string = 'http://' + ip + ':' + String(port) + '/cgi-bin/authLogin.cgi';
      probes.push(QnapApi.sendRaw(url, http.RequestMethod.GET, '', 900, ''));
    }
    const res: RawResponse[] = await Promise.all(probes);
    for (let i = 0; i < res.length; i++) {
      if (res[i].status === 200 && res[i].body.indexOf('QDocRoot') >= 0 &&
        res[i].body.indexOf('webAccessPort') >= 0) {
        const hit: LanHit = { ip: ip, port: ports[i] };
        return hit;
      }
    }
    return null;
  }

  /**
   * 响应是否为 myQNAPcloud 门户 / CloudLink 节点，而不是 QTS 本体的 XML。
   *
   * 实测：`https://d21a.myqnapcloud.cn/cgi-bin/authLogin.cgi` 不论带不带凭据都返回
   * 门户 HTML（302 到 `smarturl/device_not_found?code=cloudlink_service_not_found`），
   * 完全没有 `QDocRoot` / `authPassed`。这类域名不能当 QTS 端口用，
   * 必须单独提示，否则用户只会看到「无法连接」而不知道该改哪里。
   */
  private static isPortalBody(body: string): boolean {
    if (body.length === 0) {
      return false;
    }
    if (body.indexOf('cloudlink_service_not_found') >= 0 ||
      body.indexOf('device_not_found') >= 0 ||
      body.indexOf('QPORTAL_SESSION_ID') >= 0) {
      return true;
    }
    return body.indexOf('myQNAPcloud') >= 0 && body.indexOf('QDocRoot') < 0;
  }

  /**
   * 响应是否为**真实 QTS 接口输出**。
   *
   * 这个判断是「网页验证后能否算登录成功」的关口：中继会话过期时，
   * 中继会把 `/cgi-bin/*` 也渲染成门户 HTML（HTTP 200、body 非空），
   * 旧实现只看「body 非空」就判定成功，于是建出一个假会话 ——
   * 用户看着进了 App，但系统信息、文件、容器全是空的。
   */
  private static isQtsBody(body: string): boolean {
    if (body.length === 0) {
      return false;
    }
    if (QnapApi.isPortalBody(body)) {
      return false;
    }
    return body.indexOf('authPassed') >= 0 || body.indexOf('QDocRoot') >= 0;
  }

  /** 记下「中继被打回门户」这一事实，供登录页给出可操作提示。 */
  private static noteBody(body: string): void {
    if (QnapApi.relayCookie.length === 0 || body.length === 0) {
      return;
    }
    if (QnapApi.isPortalBody(body)) {
      QnapApi.relayExpiredFlag = true;
    }
  }

  /** 中继路由 Cookie 是否已失效（失效后只能重新做网页验证）。 */
  static relayExpired(): boolean {
    return QnapApi.relayExpiredFlag;
  }

  /** 彻底退出中继模式（退出登录 / 切到直连端点时调用）。 */
  static clearRelay(): void {
    QnapApi.relayCookie = '';
    QnapApi.relayHost = '';
    QnapApi.relayExpiredFlag = false;
  }

  /**
   * 端点与中继模式对齐：
   * 中继 Cookie 只对 myQNAPcloud 域名有意义，换成直连 IP / DDNS 时必须清掉，
   * 否则会把中继 Cookie 一起发给设备（轻则无效，重则被判为异常会话）。
   */
  private static syncRelayForHost(host: string): void {
    if (QnapApi.relayCookie.length === 0) {
      return;
    }
    const lower: string = host.toLowerCase();
    const cloud: boolean = lower.indexOf('myqnapcloud') >= 0 ||
      lower.indexOf('mycloudnas') >= 0 || lower.indexOf('qlink.to') >= 0;
    if (!cloud) {
      QnapApi.clearRelay();
    }
  }

  /**
   * 用户在 QNAP ID 输入框里直接粘贴完整 URL 时（`http(s)://host[:port]/...`），
   * 按直连端点处理：用它自己的协议和端口，不再去猜 `.local` / 云端后缀。
   */
  private static directTarget(input: string): IdTarget | null {
    let text: string = input.trim();
    if (text.indexOf('://') < 0) {
      return null;
    }
    let scheme: string = 'http';
    if (text.indexOf('https://') === 0) {
      scheme = 'https';
      text = text.substring(8);
    } else if (text.indexOf('http://') === 0) {
      scheme = 'http';
      text = text.substring(7);
    }
    const slash: number = text.indexOf('/');
    if (slash >= 0) {
      text = text.substring(0, slash);
    }
    let host: string = text;
    let port: number = 0;
    const colon: number = text.lastIndexOf(':');
    if (colon > 0) {
      const n: number = parseInt(text.substring(colon + 1), 10);
      if (!isNaN(n) && n > 0) {
        host = text.substring(0, colon);
        port = n;
      }
    }
    if (host.length === 0) {
      return null;
    }
    const target: IdTarget = {
      host: host,
      scheme: scheme,
      port: port > 0 ? port : (scheme === 'https' ? 443 : 5000)
    };
    return target;
  }

  /**
   * 主机名是否存在（DNS 预解析）。
   *
   * 只用来「剪枝」：解析不到的域名一定连不上，早点剔除能省十几秒；
   * 解析成功也不代表端口开着（实测 myserver.mycloudnas.com 解析正常但 5000/5001 refused），
   * 所以这里只把结果当作筛选依据与错误归因依据，不作为连通性判断。
   */
  private static async resolveHost(host: string): Promise<boolean> {
    try {
      const list: connection.NetAddress[] = await connection.getAddressesByName(host);
      return list.length > 0 && list[0].address.length > 0;
    } catch (e) {
      return false;
    }
  }

  /** 单端点认证探测：不触碰全局会话状态，可安全并发。 */
  private static async probeEndpoint(host: string, port: number, scheme: string,
                                     user: string, password: string,
                                     timeout: number): Promise<ProbeResult> {
    const url: string = scheme + '://' + host + ':' + String(port) +
      '/cgi-bin/authLogin.cgi?user=' + encodeURIComponent(user) +
      '&pwd=' + encodeURIComponent(b64encode(password)) + '&service=1';
    const raw: RawResponse = await QnapApi.sendRaw(url, http.RequestMethod.GET, '', timeout, '');
    // 门户特征：myQNAPcloud 的 CloudLink / SmartURL 节点会把所有路径 302 或直接
    // 渲染成门户页（含 `cloudlink_service_not_found` / `device_not_found` / `<title>myQNAPcloud`）。
    // 这类地址不是 QTS 管理端口，必须单独识别，否则只会报成含糊的「网络失败」。
    if (QnapApi.isPortalBody(raw.body)) {
      const portal: ProbeResult = { state: 'portal', sid: '' };
      return portal;
    }
    // 302 → /login 说明该端口是网页入口而不是可用 API；空体、非 QTS 响应同样判失败。
    if (raw.status >= 300 && raw.status < 400) {
      const redir: ProbeResult = { state: 'fail', sid: '' };
      return redir;
    }
    if (raw.body.length === 0 || raw.body.indexOf('authPassed') < 0) {
      const junk: ProbeResult = { state: 'fail', sid: '' };
      return junk;
    }
    if (cdata(raw.body, 'authPassed') !== '1') {
      const bad: ProbeResult = { state: 'invalid', sid: '' };
      return bad;
    }
    const sid: string = cdata(raw.body, 'authSid');
    const ok: ProbeResult = { state: sid.length > 0 ? 'ok' : 'invalid', sid: sid };
    return ok;
  }

  /** 探测成功后落地会话：注入全局状态、拉设备信息、生成 DeviceSession，并记住接入点。 */
  private static async finishLogin(mode: string, host: string, port: number, scheme: string,
                                   sid: string, user: string, password: string,
                                   timeout: number): Promise<LoginResult> {
    QnapApi.h = host;
    QnapApi.p = port;
    QnapApi.scheme = scheme;
    // 先对齐中继模式再注入 sid：applySid 会把中继 Cookie 拼进 Cookie 头，
    // 顺序反了会把上一次会话的中继 Cookie 带到直连端点上。
    QnapApi.syncRelayForHost(host);
    QnapApi.applySid(sid);
    QnapApi.authUser = user;
    QnapApi.authPass = password;
    QnapApi.resetShareCache();
    const base: string = QnapApi.baseUrl();
    const infoXml: string = await QnapApi.get(base + '/cgi-bin/sysinfoReq.cgi', false, timeout);
    // 端口通了不等于拿到设备：中继会话过期时这里会返回门户 HTML，
    // 必须确认是真实 QTS 响应且能读出主机名，才算登录成功。
    if (!QnapApi.isQtsBody(infoXml) || cdata(infoXml, 'hostname').length === 0) {
      const key: string = QnapApi.relayCookie.length > 0 && QnapApi.relayExpiredFlag
        ? 'login.fail.relayExpired'
        : (infoXml.length === 0 ? 'login.fail.network' : 'login.fail.portal');
      const bad: LoginResult = { success: false, errorKey: key, session: null };
      return bad;
    }
    const session: DeviceSession = {
      mode: mode,
      account: user,
      host: host,
      port: port,
      deviceName: cdata(infoXml, 'hostname') || 'QNAP-NAS',
      model: cdata(infoXml, 'displayModelName') || cdata(infoXml, 'modelName') || 'QNAP',
      firmware: 'QTS ' + cdata(infoXml, 'version'),
      serial: cdata(infoXml, 'serial'),
      loginAt: Date.now(),
      sid: QnapApi.sid,
      scheme: scheme,
      password: password,
      relayCookie: QnapApi.relayCookie
    };
    QnapApi.setContext(host, port, session.deviceName, session.model,
      session.firmware, session.serial);
    QnapApi.rememberEndpoint(host, port, scheme);
    const ok: LoginResult = { success: true, errorKey: '', session: session };
    return ok;
  }

  /** 记住最近一次成功的接入点，供下次 ID 登录秒连。 */
  private static rememberEndpoint(host: string, port: number, scheme: string): void {
    const record: EndpointRecord = { host: host, port: port, scheme: scheme };
    AppStorage.setOrCreate<string>('lastEndpoint', JSON.stringify(record));
  }

  /**
   * 读取「上次成功接入点」。
   *
   * 两级来源：
   *  ① `lastEndpoint`（本次起持久化，IP / ID 登录成功都会写）；
   *  ② **持久化会话 `appSession` 里的 host/port** —— 老版本用户只做过 IP 登录，
   *     没有 lastEndpoint，但会话里就存着 192.0.2.10:5000。
   *     把这条捡回来，ID 登录不必再扫一遍局域网就能直接命中。
   */
  private static readEndpoint(): EndpointRecord | null {
    const raw: string | undefined = AppStorage.get<string>('lastEndpoint');
    if (raw !== undefined && raw.length > 0) {
      try {
        const parsed: EndpointRecord = JSON.parse(raw) as EndpointRecord;
        if (parsed.host !== undefined && parsed.host.length > 0) {
          const fixed: EndpointRecord = {
            host: parsed.host,
            port: parsed.port !== undefined ? parsed.port : 5000,
            scheme: parsed.scheme !== undefined && parsed.scheme.length > 0 ? parsed.scheme : 'http'
          };
          return fixed;
        }
      } catch (e) {
        // 落到下面的会话兜底
      }
    }
    const session: string | undefined = AppStorage.get<string>('appSession');
    if (session === undefined || session.length === 0) {
      return null;
    }
    try {
      const peek: SessionPeek = JSON.parse(session) as SessionPeek;
      if (peek.host === undefined || peek.host.length === 0) {
        return null;
      }
      const fromSession: EndpointRecord = {
        host: peek.host,
        port: peek.port !== undefined ? peek.port : 5000,
        scheme: peek.scheme !== undefined && peek.scheme.length > 0 ? peek.scheme : 'http'
      };
      return fromSession;
    } catch (e) {
      return null;
    }
  }

  /**
   * 用户显式配置的**外网接入点**。
   *
   * 为什么必须有它：`qlink.to/myserver` → myQNAPcloud SmartURL 是浏览器式的
   * OAuth + relay 流程（`/oauth/auth` 登录拿 access_token，再 `/ajax/search_device`
   * 取设备路由），未登录时后端直接返回 1020027「无权限访问设备」；
   * 而公网 8081 是云端门户（Nginx + Vue），`/cgi-bin/authLogin.cgi` 一律 302 /login，
   * 5000/5001/443 等 QTS 端口在公网上全部 refused。也就是说：
   * **没有一条可被原生 HTTP 客户端直接调用的公网 QTS 端点**。
   *
   * 因此 App 提供可持久化的「外网地址」（DDNS 域名或公网 IP + 已映射端口）。
   * 只要路由器把 5000/5001（或任意自定义端口）转发到 NAS，App 就能从这个端点登录；
   * 登录成功后 DeviceSession 记的就是这个端点，`baseUrl()` 让文件、容器、监控、
   * 上传下载等**所有功能都走同一条可达链路**，外网即全功能。
   *
   * 支持三种写法：`host`、`host:port`、`http(s)://host[:port]`。
   */
  static setWanEndpoint(text: string): void {
    AppStorage.setOrCreate<string>('wanEndpoint', text.trim());
  }

  static wanEndpoint(): string {
    const saved: string | undefined = AppStorage.get<string>('wanEndpoint');
    return saved === undefined ? '' : saved.trim();
  }

  /** 读取上次成功登录的接入点，供登录页自动选路。 */
  static lastEndpointTarget(): IdTarget | null {
    const record: EndpointRecord | null = QnapApi.readEndpoint();
    if (record === null) {
      return null;
    }
    const target: IdTarget = { host: record.host, port: record.port, scheme: record.scheme };
    return target;
  }

  /** 把配置的外网地址解析成 1~2 个候选（协议不确定时两个都试）。 */
  static wanTargets(): IdTarget[] {
    const out: IdTarget[] = [];
    let text: string = QnapApi.wanEndpoint();
    if (text.length === 0) {
      return out;
    }
    let scheme: string = '';
    if (text.indexOf('https://') === 0) {
      scheme = 'https';
      text = text.substring(8);
    } else if (text.indexOf('http://') === 0) {
      scheme = 'http';
      text = text.substring(7);
    }
    const slash: number = text.indexOf('/');
    if (slash >= 0) {
      text = text.substring(0, slash);
    }
    let host: string = text;
    let port: number = 0;
    const colon: number = text.lastIndexOf(':');
    if (colon > 0) {
      const n: number = parseInt(text.substring(colon + 1), 10);
      if (!isNaN(n) && n > 0) {
        host = text.substring(0, colon);
        port = n;
      }
    }
    if (host.length === 0) {
      return out;
    }
    if (scheme.length > 0) {
      const p: number = port > 0 ? port : (scheme === 'https' ? 443 : 5000);
      const one: IdTarget = { host: host, scheme: scheme, port: p };
      out.push(one);
    } else {
      const p: number = port > 0 ? port : 5000;
      const a: IdTarget = { host: host, scheme: QnapApi.schemeForPort(p), port: p };
      out.push(a);
      const b: IdTarget = { host: host, scheme: p === 443 ? 'http' : 'https', port: p };
      out.push(b);
    }
    return out;
  }

  /** 输入是否为「云端 ID」形态（纯名字或 qlink.to 短链）。这类地址需 myQNAPcloud 才能解析。 */
  private static isCloudIdInput(input: string): boolean {
    let text: string = input.trim().toLowerCase();
    if (text.length === 0) {
      return false;
    }
    if (text.indexOf('qlink.to') >= 0) {
      return true;
    }
    if (text.indexOf('://') >= 0) {
      text = text.substring(text.indexOf('://') + 3);
    }
    const slash: number = text.indexOf('/');
    if (slash >= 0) {
      text = text.substring(0, slash);
    }
    const colon: number = text.lastIndexOf(':');
    if (colon > 0) {
      text = text.substring(0, colon);
    }
    return text.length > 0 && text.indexOf('.') < 0;
  }

  /** 把用户输入归一化成候选主机名列表：原样优先，纯名字再补 myQNAPcloud 域名。 */
  private static idHosts(input: string): string[] {
    let text = input.trim();
    if (text.indexOf('://') >= 0) {
      text = text.substring(text.indexOf('://') + 3);
    }
    // qlink.to 短链（http://qlink.to/myserver）→ 取路径首段作为 QNAP ID 再展开候选。
    // 实测 qlink.to 只做 301 跳转到 myQNAPcloud 门户，不能直接当设备地址用。
    const qlink: number = text.toLowerCase().indexOf('qlink.to');
    if (qlink >= 0) {
      let rest: string = text.substring(qlink + 8);
      while (rest.length > 0 && rest.charAt(0) === '/') {
        rest = rest.substring(1);
      }
      const cut: number = rest.indexOf('/');
      text = cut >= 0 ? rest.substring(0, cut) : rest;
    }
    const slash = text.indexOf('/');
    if (slash >= 0) {
      text = text.substring(0, slash);
    }
    const colon = text.lastIndexOf(':');
    if (colon > 0) {
      const tail = text.substring(colon + 1);
      const asPort = parseInt(tail, 10);
      if (!isNaN(asPort) && asPort > 0) {
        text = text.substring(0, colon);
      }
    }
    const hosts: string[] = [];
    const add = (h: string): void => {
      if (h.length > 0 && hosts.indexOf(h) < 0) {
        hosts.push(h);
      }
    };
    const lower = text.toLowerCase();
    const pureName = lower.length > 0 && lower.indexOf('.') < 0 && lower.indexOf(' ') < 0;
    if (pureName) {
      // 纯设备名 / QNAP ID：候选顺序按「最可能先通」排：
      //   1) <id>.local          —— 同网段 mDNS，最快，失败也快
      //   2) <id>.mycloudnas.com —— QNAP 旧版云端 DDNS。实测 myserver.mycloudnas.com
      //                             能解析到用户宽带公网 IP（同城同网段），是 ID 真正的落点
      //   3) <id>.myqnapcloud.com—— 新版云端 DDNS（未启用该域名时不解析，作兜底）
      //   4) 裸名                —— Windows/NetBIOS 环境下才可能通，放最后避免拖慢
      add(lower + '.local');
      add(lower + '.mycloudnas.com');
      add(lower + '.myqnapcloud.com');
      add(text);
    } else {
      add(text);
      // 用户填了完整域名但未带云端后缀时，补一份云端兜底（不重复）。
      if (lower.indexOf('myqnapcloud') < 0 && lower.indexOf('mycloudnas') < 0 &&
        !lower.endsWith('.local')) {
        add(lower + '.myqnapcloud.com');
        add(lower + '.mycloudnas.com');
      }
    }
    return hosts;
  }

  /**
   * 端口 → 默认协议。443 是 https 常规端口；8081 在 QTS 里默认是「http 备用端口」，
   * 但很多环境把「https 备用端口」也配成 8081，所以两个协议都必须试（见 idCandidates）。
   */
  private static schemeForPort(port: number): string {
    return port === 443 ? 'https' : 'http';
  }

  /** 生成 主机 × (协议,端口) 的候选矩阵，去重后按优先级排列。 */
  private static idCandidates(hosts: string[], port: number): IdTarget[] {
    const pairs: IdTarget[] = [];
    const pushPair = (scheme: string, p: number): void => {
      for (let i = 0; i < pairs.length; i++) {
        if (pairs[i].port === p && pairs[i].scheme === scheme) {
          return;
        }
      }
      const item: IdTarget = { host: '', scheme: scheme, port: p };
      pairs.push(item);
    };
    if (port > 0) {
      pushPair(QnapApi.schemeForPort(port), port);
      pushPair(port === 443 ? 'http' : 'https', port);
    } else {
      // 实测结论（2026-11，用户 TS-464C + QTS 5.2.11）：
      //   · 公网只映射了 8081，且 8081 落点是 myQNAPcloud 云端门户
      //     （`/cgi-bin/authLogin.cgi` 与其它路径一律 302 到 `/login`，拿不到 sid）；
      //   · 5000 / 443 / 8080 对外全部 refused。
      // 所以 8081 两个协议都排上（有些设备把 QTS 备用端口配成 8081 http），
      // 真正的兜底是下面的局域网自动发现，而不是死磕公网域名。
      // 常见的 QTS / 反向代理端口全部覆盖：只要用户在路由器做过端口映射，
      // 无需手填外网地址也能自动命中，命中后所有 API 都走这一个端点。
      pushPair('http', 5000);
      pushPair('https', 5001);
      pushPair('http', 8080);
      pushPair('http', 8081);
      pushPair('https', 8081);
      pushPair('https', 443);
      pushPair('http', 443);
      pushPair('https', 8443);
    }
    const list: IdTarget[] = [];
    for (let h = 0; h < hosts.length; h++) {
      for (let i = 0; i < pairs.length; i++) {
        const item: IdTarget = { host: hosts[h], scheme: pairs[i].scheme, port: pairs[i].port };
        list.push(item);
      }
    }
    return list;
  }

  private static async performLogin(mode: string, host: string, port: number, user: string,
                                    password: string, scheme: string,
                                    timeout: number = 15000): Promise<LoginResult> {
    // 先按目标地址配置状态，get() 才能拼出正确的 base URL。
    QnapApi.h = host;
    QnapApi.p = port;
    QnapApi.scheme = scheme;
    QnapApi.sid = '';
    // 端点变了就对齐中继模式：非云端域名一律丢弃中继 Cookie。
    QnapApi.syncRelayForHost(host);
    // 中继模式下 authLogin 自身也必须带路由 Cookie，否则中继只会返回门户页。
    QnapApi.cookie = QnapApi.relayCookie;
    const base = QnapApi.baseUrl();
    const loginUrl = base + '/cgi-bin/authLogin.cgi?user=' + encodeURIComponent(user) +
      '&pwd=' + encodeURIComponent(b64encode(password)) + '&service=1';
    try {
      const xml = await QnapApi.get(loginUrl, false, timeout);
      if (xml.length === 0) {
        const netFail: LoginResult = { success: false, errorKey: 'login.fail.network', session: null };
        return netFail;
      }
      if (!QnapApi.isQtsBody(xml)) {
        // 中继把请求打回门户页 = 中继会话过期，只能重新网页验证。
        const key: string = QnapApi.relayCookie.length > 0 ? 'login.fail.relayExpired'
          : 'login.fail.portal';
        const notQts: LoginResult = { success: false, errorKey: key, session: null };
        return notQts;
      }
      if (cdata(xml, 'authPassed') !== '1') {
        const failed: LoginResult = { success: false, errorKey: 'login.fail.invalid', session: null };
        return failed;
      }
      QnapApi.applySid(cdata(xml, 'authSid'));
      QnapApi.authUser = user;
      QnapApi.authPass = password;
      QnapApi.resetShareCache();
      const infoXml = await QnapApi.get(base + '/cgi-bin/sysinfoReq.cgi', false, timeout);
      // 认证通过还不够：必须真的能读到设备信息，否则建出来的会话在主界面上是全空的。
      if (!QnapApi.isQtsBody(infoXml) || cdata(infoXml, 'hostname').length === 0) {
        const key: string = QnapApi.relayCookie.length > 0 && QnapApi.relayExpiredFlag
          ? 'login.fail.relayExpired' : 'login.fail.network';
        const noInfo: LoginResult = { success: false, errorKey: key, session: null };
        return noInfo;
      }
      const session: DeviceSession = {
        mode: mode,
        account: user,
        host: host,
        port: port,
        deviceName: cdata(infoXml, 'hostname') || 'QNAP-NAS',
        model: cdata(infoXml, 'displayModelName') || cdata(infoXml, 'modelName') || 'QNAP',
        firmware: 'QTS ' + cdata(infoXml, 'version'),
        serial: cdata(infoXml, 'serial'),
        loginAt: Date.now(),
        sid: QnapApi.sid,
        scheme: scheme,
        password: password,
        relayCookie: QnapApi.relayCookie
      };
      QnapApi.setContext(host, port, session.deviceName, session.model, session.firmware, session.serial);
      // IP 登录成功后也记住接入点：之后用 QNAP ID 登录时会把它作为第一候选，
      // 不必再做域名探测与局域网扫描（用户「先 IP 一次、以后只填 ID」即可）。
      QnapApi.rememberEndpoint(host, port, scheme);
      const ok: LoginResult = { success: true, errorKey: '', session: session };
      return ok;
    } catch (e) {
      const netFail: LoginResult = { success: false, errorKey: 'login.fail.network', session: null };
      return netFail;
    }
  }

  /**
   * 冷启动恢复会话：把持久化的 sid / 接入点 / 凭据重新注入静态状态。
   *
   * 这是「重启 App 后文件页、容器页空白」的根因修复点——
   * 会话对象此前只存了 host / port，sid 留在内存里，重启即丢失，
   * 之后所有请求都被设备判为未认证。
   */
  static restore(session: DeviceSession): void {
    QnapApi.h = session.host;
    QnapApi.p = session.port;
    QnapApi.scheme = session.scheme.length > 0 ? session.scheme : 'http';
    QnapApi.relayCookie = session.relayCookie !== undefined ? session.relayCookie : '';
    QnapApi.relayHost = QnapApi.relayCookie.length > 0 ? session.host : '';
    QnapApi.relayExpiredFlag = false;
    QnapApi.applySid(session.sid);
    QnapApi.authUser = session.account;
    QnapApi.authPass = session.password;
    QnapApi.resetShareCache();
    QnapApi.setContext(session.host, session.port, session.deviceName, session.model,
      session.firmware, session.serial);
  }

  /** 当前 sid 是否仍在（界面用于判断是否需要重新登录）。 */
  static hasSession(): boolean {
    return QnapApi.sid.length > 0;
  }

  /** 当前有效 sid（静默重登后会变化，调用方可回写到持久化会话）。 */
  static currentSid(): string {
    return QnapApi.sid;
  }

  /* ==================== 设备状态 ==================== */

  /**
   * 同一指标在不同 QTS 版本里的 tag 名不一致：按候选顺序取第一个有效整数。
   * 设备不上报时保持 0，由界面显示「—」，绝不造数。
   */
  private static firstInt(xml: string, tags: string[]): number {
    for (const tag of tags) {
      const value: number = cdataInt(xml, tag, 0);
      if (value > 0) {
        return value;
      }
    }
    return 0;
  }

  /** 系统监控响应：CPU / 内存 / 运行时长 / 主机信息。 */
  private static async monitor(): Promise<string> {
    const url = QnapApi.baseUrl() + '/cgi-bin/management/manaRequest.cgi?subfunc=sysmonitor' +
      '&sys_cpu_use_v2=1&sys_memory_use=1';
    return await QnapApi.get(url);
  }

  /** 卷 / 磁盘信息响应：卷名、可用空间、磁盘数、加密状态与分区明细。 */
  private static async volumeInfo(): Promise<string> {
    const url = QnapApi.baseUrl() + '/cgi-bin/management/manaRequest.cgi?subfunc=sysmonitor' +
      '&net_in=1&net_out=1';
    return await QnapApi.get(url);
  }

  /** 设备概览：真实 CPU / 内存 / 运行时长 / 容量可用空间 + 设备信息。 */
  static async overview(): Promise<DeviceOverview> {
    const mon = await QnapApi.monitor();
    const vol = await QnapApi.volumeInfo();

    const cpu = cdataPercent(mon, 'cpu_total_usage');
    const memTotalKb = cdataInt(mon, 'mem_total', 0);
    const memUsedKb = cdataInt(mon, 'mem_used', 0);
    const days = cdataInt(mon, 'sys_uptime_day', 0);
    const hours = cdataInt(mon, 'sys_uptime_hour', 0);
    const minutes = cdataInt(mon, 'sys_uptime_min', 0);

    const volumeName = cdata(vol, 'volumeLabel');
    const freeGB = cdataInt(vol, 'freeSize', 0);
    const diskCount = cdataInt(vol, 'volumeDisks', 0);
    // eth_count 为设备上报的以太网口数量（TS-464C 为 2）。
    const ethernetCount = cdataInt(vol, 'eth_count', 0);

    // 温度 / 风扇：不同机型上报的 tag 名不一致，按候选顺序取；
    // 设备不上报时保持 0，界面显示「—」。
    const hardwareXml: string = mon + '\n' + vol;
    const cpuTemp = QnapApi.firstInt(hardwareXml,
      ['cpu_tempc', 'cpu_temp', 'cpu_temperature', 'cpu_temperature_c']);
    const sysTemp = QnapApi.firstInt(hardwareXml,
      ['sys_temp', 'system_temp', 'sys_tempc', 'system_tempc', 'temp_sys', 'temperature']);
    const fanRpm = QnapApi.firstInt(hardwareXml,
      ['fan_speed', 'fan_rpm', 'sys_fan_speed', 'system_fan_speed', 'fan1_speed', 'fan1_rpm']);

    const overview: DeviceOverview = {
      deviceName: QnapApi.deviceName(),
      model: QnapApi.model(),
      firmware: QnapApi.firmware(),
      serial: QnapApi.serial(),
      uptime: QnapApi.formatUptime(days, hours, minutes),
      cpu: cpu,
      memory: memTotalKb > 0 ? Math.round(memUsedKb / memTotalKb * 100) : 0,
      memoryUsedGB: Math.round(memUsedKb / 1024 / 1024 * 10) / 10,
      memoryTotalGB: Math.round(memTotalKb / 1024 / 1024 * 10) / 10,
      cpuTemp: cpuTemp,
      sysTemp: sysTemp,
      fanRpm: fanRpm,
      uploadMbps: 0,
      downloadMbps: 0,
      storageUsedTB: 0,
      storageTotalTB: 0,
      storageVolumeName: volumeName,
      storageFreeGB: freeGB,
      ethernetCount: ethernetCount,
      volumeCount: volumeName.length > 0 ? 1 : 0,
      diskCount: diskCount,
      containerCount: 0,
      serviceRunning: 0,
      health: cpu > 85 ? 'warning' : 'good'
    };
    return overview;
  }

  /* ==================== 文件 ==================== */

  /**
   * 文件列表（File Station 6）。
   *
   * 真实契约（TS-464C / QTS 5.2.11 实测）：
   *   GET /FileStation6/utilRequest.cgi?func=get_list&path=<共享路径>
   *       &limit=200&offset=0&sort=name&dir=ASC&sid=<sid>
   *   成功 → { "total": 6, "real_total": 6, "datas": [ { "filename": "music", ... } ] }
   *   路径不存在 → { "version": "...", "status": 5, "success": "true" }
   *
   * 目录必须落在共享目录内（根路径 "/" 不可列举），由 shares() 提供入口。
   */
  static async files(path: string, limit: number = 200): Promise<FileListResult> {
    const url = QnapApi.baseUrl() + '/FileStation6/utilRequest.cgi?func=get_list&path=' +
      encodeURIComponent(path) + '&limit=' + String(limit) +
      '&offset=0&sort=name&dir=ASC';
    const body = await QnapApi.get(url);
    return QnapApi.parseFileList(body);
  }

  /** 解析 File Station 6 的列表响应，并保留目录状态用于区分空目录 / 路径不存在。 */
  private static parseFileList(body: string): FileListResult {
    const result: FileListResult = { items: [], total: 0, status: 0, valid: false };
    if (body.length === 0) {
      result.status = -1;
      return result;
    }
    try {
      const obj = JSON.parse(body) as FileListResp;
      if (obj.datas === undefined) {
        // 无 datas 时为错误壳：{ version, status, success }
        result.status = obj.status !== undefined ? obj.status : -2;
        result.valid = false;
        return result;
      }
      result.valid = true;
      result.total = obj.total !== undefined ? obj.total : obj.datas.length;
      for (const d of obj.datas) {
        const name = d.filename !== undefined ? d.filename : '';
        if (name.length === 0) {
          continue;
        }
        const isFolder = d.isfolder !== undefined && d.isfolder !== 0;
        const item: FileItem = {
          id: name,
          name: name,
          kind: isFolder ? 'folder' : QnapApi.kindOf(name),
          size: QnapApi.parseSize(d.filesize),
          modified: d.epochmt !== undefined ? d.epochmt * 1000 : 0,
          owner: d.owner !== undefined ? d.owner : '',
          permission: d.privilege !== undefined ? d.privilege : '',
          // QTS 未返回子项数量，保持 0，界面不据此推断
          childCount: 0
        };
        result.items.push(item);
      }
    } catch (e) {
      result.status = -2;
      result.valid = false;
    }
    return result;
  }

  /** 文件大小：QTS 以字符串返回（目录为 4096）。 */
  private static parseSize(raw: string | undefined): number {
    if (raw === undefined) {
      return 0;
    }
    const n = parseFloat(raw);
    return isNaN(n) ? 0 : Math.floor(n);
  }

  /** 按扩展名归类，供列表图标使用。 */
  private static kindOf(name: string): string {
    const lower = name.toLowerCase();
    const dot = lower.lastIndexOf('.');
    if (dot < 0 || dot === lower.length - 1) {
      return 'file';
    }
    const ext = lower.substring(dot + 1);
    if (ext === 'jpg' || ext === 'jpeg' || ext === 'png' || ext === 'gif' || ext === 'bmp' ||
      ext === 'webp' || ext === 'heic' || ext === 'tif' || ext === 'tiff') {
      return 'image';
    }
    if (ext === 'mp4' || ext === 'mkv' || ext === 'mov' || ext === 'avi' || ext === 'rmvb' ||
      ext === 'wmv' || ext === 'flv') {
      return 'video';
    }
    if (ext === 'zip' || ext === 'rar' || ext === '7z' || ext === 'tar' || ext === 'gz' ||
      ext === 'bz2' || ext === 'iso') {
      return 'archive';
    }
    return 'file';
  }

  /**
   * 共享目录列表（文件浏览的入口）。
   *
   * 真实契约：GET /cgi-bin/priv/privRequest.cgi?subfunc=share&read=2&refresh=0
   *   → <defShareList><![CDATA[Public/TMBackup]]></defShareList>（共享名以 / 分隔）
   *   → <no_del_list><no_del_info><share_name>Container</share_name>（系统共享）
   * 名单中可能包含尚未创建的共享（如 TMBackup），因此逐个用 get_list 探测后只保留真实存在的。
   */
  static async shares(): Promise<string[]> {
    if (QnapApi.shareCache.length > 0) {
      return QnapApi.shareCache;
    }
    const url = QnapApi.baseUrl() + '/cgi-bin/priv/privRequest.cgi?subfunc=share&read=2&refresh=0';
    const candidates: string[] = [];
    /** 设备在「共享清单」里明确列出的项：探测失败也保留，否则 Data 这类共享会被误过滤。 */
    const explicit: string[] = [];
    const body = await QnapApi.get(url);
    if (body.length === 0) {
      return [];
    }

    const push = (list: string[], raw: string): void => {
      const name: string = raw.trim().replace(/^\/+/, '');
      if (name.length > 0 && list.indexOf(name) < 0) {
        list.push(name);
      }
    };

    // 1) 默认共享清单（可能包含尚未创建的目录，如 TMBackup）
    //    不同固件的分隔符可能是 / 或 ;，统一归一化后再拆，避免把「A;B」当成一个共享名。
    const defList = cdata(body, 'defShareList');
    if (defList.length > 0) {
      const normalized: string = defList.replace(/;/g, '/').replace(/\|/g, '/');
      const parts = normalized.split('/');
      for (const part of parts) {
        push(candidates, part);
      }
    }

    // 2) 系统共享（Public / Container 等）
    const sysBlocks = cdataBlocks(body, 'no_del_info');
    for (const block of sysBlocks) {
      const name = cdata(block, 'share_name');
      push(candidates, name);
      push(explicit, name);
    }

    // 3) 普通共享：share_list / share_info（旧实现漏解析，导致只显示前两个系统共享）
    const listTags: string[] = ['share_info', 'share'];
    for (const tag of listTags) {
      const blocks = cdataBlocks(body, tag);
      for (const block of blocks) {
        let name = cdata(block, 'share_name');
        if (name.length === 0) {
          name = cdata(block, 'shareName');
        }
        push(candidates, name);
        push(explicit, name);
      }
    }

    // 4) 部分固件直接平铺 <share_name> / <shareName>
    const flatTags: string[] = ['share_name', 'shareName'];
    for (const tag of flatTags) {
      const blocks = cdataBlocks(body, tag);
      for (const block of blocks) {
        const name = cdata(block, tag);
        push(candidates, name);
        push(explicit, name);
      }
    }

    const valid: string[] = [];
    for (const name of candidates) {
      // 清单里明确存在的共享直接采用，避免逐个 get_list 探测既慢又误杀只读共享。
      if (explicit.indexOf(name) >= 0) {
        valid.push('/' + name);
        continue;
      }
      const probe = await QnapApi.files('/' + name, 1);
      if (probe.valid) {
        valid.push('/' + name);
      }
    }
    QnapApi.shareCache = valid;
    return valid;
  }

  /** 可写共享目录缓存（用「建临时目录再删掉」探测，建成功即代表该共享可写）。 */
  private static writeCache: string[] = [];

  /**
   * 探测哪些共享目录**可写**。
   *
   * QTS 的共享 ACL 与「能否列目录」无关：本机实测 `/Public` 可以列、可以下载，但
   * 新建目录返回 4、上传会话返回 7 —— 也就是只读。用户默认落在只读共享上点上传，
   * 只会拿到一个失败码。这里在共享根建一个隐藏临时目录做探测（成功即删掉），
   * 结果缓存到会话级，供文件页挑选默认落地目录。
   */
  static async writableRoots(): Promise<string[]> {
    if (QnapApi.writeCache.length > 0) {
      return QnapApi.writeCache;
    }
    const roots: string[] = await QnapApi.shares();
    const probe: string = '.wlt_write_probe';
    const writable: string[] = [];
    for (const root of roots) {
      const created: OpResult = await QnapApi.mkdir(root, probe);
      if (created.ok) {
        writable.push(root);
        // 立刻清理探测目录（永久删除，不留在回收站）
        await QnapApi.removeItems(root, [probe], false);
      }
    }
    QnapApi.writeCache = writable;
    return writable;
  }

  /** 清空共享目录缓存（重新登录后调用）。 */
  static resetShareCache(): void {
    QnapApi.shareCache = [];
    QnapApi.writeCache = [];
  }

  /** 首选落地共享：第一个可写的；没有可写的退回第一个共享；都没有返回空串。 */
  static async preferredRoot(): Promise<string> {
    const writable: string[] = await QnapApi.writableRoots();
    if (writable.length > 0) {
      return writable[0];
    }
    const roots: string[] = await QnapApi.shares();
    return roots.length > 0 ? roots[0] : '';
  }

  /**
   * 逐级创建目录（mkdir -p 语义）。
   *
   * **关键约束（真机实测，旧实现就错在这里）**：
   * 路径第一段是**共享文件夹名**，共享只能由管理员在 QTS 控制台创建；
   * File Station 的 `createdir` 对根目录一律返回 **5（父路径不存在）** ——
   * `createdir(dest_path='/', dest_folder='Container')` → status **5**。
   * 所以绝不能从 `/` 开始逐级建，否则第一步就失败，「我的」页相册会直接报
   * 「备份目录不可写、没有权限」。正确做法：先确认共享存在，再从第二段开始 createdir。
   *
   * 设备实测状态码：1 = 新建成功；**33 = 目录已存在**（重复 createdir 返回 33，不是 2）；
   * 4 = 无权限；5 = 父路径不存在。只有 1 与 33 视为「目录就绪」。
   */
  static async ensureFolder(path: string): Promise<boolean> {
    if (path.length === 0 || path === '/') {
      return false;
    }
    const parts: string[] = [];
    for (const raw of path.split('/')) {
      const name: string = raw.trim();
      if (name.length > 0) {
        parts.push(name);
      }
    }
    if (parts.length === 0) {
      return false;
    }
    const share: string = '/' + parts[0];
    const roots: string[] = await QnapApi.shares();
    if (roots.length > 0) {
      if (roots.indexOf(share) < 0) {
        return false;
      }
    } else {
      // 共享名单拿不到时退化为直接探测该共享可列出，避免误判。
      const probe: FileListResult = await QnapApi.files(share, 1);
      if (!probe.valid) {
        return false;
      }
    }
    if (parts.length === 1) {
      return true;
    }
    let current: string = share;
    for (let i = 1; i < parts.length; i++) {
      const result: OpResult = await QnapApi.mkdir(current, parts[i]);
      if (!result.ok && result.status !== 33) {
        return false;
      }
      current = current + '/' + parts[i];
    }
    return true;
  }

  /* ---- 文件写操作（全部为 POST + x-www-form-urlencoded，已真机实测） ---- */

  /** 在 parentPath 下新建目录。 */
  static async mkdir(parentPath: string, folderName: string): Promise<OpResult> {
    const url = QnapApi.baseUrl() + '/FileStation6/utilRequest.cgi?func=createdir';
    const body = 'dest_path=' + encodeURIComponent(parentPath) +
      '&dest_folder=' + encodeURIComponent(folderName);
    return await QnapApi.postOp(url, body);
  }

  /** 重命名：path 为父目录，source_name 为旧名，dest_name 为新名。 */
  static async renameItem(parentPath: string, sourceName: string, destName: string): Promise<OpResult> {
    const url = QnapApi.baseUrl() + '/FileStation6/utilRequest.cgi?func=rename';
    const body = 'path=' + encodeURIComponent(parentPath) +
      '&source_name=' + encodeURIComponent(sourceName) +
      '&dest_name=' + encodeURIComponent(destName);
    return await QnapApi.postOp(url, body);
  }

  /**
   * 删除若干条目。
   * recycle = true 时移入回收站（不传 force），false 时永久删除（force=1）。
   * 默认走回收站，避免误删不可恢复。
   */
  static async removeItems(parentPath: string, names: string[], recycle: boolean = true): Promise<OpResult> {
    if (names.length === 0) {
      const empty: OpResult = { ok: false, status: -1 };
      return empty;
    }
    const url = QnapApi.baseUrl() + '/FileStation6/utilRequest.cgi?func=delete';
    let body = 'path=' + encodeURIComponent(parentPath);
    for (const name of names) {
      body += '&file_name=' + encodeURIComponent(name);
    }
    body += '&file_total=' + String(names.length) + '&v=2';
    if (!recycle) {
      body += '&force=1';
    }
    return await QnapApi.postOp(url, body);
  }

  /** 统一提交写操作并解析 status（QTS 以 status=1 表示成功）。 */
  private static async postOp(url: string, formBody: string): Promise<OpResult> {
    let target = url;
    if (QnapApi.sid.length > 0 && target.indexOf('sid=') < 0) {
      target += (target.indexOf('?') >= 0 ? '&' : '?') + 'sid=' + QnapApi.sid;
    }
    let raw = await QnapApi.sendRaw(target, http.RequestMethod.POST, formBody, 20000,
      'application/x-www-form-urlencoded; charset=UTF-8');
    if (QnapApi.isAuthFailure(raw.body)) {
      const renewed = await QnapApi.relogin();
      if (renewed) {
        let retry = url;
        retry += (retry.indexOf('?') >= 0 ? '&' : '?') + 'sid=' + QnapApi.sid;
        raw = await QnapApi.sendRaw(retry, http.RequestMethod.POST, formBody, 20000,
          'application/x-www-form-urlencoded; charset=UTF-8');
      }
    }
    const result: OpResult = { ok: false, status: raw.status };
    if (raw.body.length === 0) {
      result.status = raw.status > 0 ? -2 : -1;
      return result;
    }
    try {
      const obj = JSON.parse(raw.body) as OpResp;
      const status = obj.status !== undefined ? obj.status : -2;
      result.status = status;
      result.ok = status === 1;
    } catch (e) {
      result.status = -2;
    }
    return result;
  }

  /* ==================== 文件上传 / 下载 ==================== */

  /**
   * 把（可能含中文的）字符串编码为 UTF-8 字节，避免依赖 TextEncoder 的导入差异。
   * 完整支持 BMP 与代理对（emoji / 罕见汉字）。
   * 公开：文件页新建 txt 时也用它把文本内容转成要上传的字节。
   */
  static strToU8(s: string): Uint8Array {
    const out: number[] = [];
    for (let i = 0; i < s.length; i++) {
      let c: number = s.charCodeAt(i);
      if (c < 0x80) {
        out.push(c);
      } else if (c < 0x800) {
        out.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
      } else if (c >= 0xD800 && c <= 0xDBFF) {
        const c2: number = s.charCodeAt(++i);
        const cp: number = 0x10000 + ((c & 0x3FF) << 10) + (c2 & 0x3FF);
        out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
          0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
      } else {
        out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
      }
    }
    return new Uint8Array(out);
  }

  /** 把若干字节片段拼接成一个 Uint8Array。 */
  private static concatBytes(parts: Uint8Array[]): Uint8Array {
    let len: number = 0;
    for (const p of parts) {
      len += p.byteLength;
    }
    const out: Uint8Array = new Uint8Array(len);
    let off: number = 0;
    for (const p of parts) {
      out.set(p, off);
      off += p.byteLength;
    }
    return out;
  }

  /** Uint8Array → 精确覆盖其字节范围的 ArrayBuffer（http.extraData 需要真正的 ArrayBuffer）。 */
  private static toArrayBuffer(u8: Uint8Array): ArrayBuffer {
    const raw = u8.buffer;
    if (u8.byteOffset === 0 && u8.byteLength === raw.byteLength) {
      return raw as ArrayBuffer;
    }
    const copy: Uint8Array = new Uint8Array(u8.byteLength);
    copy.set(u8);
    return copy.buffer as ArrayBuffer;
  }

  /**
   * 构造 chunked_upload 的 multipart 请求体（完全对齐设备自身 File Station 6 前端）：
   *   formData.set("fileName", name) → 一个纯文本字段
   *   formData.set("file", chunk)    → 一个带 filename 的二进制字段
   *
   * 注意：本请求的 Content-Type 只写 `multipart/form-data`、**不能带 boundary**
   * （设备前端就是这么发的；实测带 boundary 时设备回 status=9）。
   */
  private static buildUploadBody(boundary: string, fileName: string,
                                 chunk: Uint8Array): Uint8Array {
    const crlf: Uint8Array = QnapApi.strToU8('\r\n');
    const dash: Uint8Array = QnapApi.strToU8('--' + boundary);
    const parts: Uint8Array[] = [];
    // 字段 1：fileName（纯文本）
    parts.push(dash);
    parts.push(crlf);
    parts.push(QnapApi.strToU8('Content-Disposition: form-data; name="fileName"'));
    parts.push(crlf);
    parts.push(crlf);
    parts.push(QnapApi.strToU8(fileName));
    parts.push(crlf);
    // 字段 2：file（二进制分片）
    parts.push(dash);
    parts.push(crlf);
    parts.push(QnapApi.strToU8('Content-Disposition: form-data; name="file"; filename="' +
      fileName + '"'));
    parts.push(crlf);
    parts.push(QnapApi.strToU8('Content-Type: application/octet-stream'));
    parts.push(crlf);
    parts.push(crlf);
    parts.push(chunk);
    parts.push(crlf);
    parts.push(dash);
    parts.push(QnapApi.strToU8('--'));
    parts.push(crlf);
    return QnapApi.concatBytes(parts);
  }

  /**
   * 上传文件（File Station 6 官方两段式分片协议，已真机完整验证）。
   *
   *   ① start_chunked_upload：POST（func+sid 在查询串，upload_root_dir 在表单体）
   *        → 成功 {"status":0,"upload_id":"tmpXXXX"}
   *        失败 {"status":7,"upload_id":"---"}  目标目录不可写
   *             {"status":4,...}                无权限
   *   ② chunked_upload：POST，全部参数在查询串，正文为 multipart（fileName + file）
   *        → 成功 {"status":1,"size":"114","name":"x.txt"}
   *
   * 实测要点（TS-464C / QTS 5.2.11 / FileStation 6.0.5）：
   *   - 正文 Content-Type 只能写 multipart/form-data（不带 boundary），否则 status=9；
   *   - 单次请求上限约 32MB（设备前端 chunkSize = 1MB × 32），更大需带 offset 续传；
   *   - 目标共享目录必须对该账号可写：本机 `/Public` 实测为只读（createdir 亦返回 4），
   *     `/Container` 可写。失败时如实回传设备状态码，绝不伪装成功。
   */
  static async uploadFile(destPath: string, fileName: string, data: Uint8Array,
                          overwrite: boolean = true,
                          onProgress?: (done: number, total: number) => void,
                          shouldStop?: () => boolean): Promise<OpResult> {
    // 上传协议里名字出现三次（upload_name / multipart 的 fileName 字段 / filename=），
    // 必须统一用同一个规范化名字：解码百分号、去掉会破坏 multipart 头的引号与换行。
    // 否则设备虽然收下字节，落盘文件名却会变成编码串、数字 ID 或截断的名字。
    const safeName: string = FileNameUtil.clean(FileNameUtil.decode(fileName));
    if (safeName.length === 0) {
      const noName: OpResult = { ok: false, status: -6 };
      return noName;
    }
    const sidQuery = QnapApi.sid.length > 0 ? '&sid=' + QnapApi.sid : '';
    const endpoint = QnapApi.baseUrl() + '/FileStation6/utilRequest.cgi';

    /* ---- ① 开启上传会话 ---- */
    const startRaw = await QnapApi.sendRaw(
      endpoint + '?func=start_chunked_upload' + sidQuery,
      http.RequestMethod.POST,
      'upload_root_dir=' + encodeURIComponent(destPath), 20000,
      'application/x-www-form-urlencoded; charset=UTF-8');
    let startStatus: number = -2;
    let uploadId: string = '';
    if (startRaw.body.length > 0) {
      try {
        const obj = JSON.parse(startRaw.body) as UploadStartResp;
        if (obj.status !== undefined) {
          startStatus = obj.status;
        }
        if (obj.upload_id !== undefined) {
          uploadId = obj.upload_id;
        }
      } catch (e) {
        startStatus = -2;
      }
    }
    if (startStatus !== 0 || uploadId.length === 0 || uploadId === '---') {
      const denied: OpResult = { ok: false, status: startStatus };
      return denied;
    }

    /* ---- ② 分片投递 ----
     * 实测 TS-464C：单片请求用 multipart=0；**多片必须 multipart=1**（用 0 会在第二片起
     * 报 status=7）。1~2MB 分片既能让进度条真实推进，也避免单请求超长占用连接。
     */
    const total: number = data.byteLength;
    const chunkLimit: number = 2 * 1024 * 1024;
    const multipartFlag: string = total > chunkLimit ? '1' : '0';
    const boundary: string = '----QNAPWLT' + Date.now().toString(36);
    let offset: number = 0;
    let status: number = -2;
    let guard: number = 0;
    while (guard < 4096) {
      guard++;
      if (shouldStop !== undefined && shouldStop()) {
        const canceled: OpResult = { ok: false, status: -4 };
        return canceled;
      }
      const end: number = Math.min(offset + chunkLimit, total);
      const chunk: Uint8Array = data.subarray(offset, end);
      const url: string = endpoint + '?func=chunked_upload' + sidQuery +
        '&dest_path=' + encodeURIComponent(destPath) +
        '&mode=' + (overwrite ? '0' : '2') +
        '&dup=' + 'Copy' +
        '&upload_root_dir=' + encodeURIComponent(destPath) +
        '&offset=' + String(offset) +
        '&filesize=' + String(total) +
        '&upload_name=' + encodeURIComponent(safeName) +
        '&settime=1&mtime=' + String(Math.floor(Date.now() / 1000)) +
        '&overwrite=' + (overwrite ? '1' : '0') +
        '&multipart=' + multipartFlag +
        '&upload_id=' + encodeURIComponent(uploadId);
      const body: Uint8Array = QnapApi.buildUploadBody(boundary, safeName, chunk);
      // 关键：Content-Type 不带 boundary（设备前端行为）
      const raw = await QnapApi.sendRaw(url, http.RequestMethod.POST, '', 180000,
        'multipart/form-data', false, body);
      if (raw.body.length === 0) {
        const netFail: OpResult = { ok: false, status: raw.status === 0 ? -1 : -2 };
        return netFail;
      }
      try {
        const obj = JSON.parse(raw.body) as OpResp;
        status = obj.status !== undefined ? obj.status : -2;
      } catch (e) {
        status = -2;
      }
      if (status !== 1) {
        const failed: OpResult = { ok: false, status: status };
        return failed;
      }
      if (onProgress !== undefined) {
        onProgress(end, total);
      }
      if (end >= total) {
        const done: OpResult = { ok: true, status: 1 };
        return done;
      }
      offset = end;
    }
    const timeout: OpResult = { ok: false, status: -3 };
    return timeout;
  }

  /**
   * 下载文件（File Station 6 官方契约，已真机往返验证 4.7MB 字节一致）。
   *
   *   GET utilRequest.cgi?func=download
   *       &source_path=<所在目录>        ← 目录与文件名必须拆开传
   *       &source_file=<文件名>
   *       &isfolder=0&compress=0
   *       &source_total=1                ← 缺这个参数会「200 但 0 字节」，是旧实现失败的根因
   *       &sid=<sid>
   *
   * 响应为文件原始字节 + Content-Disposition 里的原始文件名（含中文时需解码）。
   */
  static async downloadFile(sourcePath: string): Promise<DownloadResult> {
    const slash: number = sourcePath.lastIndexOf('/');
    const dir: string = slash > 0 ? sourcePath.substring(0, slash) : '/';
    const fileName: string = slash >= 0 && slash < sourcePath.length - 1
      ? sourcePath.substring(slash + 1) : QnapApi.baseName(sourcePath);
    const url = QnapApi.baseUrl() + '/FileStation6/utilRequest.cgi?func=download' +
      '&source_path=' + encodeURIComponent(dir) +
      '&source_file=' + encodeURIComponent(fileName) +
      '&isfolder=0&compress=0&source_total=1' +
      (QnapApi.sid.length > 0 ? '&sid=' + QnapApi.sid : '');
    const req = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: QnapApi.headers(),
        connectTimeout: 30000,
        readTimeout: 120000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      };
      const resp = await req.request(url, options);
      const status: number = resp.responseCode;
      if (status !== 200) {
        return { ok: false, status: status, data: null, name: fileName };
      }
      // 设备在失败时返回 JSON / XML 错误壳而不是文件字节，需按 Content-Type 区分，
      // 否则会把一段错误文本当成文件内容保存下来。
      const contentType: string = QnapApi.headerValue(resp.header, 'content-type').toLowerCase();
      if (contentType.indexOf('json') >= 0 || contentType.indexOf('xml') >= 0 ||
        contentType.indexOf('text/html') >= 0) {
        return { ok: false, status: status, data: null, name: fileName };
      }
      const result = resp.result;
      let buf: ArrayBuffer | null = null;
      if (result instanceof ArrayBuffer) {
        buf = result;
      } else if (typeof result === 'string') {
        buf = QnapApi.strToU8(result as string).buffer.slice(0) as ArrayBuffer;
      }
      if (buf === null || buf.byteLength === 0) {
        return { ok: false, status: status, data: null, name: fileName };
      }
      // 优先用设备回传的原始文件名（中文文件名会被百分号编码）
      const saved: string = QnapApi.dispositionName(resp.header, fileName);
      return { ok: true, status: status, data: buf, name: saved };
    } catch (e) {
      return { ok: false, status: -1, data: null, name: fileName };
    } finally {
      req.destroy();
    }
  }

  /** 从响应头里取某个字段（大小写不敏感）。 */
  private static headerValue(header: Object, key: string): string {
    if (header === undefined || header === null) {
      return '';
    }
    // HttpResponse.header 的静态类型是 Object，实际是字符串字典；转换失败即视为无该头。
    let map: Record<string, string> | null = null;
    try {
      map = header as Record<string, string>;
    } catch (e) {
      return '';
    }
    if (map === null) {
      return '';
    }
    const keys: string[] = Object.keys(map);
    for (const k of keys) {
      if (k.toLowerCase() === key) {
        const v: string = map[k];
        return v !== undefined && v !== null ? v : '';
      }
    }
    return '';
  }

  /**
   * 解析 Content-Disposition 里的文件名。
   * 设备实测返回：attachment; filename="%E6%B5%8B..."; filename*=utf-8''%E6%B5%8B...
   * 注意 `filename*=utf-8''` 是全小写，查找必须忽略大小写；值本身是百分号编码。
   */
  private static dispositionName(header: Object, fallback: string): string {
    const cd: string = QnapApi.headerValue(header, 'content-disposition');
    if (cd.length === 0) {
      return fallback;
    }
    const lower: string = cd.toLowerCase();
    const star: number = lower.indexOf('filename*=');
    if (star >= 0) {
      const after: string = cd.substring(star + 10);
      const quote: number = after.indexOf("''");
      if (quote >= 0) {
        let encoded: string = after.substring(quote + 2);
        const semi: number = encoded.indexOf(';');
        if (semi >= 0) {
          encoded = encoded.substring(0, semi);
        }
        encoded = encoded.trim();
        try {
          return decodeURIComponent(encoded);
        } catch (e) {
          return encoded;
        }
      }
    }
    const plain: number = lower.indexOf('filename=');
    if (plain >= 0) {
      let raw: string = cd.substring(plain + 9).trim();
      if (raw.charAt(0) === '"') {
        const end: number = raw.indexOf('"', 1);
        raw = end > 0 ? raw.substring(1, end) : raw.substring(1);
      }
      const semi2: number = raw.indexOf(';');
      if (semi2 >= 0) {
        raw = raw.substring(0, semi2).trim();
      }
      if (raw.indexOf('%') >= 0) {
        try {
          return decodeURIComponent(raw);
        } catch (e2) {
          return raw;
        }
      }
      return raw;
    }
    return fallback;
  }

  /** 取路径末端的文件名，用于下载默认保存名。 */
  private static baseName(path: string): string {
    const idx = path.lastIndexOf('/');
    const name = idx >= 0 ? path.substring(idx + 1) : path;
    return name.length > 0 ? name : 'download.bin';
  }

  /* ==================== 日志 ==================== */

  /** 事件 / 系统日志。该机型 syslog 接口返回 Error=-3，故为空集合。 */
  static async events(): Promise<EventItem[]> {
    const url = QnapApi.baseUrl() + '/cgi-bin/sys/syslogRequest.cgi?subfunc=get_log&limit=30&offset=0';
    const body = await QnapApi.get(url);
    return QnapApi.parseEvents(body);
  }

  private static parseEvents(body: string): EventItem[] {
    const items: EventItem[] = [];
    try {
      const obj = JSON.parse(body) as EventResp;
      if (obj.Success === 'false' || obj.Success === false) {
        return items;
      }
      let datas: EventEntry[] = [];
      if (obj.datas !== undefined) {
        datas = obj.datas;
      } else if (obj.data !== undefined) {
        datas = obj.data;
      }
      for (const e of datas) {
        const id = e.id !== undefined ? e.id : (e.idx !== undefined ? e.idx : '');
        let title = '';
        if (e.msg !== undefined) {
          title = e.msg;
        } else if (e.message !== undefined) {
          title = e.message;
        } else if (e.title !== undefined) {
          title = e.title;
        }
        let level = 'info';
        if (e.severity !== undefined) {
          level = e.severity;
        } else if (e.type !== undefined) {
          level = e.type;
        }
        let detail = '';
        if (e.detail !== undefined) {
          detail = e.detail;
        } else if (e.content !== undefined) {
          detail = e.content;
        }
        const item: EventItem = {
          id: id,
          title: title,
          time: 0,
          level: level,
          detail: detail
        };
        items.push(item);
      }
    } catch (e) {
      // 解析失败保持空集合
    }
    return items;
  }

  /* ==================== 容器（Container Station） ==================== */

  /**
   * Container Station 5 的 REST 网关前缀。
   *
   * 老版本 CS 3/4 用的是 `/cgi-bin/container-station/api/v2/docker/...`（docker 引擎
   * 兼容层）；CS 5 换成了自带网关 `/container-station/api/v3/...`，老的
   * `/cgi-bin/container-station/api/vN/...` 在 CS 5 上一律 404 —— 这正是此前误判
   * 「未安装」的原因：`sysinfoReq` 的 serivceList 只列多媒体类服务，本来就不含
   * Container Station，不能用来判断是否安装。
   *
   * 鉴权：该网关要求 `Authorization: Bearer <token>`，实测设备接受的就是登录拿到的 sid。
   */
  private static readonly CS_API: string = '/container-station/api/v3';

  /** 容器页落地页：能拿到 200 就说明 Container Station 已安装（用于安装判定）。 */
  private static readonly CS_HOME: string = '/container-station/';

  /**
   * 容器列表 + 安装状态。
   *
   * 判定顺序：401 → 已安装但 Bearer 失效；404 → 未安装；200 → 解析 data.items。
   * 200 且 items 为空才是「已安装但无容器」，与「未安装」严格区分。
   */
  static async containersResult(): Promise<ContainerListResult> {
    const url = QnapApi.baseUrl() + QnapApi.CS_API + '/containers?sid=' + QnapApi.sid;
    const raw = await QnapApi.sendRaw(url, http.RequestMethod.GET, '', 15000, '', true);
    const result: ContainerListResult = { items: [], installed: false, status: raw.status };
    if (raw.status === 404) {
      // 网关没有该路由：CS 未安装（或版本过旧不支持 v3）。
      return result;
    }
    if (raw.status === 401) {
      // 网关在，但 Bearer 无效 → 已安装，只是会话需要刷新。
      result.installed = true;
      return result;
    }
    if (raw.status === 0 || raw.status !== 200 || raw.body.length === 0) {
      result.status = raw.status === 0 ? -1 : raw.status;
      return result;
    }
    result.installed = true;
    result.items = QnapApi.parseContainers(raw.body);
    return result;
  }

  /** 兼容旧调用：仅返回条目（未安装时为空集合）。 */
  static async containers(): Promise<ContainerInfo[]> {
    const res = await QnapApi.containersResult();
    return res.items;
  }

  /** 解析 CS 5 的 `{ data: { items: [...] } }` 结构。 */
  private static parseContainers(body: string): ContainerInfo[] {
    const items: ContainerInfo[] = [];
    try {
      const resp = JSON.parse(body) as CsContainerResp;
      if (resp.data === undefined || resp.data.items === undefined) {
        return items;
      }
      const list: CsContainer[] = resp.data.items;
      for (const c of list) {
        // 端口映射：保留结构化数据供 UI 直接生成可点击链接
        let ports = '';
        const portBindings: ContainerPort[] = [];
        const binds: CsPortBind[] = c.portBindings !== undefined ? c.portBindings : [];
        for (const p of binds) {
          const hostPort: number = p.host !== undefined ? p.host : 0;
          const containerPort: number = p.container !== undefined ? p.container : 0;
          if (hostPort <= 0) {
            continue;
          }
          const item = String(hostPort) + ':' + String(containerPort);
          ports = ports.length === 0 ? item : ports + ', ' + item;
          portBindings.push({
            host: hostPort,
            container: containerPort,
            protocol: p.protocol !== undefined ? p.protocol : 'TCP',
            hostIP: p.hostIP !== undefined ? p.hostIP : ''
          });
        }
        const started = c.startedAt !== undefined ? c.startedAt : '';
        const memGB = c.memory !== undefined ? c.memory : 0;
        const cpuVal = c.cpu !== undefined ? c.cpu : 0;
        // 关键：必须保留完整 64 位 ID。CS 5 的启停/删除只认完整 cid，
        // 过去截成 12 位用于展示，结果请求被受理（返回 taskID）却找不到目标容器。
        const fullId: string = c.id !== undefined ? c.id : '';
        const entry: ContainerInfo = {
          id: fullId,
          shortId: fullId.substring(0, 12),
          ctype: c.type !== undefined && c.type.length > 0 ? c.type : 'docker',
          name: c.name !== undefined ? c.name : '',
          image: c.image !== undefined ? c.image : '',
          status: c.status !== undefined ? c.status : '',
          cpu: cpuVal,
          memoryMB: Math.round(memGB * 1024),
          memoryLimitMB: 0,
          ports: ports,
          portBindings: portBindings,
          project: c.project !== undefined ? c.project : '',
          startedAt: started,
          startedMs: QnapApi.parseIsoMillis(started)
        };
        items.push(entry);
      }
    } catch (e) {
      // 解析失败保持空集合
    }
    return items;
  }

  /**
   * 解析设备返回的 ISO 时间戳，返回毫秒。
   *
   * CS 5 给的是 Go 的 `time.Time` 序列化结果，小数位是纳秒（9 位）：
   * `2026-11-12T00:05:00.808636691Z`。ECMAScript 的 ISO 格式只保证 3 位毫秒，
   * 部分引擎会直接返回 NaN，所以这里先把小数位截断到 3 位再交给 Date.parse。
   */
  private static parseIsoMillis(iso: string): number {
    if (iso.length === 0) {
      return 0;
    }
    let normalized = iso.trim();
    const dot = normalized.indexOf('.');
    if (dot > 0) {
      const tail = normalized.substring(dot + 1);
      const tzAt = tail.search(/[Zz+\-]/);
      const frac = tzAt >= 0 ? tail.substring(0, tzAt) : tail;
      if (frac.length > 3) {
        const rest = tzAt >= 0 ? tail.substring(tzAt) : '';
        normalized = normalized.substring(0, dot) + '.' + frac.substring(0, 3) + rest;
      }
    }
    const ms = Date.parse(normalized);
    return isNaN(ms) || ms <= 0 ? 0 : ms;
  }

  /** 镜像列表（CS 5 `GET /container-station/api/v3/images`）。 */
  static async images(): Promise<ImageInfo[]> {
    const url = QnapApi.baseUrl() + QnapApi.CS_API + '/images?sid=' + QnapApi.sid;
    const raw = await QnapApi.sendRaw(url, http.RequestMethod.GET, '', 15000, '', true);
    const items: ImageInfo[] = [];
    if (raw.status !== 200 || raw.body.length === 0) {
      return items;
    }
    try {
      const resp = JSON.parse(raw.body) as CsImageResp;
      if (resp.data === undefined || resp.data.items === undefined) {
        return items;
      }
      const list: CsImage[] = resp.data.items;
      for (const img of list) {
        const tags: string[] = img.tags !== undefined ? img.tags : [];
        const firstTag = tags.length > 0 && tags[0] !== '' ? tags[0] : '<none>:<none>';
        const sep = firstTag.lastIndexOf(':');
        const repo = sep > 0 ? firstTag.substring(0, sep) : firstTag;
        const tag = sep > 0 ? firstTag.substring(sep + 1) : 'latest';
        const createdSec = img.created !== undefined ? img.created : 0;
        const rawId: string = img.id !== undefined ? img.id : '';
        const entry: ImageInfo = {
          id: rawId.replace('sha256:', '').substring(0, 12),
          fullId: rawId,
          type: img.type !== undefined && img.type.length > 0 ? img.type : 'docker',
          name: repo,
          tag: tag,
          sizeMB: img.size !== undefined ? Math.round(img.size / 1024 / 1024) : 0,
          created: createdSec * 1000,
          inUse: img.used === true,
          containerCount: 0
        };
        items.push(entry);
      }
    } catch (e) {
      // 解析失败保持空集合
    }
    return items;
  }

  /**
   * 删除镜像：CS 5 不同固件对 `DELETE /images/{id}` 的参数要求有差异，
   * 这里按「完整 ID + type + force」「完整 ID + type」「仓库:标签」依次尝试，
   * 并且只以镜像列表里真的消失为成功判据，避免把「已受理」误报成已删除。
   */
  static async removeImage(image: ImageInfo): Promise<OpResult> {
    const result: OpResult = { ok: false, status: -1 };
    if (image.fullId.length === 0 || image.inUse) {
      result.status = -4;
      return result;
    }
    const target: string = image.fullId;
    const shortId: string = image.id;
    const candidates: string[] = [
      '/images/' + encodeURIComponent(target) + '?type=' + encodeURIComponent(image.type) + '&force=true',
      '/images/' + encodeURIComponent(target) + '?type=' + encodeURIComponent(image.type),
      '/images/' + encodeURIComponent(image.name + ':' + image.tag) + '?type=docker&force=true'
    ];
    for (const suffix of candidates) {
      const url: string = QnapApi.baseUrl() + QnapApi.CS_API + suffix + '&sid=' + QnapApi.sid;
      const raw = await QnapApi.sendRaw(url, http.RequestMethod.DELETE, '', 25000, '', true);
      result.status = raw.status;
      if (raw.status < 200 || raw.status >= 300) {
        continue;
      }
      for (let i = 0; i < 3; i++) {
        await QnapApi.sleep(800);
        const list: ImageInfo[] = await QnapApi.images();
        let stillThere: boolean = false;
        for (const item of list) {
          if (item.fullId === target || item.id === shortId) {
            stillThere = true;
          }
        }
        if (!stillThere) {
          const ok: OpResult = { ok: true, status: 200 };
          return ok;
        }
      }
    }
    return result;
  }

  /**
   * 容器生命周期操作：start / stop / restart（真机逆向修正版）。
   *
   * 根因：CS 5 前端 `container-action` → Vuex action
   *   `startContainer({commit}, {data}) -> PUT api/v3/containers/start, data`
   * 调用方组装的是 `data: { data: { items: [ {cid, ctype} ] } }`，
   * 所以**真正的 HTTP body 是嵌套结构**：
   *   {"data":{"items":[{"cid":"<64位完整ID>","ctype":"docker"}]}}
   * 旧实现发扁平的 `{"id":"<12位短ID>","type":"docker"}`：后端依旧回 200 + taskID，
   * 任务也显示 completed，但 items 里根本没有目标容器 —— 什么都没做，
   * 界面却因为「任务 completed」提示成功，表现就是「停止/运行点了没用」。
   *
   * 判定：任务 completed 只代表受理，必须以容器列表里的真实状态翻面为准；
   * restart 的终态与初态都是 running，才退化为任务 completed 判定。
   * 状态没变化就如实报失败，不再兜底伪装成功。
   */
  static async containerAction(containerId: string, action: string,
                               ctype: string = 'docker'): Promise<OpResult> {
    const result: OpResult = { ok: false, status: -1 };
    // 短 ID（12 位）是展示用的，不能拿来调用 API；这里直接拒绝，避免静默失败。
    if (containerId.length < 12) {
      result.status = -6;
      return result;
    }
    const url = QnapApi.baseUrl() + QnapApi.CS_API + '/containers/' + action + '?sid=' + QnapApi.sid;
    const safeCtype: string = ctype.length > 0 ? ctype : 'docker';
    const payload = '{"data":{"items":[{"cid":"' + containerId +
      '","ctype":"' + safeCtype + '"}]}}';
    const raw = await QnapApi.sendRaw(url, http.RequestMethod.PUT, payload, 25000,
      'application/json', true);
    result.status = raw.status;
    if (raw.status < 200 || raw.status >= 300) {
      return result;
    }
    let taskId = '';
    try {
      const rj = JSON.parse(raw.body) as CsTaskResp;
      if (rj.data !== undefined && rj.data.taskID !== undefined) {
        taskId = rj.data.taskID;
      }
    } catch (e) {
      // 没有任务号时仍以真实状态判定
    }
    const tasksUrl = QnapApi.baseUrl() + QnapApi.CS_API + '/tasks?sid=' + QnapApi.sid;
    let taskDone: boolean = false;
    for (let i = 0; i < 15; i++) {
      await QnapApi.sleep(1000);
      if (taskId.length > 0 && !taskDone) {
        const tRaw = await QnapApi.sendRaw(tasksUrl, http.RequestMethod.GET, '', 15000, '', true);
        if (tRaw.status === 200 && tRaw.body.length > 0) {
          try {
            const tr = JSON.parse(tRaw.body) as CsTaskListResp;
            const items = tr.data !== undefined && tr.data.items !== undefined ? tr.data.items : [];
            for (const t of items) {
              if (t.id === taskId) {
                if (t.state === 'failed') {
                  result.ok = false;
                  result.status = -1;
                  return result;
                }
                if (t.state === 'completed') {
                  taskDone = true;
                }
              }
            }
          } catch (e) {
            // 任务列表可能被清空，继续以容器状态为准
          }
        }
      }
      const state: string = await QnapApi.containerStatus(containerId);
      if (state.length > 0) {
        if (action === 'stop' && state !== 'running' && state !== 'paused') {
          const ok: OpResult = { ok: true, status: 200 };
          return ok;
        }
        if (action === 'start' && state === 'running') {
          const ok: OpResult = { ok: true, status: 200 };
          return ok;
        }
      }
      if (action === 'restart' && taskDone) {
        const ok: OpResult = { ok: true, status: 200 };
        return ok;
      }
    }
    // 状态始终没变 = 操作确实没生效，不能再按「已受理」返回成功
    result.ok = false;
    result.status = -3;
    return result;
  }

  /** 从容器列表读取指定容器的真实状态（兼容完整 ID 与 12 位短 ID）。 */
  private static async containerStatus(containerId: string): Promise<string> {
    const list: ContainerListResult = await QnapApi.containersResult();
    const short: string = containerId.substring(0, 12);
    for (const c of list.items) {
      if (c.id === containerId || c.shortId === short || containerId === c.shortId) {
        return c.status;
      }
    }
    return '';
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 删除容器：CS 5 用 `DELETE /containers/{id}?type=docker`，同样以「列表里消失」为准。 */
  static async removeContainer(containerId: string, force: boolean = false): Promise<OpResult> {
    const url = QnapApi.baseUrl() + QnapApi.CS_API + '/containers/' +
      encodeURIComponent(containerId) + '?type=docker' + (force ? '&force=true' : '') +
      '&sid=' + QnapApi.sid;
    const raw = await QnapApi.sendRaw(url, http.RequestMethod.DELETE, '', 25000, '', true);
    const result: OpResult = { ok: false, status: raw.status };
    if (raw.status < 200 || raw.status >= 300) {
      return result;
    }
    for (let i = 0; i < 3; i++) {
      await QnapApi.sleep(900);
      const list = await QnapApi.containersResult();
      let stillThere = false;
      for (const c of list.items) {
        if (c.id === containerId || c.shortId === containerId.substring(0, 12)) {
          stillThere = true;
        }
      }
      if (!stillThere) {
        const ok: OpResult = { ok: true, status: 200 };
        return ok;
      }
    }
    return result;
  }

  /**
   * 创建容器：Container Station 5 的创建接口要求完整的 v3 容器规格
   * （`{ctype,name,image,resources,networks,portBindings,…}`），该结构未在真机上
   * 取得可信契约，因此这里明确返回「不支持」，由界面隐藏入口 —— 不做假成功。
   */
  static async createContainer(image: string, name: string, hostPort: string): Promise<OpResult> {
    const unsupported: OpResult = { ok: false, status: -2 };
    return unsupported;
  }

  /** 拉取镜像：同上，CS 5 的 `images/{tag}/pull` 契约未验证，明确不支持。 */
  static async pullImage(image: string): Promise<OpResult> {
    const unsupported: OpResult = { ok: false, status: -2 };
    return unsupported;
  }

  /**
   * 容器日志：CS 5 的 `/container-station/api/v3/logs` 是「系统事件日志」，
   * 不提供单容器 stdout；没有可信端点时返回 available=false，界面如实说明。
   */
  static async containerLogs(containerId: string, tail: number = 100): Promise<ContainerLogs> {
    const result: ContainerLogs = { lines: [], available: false };
    return result;
  }

  /* CS 5 的容器创建 / 镜像拉取 / 单容器日志均无已证实的 v3 契约，
     上面三个方法如实返回不支持，界面据此隐藏入口而不是给出假按钮。 */

  /* ==================== 存储 / 服务 ==================== */

  /** 存储：真实卷信息 + 设备上报的磁盘标识。
   *  实测：QTS 5.2 的 sysmonitor 只上报卷名 / 可用空间 / 磁盘数 / 加密状态，
   *  以及 monitor 响应中每个 swap_mem_info 块里的分区标识（如 3.5" SATA HDD 1）。
   *  设备未上报总容量、单盘容量、型号、序列号与 SMART，这些字段保持「未提供」。
   */
  static async storage(): Promise<StorageBundle> {
    const vol = await QnapApi.volumeInfo();
    const mon = await QnapApi.monitor();
    const pools: StoragePool[] = [];
    const volumes: VolumeInfo[] = [];
    const disks: DiskInfo[] = [];

    const volumeName = cdata(vol, 'volumeLabel');
    if (volumeName.length > 0) {
      const freeGB = cdataInt(vol, 'freeSize', 0);
      const diskCount = cdataInt(vol, 'volumeDisks', 0);
      const encrypted = cdata(vol, 'encryptfs_bool') === '1';
      const stat = cdata(vol, 'volumeStat');
      const partitions: string[] = QnapApi.diskPartitionNames(mon);
      const swapTotalGB = Math.round(cdataInt(mon, 'swap_total', 0) / 1024 / 1024 * 10) / 10;
      const volume: VolumeInfo = {
        id: 'volume-' + volumeName,
        name: volumeName,
        pool: stat.length > 0 ? stat : '—',
        usedTB: 0,
        totalTB: 0,
        // 设备未上报总容量，已用率不可计算，保持 0，界面改用可用空间展示。
        percent: 0,
        status: 'healthy',
        encrypted: encrypted,
        snapshots: 0,
        freeGB: freeGB,
        totalGB: 0,
        diskCount: diskCount,
        partitions: partitions,
        swapTotalGB: swapTotalGB
      };
      volumes.push(volume);

      for (const name of partitions) {
        const disk: DiskInfo = {
          id: 'disk-' + name,
          slot: name,
          model: '—',
          serial: '—',
          capacityTB: 0,
          bus: '—',
          temp: 0,
          smart: '',
          health: 'unknown',
          rpm: 0,
          partition: name
        };
        disks.push(disk);
      }
    }

    const bundle: StorageBundle = { pools: pools, volumes: volumes, disks: disks };
    return bundle;
  }

  /** 设备上报的磁盘标识：取 swap_mem_info 中 type=2（磁盘分区）的描述并去重。 */
  private static diskPartitionNames(xml: string): string[] {
    const names: string[] = [];
    const blocks = cdataBlocks(xml, 'swap_mem_info');
    for (const block of blocks) {
      if (cdata(block, 'swap_mem_type') !== '2') {
        continue;
      }
      const desc = cdata(block, 'swap_patition_desc');
      if (desc.length === 0) {
        continue;
      }
      let duplicated = false;
      for (const item of names) {
        if (item === desc) {
          duplicated = true;
          break;
        }
      }
      if (!duplicated) {
        names.push(desc);
      }
    }
    return names;
  }

  /** 系统服务：真实解析 sysinfoReq.cgi 的 serivceList（QTS 原始拼写）。 */
  static async services(): Promise<ServiceInfo[]> {
    const items: ServiceInfo[] = [];
    const xml = await QnapApi.get(QnapApi.baseUrl() + '/cgi-bin/sysinfoReq.cgi');
    if (xml.length === 0) {
      return items;
    }
    const blocks = cdataBlocks(xml, 'service');
    for (const block of blocks) {
      const id = cdata(block, 'id');
      if (id.length === 0 || cdata(block, 'removed') === '1') {
        continue;
      }
      if (cdata(block, 'installed') !== '1') {
        continue;
      }
      const ssl = cdata(block, 'sslEnabled') === '1';
      const port = ssl ? cdata(block, 'sslPort') : cdata(block, 'port');
      const service: ServiceInfo = {
        id: id,
        name: id,
        description: cdata(block, 'url'),
        protocol: ssl ? 'HTTPS' : 'HTTP',
        port: port,
        running: cdata(block, 'enabled') === '1'
      };
      items.push(service);
    }
    return items;
  }

  /* ==================== 会话上下文（登录后填充 / 冷启动恢复） ==================== */
  private static h: string = '';
  private static p: number = QnapApi.DEFAULT_PORT;
  private static dName: string = '';
  private static mdl: string = '';
  private static fw: string = '';
  private static ser: string = '';

  private static host(): string { return QnapApi.h; }
  private static port(): number { return QnapApi.p; }
  private static deviceName(): string { return QnapApi.dName; }
  private static model(): string { return QnapApi.mdl; }
  private static firmware(): string { return QnapApi.fw; }
  private static serial(): string { return QnapApi.ser; }

  static setContext(host: string, port: number, deviceName: string, model: string,
                    firmware: string, serial: string): void {
    QnapApi.h = host;
    QnapApi.p = port;
    QnapApi.dName = deviceName;
    QnapApi.mdl = model;
    QnapApi.fw = firmware;
    QnapApi.ser = serial;
  }

  private static formatUptime(days: number, hours: number, minutes: number): string {
    if (days <= 0 && hours <= 0 && minutes <= 0) {
      return '—';
    }
    return days + '天 ' + hours + '时 ' + minutes + '分';
  }
}

/** QNAP ID 归一化结果。 */
/** ID 登录的一个候选接入点：主机名 + 协议 + 端口。 */
export interface IdTarget {
  host: string;
  scheme: string;
  port: number;
}

/** docker create 响应。 */
