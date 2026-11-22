# 更新日志

本文件记录 QTS NAS（HarmonyOS 原生 NAS 管理器）的版本变更。
更详细的实现说明、接口契约与调试记录见 [README](./README.md)。

版本号规则：`major.minor.patch`，`versionCode = major×1000000 + minor×1000 + patch`。
仓库只提供 **unsigned HAP**，签名证书 / keystore / 口令与 signed 产物一律不入库。

---

## 2.1.9 · 2026-11-22

### 修复：Tailscale 登录卡在「已登录」页面，进不去 App

现象：网页里已登录 Tailscale，但页面一直提示「VPN 连接已断开（扩展无心跳）」，
顶部还写着「登录成功后会自动识别」，界面永远停在这一屏；网页其实停在**通用登录页**，
在官网登录并不会授权本机。

根因有两个，叠在一起才致命：

1. **授权链接被丢弃**（主因）。扩展状态文件里的一次性授权链接
   （`https://login.tailscale.com/a/<key>`）才是唯一能授权本机的地址，
   但它原先在**心跳判定之后**才取。扩展被系统回收时心跳超时、代码直接 `return`，
   于是链接永远拿不到，Web 只能停在通用登录页 —— 用户在官网登录成功，本机始终未授权。
   现在改为**先取链接、再判心跳**：状态文件即使过期，里面的授权链接依然有效。
2. **死局没有出口**。扩展反复被回收时，「登录后自动识别」不可能发生，
   但界面仍这样承诺，按钮也叫「下一步 · 选择 NAS 地址」，
   用户只能干等。现在按真实能力改文案：
   - 顶部状态在拿不到真实授权链接时明确说明「VPN 未连上，无法自动识别」；
   - 主按钮变为 **「跳过 VPN · 直接填 NAS 地址」**，一条明确的出口。

### 其它修正

- `tsAuthNext` 不再清空 `tsAuthUrl`：从「选地址」退回时 Web 会按它重建，
  清空就会退回通用登录页，再次登录也不会授权本机。
- 底部提示文案由「在**下方**页面登录」改为「在**上方**页面登录」，与真实布局一致。
- `tools/sim_ts_flow.py` 同步新逻辑，并新增用例 H：心跳已死但状态文件仍留授权链接时，
  必须继续使用该真实链接。

### 校验

- `validate_project.py` PASS（ZH=EN=649）；`sim_ts_flow.py` 全部通过；release 编译 BUILD SUCCESSFUL。

---

## 2.1.8 · 2026-11-22

### 新增：设备主页的「设备电源」卡片

- 主页新增一张 **设备电源** 卡片，提供 **重启设备** 与 **关闭设备** 两个操作；
  位置在「快捷入口」之后，手机单栏与大屏双栏布局都放在主栏，不改动既有区块顺序。
- 交互一律 **二次确认**：点行先弹确认层，确认后才下发指令，避免误触把 NAS 关掉。
- 指令走 QTS 电源管理：`POST /cgi-bin/sys/sysRequest.cgi?subfunc=power_mgmt&apply=<restart|shutdown>`。
  QTS 电源页的动作名与参数同名（Shut down → `shutdown`，Restart → `restart`）；
  少数固件只认 `reboot`，保留为次选，`restart` 拿到有效回包即不再尝试。
- 结果分三种如实提示：**已发送** / **已发出但设备未回确认** / **失败（多半是账号无管理员权限）**。
  「有 HTTP 响应但包体为空」判为已下发（设备进入关机流程时常来不及回包）；
  连接层失败（`status=0`）无法区分「没送到」与「已关机被踢下线」，同样归为未确认——
  宁可提示未确认，也不能把一次成功的重启说成失败、诱导用户反复重试。

### 代码审核修正

- **遮罩点击穿透**：确认层此前只铺 `scrim`，点空白处的事件会落到下层卡片（例如顶栏「刷新」）。
  改为吞掉空白处点击，弹层期间下层完全不可交互。
- **取消按钮不再被锁**：请求最长会挂到 12 秒超时，此前 `powerBusy` 期间取消键被禁用，用户被关在弹层里。
  改为取消始终可点；关闭弹层不撤销已发出的请求，结果仍以提示告知。
