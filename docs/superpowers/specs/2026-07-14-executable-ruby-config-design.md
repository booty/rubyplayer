# Executable Ruby Configuration Design

## Goal

Replace TOML configuration and brace-based track templates with one executable
Ruby configuration file at `~/.config/rubyplayer/config.rb`. Every setting must
be configurable through a validated DSL. Track row formatters may use ordinary
Ruby control flow and return styled fragments, including theme colors, terminal
colors, and true-color hex values.

## Configuration Source

Rubyplayer starts from `RubyPlayer::DEFAULTS` and evaluates `config.rb` when it
exists. Missing `config.rb` is valid and leaves defaults active. TOML loading and
legacy format strings are removed; no compatibility layer is required.

Configuration uses an explicit object:

```ruby
RubyPlayer.configure do |config|
  config.ui.theme = "nord"
  config.audio.ring_buffer_ms = 750
  config.scanner.thread_count = 4
  config.backends[".foo"] = :ffmpeg
end
```

The evaluator provides a narrow `RubyPlayer.configure` facade backed by a fresh
builder. It avoids leaking application internals into the DSL namespace, but it
is not a security sandbox: `config.rb` is executable Ruby and has the user's full
process permissions. README documentation must state this prominently.

Known sections and settings expose method accessors. Dynamic map sections such
as `backends` and keymap scopes expose `[]`/`[]=`. Unknown method names fail with
the setting path and a nearest-name suggestion. A completed configuration is
validated before it can replace active data.

## Validation and Activation

Loading is transactional:

1. Deep-copy built-in defaults into a new builder.
2. Evaluate source against that builder.
3. Validate setting names, scalar types, ranges, map types, theme id, and
   formatter callability.
4. Freeze or otherwise detach resulting data from the temporary builder.
5. Replace active configuration only after all prior steps succeed.

Existing application reads remain `config["section", "setting"]`, limiting the
change outside configuration and formatting code. Settings whose consumers are
constructed only at startup remain restart-required. Existing live settings
(theme, keymap, and track formatting) continue updating after hot reload.

## Last-Known-Good Recovery

After every successful primary-file load, rubyplayer atomically writes the exact
validated `config.rb` source to sibling `config-previous.rb`. It writes a
temporary file in the same directory and renames it, preventing partial backup
files after interruption. Loading `config-previous.rb` never overwrites itself.

Startup behavior:

- Missing `config.rb`: start with defaults.
- Valid `config.rb`: activate it and refresh `config-previous.rb`.
- Invalid `config.rb`, valid `config-previous.rb`: activate previous config and
  display the primary exception in a modal after UI initialization.
- Invalid `config.rb` with missing or invalid `config-previous.rb`: raise a
  combined configuration error and exit before normal application startup.

Hot-reload behavior:

- Valid changed file: activate it, update `config-previous.rb`, clear any config
  error modal, and show the existing reload status message.
- Invalid changed file: retain current in-memory configuration and display a
  modal containing file, exception class, message, and useful source location.
- A failed file's observed signature is recorded so it is not retried every
  frame. Saving the file again triggers another attempt.
- Hot-reload errors never terminate a running app because its active in-memory
  configuration is already last-known-good.

The error modal captures input. Escape or Enter dismisses it; a later successful
reload also dismisses it automatically.

## Theme Picker Persistence

Theme selection remains persistent without attempting to parse arbitrary Ruby.
`ConfigStore#persist_theme` maintains one clearly marked, generated block at the
end of `config.rb`:

```ruby
# rubyplayer: managed theme begin
RubyPlayer.configure { |config| config.ui.theme = "nord" }
# rubyplayer: managed theme end
```

Updating a theme replaces only that marked block and leaves user code and
comments untouched. Because the block is last, the interactive selection wins
over earlier theme assignments, matching current picker behavior. The rewritten
file is evaluated transactionally before backup activation; failures preserve
the previous in-memory configuration and surface through the same modal path.

