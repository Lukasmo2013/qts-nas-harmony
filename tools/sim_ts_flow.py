"""Tailscale 五步向导状态机仿真。

对应 entry/src/main/ets/feature/login/LoginPage.ets 的
tailscaleLogin() / tsTick() / tsAuthNext() 逻辑，逐行镜像成 Python，
用来验证一个核心不变量：

    只要 VPN 授权成功（TailscaleService.start 不抛异常），
    用户就一定先看到 Tailscale 登录页（tsPhase == 'auth'），
    且引擎的任何状态（starting / needs_login / running / failed / stopped）
    都不会把用户从登录页里踢走。

用法：python tools/sim_ts_flow.py
"""

TS_LOGIN_URL = 'https://login.tailscale.com/'
DEAD_MSG = 'VPN 连接已断开（扩展无心跳），正在自动重连…'

INIT = '\u672a\u5f00\u59cb'
CONNECTING = 'connecting'
AUTH = 'auth'
PICK = 'pick'
LOGIN = 'login'
LOGGING = 'logging'


class Page:
    def __init__(self):
        self.tsPhase = INIT
        self.tsStage = ''
        self.tsAuthUrl = ''
        self.tsAuthUrlReal = False
        self.tsAuthed = False
        self.tsEngineErr = ''
        self.tsCandidates = []
        self.tsPeers = []
        self.tsPickedIp = ''
        self.showFailure = False
        self.failureTextKey = ''
        self.timer = None
        self.ctx = object()
        self.tsRestart = False

    # ---------- tailscaleLogin() ----------
    def tailscale_login(self, start_ok=True):
        self.tsPhase = CONNECTING
        self.tsStage = 'login.ts.starting'
        self.tsAuthUrl = ''
        self.tsAuthUrlReal = False
        self.tsAuthed = False
        self.tsCandidates = []
        self.tsPeers = []
        self.showFailure = False

        if not start_ok:                       # TailscaleService.start 抛异常
            self.reset_ts_flow()
            self.failureTextKey = 'login.ts.vpnFailed'
            self.showFailure = True
            return

        # 登录页必经：VPN 一起就立刻给登录页
        self.tsPhase = AUTH
        self.tsAuthUrl = TS_LOGIN_URL
        self.tsAuthUrlReal = False
        self.tsStage = 'login.ts.auth'
        self.timer = 'running'

    # ---------- tsTick() ----------
    def tick(self, st):
        if self.tsPhase != AUTH:
            return
        # 存活检测：状态文件超过 8 秒没心跳 = 扩展已被回收，内容只是旧快照
        age = st.get('age', 0)
        if age > 8000:
            self.tsAuthed = False
            self.tsEngineErr = DEAD_MSG
            self.tsStage = 'login.ts.auth.wait'
            self.tsRestart = True
            return
        state = st.get('state', 'starting')
        if state in ('failed', 'timeout', 'stopped'):
            self.timer = None
            self.tsEngineErr = st.get('detail', '')
            self.tsAuthed = False
            self.tsStage = 'login.ts.auth.wait'
            return
        if st.get('candidates') or st.get('peers'):
            self.tsCandidates = st.get('candidates', [])
            self.tsPeers = st.get('peers', [])
        self.tsEngineErr = ''
        if state == 'running':
            self.tsAuthed = True
            if st.get('authUrl') and not self.tsAuthUrlReal:
                self.tsAuthUrl = st['authUrl']
                self.tsAuthUrlReal = True
            self.tsStage = 'login.ts.auth.ok'
            return
        if state == 'needs_login':
            if st.get('authUrl') and not self.tsAuthUrlReal:
                self.tsAuthUrl = st['authUrl']
                self.tsAuthUrlReal = True
            self.tsAuthed = False
            self.tsStage = 'login.ts.auth'
            return
        self.tsAuthed = False
        self.tsStage = 'login.ts.auth'

    # ---------- tsAuthNext() ----------
    def auth_next(self):
        if not self.tsAuthed:
            self.tsStage = 'login.ts.auth.wait'
            return False
        self.timer = None
        self.tsAuthUrl = ''
        self.tsStage = ''
        self.tsPickedIp = self.tsCandidates[0]['address'] if len(self.tsCandidates) == 1 else ''
        self.tsPhase = PICK
        return True

    # ---------- tsSkipEngine() ----------
    def skip_engine(self):
        self.timer = None
        self.tsEngineErr = ''
        self.tsStage = ''
        self.tsPickedIp = ''
        self.tsPhase = PICK

    def reset_ts_flow(self):
        self.timer = None
        self.tsPhase = INIT
        self.tsStage = ''
        self.tsAuthUrl = ''
        self.tsAuthUrlReal = False
        self.tsAuthed = False
        self.tsEngineErr = ''
        self.tsCandidates = []
        self.tsPeers = []
        self.tsPickedIp = ''


