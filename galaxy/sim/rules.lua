--- Tunable rules for the simulation.
--
-- Everything the game's balance depends on lives here so it can be adjusted
-- without reading the resolution logic. Values are per *turn*, and a turn is a
-- scheduled batch (typically two a day), not a real-time tick.
--
-- Where a value is a baseline that races and technology scale, the scaling
-- lives in galaxy/sim/modifiers.lua and the resolver never reads the raw
-- constant directly. The ones below marked "baseline" are in that group.

return {
	-- Population -----------------------------------------------------------
	-- Systems grow towards a capacity that depends on the star class; growth is
	-- a fraction of the remaining headroom, so it is fast when empty and tapers.
	base_capacity = 100,
	habitable_capacity_bonus = 1.8,
	growth_rate = 0.08,               -- baseline
	-- A newly captured system keeps this fraction of its population.
	capture_population_loss = 0.35,   -- baseline (via capture_keep)

	-- Economy ---------------------------------------------------------------
	-- A system's income per turn, per resource, is
	--     base_yield(class, feature) * (yield_flat + population * yield_per_pop)
	-- The flat part keeps a freshly claimed world from being worthless while it
	-- fills, without which the first ten turns of every game are dead time.
	yield_flat = 1.0,
	yield_per_pop = 0.04,
	-- Opening stockpile, so turn one is a decision rather than a wait.
	start_stock = { metal = 60, fuel = 40, research = 0 },

	-- Industry -------------------------------------------------------------
	-- Ships a system can lay down per turn = population * ships_per_pop. This
	-- is the *burst* ceiling; what usually binds is metal, so a player who
	-- banks resources can surge and one living hand-to-mouth cannot.
	ships_per_pop = 0.04,             -- baseline
	-- A home system is worth holding.
	home_production_bonus = 1.5,
	-- Metal builds hulls; fuel runs them. Keeping the two costs on separate
	-- resources is what makes the two levers legible: metal decides how fast
	-- you can build a navy, fuel decides how big a one you can keep.
	warship_cost = { metal = 2, fuel = 0 },
	freighter_cost = { metal = 4 },
	-- Ships a player can support, per point of population across their empire.
	--
	-- This predates the fuel economy and is now a backstop rather than the live
	-- constraint - fuel upkeep bites well before it does. It stays because
	-- removing it reopens the failure it was added for: without any ceiling,
	-- garrisons grow without bound, defence compounds and the map freezes into
	-- a permanent stalemate by about turn 75, which is exactly what
	-- tools/play.lua showed.
	fleet_cap_per_pop = 1.4,          -- baseline
	-- Fraction of the excess lost each turn when over the cap, so a shrinking
	-- empire sheds ships rather than keeping a fleet it can no longer support.
	over_cap_attrition = 0.15,

	-- Upkeep ----------------------------------------------------------------
	-- Fuel per warship per turn. This is the real limit on fleet size: a
	-- ten-system empire earns roughly enough fuel for six hundred warships,
	-- comfortably under what its population would allow, so expansion buys
	-- military strength through economy rather than directly.
	fuel_per_warship = 0.08,          -- baseline
	-- Ships beyond what the fuel bill covers are lost at this rate per turn.
	unfuelled_attrition = 0.10,

	-- Trade -----------------------------------------------------------------
	-- Per freighter per turn on an established route, before length and
	-- population scaling. Paid half in research and half in fuel - never in
	-- metal, so hulls always have to be dug out of ground you hold and a trade
	-- empire cannot skip having territory.
	trade_yield = 0.9,                -- baseline
	-- Route income scales with distance up to this multiple, so a long route
	-- across the map is worth the exposure it carries.
	trade_length_reference = 300,
	trade_length_cap = 2.0,
	-- ...and with the population at both ends, up to this multiple.
	trade_pop_reference = 200,
	trade_pop_cap = 1.5,

	-- Research ---------------------------------------------------------------
	-- Multiplies the *research* half of every list price in galaxy/sim/tech.lua
	-- (their metal costs are left alone; see tech.cost_of for why). The one knob
	-- for how long the tree takes to walk: the costs there fix the ratio between
	-- techs, this fixes the pace. At 1.0 a greedy AI in tools/play.lua finishes
	-- the whole tree by turn 25, which is a fortnight of a twice-a-day game and
	-- makes the back half of it scenery.
	tech_cost_scale = 9.0,

	-- Movement -------------------------------------------------------------
	-- World units a fleet covers per turn. Typical lane length is ~130, so most
	-- single-lane hops take one turn and long ones take two or three.
	fleet_speed = 150,                -- baseline
	-- Fleets always travel along lanes; this caps how far an order may path.
	max_path_hops = 12,               -- baseline
	-- Freighters are civilian hulls and slower than a warfleet.
	freighter_speed_factor = 0.8,

	-- Intelligence ----------------------------------------------------------
	-- Lanes of visibility around anything you hold. Survey Network adds one.
	base_vision = 1,                  -- baseline

	-- Combat ---------------------------------------------------------------
	-- Defenders fight above their weight; taking a system should cost more than
	-- holding it.
	defence_bonus = 1.25,             -- baseline
	-- Losses are scaled by +/- this fraction, drawn from the turn's seeded RNG,
	-- so battles are not perfectly predictable but stay reproducible.
	combat_variance = 0.12,
	-- Freighters caught at a system that falls are captured, not destroyed:
	-- this fraction survives into the winner's hands.
	freighter_capture_rate = 0.5,

	-- Starting position ----------------------------------------------------
	start_population = 40,
	start_ships = 20,
}
