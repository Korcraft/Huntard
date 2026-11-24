-- Huntard: Core.lua
-- Addon bootstrap: saved variables, slash commands, event wiring. See
-- Range.lua for the real range-detection logic, WarningText.lua for its
-- movable status-text popup, TargetFrameHighlight.lua for the target
-- frame outline, and AlertIcon.lua for the shared icon-alert window --
-- fed by AspectAlert.lua (no aspect active, or stuck in a travel aspect)
-- and SerpentSting.lua (DoT about to fall off your target).
--
-- The earlier 3D-ground-decal feasibility test that used to live in this
-- file served its purpose and confirmed the answer is no (WoW's addon API
-- has no world-to-screen projection for an arbitrary ground point) -- see
-- git history if that reasoning is ever needed again. This is the real
-- feature instead: range-zone awareness via genuine spell range checks.

Huntard = Huntard or {}
local H = Huntard

local DEFAULTS = {
	locked = false,
	warningText = { x = 0, y = -200, scale = 1.0 },
	alertCluster = { x = 120, y = -200, scale = 1.0 },
	petHealth = { threshold = 50 },
	viperAlert = { lowThreshold = 20, highThreshold = 80 },
	ammoAlert = { thresholds = { 75, 50, 25 } },
	ammoRestock = { enabled = true, fillPercent = 100, goldFloor = 1 },
	ammoMemory = {}, -- [player GUID] = { arrow = itemID, bullet = itemID, lastKind = "arrow"|"bullet" }
	aspectAlert = { preferredAspect = nil },
	aspectAlertRequireCombat = false,
	petAbilities = {},
}

local function applyDefaults(db, defaults)
	for k, v in pairs(defaults) do
		if db[k] == nil then
			if type(v) == "table" then
				db[k] = {}
				applyDefaults(db[k], v)
			else
				db[k] = v
			end
		elseif type(v) == "table" and type(db[k]) == "table" then
			applyDefaults(db[k], v)
		end
	end
end

-- ---------------------------------------------------------------------------
-- A copyable text window -- WoW's chat frame has no real select-and-copy,
-- so any debug dump longer than a line or two is practically unreadable
-- there. Built from plain Frame/EditBox/ScrollFrame/Button primitives --
-- EditBox is a bedrock-stable widget (SetMultiLine, HighlightText)
-- unchanged across WoW's entire history, so this needs no client-specific
-- verification the way a real game API would. Same pattern already proven
-- working in Wayfinder's FlightPoints.lua.
-- ---------------------------------------------------------------------------

local debugWindow

function H.ShowCopyableText(title, text)
	if not debugWindow then
		local f = CreateFrame("Frame", "HuntardDebugWindow", UIParent)
		f:SetSize(560, 440)
		f:SetPoint("CENTER")
		f:SetFrameStrata("DIALOG")
		f:SetToplevel(true)
		f:EnableMouse(true)
		f:SetMovable(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)

		local bg = f:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.05, 0.05, 0.05, 0.97)

		local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		label:SetPoint("TOP", 0, -10)
		f.label = label

		local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		hint:SetPoint("TOP", label, "BOTTOM", 0, -4)
		hint:SetText("Click inside, then Ctrl+A, Ctrl+C to copy")

		local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		closeBtn:SetSize(80, 22)
		closeBtn:SetPoint("BOTTOM", 0, 10)
		closeBtn:SetText("Close")
		closeBtn:SetScript("OnClick", function() f:Hide() end)

		local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 14, -44)
		scroll:SetPoint("BOTTOMRIGHT", -32, 40)

		local editBg = CreateFrame("Frame", nil, scroll)
		editBg:SetAllPoints()
		local editBgTex = editBg:CreateTexture(nil, "BACKGROUND")
		editBgTex:SetAllPoints()
		editBgTex:SetColorTexture(0, 0, 0, 0.5)

		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetFontObject("ChatFontNormal")
		edit:SetWidth(500)
		edit:SetAutoFocus(false)
		edit:SetTextInsets(4, 4, 4, 4)
		edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		scroll:SetScrollChild(edit)
		f.edit = edit

		f:Hide()
		debugWindow = f
	end
	debugWindow.label:SetText(title)
	debugWindow.edit:SetText(text)
	debugWindow.edit:HighlightText()
	debugWindow.edit:SetFocus()
	debugWindow:Show()
end

local eventFrame = CreateFrame("Frame", "HuntardEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")

