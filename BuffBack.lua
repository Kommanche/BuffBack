local addonName = ...

local events = CreateFrame("Frame")
local queue = {}
local seen = {}
local baselineComplete = false
local loginBaselineUntil = 0
local activeEntry
local selectedSpellID
local dragging = false
local pendingCast
local button, label, status
local debugEnabled = false
local partyDismissed = {}
local partyElapsed = 0
local expiresAfter = 60
local sequence = 0
local lastCasterMiss
local lastSkip

-- Single-target, broadly useful buffs, in preference order. IDs identify spell
-- families; localized names are resolved by the client before spellbook lookup.
local classBuffs = {
    DRUID = { 1126 }, -- Mark of the Wild
    MAGE = { 1459 }, -- Arcane Intellect
    PRIEST = { 1243 }, -- Power Word: Fortitude
    PALADIN = { 20217, 19740 }, -- Blessing of Kings, then Blessing of Might
}

-- Group versions provide the same family of buff as the single-target spell.
local groupBuffFamilies = {
    [1126] = 21849, -- Mark of the Wild / Gift of the Wild
    [1459] = 23028, -- Arcane Intellect / Arcane Brilliance
    [1243] = 21562, -- Power Word: Fortitude / Prayer of Fortitude
}

local function readable(value)
    if value == nil then return false end
    if issecretvalue and issecretvalue(value) then return false end
    return true
end

local function isTrue(value)
    return readable(value) and value == true
end

local function say(message)
    print("|cff78d9ffBuffBack:|r " .. message)
end

local debugTimes = {}
local function debugSay(message)
    if debugEnabled then say("[debug] " .. message) end
end

local function debugOnce(key, message, interval)
    if not debugEnabled then return end
    local now = GetTime()
    if debugTimes[key] and now - debugTimes[key] < (interval or 30) then return end
    debugTimes[key] = now
    say("[debug] " .. message)
end

-- Forever (Midnight) can mark aura data secret during combat, encounters,
-- challenge modes, PvP and transiently on events such as level-up. Addon code
-- cannot read the data in that state; calling the aura API raises an error.
local function aurasAreSecret()
    if not C_Secrets or not C_Secrets.ShouldAurasBeSecret then return false end
    local ok, value = pcall(C_Secrets.ShouldAurasBeSecret)
    return ok and readable(value) and value == true
end

local function auraInstanceIsSecret(unit, auraInstanceID)
    -- Reserved for a future client predicate; guarded so an absent API is safe.
    if not C_Secrets or not C_Secrets.ShouldUnitAuraInstanceBeSecret then return false end
    local ok, value = pcall(C_Secrets.ShouldUnitAuraInstanceBeSecret, unit, auraInstanceID)
    return ok and readable(value) and value == true
end

local spellInfoCache = {}
local function spellInfo(id)
    if type(id) ~= "number" or not C_Spell or not C_Spell.GetSpellInfo then return nil end
    local cached = spellInfoCache[id]
    if cached then return cached end
    local ok, info = pcall(C_Spell.GetSpellInfo, id)
    if not ok or not readable(info) or type(info) ~= "table" then return nil end
    if not readable(info.name) or type(info.name) ~= "string" then return nil end
    spellInfoCache[id] = info
    return info
end

local function spellIcon(info)
    if info and readable(info.iconID) and type(info.iconID) == "number" then
        return info.iconID
    end
    return 134400
end

-- IsPlayerSpell moved between C_Spell, the global namespace and C_SpellBook
-- across client versions. If no predicate exists, do not block the addon:
-- spellbook entries are already known spells.
local function isPlayerSpell(id)
    if type(id) ~= "number" then return false end
    local checked = false

    local function ask(fn, ...)
        checked = true
        local ok, value = pcall(fn, ...)
        return ok and readable(value) and value == true
    end

    if C_Spell and C_Spell.IsPlayerSpell then
        if ask(C_Spell.IsPlayerSpell, id) then return true end
    end
    if _G.IsPlayerSpell then
        if ask(_G.IsPlayerSpell, id) then return true end
    end
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
        if ask(C_SpellBook.IsSpellKnown, id, bank or 0) then return true end
    end
    if _G.IsSpellKnown then
        if ask(_G.IsSpellKnown, id) then return true end
    end
    return not checked
end

local automaticCache
local automaticClass
local automaticResolved = false

local function invalidateAutomaticSpell()
    automaticCache = nil
    automaticClass = nil
    automaticResolved = false
end

