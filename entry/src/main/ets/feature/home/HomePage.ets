import { AppConstants, LoadState, PageTab } from '../../common/constants/AppConstants';
import { Theme } from '../../common/constants/Theme';
import { t } from '../../common/i18n/I18n';
import { BreakpointSystem } from '../../common/utils/BreakpointSystem';
import { FormatUtil } from '../../common/utils/FormatUtil';
import { DeviceOverview, DeviceSession, EventItem, OpResult } from '../../model/Models';
import { NasRepository } from '../../service/NasRepository';
import { SessionManager } from '../../service/SessionManager';
import { CardContainer, InfoRow, MetricTile, PageHeader, ProgressBar, SectionTitle, StatusTag, ToastBar } from '../../components/CommonCards';
import { StateView } from '../../components/StateView';

interface MetricDef {
  key: string;
  labelKey: string;
  value: string;
  percent: number;
  color: string;
  icon: Resource;
}

interface QuickDef {
  tab: number;
  key: string;
  icon: Resource;
}

const DEFAULT_OVERVIEW: DeviceOverview = {
  deviceName: 'QNAP-NAS', model: '', firmware: '', serial: '', uptime: '—',
  cpu: 0, memory: 0, memoryUsedGB: 0, memoryTotalGB: 0, cpuTemp: 0, sysTemp: 0,
  fanRpm: 0, uploadMbps: 0, downloadMbps: 0, storageUsedTB: 0, storageTotalTB: 0,
  storageVolumeName: '', storageFreeGB: 0, ethernetCount: 0,
  volumeCount: 0, diskCount: 0, containerCount: 0, serviceRunning: 0, health: 'good'
};

