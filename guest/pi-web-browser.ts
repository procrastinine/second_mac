import { Type } from '@sinclair/typebox';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { homedir } from 'node:os';
import { mkdir, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const actions = ['open', 'goto', 'snapshot', 'find', 'click', 'fill', 'type', 'press',
  'select', 'go-back', 'go-forward', 'reload', 'screenshot', 'close'] as const;

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: 'web_browser',
    label: 'Brave Browser',
    description: 'Headless Brave with adblocking for JavaScript pages and interactive web research. '
      + 'Use web_search first, fetch_content for readable sources, and this browser when rendering or interaction is needed. '
      + 'open/goto: target is a URL (including a Google, Bing, or DuckDuckGo search URL). '
      + 'snapshot gives element refs; click uses a ref; fill/select use target ref and value; '
      + 'type/press/find use target as text/key/search text. Google can return CAPTCHA/429: use another search provider then. '
      + 'Ketch is also available through bash: ketch search "query" --multi=exa,parallel,ddg --json; '
      + 'ketch scrape URL; ketch code "pattern". Check source pages and cite their URLs. Close browser when finished.',
    parameters: Type.Object({
      action: Type.Union(actions.map(action => Type.Literal(action))),
      target: Type.Optional(Type.String()),
      value: Type.Optional(Type.String()),
    }),
    async execute(_id, params, signal) {
      const work = join(homedir(), '.cache/pi-browser');
      await mkdir(work, { recursive: true });
      const args = ['-s=pi-web', params.action];
      const needsTarget = ['goto', 'find', 'click', 'fill', 'type', 'press', 'select'];
      if (needsTarget.includes(params.action) && !params.target)
        throw new Error(`${params.action} requires target`);
      if (['fill', 'select'].includes(params.action) && params.value === undefined)
        throw new Error(`${params.action} requires value`);
      if (params.target) {
        if (params.target.startsWith('-')) throw new Error('target must be a URL, element ref, text or key, not a CLI flag');
        args.push(params.target);
      }
      if (params.value !== undefined) args.push(params.value);
      if (params.action === 'screenshot') args.push(`--filename=${join(work, 'screenshot.png')}`);
      const result = await pi.exec('/usr/bin/env', [
        `PLAYWRIGHT_MCP_CONFIG=${join(homedir(), '.config/playwright-brave-pi.json')}`,
        '/opt/homebrew/bin/node', '/opt/homebrew/bin/playwright-cli', ...args],
        { cwd: work, timeout: 60000, signal });
      let output = result.stdout + (result.stderr ? '\n' + result.stderr : '');
      const snapshot = output.match(/\[Snapshot\]\(([^)]+)\)/);
      if (snapshot) {
        const path = resolve(work, snapshot[1]);
        if (path.startsWith(work + '/')) output += '\n' + await readFile(path, 'utf8');
      }
      const content: any[] = [{ type: 'text', text: output.length > 26000
        ? output.slice(0, 26000) + '\n[Truncated. Use find or read the snapshot file for more.]' : output }];
      if (params.action === 'screenshot' && result.code === 0)
        content.push({ type: 'image', mimeType: 'image/png', data: (await readFile(join(work, 'screenshot.png'))).toString('base64') });
      return { content, details: { exitCode: result.code }, isError: result.code !== 0 };
    },
  });
}