local function automaticSpell()
    local _, class = UnitClass("player")
    if automaticResolved and automaticClass == class then return automaticCache end

    automaticClass = class
    automaticResolved = true
    automaticCache = nil

    local candidates = classBuffs[class]
    if not candidates or not C_SpellBook then return nil end

    local names = {}
    for priority, id in ipairs(candidates) do
        local info = spellInfo(id)
        if info then names[info.name] = priority end
    end

    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
    if bank == nil or not C_SpellBook.GetNumSpellBookSkillLines
        or not C_SpellBook.GetSpellBookSkillLineInfo
        or not C_SpellBook.GetSpellBookItemInfo then
        return nil
    end

    local okLines, numLines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
    if not okLines or not readable(numLines) or type(numLines) ~= "number" then return nil end

    local best, bestPriority, bestLevel
    for lineIndex = 1, numLines do
        local okLine, line = pcall(C_SpellBook.GetSpellBookSkillLineInfo, lineIndex)
        if okLine and readable(line) and type(line) == "table" then
            local offset, count = line.itemIndexOffset, line.numSpellBookItems
            if readable(offset) and readable(count)
                and type(offset) == "number" and type(count) == "number" then
                for slot = offset + 1, offset + count do
                    local okItem, item = pcall(C_SpellBook.GetSpellBookItemInfo, slot, bank)
                    if okItem and readable(item) and type(item) == "table" then
                        local itemName = item.name
                        local priority = readable(itemName) and type(itemName) == "string" and names[itemName]
                        local spellID = item.spellID
                        local passive, offSpec = item.isPassive, item.isOffSpec
                        if priority and readable(spellID) and type(spellID) == "number"
                            and readable(passive) and not passive
                            and readable(offSpec) and not offSpec
                            and isPlayerSpell(spellID) then
                            local level = 0
                            if C_SpellBook.GetSpellBookItemLevelLearned then
                                local okLevel, learned = pcall(C_SpellBook.GetSpellBookItemLevelLearned, slot, bank)
                                if okLevel and readable(learned) and type(learned) == "number" then
                                    level = learned
                                end
                            end
                            if not best or priority < bestPriority
                                or (priority == bestPriority and level > bestLevel) then
                                best, bestPriority, bestLevel = spellID, priority, level
                            end
                        end
                    end
                end
            end
        end
    end

    automaticCache = best
    return best
end

local function configuredSpell()
    if selectedSpellID then
        local info = spellInfo(selectedSpellID)
        if info and isPlayerSpell(selectedSpellID) then return info, selectedSpellID end
    end
    local id = automaticSpell()
    local info = spellInfo(id)
    if info and isPlayerSpell(id) then return info, id end
end

local function spellRange(spellID, unit)
    if not spellID or not unit then return nil end
    local fn = (C_Spell and C_Spell.IsSpellInRange) or _G.IsSpellInRange
    if not fn then return nil end
    local ok, value = pcall(fn, spellID, unit)
    if not ok or not readable(value) or type(value) ~= "boolean" then return nil end
    return value
end

local function unitAvailable(unit)
    local exists = UnitExists(unit)
    if not readable(exists) or not exists then return false end
    local connected = UnitIsConnected(unit)
    if not readable(connected) or not connected then return false end
    local visible = UnitIsVisible(unit)
    if not readable(visible) or not visible then return false end
    local dead = UnitIsDeadOrGhost(unit)
    if not readable(dead) or dead then return false end
    return true
end

local function matchingUnit(unit, guid)
    if type(unit) ~= "string" or type(guid) ~= "string" then return false end
    local exists = UnitExists(unit)
    if not readable(exists) or not exists then return false end
    local actual = UnitGUID(unit)
    if not readable(actual) or type(actual) ~= "string" or actual ~= guid then return false end
    local player = UnitIsPlayer(unit)
    if not readable(player) or not player then return false end
    local friend = UnitIsFriend("player", unit)
    if not readable(friend) or not friend then return false end
    return true
end

local function partyUnitForGUID(guid)
    if not guid or IsInRaid() then return nil end
    for i = 1, 4 do
        local unit = "party" .. i
        if matchingUnit(unit, guid) then return unit end
    end
end

local function resolveUnit(entry)
    if not entry or not entry.guid then return nil end
    if matchingUnit("player", entry.guid) then return "player" end
    for i = 1, 4 do
        local unit = "party" .. i
        if matchingUnit(unit, entry.guid) then return unit end
    end
    if IsInRaid() then
        for i = 1, 40 do
            local unit = "raid" .. i
            if matchingUnit(unit, entry.guid) then return unit end
        end
    end
    if entry.sourceUnit and matchingUnit(entry.sourceUnit, entry.guid) then return entry.sourceUnit end
    if matchingUnit("target", entry.guid) then return "target" end
    if matchingUnit("focus", entry.guid) then return "focus" end
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if matchingUnit(unit, entry.guid) then return unit end
    end
