--!nonstrict
-- Weapons/Behaviors: comportamiento real de las 26 armas (sección 6). Todo el daño pasa por Combat.hit.
-- Los proyectiles son lógicos (tablas) con barrido segmento-esfera; el cliente solo dibuja efectos (Fx).
-- Las partes visuales NO existen en el servidor para proyectiles/zonas.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("GameShared")
local GameConfig = require(Shared.Config.GameConfig)
local Weapons = require(Shared.Catalogs.Weapons)
local MapService = require(script.Parent.Parent.Services.MapService)

local Behaviors = {}

local PROJ_CAP = 160
local ZONE_CAP = 60

-- ===== utilidades =====
local function useful(def)
	local set = {}
	for tok in string.gmatch(def.usefulStats, "%S+") do set[tok] = true end
	return set
end

local function derive(run, w)
	local st, def, L = run.stats, w.def, w.level
	local u = w.useful
	-- 2026-11-05: el nivel del arma ya no sube todo por igual; cada nivel sumó atributos sorteados (w.up, ver
	-- Behaviors.rollUpgrade y GameConfig.weaponUpgrades). Los tomos (estadísticas globales) se aplican encima.
	local up = w.up or {}
	local function U(k) return up[k] or 0 end
	local cdMul = (u.A and st:get("attackSpeedMultiplier") or 1) * (1 + U("atk"))
	local ps = {
		dmg = def.baseDamage * (1 + U("dmg")),
		cd = math.max(GameConfig.minAttackInterval, def.baseCooldown / cdMul),
		count = def.baseProjectiles + (u.Q and (math.floor(st:get("extraProjectiles")) + U("count")) or 0),
		bounces = def.baseBounces + (u.B and (math.floor(st:get("extraBounces")) + U("bounce")) or 0),
		size = (u.S and st:get("sizeMultiplier") or 1) * (1 + U("size")),
		speed = def.speed * (u.V and st:get("projectileSpeedMultiplier") or 1) * (1 + U("pspeed")),
		dur = (u.T and st:get("durationMultiplier") or 1) * (1 + U("dur")),
		kb = def.knockback * (u.K and st:get("knockbackMultiplier") or 1) * (1 + U("kb")),
		canCrit = (u.P or u.C) and true or false,
		critBonus = (w.ownCrit or 0) + U("crit"),
		critDmgBonus = U("critdmg"),
	}
	if not u.Q then ps.count = def.baseProjectiles end
	return ps
end
Behaviors.derive = derive

local function ctx(w, ps, extra)
	local c = { amount = ps.dmg, weaponId = w.id, tags = {}, canCrit = ps.canCrit, critBonus = ps.critBonus, critDmgBonus = ps.critDmgBonus, depth = 0 }
	for _, t in ipairs(w.def.tags) do c.tags[t] = true end
	if extra then for k, v in pairs(extra) do c[k] = v end end
	return c
end

local function knock(run, e, fromx, fromz, kb)
	if kb <= 0 then return end
	local dx, dz = e.x - fromx, e.z - fromz
	local d = math.max(0.01, math.sqrt(dx * dx + dz * dz))
	local resist = (e.boss and 0.1) or (e.elite and 0.5) or 1
	e.kbx = dx / d * kb * 3 * resist
	e.kbz = dz / d * kb * 3 * resist
	e.kbt = 0.15
end

-- dirección de puntería: autoapuntado al más cercano; los tags manualAim usan la dirección del cliente si está activa
local function aim(run, Combat, w, range)
	if w.def.tags and table.find(w.def.tags, "manualAim") and run.aimActive and run.aimDir then
		return run.aimDir.X, run.aimDir.Z, nil
	end
	local e = Combat.nearest(run, run.px, run.pz, range)
	if not e then
		-- sin enemigos cerca: el ataque sale igual, hacia donde mira el personaje
		local f = run.facing
		local fx, fz = f and f.X or 0, f and f.Z or 1
		local m = math.sqrt(fx * fx + fz * fz)
		if m < 0.01 then fx, fz, m = 0, 1, 1 end
		return fx / m, fz / m, nil
	end
	local dx, dz = e.x - run.px, e.z - run.pz
	local d = math.max(0.01, math.sqrt(dx * dx + dz * dz))
	return dx / d, dz / d, e
end

-- golpes cuerpo a cuerpo: 2026-11-05 (pedido del usuario) apuntan SOLOS al enemigo más cercano que esté a su alcance;
-- si no hay ninguno cerca, salen hacia donde mira el personaje. Ya no hace falta apuntar.
local MELEE_AUTO_RANGE = 1.6 -- × radio del golpe (mín. 14 studs)
local function faceDir(run, Combat, w, ps)
	if Combat and w then
		local reach = math.max(14, (w.def.radius or 6) * ((ps and ps.size) or 1) * MELEE_AUTO_RANGE)
		local e = Combat.nearest(run, run.px, run.pz, reach)
		if e then
			local dx, dz = e.x - run.px, e.z - run.pz
			local d = math.sqrt(dx * dx + dz * dz)
			if d > 0.05 then
				run.meleeAimX, run.meleeAimZ, run.meleeAimT = dx / d, dz / d, os.clock()
				return dx / d, dz / d
			end
		end
	end
	local f = run.facing
	local fx, fz = f and f.X or 0, f and f.Z or 1
	local m = math.sqrt(fx * fx + fz * fz)
	if m < 0.01 then return 0, 1 end
	return fx / m, fz / m
end
local MELEE_FACING = { punch = true, bite = true, headbutt = true, bat = true, twinblades = true, kick = true, combo = true, sweep = true }

local function rot(dx, dz, ang)
	local c, s = math.cos(ang), math.sin(ang)
	return dx * c - dz * s, dx * s + dz * c
end

local function fanAngles(count, spreadDeg)
	local out = {}
	if count <= 1 then return { 0 } end
	local step = math.rad(spreadDeg) / (count - 1)
	for i = 1, count do out[i] = -math.rad(spreadDeg) / 2 + step * (i - 1) end
	return out
end

-- melee con más cantidad: el 1º sale adelante, el 2º por la espalda, el 3º y 4º por los costados,
-- después las diagonales, hasta cerrar el círculo (con más de 8 se reparten parejos en 360°)
local CIRCLE_ORDER = { 0, math.pi, math.pi / 2, -math.pi / 2, math.pi / 4, -3 * math.pi / 4, 3 * math.pi / 4, -math.pi / 4 }
local function circleAngles(count)
	count = math.max(1, count)
	local out = {}
	if count <= #CIRCLE_ORDER then
		for i = 1, count do out[i] = CIRCLE_ORDER[i] end
	else
		for i = 1, count do out[i] = (i - 1) * 2 * math.pi / count end
	end
	return out
end
Behaviors.circleAngles = circleAngles

-- zonas alcanzadas por ataques en este tick: RunService rompe las vasijas que caen adentro (y vacía la lista)
local function markHit(run, x, z, r)
	local list = rawget(run, "vaseHits")
	if not list then list = {}; rawset(run, "vaseHits", list) end
	if #list < 400 then list[#list + 1] = { x, z, r } end
end
Behaviors.markHit = markHit

-- ===== proyectiles =====
local function spawnProj(run, w, ps, p)
	if #run.projectiles >= PROJ_CAP then return end
	run.nextProjId += 1
	p.id = run.nextProjId
	p.weaponId = w.id; p.w = w; p.ps = ps
	p.x = p.x or run.px; p.z = p.z or run.pz
	p.hits = {}; p.life = p.life or 3
	p.traveled = 0
	p.color = p.color or { 255, 255, 255 }
	table.insert(run.projectiles, p)
	if run.m then run.m.add.fired += 1 end
	return p
end

