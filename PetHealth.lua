-- Huntard: PetHealth.lua
-- No longer owns a frame of its own -- see AlertCluster.lua, which draws
-- and positions every icon-style alert (this one, plus AlertIcon.lua)
-- relative to one shared, player-placed anchor point instead of each
-- having its own independently-positioned window.
--
-- Reports nothing while you have no pet out. Reports Mend Pet's own spell
-- icon (no text/number, just the icon) once health drops to/below the
-- configured threshold -- a glance at the icon tells you exactly what to
-- cast, same idea as the aspect alert using each aspect's own icon rather
-- than a generic warning symbol. Reports the pet's own portrait with a red
-- diagonal slash across it if it's dead (SetPortraitTexture -- the same
-- standard API every default unit frame uses to render a unit's 3D
-- portrait, not secret/restricted information).
--
-- REAL FIX for a real restriction, not a workaround for a guess:
-- UnitHealth("pet") (and UnitHealth("player")) come back as the "secret"
-- Lua value type on this client -- confirmed live via a crash ("attempt to
-- perform arithmetic on a secret number value"), and confirmed it's NOT
-- combat-tied (reproduced solo, out of combat, no instance) -- unlike
-- everything else "secret" in this addon so far. Grepped Details' own
-- source for how it handles this on this exact client (it has a whole
-- separate unitframe_midnight.lua implementation, used instead of its
-- normal one whenever DetailsFramework.IsMidnightWowAPI() is true -- which
-- it is here, since Forever's build number falls in that checked range)
-- and confirmed via TellMeWhen's LibDogTag-Unit-3.0/Categories/Health.lua
-- (which explicitly branches on `C_Secrets.HasSecretRestrictions()`):
-- Blizzard ships a DEDICATED replacement API for exactly this --
-- UnitHealthPercent(unit, useAbsorbs, curveConstant) -- that returns an
-- already-computed percentage without ever exposing the raw secret
-- number. This is the intended, official fix, not a trick -- the
-- "CurveConstants" table (confirmed via grep as a real global, not
-- something to require) controls the output scale; CurveConstants.ScaleTo100
-- gives a plain 0-100 number, matching the exact call shape both TellMeWhen
-- and Details use (`UnitHealthPercent(unit, true, CurveConstants.ScaleTo100)`).

local H = Huntard
H.PetHealth = H.PetHealth or {}

local MIN_THRESHOLD, MAX_THRESHOLD = 10, 75
local MEND_PET_NAME = "Mend Pet"

local mendPetIcon

-- GetSpellInfo -- NOT an aura read, confirmed unaffected by the secrecy
-- restriction (see AspectAlert.lua/SerpentSting.lua headers) -- used once
-- to fetch Mend Pet's own icon for display.
local function getSpellInfoCompat(identifier)
	if _G.GetSpellInfo then
		return _G.GetSpellInfo(identifier)
	end
	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(identifier)
		if info then return info.name, nil, info.iconID end
	end
	return nil
end

local hasSecretRestrictions = C_Secrets and C_Secrets.HasSecretRestrictions and C_Secrets.HasSecretRestrictions()

-- Live test (/huntard pethealthdebug) confirmed UnitHealthPercent itself
-- -- the API this file's own header called "the intended, official fix" --
-- STILL comes back as a secret value for pet and player alike, consistently,
-- both in and out of combat. Not a guess: pcall ok=true, result secret=true,
-- every time tested. Details' own client-specific code (unitframe_midnight.lua)
-- has a commented-out line showing it tried that exact same plain call first
-- (`--self.currentHealthPercent = UnitHealthPercent(unit, true, CurveConstants.ScaleTo100)`)
-- and abandoned it for a different, real API: a heal-prediction "calculator"
-- object (CreateUnitHealPredictionCalculator() + UnitGetDetailedHealPrediction()),
-- whose :EvaluateCurrentHealthPercent() is what Details actually ships live
-- today. Tried here as a second path, ahead of the plain call, guarded the
-- same way -- not yet confirmed non-secret on OUR end, hence still wrapped
-- and checked rather than trusted outright.
local healCalculators = {} -- [unit] = calculator object, created once and reused (same as Details does per-frame)
local function getCalculatorFor(unit)
	if not (_G.CreateUnitHealPredictionCalculator) then return nil end
	if not healCalculators[unit] then
		local ok, calc = pcall(_G.CreateUnitHealPredictionCalculator)
		if ok then healCalculators[unit] = calc end
	end
	return healCalculators[unit]
end

local function getHealthPercentViaCalculator(unit)
	if not _G.UnitGetDetailedHealPrediction then return nil end
	local calculator = getCalculatorFor(unit)
	if not calculator then return nil end

	local okPredict = pcall(_G.UnitGetDetailedHealPrediction, unit, nil, calculator)
	if not okPredict then return nil end

	if Enum and Enum.UnitMaximumHealthMode and calculator.SetMaximumHealthMode then
		pcall(calculator.SetMaximumHealthMode, calculator, Enum.UnitMaximumHealthMode.Default)
	end

	local okPct, pct = pcall(calculator.EvaluateCurrentHealthPercent, calculator, CurveConstants and CurveConstants.ScaleTo100)
	if okPct and pct and not (_G.issecretvalue and _G.issecretvalue(pct)) then
		return pct
	end
	return nil
end

-- Returns a 0-100 health percent for `unit`, or nil if it genuinely can't
-- be determined right now. Tries the heal-prediction calculator first (see
-- above), then plain UnitHealthPercent, then falls back to raw
-- UnitHealth/UnitHealthMax division (older clients without any of this).
local function getHealthPercent(unit)
	local viaCalculator = getHealthPercentViaCalculator(unit)
	if viaCalculator then return viaCalculator end

	if hasSecretRestrictions and _G.UnitHealthPercent then
		local ok, pct = pcall(_G.UnitHealthPercent, unit, true, CurveConstants and CurveConstants.ScaleTo100)
		if ok and pct and not (_G.issecretvalue and _G.issecretvalue(pct)) then
			return pct
		end
		return nil
	end

	local maxHealth, health = UnitHealthMax(unit), UnitHealth(unit)
	if not maxHealth or maxHealth <= 0 or not health then return nil end
	if _G.issecretvalue and (_G.issecretvalue(maxHealth) or _G.issecretvalue(health)) then return nil end
	return (health / maxHealth) * 100
end

function H.PetHealth.SetThreshold(pct)
	pct = math.max(MIN_THRESHOLD, math.min(MAX_THRESHOLD, math.floor(pct)))
	H.db.petHealth.threshold = pct
	return pct
end

-- ---------------------------------------------------------------------------
-- THRESHOLD DETECTION -- drives the real Mend Pet alert. No text/number is
-- ever displayed anywhere (explicitly not wanted) -- this exists purely to
-- answer one boolean question: is the pet's health currently at/below the
-- configured threshold?
--
-- REAL MECHANISM, confirmed live via /huntard pethealthtexttest and
-- pethealthbartest while the pet was actually taking damage, not guessed:
-- a secret health VALUE cannot be used in Lua logic at all -- arithmetic,
-- relational comparison ("attempt to compare a secret number value"), and
-- naive tostring/concat all confirmed to error out. But handing that SAME
-- secret value straight into a native StatusBar's SetValue() works -- the
-- bar visibly fills/drains correctly, exactly like Details' own
-- client-specific code does (passes the secret value straight to
-- self:SetValue() without ever reading it back).
--
-- The trick: instead of measuring health as a percentage of MAX health (0 to
-- maxHealth, always secret-derived), set the bar's range to [0, thresholdHP]
-- -- thresholdHP = maxHealth * threshold/100, computed from maxHealth (NOT
-- secret) and our own setting (NOT secret), so that arithmetic is fine. Then
-- SetValue(currentHealth) -- a StatusBar visually CLAMPS any value at/above
-- its max to render fully filled. So the fill texture renders at FULL WIDTH
-- whenever health is at/above the threshold, and at a SMALLER width whenever
-- it's genuinely below. That rendered WIDTH is a layout/geometry output, not
-- the protected data value -- comparing it against the bar's own (plain,
-- known) total width is the boolean decision, and it never touches the
-- secret health number with a comparison.
local measureBar

local function getMeasureBar()
	if measureBar then return measureBar end
	measureBar = CreateFrame("StatusBar", "HuntardPetHealthMeasureBar", UIParent)
	measureBar:SetSize(200, 10)
	-- Positioned far off-screen, not hidden -- a Hide()'d frame may skip
	-- layout/texture-size updates entirely, which would make GetWidth()
	-- stale or unreliable. Shown-but-off-screen keeps real layout math
	-- running while staying invisible to you.
	measureBar:SetPoint("CENTER", UIParent, "CENTER", 0, -10000)
	measureBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	measureBar:Show()
	return measureBar
end

-- Returns true/false, or nil if it genuinely can't be determined right now
-- (fails safe to "don't alert" rather than guessing) -- never touches
-- UnitHealth("pet") with arithmetic or comparison, only the proven-safe
-- pass-through into SetMinMaxValues/SetValue, then a comparison on the
-- RENDERED WIDTH (a plain geometry number).
local function isPetBelowThreshold()
	local maxHealth = UnitHealthMax("pet")
	if not maxHealth or type(maxHealth) ~= "number" or maxHealth <= 0 then return nil end
	if _G.issecretvalue and _G.issecretvalue(maxHealth) then return nil end

	local thresholdValue = maxHealth * (H.db.petHealth.threshold / 100)
	local bar = getMeasureBar()

	local okMinMax = pcall(bar.SetMinMaxValues, bar, 0, thresholdValue)
	local okValue = pcall(bar.SetValue, bar, UnitHealth("pet"))
	if not (okMinMax and okValue) then return nil end

	local okTex, tex = pcall(bar.GetStatusBarTexture, bar)
	if not (okTex and tex) then return nil end

	local okFillWidth, fillWidth = pcall(tex.GetWidth, tex)
	if not okFillWidth or type(fillWidth) ~= "number" then return nil end
	if _G.issecretvalue and _G.issecretvalue(fillWidth) then return nil end

	local okBarWidth, barWidth = pcall(bar.GetWidth, bar)
	if not okBarWidth or type(barWidth) ~= "number" then return nil end

	-- Full width (within a small margin for float rounding) means health is
	-- at/above the threshold (SetValue clamped the fill); meaningfully less
	-- means it's genuinely below.
	local okCompare, below = pcall(function() return fillWidth < (barWidth - 0.5) end)
	if not okCompare then return nil end
	return below
end

-- /huntard calls into this to show a live reading alongside the configured
-- threshold, since the threshold alone doesn't tell you whether you're
-- actually currently under/over it -- out-of-combat pet regen is fast
-- enough that it's easy to check a moment too late and see nothing.
function H.PetHealth.GetLiveReadout()
	if not UnitExists("pet") then return "no pet out" end
	if UnitIsDeadOrGhost("pet") then return "pet is dead" end
	local pct = getHealthPercent("pet")
	if not pct then return "unreadable right now" end
	return string.format("%d%%", pct)
end

-- /huntard pethealthdebug -- dumps exactly what's readable/secret about
-- pet health right now, and confirms which path (UnitHealthPercent vs
-- plain division) is actually in use on this client.
function H.PetHealth.Debug()
	local lines = {}
	local function add(s) table.insert(lines, s) end

	add("pet exists: " .. tostring(UnitExists("pet")))
	add("pet dead/ghost: " .. tostring(UnitIsDeadOrGhost("pet")))
	add("player in combat (UnitAffectingCombat): " .. tostring(UnitAffectingCombat("player")))
	add("")
	add("C_Secrets.HasSecretRestrictions(): " .. tostring(hasSecretRestrictions))
	add("_G.UnitHealthPercent exists: " .. tostring(_G.UnitHealthPercent ~= nil))
	add("_G.CurveConstants exists: " .. tostring(_G.CurveConstants ~= nil))
	add("_G.CurveConstants.ScaleTo100: " .. tostring(_G.CurveConstants and _G.CurveConstants.ScaleTo100))
	add("")

	local function checkUnit(unit)
		if not UnitExists(unit) then
			add(unit .. ": doesn't exist")
			return
		end
		local h, m = UnitHealth(unit), UnitHealthMax(unit)
		add(string.format("%s: UnitHealth secret=%s  UnitHealthMax secret=%s  getHealthPercent()=%s",
			unit, tostring(_G.issecretvalue and _G.issecretvalue(h)),
			tostring(_G.issecretvalue and _G.issecretvalue(m)),
			tostring(getHealthPercent(unit))))

		-- Granular breakdown of the UnitHealthPercent call itself, since
		-- getHealthPercent() alone collapses "pcall errored", "returned nil",
		-- and "returned a secret value" all down to the same plain nil --
		-- not enough to tell apart WHY it failed.
		if hasSecretRestrictions and _G.UnitHealthPercent then
			local ok, pct = pcall(_G.UnitHealthPercent, unit, true, CurveConstants and CurveConstants.ScaleTo100)
			-- tostring() on a secret value returns ANOTHER secret (tainted)
			-- value, not a normal string -- confirmed via a real crash here
			-- (table.concat choking on it downstream). pct must be checked
			-- with issecretvalue() BEFORE it ever touches tostring, same
			-- lesson as the UNIT_AURA guard in AspectAlert.lua.
			local isSecret = ok and _G.issecretvalue and _G.issecretvalue(pct)
			local resultText
			if not ok then
				resultText = tostring(pct) -- pct is a plain error-message string when ok == false, safe to tostring
			elseif isSecret then
				resultText = "<secret>"
			else
				resultText = tostring(pct)
			end
			add(string.format("  UnitHealthPercent(%s, true, ScaleTo100): pcall ok=%s  raw result=%s  result secret=%s",
				unit, tostring(ok), resultText, tostring(isSecret)))
		end

		-- Same granular breakdown for the heal-prediction calculator path
		-- (see its own comment above getHealthPercentViaCalculator) -- this
		-- is the thing actually being tested here: does Details' own
		-- confirmed-working alternative also work for us, unlike the plain
		-- UnitHealthPercent call above.
		if _G.UnitGetDetailedHealPrediction and _G.CreateUnitHealPredictionCalculator then
			local calculator = getCalculatorFor(unit)
			local okPredict = calculator and pcall(_G.UnitGetDetailedHealPrediction, unit, nil, calculator)
			local okPct, pct = false, nil
			if okPredict then
				if Enum and Enum.UnitMaximumHealthMode and calculator.SetMaximumHealthMode then
					pcall(calculator.SetMaximumHealthMode, calculator, Enum.UnitMaximumHealthMode.Default)
				end
				okPct, pct = pcall(calculator.EvaluateCurrentHealthPercent, calculator, CurveConstants and CurveConstants.ScaleTo100)
			end
			local calcIsSecret = okPct and _G.issecretvalue and _G.issecretvalue(pct)
			local calcResultText
			if not okPredict then
				calcResultText = "UnitGetDetailedHealPrediction failed"
			elseif not okPct then
				calcResultText = tostring(pct) -- error message, safe to tostring
			elseif calcIsSecret then
				calcResultText = "<secret>"
			else
				calcResultText = tostring(pct)
			end
			add(string.format("  calculator:EvaluateCurrentHealthPercent(%s): predict ok=%s  pcall ok=%s  raw result=%s  result secret=%s",
				unit, tostring(okPredict), tostring(okPct), calcResultText, tostring(calcIsSecret)))
		end

		-- Different kind of test from everything above: not trying to READ
		-- the number at all, just asking a relational question of it
		-- directly ("is current health below half of max") and seeing
		-- whether THAT'S permitted even though extracting the exact value
		-- isn't. The comparison result itself still gets issecretvalue()
		-- checked before tostring -- a secret boolean could be just as real
		-- as a secret number, and crash the exact same way if assumed safe.
		do
			local okCompare, belowHalf = pcall(function()
				return UnitHealth(unit) < (UnitHealthMax(unit) * 0.5)
			end)
			local compareIsSecret = okCompare and _G.issecretvalue and _G.issecretvalue(belowHalf)
			local compareText
			if not okCompare then
				compareText = "comparison itself errored: " .. tostring(belowHalf)
			elseif compareIsSecret then
				compareText = "<secret boolean>"
			else
				compareText = tostring(belowHalf)
			end
			add(string.format("  UnitHealth(%s) < UnitHealthMax(%s)*0.5: pcall ok=%s  result=%s  result secret=%s",
				unit, unit, tostring(okCompare), compareText, tostring(compareIsSecret)))
		end
	end
	checkUnit("pet")
	checkUnit("player")
	-- Testing whether this restriction is specific to YOUR OWN health
	-- (player+pet) or applies to every unit -- a healing addon reading party
	-- members' health would be a completely different code path if so.
	checkUnit("party1")
	checkUnit("party2")
	checkUnit("party3")
	checkUnit("party4")

	H.ShowCopyableText("Huntard pet health debug", table.concat(lines, "\n"))
end

-- ---------------------------------------------------------------------------
-- LOW HEALTH ICON -- appears when the pet's health is at or below the alert
-- number: its max health times the configured threshold percent.
--
-- Health is a secret value, so Lua can never ask "is it <= the alert number?".
-- The native StatusBar answers instead: with a range of [alert, alert + 1],
-- its fill is empty at the alert number or less and full above it. The icon
-- lives in a clipping frame spanning from the fill's right edge to the bar's
-- right edge -- the UNFILLED part -- so it is fully revealed at the alert
-- number or less and zero-width otherwise.
-- Lua only passes the value through; it never reads or compares it, which
-- also means nothing here can react to the alert (no sound, for example).
-- ---------------------------------------------------------------------------

local ALERT_TEST_SECONDS = 5
local MEND_PET_SPELL_ID = 136 -- rank 1; fallback if the name lookup fails

-- alertShifter is an invisible second gate with the same range and value. Its
-- fill is full above the alert number and empty at or below it, so another
-- icon anchored to the fill's right edge slides aside natively only while the
-- Mend Pet icon is revealed. See AlertCluster's layout().
local alertFrame, alertGate, alertShifter, alertTestUntil
local gateHealth = 0 -- the alert number the gate's range is currently set to

function H.PetHealth.TestAlert()
	alertTestUntil = GetTime() + ALERT_TEST_SECONDS
end

-- The health number the alert triggers at, or nil if max health is unavailable.
function H.PetHealth.GetAlertHealth()
	if not UnitExists("pet") then return nil end
	local maxHealth = UnitHealthMax("pet")
	if _G.issecretvalue and _G.issecretvalue(maxHealth) then return nil end
	if type(maxHealth) ~= "number" or maxHealth <= 0 then return nil end
	return math.floor(maxHealth * H.db.petHealth.threshold / 100)
end

local function setGateHealth(health)
	if health ~= gateHealth then
		gateHealth = health
		alertGate:SetMinMaxValues(health, health + 1)
		alertShifter:SetMinMaxValues(health, health + 1)
	end
end

-- May receive a secret value: both setters only pass it through to the widget.
local function setGateValue(value)
	alertGate:SetValue(value)
	alertShifter:SetValue(value)
end

local function hideAlert()
	setGateValue(gateHealth + 1)
	alertFrame:Hide()
end

function H.PetHealth.GetLayoutShifter()
	return alertShifter
end

-- A dead pet stops existing as a unit once you die and res, so "no pet unit"
-- can't be read as "nothing wrong". Remembered per character (surviving a
-- reload or relog) and cleared only when a living pet is actually seen.
local REVIVE_PET_NAME = "Revive Pet"
local REVIVE_PET_SPELL_ID = 982
local revivePetIcon

