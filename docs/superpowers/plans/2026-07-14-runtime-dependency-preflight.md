# Runtime Dependency Preflight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fail before TUI startup when any supported runtime dependency is missing and print deduplicated Homebrew/build remediation commands.

**Architecture:** A standalone `RubyPlayer::RuntimeDependencies` service probes commands, FFI dynamic libraries, and bundled native shim without loading UI/audio. `bin/rubyplayer` invokes it before requiring `rubyplayer/ui/app`; backend FFI bindings reuse its library candidate constants so checks and runtime loading cannot drift.

**Tech Stack:** Ruby 4, FFI, Minitest, Open3, Homebrew-oriented macOS diagnostics

## Global Constraints

- Check `libgme`, `libopenmpt`, `sox`, `ffmpeg`, `ffprobe`, `bsdtar`, and `lib/rubyplayer/native/librp_audio.dylib`.
- Treat all supported playback dependencies as mandatory at startup.
- Aggregate every missing dependency into one diagnostic.
- Print each Homebrew formula once.
- Exit nonzero before UI/audio initialization.
- Keep normal startup and TUI UX unchanged when checks pass.

---

### Task 1: Runtime Dependency Service

**Files:**
- Create: `lib/rubyplayer/runtime_dependencies.rb`
- Create: `test/runtime_dependencies_test.rb`

**Interfaces:**
- Produces: `RubyPlayer::RuntimeDependencies.new(...).check`
- Produces: `RubyPlayer::RuntimeDependencies.verify!(err: $stderr)`
- Produces: `RubyPlayer::RuntimeDependencies::MissingError`
- Produces: `GME_LIBRARY_CANDIDATES` and `OPENMPT_LIBRARY_CANDIDATES`

- [ ] **Step 1: Write failing service tests**

Cover successful checks, aggregated missing names, formula deduplication, native-shim build instruction, and probe exceptions. Inject probes instead of depending on host installation:

```ruby
checker = RubyPlayer::RuntimeDependencies.new(
  executable_probe: ->(name) { name != "sox" },
  library_probe: ->(candidates) { candidates != RubyPlayer::RuntimeDependencies::GME_LIBRARY_CANDIDATES },
  file_probe: ->(_path) { true },
)

error = assert_raises(RubyPlayer::RuntimeDependencies::MissingError) { checker.verify! }
assert_includes error.message, "- libgme"
assert_includes error.message, "- sox"
assert_includes error.message, "brew install libgme sox"
```

- [ ] **Step 2: Verify tests fail for missing class**

Run: `mise exec -- bundle exec ruby -Itest test/runtime_dependencies_test.rb`

Expected: FAIL with `LoadError` for `rubyplayer/runtime_dependencies`.

- [ ] **Step 3: Implement immutable dependency specifications**

Define command specs and library candidates:

```ruby
GME_LIBRARY_CANDIDATES = ["gme", "libgme.dylib", "/opt/homebrew/lib/libgme.dylib"].freeze
OPENMPT_LIBRARY_CANDIDATES = ["openmpt", "libopenmpt.dylib",
                              "/opt/homebrew/lib/libopenmpt.dylib"].freeze

COMMANDS = {
  "sox" => "sox",
  "ffmpeg" => "ffmpeg",
  "ffprobe" => "ffmpeg",
  "bsdtar" => "libarchive",
}.freeze
```

Default executable probe searches `ENV["PATH"]` for executable files. Default library probe attempts `FFI::DynamicLibrary.open` for each candidate and succeeds on first load. Default file probe uses `File.file?` for native shim.

`#check` returns missing names. `#verify!` raises `MissingError` with one diagnostic containing sorted/deterministic missing entries, deduplicated formula names, and `bundle exec rake compile` when shim is absent.

- [ ] **Step 4: Document probe rationale inline**

Explain why preflight loads no UI/audio, why probing uses backend candidate names instead of `brew list`, and why probe exceptions count as missing installation state.

- [ ] **Step 5: Run focused tests**

Run: `mise exec -- bundle exec ruby -Itest test/runtime_dependencies_test.rb`

Expected: all runtime dependency tests pass.

- [ ] **Step 6: Commit service**

