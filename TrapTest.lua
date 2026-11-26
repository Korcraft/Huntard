-- Huntard: TrapTest.lua
-- /huntard traptest -- a recorder, not a feature. Finds out what this client
-- lets an addon see about Freezing Trap, before a trap countdown is built:
--   - your trap casts (UNIT_SPELLCAST_SUCCEEDED, known to work)
--   - the trap's cooldown: does it start when you lay it, or when it springs?
--   - the target / focus / nameplate debuffs: readable, secret, or missing?
--   - UNIT_AURA events on those units (does one fire when they freeze/break?)
--   - the target frame's own debuff icons (Blizzard can show secret auras)
--   - whether a secret debuff can be handed straight to a countdown icon
--     without reading it: a row of test icons on screen tries three ways.
-- Run once to start, again to stop (stops by itself after 90 seconds); the
-- log opens in the copy window. Everything is logged only when it changes.

local H = Huntard
H.TrapTest = H.TrapTest or {}

local RECORD_SECONDS = 90
local POLL = 0.25
local MAX_LINES = 600
local MAX_AURAS = 20
local TEST_ICONS = 8
local TRAP_NAMES = { "Freezing Trap", "Frost Trap", "Immolation Trap", "Explosive Trap", "Snake Trap" }

local function isSecret(v) return _G.issecretvalue and _G.issecretvalue(v) or false end

local function S(v)
	if isSecret(v) then return "<secret>" end
	if type(v) == "number" then
		if v == math.floor(v) then return tostring(v) end
		return string.format("%.2f", v)
	end
	return tostring(v)
end

local rec -- nil when not recording

local function stamp()
	return string.format("[%6.2f]", GetTime() - rec.start)
end

