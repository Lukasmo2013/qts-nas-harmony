import os
# -*- coding: utf-8 -*-
"""QTS NAS —— 本地 release 签名链路（HarmonyOS / hap-sign-tool）。

完整复现：
  1. 开发者自有 keystore (.p12) 与 AGC 提交用 CSR
  2. 自签 Root CA -> App Release CA / Profile Release CA -> 叶证书链
  3. app_gallery 类型 release provision profile（含分发证书）
  4. sign-profile / verify-profile
  5. sign-app / verify-app（对 assembleHap 产出的 unsigned HAP）

前置：先执行 release 构建，产出
  entry/build/default/outputs/default/entry-default-unsigned.hap
若 build-profile.json5 已配置 signingConfigs，hvigor 会自行签名，此时
本脚本仍可对 unsigned HAP 单独跑一遍等价链路用于交叉验证。

注意：这里生成的是「本地自签」材料，只用于编译、验签与离线验收；
上架 AppGallery / 安装到未解锁的真机，必须替换为 AGC 下发的证书与 profile。

Usage:
  python tools/sign_release.py
"""
import datetime
import json
import pathlib
import re
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
SIGNING = ROOT / 'tools' / 'signing'
SIGNING.mkdir(parents=True, exist_ok=True)

DEVECO = pathlib.Path(r'C:\Program Files\Huawei\DevEco Studio')
LIB = DEVECO / 'sdk' / 'default' / 'openharmony' / 'toolchains' / 'lib'
TOOL = LIB / 'hap-sign-tool.jar'
JAVA = DEVECO / 'jbr' / 'bin' / 'java.exe'
UNSIGNED = ROOT / 'entry' / 'build' / 'default' / 'outputs' / 'default' / 'entry-default-unsigned.hap'

BUNDLE_NAME = 'com.wlt.qnap.nasmanager'
VERSION_NAME = '1.0.0'
VERSION_CODE = 1000000
PASSWORD = os.environ.get('QNAP_SIGN_PASSWORD', '')           # 与 tools/prepare_signing_config.js 保持一致
ALIAS_APP = 'qnap-nas-release'
ALIAS_PROFILE = 'qts-profile-key'
ALIAS_ROOT_CA = 'qts-root-ca'
ALIAS_APP_CA = 'qts-app-ca'
ALIAS_PROFILE_CA = 'qts-profile-ca'
ROOT_SUBJECT = 'C=CN,O=WLT,OU=WLT PKI,CN=QTS NAS Root CA'
APP_CA_SUBJECT = 'C=CN,O=WLT,OU=WLT PKI,CN=QTS NAS App Release CA'
PROFILE_CA_SUBJECT = 'C=CN,O=WLT,OU=WLT PKI,CN=QTS NAS Profile Release CA'
APP_SUBJECT = 'C=CN,O=WLT,OU=WLT HarmonyOS Dev,CN=QTS NAS App Release'
PROFILE_SUBJECT = 'C=CN,O=WLT,OU=WLT HarmonyOS Dev,CN=QTS NAS Profile Release'
SIGN_ALG = 'SHA256withECDSA'

steps = []


def run(command, label):
    """执行 hap-sign-tool 命令，失败即终止并打印最后一段日志。"""
    proc = subprocess.run(command, capture_output=True, text=True,
                          encoding='utf-8', errors='replace')
    out = (proc.stdout or '') + (proc.stderr or '')
    ok = proc.returncode == 0 and 'success' in out.lower() and 'ERROR' not in out
    if not ok:
        print('\n'.join(out.strip().splitlines()[-14:]))
        raise RuntimeError('%s failed (exit=%d)' % (label, proc.returncode))
    steps.append(label)
    print('  [OK] ' + label)


def sign(*args):
    return [str(JAVA), '-jar', str(TOOL), *[str(a) for a in args]]


def rel(p):
    return str(p.relative_to(ROOT)).replace('\\', '/')


