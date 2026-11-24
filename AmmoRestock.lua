-- Huntard: AmmoRestock.lua
-- Refills your quiver or ammo pouch when you open a vendor that sells ammo.
--
-- Rules (agreed with the user):
--  * Only with a real quiver/ammo pouch equipped. Ammo kept in regular bags:
--    do nothing, say nothing.
--  * Bow/crossbow fills a quiver, gun fills an ammo pouch. If only the wrong
--    kind is equipped, buy nothing and say so (also said on weapon swap).
--  * Fills EMPTY slots only, with full stacks; half-used stacks are left alone.
--    The fill setting is the share of the container's slots to keep filled.
--  * Buys the ammo you last had loaded (remembered per character, arrows and
--    bullets separately). If the vendor doesn't sell it, you've never loaded
--    ammo of this kind, or you've used the other kind since (the memory may be
--    outgrown), a window offers every ammo of the right kind you can use, plus
--    Buy nothing.
--  * Never spends below the gold floor.
--
-- Buying: BuyMerchantItem's amount is counted in single items on this client
-- (confirmed in-game: asking for 1 bought a small amount, not a stack),
-- so each purchase asks for one full stack per empty slot.

local H = Huntard
H.AmmoRestock = H.AmmoRestock or {}
local R = H.AmmoRestock

local PREFIX = "|cff33ff99Huntard|r "
local AMMO_SLOT = 0
local RANGED_SLOT = 18
local WEAPON_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local PROJECTILE_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Projectile) or 6
local QUIVER_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Quiver) or 11
local FAMILY_QUIVER, FAMILY_POUCH = 1, 2
local DEFAULT_STACK = 200
local START_DELAY = 0.3 -- ammo goes in the quiver/pouch, so it needn't wait for AutoVendor
local BUY_DELAY = 0.25 -- how often to check whether the last purchase arrived
local MAX_WAITS = 8 -- checks with nothing arriving before giving up (~2 seconds)
local MAX_BUYS = 60

-- Weapon subclass -> what it shoots.
local WEAPON_KINDS = {
	[2] = { kind = "arrow", noun = "bow" },
	[3] = { kind = "bullet", noun = "gun" },
	[18] = { kind = "arrow", noun = "crossbow" },
}
local PROJECTILE_KINDS = { [2] = "arrow", [3] = "bullet" }
local KIND_FAMILY = { arrow = FAMILY_QUIVER, bullet = FAMILY_POUCH }
local KIND_CONTAINER = { arrow = "quiver", bullet = "ammo pouch" }
local KIND_PLURAL = { arrow = "arrows", bullet = "bullets" }

local session = 0 -- bumped on every vendor open/close; stale timers stop

local function isSecret(v)
	return _G.issecretvalue and _G.issecretvalue(v) or false
end