eventFrame:SetScript("OnEvent", function(_, event, addonName)
	if event == "ADDON_LOADED" and addonName == "Huntard" then
		HuntardDB = HuntardDB or {}
		applyDefaults(HuntardDB, DEFAULTS)
		H.db = HuntardDB
	elseif event == "PLAYER_LOGIN" then
		if H.Range and H.Range.Init then H.Range.Init() end
		if H.WarningText and H.WarningText.Init then H.WarningText.Init() end
		if H.TargetFrameHighlight and H.TargetFrameHighlight.Init then H.TargetFrameHighlight.Init() end
		if H.AspectAlert and H.AspectAlert.Init then H.AspectAlert.Init() end
		if H.ViperAlert and H.ViperAlert.Init then H.ViperAlert.Init() end
		if H.SerpentSting and H.SerpentSting.Init then H.SerpentSting.Init() end
		if H.PetHealth and H.PetHealth.Init then H.PetHealth.Init() end
		if H.FeedTray and H.FeedTray.Init then H.FeedTray.Init() end
		if H.AlertCluster and H.AlertCluster.Init then H.AlertCluster.Init() end
		if H.PetAbilities and H.PetAbilities.Init then H.PetAbilities.Init() end
		if H.AmmoAlert and H.AmmoAlert.Init then H.AmmoAlert.Init() end
		if H.AmmoRestock and H.AmmoRestock.Init then H.AmmoRestock.Init() end
		if H.Settings and H.Settings.Init then H.Settings.Init() end
		print("|cff33ff99Huntard|r loaded. Type |cffffffff/huntard|r for settings or |cffffffff/huntard help|r for commands.")
	end
end)

