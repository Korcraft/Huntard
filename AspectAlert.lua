-- Huntard: AspectAlert.lua
-- Warns when you're not in a combat-appropriate aspect. Three detection
-- methods are tried in order, each covering a gap real live testing found
-- in the one before it:
--
--  1. UNIT_AURA instance tracking (queryAspectDirect/trackedInstance) --
--     can confirm which aspect is up AND catch a cancel the instant it
--     happens, including mid-fight, the one thing nothing else here can do.
--  2. Buff-icon-pool scan (scanLiveAspect) -- reads the default BuffFrame's
--     own icon textures, a plain Frame property rather than a call into any
--     aura API.
--  3. Cast-tracking (currentAspect, driven by UNIT_SPELLCAST_SUCCEEDED) --
--     casting a spell has never been secret on this client, so this is the
--     one method confirmed to hold up for an entire sustained fight.
--
-- Why all three, not just #1: real testing (a full live fight, not a
-- one-off sample) found #1 and #2 can BOTH come back cleanly "nothing
-- found" -- not a detected secrecy restriction either time, just silently
-- wrong -- for the ENTIRE DURATION of real sustained combat, not just a
-- momentary gap. "Not restricted" does not reliably mean "correct" on this
-- client once you're actually fighting something. #3 is the fallback for
-- exactly that case, with one known, unavoidable gap: casting a spell is
-- never secret, but cancelling a buff isn't a cast, so #3 alone can't see a
-- manual cancel. #1's instance-removal detection (plain numeric IDs, not
-- complex aura records) is the only thing that can, and keeps trying
-- throughout -- so a cancel still gets caught whenever that specific read
-- happens to go through, it just isn't guaranteed to during a whole fight
-- the way it reliably is outside of combat.
--
-- Gated the same way as the range zone (see Range.lua's own
-- HasFightableTarget): only checked while you have a real, attackable,
-- living target -- not just "in combat", with an optional setting
-- (/huntard combatonly) to additionally require real combat.
--
-- Real aspects confirmed present on this client via grep against
-- installed addons' own bundled spell/quest data (same Townsfolk-style
-- research as Wayfinder's location extraction, not guessed): Hawk,
-- Cheetah, Pack, Wild, Fox, Beast, Eagle. Aspect of the Monkey wasn't
-- caught by that same search, but you named it directly as real content
-- on this client, so it's included on your word rather than mine.

local H = Huntard
H.AspectAlert = H.AspectAlert or {}

-- Aspects that do NOT clear the warning -- either because they're travel
-- aspects (not combat-appropriate) or because we simply have no confirmed
-- combat aspect yet. Anything in ALL_ASPECTS but not here is treated as a
-- real combat choice and clears the warning once active.
local TRAVEL_ASPECTS = {
	["Aspect of the Cheetah"] = true,
	["Aspect of the Pack"] = true,
}

local ALL_ASPECTS = {
	"Aspect of the Hawk",
	"Aspect of the Cheetah",
	"Aspect of the Pack",
	"Aspect of the Wild",
	"Aspect of the Fox",
	"Aspect of the Beast",
	"Aspect of the Eagle",
	"Aspect of the Monkey",
}
local ASPECT_SET = {}
for _, name in ipairs(ALL_ASPECTS) do ASPECT_SET[name] = true end

-- GetSpellInfo(name/id) -- NOT an aura read, confirmed unaffected by the
-- secrecy restriction -- used to resolve a cast event's spellId back to a
-- spell name, and to fetch each aspect's own icon.
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

local function iconFor(name)
	local _, _, icon = getSpellInfoCompat(name)
	return icon
end

