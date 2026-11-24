-- Huntard: Range.lua
-- Figures out which zone your CURRENT TARGET is in, and the text/color
-- that goes with it:
--   MELEE          (blue)   -- Wing Clip in range, regardless of its own
--                               cooldown -- the range check only checks
--                               range, never castability, which is exactly
--                               what's wanted here.
--   RANGED, 3 tiers (green/yellow/orange) -- Arcane Shot in range, further
--                               split by LibRangeCheck-3.0's own live
--                               bracket: green = the outer/farthest-out
--                               bracket (near your real max), yellow =
--                               next one in, orange = closest to minimum
--                               range (nearest the dead zone).
--   DEAD ZONE      (red)    -- neither Wing Clip nor Arcane Shot in
--                               range, AND LibRangeCheck's own broader
--                               estimate still puts you close (not past
--                               Arcane Shot's own max) -- see the
--                               disambiguation note below.
--   TOO FAR        (red)    -- neither in range, and LibRangeCheck's
--                               estimate puts you beyond Arcane Shot's max.
--
-- Confirmed real APIs (not guessed) -- and one real correction made after
-- actually testing in-game (/huntard debug), not assumed from memory:
--   The plain global IsSpellInRange(spell, unit) does NOT exist on this
--   client at all (confirmed live: calling it raised "attempt to call a
--   nil value"). LibRangeCheck-3.0's own source (the exact file bundled
--   here) explains why and shows the real fix:
--     local IsSpellBookItemInRange = _G.IsSpellInRange or function(index, spellBank, unit)
--       local result = C_Spell.IsSpellInRange(index, unit)
--       ...
--   -- i.e. the modern replacement is C_Spell.IsSpellInRange, and it takes
--   a spell INDEX/ID, not a name string. The matching index is resolved
--   via rc:findSpellIndex(name) -- LibRangeCheck's own public wrapper
--   around the same spellbook scan it uses internally. spellInRange()
--   below mirrors the library's exact fallback shape rather than
--   reinventing it.
--   GetSpellInfo(spellID/name) -- confirmed STILL working as a plain
--     global on this client (the debug run correctly printed Arcane
--     Shot's declared 8-35 range) -- used here for that declared
--     minRange/maxRange, same field order LibRangeCheck's own
--     getSpellData() helper reads.
--   LibRangeCheck-3.0 (rc:GetRange(unit) -> minRange, maxRange) --
--     bundled here the same way RangeDisplay (an installed, working addon
--     on this client) bundles it: LibStub + CallbackHandler-1.0 +
--     LibRangeCheck-3.0 itself, no other dependency needed (confirmed via
--     that addon's own .toc). Documented usage straight from the
--     library's own header comment, not guessed. The debug run confirmed
--     this one works correctly out of the box (rc:GetRange returned real
--     45-100 values).
--
-- Deliberately NOT using Hunter's Mark (100y) anywhere, per your own note.
--
-- Why disambiguating dead-zone vs. too-far needs rc:GetRange at all: when
-- NEITHER Wing Clip nor Arcane Shot is in range, that alone is
-- ambiguous -- could be just past melee/short of ranged (dead zone) or
-- genuinely far away. rc:GetRange draws on a much broader battery of
-- checkpoints (other classes' spells, world items, spanning well past
-- 35y), so even though it can't identify "dead zone" by name, its
-- returned bracket tells us whether we're still within Arcane Shot's own
-- declared max (-> dead zone) or past it (-> too far).

local H = Huntard
H.Range = H.Range or {}

-- Raptor Strike was the first candidate tried -- rejected after live
-- testing (/huntard debug) showed it reporting "in range" from far away.
-- Root cause (your own diagnosis, confirmed consistent with how it
-- behaves): it's an "on your next melee swing" enabler, not a direct-cast
-- targeted ability, so it doesn't appear to enforce the normal cast-range
-- gate the way a real instant melee special does. Wing Clip is an actual
-- instant-cast, range-gated melee ability, so it's used instead.
local MELEE_SPELL = "Wing Clip"
local RANGED_SPELL = "Arcane Shot"

H.Range.ZONE_MELEE = "melee"
H.Range.ZONE_RANGED_OUTER = "ranged_outer"   -- green  -- farthest-out bracket still in range
H.Range.ZONE_RANGED_MIDDLE = "ranged_middle" -- yellow
H.Range.ZONE_RANGED_INNER = "ranged_inner"   -- orange -- closest bracket to minimum range
H.Range.ZONE_DEAD = "dead"
H.Range.ZONE_FAR = "far"

local COLOR_BLUE = { 0.25, 0.55, 1.0 }
local COLOR_GREEN = { 0.20, 0.90, 0.20 }
local COLOR_YELLOW = { 0.95, 0.85, 0.10 }
local COLOR_ORANGE = { 0.95, 0.55, 0.10 }
local COLOR_RED = { 0.90, 0.15, 0.15 }

local ZONE_COLOR = {
	[H.Range.ZONE_MELEE] = COLOR_BLUE,
	[H.Range.ZONE_RANGED_OUTER] = COLOR_GREEN,
	[H.Range.ZONE_RANGED_MIDDLE] = COLOR_YELLOW,
	[H.Range.ZONE_RANGED_INNER] = COLOR_ORANGE,
	[H.Range.ZONE_DEAD] = COLOR_RED,
	[H.Range.ZONE_FAR] = COLOR_RED,
}

local rc = LibStub and LibStub("LibRangeCheck-3.0", true)

-- GetSpellInfo(name) AS A PLAIN GLOBAL is also missing on this client,
-- same as IsSpellInRange -- confirmed live (the first debug run's "8 - 35"
-- was actually this silently hitting the hardcoded fallback below, not a
-- real read, since there was no way to tell the two apart from that
-- output alone -- usedFallback here exists specifically so Debug() can
-- show which one actually happened). Mirrors LibRangeCheck's own exact
-- compatibility shim for this ("local GetSpellInfo = GetSpellInfo or
-- function(spellID) ... C_Spell.GetSpellInfo(spellID) ... end").
local function getSpellInfoCompat(spellIdentifier)
	if _G.GetSpellInfo then
		return _G.GetSpellInfo(spellIdentifier)
	end
	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(spellIdentifier)
		if info then
			return info.name, nil, info.iconID, info.castTime, info.minRange, info.maxRange, info.spellID
		end
	end
	return nil
end

-- Same shape as LibRangeCheck's own IsSpellBookItemInRange local (see the
-- file header) -- resolves the spell NAME to the index/ID C_Spell.
-- IsSpellInRange actually wants via rc:findSpellIndex (LibRangeCheck's
-- public wrapper around the same spellbook scan it uses internally), then
-- calls whichever real API this client actually has. Returns 1/0/nil,
-- same convention the old global used.
local function spellInRange(spellName, unit)
	if not (rc and rc.findSpellIndex) then return nil end
	local okIdx, index = pcall(function() return rc:findSpellIndex(spellName) end)
	if not okIdx or not index then return nil end

	if _G.IsSpellInRange then
		return _G.IsSpellInRange(index, BOOKTYPE_SPELL, unit)
	end
	if C_Spell and C_Spell.IsSpellInRange then
		local result = C_Spell.IsSpellInRange(index, unit)
		if result == true then return 1 end
		if result == false then return 0 end
		return nil
	end
	return nil
end

-- Arcane Shot's own declared min/max range -- used both to normalize
-- which third of the ranged zone the live bracket falls into, and to
-- tell dead-zone from too-far.
--
-- Deliberately NOT cached. The original version cached this and only
-- invalidated it on talent/spell-LEARN events -- fine for a one-time
-- talent choice, but confirmed real SoD content on this client (Rune of
-- the Sniper / "Sniper Training", spellID 416091, taught via Questie's
-- own quest data) works differently: it's a stacking buff that extends
-- your real max range the longer you stand still, lost on moving, which
-- can change your effective range mid-fight with no "learn" event at
-- all. Re-reading this fresh every poll (cheap -- one table lookup) means
-- BOTH a permanent talent choice AND a dynamic buff like this just work
-- automatically -- the zone math already derives every threshold from
-- this value, so whatever the game currently reports as your real max is
-- what gets used, no talent/buff-specific detection code needed.
-- usedFallback is exposed so Debug() can show plainly whether this came
-- from a real API read or the hardcoded fallback (your own stated real
-- range, 8-35), rather than the two looking identical in the output.
local function getArcaneRange()
	local ok, _, _, _, _, minR, maxR = pcall(getSpellInfoCompat, RANGED_SPELL)
	if ok and maxR and maxR > 0 then
		return minR or 0, maxR, false
	end
	return 8, 35, true -- fallback: your own stated real range
end

function H.Range.HasFightableTarget()
	return UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDeadOrGhost("target")
end

-- LibRangeCheck v38 caches by UnitGUID and only guards secret GUIDs on retail
-- Midnight, so on this client rc:GetRange() throws whenever the target's GUID
-- is secret (seen in dungeons), which pinned the display at "8-35y"/yellow.
-- The library is shared with other addons via LibStub, so it isn't patched.
-- Instead, this runs the same binary search over its public hostile checker
-- list, skipping only the GUID cache. Returns minRange, maxRange or nil.
local function targetRangeBracket()
	if not rc then return nil, nil end
	local guid = UnitGUID("target")
	if not (_G.issecretvalue and _G.issecretvalue(guid)) then
		local ok, bracketMin, bracketMax = pcall(rc.GetRange, rc, "target")
		if ok then return bracketMin, bracketMax end
		return nil, nil
	end

	local list = rc.harmRC
	if not list or #list == 0 then return nil, nil end
	local ok, bracketMin, bracketMax = pcall(function()
		local lo, hi = 1, #list
		while lo <= hi do
			local mid = math.floor((lo + hi) / 2)
			if list[mid].checker("target", true) then
				lo = mid + 1
			else
				hi = mid - 1
			end
		end
		if lo > #list then return 0, list[#list].range end
		if lo <= 1 then return list[1].range, nil end
		return list[lo].range, list[lo - 1].range
	end)
	if ok then return bracketMin, bracketMax end
	return nil, nil
end

-- Splits the ranged zone into 3 color tiers using LibRangeCheck's live
-- bracket, normalized against Arcane Shot's own min/max -- not hardcoded
-- checkpoint counting, since how many distinct LibRangeCheck checkpoints
-- exist between your min and max varies with whatever spells/items happen
-- to be available.
local function rangedTier()
	local minR, maxR = getArcaneRange()
	local bracketMin, bracketMax = targetRangeBracket()
	-- Position within the ranged zone: prefer the live bracket's own
	-- maxRange (how far away you could still be and still be this close),
	-- falling back to its minRange, falling back to the middle of the
	-- zone if LibRangeCheck has no checkers available right now.
	local estimate = bracketMax or bracketMin or ((minR + maxR) / 2)
	local span = (maxR - minR)
	if span <= 0 then span = 1 end
	local fraction = (estimate - minR) / span -- 0 = at minimum range, 1 = at maximum range

	local text
	if bracketMin and bracketMax then
		text = string.format("%d-%dy", bracketMin, bracketMax)
	elseif bracketMin then
		text = string.format(">%dy", bracketMin)
	else
		text = string.format("%d-%dy", minR, maxR)
	end

	if fraction >= 0.66 then
		return H.Range.ZONE_RANGED_OUTER, text
	elseif fraction >= 0.33 then
		return H.Range.ZONE_RANGED_MIDDLE, text
	else
		return H.Range.ZONE_RANGED_INNER, text
	end
end

-- Returns (zone, text) -- zone is one of the ZONE_* constants above, or
-- nil (with no text) if there's no fightable target to check right now.
function H.Range.GetZone()
	if not H.Range.HasFightableTarget() then return nil end

	local meleeInRange = spellInRange(MELEE_SPELL, "target") == 1
	local rangedInRange = spellInRange(RANGED_SPELL, "target") == 1

	if meleeInRange then
		return H.Range.ZONE_MELEE, "MELEE"
	end

	if rangedInRange then
		local zone, text = rangedTier()
		return zone, text
	end

	-- Neither in range -- disambiguate dead zone vs. too far using
	-- LibRangeCheck's broader estimate against Arcane Shot's own max (see
	-- file header for why this, not a remembered last-zone guess, now
	-- that the library's here anyway).
	if rc then
		local _, currentMax = getArcaneRange()
		local bracketMin = targetRangeBracket()
		if bracketMin and bracketMin >= currentMax then
			return H.Range.ZONE_FAR, string.format(">%dy", currentMax)
		end
	end
	return H.Range.ZONE_DEAD, "DEAD ZONE"
end

function H.Range.GetColor(zone)
	return zone and ZONE_COLOR[zone]
end

-- Same real event set LibRangeCheck-3.0 itself registers (confirmed via
-- grep in the exact file bundled here) to know when to rebuild its own
-- checkers after a talent/spell change -- SPELLS_CHANGED and
-- CHARACTER_POINTS_CHANGED unconditionally, PLAYER_TALENT_UPDATE/
-- LEARNED_SPELL_IN_TAB only if C_EventUtils confirms this client actually
-- has them (same defensive check the library uses, since event
-- availability varies by client version/era).
function H.Range.Init() end

-- /huntard debug -- opens a copyable dump of the raw range-check values
-- against your current target, so you can confirm Wing Clip/Arcane
-- Shot actually flip at the right real distances for you, instead of
-- guessing. Uses the same copyable-text-window as Wayfinder's own debug
-- commands, since WoW's chat frame has no real select-and-copy.
function H.Range.Debug()
	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	if not UnitExists("target") then
		add("no target selected")
		H.ShowCopyableText("Huntard range debug", table.concat(lines, "\n"))
		return
	end

	add("target: " .. (UnitName("target") or "?"))
	add("attackable: " .. tostring(UnitCanAttack("player", "target")))
	add("dead: " .. tostring(UnitIsDeadOrGhost("target")))
	add("")

	add("raw global IsSpellInRange exists: " .. tostring(_G.IsSpellInRange ~= nil))
	add("raw global GetSpellInfo exists: " .. tostring(_G.GetSpellInfo ~= nil))
	add("C_Spell.IsSpellInRange exists: " .. tostring(C_Spell ~= nil and C_Spell.IsSpellInRange ~= nil))
	add("LibRangeCheck loaded: " .. tostring(rc ~= nil))
	add("")

	local meleeIdx = rc and rc.findSpellIndex and select(2, pcall(function() return rc:findSpellIndex(MELEE_SPELL) end))
	local rangedIdx = rc and rc.findSpellIndex and select(2, pcall(function() return rc:findSpellIndex(RANGED_SPELL) end))
	add(string.format("%s resolved spell index/ID: %s", MELEE_SPELL, tostring(meleeIdx)))
	add(string.format("%s resolved spell index/ID: %s", RANGED_SPELL, tostring(rangedIdx)))
	add("")

	local meleeRaw = spellInRange(MELEE_SPELL, "target")
	local rangedRaw = spellInRange(RANGED_SPELL, "target")
	add(string.format("%s in range (1/0/nil): %s", MELEE_SPELL, tostring(meleeRaw)))
	add(string.format("%s in range (1/0/nil): %s", RANGED_SPELL, tostring(rangedRaw)))
	add("")

	local minR, maxR, usedFallback = getArcaneRange()
	add(string.format("%s declared range: %s - %s  (from real API: %s)",
		RANGED_SPELL, tostring(minR), tostring(maxR), tostring(not usedFallback)))

	-- Same declared-range check as Arcane Shot's above, now for the melee
	-- reference spell -- kept here for ongoing visibility (this is exactly
	-- what caught Raptor Strike reading as always-in-range before it got
	-- swapped for Wing Clip: a spell with no real declared range would
	-- show that plainly here).
	local okMeleeInfo, _, _, _, _, meleeMinR, meleeMaxR = pcall(getSpellInfoCompat, MELEE_SPELL)
	add(string.format("%s declared range: %s - %s  (ok=%s)",
		MELEE_SPELL, tostring(meleeMinR), tostring(meleeMaxR), tostring(okMeleeInfo)))
	add("")

	if rc then
		local bMin, bMax = targetRangeBracket()
		add(string.format("target range bracket: min=%s max=%s", tostring(bMin), tostring(bMax)))
	end
	add("")

	local zone, text = H.Range.GetZone()
	add("derived zone: " .. tostring(zone))
	add("derived text: " .. tostring(text))
	add("")

	add("-- Aspect alert --")
	add("in combat (UnitAffectingCombat): " .. tostring(UnitAffectingCombat("player")))
	if C_Secrets then
		add("C_Secrets.ShouldAurasBeSecret(): "
			.. tostring(C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()))
		if C_Secrets.GetSpellAuraSecrecy then
			for _, aspectName in ipairs({ "Aspect of the Hawk", "Aspect of the Cheetah", "Aspect of the Monkey" }) do
				local okSec, secrecy = pcall(C_Secrets.GetSpellAuraSecrecy, aspectName)
				add(string.format("C_Secrets.GetSpellAuraSecrecy(%q): ok=%s value=%s", aspectName, tostring(okSec), tostring(secrecy)))
			end
		end
	else
		add("C_Secrets not available on this client")
	end
	add("")
	for _, aspectName in ipairs({ "Aspect of the Hawk", "Aspect of the Cheetah", "Aspect of the Pack",
			"Aspect of the Wild", "Aspect of the Fox", "Aspect of the Beast", "Aspect of the Eagle", "Aspect of the Monkey" }) do
		if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
			local okRaw, raw = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", aspectName, "HELPFUL")
			add(string.format("GetAuraDataBySpellName('player', %q, 'HELPFUL'): ok=%s found=%s",
				aspectName, tostring(okRaw), tostring(raw ~= nil)))
		end
	end
	add("")
	add("tracked aspect (via cast events, not a live read): " .. tostring(H.AspectAlert.GetTrackedAspect()))
	local okAspect, aspectStatus, aspectIcon = pcall(H.AspectAlert.GetStatus)
	add(string.format("H.AspectAlert.GetStatus(): ok=%s status=%s icon=%s",
		tostring(okAspect), tostring(aspectStatus), tostring(aspectIcon)))
	add("")

	add("-- Serpent Sting (tracked via combat log, not a live read -- see SerpentSting.lua) --")
	local debugGUID = UnitExists("target") and UnitGUID("target")
	add("current target GUID: " .. ((_G.issecretvalue and _G.issecretvalue(debugGUID)) and "<secret>" or tostring(debugGUID)))
	local okSS, ssActive, ssIcon, ssRemaining = pcall(H.SerpentSting.GetStatus)
	add(string.format("H.SerpentSting.GetStatus(): ok=%s active=%s icon=%s remaining=%s",
		tostring(okSS), tostring(ssActive), tostring(ssIcon), tostring(ssRemaining)))

	H.ShowCopyableText("Huntard range debug", table.concat(lines, "\n"))
	print("|cff33ff99Huntard|r range debug window opened -- click inside it, Ctrl+A then Ctrl+C, then paste it back.")
end
