# Config upsert patterns

Read this reference when auditing an in-file `KEY=VALUE` upsert in `/etc/forge-lite/<domain>.conf`, `.env`, or another sourceable config. Verify current callers before treating these source facts as timeless.

Forge-lite has at least three coexisting upsert helpers. Each is idempotent for its intended inputs: replace with `sed` when the key exists, otherwise append, so reruns do not accumulate duplicate keys.

1. `config_upsert` in `cli/forge-lite` uses `grep -qF "${key}="` plus `grep -q "^${key}="`, then escapes the value with `sed_escape_value`.
2. `update_site_config` in `cli/forge-lite-auth` uses one anchored `grep -q "^${key}="`, does not escape the value, and currently writes only literal `true` or `false`.
3. `_site_config_set` in `cli/forge-lite-reverb` models the second helper: one anchored key check, no value escaping, and literal `true` or `false` values.

## Confirmed-safe boundary

For fixed identifier keys without regular-expression metacharacters and literal `true`/`false` values, one anchored `^${key}=` check is sufficient and idempotent. Do not report the missing fixed-string pre-check as a finding. The extra `grep -qF` in `config_upsert` adds no material protection for these keys because the anchored match already implies the substring match.

Value escaping matters when a helper accepts arbitrary values such as `DEPLOY_REPO` URLs or `ALIASES`. The unescaped `sed` used by the boolean-only helpers becomes unsafe if a future caller passes values containing `|`, `&`, or `\`.

## Audit decision

For each upsert, verify both predicates:

1. The key check is anchored at the beginning of the line.
2. The value is a fixed safe token, or it is escaped for the selected `sed` delimiter and replacement syntax.

If both hold, record the upsert as guarded and do not manufacture a finding. If arbitrary user input reaches an unescaped boolean-only helper, report that concrete caller and second-run/file-corruption consequence; do not flag the helper speculatively while every caller remains fixed-value.
