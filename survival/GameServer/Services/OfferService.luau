--!nonstrict
-- Services/OfferService: ofertas de nivel, santuario, Moai y cofre (secciones 8, 9, 10.4).
-- Cola FIFO; nunca dos modales activos. El servidor sortea y aplica; el cliente solo elige un optionId.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("GameShared")
local GameConfig = require(Shared.Config.GameConfig)
local Stats = require(Shared.Util.Stats)
local WeaponsCat = require(Shared.Catalogs.Weapons)
local TomesCat = require(Shared.Catalogs.Tomes)
local ItemsCat = require(Shared.Catalogs.Items)
local Behaviors = require(script.Parent.Parent.Weapons.Behaviors)
local ClassEffects = require(script.Parent.Parent.Classes.ClassEffects)
local ItemEffects = require(script.Parent.Parent.Items.ItemEffects)

local Offers = {}
local P = GameConfig.progression
local OC = require(Shared.Config.MapObjectsConfig) -- 2026-11-06: santuarios, cofres, comerciantes y pactos configurables

local SHRINE_POOL = {
	{ id = "s_projspeed", text = "+10% velocidad de proyectil", stat = "projectileSpeedMultiplier", op = "flat", value = 0.10 },
	{ id = "s_proj", text = "+1 proyectil", stat = "extraProjectiles", op = "flat", value = 1 },
	{ id = "s_kb", text = "+12% empuje", stat = "knockbackMultiplier", op = "flat", value = 0.12 },
	{ id = "s_jump", text = "+1 salto", stat = "extraJumps", op = "flat", value = 1 },
	{ id = "s_size", text = "+11.2% tamaño de armas", stat = "sizeMultiplier", op = "flat", value = 0.112 },
	{ id = "s_thorns", text = "+5 espinas", stat = "thornsDamage", op = "flat", value = 5 },
	{ id = "s_crit", text = "+5% crítico", stat = "critChance", op = "flat", value = 0.05 },
	{ id = "s_drop", text = "+5% caída de potenciadores", stat = "powerupDropMultiplier", op = "flat", value = 0.05 },
	{ id = "s_power", text = "+12% potencia", stat = "powerupMultiplier", op = "flat", value = 0.12 },
	{ id = "s_dur", text = "+9.6% duración", stat = "durationMultiplier", op = "flat", value = 0.096 },
}

local function rollRarity(run)
	local w = Stats.rarityWeights(run.stats:get("luck"))
	local i = run.rng.offers:weighted(w)
	return GameConfig.rarity.order[i], GameConfig.rarity.magnitude[i]
end

local function countOwned(list) return #list end

-- Candidatos legales de nivel: adquisición o mejora (sin reservados, desterrados ni al máximo)
local function levelCandidates(run)
	local out = {}
	local maxL = P.maxItemLevel
	local all = table.clone(WeaponsCat.list)
	for _, d in ipairs(WeaponsCat.signature or {}) do table.insert(all, d) end
	for _, def in ipairs(all) do
		if not run.banished[def.id] then
			local owned = Behaviors.getWeapon(run, def.id)
			if owned then
				-- se mejoran las armas compradas y siempre el ataque propio del personaje
				-- (límite de armas = ranuras de la Tienda > Mejoras: 2 al empezar, hasta 4)
				if owned.level < maxL and (not run.ownedWeapons or run.ownedWeapons[def.id] or def.classId == run.classId) then table.insert(out, { type = "weapon", id = def.id, name = def.name, isNew = false, level = owned.level, desc = def.description }) end
			elseif #run.weapons < (run.weaponSlots or P.weaponSlots) and (not run.ownedWeapons or run.ownedWeapons[def.id]) then
				-- solo armas compradas en la tienda pueden aparecer como nuevas
				table.insert(out, { type = "weapon", id = def.id, name = def.name, isNew = true, level = 0, desc = def.description })
			end
		end
	end
	for _, def in ipairs(TomesCat.list) do
		if not run.banished[def.id] then
			local owned = run.tomes[def.id]
			if owned then
				if owned.level < (P.maxTomeLevel or maxL) then table.insert(out, { type = "tome", id = def.id, name = def.name, isNew = false, level = owned.level, tome = def }) end
			elseif run.tomeCount < (run.tomeSlots or P.tomeSlots) and (not run.ownedTomes or run.ownedTomes[def.id]) then
				table.insert(out, { type = "tome", id = def.id, name = def.name, isNew = true, level = 0, tome = def })
			end
		end
	end
	return out
