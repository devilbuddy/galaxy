--- The research tree.
--
-- Twelve technologies in three branches, all of them about waging war: moving
-- fleets, winning fights, and seeing and fortifying ground. There is nothing
-- here about trade or terraforming, because conquest is how an empire grows.
--
-- A player researches one at a time: research accumulates in the pool and the
-- chosen technology is bought the moment it is affordable, which suits a game
-- checked twice a day far better than a per-turn allocation would - it is one
-- decision that stays made.
--
-- Every tech does its work by contributing to the same effect table races use
-- (galaxy/sim/races.lua). Nothing in the resolver branches on a tech id, so the
-- tree is data and the rules stay readable.
--
-- Effect keys, all additive fractions on top of 1.0 unless noted:
--
--   growth capacity            population
--   industry ship_cost cap     output and how big a fleet it can support
--   attack defence capture     combat ("capture" = population kept on capture)
--   speed hops(int)            movement and how far a route may be plotted
--   research building_cost     the two things output and research buy
--   fortress                   how much a fortress is worth
--   vision(int)                lanes of sight, on top of radar
--   tech_cost                  price of everything still unresearched

local rules = require("galaxy.sim.rules")

local M = {}

M.BRANCHES = {
	{ id = "propulsion",  label = "Propulsion" },
	{ id = "munitions",   label = "Munitions" },
	{ id = "engineering", label = "Engineering" },
}

-- Tier is only used for layout and sort order; prerequisites are what the rules
-- actually enforce. Every branch is shaped 1 - 2 - 1, which is what lets the
-- client draw it as a tree that forks and merges.
M.TECHS = {
	-- Propulsion --------------------------------------------------------------
	{
		id = "ion_drive", label = "Ion Drive", branch = "propulsion", tier = 1,
		blurb = "Fleets cross more of a lane each turn.",
		cost = 80, requires = {},
		effects = { speed = 0.15 },
	},
	{
		id = "jump_calibration", label = "Jump Calibration", branch = "propulsion", tier = 2,
		blurb = "Plot a longer campaign in a single order.",
		cost = 300, requires = { "ion_drive" },
		effects = { hops = 4, speed = 0.10 },
	},
	{
		id = "fleet_logistics", label = "Fleet Logistics", branch = "propulsion", tier = 2,
		blurb = "A bigger navy, and cheaper hulls to fill it.",
		cost = 320, requires = { "ion_drive" },
		effects = { cap = 0.25, ship_cost = -0.15 },
	},
	{
		id = "warp_lattice", label = "Warp Lattice", branch = "propulsion", tier = 3,
		blurb = "Strike anywhere on your frontier in one turn.",
		cost = 760, requires = { "jump_calibration", "fleet_logistics" },
		effects = { speed = 0.35 },
	},

	-- Munitions ---------------------------------------------------------------
	{
		id = "mass_drivers", label = "Mass Drivers", branch = "munitions", tier = 1,
		blurb = "Heavier throw weight on the attack.",
		cost = 80, requires = {},
		effects = { attack = 0.12 },
	},
	{
		id = "targeting_ai", label = "Targeting Intellects", branch = "munitions", tier = 2,
		blurb = "Fewer shots wasted, in every engagement.",
		cost = 320, requires = { "mass_drivers" },
		effects = { attack = 0.20 },
	},
	{
		id = "ablative_plating", label = "Ablative Plating", branch = "munitions", tier = 2,
		blurb = "Defenders survive what would have broken them.",
		cost = 300, requires = { "mass_drivers" },
		effects = { defence = 0.18 },
	},
	{
		id = "siege_doctrine", label = "Siege Doctrine", branch = "munitions", tier = 3,
		blurb = "Take worlds intact instead of taking ruins.",
		cost = 760, requires = { "targeting_ai", "ablative_plating" },
		effects = { attack = 0.15, capture = 0.25 },
	},

	-- Engineering -------------------------------------------------------------
	{
		id = "survey_network", label = "Survey Network", branch = "engineering", tier = 1,
		blurb = "See a further lane out from everything you hold.",
		cost = 70, requires = {},
		effects = { vision = 1, research = 0.15 },
	},
	{
		id = "orbital_yards", label = "Orbital Yards", branch = "engineering", tier = 2,
		blurb = "More out of every world, and cheaper to develop one.",
		cost = 320, requires = { "survey_network" },
		effects = { industry = 0.25, building_cost = -0.20 },
	},
	{
		id = "xeno_archives", label = "Xeno Archives", branch = "engineering", tier = 2,
		blurb = "Read what the precursors left behind.",
		cost = 300, requires = { "survey_network" },
		effects = { research = 0.35 },
	},
	{
		id = "bastion_protocols", label = "Bastion Protocols", branch = "engineering", tier = 3,
		blurb = "Fortifications that hold a chokepoint on their own.",
		cost = 800, requires = { "orbital_yards", "xeno_archives" },
		effects = { fortress = 0.50, vision = 1 },
	},
}

local BY_ID = {}
for i = 1, #M.TECHS do BY_ID[M.TECHS[i].id] = M.TECHS[i] end

function M.by_id(id)
	return BY_ID[id]
end

--- Have all of this tech's prerequisites been researched?
function M.prereqs_met(known, id)
	local tech = BY_ID[id]
	if not tech then return false end
	for i = 1, #tech.requires do
		if not known[tech.requires[i]] then return false end
	end
	return true
end

--- May this player start researching `id` right now?
function M.can_research(known, id)
	if not BY_ID[id] then return false, "no such technology" end
	if known[id] then return false, "already researched" end
	if not M.prereqs_met(known, id) then return false, "prerequisites not met" end
	return true
end

--- Everything researchable right now, in tree order.
--
-- Iterating M.TECHS rather than the `known` set keeps the order stable; `known`
-- is a hash and pairs() order is unspecified.
function M.available(known)
	local out = {}
	for i = 1, #M.TECHS do
		local tech = M.TECHS[i]
		if not known[tech.id] and M.prereqs_met(known, tech.id) then
			out[#out + 1] = tech.id
		end
	end
	return out
end

--- What a tech costs this player, in research points.
--
-- The numbers above are list prices, and what they encode is the *ratio*
-- between technologies - which is design. How long the tree takes to walk is
-- tuning, and lives in one place: rules.tech_cost_scale.
--
-- Rounded up, and the discount never takes it below a quarter of list price, so
-- stacking discounts cannot make the endgame free.
function M.cost_of(id, discount)
	local tech = BY_ID[id]
	if not tech then return nil end
	local scale = 1 + (discount or 0)
	if scale < 0.25 then scale = 0.25 end
	return math.ceil(tech.cost * scale * rules.tech_cost_scale)
end

--- Fold every researched tech into one effect table.
function M.effects_of(known, into)
	local out = into or {}
	for i = 1, #M.TECHS do
		local tech = M.TECHS[i]
		if known[tech.id] then
			for key, value in pairs(tech.effects) do
				out[key] = (out[key] or 0) + value
			end
		end
	end
	return out
end

--- Repair a `known` set that has been through JSON.
--
-- An empty Lua table encodes as `[]` in some encoders and `{}` in others, and
-- either can come back as something that is not a set at all.
function M.normalise_known(known)
	local out = {}
	if type(known) ~= "table" then return out end
	for id, value in pairs(known) do
		-- Tolerate both { xeno_archives = true } and { "xeno_archives" }.
		if value == true and BY_ID[id] then
			out[id] = true
		elseif type(value) == "string" and BY_ID[value] then
			out[value] = true
		end
	end
	return out
end

return M
