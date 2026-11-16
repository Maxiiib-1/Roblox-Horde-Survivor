--!nonstrict
-- Services/CombatService: enemigos lógicos, índice espacial, canal único de daño, botín y muerte.
-- El servidor decide posiciones, daño y recompensas. Visuales: partes simples + eventos Fx compactos.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("GameShared")
local GameConfig = require(Shared.Config.GameConfig)
local SpawnConfig = require(Shared.Config.SpawnConfig) -- aparición de enemigos (SpawnDirector): tope de crecimiento y detalle
local DifficultyConfig = require(Shared.Config.DifficultyConfig) -- escalado por tiempo de la etapa y sus topes (2026-11-04)
local BossConfig = require(Shared.Config.BossConfig) -- tope de daño por golpe del jefe
local Stats = require(Shared.Util.Stats)
local MapService = require(script.Parent.MapService)
local ClassEffects = require(script.Parent.Parent.Classes.ClassEffects)
local Behaviors = require(script.Parent.Parent.Weapons.Behaviors)
local Brainrots = require(Shared.Visuals.Brainrots)
local ItemEffects = require(script.Parent.Parent.Items.ItemEffects)

local Combat = {}
local KILL_TAGS = { "fire", "lightning", "poison", "melee" }

local CELL = 12
-- Tamaño de enemigos: la hitbox crece un 25% y el modelo se dibuja un 30% más grande que la hitbox
local SIZE_MUL, VIS_MUL = 1.25, 1.3
local D = GameConfig.director
local C = GameConfig.combat

-- ===== Fx (batcheado por tick, un solo RemoteEvent) =====
function Combat.fx(run, ...)
	table.insert(run.fxQueue, { ownerUserId = run.player and run.player.UserId or 0, args = { ... } })
end

