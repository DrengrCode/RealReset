# RealReset! v0.4.2 (beta)

Regenerate parts of a Project Zomboid B42 server's world live, and undo it. Reads your Admin Zone Reset zones.

## What's new since 0.4.0
- **Players no longer need ZombieBuddy.** RealReset! no longer lists ZombieBuddy as a required mod, so players don't download it or see "ZombieBuddy is not installed". Only the server needs the ZombieBuddy agent. (A player who already has ZombieBuddy installed gets its normal one-time "approve this Java mod" prompt and can decline.)
- Packaging fixes only. The reset/restore code is unchanged from 0.4.0.

## Highlights (from 0.4.0)
- **Queued RESET and RESTORE**: one click works through up to 3000 chunks, pauses at the safety limit, resumes by itself, cancellable.
- **Admin lock**: while a queue runs, every admin's panel shows who is running it and disables PLAN.
- **Claimed vehicles protected** (Sunday Driver): chunks within 16 tiles of a claimed car are skipped.
- **Player warning**: a small dismissible notice when players walk into a reset zone. Wording editable in game.
- **In-game SETTINGS screen**, stored in `Zomboid/Lua/RealReset_Config.txt`.

## Requirements
Dedicated server with the [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) agent, Admin Zone Reset, B42 (tested 42.21). Players need the mod in `Mods=` (it downloads from the Workshop and does nothing on their PC). Do not add the ZombieBuddy *mod* to `Mods=` just for RealReset!.

## Install
Unpack `RealReset_v0.4.2.zip` into the server's mods folder, add `RealReset` to `Mods=`, check the log for `RealReset 0.4.2 ... READY`.
**Back up `map/` and `vehicles.db` first.** See the README's "First run on a live server".

## Known limits
- Not yet proven on a busy live server; the two-admin lock is mock-tested only.
- Chunks skipped for a nearby player or a loaded chunk are not retried: PLAN again later.
- A claimed car in the middle of a zone keeps that patch from resetting.
- Unclaimed cars in reset chunks are removed (they return on RESTORE).

Full history in `CHANGELOG.md`. MIT licence.
