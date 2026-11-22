/** 展示层格式化工具。 */

export class FormatUtil {
  static bytes(value: number): string {
    if (value <= 0) {
      return '0 B';
    }
    const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    let index: number = 0;
    let current: number = value;
    while (current >= 1024 && index < units.length - 1) {
      current = current / 1024;
      index += 1;
    }
    const shown: string = index === 0 ? String(Math.round(current)) : current.toFixed(1);
    return shown + ' ' + units[index];
  }

  static percent(value: number): string {
    return Math.round(value) + '%';
  }

  static oneDecimal(value: number): string {
    return value.toFixed(1);
  }

  static dateTime(epochMs: number): string {
    const d: Date = new Date(epochMs);
    const month: number = d.getMonth() + 1;
    const day: number = d.getDate();
    const hour: number = d.getHours();
    const minute: number = d.getMinutes();
    return d.getFullYear() + '-' + FormatUtil.pad(month) + '-' + FormatUtil.pad(day) +
      ' ' + FormatUtil.pad(hour) + ':' + FormatUtil.pad(minute);
  }

  static shortDate(epochMs: number): string {
    const d: Date = new Date(epochMs);
    return FormatUtil.pad(d.getMonth() + 1) + '-' + FormatUtil.pad(d.getDate()) +
      ' ' + FormatUtil.pad(d.getHours()) + ':' + FormatUtil.pad(d.getMinutes());
  }

  static pad(value: number): string {
    return value < 10 ? '0' + value : String(value);
  }

  static maskAccount(account: string): string {
    if (account.length === 0) {
      return '--';
    }
    const at: number = account.indexOf('@');
    if (at > 2) {
      return account.substring(0, 2) + '***' + account.substring(at);
    }
    if (account.length <= 4) {
      return account;
    }
    return account.substring(0, 2) + '***' + account.substring(account.length - 2);
  }
}
