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

local function baselineReady()
    H.cmd("status")
    return H.outputContains("baseline: ready")
end

-- 1. A stranger's new buff prompts, naming the stranger, with a cast on their unit.
do
    H.baseSetup()
    check("baseline becomes ready", baselineReady())
    check("no prompt before any buff", H.button.shown == false)

    H.addUnit("nameplate1", "Player-2-AAAA", "Stranger")
    local aura = { name = "Mark of the Wild", auraInstanceID = 11, sourceUnit = "nameplate1", spellId = 1126, expirationTime = H.now + 600 }
    H.addAura("player", aura)
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura }, updatedAuraInstanceIDs = {} })

    check("prompt shown for new buff", H.button.shown == true)
    check("prompt casts on the stranger", H.button.attributes.unit == "nameplate1", H.button.attributes.unit)
    check("prompt uses the buff spell", H.button.attributes.spell == 1126, H.button.attributes.spell)
    check("prompt is a spell action", H.button.attributes.type == "spell", H.button.attributes.type)
    check("label names the stranger", H.label and H.label.text == "Buff back Stranger?", H.label and H.label.text)
    check("no prompt-count suffix for one entry", H.label and not H.label.text:find("(+)", 1, true))

    H.click("LeftButton")
    H.fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 1126)
    check("prompt hides after a successful cast", H.button.shown == false)
    check("button attributes cleared after cast", H.button.attributes.unit == nil and H.button.attributes.spell == nil)
end

-- 2. Caster recovered from GetAuraCasterGUID when sourceUnit is withheld.
do
    H.baseSetup()
    H.addUnit("target", "Player-3-BBBB", "Bob")
    H.casterGUID.player = { [12] = "Player-3-BBBB" }
    local aura = { name = "Mark of the Wild", auraInstanceID = 12, sourceUnit = nil, spellId = 1126, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura }, updatedAuraInstanceIDs = {} })

    check("prompt recovered through caster GUID", H.button.shown == true)
    check("recovered prompt targets the caster", H.button.attributes.unit == "target", H.button.attributes.unit)
    check("recovered prompt names the caster", H.label and H.label.text == "Buff back Bob?", H.label and H.label.text)
end

-- 3. Secret auras do not error, and the addon recovers once they are readable.
do
    H.baseSetup()
    -- Re-baseline from scratch with secrets active, as happens in combat.
    H.secrets = true
    H.fire("PLAYER_ENTERING_WORLD")
    local ok = pcall(function()
        H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = {}, updatedAuraInstanceIDs = {} })
    end)
    check("secret auras never raise an error", ok)
    check("nothing shown while auras are secret", H.button.shown == false)

    H.secrets = false
    H.now = H.now + 6
    H.tick(3)
    check("baseline recovers after secrets clear", baselineReady())

    H.addUnit("nameplate2", "Player-4-CCCC", "Later")
    local aura = { name = "Mark of the Wild", auraInstanceID = 13, sourceUnit = "nameplate2", spellId = 1126, expirationTime = H.now + 600 }
    H.addAura("player", aura)
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura }, updatedAuraInstanceIDs = {} })
    check("new buff prompts after recovery", H.button.shown == true and H.button.attributes.unit == "nameplate2",
        H.button.attributes.unit)
end

-- 4. A refreshed aura instance prompts again (same person rebuffs you).
do
    H.baseSetup()
    H.addUnit("nameplate1", "Player-2-AAAA", "Stranger")
    local aura = { name = "Mark of the Wild", auraInstanceID = 21, sourceUnit = "nameplate1", spellId = 1126, expirationTime = H.now + 100 }
    H.addAura("player", aura)
    -- Establish the baseline including this aura: no prompt for a pre-existing buff.
    H.fire("PLAYER_ENTERING_WORLD")
    check("pre-existing aura does not prompt", H.button.shown == false)
    H.now = H.now + 6
    H.tick(3)

    aura.expirationTime = H.now + 500
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = {}, updatedAuraInstanceIDs = { 21 } })
    check("refresh prompts again", H.button.shown == true and H.button.attributes.unit == "nameplate1",
        H.button.attributes.unit)
end

-- 5. A recipient that already has the buff is skipped, and the prompt disappears.
do
    H.baseSetup()
    H.addUnit("nameplate1", "Player-2-AAAA", "Stranger")
    local aura = { name = "Mark of the Wild", auraInstanceID = 31, sourceUnit = "nameplate1", spellId = 1126, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura }, updatedAuraInstanceIDs = {} })
    check("prompt exists before skip check", H.button.shown == true)

    H.addAura("nameplate1", { name = "Mark of the Wild", auraInstanceID = 900, sourceUnit = "player", expirationTime = H.now + 600 })
    H.fire("PLAYER_TARGET_CHANGED")
    check("prompt removed when recipient already buffed", H.button.shown == false)
    H.cmd("status")
    check("status explains the skip", H.outputContains("already had it"))
end

