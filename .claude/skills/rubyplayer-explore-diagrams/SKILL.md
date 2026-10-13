---
name: rubyplayer-explore-diagrams
description: Use when asked to diagram, map, or visually explore one or more Ruby files in this repo — renders a stacked SVG per file (cross-file relationships over internals) into /tmp without touching the repo.
argument-hint: <file> [file ...]
---

# Explore diagrams

Code-exploration tool. For each input file, write two Mermaid diagrams,
render them, and stack them into one SVG under `/tmp`:

1. **Relationships to other files**: who calls into this file from outside,
   and what this file calls outside itself.
2. **Internals**: how the file's own pieces relate.

## Hard rule: the repo stays untouched

Write only under the run's `/tmp` output directory. No edits to repo files,
no generated files in the repo, no git writes, no formatters or `--fix`
linters. Reading the repo (`rg`, `Read`, Serena, `git log`/`git show`) is fine.

## Tools

- Renderer: the `jbootz-mermaid-diagrams` skill's
  `~/.claude/skills/jbootz-mermaid-diagrams/scripts/render.sh`. Load that skill
  for its troubleshooting rules (parse errors, Chromium launch failures).
- `svg` needs `mmdc`; the optional ASCII step needs `mermaid-ascii`. If the
  renderer exits 127, stop and name the missing tool; never hand-draw.
- Stacker: `ruby <this-skill-dir>/scripts/stack_svgs.rb` (stdlib only; run with
  plain `ruby`, not `bundle exec`).

## Workflow

### 1. Set up output

```sh
OUT=$(mktemp -d /tmp/rubyplayer-explore-diagrams.XXXXXX)
```

One subdirectory per input file, named from its path under `lib/rubyplayer/`
with `/` replaced by `__` and `.rb` dropped (for example
`playback_engine__chip_state`). Each holds:

```
context.mmd  context.svg     # diagram 1
internals.mmd internals.svg  # diagram 2
legend.txt                   # numbered-edge key (plain text)
stacked.svg                  # 1 over 2, then legend — the deliverable
```

### 2. Research the file

- Read the whole file. Name its main class/module, public methods, private
  methods, ivars, constants, and value objects it builds.
- **Inbound callers**: `rg -n '\b(method_a|method_b)\b' lib bin exe` for each
  public method (and for private methods when the file is a mixin split out of
  a larger class: the host class calls them). Exclude `test/` but report the
  test-caller count in prose. Record the *calling method* for each hit (the
  nearest preceding `def`).
- **Outbound calls**: every receiver outside the file (ivars like `@audio`,
  constants like `ChipTimeline`, handles reached through `respond_to?`).
  Resolve each to its defining file and the methods called on it.
- Dynamic dispatch (`public_send`, `send`, `respond_to?` duck typing, blocks
  stored and called later) hides callers from `rg`. Note it in the legend as
  "duck-typed" or "dynamic" instead of guessing; Serena
  `find_referencing_symbols` can confirm static references.

### 3. Write diagram 1 — `context.mmd`

`flowchart TD`. The subject file is one node; callers point into it, callees
hang below it. One node per external file or class, grouped so the diagram
stays under ~8 nodes (for example "Native handles" for several backends).

Edge labels are short and numbered (`1 getters`, `3 snapshots, RAM`). Exact
method names go in `legend.txt`, one numbered entry per edge, with the file
and calling method:

```
1 getters, ui/app.rb: spc_live (handle_spc_mute_key), chip_live (update_chip_live)
2 lifecycle hooks, playback_engine.rb: pump -> capture_chip_state; handle_seek -> reset_chip_state
```

### 4. Write diagram 2 — `internals.mmd`

Pick the type that fits the file, not a fixed template:

| File shape | Diagram |
| --- | --- |
| Owns state, collections, value objects | `erDiagram` (add `direction TB`) |
| Class hierarchy, mixins, interfaces | `classDiagram` |
| Lifecycle, modes, playback states | `stateDiagram-v2` |
| Pipeline or branched control flow | `flowchart TD` |
| Ordered calls between collaborators | `sequenceDiagram` |

Use real names (ivars, methods, classes). If the file is trivial (a
`Data.define`, FFI `attach_function` list, constants only), skip diagram 2
and say why; the stack then holds diagram 1 alone.

### 5. Stay compatible with the ASCII renderer

The user may ask for terminal renders later, so write Mermaid that
`mermaid-ascii` also handles:

- No `<br>` and no quoted edge labels in flowcharts (they render literally).
  Quoted relationship labels in `erDiagram` are fine.
- Short labels; keep each terminal render under 150 columns.
- In vertical flowchart edges, the line is drawn through the label's middle
  character; a label whose middle character is a space shows a stray `│`.

### 6. Render and stack

```sh
R=~/.claude/skills/jbootz-mermaid-diagrams/scripts/render.sh
$R svg "$DIR/context.mmd" "$DIR/context"
$R svg "$DIR/internals.mmd" "$DIR/internals"
ruby <skill-dir>/scripts/stack_svgs.rb --out "$DIR/stacked.svg" \
  --title "lib/rubyplayer/<path>.rb @ $(git rev-parse --short HEAD)" \
  --legend "$DIR/legend.txt" \
  "1. Relationships to other files::$DIR/context.svg" \
  "2. Internals::$DIR/internals.svg"
```

Fix any `Parse error` in the `.mmd` and re-render. The commit in the title
records what code the diagram describes; append ` (uncommitted changes)` when
`git status --porcelain -- <file>` is non-empty.

### 7. Report

For each input file, print `file://` links (clickable in the terminal):

```
lib/rubyplayer/playback_engine/chip_state.rb
  stacked:   file:///tmp/rubyplayer-explore-diagrams.XXXXXX/playback_engine__chip_state/stacked.svg
  sources:   file:///tmp/.../context.mmd, file:///tmp/.../internals.mmd
```

Add 2–4 bullets on what the diagrams show that the code doesn't make obvious
(hidden coupling, a single caller, duck-typed seams). Mention `open <path>`
for opening the SVG in the default viewer.

### 8. Offer the terminal render

Ask with `AskUserQuestion` whether to show ASCII/Unicode renders in chat,
with options: both diagrams, diagram 1 only, diagram 2 only, no. On yes, run
`$R text <file>.mmd` for each chosen diagram and paste its output verbatim in
a fenced code block in your reply; tool output is not shown to the user. If a
render exceeds 150 columns or fails in `mermaid-ascii`, say so and point to
the SVG instead of trimming the diagram.
