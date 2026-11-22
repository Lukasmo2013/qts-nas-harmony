import { LoadState, PageTab } from '../../common/constants/AppConstants';
import { Theme } from '../../common/constants/Theme';
import { t, tf } from '../../common/i18n/I18n';
import { BreakpointSystem } from '../../common/utils/BreakpointSystem';
import { FormatUtil } from '../../common/utils/FormatUtil';
import { FileNameUtil } from '../../common/utils/FileNameUtil';
import { validateFolderName } from '../../common/utils/Validators';
import { FileItem, OpResult } from '../../model/Models';
import { NasRepository } from '../../service/NasRepository';
import { QnapApi } from '../../service/QnapApi';
import { TransferManager, TransferState, TransferTask } from '../../service/TransferManager';
import { CardContainer, InfoRow, PageHeader, SectionTitle, ToastBar } from '../../components/CommonCards';
import { StateView } from '../../components/StateView';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';

interface LocationDef {
  path: string;
  label: string;
  icon: Resource;
}

/**
 * 文件浏览与管理模块。
 *
 * 数据来源为设备真实的 File Station 6：
 *   - 左侧位置栏 = 设备上真实存在的共享目录（privRequest 共享名单 + 逐个探测）；
 *   - 列表 = GET /FileStation6/utilRequest.cgi?func=get_list&path=<共享路径>；
 *   - 新建 / 重命名 / 删除 = POST 同名 CGI（createdir / rename / delete），
 *     真机实测 status=1 为成功；失败时如实报错，不做乐观更新。
 *
 * 状态区分：空目录 / 路径不存在 / 无共享目录 / 请求失败 分别渲染，不混为一谈。
 */
@Component
export struct FilesPage {
  @StorageProp('appLanguage') lang: string = 'zh';
  @StorageProp('appTheme') theme: string = 'system';
  @StorageProp('breakpoint') bp: string = 'sm';
  @State state: string = LoadState.LOADING;
  @State currentPath: string = '';
  /** 设备上真实存在的共享目录（如 /Public、/Container）。 */
  @State shares: string[] = [];
  /** 当前空态的文案键：空目录 / 路径不存在 / 无共享目录 分别区分。 */
  @State emptyTitleKey: string = 'files.empty.title';
  @State emptyDescKey: string = 'files.empty.desc';
  @State items: FileItem[] = [];
  @State allItems: FileItem[] = [];
  @State keyword: string = '';
  @State sortBy: string = 'name';
  @State viewMode: string = 'list';
  @State selectMode: boolean = false;
  @State selectedIds: string[] = [];
  @State dialog: string = '';
  @State inputText: string = '';
  @State inputError: string = '';
  @State activeItem: FileItem | null = null;
  @State toastText: string = '';
  @State toastVisible: boolean = false;
  /** 写操作进行中：避免重复提交，也让按钮呈现禁用态。 */
  @State busy: boolean = false;
  /** 下拉刷新状态：重新拉取当前目录，结束后归位。 */
  @State refreshing: boolean = false;
  /** 跨页深链：由「我的」页相册卡片设置，进入时定位到指定目录。 */
  @State pendingDeepLink: string = '';
  /**
   * 与 AppStorage 双向绑定的深链键。Swiper 在启动时就挂载了文件页，
   * aboutToAppear 只跑一次，因此「我的」页晚些时候写入的深链必须由 @Watch 捕获，
   * 否则点到相册卡片后文件页不会跳转目录。
   */
  @StorageLink('filesDeepLink') @Watch('onDeepLink') deepLink: string = '';
  /** 新建文件时的文本内容（txt）。 */
  @State newFileContent: string = '';

  /* ---- 后台传输：任务表由 TransferManager 持有，这里只镜像可见状态 ---- */
  @StorageLink('transferTick') @Watch('onTransferTick') transferTick: number = 0;
  @State transferList: TransferTask[] = [];
  @State transferRunning: number = 0;
  @State transferFailed: number = 0;
  @State transferPercent: number = 0;
  /** 已回刷过的最近一次上传完成时间，避免每个 tick 都重复拉列表。 */
  private lastTransferRefreshAt: number = 0;

  /** 传输状态变化时刷新镜像；当前目录有上传完成则立即回刷文件列表。 */
  onTransferTick(): void {
    const tasks: TransferTask[] = TransferManager.list();
    this.transferList = tasks;
    this.transferRunning = TransferManager.runningCount();
    this.transferFailed = TransferManager.failedCount();
    this.transferPercent = TransferManager.activeProgress();

    let newest: number = this.lastTransferRefreshAt;
    let shouldReload: boolean = false;
    for (const task of tasks) {
      if (task.kind === 'upload' && task.state === TransferState.SUCCESS &&
        task.finishedAt > this.lastTransferRefreshAt &&
        this.currentPath.length > 0 && task.target === this.currentPath) {
        shouldReload = true;
        if (task.finishedAt > newest) {
          newest = task.finishedAt;
        }
      }
    }
    if (shouldReload) {
      this.lastTransferRefreshAt = newest;
      if (!this.busy) {
        this.load();
      }
    }
  }

  aboutToAppear(): void {
    const dl: string = (AppStorage.get<string>('filesDeepLink') ?? '');
    if (dl.length > 0) {
      this.pendingDeepLink = dl;
      AppStorage.set('filesDeepLink', '');
    }
    this.onTransferTick();
    this.load();
  }

  /**
   * 深链变化回调：相册卡片在「我的」页写入 filesDeepLink 后触发。
   * 把目标目录放进 pendingDeepLink（load 会优先定位它），并清空键避免重复触发；
   * 若共享目录尚未加载则 load 会先取名单再定位，已加载则直接切目录刷新。
   */
  onDeepLink(): void {
    const path: string = this.deepLink;
    if (path.length === 0) {
      return;
    }
    this.pendingDeepLink = path;
    AppStorage.set('filesDeepLink', '');
    if (!this.busy) {
      this.load();
    }
  }

