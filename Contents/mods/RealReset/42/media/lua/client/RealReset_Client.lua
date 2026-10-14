-- RealReset! client side (v0.4.2): a small admin panel, plus the player zone notice.
-- All real checks happen on the server.
-- Open it: right-click the ground in the world as an admin -> "RealReset! (chunk reset)".
-- RESET mode: pick a zone group, PLAN, RESET NOW.
-- RESTORE mode: pick a saved batch, PLAN RESTORE, RESTORE NOW.
-- SETTINGS: protection and player-warning options, saved to RealReset_Config.txt on the server.

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"
require "ISUI/ISRichTextPanel"
require "ISUI/ISModalDialog"
require "ISUI/ISPanel"
require "ISUI/ISTextEntryBox"

RealResetPanel = ISCollapsableWindow:derive("RealResetPanel")
RealResetPanel.instance = nil
RealResetPanel.lastText = "Press STATUS to check the server."
RealResetPanel.lastGroups = nil   -- "LV|MD|WP" from the server
RealResetPanel.lastRuns = nil     -- "id|description;id|description;" from the server
RealResetPanel.queueActive = false  -- a RESET / RESTORE queue is running on the server
RealResetPanel.queueInfo = nil      -- { active, kind, group, who, done, total } from the server
RealResetPanel.settings = nil     -- last settings table sent by the server

local function isAdminPlayer(p)
    local lvl = p and p.getAccessLevel and p:getAccessLevel()
    return lvl ~= nil and tostring(lvl):lower() == "admin"
end

---------------------------------------------------------------- selection state

function RealResetPanel:selectedGroup()
    return self.groupSel or "ALL"
end

function RealResetPanel:restoreArgs()
    if self.runSel == nil then return nil end
    return { run = self.runSel }
end

-- Rebuild the left-hand list for the current mode, keeping the selection if possible.
function RealResetPanel:refreshList()
    if not self.list then return end
    self.list:clear()
    if self.mode == "restore" then
        for id, disp in string.gmatch(RealResetPanel.lastRuns or "", "([^|;]+)|([^;]+);") do
            self.list:addItem(disp, id)
        end
        local keep = self.runSel
        self.list.selected = 1
        for i, it in ipairs(self.list.items) do
            if it.item == keep then self.list.selected = i end
        end
        local cur = self.list.items[self.list.selected]
        self.runSel = cur and cur.item or nil
    else
        self.list:addItem("ALL", "ALL")
        for g in string.gmatch(RealResetPanel.lastGroups or "", "[^|]+") do self.list:addItem(g, g) end
        local keep = self.groupSel or "ALL"
        self.list.selected = 1
        for i, it in ipairs(self.list.items) do
            if it.item == keep then self.list.selected = i end
        end
        local cur = self.list.items[self.list.selected]
        self.groupSel = cur and cur.item or "ALL"
    end
end

-- Clicking a row: the game passes us the value we stored with addItem.
function RealResetPanel:onListClick(item)
    if type(item) ~= "string" or item == "" then return end
    if self.mode == "restore" then
        self.runSel = item
        self:setText("Batch selected.\nPress PLAN RESTORE to see what would come back.")
    else
        self.groupSel = item
        self:setText("Group: " .. item .. "\nPress PLAN to see what would be reset.")
    end
end

---------------------------------------------------------------- settings screen
local function newEntry(parent, x, y, w, h)
    local e = ISTextEntryBox:new("", x, y, w, h)
    e:initialise()
    e:instantiate()
    parent:addChild(e)
    return e
end

local TOGGLE_LABELS = {
    "Protect claimed vehicles (Sunday Driver)",
    "Warn players when they enter a reset zone",
    "Also show the warning to admins (for testing)",
}

function RealResetPanel:toggleTitle(i)
    return (self.tog[i] and "[ ON ]  " or "[ OFF ]  ") .. TOGGLE_LABELS[i]
end

