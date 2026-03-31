# Contributing

## Project Structure

```
claude-vm              CLI entry point (command dispatch)
lib/
  config.sh            Config loading, flavor registry, path helpers
  build.sh             Base image download and provisioning
  cloud-init.sh        Cloud-init generation (flavor-dispatched)
  launch.sh            VM launch, SSH connection, config sync
  shutdown.sh          Graceful shutdown with state preservation
  snapshot.sh          Linked snapshot management
  virtiofs.sh          virtiofsd and guest mount management
  ssh.sh               SSH key management and connectivity
  ui.sh                Spinner, log capture, status output
  resume.sh            VM state save/load for fast resume
  wait-ready.sh        SSH readiness polling
  boot-timer.sh        Boot performance measurement
  claude-code.sh       Claude Code verification and credentials
  qemu-opts.sh         QEMU argument builders
tests/
  test_*.sh            Test scripts (run directly with bash)
docs/
  architecture.md      System design and internals
  usage.md             CLI reference with examples
  contributing.md      This file
```

## Conventions

### Shell

- All scripts use `#!/usr/bin/env bash` and `set -euo pipefail`.
- Functions are `snake_case`. Private/internal functions are prefixed with `_` (e.g., `_build_ssh_cmd`).
- Global constants are `UPPER_SNAKE_CASE`.
- Local variables are declared with `local` at the top of each function.
- Quote all variable expansions: `"$var"`, `"${array[@]}"`.
- Use `[[ ]]` for conditionals, `(( ))` for arithmetic.

### Modules

- Each `lib/*.sh` file sources its own dependencies at the top.
- Modules are loaded via `source "$SCRIPT_DIR/..."` -- no circular dependencies.
- Functions that set state for the caller use a named global (e.g., `_ssh_cmd` array from `_build_ssh_cmd`).
- Functions that create subprocesses store PIDs in `$run_dir/*.pid`.

### Configuration

- New config keys go in `lib/config.sh`: add a `DEFAULT_*` constant, handle in `load_config`, add validation in `set_config_value`, and add to the `get` case in `claude-vm`.
- Config keys are always validated before use. Invalid values produce a clear error and exit.

### Flavors

- Flavor data lives in the associative arrays in `lib/config.sh` (`FLAVOR_IMAGE_URL`, `FLAVOR_IMAGE_NAME`, `FLAVOR_PKG_FAMILY`).
- Cloud-init differences are handled by the `_cloud_init_*` helper functions in `lib/cloud-init.sh`, dispatched by flavor name.
- Adding a new flavor means: add entries to the three arrays, add cases to each `_cloud_init_*` function.

### UI

- User-facing output during launch/shutdown goes through `lib/ui.sh`.
- Use `ui_phase "message" function args...` to wrap any operation that might produce output.
- Use `ui_info`, `ui_warn`, `ui_error` for standalone messages.
- Never `echo` directly in launch/shutdown code paths -- use the UI functions.
- Technical details go to the log file, not the terminal.

### Error Handling

- Functions return non-zero on failure. Callers decide whether to abort or continue.
- Error messages go to stderr (`>&2`).
- Cleanup of runtime artifacts (PID files, sockets) happens in dedicated `_cleanup_*` functions.
- The snapshot file is **never** deleted during shutdown or error recovery. Only `reset` and `destroy` remove snapshots.

### Testing

- Tests are standalone bash scripts in `tests/`. Run with `bash tests/test_*.sh`.
- Tests that need QEMU/qemu-img will skip or fail gracefully in environments without them.
- Tests create their own temp directories and clean up after themselves.
- Test functions follow the pattern: setup, action, assert, teardown.
- Use descriptive assertion messages that make failures self-explanatory.

## Adding a New Command

1. Add a `cmd_<name>` function in `claude-vm`.
2. Add the case to `main()` dispatch.
3. Add usage line to the `usage()` help text.
4. If the command has complex logic, put it in a `lib/*.sh` module and source it.

## Adding a New Flavor

1. In `lib/config.sh`, add entries to `FLAVOR_IMAGE_URL`, `FLAVOR_IMAGE_NAME`, and `FLAVOR_PKG_FAMILY`.
2. In `lib/cloud-init.sh`, add cases to `_cloud_init_packages`, `_cloud_init_nodejs_runcmd`, `_cloud_init_gh_runcmd`, `_cloud_init_cleanup_runcmd`, and `_cloud_init_ssh_service`.
3. Update `docs/usage.md` flavor table.
4. Test with `claude-vm build --flavor <name>`.

## Running Tests

```bash
# Run all tests
for t in tests/test_*.sh; do bash "$t"; done

# Run a specific test
bash tests/test_config.sh

# Tests that require QEMU (integration)
bash tests/test_snapshot_isolation.sh
bash tests/test_ssh_integration.sh
```

## Commit Messages

Follow the existing style: lowercase imperative subject line describing the change, blank line, then a body explaining **why** and what the key decisions were. Keep the subject under 72 characters.

```
add alpine flavor support

Alpine uses musl libc which breaks some Node.js native addons, so
this flavor is marked experimental. Uses apk instead of apt, and
OpenRC instead of systemd -- the cloud-init and virtiofs mount
setup needed different approaches for both.
```
