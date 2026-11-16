--!nonstrict
-- Services/RunService: ciclo de vida de las partidas. Desde el cooperativo (2026-10-28) una partida es un MUNDO
-- (mapa, enemigos, botín, jefe, reloj y pausa compartidos) con 1 a 4 MIEMBROS (vida, armas, XP, ofertas y premios
-- propios). Cada miembro es una tabla "run" cuyo metatable delega en el mundo los campos de WORLD_KEYS, así que el
-- resto de los módulos (CombatService, Behaviors, OfferService, ItemEffects, ClassEffects) siguen usando run.x.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("GameShared")
local GameConfig = require(Shared.Config.GameConfig)
local OC = require(Shared.Config.MapObjectsConfig) -- 2026-11-06: objetos del mapa estilo MegaBonk (cantidades y reglas)
local Stats = require(Shared.Util.Stats)
local SeededRandom = require(Shared.Util.SeededRandom)
local ClassesCat = require(Shared.Catalogs.Classes)
local WeaponsCat = require(Shared.Catalogs.Weapons)
local TomesCat = require(Shared.Catalogs.Tomes)
local ItemsCat = require(Shared.Catalogs.Items)
local MapsCat = require(Shared.Catalogs.Maps)
local Progression = require(Shared.Util.Progression)

local Services = game:GetService("ServerScriptService").GameServer.Services
local GameServer = Services.Parent
local MapService = require(Services.MapService)
local Combat = require(Services.CombatService)
local ReturnToLobby = require(Services.ReturnToLobby)
local Offers = require(Services.OfferService)
local Profile = require(GameServer.Persistence.ProfileService)
local ClassEffects = require(GameServer.Classes.ClassEffects)
local Behaviors = require(GameServer.Weapons.Behaviors)
local Leaderboard = require(Services.LeaderboardService)
local CharacterSkin = require(Services.CharacterSkin)
local ItemEffects = require(GameServer.Items.ItemEffects)
local Missions = require(Shared.Catalogs.Missions)
local Upgrades = require(Shared.Catalogs.Upgrades)
local PetsCat = require(Shared.Catalogs.Pets)
local Brainrots = require(Shared.Visuals.Brainrots)
local BossDirector = require(GameServer.Bosses.BossDirector) -- jefes por mapa y nivel, ataques y dificultad escalable
local SpawnDirector = require(Services.SpawnDirector) -- aparición por créditos, eventos y Final Swarm (Config/SpawnConfig)
local SpawnConfig = require(Shared.Config.SpawnConfig)
local RunServiceRbx = game:GetService("RunService")
-- Cinemática del jefe (ServerScriptService.BossCinematic). Si falta, el juego sigue con el portal de siempre.
local BossCinematic = nil
do
	local folder = game:GetService("ServerScriptService"):FindFirstChild("BossCinematic")
	local mod = folder and folder:FindFirstChild("BossCinematicService")
	if mod then
		local ok, res = pcall(require, mod)
		if ok then BossCinematic = res else warn("[BossCinematic] no se pudo cargar: " .. tostring(res)) end
	end
end

local RunService = {}
local HttpService = game:GetService("HttpService")
-- etiqueta única de ESTE servidor: los ids de run no se repiten entre servidores (r<usuario>_<n> empezaba de 0 en cada
-- servidor y la liquidación idempotente podía tomar la run de otro servidor como "duplicada")
local SERVER_TAG = string.sub((HttpService:GenerateGUID(false):gsub("%-", "")), 1, 8)
local remotes = nil
local runs = {}      -- [userId] = miembro (una partida activa por jugador)
local worlds = {}    -- mundos activos
local slots = {}     -- zonas del mapa ocupadas (cada mundo tiene su propio origen: nunca se pisan)
local runCounter = 0
local D = GameConfig.director
local COOP = GameConfig.coop
local recordHorde -- (se define más abajo)

-- Campos que pertenecen al MUNDO (compartidos por todos los miembros). El resto es personal de cada jugador.
local WORLD_KEYS = {
	world = true, members = true, slot = true, origin = true, folder = true, map = true, mapId = true, mapLevel = true, seed = true,
	stage = true, stages = true, state = true, prevState = true, paused = true, pauseReasons = true, clock = true, tickN = true,
	enemies = true, enemyCount = true, nextEnemyId = true, grid = true, enemyFolder = true, lootFolder = true, loot = true,
	lootCount = true, nextLootId = true, frozenCount = true, enemyShots = true, nextShotId = true, nextProjId = true,
	nextZoneId = true, fxQueue = true, phase = true, boss = true, bossStarted = true, bossZones = true, bossClock = true,
	bossDefeated = true, clearedStage = true, stageKills = true, spawnAcc = true, curseActive = true, curseCount = true,
	statues = true, nextPortal = true, hordeStart = true, overtimeStage = true, stagesCompleted = true, victory = true,
	stageSilverBonus = true, hiddenUnlock = true, allShrinesCount = true, devNoSpawn = true, coopN = true,
	coopHpMul = true, coopDmgMul = true, ended = true, wiping = true, mapDef_bossTag = true,
}
RunService.WORLD_KEYS = WORLD_KEYS
-- `cinematic` también es del mundo
WORLD_KEYS.cinematic = true
-- estado del director de aparición (SpawnDirector): créditos, eventos, estadísticas
WORLD_KEYS.spawnDir = true
-- 2026-11-11: una fase por nivel. Nivel con el que empezó la partida y pase automático al siguiente nivel
WORLD_KEYS.startLevel = true
WORLD_KEYS.advancing = true

function RunService.setRemotes(r) remotes = r end

local function lobbyCFrame()
	local sp = workspace:FindFirstChild("SpawnLocation")
	return sp and (sp.CFrame + Vector3.new(0, 4, 0)) or CFrame.new(0, 10, 0)
end

local function getChar(run)
	local p = run.player
	local c = p.Character
	if not c then return nil end
	local hum = c:FindFirstChildOfClass("Humanoid")
	local hrp = c:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 then return nil end
	return c, hum, hrp
end

local function send(run, name, payload)
	if remotes and run.player.Parent and not rawget(run, "over") then remotes[name]:FireClient(run.player, payload) end
end

