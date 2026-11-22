import { AppConstants } from '../constants/AppConstants';
import {
  DeviceSession, DeviceOverview, FileListResult, FileItem, StorageBundle,
  VolumeInfo, DiskInfo, ServiceInfo, EventItem, ContainerListResult, ContainerInfo,
  ContainerPort, ImageInfo, ContainerLogs, OpResult, DownloadResult
} from '../../model/Models';

/**
 * 审核预览模式。
 *
 * 设计边界（必须保持）：
 * 1. 只在用户主动点登录页「审核预览」后开启，属于独立入口，不影响任何真实登录方式；
 * 2. 数据全部是内置示例，只在 NasRepository 层返回，QnapApi 与真实网络链路一行不改；
 * 3. 所有写操作在预览模式下直接返回成功占位，不向任何设备发请求；
 * 4. 退出登录会清掉预览标记，绝不把演示会话带到真实账号上。
 */
export class DemoMode {
  static readonly STORAGE_KEY: string = 'demoMode';
  /** 固定的示例时间戳，避免每次刷新列表时间跳动。 */
  private static readonly T0: number = 1793000000000;

  static isActive(): boolean {
    return AppStorage.get<boolean>(DemoMode.STORAGE_KEY) === true;
  }

  static enter(): void {
    AppStorage.setOrCreate<boolean>(DemoMode.STORAGE_KEY, true);
  }

  static exit(): void {
    AppStorage.setOrCreate<boolean>(DemoMode.STORAGE_KEY, false);
  }

  /** 演示会话：字段齐全，能通过 SessionManager 的校验，但不会发任何请求。 */
  static session(): DeviceSession {
    const result: DeviceSession = {
      mode: AppConstants.LOGIN_MODE_IP,
      account: 'demo-user',
      host: '192.0.2.10',
      port: 5000,
      deviceName: 'QNAP-DEMO',
      model: 'TS-464-8G',
      firmware: '5.1.7.0000',
      serial: 'DEMO-2026-0001',
      loginAt: Date.now(),
      sid: 'demo-session',
      scheme: 'http',
      password: '',
      relayCookie: ''
    };
    return result;
  }

  /* ---- 写操作占位：不触网，返回成功以免审核界面误以为功能损坏 ---- */

  static ok(): OpResult {
    return { ok: true, status: 1 };
  }

  static download(): DownloadResult {
    return { ok: true, status: 1, data: new ArrayBuffer(0), name: 'preview.txt' };
  }

  /* ---- 设备概览 ---- */

  static overview(): DeviceOverview {
    const result: DeviceOverview = {
      deviceName: 'QNAP-DEMO',
      model: 'TS-464-8G',
      firmware: '5.1.7.0000',
      serial: 'DEMO-2026-0001',
      uptime: '32 天 6 小时',
      cpu: 23,
      memory: 46,
      memoryUsedGB: 3.7,
      memoryTotalGB: 8,
      cpuTemp: 43,
      sysTemp: 38,
      fanRpm: 1240,
      uploadMbps: 2.4,
      downloadMbps: 18.6,
      storageUsedTB: 4.2,
      storageTotalTB: 8,
      storageVolumeName: 'DataVol1',
      storageFreeGB: 3210,
      ethernetCount: 2,
      volumeCount: 2,
      diskCount: 2,
      containerCount: 3,
      serviceRunning: 6,
      health: 'good'
    };
    return result;
  }

  static events(): EventItem[] {
    const result: EventItem[] = [
      { id: 'sys-1', title: '系统更新完成', time: DemoMode.T0 - 3600000, level: 'info', detail: 'QTS 5.1.7.0000 更新已安装' },
      { id: 'disk-1', title: '硬盘健康检查通过', time: DemoMode.T0 - 86400000, level: 'success', detail: 'Disk 1 / Disk 2 SMART 状态正常' },
      { id: 'backup-1', title: '自动备份完成', time: DemoMode.T0 - 172800000, level: 'success', detail: '已同步 24 个文件到 NAS' },
      { id: 'docker-1', title: '容器已启动', time: DemoMode.T0 - 259200000, level: 'info', detail: 'home-assistant 已正常运行' }
    ];
    return result;
  }

  /* ---- 文件 ---- */

  static shares(): string[] {
    return ['Public', 'Home', 'Download', 'Multimedia', 'Container', 'demo-user'];
  }

  static writableRoots(): string[] {
    return ['Home', 'Public'];
  }

  static preferredRoot(): string {
    return 'Home';
  }

  static files(path: string): FileListResult {
    const items: FileItem[] = DemoMode.fileItems(path);
    const result: FileListResult = { items: items, total: items.length, status: 0, valid: true };
    return result;
  }

