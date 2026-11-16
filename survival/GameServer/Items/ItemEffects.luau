--!nonstrict
-- Items/ItemEffects: efectos especiales de los objetos (Catalogs/Items, campo fx). Todo el daño pasa por Combat.hit
-- con noProcs = true y depth = 1, así un efecto nunca dispara otro efecto en cadena.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemsCat = require(ReplicatedStorage:WaitForChild("GameShared").Catalogs.Items)

local IE = {}

local function n(run, id) return run.items[id] or 0 end
local function proc(amount, weaponId, tags)
	return { amount = amount, tags = tags or {}, weaponId = weaponId, canCrit = false, noLifesteal = true, noProcs = true, depth = 1, kind = "item" }
end

-- Al conseguir una copia: modificadores planos por copia (se reescriben con el total) y efectos de stat especiales
function IE.applyStats(run, id)
	local def = ItemsCat.byId[id]
	if not def then return end
	local st = run.stats
	local count = n(run, id)
	if def.stats then
		local before = st:get("maxHp")
		for i, s in ipairs(def.stats) do
			st:addModifier(("item_%s_%d"):format(id, i), id, s[1], s[3] or "flat", s[2] * count)
		end
		local delta = st:get("maxHp") - before
		if def.healWithMax and delta > 0 then run.hp += delta end
	end
	if def.fx == "beer" then st:addModifier("item_beer_hp", id, "maxHp", "mult", 0.95 ^ count) end
	if def.fx == "leech" then st:addModifier("item_leech_regen", id, "hpRegenPerMinute", "mult", 0.5 ^ count) end
	run.hp = math.min(run.hp, st:get("maxHp") + st:get("overhealCap"))
end

-- Multiplicador de daño de los objetos (antes del crítico)
function IE.damageMul(run, e, ctx, Combat)
	local m = 1
	local k = n(run, "item_11")
	if k > 0 then m *= 1 + 0.20 * k * (run.stats:get("maxHp") / 100) end
	k = n(run, "item_43")
	if k > 0 and e.hp >= e.maxHp * 0.9 then m *= 1 + 0.20 * k end
	k = n(run, "item_44")
	if k > 0 and (e.x - run.px) ^ 2 + (e.z - run.pz) ^ 2 <= 64 then m *= 1 + 0.20 * k end
	k = n(run, "item_41")
	if k > 0 and run.hp < run.stats:get("maxHp") * 0.5 then m *= 1 + 1.0 * k end
	k = n(run, "item_53")
	if k > 0 then m *= 1 + k * math.min(1, (run.idleT or 0) / 5) end
	if (run.joeStacks or 0) > 0 then m *= 1 + 0.01 * run.joeStacks end
	k = n(run, "item_13")
	if k > 0 and not ctx.noProcs and run.rng.passives:chance(math.min(1, 0.02 * k)) then
		m *= 20
		Combat.fx(run, "b", e.x, 2, e.z, 5, 255, 255, 255, 0.3)
	end
	return m
end

