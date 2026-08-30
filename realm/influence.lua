--- Ownership outlines on the hex lattice.
--
-- A tile draws only the sides exposed to a different owner. Six sides fit in
-- one integer, in the same east-and-anticlockwise order as realm.hex.DIRECTIONS:
-- bit 0 is direction 1, bit 5 is direction 6. Keeping this engine-independent
-- makes the political geometry testable without Defold.

local M = {}

M.EDGE_COUNT = 6
M.FULL_MASK = 63

--- Return the edge mask for `owner` beside six neighbouring ownership values.
-- Missing, unknown, sea and unowned neighbours are all represented by zero (or
-- nil) and therefore close the outline. An unowned tile never has influence.
function M.mask(owner, neighbours)
	owner = tonumber(owner) or 0
	if owner == 0 then return 0 end

	local mask, bit = 0, 1
	for i = 1, M.EDGE_COUNT do
		if (neighbours and neighbours[i] or 0) ~= owner then
			mask = mask + bit
		end
		bit = bit * 2
	end
	return mask
end

--- Atlas animation name for a non-empty mask.
function M.image(mask)
	if not mask or mask <= 0 or mask > M.FULL_MASK then return nil end
	return string.format("influence_%02d", mask)
end

return M
