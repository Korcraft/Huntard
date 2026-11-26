-- Huntard: WarningText.lua
-- The movable status-text popup. Shows the live zone text, colored to
-- match, for EVERY zone: the live bracket (e.g. "25-35y") for the 3
-- ranged tiers, "DEAD ZONE" / ">35y" for the two problem zones, "MELEE"
-- for melee. No separate hardcoded "RANGE" label anywhere -- it's always
-- whatever Range.lua's own live zone text says.

local H = Huntard
H.WarningText = H.WarningText or {}

local frame, text

local function applyLockState()
	frame:EnableMouse(not H.db.locked)
	frame:EnableMouseWheel(not H.db.locked) -- locked: no resizing, and the wheel zooms the camera again
	frame.bg:SetShown(not H.db.locked)
end

function H.WarningText.Refresh()
	if not frame then return end
	frame:ClearAllPoints()
	frame:SetPoint("CENTER", UIParent, "CENTER", H.db.warningText.x, H.db.warningText.y)
	text:SetFont(text:GetFont(), 32 * H.db.warningText.scale, "OUTLINE")
	applyLockState()
end

local function update()
	if not frame then return end
	local zone, zoneText = H.Range.GetZone()
	if not zone then
		frame:Hide()
		return
	end
	local color = H.Range.GetColor(zone)
	text:SetText(zoneText)
	text:SetTextColor(color[1], color[2], color[3], 1)
	frame:Show()
end

function H.WarningText.Init()
	frame = CreateFrame("Frame", "HuntardWarningText", UIParent)
	frame:SetSize(200, 50)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local x, y = self:GetCenter()
		local ux, uy = UIParent:GetCenter()
		H.db.warningText.x, H.db.warningText.y = x - ux, y - uy
	end)
	frame:EnableMouseWheel(not H.db.locked)
	frame:SetScript("OnMouseWheel", function(_, delta)
		H.db.warningText.scale = math.max(0.4, math.min(3, H.db.warningText.scale + delta * 0.1))
		H.WarningText.Refresh()
	end)

	frame.bg = frame:CreateTexture(nil, "BACKGROUND")
	frame.bg:SetAllPoints()
	frame.bg:SetColorTexture(0, 0, 0, 0.35)

	text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	text:SetAllPoints()
	text:SetJustifyH("CENTER")
	text:SetJustifyV("MIDDLE")

	frame:Hide()
	H.WarningText.Refresh()

	local ticker = CreateFrame("Frame")
	ticker:SetScript("OnUpdate", function(self, elapsed)
		self.t = (self.t or 0) + elapsed
		if self.t > 0.2 then
			self.t = 0
			update()
		end
	end)
end
