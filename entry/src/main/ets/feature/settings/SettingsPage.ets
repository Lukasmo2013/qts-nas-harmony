import { AppConstants, PageTab } from '../../common/constants/AppConstants';
import { Theme } from '../../common/constants/Theme';
import { t, tf, switchLanguage } from '../../common/i18n/I18n';
import { BreakpointSystem } from '../../common/utils/BreakpointSystem';
import { FormatUtil } from '../../common/utils/FormatUtil';
import { FileNameUtil } from '../../common/utils/FileNameUtil';
import { DeviceOverview, DeviceSession, DiskInfo, FileItem, FileListResult, ServiceInfo, VolumeInfo } from '../../model/Models';
import { AutoBackupConfig, AutoBackupService } from '../../service/AutoBackupService';
import { SessionManager } from '../../service/SessionManager';
import { NasRepository } from '../../service/NasRepository';
import { TransferManager } from '../../service/TransferManager';
import { CardContainer, InfoRow, PageHeader, SectionTitle, StatusTag, ToastBar } from '../../components/CommonCards';
import { LegalSheet } from '../../components/LegalSheet';
import fs from '@ohos.file.fs';
import photoAccessHelper from '@ohos.file.photoAccessHelper';

interface PermissionDef {
  key: string;
  descKey: string;
  granted: boolean;
}

/**
 * 个人中心与设置模块（含存储信息）。
 * 账号与设备信息、语言切换、显示模式、通知、缓存、权限清单、网络诊断、
 * 存储容量 / 卷 / 磁盘 / 系统服务、退出登录与登录态清除。
 * 已删除「界面状态演示」相关代码。
 */
@Component
export struct SettingsPage {
  /** 备份根目录名：落在可写共享下，真机上通常解析为 /Container/PhoneBackup。 */
  static readonly ALBUM_DIR: string = 'PhoneBackup';
  /** 手机相册照片子目录。 */
  static readonly ALBUM_PHOTO: string = 'Camera';
  /** 微信 / QQ 等聊天应用图片备份子目录。 */
  static readonly ALBUM_IM: string = 'IM';

  @StorageProp('appLanguage') lang: string = 'zh';
  @StorageProp('appTheme') theme: string = 'system';
  @StorageProp('breakpoint') bp: string = 'sm';
  @StorageProp('notificationsEnabled') notify: boolean = true;
  @State dialog: string = '';
  /** 隐私政策 / 服务条款阅读层。 */
  @State legalKind: string = '';
  @State permissionExpanded: boolean = false;
  @State toastText: string = '';
  @State toastVisible: boolean = false;
  /** 下拉刷新状态：重新拉取设备、存储与备份配置。 */
  @State refreshing: boolean = false;
  /* ---- 备份与相册 ---- */
  /** 用户自选的备份根目录（持久化，空 = 自动解析可写共享）。 */
  @StorageLink('albumRoot') albumRoot: string = '';
  /** 自动解析出的备份根目录（仅本会话，不覆盖用户选择）。 */
  @State albumRootAuto: string = '';
  @State albumBusy: boolean = false;
  /* ---- 自动备份 ---- */
  /** 配置变化时驱动状态区重绘（服务层负责实际持久化）。 */
  @StorageProp('autoBackupConfig') autoConfigRaw: string = '';
  @State autoOpen: boolean = false;
  @State autoBusy: boolean = false;
  @State autoDraftPhoneUri: string = '';
  @State autoDraftPhoneName: string = '';
  @State autoDraftNasPath: string = '';
  @State autoDraftPersisted: boolean = false;
  /** 开关显示值：与持久化配置解耦，配置不全时能把开关原地弹回去。 */
  @State autoOn: boolean = false;
  /** 文件夹行的按压反馈：点击必须有视觉响应，避免「按了没反应」的错觉。 */
  @State folderPressed: boolean = false;
  /** 程序化改写开关时置位，防止 onChange 反向触发切换逻辑形成死循环。 */
  private autoSwitchGuard: boolean = false;
  /** NAS 目录选择器正在为自动备份服务（true）还是手动备份根目录服务（false）。 */
  @State pickForAuto: boolean = false;
  /* ---- NAS 目录选择器 ---- */
  @State pickOpen: boolean = false;
  /** 当前浏览到的目录；空串表示「共享文件夹」这一层。 */
  @State pickPath: string = '';
  @State pickShares: string[] = [];
  @State pickDirs: FileItem[] = [];
  @State pickLoading: boolean = false;
  @State pickError: string = '';
  /* ---- 存储信息（自原「存储」页面并入）---- */
  @State storageLoaded: boolean = false;
  @State volumes: VolumeInfo[] = [];
  @State disks: DiskInfo[] = [];
  @State services: ServiceInfo[] = [];
  @State serviceExpanded: boolean = false;
  /* ---- 设备实时状态（序列号 / 温度 / 风扇 / 网口）---- */
  @State overview: DeviceOverview | null = null;

  aboutToAppear(): void {
    this.loadStorage();
    this.loadAlbumRoot();
    this.loadOverview();
    // 开关初始值直接取自持久化配置，避免进页面时显示与实际状态不一致。
    this.autoOn = this.autoConfig().enabled;
    // 权限可能被用户在系统设置里撤回，进页面时重新探测并回写状态。
    AutoBackupService.restorePermission();
  }

  /** 拉取一次设备概览；失败时保持空值，界面显示「—」而不是报错弹窗。 */
  private async loadOverview(): Promise<void> {
    try {
      this.overview = await NasRepository.overview();
    } catch (e) {
      this.overview = null;
    }
  }

  showToast(key: string): void {
    this.toastText = t(key, this.lang);
    this.toastVisible = true;
    setTimeout(() => {
      this.toastVisible = false;
    }, 2200);
  }

  /** 直接展示一段文本（带占位替换的文案、或需要拼进真实路径的提示）。 */
  showToastText(text: string): void {
    this.toastText = text;
    this.toastVisible = true;
    setTimeout(() => {
      this.toastVisible = false;
    }, 3000);
  }

  /** 拉取真实存储信息：卷 / 磁盘来自 sysmonitor，系统服务来自 sysinfoReq。 */
  async loadStorage(): Promise<void> {
    try {
      const bundle = await NasRepository.storage();
      this.volumes = bundle.volumes;
      this.disks = bundle.disks;
      this.services = await NasRepository.services();
    } catch (e) {
      // 接口不可用时保持空集合，由界面渲染真实空态
    }
    this.storageLoaded = true;
  }

  /** 下拉刷新：设备概览、卷/磁盘/服务、备份根目录全部以 NAS 当前数据重取。 */
  async doRefresh(): Promise<void> {
    await this.loadOverview();
    await this.loadStorage();
    await this.loadAlbumRoot();
    this.refreshing = false;
  }

  /* ---- 主卷取助手：设备当前仅上报一个卷，缺省时给出安全占位 ---- */
  hasVolume(): boolean {
    return this.volumes.length > 0;
  }

  volumeFreeGB(): number {
    return this.volumes.length > 0 ? this.volumes[0].freeGB : 0;
  }

  volumeName(): string {
    return this.volumes.length > 0 ? this.volumes[0].name : '—';
  }

  volumePool(): string {
    return this.volumes.length > 0 ? this.volumes[0].pool : '—';
  }

  volumeDiskCount(): number {
    return this.volumes.length > 0 ? this.volumes[0].diskCount : 0;
  }

  volumeEncrypted(): boolean {
    return this.volumes.length > 0 ? this.volumes[0].encrypted : false;
  }

  volumePartitions(): string {
    return this.volumes.length > 0 ? this.volumes[0].partitions.join(' / ') : '';
  }

  volumeSwapGB(): number {
    return this.volumes.length > 0 ? this.volumes[0].swapTotalGB : 0;
  }

  /** 服务列表默认只展示前 6 条，避免「我的」页面被长列表撑开。 */
  visibleServices(): ServiceInfo[] {
    if (this.serviceExpanded || this.services.length <= 6) {
      return this.services;
    }
    return this.services.slice(0, 6);
  }

  session(): DeviceSession | null {
    return SessionManager.load();
  }

  /** 避免在 @Builder 内使用非空断言，统一由此方法做空值收敛。 */
  deviceValue(field: string): string {
    const session: DeviceSession | null = SessionManager.load();
    if (session === null) {
      return '--';
    }
    if (field === 'name') {
      return session.deviceName;
    }
    if (field === 'model') {
      return session.model.length > 0 ? session.model
        : (this.overview !== null ? this.overview.model : '');
    }
    if (field === 'firmware') {
      return session.firmware.length > 0 ? session.firmware
        : (this.overview !== null ? this.overview.firmware : '');
    }
    if (field === 'serial') {
      return session.serial.length > 0 ? session.serial
        : (this.overview !== null ? this.overview.serial : '');
    }
    if (field === 'hostPort') {
      return session.host + ':' + session.port;
    }
    if (field === 'loginAt') {
      return FormatUtil.dateTime(session.loginAt);
    }
    return '--';
  }

