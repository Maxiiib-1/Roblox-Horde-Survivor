--!nonstrict
-- MapGen/Landmarks: los 4 LUGARES reconocibles (siluetas propias, espacio para combatir, camino que llega).
--   lookout = mirador de 3 pisos con bandera / obelisco / aguja de cristal en la cima
--   gorge   = garganta que atraviesa una cresta, con un arco de piedra redondeado encima (paso corto bajo roca)
--   grove   = claro rodeado de árboles de colores con un árbol gigante en el centro
--   ruins   = ruinas pequeñas sobre una meseta baja: muros bajos con 4 entradas, columnas y un arco
-- El relieve (pisos, cresta, claro) ya lo pone Layout; aquí solo van las piezas. Sin premios ni economía.
local Props = require(script.Parent.Props)
local BL, BALL, CYL = Props.BL, Props.BALL, Props.CYL
local mk, c3 = Props.mk, Props.c3
local SLATE, NEON, WOOD, GRASS, SM = Enum.Material.Slate, Enum.Material.Neon, Enum.Material.Wood, Enum.Material.Grass, Enum.Material.SmoothPlastic

local Landmarks = {}

local function V(x, y, z) return Vector3.new(x, y, z) end

-- ===== Mirador =====
local function lookout(ctx, lm)
	local P, rng, f, HM = ctx.P, ctx.rng, ctx.f, ctx.HM
	local x, z = lm.x, lm.z
	-- corona de rocas redondeadas en el borde de la cima (deja huecos donde llegan los caminos)
	local n = 7
	for i = 1, n do
		local a = lm.ang + math.pi + (i - 0.5) * 2 * math.pi / n
		local rx, rz = x + math.cos(a) * 27, z + math.sin(a) * 27
		if HM:pathDist(rx, rz) > 8 then
			local r = rng:number(1.8, 2.7)
			local h = Props.rock(f, rng, ctx.at(rx, rz, -0.7), r, P, true)
			ctx.addObs({ x = rx, z = rz, r = r, h = h })
		end
	end
	-- faro visible desde lejos, corrido hacia el lado opuesto al inicio (el centro queda libre para pelear)
	local bx, bz = x + lm.ux * 11, z + lm.uz * 11
	local b = ctx.at(bx, bz, -0.6)
	local tx, tz = -lm.uz, lm.ux
	if P.glow then
		local col = c3(P.blossom[3])
		local spire = mk(f, "LookoutSpire", BL, V(3, 18, 3), CFrame.new(b + V(0, 8.5, 0)) * CFrame.Angles(0.06, 0.4, 0.05), col, NEON, true, false)
		mk(f, "LookoutSpire", BL, V(2, 11, 2), CFrame.new(b + V(2.2, 5, 1)) * CFrame.Angles(0.25, 1.1, -0.2), c3(P.blossom[2]), NEON, false, false)
		mk(f, "LookoutSpire", BL, V(1.6, 8, 1.6), CFrame.new(b + V(-2, 3.6, -1)) * CFrame.Angles(-0.3, 0.3, 0.25), c3(P.blossom[1]), NEON, false, false)
		local l = Instance.new("PointLight"); l.Color = col; l.Range = 24; l.Brightness = 2; l.Parent = spire
	elseif ctx.mapId == "desert" then
		mk(f, "Obelisk", BL, V(5.5, 1.6, 5.5), CFrame.new(b + V(0, 0.8, 0)), c3(P.stoneDark), SLATE, true, true)
		mk(f, "Obelisk", BL, V(3, 18, 3), CFrame.new(b + V(0, 10.5, 0)), c3(P.stone), SLATE, true, true)
		mk(f, "ObeliskTip", BALL, V(2.2, 2.2, 2.2), CFrame.new(b + V(0, 20.4, 0)), Color3.fromRGB(255, 205, 60), NEON, false, false)
	else
		-- bandera con mástil y una bola dorada arriba
		Props.vertical(f, "FlagPole", b + V(0, 11, 0), 22, 0.6, Color3.fromRGB(236, 230, 214), WOOD, true, true)
		local flagC = b + V(0, 19.2, 0) + V(tx, 0, tz) * 3.7
		mk(f, "Flag", BL, V(0.25, 4.2, 7), CFrame.lookAt(flagC, flagC + V(tx, 0, tz)), Color3.fromRGB(252, 146, 40), SM, false, false) -- banderín naranja liso (sin parecerse a ninguna bandera real)
		mk(f, "FlagTop", BALL, V(1.6, 1.6, 1.6), CFrame.new(b + V(0, 22.4, 0)), Color3.fromRGB(255, 205, 60), NEON, false, false)
		-- catalejo mirando hacia afuera (detalle)
		local sx, sz = x + lm.ux * 16 + tx * 6, z + lm.uz * 16 + tz * 6
		local s = ctx.at(sx, sz, -0.2)
		for k = 0, 2 do
			local a = k * 2.094
			local foot = s + V(math.cos(a) * 0.9, 0, math.sin(a) * 0.9)
			local top = s + V(0, 3.2, 0)
			mk(f, "TelescopeLeg", BL, V(0.18, (top - foot).Magnitude, 0.18), CFrame.lookAt((foot + top) / 2, top) * CFrame.Angles(math.pi / 2, 0, 0), Color3.fromRGB(110, 74, 44), WOOD, false, false)
		end
		local tube = s + V(0, 3.5, 0)
		mk(f, "Telescope", CYL, V(3.2, 0.7, 0.7), CFrame.lookAt(tube, tube + V(lm.ux, 0.35, lm.uz)) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(200, 160, 60), Enum.Material.Metal, false, false)
	end
	ctx.addObs({ x = bx, z = bz, r = 1.8, h = 3 })
	Props.nameTag(f, b + V(0, 26, 0), lm.name)
	table.insert(ctx.keepClear, { x, z, 32 })