-- ===== misiles rectos (Misiles, Cohete guiado, Cohetes) =====
-- Apuntan a la posición 3D del objetivo AL DISPARAR y después siguen recto: no persiguen, no corrigen y no siguen el
-- terreno. Si en el tramo entre la posición anterior y la siguiente hay un obstáculo sólido (montaña, roca, tronco, muro),
-- explotan ahí. El daño lo valida el servidor; el cliente dibuja la misma recta (evento M3) y la borra al impactar (MK).
local Players = game:GetService("Players")
local MISSILE_RP = RaycastParams.new()
MISSILE_RP.FilterType = Enum.RaycastFilterType.Exclude
local function setupStraight(run, p, target, angle)
	local origin = run.map.origin
	local char = run.player and run.player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local from = hrp and (hrp.Position + Vector3.new(0, 0.5, 0)) or (origin + Vector3.new(run.px, run.map.height(run.px, run.pz) + 3, run.pz))
	local dir
	if target and target.part and target.part.Parent then
		dir = target.part.Position - from -- posición 3D del objetivo en este instante (piso o aire)
	else
		dir = Vector3.new(p.dx, 0, p.dz)
	end
	if dir.Magnitude < 0.01 then dir = Vector3.new(p.dx, 0, p.dz) end
	dir = dir.Unit
	if angle and angle ~= 0 then dir = CFrame.Angles(0, -angle, 0) * dir end -- abanico (mismo giro que rot())
	local h = Vector3.new(dir.X, 0, dir.Z)
	if h.Magnitude > 0.01 then p.dx, p.dz = h.Unit.X, h.Unit.Z end
	p.straight = true
	p.homing = nil
	p.pos3, p.dir3 = from, dir
	p.x, p.z = from.X - origin.X, from.Z - origin.Z
end

local function sendProj(run, Combat, p)
	Combat.fx(run, "m", p.id, p.x, 2.5, p.z, p.dx * p.speed, 0, p.dz * p.speed, p.life, p.size, p.color[1], p.color[2], p.color[3], p.vis)
end

local function explode(run, Combat, p, x, z)
	local ps, w = p.ps, p.w
	local r = p.explode * ps.size
	markHit(run, x, z, r)
	Combat.fx(run, "b", x, 1, z, r, p.color[1], p.color[2], p.color[3], 0.35)
	for _, v in ipairs(Combat.inRadius(run, x, z, r)) do
		local c = ctx(w, ps, { amount = p.dmg, noLifesteal = false })
		if p.poison then c.tags.poison = true; Combat.applyPoison(run, v, 2, w.id) end
		Combat.hit(run, v, c)
		knock(run, v, x, z, ps.kb)
	end
end

local function bounceTarget(run, Combat, p, e)
	local best, bd = nil, math.huge
	for _, v in ipairs(Combat.inRadius(run, e.x, e.z, p.bounceRadius or 14)) do
		if not v.dead and not p.hits[v.id] then
			local d = (v.x - e.x) ^ 2 + (v.z - e.z) ^ 2
			if d < bd then best, bd = v, d end
		end
	end
	return best
end

