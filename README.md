# RealReset!

Regenerate parts of your Project Zomboid (B42) world **while the server is running**, and put them back if you change your mind.

RealReset! reads the RESET zones you drew with [Admin Zone Reset](https://steamcommunity.com/sharedfiles/filedetails/?id=3793163790)
and, one chunk at a time, moves each chunk's save file into a trash folder. The next time that chunk loads, the game
rebuilds it from the base map. Safehouses and your PROTECTED zones are skipped.

**Status: beta (0.4.0).** Tested in game on B42.21 with a dedicated test server (resets and restores of 600+ chunks,
claimed-vehicle protection, settings, warning notice). Not yet proven on a busy live server, and the two-admin lock is only
tested in mocks. **Back up `Saves/Multiplayer/<server>/map` and `vehicles.db` before your first real run**, and start with one small group.

## Requirements
- A dedicated server where **you can add a Java agent** ([ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy)). Ask your host.
- Admin Zone Reset on the same server (RealReset! reads its synced zones file `AdminZoneReset_ServerZones.txt`).
- You are a server **admin** (access level `admin`). Everything is re-checked on the server.
- Every player who joins needs the mod too (a PZ rule for anything in `Mods=`). Publish it on the Workshop so it downloads automatically. It does nothing on a player's PC.

## Install
1. Unpack `RealReset_v0.4.0.zip` so the folder `RealReset` sits in the server's mods folder (and on your own PC to use the panel).
2. Add `RealReset` to `Mods=`.
3. Make sure ZombieBuddy is loaded on the server. The log should show `[RealReset] RealReset 0.4.0 | ... | READY`.

## First run on a live server
1. Stop the server. Back up `Saves/Multiplayer/<server>/map/` and `vehicles.db`.
2. Set ZombieBuddy to `policy=deny-new` and approve the RealReset jar once (see "About ZombieBuddy trust").
3. Install the mod, start the server, and look for the `READY` line in the log.
4. Open **SETTINGS**: check claimed-vehicle protection is on and the player warning is set how you want. SAVE.
5. Press **STATUS**: your zone groups and claim count should appear.
6. Pick one **small** group. PLAN, read what it skipped, RESET.
7. Walk the area: safehouses untouched, claimed cars still there, reset areas fresh. If anything looks wrong, RESTORE that batch.

## Use (in game, as admin)
Right-click the ground -> **RealReset! (chunk reset)**.

**RESET mode**
1. Pick a **group** on the left (the `group=` field of your AZR zones, or ALL).
2. **PLAN** changes nothing. It reports how many chunks would move and what was skipped (protected / player nearby / loaded).
3. **RESET NOW** asks you to confirm. It only works within 10 minutes of a PLAN *for the same group*. It then runs as a **queue**: steps of up to 200 chunks per second, pausing automatically when the safety limit (3000 chunk moves per 10 minutes) is used up and carrying on when it frees, up to 3000 chunks per reset. Progress appears in the panel; the button becomes **CANCEL QUEUE**. Every step re-checks safehouses, protected zones and claims. The whole queue is one batch for RESTORE. It pauses if you log out. Chunks skipped because a player was near or the chunk was loaded are not retried; PLAN again later.

**RESTORE mode** (undo)
1. Every RESET is saved as its own **batch** in the trash. Switch to RESTORE to list them, newest first.
2. Pick a batch, **PLAN RESTORE**, then **RESTORE NOW**.
3. A batch is restored whole. To get back a single chunk, use the manual undo below.
4. While any admin's queue runs, every admin's panel locks planning (you can still read it, refresh, change settings and cancel) and shows who is running it. RESTORE runs as a queue too (same steps, safety-limit pause and CANCEL QUEUE button as RESET).
5. Restore skips protected zones, safehouses, chunks near players and loaded chunks. If the game already regenerated a chunk, that newer file is moved aside into the batch's `replaced` folder, never overwritten.

The panel also shows **Here: chunk x,y (tile x,y)**, which matches the numbers in trash file names.

## Vehicles, claims and the player warning
- **Cars in reset chunks are removed** (they live in the chunk data) and come back on RESTORE. Unclaimed wrecks are cleaned up like everything else.
- **Claimed vehicles are protected** if you use Sunday Driver (SDVC): RealReset! reads its claim files (`Zomboid/Lua/SDVC_Claims/`) and skips any chunk within 16 tiles of a claimed vehicle (SDVC saves a car's position when it has moved 10+ tiles). PLAN lists the claims that caused skips. If those files exist but cannot be read, RESET refuses. Expired claims still protect until SDVC removes them. A claimed car left in the middle of a zone keeps that patch from resetting until the claim is released.
- **Player warning**: non-admin players see a small dismissible notice when they walk into a reset zone (once per entry, with a cooldown). Safehouses and protected areas never trigger it.
- **Settings**: change them in game with the panel's **SETTINGS** button (tick boxes, wording, timings, TEST NOTICE, SAVE). They are stored in `Zomboid/Lua/RealReset_Config.txt`, created on first start, which you can also edit by hand (reloaded within a minute): `protect_claimed_vehicles`, `claim_buffer`, `warn_players`, `warn_mode` (`zones` or `everywhere`, the latter for a full reset), `warn_admins` (set `true` to test it yourself), `warn_seconds`, `warn_cooldown_minutes`, and `warn_message` (the wording, up to 300 characters). Players do not need the file; the text is sent from the server.
- The 16-tile safehouse buffer is deliberate (a bigger margin avoids half-reset neighbourhoods). It is `SAFEHOUSE_BUFFER` at the top of `RealReset_Server.lua`.

## Safety model (read this before trusting it)
A chunk is moved only if **all** of these hold:
- the caller is a server-verified admin;
- a PLAN for the same group was run by that admin in the last 10 minutes;
- the chunk is outside every protected zone and every safehouse (+16 tile buffer), using the AZR file **and** the live safehouse list (if the live list cannot be read, RESET refuses);
- the chunk is not within 16 tiles of a Sunday Driver claimed vehicle (setting, on by default);
- no online player is within **8 chunks**, and the server reports the chunk is not loaded in memory;
- the Java self-test passed (cache folder, world save folder, player list).

It **never permanently deletes a chunk**. Files go to `Saves/Multiplayer/<server>/_realreset_trash/run_<time>__<group>_by_<admin>/<wx>_<wy>.bin`.
A failed move is logged and the file is left where it was. Batches older than 7 days (or beyond 20000 files in total) are pruned; only files RealReset! created are ever removed.
Every RESET and RESTORE is written to `Zomboid/Lua/RealReset_Log.txt`.

The Java code does not use the network and does not run programs. It is one file: `src/com/drengrcode/realreset/RealReset.java`. Read it.

**Manual undo** (if you ever need it without the panel): stop the server, copy `<wx>_<wy>.bin` from a batch folder to `map/<wx>/<wy>.bin` renamed to `<wy>.bin` (replacing the file there), start the server. Tested.

## About ZombieBuddy trust
ZombieBuddy lets a mod run Java code inside the server. `policy=allow-all` runs **any** jar that appears, including one added by a later Workshop update of any mod.
Prefer `policy=deny-new` (skips jars you have not approved) and only enable Java mods you have read. Hosting rules vary - check yours allows Java agents.

## Game updates
RealReset! reaches into game internals by name. A game update can rename them. The startup self-test logs which hooks still work;
if an essential one is missing it **refuses to move anything**. If the optional "chunk loaded" check disappears, it falls back to the radius check only and says so in the log.

## Build and test
`./build.sh` (JDK 17+, no game files). `tests/run.sh` runs the Java tests against fake game classes, plus the Lua mocks if a `lua` binary is installed.
The compile-time `LuaMethod` stub in `stubs/` is never packaged.

## Licence
MIT - see `LICENSE`. Not affiliated with The Indie Stone. Originated as DrengrChunkTools.
