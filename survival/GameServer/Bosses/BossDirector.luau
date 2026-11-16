--!nonstrict
-- Bosses/BossDirector: elige el jefe del mapa y nivel actual, calcula su dificultad (una sola vez, al aparecer),
-- lo mueve, decide sus ataques (Bosses/BossAttacks), maneja la fase final y el ambiente nocturno, y limpia todo.
-- Se engancha desde Services/RunService (startBoss, stepBoss, bossDefeated, newStage, destroyWorld).
-- El jefe sigue siendo un enemigo LÓGICO del juego (e.x, e.z, e.hp en world.enemies): las armas, la barra de vida,
-- el botín y la progresión funcionan igual que antes.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("GameShared")
local BossConfig = require(Shared.Config.BossConfig)
local DifficultyConfig = require(Shared.Config.DifficultyConfig) -- escalado del jefe por tiempo de la etapa (2026-11-04)
local Brainrots = require(Shared.Visuals.Brainrots)
local GameConfig = require(Shared.Config.GameConfig)
local Attacks = require(script.Parent.BossAttacks)
local Players = game:GetService("Players")

local BossDirector = {}
local deps -- { getChar, active, standing, send, sendAll, Combat, MapService }

function BossDirector.init(d) deps = d end
function BossDirector.addDep(k, v) deps[k] = v end

local function D() return BossConfig.Difficulty end
local function dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

-- ===== qué jefe toca (mapa + nivel elegido en el menú) =====
function BossDirector.resolve(mapId, mapLevel)
	local level = math.clamp(math.floor(mapLevel or 1), 1, 3)
	local name = BossConfig.bossName(mapId, level)
	if not name then return nil end
	local def = BossConfig.def(name)
	if not def then warn("[Bosses] falta la configuración de '" .. name .. "' en BossConfig.Defs"); return nil end
	return name, def, BossConfig.modelFor(name), level
end