def step1_after_start(p):
    """判断登录页是否已经展示（不看任何引擎状态）。"""
    return p.tsPhase == AUTH and p.tsAuthUrl.startswith('https://login.tailscale.com')


def run():
    ok = True
    cases = [
        ('A 首次未登录（needs_login 带真实 authUrl）',
         {'state': 'needs_login', 'authUrl': 'https://login.tailscale.com/a/abc123'},
         'auth', 'https://login.tailscale.com/a/abc123', False, ''),
        ('B 之前登录过（一启动就 running）',
         {'state': 'running', 'authUrl': '', 'candidates': [{'name': 'myserver', 'address': '100.64.0.5'}]},
         'auth', TS_LOGIN_URL, True, ''),
        ('C 引擎启动失败（failed）',
         {'state': 'failed', 'detail': 'backend start exception: xxx'},
         'auth', TS_LOGIN_URL, False, 'backend start exception: xxx'),
        ('D 引擎被停止（stopped）',
         {'state': 'stopped', 'detail': 'extension stopped'},
         'auth', TS_LOGIN_URL, False, 'extension stopped'),
        ('E 状态文件还没写出（starting）',
         {'state': 'starting'},
         'auth', TS_LOGIN_URL, False, ''),
        ('F running 且带 authUrl',
         {'state': 'running', 'authUrl': 'https://login.tailscale.com/a/zzz'},
         'auth', 'https://login.tailscale.com/a/zzz', True, ''),
        ('G 扩展已死（心跳 12 秒前，真机 VPN 图标消失）',
         {'state': 'needs_login', 'age': 12000},
         'auth', TS_LOGIN_URL, False, DEAD_MSG),
    ]

    print('=' * 78)
    print('第一阶段：VPN 授权成功后，是否立刻进入 Tailscale 登录页')
    print('=' * 78)
    for name, st, _, _, _, _ in cases:
        p = Page()
        p.tailscale_login(start_ok=True)
        landed = step1_after_start(p)
        ok = ok and landed
        print(f'  [{"OK" if landed else "FAIL"}] {name:<40s} -> tsPhase={p.tsPhase!r} url={p.tsAuthUrl}')

    print()
    print('=' * 78)
    print('第二阶段：轮询到任意引擎状态后，登录页是否仍然在（不被踢走）')
    print('=' * 78)
    for name, st, want_phase, want_url, want_authed, want_err in cases:
        p = Page()
        p.tailscale_login(start_ok=True)
        p.tick(st)
        good = (p.tsPhase == want_phase and p.tsAuthUrl == want_url
                and p.tsAuthed == want_authed and p.tsEngineErr == want_err
                and p.showFailure is False)
        ok = ok and good
        print(f'  [{"OK" if good else "FAIL"}] {name}')
        print(f'        phase={p.tsPhase!r} authed={p.tsAuthed} showFailure={p.showFailure}')
        print(f'        url={p.tsAuthUrl}')
        print(f'        engineErr={p.tsEngineErr!r}')

    print()
    print('=' * 78)
    print('第三阶段：后续步骤能否走通')
    print('=' * 78)
    # B: running -> 下一步 -> pick
    p = Page()
    p.tailscale_login(True)
    p.tick({'state': 'running', 'authUrl': '',
            'candidates': [{'name': 'myserver', 'address': '100.64.0.5'}]})
    advanced = p.auth_next()
    good = advanced and p.tsPhase == PICK and p.tsPickedIp == '100.64.0.5'
    ok = ok and good
    print(f'  [{"OK" if good else "FAIL"}] running -> 点「下一步」 -> pick，预填 {p.tsPickedIp}')

    # C: failed -> 下一步被拦截（不能穿过未连接的 VPN 去登录）
    p = Page()
    p.tailscale_login(True)
    p.tick({'state': 'failed', 'detail': 'boom'})
    advanced = p.auth_next()
    good = (advanced is False) and p.tsPhase == AUTH and p.tsStage == 'login.ts.auth.wait'
    ok = ok and good
    print(f'  [{"OK" if good else "FAIL"}] failed -> 点「下一步」被拦截，仍在登录页（stage={p.tsStage}）')

    # C: failed -> 跳过 VPN -> pick（兜底出口不死锁）
    p = Page()
    p.tailscale_login(True)
    p.tick({'state': 'failed', 'detail': 'boom'})
    p.skip_engine()
    good = p.tsPhase == PICK
    ok = ok and good
    print(f'  [{"OK" if good else "FAIL"}] failed -> 点「跳过 VPN」-> pick（局域网友好出口）')

    # VPN 授权被拒：不进登录页，直接失败（合理）
    p = Page()
    p.tailscale_login(start_ok=False)
    good = p.showFailure and p.tsPhase == INIT
    ok = ok and good
    print(f'  [{"OK" if good else "FAIL"}] VPN 授权被拒 -> 失败面板，不假装能登录')

    print()
    print('=' * 78)
    print('全部通过' if ok else '存在 FAIL，需要修复')
    print('=' * 78)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(run())
