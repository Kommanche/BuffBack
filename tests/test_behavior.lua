H = dofile("harness.lua")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then
        pass = pass + 1
        H.stdout("PASS " .. name)
    else
        fail = fail + 1
        H.stdout("FAIL " .. name .. (detail ~= nil and ("  :: " .. tostring(detail)) or ""))
    end
end

local function paladinSetup()
    H.resetAll()
    H.addUnit("player", "Player-1-0000", "Me", { class = "Paladin", classFile = "PALADIN" })
    H.spellInfo[20217] = { name = "Blessing of Kings", iconID = 135995 }
    H.spellInfo[19740] = { name = "Blessing of Might", iconID = 135906 }
    H.known[20217] = true
    H.book = { { name = "Blessing of Kings", spellID = 20217, isPassive = false, isOffSpec = false } }
    H.addAura("player", {
        name = "Blessing of Kings", auraInstanceID = 1, sourceUnit = "player",
        spellId = 20217, expirationTime = 100000,
    })
    H.load()
    H.fire("PLAYER_ENTERING_WORLD")
    H.now = H.now + 6
    H.tick(3)
end

-- A. Self reminder when the player is missing their own buff.
do
    H.baseSetup({ noSelfBuff = true })
    check("self reminder appears when unbuffed", H.button.shown == true)
    check("self reminder casts on the player", H.button.attributes.unit == "player", H.button.attributes.unit)
    check("self reminder label is clear", H.label and H.label.text == "Buff yourself?", H.label and H.label.text)

    H.click("LeftButton")
    H.fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 1126)
    check("self reminder clears after casting", H.button.shown == false)

    H.tick(3)
    check("self reminder stays dismissed for a while", H.button.shown == false)
    H.now = H.now + 61
    H.tick(3)
    check("self reminder returns after the pause", H.button.shown == true)
end

-- B. Party reminder appears only in range, and disappears when out of range.
do
    H.baseSetup()
    H.addUnit("party1", "Player-5-EEEE", "Partyone")
    H.fire("GROUP_ROSTER_UPDATE")
    check("party reminder appears in range", H.button.shown == true)
    check("party reminder targets the member", H.button.attributes.unit == "party1", H.button.attributes.unit)
    check("party label names the member", H.label and H.label.text == "Buff Partyone?", H.label and H.label.text)

    H.range.party1 = false
    H.fire("GROUP_ROSTER_UPDATE")
    check("party reminder disappears out of range", H.button.shown == false)

    H.range.party1 = true
    H.addAura("party1", { name = "Mark of the Wild", auraInstanceID = 7, sourceUnit = "player", expirationTime = 100000 })
    H.fire("GROUP_ROSTER_UPDATE")
    check("party reminder absent when member has the buff", H.button.shown == false)
end

-- C. A return-buff prompt outranks a party reminder and shows the extra count.
do
    H.baseSetup()
    H.addUnit("party1", "Player-5-EEEE", "Partyone")
    H.fire("GROUP_ROSTER_UPDATE")
    check("party reminder shown first", H.button.attributes.unit == "party1", H.button.attributes.unit)

    H.addUnit("nameplate1", "Player-2-AAAA", "Stranger")
    local aura = { name = "Mark of the Wild", auraInstanceID = 41, sourceUnit = "nameplate1", spellId = 1126, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura }, updatedAuraInstanceIDs = {} })
    check("return prompt outranks party reminder", H.button.attributes.unit == "nameplate1", H.button.attributes.unit)
    check("label counts the waiting party reminder", H.label and H.label.text == "Buff back Stranger?  (+1)",
        H.label and H.label.text)
end

-- D. Right-click dismissal pauses a party reminder for 60 seconds.
do
    H.baseSetup()
    H.addUnit("party1", "Player-5-EEEE", "Partyone")
    H.fire("GROUP_ROSTER_UPDATE")
    check("reminder shown before dismissal", H.button.shown == true)

    H.click("RightButton")
    check("right-click dismisses the reminder", H.button.shown == false)
    H.fire("GROUP_ROSTER_UPDATE")
    check("dismissed reminder does not immediately return", H.button.shown == false)

    H.now = H.now + 61
    H.fire("GROUP_ROSTER_UPDATE")
    check("reminder returns after the pause", H.button.shown == true)
end

-- E. Reported case: a paladin's Blessing of Kings prompts a Kings cast back.
do
    paladinSetup()
    H.addUnit("nameplate1", "Player-7-GGGG", "Pally")
    local aura = { name = "Blessing of Kings", auraInstanceID = 51, sourceUnit = "nameplate1", spellId = 20217, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura }, updatedAuraInstanceIDs = {} })

    check("Kings buff prompts a return", H.button.shown == true)
    check("Kings prompt targets the paladin", H.button.attributes.unit == "nameplate1", H.button.attributes.unit)
    check("Kings prompt casts Kings back", H.button.attributes.spell == 20217, H.button.attributes.spell)

    H.click("LeftButton")
    H.fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 20217)
    check("Kings prompt clears after the cast", H.button.shown == false)
end

-- F. A different class buff still triggers a return buff (primary feature).
do
    H.baseSetup()
    H.addUnit("nameplate1", "Player-2-AAAA", "Mage")
    local aura = { name = "Arcane Intellect", auraInstanceID = 61, sourceUnit = "nameplate1", spellId = 1459, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura }, updatedAuraInstanceIDs = {} })
    check("foreign buff prompts a return", H.button.shown == true and H.button.attributes.unit == "nameplate1",
        H.button.attributes.unit)
    check("return cast uses the player's own buff", H.button.attributes.spell == 1126, H.button.attributes.spell)
end

