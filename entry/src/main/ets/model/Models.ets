/**
 * 业务数据契约。全部使用静态类型的 interface，符合 ArkTS 静态类型约束；
 * 数据来源为本地模拟仓库，替换成真实 QNAP API 时只需替换 service 层实现。
 */

export interface DeviceSession {
  /** 登录方式：localIp（IP 直连）/ qnapId（QNAP ID 域名接入）。 */
  mode: string;
  account: string;
  host: string;
  port: number;
  deviceName: string;
  model: string;
  firmware: string;
  serial: string;
  loginAt: number;
  /* ---- 会话恢复所需的真实凭证 ----
   * sid 与 cookie 是 QTS 的实际会话凭证；缺少它们的持久化会导致
   * 冷启动后所有请求被设备判为未认证，表现为「页面空白 / 数据全 0」。
   * scheme 记录 http / https，ID 模式通过 myQNAPcloud 域名时必须走 https。 */
  sid: string;
  scheme: string;
  password: string;
  /**
   * CloudLink 中继会话 Cookie（走 `d2.myqnapcloud.cn` 这类中继时必须带上）。
   *
   * 实测：中继按 `qcloud_tunnel_sid` / `qcloud_tunnel_agent_id` / `cloudRelayMode`
   * 这组 Cookie 路由到设备，缺了它们请求会被打成门户页；配合查询串里的 `sid=`
   * 就能返回真实的 QTS 数据。没有端口映射时，这是唯一可用的外网通路。
   */
  relayCookie?: string;
}

export interface DeviceOverview {
  deviceName: string;
  model: string;
  firmware: string;
  serial: string;
  uptime: string;
  cpu: number;
  memory: number;
  memoryUsedGB: number;
  memoryTotalGB: number;
  cpuTemp: number;
  sysTemp: number;
  fanRpm: number;
  uploadMbps: number;
  downloadMbps: number;
  storageUsedTB: number;
  storageTotalTB: number;
  /** 设备报告的卷名（如 DataVol1）；为空表示设备未提供。 */
  storageVolumeName: string;
  /** 设备报告的可用空间（GB）；为 0 表示设备未提供。 */
  storageFreeGB: number;
  /** 设备报告的以太网口数量；为 0 表示设备未提供。 */
  ethernetCount: number;
  volumeCount: number;
  diskCount: number;
  containerCount: number;
  serviceRunning: number;
  health: string;
}

export interface FileItem {
  id: string;
  name: string;
  kind: string;
  size: number;
  modified: number;
  owner: string;
  permission: string;
  childCount: number;
}

/**
 * 文件列表的完整结果：条目 + 目录状态。
 * status 语义（来自 File Station 6 的 status 字段）：
 *   0  正常返回（valid = true，total 为目录内条目总数，可能为 0 即空目录）
 *   5  路径不存在或无访问权限（valid = false）
 *   20 参数非法（valid = false）
 *   3  会话失效（valid = false）
 *  -1  网络不可达 / 响应为空
 *  -2  响应解析失败
 */
export interface FileListResult {
  items: FileItem[];
  total: number;
  status: number;
  valid: boolean;
}

export interface StoragePool {
  id: string;
  name: string;
  raid: string;
  usedTB: number;
  totalTB: number;
  percent: number;
  status: string;
  volumeCount: number;
}

export interface VolumeInfo {
  id: string;
  name: string;
  pool: string;
  usedTB: number;
  totalTB: number;
  percent: number;
  status: string;
  encrypted: boolean;
  snapshots: number;
  /** 设备报告的可用空间（GB）；为 0 表示设备未提供。 */
  freeGB: number;
  /** 设备报告的总容量（GB）；为 0 表示设备未提供。 */
  totalGB: number;
  /** 卷内磁盘数量。 */
  diskCount: number;
  /** 设备上报的分区 / 磁盘标识（如 3.5" SATA HDD 1）。 */
  partitions: string[];
  /** 设备上报的交换空间总量（GB）。 */
  swapTotalGB: number;
}

