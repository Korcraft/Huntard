-- Huntard: FeedTray.lua
-- Click the Feed Pet alert icon to open a row of squares under it, one per
-- kind of food in your bags that your pet will eat, with a stack count.
-- Click a square to feed that food. The row stays open while the Feed Pet
-- icon is up (it can take more than one feeding to reach happy) and closes
-- when the icon goes away, when you click the icon again, or when combat
-- starts.
--
-- Anything a quest wants is left out: items the game flags as quest items,
-- and any item named in an objective of a quest in your log (finished or
-- not), so quest drops like boar meat are never offered.
--
-- The squares are secure action buttons (a click that casts a spell has to
-- be). The game only lets addons change those out of combat, so every change
-- here is skipped during combat lockdown. That's fine: the Feed Pet icon
-- itself is hidden in combat and for a few seconds after.

local H = Huntard
H.FeedTray = H.FeedTray or {}
local FeedTray = H.FeedTray

local FEED_PET_SPELL_ID = 6991
local FIRST_BAG, LAST_BAG = 0, 4
local BUTTON_SIZE = 36 -- at alert scale 1.0
local GAP = 4
local PER_ROW = 6
local QUEST_ITEM_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12

local tray, emptyText
local buttons = {}
local isOpen = false
local needsRebuild = true
local anchorSlot -- the alert slot the Feed Pet icon is in right now
local lastX, lastY, lastScale

local function isSecret(v)
	return _G.issecretvalue and _G.issecretvalue(v) or false
end

local feedPetName
local function getFeedPetName()
	if feedPetName then return feedPetName end
	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(FEED_PET_SPELL_ID)
		if info and type(info.name) == "string" then feedPetName = info.name end
	end
	if not feedPetName and _G.GetSpellInfo then
		local name = _G.GetSpellInfo(FEED_PET_SPELL_ID)
		if type(name) == "string" then feedPetName = name end
	end
	return feedPetName or "Feed Pet"
end

-- ---------------------------------------------------------------------------
-- Which bag items qualify
-- ---------------------------------------------------------------------------

-- "Crag Boar Rib: 3/10" -> "crag boar rib". Also handles "3/10 Crag Boar Rib".
local function objectiveName(text)
	if type(text) ~= "string" or isSecret(text) then return nil end
	local name = text:match("^(.-):%s*%d+%s*/%s*%d+") or text:match("^%d+%s*/%s*%d+%s+(.+)$") or text
	name = name:gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then return nil end
	return name:lower()
end

-- Every objective name across your quest log, lowercased.
local function questObjectiveNames()
	local names = {}
	if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo
		and C_QuestLog.GetQuestObjectives) then
		return names
	end
	local okCount, count = pcall(C_QuestLog.GetNumQuestLogEntries)
	if not okCount or type(count) ~= "number" then return names end
	for i = 1, count do
		local okInfo, info = pcall(C_QuestLog.GetInfo, i)
		if okInfo and type(info) == "table" and not info.isHeader and info.questID then
			local okObj, objectives = pcall(C_QuestLog.GetQuestObjectives, info.questID)
			if okObj and type(objectives) == "table" then
				for _, objective in ipairs(objectives) do
					local name = objectiveName(objective.text)
					if name then names[name] = true end
				end
			end
		end
	end
	return names
end

-- True if the game itself marks this bag item as belonging to a quest.
local function isFlaggedQuestItem(bag, slot, itemID)
	if C_Container.GetContainerItemQuestInfo then
		local ok, quest = pcall(C_Container.GetContainerItemQuestInfo, bag, slot)
		if ok and type(quest) == "table" and (quest.isQuestItem or quest.questID) then return true end
	end
	local getInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
	if getInstant then
		local ok, _, _, _, _, _, classID = pcall(getInstant, itemID)
		if ok and classID == QUEST_ITEM_CLASS then return true end
	end
	return false
end

-- true / false, or nil plus a reason when the game won't say.
local function petCanEat(itemID)
	local canEat = C_PetInfo and C_PetInfo.CanPetEatItem
	if not canEat then return nil, "CanPetEatItem missing" end
	local ok, result = pcall(canEat, itemID)
	if not ok then return nil, "error: " .. tostring(result) end
	if isSecret(result) then return nil, "secret" end
	return result == true or result == 1
end

local function nameFromLink(link)
	if type(link) ~= "string" or isSecret(link) then return nil end
	return link:match("%[(.-)%]")
end

