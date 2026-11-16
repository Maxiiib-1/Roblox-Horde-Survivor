--!nonstrict
-- Tests/DevTools: SOLO Studio. Expone un BindableFunction en ServerStorage (no replicado al cliente).
-- Ningún cliente puede invocarlo. Sirve para forzar XP, jefe, oro, inspeccionar estado y ejecutar pruebas.
local RunServiceRbx = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local DevTools = {}

function DevTools.install(RunService, Offers, Combat)
	if not RunServiceRbx:IsStudio() then return end
	if ServerStorage:FindFirstChild("DevTools") then return end
	local bf = Instance.new("BindableFunction")
	bf.Name = "DevTools"
	bf.Parent = ServerStorage
	bf.OnInvoke = function(cmd, a, b, c)
		local player = Players:GetPlayers()[1]
		if not player then return "sin jugador" end
		local run = RunService.get(player)
		if cmd == "state" then
			if not run then return { run = false } end
			local ws, ts = {}, {}
			for _, w in ipairs(run.weapons) do ws[#ws + 1] = w.id .. ":" .. w.level end
			for id, t in pairs(run.tomes) do ts[#ts + 1] = id .. ":" .. t.level end
			return { run = true, id = run.id, state = run.state, phase = run.phase, stage = run.stage, t = run.clock.t, hp = run.hp, maxHp = run.stats:get("maxHp"),
				level = run.level, kills = run.kills, gold = run.gold, enemies = run.enemyCount, proj = #run.projectiles, zones = #run.zones, loot = run.lootCount,
				offer = run.activeOffer and run.activeOffer.kind, queue = #run.offerQueue, weapons = ws, tomes = ts, paused = run.paused, boss = run.boss and math.floor(run.boss.hp) }
		elseif cmd == "stageTime" then -- stageTime(s): adelanta el reloj de la etapa (probar la súper horda)
			if run then local d = (a or 595) - run.clock.stageT; run.clock.stageT += d; run.clock.total += d end
			return true
		elseif cmd == "die" then -- die(): mata al jugador (probar animación de muerte y pantalla final)
			if run then run.invulnUntil = 0; run.hp = 0; RunService.die(run, "hp") end
			return true
		elseif cmd == "slideInfo" then
			return run and { sliding = run.slideUntil and run.slideUntil > run.clock.t or false, readyAt = run.slideReadyAt, t = run.clock.t } or false
		elseif cmd == "god" then
			if run then run.invulnUntil = math.huge end
			return true
		elseif cmd == "xp" then
			if run then RunService.pickup(run, { kind = "xp", value = a or 10 }) end
			return true
		elseif cmd == "gold" then
			if run then run.gold += a or 100 end
			return true
		elseif cmd == "boss" then
			if run then RunService.startBoss(run) end
			return true
		elseif cmd == "silver" then -- silver(n): da plata al perfil de memoria (solo Studio, para probar la tienda)
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			local rec = Profile.get(player); if not rec then return false end
			rec.data.silver += math.clamp(tonumber(a) or 0, -100000, 100000)
			local rem = game.ReplicatedStorage.GameShared.Network:FindFirstChild("Remotes")
			if rem and rem:FindFirstChild("ProfileData") then rem.ProfileData:FireClient(player, Profile.publicData(player)) end
			return rec.data.silver
		elseif cmd == "progress" then -- progress(mapId, n): fija niveles superados (solo Studio)
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			local rec = Profile.get(player); if not rec then return false end
			rec.data.mapProgress[a] = math.clamp(tonumber(b) or 0, 0, 3)
			return rec.data.mapProgress
		elseif cmd == "calm" then -- calm(): sin enemigos ni ofertas pendientes (probar movimiento)
			if not run then return false end
			run.devNoSpawn = true
			Combat.clearEnemies(run)
			run.offerQueue = {}
			return true
		elseif cmd == "unlock" then -- unlock(classId): desbloquea un personaje en el perfil de memoria (solo Studio)
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			local rec = Profile.get(player); if not rec then return false end
			rec.data.unlockedClasses[a] = true
			return true
		elseif cmd == "lockClass" then -- lockClass(classId): saca el personaje y su arma propia del perfil de memoria (solo Studio, para probar el desbloqueo)
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			local SR = require(game.ReplicatedStorage.GameShared.Util.ShopRotation)
			local rec = Profile.get(player); if not rec then return false end
			rec.data.unlockedClasses[a] = nil
			local w = SR.classWeapon[a]; if w then rec.data.ownedWeapons[w] = nil end
			Profile.markDirty(player)
			return w or true
		elseif cmd == "buy" then -- buy(id): compra en la tienda por la vía normal del perfil (solo Studio)
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			return Profile.purchase(player, a, "dev_" .. tostring(os.clock()), workspace:GetServerTimeNow())
		elseif cmd == "mapObjects" then -- mapObjects(): cuántos objetos generó la etapa por tipo, fallas del colocador y chequeo de límites/encimados
			if not run then return false end
			local map = run.map
			local OCfg = require(game.ReplicatedStorage.GameShared.Config.MapObjectsConfig)
			local counts, out, overlap, near = {}, 0, 0, 0
			local pts = {}
			for _, it in ipairs(map.items) do
				local key = it.kind .. ((it.kind == "chest" and it.origin == "reward") and "(recompensa)" or "")
				counts[key] = (counts[key] or 0) + 1
				if math.abs(it.x) > map.half or math.abs(it.z) > map.half then out += 1 end
				pts[#pts + 1] = it
			end
			counts.vase = 0
			for _, v in ipairs(map.vases or {}) do counts.vase += 1; counts["vase_" .. (v.variant or "?")] = (counts["vase_" .. (v.variant or "?")] or 0) + 1; if math.abs(v.x) > map.half or math.abs(v.z) > map.half then out += 1 end; pts[#pts + 1] = v end
			local minImp = math.huge
			for i = 1, #pts do for j = i + 1, #pts do
				local a, b2 = pts[i], pts[j]
				local d2 = math.sqrt((a.x - b2.x) ^ 2 + (a.z - b2.z) ^ 2)
				if d2 < 3 then overlap += 1 end
				if a.kind and b2.kind and OCfg.category[a.kind] == "important" and OCfg.category[b2.kind] == "important" and d2 < minImp then minImp = d2 end
			end end
			local minSpawn = math.huge
			for _, p in ipairs(pts) do local d0 = math.sqrt(p.x ^ 2 + p.z ^ 2); if d0 < minSpawn then minSpawn = d0 end end
			return { counts = counts, outside = out, overlaps = overlap, minImportantDist = math.floor(minImp), minSpawnDist = math.floor(minSpawn), fails = map.placeFails, half = map.half }
		elseif cmd == "encounter" then -- encounter(i): adelanta el reloj de la etapa hasta el encuentro i (solo Studio)
			if not run then return false end
			local OCfg = require(game.ReplicatedStorage.GameShared.Config.MapObjectsConfig)
			local enc = OCfg.encounters[tonumber(a) or 1]
			if not enc then return false end
			run.world.clock.stageT = require(game.ReplicatedStorage.GameShared.Config.GameConfig).stage.maxSeconds - enc.remaining + 0.1
			return run.world.clock.stageT
		elseif cmd == "fireTest" then		elseif cmd == "fireTest" then -- fireTest(seconds): proyectiles disparados por arma en ese lapso (solo Studio)
			if not run then return false end
			local seen, per = {}, {}
			for _, p in ipairs(run.projectiles) do seen[p] = true end
			local t0 = os.clock()
			local angles = {}
			while os.clock() - t0 < (tonumber(a) or 3) do
				for _, p in ipairs(run.projectiles) do
					if not seen[p] then
						seen[p] = true
						per[p.weaponId] = (per[p.weaponId] or 0) + 1
						angles[#angles + 1] = math.floor(math.deg(math.atan2(p.dz or 0, p.dx or 0)))
					end
				end
				task.wait()
			end
			local Behaviors = require(script.Parent.Parent.Weapons.Behaviors)
			local info = {}
			for _, w in ipairs(run.weapons) do local ps = Behaviors.derive(run, w); info[#info + 1] = ("%s count=%s cd=%.2f"):format(w.id, tostring(ps.count), ps.cd) end
			return { per = per, weapons = info, angles = table.concat(angles, ",") }
		elseif cmd == "stats" then -- stats("a,b,c"): valores actuales de esos stats en la partida (solo Studio)
			if not run then return false end
			local out = {}
			for k in string.gmatch(a or "", "[%w_]+") do out[k] = run.stats:get(k) end
			out._hp = run.hp; out._pets = run.petIds
			return out
		elseif cmd == "wup" then -- wup(key, value): aplica una mejora concreta a todas tus armas y devuelve el resultado (solo Studio)
			if not run then return false end
			local Behaviors = require(script.Parent.Parent.Weapons.Behaviors)
			local out = {}
			for _, w in ipairs(run.weapons) do
				Behaviors.applyUpgrade(w, { { key = a, value = tonumber(b) or 1 } })
				local ps = Behaviors.derive(run, w)
				out[#out + 1] = ("%s up.%s=%s count=%s"):format(w.id, tostring(a), tostring(w.up[a]), tostring(ps.count))
			end
			return table.concat(out, " | ")
		elseif cmd == "bosses" then -- bosses(): jefes de la etapa (principal + extras)
			if not run then return false end
			local BD = require(script.Parent.Parent.Bosses.BossDirector)
			local out = {}
			for _, e in ipairs(BD.list(run.world)) do out[#out + 1] = { name = e.bossName, hp = math.floor(e.hp), max = e.maxHp, dead = e.dead, extra = e.extra or false, x = math.floor(e.x), z = math.floor(e.z) } end
			local ev = {}
			for _, e in ipairs(run.world.eventBosses or {}) do ev[#ev + 1] = { name = e.bossName, hp = math.floor(e.hp), max = e.maxHp, dead = e.dead, extra = e.extra or false, enc = e.encounter, chests = e.rewardChests } end
			return { list = out, events = ev, encDone = run.world.encDone, hud = BD.hudInfo(run.world), bloody = run.world.bloody, phase = run.world.phase, cleared = run.world.clearedStage }
		elseif cmd == "killOneBoss" then -- killOneBoss(): mata al primer jefe vivo (solo Studio)
			if not run then return false end
			local BD = require(script.Parent.Parent.Bosses.BossDirector)
			for _, e in ipairs(BD.list(run.world)) do if not e.dead then Combat.kill(run, e, {}); return e.bossName .. (e.extra and " (extra)" or "") end end
			for _, e in ipairs(run.world.eventBosses or {}) do if not e.dead then Combat.kill(run, e, {}); return e.bossName .. " (encuentro)" end end
			return "ninguno"
		elseif cmd == "profile" then
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			return Profile.publicData(player)
		elseif cmd == "spawn" then -- spawn(kind, n): aparece n enemigos en anillo (prueba de rendimiento)
			if not run then return false end
			local n = math.clamp(tonumber(b) or 10, 1, 200)
			local t0 = os.clock()
			for i = 1, n do
				local ang = i / n * math.pi * 2
				Combat.spawnEnemy(run, a or "chaser", run.px + math.cos(ang) * 40, run.pz + math.sin(ang) * 40)
			end
			return { ms = (os.clock() - t0) * 1000, enemies = run.enemyCount }
		elseif cmd == "powerup" then -- powerup(kind): deja un potenciador (heal/magnet/bomb/freeze) a 2 studs del jugador (solo Studio)
			if not run then return false end
			Combat.addLoot(run, a or "heal", run.px + 2, run.pz, 1)
			return true
		elseif cmd == "testStats" then -- testStats(): aplica cada tomo y 10 subidas de nivel y compara con lo esperado (solo Studio)
			if not run then return false end
			local Tomes = require(game.ReplicatedStorage.GameShared.Catalogs.Tomes)
			local GC = require(game.ReplicatedStorage.GameShared.Config.GameConfig)
			local Behaviors = require(script.Parent.Parent.Weapons.Behaviors)
			local st = run.stats
			local res = {}
			local function chk(name, ok, detail) res[#res + 1] = (ok and "OK  " or "FAIL ") .. name .. (detail and (" · " .. detail) or "") end
			-- armas antes
			local before = {}
			for _, w in ipairs(run.weapons) do before[w.id] = Behaviors.derive(run, w) end
			for _, d in ipairs(Tomes.list) do
				if d.stat then
					local b0 = st:get(d.stat); local u0 = st:getUncapped(d.stat); local hp0 = run.hp
					Offers.applyChoice(run, nil, { type = "tome", itemId = d.id, mag = 1.2 })
					local delta = st:getUncapped(d.stat) - u0
					local exp = d.value * 1.2
					chk(d.name .. " (" .. d.stat .. ")", math.abs(delta - exp) < 1e-6, string.format("%.3f ? %.3f (+%.3f, esperado +%.3f)", b0, st:get(d.stat), delta, exp))
					if d.healWithMax then chk("  cura al subir vida máx.", run.hp - hp0 > 0, string.format("hp +%.1f", run.hp - hp0)) end
				end
			end
			for _, w in ipairs(run.weapons) do
				local a, b2 = before[w.id], Behaviors.derive(run, w)
				local parts = {}
				for k, v in pairs(b2) do if type(v) == "number" and a[k] ~= v then parts[#parts + 1] = string.format("%s %.2f?%.2f", k, a[k], v) end end
				table.sort(parts)
				res[#res + 1] = "ARMA " .. w.id .. " (" .. w.def.usefulStats .. "): " .. table.concat(parts, ", ")
				local d1 = Behaviors.derive(run, w).dmg
				local saved = w.up and table.clone(w.up) or {}
				-- las mejoras de daño se SUMAN: con +u previo, +0,18 pasa de (1+u) a (1+u+0,18) (auditoría 2026-11-06)
				local u0 = (w.up and w.up.dmg) or 0
				Behaviors.applyUpgrade(w, { { key = "dmg", value = 0.18 } })
				local d2 = Behaviors.derive(run, w).dmg
				w.up = saved
				local expR = (1 + u0 + 0.18) / (1 + u0)
				chk("  mejora de daño del arma (+18% sumado)", math.abs(d2 / d1 - expR) < 1e-6, string.format("%.2f ? %.2f (esperado ×%.3f)", d1, d2, expR))
			end
			-- subidas de nivel del personaje
			local mh0, lv0 = st:get("maxHp"), run.level
			local need = 0
			local Stats = require(game.ReplicatedStorage.GameShared.Util.Stats)
			for i = 0, 9 do need += Stats.xpForLevel(run.level + i) end
			run.xpAcc = 0
			RunService.pickup(run, { kind = "xp", value = need / st:get("xpMultiplier") + 0.5 })
			local gained = run.level - lv0
			chk("10 subidas de nivel con XP exacta", gained == 10, "subió " .. gained)
			chk("vida máx. por nivel", st:get("maxHp") - mh0 >= GC.hpPerLevel * gained - 1e-6, string.format("+%.1f (base %.1f/nivel)", st:get("maxHp") - mh0, GC.hpPerLevel))
			res[#res + 1] = "ofertas en cola: " .. #run.offerQueue .. " · pasiva " .. tostring(run.classDef.passiveId)
			return table.concat(res, "\n")
		elseif cmd == "enemyDist" then -- enemyDist(): distancia (min/media/max) de los enemigos al jugador y su dirección de marcha (solo Studio)
			if not run then return false end
			local ds, ahead, n = {}, 0, 0
			local mx, mz = rawget(run, "_mvX") or 0, rawget(run, "_mvZ") or 0
			local ms = math.sqrt(mx * mx + mz * mz)
			for _, e in pairs(run.enemies) do
				if not e.dead and not e.boss then
					local dx, dz = e.x - run.px, e.z - run.pz
					local d = math.sqrt(dx * dx + dz * dz)
					ds[#ds + 1] = d; n += 1
					if ms > 1 and d > 0 and (dx * mx + dz * mz) / (d * ms) > 0.4 then ahead += 1 end
				end
			end
			table.sort(ds)
			local sum = 0; for _, d in ipairs(ds) do sum += d end
			return { n = n, min = ds[1], max = ds[#ds], avg = n > 0 and sum / n or 0, ahead = ahead, moveSpeed = ms, far = require(game.ReplicatedStorage.GameShared.Config.GameConfig).director.far }
		elseif cmd == "frozen" then -- frozen(): cuántos enemigos están congelados/aturdidos ahora (solo Studio)
			if not run then return false end
			local n, tot = 0, 0
			for _, e in pairs(run.enemies) do tot += 1; if e.status.frozenUntil and e.status.frozenUntil > run.clock.t then n += 1 end end
			return { frozen = n, total = tot, t = run.clock.t }
		elseif cmd == "weaponLevel" then -- weaponLevel(n): pone todas tus armas en nivel n (solo Studio)
			if not run then return false end
			local Behaviors = require(script.Parent.Parent.Weapons.Behaviors)
			local out = {}
			for _, w in ipairs(run.weapons) do w.level = a or 50; local ps = Behaviors.derive(run, w); out[#out + 1] = string.format("%s L%d dmg %.1f cd %.2f n %d size %.2f", w.id, w.level, ps.dmg, ps.cd, ps.count, ps.size) end
			return table.concat(out, " | ")
		elseif cmd == "testProg" then -- testProg(): pruebas del sistema de progresión estilo MegaBonk en la partida actual (solo Studio)
			if not run then return false end
			local GC = require(game.ReplicatedStorage.GameShared.Config.GameConfig)
			local DCfg = require(game.ReplicatedStorage.GameShared.Config.DifficultyConfig)
			local StatsU = require(game.ReplicatedStorage.GameShared.Util.Stats)
			local Behaviors = require(script.Parent.Parent.Weapons.Behaviors)
			local SD = require(script.Parent.Parent.Services.SpawnDirector)
			local Rng = require(game.ReplicatedStorage.GameShared.Util.SeededRandom)
			local st = run.stats
			local res, pass, total = {}, 0, 0
			local function chk(name, ok, detail) total += 1; if ok then pass += 1 end; res[#res + 1] = (ok and "OK   " or "FAIL ") .. name .. (detail and (" · " .. detail) or "") end
			local function setMod(id, stat, v) st:addModifier(id, "test", stat, "flat", v) end
			-- 1) niveles y XP sobrante
			run.xpAcc = 0; run.xp = 0
			local lv0 = run.level
			local need = StatsU.xpForLevel(run.level)
			RunService.pickup(run, { kind = "xp", value = (need + 7) / st:get("xpMultiplier") + 1e-6 })
			chk("Sube 1 nivel y conserva la XP sobrante", run.level == lv0 + 1 and run.xp == 7, ("nivel %d?%d, xp sobrante %d (esperado 7)"):format(lv0, run.level, run.xp))
			chk("XP necesaria crece con el nivel", StatsU.xpForLevel(10) > StatsU.xpForLevel(5) and StatsU.xpForLevel(50) > StatsU.xpForLevel(10), ("nv5 %d · nv10 %d · nv50 %d"):format(StatsU.xpForLevel(5), StatsU.xpForLevel(10), StatsU.xpForLevel(50)))
			-- 2) mejoras de arma
			local w = run.weapons[1]
			if w then
				local rng = Rng.new(12345)
				local okCompat, legDmg, legCount, n2 = true, nil, nil, 0
				for i = 1, 300 do
					local mag = GC.rarity.magnitude[(i % 5) + 1]
					local list = Behaviors.rollUpgrade(w, mag, rng)
					if #list == 2 then n2 += 1 end
					for _, x in ipairs(list) do
						local e
						for _, c in ipairs(GC.weaponUpgrades.list) do if c.key == x.key then e = c end end
						local compat = false
						for ch in e.letters:gmatch(".") do if w.useful[ch] then compat = true end end
						if not compat then okCompat = false end
						if mag == 2 and x.key == "dmg" then legDmg = x.value end
						if mag == 2 and x.key == "count" then legCount = x.value end
					end
				end
				chk("Mejoras: solo atributos compatibles con el arma (" .. w.def.usefulStats .. ")", okCompat)
				chk("Mejoras: 1 o 2 atributos (~40% trae 2)", n2 > 60 and n2 < 180, n2 .. "/300 con 2")
				chk("Legendaria: daño +36% (0,18 × 2)", legDmg == nil or math.abs(legDmg - 0.36) < 1e-9, tostring(legDmg))
				chk("Legendaria: +2 proyectiles", legCount == nil or legCount == 2, tostring(legCount))
				local d0 = Behaviors.derive(run, w)
				local lvW = w.level
				Offers.applyChoice(run, nil, { type = "weapon", itemId = w.id, wup = { { key = "dmg", value = 0.5 }, { key = "atk", value = 0.25 } } })
				local d1 = Behaviors.derive(run, w)
				chk("Aplicar mejora: +1 nivel, daño ×1,5 y cadencia ×1,25", w.level == lvW + 1 and math.abs(d1.dmg / d0.dmg - 1.5) < 1e-6 and (not w.useful.A or math.abs(d0.cd / d1.cd - 1.25) < 1e-6), ("nv %d?%d · daño %.1f?%.1f · cd %.3f?%.3f"):format(lvW, w.level, d0.dmg, d1.dmg, d0.cd, d1.cd))
				Behaviors.applyUpgrade(w, { { key = "atk", value = 99 } })
				chk("Tope de cadencia por arma (" .. GC.weaponUpgrades.caps.atk .. ")", w.up.atk == GC.weaponUpgrades.caps.atk, tostring(w.up.atk))
				w.up.atk = 0.25
				w.level = math.max(1, lvW)
				chk("Tope de nivel de arma 40 y tomos 99", GC.progression.maxItemLevel == 40 and GC.progression.maxTomeLevel == 99)
			end
			-- 3) multiplicador de daño: golpe sin crítico a un enemigo de prueba
			setMod("t_dmg", "damageMultiplier", 1)
			local e = Combat.spawnEnemy(run, "chaser", run.px + 30, run.pz + 30)
			if e then
				e.hp = 1e6; e.maxHp = 1e6
				local mul = st:get("damageMultiplier")
				local h0 = e.hp
				Combat.hit(run, e, { amount = 10, tags = {}, canCrit = false, noLifesteal = true, noProcs = true, depth = 1 })
				local dealt = h0 - e.hp
				chk("Daño global se aplica una sola vez", math.abs(dealt - 10 * mul) < 0.01, ("10 × %.2f = %.2f (hecho %.2f)"):format(mul, 10 * mul, dealt))
				e.hp = 0; Combat.kill(run, e, { noProcs = true, noExplode = true })
			end
			setMod("t_dmg", "damageMultiplier", 0)
			-- 4) armadura
			local inv, ev, sh = run.invulnUntil, nil, run.shield
			run.invulnUntil = 0; run.shield = 0
			setMod("t_ev", "evasionChance", -5)
			setMod("t_arm", "armorReduction", 0.5 - st:get("armorReduction"))
			local arm = st:get("armorReduction")
			run.hp = 1000
			Combat.damagePlayer(run, 40, nil)
			local lost = 1000 - run.hp
			chk("Armadura reduce el daño", math.abs(lost - 40 * (1 - arm)) < 0.6, ("40 × (1 - %.2f) = %.1f (recibido %.1f)"):format(arm, 40 * (1 - arm), lost))
			setMod("t_arm", "armorReduction", 0); setMod("t_ev", "evasionChance", 0)
			run.invulnUntil = inv; run.shield = sh; run.hp = st:get("maxHp")
			-- 5) escalado de enemigos: solo tiempo + dificultad (no tu nivel)
			local saveLv, saveT = run.level, run.clock.stageT
			run.level = 0; local _, hA, dA = Combat.archetypeScale(run, "chaser")
			run.level = 60; local _, hB, dB = Combat.archetypeScale(run, "chaser")
			chk("Tu nivel NO cambia a los enemigos", math.abs(hA - hB) < 1e-9 and math.abs(dA - dB) < 1e-9, ("vida ×%.2f / ×%.2f"):format(hA, hB))
			run.clock.stageT = 0; local _, h0t, d0t = Combat.archetypeScale(run, "chaser")
			run.clock.stageT = 600; local _, h10, d10 = Combat.archetypeScale(run, "chaser")
			chk("El tiempo sí los hace más fuertes", h10 > h0t and d10 > d0t, ("min 0: vida ×%.2f daño ×%.2f · min 10: vida ×%.2f daño ×%.2f"):format(h0t, d0t, h10, d10))
			run.clock.stageT = 120
			local _, hD0 = Combat.archetypeScale(run, "chaser")
			setMod("t_diff", "difficulty", 1)
			local _, hD1 = Combat.archetypeScale(run, "chaser")
			chk("La dificultad sube la vida de los enemigos", hD1 > hD0, ("×%.2f ? ×%.2f"):format(hD0, hD1))
			-- 6) dificultad vs aparición y XP por enemigo
			local ctx0 = { difficulty = 0, stageT = 120, players = 1, statues = 0 }
			local ctx1 = { difficulty = 1, stageT = 120, players = 1, statues = 0 }
			local ds = SD.newState()
			local c0 = SD.creditsPerSecond(run.world or run, ctx0, ds, 0, 300)
			local c1 = SD.creditsPerSecond(run.world or run, ctx1, ds, 0, 300)
			chk("Más dificultad = más enemigos por segundo", c1 > c0, ("%.2f ? %.2f créditos/s"):format(c0, c1))
			setMod("t_diff", "difficulty", 0)
			local eA = Combat.spawnEnemy(run, "chaser", run.px + 40, run.pz)
			setMod("t_diff", "difficulty", 1)
			local eB = Combat.spawnEnemy(run, "chaser", run.px - 40, run.pz)
			setMod("t_diff", "difficulty", 0)
			if eA and eB then
				chk("La dificultad NO sube la XP de cada enemigo", eA.xp == eB.xp, ("xp %s / %s"):format(tostring(eA.xp), tostring(eB.xp)))
				for _, x in ipairs({ eA, eB }) do x.hp = 0; Combat.kill(run, x, { noProcs = true, noExplode = true }) end
			end
			run.level, run.clock.stageT = saveLv, saveT
			-- 7) rarezas
			chk("5 rarezas con 1 / 1,2 / 1,4 / 1,6 / 2", #GC.rarity.order == 5 and table.concat(GC.rarity.magnitude, ",") == "1,1.2,1.4,1.6,2")
			return ("%d/%d\n"):format(pass, total) .. table.concat(res, "\n")
		elseif cmd == "useKind" then -- useKind(kind): te lleva al primer interactuable de ese tipo y lo usa (solo Studio)
			if not run then return false end
			local target
			for _, it in ipairs(run.map.items) do if it.kind == a and not it.used then target = it break end end
			if not target then return "no hay " .. tostring(a) end
			local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if hrp then hrp.CFrame = CFrame.new(run.origin + Vector3.new(target.x + 4, run.map.height(target.x + 4, target.z) + 4, target.z)); run.px, run.pz = target.x + 4, target.z end
			task.wait(0.3)
			local ok, err = RunService.interact(run, target.id)
			return { ok = ok, err = err, id = target.id, tier = target.tier, golden = target.golden, offer = run.activeOffer and run.activeOffer.kind, opts = run.activeOffer and #run.activeOffer.options }
		elseif cmd == "kinds" then -- kinds(): cuántos interactuables hay de cada tipo (solo Studio)
			if not run then return false end
			local c = {}
			for _, it in ipairs(run.map.items) do local k = it.kind .. (it.golden and "(dorado)" or "") .. (it.tier and ("[t" .. it.tier .. "]") or ""); c[k] = (c[k] or 0) + 1 end
			return c
		elseif cmd == "offerInfo" then
			if not run or not run.activeOffer then return false end
			local o = run.activeOffer
			local t = {}
			for _, x in ipairs(o.options) do t[#t + 1] = (x.name or "?") .. " [" .. tostring(x.rarity) .. "] " .. tostring(x.price or "") .. " · " .. tostring(x.desc):gsub("\n", " / "):sub(1, 90) end
			return o.kind .. " · " .. tostring(o.title) .. "\n" .. table.concat(t, "\n")
		elseif cmd == "lootAt" then -- lootAt(kind, dx, value): deja un recogible a dx studs al este del jugador (solo Studio)
			if not run then return false end
			Combat.addLoot(run, a or "xp", run.px + (b or 8), run.pz, c or 5)
			return true
		elseif cmd == "lootInfo" then -- lootInfo(): recogibles vivos con distancia al jugador
			if not run then return false end
			local out = {}
			for _, l in pairs(run.loot) do out[#out + 1] = l.kind .. "@" .. math.floor(math.sqrt((l.x - run.px) ^ 2 + (l.z - run.pz) ^ 2) * 10) / 10 end
			return { list = out, xp = run.xp, level = run.level, hp = run.hp, px = run.px, pz = run.pz }
		elseif cmd == "worldInfo" then -- worldInfo(): datos para probar potenciadores, cofres y minijefes
			if not run then return false end
			local xp, frozen, chests = 0, 0, 0
			for _, l in pairs(run.loot) do if l.kind == "xp" then xp += 1 end end
			for _, it in ipairs(run.map.items) do if it.dropped then chests += 1 end end
			local ws = run.world or run
			return { xpLoot = xp, enemies = run.enemyCount, timeStop = math.max(0, (ws.timeStopUntil or 0) - run.clock.t), dropChests = chests, hp = run.hp, maxHp = run.stats:get("maxHp"), magnet = math.max(0, (run.magnetUntil or 0) - run.clock.t) }
		elseif cmd == "testMini" then -- testMini(): crea un minijefe al lado y lo mata (debe dejar un cofre)
			if not run then return false end
			local e = Combat.spawnEnemy(run, "brute", run.px + 6, run.pz, { elite = true, miniboss = true, hpMul = 10, sizeMul = 1.7, xpMul = 15 })
			Combat.kill(run, e, { weaponId = "test", tags = {} })
			return true
		elseif cmd == "spawnMini" then -- spawnMini(d): crea un minijefe a d studs (no lo mata); devuelve su radio
			if not run then return false end
			local e = Combat.spawnEnemy(run, "brute", run.px + (tonumber(a) or 10), run.pz, { elite = true, miniboss = true, hpMul = 10, sizeMul = 1.7, xpMul = 15, dmgMul = 1.6 })
			e.speed = 0
			return { radius = e.radius, dmg = e.dmg, x = e.x, z = e.z }
		elseif cmd == "testBomber" then -- testBomber(d): crea un Bombardino a d studs y lo mata (debe explotar igual)
			if not run then return false end
			local e = Combat.spawnEnemy(run, "bomber", run.px + (tonumber(a) or 3), run.pz)
			local before = run.hp
			run.invulnUntil = 0
			Combat.kill(run, e, { weaponId = "test", tags = {} })
			return { before = before, after = run.hp, dmg = e.dmg }
		elseif cmd == "killboss" then
			if run and run.boss and not run.boss.dead then Combat.kill(run, run.boss, {}) end
			return true
		elseif cmd == "choose" then
			if run and run.activeOffer then return Offers.choose(run, run.activeOffer.id, a or "o1") end
			return false
		elseif cmd == "action" then
			if run and run.activeOffer then return Offers.action(run, run.activeOffer.id, a, b) end
			return false
		elseif cmd == "offer" then
			if run and run.activeOffer then
				local o = {}
				for _, x in ipairs(run.activeOffer.options) do o[#o + 1] = (x.itemId or x.type) .. "/" .. tostring(x.rarity) end
				return { kind = run.activeOffer.kind, options = o, rerolls = run.rerolls, gold = run.gold }
			end
			return false
		elseif cmd == "interactKind" then
			-- teletransporta al jugador junto al primer interactuable del tipo y lo activa por la vía normal
			if not run then return false end
			for _, it in ipairs(run.map.items) do
				if it.kind == a and not it.used then
					local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
					if hrp then hrp.CFrame = CFrame.new(run.origin + Vector3.new(it.x + 4, 4 + run.map.height(it.x + 4, it.z), it.z)) end
					task.wait(0.3)
					return RunService.interact(run, it.id)
				end
			end
			return false, "none"
		elseif cmd == "addItem" then -- addItem(id, n): da copias de un objeto en la run actual (solo Studio)
			if not run then return false end
			local IE = require(script.Parent.Parent.Items.ItemEffects)
			run.items[a] = (run.items[a] or 0) + (b or 1)
			IE.applyStats(run, a)
			return run.items[a]
		elseif cmd == "addWeapon" then
			if run then return require(script.Parent.Parent.Weapons.Behaviors).addWeapon(run, a) ~= nil end
		elseif cmd == "testPure" then
			return require(script.Parent.TestRunner).pure()
		elseif cmd == "testWeapons" then
			if not run then return false end
			run.pause(run, "test") -- congela el bucle normal; el test avanza su propio reloj
			local ok, res = pcall(require(script.Parent.TestRunner).weapons, run, Combat, require(script.Parent.Parent.Weapons.Behaviors))
			run.resume(run, "test")
			return ok and res or tostring(res)
		elseif cmd == "start" then
			local r, err = RunService.start(player, a or "class_01", b or "forest", c or 1)
			return r ~= nil, err
		elseif cmd == "bossInfo" then -- bossInfo(): jefe actual, vida/daño escalados, fase, ataques en curso, jugadores con noche
			if not run then return false end
			return require(script.Parent.Parent.Bosses.BossDirector).debugInfo(run.world)
		elseif cmd == "bossAttack" then -- bossAttack(id): fuerza un ataque del jefe actual
			if not run then return false end
			return require(script.Parent.Parent.Bosses.BossDirector).forceAttack(run.world, run, a)
		elseif cmd == "bossHp" then -- bossHp(frac): deja al jefe con esa fracción de vida (probar la fase final)
			if not run or not run.world.boss then return false end
			run.world.boss.hp = run.world.boss.maxHp * (a or 0.49)
			return run.world.boss.hp
		elseif cmd == "hordeInfo" then -- hordeInfo(): estado de la súper oleada y daño medio de los enemigos vivos
			if not run then return false end
			local w = run.world
			local sum, n = 0, 0
			for _, e in pairs(w.enemies) do if not e.boss and not e.dead then sum += e.dmg; n += 1 end end
			return { active = w.superHorde ~= nil, reason = w.superHorde and w.superHorde.reason, since = w.superHorde and (w.clock.t - w.superHorde.start) or 0,
				stage = w.stage, stageT = w.clock.stageT, phase = w.phase, enemies = w.enemyCount, avgDmg = n > 0 and sum / n or 0, hordeStart = w.hordeStart }
		elseif cmd == "lb" then -- lb(scope): tabla de clasificación tal como la recibe el menú
			local LB = require(script.Parent.Parent.Services.LeaderboardService)
			return a == "friends" and LB.friends(player) or LB.top()
		elseif cmd == "mortal" then -- mortal(hp): quita el modo dios y fija la vida (probar daño de habilidades)
			if not run then return false end
			run.invulnUntil = 0
			if a then run.hp = a end
			return run.hp
		elseif cmd == "setLevel" then -- setLevel(n): fija el nivel de la partida (probar el escalado del jefe)
			if not run then return false end
			run.level = math.max(1, tonumber(a) or 1)
			return run.level
		elseif cmd == "mapStats" then -- mapStats(): piezas, obstáculos, tiempo de generación y lugares del mapa actual
			if not run then return false end
			local lms = {}
			for _, l in ipairs(run.map.landmarks or {}) do lms[#lms + 1] = l.kind .. "@" .. l.x .. "," .. l.z end
			return { stats = run.map.stats, landmarks = lms, routes = #(run.map.routes or {}), items = #run.map.items, vases = #run.map.vases }
		elseif cmd == "tpLandmark" then -- tpLandmark(i): lleva al jugador al lugar i (1..4)
			if not run then return false end
			local l = run.map.landmarks[a or 1]; if not l then return false end
			local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if hrp then hrp.CFrame = CFrame.new(run.origin + Vector3.new(l.x, run.map.height(l.x, l.z) + 4, l.z)) end
			return l.name
		elseif cmd == "walkRoute" then -- walkRoute(i): camina con el Humanoid por la ruta i (en segundo plano; leer el atributo Walk)
			if not run then return false end
			local pts = run.map.routes[a or 1]; if not pts then return false end
			bf:SetAttribute("Walk", "running")
			task.spawn(function()
				local char = player.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if not hum or not hrp then bf:SetAttribute("Walk", "no char"); return end
				-- arranca 34 studs dentro del camino (no desde adentro de un lugar, p. ej. entre las columnas de las ruinas)
				local p0, p1 = pts[1], pts[2]
				local L0 = math.max(1, math.sqrt((p1[1] - p0[1]) ^ 2 + (p1[2] - p0[2]) ^ 2))
				local k0 = math.min(34, L0 * 0.5) / L0
				local sx, sz = p0[1] + (p1[1] - p0[1]) * k0, p0[2] + (p1[2] - p0[2]) * k0
				pts = table.clone(pts); pts[1] = { sx, sz }
				hrp.CFrame = CFrame.new(run.origin + Vector3.new(sx, run.map.height(sx, sz) + 4, sz))
				task.wait(0.5)
				local t0, stuck, maxClimb, n = os.clock(), 0, 0, 0
				local lastY = hrp.Position.Y
				for k = 2, #pts do
					local ax, az, bx, bz = pts[k - 1][1], pts[k - 1][2], pts[k][1], pts[k][2]
					local L = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
					local steps = math.max(1, math.floor(L / 24))
					for s = 1, steps do
						local x, z = ax + (bx - ax) * s / steps, az + (bz - az) * s / steps
						local goal = run.origin + Vector3.new(x, run.map.height(x, z) + 2, z)
						hum:MoveTo(goal)
						local t1 = os.clock()
						while os.clock() - t1 < 6 do
							task.wait(0.1)
							local p = hrp.Position
							if (Vector3.new(p.X, 0, p.Z) - Vector3.new(goal.X, 0, goal.Z)).Magnitude < 3 then break end
						end
						local p = hrp.Position
						if (Vector3.new(p.X, 0, p.Z) - Vector3.new(goal.X, 0, goal.Z)).Magnitude >= 3 then
							stuck += 1
							hrp.CFrame = CFrame.new(goal + Vector3.new(0, 3, 0)) -- desatasca y sigue (se cuenta como problema)
						end
						maxClimb = math.max(maxClimb, hrp.Position.Y - lastY); lastY = hrp.Position.Y
						n += 1
					end
				end
				bf:SetAttribute("Walk", ("done steps=%d stuck=%d secs=%.1f maxClimbPerStep=%.1f"):format(n, stuck, os.clock() - t0, maxClimb))
			end)
			return true
		elseif cmd == "passive" then -- passive(): estado de la pasiva de clase y daño por fuente (probar pasivas)
			if not run then return false end
			local d = {}
			for k, v in pairs(run.dmgBy or {}) do d[k] = math.floor(v) end
			local c = run.cls or {}
			local fear, frozen, n = 0, 0, 0
			for _, e in pairs(run.enemies) do
				if not e.dead then
					n += 1
					if e.status.fearUntil and e.status.fearUntil > run.clock.t then fear += 1 end
					if e.status.frozenUntil then frozen += 1 end
				end
			end
			return { passive = run.classDef.passiveId, t = run.clock.t, hp = run.hp, maxHp = run.stats:get("maxHp"), level = run.level, dmg = d,
				bananas = c.bananas and #c.bananas, bombs = c.bombs and #c.bombs, wells = c.wells and #c.wells, melon = c.melonUntil and c.melonUntil > run.clock.t,
				fishHits = c.fishHits, enemies = n, fear = fear, frozen = frozen, gold = run.stats:get("goldMultiplier"), thorns = run.stats:get("thornsDamage"),
				speed = run.stats:get("moveSpeedMultiplier"), dmgMul = run.stats:get("damageMultiplier"), jump = run.stats:get("jumpHeightStuds"), extraJumps = run.stats:get("extraJumps") }
		elseif cmd == "sethp" then -- sethp(frac): fija la vida a una fracción de la máx. (probar la pasiva de 67)
			if run then run.hp = run.stats:get("maxHp") * (a or 0.1) end
			return true
		elseif cmd == "apples" then -- apples(goto): cuenta las teteras con manzana; con goto=true te lleva junto a la primera
			if not run then return false end
			local n, ap, first = 0, 0, nil
			for _, v in ipairs(run.map.vases) do
				n += 1
				if v.apple then ap += 1; if v.alive and not first then first = v end end
			end
			if a and first then
				local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				if hrp then hrp.CFrame = CFrame.new(run.origin + Vector3.new(first.x + 6, 5 + run.map.height(first.x + 6, first.z), first.z)) end
			end
			local apples = 0
			for _, l in pairs(run.loot) do if l.kind == "apple" then apples += 1 end end
			return { vases = n, withApple = ap, appleLoot = apples, hp = run.hp, maxHp = run.stats:get("maxHp"), target = first and (first.x .. "," .. first.z) or "none" }
		elseif cmd == "coopStart" then -- coopStart(n): partida cooperativa con n-1 compañeros de prueba (bots quietos). Solo Studio.
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			local n = math.clamp(tonumber(a) or 2, 2, 4)
			local ch = player.Character
			if not ch then return false, "sin personaje" end
			DevTools.bots = DevTools.bots or {}
			local entries = { { player = player, classId = "class_01" } }
			for i = 1, n - 1 do
				ch.Archivable = true
				local model = ch:Clone()
				ch.Archivable = false
				for _, d in ipairs(model:GetDescendants()) do if d:IsA("LuaSourceContainer") then d:Destroy() end end
				model.Name = "BotCoop" .. i
				model.Parent = workspace
				local fake = setmetatable({ UserId = -1000 - i, Name = "BotCoop" .. i, DisplayName = "Bot" .. i, Character = model, Parent = nil },
					{ __index = { SetAttribute = function() end, GetAttribute = function() return nil end } })
				Profile.load(fake)
				table.insert(DevTools.bots, { fake = fake, model = model })
				entries[#entries + 1] = { player = fake, classId = "class_01" }
			end
			local r, err = RunService.startGroup(entries, b or "forest", math.clamp(tonumber(c) or 1, 1, 3))
			return r ~= nil, (not r) and err or nil
		elseif cmd == "coopState" then
			if not run then return false end
			local out = { paused = run.paused, waiting = "", members = {} }
			for _, m in ipairs(run.members) do
				table.insert(out.members, ("%s hp=%d/%d downed=%s revive=%.2f over=%s pos=%d,%d"):format(m.player.DisplayName, math.floor(m.hp), math.floor(m.stats:get("maxHp")), tostring(m.downed), m.reviveP or 0, tostring(rawget(m, "over")), math.floor(m.px), math.floor(m.pz)))
			end
			for k in pairs(run.pauseReasons) do out.waiting ..= k .. " " end
			return out
		elseif cmd == "coopKill" then -- coopKill(i): derriba al miembro i (1 = tú)
			if not run then return false end
			local m = run.members[tonumber(a) or 2]
			if not m then return false end
			m.invulnUntil = 0; m.hp = 0
			RunService.die(m, "hp")
			return m.downed
		elseif cmd == "coopBring" then -- coopBring(i): te lleva al lado del miembro i
			if not run then return false end
			local m = run.members[tonumber(a) or 2]
			local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			local mh = m and m.player.Character and m.player.Character:FindFirstChild("HumanoidRootPart")
			if hrp and mh then hrp.CFrame = mh.CFrame * CFrame.new(3, 0, 0) end
			return true
		elseif cmd == "coopClean" then
			for _, b in ipairs(DevTools.bots or {}) do
				local r2 = RunService.get(b.fake)
				if r2 and not r2.over then RunService.endRun(r2, "abandoned", "test") end
				if b.model then b.model:Destroy() end
			end
			DevTools.bots = {}
			return true
		elseif cmd == "unarm" then -- unarm(): quita las armas (probar enemigos que tienen que llegar al jugador)
			if not run then return false end
			require(script.Parent.Parent.Weapons.Behaviors).clear(run)
			run.weapons = {}
			return true
		elseif cmd == "coopInfo" then
			if not run then return false end
			return { coopN = run.coopN, hpMul = run.coopHpMul, dmgMul = run.coopDmgMul, members = #run.members, origin = tostring(run.origin), slot = run.slot }
		-- ===== spawn por créditos (SpawnDirector) =====
		elseif cmd == "spawnInfo" then -- spawnInfo(): datos del panel de depuración + contador real
			if not run then return false end
			local SD = require(script.Parent.Parent.Services.SpawnDirector)
			local d = SD.debugInfo(run.world, require(game.ReplicatedStorage.GameShared.Config.GameConfig).stage.maxSeconds)
			local n = 0
			for _ in pairs(run.world.enemies) do n += 1 end
			d.listCount = n; d.enemyCount = run.world.enemyCount; d.stageT = run.world.clock.stageT; d.final = run.world.superHorde ~= nil
			return d
		elseif cmd == "spawnKillAll" then -- spawnKillAll(): mata a TODOS los enemigos (no jefe) en el mismo tick (muerte simultánea)
			if not run then return false end
			local list = {}
			for _, e in pairs(run.world.enemies) do if not e.boss then list[#list + 1] = e end end
			for _, e in ipairs(list) do Combat.kill(run, e, { weaponId = "dev" }) end
			for _, e in ipairs(list) do Combat.kill(run, e, { weaponId = "dev" }) end -- 2ª vez a propósito: no debe restar de nuevo
			return #list
		elseif cmd == "spawnDestroyModels" then -- spawnDestroyModels(n): destruye n modelos "por fuera" (simula un NPC que desaparece)
			if not run then return false end
			local n = 0
			for _, e in pairs(run.world.enemies) do
				if n >= (a or 5) then break end
				if not e.boss and e.model then e.model:Destroy(); n += 1 end
			end
			return n
		elseif cmd == "spawnCorrupt" then -- spawnCorrupt(n): desajusta el contador a propósito (la verificación periódica lo debe corregir)
			if run then run.world.enemyCount += (a or 5) end
			return true
		elseif cmd == "spawnFinal" then -- spawnFinal(): adelanta el reloj de la etapa al 0:00 (empieza el Final Swarm)
			if run then local d = 600 - run.clock.stageT; run.clock.stageT += d; run.clock.total += d end
			return true
		elseif cmd == "abandon" then
			RunService.abandon(player)
			return true
		-- ===== huevos de jefe (solo Studio) =====
		elseif cmd == "infDamage" then -- infDamage(on): daño infinito en la run actual (cualquier personaje, solo Studio)
			if not run then return false end
			if a == false then run.stats:removeSource("dev"); run.devInfDamage = false
			else run.stats:addModifier("dev_inf_dmg", "dev", "damageMultiplier", "flat", 1e6); run.devInfDamage = true end
			return run.stats:get("damageMultiplier")
		elseif cmd == "toPortal" then -- toPortal(): te lleva delante del portal del jefe (probar la cinemática)
			if not run then return false end
			local p = run.map.portal
			local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if not (p and hrp) then return false end
			local f = Vector3.new(-p.x, 0, -p.z).Unit
			local x, z = p.x + f.X * 6, p.z + f.Z * 6
			hrp.CFrame = CFrame.lookAt(run.origin + Vector3.new(x, run.map.height(x, z) + 4, z), run.origin + Vector3.new(p.x, run.map.height(x, z) + 4, p.z))
			return { pp = p.pp == true, prompt = p.part and p.part:FindFirstChild("BossCinematicPrompt") ~= nil }
		elseif cmd == "cineTrigger" then -- cineTrigger(): te lleva al portal y activa la cinemática por la vía normal (validación incluida)
			if not run then return false end
			local p = run.map.portal
			local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if not (p and p.part and hrp) then return false end
			local f = Vector3.new(-p.x, 0, -p.z).Unit
			local x, z = p.x + f.X * 6, p.z + f.Z * 6
			hrp.CFrame = CFrame.lookAt(run.origin + Vector3.new(x, run.map.height(x, z) + 4, z), run.origin + Vector3.new(p.x, run.map.height(x, z) + 4, p.z))
			task.wait(0.2)
			require(game:GetService("ServerScriptService").BossCinematic.BossCinematicService).trigger(run.world, player)
			return run.world.cinematic ~= nil
		elseif cmd == "cineState" then
			if not run then return false end
			local w = run.world
			local b = w.boss
			return { cinematic = w.cinematic ~= nil, paused = w.paused, state = w.state, bossStarted = w.bossStarted == true,
				bossVis = b and b.visSize, bossRoot = b and b.part and b.part.Size.Y, walk = (player.Character and player.Character:FindFirstChildOfClass("Humanoid") or {}).WalkSpeed }
		elseif cmd == "gotoStage" then -- gotoStage(n): avanza la run hasta la etapa n (sin jefe)
			if not run then return false end
			while run.stage < math.min(tonumber(a) or 3, run.stages) do RunService.nextStage(run) end
			return run.stage
		elseif cmd == "eggs" then -- eggs(i): huevos, fuentes y mascotas del jugador (i = 1) o del bot i-1 de la prueba cooperativa
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			local who = player
			local idx = tonumber(a) or 1
			if idx > 1 then local bt = (DevTools.bots or {})[idx - 1]; who = bt and bt.fake end
			local rec = who and Profile.get(who)
			if not rec then return false, "sin perfil" end
			local d = rec.data
			local list = {}
			for uid, e in pairs(d.eggs or {}) do list[#list + 1] = { uid = uid, type = e.type, st = e.st, ready = e.ready, left = e.ready and math.floor(e.ready - workspace:GetServerTimeNow()) or nil, src = e.src } end
			local pets = {}
			for id in pairs(d.pets) do pets[#pets + 1] = id end
			table.sort(pets)
			return { user = who.UserId, schema = d.schemaVersion, eggs = list, sources = #d.eggSources, opened = #d.openedEggs, pets = table.concat(pets, ","), equipped = table.concat(Profile.equippedList(d), ","), silver = d.silver }
		elseif cmd == "eggGrant" then -- eggGrant(mapId, sourceKey): entrega directa (probar duplicados con la misma fuente)
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			return Profile.grantBossEgg(player, a or "forest", b or ("dev_" .. os.clock()), workspace:GetServerTimeNow())
		elseif cmd == "eggIncubate" then
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			return Profile.incubateEgg(player, a, workspace:GetServerTimeNow())
		elseif cmd == "eggOpen" then
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			return Profile.openBossEgg(player, a, workspace:GetServerTimeNow())
		elseif cmd == "eggReaward" then -- eggReaward(clearWorldGuard): vuelve a llamar a la entrega del mismo jefe (debe dar 0 huevos nuevos)
			if not run then return false end
			if a then run.world.eggGiven = {} end
			RunService.awardBossEggs(run.world, run.world.boss or { x = 0, z = 0 })
			return true
		elseif cmd == "pets" then -- pets(list|"none", placeN): da mascotas al perfil de memoria (solo Studio) y coloca las primeras N en el santuario
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			local rec = Profile.get(player); if not rec then return false end
			local d = rec.data
			if a == "none" then d.pets = {}; d.equippedPet = false; d.equippedPets = {}; d.placedPets = {}
			else
				for id in string.gmatch(a or "", "[%w_]+") do d.pets[id] = true end
				d.placedPets = {}
				local n = tonumber(b) or 0
				for id in string.gmatch(a or "", "[%w_]+") do if #d.placedPets < n then table.insert(d.placedPets, id) end end
			end
			local rem = game.ReplicatedStorage.GameShared.Network:FindFirstChild("Remotes")
			if rem and rem:FindFirstChild("ProfileData") then rem.ProfileData:FireClient(player, Profile.publicData(player)) end
			return { pets = d.pets, placed = d.placedPets }
		elseif cmd == "equipPets" then -- equipPets("pet_01,pet_05" | "none"): equipa esas mascotas (por la vía normal, máx. 3; solo Studio)
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			local rec = Profile.get(player); if not rec then return false end
			Profile.equipPet(player, "none")
			local errs = {}
			if a ~= "none" then
				for id in string.gmatch(a or "", "[%w_]+") do
					local ok, err = Profile.equipPet(player, id)
					if not ok then errs[#errs + 1] = id .. ":" .. tostring(err) end
				end
			end
			local rem = game.ReplicatedStorage.GameShared.Network:FindFirstChild("Remotes")
			if rem and rem:FindFirstChild("ProfileData") then rem.ProfileData:FireClient(player, Profile.publicData(player)) end
			return { equipped = Profile.equippedList(rec.data), errors = errs }
		elseif cmd == "eggsClear" then -- eggsClear(): borra los huevos de jefe del perfil de memoria (solo Studio)
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			local rec = Profile.get(player); if not rec then return false end
			rec.data.eggs = {}
			local rem = game.ReplicatedStorage.GameShared.Network:FindFirstChild("Remotes")
			if rem and rem:FindFirstChild("ProfileData") then rem.ProfileData:FireClient(player, Profile.publicData(player)) end
			return true
		elseif cmd == "eggSkip" then -- eggSkip(seg): adelanta la incubación de tus huevos (resta segundos a la fecha de fin)
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			local rec = Profile.get(player); if not rec then return false end
			local n = 0
			for _, e in pairs(rec.data.eggs) do if e.st == "inc" and e.ready then e.ready -= (tonumber(a) or 1e9); n += 1 end end
			local rem = game.ReplicatedStorage.GameShared.Network:FindFirstChild("Remotes")
			if rem and rem:FindFirstChild("ProfileData") then rem.ProfileData:FireClient(player, Profile.publicData(player)) end
			return n
		elseif cmd == "eggReload" then -- eggReload(): simula salir y volver (perfil liberado, pasado por JSON y recargado)
			local Profile = require(script.Parent.Parent.Persistence.ProfileService)
			local ok = Profile.devReload(player)
			local rem = game.ReplicatedStorage.GameShared.Network:FindFirstChild("Remotes")
			if ok and rem and rem:FindFirstChild("ProfileData") then rem.ProfileData:FireClient(player, Profile.publicData(player)) end
			return ok
		end
		return "comando desconocido"
	end
end

return DevTools