end

local function describeTome(def, mag)
	if def.chaos then return "Un incremento aleatorio de los tomos 01–22." end
	local v = def.value * mag
	local f = GameConfig.statFormat[def.stat] or "flat"
	local txt
	if f == "pct" or f == "mult" then txt = string.format("+%.1f%%", v * 100)
	else txt = string.format("%+.2f", v) end
	return txt .. " " .. (GameConfig.statLabels[def.stat] or def.stat) .. (def.warn and ("\n? " .. def.warn) or "")
end

local function buildOption(run, cand, idx)
	local rarity, mag = rollRarity(run)
	local opt = {
		optionId = "o" .. idx, type = cand.type, itemId = cand.id, name = cand.name,
		isNew = cand.isNew, level = cand.level, nextLevel = cand.level + 1,
		rarity = rarity, rarityName = GameConfig.rarity.names[rarity], mag = mag,
	}
	if cand.type == "weapon" then
		opt.desc = cand.desc
		if not cand.isNew then
			-- 2026-11-05: estilo MegaBonk: la mejora trae 1-2 atributos sorteados; la rareza decide cuánto suben
			local w = Behaviors.getWeapon(run, cand.id)
			if w then
				opt.wup = Behaviors.rollUpgrade(w, mag, run.rng.offers, run.items.item_58 or 0)
				opt.desc = "Mejora: " .. Behaviors.describeUpgrade(opt.wup)
			end
		end
	else
		opt.desc = describeTome(cand.tome, mag)
		opt.warn = cand.tome.warn
	end
	return opt
end

