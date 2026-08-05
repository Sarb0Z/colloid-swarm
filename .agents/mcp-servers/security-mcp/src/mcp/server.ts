import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { SecretRedactor } from '../core/policy/redaction.js';
import { ScanExecutionError } from '../core/scanner/scanner.js';
import type { AuthorizedRequestDependencies } from '../core/scanner/http-client.js';
import {
  handleListPrompts,
  listPromptsInputSchema,
  listPromptsToolDefinition,
} from './tools/list-prompts.tool.js';
import {
  handleSecurityScan,
  securityScanInputSchema,
  securityScanToolDefinition,
} from './tools/security-scan.tool.js';
import {
  handleValidateTarget,
  validateTargetInputSchema,
  validateTargetToolDefinition,
} from './tools/validate-target.tool.js';

export const TOOL_DEFINITIONS = Object.freeze([
  validateTargetToolDefinition,
  securityScanToolDefinition,
  listPromptsToolDefinition,
]);

export function createMcpServer(dependencies: AuthorizedRequestDependencies = {}): Server {
  const server = new Server(
    { name: 'security-mcp', version: '0.10.0-colloid.1' },
    { capabilities: { tools: {} } },
  );
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOL_DEFINITIONS }));
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const args = request.params.arguments ?? {};
    const redactor = SecretRedactor.fromToolArguments(args);
    try {
      switch (request.params.name) {
        case 'validate_target':
          return jsonContent(
            await handleValidateTarget(validateTargetInputSchema.parse(args)),
            false,
            redactor,
          );
        case 'security_scan':
          return jsonContent(
            await handleSecurityScan(securityScanInputSchema.parse(args), dependencies),
            false,
            redactor,
          );
        case 'list_security_prompts':
          return jsonContent(handleListPrompts(listPromptsInputSchema.parse(args)), false, redactor);
        default:
          return jsonContent(
            { ok: false, error: `Unknown tool: ${request.params.name}` },
            true,
            redactor,
          );
      }
    } catch (error) {
      if (error instanceof ScanExecutionError) {
        return jsonContent(error.result, true, redactor);
      }
      return jsonContent(
        { ok: false, error: error instanceof Error ? error.message : 'Tool execution failed' },
        true,
        redactor,
      );
    }
  });
  return server;
}

function jsonContent(payload: unknown, isError: boolean, redactor: SecretRedactor) {
  return {
    isError,
    content: [{ type: 'text' as const, text: JSON.stringify(redactor.scrubSerializable(payload)) }],
  };
}
