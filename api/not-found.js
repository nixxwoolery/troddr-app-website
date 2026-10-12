import { send } from './_lib/negotiation.js';
export default function handler(request, response) {
  response.setHeader('X-Robots-Tag', 'noindex');
  send(request, response, 404, '<!doctype html><html lang="en"><title>Page not found | TRODDR</title><h1>404 — Page not found</h1><p>The requested TRODDR page does not exist.</p><a href="/">TRODDR home</a></html>', '# 404 — Page not found\n\nThe requested TRODDR page does not exist. Check the URL or explore [TRODDR agent resources](https://www.troddr.com/llms.txt) and the [sitemap](https://www.troddr.com/sitemap.xml).\n');
}