-- ===== Índice espacial =====
function Combat.rebuildGrid(run)
	local grid = {}
	for _, e in pairs(run.enemies) do
		local key = math.floor(e.x / CELL) * 4096 + math.floor(e.z / CELL)
		local b = grid[key]
		if not b then b = {}; grid[key] = b end
		b[#b + 1] = e
	end
	run.grid = grid
end

function Combat.inRadius(run, x, z, r, filter)
	local out = {}
	local c0x, c1x = math.floor((x - r) / CELL), math.floor((x + r) / CELL)
	local c0z, c1z = math.floor((z - r) / CELL), math.floor((z + r) / CELL)
	local r2 = r * r
	for cx = c0x, c1x do
		for cz = c0z, c1z do
			local b = run.grid[cx * 4096 + cz]
			if b then
				for _, e in ipairs(b) do
					if not e.dead then
						local dx, dz = e.x - x, e.z - z
						local rr = r + e.radius
						if dx * dx + dz * dz <= rr * rr and (not filter or filter(e)) then
							out[#out + 1] = e
						end
					end
				end
			end
		end
	end
	return out
end

function Combat.nearest(run, x, z, r, exclude)
	local best, bd = nil, math.huge
	for _, e in ipairs(Combat.inRadius(run, x, z, r)) do
		if not (exclude and exclude[e.id]) then
			local dx, dz = e.x - x, e.z - z
			local d = dx * dx + dz * dz
			if d < bd then best, bd = e, d end
		end
	end
	return best
end

-- ===== Enemigos =====
local function archetypeScale(run, kind)
	local a = D.archetypes[kind]
	local DC = DifficultyConfig
	-- tiempo de la ETAPA (Config/DifficultyConfig): 1 + minutos × crecimiento, con tope propio (antes: freno en el minuto 20)
	local tHp, tDmg, tSpd = DC.enemyTime(run.clock.stageT)
	local stageBonusHp = D.hpPerStage * (run.stage - 1)
	local stageBonusDmg = D.damagePerStage * (run.stage - 1)
	local diff = math.clamp(run.stats:get("difficulty"), 0, DC.MAX_DIFFICULTY or 3)
	local hpMul = (tHp + stageBonusHp) * (1 + D.difficulty.hp * diff)
	local dmgMul = (tDmg + stageBonusDmg) * (1 + D.difficulty.damage * diff) -- 2026-11-05: los pilares ya no suman daño aparte; suben el stat "difficulty" (+5% c/u)
	-- 2026-11-05: ya NO depende de tu nivel de personaje: usa el nivel de referencia por TIEMPO (DifficultyConfig)
	local L, lv = D.levelScale, DC.referenceLevel(run.clock.stageT)
	if L then
		hpMul *= L.hpStart + L.hpPerLevel * lv
		dmgMul *= L.dmgStart + L.dmgPerLevel * lv
	end
	local spdMul = tSpd * (1 + D.difficulty.speed * diff)
	-- súper horda: cada minuto que dura, los nuevos enemigos salen más rápidos
	local w = rawget(run, "world") or run.world
	local sh = w and w.superHorde
	if sh and sh.start and w.clock then
		spdMul *= 1 + math.min(DC.HORDE_MAX_SPEED_BONUS, DC.HORDE_SPEED_PER_MINUTE * math.max(0, (w.clock.t - sh.start) / 60))
	end
	-- topes ABSOLUTOS (antes del cooperativo, élite y minijefe: se conservan esas diferencias)
	hpMul, dmgMul, spdMul = DC.clampEnemyTotals(hpMul, dmgMul, spdMul)
	-- cooperativo: cada amigo extra en el grupo sube la vida y el daño de los enemigos
	hpMul *= (run.coopHpMul or 1)
	dmgMul *= (run.coopDmgMul or 1)
	return a, hpMul, dmgMul, spdMul
end
Combat.archetypeScale = archetypeScale -- (lo usan las pruebas de Tests/TestRunner)

function Combat.spawnEnemy(run, kind, x, z, opts)
	opts = opts or {}
	local a, hpMul, dmgMul, spdMul = archetypeScale(run, kind)
	local elite = opts.elite == true
	local E = D.elite
	run.nextEnemyId += 1
	-- opts.sizeMul / hpMul / xpMul / miniboss: minijefes de los eventos programados (SpawnDirector)
	local size = a.size * SIZE_MUL * (elite and E.sizeMul or 1) * (opts.sizeMul or 1)
	local visSize = size * VIS_MUL
	local e = {
		id = run.nextEnemyId, kind = kind, elite = elite,
		hp = a.hp * hpMul * (elite and E.hpMul or 1) * (opts.hpMul or 1), dmg = a.damage * dmgMul * (elite and E.damageMul or 1) * (opts.dmgMul or 1), -- opts.dmgMul: Final Swarm / minijefe
		speed = a.speed * spdMul, xp = a.xp * (elite and E.xpMul or 1) * (opts.xpMul or 1), miniboss = opts.miniboss == true or nil,
		x = x, z = z, radius = size / 2, size = size, visSize = visSize, dead = false,
		atkCd = 0, windup = 0, status = {}, offset = run.rng.combat:number(0, math.pi * 2),
		diffAtSpawn = math.clamp(run.stats:get("difficulty"), 0, DifficultyConfig.MAX_DIFFICULTY or 3),
	}
	e.maxHp = e.hp
	local model, root, tint, info = Brainrots.build(Brainrots.forEnemy(kind), visSize, elite,
		CFrame.new(run.map.origin + Vector3.new(x, visSize / 2 + run.map.height(x, z), z)), run.enemyFolder,
		{ lowDetail = run.enemyCount >= SpawnConfig.alive.lowDetailFrom and not elite }) -- con muchos enemigos vivos, los nuevos usan menos piezas
	e.part = root; e.model = model; e.tint = tint
	e.anim = info.anim; e.animFreq = 5 + e.speed * 0.45
	run.enemies[e.id] = e
	run.enemyCount += 1
	return e
end

local function removeEnemy(run, e)
	if e.removed then return end
	e.removed = true
	e.status = e.status or {} -- nunca bloquear la limpieza (salir/reiniciar) por un enemigo incompleto
	if e.status.frozenUntil and e.status.frozenUntil > run.clock.t then
		run.frozenCount = math.max(0, run.frozenCount - 1)
	end
	e.status.frozenUntil = nil
	run.enemies[e.id] = nil
	run.enemyCount -= 1
	-- estadísticas del spawn (panel de depuración): muerto en combate o quitado (limpieza, fin de etapa)
	local ds = run.spawnDir
	if ds and not e.boss then if e.dead then ds.stats.killed += 1 else ds.stats.cleared += 1 end end
	if e.model then e.model:Destroy() elseif e.part then e.part:Destroy() end
end
Combat.removeEnemy = removeEnemy

-- ===== Botín =====
local function addLoot(run, kind, x, z, value)
	-- agrupa en un recogible cercano del mismo tipo si se alcanzó el límite (conserva valor)
	if run.lootCount >= 260 then
		for _, l in pairs(run.loot) do
			if l.kind == kind and (l.x - x) ^ 2 + (l.z - z) ^ 2 < 400 then l.value += value return end
		end
	end
	run.nextLootId += 1
	local l = { id = run.nextLootId, kind = kind, x = x, z = z, value = value, born = run.clock.t }
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false
	p.Material = Enum.Material.Neon
	if kind == "xp" then p.Color = Color3.fromRGB(80, 230, 120); p.Size = Vector3.one * 0.9
	elseif kind == "gold" then p.Color = Color3.fromRGB(255, 205, 40); p.Size = Vector3.one * 1.1
	elseif kind == "heal" then p.Color = Color3.fromRGB(255, 80, 100); p.Size = Vector3.one * 1.3
	elseif kind == "magnet" then p.Color = Color3.fromRGB(90, 170, 255); p.Size = Vector3.one * 1.6
	elseif kind == "bomb" then p.Color = Color3.fromRGB(35, 35, 40); p.Size = Vector3.one * 1.8; p.Material = Enum.Material.SmoothPlastic
	elseif kind == "freeze" then p.Color = Color3.fromRGB(150, 235, 255); p.Size = Vector3.one * 1.6; p.Material = Enum.Material.Ice
	elseif kind == "apple" then p.Color = Color3.fromRGB(215, 30, 40); p.Size = Vector3.one * 1.5; p.Material = Enum.Material.SmoothPlastic
	else p.Color = Color3.fromRGB(220, 230, 240); p.Size = Vector3.one * 1.1 end
	p.CFrame = CFrame.new(run.map.origin + Vector3.new(x, 1 + run.map.height(x, z), z))
	if kind == "apple" then
		-- manzana: cuerpo rojo + tallo + hoja (soldados: siguen a la pieza principal cuando la atrae el imán)
		p.Name = "Apple"
		local function bit(size, off, color, mat, rot)
			local b = Instance.new("Part")
			b.Size = size; b.Color = color; b.Material = mat
			b.Anchored = false; b.CanCollide = false; b.CanQuery = false; b.CanTouch = false; b.Massless = true; b.CastShadow = false
			b.CFrame = p.CFrame * CFrame.new(off) * (rot or CFrame.identity)
			local w = Instance.new("WeldConstraint"); w.Part0 = p; w.Part1 = b; w.Parent = b
			b.Parent = p
		end
		bit(Vector3.new(0.14, 0.45, 0.14), Vector3.new(0, 0.85, 0), Color3.fromRGB(90, 55, 25), Enum.Material.Wood)
		bit(Vector3.new(0.5, 0.06, 0.28), Vector3.new(0.25, 0.95, 0), Color3.fromRGB(70, 175, 60), Enum.Material.SmoothPlastic, CFrame.Angles(0, 0, -0.5))
		local hl = Instance.new("PointLight"); hl.Color = Color3.fromRGB(255, 90, 90); hl.Range = 6; hl.Brightness = 1; hl.Parent = p
	end
	if kind == "heal" or kind == "magnet" or kind == "bomb" or kind == "freeze" then
		-- 2026-11-04: los potenciadores tienen forma (antes eran pelotas de color). La pieza principal sigue siendo la raíz;
		-- las demás van soldadas. El cliente los hace girar y flotar (Controllers/LootSpin, atributo Spin).
		p.Name = "PU_" .. kind
		p:SetAttribute("Spin", true)
		p.CFrame = p.CFrame + Vector3.new(0, 0.6, 0)
		local function bit(shape, size, off, color, mat, rot)
			local b = Instance.new("Part")
			b.Shape = shape; b.Size = size; b.Color = color; b.Material = mat
			b.Anchored = false; b.CanCollide = false; b.CanQuery = false; b.CanTouch = false; b.Massless = true; b.CastShadow = false
			b.CFrame = p.CFrame * CFrame.new(off) * (rot or CFrame.identity)
			local w = Instance.new("WeldConstraint"); w.Part0 = p; w.Part1 = b; w.Parent = b
			b.Parent = p
			return b
		end
		local BLOCK, BALL, CYL = Enum.PartType.Block, Enum.PartType.Ball, Enum.PartType.Cylinder
		local glow
		if kind == "heal" then
			-- manzana grande y brillante (como el ícono ?? del mapa)
			p.Color = Color3.fromRGB(225, 30, 45); p.Material = Enum.Material.SmoothPlastic; p.Size = Vector3.new(1.9, 1.75, 1.9)
			bit(BALL, Vector3.new(0.7, 0.5, 0.7), Vector3.new(0, 0.78, 0), Color3.fromRGB(170, 20, 35), Enum.Material.SmoothPlastic)
			bit(BLOCK, Vector3.new(0.16, 0.6, 0.16), Vector3.new(0, 1.15, 0), Color3.fromRGB(90, 55, 25), Enum.Material.Wood, CFrame.Angles(0, 0, 0.2))
			bit(BLOCK, Vector3.new(0.7, 0.07, 0.36), Vector3.new(0.35, 1.25, 0), Color3.fromRGB(70, 185, 60), Enum.Material.SmoothPlastic, CFrame.Angles(0, 0, -0.5))
			bit(BALL, Vector3.new(0.35, 0.5, 0.2), Vector3.new(-0.45, 0.35, -0.82), Color3.fromRGB(255, 190, 190), Enum.Material.SmoothPlastic) -- brillo
			glow = Color3.fromRGB(255, 90, 100)
		elseif kind == "magnet" then
			-- imán de herradura rojo con puntas plateadas
			p.Transparency = 1; p.Size = Vector3.one * 0.5
			local red, silver = Color3.fromRGB(220, 35, 40), Color3.fromRGB(215, 220, 230)
			bit(BLOCK, Vector3.new(1.9, 0.55, 0.55), Vector3.new(0, -0.55, 0), red, Enum.Material.SmoothPlastic)
			bit(CYL, Vector3.new(0.55, 0.62, 0.62), Vector3.new(-0.95, -0.55, 0), red, Enum.Material.SmoothPlastic, CFrame.Angles(0, math.pi / 2, 0))
			bit(CYL, Vector3.new(0.55, 0.62, 0.62), Vector3.new(0.95, -0.55, 0), red, Enum.Material.SmoothPlastic, CFrame.Angles(0, math.pi / 2, 0))
			bit(BLOCK, Vector3.new(0.55, 1.2, 0.55), Vector3.new(-0.95, 0.2, 0), red, Enum.Material.SmoothPlastic)
			bit(BLOCK, Vector3.new(0.55, 1.2, 0.55), Vector3.new(0.95, 0.2, 0), red, Enum.Material.SmoothPlastic)
			bit(BLOCK, Vector3.new(0.58, 0.45, 0.58), Vector3.new(-0.95, 1.0, 0), silver, Enum.Material.Metal)
			bit(BLOCK, Vector3.new(0.58, 0.45, 0.58), Vector3.new(0.95, 1.0, 0), silver, Enum.Material.Metal)
			glow = Color3.fromRGB(110, 170, 255)
		elseif kind == "bomb" then
			-- bomba negra con mecha y chispa
			p.Color = Color3.fromRGB(30, 30, 36); p.Material = Enum.Material.SmoothPlastic; p.Size = Vector3.one * 1.8
			bit(CYL, Vector3.new(0.35, 0.7, 0.7), Vector3.new(0, 0.95, 0), Color3.fromRGB(70, 70, 80), Enum.Material.Metal, CFrame.Angles(0, 0, math.pi / 2))
			bit(BLOCK, Vector3.new(0.12, 0.55, 0.12), Vector3.new(0.12, 1.32, 0), Color3.fromRGB(150, 110, 60), Enum.Material.Fabric, CFrame.Angles(0, 0, -0.45))
			local spark = bit(BALL, Vector3.one * 0.32, Vector3.new(0.26, 1.6, 0), Color3.fromRGB(255, 170, 40), Enum.Material.Neon)
			local sl = Instance.new("PointLight"); sl.Color = Color3.fromRGB(255, 140, 40); sl.Range = 5; sl.Brightness = 3; sl.Parent = spark
			local pe = Instance.new("ParticleEmitter"); pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"; pe.Rate = 12; pe.Lifetime = NumberRange.new(0.25, 0.45)
			pe.Speed = NumberRange.new(1.5, 3); pe.SpreadAngle = Vector2.new(60, 60); pe.Size = NumberSequence.new(0.25, 0); pe.Color = ColorSequence.new(Color3.fromRGB(255, 200, 80)); pe.LightEmission = 1; pe.Parent = spark
			bit(BALL, Vector3.new(0.35, 0.5, 0.2), Vector3.new(-0.42, 0.38, -0.78), Color3.fromRGB(110, 110, 125), Enum.Material.SmoothPlastic) -- brillo
			glow = Color3.fromRGB(255, 80, 40)
		elseif kind == "freeze" then
			-- reloj (congela el tiempo): esfera de hielo, cara blanca, agujas y campanitas
			p.Transparency = 1; p.Size = Vector3.one * 0.5
			local rim, ink = Color3.fromRGB(120, 210, 255), Color3.fromRGB(30, 40, 60)
			bit(CYL, Vector3.new(0.4, 1.9, 1.9), Vector3.zero, rim, Enum.Material.Ice, CFrame.Angles(0, math.pi / 2, 0))
			bit(CYL, Vector3.new(0.44, 1.5, 1.5), Vector3.zero, Color3.fromRGB(245, 250, 255), Enum.Material.SmoothPlastic, CFrame.Angles(0, math.pi / 2, 0))
			for _, sgn in ipairs({ -1, 1 }) do
				bit(BLOCK, Vector3.new(0.09, 0.55, 0.06), Vector3.new(0, 0.22, sgn * 0.24), ink, Enum.Material.SmoothPlastic)
				bit(BLOCK, Vector3.new(0.4, 0.09, 0.06), Vector3.new(0.17, 0, sgn * 0.24), ink, Enum.Material.SmoothPlastic)
				for k = 0, 3 do
					local a = k * math.pi / 2
					bit(BLOCK, Vector3.new(0.1, 0.1, 0.05), Vector3.new(math.sin(a) * 0.6, math.cos(a) * 0.6, sgn * 0.24), rim, Enum.Material.SmoothPlastic)
				end
			end
			bit(BALL, Vector3.one * 0.5, Vector3.new(-0.62, 0.95, 0), rim, Enum.Material.Ice)
			bit(BALL, Vector3.one * 0.5, Vector3.new(0.62, 0.95, 0), rim, Enum.Material.Ice)
			bit(CYL, Vector3.new(0.3, 0.3, 0.3), Vector3.new(0, 1.08, 0), rim, Enum.Material.Ice, CFrame.Angles(0, 0, math.pi / 2))
			glow = Color3.fromRGB(150, 235, 255)
		end
		local gl = Instance.new("PointLight"); gl.Range = 9; gl.Brightness = 2; gl.Color = glow; gl.Parent = p
	end
	p.Parent = run.lootFolder
	l.part = p
	run.loot[l.id] = l
	run.lootCount += 1
end
Combat.addLoot = addLoot

local function dropLoot(run, e)
	local rng = run.rng.loot
	local eco = GameConfig.economy.drops
	addLoot(run, "xp", e.x, e.z, e.xp)
	local pm = math.min(1, run.stats:get("powerupDropMultiplier"))
	pm = math.max(pm, 1)
	if rng:chance(eco.goldChance) then addLoot(run, "gold", e.x + rng:number(-1, 1), e.z + rng:number(-1, 1), rng:integer(eco.goldMin, eco.goldMax)) end
	local pu = run.stats:get("powerupDropMultiplier")
	if rng:chance(math.min(1, eco.healChance * pu)) then addLoot(run, "heal", e.x, e.z, eco.healAmount) end
	if rng:chance(math.min(1, eco.magnetChance * pu)) then addLoot(run, "magnet", e.x, e.z, 1) end
	if rng:chance(math.min(1, (eco.bombChance or 0) * pu)) then addLoot(run, "bomb", e.x, e.z, 1) end
	if rng:chance(math.min(1, (eco.freezeChance or 0) * pu)) then addLoot(run, "freeze", e.x, e.z, 1) end
	if rng:chance(math.min(1, eco.silverChance * pu)) then addLoot(run, "silver", e.x, e.z, eco.silverAmount) end
end

-- ===== Curación / supercuración =====
function Combat.heal(run, amount)
	if amount <= 0 or run.over then return 0 end
	local maxHp = run.stats:get("maxHp")
	local cap = maxHp + run.stats:get("overhealCap")
	local before = run.hp
	run.hp = math.min(cap, run.hp + amount)
	return run.hp - before
end

-- ===== Canal único de daño a enemigos =====
-- ctx = { amount, weaponId, tags = {..}, depth, canCrit(=true), critBonus, noLifesteal, noProcs, kind }
function Combat.hit(run, e, ctx)
	if e.dead or run.over or e.removed then return 0 end
	ctx.depth = ctx.depth or 0
	local st = run.stats
	local rng = run.rng.combat
	local amount = ctx.amount
	if amount ~= amount or amount <= 0 then return 0 end
	-- 1) multiplicador de daño + bonificaciones de clase (aditivas)
	local bonus = ClassEffects.damageBonus(run, e, ctx)
	local dmgMul = st:get("damageMultiplier") * (1 + bonus)
	amount *= dmgMul
	amount *= ItemEffects.damageMul(run, e, ctx, Combat)
	-- 2) bonus por tag
	if ctx.airborne then amount *= (1 + st:get("airDamageBonus")) end
	if ctx.tags and ctx.tags.poison then amount *= (1 + st:get("poisonDamageBonus")) end
	if e.elite or e.boss then amount *= st:get("eliteDamageMultiplier") end
	if e.status.markedUntil and e.status.markedUntil > run.clock.t then amount *= 1.25 end
	-- 3) crítico (sobrecrítico por tiers)
	local crit = false
	if ctx.canCrit ~= false then
		local chance = st:get("critChance") + (ctx.critBonus or 0)
		local tier = Stats.critTier(chance, rng)
		if tier > 0 then
			crit = true
			amount *= Stats.critMultiplier(tier, st:get("critDamageMultiplier") + (ctx.critDmgBonus or 0)) -- + daño crítico de las mejoras del arma
			run.critsRun = (run.critsRun or 0) + 1
		end
	end
	-- 4) mitigación del objetivo (jefes: ventana inicial)
	if e.boss and e.immuneUntil and e.immuneUntil > run.clock.t then amount = 0 end
	if amount <= 0 then return 0 end
	e.hp -= amount
	run.stats_damageDealt += amount
	if run.dmgBy then local k = ctx.weaponId or "other"; run.dmgBy[k] = (run.dmgBy[k] or 0) + amount end -- pantalla final
	e.lastHitWeapon = ctx.weaponId
	Combat.fx(run, "d", e.x, e.size + 1, e.z, math.floor(amount + 0.5), crit and 1 or 0)
	e.flash = run.clock.t + 0.08
	-- robo de vida: golpes directos SIEMPRE; armas de tick (aura, órbitas, zonas, escarcha…) con
	-- lifestealTick = true tiran como máximo 1 vez cada 0,4 s por arma (antes nunca robaban vida: 2026-11-10)
	local canSteal = not ctx.noLifesteal
	if not canSteal and ctx.lifestealTick and ctx.weaponId then
		local now = run.clock.t
		run.lsTick = run.lsTick or {}
		if (run.lsTick[ctx.weaponId] or -1) <= now then run.lsTick[ctx.weaponId] = now + 0.4; canSteal = true end
	end
	if canSteal then
		local pts = Stats.lifeStealPoints(st:get("lifeStealChance"), rng)
		if pts > 0 then
			local h = Combat.heal(run, pts)
			if run.m then run.m.add.lifesteal += h end
			-- número verde sobre el jugador (agrupado cada 0,5 s para no saturar la red)
			if h > 0 then
				run.lsAcc = (run.lsAcc or 0) + h
				if run.clock.t >= (run.lsFxAt or 0) then
					run.lsFxAt = run.clock.t + 0.5
					local shown = math.floor(run.lsAcc + 0.5)
					run.lsAcc -= shown
					if shown > 0 and run.px then Combat.fx(run, "hl", run.px, 5, run.pz, shown) end
				end
			end
		end
	end
	ItemEffects.onHit(run, e, ctx, amount, crit, Combat)
	ClassEffects.onHit(run, e, ctx, amount, Combat) -- pasivas por golpe (Tralalero, Trippi)
	if e.hp <= 0 then
		Combat.kill(run, e, ctx)
	end
	return amount