-- ===== dificultad: se calcula UNA vez al aparecer y queda guardada en el jefe =====
function BossDirector.computeDifficulty(world, h, name, def, level)
	local cfg = D()
	local levels = {}
	for _, m in ipairs(deps.active(world)) do table.insert(levels, math.max(1, m.level or 1)) end -- nivel de la partida (servidor)
	if #levels == 0 then levels = { 1 } end
	local lvl
	if cfg.groupLevelMode == "average" then
		local sum = 0; for _, v in ipairs(levels) do sum += v end
		lvl = math.floor(sum / #levels + 0.5)
	else
		lvl = math.max(table.unpack(levels))
	end
	-- 2026-11-05: el jefe ya no escala con tu nivel de personaje: usa el nivel de referencia por tiempo de la etapa
	-- (los niveles reales quedan solo para mostrarlos). Mínimo 1.
	lvl = math.max(1, math.floor(DifficultyConfig.referenceLevel(world.clock and world.clock.stageT or 0) + 0.5))
	local lm = BossConfig.levelMultipliers(lvl)
	local mapKey = BossConfig.mapKey(world.mapId) or "Forest"
	local mapMul = cfg.mapMultiplier[mapKey] or 1
	local tierMul = cfg.tierMultiplier[level] or 1
	local stageMul = 1 + (cfg.stageHealthStep or 0) * ((world.stage or 1) - 1)
	local extraHp, extraDmg = 1, 1
	if cfg.useCoopMultiplier then extraHp *= (world.coopHpMul or 1); extraDmg *= (world.coopDmgMul or 1) end
	if cfg.useCurse and world.curseActive then extraHp *= 1 + GameConfig.boss.curse.hp; extraDmg *= 1 + GameConfig.boss.curse.damage end
	if cfg.useStatues then
		local diffStat = 0
		pcall(function() diffStat = math.clamp(h.stats:get("difficulty"), 0, 3) end)
		extraHp *= 1 + (cfg.statueHealthPerDifficulty or 1) * diffStat
		extraDmg *= (1 + (cfg.statueDamagePerDifficulty or 0.5) * diffStat) * (1 + (cfg.statueDamagePerStatue or 0.25) * (world.statues or 0))
	end
	-- tiempo de la etapa al abrir el portal (Config/DifficultyConfig): crece más rápido que en los enemigos, con tope propio
	local stageT = (world.clock and world.clock.stageT) or 0
	local timeHp, timeDmg = DifficultyConfig.bossTime(stageT)
	local health = def.baseHealth * mapMul * tierMul * lm.health * stageMul * extraHp * (cfg.globalHealthMul or 1) * timeHp
	local damage = def.baseDamage * lm.damage * extraDmg * (cfg.globalDamageMul or 1) * timeDmg
	return {
		bossName = name, playerLevel = lvl, levelMode = cfg.groupLevelMode, levels = levels,
		baseHealth = def.baseHealth, baseDamage = def.baseDamage,
		mapKey = mapKey, mapMultiplier = mapMul, tier = level, tierMultiplier = tierMul, stage = world.stage, stageMultiplier = stageMul,
		levelHealthMultiplier = lm.health, levelDamageMultiplier = lm.damage, extraHealth = extraHp, extraDamage = extraDmg,
		stageSeconds = stageT, timeHealthMultiplier = timeHp, timeDamageMultiplier = timeDmg,
		health = math.floor(health + 0.5), damage = damage, cooldownOf = lm.cooldown,
	}
end

-- ===== aparición =====
-- tamaño VISUAL del jefe (alto del modelo en studs). La cinemática de Patapim crece exactamente hasta este valor.
function BossDirector.visSizeOf(def) return (def and def.size or 14) * 2 end

-- punto donde aparece el jefe: delante del portal (mirando al inicio), fuera de obstáculos, del agua y del terreno
function BossDirector.spawnPoint(world, size, offset) -- offset opcional: distancia al portal (la cinemática usa la suya)
	local px, pz = world.map.portal.x, world.map.portal.z
	local SUM = GameConfig.bossSummon or { riseSeconds = 1.6, frontOffset = 9 }
	do
		local fx, fz = -px, -pz
		local fl = math.sqrt(fx * fx + fz * fz)
		if fl > 0.01 then fx, fz = fx / fl, fz / fl else fx, fz = 0, 1 end
		local half = world.map.half - 10
		local best
		for _, k in ipairs({ 1, 0.6, 1.4, 0 }) do
			local cx = math.clamp(px + fx * (offset or SUM.frontOffset) * k, -half, half)
			local cz = math.clamp(pz + fz * (offset or SUM.frontOffset) * k, -half, half)
			local rx, rz = deps.MapService.resolve(world.map, cx, cz, size * 0.4)
			if not deps.MapService.inWater(world.map, rx, rz) then best = { rx, rz }; break end
		end
		if best then px, pz = best[1], best[2] end
	end
	return px, pz
end

-- opts (opcional): at = {x, z} punto exacto; noSummon = true (sin subir del suelo: lo usa la cinemática); face = Vector3 (mirada inicial)
function BossDirector.spawn(world, h, opts)
	opts = opts or {}
	local name, def, modelId, level = BossDirector.resolve(world.mapId, world.mapLevel)
	if not name then warn("[Bosses] no hay jefe para " .. tostring(world.mapId) .. " nivel " .. tostring(world.mapLevel)); return nil end
	local diff = BossDirector.computeDifficulty(world, h, name, def, level)
	world.nextEnemyId += 1
	local size = def.size or 14
	local SUM = GameConfig.bossSummon or { riseSeconds = 1.6, frontOffset = 9 }
	local px, pz
	if opts.at then px, pz = opts.at[1], opts.at[2] else px, pz = BossDirector.spawnPoint(world, size) end
	-- 2026-11-06: opts.hpMul / opts.dmgMul (encuentros del temporizador y jefes adicionales)
	local hpM, dmM = opts.hpMul or 1, opts.dmgMul or 1
	local e = { id = world.nextEnemyId, kind = "boss", boss = true, elite = false, hp = diff.health * hpM, maxHp = diff.health * hpM, dmg = diff.damage * dmM,
		speed = def.speed or 6, xp = 0, x = px, z = pz, radius = size * 0.75, size = size,
		dead = false, atkCd = 0, windup = 0, status = {}, offset = 0,
		immuneUntil = world.clock.t + GameConfig.boss.startImmunity, undead = (world.mapDef_bossTag == "undead") }
	e.tag = world.mapDef_bossTag
	e.visSize = BossDirector.visSizeOf(def)
	e.bossName = name; e.def = def; e.modelId = modelId; e.diff = diff
	e.cds = {}; e.running = {}; e.gapUntil = world.clock.t + GameConfig.boss.startImmunity; e.lift = 0
	if not opts.noSummon then
		-- invocación: emerge del suelo junto al portal (inmune y sin atacar mientras sale)
		e.summonUntil = world.clock.t + SUM.riseSeconds
		e.immuneUntil = math.max(e.immuneUntil, e.summonUntil + 0.5)
		e.gapUntil = math.max(e.gapUntil, e.summonUntil + 0.5)
		e.lift = -e.visSize
		deps.Combat.fx(h, "z", px, 0.3, pz, size, 190, 110, 255, SUM.riseSeconds)
		deps.Combat.fx(h, "b", world.map.portal.x, 4, world.map.portal.z, 10, 190, 110, 255, 0.6)
		deps.Combat.fx(h, "BP", px, 1, pz, 190, 120, 255, 36, 3, 26)
		for _, m in ipairs(deps.active(world)) do deps.send(m, "Fx", { { "BS", "magic", px, pz, 0.6 }, { "BS", "boom", px, pz, 0.7 } }) end
	end
	local spawnPos = world.origin + Vector3.new(e.x, e.visSize / 2 + world.map.height(e.x, e.z), e.z)
	local spawnCf = (opts.face and opts.face.Magnitude > 0.01) and CFrame.lookAt(spawnPos, spawnPos + Vector3.new(opts.face.X, 0, opts.face.Z)) or CFrame.new(spawnPos)
	local model, root, tint, info = Brainrots.build(modelId, e.visSize, false, spawnCf, world.enemyFolder, { nameTag = true })
	e.part = root; e.model = model; e.tint = tint; e.anim = info.anim; e.animFreq = 4
	e.displayName = name
	-- el cartel del modelo muestra el nombre del jefe de BossConfig
	local bb = root:FindFirstChildOfClass("BillboardGui")
	if bb and bb:FindFirstChildOfClass("TextLabel") then bb:FindFirstChildOfClass("TextLabel").Text = name .. "  ·  Nv " .. diff.playerLevel end
	model:SetAttribute("BossName", name)
	model:SetAttribute("BossMaxHealth", diff.health)
	model:SetAttribute("BossPlayerLevel", diff.playerLevel)
	e.fxFolder = Instance.new("Folder"); e.fxFolder.Name = "BossFX"; e.fxFolder.Parent = world.map.folder
	e.arena = { x = px, z = pz, r = D().arenaRadius }
	world.enemies[e.id] = e; world.enemyCount += 1
	e.rewardChests = opts.rewardChests or 0; e.rewardSilver = opts.rewardSilver or 0; e.encounter = opts.encounter
	-- jefes ADICIONALES (estatuas de jefe): marca roja y cartel "JEFE ADICIONAL"
	if opts.extra then
		pcall(function()
			local hl = Instance.new("Highlight"); hl.Name = "ExtraBossMark"; hl.FillColor = Color3.fromRGB(220, 20, 40); hl.OutlineColor = Color3.fromRGB(255, 60, 60)
			hl.FillTransparency = 0.8; hl.OutlineTransparency = 0; hl.DepthMode = Enum.HighlightDepthMode.Occluded; hl.Parent = model
			if bb and bb:FindFirstChildOfClass("TextLabel") then bb:FindFirstChildOfClass("TextLabel").Text = "?? JEFE ADICIONAL · " .. name end
		end)
	end
	-- 2026-11-06: jefes de los ENCUENTROS del temporizador (no terminan la etapa): lista aparte
	if opts.event then
		e.event = true; e.extra = true -- (extra = sin ambiente nocturno propio)
		e.displayName = name
		world.eventBosses = world.eventBosses or {}
		table.insert(world.eventBosses, e)
		return e
	end
	-- 2026-11-06: varios jefes a la vez (estatuas de jefe). world.boss = el PRINCIPAL; world.bossList = todos.
	if opts.extra then
		e.extra = true
		world.bossList = world.bossList or { world.boss }
		table.insert(world.bossList, e)
		return e
	end
	world.boss = e
	world.bossList = { e }
	world.lastBossInfo = { name = name, health = diff.health, damage = diff.damage, playerLevel = diff.playerLevel,
		mapMultiplier = diff.mapMultiplier, tierMultiplier = diff.tierMultiplier, levelHealthMultiplier = diff.levelHealthMultiplier,
		levelDamageMultiplier = diff.levelDamageMultiplier, stageMultiplier = diff.stageMultiplier, extraHealth = diff.extraHealth, modelId = modelId,
		timeHealthMultiplier = diff.timeHealthMultiplier, timeDamageMultiplier = diff.timeDamageMultiplier, stageSeconds = diff.stageSeconds }
	return e
end

-- ===== contexto que reciben los ataques =====
local function makeContext(world, h, e)
	local A = { world = world, h = h, boss = e, rng = h.rng.combat, origin = world.origin, arena = e.arena }
	local cfg = D()
	function A.now() return world.clock.t end
	function A.phase2() return e.phase2 == true end
	function A.W(x, y, z) return world.origin + Vector3.new(x, (y or 0) + world.map.height(x, z), z) end
	function A.fx(...) deps.Combat.fx(h, ...) end
	function A.tint(k) Brainrots.tint(e, k) end
	function A.untint() Brainrots.untint(e) end
	function A.anim(k) Brainrots.attack(e.model, k) end
	function A.lock(v) e.lockMove = v end
	function A.lift(v) e.lift = v end
	function A.hide(v) e.hidden = v end
	function A.immune(secs) e.immuneUntil = math.max(e.immuneUntil or 0, world.clock.t + secs) end
	function A.part(s, shape, size, color, material, transp)
		local p = Instance.new("Part")
		p.Shape = shape; p.Size = size; p.Color = color; p.Material = material; p.Transparency = transp or 0
		p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
		p.CFrame = CFrame.new(world.origin + Vector3.new(0, -500, 0))
		p.Parent = e.fxFolder
		table.insert(s.parts, p)
		return p
	end
	function A.buildModel(modelId, size, pos)
		local ok, m = pcall(Brainrots.build, modelId, size, false, CFrame.new(pos), e.fxFolder, {})
		return ok and m or nil
	end
	-- jugadores en pie, con posición lógica y si están en el aire (saltando)
	function A.players()
		local list = {}
		for _, m in ipairs(deps.standing(world)) do
			local _, _, hrp = deps.getChar(m)
			local air, look = false, nil
			if hrp then
				air = (hrp.Position.Y - (world.origin.Y + world.map.height(m.px, m.pz))) > cfg.jumpClearance
				look = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
				if look.Magnitude > 0.01 then look = look.Unit else look = nil end
			end
			table.insert(list, { m = m, x = m.px, z = m.pz, air = air, look = look })
		end
		return list
	end
	function A.target()
		local best, bd = nil, math.huge
		for _, p in ipairs(A.players()) do
			local d = (p.x - e.x) ^ 2 + (p.z - e.z) ^ 2
			if d < bd then best, bd = p, d end
		end
		return best
	end
	-- punto dentro del mapa (y de la arena ampliada)
	function A.clampPoint(x, z)
		local half = world.map.half - 8
		return math.clamp(x, -half, half), math.clamp(z, -half, half)
	end
	-- punto válido para el jefe: dentro del mapa, fuera de obstáculos y no en el agua
	function A.validPoint(x, z)
		local cx, cz = A.clampPoint(x, z)
		local rx, rz = deps.MapService.resolve(world.map, cx, cz, e.radius * 0.5)
		local moved = dist(rx, rz, cx, cz)
		local wet = deps.MapService.inWater(world.map, rx, rz)
		return rx, rz, moved < 2 and dist(cx, cz, x, z) < 0.5 and not wet
	end
	-- daño: siempre en el servidor, como mucho una vez por jugador y por clave, y con tope por golpe
	function A.damage(m, mult, s, key)
		s.hits[key] = s.hits[key] or {}
		if s.hits[key][m] then return false end
		s.hits[key][m] = true
		local maxHp = 100
		pcall(function() maxHp = m.stats:get("maxHp") end)
		local phaseMul = (e.phase2 and e.def.phase and e.def.phase.damageMul) or 1
		local amount = math.min(e.dmg * (mult or 1) * phaseMul, maxHp * cfg.maxHitFraction)
		deps.Combat.damagePlayer(m, amount, e)
		return true
	end
	-- empuje (lo aplica el cliente dueño del personaje)
	function A.push(m, fromX, fromZ, power, up)
		local dx, dz = m.px - fromX, m.pz - fromZ
		local d = math.sqrt(dx * dx + dz * dz)
		if d < 0.01 then dx, dz, d = 1, 0, 1 end
		deps.send(m, "Fx", { { "BK", dx / d, dz / d, power or 40, up or 18 } })
	end
	function A.pullAll(cx, cz, radius, speed, duration)
		for _, m in ipairs(deps.active(world)) do deps.send(m, "Fx", { { "BG", cx, cz, radius, speed, duration } }) end
	end
	function A.pullStop()
		for _, m in ipairs(deps.active(world)) do deps.send(m, "Fx", { { "BG", 0, 0, 0, 0, 0 } }) end
	end
	function A.shake(cx, cz, radius) A.fx("b", cx, 0.3, cz, radius * 0.25, 255, 255, 255, 0.2) end
	-- proyectil esquivable del sistema de enemigos (mismo daño que valida el servidor)
	-- empuje en una dirección dada (golpe de tronco: knockback lateral)
	function A.pushDir(m, dx, dz, power, up)
		deps.send(m, "Fx", { { "BK", dx, dz, power or 40, up or 18 } })
	end
	-- ralentización temporal (la aplica el servidor en la velocidad del Humanoid; nunca deja al jugador quieto)
	function A.slow(m, mul, secs)
		local t = world.clock.t
		mul = math.max(cfg.minSlow or 0.35, mul or 0.6)
		if (m.bossSlowUntil or 0) <= t or mul < (m.bossSlowMul or 1) then m.bossSlowMul = mul end
		m.bossSlowUntil = math.max(m.bossSlowUntil or 0, t + (secs or 1))
		if deps.applyMovement then deps.applyMovement(m) end
	end
	-- sonido y partículas (los reproduce el cliente; solo presentación)
	function A.sound(key, x, z, pitch)
		if not key then return end
		for _, m in ipairs(deps.active(world)) do deps.send(m, "Fx", { { "BS", key, x, z, pitch or 1 } }) end
	end
	function A.particles(x, z, y, rgb, count, size, speed)
		A.fx("BP", x, y or 1, z, rgb[1], rgb[2], rgb[3], count or 12, size or 2, speed or 14)
	end
	-- paredes: distancia libre desde (x,z) en una dirección (el terreno y los personajes no cuentan como pared)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	function A.rayLen(x, z, ux, uz, maxLen)
		local d = Vector3.new(ux, 0, uz)
		if d.Magnitude < 1e-3 then return maxLen end
		local excl = { workspace.Terrain }
		if e.fxFolder then table.insert(excl, e.fxFolder) end
		if world.enemyFolder then table.insert(excl, world.enemyFolder) end
		for _, pl in ipairs(Players:GetPlayers()) do if pl.Character then table.insert(excl, pl.Character) end end
		rp.FilterDescendantsInstances = excl
		local hit = workspace:Raycast(A.W(x, 3, z), d.Unit * maxLen, rp)
		if hit and hit.Instance.CanCollide then return math.max(0, (Vector3.new(hit.Position.X, 0, hit.Position.Z) - Vector3.new(world.origin.X + x, 0, world.origin.Z + z)).Magnitude - 0.5) end
		return maxLen
	end
	function A.blocked(x1, z1, x2, z2)
		local L = dist(x1, z1, x2, z2)
		if L < 1 then return false end
		return A.rayLen(x1, z1, (x2 - x1) / L, (z2 - z1) / L, L) < L - 1
	end
	-- hacia dónde mira el jefe durante un ataque (nil = mira al jugador)
	function A.face(dx, dz) if dx then e.faceDir = Vector3.new(dx, 0, dz) else e.faceDir = nil end end
	function A.shot(x, z, dx, dz, mult)
		deps.Combat.enemyShot(h, { x = x, z = z, dmg = math.min(e.dmg * (mult or 1), 100 * cfg.maxHitFraction) }, dx, dz)
	end
	return A
end

local function attackEntry(def, id)
	for _, a in ipairs(def.attacks) do if a.id == id then return a end end
end

local function startAttack(world, h, e, entry)
	local impl = Attacks[entry.id]
	if not impl then warn("[Bosses] ataque desconocido: " .. tostring(entry.id)); return end
	local P = table.clone(impl.defaults or {})
	for k, v in pairs(entry) do if k ~= "id" and k ~= "cooldown" and k ~= "weight" and k ~= "phaseCooldownMul" then P[k] = v end end
	local s = { id = entry.id, P = P, t = 0, parts = {}, hits = {} }
	e.ctx = e.ctx or makeContext(world, h, e)
	local ok, err = pcall(impl.start, e.ctx, s)
	if not ok then warn("[Bosses] " .. entry.id .. ".start: " .. tostring(err)) end
	table.insert(e.running, s)
	-- cooldown escalado por nivel (con piso) y más corto en la fase final
	local base = entry.cooldown or 5
	local cd = e.diff.cooldownOf(base)
	if e.phase2 then cd *= (entry.phaseCooldownMul or (e.def.phase and e.def.phase.cooldownMul) or 1) end
	e.cds[entry.id] = world.clock.t + cd
end

local function endAttack(e, s)
	local impl = Attacks[s.id]
	if impl and impl.cleanup and e.ctx then pcall(impl.cleanup, e.ctx, s) end
	for _, p in ipairs(s.parts) do if p and p.Parent then p:Destroy() end end
	s.parts = {}
	s.projs = nil
end

-- ===== fase final =====
local function enterPhase2(world, e)
	e.phase2 = true
	local ph = e.def.phase or {}
	local col = ph.aura or Color3.fromRGB(255, 80, 80)
	local hl = Instance.new("Highlight")
	hl.Name = "BossAura"; hl.FillColor = col; hl.OutlineColor = col; hl.FillTransparency = 0.65; hl.OutlineTransparency = 0.1
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.Parent = e.model
	local l = Instance.new("PointLight"); l.Name = "BossAuraLight"; l.Color = col; l.Range = 22; l.Brightness = 2.5; l.Parent = e.part
	deps.sendAll(world, "Toast", { text = "¡" .. e.bossName .. " entra en su FASE FINAL!" })
end

-- ===== ambiente nocturno por jugador (solo el grupo de esta partida y solo cerca de la arena) =====
local function updateAmbience(world, e)
	local amb = e.def.ambience
	if not amb or e.extra then return end
	e.ambOn = e.ambOn or {}
	local maxD = e.arena.r * (amb.leaveDistanceMul or 2.5)
	for _, m in ipairs(deps.active(world)) do
		local inside = dist(m.px, m.pz, e.arena.x, e.arena.z) <= maxD and not e.dead
		if inside and not e.ambOn[m] then
			e.ambOn[m] = true
			deps.send(m, "Fx", { { "BN", true, amb } })
		elseif not inside and e.ambOn[m] then
			e.ambOn[m] = nil
			deps.send(m, "Fx", { { "BN", false } })
		end
	end
end

-- ===== paso por tick =====
local function stepOne(world, h, dt, e)
	if not e or e.dead or not e.def then return end
	local t = world.clock.t
	e.ctx = e.ctx or makeContext(world, h, e)
	local A = e.ctx
	local cfg = D()
	-- invocación: sube desde el suelo junto al portal (todavía no ataca ni se mueve)
	if e.summonUntil then
		local rise = (GameConfig.bossSummon and GameConfig.bossSummon.riseSeconds) or 1.6
		local left = e.summonUntil - t
		if left > 0 then
			local k = math.clamp(1 - left / rise, 0, 1)
			e.lift = -e.visSize * (1 - k * k * (3 - 2 * k))
			local pos = world.origin + Vector3.new(e.x, e.visSize / 2 + world.map.height(e.x, e.z) + e.lift, e.z)
			e.part.CFrame = CFrame.new(pos) * CFrame.Angles(0, t * 4, 0)
			if (world.tickN or 0) % 6 == 0 then deps.Combat.fx(h, "BP", e.x, 0.5, e.z, 170, 130, 90, 10, 2.5, 14) end
			return
		end
		e.summonUntil = nil; e.lift = 0
		deps.Combat.fx(h, "b", e.x, 0.5, e.z, e.radius + 4, 190, 110, 255, 0.5)
		updateAmbience(world, e)
	end
	-- fase final
	if not e.phase2 and e.def.phase and e.hp <= e.maxHp * (e.def.phase.at or 0.5) then enterPhase2(world, e) end
	updateAmbience(world, e)
	local tgt = A.target()
	-- ataques en curso (como máximo 2 a la vez)
	local controls = false
	for i = #e.running, 1, -1 do
		local s = e.running[i]
		s.t += dt
		local impl = Attacks[s.id]
		local ok, done = pcall(impl.update, A, s, dt)
		if not ok then warn("[Bosses] " .. s.id .. ".update: " .. tostring(done)); done = true end
		if s.controlsMove then controls = true end
		if done then
			endAttack(e, s)
			table.remove(e.running, i)
			if #e.running == 0 then
				e.gapUntil = t + cfg.globalGap
				e.faceDir = nil; e.lockMove = false; e.lift = 0; e.hidden = false; Brainrots.untint(e)
			end
		end
	end
	-- elegir el próximo ataque
	if tgt and #e.running == 0 and t >= e.gapUntil and t >= (e.immuneUntil or 0) then
		local d = dist(tgt.x, tgt.z, e.x, e.z)
		local melee = attackEntry(e.def, "chaseHit")
		local pool, total = {}, 0
		for _, a in ipairs(e.def.attacks) do
			if (a.weight or 0) > 0 and t >= (e.cds[a.id] or 0) then table.insert(pool, a); total += a.weight end
		end
		if #pool > 0 and d < e.arena.r * 1.6 then
			local r = A.rng:number(0, total)
			local pick = pool[#pool]
			for _, a in ipairs(pool) do r -= a.weight; if r <= 0 then pick = a; break end end
			startAttack(world, h, e, pick)
		end
		-- (sin golpe cuerpo a cuerpo: 2026-11-01)
	elseif e.phase2 and #e.running == 1 and e.def.phase and e.def.phase.combo then
		-- fase final de la Vaca: puede sumar un segundo ataque (meteoritos o lunas) mientras corre otro
		local cur = e.running[1].id
		for _, id in ipairs(e.def.phase.combo) do
			local entry = attackEntry(e.def, id)
			if entry and id ~= cur and t >= (e.cds[id] or 0) and not (Attacks[cur] and Attacks[cur].combo) then
				startAttack(world, h, e, entry)
				break
			end
		end
	end
	-- daño por cercanía: solo si un jugador se pega a su cuerpo (no es un golpe; no tiene alcance extra)
	if not e.hidden and (e.lift or 0) > -1 then
		e.touchAt = e.touchAt or {}
		local reachT = e.radius + (cfg.touchPadding or 1.5)
		for _, p in ipairs(A.players()) do
			if dist(p.x, p.z, e.x, e.z) <= reachT and t >= (e.touchAt[p.m] or 0) then
				e.touchAt[p.m] = t + (cfg.touchInterval or 1)
				deps.Combat.damagePlayer(p.m, e.dmg * (cfg.touchDamageMul or 0.5), e)
			end
		end
	end
	-- movimiento: persigue al jugador más cercano salvo que un ataque lo frene o lo controle
	local dx, dz = 0, 0
	if tgt then dx, dz = tgt.x - e.x, tgt.z - e.z end
	local d = math.max(0.01, math.sqrt(dx * dx + dz * dz))
	if tgt and not controls and not e.lockMove and not e.hidden and d > e.radius + 3 then
		e.x += dx / d * e.speed * dt; e.z += dz / d * e.speed * dt
	end
	-- varios jefes (Pilar sangriento): no se apilan uno encima del otro
	local others = world.bossList
	if world.eventBosses and #world.eventBosses > 0 then
		others = table.clone(world.bossList or {})
		for _, o in ipairs(world.eventBosses) do table.insert(others, o) end
	end
	if others and #others > 1 then
		for _, o in ipairs(others) do
			if o ~= e and not o.dead then
				local sx, sz = e.x - o.x, e.z - o.z
				local sd = math.sqrt(sx * sx + sz * sz)
				local minD = (e.radius + o.radius) * 0.85
				if sd < minD then
					if sd < 0.01 then sx, sz, sd = 1, 0, 1 end
					local push = math.min(minD - sd, 12 * dt + (minD - sd) * 0.2)
					e.x += sx / sd * push; e.z += sz / sd * push
				end
			end
		end
	end
	e.x, e.z = deps.MapService.resolve(world.map, e.x, e.z, 0)
	e.x = math.clamp(e.x, -world.map.half, world.map.half); e.z = math.clamp(e.z, -world.map.half, world.map.half)
	local flash = e.flash and e.flash > t
	if flash then Brainrots.tint(e, "w") end
	local pos = world.origin + Vector3.new(e.x, e.visSize / 2 + world.map.height(e.x, e.z) + (e.lift or 0), e.z)
	if e.hidden then pos -= Vector3.new(0, 400, 0) end
	local look = e.faceDir or Vector3.new(dx, 0, dz)
	e.part.CFrame = Brainrots.pose(e, t, pos, look, not e.lockMove)
end

-- todos los jefes vivos de la etapa (principal + extras del Santuario sangriento)
function BossDirector.list(world)
	return world.bossList or (world.boss and { world.boss }) or {}
end
function BossDirector.anyAlive(world)
	for _, b in ipairs(BossDirector.list(world)) do if not b.dead then return true end end
	return false
end

function BossDirector.step(world, h, dt)
	for _, e in ipairs(BossDirector.list(world)) do
		if not e.dead then stepOne(world, h, dt, e) end
	end
end

-- jefes de los encuentros del temporizador: se mueven y atacan en cualquier fase (los muertos se sacan de la lista)
function BossDirector.stepEvents(world, h, dt)
	local evs = world.eventBosses
	if not evs or #evs == 0 then return end
	for i = #evs, 1, -1 do
		local e = evs[i]
		if e.dead then table.remove(evs, i) else stepOne(world, h, dt, e) end
	end
end

-- ===== limpieza (muerte del jefe, fin de etapa, fin de partida) =====
local function cleanupOne(world, e)
	if not e or e.cleaned then return end
	e.cleaned = true
	for _, s in ipairs(e.running or {}) do endAttack(e, s) end
	e.running = {}
	if e.ambOn then
		for m in pairs(e.ambOn) do pcall(deps.send, m, "Fx", { { "BN", false } }) end
		e.ambOn = nil
	end
	if e.fxFolder then e.fxFolder:Destroy(); e.fxFolder = nil end
	if e.model then
		local a = e.model:FindFirstChild("BossAura"); if a then a:Destroy() end
	end
	if e.part then local l = e.part:FindFirstChild("BossAuraLight"); if l then l:Destroy() end end
	e.hidden = false; e.lockMove = false; e.lift = 0; e.faceDir = nil
	for _, m in ipairs(deps.active(world)) do
		if m.bossSlowUntil then m.bossSlowUntil = nil; m.bossSlowMul = nil; if deps.applyMovement then pcall(deps.applyMovement, m) end end
		pcall(deps.send, m, "Fx", { { "BG", 0, 0, 0, 0, 0 } })
	end
	e.ctx = nil; e.cds = nil; e.diff = nil
end
BossDirector.cleanupOne = cleanupOne
function BossDirector.cleanup(world)
	for _, e in ipairs(BossDirector.list(world)) do cleanupOne(world, e) end
	for _, e in ipairs(world.eventBosses or {}) do cleanupOne(world, e) end
end

-- (pruebas) fuerza un ataque concreto del jefe actual
function BossDirector.forceAttack(world, h, id)
	local e = world.boss
	if not e or e.dead or not e.def then return false, "sin jefe" end
	local entry = attackEntry(e.def, id) or { id = id }
	if not Attacks[id] then return false, "ataque desconocido" end
	for _, s in ipairs(e.running) do endAttack(e, s) end
	e.running = {}
	e.immuneUntil = 0
	startAttack(world, h, e, entry)
	return true
end

function BossDirector.debugInfo(world)
	local e = world.boss
	local running = {}
	if e and e.running then for _, s in ipairs(e.running) do running[#running + 1] = s.id end end
	local amb = 0
	if e and e.ambOn then for _ in pairs(e.ambOn) do amb += 1 end end
	return { info = world.lastBossInfo, alive = e and not e.dead or false, hp = e and e.hp, maxHp = e and e.maxHp, phase2 = e and e.phase2 or false,
		running = running, nightPlayers = amb, fxObjects = e and e.fxFolder and #e.fxFolder:GetChildren() or 0, x = e and e.x, z = e and e.z }
end

-- datos para el HUD y las pruebas
function BossDirector.hudInfo(world)
	local hp, max, n, main = 0, 0, 0, nil
	for _, b in ipairs(BossDirector.list(world)) do
		max += b.maxHp -- la barra baja de a poco aunque caiga uno
		if not b.dead then hp += math.max(0, b.hp); n += 1; main = main or b end
	end
	if n == 0 then
		-- encuentro del temporizador
		local evs = world.eventBosses or {}
		for _, b in ipairs(evs) do if not b.dead then hp += math.max(0, b.hp); max += b.maxHp; n += 1; main = main or b end end
		if n == 0 then return nil end
		return { hp = hp, max = max, name = ("? %s%s"):format(main.bossName, n > 1 and ("  (%d jefes)"):format(n) or ""), lvl = world.lastBossInfo and world.lastBossInfo.playerLevel, phase = main.phase2 and 2 or 1, count = n }
	end
	local name = main.bossName
	if #BossDirector.list(world) > 1 then name = ("%s  (%d de %d jefes)"):format(name, n, #BossDirector.list(world)) end
	return { hp = hp, max = max, name = name, lvl = world.lastBossInfo and world.lastBossInfo.playerLevel, phase = main.phase2 and 2 or 1, count = n }
end

return BossDirector