local function formatMoney(copper)
	copper = math.floor(copper + 0.5)
	local gold = math.floor(copper / 10000)
	local silver = math.floor(copper / 100) % 100
	local rest = copper % 100
	local parts = {}
	if gold > 0 then parts[#parts + 1] = gold .. "g" end
	if silver > 0 then parts[#parts + 1] = silver .. "s" end
	if rest > 0 or #parts == 0 then parts[#parts + 1] = rest .. "c" end
	return table.concat(parts, " ")
end

local function itemClass(itemID)
	local getInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
	if not (itemID and getInstant) then return nil end
	local ok, _, _, _, _, _, classID, subclassID = pcall(getInstant, itemID)
	if not ok then return nil end
	return classID, subclassID
end

-- name, minLevel, maxStack (any may be nil if the item isn't cached yet)
local function itemDetails(itemID)
	local getInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
	if not getInfo then return nil end
	local ok, name, _, _, _, minLevel, _, _, maxStack = pcall(getInfo, itemID)
	if not ok then return nil end
	return name, minLevel, maxStack
end

local function itemCount(itemID)
	local count = (C_Item and C_Item.GetItemCount) or _G.GetItemCount
	local ok, n = pcall(count, itemID)
	return ok and type(n) == "number" and n or 0
end

local function projectileKind(itemID)
	local classID, subclassID = itemClass(itemID)
	if classID ~= PROJECTILE_CLASS then return nil end
	return PROJECTILE_KINDS[subclassID]
end

-- "arrow"/"bullet" plus the weapon's noun, or nil for no ranged weapon/wand/thrown.
local function weaponKind()
	local itemID = GetInventoryItemID("player", RANGED_SLOT)
	local classID, subclassID = itemClass(itemID)
	if classID ~= WEAPON_CLASS then return nil end
	local entry = WEAPON_KINDS[subclassID]
	if not entry then return nil end
	return entry.kind, entry.noun
end

-- ---------------------------------------------------------------------------
-- Remembered ammo, per character
-- ---------------------------------------------------------------------------

local function characterMemory()
	local guid = UnitGUID("player")
	if not guid or isSecret(guid) then return nil end
	H.db.ammoMemory = H.db.ammoMemory or {}
	H.db.ammoMemory[guid] = H.db.ammoMemory[guid] or {}
	return H.db.ammoMemory[guid]
end

local function recordLoadedAmmo()
	local itemID = GetInventoryItemID("player", AMMO_SLOT)
	if not itemID or isSecret(itemID) then return end
	local kind = projectileKind(itemID)
	local memory = characterMemory()
	if not (kind and memory) then return end
	memory[kind] = itemID
	memory.lastKind = kind
end

-- ---------------------------------------------------------------------------
-- Containers
-- ---------------------------------------------------------------------------

local function bagFamily(bag)
	local ok, _, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
	if ok and type(family) == "number" and family > 0 then return family end
	-- Fallback: the bag item's own subclass (2 = quiver, 3 = ammo pouch).
	local invSlot
	if C_Container.ContainerIDToInventoryID then
		local okSlot, slot = pcall(C_Container.ContainerIDToInventoryID, bag)
		if okSlot then invSlot = slot end
	end
	local classID, subclassID = itemClass(invSlot and GetInventoryItemID("player", invSlot))
	if classID == QUIVER_CLASS then
		if subclassID == 2 then return FAMILY_QUIVER end
		if subclassID == 3 then return FAMILY_POUCH end
	end
	return 0
end

local function hasFamily(family, bit_)
	if bit and bit.band then return bit.band(family, bit_) ~= 0 end
	return family % (bit_ * 2) >= bit_
end

-- Returns: matching bags {bag, slots, empty}, and whether ANY ammo container exists.
local function ammoContainers(kind)
	local matching, anyAmmoBag = {}, false
	for bag = 1, NUM_BAG_SLOTS or 4 do
		local family = bagFamily(bag)
		if hasFamily(family, FAMILY_QUIVER) or hasFamily(family, FAMILY_POUCH) then
			anyAmmoBag = true
			if kind and hasFamily(family, KIND_FAMILY[kind]) then
				local slots = C_Container.GetContainerNumSlots(bag) or 0
				local empty = 0
				for slot = 1, slots do
					if not C_Container.GetContainerItemInfo(bag, slot) then empty = empty + 1 end
				end
				matching[#matching + 1] = { bag = bag, slots = slots, empty = empty }
			end
		end
	end
	return matching, anyAmmoBag
end

local function stacksWanted(matching)
	local slots, empty = 0, 0
	for _, b in ipairs(matching) do
		slots, empty = slots + b.slots, empty + b.empty
	end
	local target = math.floor(slots * H.db.ammoRestock.fillPercent / 100 + 0.5)
	return math.max(0, target - (slots - empty)), slots, empty
end

local function mismatchMessage(kind, noun)
	return string.format("you have a %s equipped but no %s, so no %s were bought.",
		noun, KIND_CONTAINER[kind], KIND_PLURAL[kind])
end

-- ---------------------------------------------------------------------------
-- The vendor
-- ---------------------------------------------------------------------------

local function merchantItemID(index)
	if _G.GetMerchantItemID then
		local ok, id = pcall(_G.GetMerchantItemID, index)
		if ok and type(id) == "number" then return id end
	end
	local link = GetMerchantItemLink(index)
	return link and tonumber(link:match("item:(%d+)"))
end

-- name, price, per-purchase count, isUsable for one vendor slot. The old
-- GetMerchantItemInfo global doesn't exist on this client (confirmed: Lua
-- error, 2026-11-24); same shim Auctionator uses here.
local function merchantItemInfo(index)
	if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
		local ok, info = pcall(C_MerchantFrame.GetItemInfo, index)
		if ok and type(info) == "table" then
			return info.name, info.price, info.stackCount, info.isUsable
		end
		return nil
	end
	if _G.GetMerchantItemInfo then
		local name, _, price, perPurchase, _, _, isUsable = _G.GetMerchantItemInfo(index)
		return name, price, perPurchase, isUsable
	end
	return nil
end

-- Every ammo this vendor sells: { index, itemID, name, price, perPurchase,
-- minLevel, maxStack, kind, usable }.
local function vendorAmmo()
	local list = {}
	local level = UnitLevel("player")
	for index = 1, GetMerchantNumItems() do
		local itemID = merchantItemID(index)
		local kind = itemID and projectileKind(itemID)
		if kind then
			local name, price, perPurchase, isUsable = merchantItemInfo(index)
			local itemName, minLevel, maxStack = itemDetails(itemID)
			local usable
			if type(minLevel) == "number" then
				usable = minLevel <= level
			else
				usable = isUsable ~= false
			end
			list[#list + 1] = {
				index = index, itemID = itemID, kind = kind,
				name = itemName or name or ("item " .. itemID),
				price = price or 0, perPurchase = (perPurchase and perPurchase > 0) and perPurchase or 1,
				minLevel = minLevel, maxStack = maxStack or DEFAULT_STACK, usable = usable,
			}
		end
	end
	return list
end

local function stackCost(offer)
	return offer.price / offer.perPurchase * offer.maxStack
end

-- ---------------------------------------------------------------------------
-- Buying
-- ---------------------------------------------------------------------------

local function buy(offer, stacks, id)
	if type(_G.BuyMerchantItem) ~= "function" then
		print(PREFIX .. "can't buy: this client has no BuyMerchantItem. Please report this.")
		return
	end
	local floorCopper = H.db.ammoRestock.goldFloor * 10000
	local perStack = stackCost(offer)
	if perStack > 0 then
		local affordable = math.floor((GetMoney() - floorCopper) / perStack)
		if affordable < stacks then
			if affordable <= 0 then
				print(PREFIX .. "not enough gold above your " .. H.db.ammoRestock.goldFloor
					.. "g floor to buy " .. offer.name .. ".")
				return
			end
			print(PREFIX .. "buying only " .. affordable .. " of " .. stacks
				.. " stacks to stay above your " .. H.db.ammoRestock.goldFloor .. "g floor.")
			stacks = affordable
		end
	end

	local moneyBefore, startCount = GetMoney(), itemCount(offer.itemID)
	local goal = startCount + stacks * offer.maxStack
	local buys, waits, requested = 0, 0, 0

	local function finish()
		local bought = itemCount(offer.itemID) - startCount
		if bought > 0 then
			print(PREFIX .. "bought " .. bought .. " " .. offer.name .. " for "
				.. formatMoney(moneyBefore - GetMoney()) .. ".")
		else
			print(PREFIX .. "couldn't buy " .. offer.name .. ".")
		end
	end

	local function step(lastCount)
		if id ~= session then return end
		local now = itemCount(offer.itemID)
		if lastCount and now <= lastCount then
			-- The last purchase hasn't arrived yet: check again shortly, and
			-- give up if it never does (out of gold, vendor sold out, etc.).
			waits = waits + 1
			if waits >= MAX_WAITS then return finish() end
			C_Timer.After(BUY_DELAY, function() step(lastCount) end)
			return
		end
		waits = 0
		-- Safety net: if a purchase ever delivers far more than asked for
		-- (a vendor counting in bundles instead of items), stop right there.
		if lastCount and now - lastCount > requested * 1.5 then
			print(PREFIX .. "stopped: the vendor gave more ammo than asked for. Please report this.")
			return finish()
		end
		if now >= goal or buys >= MAX_BUYS then return finish() end

		-- Confirmed in-game: the amount is counted in single items, so ask for
		-- a whole stack (or whatever's left of the goal) per purchase.
		buys = buys + 1
		requested = math.min(goal - now, offer.maxStack)
		BuyMerchantItem(offer.index, requested)
		C_Timer.After(BUY_DELAY, function() step(now) end)
	end
	step(nil)
end

-- ---------------------------------------------------------------------------
-- The choice window
-- ---------------------------------------------------------------------------

local choice

local function hideChoice()
	if choice then choice:Hide() end
end

local function showChoice(message, offers, stacks, remembered, id)
	if not choice then
		choice = CreateFrame("Frame", "HuntardAmmoChoice", UIParent)
		choice:SetFrameStrata("DIALOG")
		choice:SetToplevel(true)
		choice:EnableMouse(true)
		choice:SetMovable(true)
		choice:RegisterForDrag("LeftButton")
		choice:SetScript("OnDragStart", choice.StartMoving)
		choice:SetScript("OnDragStop", choice.StopMovingOrSizing)
		choice:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
		local bg = choice:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.05, 0.05, 0.05, 0.95)
		choice.title = choice:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		choice.title:SetPoint("TOP", 0, -12)
		choice.title:SetWidth(320)
		choice.buttons = {}
		table.insert(UISpecialFrames, "HuntardAmmoChoice") -- Esc closes it
	end

	choice.title:SetText(message)
	local options = {}
	for _, offer in ipairs(offers) do
		local label = string.format("Buy %s (%d %s, %s)", offer.name, stacks,
			stacks == 1 and "stack" or "stacks", formatMoney(stackCost(offer) * stacks))
		if offer.itemID == remembered then label = label .. " - last used" end
		options[#options + 1] = { label = label, run = function() buy(offer, stacks, id) end }
	end
	options[#options + 1] = { label = "Buy nothing", run = function() end }

	local top = 20 + choice.title:GetStringHeight()
	for i, option in ipairs(options) do
		local b = choice.buttons[i]
		if not b then
			b = CreateFrame("Button", nil, choice, "UIPanelButtonTemplate")
			b:SetSize(320, 24)
			choice.buttons[i] = b
		end
		b:ClearAllPoints()
		b:SetPoint("TOP", choice, "TOP", 0, -top - (i - 1) * 28)
		b:SetText(option.label)
		b:SetScript("OnClick", function()
			hideChoice()
			option.run()
		end)
		b:Show()
	end
	for i = #options + 1, #choice.buttons do choice.buttons[i]:Hide() end
	choice:SetSize(350, top + #options * 28 + 10)
	choice:Show()
end

-- ---------------------------------------------------------------------------
-- The decision
-- ---------------------------------------------------------------------------

-- Works out what to do at this vendor. Returns a plan table; run() acts on it
-- and the debug command just prints it.
local function plan()
	local p = {}
	p.kind, p.noun = weaponKind()
	if not p.kind then p.action = "nothing: no bow, gun or crossbow equipped" return p end

	local matching, anyAmmoBag = ammoContainers(p.kind)
	p.matching = matching
	p.offers = {}
	for _, offer in ipairs(vendorAmmo()) do
		if offer.kind == p.kind and offer.usable then p.offers[#p.offers + 1] = offer end
		if offer.kind then p.vendorSellsAmmo = true end
	end

	if not anyAmmoBag then p.action = "nothing: no quiver or ammo pouch equipped" return p end
	if #matching == 0 then
		p.action = "mismatch"
		return p
	end

	p.stacks, p.slots, p.empty = stacksWanted(matching)
	if p.stacks == 0 then p.action = "nothing: already filled to the setting" return p end
	if #p.offers == 0 then p.action = "nothing: this vendor sells no usable " .. KIND_PLURAL[p.kind] return p end

	local memory = characterMemory() or {}
	p.remembered = memory[p.kind]
	p.stale = memory.lastKind ~= nil and memory.lastKind ~= p.kind
	if p.remembered and not p.stale then
		for _, offer in ipairs(p.offers) do
			if offer.itemID == p.remembered then
				p.offer = offer
				p.action = "buy"
				return p
			end
		end
	end

	p.action = "ask"
	local rememberedName = p.remembered and (itemDetails(p.remembered) or ("item " .. p.remembered))
	if not p.remembered then
		p.message = "Your " .. p.noun .. " needs ammo."
	elseif p.stale then
		p.message = "Your " .. p.noun .. " needs " .. KIND_PLURAL[p.kind] .. ". You last used " .. rememberedName .. "."
	else
		p.message = "This vendor doesn't sell " .. rememberedName .. "."
	end
	return p
end

local function run(id)
	if id ~= session or not H.db.ammoRestock.enabled then return end
	local p = plan()
	if p.action == "mismatch" then
		if p.vendorSellsAmmo then print(PREFIX .. mismatchMessage(p.kind, p.noun)) end
	elseif p.action == "buy" then
		buy(p.offer, p.stacks, id)
	elseif p.action == "ask" then
		showChoice(p.message, p.offers, p.stacks, p.remembered, id)
	end
end

-- Warns right away when a weapon swap leaves only the wrong container.
local lastWeaponKind
local function checkWeaponSwap()
	local kind, noun = weaponKind()
	if kind == lastWeaponKind then return end
	local first = lastWeaponKind == nil
	lastWeaponKind = kind
	if first or not kind or not H.db.ammoRestock.enabled then return end
	local matching, anyAmmoBag = ammoContainers(kind)
	if anyAmmoBag and #matching == 0 then
		print(PREFIX .. "you have a " .. noun .. " equipped but no " .. KIND_CONTAINER[kind]
			.. ". Ammo restocking will skip it.")
	end
end

function R.SetFillPercent(pct)
	pct = math.max(0, math.min(100, math.floor(pct)))
	H.db.ammoRestock.fillPercent = pct
	return pct
end

function R.SetGoldFloor(gold)
	gold = math.max(0, math.min(100, math.floor(gold)))
	H.db.ammoRestock.goldFloor = gold
	return gold
end

-- /huntard restockdebug -- what restocking would do here and why. Buys nothing.
function R.Debug()
	local lines = {}
	local function add(s) lines[#lines + 1] = s end
	local p = plan()
	add("enabled: " .. tostring(H.db.ammoRestock.enabled)
		.. "  fill: " .. H.db.ammoRestock.fillPercent .. "%  gold floor: " .. H.db.ammoRestock.goldFloor .. "g")
	add("weapon: " .. tostring(p.noun) .. " (" .. tostring(p.kind) .. ")")
	add("loaded ammo now: " .. tostring(GetInventoryItemID("player", AMMO_SLOT)))
	local memory = characterMemory() or {}
	add(string.format("remembered: arrow=%s bullet=%s lastKind=%s", tostring(memory.arrow),
		tostring(memory.bullet), tostring(memory.lastKind)))
	add("")
	for bag = 1, NUM_BAG_SLOTS or 4 do
		add(string.format("bag %d: family=%d slots=%s", bag, bagFamily(bag),
			tostring(C_Container.GetContainerNumSlots(bag))))
	end
	for _, b in ipairs(p.matching or {}) do
		add(string.format("matching container: bag %d, %d slots, %d empty", b.bag, b.slots, b.empty))
	end
	add("stacks to buy: " .. tostring(p.stacks))
	add("")
	add("vendor open: " .. tostring(MerchantFrame and MerchantFrame:IsShown() or false))
	for _, offer in ipairs(vendorAmmo()) do
		add(string.format("  %-22s id=%d kind=%s price=%s per %d  minLevel=%s maxStack=%s usable=%s",
			offer.name, offer.itemID, offer.kind, formatMoney(offer.price), offer.perPurchase,
			tostring(offer.minLevel), tostring(offer.maxStack), tostring(offer.usable)))
	end
	add("")
	add("decision: " .. tostring(p.action) .. (p.offer and (" " .. p.offer.name) or "")
		.. (p.message and ("  window: " .. p.message) or ""))
	H.ShowCopyableText("Huntard ammo restock check", table.concat(lines, "\n"))
end

function R.Init()
	recordLoadedAmmo()
	lastWeaponKind = weaponKind()

	local events = CreateFrame("Frame")
	events:RegisterEvent("MERCHANT_SHOW")
	events:RegisterEvent("MERCHANT_CLOSED")
	events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
	events:RegisterEvent("UNIT_INVENTORY_CHANGED")
	events:SetScript("OnEvent", function(_, event, arg1)
		if event == "MERCHANT_SHOW" then
			session = session + 1
			local id = session
			C_Timer.After(START_DELAY, function() run(id) end)
		elseif event == "MERCHANT_CLOSED" then
			session = session + 1
			hideChoice()
		elseif event == "UNIT_INVENTORY_CHANGED" then
			if arg1 == "player" then recordLoadedAmmo() end
		else
			recordLoadedAmmo()
			if arg1 == RANGED_SLOT then checkWeaponSwap() end
		end
	end)
end
