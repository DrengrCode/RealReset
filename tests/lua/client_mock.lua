local CLIENT = arg[1]
require = function() end
local handlers = {}
Events = { OnFillWorldObjectContextMenu = { Add = function(f) handlers.menu = f end },
           OnServerCommand = { Add = function(f) handlers.srv = f end } }
local function class(name)
  local C = {}; C.__index = C
  function C:derive(n) local D = {}; D.__index = D; setmetatable(D, {__index = self}); return D end
  function C:new(...) local o = setmetatable({}, self); o.args = {...}; o.children = {}; return o end
  return C
end
ISPanel = class(); ISTickBox = class(); ISTextEntryBox = class(); ISCollapsableWindow = class(); ISButton = class(); ISRichTextPanel = class(); ISModalDialog = class(); ISScrollingListBox = class()
function ISCollapsableWindow:new(x,y,w,h) local o = setmetatable({}, self); o.width=w; o.height=h; o.children={}; return o end
function ISCollapsableWindow:createChildren() end
function ISCollapsableWindow:render() end
function ISCollapsableWindow:drawText() end
function ISCollapsableWindow:titleBarHeight() return 16 end
function ISCollapsableWindow:addChild(c) table.insert(self.children, c) end
function ISCollapsableWindow:initialise() end
function ISCollapsableWindow:addToUIManager() end
function ISCollapsableWindow:setVisible() end
function ISCollapsableWindow:close() end
function ISButton:new(x,y,w,h,title,target,fn) local o = setmetatable({}, self); o.title=title; o.target=target; o.fn=fn; return o end
function ISButton:initialise() end
function ISButton:setTitle(t) self.title = t end
function ISButton:setEnable(v) self.enabled = v end
function ISRichTextPanel:new() local o = setmetatable({}, self); return o end
function ISRichTextPanel:initialise() end
function ISRichTextPanel:addScrollBars() end
function ISRichTextPanel:paginate() end
function ISScrollingListBox:new() local o = setmetatable({}, self); o.items = {}; o.selected = 1; return o end
function ISScrollingListBox:initialise() end
function ISScrollingListBox:instantiate() end
function ISScrollingListBox:clear() self.items = {}; self.selected = 1 end
function ISScrollingListBox:addItem(name, item) table.insert(self.items, { text = name, item = item, index = #self.items + 1 }) end
function ISScrollingListBox:setOnMouseDownFunction(t, fn) self.cbT = t; self.cbF = fn end
function ISScrollingListBox:click(i) self.selected = i; self.cbF(self.cbT, self.items[i].item) end
function ISPanel.new(cls, x,y,w,h) local o = setmetatable({}, cls); o.x=x;o.y=y;o.width=w;o.height=h;o.children={}; return o end
function ISPanel:initialise() end
function ISPanel:addChild(c) table.insert(self.children, c) end
function ISPanel:addToUIManager() self.shown = true end
function ISPanel:removeFromUIManager() self.shown = false end
function ISPanel:drawText(t) self.drawn = (self.drawn or 0) + 1 end
getTextManager = function() return { MeasureStringX = function(_, f, s) return #s * 6 end, getFontHeight = function() return 14 end } end
local nowT = 1000
getTimestampMs = function() return nowT end
function ISTickBox:new(x,y,w,h,t,target,fn) local o = setmetatable({}, self); o.opts = {}; o.sel = {}; return o end
function ISTickBox:initialise() end
function ISTickBox:instantiate() end
function ISTickBox:addOption(n) self.opts[#self.opts+1] = n end
function ISTickBox:setSelected(i, v) self.sel[i] = v end
function ISTickBox:isSelected(i) return self.sel[i] == true end
function ISTextEntryBox:new(t,x,y,w,h) local o = setmetatable({}, self); o.text = t or ""; return o end
function ISTextEntryBox:initialise() end
function ISTextEntryBox:instantiate() end
function ISTextEntryBox:setText(t) self.text = t end
function ISTextEntryBox:getText() return self.text end
function ISTextEntryBox:setMultipleLine() end
function ISTextEntryBox:setMaxLines() end
for _, C in ipairs({ ISButton, ISTickBox, ISTextEntryBox, ISRichTextPanel, ISScrollingListBox }) do
  function C:setVisible(v) self.visible = v end
end
UIFont = { Small = 1 }
local sent = {}
sendClientCommand = function(p, m, c, a) sent[#sent+1] = { c, a } end
local player = { getX = function() return 12095.4 end, getY = function() return 6791.9 end }
getPlayer = function() return player end
getSpecificPlayer = function() return { getAccessLevel = function() return "admin" end } end
getCore = function() return { getScreenWidth = function() return 1920 end, getScreenHeight = function() return 1080 end } end
dofile(CLIENT)
local function titles(p) return p.statusBtn.title .. " / " .. p.planBtn.title .. " / " .. p.resetBtn.title end
local function items(p) local t = {} for _, it in ipairs(p.list.items) do t[#t+1] = it.text .. "=" .. tostring(it.item) end return table.concat(t, " | ") end

local p = RealResetPanel:new(0, 0, 600, 440)
p.out = nil
p:createChildren()
print("start:", titles(p), "| list:", items(p))
handlers.srv("RealReset", "result", { text = "status text", groups = "DIX|LV|Vs" })
RealResetPanel.instance = p
handlers.srv("RealReset", "result", { text = "status text", groups = "DIX|LV|Vs" })
print("groups:", items(p))
p.list:click(3); print("clicked LV -> groupSel =", p.groupSel)
p:onPlan(); print("plan sent:", sent[#sent][1], sent[#sent][2].group)
-- restore mode
p:onModeRestore(); print("restore:", titles(p), "| list:", items(p), "| sent:", sent[#sent][1])
handlers.srv("RealReset", "result", { text = "batches", runs = "run_1__a|14/10 02:18 test by adm (77);run_2__b|14/10 02:07 LV by adm (12);" })
print("runs:", items(p))
print("restoreArgs with no batch:", p:restoreArgs() and "args" or "nil")
p:onPlan(); print("plan with no batch -> sent still:", sent[#sent][1])
p.list:click(1)
p.list:click(2); print("clicked run ->", p.runSel); local a = p:restoreArgs(); print("args run =", a.run)
p:onPlan(); print("plan run sent:", sent[#sent][1], sent[#sent][2].run)
p:onRestoreConfirm({ internal = "YES" }); print("restore sent:", sent[#sent][1], sent[#sent][2].run)
handlers.srv("RealReset", "result", { text = "done", runs = "" })
print("after restore list:", items(p), "| runSel:", p.runSel)
p:onModeReset(); print("back to reset:", titles(p), "| list:", items(p), "| groupSel:", p.groupSel)
p:onResetConfirm({ internal = "YES" }); print("reset sent:", sent[#sent][1], sent[#sent][2].group)
handlers.menu(0, { addOption = function(self, t) print("menu option:", t) end }, {}, false)

-- player zone notice
handlers.srv("RealReset", "zoneWarn", { text = "Heads-up: this area can be reset by admins. Items left here may be removed. Safehouses and claimed vehicles are protected.", seconds = 15 })
local n = RealResetNotice.instance
print("notice shown:", n.shown, "lines:", #n.lines, "h:", n.height, "x:", n.x)
n:render(); print("drawn lines:", n.drawn)
nowT = 1000 + 14000; n:update(); print("at 14s still shown:", n.shown)
nowT = 1000 + 15500; n:update(); print("at 15.5s shown:", n.shown, "instance:", RealResetNotice.instance)
handlers.srv("RealReset", "zoneWarn", { text = "one", seconds = 15 })
local a = RealResetNotice.instance
handlers.srv("RealReset", "zoneWarn", { text = "two", seconds = 15 })
print("replaced old:", a.shown == false and RealResetNotice.instance ~= a)
RealResetNotice.instance.children[1].fn(RealResetNotice.instance.children[1].target)
print("X closes:", RealResetNotice.instance)

-- settings screen
local q = RealResetPanel:new(0, 0, 600, 440); q.out = nil; q:createChildren(); RealResetPanel.instance = q
q:onModeSettings()
print("settings mode: list visible:", q.list.visible, "| toggle visible:", q.togBtn[1].visible, "| asked:", sent[#sent][1])
handlers.srv("RealReset", "settings", { protect = true, buffer = 16, warn = true, mode = "zones", warnAdmins = false, seconds = 15, cooldown = 10, message = "Hello there" })
print("loaded:", q.tog[1], q.tog[2], q.tog[3], q.msgEntry:getText(), q.bufEntry:getText(), q.setModeBtn.title, "|", q.togBtn[3].title)
q:onToggle(q.togBtn[3]); q:onToggleWarnMode(); q.msgEntry:setText("New words"); q.secEntry:setText("20")
q:onSaveSettings()
local a = sent[#sent]
print("save sent:", a[1], a[2].protect, a[2].warn, a[2].warnAdmins, a[2].mode, a[2].buffer, a[2].seconds, a[2].cooldown, a[2].message)
q:onTestNotice(); print("test notice shown:", RealResetNotice.instance and RealResetNotice.instance.shown)
q:onDefaultWording(); print("default wording:", q.msgEntry:getText():sub(1, 30))
q:render()
q:onModeReset(); print("back: list visible:", q.list.visible, "| toggle visible:", q.togBtn[1].visible)
print("toggle title after click:", q.togBtn[3].title)

-- queue running: the RESET NOW button becomes CANCEL QUEUE
local c = RealResetPanel:new(0, 0, 600, 440); c.out = nil; c:createChildren(); RealResetPanel.instance = c
handlers.srv("RealReset", "result", { text = "RESET running", queue = true })
print("queue on:", c.resetBtn.title)
c:onReset(); print("cancel sent:", sent[#sent][1])
handlers.srv("RealReset", "result", { text = "RESET DONE", queue = false })
print("queue off:", c.resetBtn.title)

c:onModeRestore()
handlers.srv("RealReset", "result", { text = "RESTORE running", queue = true })
print("restore queue on:", c.resetBtn.title)
handlers.srv("RealReset", "result", { text = "RESTORE DONE", queue = false })
print("restore queue off:", c.resetBtn.title)

-- another admin's queue locks planning here, and unlocks when it ends
c:onModeReset()
player.getUsername = function() return "me" end
handlers.srv("RealReset", "queueState", { active = true, kind = "reset", group = "ALL", who = "otheradmin", done = 40, total = 400 })
print("locked by other admin: plan enabled =", c.planBtn.enabled, "| button:", c.resetBtn.title)
c:render()
handlers.srv("RealReset", "queueState", { active = false })
print("unlocked: plan enabled =", c.planBtn.enabled, "| button:", c.resetBtn.title)