- **重启参数顺序**：由 `reboot` → `restart` 调整为 `restart` → `reboot`，与 QTS 电源页动作名的对应关系一致，
  降低首个参数被拒后误判的概率。

### 设计

- 复用 `surface*` 框体语言：纯白卡片 + 1px `#E6E8EC` 描边 + 同色投影，与相邻卡片完全一致。
- 行式结构：36px 图标圆底 + 标题 + 说明 + 右侧箭头；重启用极淡蓝底，关机用极淡红底，
  分隔线左端与文字对齐（47px），不铺大面积高饱和色。
- 确认层沿用全 app 弹层规格：`cardBg` + 圆角 20 + `surfaceShadow` + `scrim` 遮罩，点空白处不关闭。
- 新增两个同风格描边图标 `ic_power` / `ic_reboot`（24×24，`stroke-width` 1.8）。

### 其它

- 中英文各新增 13 条文案（ZH=EN=646）；`preview/index.html` 同步该卡片以便静态预览。
- 未改动任何既有功能的行为与布局。

---

## 2.1.7 · 2026-11-22

### 修复：共享目录仍只显示 Public / Container

- `privRequest` 改用 `refresh=1`：`refresh=0` 可能命中只含默认共享的设备缓存。
- 候选接口由 5 个扩到 **8 个**：`FileStation6 get_tree(node=/, node=share)`、`get_list(path=/)`、
  `filemanager get_tree`（新旧两版）、`manaRequest get_share_list`、`get_share&read=1`、`privRequest`；
  并行发起、取并集，最坏 6 秒。
- **兜底探测**：8 个接口全部无结果时，用 20 个 QTS 常见共享名（Data / Download / Multimedia / Web /
  Homes / Backup / Photo / Music / Video / Recordings / Qsync / TimeMachine / Virtualization…）
  逐个 `get_list` 校验，存在的直接纳入。只在枚举失败时执行，正常固件不额外耗时。
- **网络熔断**：探测中连续两次请求级失败（`status < 0`）立即停止，候选上限 40，
  避免 NAS 不可达时首屏被拖到几十秒。
- 新增 **「我的 → 网络与连接 → 共享目录诊断」**：一键列出每个候选接口的返回长度、解析到的共享名与前 120
  字符片段。固件字段与预期不一致时，用户直接截图即可定位，不用再盲猜。

### 设计：全 app 的「框」统一为一套规格

- 新增 `surface*` 表面令牌（`surfaceBg / surfaceBorder / surfaceShadowColor / surfaceShadow / floatingShadow`），
  卡片、底部导航栏、顶栏、侧栏、各页弹层、自动备份配置层、共享诊断层**全部指向同一套**：
  纯白 `#FFFFFF` + 1px 冷灰描边 `#E6E8EC` + 投影 `rgba(20,32,58,0.10)`（r16/y5），悬浮底栏仅半径放大到 r22/y8。
- 底栏选中胶囊改用 `primarySoft`，与侧栏选中态同一令牌 —— 同一件事在两处看起来完全一样。
- `CardContainer` 取消「glass / 非 glass」两套外观（此前非 glass 卡片**无投影**、描边色也不同，正是"同一个框不一样"的来源）。
- `ToastBar` 投影、登录页弹层投影一并收敛到 `surfaceShadow`。

### 工程

- `validate_project.py` PASS（ZH=EN=633，新增 4 条诊断文案）；release 编译 BUILD SUCCESSFUL（0 error）。
- 分发包：`dist/QnapNasManager-2.1.7-unsigned.hap`，SHA-256
  `2dd3c9613971daa32177e1d0d71a091b1870c412825ccdee7246ea081e2b01a1`。

---

## 2.1.6 · 2026-11-22

### 修复：文件页共享目录不完整（Data 等自建共享缺失）

- **根因**：`privRequest.cgi?subfunc=share&read=2` 只返回 `defShareList`（默认共享，如 Public）与
  `no_del_list`（系统共享，如 Container）。**用户自建的共享根本不在这个响应里**，2.1.5 只是把同一份名单
  解析得更全，没有换数据源，所以问题依旧。
- 改为**多源合并**：`privRequest` + File Station 目录树（`func=get_tree&node=/`）+
  共享管理（`manaRequest.cgi?subfunc=get_share_list`）等 4 个候选接口，按顺序尝试，取第一个可用结果；
  JSON（`datas / nodes / items / data` 中的 `path / text / name / filename`）与
  XML（`share_name / shareName / share / name`）双解析。
