-- Huntard: Settings.lua
-- The settings window, opened with /huntard or from WoW's AddOns options.
-- Every control calls the same setter its slash command uses, so clamping
-- rules live in one place. Built from plain widgets (no dropdown or slider
-- templates) because template availability varies between clients.

local H = Huntard
H.Settings = H.Settings or {}

local WIDTH, HEIGHT = 420, 732
local PAD = 20
local SYNC_INTERVAL = 0.5

local ASPECT_CHOICES = {
	{ label = "Any", key = "any" },
	{ label = "Hawk", key = "hawk", name = "Aspect of the Hawk" },
	{ label = "Cheetah", key = "cheetah", name = "Aspect of the Cheetah" },
	{ label = "Pack", key = "pack", name = "Aspect of the Pack" },
	{ label = "Wild", key = "wild", name = "Aspect of the Wild" },
	{ label = "Fox", key = "fox", name = "Aspect of the Fox" },
	{ label = "Beast", key = "beast", name = "Aspect of the Beast" },
	{ label = "Eagle", key = "eagle", name = "Aspect of the Eagle" },
	{ label = "Monkey", key = "monkey", name = "Aspect of the Monkey" },
}

local AMMO_FALLBACK = { 75, 50, 25 }

local frame
local syncers = {}

local function syncAll()
	for _, sync in ipairs(syncers) do sync() end
end

local function makeHeader(parent, y, text)
	local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	header:SetPoint("TOPLEFT", PAD, y)
	header:SetText(text)
end

local function makeSlider(parent, y, text, minValue, maxValue, get, set, describe)
	local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	label:SetPoint("TOPLEFT", PAD, y)
	label:SetText(text)

	local valueText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	valueText:SetPoint("TOPRIGHT", -PAD, y)

	local slider = CreateFrame("Slider", nil, parent)
	slider:SetOrientation("HORIZONTAL")
	slider:SetPoint("TOPLEFT", PAD, y - 18)
	slider:SetPoint("TOPRIGHT", -PAD, y - 18)
	slider:SetHeight(16)
	slider:SetMinMaxValues(minValue, maxValue)
	slider:SetValueStep(1)
	slider:SetObeyStepOnDrag(true)
	slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	slider:EnableMouseWheel(true)

	local track = slider:CreateTexture(nil, "BACKGROUND")
	track:SetPoint("LEFT")
	track:SetPoint("RIGHT")
	track:SetHeight(4)
	track:SetColorTexture(0.4, 0.4, 0.4, 0.9)

	local syncing = false
	local function sync()
		local value = get()
		syncing = true
		slider:SetValue(value)
		syncing = false
		valueText:SetText(describe and describe(value) or (value .. "%"))
	end

	slider:SetScript("OnValueChanged", function(_, value)
		if syncing then return end
		set(math.floor(value + 0.5))
		sync()
	end)
	slider:SetScript("OnMouseWheel", function(self, delta)
		self:SetValue(self:GetValue() + delta)
	end)

	table.insert(syncers, sync)
end

local function makeCheckbox(parent, y, text, get, set)
	local check = CreateFrame("CheckButton", nil, parent)
	check:SetSize(24, 24)
	check:SetPoint("TOPLEFT", PAD, y)
	check:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
	check:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
	check:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
	check:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")

	local label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	label:SetPoint("LEFT", check, "RIGHT", 4, 0)
	label:SetText(text)
	check:SetHitRectInsets(0, -(label:GetStringWidth() + 4), 0, 0)

	check:SetScript("OnClick", function(self)
		set(self:GetChecked() and true or false)
		syncAll()
	end)

	table.insert(syncers, function() check:SetChecked(get()) end)
end

local function makeAspectButtons(parent, y)
	local columns, gap, rowHeight = 3, 6, 26
	local buttonWidth = (WIDTH - PAD * 2 - gap * (columns - 1)) / columns

	for i, choice in ipairs(ASPECT_CHOICES) do
		local column = (i - 1) % columns
		local row = math.floor((i - 1) / columns)
		local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
		button:SetSize(buttonWidth, 22)
		button:SetPoint("TOPLEFT", PAD + column * (buttonWidth + gap), y - row * rowHeight)
		button:SetText(choice.label)
		button:SetScript("OnClick", function()
			H.AspectAlert.SetPreferredAspect(choice.key)
			syncAll()
		end)

		table.insert(syncers, function()
			if H.AspectAlert.GetPreferredAspect() == choice.name then
				button:LockHighlight()
			else
				button:UnlockHighlight()
			end
		end)
	end
end

local function getAmmoThreshold(index)
	return H.db.ammoAlert.thresholds[index] or AMMO_FALLBACK[index]
end

-- Keeps the three thresholds strictly descending while dragging.
local function setAmmoThreshold(index, value)
	local thresholds = { getAmmoThreshold(1), getAmmoThreshold(2), getAmmoThreshold(3) }
	local highest = index > 1 and thresholds[index - 1] - 1 or 99
	local lowest = index < 3 and thresholds[index + 1] + 1 or 1
	thresholds[index] = math.max(lowest, math.min(highest, value))
	H.AmmoAlert.SetThresholds(thresholds)
end

