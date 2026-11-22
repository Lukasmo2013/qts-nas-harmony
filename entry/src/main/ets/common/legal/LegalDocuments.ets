import { AppConstants } from '../constants/AppConstants';

/**
 * 应用内可访问的隐私政策与服务条款全文。
 *
 * 上架说明：
 * 1. 本文件是审核与用户可查阅的权威文本，登录页与「我的 → 关于」均可直接打开；
 * 2. 文案必须与实际行为一致：账号与连接信息只保存在本机，密码不持久化，
 *    不接入任何第三方统计 / 广告 SDK，Tailscale 账号密码由官方页面自行输入；
 * 3. 如上架商店要求填写公开 URL，请把同一份文本发布到开发者站点后填入后台。
 */

/** 单个条款分节：标题 + 若干自然段。 */
export interface LegalSection {
  heading: string;
  paragraphs: string[];
}

const PRIVACY_ZH: LegalSection[] = [
  {
    heading: '一、我们如何处理信息',
    paragraphs: [
      '本应用是一款本地 NAS 管理工具，仅用于连接和管理您本人有权访问的 QNAP QTS 设备。我们不在云端保存您的业务数据，也不通过本应用收集个人信息用于画像、广告或转售。',
      '应用在运行过程中会接触以下几类信息：您手动填写的设备地址、端口与账号；您设备返回的硬件状态、存储卷、硬盘、服务与容器信息；您主动选择上传或备份的文件；以及为实现远程连接而产生的 VPN 连接状态。上述信息均用于完成您发起的操作。'
    ]
  },
  {
    heading: '二、账号与凭据',
    paragraphs: [
      '账号由您自己的 NAS（QTS）提供，本应用不注册、不托管任何账号。账号名称、设备地址与端口会保存在本机，方便下次连接；登录密码不会被写入持久化存储，退出登录后本地会话与凭据会被清除。',
      '若您选择「通过 Tailscale 连接」，Tailscale 账号的登录与设备授权在 Tailscale 官方网站完成，密码由您直接输入给 Tailscale，本应用无法读取也不会保存该密码。'
    ]
  },
  {
    heading: '三、权限使用说明',
    paragraphs: [
      '网络访问：用于连接同一网络内的 NAS 并读取设备状态，以及检测网络异常。',
      '媒体文件读取：仅在您开启照片自动备份时使用，用于读取您所选文件的原始名称，使 NAS 上的备份保留原文件名；我们不会扫描您的整个相册，也不会上传未被您选择的内容。',
      '文件选择器：上传文件、选择备份目录时由系统弹出，遵循系统授权结果，应用不绕过系统选择器直接读取目录。',
      'VPN 连接：仅在您选择 Tailscale 方式时由系统弹出授权确认，用于在本机建立加密隧道；您可以在系统设置中随时撤销该授权。'
    ]
  },
  {
    heading: '四、数据存储与安全',
    paragraphs: [
      '设备状态、文件列表、传输队列等数据保存在您的手机或平板本地；文件与备份内容写入您自己的 NAS。应用未内置第三方统计、广告或崩溃上报 SDK，不会把上述数据发送到我们的服务器。',
      '网络连接优先使用您配置的 HTTP/HTTPS 地址；远程场景由您自行部署的 Tailscale 隧道提供加密传输。请为 NAS 设置强密码，并仅向可信设备开放访问权限。'
    ]
  },
  {
    heading: '五、信息共享与第三方',
    paragraphs: [
      '我们不会出售、出租或与第三方交换您的个人信息。您主动打开容器端口链接时，浏览器会访问该容器在您 NAS 上提供的地址，该行为完全由您触发。',
      'Tailscale 是独立第三方服务，其账号体系与隐私规则由 Tailscale 制定；使用相关功能即表示您同意遵守其服务条款。除上述情形外，本应用不向其他第三方提供数据。'
    ]
  },
  {
    heading: '六、退出登录与账号注销',
    paragraphs: [
      '您可以在「我的 → 退出登录」随时结束会话。退出会清除本机的会话标识、连接地址、账号、备份配置与登录表单；NAS 上的文件不会被删除。',
      '由于账号归属于您自己的 NAS 而非本应用，如需注销 NAS 账号或删除 NAS 上的数据，请联系该设备的管理员或在 QTS 中操作。如需清除本应用留存的全部设置，请在系统设置中卸载本应用。'
    ]
  },
  {
    heading: '七、自动备份',
    paragraphs: [
      '自动备份默认关闭。只有当您手动开启并选择手机目录与 NAS 目录后，应用才会按增量方式扫描并上传所选目录中的文件；扫描深度与单次文件数量设有上限。关闭开关后不再执行新的备份任务。',
      '目录授权随系统能力而定：若系统不支持长期保留授权，重启后可能需要您重新选择目录。备份失败会在应用内提示原因，不会在后台静默重试。'
    ]
  },
  {
    heading: '八、儿童隐私',
    paragraphs: [
      '本应用面向管理自有 NAS 的用户，并非面向儿童设计。我们不会有意收集未满十四周岁儿童的个人信息。'
    ]
  },
  {
    heading: '九、政策更新',
    paragraphs: [
      '当功能或法规要求发生变化时，我们会更新本政策并在应用内公布。更新后的版本自公布之日起生效，请在使用前查阅。'
    ]
  },
  {
    heading: '十、联系我们',
    paragraphs: [
      '如对本政策或数据处理方式有疑问，请通过应用商店页面公布的开发者联系方式与我们联系。'
    ]
  }
];

