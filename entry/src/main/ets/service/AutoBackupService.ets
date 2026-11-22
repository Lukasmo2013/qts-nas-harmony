import fileShare from '@ohos.fileshare';
import fileUri from '@ohos.file.fileuri';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import { t } from '../common/i18n/I18n';
import { FileNameUtil } from '../common/utils/FileNameUtil';
import { NasRepository } from './NasRepository';
import { TransferManager } from './TransferManager';
import { DemoMode } from '../common/demo/DemoMode';

const AUTO_BACKUP_CONFIG_KEY: string = 'autoBackupConfig';
/** 去重索引上限：防止长期备份后配置无限膨胀。 */
const MAX_SYNCED_KEYS: number = 5000;

/** 自动备份配置（整体以 JSON 存 AppStorage，并由 PersistentStorage 落盘）。 */
export interface AutoBackupConfig {
  enabled: boolean;
  /** 手机文件夹 URI；为空表示未配置。 */
  phoneUri: string;
  /** 手机文件夹显示名。 */
  phoneName: string;
  /** NAS 目标文件夹绝对路径。 */
  nasPath: string;
  /** 是否已成功申请目录授权持久化。 */
  persisted: boolean;
  /** 上次扫描时间（毫秒），0 表示从未执行。 */
  lastRunAt: number;
  /** 上次扫描新入队的文件数。 */
  lastQueued: number;
  /** 上次错误文案 key，空串表示正常。 */
  lastError: string;
  /** 已入队文件的去重键：名称|大小|修改时间。 */
  syncedKeys: string[];
}

/** 手机文件夹选择结果。 */
export interface AutoBackupPickResult {
  ok: boolean;
  uri: string;
  name: string;
  persisted: boolean;
  /** 非致命提示：例如系统不支持授权持久化，本次仍可备份。 */
  errorKey: string;
}

/** 一次自动备份扫描的结果。 */
export interface AutoBackupResult {
  queued: number;
  errorKey: string;
}

/** 手机目录里的一个待备份文件。 */
interface AutoBackupSourceFile {
  path: string;
  relative: string;
  name: string;
  size: number;
  mtime: number;
}

/**
 * 自动备份服务。
 *
 * 设计边界（必须在 UI 上如实表达）：
 * 1) 目录选择来自系统 Picker，拿到的是临时授权；若设备支持且用户允许，
 *    通过 fileShare.persistPermission 持久化，冷启动再 activatePermission 恢复；
 * 2) 不支持持久化授权的设备/场景，配置仍可保存，但重启后需重新选择手机文件夹；
 * 3) 自动备份在 App 前台启动与用户点「立即备份」时执行增量扫描：
 *    只把未入队过的新文件交给既有 TransferManager，不重复造上传链路；
 * 4) NAS 目标目录必须真实存在且可写，否则不保存成功状态。
 */
export class AutoBackupService {
  private static running: boolean = false;

  static defaultConfig(): AutoBackupConfig {
    const config: AutoBackupConfig = {
      enabled: false,
      phoneUri: '',
      phoneName: '',
      nasPath: '',
      persisted: false,
      lastRunAt: 0,
      lastQueued: 0,
      lastError: '',
      syncedKeys: []
    };
    return config;
  }

  static load(): AutoBackupConfig {
    const raw: string | undefined = AppStorage.get<string>(AUTO_BACKUP_CONFIG_KEY);
    if (raw === undefined || raw.length === 0) {
      return AutoBackupService.defaultConfig();
    }
    try {
      const parsed: AutoBackupConfig = JSON.parse(raw) as AutoBackupConfig;
      const fallback: AutoBackupConfig = AutoBackupService.defaultConfig();
      const config: AutoBackupConfig = {
        enabled: parsed.enabled === true,
        phoneUri: parsed.phoneUri !== undefined ? parsed.phoneUri : fallback.phoneUri,
        phoneName: parsed.phoneName !== undefined ? parsed.phoneName : fallback.phoneName,
        nasPath: parsed.nasPath !== undefined ? parsed.nasPath : fallback.nasPath,
        persisted: parsed.persisted === true,
        lastRunAt: parsed.lastRunAt !== undefined ? parsed.lastRunAt : fallback.lastRunAt,
        lastQueued: parsed.lastQueued !== undefined ? parsed.lastQueued : fallback.lastQueued,
        lastError: parsed.lastError !== undefined ? parsed.lastError : fallback.lastError,
        syncedKeys: parsed.syncedKeys !== undefined ? parsed.syncedKeys : fallback.syncedKeys
      };
      return config;
    } catch (e) {
      return AutoBackupService.defaultConfig();
    }
  }