```bash
git add lib/rubyplayer/runtime_dependencies.rb test/runtime_dependencies_test.rb
git commit -m "Add runtime dependency preflight"
```

---

### Task 2: Fail-Fast Entrypoint Wiring

**Files:**
- Modify: `bin/rubyplayer`
- Modify: `lib/rubyplayer/backends/gme.rb`
- Modify: `lib/rubyplayer/backends/openmpt.rb`
- Create: `test/startup_preflight_test.rb`

**Interfaces:**
- Consumes: `RubyPlayer::RuntimeDependencies.verify!`
- Consumes: shared FFI library candidate constants

- [ ] **Step 1: Write failing subprocess test**

Create a temporary `RUBYOPT` preloader that requires `runtime_dependencies` and overrides `verify!` to raise a sentinel `MissingError`. Execute `bin/rubyplayer` with `Open3.capture3` and assert exit status `1`, sentinel diagnostic on stderr, and no crash backtrace.

```ruby
env = { "RUBYOPT" => "-r#{override_path}" }
_stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, BIN)
assert_equal 1, status.exitstatus
assert_includes stderr, "sentinel dependency failure"
refute_includes stderr, "backtrace"
```

- [ ] **Step 2: Verify subprocess test fails**

Run: `mise exec -- bundle exec ruby -Itest test/startup_preflight_test.rb`

Expected: FAIL because entrypoint does not invoke preflight.

- [ ] **Step 3: Run preflight before UI require**

Restructure `bin/rubyplayer` in this order:

```ruby
require "rubyplayer/runtime_dependencies"

begin
  RubyPlayer::RuntimeDependencies.verify!
rescue RubyPlayer::RuntimeDependencies::MissingError => e
  warn e.message
  exit 1
end

require "rubyplayer"
require "rubyplayer/ui/app"
```

Keep existing application exception logging around `App.new(...).run` only.

- [ ] **Step 4: Share library candidates with FFI backends**

Require `runtime_dependencies` from `gme.rb` and `openmpt.rb`, then replace duplicated `ffi_lib` arrays with `RuntimeDependencies::GME_LIBRARY_CANDIDATES` and `RuntimeDependencies::OPENMPT_LIBRARY_CANDIDATES`.

- [ ] **Step 5: Add inline ordering documentation**

Explain that dependency failure must happen before `ui/app` loads `AudioOutput`, because that require immediately opens bundled native dylib and would otherwise produce raw FFI errors first.

- [ ] **Step 6: Run focused and backend tests**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/startup_preflight_test.rb
mise exec -- bundle exec ruby -Itest test/registry_test.rb
mise exec -- bundle exec ruby -Itest test/gme_test.rb
mise exec -- bundle exec ruby -Itest test/openmpt_test.rb
```

Expected: all tests pass.

- [ ] **Step 7: Commit entrypoint wiring**

```bash
git add bin/rubyplayer lib/rubyplayer/backends/gme.rb lib/rubyplayer/backends/openmpt.rb test/startup_preflight_test.rb
git commit -m "Fail fast on missing runtime dependencies"
```

---

### Task 3: Installation Documentation and Verification

**Files:**
- Modify: `README.md`

**Interfaces:**
- Documents: startup requirements and remediation emitted by preflight

- [ ] **Step 1: Update README installation commands**

Change Homebrew setup to:

```bash
brew install libgme libopenmpt sox ffmpeg
```

Document `bsdtar` as macOS-provided with `brew install libarchive` fallback. Explain that startup checks all runtime dependencies and that missing native shim requires `bundle exec rake compile`.

- [ ] **Step 2: Run real preflight**

Run:

```bash
mise exec -- bundle exec ruby -Ilib -rrubyplayer/runtime_dependencies -e 'RubyPlayer::RuntimeDependencies.verify!; puts "preflight: ok"'
```

Expected: `preflight: ok` on configured development machine.

- [ ] **Step 3: Run full verification**

Run:

```bash
mise exec -- bundle exec rake test
git diff --check
```

Expected: 0 failures, 0 errors, clean diff check.

- [ ] **Step 4: Commit documentation**

```bash
git add README.md
git commit -m "Document runtime dependency setup"
```
