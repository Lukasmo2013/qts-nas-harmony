# QTS NAS · HarmonyOS 原生 NAS 管理器

用鸿蒙手机 / 平板管理你的威联通（QNAP）NAS：设备状态、文件、容器、自动备份，以及**开箱可用的 Tailscale 内网直连**。

**作者 / 版权**：莫洁安（annst） · **许可**：MIT · **当前版本**：2.1.4

**仓库地址**：https://gitee.com/YOUR_GITEE_ACCOUNT/qts-nas-harmony

> 应用显示名统一为 **QTS NAS**（系统级应用名走 `app_name` 资源，应用内标题走 `app.name` 文案键）。
> 包名 `com.wlt.qnap.nasmanager`。
> **配色基调：素雅中性灰 + 克制钢蓝，界面零暖黄。**
> 本仓库**只提供 unsigned HAP**；签名证书、keystore、口令与 signed 产物一律不入库。

---

## ✨ 项目特色

### 1. Tailscale 原生集成（核心特色）

不是"在 App 里打开一个网页"，而是把 Tailscale 引擎真正内置进应用：

- **引擎内置**：`VpnExtensionAbility` 持有预编译的 `libtailscale_go.so` / `libtailscale_ohos.so`，通过 NAPI 桥接调用，不依赖外部 Tailscale 客户端。
- **五步向导**：VPN 授权 → Tailscale 官方授权页 → 选择/填写 NAS 内网 IP → 独立 NAS 登录页输入账号密码 → 进入 App。每一步都有明确的阶段提示，不会"点了没反应"。
- **真实 TUN**：扩展内 `createVpnConnection()` 建立 TUN，并用 `trustedApplications` 白名单让本 App 自身流量进入 tailnet —— 这是"Tailscale 已登录、NAS 却连不上"的常见坑，很多集成方案会误用 `blockedApplications`。
- **心跳判活**：扩展把状态写入 `filesDir/tailscale-status.json`，UI 侧按 `updatedAt` 判断扩展是否存活；扩展被系统回收时自动重连，不会拿旧快照冒充在线。
- **授权链接可见**：明确区分"登录 Tailscale 官网后台"与"授权本机节点"，界面直接展示 `/a/<key>` 授权链接状态，避免"登录成功但本机没入网"。
- **无公网也能用**：没有公网 IP、没有端口映射时，直接用 `100.x` 内网地址访问 NAS，文件、容器、备份全功能可用。

