/** 表单校验：返回错误文案的 i18n key，空串表示校验通过。 */

const DIGITS: RegExp = new RegExp('^[0-9]+$');
const ACCOUNT_CHARS: RegExp = new RegExp('^[A-Za-z0-9_.-]+$');
const HAS_SPACE: RegExp = new RegExp('\\s');

export function validateQnapAccount(input: string): string {
  const value: string = input.trim();
  if (value.length < 3 || value.length > 64) {
    return 'login.err.account';
  }
  if (HAS_SPACE.test(value)) {
    return 'login.err.account';
  }
  if (value.indexOf('@') >= 0) {
    const parts: string[] = value.split('@');
    if (parts.length !== 2 || parts[0].length === 0 || parts[1].length < 3) {
      return 'login.err.account';
    }
    if (parts[1].indexOf('.') < 0 || !ACCOUNT_CHARS.test(parts[0]) || !ACCOUNT_CHARS.test(parts[1])) {
      return 'login.err.account';
    }
    return '';
  }
  return ACCOUNT_CHARS.test(value) ? '' : 'login.err.account';
}

export function validatePassword(input: string): string {
  const value: string = input.trim();
  return value.length >= 6 && value.length <= 32 ? '' : 'login.err.password';
}

export function validateIpv4(input: string): string {
  const value: string = input.trim();
  const parts: string[] = value.split('.');
  if (parts.length !== 4) {
    return 'login.err.ip';
  }
  for (const part of parts) {
    if (part.length === 0 || part.length > 3 || !DIGITS.test(part)) {
      return 'login.err.ip';
    }
    const num: number = Number(part);
    if (num < 0 || num > 255) {
      return 'login.err.ip';
    }
  }
  return '';
}

export function validatePort(input: string): string {
  const value: string = input.trim();
  if (value.length === 0 || !DIGITS.test(value)) {
    return 'login.err.port';
  }
  const num: number = Number(value);
  return num >= 1 && num <= 65535 ? '' : 'login.err.port';
}

export function validateUsername(input: string): string {
  return input.trim().length > 0 ? '' : 'login.err.username';
}

export function validateFolderName(input: string): string {
  const value: string = input.trim();
  const illegal: RegExp = new RegExp('[/\\\\:*?"<>|]');
  return value.length > 0 && value.length <= 64 && !illegal.test(value) ? '' : 'files.new.folder.hint';
}

const BAD_HOST_CHARS: RegExp = new RegExp('[^A-Za-z0-9.-]');

/**
 * QNAP ID / myQNAPcloud 域名校验。
 * 允许纯 ID（myid）、完整域名（myid.myqnapcloud.com）、带端口的地址。
 * 带协议前缀属于常见粘贴习惯，这里做宽松放行（由 QnapApi 归一化处理）。
 */
export function validateCloudId(input: string): string {
  let value: string = input.trim();
  if (value.length === 0 || value.length > 128) {
    return 'login.err.id';
  }
  const schemeAt: number = value.indexOf('://');
  if (schemeAt >= 0) {
    value = value.substring(schemeAt + 3);
  }
  const slash: number = value.indexOf('/');
  if (slash >= 0) {
    value = value.substring(0, slash);
  }
  const colon: number = value.indexOf(':');
  if (colon >= 0) {
    const portPart: string = value.substring(colon + 1);
    if (portPart.length > 0 && (!DIGITS.test(portPart) || Number(portPart) < 1 || Number(portPart) > 65535)) {
      return 'login.err.id';
    }
    value = value.substring(0, colon);
  }
  if (value.length === 0 || BAD_HOST_CHARS.test(value)) {
    return 'login.err.id';
  }
  return '';
}

/** 端口允许留空（ID 模式自动探测 8081 / 443）。 */
export function validateOptionalPort(input: string): string {
  const value: string = input.trim();
  if (value.length === 0) {
    return '';
  }
  return validatePort(value);
}
