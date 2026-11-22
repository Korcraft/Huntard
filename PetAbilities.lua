-- Huntard: PetAbilities.lua
-- Hunter pets on this server never auto-learn new ability ranks (or brand
-- new abilities) as they level -- confirmed via live research against
-- ForeverChanges' own WoW Forever hunter pet guide (foreverchanges.pro/
-- hunter-pets) and corroborated by a second independent source
-- (mmonster.co's "WoW Forever Pet Abilities" guide), plus your own direct
-- in-game experience with Claw. The split is clean, not per-ability
-- special-casing:
--   - PASSIVE/DEFENSIVE abilities (Growl, Great Stamina, Natural Armor, the
--     resistances) are bought straight from any pet trainer, new Growl rank
--     every 10 pet levels (10/20/30/40/50/60).
--   - ACTIVE abilities (Claw, Bite, Swipe, Dash, and presumably the
--     equivalent active abilities on other families) can ONLY be learned by
--     taming a beast that already knows that rank, learning it yourself,
--     then teaching your own pet via Beast Training -- a trainer visit
--     alone can never grant these, confirmed by your own Claw experience.
--
-- Bear family level table (the only family sourced so far -- confirmed via
-- the same two independent sources, cross-checked against each other):
--   Claw/Bite: ranks 1-8 at pet level 1/8/16/24/32/40/48/56
--   Swipe:     ranks 1-5 at pet level 12/24/36/48/60 (Forever-specific --
--              Classic already gave this to boar/cat/hyena/tallstrider/wolf,
--              bears are a Forever addition)
--   Dash:      ranks 1-3 at pet level 30/40/50 (also a Forever addition for
--              bears specifically)
--   Growl:     new rank at pet level 10/20/30/40/50/60, via trainer
--
-- DETECTION IS SPLIT BY CONFIDENCE, unlike everything else in this addon
-- which was fully live-verified before being trusted:
--   - "Missing ability entirely" is HIGH confidence: GetPetActionInfo across
--     the pet action bar slots (confirmed real on this client via grep
--     against TellMeWhen's own PlayerAttributes.lua condition code) tells
--     us the base ability NAMES your pet currently has, independent of
--     rank. If your level-appropriate family ability isn't in that list at
--     all, that's unambiguous.
--   - "Outdated RANK of a known ability" is LOWER confidence: there's no
--     addon on this client confirmed to read a specific pet ability's
--     currently-known rank number, and action-bar names typically don't
--     include a rank suffix (only tooltips historically did, on Classic-era
--     clients this interface number matches). This attempts a tooltip scan
--     for a "Rank N" pattern as a best effort, but it is NOT verified
--     working yet -- see /huntard petdebug, which dumps exactly what's
--     readable so this can be corrected against real data instead of
--     staying a guess.

local H = Huntard
H.PetAbilities = H.PetAbilities or {}

local METHOD_TRAINER = "trainer"
local METHOD_PET = "pet" -- needs the two-pet tame-learn-teach method

-- [creatureFamily] = { {name=, method=, levels={...levels, one per rank...}}, ... }
local FAMILY_ABILITIES = {
	Bear = {
		{ name = "Claw", method = METHOD_PET, levels = { 1, 8, 16, 24, 32, 40, 48, 56 } },
		{ name = "Bite", method = METHOD_PET, levels = { 1, 8, 16, 24, 32, 40, 48, 56 } },
		{ name = "Swipe", method = METHOD_PET, levels = { 12, 24, 36, 48, 60 } },
		{ name = "Dash", method = METHOD_PET, levels = { 30, 40, 50 } },
		{ name = "Growl", method = METHOD_TRAINER, levels = { 10, 20, 30, 40, 50, 60 } },
	},
}

local REMIND_INTERVAL = 24 * 60 * 60 -- 24 hours, in real seconds (time(), not GetTime())

local function dbState()
	H.db.petAbilities = H.db.petAbilities or {}
	return H.db.petAbilities
end

-- Highest rank unlocked at a given pet level, or 0 if the ability isn't
-- unlocked at all yet.
local function highestUnlockedRank(ability, petLevel)
	local rank = 0
	for i, reqLevel in ipairs(ability.levels) do
		if petLevel >= reqLevel then
			rank = i
		end
	end
	return rank
end

-- Scans the pet action bar for ability base names currently known, and
-- (best-effort) a rank number per name via tooltip text. Returns
-- knownNames[name] = true, and knownRanks[name] = rank or nil if the rank
-- couldn't be determined from the tooltip.
--
-- Iterates tooltip:GetRegions() looking for FontStrings rather than relying
-- on named globals like "HuntardPetScanTooltipTextLeft1" -- confirmed via
-- Auctionator's own ScanTooltip.lua as the more robust real-world pattern,
-- given how many naming/API assumptions have already broken on this client.
local scanTooltip = CreateFrame("GameTooltip", "HuntardPetScanTooltip", nil, "GameTooltipTemplate")
scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
local function scanPetActionBar()
	local knownNames, knownRanks = {}, {}
	local slots = NUM_PET_ACTION_SLOTS or 10
	for i = 1, slots do
		local ok, name = pcall(GetPetActionInfo, i)
		if ok and name and name ~= "" then
			knownNames[name] = true

			local okTip = pcall(function()
				scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
				scanTooltip:SetPetAction(i)
			end)
			if okTip then
				for _, region in ipairs({ scanTooltip:GetRegions() }) do
					if region and region.GetObjectType and region:GetObjectType() == "FontString" then
						local text = region:GetText()
						local rankNum = text and text:match("Rank (%d+)")
						if rankNum then
							knownRanks[name] = tonumber(rankNum)
							break
						end
					end
				end
				scanTooltip:Hide()
			end
		end
	end
	return knownNames, knownRanks
end

local function popupKey(familyName, abilityName)
	return familyName .. ":" .. abilityName
end

local TRAINER_TEXT = "Your pet can learn a new rank of %s from the pet trainer (available since level %d)."
local TAME_TEXT = "Your pet is missing %s (or has an outdated rank) -- this can only be learned by taming another beast that knows it, then teaching your pet."

local function onAccept(self, data)
	dbState()[data.key] = { lastShown = time(), dismissed = false }
end
local function onCancel(self, data)
	dbState()[data.key] = { lastShown = time(), dismissed = true }
end

-- Each ability gets its OWN StaticPopupDialogs entry (registered lazily,
-- the first time it's actually needed) rather than sharing just two
-- templates split by method. Confirmed live: WoW's StaticPopup system does
-- NOT show two simultaneous instances of the identical "which" template --
-- a second StaticPopup_Show call for an already-visible "which" just
-- overwrites its text/data instead of stacking a new dialog, so Claw and
-- Bite (both the "tame another pet" type) were silently clobbering each
-- other and only the last one ever rendered. Giving every ability a
-- distinct dialog name (e.g. "HUNTARD_PET_ABILITY_Bear_Claw") makes them
-- fully independent, so any number of them can be visible at once (up to
-- Blizzard's own simultaneous-dialog limit).
local registeredDialogs = {}
local function ensureDialogRegistered(familyName, ability)
	local dialogName = "HUNTARD_PET_ABILITY_" .. familyName .. "_" .. ability.name
	if registeredDialogs[dialogName] then return dialogName end
	StaticPopupDialogs[dialogName] = {
		text = (ability.method == METHOD_TRAINER) and TRAINER_TEXT or TAME_TEXT,
		button1 = "Remind Me",
		button2 = "Don't Remind Me",
		OnAccept = onAccept,
		OnCancel = onCancel,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		showAlert = true,
	}
	registeredDialogs[dialogName] = true
	return dialogName
end

local function showPopup(familyName, ability)
	local key = popupKey(familyName, ability.name)
	local state = dbState()[key]
	if state and state.dismissed then return end
	if state and state.lastShown and (time() - state.lastShown) < REMIND_INTERVAL then return end

	local dialogName = ensureDialogRegistered(familyName, ability)
	local unlockedAt = ability.levels[1]
	StaticPopup_Show(dialogName, ability.name, unlockedAt, { key = key })
end

local lastCheckedLevel

local function checkPet()
	local family = UnitCreatureFamily("pet")
	local petLevel = UnitLevel("pet")
	if not family or not petLevel or petLevel <= 0 then return end

	local abilities = FAMILY_ABILITIES[family]
	if not abilities then return end -- family not sourced yet

	local knownNames, knownRanks = scanPetActionBar()

	for _, ability in ipairs(abilities) do
		local unlockedRank = highestUnlockedRank(ability, petLevel)
		if unlockedRank > 0 then
			if not knownNames[ability.name] then
				showPopup(family, ability)
			else
				local currentRank = knownRanks[ability.name]
				-- Only flag an outdated rank when the tooltip scan actually
				-- gave us a rank number to compare -- otherwise we'd be
				-- guessing, which this addon avoids throughout.
				if currentRank and currentRank < unlockedRank then
					showPopup(family, ability)
				end
			end
		end
	end
end

-- /huntard pettest -- runs the same check Init() only normally runs on a
-- real pet level-up, so the popup(s) can be seen immediately without
-- waiting for your pet to actually level.
function H.PetAbilities.ForceCheck()
	checkPet()
end

function H.PetAbilities.Init()
	local watch = CreateFrame("Frame")
	watch:RegisterUnitEvent("UNIT_LEVEL", "pet")
	watch:RegisterEvent("PLAYER_ENTERING_WORLD")
	watch:SetScript("OnEvent", function(_, event)
		local petLevel = UnitLevel("pet")
		if not petLevel then return end

		if event == "PLAYER_ENTERING_WORLD" then
			-- Confirmed live: the pet action bar isn't reliably populated yet
			-- at the exact instant PLAYER_ENTERING_WORLD fires on login/reload
			-- -- checking immediately produced false "missing ability" popups
			-- for abilities the pet actually has (GetPetActionInfo reading
			-- empty slots that hadn't synced in yet). Give it a few seconds.
			lastCheckedLevel = petLevel
			C_Timer.After(3, function()
				if UnitExists("pet") then checkPet() end
			end)
			return
		end

		if petLevel ~= lastCheckedLevel then
			lastCheckedLevel = petLevel
			checkPet()
		end
	end)
end

-- /huntard petdebug -- dumps exactly what's readable about the active pet's
-- abilities, since the rank-detection piece above is a best-effort attempt,
-- not something confirmed working on this client yet.
function H.PetAbilities.Debug()
	local lines = {}
	local function add(s) table.insert(lines, s) end

	local family = UnitCreatureFamily("pet")
	local petLevel = UnitLevel("pet")
	add("pet exists: " .. tostring(UnitExists("pet")))
	add("pet family (UnitCreatureFamily): " .. tostring(family))
	add("pet level: " .. tostring(petLevel))
	add("")

	local knownNames, knownRanks = scanPetActionBar()
	add("-- Pet action bar scan (GetPetActionInfo) --")
	local slots = NUM_PET_ACTION_SLOTS or 10
	for i = 1, slots do
		local ok, name, texture, isToken = pcall(GetPetActionInfo, i)
		if ok and name and name ~= "" then
			add(string.format("slot %d: name=%q isToken=%s tooltipRank=%s",
				i, tostring(name), tostring(isToken), tostring(knownRanks[name])))
		end
	end

	add("")
	local abilities = FAMILY_ABILITIES[family or ""]
	if abilities then
		add("-- Comparison against known table for family " .. family .. " --")
		for _, ability in ipairs(abilities) do
			local unlockedRank = petLevel and highestUnlockedRank(ability, petLevel) or 0
			local reminderState = dbState()[popupKey(family, ability.name)]
			add(string.format("%s (%s): unlockedRank=%d knownInActionBar=%s detectedRank=%s reminderState=%s",
				ability.name, ability.method, unlockedRank,
				tostring(knownNames[ability.name]), tostring(knownRanks[ability.name]),
				reminderState and (reminderState.dismissed and "DISMISSED permanently" or "snoozed until " .. date("%c", reminderState.lastShown + 24 * 60 * 60)) or "none (never shown/responded to)"))
		end
	else
		add("No ability table sourced yet for family: " .. tostring(family))
	end

	H.ShowCopyableText("Huntard pet ability debug", table.concat(lines, "\n"))
end
