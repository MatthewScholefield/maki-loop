# maki-loop

A maki plugin that keeps working toward an objective across fresh sessions, without carrying an ever-growing conversation along.

## Setup

Requires maki 0.5.7+ and the interactive TUI in build mode.

Copy `lua/loop.lua` into your maki config's `lua/` directory, add `require("loop")` to `init.lua`, and enable `fs_read` and `fs_write` in the config's `plugin.toml`. Run `/reload` to load it.

## Usage

```text
/loop Finish the tasks in TASKS.md. Record progress there and verify each change.
```

The first iteration uses your current session. After each normally finished turn, the plugin opens a fresh session with the same model settings and repeats the original objective. No previous transcript or summary is passed along, so keep progress in project files and say where in your objective.

The agent calls `loop_complete` when the whole objective is done. Earlier sessions remain available.

- `/loop-status` — show progress and reported cost.
- `/loop-stop` — stop continuation without cancelling current work.
- `/loop-resume` — resume a stopped or interrupted loop in a fresh session.

Errors, cancellation, or conflicting user work interrupt continuation. Restarting or reloading requires an explicit resume.

**There is no iteration or spending limit, and progress isn't guaranteed.** Use a clear, verifiable objective and stop the loop if it gets stuck.

## Tests

```sh
luajit tests/run.lua
```

MIT licensed.
