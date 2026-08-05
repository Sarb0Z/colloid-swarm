import type { SecurityPrompt } from '../../types.js';

export const tenantIsolationPrompt: SecurityPrompt = {
  id: 'multi-tenant.isolation',
  title: 'Multi-tenant data isolation',
  category: 'multi-tenant',
  severityFocus: 'critical',
  prompt: [
    'Goal: Verify that the server derives tenant scope from the authenticated principal.',
    '',
    'Evidence required: at least two principals in different tenants, the same object request for',
    'each principal, and a comparison of returned data.',
    '',
    'Constraints: use read operations only. Never mutate cross-tenant data.',
    '',
    'Current scan coverage: untested. security_scan accepts at most one credential and does not',
    'run cross-tenant differential requests. Do not emit an isolation finding from its evidence alone.',
  ].join('\n'),
};
