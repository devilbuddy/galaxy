--- What a colony can be built into.
--
-- Two slots, four buildings, and they do not stack - so a colony **specialises**
-- and the decision is spatial rather than numeric: this one is where my units
-- come from, that one is where my officers do, the one on the frontier is a
-- fortress. It is a choice a player makes once per colony, in ten seconds, and
-- then lives with, which is the only shape that survives two logins a day.
--
--   Yards      more units held ready
--   Works      another ready every turn instead of every other
--   Bastion    harder to take, and feeds nobody
--   Admiralty  another captain allowed, and the place to raise them
--
-- **Buildings need no captain present.** Raising one is an empire's decision,
-- not an errand, and requiring an officer to stand there would make the whole
-- economy hostage to one captain's touring speed. It is also the sink that
-- absorbs a large empire's surplus, which units alone never could: colonies
-- produce at a fixed rate however rich you are.
--
-- Ordered, never keyed: `pairs` order is unspecified and both runtimes have to
-- agree on what a turn contained.

local rules = require("galaxy.sim.rules")

local M = {}

M.CATALOGUE = {
	{
		id = "yards",
		name = "Yards",
		blurb = "Holds more units ready.",
		cost = 140,
	},
	{
		id = "works",
		name = "Works",
		blurb = "Makes one ready every turn.",
		cost = 160,
	},
	{
		id = "bastion",
		name = "Bastion",
		blurb = "Harder to take. Arms nobody.",
		cost = 100,
	},
	{
		id = "admiralty",
		name = "Admiralty",
		blurb = "Another captain, raised here.",
		cost = 220,
	},
}

local BY_ID = {}
for i = 1, #M.CATALOGUE do BY_ID[M.CATALOGUE[i].id] = M.CATALOGUE[i] end

function M.by_id(id)
	return BY_ID[id]
end

function M.exists(id)
	return BY_ID[id] ~= nil
end

--- Ids in catalogue order, for a client that wants to list them.
function M.ids()
	local out = {}
	for i = 1, #M.CATALOGUE do out[i] = M.CATALOGUE[i].id end
	return out
end

-- Reading a colony -------------------------------------------------------------

--- Does this system have that building?
function M.has(sys, id)
	local built = sys and sys.buildings
	if not built then return false end
	for i = 1, #built do
		if built[i] == id then return true end
	end
	return false
end

function M.count(sys)
	local built = sys and sys.buildings
	return built and #built or 0
end

function M.room(sys)
	return M.count(sys) < rules.building_slots
end

-- What they do ------------------------------------------------------------------

--- How many units this colony holds ready.
function M.stock_cap(sys)
	local cap = rules.colony_stock_cap
	if M.has(sys, "yards") then cap = cap + rules.yards_stock end
	return cap
end

--- How often another becomes available, in turns.
function M.stock_turns(sys)
	if M.has(sys, "works") then return 1 end
	return rules.colony_stock_turns
end

--- What a Bastion adds to a system's resistance.
--
-- Flat, and on top of everything else. It is the only way to make a world hard
-- to take, deliberately: production used to defend the colony holding it, which
-- meant a world nobody had visited fortified itself for free.
function M.defence_bonus(sys)
	if M.has(sys, "bastion") then return rules.bastion_defence end
	return 0
end

--- How many captains this player may have in the field.
--
-- One to begin with, and one more per Admiralty. Capped, because the commander
-- strip is a row of faces rather than a list and stops being readable past
-- four - a limit worth keeping as a rule rather than discovering as a layout
-- bug.
function M.captain_cap(state, player)
	local cap = rules.captain_cap
	for _, sys in pairs(state.systems) do
		if sys.owner == player and M.has(sys, "admiralty") then
			cap = cap + 1
		end
	end
	if cap > rules.captain_cap_max then cap = rules.captain_cap_max end
	return cap
end

return M