local function characterKey()
	local guid = UnitGUID("player")
	if _G.issecretvalue and _G.issecretvalue(guid) then return nil end
	return guid
end

local function isPetRememberedDead()
	local key = characterKey()
	return key and H.db.petDeadByCharacter and H.db.petDeadByCharacter[key] or false
end

local function rememberPetDead(isDead)
	local key = characterKey()
	if not key then return end
	if isDead then
		H.db.petDeadByCharacter = H.db.petDeadByCharacter or {}
		H.db.petDeadByCharacter[key] = true
	elseif H.db.petDeadByCharacter then
		H.db.petDeadByCharacter[key] = nil
	end
end

-- A living pet that simply isn't out. Uses the same gate as the Cheetah/Pack
-- warning: a living attackable target, plus the optional combat-only setting.
local CALL_PET_SPELL_ID = 883
local CALL_PET_FALLBACK_ICON = "Interface\\Icons\\Ability_Hunter_BeastCall"
local PET_RETURN_GRACE = 2 -- seconds for a pet to reappear after zoning or dismounting
local callPetIcon
local petGoneSince

local function knowsCallPet()
	if C_SpellBook and C_SpellBook.IsSpellKnown and C_SpellBook.IsSpellKnown(CALL_PET_SPELL_ID) then
		return true
	end
	return _G.IsPlayerSpell and _G.IsPlayerSpell(CALL_PET_SPELL_ID) or false
