import type { Confidence, Finding, Severity } from '../../types/finding.types.js';
import type { PromptContext } from './prompt-context.js';

export type PromptCategory =
  | 'headers'
  | 'auth'
  | 'authorization'
  | 'api'
  | 'access-control'
  | 'input-validation'
  | 'injection'
  | 'business-logic'
  | 'payment'
  | 'files'
  | 'infrastructure'
  | 'configuration'
  | 'multi-tenant'
  | 'reporting';

export interface SecurityPrompt {
  id: string;
  title: string;
  category: PromptCategory;
  severityFocus: Severity;
  /**
   * Free-form text that describes the test, required evidence, and structured
   * finding format. The calling agent applies this text to scan evidence.
   */
  prompt: string;
  /**
   * Optional deterministic heuristic that produces findings directly from
   * evidence.
   */
  heuristic?: (ctx: PromptContext) => PromptFinding[];
}

/**
 * A finding as emitted by a prompt module. Severity and confidence are
 * always required so we never claim certainty we don't have.
 */
export interface PromptFinding extends Omit<Finding, 'id' | 'promptId' | 'confidence'> {
  confidence: Confidence;
}
