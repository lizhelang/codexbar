#!/usr/bin/env node

const port = process.env.CDP_PORT || '9222';
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

console.log(JSON.stringify({
  browser: version.Browser,
  webSocketDebuggerUrl: version.webSocketDebuggerUrl,
  targets: targets
    .filter((t) => t.type === 'page')
    .map((t) => ({
      id: t.id,
      title: t.title,
      url: t.url,
      type: t.type,
    })),
}, null, 2));