function RealResetPanel:onToggle(button)
    local i = button.toggleIndex
    self.tog[i] = not self.tog[i]
    button:setTitle(self:toggleTitle(i))
end

function RealResetPanel:createSettingsControls(top)
    local x = 20
    local sy = top + 56
    self.tog = { true, true, false }
    self.togBtn = {}
    for i = 1, 3 do
        local btn = ISButton:new(x, sy + (i - 1) * 30, 400, 24, "", self, RealResetPanel.onToggle)
        btn.toggleIndex = i
        btn:initialise()
        btn:setTitle(self:toggleTitle(i))
        self:addChild(btn)
        self.togBtn[i] = btn
    end

    self.setModeBtn = ISButton:new(x, sy + 94, 400, 24, "Warn where: reset zones only", self, RealResetPanel.onToggleWarnMode)
    self.setModeBtn:initialise(); self:addChild(self.setModeBtn)

    self.bufEntry  = newEntry(self, 300, sy + 128, 50, 22)
    self.secEntry  = newEntry(self, 300, sy + 154, 50, 22)
    self.coolEntry = newEntry(self, 300, sy + 180, 50, 22)
    self.msgEntry  = newEntry(self, x, sy + 232, self.width - 40, 58)
    pcall(function() self.msgEntry:setMultipleLine(true); self.msgEntry:setMaxLines(4) end)

    local by = sy + 300
    self.setSaveBtn = ISButton:new(x, by, 120, 26, "SAVE", self, RealResetPanel.onSaveSettings)
    self.setSaveBtn:initialise(); self:addChild(self.setSaveBtn)
    self.setTestBtn = ISButton:new(x + 130, by, 130, 26, "TEST NOTICE", self, RealResetPanel.onTestNotice)
    self.setTestBtn:initialise(); self:addChild(self.setTestBtn)
    self.setDefBtn = ISButton:new(x + 270, by, 150, 26, "DEFAULT WORDING", self, RealResetPanel.onDefaultWording)
    self.setDefBtn:initialise(); self:addChild(self.setDefBtn)

    self.setNote = ""
    self.setMode = "zones"
    self.setBase = sy
    self:applyModeVisibility()
end

local SETTINGS_WIDGETS = { "setModeBtn", "bufEntry", "secEntry", "coolEntry", "msgEntry",
                           "setSaveBtn", "setTestBtn", "setDefBtn" }
local RESET_WIDGETS = { "list", "out", "statusBtn", "planBtn", "resetBtn" }

function RealResetPanel:applyModeVisibility()
    local settings = (self.mode == "settings")
    for _, k in ipairs(SETTINGS_WIDGETS) do
        if self[k] then self[k]:setVisible(settings) end
    end
    if self.togBtn then
        for _, b in ipairs(self.togBtn) do b:setVisible(settings) end
    end
    for _, k in ipairs(RESET_WIDGETS) do
        if self[k] then self[k]:setVisible(not settings) end
    end
end

function RealResetPanel:applySettings(d)
    if not d or not self.togBtn then return end
    self.tog = { d.protect ~= false, d.warn ~= false, d.warnAdmins == true }
    for i = 1, 3 do self.togBtn[i]:setTitle(self:toggleTitle(i)) end
    self.setMode = (d.mode == "everywhere") and "everywhere" or "zones"
    self:updateModeButton()
    self.bufEntry:setText(tostring(d.buffer or 16))
    self.secEntry:setText(tostring(d.seconds or 15))
    self.coolEntry:setText(tostring(d.cooldown or 10))
    self.msgEntry:setText(tostring(d.message or ""))
    self.setNote = d.note or ""
end

function RealResetPanel:updateModeButton()
    self.setModeBtn:setTitle(self.setMode == "everywhere"
        and "Warn where: everywhere (full reset)" or "Warn where: reset zones only")
end

