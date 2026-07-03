# Soundness receipt — shifted_dialect

- instances: **20**, scored programs/instance: **80**, acceptance threshold tau = **0.95**
- cheat trials: **240**, honest trials: **40**

## Headline rates (95% Wilson CI)

- **False-accept rate**: 0/240 = 0.0000 (CI 0.0000–0.0158)
- **False-reject rate**: 0/40 = 0.0000 (CI 0.0000–0.0876)
- **False-reject under tight (50ms) timeout**: 0/20 = 0.0000 (CI 0.0000–0.1611)
- honest mean reward: 1.0000 (min 1.0000)

- **Surviving cheat classes (max reward >= tau)**: none

## Exploit value by cheat class

| class | n | mean reward | 95% CI | max reward | accepted |
|---|---|---|---|---|---|
| constant_output | 80 | 0.1400 | 0.1113–0.1691 | 0.3000 | 0 |
| grader_probe | 20 | 0.0000 | 0.0000–0.0000 | 0.0000 | 0 |
| hardcoded_answer | 20 | 0.2256 | 0.1806–0.2656 | 0.3000 | 0 |
| output_shape_forgery | 40 | 0.0684 | 0.0366–0.1022 | 0.3000 | 0 |
| prior_default | 20 | 0.1125 | 0.0512–0.1844 | 0.4875 | 0 |
| read_reference | 60 | 0.0752 | 0.0450–0.1058 | 0.3000 | 0 |
