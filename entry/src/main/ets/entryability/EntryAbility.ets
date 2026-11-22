import { UIAbility, Want, AbilityConstant, Configuration } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { AppConstants } from '../common/constants/AppConstants';

/**
 * 应用入口 Ability。
 * 除加载首页外，负责把系统深浅色模式同步到 AppStorage，供「跟随系统」主题使用。
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate<number>(
      AppConstants.APP_STORAGE_SYSTEM_COLOR,
      Number(this.context.config.colorMode)
    );
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    AppStorage.setOrCreate<number>(
      AppConstants.APP_STORAGE_SYSTEM_COLOR,
      Number(newConfig.colorMode)
    );
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 显式指定窗口底色为中性浅灰：
    // 页面内的雾玻璃（backgroundBlurStyle）会采样窗口背景，若沿用系统默认底色，
    // 设备主题色 / 壁纸的暖黄色会透过模糊层给整个界面染上黄调。
    windowStage.getMainWindow()
      .then((mainWindow: window.Window) => {
        mainWindow.setWindowBackgroundColor('#F4F5F6');
      })
      .catch(() => {
        // 取不到主窗口时忽略，交由页面自身的渐变底兜底
      });
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error('QnapNas: loadContent failed, code=' + err.code);
      }
    });
  }

  onWindowStageDestroy(): void {
  }

  onForeground(): void {
  }

  onBackground(): void {
  }
}
