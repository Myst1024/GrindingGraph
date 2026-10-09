local ADDON_NAME = ...

local DEFAULTS = {
    point = "CENTER", relativePoint = "CENTER", x = 0, y = 200,
    width = 300, height = 160,
    locked = false,
    minutes = 30,
}

local MIN_W, MIN_H, MAX_W, MAX_H = 160, 100, 1200, 600
local MAX_MINUTES = 120

-- XP bar across the top of the box
local XPBAR_INSET, XPBAR_HEIGHT = 4, 14

-- Chart margins inside the frame: room for XP bar, title, y-axis labels and the window picker
local HEADER_TOP = XPBAR_INSET + XPBAR_HEIGHT + 4
local PAD_LEFT, PAD_RIGHT, PAD_TOP, PAD_BOTTOM = 34, 8, HEADER_TOP + 16, 16

-- Turn a GlobalStrings format like "%s dies, you gain %d experience." into a Lua pattern.
local function FormatToPattern(fmt)
    local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%s", "(.-)"):gsub("%%d", "([%%d,]+)")
    return p
end

-- "Wolf dies, you gain 120 experience." (no anchor at end so rested/group bonus suffixes still match)
local KILL_PATTERN = FormatToPattern(COMBATLOG_XPGAIN_FIRSTPERSON or "%s dies, you gain %d experience.")

-- The kill message doesn't mention rested bonus, so we infer it from the rested pool. Sampled every
-- second because the pool may already be reduced by the time the kill message arrives.
local lastRestedSample = 0
local function SampleRested()
    lastRestedSample = GetXPExhaustion() or 0
end

-- While rested, kills give double XP and the whole gain is taken from the pool. So a kill's bonus
-- (the part above normal XP) is half of whatever portion of it was covered by the pool.
local function EstimateRestedBonus(amount)
    local poolBefore = math.max(lastRestedSample, GetXPExhaustion() or 0)
    return math.min(poolBefore, amount) / 2
end

