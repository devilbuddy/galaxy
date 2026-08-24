--- The research tree.
--
-- Sixteen technologies in four branches. A player researches one at a time:
-- their research income accumulates into the chosen tech until it completes,
-- which suits a game checked twice a day far better than a per-turn
-- allocation slider would - it is one decision that stays made.
--
-- Every tech does its work by contributing to the same effect table races use
-- (galaxy/sim/races.lua). Nothing in the resolver branches on a tech id, so
-- the tree is data and the rules stay readable.
--
-- Effect keys, all additive fractions on top of 1.0 unless noted:
--
--   growth capacity            population
--   industry ship_cost cap     shipbuilding
--   attack defence capture     combat ("capture" = population kept on capture)
--   speed upkeep hops(int)     movement and its fuel bill
--   yield_metal yield_fuel yield_research trade   income
--   vision(int)                extra lanes of visibility
--   tech_cost                  price of everything still unresearched

local rules = require("galaxy.sim.rules")

local M = {}

M.BRANCHES = {
	{ id = "propulsion", label = "Propulsion" },
	{ id = "munitions",  label = "Munitions" },
	{ id = "industry",   label = "Industry" },
	{ id = "sciences",   label = "Sciences" },
}

-- Tier is only used for layout and sort order; prerequisites are what the
-- rules actually enforce.
M.TECHS = {
	-- Propulsion ------------------------------------------------------------
	{
		id = "ion_drive", label = "Ion Drive", branch = "propulsion", tier = 1,
		blurb = "Fleets cross more of a lane each turn.",
		cost = { research = 80 }, requires = {},
		effects = { speed = 0.15 },
	},
	{
		id = "jump_calibration", label = "Jump Calibration", branch = "propulsion", tier = 2,
		blurb = "Longer routes can be plotted in a single order.",
		cost = { research = 300, metal = 60 }, requires = { "ion_drive" },
		effects = { hops = 4, speed = 0.10 },
	},
	{
		id = "fuel_scoops", label = "Ramscoops", branch = "propulsion", tier = 2,
		blurb = "Warships largely refuel themselves.",
		cost = { research = 300, metal = 40 }, requires = { "ion_drive" },
		effects = { upkeep = -0.30, yield_fuel = 0.10 },
	},
	{
		id = "warp_lattice", label = "Warp Lattice", branch = "propulsion", tier = 3,
		blurb = "Strike anywhere on your frontier in one turn.",
		cost = { research = 760, metal = 220 },
		requires = { "jump_calibration", "fuel_scoops" },
		effects = { speed = 0.35 },
	},

	-- Munitions -------------------------------------------------------------
	{
		id = "mass_drivers", label = "Mass Drivers", branch = "munitions", tier = 1,
		blurb = "Heavier throw weight on the attack.",
		cost = { research = 80, metal = 30 }, requires = {},
		effects = { attack = 0.12 },
	},
	{
		id = "ablative_plating", label = "Ablative Plating", branch = "munitions", tier = 2,
		blurb = "Garrisons survive what would have broken them.",
		cost = { research = 300, metal = 120 }, requires = { "mass_drivers" },
		effects = { defence = 0.18 },
	},
	{
		id = "targeting_ai", label = "Targeting Intellects", branch = "munitions", tier = 2,
		blurb = "Fewer shots wasted, in every engagement.",
		cost = { research = 320, metal = 60 }, requires = { "mass_drivers" },
		effects = { attack = 0.20 },
	},
	{
		id = "siege_doctrine", label = "Siege Doctrine", branch = "munitions", tier = 3,
		blurb = "Take worlds intact instead of taking ruins.",
		cost = { research = 760, metal = 180 },
		requires = { "ablative_plating", "targeting_ai" },
		effects = { attack = 0.15, capture = 0.20 },
	},

	-- Industry --------------------------------------------------------------
	{
		id = "orbital_yards", label = "Orbital Yards", branch = "industry", tier = 1,
		blurb = "Every world builds faster.",
		cost = { research = 85, metal = 40 }, requires = {},
		effects = { industry = 0.22 },
	},
	{
		id = "deep_core_mining", label = "Deep Core Mining", branch = "industry", tier = 2,
		blurb = "Far more metal out of the same rock.",
		cost = { research = 300, metal = 140 }, requires = { "orbital_yards" },
		effects = { yield_metal = 0.35 },
	},
	{
		id = "logistics_net", label = "Logistics Net", branch = "industry", tier = 2,
		blurb = "Cheaper hulls, a bigger navy, richer trade.",
		cost = { research = 320, metal = 80 }, requires = { "orbital_yards" },
		effects = { cap = 0.25, ship_cost = -0.15, trade = 0.25 },
	},
	{
		id = "von_neumann_forges", label = "Von Neumann Forges", branch = "industry", tier = 3,
		blurb = "The yards build the yards.",
		cost = { research = 820, metal = 300 },
		requires = { "deep_core_mining", "logistics_net" },
		effects = { industry = 0.30, yield_metal = 0.20 },
	},

	-- Sciences --------------------------------------------------------------
	{
		id = "survey_network", label = "Survey Network", branch = "sciences", tier = 1,
		blurb = "See a further lane out from everything you hold.",
		cost = { research = 70 }, requires = {},
		effects = { vision = 1, yield_research = 0.15 },
	},
	{
		id = "terraforming", label = "Terraforming", branch = "sciences", tier = 2,
		blurb = "Worlds hold more people, and fill up faster.",
		cost = { research = 320, metal = 100 }, requires = { "survey_network" },
		effects = { capacity = 0.25, growth = 0.18 },
	},
	{
		id = "xeno_archives", label = "Xeno Archives", branch = "sciences", tier = 2,
		blurb = "Read the things the precursors left behind.",
		cost = { research = 300, metal = 40 }, requires = { "survey_network" },
		effects = { yield_research = 0.35 },
	},
	{
		id = "singularity_labs", label = "Singularity Labs", branch = "sciences", tier = 3,
		blurb = "Knowledge compounds, and pays for itself.",
		cost = { research = 800, metal = 160 },
		requires = { "xeno_archives", "terraforming" },
		effects = { yield_research = 0.40, yield_fuel = 0.25, tech_cost = -0.10 },
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

--- What a tech costs this player, after their tech_cost modifier.
--
-- The numbers above are list prices, and what they encode is the *ratio*
-- between techs - which is design. How long the tree takes to walk is tuning,
-- and lives in one place: rules.tech_cost_scale.
--
-- That scale applies to the research half only. Metal is also the only thing
-- that buys ships, so multiplying it too made the full tree cost about as much
-- metal as a whole game produces - the tree stopped being a parallel
-- investment and became an alternative to having a navy. The metal figures
-- above are meant as a side-constraint that keeps a pure-research empire
-- honest, and they are already the right size for that.
--
-- Rounded up, and the discount never takes either below a quarter of list
-- price, so stacking it can not make the endgame free.
function M.cost_of(id, discount)
	local tech = BY_ID[id]
	if not tech then return nil end
	local scale = (1 + (discount or 0))
	if scale < 0.25 then scale = 0.25 end
	return {
		research = math.ceil((tech.cost.research or 0) * scale * rules.tech_cost_scale),
		metal = math.ceil((tech.cost.metal or 0) * scale),
		fuel = 0,
	}
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