const PRIVACY_EN: LegalSection[] = [
  {
    heading: '1. How information is handled',
    paragraphs: [
      'This app is a local NAS management tool. It only connects to QNAP QTS devices you are authorized to manage. We do not store your data in the cloud and do not collect personal information for profiling, advertising or resale.',
      'While the app runs it may process the host, port and account you enter; device status, volumes, disks, services and containers returned by your NAS; files you choose to upload or back up; and VPN connection state needed for remote access. All of it is used only to perform the action you requested.'
    ]
  },
  {
    heading: '2. Accounts and credentials',
    paragraphs: [
      'Accounts belong to your own NAS (QTS). This app does not register or host accounts. The account name, host and port are kept on this device for convenience; passwords are never written to persistent storage and local sessions are cleared when you sign out.',
      'If you choose "Connect via Tailscale", sign-in and node authorization happen on the official Tailscale website. You enter the Tailscale password directly with Tailscale; this app cannot read or store it.'
    ]
  },
  {
    heading: '3. Permissions we request',
    paragraphs: [
      'Network access: to reach the NAS on your network and detect connectivity problems.',
      'Media read access: used only when you enable photo backup, to keep original file names on the NAS. Your whole photo library is never scanned and unselected content is never uploaded.',
      'File picker: shown by the system when you upload files or choose backup folders. We rely on the system authorization result and never bypass the picker.',
      'VPN connection: shown only when you choose Tailscale, to establish an encrypted tunnel on this device. You can revoke it at any time in system settings.'
    ]
  },
  {
    heading: '4. Storage and security',
    paragraphs: [
      'Device state, file listings and transfer queues stay on your phone or tablet; files and backups are written to your own NAS. The app contains no third-party analytics, advertising or crash-reporting SDK and does not send this data to our servers.',
      'Connections use the HTTP/HTTPS address you configure; remote access relies on the Tailscale tunnel you deploy. Use a strong NAS password and only grant access to trusted devices.'
    ]
  },
  {
    heading: '5. Sharing and third parties',
    paragraphs: [
      'We do not sell, rent or trade personal information. Opening a container port link launches a browser to an address hosted on your own NAS, and only happens when you tap it.',
      'Tailscale is an independent third party with its own account system and privacy terms. Other than the above, this app does not disclose data to third parties.'
    ]
  },
  {
    heading: '6. Sign-out and account deletion',
    paragraphs: [
      'Use "Profile → Sign out" at any time. Sign-out clears the local session, connection address, account, backup configuration and login form; files on the NAS are not deleted.',
      'Because the account belongs to your NAS rather than this app, contact the administrator of that device or use QTS to delete the account or its data. To remove all local settings, uninstall the app from system settings.'
    ]
  },
  {
    heading: '7. Automatic backup',
    paragraphs: [
      'Automatic backup is off by default. Only after you enable it and pick a phone folder and a NAS folder does the app scan incrementally and upload files from the selected folder. Scan depth and per-run file count are capped. Turning the switch off stops new jobs.',
      'Folder permission persistence depends on system capabilities. If the system does not keep long-term access, you may need to pick the folder again after a restart. Failures are shown in the app and are never silently retried in the background.'
    ]
  },
  {
    heading: '8. Children',
    paragraphs: [
      'This app is intended for users managing their own NAS and is not directed at children. We do not knowingly collect personal information from children under 14.'
    ]
  },
  {
    heading: '9. Updates',
    paragraphs: [
      'We may update this policy when features or legal requirements change. The revised version is published in the app and takes effect on the date of publication.'
    ]
  },
  {
    heading: '10. Contact',
    paragraphs: [
      'For questions about this policy or data handling, use the developer contact information published on the app store listing.'
    ]
  }
];

