import { AppConstants } from '../common/constants/AppConstants';
import { Theme } from '../common/constants/Theme';
import { t } from '../common/i18n/I18n';
import {
  LegalSection, legalSections, legalTitle, legalUpdatedText
} from '../common/legal/LegalDocuments';

/**
 * 隐私政策 / 服务条款全屏阅读层。
 *
 * 直接叠加在登录页与「我的」页之上，不依赖网络：
 * 审核人员与用户在离线状态下也能读完整文本，避免"链接打不开"型驳回。
 */
@Component
export struct LegalSheet {
  @Prop kind: string = 'privacy';
  @Prop lang: string = 'zh';
  @Prop theme: string = 'system';
  onClose: () => void = () => {};

  build() {
    Column() {
      Row() {
        Text(legalTitle(this.kind, this.lang))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.theme))
          .layoutWeight(1)
        Text('×')
          .fontSize(24)
          .fontColor(Theme.textSecondary(this.theme))
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .accessibilityText(t('action.close', this.lang))
          .onClick(() => this.onClose())
      }
      .width('100%')
      .height(52)
      .alignItems(VerticalAlign.Center)

      Text(legalUpdatedText(this.kind, this.lang, AppConstants.BUILD_DATE))
        .fontSize(11)
        .fontColor(Theme.textSecondary(this.theme))
        .width('100%')
        .margin({ bottom: 12 })

      Scroll() {
        Column() {
          ForEach(legalSections(this.kind, this.lang), (section: LegalSection, index: number) => {
            Column() {
              Text(section.heading)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.theme))
                .width('100%')
                .margin({ bottom: 6 })
              ForEach(section.paragraphs, (paragraph: string, pIndex: number) => {
                Text(paragraph)
                  .fontSize(12)
                  .lineHeight(20)
                  .fontColor(Theme.textSecondary(this.theme))
                  .width('100%')
                  .margin({ bottom: 8 })
              }, (paragraph: string, pIndex: number) => section.heading + String(pIndex))
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .border({ width: { bottom: 1 }, color: Theme.divider(this.theme) })
          }, (section: LegalSection, index: number) => section.heading + String(index))
        }
        .width('100%')
        .padding({ bottom: 18 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Button(t('action.close', this.lang), { type: ButtonType.Capsule })
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontColor(Theme.buttonPrimaryFg(this.theme))
        .backgroundColor(Theme.buttonPrimaryBg(this.theme))
        .margin({ top: 8 })
        .onClick(() => this.onClose())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 20 })
    .backgroundColor(Theme.pageBg(this.theme))
  }
}
