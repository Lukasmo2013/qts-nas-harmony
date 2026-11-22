/**
 * 为 build-profile.json5 生成 DevEco / hvigor 可识别的加密签名口令与 material 目录。
 *
 * 背景：hvigor 的 SignHap 任务不接受明文口令，它调用
 *   hvigor-ohos-plugin/src/utils/decipher-util.js :: DecipherUtil.decryptPwd()
 * 用 keystore 同级 material/ 下的密钥材料解密 storePassword / keyPassword。
 * DevEco Studio「自动生成签名」使用同一套机制。本脚本按该算法生成一套
 * 开发者自有材料，因此无需登录 AGC 也能让 hvigor 原生完成 release 签名。
 *
 * 注意：生成的 signingConfigs 属于「本地自签」，仅用于本地编译 / 验签链路；
 * 正式上架应用商店时必须替换为 AGC 下发的证书与 provision profile。
 *
 * Usage: node tools/prepare_signing_config.js [password]
 * Output: tools/signing/material/** + 打印写入 build-profile.json5 的密文口令
 */
'use strict';
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SIGNING_DIR = path.join(ROOT, 'tools', 'signing');
const MATERIAL_DIR = path.join(SIGNING_DIR, 'material');
const PASSWORD = process.argv[2] || 'QnapNas2026';

// 来自 hvigor-ohos-plugin decipher-util.js 的常量
const COMPONENT = new Int8Array([
  49, 243, 9, 115, 214, 175, 91, 184, 211, 190, 177, 88, 101, 131, 192, 119
]);
const DIRS = ['fd', 'ac', 'ce'];

function xor(a, b) {
  const out = new Int8Array(a.length);
  for (let i = 0; i < a.length; i++) out[i] = a[i] ^ b[i];
  return out;
}

/** 与 DecipherUtil.decrypt() 对应的封装：r(4B BE) + iv(12B) + ciphertext + tag(16B) */
function seal(key, plaintext) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-128-gcm', key, iv);
  const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  const head = Buffer.alloc(4);
  head.writeUInt32BE(ct.length + 16, 0);
  return Buffer.concat([head, iv, ct, tag]);
}

/** 与 DecipherUtil.getKey() 完全一致的根密钥推导 */
function deriveRootKey(fdParts, saltBytes) {
  let acc = xor(fdParts[0], fdParts[1]);
  acc = xor(acc, fdParts[2]);
  acc = xor(acc, COMPONENT);
  return crypto.pbkdf2Sync(Buffer.from(acc).toString(), new Int8Array(saltBytes), 10000, 16, 'sha256');
}

/** 与 DecipherUtil.decrypt() 对应的解封，用于生成后自校验 */
function open(key, blob) {
  const e = new Int8Array(blob);
  const r = ((255 & e[0]) << 24) | ((255 & e[1]) << 16) | ((255 & e[2]) << 8) | (255 & e[3]);
  const i = e.length - 4 - r;
  const iv = Buffer.from(blob.slice(4, 4 + i));
  const tag = Buffer.from(blob.slice(blob.length - 16));
  const ct = Buffer.from(blob.slice(4 + i, blob.length - 16));
  const d = crypto.createDecipheriv('aes-128-gcm', key, iv);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(ct), d.final()]);
}

// 重建 material：fd/{0,1,2}/ 各 1 个 16B 文件，ac/ 1 个 16B salt，ce/ 1 个密文文件
fs.rmSync(MATERIAL_DIR, { recursive: true, force: true });
const fdParts = [];
for (let i = 0; i < 3; i++) {
  const bytes = crypto.randomBytes(16);
  fdParts.push(new Int8Array(bytes));
  const dir = path.join(MATERIAL_DIR, DIRS[0], String(i));
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'part' + i), bytes);
}
const salt = crypto.randomBytes(16);
fs.mkdirSync(path.join(MATERIAL_DIR, DIRS[1]), { recursive: true });
fs.writeFileSync(path.join(MATERIAL_DIR, DIRS[1], 'salt'), salt);

const rootKey = deriveRootKey(fdParts, salt);
const finalKey = crypto.randomBytes(16);
fs.mkdirSync(path.join(MATERIAL_DIR, DIRS[2]), { recursive: true });
fs.writeFileSync(path.join(MATERIAL_DIR, DIRS[2], 'work'), seal(rootKey, finalKey));

const encrypted = seal(finalKey, Buffer.from(PASSWORD, 'utf8')).toString('hex');

// 按 SDK 的 decryptPwd 路径完整反向解一次，确保材料能被 hvigor 解密
const fdRead = [0, 1, 2].map(i => new Int8Array(
  fs.readFileSync(path.join(MATERIAL_DIR, DIRS[0], String(i), 'part' + i))));
const saltRead = new Int8Array(fs.readFileSync(path.join(MATERIAL_DIR, DIRS[1], 'salt')));
const workRead = fs.readFileSync(path.join(MATERIAL_DIR, DIRS[2], 'work'));
const checkKey = open(deriveRootKey(fdRead, saltRead), workRead);
const plain = open(checkKey, Buffer.from(encrypted, 'hex')).toString('utf8');
const verified = plain === PASSWORD ? 'OK' : 'MISMATCH (' + plain + ')';
if (verified !== 'OK') throw new Error('generated signing material failed self-check');

console.log('material dir      : ' + MATERIAL_DIR);
console.log('local self-check  : ' + verified);
console.log('storePassword     : ' + encrypted);
console.log('keyPassword       : ' + encrypted);