end

-- ===== Garganta con arco de piedra =====
local function gorge(ctx, lm)
	local P, rng, f, HM = ctx.P, ctx.rng, ctx.f, ctx.HM
	local x, z = lm.x, lm.z
	local tx, tz = -lm.uz, lm.ux -- eje de la cresta
	local floorY = HM:get(x, z)
	local wallY = math.max(HM:get(x + tx * 21, z + tz * 21), HM:get(x - tx * 21, z - tz * 21))
	local baseY = math.max(wallY - 1, floorY + 13.5)
	local stone = c3(P.rock)
	for i = 0, 8 do
		local t = i / 8
		local o = -22 + 44 * t
		local s = math.sin(math.pi * t)
		local r = 5 - s * 0.8
		local pos = ctx.origin + V(x + tx * o, baseY + s * 3, z + tz * o)
		mk(f, "StoneArch", BALL, V(r * 2, r * 2, r * 2), CFrame.new(pos), stone:Lerp(Color3.new(1, 1, 1), (i % 2) * 0.06), SLATE, true, true)
		if P.moss and i >= 2 and i <= 6 then
			mk(f, "ArchMoss", BALL, V(r * 1.3, r * 1.3, r * 1.3), CFrame.new(pos + V(0, r * 0.75, 0)), c3(P.moss), GRASS, false, false)
		elseif P.glow and i % 3 == 1 then
			mk(f, "ArchCrystal", BL, V(0.8, 3.2, 0.8), CFrame.new(pos + V(0, -r * 0.9, 0)) * CFrame.Angles(0, i, 0.2), c3(P.blossom[2]), NEON, false, false)
		end
	end
	-- rocas chicas contra las paredes de la garganta y hongos en las dos entradas (decoración, no bloquea)
	for k = -2, 2 do
		for _, side in ipairs({ -1, 1 }) do
			local px, pz = x + lm.ux * k * 13 + tx * side * 15, z + lm.uz * k * 13 + tz * side * 15
			if rng:chance(0.7) then Props.rock(f, rng, ctx.at(px, pz, -0.5), rng:number(1.1, 1.7), P, false) end
		end
	end
	for _, s in ipairs({ -1, 1 }) do
		local px, pz = x + lm.ux * s * 36 + tx * 10, z + lm.uz * s * 36 + tz * 10
		Props.smallShrooms(f, rng, ctx.at(px, pz, 0), P)
	end
	Props.nameTag(f, ctx.origin + V(x, baseY + 9, z), lm.name)
	for k = -5, 5 do table.insert(ctx.keepClear, { x + lm.ux * k * 12, z + lm.uz * k * 12, 12 }) end
end