local db, charDB
local frame = CreateFrame("Frame", "GrindingGraphFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:SetResizable(true)
if frame.SetResizeBounds then
    frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
else
    frame:SetMinResize(MIN_W, MIN_H)
    frame:SetMaxResize(MAX_W, MAX_H)
end
frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
frame:SetBackdropColor(0, 0, 0, 0.45)
frame:SetBackdropBorderColor(1, 1, 1, 0.25)

-- XP bar: background, rested XP stacked after current XP, current XP from the left
local xpBar = CreateFrame("Frame", nil, frame)
xpBar:SetPoint("TOPLEFT", XPBAR_INSET, -XPBAR_INSET)
xpBar:SetPoint("TOPRIGHT", -XPBAR_INSET, -XPBAR_INSET)
xpBar:SetHeight(XPBAR_HEIGHT)

local xpBarBg = xpBar:CreateTexture(nil, "BACKGROUND")
xpBarBg:SetAllPoints()
xpBarBg:SetColorTexture(0, 0, 0, 0.5)

local xpFill = xpBar:CreateTexture(nil, "ARTWORK")
xpFill:SetPoint("TOPLEFT")
xpFill:SetPoint("BOTTOMLEFT")
xpFill:SetColorTexture(0.6, 0.4, 1, 0.9)

local restedFill = xpBar:CreateTexture(nil, "ARTWORK")
restedFill:SetPoint("TOPLEFT", xpFill, "TOPRIGHT")
restedFill:SetPoint("BOTTOMLEFT", xpFill, "BOTTOMRIGHT")
restedFill:SetColorTexture(0.25, 0.55, 1, 0.55)

local xpText = xpBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
xpText:SetPoint("CENTER")

local function UpdateXPBar()
    local cur, max = UnitXP("player"), UnitXPMax("player")
    local rested = GetXPExhaustion() or 0
    local w = xpBar:GetWidth()
    if max <= 0 or w <= 0 then return end
    local xpW = cur / max * w
    local restedW = math.min(rested, max - cur) / max * w
    -- Zero-width textures render at their natural size, so hide instead
    xpFill:SetWidth(math.max(xpW, 0.001))
    xpFill:SetShown(xpW >= 0.5)
    restedFill:SetWidth(math.max(restedW, 0.001))
    restedFill:SetShown(restedW >= 0.5)
    local text = ("%d / %d (%.1f%%)"):format(cur, max, cur / max * 100)
    xpText:SetText(text)
    -- Only add the rested amount if it still fits in the bar
    if rested > 0 then
        xpText:SetText(text .. ("  +%d rested"):format(rested))
        if xpText:GetStringWidth() > w - 4 then xpText:SetText(text) end
    end
end

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
title:SetPoint("TOPLEFT", 6, -HEADER_TOP)
title:SetText("Level in: --")
title:SetTextColor(0.8, 0.8, 0.8)

local summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
summary:SetPoint("TOPRIGHT", -6, -HEADER_TOP)
summary:SetJustifyH("RIGHT")

-- The plot area; bars, gridlines and axis labels are positioned relative to it
local plot = CreateFrame("Frame", nil, frame)
plot:SetPoint("TOPLEFT", PAD_LEFT, -PAD_TOP)
plot:SetPoint("BOTTOMRIGHT", -PAD_RIGHT, PAD_BOTTOM)

local bars, gridLines, yLabels = {}, {}, {}
local Render

local function GetBar(i)
    local bar = bars[i]
    if not bar then
        bar = plot:CreateTexture(nil, "ARTWORK")
        bar:SetColorTexture(0.6, 0.4, 1, 0.9)
        bars[i] = bar
    end
    return bar
end

-- Clickable "30 Minutes" label under the chart that opens a small window-size picker
local WINDOW_CHOICES = { 5, 10, 15, 30, 60 }

local windowButton = CreateFrame("Button", nil, frame)
windowButton:SetPoint("TOP", plot, "BOTTOM", 0, -1)
windowButton:SetHeight(PAD_BOTTOM - 2)
local windowText = windowButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
windowText:SetPoint("CENTER")
windowText:SetTextColor(0.7, 0.7, 0.7)
windowButton:SetScript("OnEnter", function() windowText:SetTextColor(1, 1, 1) end)
windowButton:SetScript("OnLeave", function() windowText:SetTextColor(0.7, 0.7, 0.7) end)

local windowMenu = CreateFrame("Frame", nil, windowButton, BackdropTemplateMixin and "BackdropTemplate" or nil)
windowMenu:SetFrameStrata("DIALOG")
windowMenu:SetPoint("TOP", windowButton, "BOTTOM", 0, -2)
windowMenu:SetSize(90, #WINDOW_CHOICES * 16 + 8)
windowMenu:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
windowMenu:SetBackdropColor(0, 0, 0, 0.9)
windowMenu:SetBackdropBorderColor(1, 1, 1, 0.25)
windowMenu:SetClampedToScreen(true)
windowMenu:Hide()

local function SetWindowMinutes(n)
    db.minutes = n
    windowMenu:Hide()
    Render()
end

local windowOptions = {}
for i, n in ipairs(WINDOW_CHOICES) do
    local option = CreateFrame("Button", nil, windowMenu)
    option:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 16)
    option:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * 16)
    option:SetHeight(16)
    option:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    local text = option:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("CENTER")
    text:SetText(n .. " Minutes")
    option.text, option.minutes = text, n
    option:SetScript("OnClick", function() SetWindowMinutes(n) end)
    windowOptions[i] = option
end

windowButton:SetScript("OnClick", function()
    -- Highlight the current choice in gold
    for _, option in ipairs(windowOptions) do
        if option.minutes == db.minutes then
            option.text:SetTextColor(1, 0.82, 0)
        else
            option.text:SetTextColor(1, 1, 1)
        end
    end
    windowMenu:SetShown(not windowMenu:IsShown())
end)

-- y-axis: gridlines + labels at 0, 50% and 100% of the scale
for i = 1, 3 do
    local line = plot:CreateTexture(nil, "BACKGROUND")
    line:SetColorTexture(1, 1, 1, i == 1 and 0.35 or 0.12)
    line:SetHeight(1)
    gridLines[i] = line
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetTextColor(0.7, 0.7, 0.7)
    fs:SetJustifyH("RIGHT")
    yLabels[i] = fs
end

-- Round up to a "nice" axis maximum: 1, 2, 2.5, 5 x 10^n
local function NiceCeil(v)
    if v <= 0 then return 100 end
    local mag = 10 ^ math.floor(math.log10(v))
    for _, m in ipairs({ 1, 2, 2.5, 5, 10 }) do
        if v <= m * mag then return m * mag end
    end
    return 10 * mag
end

