-- RealReset! server side (v0.4.0)
-- Reads Admin Zone Reset's synced zone file, then moves the save file of every chunk in
-- the RESET zones to a trash folder (Java side) so it regenerates from the base map.
--
-- Safety layers (all must pass for a chunk to be touched):
--   1. caller must be a server-verified admin
--   2. EXECUTE only works within 10 minutes of a PLAN (dry run) by the same admin
--   3. chunk is not inside a protected zone or safehouse (+buffer), file AND live list
--   4. live safehouse list must be readable, otherwise EXECUTE refuses
--   5. Java side: no player within the radius, chunk not loaded, essentials self-tested
--   6. per-run cap, Java-side rate ceiling, trash instead of delete, audit log
--   7. chunks near a vehicle claimed with Sunday Driver (SDVC) are skipped (setting, on by default)
--
-- A RESET is a queue: it works through the chunks in small steps and waits when the safety limit
-- (moves per 10 minutes) is used up. Every step re-checks protection. Admin can cancel any time.
--
-- Also: a light, dismissible warning for non-admin players inside a reset zone (settings file).

local MIN_VACANT_RADIUS = 8        -- chunks. Java will not accept less than 4.
local PLAN_VALID_MS = 10 * 60 * 1000
local MAX_QUEUE = 3000            -- chunks one RESET may queue
local QUEUE_SLICE = 200           -- chunk moves per step
local QUEUE_EVERY_MS = 1000       -- gap between steps
local QUEUE_REPORT_MS = 20000     -- progress message to the admin
local SAFEHOUSE_BUFFER = 16
local ZONES_FILE = "AdminZoneReset_ServerZones.txt"
local LOG_FILE = "RealReset_Log.txt"

local CONFIG_FILE = "RealReset_Config.txt"
local DEFAULT_WARN = "Heads-up: this area can be reset by admins. Items left here may be removed. Safehouses and claimed vehicles are protected."
local cfg = {
    protect_claimed_vehicles = true,
    claim_buffer = 16,            -- tiles around each claimed vehicle that are left alone
    warn_players = true,
    warn_mode = "zones",          -- "zones" = inside reset zones only; "everywhere" = anywhere not protected
    warn_admins = false,          -- true lets an admin see the warning (for testing)
    warn_seconds = 15,
    warn_cooldown_minutes = 10,
    warn_message = DEFAULT_WARN,
}
local cfgLoadedAt = nil

local function configText(c)
    local function b(v) return v and "true" or "false" end
    return table.concat({
        "# RealReset! settings. You can change them in game (RealReset! panel > SETTINGS) or edit this file.",
        "# File edits load within a minute (no restart needed). Lines starting with # are ignored.",
        "# Delete this file to get the defaults back.",
        "",
        "# Skip chunks near vehicles claimed with Sunday Driver (SDVC). true / false",
        "protect_claimed_vehicles=" .. b(c.protect_claimed_vehicles),
        "# Tiles around each claimed vehicle that are left alone (a claim's saved position can lag by ~10 tiles).",
        "claim_buffer=" .. tostring(c.claim_buffer),
        "",
        "# Show players a small dismissible warning when they enter a reset zone. true / false",
        "warn_players=" .. b(c.warn_players),
        "# zones = only inside RESET zones.  everywhere = anywhere that is not protected (use for a full reset).",
        "warn_mode=" .. c.warn_mode,
        "# Admins never see the warning unless this is true (handy to test it yourself).",
        "warn_admins=" .. b(c.warn_admins),
        "# How long the notice stays up if the player does not close it (seconds), and the gap before it can show again (minutes).",
        "warn_seconds=" .. tostring(c.warn_seconds),
        "warn_cooldown_minutes=" .. tostring(c.warn_cooldown_minutes),
        "# The wording. One line, up to 300 characters.",
        "warn_message=" .. c.warn_message,
    }, "\n") .. "\n"
end

local queue = nil               -- the running RESET / RESTORE queue, if any