end

function Combat.kill(run, e, ctx)
	if e.dead then return end
	e.dead = true
	if e.boss then
		addLoot(run, "silver", e.x, e.z, 5) -- el jefe suelta 5 de plata
	else
		run.kills += 1
		run.stageKills += 1
		dropLoot(run, e)
		-- contadores para las misiones
		local M = run.m
		if M then
			local A = M.add
			if e.elite then A.eliteKills += 1 end
			if (run.idleT or 0) > 0.5 then A.idleKills += 1 end
			if run.isTank then A.tankKills += 1 end
			if ctx and ctx.weaponId then A.killsWeapon[ctx.weaponId] = (A.killsWeapon[ctx.weaponId] or 0) + 1 end
			if ctx and ctx.tags then
				for _, tg in ipairs(KILL_TAGS) do if ctx.tags[tg] then A.killsTag[tg] = (A.killsTag[tg] or 0) + 1 end end
			end
			-- Tomo de Suerte (wiki: lo suelta un enemigo con probabilidad mínima)
			if (M.max.luckDrop or 0) == 0 and not (run.ownedTomes and run.ownedTomes.tome_20) and run.rng.loot:chance(0.0005) then
				M.max.luckDrop = 1
				Combat.fx(run, "b", e.x, 2, e.z, 6, 120, 255, 120, 0.6)
				run.send("Toast", { text = "¡Encontraste el Tomo de Suerte! Se desbloquea al terminar la run." })
			end
		end
		ItemEffects.onKill(run, e, ctx, Combat)
		-- el minijefe deja un cofre dorado gratis (oferta de objetos)
		if e.miniboss and run.map and run.map.items then
			local ok, it = pcall(MapService.addDropChest, run.map, e.x, e.z)
			if ok and it then
				Combat.fx(run, "b", it.x, 2, it.z, 6, 255, 210, 80, 0.6)
				if run.send then run.send("Toast", { text = "¡El minijefe dejó un COFRE! Abrilo gratis con E." }) end
			end
		end
		-- Svinina Bombardino explota igual al morir (salvo con la bomba potenciador)
		if e.kind == "bomber" and not (ctx and ctx.noExplode) then
			local B = D.bomber
			local r = e.elite and B.eliteRadius or B.radius
			for _, m in ipairs(run.members or { run }) do
				if not rawget(m, "over") and not m.downed then
					local dx, dz = m.px - e.x, m.pz - e.z
					if dx * dx + dz * dz <= r * r then Combat.damagePlayer(m, e.dmg, e) end
				end
			end
			Combat.fx(run, "X", e.x, e.z, r)
			e.chargeFx = nil
		end
	end
	Combat.fx(run, "b", e.x, 1, e.z, e.radius + 1.5, 255, 120, 90, 0.25)
	-- hooks de arma por muerte (Magia de sangre) y de clase (cadena de veneno)
	if ctx and ctx.weaponId == "weapon_21" and not ctx.noProcs and run.rng.passives:chance(0.05) then
		local st = run.stats
		st:addModifier("bloodmagic_" .. run.kills, "weapon_21", "maxHp", "flat", 1)
		run.hp = math.min(run.hp + 1, st:get("maxHp") + st:get("overhealCap"))
	end
	ClassEffects.onEnemyKilled(run, e, ctx, Combat)
	removeEnemy(run, e)
	if e.boss then
		-- 2026-11-06: con varios jefes (Pilar sangriento), la etapa se gana cuando cae el ÚLTIMO
		local ws = run.world or run
		-- 2026-11-06: premio de los jefes adicionales (estatuas de jefe) y de los encuentros: cofres dorados + plata
		local map = ws.map or run.map
		for i = 1, (e.rewardChests or 0) do
			local ang = (i - 1) / math.max(1, e.rewardChests) * math.pi * 2
			pcall(MapService.addDropChest, map, e.x + math.cos(ang) * 5, e.z + math.sin(ang) * 5)
		end
		if (e.rewardSilver or 0) > 0 then addLoot(run, "silver", e.x + 2, e.z, e.rewardSilver) end
		if e.event then
			-- jefe de un encuentro del temporizador: NO termina la etapa
			pcall(function() require(script.Parent.Parent.Bosses.BossDirector).cleanupOne(ws, e) end)
			Combat.fx(run, "b", e.x, 2, e.z, e.radius + 6, 255, 210, 80, 0.6)
			local more = 0
			for _, b in ipairs(ws.eventBosses or {}) do if not b.dead then more += 1 end end
			for _, m in ipairs(ws.members or { run }) do
				if m.send then pcall(m.send, "Toast", { text = more > 0 and ("?? ¡Cayó un jefe del encuentro! Quedan %d."):format(more) or ("?? ¡Encuentro superado! %d cofre%s dorado%s."):format(e.rewardChests or 0, (e.rewardChests or 0) == 1 and "" or "s", (e.rewardChests or 0) == 1 and "" or "s") }) end
			end
			return
		end
		ws.lastBossKilled = e
		local left = 0
		for _, b in ipairs(ws.bossList or {}) do if not b.dead then left += 1 end end
		if left == 0 then
			run.bossDefeated = true
			run.onBossDefeated(run) -- solo la muerte del jefe (no cada baja de la súper horda)
		else
			pcall(function() require(script.Parent.Parent.Bosses.BossDirector).cleanupOne(ws, e) end)
			Combat.fx(run, "b", e.x, 2, e.z, e.radius + 6, 255, 60, 60, 0.6)
			for _, m in ipairs(ws.members or { run }) do
				if m.send then pcall(m.send, "Toast", { text = ("?? ¡Cayó un jefe! Quedan %d."):format(left) }) end
			end
		end
	end
