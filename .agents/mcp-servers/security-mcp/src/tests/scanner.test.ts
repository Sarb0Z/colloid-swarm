import { createServer } from 'node:http';
import { appendFile, cp, mkdtemp, readdir } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { afterEach, describe, expect, it } from 'vitest';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { RuntimeConfig } from '../config/env.js';
import { scanTarget } from '../core/scanner/scanner.js';
import type { NetworkTransport } from '../core/scanner/http-client.js';
import { createMcpServer, TOOL_DEFINITIONS } from '../mcp/server.js';
import { securityScanInputSchema } from '../mcp/tools/security-scan.tool.js';
import { validateTargetInputSchema } from '../mcp/tools/validate-target.tool.js';
import { loadBundledTemplates, loadCommonPaths } from '../core/templates/template-loader.js';

const config = (maxRequests = 5): RuntimeConfig => ({
  allowedHosts: new Set(),
  requestTimeoutMs: 1_000,
  maxRequests,
  maxDepth: 2,
  maxRedirects: 2,
  maxBodyBytes: 16_384,
});

const servers: Array<ReturnType<typeof createServer>> = [];
const execFileAsync = promisify(execFile);
afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
});

describe('security scanner', () => {
  it('exposes exactly the retained MCP tools', () => {
    expect(TOOL_DEFINITIONS.map((tool) => tool.name)).toEqual([
      'validate_target',
      'security_scan',
      'list_security_prompts',
    ]);
  });

  it('initializes over MCP and lists exactly the retained tools', async () => {
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const server = createMcpServer();
    const client = new Client({ name: 'security-mcp-test', version: '1.0.0' });
    try {
      await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
      const response = await client.listTools();
      expect(response.tools.map((tool) => tool.name)).toEqual([
        'validate_target',
        'security_scan',
        'list_security_prompts',
      ]);
    } finally {
      await client.close();
      await server.close();
    }
  });

  it('does not let tool input add an authorized host', () => {
    expect(
      validateTargetInputSchema.safeParse({
        targetUrl: 'https://example.com',
        allowedHosts: ['example.com'],
      }).success,
    ).toBe(false);
    expect(
      securityScanInputSchema.safeParse({
        targetUrl: 'https://example.com',
        scanType: 'quick',
        allowedHosts: ['example.com'],
      }).success,
    ).toBe(false);
  });

  it('enforces the global request cap', async () => {
    let calls = 0;
    const transport: NetworkTransport = async () => {
      calls += 1;
      return {
        status: 200,
        headers: { 'content-type': 'text/html' },
        body: '<a href="/one">one</a><a href="/two">two</a><a href="/three">three</a>',
        bytes: 80,
      };
    };
    const result = await scanTarget(
      { targetUrl: 'http://127.0.0.1:8080', scanType: 'deep', includeContentDiscovery: false },
      config(2),
      { transport },
    );
    expect(calls).toBe(2);
    expect(result.evidence.requestCount).toBe(2);
  });

  it('reserves deep-scan requests for templates under the default limit', async () => {
    let calls = 0;
    const transport: NetworkTransport = async () => {
      calls += 1;
      return {
        status: 200,
        headers: { 'content-type': 'text/html' },
        body: '',
        bytes: 0,
      };
    };
    const result = await scanTarget(
      { targetUrl: 'http://127.0.0.1:8080', scanType: 'deep' },
      config(25),
      { transport },
    );
    expect(calls).toBeLessThanOrEqual(25);
    expect(result.evidence.coverage.phases.templates.allocatedRequests).toBeGreaterThan(0);
    expect(result.evidence.coverage.phases.templates.succeeded).toBeGreaterThan(0);
  });

  it('rejects an unauthorized root without a transport call', async () => {
    let calls = 0;
    const transport: NetworkTransport = async () => {
      calls += 1;
      return { status: 200, headers: {}, body: '', bytes: 0 };
    };
    await expect(
      scanTarget({ targetUrl: 'https://example.com', scanType: 'quick' }, config(), { transport }),
    ).rejects.toThrow('Target rejected');
    expect(calls).toBe(0);
  });

  it('records later request failures instead of collapsing them into notes', async () => {
    const secret = 'later-error secret';
    let calls = 0;
    const transport: NetworkTransport = async () => {
      calls += 1;
      if (calls > 1) throw new Error(`reflected ${secret}`);
      return {
        status: 200,
        headers: { 'content-type': 'text/html' },
        body: '<a href="/later">later</a>',
        bytes: 26,
      };
    };
    const result = await scanTarget(
      {
        targetUrl: 'http://127.0.0.1:8080',
        scanType: 'standard',
        includeTemplates: false,
        credentials: { bearerToken: secret },
      },
      config(4),
      { transport },
    );
    expect(result.evidence.coverage.phases.crawl.failed).toBe(1);
    expect(result.evidence.coverage.failures).toHaveLength(1);
    expect(JSON.stringify(result)).not.toContain(secret);
  });

  it('treats an empty credentials object as anonymous', async () => {
    const transport: NetworkTransport = async () => ({
      status: 200,
      headers: { 'content-type': 'text/html' },
      body: '',
      bytes: 0,
    });
    const result = await scanTarget(
      {
        targetUrl: 'http://127.0.0.1:8080/admin',
        scanType: 'quick',
        includeTemplates: false,
        credentials: {},
      },
      config(),
      { transport },
    );
    expect(result.findings.some((finding) => finding.promptId === 'authentication.auth-bypass')).toBe(true);
  });

  it('scrubs reflected credentials from extraction, findings, and successful MCP serialization', async () => {
    const token = 'mix/value?with space';
    const cookie = 'cookie/value?private';
    const encodedToken = encodeURIComponent(token);
    const mixedCaseToken = encodedToken.replace('%2F', '%2f');
    const encodedCookie = encodeURIComponent(cookie);
    const transport: NetworkTransport = async () => ({
      status: 200,
      headers: {
        'content-type': 'text/html',
        server: `server-${mixedCaseToken}`,
        'x-powered-by': `runtime-${encodedCookie}`,
      },
      body:
        `<a href="/next?trace=${mixedCaseToken}">${cookie}</a>` +
        `<form action="/submit?value=${encodedCookie}"><input name="value"></form>` +
        `<script>fetch('/api?trace=${encodedToken}')</script>`,
      bytes: 200,
    });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const server = createMcpServer({ transport });
    const client = new Client({ name: 'redaction-test', version: '1.0.0' });
    try {
      await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
      const response = await client.callTool({
        name: 'security_scan',
        arguments: {
          targetUrl: `http://127.0.0.1:8080/?trace=${encodedToken}`,
          scanType: 'standard',
          includeTemplates: false,
          credentials: { bearerToken: token, cookies: { session: cookie } },
        },
      });
      const serialized = JSON.stringify(response);
      for (const secret of [token, cookie, encodedToken, mixedCaseToken, encodedCookie]) {
        expect(serialized).not.toContain(secret);
      }
      expect(serialized).toContain('[REDACTED]');
    } finally {
      await client.close();
      await server.close();
    }
  });

  it('returns a structured, redacted MCP error for root network failure', async () => {
    const secret = 'root/error +private';
    const encoded = encodeURIComponent(secret);
    const transport: NetworkTransport = async () => {
      throw new Error(`system failure ${secret} ${encoded}`);
    };
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const server = createMcpServer({ transport });
    const client = new Client({ name: 'root-failure-test', version: '1.0.0' });
    try {
      await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
      const response = await client.callTool({
        name: 'security_scan',
        arguments: {
          targetUrl: 'http://127.0.0.1:8080',
          scanType: 'quick',
          credentials: { bearerToken: secret },
        },
      });
      expect(response.isError).toBe(true);
      const serialized = JSON.stringify(response);
      expect(serialized).not.toContain(secret);
      expect(serialized).not.toContain(encoded);
      if (!Array.isArray(response.content)) throw new Error('MCP error content is not an array');
      const text = response.content.find(
        (entry: unknown): entry is { type: 'text'; text: string } =>
          Boolean(
            entry &&
              typeof entry === 'object' &&
              (entry as { type?: unknown }).type === 'text' &&
              typeof (entry as { text?: unknown }).text === 'string',
          ),
      );
      if (!text) throw new Error('MCP error has no text content');
      expect(JSON.parse(text.text)).toMatchObject({
        ok: false,
        phase: 'root',
        coverage: { phases: { root: { attempted: 1, failed: 1 } } },
      });
    } finally {
      await client.close();
      await server.close();
    }
  });

  it('performs a functional loopback scan without persistence', async () => {
    const beforeDirectory = await mkdtemp(join(tmpdir(), 'security-mcp-no-write-'));
    const server = createServer((_request, response) => {
      response.writeHead(200, { 'content-type': 'text/html', 'x-content-type-options': 'nosniff' });
      response.end('<a href="/next">next</a>');
    });
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Test server has no TCP address');
    const result = await scanTarget(
      {
        targetUrl: `http://127.0.0.1:${address.port}`,
        scanType: 'standard',
        includeTemplates: false,
        includeContentDiscovery: false,
      },
      config(4),
    );
    expect(result.ok).toBe(true);
    expect(result.evidence.pages).toHaveLength(2);
    expect(await readdir(beforeDirectory)).toEqual([]);
  });

  it('destroys an oversized response and reports truncation at the hard body limit', async () => {
    let writes = 0;
    let responseClosed: (() => void) | undefined;
    const closed = new Promise<void>((resolveClosed) => {
      responseClosed = resolveClosed;
    });
    const server = createServer((_request, response) => {
      const interval = setInterval(() => {
        writes += 1;
        response.write('x'.repeat(1_024));
        if (writes === 100) response.end();
      }, 1);
      response.on('close', () => {
        clearInterval(interval);
        responseClosed?.();
      });
    });
    servers.push(server);
    await new Promise<void>((resolveListen) => server.listen(0, '127.0.0.1', resolveListen));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Test server has no TCP address');
    const limitedConfig = { ...config(2), maxBodyBytes: 64 };
    const result = await scanTarget(
      {
        targetUrl: `http://127.0.0.1:${address.port}`,
        scanType: 'quick',
        includeTemplates: false,
      },
      limitedConfig,
    );
    await closed;
    expect(writes).toBeLessThan(100);
    expect(result.evidence.pages[0]).toMatchObject({
      bytes: 64,
      truncated: true,
      bodyLimitBytes: 64,
    });
    expect(result.evidence.coverage.phases.root.truncated).toBe(1);
  });

  it('loads templates and the wordlist from tracked asset paths', async () => {
    expect((await loadBundledTemplates()).length).toBeGreaterThan(20);
    expect((await loadCommonPaths()).length).toBeGreaterThan(20);
  });

  it('rejects a tampered dist before clean-build comparison', async () => {
    const fixture = await mkdtemp(join(tmpdir(), 'security-mcp-tamper-'));
    await cp(resolve('dist'), fixture, { recursive: true });
    await appendFile(join(fixture, 'server.js'), '\n// tampered\n');
    let diagnostic = '';
    try {
      await execFileAsync(process.execPath, [
        resolve('scripts/check-bundle.mjs'),
        `--dist=${fixture}`,
      ]);
    } catch (error) {
      const failure = error as { stderr?: string; message?: string };
      diagnostic = failure.stderr ?? failure.message ?? '';
    }
    expect(diagnostic).toContain('does not match its build manifest');
  });
});
