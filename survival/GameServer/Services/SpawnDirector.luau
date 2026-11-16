--!nonstrict
-- Services/SpawnDirector: aparición CONTINUA de enemigos por créditos (inspirado en Megabonk; los números son propios y
-- están en Config/SpawnConfig), eventos programados (minijefes y enjambres), Final Swarm y verificación del contador.
--
-- No toca Roblox directamente: RunService le pasa un `ctx` con las funciones reales (crear y quitar enemigos, resolver
-- posiciones, avisos). Así Tests/TestRunner lo simula sin mapa ni modelos.
--
-- Contador de vivos: el único que lo cambia es CombatService (spawnEnemy suma DESPUÉS de construir el modelo con éxito;
-- removeEnemy resta una sola vez gracias a e.removed). Este módulo solo lo lee y, cada `debug.reconcileEvery` segundos,
-- lo compara con la lista real (world.enemies): quita enemigos cuyo modelo fue destruido por fuera y corrige diferencias.
-- El jefe NO cuenta para el límite de vivos.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CFG = require(ReplicatedStorage:WaitForChild("GameShared").Config.SpawnConfig)

local SpawnDirector = {}
SpawnDirector.config = CFG

-- interpola una curva { {x, y}, ... } en línea recta; fuera de rango usa el extremo
local function curve(points, x)
	local n = #points
	if n == 0 then return 0 end
	if x <= points[1][1] then return points[1][2] end
	for i = 2, n do
		local a, b = points[i - 1], points[i]
		if x <= b[1] then
			local f = (x - a[1]) / math.max(1e-9, b[1] - a[1])
			return a[2] + (b[2] - a[2]) * f
		end
	end
	return points[n][2]
end
SpawnDirector.curve = curve