end

-- ===== Estados =====
function Combat.applyFreeze(run, e, duration)
	local t = run.clock.t
	if e.boss then
		e.status.slowUntil = math.max(e.status.slowUntil or 0, t + 0.5)
		return
	end
	if e.elite then duration = 0.3 end
	duration *= DifficultyConfig.ccFactor(run.clock.stageT) -- presión tardía: resisten más con el tiempo
	local was = e.status.frozenUntil and e.status.frozenUntil > t
	e.status.frozenUntil = math.max(e.status.frozenUntil or 0, t + duration)
	if not was then run.frozenCount += 1 end
end

function Combat.applyPoison(run, e, dps, source)
	local t = run.clock.t
	local p = e.status.poison
	if not p then
		p = { stacks = {}, nextTick = t + 1 }
		e.status.poison = p
	end
	local s = p.stacks[source or "x"]
	if not s then s = { n = 0 }; p.stacks[source or "x"] = s end
	s.n = math.min(3, s.n + 1)
	s.expires = t + 3
	s.dps = dps
end

local function stepStatus(run, e, dt)
	local t = run.clock.t
	local st = e.status
	if st.frozenUntil and st.frozenUntil <= t then st.frozenUntil = nil; run.frozenCount = math.max(0, run.frozenCount - 1) end
	local p = st.poison
	if p and t >= p.nextTick then
		p.nextTick += 1 -- tick de 1 s; sin tick inmediato extra al refrescar
		local total, any = 0, false
		for src, s in pairs(p.stacks) do
			if s.expires <= t then p.stacks[src] = nil else total += s.dps * s.n; any = true end
		end
		if total > 0 then
			Combat.hit(run, e, { amount = total, tags = { poison = true }, weaponId = "poison", canCrit = false, noLifesteal = true, noProcs = true, depth = 1, kind = "dot" })
		end
		if not any then st.poison = nil end
	end
