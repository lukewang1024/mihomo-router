// Exercise the actual inline dashboard script with a small DOM and API fixture.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, '../share/ui/index.html'), 'utf8');
class Element {
  constructor() { this.children = []; this.handlers = {}; this.hidden = true; this.disabled = false; }
  set textContent(value) { this.text = value; this.children = []; }
  get textContent() { return this.text; }
  append(...items) { this.children.push(...items); }
  replaceChildren(...items) { this.children = items; }
  addEventListener(event, fn) { this.handlers[event] = fn; }
  querySelectorAll() { return this.children.flatMap(item => item.children.filter(child => child.type === 'button')); }
}
const elements = Object.fromEntries([...html.matchAll(/id="([^"]+)"/g)].map(match => [match[1], new Element()]));
const stored = new Map();
const requests = [];
let selected = 'phone-main';
let authorized = true;
const context = {
  document: { getElementById: id => elements[id], createElement: () => new Element() },
  location: { hash: '#secret=test-access', pathname: '/ui/', search: '' },
  history: { replaceState: (...args) => requests.push(['history', args]) },
  localStorage: { getItem: key => stored.get(key), setItem: (key, value) => stored.set(key, value), removeItem: key => stored.delete(key) },
  URLSearchParams,
  fetch: async (url, options) => {
    requests.push([url, options]);
    if (!authorized) return { ok: false, status: 401 };
    assert.equal(options.headers.Authorization, 'Bearer test-access');
    if (options.method === 'PUT') {
      selected = JSON.parse(options.body).name;
      return { ok: true, status: 204 };
    }
    const data = url === '/rules'
      ? { rules: [{ proxy: 'SSH-Gateway', payload: '10.42.0.0/16' }, { proxy: 'DIRECT', payload: 'other' }] }
      : { now: selected, all: ['phone-main', 'laptop-b'] };
    return { ok: true, status: 200, json: async () => data };
  },
};
async function settle() { await new Promise(resolve => setImmediate(resolve)); }
(async () => {
  vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], context);
  await settle();
  assert.equal(elements.gateway.hidden, false);
  assert.equal(elements.devices.children.length, 2);
  assert.equal(elements.routes.children.length, 1);
  assert.equal(elements.routes.children[0].textContent, '10.42.0.0/16');
  assert.equal(stored.get('mihomo-router-access'), 'test-access');
  assert.equal(requests[0][0], 'history'); // Remove the access secret from the URL.
  await elements.devices.children[1].children[3].handlers.click();
  assert.equal(selected, 'laptop-b');
  assert.match(elements.notice.textContent, /laptop-b/);
  authorized = false;
  await elements.refresh.handlers.click();
  assert.equal(elements.gateway.hidden, true);
  assert.equal(elements.connection.open, true);
  assert.match(elements.notice.textContent, /口令/);
  elements.forget.handlers.click();
  assert.equal(stored.size, 0);
  assert.equal(elements.secret.value, '');
  console.log('PASS: dashboard authentication, route display, switching and error handling');
})().catch(error => { console.error(error); process.exitCode = 1; });