/** 设备主页：状态概览、资源监控、容量、快捷入口、近期事件与设备信息（雾玻璃框）。 */
@Component
export struct HomePage {
  @StorageProp('appLanguage') lang: string = 'zh';
  @StorageProp('appTheme') theme: string = 'system';
  @StorageProp('breakpoint') bp: string = 'sm';
  @State state: string = LoadState.LOADING;
  @State overview: DeviceOverview = DEFAULT_OVERVIEW;
  @State events: EventItem[] = [];
  @State toastText: string = '';
  @State toastVisible: boolean = false;
  /** 下拉刷新状态：由 Refresh 组件驱动，结束后必须归位。 */
  @State refreshing: boolean = false;
  /** 电源确认层：空串表示关闭，'reboot' / 'shutdown' 表示待确认的动作。 */
  @State powerKind: string = '';
  /** 指令下发中：禁用确认按钮，避免重复提交。 */
  @State powerBusy: boolean = false;
  /** 正在按下的电源行，仅用于按压反馈。 */
  @State powerPressed: string = '';
  onNavigate: (tab: number) => void = () => {
  };

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.state = LoadState.LOADING;
    try {
      this.overview = await NasRepository.overview();
      this.events = await NasRepository.events();
    } catch (e) {
      // 真实接口异常时保持空值，不填充假数据
    }
    this.state = LoadState.SUCCESS;
  }

  /** 下拉刷新：重新拉取概览与事件，完成后收起刷新指示。 */
  async doRefresh(): Promise<void> {
    await this.load();
    this.refreshing = false;
  }

  showToast(key: string): void {
    this.toastText = t(key, this.lang);
    this.toastVisible = true;
    setTimeout(() => {
      this.toastVisible = false;
    }, 2200);
  }

  /* ---------- 系统电源 ---------- */

  /** 电源操作不可撤销，一律先弹确认层，不做「点一下就执行」。 */
  askPower(kind: string): void {
    if (this.powerBusy) {
      return;
    }
    this.powerPressed = '';
    this.powerKind = kind;
  }

  /**
   * 下发电源指令。三种结果分开提示：
   * 成功 / 设备有响应但未回确认（status = -2）/ 明确失败。
   * 不允许把「未确认」说成成功，也不允许把「已下发」说成失败。
   */
  async doPower(): Promise<void> {
    const kind: string = this.powerKind;
    if (this.powerBusy || kind.length === 0) {
      return;
    }
    this.powerBusy = true;
    let result: OpResult = { ok: false, status: -1 };
    try {
      result = await NasRepository.powerAction(kind);
    } catch (e) {
      result = { ok: false, status: -1 };
    }
    this.powerBusy = false;
    this.powerKind = '';
    if (result.ok) {
      this.showToast(kind === 'shutdown' ? 'home.power.shutdown.sent' : 'home.power.reboot.sent');
    } else if (result.status === -2) {
      this.showToast('home.power.uncertain');
    } else {
      this.showToast('home.power.failed');
    }
  }

  powerIsShutdown(): boolean {
    return this.powerKind === 'shutdown';
  }

  /** 电源图标底：关机用极淡红，重启用极淡蓝，都不铺大面积高饱和色。 */
  powerIconBg(): string {
    return this.powerIsShutdown() ? Theme.tagBackground('danger', this.theme)
      : Theme.primarySoft(this.theme);
  }

  powerIcon(): Resource {
    return this.powerIsShutdown() ? $r('app.media.ic_power') : $r('app.media.ic_reboot');
  }

  powerIconFg(): string {
    return this.powerIsShutdown() ? Theme.DANGER : Theme.PRIMARY;
  }

  powerConfirmTitle(): string {
    return t(this.powerIsShutdown() ? 'home.power.shutdown.confirm' : 'home.power.reboot.confirm', this.lang);
  }

  powerConfirmLabel(): string {
    if (this.powerBusy) {
      return t('home.power.sending', this.lang);
    }
    return t(this.powerIsShutdown() ? 'home.power.shutdown' : 'home.power.reboot', this.lang);
  }

  powerConfirmBg(): string {
    return this.powerIsShutdown() ? Theme.buttonDangerBg(this.theme) : Theme.buttonPrimaryBg(this.theme);
  }

  healthTone(): string {
    if (this.overview.health === 'error') {
      return 'danger';
    }
    if (this.overview.health === 'warning') {
      return 'warning';
    }
    return 'success';
  }

  healthText(): string {
    if (this.overview.health === 'error') {
      return t('home.health.error', this.lang);
    }
    if (this.overview.health === 'warning') {
      return t('home.health.warning', this.lang);
    }
    return t('home.health.good', this.lang);
  }

  connectionText(): string {
    const session: DeviceSession | null = SessionManager.load();
    const isQid: boolean = session !== null && session.mode === AppConstants.LOGIN_MODE_QID;
    return t(isQid ? 'home.connection.qid' : 'home.connection.ip', this.lang);
  }

  metrics(): MetricDef[] {
    const o: DeviceOverview = this.overview;
    const list: MetricDef[] = [
      {
        key: 'cpu', labelKey: 'home.cpu', value: FormatUtil.percent(o.cpu),
        percent: o.cpu, color: Theme.INK_BLUE, icon: $r('app.media.ic_cpu')
      },
      {
        key: 'memory', labelKey: 'home.memory',
        value: o.memoryTotalGB > 0 ? o.memoryUsedGB + ' / ' + o.memoryTotalGB + ' GB' : '—',
        percent: o.memory, color: Theme.INK_BLUE, icon: $r('app.media.ic_layers')
      },
      {
        key: 'temp', labelKey: 'home.cpu.temp',
        value: o.cpuTemp > 0 ? o.cpuTemp + '°C' : '—',
        percent: o.cpuTemp > 0 ? Math.round(o.cpuTemp / 90 * 100) : 0,
        color: Theme.INK_BLUE, icon: $r('app.media.ic_temp')
      },
      {
        // 该机型未开放网口吞吐统计，退而展示真实上报的以太网口数量。
        key: 'network', labelKey: 'home.net.ports',
        value: o.ethernetCount > 0 ? String(o.ethernetCount) : '—',
        percent: 0,
        color: Theme.INK_BLUE, icon: $r('app.media.ic_network')
      }
    ];
    return list;
  }

  @Builder
  healthBanner() {
    CardContainer({ glass: true }) {
      Row() {
        Stack() {
          Circle().width(46).height(46).fill(Theme.tagBackground(this.healthTone(), this.theme))
          Image($r('app.media.ic_shield'))
            .width(23)
            .height(23)
            .fillColor(Theme.tagForeground(this.healthTone()))
        }
        .width(46)
        .height(46)

        Column() {
          Row() {
            Text(this.overview.deviceName)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.textPrimary(this.theme))
            StatusTag({ text: t('common.online', this.lang), tone: 'success' })
              .margin({ left: 8 })
          }
          .alignItems(VerticalAlign.Center)
          Text(this.healthText())
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 5 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  metricsGrid() {
    GridRow({ columns: BreakpointSystem.columns(this.bp) }) {
      ForEach(this.metrics(), (item: MetricDef) => {
        GridCol({ span: 1 }) {
          Column() {
            MetricTile({
              label: t(item.labelKey, this.lang), value: item.value,
              percent: item.percent, barColor: item.color, icon: item.icon, glass: true
            })
          }
          .width('100%')
          .padding({
            left: BreakpointSystem.contentGap(this.bp) / 2,
            right: BreakpointSystem.contentGap(this.bp) / 2,
            bottom: BreakpointSystem.contentGap(this.bp)
          })
        }
      }, (item: MetricDef) => item.key)
    }
    .width('100%')
  }

  @Builder
  storageCard() {
    CardContainer({ glass: true }) {
      SectionTitle({ text: t('home.capacity', this.lang) })
      if (this.overview.storageTotalTB > 0) {
        // 设备同时上报总量与已用：显示百分比进度。
        Text(FormatUtil.oneDecimal(this.overview.storageUsedTB) + ' TB / ' +
          FormatUtil.oneDecimal(this.overview.storageTotalTB) + ' TB')
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
          .margin({ top: 4, bottom: 12 })
        ProgressBar({
          percent: Math.round(this.overview.storageUsedTB / this.overview.storageTotalTB * 100),
          barColor: Theme.INK_BLUE
        })
        Row() {
          Text(t('common.used', this.lang) + ' ' + FormatUtil.oneDecimal(this.overview.storageUsedTB) + ' TB')
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
            .layoutWeight(1)
          Text(t('common.free', this.lang) + ' ' +
            FormatUtil.oneDecimal(this.overview.storageTotalTB - this.overview.storageUsedTB) + ' TB')
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
        }
        .width('100%')
        .margin({ top: 10 })
      } else if (this.overview.storageFreeGB > 0) {
        // 设备仅上报可用空间（QTS 未提供总容量）：如实呈现，不补零。
        Text(FormatUtil.oneDecimal(this.overview.storageFreeGB) + ' GB')
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
          .margin({ top: 4, bottom: 4 })
        Text(t('home.capacity.free', this.lang))
          .fontSize(11)
          .fontColor(Theme.textSecondary(this.theme))
        Row() {
          Text(t('storage.volume', this.lang) + ': ' + this.overview.storageVolumeName)
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
            .layoutWeight(1)
          Text(this.overview.diskCount + ' ' + t('storage.disk', this.lang))
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
        }
        .width('100%')
        .margin({ top: 10 })
      } else {
        Text(t('home.capacity.none', this.lang))
          .fontSize(13)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 6, bottom: 6 })
      }
    }
  }

  @Builder
  quickActions() {
    // 手机三栏保持紧凑；平板/大屏用六栏栅格、每项占两栏，形成更舒展的卡片间距。
    GridRow({ columns: BreakpointSystem.isWide(this.bp) ? 6 : 3 }) {
      ForEach(this.quickDefs(), (item: QuickDef) => {
        GridCol({ span: BreakpointSystem.isWide(this.bp) ? 2 : 1 }) {
          CardContainer({ glass: true }) {
            Column() {
              Stack() {
                Circle().width(38).height(38).fill(Theme.primarySoft(this.theme))
                Image(item.icon).width(19).height(19).fillColor(Theme.PRIMARY)
              }
              .width(38)
              .height(38)
              Text(t(item.key, this.lang))
                .fontSize(12)
                .fontColor(Theme.textPrimary(this.theme))
                .margin({ top: 9 })
                .textAlign(TextAlign.Center)
                .maxLines(1)
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })
            .alignItems(HorizontalAlign.Center)
            .onClick(() => {
              this.onNavigate(item.tab);
            })
          }
        }
        .width('100%')
        .padding({
          left: BreakpointSystem.contentGap(this.bp) / 2,
          right: BreakpointSystem.contentGap(this.bp) / 2
        })
      }, (item: QuickDef) => String(item.tab))
    }
    .width('100%')
  }

  /** 快捷入口：底部导航已移除「存储」，存储信息统一在「我的」页面查看。 */
  quickDefs(): QuickDef[] {
    const list: QuickDef[] = [
      { tab: PageTab.FILES, key: 'home.action.files', icon: $r('app.media.ic_folder') },
      { tab: PageTab.DOCKER, key: 'home.action.docker', icon: $r('app.media.ic_docker') },
      { tab: PageTab.PROFILE, key: 'home.action.settings', icon: $r('app.media.ic_settings') }
    ];
    return list;
  }

  /** 单条电源操作：图标 + 标题 + 说明 + 箭头，整行可点，按下有极淡底色反馈。 */
  @Builder
  powerRow(kind: string, icon: Resource, titleKey: string, descKey: string) {
    Row() {
      Stack() {
        Circle()
          .width(36)
          .height(36)
          .fill(kind === 'shutdown' ? Theme.tagBackground('danger', this.theme)
            : Theme.primarySoft(this.theme))
        Image(icon)
          .width(18)
          .height(18)
          .fillColor(kind === 'shutdown' ? Theme.DANGER : Theme.PRIMARY)
      }
      .width(36)
      .height(36)

      Column() {
        Text(t(titleKey, this.lang))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
        Text(t(descKey, this.lang))
          .fontSize(11)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 3 })
          .maxLines(2)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 11 })

      Image($r('app.media.ic_chevron'))
        .width(13)
        .height(13)
        .fillColor(Theme.textSecondary(this.theme))
    }
    .width('100%')
    .padding({ left: 8, right: 6, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.powerPressed === kind ? Theme.pressBg(this.theme) : Color.Transparent)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.powerPressed = kind;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.powerPressed = '';
      }
    })
    .onClick(() => {
      this.askPower(kind);
    })
  }

  @Builder
  powerCard() {
    CardContainer({ glass: true }) {
      SectionTitle({ text: t('home.power.title', this.lang) })
      Column() {
        this.powerRow('reboot', $r('app.media.ic_reboot'), 'home.power.reboot', 'home.power.reboot.desc')
        Divider()
          .strokeWidth(1)
          .color(Theme.hairline(this.theme))
          .margin({ left: 47 })
        this.powerRow('shutdown', $r('app.media.ic_power'), 'home.power.shutdown', 'home.power.shutdown.desc')
      }
      .width('100%')
      .margin({ top: 2 })
    }
  }

  /** 二次确认层：与全 app 其它弹层同一套 surface 规格（圆角 / 描边 / 投影）。 */
  @Builder
  powerConfirmLayer() {
    Column() {
      Stack() {
        Circle()
          .width(48)
          .height(48)
          .fill(this.powerIconBg())
        Image(this.powerIcon())
          .width(22)
          .height(22)
          .fillColor(this.powerIconFg())
      }
      .width(48)
      .height(48)

      Text(this.powerConfirmTitle())
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.theme))
        .margin({ top: 14 })
        .textAlign(TextAlign.Center)

      Text(t('home.power.confirm.desc', this.lang))
        .fontSize(12)
        .fontColor(Theme.textSecondary(this.theme))
        .margin({ top: 7 })
        .textAlign(TextAlign.Center)
        .maxLines(3)

      Row() {
        // 取消始终可点：请求挂住时（开机箱已开始关机，回包要等到超时）不能把用户锁在弹层里。
        // 关闭弹层不撤销已发出的请求，结果仍会以提示告知。
        Button(t('action.cancel', this.lang))
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(Theme.buttonGhostFg(this.theme))
          .backgroundColor(Theme.buttonGhostBg(this.theme))
          .borderRadius(10)
          .onClick(() => {
            this.powerKind = '';
          })

        Button(this.powerConfirmLabel())
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(Theme.buttonPrimaryFg(this.theme))
          .backgroundColor(this.powerConfirmBg())
          .borderRadius(10)
          .enabled(!this.powerBusy)
          .margin({ left: 10 })
          .onClick(() => {
            this.doPower();
          })
      }
      .width('100%')
      .margin({ top: 18 })
      .alignItems(VerticalAlign.Center)
    }
    .width('86%')
    .constraintSize({ maxWidth: 380 })
    .padding({ left: 22, right: 22, top: 22, bottom: 18 })
    .backgroundColor(Theme.cardBg(this.theme))
    .borderRadius(20)
    .border({ width: 1, color: Theme.surfaceBorder(this.theme) })
    .shadow(Theme.surfaceShadow(this.theme))
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  eventsCard() {    CardContainer({ glass: true }) {
      SectionTitle({ text: t('home.recent.events', this.lang), trailing: this.events.length > 0 ? t('home.viewAll', this.lang) : '' })
      if (this.events.length === 0) {
        Column() {
          Text(t('home.no.events', this.lang))
            .fontSize(13)
            .fontColor(Theme.textPrimary(this.theme))
          Text(t('home.no.events.desc', this.lang))
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 4 })
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .alignItems(HorizontalAlign.Start)
      } else {
        ForEach(this.events, (item: EventItem) => {
          Row() {
            Circle()
              .width(8)
              .height(8)
              .fill(item.level === 'error' ? Theme.DANGER
                : item.level === 'warning' ? Theme.WARNING : Theme.SUCCESS)
              .margin({ right: 10, top: 6 })
            Column() {
              Text(item.title.length > 0 ? item.title : item.id)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.theme))
              Text(FormatUtil.shortDate(item.time))
                .fontSize(11)
                .fontColor(Theme.textSecondary(this.theme))
                .margin({ top: 4 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ top: 10, bottom: 10 })
          .alignItems(VerticalAlign.Top)
        }, (item: EventItem) => item.id)
      }
    }
  }

  @Builder
  deviceCard() {
    CardContainer({ glass: true }) {
      SectionTitle({ text: t('home.device.info', this.lang) })
      if (this.overview.model.length > 0) {
        InfoRow({ label: t('home.model', this.lang), value: this.overview.model })
      }
      if (this.overview.firmware.length > 0) {
        InfoRow({ label: t('home.firmware', this.lang), value: this.overview.firmware })
      }
      if (this.overview.serial.length > 0) {
        InfoRow({ label: t('home.serial', this.lang), value: this.overview.serial })
      }
      if (this.overview.cpuTemp > 0) {
        InfoRow({ label: t('home.cpu.temp', this.lang), value: this.overview.cpuTemp + '°C' })
      }
      if (this.overview.uptime.length > 0 && this.overview.uptime !== '—') {
        InfoRow({ label: t('home.uptime', this.lang), value: this.overview.uptime })
      }
      InfoRow({ label: t('home.connected.via', this.lang), value: this.connectionText() })
      if (this.overview.fanRpm > 0) {
        InfoRow({ label: t('home.fan', this.lang), value: this.overview.fanRpm + ' RPM' })
      }
      if (this.overview.sysTemp > 0) {
        InfoRow({ label: t('home.sys.temp', this.lang), value: this.overview.sysTemp + '°C' })
      }
    }
  }

  @Builder
  successContent() {
    if (BreakpointSystem.isWide(this.bp)) {
      // HarmonyOS 大屏三段式：通栏健康横幅 → 通栏资源栅格 → 主/辅双栏 → 通栏快捷入口。
      Column() {
        this.healthBanner()
        SectionTitle({ text: t('home.resource.monitor', this.lang) })
        this.metricsGrid()

        Row() {
          Column() {
            this.storageCard()
            SectionTitle({ text: t('home.quick.actions', this.lang) })
            this.quickActions()
            this.powerCard()
          }
          .layoutWeight(3)
          .alignItems(HorizontalAlign.Start)
          .padding({ right: BreakpointSystem.contentGap(this.bp) / 2 })

          Column() {
            this.eventsCard()
            this.deviceCard()
          }
          .layoutWeight(2)
          .alignItems(HorizontalAlign.Start)
          .padding({ left: BreakpointSystem.contentGap(this.bp) / 2 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else {
      Column() {
        this.healthBanner()
        SectionTitle({ text: t('home.resource.monitor', this.lang) })
        this.metricsGrid()
        this.storageCard()
        SectionTitle({ text: t('home.quick.actions', this.lang) })
        this.quickActions()
        this.powerCard()
        this.eventsCard()
        this.deviceCard()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: t('home.title', this.lang),
          subtitle: t('home.subtitle', this.lang),
          showAction: true,
          actionLabel: t('action.refresh', this.lang),
          onAction: () => {
            this.load();
            this.showToast('home.last.updated');
          }
        })

        ToastBar({ text: this.toastText, visible: this.toastVisible })

        // 下拉刷新 + 页面自滚动：Refresh 提供手势，Scroll 承载内容。
        Refresh({ refreshing: $$this.refreshing, offset: 80, friction: 42 }) {
          Scroll() {
            Column() {
              if (this.state === LoadState.SUCCESS) {
                this.successContent()
              } else if (this.state === LoadState.LOADING && !this.refreshing) {
                StateView({ state: LoadState.LOADING })
              } else {
                StateView({
                  state: this.state,
                  onRetry: () => {
                    this.load();
                  },
                  onGoSettings: () => {
                    this.onNavigate(PageTab.PROFILE);
                  }
                })
              }
            }
            .width('100%')
            .padding({ bottom: 20 })
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

      // 电源确认层：盖住整页（含顶栏），点空白处不关闭，避免误触。
      if (this.powerKind.length > 0) {
        Column() {
          this.powerConfirmLayer()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.scrim(this.theme))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        // 吞掉空白处的点击，避免穿透到下层卡片（尤其是顶栏的「刷新」）。
        .onClick(() => {
        })
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
