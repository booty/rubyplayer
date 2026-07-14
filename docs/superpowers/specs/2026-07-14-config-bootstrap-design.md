# User Config Bootstrap Design

## Goal

Install a useful executable user configuration automatically without confusing
it with rubyplayer's loader source or risking existing user changes.

## Files and Naming

- Keep `lib/rubyplayer/config.rb` as application loader code.
- Ship version-controlled example as `examples/config.rb`.
- Install user-owned source at `~/.config/rubyplayer/config.rb`.
- Keep last-known-good source at `~/.config/rubyplayer/config-previous.rb`.
- Do not add user filenames to repository `.gitignore`; both user files live
  outside repository.

## Bootstrap Order

Before initial load and whenever primary file disappears during hot reload:

1. If primary config exists, leave it untouched.
2. If primary is missing and previous exists, restore exact previous source.
3. If both user files are missing, install exact packaged example source.
4. Evaluate restored/installed primary through existing transactional loader.
5. Successful evaluation refreshes `config-previous.rb` through existing path.

An invalid previous file remains subject to existing fatal startup or nonfatal
hot-reload behavior. Missing/unreadable packaged example raises `ConfigError`
with source path.

## Atomicity

Bootstrap writes a complete temporary file beside destination, sets user-only
permissions, and creates destination with an exclusive hard link. A concurrent
process that wins destination race is never overwritten. Temporary file is
always removed.

## Example Content

`examples/config.rb` is valid and immediately runnable, but leaves settings at
built-in defaults. Common overrides, keymap maps, backend maps, and styled track
formatters appear as commented examples. This avoids pinning every current
default and allows future default changes to reach existing users.

Header states:

- File is executable Ruby.
- User should edit installed copy, not packaged example.
- Rubyplayer never overwrites existing primary config.
- Deleting primary restores last-known-good source when available.

## Testing

Cover first-run sample installation, exact source copy, previous restoration,
existing-primary preservation, hot-reload restoration, missing sample errors,
exclusive creation behavior, and full suite regression.

## Documentation

README documents automatic install, sample location, recovery precedence, why
`.gitignore` entries are unnecessary, and how to intentionally reset config
(remove both primary and previous before restart).