  async load(): Promise<void> {
    this.state = LoadState.LOADING;
    try {
      // 1) 取共享目录（首次进入时拉取，之后复用设备侧缓存）
      if (this.shares.length === 0) {
        this.shares = await NasRepository.shares();
      }
      if (this.shares.length === 0) {
        this.state = LoadState.EMPTY;
        this.emptyTitleKey = 'files.empty.noshares';
        this.emptyDescKey = 'files.empty.noshares.desc';
        return;
      }
      // 2) 定位当前目录：深链优先；首次进入优先落在「可写」共享上，
      //    因为 QTS 的共享 ACL 可能与可读性无关（本机 /Public 能读能下但只读，写入返回 4）。
      let target: string = this.currentPath;
      if (this.pendingDeepLink.length > 0) {
        target = this.pendingDeepLink;
      } else if (this.currentPath.length === 0) {
        target = await this.defaultPath();
      }
      this.pendingDeepLink = '';
      if (target !== this.currentPath) {
        this.currentPath = target;
      }
      // 3) 拉取真实列表
      const result = await NasRepository.files(this.currentPath);
      this.allItems = result.items;
      this.applyItems(result.items);
      if (!result.valid) {
        // status 5 = 路径不存在或无访问权限；3 = 会话失效；其余为请求异常
        if (result.status === 5) {
          this.state = LoadState.EMPTY;
          this.emptyTitleKey = 'files.empty.notfound';
          this.emptyDescKey = 'files.empty.notfound.desc';
        } else if (result.status === 3) {
          this.state = LoadState.NO_PERMISSION;
        } else {
          this.state = LoadState.ERROR;
        }
        return;
      }
      this.state = this.items.length === 0 ? LoadState.EMPTY : LoadState.SUCCESS;
      if (this.state === LoadState.EMPTY) {
        this.emptyTitleKey = this.keyword.length > 0 ? 'files.empty.search' : 'files.empty.title';
        this.emptyDescKey = this.keyword.length > 0 ? 'files.empty.search.desc' : 'files.empty.desc';
      }
    } catch (e) {
      this.state = LoadState.ERROR;
    }
  }

  /** 下拉刷新：清缓存后重新向设备要共享名单，再读当前目录（支持新增共享立即出现）。 */
  async doRefresh(): Promise<void> {
    NasRepository.resetShareCache();
    try {
      const fresh: string[] = await NasRepository.shares();
      if (fresh.length > 0) {
        this.shares = fresh;
      }
    } catch (e) {
      // 刷新失败保留旧名单，仍继续刷当前目录。
    }
    await this.load();
    this.refreshing = false;
  }

  /**
   * 首次进入的落地目录：优先第一个**可写**共享（进去就能新建/上传），
   * 没有可写的就退回第一个共享（至少还能浏览与下载）。
   */
  async defaultPath(): Promise<string> {
    const writable: string[] = await NasRepository.writableRoots();
    for (const w of writable) {
      if (this.shares.indexOf(w) >= 0) {
        return w;
      }
    }
    return this.shares[0];
  }

  /** 无共享目录时的重试：清掉探测缓存，重新向设备要一次名单。 */
  async retryShares(): Promise<void> {
    this.shares = [];
    this.currentPath = '';
    QnapApi.resetShareCache();
    await this.load();
  }

  applyItems(source: FileItem[]): void {
    let list: FileItem[] = source.slice();
    if (this.keyword.trim().length > 0) {
      const kw: string = this.keyword.trim().toLowerCase();
      const filtered: FileItem[] = [];
      for (const item of list) {
        if (item.name.toLowerCase().indexOf(kw) >= 0) {
          filtered.push(item);
        }
      }
      list = filtered;
    }
    const sorted: FileItem[] = list.slice();
    sorted.sort((a: FileItem, b: FileItem) => {
      if (a.kind === 'folder' && b.kind !== 'folder') {
        return -1;
      }
      if (a.kind !== 'folder' && b.kind === 'folder') {
        return 1;
      }
      if (this.sortBy === 'size') {
        return b.size - a.size;
      }
      if (this.sortBy === 'time') {
        return b.modified - a.modified;
      }
      return a.name.localeCompare(b.name);
    });
    this.items = sorted;
  }

  showToast(key: string): void {
    this.showToastText(t(key, this.lang));
  }

  /** 直接展示已格式化的文案（带状态码等参数，不能再当 key 去查表）。 */
  showToastText(text: string): void {
    this.toastText = text;
    this.toastVisible = true;
    setTimeout(() => {
      this.toastVisible = false;
    }, 2200);
  }

  /**
   * 上传失败文案映射。
   * 实测设备状态码：4 = 无权限，7 = 目标目录打不开（只读共享），9 = 配额/写入受限。
   * 这几类不是网络问题，明确提示换可写目录，比只抛一个数字有用。
   */
  uploadFailText(status: number): string {
    if (status === 4 || status === 7 || status === 9) {
      return tf('files.upload.denied', this.lang, String(status));
    }
    return tf('files.upload.failed', this.lang, String(status));
  }

  fileIcon(kind: string): Resource {
    if (kind === 'folder') {
      return $r('app.media.ic_folder');
    }
    if (kind === 'image') {
      return $r('app.media.ic_image');
    }
    if (kind === 'video') {
      return $r('app.media.ic_monitor');
    }
    if (kind === 'archive') {
      return $r('app.media.ic_layers');
    }
    return $r('app.media.ic_file');
  }

  itemSubtitle(item: FileItem): string {
    if (item.kind === 'folder') {
      // QTS 不返回子项数量，目录只展示类型与修改时间，不臆造条目数。
      return t('files.folder', this.lang) + ' · ' + FormatUtil.shortDate(item.modified);
    }
    return FormatUtil.bytes(item.size) + ' · ' + FormatUtil.shortDate(item.modified);
  }

