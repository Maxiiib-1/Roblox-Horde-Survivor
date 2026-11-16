--!nonstrict
-- MapGen/Occupancy: rejilla espacial de obstáculos (círculos) para colocar cosas sin encimarlas.
-- Reemplaza la búsqueda lineal anterior (que con cientos de obstáculos se volvía lenta).
local Occupancy = {}
Occupancy.__index = Occupancy

function Occupancy.new(cell)
	return setmetatable({ cell = cell or 16, cells = {}, big = {}, maxR = 0 }, Occupancy)
end

local function key(cx, cz) return cx * 8192 + cz end

function Occupancy:add(o)
	if o.r > self.cell * 2 then table.insert(self.big, o); return end
	local k = key(math.floor(o.x / self.cell), math.floor(o.z / self.cell))
	local b = self.cells[k]
	if not b then b = {}; self.cells[k] = b end
	table.insert(b, o)
	if o.r > self.maxR then self.maxR = o.r end
end

-- ¿hay lugar para un círculo de radio r con un margen extra?
function Occupancy:free(x, z, r, margin)
	margin = margin or 0
	for _, o in ipairs(self.big) do
		local dx, dz = x - o.x, z - o.z
		local lim = o.r + r + margin
		if dx * dx + dz * dz < lim * lim then return false end
	end
	local reach = r + margin + self.maxR
	local c = self.cell
	for cx = math.floor((x - reach) / c), math.floor((x + reach) / c) do
		for cz = math.floor((z - reach) / c), math.floor((z + reach) / c) do
			local b = self.cells[key(cx, cz)]
			if b then
				for _, o in ipairs(b) do
					local dx, dz = x - o.x, z - o.z
					local lim = o.r + r + margin
					if dx * dx + dz * dz < lim * lim then return false end
				end
			end
		end
	end
	return true
end

return Occupancy
