--- Tunable rules for the simulation.
--
-- Everything the game's balance depends on lives here so it can be adjusted
-- without reading the resolution logic. Values are per *turn*, and a turn is a
-- scheduled batch (typically two a day), not a real-time tick.

return {
	-- Population -----------------------------------------------------------
	-- Systems grow towards a capacity that depends on the star class; growth is
	-- a fraction of the remaining headroom, so it is fast when empty and tapers.
	base_capacity = 100,
	habitable_capacity_bonus = 1.8,
	growth_rate = 0.08,
	-- A newly captured system keeps this fraction of its population.
	capture_population_loss = 0.35,

	-- Industry -------------------------------------------------------------
	-- Ships produced per turn = population * ships_per_pop, so a bigger, older
	-- empire out-produces a new one but only linearly.
	ships_per_pop = 0.04,
	-- A home system is worth holding.
	home_production_bonus = 1.5,
	-- Ships a player can support, per point of population across their empire.
	--
	-- Without a ceiling every garrison grows without bound, defence compounds
	-- forever and the map freezes into a permanent stalemate - which is exactly
	-- what tools/play.lua showed. Tying the cap to population makes fleet
	-- strength a consequence of territory, so losing ground genuinely weakens
	-- you and a larger empire can concentrate more force than a smaller one can
	-- hold at any single point.
	fleet_cap_per_pop = 1.4,
	-- Fraction of the excess lost each turn when over the cap, so a shrinking
	-- empire sheds ships rather than keeping a fleet it can no longer support.
	over_cap_attrition = 0.15,

	-- Movement -------------------------------------------------------------
	-- World units a fleet covers per turn. Typical lane length is ~130, so most
	-- single-lane hops take one turn and long ones take two or three.
	fleet_speed = 150,
	-- Fleets always travel along lanes; this caps how far an order may path.
	max_path_hops = 12,

	-- Combat ---------------------------------------------------------------
	-- Defenders fight above their weight; taking a system should cost more than
	-- holding it.
	defence_bonus = 1.25,
	-- Losses are scaled by +/- this fraction, drawn from the turn's seeded RNG,
	-- so battles are not perfectly predictable but stay reproducible.
	combat_variance = 0.12,

	-- Starting position ----------------------------------------------------
	start_population = 40,
	start_ships = 20,
}
