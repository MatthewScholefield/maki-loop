# maki-loop

A simple maki plugin that adds a `/loop [Instructions]` command. This command will run until the described goal / task is complete.

## Install

Requires maki 0.5.7+ with `maki.pack` support, Git, and the interactive TUI in build mode.

1. Add this to your **global** `~/.config/maki/init.lua` (create it if needed):

   ```lua
   maki.pack.add({
     "https://github.com/MatthewScholefield/maki-loop",
   })
   ```

   If you use the legacy `~/.maki/` config directory, edit its `init.lua` instead. Package installation is global; don't put this in a project's `.maki/init.lua`.

2. Start maki and accept the package installation and permission prompts. The plugin requests only `fs_read` and `fs_write` to save and restore per-project loop state. It does not request network, process, or environment access.
3. Use `/loop` in a build-mode session.

No copying files, extra `require`, or changes to your config's `plugin.toml` are needed. Maki loads `plugin/loop.lua` automatically, keeps the checkout in its managed data directory, and pins the installed commit in your global config's `pack-lock.json`.

If you previously installed by copying `lua/loop.lua`, remove the old `require("loop")` and copied file before installing the package to avoid duplicate registrations. Remove any permissions you added solely for that old installation, keeping grants needed by other plugins.

## Update and uninstall

To fetch and review an update:

```text
/packupdate maki-loop
```

Accept the proposed revision, then run `/reload` to use it. Updates are explicit; normal startup uses the locked commit. You can share `pack-lock.json` to reproduce the same revisions on another machine, but permission approval is local to each machine.

To uninstall, remove the source from `maki.pack.add`, run `/reload`, then run:

```text
/packdel maki-loop
```

Accept the removal prompt. Close any other maki processes still using the package if removal is refused.

## Usage

```text
/loop Finish the tasks in TASKS.md. Record progress there and verify each change.
```

The first iteration uses your current session. After each normally finished turn, the plugin opens a fresh session with the same model settings and repeats the original objective. No previous transcript or summary is passed along, so it's meant for you to keep your ongoing task state / progress within some markdown file you reference in your prompt.

The agent calls `loop_complete` when the whole objective is done.

- `/loop-status` — show progress and reported cost.
- `/loop-stop` — stop continuation without cancelling current work.
- `/loop-resume` — resume a stopped or interrupted loop in a fresh session.

Errors, cancellation, or conflicting user work interrupt continuation. Restarting or reloading requires an explicit resume.

Warning: **There is currently no iteration or spending limit**; use carefully.

## Tests

```sh
luajit tests/run.lua
```
