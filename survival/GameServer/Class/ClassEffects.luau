--!nonstrict
-- Classes/ClassEffects: pasivas de los 20 personajes (pedidas por el usuario, 2026-10-28).
-- Indexado por passiveId. Los bonus por nivel son IDEMPOTENTES (se fija el total coef·nivel con un id estable).
-- Las pasivas con efectos en el mapa (bate, banana, bomba, círculo, miedo, sandía…) viven en ClassEffects.step.
-- La de Ballerina (cada 5 giros atrae y pega más) está en Weapons/Behaviors (orbitStep del tutú).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("GameShared")
local GameConfig = require(Shared.Config.GameConfig)

local ClassEffects = {}
local active = {} -- runs vivas (para la curación en área de Tralalita a sus aliados)

-- bonus por nivel de partida
local PERLEVEL = {
	gold_per_level = { stat = "goldMultiplier", op = "flat", coef = 0.03 },      -- Tim Cheese: +3% de oro por nivel
	thorns_mail = { stat = "thornsDamage", op = "flat", coef = 3 },              -- Lirilì: +3 de espinas por nivel
	damage_per_level = { stat = "damageMultiplier", op = "add", coef = 0.015 },  -- Cappuccino Assassino (igual que antes)
	hp_per_level = { stat = "maxHp", op = "flat", coef = 4, healDelta = true },  -- Sigma Boy: +4 de vida máx. por nivel
	speed_per_level = { stat = "moveSpeedMultiplier", op = "add", coef = 0.012 }, -- Bombombini Gusini: +1,2% de velocidad por nivel
	strength_per_level = { stat = "damageMultiplier", op = "add", coef = 0.025 }, -- Udin Din Din Dun: +2,5% de daño por nivel
}

function ClassEffects.init(run)
	run.cls = { processed = {}, nextAt = {}, bananas = {}, bombs = {}, wells = {}, propId = 0, healT = 0, healBudget = 0,
		fishHits = 0, panicReady = 0, melonUntil = 0, melonHitAt = 0, wellHitAt = 0 }
	active[run] = true
end

local function lvl(run) return run.level or 0 end

local function setLevelBonus(run, passiveId, level)
	local p = PERLEVEL[passiveId]
	if not p then return end
	local st = run.stats
	local before = st:get("maxHp")
	st:addModifier("class_passive", "class", p.stat, p.op, p.coef * level)
	if p.healDelta then
		local d = st:get("maxHp") - before
		if d > 0 then run.hp += d end
	end
end

-- Se llama UNA vez por levelUpId (nivel de carrera nuevo).
function ClassEffects.onLevelUp(run, levelUpId, level)
	if run.cls.processed[levelUpId] then return end
	run.cls.processed[levelUpId] = true
	local st = run.stats
	-- +1 Max HP por nivel (común), sin curar toda la barra: se suma solo el incremento
	local before = st:get("maxHp")
	st:addModifier("level_hp", "level", "maxHp", "flat", GameConfig.hpPerLevel * level)
	local d = st:get("maxHp") - before
	if d > 0 then run.hp += d end
	setLevelBonus(run, run.classDef.passiveId, level)
end

-- ===== utilidades =====
local function skin(run)
	local ch = run.player and run.player.Character
	return ch and ch:FindFirstChild("BrainrotSkin")
end
-- animación de golpe del personaje (+ sonido opcional)
local function pulse(run, snd, anim)
	local m = skin(run)
	if not m then return end
	if snd then
		m:SetAttribute("AtkSnd", snd)
		m:SetAttribute("Snd", ((m:GetAttribute("Snd") or 0) + 1) % 10000)
	end
	if anim ~= false then m:SetAttribute("Atk", ((m:GetAttribute("Atk") or 0) + 1) % 10000) end
end
local function knock(e, fromx, fromz, kb, time)
	local dx, dz = e.x - fromx, e.z - fromz
	local d = math.max(0.01, math.sqrt(dx * dx + dz * dz))
	local resist = (e.boss and 0.1) or (e.elite and 0.5) or 1
	e.kbx = dx / d * kb * 3 * resist
	e.kbz = dz / d * kb * 3 * resist
	e.kbt = time or 0.15
end
local function hitCtx(run, amount, id, extra)
	local c = { amount = amount, tags = {}, weaponId = id, canCrit = false, noLifesteal = true, noProcs = true, depth = 1 }
	if extra then for k, v in pairs(extra) do c[k] = v end end
	return c
end
-- ¿toca? (temporizador por clave, primera vez a los `first` segundos)
local function every(run, key, period, first)
	local c, t = run.cls, run.clock.t
	if not c.nextAt[key] then c.nextAt[key] = t + (first or period) end
	if t >= c.nextAt[key] then c.nextAt[key] = t + period; return true end
	return false
end
local function newProp(run)
	run.cls.propId += 1
	return tostring(run.id) .. "_p" .. run.cls.propId
end

