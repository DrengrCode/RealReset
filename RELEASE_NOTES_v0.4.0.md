# RealReset! v0.4.0 (beta)

Regenerate parts of a Project Zomboid B42 server's world live, and undo it. Reads your Admin Zone Reset zones.

## Highlights
- **Queued RESET and RESTORE**: one click works through up to 3000 chunks, pauses at the safety limit, resumes by itself, cancellable.
- **Admin lock**: while a queue runs, every admin's panel shows who is running it and disables PLAN.
- **Claimed vehicles protected** (Sunday Driver): chunks within 16 tiles of a claimed car are skipped.
- **Player warning**: a small dismissible notice when players walk into a reset zone. Wording editable in game.
- **In-game SETTINGS screen**, stored in `Zomboid/Lua/RealReset_Config.txt`.
- Safety-limit readout in PLAN; progress reports during a queue.

## Requirements
Dedicated server with [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy), Admin Zone Reset, B42 (tested 42.21). Players need the mod in `Mods=` (it does nothing on their PC).

## Install
Unpack `RealReset_v0.4.0.zip` into the server's mods folder, add `RealReset` to `Mods=`, check the log for `READY`.
**Back up `map/` and `vehicles.db` first.** See the README's "First run on a live server".

## Known limits
- Not yet proven on a busy live server; the two-admin lock is mock-tested only.
- Chunks skipped for a nearby player or a loaded chunk are not retried: PLAN again later.
- A claimed car in the middle of a zone keeps that patch from resetting.
- Unclaimed cars in reset chunks are removed (they return on RESTORE).

Full history in `CHANGELOG.md`. MIT licence.
