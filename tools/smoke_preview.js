/**
 * Headless smoke test for preview/index.html (no browser required).
 * Stubs a minimal DOM, evaluates the preview script synchronously, then drives
 * the real action handlers through the main user journeys.
 *
 * Run: node tools/smoke_preview.js
 */
const fs = require('fs');
const path = require('path');

const htmlPath = path.join(__dirname, '..', 'preview', 'index.html');
const html = fs.readFileSync(htmlPath, 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function fakeElement() {
  return {
    innerHTML: '', dataset: {}, id: '',
    focus() {}, setSelectionRange() {}, selectionStart: 0,
    addEventListener() {}, removeEventListener() {},
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    querySelectorAll() { return []; }, setAttribute() {}, getAttribute() { return null; }
  };
}
const nodes = {};
global.document = {
  activeElement: null,
  getElementById(id) {
    if (!nodes[id]) nodes[id] = fakeElement();
    return nodes[id];
  },
  addEventListener() {}
};
// Run timers synchronously so asynchronous login / toast paths are deterministic.
global.setTimeout = (fn) => { fn(); return 0; };
global.clearTimeout = () => {};

let renders = 0;
const assertions = [];
function check(name, cond) {
  assertions.push([name, !!cond]);
  if (!cond) throw new Error('FAILED: ' + name);
}

const driver = `
;(function () {
  const realRender = render;
  render = function () { globalThis.__renders++; return realRender.apply(this, arguments); };
  globalThis.__api = { get S() { return S; }, act, render, t, currentFiles };
})();
`;
global.__renders = 0;

// eslint-disable-next-line no-new-func
new Function(script + driver)();
const api = global.__api;
const S = api.S;

// 1. initial login page renders in both languages and both device forms
for (const lang of ['zh', 'en']) {
  for (const device of ['phone', 'tablet']) {
    S.lang = lang; S.device = device; S.loggedIn = false; S.scenario = 'success';
    api.render(); renders++;
  }
}
check('login page renders for zh/en x phone/tablet', renders === 4);

// 2. QNAP ID form validation blocks empty submit
S.lang = 'zh'; S.device = 'phone';
S.form.mode = 'qid'; S.form.account = ''; S.form.password = '';
api.act('login-submit', '');
check('empty QNAP ID shows account error', S.form.accountErr === 'login.err.account');
check('empty QNAP ID shows password error', S.form.passwordErr === 'login.err.password');
check('validation keeps user on login page', S.loggedIn === false);

// 3. wrong QNAP ID credentials -> explicit failure + switch to local IP
S.form.account = 'someone@example.com'; S.form.password = 'wrong-password';
api.act('login-submit', '');
check('wrong QNAP ID produces explicit failure', S.form.failure === true);
check('wrong QNAP ID does not sign in', S.loggedIn === false);
api.act('login-switch-ip', '');
check('failure lets user switch to local IP', S.form.mode === 'ip');
check('local IP is prefilled for convenience', S.form.ip === '192.0.2.10');

// 4. invalid IP is rejected
S.form.ip = '999.1.1.1';
api.act('login-submit', '');
check('invalid IPv4 is rejected', S.form.ipErr === 'login.err.ip' && S.loggedIn === false);

// 5. valid local IP -> device home
S.form.ip = '192.0.2.10'; S.form.port = '443'; S.form.username = 'admin';
api.act('login-submit', '');
check('valid local IP signs in', S.loggedIn === true);
check('local IP lands on device home', S.tab === 'home');
check('session records host and port', S.session.host === '192.0.2.10' && S.session.port === 443);

// 6. every module renders in both languages / device forms / theme modes
for (const lang of ['zh', 'en']) {
  for (const device of ['phone', 'tablet']) {
    for (const theme of ['light', 'dark']) {
      S.lang = lang; S.device = device; S.theme = theme; S.scenario = 'success';
      for (const tab of ['home', 'files', 'storage', 'docker', 'settings']) {
        S.tab = tab; api.render(); renders++;
      }
    }
  }
}
check('all modules render across language/device/theme matrix', renders === 4 + 40);

// 7. all five abnormal states render without errors
for (const sc of ['loading', 'empty', 'error', 'noNetwork', 'noPermission']) {
  S.scenario = sc;
  for (const tab of ['home', 'files', 'storage', 'docker']) {
    S.tab = tab; api.render(); renders++;
  }
}
check('five UI states render across feature pages', renders === 4 + 40 + 20);
S.scenario = 'success';

// 8. file module: navigate, create folder, properties, delete
S.tab = 'files';
api.act('files-path', '/Multimedia');
check('file navigation changes path', S.files.path === '/Multimedia');
api.act('files-new', '');
S.dialog.value = '新建资料夹';
api.act('dlg-confirm', '');
check('new folder is created', api.currentFiles().some(f => f.name === '新建资料夹'));
api.act('files-sort', '');
check('sort cycles to size', S.files.sort === 'size');
api.act('files-view', '');
check('view toggles to grid', S.files.view === 'grid');
api.act('files-select', '');
check('multi-select selects all items', S.files.sel.length > 0);
api.act('files-bulk', 'delete');
check('bulk delete opens confirmation', S.dialog && S.dialog.type === 'files-delete');
api.act('dlg-confirm', '');
check('bulk delete empties selection', S.files.selectMode === false && S.files.sel.length === 0);

// 9. storage service toggling
S.tab = 'storage'; S.storage.tab = 3;
const before = S.storage.services.find(x => x.id === 's3').on;
api.act('service-toggle', 's3');
check('service start/stop toggles state', S.storage.services.find(x => x.id === 's3').on === !before);

// 10. docker create / toggle / logs / remove
S.tab = 'docker'; S.docker.tab = 0;
const c0 = S.docker.containers.length;
api.act('ct-create', 'nginx:latest');
S.dialog.name = 'my-nginx'; S.dialog.port = '8080:80';
api.act('dlg-confirm', '');
check('container is created', S.docker.containers.length === c0 + 1);
const fresh = S.docker.containers[0];
api.act('ct-toggle', fresh.id);
check('container can be stopped', fresh.status === 'stopped');
api.act('ct-logs', fresh.id);
check('container logs dialog opens', S.dialog && S.dialog.type === 'ct-logs');
api.act('dlg-close', '');
api.act('ct-remove', fresh.id);
check('remove confirmation opens', S.dialog && S.dialog.type === 'ct-remove');
api.act('dlg-confirm', '');
check('container is removed', S.docker.containers.length === c0);

// 11. settings: language, theme, scenario, logout
S.tab = 'settings';
api.act('set-dialog', 'language');
api.act('set-lang', 'en');
check('in-app language switch works', S.lang === 'en' && S.dialog === null);
api.act('set-dialog', 'theme');
api.act('set-theme', 'dark');
check('in-app theme switch works', S.theme === 'dark');
api.act('set-perm', '');
check('permission list expands', S.permOpen === true);
api.act('scenario', 'noNetwork');
check('state preview is set', S.scenario === 'noNetwork');
api.act('set-dialog', 'logout');
api.act('logout-confirm', '');
check('logout clears session', S.loggedIn === false && S.session === null);

console.log('render calls        : ' + global.__renders);
console.log('assertions passed   : ' + assertions.length);
console.log('RESULT: PASS - all user journeys executed without errors');