local function ShortNumber(v)
    if v >= 1000000 then return (("%.1fm"):format(v / 1000000):gsub("%.0m", "m")) end
    if v >= 1000 then return (("%.1fk"):format(v / 1000):gsub("%.0k", "k")) end
    return tostring(math.floor(v))
end

-- Pauses are stored as { start = t, stop = t } intervals; the last one has no stop while paused.
local function CurrentPause()
    local p = charDB.pauses[#charDB.pauses]
    if p and not p.stop then return p end
end

-- A clock minute is skipped if it lies entirely inside a pause. While paused, the ongoing pause
-- covers the current minute too if it started before that minute did.
local function PauseCovering(m)
    local s, e = m * 60, m * 60 + 60
    for _, p in ipairs(charDB.pauses) do
        if p.start <= s and e <= (p.stop or math.huge) then return p end
    end
end

-- The most recent `count` clock minutes that weren't skipped by a pause, newest first
local function ActiveMinutes(now, count)
    local list = {}
    local m = math.floor(now / 60)
    while #list < count do
        local p = PauseCovering(m)
        if p then
            m = math.ceil(p.start / 60) - 1 -- jump to the minute before the pause's first full minute
        else
            list[#list + 1] = m
            m = m - 1
        end
    end
    return list
end

-- Drop kills and pauses older than the largest window we could ever show
local function PruneHistory(now)
    local active = ActiveMinutes(now, MAX_MINUTES)
    local cutoff = active[#active] * 60
    for _, list in ipairs({ charDB.kills, charDB.pauses }) do
        local keep = 1
        for i = 1, #list do
            local entry = list[i]
            if (entry.t or entry.stop or math.huge) >= cutoff then
                list[keep] = entry
                keep = keep + 1
            end
        end
        for i = #list, keep, -1 do list[i] = nil end
    end
end

-- Buckets are fixed clock minutes, so a kill always stays in the minute it happened.
-- Bucket 0 is the newest active minute, bucket i the i-th active minute before it; fully paused
-- minutes are left out, as if they never happened.
-- baseBuckets holds the same XP with rested bonus removed, i.e. what the kills would give unrested.
local function BuildBuckets(active)
    local minutes = #active
    local buckets, baseBuckets, index = {}, {}, {}
    for i = 0, minutes - 1 do
        buckets[i], baseBuckets[i] = 0, 0
        index[active[i + 1]] = i
    end
    local killCount = 0
    for _, kill in ipairs(charDB.kills) do
        local i = index[math.floor(kill.t / 60)]
        if i then
            buckets[i] = buckets[i] + kill.xp
            baseBuckets[i] = baseBuckets[i] + kill.xp - (kill.bonus or 0)
            killCount = killCount + 1
        end
    end
    return buckets, baseBuckets, killCount
end

-- Minutes of bucket 0 that count as elapsed: the whole minute if it's in the past, otherwise the
-- part of the current minute that has passed (frozen at the pause point while paused).
local function NewestBucketDuration(active, now)
    local m = active[1]
    if m ~= math.floor(now / 60) then return 1 end
    local pause = CurrentPause()
    local stopAt = pause and pause.start or now
    return math.max(0, stopAt - m * 60) / 60
end

local function FormatDuration(minutes)
    if minutes < 1 then return "<1m" end
    minutes = math.floor(minutes + 0.5)
    if minutes < 60 then return minutes .. "m" end
    return ("%dh %dm"):format(math.floor(minutes / 60), minutes % 60)
end

-- The rested pool is an amount of XP earned at double pace (the pool drains by the full gain).
-- So the first min(pool, remaining) XP comes at 2x base rate and the rest at 1x:
--   time = rested part / (2 * base) + unrested part / base = (remaining - restedPart / 2) / base
-- The same holds per kill, so kills = (remaining - restedPart / 2) / base XP per kill.
local function EstimateLevelUp(baseRate, baseXPPerKill)
    if UnitLevel("player") >= (GetMaxPlayerLevel and GetMaxPlayerLevel() or 60) then return "max level" end
    if baseRate <= 0 or baseXPPerKill <= 0 then return "--" end
    local remaining = UnitXPMax("player") - UnitXP("player")
    local restedPart = math.min(GetXPExhaustion() or 0, remaining)
    local baseXPNeeded = remaining - restedPart / 2
    return ("%s (%d kills)"):format(FormatDuration(baseXPNeeded / baseRate), math.ceil(baseXPNeeded / baseXPPerKill))
end

function Render()
    if not charDB or not frame:IsShown() then return end
    local now = time()
    local minutes = db.minutes
    local active = ActiveMinutes(now, minutes)
    local buckets, baseBuckets, killCount = BuildBuckets(active)

    -- Average over buckets from the oldest one with XP up to now, ignoring leading empty minutes
    local peak, total, baseTotal, oldest = 0, 0, 0, nil
    for i = 0, minutes - 1 do
        peak = math.max(peak, buckets[i])
        total = total + buckets[i]
        baseTotal = baseTotal + baseBuckets[i]
        if buckets[i] > 0 then oldest = i end
    end
    local scale = NiceCeil(peak)
    -- Elapsed active minutes from the start of the oldest bucket with XP until now, counting only the
    -- part of the current minute that has passed. At least 1 so a single early kill doesn't spike the rate.
    local elapsed = oldest and math.max(1, oldest + NewestBucketDuration(active, now)) or 1
    local avg = oldest and total / elapsed or 0
    local baseRate = oldest and baseTotal / elapsed or 0
    summary:SetText(("avg %s xp / min"):format(ShortNumber(avg)))
    local baseXPPerKill = killCount > 0 and baseTotal / killCount or 0
    title:SetText("Level in: " .. EstimateLevelUp(baseRate, baseXPPerKill))

    local plotW, plotH = plot:GetWidth(), plot:GetHeight()
    if plotW <= 0 or plotH <= 0 then return end

    for i = 1, 3 do
        local frac = (i - 1) / 2
        local y = frac * plotH
        gridLines[i]:ClearAllPoints()
        gridLines[i]:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y)
        gridLines[i]:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, y)
        yLabels[i]:ClearAllPoints()
        -- The 0 label sits just above the baseline so it clears the buttons below
        yLabels[i]:SetPoint(i == 1 and "BOTTOMRIGHT" or "RIGHT", plot, "BOTTOMLEFT", -4, y)
        yLabels[i]:SetText(ShortNumber(scale * frac))
    end

    -- Bars fill from the right edge (now) leftward (older)
    local slot = plotW / minutes
    local barW = math.max(1, slot - (slot > 4 and 1 or 0))
    for i = 0, minutes - 1 do
        local bar = GetBar(i + 1)
        local h = buckets[i] / scale * plotH
        if h >= 1 then
            bar:ClearAllPoints()
            bar:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", plotW - (i + 1) * slot, 0)
            bar:SetSize(barW, h)
            bar:Show()
        else
            bar:Hide()
        end
    end
    for i = minutes + 1, #bars do bars[i]:Hide() end

    windowText:SetText(minutes .. " Minutes")
    windowButton:SetWidth(windowText:GetStringWidth() + 8)
end

-- Pause / Resume and Restart text buttons in the bottom-left corner
local function CreateTextButton(label)
    local button = CreateFrame("Button", nil, frame)
    button:SetHeight(PAD_BOTTOM - 2)
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("CENTER")
    button.text = text
    button.color = { 0.7, 0.7, 0.7 }
    button.SetLabel = function(self, s, r, g, b)
        self.text:SetText(s)
        self.color = { r or 0.7, g or 0.7, b or 0.7 }
        self.text:SetTextColor(unpack(self.color))
        self:SetWidth(self.text:GetStringWidth() + 8)
    end
    button:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 1, 1) end)
    button:SetScript("OnLeave", function(self) self.text:SetTextColor(unpack(self.color)) end)
    button:SetLabel(label)
    return button
