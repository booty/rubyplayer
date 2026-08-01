# Aider skill bundle

`.aider-desk/skills/` is a mirror of `.agents/skills/`. It exists for Aider and other tools that discover skills through the `.aider-desk` path. Keep both trees synchronized; do not remove either tree.

`.agents/skills/` is canonical. `skills-lock.json` pins skill sources used there, so update or restore skills in `.agents/skills/` first. Do not edit the mirror by hand.

## Sync

Run from repository root. Preview changes first:

Before any sync, validate canonical source and every skill's non-empty
`SKILL.md`:

```sh
test -d .agents/skills || {
  echo "missing canonical skill directory: .agents/skills" >&2
  exit 1
}

skill_dirs="$(find .agents/skills -mindepth 1 -maxdepth 1 -type d -print)"
test -n "$skill_dirs" || {
  echo "canonical skill directory is empty: .agents/skills" >&2
  exit 1
}

while IFS= read -r skill_dir; do
  skill_file="$skill_dir/SKILL.md"
  test -s "$skill_file" || {
    echo "missing or empty canonical skill file: $skill_file" >&2
    exit 1
  }
done <<EOF
$skill_dirs
EOF
```

```sh
rsync -avn --delete .agents/skills/ .aider-desk/skills/
```

If preview matches intended changes, sync mirror:

```sh
rsync -a --delete .agents/skills/ .aider-desk/skills/
```

Verify exact synchronization:

```sh
diff -qr .agents/skills/ .aider-desk/skills/
```

Expected verification output: none. Do not change `skills-lock.json` during mirror sync.