end

-- ===== Daño al jugador =====
function Combat.damagePlayer(run, amount, attacker)
	if run.over or run.downed or amount <= 0 then return end
	local t = run.clock.t
	if run.invulnUntil > t then return end
	if attacker and Behaviors.tryBlock(run, attacker) then
		Combat.fx(run, "b", run.px, 2, run.pz, 5, 120, 200, 255, 0.25)
		return -- bloqueo real: ni daño ni cooldown extra de la onda
	end
	local st = run.stats
	if attacker and attacker.boss then
		amount = math.min(amount, st:get("maxHp") * (BossConfig.Difficulty.maxHitFraction or 0.25))
	end
	if run.rng.combat:chance(st:get("evasionChance")) then
		Combat.fx(run, "t", run.px, 5, run.pz, run.px, 6, run.pz, 200, 220, 255, 0.3, 0.3)
		ClassEffects.onEvade(run, attacker, Combat)
		return
	end
	local reduced = amount * (1 - st:get("armorReduction"))
	local toShield, toHp = Stats.applyShield(run.shield, reduced)
	run.shield -= toShield
	run.lastDamageAt = t
	if toShield > 0 or toHp > 0 then
		run.stats_damageTaken += toShield + toHp
		if run.phase == "boss" then run.bossHit = true end
	end
	if toHp > 0 then
		run.hp -= toHp
		run.invulnUntil = t + C.contactInvuln
		ClassEffects.onHpDamage(run, toHp)
		ItemEffects.onPlayerHit(run, attacker, toHp, Combat)
		local thorns = st:get("thornsDamage")
		if thorns > 0 and attacker and not attacker.dead and attacker.id then
			Combat.hit(run, attacker, { amount = thorns, tags = { thorns = true }, weaponId = "thorns", canCrit = false, noLifesteal = true, noProcs = true, depth = 1, kind = "thorns" })
		end
	else
		run.invulnUntil = t + 0.15
	end
	Combat.fx(run, "p", run.px, 3, run.pz, math.floor(reduced + 0.5))
	if run.hp <= 0 then
		if ItemEffects.preventDeath(run, Combat) then return end
		run.hp = 0; run.onPlayerDeath(run, "hp")
	end