-- Efectos al golpear (solo golpes directos de armas)
function IE.onHit(run, e, ctx, amount, crit, Combat)
	if ctx.noProcs or (ctx.depth or 0) > 0 then return end
	local rng = run.rng.passives
	local t = run.clock.t
	local k = n(run, "item_23")
	if k > 0 and not e.dead and rng:chance(math.min(1, 0.2 * k)) then Combat.applyFreeze(run, e, 1.2) end
	k = n(run, "item_26")
	if k > 0 and not e.dead and rng:chance(math.min(1, 0.2 * k)) then Combat.applyPoison(run, e, 3, "item_26") end
	k = n(run, "item_27")
	if k > 0 and rng:chance(math.min(1, 0.08 * k)) then
		Combat.fx(run, "b", e.x, 1, e.z, 7, 255, 200, 80, 0.35)
		for _, v in ipairs(Combat.inRadius(run, e.x, e.z, 7)) do Combat.hit(run, v, proc(25, "item_27", { explosive = true })) end
	end
	k = n(run, "item_30")
	if k > 0 and rng:chance(math.min(1, 0.25 * k)) then
		Combat.fx(run, "b", e.x, 1, e.z, 4, 255, 120, 60, 0.25)
		for _, v in ipairs(Combat.inRadius(run, e.x, e.z, 4)) do Combat.hit(run, v, proc(amount * 0.4, "item_30", { explosive = true })) end
	end
	k = n(run, "item_32")
	if k > 0 and t >= (run.mittsAt or 0) then
		run.mittsAt = t + 10 / k
		local visited, cur, fx, fz = {}, e, e.x, e.z
		for _ = 1, 5 do
			if not cur then break end
			visited[cur.id] = true
			Combat.fx(run, "t", fx, 4, fz, cur.x, 2, cur.z, 255, 240, 120, 0.5, 0.25)
			Combat.hit(run, cur, proc(30, "item_32", { lightning = true }))
			fx, fz = cur.x, cur.z
			cur = Combat.nearest(run, fx, fz, 14, visited)
		end
	end
	k = n(run, "item_45")
	if k > 0 and rng:chance(math.min(1, 0.15 * k)) then
		Combat.fx(run, "z", e.x, 0.3, e.z, 5, 255, 90, 20, 1)
		for _, v in ipairs(Combat.inRadius(run, e.x, e.z, 5)) do Combat.hit(run, v, proc(12, "item_45", { fire = true })) end
	end
	k = n(run, "item_46")
	if k > 0 and rng:chance(math.min(1, 0.25 * k)) then
		Combat.fx(run, "t", e.x, 14, e.z, e.x, 1, e.z, 200, 220, 255, 1, 0.25)
		for _, v in ipairs(Combat.inRadius(run, e.x, e.z, 4)) do
			Combat.hit(run, v, proc(18, "item_46", { lightning = true }))
			if not v.dead then Combat.applyFreeze(run, v, 0.4) end
		end
	end
	k = n(run, "item_47")
	if k > 0 and not e.dead and not (e.boss or e.elite) and rng:chance(math.min(1, 0.01 * k)) then
		Combat.hit(run, e, proc(e.hp + 1, "item_47"))
		run.joeStacks = math.min(30, (run.joeStacks or 0) + 1)
	end
	k = n(run, "item_57")
	if k > 0 and crit and rng:chance(math.min(1, 0.25 * k)) then Combat.heal(run, 2) end
end

-- Al matar
function IE.onKill(run, e, ctx, Combat)
	local rng = run.rng.passives
	local k = n(run, "item_14")
	if k > 0 and rng:chance(math.min(1, 0.02 * k)) then Combat.addLoot(run, "heal", e.x, e.z, 15) end
	k = n(run, "item_51")
	if k > 0 and rng:chance(math.min(1, 0.12 * k)) then Combat.addLoot(run, "xp", e.x + 1, e.z, e.xp or 1) end
	k = n(run, "item_40")
	if k > 0 and rng:chance(math.min(1, 0.10 * k)) then
		local tgt = Combat.nearest(run, e.x, e.z, 20, { [e.id] = true })
		if tgt then
			Combat.fx(run, "t", e.x, 3, e.z, tgt.x, 2, tgt.z, 170, 230, 255, 0.6, 0.3)
			Combat.hit(run, tgt, proc(15, "item_40"))
		end
	end
end