function RealResetPanel:onToggleWarnMode()
    self.setMode = (self.setMode == "everywhere") and "zones" or "everywhere"
    self:updateModeButton()
end

function RealResetPanel:onSaveSettings()
    sendClientCommand(getPlayer(), "RealReset", "saveSettings", {
        protect = self.tog[1],
        warn = self.tog[2],
        warnAdmins = self.tog[3],
        mode = self.setMode,
        buffer = tonumber(self.bufEntry:getText()),
        seconds = tonumber(self.secEntry:getText()),
        cooldown = tonumber(self.coolEntry:getText()),
        message = self.msgEntry:getText(),
    })
    self.setNote = "Saving..."
end

function RealResetPanel:onTestNotice()
    RealResetNotice.show(self.msgEntry:getText(), tonumber(self.secEntry:getText()) or 15)
end

function RealResetPanel.defaultWording()
    return "Heads-up: this area can be reset by admins. Items left here may be removed. Safehouses and claimed vehicles are protected."
end

function RealResetPanel:onDefaultWording()
    self.msgEntry:setText(RealResetPanel.defaultWording())
end

function RealResetPanel:onModeSettings()
    self.mode = "settings"
    self:applyModeVisibility()
    self:applyModeTitles()
    if RealResetPanel.settings then self:applySettings(RealResetPanel.settings) end
    sendClientCommand(getPlayer(), "RealReset", "getSettings", {})
    self.setNote = "Loading..."
end

function RealResetPanel:renderSettings()
    local sy = self.setBase
    local x = 20
    self:drawText("Saved on the server (RealReset_Config.txt). Takes effect within a minute.", x, self.listTop + 32, 0.8, 0.8, 0.8, 1, UIFont.Small)
    self:drawText("Claim buffer (tiles around a claimed car):", x, sy + 130, 1, 1, 1, 1, UIFont.Small)
    self:drawText("Notice stays up (seconds):", x, sy + 156, 1, 1, 1, 1, UIFont.Small)
    self:drawText("Gap before it can show again (minutes):", x, sy + 182, 1, 1, 1, 1, UIFont.Small)
    self:drawText("Warning wording (shown to players):", x, sy + 212, 1, 1, 1, 1, UIFont.Small)
    if self.setNote and self.setNote ~= "" then
        self:drawText(self.setNote, x + 440, sy + 306, 0.7, 1, 0.7, 1, UIFont.Small)
    end
end

---------------------------------------------------------------- layout

function RealResetPanel:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.mode = self.mode or "reset"
    self.groupSel = self.groupSel or "ALL"
    local top = self:titleBarHeight() + 8
    self.listTop = top

    -- left column: list (groups, or saved batches)
    self.list = ISScrollingListBox:new(10, top + 20, 150, self.height - top - 30)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = 22
    self.list.selected = 1
    self.list.joypadParent = self
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    self.list:setOnMouseDownFunction(self, RealResetPanel.onListClick)
    self:addChild(self.list)

    -- right column
    local rx = 170
    local bw = (self.width - rx - 10 - 20) / 3
    local tw = (self.width - rx - 10 - 20) / 3        -- top row has three buttons
    local y0 = top
    local y1 = top + 30

    self.modeResetBtn = ISButton:new(rx, y0, tw, 26, "RESET", self, RealResetPanel.onModeReset)
    self.modeResetBtn:initialise(); self:addChild(self.modeResetBtn)
    self.modeRestoreBtn = ISButton:new(rx + 10 + tw, y0, tw, 26, "RESTORE", self, RealResetPanel.onModeRestore)
    self.modeRestoreBtn:initialise(); self:addChild(self.modeRestoreBtn)
    self.modeSettingsBtn = ISButton:new(rx + 20 + tw * 2, y0, tw, 26, "SETTINGS", self, RealResetPanel.onModeSettings)
    self.modeSettingsBtn:initialise(); self:addChild(self.modeSettingsBtn)

    self.statusBtn = ISButton:new(rx, y1, bw, 26, "STATUS", self, RealResetPanel.onStatus)
    self.statusBtn:initialise(); self:addChild(self.statusBtn)
    self.planBtn = ISButton:new(rx + 10 + bw, y1, bw, 26, "1. PLAN", self, RealResetPanel.onPlan)
    self.planBtn:initialise(); self:addChild(self.planBtn)
    self.resetBtn = ISButton:new(rx + 20 + bw * 2, y1, bw, 26, "2. RESET NOW", self, RealResetPanel.onReset)
    self.resetBtn:initialise(); self:addChild(self.resetBtn)

    local ty = y1 + 36
    self.out = ISRichTextPanel:new(rx, ty, self.width - rx - 10, self.height - ty - 30)
    self.out:initialise()
    self.out.autosetheight = false
    self.out.clip = true
    self.out:addScrollBars()
    self.out.background = true
    self.out.backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 }
    self:addChild(self.out)

    self:createSettingsControls(top)
    self:refreshList()
    self:applyModeTitles()
    self:setText(RealResetPanel.lastText)
