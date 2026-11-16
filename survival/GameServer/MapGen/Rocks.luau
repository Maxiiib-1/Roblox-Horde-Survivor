--!nonstrict
-- MapGen/Rocks: rocas redondeadas (con musgo en el Bosque). La mayoría al pie de los barrancos de las mesetas,
-- el resto sueltas o en grupitos. Las grandes colisionan (y los enemigos trepan por encima); las chicas no.
local Props = require(script.Parent.Props)

local Rocks = {}

function Rocks.place(ctx)
	local cfg, P, rng, HM = ctx.cfg, ctx.P, ctx.rng, ctx.HM
	local HALF = ctx.half
	local pathHalf = cfg.terrace.pathWidth * 0.5
	local plats = {}
	for _, q in ipairs(ctx.layout.plateaus) do if q.h > 0 then table.insert(plats, q) end end
	local total = math.floor(70 * cfg.rockDensity + 0.5)
	local placed, tries = 0, 0
	local function put(x, z, r)
		if math.abs(x) > HALF - r - 4 or math.abs(z) > HALF - r - 4 then return false end
		if x * x + z * z < (cfg.spawnClearRadius + 6 + r) ^ 2 then return false end
		if ctx.inKeepClear(x, z, r) or ctx.inWater(x, z, r + 2) then return false end
		if HM:pathDist(x, z) < pathHalf + r + 2 then return false end
		if HM:slope(x, z) > 0.8 then return false end
		if not ctx.free(x, z, r, 2) then return false end
		local collide = r > 2.6
		local top = Props.rock(ctx.f, rng, ctx.at(x, z, -r * 0.35), r, P, collide)
		if collide then ctx.addObs({ x = x, z = z, r = r, h = top }) else ctx.addObs({ x = x, z = z, r = r, virtual = true }) end
		ctx.work(3)
		return true
	end
	while placed < total and tries < total * 15 do
		tries += 1
		local x, z
		if #plats > 0 and rng:chance(0.55) then
			-- al pie de un barranco
			local q = plats[rng:integer(1, #plats)]
			local a = rng:number(0, math.pi * 2)
			local k = 1 + (q.edge + 3) / ((q.rx + q.rz) * 0.5)
			x, z = q.x + math.cos(a) * q.rx * k, q.z + math.sin(a) * q.rz * k
		else
			x, z = rng:number(-HALF, HALF), rng:number(-HALF, HALF)
		end
		local r = (rng:chance(0.3) and rng:number(2.8, 4.6)) or rng:number(1.4, 2.6)
		if put(x, z, r) then
			placed += 1
			-- a veces, un grupito
			if rng:chance(0.25) then
				for _ = 1, rng:integer(1, 2) do
					local a = rng:number(0, math.pi * 2)
					if put(x + math.cos(a) * (r + 2.5), z + math.sin(a) * (r + 2.5), rng:number(1.2, 2.2)) then placed += 1 end
				end
			end
		end
	end
	ctx.stats.rocks = placed
end

return Rocks
