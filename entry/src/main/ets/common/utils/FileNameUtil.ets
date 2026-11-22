import fileUri from '@ohos.file.fileuri';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import dataSharePredicates from '@ohos.data.dataSharePredicates';
import common from '@ohos.app.ability.common';

/**
 * 统一的「本地文件原始名」解析器。
 *
 * 为什么需要它：HarmonyOS 的 DocumentViewPicker / PhotoViewPicker 返回的是 **URI**，
 * 不是文件名。旧实现直接截取 URI 最后一个 `/` 之后的字符串，会遇到三类问题：
 *   ① URI 中的中文 / 空格是百分号编码（`%E6%88%91%E7%9A%84...`），不解码会原样写到 NAS；
 *   ② 相册 / 文档提供者可能返回纯数字 ID（`.../Photo/12/12345`）而不是显示名；
 *   ③ URI 里带 `?`/`#` 参数、反斜杠、`"`、换行时会截断或破坏 multipart 头。
 * 结果就是「上传成功但 NAS 上的文件名不对」。
 *
 * 这里的解析顺序：
 *   1. `fileUri.FileUri(uri).name` —— 由系统按 URI 规范解析，能正确处理编码与层级；
 *   2. 相册场景再查媒体库 `display_name`（Picker 只给 uri，显示名在资产元数据里）；
 *   3. 多轮 `decodeURIComponent` 解码（应对二次编码）；
 *   4. 清理 QTS / multipart 不允许的字符，但**保留中文、空格、括号与扩展名**；
 *   5. 都不行才返回空串，由调用方生成带正确扩展名的兜底名。
 */
export class FileNameUtil {
  /** QTS 与 multipart 头中不允许出现的字符（含 CR/LF 和英文双引号）。 */
  private static readonly BAD: string = '/\\:*?"<>|';

  /**
   * 解析 URI 对应的原始文件名（异步，因为相册显示名需要查媒体库）。
   * context 为空时只做 URI 解析，不访问媒体库。
   */
  static async resolve(uri: string, context?: common.Context): Promise<string> {
    let name: string = FileNameUtil.fromUri(uri);
    const weak: boolean = name.length === 0 || FileNameUtil.isIdLike(name);
    if (weak && context !== undefined) {
      const display: string = await FileNameUtil.photoDisplayName(context, uri);
      const cleaned: string = FileNameUtil.clean(FileNameUtil.decode(display));
      if (cleaned.length > 0 && !FileNameUtil.isIdLike(cleaned)) {
        name = cleaned;
      }
    }
    return name;
  }

  /** 同步版本：只做 URI 解析（不查媒体库），适合文档选择器。 */
  static fromUri(uri: string): string {
    let raw: string = '';
    try {
      raw = new fileUri.FileUri(uri).name;
    } catch (e) {
      raw = '';
    }
    const primary: string = FileNameUtil.clean(FileNameUtil.decode(raw));
    if (primary.length > 0 && !FileNameUtil.isIdLike(primary)) {
      return primary;
    }
    // 有些 URI 的 name 是纯数字 ID，尝试从整条 URI 末段再取一次
    const tail: string = FileNameUtil.clean(FileNameUtil.decode(FileNameUtil.lastSegment(uri)));
    if (tail.length > 0 && !FileNameUtil.isIdLike(tail)) {
      return tail;
    }
    return primary.length > 0 ? primary : tail;
  }

  /** 兜底名：尽量沿用从 URI 推断出的扩展名，避免把 .jpg 变成无后缀文件。 */
  static fallback(uri: string, index: number, defaultExt: string): string {
    let ext: string = FileNameUtil.extensionOf(FileNameUtil.fromUri(uri), defaultExt);
    if (ext.length === 0) {
      ext = FileNameUtil.extFromUri(uri);
    }
    const stamp: number = Date.now();
    return 'FILE_' + String(stamp) + '_' + String(index) + ext;
  }