end

local function nextSequence()
    sequence = sequence + 1
    return sequence
end

local function priorityOf(entry)
    if entry.kind == "preview" or entry.kind == "casttest" then return 0 end
    if entry.kind == "return" then return 1 end
    return 2
end

local function prune()
    local now = GetTime()
    for i = #queue, 1, -1 do
        if queue[i].expires <= now then
            if activeEntry == queue[i] then activeEntry = nil end
            table.remove(queue, i)
        end
    end
end

local function pruneDismissed()
    local now = GetTime()
    for guid, untilTime in pairs(partyDismissed) do
        if untilTime <= now then partyDismissed[guid] = nil end
    end
end

local buffNameCache = {}
local function partyBuffNames(info)
    local _, class = UnitClass("player")
    local key = (class or "") .. "\0" .. info.name
    local cached = buffNameCache[key]
    if cached then return cached end

    local names = { [info.name] = true }
    for _, baseID in ipairs(classBuffs[class] or {}) do
        local base = spellInfo(baseID)
        local group = groupBuffFamilies[baseID] and spellInfo(groupBuffFamilies[baseID])
        if base and group and (info.name == base.name or info.name == group.name) then
            names[base.name] = true
            names[group.name] = true
        end
    end
    buffNameCache[key] = names
    return names
end

-- true means present, false means absent, nil means the client withheld data.
local function auraBuffState(unit, info)
    if not unit or not info or aurasAreSecret() then return nil end
    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return nil end
    local exists = UnitExists(unit)
    if not readable(exists) or not exists then return nil end

    local names = partyBuffNames(info)
    for index = 1, 255 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, "HELPFUL")
        if not ok then return nil end
        if not aura then return false end
        if not readable(aura) or type(aura) ~= "table" then return nil end
        local name = aura.name
        if not readable(name) or type(name) ~= "string" then return nil end
        if names[name] then return true end
    end
    return nil
end

local function addCaster(aura)
    if not aura or not readable(aura) or type(aura) ~= "table" then return end

    local auraName = readable(aura.name) and type(aura.name) == "string" and aura.name or nil
    local auraID = aura.auraInstanceID
    if not readable(auraID) or type(auraID) ~= "number" then return end
    if auraInstanceIsSecret("player", auraID) then
        debugOnce("instance-secret", "A buff was applied, but this client hides that aura's data.")
        return
    end

    local source = aura.sourceUnit
    if not readable(source) or type(source) ~= "string" then source = nil end
    if source then
        local exists = UnitExists(source)
        if not readable(exists) or not exists then source = nil end
    end

    local guid = source and UnitGUID(source)
    if not readable(guid) or type(guid) ~= "string" then
        guid = nil
        if C_UnitAuras and C_UnitAuras.GetAuraCasterGUID then
            local ok, caster = pcall(C_UnitAuras.GetAuraCasterGUID, "player", auraID)
            if ok and readable(caster) and type(caster) == "string" then guid = caster end
        end
    end

    local playerGUID = UnitGUID("player")
    if not readable(guid) or type(guid) ~= "string" then
        lastCasterMiss = { name = auraName or "that buff", time = GetTime() }
        debugSay("Buff detected" .. (auraName and (": " .. auraName) or "")
            .. ", but the client did not provide a usable caster.")
        return
    end
    if not readable(playerGUID) or guid == playerGUID then return end
    if not guid:match("^Player%-") then return end

    if source then
        local isPlayer = UnitIsPlayer(source)
        local isFriend = UnitIsFriend("player", source)
        if not readable(isPlayer) or not isPlayer then return end
        if not readable(isFriend) or not isFriend then return end
    end

    local name = source and GetUnitName(source, true)
    if not readable(name) or type(name) ~= "string" then
        name = nil
        if GetPlayerInfoByGUID then
            local ok, _, _, _, _, _, playerName, realm = pcall(GetPlayerInfoByGUID, guid)
            if ok and readable(playerName) and type(playerName) == "string" then
                name = playerName
                if readable(realm) and type(realm) == "string" and realm ~= "" then
                    name = name .. "-" .. realm
                end
            end
        end
    end

    for _, entry in ipairs(queue) do
        if entry.guid == guid then
            entry.expires = GetTime() + expiresAfter
            entry.sourceUnit = entry.sourceUnit or source
            -- A party reminder can be upgraded into the primary return prompt.
            if entry.kind == "party" or entry.kind == "self" then
                entry.kind = "return"
                entry.party = nil
                entry.self = nil
            end
            if entry.name == "another player" and name then entry.name = name end
            debugSay("Refreshed return prompt for " .. (name or entry.name or "a player") .. ".")
            return
        end
    end

    table.insert(queue, {
        kind = "return",
        guid = guid,
        name = name or "another player",
        sourceUnit = source,
        expires = GetTime() + expiresAfter,
        seq = nextSequence(),
    })
    debugSay("Queued return prompt for " .. (name or "another player")
        .. (auraName and (" (" .. auraName .. ")") or "") .. ".")
