import { PageTab } from '../common/constants/AppConstants';
import { Theme } from '../common/constants/Theme';
import { BreakpointSystem } from '../common/utils/BreakpointSystem';
import { t } from '../common/i18n/I18n';
import { HomePage } from '../feature/home/HomePage';
import { FilesPage } from '../feature/files/FilesPage';
import { DockerPage } from '../feature/docker/DockerPage';
import { SettingsPage } from '../feature/settings/SettingsPage';

interface TabDef {
  tab: number;
  icon: Resource;
  key: string;
}

interface NavGroup {
  labelKey: string;
  items: TabDef[];
}

/**
 * 多设备自适应外壳（HarmonyOS 7 大屏范式）。
 *
 * - 四个业务页面统一放入 Swiper，支持左右滑动切换；
 * - 手机端底栏是一条**悬浮的雾玻璃圆角长条**：半透明底 + 系统模糊 + 可见淡描边 +
 *   柔和投影，选中项带胶囊高亮，页面内容在其下方继续滚动，形成真正的「悬浮」层次；
 * - 平板 / 2in1 走分组侧栏 + 雾玻璃顶栏，与底部导航索引双向同步；
 * - 「存储」不再作为独立入口，容量 / 卷 / 磁盘 / 服务信息统一在「我的」页面查看。
 */
@Component
export struct AdaptiveShell {
  @StorageProp('breakpoint') bp: string = 'sm';
  @StorageProp('appLanguage') lang: string = 'zh';
  @StorageProp('appTheme') theme: string = 'system';
  @Prop activeTab: number = 0;
  @Prop deviceName: string = 'QNAP-NAS';
  onTabChange: (tab: number) => void = () => {
  };
  onNavigate: (tab: number) => void = () => {
  };
  /** Swiper 控制器：ArkTS 中 Swiper 构造参数须为 SwiperController；索引切换走 .index() 属性（响应式）。 */
  private swiperController: SwiperController = new SwiperController();

  /** 统一导航入口：更新 activeTab（驱动 Swiper 的 index 属性切换页面）。 */
  goTo(tab: number): void {
    this.onTabChange(tab);
  }

  /** 侧栏按「概览 / 管理 / 系统」三组组织，避免平板上一长串无层级列表。 */
  groups(): NavGroup[] {
    const list: NavGroup[] = [
      {
        labelKey: 'nav.group.overview',
        items: [{ tab: PageTab.HOME, icon: $r('app.media.ic_home'), key: 'nav.home' }]
      },
      {
        labelKey: 'nav.group.manage',
        items: [
          { tab: PageTab.FILES, icon: $r('app.media.ic_folder'), key: 'nav.files' },
          { tab: PageTab.DOCKER, icon: $r('app.media.ic_docker'), key: 'nav.docker' }
        ]
      },
      {
        labelKey: 'nav.group.system',
        items: [{ tab: PageTab.PROFILE, icon: $r('app.media.ic_person'), key: 'nav.profile' }]
      }
    ];
    return list;
  }

  flatTabs(): TabDef[] {
    const groups: NavGroup[] = this.groups();
    const list: TabDef[] = [];
    for (const g of groups) {
      for (const item of g.items) {
        list.push(item);
      }
    }
    return list;
  }

