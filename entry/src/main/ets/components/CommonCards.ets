import { Theme } from '../common/constants/Theme';
import { BreakpointSystem } from '../common/utils/BreakpointSystem';

/**
 * 通用 UI 组件库（HarmonyOS 7 素雅版）。
 *
 * 语言、主题、断点通过 @StorageProp 订阅 AppStorage：
 * - 设置页切换语言 / 深浅色后所有界面自动刷新；
 * - 窗口尺寸变化（平板横竖屏、2in1 自由窗口）后圆角、内边距、字号自动适配；
 * 无需在组件树中逐层透传参数。
 *
 * 视觉约定：白色卡片 + 1px 极淡描边 + 无投影；系统蓝只用于可交互元素。
 */

@Component
export struct PageHeader {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop actionLabel: string = '';
  @Prop showAction: boolean = false;
  @StorageProp('appTheme') theme: string = 'system';
  @StorageProp('breakpoint') bp: string = 'sm';
  onAction: () => void = () => {
  };

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(BreakpointSystem.titleSize(this.bp))
          .fontWeight(BreakpointSystem.isWide(this.bp) ? FontWeight.Medium : FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.theme))
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ top: 5 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.showAction) {
        // 素雅：次级文字按钮 + 细描边，不用大面积高饱和填充。
        Row() {
          Image($r('app.media.ic_refresh'))
            .width(15)
            .height(15)
            .fillColor(Theme.PRIMARY)
          Text(this.actionLabel)
            .fontSize(12)
            .fontColor(Theme.PRIMARY)
            .margin({ left: 6 })
        }
        .height(34)
        .padding({ left: 13, right: 13 })
        .borderRadius(17)
        .backgroundColor(Theme.cardBg(this.theme))
        .border({ width: 1, color: Theme.hairline(this.theme) })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.onAction();
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: 2, right: 2,
      top: BreakpointSystem.isWide(this.bp) ? 10 : 6,
      bottom: BreakpointSystem.isWide(this.bp) ? 22 : 14
    })
  }
}

@Component
export struct CardContainer {
  @StorageProp('appTheme') theme: string = 'system';
  @StorageProp('breakpoint') bp: string = 'sm';
  /** 0 表示按断点自动取值；>0 时用于紧凑列表等特殊场景。 */
  @Prop paddingValue: number = 0;
  /** 是否启用鸿蒙7 雾玻璃材质（半透明 + 系统模糊 + 柔和投影）。 */
  @Prop glass: boolean = false;
  @Builder
  defaultContent() {
    Column() {
    }
  }

  @BuilderParam content: () => void = this.defaultContent;

  resolvedPadding(): number {
    return this.paddingValue > 0 ? this.paddingValue : BreakpointSystem.cardPadding(this.bp);
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .padding(this.resolvedPadding())
    .borderRadius(BreakpointSystem.cardRadius(this.bp))
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: BreakpointSystem.contentGap(this.bp) })
    .backgroundColor(this.glass ? Theme.glassBg(this.theme) : Theme.cardBg(this.theme))
    .border({ width: 1, color: this.glass ? Theme.glassBorder(this.theme) : Theme.hairline(this.theme) })
    // 鸿蒙 7 雾玻璃：组分模糊 + 半透明底 + 1px 冷灰描边 + 大半径浅投影。
    .backgroundBlurStyle(this.glass ? Theme.glassBlur() : BlurStyle.NONE)
    .shadow(this.glass
      ? Theme.cardShadow(this.theme)
      : { radius: 0, color: Color.Transparent, offsetY: 0 })
  }
}

@Component
export struct SectionTitle {
  @Prop text: string = '';
  @Prop trailing: string = '';
  @StorageProp('appTheme') theme: string = 'system';
  @StorageProp('breakpoint') bp: string = 'sm';
  onTrailing: () => void = () => {
  };

  build() {
    Row() {
      Text(this.text)
        .fontSize(BreakpointSystem.isWide(this.bp) ? 16 : 15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.theme))
        .layoutWeight(1)
      if (this.trailing.length > 0) {
        Text(this.trailing)
          .fontSize(12)
          .fontColor(Theme.PRIMARY)
          .onClick(() => {
            this.onTrailing();
          })
      }
    }
    .width('100%')
    .margin({
      top: BreakpointSystem.isWide(this.bp) ? 26 : 18,
      bottom: BreakpointSystem.isWide(this.bp) ? 14 : 10
    })
  }
}

@Component
export struct ProgressBar {
  @Prop percent: number = 0;
  @Prop barColor: string = Theme.PRIMARY;
  @StorageProp('appTheme') theme: string = 'system';

  build() {
    Row() {
      Column()
        .width(this.percent + '%')
        .height(5)
        .borderRadius(3)
        .backgroundColor(this.barColor)
      Column()
        .layoutWeight(1)
    }
    .width('100%')
    .height(5)
    .borderRadius(3)
    .backgroundColor(Theme.isDark(this.theme) ? '#2E343D' : '#EEF1F4')
  }
}