  static save(config: AutoBackupConfig): void {
    AppStorage.setOrCreate<string>(AUTO_BACKUP_CONFIG_KEY, JSON.stringify(config));
  }

  static clear(): void {
    AppStorage.setOrCreate<string>(AUTO_BACKUP_CONFIG_KEY, '');
  }

  /** 开启前必须同时配好两端文件夹，避免出现「已开启但无法备份」。 */
  static setEnabled(enabled: boolean): string {
    const config: AutoBackupConfig = AutoBackupService.load();
    if (enabled && (config.phoneUri.length === 0 || config.nasPath.length === 0)) {
      return 'gallery.auto.needFolders';
    }
    config.enabled = enabled;
    config.lastError = '';
    AutoBackupService.save(config);
    return '';
  }

  /** 保存自动备份文件夹配置；NAS 路径由调用方先验证可写。 */
  static saveFolders(phoneUri: string, phoneName: string, nasPath: string, persisted: boolean): void {
    const config: AutoBackupConfig = AutoBackupService.load();
    config.phoneUri = phoneUri;
    config.phoneName = phoneName;
    config.nasPath = nasPath;
    config.persisted = persisted;
    config.lastError = '';
    AutoBackupService.save(config);
  }

  /**
   * 选择手机文件夹。
   *
   * 支持 FolderSelection 的设备直接选目录；不支持的设备退化成选一个文件，
   * 再取其所在目录作为备份源，并在结果里说明授权持久化能力。
   */
  static async pickPhoneFolder(lang: string): Promise<AutoBackupPickResult> {
    const fail: AutoBackupPickResult = {
      ok: false,
      uri: '',
      name: '',
      persisted: false,
      errorKey: 'gallery.auto.phone.fail'
    };
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      let folderMode: boolean = false;
      if (canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')) {
        options.selectMode = picker.DocumentSelectMode.FOLDER;
        folderMode = true;
      }
      const uris: string[] = await new picker.DocumentViewPicker().select(options);
      if (uris.length === 0 || uris[0].length === 0) {
        fail.errorKey = '';
        return fail;
      }
      let folderUri: string = uris[0];
      if (!folderMode) {
        folderUri = new fileUri.FileUri(folderUri).getFullDirectoryUri();
      }
      let name: string = '';
      try {
        name = new fileUri.FileUri(folderUri).name;
      } catch (e) {
        name = '';
      }
      if (name.length === 0) {
        name = FileNameUtil.fromUri(folderUri);
      }

      const result: AutoBackupPickResult = {
        ok: true,
        uri: folderUri,
        name: name.length > 0 ? name : t('gallery.auto.phone.folder', lang),
        persisted: false,
        errorKey: ''
      };
      if (canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')) {
        try {
          await fileShare.persistPermission([AutoBackupService.readPolicy(folderUri)]);
          result.persisted = true;
        } catch (e) {
          result.errorKey = 'gallery.auto.persist.fail';
        }
      } else {
        result.errorKey = 'gallery.auto.persist.unsupported';
      }
      return result;
    } catch (e) {
      return fail;
    }
  }

  /** 冷启动恢复已持久化的目录授权；失败时把配置标记为需要重新选择。 */
  static async restorePermission(): Promise<void> {
    const config: AutoBackupConfig = AutoBackupService.load();
    if (!config.enabled || config.phoneUri.length === 0 || !config.persisted) {
      return;
    }
    if (!canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')) {
      config.persisted = false;
      config.lastError = 'gallery.auto.persist.unsupported';
      AutoBackupService.save(config);
      return;
    }
    try {
      await fileShare.activatePermission([AutoBackupService.readPolicy(config.phoneUri)]);
    } catch (e) {
      config.persisted = false;
      config.lastError = 'gallery.auto.permExpired';
      AutoBackupService.save(config);
    }
  }

  /** App 前台启动 / 用户点「立即备份」时调用。 */
  static async runIfEnabled(): Promise<AutoBackupResult> {
    const idle: AutoBackupResult = { queued: 0, errorKey: '' };
    // 审核预览模式不启动任何真实备份任务。
    if (DemoMode.isActive()) {
      return idle;
    }
    if (AutoBackupService.running) {
      return { queued: 0, errorKey: 'gallery.auto.running' };
    }
    const config: AutoBackupConfig = AutoBackupService.load();
    if (!config.enabled) {
      return idle;
    }
    if (config.phoneUri.length === 0 || config.nasPath.length === 0) {
      config.lastError = 'gallery.auto.needFolders';
      AutoBackupService.save(config);
      return { queued: 0, errorKey: config.lastError };
    }

    AutoBackupService.running = true;
    let queued: number = 0;
    try {
      const writable: boolean = await NasRepository.ensureFolder(config.nasPath);
      if (!writable) {
        config.lastError = 'gallery.auto.nas.fail';
        return { queued: 0, errorKey: config.lastError };
      }

      const sourcePath: string = new fileUri.FileUri(config.phoneUri).path;
      const files: AutoBackupSourceFile[] = AutoBackupService.collectFiles(sourcePath);
      for (const file of files) {
        const key: string = file.relative + '|' + String(file.size) + '|' + String(file.mtime);
        if (config.syncedKeys.indexOf(key) >= 0) {
          continue;
        }
        const uri: string = new fileUri.FileUri(file.path).toString();
        TransferManager.enqueueUploadFromUri(config.nasPath, file.name, uri, file.size);
        config.syncedKeys.push(key);
        queued++;
      }
      if (config.syncedKeys.length > MAX_SYNCED_KEYS) {
        config.syncedKeys.splice(0, config.syncedKeys.length - MAX_SYNCED_KEYS);
      }
      config.lastError = queued > 0 ? '' : 'gallery.auto.noNew';
    } catch (e) {
      config.lastError = 'gallery.auto.source.fail';
    } finally {
      AutoBackupService.running = false;
      config.lastRunAt = Date.now();
      config.lastQueued = queued;
      AutoBackupService.save(config);
    }
    return { queued: queued, errorKey: config.lastError };
  }

  /**
   * 递归收集待备份文件：最多 4 层、单次最多 200 个，避免一次扫描把队列撑爆。
   * 子目录结构不映射到 NAS（与现有「备份手机相册」行为一致），但去重键保留相对路径，
   * 防止不同子目录下的同名文件互相覆盖。
   */
  private static collectFiles(rootPath: string): AutoBackupSourceFile[] {
    const files: AutoBackupSourceFile[] = [];
    AutoBackupService.walk(rootPath, '', 0, files);
    return files;
  }

  private static walk(base: string, relative: string, depth: number,
    files: AutoBackupSourceFile[]): void {
    if (depth > 4 || files.length >= 200) {
      return;
    }
    const dir: string = relative.length === 0 ? base : base + '/' + relative;
    const names: string[] = fs.listFileSync(dir);
    for (const name of names) {
      if (files.length >= 200) {
        return;
      }
      const full: string = dir + '/' + name;
      const stat = fs.statSync(full);
      if (stat.isDirectory()) {
        AutoBackupService.walk(base,
          relative.length === 0 ? name : relative + '/' + name, depth + 1, files);
      } else if (stat.isFile()) {
        const entry: AutoBackupSourceFile = {
          path: full,
          relative: relative.length === 0 ? name : relative + '/' + name,
          name: name,
          size: stat.size,
          mtime: stat.mtime
        };
        files.push(entry);
      }
    }
  }

  private static readPolicy(uri: string): fileShare.PolicyInfo {
    const policy: fileShare.PolicyInfo = {
      uri: uri,
      operationMode: fileShare.OperationMode.READ_MODE
    };
    return policy;
  }
}
