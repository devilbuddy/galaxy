--- Tunable rules for the simulation.
--
-- Everything the game's balance depends on lives here so it can be adjusted
-- without reading the resolution logic. Values are per *turn*, and a turn is a
-- scheduled batch (typically two a day), not a real-time tick.
--
-- Where a value is a baseline that races and technology scale, the scaling lives
-- in galaxy/sim/modifiers.lua and the resolver never reads the raw constant
-- directly. Those are marked "baseline".
--
-- The economy is one axis on purpose. A system produces **build points**, which
-- become ships or pay for a building, and **research**, which is the only thing
-- that pools empire-wide. There is no second currency, no upkeep and no
-- logistics: what makes an empire strong is how much ground it holds.

return {
	-- Population --------------------------------------------------------------
	-- Only colonies have any (see galaxy/sim/systems.lua). Growth is a fraction
	-- of the remaining headroom, so an empty world fills quickly and a full one
	-- stagnates.
	base_capacity = 130,
	growth_rate = 0.08,              -- baseline
	-- A captured world keeps this fraction of its people. Buildings survive
	-- intact, so this is the whole cost of conquest - and because output and
	-- defence both scale with population, a blitz leaves you holding a lot of
	-- strong, useless worlds.
	capture_population_loss = 0.40,  -- baseline (via capture_keep)

	-- Output ------------------------------------------------------------------
	-- Build points per turn. A colony scales with its people; an outpost is a
	-- flat trickle whoever holds it.
	colony_output_flat = 1.0,
	colony_output_per_pop = 0.05,
	outpost_output = 2.0,
	-- Build points per ship, so a colony of 150 lays down about eight a turn.
	ship_cost = 1.0,                 -- baseline (via ship_cost)
	shipyard_bonus = 0.35,           -- per shipyard level
	-- Multiplies every building's list price in galaxy/sim/buildings.lua: the
	-- one knob for how long infrastructure takes relative to a fleet.
	building_cost_scale = 1.0,

	-- Research ----------------------------------------------------------------
	research_per_pop = 0.04,
	outpost_research = 0.5,
	-- Multiplies the research half of every tech's list price; see
	-- galaxy/sim/tech.lua for why metal is not scaled with it.
	tech_cost_scale = 4.0,

	-- Commanders --------------------------------------------------------------
	-- How many forces a player may field at once. **This is the shape of the
	-- game**, not a balance knob: with a cap, "which fronts am I fighting on"
	-- is a decision, and without one a 400-turn run ends with one empire
	-- holding a hundred and sixty forces and a list nobody can read.
	commander_cap = 4,
	commander_max_level = 10,
	-- Experience is enemy ships destroyed. Quadratic thresholds, so the first
	-- promotion comes from a skirmish and the last from a campaign:
	-- level n at base * (n-1) * n, i.e. 150 / 450 / 900 / 1500 at base 75.
	commander_xp_base = 75,
	-- Ships a commander can lead. Anything over it stays in the garrison, so a
	-- veteran is worth more than the sum of their ships.
	--
	-- Sized against the economy, not picked for feel: `fleet_cap_per_pop` lets a
	-- developed empire support roughly 400 ships, and four commanders at level 1
	-- have to be able to field about that many or the cap stops being "how many
	-- fronts" and becomes "you may not attack anything defended". At 70 it did
	-- exactly that - every AI in tools/play.lua froze at four systems by turn 75
	-- because no assault it could mount ever met a defended world's price.
	command_base = 120,
	command_per_level = 40,          -- baseline (via command)
	-- Battle multiplier from the officer alone: +6% a level, so a Grand Admiral
	-- fights at about 1.5x a raw force of the same size.
	tactics_per_level = 0.06,        -- baseline (via tactics)

	-- Fleets ------------------------------------------------------------------
	-- Ships a player can support per point of population. Without a ceiling,
	-- forces grow without bound, defence compounds and the map freezes into a
	-- permanent stalemate by about turn 75 - which is exactly what
	-- tools/play.lua showed before it existed.
	fleet_cap_per_pop = 1.4,         -- baseline (via cap)
	over_cap_attrition = 0.15,
	-- World units a commander covers per turn.
	--
	-- **Deliberately below a typical lane** (~130). At the old 150 every hop
	-- completed inside one turn, so nothing was ever caught in transit and
	-- interception was decoration that only tests ever saw. At 95 a green
	-- commander spends a turn or two on a long lane, which is where the map
	-- stops being a list of systems and starts being a distance.
	commander_speed = 95,            -- baseline (via speed_scale)
	speed_per_level = 7,             -- so a Grand Admiral crosses in one turn
	-- How far ahead a route may be plotted, in lanes.
	max_route_hops = 12,             -- baseline (via hops)
	-- Fleets below this are folded into whatever they arrive at rather than
	-- cluttering the map.
	min_fleet_size = 1,

	-- Combat ------------------------------------------------------------------
	-- Defenders fight above their weight; taking a system should cost more than
	-- holding it.
	defence_bonus = 1.25,            -- baseline (via defence)
	-- Losses are scaled by +/- this fraction from the turn's seeded RNG, so
	-- battles are not perfectly predictable but stay reproducible.
	combat_variance = 0.12,
	-- What a world defends itself with before any fleet is counted.
	planet_defence_per_pop = 0.20,
	fortress_defence = 40,           -- per fortress level

	-- Intelligence ------------------------------------------------------------
	-- Lanes of vision. A developed border world sees much further than a fleet,
	-- which is what makes a radar outpost a listening post worth fighting over.
	base_vision = 1,                 -- baseline (via vision)
	radar_vision = 1,                -- per radar level
	fleet_vision = 1,

	-- Regions -----------------------------------------------------------------
	-- The map is much bigger than anyone will hold, so the objective is the
	-- region rather than the system count - see galaxy/sim/regions.lua. A held
	-- region pays a little more, which is what makes finishing one off worth
	-- doing instead of leaving a stubborn outpost behind.
	region_output_bonus = 0.15,
	-- Fraction of all regions that wins the game.
	victory_region_fraction = 0.5,

	-- Starting position -------------------------------------------------------
	start_population = 50,
	start_ships = 25,
	-- A home must have at least this many colonies within reach, or the game is
	-- decided at generation rather than played.
	home_colony_hops = 3,
	home_colony_minimum = 3,
}