-- miembros que siguen en la partida (vivos o caídos)
local function active(world)
	local out = {}
	for _, m in ipairs(world.members) do if not rawget(m, "over") then out[#out + 1] = m end end
	return out
end
-- miembros en pie (pueden moverse, atacar y ser atacados)
local function standing(world)
	local out = {}
	for _, m in ipairs(world.members) do if not rawget(m, "over") and not m.downed then out[#out + 1] = m end end
	return out
end
-- miembro "anfitrión" para los pasos del mundo (dificultad, RNG del director): el primero activo
local function host(world)
	for _, m in ipairs(world.members) do if not rawget(m, "over") then return m end end
	return nil
end
RunService.active, RunService.standing = active, standing

local function sendAll(world, name, payload)
	for _, m in ipairs(active(world)) do send(m, name, payload) end
end
-- ===== Final Swarm (antes "súper oleada"; parámetros en Config/SpawnConfig.finalSwarm) =====
-- Se activa UNA vez por etapa: a los 10 min de la etapa o al morir el jefe (lo que pase primero). Sigue hasta el viaje al
-- siguiente nivel (newStage la apaga) o hasta que termine su duración, si tiene. Si ya está activa, otra llamada no la
-- reinicia ni la duplica; si ya terminó en esta etapa (onEnd = "calm"), no vuelve a empezar.
local function activateSuperHorde(world, reason)
	if world.superHorde then return false end
	if world.spawnDir and world.spawnDir.finalDone then return false end
	world.superHorde = { start = world.clock.t, reason = reason, stage = world.stage }
	world.hordeStart = world.clock.t
	if reason == "time" then sendAll(world, "Toast", { text = "¡FINAL SWARM! Cada segundo aparecen más enemigos y pegan más fuerte." }) end
	return true
end
RunService.activateSuperHorde = activateSuperHorde

BossDirector.init({ getChar = getChar, active = active, standing = standing, send = send, sendAll = sendAll, Combat = Combat, MapService = MapService })

-- ===== Pausa por mundo (razones por miembro: "offer:r123_4") =====
local function applyMovement(run)
	local _, hum = getChar(run)
	if not hum then return end
	if run.paused or run.downed or run.noMove then -- noMove = desafío "Sin moverse"
		hum.WalkSpeed = 0
		hum.JumpHeight = 0
	else
		local mul = run.stats:get("moveSpeedMultiplier") * ClassEffects.moveSpeedMultiplier(run)
		if run.inWater then mul *= MapService.WATER_SLOW end -- el agua frena
		if run.slideUntil and run.clock.t < run.slideUntil then
			-- deslizamiento (x1,9). 2026-11-05: en BAJADA acelera más (hasta x1,9 extra según la pendiente)
			local slideMul = 1.9
			local f = run.facing
			if f and run.map and run.map.height then
				local h0 = run.map.height(run.px, run.pz)
				local h1 = run.map.height(run.px + f.X * 3, run.pz + f.Z * 3)
				local drop = (h0 - h1) / 3 -- >0 = bajada
				if drop > 0.05 then slideMul *= 1 + math.min(1, drop * 2.5) end
			end
			mul *= slideMul
		end
		if run.bossSlowUntil and run.clock.t < run.bossSlowUntil then mul *= (run.bossSlowMul or 0.6) end -- habilidades de jefe (lianas, rugido, charcos…)
		hum.UseJumpPower = false
		-- solo se escribe si cambió (se llama a menudo: no genera tráfico de red de más)
		local ws = GameConfig.baseWalkSpeed * mul
		if math.abs(hum.WalkSpeed - ws) > 0.01 then hum.WalkSpeed = ws end
		local jh = run.stats:get("jumpHeightStuds")
		if math.abs(hum.JumpHeight - jh) > 0.01 then hum.JumpHeight = jh end
	end
end

BossDirector.addDep("applyMovement", applyMovement)

local function applyMovementAll(world)
	for _, m in ipairs(active(world)) do applyMovement(m) end
end

local function pause(run, reason)
	local world = run.world
	world.pauseReasons[reason .. ":" .. run.id] = { by = run, reason = reason }
	world.paused = true
	if world.state == "Playing" or world.state == "BossEncounter" then world.prevState = world.state; world.state = (reason == "offer") and "OfferPending" or "Paused" end
	applyMovementAll(world)
end

local function resume(run, reason)
	local world = run.world
	world.pauseReasons[reason .. ":" .. run.id] = nil
	if next(world.pauseReasons) == nil then
		world.paused = false
		if world.state == "Paused" or world.state == "OfferPending" then world.state = world.prevState or "Playing" end
	end
	applyMovementAll(world)
end

-- quita todas las razones de pausa de un miembro (al salir de la partida)
local function clearPauses(run)
	local world = run.world
	for k, v in pairs(world.pauseReasons) do if v.by == run then world.pauseReasons[k] = nil end end
	if next(world.pauseReasons) == nil and world.paused then
		world.paused = false
		if world.state == "Paused" or world.state == "OfferPending" then world.state = world.prevState or "Playing" end
	end
	applyMovementAll(world)
end

if BossCinematic then
	BossCinematic.init({
		RunService = RunService, BossDirector = BossDirector, MapService = MapService,
		getChar = getChar, active = active, standing = standing, send = send, sendAll = sendAll,
		pause = pause, resume = resume,
	})
end

-- ===== Caído / revivir (cooperativo) =====
local function removeDownMarker(run)
	if run.downMarker then run.downMarker:Destroy(); run.downMarker = nil end
end

local function setDowned(run)
	run.downed = true
	run.hp = 0
	run.reviveP = 0
	run.slideUntil = nil
	-- la oferta abierta vuelve a la cola: se elige al revivir
	if run.activeOffer then
		local o = run.activeOffer
		run.activeOffer = nil
		table.insert(run.offerQueue, 1, { kind = o.kind })
		send(run, "OfferClose", { offerId = o.id, result = "downed" })
	end
	Behaviors.clear(run)
	clearPauses(run)
	applyMovement(run)
	local _, _, hrp = getChar(run)
	local ring = Instance.new("Part")
	ring.Name = "DownedRing_" .. run.player.Name
	ring.Shape = Enum.PartType.Cylinder; ring.Size = Vector3.new(0.3, COOP.reviveRadius * 2, COOP.reviveRadius * 2)
	ring.Color = Color3.fromRGB(255, 70, 90); ring.Material = Enum.Material.Neon; ring.Transparency = 0.55
	ring.Anchored = true; ring.CanCollide = false; ring.CanQuery = false; ring.CanTouch = false; ring.CastShadow = false
	ring.CFrame = CFrame.new(hrp and (hrp.Position - Vector3.new(0, 2.6, 0)) or (run.origin + Vector3.new(run.px, 0.2, run.pz))) * CFrame.Angles(0, 0, math.pi / 2)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(220, 50); bb.StudsOffsetWorldSpace = Vector3.new(0, 6, 0); bb.AlwaysOnTop = true; bb.MaxDistance = 250
	local tl = Instance.new("TextLabel")
	tl.Name = "Text"; tl.Size = UDim2.fromScale(1, 1); tl.BackgroundTransparency = 1; tl.Font = Enum.Font.GothamBlack; tl.TextScaled = true
	tl.TextColor3 = Color3.fromRGB(255, 90, 110); tl.TextStrokeTransparency = 0; tl.Text = "¡" .. run.player.DisplayName .. " CAYÓ! 0%"
	tl.Parent = bb; bb.Parent = ring
	ring.Parent = run.world.folder
	run.downMarker = ring
	sendAll(run.world, "Toast", { text = ("¡%s cayó! Quédate a su lado %d s para revivirlo."):format(run.player.DisplayName, COOP.reviveTime) })
end

local function revive(run, pct)
	if not run.downed then return end
	run.downed = false
	run.reviveP = 0
	run.hp = math.max(1, run.stats:get("maxHp") * (pct or COOP.reviveHpPct))
	run.invulnUntil = run.clock.t + GameConfig.combat.spawnInvuln
	removeDownMarker(run)
	applyMovement(run)
	Combat.fx(run, "b", run.px, 1, run.pz, 6, 120, 255, 150, 0.5)
	Offers.pump(run) -- mejoras pendientes de cuando estaba caído
end

-- ===== Creación =====
local function allocSlot()
	for i = 1, 200 do if not slots[i] then slots[i] = true; return i end end
	return 201
end

local function newStage(world)
	-- el mapa se genera por lotes (unos segundos): congelamos a los jugadores para que no caigan mientras tanto
	for _, m in ipairs(active(world)) do
		local _, _, hrp = getChar(m)
		if hrp then hrp.Anchored = true end
	end
	if world.map then MapService.destroy(world.map) end
	local mapRng = SeededRandom.new(world.seed + world.stage * 977)
	world.map = MapService.generate({ mapId = world.mapId, mapLevel = world.mapLevel, stage = world.stage, seed = world.seed, origin = world.origin, parent = world.folder, rng = mapRng })
	world.enemyFolder = world.map.folder:FindFirstChild("Enemies") or Instance.new("Folder")
	world.enemyFolder.Name = "Enemies"; world.enemyFolder.Parent = world.map.folder
	world.lootFolder = Instance.new("Folder"); world.lootFolder.Name = "Loot"; world.lootFolder.Parent = world.map.folder
	world.cinematic = nil
	if BossCinematic then -- ProximityPrompt (E) en el portal si el jefe de este mapa tiene cinemática
		local okC, errC = pcall(BossCinematic.setupWorld, world)
		if not okC then warn("[BossCinematic] " .. tostring(errC)) end
	end
	world.phase = "normal"
	world.superHorde = nil; world.hordeStart = nil; world.overtimeStage = nil -- súper oleada: contador y multiplicadores a cero
	world.clock.stageT = 0
	world.stageKills = 0
	world.spawnAcc = 0
	SpawnDirector.resetStage(world.spawnDir) -- créditos, eventos programados y Final Swarm de la nueva etapa
	BossDirector.cleanup(world) -- limpia ataques, efectos y ambiente del jefe anterior
	world.boss = nil
	world.bossList = nil; world.lastBossKilled = nil
	world.eventBosses = nil; world.encDone = {}; world.bloody = nil -- encuentros del temporizador y estatuas de jefe por etapa
	world.bossZones = {}
	world.curseActive = false
	world.nextPortal = nil
	world.bossStarted = false
	Combat.clearEnemies(world)
	world.loot = {}; world.lootCount = 0
	local names = {}
	for _, m in ipairs(active(world)) do names[#names + 1] = m.player.DisplayName end
	for _, m in ipairs(active(world)) do
		if m.downed then revive(m, COOP.reviveHpPct) end -- nueva etapa: los caídos vuelven
		m.px, m.pz = 0, 0
		m.inWater = false
		m.lastSafe = Vector3.new(0, 3.5, 0)
		m.charging = nil
		Behaviors.clear(m)
		m.summons = {}
		m.invulnUntil = world.clock.t + GameConfig.combat.spawnInvuln
		send(m, "StageInfo", { runId = m.id, classId = m.classId, stage = world.stage, stages = world.stages, mapId = world.mapId, mapLevel = world.mapLevel,
			half = world.map.half, origin = world.origin, water = world.map.water, mountains = world.map.mountains, height = world.map.heightParams,
			landmarks = world.map.landmarks, routes = world.map.routes,
			coop = #names > 1 and names or nil })
	end
end

local function teleportToSpawn(world)
	local list = active(world)
	for i, m in ipairs(list) do
		local _, _, hrp = getChar(m)
		if hrp then
			local off = (i - (#list + 1) / 2) * 4
			hrp.CFrame = CFrame.new(world.map.spawnPos + Vector3.new(off, 0, 0)); hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.Anchored = false
		end
	end
end

function RunService.get(player) return runs[player.UserId] end

local function newWorld(mapId, mapLevel, seed, n)
	local slot = allocSlot()
	local world = {
		slot = slot, members = {}, origin = Vector3.new(2000 + (slot - 1) * 3000, 0, 0),
		mapId = mapId, mapLevel = mapLevel, stage = 1, stages = 4 - mapLevel, startLevel = mapLevel, seed = seed, -- 2026-11-11: una fase por nivel; se juegan los niveles que faltan hasta el 3
		state = "Generating", paused = false, pauseReasons = {}, clock = { t = 0, stageT = 0, total = 0 }, tickN = 0,
		enemies = {}, enemyCount = 0, nextEnemyId = 0, grid = {}, enemyShots = {}, nextShotId = 0, nextProjId = 0, nextZoneId = 0,
		loot = {}, lootCount = 0, nextLootId = 0, frozenCount = 0, fxQueue = {}, stageKills = 0, stagesCompleted = 0,
		curseCount = 0, allShrinesCount = 0,
		coopN = n, coopHpMul = 1 + COOP.hpPerExtra * (n - 1), coopDmgMul = 1 + COOP.dmgPerExtra * (n - 1), ended = false,
		spawnDir = SpawnDirector.newState(),
	}
	world.world = world
	world.folder = Instance.new("Folder")
	world.folder.Name = string.format("World%d_%d", slot, runCounter + 1)
	world.folder.Parent = workspace:WaitForChild("Runtime"):WaitForChild("Runs")
	return world
end

local function makeMember(world, player, classId, idx)
	local classDef = ClassesCat.byId[classId]
	local rec = Profile.get(player)
	runCounter += 1
	local run = {
		id = string.format("r%d_%d_%s", player.UserId, runCounter, SERVER_TAG), player = player, classId = classId, classDef = classDef, idx = idx,
		rng = SeededRandom.streams(world.seed + idx * 104729), over = false,
		level = 0, xp = 0, xpAcc = 0, goldAcc = 0, silverAcc = 0, kills = 0, gold = 0, silverEarned = 0, shield = 0,
		weapons = {}, tomes = {}, tomeCount = 0, items = {}, banished = {}, offerQueue = {}, nextOfferId = 0,
		rerolls = GameConfig.progression.rerollsPerRun, skips = GameConfig.progression.skipsPerRun, banishes = GameConfig.progression.banishesPerRun,
		refreshUsed = 0, nextModId = 1, log = {},
		projectiles = {}, zones = {},
		invulnUntil = 0, lastDamageAt = -99, px = 0, pz = 0, moveDelta = 0, chainBudget = 8, summons = {}, bobAcc = 0,
		stats_damageDealt = 0, stats_damageTaken = 0, stats_picks = 0, handled = {}, handledOrder = {},
		fallCd = 0, dev = Profile.isDevMemory, downed = false, reviveP = 0,
	}
	setmetatable(run, {
		__index = world,
		__newindex = function(t, k, v)
			if WORLD_KEYS[k] then world[k] = v else rawset(t, k, v) end
		end,
	})
	-- solo lo desbloqueado en la tienda puede salir en las ofertas de nivel
	run.ownedWeapons = table.clone(rec.data.ownedWeapons or {})
	run.ownedTomes = table.clone(rec.data.ownedTomes or {})
	run.ownedItems = table.clone(rec.data.ownedItems or {})
	run.isTank = Missions.TANKS[classId] == true
	local pd = rec.data
	local function up(id) return Upgrades.value(id, Profile.upgradeLevel(pd, id)) end
	run.weaponSlots = up("up_weapons"); run.tomeSlots = up("up_tomes")
	run.rerolls = up("up_refresh"); run.skips = up("up_skip"); run.banishes = up("up_banish")
	run.silverBonus = up("up_silver")
	for id in pairs(pd.disabled or {}) do run.ownedWeapons[id] = nil; run.ownedTomes[id] = nil; run.ownedItems[id] = nil end
	run.skinId = pd.equippedSkins and pd.equippedSkins[classId] or nil
	run.dmgBy = {}
	run.m = {
		add = { kills = 0, deaths = 0, chests = 0, pots = 0, shrines = 0, fired = 0, blocks = 0, lifesteal = 0, eliteKills = 0, idleKills = 0, tankKills = 0, killsTag = {}, killsWeapon = {} },
		max = { hordeTime = 0, luckDrop = 0, bossNoHit = 0, curseClears = 0, allShrinesStage = 0, allShrinesRun = 0 },
		min = { bossFast = 0, bossStageTime = 0 },
	}
	run.potsRun = 0; run.critsRun = 0
	run.stats = Stats.newSheet(table.clone(classDef.overrides))
 if player:GetAttribute("RobuxVIP") == true then
  run.stats:addModifier("vip_xp", "vip", "xpMultiplier", "flat", 0.10)
  run.stats:addModifier("vip_damage", "vip", "damageMultiplier", "flat", 0.10)
 end
	run.stats:setBase("maxHp", classDef.maxHp)
	run.stats:setBase("moveSpeedMultiplier", classDef.moveSpeedMultiplier)
	run.stats:setBase("jumpHeightStuds", classDef.jumpHeightStuds)
	run.stats:setBase("pickupRadiusStuds", classDef.pickupRadiusStuds)
	if run.silverBonus > 0 then run.stats:addModifier("up_silver", "upgrade", "silverMultiplier", "flat", run.silverBonus) end
	-- hasta 3 mascotas: cada una suma su bonus y te sigue detrás (el cliente las dibuja con el atributo PetIds)
	local petIds = {}
	for i, id in ipairs(Profile.equippedList(pd)) do
		local pet = PetsCat.byId[id]
		run.stats:addModifier("pet_bonus_" .. i, "pet", pet.stat, pet.op, pet.value)
		table.insert(petIds, id)
	end
	run.petIds = petIds; run.petId = petIds[1]
	-- 2026-11-05: modo de desafío (ajuste del perfil). Solo cambia esta partida; da más plata al final.
	local cm = pd.settings and tonumber(pd.settings.challengeMode) or 0
	local ch = GameConfig.challenges and GameConfig.challenges[cm]
	if ch then
		run.challenge = ch
		if ch.id == "fragile" then run.stats:addModifier("ch_fragile", "challenge", "maxHp", "mult", 0.5)
		elseif ch.id == "double" then run.stats:addModifier("ch_double", "challenge", "difficulty", "flat", 1)
		elseif ch.id == "still" then run.noMove = true end
	end
	-- SOLO Studio: daño infinito de prueba (GameConfig.profile.devInfiniteDamage). En servidores publicados no hace nada.
	if game:GetService("RunService"):IsStudio() and (GameConfig.profile.devInfiniteDamage or {})[classId] then
		run.stats:addModifier("dev_inf_dmg", "dev", "damageMultiplier", "flat", 1e6)
		run.devInfDamage = true
	end
	player:SetAttribute("PetId", nil)
	player:SetAttribute("PetIds", #petIds > 0 and table.concat(petIds, ",") or nil)
	run.hp = run.stats:get("maxHp") -- arranca con la vida llena ya con mascotas (+6% de Mini Lirilì) y desafío Frágil (2026-11-06)
	run.shield = run.stats:get("shieldMax")
	run.send = function(name, payload) send(run, name, payload) end
	run.pause = pause; run.resume = resume
	run.onPlayerDeath = function(r, why) RunService.die(r, why) end
	run.onBossDefeated = function(r) RunService.bossDefeated(r) end
	run.onPickup = function(r, l) RunService.pickup(r, l) end
	ClassEffects.init(run)
	Behaviors.addWeapon(run, classDef.startWeaponId)
	return run
end

-- Valida a un jugador para entrar a una partida
local function canJoin(player, classId)
	if player:GetAttribute("ReturningToLobby") then return false, "returning_to_lobby" end
	if runs[player.UserId] and not runs[player.UserId].over then return false, "run_active" end
	if not ClassesCat.byId[classId] then return false, "invalid_ids" end
	if not Profile.canUseClass(player, classId) then return false, "class_locked" end
	if not Profile.get(player) then return false, "no_profile" end
	if not getChar({ player = player }) then return false, "no_character" end
	return true
end
RunService.canJoin = canJoin

-- entries = { { player = Player, classId = "class_01" }, ... } (1 a 4). El primero es el líder.
function RunService.startGroup(entries, mapId, mapLevel, devSeed, deferStart)
	if #entries < 1 or #entries > COOP.maxPlayers then return nil, "invalid_group" end
	local mapDef = MapsCat.byId[mapId]
	if not mapDef then return nil, "invalid_ids" end
	if not (mapLevel == 1 or mapLevel == 2 or mapLevel == 3) then return nil, "invalid_level" end
	local leader = entries[1].player
	local lrec = Profile.get(leader)
	if not lrec then return nil, "no_profile" end
	if not Progression.isLevelUnlocked(lrec.data.mapProgress, mapId, mapLevel) then return nil, "map_locked" end
	for _, e in ipairs(entries) do
		local ok, err = canJoin(e.player, e.classId)
		if not ok then return nil, err, e.player end
	end
	local seed = devSeed or (os.time() * 31 + (runCounter + 1) * 7919 + leader.UserId % 10007)
	local world = newWorld(mapId, mapLevel, seed, #entries)
	world.mapDef_bossTag = mapDef.bossTag
	for i, e in ipairs(entries) do
		local m = makeMember(world, e.player, e.classId, i)
		table.insert(world.members, m)
		runs[e.player.UserId] = m
	end
	table.insert(worlds, world)
	newStage(world)
	for _, m in ipairs(world.members) do
		pcall(CharacterSkin.apply, m.player, m.classId, m.skinId)
	end
	if deferStart then
		world.prepared = true -- mapa replicado; reloj, enemigos y movimiento siguen detenidos
		return world.members[1], world
	end
	teleportToSpawn(world)
	for _, m in ipairs(world.members) do Profile.registerRunStart(m.player, m.classId, mapId, mapLevel) end
	world.state = "Playing"
	applyMovementAll(world)
	return world.members[1], world
end

function RunService.releasePrepared(world)
	if not world or not world.prepared or world.ended or not world.map then return false end
	for _, m in ipairs(world.members) do
		if not m.player.Parent or runs[m.player.UserId] ~= m then return false end
	end
	world.prepared = false
	for _, m in ipairs(world.members) do Profile.registerRunStart(m.player, m.classId, world.mapId, world.mapLevel) end
	teleportToSpawn(world)
	world.state = "Playing"
	applyMovementAll(world)
	return true
end

-- Partida en solitario (misma ruta que el cooperativo, con un único miembro)
function RunService.start(player, classId, mapId, mapLevel, devSeed)
	local r, err = RunService.startGroup({ { player = player, classId = classId } }, mapId, mapLevel, devSeed)
	if r then return r, nil end -- (startGroup devuelve el mundo como 2.º valor: nunca mandarlo como error)
	return nil, err
end

-- ===== Recogibles =====
function RunService.pickup(run, l)
	local st = run.stats
	if l.kind == "xp" then
		run.xpAcc += l.value * st:get("xpMultiplier")
		local whole = math.floor(run.xpAcc)
		run.xpAcc -= whole
		run.xp += whole
		while run.xp >= Stats.xpForLevel(run.level) do
			run.xp -= Stats.xpForLevel(run.level)
			run.level += 1
			ClassEffects.onLevelUp(run, run.level, run.level)
			Offers.queue(run, "level")
		end
	elseif l.kind == "gold" then
		run.goldAcc += l.value * st:get("goldMultiplier")
		local whole = math.floor(run.goldAcc)
		run.goldAcc -= whole; run.gold += whole
	elseif l.kind == "silver" then
		local premium = Profile.get(run.player)
		local boost = premium and (premium.data.moneyBoostUntil or 0) > os.time() and 2 or 1
		run.silverAcc += l.value * st:get("silverMultiplier") * boost
		local whole = math.floor(run.silverAcc)
		run.silverAcc -= whole
		if whole > 0 then run.silverEarned += whole; Profile.addSilverMidRun(run.player, whole) end
	elseif l.kind == "heal" then
		-- POTENCIADOR cura: % de la vida máxima × "Potenciadores"
		local P = GameConfig.economy.powerups
		local h = Combat.heal(run, st:get("maxHp") * P.healPct * st:get("powerupMultiplier"))
		Combat.fx(run, "b", run.px, 2, run.pz, 4, 255, 80, 100, 0.4)
		Combat.fx(run, "PU", "heal", run.px, run.pz)
		send(run, "Toast", { text = ("?? Cura: +%d de vida"):format(math.floor(h + 0.5)), short = true })
	elseif l.kind == "apple" then
		local h = Combat.heal(run, l.value)
		Combat.fx(run, "b", run.px, 2, run.pz, 3, 255, 80, 80, 0.3)
		if h > 0 then send(run, "Toast", { text = ("?? +%d de vida"):format(math.floor(h + 0.5)), short = true }) end
	elseif l.kind == "magnet" then
		-- POTENCIADOR imán: trae TODA la experiencia del mapa (dura más con "Potenciadores")
		local P = GameConfig.economy.powerups
		run.magnetUntil = run.clock.t + P.magnetSeconds * st:get("powerupMultiplier")
		for _, o in pairs(run.loot) do
			if (o.kind == "xp" or o.kind == "gold" or o.kind == "silver" or Combat.POWERUP_KINDS[o.kind]) and (not o.pulledBy or o.pulledBy == run) then o.pulled = true; o.pulledBy = run; o.magnetized = true end
		end
		Combat.fx(run, "b", run.px, 2, run.pz, 10, 90, 170, 255, 0.5)
		Combat.fx(run, "PU", "magnet", run.px, run.pz)
		send(run, "Toast", { text = "?? ¡Imán! La experiencia, el oro, la plata y los potenciadores vienen hacia vos.", short = true })
	elseif l.kind == "bomb" then
		-- POTENCIADOR bomba: mata a TODOS los enemigos del mapa (no al jefe; al jefe le saca un poco)
		local P = GameConfig.economy.powerups
		local list = {}
		for _, e in pairs(run.enemies) do if not e.dead then list[#list + 1] = e end end
		-- 2026-11-05: efecto visible. Se mandan las posiciones de hasta 40 enemigos (los más cercanos) para que exploten uno por uno
		table.sort(list, function(a, b) return (a.x - run.px) ^ 2 + (a.z - run.pz) ^ 2 < (b.x - run.px) ^ 2 + (b.z - run.pz) ^ 2 end)
		local pts = {}
		for i = 1, math.min(#list, 40) do pts[#pts + 1] = math.floor(list[i].x); pts[#pts + 1] = math.floor(list[i].z) end
		Combat.fx(run, "CP", "nuke", run.px, run.pz, pts)
		local n = 0
		for _, e in ipairs(list) do
			if e.boss then
				Combat.hit(run, e, { amount = e.maxHp * P.bombBossPct * st:get("powerupMultiplier"), weaponId = "powerup_bomb", tags = {}, canCrit = false, noLifesteal = true, noProcs = true, depth = 1 })
			elseif not e.dead then
				n += 1
				Combat.kill(run, e, { weaponId = "powerup_bomb", tags = {}, noProcs = true, noExplode = true })
			end
		end
		Combat.fx(run, "X", run.px, run.pz, 18)
		Combat.fx(run, "PU", "bomb", run.px, run.pz)
		sendAll(run.world, "Toast", { text = ("?? ¡BOMBA! %d enemigos eliminados."):format(n) })
	elseif l.kind == "freeze" then
		-- POTENCIADOR congelación: el tiempo se detiene para TODOS los enemigos del mapa (no el jefe)
		local P = GameConfig.economy.powerups
		local ws = run.world or run
		local secs = P.freezeSeconds * st:get("powerupMultiplier")
		ws.timeStopUntil = math.max(ws.timeStopUntil or 0, run.clock.t + secs)
		run.enemyShots = {}
		Combat.fx(run, "b", run.px, 2, run.pz, 40, 150, 235, 255, 0.8)
		Combat.fx(run, "PU", "freeze", run.px, run.pz)
		sendAll(run.world, "Toast", { text = ("?? ¡Tiempo congelado! %d s"):format(math.floor(secs + 0.5)) })
	end
end

-- ===== Invocaciones (Fantasma / Bob) =====
local function summon(run, ttl, dmg, source)
	if #run.summons >= ItemsCat.summonCap then
		run.summons[#run.summons].dmg += dmg
		return
	end
	table.insert(run.summons, { x = run.px, z = run.pz, ttl = ttl, dmg = dmg, source = source })
	Combat.fx(run, "b", run.px, 2, run.pz, 1.5, 200, 220, 255, 0.3)
end

local function onInteractionCompleted(run)
	local n = run.items.item_03 or 0
	if n > 0 then summon(run, ItemsCat.ghost.ttl, ItemsCat.ghost.damage * n, "item_03") end
end

local function stepSummons(run, dt)
	for i = #run.summons, 1, -1 do
		local s = run.summons[i]
		s.ttl -= dt
		local t = Combat.nearest(run, s.x, s.z, 30)
		if t then
			local dx, dz = t.x - s.x, t.z - s.z
			local d = math.max(0.01, math.sqrt(dx * dx + dz * dz))
			s.x += dx / d * 26 * dt; s.z += dz / d * 26 * dt
			if d < 2.5 then
				Combat.hit(run, t, { amount = s.dmg, tags = {}, weaponId = s.source, canCrit = false, noLifesteal = true, noProcs = true, depth = 1 })
				table.remove(run.summons, i)
				continue
			end
		end
		if s.ttl <= 0 then table.remove(run.summons, i) end
	end
end

-- ===== Interacciones =====
-- precio del próximo cofre pagado: GameConfig.economy.chestCosts y después sigue creciendo (chestCostGrowth)
local function chestCostFor(n)
	local E = GameConfig.economy
	local list = E.chestCosts or { E.chestCost }
	if n < #list then return list[n + 1] end
	local last = list[#list]
	local step = (#list >= 2) and (list[#list] - list[#list - 1]) or last
	for _ = #list, n do
		step = step * (E.chestCostGrowth or 1.08)
		last += math.floor(step + 0.5)
	end
	return last
end
RunService.chestCostFor = chestCostFor
local function chestPrice(run, it)
	if (it.cost or 0) <= 0 then return 0 end -- cofre dorado gratis
	return chestCostFor(rawget(run, "paidChests") or 0)
end

local function findItem(run, id)
	for _, it in ipairs(run.map.items) do if it.id == id then return it end end
end

function RunService.interact(run, interactionId)
	if run.over or run.downed or run.paused or (run.state ~= "Playing" and run.state ~= "BossEncounter" and run.state ~= "StageComplete") then return false, "state" end
	local it = findItem(run, interactionId)
	if not it then return false, "invalid" end
	local _, _, hrp = getChar(run)
	if not hrp then return false, "no_char" end
	local p = hrp.Position - run.origin
	local d = math.sqrt((p.X - it.x) ^ 2 + (p.Z - it.z) ^ 2)
	if d > 11 then return false, "too_far" end
	if it.used then return false, "used" end
	local t = run.clock.t
	if it.kind == "chest" then
		local cost = chestPrice(run, it)
		if run.gold < cost then return false, "no_gold" end
		run.gold -= cost; it.used = true
		run.m.add.chests += 1
		if cost > 0 then rawset(run, "paidChests", (rawget(run, "paidChests") or 0) + 1) end
		-- Llave: si lo abrió gratis (devuelve el oro), el precio no sube
		if ItemEffects.onChestOpen(run, cost) and cost > 0 then rawset(run, "paidChests", rawget(run, "paidChests") - 1) end
		if it.lidParts and it.hinge then
			local rot = it.hinge * CFrame.Angles(1.25, 0, 0) * it.hinge:Inverse()
			for _, lp in ipairs(it.lidParts) do
				TweenService:Create(lp, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = rot * lp.CFrame }):Play()
			end
		end
		local sp = it.part:FindFirstChildOfClass("Sparkles"); if sp then sp.Enabled = false end
		Combat.fx(run, "b", it.x, 2, it.z, 4, 255, 210, 80, 0.4)
		onInteractionCompleted(run)
		Offers.queue(run, "chest")
		return true
	elseif it.kind == "moai" then
		it.used = true
		onInteractionCompleted(run)
		Offers.queue(run, "moai")
		return true
	elseif it.kind == "gift" then
		it.used = true
		it.part.Transparency = 1
		local first = Profile.grantHat(run.player, "hat_01")
		send(run, "Toast", { text = first and "¡Regalo! Sombrero festivo desbloqueado." or "Regalo ya reclamado." })
		onInteractionCompleted(run)
		return true
	elseif it.kind == "curse" then
		if run.bossStarted or run.curseActive then return false, "too_late" end
		it.used = true; run.curseActive = true; run.curseCount += 1
		it.part.Color = Color3.fromRGB(60, 10, 20)
		onInteractionCompleted(run)
		sendAll(run.world, "Toast", { text = ("Maldición activada por %s: el jefe tiene +25%% de vida y +10%% de daño; +20%% de plata."):format(run.player.DisplayName) })
		return true
	elseif it.kind == "statue" then
		it.used = true
		run.statues = (run.statues or 0) + 1
		it.part.Color = Color3.fromRGB(70, 20, 20)
		local light = it.part:FindFirstChildOfClass("PointLight"); if light then light.Enabled = false end
		-- ESTATUA DE DIFICULTAD (MapObjectsConfig.difficultyStatue): +5% de dificultad GLOBAL para todo el grupo (sube vida,
		-- daño y velocidad de los enemigos NUEVOS y la presión de aparición; los que ya están vivos no se vuelven a
		-- multiplicar: el escalado se calcula una sola vez al aparecer). Premio por el riesgo: oro al instante y +oro/+XP.
		local PG = OC.difficultyStatue
		local goldGain = math.floor(PG.gold * (1 + PG.goldPerStage * ((run.stage or 1) - 1)))
		for _, m in ipairs(active(run.world)) do
			m.stats:addModifier("statue_diff_" .. run.statues, "statue", "difficulty", "flat", PG.difficulty)
			if PG.goldMultiplier > 0 then m.stats:addModifier("statue_gold_" .. run.statues, "statue", "goldMultiplier", "flat", PG.goldMultiplier) end
			if PG.xpMultiplier > 0 then m.stats:addModifier("statue_xp_" .. run.statues, "statue", "xpMultiplier", "flat", PG.xpMultiplier) end
			m.gold += goldGain
		end
		Combat.fx(run, "b", it.x, 2, it.z, 8, 230, 40, 40, 0.5)
		Combat.fx(run, "b", it.x, 5, it.z, 14, 255, 60, 40, 0.8)
		onInteractionCompleted(run)
		local total = math.floor(run.statues * PG.difficulty * 100 + 0.5)
		sendAll(run.world, "Toast", { text = ("?? Estatua de dificultad: +%d%% (total +%d%%). Premio: +%d de oro, +%d%% oro y +%d%% XP."):format(math.floor(PG.difficulty * 100 + 0.5), total, goldGain, math.floor(PG.goldMultiplier * 100 + 0.5), math.floor(PG.xpMultiplier * 100 + 0.5)) })
		return true
	elseif it.kind == "challenge" then
		-- 2026-11-05: santuario de desafío: aparecen enemigos élite marcados; si los matás a todos, cofre dorado gratis
		if it.active then return false, "used" end
		it.used = true; it.active = true; it.mobs = {}
		-- 2026-11-06: escala con el tiempo de la etapa y la etapa (MapObjectsConfig.challenge); además cada enemigo ya
		-- sale con el escalado normal por tiempo y por la dificultad actual (archetypeScale)
		local CH = OC.challenge
		local mins = run.clock.stageT / 60
		local n = math.min(CH.max, math.floor(CH.base + CH.perStage * ((run.world.stage or 1) - 1) + CH.perMinute * mins))
		local hpMul = CH.hpMul * (1 + CH.hpPerMinute * mins)
		local dmgMul = CH.dmgMul * (1 + CH.dmgPerMinute * mins)
		for k = 1, n do
			local a = k / n * math.pi * 2
			local kind = (k % 3 == 0) and "brute" or "chaser"
			local ex, ez = MapService.resolve(run.map, it.x + math.cos(a) * CH.ring, it.z + math.sin(a) * CH.ring, 1)
			local e = Combat.spawnEnemy(run, kind, ex, ez, { elite = true, hpMul = hpMul, dmgMul = dmgMul, xpMul = CH.xpMul })
			if e then
				e.challenge = it.id
				table.insert(it.mobs, e)
				pcall(function()
					local g = Instance.new("BillboardGui"); g.Size = UDim2.fromOffset(34, 34); g.StudsOffset = Vector3.new(0, e.visSize * 0.7 + 1.5, 0); g.AlwaysOnTop = true; g.LightInfluence = 0
					local l = Instance.new("TextLabel"); l.Size = UDim2.fromScale(1, 1); l.BackgroundTransparency = 1; l.Text = "??"; l.TextScaled = true; l.TextColor3 = Color3.fromRGB(200, 120, 255); l.Parent = g
					g.Parent = e.part
				end)
			end
		end
		it.part.Color = Color3.fromRGB(90, 40, 140)
		Combat.fx(run, "b", it.x, 2, it.z, 16, 170, 80, 255, 0.6)
		onInteractionCompleted(run)
		sendAll(run.world, "Toast", { text = ("?? ¡Desafío! Derrotá a los %d enemigos marcados para ganar un cofre."):format(#it.mobs) })
		return true
	elseif it.kind == "bloody" then
		-- santuario sangriento: el jefe viene con 2 minijefes; al vencerlo, 2 cofres dorados y +50% de plata en la etapa
		if run.bossStarted or run.world.bossStarted then return false, "too_late" end
		-- 2026-11-06: ESTATUA DE JEFE: suma UN JEFE ADICIONAL al PRÓXIMO encuentro de jefe (a los 7 min, a los 2 min o el
		-- del portal). Se acumulan: 3 estatuas = 3 jefes adicionales. Cada jefe adicional derrotado suelta un cofre dorado.
		it.used = true; run.world.bloody = (tonumber(run.world.bloody) or 0) + 1
		it.part.Color = Color3.fromRGB(70, 0, 10)
		Combat.fx(run, "b", it.x, 2, it.z, 10, 200, 20, 30, 0.6)
		onInteractionCompleted(run)
		local nb = run.world.bloody
		sendAll(run.world, "Toast", { text = ("?? %s activó una Estatua de jefe: el próximo encuentro trae %d jefe%s adicional%s (1 cofre dorado por cada uno)."):format(run.player.DisplayName, nb, nb > 1 and "s" or "", nb > 1 and "es" or "") })
		return true
	elseif it.kind == "merchant" then
		-- 2026-11-06: el comerciante guarda SU stock (it.stock): lo comprado desaparece de la tienda y la tienda se
		-- vuelve a abrir con lo que queda. Si te vas sin comprar, al volver tiene lo mismo. Cuando vende todo, se va.
		local CAT = { item = "objetos", weapon = "armas", tome = "tomos" }
		local function openShop(r)
			Offers.queue(r, "merchant", { title = ("Mercader de %s"):format(CAT[it.category or "item"] or "objetos"), tier = it.tier, category = it.category, holder = it, onChosen = function(r2, opt)
				if it.stock then
					for i, o in ipairs(it.stock) do if o.optionId == opt.optionId then table.remove(it.stock, i); break end end
				end
				Combat.fx(r2, "b", it.x, 2, it.z, 6, 255, 220, 120, 0.4)
				if not it.stock or #it.stock == 0 then
					it.used = true
					if it.part then it.part.Transparency = 1 end
					send(r2, "Toast", { text = "?? ¡Le compraste todo! El mercader se fue." })
				else
					send(r2, "Toast", { text = ("?? ¡Comprado! Le quedan %d cosas."):format(#it.stock), short = true })
					openShop(r2)
				end
			end })
		end
		openShop(run)
		return true
	elseif it.kind == "microwave" then
		local any = false
		for id, c in pairs(run.items) do if c > 0 then any = true break end end
		if not any then send(run, "Toast", { text = "? Necesitás al menos un objeto para usar el microondas." }); return false, "no_items" end
		Offers.queue(run, "microwave", { title = ("Microondas (%d/%d)"):format((it.uses or 0) + 1, OC.microwave.uses), tier = it.tier, uses = it.uses or 0, onChosen = function(r, opt)
			it.uses = (it.uses or 0) + 1
			Combat.fx(r, "b", it.x, 2.5, it.z, 4, 120, 255, 140, 0.4)
			if it.uses >= OC.microwave.uses then
				it.used = true
				Combat.fx(r, "X", it.x, it.z, 6)
				if it.part then it.part.Transparency = 1 end
				if it.ring then it.ring.Transparency = 1 end
				send(r, "Toast", { text = ("?? ¡El microondas explotó después de %d usos!"):format(OC.microwave.uses) })
			end
		end })
		return true
	elseif it.kind == "xpmagnet" then
		-- 2026-11-06: ATRACTOR DE EXPERIENCIA: toda la XP que ya está tirada en el mapa vuela físicamente hacia vos
		-- (no crea XP nueva ni duplica: marca los mismos fragmentos para que los atraiga stepLoot)
		it.used = true
		local n = 0
		for _, o in pairs(run.loot) do
			if o.kind == "xp" and (not o.pulledBy or o.pulledBy == run) then o.pulled = true; o.pulledBy = run; o.magnetized = true; n += 1 end
		end
		if it.part then it.part.Color = Color3.fromRGB(90, 90, 90); it.part.Transparency = 0.85 end
		if it.crystal then it.crystal.Color = Color3.fromRGB(80, 90, 85); it.crystal.Material = Enum.Material.Glass; local l = it.crystal:FindFirstChildOfClass("PointLight"); if l then l.Enabled = false end end
		Combat.fx(run, "b", it.x, 3, it.z, 14, 90, 255, 140, 0.6)
		Combat.fx(run, "PU", "magnet", run.px, run.pz)
		onInteractionCompleted(run)
		send(run, "Toast", { text = ("?? ¡Atractor de experiencia! %d fragmentos de XP vienen hacia vos."):format(n) })
		return true
	elseif it.kind == "pact" then
		-- 2026-11-06: ESTATUA ESPECIAL: 3 pactos (algunos con un lado malo); elegís uno o te vas (queda para después)
		Offers.queue(run, "pact", { title = "Estatua especial", onChosen = function(r, opt)
			it.used = true
			if it.part then it.part.Color = Color3.fromRGB(90, 90, 90) end
			if it.orb then it.orb.Color = Color3.fromRGB(70, 60, 80); it.orb.Material = Enum.Material.Glass; local l = it.orb:FindFirstChildOfClass("PointLight"); if l then l.Enabled = false end end
			Combat.fx(r, "b", it.x, 3, it.z, 10, 190, 110, 255, 0.6)
		end })
		return true
	elseif it.kind == "portal" then
		if run.bossStarted then return false, "used" end
		if it.pp then return false, "use_prompt" end -- este portal se activa con su ProximityPrompt (cinemática)
		it.used = true
		RunService.startBoss(run)
		return true
	elseif it.kind == "nextportal" then
		it.used = true
		RunService.nextStage(run)
		return true
	elseif it.kind == "exitportal" then
		it.used = true
		RunService.endWorld(run.world, "victory", "exit_portal")
		return true
	end
	return false, "invalid"
end

-- ===== Jefe =====
function RunService.startBoss(run, spawnOpts)
	local world = run.world
	if world.bossStarted or world.ended then return end
	local h = host(world) or run
	world.bossStarted = true
	world.phase = "boss"
	world.state = world.paused and world.state or "BossEncounter"
	world.prevState = "BossEncounter"
	for _, m in ipairs(active(world)) do recordHorde(m); m.bossHit = false end
	world.bossClock = 0
	-- (antes: se vaciaba el mundo y se llevaba al grupo a una arena; ahora el jefe sale del portal en el mapa actual)
	-- jefe del mapa y nivel actual (Config/BossConfig): vida y daño se calculan UNA vez, aquí, en el servidor
	local e = BossDirector.spawn(world, h, spawnOpts)
	if not e then
		warn("[Bosses] no se pudo crear el jefe de " .. tostring(world.mapId) .. " nivel " .. tostring(world.mapLevel))
		world.bossStarted = false; world.phase = "normal"; world.state = "Playing"; world.prevState = "Playing"
		return
	end
	sendAll(world, "Toast", { text = ("¡%s sale del portal! (vida %d · escalado a nivel %d)"):format(e.displayName, e.maxHp, world.lastBossInfo.playerLevel) })
	local extra = tonumber(world.bloody) or 0
	world.bloody = nil -- las estatuas de jefe se consumen en ESTE encuentro
	if extra > 0 then
		-- 2026-11-06: jefes ADICIONALES de las estatuas de jefe, a los costados del principal (marcados en rojo)
		local made = 0
		for i = 1, extra do
			local side = (i % 2 == 1) and 1 or -1
			local off = (e.radius * 2 + 8) * math.ceil(i / 2) * side
			local ax, az = MapService.resolve(world.map, e.x + off, e.z + 4, e.radius * 0.5)
			local x2 = BossDirector.spawn(world, h, { extra = true, at = { ax, az }, hpMul = OC.bossStatue.extraHpMul, rewardChests = OC.bossStatue.chestsPerExtra, rewardSilver = OC.bossStatue.silverPerExtra })
			if x2 then made += 1 end
		end
		sendAll(world, "Toast", { text = ("?? ¡Estatuas de jefe: %d jefes a la vez!"):format(made + 1) })
	end
end

-- ===== 2026-11-06: encuentros de jefe con el temporizador (MapObjectsConfig.encounters) =====
-- A los X segundos que faltan de la etapa sale el jefe del mapa (más débil) cerca del grupo, con los jefes
-- adicionales de las estatuas de jefe activadas hasta ese momento. Cada encuentro se marca ANTES de crearse, así
-- nunca se repite aunque el reloj salte o el tick se llame dos veces. Su muerte NO termina la etapa.
local function spawnEncounter(world, h, enc)
	local tgt = standing(world)[1] or h
	local ang = h.rng.combat:number(0, math.pi * 2)
	local d = enc.distance or 38
	local lim = world.map.half - 20
	local x = math.clamp(tgt.px + math.cos(ang) * d, -lim, lim)
	local z = math.clamp(tgt.pz + math.sin(ang) * d, -lim, lim)
	x, z = MapService.resolve(world.map, x, z, 3)
	local extra = tonumber(world.bloody) or 0
	world.bloody = nil
	local made = 0
	for i = 0, extra do
		local off = (i == 0) and 0 or (22 * math.ceil(i / 2) * ((i % 2 == 1) and 1 or -1))
		local ax, az = MapService.resolve(world.map, math.clamp(x + off, -lim, lim), z, 3)
		local e = BossDirector.spawn(world, h, { event = true, extra = i > 0, at = { ax, az }, hpMul = enc.hpMul * (i > 0 and OC.bossStatue.extraHpMul or 1), dmgMul = enc.dmgMul,
			rewardChests = (i == 0) and (enc.chests or 1) or OC.bossStatue.chestsPerExtra, rewardSilver = (i > 0) and OC.bossStatue.silverPerExtra or 0, encounter = enc.id })
		if e then made += 1 end
	end
	if made > 0 then
		local r = enc.remaining
		sendAll(world, "Toast", { text = ("? ¡Encuentro de jefe! (faltan %d:%02d) %s"):format(r // 60, r % 60, made > 1 and ("· %d jefes por las estatuas de jefe"):format(made) or "") })
		for _, m in ipairs(active(world)) do send(m, "Fx", { { "BS", "boom", x, z, 0.7 } }) end
	end
	return made
end
RunService.spawnEncounter = spawnEncounter

local function stepEncounters(h, dt)
	local world = h.world
	if world.ended or world.paused then return end
	world.encDone = world.encDone or {}
	local maxS = GameConfig.stage.maxSeconds
	for _, enc in ipairs(OC.encounters) do
		if not world.encDone[enc.id] and world.clock.stageT >= maxS - enc.remaining then
			world.encDone[enc.id] = true -- primero se marca: nunca se crea dos veces
			if not world.bossStarted and not world.superHorde and world.phase == "normal" then spawnEncounter(world, h, enc) end
		end
	end
end

-- objetivo más cercano en pie (para el jefe)
local function nearestTarget(world, x, z)
	local best, bd = nil, math.huge
	for _, m in ipairs(standing(world)) do
		local d = (m.px - x) ^ 2 + (m.pz - z) ^ 2
		if d < bd then best, bd = m, d end
	end
	return best
end

local function stepBoss(h, dt)
	local world = h.world
	if not BossDirector.anyAlive(world) then return end
	local t = world.clock.t
	world.bossClock += dt
	if world.bossClock >= GameConfig.stage.bossMaxSeconds then RunService.endWorld(world, "defeat", "boss_timeout"); return end
	-- movimiento, ataques con aviso, fase final y ambiente: Bosses/BossDirector (+ Bosses/BossAttacks)
	BossDirector.step(world, h, dt)
end

-- ===== Huevos de jefe (GameConfig.bossEggs + Catalogs/Pets.mapEggs) =====
-- Al vencer al jefe de la etapa 3, CADA miembro que sigue en la partida recibe SU huevo, directo en su perfil (nadie
-- puede agarrar el de otro: no hay objeto que recoger). Se guarda enseguida, así no se pierde aunque viaje al siguiente
-- nivel, termine la run o se desconecte. La animación de caída y entrega es solo visual (Fx "EGD" para todo el grupo).
local function awardBossEggs(world, b)
	local cfg = GameConfig.bossEggs
	if not (cfg and cfg.enabled) or (world.mapLevel or 1) ~= cfg.stage then return end -- 2026-11-11: huevo del jefe del NIVEL 3
	local def = PetsCat.mapEggByMap[world.mapId]
	if not def then return end
	world.eggKey = world.eggKey or HttpService:GenerateGUID(false)
	world.eggGiven = world.eggGiven or {}
	local list = active(world)
	local now = workspace:GetServerTimeNow()
	for i, m in ipairs(list) do
		local uidKey = tostring(m.player.UserId)
		if not world.eggGiven[uidKey] then
			world.eggGiven[uidKey] = true
			local source = world.eggKey .. "_s" .. world.stage .. "_" .. uidKey
			local ok, res = Profile.grantBossEgg(m.player, world.mapId, source, now)
			if ok then
				m.eggsWon = m.eggsWon or {}
				table.insert(m.eggsWon, res.uid)
				task.spawn(function() Profile.save(m.player) end) -- asegurado antes de viajar o salir
				local ang = (i - 1) / math.max(1, #list) * math.pi * 2
				local off = (#list > 1) and 4 or 0
				table.insert(world.fxQueue, { "EGD", b.x + math.cos(ang) * off, b.z + math.sin(ang) * off, def.id, m.player.UserId, m.player.DisplayName })
				send(m, "Toast", { text = ("?? ¡Conseguiste un %s! Ya se está incubando en Mascotas (listo en %s)."):format(def.name, def.incubate >= 3600 and ((def.incubate / 3600) .. " h") or ((def.incubate // 60) .. " min")) })
			else
				warn(("[Huevos] no se pudo entregar a %s: %s"):format(m.player.Name, tostring(res)))
				if res ~= "duplicate" then send(m, "Toast", { text = "No se pudo entregar tu huevo (" .. tostring(res) .. ")." }) end
			end
		end
	end
end
RunService.awardBossEggs = awardBossEggs

function RunService.bossDefeated(run)
	local world = run.world
	if world.ended then return end
	if world.clearedStage == world.stage then return end -- idempotente: un solo jefe por etapa
	world.clearedStage = world.stage
	BossDirector.cleanup(world) -- borra ataques, clones, efectos, aura y devuelve la iluminación normal
	if BossCinematic then pcall(BossCinematic.bossEnded, world) end -- corta la música del jefe
	world.stagesCompleted += 1
	local b = world.lastBossKilled or world.boss
	world.stageSilverBonus = world.curseActive and GameConfig.boss.curse.silver or 0
	-- (estatuas de jefe: cada jefe adicional ya soltó su cofre dorado al morir, ver Combat.kill)
	world.bloody = nil
	world.hiddenUnlock = false
	local final = world.stage >= world.stages
	if final then world.victory = true end
	local total, used = 0, 0
	for _, x in ipairs(world.map.items) do if x.kind == "shrine" then total += 1; if x.used then used += 1 end end end
	local allShrines = total > 0 and used >= total
	if allShrines then world.allShrinesCount += 1 end
	for _, m in ipairs(active(world)) do
		local M = m.m
		local function minRec(k, v) if v > 0 and (M.min[k] == 0 or v < M.min[k]) then M.min[k] = v end end
		minRec("bossFast", world.bossClock or 0)
		minRec("bossStageTime", world.clock.stageT)
		if not m.bossHit then M.max.bossNoHit = 1 end
		if (world.mapLevel or 1) >= 3 then m.boss3 = true end
		if world.curseActive then M.max.curseClears = 1 end
		if allShrines then
			M.max.allShrinesStage = 1
			if final and (world.startLevel or 1) == 1 and world.allShrinesCount >= 3 then M.max.allShrinesRun = 1 end
		end
	end
	world.state = "StageComplete"; world.prevState = "StageComplete"
	world.phase = "horde"
	-- 2026-11-11: sin súper horda ni portal tras el jefe. Se pasa SOLO al nivel siguiente (o se termina el mapa).
	-- los caídos vuelven al vencer al jefe
	for _, m in ipairs(active(world)) do if m.downed then revive(m, COOP.reviveHpPct) end end
	local okEgg, eggErr = pcall(awardBossEggs, world, b) -- huevo del jefe del nivel 3 (uno por jugador)
	if not okEgg then warn("[Huevos] " .. tostring(eggErr)) end
	-- el botín que quedó en el piso se junta solo antes de cambiar de nivel
	for _, m in ipairs(active(world)) do m.magnetUntil = world.clock.t + 10; for _, o in pairs(world.loot) do if (o.kind == "xp" or o.kind == "gold" or o.kind == "silver" or Combat.POWERUP_KINDS[o.kind]) and not o.pulledBy then o.pulled = true; o.pulledBy = m; o.magnetized = true end end end
	local ADV = 6
	world.advancing = true
	if final then
		sendAll(world, "Toast", { text = ("?? ¡Mapa completado! Volviendo al lobby en %d s…"):format(ADV) })
	else
		sendAll(world, "Toast", { text = ("¡Nivel %d superado! Pasando al nivel %d en %d s…"):format(world.mapLevel, world.mapLevel + 1, ADV) })
	end
	local stageAt = world.stage
	task.delay(ADV, function()
		if world.ended or world.stage ~= stageAt then return end
		world.advancing = false
		if final then
			RunService.endWorld(world, "victory", "map_complete")
		else
			local h = host(world)
			if h then RunService.nextStage(h) end
		end
	end)
end
local function recordHordeImpl(run)
	local sh = run.world and run.world.superHorde
	if sh then run.m.max.hordeTime = math.max(run.m.max.hordeTime, run.clock.t - sh.start) end
end
recordHorde = recordHordeImpl

-- ===== Muerte =====
-- Grupo eliminado (o jugador solo muerto): animación de muerte para todos y fin de la partida.
local function wipe(world, why)
	if world.wiping or world.ended then return end
	world.wiping = true
	for _, m in ipairs(active(world)) do
		m.dying = true
		pause(m, "death")
		send(m, "PlayerDied", { runId = m.id, victory = world.victory == true })
		pcall(CharacterSkin.shatter, m.player)
	end
	world.state = "Dying"
	task.delay(2.8, function()
		if not world.ended then RunService.endWorld(world, "defeat", why) end
	end)
end

function RunService.die(run, why)
	if run.over or run.dying or run.downed then return end
	local world = run.world
	local list = active(world)
	if #list > 1 then
		-- cooperativo: queda caído; si ya no queda nadie en pie, el grupo pierde
		setDowned(run)
		if #standing(world) == 0 then wipe(world, why) end
		return
	end
	wipe(world, why)
end

local function stepRevives(world, dt)
	local up = standing(world)
	for _, m in ipairs(active(world)) do
		if m.downed then
			local near = false
			for _, o in ipairs(up) do
				if (o.px - m.px) ^ 2 + (o.pz - m.pz) ^ 2 <= COOP.reviveRadius ^ 2 then near = true; break end
			end
			if near then
				m.reviveP = math.min(1, m.reviveP + dt / COOP.reviveTime)
			else
				m.reviveP = math.max(0, m.reviveP - dt / COOP.reviveTime * 0.5)
			end
			if m.downMarker then
				local bb = m.downMarker:FindFirstChildWhichIsA("BillboardGui")
				local tl = bb and bb:FindFirstChild("Text")
				if tl then tl.Text = ("¡%s CAYÓ! %d%%"):format(m.player.DisplayName, math.floor(m.reviveP * 100)) end
				m.downMarker.Color = Color3.fromRGB(255, 70, 90):Lerp(Color3.fromRGB(90, 255, 140), m.reviveP)
				local _, _, hrp = getChar(m)
				if hrp then m.downMarker.CFrame = CFrame.new(hrp.Position - Vector3.new(0, 2.6, 0)) * CFrame.Angles(0, 0, math.pi / 2) end
			end
			if m.reviveP >= 1 then
				revive(m, COOP.reviveHpPct)
				sendAll(world, "Toast", { text = ("¡%s volvió a la pelea!"):format(m.player.DisplayName) })
			end
		end
	end
end

-- ===== Deslizamiento =====
function RunService.slide(run)
	if run.paused or run.dying or run.over or run.downed then return end
	local t = run.clock.t
	if t < (run.slideReadyAt or 0) or (run.moveDelta or 0) < 0.04 then return end
	run.slideReadyAt = t + 1.4
	run.slideUntil = t + 0.6
	applyMovement(run)
	pcall(CharacterSkin.setSlide, run.player, true)
	Combat.fx(run, "b", run.px, 0.4, run.pz, 3, 235, 235, 235, 0.35)
end

function RunService.nextStage(run)
	local world = run.world
	if world.ended then return end
	for _, m in ipairs(active(world)) do recordHorde(m) end
	world.stage += 1
	world.mapLevel = math.min(3, (world.mapLevel or 1) + 1) -- 2026-11-11: cada fase es el nivel siguiente (nuevo mapa y nuevo jefe)
	world.state = "Generating"
	newStage(world)
	teleportToSpawn(world)
	world.state = "Playing"; world.prevState = "Playing"
end

-- ===== Final =====
local function destroyWorld(world)
	if world.destroyed then return end
	world.destroyed = true
	world.ended = true
	if BossCinematic then pcall(BossCinematic.cleanup, world) end
	pcall(BossDirector.cleanup, world)
	Combat.clearEnemies(world)
	local idx = table.find(worlds, world)
	if idx then table.remove(worlds, idx) end
	task.delay(0.5, function()
		if world.map then pcall(MapService.destroy, world.map) end
		if world.folder then world.folder:Destroy() end
		slots[world.slot] = nil
	end)
end

function RunService.abortPrepared(world)
	if not world or not world.prepared or world.ended then return end
	world.prepared = false
	for _, m in ipairs(world.members) do
		if runs[m.player.UserId] == m then runs[m.player.UserId] = nil end
		local _, hum, hrp = getChar(m)
		if hrp then hrp.Anchored = false; hrp.CFrame = lobbyCFrame() end
		if hum then hum.WalkSpeed = 16; hum.JumpHeight = 7.2 end
		pcall(CharacterSkin.remove, m.player)
		pcall(function() m.player:SetAttribute("PetId", nil); m.player:SetAttribute("PetIds", nil) end)
	end
	destroyWorld(world)
end

-- Liquida a UN miembro (premios, misiones, pantalla final) y lo saca de la partida.
function RunService.endRun(run, outcome, reason)
	if rawget(run, "over") then return end
	local world = run.world
	-- vencido el último jefe, morir o salir durante la súper horda conserva la victoria
	if world.victory and outcome ~= "victory" then
		outcome = "victory"
		reason = (reason == "hp" or reason == "fall") and "horde_death" or reason
	end
	rawset(run, "over", true) -- terminal ANTES de conceder nada
	if BossCinematic then pcall(BossCinematic.playerLeft, run) end -- corta la cámara/música de la cinemática para este jugador
	ReturnToLobby.begin(run.player, Profile, remotes)
	rawset(run, "state", (outcome == "victory" and "Victory") or (outcome == "abandoned" and "Abandoned") or "Defeat")
	removeDownMarker(run)
	Behaviors.clear(run)
	run.activeOffer = nil; run.offerQueue = {}
	clearPauses(run)
	local eco = GameConfig.economy
	local silver = math.floor(run.kills / eco.silverPerKills) + eco.silverPerStage * world.stagesCompleted
	if outcome == "victory" then silver += eco.silverWinBonus end
	local mult = run.stats:get("silverMultiplier") * eco.mapLevelSilverMultiplier[world.mapLevel] * (1 + (world.stageSilverBonus or 0))
	-- 2026-11-05 (estilo MegaBonk): aguantar la súper horda multiplica la plata: x(1 + minutos aguantados), máx. x8
	mult *= (world.hordeSilverMul or 1)
	if run.challenge then mult *= run.challenge.silver end -- modo de desafío
	local premium = Profile.get(run.player)
	if premium and (premium.data.moneyBoostUntil or 0) > os.time() then mult *= 2 end
	silver = math.floor(silver * mult)
	local weaponIds, tomeIds, itemIds = {}, {}, {}
	for _, w in ipairs(run.weapons) do table.insert(weaponIds, w.id) end
	for id in pairs(run.tomes) do table.insert(tomeIds, id) end
	for id in pairs(run.items) do table.insert(itemIds, id) end
	local dmgList = {}
	for id, v in pairs(run.dmgBy or {}) do dmgList[#dmgList + 1] = { id, math.floor(v) } end
	table.sort(dmgList, function(a, b) return a[2] > b[2] end)
	while #dmgList > 14 do table.remove(dmgList) end
	local inv = { weapons = {}, tomes = {}, items = {} }
	for _, w in ipairs(run.weapons) do inv.weapons[#inv.weapons + 1] = { w.id, w.level } end
	for id, tm in pairs(run.tomes) do inv.tomes[#inv.tomes + 1] = { id, tm.level } end
	for id, n in pairs(run.items) do inv.items[#inv.items + 1] = { id, n } end
	Leaderboard.submit(run.player, run.kills, run.classId) -- récord: kills de ESTE jugador en esta run + su personaje
	-- tabla EN GRUPO: cuando termina el último del grupo se guarda el total de kills de todo el grupo
	if (world.coopN or 1) >= 2 and not world.groupSubmitted then
		local allOver = true
		for _, m in ipairs(world.members or {}) do if not rawget(m, "over") then allOver = false end end
		if allOver then
			world.groupSubmitted = true
			local list = {}
			for _, m in ipairs(world.members) do
				local pl = m.player
				list[#list + 1] = { userId = pl and pl.UserId or 0, name = pl and (pl.DisplayName or pl.Name) or "?", kills = m.kills or 0, classId = m.classId }
			end
			local ok, err = pcall(Leaderboard.submitGroup, list)
			if not ok then warn("[Leaderboard] grupo: " .. tostring(err)) end
		end
	end
	recordHorde(run)
	local M = run.m
	M.add.kills = run.kills
	M.add.deaths = (outcome == "defeat") and 1 or 0
	M.max.critsRun = run.critsRun or 0
	M.max.potsRun = run.potsRun or 0
	M.max.statuesRun = world.statues or 0
	M.max.maxHp = math.floor(run.stats:get("maxHp"))
	M.max.tomeLv = {}
	for id, tm in pairs(run.tomes) do M.max.tomeLv[id] = tm.level end
	M.max.weaponLv = {}
	for _, w in ipairs(run.weapons) do M.max.weaponLv[w.id] = w.level end
	M.max.skates = ((M.max.tomeLv.tome_13 or 0) >= 5 and (M.max.tomeLv.tome_01 or 0) >= 5) and 1 or 0
	local ok, res = Profile.settle(run.player, {
		settlementId = run.id, silver = silver, kills = run.kills, classId = run.classId, stagesCompleted = world.stagesCompleted, startLevel = world.startLevel or world.mapLevel,
		mapId = world.mapId, mapLevel = world.mapLevel, outcome = outcome, time = world.clock.total, dev = run.dev,
		hiddenUnlock = world.hiddenUnlock, weapons = weaponIds, tomes = tomeIds, items = itemIds, m = run.m,
		bossStageTime = run.m.min.bossStageTime, boss3 = run.boss3 == true,
	})
	if remotes and run.player.Parent then
		remotes.RunEnded:FireClient(run.player, {
			runId = run.id, outcome = outcome, reason = reason, classSlot = run.classDef.slot, mapId = world.mapId, mapLevel = world.mapLevel, stages = world.stagesCompleted .. "/" .. world.stages,
			time = world.clock.total, level = run.level, kills = run.kills, dmgDone = math.floor(run.stats_damageDealt), dmgTaken = math.floor(run.stats_damageTaken),
			silverSummary = silver, silverPickups = run.silverEarned, gold = run.gold, rankXp = res and res.rankXp or 0, rank = res and res.rank or 0,
			weapons = weaponIds, tomes = tomeIds, saveState = "pending", hiddenUnlock = world.hiddenUnlock or false, log = run.log,
			missions = res and res.missions or {}, items = itemIds, dmgBy = dmgList, inv = inv, skin = run.skinId,
			coop = world.coopN > 1 and world.coopN or nil, eggs = run.eggsWon,
		})
	end
	task.spawn(function()
		Profile.save(run.player)
		local pd = Profile.publicData(run.player)
		if pd and remotes and run.player.Parent then remotes.ProfileData:FireClient(run.player, pd) end
	end)
	local _, _, hrp = getChar(run)
	if hrp then hrp.CFrame = lobbyCFrame() end
	pcall(CharacterSkin.remove, run.player)
	pcall(function() run.player:SetAttribute("PetId", nil); run.player:SetAttribute("PetIds", nil) end)
	local _, hum = getChar(run)
	if hum then hum.WalkSpeed = 16; hum.JumpHeight = 7.2 end
	task.delay(0.5, function()
		if runs[run.player.UserId] == run then runs[run.player.UserId] = nil end
	end)
	-- ¿queda alguien? si no, se destruye el mundo; si los que quedan están todos caídos, el grupo pierde
	local left = active(world)
	if #left == 0 then
		destroyWorld(world)
	elseif not world.ended and #standing(world) == 0 then
		wipe(world, "team_down")
	elseif not world.ended and world.coopN > 1 and outcome == "abandoned" then
		sendAll(world, "Toast", { text = ("%s salió de la partida."):format(run.player.DisplayName) })
	end
end

-- Termina la partida para todo el grupo
function RunService.endWorld(world, outcome, reason)
	if world.ended then return end
	world.ended = true
	for _, m in ipairs(active(world)) do RunService.endRun(m, outcome, reason) end
	destroyWorld(world)
end

function RunService.abandon(player)
	local run = runs[player.UserId]
	if run and not run.over then RunService.endRun(run, "abandoned", "player") end
end

function RunService.onPlayerRemoving(player)
	local run = runs[player.UserId]
	if run and run.world.prepared then
		RunService.abortPrepared(run.world)
		return
	end
	if run and not run.over then RunService.endRun(run, "abandoned", "disconnect") end
	runs[player.UserId] = nil
end

function RunService.isCoop(run)
	return run and run.world and #active(run.world) > 1
end

-- ===== Paso de simulación =====
local function sampleCharacter(run)
	local _, hum, hrp = getChar(run)
	if not hrp then return false end
	local pos = hrp.Position - run.origin
	local dx, dz = pos.X - run.px, pos.Z - run.pz
	local d = math.sqrt(dx * dx + dz * dz)
	if d < 30 then run.moveDelta = d else run.moveDelta = 0 end
	if hum.FloorMaterial ~= Enum.Material.Air then
		run.lastSafe = Vector3.new(pos.X, pos.Y + 3, pos.Z)
	else
		run.moveDelta = run.moveDelta * 0.5
	end
	run.px, run.pz = pos.X, pos.Z
	local look = hrp.CFrame.LookVector
	run.facing = Vector3.new(look.X, 0, look.Z).Unit
	run.airborne = hum.FloorMaterial == Enum.Material.Air
	if pos.Y < -25 and run.clock.t >= run.fallCd then
		run.fallCd = run.clock.t + GameConfig.combat.fallCooldown
		hrp.CFrame = CFrame.new(run.origin + run.lastSafe)
		if not run.downed then
			run.hp -= run.stats:get("maxHp") * GameConfig.combat.fallPenaltyPct
			if run.hp <= 0 then run.hp = 0; RunService.die(run, "fall") end
		end
	end
	return true
end

-- Aparición de enemigos: la decide SpawnDirector (créditos, límite de vivos, eventos y Final Swarm; Config/SpawnConfig).
-- Acá solo se le pasan las funciones reales del juego. El contexto se reutiliza por mundo (sin crear funciones cada tick).
local spawnCtx = setmetatable({}, { __mode = "k" })
local function getSpawnCtx(world)
	local ctx = spawnCtx[world]
	if ctx then return ctx end
	ctx = {}
	ctx.resolve = function(x, z) return MapService.resolve(world.map, x, z, 1.5) end
	ctx.inWater = function(x, z) return MapService.inWater(world.map, x, z) end
	ctx.spawn = function(kind, x, z, opts)
		-- si el modelo falla al construirse, el enemigo no se registra ni se cuenta
		local ok, e = pcall(Combat.spawnEnemy, ctx.host, kind, x, z, opts)
		if ok then return e end
		warn("[SpawnDirector] no se pudo crear " .. tostring(kind) .. ": " .. tostring(e))
		return nil
	end
	ctx.remove = function(e) Combat.removeEnemy(ctx.host, e) end
	ctx.toast = function(text) sendAll(world, "Toast", { text = text }) end
	ctx.endFinal = function(mode)
		if mode == "victory" then
			sendAll(world, "Toast", { text = "¡Sobreviviste al Final Swarm!" })
			task.defer(RunService.endWorld, world, "victory", "final_swarm")
		elseif mode == "calm" then
			world.superHorde = nil; world.hordeStart = nil
			sendAll(world, "Toast", { text = "El Final Swarm terminó. ¡Buscá el portal!" })
		end
	end
	spawnCtx[world] = ctx
	return ctx
end

-- ===== Clima de los mapas (GameConfig.hazards): tormenta de arena (Desierto) y meteoritos (Zona oculta) =====
local function stepHazards(h, dt)
	local world = h.world
	local HZ = GameConfig.hazards
	if not HZ or world.ended then return end
	local st, t = world.clock.stageT, world.clock.t
	if world.hazStage ~= world.stage then
		world.hazStage = world.stage
		world.stormNext = HZ.sandstorm.every; world.stormUntil = nil
		world.meteorAt = t + 6; world.meteors = {}
	end
	local bossFight = world.phase == "boss"
	-- plata de la súper horda: cada minuto que aguantás sube el multiplicador (x2, x3… hasta x8)
	if world.superHorde and world.superHorde.start then
		local mins = math.floor((t - world.superHorde.start) / 60)
		local mul = math.min(8, 1 + mins)
		if mul > (world.hordeSilverMul or 1) then
			world.hordeSilverMul = mul
			sendAll(world, "Toast", { text = ("?? ¡Aguantaste %d min de súper horda! Plata al final: x%d"):format(mins, mul) })
		end
	end
	if world.mapId == "desert" then
		if world.stormUntil then
			if st >= world.stormUntil or bossFight then
				world.stormUntil = nil
				Combat.fx(h, "WS", 0, 0)
				sendAll(world, "Toast", { text = "La tormenta de arena pasó." })
			end
		elseif not bossFight and st >= (world.stormNext or HZ.sandstorm.every) then
			world.stormUntil = st + HZ.sandstorm.duration
			repeat world.stormNext = (world.stormNext or 0) + HZ.sandstorm.every until world.stormNext > st
			Combat.fx(h, "WS", 1, HZ.sandstorm.duration)
			sendAll(world, "Toast", { text = "?? ¡TORMENTA DE ARENA! No ves el mapa y casi no ves nada alrededor." })
		end
	elseif world.mapId == "hidden" then
		local M = HZ.meteors
		world.meteors = world.meteors or {}
		local up = standing(world)
		if not bossFight and #up > 0 and t >= (world.meteorAt or 0) then
			world.meteorAt = t + M.every / #up -- más jugadores, más meteoritos (cada uno recibe ~1 cada `every` s)
			local target = up[h.rng.combat:integer(1, #up)]
			local a, d = h.rng.combat:number(0, math.pi * 2), h.rng.combat:number(0, M.spread)
			local lim = world.map.half - 4
			local x, z = math.clamp(target.px + math.cos(a) * d, -lim, lim), math.clamp(target.pz + math.sin(a) * d, -lim, lim)
			table.insert(world.meteors, { x = x, z = z, at = t + M.warn })
			Combat.fx(h, "MT", x, z, M.radius, M.warn)
		end
		for i = #world.meteors, 1, -1 do
			local m = world.meteors[i]
			if t >= m.at then
				table.remove(world.meteors, i)
				local dmg = math.min(M.maxDamage, M.damage + M.damagePerMinute * st / 60)
				for _, p in ipairs(up) do
					local dx, dz = p.px - m.x, p.pz - m.z
					if dx * dx + dz * dz <= (M.radius + 0.5) ^ 2 then Combat.damagePlayer(p, dmg, nil) end
				end
			end
		end
	end
end

local function stepDirector(h, dt)
	local world = h.world
	local sh = world.superHorde
	if world.phase ~= "normal" and world.phase ~= "horde" and not (sh and SpawnConfig.finalSwarm.spawnDuringBoss and world.phase == "boss") then return end
	if world.devNoSpawn then return end
	local up = standing(world)
	if #up == 0 then return end
	local serverAlive = 0
	for _, w in ipairs(worlds) do if not w.ended then serverAlive += SpawnDirector.aliveCount(w) end end
	local ctx = getSpawnCtx(world)
	ctx.host = h
	ctx.now, ctx.stageT, ctx.phase = world.clock.t, world.clock.stageT, world.phase
	ctx.standing, ctx.players = up, #active(world)
	ctx.rng = h.rng.combat
	ctx.difficulty = h.stats:get("difficulty")
	ctx.eliteMul = h.stats:get("eliteSpawnMultiplier")
	ctx.statues = world.statues or 0
	ctx.serverAlive = serverAlive
	ctx.half = world.map.half or 500
	SpawnDirector.step(world, dt, ctx)
end

local function stepInteractables(run, dt)
	local map = run.map
	local wrench = run.items.item_01 or 0
	local chargingItem = nil
	local appleCfg = GameConfig.economy.vaseApple
	for _, it in ipairs(map.items) do
		local dx, dz = run.px - it.x, run.pz - it.z
		local d = math.sqrt(dx * dx + dz * dz)
		if not it.discovered and d < 38 then it.discovered = true end
		if not run.downed and it.kind == "shrine" and not it.used and d <= GameConfig.shrine.chargeRadius then
			if not run.charging or run.charging == it then
				run.charging = it
				chargingItem = it
				it.progress += dt * (1 + 0.04 * wrench) / OC.shrine.chargeSeconds
				if it.progress >= 1 then
					it.used = true; it.progress = 1; run.charging = nil
					run.m.add.shrines += 1
					send(run, "Fx", { { "SH", it.id, it.x, it.z } }) -- sonido de finalización (corta el de carga)
					it.part.Color = Color3.fromRGB(90, 90, 90)
					if it.ring then it.ring.Color = Color3.fromRGB(90, 90, 90) end
					local light = it.part:FindFirstChildOfClass("PointLight"); if light then light.Enabled = false end
					onInteractionCompleted(run)
					Offers.queue(run, "shrine", it.golden and { golden = true, title = "Santuario dorado" } or nil)
				end
			end
		end
	end
	if run.charging and run.charging ~= chargingItem then run.charging = nil end
	-- 2026-11-05: santuarios de desafío: cuando mueren todos los marcados, sale un cofre dorado al lado del obelisco
	for _, it in ipairs(map.items) do
		if it.kind == "challenge" and it.active then
			local alive = 0
			for _, e in ipairs(it.mobs or {}) do if not e.dead and run.enemies[e.id] then alive += 1 end end
			if alive == 0 then
				it.active = false
				MapService.addDropChest(map, it.x + 4, it.z)
				Combat.fx(run, "b", it.x, 2, it.z, 10, 255, 220, 90, 0.6)
				sendAll(run.world, "Toast", { text = "?? ¡Desafío completado! Apareció un cofre dorado junto al obelisco." })
			end
		end
	end
	-- vasijas (teteras): se rompen cuando las alcanza un ataque (Behaviors marca las zonas golpeadas en run.vaseHits),
	-- ya no al acercarse. Suenan al romperse. Algunas traen una manzana que cura.
	local hits = rawget(run, "vaseHits")
	rawset(run, "vaseHits", nil)
	if run.downed or not hits or #hits == 0 then return end
	for _, v in ipairs(map.vases) do
		local broken = false
		if v.alive then
			local pdx, pdz = run.px - v.x, run.pz - v.z
			if pdx * pdx + pdz * pdz < 110 * 110 then -- los ataques salen alrededor del jugador
				for _, h in ipairs(hits) do
					local dx, dz = h[1] - v.x, h[2] - v.z
					local rr = h[3] + 1.2
					if dx * dx + dz * dz <= rr * rr then broken = true; break end
				end
			end
		end
		if broken then
			do
				v.alive = false; v.part:Destroy()
				Combat.fx(run, "VB", v.x, v.z) -- sonido de cerámica rota
				run.m.add.pots += 1; run.potsRun += 1
				-- 2026-11-06: recompensa según la variante (MapObjectsConfig.vase): normal, plateada o dorada
				local VV = OC.vase.variants[v.variant or (v.silver and "silver" or "normal")] or OC.vase.variants.normal
				if VV.xp and VV.xp > 0 then Combat.addLoot(run, "xp", v.x, v.z, VV.xp) end
				if VV.silver then Combat.addLoot(run, "silver", v.x + 0.8, v.z, VV.silver) end
				if VV.goldChance and run.rng.loot:chance(VV.goldChance) then Combat.addLoot(run, "gold", v.x - 0.8, v.z, run.rng.loot:integer(VV.gold[1], VV.gold[2])) end
				if VV.healChance and run.rng.loot:chance(VV.healChance) then Combat.addLoot(run, "heal", v.x, v.z + 0.8, 1) end
				if v.golden then Combat.fx(run, "b", v.x, 1.5, v.z, 4, 255, 210, 80, 0.4)
				elseif v.silver then Combat.fx(run, "b", v.x, 1.5, v.z, 3, 220, 230, 255, 0.3)
				else Combat.fx(run, "b", v.x, 1.5, v.z, 3, 190, 90, 60, 0.3) end
				if v.apple then
					Combat.addLoot(run, "apple", v.x + 1.2, v.z, appleCfg.heal)
					Combat.fx(run, "b", v.x, 1.5, v.z, 2.5, 255, 70, 70, 0.3)
				end
			end
		end
	end
end

local function stepVitals(run, dt)
	if run.downed then return end
	local st = run.stats
	local maxHp = st:get("maxHp")
	local cap = maxHp + st:get("overhealCap")
	if run.hp < cap then
		run.hp = math.min(cap, run.hp + st:get("hpRegenPerMinute") / 60 * dt)
	end
	if run.hp > maxHp then run.hp = math.max(maxHp, run.hp - GameConfig.combat.overhealDecayPerSecond * dt) end
	local smax = st:get("shieldMax")
	if run.shield > smax then run.shield = smax end
	if run.shield < smax and run.clock.t - run.lastDamageAt >= GameConfig.combat.shieldRegenDelay then
		run.shield = math.min(smax, run.shield + smax * GameConfig.combat.shieldRegenPctPerSecond * dt)
	end
end

local function applyMovementTick(run)
	-- 2026-11-05: bunny hop. Si saltás mientras te deslizás, en el aire conservás la velocidad del deslizamiento; si
	-- volvés a saltar apenas tocás el piso, la cadena sigue (máx. 4 s seguidos). Caminando normal no cambia nada.
	if run.slideUntil and run.clock.t < run.slideUntil + 0.1 then
		local _, hum = getChar(run)
		if hum and hum.FloorMaterial == Enum.Material.Air then
			run.hopChainStart = run.hopChainStart or run.clock.t
			if run.clock.t - run.hopChainStart < 4 then
				run.slideUntil = math.max(run.slideUntil, run.clock.t + 0.25)
			end
		elseif run.hopChainStart and hum and hum.FloorMaterial ~= Enum.Material.Air and run.clock.t >= run.slideUntil then
			run.hopChainStart = nil
		end
	end
	if run.tickN % 2 == 0 then applyMovement(run) end -- 2026-11-10: cada 0,1 s (antes 0,5 s: el impulso de saltos encadenados y el fin de los ralentizamientos se perdían)
end

local function worldStep(world, dt)
	world.tickN += 1
	world.clock.t += dt; world.clock.stageT += dt; world.clock.total += dt
	for _, m in ipairs(active(world)) do
		m.chainBudget = 8
		if not sampleCharacter(m) then
			RunService.endRun(m, "defeat", "character_lost") -- respawn inesperado / personaje destruido
		end
	end
	if world.ended then return end
	local list = active(world)
	if #list == 0 then return end
	local h = list[1]
	for _, m in ipairs(list) do
		local inW = MapService.inWater(world.map, m.px, m.pz)
		if inW ~= (m.inWater == true) then
			m.inWater = inW
			applyMovement(m)
			if inW and not m.waterHint then
				m.waterHint = true
				send(m, "Toast", { text = "Agua: te mueves más lento." })
			end
		end
	end
	Combat.rebuildGrid(h)
	for _, m in ipairs(list) do
		if not m.downed and not rawget(m, "over") then
			ClassEffects.step(m, dt, Combat)
			local bob = m.items.item_05 or 0
			if bob > 0 then
				m.bobAcc += m.moveDelta
				while m.bobAcc >= ItemsCat.bob.studs do
					m.bobAcc -= ItemsCat.bob.studs
					summon(m, ItemsCat.bob.ttl, ItemsCat.bob.damage * bob, "item_05")
				end
			end
			stepVitals(m, dt)
			ItemEffects.step(m, dt, Combat)
			Behaviors.step(m, dt, Combat)
			stepSummons(m, dt)
		end
	end
	Combat.stepEnemies(h, dt)
	if world.ended then return end
	for _, m in ipairs(active(world)) do
		Combat.stepLoot(m, dt)
		stepInteractables(m, dt)
	end
	if world.ended then return end
	stepRevives(world, dt)
	h = host(world)
	if not h then return end
	if world.phase == "boss" then stepBoss(h, dt) end
	if world.ended then return end
	stepEncounters(h, dt)
	BossDirector.stepEvents(world, h, dt) -- jefes de los encuentros del temporizador (en cualquier fase)
	if world.ended then return end
	stepDirector(h, dt)
	stepHazards(h, dt)
	if not world.superHorde and world.clock.stageT >= GameConfig.stage.maxSeconds then activateSuperHorde(world, "time") end
	for _, m in ipairs(active(world)) do
		if m.slideUntil and world.clock.t >= m.slideUntil then
			m.slideUntil = nil
			applyMovement(m)
			pcall(CharacterSkin.setSlide, m.player, false)
		end
		applyMovementTick(m)
	end
end

local REASON_TEXT = { offer = "eligiendo una mejora", menu = "en pausa", test = "en pausa" }

local function buildHud(run)
	local world = run.world
	local st = run.stats
	local ws, ts, its = {}, {}, {}
	for _, w in ipairs(run.weapons) do
		-- 2026-11-05: total de mejoras sorteadas del arma (estilo MegaBonk), para la pausa
		local ups = {}
		for _, e in ipairs(GameConfig.weaponUpgrades.list) do
			local v = w.up and w.up[e.key]
			if v and v > 0 then ups[#ups + 1] = { key = e.key, value = v, label = e.label, pct = e.pct, int = e.int } end
		end
		ws[#ws + 1] = { id = w.id, name = w.def.name, level = w.level, ups = #ups > 0 and Behaviors.describeUpgrade(ups) or nil }
	end
	for id, tm in pairs(run.tomes) do ts[#ts + 1] = { id = id, name = TomesCat.byId[id].name, level = tm.level } end
	for id, n in pairs(run.items) do its[#its + 1] = { id = id, name = ItemsCat.byId[id].name, n = n } end
	local pois = {}
	for _, it in ipairs(world.map.items) do
		if it.discovered then pois[#pois + 1] = { id = it.id, kind = it.kind, x = it.x, z = it.z, used = it.used, cost = (it.kind == "chest") and chestPrice(run, it) or it.cost, progress = it.progress, tier = it.tier, golden = it.golden, pp = it.pp or nil, category = it.category } end
	end
	-- 2026-11-04: mapa con íconos. Vasijas vistas (puntito blanco) y potenciadores tirados en el piso (con su ícono)
	local vases, pus = {}, {}
	for _, v in ipairs(world.map.vases or {}) do
		if v.alive then
			if not v.seen and (v.x - run.px) ^ 2 + (v.z - run.pz) ^ 2 < 38 * 38 then v.seen = true end
			if v.seen and #vases < 300 then vases[#vases + 1] = math.floor(v.x); vases[#vases + 1] = math.floor(v.z) end
		end
	end
	for _, l in pairs(world.loot) do
		if Combat.POWERUP_KINDS[l.kind] and #pus < 40 then pus[#pus + 1] = { math.floor(l.x), math.floor(l.z), l.kind } end
	end
	local dots = {}
	for _, e in pairs(world.enemies) do
		if #dots < 60 and (e.x - run.px) ^ 2 + (e.z - run.pz) ^ 2 < 90 * 90 then dots[#dots + 1] = { math.floor(e.x), math.floor(e.z), e.boss and 2 or (e.elite and 1 or 0) } end
	end
	local boss = BossDirector.hudInfo(world) -- vida máxima ya escalada + nombre, nivel usado y fase
	local abilityCd = 0
	if run.cls.abilityReadyAt then abilityCd = math.max(0, run.cls.abilityReadyAt - world.clock.t) end
	-- compañeros (cooperativo)
	local mates, waiting = nil, nil
	if #world.members > 1 then
		mates = {}
		for _, m in ipairs(world.members) do
			if m ~= run then
				mates[#mates + 1] = { name = m.player.DisplayName, hp = math.max(0, m.hp), maxHp = m.stats:get("maxHp"), x = math.floor(m.px), z = math.floor(m.pz),
					downed = m.downed or nil, revive = m.downed and m.reviveP or nil, left = rawget(m, "over") or nil, classId = m.classId, level = m.level }
			end
		end
		if world.paused then
			local mine = false
			local who = {}
			for _, v in pairs(world.pauseReasons) do
				if v.by == run then mine = true else who[#who + 1] = v.by.player.DisplayName .. " (" .. (REASON_TEXT[v.reason] or "en pausa") .. ")" end
			end
			if not mine and #who > 0 then waiting = table.concat(who, ", ") end
		end
	end
	return {
		ruId = run.id, hp = run.hp, maxHp = st:get("maxHp"), shield = run.shield, shieldMax = st:get("shieldMax"),
		level = run.level, xp = run.xp, xpNeed = Stats.xpForLevel(run.level), stageT = world.clock.stageT, total = world.clock.total,
		stageLimit = GameConfig.stage.maxSeconds, kills = run.kills, gold = run.gold, silver = run.silverEarned,
		weapons = ws, tomes = ts, items = its, phase = world.phase, state = world.state, boss = boss, pois = pois, dots = dots, vases = vases, pus = pus,
		portalHint = (not world.bossStarted and world.map.portal and world.clock.stageT >= 480 and world.phase == "normal") and { world.map.portal.x, world.map.portal.z } or nil,
		hordeSilverMul = world.hordeSilverMul,
		greedPct = (world.statues or 0) > 0 and math.floor((world.statues or 0) * OC.difficultyStatue.difficulty * 100 + 0.5) or nil,
		bossStatues = (tonumber(world.bloody) or 0) > 0 and tonumber(world.bloody) or nil,
		px = run.px, pz = run.pz, stage = world.stage, stages = world.stages, paused = world.paused or run.downed,
		charging = run.charging and { id = run.charging.id, p = run.charging.progress } or nil,
		abilityCd = abilityCd, hasAbility = run.classDef.passiveId == "defensive_pulse", passive = run.classDef.passiveId,
		rerolls = run.rerolls, skips = run.skips, banishes = run.banishes, half = world.map.half, weaponSlots = #run.weapons .. "/" .. (run.weaponSlots or GameConfig.progression.weaponSlots),
		tomeSlots = run.tomeCount .. "/" .. (run.tomeSlots or GameConfig.progression.tomeSlots),
		overtime = world.superHorde ~= nil and world.phase == "normal", superHorde = world.superHorde and world.superHorde.reason or nil,
		hordeT = world.superHorde and (world.clock.t - world.superHorde.start) or 0,
		slideCd = math.max(0, (run.slideReadyAt or 0) - world.clock.t),
		stats = (function() local s = {}; for _, k in ipairs(GameConfig.statOrder) do s[k] = st:get(k) end; return s end)(),
		log = run.log, mapName = MapsCat.byId[world.mapId].name,
		mates = mates, waiting = waiting, downed = run.downed or nil, reviveP = run.downed and run.reviveP or nil,
		coopN = world.coopN > 1 and world.coopN or nil,
		-- panel de depuración del spawn: solo en Studio o para SpawnConfig.debug.admins (al resto no se le manda)
		spawnDbg = SpawnDirector.canDebug(run.player, RunServiceRbx:IsStudio()) and SpawnDirector.debugInfo(world, GameConfig.stage.maxSeconds) or nil,
	}
end

local function flushFx(world)
	local q = world.fxQueue
	if #q == 0 then return end
	if #q > 150 then
		local cut = {}
		for i = 1, 150 do cut[i] = q[i] end
		q = cut
	end
	for _, m in ipairs(active(world)) do send(m, "Fx", q) end
	world.fxQueue = {}
end

-- ===== Bucle global a paso fijo (un único Heartbeat) =====
local accumulator = 0
local STEP = 1 / GameConfig.sim.tickHz
local started = false

function RunService.startLoop()
	if started then return end
	started = true
	game:GetService("RunService").Heartbeat:Connect(function(dt)
		accumulator = math.min(accumulator + dt, STEP * GameConfig.sim.maxCatchUpSteps)
		while accumulator >= STEP do
			accumulator -= STEP
			for _, world in ipairs(table.clone(worlds)) do
				if not world.ended then
					if not world.paused and (world.state == "Playing" or world.state == "BossEncounter" or world.state == "StageComplete") then
						local ok, err = pcall(worldStep, world, STEP)
						if not ok then warn("[World " .. tostring(world.slot) .. "] error de simulación: " .. tostring(err)) end
					end
					if not world.ended and world.state ~= "Generating" and world.map then -- mientras se genera el mapa no hay HUD que mandar
						flushFx(world)
						if world.paused then world.tickN += 1 end
						if world.tickN % 2 == 0 or world.paused then
							world.hudTick = (world.hudTick or 0) + 1
							if world.hudTick % (world.paused and 5 or 1) == 0 then
								for _, m in ipairs(active(world)) do
									local ok, d = pcall(buildHud, m)
									if ok then send(m, "HudDelta", d) else warn("[Hud] " .. tostring(d)) end
								end
							end
						end
					end
				end
			end
		end
	end)
end

-- ===== Peticiones (ya validadas en NetworkService) =====
function RunService.dedupe(run, requestId)
	if type(requestId) ~= "string" then return false end
	if run.handled[requestId] then return true end
	run.handled[requestId] = true
	table.insert(run.handledOrder, requestId)
	if #run.handledOrder > 64 then run.handled[table.remove(run.handledOrder, 1)] = nil end
	return false
end

return RunService