end

local pauseButton = CreateTextButton("Pause")
pauseButton:SetPoint("LEFT", frame, "BOTTOMLEFT", 2, PAD_BOTTOM / 2)
local restartButton = CreateTextButton("Restart")
restartButton:SetPoint("LEFT", pauseButton, "RIGHT", 2, 0)

local function UpdatePauseButton()
    if CurrentPause() then
        pauseButton:SetLabel("Resume", 1, 0.82, 0)
    else
        pauseButton:SetLabel("Pause")
    end
    if pauseButton:IsMouseOver() then pauseButton.text:SetTextColor(1, 1, 1) end
end

local function TogglePause()
    local now = time()
    local pause = CurrentPause()
    if pause then
        pause.stop = now
    else
        table.insert(charDB.pauses, { start = now })
    end
    PruneHistory(now)
    UpdatePauseButton()
    Render()
end

local function RestartSession()
    wipe(charDB.kills)
    wipe(charDB.pauses)
    UpdatePauseButton()
    Render()
end

StaticPopupDialogs["GRINDINGGRAPH_RESTART"] = {
    text = "Restart the GrindingGraph session? This clears all recorded kills.",
    button1 = YES,
    button2 = NO,
    OnAccept = RestartSession,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

pauseButton:SetScript("OnClick", TogglePause)
restartButton:SetScript("OnClick", function() StaticPopup_Show("GRINDINGGRAPH_RESTART") end)

local function SaveLayout()
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    db.point, db.relativePoint, db.x, db.y = point, relativePoint, x, y
    db.width, db.height = frame:GetWidth(), frame:GetHeight()
end

local function ApplyLayout()
    frame:ClearAllPoints()
    frame:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)
    frame:SetSize(db.width, db.height)
