-- Huntard: FreezeTimer.lua
-- The end of your Freezing Trap's freeze (last 1-10 seconds, the /huntard slider, default 3): the trap icon with a
-- countdown, in the alert cluster's row like the Serpent Sting
-- countdown. It goes the moment the freeze ends -- ran out, or broken early.
--
-- HOW: in combat this client hides every debuff on other units from addons
-- (/huntard traptest, 26 Nov 2026: "Auras cannot be accessed when secret while
-- tainted by 'Huntard'"), and the trap's cooldown is secret too. So Huntard
-- never reads the freeze. It hands Blizzard's aura container
-- (Blizzard_AuraContainer) frames for each unit that could be frozen, with a
-- filter that lets through only YOUR Freezing Trap Effect. The game shows them
-- while the freeze is really there and writes the real time left into them
-- (SetDurationText) through two of the game's number formatters that print
-- nothing above the window: one prints the trap icon (an inline |T texture),
-- the other the number. So nothing shows until the window, and Huntard
-- never compares the hidden time. Idea from MageProcs' Polymorph timer; this
-- is Huntard's own code.
--
-- PLACE: Huntard asks whether the game is showing a freeze frame and counts
-- down the trap rank's duration from then, so the cluster gives it a real slot
-- (see GetStatus). If it can't tell, it sits in the next free spot (PlaceAt):
-- centred when no other alert shows, else just right of the row.
--
-- WHICH UNITS: target, focus, every enemy nameplate, pet's target, target's
-- target, party members' targets, arena enemies. Nameplates are what catch a
-- mob you never targeted; the player doesn't want to see them, so "hidden
-- nameplates" (on by default) switches enemy plates on fully transparent and
-- click-through, saving and restoring the player's own settings. The
-- "someone's target" units get no aura updates of their own, so while a trap
-- may be out those containers are asked to look again a few times a second.
-- The frozen one has to be one of these units for anything to show.
--
-- LIMITS: the game's frames take no changes in combat, so everything is built
-- out of combat; a change of size waits for the fight to end. They hang off
-- Huntard's own holder frame, which can move at any time.

local H = Huntard
H.FreezeTimer = H.FreezeTimer or {}
local F = H.FreezeTimer

-- Freezing Trap Effect, ranks 1-3 (the debuff; the trap you lay is 1499/14310/14311)
local EFFECT_IDS = { 3355, 14308, 14309 }
local TRAP_NAME = "Freezing Trap"
local ICON = "Interface\\Icons\\Spell_Frost_ChainsOfIce"
local SIZE = 48 -- the cluster's icon size
local SHOW_FROM = 3 -- seconds left when it appears
local ARMED_FOR = 85 -- seconds after laying a trap a freeze can still be up (60s trap + 20s freeze + margin)
local POLL = 0.25
local KINDS = { "icon", "num" } -- two frames per unit: the icon, and the number over it

local DIRECT = { "target", "focus", "arena1", "arena2", "arena3", "arena4", "arena5" }
for i = 1, 40 do DIRECT[#DIRECT + 1] = "nameplate" .. i end
local INDIRECT = { "pettarget", "targettarget", "party1target", "party2target", "party3target", "party4target" }

-- Hidden nameplates: enemy nameplates switched on so every nearby enemy has a
-- unit token (nameplateN) the containers can watch, but drawn fully
-- transparent and click-through, so nothing shows and nothing steals a click.
-- The player's own values are saved first and put back when it's turned off.
local PLATE_CVARS = {
	nameplateShowEnemies = "1",
	nameplateMinAlpha = "0",
	nameplateMaxAlpha = "0",
	nameplateSelectedAlpha = "0",
	nameplateNotSelectedAlpha = "0",
	nameplateOccludedAlphaMult = "0",
}
local getCVar = (C_CVar and C_CVar.GetCVar) or _G.GetCVar
local setCVar = (C_CVar and C_CVar.SetCVar) or _G.SetCVar
local pendingPlates

local containers = {} -- unit -> { c = container, unit, slots = { icon = slot, num = slot } }
local holder
local broken -- why the game's frames can't be used here, or nil
local pendingSetup, pendingApply = false, false
local armedUntil = 0
local gen = 0

local function inCombat() return InCombatLockdown() or UnitAffectingCombat("player") end
local function cfg() return H.db.freezeTimer end
local function scale() return H.db.alertCluster.scale end

-- ---------------------------------------------------------------------------
-- The game's number formatters: nothing above SHOW_FROM seconds or at 0.
-- ---------------------------------------------------------------------------

-- Seconds before the freeze ends that the countdown shows: the /huntard
-- slider (1-10, default 3).
local function window()
	local w = H.db and H.db.freezeTimer and H.db.freezeTimer.window
	return type(w) == "number" and w or SHOW_FROM
end
F.GetWindow = window

-- One formatter per kind and window, made once: "num" prints the whole
-- seconds left (rounded up), "icon" prints the trap icon at the font's own
-- height (:0, so its size follows the font); both print nothing above the window.
local formatters = {}
local function getFormatter(kind)
	local w = window()
	local key = kind .. w
	if formatters[key] ~= nil then return formatters[key] or nil end
	formatters[key] = false
	local make = C_StringUtil and C_StringUtil.CreateNumericRuleFormatter
	if not make then return nil end
	local up = Enum and Enum.NumericRuleFormatRounding and Enum.NumericRuleFormatRounding.Up
	local shown = kind == "num" and { threshold = 0.05, step = 1, rounding = up, format = "%.0f" }
		or { threshold = 0.05, format = "|T" .. ICON .. ":0|t" }
	local ok, f = pcall(make)
	if ok and f and pcall(f.SetBreakpoints, f, {
			{ threshold = 0, format = "" }, shown, { threshold = w, format = "" } }) then
		formatters[key] = f
	end
	return formatters[key] or nil
end

local function fontFile()
	return GameFontNormalHuge and GameFontNormalHuge:GetFont() or STANDARD_TEXT_FONT
end

local function styleText(fs, kind)
	fs:ClearAllPoints()
	if kind == "icon" then
		fs:SetPoint("CENTER", fs:GetParent(), "CENTER", 0, 0)
		fs:SetFont(fontFile(), SIZE * scale())
	else
		-- Same look as the Serpent Sting countdown (AlertCluster.lua)
		fs:SetPoint("BOTTOM", fs:GetParent(), "BOTTOM", 0, 2)
		fs:SetFont(fontFile(), 22 * scale(), "OUTLINE")
		fs:SetTextColor(1, 1, 1, 1)
	end
end

-- ---------------------------------------------------------------------------
-- The holder: Huntard's own frame the game's frames sit in
-- ---------------------------------------------------------------------------

local placedX, placedAnchor
-- Fallback place, called by AlertCluster when the countdown has no slot of its
-- own in the row (see GetStatus): x is the row's next free spot, as an offset
-- from the anchor's centre.
function F.PlaceAt(anchor, x)
	if not holder then return end
	if holder.slot == nil and placedAnchor == anchor and placedX == x then return end
	holder.slot = nil
	placedAnchor, placedX = anchor, x
	holder:ClearAllPoints()
	holder:SetPoint("CENTER", anchor, "CENTER", x, 0)
end

-- ---------------------------------------------------------------------------
-- Knowing when it shows, so it can take a real slot in the row
-- ---------------------------------------------------------------------------
-- Huntard can't read the freeze, but it can ask whether the game is showing
-- one of its frames (the game shows them for the whole freeze, with nothing
-- drawn until the window). From the moment one shows, the freeze lasts the
-- laid trap's duration; once that many seconds minus the window have passed,
-- the cluster gives the countdown a slot like any other alert, and the game's
-- frames are pinned into it. If the game's answer is secret, or the freeze is
-- shorter than its rank says (diminishing returns on players), the countdown
-- still shows, in the row's next free spot instead (PlaceAt).

-- Freezing Trap rank -> freeze length on NPCs (and the cap on players)
local TRAP_DURATIONS = { [1499] = 10, [14310] = 15, [14311] = 20 }
local trapDuration = 10
local frozenSince -- GetTime() a game frame was first seen showing, nil when none is
F.diag = { plain = 0, secret = 0 }

local function anyShowing()
	local known = false
	for _, e in pairs(containers) do
		local slot = e.slots.num
		local b = slot and slot.button
		if b then
			local ok, shown = pcall(b.IsShown, b)
			if ok and _G.issecretvalue and _G.issecretvalue(shown) then
				F.diag.secret = F.diag.secret + 1
			elseif ok then
				known = true
				if shown == true then
					F.diag.plain = F.diag.plain + 1
					return true
				end
			end
		end
	end
	if known then return false end
	return nil -- couldn't tell
end

-- For the alert cluster: { holder = frame } while the countdown is due to show
-- (the cluster gives it a slot and pins the frame there), else nil.
function F.GetStatus()
	if not holder or broken or not cfg().enabled or not next(containers) then return nil end
	local showing = anyShowing()
	if showing ~= true then
		frozenSince = nil
		return nil
	end
	local now = GetTime()
	frozenSince = frozenSince or now
	local left = frozenSince + trapDuration - now
	if left > 0 and left <= window() then return { holder = holder } end
	return nil
end

local function sizeHolder()
	local size = SIZE * scale()
	holder:SetSize(size, size)
	if not placedAnchor then
		holder:SetPoint("CENTER", HuntardAlertAnchor or UIParent, "CENTER", 0, 0)
	end
end

-- Tells the game which text to write into and how (out of combat). Without
-- its formatter a frame would print the whole time: better nothing.
local function bindText(slot)
	local f = getFormatter(slot.kind)
	slot.window = window()
	slot.textOk = f and pcall(slot.button.SetDurationText, slot.button, slot.text, { textFormatter = f }) or false
end

-- What Huntard draws inside one of the game's frames, once (out of combat).
local function build(slot, b)
	if slot.button == b and slot.content then return end
	slot.button = b
	pcall(b.EnableMouse, b, false)
	pcall(b.ClearAllPoints, b)
	pcall(b.SetAllPoints, b, holder)
	if slot.kind == "num" then pcall(b.SetFrameLevel, b, holder:GetFrameLevel() + 5) end
	if type(b.GetIcon) == "function" then
		local ok, icon = pcall(b.GetIcon, b)
		if ok and icon and icon.Hide then pcall(icon.Hide, icon) end
	end

	local content = CreateFrame("Frame", nil, b)
	content:SetAllPoints(b)
	slot.content = content

	local text = content:CreateFontString(nil, "OVERLAY")
	styleText(text, slot.kind)
	text:SetText("")
	slot.text = text
	bindText(slot)
end

local function applyAll()
	if inCombat() then pendingApply = true; return end
	sizeHolder()
	for _, e in pairs(containers) do
		for kind, slot in pairs(e.slots) do
			if slot.text then
				styleText(slot.text, kind)
				if slot.window ~= window() then bindText(slot) end
			end
		end
	end
end

function F.SetWindow(seconds)
	H.db.freezeTimer.window = math.max(1, math.min(10, math.floor(seconds + 0.5)))
	applyAll() -- the new window reaches the game's frames now, or when the fight ends
	return H.db.freezeTimer.window
end

-- ---------------------------------------------------------------------------
-- The containers
-- ---------------------------------------------------------------------------

local function setSlotOn(e, slot, on)
	if slot.on == on then return end
	slot.on = on
	pcall(e.c.SetAuraSlotEnabled, e.c, slot.key, on)
end

function F.Sync()
	local on = (cfg().enabled and not broken) and true or false
	for _, e in pairs(containers) do
		for _, slot in pairs(e.slots) do setSlotOn(e, slot, on) end
	end
end

local function newContainer(unit)
	local ok, c = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
	if not ok or not c or not c.AddAuraSlot then
		broken = "Blizzard's aura container isn't available on this client"
		return nil
	end
	pcall(c.SetAllPoints, c, UIParent)
	pcall(c.SetFrameStrata, c, "MEDIUM")
	pcall(c.SetUnit, c, unit)
	pcall(c.SetEnabled, c, true)
	local e = { c = c, unit = unit, slots = {} }
	containers[unit] = e
	return e
end

local function idSet()
	local set = {}
	for _, id in ipairs(EFFECT_IDS) do set[id] = true end
	return set
end

local function addSlot(e, kind)
	local slot = { key = "huntard_freeze_" .. kind .. "_" .. gen, kind = kind }
	local filter = cfg().anySource and "HARMFUL" or "HARMFUL|PLAYER"
	local ok, res = pcall(e.c.AddAuraSlot, e.c, slot.key, filter, {
		templateNames = { "HuntardFreezeTemplate" },
		initializeFrame = function(b) pcall(build, slot, b) end,
		candidateFilters = { includeSpellIDs = idSet() },
	})
	if not ok then
		broken = "the game refused the Freezing Trap filter (" .. tostring(res) .. ")"
		return
	end
	e.slots[kind] = slot
	if type(res) == "table" and not slot.content then pcall(build, slot, res) end
end

-- Builds (or rebuilds, after a filter change) every unit's frames. Out of combat only.
function F.Setup()
	if broken then return end
	if inCombat() then pendingSetup = true; return end
	pendingSetup = false
	local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
	if load then pcall(load, "Blizzard_AuraContainer") end
	gen = gen + 1
	local units = {}
	for _, u in ipairs(DIRECT) do units[#units + 1] = u end
	for _, u in ipairs(INDIRECT) do units[#units + 1] = u end
	for _, u in ipairs(units) do
		local e = containers[u] or newContainer(u)
		if not e then break end
		for kind, slot in pairs(e.slots) do
			setSlotOn(e, slot, false)
			if slot.button then pcall(slot.button.Hide, slot.button) end
			e.slots[kind] = nil
		end
		for _, kind in ipairs(KINDS) do
			addSlot(e, kind)
			if broken then break end
		end
		if broken then break end
	end
	if broken then
		for _, e in pairs(containers) do
			for _, slot in pairs(e.slots) do setSlotOn(e, slot, false) end
		end
		return
	end
	F.Sync()
	applyAll()
end

-- The unit behind a token changed (or may have): the game is asked to look again.
local function refresh(unit)
	local e = containers[unit]
	if not e then return end
	if type(e.c.UpdateAllAuras) == "function" then
		pcall(e.c.UpdateAllAuras, e.c)
	else
		pcall(e.c.SetUnit, e.c, "none")
		pcall(e.c.SetUnit, e.c, unit)
	end
end

-- ---------------------------------------------------------------------------
-- Preview (/huntard freezetest): Huntard's own frame, never the game's
-- ---------------------------------------------------------------------------

local demo
function F.Preview()
	if not holder then return end
	if not demo then
		demo = CreateFrame("Frame", nil, holder)
		demo:SetAllPoints(holder)
		demo.icon = demo:CreateTexture(nil, "ARTWORK")
		demo.icon:SetAllPoints()
		demo.icon:SetTexture(ICON)
		demo.text = demo:CreateFontString(nil, "OVERLAY")
		demo:SetScript("OnUpdate", function(self)
			local left = self.endAt - GetTime()
			if left <= 0 then self:Hide(); return end
			self.text:SetText(tostring(math.ceil(left)))
		end)
	end
	styleText(demo.text, "num")
	demo.endAt = GetTime() + window()
	demo:Show()
end

-- ---------------------------------------------------------------------------
-- Settings and status
-- ---------------------------------------------------------------------------

local function plateClickThrough()
	local get = C_NamePlate and C_NamePlate.GetNamePlateEnemyClickThrough
	if not get then return nil end
	local ok, v = pcall(get)
	return ok and v or nil
end

local function setPlateClickThrough(on)
	local set = C_NamePlate and C_NamePlate.SetNamePlateEnemyClickThrough
	if set then pcall(set, on and true or false) end
end

-- Switches hidden nameplates on (want = true) or puts the player's own
-- values back. Out of combat only: the game refuses nameplate changes in a fight.
local function applyPlates(want)
	if inCombat() then pendingPlates = want; return end
	pendingPlates = nil
	local saved = cfg().savedPlateCVars
	if want then
		if not saved then
			saved = { clickThrough = plateClickThrough() }
			for name in pairs(PLATE_CVARS) do
				local ok, v = pcall(getCVar, name)
				if ok and v ~= nil then saved[name] = v end
			end
			cfg().savedPlateCVars = saved
		end
		for name, value in pairs(PLATE_CVARS) do
			if saved[name] ~= nil then pcall(setCVar, name, value) end
		end
		setPlateClickThrough(true)
	elseif saved then
		for name in pairs(PLATE_CVARS) do
			if saved[name] ~= nil then pcall(setCVar, name, saved[name]) end
		end
		setPlateClickThrough(saved.clickThrough)
		cfg().savedPlateCVars = nil
	end
end

local function platesWanted() return cfg().enabled and cfg().hiddenPlates end

function F.SetHiddenPlates(on)
	cfg().hiddenPlates = on and true or false
	applyPlates(platesWanted())
end

function F.Refresh() if holder then applyAll() end end

function F.SetEnabled(on)
	cfg().enabled = on and true or false
	if on and not next(containers) then F.Setup() end
	F.Sync()
	applyPlates(platesWanted())
end

function F.SetAnySource(on)
	cfg().anySource = on and true or false
	F.Setup()
	return cfg().anySource
end

function F.StatusText()
	if broken then return "not available: " .. broken end
	if not cfg().enabled then return "off" end
	local n, built, refused = 0, 0, {}
	for _, e in pairs(containers) do
		n = n + 1
		for kind, slot in pairs(e.slots) do
			if slot.content then built = built + 1 end
			if slot.content and not slot.textOk then refused[kind] = true end
		end
	end
	local notes = ""
	if refused.icon then notes = notes .. ", icon refused" end
	if refused.num then notes = notes .. ", countdown refused" end
	local plates = "hidden nameplates off"
	if cfg().hiddenPlates then
		local ok, show = pcall(getCVar, "nameplateShowEnemies")
		local ok2, alpha = pcall(getCVar, "nameplateMaxAlpha")
		plates = string.format("hidden nameplates on (enemy plates=%s, max alpha=%s)",
			ok and tostring(show) or "?", ok2 and tostring(alpha) or "?")
	end
	return string.format("on, watching %d units (%d frames made)%s%s, %s, warns for the last %ds; showing-check answers: %d plain, %d secret",
		n, built, notes,
		cfg().anySource and ", showing ANY hunter's Freezing Trap" or ", your own Freezing Trap only", plates,
		window(), F.diag.plain, F.diag.secret)
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

local function isTrap(spellId)
	local name
	if C_Spell and C_Spell.GetSpellName then
		local ok, n = pcall(C_Spell.GetSpellName, spellId)
		if ok then name = n end
	end
	return type(name) == "string" and not (_G.issecretvalue and _G.issecretvalue(name)) and name == TRAP_NAME
end

function F.Init()
	holder = CreateFrame("Frame", "HuntardFreezeHolder", UIParent)
	holder:SetFrameStrata("MEDIUM")
	sizeHolder()

	local ev = CreateFrame("Frame")
	for _, e in ipairs({ "PLAYER_REGEN_ENABLED", "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED",
		"UNIT_TARGET", "ARENA_OPPONENT_UPDATE", "GROUP_ROSTER_UPDATE",
		"NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" }) do
		pcall(ev.RegisterEvent, ev, e)
	end
	pcall(ev.RegisterUnitEvent, ev, "UNIT_SPELLCAST_SUCCEEDED", "player")
	ev:SetScript("OnEvent", function(_, event, unit, _, spellId)
		if event == "PLAYER_REGEN_ENABLED" then
			if pendingSetup then F.Setup() end
			if pendingApply then pendingApply = false; applyAll() end
			if pendingPlates ~= nil then applyPlates(pendingPlates) end
		elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
			if isTrap(spellId) then
				armedUntil = GetTime() + ARMED_FOR
				if not (_G.issecretvalue and _G.issecretvalue(spellId)) then
					trapDuration = TRAP_DURATIONS[spellId] or trapDuration
				end
			end
		elseif event == "PLAYER_TARGET_CHANGED" then
			refresh("target"); refresh("targettarget")
		elseif event == "PLAYER_FOCUS_CHANGED" then
			refresh("focus")
		elseif event == "UNIT_TARGET" then
			if type(unit) == "string" and not (_G.issecretvalue and _G.issecretvalue(unit)) then
				refresh(unit .. "target")
			end
		elseif event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED" then
			-- A plate token now names another mob (plates are recycled): look again.
			if type(unit) == "string" and not (_G.issecretvalue and _G.issecretvalue(unit)) then refresh(unit) end
		elseif event == "ARENA_OPPONENT_UPDATE" then
			if type(unit) == "string" and not (_G.issecretvalue and _G.issecretvalue(unit)) then refresh(unit) end
		elseif event == "GROUP_ROSTER_UPDATE" then
			for _, u in ipairs(INDIRECT) do refresh(u) end
		end
	end)

	-- While a trap may be out: the "someone's target" units get no aura updates
	-- of their own, so they're asked every POLL; the others once a second (a
	-- frozen unit that dies isn't always passed on in combat).
	local tick = 0
	C_Timer.NewTicker(POLL, function()
		if GetTime() > armedUntil or not cfg().enabled or broken then return end
		tick = tick + 1
		for _, u in ipairs(INDIRECT) do refresh(u) end
		if tick % 4 == 0 then
			for _, u in ipairs(DIRECT) do refresh(u) end
		end
	end)

	if cfg().enabled then F.Setup() end
	if platesWanted() then applyPlates(true) end
end