const TERMS_ZH: LegalSection[] = [
  {
    heading: '一、服务内容',
    paragraphs: [
      '本应用提供对您自有 NAS 设备的状态查看、文件浏览与传输、存储与容器管理、以及可选的远程连接能力。所有操作均直接作用于您指定的设备，本应用本身不提供云存储服务。'
    ]
  },
  {
    heading: '二、使用条件',
    paragraphs: [
      '您应确保对目标设备及其数据拥有合法访问权限，并遵守设备所在地及使用地的法律法规。请勿使用本应用访问他人设备或传播违法内容。'
    ]
  },
  {
    heading: '三、您的责任',
    paragraphs: [
      '请自行保管 NAS 账号、密码与网络配置，并在执行删除、覆盖、镜像移除等操作前确认目标。自动备份开启后，请定期检查备份结果；重要数据建议保留其他独立副本。'
    ]
  },
  {
    heading: '四、知识产权',
    paragraphs: [
      'QNAP、QTS、Container Station、Tailscale 及相关标识归各自权利人所有。本应用仅为管理工具，与上述权利人无隶属或背书关系。'
    ]
  },
  {
    heading: '五、免责声明',
    paragraphs: [
      '本应用按现状提供。因设备固件差异、网络环境、权限设置或第三方服务变更导致的功能不可用，我们会在应用内给出提示，但不对由此产生的间接损失承担责任。'
    ]
  },
  {
    heading: '六、条款变更',
    paragraphs: [
      '功能调整时我们可能更新本条款，更新后将在应用内公布。继续使用即视为您接受更新后的条款；如不接受，请停止使用并卸载应用。'
    ]
  }
];

const TERMS_EN: LegalSection[] = [
  {
    heading: '1. Service',
    paragraphs: [
      'This app provides status monitoring, file browsing and transfer, storage and container management, and optional remote access for NAS devices you own. All actions target the device you specify; the app itself is not a cloud storage service.'
    ]
  },
  {
    heading: '2. Conditions of use',
    paragraphs: [
      'You must have lawful access to the target device and its data and comply with applicable laws. Do not use the app to access devices owned by others or to distribute unlawful content.'
    ]
  },
  {
    heading: '3. Your responsibilities',
    paragraphs: [
      'Keep your NAS credentials and network settings safe, and verify targets before deleting, overwriting or removing images. Check backup results regularly if automatic backup is enabled and keep independent copies of important data.'
    ]
  },
  {
    heading: '4. Intellectual property',
    paragraphs: [
      'QNAP, QTS, Container Station, Tailscale and related marks belong to their respective owners. This app is an independent management tool and is not affiliated with or endorsed by them.'
    ]
  },
  {
    heading: '5. Disclaimer',
    paragraphs: [
      'The app is provided as is. We show in-app guidance when firmware differences, network conditions, permission settings or third-party changes affect functionality, but we are not liable for indirect losses arising from them.'
    ]
  },
  {
    heading: '6. Changes',
    paragraphs: [
      'We may update these terms as features change and will publish revisions in the app. Continued use means you accept the updated terms; otherwise please stop using and uninstall the app.'
    ]
  }
];

/** 文档类型，仅允许 privacy / terms。 */
export function legalTitle(kind: string, lang: string): string {
  if (kind === 'terms') {
    return lang === 'en' ? 'Terms of Service' : '服务条款';
  }
  return lang === 'en' ? 'Privacy Policy' : '隐私政策';
}

export function legalUpdatedText(kind: string, lang: string, date: string): string {
  if (lang === 'en') {
    return (kind === 'terms' ? 'Terms' : 'Policy') + ' · Last updated ' + date +
      ' · Version ' + AppConstants.VERSION_NAME;
  }
  return (kind === 'terms' ? '服务条款' : '隐私政策') + ' · 更新日期 ' + date +
    ' · 版本 ' + AppConstants.VERSION_NAME;
}

export function legalSections(kind: string, lang: string): LegalSection[] {
  const english: boolean = lang === 'en';
  if (kind === 'terms') {
    return english ? TERMS_EN : TERMS_ZH;
  }
  return english ? PRIVACY_EN : PRIVACY_ZH;
}
