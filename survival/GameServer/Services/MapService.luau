--!nonstrict
-- Services/MapService: arma cada etapa del mapa.
--   RELIEVE fijo (semilla de MapGenConfig): mesetas en terrazas, valles, lagos, caminos, 4 lugares, árboles, rocas,
--   flores, detalles y montañas del horizonte (módulos en GameServer/MapGen).
--   OBJETOS variables (semilla de la run): portal del jefe, santuarios, cofres, Moai, altar, estatuas y teteras.
-- Devuelve un objeto de mapa con obstáculos lógicos (círculos) para la navegación de enemigos.
-- Genera por lotes (cede frames con task.wait) para no congelar el servidor ni Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("GameShared")
local Maps = require(Shared.Catalogs.Maps)
local GameConfig = require(Shared.Config.GameConfig)
local BossConfig = require(Shared.Config.BossConfig)
local MapGenConfig = require(Shared.Config.MapGenConfig)
local OC = require(Shared.Config.MapObjectsConfig) -- 2026-11-06: cantidades y reglas de los objetos del mapa (un solo lugar)
local Brainrots = require(Shared.Visuals.Brainrots)
local Heightmap = require(Shared.Util.Heightmap)
local SeededRandom = require(Shared.Util.SeededRandom)
local MapGen = script.Parent.Parent:WaitForChild("MapGen")
local Layout = require(MapGen.Layout)
local Props = require(MapGen.Props)
local Occupancy = require(MapGen.Occupancy)
local Landmarks = require(MapGen.Landmarks)
local Vegetation = require(MapGen.Vegetation)
local Rocks = require(MapGen.Rocks)
local Details = require(MapGen.Details)
local Horizon = require(MapGen.Horizon)
local TerrainWriter = require(MapGen.TerrainWriter)
local Terrain = workspace.Terrain

local MapService = {}
MapService.TERRAIN_SINK = TerrainWriter.SINK

local MAX_HALF = MapGenConfig.size / 2 - 6
local GRID = 40 -- celda de la rejilla espacial de obstáculos pequeños (enemigos)
MapService.WATER_SLOW = 0.55 -- multiplicador de velocidad dentro del agua (jugador y enemigos)

-- pieza de los objetos interactivos (portal, santuarios, cofres…)
local function mk(parent, name, shape, size, cf, color, material, canCollide)
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape or Enum.PartType.Block
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = canCollide ~= false
	p.CanQuery = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function dist2(ax, az, bx, bz)
	local dx, dz = ax - bx, az - bz
	return math.sqrt(dx * dx + dz * dz)
end

