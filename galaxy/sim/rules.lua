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
	-- Lanes a captain crosses per turn.
	--
	-- **Discrete on purpose.** Movement used to be a distance - 95 world units
	-- a turn along lanes varying from roughly 60 to 200 - which meant "when
	-- does Kess arrive?" had no answer a player could work out. Lane length is
	-- not drawn, not stated and cannot be eyeballed, so the number the rule
	-- depended on was invisible. A step is countable off the map: a four-lane
	-- route takes four turns.
	--
	-- What this gives up is that lane *length* no longer means anything. If it
	-- is missed, the way back is to price some lanes at two steps and draw them
	-- as such - not to return to a continuous speed nobody can see.
	captain_steps = 1,
	-- Rank buys reach rather than pace, so progression is legible: a Commodore
	-- moves two systems a turn, a Grand Admiral three.
	steps_at_rank = { [5] = 1, [9] = 1 },
	-- A race with a mobility bonus gets a whole extra step. Fractions of a step
	-- would be exactly the invisible arithmetic this replaced.
	step_race_threshold = 0.2,
	-- How far ahead a route may be plotted, in lanes. Standing orders are what
	-- make a game checked twice a day playable rather than tedious.
	max_route_hops = 12,          -- baseline (via hops)
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
