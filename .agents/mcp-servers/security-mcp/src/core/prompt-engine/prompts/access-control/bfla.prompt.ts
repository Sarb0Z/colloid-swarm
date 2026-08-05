import type { SecurityPrompt } from '../../types.js';

export const bflaPrompt: SecurityPrompt = {
  id: 'access-control.bfla',
  title: 'Broken Function Level Authorization (BFLA)',
  category: 'access-control',
  severityFocus: 'high',
  prompt: [
    'Goal: Verify that higher-privilege functions reject anonymous and lower-privilege principals.',
    '',
    'Evidence required: the same protected function requested anonymously, by a lower-privilege',
    'principal, and by an authorized principal, with response status and returned data.',
    '',
    'Constraints: use read operations only. Do not execute state-changing administrative actions.',
    '',
    'Current scan coverage: untested. security_scan accepts at most one credential and does not',
    'run role-to-role differential requests. Do not emit a BFLA finding from its evidence alone.',
  ].join('\n'),
};
