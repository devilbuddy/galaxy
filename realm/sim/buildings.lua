--- What a city can be built into.
--
-- Four slots and five buildings, so a city **specialises** and the decision is
-- spatial rather than numeric: this one makes escorts, that one is where
-- officers come from, the one on the frontier is a fortress. You give up
-- exactly one thing, and which one is decided by where the city sits.
--
--   Berths           Escorts accumulate here
--   Interceptor Bay  Interceptors accumulate here
--   Foundry          Bombards accumulate here
--   Bastion          harder to take, and arms nobody
--   Admiralty        another commander allowed, and the place to raise them
--
-- **A city makes only what it has dwellings for.** There is no base
-- production any more: a world you have just taken pays gold, counts towards
-- its province and is somewhere to stand, but there is no shipyard on it until
-- you put one there. That is what makes the four slots the whole decision
-- rather than a bonus on top of one, and it is what turns an enemy's developed
-- city into a target worth wanting - **buildings live on the tile, so a
-- city changes hands with everything built on it.** Before this the only
-- reason to want a *particular* world was provinces and seats.
--
-- A seat opens with Berths already standing, because a player who cannot arm
-- at all until they have saved sixty gold has no opening.
--
-- **Buildings need no commander present.** Raising one is an empire's decision,
-- not an errand, and requiring an officer to stand there would make the whole
-- economy hostage to one commander's touring speed.
--
-- **`every` is the single most load-bearing number in the economy**, and it was
-- measured rather than argued. Twenty seeds at four players: at every-other-turn
-- the median game ran 181 turns and every surviving player finished sitting on
-- ~8,300 gold they could not spend; at every turn it is 128 and ~2,500.
-- Halving the *prices* instead moved the median the wrong way and raised the
-- idle pile to 8,800 - money was never the constraint, throughput was.
--
-- That reverses an older rule, which said making stock accrue every turn was
-- worse than either cadence and left seeds running past 1500 turns. It was
-- true, of a pooled stock that every city got for free. Once production is
-- gated behind a building you spend an order and a slot on, "every turn" only
-- means the cities somebody actually developed.
--
-- Ordered, never keyed: `pairs` order is unspecified and both runtimes have to
-- agree on what a turn contained.

local rules = require("realm.sim.rules")

local M = {}

M.CATALOGUE = {
	{
		id = "berths",
		name = "Berths",
		blurb = "Escorts, ready to buy.",
		cost = 60,
		makes = "escort",
		ready = 2,          -- how many accumulate, at most
		every = 1,          -- and how often another does, in turns
	},
	{
		id = "interceptor_bay",
		name = "Interceptor Bay",
		blurb = "Interceptors, ready to buy.",
		cost = 140,
		makes = "interceptor",
		ready = 2,
		every = 1,
	},
	{
		id = "foundry",
		name = "Foundry",
		blurb = "Bombards, ready to buy.",
		cost = 160,
		makes = "bombard",
		ready = 2,
		every = 1,
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
		blurb = "Another commander, raised here.",
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

-- Reading a city -------------------------------------------------------------

--- Does this tile have that building?
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

--- The dwellings standing on this city, in catalogue order.
--
-- Ordered rather than keyed for the usual reason: two runtimes have to agree on
-- what a turn contained, and `pairs` does not.
function M.dwellings(sys)
	local out = {}
	for i = 1, #M.CATALOGUE do
		local spec = M.CATALOGUE[i]
		if spec.makes and M.has(sys, spec.id) then out[#out + 1] = spec end
	end
	return out
end

--- Does this city make that unit type at all?
function M.makes(sys, type_id)
	for i = 1, #M.CATALOGUE do
		local spec = M.CATALOGUE[i]
		if spec.makes == type_id and M.has(sys, spec.id) then return spec end
	end
	return nil
end

--- How many of a type this city holds ready at most.
--
-- Zero where there is no dwelling for it, which is the whole point: a city
-- with no Foundry does not accumulate Bombards slowly, it does not accumulate
-- them at all.
function M.ready_cap(sys, type_id)
	local spec = M.makes(sys, type_id)
	return spec and spec.ready or 0
end

--- What a Bastion adds to a tile's resistance.
--
-- Flat, and on top of everything else. It is the only way to make a world hard
-- to take, deliberately: production used to defend the city holding it, which
-- meant a world nobody had visited fortified itself for free.
function M.defence_bonus(sys)
	if M.has(sys, "bastion") then return rules.bastion_defence end
	return 0
end

--- How many commanders this player may have in the field.
--
-- One to begin with, and one more per Admiralty. Capped, because the commander
-- strip is a row of faces rather than a list and stops being readable past
-- four - a limit worth keeping as a rule rather than discovering as a layout
-- bug.
function M.commander_cap(state, player)
	local cap = rules.commander_cap
	for _, sys in pairs(state.tiles) do
		if sys.owner == player and M.has(sys, "admiralty") then
			cap = cap + 1
		end
	end
	if cap > rules.commander_cap_max then cap = rules.commander_cap_max end
	return cap
end

return M
