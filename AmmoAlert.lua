-- Huntard: AmmoAlert.lua
-- Quick, transient "Ammo at 75%" / "Ammo at 50%" / "Ammo at 25%" style
-- messages (via UIErrorsFrame -- the same system Blizzard's own "Out of
-- range" / "Not enough mana" messages use, so these look and feel native
-- rather than like a custom popup) fired once each time your ammo
-- percentage crosses one of your configured thresholds going DOWN. Refilling
-- back above a threshold re-arms it, so dropping below it again later fires
-- again.
--
-- Percentage is current ammo count divided by your equipped quiver/ammo
-- pouch's total capacity (its slot count times the ammo item's own max
-- stack size) -- NOT a flat count, since pouch size varies. This is a
-- best-effort formula, not confirmed against this server's actual ammo
-- mechanics yet (unlike nearly everything else in this addon, which was
-- live-tested before being trusted) -- see /huntard ammodebug, which dumps
-- exactly what bag was detected as the quiver, its slot count, the ammo
-- item found and its stack size, and the resulting count/capacity/percent,
-- so this can be corrected against real data instead of staying a guess.
--
-- APIs used here (C_Item.GetItemInfoInstant, C_Item.GetItemInfo,
-- C_Container.GetContainerNumSlots/GetContainerItemInfo,
-- ContainerIDToInventoryID) are all confirmed real and in active use by
-- other installed addons on this client (Auctionator, Baganator, Details) --
-- verified via grep before writing any of this, consistent with how every
-- other API in this addon was checked.

local H = Huntard
H.AmmoAlert = H.AmmoAlert or {}

local DEFAULT_THRESHOLDS = { 75, 50, 25 }
local QUIVER_CLASS_ID = Enum and Enum.ItemClass and Enum.ItemClass.Quiver or 11
local QUIVER_BAG_FAMILIES = 3 -- bag family bits: 1 = quiver, 2 = ammo pouch

local lastPct -- nil until the first real reading, so login/reload never fires a false crossing

local function getBagInventorySlot(bagID)
	if C_Container and C_Container.ContainerIDToInventoryID then
		local ok, slot = pcall(C_Container.ContainerIDToInventoryID, bagID)
		if ok and slot then return slot end
	end
	if _G.ContainerIDToInventoryID then
		local ok, slot = pcall(_G.ContainerIDToInventoryID, bagID)
		if ok and slot then return slot end
	end
	local ok, slot = pcall(GetInventorySlotInfo, "Bag" .. (bagID - 1) .. "Slot")
	if ok then return slot end
	return nil
end

local function getBagItemClass(itemId)
	if not itemId then return nil end
	local getInfo = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
	if not getInfo then return nil end
	local ok, _, _, _, _, _, classID = pcall(getInfo, itemId)
	return ok and classID or nil
end

local function getBagFamily(bagID)
	local ok, _, family = pcall(C_Container.GetContainerNumFreeSlots, bagID)
	if ok and type(family) == "number" then return family end
	return nil
end

local function findQuiverBag()
	local numBags = NUM_BAG_SLOTS or 4
	for bagID = 1, numBags do
		local invSlot = getBagInventorySlot(bagID)
		local itemId = invSlot and GetInventoryItemID("player", invSlot)
		local family = getBagFamily(bagID)
		if getBagItemClass(itemId) == QUIVER_CLASS_ID
			or (family and bit.band(family, QUIVER_BAG_FAMILIES) ~= 0) then
			return bagID, itemId
		end
	end
	return nil
end

-- Returns (count, capacity, pct), or nil if no quiver/ammo pouch is
-- currently equipped at all.
local function readAmmo()
	local bagID = findQuiverBag()
	if not bagID then return nil end

	local numSlots = C_Container.GetContainerNumSlots(bagID)
	if not numSlots or numSlots <= 0 then return nil end

	local count, maxStack = 0, nil
	for slot = 1, numSlots do
		local info = C_Container.GetContainerItemInfo(bagID, slot)
		if info and info.itemID then
			count = count + (info.stackCount or 0)
			if not maxStack then
				local okInfo, _, _, _, _, _, _, _, stackCount = pcall(C_Item.GetItemInfo, info.itemID)
				if okInfo and stackCount and stackCount > 0 then
					maxStack = stackCount
				end
			end
		end
	end

	if not maxStack then return count, nil, nil end -- pouch is empty -- can't infer stack size with nothing in it
	local capacity = numSlots * maxStack
	if capacity <= 0 then return count, capacity, nil end
	return count, capacity, (count / capacity) * 100
end

function H.AmmoAlert.SetThresholds(thresholds)
	H.db.ammoAlert.thresholds = thresholds
end

local function checkThresholds(pct)
	if lastPct == nil then
		lastPct = pct
		return
	end
	if pct < lastPct then
		local crossed = false
		for _, threshold in ipairs(H.db.ammoAlert.thresholds) do
			if lastPct > threshold and pct <= threshold then
				UIErrorsFrame:AddMessage(string.format("Ammo at %d%%", threshold), 1.0, 0.5, 0.1)
				crossed = true
			end
		end
		if crossed then
			-- Once per drop, even if a big move crossed several thresholds.
			-- Master channel so it still plays with game sound effects off.
			PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
		end
	end
	lastPct = pct
end

local function update()
	local _, _, pct = readAmmo()
	if not pct then return end
	checkThresholds(pct)
end

function H.AmmoAlert.Init()
	local ticker = CreateFrame("Frame")
	ticker:SetScript("OnUpdate", function(self, elapsed)
		self.t = (self.t or 0) + elapsed
		if self.t > 1 then -- ammo count doesn't need fast polling
			self.t = 0
			update()
		end
	end)
end

-- /huntard ammodebug -- dumps exactly what's readable about the equipped
-- quiver/ammo pouch, since the capacity formula here is a best-effort
-- attempt, not something confirmed working on this client yet.
function H.AmmoAlert.Debug()
	local lines = {}
	local function add(s) table.insert(lines, s) end

	for bag = 1, NUM_BAG_SLOTS or 4 do
		local invSlot = getBagInventorySlot(bag)
		local bagItem = invSlot and GetInventoryItemID("player", invSlot)
		add(string.format("bag %d: invSlot=%s item=%s class=%s family=%s slots=%s",
			bag, tostring(invSlot), tostring(bagItem), tostring(getBagItemClass(bagItem)),
			tostring(getBagFamily(bag)), tostring(C_Container.GetContainerNumSlots(bag))))
	end
	add("")

	local bagID, itemId = findQuiverBag()
	add("detected quiver bag ID: " .. tostring(bagID))
	add("quiver item ID: " .. tostring(itemId))
	if bagID then
		add("quiver slot count: " .. tostring(C_Container.GetContainerNumSlots(bagID)))
	end

	local count, capacity, pct = readAmmo()
	add("ammo count: " .. tostring(count))
	add("computed capacity: " .. tostring(capacity))
	add("computed percent: " .. tostring(pct))
	add("")
	add("configured thresholds: " .. table.concat(H.db.ammoAlert.thresholds, ", "))

	H.ShowCopyableText("Huntard ammo debug", table.concat(lines, "\n"))
end
