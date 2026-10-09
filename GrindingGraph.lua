local ADDON_NAME = ...

local DEFAULTS = {
    point = "CENTER", relativePoint = "CENTER", x = 0, y = 200,
    width = 160, height = 60,
    locked = false,
}

local MIN_W, MIN_H, MAX_W, MAX_H = 80, 30, 600, 300

-- Turn a GlobalStrings format like "%s dies, you gain %d experience." into a Lua pattern.
local function FormatToPattern(fmt)
    local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%s", "(.-)"):gsub("%%d", "([%%d,]+)")
    return p
end

-- "Wolf dies, you gain 120 experience." (no anchor at end so rested/group bonus suffixes still match)
local KILL_PATTERN = FormatToPattern(COMBATLOG_XPGAIN_FIRSTPERSON or "%s dies, you gain %d experience.")

local db
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

local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
label:SetPoint("TOPLEFT", 6, -4)
label:SetText("Last kill XP")
label:SetTextColor(0.8, 0.8, 0.8)

local value = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
value:SetPoint("CENTER", 0, -6)
value:SetTextColor(0.6, 0.4, 1)
value:SetText("--")

local function UpdateFontSize()
    local size = math.max(10, math.floor(frame:GetHeight() * 0.45))
    value:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
end

local function SaveLayout()
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    db.point, db.relativePoint, db.x, db.y = point, relativePoint, x, y
    db.width, db.height = frame:GetWidth(), frame:GetHeight()
end

local function ApplyLayout()
    frame:ClearAllPoints()
    frame:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)
    frame:SetSize(db.width, db.height)
    UpdateFontSize()
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
frame:SetScript("OnSizeChanged", UpdateFontSize)

-- Resize grip (bottom-right corner)
local grip = CreateFrame("Button", nil, frame)
grip:SetSize(16, 16)
grip:SetPoint("BOTTOMRIGHT", -1, 1)
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
    if amount then value:SetText(amount) end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        GrindingGraphDB = GrindingGraphDB or {}
        db = GrindingGraphDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        ApplyLayout()
        ApplyLock()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        OnKillXP(arg1)
    end
end)

SLASH_GRINDINGGRAPH1 = "/gg"
SLASH_GRINDINGGRAPH2 = "/grindinggraph"
SlashCmdList.GRINDINGGRAPH = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "lock" or msg == "unlock" then
        db.locked = (msg == "lock")
        ApplyLock()
        print("GrindingGraph: " .. (db.locked and "locked" or "unlocked"))
    elseif msg == "reset" then
        for k, v in pairs(DEFAULTS) do db[k] = v end
        ApplyLayout()
        ApplyLock()
        print("GrindingGraph: position and size reset")
    elseif msg == "show" or msg == "hide" then
        frame:SetShown(msg == "show")
    else
        print("GrindingGraph commands: /gg lock | unlock | reset | show | hide")
    end
end
