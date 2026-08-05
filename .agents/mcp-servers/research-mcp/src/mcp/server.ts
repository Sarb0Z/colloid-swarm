import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { getConfig, VERSION, type RuntimeConfig } from '../config/env.js';
import { HttpClient } from '../core/http-client.js';
import type { Resolver } from '../core/url-policy.js';
import {
  fetchReadableInputSchema,
  fetchReadableToolDefinition,
  handleFetchReadable,
} from './tools/fetch-readable.tool.js';
import {
  handleResolveOpenAccess,
  resolveOpenAccessInputSchema,
  resolveOpenAccessToolDefinition,
} from './tools/resolve-open-access.tool.js';

export const TOOL_DEFINITIONS = Object.freeze([
  fetchReadableToolDefinition,
  resolveOpenAccessToolDefinition,
]);

export interface ServerDependencies {
  config?: RuntimeConfig;
  resolver?: Resolver;
}

export function createMcpServer(dependencies: ServerDependencies = {}): Server {
  const config = dependencies.config ?? getConfig();
  const http = new HttpClient(config, dependencies.resolver);
  const server = new Server(
    { name: 'research-mcp', version: VERSION },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOL_DEFINITIONS }));
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const args = request.params.arguments ?? {};
    try {
      switch (request.params.name) {
        case 'fetch_readable':
          return jsonContent(await handleFetchReadable(fetchReadableInputSchema.parse(args), http));
        case 'resolve_open_access':
          return jsonContent(
            await handleResolveOpenAccess(resolveOpenAccessInputSchema.parse(args), http, config),
          );
        default:
          return jsonContent({ ok: false, error: `Unknown tool: ${request.params.name}` }, true);
      }
    } catch (error) {
      return jsonContent(
        { ok: false, error: error instanceof Error ? error.message : 'Tool execution failed' },
        true,
      );
    }
  });
  return server;
}

function jsonContent(payload: unknown, isError = false) {
  return {
    content: [{ type: 'text' as const, text: JSON.stringify(payload, null, 2) }],
    isError,
  };
}