  @Builder
  groupLabel(labelKey: string) {
    Text(t(labelKey, this.lang))
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.textSecondary(this.theme))
      .margin({ left: 16, top: 20, bottom: 7 })
  }

  @Builder
  sideTabItem(item: TabDef) {
    Row() {
      Column()
        .width(3)
        .height(18)
        .borderRadius(2)
        .backgroundColor(this.activeTab === item.tab ? Theme.PRIMARY : Color.Transparent)
      Image(item.icon)
        .width(19)
        .height(19)
        .fillColor(this.activeTab === item.tab ? Theme.PRIMARY : Theme.iconTint(this.theme))
        .margin({ left: 13 })
      Text(t(item.key, this.lang))
        .fontSize(14)
        .fontWeight(this.activeTab === item.tab ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === item.tab ? Theme.PRIMARY : Theme.textPrimary(this.theme))
        .margin({ left: 12 })
        .layoutWeight(1)
        .maxLines(1)
    }
    .width('100%')
    .height(44)
    .borderRadius(11)
    .backgroundColor(this.activeTab === item.tab ? Theme.primarySoft(this.theme) : Color.Transparent)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.goTo(item.tab);
    })
  }

  /* ---------- 手机端：悬浮雾玻璃底栏 ---------- */

  @Builder
  floatingTabItem(item: TabDef) {
    Column() {
      Image(item.icon)
        .width(21)
        .height(21)
        .fillColor(this.activeTab === item.tab ? Theme.PRIMARY : Theme.iconTint(this.theme))
      Text(t(item.key, this.lang))
        .fontSize(10)
        .fontWeight(this.activeTab === item.tab ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === item.tab ? Theme.PRIMARY : Theme.textSecondary(this.theme))
        .margin({ top: 3 })
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(48)
    .justifyContent(FlexAlign.Center)
    .borderRadius(16)
    .backgroundColor(this.activeTab === item.tab ? Theme.barActiveBg(this.theme) : Color.Transparent)
    .onClick(() => {
      this.goTo(item.tab);
    })
  }

  /**
   * 悬浮底栏：左右各留 16vp 让长条「浮」起来，底部留 12vp 承接手势区。
   * 外层面板只负责定位与留白，真正的毛玻璃材质在内层的圆角长条上，
   * 这样模糊采样的是页面渐变底而不是整块屏幕。
   */
  @Builder
  floatingTabBar() {
    Row() {
      Row() {
        ForEach(this.flatTabs(), (item: TabDef) => {
          this.floatingTabItem(item)
        }, (item: TabDef) => 'ftab-' + String(item.tab))
      }
      .layoutWeight(1)
      .height(Theme.BAR_HEIGHT)
      .padding({ left: 6, right: 6, top: 7, bottom: 7 })
      .backgroundColor(Theme.barBg(this.theme))
      .borderRadius(Theme.BAR_RADIUS)
      .border({ width: 1, color: Theme.barBorder(this.theme) })
      .backgroundBlurStyle(Theme.glassBlur(this.theme))
      .shadow(Theme.floatingShadow(this.theme))
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  /* ---------- 平板 / 2in1：分组侧栏 + 雾玻璃顶栏 ---------- */

  @Builder
  sideBar() {
    Column() {
      // 品牌区：中性底 + 线性图标，取代高饱和实心色块。
      Row() {
        Stack() {
          Circle().width(38).height(38).fill(Theme.quietIconBg(this.theme))
          Image($r('app.media.ic_storage'))
            .width(21)
            .height(21)
            .fillColor(Theme.PRIMARY)
        }
        .width(38)
        .height(38)
        Column() {
          Text(t('app.name', this.lang))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.theme))
            .maxLines(1)
          Text(t('app.tagline', this.lang))
            .fontSize(10)
            .fontColor(Theme.textSecondary(this.theme))
            .maxLines(1)
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 11 })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 26, bottom: 24 })

      ForEach(this.groups(), (group: NavGroup) => {
        this.groupLabel(group.labelKey)
        ForEach(group.items, (item: TabDef) => {
          this.sideTabItem(item)
        }, (item: TabDef) => 'side-' + String(item.tab))
      }, (group: NavGroup) => 'group-' + group.labelKey)

      Column() {
        Row() {
          Circle().width(7).height(7).fill(Theme.SUCCESS)
          Text(this.deviceName)
            .fontSize(12)
            .fontColor(Theme.textPrimary(this.theme))
            .margin({ left: 9 })
            .layoutWeight(1)
            .maxLines(1)
          Text(t('common.online', this.lang))
            .fontSize(11)
            .fontColor(Theme.textSecondary(this.theme))
        }
        .width('100%')
        .padding(14)
        .backgroundColor(Theme.subCardBg(this.theme))
        .borderRadius(14)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 20 })
    }
    .width(BreakpointSystem.sideBarWidth(this.bp))
    .height('100%')
    .backgroundColor(Theme.chromeBg(this.theme))
    .backgroundBlurStyle(Theme.glassBlur(this.theme))
    .border({ width: { right: 1 }, color: Theme.chromeBorder(this.theme) })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  iconAction(icon: Resource, target: number, label: string) {
    Stack() {
      Circle().width(36).height(36).fill(Theme.quietIconBg(this.theme))
      Image(icon).width(18).height(18).fillColor(Theme.iconTint(this.theme))
    }
    .width(36)
    .height(36)
    .margin({ left: 10 })
    .accessibilityText(label)
    .onClick(() => {
      if (target >= 0) {
        this.goTo(target);
      }
    })
  }

  /** 顶部应用栏：仅平板 / 2in1 显示，承载设备切换、全局搜索与账号入口。 */
  @Builder
  topBar() {
    Row() {
      Row() {
        Circle().width(7).height(7).fill(Theme.SUCCESS)
        Text(t('nav.device.current', this.lang))
          .fontSize(11)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ left: 8 })
        Text(this.deviceName)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
          .margin({ left: 6 })
          .maxLines(1)
      }
      .height(34)
      .padding({ left: 13, right: 13 })
      .backgroundColor(Theme.cardBg(this.theme))
      .borderRadius(17)
      .alignItems(VerticalAlign.Center)

      Column()
        .layoutWeight(1)

      Row() {
        Image($r('app.media.ic_search'))
          .width(16)
          .height(16)
          .fillColor(Theme.textSecondary(this.theme))
        Text(t('nav.search.hint', this.lang))
          .fontSize(12)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ left: 9 })
          .maxLines(1)
      }
      .width(BreakpointSystem.isExtraWide(this.bp) ? 300 : 230)
      .height(36)
      .padding({ left: 13, right: 13 })
      .backgroundColor(Theme.cardBg(this.theme))
      .border({ width: 1, color: Theme.hairline(this.theme) })
      .borderRadius(18)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.goTo(PageTab.FILES);
      })

      this.iconAction($r('app.media.ic_bell'), -1, t('nav.notification', this.lang))
      this.iconAction($r('app.media.ic_person'), PageTab.PROFILE, t('nav.account', this.lang))
    }
    .width('100%')
    .height(BreakpointSystem.topBarHeight(this.bp))
    .padding({ left: BreakpointSystem.pagePadding(this.bp), right: BreakpointSystem.pagePadding(this.bp) })
    .backgroundColor(Theme.chromeBg(this.theme))
    .backgroundBlurStyle(Theme.glassBlur(this.theme))
    .border({ width: { bottom: 1 }, color: Theme.chromeBorder(this.theme) })
    .alignItems(VerticalAlign.Center)
  }

  /** 四个业务页面全部进入 Swiper，支持左右滑动切换。
   *  页面内部自行承担滚动（各自带 Scroll），这里不再套 Scroll ——
   *  嵌套滚动会让页面的 height('100%') 失去确定值，是此前内容区显示为空的成因之一。 */
  @Builder
  pagedContent() {
    Swiper(this.swiperController) {
      HomePage({ onNavigate: (tab: number) => this.goTo(tab) })
      FilesPage()
      DockerPage()
      SettingsPage()
    }
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ maxWidth: BreakpointSystem.maxContentWidth(this.bp) })
    .alignSelf(ItemAlign.Center)
    .indicator(false)
    .loop(false)
    .disableSwipe(false)
    .index(this.activeTab)
    .onChange((index: number) => {
      if (index !== this.activeTab) {
        this.onTabChange(index);
      }
    })
  }

  build() {
    if (BreakpointSystem.isWide(this.bp)) {
      // 平板 / 2in1：分组侧栏 + 顶部应用栏 + 渐变底上居中限宽的 Swiper 内容区。
      Column() {
        Row() {
          this.sideBar()
          Column() {
            this.topBar()
            this.pagedContent()
          }
          .layoutWeight(1)
          .height('100%')
          .alignItems(HorizontalAlign.Center)
          .linearGradient({
            angle: 135,
            colors: Theme.pageGradientColors(this.theme)
          })
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .height('100%')
      .linearGradient({
        angle: 135,
        colors: Theme.pageGradientColors(this.theme)
      })
    } else {
      // 手机：内容铺满，悬浮雾玻璃底栏叠在内容之上（内容底部预留其高度）。
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          this.pagedContent()
        }
        .width('100%')
        .height('100%')
        .padding({ bottom: Theme.BAR_HEIGHT + 22 })

        this.floatingTabBar()
      }
      .width('100%')
      .height('100%')
      .linearGradient({
        angle: 135,
        colors: Theme.pageGradientColors(this.theme)
      })
    }
  }
}
