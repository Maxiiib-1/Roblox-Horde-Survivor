--!nonstrict
-- Tests/TestRunner: runner local (sin frameworks remotos). Solo se ejecuta bajo demanda desde DevTools en Studio.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("GameShared")
local GameConfig = require(Shared.Config.GameConfig)
local Stats = require(Shared.Util.Stats)
local SeededRandom = require(Shared.Util.SeededRandom)
local ClassesCat = require(Shared.Catalogs.Classes)
local WeaponsCat = require(Shared.Catalogs.Weapons)
local TomesCat = require(Shared.Catalogs.Tomes)
local ItemsCat = require(Shared.Catalogs.Items)
local Presentation = require(Shared.Catalogs.ClassPresentationRegistry)

local Runner = {}

local function fakeRng(seq)
	local i = 0
	return { chance = function(_, p) i += 1; local v = seq[(i - 1) % #seq + 1]; return v < p end }
end

function Runner.pure()
	local res = {}
	local function check(name, cond, detail) table.insert(res, { name = name, pass = cond and true or false, detail = detail }) end
	-- Catálogos
	check("20 clases", ClassesCat.count == 20)
	check("26 armas activas", WeaponsCat.count == 26)
	check("4 armas reservadas fuera del pool", #WeaponsCat.reserved == 4)
	local sigOk = #WeaponsCat.signature == 20
	for _, c in ipairs(ClassesCat.list) do
		local wd = WeaponsCat.byId[c.startWeaponId]
		if not (wd and wd.signature and wd.classId == c.id) then sigOk = false end
	end
	check("20 armas propias (una por personaje, fuera de la tienda)", sigOk)
	check("23 tomos", TomesCat.count == 23)
	check("57 objetos", ItemsCat.count == 57)
	-- misiones: cada recompensa existe, los objetos/tomos de misión NO están en la tienda y cada objeto de misión tiene su misión
	local Missions = require(Shared.Catalogs.Missions)
	local Shop = require(Shared.Util.ShopRotation)
	local mOk = true
	for _, x in ipairs(Missions.list) do
		local exists = (x.reward.kind == "item" and ItemsCat.byId[x.reward.id]) or (x.reward.kind == "tome" and TomesCat.byId[x.reward.id])
		if not exists or Shop.entries[x.reward.id] then mOk = false end
	end
	for _, d in ipairs(ItemsCat.list) do
		if d.unlock == "mission" and not Missions.byReward[d.id] then mOk = false end
		if d.unlock == "shop" and not Shop.entries[d.id] then mOk = false end
	end
	check("36 misiones con recompensa válida y fuera de la tienda", mOk and #Missions.list == 36)
	-- el usuario pidió nombres y modelos: cada clase debe tener nombre y un modelo existente
	local Brainrots = require(Shared.Visuals.Brainrots)
	local presOk = true
	for i = 1, 20 do
		local e = Presentation[string.format("class_%02d", i)]
		if not (e and type(e.name) == "string" and Brainrots.names[e.model]) then presOk = false end
	end
	check("Registro de presentación: 20 personajes con nombre y modelo", presOk)
	local okWeapons = true
	for _, c in ipairs(ClassesCat.list) do
		if not WeaponsCat.byId[c.startWeaponId] then okWeapons = false end
		if c.id ~= string.format("class_%02d", c.slot) then okWeapons = false end
	end
	check("Arma inicial de cada clase existe", okWeapons)
	-- Presets (spot-check contra la tabla 5.1)
	local c20 = ClassesCat.byId.class_20
	check("Preset class_20", c20.maxHp == 130 and c20.overrides.critChance == 0.06 and c20.startWeaponId == "sig_20")
	local c06 = ClassesCat.byId.class_06
	check("Preset class_06", c06.maxHp == 90 and c06.overrides.shieldMax == 50 and c06.startWeaponId == "sig_06")
	-- Hoja de estadísticas: añadir/quitar fuente restaura
	local sh = Stats.newSheet({ critChance = 0.06 })
	local before = sh:get("critChance")
	sh:addModifier("t1", "item_02", "critChance", "flat", 0.10)
	local mid = sh:get("critChance")
	sh:removeSource("item_02")
	check("Añadir/quitar fuente", math.abs(mid - 0.16) < 1e-9 and math.abs(sh:get("critChance") - before) < 1e-9)
	sh:addModifier("a", "x", "armorReduction", "flat", 2)
	check("Tope de armadura 0.85", math.abs(sh:get("armorReduction") - 0.85) < 1e-9)
	sh:addModifier("nan", "y", "damageMultiplier", "flat", 0 / 0)
	check("NaN no se propaga", sh:get("damageMultiplier") == sh:get("damageMultiplier"))
	-- Crítico con RNG inyectado
	check("Crítico 0%", Stats.critTier(0, fakeRng({ 0 })) == 0)
	check("Crítico 100%", Stats.critTier(1, fakeRng({ 0.99 })) == 1)
	check("Crítico 150% (bernoulli sí)", Stats.critTier(1.5, fakeRng({ 0.2 })) == 2)
	check("Crítico 150% (bernoulli no)", Stats.critTier(1.5, fakeRng({ 0.8 })) == 1)
	check("Crítico 250%", Stats.critTier(2.5, fakeRng({ 0.4 })) == 3)
	check("Multiplicador tier 2 con x2", Stats.critMultiplier(2, 2) == 3)
	check("Robo de vida 150%", Stats.lifeStealPoints(1.5, fakeRng({ 0.1 })) == 2)
	-- XP
	check("XP L0=5, L1=8, L2=13 (curva más rápida 2026-10-29)", Stats.xpForLevel(0) == 5 and Stats.xpForLevel(1) == 8 and Stats.xpForLevel(2) == 13)
	-- Rarezas
	local w0 = Stats.rarityWeights(0)
	check("Rareza base 62/25/9/3/1 (5 rarezas)", #w0 == 5 and math.abs(w0[1] - 0.62) < 1e-9 and math.abs(w0[5] - 0.01) < 1e-9)
	local w1 = Stats.rarityWeights(1)
	check("Suerte sube épico y legendario", w1[4] > w0[4] and w1[5] > w0[5] and w1[1] < w0[1]); check("Multiplicadores de rareza 1 / 1,2 / 1,4 / 1,6 / 2", table.concat(GameConfig.rarity.magnitude, ",") == "1,1.2,1.4,1.6,2")
	local sum = 0; for _, v in ipairs(Stats.rarityWeights(-5)) do sum += v end
	check("Pesos normalizados con suerte negativa", math.abs(sum - 1) < 1e-9)
	check("Tamaño raro 8%->11.2%", math.abs(0.08 * GameConfig.rarity.magnitude[3] - 0.112) < 1e-9)
	-- RNG determinista
	local a, b = SeededRandom.new(42), SeededRandom.new(42)
	local same = true
	for _ = 1, 50 do if a:next() ~= b:next() then same = false end end
	check("RNG reproducible por semilla", same)
	-- Director de aparición (SpawnDirector): simulado, sin mapa ni modelos
	for _, r in ipairs(Runner.spawn()) do table.insert(res, r) end
	-- Dificultad progresiva por tiempo (Config/DifficultyConfig, 2026-11-04)
	for _, r in ipairs(Runner.difficulty()) do table.insert(res, r) end
	return res
end

-- ===== Pruebas del director de aparición (créditos, límites, eventos, Final Swarm, contador) =====
-- Mundo falso: los enemigos son tablas; ctx.spawn/remove imitan a CombatService (suma al crear, resta una sola vez).
function Runner.spawn()
	local SD = require(script.Parent.Parent.Services.SpawnDirector)
	local SC = require(Shared.Config.SpawnConfig)
	local res = {}
	local function check(name, cond, detail) table.insert(res, { name = "Spawn: " .. name, pass = cond and true or false, detail = detail }) end
	local DT = 1 / 20

	local function newWorld(members)
		local w = { enemies = {}, enemyCount = 0, nextId = 0, spawnDir = SD.newState(), clock = { t = 0, stageT = 0 }, phase = "normal", quiet = true }
		local ctx = { rng = SeededRandom.new(7), standing = members, players = #members, difficulty = 0, statues = 0, eliteMul = 1,
			half = 500, phase = "normal", now = 0, stageT = 0, toasts = 0, spawnLog = {} }
		ctx.spawn = function(kind, x, z, opts)
			w.nextId += 1
			local e = { id = w.nextId, kind = kind, x = x, z = z, opts = opts or {}, born = w.clock.t }
			w.enemies[e.id] = e; w.enemyCount += 1
			table.insert(ctx.spawnLog, e)
			return e
		end
		ctx.remove = function(e)
			if e.removed then return end
			e.removed = true; w.enemies[e.id] = nil; w.enemyCount -= 1
		end
		ctx.toast = function() ctx.toasts += 1 end
		return w, ctx
	end
	local function advance(w, ctx, secs, onTick)
		for _ = 1, math.floor(secs / DT + 0.5) do
			w.clock.t += DT; w.clock.stageT += DT
			ctx.now, ctx.stageT, ctx.phase = w.clock.t, w.clock.stageT, w.phase
			SD.step(w, DT, ctx)
			if onTick then onTick() end
		end
	end
	local solo = { { px = 0, pz = 0 } }

	-- 1) curvas
	check("curva interpola y no pasa los extremos", SD.curve({ { 0, 1 }, { 10, 2 } }, 5) == 1.5 and SD.curve({ { 0, 1 }, { 10, 2 } }, 99) == 2 and SD.curve({ { 0, 1 }, { 10, 2 } }, -3) == 1)

	-- 2) 10 minutos sin matar a nadie: nunca supera el límite, los créditos nunca pasan el tope
	do
		local w, ctx = newWorld(solo)
		local okCap, okBank, maxAlive, prev = true, true, 0, 0
		advance(w, ctx, 600, function()
			local ds = w.spawnDir
			-- si en este tick se creó alguno, no puede haber más vivos que el límite (cuando un enjambre termina el límite
			-- baja y puede quedar gente por encima: eso es válido, solo se frena la creación)
			if (w.enemyCount > prev and w.enemyCount > ds.lastCap) or w.enemyCount > SC.alive.hardCap then okCap = false end
			prev = w.enemyCount
			if ds.credits > SC.credits.bankCap + 1e-6 then okBank = false end
			if w.enemyCount > maxAlive then maxAlive = w.enemyCount end
		end)
		check("sin matar: vivos <= límite toda la etapa", okCap, "máx " .. maxAlive)
		check("créditos nunca superan bankCap", okBank)
		check("con el límite lleno el banco queda recortado", w.spawnDir.credits <= SC.credits.bankCapAtLimit + 1e-6, tostring(w.spawnDir.credits))
	end

	-- 3) matando todo apenas aparece: tope de apariciones por segundo y por intento
	do
		local w, ctx = newWorld(solo)
		local okSec, okAttempt, total = true, true, 0
		local perTick = {}
		advance(w, ctx, 300, function()
			local born = 0
			for _, e in pairs(w.enemies) do if e.born == w.clock.t then born += 1 end end
			if born > SC.maxPerAttempt then okAttempt = false end
			table.insert(perTick, born); total += born
			local sum = 0
			for k = math.max(1, #perTick - 19), #perTick do sum += perTick[k] end -- último segundo (20 ticks)
			if sum > SC.maxPerSecond then okSec = false end
			for _, e in pairs(table.clone(w.enemies)) do ctx.remove(e) end
		end)
		check("matando todo: <= maxPerSecond por segundo", okSec)
		check("matando todo: <= maxPerAttempt por intento", okAttempt)
		check("matando todo: repone sin esperar oleadas", total > 300, total .. " en 5 min")
	end

	-- 4) muerte simultánea de un grupo grande: sin avalancha
	do
		local w, ctx = newWorld(solo)
		advance(w, ctx, 560) -- minuto 9:20, límite lleno
		local before = w.enemyCount
		local all = table.clone(w.enemies)
		for _, e in pairs(all) do ctx.remove(e) end
		for _, e in pairs(all) do ctx.remove(e) end -- quitar dos veces no resta de más
		local afterRemove = w.enemyCount
		local n0 = #ctx.spawnLog
		advance(w, ctx, 1)
		local first = #ctx.spawnLog - n0
		check("muerte simultánea: contador en 0 (y doble baja sin efecto)", afterRemove == 0 and before > 0, "antes " .. before .. ", después " .. afterRemove)
		check("muerte simultánea: el primer segundo <= maxPerSecond", first <= SC.maxPerSecond, first .. " en 1 s")
	end

	-- 5) eventos: cada uno una sola vez por etapa; minijefe con sus multiplicadores
	do
		local w, ctx = newWorld(solo)
		local minis = 0
		advance(w, ctx, 650, function()
			for _, e in pairs(w.enemies) do if e.opts.miniboss and not e.counted then e.counted = true; minis += 1 end end
			-- matar seguido para que siempre haya lugar
			local k = 0
			for _, e in pairs(table.clone(w.enemies)) do if not e.opts.miniboss then k += 1; if k % 2 == 0 then ctx.remove(e) end end end
		end)
		local fired = 0
		for _ in pairs(w.spawnDir.fired) do fired += 1 end
		check("eventos: los " .. #SC.events .. " salen una vez", fired == #SC.events and ctx.toasts == #SC.events, fired .. " eventos, " .. ctx.toasts .. " avisos")
		check("eventos: 2 minijefes", minis == 2, tostring(minis))
		local toastsBefore = ctx.toasts
		advance(w, ctx, 60)
		check("eventos: no se repiten", ctx.toasts == toastsBefore)
		SD.resetStage(w.spawnDir); w.clock.stageT = 0
		advance(w, ctx, 200)
		check("eventos: nueva etapa los rearma", w.spawnDir.fired.miniboss1 == true and not w.spawnDir.fired.swarm1)
	end

	-- 6) minijefe con el límite lleno: espera lugar y no lo supera
	do
		-- límite fijo durante esta prueba (la curva real sube con los minutos y abriría lugar sola)
		local savedCap = SC.alive.cap
		SC.alive.cap = { { 0, 150 } }
		local w, ctx = newWorld(solo)
		advance(w, ctx, 179)
		while w.enemyCount < w.spawnDir.lastCap do ctx.spawn("chaser", 100, 100, {}) end -- límite lleno a mano
		local capAt = w.spawnDir.lastCap
		advance(w, ctx, 3)
		local pend = #w.spawnDir.pendingMini
		local over = w.enemyCount > capAt
		for _, e in pairs(table.clone(w.enemies)) do ctx.remove(e); break end
		advance(w, ctx, 1)
		local gotMini = false
		for _, e in pairs(w.enemies) do if e.opts.miniboss then gotMini = true end end
		check("minijefe espera si el límite está lleno", pend == 1 and not over)
		check("minijefe sale cuando hay lugar", gotMini and #w.spawnDir.pendingMini == 0)
		SC.alive.cap = savedCap
	end

	-- 7) Final Swarm: límite propio que baja a los 2 min y créditos que crecen
	do
		local w, ctx = newWorld(solo)
		advance(w, ctx, 600)
		w.superHorde = { start = w.clock.t, reason = "time" }
		advance(w, ctx, 30)
		local capA = w.spawnDir.lastCap
		local cpsA = w.spawnDir.lastCps
		advance(w, ctx, 100)
		local capB = w.spawnDir.lastCap
		local cpsB = w.spawnDir.lastCps
		local spawnedOver = false
		local n0 = #ctx.spawnLog
		advance(w, ctx, 10)
		if w.enemyCount > capB and #ctx.spawnLog > n0 then spawnedOver = true end
		check("Final Swarm: límite " .. SD.curve(SC.finalSwarm.cap, 30) .. " -> " .. SD.curve(SC.finalSwarm.cap, 130), capA == math.floor(SD.curve(SC.finalSwarm.cap, 30)) and capB == math.floor(SD.curve(SC.finalSwarm.cap, 130)), capA .. " / " .. capB)
		check("Final Swarm: créditos/s suben", cpsB > cpsA, string.format("%.1f -> %.1f", cpsA, cpsB))
		check("Final Swarm: no crea por encima del nuevo límite", not spawnedOver)
	end

	-- 8) cooperativo: límite escalado y nadie aparece cerca de ningún jugador
	do
		local members = { { px = 0, pz = 0 }, { px = 60, pz = 0 }, { px = -40, pz = 50 } }
		local w, ctx = newWorld(members)
		local tooClose = false
		advance(w, ctx, 120, function()
			for _, e in pairs(w.enemies) do
				if not e.checked then
					e.checked = true
					for _, m in ipairs(members) do
						if (e.x - m.px) ^ 2 + (e.z - m.pz) ^ 2 < SC.placement.safeRadius ^ 2 then tooClose = true end
					end
				end
			end
		end)
		local expect = math.floor(math.min(SD.curve(SC.alive.cap, 2) * (1 + SC.alive.coopPerExtra * 2), SC.alive.hardCap))
		check("coop: límite escalado x3 jugadores", math.abs(w.spawnDir.lastCap - expect) <= 1, w.spawnDir.lastCap .. " (esperado ~" .. expect .. ")")
		check("coop: ninguno a menos de safeRadius de ningún jugador", not tooClose)
	end

	-- 9) tope del servidor
	do
		local w, ctx = newWorld(solo)
		local others = SC.alive.serverCap - 5 -- otras partidas del servidor ya ocupan casi todo
		advance(w, ctx, 30, function() ctx.serverAlive = others + w.enemyCount end)
		check("tope del servidor respetado", w.enemyCount <= 5, tostring(w.enemyCount))
	end

	-- 10) verificación del contador
	do
		local w, ctx = newWorld(solo)
		advance(w, ctx, 20)
		w.enemyCount += 7 -- desincronizado a propósito
		advance(w, ctx, SC.debug.reconcileEvery + 0.5)
		local n = 0
		for _ in pairs(w.enemies) do n += 1 end
		check("contador desincronizado se corrige", w.enemyCount == n and w.spawnDir.stats.fixes >= 1)
	end
	return res
