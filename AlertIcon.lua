-- Huntard: AlertIcon.lua
-- No longer owns a frame of its own -- see AlertCluster.lua, which draws
-- and positions every icon-style alert (this one, plus PetHealth.lua)
-- relative to one shared, player-placed anchor point instead of each
-- having its own independently-positioned window.
--
-- This file just decides WHAT should show right now, in priority order
-- (shouldn't really overlap in practice -- you're not usually
-- Cheetah-sprinting with a live Serpent Sting target -- but a clear order
-- beats an undefined one):
--   1. Serpent Sting about to fall off your target (SerpentSting.lua) --
--      its icon plus a numeric countdown, since this is the most
--      time-critical, mid-combat thing this reports.
--   2. Viper mana-threshold suggestion (ViperAlert.lua) -- switch to or
--      from Aspect of the Viper based on mana. Takes priority over the
--      aspect warning below since, if no combat aspect is confirmed AND
--      mana is low, telling you WHICH aspect to put on is strictly more
--      useful than a generic aspect icon.
--   3. Aspect warning (AspectAlert.lua) -- now live-detected (see that
--      file's header), so this shows the SPECIFIC icon for whichever case
--      applies: the dedicated "NO ASPECT" icon if truly no aspect is up,
--      that travel aspect's own icon (Cheetah/Pack) if one of those is
--      live, or the generic "ASPECT" icon if a preferred aspect is
--      configured and a different real combat aspect is live instead.
--   4. Otherwise nil (nothing to show).

local H = Huntard
H.AlertIcon = H.AlertIcon or {}

local NO_ASPECT_TEXTURE = "Interface/AddOns/Huntard/Textures/NoAspect.png"
local ASPECT_WARNING_TEXTURE = "Interface/AddOns/Huntard/Textures/Aspect.png"

-- Returns a display status table, or nil if nothing to show:
--   { texture = ..., countdown = secondsRemaining or nil, cooldownWindow = windowSeconds or nil }
function H.AlertIcon.GetDisplayStatus()
	local ssActive, ssIcon, ssRemaining = H.SerpentSting.GetStatus()
	if ssActive then
		return { texture = ssIcon, countdown = ssRemaining, cooldownWindow = H.SerpentSting.ALERT_WINDOW }
	end

	local viperStatus, viperIcon = H.ViperAlert.GetStatus()
	if viperStatus then
		return { texture = viperIcon }
	end

	local aspectStatus, aspectIcon = H.AspectAlert.GetStatus()
	if not aspectStatus then return nil end
	if aspectStatus == "travel" then
		return { texture = aspectIcon }
	elseif aspectStatus == "wrong" then
		return { texture = ASPECT_WARNING_TEXTURE }
	end
	return { texture = NO_ASPECT_TEXTURE } -- "none"
end