  /** 设备字段有有效值才渲染，避免展示 `--` / `—` 空项。 */
  hasDeviceValue(field: string): boolean {
    const value: string = this.deviceValue(field);
    return value.length > 0 && value !== '--' && value !== '—';
  }

  accountText(): string {
    const session: DeviceSession | null = this.session();
    return session !== null ? FormatUtil.maskAccount(session.account) : '--';
  }

  connectionText(): string {
    const session: DeviceSession | null = this.session();
    const isQid: boolean = session !== null && session.mode === AppConstants.LOGIN_MODE_QID;
    return t(isQid ? 'home.connection.qid' : 'home.connection.ip', this.lang);
  }

  /** 当前登录方式（IP 直连 / QNAP ID）对应的显示文案。 */
  modeText(): string {
    const session: DeviceSession | null = this.session();
    const isQid: boolean = session !== null && session.mode === AppConstants.LOGIN_MODE_QID;
    return t(isQid ? 'login.mode.id' : 'login.mode.ip', this.lang);
  }

  isIdMode(): boolean {
    const session: DeviceSession | null = this.session();
    return session !== null && session.mode === AppConstants.LOGIN_MODE_QID;
  }

  /** 切换登录方式 = 清除当前会话，回到登录页并预选目标方式。 */
  switchLoginMode(mode: string): void {
    AppStorage.setOrCreate<string>(AppConstants.APP_STORAGE_LOGIN_MODE, mode);
    this.dialog = '';
    SessionManager.clear();
  }

  languageText(): string {
    return this.lang === AppConstants.LANG_EN ? t('login.lang.en', this.lang) : t('login.lang.zh', this.lang);
  }

  themeText(): string {
    if (this.theme === 'light') {
      return t('settings.theme.light', this.lang);
    }
    if (this.theme === 'dark') {
      return t('settings.theme.dark', this.lang);
    }
    return t('settings.theme.system', this.lang);
  }

  permissions(): PermissionDef[] {
    // 与 module.json5 实际声明保持一致：不再展示未声明的通知权限。
    const list: PermissionDef[] = [
      { key: 'settings.permission.internet', descKey: 'settings.permission.internet.desc', granted: true },
      { key: 'settings.permission.network', descKey: 'settings.permission.network.desc', granted: true },
      { key: 'settings.permission.media', descKey: 'settings.permission.media.desc', granted: true },
      { key: 'settings.permission.vpn', descKey: 'settings.permission.vpn.desc', granted: true }
    ];
    return list;
  }

