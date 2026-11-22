-- Huntard: TargetFrameHighlight.lua
-- Colors an outline border around your target frame to match the current
-- range zone (see Range.lua). Does NOT attempt to grey out/desaturate the
-- frame's own textures -- that needs this client's real internal
-- TargetFrame field names (health bar texture, portrait texture), and no
-- installed addon happened to reference them, so there was nothing to
-- verify against. Rather than guess at field names -- an easy way to
-- silently do nothing if they're wrong -- this draws its own border
-- texture anchored to the frame instead, which works no matter its
-- internal structure. If the grey-out version is wanted too: run
-- /dump TargetFrame.healthbar (or similar) next to a target and tell me
-- what it prints, and that can be added on top of this.
--
-- Same unit-frame-addon fallback chain Questie's own QuestieNameplate.lua
-- uses (confirmed real on this client via grep) -- so this still finds
-- the right frame if ElvUI/PitBull4/etc. is running instead of Blizzard's
-- default TargetFrame.

local H = Huntard
H.TargetFrameHighlight = H.TargetFrameHighlight or {}

local BORDER_THICKNESS = 3
local borders = {} -- [frame] = { TOP=tex, BOTTOM=tex, LEFT=tex, RIGHT=tex }

local function resolveTargetFrame()
	if ElvUF_Target then return ElvUF_Target end
	if PitBull4_Frames_Target then return PitBull4_Frames_Target end
	if AzeriteUnitFrameTarget then return AzeriteUnitFrameTarget end
	if GwTargetUnitFrame then return GwTargetUnitFrame end
	if InvenUnitFrames_Target then return InvenUnitFrames_Target end
	if SUFUnittarget then return SUFUnittarget end
	if XPerl_Target then return XPerl_Target end
	if EllesmereUIUnitFrames_Target then return EllesmereUIUnitFrames_Target end
	return TargetFrame
end

local function buildBorder(parent)
	local edges = {}
	for _, point in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
		edges[point] = parent:CreateTexture(nil, "OVERLAY")
	end

	edges.TOP:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
	edges.TOP:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
	edges.TOP:SetHeight(BORDER_THICKNESS)

	edges.BOTTOM:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
	edges.BOTTOM:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
	edges.BOTTOM:SetHeight(BORDER_THICKNESS)

	edges.LEFT:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
	edges.LEFT:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
	edges.LEFT:SetWidth(BORDER_THICKNESS)

	edges.RIGHT:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
	edges.RIGHT:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
	edges.RIGHT:SetWidth(BORDER_THICKNESS)

	for _, tex in pairs(edges) do
		tex:SetColorTexture(1, 1, 1, 1)
	end
	return edges
end

local function update()
	local parent = resolveTargetFrame()
	if not parent then return end
	if not borders[parent] then
		borders[parent] = buildBorder(parent)
	end

	-- Hide every OTHER resolved frame's border (in case which unit-frame
	-- addon is "the" target frame changed, e.g. one loaded after Huntard
	-- did) -- cheap, only ever a handful of entries across a session.
	for p, edges in pairs(borders) do
		if p ~= parent then
			for _, tex in pairs(edges) do tex:Hide() end
		end
	end

	local edges = borders[parent]
	local zone = H.Range.GetZone()
	if not zone then
		for _, tex in pairs(edges) do tex:Hide() end
		return
	end
	local color = H.Range.GetColor(zone)
	for _, tex in pairs(edges) do
		tex:SetColorTexture(color[1], color[2], color[3], 1)
		tex:Show()
	end
end

function H.TargetFrameHighlight.Init()
	local ticker = CreateFrame("Frame")
	local warned = false
	ticker:SetScript("OnUpdate", function(self, elapsed)
		self.t = (self.t or 0) + elapsed
		if self.t > 0.2 then
			self.t = 0
			local ok, err = pcall(update)
			if not ok and not warned then
				warned = true
				print("|cffff4444Huntard|r target frame highlight error (won't spam further): " .. tostring(err))
			end
		end
	end)
end
