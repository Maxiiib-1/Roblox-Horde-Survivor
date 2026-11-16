--!nonstrict
-- MapGen/Details: detalles para descubrir junto a los caminos (mojones, troncos, hongos, flores) y carteles
-- que indican cómo llegar a cada lugar. Solo decoración: no colisionan y no dan premios.
local Props = require(script.Parent.Props)

local Details = {}

local function along(pts, every, fn)
	local carry = every * 0.5
	for i = 1, #pts - 1 do
		local ax, az, bx, bz = pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2]
		local dx, dz = bx - ax, bz - az
		local L = math.sqrt(dx * dx + dz * dz)
		if L > 0.01 then
			local ux, uz = dx / L, dz / L
			local s = carry
			while s < L do
				fn(ax + ux * s, az + uz * s, ux, uz)
				s += every
			end
			carry = s - L
		end
	end
end

function Details.place(ctx)
	local cfg, P, rng, HM = ctx.cfg, ctx.P, ctx.rng, ctx.HM
	local pathHalf = cfg.terrace.pathWidth * 0.5
	local every = 60 / math.max(0.2, cfg.detailDensity)
	local kinds
	if ctx.mapId == "desert" then kinds = { "cairn", "flowers", "cairn", "rock" }
	elseif ctx.mapId == "hidden" then kinds = { "shrooms", "cairn", "shrooms", "rock" }
	else kinds = { "cairn", "flowers", "log", "stump", "shrooms", "sunflower" } end
	local n, side = 0, 1
	for _, route in ipairs(ctx.layout.routes) do
		along(route.pts, every, function(x, z, ux, uz)
			side = -side
			local off = pathHalf + rng:number(2.5, 5)
			local px, pz = x - uz * off * side, z + ux * off * side
			if px * px + pz * pz < (cfg.spawnClearRadius + 4) ^ 2 or ctx.inWater(px, pz, 3) or not ctx.free(px, pz, 1.5, 1) then return end
			if HM:slope(px, pz) > 0.45 then return end
			local kind = kinds[rng:integer(1, #kinds)]
			local pos = ctx.at(px, pz, 0)
			if kind == "cairn" then Props.cairn(ctx.f, rng, pos, P)
			elseif kind == "flowers" then Props.flowers(ctx.f, rng, pos, P, 4)
			elseif kind == "log" then Props.log(ctx.f, rng, pos, P)
			elseif kind == "stump" then Props.stump(ctx.f, rng, pos, P)
			elseif kind == "shrooms" then Props.smallShrooms(ctx.f, rng, pos, P)
			elseif kind == "sunflower" then Props.sunflower(ctx.f, rng, pos)
			else Props.rock(ctx.f, rng, ctx.at(px, pz, -0.4), rng:number(1, 1.6), P, false) end
			ctx.addObs({ x = px, z = pz, r = 1.5, virtual = true })
			n += 1
			ctx.work(3)
		end)
	end
	ctx.stats.details = n
	-- (2026-10-29) sin carteles con nombres: las estructuras ya no tienen nombre
end

return Details
