import { AppConstants, PageTab } from '../common/constants/AppConstants';
import { Theme } from '../common/constants/Theme';
import { BreakpointSystem } from '../common/utils/BreakpointSystem';
import { AdaptiveShell } from '../components/AdaptiveShell';
import { LoginPage } from '../feature/login/LoginPage';
import { AutoBackupService } from '../service/AutoBackupService';
import { SessionManager } from '../service/SessionManager';
import { DemoMode } from '../common/demo/DemoMode';
import { t } from '../common/i18n/I18n';

/**
 * 应用根页面。
 * - PersistentStorage 在页面加载前建立持久化属性，冷启动自动恢复登录态与偏好；
 * - 冷启动时把持久化的 sid / 接入点重新注入数据层（否则设备将所有请求判为未认证，
 *   表现为文件页、容器页整页空白）；
 * - @StorageLink('appSession') 驱动「登录页 / 设备主页」路由，无需手动跳转；
 * - onAreaChange 以实际可用宽度发布断点，手机 / 平板 / 2in1 共用同一套页面。
 */
PersistentStorage.persistProp(AppConstants.APP_STORAGE_LANG, AppConstants.LANG_ZH);
PersistentStorage.persistProp(AppConstants.APP_STORAGE_THEME, 'system');
PersistentStorage.persistProp(AppConstants.APP_STORAGE_SESSION, '');
PersistentStorage.persistProp(AppConstants.APP_STORAGE_NOTIFY, true);
/**
 * 上次成功登录的接入点。持久化的意义：QNAP ID 登录只在首次需要做
 * 「域名探测 + 局域网扫描」，之后直接复用这个地址，登录瞬间完成。
 */
PersistentStorage.persistProp('lastEndpoint', '');
/** 用户在「我的 → 备份与相册」里自选的 NAS 备份文件夹（空 = 自动解析可写共享）。 */
PersistentStorage.persistProp('albumRoot', '');
/** 自动备份配置（开关 / 手机文件夹 / NAS 文件夹 / 上次结果），跨重启保留。 */
PersistentStorage.persistProp('autoBackupConfig', '');
/** 用户已填写的登录表单（不含密码），避免每次重启重新输入 IP/端口/账号。 */
PersistentStorage.persistProp(AppConstants.APP_STORAGE_LOGIN_FORM, '');
/**
 * 用户配置的外网接入点（DDNS 域名 / 公网 IP + 已映射端口）。
 * 云端 SmartURL 是 OAuth + relay 的浏览器流程，原生 HTTP 客户端无法直接复用；
 * 因此需要在路由器把 QTS 端口映射出去后把地址填在这里。登录成功后
 * DeviceSession 记录该端点，所有功能接口都走它，外网即全功能。
 */
PersistentStorage.persistProp('wanEndpoint', '');
/** 审核预览标记：只在用户主动进入预览时置位，退出登录即清除。 */
PersistentStorage.persistProp(DemoMode.STORAGE_KEY, false);
AppStorage.setOrCreate<string>(AppConstants.APP_STORAGE_BREAKPOINT, 'sm');
AppStorage.setOrCreate<string>(AppConstants.APP_STORAGE_LOGIN_MODE, AppConstants.LOGIN_MODE_IP);
/** 跨页导航事件总线：相册卡片用它把「我的」页跳转到文件页并定位到某目录。 */
AppStorage.setOrCreate<number>('gotoTab', -1);
AppStorage.setOrCreate<string>('filesDeepLink', '');
/** 登录阶段提示（数据层写入，登录页显示），避免 ID 登录长时间只有一个转圈。 */
AppStorage.setOrCreate<string>('loginStage', '');
/**
 * 冷启动恢复会话失败的原因（如中继会话过期），登录页据此给出可操作提示，
 * 而不是让用户「莫名回到登录页」。消费后由登录页清空。
 */
AppStorage.setOrCreate<string>('loginNotice', '');

@Entry
@Component
struct Index {
  @StorageLink('appSession') sessionRaw: string = '';
  @StorageProp('appLanguage') lang: string = 'zh';
  @StorageProp('appTheme') theme: string = 'system';
  @StorageLink('demoMode') demoMode: boolean = false;
  @StorageProp('breakpoint') bp: string = 'sm';
  @State currentTab: number = PageTab.HOME;
  /** 监听跨页跳转事件：相册卡片设置 gotoTab 后，这里把当前页切过去。 */
  @StorageLink('gotoTab') @Watch('onGotoTab') gotoTab: number = -1;

  onGotoTab(): void {
    if (this.gotoTab >= 0 && this.gotoTab !== this.currentTab) {
      this.currentTab = this.gotoTab;
    }
    AppStorage.set('gotoTab', -1);
  }

  async aboutToAppear(): Promise<void> {
    if (SessionManager.load() === null) {
      return;
    }
    // 预览会话没有真实 sid，跳过连通性探测，避免被判为过期而踢回登录页。
    if (DemoMode.isActive()) {
      return;
    }
    // 恢复会话到数据层；sid 缺失或已失效时用留存凭据静默重登一次。
    const ready: boolean = await SessionManager.ensureSession();
    if (!ready) {
      // 凭据也不可用（改过密码 / 设备换了地址）→ 回登录页重新输入。
      SessionManager.clear();
      return;
    }
    // 自动备份：先恢复目录授权，再按配置做一次增量扫描；
    // 未开启或配置不全时两个方法都会立即返回，不影响冷启动速度。
    await AutoBackupService.restorePermission();
    await AutoBackupService.runIfEnabled();
  }

  /** 取真实会话中的设备名，用于侧栏 / 顶栏展示。 */
  deviceName(): string {
    const session = SessionManager.load();
    return session !== null && session.deviceName.length > 0 ? session.deviceName : 'QNAP-NAS';
  }

  build() {
    Column() {
      if (this.sessionRaw.length === 0) {
        LoginPage()
      } else {
        Column() {
          // 审核预览标识：始终明示数据是示例，避免截图被误认为真实设备数据。
          if (this.demoMode) {
            Row() {
              Text(t('demo.banner', this.lang))
                .fontSize(11)
                .fontColor('#FFFFFF')
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(t('demo.banner.exit', this.lang))
                .fontSize(11)
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Medium)
                .margin({ left: 10 })
                .accessibilityText(t('demo.banner.exit', this.lang))
                .onClick(() => {
                  SessionManager.clear();
                })
            }
            .width('100%')
            .height(34)
            .padding({ left: 14, right: 14 })
            .backgroundColor(Theme.DANGER)
            .alignItems(VerticalAlign.Center)
          }
          AdaptiveShell({
            activeTab: this.currentTab,
            deviceName: this.deviceName(),
            onTabChange: (tab: number) => {
              this.currentTab = tab;
            },
            onNavigate: (tab: number) => {
              this.currentTab = tab;
            }
          }).layoutWeight(1)
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 135,
      colors: Theme.pageGradientColors(this.theme)
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = newValue.width as number;
      if (width > 0) {
        BreakpointSystem.publish(width);
      }
    })
  }
}
