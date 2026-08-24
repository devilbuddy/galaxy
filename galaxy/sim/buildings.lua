--- Buildings, as levels rather than queue items.
--
-- The shape matters more than the content. A per-system build *queue* is what
-- would turn this game into a chore list: twenty worlds, two logins a day, and
-- every session spent re-checking timers. So a building is a level you raise
-- once and never think about again - one tap, paid out of that system's own
-- output over however many turns it takes, then done forever.
--
-- Only a colony can host the buildings that need people. A radar mast and a gun
-- battery do not, which is what lets a frontier of barren outposts be fortified
-- and watched - otherwise the rules would forbid putting a listening post
-- anywhere you actually need one.

local systems = require("galaxy.sim.systems")
local rules = require("galaxy.sim.rules")

local M = {}

M.KINDS = {
	{
		id = "radar",
		label = "Radar Array",
		icon = "icon_vision",
		blurb = "Sees further down the lanes.",
		-- Installations, not cities: an outpost can host these.
		needs_population = false,
		levels = { 25, 60, 130 },
	},
	{
		id = "fortress",
		label = "Fortress",
		icon = "icon_defence",
		blurb = "Holds ground without a fleet parked on it.",
		needs_population = false,
		levels = { 35, 90, 200 },
	},
	{
		id = "shipyard",
		label = "Shipyard",
		icon = "icon_industry",
		blurb = "Builds more per turn. Needs people.",
		needs_population = true,
		levels = { 40, 100, 220 },
	},
}

local BY_ID = {}
for i = 1, #M.KINDS do BY_ID[M.KINDS[i].id] = M.KINDS[i] end

function M.by_id(id)
	return BY_ID[id]
end

function M.max_level(id)
	local kind = BY_ID[id]
	return kind and #kind.levels or 0
end

--- A fresh set of levels.
function M.zero()
	local out = {}
	for i = 1, #M.KINDS do out[M.KINDS[i].id] = 0 end
	return out
end

--- Can this system host this building at all?
function M.allowed(galaxy, id, building)
	local kind = BY_ID[building]
	if not kind then return false, "no such building" end
	local profile = systems.profile(galaxy, id)
	if profile.kind == systems.WAYPOINT then
		return false, "nothing to build on"
	end
	if kind.needs_population and profile.kind ~= systems.COLONY then
		return false, "needs a colony"
	end
	return true
end

--- What raising `building` from its current level costs, after any discount.
-- Returns nil when it is already at maximum.
function M.cost(building, level, discount)
	local kind = BY_ID[building]
	if not kind then return nil end
	local next_level = (level or 0) + 1
	local base = kind.levels[next_level]
	if not base then return nil end
	local scale = 1 + (discount or 0)
	if scale < 0.25 then scale = 0.25 end
	return math.ceil(base * scale * rules.building_cost_scale)
end

--- May this player start `building` here right now?
function M.can_start(galaxy, id, sys, building, known_levels)
	local ok, why = M.allowed(galaxy, id, building)
	if not ok then return false, why end
	local level = (known_levels or sys.buildings or {})[building] or 0
	if level >= M.max_level(building) then return false, "already at maximum" end
	return true
end

--- Repair a level set that has been through JSON, or was never written.
function M.normalise(levels)
	local out = M.zero()
	if type(levels) ~= "table" then return out end
	for i = 1, #M.KINDS do
		local id = M.KINDS[i].id
		local value = tonumber(levels[id]) or 0
		if value < 0 then value = 0 end
		local max = #M.KINDS[i].levels
		if value > max then value = max end
		out[id] = math.floor(value)
	end
	return out
end

--- What a system can host, in declaration order, for a client listing.
function M.available(galaxy, id)
	local out = {}
	for i = 1, #M.KINDS do
		if M.allowed(galaxy, id, M.KINDS[i].id) then
			out[#out + 1] = M.KINDS[i].id
		end
	end
	return out
end

return M