end

local function selectEntry(spellID)
    local best, bestPriority, bestSeq
    for _, entry in ipairs(queue) do
        local eligible = true
        if entry.kind == "return" then
            eligible = resolveUnit(entry) ~= nil
        elseif entry.kind == "party" then
            local unit = partyUnitForGUID(entry.guid)
            eligible = unit ~= nil and (not spellID or spellRange(spellID, unit) == true)
        elseif entry.kind == "self" then
            local dead = UnitIsDeadOrGhost("player")
            eligible = readable(dead) and not dead
        end
        if eligible then
            local priority = priorityOf(entry)
            if not best or priority < bestPriority
                or (priority == bestPriority and entry.seq < bestSeq) then
                best, bestPriority, bestSeq = entry, priority, entry.seq
            end
        end
    end
    return best
end

local function hidePrompt()
    if not button then return end
    button:SetAttribute("has-prompt", false)
    button:SetAttribute("type", nil)
    button:SetAttribute("unit", nil)
    button:SetAttribute("spell", nil)
    button:Hide()
    if label then label:Hide() end
    if status then status:Hide() end
end

local function update()
    if InCombatLockdown() or not button then return end
    prune()
    pruneDismissed()

    local info, spellID = configuredSpell()

    -- Do not offer a buff the recipient already has. Unknown data (nil) does
    -- not count as absent and never removes a prompt.
    if info and auraBuffState then
        for i = #queue, 1, -1 do
            local queued = queue[i]
            if not queued.force and not queued.preview then
                local queuedUnit = resolveUnit(queued)
                if queuedUnit and auraBuffState(queuedUnit, info) == true then
                    lastSkip = {
                        name = queued.name or "another player",
                        spell = info.name,
                        time = GetTime(),
                    }
                    debugSay("Skipped " .. (queued.name or "another player")
                        .. " because they already have " .. info.name .. ".")
                    if activeEntry == queued then activeEntry = nil end
                    table.remove(queue, i)
                end
            end
        end
    end

    local entry = selectEntry(spellID)
    activeEntry = entry
    if not entry then
        hidePrompt()
        return
    end

    local unit = resolveUnit(entry)
    local matched = unit ~= nil
    if matched and entry.name == "another player" then
        local actualName = GetUnitName(unit, true)
        if readable(actualName) and type(actualName) == "string" then entry.name = actualName end
    end

    -- Preview entries never get a spell action. A return prompt also stays
    -- queued if the client cannot provide a matching unit token.
    local canCast = matched and info ~= nil and not entry.preview
    if canCast then
        button:SetAttribute("type", "spell")
        button:SetAttribute("unit", unit)
        button:SetAttribute("spell", spellID)
    else
        button:SetAttribute("type", nil)
        button:SetAttribute("unit", nil)
        button:SetAttribute("spell", nil)
    end

    entry.actionUnit = unit
    entry.actionSpellID = spellID
    entry.actionSpellName = info and info.name or nil

    local remaining = 0
    for _, queued in ipairs(queue) do
        if queued ~= entry then remaining = remaining + 1 end
    end
    local suffix = remaining > 0 and ("  (+" .. remaining .. ")") or ""
    local name = entry.name or "another player"

    if entry.kind == "preview" then
        label:SetText("Preview: buff back " .. name .. "?" .. suffix)
    elseif entry.kind == "casttest" then
        label:SetText("Test: buff " .. name .. "?" .. suffix)
    elseif entry.kind == "return" then
        label:SetText("Buff back " .. name .. "?" .. suffix)
    elseif entry.kind == "self" then
        label:SetText("Buff yourself?" .. suffix)
    else
        label:SetText("Buff " .. name .. "?" .. suffix)
    end

    local range = matched and spellID and spellRange(spellID, unit) or nil
    if not info then
        status:SetText(entry.preview and "Preview only - no spell will be cast"
            or "No supported buff known. Set one with /buffback spell <ID>")
    elseif entry.preview then
        status:SetText("Preview only - no spell will be cast  |  Right-click to dismiss")
    elseif not matched then
        status:SetText("Player unavailable - target them or move closer")
    elseif range == false and entry.kind ~= "self" then
        status:SetText("Out of range - move closer (click still attempts the cast)")
    elseif entry.kind == "self" then
        status:SetText("Click to cast " .. info.name .. " on yourself  |  Right-click to dismiss")
    elseif entry.kind == "casttest" then
        status:SetText("Test cast: " .. info.name .. "  |  Right-click to dismiss")
    else
        status:SetText("Click to cast " .. info.name .. "  |  Right-click to dismiss")
    end

    button.icon:SetTexture(spellIcon(info))
    label:Show()
    status:Show()
    button:SetAttribute("has-prompt", true)
    button:Show()