end

-- The game removes the pet by itself during these and brings it back after.
local function petTemporarilyAway()
	return UnitIsDeadOrGhost("player") or IsMounted() or UnitOnTaxi("player")
		or (_G.UnitInVehicle and _G.UnitInVehicle("player"))
end

local function shouldWarnPetMissing()
	if petTemporarilyAway() then
		petGoneSince = nil
		return false
	end
	local now = GetTime()
	petGoneSince = petGoneSince or now
	if now - petGoneSince < PET_RETURN_GRACE then return false end
	if not H.Range.HasFightableTarget() then return false end
	if H.db.aspectAlertRequireCombat and not UnitAffectingCombat("player") then return false end
	return knowsCallPet()
end

-- Returns a display status table for AlertCluster, or nil if nothing to show:
--   { portrait = "pet", slash = true } -- dead pet, unit still available
--   { texture = revivePetIcon, slash = true } -- dead pet, unit gone (you died and rezzed)
--   { texture = callPetIcon } -- pet not summoned, with an attackable target
--   { overlay = alertFrame } -- living pet. Lua can't know whether the icon is
--   currently revealed, so a living pet always holds its cluster slot.
function H.PetHealth.GetDisplayStatus()
	if not alertFrame then return nil end

	if alertTestUntil and GetTime() < alertTestUntil then
		setGateValue(gateHealth)
		alertFrame:Show()
		return { overlay = alertFrame }
	end
	alertTestUntil = nil

	if not UnitExists("pet") then
		hideAlert()
		if isPetRememberedDead() then
			return { texture = revivePetIcon, slash = true }
		end
		if shouldWarnPetMissing() then
			return { texture = callPetIcon }
		end
		return nil
	end
	petGoneSince = nil

	if UnitIsDeadOrGhost("pet") then
		rememberPetDead(true)
		hideAlert()
		return { portrait = "pet", slash = true }
	end
	rememberPetDead(false)

	local alertHealth = H.PetHealth.GetAlertHealth()
	if not alertHealth then
		hideAlert()
		return nil
	end
	setGateHealth(alertHealth)

	if not pcall(setGateValue, UnitHealth("pet")) then
		hideAlert()
		return nil
	end
	alertFrame:Show()
	return { overlay = alertFrame }
