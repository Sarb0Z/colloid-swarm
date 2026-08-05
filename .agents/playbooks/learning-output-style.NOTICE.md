# MODIFIED SOURCE NOTICE

This repository contains a modified adaptation of the Anthropic
`learning-output-style` plugin. The source plugin is version 1.0.0 from the
official Claude plugins marketplace.

Marketplace package path:
`claude-plugins-official/learning-output-style/1.0.0/`

Source files:

- `.claude-plugin/plugin.json`
- `hooks-handlers/session-start.sh`
- `hooks/hooks.json`
- `LICENSE`

Verified source hashes:

- `hooks-handlers/session-start.sh`:
  `2b2ef02fffeb9df6d587a3180ab3bb06e1364a75f70e2f534045b599b953731e`
- `hooks/hooks.json`:
  `2f5725548acfcae80ae997996a5037aad0754c13498cd81b87df35893f283db8`
- `LICENSE`:
  `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`

Repository adaptation:

- The policy uses the shared SessionStart hook.
- The policy uses a repository config switch.
- The policy offers non-blocking contributions only for meaningful decisions.
- The policy continues with the recommended implementation when the user does
  not accept the contribution.
- The policy does not leave an unfinished code placeholder.

The source distribution does not identify a revision. Do not infer one from
the marketplace cache path.

The Apache License 2.0 applies to the source work. See
`../licenses/learning-output-style-APACHE-2.0.txt`.
