-- Huntard: SerpentSting.lua
-- Tracks Serpent Sting's remaining DEBUFF duration on your CURRENT
-- TARGET, surfacing an alert only during the final 3 seconds before it
-- falls off -- the classic "refresh your DoT now" pattern addons like
-- TellMeWhen build as reactive icons, purpose-built here for this one DoT.
--
-- Does NOT alert when Serpent Sting is simply missing/never applied to
-- the current target -- only when a tracked application is about to
-- expire.
--
-- DOES NOT READ THE LIVE DEBUFF -- confirmed via /huntard debug, run live
-- in combat, that this client marks auras secret during combat
-- (C_Secrets.ShouldAurasBeSecret() == true), which blocks BOTH
-- index-based enumeration and direct by-name aura lookups equally (see
-- AspectAlert.lua's header for the full finding).
--
-- DOES NOT USE THE COMBAT LOG EITHER -- that was the original design
-- (SPELL_AURA_APPLIED/REFRESH/REMOVED, keyed per target GUID), but
-- registering for COMBAT_LOG_EVENT_UNFILTERED at all is blocked on this
-- client for Huntard, confirmed via extensive live bisection:
--   - A plain CreateFrame("Frame"):RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
--     triggers "Huntard has been blocked from an action only available to
--     the Blizzard UI" -- reproducible even with a totally empty handler,
--     so it's not about processing the data, just making that native call.
--   - Routing it through AceEvent-3.0 (piggybacking on TellMeWhen's own
--     already-loaded copy of that library, so the actual native
--     RegisterEvent() call executes from TellMeWhen's file, not Huntard's)
--     STILL triggered it -- ruled out live.
--   - Grepped Details' own source for how it handles this exact client
--     (named internally as "ForeverWow"/"ApocalypseWow", build range
--     16001-19999, via DetailsFramework.IsForeverWow() in its bundled
--     Libs/DF/fw.lua): Details ITSELF skips COMBAT_LOG_EVENT_UNFILTERED
--     registration entirely on this client (functions/plater.lua,
--     startup.lua) and instead falls back to Blizzard's own newer built-in
--     DamageMeter API (Enum.DamageMeterType, see core/parser_nocleu.lua)
--     for aggregate combat stats. Even THAT official replacement explicitly
--     marks debuff-uptime tracking as "not supported" in its own mapping
--     table. Conclusion: there is no mechanism, native or addon-side, for
--     any addon to get real-time per-target debuff application data on
--     this client. This is a hard platform ceiling, not a Huntard bug.
--
-- FALLBACK DESIGN: tracks your own successful Serpent Sting cast via
-- UNIT_SPELLCAST_SUCCEEDED (same always-visible, never-secret event type
-- AspectAlert.lua uses for aspects) against your current target at the
-- moment of casting, keyed by that target's GUID, then just counts down a
-- fixed SERPENT_STING_DURATION from there. This does NOT know about the
-- debuff being dispelled, resisted, or overwritten early by another
-- hunter -- there's no way to know that on this client -- so a countdown
-- can occasionally run past when the real debuff actually fell off. For
-- the stated use case (tracking your own application while multi-dotting
-- and switching targets) that's a rare edge case, not the common path.
--
-- Tracked per TARGET GUID rather than "your last cast" specifically
-- because you multi-dot: Serpent Sting can be ticking on several targets
-- at once, and this needs to report correctly on whichever one you're
-- CURRENTLY looking at, not just the most recent one you cast it on.

local H = Huntard
H.SerpentSting = H.SerpentSting or {}

local SERPENT_STING_NAME = "Serpent Sting"
local SERPENT_STING_DURATION = 15 -- seconds -- confirmed real value, not guessed
-- UNIT_SPELLCAST_SUCCEEDED fires when the CAST completes, not when the shot
-- actually lands -- Serpent Sting is a ranged shot with real flight time to
-- the target, so the debuff doesn't actually apply until slightly after
-- this event fires. Confirmed live: without this buffer, the tracked
-- countdown reached zero (and the real debuff actually fell off) about
-- 0.5-1s AFTER our calculated expiry -- i.e. our timer was running early.
-- Padding the effective duration compensates. This is an approximation --
-- real flight time scales with distance to target -- not an exact fix, but
-- splits the reported 0.5-1s gap.
local TRAVEL_TIME_BUFFER = 0.75
-- Seconds before it falls off that the countdown shows: the /huntard slider
-- (1-10, default 3).
local function alertWindow()
	local w = H.db and H.db.serpentSting and H.db.serpentSting.window
	return type(w) == "number" and w or 3
end
H.SerpentSting.GetWindow = alertWindow
function H.SerpentSting.SetWindow(seconds)
	H.db.serpentSting.window = math.max(1, math.min(10, math.floor(seconds + 0.5)))
	return H.db.serpentSting.window
end

-- [targetGUID] = GetTime() when you last successfully cast Serpent Sting
-- while that GUID was your target.
local appliedAt = {}
local serpentStingIcon
local serpentStingSpellId

-- Confirmed live in a party dungeon: UnitGUID("target") can be a secret
-- value, and a secret can't be used as a table key. It can also change between
-- readable and secret on the SAME mob (e.g. cast before the pull, read during
-- combat), so a cast is always recorded in currentTargetAppliedAt as well as
-- by GUID when readable. currentTargetAppliedAt resets on every target change,
-- so a timer can't show on the wrong mob. Multi-dot tracking across target
-- swaps only works while GUIDs are readable.
local currentTargetAppliedAt
local function readableTargetGUID()
	local guid = UnitGUID("target")
	if _G.issecretvalue and _G.issecretvalue(guid) then return nil end
	return guid
end

-- [nameplate frame] = GetTime() of your last cast on that mob. Keeps multi-dot
-- working while GUIDs are secret: each visible mob has its own nameplate
-- frame. Plates are recycled between mobs, so an entry is dropped the moment
-- its plate is removed (see NAME_PLATE_UNIT_REMOVED in Init).
local appliedByPlate = {}

local function plateForUnit(unit)
	if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
	local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
	if not ok or (_G.issecretvalue and _G.issecretvalue(plate)) then return nil end
	return plate
end

-- The newest known cast on the current target, from any record.
local function appliedTimeForTarget()
	local guid = readableTargetGUID()
	local plate = plateForUnit("target")
	local newest = currentTargetAppliedAt
	for _, t in ipairs({ guid and appliedAt[guid] or 0, plate and appliedByPlate[plate] or 0 }) do
		if t > 0 and (not newest or t > newest) then newest = t end
	end
	return newest
end

-- GetSpellInfo -- NOT an aura read, confirmed unaffected by the secrecy
-- restriction (Arcane Shot's own declared range read correctly in the
-- same in-combat debug run that proved aura reads were blocked) -- used
-- once to fetch Serpent Sting's icon for display and to resolve its
-- spellId (UNIT_SPELLCAST_SUCCEEDED gives a spellId, not a name).
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

-- Returns (active, icon, secondsRemaining). active is only true once
-- Serpent Sting (as tracked on the CURRENT target specifically) has
-- alertWindow() seconds or less left.
function H.SerpentSting.GetStatus()
	if not H.Range.HasFightableTarget() then return false end
	local appliedTime = appliedTimeForTarget()
	if not appliedTime then return false end

	local remaining = (appliedTime + SERPENT_STING_DURATION + TRAVEL_TIME_BUFFER) - GetTime()
	if remaining <= 0 then
		-- our own tracking says it's over -- safety net, don't keep reporting a stale application
		local targetGUID = readableTargetGUID()
		if targetGUID then appliedAt[targetGUID] = nil end
		local targetPlate = plateForUnit("target")
		if targetPlate then appliedByPlate[targetPlate] = nil end
		currentTargetAppliedAt = nil
		return false
	end
	if remaining <= alertWindow() then
		return true, serpentStingIcon, remaining
	end
	return false
end

-- /huntard ssdebug -- dumps exactly what's tracked right now, to tell
-- apart "never recorded a cast" from "recorded, but outside the 3s alert
-- window" from "something else is wrong".
function H.SerpentSting.Debug()
	local lines = {}
	local function add(s) table.insert(lines, s) end

	add("serpentStingSpellId (resolved at Init): " .. tostring(serpentStingSpellId))
	add("serpentStingIcon (resolved at Init): " .. tostring(serpentStingIcon))
	add("")
	add("current target exists: " .. tostring(UnitExists("target")))
	local targetGUID = UnitExists("target") and readableTargetGUID()
	add("current target GUID: " .. (targetGUID and tostring(targetGUID) or "none or secret"))
	add("current target timer started at: " .. tostring(currentTargetAppliedAt))
	local debugPlate = UnitExists("target") and plateForUnit("target")
	add("current target has nameplate: " .. tostring(debugPlate and true or false)
		.. "  timer on that plate: " .. tostring(debugPlate and appliedByPlate[debugPlate]))
	local plateCount = 0
	for _ in pairs(appliedByPlate) do plateCount = plateCount + 1 end
	add("mobs tracked by nameplate: " .. plateCount)
	add("H.Range.HasFightableTarget(): " .. tostring(H.Range.HasFightableTarget()))
	add("")

	local count = 0
	for guid, appliedTime in pairs(appliedAt) do
		count = count + 1
		local remaining = (appliedTime + SERPENT_STING_DURATION + TRAVEL_TIME_BUFFER) - GetTime()
		add(string.format("tracked GUID=%s appliedAt=%.1f remaining=%.1fs%s",
			guid, appliedTime, remaining, guid == targetGUID and "  <-- CURRENT TARGET" or ""))
	end
	add(count .. " target(s) currently tracked")
	add("")

	local active, icon, remaining = H.SerpentSting.GetStatus()
	add(string.format("H.SerpentSting.GetStatus(): active=%s icon=%s remaining=%s",
		tostring(active), tostring(icon), tostring(remaining)))

	H.ShowCopyableText("Huntard Serpent Sting debug", table.concat(lines, "\n"))
end

function H.SerpentSting.Init()
	local _, _, icon, spellId = getSpellInfoCompat(SERPENT_STING_NAME)
	serpentStingIcon = icon
	serpentStingSpellId = spellId

	local watch = CreateFrame("Frame")
	watch:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
	watch:RegisterEvent("PLAYER_TARGET_CHANGED")
	watch:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
	watch:SetScript("OnEvent", function(_, event, unit, _, spellId)
		if event == "PLAYER_TARGET_CHANGED" then
			currentTargetAppliedAt = nil
			return
		end
		if event == "NAME_PLATE_UNIT_REMOVED" then
			-- If the plate can't be identified, drop them all: a missed warning
			-- is better than a recycled plate showing another mob's timer.
			local plate = not (_G.issecretvalue and _G.issecretvalue(unit)) and plateForUnit(unit)
			if plate then
				appliedByPlate[plate] = nil
			else
				wipe(appliedByPlate)
			end
			return
		end
		-- UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellId) -- unit is
		-- always "player" here since RegisterUnitEvent filtered to it.
		local name = getSpellInfoCompat(spellId)
		if (spellId == serpentStingSpellId or name == SERPENT_STING_NAME) and UnitExists("target") then
			local now = GetTime()
			currentTargetAppliedAt = now
			local guid = readableTargetGUID()
			if guid then appliedAt[guid] = now end
			local plate = plateForUnit("target")
			if plate then appliedByPlate[plate] = now end
		end
	end)

	-- Safety-net cleanup: a target that somehow never gets revisited would
	-- otherwise sit in the table forever. Nothing with a real application
	-- should still be tracked this long after SERPENT_STING_DURATION, so
	-- anything older than that plus a margin is definitely stale.
	local cleanupTicker = CreateFrame("Frame")
	cleanupTicker:SetScript("OnUpdate", function(self, elapsed)
		self.t = (self.t or 0) + elapsed
		if self.t > 30 then
			self.t = 0
			local now = GetTime()
			for guid, appliedTime in pairs(appliedAt) do
				if now - appliedTime > SERPENT_STING_DURATION + 10 then
					appliedAt[guid] = nil
				end
			end
			for plate, appliedTime in pairs(appliedByPlate) do
				if now - appliedTime > SERPENT_STING_DURATION + 10 then
					appliedByPlate[plate] = nil
				end
			end
		end
	end)
end