@Component
export struct StatusTag {
  @Prop text: string = '';
  @Prop tone: string = 'success';
  @StorageProp('appTheme') theme: string = 'system';

  build() {
    Text(this.text)
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.tagForeground(this.tone))
      .backgroundColor(Theme.tagBackground(this.tone, this.theme))
      .borderRadius(8)
      .padding({ left: 9, right: 9, top: 3, bottom: 3 })
  }
}

@Component
export struct MetricTile {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop percent: number = 0;
  @Prop barColor: string = Theme.INK_BLUE;
  @Prop glass: boolean = false;
  icon: Resource = $r('app.media.ic_cpu');
  @StorageProp('appTheme') theme: string = 'system';
  @StorageProp('breakpoint') bp: string = 'sm';

  build() {
    Column() {
      Row() {
        Image(this.icon)
          .width(17)
          .height(17)
          .fillColor(Theme.iconTint(this.theme))
        Text(this.label)
          .fontSize(12)
          .fontColor(Theme.textSecondary(this.theme))
          .margin({ left: 8 })
          .layoutWeight(1)
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.value)
        .fontSize(BreakpointSystem.isWide(this.bp) ? 28 : 24)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.theme))
        .margin({ top: 14, bottom: 14 })

      ProgressBar({ percent: this.percent, barColor: this.barColor })
    }
    .width('100%')
    .padding(BreakpointSystem.cardPadding(this.bp))
    .borderRadius(BreakpointSystem.cardRadius(this.bp))
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.glass ? Theme.glassBg(this.theme) : Theme.cardBg(this.theme))
    .border({ width: 1, color: this.glass ? Theme.glassBorder(this.theme) : Theme.hairline(this.theme) })
    // 鸿蒙 7 雾玻璃：组分模糊 + 半透明底 + 1px 冷灰描边 + 大半径浅投影。
    .backgroundBlurStyle(this.glass ? Theme.glassBlur() : BlurStyle.NONE)
    .shadow(this.glass
      ? Theme.cardShadow(this.theme)
      : { radius: 0, color: Color.Transparent, offsetY: 0 })
  }
}

@Component
export struct InfoRow {
  @Prop label: string = '';
  @Prop value: string = '';
  @StorageProp('appTheme') theme: string = 'system';

  build() {
    Row() {
      Text(this.label)
        .fontSize(13)
        .fontColor(Theme.textSecondary(this.theme))
        .layoutWeight(1)
      Text(this.value)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.theme))
        .maxLines(2)
        .textAlign(TextAlign.End)
        .constraintSize({ maxWidth: '62%' })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }
}

@Component
export struct SettingRow {
  icon: Resource = $r('app.media.ic_settings');
  @Prop title: string = '';
  @Prop desc: string = '';
  @Prop value: string = '';
  @Prop showToggle: boolean = false;
  @Prop toggleValue: boolean = false;
  @Prop showArrow: boolean = true;
  @Prop showDivider: boolean = true;
  @StorageProp('appTheme') theme: string = 'system';
  onItemClick: () => void = () => {
  };
  onToggle: (value: boolean) => void = () => {
  };

  build() {
    Column() {
      Row() {
        Image(this.icon)
          .width(19)
          .height(19)
          .fillColor(Theme.iconTint(this.theme))
          .margin({ right: 12 })
        Column() {
          Text(this.title)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.theme))
          if (this.desc.length > 0) {
            Text(this.desc)
              .fontSize(11)
              .fontColor(Theme.textSecondary(this.theme))
              .margin({ top: 3 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.value.length > 0) {
          Text(this.value)
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.theme))
            .margin({ right: 6 })
        }
        if (this.showToggle) {
          Toggle({ type: ToggleType.Switch, isOn: this.toggleValue })
            .width(42)
            .height(24)
            .selectedColor(Theme.PRIMARY)
            .switchPointColor('#FFFFFF')
            .onChange((isOn: boolean) => {
              this.onToggle(isOn);
            })
        } else if (this.showArrow) {
          Image($r('app.media.ic_chevron'))
            .width(16)
            .height(16)
            .fillColor(Theme.textSecondary(this.theme))
        }
      }
      .width('100%')
      .padding({ top: 13, bottom: 13 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.onItemClick();
      })

      if (this.showDivider) {
        Column()
          .width('100%')
          .height(1)
          .backgroundColor(Theme.divider(this.theme))
      }
    }
    .width('100%')
  }
}

@Component
export struct ToastBar {
  @Prop text: string = '';
  @Prop visible: boolean = false;

  build() {
    if (this.visible && this.text.length > 0) {
      Row() {
        Image($r('app.media.ic_check'))
          .width(17)
          .height(17)
          .fillColor('#FFFFFF')
        Text(this.text)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .margin({ left: 8 })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .backgroundColor('#2A3038')
      .borderRadius(14)
      .shadow({ radius: 12, color: 'rgba(20,32,58,0.18)', offsetY: 4 })
      .margin({ bottom: 2 })
      .alignItems(VerticalAlign.Center)
    }
  }
}