def verify_only():
    """只复核已生成的 profile 与 signed HAP，不改动任何签名材料。"""
    signed_profile = SIGNING / 'qts-release-profile.p7b'
    signed_hap = SIGNING / 'QTS-NAS-release-signed.hap'
    for p in (signed_profile, signed_hap):
        if not p.exists():
            raise RuntimeError('missing artifact: %s' % rel(p))
    run(sign('verify-profile', '-inFile', signed_profile,
             '-outFile', SIGNING / 'verify-profile-result.json'), 'verify-profile')
    check = json.loads((SIGNING / 'verify-profile-result.json').read_text(encoding='utf-8'))
    if not check.get('verifiedPassed'):
        raise RuntimeError('profile verification did not pass')
    proc = subprocess.run(sign('verify-app', '-inFile', signed_hap,
                               '-outCertChain', SIGNING / 'verify-app-certchain.cer',
                               '-outProfile', SIGNING / 'verify-app-profile.p7b'),
                          capture_output=True, text=True, encoding='utf-8', errors='replace')
    out = (proc.stdout or '') + (proc.stderr or '')
    if 'Digest verify result: true' not in out or 'verify-app success' not in out:
        raise RuntimeError('verify-app failed')
    print('  [OK] verify-app (SHA-256 digest = true)')
    print('\nRESULT: PASS - profile and signed HAP both verified')
    print('signed HAP : %s (%d bytes)' % (rel(signed_hap), signed_hap.stat().st_size))