  /** 位置栏 = 设备上真实存在的共享目录（名称直接来自设备，不做本地假设）。 */
  locations(): LocationDef[] {
    const list: LocationDef[] = [];
    for (const path of this.shares) {
      list.push({
        path: path,
        label: path.length > 0 && path.charAt(0) === '/' ? path.substring(1) : path,
        icon: $r('app.media.ic_storage')
      });
    }
    return list;
  }

  /** 面包屑展示：/Public/music → Public / music。 */
  pathLabel(): string {
    if (this.currentPath.length === 0) {
      return t('files.root', this.lang);
    }
    const trimmed = this.currentPath.charAt(0) === '/' ? this.currentPath.substring(1) : this.currentPath;
    return trimmed.length === 0 ? t('files.root', this.lang) : trimmed.replace(/\//g, ' / ');
  }

  openPath(path: string): void {
    this.currentPath = path;
    this.selectMode = false;
    this.selectedIds = [];
    this.keyword = '';
    this.load();
  }

  goParent(): void {
    const target: string = this.parentPath();
    if (target.length === 0) {
      // 已位于共享目录根：不再有上级
      return;
    }
    this.openPath(target);
  }

  /** 上一级路径；共享目录根部返回空串，表示没有上级可去。 */
  parentPath(): string {
    const index: number = this.currentPath.lastIndexOf('/');
    return index > 0 ? this.currentPath.substring(0, index) : '';
  }

  canGoUp(): boolean {
    return this.parentPath().length > 0;
  }

  toggleSelect(id: string): void {
    const next: string[] = this.selectedIds.slice();
    const index: number = next.indexOf(id);
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(id);
    }
    this.selectedIds = next;
    if (next.length === 0) {
      this.selectMode = false;
    }
  }

  isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  openDialog(kind: string, item: FileItem | null): void {
    this.dialog = kind;
    this.activeItem = item;
    this.inputText = kind === 'rename' && item !== null ? item.name : '';
    this.newFileContent = '';
    this.inputError = '';
  }

  closeDialog(): void {
    this.dialog = '';
    this.activeItem = null;
    this.inputText = '';
    this.newFileContent = '';
    this.inputError = '';
  }