-- orden estable de los tipos (pairs no garantiza orden y el RNG con semilla debe dar siempre lo mismo)
local function sortedKeys(t)
	local out = {}
	for k in pairs(t) do out[#out + 1] = k end
	table.sort(out)
	return out
end

function SpawnDirector.newState()
	return {
		credits = 0, attemptT = 0, window = {}, fired = {}, pendingMini = {}, reconcileT = 0,
		lastCps = 0, lastCap = 0, lastDiff = 0, lastEvent = nil, swarm = nil, finalDone = false, finalEnded = false,
		stats = { spawned = 0, killed = 0, cleared = 0, lost = 0, fixes = 0, noPlace = 0, events = 0, minibosses = 0, miniGivenUp = 0, spawnErrors = 0 },
	}
end

-- al empezar cada etapa: créditos, eventos y Final Swarm a cero (las estadísticas siguen sumando en toda la partida)
function SpawnDirector.resetStage(ds)
	if not ds then return end
	ds.credits = 0; ds.attemptT = 0; ds.window = {}; ds.fired = {}; ds.pendingMini = {}; ds.reconcileT = 0
	ds.swarm = nil; ds.finalDone = false; ds.finalEnded = false; ds.lastEvent = nil
end

-- enemigos vivos que cuentan para el límite (sin el jefe)
function SpawnDirector.aliveCount(world)
	local n = world.enemyCount or 0
	for _, b in ipairs(world.bossList or (world.boss and { world.boss }) or {}) do
		if not b.removed and world.enemies[b.id] == b then n -= 1 end
	end
	for _, b in ipairs(world.eventBosses or {}) do
		if not b.removed and world.enemies[b.id] == b then n -= 1 end
	end
	return math.max(0, n)
end
local aliveCount = SpawnDirector.aliveCount

function SpawnDirector.cost(kind, tier)
	local C = CFG.costs
	return (C.base[kind] or 1) * (C.tierMul[tier or C.tier[kind] or "normal"] or 1)
end

local function finalElapsed(world, ctx)
	local fs = world.superHorde
	if not fs then return nil end
	local e = ctx.now - fs.start
	local F = CFG.finalSwarm
	if F.duration and F.onEnd == "keep" then e = math.min(e, F.duration) end -- "keep": se queda con los valores del final
	return e
end

local function swarmActive(ds, ctx)
	return ds.swarm ~= nil and ctx.now < ds.swarm.untilT
end

-- límite de vivos de esta partida en este momento
function SpawnDirector.aliveCap(world, ctx, ds)
	local A = CFG.alive
	local players = math.max(1, ctx.players or 1)
	local fe = finalElapsed(world, ctx)
	local cap = fe and curve(CFG.finalSwarm.cap, fe) or curve(A.cap, ctx.stageT / 60)
	cap *= 1 + A.coopPerExtra * (players - 1)
	if not fe and swarmActive(ds, ctx) then cap += ds.swarm.capBonus end
	cap = math.min(cap, A.hardCap)
	-- tope del servidor: solo lo que queda libre entre todas las partidas
	if ctx.serverAlive then cap = math.min(cap, aliveCount(world) + math.max(0, A.serverCap - ctx.serverAlive)) end
	return math.floor(cap)
end

-- créditos por segundo en este momento
function SpawnDirector.creditsPerSecond(world, ctx, ds, alive, cap)
	local C = CFG.credits
	local diff = math.clamp(ctx.difficulty or 0, 0, 5)
	local players = math.max(1, ctx.players or 1)
	local fe = finalElapsed(world, ctx)
	local cps
	if fe then
		local F = CFG.finalSwarm
		cps = math.min(F.creditsMax, F.creditsStart + F.creditsPerSecond * fe)
		cps *= 1 + C.difficultyWeight * diff
	else
		cps = curve(C.perSecond, ctx.stageT / 60)
		cps *= 1 + C.difficultyWeight * diff
		cps *= 1 + C.statueBonus * (ctx.statues or 0)
		local target = math.max(1, cap * C.refillTarget)
		cps *= 1 + C.refill * math.clamp(1 - alive / target, 0, 1)
		local mul = swarmActive(ds, ctx) and ds.swarm.creditMul or 1
		cps = math.min(cps * mul, C.maxPerSecond * mul)
	end
	return cps * (1 + C.coopPerExtra * (players - 1))
end

-- lugar válido alrededor de `who`: distancia min/max, lejos de TODOS los jugadores en pie, dentro del mapa, fuera del agua
function SpawnDirector.findSpot(ctx, who)
	local P = CFG.placement
	local lim = math.max(10, (ctx.half or 500) - P.edgeMargin)
	for _ = 1, P.tries do
		local ang = ctx.rng:number(0, math.pi * 2)
		local dist = ctx.rng:number(P.minDist, P.maxDist)
		local x = math.clamp(who.px + math.cos(ang) * dist, -lim, lim)
		local z = math.clamp(who.pz + math.sin(ang) * dist, -lim, lim)
		if ctx.resolve then x, z = ctx.resolve(x, z) end -- afuera de rocas/árboles grandes
		local ok = true
		for _, m in ipairs(ctx.standing) do
			if (x - m.px) ^ 2 + (z - m.pz) ^ 2 < P.safeRadius * P.safeRadius then ok = false; break end
		end
		if ok and P.avoidWater and ctx.inWater and ctx.inWater(x, z) then ok = false end
		if ok then return x, z end
	end
	return nil
end

local function trySpawn(ds, ctx, kind, opts)
	local up = ctx.standing
	local who = up[ctx.rng:integer(1, #up)] -- se reparten entre los jugadores en pie
	local x, z = SpawnDirector.findSpot(ctx, who)
	if not x then ds.stats.noPlace += 1; return nil end
	local e = ctx.spawn(kind, x, z, opts)
	if e then ds.stats.spawned += 1 else ds.stats.spawnErrors += 1 end
	return e
end

local function pickKind(ctx, weights, minute, ignoreUnlock)
	local unlock = CFG.variety.unlockMinute
	local kinds, ws = {}, {}
	for _, kind in ipairs(sortedKeys(weights)) do
		local w = weights[kind]
		if w > 0 and (ignoreUnlock or minute >= (unlock[kind] or 0)) then kinds[#kinds + 1] = kind; ws[#ws + 1] = w end
	end
	if #kinds == 0 then return "chaser" end
	return kinds[ctx.rng:weighted(ws)]
end

local function finalDamageMul(fe)
	if not fe then return 1 end
	local F = CFG.finalSwarm
	return math.min(F.damageMax, F.damageStart + F.damagePerSecond * fe)
end

-- ===== eventos programados =====
local function stepEvents(world, ctx, ds, cap)
	local finalOn = world.superHorde ~= nil
	for _, ev in ipairs(CFG.events) do
		if not ds.fired[ev.id] and ctx.stageT >= ev.at and ctx.phase ~= "boss" then
			ds.fired[ev.id] = true -- UNA sola vez por etapa, salga o no salga
			if finalOn and not CFG.eventsDuringFinal then
				ds.lastEvent = ev.id .. " (omitido: Final Swarm)"
			else
				if ev.kind == "swarm" then
					ds.swarm = { id = ev.id, untilT = ctx.now + (ev.duration or 20), creditMul = ev.creditMul or 2, capBonus = ev.capBonus or 0, weights = ev.weights }
				elseif ev.kind == "miniboss" then
					table.insert(ds.pendingMini, { ev = ev, since = ctx.now })
				end
				ds.stats.events += 1
				ds.lastEvent = ev.id
				if ev.text and ctx.toast then ctx.toast(ev.text) end
			end
		end
	end
	-- minijefes pendientes: salen cuando hay lugar (respetan el límite de vivos)
	local M = CFG.miniboss
	for i = #ds.pendingMini, 1, -1 do
		local p = ds.pendingMini[i]
		if ctx.now - p.since > M.giveUpAfter then
			table.remove(ds.pendingMini, i)
			ds.stats.miniGivenUp += 1
		elseif aliveCount(world) < cap then
			local kind = p.ev.archetype or "brute"
			local e = trySpawn(ds, ctx, kind, { elite = true, miniboss = true, hpMul = M.hpMul, sizeMul = M.sizeMul, xpMul = M.xpMul,
				dmgMul = M.damageMul * finalDamageMul(finalElapsed(world, ctx)) })
			if e then
				table.remove(ds.pendingMini, i)
				ds.stats.minibosses += 1
				local bank = world.superHorde and CFG.finalSwarm.bankCap or CFG.credits.bankCap
				ds.credits = math.max(-bank, ds.credits - SpawnDirector.cost(kind, "miniboss"))
			end
		end
	end
end

-- verificación del contador: barato (cada N segundos), corrige si algo se desincronizó
function SpawnDirector.reconcile(world, ctx, ds)
	local lost = nil
	for _, e in pairs(world.enemies) do
		if not e.boss and not e.removed and typeof(e.model) == "Instance" and e.model.Parent == nil then
			lost = lost or {}
			lost[#lost + 1] = e -- su modelo fue destruido por fuera: se quita de la lógica también
		end
	end
	if lost then
		for _, e in ipairs(lost) do
			if ctx.remove then ctx.remove(e) end
			ds.stats.lost += 1
			ds.stats.cleared -= 1 -- removeEnemy lo contó como "quitado"; acá es "perdido"
		end
	end
	local n = 0
	for _ in pairs(world.enemies) do n += 1 end
	if n ~= world.enemyCount then
		if not world.quiet then -- (los mundos falsos de las pruebas no avisan en la Salida)
			warn(("[SpawnDirector] contador desincronizado: %d en el contador, %d en la lista. Corregido."):format(world.enemyCount, n))
		end
		world.enemyCount = n
		ds.stats.fixes += 1
	end
end

-- ===== paso principal (lo llama RunService con el mundo activo) =====
-- ctx: now, stageT, phase, standing (miembros en pie con px/pz), players, rng, difficulty, statues, eliteMul,
--      serverAlive, half, resolve(x,z), inWater(x,z), spawn(kind,x,z,opts) -> e|nil, remove(e), toast(text),
--      endFinal(mode) [Final Swarm con duración]
function SpawnDirector.step(world, dt, ctx)
	local ds = world.spawnDir
	if not ds then ds = SpawnDirector.newState(); world.spawnDir = ds end
	if not ctx.standing or #ctx.standing == 0 then return end

	-- verificación periódica del contador
	ds.reconcileT += dt
	if ds.reconcileT >= CFG.debug.reconcileEvery then ds.reconcileT = 0; SpawnDirector.reconcile(world, ctx, ds) end

	-- fin del Final Swarm (solo si tiene duración)
	local F = CFG.finalSwarm
	local fs = world.superHorde
	if fs and F.duration and not ds.finalEnded and ctx.now - fs.start >= F.duration then
		ds.finalEnded = true
		if F.onEnd ~= "keep" then
			if ctx.endFinal then ctx.endFinal(F.onEnd) end
			if F.onEnd == "calm" then ds.finalDone = true end
		end
		fs = world.superHorde
	end
	if ds.swarm and ctx.now >= ds.swarm.untilT then ds.swarm = nil end

	local alive = aliveCount(world)
	local cap = SpawnDirector.aliveCap(world, ctx, ds)
	local cps = SpawnDirector.creditsPerSecond(world, ctx, ds, alive, cap)
	ds.lastCps, ds.lastCap, ds.lastDiff = cps, cap, math.clamp(ctx.difficulty or 0, 0, 5)

	-- créditos: solo se acumulan si hay lugar; con el límite lleno el banco se recorta (sin avalancha después)
	local C = CFG.credits
	local bankCap = fs and F.bankCap or C.bankCap
	if alive >= cap then
		ds.credits = math.min(ds.credits, C.bankCapAtLimit)
	else
		ds.credits = math.min(bankCap, ds.credits + cps * dt)
	end

	-- intentos espaciados
	ds.attemptT += dt
	if ds.attemptT < CFG.attemptInterval then return end
	ds.attemptT = 0

	stepEvents(world, ctx, ds, cap)
	alive = aliveCount(world)

	-- ventana de 1 s para el tope de apariciones por segundo
	local w = ds.window
	while #w > 0 and ctx.now - w[1] >= 1 do table.remove(w, 1) end
	local perSecond = fs and F.maxPerSecond or CFG.maxPerSecond

	local minute = ctx.stageT / 60
	local fe = finalElapsed(world, ctx)
	local swarm = (not fe) and swarmActive(ds, ctx) and ds.swarm or nil
	local weights = swarm and swarm.weights or CFG.variety.weights
	local eliteP = curve(CFG.variety.eliteChance, minute) * (ctx.eliteMul or 1) * (fe and F.eliteChanceMul or 1)
	local dmgMul = finalDamageMul(fe)
	local made = 0
	while made < CFG.maxPerAttempt and #w < perSecond and alive < cap do
		local kind = pickKind(ctx, weights, minute, swarm ~= nil or fe ~= nil)
		local elite = eliteP > 0 and ctx.rng:chance(eliteP)
		local cost = SpawnDirector.cost(kind, elite and "elite" or nil)
		if ds.credits < cost and elite then elite = false; cost = SpawnDirector.cost(kind) end
		if ds.credits < cost then break end -- se junta para la próxima
		local e = trySpawn(ds, ctx, kind, { elite = elite, dmgMul = dmgMul })
		if not e then break end
		ds.credits -= cost
		made += 1
		alive += 1
		w[#w + 1] = ctx.now
	end
end

-- ===== depuración =====
function SpawnDirector.canDebug(player, isStudio)
	return (isStudio and CFG.debug.studio) or (player ~= nil and CFG.debug.admins[player.UserId] == true)
end

function SpawnDirector.debugInfo(world, maxSeconds)
	local ds = world.spawnDir
	if not ds then return nil end
	local now = world.clock.t
	local phase = world.phase == "boss" and "jefe" or "normal"
	if world.superHorde then
		phase = ("Final Swarm %ds"):format(math.floor(now - world.superHorde.start))
	elseif ds.swarm and now < ds.swarm.untilT then
		phase = ("enjambre (%ds)"):format(math.ceil(ds.swarm.untilT - now))
	end
	local fired = {}
	for _, ev in ipairs(CFG.events) do fired[#fired + 1] = (ds.fired[ev.id] and "?" or "·") .. ev.id end
	local s = ds.stats
	return {
		alive = aliveCount(world), cap = ds.lastCap, credits = math.floor(ds.credits * 10 + 0.5) / 10,
		cps = math.floor(ds.lastCps * 100 + 0.5) / 100, diff = math.floor(ds.lastDiff * 100 + 0.5) / 100,
		remaining = math.max(0, maxSeconds - world.clock.stageT), phase = phase, perSec = #ds.window,
		spawned = s.spawned, killed = s.killed, cleared = s.cleared, lost = s.lost, fixes = s.fixes, noPlace = s.noPlace,
		minis = s.minibosses, pending = #ds.pendingMini, events = table.concat(fired, " "), last = ds.lastEvent,
	}
end

return SpawnDirector