  /** 从整条 URI 里找形如 `.jpg` / `.heic` 的片段（URI 末段是数字 ID 时的最后手段）。 */
  private static extFromUri(uri: string): string {
    let text: string = uri;
    const q: number = text.search(/[?#]/);
    if (q >= 0) {
      text = text.substring(0, q);
    }
    const dot: number = text.lastIndexOf('.');
    if (dot <= 0 || text.length - dot > 6) {
      return '';
    }
    const ext: string = text.substring(dot);
    if (ext.length < 3) {
      return '';
    }
    for (let i = 1; i < ext.length; i++) {
      const c: string = ext.charAt(i);
      const isDigit: boolean = c >= '0' && c <= '9';
      const isLower: boolean = c >= 'a' && c <= 'z';
      const isUpper: boolean = c >= 'A' && c <= 'Z';
      if (!isDigit && !isLower && !isUpper) {
        return '';
      }
    }
    return ext.toLowerCase();
  }

  /** 从名字里取扩展名（含点）；没有则用 defaultExt（自动补点）。 */
  static extensionOf(name: string, defaultExt: string): string {
    const dot: number = name.lastIndexOf('.');
    if (dot > 0 && dot < name.length - 1 && name.length - dot <= 12) {
      const ext: string = name.substring(dot);
      if (ext.indexOf(' ') < 0) {
        return ext;
      }
    }
    if (defaultExt.length === 0) {
      return '';
    }
    return defaultExt.charAt(0) === '.' ? defaultExt : '.' + defaultExt;
  }

  /** 是否看起来像一个内部 ID 而不是真实文件名（纯数字、无扩展名）。 */
  static isIdLike(name: string): boolean {
    if (name.length === 0) {
      return true;
    }
    if (name.indexOf('.') > 0) {
      return false;
    }
    for (let i = 0; i < name.length; i++) {
      const c: string = name.charAt(i);
      if (c < '0' || c > '9') {
        return false;
      }
    }
    return true;
  }

  /** 多轮百分号解码；遇到非法 % 序列时保留已解码的部分，不抛异常。 */
  static decode(text: string): string {
    let out: string = text;
    for (let round = 0; round < 2; round++) {
      if (out.indexOf('%') < 0) {
        break;
      }
      let next: string = '';
      try {
        next = decodeURIComponent(out);
      } catch (e) {
        break;
      }
      if (next === out || next.length === 0) {
        break;
      }
      out = next;
    }
    return out;
  }

  /** 去掉路径、query、片段、非法字符与控制字符，保留原始可见名字。 */
  static clean(text: string): string {
    let s: string = text;
    const q: number = s.search(/[?#]/);
    if (q >= 0) {
      s = s.substring(0, q);
    }
    const bs: number = s.lastIndexOf('\\');
    const fs2: number = s.lastIndexOf('/');
    const cut: number = Math.max(bs, fs2);
    if (cut >= 0) {
      s = s.substring(cut + 1);
    }
    let out: string = '';
    for (let i = 0; i < s.length; i++) {
      const c: string = s.charAt(i);
      const code: number = s.charCodeAt(i);
      if (code < 32 || code === 127) {
        continue;
      }
      if (FileNameUtil.BAD.indexOf(c) >= 0) {
        continue;
      }
      out += c;
    }
    return out.trim();
  }

  private static lastSegment(uri: string): string {
    let s: string = uri;
    const q: number = s.search(/[?#]/);
    if (q >= 0) {
      s = s.substring(0, q);
    }
    while (s.length > 1 && s.charAt(s.length - 1) === '/') {
      s = s.substring(0, s.length - 1);
    }
    const slash: number = s.lastIndexOf('/');
    return slash >= 0 ? s.substring(slash + 1) : s;
  }

  /**
   * 用媒体库按 uri 查 display_name。
   * Picker 授予的是临时读权限，个别机型/版本不允许查资产，失败一律回退到 URI 解析。
   */
  private static async photoDisplayName(context: common.Context, uri: string): Promise<string> {
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const predicates = new dataSharePredicates.DataSharePredicates();
      predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
      const options: photoAccessHelper.FetchOptions = {
        fetchColumns: [photoAccessHelper.PhotoKeys.DISPLAY_NAME],
        predicates: predicates
      };
      const fetch = await helper.getAssets(options);
      const assets = await fetch.getAllObjects();
      if (assets.length > 0) {
        return String(assets[0].get(photoAccessHelper.PhotoKeys.DISPLAY_NAME));
      }
    } catch (e) {
      // 无权限或该 URI 不在媒体库：交给 URI 解析结果
    }
    return '';
  }
}
