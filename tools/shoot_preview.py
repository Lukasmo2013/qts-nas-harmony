#!/usr/bin/env python3
import os
# -*- coding: utf-8 -*-
"""预览页可视化验证：用本机 Chrome 无头打开 preview/index.html，登录真实设备后截图。

用法: python tools/shoot_preview.py
产物: preview/_shot_*.png
"""
import http.server
import os
import pathlib
import socketserver
import threading
import time

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
PREVIEW = ROOT / 'preview'
OUT = PREVIEW / '_shots'
PORT = 8765
PROXY = 'http://127.0.0.1:7890'

CHROME_CANDIDATES = [
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
]


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(PREVIEW), **kw)

    def log_message(self, *a):
        pass


def serve():
    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.TCPServer(('127.0.0.1', PORT), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def chrome_path():
    for c in CHROME_CANDIDATES:
        if os.path.exists(c):
            return c
    return None


def main():
    OUT.mkdir(exist_ok=True)
    httpd = serve()
    exe = chrome_path()
    if exe is None:
        print('未找到本机 Chrome / Edge')
        return

    with sync_playwright() as pw:
        browser = pw.chromium.launch(executable_path=exe, headless=True,
                                     args=['--disable-gpu', '--hide-scrollbars'])
        page = browser.new_page(viewport={'width': 1440, 'height': 900},
                                device_scale_factor=2)
        page.goto(f'http://127.0.0.1:{PORT}/index.html')
        page.wait_for_timeout(400)

        # 直接调用页面内的真实登录流程（走本地代理 → 真实 NAS）
        page.evaluate("""async (proxy) => {
            const res = await fetch(proxy + '/api/login', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ host: '192.0.2.10', port: 5000,
                                       user: 'demo-user', password: os.environ.get('NAS_PASSWORD', '') })
            });
            const r = await res.json();
            if (r && r.success) {
                S.session = r.session; S.loggedIn = true; S.dataReady = false;
                document.getElementById('loginMask').style.display = 'none';
                enterApp();
            } else { throw new Error('login failed: ' + JSON.stringify(r)); }
        }""", PROXY)
        page.wait_for_timeout(6000)

        for tab, name in [(0, 'home'), (1, 'files'), (2, 'docker'), (3, 'profile')]:
            page.evaluate("(t) => goto(t)", tab)
            page.wait_for_timeout(700)
            out = OUT / f'shot_{name}.png'
            page.screenshot(path=str(out))
            print('saved', out)

        # 文件页切换到第二个共享目录
        page.evaluate("(t) => goto(t)", 1)
        page.wait_for_timeout(500)
        locs = page.query_selector_all('.loc')
        if len(locs) > 1:
            locs[1].click()
            page.wait_for_timeout(2500)
            out = OUT / 'shot_files_share2.png'
            page.screenshot(path=str(out))
            print('saved', out)

        # 进入子目录：验证「返回上一层」按钮确实出现并可点
        entered = page.evaluate("""() => {
            const rows = Array.from(document.querySelectorAll('.row'));
            const dir = rows.find(r => r.getAttribute('onclick') && r.textContent.indexOf('Recycle') < 0);
            if (!dir) return false;
            dir.click();
            return true;
        }""")
        print('entered subfolder:', entered)
        page.wait_for_timeout(2400)
        out = OUT / 'shot_files_deep.png'
        page.screenshot(path=str(out))
        print('saved', out)
        back = page.evaluate("""() => {
            const b = document.querySelector('.up-back');
            if (!b) return 'missing';
            const label = b.textContent.trim();
            b.click();
            return label;
        }""")
        print('up-back label:', back)
        page.wait_for_timeout(2400)
        out = OUT / 'shot_files_back.png'
        page.screenshot(path=str(out))
        print('saved', out)

        # 设备主页滚动：验证快捷入口与容量卡
        page.evaluate("(t) => goto(t)", 0)
        page.wait_for_timeout(600)
        page.evaluate("() => { const ps = document.getElementById('track').children;"
                      " if (ps && ps[0]) ps[0].scrollTop = ps[0].scrollHeight; }")
        page.wait_for_timeout(500)
        out = OUT / 'shot_home_bottom.png'
        page.screenshot(path=str(out))
        print('saved', out)

# 「我的」页面滚动到底：验证存储区块
        page.evaluate("(t) => goto(t)", 3)
        page.wait_for_timeout(600)
        page.evaluate("() => { const ps = document.getElementById('track').children;"
                      " if (ps && ps[3]) ps[3].scrollTop = ps[3].scrollHeight; }")
        page.wait_for_timeout(500)
        out = OUT / 'shot_profile_storage.png'
        page.screenshot(path=str(out))
        print('saved', out)

        # 深色模式
        page.evaluate("() => { S.theme = 'dark'; applyTheme(); renderTrack(); }")
        page.wait_for_timeout(600)
        page.evaluate("(t) => goto(t)", 3)
        page.wait_for_timeout(600)
        out = OUT / 'shot_profile_dark.png'
        page.screenshot(path=str(out))
        print('saved', out)

        # ---- 手机端：悬浮圆角底栏（雾玻璃）----
        page.evaluate("() => { S.theme = 'light'; applyTheme(); S.device = 'phone'; applyDevice(); }")
        page.wait_for_timeout(400)
        for tab, name in [(0, 'phone_home'), (1, 'phone_files')]:
            page.evaluate("(t) => goto(t)", tab)
            page.wait_for_timeout(900)
            out = OUT / f'shot_{name}.png'
            page.screenshot(path=str(out))
            print('saved', out)

        # ---- 手机端底栏特写：验证圆角长条 + 选中胶囊 ----
        page.evaluate("(t) => goto(t)", 2)
        page.wait_for_timeout(800)
        bar = page.query_selector('#bottomTabs')
        if bar:
            bar.screenshot(path=str(OUT / 'shot_tabbar.png'))
            print('saved', OUT / 'shot_tabbar.png')

        # ---- 登录页：本地 IP / QNAP ID 双模式 ----
        page.evaluate("() => { logout(); setLoginMode('ip'); }")
        page.wait_for_timeout(400)
        page.screenshot(path=str(OUT / 'shot_login_ip.png'))
        print('saved', OUT / 'shot_login_ip.png')

        page.evaluate("() => { setLoginMode('id'); }")
        page.wait_for_timeout(400)
        page.screenshot(path=str(OUT / 'shot_login_id.png'))
        print('saved', OUT / 'shot_login_id.png')

        browser.close()
    httpd.shutdown()


if __name__ == '__main__':
    main()