  private static fileItems(path: string): FileItem[] {
    const stamp: number = DemoMode.T0;
    if (path.indexOf('Download') >= 0) {
      return [
        { id: 'd1', name: 'SetupGuide.pdf', kind: 'file', size: 2481024, modified: stamp - 7200000, owner: 'demo-user', permission: '777', childCount: 0 },
        { id: 'd2', name: 'release-notes.txt', kind: 'file', size: 2048, modified: stamp - 86400000, owner: 'demo-user', permission: '777', childCount: 0 }
      ];
    }
    if (path.indexOf('Multimedia') >= 0) {
      return [
        { id: 'm1', name: 'Photos', kind: 'folder', size: 0, modified: stamp - 86400000, owner: 'demo-user', permission: '777', childCount: 36 },
        { id: 'm2', name: 'Camera', kind: 'folder', size: 0, modified: stamp - 172800000, owner: 'demo-user', permission: '777', childCount: 128 },
        { id: 'm3', name: 'sample.jpg', kind: 'file', size: 1835008, modified: stamp - 3600000, owner: 'demo-user', permission: '777', childCount: 0 }
      ];
    }
    if (path.indexOf('Container') >= 0) {
      return [
        { id: 'c1', name: 'docker', kind: 'folder', size: 0, modified: stamp - 86400000, owner: 'demo-user', permission: '777', childCount: 3 },
        { id: 'c2', name: 'compose.yaml', kind: 'file', size: 1536, modified: stamp - 172800000, owner: 'demo-user', permission: '777', childCount: 0 }
      ];
    }
    if (path.indexOf('Photos') >= 0 || path.indexOf('Camera') >= 0) {
      return [
        { id: 'p1', name: 'IMG_20261120.jpg', kind: 'file', size: 2411724, modified: stamp - 3600000, owner: 'demo-user', permission: '777', childCount: 0 },
        { id: 'p2', name: 'IMG_20261119.jpg', kind: 'file', size: 2097152, modified: stamp - 86400000, owner: 'demo-user', permission: '777', childCount: 0 }
      ];
    }
    if (path.indexOf('Home') >= 0 || path.indexOf('demo-user') >= 0) {
      return [
        { id: 'h1', name: 'Documents', kind: 'folder', size: 0, modified: stamp - 7200000, owner: 'demo-user', permission: '777', childCount: 12 },
        { id: 'h2', name: 'Music', kind: 'folder', size: 0, modified: stamp - 86400000, owner: 'demo-user', permission: '777', childCount: 48 },
        { id: 'h3', name: 'PhoneBackup', kind: 'folder', size: 0, modified: stamp - 172800000, owner: 'demo-user', permission: '777', childCount: 24 },
        { id: 'h4', name: 'README.txt', kind: 'file', size: 4096, modified: stamp - 259200000, owner: 'demo-user', permission: '777', childCount: 0 }
      ];
    }
    return [
      { id: 'pub1', name: 'Music', kind: 'folder', size: 0, modified: stamp - 7200000, owner: 'demo-user', permission: '777', childCount: 48 },
      { id: 'pub2', name: 'Photos', kind: 'folder', size: 0, modified: stamp - 86400000, owner: 'demo-user', permission: '777', childCount: 36 },
      { id: 'pub3', name: 'Shared', kind: 'folder', size: 0, modified: stamp - 172800000, owner: 'demo-user', permission: '777', childCount: 8 },
      { id: 'pub4', name: 'welcome.txt', kind: 'file', size: 1024, modified: stamp - 259200000, owner: 'demo-user', permission: '777', childCount: 0 }
    ];
  }

  /* ---- 存储 / 服务 ---- */

  static storage(): StorageBundle {
    const volumes: VolumeInfo[] = [
      { id: 'v1', name: 'DataVol1', pool: 'Storage Pool 1', usedTB: 3.1, totalTB: 6, percent: 52, status: 'Ready', encrypted: false, snapshots: 12, freeGB: 2970, totalGB: 6144, diskCount: 2, partitions: ['3.5" SATA HDD 1', '3.5" SATA HDD 2'], swapTotalGB: 8 },
      { id: 'v2', name: 'DataVol2', pool: 'Storage Pool 1', usedTB: 1.1, totalTB: 2, percent: 55, status: 'Ready', encrypted: true, snapshots: 4, freeGB: 920, totalGB: 2048, diskCount: 2, partitions: ['3.5" SATA HDD 1', '3.5" SATA HDD 2'], swapTotalGB: 4 }
    ];
    const disks: DiskInfo[] = [
      { id: 'disk1', slot: '1', model: 'WD Red Plus WD40EFPX', serial: 'DEMO-DISK-01', capacityTB: 4, bus: 'SATA', temp: 34, smart: 'PASS', health: 'Good', rpm: 5400, partition: '3.5" SATA HDD 1' },
      { id: 'disk2', slot: '2', model: 'WD Red Plus WD40EFPX', serial: 'DEMO-DISK-02', capacityTB: 4, bus: 'SATA', temp: 36, smart: 'PASS', health: 'Good', rpm: 5400, partition: '3.5" SATA HDD 2' }
    ];
    const result: StorageBundle = { pools: [], volumes: volumes, disks: disks };
    return result;
  }

