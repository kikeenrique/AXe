# AXe Batch Reference

Use this reference when generating or reviewing `axe batch` commands.

## Supported step commands
- `tap`
- `swipe`
- `gesture`
- `touch`
- `type`
- `button`
- `key`
- `key-sequence`
- `key-combo`
- `remote <up|down|left|right|select|menu|play-pause> [--count N] [--delay ms]` (tvOS simulators)
- `sleep <seconds>` (batch pseudo-step)
- `hinge <set <degrees>|open|close|half> [--duration <s>] [--no-wait]` (foldable simulators)
- `rotate <portrait|landscape|portrait-upside-down|landscape-flipped>`

`hinge` and `rotate` are barrier steps: earlier steps finish first, and later steps re-read display state and the accessibility tree (the cached snapshot from `--ax-cache perBatch` is dropped). `hinge sweep`, `hinge get` and `--json` are not available as steps.

## Batch flags
- `--udid <UDID>`: required simulator target.
- `--step "..."`: repeatable inline step source.
- `--file <path>`: read one step per line from file.
- `--stdin`: read one step per line from stdin.
- `--continue-on-error`: keep running after a failed step; report failures at end.
- `--ax-cache perBatch|perStep|none`: selector tap AX snapshot reuse policy.
- `--type-submission chunked|composite`: submission mode for `type` steps.
- `--type-chunk-size <n>`: chunk size when using chunked submission.
- `--tap-style automatic|simulator|physical`: default tap event style for tap steps.
- `--wait-timeout <seconds>`: maximum seconds to poll for selector-based elements before failing (0 = no waiting, default).
- `--poll-interval <seconds>`: seconds between accessibility tree polls when `--wait-timeout` is active (default 0.25).
- `--verbose`: enable detailed stderr logs for troubleshooting (default quiet output).

## Input rules
- Use exactly one source: `--step` OR `--file` OR `--stdin`.
- Empty lines are ignored.
- `#` comment lines are ignored in file/stdin input.
- Do not pass `--udid` inside step lines; keep it at batch command level.

## Example: inline steps
```bash
axe batch --udid SIMULATOR_UDID \
  --step "tap --id EmailField" \
  --step "type 'cam@example.com'" \
  --step "key 43" \
  --step "type 'super-secret'" \
  --step "key 40"
```

## Example: stdin steps
```bash
cat <<'EOF' | axe batch --udid SIMULATOR_UDID --stdin
tap --id EmailField
type 'cam@example.com'
key 43
type 'super-secret'
key 40
EOF
```

## Example: file steps
`login.steps`
```text
# login flow
tap --id EmailField
type 'cam@example.com'
key 43
type 'super-secret'
key 40
```

Run:
```bash
axe batch --udid SIMULATOR_UDID --file login.steps
```

## Example: explicit timing and policy
```bash
axe batch --udid SIMULATOR_UDID \
  --ax-cache perStep \
  --type-submission chunked \
  --type-chunk-size 150 \
  --continue-on-error \
  --step "tap --label Settings" \
  --step "sleep 0.5" \
  --step "tap --id SaveButton"
```

## Example: multi-screen flow with element waiting
```bash
axe batch --udid SIMULATOR_UDID \
  --wait-timeout 5 \
  --step "tap --id LoginButton" \
  --step "tap --id WelcomeMessage"
```

The second step polls for up to 5 seconds for `WelcomeMessage` to appear after the login tap triggers navigation.

## Example: toggling a setting switch
```bash
axe batch --udid SIMULATOR_UDID \
  --step "tap --label 'Weather Alerts'"
```

Batch selector taps share direct `axe tap` behavior. If the matched row or label contains exactly one UIKit `UISwitch` or SwiftUI `Toggle`/switch control, AXe taps that control's activation point. With default `--tap-style automatic`, switch/toggle activations use physical touch down/up and normal taps use simulator `tapAt`.

If label selectors are ambiguous and AXe reports no `AXUniqueId` values for matches, switch that step to coordinates (`tap -x/-y`). For coordinate taps that need physical touch, use `tap -x/-y --tap-style physical` or batch-level `--tap-style physical`.

## Foldable simulators (iPhone Duo)
- Display state is re-read at every step, so a fold during a `sleep` or element wait is picked up, and touch steps (`tap`, `swipe`, `gesture`, `touch`) go to the display that is active when the step runs.
- Coordinates are interface points of the active display as `axe screenshot` shows it; after a `hinge` or `rotate` step they refer to the new display or orientation. Selector taps resolve against the active display's windows only.
- Touch steps fail only when the active display cannot be determined, or when the inner display is active on the legacy Indigo input transport.
- `hinge` and `rotate` step argument errors, like other step errors, are reported with the parser's message.
- Check the result with `axe posture` and `axe screenshot` after the batch:

```bash
axe batch --udid SIMULATOR_UDID \
  --step "hinge open" \
  --step "tap --label Settings" \
  --step "sleep 1" \
  --step "hinge close" \
  --step "tap --label General"
```