详见 [Tailscale 五步向导](#) 与 [真机诊断](#) 章节。

### 2. 真实数据，零演示依赖

所有页面数据来自真实 QTS HTTP API（`QnapApi.ets`），接口未授权或不支持时返回真实空态，不用假数据填充。唯一的例外是**独立入口的审核预览模式**，它使用内置示例数据、不连接任何设备，详见下文。

### 3. 文件与容器

- 文件：共享目录浏览、上传 / 下载、新建文件夹与文本文件、重命名、删除、搜索、多选；后台上传下载队列带进度与失败重试。
- 容器：Container Station 5 容器启停 / 重启 / 删除、容器日志、镜像拉取与删除、**端口一键直达容器 Web 界面**。

### 4. 自动备份

在「我的 → 备份与相册」开启自动备份，选择手机目录与 NAS 目录后按 `相对路径 + 大小 + 修改时间` 增量上传；支持相册 / 微信 / QQ 备份入口，失败在应用内提示，不在后台静默重试。

### 5. 体验细节

- 全页面下拉刷新，文件与容器操作后自动回刷；
- 登录智能选路：并发探测上次端点 / 已填地址 / 外网地址，选延迟最低的线路；
- 手机 / 平板 / 2in1 三档断点响应式，深浅色主题，中英双语；
- 隐私政策与服务条款应用内可读，纯图标按钮有无障碍标签。

### 6. 审核预览账号（方便商店审核）

登录页提供「审核预览账号 → 进入预览」入口：无需设备、账号或网络，直接查看填好示例数据的主界面。

- 顶部常驻「预览模式」提示条，右侧可一键退出；
- 预览模式下写操作返回占位成功但不发请求，自动备份不启动，容器端口不打开外部网页；
- 示例地址使用文档保留地址 `192.0.2.10`，账号 `demo-user`，**不含任何真实凭据**；
- 退出登录会同时清除预览标记。

---

## 🚀 快速开始

**环境要求**：DevEco Studio 6.0.0+、HarmonyOS SDK API 20+、Node.js（DevEco 自带）、hdc。

```powershell
# 1. 设置 SDK 与 Node（按本机安装路径调整）
$env:DEVECO_SDK_HOME = "C:\Program Files\Huawei\DevEco Studio\sdk"
$env:NODE_HOME      = "C:\Program Files\Huawei\DevEco Studio\tools\node"
$env:PATH = "$env:NODE_HOME;C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin;" + $env:PATH

# 2. 编译 unsigned release HAP
hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon

# 3. 产物
# entry/build/default/outputs/default/entry-default-unsigned.hap
```

> 本仓库不附带签名证书与口令。需要安装到真机时，请使用自己的 AGC 证书 / profile 在 DevEco 中配置自动签名；
> 若要复用 `tools/sign_release.py` 的本地签名链路，请先设置环境变量 `QNAP_SIGN_PASSWORD`，口令不会写入仓库。

---

## 🌐 发布到 Gitee

```bash
# 1) 先在 Gitee 新建同名公开仓库（不要勾选“初始化 README”）
# 2) 推送（脚本不会读取或保存密码）
bash tools/push_gitee.sh qts-nas-harmony
#    按提示输入 Gitee 用户名；密码 / 私人令牌由 git 自行提示
```

Release 附件只上传 **unsigned HAP**：`dist/QnapNasManager-2.1.4-unsigned.hap`。
**不要上传** `tools/signing/` 下的证书、keystore、profile 或任何 signed 产物。

---

## 🔐 安全与凭据

- 仓库内**没有**任何 NAS 账号、密码、Tailscale 凭据、签名证书、keystore、profile 或 token；
- 登录密码不会写入持久化存储，退出登录会清除本地会话与表单；
- 签名脚本从环境变量 `QNAP_SIGN_PASSWORD` 读取口令，缺失时直接退出；
- 预览模式使用文档保留地址与示例账号，不接触真实设备；
- `tools/` 下的诊断脚本默认地址同样是文档保留地址，密码从 `NAS_PASSWORD` 环境变量读取。

---

## 📄 版权与许可

Copyright © 2026 **莫洁安（annst）**. 本项目基于 [MIT License](./LICENSE) 开源。

QNAP、QTS、Container Station、Tailscale 等名称与标识归各自权利人所有；本项目为独立第三方工具，与上述公司无隶属或背书关系。

---

## 一、交付物与技术选型

需求明确要求「鸿蒙 7 应用」及其开发规范、多设备适配与系统界面风格，因此主体交付为 **HarmonyOS 原生 ArkTS / ArkUI 工程**（Stage 模型、声明式 UI、资源限定词、响应式断点）。

| 交付物 | 路径 | 说明 |
| --- | --- | --- |
| HarmonyOS 原生工程 | `AppScope/`、`entry/`、`hvigor/`、`*.json5` | DevEco Studio 6.0.0.878 实测可编译的完整源码工程 |
| **unsigned release HAP** | `entry/build/default/outputs/default/entry-default-unsigned.hap` | 本仓库唯一分发的构建产物；签名请在本地用自有证书完成 |
| 签名链路（可选） | `tools/sign_release.py` | 读取 `QNAP_SIGN_PASSWORD` 环境变量在本地签名，证书与口令不入库 |
| 高保真交互预览 | `preview/index.html` | 单文件、零依赖；复刻雾玻璃 + 左右滑动新 UI，可经 `tools/qnap_proxy.py` 接真实设备数据 |
| 真实数据代理 | `tools/qnap_proxy.py` | 开发期浏览器预览用的 QTS 桥接（CORS），设备端不经过它 |
| 签名与校验工具链 | `tools/` | 图标生成、静态校验、冒烟测试、证书链 / profile / HAP 签名与验签 |

**本机工具链实测**：DevEco Studio `6.0.0.878`、HarmonyOS SDK `6.0.0.47 / API 20`、hvigor `6.20.2`、hap-sign-tool、hdc `3.2.0b`。debug 与 release 两种 buildMode 均已在本机真实编译通过，release 已完成签名与验签。

---

## 二、真实设备对接（真实数据优先 + 独立审核预览）

页面数据一律来自真实 QTS 接口；唯一例外是独立入口的审核预览模式（`common/demo/DemoMode.ets`，
不连接任何设备，退出登录即失效）。数据链路：

```
ArkTS 页面 (async/await)
    → NasRepository（统一仓库层）
        → QnapApi（真实 QTS HTTP 客户端）
            → 本地设备 http://<host>:<port>（地址由使用者首次登录时填写）
```

自 1.2.18 起，工程内**不预置任何账号、密码或设备地址**：`AppConstants.DEFAULT_HOST` /
`DEFAULT_USER` / `DEFAULT_PASS` 全部为空，`SessionManager.save()` 也不再持久化明文密码。
Tailscale 向导进入 NAS 登录步骤时不会继承主表单凭据，账号密码必须由当前使用者输入。

### QTS 接口契约（已在 TS-464C / QTS 5.2.11 实测验证）

| 用途 | 接口 | 实测返回 |
| --- | --- | --- |
| 登录 | `GET /cgi-bin/authLogin.cgi?user=&pwd=(base64)&service=1` | 返回 `<authSid>`；`authPassed=1` 判定成功 |
| 设备信息 / 服务列表 | `GET /cgi-bin/sysinfoReq.cgi` | 型号 / 固件 / 主机名 / serial；`serivceList`（QTS 原始拼写）中的已安装服务 |
| 系统监控 | `GET /cgi-bin/management/manaRequest.cgi?subfunc=sysmonitor&sys_cpu_use_v2=1&sys_memory_use=1` | `cpu_total_usage`("23.1 %") / `cpu_tempc` / `mem_total`、`mem_used`(KB) / `sys_uptime_day·hour·min` / `swap_mem_info` 分区块 |
| 卷与网口 | `GET /cgi-bin/management/manaRequest.cgi?subfunc=sysmonitor&net_in=1&net_out=1` | `volumeLabel`、`freeSize`(GB)、`volumeDisks`、`volumeStat`、`encryptfs_bool`、`eth_count` |
| 文件列表 | `GET /FileStation6/utilRequest.cgi?func=get_list&path=<共享路径>&limit=200&offset=0&sort=name&dir=ASC` (JSON) | `{"total":6,"real_total":6,"datas":[{"filename":"music","isfolder":1,"filesize":"4096","owner":"demo-user","privilege":"777","filetype":0,"mt":"2026/10/08 15:55:36","epochmt":1791446136}]}`；路径不存在返回 `status:5` |
| 共享目录名单 | `GET /cgi-bin/priv/privRequest.cgi?subfunc=share&read=2&refresh=0` (XML) | `<defShareList><![CDATA[Public/Container]]></defShareList>` + `<no_del_info><share_name>Container</share_name>`；根路径 `/` 不可列举，列表必须落在共享目录内 |
| 系统日志 | `GET /cgi-bin/sys/syslogRequest.cgi?subfunc=get_log&limit=...` (JSON) | `Success:false Error:-3` → 事件区显示真实空态 |
| 容器 | `GET /container-station/api/v3/containers`（`Authorization: Bearer <sid>`） | CS 5 网关：首页 `/container-station/` 返回 **200** 表示已安装；`/api/v3/containers` 返回 `{data:{items}}`（`status`/`portBindings`/`cpu`(核占比)/`memory`(GB)/`startedAt`/`project`）。**旧 v2 路径 `/cgi-bin/container-station/api/v2/...` 在 CS 5 一律 404**——这才是此前误判「未安装」的根因；401 表示已安装但会话失效 |
| 新建文件夹 | **POST** `/FileStation6/utilRequest.cgi?func=createdir`，body `dest_path=<父目录>&dest_folder=<新名>` | `{"status":1}` |
| 重命名 | **POST** `?func=rename`，body `path=<父目录>&source_name=<旧名>&dest_name=<新名>` | `{"status":1}` |
| 删除 | **POST** `?func=delete`，body `path=<父目录>&file_name=<名>&file_total=<n>&v=2[&force=1]` | `{"status":1,"pid":...}`；不传 `force` 即移入回收站 `@Recycle` |

> **File Station 6 写操作契约（本轮实测打通，极易踩坑）**：
> - 三个写接口**必须是 `POST` + `Content-Type: application/x-www-form-urlencoded`**，`func` 放查询串、参数放 body；
>   用 GET 调用一律返回 `status:20`（参数非法），会误判成「没权限」；
> - `createdir` 的参数名是 `dest_path` + `dest_folder`（不是 `dest`）；`rename` 是 `path` + `source_name` + `dest_name`；
> - `delete` 的 `file_name` **可重复出现**（多选删除），不能再经 `dict` 去重，必须手工拼 `urlencode` 列表；
> - 成功判定只看 `status === 1`。


> **File Station 6 契约要点**（经 9 轮真机探测确定，务必照此实现）：
> - CGI 路径是 `/FileStation6/utilRequest.cgi`，参数是 **`func=get_list`**（**不是** `subfunc=list`）；
> - 旧版 `/cgi-bin/filemanager/utilRequest.cgi?subfunc=list` 在 QTS 5.2 上**只返回空壳 `success:true`、无任何条目**，不可用；
> - `datas[].isfolder` 为 **number**（`1` 为目录）、`filesize` 为 **string**；
> - 状态码语义：`0` 正常 / `5` 路径不存在或无权限 / `20` 参数非法 / `3` 会话失效（缺 `sid`）；
> - 文件名含空格、括号、中文时**必须 URL 编码**后再拼进 `path=`。

**会话关键点**：登录后除携带 `Cookie: NAS_SID=<sid>; home=1` 外，**所有后续请求必须在查询串带上 `sid=`**。
缺 `sid` 时设备返回 `<authPassed>0`，表现为「登录成功但所有指标都是 0」。`QnapApi.get()` 已统一自动补齐该参数。

### 网页验证登录（纯 qlink.to 网页）

网页验证入口只做一件事：内嵌 WebView 打开 `https://qlink.to/`，把 QNAP ID 登录、二次验证、
NAS 账号密码、设备选择**全部交给网页**完成。App 不再做云端选路、不自动导航、不解析设备链接。
旧 ID 云端路由自动登录代码（SmartURL 选路、`cloudPrepareRoute`、设备列表自动点选、404 自愈、
`sniffAddresses`、`advanceAfterAuth` 等）已删除。

网页登录完成后，App 只复用网页会话：

```
① 点「网页验证登录」→ WebView 打开 qlink.to
② 用户在网页里完成 QNAP ID + 二次验证 + 目标 NAS 登录
③ webTick 轮询当前 URL：仍在门户域则只提示等待，不干预
④ 离开门户域（中继节点 / QTS 页）→ tryRelaySession 取 Cookie
   ④a Cookie 有 NAS_SID（网页已登录 QTS）→ adoptRelay 直接沿用
   ④b 否则用中继 Cookie（qcloud_tunnel_* / cloudRelayMode）+ 账号密码走原生 authLogin
⑤ isQtsBody 校验真实 QTS 响应 → SessionManager.save → 自动进入 App
```

**固化点**：

| 不变量 | 落点 | 破坏后的现象 |
| --- | --- | --- |
| 门户域只等待、不自动跳转 | `webTickInner` 的 `isPortal` 分支 | 二次验证码还没输完就被踢回登录页 |
| `_blank` 链接改本窗口打开 | `BLANK_FIX` 注入（门户页前 3 轮） | 点设备链接无反应（ArkWeb 未配多窗口） |
| 网页层绝不因超时自动关闭 | `webTick` 顶层 try-catch，异常不冒泡 | 定时器抛异常导致闪退 |
| 中继 Cookie 必须含路由标志才尝试登录 | `qcloud_tunnel` / `cloudRelayMode` / `NAS_SID` 门 | 门户 API 子域被当节点，烧光 6 次尝试 |
| Cookie 双通道获取 | `fetchCookie` + `document.cookie` 合并 | HttpOnly Cookie 拿不全时误判未就绪 |
| 中继登录必须限次退避 | `relayAttempts`（4s/8s/…，共 6 次） | QTS 判暴力破解，锁账号 |
| 登录成功必须以真实 QTS 响应为准 | `isQtsBody()`：中继过期返回 200 的门户 HTML | 假成功，主界面全 0 |
| 中继 Cookie 随会话持久化 | `DeviceSession.relayCookie` | 冷启动后请求全部返回门户页 |
| 冷启动校验会话仍可用 | `SessionManager.ensureSession` → `QnapApi.ping()` | 带着死会话进主界面 |
| 中继过期给出可操作提示 | `login.fail.relayExpired` + `loginNotice` | 用户「莫名回到登录页」 |

退出登录（`SessionManager.clear`）会一并清掉中继 Cookie，避免下一个账号继承上一个人的中继会话。

### Tailscale 内网地址登录（1.2.15 起，ID 登录入口已切换）

入口：`LoginPage` 的「QNAP ID」页 → 「通过 Tailscale 连接」。这是**五步向导**，每步一个全屏层（`tsPhase` 驱动）：

```
① connecting：TailscaleService.start() 拉起 TailscaleVpnExtensionAbility
   → 系统首次弹 VPN 授权（之后复用）；扩展进程内启动预编译引擎
② auth：Tailscale 登录页（必经，且**不依赖引擎状态**）
   → VPN 授权一旦通过，tailscaleLogin() 立刻置 tsPhase='auth' 并加载 login.tailscale.com，
     不等轮询结果；扩展稍后给出带一次性 key 的授权 URL 时再替换这一页
   → 用户在页面里登录 Tailscale；扩展检测 Running 后写 running 状态
   → UI 轮询确认连接后，页内显示「已连接」，由用户点「下一步」才继续
   → 即使之前登录过 Tailscale（一启动就 running），或引擎直接 failed / stopped，
     这一步都不会被跳过：引擎异常只在页内联提示 + 「重试连接」，不弹失败面板
   → 兜底出口：未连接时可点「跳过 VPN，直接用 IP 登录」，避免引擎不可用时流程死锁
③ pick：点「下一步」后进入「选 IP」步骤
   → 列出 myserver / demouserDrive 精确匹配候选（优先）+ tailnet 全部节点，
     也允许手动填入 100.x 地址；点节点或填地址后点「下一步」
④ login：进入独立的「登录 NAS」界面（目标地址来自上一步），输入 NAS 账号密码
⑤ logging：TailscaleService.login() 依次试 100.x:5000 / :5001，
   isQtsBody() + hostname 校验通过后 SessionManager.save() → 进 App
```

VPN 扩展内部：登录前只建 `192.0.2.0/24` 探针 TUN，拿到 `100.x` 后改为 `100.64.0.0/10` + IPv6 精确路由，
再用 `backendRestartWithTun` 把数据面切到 TUN。

**「App 进入 tailnet」的完整链路（缺一不可）**：

1. 引擎授权完成 → `backendStatus()` 出现 `state=Running`；
2. `backendVpnConfigAsync()` 取到本机 `100.x`（`ipv4|ipv6`）；
3. 销毁探针 TUN，用 `100.64.0.0/10` 路由重建 TUN；
4. **VpnConfig 必须把本应用放进 `trustedApplications`**（白名单才会走该 VPN 网络），
   写进 `blockedApplications` 等于把 App 排除在隧道外；
5. `backendRestartWithTun(stateDir, deviceModel, fd)` 切数据面，状态写 `running`；
6. App 用 `100.x:5000 / :5001` 直连 QTS，系统按路由把流量送进 TUN。

`isBlocking` 在 SDK 里是 **TUN fd 的阻塞模式**，与"应用是否走 VPN"无关，别拿它当开关。

**重要区分：登录 Tailscale 官网 ≠ 授权本机节点**。
网页里登进 `login.tailscale.com/admin/machines` 只是浏览器会话；本机引擎要入网，
必须打开引擎自己签发的 `https://login.tailscale.com/a/<key>`（带一次性 key）。
因此登录页必须显示「授权链接：已就绪 https://…」才可能成功；显示「未取到」时，
在那个页面里怎么登录都不会让引擎变成 `Running`。

**向导固化点**：

| 不变量 | 落点 | 破坏后的现象 |
| --- | --- | --- |
| ID 模式不预校验账号密码 | `submit()` 先按 isIdMode 分流 | 还没到输密码步骤就被表单校验拦住，按钮「无反应」 |
| Tailscale 登录页必经 | `tailscaleLogin()` 在 `start()` 成功后**立刻**置 `tsPhase='auth'`；`tsTick()` 全程不赋值 `tsPhase` | 之前登录过就直接跳到选 IP；引擎 failed 时弹失败面板、登录页根本看不到（历史 bug） |
| 引擎异常不覆盖登录页 | `tsTick()` 只写 `tsEngineErr`，不 `showFailure`、不 `resetTsFlow` | 引擎一报错就把用户踢回普通登录页，看不到 Tailscale 登录页 |
| 重试前只清错误状态 | `TailscaleService.clearStaleFailure()` 仅在 failed/timeout/stopped 时删状态文件 | 无条件删：扩展在跑时 poll 永远返回 starting，卡死；不删：旧的 failed 立刻回读，重试无效 |
| 真实授权 URL 优先 | `tsAuthUrlReal` 标记，兜底页可被真实 authUrl 替换一次 | 只用官方首页登录，引擎不认账、无法完成授权 |
| 授权 URL 不反复赋值 | 已是真实 URL 时不再覆盖 | 每轮换 state 的 URL 反复赋值 → WebView 重载，打断授权输入 |
| 未连接不能进下一步 | `tsAuthNext()` 检查 `tsAuthed` | 还没登录 Tailscale 就进选 IP，节点为空 |
| NAS 登录用向导内独立凭据 | `tsFinishTailscale()` 用 `tsUser`/`tsPass` | 沿用 IP 模式的旧凭据，用户无法在正确时机改密码 |
| 取消/失败彻底复位阶段 | `resetTsFlow()` | 残留 phase 导致下次进来卡在旧步骤 |
| 真实 TUN 用 VPN 白名单 | `realConfig()` 里 `trustedApplications: [本应用]` | 误用 `blockedApplications`（黑名单=绕过隧道）→ VPN 连上了但 App 自己不走 tailnet，访问 100.x 全部失败 |
| 授权窗口足够长 | `AUTH_WAIT_SECONDS = 14400`（4 小时） | 原来 150 秒，输账号+二次验证超时后引擎写 `timeout` 永久放弃，登录成功也不会 Running |
| authUrl 必须解析成纯 URL | `pickAuthUrl()` 取首个 `http` 到 ` | ` 之间 | bridge 返回带 `OK ` 前缀时直接当 WebView src → 白屏 |
| 「下一步」被拦要有强反馈 | `tsAuthBlock` 红字 + 「VPN 连不上？直接用 IP 登录」 | 只改一行淡色小字，用户以为按钮坏了 |
| NAS 登录失败留在向导内 | `tsLoginErr` 内联报错，不 `resetTsFlow()` | 失败即清空流程，向导和已填地址/账号全消失，观感是"点登录没反应" |
| 选 IP 页可退回登录页 | `tsBackToAuth()` 并恢复轮询 | 停在 pick 无法回到 Tailscale 登录，VPN 没连上就死路 |
| 授权链接必须真的拿到 | 扩展 `fetchAuthUrl()`：`backendAuthURLAsync()` 失败退同步 `backendAuthURL()` | 旧版 bridge 异步封装可能不匹配，永远拿不到 URL → 页面停在官网，登录官网只登进后台、不授权本机节点 |
| 换 URL 要显式 loadUrl | `tsLoadAuthUrl()` + `tsApplyAuthUrl()` | ArkUI `Web({src})` 改状态不一定重载，页面停在旧地址（真机现象：引擎有链接但网页不动） |
| 一次性授权链接可换新 | 按「URL 是否变化」判断，8 秒防抖 | 只允许替换一次的话，链接过期后永远卡在失效页 |
| 页面停在管理后台 ≠ 已授权 | 判据只有引擎 `state=Running` | 误以为"已登录"就点下一步，引擎仍 NeedsLogin |
| 状态文件必须判活 | `TsConnectState.updatedAt` + 8 秒心跳阈值（`tsAlive()`） | 扩展被系统回收后文件停在上个快照，网页已提示 `Login successful`、页头却还是 `NeedsLogin`，永远识别不出成功 |
| 判死后要能自愈 | `tsRestartEngine()` 先 `clearStatus()` 再拉起，15 秒节流 | 只弹"请重试"但状态文件还在骗人，重试也不生效 |
| 有 tailnet IP 即算入网 | 扩展 `isInTailnet()`：`state=Running` 或 `tailscaleIPs>0` | 状态机文本滞后时明明已入网却被判成未连接 |
| 100.x 失败要报对原因 | `tsLoginErr = 'login.ts.vpnNeeded'` | 报"名称无法解析或端口未开放"，用户去查 NAS 设置，真因是隧道没起 |

**实现边界（必须知道）**：社区预编译引擎（`libtailscale_go.so` 1.86.5 / BSD-3）**没有导出
`set_authkey` C API**，因此首次接入走交互式 tailnet 授权（App 内嵌 WebView），授权状态持久化在
应用沙箱 `filesDir/tailscale`；之后每次启动都是自动连接。若要完全无交互的 auth key 模式，
必须用 OpenHarmony Go 工具链重新编译带 `TSBackendSetAuthKey` 的引擎，当前本机无 Go 工具链。

**真机验证结果（2026-11-22，1.2.16 已跑通引擎侧）**：

```
state=running  selfIp=100.x.x.x  tailscaleIPs=2  tun=true
peers: myiddrive → 100.x.x.x ; myidnas → 100.x.x.x ; …
```

结论：节点身份**确实持久化**了（00:26 授权一次，00:47 重新启动直接 Running，无需重新登录），
`backendVpnConfigAsync()` 正常返回 100.x，真实 TUN 建立成功，数据面切换成功。
此前"授权成功但一直 NeedsLogin"是**时序问题**：30 分钟授权窗口在用户完成授权前就到期退出，
现已放宽到 4 小时，并加了状态文件心跳判活/自动重连。

首次授权刚落地时引擎状态可能抖动一下，导致 `backendVpnConfigAsync()` 偶发返回
`FAILED | VPN config : backend not running`（真机出现过，直接被写成永久 failed）。
1.2.17 起 `fetchVpnConfig()` 会重试 20 秒才认输。

### 1.2.18 交付优化

- **账号清理**：默认主机 / 账号 / 密码全空；不再持久化明文密码；退出登录同时清理
  `lastEndpoint` / `wanEndpoint` / `albumRoot` / `loginNotice`；Tailscale 向导 NAS 登录步骤
  不再继承主表单凭据。
- **设备信息**：`DeviceOverview` 增加 CPU 温度、系统温度、风扇转速、以太网口数；
  `QnapApi.firstInt()` 兼容多种 QTS 字段标签，缺失数据统一显示 `—`。首页设备卡与
  「我的 → 设备信息」均展示序列号 / 温度 / 风扇。
- **容器端口直达**：`ContainerPort` 保留 `host / container / protocol / hostIP`；容器卡端口改为
  可点击 chip，点击后使用当前会话 `scheme + host + hostPort` 在 App 内 WebView 打开真实容器
  Web 应用，不再拼任何固定地址。
- **响应式**：容器列表按 `sm / md / lg` 走 1 / 2 / 3 列；首页快捷入口大屏改六栏栅格；
  设置页宽屏左右栏按 3:2 分配。

最终包：`dist/QnapNasManager-1.2.18-signed.hap`，SHA-256
`2c08a3bf672701775965d62d764525a0376669bbb5ce61f4fb8daeaf7d5fdcbe`。

### 1.2.19 自动备份

- **开关与状态**：「我的 → 备份与相册」新增「自动备份」状态行，支持开启 / 关闭 / 立即备份；
  状态包含已开启、已关闭、等待首次扫描、授权失效、目录不可写、无新文件等真实结果。
- **文件夹配置**：新增「自动备份文件夹」配置层，手机目录走系统 Picker（支持时直接选目录，
  否则取所选文件所在目录），NAS 目录既可从既有目录选择器选，也可直接输入绝对路径；
  保存前真实检查 NAS 目录可写。
- **执行链路**：App 前台启动与「立即备份」都会触发增量扫描，递归收集最多 4 层 / 200 个文件，
  以「相对路径|大小|修改时间」去重后交给既有 `TransferManager` 上传队列，不重复造传输逻辑。
- **授权边界**：目录 Picker 给的是临时授权。设备支持时调用 `fileShare.persistPermission`
  持久化、冷启动 `activatePermission` 恢复；不支持或未授予时如实提示「重启后需重新选择」，
  不会假装已获得长期权限。退出登录会清除 `autoBackupConfig`，避免跨账号串用目录。

最终包：`dist/QnapNasManager-1.2.19-signed.hap`，SHA-256
`c23ba45fb6a280179080b781631f1cd30541d71fb35c9b414f4198097dc80882`。

### 2.1.1 版本基线

从 2.1.1 起作为新的正式版本基线，包含上述 1.2.18 / 1.2.19 的全部功能与修复：
账号清理、设备信息补全、容器端口直达、响应式布局、自动备份开关与文件夹配置。
`AppScope/app.json5` 与 `AppConstants.ets` 已同步为 `2.1.1 (2001001)`。

最终包：`dist/QnapNasManager-2.1.1-signed.hap`，SHA-256
`9cf73a41138fb2bf4c864dc1adc70d240143183f6a16e06125b8543e164ffd74`。

### 2.1.2 页面能力完善

- **全页下拉刷新**：Home / Files / Docker / Settings 全部接入 `Refresh`，下拉后重新拉取当前页真实数据；
  刷新期间保留旧列表，不闪整页 loading。
- **文件与卷同步**：文件新建 / 重命名 / 删除 / 新建文本文件成功后立即回刷目录；
  上传任务完成后自动回刷当前目录；卷 / 磁盘 / 服务信息在设置页下拉后从 NAS 重取。
- **镜像管理**：镜像页新增「管理镜像」入口，可删除未被容器使用且设备未标记 in-use 的镜像；
  删除以镜像列表真的消失为成功判据，并立即回刷。
- **登录选路与输入保留**：按上次成功端点 / 已填地址 / 外网地址并发探测，选延迟最低的可用线路；
  都不可达时自动切 Tailscale 在线节点。IP / 端口 / 账号跨重启保留，密码不持久化；显式退出登录清空表单。
- **硬件字段**：序列号 / 型号 / 固件 / CPU 温度 / 系统温度 / 风扇 / 网口 / 硬盘数仅在 NAS 返回有效值时显示，
  不再出现 `—` 空项。

最终包：`dist/QnapNasManager-2.1.2-signed.hap`，SHA-256
`d6c996a05213f70cb4f787f0e3cb115a807ca6c083d6160f3f5a525c1754cdc4`。

### 2.1.3 上架合规审查

- **敏感信息**：预览页与工具脚本中的示例账号 / 设备地址改为中性占位值，明文密码改为环境变量读取；
  源码注释中的设备示例同步脱敏。
- **权限最小化**：删除未使用的 `KEEP_BACKGROUND_RUNNING`；媒体读取用途说明改为"仅在用户开启照片备份时
  读取所选文件名"；设置页权限清单与 `module.json5` 声明一一对应，不再展示未声明的通知权限。
- **协议可访问**：新增中英双语隐私政策与服务条款全文，登录页协议文字与「我的 → 关于」均可点击打开，
  离线可读；覆盖信息收集、权限、本地存储、第三方、退出与注销、自动备份、儿童隐私、联系方式。
- **错误与无障碍**：Tailscale 引擎诊断串默认折叠，默认展示可操作提示；纯图标操作补 `accessibilityText`。
- **发布材料**：README 第十一节给出应用描述、权限表、账号注销说明与截图脱敏规范。

最终包：`dist/QnapNasManager-2.1.3-signed.hap`，SHA-256
`4a67f322597484a545327d9264fae6e41be20ca2eac02aee217a6e3ed73de798`。

### 2.1.4 审核预览账号

- **入口**：登录页新增「审核预览账号 → 进入预览」，点击后直接进入主界面，无需设备、账号或网络；
  真实 IP / Tailscale 登录流程和所有 QNAP API 代码完全未改动。
- **虚拟数据**：`common/demo/DemoMode.ets` 内置设备概览、事件、共享与文件、存储池 / 卷 / 硬盘、
  服务、容器 / 端口 / 镜像 / 日志等完整示例数据；`NasRepository` 仅在预览标记开启时返回这些数据。
- **边界**：预览模式下所有写操作返回占位成功但不发任何请求；自动备份不启动；容器端口不打开外部网页。
  主界面顶部常驻「预览模式」提示条并提供「退出预览」，退出登录会同时清除预览标记。
- **隔离**：预览会话使用文档保留地址与示例账号，不含任何真实凭据；跨重启保留，退出即销毁。
- **验证**：validate_project PASS（ZH=EN=625）；sim_ts_flow 全过；release 编译 BUILD SUCCESSFUL（0 error）。
- **分发约定**：本仓库只提供 **unsigned HAP**；签名证书、keystore、口令与 signed 产物一律不入库。

最终包：`dist/QnapNasManager-2.1.4-unsigned.hap`（unsigned），SHA-256
`ee6c182ad2852f76774a66fc4bb5c6bee79bdb25d288d030746b572d61f689f8`。

**后续版本号**：当前基线为 2.1.4，下一次从 2.1.5 递增，不再回到 1.2.x 序列。

**真机诊断：直接读状态文件（最快，无需日志）**：

```bash
hdc shell "cat /data/app/el2/100/base/com.wlt.qnap.nasmanager/haps/entry/files/tailscale-status.json"
```

真机实测可读（`hdc shell` 能进 `el2/100/base/<bundle>/haps/entry/files/`）。
里面的 `state` / `detail` / `authUrl` / `selfIp` / `updatedAt` 就是引擎的全部真相：

- `updatedAt` 距今超过几秒 → 扩展已经死了，文件是旧快照（**这时 UI 必须靠心跳判活**，
  否则会把"VPN 已死"误读成"还在等你登录"）；
- `authUrl` 为空 → 网页登录只会登进官网后台，不会授权本机；
- `state=Running` 或 `tailscaleIPs>0` → 已进入 tailnet。

注意 `tailscale/` 状态目录本身是 700，`ls` 会被拒绝；但 `files/` 下的状态文件可读。

**运行环境要求（务必真机，不能用预览器）**：

DevEco 的 **Previewer（预览器）不支持 VPN 扩展**：`VpnExtensionAbility` 进程不会创建、
原生 `.so` 不加载、ArkWeb 也不真正联网。因此在预览器里点「通过 Tailscale 连接」，
永远看不到 Tailscale 登录页——这是环境限制，不是代码问题。

判别方法：IDE 日志里若出现 `-p previewMode=true ... PreviewBuild --watch`，
说明当前是预览构建；真机运行会是 `assembleHap` + `hdc install`。

正确姿势：顶部设备下拉选真机（如 `192.0.2.10`）→ 点 **▶ Run 'entry'**。
且真机安装需要设备信任的签名：本工程 `build-profile.json5` 用的是自签 release 证书，
零售机不信任，`hdc install` 会报 `code:9568257 error: fail to verify pkcs7 file`；
需在 Project Structure → Signing Configs 勾选 **Automatically generate signature**
（登录华为账号自动签发绑定本机 UDID 的调试 profile）后再 Run。
自签配置已备份为 `build-profile.selfsigned.json5.bak`，上架时切回即可。

**IPC 与进程约束**：引擎只能在 VPN 扩展进程里跑一个实例；UI 进程只读状态文件，绝不再起一个引擎，
否则两个实例争抢同一设备身份会无限重连。状态文件：`tailscale-status.json`。
可选控制面地址文件：`tailscale-control-url.txt`（默认 `https://controlplane.tailscale.com`）。

**原生 bridge 调用约束（真机踩坑，务必按本工程 so 的实际签名）**：

本工程打包的 `libtailscale_ohos.so` 是**旧版 bridge**，签名与上游最新源码不同。
从 so 内可直接验证这一点：so 里只有 `backendStart requires state directory and device model`
和 `backendRestartWithTun requires state directory, device model and TUN descriptor`，
**没有** `OS version` / `control server` / `controlURL` 相关字符串。

| 函数 | 本工程 so 实际签名 | 上游最新（不可照抄） |
| --- | --- | --- |
| `backendStart` | `(stateDir, deviceModel)` — **2 参数** | `(stateDir, deviceModel, osVersion, controlURL)` 4 参数 |
| `backendRestartWithTun` | `(stateDir, deviceModel, fd)` — **3 参数** | 5 参数 |

**参数个数必须与 so 完全一致**，多传任何一个都会让原生 `argc` 校验失败，抛出
`backendStart requires state directory and device model`（看起来像"缺值"，其实是"多参"）。

补充约束：
- `stateDir` 必须是**已存在**的目录（`filesDir/tailscale`，调用前先 `mkdirSync`）；
- `deviceModel` 不能为空：用 `marketName`（去 Huawei 前缀、排除 default）回退 `productModel`，
  再兜底常量；对齐上游 `DeviceNameService.model()`。空串同样会被拒。
- 原生异常会带 `<msg>` 写入失败面板，便于定位。
- 若要升级到上游新版 bridge，必须同时替换 so 并改回 4/5 参数签名，两者必须成对。

**前置条件**：NAS（TS-464C，x86-64）在 QNAP App Center 装官方 Tailscale 并加入同一 tailnet；
ACL 仅放行移动端 tag 访问 NAS 的 5000/5001；不要启用 Funnel 把 QTS 暴露到公网。


### 该机型真实可得 / 不可得的数据（真机逐项探测结论）

| 界面字段 | 实测值 | 说明 |
| --- | --- | --- |
| CPU 使用率 | `23.1 %` | `cpu_total_usage` |
| 内存 | `2.3 / 15.4 GB` | `mem_used` / `mem_total`（KB） |
| CPU 温度 | `47~52 ℃` | `cpu_tempc`（台式无系统温度传感器，故系统温度显示 `—`） |
| 已运行 | `0天 10时 50分` | `sys_uptime_day/hour/min` |
| 存储卷 | `DataVol1`，可用 `3546 GB`，磁盘 `1` | 设备**不提供总容量**，因此只呈现可用空间，不显示已用率 |
| 磁盘标识 | `3.5" SATA HDD 1` | 来自 `swap_mem_info` 的分区描述；型号 / 序列号 / SMART / 容量均未提供，一律显示 `—` |
| 交换空间 | `22.9 GB` | `swap_total` |
| 以太网口 | `2` | `eth_count`；该机型**不开放**网口吞吐统计，故不再显示虚假的 0 MB/s |
| 系统服务 | `FileStation6`、`musicStation`（运行中）、`hdStation`（已停用） | 来自 `sysinfoReq.cgi` 的 `serivceList` |
| 共享目录 | `Public`、`Container` | 来自 `privRequest.cgi?subfunc=share`，并逐个 `files(path,1)` 探测确认真实存在（`TMBackup` 未创建，返回 `status:5`） |
| 文件条目 | `Public`：`Mate60Pro微信备份`、`music`、`novel` 等 6 项 | 真实 `File Station 6` 列表，`owner=demo-user`、`privilege=777`、真实修改时间 |
| 序列号 | 空 | 设备未上报，界面显示 `—` |

接口暂不支持或未授权时**返回空集合，页面渲染真实空态，绝不填充假数据**。

**限流实测**：QTS 对同一会话的并发 / 高频请求会返回空响应或 404。因此：

- ArkTS 端 `QnapApi.get()` 对空结果退避 400ms 后重试一次（`delay()` 辅助）；
- 各页面数据**串行**加载，不并发打设备；
- 开发期代理 `tools/qnap_proxy.py` 用 `QnapClient._lock` 串行排队 + 退避重试；
- 预览页 `loadData()` 也改为串行拉取，数据就绪后统一重绘。

### ArkTS 严格类型实现要点（编译实测）

- base64 为纯 ASCII 逐字符实现（不依赖 `TextEncoder`）；
- JSON 解析统一 `JSON.parse(body) as <显式接口>`，字段全部显式类型 + 可选属性；
- 不使用 `any` / 动态下标 / `@ts-ignore`；
- 模型契约（`model/Models.ets`）全部为 `interface`，对象字面量可直接结构化赋值。

---

## 三、工程结构

```
QnapNasHarmony/
├── AppScope/                         应用级配置与中英文应用名
├── build-profile.json5               signingConfigs / products / buildModeSet
├── entry/
│   ├── build/default/outputs/default/   ★ release signed + unsigned HAP
│   └── src/main/
│       ├── module.json5              Ability、phone/tablet/2in1、INTERNET 权限
│       ├── resources/
│       │   ├── base|zh_CN|en_US/element/   系统级文案与色板
│       │   ├── base/media/                 48 个图标（1 PNG + 47 SVG）
│       │   └── base/profile/main_pages.json
│       └── ets/
│           ├── entryability/EntryAbility.ets   入口 Ability、系统深浅色同步
│           ├── pages/Index.ets                 根页面：登录态路由 + 断点发布 + 渐变底
│           ├── common/
│           │   ├── constants/AppConstants.ets 常量与状态枚举（默认真实连接信息）
│           │   ├── constants/Theme.ets        素雅色板 + 雾玻璃/渐变令牌
│           │   ├── i18n/I18n.ets              中英文案与应用内切换
│           │   └── utils/BreakpointSystem.ets 断点 + 大屏栅格/间距/圆角令牌
│           ├── model/Models.ets               静态类型数据契约（interface）
│           ├── service/                      QnapApi（真实接口）+ NasRepository + SessionManager
│           ├── components/
│           │   ├── AdaptiveShell.ets          ★ Swiper 左右滑动外壳 + 分组侧栏 + 顶栏
│           │   ├── CommonCards.ets            素雅卡片体系（支持 glass 雾玻璃）
│           │   └── StateView.ets              统一状态视图
│           └── feature/                      ← 按需求划分的四大模块
│               ├── login/LoginPage.ets       登录（真实 IP 直连，默认 192.0.2.10）
│               ├── home/HomePage.ets         设备主页（真实概览 + 雾玻璃框）
│               ├── files/FilesPage.ets       文件（真实 File Station 6 列表）
│               ├── docker/DockerPage.ets     容器（真实 Container Station）
│               └── settings/SettingsPage.ets 个人中心与设置（含存储卷 / 硬盘 / 服务）
├── preview/index.html                交互预览（雾玻璃 + 左右滑动）
└── tools/
    ├── qnap_proxy.py                 ★ 真实数据本地代理（预览页 CORS 桥接）
    ├── gen_assets.py                 生成图标资源
    ├── validate_project.py           工程静态一致性校验（含 JSON5 注释）
    ├── validate_preview.py           预览 JS 语法与文案校验
    ├── smoke_preview.js              交互路径无头测试
    ├── shoot_preview.py              ★ Playwright 无头登录真实 NAS 并批量截图
    ├── audit_palette.py              ★ Pillow 像素级配色审计（暖黄占比 / 饱和度）
    ├── install_device.py             一键连接 / 安装 / 拉起真机
    ├── prepare_signing_config.js     生成 hvigor 可解密的加密口令 + material/
    ├── sign_release.py               完整 release 证书链 / profile / HAP 签名与验签
    └── signing/                      证书、keystore、profile、验签结果与产物
```

> `tools/probe_fs*.py`、`tools/probe_ops.py`、`tools/probe_fs_ops.py` 为打通 File Station 6 读写契约时的一次性真机探测脚本，保留以备复查接口，不再参与构建。Container Station 5 的 v3 契约（`/container-station/api/v3/*` + `Authorization: Bearer <sid>`，401=会话失效 / 404=未安装 / 200=`data.items`）已在本轮经真实设备验证并固化进 `QnapApi.ets`，其一次性探测脚本已清理。

---

## 四、编译与运行

### 本机真实构建命令（已验证）

```powershell
$env:DEVECO_SDK_HOME = "C:\Program Files\Huawei\DevEco Studio\sdk"
$env:NODE_HOME      = "C:\Program Files\Huawei\DevEco Studio\tools\node"
$env:PATH = "C:\Program Files\Huawei\DevEco Studio\tools\node;C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin;" + $env:PATH
& "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap `
    --mode module -p product=default -p buildMode=release --no-daemon
```

| buildMode | 结果 | 产物 |
| --- | --- | --- |
| `debug` | BUILD SUCCESSFUL（0 error / 0 warning） | unsigned HAP |
| `release` | BUILD SUCCESSFUL，`SignHap` 真实执行、无签名警告 | `entry-default-signed.hap` + `entry-default-unsigned.hap` |

> 构建命令需同时给出 `DEVECO_SDK_HOME`（否则报 `00303217 Configuration Error`）与 `NODE_HOME`；`DEVECO_SDK_HOME` 指向 `C://Program Files\Huawei\DevEco Studio\sdk`。

`build-profile.json5` 已配置 `signingConfigs[release]` 与 `products[0].signingConfig`，hvigor 会原生完成签名。加密口令与 `material/` 由 `tools/prepare_signing_config.js` 生成（与 DevEco「自动生成签名」同一套 `DecipherUtil` 机制），脚本自带反向解密自校验。

### 独立签名 / 验签链路

```bash
python tools/sign_release.py                # 完整重建证书链、profile 并签名 HAP
python tools/sign_release.py --verify-only  # 只复核现有 profile 与 signed HAP
```

链路：`generate-keypair → generate-csr → generate-ca(root) → generate-ca(app/profile 子 CA) → generate-app-cert / generate-profile-cert(certChain) → sign-profile → verify-profile → sign-app → verify-app`。全部 9 步在本机通过，`Digest verify result: true`。

### 交互预览（无需 SDK）

1. （可选，接真实数据）启动代理：`python tools/qnap_proxy.py`（默认 `127.0.0.1:7890`，桥接 `192.0.2.10:5000`）。代理的 `/api/overview`、`/api/storage`、`/api/services`、`/api/containers` 返回结构与 ArkTS 端 `DeviceOverview` / `StorageBundle` / `ServiceInfo` / `ContainerListResult` **完全一致**，预览所见即真机所见。
2. 浏览器打开 `preview/index.html`：顶部工具条可切换 **手机 / 平板**、**中文 / English**、**浅色 / 深色**；登录卡顶部的两枚胶囊可在 **本地 IP / QNAP ID** 间切换（ID 模式走 `<name>.myqnapcloud.com` + 8081/443 探测）；进入后**左右滑动**在四个页面（设备主页 / 文件 / 容器 / 我的）间切换，所有卡片为雾玻璃框，手机底栏是**悬浮圆角雾玻璃长条**。
3. 文件页的**新建 / 重命名 / 删除**会真的打到设备（`POST /api/mkdir|rename|delete`，与真机同一套 FS6 form-urlencoded 契约），删除为移入 `@Recycle`；容器页在未装 Container Station 的设备上显示「未安装」引导页而非空列表。代理未启动时可点「离线预览界面」查看 UI（真实空态，无假数据）。

---

## 五、鸿蒙 7 设计：雾玻璃 + 左右滑动 + 大屏范式

- **雾玻璃以框的形式展示**：`CardContainer` / `MetricTile` 支持 `glass: true`，组合 `backgroundBlurStyle(BlurStyle.Regular)` + **高不透明度**底（`#FFFFFFF2` / `#1E222AD9`）+ **可见淡灰描边**（浅色 `#E2E6EB` / 深色 `#2E333B`）+ 极轻投影（`rgba(31,38,51,0.05)` / `rgba(0,0,0,0.22)`）；`Theme.ets` 统一下发 `glassBg / glassBorder / glassShadow` 令牌。设备主页等栏全部以玻璃框呈现。
  - 底色改为近乎不透明是**刻意为之**：玻璃层会采样窗口背景，若沿用系统默认底色，设备壁纸 / 主题的**暖黄调会透过模糊层给整页染色**，去不掉黄。配合 `EntryAbility` 显式 `setWindowBackgroundColor('#F4F5F6')` 彻底阻断渗透。
- **系统强调色泄漏防护**：HarmonyOS `Button` 默认取系统强调色（可能是暖黄），因此所有 `Button` 一律 `ButtonType.Capsule` + 显式 `backgroundColor / fontColor`（`Theme.buttonPrimaryBg / buttonPrimaryFg / buttonGhostBg / buttonGhostFg / buttonDangerBg`）；`Toggle` 显式 `selectedColor` + `switchPointColor('#FFFFFF')`；`TextInput` 显式 `caretColor`。
- **页面柔和渐变底**：外壳与页面铺 `linearGradient`（`Theme.pageGradientColors` 返回 `[颜色, 位置]` 元组数组），玻璃框模糊其后方，形成通透大气观感。
- **所有页面左右滑动**：四个业务页（设备主页 / 文件 / 容器 / 我的）统一放入 `Swiper`；`goTo()` 与侧栏 / 底部导航双向同步，`onChange` 回写当前页；`loop` 关闭、指示器隐藏，滑动与点按等效。
- **三段式外壳**：`AdaptiveShell` 在 md / lg 下呈现「分组持久侧边栏（概览 / 管理 / 系统）+ 顶部应用栏 + 居中限宽内容区」；sm 为悬浮底栏 + 单列。
- **手机底栏 = 悬浮雾玻璃圆角长条**：不再是贴底通栏，而是一条浮在内容之上的胶囊长条 ——
  `height 62vp` / `borderRadius 26vp` / 半透明底（浅色 `#FFFFFFD6`、深色 `#1E222AC4`）/ `backgroundBlurStyle(BlurStyle.Regular)` / 1vp 淡描边（`#DFE3E9` / `#343A44`）/ `shadow(radius 26, offsetY 8)`；
  当前项套一层 `barActiveBg` 胶囊（浅色 `#EAF0F8` / 深色 `#26344D`），内容区预留 `BAR_HEIGHT + 22` 的底部内边距，滚动时内容从长条下方穿过，形成真实的悬浮层次。
  侧边栏与顶栏同步改为 `chromeBg`（`#FBFBFCD2` / `#171A1FC2`）+ 系统模糊 + 单边描边，全局只有一套雾玻璃语言。
- **页面自身持有滚动**：`pagedContent()` 的 Swiper 子项**不再包 `Scroll()`**（此前 `Scroll(){ HomePage() }` 让页面 `height('100%')` 失去确定值，直接导致整页空白）；滚动下沉到各页自己的 `Scroll().layoutWeight(1)`，`PageHeader` 固定不动。

- **素雅色板（默认，零暖黄）**：中性灰基底 `#F4F5F6 → #FAFAFB` + 白卡片 `#FFFFFF` + 1px 极淡描边 `#E7E9EC`；强调色为克制钢蓝 `#3D74C4`（仅用于按钮 / 选中 / 链接等小面积），大面积图表用低饱和墨蓝 `#7D93B8`，成功 `#4E8C74` / 注意态冷灰 `#6E7681` / 危险 `#B5615C` 均去饱和处理。深色模式同步一套（`#16181C → #0F1114` 基底 / `#1B1E23` 卡片）。`Theme.ets` 为唯一样式来源，`preview/index.html` 的 CSS 变量与之逐一对应。
  - 原警告色 `#B08A4E`（暖黄褐）已改为冷灰 `#6E7681`，`color.json` 同步 `warning #F5A623 → #6E7681`、`primary #0A59F7 → #3D74C4`、`success #31B773 → #4E8C74`、`danger #E5544B → #B5615C`。
  - 像素级审计（8 张真机数据截图）实测**暖黄像素占比 0.0000%**、中位饱和度 0.11~0.14。
- **栅格令牌**：`BreakpointSystem` 统一下发分栏数、间距、圆角、标题字号与最大内容宽度，页面不写魔法数字。

**容器宽度驱动**：根页面 `onAreaChange` 读取实际可用宽度（vp）→ `sm / md / lg` → `AppStorage('breakpoint')`，所有页面通过 `@StorageProp` 订阅。旋转、分屏、自由窗口自动重算；`module.json5` 声明 `phone / tablet / 2in1`。

---

## 六、模块说明

### 1. 登录模块 `feature/login/`

- **双登录方式（本轮新增）**：顶部两枚等宽胶囊在 **本地 IP** 与 **QNAP ID** 之间切换，`S.mode` 存于 `AppStorage('loginMode')`，设置页可再次切换。
  - 本地 IP：`192.0.2.10 : 5000`，IPv4 / 端口 / 账号逐字段校验，`httpsOn` 默认关闭（`http://192.0.2.10:5000` 实测可登）；
  - QNAP ID：填设备主机名（如 `demouserDrive` / `myiddrive.local`）、QNAP ID 或完整域名；纯名字**原样优先**，解析不到才补 `<lower>.myqnapcloud.com`；端口留空时按 **`http:5000 → https:8081 → https:443 → http:8080`** 矩阵探测（实测设备仅开放 5000，旧实现只试 8081/443 且固定 https 故必失败）。凭据错误（`login.fail.invalid`）立即返回、不再换候选重试；失败卡片额外回显实际尝试过的 `host:port` 便于排错。
- **真实登录**：`submit()` 为 `async`，分别走 `NasRepository.loginById()` / `NasRepository.login()`（base64 密码 + `authLogin.cgi`）；失败按 `errorKey`（`login.fail.invalid` 凭据错误 / `login.fail.network` 网络不可达 / `login.fail.idFormat` 格式错误）给出**分模式**的成因与两条排查建议。
- **登录态**：`DeviceSession` 持久化 **`sid` / `scheme`** 等会话标识，不保存明文密码；冷启动 `SessionManager.ensureSession()` 恢复会话，`refreshSid()` 回写新 sid —— 这是「冷启动后所有数据变 0 / 页面空白」的根因修复。
- **平板登录页**：左右分屏，左侧品牌区，右侧限宽玻璃登录卡片。

### 2. 个人中心与设置 `feature/settings/`

- `sessionCard()`：登录方式（可点开切换）、账号、接入地址（`host:port` 或 myQNAPcloud 名称）、登录时间，底部「退出登录」；切换登录方式会 `SessionManager.clear()` 并回到登录页。
- `profileCard()` 顶部显示 `StatusTag` 形态的登录方式与接入地址，一眼可辨当前是 IP 还是 ID 连接。
- `galleryCard()`：手动备份 NAS 目录选择、相册 / 聊天图片入口，以及 1.2.19 新增的**自动备份开关、状态、立即备份、手机 / NAS 文件夹配置**；配置由 `AutoBackupService` 持久化，执行复用 `TransferManager`。
- 存储容量 / 卷 / 磁盘 / 服务信息并入本页：**存储概览卡片**（可用空间大字 + 卷名 + 卷类型 / 磁盘数 / 加密 / 分区 / 交换空间）、**硬盘列表卡片**、**服务列表卡片**（默认前 6 条，可展开全部）。原独立文件 `feature/storage/StoragePage.ets` 已整体删除，避免与底栏重复入口；宽屏卡片置于左栏，窄屏顺排单栏。

### 3. 设备主页 `feature/home/`

`async load()` 拉取真实概览（`sysmonitor`：CPU / 内存 / 温度 / 网络吞吐 / uptime）与近期事件（`syslog`）：健康横幅、四指标玻璃框栅格、存储容量、**三个快捷入口**（文件 / 容器 / 设置）、近期事件、设备信息。布局为「`PageHeader` 固定 + 内容区 `Scroll().layoutWeight(1)`」，平板为大屏三段式。

### 4. 核心功能模块

| 模块 | 能力 | 数据 |
| --- | --- | --- |
| `feature/files/` | 目录导航 / 搜索 / 排序 / 列表·网格 / 多选 / 新建·重命名·删除 / 属性；平板分组目录侧栏 | 真实 File Station 6 列表（`func=get_list`）+ 真实共享目录名单（`privRequest subfunc=share`）+ 真实写操作（`createdir` / `rename` / `delete`） |
| `feature/docker/` | Container Station 5 容器列表 / 状态 / 端口 / 项目 / 运行时长 / 启停·重启 / 删除；端口 chip 可点击直达容器 Web 应用；**未安装态**独立成页（404 判定）/ **会话失效态**独立成页（401 判定） | 真实 `/container-station/api/v3/containers`（Bearer 鉴权）；Web URL 由当前会话 host/scheme + `portBindings[].host` 拼出；创建 / 拉取镜像 / 单容器日志三类未证实 v3 契约的能力在界面**隐藏入口**，绝不给假按钮 |

**文件页数据链路（本轮修复重点）**：此前恒显「文件夹为空」的根因是**用了 QTS 5.2 已废弃的 `filemanager/utilRequest.cgi?subfunc=list`，该接口只返回 `success:true` 空壳**。修复后：

1. `QnapApi.shares()` → `privRequest.cgi?subfunc=share` 取共享名单（解析 `defShareList` 与 `no_del_info/share_name`），并对每个共享逐个 `files(path, 1)` 探测，**只保留真实存在者**（如 `/TMBackup` 未创建会被剔除）；结果按会话缓存，`login()` 时 `resetShareCache()`；
2. `QnapApi.files(path)` → `/FileStation6/utilRequest.cgi?func=get_list`，解析 `datas[]`（`isfolder` 为 number、`filesize` 为 string，需 `parseSize()` 转数值）；
3. `FilesPage.load()` 多态区分：**成功** → 渲染真实条目；**`status===5`** → 「目录不存在或无权访问」；**`status===3`** → 「会话失效/无权限」；**目录条目为 0** → 「文件夹为空」；**其他失败** → 错误态 + 重试；**共享名单为空** → 「无共享目录」；
4. 侧栏 `locations()` 遍历真实共享目录，`pathLabel()` 把 `/Public/music` 显示为 `Public / music`；`goParent()` 以 `lastIndexOf('/') <= 0` 判断是否已到共享根（根路径 `/` 不可列举）；
5. **写操作全部接真实接口**：`mkdir` / `rename` / `removeItems` 走 POST + form-urlencoded，成功后 `await this.load()` 重取列表，失败按返回码提示；已移除「上传 / 复制 / 移动」等无后端支撑的假按钮。
6. **常驻「返回上一层」按钮（本轮修复）**：文件页顶部始终有一条 `up-bar`，显示当前路径并带「← 返回上一层」胶囊；无论在子目录、空目录还是 `status:5`（路径不存在）状态都能退回上级，避免被困在子目录里无法返回——此前无该入口导致「能看到文件夹却无法使用」。

**容器页（本轮修复重点）**：此前误判「未安装」的根因是 CS 5 已废弃 `/cgi-bin/container-station/api/v2/...`，该路径在已装 CS 5 的机器上**一律 404**；而 `sysinfoReq` 的 `serivceList` 本就不含 Container Station，进一步误导。现在：
- 网关切到 CS 5 真实路径 `/container-station/api/v3/*`，首页 `/container-station/` 返回 200 即判「已安装」；`containersResult()` 三态判定：**404** → `installed=false`（未安装）；**401** → `installed=true` 但会话失效（提示重新登录）；**200** → 解析 `data.items`（`id`/`name`/`image`/`status`/`portBindings`/`cpu`(核占比)/`memory`(GB)/`startedAt`/`project`）；
- 未安装时渲染 `notInstalledView()`：一句结论 + 两步指引（App Center 安装 → 回页刷新）+ 刷新按钮；会话失效时渲染独立提示页；都不用「暂无容器」糊过去；
- 已安装时展示真实容器（状态 / 端口 / 项目 / 运行时长 / ID），支持真实启停 / 重启（操作后轮询列表比对 state 才算成功）/ 删除；
- CS 5 的**创建容器 / 拉取镜像 / 单容器日志均无已证实的 v3 契约**，这三个能力如实返回「不支持」，界面据此**隐藏入口**而非给出假按钮。

---

## 七、国际化

- 文案集中在 `I18n.ets`，中英文案一一对应（**ZH = EN = 606 键**，覆盖登录双模式 / 智能选路 / Tailscale 向导 / 自动备份 / 镜像管理 / 容器未安装态 / 端口直达 / 设备信息 / 写操作反馈 / 返回上一层 / 版权等）；`t(key, lang)` 取值，缺失时回退中文再回退 key。
- 语言状态存 `AppStorage('appLanguage')`，页面 `@StorageProp` 订阅，切换后全量刷新。
- 系统级应用名 / 权限原因走资源限定词 `base / zh_CN / en_US`。

---

## 八、校验与调试结果

| 校验 | 命令 / 动作 | 结果 |
| --- | --- | --- |
| 工程静态一致性 | `python tools/validate_project.py` | **PASS**：20 ETS、**ZH=EN=427** 双语键、48 图标，无未解析引用、无演示残留 |
| ArkTS 真实编译 | `assembleHap -p buildMode=debug` | **BUILD SUCCESSFUL**（0 error / 0 warning） |
| release 真实编译 + 签名 | `assembleHap -p buildMode=release` | **BUILD SUCCESSFUL**，`SignHap` 真实执行 |
| profile 签名 / 验签 | `sign-profile` / `verify-profile` | **PASS**，`verifiedPassed: true` |
| HAP 签名 / 验签 | `sign-app` / `verify-app` | **PASS**，`Digest verify result: true`，SHA256withECDSA / EC 256 |
| 真机数据验证（代理） | `POST /api/login` → `GET /api/shares` → `GET /api/files?path=/Public` | `shares=["/Public","/Container"]`；`/Public` 返回 6 条真实条目；`/NotExist` → `status:5` |
| **文件写操作实测（代理）** | `mkdir → rename → delete`（临时目录 `__wlt_probe_ui__`） | 三步全部 `{"ok":true,"status":1}`；重命名后旧名消失、新名出现；删除后列表无残留 |
| **容器未安装态判定** | `GET /api/containers` | `{"items":[],"installed":false,"error":"HTTP Error 404"}` → 应用渲染「未安装 Container Station」页 |
| 预览页一致性 | `python tools/validate_preview.py` | **PASS**：ZH=EN=140 键，JS 语法与 handler 引用全部解析 |
| 视觉去黄像素审计 | `python tools/audit_palette.py` | **13 张截图暖黄像素占比全部 0.0000%**，中位饱和度 0.07~0.40 |
| 无线调试真机连接 | `hdc tconn 192.0.2.10:35475` | 曾 **Connect OK**；HUAWEI Mate 60 Pro，HarmonyOS 7.0.0.111，API 26（当前会话已断开，需重新 tconn） |

### 本机调试中修复的问题（真实编译暴露）

1. `hvigor/hvigor-config.json5` 声明了需从 npm 下载的 `@ohos/hvigor` → 404；改为 `dependencies: {}`。
2. `build-profile.json5` 的 `products[0]` 含 schema 不允许的 `buildMode` → 删除。
3. ArkTS `@Builder` 名与 `CustomComponent` 基类冲突：`toolbar` → `fileToolbar`、`placeholder` → `statePlaceholder`。
4. `AppScope/app.json5` 的 `targetAPIVersion` 对齐本机 SDK 改为 20。
5. `validate_project.py` 误扫构建缓存 JSON，并修复对 JSON5 注释 / 尾逗号的支持。
6. **真实设备接入 + 雾玻璃 + 滑动改版后的编译修复**：
   - `linearGradient` 的 `colors` 须为 `[ResourceColor, number][]`（颜色+位置元组），`Theme.pageGradientColors` 相应改为元组数组；
   - `Swiper` 构造参数须为 `SwiperController`（不能传 `{index}`），改用控制器 + `.index()` 响应式属性驱动；
   - `BlurStyle.None` → `BlurStyle.NONE`（枚举命名）；
   - `@Builder` 返回 void，不能链式 `.layoutWeight()`，布局属性移入 Swiper 自身；
   - `TextEncoder` 非全局（在 `@ohos.util`），改为纯 ASCII base64；
   - `@ts-ignore` / 动态下标 / 内联对象类型均被 ArkTS 严格模式禁止：JSON 解析改为 `as <显式接口>`，`storage()` 返回类型改为 `StorageBundle` 接口。
7. **本轮（底栏改版 / 页面空白 / 双登录方式）修复**：
   - `AdaptiveShell.pagedContent()` 里 `Scroll(){ HomePage() }` 让页面 `height('100%')` 失去确定值 → **整页空白**；改为滚动下沉到各页自身，`PageHeader` 固定；
   - `DeviceSession` 未持久化 `sid` → 冷启动后所有请求被判未认证，数据全 0 / 列表空白；补 `sid / scheme / password` 字段 + `SessionManager.ensureSession()` 静默重登；
   - File Station 写接口错误地用 GET 调 → 一律 `status:20`；改 POST + form-urlencoded 后全部 `status:1`；
   - 容器端点 404 曾被当成「空列表」→ 改为 `ContainerListResult.installed` 一等状态。

---

## 九、应用商店发布标准核对

| # | 项目 | 状态 | 说明 |
| --- | --- | --- | --- |
| 1 | Stage 模型 / ArkTS 静态类型 / 无 `any` / 无非空断言 | ✅ | 真实编译 + 静态校验 PASS |
| 2 | `bundleName`、版本号、图标、应用名资源 | ✅ | `com.wlt.qnap.nasmanager` / `2.1.4` / `QTS NAS` / 48 图标 |
| 3 | 设备类型 `phone / tablet / 2in1`、多断点适配 | ✅ | 宽度驱动 sm / md / lg |
| 4 | 权限最小化与申请原因 | ✅ | `INTERNET`、`GET_NETWORK_INFO`、`READ_IMAGEVIDEO` 三项 + `$string` 用途说明；未使用的 `KEEP_BACKGROUND_RUNNING` 已删除 |
| 5 | 中英双语、深浅色 | ✅ | 625×2 文案键 |
| 6 | release 构建 + 代码压缩 | ✅ | signed HAP |
| 7 | `app_gallery` 类型 release profile | ✅ | `verify-profile` PASS |
| 8 | HAP 签名 + 验签 | 本地自备 | 仓库只分发 unsigned；签名需自有 AGC 证书与 `QNAP_SIGN_PASSWORD` |
| 9 | **AGC 官方证书 / provision profile** | ❌ | 当前为**本地自签**，设备不信任；上架必须替换 |
| 10 | **真机安装运行** | ❌ | `hdc install` 报 `code:9568257 fail to verify pkcs7 file` |
| 11 | 隐私政策 / 权限说明页 | ✅ | 登录页协议文字可点击；「我的 → 关于」提供完整中英文本，离线可读 |
| 12 | 应用签名证书 SHA256 指纹登记、AGC 应用创建 | ❌ | 需开发者账号 |
| 13 | 应用截图、软著、备案与公开政策 URL | ❌ | 需开发者/法务提供，见第十一节 |

### 真机安装被拦截的确切原因与解法

无线调试设备 **HUAWEI Mate 60 Pro / HarmonyOS 7.0.0.111 / API 26** 已连接成功，UDID 已写入 `tools/signing/qts-debug-profile.json`（`debug` 类型 + `device-ids`）。设备只信任华为签发链，本地自签 profile 的 pkcs7 无法通过校验。

**解决步骤（需华为开发者账号）**：

1. 用 DevEco Studio 打开本工程并登录华为账号；
2. `File → Project Structure → Signing Configs` 勾选 **Automatically generate signature**（或到 AGC 创建应用、上传 `tools/signing/qnap-release.csr` 申请证书与 profile）；
3. 用 AGC 下发的 `.p12` / `.cer` / `.p7b` 替换 `build-profile.json5` 的 `signingConfigs[release].material`；
4. 重新执行 `assembleHap -p buildMode=release`；
5. 一键安装（自动连接 / 安装 / 拉起）：

   ```bash
   python tools/install_device.py                 # 默认 192.0.2.10:35475
   python tools/install_device.py --list          # 先看设备是否在线
   ```

   脚本等价于 `hdc tconn <target>` → `hdc install -r entry-default-signed.hap` →
   `hdc shell aa start -a -b com.wlt.qnap.nasmanager -m EntryAbility`。

6. 安装后在真机验证：平板横竖屏、语言与主题切换、左右滑动，以及连接真实设备后的数据一致性。

> **无线调试注意**：设备息屏会断开 `hdcd` 会话，`hdc list targets` 会变空。
> 此时点亮屏幕并重新进入「开发者选项 → 无线调试」即可恢复；若仍为 `[Empty]`，先 `hdc kill && hdc tconn <ip:port>`。

---

## 十、边界说明

1. 数据全部来自真实 QTS HTTP API（`QnapApi.ets`）；**无任何演示 / 模拟数据**。接口未授权或暂不支持（如存储池聚合、容器指标详情）时返回空集合，页面渲染真实空态。
2. **QTS 的 `volumeList/Progress` 字段不是容量已用率**（实测恒为 100，表示卷就绪进度）。因此本工程不再用其推导已用率：设备未上报总容量时，界面只呈现真实可用空间（`freeSize`）与卷状态，不显示「已用 / 总量」进度条。
3. 设备的磁盘明细（型号 / 序列号 / SMART / 单盘容量）未通过任何已开放接口暴露，界面按「未提供」呈现 `—`；分区标识来自 `swap_mem_info` 的 `swap_patition_desc`，是设备真实上报值。
4. 网口吞吐统计（`rx_bytes` / `tx_bytes`）在该机型不可得，网络指标改为展示真实上报的以太网口数量 `eth_count`。
5. 登录为真实 `authLogin.cgi` 判定：凭据正确即进入设备主页，错误 / 不可达给出明确原因（空响应判为网络不可达，`authPassed≠1` 判为凭据错误）。
6. 存储池聚合接口未开放，「我的」页面只呈现真实上报的卷 / 磁盘标识 / 交换空间与服务列表，不虚构存储池层级；独立的「存储」页面已并入「我的」。
7. `tools/signing/` 下的证书与口令属于**本地自签测试材料**，不要用于生产环境或提交到公开仓库；正式上架须替换为 AGC 材料。真机安装另需华为链签名（见下节）。
8. 本机 SDK 为 API 20，真机为 API 26；工程按 API 20 编译，向下兼容目标设备。

---

## 十一、上架合规审查（2.1.3）

### 11.1 应用描述（可直接用于商店填写）

**中文简短描述**：连接和管理你的 QNAP NAS：查看设备状态与硬盘信息，浏览、上传和下载文件，管理容器与镜像，并支持照片自动备份与 Tailscale 加密远程连接。账号与数据仅保存在本机和你的 NAS。

**中文完整描述**：QTS NAS 管理器是一款本地优先的 NAS 管理工具。通过局域网地址或 Tailscale 安全隧道连接你的 QNAP QTS 设备，实时查看 CPU、温度、风扇、存储卷与硬盘状态；浏览共享目录并上传、下载、重命名、删除文件；启停容器、直达容器 Web 界面、管理镜像；开启自动备份后按增量将指定手机目录同步到 NAS。应用不内置广告与统计 SDK，登录密码不写入持久化存储，可在「我的」中随时退出并清除本地数据。

**English**：A local-first manager for your QNAP NAS. Monitor CPU, temperature, fans, volumes and disks; browse and transfer files; start, stop and inspect containers and images; back up selected phone folders incrementally; and connect remotely through Tailscale. No ads or analytics SDK. Passwords are never persisted, and you can sign out and clear local data at any time.

### 11.2 权限与数据说明（与 `module.json5` 完全一致）

| 权限 | 是否申请 | 用途 | 用户可感知提示 |
| --- | --- | --- | --- |
| `ohos.permission.INTERNET` | 是 | 连接 NAS、读取状态、访问 Tailscale 授权页 | 权限弹窗 + 设置页权限清单 |
| `ohos.permission.GET_NETWORK_INFO` | 是 | 判断网络是否可用、给出连接异常提示 | 权限弹窗 + 设置页权限清单 |
| `ohos.permission.READ_IMAGEVIDEO` | 是 | 仅在开启照片备份时读取所选文件的原始名称 | 权限弹窗 + 隐私政策第三节 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 否 | 代码未使用后台任务，已删除声明 | — |
| 系统文件选择器 | 系统授权 | 上传文件、选择备份目录 | 由系统弹窗授权，不绕过 |
| VPN 连接 | 系统授权 | 仅 Tailscale 方式需要，建立加密隧道 | 系统 VPN 授权弹窗，可随时撤销 |

### 11.3 隐私政策与协议入口

- 文本位置：`entry/src/main/ets/common/legal/LegalDocuments.ets`（中英双语、可离线阅读）。
- 展示组件：`entry/src/main/ets/components/LegalSheet.ets`。
- 入口一：登录页底部「服务条款」「隐私政策」可直接点击打开。
- 入口二：「我的 → 关于」中同样提供两个入口，登录后仍可随时查阅。
- 内容覆盖：信息收集范围、权限用途、本地存储、第三方共享、退出与账号注销、自动备份、儿童隐私、政策更新、联系方式。

### 11.4 账号、退出与注销

应用不注册账号；账号属于用户自己的 NAS。退出登录会清除本机会话、连接地址、账号、备份配置与登录表单，不影响 NAS 上的文件。若需注销 NAS 账号或删除 NAS 数据，请在 QTS 中操作或联系设备管理员；彻底清除本应用留存数据的方式是卸载应用。

### 11.5 截图与文案规范

- 审核截图建议直接使用登录页「审核预览账号 → 进入预览」：主界面顶部常驻「预览模式」提示条，
  所有内容均为内置示例，不涉及真实设备或账号；预览模式下的写操作不会生效。
- 截图中使用文档保留地址 `192.0.2.10` 与中性账号 `demo-user`，密码栏一律留空。
- 本仓库的 `preview/index.html` 仅用于交互预览，不自动填入任何凭据；预览页的示例不得作为商店截图直接提交。
- 错误提示默认展示可操作的友好说明，引擎诊断串折叠在「显示诊断信息」之后；截图请保持默认状态。

### 11.6 仍需人工补充或确认

1. 将第十一节文本中的隐私政策与服务条款发布到开发者公开 URL，并填入应用商店后台；同时确认商店要求的备案与软著材料。
2. 使用 AGC 正式证书与 profile 签名，替换 `tools/signing/` 下的本地自签测试材料。
3. 提供真实设备截图（手机 + 平板、浅色 + 深色），按 11.5 规范脱敏。
4. 在商店后台填写开发者联系方式，替换隐私政策第十节的占位描述。
5. `tools/` 下的诊断脚本默认地址为文档保留地址，密码从环境变量 `NAS_PASSWORD` 读取；仅供本地排查，不随应用包分发。
6. 若使用预览账号截图，建议在商店审核备注中说明：示例数据模式从登录页入口进入，退出登录即可返回真实连接。