  /** 执行对话框对应的写操作：全部走真实接口，成功后才刷新列表。 */
  async confirmDialog(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.dialog === 'newFolder' || this.dialog === 'rename') {
      const err: string = validateFolderName(this.inputText);
      if (err.length > 0) {
        this.inputError = t('files.new.folder.hint', this.lang);
        return;
      }
      const name: string = this.inputText.trim();
      this.busy = true;
      let result: OpResult;
      if (this.dialog === 'newFolder') {
        result = await NasRepository.mkdir(this.currentPath, name);
      } else {
        const source: string = this.activeItem !== null ? this.activeItem.name : '';
        result = await NasRepository.renameParent(this.currentPath, source, name);
      }
      this.busy = false;
      if (result.ok) {
        this.showToast(this.dialog === 'newFolder' ? 'files.created' : 'files.renamed');
        this.closeDialog();
        await this.load();
      } else {
        this.inputError = tf('files.op.failed', this.lang, String(result.status));
      }
      return;
    }
    if (this.dialog === 'delete') {
      const names: string[] = this.selectedIds.slice();
      if (names.length === 0) {
        this.closeDialog();
        return;
      }
      this.busy = true;
      const result: OpResult = await NasRepository.remove(this.currentPath, names, true);
      this.busy = false;
      if (result.ok) {
        this.selectMode = false;
        this.selectedIds = [];
        this.showToast('files.deleted');
        this.closeDialog();
        await this.load();
      } else {
        this.showToast('files.op.failed.short');
        this.closeDialog();
      }
      return;
    }
    if (this.dialog === 'newFile') {
      const name: string = this.inputText.trim();
      if (!this.isValidFileName(name)) {
        this.inputError = t('files.new.file.hint', this.lang);
        return;
      }
      this.busy = true;
      const bytes: Uint8Array = QnapApi.strToU8(this.newFileContent);
      const result: OpResult = await NasRepository.uploadFile(this.currentPath, name, bytes, true);
      this.busy = false;
      if (result.ok) {
        this.showToast('files.new.file.created');
        this.closeDialog();
        await this.load();
      } else {
        this.inputError = this.uploadFailText(result.status);
      }
      return;
    }
    this.closeDialog();
  }

  /** 批量删除入口（复制 / 移动依赖 File Station 的异步任务接口，暂不提供假按钮）。 */
  askDelete(): void {
    if (this.selectedIds.length === 0) {
      return;
    }
    this.openDialog('delete', null);
  }

  /** 某条目在当前目录下的完整路径（用于下载）。 */
  fullPath(name: string): string {
    if (this.currentPath === '/') {
      return '/' + name;
    }
    const trimmed = this.currentPath.charAt(this.currentPath.length - 1) === '/'
      ? this.currentPath.substring(0, this.currentPath.length - 1) : this.currentPath;
    return trimmed + '/' + name;
  }

  /**
   * 从 picker 返回的 uri 解析出**原始文件名**。
   * 不能简单截最后一个 `/`：URI 里的中文/空格是百分号编码，相册/文档提供者
   * 还可能返回纯数字 ID。统一交给 FileNameUtil（系统 FileUri + 解码 + 清理）。
   */
  fileNameOfUri(uri: string): string {
    return FileNameUtil.fromUri(uri);
  }

  /** 校验新建文件名：非空且不含路径分隔符。 */
  isValidFileName(name: string): boolean {
    const trimmed = name.trim();
    if (trimmed.length === 0) {
      return false;
    }
    if (trimmed.indexOf('/') >= 0 || trimmed.indexOf('\\') >= 0) {
      return false;
    }
    return true;
  }

  /**
   * 选本地文件 → 入队后台上传。
   *
   * 与旧实现的差别：不再在界面里等整个文件传完（大文件会让页面卡在 busy 态），
   * 只把「目录 + 文件名 + uri」交给 TransferManager，由它在后台按 2MB 分片串行上传，
   * 进度写进任务表，切页甚至锁屏后仍然继续。
   */
  async pickAndUpload(): Promise<void> {
    if (this.busy) {
      return;
    }
    let uris: Array<string> = [];
    try {
      const documentPicker = new picker.DocumentViewPicker();
      uris = await documentPicker.select();
    } catch (e) {
      return;
    }
    if (uris.length === 0) {
      return;
    }
    this.busy = true;
    let queued: number = 0;
    const context = this.getUIContext().getHostContext();
    for (const uri of uris) {
      try {
        // 用系统 FileUri + 媒体库 display_name 取真实文件名，不再拿 URI 末段硬截
        let name: string = await FileNameUtil.resolve(uri, context);
        if (name.length === 0 || FileNameUtil.isIdLike(name)) {
          name = FileNameUtil.fallback(uri, queued, '');
        }
        let sizeHint: number = 0;
        try {
          const probe = fs.openSync(uri, fs.OpenMode.READ_ONLY);
          try {
            sizeHint = fs.statSync(probe.fd).size;
          } finally {
            fs.closeSync(probe);
          }
        } catch (e) {
          sizeHint = 0;
        }
        TransferManager.enqueueUploadFromUri(this.currentPath, name, uri, sizeHint);
        queued++;
      } catch (e) {
        this.showToast('files.upload.failed');
      }
    }
    this.busy = false;
    this.onTransferTick();
    if (queued > 0) {
      this.showToastText(tf('files.transfer.queued', this.lang, String(queued)));
    }
  }

  /**
   * 下载当前选中的文件到本机：先用系统选择器确定保存位置（这一步必须在 UI 上下文做），
   * 再把「远端路径 + 保存 uri」交给 TransferManager 在后台取字节并落盘。
   */
  async downloadActive(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.activeItem === null) {
      // 工具栏的下载按钮在未选中条目时也要给出明确反馈，而不是「点了没反应」。
      this.showToast('files.download.pick');
      return;
    }
    const item: FileItem = this.activeItem;
    if (item.kind === 'folder') {
      this.showToast('files.download.none');
      return;
    }
    this.busy = true;
    let saveUri: string = '';
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const uris: Array<string> = await documentPicker.save({ newFileNames: [item.name] });
      if (uris.length === 0) {
        this.busy = false;
        return;
      }
      saveUri = uris[0];
    } catch (e) {
      this.busy = false;
      this.showToast('files.download.failed');
      return;
    }
    this.busy = false;
    TransferManager.enqueueDownload(this.fullPath(item.name), saveUri, item.name, item.size);
    this.onTransferTick();
    this.showToastText(tf('files.transfer.queued', this.lang, '1'));
  }

  /**
   * 顶部传输条：有任务在跑或有失败任务时出现，点「查看」打开传输管理面板。
   * 任务本体在 TransferManager 里跑，离开本页也继续。
   */
  @Builder
  transferBar() {
    if (this.transferRunning > 0 || this.transferFailed > 0) {
      Row() {
        Image($r('app.media.ic_upload'))
          .width(15)
          .height(15)
          .fillColor(this.transferFailed > 0 && this.transferRunning === 0 ? Theme.DANGER : Theme.PRIMARY)
        Column() {
          Text(this.transferRunning > 0
            ? tf('files.transfer.summary', this.lang, String(this.transferRunning))
            : tf('files.transfer.failedCount', this.lang, String(this.transferFailed)))
            .fontSize(12)
            .fontColor(Theme.textPrimary(this.theme))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.transferRunning > 0) {
            Progress({ value: this.transferPercent, total: 100, type: ProgressType.Linear })
              .height(3)
              .width('100%')
              .margin({ top: 4 })
              .color(this.transferFailed > 0 ? Theme.DANGER : Theme.PRIMARY)
          }
        }
        .layoutWeight(1)
        .margin({ left: 8 })
        .alignItems(HorizontalAlign.Start)

        Text(t('files.transfer.open', this.lang))
          .fontSize(12)
          .fontColor(Theme.PRIMARY)
          .padding({ left: 10 })
          .onClick(() => {
            this.openDialog('transfer', null);
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(Theme.cardBg(this.theme))
      .border({ width: 1, color: Theme.hairline(this.theme) })
      .borderRadius(12)
      .margin({ top: 9 })
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 传输面板里的单条任务。 */
  @Builder
  transferRow(task: TransferTask) {
    Column() {
      Row() {
        Text(task.kind === 'upload' ? t('files.upload', this.lang) : t('files.download', this.lang))
          .fontSize(9)
          .fontColor('#FFFFFF')
          .backgroundColor(task.kind === 'upload' ? Theme.PRIMARY : Theme.textSecondary(this.theme))
          .borderRadius(4)
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
        Text(task.name)
          .fontSize(13)
          .fontColor(Theme.textPrimary(this.theme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: 6 })
        Text(this.transferStateText(task))
          .fontSize(10)
          .fontColor(task.state === 'failed' ? Theme.DANGER
            : task.state === 'success' ? Theme.SUCCESS : Theme.textSecondary(this.theme))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (task.state === TransferState.RUNNING || task.state === TransferState.QUEUED) {
        Progress({
          value: task.size > 0 ? Math.floor(task.done * 100 / task.size) : 0,
          total: 100, type: ProgressType.Linear
        })
          .height(3)
          .width('100%')
          .margin({ top: 6 })
          .color(Theme.PRIMARY)
      }

      Row() {
        Text(FormatUtil.bytes(task.done) + ' / ' + FormatUtil.bytes(task.size))
          .fontSize(10)
          .fontColor(Theme.textSecondary(this.theme))
          .layoutWeight(1)
        if (task.state === TransferState.RUNNING || task.state === TransferState.QUEUED) {
          Text(t('files.transfer.cancel', this.lang))
            .fontSize(11)
            .fontColor(Theme.DANGER)
            .onClick(() => {
              TransferManager.cancel(task.id);
              this.onTransferTick();
            })
        } else if (task.state === TransferState.FAILED && task.kind === 'upload') {
          Text(t('files.transfer.retry', this.lang))
            .fontSize(11)
            .fontColor(Theme.PRIMARY)
            .onClick(() => {
              TransferManager.retry(task.id);
              this.onTransferTick();
            })
        }
      }
      .width('100%')
      .margin({ top: 4 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(10)
    .backgroundColor(Theme.subCardBg(this.theme))
    .borderRadius(10)
    .margin({ bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 任务状态文案：失败时把设备状态码带上，便于直接判断是权限(4/7)还是网络。 */
  transferStateText(task: TransferTask): string {
    if (task.state === TransferState.FAILED) {
      return t('files.transfer.state.failed', this.lang) + ' (' + String(task.status) + ')';
    }
    if (task.state === TransferState.SUCCESS) {
      return t('files.transfer.state.success', this.lang);
    }
    if (task.state === TransferState.CANCELED) {
      return t('files.transfer.state.canceled', this.lang);
    }
    if (task.state === TransferState.RUNNING) {
      return t('files.transfer.state.running', this.lang);
    }
    return t('files.transfer.state.queued', this.lang);
  }

  @Builder
  fileToolbar() {
    Row() {
      Row() {
        Image($r('app.media.ic_search'))
          .width(15)
          .height(15)
          .fillColor(Theme.textSecondary(this.theme))
        TextInput({ placeholder: t('files.search.hint', this.lang), text: this.keyword })
          .layoutWeight(1)
          .height(36)
          .fontSize(13)
          .fontColor(Theme.textPrimary(this.theme))
          .placeholderColor(Theme.textSecondary(this.theme))
          .caretColor(Theme.PRIMARY)
          .backgroundColor(Color.Transparent)
          .padding({ left: 8, right: 4 })
          .onChange((text: string) => {
            this.keyword = text;
            this.applyItems(this.allItems);
          })
      }
      .layoutWeight(1)
      .height(38)
      .padding({ left: 11, right: 8 })
      .backgroundColor(Theme.cardBg(this.theme))
      .border({ width: 1, color: Theme.hairline(this.theme) })
      .borderRadius(19)
      .alignItems(VerticalAlign.Center)

      this.toolButton($r('app.media.ic_grid'), this.viewMode === 'grid', () => {
        this.viewMode = this.viewMode === 'list' ? 'grid' : 'list';
      })
      this.toolButton($r('app.media.ic_sort'), this.sortBy !== 'name', () => {
        this.sortBy = this.sortBy === 'name' ? 'size' : this.sortBy === 'size' ? 'time' : 'name';
        this.applyItems(this.allItems);
        this.showToast(this.sortBy === 'name' ? 'files.sort.name'
          : this.sortBy === 'size' ? 'files.sort.size' : 'files.sort.time');
      })
      // 宽屏横向空间充足：写操作沿用圆形图标按钮，保持与其它页一致的视觉密度。
      if (BreakpointSystem.isWide(this.bp)) {
        this.toolButton($r('app.media.ic_folder_add'), false, () => {
          this.openDialog('newFolder', null);
        })
        this.toolButton($r('app.media.ic_file'), false, () => {
          this.openDialog('newFile', null);
        })
        this.toolButton($r('app.media.ic_upload'), false, () => {
          this.pickAndUpload();
        })
        this.toolButton($r('app.media.ic_download'), false, () => {
          this.downloadActive();
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 窄屏的写操作条：新建文件夹 / 新建文件 / 上传 / 下载 四个带文字的标签按钮。
   *
   * 此前这些操作只以 18px 纯图标挤在搜索框右侧，手机上一是认不出含义、二是宽度
   * 不够被压缩，用户直接反馈「文件页没有上传、下载功能」。带文字单独成行后，
   * 入口一眼可见，也避免与搜索框抢宽度。
   */
  @Builder
  actionRow() {
    if (!BreakpointSystem.isWide(this.bp)) {
      Row() {
        this.actionChip($r('app.media.ic_folder_add'), 'files.new.folder', () => {
          this.openDialog('newFolder', null);
        })
        this.actionChip($r('app.media.ic_file'), 'files.new.file', () => {
          this.openDialog('newFile', null);
        })
        this.actionChip($r('app.media.ic_upload'), 'files.upload', () => {
          this.pickAndUpload();
        })
        this.actionChip($r('app.media.ic_download'), 'files.download', () => {
          this.downloadActive();
        })
      }
      .width('100%')
      .margin({ top: 9 })
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 带文字的操作按钮（窄屏写操作条）。 */
  @Builder
  actionChip(icon: Resource, labelKey: string, action: () => void) {
    Row() {
      Image(icon)
        .width(15)
        .height(15)
        .fillColor(Theme.iconTint(this.theme))
      Text(t(labelKey, this.lang))
        .fontSize(12)
        .fontColor(Theme.textPrimary(this.theme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 5 })
    }
    .layoutWeight(1)
    .height(34)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Theme.cardBg(this.theme))
    .border({ width: 1, color: Theme.hairline(this.theme) })
    .borderRadius(17)
    .margin({ right: 6 })
    .onClick(() => {
      action();
    })
  }

  @Builder
  toolButton(icon: Resource, active: boolean, action: () => void) {
    Stack() {
      Circle()
        .width(38)
        .height(38)
        .fill(active ? Theme.primarySoft(this.theme) : Theme.cardBg(this.theme))
      Image(icon)
        .width(18)
        .height(18)
        .fillColor(active ? Theme.PRIMARY : Theme.iconTint(this.theme))
    }
    .width(38)
    .height(38)
    .margin({ left: 8 })
    .border({ width: active ? 0 : 1, color: Theme.hairline(this.theme) })
    .borderRadius(19)
    .onClick(() => {
      action();
    })
  }

  /**
   * 路径栏：常驻的「返回上一层」+ 当前位置 + 计数/全选。
   *
   * 「返回上一层」必须始终可见、可点：此前只在列表非空时渲染面包屑，
   * 一旦进入空目录或搜索无结果，整页只剩空态，用户就被困在子目录里出不来。
   * 因此该按钮做成带文字与点击区域的胶囊，而不是一个 18px 的小箭头。
   */
  @Builder
  breadcrumb() {
    Column() {
      Row() {
        if (this.canGoUp()) {
          Row() {
            Image($r('app.media.ic_chevron_left'))
              .width(14)
              .height(14)
              .fillColor(Theme.PRIMARY)
            Text(t('files.up', this.lang))
              .fontSize(12)
              .fontColor(Theme.PRIMARY)
              .margin({ left: 2 })
          }
          .height(32)
          .padding({ left: 8, right: 12 })
          .backgroundColor(Theme.primarySoft(this.theme))
          .borderRadius(16)
          .margin({ right: 9 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.goParent();
          })
        }

        Row() {
          Image($r('app.media.ic_folder'))
            .width(13)
            .height(13)
            .fillColor(Theme.textSecondary(this.theme))
          Text(this.pathLabel())
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.theme))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 6 })
        }
        .layoutWeight(1)
        .height(32)
        .padding({ left: 10, right: 10 })
        .backgroundColor(Theme.glassBg(this.theme))
        .border({ width: 1, color: Theme.hairline(this.theme) })
        .borderRadius(16)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Text(tf('common.count', this.lang, String(this.items.length)))
          .fontSize(11)
          .fontColor(Theme.textSecondary(this.theme))
        Blank()
        Text(this.selectMode ? t('action.cancelSelect', this.lang) : t('files.select.all', this.lang))
          .fontSize(12)
          .fontColor(Theme.PRIMARY)
          .onClick(() => {
            if (this.selectMode) {
              this.selectMode = false;
              this.selectedIds = [];
            } else {
              this.selectMode = true;
              const all: string[] = [];
              for (const item of this.items) {
                all.push(item.id);
              }
              this.selectedIds = all;
            }
          })
      }
      .width('100%')
      .margin({ top: 7 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: 10, bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  bulkBar() {
    if (this.selectMode) {
      Row() {
        Text(tf('action.selected', this.lang, String(this.selectedIds.length)))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
          .layoutWeight(1)
        Text(t('action.cancelSelect', this.lang))
          .fontSize(12)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ right: 14 })
          .onClick(() => {
            this.selectMode = false;
            this.selectedIds = [];
          })
        Text(t('action.delete', this.lang))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.DANGER)
          .onClick(() => {
            this.askDelete();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(Theme.primarySoft(this.theme))
      .borderRadius(10)
      .margin({ bottom: 8 })
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  fileRow(item: FileItem) {
    Row() {
      if (this.selectMode) {
        Image(this.isSelected(item.id) ? $r('app.media.ic_check') : $r('app.media.ic_add'))
          .width(18)
          .height(18)
          .fillColor(this.isSelected(item.id) ? Theme.PRIMARY : Theme.textSecondary(this.theme))
          .margin({ right: 10 })
      }
      Stack() {
        Circle().width(40).height(40).fill(Theme.quietIconBg(this.theme))
        Image(this.fileIcon(item.kind))
          .width(20)
          .height(20)
          .fillColor(Theme.PRIMARY)
      }
      .width(40)
      .height(40)

      Column() {
        Text(item.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.itemSubtitle(item))
          .fontSize(11)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 4 })
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })

      Image($r('app.media.ic_more'))
        .width(18)
        .height(18)
        .fillColor(Theme.textSecondary(this.theme))
        .accessibilityText(t('action.properties', this.lang) + ' ' + item.name)
        .onClick(() => {
          this.openDialog('properties', item);
        })
    }
    .width('100%')
    .padding({ top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.selectMode) {
        this.toggleSelect(item.id);
      } else if (item.kind === 'folder') {
        this.openPath(this.childPath(item.name));
      } else {
        this.openDialog('properties', item);
      }
    })
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          this.selectMode = true;
          this.toggleSelect(item.id);
        })
    )
  }

  /** 子条目路径：共享根为 /Public 时拼成 /Public/music。 */
  childPath(name: string): string {
    if (this.currentPath === '/') {
      return '/' + name;
    }
    const trimmed = this.currentPath.charAt(this.currentPath.length - 1) === '/'
      ? this.currentPath.substring(0, this.currentPath.length - 1) : this.currentPath;
    return trimmed + '/' + name;
  }

  @Builder
  fileGridTile(item: FileItem) {
    Column() {
      Stack() {
        Circle().width(48).height(48).fill(Theme.quietIconBg(this.theme))
        Image(this.fileIcon(item.kind)).width(25).height(25).fillColor(Theme.PRIMARY)
      }
      .width(48)
      .height(48)
      Text(item.name)
        .fontSize(12)
        .fontColor(Theme.textPrimary(this.theme))
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .margin({ top: 10 })
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.glassBg(this.theme))
    .border({ width: 1, color: Theme.glassBorder(this.theme) })
    .backgroundBlurStyle(Theme.glassBlur())
    .borderRadius(14)
    .onClick(() => {
      if (this.selectMode) {
        this.toggleSelect(item.id);
      } else if (item.kind === 'folder') {
        this.openPath(this.childPath(item.name));
      } else {
        this.openDialog('properties', item);
      }
    })
  }

  @Builder
  fileList() {
    if (this.viewMode === 'grid') {
      GridRow({ columns: BreakpointSystem.isWide(this.bp) ? 4 : 3 }) {
        ForEach(this.items, (item: FileItem) => {
          GridCol({ span: 1 }) {
            Column() {
              this.fileGridTile(item)
            }
            .width('100%')
            .padding({ left: 4, right: 4, bottom: 8 })
          }
        }, (item: FileItem) => item.id)
      }
      .width('100%')
    } else {
      CardContainer({ paddingValue: 6, glass: true }) {
        ForEach(this.items, (item: FileItem) => {
          Column() {
            this.fileRow(item)
            if (this.items.indexOf(item) < this.items.length - 1) {
              Column().width('100%').height(1).backgroundColor(Theme.divider(this.theme))
            }
          }
          .width('100%')
          .padding({ left: 10, right: 10 })
        }, (item: FileItem) => item.id)
      }
    }
  }

  @Builder
  locationSideBar() {
    CardContainer({ glass: true }) {
      SectionTitle({ text: t('files.directories', this.lang) })
      ForEach(this.locations(), (item: LocationDef) => {
        Row() {
          Image(item.icon).width(17).height(17).fillColor(Theme.iconTint(this.theme))
          Text(item.label)
            .fontSize(13)
            .fontColor(this.currentPath === item.path ? Theme.PRIMARY : Theme.textPrimary(this.theme))
            .margin({ left: 10 })
            .layoutWeight(1)
            .maxLines(1)
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 11, bottom: 11 })
        .backgroundColor(this.currentPath === item.path ? Theme.primarySoft(this.theme) : Color.Transparent)
        .borderRadius(9)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.openPath(item.path);
        })
      }, (item: LocationDef) => item.path)
    }
  }

  @Builder
  locationChips() {
    Scroll() {
      Row() {
        ForEach(this.locations(), (item: LocationDef) => {
          Text(item.label)
            .fontSize(12)
            .fontColor(this.currentPath === item.path ? '#FFFFFF' : Theme.textSecondary(this.theme))
            .backgroundColor(this.currentPath === item.path ? Theme.PRIMARY : Theme.glassBg(this.theme))
            .border({ width: 1, color: this.currentPath === item.path ? Theme.PRIMARY : Theme.glassBorder(this.theme) })
            .borderRadius(16)
            .padding({ left: 13, right: 13, top: 7, bottom: 7 })
            .margin({ right: 8 })
            .onClick(() => {
              this.openPath(item.path);
            })
        }, (item: LocationDef) => item.path)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ bottom: 4 })
  }

  @Builder
  dialogCard() {
    Column() {
      Text(this.dialog === 'newFolder' ? t('files.new.folder', this.lang)
        : this.dialog === 'newFile' ? t('files.new.file', this.lang)
          : this.dialog === 'rename' ? t('action.rename', this.lang)
            : this.dialog === 'delete' ? t('files.confirm.delete', this.lang)
              : this.dialog === 'transfer' ? t('files.transfer.title', this.lang)
                : t('files.properties.title', this.lang))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.theme))
        .width('100%')

      if (this.dialog === 'newFolder' || this.dialog === 'rename' || this.dialog === 'newFile') {
        TextInput({
          placeholder: this.dialog === 'newFile' ? t('files.new.file.hint', this.lang) : t('files.new.folder.hint', this.lang),
          text: this.inputText
        })
          .width('100%')
          .height(44)
          .fontSize(14)
          .caretColor(Theme.PRIMARY)
          .backgroundColor(Theme.subCardBg(this.theme))
          .borderRadius(10)
          .margin({ top: 18 })
          .onChange((text: string) => {
            this.inputText = text;
            this.inputError = '';
          })
        if (this.dialog === 'newFile') {
          TextArea({ placeholder: t('files.new.file.content', this.lang) })
            .width('100%')
            .height(110)
            .fontSize(13)
            .caretColor(Theme.PRIMARY)
            .backgroundColor(Theme.subCardBg(this.theme))
            .borderRadius(10)
            .margin({ top: 10 })
            .onChange((text: string) => {
              this.newFileContent = text;
            })
        }
        if (this.inputError.length > 0) {
          Text(this.inputError)
            .fontSize(11)
            .fontColor(Theme.DANGER)
            .margin({ top: 6 })
            .width('100%')
        }
      } else if (this.dialog === 'delete') {
        Text(tf('files.confirm.delete.desc', this.lang,
          String(this.selectedIds.length) + ' ' + t('common.items', this.lang)))
          .fontSize(13)
          .lineHeight(20)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 14 })
          .width('100%')
        Text(t('files.delete.recycle.tip', this.lang))
          .fontSize(11)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ top: 8 })
          .width('100%')
      } else if (this.dialog === 'transfer') {
        if (this.transferList.length === 0) {
          Text(t('files.transfer.empty', this.lang))
            .fontSize(13)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 18 })
            .width('100%')
        } else {
          Scroll() {
            Column() {
              ForEach(this.transferList, (task: TransferTask) => {
                this.transferRow(task)
              }, (task: TransferTask) => task.id + '_' + task.state + '_' + String(task.done))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .height(300)
          .margin({ top: 12 })
          .scrollBar(BarState.Auto)
          .align(Alignment.Top)
        }
      } else if (this.activeItem !== null) {
        Column() {
          InfoRow({ label: t('common.name', this.lang), value: this.activeItem.name })
          InfoRow({
            label: t('common.type', this.lang),
            value: t(this.activeItem.kind === 'folder' ? 'files.folder' : 'files.file', this.lang)
          })
          InfoRow({ label: t('common.size', this.lang), value: FormatUtil.bytes(this.activeItem.size) })
          InfoRow({ label: t('files.path', this.lang), value: this.currentPath })
          InfoRow({ label: t('files.owner', this.lang), value: this.activeItem.owner })
          InfoRow({ label: t('files.permission', this.lang), value: this.activeItem.permission })
          InfoRow({ label: t('common.modified', this.lang), value: FormatUtil.dateTime(this.activeItem.modified) })
        }
        .width('100%')
        .margin({ top: 10 })
        Row() {
          Text(t('action.rename', this.lang))
            .fontSize(13)
            .fontColor(Theme.PRIMARY)
            .padding({ top: 8, bottom: 8, right: 20 })
            .onClick(() => {
              this.openDialog('rename', this.activeItem);
            })
          if (this.activeItem !== null && this.activeItem.kind !== 'folder') {
            Text(t('action.download', this.lang))
              .fontSize(13)
              .fontColor(Theme.PRIMARY)
              .padding({ top: 8, bottom: 8, right: 20 })
              .onClick(() => {
                this.downloadActive();
                this.closeDialog();
              })
          }
          Text(t('action.delete', this.lang))
            .fontSize(13)
            .fontColor(Theme.DANGER)
            .padding({ top: 8, bottom: 8 })
            .onClick(() => {
              if (this.activeItem !== null) {
                this.selectMode = true;
                this.selectedIds = [this.activeItem.id];
              }
              this.openDialog('delete', null);
            })
        }
        .width('100%')
        .margin({ top: 6 })
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
            this.closeDialog();
          })
        if (this.dialog === 'transfer') {
          Button(t('files.transfer.clear', this.lang), { type: ButtonType.Capsule })
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(Theme.buttonGhostFg(this.theme))
            .backgroundColor(Theme.buttonGhostBg(this.theme))
            .borderRadius(10)
            .margin({ left: 10 })
            .onClick(() => {
              TransferManager.clearFinished();
              this.onTransferTick();
            })
        }
        if (this.dialog !== 'properties' && this.dialog !== 'transfer') {
          Button(this.busy ? t('state.working', this.lang) : t('action.confirm', this.lang),
            { type: ButtonType.Capsule })
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(Theme.buttonPrimaryFg(this.theme))
            .backgroundColor(this.dialog === 'delete' ? Theme.buttonDangerBg(this.theme)
              : Theme.buttonPrimaryBg(this.theme))
            .borderRadius(10)
            .margin({ left: 10 })
            .enabled(!this.busy)
            .opacity(this.busy ? 0.7 : 1)
            .onClick(() => {
              this.confirmDialog();
            })
        }
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

  /** 成功态主体：宽屏两栏（位置栏 + 列表），窄屏单栏。 */
  @Builder
  browseContent() {
    Column() {
      if (!BreakpointSystem.isWide(this.bp)) {
        this.locationChips()
        this.breadcrumb()
        this.bulkBar()
        if (this.items.length === 0) {
          StateView({
            state: LoadState.EMPTY,
            compact: true,
            emptyTitleKey: this.emptyTitleKey,
            emptyDescKey: this.emptyDescKey,
            showEmptyAction: this.emptyTitleKey === 'files.empty.title',
            onEmptyAction: () => {
              this.openDialog('newFolder', null);
            }
          })
        } else {
          this.fileList()
        }
      } else {
        Row() {
          Column() {
            this.locationSideBar()
          }
          .width(200)
          .padding({ right: 14 })
          .alignItems(HorizontalAlign.Start)

          Column() {
            this.breadcrumb()
            this.bulkBar()
            if (this.items.length === 0) {
              StateView({
                state: LoadState.EMPTY,
                compact: true,
                emptyTitleKey: this.emptyTitleKey,
                emptyDescKey: this.emptyDescKey,
                showEmptyAction: this.emptyTitleKey === 'files.empty.title',
                onEmptyAction: () => {
                  this.openDialog('newFolder', null);
                }
              })
            } else {
              this.fileList()
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        PageHeader({
          title: t('files.title', this.lang),
          subtitle: t('files.subtitle', this.lang),
          showAction: true,
          actionLabel: t('action.refresh', this.lang),
          onAction: () => {
            this.load();
          }
        })
        ToastBar({ text: this.toastText, visible: this.toastVisible })
        this.fileToolbar()
        this.actionRow()
        this.transferBar()

        // 下拉刷新 + 内容区独立滚动：手势由 Refresh 提供，列表高度仍由 layoutWeight 决定。
        Refresh({ refreshing: $$this.refreshing, offset: 80, friction: 42 }) {
          Scroll() {
            Column() {
            if (this.state === LoadState.SUCCESS) {
              this.browseContent()
            } else if (this.state === LoadState.LOADING && this.refreshing) {
              // 下拉刷新期间保留旧列表，避免闪烁成整页 loading。
            } else {
              // 非成功态（空目录 / 路径不存在 / 会话失效 / 请求失败）同样保留位置与返回入口，
              // 否则用户进入空文件夹后就再也退不出去。
              if (this.shares.length > 0 && this.currentPath.length > 0) {
                this.locationChips()
                this.breadcrumb()
              }
              if (this.emptyTitleKey === 'files.empty.noshares' && this.state === LoadState.EMPTY) {
                StateView({
                  state: LoadState.EMPTY,
                  emptyTitleKey: this.emptyTitleKey,
                  emptyDescKey: this.emptyDescKey,
                  showEmptyAction: true,
                  onEmptyAction: () => {
                    this.retryShares();
                  }
                })
              } else {
                StateView({
                  state: this.state,
                  emptyTitleKey: this.emptyTitleKey,
                  emptyDescKey: this.emptyDescKey,
                  showEmptyAction: this.state === LoadState.EMPTY &&
                    this.emptyTitleKey === 'files.empty.title',
                  onEmptyAction: () => {
                    this.openDialog('newFolder', null);
                  },
                  onRetry: () => {
                    this.load();
                  },
                  onGoSettings: () => {
                    this.load();
                  }
                })
              }
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
    }
    .width('100%')
    .height('100%')
  }
}