end

-- Dragging
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self)
    if not db.locked then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveLayout()
end)
frame:SetScript("OnSizeChanged", function()
    UpdateXPBar()
    Render()
end)

-- Resize grip (bottom-right corner)
local grip = CreateFrame("Button", nil, frame)
grip:SetSize(16, 16)
grip:SetPoint("BOTTOMRIGHT", -1, 1)
grip:SetFrameLevel(plot:GetFrameLevel() + 2)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
grip:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" and not db.locked then frame:StartSizing("BOTTOMRIGHT") end
end)
grip:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    SaveLayout()
end)

local function ApplyLock()
    grip:SetShown(not db.locked)
end

local function OnKillXP(msg)
    local _, amount = msg:match(KILL_PATTERN)
    if not amount then return end
    amount = tonumber((amount:gsub(",", "")))
    if not amount or CurrentPause() then return end
    local bonus = EstimateRestedBonus(amount)
    table.insert(charDB.kills, { t = time(), xp = amount, bonus = bonus })
    PruneHistory(time())
    Render()
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_XP_UPDATE")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("UPDATE_EXHAUSTION")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_XP_UPDATE"
        or event == "PLAYER_LEVEL_UP" or event == "UPDATE_EXHAUSTION" then
        UpdateXPBar()
        return
    end
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        GrindingGraphDB = GrindingGraphDB or {}
        db = GrindingGraphDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        GrindingGraphCharDB = GrindingGraphCharDB or {}
        charDB = GrindingGraphCharDB
        charDB.kills = charDB.kills or {}
        charDB.pauses = charDB.pauses or {}
        PruneHistory(time())
        ApplyLayout()
        ApplyLock()
        UpdatePauseButton()
        SampleRested()
        Render()
        -- Bars slide left as time passes, so redraw periodically
        C_Timer.NewTicker(1, function()
            SampleRested()
            Render()
        end)
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        OnKillXP(arg1)
    end
end)

SLASH_GRINDINGGRAPH1 = "/gg"
SLASH_GRINDINGGRAPH2 = "/grindinggraph"
SlashCmdList.GRINDINGGRAPH = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    if cmd == "lock" or cmd == "unlock" then
        db.locked = (cmd == "lock")
        ApplyLock()
        print("GrindingGraph: " .. (db.locked and "locked" or "unlocked"))
    elseif cmd == "reset" then
        for k, v in pairs(DEFAULTS) do db[k] = v end
        ApplyLayout()
        ApplyLock()
        Render()
        print("GrindingGraph: position, size and window reset")
    elseif cmd == "minutes" then
        local n = tonumber(arg)
        if n and n >= 5 and n <= MAX_MINUTES then
            db.minutes = math.floor(n)
            Render()
            print("GrindingGraph: showing last " .. db.minutes .. " minutes")
        else
            print("GrindingGraph: usage /gg minutes <5-" .. MAX_MINUTES .. ">")
        end
    elseif cmd == "pause" or cmd == "resume" then
        if (cmd == "pause") ~= (CurrentPause() ~= nil) then TogglePause() end
        print("GrindingGraph: " .. (CurrentPause() and "paused" or "running"))
    elseif cmd == "restart" or cmd == "clear" then
        RestartSession()
        print("GrindingGraph: session restarted")
    elseif cmd == "show" or cmd == "hide" then
        frame:SetShown(cmd == "show")
        Render()
    else
        print("GrindingGraph commands: /gg lock | unlock | reset | minutes <n> | pause | resume | restart | show | hide")
    end
end
