-- Huntard: ViperAlert.lua
-- A pure mana warning for Viper Sting (WoW Forever has no Aspect of the
-- Viper). The icon turns on at/below the low threshold and stays on until
-- mana reaches the high threshold. It shares a cluster slot with the Serpent
-- Sting countdown, which takes over for its final seconds (see AlertIcon.lua).
--
-- Stays silent until you know Viper Sting, re-checking so that learning it
-- needs no reload.
--
-- Mana may be a secret value on this client (untested, hence /huntard
-- manadebug), so every read is checked first. An unreadable read changes
-- nothing and can never take down the Serpent Sting countdown in this slot.

local H = Huntard
H.ViperAlert = H.ViperAlert or {}

local VIPER_STING_NAME = "Viper Sting"
local VIPER_STING_SPELL_ID = 3034 -- rank 1
local VIPER_STING_FALLBACK_ICON = "Interface\\Icons\\Ability_Hunter_AimedShot"
local MIN_THRESHOLD, MAX_THRESHOLD = 0, 100

local viperIcon
local viperKnown = false
local manaWarningOn = false -- on at the low threshold, off at the high one
local POWER_MANA = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0

local function getSpellInfoCompat(identifier)
	if _G.GetSpellInfo then
		return _G.GetSpellInfo(identifier)
	end
	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(identifier)
		if info then return info.name, nil, info.iconID, info.spellID end
	end
	return nil
end

-- Modernized compat: C_SpellBook.IsSpellKnown, falling back to
-- IsPlayerSpell -- confirmed real pattern via Questie's own
-- QuestieCompat.IsSpellKnown on this client.
local function isSpellKnownCompat(spellId)
	if not spellId then return false end
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		return C_SpellBook.IsSpellKnown(spellId)
	end
	if _G.IsPlayerSpell then
		return _G.IsPlayerSpell(spellId)
	end
	return false
end

-- Checks rank 1 and whichever rank the name resolves to.
local function knowsViperSting()
	if viperKnown then return true end
	local _, _, icon, fourth, _, _, seventh = getSpellInfoCompat(VIPER_STING_NAME)
	if icon then viperIcon = icon end
	local resolvedId = seventh or fourth
	viperKnown = (isSpellKnownCompat(VIPER_STING_SPELL_ID) or isSpellKnownCompat(resolvedId)) and true or false
	return viperKnown
end

local function isSecret(value)
	return _G.issecretvalue and _G.issecretvalue(value)
end

-- Returns mana as 0-100, or nil if it can't be read right now.
local function readManaPercent()
	local okMax, maxMana = pcall(UnitPowerMax, "player", POWER_MANA)
	if not okMax or isSecret(maxMana) or type(maxMana) ~= "number" or maxMana <= 0 then return nil end
	local okMana, mana = pcall(UnitPower, "player", POWER_MANA)
	if not okMana or isSecret(mana) or type(mana) ~= "number" then return nil end
	return (mana / maxMana) * 100
end

-- Returns ("low", icon) while the mana warning is on, otherwise nil.
-- If mana becomes unreadable, the warning keeps its last state.
function H.ViperAlert.GetStatus()
	if not knowsViperSting() then return nil end

	local pct = readManaPercent()
	if pct then
		if pct <= H.db.viperAlert.lowThreshold then
			manaWarningOn = true
		elseif pct >= H.db.viperAlert.highThreshold then
			manaWarningOn = false
		end
	end

	if manaWarningOn then
		return "low", viperIcon or VIPER_STING_FALLBACK_ICON
	end
	return nil
end

function H.ViperAlert.SetLowThreshold(pct)
	pct = math.max(MIN_THRESHOLD, math.min(H.db.viperAlert.highThreshold - 1, math.floor(pct)))
	H.db.viperAlert.lowThreshold = pct
	return pct
end

function H.ViperAlert.SetHighThreshold(pct)
	pct = math.max(H.db.viperAlert.lowThreshold + 1, math.min(MAX_THRESHOLD, math.floor(pct)))
	H.db.viperAlert.highThreshold = pct
	return pct
end

-- /huntard manadebug -- run once out of combat and once mid-fight. Works
-- before Viper Sting is learned, since it only reports whether mana is readable.
function H.ViperAlert.DebugMana()
	local function describe(ok, value)
		if not ok then return "error" end
		if isSecret(value) then return "BLOCKED (secret)" end
		return tostring(value)
	end
	local okMax, maxMana = pcall(UnitPowerMax, "player", POWER_MANA)
	local okMana, mana = pcall(UnitPower, "player", POWER_MANA)
	local pct = readManaPercent()
	print("|cff33ff99Huntard|r mana check -- in combat: " .. tostring(UnitAffectingCombat("player") and true or false)
		.. ", in instance: " .. tostring(IsInInstance() and true or false))
	print("  current mana: " .. describe(okMana, mana) .. "  max mana: " .. describe(okMax, maxMana))
	print("  result: " .. (pct and string.format("READABLE (%d%%)", pct) or "NOT READABLE"))
	print("  Viper Sting known: " .. tostring(knowsViperSting()) .. "  warning on: " .. tostring(manaWarningOn))
end

function H.ViperAlert.Init()
	local _, _, icon = getSpellInfoCompat(VIPER_STING_SPELL_ID)
	viperIcon = icon
end