  static services(): ServiceInfo[] {
    const result: ServiceInfo[] = [
      { id: 'smb', name: 'Microsoft Networking', description: 'SMB/CIFS 文件共享', protocol: 'TCP', port: '445', running: true },
      { id: 'afp', name: 'Apple Filing Protocol', description: 'macOS 文件共享', protocol: 'TCP', port: '548', running: true },
      { id: 'ftp', name: 'FTP', description: '文件传输服务', protocol: 'TCP', port: '21', running: true },
      { id: 'ssh', name: 'SSH', description: '安全远程登录', protocol: 'TCP', port: '22', running: true },
      { id: 'web', name: 'Web Server', description: 'HTTP 服务', protocol: 'TCP', port: '80', running: true },
      { id: 'mysql', name: 'MySQL', description: '数据库服务', protocol: 'TCP', port: '3306', running: false }
    ];
    return result;
  }

  /* ---- 容器与镜像 ---- */

  static containersResult(): ContainerListResult {
    const p1: ContainerPort[] = [{ host: 8080, container: 80, protocol: 'TCP', hostIP: '' }];
    const p2: ContainerPort[] = [{ host: 8123, container: 8123, protocol: 'TCP', hostIP: '' }];
    const p3: ContainerPort[] = [{ host: 9000, container: 9000, protocol: 'TCP', hostIP: '' }];
    const items: ContainerInfo[] = [
      { id: 'demo0000000000000000000000000001', shortId: 'demo00000000', ctype: 'docker', name: 'nginx-web', image: 'nginx:latest', status: 'running', cpu: 2, memoryMB: 86, memoryLimitMB: 512, ports: '8080:80', portBindings: p1, project: 'web', startedAt: '2026-11-20T08:12:00Z', startedMs: DemoMode.T0 - 86400000 },
      { id: 'demo0000000000000000000000000002', shortId: 'demo00000001', ctype: 'docker', name: 'home-assistant', image: 'ghcr.io/home-assistant:stable', status: 'running', cpu: 6, memoryMB: 248, memoryLimitMB: 1024, ports: '8123:8123', portBindings: p2, project: 'smart-home', startedAt: '2026-11-18T10:30:00Z', startedMs: DemoMode.T0 - 172800000 },
      { id: 'demo0000000000000000000000000003', shortId: 'demo00000002', ctype: 'docker', name: 'portainer', image: 'portainer/portainer-ce', status: 'stopped', cpu: 0, memoryMB: 0, memoryLimitMB: 512, ports: '9000:9000', portBindings: p3, project: 'tools', startedAt: '2026-11-10T09:00:00Z', startedMs: DemoMode.T0 - 604800000 }
    ];
    const result: ContainerListResult = { items: items, installed: true, status: 0 };
    return result;
  }

  static containers(): ContainerInfo[] {
    return DemoMode.containersResult().items;
  }

  static images(): ImageInfo[] {
    const result: ImageInfo[] = [
      { id: 'img0000001a', fullId: 'sha256:demoimage0000000000000000000000000000000000000000000000000000001', type: 'docker', name: 'nginx', tag: 'latest', sizeMB: 142, created: DemoMode.T0 - 86400000, inUse: true, containerCount: 1 },
      { id: 'img0000002b', fullId: 'sha256:demoimage0000000000000000000000000000000000000000000000000000002', type: 'docker', name: 'home-assistant', tag: 'stable', sizeMB: 386, created: DemoMode.T0 - 172800000, inUse: true, containerCount: 1 },
      { id: 'img0000003c', fullId: 'sha256:demoimage0000000000000000000000000000000000000000000000000000003', type: 'docker', name: 'portainer/portainer-ce', tag: 'latest', sizeMB: 208, created: DemoMode.T0 - 604800000, inUse: true, containerCount: 1 },
      { id: 'img0000004d', fullId: 'sha256:demoimage0000000000000000000000000000000000000000000000000000004', type: 'docker', name: 'alpine', tag: '3.20', sizeMB: 8, created: DemoMode.T0 - 1209600000, inUse: false, containerCount: 0 }
    ];
    return result;
  }

  static containerLogs(containerId: string): ContainerLogs {
    const result: ContainerLogs = {
      lines: [
        '2026-11-22 08:00:01  [demo] container ' + containerId + ' ready',
        '2026-11-22 08:00:02  [demo] listening on port 8080',
        '2026-11-22 08:01:14  [demo] health check passed'
      ],
      available: true
    };
    return result;
  }
}