-- Hooks que ya no usa ninguna pasiva (se dejan inertes para RunService/CombatService).
function ClassEffects.damageBonus(run, e, ctx) return 0 end
function ClassEffects.onHpDamage(run, toHp) end
function ClassEffects.onEvade(run, attacker, Combat) end
function ClassEffects.onEnemyKilled(run, e, ctx, Combat) end
function ClassEffects.tryAbility(run) return false end

-- cada golpe a un enemigo (lo llama Combat.hit)
function ClassEffects.onHit(run, e, ctx, amount, Combat)
	if not run.cls then return end
	local passive = run.classDef.passiveId
	if ctx.kind == "dot" or ctx.kind == "thorns" then return end
	if passive == "bite_heal" then
		-- Tralalero: se cura con cada golpe. 2026-11-05 (nerf pedido): máx. 4 de vida por segundo (antes 8)
		-- y 0,6 + 0,03 por nivel por golpe (antes 1 + 0,05 por nivel)
		local c, t = run.cls, run.clock.t
		if t >= c.healT then c.healT = t + 1; c.healBudget = 4 end
		if c.healBudget > 0 then
			local h = math.min(c.healBudget, 0.6 + lvl(run) * 0.03)
			c.healBudget -= h
			Combat.heal(run, h)
		end
	elseif passive == "rotten_fish" and ctx.weaponId == "sig_19" then
		-- Trippi: uno de cada 4 pescados está podrido y envenena
		local c = run.cls
		c.fishHits += 1
		if c.fishHits % 4 == 0 and not e.dead then
			Combat.applyPoison(run, e, 5 + lvl(run) * 0.5, "rotten_fish")
			Combat.fx(run, "b", e.x, 1, e.z, 3, 120, 200, 60, 0.4)
		end
	end
end