def main():
    if not TOOL.exists():
        raise RuntimeError('hap-sign-tool.jar not found: %s' % TOOL)
    if '--verify-only' in sys.argv:
        return verify_only()
    if not UNSIGNED.exists():
        raise RuntimeError('unsigned HAP not found, run assembleHap first: %s' % rel(UNSIGNED))

    p12 = SIGNING / 'qnap-release.p12'
    csr = SIGNING / 'qnap-release.csr'
    common = ['-keystoreFile', p12, '-keystorePwd', PASSWORD]

    # 幂等：证书链、profile、keystore 均已存在时，只重新签署当前 HAP 并验签。
    # 否则 generate-keypair / generate-ca 会因「Key alias is exist」直接失败。
    chain_artifacts = [
        SIGNING / 'qts-root-ca.cer',
        SIGNING / 'qts-app-ca.cer',
        SIGNING / 'qts-profile-ca.cer',
        SIGNING / 'qts-app-cert-chain.cer',
        SIGNING / 'qts-profile-cert-chain.cer',
        SIGNING / 'qts-release-profile.p7b',
    ]
    reuse_chain = p12.exists() and all(a.exists() for a in chain_artifacts)

    print('\n[1/6] 开发者 keystore 与 CSR（AGC 提交素材）')
    if not p12.exists():
        run(sign('generate-keypair', '-keyAlias', ALIAS_APP, '-keyPwd', PASSWORD,
                 '-keyAlg', 'ECC', '-keySize', 'NIST-P-256', *common),
            'generate-keypair')
        run(sign('generate-csr', '-keyAlias', ALIAS_APP, '-keyPwd', PASSWORD,
                 '-subject', APP_SUBJECT, '-signAlg', SIGN_ALG,
                 '-outFile', csr, *common), 'generate-csr')
    else:
        print('  [SKIP] keystore 已存在，保留原密钥：' + rel(p12))

    if reuse_chain:
        print('\n[2-4/6] 证书链与 profile')
        print('  [SKIP] 证书链 / profile 已存在，复用原链路（幂等）')
        print('\n[5/6] 签名 unsigned HAP')
        signed_hap = SIGNING / 'QTS-NAS-release-signed.hap'
        run(sign('sign-app', '-mode', 'localSign', '-keyAlias', ALIAS_APP,
                 '-keyPwd', PASSWORD, '-appCertFile', SIGNING / 'qts-app-cert-chain.cer',
                 '-profileFile', SIGNING / 'qts-release-profile.p7b', '-profileSigned', 1,
                 '-inFile', UNSIGNED, '-signAlg', SIGN_ALG,
                 '-outFile', signed_hap, '-compatibleVersion', 20,
                 '-signCode', 1, *common), 'sign-app')
        print('\n[6/6] 验签 HAP')
        proc = subprocess.run(sign('verify-app', '-inFile', signed_hap,
                                   '-outCertChain', SIGNING / 'verify-app-certchain.cer',
                                   '-outProfile', SIGNING / 'verify-app-profile.p7b'),
                              capture_output=True, text=True, encoding='utf-8', errors='replace')
        out = (proc.stdout or '') + (proc.stderr or '')
        if 'Digest verify result: true' not in out or 'verify-app success' not in out:
            print('\n'.join(out.strip().splitlines()[-14:]))
            raise RuntimeError('verify-app failed')
        steps.append('verify-app')
        print('  [OK] verify-app (SHA-256 digest = true)')
        print('\n==================== SIGNING SUMMARY ====================')
        print('unsigned HAP : %s (%d bytes)' % (rel(UNSIGNED), UNSIGNED.stat().st_size))
        print('signed HAP   : %s (%d bytes)' % (rel(signed_hap), signed_hap.stat().st_size))
        print('profile      : %s' % rel(SIGNING / 'qts-release-profile.p7b'))
        print('keystore     : %s' % rel(p12))
        print('CSR for AGC  : %s' % rel(csr))
        print('steps        : sign-app + verify-app (证书链复用)')
        print('NOTE         : local self-signed chain only; AGC cert required for store release')
        print('========================================================')
        return

    print('\n[2/6] 三级 CA 证书链')
    run(sign('generate-keypair', '-keyAlias', ALIAS_PROFILE, '-keyPwd', PASSWORD,
             '-keyAlg', 'ECC', '-keySize', 'NIST-P-256', *common),
        'profile keypair (reuse-safe)')
    run(sign('generate-ca', '-keyAlias', ALIAS_ROOT_CA, '-keyPwd', PASSWORD,
             '-keyAlg', 'ECC', '-keySize', 'NIST-P-256', '-subject', ROOT_SUBJECT,
             '-validity', 3650, '-signAlg', SIGN_ALG,
             '-outFile', SIGNING / 'qts-root-ca.cer', *common), 'root CA')
    for alias, subject, out in [
        (ALIAS_APP_CA, APP_CA_SUBJECT, 'qts-app-ca.cer'),
        (ALIAS_PROFILE_CA, PROFILE_CA_SUBJECT, 'qts-profile-ca.cer'),
    ]:
        run(sign('generate-ca', '-keyAlias', alias, '-keyPwd', PASSWORD,
                 '-keyAlg', 'ECC', '-keySize', 'NIST-P-256',
                 '-issuer', ROOT_SUBJECT, '-issuerKeyAlias', ALIAS_ROOT_CA,
                 '-issuerKeyPwd', PASSWORD, '-subject', subject,
                 '-validity', 3650, '-signAlg', SIGN_ALG,
                 '-outFile', SIGNING / out, *common), 'sub CA: ' + alias)

    app_chain = SIGNING / 'qts-app-cert-chain.cer'
    profile_chain = SIGNING / 'qts-profile-cert-chain.cer'
    for kind, alias, issuer, issuer_key, sub_ca, subject, out in [
        ('generate-app-cert', ALIAS_APP, APP_CA_SUBJECT, ALIAS_APP_CA,
         'qts-app-ca.cer', APP_SUBJECT, app_chain),
        ('generate-profile-cert', ALIAS_PROFILE, PROFILE_CA_SUBJECT, ALIAS_PROFILE_CA,
         'qts-profile-ca.cer', PROFILE_SUBJECT, profile_chain),
    ]:
        run(sign(kind, '-keyAlias', alias, '-keyPwd', PASSWORD,
                 '-issuer', issuer, '-issuerKeyAlias', issuer_key,
                 '-issuerKeyPwd', PASSWORD, '-subject', subject,
                 '-validity', 1095, '-signAlg', SIGN_ALG,
                 '-outForm', 'certChain',
                 '-rootCaCertFile', SIGNING / 'qts-root-ca.cer',
                 '-subCaCertFile', SIGNING / sub_ca,
                 '-outFile', out, *common), kind)

    print('\n[3/6] app_gallery release provision profile')
    leaf = re.search(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                     app_chain.read_text(encoding='utf-8'), re.S).group(0)
    now = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    profile = {
        'version-name': VERSION_NAME,
        'version-code': VERSION_CODE,
        'app-distribution-type': 'app_gallery',
        'uuid': str(uuid.uuid4()),
        'validity': {'not-before': now - 60, 'not-after': now + 1095 * 86400},
        'type': 'release',
        'bundle-info': {
            'developer-id': 'WLT Local Release',
            'distribution-certificate': leaf + '\n',
            'bundle-name': BUNDLE_NAME,
            'apl': 'normal',
            'app-feature': 'hos_normal_app',
        },
        'acls': {'allowed-acls': []},
        'permissions': {'restricted-permissions': []},
        'issuer': 'pki_internal',
    }
    profile_json = SIGNING / 'qnap-release-profile.json'
    profile_json.write_text(json.dumps(profile, ensure_ascii=False, indent=2), encoding='utf-8')
    print('  [OK] ' + rel(profile_json))

    print('\n[4/6] 签名并校验 profile')
    signed_profile = SIGNING / 'qts-release-profile.p7b'
    run(sign('sign-profile', '-mode', 'localSign', '-keyAlias', ALIAS_PROFILE,
             '-keyPwd', PASSWORD, '-profileCertFile', profile_chain,
             '-inFile', profile_json, '-signAlg', SIGN_ALG,
             '-outFile', signed_profile, *common), 'sign-profile')
    run(sign('verify-profile', '-inFile', signed_profile,
             '-outFile', SIGNING / 'verify-profile-result.json'), 'verify-profile')
    check = json.loads((SIGNING / 'verify-profile-result.json').read_text(encoding='utf-8'))
    if not check.get('verifiedPassed'):
        raise RuntimeError('profile verification did not pass')

    print('\n[5/6] 签名 unsigned HAP')
    signed_hap = SIGNING / 'QTS-NAS-release-signed.hap'
    run(sign('sign-app', '-mode', 'localSign', '-keyAlias', ALIAS_APP,
             '-keyPwd', PASSWORD, '-appCertFile', app_chain,
             '-profileFile', signed_profile, '-profileSigned', 1,
             '-inFile', UNSIGNED, '-signAlg', SIGN_ALG,
             '-outFile', signed_hap, '-compatibleVersion', 20,
             '-signCode', 1, *common), 'sign-app')

    print('\n[6/6] 验签 HAP')
    # verify-app 成功时输出 "verify-app success"，不写入 json，按返回码与日志判定
    proc = subprocess.run(sign('verify-app', '-inFile', signed_hap,
                               '-outCertChain', SIGNING / 'verify-app-certchain.cer',
                               '-outProfile', SIGNING / 'verify-app-profile.p7b'),
                          capture_output=True, text=True, encoding='utf-8', errors='replace')
    out = (proc.stdout or '') + (proc.stderr or '')
    if 'Digest verify result: true' not in out or 'verify-app success' not in out:
        print('\n'.join(out.strip().splitlines()[-14:]))
        raise RuntimeError('verify-app failed')
    steps.append('verify-app')
    print('  [OK] verify-app (SHA-256 digest = true)')

    print('\n==================== SIGNING SUMMARY ====================')
    print('unsigned HAP : %s (%d bytes)' % (rel(UNSIGNED), UNSIGNED.stat().st_size))
    print('signed HAP   : %s (%d bytes)' % (rel(signed_hap), signed_hap.stat().st_size))
    print('profile      : %s' % rel(signed_profile))
    print('keystore     : %s' % rel(p12))
    print('CSR for AGC  : %s' % rel(csr))
    print('steps        : %d / 9 passed' % len(steps))
    print('NOTE         : local self-signed chain only; AGC cert required for store release')
    print('========================================================')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('\nRESULT: FAIL - %s' % exc)
        sys.exit(1)