end

-- Prueba de integración por arma dentro de una carrera real
function Runner.weapons(run, Combat, Behaviors)
	local res = {}
	local saved = run.weapons
	run.invulnUntil = math.huge
	local all = table.clone(WeaponsCat.list)
	for _, def in ipairs(WeaponsCat.signature) do table.insert(all, def) end
	for _, def in ipairs(all) do
		Combat.clearEnemies(run)
		Behaviors.clear(run)
		run.weapons = {}
		local w = Behaviors.addWeapon(run, def.id)
		-- anillo de enemigos robustos cerca del jugador
		for i = 1, 6 do
			local ang = i * math.pi / 3
			local d = (i % 2 == 0) and 5 or 9
			local e = Combat.spawnEnemy(run, "brute", run.px + math.cos(ang) * d, run.pz + math.sin(ang) * d)
			e.hp, e.maxHp, e.speed, e.dmg = 5000, 5000, 0, 0
		end
		local dealt0 = run.stats_damageDealt
		local moveT = 0
		-- 4 s simulados sin depender del bucle (paso determinista)
		for _ = 1, 80 do
			run.clock.t += 0.05; run.tickN += 1
			if def.behaviorId == "trail" then moveT += 0.05; run.px = math.sin(moveT * 2) * 6 end
			Combat.rebuildGrid(run)
			Behaviors.step(run, 0.05, Combat)
		end
		run.px = 0
		local dealt = run.stats_damageDealt - dealt0
		table.insert(res, { name = def.id .. " " .. def.name, pass = dealt > 0, detail = string.format("daño en 4 s: %.1f · proyectiles vivos %d · zonas %d", dealt, #run.projectiles, #run.zones) })
	end
	Combat.clearEnemies(run)
	Behaviors.clear(run)
	run.weapons = saved
	run.fxQueue = {}
	return res
end

-- ===== Pruebas de la dificultad progresiva por tiempo (Config/DifficultyConfig) =====
function Runner.difficulty()
	local DC = require(Shared.Config.DifficultyConfig)
	local SC = require(Shared.Config.SpawnConfig)
	local SD = require(script.Parent.Parent.Services.SpawnDirector)
	local res = {}
	local function check(name, cond, detail) table.insert(res, { name = "Dificultad: " .. name, pass = cond and true or false, detail = detail }) end
	local EPS = 1e-6

	-- 1) multiplicadores de tiempo de los enemigos
	local h0, d0, s0 = DC.enemyTime(0)
	check("enemigos: x1 al empezar", h0 == 1 and d0 == 1 and s0 == 1, ("%.2f / %.2f / %.2f"):format(h0, d0, s0))
	local mono, overMax, ph, pd = true, false, 0, 0
	for s = 0, 3600, 15 do
		local h, d, sp = DC.enemyTime(s)
		if h < ph - EPS or d < pd - EPS then mono = false end
		if h > DC.MAX_ENEMY_HEALTH_MULTIPLIER + EPS or d > DC.MAX_ENEMY_DAMAGE_MULTIPLIER + EPS or sp > DC.MAX_ENEMY_SPEED_MULTIPLIER + EPS then overMax = true end
		ph, pd = h, d
	end
	check("enemigos: vida y daño crecen con el tiempo (nunca bajan)", mono)
	check("enemigos: nunca superan su tope por tiempo", not overMax)
	local h5, d5 = DC.enemyTime(300)
	local h10, d10 = DC.enemyTime(600)
	check("enemigos: gradual (min 5 < min 10)", h5 > 1 and h10 > h5 and d10 > d5, ("vida x%.2f -> x%.2f · daño x%.2f -> x%.2f"):format(h5, h10, d5, d10))
	local hInf, dInf = DC.enemyTime(1e7)
	check("enemigos: partida eterna = tope exacto", math.abs(hInf - DC.MAX_ENEMY_HEALTH_MULTIPLIER) < EPS and math.abs(dInf - DC.MAX_ENEMY_DAMAGE_MULTIPLIER) < EPS)
	local same = true -- con los valores de hoy, igual a la fórmula anterior (1 + 0.08/0.04 × min, freno en min 20)
	for m = 0, 30, 0.5 do
		local h, d = DC.enemyTime(m * 60)
		if DC.ENEMY_HEALTH_GROWTH_PER_MINUTE == 0.08 and DC.MAX_ENEMY_HEALTH_MULTIPLIER == 2.6 and math.abs(h - (1 + 0.08 * math.min(m, 20))) > EPS then same = false end
		if DC.ENEMY_DAMAGE_GROWTH_PER_MINUTE == 0.04 and DC.MAX_ENEMY_DAMAGE_MULTIPLIER == 1.8 and math.abs(d - (1 + 0.04 * math.min(m, 20))) > EPS then same = false end
	end
	check("enemigos: mismo ritmo que antes (sin pico ni caída)", same)
	check("enemigos: NaN / tiempo negativo -> x1", DC.grow(-5, 0.1, 3) == 1 and DC.grow(0 / 0, 0.1, 3) == 1)

	-- 2) jefes: crecen más rápido que los enemigos y tienen tope
	local bh0, bd0 = DC.bossTime(0)
	local bh5, bd5 = DC.bossTime(300)
	local bhInf, bdInf = DC.bossTime(1e7)
	check("jefe: x1 al empezar", bh0 == 1 and bd0 == 1)
	check("jefe: escala más fuerte que un enemigo (min 5)", (bh5 - 1) > (h5 - 1) and (bd5 - 1) > (d5 - 1),
		("jefe vida x%.2f daño x%.2f · enemigo vida x%.2f daño x%.2f"):format(bh5, bd5, h5, d5))
	check("jefe: tope de vida y daño", math.abs(bhInf - DC.BOSS_MAX_HEALTH_MULTIPLIER) < EPS and math.abs(bdInf - DC.BOSS_MAX_DAMAGE_MULTIPLIER) < EPS,
		("x%.2f / x%.2f"):format(bhInf, bdInf))

	-- 3) curvas de aparición y límite de vivos armadas desde DifficultyConfig
	check("cap: arranca en INITIAL_ENEMY_CAP", SD.curve(SC.alive.cap, 0) == DC.INITIAL_ENEMY_CAP, tostring(SD.curve(SC.alive.cap, 0)))
	check("cap: minuto 5 entre inicial y máximo", SD.curve(SC.alive.cap, 5) > DC.INITIAL_ENEMY_CAP and SD.curve(SC.alive.cap, 5) < DC.MAX_ENEMY_CAP, tostring(SD.curve(SC.alive.cap, 5)))
	check("cap: minuto 20+ = MAX_ENEMY_CAP (no crece más)", SD.curve(SC.alive.cap, 20) == DC.MAX_ENEMY_CAP and SD.curve(SC.alive.cap, 999) == DC.MAX_ENEMY_CAP)
	check("cap: tope absoluto = ABSOLUTE_ENEMY_CAP", SC.alive.hardCap == DC.ABSOLUTE_ENEMY_CAP)
	local c0, cR = SD.curve(SC.credits.perSecond, 0), SD.curve(SC.credits.perSecond, DC.SPAWN_RAMP_MINUTES)
	check("frecuencia: intervalo inicial y mínimo", math.abs(c0 - 1 / DC.INITIAL_SPAWN_INTERVAL) < EPS and math.abs(cR - 1 / DC.MIN_SPAWN_INTERVAL) < EPS
		and SD.curve(SC.credits.perSecond, 99) == cR, ("%.2f -> %.2f créditos/s"):format(c0, cR))
	check("configuración válida", (DC.validate()))

	-- 4) simulación del spawner: progresivo, respeta el límite y lo libera al morir
	do
		local w = { enemies = {}, enemyCount = 0, nextId = 0, spawnDir = SD.newState(), clock = { t = 0, stageT = 0 }, phase = "normal", quiet = true }
		local ctx = { rng = SeededRandom.new(11), standing = { { px = 0, pz = 0 } }, players = 1, difficulty = 0, statues = 0, eliteMul = 1, half = 500, phase = "normal", now = 0, stageT = 0 }
		local born = 0
		ctx.spawn = function(kind, x, z, opts)
			w.nextId += 1
			local e = { id = w.nextId, kind = kind, x = x, z = z, opts = opts or {} }
			w.enemies[e.id] = e; w.enemyCount += 1; born += 1
			return e
		end
		ctx.remove = function(e) if e.removed then return end; e.removed = true; w.enemies[e.id] = nil; w.enemyCount -= 1 end
		local DT = 1 / 20
		local function run(secs, killAll)
			for _ = 1, math.floor(secs / DT + 0.5) do
				w.clock.t += DT; w.clock.stageT += DT
				ctx.now, ctx.stageT = w.clock.t, w.clock.stageT
				SD.step(w, DT, ctx)
				if killAll then for _, e in pairs(table.clone(w.enemies)) do if not e.opts.miniboss then ctx.remove(e) end end end
			end
		end
		-- matando todo (sin tope de vivos en juego): cuántos salen en el minuto 0-1 vs 8-9
		born = 0; run(60, true); local early = born
		run(60 * 7, true)
		born = 0; run(60, true); local late = born
		check("spawner: al principio pocos, después más", late > early * 1.5, ("min 0-1: %d · min 8-9: %d (matando todo al instante)"):format(early, late))
		-- ritmo BASE (sin bonus de reposición: partida a medio llenar) al minuto 0 vs minuto 10
		local ds0 = SD.newState()
		local function baseCps(stageT)
			local c = table.clone(ctx); c.stageT = stageT
			return SD.creditsPerSecond({ enemies = {}, enemyCount = 0 }, c, ds0, 1e9, 100)
		end
		check("spawner: ritmo base 1 básico/INITIAL_SPAWN_INTERVAL al empezar y sube gradual",
			math.abs(baseCps(0) - 1 / DC.INITIAL_SPAWN_INTERVAL) < 1e-6 and baseCps(300) > baseCps(0) and baseCps(600) > baseCps(300),
			("%.1f -> %.1f -> %.1f créditos/s (min 0 / 5 / 10)"):format(baseCps(0), baseCps(300), baseCps(600)))
		-- sin matar: llega al límite y se frena; al matar 25 se libera lugar
		local w2 = w
		SD.resetStage(w2.spawnDir); for _, e in pairs(table.clone(w2.enemies)) do ctx.remove(e) end
		w2.clock.stageT = 0
		run(120, false)
		local cap = w2.spawnDir.lastCap
		local full = w2.enemyCount
		born = 0; run(3, false); local whileFull = born
		check("cap: se llena y no lo pasa", full >= cap - SC.maxPerAttempt and w2.enemyCount <= w2.spawnDir.lastCap, ("%d vivos / límite %d"):format(w2.enemyCount, w2.spawnDir.lastCap))
		local k = 0
		for _, e in pairs(table.clone(w2.enemies)) do k += 1; ctx.remove(e); if k >= 25 then break end end
		local freed = w2.enemyCount
		born = 0; run(3, false)
		check("cap: al morir enemigos vuelven a aparecer (sin pasar el límite)", born > 0 and w2.enemyCount <= w2.spawnDir.lastCap,
			("lleno sin lugar: +%d en 3 s · tras 25 muertes (%d vivos): +%d"):format(whileFull, freed, born))
	end

	-- 5) estadísticas reales de cada tipo (CombatService.archetypeScale) con un "run" falso
	local okC, Combat = pcall(require, script.Parent.Parent.Services.CombatService)
	if not okC or not Combat.archetypeScale then
		check("CombatService.archetypeScale disponible", false, tostring(Combat))
		return res
	end
	local function fakeRun(stageT, o)
		o = o or {}
		local vals = { difficulty = o.diff or 0 }
		return { clock = { stageT = stageT }, stage = o.stage or 1, level = o.level or 0, statues = o.statues or 0,
			coopHpMul = o.coopHp, coopDmgMul = o.coopDmg, stats = { get = function(_, k) return vals[k] or 0 end } }
	end
	local _, hpA, dmgA = Combat.archetypeScale(fakeRun(0), "chaser")
	local _, hpB, dmgB = Combat.archetypeScale(fakeRun(600), "chaser")
	check("enemigo nuevo al min 10: más vida y daño que al min 0", hpB > hpA and dmgB > dmgA, ("vida x%.2f -> x%.2f · daño x%.2f -> x%.2f"):format(hpA, hpB, dmgA, dmgB))
	local GC = require(Shared.Config.GameConfig)
	local arch = GC.director.archetypes
	local distinct = arch.brute.hp > arch.chaser.hp and arch.chaser.hp > arch.runner.hp and arch.runner.speed > arch.chaser.speed and arch.bomber.damage > arch.chaser.damage
	local _, hpBr = Combat.archetypeScale(fakeRun(600), "brute")
	check("tipos conservan sus diferencias (mismo multiplicador para todos)", distinct and math.abs(hpBr - hpB) < EPS)
	local maxRun = fakeRun(1e6, { diff = 3, level = 999, statues = 8, stage = 3 })
	local _, hpM, dmgM, spdM = Combat.archetypeScale(maxRun, "chaser")
	check("todo al máximo: topes absolutos de vida/daño/velocidad", math.abs(hpM - DC.MAX_ENEMY_TOTAL_HEALTH_MULTIPLIER) < EPS and math.abs(dmgM - DC.MAX_ENEMY_TOTAL_DAMAGE_MULTIPLIER) < EPS
		and spdM <= DC.MAX_ENEMY_TOTAL_SPEED_MULTIPLIER + EPS, ("vida x%.2f · daño x%.2f · vel x%.2f"):format(hpM, dmgM, spdM))
	local coopRun = fakeRun(1e6, { diff = 3, level = 999, statues = 8, stage = 3, coopHp = 2.8, coopDmg = 1.6 })
	local _, hpCo = Combat.archetypeScale(coopRun, "chaser")
	check("cooperativo se aplica después del tope (grupos grandes siguen escalando)", math.abs(hpCo - DC.MAX_ENEMY_TOTAL_HEALTH_MULTIPLIER * 2.8) < 1e-4)
	return res
end

return Runner
