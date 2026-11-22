-- Huntard: ViperAlert.lua
-- Suggests switching TO Aspect of the Viper once mana drops to/below a low
-- threshold, and suggests switching BACK once mana recovers to/above a
-- separate, higher threshold -- two different numbers on purpose (not one
-- shared cutoff) so it doesn't flicker back and forth right at a single
-- boundary.
--
-- Never suggests Viper at all if you don't currently know it -- gated via
-- IsSpellKnown (modernized: C_SpellBook.IsSpellKnown, falling back to
-- IsPlayerSpell -- confirmed real compat pattern via Questie's own
-- QuestieCompat.lua on this exact client), so there's no need to hardcode
-- or research Forever's actual level requirement for it at all: if the
-- game says you don't know it yet, this just stays silent.
--
-- Reads your CURRENT aspect via H.AspectAlert.GetTrackedAspect() rather
-- than tracking it separately -- that's already cast-event-tracked there
-- for the exact same reason (aspect buffs are secret-read-blocked in
-- combat, see AspectAlert.lua's header), no need to duplicate it.

local H = Huntard
H.ViperAlert = H.ViperAlert or {}

local VIPER_NAME = "Aspect of the Viper"
local HAWK_NAME = "Aspect of the Hawk"
local MIN_THRESHOLD, MAX_THRESHOLD = 0, 100

local viperIcon, hawkIcon, viperSpellId
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

-- Returns (status, icon):
--   status == "toViper"   -> mana is low, not currently in Viper -> suggest switching to it
--   status == "fromViper" -> currently in Viper, mana has recovered -> suggest switching back
--   status == nil         -> nothing to suggest (includes: Viper not known yet)
function H.ViperAlert.GetStatus()
	if not isSpellKnownCompat(viperSpellId) then return nil end

	local maxMana = UnitPowerMax("player", POWER_MANA)
	if not maxMana or maxMana <= 0 then return nil end
	local pct = (UnitPower("player", POWER_MANA) / maxMana) * 100

	local current = H.AspectAlert and H.AspectAlert.GetTrackedAspect and H.AspectAlert.GetTrackedAspect()
	if current == VIPER_NAME then
		if pct >= H.db.viperAlert.highThreshold then
			return "fromViper", hawkIcon
		end
		return nil
	end

	if pct <= H.db.viperAlert.lowThreshold then
		return "toViper", viperIcon
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

function H.ViperAlert.Init()
	local _, _, icon, spellId = getSpellInfoCompat(VIPER_NAME)
	viperIcon, viperSpellId = icon, spellId
	local _, _, hIcon = getSpellInfoCompat(HAWK_NAME)
	hawkIcon = hIcon
end