end

local function scan(initial, changed)
    if InCombatLockdown() then return end
    if aurasAreSecret() then
        debugOnce("secret-scan", "Player auras are hidden by the client right now; will retry.", 15)
        return
    end

    -- The UNIT_AURA payload itself can be secret. In that case the change is
    -- unobservable; leave the old baseline intact and retry later.
    if changed ~= nil then
        if not readable(changed) then
            debugOnce("secret-payload", "Aura update details were hidden by the client; will retry.", 15)
            return
        end
        local full, added, updated = changed.isFullUpdate, changed.addedAuras, changed.updatedAuraInstanceIDs
        if (full ~= nil and not readable(full)) or (added ~= nil and not readable(added))
            or (updated ~= nil and not readable(updated)) then
            debugOnce("secret-payload", "Aura update details were hidden by the client; will retry.", 15)
            return
        end
    end

    local fullUpdate = isTrue(changed and changed.isFullUpdate)
    local isBaseline = initial or not baselineComplete or fullUpdate

    -- A full update is a resync point: discard old instance IDs. Ordinary
    -- scans merge into the existing set so a partial/secret read never wipes it.
    if initial or fullUpdate then seen = {} end

    local complete = true

    -- New auras are available directly in the event payload. Use them first so
    -- a single secret aura elsewhere cannot hide the buff we care about.
    local addedAuras = changed and changed.addedAuras
    if readable(addedAuras) and type(addedAuras) == "table" and not isBaseline then
        local okAdded = pcall(function()
            for _, aura in ipairs(addedAuras) do
                if not readable(aura) or type(aura) ~= "table" then
                    complete = false
                else
                    local helpful = aura.isHelpful
                    local id, expiry = aura.auraInstanceID, aura.expirationTime
                    if not readable(helpful) then
                        complete = false
                    elseif helpful == true and readable(id) and type(id) == "number" then
                        if seen[id] == nil then
                            seen[id] = (readable(expiry) and type(expiry) == "number" and expiry) or false
                            addCaster(aura)
                        end
                    elseif helpful == true then
                        complete = false
                    end
                    -- Harmful auras in the payload are ignored.
                end
            end
        end)
        if not okAdded then complete = false end
    end

    local failures = 0
    local present = {}
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for index = 1, 255 do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, "HELPFUL")
            if not ok then
                -- One inaccessible aura must not abort the whole scan.
                complete = false
                failures = failures + 1
                debugOnce("secret-index", "Some player auras are hidden by the client; skipping them.", 15)
                if failures >= 8 then break end
            elseif not aura then
                break
            else
                failures = 0
                if readable(aura) and type(aura) == "table" then
                    local id, expiry = aura.auraInstanceID, aura.expirationTime
                    if readable(id) and type(id) == "number" then
                        local prior = seen[id]
                        local exp = (readable(expiry) and type(expiry) == "number" and expiry) or false
                        if not isBaseline then
                            if prior == nil then
                                debugSay("New aura detected: " .. (aura.name or "unnamed") .. ".")
                                addCaster(aura)
                            elseif type(prior) == "number" and exp and exp > prior + 0.05 then
                                -- The same aura instance was refreshed.
                                debugSay("Refresh detected: " .. (aura.name or "unnamed") .. ".")
                                addCaster(aura)
                            end
                        end
                        seen[id] = exp
                        present[id] = exp
                    else
                        complete = false
                    end
                else
                    complete = false
                end
            end
        end
    else
        complete = false
    end

    if complete then
        -- Rebuild the known set so removed auras do not accumulate forever.
        seen = present
        baselineComplete = GetTime() >= loginBaselineUntil
    end

    update()