-- 6. A failed click keeps the prompt, and a later cast cannot fake success.
do
    H.baseSetup()
    H.addUnit("nameplate1", "Player-2-AAAA", "Stranger")
    local aura = { name = "Mark of the Wild", auraInstanceID = 41, sourceUnit = "nameplate1", spellId = 1126, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura }, updatedAuraInstanceIDs = {} })
    check("prompt exists before failed cast", H.button.shown == true)

    H.click("LeftButton")
    H.fire("UNIT_SPELLCAST_FAILED", "player", nil, 1126)
    check("failed cast keeps the prompt", H.button.shown == true)

    H.fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 1126)
    check("later unrelated success does not clear the prompt", H.button.shown == true)

    H.click("LeftButton")
    H.fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 1126)
    check("prompt clears after the next successful click", H.button.shown == false)
end

-- 7. Success is matched by spell name when the client reports a different rank ID.
do
    H.baseSetup()
    H.addUnit("nameplate1", "Player-2-AAAA", "Stranger")
    H.spellInfo[8903] = { name = "Mark of the Wild", iconID = 136078 }
    local aura = { name = "Mark of the Wild", auraInstanceID = 51, sourceUnit = "nameplate1", spellId = 1126, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura }, updatedAuraInstanceIDs = {} })

    H.click("LeftButton")
    H.fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 8903)
    check("rank-ID mismatch still clears on success", H.button.shown == false)
end

-- 8. If the resolved unit token now points at someone else, the click is neutralised.
do
    H.baseSetup()
    H.addUnit("nameplate1", "Player-2-AAAA", "Stranger")
    local aura = { name = "Mark of the Wild", auraInstanceID = 61, sourceUnit = "nameplate1", spellId = 1126, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura }, updatedAuraInstanceIDs = {} })
    check("prompt exists before token reuse", H.button.shown == true)

    H.units.nameplate1.guid = "Player-9-ZZZZ"
    H.click("LeftButton")
    check("stale token clears the action instead of casting", H.button.attributes.type == nil, H.button.attributes.type)
    H.fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 1126)
    check("stale token cast cannot clear the prompt", H.button.shown == true)
end

-- 9. One unreadable aura does not abort the whole scan.
do
    H.baseSetup()
    H.addUnit("nameplate1", "Player-2-AAAA", "Stranger")
    local aura = { name = "Mark of the Wild", auraInstanceID = 71, sourceUnit = "nameplate1", spellId = 1126, expirationTime = H.now + 600 }
    H.auras.player = { nil, aura }
    H.secretIndex = 1
    local ok = pcall(function()
        H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = {}, updatedAuraInstanceIDs = {} })
    end)
    check("scan survives a partially secret aura list", ok)
    check("buff after a secret slot is still detected", H.button.shown == true and H.button.attributes.unit == "nameplate1",
        H.button.attributes.unit)
end

-- 10. An unknown caster never guesses a target, but the limitation is visible.
do
    H.baseSetup()
    local aura = { name = "Mark of the Wild", auraInstanceID = 81, sourceUnit = nil, spellId = 1126, expirationTime = H.now + 600 }
    H.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura }, updatedAuraInstanceIDs = {} })
    check("unknown caster shows no prompt", H.button.shown == false)
    H.cmd("status")
    check("unknown caster is reported in status", H.outputContains("without a usable caster"))
end

-- Auras streamed after login should become part of the baseline.
do
    H.baseSetup()
    H.addUnit("nameplate1", "Player-2-AAAA", "Earlier caster")
    H.fire("PLAYER_ENTERING_WORLD")
    local aura = { name = "Arcane Intellect", auraInstanceID = 201, sourceUnit = "nameplate1", expirationTime = H.now + 600 }
    H.addAura("player", aura)
    H.fire("UNIT_AURA", "player", { addedAuras = { aura } })
    check("login aura streamed late does not prompt", H.button.shown == false)
    H.now = H.now + 6
    H.tick(3)
    check("login baseline settles without a prompt", H.button.shown == false and baselineReady())
    local newAura = { name = "Blessing of Kings", auraInstanceID = 202, sourceUnit = "nameplate1", expirationTime = H.now + 600 }
    H.addAura("player", newAura)
    H.fire("UNIT_AURA", "player", { addedAuras = { newAura } })
    check("new buff after login is detected with sparse payload", H.button.shown == true)
end

-- Keep unavailable casters queued, but do not show an unactionable prompt.
do
    H.baseSetup()
    H.addUnit("nameplate1", "Player-2-AAAA", "Stranger")
    local aura = { name = "Arcane Intellect", auraInstanceID = 210, sourceUnit = "nameplate1", expirationTime = H.now + 600 }
    H.addAura("player", aura)
    H.fire("UNIT_AURA", "player", { addedAuras = { aura } })
    check("available caster shows return prompt", H.button.shown == true)
    H.units.nameplate1 = nil
    H.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    check("unavailable caster hides return prompt", H.button.shown == false)
    H.addUnit("target", "Player-2-AAAA", "Stranger")
    H.fire("PLAYER_TARGET_CHANGED")
    check("return prompt recovers when caster is resolvable", H.button.shown == true and H.button.attributes.unit == "target")
end

H.stdout(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
