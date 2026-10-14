# Changelog

## 0.4.2
- The jar is back at `media/java/RealReset.jar`. In 0.4.1 it was under `media/java/server/`, and ZombieBuddy on a dedicated server skipped it as a "server-only mod", so the Java side never loaded. Players still do not need ZombieBuddy (no `require=` in mod.info); a player who has ZombieBuddy installed gets its normal one-time approval prompt for the jar.

## 0.4.1
- Players no longer need ZombieBuddy: removed `require=\ZombieBuddy` from mod.info and moved the jar to `media/java/server/` (ZombieBuddy skips that folder on game clients, so players are not asked to approve a Java mod and do not see "ZombieBuddy is not installed"). The server still needs the ZombieBuddy agent.

## 0.4.0
- RESET is now a queue. RESET NOW starts it and it works through the chunks in steps of up to 200 chunks per second, pausing by itself when the safety limit (3000 moves / 10 min, was 1000) is used up and carrying on when it frees. No more PLAN + RESET every 200 chunks (one queue holds up to 3000). Every step re-reads safehouses, protected zones and claims, so one made mid-run is respected. The button becomes CANCEL QUEUE while it runs; progress is sent every 20 s; the whole queue is one batch for RESTORE. It pauses if the starting admin goes offline. Chunks skipped for a nearby player or a loaded chunk are not retried; PLAN again later.
- RESTORE is a queue too: same steps, same pause at the safety limit, same CANCEL QUEUE button; no more 200-chunk rounds. The queue also only takes chunks that have a saved file, so never-saved chunks no longer use up the 3000 slots.
- Admin lock: while a RESET or RESTORE queue runs, every online admin's panel is told. PLAN is disabled and a "LOCKED: admin X is running ..." line shows progress. The panel stays readable, STATUS/REFRESH and SETTINGS still work, and any admin can press CANCEL QUEUE. It unlocks when the queue ends. (The server refuses a second operation anyway; this just makes it visible.)
- PLAN shows the safety-limit usage and says how long a big RESET will take. New Java call `RealReset_ceilingInfo`.
- Removed the MARK CHUNK button (restore works per batch; one chunk can still be put back by hand, see the README).
- Claimed vehicles are protected: chunks within 16 tiles of a vehicle claimed with Sunday Driver (SDVC) are skipped by PLAN, RESET and RESTORE. PLAN lists which claims caused skips. If SDVC's claim files exist but cannot be read, RESET refuses.
- Player warning: non-admin players get a small see-through notice (with an X, hides itself after ~15 s) when they enter a reset zone. Safehouses/protected areas never trigger it.
- In-game SETTINGS screen in the panel: tick the options, edit the warning wording, set the timings, TEST NOTICE to preview it, SAVE. Admin only, checked on the server.
- Settings are stored in `RealReset_Config.txt` (created on first start, reloaded every minute, also hand-editable): features on/off, wording, `warn_mode=everywhere` for a future full reset, cooldown, buffer size.
- STATUS shows the settings in effect. Tests added for claims and warnings (`tests/lua/claims_warn_mock.lua`).

## 0.3.0
- RESTORE: every RESET is saved as its own batch folder in the trash; list them, PLAN RESTORE, RESTORE NOW.
- Restore one chunk: MARK CHUNK, walk away, restore from the newest batch holding it.
- Restore skips protected zones/safehouses, chunks near players and loaded chunks; a regenerated file is moved aside, never overwritten. Same 10-minute PLAN rule and 200-chunk cap.
- Trash is kept 7 days / 20000 files by default (was 3 days / 2000).
- Panel: RESET / RESTORE modes, MARK CHUNK.
- Tests added under `tests/` (Java against fake game classes, Lua mocks).

## 0.2.3
- Panel shows the chunk (and tile) you are standing in, to match against trash file names `<chunkX>_<chunkY>_<time>.bin`.

## 0.2.2
- Output area scrolls (mouse wheel / scroll bar); the "Selected group" label no longer overlaps it.

## 0.2.1
- Group picker is now a scrollable list on the left (the dropdown snapped back to ALL in-game).

## 0.2.0
- Group picker: choose which zone group (the `group=` field in the AZR file, e.g. LV, MD, WP) to PLAN and RESET, or ALL.
- A PLAN is tied to its group; RESET refuses if your last PLAN was for a different group.
- STATUS lists each group and its zone count.
- A PLAN that finds nothing to move no longer unlocks RESET.

## 0.1.2
- World folder is resolved once per self-test and cached (no more repeated log lines / folder scans per chunk).

## 0.1.1
- World folder: also tries `Core.GameSaveWorld`, and `-Drealreset.world=<name>` overrides it (needed if a server has more than one save folder).

## 0.1.0 (first RealReset! build, from DrengrChunkTools v7)
- Renamed: mod id `RealReset`, Lua globals `RealReset_*`, trash folder `_realreset_trash`.
- Java: removed the permanent-delete fallback. A failed move is logged and the file is left alone.
- Java: default safety radius 8 chunks (floor 4); asks the server whether the chunk is loaded.
- Java: world save folder chosen by server name; refuses if it cannot tell which world.
- Java: hard rate ceiling (1000 moves / 10 min) because the functions are global Lua functions.
- Java: trash expires after 3 days and is capped at 2000 files (only files it created).
- Java: startup self-test; refuses to run if an essential game hook is missing.
- Lua: PLAN (dry run) is required within 10 minutes before RESET; per-run cap of 200 chunks.
- Lua: refuses RESET if the live safehouse list cannot be read.
- Lua: results are sent back to the admin's screen, including which players blocked chunks.
- Lua: own admin panel (right-click the ground as admin). Does not modify Admin Zone Reset.
