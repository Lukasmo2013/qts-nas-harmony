import { LoadState } from '../common/constants/AppConstants';
import { t } from '../common/i18n/I18n';
import { Theme } from '../common/constants/Theme';

/**
 * 统一异常 / 加载态视图。
 * 覆盖：加载中、空数据、加载错误、网络异常、权限不足。
 * 所有业务页面只负责计算 LoadState，展示与操作入口在此集中处理。
 */
@Component
export struct StateView {
  @Prop state: string = LoadState.LOADING;
  @StorageProp('appLanguage') lang: string = 'zh';
  @StorageProp('appTheme') theme: string = 'system';
  @Prop compact: boolean = false;
  @Prop emptyTitleKey: string = 'state.empty.title';
  @Prop emptyDescKey: string = 'state.empty.desc';
  showEmptyAction: boolean = false;
  onRetry: () => void = () => {
  };
  onGoSettings: () => void = () => {
  };
  onEmptyAction: () => void = () => {
  };

  @Builder
  loadingBody() {
    Column() {
      LoadingProgress()
        .width(44)
        .height(44)
        .color(Theme.PRIMARY)
      Text(t('state.loading.title', this.lang))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.theme))
        .margin({ top: 16 })
      Text(t('state.loading.desc', this.lang))
        .fontSize(12)
        .fontColor(Theme.textSecondary(this.theme))
        .margin({ top: 6 })
      if (!this.compact) {
        this.skeletonRow()
        this.skeletonRow()
        this.skeletonRow()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  skeletonRow() {
    Row() {
      Column()
        .width(40)
        .height(40)
        .borderRadius(10)
        .backgroundColor(Theme.subCardBg(this.theme))
      Column() {
        Column().width('70%').height(12).borderRadius(6).backgroundColor(Theme.subCardBg(this.theme))
        Column().width('45%').height(10).borderRadius(5).backgroundColor(Theme.subCardBg(this.theme)).margin({ top: 8 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
    }
    .width('80%')
    .margin({ top: 14 })
  }

  @Builder
  statePlaceholder(icon: Resource, title: string, desc: string, actionKey: string, tone: string,
              action: () => void) {
    Column() {
      Stack() {
        Circle()
          .width(76)
          .height(76)
          .fill(tone === 'danger' ? Theme.dangerSoft(this.theme)
            : tone === 'warning' ? Theme.warningSoft(this.theme) : Theme.primarySoft(this.theme))
        Image(icon)
          .width(34)
          .height(34)
          .fillColor(tone === 'danger' ? Theme.DANGER
            : tone === 'warning' ? Theme.WARNING : Theme.PRIMARY)
      }
      .width(76)
      .height(76)
      .margin({ bottom: 16 })

      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.theme))
        .textAlign(TextAlign.Center)
      Text(desc)
        .fontSize(12)
        .lineHeight(19)
        .fontColor(Theme.textSecondary(this.theme))
        .textAlign(TextAlign.Center)
        .margin({ top: 8, left: 24, right: 24 })

      Button(actionKey, { type: ButtonType.Capsule })
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.buttonPrimaryFg(this.theme))
        .backgroundColor(Theme.buttonPrimaryBg(this.theme))
        .borderRadius(20)
        .height(36)
        .padding({ left: 24, right: 24 })
        .margin({ top: 20 })
        .onClick(() => {
          action();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      if (this.state === LoadState.LOADING) {
        this.loadingBody()
      } else if (this.state === LoadState.EMPTY) {
        this.statePlaceholder(
          $r('app.media.ic_empty_box'),
          t(this.emptyTitleKey, this.lang),
          t(this.emptyDescKey, this.lang),
          this.showEmptyAction ? t('state.empty.action', this.lang) : t('state.retry', this.lang),
          'primary',
          this.showEmptyAction ? this.onEmptyAction : this.onRetry
        )
      } else if (this.state === LoadState.ERROR) {
        this.statePlaceholder(
          $r('app.media.ic_warning'), t('state.error.title', this.lang),
          t('state.error.desc', this.lang), t('state.retry', this.lang), 'danger', this.onRetry
        )
      } else if (this.state === LoadState.NO_NETWORK) {
        this.statePlaceholder(
          $r('app.media.ic_wifi_off'), t('state.noNetwork.title', this.lang),
          t('state.noNetwork.desc', this.lang), t('state.retry', this.lang), 'warning', this.onRetry
        )
      } else if (this.state === LoadState.NO_PERMISSION) {
        this.statePlaceholder(
          $r('app.media.ic_lock'), t('state.noPermission.title', this.lang),
          t('state.noPermission.desc', this.lang), t('state.go.settings', this.lang),
          'warning', this.onGoSettings
        )
      }
    }
    .width('100%')
    .height(this.compact ? 260 : 340)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
