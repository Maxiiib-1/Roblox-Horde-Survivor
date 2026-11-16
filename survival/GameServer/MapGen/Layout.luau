--!nonstrict
-- MapGen/Layout: RELIEVE y CAMINOS. Desde 2026-10-29 la semilla es la de CADA PARTIDA (y etapa): cada run tiene otro
-- relieve, otras montañas, otras estructuras (cantidad, tipo y lugar al azar, sin nombres), otros lagos y caminos.
-- No crea piezas: devuelve los parámetros de la altura (Heightmap) y los datos que usan los demás módulos.
-- Misma semilla + mismo mapa = mismo resultado (todas las decisiones salen de un SeededRandom propio).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("GameShared")
local SeededRandom = require(Shared.Util.SeededRandom)
local Heightmap = require(Shared.Util.Heightmap)

local Layout = {}
Layout.SALT = { forest = 0, desert = 1777, hidden = 3559 }
Layout.KINDS = { "lookout", "gorge", "grove", "ruins" }

local function dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

function Layout.build(mapId, cfg, seed)
 -- Local copies: biome tuning never mutates shared configuration.
 if mapId=="desert" or mapId=="hidden" then
  cfg=table.clone(cfg);cfg.terrace=table.clone(cfg.terrace)
  if mapId=="desert" then
   cfg.hillCount={3,5};cfg.mountainCount=0;cfg.terraceCount={3,5};cfg.valleyCount={2,3};cfg.lakeCount={0,1}
   cfg.terrace.step=16;cfg.terrace.edge=18;cfg.terrace.rampLength=65;cfg.terrace.pathWidth=18
  else
   cfg.hillCount=0;cfg.mountainCount=0;cfg.terraceCount={12,16};cfg.valleyCount={4,6};cfg.lakeCount=0
   cfg.terrace.step=10;cfg.terrace.edge=8;cfg.terrace.rampLength=64;cfg.terrace.pathWidth=20
  end
 end

	local B = cfg.biomes[mapId] or cfg.biomes.forest
	local salt = Layout.SALT[mapId] or 0
	local rng = SeededRandom.new((seed or cfg.seed) + salt)
	-- cantidades: un número fijo o un rango { mín, máx } que se sortea en cada partida
	local function count(v) if type(v) == "table" then return rng:integer(v[1], v[2]) end return v end
	local size = cfg.size
	local HALF = size / 2 - 6
	local T = cfg.terrace
	local flat = B.flatness or 1
	local hp = {
		biome = mapId, duneAngle = (seed or cfg.seed) % 628 / 100, hills = {}, nAmp = (mapId=="hidden" and .45 or 2.6) * cfg.hillAmp * flat, nScale = 70, seed = rng:number(0, 1000),
		flats = {}, lakes = {}, plateaus = {}, paths = {},
		ramp = T.rampLength, pathW = T.pathWidth, maxH = cfg.maxHeight,
		rim = { HALF, cfg.rim.height, cfg.rim.width },
	}
	-- lomas suaves (colinas transitables)
	for _ = 1, count(cfg.hillCount or 16) do
		table.insert(hp.hills, { rng:number(-HALF, HALF), rng:number(-HALF, HALF), rng:number(3, 9) * cfg.hillAmp * flat, rng:number(40, 90) })
	end
	local plats = {} -- copia legible: { x, z, rx, rz, h }
	local function plateau(x, z, rx, rz, rot, h, edge, cut)
		local P = { x, z, rx, rz, rot, h, edge, rng:number(0, 1000), 0, 0, 0, 0, 0 }
		if cut then P[9], P[10], P[11], P[12], P[13] = cut[1], cut[2], cut[3], cut[4], cut[5] end
		table.insert(hp.plateaus, P)
		table.insert(plats, { x = x, z = z, rx = rx, rz = rz, h = h, edge = edge })
		return P
	end

	-- ===== 1) estructuras: cantidad y tipos al azar, repartidas alrededor del inicio (sin nombre) =====
	local a0 = rng:number(0, math.pi * 2)
	local lms = {}
	local biomeKinds = mapId=="desert" and {"gorge","ruins","gorge","ruins"} or mapId=="hidden" and {"ruins","lookout","ruins","gorge"} or Layout.KINDS
 local kinds = rng:shuffle(table.clone(biomeKinds))
	local nL = count(cfg.landmarkCount or 4)
	while #kinds < nL do table.insert(kinds, biomeKinds[rng:integer(1, #biomeKinds)]) end
	for i = 1, nL do
		local kind = kinds[i]
		local ang = a0 + (i - 1) * math.pi * 2 / nL + rng:number(-0.25, 0.25)
		local d = math.min(rng:number(cfg.landmarkDistance[1], cfg.landmarkDistance[2]), HALF - 120)
		local ux, uz = math.cos(ang), math.sin(ang)
		lms[i] = { kind = kind, x = ux * d, z = uz * d, ux = ux, uz = uz, ang = ang, dist = d }
	end
	for _, lm in ipairs(lms) do
		lm.anchor = { lm.x, lm.z }
		if lm.kind == "lookout" then
			-- mirador: meseta de 3 pisos (cada piso, un escalón); los caminos suben con rampas
			lm.r = 84
			plateau(lm.x, lm.z, 84, 74, rng:number(0, math.pi), T.step, T.edge)
			plateau(lm.x, lm.z, 58, 50, rng:number(0, math.pi), T.step, T.edge)
			plateau(lm.x, lm.z, 33, 30, rng:number(0, math.pi), T.step, T.edge)
			lm.topR = 30
		elseif lm.kind == "gorge" then
			-- cresta larga atravesada por una garganta (el camino pasa por debajo de un arco natural)
			local cutW = 26
			local x1, z1 = lm.x - lm.ux * 46, lm.z - lm.uz * 46
			local x2, z2 = lm.x + lm.ux * 46, lm.z + lm.uz * 46
			plateau(lm.x, lm.z, 128, 22, lm.ang + math.pi / 2, T.step * 2, T.edge, { x1, z1, x2, z2, cutW })
			lm.r = 34
			lm.cutW = cutW
			lm.anchor = { lm.x + lm.ux * 66, lm.z + lm.uz * 66 } -- salida del otro lado
		elseif lm.kind == "grove" then
			lm.r = 54 -- claro rodeado de árboles (se aplana más abajo)
		else -- ruins
			lm.r = 40
			plateau(lm.x, lm.z, 46, 40, rng:number(0, math.pi), T.step, T.edge)
		end
	end

	-- ===== 1b) montañas: cerros altos de 3 o 4 pisos (los caminos suben con rampas) =====
	local mountains = {}
	local nM, mt = count(cfg.mountainCount or 0), 0
	local MC = cfg.mountain or { floors = { 3, 4 }, baseR = { 95, 130 } }
	while #mountains < nM and mt < 300 do
		mt += 1
		local R = rng:number(MC.baseR[1], MC.baseR[2])
		local x, z = rng:number(-HALF + R + 40, HALF - R - 40), rng:number(-HALF + R + 40, HALF - R - 40)
		local ok = dist(x, z, 0, 0) > cfg.spawnClearRadius + R + 80
		for _, lm in ipairs(lms) do if ok and dist(x, z, lm.x, lm.z) < lm.r + R + 40 then ok = false end end
		for _, m in ipairs(mountains) do if ok and dist(x, z, m.x, m.z) < m.r + R + 60 then ok = false end end
		if ok then
			local floors = rng:integer(MC.floors[1], MC.floors[2])
			local rot = rng:number(0, math.pi)
			local ox, oz = 0, 0
			for k = 0, floors - 1 do
				local f = 1 - k / floors * 0.78 -- cada piso más chico, apenas corrido (no es una torta perfecta)
				local rx = R * f
				plateau(x + ox, z + oz, rx, rx * rng:number(0.72, 1), rot + rng:number(-0.6, 0.6), T.step, T.edge)
				ox += rng:number(-0.07, 0.07) * R; oz += rng:number(-0.07, 0.07) * R
			end
			table.insert(mountains, { x = x, z = z, r = R, floors = floors })
		end
	end

	-- ===== 2) mesetas sueltas (algunas de dos pisos) =====
	local placed, tries = 0, 0
	local nTerr = count(cfg.terraceCount)
	while placed < nTerr and tries < 500 do
		tries += 1
		local rx = mapId=="desert" and rng:number(105,160) or mapId=="hidden" and rng:number(45,85) or rng:number(40,95)
		local rz = rx * (mapId=="desert" and rng:number(.22,.38) or mapId=="hidden" and rng:number(.8,1.2) or rng:number(.55,1))
		local x, z = rng:number(-HALF + rx + 30, HALF - rx - 30), rng:number(-HALF + rx + 30, HALF - rx - 30)
		local ok = dist(x, z, 0, 0) > cfg.spawnClearRadius + rx + 70
		for _, lm in ipairs(lms) do
			if ok and dist(x, z, lm.x, lm.z) < lm.r + rx + 50 then ok = false end
		end
		for _, q in ipairs(plats) do -- se pueden tocar, pero no apilarse por completo
			if ok and dist(x, z, q.x, q.z) < math.max(rx, q.rx) * 0.9 then ok = false end
		end
		if ok then
			local rot = rng:number(0, math.pi)
			plateau(x, z, rx, rz, rot, T.step, T.edge)
			if rng:chance(0.4) then
				plateau(x + rng:number(-0.2, 0.2) * rx, z + rng:number(-0.2, 0.2) * rz, rx * 0.55, rz * 0.55, rot + rng:number(-0.4, 0.4), T.step, T.edge)
			end
			placed += 1
		end
	end

	-- ===== 3) valles (hondonadas suaves) =====
	placed, tries = 0, 0
	local nVal = count(cfg.valleyCount)
	while placed < nVal and tries < 300 do
		tries += 1
		local r = rng:number(60, 90)
		local x, z = rng:number(-HALF + r + 40, HALF - r - 40), rng:number(-HALF + r + 40, HALF - r - 40)
		local ok = dist(x, z, 0, 0) > cfg.spawnClearRadius + r + 60
		for _, lm in ipairs(lms) do if ok and dist(x, z, lm.x, lm.z) < lm.r + r + 50 then ok = false end end
		for _, q in ipairs(plats) do if ok and dist(x, z, q.x, q.z) < math.max(q.rx, q.rz) + r + 20 then ok = false end end
		if ok then
			plateau(x, z, r, r * rng:number(0.7, 1), rng:number(0, math.pi), -T.step * 0.9, 34)
			placed += 1
		end
	end

	-- ===== 4) caminos: del inicio a cada lugar y un anillo que une los lugares entre sí =====
	local routes = {}
	local function addSeg(ax, az, bx, bz) table.insert(hp.paths, { ax, az, bx, bz }) end
	local function route(ax, az, bx, bz, bend, label)
		local pts = { { ax, az } }
		local dx, dz = bx - ax, bz - az
		local L = math.max(1, math.sqrt(dx * dx + dz * dz))
		local px, pz = -dz / L, dx / L
		local k = (L > 260) and 2 or 1
		for i = 1, k do
			local t = i / (k + 1)
			local off = rng:number(-bend, bend)
			table.insert(pts, { ax + dx * t + px * off, az + dz * t + pz * off })
		end
		table.insert(pts, { bx, bz })
		for i = 1, #pts - 1 do addSeg(pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2]) end
		table.insert(routes, { pts = pts, label = label })
		return pts
	end
	local r0 = cfg.spawnClearRadius * 0.7
	for _, lm in ipairs(lms) do
		local sx, sz = lm.ux * r0, lm.uz * r0
		if lm.kind == "gorge" then
			-- el último tramo entra recto por la garganta y sale del otro lado (no es un callejón sin salida)
			local ex, ez = lm.x - lm.ux * 60, lm.z - lm.uz * 60
			local pts = route(sx, sz, ex, ez, 45, lm.kind)
			addSeg(ex, ez, lm.anchor[1], lm.anchor[2])
			table.insert(pts, { lm.x, lm.z })
			table.insert(pts, { lm.anchor[1], lm.anchor[2] })
		else
			route(sx, sz, lm.x, lm.z, 45, lm.kind)
		end
		lm.start = { sx, sz }
	end
	for i, lm in ipairs(lms) do
		local nx = lms[i % #lms + 1]
		route(lm.anchor[1], lm.anchor[2], nx.anchor[1], nx.anchor[2], 70, "ring")
	end
	-- un camino a la cima de cada montaña (en cada piso queda una rampa)
	for _, m in ipairs(mountains) do
		local d = math.max(1, math.sqrt(m.x * m.x + m.z * m.z))
		route(m.x / d * r0, m.z / d * r0, m.x, m.z, 40, "mountain")
	end

	-- ===== 5) lagos (lejos de mesetas, lugares, caminos e inicio) =====
	if mapId=="hidden" then hp.rim={HALF,0,cfg.rim.width} end
 local tmp = Heightmap.new(hp)
	local water = {}
	placed, tries = 0, 0
	local nLake = count(cfg.lakeCount)
	while placed < nLake and tries < 300 do
		tries += 1
		local R = rng:number(28, 44)
		local cx, cz = rng:number(-HALF + R + 50, HALF - R - 50), rng:number(-HALF + R + 50, HALF - R - 50)
		local ok = dist(cx, cz, 0, 0) > 150 and tmp:pathDist(cx, cz) > R * 1.6 + 16
		for _, lm in ipairs(lms) do if ok and dist(cx, cz, lm.x, lm.z) < lm.r + R + 70 then ok = false end end
		for _, q in ipairs(plats) do if ok and dist(cx, cz, q.x, q.z) < math.max(q.rx, q.rz) + q.edge + R * 1.6 + 30 then ok = false end end
		for _, w in ipairs(water) do if ok and dist(cx, cz, w.x, w.z) < w.r + R * 2 + 60 then ok = false end end
		if ok then
			local discs = { { cx, cz, R } }
			for _ = 1, rng:integer(2, 3) do
				local a = rng:number(0, math.pi * 2)
				local rr = R * rng:number(0.5, 0.8)
				table.insert(discs, { cx + math.cos(a) * R * 0.75, cz + math.sin(a) * R * 0.75, rr })
			end
			local level = math.min(tmp:relief(cx, cz), 6)
			local floorY = math.floor((level - 2.6) / 4) * 4 - 4 -- un vóxel más hondo: el agua queda por debajo de la orilla
			for _, d in ipairs(discs) do
				table.insert(hp.lakes, { d[1], d[2], d[3], floorY, floorY + 4 })
				table.insert(water, { x = d[1], z = d[2], r = d[3] })
			end
			placed += 1
		end
	end

	-- ===== 6) zonas planas fijas: inicio y claro de la arboleda =====
	local clear = cfg.spawnClearRadius
	table.insert(hp.flats, { 0, 0, clear * 0.6, clear * 0.6, tmp:relief(0, 0) })
	for _, lm in ipairs(lms) do
		if lm.kind == "grove" then table.insert(hp.flats, { lm.x, lm.z, 46, 20, tmp:relief(lm.x, lm.z) }) end
	end

	return { params = hp, landmarks = lms, mountains = mountains, routes = routes, plateaus = plats, water = water, half = HALF, size = size, biome = B }
end

return Layout
