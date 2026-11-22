-- Huntard: AlertCluster.lua
-- A single shared anchor point for all the square icon-style alerts
-- (Serpent Sting / Viper / aspect via AlertIcon.lua, and pet health via
-- PetHealth.lua) instead of each owning its own independently-positioned
-- window. You drag ONE point into place; when only one alert is active it
-- appears centered exactly there, and when more than one is active at the
-- same time they fan out symmetrically around that same center point --
-- e.g. two active alerts show side-by-side, straddling the center --
-- rather than stacking in separate spots you'd have to manage individually.
--
-- AlertIcon.lua and PetHealth.lua no longer own any visible frame
-- themselves -- they only expose a GetDisplayStatus() query (what to show
-- right now, as a plain table, or nil) and this file owns every actual
-- visual and the layout math. New icon-style alerts added later just need
-- to be added to the PROVIDERS list below to join the same cluster.

local H = Huntard
H.AlertCluster = H.AlertCluster or {}

local ICON_SIZE = 48
local GAP = 10 -- pixels between adjacent icons at scale 1.0

-- Ordered providers -- this is also the left-to-right order when more than
-- one is active at once. Each returns a display status table or nil:
--   { texture = ... } -- plain icon
--   { texture = ..., countdown = secondsRemaining, cooldownWindow = windowSeconds } -- icon + countdown + swipe
--   { text = "...", textColor = {r,g,b} } -- plain text, no icon
--   { portrait = "unit", slash = true } -- that unit's own 3D portrait, optionally with a red diagonal slash over it
local PROVIDERS = {
	function() return H.AlertIcon and H.AlertIcon.GetDisplayStatus and H.AlertIcon.GetDisplayStatus() end,
	function() return H.PetHealth and H.PetHealth.GetDisplayStatus and H.PetHealth.GetDisplayStatus() end,
}

local anchor
local pool = {} -- reusable slot frames, grown as needed

local function applyLockState()
	anchor:EnableMouse(not H.db.locked)
	anchor.bg:SetShown(not H.db.locked)
end

function H.AlertCluster.Refresh()
	if not anchor then return end
	anchor:ClearAllPoints()
	anchor:SetPoint("CENTER", UIParent, "CENTER", H.db.alertCluster.x, H.db.alertCluster.y)
	local size = ICON_SIZE * H.db.alertCluster.scale
	anchor:SetSize(size, size)
	applyLockState()
end

local function createSlotFrame()
	local f = CreateFrame("Frame", nil, UIParent)
	f:SetFrameStrata("MEDIUM")

	f.bg = f:CreateTexture(nil, "BACKGROUND")
	f.bg:SetAllPoints()
	f.bg:SetColorTexture(0, 0, 0, 0.35)

	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetAllPoints()

	-- Real Blizzard cooldown-swipe widget (CooldownFrameTemplate, confirmed
	-- real via Questie's own TrackerItemButton.lua using this exact
	-- CreateFrame call) -- only driven when a provider supplies a countdown.
	f.cooldownSwipe = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
	f.cooldownSwipe:SetAllPoints(f.icon)
	f.cooldownSwipe:SetHideCountdownNumbers(true) -- Blizzard's own number would double up with our countdown fontstring

	f.countdown = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	f.countdown:SetPoint("BOTTOM", f, "BOTTOM", 0, 2)
	f.countdown:SetTextColor(1, 1, 1, 1)

	f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	f.text:SetAllPoints()
	f.text:SetJustifyH("CENTER")
	f.text:SetJustifyV("MIDDLE")

	-- Diagonal "forbidden" slash drawn as a thin rotated texture, corner to
	-- corner across the icon -- used for e.g. a dead pet's portrait. Plain
	-- color texture + SetRotation (both bog-standard Texture APIs), not a
	-- special "no" icon asset, so it scales cleanly with the slot size.
	f.slash = f:CreateTexture(nil, "OVERLAY", nil, 1)
	f.slash:SetColorTexture(0.85, 0.1, 0.1, 0.95)

	f:Hide()
	return f
end