-- G. Your own buffs and non-player casters are ignored.
do
    H.baseSetup()
    local own = { name = "Mark of the Wild", auraInstanceID = 71, sourceUnit = "player", spellId = 1126, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { own }, updatedAuraInstanceIDs = {} })
    check("own buff is ignored", H.button.shown == false)

    H.addUnit("nameplate2", "Creature-0-1234", "Wolf", { player = false })
    local npc = { name = "Mark of the Wild", auraInstanceID = 72, sourceUnit = "nameplate2", spellId = 1126, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { npc }, updatedAuraInstanceIDs = {} })
    check("non-player caster is ignored", H.button.shown == false)
end

-- H. Combat: incoming buffs are not attributed while locked down; recovery is clean.
do
    H.baseSetup()
    H.combat = true
    H.fire("PLAYER_REGEN_DISABLED")
    H.addUnit("nameplate1", "Player-2-AAAA", "Stranger")
    local inCombat = { name = "Mark of the Wild", auraInstanceID = 81, sourceUnit = "nameplate1", spellId = 1126, expirationTime = H.now + 600 }
    H.addAura("player", inCombat)
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { inCombat }, updatedAuraInstanceIDs = {} })
    check("nothing is shown during combat", H.button.shown == false)

    H.combat = false
    H.fire("PLAYER_REGEN_ENABLED")
    check("combat buffs are not guessed after combat", H.button.shown == false)

    H.addUnit("nameplate2", "Player-4-CCCC", "After")
    local after = { name = "Mark of the Wild", auraInstanceID = 82, sourceUnit = "nameplate2", spellId = 1126, expirationTime = H.now + 600 }
    H.addAura("player", after)
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { after }, updatedAuraInstanceIDs = {} })
    check("new buff after combat prompts", H.button.shown == true and H.button.attributes.unit == "nameplate2",
        H.button.attributes.unit)
end

-- I. /buffback test is a preview that never sets up a cast, even if clicked.
do
    H.baseSetup()
    H.cmd("test")
    check("preview is shown", H.button.shown == true)
    check("preview has no spell action", H.button.attributes.type == nil, H.button.attributes.type)
    check("preview label says so", H.label and H.label.text == "Preview: buff back Example player?",
        H.label and H.label.text)

    H.click("LeftButton")
    H.fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 1126)
    check("clicking a preview never clears it as a cast", H.button.shown == true)
    check("preview still has no spell action", H.button.attributes.type == nil, H.button.attributes.type)

    H.click("RightButton")
    check("right-click dismisses the preview", H.button.shown == false)
end

-- J. /buffback casttest performs a real cast on the target without retargeting.
do
    H.baseSetup()
    H.addUnit("target", "Player-6-FFFF", "Friend")
    H.cmd("casttest")
    check("casttest prompt is shown", H.button.shown == true)
    check("casttest targets the current target", H.button.attributes.unit == "target", H.button.attributes.unit)
    check("casttest sets up a real spell action", H.button.attributes.type == "spell", H.button.attributes.type)
    check("casttest never sets a target attribute", H.button.attributes.target == nil)
    check("casttest label is distinct", H.label and H.label.text == "Test: buff Friend?", H.label and H.label.text)

    H.click("LeftButton")
    H.fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 1126)
    check("casttest prompt clears after casting", H.button.shown == false)
end

-- K. /buffback clear removes everything and pauses reminders.
do
    H.baseSetup()
    H.addUnit("party1", "Player-5-EEEE", "Partyone")
    H.fire("GROUP_ROSTER_UPDATE")
    check("reminder exists before clear", H.button.shown == true)
    H.cmd("clear")
    check("clear hides the prompt", H.button.shown == false)
    H.fire("GROUP_ROSTER_UPDATE")
    check("clear pauses the reminder", H.button.shown == false)
end

-- L. A click during combat still clears the prompt on success (via stored spell).
do
    H.baseSetup()
    H.addUnit("nameplate1", "Player-2-AAAA", "Stranger")
    local aura = { name = "Mark of the Wild", auraInstanceID = 91, sourceUnit = "nameplate1", spellId = 1126, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura }, updatedAuraInstanceIDs = {} })
    check("prompt exists before combat cast", H.button.shown == true)

    H.combat = true
    H.fire("PLAYER_REGEN_DISABLED")
    H.click("LeftButton")
    H.fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 1126)

    H.combat = false
    H.fire("PLAYER_REGEN_ENABLED")
    check("combat success clears the prompt after combat", H.button.shown == false)
end

-- M. A hidden UNIT_AURA payload is recovered by the periodic merge-scan.
do
    H.baseSetup()
    H.addUnit("nameplate1", "Player-2-AAAA", "Stranger")
    local aura = { name = "Mark of the Wild", auraInstanceID = 95, sourceUnit = "nameplate1", spellId = 1126, expirationTime = H.now + 600 }
    H.addAura("player", aura)
    H.fire("UNIT_AURA", "player", { __secret = true })
    check("hidden payload does not prompt immediately", H.button.shown == false)

    H.tick(3)
    check("periodic scan recovers the hidden buff", H.button.shown == true and H.button.attributes.unit == "nameplate1",
        H.button.attributes.unit)
end

-- N. Harmful auras in the payload never prompt a buff-back.
do
    H.baseSetup()
    H.addUnit("nameplate1", "Player-8-HHHH", "Rogue")
    local poison = { name = "Deadly Poison", auraInstanceID = 101, sourceUnit = "nameplate1", isHelpful = false, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { poison }, updatedAuraInstanceIDs = {} })
    check("debuffs do not prompt a buff-back", H.button.shown == false)
    H.cmd("status")
    check("debuff scan keeps the baseline ready", H.outputContains("baseline: ready"))
end

H.stdout(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