end

local function scanParty()
    if InCombatLockdown() or not button then return end
    if aurasAreSecret() then
        debugOnce("secret-party", "Party auras are hidden by the client right now; will retry.", 15)
        return
    end

    pruneDismissed()
    local info, spellID = configuredSpell()
    local missing = {}

    if info then
        local lastIndex = IsInRaid() and 0 or 4
        for index = 0, lastIndex do
            local unit = index == 0 and "player" or "party" .. index
            if unitAvailable(unit) then
                local guid, name = UnitGUID(unit), GetUnitName(unit, true)
                if readable(guid) and type(guid) == "string"
                    and readable(name) and type(name) == "string" then
                    local selfMember = index == 0
                    local inRange = selfMember or spellRange(spellID, unit) == true
                    if inRange and auraBuffState(unit, info) == false then
                        missing[guid] = {
                            name = selfMember and "yourself" or name,
                            self = selfMember,
                        }
                    end
                end
            end
        end
    end

    -- Remove reminders that are no longer missing. Return prompts are kept.
    for i = #queue, 1, -1 do
        local entry = queue[i]
        if (entry.kind == "party" or entry.kind == "self") and not missing[entry.guid] then
            if activeEntry == entry then activeEntry = nil end
            table.remove(queue, i)
        end
    end

    for guid, member in pairs(missing) do
        local present = false
        for _, entry in ipairs(queue) do
            if entry.guid == guid then present = true; break end
        end
        if not present and (not partyDismissed[guid] or partyDismissed[guid] <= GetTime()) then
            table.insert(queue, {
                kind = member.self and "self" or "party",
                guid = guid,
                name = member.name,
                expires = GetTime() + expiresAfter,
                seq = nextSequence(),
            })
        end
    end

    update()
end

local function createUI()
    button = CreateFrame("Button", "BuffBackButton", UIParent,
        "SecureActionButtonTemplate,SecureHandlerStateTemplate")
    button:SetSize(48, 48)
    button:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
    button:SetClampedToScreen(true)
    button:RegisterForClicks("AnyUp")
    -- Match the registered mouse-up event regardless of action bar key-down settings.
    button:SetAttribute("useOnKeyDown", false)
    button:SetMovable(true)
    button:EnableMouse(true)
    button:RegisterForDrag("LeftButton")

    button:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() and not InCombatLockdown() then
            dragging = true
            self:StartMoving()
        end
    end)

    button:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        dragging = false
        if not InCombatLockdown() then
            local point, _, relativePoint, x, y = self:GetPoint()
            BuffBackDB.position = { point, relativePoint, x, y }
        end
        update()
    end)

    if BuffBackDB.position then
        local p = BuffBackDB.position
        button:ClearAllPoints()
        button:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    end

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    button:SetScript("PreClick", function(_, mouseButton)
        if mouseButton ~= "LeftButton" then return end
        local entry = activeEntry
        local locked = InCombatLockdown()
        -- Validate the token again so a reused party/nameplate/target slot can
        -- never silently redirect the buff to someone else.
        local valid = entry ~= nil and not entry.preview and not dragging
            and matchingUnit(entry.actionUnit, entry.guid)

        if not valid then
            pendingCast = nil
            if not locked then
                button:SetAttribute("type", nil)
                if entry and not entry.preview and not dragging then
                    say("That player is no longer available. Target them or move closer, then click again.")
                end
            end
            return
        end

        if locked then
            -- Attributes cannot be changed in combat, but the click still casts
            -- using the values set before combat. Track the last known spell so
            -- a successful cast can clear the prompt.
            pendingCast = {
                entry = entry,
                spellID = entry.actionSpellID,
                spellName = entry.actionSpellName,
                time = GetTime(),
            }
            return
        end

        local info, id = configuredSpell()
        if info and id then
            pendingCast = {
                entry = entry,
                spellID = id,
                spellName = info.name,
                time = GetTime(),
            }
        else
            button:SetAttribute("type", nil)
            pendingCast = nil
        end
    end)

    button:SetScript("PostClick", function(_, mouseButton)
        if mouseButton ~= "RightButton" or InCombatLockdown() or not activeEntry then return end
        local entry = activeEntry
        activeEntry = nil
        for i = #queue, 1, -1 do
            if queue[i] == entry then table.remove(queue, i); break end
        end
        if (entry.kind == "party" or entry.kind == "self") and entry.guid then
            partyDismissed[entry.guid] = GetTime() + 60
        end
        update()
    end)

    -- Right click is reserved for dismissal and never casts.
    button:SetAttribute("type2", "none")

    -- Restore visibility after combat only when there is an actual prompt.
    button:SetAttribute("_onstate-combat", [[
        if newstate == "1" then
            self:Hide()
        elseif self:GetAttribute("has-prompt") then
            self:Show()
        else
            self:Hide()
        end
    ]])
    RegisterStateDriver(button, "combat", "[combat] 1; 0")

    label = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("BOTTOM", button, "TOP", 0, 10)
    status = UIParent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOP", button, "BOTTOM", 0, -8)

    hidePrompt()
    update()