local function pickDistinct(run, cands, n, exclude)
	local pool = {}
	for _, c in ipairs(cands) do if not (exclude and exclude[c.id]) then table.insert(pool, c) end end
	run.rng.offers:shuffle(pool)
	local out = {}
	for i = 1, math.min(n, #pool) do out[i] = pool[i] end
	-- con pocas armas compradas, los tomos acapararían las ofertas: el 60% de las veces se garantiza un arma
	local hasWeapon = false
	for _, c in ipairs(out) do if c.type == "weapon" then hasWeapon = true break end end
	if not hasWeapon and #out > 0 and run.rng.offers:chance(0.6) then
		for i = #out + 1, #pool do
			if pool[i].type == "weapon" then out[#out] = pool[i]; break end
		end
	end
	return out
end

local function snapshot(run, offer)
	local opts = {}
	for i, o in ipairs(offer.options) do
		opts[i] = { optionId = o.optionId, type = o.type, itemId = o.itemId, name = o.name, isNew = o.isNew, level = o.level, nextLevel = o.nextLevel, rarity = o.rarity, rarityName = o.rarityName, desc = o.desc, warn = o.warn, text = o.text, color = o.color }
	end
	return {
		ruId = run.id, offerId = offer.id, kind = offer.kind, title = offer.title, options = opts,
		refreshesLeft = run.rerolls, skipsLeft = run.skips, banishLeft = run.banishes,
		nextRefreshCost = 0, -- refrescar es gratis: lo limitan los usos de la mejora
		reel = offer.reel,
		gold = run.gold, canSkip = offer.canSkip, canRefresh = offer.canRefresh, canBanish = offer.canBanish, canIgnore = offer.canIgnore,
		fallback = offer.fallback, weaponSlots = string.format("%d/%d", #run.weapons, run.weaponSlots or P.weaponSlots), tomeSlots = string.format("%d/%d", run.tomeCount, run.tomeSlots or P.tomeSlots),
	}
end

local function generate(run, offer)
	if offer.kind == "level" then
		local cands = levelCandidates(run)
		local picks = pickDistinct(run, cands, 3, offer.exclude)
		if #picks == 0 then
			offer.fallback = true
			offer.options = {}
			local maxHp = run.stats:get("maxHp")
			if run.hp < maxHp then table.insert(offer.options, { optionId = "fb_heal", type = "fallback", name = "Curar 20% de vida", text = "fb_heal", rarity = "common", rarityName = "—", desc = "Recupera el 20% de la vida máxima." }) end
			table.insert(offer.options, { optionId = "fb_gold", type = "fallback", name = "+20 oro", text = "fb_gold", rarity = "common", rarityName = "—", desc = "Recibes 20 de oro." })
			return
		end
		offer.options = {}
		for i, c in ipairs(picks) do offer.options[i] = buildOption(run, c, i) end
	elseif offer.kind == "shrine" then
		local pool = table.clone(OC.shrine.pool or SHRINE_POOL) -- 2026-11-06: las 10 mejoras pedidas (MapObjectsConfig.shrine.pool)
		run.rng.offers:shuffle(pool)
		offer.options = {}
		local wrench = run.items.item_01 or 0
		for i = 1, 3 do
			local r, mag = rollRarity(run)
			if offer.golden then r, mag = "legendary", GameConfig.rarity.magnitude[#GameConfig.rarity.magnitude] end -- santuario dorado
			local e = pool[i]
			local v = e.value * mag * (1 + 0.075 * wrench)
			table.insert(offer.options, { optionId = "o" .. i, type = "shrine", shrine = e, value = v, name = "Santuario", rarity = r, rarityName = GameConfig.rarity.names[r], desc = string.format("%s (x%.2f)", e.text, mag * (1 + 0.075 * wrench)) })
		end
	elseif offer.kind == "merchant" and offer.holder and offer.holder.stock then
		-- 2026-11-06: el comerciante ya tiene su stock: se muestra lo que queda (precio fijo, texto con tu oro actual)
		offer.options = {}
		for i, o in ipairs(offer.holder.stock) do
			o.desc = (o.baseDesc or "") .. ("\n\n?? Precio: %d de oro (tenés %d)"):format(o.price or 0, run.gold)
			offer.options[i] = o
		end
	elseif offer.kind == "merchant" and (offer.category == "weapon" or offer.category == "tome") then
		-- 2026-11-06: comerciante de ARMAS o de TOMOS: 3 armas/tomos (nuevos si tenés lugar, o mejoras de los tuyos)
		local cands = {}
		for _, c in ipairs(levelCandidates(run)) do if c.type == offer.category then table.insert(cands, c) end end
		run.rng.offers:shuffle(cands)
		local MC = OC.merchant
		local scale = (MC.categoryPriceMul[offer.category] or 1) * (1 + 0.08 * (rawget(run, "paidChests") or 0))
		offer.options = {}
		for i = 1, math.min(MC.stock, #cands) do
			local opt = buildOption(run, cands[i], i)
			opt.price = math.floor((MC.prices[opt.rarity] or 40) * scale)
			opt.baseDesc = opt.desc
			opt.desc = opt.desc .. ("\n\n?? Precio: %d de oro (tenés %d)"):format(opt.price, run.gold)
			offer.options[i] = opt
		end
		if #offer.options == 0 then offer.options = { { optionId = "fb_gold", type = "fallback", name = "+20 oro", text = "fb_gold", rarity = "common", rarityName = "—", desc = "No tiene nada para vos. Te regala 20 de oro." } }
		elseif offer.holder then offer.holder.stock = offer.options end
	elseif offer.kind == "merchant" then
		-- 2026-11-05: mercader: 3 objetos desbloqueados de la rareza de su puesto, con precio en oro
		local TIER_RAR = { { common = true, uncommon = true }, { uncommon = true, rare = true }, { rare = true, epic = true }, { epic = true, legendary = true } }
		local PRICE = OC.merchant.prices
		local want = TIER_RAR[offer.tier or 1] or TIER_RAR[1]
		local pool = {}
		for _, it in ipairs(ItemsCat.list) do
			if ((not run.ownedItems) or run.ownedItems[it.id]) and not run.banished[it.id] and (run.items[it.id] or 0) < it.maxStacks and want[it.rarity] then table.insert(pool, it) end
		end
		if #pool < 3 then
			for _, it in ipairs(ItemsCat.list) do
				if ((not run.ownedItems) or run.ownedItems[it.id]) and (run.items[it.id] or 0) < it.maxStacks and not table.find(pool, it) then table.insert(pool, it) end
			end
		end
		run.rng.offers:shuffle(pool)
		local scale = 1 + 0.08 * (rawget(run, "paidChests") or 0) -- los precios suben un poco con lo que ya compraste
		offer.options = {}
		for i = 1, math.min(3, #pool) do
			local it = pool[i]
			local price = math.floor((PRICE[it.rarity] or 40) * scale)
			table.insert(offer.options, { optionId = "o" .. i, type = "item", itemId = it.id, name = it.name, rarity = it.rarity, rarityName = GameConfig.rarity.names[it.rarity],
				desc = it.description .. ("\n\n?? Precio: %d de oro (tenés %d)"):format(price, run.gold), baseDesc = it.description, level = run.items[it.id] or 0, price = price })
		end
		if #offer.options == 0 then offer.options = { { optionId = "fb_gold", type = "fallback", name = "+20 oro", text = "fb_gold", rarity = "common", rarityName = "—", desc = "Recibes 20 de oro." } }
		elseif offer.holder then offer.holder.stock = offer.options end
	elseif offer.kind == "pact" then
		-- 2026-11-06: ESTATUA ESPECIAL: 3 pactos distintos sorteados por rareza (MapObjectsConfig.pacts / pactRarityWeights)
		local byR = {}
		for _, p in ipairs(OC.pacts) do byR[p.rarity] = byR[p.rarity] or {}; table.insert(byR[p.rarity], p) end
		local taken = {}
		offer.options = {}
		for i = 1, 3 do
			local pick
			for _ = 1, 20 do
				local r = OC.pick(OC.pactRarityWeights, run.rng.offers)
				local list = byR[r]
				if list and #list > 0 then
					local p = list[run.rng.offers:integer(1, #list)]
					if not taken[p.id] then pick = p; break end
				end
			end
			if not pick then for _, p in ipairs(OC.pacts) do if not taken[p.id] then pick = p; break end end end
			if pick then
				taken[pick.id] = true
				local lines = {}
				for _, ef in ipairs(pick.effects) do
					local stat, op, v = ef[1], ef[2], ef[3]
					local f = GameConfig.statFormat[stat] or "flat"
					local good = (op == "mult" and v >= 1) or (op ~= "mult" and v >= 0)
					if stat == "difficulty" then good = not good end
					local txt
					if op == "mult" then txt = ("%+d%%"):format(math.floor((v - 1) * 100 + 0.5))
					elseif f == "pct" or f == "mult" or stat == "difficulty" then txt = ("%+.0f%%"):format(v * 100)
					else txt = ("%+g"):format(v) end
					lines[#lines + 1] = ("%s %s %s"):format(good and "?" or "?", txt, GameConfig.statLabels[stat] or stat)
				end
				table.insert(offer.options, { optionId = "o" .. i, type = "pact", pact = pick, name = pick.name, rarity = pick.rarity, rarityName = GameConfig.rarity.names[pick.rarity], desc = table.concat(lines, "\n") })
			end
		end
	elseif offer.kind == "microwave" then
		-- microondas: elegís un objeto TUYO y se duplica (+1 copia) por oro. El color decide qué rarezas acepta.
		local TIER_OK = { { common = true, uncommon = true }, { common = true, uncommon = true, rare = true, epic = true }, nil }
		local ok = TIER_OK[offer.tier or 1]
		local mine = {}
		for id, c in pairs(run.items) do
			local it = ItemsCat.byId[id]
			if it and c > 0 and c < it.maxStacks and (not ok or ok[it.rarity]) then table.insert(mine, it) end
		end
		table.sort(mine, function(a, b) return a.id < b.id end)
		run.rng.offers:shuffle(mine)
		local PRICE = { common = 20, uncommon = 30, rare = 45, epic = 70, legendary = 100 }
		offer.options = {}
		for i = 1, math.min(3, #mine) do
			local it = mine[i]
			local price = math.floor((PRICE[it.rarity] or 30) * (1 + 0.5 * (offer.uses or 0)))
			table.insert(offer.options, { optionId = "o" .. i, type = "item", itemId = it.id, name = "Duplicar: " .. it.name, rarity = it.rarity, rarityName = GameConfig.rarity.names[it.rarity],
				desc = ("Tenés x%d ? x%d\n%s\n\n?? Precio: %d de oro (tenés %d)"):format(run.items[it.id], run.items[it.id] + 1, it.description, price, run.gold), level = run.items[it.id], price = price })
		end
		if #offer.options == 0 then offer.options = { { optionId = "fb_gold", type = "fallback", name = "Nada para duplicar", text = "fb_gold", rarity = "common", rarityName = "—", desc = "Este microondas no acepta tus objetos. Te da 20 de oro." } } end
	elseif offer.kind == "chest" then
		-- 2026-11-05 (estilo MegaBonk): el cofre da UN objeto. Se tira la rareza con la suerte y sale uno al azar de esa rareza.
		-- Solo se puede TOMAR o DESTERRAR (desterrar lo saca del pool y el cofre se cierra vacío).
		local pool = {}
		for _, it in ipairs(ItemsCat.list) do
			local ok = ((not run.ownedItems) or run.ownedItems[it.id]) and not run.banished[it.id]
			if ok and (run.items[it.id] or 0) < it.maxStacks then table.insert(pool, it) end
		end
		offer.options = {}
		if #pool == 0 then
			offer.fallback = true
			offer.options = { { optionId = "fb_gold", type = "fallback", name = "+20 oro", text = "fb_gold", rarity = "common", rarityName = "—", desc = "Recibes 20 de oro." } }
			offer.reel = {}
			return
		end
		-- 2026-11-06: qué trae el cofre (MapObjectsConfig.chest.rewards): objeto, arma, tomo, mejora de estadística u oro
		local kindR = OC.pick(OC.chest.rewards, run.rng.offers)
		local reel = {}
		for i = 1, 22 do local it = pool[run.rng.offers:integer(1, #pool)]; reel[i] = { it.id, it.rarity, "item" } end
		offer.reel = reel
		if kindR == "weapon" or kindR == "tome" then
			local cands = {}
			for _, c in ipairs(levelCandidates(run)) do if c.type == kindR then table.insert(cands, c) end end
			if #cands > 0 then
				local opt = buildOption(run, cands[run.rng.offers:integer(1, #cands)], 1)
				opt.optionId = "o1"
				offer.options = { opt }
				return
			end
		elseif kindR == "stat" then
			local list = OC.shrine.pool
			local e = list[run.rng.offers:integer(1, #list)]
			local r, mag = rollRarity(run)
			local v = e.value * mag
			offer.options = { { optionId = "o1", type = "shrine", shrine = e, value = v, name = "Mejora de estadística", rarity = r, rarityName = GameConfig.rarity.names[r], desc = string.format("%s (x%.2f)", e.text, mag) } }
			return
		elseif kindR == "gold" then
			local g = math.floor(run.rng.offers:integer(OC.chest.gold[1], OC.chest.gold[2]) * (1 + 0.5 * ((run.stage or 1) - 1)))
			offer.options = { { optionId = "fb_gold", type = "fallback", name = ("+%d de oro"):format(g), text = "fb_gold", gold = g, rarity = "uncommon", rarityName = "Monedas", desc = ("Recibís %d de oro."):format(g) } }
			return
		end
		local rar = rollRarity(run)
		local order = GameConfig.rarity.order
		local ri = table.find(order, rar) or 1
		local pick
		-- si no hay de esa rareza, baja; si tampoco, sube
		for d = 0, #order do
			for _, idx in ipairs({ ri - d, ri + d }) do
				if not pick and order[idx] then
					local same = {}
					for _, it in ipairs(pool) do if it.rarity == order[idx] then table.insert(same, it) end end
					if #same > 0 then pick = same[run.rng.offers:integer(1, #same)] end
				end
			end
			if pick then break end
		end
		pick = pick or pool[run.rng.offers:integer(1, #pool)]
		table.insert(offer.options, { optionId = "o1", type = "item", itemId = pick.id, name = pick.name, rarity = pick.rarity, rarityName = GameConfig.rarity.names[pick.rarity], desc = pick.description, level = run.items[pick.id] or 0, nextLevel = (run.items[pick.id] or 0) + 1, isNew = (run.items[pick.id] or 0) == 0 })
		-- (el rodillo de relleno ya se armó arriba)
	else -- moai: objetos
		local pool = {}
		-- solo objetos desbloqueados (iniciales, comprados en la tienda o ganados en misiones)
		for _, it in ipairs(ItemsCat.list) do
			local ok = ((not run.ownedItems) or run.ownedItems[it.id]) and not run.banished[it.id]
			if ok and (run.items[it.id] or 0) < it.maxStacks then table.insert(pool, it) end
		end
		local picks = {}
		local exclude = offer.exclude or {}
		local filtered = {}
		for _, it in ipairs(pool) do if not exclude[it.id] then table.insert(filtered, it) end end
		if #filtered < 3 then filtered = pool end
		offer.order = offer.order or filtered
		-- orden determinista de las pistas ofrecidas: primero las no vistas
		run.rng.offers:shuffle(filtered)
		offer.options = {}
		for i = 1, math.min(3, #filtered) do
			local it = filtered[i]
			table.insert(offer.options, { optionId = "o" .. i, type = "item", itemId = it.id, name = it.name, rarity = it.rarity, rarityName = GameConfig.rarity.names[it.rarity], desc = it.description, level = run.items[it.id] or 0, nextLevel = (run.items[it.id] or 0) + 1, isNew = (run.items[it.id] or 0) == 0 })
		end
		offer.seen = offer.seen or {}
		for _, o in ipairs(offer.options) do offer.seen[o.itemId] = true end
		if #offer.options == 0 then -- sin objetos disponibles: nunca se queda trabada la oferta
			offer.fallback = true
			offer.options = { { optionId = "fb_gold", type = "fallback", name = "+20 oro", text = "fb_gold", rarity = "common", rarityName = "—", desc = "Recibes 20 de oro." } }
		end
	end
end

local function newOffer(run, kind, extra)
	run.nextOfferId += 1
	local offer = { id = run.nextOfferId, kind = kind, resolved = false, canSkip = false, canRefresh = false, canBanish = false, canIgnore = false }
	if kind == "level" then
		offer.title = "¡Subida de nivel!"
		offer.canSkip, offer.canRefresh, offer.canBanish = true, true, true
	elseif kind == "shrine" then
		offer.title = "Santuario"; offer.canIgnore = true
	elseif kind == "moai" then
		offer.title = "Moai"; offer.canSkip, offer.canRefresh, offer.canBanish = true, true, true
	elseif kind == "pact" then
		offer.title = "Estatua especial"; offer.canIgnore = true
	elseif kind == "merchant" or kind == "microwave" then
		offer.title = kind == "merchant" and "Mercader" or "Microondas"; offer.canIgnore = true -- "Ignorar" = irte sin comprar
	else
		offer.title = "Cofre"; offer.canSkip, offer.canRefresh, offer.canBanish = false, false, true -- 2026-11-05: tomar o desterrar
	end
	if extra then for k, v in pairs(extra) do offer[k] = v end end
	generate(run, offer)
	return offer
end

function Offers.queue(run, kind, extra)
	table.insert(run.offerQueue, { kind = kind, extra = extra })
	Offers.pump(run)
end

function Offers.pump(run)
	-- (cooperativo) un jugador caído no abre ofertas: se le muestran al revivir
	if run.activeOffer or run.over or run.downed or run.wiping then return end
	local nxt = table.remove(run.offerQueue, 1)
	if not nxt then return end
	local offer = newOffer(run, nxt.kind, nxt.extra)
	run.activeOffer = offer
	run.pause(run, "offer")
	run.send("OfferShow", snapshot(run, offer))
end

local function closeOffer(run, offer, result)
	offer.resolved = true
	run.activeOffer = nil
	run.send("OfferClose", { offerId = offer.id, result = result })
	if #run.offerQueue > 0 then
		Offers.pump(run)
	else
		run.resume(run, "offer")
	end
end

-- ===== aplicar elección =====
local function applyTome(run, def, mag, label)
	local st = run.stats
	local owned = run.tomes[def.id]
	if not owned then
		owned = { level = 0, history = {} }
		run.tomes[def.id] = owned
		run.tomeCount += 1
	end
	owned.level += 1
	local function inc(d, m)
		local v = d.value * m
		local before = st:get(d.stat)
		st:addModifier(string.format("%s_L%d_%d", d.id, owned.level, run.nextModId), d.id, d.stat, "flat", v)
		run.nextModId += 1
		local delta = st:get(d.stat) - before
		if d.healWithMax and delta > 0 then run.hp += delta end
		if d.stat == "shieldMax" and delta > 0 then run.shield += delta end -- solo la diferencia
		return v, delta
	end
	if def.chaos then
		local pool = {}
		for _, d in ipairs(TomesCat.list) do
			if d.stat and not (TomesCat.chaosExcludesDifficulty and d.stat == "difficulty") then table.insert(pool, d) end
		end
		local pick = pool[run.rng.passives:integer(1, #pool)]
		local v = inc(pick, mag)
		table.insert(owned.history, { mag = mag, via = pick.id })
		table.insert(run.log, { t = run.clock.t, src = "tome_23", text = string.format("Caos: %s %+.3f", GameConfig.statLabels[pick.stat] or pick.stat, v) })
	else
		inc(def, mag)
		table.insert(owned.history, { mag = mag })
	end
end

function Offers.applyChoice(run, offer, opt)
	if opt.type == "weapon" then
		local w = Behaviors.getWeapon(run, opt.itemId)
		if w then
			if w.level < P.maxItemLevel then
				w.level += 1
				Behaviors.applyUpgrade(w, opt.wup)
			end
		else Behaviors.addWeapon(run, opt.itemId) end
	elseif opt.type == "tome" then
		applyTome(run, require(Shared.Catalogs.Tomes).byId[opt.itemId], opt.mag or 1)
	elseif opt.type == "item" then
		run.items[opt.itemId] = (run.items[opt.itemId] or 0) + 1
		local it = ItemsCat.byId[opt.itemId]
		ItemEffects.applyStats(run, it.id)
		table.insert(run.log, { t = run.clock.t, src = it.id, text = it.name .. " x" .. run.items[it.id] })
	elseif opt.type == "pact" then
		for _, ef in ipairs(opt.pact.effects) do
			local before = run.stats:get("maxHp")
			run.stats:addModifier("pact_" .. run.nextModId, "pact", ef[1], ef[2], ef[3])
			run.nextModId += 1
			if ef[1] == "maxHp" then
				local mh = run.stats:get("maxHp")
				if mh > before then run.hp += mh - before end
				run.hp = math.min(run.hp, mh)
			end
		end
		table.insert(run.log, { t = run.clock.t, src = "pact", text = "Pacto: " .. opt.pact.name })
	elseif opt.type == "shrine" then
		local e = opt.shrine
		local before = run.stats:get(e.stat)
		run.stats:addModifier("shrine_" .. run.nextModId, "shrine", e.stat, e.op, opt.value)
		run.nextModId += 1
		if e.healWithMax then local d = run.stats:get(e.stat) - before; if d > 0 then run.hp += d end end
		table.insert(run.log, { t = run.clock.t, src = "shrine", text = string.format("%s (%+.3f)", e.text, opt.value) })
	elseif opt.type == "fallback" then
		if opt.text == "fb_heal" then run.hp = math.min(run.stats:get("maxHp"), run.hp + run.stats:get("maxHp") * P.fallbackHealPct) else run.gold += (opt.gold or P.fallbackGold) end
	end
end

local function findOption(offer, optionId)
	for _, o in ipairs(offer.options) do if o.optionId == optionId then return o end end
end

function Offers.choose(run, offerId, optionId)
	local offer = run.activeOffer
	if not offer or offer.id ~= offerId or offer.resolved then return false, "stale" end
	local opt = findOption(offer, optionId)
	if not opt then return false, "invalid_option" end
	if opt.price then
		-- mercader / microondas: hay que tener el oro
		if run.gold < opt.price then
			run.send("Toast", { text = ("?? Te falta oro: cuesta %d y tenés %d."):format(opt.price, run.gold) })
			return false, "no_gold"
		end
		run.gold -= opt.price
	end
	Offers.applyChoice(run, offer, opt)
	if offer.kind == "level" then run.stats_picks += 1 end
	if offer.onChosen then offer.onChosen(run, opt) end
	closeOffer(run, offer, "chosen")
	return true
end

function Offers.action(run, offerId, actionId, targetOptionId)
	local offer = run.activeOffer
	if not offer or offer.id ~= offerId or offer.resolved then return false, "stale" end
	if actionId == "skip" then
		if not offer.canSkip or run.skips <= 0 then return false, "no_uses" end
		run.skips -= 1
		if offer.onSkipped then offer.onSkipped(run) end
		closeOffer(run, offer, "skipped")
		return true
	elseif actionId == "ignore" then
		if not offer.canIgnore then return false, "invalid" end
		if offer.onIgnored then offer.onIgnored(run) end
		closeOffer(run, offer, "ignored")
		return true
	elseif actionId == "refresh" then
		if not offer.canRefresh or run.rerolls <= 0 then return false, "no_uses" end
		local cost = 0
		if run.gold < cost then return false, "no_gold" end
		run.gold -= cost -- cobro y nueva oferta, en el mismo paso
		run.rerolls -= 1
		run.refreshUsed += 1
		if offer.kind == "level" then offer.exclude = nil end
		generate(run, offer)
		run.send("OfferShow", snapshot(run, offer))
		return true
	elseif actionId == "banish" then
		if not offer.canBanish or run.banishes <= 0 then return false, "no_uses" end
		local opt = targetOptionId and findOption(offer, targetOptionId)
		if not opt or opt.type == "fallback" then return false, "invalid_option" end
		run.banishes -= 1
		run.banished[opt.itemId] = true
		if offer.kind == "chest" then
			table.insert(run.log, { t = run.clock.t, src = opt.itemId, text = "Desterrado: " .. tostring(opt.name) })
			run.send("Toast", { text = ("?? Desterraste %s: ya no va a salir en esta partida."):format(tostring(opt.name)), short = true })
			closeOffer(run, offer, "banished")
			return true
		end
		-- reemplaza SOLO esa carta una vez; si no hay alternativas, recompensa alternativa
		local keep = {}
		for _, o in ipairs(offer.options) do if o ~= opt then keep[o.itemId] = true end end
		if opt.type == "item" then
			-- cofre/Moai: se reemplaza por otro objeto desbloqueado
			local pool = {}
			for _, it in ipairs(ItemsCat.list) do
				if ((not run.ownedItems) or run.ownedItems[it.id]) and not run.banished[it.id] and not keep[it.id] then table.insert(pool, it) end
			end
			for i, o in ipairs(offer.options) do
				if o == opt then
					if #pool > 0 then
						local it = pool[run.rng.offers:integer(1, #pool)]
						offer.options[i] = { optionId = "o" .. i, type = "item", itemId = it.id, name = it.name, rarity = it.rarity, rarityName = GameConfig.rarity.names[it.rarity], desc = it.description, level = run.items[it.id] or 0, nextLevel = (run.items[it.id] or 0) + 1, isNew = (run.items[it.id] or 0) == 0 }
					else table.remove(offer.options, i) end
					break
				end
			end
			if #offer.options == 0 then
				offer.options = { { optionId = "fb_gold", type = "fallback", name = "+20 oro", text = "fb_gold", rarity = "common", rarityName = "—", desc = "Recibes 20 de oro." } }
			end
			run.send("OfferShow", snapshot(run, offer))
			return true
		end
		local cands = levelCandidates(run)
		local pool = {}
		for _, c in ipairs(cands) do if not keep[c.id] then table.insert(pool, c) end end
		for i, o in ipairs(offer.options) do
			if o == opt then
				if #pool > 0 then
					offer.options[i] = buildOption(run, pool[run.rng.offers:integer(1, #pool)], i)
				else
					table.remove(offer.options, i)
				end
				break
			end
		end
		if #offer.options == 0 then generate(run, offer) end
		run.send("OfferShow", snapshot(run, offer))
		return true
	end
	return false, "invalid_action"
end

return Offers