## Styled Track Formatters

Two settings replace legacy strings:

```ruby
RubyPlayer.configure do |config|
  config.ui.format_track_grouped = lambda do |track, fmt|
    fmt.line(
      fmt.number(track.track_number),
      fmt.text(track.title, bold: true),
      fmt.duration(track.duration_ms, fg: :text_muted),
      fmt.text(track.artist, italic: true) unless track.artist == fmt.album_artist,
      fmt.stars(track.rating, fg: :yellow)
    )
  end

  config.ui.format_track_ungrouped = lambda do |track, fmt|
    fmt.line(
      fmt.text(track.album),
      fmt.number(track.track_number),
      fmt.text(track.title, bold: true),
      fmt.duration(track.duration_ms, fg: :text_muted),
      fmt.text(track.artist, italic: true),
      fmt.stars(track.rating, fg: :yellow)
    )
  end
end
```

Formatter helpers return immutable fragments. `fmt.line` removes nil and empty
values, flattens nested fragment arrays, and inserts one unstyled space between
surviving values. A formatter may return a string, one fragment, or an array of
either. Supported helpers:

- `text(value, **style)` converts non-empty values to fragments.
- `number(value, width: 2, **style)` zero-pads numeric track values.
- `duration(milliseconds, **style)` renders `M:SS`.
- `stars(rating, **style)` uses configured star glyph.
- `line(*parts, separator: " ")` joins conditional pieces.

Supported style keys are `fg`, `bg`, `bold`, `italic`, `underline`, and `dim`.
Colors may be:

- Theme roles such as `:text`, `:text_muted`, `:primary`, and `:accent`.
- ANSI names such as `:yellow`, `:bright_blue`, and `:black`.
- True-color strings such as `"#ffaa00"`.

Unknown style keys, unknown theme roles, malformed hex colors, and unsupported
formatter return values raise configuration/formatting errors with context.

Selection foreground and background override formatter foreground/background
for readability. Existing selected-row emphasis remains. Formatter attributes
such as bold, italic, underline, and dim remain active under selection.

## Rendering Changes

Replace `Template` with a focused formatter/context component. TracksPane stores
the two formatter callables and builds normalized styled segments when rows are
produced. It resolves theme-role colors at render time so changing theme does not
require rebuilding formatter output. Focus sounds retain their existing simple
title rows.

Screen cells gain underline and dim flags. ANSI diffing includes those flags,
and SGR emission uses codes 4 and 2 respectively. Existing bold, italic, named
color, and hex-color behavior remains unchanged.

## Documentation

`README.md` will contain:

- Config path, execution warning, loading order, backup/fallback behavior, and
  hot-reload modal behavior.
- Complete DSL setting reference covering every default section.
- Restart-required versus live-reloaded settings.
- Formatter inputs, helpers, return shapes, style keys, and color forms.
- Minimal, colorful, compact, metadata-heavy, and conditional formatter presets.
- Keymap and backend override examples.
- Theme picker's generated block behavior.

Repository architecture notes will describe the Ruby loader and styled formatter
instead of TOML and `Template`. The `tomlrb` dependency will be removed.

## Testing

Tests cover:

- Defaults when `config.rb` is absent.
- Overrides for every section shape, nested maps, unknown names, and validation.
- Arbitrary Ruby conditionals inside formatters.
- Atomic last-known-good refresh and startup fallback.
- Fatal startup when both primary and previous files fail.
- Transactional hot reload retaining active data after syntax/runtime/validation
  errors, then recovering after a corrected save.
- Config error modal contents, input capture, dismissal, and automatic clearing.
- Managed theme block creation/replacement without damaging user content.
- Fragment normalization, helper formatting, color validation, theme-role
  resolution, selected-row precedence, and all text attributes.
- Removal of TOML behavior and dependency references.

Run focused configuration, formatter, screen, TracksPane, and App tests first,
then the complete Minitest suite.
