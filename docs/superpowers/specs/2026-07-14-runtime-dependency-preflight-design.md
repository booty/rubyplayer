# Runtime Dependency Preflight Design

## Goal

Fail before terminal setup when rubyplayer cannot access required runtime dependencies. Report every missing dependency together and provide exact Homebrew or project build commands needed to fix them.

## Scope

Startup requires all supported playback paths, including format-specific FFmpeg support. Preflight checks:

- Dynamic libraries: `libgme`, `libopenmpt`
- Executables: `sox`, `ffmpeg`, `ffprobe`, `bsdtar`
- Bundled native audio shim: `lib/rubyplayer/native/librp_audio.dylib`

Ruby gems remain Bundler's responsibility. `clang` remains build-time-only and is not checked during normal startup.

## Architecture

Add `RubyPlayer::RuntimeDependencies`, loadable without initializing UI or audio. It owns immutable dependency specifications and accepts injectable probes for tests.

`bin/rubyplayer` loads and runs preflight before requiring `rubyplayer/ui/app`. Successful checks continue unchanged. Failure writes one diagnostic to stderr and exits nonzero before TUI terminal ownership begins.

Executable probing searches `PATH` for executable files. Dynamic-library probing attempts the same candidate names used by FFI backends, including Homebrew Apple Silicon paths. Native-shim probing checks its repository-relative file path.

## Diagnostics

Report missing dependency names, then deduplicated commands:

```text
rubyplayer cannot start; missing runtime dependencies:
- libgme
- sox

Install missing Homebrew packages:
  brew install libgme sox
```

Formula mapping:

- `libgme` → `libgme`
- `libopenmpt` → `libopenmpt`
- `sox` → `sox`
- `ffmpeg`, `ffprobe` → `ffmpeg`
- `bsdtar` → `libarchive`

Missing native shim adds:

```text
Build rubyplayer's native audio shim:
  bundle exec rake compile
```

When several dependencies share a formula, print that formula once.

## Error Handling

Probe failures count as missing dependencies rather than crashing preflight. Diagnostics contain no stack trace because missing dependencies are an expected installation problem. Unexpected application errors retain existing logging and re-raise behavior after preflight succeeds.

## Testing

Unit tests inject library, executable, and file probes to verify:

- success when every dependency exists
- aggregation of multiple missing dependencies
- Homebrew formula deduplication
- separate native-shim build instruction
- probe exceptions treated as missing

Entrypoint tests run `bin/rubyplayer` with a controlled preflight result and verify failure occurs before `RubyPlayer::UI::App` construction.

## Documentation

Update README requirements and setup command to include `sox` and `ffmpeg`. Explain startup preflight and native-shim remediation.