- 枚举出的名字逐个 `get_list` 校验，过滤误解析字段（如把 `<name>` 当成共享名）；
  最终按名称排序，与主机 File Station 的字母序一致。

### 修复：卡片底色偏浅黄 → 纯白

- 根因：浅色模式卡片是 0.8 透明 + 背景模糊，会采样窗口背后的壁纸 / 主题色，暖色壁纸把整块卡片染成浅黄。
- 浅色模式卡片改为**纯白不透明并关闭背景模糊**；底栏 / 顶栏 / 侧栏改近纯白；
  内层区块（输入框、次级按钮、图标底）改**中性浅灰** `#F7F8FA / #F2F3F5`（去掉蓝调）；
  页面渐变改中性灰阶 `#F7F8FA → #EDEFF2`。深色模式保留 `COMPONENT_THICK` 雾玻璃。

### 修复：Tailscale 登录后卡在「下一步·选择 NAS 地址」

- 根因：`tsAuthNext()` 在 `tsAuthed === false` 时直接 return，只改一行小字。真机上 VPN 扩展常被系统回收，
  心跳超时导致 `tsAuthed` 永远为 false —— 用户明明已在网页完成授权，按钮却永远点不动，流程死锁。
- 现在主按钮**无条件放行**到「选 NAS 地址」；未连上 VPN 时该页顶部明确提示改填局域网 IP。
- 引擎变为 running（授权成功）后 **900ms 自动进入选地址**，省掉一次点击。
- 进入选地址后**继续轮询**：VPN 稍后连上，候选节点自动补进列表，无需退回上一步。
- 去掉与之重复的「VPN 连不上？直接用 IP 登录」次要按钮，改为一行说明；
  「授权链接未取到」由红色警告改为次级文字色，避免把可继续的流程渲染成故障。

### 工程

- 仿真用例同步新流程（failed → 下一步放行、pick 阶段轮询补候选），全部通过。
- `validate_project.py` PASS（ZH=EN=629，新增 `login.ts.nextIp.hint`）；release 编译 BUILD SUCCESSFUL。
- 分发包：`dist/QnapNasManager-2.1.6-unsigned.hap`，SHA-256
  `0ac13c9127234a769b42f10a048bba671a50ab41128844f5e0541ef85adcc12b`。

---

## 2.1.5 · 2026-11-22

### 修复：共享目录只看得到 Public / Container

- `QnapApi.shares()` 重写解析逻辑，同时覆盖四种真实返回形态：
  - `defShareList`（默认共享清单）
  - `no_del_info → share_name`（系统共享）
  - `share_info / share → share_name`（普通共享，**旧实现完全漏解析**）
  - 平铺的 `share_name / shareName`
- `defShareList` 的分隔符兼容 `/`、`;`、`|` 三种固件差异（旧实现只按 `/` 拆分，
  非该分隔符时多个共享会被并成一个非法名字而整体丢弃）。
- 清单里**明确存在**的共享不再逐个 `get_list` 探测：旧逻辑既慢，又会把只读共享误判为不存在，
  这是「Data 看不到」的直接根因。
- 文件页下拉刷新、设置页打开 NAS 目录选择器时都会 `resetShareCache()` 重新取名单，
  NAS 上新建立共享无需重启 App。

### 修复：自动备份「开关不明显、点击无反应」

- 开关由「文字按钮」改为 46×26 的 `Toggle` 控件：开为主色、关为浅灰轨道，状态一眼可见。
  原按钮是**白字 `#FFFFFF` 配浅蓝底 `#EDF2F8`**，对比度接近 1:1，等于隐形。
- 配置未完成时拨动开关不再静默失败：直接把用户带到文件夹配置层并说明原因，开关自动弹回，
  避免「看着是开的、其实没生效」。
- 「立即备份」在未配置 / 未开启时分别给出可操作提示（旧实现在未开启时静默返回，什么都没发生）。
- 自动备份文件夹整行可点，补按压反馈与「配置文件夹」强调胶囊。
- 配置层里的「选择手机 / NAS 文件夹」由白字无底改为浅蓝底 + 蓝字 + 描边，浅深色下均 ≥4.5:1；
  配置层高度随断点自适应（平板 560vp / 手机 500vp）。

