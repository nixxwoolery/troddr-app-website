import assert from 'node:assert/strict';
const base = process.argv[2] || 'http://localhost:3088';
const checks = [
  ['/', 'text/markdown', 200, 'text/markdown', '# TRODDR'],
  ['/', 'text/html', 200, 'text/html', '<!DOCTYPE html>'],
  ['/index.html', 'text/markdown', 200, 'text/markdown', '# TRODDR'],
  ['/__ora-agent-check-does-not-exist', 'text/markdown', 404, 'text/markdown', '/llms.txt'],
  ['/__ora-agent-check-does-not-exist', 'text/html', 404, 'text/html', 'Page not found'],
  ['/', 'application/json', 406, 'text/plain', 'Supported response types'],
  ['/llms.txt', '*/*', 200, 'text/plain', 'When to use this:'],
  ['/index.md', '*/*', 200, 'text/markdown', '# TRODDR'],
  ['/developers.md', '*/*', 200, 'text/markdown', 'When to use TRODDR'],
  ['/developers', 'text/html', 200, 'text/html', 'TRODDR Developer'],
  ['/robots.txt', '*/*', 200, 'text/plain', 'Sitemap:'],
  ['/sitemap.xml', '*/*', 200, 'application/xml', '/developers'],
  ['/app', 'text/html', 200, 'text/html', '<!DOCTYPE html>'],
  ['/css/style.css', '*/*', 200, 'text/css', '{'],
  ['/where-to-eat-in-jamaica', 'text/html', 200, 'text/html', 'TRODDR'],
  ['/things-to-do-in-jamaica', 'text/html', 200, 'text/html', 'TRODDR'],
  ['/things-to-do-in-kingston', 'text/html', 200, 'text/html', 'TRODDR'],
  ['/about.html', 'text/html', 200, 'text/html', 'TRODDR'],
  ['/contact.html', 'text/html', 200, 'text/html', 'Negril, Jamaica'],
  ['/privacy.html', 'text/html', 200, 'text/html', 'TRODDR'],
  ['/terms_and_conditions.html', 'text/html', 200, 'text/html', 'TRODDR'],
];
let failures=0;
for (const [path, accept, status, type, content] of checks) {
  try {
    const r=await fetch(base+path,{headers:{Accept:accept}});const body=await r.text();
    assert.equal(r.status,status);assert.ok(r.headers.get('content-type')?.startsWith(type),r.headers.get('content-type'));assert.ok(body.includes(content), 'Unexpected body');
    if (path==='/' || path==='/index.html' || status===404) assert.match(r.headers.get('vary') || '', /Accept/i);
    console.log(`PASS ${path} (${accept}) → ${r.status} ${r.headers.get('content-type')}`);
  } catch(e) { failures++;console.error(`FAIL ${path} (${accept}): ${e.message}`); }
}
const sitemap = await (await fetch(base + '/sitemap.xml')).text();
for (const match of sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)) {
  const path = new URL(match[1]).pathname;
  if (checks.some(check => check[0] === path)) continue;
  try {
    const r = await fetch(base + path); const body = await r.text();
    assert.equal(r.status, 200); assert.ok(body.length > 20); assert.match(r.headers.get('content-type'), /text\/html/);
    console.log(`PASS sitemap page ${path}`);
  } catch (e) { failures++; console.error(`FAIL sitemap page ${path}: ${e.message}`); }
}
for (const path of ['/.well-known/apple-app-site-association', '/.well-known/assetlinks.json']) {
  try {
    const r = await fetch(base + path); assert.equal(r.status, 200); await r.json();
    if (path === '/.well-known/apple-app-site-association' && new URL(base).hostname === 'localhost' && r.headers.get('content-type') === 'application/octet-stream') {
      console.log(`WARN ${path}: valid JSON; local Vercel CLI overrides configured application/json header. Check deployed header.`);
    } else { assert.match(r.headers.get('content-type'), /application\/json/); console.log(`PASS JSON resource ${path}`); }
  } catch (e) { failures++; console.error(`FAIL ${path}: ${e.message}`); }
}
if (failures) process.exitCode=1;
