import { LoadState } from '../../common/constants/AppConstants';
import { Theme } from '../../common/constants/Theme';
import { t, tf } from '../../common/i18n/I18n';
import { BreakpointSystem } from '../../common/utils/BreakpointSystem';
import { FormatUtil } from '../../common/utils/FormatUtil';
import { webview } from '@kit.ArkWeb';
import { ContainerInfo, ContainerPort, DeviceSession, ImageInfo, OpResult } from '../../model/Models';
import { NasRepository } from '../../service/NasRepository';
import { SessionManager } from '../../service/SessionManager';
import { CardContainer, InfoRow, PageHeader, StatusTag, ToastBar } from '../../components/CommonCards';
import { StateView } from '../../components/StateView';
import { DemoMode } from '../../common/demo/DemoMode';

/**
 * Container Station 5：容器与镜像管理。
 *
 * 真机实测（QTS 5.2.11 + CS 5）确认的契约：
 *   - 网关是 `/container-station/api/v3/...`，老版 `/cgi-bin/container-station/api/v2/...` 一律 404；
 *   - 鉴权只认 `Authorization: Bearer <sid>`，只用 `?sid=` 会 401；
 *   - `GET /containers` → `{data:{items:[{id,name,type,image,status,project,startedAt,portBindings}]}}`；
 *   - `GET /images` → `{data:{items:[{id,tags[],created,size}]}}`。
 *
 * 因此「未安装」的判定必须看 HTTP 状态码而不是 si 服务清单：
 *   - 404 → 网关卡不存在，判定未安装，渲染专门的安装说明；
 *   - 401 → 网关在，只是会话失效，提示重新登录而不是谎报未安装；
 *   - 200 + 空数组 → 已安装但无容器。
 *
 * 已确认缺失契约的能力（创建容器 / 拉取镜像 / 单容器日志）不提供入口，
 * 宁可没有按钮，也不给点了没反应的假按钮。启停 / 重启 / 删除均为真实调用，
 * 且以「操作后重新拉列表、状态真的变了」为成功判据。
 */