-- ===== Arboleda / oasis / bosque de hongos =====
local function grove(ctx, lm)
	local P, rng, f, HM = ctx.P, ctx.rng, ctx.f, ctx.HM
	local x, z = lm.x, lm.z
	local c = ctx.at(x, z, -1)
	-- árbol gigante (o palmera / hongo) en el centro
	if ctx.mapId == "desert" then
		local top = Props.palm(f, rng, c, 22, P)
		ctx.addObs({ x = x, z = z, r = 2, h = top })
	elseif P.glow then
		local top = Props.mushroom(f, rng, c, 18, P, c3(P.blossom[1]))
		ctx.addObs({ x = x, z = z, r = 3.4, h = top })
	else
		Props.vertical(f, "GiantTrunk", c + V(0, 11, 0), 24, 4.4, c3(P.trunk), WOOD, true, true)
		local cc = c + V(0, 25, 0)
		local cols = { c3(P.blossom[1]), c3(P.blossom[2]), c3(P.blossom[3]), c3(P.leaves[3]), c3(P.blossom[1]):Lerp(Color3.new(1, 1, 1), 0.25), c3(P.blossom[4] or P.blossom[1]) }
		mk(f, "GiantLeaves", BALL, V(16, 16, 16), CFrame.new(cc), cols[1], SM, false, true)
		for i = 1, 6 do
			local a = i * 1.047 + 0.3
			local s = rng:number(9, 12)
			mk(f, "GiantLeaves", BALL, V(s, s, s), CFrame.new(cc + V(math.cos(a) * 7.5, rng:number(-3, 3), math.sin(a) * 7.5)), cols[i], SM, false, i <= 3)
		end
		ctx.addObs({ x = x, z = z, r = 3, h = 22 })
	end
	-- círculo de piedritas alrededor del árbol
	for i = 1, 8 do
		local a = i * 0.785
		local px, pz = x + math.cos(a) * 8.5, z + math.sin(a) * 8.5
		mk(f, "GroveStone", BALL, V(1.4, 1.4, 1.4), CFrame.new(ctx.at(px, pz, 0.3)), c3(P.stone), SLATE, false, false)
	end
	-- anillo de árboles de colores (deja libre por donde entran los caminos)
	for i = 1, 12 do
		local a = i * (math.pi * 2 / 12) + rng:number(-0.08, 0.08)
		local px, pz = x + math.cos(a) * 46, z + math.sin(a) * 46
		if HM:pathDist(px, pz) > ctx.cfg.terrace.pathWidth * 0.5 + 6 and ctx.free(px, pz, 2.4, 1) then
			local pos = ctx.at(px, pz, -0.8)
			local top, r
			if ctx.mapId == "desert" then top, r = Props.palm(f, rng, pos, rng:number(11, 15), P)
			elseif P.glow then top, r = Props.mushroom(f, rng, pos, rng:number(8, 11), P)
			else top, r = Props.oak(f, rng, pos, rng:number(12, 15), P, true) end
			ctx.addObs({ x = px, z = pz, r = r, h = top })
		end
	end
	-- flores dentro del claro
	for _ = 1, 10 do
		local a, d = rng:number(0, math.pi * 2), rng:number(13, 36)
		Props.flowers(f, rng, ctx.at(x + math.cos(a) * d, z + math.sin(a) * d, 0), P, 5)
	end
	Props.nameTag(f, c + V(0, 36, 0), lm.name)
	table.insert(ctx.keepClear, { x, z, 41 })
end