end

-- ===== Svinina Bombardino: carga y explosión kamikaze =====
-- Carga: un aviso en el piso del tamaño REAL del daño, un brillo rojo que crece, chispas cada vez más rápidas y
-- un "tic" que se acelera y sube de tono. Todo cuelga del modelo del enemigo: si muere antes, desaparece con él.
local function startBomberCharge(run, e, r)
	local root = e.part
	if not root or not root.Parent then return end
	local fx = {}
	local ground = run.map.origin + Vector3.new(e.x, run.map.height(e.x, e.z) + 0.25, e.z)
	local disc = Instance.new("Part")
	disc.Name = "FuseWarning"; disc.Shape = Enum.PartType.Cylinder; disc.Size = Vector3.new(0.2, r * 2, r * 2)
	disc.CFrame = CFrame.new(ground) * CFrame.Angles(0, 0, math.pi / 2)
	disc.Color = Color3.fromRGB(255, 70, 40); disc.Material = Enum.Material.Neon; disc.Transparency = 0.75
	disc.Anchored = false; disc.Massless = true; disc.CanCollide = false; disc.CanQuery = false; disc.CanTouch = false; disc.CastShadow = false
	local w = Instance.new("WeldConstraint"); w.Part0 = root; w.Part1 = disc; w.Parent = disc
	disc.Parent = e.model or root
	fx.disc = disc
	local light = Instance.new("PointLight"); light.Color = Color3.fromRGB(255, 90, 40); light.Range = 6; light.Brightness = 1; light.Parent = root
	fx.light = light
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(Color3.fromRGB(255, 220, 90), Color3.fromRGB(255, 70, 30)); pe.LightEmission = 1
	pe.Size = NumberSequence.new(0.5, 0); pe.Lifetime = NumberRange.new(0.2, 0.45); pe.Speed = NumberRange.new(4, 9)
	pe.SpreadAngle = Vector2.new(180, 180); pe.Rate = 10; pe.Parent = root
	fx.sparks = pe
	e.chargeFx = fx
	e.nextBeep = run.clock.t
end
local function stepBomberCharge(run, e, left, fuse)
	local fx = e.chargeFx
	if not fx then return end
	local k = math.clamp(1 - left / fuse, 0, 1) -- 0 = recién encendida, 1 = explota
	if fx.light.Parent then fx.light.Brightness = 1 + 7 * k; fx.light.Range = 6 + 10 * k end
	if fx.sparks.Parent then fx.sparks.Rate = 10 + 90 * k end
	if fx.disc.Parent then fx.disc.Transparency = 0.75 - 0.45 * k end
	if run.clock.t >= e.nextBeep then
		e.nextBeep = run.clock.t + math.max(0.07, 0.3 * (1 - k)) -- el tic se acelera
		Combat.fx(run, "F", e.x, e.z, 1 + k * 0.9)              -- y sube de tono
	end
end
Combat.startBomberCharge = startBomberCharge

-- Daña a TODOS los jugadores en pie dentro del radio y desaparece sin dar premios (si lo matas antes, sí los da).
local function explodeBomber(run, e, targets)
	if e.dead then return end
	local B = D.bomber
	local r = e.elite and B.eliteRadius or B.radius
	for _, m in ipairs(targets) do
		local dx, dz = m.px - e.x, m.pz - e.z
		if dx * dx + dz * dz <= r * r then Combat.damagePlayer(m, e.dmg, e) end
	end
	Combat.fx(run, "X", e.x, e.z, r) -- visual sincronizado: mismo tick, misma posición y radio que el daño
	e.chargeFx = nil
	e.dead = true
	removeEnemy(run, e)
end
Combat.explodeBomber = explodeBomber

-- ===== Proyectiles enemigos (esquivables) =====
function Combat.enemyShot(run, e, dirx, dirz)
	local d = math.sqrt(dirx * dirx + dirz * dirz)
	if d < 1e-3 then return end
	table.insert(run.enemyShots, { x = e.x, z = e.z, vx = dirx / d * 24, vz = dirz / d * 24, life = 3, dmg = e.dmg, id = run.nextShotId })
	run.nextShotId += 1
	Combat.fx(run, "m", -run.nextShotId, e.x, 2, e.z, dirx / d * 24, 0, dirz / d * 24, 3, 0.9, 80, 160, 255)
