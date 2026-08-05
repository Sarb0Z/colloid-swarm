import type { SecurityPrompt } from '../../types.js';

export const idorPrompt: SecurityPrompt = {
  id: 'access-control.idor',
  title: 'Insecure Direct Object Reference (IDOR)',
  category: 'access-control',
  severityFocus: 'high',
  prompt: [
    'Goal: Verify that the authenticated principal owns or may access every requested object.',
    '',
    'Evidence required: the same object request from at least two principals with different ownership',
    'scopes, including response status and returned data.',
    '',
    'Constraints: use read operations only. Do not enumerate unrelated records or modify data.',
    '',
    'Current scan coverage: untested. security_scan accepts at most one credential and does not',
    'run principal-to-principal differential requests. Do not emit an IDOR finding from its evidence alone.',
  ].join('\n'),
};
