// RFC 9110: the most specific matching media range determines its quality.
export function negotiate(accept = '*/*') {
  const ranges = accept.toLowerCase().split(',').map(part => {
    const [type, ...params] = part.trim().split(';');
    const qParam = params.map(p => p.trim()).find(p => p.startsWith('q='));
    const q = qParam ? Number(qParam.slice(2)) : 1;
    return { type: type.trim(), q: Number.isFinite(q) && q >= 0 && q <= 1 ? q : 0 };
  });
  function quality(type) {
    const matches = ranges.map(r => ({ ...r, specificity: r.type === type ? 2 : r.type === 'text/*' ? 1 : r.type === '*/*' ? 0 : -1 })).filter(r => r.specificity >= 0).sort((a,b) => b.specificity - a.specificity || b.q - a.q);
    return matches[0]?.q ?? 0;
  }
  const html = quality('text/html'), markdown = quality('text/markdown');
  return html === 0 && markdown === 0 ? null : markdown > html ? 'markdown' : 'html';
}
export function send(request, response, status, html, markdown) {
  const format = negotiate(request.headers.accept);
  response.setHeader('Vary', 'Accept');
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('Link', '</llms.txt>; rel="describedby"' + (status === 200 ? ', </index.md>; rel="alternate"; type="text/markdown"' : ''));
  response.statusCode = format ? status : 406;
  response.setHeader('Content-Type', format === 'markdown' ? 'text/markdown; charset=utf-8' : format === 'html' ? 'text/html; charset=utf-8' : 'text/plain; charset=utf-8');
  response.end(request.method === 'HEAD' ? undefined : format === 'markdown' ? markdown : format === 'html' ? html : 'Supported response types: text/html, text/markdown.');
}
