-- Huntard: StingTimer.lua
-- The end of YOUR sting on YOUR CURRENT TARGET (Serpent, Viper or Scorpid
-- Sting): its icon with a countdown for the last N seconds (the /huntard
-- slider, default 3). Only the target: you can have stings ticking on many
-- mobs, and the one that matters is the one you're looking at.
--
-- Drawn by the game, the same way as the Freezing Trap countdown (see
-- FreezeTimer.lua for the full story): Blizzard's aura container watches your
-- target for your own stings and shows a frame only while one is really there,
-- writing the real time left into it through formatters that print nothing
-- above the window. So a sting that missed or was resisted never shows, one
-- that's dispelled vanishes at once, and the time is exact. Huntard never
-- reads the sting itself (auras on other units are secret in combat).
--
-- One container (the target), two frames per sting kind: the icon (an inline
-- texture printed by a formatter) and the number over it. A hunter has only
-- one sting on a mob at a time, so at most one kind shows.
--
-- PLACE: the game's frames are always secret to Lua (IsShown, 26 Nov 2026),
-- so these can't be counted in the cluster's row. They sit in the row's next
-- free spot (AlertCluster -> PlaceAt), ahead of the Freezing Trap countdown.
--
-- SPELL IDS: the debuff of a sting has the same ID as the shot that casts it,
-- so any rank this list lacks is learned from your own casts (saved per
-- account in HuntardDB.stingIds) and the frames are rebuilt out of combat.
--
-- The old cast-timed countdown (SerpentSting.lua) is no longer drawn; git tag
-- before-game-stings has it.

local H = Huntard
H.StingTimer = H.StingTimer or {}
local T = H.StingTimer

local KINDS = {
	{ key = "serpent", name = "Serpent Sting",
		ids = { 1978, 13549, 13550, 13551, 13552, 13553, 13554, 13555, 25295, 27016 } },
	{ key = "viper", name = "Viper Sting", ids = { 3034, 14279, 14280, 27018 } },
	{ key = "scorpid", name = "Scorpid Sting", ids = { 3043, 14275, 14276, 14277, 27060 } },
}
local BY_NAME = {}
for _, k in ipairs(KINDS) do BY_NAME[k.name] = k end

local UNIT = "target"
local SIZE = 48

local container
local slots = {} -- list of { key, kind = KINDS entry, part = "icon"|"num", button, text, ... }
local holder
local broken
local pendingSetup, pendingApply = false, false
local gen = 0

local function inCombat() return InCombatLockdown() or UnitAffectingCombat("player") end
local function scale() return H.db.alertCluster.scale end
local function window() return H.SerpentSting.GetWindow() end
local function isSecret(v) return _G.issecretvalue and _G.issecretvalue(v) or false end

local function spellIcon(name)
	if C_Spell and C_Spell.GetSpellTexture then
		local ok, icon = pcall(C_Spell.GetSpellTexture, name)
		if ok and icon and not isSecret(icon) then return icon end
	end
	if _G.GetSpellInfo then
		local ok, _, _, icon = pcall(_G.GetSpellInfo, name)
		if ok and icon and not isSecret(icon) then return icon end
	end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- The IDs one kind's filter lets through: the known ranks plus any learned.
local function idSet(kind)
	local set = {}
	for _, id in ipairs(kind.ids) do set[id] = true end
	local learned = H.db.stingIds and H.db.stingIds[kind.key]
	if learned then for _, id in ipairs(learned) do set[id] = true end end
	return set
end

-- ---------------------------------------------------------------------------
-- Formatters (nothing above the window, nothing at 0)
-- ---------------------------------------------------------------------------

local formatters = {}
local function getFormatter(slot)
	local w = window()
	local key = (slot.part == "num" and "num" or slot.kind.key) .. w
	if formatters[key] ~= nil then return formatters[key] or nil end
	formatters[key] = false
	local make = C_StringUtil and C_StringUtil.CreateNumericRuleFormatter
	if not make then return nil end
	local up = Enum and Enum.NumericRuleFormatRounding and Enum.NumericRuleFormatRounding.Up
	local shown = slot.part == "num" and { threshold = 0.05, step = 1, rounding = up, format = "%.0f" }
		or { threshold = 0.05, format = "|T" .. tostring(slot.kind.icon) .. ":0|t" }
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