end

-- While a queue runs (anyone's), planning is locked; the panel stays readable and CANCEL QUEUE works.
function RealResetPanel.setQueueInfo(info)
    info = info or { active = false }
    RealResetPanel.queueInfo = info
    RealResetPanel.queueActive = (info.active == true)
    local inst = RealResetPanel.instance
    if inst and inst.resetBtn then inst:applyModeTitles() end
end

function RealResetPanel:applyModeTitles()
    if self.planBtn and self.planBtn.setEnable then self.planBtn:setEnable(not RealResetPanel.queueActive) end
    local reset = (self.mode ~= "restore")
    self.statusBtn:setTitle(reset and "STATUS" or "REFRESH")
    self.planBtn:setTitle(reset and "1. PLAN" or "1. PLAN RESTORE")
    if RealResetPanel.queueActive then
        self.resetBtn:setTitle("CANCEL QUEUE")
    elseif self.mode == "restore" then
        self.resetBtn:setTitle("2. RESTORE NOW")
    else
        self.resetBtn:setTitle("2. RESET NOW")
    end
end

function RealResetPanel:render()
    ISCollapsableWindow.render(self)
    if not self.listTop then return end
    if self.mode == "settings" then self:renderSettings(); return end
    local restore = (self.mode == "restore")
    self:drawText(restore and "Batches:" or "Group:", 12, self.listTop + 2, 1, 1, 1, 1, UIFont.Small)
    local sel
    if restore then
        sel = self.runSel and "a saved batch" or "no batch"
    else
        sel = "group " .. self:selectedGroup()
    end
    self:drawText("Selected: " .. sel, 170, self.height - 24, 0.8, 1, 0.8, 1, UIFont.Small)
    local qi = RealResetPanel.queueInfo
    if qi and qi.active then
        local me = getPlayer() and getPlayer():getUsername()
        local mine = (qi.who == me)
        self:drawText(string.format("LOCKED: %s %s is running a %s (%s), %d of %d done. Planning is off until it finishes.",
            mine and "you" or "admin", mine and "" or tostring(qi.who), tostring(qi.kind), tostring(qi.group),
            tonumber(qi.done) or 0, tonumber(qi.total) or 0), 170, self.height - 44, 1, 0.7, 0.3, 1, UIFont.Small)
    end
    local ok, here = pcall(function()
        local p = getPlayer()
        if not p then return nil end
        local x, y = math.floor(p:getX()), math.floor(p:getY())
        return string.format("Here: chunk %d,%d  (tile %d,%d)", math.floor(x / 8), math.floor(y / 8), x, y)
    end)
    if ok and here then
        self:drawText(here, 340, self.height - 24, 1, 1, 0.7, 1, UIFont.Small)
    end
end

function RealResetPanel:setText(text)
    RealResetPanel.lastText = text
    if not self.out then return end
    local rich = tostring(text):gsub("<", "("):gsub(">", ")"):gsub("\n", " <LINE> ")
    self.out.text = rich
    self.out:paginate()
end

---------------------------------------------------------------- buttons

function RealResetPanel:onModeReset()
    self.mode = "reset"
    self:applyModeVisibility()
    self:applyModeTitles()
    self:refreshList()
    self:setText("RESET mode. Pick a group, then PLAN.")
end

function RealResetPanel:onModeRestore()
    self.mode = "restore"
    self:applyModeVisibility()
    self:applyModeTitles()
    self:refreshList()
    sendClientCommand(getPlayer(), "RealReset", "runs", {})
    self:setText("RESTORE mode. Pick a saved batch on the left, then PLAN RESTORE.")
end

function RealResetPanel:onStatus()
    if self.mode == "restore" then
        sendClientCommand(getPlayer(), "RealReset", "runs", {})
    else
        sendClientCommand(getPlayer(), "RealReset", "status", {})
    end
    self:setText("Asking the server...")
end

function RealResetPanel:onPlan()
    if self.mode == "restore" then
        local a = self:restoreArgs()
        if not a then self:setText("Pick a saved batch on the left first."); return end
        sendClientCommand(getPlayer(), "RealReset", "restorePlan", a)
        self:setText("Planning restore (nothing is changed)...")
    else
        sendClientCommand(getPlayer(), "RealReset", "plan", { group = self:selectedGroup() })
        self:setText("Planning group " .. self:selectedGroup() .. " (nothing is changed)...")
    end
end

local function confirm(target, text, onclick)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local modal = ISModalDialog:new(sw / 2 - 200, sh / 2 - 100, 400, 200, text, true, target, onclick, 0)
    modal:initialise()
    modal:addToUIManager()
end

function RealResetPanel:onReset()
    if RealResetPanel.queueActive then
        sendClientCommand(getPlayer(), "RealReset", "cancelQueue", {})
        self:setText("Cancelling...")
        return
    end
    if self.mode == "restore" then
        if not self:restoreArgs() then self:setText("Nothing selected to restore."); return end
        confirm(self, "Put the selected chunks back from the trash?\n\n"
            .. "Skipped: protected zones, safehouses, chunks near players, loaded chunks.\n"
            .. "A chunk the game already regenerated is kept aside, not overwritten.\n\n"
            .. "You must have run PLAN RESTORE in the last 10 minutes.", RealResetPanel.onRestoreConfirm)
    else
        confirm(self, "Move every eligible chunk in group '" .. self:selectedGroup() .. "' to the trash?\n\n"
            .. "Chunks regenerate from the base map when next loaded. Protected zones, safehouses, "
            .. "and chunks near players are skipped.\n\nYou must have run PLAN for this group in the last 10 minutes.",
            RealResetPanel.onResetConfirm)
    end
end

function RealResetPanel:onResetConfirm(button)
    if button and button.internal == "YES" then
        sendClientCommand(getPlayer(), "RealReset", "reset", { group = self:selectedGroup() })
        self:setText("Resetting group " .. self:selectedGroup() .. "...")
    end
end

function RealResetPanel:onRestoreConfirm(button)
    if button and button.internal == "YES" then
        local a = self:restoreArgs()
        if a then
            sendClientCommand(getPlayer(), "RealReset", "restore", a)
            self:setText("Restoring...")
        end
    end
end

function RealResetPanel:close()
    ISCollapsableWindow.close(self)
    RealResetPanel.instance = nil
end

---------------------------------------------------------------- player zone notice
-- A small see-through box in the top-right corner with an X. Hides itself after a while.
RealResetNotice = ISPanel:derive("RealResetNotice")
RealResetNotice.instance = nil

local function wrapText(text, maxW, font)
    local tm = getTextManager()
    local lines, cur = {}, ""
    for word in string.gmatch(tostring(text), "%S+") do
        local try = (cur == "") and word or (cur .. " " .. word)
        if cur ~= "" and tm:MeasureStringX(font, try) > maxW then
            lines[#lines + 1] = cur
            cur = word
        else
            cur = try
        end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    return lines
end

function RealResetNotice:onClose()
    self:removeFromUIManager()
    if RealResetNotice.instance == self then RealResetNotice.instance = nil end
end

function RealResetNotice:update()
    if self.hideAt and getTimestampMs and getTimestampMs() >= self.hideAt then
        self:onClose()
    end
end

function RealResetNotice:render()
    local lh = getTextManager():getFontHeight(UIFont.Small) + 2
    for i, l in ipairs(self.lines) do
        self:drawText(l, 8, 6 + (i - 1) * lh, 1, 1, 1, 0.95, UIFont.Small)
    end
end

function RealResetNotice.show(text, seconds)
    local old = RealResetNotice.instance
    if old then old:onClose() end
    local font = UIFont.Small
    local w = 300
    local lines = wrapText(text, w - 8 - 28, font)
    local lh = getTextManager():getFontHeight(font) + 2
    local h = math.max(30, 12 + #lines * lh)
    local x = getCore():getScreenWidth() - w - 20
    local n = ISPanel.new(RealResetNotice, x, 90, w, h)  -- an ISPanel that uses our update/render
    n:initialise()
    n.backgroundColor = { r = 0, g = 0, b = 0, a = 0.55 }
    n.borderColor = { r = 1, g = 0.8, b = 0.3, a = 0.7 }
    n.lines = lines
    n.hideAt = (getTimestampMs and getTimestampMs() or 0) + (tonumber(seconds) or 15) * 1000
    local close = ISButton:new(w - 24, 4, 18, 18, "X", n, RealResetNotice.onClose)
    close:initialise()
    close.borderColor = { r = 1, g = 1, b = 1, a = 0.4 }
    n:addChild(close)
    n:addToUIManager()
    RealResetNotice.instance = n
end

---------------------------------------------------------------- open + server replies

local function openPanel()
    if RealResetPanel.instance then return end
    local w, h = 600, 440
    local p = RealResetPanel:new(getCore():getScreenWidth() / 2 - w / 2, getCore():getScreenHeight() / 2 - h / 2, w, h)
    p:initialise()
    p.title = "RealReset!"
    p:addToUIManager()
    p:setVisible(true)
    RealResetPanel.instance = p
    sendClientCommand(getPlayer(), "RealReset", "status", {})
end

Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldObjects, test)
    if test then return end
    local p = getSpecificPlayer(playerNum)
    if isAdminPlayer(p) then
        context:addOption("RealReset! (chunk reset)", nil, openPanel)
    end
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "RealReset" or not args then return end
    if command == "queueState" then
        RealResetPanel.setQueueInfo(args)
        return
    end
    if command == "settings" then
        RealResetPanel.settings = args
        local inst = RealResetPanel.instance
        if inst and inst.mode == "settings" then inst:applySettings(args) end
        return
    end
    if command == "zoneWarn" then
        RealResetNotice.show(args.text or "", args.seconds)
        return
    end
    if command ~= "result" then return end
    RealResetPanel.lastText = tostring(args.text or "")
    if args.groups ~= nil then RealResetPanel.lastGroups = tostring(args.groups) end
    if args.runs ~= nil then RealResetPanel.lastRuns = tostring(args.runs) end
    if args.qinfo ~= nil then
        RealResetPanel.setQueueInfo(args.qinfo)
    elseif args.queue ~= nil then
        RealResetPanel.setQueueInfo({ active = (args.queue == true) })
    end
    local inst = RealResetPanel.instance
    if inst then
        if args.groups ~= nil or args.runs ~= nil then inst:refreshList() end
        inst:setText(RealResetPanel.lastText)
    end
end)
