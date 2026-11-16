--!nonstrict
-- MapGen/Vegetation: árboles (en bosquecitos y sueltos), arbustos, flores y el borde natural del mapa.
-- Nunca sobre caminos, agua, la zona de inicio ni los claros de los lugares; solo en pendientes suaves.
local Props = require(script.Parent.Props)

local Vegetation = {}

local Murals=require(script.Parent.ForestMurals)
local function tree(ctx, kind, pos, rng)
	local P, f = ctx.P, ctx.f
	if ctx.mapId=="forest" then
  if kind=="pine" then return Props.pine(f,rng,pos,rng:number(27,45),P) end
  if kind=="oak" then return Props.oak(f,rng,pos,rng:number(20,34),P,false) end
 end
	if kind == "oak" then return Props.oak(f, rng, pos, rng:number(9, 14), P, false)
	elseif kind == "blossom" then return Props.oak(f, rng, pos, rng:number(10, 14), P, true)
	elseif kind == "pine" then return Props.pine(f, rng, pos, rng:number(12, 18), P)
	elseif kind == "palm" then return Props.palm(f, rng, pos, rng:number(10, 14), P)
	elseif kind == "mushroom" then return Props.mushroom(f, rng, pos, rng:number(6, 9), P)
	elseif kind == "cactus" then return Props.cactus(f, rng, pos, P)
	elseif kind == "crystal" then return Props.crystal(f, rng, pos, P)
	else return Props.bush(f, rng, pos, P) end
end
Vegetation.tree = tree

function Vegetation.place(ctx)
	local cfg, P, rng, HM = ctx.cfg, ctx.P, ctx.rng, ctx.HM
	local HALF = ctx.half
	local pathHalf = cfg.terrace.pathWidth * 0.5
	local function okSpot(x, z, r, maxSlope)
		if math.abs(x) > HALF - r - 4 or math.abs(z) > HALF - r - 4 then return false end
		if x * x + z * z < (cfg.spawnClearRadius + 8 + r) ^ 2 then return false end
		if ctx.inKeepClear(x, z, r) or ctx.inWater(x, z, r + 3) then return false end
		if HM:pathDist(x, z) < pathHalf + r + 3 then return false end
		if HM:slope(x, z) > (maxSlope or 0.45) then return false end
		return ctx.free(x, z, r, 3)
	end
	-- 1) árboles: 70% en bosquecitos, 30% sueltos
	local total = math.floor(240 * cfg.vegetationDensity + 0.5)
	local clusters = {}
	for i = 1, 16 do clusters[i] = { rng:number(-HALF + 60, HALF - 60), rng:number(-HALF + 60, HALF - 60), rng:number(30, 70) } end
	local placed, tries = 0, 0
	while placed < total and tries < total * 14 do
		tries += 1
		local x, z
		if rng:chance(0.7) then
			local c = clusters[rng:integer(1, #clusters)]
			local a, d = rng:number(0, math.pi * 2), c[3] * math.sqrt(rng:next())
			x, z = c[1] + math.cos(a) * d, c[2] + math.sin(a) * d
		else
			x, z = rng:number(-HALF, HALF), rng:number(-HALF, HALF)
		end
		local kind = P.trees[rng:integer(1, #P.trees)]
		local r = (kind == "bush") and 2 or 2.4
		if okSpot(x, z, r) then
			local top, tr = tree(ctx, kind, ctx.at(x, z, -0.9), rng)
			if top and top > 0 then ctx.addObs({ x = x, z = z, r = tr or 2, h = top })
			else ctx.addObs({ x = x, z = z, r = 2, virtual = true }) end
			placed += 1
			ctx.work(7)
		end
	end
	ctx.stats.trees = placed
	-- 2) flores (y girasoles en el Bosque): solo en lugares casi planos
	local flowers = math.floor(110 * cfg.flowerDensity + 0.5)
	placed, tries = 0, 0
	while placed < flowers and tries < flowers * 10 do
		tries += 1
		local x, z = rng:number(-HALF + 6, HALF - 6), rng:number(-HALF + 6, HALF - 6)
		if x * x + z * z > (cfg.spawnClearRadius * 0.7) ^ 2 and not ctx.inWater(x, z, 3) and HM:pathDist(x, z) > pathHalf + 1
			and HM:slope(x, z) < 0.25 and ctx.free(x, z, 1.5, 0.5) then
			local pos = ctx.at(x, z, 0)
			if ctx.mapId == "forest" and rng:chance(0.15) then
				for _ = 1, 3 do Props.sunflower(ctx.f, rng, pos + Vector3.new(rng:number(-1.6, 1.6), 0, rng:number(-1.6, 1.6))) end
			else
				Props.flowers(ctx.f, rng, pos, P, rng:integer(3, 5))
			end
			placed += 1
			ctx.work(4)
		end
	end
	ctx.stats.flowers = placed
end

-- borde natural detrás de los muros invisibles (sobre la subida del terreno): enmarca sin encerrar
function Vegetation.border(ctx)
 if ctx.mapId=="forest" then Murals.border(ctx) end
	local P, rng = ctx.P, ctx.rng
	local size = ctx.size
	local step = 30
	local n = 0
	for i = -size / 2, size / 2, step do
		for side = 1, 4 do
			local e = size / 2 + rng:number(6, 20)
			local bx, bz
			if side == 1 then bx, bz = i, -e elseif side == 2 then bx, bz = i, e elseif side == 3 then bx, bz = -e, i else bx, bz = e, i end
			bx += rng:number(-3, 3); bz += rng:number(-3, 3)
			local pos = ctx.at(bx, bz, -0.9)
			local kinds = P.trees
			local kind = kinds[rng:integer(1, #kinds)]
			if kind == "bush" and rng:chance(0.5) then kind = kinds[1] end
			tree(ctx, kind, pos, rng)
			n += 1
			ctx.work(5)
		end
	end
	ctx.stats.border = n
end

return Vegetation
