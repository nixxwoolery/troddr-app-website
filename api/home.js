import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { send } from './_lib/negotiation.js';
export default function handler(request, response) {
  send(request, response, 200, readFileSync(join(process.cwd(), 'index.html'), 'utf8'), readFileSync(join(process.cwd(), 'index.md'), 'utf8'));
}
