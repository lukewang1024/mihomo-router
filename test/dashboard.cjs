// Exercise the inline dashboard with a small DOM and authenticated API fixture.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, '../share/ui/index.html'), 'utf8');
class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.handlers = {}; this.hidden = true; this.disabled = false; }
  set textContent(value) { this.text = value; this.children = []; }
  get textContent() { return this.text; }
  append(...items) { this.children.push(...items); }
  replaceChildren(...items) { this.children = items; }
  addEventListener(event, fn) { this.handlers[event] = fn; }
  setAttribute(name, value) { this[name] = value; }
  querySelectorAll(selector) {
    const tags = selector.split(',').map(tag => tag.trim());
    return this.children.flatMap(child => [...(tags.includes(child.tag) ? [child] : []), ...child.querySelectorAll(selector)]);
  }
}
const elements = Object.fromEntries([...html.matchAll(/id="([^"]+)"/g)].map(match => [match[1], new Element()]));
const stored = new Map();
const requests = [];
const manual = '订阅 / 手动';
const unsafe = '<img src=x onerror=alert(1)>';
let selected = 'phone-main';
let subscription = '自动';
let authorized = true;
let putFailure = false;
let gatewayEnabled = true;
let failoverEnabled = false;
let effective = 'DIRECT';
let mode = 'rule';
function proxies() {
  return {
    GLOBAL: { type: 'Selector', now: manual, all: ['DIRECT', manual] },
    ...(gatewayEnabled ? { 'SSH-Gateway': { type: 'Selector', now: selected, all: ['phone-main', 'laptop-b'] } } : {}),
    ...(gatewayEnabled && failoverEnabled ? { 'SSH-Gateway-Route': { type: 'Selector', now: effective, all: ['DIRECT', 'SSH-Gateway'], hidden: true } } : {}),
    [manual]: { type: 'Selector', now: subscription, all: ['自动', 'node-a', unsafe] },
    '自动': { type: 'URLTest', now: 'node-a', all: ['node-a'] },
    '均衡': { type: 'LoadBalance', all: ['node-a'] },
    'node-a': { type: 'Trojan', history: [{ delay: 123 }] },
    [unsafe]: { type: 'Trojan', history: [{ delay: 0 }] },
  };
}
const context = {
  document: { getElementById: id => elements[id], createElement: tag => new Element(tag) },
  location: { hash: '#secret=test-access', pathname: '/ui/', search: '' },
  history: { replaceState: (...args) => requests.push(['history', args]) },
  localStorage: { getItem: key => stored.get(key), setItem: (key, value) => stored.set(key, value), removeItem: key => stored.delete(key) },
  URLSearchParams,
  fetch: async (url, options) => {
    requests.push([url, options]);
    if (!authorized) return { ok: false, status: 401 };
    assert.equal(options.headers.Authorization, 'Bearer test-access');
    if (options.method === 'PUT') {
      if (putFailure) return { ok: false, status: 500 };
      const name = decodeURIComponent(url.slice('/proxies/'.length));
      const target = JSON.parse(options.body).name;
      if (name === 'SSH-Gateway') selected = target;
      else if (name === 'SSH-Gateway-Route') effective = target;
      else { assert.equal(name, manual); subscription = target; }
      return { ok: true, status: 204 };
    }
    const data = {
      '/rules': { rules: [{ proxy: failoverEnabled ? 'SSH-Gateway-Route' : 'SSH-Gateway', payload: '10.42.0.0/16' }, { proxy: manual, type: 'Match' }] },
      '/proxies': { proxies: proxies() },
      '/configs': { mode },
      '/connections': { connections: [{ metadata: { host: 'example.com', sourceIP: '192.168.31.2', destinationPort: '443' }, rule: 'Match', chains: ['node-a', manual] }] },
    }[url];
    assert.ok(data, 'unexpected API request: ' + url);
    return { ok: true, status: 200, json: async () => data };
  },
};
async function settle() { await new Promise(resolve => setImmediate(resolve)); }
function card(title) {
  return elements['subscription-groups'].children.find(item => item.children[0].textContent === title);
}
(async () => {
  vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], context);
  await settle();
  assert.equal(elements.gateway.hidden, false);
  assert.equal(elements.devices.children.length, 2);
  assert.equal(elements.routes.children.length, 1);
  assert.equal(elements.routes.children[0].textContent, '10.42.0.0/16');
  assert.equal(stored.get('mihomo-router-access'), 'test-access');
  assert.equal(requests[0][0], 'history');
  assert.equal(elements.subscription.hidden, false);
  assert.match(elements['subscription-summary'].textContent, /规则模式.*订阅 \/ 手动 → 自动 → node-a/);
  assert.equal(card('GLOBAL'), undefined);
  assert.equal(card('自动').querySelectorAll('select, button').length, 0);
  assert.match(card('均衡').children[2].textContent, /按连接分配节点/);
  assert.equal(elements['traffic-rows'].children.length, 1);
  assert.equal(elements['traffic-rows'].children[0].children[1].textContent, 'example.com:443');
  assert.match(elements['traffic-rows'].children[0].children[3].textContent, /node-a/);
  await elements.devices.children[1].children[3].handlers.click();
  assert.equal(selected, 'laptop-b');
  assert.match(elements.notice.textContent, /laptop-b/);

  const choices = card(manual).querySelectorAll('select')[0];
  assert.equal(choices.children[2].textContent, unsafe); // Subscription strings remain plain text.
  choices.value = 'node-a';
  await card(manual).querySelectorAll('button')[0].handlers.click();
  assert.equal(subscription, 'node-a');
  assert.ok(requests.some(([url, options]) => url === '/proxies/' + encodeURIComponent(manual) && options.method === 'PUT'));
  assert.match(elements['subscription-summary'].textContent, /订阅 \/ 手动 → node-a/);
  assert.match(card(manual).children[3].textContent, /123 ms/);

  putFailure = true;
  card(manual).querySelectorAll('select')[0].value = unsafe;
  await card(manual).querySelectorAll('button')[0].handlers.click();
  assert.equal(subscription, 'node-a');
  assert.match(elements.notice.textContent, /500/);
  assert.equal(elements.refresh.disabled, false);
  putFailure = false;

  failoverEnabled = true;
  await elements.refresh.handlers.click();
  assert.match(elements['gateway-summary'].textContent, /当前直连/);
  assert.match(elements.notice.textContent, /直连回退/);
  assert.equal(card('SSH-Gateway-Route'), undefined);
  assert.equal(elements.routes.children[0].textContent, '10.42.0.0/16');
  effective = 'SSH-Gateway';
  await elements.refresh.handlers.click();
  assert.match(elements['gateway-summary'].textContent, /检查通过/);
  await elements.devices.children[0].children[3].handlers.click();
  assert.equal(selected, 'phone-main');
  assert.equal(effective, 'DIRECT');

  gatewayEnabled = false;
  await elements.refresh.handlers.click();
  assert.equal(elements.gateway.hidden, true);
  assert.equal(elements.routing.hidden, true);
  assert.equal(elements.subscription.hidden, false);
  mode = 'global';
  await elements.refresh.handlers.click();
  assert.ok(card('GLOBAL'));
  assert.match(elements['subscription-summary'].textContent, /全局模式.*GLOBAL/);
  mode = 'direct';
  await elements.refresh.handlers.click();
  assert.match(elements['subscription-summary'].textContent, /直连模式.*DIRECT/);

  authorized = false;
  await elements.refresh.handlers.click();
  for (const id of ['gateway', 'routing', 'subscription', 'traffic']) assert.equal(elements[id].hidden, true);
  assert.equal(elements.connection.open, true);
  assert.match(elements.notice.textContent, /口令/);
  elements.forget.handlers.click();
  assert.equal(stored.size, 0);
  assert.equal(elements.secret.value, '');
  console.log('PASS: dashboard authentication, gateway/subscription selection, mode/chain display, active connections and failure handling');
})().catch(error => { console.error(error); process.exitCode = 1; });
