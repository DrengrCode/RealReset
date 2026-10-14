local SERVER = arg[1]
local zones = [[
[LV 145]
type=reset
id=a
group=LV
x1=0
y1=0
x2=15
y2=7
z=0
[old]
type=reset
id=b
group=spawn
x1=100
y1=100
x2=107
y2=107
z=0
deleted=1
[Vs 14]
type=reset
id=c
group= vs 
x1=800
y1=800
x2=815
y2=807
z=0
[Vs 15]
type=reset
id=d
group=VS
x1=900
y1=800
x2=907
y2=807
z=0
[nog]
type=reset
id=e
x1=2000
y1=2000
x2=2007
y2=2007
z=0
[prot]
type=protected
id=f
group=LV
x1=8
y1=0
x2=15
y2=7
z=0
]]
-- mocks
local handlers = {}
Events = { OnServerStarted = { Add = function(f) handlers.start = f end },
           OnClientCommand = { Add = function(f) handlers.cmd = f end } }
local function reader(text)
  local lines = {}; for l in (text.."\n"):gmatch("(.-)\n") do lines[#lines+1] = l end
  local i = 0
  return { readLine = function() i = i + 1; return lines[i] end, close = function() end }
end
getFileReader = function() return reader(zones) end
getFileWriter = function() return { write = function() end, close = function() end } end
local adminP = { getAccessLevel = function() return "admin" end, getUsername = function() return "adm" end, getX = function() return 0 end, getY = function() return 0 end }
getOnlinePlayers = function() return { size = function() return 1 end, get = function() return adminP end } end
SafeHouse = { getSafehouseList = function() return { size = function() return 0 end } end }
getChunkSizeInSquares = function() return 8 end
local t = 1000000
getTimestampMs = function() return t end
local sent
sendServerCommand = function(p, m, c, a) sent = a end
local moved = {}
RealReset_ping = function() return "ping" end
RealReset_selfTest = function() return "selftest READY" end
RealReset_isReady = function() return true end
RealReset_pruneTrash = function() return 0 end
RealReset_previewChunk = function(wx, wy) return 1 end
local runs, cur = {}, nil
RealReset_beginRun = function(l) cur = "run_1791940000000__" .. l:gsub("[^%w_-]","_"); runs[cur] = runs[cur] or {}; return cur end
RealReset_endRun = function() local n = 0; for _ in pairs(runs[cur] or {}) do n = n + 1 end; cur = nil; return n end
RealReset_moveChunk = function(wx, wy) runs[cur][wx..","..wy] = true; moved[#moved+1] = wx..","..wy; return 1 end
RealReset_listRuns = function() local o = ""; for id, c in pairs(runs) do local n=0; for _ in pairs(c) do n=n+1 end; if n>0 then o = o .. id .. "|14/10 02:18 test by adm (" .. n .. ");" end end; return o end
RealReset_runChunks = function(id) local o = ""; for k in pairs(runs[id] or {}) do o = o .. k .. ";" end; return o end
RealReset_findLatestRun = function(wx, wy) for id, c in pairs(runs) do if c[wx..","..wy] then return id end end; return "" end
RealReset_restoreChunk = function(id, wx, wy, cs, r, doMove) local c = runs[id]; if not c or not c[wx..","..wy] then return 0 end; if doMove then c[wx..","..wy] = nil end; return 1 end
dofile(SERVER)
local admin = adminP
local function cmd(c, a) sent = nil; handlers.cmd("RealReset", c, admin, a or {}); return sent end
local function show(tag, r) print("== " .. tag); print(r and r.text or "(nothing sent)"); if r and r.runs then print("runs=" .. r.runs) end end
cmd("plan", {group="LV"}); show("reset LV", cmd("reset", {group="LV"}))
local runsr = cmd("runs"); show("runs", runsr)
local id = runsr.runs:match("^([^|]+)|")
show("restore w/o plan", cmd("restore", {run=id}))
show("plan restore", cmd("restorePlan", {run=id}))
show("restore other run", cmd("restore", {run="run_1__x"}))
show("plan restore", cmd("restorePlan", {run=id}))
show("restore", cmd("restore", {run=id}))
show("runs after", cmd("runs"))
-- chunk mode: re-reset then restore one chunk
cmd("plan", {group="Vs"}); cmd("reset", {group="Vs"})
show("plan chunk (100,100) not in trash", cmd("restorePlan", {wx=100, wy=100}))
show("plan chunk 100,100? use 100,100", cmd("restorePlan", {wx=100, wy=100}))
show("plan chunk vs 100,100 has?", cmd("restorePlan", {wx=102, wy=100}))
show("restore chunk 102,100 w/o chunk plan", cmd("restore", {wx=102, wy=100}))
show("bad args", cmd("restorePlan", {}))
