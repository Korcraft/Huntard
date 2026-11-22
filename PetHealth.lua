-- Huntard: PetHealth.lua
-- No longer owns a frame of its own -- see AlertCluster.lua, which draws
-- and positions every icon-style alert (this one, plus AlertIcon.lua)
-- relative to one shared, player-placed anchor point instead of each
-- having its own independently-positioned window.
--
-- Reports nothing while you have no pet out. Reports Mend Pet's own spell
-- icon (no text/number, just the icon) once health drops to/below the
-- configured threshold -- a glance at the icon tells you exactly what to
-- cast, same idea as the aspect alert using each aspect's own icon rather
-- than a generic warning symbol. Reports the pet's own portrait with a red
-- diagonal slash across it if it's dead (SetPortraitTexture -- the same
-- standard API every default unit frame uses to render a unit's 3D
-- portrait, not secret/restricted information).
--
-- REAL FIX for a real restriction, not a workaround for a guess:
-- UnitHealth("pet") (and UnitHealth("player")) come back as the "secret"
-- Lua value type on this client -- confirmed live via a crash ("attempt to
-- perform arithmetic on a secret number value"), and confirmed it's NOT
-- combat-tied (reproduced solo, out of combat, no instance) -- unlike
-- everything else "secret" in this addon so far. Grepped Details' own
-- source for how it handles this on this exact client (it has a whole
-- separate unitframe_midnight.lua implementation, used instead of its
-- normal one whenever DetailsFramework.IsMidnightWowAPI() is true -- which
-- it is here, since Forever's build number falls in that checked range)
-- and confirmed via TellMeWhen's LibDogTag-Unit-3.0/Categories/Health.lua
-- (which explicitly branches on `C_Secrets.HasSecretRestrictions()`):
-- Blizzard ships a DEDICATED replacement API for exactly this --
-- UnitHealthPercent(unit, useAbsorbs, curveConstant) -- that returns an
-- already-computed percentage without ever exposing the raw secret
-- number. This is the intended, official fix, not a trick -- the
-- "CurveConstants" table (confirmed via grep as a real global, not
-- something to require) controls the output scale; CurveConstants.ScaleTo100
-- gives a plain 0-100 number, matching the exact call shape both TellMeWhen
-- and Details use (`UnitHealthPercent(unit, true, CurveConstants.ScaleTo100)`).

local H = Huntard
H.PetHealth = H.PetHealth or {}

local MIN_THRESHOLD, MAX_THRESHOLD = 10, 75
local MEND_PET_NAME = "Mend Pet"

local mendPetIcon

-- GetSpellInfo -- NOT an aura read, confirmed unaffected by the secrecy
-- restriction (see AspectAlert.lua/SerpentSting.lua headers) -- used once
-- to fetch Mend Pet's own icon for display.
local function getSpellInfoCompat(identifier)
	if _G.GetSpellInfo then
		return _G.GetSpellInfo(identifier)
	end
	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(identifier)
		if info then return info.name, nil, info.iconID end
	end
	return nil
end

local hasSecretRestrictions = C_Secrets and C_Secrets.HasSecretRestrictions and C_Secrets.HasSecretRestrictions()

-- Returns a 0-100 health percent for `unit`, or nil if it genuinely can't
-- be determined right now. Prefers UnitHealthPercent (the secrecy-safe
-- replacement) when this client has secret restrictions at all; falls back
-- to plain UnitHealth/UnitHealthMax division otherwise (older clients
-- without either the restriction or the replacement API).
local function getHealthPercent(unit)
	if hasSecretRestrictions and _G.UnitHealthPercent then
		local ok, pct = pcall(_G.UnitHealthPercent, unit, true, CurveConstants and CurveConstants.ScaleTo100)
		if ok and pct and not (_G.issecretvalue and _G.issecretvalue(pct)) then
			return pct
		end
		return nil
	end

	local maxHealth, health = UnitHealthMax(unit), UnitHealth(unit)
	if not maxHealth or maxHealth <= 0 or not health then return nil end
	if _G.issecretvalue and (_G.issecretvalue(maxHealth) or _G.issecretvalue(health)) then return nil end
	return (health / maxHealth) * 100
end

function H.PetHealth.SetThreshold(pct)
	pct = math.max(MIN_THRESHOLD, math.min(MAX_THRESHOLD, math.floor(pct)))
	H.db.petHealth.threshold = pct
	return pct
end

-- Returns a display status table, or nil if nothing to show (including:
-- health is currently unreadable -- fails safe to "don't alert" rather
-- than guessing).
--   { portrait = "pet", slash = true } or { texture = mendPetIcon }
function H.PetHealth.GetDisplayStatus()
	if not UnitExists("pet") then return nil end

	if UnitIsDeadOrGhost("pet") then
		return { portrait = "pet", slash = true }
	end

	local pct = getHealthPercent("pet")
	if not pct or pct > H.db.petHealth.threshold then return nil end

	return { texture = mendPetIcon }
end

-- /huntard calls into this to show a live reading alongside the configured
-- threshold, since the threshold alone doesn't tell you whether you're
-- actually currently under/over it -- out-of-combat pet regen is fast
-- enough that it's easy to check a moment too late and see nothing.
function H.PetHealth.GetLiveReadout()
	if not UnitExists("pet") then return "no pet out" end
	if UnitIsDeadOrGhost("pet") then return "pet is dead" end
	local pct = getHealthPercent("pet")
	if not pct then return "unreadable right now" end
	return string.format("%d%%", pct)
end

-- /huntard pethealthdebug -- dumps exactly what's readable/secret about
-- pet health right now, and confirms which path (UnitHealthPercent vs
-- plain division) is actually in use on this client.
function H.PetHealth.Debug()
	local lines = {}
	local function add(s) table.insert(lines, s) end

	add("pet exists: " .. tostring(UnitExists("pet")))
	add("pet dead/ghost: " .. tostring(UnitIsDeadOrGhost("pet")))
	add("player in combat (UnitAffectingCombat): " .. tostring(UnitAffectingCombat("player")))
	add("")
	add("C_Secrets.HasSecretRestrictions(): " .. tostring(hasSecretRestrictions))
	add("_G.UnitHealthPercent exists: " .. tostring(_G.UnitHealthPercent ~= nil))
	add("_G.CurveConstants exists: " .. tostring(_G.CurveConstants ~= nil))
	add("_G.CurveConstants.ScaleTo100: " .. tostring(_G.CurveConstants and _G.CurveConstants.ScaleTo100))
	add("")

	local function checkUnit(unit)
		if not UnitExists(unit) then
			add(unit .. ": doesn't exist")
			return
		end
		local h, m = UnitHealth(unit), UnitHealthMax(unit)
		add(string.format("%s: UnitHealth secret=%s  UnitHealthMax secret=%s  getHealthPercent()=%s",
			unit, tostring(_G.issecretvalue and _G.issecretvalue(h)),
			tostring(_G.issecretvalue and _G.issecretvalue(m)),
			tostring(getHealthPercent(unit))))
	end
	checkUnit("pet")
	checkUnit("player")

	H.ShowCopyableText("Huntard pet health debug", table.concat(lines, "\n"))
end

function H.PetHealth.Init()
	local _, _, icon = getSpellInfoCompat(MEND_PET_NAME)
	mendPetIcon = icon
end