-- ===== pasivas con efectos en el mapa =====
function ClassEffects.step(run, dt, Combat)
	local passive = run.classDef.passiveId
	local c, t = run.cls, run.clock.t
	local L = lvl(run)
	if passive == "bat_spin" then
		-- Tung: cada 10 s gira con el bate y empuja a todos alrededor
		if every(run, "bat", 10, 4) then
			local r = 11
			Combat.fx(run, "s", "bat", run.px, run.pz, 1, 0, r, 360, 0.45, 199, 117, 56, 1)
			Combat.fx(run, "CP", "bat", run.px, run.pz, r)
			pulse(run, "bat")
			for _, e in ipairs(Combat.inRadius(run, run.px, run.pz, r)) do
				Combat.hit(run, e, hitCtx(run, 15 + 2 * L, "class_04"))
				knock(e, run.px, run.pz, 12, 0.3)
			end
		end
	elseif passive == "banana_peel" then
		-- Chimpanzini: cada 10 s deja una banana; el enemigo que la pisa se resbala (queda quieto) y recibe daño
		if every(run, "banana", 10, 3) then
			if #c.bananas >= 4 then local old = table.remove(c.bananas, 1); Combat.fx(run, "K", old.id) end
			local b = { id = newProp(run), x = run.px, z = run.pz, until_ = t + 20, armAt = t + 0.5 }
			table.insert(c.bananas, b)
			Combat.fx(run, "k", b.id, "banana", b.x, b.z, 20, 1.4)
		end
		for i = #c.bananas, 1, -1 do
			local b = c.bananas[i]
			if t > b.until_ then table.remove(c.bananas, i)
			elseif t >= (b.armAt or 0) then
				-- 2026-11-05: antes solo frenaba a UN enemigo 1,6 s (y en una horda no se notaba). Ahora resbalan todos los
				-- que estén encima: quedan aturdidos 2,5 s (los élite 0,3 s, los jefes solo se frenan) y reciben daño.
				local list = Combat.inRadius(run, b.x, b.z, 3.5)
				if #list > 0 then
					for _, e in ipairs(list) do
						Combat.applyFreeze(run, e, 2.5)
						if not e.dead then Combat.hit(run, e, hitCtx(run, 20 + 2 * L, "class_06")) end
					end
					Combat.fx(run, "K", b.id)
					Combat.fx(run, "CP", "banana", b.x, b.z)
					table.remove(c.bananas, i)
				end
			end
		end
	elseif passive == "bomb_drop" then
		-- Bombardiro: cada 7 s suelta una bomba que explota al rato
		if every(run, "bomb", 7, 3) then
			local b = { id = newProp(run), x = run.px, z = run.pz, at = t + 1.3 }
			table.insert(c.bombs, b)
			Combat.fx(run, "k", b.id, "bomb", b.x, b.z, 1.4, 1.5)
		end
		for i = #c.bombs, 1, -1 do
			local b = c.bombs[i]
			if t >= b.at then
				table.remove(c.bombs, i)
				Combat.fx(run, "K", b.id)
				Combat.fx(run, "X", b.x, b.z, 10) -- explosión de verdad: bola de fuego, onda, humo y sonido
				for _, e in ipairs(Combat.inRadius(run, b.x, b.z, 10)) do
					Combat.hit(run, e, hitCtx(run, 30 + 4 * L, "class_09", { tags = { explosive = true } }))
					knock(e, b.x, b.z, 6)
				end
			end
		end
	elseif passive == "heal_aura" then
		-- Tralalita: cada 4 s cura a su alrededor (a ella y a los aliados cerca)
		if every(run, "heal", 4, 4) then
			local amount = 0.03 * run.stats:get("maxHp") + 0.3 * L
			Combat.heal(run, amount)
			Combat.fx(run, "CP", "heal", run.px, run.pz, 14)
			local me = run.player and run.player.Character and run.player.Character:FindFirstChild("HumanoidRootPart")
			if me then
				for other in pairs(active) do
					if other ~= run and not other.over and other.player and other.player.Character then
						local hrp = other.player.Character:FindFirstChild("HumanoidRootPart")
						if hrp and (hrp.Position - me.Position).Magnitude < 30 then
							local maxHp = other.stats:get("maxHp")
							other.hp = math.min(maxHp, other.hp + 0.03 * maxHp + 0.3 * L)
						end
					end
				end
			end
		end
	elseif passive == "gravity_well" then
		-- La Vaca Saturno: cada 12 s deja un círculo que atrae a los enemigos durante 3,5 s
		if every(run, "well", 12, 5) then
			table.insert(c.wells, { x = run.px, z = run.pz, until_ = t + 3.5 })
			Combat.fx(run, "CP", "well", run.px, run.pz, 17, 3.5) -- agujero negro que se los traga
			pulse(run, "magic")
		end
		local tick = t >= c.wellHitAt
		if tick then c.wellHitAt = t + 0.5 end
		for i = #c.wells, 1, -1 do
			local wl = c.wells[i]
			if t > wl.until_ then table.remove(c.wells, i)
			else
				for _, e in ipairs(Combat.inRadius(run, wl.x, wl.z, 17)) do
					if not e.boss then e.pullTo = { wl.x, wl.z, 14 } end
					if tick then Combat.hit(run, e, hitCtx(run, 3 + 0.5 * L, "class_15")) end
				end
			end
		end
	elseif passive == "ground_stab" then
		-- Agarrini: cada 6 s clava la pala en el piso y hace daño en área
		if every(run, "stab", 6, 3) then
			local r = 10
			Combat.fx(run, "CP", "stab", run.px, run.pz, r)
			pulse(run, "shovel")
			for _, e in ipairs(Combat.inRadius(run, run.px, run.pz, r)) do
				Combat.hit(run, e, hitCtx(run, 20 + 3 * L, "class_16"))
				knock(e, run.px, run.pz, 3)
			end
		end
	elseif passive == "fear" then
		-- Esok Sekolah: cada 12 s asusta a los enemigos cercanos (huyen 3 s)
		if every(run, "fear", 12, 5) then
			Combat.fx(run, "CP", "fear", run.px, run.pz, 18)
			pulse(run, "sign")
			for _, e in ipairs(Combat.inRadius(run, run.px, run.pz, 18)) do
				if not e.boss then e.status.fearUntil = t + 3 end
			end
		end
	elseif passive == "melon_roll" then
		-- Girafa: cada 30 s se convierte en sandía 5 s: más rápida y atropella a los enemigos
		if every(run, "melon", 30, 8) then
			c.melonUntil = t + 5
			local m = skin(run); if m then m:SetAttribute("Melon", true) end
			Combat.fx(run, "CP", "melon", run.px, run.pz)
		end
		if c.melonUntil > 0 then
			if t >= c.melonUntil then
				c.melonUntil = 0
				local m = skin(run); if m then m:SetAttribute("Melon", false) end
			elseif t >= c.melonHitAt then
				c.melonHitAt = t + 0.35
				for _, e in ipairs(Combat.inRadius(run, run.px, run.pz, 4.5)) do
					Combat.hit(run, e, hitCtx(run, 15 + 2 * L, "class_18"))
					knock(e, run.px, run.pz, 8)
				end
			end
		end
	elseif passive == "panic_pause" then
		-- 67: al quedar con 15% de vida o menos, congela a todos los enemigos 4 s (enfriamiento 1 min)
		local maxHp = run.stats:get("maxHp")
		if run.hp > 0 and run.hp <= 0.15 * maxHp and t >= c.panicReady then
			c.panicReady = t + 60
			for _, e in pairs(run.enemies) do if not e.dead then Combat.applyFreeze(run, e, 4) end end
			Combat.fx(run, "CP", "ice", run.px, run.pz, 40)
			pulse(run, "sixseven")
			if run.send then run.send("Toast", { text = "¡SIX SEVEN! Enemigos congelados" }) end
		end
	end
	if run.over then active[run] = nil end
end

function ClassEffects.moveSpeedMultiplier(run)
	if run.classDef.passiveId == "melon_roll" and run.cls and run.cls.melonUntil > run.clock.t then return 1.6 end
	return 1
end

return ClassEffects
