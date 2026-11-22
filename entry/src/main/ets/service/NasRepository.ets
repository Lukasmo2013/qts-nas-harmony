/**
 * 统一数据访问层。页面只消费三样东西：数据、LoadState、Toast 文案。
 * 全部数据来自真实 QNAP 设备（QnapApi）；
 * 接口未授权或不支持时返回空集合 / available=false，由页面渲染真实空态。
 *
 * 审核预览模式：仅在 DemoMode 开启时，读方法返回内置示例数据，写方法返回占位成功；
 * 真实登录与所有 QnapApi 调用路径保持不变，退出登录后立即恢复真实行为。
 */
import {
  DeviceOverview, LoginResult, FileListResult, ServiceInfo,
  ContainerInfo, ContainerListResult, ContainerLogs, ImageInfo, EventItem, StorageBundle, OpResult,
  DownloadResult
} from '../model/Models';
import { QnapApi } from './QnapApi';
import { DemoMode } from '../common/demo/DemoMode';

export class NasRepository {
  /* ---- 登录（真实链路，预览模式不走这里） ---- */

  /** IP 直连登录。 */
  static async login(host: string, port: number, user: string, password: string,
                     scheme: string = 'http'): Promise<LoginResult> {
    return await QnapApi.login(host, port, user, password, scheme);
  }

  /** 用网页验证拿到的 CloudLink 中继会话直接建会话（无端口映射时的外网通路）。 */
  static async adoptRelay(host: string, sid: string, cookie: string, account: string,
                          password: string): Promise<LoginResult> {
    return await QnapApi.adoptRelay(host, sid, cookie, account, password);
  }

  /** 通过 CloudLink 中继做 QTS 登录（只需要中继路由 Cookie，不需要 NAS_SID）。 */
  static async loginViaRelay(host: string, cookie: string, account: string,
                             password: string): Promise<LoginResult> {
    return await QnapApi.loginViaRelay(host, cookie, account, password);
  }

  /**
   * 云 API 直取通道：用 myQNAPcloud 云端接口返回的 tunnel_agent_id 直连中继，
   * 原生完成「取路由 Cookie → authLogin」，完全绕开 SmartURL 的 JS 选路页。
   */
  static async loginViaTunnel(relayHost: string, tunnelAgentId: string,
                              account: string, password: string): Promise<LoginResult> {
    return await QnapApi.loginViaTunnel(relayHost, tunnelAgentId, account, password);
  }

  /**
   * 中继会话是否已被服务端判过期（请求被打回门户页）。
   * 页面据此区分「还没登录」和「登录过了但中继到期，需要重新验证」。
   */
  static relayExpired(): boolean {
    return QnapApi.relayExpired();
  }

  /** 保存 / 读取用户配置的外网接入点（路由器端口映射后的公网地址）。 */
  static setWanEndpoint(text: string): void {
    QnapApi.setWanEndpoint(text);
  }

  static wanEndpoint(): string {
    return QnapApi.wanEndpoint();
  }

  /* ---- 设备状态 ---- */

  static async overview(): Promise<DeviceOverview> {
    if (DemoMode.isActive()) {
      return DemoMode.overview();
    }
    return await QnapApi.overview();
  }

  /* ---- 文件 ---- */

  /** 文件列表：条目 + 目录状态（空目录 / 路径不存在 / 请求失败可区分）。 */
  static async files(path: string): Promise<FileListResult> {
    if (DemoMode.isActive()) {
      return DemoMode.files(path);
    }
    return await QnapApi.files(path);
  }

  /** 共享目录列表：文件浏览的入口，来自设备真实的 privRequest 共享名单。 */
  static async shares(): Promise<string[]> {
    if (DemoMode.isActive()) {
      return DemoMode.shares();
    }
    return await QnapApi.shares();
  }

  /** 清空共享 / 可写缓存：下拉刷新与重新进页时调用，保证新增共享能立刻出现。 */
  static resetShareCache(): void {
    QnapApi.resetShareCache();
  }

  /** 可写共享目录（探测得到，已缓存）：用于挑选默认落地目录与上传前提示。 */
  static async writableRoots(): Promise<string[]> {
    if (DemoMode.isActive()) {
      return DemoMode.writableRoots();
    }
    return await QnapApi.writableRoots();
  }

  /** 首选落地共享（第一个可写共享，退回第一个共享）。 */
  static async preferredRoot(): Promise<string> {
    if (DemoMode.isActive()) {
      return DemoMode.preferredRoot();
    }
    return await QnapApi.preferredRoot();
  }

  /** 逐级创建目录（mkdir -p），已存在也算成功。 */
  static async ensureFolder(path: string): Promise<boolean> {
    if (DemoMode.isActive()) {
      return true;
    }
    return await QnapApi.ensureFolder(path);
  }