-- What every admin's panel needs to know about the running queue.
local function queueInfo()
    if not queue then return { active = false } end
    return { active = true, kind = queue.kind or "reset", group = queue.group, who = queue.who,
             done = math.min(queue.idx - 1, #queue.cand), total = #queue.cand, moved = queue.moved, note = queue.note }
end
local lastRestorePlan = {}   -- [username] = { t = ms, key = "run:<id>" or "chunk:<x>,<y>" }
local lastPlan = {}   -- [username] = { t = ms, wouldMove = n, group = "all" or lower-case group }

-- Zone groups come from the "group=" field in AZR's file. Matching ignores case and stray spaces.
local function normGroup(g)
    if g == nil then return "(no group)" end
    g = tostring(g):match("^%s*(.-)%s*$")
    if g == nil or g == "" then return "(no group)" end
    return g
end

local function groupKey(wanted)
    if wanted == nil then return "all" end
    local w = tostring(wanted):match("^%s*(.-)%s*$") or ""
    if w == "" or w:lower() == "all" then return "all" end
    return w:lower()
end

local function nowMs()
    if getTimestampMs then return getTimestampMs() end
    return 0
end

local function isAdmin(player)
    if not player then return false end
    local lvl = player.getAccessLevel and player:getAccessLevel()
    return lvl ~= nil and tostring(lvl):lower() == "admin"
end

local function boxesOverlap(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2)
    return not (ax2 < bx1 or ax1 > bx2 or ay2 < by1 or ay1 > by2)
end

-- Nearest online player to a chunk: distance in chunks, and who.
local function nearestPlayer(wx, wy, cs)
    local players = getOnlinePlayers()
    if not players or players:size() == 0 then return 999999, nil end
    local best, who = 999999, nil
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            local d = math.max(math.abs(math.floor(p:getX() / cs) - wx),
                               math.abs(math.floor(p:getY() / cs) - wy))
            if d < best then best = d; who = p:getUsername() end
        end
    end
    return best, who
end

-- Live safehouses straight from the game. Returns boxes, or nil + reason if unreadable.
local function liveSafehouseBoxes()
    local out = {}
    local ok, err = pcall(function()
        local list = SafeHouse.getSafehouseList()
        if not list then error("safehouse list is nil") end
        for i = 0, list:size() - 1 do
            local sh = list:get(i)
            if sh then
                out[#out + 1] = {
                    x1 = sh:getX()  - SAFEHOUSE_BUFFER, y1 = sh:getY()  - SAFEHOUSE_BUFFER,
                    x2 = sh:getX2() + SAFEHOUSE_BUFFER, y2 = sh:getY2() + SAFEHOUSE_BUFFER,
                }
            end
        end
    end)
    if not ok then return nil, tostring(err) end
    return out
end

-- Parse AZR's shared file into reset[] and protected[] tile boxes.
local function readZones()
    local reader = getFileReader(ZONES_FILE, false)
    if not reader then return nil end
    local recs, cur = {}, nil
    pcall(function()
        local line = reader:readLine()
        while line ~= nil do
            local t = line:match("^%s*(.-)%s*$")
            if t ~= "" then
                local name = t:match("^%[(.+)%]$")
                if name then cur = { name = name }; recs[#recs + 1] = cur
                elseif cur then
                    local k, v = t:match("^([^=]+)=(.*)$")
                    if k then cur[k] = tonumber(v) or v end
                end
            end
            line = reader:readLine()
        end
    end)
    reader:close()

    local reset, protected = {}, {}
    for _, r in ipairs(recs) do
        if r.deleted == 1 then
            -- tombstone
        elseif r.x1 and r.y1 and r.x2 and r.y2 then
            if r.type == "reset" then
                r.groupName = normGroup(r.group)
                reset[#reset + 1] = r
            elseif r.type == "protected" then
                protected[#protected + 1] = r
            elseif r.type == "safehouse" then
                local b = tonumber(r.buffer) or 0
                protected[#protected + 1] = { x1 = r.x1 - b, y1 = r.y1 - b, x2 = r.x2 + b, y2 = r.y2 + b }
            end
        end
    end
    return reset, protected
end


---------------------------------------------------------------- settings file
local function setDefaults()
    cfg.protect_claimed_vehicles, cfg.claim_buffer = true, 16
    cfg.warn_players, cfg.warn_mode, cfg.warn_admins = true, "zones", false
    cfg.warn_seconds, cfg.warn_cooldown_minutes, cfg.warn_message = 15, 10, DEFAULT_WARN
end

local function writeDefaultConfig()
    setDefaults()
    local w = getFileWriter(CONFIG_FILE, true, false)
    if not w then return end
    w:write(configText(cfg))
    w:close()
end

local function asBool(v, default)
    v = tostring(v):lower()
    if v == "true" or v == "yes" or v == "on" or v == "1" then return true end
    if v == "false" or v == "no" or v == "off" or v == "0" then return false end
    return default
end

local function asNum(v, default, lo, hi)
    local n = tonumber(v)
    if not n then return default end
    if n < lo then n = lo elseif n > hi then n = hi end
    return n
end

-- Reads the settings file (creates it with defaults if missing). Reloads at most once a minute.
local function loadConfig(force)
    local t = nowMs()
    if not force and cfgLoadedAt and t ~= 0 and (t - cfgLoadedAt) < 60000 then return cfg end
    cfgLoadedAt = t
    local r = getFileReader(CONFIG_FILE, false)
    if not r then
        writeDefaultConfig()
        return cfg
    end
    local lines, ok = {}, true
    ok = pcall(function()
        local l = r:readLine()
        while l ~= nil do lines[#lines + 1] = l; l = r:readLine() end
    end)
    r:close()
    if not ok then return cfg end    -- keep the previous settings if the read broke
    -- start from the defaults so a line removed from the file really goes back to default
    setDefaults()
    for _, l in ipairs(lines) do
        local t2 = l:match("^%s*(.-)%s*$")
        if t2 ~= "" and t2:sub(1, 1) ~= "#" then
            local k, v = t2:match("^([^=]+)=(.*)$")
            if k then
                k = k:match("^%s*(.-)%s*$"):lower()
                v = v:match("^%s*(.-)%s*$")
                if k == "protect_claimed_vehicles" then cfg.protect_claimed_vehicles = asBool(v, true)
                elseif k == "claim_buffer" then cfg.claim_buffer = asNum(v, 16, 0, 64)
                elseif k == "warn_players" then cfg.warn_players = asBool(v, true)
                elseif k == "warn_mode" then
                    v = v:lower()
                    cfg.warn_mode = (v == "everywhere") and "everywhere" or "zones"
                elseif k == "warn_admins" then cfg.warn_admins = asBool(v, false)
                elseif k == "warn_seconds" then cfg.warn_seconds = asNum(v, 15, 3, 120)
                elseif k == "warn_cooldown_minutes" then cfg.warn_cooldown_minutes = asNum(v, 10, 0, 1440)
                elseif k == "warn_message" then
                    v = v:gsub("[%c]", " ")
                    if #v > 300 then v = v:sub(1, 300) end
                    cfg.warn_message = (v ~= "") and v or DEFAULT_WARN
                end
            end
        end
    end
    return cfg
end

---------------------------------------------------------------- Sunday Driver (SDVC) claims
local function readLinesOf(path)
    local r = getFileReader(path, false)
    if not r then return nil end
    local lines = {}
    local ok = pcall(function()
        local l = r:readLine()
        while l ~= nil do lines[#lines + 1] = l; l = r:readLine() end
    end)
    r:close()
    if not ok then return nil end
    return lines
end

-- Boxes around every claimed vehicle SDVC knows about.
-- Returns boxes, claimCount, errorText (fatal: unreadable data), noteText (harmless info).
local function claimBoxes()
    local boxes = {}
    local idx = readLinesOf("SDVC_Claims/_Index.txt") or readLinesOf("SDVC_Claims/_Index.json")
    if not idx then
        return boxes, 0, nil, "no Sunday Driver claim data found (nothing to protect)"
    end
    local buf = cfg.claim_buffer
    local missing, count = 0, 0
    for _, l in ipairs(idx) do
        local user = l:match('"([^"]+)"')
        if user and not user:find("[/\\]") and not user:find("..", 1, true) then
            local lines = readLinesOf("SDVC_Claims/SDVC_Claims_" .. user .. ".txt")
                       or readLinesOf("SDVC_Claims/SDVC_Claims_" .. user .. ".json")
            if not lines then
                missing = missing + 1
            else
                for _, line in ipairs(lines) do
                    local sqlId, body = line:match('^%s*"([^"]+)":%s*{(.*)}')
                    if sqlId and body then
                        local x = tonumber(body:match('"x":([^,]+)'))
                        local y = tonumber(body:match('"y":([^,]+)'))
                        if x and y then
                            local car = body:match('"vehicleName":"([^"]*)"') or "vehicle"
                            boxes[#boxes + 1] = {
                                x1 = math.floor(x - buf), y1 = math.floor(y - buf),
                                x2 = math.floor(x + buf), y2 = math.floor(y + buf),
                                kind = "claim",
                                desc = string.format("%s: %s at %d,%d", user, car, math.floor(x), math.floor(y)),
                            }
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
    if missing > 0 then
        return boxes, count, string.format("Sunday Driver claim file missing for %d user(s)", missing)
    end
    return boxes, count, nil, nil
end

-- First box that overlaps the chunk's tiles. A real protection beats a claim box when both apply.
local function blockedBy(boxes, tx1, ty1, tx2, ty2)
    local claimHit = nil
    for _, p in ipairs(boxes) do
        if boxesOverlap(tx1, ty1, tx2, ty2, p.x1, p.y1, p.x2, p.y2) then
            if p.kind ~= "claim" then return p end
            claimHit = claimHit or p
        end
    end
    return claimHit
end

local function stamp()
    local ok, s = pcall(os.date, "!%Y-%m-%d %H:%M:%S UTC")
    if ok and s then return s end
    return "t=" .. tostring(nowMs())
end

-- Send lines to the admin's screen and the server console.
local function report(player, header, lines, groupsStr, runsStr)
    local text = header
    print("[RealReset] " .. header)
    for _, l in ipairs(lines) do
        text = text .. "\n" .. l
        print("[RealReset]   " .. l)
    end
    if player and sendServerCommand then
        sendServerCommand(player, "RealReset", "result", { text = text, groups = groupsStr, runs = runsStr, queue = (queue ~= nil), qinfo = queueInfo() })
    end
end

-- Sorted list of group display names and a count per lower-case key.
local function listGroups(reset)
    local names, counts, seen = {}, {}, {}
    for _, z in ipairs(reset) do
        local k = z.groupName:lower()
        counts[k] = (counts[k] or 0) + 1
        if not seen[k] then seen[k] = true; names[#names + 1] = z.groupName end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names, counts
end

local startQueue

---------------------------------------------------------------- RESET queue
-- Safety-limit numbers from the Java side. used, max, secondsUntilOneFrees (nil if unavailable).
local function ceilingNow()
    if not RealReset_ceilingInfo then return nil end
    local ok, v = pcall(RealReset_ceilingInfo)
    if not ok or not v then return nil end
    local u, m, w = tostring(v):match("^(%d+)|(%d+)|(%d+)$")
    if not u then return nil end
    return tonumber(u), tonumber(m), tonumber(w)
end

local function findPlayer(name)
    local players = getOnlinePlayers()
    if not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p:getUsername() == name then return p end
    end
    return nil
end

local lastBroadcast = 0
-- Tell every online admin (their panels lock or unlock) about the queue state.
local function broadcastQueue()
    lastBroadcast = nowMs()
    local players = getOnlinePlayers()
    if not players then return end
    local info = queueInfo()
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and isAdmin(p) then sendServerCommand(p, "RealReset", "queueState", info) end
    end
end

local function queueLines(q, final)
    local lines = {}
    local restore = (q.kind == "restore")
    if restore then
        lines[#lines + 1] = "Batch: " .. q.runId
    else
        lines[#lines + 1] = string.format("Group: %s", q.group)
        lines[#lines + 1] = "Batch (for RESTORE): " .. q.runId
        lines[#lines + 1] = string.format("Zones: %d reset, %d protected area(s) (incl. %d live safehouse(s))",
            q.zoneCount, q.nProtected, q.nLive)
    end
    lines[#lines + 1] = string.format("Progress: %d of %d chunk(s) checked", math.min(q.idx - 1, #q.cand), #q.cand)
    if restore then
        lines[#lines + 1] = string.format("%s: %d chunk(s)", final and "Restored" or "Restored so far", q.moved)
    else
        lines[#lines + 1] = string.format("%s: %d chunk(s)", final and "Moved to trash" or "Moved so far", q.moved)
    end
    lines[#lines + 1] = string.format("Skipped - protected: %d", q.protSkip)
    if cfg.protect_claimed_vehicles then
        if restore then
            lines[#lines + 1] = string.format("Skipped - near a claimed vehicle (Sunday Driver): %d", q.claimSkip)
        else
            lines[#lines + 1] = string.format("Skipped - near a claimed vehicle (Sunday Driver): %d  [%d claim(s) known]",
                q.claimSkip, q.claimCount)
        end
    end
    local names = {}
    for n, _ in pairs(q.nearNames) do names[#names + 1] = n end
    table.sort(names)
    lines[#lines + 1] = string.format("Skipped - player nearby: %d%s", q.playerSkip,
        #names > 0 and (" (" .. table.concat(names, ", ") .. ")") or "")
    lines[#lines + 1] = string.format("Skipped - chunk loaded: %d", q.loadedSkip)
    if restore then
        if q.noFile > 0 then lines[#lines + 1] = string.format("Not in this batch any more: %d", q.noFile) end
    else
        lines[#lines + 1] = string.format("Nothing to reset (never saved / already clean): %d", q.noFile + (q.noFilePre or 0))
    end
    if q.failed > 0 then lines[#lines + 1] = string.format("FAILED moves (left in place): %d - see console", q.failed) end
    if q.truncated then lines[#lines + 1] = string.format("More than %d chunks: run PLAN and RESET again for the rest.", MAX_QUEUE) end
    if q.playerSkip > 0 or q.loadedSkip > 0 then
        lines[#lines + 1] = "Skipped chunks were not retried. Run PLAN " .. (restore and "RESTORE " or "") .. "again later to pick them up."
    end
    if restore then
        lines[#lines + 1] = "If the game had already regenerated a chunk, that newer file is kept in the batch's 'replaced' folder."
    end
    return lines
end

local function finishQueue(why)
    local q = queue
    queue = nil
    if not q then return end
    if q.kind ~= "restore" and RealReset_endRun then RealReset_endRun() end
    local lines = queueLines(q, true)
    local word = (q.kind == "restore") and "RESTORE" or "RESET"
    local header = word .. " DONE"
    if why then
        header = word .. " STOPPED"
        table.insert(lines, 1, "Stopped: " .. why)
    end
    local log = getFileWriter(LOG_FILE, true, true)
    if log then
        log:write(string.format("RESULT%s: moved=%d protected=%d claimed=%d player=%d loaded=%d nofile=%d failed=%d\n",
            why and (" (stopped: " .. why .. ")") or "", q.moved, q.protSkip, q.claimSkip, q.playerSkip, q.loadedSkip, q.noFile, q.failed))
        log:close()
    end
    if q.kind ~= "restore" and RealReset_pruneTrash then RealReset_pruneTrash() end
    local p = findPlayer(q.who)
    print("[RealReset] " .. header .. " (" .. q.group .. ", " .. q.moved .. " moved)")
    broadcastQueue()
    if p then report(p, header, lines, nil, RealReset_listRuns and RealReset_listRuns() or nil) end
end

local function processQueue()
    local q = queue
    if not q then return end
    local t = nowMs()
    if t ~= 0 and q.lastTick and (t - q.lastTick) < QUEUE_EVERY_MS then return end
    q.lastTick = t

    local p = findPlayer(q.who)
    if not p then q.note = "paused - " .. q.who .. " is offline"; return end

    -- Re-read every protection each step: a safehouse or claim made mid-run is respected.
    local _, protected, perr = nil, nil, nil
    do
        local reset, prot = readZones()
        if reset == nil then perr = ZONES_FILE .. " not found" else
            local live, lerr = liveSafehouseBoxes()
            if not live then perr = "live safehouses unreadable (" .. tostring(lerr) .. ")" else
                for _, b in ipairs(live) do prot[#prot + 1] = b end
                loadConfig()
                if cfg.protect_claimed_vehicles then
                    local cb, _, cerr = claimBoxes()
                    if cerr then perr = cerr else for _, b in ipairs(cb) do prot[#prot + 1] = b end end
                end
                protected = prot
            end
        end
    end
    if perr or not protected then q.note = "paused - " .. tostring(perr); return end

    local used, max, wait = ceilingNow()
    local left = used and (max - used) or QUEUE_SLICE
    if left <= 0 then
        q.note = string.format("waiting for the safety limit (next chunk frees in about %d s)", wait or 0)
    else
        q.note = nil
        local budget = math.min(QUEUE_SLICE, left)
        local moves, steps = 0, 0
        local log = getFileWriter(LOG_FILE, true, true)
        while q.idx <= #q.cand and moves < budget and steps < 600 do
            local c = q.cand[q.idx]
            q.idx = q.idx + 1
            steps = steps + 1
            local wx, wy = c[1], c[2]
            local tx1, ty1 = wx * q.cs, wy * q.cs
            local blk = blockedBy(protected, tx1, ty1, tx1 + q.cs - 1, ty1 + q.cs - 1)
            if blk then
                if blk.kind == "claim" then q.claimSkip = q.claimSkip + 1 else q.protSkip = q.protSkip + 1 end
            else
                local code
                if q.kind == "restore" then
                    code = RealReset_restoreChunk(q.runId, wx, wy, q.cs, MIN_VACANT_RADIUS, true)
                else
                    code = RealReset_moveChunk(wx, wy, q.cs, MIN_VACANT_RADIUS)
                end
                if code == 1 then
                    q.moved = q.moved + 1; moves = moves + 1; q.refuseStreak = 0
                    if log then log:write(c[3] .. " | chunk " .. wx .. "," .. wy .. "\n") end
                elseif code == 0 then q.noFile = q.noFile + 1; q.refuseStreak = 0
                elseif code == -1 then
                    q.playerSkip = q.playerSkip + 1; q.refuseStreak = 0
                    local _, name = nearestPlayer(wx, wy, q.cs)
                    if name then q.nearNames[name] = true end
                elseif code == -2 then q.loadedSkip = q.loadedSkip + 1; q.refuseStreak = 0
                elseif code == -3 then q.failed = q.failed + 1; q.refuseStreak = 0
                else
                    -- refused (limit reached meanwhile, or not ready): put it back and retry next step
                    q.idx = q.idx - 1
                    q.refuseStreak = (q.refuseStreak or 0) + 1
                    break
                end
            end
        end
        if log then log:close() end
    end

    if t == 0 or (t - lastBroadcast) >= 5000 then broadcastQueue() end
    if (q.refuseStreak or 0) >= 20 then finishQueue("the Java side kept refusing (see the console)"); return end
    if q.cancel then finishQueue("cancelled"); return end
    if q.idx > #q.cand then finishQueue(nil); return end

    if t == 0 or not q.lastReport or (t - q.lastReport) >= QUEUE_REPORT_MS then
        q.lastReport = t
        local lines = queueLines(q, false)
        if q.note then table.insert(lines, 1, "Status: " .. q.note) end
        report(p, ((q.kind == "restore") and "RESTORE" or "RESET") .. " running", lines, nil, nil)
    end
end

startQueue = function(player, gkey, glabel, reset, protected, nProtected, nLive, claimCount, groupNames)
    local who = player:getUsername()
    local cs = (getChunkSizeInSquares and getChunkSizeInSquares()) or 8
    local cand, seen = {}, {}
    local protSkip, claimSkip, truncated, noFilePre = 0, 0, false, 0
    for _, z in ipairs(reset) do
        local cx1, cx2 = math.floor(z.x1 / cs), math.floor(z.x2 / cs)
        local cy1, cy2 = math.floor(z.y1 / cs), math.floor(z.y2 / cs)
        local zname = tostring(z.name or z.id or "?")
        for wx = cx1, cx2 do
            for wy = cy1, cy2 do
                local key = wx .. "," .. wy
                if not seen[key] then
                    seen[key] = true
                    local tx1, ty1 = wx * cs, wy * cs
                    local blk = blockedBy(protected, tx1, ty1, tx1 + cs - 1, ty1 + cs - 1)
                    if blk then
                        if blk.kind == "claim" then claimSkip = claimSkip + 1 else protSkip = protSkip + 1 end
                    else
                        -- Only chunks that have a saved file are worth queueing (most of the map was never visited).
                        local code = RealReset_previewChunk(wx, wy, cs, MIN_VACANT_RADIUS)
                        if code == 0 then
                            noFilePre = noFilePre + 1
                        elseif #cand >= MAX_QUEUE then
                            truncated = true
                        else
                            cand[#cand + 1] = { wx, wy, zname }
                        end
                    end
                end
            end
        end
    end
    if #cand == 0 then
        report(player, "RESET", { "Nothing to queue: every chunk is protected, never saved, or already clean. Nothing was changed." },
            table.concat(groupNames, "|"))
        return
    end
    local runId = RealReset_beginRun(glabel .. "_by_" .. who)
    if not runId or runId == "" then
        report(player, "RESET REFUSED", { "Could not create the trash batch folder. Nothing was touched." })
        return
    end
    queue = {
        who = who, group = glabel, gkey = gkey, runId = runId, cand = cand, idx = 1, cs = cs,
        moved = 0, protSkip = protSkip, claimSkip = claimSkip, playerSkip = 0, loadedSkip = 0, noFile = 0, failed = 0,
        nearNames = {}, truncated = truncated, nProtected = nProtected, nLive = nLive, claimCount = claimCount,
        zoneCount = #reset, noFilePre = noFilePre, startedMs = nowMs(), lastTick = nil, lastReport = nil, refuseStreak = 0,
    }
    local log = getFileWriter(LOG_FILE, true, true)
    if log then log:write("---- " .. stamp() .. " EXECUTE (queued, " .. #cand .. " chunks) by " .. who .. " (" .. runId .. ") ----\n"); log:close() end
    report(player, "RESET STARTED", {
        string.format("%d chunk(s) queued for group %s. It works through them in small steps and waits when the safety limit is used up.", #cand, glabel),
        "Batch (for RESTORE): " .. runId,
        "Press CANCEL QUEUE to stop. Chunks already moved stay in the batch and can be restored.",
    }, table.concat(groupNames, "|"))
    broadcastQueue()
    processQueue()
end

local function startRestoreQueue(player, runId, chunks, protected, cs)
    local who = player:getUsername()
    local cand, protSkip, claimSkip, truncated = {}, 0, 0, false
    for _, c in ipairs(chunks) do
        local wx, wy = c[1], c[2]
        local tx1, ty1 = wx * cs, wy * cs
        local blk = blockedBy(protected, tx1, ty1, tx1 + cs - 1, ty1 + cs - 1)
        if blk then
            if blk.kind == "claim" then claimSkip = claimSkip + 1 else protSkip = protSkip + 1 end
        elseif #cand >= MAX_QUEUE then
            truncated = true
        else
            cand[#cand + 1] = { wx, wy, "restored" }
        end
    end
    if #cand == 0 then
        report(player, "RESTORE", { "Nothing to restore: every chunk in this batch is protected. Nothing was changed." })
        return
    end
    queue = {
        kind = "restore", who = who, group = runId, gkey = runId, runId = runId, cand = cand, idx = 1, cs = cs,
        moved = 0, protSkip = protSkip, claimSkip = claimSkip, playerSkip = 0, loadedSkip = 0, noFile = 0, failed = 0,
        nearNames = {}, truncated = truncated, nProtected = 0, nLive = 0, claimCount = 0, zoneCount = 0,
        startedMs = nowMs(), lastTick = nil, lastReport = nil, refuseStreak = 0,
    }
    local log = getFileWriter(LOG_FILE, true, true)
    if log then log:write("---- " .. stamp() .. " RESTORE (queued, " .. #cand .. " chunks) by " .. who .. " from " .. runId .. " ----\n"); log:close() end
    report(player, "RESTORE STARTED", {
        string.format("%d chunk(s) queued from batch %s. It works through them in steps and waits when the safety limit is used up.", #cand, runId),
        "Press CANCEL QUEUE to stop. Chunks already restored stay restored.",
    })
    broadcastQueue()
    processQueue()
end

local function cancelQueue(player)
    if not queue then
        report(player, "RealReset", { "Nothing is running." })
        return
    end
    queue.cancel = true
    finishQueue("cancelled by " .. player:getUsername())
end

if Events.OnTick then Events.OnTick.Add(processQueue) end

local function runReset(dryRun, player, wantGroup)
    local who = player:getUsername()
    local lines = {}
    local gkey = groupKey(wantGroup)
    local glabel = (gkey == "all") and "ALL" or tostring(wantGroup)

    if not RealReset_previewChunk or not RealReset_beginRun then
        report(player, "RealReset: NOT AVAILABLE", { "The Java side is not loaded (is ZombieBuddy running with this jar?)." })
        return
    end
    if not RealReset_isReady() then
        report(player, "RealReset: NOT READY", { "Java self-test failed. See server console for the [RealReset] line." })
        return
    end

    if queue then
        report(player, dryRun and "PLAN refused" or "RESET REFUSED",
            { "A " .. ((queue.kind == "restore") and "restore" or "reset") .. " is already running (" .. queue.group .. ", started by " .. queue.who .. "). Wait for it to finish or cancel it." })
        return
    end

    if not dryRun then
        local p = lastPlan[who]
        if not p or (nowMs() - p.t) > PLAN_VALID_MS then
            report(player, "RESET REFUSED", { "Run PLAN (dry run) first. A plan is valid for 10 minutes." })
            return
        end
        if p.group ~= gkey then
            report(player, "RESET REFUSED", { "Your last PLAN was for a different group. Run PLAN for group '"
                .. glabel .. "' first." })
            return
        end
        lastPlan[who] = nil   -- one plan, one execute
    end

    local reset, protected = readZones()
    if reset == nil then
        report(player, "RealReset: no zones file",
            { ZONES_FILE .. " not found. Admin Zone Reset must be on the server, with a RESET zone drawn and synced." })
        return
    end

    -- Keep only the zones in the chosen group (protected areas always apply, whatever the group).
    local groupNames = listGroups(reset)
    if gkey ~= "all" then
        local picked = {}
        for _, z in ipairs(reset) do
            if z.groupName:lower() == gkey then picked[#picked + 1] = z end
        end
        if #picked == 0 then
            report(player, dryRun and "PLAN refused" or "RESET REFUSED",
                { "No zones in group '" .. glabel .. "'. Press STATUS to see the groups." },
                table.concat(groupNames, "|"))
            return
        end
        reset = picked
    end

    local live, liveErr = liveSafehouseBoxes()
    if not live then
        if not dryRun then
            report(player, "RESET REFUSED", { "Could not read live safehouses (" .. liveErr .. "). Not touching anything." })
            return
        end
        lines[#lines + 1] = "WARNING: live safehouses unreadable (" .. liveErr .. ") - EXECUTE would refuse."
        live = {}
    end
    for _, b in ipairs(live) do protected[#protected + 1] = b end
    local nProtected = #protected

    loadConfig(true)
    local claimCount, claimNote = 0, nil
    if cfg.protect_claimed_vehicles then
        local cb, n, cerr, note = claimBoxes()
        if cerr then
            if not dryRun then
                report(player, "RESET REFUSED", { cerr .. ". Not touching anything. (Set protect_claimed_vehicles=false in "
                    .. CONFIG_FILE .. " to turn this check off.)" })
                return
            end
            lines[#lines + 1] = "WARNING: " .. cerr .. " - RESET NOW would refuse."
        end
        for _, b in ipairs(cb) do protected[#protected + 1] = b end
        claimCount, claimNote = n, note
    end

    if not dryRun then
        startQueue(player, gkey, glabel, reset, protected, nProtected, #live, claimCount, groupNames)
        return
    end

    -- PLAN (dry run): count what would happen. Nothing is changed.
    local cs = (getChunkSizeInSquares and getChunkSizeInSquares()) or 8
    local acted, protSkip, playerSkip, loadedSkip, noFile, failed, refused = 0, 0, 0, 0, 0, 0, 0
    local claimSkip, claimSeen, claimList = 0, {}, {}
    local nearNames, seenChunk = {}, {}

    for _, z in ipairs(reset) do
        local cx1, cx2 = math.floor(z.x1 / cs), math.floor(z.x2 / cs)
        local cy1, cy2 = math.floor(z.y1 / cs), math.floor(z.y2 / cs)
        for wx = cx1, cx2 do
            for wy = cy1, cy2 do
                local key = wx .. "," .. wy
                if not seenChunk[key] then
                    seenChunk[key] = true
                    local tx1, ty1 = wx * cs, wy * cs
                    local tx2, ty2 = tx1 + cs - 1, ty1 + cs - 1
                    local blk = blockedBy(protected, tx1, ty1, tx2, ty2)
                    if blk then
                        if blk.kind == "claim" then
                            claimSkip = claimSkip + 1
                            if not claimSeen[blk.desc] then
                                claimSeen[blk.desc] = true
                                if #claimList < 12 then claimList[#claimList + 1] = blk.desc end
                            end
                        else
                            protSkip = protSkip + 1
                        end
                    else
                        local code = RealReset_previewChunk(wx, wy, cs, MIN_VACANT_RADIUS)
                        if code == 1 then acted = acted + 1
                        elseif code == 0 then noFile = noFile + 1
                        elseif code == -1 then
                            playerSkip = playerSkip + 1
                            local d, name = nearestPlayer(wx, wy, cs)
                            if name then nearNames[name] = true end
                        elseif code == -2 then loadedSkip = loadedSkip + 1
                        elseif code == -3 then failed = failed + 1
                        else refused = refused + 1 end
                    end
                end
            end
        end
    end

    local names = {}
    for n, _ in pairs(nearNames) do names[#names + 1] = n end
    table.sort(names)

    lines[#lines + 1] = string.format("Group: %s", glabel)
    lines[#lines + 1] = string.format("Zones: %d reset, %d protected area(s) (incl. %d live safehouse(s))",
        #reset, nProtected, #live)
    lines[#lines + 1] = string.format("Would move: %d chunk(s)", acted)
    lines[#lines + 1] = string.format("Skipped - protected: %d", protSkip)
    if cfg.protect_claimed_vehicles then
        lines[#lines + 1] = string.format("Skipped - near a claimed vehicle (Sunday Driver): %d  [%d claim(s) known]",
            claimSkip, claimCount)
        for _, d in ipairs(claimList) do lines[#lines + 1] = "    " .. d end
        if claimNote then lines[#lines + 1] = "    (" .. claimNote .. ")" end
    else
        lines[#lines + 1] = "Claimed-vehicle protection is OFF (" .. CONFIG_FILE .. ")."
    end
    lines[#lines + 1] = string.format("Skipped - player nearby: %d%s", playerSkip,
        #names > 0 and (" (" .. table.concat(names, ", ") .. ")") or "")
    lines[#lines + 1] = string.format("Skipped - chunk loaded: %d", loadedSkip)
    lines[#lines + 1] = string.format("Nothing to reset (never saved / already clean): %d", noFile)
    if failed > 0 then lines[#lines + 1] = string.format("FAILED checks: %d - see console", failed) end
    if refused > 0 then lines[#lines + 1] = string.format("REFUSED by Java safety (not ready / cannot read players): %d", refused) end

    local used, max, wait = ceilingNow()
    if used then
        lines[#lines + 1] = string.format("Safety limit: %d of %d chunk moves used in the last 10 minutes.", used, max)
    end
    if acted == 0 then
        lines[#lines + 1] = "Nothing to move right now. Nothing was changed."
        lastPlan[who] = nil   -- an empty plan must not leave an older plan usable
    else
        lines[#lines + 1] = "Nothing was changed. RESET NOW is unlocked for 10 minutes (for this group)."
        lastPlan[who] = { t = nowMs(), wouldMove = acted, group = gkey }
        if used and acted > (max - used) then
            local perMin = math.max(1, max / 10)
            lines[#lines + 1] = string.format(
                "RESET NOW will queue these and keep going by itself, pausing when the safety limit is used up (about %d minute(s) in total).",
                math.ceil(math.max(0, acted - (max - used)) / perMin))
        end
        if acted > MAX_QUEUE then
            lines[#lines + 1] = string.format("Note: one RESET queues at most %d chunks; run PLAN and RESET again for the rest.", MAX_QUEUE)
        end
    end

    report(player, "PLAN (dry run)", lines, table.concat(groupNames, "|"), nil)
end


----------------------------------------------------------------- RESTORE
local function protectedBoxes()
    local reset, protected = readZones()
    if reset == nil then return nil, ZONES_FILE .. " not found" end
    local live, err = liveSafehouseBoxes()
    if not live then return nil, "live safehouses unreadable (" .. tostring(err) .. ")" end
    for _, b in ipairs(live) do protected[#protected + 1] = b end
    loadConfig(true)
    if cfg.protect_claimed_vehicles then
        local cb, _, cerr = claimBoxes()
        if cerr then return nil, cerr end
        for _, b in ipairs(cb) do protected[#protected + 1] = b end
    end
    return protected
end

local function parseChunks(str)
    local out = {}
    for a, b in string.gmatch(str or "", "(-?%d+),(-?%d+);") do out[#out + 1] = { tonumber(a), tonumber(b) } end
    return out
end

local function sendRuns(player)
    local runsStr = RealReset_listRuns and RealReset_listRuns() or ""
    local lines = {}
    for _, disp in string.gmatch(runsStr, "([^|;]+)|([^;]+);") do lines[#lines + 1] = disp end
    if #lines == 0 then lines[1] = "No batches in the trash." end
    report(player, "Saved batches (newest first)", lines, nil, runsStr)
end

-- args: { run = "<batch id>" } or { wx = n, wy = n } (restores from the newest batch holding that chunk)
local function runRestore(dryRun, player, args)
    local who = player:getUsername()
    args = args or {}
    if queue then
        report(player, dryRun and "PLAN RESTORE refused" or "RESTORE REFUSED",
            { "A " .. ((queue.kind == "restore") and "restore" or "reset") .. " is running (" .. queue.group .. "). Wait for it to finish or cancel it first." })
        return
    end

    if not RealReset_restoreChunk then
        report(player, "RealReset: NOT AVAILABLE", { "The Java side is not loaded (needs the RealReset jar, 0.3.0 or newer)." })
        return
    end
    if not RealReset_isReady() then
        report(player, "RealReset: NOT READY", { "Java self-test failed. See the server console." })
        return
    end

    local key, runId, single
    if args.run and tostring(args.run) ~= "" then
        runId = tostring(args.run)
        key = "run:" .. runId
    elseif args.wx ~= nil and args.wy ~= nil then
        local wx, wy = tonumber(args.wx), tonumber(args.wy)
        if not wx or not wy then
            report(player, "RESTORE REFUSED", { "Bad chunk coordinates." })
            return
        end
        wx, wy = math.floor(wx), math.floor(wy)
        single = { wx, wy }
        key = "chunk:" .. wx .. "," .. wy
        runId = RealReset_findLatestRun(wx, wy)
        if not runId or runId == "" then
            report(player, "RESTORE", { "No saved copy of chunk " .. wx .. "," .. wy .. " in the trash." })
            return
        end
    else
        report(player, "RESTORE REFUSED", { "Choose a batch, or mark a chunk, first." })
        return
    end

    if not dryRun then
        local p = lastRestorePlan[who]
        if not p or (nowMs() - p.t) > PLAN_VALID_MS then
            report(player, "RESTORE REFUSED", { "Run PLAN RESTORE first. A plan is valid for 10 minutes." })
            return
        end
        if p.key ~= key then
            report(player, "RESTORE REFUSED", { "Your last PLAN RESTORE was for something else. Run it again for this choice." })
            return
        end
        lastRestorePlan[who] = nil
    end

    -- Restoring old content over a newly claimed safehouse or protected zone would destroy it.
    local protected, perr = protectedBoxes()
    if not protected then
        report(player, "RESTORE REFUSED", { "Cannot check protected zones: " .. tostring(perr) .. ". Not touching anything." })
        return
    end

    local cs = (getChunkSizeInSquares and getChunkSizeInSquares()) or 8
    local chunks = single and { single } or parseChunks(RealReset_runChunks(runId))
    if not dryRun then
        startRestoreQueue(player, runId, chunks, protected, cs)
        return
    end
    local restored, protSkip, playerSkip, loadedSkip, failed, refused, missing = 0, 0, 0, 0, 0, 0, 0

    for _, c in ipairs(chunks) do
        local wx, wy = c[1], c[2]
        local tx1, ty1 = wx * cs, wy * cs
        local tx2, ty2 = tx1 + cs - 1, ty1 + cs - 1
        if blockedBy(protected, tx1, ty1, tx2, ty2) then
            protSkip = protSkip + 1
        else
            local code = RealReset_restoreChunk(runId, wx, wy, cs, MIN_VACANT_RADIUS, false)
            if code == 1 then
                restored = restored + 1
            elseif code == 0 then missing = missing + 1
            elseif code == -1 then playerSkip = playerSkip + 1
            elseif code == -2 then loadedSkip = loadedSkip + 1
            elseif code == -3 then failed = failed + 1
            else refused = refused + 1 end
        end
    end

    local lines = {}
    lines[#lines + 1] = "Batch: " .. runId
    lines[#lines + 1] = string.format("Would restore: %d chunk(s)", restored)
    lines[#lines + 1] = string.format("Skipped - protected zone / safehouse / claimed vehicle: %d", protSkip)
    lines[#lines + 1] = string.format("Skipped - player nearby: %d", playerSkip)
    lines[#lines + 1] = string.format("Skipped - chunk loaded: %d", loadedSkip)
    if missing > 0 then lines[#lines + 1] = string.format("Not in this batch any more: %d", missing) end
    if failed > 0 then lines[#lines + 1] = string.format("FAILED (left as they were): %d - see console", failed) end
    if refused > 0 then lines[#lines + 1] = string.format("REFUSED by Java safety: %d", refused) end
    lines[#lines + 1] = "If the game had already regenerated a chunk, that newer file is kept in the batch's 'replaced' folder."
    if dryRun then
        if restored == 0 then
            lines[#lines + 1] = "Nothing to restore right now. Nothing was changed."
            lastRestorePlan[who] = nil
        else
            lines[#lines + 1] = "Nothing was changed. RESTORE NOW is unlocked for 10 minutes."
            lastRestorePlan[who] = { t = nowMs(), key = key }
            local used, max = ceilingNow()
            if used then
                lines[#lines + 1] = string.format("Safety limit: %d of %d chunk moves used in the last 10 minutes.", used, max)
                if restored > (max - used) then
                    lines[#lines + 1] = "RESTORE NOW will queue these and keep going by itself, pausing when the safety limit is used up."
                end
            end
            if restored > MAX_QUEUE then
                lines[#lines + 1] = string.format("Note: one RESTORE queues at most %d chunks; run it again for the rest.", MAX_QUEUE)
            end
        end
    end

    report(player, "PLAN RESTORE (dry run)", lines, nil, RealReset_listRuns())
end


---------------------------------------------------------------- in-game settings
local function settingsPayload(extra)
    local c = loadConfig(true)
    local t = {
        protect = c.protect_claimed_vehicles, buffer = c.claim_buffer,
        warn = c.warn_players, mode = c.warn_mode, warnAdmins = c.warn_admins,
        seconds = c.warn_seconds, cooldown = c.warn_cooldown_minutes, message = c.warn_message,
    }
    if extra then for k, v in pairs(extra) do t[k] = v end end
    return t
end

local function sendSettings(player, note)
    sendServerCommand(player, "RealReset", "settings", settingsPayload({ note = note }))
end

local function saveSettings(player, a)
    a = a or {}
    local c = loadConfig(true)
    if a.protect ~= nil then c.protect_claimed_vehicles = (a.protect == true) end
    if a.buffer ~= nil then c.claim_buffer = asNum(a.buffer, c.claim_buffer, 0, 64) end
    if a.warn ~= nil then c.warn_players = (a.warn == true) end
    if a.mode ~= nil then c.warn_mode = (tostring(a.mode):lower() == "everywhere") and "everywhere" or "zones" end
    if a.warnAdmins ~= nil then c.warn_admins = (a.warnAdmins == true) end
    if a.seconds ~= nil then c.warn_seconds = asNum(a.seconds, c.warn_seconds, 3, 120) end
    if a.cooldown ~= nil then c.warn_cooldown_minutes = asNum(a.cooldown, c.warn_cooldown_minutes, 0, 1440) end
    if a.message ~= nil then
        local m = tostring(a.message):gsub("[%c]", " "):match("^%s*(.-)%s*$") or ""
        if #m > 300 then m = m:sub(1, 300) end
        c.warn_message = (m ~= "") and m or DEFAULT_WARN
    end
    local w = getFileWriter(CONFIG_FILE, true, false)
    if not w then
        sendSettings(player, "Could not write " .. CONFIG_FILE .. ". Changes apply until the server restarts.")
        return
    end
    w:write(configText(c))
    w:close()
    cfgLoadedAt = nowMs()
    local log = getFileWriter(LOG_FILE, true, true)
    if log then log:write("---- " .. stamp() .. " SETTINGS changed by " .. player:getUsername() .. " ----\n"); log:close() end
    print("[RealReset] settings saved by " .. player:getUsername())
    sendSettings(player, "Saved.")
end

local function sendStatus(player)
    local lines = {}
    if not RealReset_ping then
        lines[1] = "Java side NOT loaded. RealReset needs ZombieBuddy on the server."
    else
        lines[1] = RealReset_ping()
        lines[2] = RealReset_selfTest()
    end
    if queue then
        lines[#lines + 1] = string.format("%s RUNNING: %s by %s, %d of %d chunk(s) checked, %d done%s",
            (queue.kind == "restore") and "RESTORE" or "RESET", queue.group, queue.who, math.min(queue.idx - 1, #queue.cand), #queue.cand, queue.moved,
            queue.note and (" - " .. queue.note) or "")
    end
    local used, max, wait = ceilingNow()
    if used then lines[#lines + 1] = string.format("Safety limit: %d of %d chunk moves used in the last 10 minutes.", used, max) end
    loadConfig(true)
    local ccount, cnote = 0, nil
    if cfg.protect_claimed_vehicles then
        local _, n, cerr, note = claimBoxes()
        ccount = n
        cnote = cerr and ("PROBLEM: " .. cerr) or note
    end
    lines[#lines + 1] = string.format("Claimed-vehicle protection: %s%s", cfg.protect_claimed_vehicles and "on" or "OFF",
        cfg.protect_claimed_vehicles and (" (" .. ccount .. " claim(s)" .. (cnote and ("; " .. cnote) or "") .. ")") or "")
    lines[#lines + 1] = string.format("Player warning: %s (%s). Settings file: %s",
        cfg.warn_players and "on" or "OFF", cfg.warn_mode, CONFIG_FILE)
    local reset = readZones()
    local groupsStr = nil
    if reset then
        lines[#lines + 1] = #reset .. " RESET zone(s) found in the AZR file."
        local names, counts = listGroups(reset)
        for _, n in ipairs(names) do
            lines[#lines + 1] = string.format("  group %s: %d zone(s)", n, counts[n:lower()])
        end
        groupsStr = table.concat(names, "|")
    else
        lines[#lines + 1] = "No Admin Zone Reset zones file found."
    end
    report(player, "RealReset status", lines, groupsStr)
end

---------------------------------------------------------------- player warning
local warnCache = { t = nil, reset = {}, protected = {} }
local warnState = {}      -- [username] = { inside = bool, last = ms }
local lastWarnTick = 0
local WARN_EVERY_MS = 5000
local WARN_CACHE_MS = 120000

local function refreshWarnCache(t)
    warnCache.t = t
    local reset, prot = readZones()
    if reset == nil then reset, prot = {}, {} end
    local live = liveSafehouseBoxes()
    if live then for _, b in ipairs(live) do prot[#prot + 1] = b end end
    warnCache.reset, warnCache.protected = reset, prot
end

local function pointIn(boxes, x, y)
    for _, b in ipairs(boxes) do
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return true end
    end
    return false
end

local function warnTick()
    local t = nowMs()
    if t == 0 or (t - lastWarnTick) < WARN_EVERY_MS then return end
    lastWarnTick = t
    local c = loadConfig()
    if not c.warn_players then return end
    local players = getOnlinePlayers()
    if not players then return end
    if not warnCache.t or (t - warnCache.t) > WARN_CACHE_MS then refreshWarnCache(t) end

    local online = {}
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            local name = p:getUsername()
            online[name] = true
            if isAdmin(p) and not c.warn_admins then
                warnState[name] = nil
            else
                local x, y = math.floor(p:getX()), math.floor(p:getY())
                local inside
                if pointIn(warnCache.protected, x, y) then inside = false
                elseif c.warn_mode == "everywhere" then inside = true
                else inside = pointIn(warnCache.reset, x, y) end

                local st = warnState[name]
                if not st then st = { inside = false, last = nil }; warnState[name] = st end
                if inside and not st.inside then
                    if not st.last or (t - st.last) >= c.warn_cooldown_minutes * 60000 then
                        st.last = t
                        sendServerCommand(p, "RealReset", "zoneWarn", { text = c.warn_message, seconds = c.warn_seconds })
                    end
                end
                st.inside = inside
            end
        end
    end
    for name, _ in pairs(warnState) do
        if not online[name] then warnState[name] = nil end
    end
end
if Events.OnTick then Events.OnTick.Add(warnTick) end

Events.OnServerStarted.Add(function()
    loadConfig(true)
    if RealReset_ping then
        print("[RealReset] loaded server-side. " .. RealReset_ping())
        print("[RealReset] " .. RealReset_selfTest())
    else
        print("[RealReset] WARNING: Java side missing - ZombieBuddy or the jar did not load")
    end
end)

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= "RealReset" then return end
    if not isAdmin(player) then
        print("[RealReset] REJECTED '" .. tostring(command) .. "' from non-admin "
              .. tostring(player and player.getUsername and player:getUsername() or "?"))
        return
    end
    if command == "status" then sendStatus(player)
    elseif command == "plan" then runReset(true, player, args and args.group)
    elseif command == "reset" then runReset(false, player, args and args.group)
    elseif command == "runs" then sendRuns(player)
    elseif command == "restorePlan" then runRestore(true, player, args)
    elseif command == "restore" then runRestore(false, player, args)
    elseif command == "cancelQueue" then cancelQueue(player)
    elseif command == "getSettings" then sendSettings(player)
    elseif command == "saveSettings" then saveSettings(player, args)
    end
end)