-- Modernized compat: C_SpellBook.IsSpellKnown, falling back to
-- IsPlayerSpell -- same confirmed-real pattern already used in
-- ViperAlert.lua (via Questie's own QuestieCompat.IsSpellKnown).
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

-- Cached once true, since you can't un-learn an aspect -- while still
-- false (pre-first-aspect leveling), re-checks each call so the moment you
-- DO learn one, the alert turns on without needing a reload.
local knownAnyAspectCache = false
local function knowsAnyAspect()
	if knownAnyAspectCache then return true end
	for _, name in ipairs(ALL_ASPECTS) do
		local _, _, _, spellId = getSpellInfoCompat(name)
		if isSpellKnownCompat(spellId) then
			knownAnyAspectCache = true
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- BUFF-ICON-POOL SCAN -- reads Blizzard's own default buff icon pool
-- directly. See file header for how this was found and confirmed. GetStatus()
-- consults this whenever UNIT_AURA instance tracking (below) comes up empty,
-- since that path has a confirmed silent-false-negative gap mid-combat.
-- ---------------------------------------------------------------------------

-- Returns the first Texture-type region's fileID on `frame`, or nil.
local function firstTextureOf(frame)
	local ok, regions = pcall(function() return { frame:GetRegions() } end)
	if not ok then return nil end
	for _, region in ipairs(regions) do
		local okType, rType = pcall(function() return region:GetObjectType() end)
		if okType and rType == "Texture" then
			local okTex, tex = pcall(function() return region:GetTexture() end)
			if okTex and tex then return tex end
		end
	end
	return nil
end

-- Finds the real pooled buff-icon container: whichever of BuffFrame's
-- children has the most children of its own (confirmed live: a 32-slot
-- pool, with exactly as many `shown=true` slots as you have real buffs,
-- each slot's first texture region being that buff's own icon -- found by
-- recursively dumping the whole tree once and reading it by hand, not
-- guessed). Cached once found -- this structure doesn't change mid-session.
-- NOT cached, deliberately -- confirmed live that caching this at Init()
-- time (login/reload) could grab the wrong frame if BuffFrame's children
-- haven't fully settled yet at that exact moment, same category of timing
-- bug already hit once before with the pet action bar not being populated
-- immediately after reload. Re-resolving fresh each call is cheap (a
-- shallow walk over BuffFrame's own children, not the full 32-slot pool)
-- and removes the staleness risk entirely.
local function getBuffPool()
	if not _G.BuffFrame then return nil end
	local ok, kids = pcall(function() return { BuffFrame:GetChildren() } end)
	if not ok then return nil end
	local best, bestCount = nil, 0
	for _, child in ipairs(kids) do
		local okKids, grandkids = pcall(function() return { child:GetChildren() } end)
		if okKids and #grandkids > bestCount then
			best, bestCount = child, #grandkids
		end
	end
	return best
end

-- [iconFileID] = aspectName -- only ever contains aspects this client has
-- resolved an icon for, which in practice means aspects you've learned.
-- Refreshed periodically (see Init) so a newly-learned aspect gets picked
-- up without needing a reload.
local KNOWN_ASPECT_ICONS = {}
local function refreshKnownIcons()
	for _, name in ipairs(ALL_ASPECTS) do
		local icon = iconFor(name)
		if icon then
			KNOWN_ASPECT_ICONS[icon] = name
		end
	end
end

-- Returns (aspectNameOrNil, poolFound). poolFound=false means the buff icon
-- pool itself couldn't be located (structural failure -- e.g. this
-- client's default UI changes shape) -- distinct from poolFound=true with
-- a nil result, which means the scan ran fine and genuinely found no
-- matching aspect icon among your current buffs.
local function scanLiveAspect()
	local pool = getBuffPool()
	if not pool then return nil, false end
	local ok, kids = pcall(function() return { pool:GetChildren() } end)
	if not ok then return nil, false end
	for _, child in ipairs(kids) do
		local okShown, shown = pcall(function() return child:IsShown() end)
		if okShown and shown then
			local tex = firstTextureOf(child)
			if tex and not (_G.issecretvalue and _G.issecretvalue(tex)) then
				local aspectName = KNOWN_ASPECT_ICONS[tex]
				if aspectName then return aspectName, true end
			end
		end
	end
	return nil, true
end

-- ---------------------------------------------------------------------------
-- UNIT_AURA INSTANCE TRACKING (primary source -- GetStatus() falls back to
-- the buff-icon-pool scan above only when this comes up empty, see there).
--
-- Adapted from a real, working Paladin addon (PallySealCooldowns, found in
-- your Downloads) whose SealLogic.lua does exactly this for Paladin seals.
-- The key technique a first attempt at this missed (it crashed and was
-- removed -- see AlertCluster/AspectAlert history if ever needed): GUARD
-- the updateInfo table itself with issecretvalue() BEFORE ever touching it
-- with ipairs, rather than iterating first and finding out the hard way.
-- Done correctly, the event payload is NOT uniformly unusable in combat --
-- readability flickers call to call (confirmed independently by our own
-- speed/texture probes earlier returning different readable/secret results
-- across different moments), and the goal is to use it whenever it's
-- readable, not require it to always be.
--
-- Tracks a specific aura INSTANCE (auraInstanceID), not just a name:
--   - A direct per-name query (GetAuraDataBySpellName) establishes/confirms
--     the instance whenever that read happens to be unrestricted.
--   - UNIT_AURA's addedAuras list (properly guarded) can also reveal a
--     newly-applied aspect's instance straight from the event, with no
--     query needed at all.
--   - UNIT_AURA's removedAuraInstanceIDs list (properly guarded) is
--     checked against whatever instance is currently tracked -- if that
--     specific ID shows up there, that's a DEFINITIVE removal, caught the
--     moment it happens, including mid-combat -- the one thing nothing
--     else in this file could ever do.
-- ---------------------------------------------------------------------------

local function isReadable(value)
	return not (_G.issecretvalue and _G.issecretvalue(value))
end

local function isFiniteNumber(value)
	return isReadable(value) and type(value) == "number"
		and value == value and value > -math.huge and value < math.huge
end

-- Direct per-name query. Returns (result, restricted):
--   result = {name=, auraInstanceID=, icon=} if a non-secret match was found
--   restricted = true if ANY of the per-name queries came back secret/errored
-- (mirrors PallySealCooldowns' own FindSeal -- first non-secret match wins,
-- same as the old syncFromLiveBuff, but this version also captures the
-- auraInstanceID, which that one never needed).
local function queryAspectDirect()
	local restricted = false
	for _, name in ipairs(ALL_ASPECTS) do
		local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", name, "HELPFUL")
		if not ok or not isReadable(aura) then
			restricted = true
		elseif aura then
			return { name = name, auraInstanceID = aura.auraInstanceID, icon = aura.icon }, false
		end
	end
	return nil, restricted
end

-- The tracked instance -- {name=, auraInstanceID=} or nil.
local trackedInstance = nil

local function handleUnitAuraUpdate(update)
	if not isReadable(update) or type(update) ~= "table" then return end

	-- Removal: does this update's removed-instance list contain the ID
	-- we're currently tracking?
	if trackedInstance and isFiniteNumber(trackedInstance.auraInstanceID) then
		local removed = update.removedAuraInstanceIDs
		if isReadable(removed) and type(removed) == "table" then
			for _, id in ipairs(removed) do
				if isFiniteNumber(id) and id == trackedInstance.auraInstanceID then
					trackedInstance = nil
					break
				end
			end
		end
	end

	-- Addition: does this update's added-aura list contain a known aspect?
	local added = update.addedAuras
	if isReadable(added) and type(added) == "table" then
		for _, aura in ipairs(added) do
			if isReadable(aura) and type(aura) == "table"
				and isReadable(aura.name) and type(aura.name) == "string"
				and ASPECT_SET[aura.name]
				and isReadable(aura.isHelpful) and aura.isHelpful ~= false then
				trackedInstance = { name = aura.name, auraInstanceID = aura.auraInstanceID }
			end
		end
	end
end

-- Reconciles tracked state against a fresh direct query whenever that read
-- happens to be unrestricted -- corrects drift, and is how the initial
-- state gets established (e.g. right after login).
--
-- Confirmed live (via /huntard auradebug during a real sustained fight):
-- queryAspectDirect() can come back result=nil restricted=false -- a CLEAN,
-- CONFIDENT negative, not a detected restriction -- while an aspect is
-- genuinely active. "restricted=false" does NOT reliably mean "correct" on
-- this client during real combat, unlike every assumption this file was
-- built on earlier. So a clean negative only clears trackedInstance while
-- OUT of combat (extensively confirmed reliable there all session); during
-- combat it's trusted to CONFIRM a match but never trusted to clear one --
-- leaves trackedInstance as the event-driven removal-by-ID path (plain
-- numeric IDs, not complex aura records) set it, which hasn't shown this
-- same false-negative problem.
local function reconcileAspect()
	local queried, restricted = queryAspectDirect()
	if queried then
		trackedInstance = queried
	elseif not restricted and not UnitAffectingCombat("player") then
		trackedInstance = nil
	end
end

-- ---------------------------------------------------------------------------
-- CAST-TRACKING FALLBACK -- GetStatus()'s last resort when both the
-- UNIT_AURA instance tracker and the buff-icon-pool scan have nothing,
-- which real testing showed can happen for an entire sustained fight, not
-- just a momentary gap. Cannot detect a manual cancel on its own -- see the
-- "Known gap" note in GetStatus() above.
-- ---------------------------------------------------------------------------

local currentAspect = nil

local function syncFromLiveBuff()
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then return end
	if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then return end
	for _, name in ipairs(ALL_ASPECTS) do
		local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", name, "HELPFUL")
		if ok and aura then
			currentAspect = name
			return
		end
	end
	currentAspect = nil
end

-- ---------------------------------------------------------------------------
-- Public status
-- ---------------------------------------------------------------------------

-- Driven by trackedInstance (UNIT_AURA instance tracking, see above) --
-- one source of truth across both in and out of combat, no combat-state
-- switching needed, since the instance-removal detection works in either.

-- Returns (status, icon, aspectName):
--   status == "none"  -> no aspect confirmed active at all (AlertIcon.lua
--                         shows the dedicated "NO ASPECT" icon)
--   status == "travel" -> a travel aspect (Cheetah/Pack) is live -- icon is
--                         that aspect's own
--   status == "wrong"  -> a preferred aspect is configured, and a DIFFERENT
--                         real combat aspect is live (AlertIcon.lua shows
--                         the generic "ASPECT" icon for this case)
--   status == nil      -> no alert warranted (gated off, or the right
--                         aspect is confirmed live)
function H.AspectAlert.GetStatus()
	if not H.Range.HasFightableTarget() then return nil end
	if H.db.aspectAlertRequireCombat and not UnitAffectingCombat("player") then return nil end
	if not knowsAnyAspect() then return nil end -- too low level for any aspect yet -- nothing to warn about

	local liveAspect = trackedInstance and trackedInstance.name
	if not liveAspect then
		-- Confirmed live (via /huntard auradebug mid-combat): the direct
		-- per-name query can come back cleanly "not found" (restricted=false)
		-- for an aspect that IS actually active -- a silent wrong-answer, not
		-- a detected secrecy restriction, so queryAspectDirect/reconcileAspect
		-- can't catch it and trackedInstance is left incorrectly nil. The
		-- buff-icon-pool scan (see LIVE DETECTION above) reads a plain
		-- Frame/Texture property instead of calling an aura API at all, so it
		-- isn't subject to that same failure mode -- fall back to it here
		-- rather than trusting trackedInstance's "nothing" as the final word.
		local scanned, poolFound = scanLiveAspect()
		if poolFound and scanned then liveAspect = scanned end
	end
	if not liveAspect then
		-- Confirmed live (same /huntard auradebug session): during a real
		-- sustained fight, queryAspectDirect/scanLiveAspect can BOTH come
		-- back empty the entire fight, not just a momentary gap -- not a
		-- detected restriction either time, just silently wrong. currentAspect
		-- (the legacy cast-tracking fallback, see below) is driven purely by
		-- UNIT_SPELLCAST_SUCCEEDED, which has never been secret on this
		-- client -- so it's the one thing left that's actually reliable
		-- through a whole fight. Known gap: it can't see a manual cancel
		-- (right-clicking the buff off isn't a cast) -- that's a real platform
		-- limit, not something readable any other way right now, same as
		-- this file's original design before the UNIT_AURA rewrite.
		liveAspect = currentAspect
	end

	local preferred = H.db.aspectAlert.preferredAspect
	if preferred then
		if liveAspect == preferred then return nil end
		if not liveAspect then return "none" end
		if TRAVEL_ASPECTS[liveAspect] then return "travel", iconFor(liveAspect), liveAspect end
		return "wrong"
	end

	if not liveAspect then return "none" end
	if TRAVEL_ASPECTS[liveAspect] then return "travel", iconFor(liveAspect), liveAspect end
	return nil
end

function H.AspectAlert.Init()
	syncFromLiveBuff() -- legacy, kept warm but no longer consulted by GetStatus()
	refreshKnownIcons()
	reconcileAspect()

	local watch = CreateFrame("Frame")
	watch:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
	watch:RegisterUnitEvent("UNIT_AURA", "player")
	watch:RegisterEvent("PLAYER_ENTERING_WORLD")
	watch:RegisterEvent("PLAYER_REGEN_ENABLED")
	watch:SetScript("OnEvent", function(_, event, arg1, arg2, spellId)
		if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_REGEN_ENABLED" then
			syncFromLiveBuff()
			reconcileAspect()
			return
		end
		if event == "UNIT_AURA" then
			-- UNIT_AURA(unit, updateInfo) -- unit (arg1) always "player" here
			handleUnitAuraUpdate(arg2)
			return
		end
		-- UNIT_SPELLCAST_SUCCEEDED -- a confirmed cast is the single most
		-- trustworthy signal on this client (never secret, in or out of
		-- combat), so it overwrites trackedInstance directly, not just the
		-- separate currentAspect fallback -- confirmed live that otherwise, a
		-- stale trackedInstance (its OWN removal silently failed to register,
		-- same failure mode as everything else aura-related in real combat)
		-- outranks a fresh, definitely-correct cast in GetStatus()'s priority
		-- order, since GetStatus() checks trackedInstance first and only
		-- falls back to currentAspect when trackedInstance is nil -- which it
		-- wasn't, it was just wrong. No auraInstanceID from a cast event, so
		-- the ID-based removal check in handleUnitAuraUpdate simply won't
		-- fire for this instance until a later read re-establishes one --
		-- same known gap as everywhere else (a cast is reliable, a manual
		-- cancel isn't detectable this way).
		local name = getSpellInfoCompat(spellId)
		if name and ASPECT_SET[name] then
			currentAspect = name
			trackedInstance = { name = name, auraInstanceID = nil }
			-- Best-effort only: try a couple of extra times in the few
			-- seconds right after the cast to grab a real auraInstanceID
			-- (readability flickers, so more attempts right when its
			-- freshest = a better chance of catching a readable moment) so a
			-- LATER manual cancel has something to match against via the
			-- removal-by-ID path. Doesnt change what is shown right now --
			-- trackedInstance.name is already correct from the cast; this
			-- only fills in the ID reconcileAspect() would otherwise only
			-- get around to on its regular 1s tick.
			C_Timer.After(0.3, reconcileAspect)
			C_Timer.After(1.0, reconcileAspect)
		end
	end)

	-- Periodically refresh known-aspect icons, since you might learn a new
	-- one (Pack/Wild/Fox/Beast/Eagle) partway through a session -- its icon
	-- won't resolve by name until the client has seen you know it.
	local refreshTicker = CreateFrame("Frame")
	refreshTicker:SetScript("OnUpdate", function(self, elapsed)
		self.t = (self.t or 0) + elapsed
		if self.t > 30 then
			self.t = 0
			refreshKnownIcons()
		end
	end)

	-- Periodic reconcile against a fresh direct query, regardless of combat
	-- state -- readability flickers (confirmed independently elsewhere in
	-- this addon), so just keep trying; reconcileAspect() already no-ops
	-- safely whenever the read comes back restricted.
	local reconcileTicker = CreateFrame("Frame")
	reconcileTicker:SetScript("OnUpdate", function(self, elapsed)
		self.t = (self.t or 0) + elapsed
		if self.t > 1 then
			self.t = 0
			reconcileAspect()
		end
	end)

	-- Legacy: keeps currentAspect continuously mirroring the live buff-icon
	-- scan whenever out of combat. No longer feeds GetStatus() but left
	-- running -- cheap, and keeps the old fallback warm in case it's ever
	-- needed again.
	local syncTicker = CreateFrame("Frame")
	syncTicker:SetScript("OnUpdate", function(self, elapsed)
		self.t = (self.t or 0) + elapsed
		if self.t > 0.5 then
			self.t = 0
			if not UnitAffectingCombat("player") then
				local scanned, poolFound = scanLiveAspect()
				if poolFound then
					currentAspect = scanned
				end
			end
		end
	end)
end

-- /huntard debug calls into this for the aspect section.
function H.AspectAlert.GetTrackedAspect()
	return trackedInstance and trackedInstance.name
end

-- Maps a short typed name ("hawk", "wild", ...) to its full spell name, so
-- /huntard preferaspect doesn't require typing "Aspect of the Hawk" in full.
local SHORT_NAME_TO_ASPECT = {}
for _, name in ipairs(ALL_ASPECTS) do
	local short = name:match("Aspect of the (%a+)")
	if short then SHORT_NAME_TO_ASPECT[short:lower()] = name end
end

-- /huntard preferaspect <name> -- e.g. "hawk", "wild", "monkey" -- restricts
-- the warning to ONLY clear once that exact aspect is confirmed live, not
-- just any real combat aspect. Pass "any"/"clear"/"none" to go back to
-- accepting any of them (the default). Returns the resolved full spell
-- name, or nil if cleared/not recognized.
function H.AspectAlert.SetPreferredAspect(input)
	input = input and input:lower()
	if not input or input == "any" or input == "clear" or input == "none" then
		H.db.aspectAlert.preferredAspect = nil
		return nil
	end
	local full = SHORT_NAME_TO_ASPECT[input]
	if full then
		H.db.aspectAlert.preferredAspect = full
	end
	return full
end

function H.AspectAlert.GetPreferredAspect()
	return H.db.aspectAlert.preferredAspect
end

-- /huntard auradebug -- shows what the new UNIT_AURA instance tracking
-- currently has, plus whether a fresh direct query is restricted right
-- now, so we can see whether this actually holds up in combat.
function H.AspectAlert.DebugAuraTracking()
	local lines = {}
	local function add(s) table.insert(lines, s) end

	add("player in combat (UnitAffectingCombat): " .. tostring(UnitAffectingCombat("player")))
	add("")
	add("trackedInstance: " .. (trackedInstance
		and string.format("name=%s auraInstanceID=%s", trackedInstance.name, tostring(trackedInstance.auraInstanceID))
		or "nil"))

	add("")
	local queried, restricted = queryAspectDirect()
	add("queryAspectDirect() right now: result="
		.. (queried and (queried.name .. " (instanceID=" .. tostring(queried.auraInstanceID) .. ")") or "nil")
		.. " restricted=" .. tostring(restricted))

	-- GetStatus() falls back to this whenever trackedInstance is nil -- show
	-- it here too, since a prior debug dump only showing the two lines above
	-- gave no way to tell whether that fallback was actually catching the
	-- gap or not.
	add("")
	local scanned, poolFound = scanLiveAspect()
	add("scanLiveAspect() right now: result=" .. tostring(scanned) .. " poolFound=" .. tostring(poolFound))

	-- Third-tier fallback (cast-tracking) -- GetStatus() falls back to this
	-- whenever BOTH of the above have nothing, which real sustained-combat
	-- testing showed can last an entire fight, not just a momentary gap.
	add("")
	add("currentAspect (last confirmed cast): " .. tostring(currentAspect))

	add("")
	add("GetStatus() would currently return: " .. tostring(H.AspectAlert.GetStatus()))

	H.ShowCopyableText("Huntard aura tracking debug", table.concat(lines, "\n"))
end

-- /huntard bufframedebug -- confirms the buff icon pool is found, lists
-- each currently-shown slot's icon texture, and cross-references them
-- against every known aspect's own icon.
function H.AspectAlert.DebugBuffFrame()
	local lines = {}
	local function add(s) table.insert(lines, s) end

	add("player in combat (UnitAffectingCombat): " .. tostring(UnitAffectingCombat("player")))
	add("")

	-- tostring() on a secret value returns ANOTHER secret (tainted) value,
	-- not a normal string -- confirmed live via a real crash here in combat
	-- (table.concat choked on a "secret string"). Every field has to be
	-- gated BEFORE it ever touches tostring/concat, same lesson as the
	-- earlier speed probe.
	local function safeStr(v)
		if _G.issecretvalue and _G.issecretvalue(v) then return "<secret>" end
		return tostring(v)
	end

	local pool = getBuffPool()
	add("buff icon pool found: " .. tostring(pool ~= nil))
	if pool then
		local okKids, kids = pcall(function() return { pool:GetChildren() } end)
		if okKids then
			for i, child in ipairs(kids) do
				local okShown, shown = pcall(function() return child:IsShown() end)
				if okShown and shown then
					local tex = firstTextureOf(child)
					local isSecret = _G.issecretvalue and _G.issecretvalue(tex)
					add(string.format("slot %d: icon texture=%s secret=%s", i, safeStr(tex), tostring(isSecret)))
				end
			end
		end
	end

	add("")
	add("-- known aspect icons, for cross-reference --")
	for _, name in ipairs(ALL_ASPECTS) do
		add(name .. ": icon=" .. tostring(iconFor(name)))
	end

	local live, found = scanLiveAspect()
	add("")
	add("scanLiveAspect(): aspect=" .. tostring(live) .. " poolFound=" .. tostring(found))

	H.ShowCopyableText("Huntard buff frame debug", table.concat(lines, "\n"))
end