  /** 新建目录。 */
  static async mkdir(parentPath: string, folderName: string): Promise<OpResult> {
    if (DemoMode.isActive()) {
      return DemoMode.ok();
    }
    return await QnapApi.mkdir(parentPath, folderName);
  }

  /** 重命名。 */
  static async renameParent(parentPath: string, sourceName: string, destName: string): Promise<OpResult> {
    if (DemoMode.isActive()) {
      return DemoMode.ok();
    }
    return await QnapApi.renameItem(parentPath, sourceName, destName);
  }

  /** 删除（默认移入回收站）。 */
  static async remove(parentPath: string, names: string[], recycle: boolean = true): Promise<OpResult> {
    if (DemoMode.isActive()) {
      return DemoMode.ok();
    }
    return await QnapApi.removeItems(parentPath, names, recycle);
  }

  /** 上传文件（File Station 6 两段式分片，支持进度与取消）。 */
  static async uploadFile(destPath: string, fileName: string, data: Uint8Array,
                          overwrite: boolean = true,
                          onProgress?: (done: number, total: number) => void,
                          shouldStop?: () => boolean): Promise<OpResult> {
    if (DemoMode.isActive()) {
      return DemoMode.ok();
    }
    return await QnapApi.uploadFile(destPath, fileName, data, overwrite, onProgress, shouldStop);
  }

  /** 下载文件（File Station 6 `func=download`，取回原始字节）。 */
  static async downloadFile(sourcePath: string): Promise<DownloadResult> {
    if (DemoMode.isActive()) {
      return DemoMode.download();
    }
    return await QnapApi.downloadFile(sourcePath);
  }

  /* ---- 存储 / 服务 / 日志 ---- */

  static async storage(): Promise<StorageBundle> {
    if (DemoMode.isActive()) {
      return DemoMode.storage();
    }
    return await QnapApi.storage();
  }

  static async events(): Promise<EventItem[]> {
    if (DemoMode.isActive()) {
      return DemoMode.events();
    }
    return await QnapApi.events();
  }

  static async services(): Promise<ServiceInfo[]> {
    if (DemoMode.isActive()) {
      return DemoMode.services();
    }
    return await QnapApi.services();
  }

  /* ---- 容器 ---- */

  /** 容器列表 + Container Station 安装状态。 */
  static async containersResult(): Promise<ContainerListResult> {
    if (DemoMode.isActive()) {
      return DemoMode.containersResult();
    }
    return await QnapApi.containersResult();
  }

  static async containers(): Promise<ContainerInfo[]> {
    if (DemoMode.isActive()) {
      return DemoMode.containers();
    }
    return await QnapApi.containers();
  }

  static async images(): Promise<ImageInfo[]> {
    if (DemoMode.isActive()) {
      return DemoMode.images();
    }
    return await QnapApi.images();
  }

  /** ctype 来自 CS 5 列表的 type 字段，启停请求体需要它。 */
  static async containerAction(containerId: string, action: string,
                               ctype: string = 'docker'): Promise<OpResult> {
    if (DemoMode.isActive()) {
      return DemoMode.ok();
    }
    return await QnapApi.containerAction(containerId, action, ctype);
  }

  static async removeContainer(containerId: string, force: boolean): Promise<OpResult> {
    if (DemoMode.isActive()) {
      return DemoMode.ok();
    }
    return await QnapApi.removeContainer(containerId, force);
  }

  static async removeImage(image: ImageInfo): Promise<OpResult> {
    if (DemoMode.isActive()) {
      return DemoMode.ok();
    }
    return await QnapApi.removeImage(image);
  }

  static async createContainer(image: string, name: string, hostPort: string): Promise<OpResult> {
    if (DemoMode.isActive()) {
      return DemoMode.ok();
    }
    return await QnapApi.createContainer(image, name, hostPort);
  }

  static async pullImage(image: string): Promise<OpResult> {
    if (DemoMode.isActive()) {
      return DemoMode.ok();
    }
    return await QnapApi.pullImage(image);
  }

  static async containerLogs(containerId: string): Promise<ContainerLogs> {
    if (DemoMode.isActive()) {
      return DemoMode.containerLogs(containerId);
    }
    return await QnapApi.containerLogs(containerId);
  }

  /* ---- 文案辅助 ---- */

  static eventTitle(id: string, lang: string): string {
    return id;
  }

  /** 服务副标题：优先展示设备上报的访问路径，缺失时回退为服务标识。 */
  static serviceDescription(id: string, description: string, lang: string): string {
    return description.length > 0 ? description : id;
  }
}