-- NOTE: a prior version of this file registered ADDON_ACTION_BLOCKED /
-- ADDON_ACTION_FORBIDDEN here as a diagnostic catcher. Confirmed live (via
-- that catcher's own output) that THIS CLIENT forbids addons from
-- registering for that event at all -- it reported itself: "action:
-- Frame:RegisterEvent()". Details.lua only touches that event behind a
-- retail-only version gate (GetBuildInfo() >= 100000), which this
-- WotLK-interface client doesn't meet, consistent with that gate existing
-- precisely because older/custom clients don't allow it. Do not re-add
-- this -- it cannot be used for diagnostics on this client.

local function refreshAllMovables()
	if H.WarningText and H.WarningText.Refresh then H.WarningText.Refresh() end
	if H.AlertCluster and H.AlertCluster.Refresh then H.AlertCluster.Refresh() end
end
H.RefreshMovables = refreshAllMovables

function H.ResetPositions()
	local d = {}
	applyDefaults(d, DEFAULTS)
	H.db.warningText = d.warningText
	H.db.alertCluster = d.alertCluster
	refreshAllMovables()
	print("|cff33ff99Huntard|r position/size reset to default.")
end

local function printHelp()
	print("|cff33ff99Huntard|r commands:")
	print("  /huntard              - open the settings window")
	print("  /huntard lock         - lock the status text and the alert icon cluster in place")
	print("  /huntard unlock       - unlock them so you can drag (click+drag) and resize (mouse wheel) them")
	print("  /huntard reset        - reset both back to their default position/size")
	print("  /huntard combatonly   - toggle: aspect alert only while actually in combat (currently "
		.. (H.db and H.db.aspectAlertRequireCombat and "ON" or "off") .. ")")
	print("  /huntard preferaspect hawk|cheetah|pack|wild|fox|beast|eagle|monkey|any - only that exact aspect clears the warning (currently "
		.. (H.db and H.db.aspectAlert and H.db.aspectAlert.preferredAspect or "any") .. ")")
	print("  /huntard debug        - print live melee/ranged range-check values against your current target")
	print("  /huntard pethealthdebug - print whether your pet's health is currently readable or secret, and why")
	print("  /huntard petalerttest - show the low pet health alert for 5 seconds")
	print("  /huntard ssdebug      - print exactly what Serpent Sting tracking currently has recorded")
	print("  /huntard bufframedebug - print exactly what's live-detected right now via Blizzard's default buff icon row")
	print("  /huntard auradebug    - print what the UNIT_AURA instance tracker currently has, and whether a direct query is restricted right now")
	print("  /huntard petdebug     - print what's readable about your active pet's abilities/ranks")
	print("  /huntard pettest      - force a pet ability check right now (normally only runs on pet level-up)")
	print("  /huntard petreminders - clear all pet ability Remind Me / Don't Remind Me history so popups re-evaluate fresh")
	print("  /huntard pethealth N  - set the pet health alert threshold to N percent (10-75, currently "
		.. (H.db and H.db.petHealth and H.db.petHealth.threshold or "?") .. "%, live right now: "
		.. (H.PetHealth and H.PetHealth.GetLiveReadout and H.PetHealth.GetLiveReadout() or "?")
		.. ") -- stand-in for a future slider")
	print("  /huntard manadebug    - check whether mana is readable right now (run it mid-fight)")
	print("  /huntard happinessdebug - check whether pet happiness is readable right now")
	print("  /huntard feeddebug    - list which bag items the Feed Pet tray would offer, and why")
	print("  /huntard viperlow N   - show the Viper Sting icon at or below N percent mana (currently "
		.. (H.db and H.db.viperAlert and H.db.viperAlert.lowThreshold or "?") .. "%)")
	print("  /huntard viperhigh N  - hide the Viper Sting icon at or above N percent mana (currently "
		.. (H.db and H.db.viperAlert and H.db.viperAlert.highThreshold or "?") .. "%)")
	print("  /huntard ammodebug    - print what's readable about your equipped quiver/ammo pouch")
	print("  /huntard restockdebug - show what ammo restocking would do at this vendor, and why (buys nothing)")
	print("  /huntard ammo 75,50,25 - set the ammo warning thresholds, comma separated (currently "
		.. (H.db and H.db.ammoAlert and table.concat(H.db.ammoAlert.thresholds, ",") or "?") .. ")")
end

SLASH_HUNTARD1 = "/huntard"
SlashCmdList.HUNTARD = function(msg)
	msg = (msg or ""):trim():lower()

	if msg == "" and H.Settings then
		H.Settings.Toggle()
	elseif msg == "lock" then
		H.db.locked = true
		refreshAllMovables()
		print("|cff33ff99Huntard|r locked.")
	elseif msg == "unlock" then
		H.db.locked = false
		refreshAllMovables()
		print("|cff33ff99Huntard|r unlocked -- drag the status text and the alert icon anchor wherever you want, "
			.. "scroll the mouse wheel over either one to resize it. The anchor is the small white square -- "
			.. "active alerts fan out around it, centered when there's one, side-by-side when there's more than one.")
	elseif msg == "reset" then
		H.ResetPositions()
	elseif msg == "combatonly" then
		H.db.aspectAlertRequireCombat = not H.db.aspectAlertRequireCombat
		print("|cff33ff99Huntard|r aspect alert combat-only: " .. (H.db.aspectAlertRequireCombat and "ON" or "off"))
	elseif msg:match("^preferaspect%s+%S+$") then
		local input = msg:match("^preferaspect%s+(%S+)$")
		local resolved = H.AspectAlert.SetPreferredAspect(input)
		if resolved then
			print("|cff33ff99Huntard|r preferred aspect set to " .. resolved .. " -- only that exact aspect will clear the warning.")
		elseif input == "any" or input == "clear" or input == "none" then
			print("|cff33ff99Huntard|r preferred aspect cleared -- any real combat aspect will clear the warning.")
		else
			print("|cff33ff99Huntard|r didn't recognize \"" .. input .. "\" -- try hawk, cheetah, pack, wild, fox, beast, eagle, monkey, or any.")
		end
	elseif msg == "debug" then
		if H.Range then H.Range.Debug() end
	elseif msg == "pethealthdebug" then
		if H.PetHealth then H.PetHealth.Debug() end
	elseif msg == "petalerttest" then
		if H.PetHealth then H.PetHealth.TestAlert() end
	elseif msg == "ssdebug" then
		if H.SerpentSting then H.SerpentSting.Debug() end
	elseif msg == "bufframedebug" then
		if H.AspectAlert then H.AspectAlert.DebugBuffFrame() end
	elseif msg == "auradebug" then
		if H.AspectAlert then H.AspectAlert.DebugAuraTracking() end
	elseif msg == "petdebug" then
		if H.PetAbilities then H.PetAbilities.Debug() end
	elseif msg == "pettest" then
		if H.PetAbilities then H.PetAbilities.ForceCheck() end
	elseif msg == "petreminders" then
		local count = 0
		for _ in pairs(H.db.petAbilities) do count = count + 1 end
		for k in pairs(H.db.petAbilities) do H.db.petAbilities[k] = nil end
		print("|cff33ff99Huntard|r cleared " .. count .. " pet ability reminder state(s) (Remind Me / Don't Remind Me history). Run /huntard pettest to recheck fresh.")
	elseif msg:match("^pethealth%s+%d+$") then
		local pct = H.PetHealth.SetThreshold(tonumber(msg:match("%d+")))
		local alertHealth = H.PetHealth.GetAlertHealth()
		print("|cff33ff99Huntard|r pet health alert threshold set to " .. pct .. "%"
			.. (alertHealth and (" (" .. alertHealth .. " health on this pet).") or "."))
	elseif msg:match("^viperlow%s+%d+$") then
		local pct = H.ViperAlert.SetLowThreshold(tonumber(msg:match("%d+")))
		print("|cff33ff99Huntard|r Viper Sting icon will show at or below " .. pct .. "% mana.")
	elseif msg:match("^viperhigh%s+%d+$") then
		local pct = H.ViperAlert.SetHighThreshold(tonumber(msg:match("%d+")))
		print("|cff33ff99Huntard|r Viper Sting icon will hide at or above " .. pct .. "% mana.")
	elseif msg == "manadebug" then
		if H.ViperAlert then H.ViperAlert.DebugMana() end
	elseif msg == "happinessdebug" then
		if H.PetHealth then H.PetHealth.DebugHappiness() end
	elseif msg == "feeddebug" then
		if H.FeedTray then H.FeedTray.Debug() end
	elseif msg == "restockdebug" then
		if H.AmmoRestock then H.AmmoRestock.Debug() end
	elseif msg == "ammodebug" then
		if H.AmmoAlert then H.AmmoAlert.Debug() end
	elseif msg:match("^ammo%s+[%d,%s]+$") then
		local thresholds = {}
		for num in msg:gmatch("%d+") do
			table.insert(thresholds, tonumber(num))
		end
		table.sort(thresholds, function(a, b) return a > b end)
		H.AmmoAlert.SetThresholds(thresholds)
		print("|cff33ff99Huntard|r ammo warning thresholds set to " .. table.concat(thresholds, ", ") .. "%.")
	else
		printHelp()
	end
end