@Component
export struct DockerPage {
  @StorageProp('appLanguage') lang: string = 'zh';
  @StorageProp('appTheme') theme: string = 'system';
  @StorageProp('breakpoint') bp: string = 'sm';
  @State state: string = LoadState.LOADING;
  /** Container Station 是否已安装（决定渲染「未安装」还是空态/列表）。 */
  @State installed: boolean = false;
  /** 会话失效标记（网关 401）：已安装但没有可用凭据。 */
  @State unauthorized: boolean = false;
  @State tab: number = 0;
  @State containers: ContainerInfo[] = [];
  @State images: ImageInfo[] = [];
  @State dialog: string = '';
  @State activeItem: ContainerInfo | null = null;
  @State toastText: string = '';
  @State toastVisible: boolean = false;
  @State busy: boolean = false;
  /** 镜像管理模式：打开后镜像卡显示删除入口。 */
  @State imageManage: boolean = false;
  /** 待删除镜像（仅删除确认层使用）。 */
  @State imageTarget: ImageInfo | null = null;
  /** 下拉刷新状态：驱动 Refresh 组件的加载指示。 */
  @State refreshing: boolean = false;
  /** 容器 Web 应用全屏层：端口 chip 点击后在此打开真实宿主机端口。 */
  @State showWeb: boolean = false;
  @State webUrl: string = '';
  @State webLabel: string = '';
  @State webLoadError: boolean = false;
  private webCtl: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.state = LoadState.LOADING;
    try {
      const result = await NasRepository.containersResult();
      this.installed = result.installed;
      this.unauthorized = result.status === 401;
      this.containers = result.items;
      if (!result.installed && result.status !== 401) {
        // 网络失败 / 网关不存在：state 与 installed 分开表达，避免把断网说成未安装
        this.state = result.status === 404 ? LoadState.EMPTY : LoadState.ERROR;
        this.images = [];
        return;
      }
      if (result.status === 401) {
        this.state = LoadState.ERROR;
        this.images = [];
        return;
      }
      this.images = await NasRepository.images();
      this.state = LoadState.SUCCESS;
    } catch (e) {
      this.state = LoadState.ERROR;
    }
  }

  /** 下拉刷新：重新拉取容器与镜像，完成后收起刷新指示。 */
  async doRefresh(): Promise<void> {
    await this.load();
    this.refreshing = false;
  }

  /**
   * 打开容器映射到宿主机的 Web 应用。
   *
   * 地址只来自当前真实会话的 host/scheme 与 Container Station 上报的 host 端口，
   * 不拼接任何固定示例地址；Web 的 src 只在组件创建时读取，因此每次打开都重建
   * controller，并通过先关后开保证新地址一定被加载。
   */
  private openContainerPort(item: ContainerInfo, port: ContainerPort): void {
    if (port.host <= 0) {
      return;
    }
    // 预览模式只展示端口信息，不打开真实设备上的网页，避免审核时看到错误页。
    if (DemoMode.isActive()) {
      this.showToast('docker.web.preview');
      return;
    }
    const session: DeviceSession | null = SessionManager.load();
    if (session === null) {
      this.showToast('docker.web.noSession');
      return;
    }
    const scheme: string = session.scheme === 'https' ? 'https' : 'http';
    const url: string = scheme + '://' + session.host + ':' + String(port.host);
    this.webUrl = url;
    this.webLabel = item.name.length > 0 ? item.name + ' · ' + url : url;
    this.webLoadError = false;
    this.webCtl = new webview.WebviewController();
    this.showWeb = true;
  }

  private closeWeb(): void {
    this.showWeb = false;
    this.webUrl = '';
    this.webLoadError = false;
  }

  showToast(key: string): void {
    this.toastText = t(key, this.lang);
    this.toastVisible = true;
    setTimeout(() => {
      this.toastVisible = false;
    }, 2200);
  }

  openRemoveDialog(item: ContainerInfo): void {
    this.dialog = 'remove';
    this.activeItem = item;
  }

  closeDialog(): void {
    this.dialog = '';
    this.activeItem = null;
  }

  /** 启停容器（真实调用；以列表状态变化为准，失败如实提示）。 */
  async toggleContainer(item: ContainerInfo): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const start: boolean = item.status !== 'running';
    const result: OpResult = await NasRepository.containerAction(item.id, start ? 'start' : 'stop',
      item.ctype);
    this.busy = false;
    if (result.ok) {
      this.showToast(start ? 'docker.started' : 'docker.stopped');
    } else {
      this.showToast('docker.op.failed');
    }
    await this.load();
  }

  /** 重启容器。 */
  async restartContainer(item: ContainerInfo): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const result: OpResult = await NasRepository.containerAction(item.id, 'restart', item.ctype);
    this.busy = false;
    if (result.ok) {
      this.showToast('docker.restarted');
    } else {
      this.showToast('docker.op.failed');
    }
    await this.load();
  }

  /** 删除容器（真实 DELETE，以列表消失为准）。 */
  async removeConfirmed(): Promise<void> {
    if (this.busy || this.activeItem === null) {
      return;
    }
    this.busy = true;
    const target: ContainerInfo = this.activeItem;
    const result: OpResult = await NasRepository.removeContainer(target.id, true);
    this.busy = false;
    this.closeDialog();
    if (result.ok) {
      this.showToast('docker.removed');
    } else {
      this.showToast('docker.op.failed');
    }
    await this.load();
  }

  openImageRemoveDialog(item: ImageInfo): void {
    this.imageTarget = item;
    this.dialog = 'removeImage';
  }

  /** 删除镜像：以镜像列表里真的消失为成功判据，完成后立即回刷。 */
  async removeImageConfirmed(): Promise<void> {
    if (this.busy || this.imageTarget === null) {
      return;
    }
    this.busy = true;
    const result: OpResult = await NasRepository.removeImage(this.imageTarget);
    this.busy = false;
    this.dialog = '';
    this.imageTarget = null;
    if (result.ok) {
      this.showToast('docker.image.removed');
    } else if (result.status === -4) {
      this.showToast('docker.image.inUse');
    } else {
      this.showToast('docker.image.removeFailed');
    }
    await this.load();
  }

  /** 某个镜像当前承载的容器数（由真实容器列表推导，不显示假 0）。 */
  countForImage(item: ImageInfo): number {
    let count = 0;
    const full: string = item.name + ':' + item.tag;
    for (const c of this.containers) {
      if (c.image === full || c.image === item.name) {
        count++;
      }
    }
    return count;
  }

  /** 容器卡上的「运行/停止」文案。 */
  private runningText(item: ContainerInfo): string {
    if (item.status === 'running') {
      return t('storage.running', this.lang);
    }
    if (item.status === 'paused') {
      return t('docker.paused', this.lang);
    }
    return t('storage.stopped', this.lang);
  }

  /**
   * 由真实启动时间推出「运行 X 天 / 小时 / 分钟」。
   * 只对运行中的容器展示；设备未上报 startedAt 时返回空串（宁可不显示也不写假值）。
   */
  uptimeText(item: ContainerInfo): string {
    if (item.startedMs <= 0 || item.status !== 'running') {
      return '';
    }
    const minutes: number = Math.floor((Date.now() - item.startedMs) / 60000);
    if (minutes < 1) {
      return t('docker.uptime.just', this.lang);
    }
    if (minutes < 60) {
      return tf('docker.uptime.min', this.lang, String(minutes));
    }
    const hours: number = Math.floor(minutes / 60);
    if (hours < 24) {
      return tf('docker.uptime.hour', this.lang, String(hours));
    }
    return tf('docker.uptime.day', this.lang, String(Math.floor(hours / 24)));
  }

  @Builder
  tabs() {
    Row() {
      this.tabButton(0, 'docker.tab.containers', this.containers.length)
      this.tabButton(1, 'docker.tab.images', this.images.length)
      if (this.tab === 1) {
        Text(t(this.imageManage ? 'docker.image.manageDone' : 'docker.image.manage', this.lang))
          .fontSize(12)
          .fontColor(Theme.PRIMARY)
          .padding({ left: 10, right: 8, top: 8, bottom: 8 })
          .onClick(() => {
            this.imageManage = !this.imageManage;
          })
      }
    }
    .width('100%')
    .padding(4)
    .backgroundColor(Theme.subCardBg(this.theme))
    .borderRadius(14)
    .margin({ bottom: 14 })
  }

  @Builder
  tabButton(index: number, labelKey: string, count: number) {
    Row() {
      Text(t(labelKey, this.lang))
        .fontSize(13)
        .fontWeight(this.tab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.tab === index ? Theme.PRIMARY : Theme.textSecondary(this.theme))
      Text(String(count))
        .fontSize(11)
        .fontColor(this.tab === index ? Theme.PRIMARY : Theme.textSecondary(this.theme))
        .opacity(0.72)
        .margin({ left: 5 })
    }
    .layoutWeight(1)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.tab === index ? Theme.glassBg(this.theme) : Color.Transparent)
    .borderRadius(11)
    .onClick(() => {
      this.tab = index;
    })
  }

  /** 端口展示：有结构化映射时渲染可点击 chip，无映射时保持纯文本空态。 */
  @Builder
  portLinks(item: ContainerInfo) {
    if (item.portBindings.length > 0) {
      Column() {
        Row() {
          Text(t('docker.ports', this.lang))
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.theme))
          Blank()
          Text(t('docker.web.tapHint', this.lang))
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
        }
        .width('100%')

        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
          ForEach(item.portBindings, (p: ContainerPort) => {
            Row() {
              Text(String(p.host) + ':' + String(p.container))
                .fontSize(12)
                .fontColor(Theme.PRIMARY)
              Text('↗')
                .fontSize(11)
                .fontColor(Theme.PRIMARY)
                .margin({ left: 5 })
            }
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .margin({ right: 8, top: 8 })
            .backgroundColor(Theme.primarySoft(this.theme))
            .borderRadius(8)
            .onClick(() => {
              this.openContainerPort(item, p);
            })
          }, (p: ContainerPort) => String(p.host) + ':' + String(p.container) + ':' + p.protocol)
        }
        .width('100%')
      }
      .width('100%')
      .margin({ top: 8 })
      .alignItems(HorizontalAlign.Start)
    } else {
      InfoRow({ label: t('docker.ports', this.lang), value: t('docker.ports.none', this.lang) })
    }
  }

  @Builder
  containerCard(item: ContainerInfo) {
    CardContainer({ glass: true }) {
      Row() {
        Stack() {
          Circle().width(40).height(40).fill(Theme.quietIconBg(this.theme))
          Image($r('app.media.ic_docker')).width(22).height(22).fillColor(Theme.PRIMARY)
        }
        .width(40)
        .height(40)
        Column() {
          Text(item.name.length > 0 ? item.name : item.image)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.theme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(item.image)
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })
        StatusTag({
          text: this.runningText(item),
          tone: item.status === 'running' ? 'success' : 'info'
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 下面四行全部来自 CS 5 真实字段：startedAt / project / portBindings / id
      if (this.uptimeText(item).length > 0) {
        InfoRow({ label: t('docker.uptime', this.lang), value: this.uptimeText(item) })
      }
      if (item.startedMs > 0) {
        InfoRow({ label: t('docker.startedAt', this.lang), value: FormatUtil.dateTime(item.startedMs) })
      }
      if (item.project.length > 0) {
        InfoRow({ label: t('docker.project', this.lang), value: item.project })
      }
      this.portLinks(item)
      InfoRow({ label: t('docker.containerId', this.lang), value: item.shortId })

      Row() {
        Text(t(item.status === 'running' ? 'action.stop' : 'action.start', this.lang))
          .fontSize(12)
          .fontColor(Theme.PRIMARY)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(Theme.primarySoft(this.theme))
          .borderRadius(8)
          .opacity(this.busy ? 0.6 : 1)
          .onClick(() => {
            this.toggleContainer(item);
          })
        Text(t('action.restart', this.lang))
          .fontSize(12)
          .fontColor(Theme.textSecondary(this.theme))
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(Theme.subCardBg(this.theme))
          .borderRadius(8)
          .margin({ left: 8 })
          .opacity(this.busy ? 0.6 : 1)
          .onClick(() => {
            this.restartContainer(item);
          })
        Blank()
        Text(t('action.delete', this.lang))
          .fontSize(12)
          .fontColor(Theme.DANGER)
          .padding({ left: 10, right: 6, top: 7, bottom: 7 })
          .onClick(() => {
            this.openRemoveDialog(item);
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
  }

  @Builder
  imageCard(item: ImageInfo) {
    CardContainer({ glass: true }) {
      Row() {
        Stack() {
          Circle().width(38).height(38).fill(Theme.quietIconBg(this.theme))
          Image($r('app.media.ic_layers')).width(20).height(20).fillColor(Theme.PRIMARY)
        }
        .width(38)
        .height(38)
        Column() {
          Text(item.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.theme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(item.tag)
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })
        StatusTag({
          text: String(this.countForImage(item)),
          tone: this.countForImage(item) > 0 ? 'success' : 'info'
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      InfoRow({ label: t('docker.image.size', this.lang), value: FormatUtil.bytes(item.sizeMB * 1024 * 1024) })
      InfoRow({ label: t('common.modified', this.lang), value: FormatUtil.shortDate(item.created) })
      InfoRow({ label: t('docker.container', this.lang), value: String(this.countForImage(item)) })
      if (this.imageManage) {
        Row() {
          Blank()
          Text(t(item.inUse || this.countForImage(item) > 0 ? 'docker.image.inUse' : 'action.delete', this.lang))
            .fontSize(12)
            .fontColor(item.inUse || this.countForImage(item) > 0 ? Theme.textSecondary(this.theme) : Theme.DANGER)
            .padding({ left: 12, right: 4, top: 7, bottom: 7 })
            .opacity(item.inUse || this.countForImage(item) > 0 ? 0.65 : 1)
            .onClick(() => {
              if (!item.inUse && this.countForImage(item) === 0) {
                this.openImageRemoveDialog(item);
              }
            })
        }
        .width('100%')
        .margin({ top: 4 })
      }
    }
  }

  @Builder
  contentGrid() {
    GridRow({ columns: BreakpointSystem.contentColumns(this.bp) }) {
      if (this.tab === 0) {
        ForEach(this.containers, (item: ContainerInfo) => {
          GridCol({ span: 1 }) {
            Column() {
              this.containerCard(item)
            }
            .width('100%')
            .padding({ left: 5, right: 5, bottom: 10 })
          }
        }, (item: ContainerInfo) => item.id)
      } else {
        ForEach(this.images, (item: ImageInfo) => {
          GridCol({ span: 1 }) {
            Column() {
              this.imageCard(item)
            }
            .width('100%')
            .padding({ left: 5, right: 5, bottom: 10 })
          }
        }, (item: ImageInfo) => item.id + item.tag)
      }
    }
    .width('100%')
  }

  /** 未安装 Container Station：给出明确成因与后续动作，而不是一片空白。 */
  @Builder
  notInstalledView() {
    Column() {
      Stack() {
        Circle().width(76).height(76).fill(Theme.warningSoft(this.theme))
        Image($r('app.media.ic_docker')).width(34).height(34).fillColor(Theme.WARNING)
      }
      .width(76)
      .height(76)
      .margin({ bottom: 16 })

      Text(t('docker.notInstalled.title', this.lang))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.theme))
        .textAlign(TextAlign.Center)
      Text(t('docker.notInstalled.desc', this.lang))
        .fontSize(12)
        .lineHeight(19)
        .fontColor(Theme.textSecondary(this.theme))
        .textAlign(TextAlign.Center)
        .margin({ top: 8, left: 24, right: 24 })

      Column() {
        Text(t('docker.notInstalled.step1', this.lang))
          .fontSize(12)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ bottom: 6 })
        Text(t('docker.notInstalled.step2', this.lang))
          .fontSize(12)
          .fontColor(Theme.textSecondary(this.theme))
      }
      .width('100%')
      .padding(14)
      .backgroundColor(Theme.subCardBg(this.theme))
      .borderRadius(12)
      .margin({ top: 18 })
      .alignItems(HorizontalAlign.Start)

      Button(t('action.refresh', this.lang), { type: ButtonType.Capsule })
        .fontSize(14)
        .fontColor(Theme.buttonPrimaryFg(this.theme))
        .backgroundColor(Theme.buttonPrimaryBg(this.theme))
        .borderRadius(20)
        .height(38)
        .padding({ left: 26, right: 26 })
        .margin({ top: 20 })
        .onClick(() => {
          this.load();
        })
    }
    .width('100%')
    .padding({ top: 28, bottom: 12 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 网关在但 Bearer 失效：明确提示重新登录，而不是谎报「未安装」。 */
  @Builder
  unauthorizedView() {
    Column() {
      Stack() {
        Circle().width(68).height(68).fill(Theme.warningSoft(this.theme))
        Image($r('app.media.ic_docker')).width(30).height(30).fillColor(Theme.WARNING)
      }
      .width(68)
      .height(68)
      .margin({ bottom: 14 })

      Text(t('docker.session.title', this.lang))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.theme))
        .textAlign(TextAlign.Center)
      Text(t('docker.session.desc', this.lang))
        .fontSize(12)
        .lineHeight(19)
        .fontColor(Theme.textSecondary(this.theme))
        .textAlign(TextAlign.Center)
        .margin({ top: 8, left: 20, right: 20 })

      Button(t('action.refresh', this.lang), { type: ButtonType.Capsule })
        .fontSize(14)
        .fontColor(Theme.buttonPrimaryFg(this.theme))
        .backgroundColor(Theme.buttonPrimaryBg(this.theme))
        .borderRadius(20)
        .height(38)
        .padding({ left: 26, right: 26 })
        .margin({ top: 18 })
        .onClick(() => {
          this.load();
        })
    }
    .width('100%')
    .padding({ top: 28, bottom: 12 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 删除确认：容器与镜像共用一层，按 dialog 类型选择真实操作。 */
  @Builder
  dialogCard() {
    Column() {
      Text(t(this.dialog === 'removeImage' ? 'docker.image.remove.confirm' : 'docker.remove.confirm', this.lang))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.theme))
        .width('100%')

      if (this.dialog === 'removeImage') {
        if (this.imageTarget !== null) {
          Text(tf('docker.image.remove.desc', this.lang,
            this.imageTarget.name + ':' + this.imageTarget.tag))
            .fontSize(13)
            .lineHeight(20)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 14 })
            .width('100%')
        }
      } else if (this.activeItem !== null) {
        Text(tf('docker.remove.desc', this.lang, this.activeItem.name))
          .fontSize(13)
          .lineHeight(20)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 14 })
          .width('100%')
      }

      Row() {
        Button(t('action.cancel', this.lang), { type: ButtonType.Capsule })
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor(Theme.buttonGhostFg(this.theme))
          .backgroundColor(Theme.buttonGhostBg(this.theme))
          .borderRadius(10)
          .onClick(() => {
            if (this.dialog === 'removeImage') {
              this.imageTarget = null;
            }
            this.closeDialog();
          })
        Button(this.busy ? t('state.working', this.lang) : t('action.delete', this.lang),
          { type: ButtonType.Capsule })
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor(Theme.buttonPrimaryFg(this.theme))
          .backgroundColor(Theme.buttonDangerBg(this.theme))
          .borderRadius(10)
          .margin({ left: 10 })
          .enabled(!this.busy)
          .opacity(this.busy ? 0.7 : 1)
          .onClick(() => {
            if (this.dialog === 'removeImage') {
              this.removeImageConfirmed();
            } else {
              this.removeConfirmed();
            }
          })
      }
      .width('100%')
      .margin({ top: 20 })
    }
    .width('100%')
    .padding(20)
    .backgroundColor(Theme.glassBg(this.theme))
    .backgroundBlurStyle(Theme.glassBlur())
    .border({ width: 1, color: Theme.glassBorder(this.theme) })
    .borderRadius(20)
    .shadow(Theme.cardShadow(this.theme))
    .alignItems(HorizontalAlign.Start)
  }

  /** 容器 Web 应用全屏层：沿用登录页 WebView 遮罩模式，顶部显示真实目标地址。 */
  @Builder
  webLayer() {
    Column() {
      Row() {
        Text(t('docker.web.title', this.lang))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
          .layoutWeight(1)
        Text(t('login.web.close', this.lang))
          .fontSize(14)
          .fontColor(Theme.PRIMARY)
          .padding({ left: 12, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.closeWeb();
          })
      }
      .width('100%')
      .height(50)
      .padding({ left: 16, right: 12 })
      .backgroundColor(Theme.cardBg(this.theme))
      .alignItems(VerticalAlign.Center)

      Text(this.webLabel)
        .fontSize(11)
        .fontColor(Theme.textSecondary(this.theme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .backgroundColor(Theme.cardBg(this.theme))

      if (this.webLoadError) {
        Column() {
          Image($r('app.media.ic_warning'))
            .width(34)
            .height(34)
            .fillColor(Theme.DANGER)
          Text(t('docker.web.error', this.lang))
            .fontSize(13)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 12 })
          Button(t('docker.web.retry', this.lang), { type: ButtonType.Capsule })
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
            // 只响应主文档错误：子资源失败不该让整个容器页面不可用
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

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        PageHeader({
          title: t('docker.title', this.lang),
          subtitle: t('docker.subtitle', this.lang),
          showAction: true,
          actionLabel: t('action.refresh', this.lang),
          onAction: () => {
            this.load();
          }
        })
        ToastBar({ text: this.toastText, visible: this.toastVisible })

        Refresh({ refreshing: $$this.refreshing, offset: 80, friction: 42 }) {
          Scroll() {
            Column() {
              if (this.state === LoadState.LOADING && !this.refreshing) {
                StateView({ state: LoadState.LOADING })
              } else if (this.unauthorized) {
                this.unauthorizedView()
              } else if (!this.installed && this.state === LoadState.EMPTY) {
                // 明确区分「未安装」与「已安装但为空」
                this.notInstalledView()
              } else if (this.state === LoadState.SUCCESS) {
                this.tabs()
                if ((this.tab === 0 && this.containers.length === 0) ||
                  (this.tab === 1 && this.images.length === 0)) {
                  StateView({
                    state: LoadState.EMPTY,
                    compact: true,
                    emptyTitleKey: this.tab === 0 ? 'docker.empty.containers' : 'docker.empty.images',
                    emptyDescKey: 'docker.empty.containers.desc',
                    showEmptyAction: true,
                    onEmptyAction: () => {
                      this.load();
                    }
                  })
                } else {
                  this.contentGrid()
                }
              } else {
                StateView({
                  state: this.state,
                  onRetry: () => {
                    this.load();
                  },
                  onGoSettings: () => {
                    this.load();
                  }
                })
              }
            }
            .width('100%')
            .padding({ bottom: 20 })
            .alignItems(HorizontalAlign.Start)
          }
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
        .backgroundColor('#66000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 24, right: 24 })
      }

      if (this.showWeb) {
        this.webLayer()
      }
    }
    .width('100%')
    .height('100%')
  }
}