function MapService.generate(opts)
	-- opts: mapId, mapLevel, stage, seed, origin(Vector3), parent(Instance), rng(SeededRandom), noYield
	local t0 = os.clock()
	local cfg = MapGenConfig
	local def = Maps.byId[opts.mapId] or Maps.byId.forest
	local mapId = def.id
	local rng = opts.rng -- variable: objetos de esta partida
	local origin = opts.origin
	local folder = Instance.new("Folder")
	folder.Name = "Stage_" .. tostring(opts.stage)
 folder:SetAttribute("BiomeOrigin",origin)
 folder:SetAttribute("BiomeId",mapId)
 game:GetService("CollectionService"):AddTag(folder,"BiomeStage")

	-- ===== 1) RELIEVE de ESTA partida y etapa: montañas, mesetas, valles, lagos, caminos y estructuras (MapGen/Layout) =====
	local mapSeed = math.floor((opts.seed or cfg.seed) + (opts.stage or 1) * 7919) % 2000000000
	local layout = Layout.build(mapId, cfg, mapSeed)
	local B = layout.biome
	local size, HALF = layout.size, layout.half
	local hp = layout.params
	local HM = Heightmap.new(hp)
	local spawnLevel = HM:get(0, 0)
	local map = {
		folder = folder, def = def, origin = origin, half = HALF, obstacles = {}, items = {},
		stage = opts.stage, size = size, heightParams = hp, heightmap = HM, mountains = {},
	}
	map.height = function(x, z) return HM:get(x, z) end
	local function at(x, z, dy) return origin + Vector3.new(x, HM:get(x, z) + (dy or 0), z) end

	-- cede un frame cada `batch.parts` piezas (o al forzar)
	local budget = 0
	local function work(n, force)
		if opts.noYield then return end
		budget += (n or 0)
		if force or budget >= cfg.batch.parts then budget = 0; task.wait() end
	end

	-- obstáculos (lógicos para los enemigos) + rejilla de ocupación (para colocar sin encimar)
	local occ = Occupancy.new(16)
	local function addObs(o)
		table.insert(map.obstacles, o)
		occ:add(o)
	end
	local function free(x, z, r, margin)
		if math.abs(x) > HALF - r or math.abs(z) > HALF - r then return false end
		return occ:free(x, z, r, margin or 2)
	end
	local keepClear = {}
	local function inKeepClear(x, z, r)
		for _, k in ipairs(keepClear) do
			local dx, dz = x - k[1], z - k[2]
			if dx * dx + dz * dz < (k[3] + r) ^ 2 then return true end
		end
		return false
	end
	map.water = {}
	for _, w in ipairs(layout.water) do table.insert(map.water, w) end
	if #map.water > 0 then map.waterColor = Props.c3(B.water) end
	local function inWater(x, z, pad)
		for _, w in ipairs(map.water) do
			local dx, dz = x - w.x, z - w.z
			if dx * dx + dz * dz < (w.r + (pad or 0)) ^ 2 then return true end
		end
		return false
	end
	-- reservas: inicio despejado y agua (nada se coloca encima; los enemigos sí cruzan)
	addObs({ x = 0, z = 0, r = cfg.spawnClearRadius, virtual = true })
	for _, w in ipairs(map.water) do addObs({ x = w.x, z = w.z, r = w.r, virtual = true, water = true }) end

	-- límite físico: muros invisibles altos (no se pueden saltar)
	local wallH = 120
	for _, w in ipairs({
		{ Vector3.new(size + 4, wallH, 2), Vector3.new(0, wallH / 2, size / 2 + 1) },
		{ Vector3.new(size + 4, wallH, 2), Vector3.new(0, wallH / 2, -size / 2 - 1) },
		{ Vector3.new(2, wallH, size + 4), Vector3.new(size / 2 + 1, wallH / 2, 0) },
		{ Vector3.new(2, wallH, size + 4), Vector3.new(-size / 2 - 1, wallH / 2, 0) },
	}) do
		local p = mk(folder, "Boundary", Enum.PartType.Block, w[1], CFrame.new(origin + w[2]), def.fog, Enum.Material.SmoothPlastic)
		p.Transparency = 1
		p.CastShadow = false
	end

	-- ===== 2) piezas fijas por capas (cada una en su carpeta; se publican por lotes al final) =====
	local stats = {}
	local function ctxFor(name, salt)
		local f = Instance.new("Folder")
		f.Name = name
		return {
			f = f, HM = HM, origin = origin, P = B, cfg = cfg, mapId = mapId, half = HALF, size = size, layout = layout,
			rng = SeededRandom.new(mapSeed + (Layout.SALT[mapId] or 0) + salt),
			at = at, addObs = addObs, free = free, keepClear = keepClear, inKeepClear = inKeepClear, inWater = inWater,
			work = work, stats = stats,
		}
	end
	local partsBefore = Props.count
	local cLand = ctxFor("Landmarks", 101)
	Landmarks.build(cLand, layout.landmarks)
 require(MapGen.BiomeScenery).ruins(cLand)
	local cRock = ctxFor("Rocks", 202)
	Rocks.place(cRock)
	local cVeg = ctxFor("Vegetation", 303)
	Vegetation.place(cVeg)
	local cDet = ctxFor("Details", 404)
	Details.place(cDet)
	local cBor = ctxFor("Border", 505)
	if mapId == "forest" then Vegetation.border(cBor) end
	local cHor = ctxFor("Horizon", 606)
	Horizon.build(cHor)
	stats.fixedParts = Props.count - partsBefore
	local layers = { cLand.f, cRock.f, cVeg.f, cDet.f, cBor.f, cHor.f }

	-- ===== 3) OBJETOS variables de esta partida =====
	local BL, CYL = Enum.PartType.Block, Enum.PartType.Cylinder
	-- busca un punto libre y casi plano entre rMin y rMax del inicio
	local function sample(rMin, rMax, radius, margin, minFromSpawn)
		for _ = 1, 120 do
			local ang = rng:number(0, math.pi * 2)
			local d = rng:number(rMin, rMax)
			local x, z = math.cos(ang) * d, math.sin(ang) * d
			if dist2(x, z, 0, 0) >= (minFromSpawn or 0) and free(x, z, radius, margin) and not inWater(x,z,radius+4) and HM:slope(x, z) < 0.25 then
				return x, z
			end
		end
		return nil, nil
	end

	-- 2026-11-06: COLOCADOR CENTRAL de objetos (MapObjectsConfig). Sortea puntos uniformes en TODO el mapa (no solo cerca
	-- del inicio), dentro de los límites, lejos del agua, de pendientes fuertes, de obstáculos y del punto de aparición,
	-- y respeta la distancia mínima entre objetos (importantes entre sí, cofres y vasijas). Si no encuentra lugar, baja
	-- las distancias de a 20% (hasta 6 rondas) antes de descartar el objeto. Usa el generador de la partida (semilla).
	local placed = {}
	map.objectCounts = {}
	map.placeFails = {}
	local SP = OC.spacing
	local function spacingOk(x, z, cat, k)
		for _, p in ipairs(placed) do
			local need
			if cat == "important" and p.cat == "important" then need = SP.important
			elseif cat == "minor" or p.cat == "minor" then need = SP.minor
			else need = SP.secondary end
			need *= k
			local dx, dz = x - p.x, z - p.z
			if dx * dx + dz * dz < need * need then return false end
		end
		return true
	end
	local function place(kind)
		local cat = OC.category[kind] or "secondary"
		local rad = OC.radius[kind] or 3
		local k = 1
		local lim = HALF - SP.edge
		for _ = 1, OC.relax.rounds do
			for _ = 1, OC.relax.attempts do
				local x, z = rng:number(-lim, lim), rng:number(-lim, lim)
				if dist2(x, z, 0, 0) >= SP.player * math.max(0.5, k) and free(x, z, rad, SP.obstacle) and not inWater(x, z, rad + OC.waterPad)
					and HM:slope(x, z) < OC.maxSlope and spacingOk(x, z, cat, k) then
					table.insert(placed, { x = x, z = z, cat = cat })
					return x, z
				end
			end
			k *= OC.relax.factor
		end
		map.placeFails[kind] = (map.placeFails[kind] or 0) + 1
		return nil, nil
	end
	local function countOf(kind) return OC.roll(kind, rng) end
	map.place = place

	local function marker(name, shape, size, color, mat, pos, glow)
		local p = mk(folder, name, shape, size, CFrame.new(pos), color, mat, true)
		p.CanCollide = false
		if glow then
			local l = Instance.new("PointLight"); l.Color = color; l.Range = 16; l.Brightness = 2; l.Parent = p
		end
		return p
	end

	local nextId = 0
	local function addItem(kind, x, z, extra)
		nextId += 1
		-- cada objeto interactivo queda sobre una pequeña explanada a la altura del terreno
		local lvl = HM:get(x, z)
		table.insert(hp.flats, { x, z, (extra and extra.flatR) or 5, 5, lvl })
		local it = { id = kind .. "_" .. nextId, kind = kind, x = x, z = z, pos = origin + Vector3.new(x, lvl, z), used = false, discovered = false }
		if extra then for k, v in pairs(extra) do it[k] = v end end
		map.objectCounts[kind] = (map.objectCounts[kind] or 0) + 1
		table.insert(map.items, it)
		addObs({ x = x, z = z, r = 3, virtual = true })
		return it
	end
	-- portal del jefe (explorando, lejos del spawn)
	local px, pz = sample(380, HALF - 12, 8, 4, 380)
	if not px then px, pz = HALF - 30, HALF - 30 end
	local portal = addItem("portal", px, pz, { radius = 6, flatR = 9 })
	map.portal = portal
	table.insert(placed, { x = px, z = pz, cat = "important" })
	do
		-- arco de piedra con runas y un remolino de energía, mirando hacia el inicio
		local bossId = BossConfig.modelFor(BossConfig.bossName(mapId, opts.mapLevel or 1)) or "patapim"
		local Theme = {
			cacto = { accent = Color3.fromRGB(255, 170, 45), secondary = Color3.fromRGB(120, 72, 38), stone = Color3.fromRGB(130, 105, 75) },
			lirili = { accent = Color3.fromRGB(80, 220, 255), secondary = Color3.fromRGB(75, 40, 130), stone = Color3.fromRGB(80, 70, 120) },
			sigmaboy = { accent = Color3.fromRGB(90, 140, 255), secondary = Color3.fromRGB(35, 50, 105), stone = Color3.fromRGB(60, 72, 110) },
			patapim = { accent = Color3.fromRGB(80, 220, 120), secondary = Color3.fromRGB(92, 55, 35), stone = Color3.fromRGB(67, 82, 54) },
			chimpanzini = { accent = Color3.fromRGB(255, 220, 70), secondary = Color3.fromRGB(120, 70, 30), stone = Color3.fromRGB(100, 75, 50) },
			tung = { accent = Color3.fromRGB(255, 75, 45), secondary = Color3.fromRGB(100, 32, 28), stone = Color3.fromRGB(95, 55, 48) },
			esoksekolah = { accent = Color3.fromRGB(190, 100, 255), secondary = Color3.fromRGB(38, 28, 65), stone = Color3.fromRGB(58, 48, 82) },
			sixseven = { accent = Color3.fromRGB(255, 55, 185), secondary = Color3.fromRGB(45, 220, 255), stone = Color3.fromRGB(55, 55, 85) },
			saturnita = { accent = Color3.fromRGB(255, 215, 90), secondary = Color3.fromRGB(70, 150, 255), stone = Color3.fromRGB(75, 78, 110) },
		}
		local theme = Theme[bossId] or Theme.patapim
		portal.bossId = bossId
		portal.theme = theme
		local stone, stoneD, glow = theme.stone, theme.stone:Lerp(Color3.fromRGB(20, 20, 28), 0.35), theme.accent
		local look = CFrame.lookAt(portal.pos, Vector3.new(origin.X, portal.pos.Y, origin.Z))
		local function P(name, shape, sz, cf, col, mat, collide) local p = mk(folder, name, shape, sz, cf, col, mat, collide == true); p.CastShadow = false; return p end
		P("PortalBase", CYL, Vector3.new(0.8, 15, 15), look * CFrame.new(0, 0.3, 0) * CFrame.Angles(0, 0, math.pi / 2), stoneD, Enum.Material.Slate, true)
		P("PortalBase", CYL, Vector3.new(0.12, 11, 11), look * CFrame.new(0, 0.75, 0) * CFrame.Angles(0, 0, math.pi / 2), glow, Enum.Material.Neon)
		local R, cy = 6.4, 7.4
		for k = 0, 15 do
			local a = k / 16 * math.pi * 2
			local cf = look * CFrame.new(math.cos(a) * R, cy + math.sin(a) * R, 0) * CFrame.Angles(0, 0, a)
			P("PortalStone", BL, Vector3.new(1.6, 2.7, 2.4), cf, (k % 2 == 0) and stone or stoneD, Enum.Material.Slate)
			if k % 4 == 1 then P("PortalRune", BL, Vector3.new(0.5, 0.9, 0.1), cf * CFrame.new(0, 0, -1.25), glow, Enum.Material.Neon) end
		end
		for _, s in ipairs({ -1, 1 }) do P("PortalFoot", BL, Vector3.new(2.4, 2.2, 3), look * CFrame.new(s * 6.2, 1.6, 0), stoneD, Enum.Material.Slate, true) end
		portal.part = P("Portal", CYL, Vector3.new(0.3, 11.6, 11.6), look * CFrame.new(0, cy, 0) * CFrame.Angles(0, math.pi / 2, 0), glow, Enum.Material.Neon)
		portal.part.Transparency = 0.25
		local inner = P("PortalCore", CYL, Vector3.new(0.35, 6.5, 6.5), look * CFrame.new(0, cy, 0) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(230, 200, 255), Enum.Material.Neon)
		inner.Transparency = 0.35
		local l = Instance.new("PointLight"); l.Color = glow; l.Range = 24; l.Brightness = 3; l.Parent = portal.part
		local pe = Instance.new("ParticleEmitter")
		pe.Color = ColorSequence.new(glow, Color3.fromRGB(255, 255, 255)); pe.LightEmission = 1; pe.Rate = 18; pe.Lifetime = NumberRange.new(1, 2)
		pe.Speed = NumberRange.new(1, 3); pe.SpreadAngle = Vector2.new(180, 180); pe.Size = NumberSequence.new(0.6, 0)
		pe.Parent = portal.part
		-- ambientación propia del jefe: el portal cambia de paleta, material y elementos alrededor
		portal.part:SetAttribute("BossId", bossId)
		local themeFolder = Instance.new("Folder")
		themeFolder.Name = "BossTheme_" .. bossId
		themeFolder.Parent = folder
		local function TP(name, shape, size, cf, color, material, collide)
			local q = mk(themeFolder, name, shape, size, cf, color, material, collide == true)
			q.CastShadow = material ~= Enum.Material.Neon
			return q
		end
		local accent, secondary = theme.accent, theme.secondary
		for k = 0, 3 do
			local a = k * math.pi / 2 + math.pi / 4
			local q = TP("BossRunePillar", BL, Vector3.new(0.8, 3.8, 0.8), CFrame.new(portal.pos + Vector3.new(math.cos(a) * 9, 1.9, math.sin(a) * 9)), secondary, Enum.Material.Slate, true)
			local rune = TP("BossRune", BL, Vector3.new(0.12, 2.5, 0.16), q.CFrame * CFrame.new(0, 0, -0.44), accent, Enum.Material.Neon)
			local light = Instance.new("PointLight"); light.Color = accent; light.Range = 10; light.Brightness = 0.7; light.Parent = rune
		end
		local halo = TP("BossHalo", CYL, Vector3.new(0.12, 18, 18), CFrame.new(portal.pos + Vector3.new(0, 0.18, 0)) * CFrame.Angles(0, 0, math.pi / 2), accent, Enum.Material.Neon)
		halo.Transparency = 0.84
		if bossId == "cacto" then
			for k = 0, 5 do
				local a = k * math.pi / 3
				TP("CactusSpine", Enum.PartType.Wedge, Vector3.new(0.7, 2.6, 0.7), CFrame.new(portal.pos + Vector3.new(math.cos(a) * 8, 1.5, math.sin(a) * 8)) * CFrame.Angles(0, -a, 0), secondary, Enum.Material.Sandstone)
			end
		elseif bossId == "lirili" then
			for k = 0, 7 do
				local a = k * math.pi / 4
				local note = TP("MusicNote", Enum.PartType.Ball, Vector3.new(0.7, 0.7, 0.7), CFrame.new(portal.pos + Vector3.new(math.cos(a) * 8, 3.2 + (k % 2) * 1.3, math.sin(a) * 8)), accent, Enum.Material.Neon)
				local l = Instance.new("PointLight"); l.Color = accent; l.Range = 7; l.Brightness = 0.7; l.Parent = note
			end
		elseif bossId == "sigmaboy" then
			for k = 0, 2 do
				TP("SigmaBeam", BL, Vector3.new(0.3, 5.5, 0.3), CFrame.new(portal.pos + Vector3.new((k - 1) * 2.2, 3.1, -8)), accent, Enum.Material.Neon)
			end
		elseif bossId == "patapim" then
			for k = 0, 5 do
				local a = k * math.pi / 3
				TP("JungleRoot", BL, Vector3.new(0.7, 2.8, 0.7), CFrame.new(portal.pos + Vector3.new(math.cos(a) * 8, 1.4, math.sin(a) * 8)) * CFrame.Angles(0, a, 0), secondary, Enum.Material.Wood)
			end
		elseif bossId == "chimpanzini" then
			for k = 0, 5 do
				local a = k * math.pi / 3
				TP("BananaRelic", Enum.PartType.Ball, Vector3.new(1, 1, 1), CFrame.new(portal.pos + Vector3.new(math.cos(a) * 8, 2.2, math.sin(a) * 8)), accent, Enum.Material.Neon)
			end
		elseif bossId == "tung" then
			for k = 1, 3 do
				local ring = TP("DawnDrumRing", CYL, Vector3.new(0.18, 7 + k * 2, 7 + k * 2), CFrame.new(portal.pos + Vector3.new(0, 0.12 + k * 0.12, 0)) * CFrame.Angles(0, 0, math.pi / 2), accent, Enum.Material.Neon)
				ring.Transparency = 0.78
			end
		elseif bossId == "esoksekolah" then
			TP("CursedBlackboard", BL, Vector3.new(5, 3.4, 0.25), CFrame.lookAt(portal.pos + Vector3.new(0, 2.3, -8), portal.pos), secondary, Enum.Material.Slate)
			for k = -1, 1 do TP("SchoolBell", Enum.PartType.Ball, Vector3.new(0.9, 0.9, 0.9), CFrame.new(portal.pos + Vector3.new(k * 2.2, 4.8, -7)), accent, Enum.Material.Metal) end
		elseif bossId == "sixseven" then
			for k = 0, 7 do
				local a = k * math.pi / 4
				TP("GlitchBlock", BL, Vector3.new(1.2, 1.2, 1.2), CFrame.new(portal.pos + Vector3.new(math.cos(a) * 8, 1.5 + (k % 3) * 1.2, math.sin(a) * 8)), (k % 2 == 0) and accent or secondary, Enum.Material.Neon)
			end
		elseif bossId == "saturnita" then
			for k = 1, 2 do
				local ring = TP("SaturnRing", CYL, Vector3.new(0.22, 12 + k * 4, 4 + k * 2), CFrame.new(portal.pos + Vector3.new(0, 5 + k * 1.4, 0)) * CFrame.Angles(math.rad(18 + k * 12), 0, math.pi / 2), accent, Enum.Material.Neon)
				ring.Transparency = 0.45
				TP("CosmicOrb", Enum.PartType.Ball, Vector3.new(1.2, 1.2, 1.2), CFrame.new(portal.pos + Vector3.new((k == 1 and -7 or 7), 4, 0)), secondary, Enum.Material.Neon)
			end
		end
	end

	-- santuarios
	for i = 1, countOf("shrine") do
		local x, z = place("shrine")
		if x then
			-- 2026-11-05: ~1 de cada 8 santuarios es DORADO (sus mejoras salen siempre legendarias)
			local goldenShrine = rng:chance(OC.shrine.goldenChance)
			local it = addItem("shrine", x, z, { progress = 0, flatR = 10, golden = goldenShrine or nil })
			-- pilar de santuario: escalones, columna estriada con anillos dorados, capitel y cristal flotante
			local stone, stoneD, gold = Color3.fromRGB(86, 98, 96), Color3.fromRGB(58, 68, 66), Color3.fromRGB(222, 178, 70)
			if goldenShrine then stone, stoneD, gold = Color3.fromRGB(226, 182, 64), Color3.fromRGB(176, 128, 40), Color3.fromRGB(255, 240, 160) end
			local base = CFrame.new(it.pos) * CFrame.Angles(0, rng:number(0, math.pi / 2), 0)
			local function S(name, shape, sz, off, col, mat, rot) return mk(folder, name, shape, sz, base * CFrame.new(off) * (rot or CFrame.identity), col, mat) end
			local UP = CFrame.Angles(0, 0, math.pi / 2)
			S("ShrinePedestal", BL, Vector3.new(5.6, 0.7, 5.6), Vector3.new(0, 0.35, 0), stoneD, Enum.Material.Slate)
			S("ShrinePedestal", BL, Vector3.new(4.6, 0.6, 4.6), Vector3.new(0, 1.0, 0), stone, Enum.Material.Slate, CFrame.Angles(0, math.pi / 4, 0))
			S("ShrinePedestal", CYL, Vector3.new(5.2, 2.2, 2.2), Vector3.new(0, 3.9, 0), stone, Enum.Material.Slate, UP)
			for k = 0, 3 do
				local a = k * math.pi / 2
				S("ShrinePedestal", BL, Vector3.new(0.45, 5.2, 0.45), Vector3.new(math.cos(a) * 1.12, 3.9, math.sin(a) * 1.12), stoneD, Enum.Material.Slate)
			end
			for _, y in ipairs({ 1.45, 6.4 }) do S("ShrineTrim", CYL, Vector3.new(0.28, 2.75, 2.75), Vector3.new(0, y, 0), gold, Enum.Material.Metal, UP) end
			S("ShrinePedestal", BL, Vector3.new(3.6, 0.7, 3.6), Vector3.new(0, 6.9, 0), stone, Enum.Material.Slate)
			S("ShrinePedestal", BL, Vector3.new(2.8, 0.45, 2.8), Vector3.new(0, 7.45, 0), stoneD, Enum.Material.Slate, CFrame.Angles(0, math.pi / 4, 0))
			for k = 0, 3 do
				local a = k * math.pi / 2 + math.pi / 4
				S("ShrineTrim", BL, Vector3.new(0.35, 0.9, 0.35), Vector3.new(math.cos(a) * 1.55, 7.9, math.sin(a) * 1.55), gold, Enum.Material.Metal)
			end
			-- cristal flotante: indica que está activo (se apaga al usarse)
			it.part = marker("Shrine", BL, Vector3.new(1.3, 1.3, 1.3), Color3.fromRGB(255, 210, 90), Enum.Material.Neon, it.pos + Vector3.new(0, 9.4, 0), true)
			it.part.CFrame = base * CFrame.new(0, 9.4, 0) * CFrame.Angles(math.pi / 4, 0, math.pi / 4)
			-- anillo en el suelo: zona donde hay que quedarse para cargarlo
			local ring = marker("ShrineZone", Enum.PartType.Cylinder, Vector3.new(0.15, GameConfig.shrine.chargeRadius * 2, GameConfig.shrine.chargeRadius * 2), Color3.fromRGB(255, 210, 90), Enum.Material.Neon, it.pos + Vector3.new(0, 0.1, 0), false)
			ring.CFrame = CFrame.new(it.pos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			ring.Transparency = 0.75
			it.ring = ring
		end
	end
	-- cofres
	for i = 1, countOf("chest") do
		local x, z = place("chest")
		if x then
			-- 12% son cofres dorados GRATIS (brillan); el resto cuestan oro. origin = "map" (iniciales) / "reward" (addDropChest)
			local golden = rng:chance(OC.chest.goldenChance)
			local it = addItem("chest", x, z, { cost = golden and 0 or OC.chest.baseCost, golden = golden, origin = "map" })
			local yaw = CFrame.Angles(0, rng:number(0, math.pi * 2), 0)
			local base = CFrame.new(it.pos) * yaw
			local wood = golden and Color3.fromRGB(226, 168, 38) or Color3.fromRGB(128, 76, 40)
			local woodMat = golden and Enum.Material.Foil or Enum.Material.WoodPlanks
			local trim = golden and Color3.fromRGB(255, 226, 110) or Color3.fromRGB(222, 178, 62)
			local trimMat = Enum.Material.Metal
			local function c(name, sx, sy, sz, ox, oy, oz, col, mat, collide)
				return mk(folder, name, Enum.PartType.Block, Vector3.new(sx, sy, sz), base * CFrame.new(ox, oy, oz), col, mat, collide == true)
			end
			-- caja
			it.part = c("Chest", 3.2, 1.6, 2.2, 0, 0.8, 0, wood, woodMat, true)
			c("ChestTrim", 3.3, 0.18, 2.3, 0, 0.09, 0, trim, trimMat)
			c("ChestTrim", 3.3, 0.14, 2.3, 0, 1.53, 0, trim, trimMat)
			for _, sx in ipairs({ -1.55, 1.55 }) do for _, sz in ipairs({ -1.05, 1.05 }) do c("ChestTrim", 0.22, 1.6, 0.22, sx, 0.8, sz, trim, trimMat) end end
			for _, y in ipairs({ 0.55, 1.05 }) do c("ChestPlank", 2.9, 0.05, 0.03, 0, y, -1.11, wood:Lerp(Color3.new(0, 0, 0), 0.3), woodMat) end
			c("ChestLock", 0.36, 0.42, 0.12, 0, 1.12, -1.16, trim, trimMat)
			c("ChestLock", 0.06, 0.13, 0.03, 0, 1.08, -1.23, Color3.fromRGB(30, 20, 10), Enum.Material.SmoothPlastic)
			-- tapa abombada (se abre girando sobre la bisagra trasera)
			it.lidParts = {
				c("ChestLid", 3.2, 0.45, 2.2, 0, 1.83, 0, wood, woodMat),
				c("ChestLid", 3.0, 0.22, 1.8, 0, 2.16, 0, wood, woodMat),
				c("ChestLid", 2.6, 0.14, 1.2, 0, 2.33, 0, wood, woodMat),
				c("ChestLidTrim", 3.3, 0.12, 2.3, 0, 1.66, 0, trim, trimMat),
				c("ChestLidTrim", 0.32, 0.7, 0.08, 0, 1.98, -1.12, trim, trimMat),
				c("ChestLidTrim", 0.22, 0.5, 2.32, -1.55, 1.85, 0, trim, trimMat),
				c("ChestLidTrim", 0.22, 0.5, 2.32, 1.55, 1.85, 0, trim, trimMat),
			}
			it.hinge = base * CFrame.new(0, 1.6, 1.1)
			if golden then
				local l = Instance.new("PointLight"); l.Color = Color3.fromRGB(255, 210, 80); l.Range = 14; l.Brightness = 2.5; l.Parent = it.part
				local sp = Instance.new("Sparkles"); sp.SparkleColor = Color3.fromRGB(255, 220, 90); sp.Parent = it.part
			end
		end
	end
	-- Moai genérico
	for _ = 1, countOf("moai") do
		local x, z = place("moai")
		if x then
			local it = addItem("moai", x, z, { flatR = 6 })
			-- Moai: cabeza alargada con ceño, nariz, labios, orejas y pukao (sombrero de piedra roja) sobre un torso
			local st, stD, red = Color3.fromRGB(150, 144, 134), Color3.fromRGB(112, 106, 98), Color3.fromRGB(160, 82, 60)
			local base = CFrame.lookAt(it.pos, Vector3.new(origin.X, it.pos.Y, origin.Z))
			local M = Enum.Material.Slate
			local function m(name, sz, off, col, rot, collide) return mk(folder, name, BL, sz, base * CFrame.new(off) * (rot or CFrame.identity), col, M, collide == true) end
			m("Moai", Vector3.new(4.6, 0.8, 3.6), Vector3.new(0, 0.4, 0), stD, nil, true)
			it.part = m("Moai", Vector3.new(3.8, 4.2, 2.8), Vector3.new(0, 2.9, 0), st, nil, true) -- torso
			for _, s in ipairs({ -1, 1 }) do m("MoaiArm", Vector3.new(0.5, 3, 0.9), Vector3.new(s * 1.95, 2.9, -0.6), stD) end
			m("MoaiHand", Vector3.new(2.8, 0.45, 0.4), Vector3.new(0, 1.7, -1.5), stD)
			m("MoaiHead", Vector3.new(3.3, 6.4, 3.0), Vector3.new(0, 8.2, 0), st, nil, true)
			m("MoaiBrow", Vector3.new(3.4, 0.9, 1.0), Vector3.new(0, 9.9, -1.6), stD)
			for _, s in ipairs({ -0.8, 0.8 }) do m("MoaiEye", Vector3.new(1.0, 0.55, 0.3), Vector3.new(s, 9.15, -1.42), Color3.fromRGB(45, 42, 40)) end
			m("MoaiNose", Vector3.new(1.0, 2.8, 1.2), Vector3.new(0, 7.9, -1.85), st)
			m("MoaiNose", Vector3.new(1.3, 0.6, 1.0), Vector3.new(0, 6.6, -2.0), stD)
			m("MoaiLips", Vector3.new(2.0, 0.5, 0.6), Vector3.new(0, 5.8, -1.65), stD)
			m("MoaiChin", Vector3.new(2.6, 1.0, 0.9), Vector3.new(0, 5.15, -1.35), st)
			for _, s in ipairs({ -1, 1 }) do m("MoaiEar", Vector3.new(0.45, 2.6, 0.9), Vector3.new(s * 1.8, 8.3, 0.1), stD) end
			local hat = mk(folder, "MoaiPukao", CYL, Vector3.new(1.6, 3.2, 3.2), base * CFrame.new(0, 12.2, 0.15) * CFrame.Angles(0, 0, math.pi / 2), red, Enum.Material.Sandstone, false)
			hat.CastShadow = true
 for _,side in ipairs({-1,1}) do
  local eye=m("JadeInlay",Vector3.new(.58,.16,.12),Vector3.new(side*.8,9.15,-1.61),Color3.fromRGB(110,230,187))
  eye.Material=Enum.Material.Neon
  m("CarvedCollar",Vector3.new(1.35,.18,.15),Vector3.new(side*.64,3.65,-1.44),Color3.fromRGB(173,154,99),CFrame.Angles(0,0,side*.26))
 end
		end
	end
	-- altar de Maldición del Jefe (una interacción voluntaria)
	for _ = 1, countOf("curse") do
		local x, z = place("curse")
		if x then
			local it = addItem("curse", x, z, { flatR = 6 })
			-- estatua gris del jefe de este mapa sobre un zócalo, con anillo rojo de interacción
			local yaw = CFrame.Angles(0, rng:number(0, math.pi * 2), 0)
			mk(folder, "CursePlinth", Enum.PartType.Block, Vector3.new(5, 0.7, 5), CFrame.new(it.pos + Vector3.new(0, 0.35, 0)) * yaw, Color3.fromRGB(70, 70, 74), Enum.Material.Slate)
			local ss = 4.6
			local model = Brainrots.build(Brainrots.forBoss(opts.mapId, opts.mapLevel), ss, false, CFrame.new(it.pos + Vector3.new(0, 0.7 + ss / 2, 0)) * yaw, folder, { grey = true })
			model.Name = "CurseStatue"
			it.part = marker("CurseRing", Enum.PartType.Cylinder, Vector3.new(0.15, 9, 9), Color3.fromRGB(200, 40, 70), Enum.Material.Neon, it.pos + Vector3.new(0, 0.1, 0), false) -- sin luz: no tiñe la estatua
			it.part.CFrame = CFrame.new(it.pos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			it.part.Transparency = 0.45
		end
	end
	-- estatuas de dificultad (2 por nivel): calavera sostenida por una mano roja sobre una columna de piedra
	local function skullStatue(pos,yaw)
  local base=CFrame.new(pos)*yaw
  local obsidian=Color3.fromRGB(40,32,49)
  local brass=Color3.fromRGB(167,109,58)
  local ivory=Color3.fromRGB(218,202,170)
  local ember=Color3.fromRGB(255,75,35)
  local function piece(name,shape,sz,offset,col,material)
   local p=mk(folder,name,shape,sz,base*offset,col,material,false)
   p.CastShadow=material~=Enum.Material.Neon
   return p
  end
  local function link(name,a,b,width,depth,col,mat)
   return piece(name,BL,Vector3.new(width,depth,(b-a).Magnitude+.06),CFrame.lookAt((a+b)/2,b),col,mat)
  end
  for i=0,2 do
   piece("ReliquaryStep",CYL,Vector3.new(.5,8.3-i*1.2,8.3-i*1.2),CFrame.new(0,.25+i*.5,0)*CFrame.Angles(0,0,math.pi/2),i==1 and brass or obsidian,Enum.Material.Slate)
  end
  -- Suspended skull inside a broken bronze eclipse.
  for i=0,17 do
   local a,b=math.rad(-155+i*17),math.rad(-155+(i+1)*17)
   local p=Vector3.new(math.sin(a)*3.8,5.8+math.cos(a)*3.8,1.25)
   local q=Vector3.new(math.sin(b)*3.8,5.8+math.cos(b)*3.8,1.25)
   link("EclipseBand",p,q,.42,.55,brass,Enum.Material.Metal)
   link("EmberChannel",p-Vector3.zAxis*.29,q-Vector3.zAxis*.29,.11,.11,ember,Enum.Material.Neon)
  end
  piece("Cranium",Enum.PartType.Ball,Vector3.new(4.5,3.85,3.25),CFrame.new(0,6.4,0),ivory,Enum.Material.Marble)
  piece("Jaw",BL,Vector3.new(2.75,.65,1.8),CFrame.new(0,4.15,-.24),ivory,Enum.Material.Slate)
  for _,side in ipairs({-1,1}) do
   piece("Cheekbone",Enum.PartType.Ball,Vector3.new(1.45,1.2,1.25),CFrame.new(side*1.42,5.38,-.75),ivory,Enum.Material.Marble)
   piece("Socket",Enum.PartType.Ball,Vector3.new(1.44,1.24,.65),CFrame.new(side*.93,6.31,-1.39)*CFrame.Angles(0,0,side*.21),obsidian,Enum.Material.Basalt)
   piece("EmberEye",Enum.PartType.Ball,Vector3.new(.46,.62,.28),CFrame.new(side*.93,6.31,-1.72),ember,Enum.Material.Neon)
   local h=Vector3.new(side*1.73,7.12,.05)
   local k=Vector3.new(side*2.66,7.94,.12)
   link("GildedHorn",h,k,.63,.7,brass,Enum.Material.Metal)
   link("HornTip",k,Vector3.new(side*2.51,8.97,.2),.25,.34,ivory,Enum.Material.Marble)
  end
  for i=-2,2 do piece("Fang",BL,Vector3.new(.36,i%2==0 and .75 or .55,.42),CFrame.new(i*.46,4.85,-1.02),ivory,Enum.Material.Marble) end
  local core=piece("SoulFlame",Enum.PartType.Ball,Vector3.new(.85,1.25,.85),CFrame.new(0,2.6,0),ember,Enum.Material.Neon)
  local light=Instance.new("PointLight");light.Color=ember;light.Range=9;light.Brightness=.8;light.Parent=core
  local sparks=Instance.new("ParticleEmitter");sparks.Texture="rbxasset://textures/particles/sparkles_main.dds";sparks.Rate=5;sparks.Lifetime=NumberRange.new(.7,1.4);sparks.Speed=NumberRange.new(1.5,2.8);sparks.Size=NumberSequence.new(.16,0);sparks.Color=ColorSequence.new(ember,brass);sparks.LightEmission=.9;sparks.Parent=core
 end
	for i = 1, countOf("statue") do -- estatuas de dificultad (MapObjectsConfig)
		local x, z = place("statue")
		if x then
			local it = addItem("statue", x, z, { flatR = 6 })
			skullStatue(it.pos, CFrame.Angles(0, rng:number(0, math.pi * 2), 0))
			it.part = marker("StatueRing", Enum.PartType.Cylinder, Vector3.new(0.15, 9, 9), Color3.fromRGB(220, 40, 40), Enum.Material.Neon, it.pos + Vector3.new(0, 0.1, 0), true)
			it.part.CFrame = CFrame.new(it.pos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			it.part.Transparency = 0.84
            local glow=it.part:FindFirstChildOfClass("PointLight");if glow then glow.Brightness=.55;glow.Range=9 end
		end
	end

	-- ===== 2026-11-05: interactuables nuevos (estilo MegaBonk) =====
	local function glowLight(p, col, range) local l = Instance.new("PointLight"); l.Color = col; l.Range = range or 12; l.Brightness = 2; l.Parent = p; return l end
	-- Santuario de DESAFÍO: obelisco violeta. Al activarlo salen enemigos marcados; si los matás a todos, cofre gratis.
	for _ = 1, countOf("challenge") do
		local x, z = place("challenge")
		if x then
			local it = addItem("challenge", x, z, { flatR = 7 })
			local base = CFrame.new(it.pos) * CFrame.Angles(0, rng:number(0, math.pi * 2), 0)
			local dark, purple = Color3.fromRGB(44, 30, 66), Color3.fromRGB(170, 80, 255)
			mk(folder, "ChallengeBase", CYL, Vector3.new(0.8, 7, 7), base * CFrame.new(0, 0.4, 0) * CFrame.Angles(0, 0, math.pi / 2), dark, Enum.Material.Slate, true)
			mk(folder, "ChallengeObelisk", BL, Vector3.new(1.8, 7, 1.8), base * CFrame.new(0, 4.3, 0), dark, Enum.Material.Basalt, true)
			mk(folder, "ChallengeObelisk", Enum.PartType.Wedge, Vector3.new(1.8, 1.4, 0.9), base * CFrame.new(0, 8.5, -0.45), dark, Enum.Material.Basalt)
			mk(folder, "ChallengeObelisk", Enum.PartType.Wedge, Vector3.new(1.8, 1.4, 0.9), base * CFrame.new(0, 8.5, 0.45) * CFrame.Angles(0, math.pi, 0), dark, Enum.Material.Basalt)
			for k = 0, 3 do mk(folder, "ChallengeRune", BL, Vector3.new(0.12, 4.5, 0.5), base * CFrame.Angles(0, k * math.pi / 2, 0) * CFrame.new(0.93, 4.6, 0), purple, Enum.Material.Neon) end
			it.part = marker("ChallengeRing", CYL, Vector3.new(0.15, 9, 9), purple, Enum.Material.Neon, it.pos + Vector3.new(0, 0.1, 0), true)
			it.part.CFrame = CFrame.new(it.pos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			it.part.Transparency = 0.6
		end
	end
	-- ESTATUAS DE JEFE (altar sangriento): cada una suma un jefe más al PRÓXIMO encuentro de jefe (se acumulan);
	-- cada jefe adicional derrotado suelta un cofre dorado.
	for _ = 1, countOf("bloody") do
		local x, z = place("bloody")
		if x then
			local it = addItem("bloody", x, z, { flatR = 7 })
			local base = CFrame.new(it.pos) * CFrame.Angles(0, rng:number(0, math.pi * 2), 0)
			local stone, blood = Color3.fromRGB(60, 40, 42), Color3.fromRGB(170, 10, 25)
			mk(folder, "BloodyAltar", BL, Vector3.new(5, 1, 3), base * CFrame.new(0, 0.5, 0), stone, Enum.Material.Slate, true)
			mk(folder, "BloodyAltar", BL, Vector3.new(4.2, 1.4, 2.4), base * CFrame.new(0, 1.7, 0), stone, Enum.Material.Slate, true)
			mk(folder, "BloodyPool", CYL, Vector3.new(0.12, 2.4, 2.4), base * CFrame.new(0, 2.45, 0) * CFrame.Angles(0, 0, math.pi / 2), blood, Enum.Material.Glass)
			for _, sx in ipairs({ -1.9, 1.9 }) do
				local c = mk(folder, "BloodyCandle", CYL, Vector3.new(1.2, 0.4, 0.4), base * CFrame.new(sx, 3, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(230, 220, 200), Enum.Material.SmoothPlastic)
				local f = mk(folder, "BloodyFlame", Enum.PartType.Ball, Vector3.new(0.3, 0.45, 0.3), base * CFrame.new(sx, 3.8, 0), Color3.fromRGB(255, 90, 40), Enum.Material.Neon)
				glowLight(f, Color3.fromRGB(255, 60, 40), 10)
			end
			it.part = marker("BloodyRing", CYL, Vector3.new(0.15, 9, 9), blood, Enum.Material.Neon, it.pos + Vector3.new(0, 0.1, 0), true)
			it.part.CFrame = CFrame.new(it.pos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			it.part.Transparency = 0.6
		end
	end
	-- MERCADER: un brainrot con su puestito. 3 objetos por oro; comprás uno y se va. Color del techo = rareza.
	for _ = 1, countOf("merchant") do
		local x, z = place("merchant")
		if x then
			local tier = rng:weighted(OC.merchant.tierWeights)
			local category = OC.pick(OC.merchant.categories, rng)
			local roofCol = ({ Color3.fromRGB(60, 60, 70), Color3.fromRGB(60, 130, 255), Color3.fromRGB(170, 80, 255), Color3.fromRGB(255, 196, 40) })[tier]
			local it = addItem("merchant", x, z, { flatR = 8, tier = tier, category = category })
			local base = CFrame.lookAt(it.pos, Vector3.new(origin.X, it.pos.Y, origin.Z))
			local wood = Color3.fromRGB(120, 78, 44)
			mk(folder, "MerchantCounter", BL, Vector3.new(5, 2.2, 1.6), base * CFrame.new(0, 1.1, -1.4), wood, Enum.Material.WoodPlanks, true)
			for _, sx in ipairs({ -2.4, 2.4 }) do mk(folder, "MerchantPole", BL, Vector3.new(0.3, 5.5, 0.3), base * CFrame.new(sx, 2.75, -1.4), wood, Enum.Material.Wood) end
			for k = 0, 5 do
				mk(folder, "MerchantRoof", BL, Vector3.new(0.9, 0.2, 2.6), base * CFrame.new(-2.25 + k * 0.9, 5.6, -1.4) * CFrame.Angles(0.25, 0, 0), (k % 2 == 0) and roofCol or Color3.fromRGB(240, 236, 228), Enum.Material.Fabric)
			end
			for k = 0, 2 do mk(folder, "MerchantGoods", Enum.PartType.Ball, Vector3.one * 0.7, base * CFrame.new(-1.4 + k * 1.4, 2.55, -1.4), ({ Color3.fromRGB(255, 90, 90), Color3.fromRGB(90, 200, 255), Color3.fromRGB(255, 220, 80) })[k + 1], Enum.Material.Neon) end
			pcall(function()
				-- 2026-11-05: por piezas (noPack): dos mallas del pack de Tim Cheese no cargan y trababan la pantalla de carga
				local npc = Brainrots.build("timcheese", 3.6, false, base * CFrame.new(0, 1.8, 0.6) * CFrame.Angles(0, math.pi, 0), folder, { noPack = true })
				npc.Name = "MerchantNPC"
			end)
			it.part = marker("MerchantRing", CYL, Vector3.new(0.15, 9, 9), roofCol, Enum.Material.Neon, it.pos + Vector3.new(0, 0.1, 0), true)
			it.part.CFrame = CFrame.new(it.pos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			it.part.Transparency = 0.7
		end
	end
	-- MICROONDAS: duplica un objeto tuyo por oro. 3 usos y explota. Color = qué rarezas acepta.
	for _ = 1, countOf("microwave") do
		local x, z = place("microwave")
		if x then
			local tier = rng:weighted(OC.microwave.tierWeights) -- 1 blanco: común/poco común · 2 violeta: + raro/épico · 3 dorado: todos
			local shell = ({ Color3.fromRGB(235, 235, 235), Color3.fromRGB(150, 90, 230), Color3.fromRGB(240, 196, 60) })[tier]
			local it = addItem("microwave", x, z, { flatR = 6, tier = tier, uses = 0 })
			local base = CFrame.lookAt(it.pos, Vector3.new(origin.X, it.pos.Y, origin.Z))
			mk(folder, "MicrowaveTable", BL, Vector3.new(3.6, 1.6, 2.6), base * CFrame.new(0, 0.8, 0), Color3.fromRGB(110, 110, 120), Enum.Material.Metal, true)
			it.part = mk(folder, "Microwave", BL, Vector3.new(3, 1.8, 2), base * CFrame.new(0, 2.5, 0), shell, Enum.Material.SmoothPlastic, true)
			local win = mk(folder, "MicrowaveWindow", BL, Vector3.new(1.8, 1.2, 0.05), base * CFrame.new(-0.4, 2.5, -1.02), Color3.fromRGB(20, 22, 28), Enum.Material.Glass)
			win.Transparency = 0.2
			local panel = mk(folder, "MicrowavePanel", BL, Vector3.new(0.6, 1.3, 0.05), base * CFrame.new(1.05, 2.5, -1.02), Color3.fromRGB(40, 40, 46), Enum.Material.SmoothPlastic)
			local led = mk(folder, "MicrowaveLed", BL, Vector3.new(0.4, 0.2, 0.03), base * CFrame.new(1.05, 2.9, -1.06), Color3.fromRGB(90, 255, 120), Enum.Material.Neon)
			glowLight(led, Color3.fromRGB(90, 255, 120), 8)
			it.ring = marker("MicrowaveRing", CYL, Vector3.new(0.15, 8, 8), Color3.fromRGB(90, 255, 120), Enum.Material.Neon, it.pos + Vector3.new(0, 0.1, 0), false)
			it.ring.CFrame = CFrame.new(it.pos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			it.ring.Transparency = 0.7
		end
	end

	-- teteras rompibles (se rompen al acercarte): marrones dan XP, plateadas (15%) dan 1 de plata
	-- 2026-11-06: ATRACTOR DE EXPERIENCIA: obelisco verde con un cristal. Al usarlo, toda la XP del mapa vuela hacia vos.
	for _ = 1, countOf("xpmagnet") do
		local x, z = place("xpmagnet")
		if x then
			local it = addItem("xpmagnet", x, z, { flatR = 6 })
			local base = CFrame.new(it.pos) * CFrame.Angles(0, rng:number(0, math.pi * 2), 0)
			local stone, green = Color3.fromRGB(70, 78, 86), Color3.fromRGB(90, 255, 140)
			mk(folder, "XpMagnetBase", BL, Vector3.new(4.4, 0.8, 4.4), base * CFrame.new(0, 0.4, 0), stone, Enum.Material.Slate, true)
			mk(folder, "XpMagnetBase", BL, Vector3.new(3.2, 0.6, 3.2), base * CFrame.new(0, 1.1, 0) * CFrame.Angles(0, math.pi / 4, 0), stone, Enum.Material.Slate, true)
			for k = 0, 3 do
				local ang = k * math.pi / 2
				mk(folder, "XpMagnetProng", BL, Vector3.new(0.5, 3.4, 0.5), base * CFrame.new(math.cos(ang) * 1.2, 3, math.sin(ang) * 1.2) * CFrame.Angles(math.cos(ang) * 0.25, 0, -math.sin(ang) * 0.25), Color3.fromRGB(130, 140, 150), Enum.Material.Metal, true)
			end
			local crystal = mk(folder, "XpMagnetCrystal", BL, Vector3.new(1.4, 2.2, 1.4), base * CFrame.new(0, 4.6, 0) * CFrame.Angles(0, math.pi / 4, 0), green, Enum.Material.Neon)
			crystal:SetAttribute("Spin", 1.2)
			glowLight(crystal, green, 16)
			it.crystal = crystal
			it.part = marker("XpMagnetRing", CYL, Vector3.new(0.15, 9, 9), green, Enum.Material.Neon, it.pos + Vector3.new(0, 0.1, 0), false)
			it.part.CFrame = CFrame.new(it.pos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			it.part.Transparency = 0.65
		end
	end
	-- 2026-11-06: ESTATUA ESPECIAL (pactos): figura encapuchada que sostiene un orbe violeta. Ofrece 3 pactos
	-- (algunos con un lado malo) con rarezas configurables en MapObjectsConfig.pacts.
	for _ = 1, countOf("pact") do
		local x, z = place("pact")
		if x then
			local it = addItem("pact", x, z, { flatR = 6 })
			local base = CFrame.lookAt(it.pos, Vector3.new(origin.X, it.pos.Y, origin.Z))
			local robe, dark, orbC = Color3.fromRGB(52, 40, 74), Color3.fromRGB(28, 22, 40), Color3.fromRGB(190, 110, 255)
			mk(folder, "PactBase", CYL, Vector3.new(0.8, 5.2, 5.2), base * CFrame.new(0, 0.4, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(80, 74, 90), Enum.Material.Slate, true)
			mk(folder, "PactRobe", BL, Vector3.new(2.6, 3.6, 1.8), base * CFrame.new(0, 2.6, 0), robe, Enum.Material.Fabric, true)
			mk(folder, "PactRobe", Enum.PartType.Wedge, Vector3.new(2.6, 1.2, 1.8), base * CFrame.new(0, 5, 0), robe, Enum.Material.Fabric)
			mk(folder, "PactHood", Enum.PartType.Ball, Vector3.new(1.8, 1.8, 1.8), base * CFrame.new(0, 5.4, 0), robe, Enum.Material.Fabric)
			mk(folder, "PactFace", Enum.PartType.Ball, Vector3.new(1.2, 1.2, 0.6), base * CFrame.new(0, 5.35, -0.6), dark, Enum.Material.SmoothPlastic)
			for _, sx in ipairs({ -0.3, 0.3 }) do
				local eye = mk(folder, "PactEye", BL, Vector3.new(0.2, 0.12, 0.05), base * CFrame.new(sx, 5.45, -0.92), orbC, Enum.Material.Neon)
			end
			for _, sx in ipairs({ -0.9, 0.9 }) do mk(folder, "PactArm", BL, Vector3.new(0.5, 0.5, 1.6), base * CFrame.new(sx, 3.4, -1.1), robe, Enum.Material.Fabric) end
			local orb = mk(folder, "PactOrb", Enum.PartType.Ball, Vector3.new(1.3, 1.3, 1.3), base * CFrame.new(0, 3.6, -1.9), orbC, Enum.Material.Neon)
			glowLight(orb, orbC, 14)
			it.orb = orb
			it.part = marker("PactRing", CYL, Vector3.new(0.15, 9, 9), orbC, Enum.Material.Neon, it.pos + Vector3.new(0, 0.1, 0), false)
			it.part.CFrame = CFrame.new(it.pos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			it.part.Transparency = 0.65
		end
	end
	map.vases = {}
	local function teapot(pos, silver, yaw, golden)
		local m = Instance.new("Model")
		m.Name = golden and "GoldenTeapot" or (silver and "SilverTeapot" or "Teapot")
		local body = golden and Color3.fromRGB(240, 190, 50) or (silver and Color3.fromRGB(205, 210, 220) or Color3.fromRGB(150, 58, 40))
		local mat = (silver or golden) and Enum.Material.Metal or Enum.Material.SmoothPlastic
		local limb = golden and Color3.fromRGB(255, 225, 120) or (silver and Color3.fromRGB(175, 180, 192) or Color3.fromRGB(232, 150, 150))
		local dark = Color3.fromRGB(60, 25, 20)
		local first
		local function b(sz, off, col, mt, rot)
			local p = Instance.new("Part")
			p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
			p.Size = sz; p.Color = col; p.Material = mt or Enum.Material.SmoothPlastic
			p.CFrame = CFrame.new(pos) * yaw * CFrame.new(off) * (rot or CFrame.identity)
			p.Parent = m
			first = first or p
		end
		-- piernas y zapatos
		b(Vector3.new(.22, .7, .22), Vector3.new(-.25, .5, 0), limb)
		b(Vector3.new(.22, .7, .22), Vector3.new(.25, .5, 0), limb)
		b(Vector3.new(.32, .16, .42), Vector3.new(-.25, .08, -.06), limb)
		b(Vector3.new(.32, .16, .42), Vector3.new(.25, .08, -.06), limb)
		-- cuerpo, tapa y perilla
		b(Vector3.new(1.2, 1.3, .9), Vector3.new(0, 1.5, 0), body, mat)
		b(Vector3.new(.9, .22, .7), Vector3.new(0, 2.26, 0), body, mat)
		b(Vector3.new(.28, .22, .28), Vector3.new(0, 2.48, 0), body, mat)
		-- pico (izquierda, hacia arriba)
		b(Vector3.new(.26, .8, .26), Vector3.new(-.85, 1.85, 0), body, mat, CFrame.Angles(0, 0, 0.9))
		b(Vector3.new(.3, .2, .3), Vector3.new(-1.18, 2.12, 0), body, mat, CFrame.Angles(0, 0, 0.9))
		-- asa (derecha, cae hacia abajo terminando en mano)
		b(Vector3.new(.5, .16, .16), Vector3.new(.8, 1.95, 0), body, mat)
		b(Vector3.new(.16, .7, .16), Vector3.new(1.05, 1.55, 0), body, mat)
		b(Vector3.new(.35, .14, .14), Vector3.new(1.15, 1.15, 0), limb)
		-- cara (frente = -Z)
		for _, sx in ipairs({ -.24, .24 }) do
			b(Vector3.new(.24, .24, .04), Vector3.new(sx, 1.72, -.46), Color3.fromRGB(240, 240, 245))
			b(Vector3.new(.12, .14, .05), Vector3.new(sx, 1.7, -.47), Color3.fromRGB(40, 90, 190))
			b(Vector3.new(.26, .05, .05), Vector3.new(sx, 1.9, -.47), dark, nil, CFrame.Angles(0, 0, sx < 0 and -.25 or .25))
		end
		b(Vector3.new(.34, .07, .05), Vector3.new(0, 1.32, -.47), dark)
		if silver or golden then
			local l = Instance.new("PointLight"); l.Color = golden and Color3.fromRGB(255, 210, 90) or Color3.fromRGB(220, 230, 255); l.Range = 8; l.Brightness = golden and 1.8 or 1.2; l.Parent = first
		end
		m.Parent = folder
		return m
	end
	local VW = {}
	for name, v in pairs(OC.vase.variants) do VW[name] = v.weight end
	for i = 1, countOf("vase") do
		local x, z = place("vase")
		if x then
			-- variante: normal / plateada / dorada (MapObjectsConfig.vase)
			local variant = OC.pick(VW, rng)
			local silver, golden = variant == "silver", variant == "golden"
			-- manzana dentro de la tetera (se suelta al romperla y cura)
			local apple = rng:chance(OC.vase.appleChance)
			local v = { id = "vase_" .. i, x = x, z = z, hp = 1, alive = true, silver = silver, golden = golden, variant = variant, apple = apple, pos = at(x, z, -0.1) }
			v.part = teapot(v.pos, silver, CFrame.Angles(0, rng:number(0, math.pi * 2), 0), golden)
			map.objectCounts.vase = (map.objectCounts.vase or 0) + 1
			table.insert(map.vases, v)
			addObs({ x = x, z = z, r = 1.6, virtual = true })
		end
	end
	if mapId=="forest" then
   local ruin=Instance.new("Folder");ruin.Name="Bosque_Observatorio";ruin.Parent=folder
   local slate=Color3.fromRGB(61,75,78)
   local brass=Color3.fromRGB(189,153,87)
   local jade=Color3.fromRGB(72,208,164)
   local function stone(name,x,y,z,w,h,d,color,mat,yaw)
    return mk(ruin,name,Enum.PartType.Block,Vector3.new(w,h,d),CFrame.new(at(x,z,y))*CFrame.Angles(0,yaw or 0,0),color,mat,false)
   end
   for i=0,23 do
    local a=i*math.pi/12
    local x,z=math.sin(a)*11,math.cos(a)*11
    stone("Losa radial",x,.15,z,2.78,.55,3.2,slate,Enum.Material.Slate,a)
    stone("Incrustación",x,.47,z,i%6==0 and .65 or .18,.09,2.3,i%6==0 and jade or brass,i%6==0 and Enum.Material.Neon or Enum.Material.Metal,a)
   end
   for _,x in ipairs({-8,8}) do
    stone("Base",x,.65,-13,4,1.6,4,slate,Enum.Material.Slate)
    stone("Pilar",x,5,-13,2.8,8,2.8,slate,Enum.Material.Slate)
    stone("Capitel",x,9,-13,3.8,.8,3.8,brass,Enum.Material.Metal)
    stone("Vena jade",x,5,-11.55,.26,6.5,.14,jade,Enum.Material.Neon)
   end
   local apex=at(0,-13,12)
   for _,x in ipairs({-8,8}) do
    local foot=at(x,-13,9.4)
    mk(ruin,"Arco del observatorio",Enum.PartType.Block,Vector3.new(1.2,1.2,(foot-apex).Magnitude),CFrame.lookAt((foot+apex)/2,apex),brass,Enum.Material.Metal,false)
   end
   stone("Clave",0,12,-13,2,2,2,jade,Enum.Material.Neon,.78)
  end
  map.spawnPos = origin + Vector3.new(0, spawnLevel + 3.5, 0)
	-- zona de aparición (portal circular de entrada)
	local ring = marker("SpawnPortal", Enum.PartType.Cylinder, Vector3.new(0.4, 8, 8), Color3.fromRGB(80, 200, 255), Enum.Material.Neon, origin + Vector3.new(0, spawnLevel + 0.2, 0), false)
	ring.CFrame = CFrame.new(origin + Vector3.new(0, spawnLevel + 0.2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Transparency = 0.82

	-- iluminación del bioma (solo cliente-visual; no afecta lógica)
	map.skyColor = def.sky

	-- rejilla espacial: los obstáculos pequeños por celda y los grandes aparte (enemigos)
	map.grid, map.bigObs = {}, {}
	for _, o in ipairs(map.obstacles) do
		if not o.virtual then
			if o.r > GRID / 2 then
				table.insert(map.bigObs, o)
			else
				local k = math.floor(o.x / GRID) * 4096 + math.floor(o.z / GRID)
				local b = map.grid[k]; if not b then b = {}; map.grid[k] = b end
				table.insert(b, o)
			end
		end
	end

	-- lugares y caminos para el mapa grande del cliente
	map.landmarks = {}
	for _, lm in ipairs(layout.landmarks) do
		table.insert(map.landmarks, { kind = lm.kind, x = math.floor(lm.x), z = math.floor(lm.z) }) -- sin nombre
	end
	for _, m in ipairs(layout.mountains or {}) do
		table.insert(map.landmarks, { kind = "mountain", x = math.floor(m.x), z = math.floor(m.z) })
	end
	map.routes = {}
	for _, r in ipairs(layout.routes) do
		local pts = {}
		for _, p in ipairs(r.pts) do table.insert(pts, { math.floor(p[1]), math.floor(p[2]) }) end
		table.insert(map.routes, pts)
	end
	map.layout = layout

	-- ===== 4) Terrain: desde aquí la altura no cambia (ya están todas las zonas planas) =====
	HM:freeze()
	TerrainWriter.write(map, B, cfg, work)

	-- ===== 5) publicar: primero los objetos, después cada capa en su lote =====
	folder.Parent = opts.parent
	for _, layer in ipairs(layers) do
		layer.Parent = folder
		work(nil, true)
	end
	local parts = 0
	for _, d in ipairs(folder:GetDescendants()) do if d:IsA("BasePart") then parts += 1 end end
	stats.parts = parts
	stats.obstacles = #map.obstacles
	stats.ms = math.floor((os.clock() - t0) * 1000)
	map.stats = stats
	return map
end

-- Validador de un mapa generado: todos los esenciales dentro de límites y libres de obstáculos reales.
function MapService.validate(map)
	local problems = {}
	local HALF = map.half
	local function check(name, x, z, r)
		if math.abs(x) > HALF or math.abs(z) > HALF then table.insert(problems, name .. " fuera de límites") end
		for _, o in ipairs(map.obstacles) do
			if not o.virtual and not o.plateau and dist2(x, z, o.x, o.z) < o.r + (r or 2) - 0.01 then
				table.insert(problems, name .. " solapa obstáculo")
				break
			end
		end
	end
	if not map.portal then table.insert(problems, "sin portal") end
	local shrines, chests = 0, 0
	for _, it in ipairs(map.items) do
		check(it.id, it.x, it.z, 2)
		if it.kind == "shrine" then shrines += 1 elseif it.kind == "chest" then chests += 1 end
		if it.kind == "portal" and dist2(it.x, it.z, 0, 0) < 90 then table.insert(problems, "portal demasiado cerca") end
	end
	if shrines < 3 then table.insert(problems, "pocos santuarios") end
	if chests < 3 then table.insert(problems, "pocos cofres") end
	return #problems == 0, problems
end

function MapService.destroy(map)
	if map and map.folder then map.folder:Destroy() end
	if map and map.terrainRegion then
		pcall(function() Terrain:FillBlock(map.terrainRegion.cf, map.terrainRegion.size, Enum.Material.Air) end)
		map.terrainRegion = nil
	end
end

-- (compatibilidad) escribe el Terrain de un mapa ya generado
function MapService.writeTerrain(map, mapId)
	local B = MapGenConfig.biomes[mapId] or MapGenConfig.biomes.forest
	TerrainWriter.write(map, B, MapGenConfig, function() end)
end

-- ===== Vista previa en Studio (modo edición) =====
-- MapService.preview("forest") arma el mapa en workspace.MapPreview lejos del lobby (borra la vista anterior:
-- nunca duplica). MapService.clearPreview() lo borra, incluido el Terrain. No se guarda nada del juego.
MapService.PREVIEW_ORIGIN = Vector3.new(-8000, 0, 0)
function MapService.clearPreview()
	local h = workspace:FindFirstChild("MapPreview")
	if h then
		local pos, sz = h:GetAttribute("RegionPos"), h:GetAttribute("RegionSize")
		if pos and sz then pcall(function() Terrain:FillBlock(CFrame.new(pos), sz, Enum.Material.Air) end) end
		h:Destroy()
	end
end
function MapService.preview(mapId, runSeed)
	MapService.clearPreview()
	local holder = Instance.new("Folder")
	holder.Name = "MapPreview"
	holder:SetAttribute("MapId", mapId)
	holder.Parent = workspace
	local seed = runSeed or 12345
	local map = MapService.generate({ mapId = mapId, mapLevel = 1, stage = 1, seed = seed, origin = MapService.PREVIEW_ORIGIN, parent = holder, rng = SeededRandom.new(seed) })
	if map.terrainRegion then
		-- en modo edición, Studio a veces deja trozos del Terrain sin redibujar (se ven grises y planos):
		-- reescribir los mismos vóxeles por franjas los vuelve a dibujar. En el juego no hace falta.
		local reg = map.terrainRegion
		local lo = reg.cf.Position - reg.size / 2
		local hi = reg.cf.Position + reg.size / 2
		for x0 = lo.X, hi.X - 1, 64 do
			local r = Region3.new(Vector3.new(x0, lo.Y, lo.Z), Vector3.new(math.min(x0 + 64, hi.X), hi.Y, hi.Z)):ExpandToGrid(4)
			local m, o = Terrain:ReadVoxels(r, 4)
			Terrain:WriteVoxels(r, 4, m, o)
			task.wait()
		end
		holder:SetAttribute("RegionPos", map.terrainRegion.cf.Position)
		holder:SetAttribute("RegionSize", map.terrainRegion.size)
	end
	return map
end

-- empuja una posición 2D fuera de obstáculos reales (para enemigos y jugador lógico)
local function push(o, x, z, radius)
	local dx, dz = x - o.x, z - o.z
	local d = math.sqrt(dx * dx + dz * dz)
	local minD = o.r + radius
	if d < minD then
		if d < 1e-3 then dx, dz, d = 1, 0, 1 end
		return o.x + dx / d * minD, o.z + dz / d * minD
	end
	return x, z
end

function MapService.resolve(map, x, z, radius)
	if map.grid then
		for _, o in ipairs(map.bigObs) do x, z = push(o, x, z, radius) end
		local cx, cz = math.floor(x / GRID), math.floor(z / GRID)
		for i = -1, 1 do
			for j = -1, 1 do
				local b = map.grid[(cx + i) * 4096 + (cz + j)]
				if b then for _, o in ipairs(b) do x, z = push(o, x, z, radius) end end
			end
		end
	else
		for _, o in ipairs(map.obstacles) do
			if not o.virtual then x, z = push(o, x, z, radius) end
		end
	end
	local h = map.half or MAX_HALF
	return math.clamp(x, -h, h), math.clamp(z, -h, h)
end

-- Altura del obstáculo bajo un punto (los enemigos trepan por encima de árboles, cactus, cristales…)
function MapService.topAt(map, x, z)
	if not map.grid then return 0 end
	local best = 0
	local cx, cz = math.floor(x / GRID), math.floor(z / GRID)
	for i = -1, 1 do
		for j = -1, 1 do
			local b = map.grid[(cx + i) * 4096 + (cz + j)]
			if b then
				for _, o in ipairs(b) do
					if o.h and o.h > best then
						local dx, dz = x - o.x, z - o.z
						if dx * dx + dz * dz < (o.r + 1.2) ^ 2 then best = o.h end
					end
				end
			end
		end
	end
	return best
end

-- ¿El punto está dentro de un lago?
function MapService.inWater(map, x, z)
	if not map.water then return false end
	for _, w in ipairs(map.water) do
		local dx, dz = x - w.x, z - w.z
		if dx * dx + dz * dz < w.r * w.r then return true end
	end
	return false
end

-- cofre dorado GRATIS que aparece durante la partida (lo deja el minijefe al morir). Se abre con E como los demás
-- y da la misma oferta de objetos que un cofre. Queda en map.items: lo ve todo el grupo y lo abre uno solo.
function MapService.addDropChest(map, x, z)
	local lim = map.half - 6
	x, z = math.clamp(x, -lim, lim), math.clamp(z, -lim, lim)
	x, z = MapService.resolve(map, x, z, 2)
	map.dropChests = (map.dropChests or 0) + 1
	local pos = map.origin + Vector3.new(x, map.height(x, z), z)
	-- origin = "reward": cofres de jefes, desafíos y eventos (no cuentan para los 30-35 iniciales y no tienen tope)
	local it = { id = "dropchest_" .. map.dropChests, kind = "chest", x = x, z = z, pos = pos, used = false, discovered = true, cost = 0, golden = true, dropped = true, origin = "reward" }
	local base = CFrame.new(pos) * CFrame.Angles(0, math.random() * math.pi * 2, 0)
	local wood, trim = Color3.fromRGB(226, 168, 38), Color3.fromRGB(255, 226, 110)
	local function c(name, sx, sy, sz, ox, oy, oz, col, mat, collide)
		local p = Instance.new("Part")
		p.Name = name; p.Size = Vector3.new(sx, sy, sz); p.CFrame = base * CFrame.new(ox, oy, oz)
		p.Color = col; p.Material = mat; p.Anchored = true; p.CanCollide = collide == true; p.CanQuery = collide == true; p.CanTouch = false
		p.TopSurface = Enum.SurfaceType.Smooth; p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = map.folder
		return p
	end
	it.part = c("Chest", 3.2, 1.6, 2.2, 0, 0.8, 0, wood, Enum.Material.Foil, true)
	c("ChestTrim", 3.3, 0.18, 2.3, 0, 0.09, 0, trim, Enum.Material.Metal)
	c("ChestTrim", 3.3, 0.14, 2.3, 0, 1.53, 0, trim, Enum.Material.Metal)
	for _, sx in ipairs({ -1.55, 1.55 }) do for _, sz in ipairs({ -1.05, 1.05 }) do c("ChestTrim", 0.22, 1.6, 0.22, sx, 0.8, sz, trim, Enum.Material.Metal) end end
	c("ChestLock", 0.36, 0.42, 0.12, 0, 1.12, -1.16, trim, Enum.Material.Metal)
	it.lidParts = {
		c("ChestLid", 3.2, 0.45, 2.2, 0, 1.83, 0, wood, Enum.Material.Foil),
		c("ChestLid", 3.0, 0.22, 1.8, 0, 2.16, 0, wood, Enum.Material.Foil),
		c("ChestLidTrim", 3.3, 0.12, 2.3, 0, 1.66, 0, trim, Enum.Material.Metal),
	}
	it.hinge = base * CFrame.new(0, 1.6, 1.1)
	local l = Instance.new("PointLight"); l.Color = Color3.fromRGB(255, 210, 80); l.Range = 16; l.Brightness = 3; l.Parent = it.part
	local sp = Instance.new("Sparkles"); sp.SparkleColor = Color3.fromRGB(255, 220, 90); sp.Parent = it.part
	table.insert(map.items, it)
	return it
end

return MapService