local function describePetThreshold(pct)
	local health = H.PetHealth.GetAlertHealth()
	if health then
		return pct .. "% = " .. health .. " health"
	end
	return pct .. "%"
end

-- The page itself. Built twice -- into the standalone window and into the
-- AddOns options canvas -- and every control registers a syncer, so both
-- copies always show the current settings.
local function buildContent(page)
	makeHeader(page, -46, "Pet Health Alert")
	makeSlider(page, -68, "Alert at", 10, 75,
		function() return H.db.petHealth.threshold end,
		H.PetHealth.SetThreshold,
		describePetThreshold)

	makeHeader(page, -114, "Viper Sting")
	makeSlider(page, -136, "Show icon at or below", 0, 100,
		function() return H.db.viperAlert.lowThreshold end,
		H.ViperAlert.SetLowThreshold)
	makeSlider(page, -178, "Hide icon at or above", 0, 100,
		function() return H.db.viperAlert.highThreshold end,
		H.ViperAlert.SetHighThreshold)

	makeHeader(page, -224, "Ammo Warnings")
	for index, text in ipairs({ "First warning", "Second warning", "Final warning" }) do
		makeSlider(page, -246 - (index - 1) * 42, text, 1, 99,
			function() return getAmmoThreshold(index) end,
			function(value) setAmmoThreshold(index, value) end)
	end

	makeHeader(page, -376, "Ammo Restock")
	makeCheckbox(page, -396, "Refill quiver / ammo pouch at vendors",
		function() return H.db.ammoRestock.enabled end,
		function(checked) H.db.ammoRestock.enabled = checked end)
	makeSlider(page, -426, "Keep this much of it filled", 0, 100,
		function() return H.db.ammoRestock.fillPercent end,
		H.AmmoRestock.SetFillPercent)
	makeSlider(page, -468, "Never spend below", 0, 100,
		function() return H.db.ammoRestock.goldFloor end,
		H.AmmoRestock.SetGoldFloor,
		function(gold) return gold .. " gold" end)

	makeHeader(page, -518, "Preferred Aspect")
	makeAspectButtons(page, -540)
	makeCheckbox(page, -620, "Aspect alert only in combat",
		function() return H.db.aspectAlertRequireCombat end,
		function(checked) H.db.aspectAlertRequireCombat = checked end)

	makeHeader(page, -656, "Layout")
	makeCheckbox(page, -678, "Lock positions",
		function() return H.db.locked end,
		function(checked)
			H.db.locked = checked
			H.RefreshMovables()
		end)

	local reset = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
	reset:SetSize(130, 22)
	reset:SetPoint("TOPRIGHT", -PAD, -679)
	reset:SetText("Reset Positions")
	reset:SetScript("OnClick", H.ResetPositions)
end

-- Re-syncs when shown, and every SYNC_INTERVAL while shown, so the health
-- number and lock state stay current if the pet changes or a slash command
-- is used while the page is open.
local function keepSynced(page)
	page:HookScript("OnShow", syncAll)
	page:HookScript("OnUpdate", function(self, elapsed)
		self.sinceSync = (self.sinceSync or 0) + elapsed
		if self.sinceSync >= SYNC_INTERVAL then
			self.sinceSync = 0
			syncAll()
		end
	end)
end

local function buildWindow()
	frame = CreateFrame("Frame", "HuntardSettingsFrame", UIParent)
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()
	table.insert(UISpecialFrames, "HuntardSettingsFrame") -- Esc closes it

	local bg = frame:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.05, 0.05, 0.97)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetText("Huntard Settings")

	local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	close:SetSize(26, 22)
	close:SetPoint("TOPRIGHT", -8, -8)
	close:SetText("X")
	close:SetScript("OnClick", function() frame:Hide() end)

	buildContent(frame)
	keepSynced(frame)
end

function H.Settings.Show()
	if not frame then buildWindow() end
	frame:Show()
end

function H.Settings.Toggle()
	if frame and frame:IsShown() then
		frame:Hide()
	else
		H.Settings.Show()
	end
end

-- The same page under WoW's Options > AddOns > Huntard. The page is taller
-- than the canvas Blizzard gives it, so it sits in a scroll frame (the same
-- UIPanelScrollFrameTemplate setup Wayfinder's settings use on this client).
-- The standalone window (/huntard) stays the main way in: closing Blizzard's
-- settings panel reopens the game menu, the window doesn't.
function H.Settings.Init()
	if not (_G.Settings and _G.Settings.RegisterCanvasLayoutCategory and _G.Settings.RegisterAddOnCategory) then
		return
	end
	local canvas = CreateFrame("Frame", nil, UIParent)
	canvas:Hide()

	local title = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Huntard")

	local scroll = CreateFrame("ScrollFrame", nil, canvas, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -20)
	scroll:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -27, 0)

	local content = CreateFrame("Frame", nil, scroll)
	content:SetPoint("TOPLEFT")
	content:SetSize(WIDTH, HEIGHT)
	scroll:SetScrollChild(content)

	-- buildContent lays out for the window's width; keep it at that width so
	-- the sliders and buttons look the same in both places.
	buildContent(content)
	keepSynced(canvas)

	pcall(function()
		_G.Settings.RegisterAddOnCategory(_G.Settings.RegisterCanvasLayoutCategory(canvas, "Huntard"))
	end)
end