-- avance de un misil recto: devuelve true si hay que quitarlo
local function stepStraight(run, Combat, p, dt)
	local origin = run.map.origin
	local step = p.speed * dt
	local from = p.pos3
	local delta = p.dir3 * step
	-- 1) obstáculo sólido entre la posición anterior y la siguiente (terreno incluido): no atraviesa ni sube montañas
	local excl = {}
	for _, pl in ipairs(Players:GetPlayers()) do if pl.Character then excl[#excl + 1] = pl.Character end end
	if run.enemyFolder then excl[#excl + 1] = run.enemyFolder end
	local ce = workspace:FindFirstChild("ClientEffects"); if ce then excl[#excl + 1] = ce end
	MISSILE_RP.FilterDescendantsInstances = excl
	local hit = workspace:Raycast(from, delta, MISSILE_RP)
	local frac = 1
	if hit and (hit.Instance == workspace.Terrain or hit.Instance.CanCollide) then
		frac = math.clamp((hit.Position - from).Magnitude / math.max(step, 1e-3), 0, 1)
	else
		hit = nil
	end
	-- 2) enemigos en ese mismo tramo (hasta el obstáculo), comparando también la ALTURA del misil con el cuerpo del enemigo
	local seg = delta * frac
	local ox, oz = from.X - origin.X, from.Z - origin.Z
	local sx, sz = seg.X, seg.Z
	local sl = math.max(1e-6, sx * sx + sz * sz)
	local best, bestT = nil, nil
	for _, e in ipairs(Combat.inRadius(run, ox + sx / 2, oz + sz / 2, seg.Magnitude / 2 + p.radius)) do
		if not e.dead and not p.hits[e.id] then
			local t = math.clamp(((e.x - ox) * sx + (e.z - oz) * sz) / sl, 0, 1)
			local cx, cz = ox + sx * t, oz + sz * t
			local rr = p.radius + e.radius
			if (e.x - cx) ^ 2 + (e.z - cz) ^ 2 <= rr * rr then
				local y = from.Y + seg.Y * t
				local half = (e.visSize or e.size or 2) / 2
				local ey = (e.part and e.part.Parent) and e.part.Position.Y or (origin.Y + run.map.height(e.x, e.z) + half)
				if math.abs(y - ey) <= half + p.radius then
					if not bestT or t < bestT then best, bestT = e, t end
				end
			end
		end
	end
	if best then
		p.hits[best.id] = true
		p.traveled += step * frac * bestT
		local c = ctx(p.w, p.ps, { amount = p.dmg })
		if p.explode then explode(run, Combat, p, best.x, best.z) else Combat.hit(run, best, c); knock(run, best, ox, oz, p.ps.kb) end
		return true
	end
	if hit then
		-- choca con la montaña / obstáculo: explota en el punto de impacto
		if p.explode then explode(run, Combat, p, hit.Position.X - origin.X, hit.Position.Z - origin.Z) end
		return true
	end
	p.pos3 = from + delta
	p.x, p.z = p.pos3.X - origin.X, p.pos3.Z - origin.Z
	markHit(run, p.x, p.z, p.radius + 0.5)
	p.traveled += step
	if p.range and p.traveled >= p.range then
		if p.explode then explode(run, Combat, p, p.x, p.z) end
		return true
	end
	if math.abs(p.x) > run.map.half + 4 or math.abs(p.z) > run.map.half + 4 then return true end
	return false
end

function Behaviors.stepProjectiles(run, dt, Combat)
	local list = run.projectiles
	for i = #list, 1, -1 do
		local p = list[i]
		local remove = false
		if p.straight then
			if p.dirty then
				p.dirty = false
				local v = p.dir3 * p.speed
				Combat.fx(run, "M3", p.id, p.pos3.X, p.pos3.Y, p.pos3.Z, v.X, v.Y, v.Z, p.life, p.size, p.color[1], p.color[2], p.color[3], p.vis)
			end
			p.life -= dt
			if p.life <= 0 or stepStraight(run, Combat, p, dt) then
				Combat.fx(run, "MK", p.id) -- el cliente lo borra donde impactó
				table.remove(list, i)
			end
			continue
		end
		p.life -= dt
		if p.life <= 0 then remove = true end
		-- búsqueda guiada
		if not remove and p.homing then
			local t = p.target
			if not t or t.dead then t = Combat.nearest(run, p.x, p.z, 28, p.hits); p.target = t end
			if t then
				local dx, dz = t.x - p.x, t.z - p.z
				local d = math.max(0.01, math.sqrt(dx * dx + dz * dz))
				local nx, nz = p.dx + (dx / d - p.dx) * math.min(1, dt * 6), p.dz + (dz / d - p.dz) * math.min(1, dt * 6)
				local m = math.max(0.01, math.sqrt(nx * nx + nz * nz))
				p.dx, p.dz = nx / m, nz / m
				if run.tickN % 3 == 0 then p.dirty = true end
			end
		end
		-- retorno del bumerán
		if not remove and p.boomerang then
			if not p.returning and p.traveled >= p.range then
				p.returning = true; p.hits = {}; p.dirty = true
			end
			if p.returning then
				local dx, dz = run.px - p.x, run.pz - p.z
				local d = math.sqrt(dx * dx + dz * dz)
				if d < 2 then remove = true else p.dx, p.dz = dx / d, dz / d; p.dirty = true end
			end
		end
		if not remove then
			local step = p.speed * dt
			local ox, oz = p.x, p.z
			local nx, nz = ox + p.dx * step, oz + p.dz * step
			p.traveled += step
			-- barrido: candidatos cerca del punto medio
			local mx, mz = (ox + nx) / 2, (oz + nz) / 2
			local cands = Combat.inRadius(run, mx, mz, step / 2 + p.radius)
			table.sort(cands, function(a, b)
				return (a.x - ox) ^ 2 + (a.z - oz) ^ 2 < (b.x - ox) ^ 2 + (b.z - oz) ^ 2
			end)
			local sx, sz = nx - ox, nz - oz
			local sl = math.max(1e-6, sx * sx + sz * sz)
			for _, e in ipairs(cands) do
				if not remove and not e.dead and not p.hits[e.id] then
					local t = math.clamp(((e.x - ox) * sx + (e.z - oz) * sz) / sl, 0, 1)
					local cx, cz = ox + sx * t, oz + sz * t
					local rr = p.radius + e.radius
					if (e.x - cx) ^ 2 + (e.z - cz) ^ 2 <= rr * rr then
						p.hits[e.id] = true
						local c = ctx(p.w, p.ps, { amount = p.dmg })
						if p.shotgun then c.amount = p.dmg * math.clamp(1.5 - p.traveled / math.max(1, p.range), 0.5, 1.5) end
						if p.airborne then c.airborne = true end
						if p.explode then
							explode(run, Combat, p, e.x, e.z)
							remove = true
						else
							if p.poison then c.tags.poison = true; Combat.applyPoison(run, e, 2, p.weaponId) end
							if p.execChance and not (e.boss or e.elite) and run.rng.combat:chance(p.execChance) then c.amount = e.hp + 1 end
							Combat.hit(run, e, c)
							knock(run, e, ox, oz, p.ps.kb)
							if p.pierceLeft and p.pierceLeft > 0 then
								p.pierceLeft -= 1
							elseif p.bouncesLeft and p.bouncesLeft > 0 then
								local nt = bounceTarget(run, Combat, p, e)
								if nt then
									p.bouncesLeft -= 1
									local dx, dz = nt.x - e.x, nt.z - e.z
									local d = math.max(0.01, math.sqrt(dx * dx + dz * dz))
									p.dx, p.dz = dx / d, dz / d
									p.x, p.z = e.x, e.z
									nx, nz = e.x, e.z
									p.dirty = true
								else remove = true end
							elseif not p.pierceAll and not p.persistent then
								remove = true
							end
						end
					end
				end
			end
			if not remove then
				p.x, p.z = nx, nz
				markHit(run, p.x, p.z, p.radius + 0.5)
				if p.range and not p.boomerang and p.traveled >= p.range then
					if p.explode then explode(run, Combat, p, p.x, p.z) end
					remove = true
				end
				if math.abs(p.x) > run.map.half + 4 or math.abs(p.z) > run.map.half + 4 then remove = true end
			end
		end
		if p.dirty and not remove then p.dirty = false; sendProj(run, Combat, p) end
		if remove then table.remove(list, i) end
	end
end

-- ===== zonas persistentes con tick =====
local function addZone(run, z)
	if #run.zones >= ZONE_CAP then table.remove(run.zones, 1) end
	run.nextZoneId += 1
	z.id = run.nextZoneId
	table.insert(run.zones, z)
end

function Behaviors.stepZones(run, dt, Combat)
	local t = run.clock.t
	local list = run.zones
	for i = #list, 1, -1 do
		local z = list[i]
		z.life -= dt
		if z.life <= 0 then
			table.remove(list, i)
		elseif z.kind == "link" then
			-- el vínculo hace su propio tick en stepLinks
		elseif t >= z.nextTick then
			z.nextTick = t + z.interval
			markHit(run, z.x, z.z, z.radius)
			for _, e in ipairs(Combat.inRadius(run, z.x, z.z, z.radius)) do
				if z.kind == "well" then
					if not e.boss then e.pullTo = { z.x, z.z, e.elite and 4 or 9 } end
				end
				Combat.hit(run, e, ctx(z.w, z.ps, { amount = z.dmg, noLifesteal = true, lifestealTick = true }))
			end
		end
		if z.kind == "well" and z.life > 0 then
			for _, e in ipairs(Combat.inRadius(run, z.x, z.z, z.radius)) do
				if not e.boss then e.pullTo = { z.x, z.z, e.elite and 4 or 9 } end
			end
		end
	end
end

-- ===== comportamientos de disparo =====
local B = {}

local function projectileFire(opts)
	return function(run, Combat, w, ps)
		local dx, dz, target = aim(run, Combat, w, ps.range or w.def.range)
		if not dx then return false end
		local def = w.def
		local count = ps.count
		local angles = fanAngles(count, opts.spread or 12)
		if opts.fixedAngles then angles = fanAngles(count, opts.spread) end
		-- 2026-11-06 (bug de +1 proyectil): con 2 proyectiles el abanico los abría ±7° y NINGUNO iba derecho al
		-- objetivo, así que a distancia fallaban los dos. Ahora el 1º va siempre al objetivo y cada proyectil extra va
		-- a OTRO enemigo cercano (el siguiente más próximo); si no hay más enemigos, sale abierto alrededor del 1º.
		local tgts = { target }
		if count > 1 and not opts.shotgun and not opts.fixedAngles then
			local step = math.rad(opts.spread or 12) / 2
			for i = 1, count do
				local k = math.floor(i / 2)
				angles[i] = (i == 1) and 0 or ((i % 2 == 0) and k or -k) * step
			end
			if target then
				local list = Combat.inRadius(run, run.px, run.pz, ps.range or def.range or 40)
				table.sort(list, function(a, b) return (a.x - run.px) ^ 2 + (a.z - run.pz) ^ 2 < (b.x - run.px) ^ 2 + (b.z - run.pz) ^ 2 end)
				local n = 1
				for _, e in ipairs(list) do
					if n >= count then break end
					if e ~= target then n += 1; tgts[n] = e end
				end
			end
		end
		local roll = nil
		for i = 1, count do
			local rx, rz = rot(dx, dz, angles[i])
			local own = tgts[i]
			if i > 1 and own then
				-- proyectil extra con su propio objetivo: sale derecho hacia él
				local ex, ez = own.x - run.px, own.z - run.pz
				local ed = math.max(0.01, math.sqrt(ex * ex + ez * ez))
				rx, rz = ex / ed, ez / ed
			end
			local dmg = ps.dmg
			if opts.dice then
				roll = run.rng.combat:integer(1, 6)
				-- 2026-11-11: la tirada multiplica el daño base (antes el daño era solo la tirada 1-6 e ignoraba el base y las mejoras de daño global)
				dmg = ps.dmg * roll / 3.5
				if roll == 6 then w.ownCrit = (w.ownCrit or 0) + def.extra.sixCritBonus end
			end
			if opts.shotgun then
				dmg = ps.dmg * 1 -- daño por perdigón
			end
			local np = spawnProj(run, w, ps, {
				dx = rx, dz = rz, speed = ps.speed, radius = (opts.radius or 1.4) * ps.size,
				dmg = dmg, life = opts.life or ((def.range or 40) / math.max(1, ps.speed) + 0.2),
				range = (opts.rangeOverride or def.range), size = (opts.visualSize or 1) * ps.size,
				pierceLeft = opts.pierce and (def.pierce) or nil,
				bouncesLeft = opts.bounce and ps.bounces or nil,
				bounceRadius = def.radius > 0 and def.radius or 14,
				homing = opts.homing, explode = opts.explode and def.radius or nil,
				poison = opts.poison, boomerang = opts.boomerang, persistent = opts.persistent,
				x = run.px, z = run.pz, color = opts.color, dirty = true,
				execChance = opts.execChance, pierceAll = opts.pierceAll, shotgun = opts.shotgun, vis = opts.vis,
			})
			if np and opts.straight then
				if i > 1 and tgts[i] then setupStraight(run, np, tgts[i], 0) else setupStraight(run, np, target, angles[i]) end
			end
		end
		return true
	end
end

B.fireball = projectileFire({ explode = true, color = { 255, 120, 40 }, visualSize = 1.4, radius = 1.6 })
B.bounce = projectileFire({ bounce = true, color = { 235, 230, 210 }, radius = 1.4 })
B.pierce = projectileFire({ pierce = true, color = { 190, 150, 90 }, radius = 1.2 })
B.burst = projectileFire({ bounce = true, color = { 255, 230, 120 }, spread = 10, radius = 1 })
B.rifle = projectileFire({ pierce = true, color = { 120, 220, 255 }, spread = 4, radius = 1.4, rangeOverride = 90 })
B.rocket = projectileFire({ explode = true, straight = true, color = { 255, 90, 60 }, visualSize = 1.5, radius = 1.6, spread = 20 })
B.shotgun = projectileFire({ shotgun = true, color = { 255, 180, 90 }, spread = 36, radius = 1.2, visualSize = 0.7 })
B.dagger = projectileFire({ homing = true, bounce = true, color = { 200, 210, 230 }, spread = 24, radius = 1.2, visualSize = 0.8 })
B.bloodmagic = projectileFire({ color = { 200, 30, 50 }, spread = 14, radius = 1.6, visualSize = 1.2 })
B.flask = projectileFire({ explode = true, poison = true, color = { 110, 220, 90 }, radius = 1.4, visualSize = 1.2 })
B.dice = projectileFire({ dice = true, bounce = true, color = { 245, 245, 245 }, spread = 14, radius = 1.5, visualSize = 1.2 })
B.boomerang = projectileFire({ boomerang = true, color = { 220, 160, 70 }, spread = 22, radius = 2, life = 4, persistent = true, visualSize = 1.4 })
B.tornado = function(run, Combat, w, ps)
	local dx, dz, target = aim(run, Combat, w, 40)
	if not dx then return false end
	local angles = fanAngles(ps.count, 30)
	for i = 1, ps.count do
		local rx, rz = rot(dx, dz, angles[i])
		spawnProj(run, w, ps, { dx = rx, dz = rz, speed = ps.speed, radius = w.def.radius * ps.size * 0.5, dmg = ps.dmg,
			life = 3 * ps.dur, range = 60, size = 3 * ps.size, persistent = true, tornado = true, color = { 200, 230, 255 }, x = run.px, z = run.pz, dirty = true, pierceAll = true })
	end
	return true
end

-- Aura
B.aura = function(run, Combat, w, ps)
	local r = w.def.radius * ps.size
	local list = Combat.inRadius(run, run.px, run.pz, r)
	local c = (w.def.extra and w.def.extra.color) or { 255, 160, 60 }
	markHit(run, run.px, run.pz, r)
	Combat.fx(run, "b", run.px, 0.5, run.pz, r, c[1], c[2], c[3], 0.3)
	for _, e in ipairs(list) do Combat.hit(run, e, ctx(w, ps, { noLifesteal = true, lifestealTick = true })) end
	return true
end

-- Aura 67: un pulso por ataque (gesto "six seven" + sonido en cada uno); sale aunque no haya enemigos
B.sixseven = function(run, Combat, w, ps)
	local r = w.def.radius * ps.size
	local list = Combat.inRadius(run, run.px, run.pz, r)
	markHit(run, run.px, run.pz, r)
	local c = (w.def.extra and w.def.extra.color) or { 170, 90, 255 }
	Combat.fx(run, "b", run.px, 0.5, run.pz, r, c[1], c[2], c[3], 0.35)
	for _, e in ipairs(list) do Combat.hit(run, e, ctx(w, ps, { noLifesteal = true, lifestealTick = true })) end
	return true
end

-- Zona de escarcha: congela y daña próximos
B.frost = function(run, Combat, w, ps)
	local r = w.def.radius * ps.size
	local list = Combat.inRadius(run, run.px, run.pz, r)
	markHit(run, run.px, run.pz, r)
	Combat.fx(run, "b", run.px, 0.5, run.pz, r, 140, 220, 255, 0.5)
	for _, e in ipairs(list) do
		Combat.applyFreeze(run, e, 1.2 * ps.dur)
		Combat.hit(run, e, ctx(w, ps, { noLifesteal = true, lifestealTick = true }))
	end
	return true
end

-- Escudo de choque: onda de daño; el bloqueo real se resuelve en tryBlock
B.shockshield = function(run, Combat, w, ps)
	w.state.readyAt = run.clock.t -- listo para bloquear
	local list = Combat.inRadius(run, run.px, run.pz, w.def.radius * ps.size)
	markHit(run, run.px, run.pz, w.def.radius * ps.size)
	Combat.fx(run, "b", run.px, 0.5, run.pz, w.def.radius * ps.size, 120, 200, 255, 0.3)
	for _, e in ipairs(list) do
		Combat.hit(run, e, ctx(w, ps, { noLifesteal = true, lifestealTick = true }))
		knock(run, e, run.px, run.pz, ps.kb)
	end
	return true
end

function Behaviors.tryBlock(run, attacker)
	if not attacker or not run.facing then return false end
	for _, w in ipairs(run.weapons) do
		if w.id == "weapon_09" then
			local ready = w.state.blockReadyAt or 0
			if run.clock.t >= ready then
				local dx, dz = attacker.x - run.px, attacker.z - run.pz
				local d = math.max(0.01, math.sqrt(dx * dx + dz * dz))
				local dot = (dx / d) * run.facing.X + (dz / d) * run.facing.Z
				if dot >= math.cos(math.rad(60)) then
					w.state.blockReadyAt = run.clock.t + 3
					if run.m then run.m.add.blocks += 1 end
					return true
				end
			end
		end
	end
	return false
end

-- Cadena de rayos
B.chain = function(run, Combat, w, ps)
	local first = Combat.nearest(run, run.px, run.pz, w.def.range)
	if not first then
		-- sin objetivo: el rayo sale igual hacia adelante
		local dx, dz = aim(run, Combat, w, w.def.range)
		local len = w.def.range * 0.6
		Combat.fx(run, "t", run.px, 3, run.pz, run.px + dx * len, 2, run.pz + dz * len, 255, 240, 120, 0.4, 0.2)
		markHit(run, run.px + dx * len, run.pz + dz * len, 2)
		markHit(run, run.px + dx * len * 0.5, run.pz + dz * len * 0.5, 2)
		return true
	end
	local visited = {}
	local cur, fromx, fromz = first, run.px, run.pz
	local jumps = ps.bounces
	local n = 0
	while cur and n <= jumps do
		visited[cur.id] = true
		Combat.fx(run, "t", fromx, 3, fromz, cur.x, 2, cur.z, 255, 240, 120, 0.4, 0.2)
		markHit(run, cur.x, cur.z, 2)
		Combat.hit(run, cur, ctx(w, ps))
		fromx, fromz = cur.x, cur.z
		cur = Combat.nearest(run, fromx, fromz, w.def.radius * ps.size, visited)
		n += 1
	end
	return true
end

-- Cuerpo a cuerpo: barrido, katana, ejecutora, riesgo
local function arcHit(run, Combat, w, ps, dx, dz, radius, arcDeg, visited, mult)
	Combat.fx(run, "t", run.px, 2, run.pz, run.px + dx * radius, 2, run.pz + dz * radius, 255, 255, 255, radius * 0.6, 0.15)
	markHit(run, run.px + dx * radius * 0.55, run.pz + dz * radius * 0.55, radius * 0.6)
	local cosHalf = math.cos(math.rad(arcDeg / 2))
	local anyHit = false
	for _, e in ipairs(Combat.inRadius(run, run.px, run.pz, radius)) do
		if not visited[e.id] then
			local ex, ez = e.x - run.px, e.z - run.pz
			local d = math.max(0.01, math.sqrt(ex * ex + ez * ez))
			if (ex / d) * dx + (ez / d) * dz >= cosHalf or d < 2.5 then
				visited[e.id] = true
				anyHit = true
				Combat.hit(run, e, ctx(w, ps, { amount = ps.dmg * (mult or 1) }))
				knock(run, e, run.px, run.pz, ps.kb)
			end
		end
	end
	return anyHit
end

B.sweep = function(run, Combat, w, ps)
	local dx, dz = faceDir(run, Combat, w, ps)
	local visited = {}
	local angles = fanAngles(ps.count, 360 * (1 - 1 / math.max(1, ps.count)))
	if ps.count == 1 then angles = { 0 } end
	for i = 1, ps.count do
		local rx, rz = rot(dx, dz, angles[i])
		arcHit(run, Combat, w, ps, rx, rz, w.def.radius * ps.size, w.def.extra.arc, visited)
	end
	return true
end

B.riskblade = function(run, Combat, w, ps)
	local dx, dz, t = aim(run, Combat, w, w.def.range * ps.size + 6)
	if not dx then return false end
	local maxHp = run.stats:get("maxHp")
	local risk = 1 + 1.0 * (1 - math.clamp(run.hp / maxHp, 0, 1))
	local visited = {} -- los dos cortes comparten víctimas: sin daño doble por la misma geometría
	arcHit(run, Combat, w, ps, dx, dz, w.def.radius * ps.size, 140, visited, risk)
	arcHit(run, Combat, w, ps, -dx, -dz, w.def.radius * ps.size, 140, visited, risk)
	return true
end

B.executioner = function(run, Combat, w, ps)
	local dx, dz, t = aim(run, Combat, w, w.def.range * ps.size + 4)
	if not dx then return false end
	local chance = math.min(0.20, 0.02 + 0.05 * run.stats:get("critChance"))
	local len = w.def.range * ps.size
	Combat.fx(run, "t", run.px, 2, run.pz, run.px + dx * len, 2, run.pz + dz * len, 255, 60, 60, 1.2, 0.2)
	for k = 1, 3 do markHit(run, run.px + dx * len * k / 3, run.pz + dz * len * k / 3, 3 * ps.size) end
	for _, e in ipairs(Combat.inRadius(run, run.px + dx * len / 2, run.pz + dz * len / 2, len / 2 + 1)) do
		local ex, ez = e.x - run.px, e.z - run.pz
		local along = ex * dx + ez * dz
		local perp = math.abs(ex * dz - ez * dx)
		if along >= 0 and along <= len and perp <= 3 * ps.size + e.radius then
			local c = ctx(w, ps)
			if run.rng.combat:chance(chance) then
				if e.boss or e.elite then c.amount = ps.dmg * 2 else c.amount = e.hp + 1 end
			end
			Combat.hit(run, e, c)
		end
	end
	return true
end

B.katana = function(run, Combat, w, ps)
	local excl = {}
	local any = false
	for i = 1, ps.count do
		local t = Combat.nearest(run, run.px, run.pz, w.def.range * ps.size, excl)
		if not t then break end
		excl[t.id] = true
		any = true
		Combat.fx(run, "t", run.px, 2, run.pz, t.x, 2, t.z, 240, 240, 255, 0.5, 0.15)
		markHit(run, t.x, t.z, 2)
		Combat.hit(run, t, ctx(w, ps))
	end
	if not any then
		-- sin objetivo: corta igual hacia adelante
		local dx, dz = aim(run, Combat, w, w.def.range * ps.size)
		local len = math.min(w.def.range * ps.size, 12)
		Combat.fx(run, "t", run.px, 2, run.pz, run.px + dx * len, 2, run.pz + dz * len, 240, 240, 255, 0.5, 0.15)
		markHit(run, run.px + dx * len * 0.5, run.pz + dz * len * 0.5, len * 0.5)
	end
	return true
end

-- Vínculo espacial
B.link = function(run, Combat, w, ps)
	local t = Combat.nearest(run, run.px, run.pz, w.def.range)
	if not t then
		local dx, dz = aim(run, Combat, w, w.def.range)
		local len = w.def.range * 0.5
		Combat.fx(run, "t", run.px, 3, run.pz, run.px + dx * len, 2, run.pz + dz * len, 190, 120, 255, 0.5, 0.45)
		markHit(run, run.px + dx * len, run.pz + dz * len, 2)
		return true
	end
	addZone(run, { kind = "link", w = w, ps = ps, target = t, x = t.x, z = t.z, radius = 0.1, life = 3 * ps.dur, interval = 0.5, nextTick = run.clock.t + 0.5, dmg = ps.dmg })
	return true
end

function Behaviors.stepLinks(run, dt, Combat)
	for i = #run.zones, 1, -1 do
		local z = run.zones[i]
		if z.kind == "link" then
				local tgt = z.target
			if not tgt or tgt.dead or tgt.removed then
				table.remove(run.zones, i)
			elseif run.clock.t >= z.nextTick then
				z.nextTick += z.interval
				Combat.fx(run, "t", run.px, 3, run.pz, tgt.x, 2, tgt.z, 190, 120, 255, 0.5, 0.45)
				local sx, sz = tgt.x - run.px, tgt.z - run.pz
				local sl = math.max(1e-6, sx * sx + sz * sz)
				for _, e in ipairs(Combat.inRadius(run, (run.px + tgt.x) / 2, (run.pz + tgt.z) / 2, math.sqrt(sl) / 2 + 3)) do
					local t = math.clamp(((e.x - run.px) * sx + (e.z - run.pz) * sz) / sl, 0, 1)
					local cx, cz = run.px + sx * t, run.pz + sz * t
					local rr = z.w.def.radius * z.ps.size
					if (e.x - cx) ^ 2 + (e.z - cz) ^ 2 <= (rr + e.radius) ^ 2 then
						Combat.hit(run, e, ctx(z.w, z.ps, { amount = z.dmg, noLifesteal = true, lifestealTick = true }))
					end
				end
			end
		end
	end
end

-- Pozo gravitatorio
B.well = function(run, Combat, w, ps)
	local t = Combat.nearest(run, run.px, run.pz, w.def.range)
	if not t then
		-- sin objetivo: el pozo cae adelante del personaje
		local dx, dz = aim(run, Combat, w, w.def.range)
		local lim = run.map.half - 3
		t = { x = math.clamp(run.px + dx * w.def.range * 0.5, -lim, lim), z = math.clamp(run.pz + dz * w.def.range * 0.5, -lim, lim) }
	end
	Combat.fx(run, "CP", "wellSmall", t.x, t.z, w.def.radius * ps.size, 3 * ps.dur)
	addZone(run, { kind = "well", w = w, ps = ps, x = t.x, z = t.z, radius = w.def.radius * ps.size, life = 3 * ps.dur, interval = 0.5, nextTick = run.clock.t + 0.5, dmg = ps.dmg })
	return true
end

-- Rastro de fuego (continuo, no usa cooldown de disparo)
function B.trailStep(run, Combat, w, ps)
	local st = w.state
	if not st.lx then st.lx, st.lz = run.px, run.pz end
	local d = math.sqrt((run.px - st.lx) ^ 2 + (run.pz - st.lz) ^ 2)
	if d >= 2 then
		st.lx, st.lz = run.px, run.pz
		local r = w.def.radius * ps.size
		local c = (w.def.extra and w.def.extra.color) or { 255, 120, 30 }
		Combat.fx(run, "z", run.px, 0.2, run.pz, r, c[1], c[2], c[3], 4 * ps.dur)
		for i = 1, math.max(1, ps.count) do
			local ox, oz = 0, 0
			if i > 1 then ox, oz = rot(0, 2.5 * (i - 1), (i % 2 == 0) and 1.2 or -1.2) end
			addZone(run, { kind = "trail", w = w, ps = ps, x = run.px + ox, z = run.pz + oz, radius = r, life = 4 * ps.dur, interval = 1, nextTick = run.clock.t + 0.5, dmg = ps.dmg })
		end
	end
end

-- Orbitales (rocas y hachas)
local attackPulse -- se define más abajo (sonido + animación del golpe)
local function orbitStep(run, Combat, w, ps, window)
	local st = w.state
	local t = run.clock.t
	local count = ps.count
	if window then
		if not st.windowEnd or t > st.windowEnd then
			if t >= (st.nextWindow or 0) then
				st.windowEnd = t + window * ps.dur
				st.nextWindow = t + window * ps.dur + ps.cd
				st.t0 = t
				local ex = w.def.extra or {}
				local c = ex.color or { 255, 160, 60 }
				local spd = w.def.behaviorId == "beyblade" and w.def.speed * ps.speed / math.max(1, w.def.speed) or 2.6
				Combat.fx(run, "o", w.id, count, w.def.radius * ps.size, spd, st.windowEnd - t, c[1], c[2], c[3], 1.6, ex.vis)
				if w.def.behaviorId == "beyblade" then
					-- un giro más (pasiva de Ballerina: cada 5 giros atrae y pega más fuerte)
					st.spins = (st.spins or 0) + 1
					st.vortex = run.classDef.passiveId == "ballerina_vortex" and st.spins % 5 == 0
					if st.vortex then Combat.fx(run, "CP", "vortex", run.px, run.pz, 18) end
					attackPulse(run, w, Combat)
				end
			end
		end
		if not st.windowEnd or t > st.windowEnd then return end
		if st.vortex then
			for _, e in ipairs(Combat.inRadius(run, run.px, run.pz, 18)) do
				if not e.boss then e.pullTo = { run.px, run.pz, 16 } end
			end
		end
	else
		if st.count ~= count or st.size ~= ps.size then
			st.count, st.size, st.t0 = count, ps.size, t
			local ex = w.def.extra or {}
			local c = ex.color or { 160, 150, 140 }
			Combat.fx(run, "o", w.id, count, w.def.radius * ps.size, w.def.speed * ps.speed / math.max(1, w.def.speed), 1e6, c[1], c[2], c[3], 1.8, ex.vis)
		end
	end
	st.hitAt = st.hitAt or {}
	local ang0 = (t - (st.t0 or t)) * (window and 2.6 or (w.def.speed * (ps.speed / math.max(1, w.def.speed))))
	local radius = w.def.radius * ps.size
	if w.def.behaviorId == "beyblade" then
		-- tutú de Ballerina: del tamaño del personaje; corta a todo lo que alcanza (borde + 2,2 studs, como antes)
		markHit(run, run.px, run.pz, radius + 2.2)
		for _, e in ipairs(Combat.inRadius(run, run.px, run.pz, radius + 2.2)) do
			local key = e.id * 16
			if t >= (st.hitAt[key] or 0) then
				-- la cantidad (q) ya no son puntos de la órbita: cuantos más, más seguido corta
				st.hitAt[key] = t + ((w.def.extra and w.def.extra.rehit) or 0.3) / math.max(1, count)
				Combat.hit(run, e, ctx(w, ps, { noLifesteal = true, lifestealTick = true, amount = ps.dmg * (st.vortex and 1.75 or 1) }))
				knock(run, e, run.px, run.pz, ps.kb)
			end
		end
		if run.tickN % 40 == 0 then st.hitAt = {} end
		return
	end
	for i = 1, count do
		local ang = ang0 + (i - 1) * (2 * math.pi / count)
		local ox, oz = run.px + math.cos(ang) * radius, run.pz + math.sin(ang) * radius
		local hitR = (window and w.def.behaviorId ~= "beyblade") and (w.def.radius * 0.5 * ps.size) or 2.2
		markHit(run, ox, oz, hitR)
		for _, e in ipairs(Combat.inRadius(run, ox, oz, hitR)) do
			local key = e.id * 16 + i
			if t >= (st.hitAt[key] or 0) then
				st.hitAt[key] = t + ((w.def.extra and w.def.extra.rehit) or 0.3)
				Combat.hit(run, e, ctx(w, ps, { noLifesteal = true, lifestealTick = true, amount = ps.dmg * (st.vortex and 1.75 or 1) }))
				knock(run, e, run.px, run.pz, ps.kb)
			end
		end
	end
	if run.tickN % 40 == 0 then st.hitAt = {} end -- limpia entradas viejas
end

-- ===== Armas propias de los personajes =====
local function color(w, d) return (w.def.extra and w.def.extra.color) or d end

-- golpe en arco sin línea de efecto (el cliente dibuja el puño/bate/espada)
local function meleeArc(run, Combat, w, ps, dx, dz, radius, arcDeg, visited, mult, kb)
	local cosHalf = math.cos(math.rad(math.min(359, arcDeg) / 2))
	if arcDeg >= 360 then markHit(run, run.px, run.pz, radius)
	else markHit(run, run.px + dx * radius * 0.55, run.pz + dz * radius * 0.55, radius * 0.6) end
	local any = false
	for _, e in ipairs(Combat.inRadius(run, run.px, run.pz, radius)) do
		if not visited[e.id] then
			local ex, ez = e.x - run.px, e.z - run.pz
			local d = math.max(0.01, math.sqrt(ex * ex + ez * ez))
			if arcDeg >= 360 or (ex / d) * dx + (ez / d) * dz >= cosHalf or d < 2.5 then
				visited[e.id] = true
				any = true
				Combat.hit(run, e, ctx(w, ps, { amount = ps.dmg * (mult or 1) }))
				knock(run, e, run.px, run.pz, kb or ps.kb)
			end
		end
	end
	return any
end

local function swingFx(run, Combat, vis, dx, dz, radius, arc, life, c, side)
	Combat.fx(run, "s", vis, run.px, run.pz, dx, dz, radius, arc, life, c[1], c[2], c[3], side or 1)
end

-- Manos (Noobini): puñetazos alternados
B.punch = function(run, Combat, w, ps)
	local dx, dz = faceDir(run, Combat, w, ps)
	local st, visited, c = w.state, {}, color(w, { 255, 214, 60 })
	st.side = -(st.side or 1)
	for i = 1, ps.count do
		local rx, rz = rot(dx, dz, (i - 1) * 0.35 * ((i % 2 == 0) and 1 or -1))
		meleeArc(run, Combat, w, ps, rx, rz, w.def.radius * ps.size, w.def.extra.arc, visited)
		swingFx(run, Combat, "fist", rx, rz, w.def.radius * ps.size, 0, 0.2, c, st.side)
	end
	return true
end

-- Mordisco (Tralalero): mandíbulas que se cierran adelante
B.bite = function(run, Combat, w, ps)
	local dx, dz = faceDir(run, Combat, w, ps)
	local r = w.def.radius * ps.size
	for i = 1, ps.count do
		local rx, rz = rot(dx, dz, (i - 1) * 0.6 * ((i % 2 == 0) and 1 or -1))
		meleeArc(run, Combat, w, ps, rx, rz, r, w.def.extra.arc, {})
		swingFx(run, Combat, "jaws", rx, rz, r, 0, 0.32, color(w, { 245, 245, 250 }))
	end
	return true
end

-- Cabezazos (Lirilì): un solo golpe frontal con mucho empuje
B.headbutt = function(run, Combat, w, ps)
	local dx, dz = faceDir(run, Combat, w, ps)
	local r = w.def.radius * ps.size
	meleeArc(run, Combat, w, ps, dx, dz, r, w.def.extra.arc, {})
	local c = color(w, { 120, 190, 80 })
	swingFx(run, Combat, "head", dx, dz, r, 0, 0.25, c)
	Combat.fx(run, "b", run.px + dx * r * 0.6, 2, run.pz + dz * r * 0.6, 3 * ps.size, 255, 255, 255, 0.25)
	return true
end

-- Bate (Tung): batazo en arco amplio
B.bat = function(run, Combat, w, ps)
	local dx, dz = faceDir(run, Combat, w, ps)
	local st, visited, c = w.state, {}, color(w, { 199, 117, 56 })
	st.side = -(st.side or 1)
	local angles = fanAngles(ps.count, 360 * (1 - 1 / math.max(1, ps.count)))
	if ps.count == 1 then angles = { 0 } end
	for i = 1, ps.count do
		local rx, rz = rot(dx, dz, angles[i])
		meleeArc(run, Combat, w, ps, rx, rz, w.def.radius * ps.size, w.def.extra.arc, visited)
		swingFx(run, Combat, "bat", rx, rz, w.def.radius * ps.size, w.def.extra.arc, 0.28, c, st.side)
	end
	return true
end

-- Dos espadas (Cappuccino): dos cortes cruzados; cada espada golpea por separado
B.twinblades = function(run, Combat, w, ps)
	local dx, dz = faceDir(run, Combat, w, ps)
	local c = color(w, { 210, 215, 225 })
	local r = w.def.radius * ps.size
	for i = 1, ps.count do
		local bx, bz = rot(dx, dz, (i - 1) * (2 * math.pi / math.max(1, ps.count)))
		for _, side in ipairs({ -1, 1 }) do
			local rx, rz = rot(bx, bz, side * 0.25)
			meleeArc(run, Combat, w, ps, rx, rz, r, w.def.extra.arc, {})
			swingFx(run, Combat, "sword", rx, rz, r, w.def.extra.arc, 0.22, c, side)
		end
	end
	return true
end

-- Patadas (Patapim)
B.kick = function(run, Combat, w, ps)
	local dx, dz = faceDir(run, Combat, w, ps)
	local visited, c = {}, color(w, { 70, 130, 60 })
	for i = 1, ps.count do
		local rx, rz = rot(dx, dz, (i - 1) * 0.5 * ((i % 2 == 0) and 1 or -1))
		meleeArc(run, Combat, w, ps, rx, rz, w.def.radius * ps.size, w.def.extra.arc, visited)
		swingFx(run, Combat, "foot", rx, rz, w.def.radius * ps.size, 0, 0.25, c)
	end
	return true
end

-- Piñas y patadas (Te Te Te Sahur): dos puñetazos y una patada fuerte
B.combo = function(run, Combat, w, ps)
	local dx, dz = faceDir(run, Combat, w, ps)
	local st, c = w.state, color(w, { 230, 170, 90 })
	st.n = ((st.n or 0) % 3) + 1
	local kickHit = st.n == 3
	local r = w.def.radius * ps.size * (kickHit and 1.2 or 1)
	local visited = {}
	for i = 1, ps.count do
		local rx, rz = rot(dx, dz, (i - 1) * 0.4 * ((i % 2 == 0) and 1 or -1))
		meleeArc(run, Combat, w, ps, rx, rz, r, w.def.extra.arc, visited, kickHit and 1.8 or 1, kickHit and ps.kb * 3 or ps.kb)
		swingFx(run, Combat, kickHit and "foot" or "fist", rx, rz, r, 0, 0.2, c, (st.n == 1) and 1 or -1)
	end
	return true
end

-- Embestida (Tralalero / Tralalita): atraviesa enemigos en línea y aparece al otro lado
B.dash = function(run, Combat, w, ps)
	if w.state.dashBack then return false end -- todavía no volvió de la embestida anterior
	local len = w.def.range * ps.size
	local dx, dz, target = aim(run, Combat, w, len + 6)
	if not dx then return false end
	local char = run.player and run.player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	local sx, sz = run.px, run.pz
	local ex, ez = sx + dx * len, sz + dz * len
	local lim = run.map.half - 3
	ex, ez = math.clamp(ex, -lim, lim), math.clamp(ez, -lim, lim)
	ex, ez = MapService.resolve(run.map, ex, ez, 1.5)
	local ddx, ddz = ex - sx, ez - sz
	local dl = math.sqrt(ddx * ddx + ddz * ddz)
	if dl < 2 then return false end
	local ux, uz = ddx / dl, ddz / dl
	local width = w.def.radius * ps.size
	for _, e in ipairs(Combat.inRadius(run, (sx + ex) / 2, (sz + ez) / 2, dl / 2 + width + 2)) do
		local rx, rz = e.x - sx, e.z - sz
		local along = rx * ux + rz * uz
		local perp = math.abs(rx * uz - rz * ux)
		if along >= -1 and along <= dl + 1 and perp <= width + e.radius then
			Combat.hit(run, e, ctx(w, ps))
		end
	end
	local c = color(w, { 70, 140, 255 })
	for k = 0, 4 do markHit(run, sx + ddx * k / 4, sz + ddz * k / 4, width + 1) end
	Combat.fx(run, "t", sx, 2, sz, ex, 2, ez, c[1], c[2], c[3], width * 1.4, 0.35)
	Combat.fx(run, "CD", sx, sz, ex, ez, width * 1.4)
	Combat.fx(run, "b", ex, 1, ez, width + 1, c[1], c[2], c[3], 0.3)
	local y = hrp.Position.Y
	local pos = run.origin + Vector3.new(ex, run.map.height(ex, ez) + 3, ez)
	hrp.CFrame = CFrame.lookAt(pos, pos + Vector3.new(ux, 0, uz))
	run.px, run.pz = ex, ez
	run.invulnUntil = math.max(run.invulnUntil or 0, run.clock.t + 0.75)
	-- después de embestir vuelve nadando a donde estaba (también golpea a la vuelta)
	w.state.dashBack = { at = run.clock.t + 0.35, x = sx, z = sz }
	return true
end

local function dashReturn(run, Combat, w, ps)
	local back = w.state.dashBack
	w.state.dashBack = nil
	local char = run.player and run.player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or run.hp <= 0 then return end
	local sx, sz = run.px, run.pz
	local ex, ez = MapService.resolve(run.map, back.x, back.z, 1.5)
	local ddx, ddz = ex - sx, ez - sz
	local dl = math.sqrt(ddx * ddx + ddz * ddz)
	if dl < 1 then return end
	local ux, uz = ddx / dl, ddz / dl
	local width = w.def.radius * ps.size
	for _, e in ipairs(Combat.inRadius(run, (sx + ex) / 2, (sz + ez) / 2, dl / 2 + width + 2)) do
		local rx, rz = e.x - sx, e.z - sz
		local along = rx * ux + rz * uz
		local perp = math.abs(rx * uz - rz * ux)
		if along >= -1 and along <= dl + 1 and perp <= width + e.radius then
			Combat.hit(run, e, ctx(w, ps, { amount = ps.dmg * 0.5 }))
		end
	end
	local c = color(w, { 70, 140, 255 })
	Combat.fx(run, "t", sx, 2, sz, ex, 2, ez, c[1], c[2], c[3], width, 0.3)
	local pos = run.origin + Vector3.new(ex, run.map.height(ex, ez) + 3, ez)
	hrp.CFrame = CFrame.lookAt(pos, pos + Vector3.new(-ux, 0, -uz))
	run.px, run.pz = ex, ez
end

-- Diezmar (La Vaca Saturno Saturnita): carga breve y giro; el borde hace daño completo y cura
B.decimate = function(run, Combat, w, ps)
	local r = w.def.radius * ps.size
	local ex = w.def.extra
	w.state.pendingAt = run.clock.t + ex.windup
	local c = color(w, { 220, 40, 50 })
	-- 2026-11-05: sin aviso en el piso durante la carga (el usuario lo veía como un círculo rojo raro); solo sale el anillo al girar
	return true
end

local function resolveDecimate(run, Combat, w, ps)
	w.state.pendingAt = nil
	local ex = w.def.extra
	local r = w.def.radius * ps.size
	local inner = r * ex.inner
	local c = color(w, { 220, 40, 50 })
	-- el anillo de Saturno sale girando y se expande hasta el borde
	swingFx(run, Combat, "ring", 1, 0, r, 360, 0.45, c)
	Combat.fx(run, "b", run.px, 1, run.pz, r, 120, 160, 230, 0.35)
	markHit(run, run.px, run.pz, r)
	local outerHits = 0
	for _, e in ipairs(Combat.inRadius(run, run.px, run.pz, r)) do
		local d = math.sqrt((e.x - run.px) ^ 2 + (e.z - run.pz) ^ 2)
		local outer = d + e.radius * 0.5 >= inner
		Combat.hit(run, e, ctx(w, ps, { amount = ps.dmg * (outer and 1 or 0.4) }))
		knock(run, e, run.px, run.pz, 2)
		if outer and not e.dead then outerHits += 1 end
	end
	if outerHits > 0 then
		local maxHp = run.stats:get("maxHp")
		run.hp = math.min(maxHp, run.hp + ex.heal * math.min(outerHits, 5))
	end
end

-- Proyectiles con modelo propio (bananas, paraguas, cohetes, misiles, palas, carteles, sandías, pescados)
B.sigproj = function(run, Combat, w, ps)
	local f = w.state.fire
	if not f then
		local ex = w.def.extra or {}
		local straight = ex.vis == "missile" or ex.vis == "rocket" -- misiles y cohetes: rectos en 3D
		f = projectileFire({ vis = ex.vis, explode = ex.explode, homing = (not straight) and ex.homing or nil, straight = straight, bounce = ex.bounce, pierce = ex.pierce,
			color = ex.color, spread = ex.spread or 14, radius = 1.6, visualSize = 1 })
		w.state.fire = f
	end
	return f(run, Combat, w, ps)
end

-- ===== API pública =====
local CONTINUOUS = { trail = true, orbit = true, axe = true }

-- sonido propio de cada arma (el cliente lo reproduce con UI/Sfx). Armas propias = una por personaje.
local WEAPON_SND = {
	sig_01 = "punch", sig_02 = "fire", sig_03 = "bonk", sig_04 = "bat", sig_05 = "twin", sig_06 = "banana", sig_07 = "spin",
	sig_08 = "throw", sig_09 = "rocket", sig_10 = "kick", sig_11 = "missile", sig_12 = "combo", sig_13 = "bite", sig_14 = "dash",
	sig_15 = "axe", sig_16 = "shovel", sig_17 = "sign", sig_18 = "splat", sig_19 = "slap", sig_20 = "sixseven",
	weapon_01 = "fire", weapon_02 = "slash", weapon_03 = "zap", weapon_04 = "fireball", weapon_05 = "bonk", weapon_06 = "throw",
	weapon_07 = "bow", weapon_08 = "gun", weapon_09 = "boom", weapon_10 = "aura", weapon_11 = "axe", weapon_12 = "spin",
	weapon_13 = "zap", weapon_14 = "rifle", weapon_15 = "rocket", weapon_16 = "shotgun", weapon_17 = "dagger", weapon_18 = "ice",
	weapon_19 = "wind", weapon_20 = "heavy", weapon_21 = "magic", weapon_22 = "magic", weapon_23 = "glass", weapon_24 = "katana",
	weapon_25 = "dice", weapon_26 = "slash",
}
-- armas continuas (rastro, rocas, hacha, giro, aura): suenan cada cierto tiempo
local CONT_SND_EVERY = { trail = 1.4, orbit = 1.8, axe = 1.2, aura = 1.8 }
local CONT_SND_BY_ID = {}

-- avisa al cliente: Snd = sonido de esta arma; Atk = animación de golpe (máx. 4/s) mirando al objetivo (AtkDir)
attackPulse = function(run, w, Combat, soundOnly)
	if w.def.behaviorId == "aura" and not soundOnly then return end -- el aura daña seguido: solo suena cada 1,8 s
	local ch = run.player and run.player.Character
	local m = ch and ch:FindFirstChild("BrainrotSkin")
	if not m then return end
	local now = os.clock()
	w.state.sndAt = w.state.sndAt or 0
	if now - w.state.sndAt >= 0.15 then
		w.state.sndAt = now
		m:SetAttribute("AtkSnd", WEAPON_SND[w.id] or "magic")
		m:SetAttribute("Snd", ((m:GetAttribute("Snd") or 0) + 1) % 10000)
	end
	if soundOnly or now - (run.atkPulseAt or 0) < 0.25 then return end
	run.atkPulseAt = now
	local dir
	if MELEE_FACING[w.def.behaviorId] and run.meleeAimT and os.clock() - run.meleeAimT < 0.3 then
		dir = Vector3.new(run.meleeAimX, 0, run.meleeAimZ) -- el personaje gira hacia el enemigo al que le pega
	elseif MELEE_FACING[w.def.behaviorId] and run.facing then
		dir = run.facing
	elseif w.def.tags and table.find(w.def.tags, "manualAim") and run.aimActive and run.aimDir then
		dir = run.aimDir
	else
		local e = Combat.nearest(run, run.px, run.pz, 70)
		if e then
			local dx, dz = e.x - run.px, e.z - run.pz
			if dx * dx + dz * dz > 0.01 then dir = Vector3.new(dx, 0, dz).Unit end
		elseif run.facing then
			dir = run.facing
		end
	end
	if dir then m:SetAttribute("AtkDir", dir) end
	m:SetAttribute("Atk", ((m:GetAttribute("Atk") or 0) + 1) % 10000)
end

local function continuousSound(run, w, Combat, t)
	local every = CONT_SND_BY_ID[w.id] or CONT_SND_EVERY[w.def.behaviorId]
	if not every then return end
	if t >= (w.state.contSndAt or 0) then
		w.state.contSndAt = t + every
		attackPulse(run, w, Combat, true)
	end
end

function Behaviors.addWeapon(run, id)
	local def = Weapons.byId[id]
	if not def then return nil end
	for _, w in ipairs(run.weapons) do if w.id == id then return w end end
	local w = { id = id, def = def, level = 1, nextFire = 0, state = {}, useful = useful(def), ownCrit = 0, up = {} }
	table.insert(run.weapons, w)
	return w
end

-- Mejora estilo MegaBonk: sortea 1 o 2 atributos compatibles con el arma y su valor según la rareza (mag).
-- Devuelve la lista { { key, value, label, pct, int } } para mostrarla en la oferta; se aplica con applyUpgrade.
function Behaviors.rollUpgrade(w, mag, rng, extraAttrs)
	local cfg = GameConfig.weaponUpgrades
	local u, up = w.useful, w.up or {}
	local pool = {}
	for _, e in ipairs(cfg.list) do
		local ok = false
		for ch in e.letters:gmatch(".") do if u[ch] then ok = true end end
		local cap = cfg.caps[e.key]
		if ok and (not cap or (up[e.key] or 0) < cap) then pool[#pool + 1] = e end
	end
	if #pool == 0 then pool = { cfg.list[1] } end
	local n = math.min(#pool, ((rng:chance(cfg.twoChance) and #pool >= 2) and 2 or 1) + (extraAttrs or 0)) -- + Yunque
	local out = {}
	for _ = 1, n do
		local i = rng:integer(1, #pool)
		local e = table.remove(pool, i)
		local v = e.int and math.max(1, math.floor(e.value * mag + 1e-6)) or e.value * mag
		out[#out + 1] = { key = e.key, value = v, label = e.label, pct = e.pct, int = e.int }
	end
	return out
end
function Behaviors.applyUpgrade(w, list)
	w.up = w.up or {}
	local caps = GameConfig.weaponUpgrades.caps
	for _, x in ipairs(list or {}) do
		local nv = (w.up[x.key] or 0) + x.value
		if caps[x.key] then nv = math.min(caps[x.key], nv) end
		w.up[x.key] = nv
	end
end
function Behaviors.describeUpgrade(list)
	local parts = {}
	for _, x in ipairs(list or {}) do
		if x.int then parts[#parts + 1] = ("+%d %s%s"):format(x.value, x.label, x.value > 1 and "s" or "")
		else parts[#parts + 1] = ("+%s%% %s"):format((("%.1f"):format(x.value * 100)):gsub("%.0$", ""), x.label) end
	end
	return table.concat(parts, " · ")
end

function Behaviors.getWeapon(run, id)
	for _, w in ipairs(run.weapons) do if w.id == id then return w end end
	return nil
end

function Behaviors.clear(run)
	run.projectiles = {}
	run.zones = {}
end

function Behaviors.step(run, dt, Combat)
	local t = run.clock.t
	for _, w in ipairs(run.weapons) do
		local ps = derive(run, w)
		local bid = w.def.behaviorId
		if CONTINUOUS[bid] or bid == "aura" then continuousSound(run, w, Combat, t) end
		if bid == "trail" then
			B.trailStep(run, Combat, w, ps)
		elseif bid == "orbit" then
			orbitStep(run, Combat, w, ps, nil)
		elseif bid == "axe" then
			orbitStep(run, Combat, w, ps, w.def.lifetime)
		elseif bid == "beyblade" then
			-- gira por tandas (no todo el tiempo): `lifetime` s girando, `cd` s de descanso
			orbitStep(run, Combat, w, ps, w.def.lifetime)
			-- el giro también golpea lo que toca el cuerpo
			if w.state.windowEnd and t <= w.state.windowEnd and t >= (w.state.bodyAt or 0) then
				w.state.bodyAt = t + 0.4
				for _, e in ipairs(Combat.inRadius(run, run.px, run.pz, 2.5 * ps.size)) do
					Combat.hit(run, e, ctx(w, ps, { amount = ps.dmg * 0.5, noLifesteal = true, lifestealTick = true }))
					knock(run, e, run.px, run.pz, ps.kb)
				end
			end
		elseif w.state.dashBack and t >= w.state.dashBack.at then
			dashReturn(run, Combat, w, ps)
		elseif w.state.pendingAt then
			if t >= w.state.pendingAt then resolveDecimate(run, Combat, w, ps) end
		elseif t >= w.nextFire then
			local fn = B[bid]
			if fn then
				local fired = fn(run, Combat, w, ps)
				if fired then
					attackPulse(run, w, Combat)
					-- el cooldown se acumula sin reiniciar al cambiar stats (ancla al último disparo)
					w.nextFire = math.max(t, w.nextFire) + ps.cd
					if w.nextFire < t then w.nextFire = t + ps.cd end
				else
					w.nextFire = t + 0.1 -- sin objetivo: reintenta rápido pero sin bucle ocupado
				end
			end
		end
	end
	Behaviors.stepProjectiles(run, dt, Combat)
	Behaviors.stepLinks(run, dt, Combat)
	Behaviors.stepZones(run, dt, Combat)
end

return Behaviors
