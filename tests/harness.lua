-- Minimal WoW API harness for testing BuffBack logic outside the client.
local H = {
    addonPath = "../BuffBack.lua",
    units = {},
    auras = {},
    playerInfo = {},
    spellInfo = {},
    known = {},
    book = {},
    casterGUID = {},
    range = {},
    frames = {},
    fontStrings = {},
    output = {},
    secrets = false,
    secretIndex = nil,
    combat = false,
    now = 1000,
    raid = false,
}

local function newFrame(kind, name)
    local f = { kind = kind, name = name, attributes = {}, scripts = {}, events = {}, shown = true }
    function f:SetScript(s, fn) self.scripts[s] = fn end
    function f:GetScript(s) return self.scripts[s] end
    function f:SetAttribute(k, v) self.attributes[k] = v end
    function f:GetAttribute(k) return self.attributes[k] end
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterEvent(e) self.events[e] = nil end
    function f:RegisterForClicks() end
    function f:RegisterForDrag() end
    function f:SetSize() end
    function f:SetPoint(...) self.point = { ... } end
    function f:GetPoint() return "CENTER", "UIParent", "CENTER", 0, 0 end
    function f:ClearAllPoints() end
    function f:SetClampedToScreen() end
    function f:SetMovable() end
    function f:EnableMouse() end
    function f:SetNormalTexture() end
    function f:SetHighlightTexture() end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:StartMoving() end
    function f:StopMovingOrSizing() end
    function f:CreateTexture()
        return { SetAllPoints = function() end, SetTexture = function(self2, t) self2.texture = t end }
    end
    function f:CreateFontString()
        local fs = { text = nil, shown = true }
        function fs:SetPoint() end
        function fs:SetText(t) self.text = t end
        function fs:GetText() return self.text end
        function fs:Show() self.shown = true end
        function fs:Hide() self.shown = false end
        H.fontStrings[#H.fontStrings + 1] = fs
        return fs
    end
    H.frames[#H.frames + 1] = f
    return f
end

UIParent = {
    CreateFontString = function(self, ...)
        local fs = { text = nil, shown = true }
        function fs:SetPoint() end
        function fs:SetText(t) self.text = t end
        function fs:GetText() return self.text end
        function fs:Show() self.shown = true end
        function fs:Hide() self.shown = false end
        H.fontStrings[#H.fontStrings + 1] = fs
        return fs
    end,
}

function CreateFrame(kind, name)
    return newFrame(kind, name)
end

function RegisterStateDriver(frame, state, cond)
    H.stateDriver = cond
end

function wipe(t)
    for k in pairs(t) do t[k] = nil end
end

-- Mirrors the client's secret-value predicate for payloads marked by tests.
function issecretvalue(v)
    return type(v) == "table" and v.__secret == true
end

function IsShiftKeyDown() return H.shift end
function InCombatLockdown() return H.combat end
function IsInRaid() return H.raid end
function GetTime() return H.now end

function UnitExists(unit) local u = H.units[unit]; return u ~= nil and u.exists ~= false end
function UnitGUID(unit) local u = H.units[unit]; return u and u.guid end
function GetUnitName(unit) local u = H.units[unit]; return u and u.name end
function UnitClass(unit) local u = H.units[unit]; return u and u.class, u and u.classFile end
function UnitIsPlayer(unit) local u = H.units[unit]; return u and u.player or false end
function UnitIsFriend(a, b) local u = H.units[b]; return u and u.friend or false end
function UnitIsConnected(unit) local u = H.units[unit]; return u and u.connected or false end
function UnitIsVisible(unit) local u = H.units[unit]; return u and u.visible or false end
function UnitIsDeadOrGhost(unit) local u = H.units[unit]; return u and u.dead or false end

function GetPlayerInfoByGUID(guid)
    local i = H.playerInfo[guid]
    if not i then return nil end
    return i.class, i.classFile, i.race, i.raceFile, i.sex, i.name, i.realm
end

C_UnitAuras = {
    GetAuraDataByIndex = function(unit, index, filter)
        if H.secrets then error("Auras cannot be accessed when secret") end
        if H.secretIndex == index then error("Aura at index " .. ticker(index) .. " is secret") end
        local list = H.auras[unit]
        if not list then return nil end
        return list[index]
    end,
    GetAuraCasterGUID = function(unit, auraInstanceID)
        local m = H.casterGUID[unit]
        return m and m[auraInstanceID]
    end,
}

function ticker(n) return tostring(n) end

C_Spell = {
    GetSpellInfo = function(id) return H.spellInfo[id] end,
    IsSpellInRange = function(id, unit)
        local v = H.range[unit]
        if v == nil then return true end
        return v
    end,
    IsPlayerSpell = function(id) return H.known[id] == true end,
}

C_SpellBook = {
    GetNumSpellBookSkillLines = function() return 1 end,
    GetSpellBookSkillLineInfo = function() return { itemIndexOffset = 0, numSpellBookItems = #H.book } end,
    GetSpellBookItemInfo = function(slot) return H.book[slot] end,
    GetSpellBookItemLevelLearned = function() return 60 end,
}

Enum = { SpellBookSpellBank = { Player = 0 } }

C_Secrets = {
    ShouldAurasBeSecret = function() return H.secrets end,
    ShouldUnitAuraInstanceBeSecret = function() return false end,
}

SlashCmdList = {}

H.stdout = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    H.output[#H.output + 1] = table.concat(parts, " ")
end

function H.addUnit(unit, guid, name, opts)
    local u = {
        guid = guid, name = name, exists = true, player = true,
        friend = true, connected = true, visible = true, dead = false,
        class = "Warrior", classFile = "WARRIOR",
    }
    for k, v in pairs(opts or {}) do u[k] = v end
    H.units[unit] = u
    H.playerInfo[guid] = {
        class = u.class, classFile = u.classFile,
        race = "Human", raceFile = "Human", sex = 2, name = name, realm = "",
    }
    return u
end

function H.addAura(unit, aura)
    if aura.isHelpful == nil then aura.isHelpful = true end
    H.auras[unit] = H.auras[unit] or {}
    H.auras[unit][#H.auras[unit] + 1] = aura
    return aura
end

function H.resetAll()
    H.units = {}
    H.auras = {}
    H.playerInfo = {}
    H.spellInfo = {}
    H.known = {}
    H.book = {}
    H.casterGUID = {}
    H.range = {}
    H.frames = {}
    H.fontStrings = {}
    H.output = {}
    H.secrets = false
    H.secretIndex = nil
    H.combat = false
    H.now = 1000
    H.raid = false
    H.eventsFrame = nil
    H.button = nil
    H.label = nil
    H.status = nil
    H.stateDriver = nil
    SlashCmdList = {}
    BuffBackDB = nil
end

function H.load()
    local chunk = assert(loadfile(H.addonPath))
    chunk("BuffBack")
    for _, frame in ipairs(H.frames) do
        if frame.events and frame.events["ADDON_LOADED"] then H.eventsFrame = frame end
    end
    assert(H.eventsFrame, "events frame not created")
    H.fire("ADDON_LOADED", "BuffBack")
    for _, frame in ipairs(H.frames) do
        if frame.name == "BuffBackButton" then H.button = frame end
    end
    H.label = H.fontStrings[1]
    H.status = H.fontStrings[2]
    assert(H.button, "BuffBackButton not created")
end

function H.fire(event, ...)
    local frame = H.eventsFrame
    if not frame or not frame.events[event] then return end
    if event == "UNIT_AURA" then
        local unit, info = ...
        -- The real client always labels payload auras; default them to helpful.
        if type(info) == "table" and info.__secret ~= true and type(info.addedAuras) == "table" then
            for _, aura in ipairs(info.addedAuras) do
                if type(aura) == "table" and aura.isHelpful == nil then aura.isHelpful = true end
            end
        end
        return frame.scripts.OnEvent(frame, event, unit, info)
    end
    return frame.scripts.OnEvent(frame, event, ...)
end

function H.tick(delta)
    local frame = H.eventsFrame
    if frame and frame.scripts.OnUpdate then
        frame.scripts.OnUpdate(frame, delta or 3)
    end
end

function H.click(mouseButton)
    local b = H.button
    if b.scripts.PreClick then b.scripts.PreClick(b, mouseButton or "LeftButton", false) end
    if b.scripts.PostClick then b.scripts.PostClick(b, mouseButton or "LeftButton", false) end
end

function H.cmd(message)
    if SlashCmdList.BUFFBACK then return SlashCmdList.BUFFBACK(message) end
end

function H.lastOutput()
    return H.output[#H.output] or ""
end

function H.outputContains(needle)
    for i = #H.output, 1, -1 do
        if H.output[i]:find(needle, 1, true) then return true end
    end
    return false
end

-- Standard caster setup: a druid who knows Mark of the Wild.
function H.baseSetup(opts)
    opts = opts or {}
    H.resetAll()
    H.addUnit("player", "Player-1-0000", "Me", { class = "Druid", classFile = "DRUID" })
    H.spellInfo[1126] = { name = "Mark of the Wild", iconID = 136078 }
    H.known[1126] = true
    H.book = { { name = "Mark of the Wild", spellID = 1126, isPassive = false, isOffSpec = false } }
    -- The player already has their own buff, so no self reminder competes with
    -- the return-buff prompts under test.
    if not opts.noSelfBuff then
        H.addAura("player", {
            name = "Mark of the Wild", auraInstanceID = 1, sourceUnit = "player",
            spellId = 1126, expirationTime = 100000,
        })
    end
    H.load()
    H.fire("PLAYER_ENTERING_WORLD")
    H.now = H.now + 6
    H.tick(3)
    return H
end

return H