local function applySlot(f, status, size)
	f:SetSize(size, size)
	f.bg:SetShown(not H.db.locked)

	if status.text then
		f.icon:Hide()
		f.cooldownSwipe:Hide()
		f.countdown:Hide()
		f.slash:Hide()
		local c = status.textColor or { 1, 1, 1 }
		f.text:SetFont(f.text:GetFont(), 20 * H.db.alertCluster.scale, "OUTLINE")
		f.text:SetText(status.text)
		f.text:SetTextColor(c[1], c[2], c[3], 1)
		f.text:Show()
		return
	end

	f.text:Hide()
	f.countdown:Hide()
	f.cooldownSwipe:Hide()

	if status.portrait then
		f.icon:ClearAllPoints()
		f.icon:SetAllPoints()
		f.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9) -- portraits render with a lot of empty margin -- crop in a bit, same trick unit frames use
		pcall(SetPortraitTexture, f.icon, status.portrait)
		f.icon:Show()
	else
		f.icon:ClearAllPoints()
		f.icon:SetAllPoints()
		f.icon:SetTexCoord(0, 1, 0, 1)
		f.icon:SetTexture(status.texture)
		f.icon:Show()
	end

	if status.slash then
		-- Thin rotated bar spanning corner-to-corner (diagonal length =
		-- size * sqrt(2)), pivoting around its own center by default.
		local thickness = math.max(2, size * 0.08)
		f.slash:SetSize(size * 1.42, thickness)
		f.slash:ClearAllPoints()
		f.slash:SetPoint("CENTER", f, "CENTER", 0, 0)
		f.slash:SetRotation(math.rad(45))
		f.slash:Show()
	else
		f.slash:Hide()
	end

	if status.countdown then
		f.countdown:SetFont(f.countdown:GetFont(), 22 * H.db.alertCluster.scale, "OUTLINE")
		f.countdown:SetText(tostring(math.ceil(status.countdown)))
		f.countdown:Show()
		-- startTime derived from `countdown` each call (not set once) so it
		-- stays accurate even if a layout pass gets skipped.
		local startTime = GetTime() - (status.cooldownWindow - status.countdown)
		f.cooldownSwipe:SetCooldown(startTime, status.cooldownWindow)
		f.cooldownSwipe:Show()
	end
end

local function layout()
	local active = {}
	for _, provider in ipairs(PROVIDERS) do
		local ok, status = pcall(provider)
		if ok and status then
			table.insert(active, status)
		end
	end

	local size = ICON_SIZE * H.db.alertCluster.scale
	local gap = GAP * H.db.alertCluster.scale
	local count = #active
	local totalWidth = count * size + math.max(0, count - 1) * gap
	local startX = -totalWidth / 2

	local highWaterMark = math.max(count, #pool)
	for i = 1, highWaterMark do
		local f = pool[i]
		if not f then
			f = createSlotFrame()
			pool[i] = f
		end
		if i <= count then
			f:ClearAllPoints()
			local x = startX + (i - 1) * (size + gap) + size / 2
			f:SetPoint("CENTER", anchor, "CENTER", x, 0)
			applySlot(f, active[i], size)
			f:Show()
		else
			f:Hide()
		end
	end
end

function H.AlertCluster.Init()
	anchor = CreateFrame("Frame", "HuntardAlertAnchor", UIParent)
	anchor:SetSize(ICON_SIZE, ICON_SIZE)
	anchor:SetFrameStrata("MEDIUM")
	anchor:SetClampedToScreen(true)
	anchor:SetMovable(true)
	anchor:RegisterForDrag("LeftButton")
	anchor:SetScript("OnDragStart", function(self) self:StartMoving() end)
	anchor:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local x, y = self:GetCenter()
		local ux, uy = UIParent:GetCenter()
		H.db.alertCluster.x, H.db.alertCluster.y = x - ux, y - uy
	end)
	anchor:EnableMouseWheel(true)
	anchor:SetScript("OnMouseWheel", function(_, delta)
		H.db.alertCluster.scale = math.max(0.4, math.min(3, H.db.alertCluster.scale + delta * 0.1))
		H.AlertCluster.Refresh()
	end)

	anchor.bg = anchor:CreateTexture(nil, "BACKGROUND")
	anchor.bg:SetAllPoints()
	anchor.bg:SetColorTexture(0, 0, 0, 0.35) -- same as a real alert slot's background, so this previews exactly what one alert will look like

	H.AlertCluster.Refresh()

	local ticker = CreateFrame("Frame")
	ticker:SetScript("OnUpdate", function(self, elapsed)
		self.t = (self.t or 0) + elapsed
		if self.t > 0.1 then -- matches the old AlertIcon.lua cadence, fast enough for the Serpent Sting countdown
			self.t = 0
			layout()
		end
	end)
end
