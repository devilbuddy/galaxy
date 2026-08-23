--- Builds dynamic vertex buffers for the galaxy's mesh layers.
--
-- Each layer is one mesh component with one buffer, so a layer costs a single
-- draw call no matter how many stars or lanes it contains. Per-item colour
-- lives in a vertex stream rather than a material constant, because setting a
-- constant per item is what would force Defold to break the batch.

local M = {}

local STREAM_POSITION = hash("position")
local STREAM_TEXCOORD = hash("texcoord0")
local STREAM_COLOR = hash("color")

local DECLARATION = {
	{ name = STREAM_POSITION, type = buffer.VALUE_TYPE_FLOAT32, count = 3 },
	{ name = STREAM_TEXCOORD, type = buffer.VALUE_TYPE_FLOAT32, count = 2 },
	{ name = STREAM_COLOR, type = buffer.VALUE_TYPE_FLOAT32, count = 4 },
}

local Builder = {}
Builder.__index = Builder

--- A builder sized for exactly `quads` quads.
--
-- The capacity is exact rather than generous on purpose: leftover vertices
-- would still be uploaded and rasterised as degenerate triangles every frame.
function M.new(quads)
	local verts = quads * 6
	local buf = buffer.create(verts, DECLARATION)
	return setmetatable({
		buf = buf,
		pos = buffer.get_stream(buf, STREAM_POSITION),
		uv = buffer.get_stream(buf, STREAM_TEXCOORD),
		col = buffer.get_stream(buf, STREAM_COLOR),
		n = 0,
		capacity = verts,
	}, Builder)
end

function Builder:vertex(x, y, z, u, v, r, g, b, a)
	local i = self.n
	local p, t, c = i * 3, i * 2, i * 4
	local pos, uvs, col = self.pos, self.uv, self.col
	pos[p + 1] = x; pos[p + 2] = y; pos[p + 3] = z
	uvs[t + 1] = u; uvs[t + 2] = v
	col[c + 1] = r; col[c + 2] = g; col[c + 3] = b; col[c + 4] = a
	self.n = i + 1
end

--- A quad from four corners, wound a-b-c and a-c-d.
-- Corners map to UV (u0,v0), (u1,v0), (u1,v1), (u0,v1) in that order.
function Builder:quad(ax, ay, bx, by, cx, cy, dx, dy, z, r, g, b, a, u0, v0, u1, v1)
	self:vertex(ax, ay, z, u0, v0, r, g, b, a)
	self:vertex(bx, by, z, u1, v0, r, g, b, a)
	self:vertex(cx, cy, z, u1, v1, r, g, b, a)
	self:vertex(ax, ay, z, u0, v0, r, g, b, a)
	self:vertex(cx, cy, z, u1, v1, r, g, b, a)
	self:vertex(dx, dy, z, u0, v1, r, g, b, a)
end

--- An axis-aligned quad centred on (x, y), spanning the whole texture.
function Builder:sprite(x, y, half, z, r, g, b, a)
	self:quad(
		x - half, y - half,
		x + half, y - half,
		x + half, y + half,
		x - half, y + half,
		z, r, g, b, a, 0, 0, 1, 1)
end

--- An axis-aligned quad with independent half-extents.
function Builder:rect(x, y, hw, hh, z, r, g, b, a)
	self:quad(
		x - hw, y - hh,
		x + hw, y - hh,
		x + hw, y + hh,
		x - hw, y + hh,
		z, r, g, b, a, 0, 0, 1, 1)
end

--- A thick line from (x1,y1) to (x2,y2).
--
-- The texture's soft edge runs along v, so v spans the lane's width and gives
-- the line free antialiasing at any zoom level.
function Builder:segment(x1, y1, x2, y2, width, z, r, g, b, a)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1e-6 then return end
	-- Perpendicular, scaled to half the lane width.
	local px, py = -dy / len * width * 0.5, dx / len * width * 0.5
	self:quad(
		x1 - px, y1 - py,
		x2 - px, y2 - py,
		x2 + px, y2 + py,
		x1 + px, y1 + py,
		z, r, g, b, a, 0, 0, 1, 1)
end

--- Upload to a mesh component. `url` is the mesh, e.g. "#stars".
function Builder:apply(url)
	assert(self.n == self.capacity,
		string.format("mesh builder filled %d of %d vertices", self.n, self.capacity))
	resource.set_buffer(go.get(url, "vertices"), self.buf)
end

return M
