-- Huntard: AlertIcon.lua
-- No longer owns a frame of its own -- see AlertCluster.lua, which draws
-- and positions every icon-style alert (this one, plus PetHealth.lua)
-- relative to one shared, player-placed anchor point instead of each
-- having its own independently-positioned window.
--
-- This file decides WHAT the two non-pet cluster slots show right now:
--   Sting slot:
--     1. A sting (Serpent, Viper or Scorpid) about to fall off your target (SerpentSting.lua) --
--        its icon plus a numeric countdown.
--     2. Otherwise the Viper Sting low-mana icon (ViperAlert.lua), which
--        returns as soon as the countdown ends if mana is still low.
--   Aspect slot (AspectAlert.lua) -- one state at a time: the "NO ASPECT"
--   icon, the travel aspect's own icon (Cheetah/Pack), or the generic
--   "ASPECT" icon if a different aspect than your preferred one is live.

local H = Huntard
H.AlertIcon = H.AlertIcon or {}

local NO_ASPECT_TEXTURE = "Interface/AddOns/Huntard/Textures/NoAspect.png"
local ASPECT_WARNING_TEXTURE = "Interface/AddOns/Huntard/Textures/Aspect.png"

-- Returns a display status table, or nil if nothing to show:
--   { texture = ..., countdown = secondsRemaining, cooldownWindow = windowSeconds }
--   { texture = ... } -- Viper Sting low-mana icon
function H.AlertIcon.GetStingStatus()
	-- Read first so the mana warning keeps updating during a countdown.
	local viperStatus, viperIcon = H.ViperAlert.GetStatus()

	local ssActive, ssIcon, ssRemaining = H.SerpentSting.GetStatus()
	if ssActive then
		return { texture = ssIcon, countdown = ssRemaining, cooldownWindow = H.SerpentSting.GetWindow() }
	end
	if viperStatus then
		return { texture = viperIcon }
	end
	return nil
end

-- Returns { texture = ... }, or nil if nothing to show.
function H.AlertIcon.GetAspectStatus()
	local aspectStatus, aspectIcon = H.AspectAlert.GetStatus()
	if not aspectStatus then return nil end
	if aspectStatus == "travel" then
		return { texture = aspectIcon }
	elseif aspectStatus == "wrong" then
		return { texture = ASPECT_WARNING_TEXTURE }
	end
	return { texture = NO_ASPECT_TEXTURE } -- "none"
end