local function log(s)
	if not rec or #rec.lines >= MAX_LINES then return end
	rec.lines[#rec.lines + 1] = stamp() .. " " .. s
end

-- Logs `text` under `key` only when it differs from last time.
local function logChange(key, text)
	if not rec then return end
	if rec.last[key] == text then return end
	rec.last[key] = text
	log(key .. ": " .. text)
end

local function spellName(id)
	if C_Spell and C_Spell.GetSpellName then
		local ok, n = pcall(C_Spell.GetSpellName, id)
		if ok then return n end
	end
	if _G.GetSpellInfo then
		local ok, n = pcall(_G.GetSpellInfo, id)
		if ok then return n end
	end
end

-- ---------------------------------------------------------------------------
-- Trap cooldown
-- ---------------------------------------------------------------------------

local function cooldownText(name)
	local start, duration
	if C_Spell and C_Spell.GetSpellCooldown then
		local ok, info = pcall(C_Spell.GetSpellCooldown, name)
		if not ok then return "C_Spell.GetSpellCooldown errored" end
		if isSecret(info) then return "<secret table>" end
		if not info then return "no info (spell not known?)" end
		start, duration = info.startTime, info.duration
	elseif _G.GetSpellCooldown then
		local ok, s, d = pcall(_G.GetSpellCooldown, name)
		if not ok then return "GetSpellCooldown errored" end
		start, duration = s, d
	else
		return "no cooldown API"
	end
	if isSecret(start) or isSecret(duration) then
		return "start=" .. S(start) .. " duration=" .. S(duration)
	end
	if not start or start == 0 or not duration or duration <= 1.5 then
		return "ready (start=" .. S(start) .. " duration=" .. S(duration) .. ")"
	end
	return string.format("ON COOLDOWN start=%.2f (%.2fs ago) duration=%.1f",
		start - rec.start, GetTime() - start, duration)
end

-- ---------------------------------------------------------------------------
-- Debuffs on a unit
-- ---------------------------------------------------------------------------

local function auraLine(a)
	if isSecret(a) then return "<secret aura table>" end
	local parts = {}
	for _, f in ipairs({ "name", "spellId", "duration", "expirationTime", "sourceUnit", "auraInstanceID", "icon" }) do
		local ok, v = pcall(function() return a[f] end)
		parts[#parts + 1] = f .. "=" .. (ok and S(v) or "<error>")
	end
	return table.concat(parts, " ")
end

local function debuffSummary(unit)
	if not UnitExists(unit) then return "none" end
	local who = UnitName(unit)
	local head = "name=" .. S(who) .. " player=" .. S(UnitIsPlayer(unit))
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return head .. " (no C_UnitAuras.GetAuraDataByIndex)" end
	local list = {}
	for i = 1, MAX_AURAS do
		local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL")
		if not ok then list[#list + 1] = i .. ": <error: " .. S(a) .. ">"; break end
		if not isSecret(a) and a == nil then break end
		list[#list + 1] = i .. ": " .. auraLine(a)
	end
	local byName = "n/a"
	if C_UnitAuras.GetAuraDataBySpellName then
		local ok, a = pcall(C_UnitAuras.GetAuraDataBySpellName, unit, "Freezing Trap Effect", "HARMFUL")
		byName = not ok and "<error>" or (not isSecret(a) and a == nil and "not found") or auraLine(a)
	end
	return head .. " | debuffs: " .. (#list > 0 and table.concat(list, " ; ") or "none")
		.. " | by name 'Freezing Trap Effect': " .. byName
end

local function watchedUnits()
	local units = { "target", "focus" }
	for i = 1, 40 do
		local u = "nameplate" .. i
		if UnitExists(u) then units[#units + 1] = u end
	end
	return units
end

-- ---------------------------------------------------------------------------
-- The target frame's own debuff icons
-- ---------------------------------------------------------------------------

local function targetFrameIcons()
	local out = {}
	local function inspect(btn, label)
		local okShown, shown = pcall(btn.IsShown, btn)
		if not (okShown and shown) then return end
		local icon = btn.Icon or btn.icon or (btn.GetName and btn:GetName() and _G[btn:GetName() .. "Icon"])
		local tex = icon and icon.GetTexture and select(2, pcall(icon.GetTexture, icon))
		local cd = btn.Cooldown or btn.cooldown or (btn.GetName and btn:GetName() and _G[btn:GetName() .. "Cooldown"])
		local cdText = "no cooldown frame"
		if cd and cd.GetCooldownTimes then
			local ok, s, d = pcall(cd.GetCooldownTimes, cd)
			cdText = ok and ("cd start=" .. S(s) .. " dur=" .. S(d)) or "cd <error>"
		end
		out[#out + 1] = label .. " tex=" .. S(tex) .. " " .. cdText
	end
	for i = 1, 16 do
		local b = _G["TargetFrameDebuff" .. i]
		if b then inspect(b, "TargetFrameDebuff" .. i) end
	end
	if #out == 0 and TargetFrame and TargetFrame.auraPools and TargetFrame.auraPools.EnumerateActive then
		local ok = pcall(function()
			for b in TargetFrame.auraPools:EnumerateActive() do inspect(b, "pool") end
		end)
		if not ok then out[#out + 1] = "auraPools <error>" end
	end
	return #out > 0 and table.concat(out, " ; ") or "no shown debuff icons"
end

-- ---------------------------------------------------------------------------
-- Test icons: can a secret debuff be shown as a countdown without reading it?
-- ---------------------------------------------------------------------------

local iconRow

local function buildIcons()
	if iconRow then return end
	iconRow = CreateFrame("Frame", nil, UIParent)
	iconRow:SetSize(TEST_ICONS * 40, 60)
	iconRow:SetPoint("CENTER", UIParent, "CENTER", 0, 170)
	local title = iconRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	title:SetPoint("BOTTOM", iconRow, "TOP", 0, 2)
	title:SetText("Huntard trap test: your target's debuffs (letter = what worked)")
	iconRow.icons = {}
	for i = 1, TEST_ICONS do
		local f = CreateFrame("Frame", nil, iconRow)
		f:SetSize(36, 36)
		f:SetPoint("TOPLEFT", iconRow, "TOPLEFT", (i - 1) * 40, 0)
		f.tex = f:CreateTexture(nil, "ARTWORK")
		f.tex:SetAllPoints()
		f.cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
		f.cd:SetAllPoints()
		if f.cd.SetHideCountdownNumbers then f.cd:SetHideCountdownNumbers(false) end
		f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		f.label:SetPoint("TOP", f, "BOTTOM", 0, -1)
		f:Hide()
		iconRow.icons[i] = f
	end
end

-- Tries each way of feeding one aura's timing to a cooldown swipe. Returns
-- the letters that worked: A = duration object, B = from expiration time,
-- C = plain SetCooldown (needs maths on the values).
local function feedCooldown(cd, unit, a)
	local worked = {}
	local okId, id = pcall(function() return a.auraInstanceID end)
	if okId and C_UnitAuras.GetAuraDuration and cd.SetCooldownFromDurationObject then
		local ok = pcall(function()
			local obj = C_UnitAuras.GetAuraDuration(unit, id)
			if not obj then error("no duration object") end
			cd:SetCooldownFromDurationObject(obj)
		end)
		if ok then worked[#worked + 1] = "A" end
	end
	if #worked == 0 and cd.SetCooldownFromExpirationTime then
		local ok = pcall(function() cd:SetCooldownFromExpirationTime(a.expirationTime, a.duration) end)
		if ok then worked[#worked + 1] = "B" end
	end
	if #worked == 0 then
		local ok = pcall(function() cd:SetCooldown(a.expirationTime - a.duration, a.duration) end)
		if ok then worked[#worked + 1] = "C" end
	end
	return #worked > 0 and table.concat(worked) or "-"
end

local function refreshIcons()
	if not iconRow then return end
	local results = {}
	for i = 1, TEST_ICONS do
		local f = iconRow.icons[i]
		local ok, a = false, nil
		if UnitExists("target") and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
			ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "target", i, "HARMFUL")
		end
		if ok and not isSecret(a) and a ~= nil then
			local texOk = pcall(function() f.tex:SetTexture(a.icon) end)
			if not texOk then f.tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark") end
			if f.cd.Clear then f.cd:Clear() end
			local how = feedCooldown(f.cd, "target", a)
			f.label:SetText(how)
			f:Show()
			results[#results + 1] = i .. ": icon " .. (texOk and "ok" or "FAILED") .. ", countdown " .. how
		elseif ok and isSecret(a) then
			f.tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
			if f.cd.Clear then f.cd:Clear() end
			f.label:SetText("secret")
			f:Show()
			results[#results + 1] = i .. ": whole aura secret"
		else
			f:Hide()
		end
	end
	logChange("test icons", #results > 0 and table.concat(results, " ; ") or "none shown")
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
local ticker

local function poll()
	if not rec then return end
	logChange("in combat", S(UnitAffectingCombat("player"))
		.. "  auras secret right now: " .. S(C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()))
	for _, name in ipairs(TRAP_NAMES) do
		if name == "Freezing Trap" or rec.knownTraps[name] then
			logChange("cooldown " .. name, cooldownText(name))
		end
	end
	for _, u in ipairs(watchedUnits()) do
		logChange("debuffs " .. u, debuffSummary(u))
	end
	logChange("target frame icons", targetFrameIcons())
	if GetTime() - rec.start >= RECORD_SECONDS then H.TrapTest.Stop() end
end

local function onAura(unit, info)
	if isSecret(unit) then log("UNIT_AURA unit=<secret>"); return end
	if unit ~= "target" and unit ~= "focus" and not tostring(unit):match("^nameplate") then return end
	local desc
	if isSecret(info) then
		desc = "updateInfo <secret>"
	elseif type(info) ~= "table" then
		desc = "updateInfo " .. S(info)
	else
		local parts = { "fullUpdate=" .. S(info.isFullUpdate) }
		for _, f in ipairs({ "addedAuras", "updatedAuraInstanceIDs", "removedAuraInstanceIDs" }) do
			local v = info[f]
			if isSecret(v) then
				parts[#parts + 1] = f .. "=<secret>"
			elseif type(v) == "table" then
				local items = {}
				for _, x in ipairs(v) do
					items[#items + 1] = not isSecret(x) and type(x) == "table" and ("{" .. auraLine(x) .. "}") or S(x)
				end
				parts[#parts + 1] = f .. "=[" .. table.concat(items, ", ") .. "]"
			end
		end
		desc = table.concat(parts, " ")
	end
	log("UNIT_AURA " .. unit .. " " .. desc)
	if unit == "target" then refreshIcons() end
end

events:SetScript("OnEvent", function(_, event, a1, a2, a3)
	if not rec then return end
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		local name = spellName(a3)
		log("YOU CAST " .. S(name) .. " (spell " .. S(a3) .. ")"
			.. "  target=" .. S(UnitExists("target") and UnitName("target")))
		if not isSecret(name) and name and name:find("Trap") then rec.knownTraps[name] = true end
		poll()
	elseif event == "UNIT_AURA" then
		onAura(a1, a2)
	elseif event == "PLAYER_TARGET_CHANGED" then
		log("target changed -> " .. S(UnitExists("target") and UnitName("target")))
		refreshIcons()
	elseif event == "PLAYER_FOCUS_CHANGED" then
		log("focus changed -> " .. S(UnitExists("focus") and UnitName("focus")))
	elseif event == "SPELL_UPDATE_COOLDOWN" then
		local before = rec.last["cooldown Freezing Trap"]
		poll()
		if rec and rec.last["cooldown Freezing Trap"] ~= before then log("  (that change came with SPELL_UPDATE_COOLDOWN)") end
	elseif event == "PLAYER_REGEN_DISABLED" then
		log("entered combat")
	elseif event == "PLAYER_REGEN_ENABLED" then
		log("left combat")
	elseif event == "LOSS_OF_CONTROL_ADDED" or event == "UNIT_FLAGS" then
		log(event .. " " .. S(a1))
	end
end)

local EVENTS = { "UNIT_AURA", "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "SPELL_UPDATE_COOLDOWN",
	"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }

function H.TrapTest.Start()
	rec = { start = GetTime(), lines = {}, last = {}, knownTraps = {} }
	log("recording started. Client build: " .. S(select(4, GetBuildInfo())))
	log("APIs: GetAuraDataByIndex=" .. tostring(C_UnitAuras and C_UnitAuras.GetAuraDataByIndex ~= nil)
		.. " GetAuraDataBySpellName=" .. tostring(C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName ~= nil)
		.. " GetAuraDuration=" .. tostring(C_UnitAuras and C_UnitAuras.GetAuraDuration ~= nil)
		.. " C_Spell.GetSpellCooldown=" .. tostring(C_Spell and C_Spell.GetSpellCooldown ~= nil)
		.. " GetSpellCooldown=" .. tostring(_G.GetSpellCooldown ~= nil))
	for _, ev in ipairs(EVENTS) do pcall(events.RegisterEvent, events, ev) end
	pcall(events.RegisterUnitEvent, events, "UNIT_SPELLCAST_SUCCEEDED", "player")
	pcall(events.RegisterUnitEvent, events, "UNIT_FLAGS", "target")
	buildIcons()
	iconRow:Show()
	refreshIcons()
	ticker = C_Timer.NewTicker(POLL, poll)
	poll()
	print("|cff33ff99Huntard|r trap test recording for " .. RECORD_SECONDS .. "s. Target the one you want to freeze, "
		.. "lay a Freezing Trap, let them walk in. Type |cffffffff/huntard traptest|r again to stop early.")
end

function H.TrapTest.Stop()
	if not rec then return end
	if ticker then ticker:Cancel(); ticker = nil end
	events:UnregisterAllEvents()
	if iconRow then iconRow:Hide() end
	log("recording stopped.")
	local lines = rec.lines
	if #lines >= MAX_LINES then lines[#lines + 1] = "(log full -- stopped adding lines at " .. MAX_LINES .. ")" end
	rec = nil
	H.ShowCopyableText("Huntard trap test", table.concat(lines, "\n"))
end

function H.TrapTest.Toggle()
	if rec then H.TrapTest.Stop() else H.TrapTest.Start() end
end