end

local castMatches = function(spellID)
    if not pendingCast or not readable(spellID) then return false end
    if spellID == pendingCast.spellID then return true end
    local cast = spellInfo(spellID)
    return cast ~= nil and cast.name == pendingCast.spellName
end

SLASH_BUFFBACK1 = "/buffback"
SlashCmdList.BUFFBACK = function(message)
    local command, arg = message:match("^%s*(%S*)%s*(.-)%s*$")
    command = command:lower()

    if command == "spell" then
        local id = tonumber(arg)
        local info = spellInfo(id)
        if not info or not isPlayerSpell(id) then
            say("Enter the numeric ID of a spell your character knows: /buffback spell <ID>")
            return
        end
        if C_Spell and C_Spell.IsSelfBuff then
            local ok, selfOnly = pcall(C_Spell.IsSelfBuff, id)
            if ok and readable(selfOnly) and selfOnly == true then
                say(info.name .. " only affects you and cannot buff another player back.")
                return
            end
        end
        selectedSpellID = id
        BuffBackDB.spellID = id
        buffNameCache = {}
        say("Return buff set to " .. info.name .. ".")
        update()
    elseif command == "auto" then
        selectedSpellID = nil
        BuffBackDB.spellID = nil
        buffNameCache = {}
        invalidateAutomaticSpell()
        local info = configuredSpell()
        say(info and ("Automatic buff set to " .. info.name .. ".")
            or "Automatic mode: no supported buff known yet.")
        update()
    elseif command == "debug" then
        debugEnabled = not debugEnabled
        say("Debug " .. (debugEnabled and "enabled" or "disabled")
            .. ". Detection messages will appear in chat.")
        if debugEnabled then
            local info, id = configuredSpell()
            local secret = aurasAreSecret()
            say("Buff " .. (info and (info.name .. " (" .. tostring(id) .. ")") or "none")
                .. " | auras " .. (secret and "hidden by client" or "readable")
                .. " | baseline " .. (baselineComplete and "ready" or "pending"))
        end
    elseif command == "status" then
        local info, id = configuredSpell()
        local secret = aurasAreSecret()
        say(("Buff: %s | auras: %s | baseline: %s | prompts: %d"):format(
            info and (info.name .. " (" .. tostring(id) .. ")") or "none",
            secret and "hidden by client" or "readable",
            baselineComplete and "ready" or "pending",
            #queue))
        if activeEntry then
            say("Active prompt: " .. (activeEntry.name or "?")
                .. " (" .. (activeEntry.kind or "?") .. ")")
        else
            say("Active prompt: none")
        end
        if lastCasterMiss and GetTime() - lastCasterMiss.time < 120 then
            say("Last detected buff without a usable caster: " .. lastCasterMiss.name)
        end
        if lastSkip and GetTime() - lastSkip.time < 120 then
            say("Last prompt skipped because the player already had it: "
                .. lastSkip.name .. " / " .. lastSkip.spell)
        end
    elseif command == "clear" then
        wipe(queue)
        activeEntry = nil
        pendingCast = nil
        update()
        for i = 0, 4 do
            local guid = UnitGUID(i == 0 and "player" or "party" .. i)
            if readable(guid) and type(guid) == "string" then
                partyDismissed[guid] = GetTime() + 60
            end
        end
        say("Queue cleared; missing-buff reminders paused for 60 seconds.")
    elseif command == "test" then
        if InCombatLockdown() then say("Test is unavailable in combat."); return end
        table.insert(queue, {
            kind = "preview",
            name = "Example player",
            preview = true,
            expires = GetTime() + expiresAfter,
            seq = nextSequence(),
        })
        update()
        say("Preview shown. Right-click the icon to dismiss it; shift-drag to move it.")
    elseif command == "casttest" then
        if InCombatLockdown() then say("Test is unavailable in combat."); return end
        local guid, name = UnitGUID("target"), GetUnitName("target", true)
        local isPlayer = UnitIsPlayer("target")
        local isFriend = UnitIsFriend("player", "target")
        if not readable(guid) or type(guid) ~= "string"
            or not readable(name) or type(name) ~= "string"
            or not readable(isPlayer) or not isPlayer
            or not readable(isFriend) or not isFriend then
            say("Target a friendly player to test the prompt.")
            return
        end
        table.insert(queue, {
            kind = "casttest",
            guid = guid,
            name = name,
            force = true,
            expires = GetTime() + expiresAfter,
            seq = nextSequence(),
        })
        update()
        say("Test prompt shown. Click to cast on your target; right-click to dismiss.")
    else
        say("Commands: /buffback spell <ID> | auto | test | casttest | status | clear | debug. "
            .. "Shift-drag the icon to move it; right-click a prompt to dismiss it.")
    end
end

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("UNIT_AURA")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
events:RegisterEvent("UNIT_SPELLCAST_FAILED")
events:RegisterEvent("UNIT_SPELLCAST_FAILED_QUIET")
events:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

events:SetScript("OnEvent", function(_, event, a, updateInfo, spellID)
    if event == "ADDON_LOADED" and a == addonName then
        BuffBackDB = BuffBackDB or {}
        selectedSpellID = BuffBackDB.spellID
        createUI()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Existing buffs can arrive in several updates while the world loads.
        loginBaselineUntil = GetTime() + 5
        for i = #queue, 1, -1 do
            if queue[i].kind == "return" then
                if activeEntry == queue[i] then activeEntry = nil end
                table.remove(queue, i)
            end
        end
        pendingCast = nil
        seen = {}
        baselineComplete = false
        invalidateAutomaticSpell()
        if not InCombatLockdown() then
            scan(true)
            scanParty()
        end
    elseif event == "UNIT_AURA" then
        -- The event payload can itself be secret in restricted content, so the
        -- unit token is only inspected after an explicit readability check.
        local unit = readable(a) and type(a) == "string" and a or nil
        if unit == "player" then
            if not InCombatLockdown() then scan(not baselineComplete, updateInfo) end
        elseif unit and unit:match("^party%d+$") then
            scanParty()
        else
            update()
        end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "SPELLS_CHANGED" then
        if event == "SPELLS_CHANGED" then invalidateAutomaticSpell() end
        scanParty()
        update()
    elseif event == "PLAYER_TARGET_CHANGED"
        or event == "NAME_PLATE_UNIT_ADDED"
        or event == "NAME_PLATE_UNIT_REMOVED" then
        update()
    elseif event == "PLAYER_REGEN_DISABLED" then
        pendingCast = nil
        if label then label:Hide(); status:Hide() end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Rebaseline: aura changes in combat cannot be attributed reliably.
        seen = {}
        baselineComplete = false
        scan(true)
        scanParty()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" and a == "player" then
        if castMatches(spellID) then
            local entry = pendingCast.entry
            for i, queued in ipairs(queue) do
                if queued == entry then
                    if queued.kind == "party" or queued.kind == "self" then
                        partyDismissed[queued.guid] = GetTime() + 60
                    end
                    if activeEntry == queued then activeEntry = nil end
                    table.remove(queue, i)
                    break
                end
            end
            pendingCast = nil
            update()
        end
    elseif (event == "UNIT_SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_FAILED_QUIET"
        or event == "UNIT_SPELLCAST_INTERRUPTED") and a == "player" then
        -- A failed click must not leave a pending success that a later cast of
        -- the same spell could claim. The prompt itself is kept.
        if pendingCast and GetTime() - pendingCast.time <= 10
            and (not readable(spellID) or castMatches(spellID)) then
            pendingCast = nil
        end
    end
end)

local elapsed = 0
events:SetScript("OnUpdate", function(_, delta)
    elapsed = elapsed + delta
    partyElapsed = partyElapsed + delta

    if partyElapsed >= 3 then
        partyElapsed = 0
        if not InCombatLockdown() and not aurasAreSecret() then
            -- A periodic merge-scan recovers buffs whose UNIT_AURA payload was
            -- hidden by the client, without re-prompting for known auras.
            scan(not baselineComplete)
        end
        scanParty()
    end

    if elapsed >= 1 then
        elapsed = 0
        if pendingCast and GetTime() - pendingCast.time > 10 then pendingCast = nil end
        if #queue > 0 or activeEntry then update() end
    end
end)