end

-- ---------------------------------------------------------------------------
-- FEED PET -- icon whenever a living pet is below fully happy. Happiness is
-- expected as 1 (unhappy), 2 (content) or 3 (happy). The API exists on this
-- client, but its values are unconfirmed, so a failed or secret read shows
-- nothing (/huntard happinessdebug reports which). Separate slot from pet health.
-- ---------------------------------------------------------------------------
local FEED_PET_SPELL_ID = 6991
local FEED_PET_FALLBACK_ICON = "Interface\\Icons\\Ability_Hunter_BeastTraining"
local FULLY_HAPPY = 3
local feedPetIcon

local function readHappiness()
	-- Forever keeps this under C_PetInfo; the old global doesn't exist here.
	local getHappiness = (_G.C_PetInfo and _G.C_PetInfo.GetPetHappiness) or _G.GetPetHappiness
	if not getHappiness then return nil, "API missing" end
	local ok, happiness = pcall(getHappiness)
	if not ok then return nil, "read failed" end
	if _G.issecretvalue and _G.issecretvalue(happiness) then return nil, "BLOCKED (secret)" end
	if type(happiness) ~= "number" then return nil, "returned " .. type(happiness) end
	return happiness
end

-- You can't feed a pet in combat, so happiness isn't checked during combat or
-- for a short time after it ends.
local FEED_COMBAT_COOLDOWN = 10
local lastInCombatAt