-- One entry per kind of food: { itemID, name, icon, count, bag, slot }.
-- bag/slot point at the first stack found, which is the one fed.
local function scanFood()
	local foods, byItem, skip = {}, {}, {}
	local questNames = questObjectiveNames()
	for bag = FIRST_BAG, LAST_BAG do
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local itemID = info and info.itemID
			if itemID and not isSecret(itemID) and not skip[itemID] then
				local entry = byItem[itemID]
				if entry then
					entry.count = entry.count + (info.stackCount or 1)
				else
					local name = nameFromLink(info.hyperlink)
					local eats = petCanEat(itemID)
					if eats and not isFlaggedQuestItem(bag, slot, itemID)
						and not (name and questNames[name:lower()]) then
						entry = {
							itemID = itemID, name = name or ("item " .. itemID),
							icon = info.iconFileID, count = info.stackCount or 1,
							bag = bag, slot = slot,
						}
						byItem[itemID] = entry
						foods[#foods + 1] = entry
					else
						skip[itemID] = true
					end
				end
			end
		end
	end
	table.sort(foods, function(a, b) return a.name < b.name end)
	return foods
end

-- ---------------------------------------------------------------------------
-- The tray
-- ---------------------------------------------------------------------------

local function getButton(i)
	if buttons[i] then return buttons[i] end
	local b = CreateFrame("Button", "HuntardFeedTrayButton" .. i, tray, "SecureActionButtonTemplate")
	-- Same registration Questie uses for its secure item buttons on this client.
	b:RegisterForClicks("AnyUp", "AnyDown")

	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.bg:SetColorTexture(0, 0, 0, 0.6)

	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetPoint("TOPLEFT", 1, -1)
	b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.count:SetPoint("BOTTOMRIGHT", -2, 2)

	b.highlight = b:CreateTexture(nil, "HIGHLIGHT")
	b.highlight:SetAllPoints(b.icon)
	b.highlight:SetColorTexture(1, 1, 1, 0.2)

	b:SetScript("OnEnter", function(self)
		if not self.bag then return end
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		pcall(GameTooltip.SetBagItem, GameTooltip, self.bag, self.slot)
		GameTooltip:AddLine("Click to feed your pet", 0.2, 1, 0.6)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)

	buttons[i] = b
	return b
end

local function rebuild()
	if InCombatLockdown() then
		needsRebuild = true
		return
	end
	needsRebuild = false

	local scale = H.db.alertCluster.scale
	local size, gap = BUTTON_SIZE * scale, GAP * scale
	local foods = scanFood()
	local spell = getFeedPetName()
	local columns = math.min(#foods, PER_ROW)

	for i, food in ipairs(foods) do
		local b = getButton(i)
		b:SetAttribute("type", "macro")
		b:SetAttribute("macrotext", "/cast " .. spell .. "\n/use " .. food.bag .. " " .. food.slot)
		b.bag, b.slot = food.bag, food.slot
		b.icon:SetTexture(food.icon)
		b.count:SetText(food.count > 1 and food.count or "")
		b:SetSize(size, size)

		local row = math.floor((i - 1) / PER_ROW)
		local col = (i - 1) % PER_ROW
		local inRow = math.min(PER_ROW, #foods - row * PER_ROW)
		local x = (col - (inRow - 1) / 2) * (size + gap)
		b:ClearAllPoints()
		b:SetPoint("TOP", tray, "TOP", x, -row * (size + gap))
		b:Show()
	end
	for i = #foods + 1, #buttons do
		local b = buttons[i]
		b:Hide()
		b:SetAttribute("type", nil)
		b:SetAttribute("macrotext", nil)
		b.bag, b.slot = nil, nil
	end

	local rows = math.max(1, math.ceil(#foods / PER_ROW))
	tray:SetSize(math.max(columns, 1) * (size + gap), rows * (size + gap))
	emptyText:SetShown(#foods == 0)
	lastScale = scale
end

local anchorX, anchorY = 0, 0

-- Placed relative to the alert cluster's fixed anchor using offsets Huntard
-- computed itself. Never reads an icon's screen position: those come back
-- secret on this client (confirmed: Lua error, 2026-11-24). Never anchored to
-- the alert icon itself either, so that icon isn't tied to a secure frame and
-- stays free to move during combat.
local function position()
	if not anchorSlot or InCombatLockdown() then return end
	local y = anchorY - GAP * H.db.alertCluster.scale * 2
	if anchorX == lastX and y == lastY then return end
	lastX, lastY = anchorX, y
	tray:ClearAllPoints()
	tray:SetPoint("TOP", anchorSlot, "CENTER", anchorX, y)
end

local function close()
	if not isOpen or InCombatLockdown() then return end
	isOpen = false
	tray:Hide()
	GameTooltip:Hide()
end

local function open()
	if isOpen or InCombatLockdown() then return end
	isOpen = true
	lastX, lastY = nil, nil
	rebuild()
	position()
	tray:Show()
end

-- Click handler for the Feed Pet alert icon.
function FeedTray.Toggle()
	if isOpen then close() else open() end
end

function FeedTray.IsOpen()
	return isOpen
end

-- Called by AlertCluster every layout pass with the cluster anchor and the
-- Feed Pet icon's offset from its center (x, and y of the icon's bottom edge),
-- or nil when that icon isn't showing (which closes the tray).
function FeedTray.SetAnchorSlot(slot, x, y)
	anchorSlot = slot
	anchorX, anchorY = x or 0, y or 0
	if not isOpen then return end
	if not slot then
		close()
		return
	end
	if InCombatLockdown() then return end
	if needsRebuild or lastScale ~= H.db.alertCluster.scale then rebuild() end
	position()
end

-- /huntard feeddebug -- what the tray thinks of every item in your bags.
function FeedTray.Debug()
	local lines = {}
	local function add(s) lines[#lines + 1] = s end
	add("Feed Pet spell name: " .. getFeedPetName())
	add("C_PetInfo.CanPetEatItem exists: " .. tostring(C_PetInfo and C_PetInfo.CanPetEatItem ~= nil))
	add("C_Container.GetContainerItemQuestInfo exists: " .. tostring(C_Container.GetContainerItemQuestInfo ~= nil))
	add("C_QuestLog.GetQuestObjectives exists: " .. tostring(C_QuestLog and C_QuestLog.GetQuestObjectives ~= nil))
	add("pet out: " .. tostring(UnitExists("pet") and true or false)
		.. "  in combat lockdown: " .. tostring(InCombatLockdown() and true or false))

	local questNames = questObjectiveNames()
	local objectiveList = {}
	for name in pairs(questNames) do objectiveList[#objectiveList + 1] = name end
	table.sort(objectiveList)
	add("quest objectives seen: " .. (#objectiveList > 0 and table.concat(objectiveList, "; ") or "(none)"))
	add("")

	local seen = {}
	for bag = FIRST_BAG, LAST_BAG do
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local itemID = info and info.itemID
			if itemID and not isSecret(itemID) and not seen[itemID] then
				seen[itemID] = true
				local name = nameFromLink(info.hyperlink) or ("item " .. itemID)
				local eats, why = petCanEat(itemID)
				local flagged = isFlaggedQuestItem(bag, slot, itemID)
				local objective = questNames[name:lower()] == true
				local verdict = (eats and not flagged and not objective) and "IN TRAY" or "-"
				add(string.format("%-8s %-30s eats=%s questFlag=%s questObjective=%s",
					verdict, name, eats == nil and ("? " .. tostring(why)) or tostring(eats),
					tostring(flagged), tostring(objective)))
			end
		end
	end

	H.ShowCopyableText("Huntard feed tray check", table.concat(lines, "\n"))
end

function FeedTray.Init()
	tray = CreateFrame("Frame", "HuntardFeedTray", UIParent)
	tray:SetFrameStrata("MEDIUM")
	tray:SetFrameLevel(30)
	tray:SetSize(1, 1)
	tray:Hide()

	emptyText = tray:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	emptyText:SetPoint("TOP", tray, "TOP", 0, -4)
	emptyText:SetText("No food your pet will eat")
	emptyText:SetTextColor(1, 0.35, 0.35)
	emptyText:Hide()

	local events = CreateFrame("Frame")
	events:RegisterEvent("PLAYER_REGEN_DISABLED")
	events:RegisterEvent("BAG_UPDATE_DELAYED")
	events:RegisterEvent("QUEST_LOG_UPDATE")
	events:RegisterEvent("UNIT_PET")
	events:SetScript("OnEvent", function(_, event, unit)
		if event == "PLAYER_REGEN_DISABLED" then
			-- Fires just before combat lockdown starts, the last moment the
			-- secure squares can still be hidden.
			close()
			return
		end
		if event == "UNIT_PET" and unit ~= "player" then return end
		needsRebuild = true
		if isOpen and not InCombatLockdown() then rebuild() end
	end)
end