-- ===== Ruinas =====
local function ruins(ctx, lm)
	local P, rng, f = ctx.P, ctx.rng, ctx.f
	local x, z = lm.x, lm.z
	local center = ctx.at(x, z, 0)
	local frame = CFrame.lookAt(center, center - V(lm.ux, 0, lm.uz)) -- el frente mira hacia el inicio
	local stone, dark = c3(P.stone), c3(P.stoneDark)
	local function world(lx, lz) local p = frame * V(lx, 0, lz); return p.X - ctx.origin.X, p.Z - ctx.origin.Z end
	local function ground(lx, lz) local wx, wz = world(lx, lz); return ctx.at(wx, wz, 0) end
	-- muros bajos (= 3,6 studs: se saltan) con una entrada ancha en cada lado
	for side = 0, 3 do
		local rot = CFrame.Angles(0, side * math.pi / 2, 0)
		for _, lat in ipairs({ -11, 11 }) do
			if rng:chance(0.85) then
				local h = rng:number(1.6, 3.6)
				local off = (rot * V(lat, 0, -17))
				local g = ground(off.X, off.Z)
				local cf = CFrame.new(g + V(0, h / 2 - 0.3, 0)) * (frame - frame.Position) * rot * CFrame.Angles(0, 0, rng:number(-0.04, 0.04))
				mk(f, "RuinWall", BL, V(9, h, 1.8), cf, (lat < 0) and stone or stone:Lerp(dark, 0.4), SLATE, true, true)
				if P.moss then mk(f, "RuinMoss", BL, V(9.1, 0.35, 1.9), cf * CFrame.new(0, h / 2, 0), c3(P.moss), GRASS, false, false) end
				for k = -1, 1 do
					local o2 = rot * V(lat + k * 3.2, 0, -17)
					local wx, wz = world(o2.X, o2.Z)
					ctx.addObs({ x = wx, z = wz, r = 1.6, h = h })
				end
			end
		end
	end
	-- columnas (algunas rotas)
	local heights = { 13, 6, 10, 4 }
	for i = #heights, 2, -1 do local j = rng:integer(1, i); heights[i], heights[j] = heights[j], heights[i] end
	for i, c in ipairs({ { -9, -9 }, { 9, -9 }, { -9, 9 }, { 9, 9 } }) do
		local h = heights[i]
		local g = ground(c[1], c[2])
		mk(f, "ColumnBase", BL, V(3.6, 1, 3.6), CFrame.new(g + V(0, 0.2, 0)), dark, SLATE, true, false)
		Props.vertical(f, "Column", g + V(0, h / 2 + 0.6, 0), h, 2.6, stone, SLATE, true, true)
		if h > 8 then mk(f, "ColumnCap", BL, V(3.4, 0.9, 3.4), CFrame.new(g + V(0, h + 1, 0)), dark, SLATE, true, false) end
		if P.glow then mk(f, "Rune", BL, V(0.2, h * 0.6, 0.6), CFrame.new(g + V(1.32, h * 0.5, 0)), c3(P.blossom[2]), NEON, false, false) end
		local wx, wz = world(c[1], c[2])
		ctx.addObs({ x = wx, z = wz, r = 1.9, h = h + 1 })
	end
	-- arco del fondo (silueta que se ve de lejos), por fuera del muro trasero
	for _, lat in ipairs({ -5.5, 5.5 }) do
		local g = ground(lat, 22)
		Props.vertical(f, "ArchColumn", g + V(0, 7.6, 0), 15, 2.6, stone, SLATE, true, true)
		local wx, wz = world(lat, 22)
		ctx.addObs({ x = wx, z = wz, r = 1.9, h = 15 })
	end
	local gm = ground(0, 22)
	mk(f, "ArchLintel", BL, V(14, 2, 2.8), CFrame.new(gm + V(0, 16, 0)) * (frame - frame.Position), dark, SLATE, true, true)
	-- columna caída y escombros
	local fg = ground(6, 4)
	mk(f, "FallenColumn", CYL, V(9, 2.4, 2.4), CFrame.new(fg + V(0, 1.1, 0)) * (frame - frame.Position) * CFrame.Angles(0, 0.6, 0), stone, SLATE, true, true)
	local fx, fz = world(6, 4)
	ctx.addObs({ x = fx, z = fz, r = 2.6, h = 2.4 })
	for _ = 1, 6 do
		local g = ground(rng:number(-14, 14), rng:number(-14, 14))
		mk(f, "Rubble", BL, V(rng:number(0.8, 1.6), rng:number(0.5, 1), rng:number(0.8, 1.6)), CFrame.new(g + V(0, 0.3, 0)) * CFrame.Angles(rng:number(0, 0.4), rng:number(0, 6), rng:number(0, 0.4)), dark, SLATE, false, false)
	end
	Props.nameTag(f, gm + V(0, 22, 0), lm.name)
	table.insert(ctx.keepClear, { x, z, 30 })
end

local BUILD = { lookout = lookout, gorge = gorge, grove = grove, ruins = ruins }

function Landmarks.build(ctx, landmarks)
	for _, lm in ipairs(landmarks) do
		local fn = BUILD[lm.kind]
		if fn then fn(ctx, lm) end
		ctx.work(40)
	end
end

return Landmarks