function H.PetHealth.GetHappinessStatus()
	local now = GetTime()
	if UnitAffectingCombat("player") then
		lastInCombatAt = now
		return nil
	end
	if lastInCombatAt and now - lastInCombatAt < FEED_COMBAT_COOLDOWN then return nil end

	if not UnitExists("pet") or UnitIsDeadOrGhost("pet") then return nil end
	local happiness = readHappiness()
	if happiness and happiness < FULLY_HAPPY then
		-- Clicking opens the food tray under the icon (see FeedTray.lua).
		local trayOpen = H.FeedTray and H.FeedTray.IsOpen and H.FeedTray.IsOpen()
		return {
			texture = feedPetIcon or FEED_PET_FALLBACK_ICON,
			feedTray = true,
			onClick = H.FeedTray and H.FeedTray.Toggle,
			tooltip = trayOpen and "Feed Pet\nClick to close the food tray"
				or "Feed Pet\nClick to choose a food",
		}
	end
	return nil
end

-- /huntard happinessdebug -- run with your pet out, in and out of combat.
-- Reports the happiness read, plus every other place it could be exposed.
function H.PetHealth.DebugHappiness()
	local lines = {}
	local function add(s) lines[#lines + 1] = s end
	local function safe(value)
		if _G.issecretvalue and _G.issecretvalue(value) then return "<secret>" end
		return tostring(value)
	end

	local happiness, problem = readHappiness()
	add("pet out: " .. tostring(UnitExists("pet") and true or false)
		.. "  in combat: " .. tostring(UnitAffectingCombat("player") and true or false))
	add("C_PetInfo.GetPetHappiness: " .. (happiness and ("READABLE (" .. happiness .. " of 3)") or ("NOT READABLE: " .. problem)))

	add("")
	add("-- global names containing happi / loyal --")
	local names = {}
	for name in pairs(_G) do
		if type(name) == "string" then
			local lower = name:lower()
			if lower:find("happi", 1, true) or lower:find("loyal", 1, true) then
				names[#names + 1] = name
			end
		end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		add(name .. " (" .. type(_G[name]) .. ")")
	end
	if #names == 0 then add("none") end

	add("")
	add("-- C_PetInfo functions --")
	if _G.C_PetInfo then
		local fns = {}
		for name in pairs(_G.C_PetInfo) do fns[#fns + 1] = tostring(name) end
		table.sort(fns)
		add(table.concat(fns, ", "))
	else
		add("C_PetInfo missing")
	end

	add("")
	add("-- pet power types with a value --")
	if Enum and Enum.PowerType then
		local powerNames = {}
		for name in pairs(Enum.PowerType) do powerNames[#powerNames + 1] = name end
		table.sort(powerNames)
		for _, name in ipairs(powerNames) do
			local id = Enum.PowerType[name]
			local okCur, cur = pcall(UnitPower, "pet", id)
			local okMax, max = pcall(UnitPowerMax, "pet", id)
			if okCur and okMax then
				local maxSecret = _G.issecretvalue and _G.issecretvalue(max)
				if maxSecret or (type(max) == "number" and max > 0) then
					add(string.format("%s (%s): %s / %s", name, tostring(id), safe(cur), safe(max)))
				end
			end
		end
	end

	add("")
	add("-- pet frame happiness widgets --")
	for _, frameName in ipairs({ "PetFrameHappiness", "PetFrameHappinessTexture", "PetPaperDollPetInfo" }) do
		local widget = _G[frameName]
		if widget then
			local okShown, shown = pcall(widget.IsShown, widget)
			local coords = ""
			if widget.GetTexCoord then
				local coordValues = { pcall(widget.GetTexCoord, widget) }
				if coordValues[1] then
					local parts = {}
					for i = 2, #coordValues do parts[#parts + 1] = safe(coordValues[i]) end
					coords = "  texcoords: " .. table.concat(parts, ", ")
				end
			end
			add(frameName .. ": shown=" .. (okShown and safe(shown) or "error") .. coords)
		else
			add(frameName .. ": missing")
		end
	end

	add("")
	add("-- pet buffs --")
	local foundBuff = false
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		for i = 1, 40 do
			local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "pet", i, "HELPFUL")
			if not ok then break end
			if _G.issecretvalue and _G.issecretvalue(aura) then
				add("buff " .. i .. ": <secret>")
				foundBuff = true
			elseif not aura then
				break
			else
				add("buff " .. i .. ": " .. safe(aura.name) .. "  spellId=" .. safe(aura.spellId) .. "  icon=" .. safe(aura.icon))
				foundBuff = true
			end
		end
	end
	if not foundBuff then add("none") end

	H.ShowCopyableText("Huntard pet happiness search", table.concat(lines, "\n"))
end

local function initAlertDisplay()
	alertFrame = CreateFrame("Frame", "HuntardPetHealthAlert", UIParent)
	alertFrame:SetSize(48, 48)
	alertFrame:SetFrameStrata("MEDIUM")
	alertFrame:SetFrameLevel(20)

	alertGate = CreateFrame("StatusBar", nil, alertFrame)
	alertGate:SetAllPoints()
	alertGate:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	alertGate:SetStatusBarColor(0, 0, 0, 0)
	alertGate:SetMinMaxValues(gateHealth, gateHealth + 1)
	alertGate:SetValue(gateHealth + 1)

	-- Stays shown (fully transparent) so its fill keeps updating its layout.
	alertShifter = CreateFrame("StatusBar", nil, UIParent)
	alertShifter:SetSize(1, 1)
	alertShifter:SetPoint("CENTER", UIParent, "CENTER")
	alertShifter:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	alertShifter:SetStatusBarColor(0, 0, 0, 0)
	alertShifter:SetMinMaxValues(gateHealth, gateHealth + 1)
	alertShifter:SetValue(gateHealth + 1)

	local reveal = CreateFrame("Frame", nil, alertGate)
	reveal:SetClipsChildren(true)
	reveal:SetPoint("TOPLEFT", alertGate:GetStatusBarTexture(), "TOPRIGHT")
	reveal:SetPoint("BOTTOMRIGHT", alertGate, "BOTTOMRIGHT")

	local content = CreateFrame("Frame", nil, reveal)
	content:SetAllPoints(alertFrame)

	local icon = content:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexture(mendPetIcon)

	alertFrame:Hide()
end

function H.PetHealth.Init()
	local _, _, icon = getSpellInfoCompat(MEND_PET_NAME)
	if not icon then
		_, _, icon = getSpellInfoCompat(MEND_PET_SPELL_ID)
	end
	mendPetIcon = icon

	local _, _, reviveIcon = getSpellInfoCompat(REVIVE_PET_NAME)
	if not reviveIcon then
		_, _, reviveIcon = getSpellInfoCompat(REVIVE_PET_SPELL_ID)
	end
	revivePetIcon = reviveIcon

	local _, _, callIcon = getSpellInfoCompat(CALL_PET_SPELL_ID)
	callPetIcon = callIcon or CALL_PET_FALLBACK_ICON

	local _, _, feedIcon = getSpellInfoCompat(FEED_PET_SPELL_ID)
	feedPetIcon = feedIcon

	initAlertDisplay()
end