local function styleText(slot)
	local fs = slot.text
	fs:ClearAllPoints()
	if slot.part == "icon" then
		fs:SetPoint("CENTER", fs:GetParent(), "CENTER", 0, 0)
		fs:SetFont(fontFile(), SIZE * scale())
	else
		-- Same look as the old countdown (AlertCluster.lua)
		fs:SetPoint("BOTTOM", fs:GetParent(), "BOTTOM", 0, 2)
		fs:SetFont(fontFile(), 22 * scale(), "OUTLINE")
		fs:SetTextColor(1, 1, 1, 1)
	end
end

local function bindText(slot)
	local f = getFormatter(slot)
	slot.window = window()
	slot.textOk = f and pcall(slot.button.SetDurationText, slot.button, slot.text, { textFormatter = f }) or false
end

-- ---------------------------------------------------------------------------
-- The holder and the game's frames
-- ---------------------------------------------------------------------------

local placedX, placedAnchor
-- Called by AlertCluster every layout: x is this countdown's spot in the row.
function T.PlaceAt(anchor, x)
	if not holder or (placedAnchor == anchor and placedX == x) then return end
	placedAnchor, placedX = anchor, x
	holder:ClearAllPoints()
	holder:SetPoint("CENTER", anchor, "CENTER", x, 0)
end

local function sizeHolder()
	local size = SIZE * scale()
	holder:SetSize(size, size)
	if not placedAnchor then holder:SetPoint("CENTER", HuntardAlertAnchor or UIParent, "CENTER", 0, 0) end
end

local function build(slot, b)
	if slot.button == b and slot.content then return end
	slot.button = b
	pcall(b.EnableMouse, b, false)
	pcall(b.ClearAllPoints, b)
	pcall(b.SetAllPoints, b, holder)
	if slot.part == "num" then pcall(b.SetFrameLevel, b, holder:GetFrameLevel() + 5) end
	if type(b.GetIcon) == "function" then
		local ok, icon = pcall(b.GetIcon, b)
		if ok and icon and icon.Hide then pcall(icon.Hide, icon) end
	end
	local content = CreateFrame("Frame", nil, b)
	content:SetAllPoints(b)
	slot.content = content
	slot.text = content:CreateFontString(nil, "OVERLAY")
	styleText(slot)
	slot.text:SetText("")
	bindText(slot)
end

local function applyAll()
	if inCombat() then pendingApply = true; return end
	sizeHolder()
	for _, slot in ipairs(slots) do
		if slot.text then
			styleText(slot)
			if slot.window ~= window() then bindText(slot) end
		end
	end
end

