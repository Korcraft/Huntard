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

	makeHeader(frame, -46, "Pet Health Alert")
	makeSlider(frame, -68, "Alert at", 10, 75,
		function() return H.db.petHealth.threshold end,
		H.PetHealth.SetThreshold,
		describePetThreshold)

	makeHeader(frame, -114, "Viper Sting")
	makeSlider(frame, -136, "Show icon at or below", 0, 100,
		function() return H.db.viperAlert.lowThreshold end,
		H.ViperAlert.SetLowThreshold)
	makeSlider(frame, -178, "Hide icon at or above", 0, 100,
		function() return H.db.viperAlert.highThreshold end,
		H.ViperAlert.SetHighThreshold)

	makeHeader(frame, -224, "Ammo Warnings")
	for index, text in ipairs({ "First warning", "Second warning", "Final warning" }) do
		makeSlider(frame, -246 - (index - 1) * 42, text, 1, 99,
			function() return getAmmoThreshold(index) end,
			function(value) setAmmoThreshold(index, value) end)
	end

	makeHeader(frame, -376, "Ammo Restock")
	makeCheckbox(frame, -396, "Refill quiver / ammo pouch at vendors",
		function() return H.db.ammoRestock.enabled end,
		function(checked) H.db.ammoRestock.enabled = checked end)
	makeSlider(frame, -426, "Keep this much of it filled", 0, 100,
		function() return H.db.ammoRestock.fillPercent end,
		H.AmmoRestock.SetFillPercent)
	makeSlider(frame, -468, "Never spend below", 0, 100,
		function() return H.db.ammoRestock.goldFloor end,
		H.AmmoRestock.SetGoldFloor,
		function(gold) return gold .. " gold" end)

	makeHeader(frame, -518, "Preferred Aspect")
	makeAspectButtons(frame, -540)
	makeCheckbox(frame, -620, "Aspect alert only in combat",
		function() return H.db.aspectAlertRequireCombat end,
		function(checked) H.db.aspectAlertRequireCombat = checked end)

	makeHeader(frame, -656, "Layout")
	makeCheckbox(frame, -678, "Lock positions",
		function() return H.db.locked end,
		function(checked)
			H.db.locked = checked
			H.RefreshMovables()
		end)

	local reset = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	reset:SetSize(130, 22)
	reset:SetPoint("TOPRIGHT", -PAD, -679)
	reset:SetText("Reset Positions")
	reset:SetScript("OnClick", H.ResetPositions)

	frame:SetScript("OnShow", syncAll)
	-- Keeps the health number and lock state current if the pet changes or a
	-- slash command is used while the window is open.
	frame:SetScript("OnUpdate", function(self, elapsed)
		self.sinceSync = (self.sinceSync or 0) + elapsed
		if self.sinceSync >= SYNC_INTERVAL then
			self.sinceSync = 0
			syncAll()
		end
	end)
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

-- Adds a Huntard entry to WoW's AddOns options with a button to open the window.
function H.Settings.Init()
	local panel = CreateFrame("Frame")
	panel.name = "Huntard"

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Huntard")

	local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	open:SetSize(200, 26)
	open:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
	open:SetText("Open Huntard Settings")
	open:SetScript("OnClick", function()
		if _G.SettingsPanel and _G.SettingsPanel:IsShown() then
			pcall(HideUIPanel, _G.SettingsPanel)
		end
		H.Settings.Show()
	end)

	if _G.Settings and _G.Settings.RegisterCanvasLayoutCategory then
		pcall(function()
			local category = _G.Settings.RegisterCanvasLayoutCategory(panel, "Huntard")
			_G.Settings.RegisterAddOnCategory(category)
		end)
	elseif _G.InterfaceOptions_AddCategory then
		pcall(_G.InterfaceOptions_AddCategory, panel)
	end
end
