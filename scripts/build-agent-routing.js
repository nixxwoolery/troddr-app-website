import { readFileSync, writeFileSync } from 'node:fs';
import { getTransformedRoutes } from '@vercel/routing-utils';
const source = JSON.parse(readFileSync(new URL('./vercel-routing-source.json', import.meta.url)));
// Keep the original high-level routing configuration editable and use Vercel's
// own compiler to preserve conditions, query parameters, redirects and headers.
source.rewrites.unshift({ source: '/developers', destination: '/developers.html' });
for (const path of ['/llms.txt', '/index.md', '/developers.md']) {
  source.headers.push({ source: path, headers: [{ key: 'Content-Type', value: path === '/llms.txt' ? 'text/plain; charset=utf-8' : 'text/markdown; charset=utf-8' }, { key: 'Link', value: '</llms.txt>; rel="describedby"' }] });
}
const { routes, error } = getTransformedRoutes(source);
if (error) throw new Error(JSON.stringify(error));
const filesystem = routes.findIndex(route => route.handle === 'filesystem');
routes.splice(filesystem, 0, { src: '^/(?:index\\.html)?$', dest: '/api/home' });
// Only after real files and existing application rewrites have been checked.
routes.push({ handle: 'error' }, { src: '/.*', dest: '/api/not-found', status: 404 });
const { rewrites, redirects, headers, ...rest } = source;
const output = { ...rest, routes, functions: { ...rest.functions, 'api/home.js': { includeFiles: '{index.html,index.md}' } } };
writeFileSync(new URL('../vercel.json', import.meta.url), JSON.stringify(output, null, 2) + '\n');