-- Builds (or rebuilds, after learning a new ID) the frames. Out of combat only.
function T.Setup()
	if broken then return end
	if inCombat() then pendingSetup = true; return end
	pendingSetup = false
	local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
	if load then pcall(load, "Blizzard_AuraContainer") end
	if not container then
		local ok, c = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
		if not ok or not c or not c.AddAuraSlot then
			broken = "Blizzard's aura container isn't available on this client"
			return
		end
		pcall(c.SetAllPoints, c, UIParent)
		pcall(c.SetFrameStrata, c, "MEDIUM")
		pcall(c.SetUnit, c, UNIT)
		pcall(c.SetEnabled, c, true)
		container = c
	end
	for _, slot in ipairs(slots) do
		pcall(container.SetAuraSlotEnabled, container, slot.key, false)
		if slot.button then pcall(slot.button.Hide, slot.button) end
	end
	wipe(slots)
	gen = gen + 1
	for _, kind in ipairs(KINDS) do
		for _, part in ipairs({ "icon", "num" }) do
			local slot = { key = "huntard_sting_" .. kind.key .. "_" .. part .. "_" .. gen, kind = kind, part = part }
			local ok, res = pcall(container.AddAuraSlot, container, slot.key, "HARMFUL|PLAYER", {
				templateNames = { "HuntardFreezeTemplate" },
				initializeFrame = function(b) pcall(build, slot, b) end,
				candidateFilters = { includeSpellIDs = idSet(kind) },
			})
			if not ok then
				broken = "the game refused the sting filter (" .. tostring(res) .. ")"
				return
			end
			slots[#slots + 1] = slot
			if type(res) == "table" and not slot.content then pcall(build, slot, res) end
			pcall(container.SetAuraSlotEnabled, container, slot.key, true)
		end
	end
	applyAll()
end

local function refresh()
	if not container then return end
	if type(container.UpdateAllAuras) == "function" then
		pcall(container.UpdateAllAuras, container)
	else
		pcall(container.SetUnit, container, "none")
		pcall(container.SetUnit, container, UNIT)
	end
end

-- A sting rank the filter doesn't know: learn it (the debuff has the cast's ID).
local function learn(kind, spellId)
	if type(spellId) ~= "number" or isSecret(spellId) or idSet(kind)[spellId] then return end
	H.db.stingIds = H.db.stingIds or {}
	local list = H.db.stingIds[kind.key] or {}
	H.db.stingIds[kind.key] = list
	if #list >= 20 then return end
	list[#list + 1] = spellId
	T.Setup() -- now, or when this fight ends
end

-- ---------------------------------------------------------------------------
-- Settings, preview and status
-- ---------------------------------------------------------------------------

function T.Refresh() if holder then applyAll() end end

local demo
function T.Preview()
	if not holder then return end
	if not demo then
		demo = CreateFrame("Frame", nil, holder)
		demo:SetAllPoints(holder)
		demo.icon = demo:CreateTexture(nil, "ARTWORK")
		demo.icon:SetAllPoints()
		demo.text = demo:CreateFontString(nil, "OVERLAY")
		demo.text:SetPoint("BOTTOM", demo, "BOTTOM", 0, 2)
		demo:SetScript("OnUpdate", function(self)
			local left = self.endAt - GetTime()
			if left <= 0 then self:Hide(); return end
			self.text:SetText(tostring(math.ceil(left)))
		end)
	end
	demo.icon:SetTexture(KINDS[1].icon)
	demo.text:SetFont(fontFile(), 22 * scale(), "OUTLINE")
	demo.endAt = GetTime() + window()
	demo:Show()
end

function T.StatusText()
	if broken then return "not available: " .. broken end
	local built, refused = 0, 0
	for _, slot in ipairs(slots) do
		if slot.content then built = built + 1 end
		if slot.content and not slot.textOk then refused = refused + 1 end
	end
	local learned = 0
	for _, list in pairs(H.db.stingIds or {}) do learned = learned + #list end
	return string.format("watching your target for your Serpent, Viper and Scorpid Sting (%d of %d frames made%s), "
		.. "warns for the last %ds, %d sting rank(s) learned from your casts",
		built, #KINDS * 2, refused > 0 and (", " .. refused .. " refused") or "", window(), learned)
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

function T.Init()
	for _, kind in ipairs(KINDS) do kind.icon = spellIcon(kind.name) end

	holder = CreateFrame("Frame", "HuntardStingHolder", UIParent)
	holder:SetFrameStrata("MEDIUM")
	sizeHolder()

	local ev = CreateFrame("Frame")
	pcall(ev.RegisterEvent, ev, "PLAYER_REGEN_ENABLED")
	pcall(ev.RegisterEvent, ev, "PLAYER_TARGET_CHANGED")
	pcall(ev.RegisterUnitEvent, ev, "UNIT_SPELLCAST_SUCCEEDED", "player")
	ev:SetScript("OnEvent", function(_, event, _, _, spellId)
		if event == "PLAYER_REGEN_ENABLED" then
			if pendingSetup then T.Setup() end
			if pendingApply then pendingApply = false; applyAll() end
		elseif event == "PLAYER_TARGET_CHANGED" then
			refresh()
		elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
			if isSecret(spellId) then return end
			local name
			if C_Spell and C_Spell.GetSpellName then
				local ok, n = pcall(C_Spell.GetSpellName, spellId)
				if ok and not isSecret(n) then name = n end
			end
			local kind = name and BY_NAME[name]
			if kind then learn(kind, spellId) end
		end
	end)

	-- A target that dies isn't always passed on to the container in combat:
	-- ask it to look again once a second.
	C_Timer.NewTicker(1, function()
		if container and UnitExists(UNIT) then refresh() end
	end)

	T.Setup()
end