end

-- ===== Paso de IA de enemigos =====
-- Si el jugador está subido a un obstáculo (roca, árbol…), los enemigos no pueden entrar en él:
-- se amplía su alcance con el radio del obstáculo para que no exista un escondite seguro.
local function refugeRadius(run)
	local best = 0
	for _, o in ipairs(run.map.obstacles) do
		if not o.virtual then
			local dx, dz = run.px - o.x, run.pz - o.z
			if dx * dx + dz * dz < (o.r + 0.5) ^ 2 and o.r > best then best = o.r end
		end
	end
	return best
end

function Combat.stepEnemies(run, dt)
	local t = run.clock.t
	-- objetivos: los jugadores EN PIE del grupo (cooperativo). Cada enemigo va por el más cercano.
	local targets = {}
	for _, m in ipairs(run.members or { run }) do
		if not rawget(m, "over") and not m.downed then targets[#targets + 1] = m end
	end
	local shots = run.enemyShots
	if #targets == 0 then return end
	local px, pz = targets[1].px, targets[1].pz
	-- 2026-11-05: dirección en la que camina cada jugador (suavizada), para recolocar a los rezagados DELANTE (estilo MegaBonk)
	for _, m in ipairs(targets) do
		if rawget(m, "_mvT") ~= t then
			local lx, lz = rawget(m, "_mvLx"), rawget(m, "_mvLz")
			if lx and dt > 0 then
				local vx, vz = (m.px - lx) / dt, (m.pz - lz) / dt
				if vx * vx + vz * vz > 10000 then vx, vz = 0, 0 end -- teletransporte / portal: no cuenta
				rawset(m, "_mvX", (rawget(m, "_mvX") or 0) * 0.9 + vx * 0.1)
				rawset(m, "_mvZ", (rawget(m, "_mvZ") or 0) * 0.9 + vz * 0.1)
			end
			rawset(m, "_mvLx", m.px); rawset(m, "_mvLz", m.pz); rawset(m, "_mvT", t)
		end
	end
	-- los enemigos trepan por encima de los obstáculos: ya no hay escondites, no hace falta ampliar el alcance
	run.refugeR = 0
	local parts, cfs = {}, {}
	local ws = run.world or run
	local timeStop = (ws.timeStopUntil or 0) > t
	for _, e in pairs(run.enemies) do
		if not e.dead then
			stepStatus(run, e, dt)
			if e.dead then continue end
			if e.boss then continue end -- el jefe se mueve y ataca en Bosses/BossDirector (sin golpe cuerpo a cuerpo)
			local tgt = targets[1]
			if #targets > 1 then
				local bd = math.huge
				for _, m in ipairs(targets) do
					local d2 = (m.px - e.x) ^ 2 + (m.pz - e.z) ^ 2
					if d2 < bd then tgt, bd = m, d2 end
				end
			end
			px, pz = tgt.px, tgt.pz
			local dx, dz = px - e.x, pz - e.z
			local dist = math.sqrt(dx * dx + dz * dz)
			local frozen = e.status.frozenUntil ~= nil or (not e.boss and timeStop)
			if dist > D.far then
				-- 2026-11-05 (estilo MegaBonk): si te alejás mucho, los rezagados reaparecen DELANTE tuyo (±60° de hacia
				-- donde caminás) a distancia de spawn, sin premios. Si estás quieto, alrededor.
				local mx, mz = rawget(tgt, "_mvX") or 0, rawget(tgt, "_mvZ") or 0
				local spd = math.sqrt(mx * mx + mz * mz)
				local rng = run.rng.combat
				local ang
				if spd > 3 then ang = math.atan2(mz, mx) + rng:number(-1, 1) * math.rad(60)
				else ang = rng:number(0, math.pi * 2) end
				local r = rng:number(SpawnConfig.placement.minDist, SpawnConfig.placement.minDist + 15)
				e.x = px + math.cos(ang) * r
				e.z = pz + math.sin(ang) * r
				e.x, e.z = MapService.resolve(run.map, e.x, e.z, e.radius)
			elseif not frozen then
				local speed = e.speed
				if e.status.slowUntil and e.status.slowUntil > t then speed *= 0.85 end
				if e.pullTo then
					local gx, gz, gs = e.pullTo[1], e.pullTo[2], e.pullTo[3]
					local ddx, ddz = gx - e.x, gz - e.z
					local dd = math.sqrt(ddx * ddx + ddz * ddz)
					if dd > 0.5 then e.x += ddx / dd * gs * dt; e.z += ddz / dd * gs * dt end
					e.pullTo = nil
				end
				if e.kbx then
					e.x += e.kbx * dt; e.z += e.kbz * dt
					e.kbt -= dt
					if e.kbt <= 0 then e.kbx, e.kbz = nil, nil end
				end
				if e.kind == "bomber" and e.fuseAt then
					-- Svinina Bombardino con la mecha encendida: quieto, parpadea y explota al terminar el segundo
					local left = e.fuseAt - t
					local blink = 4 + 12 * math.clamp(1 - left / D.bomber.fuse, 0, 1) -- parpadea cada vez más rápido
					if math.floor(left * blink) % 2 == 0 then Brainrots.tint(e, "w") else Brainrots.untint(e) end
					stepBomberCharge(run, e, left, D.bomber.fuse)
					if left <= 0 then explodeBomber(run, e, targets) end
				elseif e.status.fearUntil and e.status.fearUntil > t then
					-- miedo (Esok Sekolah): huye del jugador y no ataca
					if dist > 0.01 then e.x -= dx / dist * speed * 1.1 * dt; e.z -= dz / dist * speed * 1.1 * dt end
					if e.windup > 0 then e.windup = 0; Brainrots.untint(e) end
				elseif e.kind == "bomber" then
					-- corre directo hacia el jugador más cercano; al llegar a su lado enciende la mecha
					local B = D.bomber
					if dist > 0.01 then e.x += dx / dist * speed * dt; e.z += dz / dist * speed * dt end
					if dist < B.triggerRange + e.radius then
						e.fuseAt = t + B.fuse
						local r = e.elite and B.eliteRadius or B.radius
						startBomberCharge(run, e, r) -- aviso en el piso + brillo + chispas + tic (se borran si muere antes)
					end
				elseif e.kind == "ranged" then
					if dist > D.rangedRange * 0.8 then
						e.x += dx / dist * speed * dt; e.z += dz / dist * speed * dt
					end
					e.atkCd -= dt
					if e.windup > 0 then
						e.windup -= dt
						if e.windup <= 0 then Combat.enemyShot(run, e, px - e.x, pz - e.z); e.atkCd = 2.2; Brainrots.untint(e) end
					elseif e.atkCd <= 0 and dist < D.rangedRange then
						e.windup = D.rangedWindup
						Brainrots.tint(e, "w")
						Brainrots.attack(e.model, "fire")
					end
				else
					local tx, tz = px + math.cos(e.offset) * 1.2, pz + math.sin(e.offset) * 1.2
					local ddx, ddz = tx - e.x, tz - e.z
					local dd = math.max(0.001, math.sqrt(ddx * ddx + ddz * ddz))
					if e.windup <= 0 then
						e.x += ddx / dd * speed * dt; e.z += ddz / dd * speed * dt
					end
					e.atkCd -= dt
					local reach = D.contactRange + e.radius + run.refugeR
					if e.miniboss then
						-- minijefe: sin golpe; solo daña si el jugador se pega a su cuerpo
						local MB = SpawnConfig.miniboss
						if e.windup > 0 then e.windup = 0; Brainrots.untint(e) end
						if dist < e.radius + (MB.touchPadding or 1.2) and e.atkCd <= 0 then
							Combat.damagePlayer(tgt, e.dmg * (MB.touchDamageMul or 0.6), e)
							e.atkCd = MB.touchInterval or 1
						end
					elseif e.kind == "brute" then
						if e.windup > 0 then
							e.windup -= dt
							if e.windup <= 0 then
								Brainrots.untint(e)
								if dist < reach + 1.5 then Combat.damagePlayer(tgt, e.dmg, e) end
								e.atkCd = 1.6
							end
						elseif dist < reach and e.atkCd <= 0 then
							e.windup = D.bruteWindup
							Brainrots.tint(e, "w")
							Brainrots.attack(e.model, "punch")
						end
					elseif dist < reach and e.atkCd <= 0 then
						Combat.damagePlayer(tgt, e.dmg, e)
						e.atkCd = 0.8
						Brainrots.attack(e.model, "punch")
					end
				end
			end
			if e.fuseAt and frozen then e.fuseAt += dt end -- congelado: la mecha se detiene
			if not e.dead then
				-- trepar: no se los empuja fuera de los obstáculos, suben por encima (altura suavizada)
				local hl = run.map.half
				e.x, e.z = math.clamp(e.x, -hl, hl), math.clamp(e.z, -hl, hl)
				if (run.tickN + e.id) % 3 == 0 then e.climbTarget = MapService.topAt(run.map, e.x, e.z) end
				e.climbY = (e.climbY or 0) + ((e.climbTarget or 0) - (e.climbY or 0)) * math.min(1, dt * 7)
				local ydir = Vector3.new(dx, 0, dz)
				local pos = run.map.origin + Vector3.new(e.x, (e.visSize or e.size) / 2 + run.map.height(e.x, e.z) + e.climbY, e.z)
				parts[#parts + 1] = e.part
				cfs[#cfs + 1] = Brainrots.pose(e, t, pos, ydir, not frozen and e.windup <= 0)
				if e.flash and e.flash > t then
					Brainrots.tint(e, "w")
				elseif e.flash then
					e.flash = nil
					if e.windup <= 0 then Brainrots.untint(e) end
				end
				if frozen then Brainrots.tint(e, "ice") elseif e.tintKey == "ice" then Brainrots.untint(e) end
			end
		end
	end
	if #parts > 0 then workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged) end

	-- proyectiles enemigos (golpean a cualquier jugador en pie del grupo)
	for i = #shots, 1, -1 do
		local s = shots[i]
		s.x += s.vx * dt; s.z += s.vz * dt; s.life -= dt
		local hit = nil
		for _, m in ipairs(targets) do
			local ddx, ddz = s.x - m.px, s.z - m.pz
			if ddx * ddx + ddz * ddz < 2.2 * 2.2 then hit = m; break end
		end
		if hit then
			Combat.damagePlayer(hit, s.dmg, nil)
			table.remove(shots, i)
		elseif s.life <= 0 then
			table.remove(shots, i)
		end
	end
end

-- ===== Recogibles =====
local POWERUP_KINDS = { heal = true, magnet = true, bomb = true, freeze = true, apple = true }
Combat.POWERUP_KINDS = POWERUP_KINDS
function Combat.stepLoot(run, dt)
	local st = run.stats
	local pr = st:get("pickupRadiusStuds")
	local px, pz = run.px, run.pz
	for id, l in pairs(run.loot) do
		local dx, dz = px - l.x, pz - l.z
		local d = math.sqrt(dx * dx + dz * dz)
		-- cooperativo: cada recogible lo atrae UN solo jugador (el primero que lo alcanzó), sin tirones entre compañeros
		local owner = l.pulledBy
		if owner and (rawget(owner, "over") or owner.downed) then l.pulledBy = nil; l.pulled = false; owner = nil end
		-- 2026-11-04: todo queda en el piso; hay que pasar por encima. Solo el imán (potenciador u objeto) atrae desde lejos.
		-- XP/oro/plata: un pequeño "sorbido" al rozarlos (radio de recogida). Potenciadores: solo con el imán activo.
		local isPU = POWERUP_KINDS[l.kind]
		local pick = isPU and 3 or math.max(3, pr * 0.45)
		local magnetOn = run.magnetUntil and run.magnetUntil > run.clock.t
		if not owner and not run.downed and (magnetOn or not isPU) then
			-- 2026-11-05: el imán trae XP, oro, plata Y potenciadores; sin imán los potenciadores nunca se atraen
			if magnetOn or d < pick + 1.5 then
				l.pulled = true; l.pulledBy = run; owner = run
			end
		end
		if owner == run and d > 0.01 then
			local sp = ((magnetOn or l.magnetized) and math.max(110, d * 2.5) or 38) * dt
			l.x += dx / d * math.min(sp, d); l.z += dz / d * math.min(sp, d)
			l.part.CFrame = CFrame.new(run.map.origin + Vector3.new(l.x, 1 + run.map.height(l.x, l.z), l.z))
		end
		if not run.downed and d < pick and run.loot[id] == l then
			run.onPickup(run, l)
			l.part:Destroy()
			run.loot[id] = nil
			run.lootCount -= 1
		end
	end
end

function Combat.clearEnemies(run)
	for _, e in pairs(run.enemies) do removeEnemy(run, e) end
	run.enemies = {}
	run.enemyCount = 0
	run.frozenCount = 0
	run.enemyShots = {}
end

return Combat