-- Al recibir daño en la vida
function IE.onPlayerHit(run, attacker, dmg, Combat)
	local t = run.clock.t
	local k = n(run, "item_19")
	if k > 0 then
		Combat.fx(run, "b", run.px, 1.5, run.pz, 8, 120, 200, 255, 0.3)
		for _, v in ipairs(Combat.inRadius(run, run.px, run.pz, 8)) do Combat.hit(run, v, proc(15 * k, "item_19", { lightning = true })) end
	end
	k = n(run, "item_22")
	if k > 0 then run.gold += 2 * k end
	k = n(run, "item_25")
	if k > 0 and t >= (run.mirrorAt or 0) then
		run.mirrorAt = t + 8 / k
		run.invulnUntil = math.max(run.invulnUntil, t + 1)
		Combat.fx(run, "b", run.px, 2, run.pz, 3, 230, 240, 255, 0.4)
	end
	k = n(run, "item_48")
	if k > 0 then
		Combat.fx(run, "z", run.px, 0.3, run.pz, 7, 110, 220, 90, 1.2)
		for _, v in ipairs(Combat.inRadius(run, run.px, run.pz, 7)) do Combat.applyPoison(run, v, 4 * k, "item_48") end
	end
end

-- Za Warudo: evita la muerte una vez por run
function IE.preventDeath(run, Combat)
	-- una vida extra por copia
	if (run.zaUsed or 0) >= n(run, "item_33") then return false end
	run.zaUsed = (run.zaUsed or 0) + 1
	run.hp = math.max(1, run.stats:get("maxHp") * 0.3)
	run.invulnUntil = run.clock.t + 2
	for _, e in pairs(run.enemies) do if not e.dead then Combat.applyFreeze(run, e, 2) end end
	Combat.fx(run, "b", run.px, 2, run.pz, 30, 255, 230, 120, 0.8)
	run.send("Toast", { text = "¡ZA WARUDO! El tiempo se detiene…" })
	return true
end

-- Al abrir un cofre: devuelve true si fue gratis (Llave)
function IE.onChestOpen(run, cost)
	local st = run.stats
	run.chestsOpened = (run.chestsOpened or 0) + 1
	local k = n(run, "item_17")
	if k > 0 then st:addModifier("item_greencard_" .. run.chestsOpened, "item_17", "luck", "flat", 0.02 * k) end
	k = n(run, "item_18")
	if k > 0 then st:addModifier("item_redcard_" .. run.chestsOpened, "item_18", "damageMultiplier", "flat", 0.025 * k) end
	k = n(run, "item_38")
	if k > 0 and cost > 0 and run.rng.passives:chance(math.min(1, 0.10 * k)) then
		run.gold += cost
		run.send("Toast", { text = "¡La Llave abrió el cofre gratis!" })
		return true
	end
	return false
end

-- Paso por tick
function IE.step(run, dt, Combat)
	local t = run.clock.t
	local moving = (run.moveDelta or 0) > 0.05
	run.idleT = moving and 0 or ((run.idleT or 0) + dt)
	local k = n(run, "item_15")
	if k > 0 and run.idleT > 0.5 then Combat.heal(run, 3 * k * dt) end
	k = n(run, "item_36")
	if k > 0 and t >= (run.dollAt or 0) then
		run.dollAt = t + 3
		local e = Combat.nearest(run, run.px, run.pz, 25)
		if e then
			Combat.fx(run, "t", run.px, 3, run.pz, e.x, 2, e.z, 140, 40, 160, 0.5, 0.3)
			Combat.hit(run, e, proc(e.maxHp * (e.boss and 0.01 or 0.10) * k, "item_36"))
		end
	end
	k = n(run, "item_42")
	if k > 0 and t >= (run.magnetItemAt or 20 / k) then
		run.magnetItemAt = t + 20 / k
		run.magnetUntil = t + 1.5
	end
	k = n(run, "item_52")
	if k > 0 then
		run.sneakAcc = (run.sneakAcc or 0) + (run.moveDelta or 0)
		while run.sneakAcc >= 40 do run.sneakAcc -= 40; run.gold += k end
	end
	k = n(run, "item_56")
	if k > 0 and run.tickN % 5 == 0 then
		if moving ~= run.skatesOn then
			run.skatesOn = moving
			if moving then run.stats:addModifier("item_skates", "item_56_live", "attackSpeedMultiplier", "flat", 0.20 * k)
			else run.stats:removeSource("item_56_live") end
		end
	end
end

return IE
