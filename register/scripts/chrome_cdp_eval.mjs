#!/usr/bin/env node

const port = process.env.CDP_PORT || '9222';
const targetId = process.env.CDP_TARGET_ID || '';
const urlIncludes = process.env.CDP_TARGET_URL_INCLUDES || '';
const expr = process.env.CDP_JS_EXPR || '';

if (!expr) {
  console.error('Set CDP_JS_EXPR before running chrome_cdp_eval.mjs');
  process.exit(64);
}

const base = `http://127.0.0.1:${port}`;

const versionResp = await fetch(`${base}/json/version`);
if (!versionResp.ok) {
  throw new Error(`Failed to fetch ${base}/json/version: ${versionResp.status}`);
}
const version = await versionResp.json();

const targetsResp = await fetch(`${base}/json/list`);
if (!targetsResp.ok) {
  throw new Error(`Failed to fetch ${base}/json/list: ${targetsResp.status}`);
}
const targets = await targetsResp.json();

const pages = targets.filter((t) => t.type === 'page');
let target = null;

if (targetId) {
  target = pages.find((t) => t.id === targetId) || null;
}

if (!target && urlIncludes) {
  target = [...pages].reverse().find((t) => (t.url || '').includes(urlIncludes)) || null;
}

if (!target) {
  target = pages.at(-1) || null;
}

if (!target) {
  throw new Error('No page target found for CDP evaluation');
}

class CDPClient {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.ws = null;
    this.nextId = 1;
    this.pending = new Map();
  }

  async connect() {
    this.ws = new WebSocket(this.wsUrl);
    await new Promise((resolve, reject) => {
      this.ws.onopen = () => resolve();
      this.ws.onerror = (error) => reject(error);
    });

    this.ws.onmessage = (event) => {
      const payload = JSON.parse(event.data);
      if (payload.id && this.pending.has(payload.id)) {
        const { resolve, reject } = this.pending.get(payload.id);
        this.pending.delete(payload.id);
        if (payload.error) {
          reject(new Error(payload.error.message || JSON.stringify(payload.error)));
        } else {
          resolve(payload.result);
        }
      }
    };
  }

  send(method, params = {}, sessionId = null) {
    const id = this.nextId++;
    const message = { id, method, params };
    if (sessionId) {
      message.sessionId = sessionId;
    }
    this.ws.send(JSON.stringify(message));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
  }

  close() {
    this.ws?.close();
  }
}

const client = new CDPClient(version.webSocketDebuggerUrl);
await client.connect();

try {
  const { sessionId } = await client.send('Target.attachToTarget', {
    targetId: target.id,
    flatten: true,
  });

  await client.send('Runtime.enable', {}, sessionId);
  const result = await client.send('Runtime.evaluate', {
    expression: `(async () => { return await (${expr})(); })()`,
    awaitPromise: true,
    returnByValue: true,
  }, sessionId);

  const payload = result.result;
  if (payload.subtype === 'error') {
    throw new Error(payload.description || payload.value || 'Runtime evaluation failed');
  }

  if (payload.value !== undefined) {
    if (typeof payload.value === 'string') {
      console.log(payload.value);
    } else {
      console.log(JSON.stringify(payload.value, null, 2));
    }
  }
} finally {
  client.close();
}
