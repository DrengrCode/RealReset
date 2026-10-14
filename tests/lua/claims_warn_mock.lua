-- Tests claimed-vehicle protection and the player warning with fake game functions.
local SERVER = arg[1]
local files = {}
files["AdminZoneReset_ServerZones.txt"] = [[
[LV 1]
type=reset
id=a
group=LV
x1=0
y1=0
x2=63
y2=7
z=0
[prot]
type=protected
id=p
x1=1000
y1=1000
x2=1010
y2=1010
z=0
[big]
type=reset
id=big
group=BIG
x1=4000
y1=4000
x2=4159
y2=4079
z=0
[far]
type=reset
id=b
group=MD
x1=500
y1=500
x2=523
y2=507
z=0
]]
-- SDVC format, copied from SDVC_Database_Server.lua SaveUserJSON
files["SDVC_Claims/_Index.txt"] = '[\n  "alice",\n  "bob"\n]\n'
files["SDVC_Claims/SDVC_Claims_alice.txt"] = '{\n  "101": {"x":20.000000, "y":4.000000, "vehicleName":"Base.PickUpVan", "lastSeen":1790000000}\n}'
files["SDVC_Claims/SDVC_Claims_bob.txt"] = '{\n  "202": {"x":9000.000000, "y":9000.000000, "vehicleName":"Base.CarNormal", "lastSeen":1790000000}\n}'
local written = {}
local handlers, ticks = {}, {}
Events = { OnServerStarted = { Add = function(f) handlers.start = f end },
           OnClientCommand = { Add = function(f) handlers.cmd = f end },
           OnTick = { Add = function(f) ticks[#ticks+1] = f end } }
local function reader(text)
  local lines = {}; for l in (text.."\n"):gmatch("(.-)\n") do lines[#lines+1] = l end
  local i = 0
  return { readLine = function() i = i + 1; return lines[i] end, close = function() end }
end
getFileReader = function(name) if files[name] then return reader(files[name]) end return nil end
getFileWriter = function(name) local buf = {}; return { write = function(_, s) buf[#buf+1] = s end,
  close = function() written[name] = table.concat(buf); if name == "RealReset_Config.txt" then files[name] = written[name] end end } end
local players = {}
local ADMINS = true
getOnlinePlayers = function() return { size = function() return #players end, get = function(_, i) return players[i+1] end } end
SafeHouse = { getSafehouseList = function() return { size = function() return 0 end } end }
getChunkSizeInSquares = function() return 8 end
local t = 1000000
getTimestampMs = function() return t end
local sent, warns, qstates = nil, {}, {}
sendServerCommand = function(p, m, c, a)
  if c == "zoneWarn" then warns[#warns+1] = { p:getUsername(), a.text, a.seconds }
  elseif c == "queueState" then qstates[#qstates+1] = { p:getUsername(), a }
  else sent = a end
end
RealReset_ping = function() return "ping" end
RealReset_selfTest = function() return "READY" end
RealReset_isReady = function() return true end
RealReset_pruneTrash = function() return 0 end
local noFileBelow = nil
RealReset_previewChunk = function(wx) if noFileBelow and wx < noFileBelow then return 0 end return 1 end
local moved = {}
RealReset_beginRun = function(l) return "run_1791940000000__" .. l:gsub("[^%w_-]","_") end
local ceilUsed, ceilMax = 0, 150
RealReset_ceilingInfo = function() return ceilUsed .. "|" .. ceilMax .. "|30" end
RealReset_endRun = function() return 0 end
RealReset_moveChunk = function(wx, wy) moved[#moved+1] = wx..","..wy; ceilUsed = ceilUsed + 1; return 1 end
RealReset_listRuns = function() return "" end
dofile(SERVER)
handlers.start()
print("config file created:", written["RealReset_Config.txt"] ~= nil)
local admin = { getAccessLevel = function() return "admin" end, getUsername = function() return "adm" end, getX = function() return 0 end, getY = function() return 0 end }
players = { admin }
local function cmd(c, a) sent = nil; handlers.cmd("RealReset", c, admin, a or {}); return sent end
local function fail(m) print("FAIL: " .. m); os.exit(1) end

-- 1. claim at tile 20,4 (+-16) covers x 4..36, y -12..20 => chunks wx 0..4, wy -2..2 ; LV zone is wx 0..7, wy 0 => 8 chunks, 5 skipped
local r = cmd("plan", {group="LV"})
print(r.text)
if not r.text:find("near a claimed vehicle %(Sunday Driver%): 5") then fail("expected 5 claim skips") end
if not r.text:find("Would move: 3 chunk") then fail("expected 3 movable") end
if not r.text:find("alice: Base.PickUpVan at 20,4") then fail("claim detail missing") end
cmd("reset", {group="LV"})
local m = {}; for _, c in ipairs(moved) do m[c] = true end
if not (m["5,0"] and m["6,0"] and m["7,0"]) or m["4,0"] or m["0,0"] then fail("wrong chunks moved: " .. table.concat(moved, " ")) end
print("moved:", table.concat(moved, " "))

-- 2. setting off => nothing skipped for claims
files["RealReset_Config.txt"] = "protect_claimed_vehicles=false\nwarn_message=Custom words here = ok\nwarn_mode=everywhere\nwarn_admins=false\n"
t = t + 61000
r = cmd("plan", {group="LV"})   -- runReset forces reload
if not r.text:find("Claimed%-vehicle protection is OFF") then fail("OFF notice missing") end
if not r.text:find("Would move: 8 chunk") then fail("expected 8 with protection off") end

-- 3. broken claims data (bob listed, file gone) => PLAN warns, RESET refuses
files["RealReset_Config.txt"] = "protect_claimed_vehicles=true\n"
files["SDVC_Claims/SDVC_Claims_bob.txt"] = nil
r = cmd("plan", {group="LV"})
if not r.text:find("WARNING: Sunday Driver claim file missing") then fail("missing-file warning absent") end
r = cmd("reset", {group="LV"})
if not r.text:find("RESET REFUSED") then fail("expected refusal on unreadable claims") end
print("refusal ok:", r.text)

-- 4. no SDVC at all => harmless
files["SDVC_Claims/_Index.txt"] = nil
r = cmd("plan", {group="LV"})
if not r.text:find("nothing to protect") then fail("no-SDVC note missing") end
if not r.text:find("Would move: 8 chunk") then fail("expected 8 without SDVC") end

-- 5. status shows settings
r = cmd("status"); if not r.text:find("Player warning: on %(zones%)") then fail("status line missing") end

-- 6. warnings
files["RealReset_Config.txt"] = "warn_message=Custom words here = ok\n"
t = t + 61000
local function player(name, x, y, adminLevel) return { getUsername = function() return name end, getX = function() return x end, getY = function() return y end,
   getAccessLevel = function() return adminLevel or "" end } end
local pIn, pOut, pAdm = player("inside", 10, 3), player("outside", 300, 300), player("boss", 10, 3, "admin")
players = { pIn, pOut, pAdm }
local qtick, tick = ticks[1], ticks[2]
tick()
if #warns ~= 1 or warns[1][1] ~= "inside" then fail("expected one warning to 'inside', got " .. #warns) end
if warns[1][2] ~= "Custom words here = ok" then fail("custom wording not used: " .. tostring(warns[1][2])) end
t = t + 1000; tick(); if #warns ~= 1 then fail("throttle/once-per-entry broken") end
t = t + 6000; tick(); if #warns ~= 1 then fail("repeated warning while staying inside") end
-- leaves, re-enters within cooldown => no repeat; after cooldown => warns again
players = { player("inside", 300, 300) }; t = t + 6000; tick()
players = { player("inside", 10, 3) };    t = t + 6000; tick()
if #warns ~= 1 then fail("cooldown not honoured") end
players = { player("inside", 300, 300) }; t = t + 6000; tick()
t = t + 11 * 60000
players = { player("inside", 10, 3) };    tick()
if #warns ~= 2 then fail("expected second warning after cooldown, got " .. #warns) end
-- protected zone beats everywhere mode
files["RealReset_Config.txt"] = "warn_mode=everywhere\nwarn_cooldown_minutes=0\n"
t = t + 61000
players = { player("p1", 1005, 1005), player("p2", 4000, 4000) }; local before = #warns; tick()
if #warns ~= before + 1 or warns[#warns][1] ~= "p2" then fail("everywhere/protected logic wrong") end
-- warn_admins
files["RealReset_Config.txt"] = "warn_admins=true\nwarn_cooldown_minutes=0\n"
t = t + 61000
players = { player("boss", 10, 3, "admin") }; before = #warns; tick()
if #warns ~= before + 1 then fail("warn_admins=true should warn admin") end
-- off
files["RealReset_Config.txt"] = "warn_players=false\n"
t = t + 61000
players = { player("new", 10, 3) }; before = #warns; tick()
if #warns ~= before then fail("warn_players=false still warned") end
-- 7. in-game settings
files["RealReset_Config.txt"] = nil
t = t + 61000
local got
local oldSend = sendServerCommand
sendServerCommand = function(p, m, c, a) if c == "settings" then got = a else oldSend(p, m, c, a) end end
handlers.cmd("RealReset", "getSettings", admin, {})
if not got or got.warn ~= true or got.protect ~= true then fail("getSettings payload wrong") end
handlers.cmd("RealReset", "saveSettings", admin, { protect = false, warn = true, warnAdmins = true, mode = "everywhere",
    buffer = 500, seconds = 1, cooldown = 3, message = "Line one\nLine two = fine" })
if got.note ~= "Saved." then fail("no Saved note") end
if got.protect ~= false or got.mode ~= "everywhere" or got.buffer ~= 64 or got.seconds ~= 3 or got.cooldown ~= 3 then
  fail("values not applied/clamped") end
if got.message ~= "Line one Line two = fine" then fail("message not cleaned: " .. tostring(got.message)) end
local f = written["RealReset_Config.txt"]
if not f or not f:find("warn_mode=everywhere") or not f:find("protect_claimed_vehicles=false") then fail("file not written") end
-- a non-admin cannot change settings
local before = written["RealReset_Config.txt"]
handlers.cmd("RealReset", "saveSettings", { getAccessLevel = function() return "" end, getUsername = function() return "x" end }, { protect = true })
if written["RealReset_Config.txt"] ~= before then fail("non-admin changed settings") end
-- the saved file reads back the same
t = t + 61000
handlers.cmd("RealReset", "getSettings", admin, {})
if got.protect ~= false or got.mode ~= "everywhere" or got.message ~= "Line one Line two = fine" then fail("round trip failed") end
-- 8. the RESET queue
files["RealReset_Config.txt"] = "protect_claimed_vehicles=false\n"
files["SDVC_Claims/_Index.txt"] = nil
t = t + 61000
players = { admin }
moved = {}; ceilUsed = 0
r = cmd("plan", {group="BIG"})
if not r.text:find("Would move: 200 chunk") then fail("expected 200 in plan: " .. r.text) end
if not r.text:find("Safety limit: 0 of 150") then fail("plan should show the safety limit") end
if not r.text:find("queue these") then fail("plan should explain queueing") end
r = cmd("reset", {group="BIG"})
if not r.text:find("RESET running") then fail("expected RESET running: " .. r.text) end
if #moved ~= 150 then fail("first step should stop at the limit (150), moved " .. #moved) end
-- a second reset or a restore while it runs is refused
r = cmd("plan", {group="BIG"}); if not r.text:find("already running") then fail("plan during queue") end
r = cmd("restorePlan", {run="x"}); if not r.text:find("A reset is running") then fail("restore during queue") end
r = cmd("status"); if not r.text:find("RESET RUNNING") then fail("status should show the queue") end
-- steps are throttled
qtick(); if #moved ~= 150 then fail("step ran too early") end
local guard = 0
while #moved < 150 and guard < 20 do t = t + 1100; qtick(); guard = guard + 1 end
if #moved ~= 150 then fail("should stop at the safety limit, moved " .. #moved) end
t = t + 1100; qtick(); t = t + 1100; qtick()
if #moved ~= 150 then fail("moved past the safety limit") end
r = cmd("status"); if not r.text:find("waiting for the safety limit") then fail("status should say waiting: " .. r.text) end
-- time passes, the limit frees up
ceilUsed = 0; guard = 0
sent = nil
while #moved < 200 and guard < 20 do t = t + 1100; qtick(); guard = guard + 1 end
t = t + 1100; qtick()
if #moved ~= 200 then fail("queue did not finish, moved " .. #moved) end
if not sent or not sent.text:find("RESET DONE") or not sent.text:find("Moved to trash: 200") then fail("no DONE report: " .. tostring(sent and sent.text)) end
if sent.queue ~= false then fail("queue flag should be false when done") end
print("queue finished:", sent.text:match("Moved to trash: %d+ chunk%(s%)"))
-- cancel
moved = {}; ceilUsed = 145
t = t + 61000
cmd("plan", {group="BIG"}); cmd("reset", {group="BIG"})
if #moved ~= 5 then fail("expected 5 moves up to the limit, got " .. #moved) end
r = cmd("cancelQueue")
if not r.text:find("RESET STOPPED") or not r.text:find("cancelled") then fail("cancel report: " .. r.text) end
if r.queue ~= false then fail("queue flag after cancel") end
r = cmd("plan", {group="BIG"}); if r.text:find("already running") then fail("queue should be gone after cancel") end
-- queue pauses if a new safehouse covers the rest
moved = {}; ceilUsed = 0; ceilMax = 100; t = t + 61000
cmd("plan", {group="BIG"}); cmd("reset", {group="BIG"})
local first = #moved
ceilUsed = 0   -- time passes, the limit frees up
SafeHouse = { getSafehouseList = function() return { size = function() return 1 end, get = function() return { getX = function() return 4000 end, getY = function() return 4000 end, getX2 = function() return 4159 end, getY2 = function() return 4079 end } end } end }
t = t + 1100; qtick()
if #moved ~= first then fail("moves continued into a new safehouse: " .. #moved) end
-- never-saved chunks are not queued and do not use up the cap
SafeHouse = { getSafehouseList = function() return { size = function() return 0 end } end }
queue_cleanup = cmd("cancelQueue")
noFileBelow = 510; moved = {}; ceilUsed = 0; ceilMax = 3000; t = t + 61000
r = cmd("plan", {group="BIG"})
if not r.text:find("Would move: 100 chunk") then fail("plan with 100 saved chunks: " .. r.text) end
r = cmd("reset", {group="BIG"})
local g2 = 0
while #moved < 100 and g2 < 10 do t = t + 1100; qtick(); g2 = g2 + 1 end
if #moved ~= 100 then fail("expected only the 100 saved chunks moved, got " .. #moved) end
-- 9. RESTORE is a queue too
local batch = "run_1791940000000__BIG_by_adm"
local list = ""
for i = 0, 249 do list = list .. (6000 + i) .. "," .. 6000 .. ";" end
RealReset_runChunks = function(id) return list end
RealReset_findLatestRun = function() return batch end
RealReset_listRuns = function() return batch .. "|14/10 BIG by adm (250);" end
local restoredN = 0
RealReset_restoreChunk = function(id, wx, wy, cs, r, doMove) if doMove then ceilUsed = ceilUsed + 1; restoredN = restoredN + 1 end return 1 end
noFileBelow = nil; ceilUsed = 0; ceilMax = 100; t = t + 61000
r = cmd("restorePlan", {run=batch})
if not r.text:find("Would restore: 250") then fail("restore plan: " .. r.text) end
if not r.text:find("queue these") then fail("restore plan should explain queueing: " .. r.text) end
r = cmd("restore", {run=batch})
if not r.text:find("RESTORE running") then fail("expected RESTORE running: " .. r.text) end
if restoredN ~= 100 then fail("first restore step should stop at the limit, did " .. restoredN) end
if not cmd("status").text:find("RESTORE RUNNING") then fail("status should show the restore queue") end
r = cmd("plan", {group="BIG"}); if not r.text:find("restore is already running") then fail("plan during restore: " .. r.text) end
ceilUsed = 0; local g3 = 0
while restoredN < 200 and g3 < 10 do t = t + 1100; qtick(); g3 = g3 + 1 end
ceilUsed = 0; g3 = 0
sent = nil
while restoredN < 250 and g3 < 10 do t = t + 1100; qtick(); g3 = g3 + 1 end
t = t + 1100; qtick()
if restoredN ~= 250 then fail("restore queue incomplete: " .. restoredN) end
if not sent or not sent.text:find("RESTORE DONE") or not sent.text:find("Restored: 250") then fail("restore final report: " .. tostring(sent and sent.text)) end
if sent.queue ~= false then fail("queue flag after restore") end
-- 10. other admins are told about the queue (their panels lock)
local admin2 = { getAccessLevel = function() return "admin" end, getUsername = function() return "adm2" end, getX = function() return 0 end, getY = function() return 0 end }
local plain = { getAccessLevel = function() return "" end, getUsername = function() return "joe" end, getX = function() return 0 end, getY = function() return 0 end }
players = { admin, admin2, plain }
qstates = {}; moved = {}; ceilUsed = 0; ceilMax = 100; noFileBelow = nil; t = t + 61000
cmd("plan", {group="BIG"}); cmd("reset", {group="BIG"})
local got2, gotPlain = nil, false
for _, q in ipairs(qstates) do
  if q[1] == "adm2" then got2 = q[2] end
  if q[1] == "joe" then gotPlain = true end
end
if not got2 or got2.active ~= true or got2.who ~= "adm" or got2.total ~= 200 then fail("other admin should be told a queue started") end
if gotPlain then fail("players who are not admins must not get queue state") end
local r2 = cmd("cancelQueue")
local last2
for _, q in ipairs(qstates) do if q[1] == "adm2" then last2 = q[2] end end
if not last2 or last2.active ~= false then fail("other admin should be told the queue ended") end
-- the starter's own reply also carries the queue info
if not r2.qinfo or r2.qinfo.active ~= false then fail("reply should carry qinfo") end
print("ALL PASS (claims + warnings + settings + queue + restore queue + admin lock)")
