import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import home from '../api/home.js';
import notFound from '../api/not-found.js';
import { negotiate } from '../api/_lib/negotiation.js';
import { getTransformedRoutes } from '@vercel/routing-utils';
const read = path => readFileSync(path, 'utf8');
function response(handler, accept, method = 'GET') {
  const result = { headers: {}, setHeader(key,value) { this.headers[key.toLowerCase()] = value; }, end(body) { this.body = body; } };
  handler({ headers: { accept }, method }, result);
  return result;
}
test('Accept negotiation honors specificity, exclusions, weights and HTML defaults', () => {
  for (const [accept, expected] of [[undefined,'html'],['*/*','html'],['text/markdown','markdown'],['TEXT/MARKDOWN; charset=utf-8','markdown'],['text/html','html'],['text/markdown;q=0.2,text/html;q=0.9','html'],['text/*;q=0.9,text/html;q=0','markdown'],['text/markdown;q=0,*/*;q=1','html'],['application/json',null],['text/html;q=0,text/markdown;q=0',null]]) assert.equal(negotiate(accept),expected,accept);
});
test('homepage serves exact existing HTML or meaningful Markdown and Vary', () => {
  for (const [accept, type, body] of [['text/html','text/html',read('index.html')],['text/markdown','text/markdown',read('index.md')]]) {
    const r=response(home,accept);assert.equal(r.statusCode,200);assert.ok(r.headers['content-type'].startsWith(type));assert.equal(r.headers.vary,'Accept');assert.equal(r.body,body);
  }
  assert.equal(response(home,'application/json').statusCode,406);
  assert.equal(response(home,'text/markdown','HEAD').body,undefined);
});
test('unknown paths retain 404 with explanatory Markdown and resource links', () => {
  const r=response(notFound,'text/markdown');assert.equal(r.statusCode,404);assert.match(r.headers['content-type'],/^text\/markdown/);assert.equal(r.headers.vary,'Accept');assert.ok(r.body.length>20);assert.match(r.body,/\[.+\]\(https:\/\/www.troddr.com\/llms.txt\)/);
  assert.equal(response(notFound,'text/html').statusCode,404);assert.equal(response(notFound,'text/markdown','HEAD').body,undefined);
});
test('routing preserves all original compiled rules and runs fallback after filesystem', () => {
  const before=read('vercel.json');execFileSync(process.execPath,['scripts/build-agent-routing.js']);assert.equal(read('vercel.json'),before);
  const routes=JSON.parse(before).routes;
  const original=getTransformedRoutes(JSON.parse(read('scripts/vercel-routing-source.json'))).routes;
  for (const route of original) assert.ok(routes.some(r=>JSON.stringify(r)===JSON.stringify(route)),JSON.stringify(route));
  assert.equal(routes.find(r=>r.src?.includes('apple-app-site-association')).headers['Content-Type'],'application/json');assert.equal(routes.at(-2).handle,'error');assert.equal(routes.at(-1).dest,'/api/not-found');assert.ok(routes.findIndex(r=>r.dest==='/api/home')<routes.findIndex(r=>r.handle==='filesystem'));
});
test('llms format and resource links, developer discovery, sitemap and brand metadata', () => {
  const llms=read('llms.txt');assert.match(llms,/^# TRODDR\n\n> /);assert.match(llms,/When to use this:/);assert.match(llms,/How to call:/);
  for (const section of llms.split(/^## /m).slice(1)) for (const line of section.split('\n').slice(1).filter(Boolean)) assert.match(line,/^- \[.+\]\(https:\/\/.+\)(: .+)?$/);
  for (const file of ['index.md','developers.md','developers.html','llms.txt','robots.txt','sitemap.xml']) assert.ok(read(file).length>20);
  for (const file of ['llms.txt','index.md','developers.md']) {
    for (const match of read(file).matchAll(/https:\/\/www\.troddr\.com([^\s)]+)/g)) {
      const path=match[1].split(/[?#]/)[0]; if (/\.(md|txt|xml|html)$/.test(path)) assert.ok(existsSync('.'+path),path);
    }
  }
  assert.match(read('developers.html'),/<title>TRODDR Developer/);assert.match(read('developers.md'),/no supported third-party API/);assert.match(read('sitemap.xml'),/https:\/\/www.troddr.com\/developers/);
  assert.match(read('index.html'),/<title>TRODDR: Jamaica Travel Guide/);assert.match(read('index.html'),/rel="describedby" href="\/llms.txt"/);
});
test('Organization includes factual location, description and complete contact', () => {
  const scripts=[...read('index.html').matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map(m=>JSON.parse(m[1]));
  const org=scripts.find(s=>s.publisher)?.publisher;
  assert.equal(org['@type'],'Organization');assert.ok(org.description.length>20);assert.equal(org.address['@type'],'PostalAddress');assert.equal(org.address.addressLocality,'Negril');assert.equal(org.address.addressCountry,'JM');assert.equal(org.contactPoint.email,'hello@troddr.com');assert.ok(org.contactPoint.contactType);
  assert.match(read('contact.html'),/Negril, Jamaica/);
});
