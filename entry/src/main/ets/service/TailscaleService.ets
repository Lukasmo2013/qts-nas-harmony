import { common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { LoginResult } from '../model/Models';
import { NasRepository } from './NasRepository';

/**
 * Tailscale 登录编排（UI 进程）。
 *
 * 只负责三件事：
 *   ① 拉起系统 VPN 扩展（首次由系统弹授权框，之后直接复用授权）；
 *   ② 读扩展写出的状态文件，拿到自身 IP / peers / 授权 URL；
 *   ③ 用 100.x 地址走现有 `NasRepository.login()`，完全复用 QTS 会话链路。
 *
 * 引擎实例只在 VPN 扩展进程里存在；这里绝不创建第二个引擎。
 */

const STATUS_FILE: string = 'tailscale-status.json';
const CONTROL_FILE: string = 'tailscale-control-url.txt';
const BUNDLE_NAME: string = 'com.wlt.qnap.nasmanager';
const ABILITY_NAME: string = 'TailscaleVpnExtensionAbility';

interface TsStatus {
  state: string;
  detail: string;
  authUrl: string;
  selfIp: string;
  peers: string;
  updatedAt: number;
}

interface TsPeer {
  name: string;
  address: string;
  online: boolean;
}

/** 匹配结果：唯一地址直接返回，多个候选由页面选择。 */
export interface NasCandidate {
  address: string;
  name: string;
}

/** 连接结果交给页面决定：需要授权时把 URL 交给页面展示。 */
export interface TsConnectState {
  state: string;
  authUrl: string;
  selfIp: string;
  /** 按 myserver/MyNAS 精确匹配的 NAS 候选（优先展示）。 */
  candidates: NasCandidate[];
  /** tailnet 里的全部在线节点（供用户手动挑选 / 填入地址）。 */
  peers: NasCandidate[];
  detail: string;
  /**
   * 扩展最后一次写状态的时间戳（毫秒）。
   * 0 表示状态文件还不存在。UI 必须用它做存活判断：
   * 扩展一旦被系统回收，文件就停在上一个快照（例如 needs_login），
   * 只看 state 会把"VPN 已死"误读成"还在等你登录"。
   */
  updatedAt: number;
}

function emptyState(s: string, detail: string): TsConnectState {
  const v: TsConnectState = {
    state: s, authUrl: '', selfIp: '', candidates: [], peers: [],
    detail: detail, updatedAt: 0
  };
  return v;
}

export class TailscaleService {
  /** 首次连接会触发系统 VPN 授权弹窗；之后系统记住授权，直接启动。 */
  static async start(context: common.UIAbilityContext): Promise<void> {
    const want: Want = {
      deviceId: '',
      bundleName: BUNDLE_NAME,
      abilityName: ABILITY_NAME
    };
    await vpnExtension.startVpnExtensionAbility(want);
  }

  /**
   * 重连前清掉上一轮的「失败」状态。
   * 否则扩展还没重新写状态时，页面会立刻读到旧的 failed 并把用户再次踢进失败态，
   * 重试事实上升效不了。
   *
   * 只在状态确实是错误态时才删除：若扩展本来就在运行（running），
   * 删掉状态文件会让 poll() 一直返回 starting，反而卡住流程。
   */
  static clearStaleFailure(context: common.UIAbilityContext): boolean {
    const st: TsStatus | null = TailscaleService.readStatus(context);
    if (st === null) {
      return false;
    }
    if (st.state !== 'failed' && st.state !== 'timeout' && st.state !== 'stopped') {
      return false;
    }
    try {
      const p: string = context.filesDir + '/' + STATUS_FILE;
      if (fileIo.accessSync(p)) {
        fileIo.unlinkSync(p);
        return true;
      }
    } catch (e) {
      // 删不掉也不影响：poll() 读到旧状态最多多一次轮询延迟
    }
    return false;
  }

  /**
   * 无条件删除状态文件。
   * 仅在「判定扩展已死」时用：此时文件里任何状态都不可信，
   * 留着会让页面在重连后继续读到旧快照。
   */
  static clearStatus(context: common.UIAbilityContext): void {
    try {
      const p: string = context.filesDir + '/' + STATUS_FILE;
      if (fileIo.accessSync(p)) {
        fileIo.unlinkSync(p);
      }
    } catch (e) {
      // 删不掉就只能靠 updatedAt 判断，不影响重连
    }
  }

  /** 可选：写入自定义 control server 地址（默认官方控制面）。 */
  static saveControlUrl(context: common.UIAbilityContext, url: string): void {
    try {
      const p: string = context.filesDir + '/' + CONTROL_FILE;
      const f: fileIo.File = fileIo.openSync(p,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(f.fd, url.trim());
      } finally {
        fileIo.closeSync(f);
      }
    } catch (e) {
      // 写失败就用默认控制面
    }
  }

  private static readStatus(context: common.UIAbilityContext): TsStatus | null {
    try {
      const p: string = context.filesDir + '/' + STATUS_FILE;
      if (!fileIo.accessSync(p)) {
        return null;
      }
      const f: fileIo.File = fileIo.openSync(p, fileIo.OpenMode.READ_ONLY);
      try {
        const buf: ArrayBuffer = new ArrayBuffer(65536);
        const n: number = fileIo.readSync(f.fd, buf);
        const bytes: Uint8Array = new Uint8Array(buf, 0, n);
        let text: string = '';
        for (let i: number = 0; i < bytes.length; i++) {
          text += String.fromCharCode(bytes[i]);
        }
        return JSON.parse(text) as TsStatus;
      } finally {
        fileIo.closeSync(f);
      }
    } catch (e) {
      return null;
    }
  }

  /**
   * 从 status_json 的 peers 里解析节点。
   * @param onlyNas 保留字段以兼容调用方；当前所有节点均可作为 NAS 候选。
   */
  private static parsePeers(peersText: string, onlyNas: boolean): NasCandidate[] {
    const out: NasCandidate[] = [];
    if (peersText.length === 0) {
      return out;
    }
    try {
      const parsed: Object = JSON.parse(peersText) as Object;
      const root: Object | undefined = (parsed as Record<string, Object>)['peers'];
      let list: Object[] = [];
      if (Array.isArray(parsed)) {
        list = parsed as Object[];
      } else if (root !== undefined && Array.isArray(root)) {
        list = root as Object[];
      }
      for (const item of list) {
        const obj: Record<string, Object> = item as Record<string, Object>;
        const rawName: Object | undefined = obj['name'];
        const rawName2: Object | undefined = obj['Name'];
        const rawName3: Object | undefined = obj['displayName'];
        let name: string = '';
        if (typeof rawName === 'string') {
          name = rawName as string;
        } else if (typeof rawName2 === 'string') {
          name = rawName2 as string;
        } else if (typeof rawName3 === 'string') {
          name = rawName3 as string;
        }
        const addr: string = TailscaleService.pickAddress(obj);
        if (addr.length === 0) {
          continue;
        }
        // 不再按写死的设备名过滤：任何 tailnet 节点都可能是用户的 NAS，
        // 全部展示后由用户自行选择（UI 侧会按地址去重）。
        const seen: boolean = out.some((c: NasCandidate) => c.address === addr);
        if (!seen) {
          const c: NasCandidate = { address: addr, name: name.length > 0 ? name : addr };
          out.push(c);
        }
      }
    } catch (e) {
      // peers JSON 结构变化时宁可返回空，也不猜 IP
    }
    return out;
  }

  /** 全部在线节点均可作为 NAS 候选，由用户选择。 */
  static parseCandidates(peersText: string): NasCandidate[] {
    return TailscaleService.parsePeers(peersText, true);
  }

  /** tailnet 里的全部节点（供用户手动挑选 NAS 地址）。 */
  static parseAllPeers(peersText: string): NasCandidate[] {
    return TailscaleService.parsePeers(peersText, false);
  }

  private static pickAddress(obj: Record<string, Object>): string {
    const keyNames: string[] = ['address', 'addresses', 'tailscaleIps', 'Addresses'];
    for (const k of keyNames) {
      const v: Object | undefined = obj[k];
      if (typeof v === 'string') {
        const s: string = v as string;
        if (TailscaleService.isTailnetIp(s)) {
          return s;
        }
      } else if (Array.isArray(v)) {
        const arr: Object[] = v as Object[];
        for (const one of arr) {
          if (typeof one === 'string') {
            const s: string = one as string;
            if (TailscaleService.isTailnetIp(s)) {
              return s;
            }
          }
        }
      }
    }
    return '';
  }

  private static isTailnetIp(s: string): boolean {
    return /^100\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(s);
  }

  /**
   * 等待 VPN 扩展就绪。页面每轮调一次；需要授权时返回 authUrl，
   * 页面展示授权 WebView，授权完成后再继续调用即可。
   */
  static poll(context: common.UIAbilityContext): TsConnectState {
    const st: TsStatus | null = TailscaleService.readStatus(context);
    if (st === null) {
      return emptyState('starting', 'vpn extension starting');
    }
    const result: TsConnectState = emptyState(st.state, st.detail);
    result.updatedAt = st.updatedAt !== undefined ? st.updatedAt : 0;
    if (st.state === 'failed' || st.state === 'timeout' || st.state === 'stopped') {
      return result;
    }
    result.authUrl = st.authUrl;
    result.selfIp = st.selfIp;
    result.candidates = TailscaleService.parseCandidates(st.peers);
    result.peers = TailscaleService.parseAllPeers(st.peers);
    return result;
  }

  /** 按 100.x:5000 / :5001 探测并登录，成功即返回可直接保存的会话。 */
  static async login(address: string, user: string, password: string): Promise<LoginResult> {
    const ports: number[] = [5000, 5001];
    const schemes: string[] = ['http', 'https'];
    let last: LoginResult = {
      success: false, errorKey: 'login.fail.network', session: null
    };
    for (let i: number = 0; i < ports.length; i++) {
      const r: LoginResult = await NasRepository.login(address, ports[i], user, password, schemes[i]);
      if (r.success) {
        return r;
      }
      last = r;
    }
    return last;
  }
}
