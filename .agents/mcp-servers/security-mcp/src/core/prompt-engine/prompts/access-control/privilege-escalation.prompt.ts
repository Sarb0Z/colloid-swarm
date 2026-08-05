import type { SecurityPrompt } from '../../types.js';

export const privilegeEscalationPrompt: SecurityPrompt = {
  id: 'access-control.privilege-escalation',
  title: 'Vertical / horizontal privilege escalation',
  category: 'access-control',
  severityFocus: 'critical',
  prompt: [
    'Goal: Detect whether a lower-privileged user can reach higher-privileged functionality',
    '(vertical) or another peer\'s resources (horizontal).',
    '',
    'Evidence required: two principals in different roles; protected endpoint list; response',
    'codes and returned data for both principals on each endpoint.',
    '',
    'Constraints: read-only probing; never use the higher-privileged account to mutate data on',
    'behalf of the lower-privileged one.',
    '',
    'Output: severity critical with high confidence ONLY when differential evidence shows the',
    'lower role receives data/2xx for protected functionality; otherwise low confidence.',
    '',
    'Current scan coverage: untested. security_scan accepts at most one credential and does not',
    'run role-to-role differential requests. Do not emit a privilege finding from its evidence alone.',
  ].join('\n'),
};
