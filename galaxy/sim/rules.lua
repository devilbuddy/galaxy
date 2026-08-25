--- Tunable rules for the simulation.
--
-- Everything the game's balance depends on lives here so it can be adjusted
-- without reading the resolution logic. Values are per *turn*, and a turn is a
-- scheduled batch, not a real-time tick.
--
-- The game is being rebuilt from its foundations. Right now it is only this:
-- every player has a capital and one captain, captains move along lanes, and
-- whatever they pass through becomes theirs. There is no production, no
-- research and no combat - those arrive with city upgrades and unit types, and
-- the constants for them will arrive with the code that reads them rather than
-- sitting here describing a game that is not running.

return {
	-- Movement ----------------------------------------------------------------
	-- World units a captain covers per turn.
	--
	-- Deliberately below a typical lane (~130). A captain that crossed any lane
	-- in one turn would make distance meaningless, and distance is currently the
	-- only thing standing between a player and the far side of the map.
	captain_speed = 95,           -- baseline (via speed_scale)
	-- How far ahead a route may be plotted, in lanes. Standing orders are what
	-- make a game checked twice a day playable rather than tedious.
	max_route_hops = 12,          -- baseline (via hops)
	-- Rank still makes a captain faster, which is the one place progression is
	-- visible while nothing awards experience.
	speed_per_level = 7,
	commander_max_level = 10,
	commander_xp_base = 75,

	-- Intelligence ------------------------------------------------------------
	-- Lanes of vision from each source. A captain sees barely past itself; a
	-- world you hold sees its own neighbourhood.
	base_vision = 1,              -- baseline (via vision)
	captain_vision = 1,

	-- Regions -----------------------------------------------------------------
	-- The map is far larger than anyone will hold, so the objective is the
	-- region rather than the system count - see galaxy/sim/regions.lua.
	victory_region_fraction = 0.5,

	-- Starting position -------------------------------------------------------
	-- A capital must have somewhere to expand into, or the game is decided at
	-- generation rather than in play.
	capital_hops = 3,
	capital_neighbours = 3,
}