export interface DiskInfo {
  id: string;
  slot: string;
  model: string;
  serial: string;
  capacityTB: number;
  bus: string;
  temp: number;
  smart: string;
  health: string;
  rpm: number;
  /** 分区 / 磁盘类型说明（如 3.5" SATA HDD 1）。 */
  partition: string;
}

export interface ServiceInfo {
  id: string;
  name: string;
  description: string;
  protocol: string;
  port: string;
  running: boolean;
}

/** 容器端口映射（Container Station `portBindings` 原始字段）。 */
export interface ContainerPort {
  /** 宿主机端口：App 通过该端口访问容器里的 Web 应用。 */
  host: number;
  /** 容器内端口，仅用于展示。 */
  container: number;
  /** TCP / UDP，仅用于展示；Web 访问一律走 http/https。 */
  protocol: string;
  /** 绑定地址（设备可能不上报）。 */
  hostIP: string;
}

export interface ContainerInfo {
  /**
   * CS 5 的完整 64 位容器 ID。启停 / 删除 API 必须用它，
   * 早期版本把它截成 12 位，导致请求被受理却找不到目标容器。
   */
  id: string;
  /** 仅用于界面展示的短 ID（完整 ID 的前 12 位）。 */
  shortId: string;
  /** 容器类型（CS 5 的 type 字段，通常为 docker），启停请求体里的 ctype。 */
  ctype: string;
  name: string;
  image: string;
  status: string;
  /** CPU 占用（CS 上报的原始数值，未确认单位语义，界面不展示）。 */
  cpu: number;
  memoryMB: number;
  memoryLimitMB: number;
  /** 已格式化的端口映射，如 `9527:9527`。 */
  ports: string;
  /** 结构化端口映射，供「打开容器 Web 应用」直接拼 URL。 */
  portBindings: ContainerPort[];
  /** 所属应用 / 项目名（CS 5 的 project 字段，可为空）。 */
  project: string;
  /** 容器启动时间（ISO 字符串，原始值）。 */
  startedAt: string;
  /** 启动时间的毫秒时间戳；0 表示设备未上报或无法解析。 */
  startedMs: number;
}

/**
 * 容器列表结果：把「Container Station 未安装」与「已安装但无容器」区分开。
 * installed = false 时页面渲染「未安装」说明，而不是含糊的「暂无数据」。
 */
export interface ContainerListResult {
  items: ContainerInfo[];
  installed: boolean;
  status: number;
}

/** 写操作结果：status 为 QTS 返回的原始状态码（1 = 成功）。 */
export interface OpResult {
  ok: boolean;
  status: number;
}

/** 文件下载结果：data 为下载到的原始字节（ArrayBuffer），name 为建议保存的文件名。 */
export interface DownloadResult {
  ok: boolean;
  status: number;
  data: ArrayBuffer | null;
  name: string;
}

/** 容器日志：lines 为真实日志行，available = false 表示接口不可用。 */
export interface ContainerLogs {
  lines: string[];
  available: boolean;
}

export interface ImageInfo {
  /** 12 位短 ID，仅用于展示。 */
  id: string;
  /** CS 5 返回的完整镜像 ID（含 sha256:），删除必须使用它。 */
  fullId: string;
  /** 镜像类型（docker / lxd），删除接口需要。 */
  type: string;
  name: string;
  tag: string;
  sizeMB: number;
  created: number;
  /** 设备上报的「已被容器使用」标记，true 时禁止删除。 */
  inUse: boolean;
  containerCount: number;
}

export interface EventItem {
  id: string;
  title: string;
  time: number;
  level: string;
  detail: string;
}

export interface LoginResult {
  success: boolean;
  errorKey: string;
  session: DeviceSession | null;
  /** 失败时记录实际尝试过的 主机:端口，便于用户判断是名称错了还是端口没开。 */
  tried?: string;
}

/** 存储页聚合数据：存储池 / 卷 / 硬盘。 */
export interface StorageBundle {
  pools: StoragePool[];
  volumes: VolumeInfo[];
  disks: DiskInfo[];
}

export interface MetricItem {
  key: string;
  icon: string;
  labelKey: string;
  value: string;
  percent: number;
  color: string;
}