### 设计：鸿蒙 7 雾玻璃与配色重塑

- 卡片、悬浮底栏、侧栏 / 顶栏、各页对话框、配置层统一为
  `BlurStyle.COMPONENT_THICK` + 半透明底（明 `#FFFFFFCC` / 暗 `#191D24CC`）+ 1px 冷灰描边 + 大半径浅投影。
- 弹层遮罩统一走 `Theme.scrim()`，不再散落写死 `#66000000`。
- 主色 `#3D74C4 → #2E6AD6`（白底对比度 5.0:1）；新增令牌：
  `buttonSoftBg / buttonSoftFg / buttonSoftBorder`（浅底按钮三件套）、`pressBg`、`scrim`、
  `cardShadow`、`glassBlur()`、`heroGradientColors`。
- 页面渐变底改为三段式冷调渐变；首页健康横幅图标底跟随状态语义色，快捷入口改用主色系。
- `color.json`、`EntryAbility` 窗口底色、`preview/index.html` CSS 变量与本机令牌逐一同步。

### 工程

- 新增 3 条中英文案（`gallery.auto.folder.config / switch / enableFirst`），ZH=EN=628。
- `validate_project.py` PASS；release 编译 BUILD SUCCESSFUL（0 error）。
- 分发包：`dist/QnapNasManager-2.1.5-unsigned.hap`，SHA-256
  `0e6aceb53c6687b2d80227925ec8443d2023235e0d88627a250465797400854d`。

---

## 2.1.4 · 2026-11-22

- 登录页新增「审核预览账号 → 进入预览」：无需设备、账号或网络即可看到完整虚拟界面，便于商店审核。
- `common/demo/DemoMode.ets` 提供设备概览、事件、共享与文件、存储池 / 卷 / 硬盘、服务、
  容器 / 端口 / 镜像 / 日志等示例数据；`NasRepository` 仅在预览标记开启时返回这些数据，真实 API 一行未改。
- 预览模式下所有写操作返回占位成功但不发请求；自动备份不启动；容器端口不打开外部网页。
- 主界面常驻「预览模式」提示条并提供「退出预览」，退出登录会同时清除预览标记。
- 分发包：`dist/QnapNasManager-2.1.4-unsigned.hap`，SHA-256
  `ee6c182ad2852f76774a66fc4bb5c6bee79bdb25d288d030746b572d61f689f8`。

## 2.1.3 · 2026-11-22

- 上架合规审查：敏感信息清零（示例账号 / 明文密码 / 设备地址）、权限最小化
  （删除未使用的 `KEEP_BACKGROUND_RUNNING`）、媒体读取用途说明收紧。
- 新增中英双语隐私政策与服务条款全文，登录页与「我的 → 关于」均可离线打开。
- Tailscale 引擎诊断串默认折叠；纯图标操作补 `accessibilityText`。
- 分发包：`dist/QnapNasManager-2.1.3-signed.hap`（历史本地自签产物，不入库）。

## 2.1.2 · 2026-11-21

- 页面能力完善：文件页搜索 / 多选 / 新建 / 重命名 / 删除 / 属性，容器页端口与镜像管理，
  设置页存储概览（卷 / 硬盘 / 系统服务）并入。

## 2.1.1 · 2026-11-20

- 版本基线重整为 2.1.x；补齐应用商店发布核对表与截图规范。

## 1.2.19 · 2026-11-18

- 新增自动备份：手机目录 → NAS 目录增量备份，支持目录授权持久化与去重索引。

## 1.2.18 · 2026-11-16

- 交付优化：悬浮雾玻璃底栏、左右滑动切页、平板 / 2in1 三段式外壳。

## 1.2.15 · 2026-11-10

- Tailscale 内网地址登录链路打通（`VpnExtensionAbility` + NAPI 真实 TUN）。

## 1.2.12 · 2026-11-02

- 首个可用版本：QTS 登录、设备概览、文件浏览、容器列表。

---

## 安全说明

- 仓库中不含任何真实设备地址、账号、密码、令牌或签名材料。
- 需要口令的工具（如本地签名脚本）一律从环境变量读取，不写入仓库。
- 所有示例数据（预览页、`DemoMode`、文档）均为文档保留地址与中性占位值。