  @Builder
  profileCard() {
    CardContainer({ glass: true }) {
      Row() {
        Stack() {
          Circle().width(56).height(56).fill(Theme.PRIMARY)
          Image($r('app.media.ic_person')).width(28).height(28).fillColor('#FFFFFF')
        }
        .width(56)
        .height(56)
        Column() {
          Row() {
            Text(this.accountText())
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.textPrimary(this.theme))
            StatusTag({ text: t('common.online', this.lang), tone: 'success' })
              .margin({ left: 8 })
          }
          .alignItems(VerticalAlign.Center)
          Text(this.connectionText())
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 6 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 14 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 登录方式 + 接入地址：把「怎么连上的」讲清楚。
      Row() {
        StatusTag({ text: this.modeText(), tone: 'info' })
        Text(this.deviceValue('hostPort'))
          .fontSize(11)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ left: 10 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ top: 10 })
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  deviceCard() {
    CardContainer({ glass: true }) {
      SectionTitle({ text: t('settings.device.list', this.lang) })
      if (this.hasDeviceValue('name')) {
        InfoRow({ label: t('settings.device.name', this.lang), value: this.deviceValue('name') })
      }
      if (this.hasDeviceValue('model')) {
        InfoRow({ label: t('settings.device.model', this.lang), value: this.deviceValue('model') })
      }
      if (this.hasDeviceValue('firmware')) {
        InfoRow({ label: t('settings.device.firmware', this.lang), value: this.deviceValue('firmware') })
      }
      if (this.hasDeviceValue('serial')) {
        InfoRow({ label: t('settings.device.serial', this.lang), value: this.deviceValue('serial') })
      }
      if (this.overview !== null && this.overview.cpuTemp > 0) {
        InfoRow({ label: t('home.cpu.temp', this.lang), value: this.overview.cpuTemp + '°C' })
      }
      if (this.overview !== null && this.overview.sysTemp > 0) {
        InfoRow({ label: t('home.sys.temp', this.lang), value: this.overview.sysTemp + '°C' })
      }
      if (this.overview !== null && this.overview.fanRpm > 0) {
        InfoRow({ label: t('home.fan', this.lang), value: this.overview.fanRpm + ' RPM' })
      }
      if (this.overview !== null && this.overview.ethernetCount > 0) {
        InfoRow({ label: t('home.net.ports', this.lang), value: String(this.overview.ethernetCount) })
      }
      if (this.overview !== null && this.overview.diskCount > 0) {
        InfoRow({ label: t('home.disks', this.lang), value: String(this.overview.diskCount) })
      }
      if (this.hasDeviceValue('hostPort')) {
        InfoRow({ label: t('settings.connection', this.lang), value: this.deviceValue('hostPort') })
      }
      if (this.hasDeviceValue('loginAt')) {
        InfoRow({ label: t('settings.login.time', this.lang), value: this.deviceValue('loginAt') })
      }
    }
  }

  @Builder
  generalCard() {
    CardContainer() {
      SectionTitle({ text: t('settings.general', this.lang) })
      this.settingRow($r('app.media.ic_language'), 'settings.language',
        'settings.language.desc', this.languageText(), () => {
          this.dialog = 'language';
        })
      this.settingRow($r('app.media.ic_settings'), 'settings.theme',
        'settings.theme.desc', this.themeText(), () => {
          this.dialog = 'theme';
        })
      this.switchRow($r('app.media.ic_bell'), 'settings.notifications', 'settings.notifications.desc')
      this.settingRow($r('app.media.ic_refresh'), 'settings.cache',
        'settings.cache.desc', '', () => {
          this.showToast('settings.cache.cleared');
        })
      this.settingRow($r('app.media.ic_lock'), 'settings.permissions',
        'settings.permissions.desc', '', () => {
          this.permissionExpanded = !this.permissionExpanded;
        })
      if (this.permissionExpanded) {
        Column() {
          ForEach(this.permissions(), (item: PermissionDef) => {
            Row() {
              Column() {
                Text(t(item.key, this.lang))
                  .fontSize(12)
                  .fontColor(Theme.textPrimary(this.theme))
                Text(t(item.descKey, this.lang))
                  .fontSize(10)
                  .fontColor(Theme.textSecondary(this.theme))
                  .margin({ top: 3 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              StatusTag({
                text: t(item.granted ? 'settings.granted' : 'settings.not.granted', this.lang),
                tone: item.granted ? 'success' : 'warning'
              })
            }
            .width('100%')
            .padding({ top: 9, bottom: 9 })
            .alignItems(VerticalAlign.Center)
          }, (item: PermissionDef) => item.key)
        }
        .width('100%')
        .padding({ left: 8, right: 8, bottom: 6 })
        .backgroundColor(Theme.subCardBg(this.theme))
        .borderRadius(10)
      }
    }
  }

  @Builder
  settingRow(icon: Resource, titleKey: string, descKey: string, value: string, action: () => void) {
    Row() {
      Image(icon).width(20).height(20).fillColor(Theme.PRIMARY).margin({ right: 12 })
      Column() {
        Text(t(titleKey, this.lang))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
        Text(t(descKey, this.lang))
          .fontSize(11)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (value.length > 0) {
        Text(value)
          .fontSize(12)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ right: 6 })
      }
      Image($r('app.media.ic_chevron'))
        .width(16)
        .height(16)
        .fillColor(Theme.textSecondary(this.theme))
    }
    .width('100%')
    .padding({ top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      action();
    })
    Column().width('100%').height(1).backgroundColor(Theme.divider(this.theme))
  }

  @Builder
  switchRow(icon: Resource, titleKey: string, descKey: string) {
    Row() {
      Image(icon).width(20).height(20).fillColor(Theme.PRIMARY).margin({ right: 12 })
      Column() {
        Text(t(titleKey, this.lang))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
        Text(t(descKey, this.lang))
          .fontSize(11)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.notify })
        .width(42)
        .height(24)
        .selectedColor(Theme.PRIMARY)
        .switchPointColor('#FFFFFF')
        .onChange((isOn: boolean) => {
          AppStorage.setOrCreate<boolean>('notificationsEnabled', isOn);
        })
    }
    .width('100%')
    .padding({ top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    Column().width('100%').height(1).backgroundColor(Theme.divider(this.theme))
  }

  @Builder
  networkCard() {
    CardContainer({ glass: true }) {
      SectionTitle({ text: t('settings.network', this.lang) })
      InfoRow({ label: t('settings.connection', this.lang), value: this.deviceValue('hostPort') })
      InfoRow({
        label: t('common.status', this.lang),
        value: t('common.online', this.lang)
      })
      InfoRow({ label: t('login.protocol', this.lang), value: 'HTTPS / TLS 1.3' })
      StatusTag({
        text: t('common.online', this.lang),
        tone: 'success'
      }).margin({ top: 8 })
    }
  }

  @Builder
  aboutCard() {
    CardContainer({ glass: true }) {
      SectionTitle({ text: t('settings.about', this.lang) })
      InfoRow({
        label: t('common.version', this.lang),
        value: AppConstants.VERSION_NAME + ' (' + AppConstants.VERSION_CODE + ')'
      })
      InfoRow({ label: t('settings.buildDate', this.lang), value: AppConstants.BUILD_DATE })
      InfoRow({ label: t('settings.build', this.lang), value: AppConstants.BUILD_TAG })
      InfoRow({ label: t('settings.license', this.lang), value: AppConstants.LICENSE_NAME })
      InfoRow({ label: t('settings.copyright', this.lang), value: AppConstants.COPYRIGHT })
      // 政策入口必须是真实可打开的全文，不能只弹一段提示文字。
      Row() {
        Text(t('settings.privacy', this.lang))
          .fontSize(12)
          .fontColor(Theme.PRIMARY)
          .accessibilityText(t('settings.privacy.desc', this.lang))
          .onClick(() => {
            this.legalKind = 'privacy';
          })
        Text(t('settings.terms', this.lang))
          .fontSize(12)
          .fontColor(Theme.PRIMARY)
          .margin({ left: 20 })
          .accessibilityText(t('settings.terms.desc', this.lang))
          .onClick(() => {
            this.legalKind = 'terms';
          })
        Text(t('settings.reset', this.lang))
          .fontSize(12)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ left: 20 })
          .accessibilityText(t('settings.reset', this.lang))
          .onClick(() => {
            switchLanguage(AppConstants.LANG_ZH);
            AppStorage.setOrCreate<string>('appTheme', 'system');
            this.showToast('settings.reset.done');
          })
      }
      .width('100%')
      .margin({ top: 10 })
    }
  }

  /**
   * 备份与相册：把「我的」页做成真正的手机备份入口。
   *
   * 旧实现只是把三个写死的 /Public/... 路径丢给文件页，而真机上 /Public 对 demo-user
   * 是**只读且为空**，点进去永远是空目录 —— 用户看到的就是「功能不能用」。
   *
   * 现在：
   *  1) 「备份位置」一行显示真实路径，点它打开 **NAS 目录选择器**，可自选任意共享下的文件夹
   *     （选择结果持久化到 `albumRoot`，跨重启保留；失败会回退为自动选择）；
   *  2) 「备份手机相册」拉系统相册选择器 → 入队后台上传（TransferManager），选完立刻返回；
   *  3) 两个相册入口点击时先 ensureFolder 建目录，成功才深链到文件页。
   */
  @Builder
  galleryCard() {
    CardContainer({ glass: true }) {
      SectionTitle({ text: t('gallery.title', this.lang) })
      Text(t('gallery.desc', this.lang))
        .fontSize(11)
        .fontColor(Theme.textSecondary(this.theme))
        .margin({ top: 2, bottom: 10 })
        .width('100%')

      Row() {
        Image($r('app.media.ic_upload'))
          .width(15)
          .height(15)
          .fillColor(Theme.PRIMARY)
        Text(t('gallery.upload', this.lang))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.PRIMARY)
          .margin({ left: 6 })
      }
      .width('100%')
      .height(38)
      .justifyContent(FlexAlign.Center)
      .borderRadius(10)
      .backgroundColor(Theme.primarySoft(this.theme))
      .opacity(this.albumBusy ? 0.5 : 1)
      .onClick(() => {
        this.backupPhotos();
      })
      .margin({ bottom: 12 })

      this.autoBackupRow()
      this.autoFolderRow()
      Column().width('100%').height(1).backgroundColor(Theme.divider(this.theme)).margin({ top: 4 })

      this.galleryEntry($r('app.media.ic_image'), 'gallery.wechat', SettingsPage.ALBUM_PHOTO)
      this.galleryEntry($r('app.media.ic_file'), 'gallery.qq', SettingsPage.ALBUM_IM)

      Row() {
        Stack() {
          Circle().width(34).height(34).fill(Theme.quietIconBg(this.theme))
          Image($r('app.media.ic_folder')).width(17).height(17).fillColor(Theme.iconTint(this.theme))
        }
        .width(34)
        .height(34)
        .margin({ right: 10 })
        Column() {
          Row() {
            Text(t('gallery.root.label', this.lang))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.theme))
            Text(t(this.rootPicked() ? 'gallery.root.custom' : 'gallery.root.auto', this.lang))
              .fontSize(10)
              .fontColor(Theme.textSecondary(this.theme))
              .backgroundColor(Theme.quietIconBg(this.theme))
              .borderRadius(4)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .margin({ left: 6 })
          }
          Text(this.albumPath(''))
            .fontSize(10)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(t('gallery.root.change', this.lang))
          .fontSize(12)
          .fontColor(Theme.PRIMARY)
      }
      .width('100%')
      .padding({ top: 11, bottom: 11 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.openPicker();
      })
    }
  }

  /**
   * 自动备份控制区：显式开关 + 状态标签 + 配置/立即备份入口。
   *
   * 之前这里是「白字 + 浅蓝底」的文字按钮（对比度接近 1:1，等于隐形），
   * 也没有任何状态控件，用户看不出当前是开还是关。现改为：
   * 1) 右侧放 46×26 的开关控件，开为主色、关为浅灰轨道，一眼可见；
   * 2) 开启态整块面板换成浅蓝底 + 蓝边，状态强化；
   * 3) 未配置文件夹时拨动开关不静默失败，直接落到配置层并给出提示。
   */
  @Builder
  autoBackupRow() {
    Column() {
      Row() {
        Stack() {
          Circle()
            .width(36)
            .height(36)
            .fill(this.autoOn ? Theme.primarySoft(this.theme) : Theme.quietIconBg(this.theme))
          Image($r('app.media.ic_upload'))
            .width(17)
            .height(17)
            .fillColor(this.autoOn ? Theme.PRIMARY : Theme.iconTint(this.theme))
        }
        .width(36)
        .height(36)
        .margin({ right: 11 })

        Column() {
          Row() {
            Text(t('gallery.auto.title', this.lang))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.theme))
            StatusTag({
              text: this.autoStatusText(),
              tone: this.autoOn && this.autoConfig().lastError.length === 0 ? 'success' : 'info'
            }).margin({ left: 6 })
          }
          .alignItems(VerticalAlign.Center)

          Text(this.autoDetailText())
            .fontSize(10)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 3 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.autoOn })
          .width(46)
          .height(26)
          .selectedColor(Theme.PRIMARY)
          .switchPointColor('#FFFFFF')
          .accessibilityText(t('gallery.auto.switch', this.lang))
          .margin({ left: 8 })
          .onChange((isOn: boolean) => {
            this.onAutoSwitch(isOn);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Button(t('gallery.auto.folder.config', this.lang), { type: ButtonType.Capsule })
          .height(32)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.buttonSoftFg(this.theme))
          .backgroundColor(Theme.buttonSoftBg(this.theme))
          .border({ width: 1, color: Theme.buttonSoftBorder(this.theme) })
          .layoutWeight(1)
          .onClick(() => {
            this.openAutoDialog();
          })
        Button(t('gallery.auto.runNow', this.lang), { type: ButtonType.Capsule })
          .height(32)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.buttonPrimaryFg(this.theme))
          .backgroundColor(Theme.buttonPrimaryBg(this.theme))
          .layoutWeight(1)
          .margin({ left: 10 })
          .enabled(!this.autoBusy)
          .opacity(this.autoBusy ? 0.6 : 1)
          .onClick(() => {
            this.runAutoNow();
          })
      }
      .width('100%')
      .margin({ top: 11 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.autoOn ? Theme.primarySoft(this.theme) : Theme.subCardBg(this.theme))
    .borderRadius(14)
    .border({ width: 1, color: this.autoOn ? Theme.buttonSoftBorder(this.theme) : Theme.hairline(this.theme) })
    .margin({ bottom: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 自动备份文件夹入口：显示手机与 NAS 两端配置，点击进入配置层（带按压反馈）。 */
  @Builder
  autoFolderRow() {
    Row() {
      Stack() {
        Circle().width(34).height(34).fill(Theme.quietIconBg(this.theme))
        Image($r('app.media.ic_folder')).width(17).height(17).fillColor(Theme.iconTint(this.theme))
      }
      .width(34)
      .height(34)
      .margin({ right: 10 })
      Column() {
        Text(t('gallery.auto.folder.title', this.lang))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
        Text(this.autoConfig().phoneName.length > 0 && this.autoConfig().nasPath.length > 0
          ? this.autoConfig().phoneName + ' → ' + this.autoConfig().nasPath
          : t('gallery.auto.folder.empty', this.lang))
          .fontSize(10)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(t('gallery.auto.folder.config', this.lang))
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.buttonSoftFg(this.theme))
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(Theme.buttonSoftBg(this.theme))
        .borderRadius(9)
        .border({ width: 1, color: Theme.buttonSoftBorder(this.theme) })
        .margin({ right: 4 })
      Image($r('app.media.ic_chevron'))
        .width(16)
        .height(16)
        .fillColor(Theme.textSecondary(this.theme))
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor(this.folderPressed ? Theme.pressBg(this.theme) : Color.Transparent)
    .alignItems(VerticalAlign.Center)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.folderPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.folderPressed = false;
      }
    })
    .onClick(() => {
      this.openAutoDialog();
    })
  }

  /**
   * 相册入口：点击先确保目录存在，再跨页深链到文件页。
   * sub 为相对备份根目录的子路径（空串表示根目录本身）。
   */
  @Builder
  galleryEntry(icon: Resource, titleKey: string, sub: string) {
    Row() {
      Stack() {
        Circle().width(34).height(34).fill(Theme.quietIconBg(this.theme))
        Image(icon).width(17).height(17).fillColor(Theme.iconTint(this.theme))
      }
      .width(34)
      .height(34)
      .margin({ right: 10 })
      Column() {
        Text(t(titleKey, this.lang))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
        Text(this.albumPath(sub))
          .fontSize(10)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Image($r('app.media.ic_chevron'))
        .width(16)
        .height(16)
        .fillColor(Theme.textSecondary(this.theme))
    }
    .width('100%')
    .padding({ top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.openAlbum(sub);
    })
    Column().width('100%').height(1).backgroundColor(Theme.divider(this.theme))
  }

  /** 当前生效的备份根目录：优先用户自选（持久化），否则用自动解析的结果。 */
  effectiveRoot(): string {
    return this.albumRoot.length > 0 ? this.albumRoot : this.albumRootAuto;
  }

  /** 是否由用户显式指定过备份目录。 */
  rootPicked(): boolean {
    return this.albumRoot.length > 0;
  }

  /** 卡片上展示的真实路径：根目录未解析完成时给出占位，不显示假路径。 */
  albumPath(sub: string): string {
    const root: string = this.effectiveRoot();
    if (root.length === 0) {
      return t('gallery.root.pending', this.lang);
    }
    return sub.length === 0 ? root : root + '/' + sub;
  }

  /** 目标绝对路径。 */
  albumAbs(sub: string): string {
    const root: string = this.effectiveRoot();
    const safe: string = root.length > 0 ? root : ('/' + SettingsPage.ALBUM_DIR);
    return sub.length === 0 ? safe : safe + '/' + sub;
  }

  /**
   * 把备份根目录与两个子目录真正建出来，返回可用的根目录；失败返回空串。
   *
   * **用户自选过目录时只认它**（失败就如实报错，不偷偷换到别处）；
   * 没选过才自动挑：已解析根目录 → 每个可写共享下的 PhoneBackup → preferredRoot。
   * 真机上 /Public 只读、/TMBackup 不存在，只有 /Container 能建。
   */
  async ensureAlbum(): Promise<string> {
    const bases: string[] = [];
    if (this.rootPicked()) {
      bases.push(this.albumRoot);
    } else {
      if (this.albumRootAuto.length > 0) {
        bases.push(this.albumRootAuto);
      }
      try {
        const roots: string[] = await NasRepository.writableRoots();
        for (const root of roots) {
          const candidate: string = root + '/' + SettingsPage.ALBUM_DIR;
          if (bases.indexOf(candidate) < 0) {
            bases.push(candidate);
          }
        }
      } catch (e) {
        // 探测失败就只用已解析的根目录
      }
      if (bases.length === 0) {
        try {
          const root: string = await NasRepository.preferredRoot();
          if (root.length > 0) {
            bases.push(root + '/' + SettingsPage.ALBUM_DIR);
          }
        } catch (e) {
          // 保持 bases 为空，下面统一返回失败
        }
      }
    }
    for (const base of bases) {
      const ok: boolean = await NasRepository.ensureFolder(base + '/' + SettingsPage.ALBUM_PHOTO);
      if (ok) {
        if (!this.rootPicked()) {
          this.albumRootAuto = base;
        } else {
          this.albumRoot = base;
        }
        await NasRepository.ensureFolder(base + '/' + SettingsPage.ALBUM_IM);
        return base;
      }
    }
    return '';
  }

  /** 备份失败提示：把真实尝试路径带出去，用户/开发者一眼能看出卡在哪。 */
  dirFailText(): string {
    const target: string = this.albumPath(SettingsPage.ALBUM_PHOTO);
    return tf('gallery.dir.fail', this.lang, target);
  }

  /** 打开备份目录：先建目录再深链，避免落到不存在的路径上。 */
  async openAlbum(sub: string): Promise<void> {
    const root: string = await this.ensureAlbum();
    if (root.length === 0) {
      this.showToastText(this.dirFailText());
      return;
    }
    AppStorage.setOrCreate<string>('filesDeepLink', this.albumAbs(sub));
    AppStorage.setOrCreate<number>('gotoTab', PageTab.FILES);
  }

  /**
   * 备份手机相册：系统相册选择器 → 逐张入队后台上传。
   * 选完立刻返回（不等传输完成），进度由 TransferManager 维护，文件页的传输条可查看。
   */
  async backupPhotos(): Promise<void> {
    if (this.albumBusy) {
      return;
    }
    this.albumBusy = true;
    let uris: string[] = [];
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 50;
      const result = await new photoAccessHelper.PhotoViewPicker().select(options);
      uris = result.photoUris;
    } catch (e) {
      this.albumBusy = false;
      return;
    }
    if (uris.length === 0) {
      this.albumBusy = false;
      this.showToast('gallery.upload.empty');
      return;
    }
    const root: string = await this.ensureAlbum();
    if (root.length === 0) {
      this.albumBusy = false;
      this.showToastText(this.dirFailText());
      return;
    }
    const dest: string = this.albumAbs(SettingsPage.ALBUM_PHOTO);
    const context = this.getUIContext().getHostContext();
    let queued: number = 0;
    for (const uri of uris) {
      try {
        // 相册 Picker 只给 uri；用系统 FileUri + 媒体库 display_name 还原原始文件名
        let name: string = await FileNameUtil.resolve(uri, context);
        if (name.length === 0 || FileNameUtil.isIdLike(name)) {
          // 实在取不到才用兜底名，并尽量保留从 uri 推断出的扩展名
          name = FileNameUtil.fallback(uri, queued, 'jpg');
        }
        let sizeHint: number = 0;
        try {
          const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
          try {
            sizeHint = fs.statSync(file.fd).size;
          } finally {
            fs.closeSync(file);
          }
        } catch (e) {
          sizeHint = 0;
        }
        TransferManager.enqueueUploadFromUri(dest, name, uri, sizeHint);
        queued++;
      } catch (e) {
        // 单张失败不影响其余照片入队
      }
    }
    this.albumBusy = false;
    if (queued > 0) {
      this.toastText = tf('gallery.upload.queued', this.lang, String(queued));
      this.toastVisible = true;
      setTimeout(() => {
        this.toastVisible = false;
      }, 2400);
    } else {
      this.showToast('gallery.upload.fail');
    }
  }

  /* ==================== 自动备份 ==================== */

  private autoConfig(): AutoBackupConfig {
    return AutoBackupService.load();
  }

  /** 当前自动备份状态：关闭 / 正常 / 待配置 / 具体异常。 */
  autoStatusText(): string {
    const config: AutoBackupConfig = this.autoConfig();
    if (!config.enabled) {
      return t('gallery.auto.off', this.lang);
    }
    if (config.lastError.length > 0) {
      return t(config.lastError, this.lang);
    }
    if (config.lastRunAt === 0) {
      return t('gallery.auto.pending', this.lang);
    }
    return t('gallery.auto.on', this.lang);
  }

  /** 状态副标题：显示已配置的源/目标与最近一次扫描结果，不显示假数据。 */
  autoDetailText(): string {
    const config: AutoBackupConfig = this.autoConfig();
    if (config.phoneUri.length === 0 || config.nasPath.length === 0) {
      return t('gallery.auto.notConfigured', this.lang);
    }
    const folders: string = (config.phoneName.length > 0 ? config.phoneName : t('gallery.auto.phone.folder', this.lang))
      + ' → ' + config.nasPath;
    if (config.lastRunAt === 0) {
      return folders;
    }
    let detail: string = folders + ' · ' + tf('gallery.auto.lastRun', this.lang,
      FormatUtil.dateTime(config.lastRunAt));
    if (config.lastQueued > 0) {
      detail += ' · ' + tf('gallery.auto.lastQueued', this.lang, String(config.lastQueued));
    }
    return detail;
  }

  /** 手机与 NAS 两端是否都已配置。 */
  private autoConfigured(): boolean {
    const config: AutoBackupConfig = this.autoConfig();
    return config.phoneUri.length > 0 && config.nasPath.length > 0;
  }

  /** 把开关的显示值同步回持久化配置（用于拒绝切换后原地弹回）。 */
  private syncAutoOn(): void {
    const enabled: boolean = this.autoConfig().enabled;
    if (enabled === this.autoOn) {
      return;
    }
    this.autoSwitchGuard = true;
    this.autoOn = enabled;
    setTimeout(() => {
      this.autoSwitchGuard = false;
    }, 60);
  }

  /**
   * 开关回调：配置不完整时不静默失败，直接把用户带到配置层并说明原因，
   * 同时把开关弹回关闭态，避免出现「看着是开的、其实没生效」。
   */
  onAutoSwitch(isOn: boolean): void {
    if (this.autoSwitchGuard) {
      return;
    }
    if (isOn && !this.autoConfigured()) {
      this.showToast('gallery.auto.needFolders');
      this.autoSwitchGuard = true;
      this.autoOn = false;
      setTimeout(() => {
        this.autoSwitchGuard = false;
      }, 60);
      this.openAutoDialog();
      return;
    }
    const errorKey: string = AutoBackupService.setEnabled(isOn);
    if (errorKey.length > 0) {
      this.showToast(errorKey);
      this.syncAutoOn();
      return;
    }
    this.autoOn = isOn;
    this.showToast(isOn ? 'gallery.auto.enabled' : 'gallery.auto.disabled');
  }

  /** 保留的切换入口：供开关以外的地方调用，内部仍走 onAutoSwitch。 */
  toggleAutoBackup(): void {
    this.onAutoSwitch(!this.autoOn);
  }

  /** 立即扫描一次：使用与主备份完全相同的 TransferManager 队列。 */
  async runAutoNow(): Promise<void> {
    if (this.autoBusy) {
      return;
    }
    // 未配置先引导配置，未开启先明确提示：不再出现「点了完全没动静」。
    if (!this.autoConfigured()) {
      this.showToast('gallery.auto.needFolders');
      this.openAutoDialog();
      return;
    }
    if (!this.autoOn) {
      this.showToast('gallery.auto.enableFirst');
      return;
    }
    this.autoBusy = true;
    const result = await AutoBackupService.runIfEnabled();
    this.autoBusy = false;
    this.autoOn = this.autoConfig().enabled;
    if (result.queued > 0 && result.errorKey.length === 0) {
      this.showToastText(tf('gallery.auto.queued', this.lang, String(result.queued)));
      return;
    }
    if (result.errorKey.length > 0) {
      this.showToast(result.errorKey);
    }
  }

  /** 打开配置层时先把已保存配置带入草稿，取消则不会写回。 */
  openAutoDialog(): void {
    // 先置位再读配置：即使配置读取异常，点击也必须有响应。
    this.autoOpen = true;
    this.autoDraftPhoneUri = '';
    this.autoDraftPhoneName = '';
    this.autoDraftNasPath = '';
    this.autoDraftPersisted = false;
    try {
      const config: AutoBackupConfig = this.autoConfig();
      this.autoDraftPhoneUri = config.phoneUri;
      this.autoDraftPhoneName = config.phoneName;
      this.autoDraftNasPath = config.nasPath;
      this.autoDraftPersisted = config.persisted;
    } catch (e) {
      this.showToast('gallery.auto.folder.empty');
    }
  }

  closeAutoDialog(): void {
    this.autoOpen = false;
  }

  /** 选择手机文件夹；授权持久化失败不阻断配置保存，但要如实提示。 */
  async pickAutoPhoneFolder(): Promise<void> {
    if (this.autoBusy) {
      return;
    }
    this.autoBusy = true;
    const result = await AutoBackupService.pickPhoneFolder(this.lang);
    this.autoBusy = false;
    if (!result.ok) {
      if (result.errorKey.length > 0) {
        this.showToast(result.errorKey);
      }
      return;
    }
    this.autoDraftPhoneUri = result.uri;
    this.autoDraftPhoneName = result.name;
    this.autoDraftPersisted = result.persisted;
    if (result.errorKey.length > 0) {
      this.showToast(result.errorKey);
    } else {
      this.showToast('gallery.auto.phone.saved');
    }
  }

  /** 转入 NAS 目录选择器；确认后自动回到配置层。 */
  openAutoNasPicker(): void {
    this.autoOpen = false;
    this.openPicker(true);
  }

  /** 保存草稿：先确认 NAS 目录真实可写，再落盘。 */
  async saveAutoFolders(): Promise<void> {
    if (this.autoBusy) {
      return;
    }
    if (this.autoDraftPhoneUri.length === 0 || this.autoDraftNasPath.length === 0) {
      this.showToast('gallery.auto.needFolders');
      return;
    }
    this.autoBusy = true;
    const writable: boolean = await NasRepository.ensureFolder(this.autoDraftNasPath);
    this.autoBusy = false;
    if (!writable) {
      this.showToastText(tf('gallery.auto.nas.fail.path', this.lang, this.autoDraftNasPath));
      return;
    }
    AutoBackupService.saveFolders(this.autoDraftPhoneUri, this.autoDraftPhoneName,
      this.autoDraftNasPath, this.autoDraftPersisted);
    this.autoOpen = false;
    this.autoOn = this.autoConfig().enabled;
    this.showToast('gallery.auto.saved');
    // 首配完成但开关还关着时，明确告诉用户下一步该做什么。
    if (!this.autoOn) {
      setTimeout(() => {
        this.showToast('gallery.auto.enableFirst');
      }, 1200);
    }
  }

  /** 从 photoAccessHelper 返回的 uri 里取原始文件名（解码、清理、保留扩展名）。 */
  static nameOfUri(uri: string): string {
    return FileNameUtil.fromUri(uri);
  }

  /** 解析「自动」备份根目录（不覆盖用户自选值）：优先可写共享，没有可写共享时退回第一个共享。 */
  async loadAlbumRoot(): Promise<void> {
    if (this.rootPicked()) {
      return;
    }
    try {
      const root: string = await NasRepository.preferredRoot();
      if (root.length > 0) {
        this.albumRootAuto = root + '/' + SettingsPage.ALBUM_DIR;
      }
    } catch (e) {
      this.albumRootAuto = '';
    }
  }

  /* ==================== NAS 目录选择器 ==================== */

  /** 打开选择器：从共享文件夹这一层开始（若已选过，则直接定位到已选目录所在层级）。 */
  async openPicker(forAuto: boolean = false): Promise<void> {
    this.pickForAuto = forAuto;
    this.pickOpen = true;
    this.pickError = '';
    this.pickDirs = [];
    this.pickShares = [];
    this.pickPath = '';
    this.pickLoading = true;
    try {
      // 每次打开都重新向设备要共享名单，避免新增共享（如 Data）看不到。
      NasRepository.resetShareCache();
      this.pickShares = await NasRepository.shares();
      if (this.pickShares.length === 0) {
        this.pickError = t('gallery.pick.noShares', this.lang);
      }
    } catch (e) {
      this.pickError = t('gallery.pick.fail', this.lang);
    }
    this.pickLoading = false;
  }

  /** 进入某个目录：只列子文件夹（备份只能选文件夹）。 */
  async pickEnter(path: string): Promise<void> {
    this.pickLoading = true;
    this.pickError = '';
    try {
      const res: FileListResult = await NasRepository.files(path);
      if (!res.valid) {
        this.pickError = t('gallery.pick.fail', this.lang);
        this.pickLoading = false;
        return;
      }
      const dirs: FileItem[] = [];
      for (const item of res.items) {
        if (item.kind === 'folder') {
          dirs.push(item);
        }
      }
      this.pickDirs = dirs;
      this.pickPath = path;
      if (dirs.length === 0) {
        this.pickError = t('gallery.pick.emptyDir', this.lang);
      }
    } catch (e) {
      this.pickError = t('gallery.pick.fail', this.lang);
    }
    this.pickLoading = false;
  }

  /** 返回上一级；已在共享层则无操作。 */
  async pickUp(): Promise<void> {
    if (this.pickPath.length === 0) {
      return;
    }
    const idx: number = this.pickPath.lastIndexOf('/');
    if (idx <= 0) {
      this.pickPath = '';
      this.pickDirs = [];
      this.pickError = '';
      return;
    }
    await this.pickEnter(this.pickPath.substring(0, idx));
  }

  /** 当前选择器所在目录的子路径拼接。 */
  pickChild(name: string): string {
    return this.pickPath + '/' + name;
  }

  /**
   * 确认选择：先真的在该目录下建出 Camera 子目录来验证可写；
   * 不可写就报错且不保存（避免用户以为设置成功、备份时才失败）。
   */
  async confirmPick(): Promise<void> {
    const target: string = this.pickPath;
    if (target.length === 0) {
      this.showToast('gallery.pick.needFolder');
      return;
    }
    this.pickLoading = true;
    if (this.pickForAuto) {
      const autoOk: boolean = await NasRepository.ensureFolder(target);
      this.pickLoading = false;
      if (!autoOk) {
        this.showToastText(tf('gallery.auto.nas.fail.path', this.lang, target));
        return;
      }
      this.autoDraftNasPath = target;
      this.pickOpen = false;
      this.autoOpen = true;
      this.showToastText(tf('gallery.auto.nas.saved', this.lang, target));
      return;
    }
    const ok: boolean = await NasRepository.ensureFolder(target + '/' + SettingsPage.ALBUM_PHOTO);
    if (!ok) {
      this.pickLoading = false;
      this.showToastText(tf('gallery.pick.readonly', this.lang, target));
      return;
    }
    await NasRepository.ensureFolder(target + '/' + SettingsPage.ALBUM_IM);
    this.albumRoot = target;
    this.pickLoading = false;
    this.pickOpen = false;
    this.showToastText(tf('gallery.pick.saved', this.lang, target));
  }

  /** 恢复为自动选择。 */
  resetPick(): void {
    this.albumRoot = '';
    this.pickOpen = false;
    this.loadAlbumRoot();
    this.showToast('gallery.pick.autoDone');
  }

  /** 容量概览：只呈现设备真实上报的可用空间 / 卷 / 磁盘信息，不臆造总容量。 */
  @Builder
  storageOverviewCard() {
    CardContainer({ glass: true }) {
      SectionTitle({ text: t('settings.storage.title', this.lang) })
      if (this.hasVolume()) {
        Row() {
          Column() {
            Text(FormatUtil.oneDecimal(this.volumeFreeGB()) + ' GB')
              .fontSize(26)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.theme))
            Text(t('home.capacity.free', this.lang))
              .fontSize(11)
              .fontColor(Theme.textSecondary(this.theme))
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Column() {
            Text(t('storage.volume', this.lang))
              .fontSize(11)
              .fontColor(Theme.textSecondary(this.theme))
            Text(this.volumeName())
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.theme))
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 4, bottom: 6 })

        InfoRow({ label: t('storage.pool.type', this.lang), value: this.volumePool() })
        InfoRow({ label: t('storage.disk', this.lang), value: String(this.volumeDiskCount()) })
        InfoRow({
          label: t('storage.encryption', this.lang),
          value: t(this.volumeEncrypted() ? 'action.on' : 'action.off', this.lang)
        })
        if (this.volumePartitions().length > 0) {
          InfoRow({ label: t('storage.partitions', this.lang), value: this.volumePartitions() })
        }
        if (this.volumeSwapGB() > 0) {
          InfoRow({
            label: t('storage.swap', this.lang),
            value: FormatUtil.oneDecimal(this.volumeSwapGB()) + ' GB'
          })
        }
      } else if (this.storageLoaded) {
        Text(t('settings.storage.empty', this.lang))
          .fontSize(13)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 6, bottom: 6 })
      } else {
        Text(t('state.loading.desc', this.lang))
          .fontSize(13)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 6, bottom: 6 })
      }
    }
  }

  /** 硬盘明细：设备仅提供分区标识，其余字段保持「未提供」。 */
  @Builder
  diskListCard() {
    CardContainer({ glass: true }) {
      SectionTitle({ text: t('storage.tab.disks', this.lang) })
      if (this.disks.length === 0) {
        Text(this.storageLoaded ? t('storage.empty.disks', this.lang) : t('state.loading.desc', this.lang))
          .fontSize(13)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 6, bottom: 6 })
      } else {
        ForEach(this.disks, (item: DiskInfo) => {
          Row() {
            Stack() {
              Circle().width(34).height(34).fill(Theme.quietIconBg(this.theme))
              Image($r('app.media.ic_storage')).width(17).height(17).fillColor(Theme.iconTint(this.theme))
            }
            .width(34)
            .height(34)
            Column() {
              Text(item.slot)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.theme))
                .maxLines(1)
              Text(item.partition.length > 0 ? item.partition : item.model)
                .fontSize(11)
                .fontColor(Theme.textSecondary(this.theme))
                .margin({ top: 3 })
                .maxLines(1)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 10 })
            if (item.smart.length > 0) {
              StatusTag({ text: item.smart, tone: item.smart === 'Pass' ? 'success' : 'warning' })
            }
          }
          .width('100%')
          .padding({ top: 9, bottom: 9 })
          .alignItems(VerticalAlign.Center)
        }, (item: DiskInfo) => item.id)
      }
    }
  }

  /** 已安装的系统服务：协议、端口与运行状态。 */
  @Builder
  serviceListCard() {
    CardContainer({ glass: true }) {
      SectionTitle({
        text: t('storage.tab.services', this.lang),
        trailing: this.services.length > 6
          ? (this.serviceExpanded ? t('settings.storage.collapse', this.lang)
            : t('settings.storage.showAll', this.lang))
          : ''
      })
      if (this.services.length === 0) {
        Text(this.storageLoaded ? t('storage.empty.services', this.lang) : t('state.loading.desc', this.lang))
          .fontSize(13)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 6, bottom: 6 })
      } else {
        ForEach(this.visibleServices(), (item: ServiceInfo) => {
          Row() {
            Stack() {
              Circle().width(34).height(34).fill(Theme.quietIconBg(this.theme))
              Image($r('app.media.ic_network')).width(17).height(17).fillColor(Theme.iconTint(this.theme))
            }
            .width(34)
            .height(34)
            Column() {
              Text(item.name)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.theme))
                .maxLines(1)
              Text(item.protocol + (item.port.length > 0 ? ' · ' + item.port : ''))
                .fontSize(11)
                .fontColor(Theme.textSecondary(this.theme))
                .margin({ top: 3 })
                .maxLines(1)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 10 })
            StatusTag({
              text: t(item.running ? 'storage.running' : 'storage.stopped', this.lang),
              tone: item.running ? 'success' : 'info'
            })
          }
          .width('100%')
          .padding({ top: 9, bottom: 9 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            if (this.services.length > 6) {
              this.serviceExpanded = !this.serviceExpanded;
            }
          })
        }, (item: ServiceInfo) => item.id)
      }
    }
  }

  /** 账户与登录：登录方式展示与切换、账号信息、退出登录。 */
  @Builder
  sessionCard() {
    CardContainer({ glass: true }) {
      SectionTitle({ text: t('settings.account', this.lang) })

      // 登录方式：一行式展示当前方式 + 切换入口
      Row() {
        Image($r('app.media.ic_shield')).width(20).height(20).fillColor(Theme.PRIMARY).margin({ right: 12 })
        Column() {
          Text(t('settings.loginMode', this.lang))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.theme))
          Text(t(this.isIdMode() ? 'settings.loginMode.idDesc' : 'settings.loginMode.ipDesc', this.lang))
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.modeText())
          .fontSize(12)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ right: 8 })
        Image($r('app.media.ic_chevron'))
          .width(16)
          .height(16)
          .fillColor(Theme.textSecondary(this.theme))
      }
      .width('100%')
      .padding({ top: 13, bottom: 13 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.dialog = 'loginMode';
      })
      Column().width('100%').height(1).backgroundColor(Theme.divider(this.theme))

      InfoRow({ label: t('login.ip.username', this.lang), value: this.accountText() })
      InfoRow({ label: t('settings.connection', this.lang), value: this.deviceValue('hostPort') })
      InfoRow({ label: t('settings.login.time', this.lang), value: this.deviceValue('loginAt') })

      Row() {
        Button(t('action.logout', this.lang), { type: ButtonType.Capsule })
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.DANGER)
          .backgroundColor(Theme.dangerSoft(this.theme))
          .borderRadius(12)
          .onClick(() => {
            this.dialog = 'logout';
          })
      }
      .width('100%')
      .margin({ top: 14 })
    }
  }

  @Builder
  optionRow(label: string, selected: boolean, action: () => void) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor(selected ? Theme.PRIMARY : Theme.textPrimary(this.theme))
        .layoutWeight(1)
      if (selected) {
        Image($r('app.media.ic_check'))
          .width(18)
          .height(18)
          .fillColor(Theme.PRIMARY)
      }
    }
    .width('100%')
    .padding({ top: 13, bottom: 13 })
    .onClick(() => {
      action();
    })
    Column().width('100%').height(1).backgroundColor(Theme.divider(this.theme))
  }

  /* ==================== NAS 目录选择器（弹层） ==================== */

  /** 选择器单行：文件夹图标 + 名称 + chevron。 */
  @Builder
  pickRow(label: string, icon: Resource, onTap: () => void) {
    Row() {
      Image(icon)
        .width(16)
        .height(16)
        .fillColor(Theme.iconTint(this.theme))
      Text(label)
        .fontSize(13)
        .fontColor(Theme.textPrimary(this.theme))
        .margin({ left: 10 })
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Image($r('app.media.ic_chevron'))
        .width(14)
        .height(14)
        .fillColor(Theme.textSecondary(this.theme))
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      onTap();
    })
    Column().width('100%').height(1).backgroundColor(Theme.divider(this.theme))
  }

  /** NAS 目录选择器：共享层 → 逐级进入子目录 → 选用当前目录。 */
  /** 自动备份文件夹配置层：手机目录走系统 Picker，NAS 目录可选可填。 */
  @Builder
  autoFolderLayer() {
    Column() {
      Row() {
        Text(t('gallery.auto.folder.title', this.lang))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.theme))
          .layoutWeight(1)
        Image($r('app.media.ic_close'))
          .width(18)
          .height(18)
          .fillColor(Theme.textSecondary(this.theme))
          .accessibilityText(t('action.close', this.lang))
          .onClick(() => {
            this.closeAutoDialog();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(t('gallery.auto.folder.desc', this.lang))
        .fontSize(11)
        .lineHeight(17)
        .fontColor(Theme.textSecondary(this.theme))
        .width('100%')
        .margin({ top: 8 })

      Scroll() {
        Column() {
          Row() {
            Stack() {
              Circle().width(34).height(34).fill(Theme.quietIconBg(this.theme))
              Image($r('app.media.ic_image')).width(17).height(17).fillColor(Theme.iconTint(this.theme))
            }
            .width(34)
            .height(34)
            .margin({ right: 10 })
            Column() {
              Text(t('gallery.auto.phone.title', this.lang))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.theme))
              Text(this.autoDraftPhoneName.length > 0 ? this.autoDraftPhoneName
                : t('gallery.auto.phone.empty', this.lang))
                .fontSize(11)
                .fontColor(Theme.textSecondary(this.theme))
                .margin({ top: 3 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(t('gallery.auto.phone.choose', this.lang))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.buttonSoftFg(this.theme))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(Theme.buttonSoftBg(this.theme))
              .borderRadius(9)
              .border({ width: 1, color: Theme.buttonSoftBorder(this.theme) })
              .opacity(this.autoBusy ? 0.45 : 1)
              .onClick(() => {
                this.pickAutoPhoneFolder();
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center)

          if (this.autoDraftPhoneUri.length > 0 && !this.autoDraftPersisted) {
            Text(t('gallery.auto.persist.hint', this.lang))
              .fontSize(10)
              .lineHeight(15)
              .fontColor(Theme.WARNING)
              .width('100%')
              .padding({ bottom: 10 })
          }

          Column().width('100%').height(1).backgroundColor(Theme.divider(this.theme))

          Row() {
            Stack() {
              Circle().width(34).height(34).fill(Theme.quietIconBg(this.theme))
              Image($r('app.media.ic_folder')).width(17).height(17).fillColor(Theme.iconTint(this.theme))
            }
            .width(34)
            .height(34)
            .margin({ right: 10 })
            Column() {
              Text(t('gallery.auto.nas.title', this.lang))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.theme))
              Text(this.autoDraftNasPath.length > 0 ? this.autoDraftNasPath
                : t('gallery.auto.nas.empty', this.lang))
                .fontSize(11)
                .fontColor(Theme.textSecondary(this.theme))
                .margin({ top: 3 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(t('gallery.auto.nas.choose', this.lang))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.buttonSoftFg(this.theme))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(Theme.buttonSoftBg(this.theme))
              .borderRadius(9)
              .border({ width: 1, color: Theme.buttonSoftBorder(this.theme) })
              .onClick(() => {
                this.openAutoNasPicker();
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 8 })
          .alignItems(VerticalAlign.Center)

          TextInput({ text: this.autoDraftNasPath, placeholder: t('gallery.auto.nas.hint', this.lang) })
            .fontSize(12)
            .fontColor(Theme.textPrimary(this.theme))
            .backgroundColor(Theme.subCardBg(this.theme))
            .height(40)
            .width('100%')
            .onChange((value: string) => {
              this.autoDraftNasPath = value;
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Row() {
        Button(t('action.cancel', this.lang), { type: ButtonType.Capsule })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(Theme.buttonGhostFg(this.theme))
          .backgroundColor(Theme.buttonGhostBg(this.theme))
          .borderRadius(10)
          .onClick(() => {
            this.closeAutoDialog();
          })
        Button(t('action.save', this.lang), { type: ButtonType.Capsule })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(Theme.buttonPrimaryFg(this.theme))
          .backgroundColor(Theme.buttonPrimaryBg(this.theme))
          .borderRadius(10)
          .margin({ left: 10 })
          .enabled(!this.autoBusy)
          .opacity(this.autoBusy ? 0.6 : 1)
          .onClick(() => {
            this.saveAutoFolders();
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .height(BreakpointSystem.isWide(this.bp) ? 560 : 500)
    .padding(18)
    .backgroundColor(Theme.glassBg(this.theme))
    .backgroundBlurStyle(Theme.glassBlur())
    .border({ width: 1, color: Theme.glassBorder(this.theme) })
    .borderRadius(20)
    .shadow(Theme.cardShadow(this.theme))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  folderPicker() {
    Column() {
      Row() {
        Image($r('app.media.ic_chevron_left'))
          .width(18)
          .height(18)
          .fillColor(this.pickPath.length > 0 ? Theme.textPrimary(this.theme)
            : Theme.textSecondary(this.theme))
          .opacity(this.pickPath.length > 0 ? 1 : 0.35)
          .onClick(() => {
            this.pickUp();
          })
        Column() {
          Text(t(this.pickForAuto ? 'gallery.auto.nas.title' : 'gallery.pick.title', this.lang))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.theme))
          Text(this.pickPath.length > 0 ? this.pickPath : t('gallery.pick.shares', this.lang))
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 8 })
        Image($r('app.media.ic_close'))
          .width(18)
          .height(18)
          .fillColor(Theme.textSecondary(this.theme))
          .accessibilityText(t('action.close', this.lang))
          .onClick(() => {
            this.pickOpen = false;
            if (this.pickForAuto) {
              this.autoOpen = true;
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column().width('100%').height(1).backgroundColor(Theme.divider(this.theme)).margin({ top: 10 })

      Scroll() {
        Column() {
          if (this.pickLoading) {
            Row() {
              LoadingProgress().width(18).height(18).color(Theme.PRIMARY)
            }
            .width('100%')
            .height(70)
            .justifyContent(FlexAlign.Center)
          } else if (this.pickPath.length === 0) {
            ForEach(this.pickShares, (path: string) => {
              this.pickRow(path, $r('app.media.ic_storage'), () => {
                this.pickEnter(path);
              })
            }, (path: string) => 'sh-' + path)
          } else {
            ForEach(this.pickDirs, (item: FileItem) => {
              this.pickRow(item.name, $r('app.media.ic_folder'), () => {
                this.pickEnter(this.pickChild(item.name));
              })
            }, (item: FileItem) => 'dir-' + item.name)
          }
          if (!this.pickLoading && this.pickError.length > 0) {
            Text(this.pickError)
              .fontSize(11)
              .fontColor(Theme.textSecondary(this.theme))
              .width('100%')
              .padding({ top: 12, bottom: 12 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)

      Text(t(this.pickForAuto ? 'gallery.auto.nas.hint' : 'gallery.pick.hint', this.lang))
        .fontSize(10)
        .lineHeight(15)
        .fontColor(Theme.textSecondary(this.theme))
        .width('100%')
        .margin({ top: 6 })

      Row() {
        Button(t(this.pickForAuto ? 'action.cancel' : 'gallery.pick.auto', this.lang),
          { type: ButtonType.Capsule })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(Theme.buttonGhostFg(this.theme))
          .backgroundColor(Theme.buttonGhostBg(this.theme))
          .borderRadius(10)
          .onClick(() => {
            if (this.pickForAuto) {
              this.pickOpen = false;
              this.autoOpen = true;
            } else {
              this.resetPick();
            }
          })
        Button(t('gallery.pick.choose', this.lang), { type: ButtonType.Capsule })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(Theme.buttonPrimaryFg(this.theme))
          .backgroundColor(Theme.buttonPrimaryBg(this.theme))
          .borderRadius(10)
          .margin({ left: 10 })
          .enabled(this.pickPath.length > 0 && !this.pickLoading)
          .opacity(this.pickPath.length > 0 ? 1 : 0.45)
          .onClick(() => {
            this.confirmPick();
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .height('72%')
    .padding(18)
    .backgroundColor(Theme.glassBg(this.theme))
    .backgroundBlurStyle(Theme.glassBlur())
    .border({ width: 1, color: Theme.glassBorder(this.theme) })
    .borderRadius(20)
    .shadow(Theme.cardShadow(this.theme))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  dialogCard() {
    Column() {
      Text(this.dialog === 'language' ? t('settings.language', this.lang)
        : this.dialog === 'theme' ? t('settings.theme', this.lang)
          : this.dialog === 'loginMode' ? t('settings.loginMode', this.lang)
            : t('settings.logout.confirm', this.lang))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.theme))        .width('100%')

      if (this.dialog === 'language') {
        this.optionRow(t('login.lang.zh', this.lang), this.lang === AppConstants.LANG_ZH, () => {
          switchLanguage(AppConstants.LANG_ZH);
          this.dialog = '';
        })
        this.optionRow(t('login.lang.en', this.lang), this.lang === AppConstants.LANG_EN, () => {
          switchLanguage(AppConstants.LANG_EN);
          this.dialog = '';
        })
      } else if (this.dialog === 'theme') {
        this.optionRow(t('settings.theme.light', this.lang), this.theme === 'light', () => {
          AppStorage.setOrCreate<string>('appTheme', 'light');
          this.dialog = '';
        })
        this.optionRow(t('settings.theme.dark', this.lang), this.theme === 'dark', () => {
          AppStorage.setOrCreate<string>('appTheme', 'dark');
          this.dialog = '';
        })
        this.optionRow(t('settings.theme.system', this.lang), this.theme === 'system', () => {
          AppStorage.setOrCreate<string>('appTheme', 'system');
          this.dialog = '';
        })
      } else if (this.dialog === 'loginMode') {
        Text(t('settings.loginMode.desc', this.lang))
          .fontSize(12)
          .lineHeight(19)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 12, bottom: 4 })
          .width('100%')
        this.modeRow(t('login.mode.ip', this.lang), t('settings.loginMode.ipDesc', this.lang),
          !this.isIdMode(), AppConstants.LOGIN_MODE_IP)
        this.modeRow(t('login.mode.id', this.lang), t('settings.loginMode.idDesc', this.lang),
          this.isIdMode(), AppConstants.LOGIN_MODE_QID)
      } else {
        Text(t('settings.logout.confirm.desc', this.lang))
          .fontSize(13)
          .lineHeight(20)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 14 })
          .width('100%')
        Row() {
          Button(t('action.cancel', this.lang), { type: ButtonType.Capsule })
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(Theme.buttonGhostFg(this.theme))
            .backgroundColor(Theme.buttonGhostBg(this.theme))
            .borderRadius(10)
            .onClick(() => {
              this.dialog = '';
            })
          Button(t('action.logout', this.lang), { type: ButtonType.Capsule })
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(Theme.buttonPrimaryFg(this.theme))
            .backgroundColor(Theme.buttonDangerBg(this.theme))
            .borderRadius(10)
            .margin({ left: 10 })
            .onClick(() => {
              this.dialog = '';
              this.showToast('settings.logout.success');
              setTimeout(() => {
                SessionManager.clear();
              }, 300);
            })
        }
        .width('100%')
        .margin({ top: 20 })
      }

      if (this.dialog === 'language' || this.dialog === 'theme' || this.dialog === 'loginMode') {
        Button(t('action.close', this.lang), { type: ButtonType.Capsule })
          .width('100%')
          .height(40)
          .fontSize(14)
          .fontColor(Theme.buttonGhostFg(this.theme))
          .backgroundColor(Theme.buttonGhostBg(this.theme))
          .borderRadius(10)
          .margin({ top: 16 })
          .onClick(() => {
            this.dialog = '';
          })
      }
    }
    .width('100%')
    .padding(20)
    .backgroundColor(Theme.cardBg(this.theme))
    .borderRadius(18)
    .alignItems(HorizontalAlign.Start)
  }

  /** 登录方式选项：标题 + 一行说明，选中打勾。 */
  @Builder
  modeRow(title: string, desc: string, selected: boolean, mode: string) {    Row() {
      Column() {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(selected ? Theme.PRIMARY : Theme.textPrimary(this.theme))
        Text(desc)
          .fontSize(11)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (selected) {
        Image($r('app.media.ic_check'))
          .width(18)
          .height(18)
          .fillColor(Theme.PRIMARY)
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (selected) {
        this.dialog = '';
        return;
      }
      this.switchLoginMode(mode);
    })
    Column().width('100%').height(1).backgroundColor(Theme.divider(this.theme))
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        PageHeader({ title: t('settings.title', this.lang), subtitle: t('settings.subtitle', this.lang) })
        ToastBar({ text: this.toastText, visible: this.toastVisible })

        // 下拉刷新 + 内容区独立滚动：刷新后所有卡片以 NAS 当前数据重绘。
        Refresh({ refreshing: $$this.refreshing, offset: 80, friction: 42 }) {
          Scroll() {
            Column() {
            if (BreakpointSystem.isWide(this.bp)) {
              Row() {
                Column() {
                  this.profileCard()
                  this.sessionCard()
                  this.deviceCard()
                  this.storageOverviewCard()
                  this.galleryCard()
                  this.diskListCard()
                  this.serviceListCard()
                  this.networkCard()
                }
                // 左侧设备/存储/硬盘卡片更多，宽屏按 3:2 分配，避免右栏过宽留白。
                .layoutWeight(3)
                .padding({ right: 10 })
                .alignItems(HorizontalAlign.Start)

                Column() {
                  this.generalCard()
                  this.aboutCard()
                }
                .layoutWeight(2)
                .padding({ left: 10 })
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            } else {
              Column() {
                this.profileCard()
                this.sessionCard()
                this.deviceCard()
                this.generalCard()
                this.storageOverviewCard()
                this.galleryCard()
                this.diskListCard()
                this.serviceListCard()
                this.networkCard()
                this.aboutCard()
              }
              .width('100%')
                .alignItems(HorizontalAlign.Start)
              }
            }
            .width('100%')
            .padding({ bottom: 24 })
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing(() => {
          this.doRefresh();
        })
      }
      .width('100%')
      .height('100%')
      .padding({ left: BreakpointSystem.pagePadding(this.bp), right: BreakpointSystem.pagePadding(this.bp) })
      .alignItems(HorizontalAlign.Start)

      if (this.dialog.length > 0) {
        Column() {
          this.dialogCard()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.scrim(this.theme))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 24, right: 24 })
      }

      if (this.autoOpen && !this.pickOpen) {
        Column() {
          this.autoFolderLayer()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.scrim(this.theme))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 24, right: 24 })
      }

      if (this.pickOpen) {
        Column() {
          this.folderPicker()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.scrim(this.theme))
        .justifyContent(FlexAlign.End)
        .padding({ left: 12, right: 12, bottom: 12 })
      }

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
  }
}
