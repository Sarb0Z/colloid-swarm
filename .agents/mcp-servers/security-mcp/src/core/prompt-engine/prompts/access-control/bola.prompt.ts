import type { SecurityPrompt } from '../../types.js';

export const bolaPrompt: SecurityPrompt = {
  id: 'access-control.bola',
  title: 'Broken Object Level Authorization (BOLA)',
  category: 'access-control',
  severityFocus: 'high',
  prompt: [
    'Goal: Verify that object-level authorization is enforced on each API endpoint that returns,',
    'mutates, or deletes a single object.',
    '',
    'Evidence required: at least two principals with different ownership scopes, the same endpoint',
    'and object identifier, and response status and data for the foreign principal.',
    '',
    'Constraints: use read operations only. Do not issue mutating requests against another tenant.',
    '',
    'Current scan coverage: untested. security_scan accepts at most one credential and does not',
    'run principal-to-principal differential requests. Do not emit a BOLA finding from its evidence alone.',
  ].join('\n'),
};
