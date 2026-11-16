--!nonstrict
-- Bosses/BossAttacks: ataques de los jefes. Todo el daño se decide aquí, en el SERVIDOR.
-- Cada ataque = { defaults, start(A, s), update(A, s, dt) -> true al terminar, cleanup(A, s) }.
--   A = contexto que arma BossDirector (jefe, jugadores, daño, empuje, efectos, suelo…).
--   s = estado de ESTA ejecución: s.P (parámetros), s.t (segundos), s.parts (se borran solas), s.hits (un golpe por clave).
-- Los parámetros de abajo (defaults) se pueden pisar desde Config/BossConfig, en la lista `attacks` de cada jefe.
-- Reglas: siempre hay aviso visual antes del daño, cada jugador recibe como máximo un golpe por onda/objeto,
-- hay límites de cantidad (ramas, cactus, meteoritos, lunas, clones) y todo lo creado se destruye al terminar.
local Attacks = {}

local NEON, SM, WOOD, GRASS, SLATE = Enum.Material.Neon, Enum.Material.SmoothPlastic, Enum.Material.Wood, Enum.Material.Grass, Enum.Material.Slate
local BL, BALL, CYL = Enum.PartType.Block, Enum.PartType.Ball, Enum.PartType.Cylinder
local UP = CFrame.Angles(0, 0, math.pi / 2)
local RED = { 255, 60, 60 }

local function dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end
local function smoothstep(k) k = math.clamp(k, 0, 1); return k * k * (3 - 2 * k) end

-- ===== utilidades =====
-- anillo hecho de segmentos (se mueve por código; respeta la pausa del juego)
local function makeRing(A, s, n, color, thick, height, transp)
	local ring = {}
	for i = 1, n do ring[i] = A.part(s, BL, Vector3.new(thick, height, 2), color, NEON, transp or 0.2) end
	return ring
end
local function placeRing(A, ring, cx, cz, radius, spin, yOff, tilt)
	local n = #ring
	local seg = math.max(0.6, 2 * math.pi * math.max(radius, 0.5) / n * 1.08)
	for i, p in ipairs(ring) do
		local a = (i - 1) / n * math.pi * 2 + (spin or 0)
		local x, z = cx + math.cos(a) * radius, cz + math.sin(a) * radius
		local y = (yOff or 0.6) + (tilt and math.sin(a) * tilt or 0)
		local pos = A.W(x, y, z)
		p.Size = Vector3.new(p.Size.X, p.Size.Y, seg)
		p.CFrame = CFrame.lookAt(pos, pos + Vector3.new(-math.sin(a), 0, math.cos(a)))
	end
end
local function hideRing(ring) for _, p in ipairs(ring) do p.Transparency = 1 end end

-- puntos cerca de un jugador: uno "cerca" (no exacto) y el resto alrededor, nunca todos encima
local function scatter(A, s, n, nearMin, nearMax, minOff, maxOff)
	local pts = {}
	local targets = A.players()
	if #targets == 0 then return pts end
	for i = 1, n do
		local tp = targets[(i - 1) % #targets + 1]
		local a = A.rng:number(0, math.pi * 2)
		local d = (i == 1) and A.rng:number(nearMin, nearMax) or A.rng:number(minOff, maxOff)
		local x, z = A.clampPoint(tp.x + math.cos(a) * d, tp.z + math.sin(a) * d)
		local ok = true
		for _, q in ipairs(pts) do if dist(x, z, q[1], q[2]) < 4 then ok = false; break end end
		if ok then table.insert(pts, { x, z }) end
	end
	return pts
end

-- ======================================================================
-- Ataques básicos (jefes sin ataques propios todavía y relleno cuerpo a cuerpo)
-- ======================================================================
Attacks.chaseHit = {
	defaults = { range = 4.5, windup = 0.55, mult = 0.8 },
	start = function(A, s)
		local e = A.boss
		A.tint("w")
		A.anim("punch")
		A.fx("z", e.x, 0.3, e.z, e.radius + s.P.range, 255, 120, 60, s.P.windup)
	end,
	update = function(A, s)
		if s.t < s.P.windup then return false end
		local e = A.boss
		for _, p in ipairs(A.players()) do
			if dist(p.x, p.z, e.x, e.z) < e.radius + s.P.range + 1 then A.damage(p.m, s.P.mult, s, "hit") end
		end
		A.untint()
		return true
	end,
}

Attacks.shortWave = {
	defaults = { radius = 14, windup = 0.9, mult = 1.0, push = 45, up = 18 },
	start = function(A, s)
		local e = A.boss
		A.lock(true); A.tint("w"); A.anim("fire")
		A.fx("z", e.x, 0.3, e.z, s.P.radius, RED[1], RED[2], RED[3], s.P.windup)
	end,
	update = function(A, s)
		if s.t < s.P.windup then A.lift(math.sin(s.t / s.P.windup * math.pi) * 2); return false end
		local e = A.boss
		A.lift(0); A.untint()
		A.fx("b", e.x, 0.5, e.z, s.P.radius, 255, 160, 60, 0.45)
		for _, p in ipairs(A.players()) do
			if not p.air and dist(p.x, p.z, e.x, e.z) < s.P.radius then
				if A.damage(p.m, s.P.mult, s, "wave") then A.push(p.m, e.x, e.z, s.P.push, s.P.up) end
			end
		end
		return true
	end,
	cleanup = function(A) A.lock(false); A.lift(0) end,
}

-- ======================================================================
-- BR BR PATAPIM
-- ======================================================================
-- (El Pisotón Patapim ahora está en Bosses/SkillsForest: onda expansiva configurable.)

-- Lluvia de ramas: círculos de aviso cerca de los jugadores y ramas que salen del suelo.
Attacks.branchRain = {
	defaults = { count = 5, phaseCount = 7, max = 10, warn = 1.1, upTime = 1.4, rise = 0.25, hitRadius = 2.6, mult = 0.9,
		nearMin = 2, nearMax = 3.5, minOffset = 5, maxOffset = 14 },
	start = function(A, s)
		local P = s.P
		A.anim("fire")
		local n = math.min(P.max, A.phase2() and P.phaseCount or P.count)
		s.pts = scatter(A, s, n, P.nearMin, P.nearMax, P.minOffset, P.maxOffset)
		for _, q in ipairs(s.pts) do A.fx("z", q[1], 0.3, q[2], P.hitRadius + 0.6, 150, 90, 40, P.warn) end
	end,
	update = function(A, s)
		local P = s.P
		if s.t < P.warn then return false end
		if not s.branches then
			s.branches = {}
			for i, q in ipairs(s.pts) do
				local tilt = CFrame.Angles(A.rng:number(-0.25, 0.25), A.rng:number(0, 6.28), A.rng:number(-0.25, 0.25))
				local trunk = A.part(s, CYL, Vector3.new(9, 1.7, 1.7), Color3.fromRGB(118, 78, 44), WOOD, 0)
				local tip = A.part(s, BALL, Vector3.one * 3, Color3.fromRGB(80, 160, 60), GRASS, 0)
				s.branches[i] = { x = q[1], z = q[2], trunk = trunk, tip = tip, tilt = tilt, key = "b" .. i }
			end
		end
		local k = s.t - P.warn
		local up = (k < P.rise) and smoothstep(k / P.rise) or ((k > P.upTime) and (1 - smoothstep((k - P.upTime) / 0.3)) or 1)
		for _, b in ipairs(s.branches) do
			local base = A.W(b.x, -9 + up * 9, b.z)
			b.trunk.CFrame = CFrame.new(base + Vector3.new(0, 4.5, 0)) * b.tilt * UP
			b.tip.CFrame = CFrame.new(base + (b.tilt * CFrame.new(0, 9, 0)).Position)
			if up > 0.6 and k < P.upTime then
				for _, p in ipairs(A.players()) do
					if dist(p.x, p.z, b.x, b.z) < P.hitRadius then A.damage(p.m, P.mult, s, b.key) end
				end
			end
		end
		return k > P.upTime + 0.32
	end,
}

-- ======================================================================
-- LIRILI LARILA
-- ======================================================================
-- Danza de espejismos: clones que giran alrededor de la arena junto al jefe real (el real brilla con chispas
-- doradas y los clones son translúcidos). Los clones no hacen daño ni reciben daño.
Attacks.mirageDance = {
	defaults = { clones = 4, phaseClones = 6, max = 6, duration = 5, radius = 18, speed = 1.1 },
	start = function(A, s)
		local e, P = A.boss, s.P
		s.controlsMove = true
		s.cx, s.cz = e.x, e.z
		local n = math.min(P.max, A.phase2() and P.phaseClones or P.clones)
		s.clones = {}
		for i = 1, n do
			local m = A.buildModel(e.modelId, e.visSize, A.W(e.x, e.visSize / 2, e.z))
			if m then
				for _, d in ipairs(m:GetDescendants()) do
					if d:IsA("BasePart") and d.Transparency < 0.9 then d.Transparency = math.max(d.Transparency, 0.35) end
				end
				table.insert(s.clones, m)
				table.insert(s.parts, m)
			end
		end
		s.slots = #s.clones + 1
		s.realSlot = A.rng:integer(1, s.slots)
		s.spark = Instance.new("Sparkles"); s.spark.SparkleColor = Color3.fromRGB(255, 220, 90); s.spark.Parent = e.part
		A.fx("b", e.x, 1, e.z, s.P.radius, 200, 120, 255, 0.5)
	end,
	update = function(A, s, dt)
		local e, P = A.boss, s.P
		local ang = s.t * P.speed
		local k = smoothstep(s.t / 0.6) -- se abren desde el centro
		local slot = 0
		for i = 1, s.slots do
			local a = ang + (i - 1) / s.slots * math.pi * 2
			local x, z = A.clampPoint(s.cx + math.cos(a) * P.radius * k, s.cz + math.sin(a) * P.radius * k)
			if i == s.realSlot then
				e.x, e.z = x, z
			else
				slot += 1
				local m = s.clones[slot]
				if m and m.PrimaryPart then
					local pos = A.W(x, e.visSize / 2 + math.abs(math.sin(s.t * 6 + i)) * 1.2, z)
					m.PrimaryPart.CFrame = CFrame.lookAt(pos, A.W(s.cx, e.visSize / 2, s.cz)) * CFrame.Angles(0, math.sin(s.t * 4 + i) * 0.4, 0)
				end
			end
		end
		return s.t >= P.duration
	end,
	cleanup = function(A, s)
		if s.spark then s.spark:Destroy() end
		for _, m in ipairs(s.clones or {}) do A.fx("b", m.PrimaryPart and (m.PrimaryPart.Position.X - A.origin.X) or 0, 1, m.PrimaryPart and (m.PrimaryPart.Position.Z - A.origin.Z) or 0, 4, 200, 120, 255, 0.3) end
	end,
}

-- Teletransporte sorpresa: desaparece, marca dónde va a volver (detrás o al costado del jugador) y golpea corto.
Attacks.surpriseTeleport = {
	defaults = { vanish = 0.45, warn = 0.7, strikeDelay = 0.2, hitRadius = 8, mult = 1.0, behind = 8, push = 35, up = 16 },
	start = function(A, s)
		local e, P = A.boss, s.P
		s.controlsMove = true
		A.fx("b", e.x, 1, e.z, 6, 200, 120, 255, 0.35)
		A.hide(true)
		A.immune(P.vanish + P.warn)
		local tgt = A.target()
		if not tgt then s.dx, s.dz = e.x, e.z; return end
		local look = tgt.look or Vector3.new(0, 0, -1)
		local right = Vector3.new(-look.Z, 0, look.X)
		local cands = { -look * P.behind, right * P.behind, -right * P.behind, look * P.behind }
		for _, c in ipairs(cands) do
			local x, z, valid = A.validPoint(tgt.x + c.X, tgt.z + c.Z)
			if valid then s.dx, s.dz = x, z; break end
		end
		if not s.dx then s.dx, s.dz = A.clampPoint(tgt.x + 6, tgt.z) end
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		if not s.warned and s.t >= P.vanish then
			s.warned = true
			A.fx("z", s.dx, 0.3, s.dz, P.hitRadius, 200, 90, 255, P.warn)
		end
		if s.t >= P.vanish + P.warn and not s.back then
			s.back = true
			e.x, e.z = s.dx, s.dz
			A.hide(false); A.tint("w"); A.anim("punch")
			A.fx("b", e.x, 1, e.z, 6, 200, 120, 255, 0.35)
		end
		if s.back and s.t >= P.vanish + P.warn + P.strikeDelay then
			A.untint()
			for _, p in ipairs(A.players()) do
				if dist(p.x, p.z, e.x, e.z) < P.hitRadius then
					if A.damage(p.m, P.mult, s, "strike") then A.push(p.m, e.x, e.z, P.push, P.up) end
				end
			end
			return true
		end
		return false
	end,
	cleanup = function(A) A.hide(false); A.untint() end,
}

-- Ritmo hipnótico: cactus con aviso previo que aparecen alrededor de la arena (nunca encima de un jugador).
-- Tocar un cactus o su pequeña zona de pinchos hace daño (cada jugador, como mucho una vez cada `tick` s por cactus).
Attacks.hypnoticRhythm = {
	defaults = { count = 6, phaseCount = 9, max = 10, warn = 1.0, life = 4.5, bodyRadius = 1.8, zone = 1.4, mult = 0.6, tick = 0.8,
		minFromPlayer = 6, spread = 34 },
	start = function(A, s)
		local e, P = A.boss, s.P
		A.anim("fire")
		local n = math.min(P.max, A.phase2() and P.phaseCount or P.count)
		s.cacti = {}
		local tries = 0
		while #s.cacti < n and tries < n * 12 do
			tries += 1
			local a, d = A.rng:number(0, math.pi * 2), A.rng:number(8, P.spread)
			local x, z = A.clampPoint(A.arena.x + math.cos(a) * d, A.arena.z + math.sin(a) * d)
			local ok = dist(x, z, e.x, e.z) > e.radius + 3
			for _, p in ipairs(A.players()) do if dist(x, z, p.x, p.z) < P.minFromPlayer then ok = false end end
			for _, c in ipairs(s.cacti) do if dist(x, z, c.x, c.z) < 5 then ok = false end end
			if ok then table.insert(s.cacti, { x = x, z = z, last = {} }) end
		end
		for _, c in ipairs(s.cacti) do A.fx("z", c.x, 0.3, c.z, P.bodyRadius + P.zone, 90, 220, 90, P.warn) end
	end,
	update = function(A, s)
		local P = s.P
		if s.t < P.warn then return false end
		local k = s.t - P.warn
		if not s.built then
			s.built = true
			for _, c in ipairs(s.cacti) do
				c.body = A.part(s, CYL, Vector3.new(7, P.bodyRadius * 1.6, P.bodyRadius * 1.6), Color3.fromRGB(70, 150, 66), GRASS, 0)
				c.arm = A.part(s, CYL, Vector3.new(2.6, 1, 1), Color3.fromRGB(60, 132, 58), GRASS, 0)
				c.zoneDisc = A.part(s, CYL, Vector3.new(0.15, (P.bodyRadius + P.zone) * 2, (P.bodyRadius + P.zone) * 2), Color3.fromRGB(150, 255, 120), NEON, 0.7)
			end
		end
		local up = (k < 0.25) and smoothstep(k / 0.25) or ((k > P.life) and (1 - smoothstep((k - P.life) / 0.3)) or 1)
		for _, c in ipairs(s.cacti) do
			local base = A.W(c.x, -7 + up * 7, c.z)
			c.body.CFrame = CFrame.new(base + Vector3.new(0, 3.5, 0)) * UP
			c.arm.CFrame = CFrame.new(base + Vector3.new(1.4, 4.4, 0)) * UP * CFrame.Angles(0, 0, 0)
			c.zoneDisc.CFrame = CFrame.new(A.W(c.x, 0.15, c.z)) * UP
			if up > 0.6 and k < P.life then
				for _, p in ipairs(A.players()) do
					if dist(p.x, p.z, c.x, c.z) < P.bodyRadius + P.zone then
						local last = c.last[p.m] or -99
						if A.now() - last >= P.tick then
							c.last[p.m] = A.now()
							A.damage(p.m, P.mult, s, "c" .. tostring(c) .. math.floor(A.now() / P.tick))
						end
					end
				end
			end
		end
		return k > P.life + 0.32
	end,
}

-- ======================================================================
-- LA VACA SATURNO
-- ======================================================================
-- Anillos de Saturno: giran alrededor del jefe (aviso) y salen disparados hacia afuera. Se saltan.
Attacks.saturnRings = {
	defaults = { rings = 2, phaseRings = 3, windup = 0.9, spin = 3, expandTime = 1.8, stagger = 0.35, maxRadius = 42, band = 2.4,
		mult = 1.0, push = 50, up = 20 },
	start = function(A, s)
		local e, P = A.boss, s.P
		A.lock(true); A.anim("fire")
		s.cx, s.cz = e.x, e.z
		local n = A.phase2() and P.phaseRings or P.rings
		s.rings = {}
		for i = 1, n do
			s.rings[i] = { parts = makeRing(A, s, 20, Color3.fromRGB(255, 210, 120), 0.9, 0.9, 0.1), r0 = e.radius * 0.7 + i * 2.5, key = "r" .. i, t0 = P.windup + (i - 1) * P.stagger }
		end
		A.fx("z", s.cx, 0.3, s.cz, P.maxRadius, 255, 200, 90, P.windup + 0.4)
	end,
	update = function(A, s)
		local P = s.P
		local done = true
		for i, r in ipairs(s.rings) do
			local k = (s.t - r.t0) / P.expandTime
			if k < 0 then
				done = false
				placeRing(A, r.parts, s.cx, s.cz, r.r0, s.t * P.spin * (i % 2 == 0 and -1 or 1), 6 + i * 1.5, 1.5)
			elseif k <= 1 then
				done = false
				local rad = r.r0 + (P.maxRadius - r.r0) * smoothstep(k)
				placeRing(A, r.parts, s.cx, s.cz, rad, s.t * P.spin, 1.2)
				for _, p in ipairs(A.players()) do
					local d = dist(p.x, p.z, s.cx, s.cz)
					if not p.air and math.abs(d - rad) < P.band then
						if A.damage(p.m, P.mult, s, r.key) then A.push(p.m, s.cx, s.cz, P.push, P.up) end
					end
				end
			else
				hideRing(r.parts)
			end
		end
		if s.t > P.windup then A.lock(false) end
		return done
	end,
	cleanup = function(A) A.lock(false) end,
}

-- Gravedad vacuna: atrae despacio (se puede escapar caminando) y termina con un empujón.
-- La atracción la aplica el cliente de cada jugador, y no atrae si hay una pared entre el jugador y el jefe.
Attacks.cowGravity = {
	defaults = { radius = 30, duration = 3.5, pullSpeed = 7, endWarn = 0.7, endRadius = 11, mult = 1.0, push = 60, up = 26 },
	start = function(A, s)
		local e, P = A.boss, s.P
		A.lock(true); A.anim("fire")
		s.cx, s.cz = e.x, e.z
		s.disc = A.part(s, CYL, Vector3.new(0.2, P.radius * 2, P.radius * 2), Color3.fromRGB(150, 90, 255), NEON, 0.8)
		s.disc.CFrame = CFrame.new(A.W(s.cx, 0.2, s.cz)) * UP
		A.fx("z", s.cx, 0.3, s.cz, P.radius, 150, 90, 255, 0.8)
		A.pullAll(s.cx, s.cz, P.radius, P.pullSpeed, P.duration)
	end,
	update = function(A, s)
		local P = s.P
		s.disc.CFrame = CFrame.new(A.W(s.cx, 0.2, s.cz)) * CFrame.Angles(0, s.t * 2, 0) * UP
		if not s.warned and s.t >= P.duration - P.endWarn then
			s.warned = true
			A.tint("w")
			A.fx("z", s.cx, 0.3, s.cz, P.endRadius, RED[1], RED[2], RED[3], P.endWarn)
		end
		if s.t >= P.duration then
			A.untint()
			A.fx("X", s.cx, s.cz, P.endRadius)
			for _, p in ipairs(A.players()) do
				if dist(p.x, p.z, s.cx, s.cz) < P.endRadius then
					if A.damage(p.m, P.mult, s, "boom") then A.push(p.m, s.cx, s.cz, P.push, P.up) end
				end
			end
			return true
		end
		return false
	end,
	cleanup = function(A) A.lock(false); A.untint(); A.pullStop() end,
}

-- Meteoritos: círculos rojos y luego caen rocas desde arriba (uno cerca del jugador, el resto alrededor).
Attacks.meteors = {
	defaults = { count = 5, phaseExtra = 2, max = 9, warn = 1.3, fall = 0.55, radius = 6, mult = 1.0, push = 40, up = 18,
		nearMin = 2.5, nearMax = 4, minOffset = 6, maxOffset = 16, height = 70 },
	combo = true,
	start = function(A, s)
		local P = s.P
		local n = math.min(P.max, P.count + (A.phase2() and P.phaseExtra or 0))
		s.pts = scatter(A, s, n, P.nearMin, P.nearMax, P.minOffset, P.maxOffset)
		s.rocks = {}
		for i, q in ipairs(s.pts) do
			local delay = (i - 1) * 0.12
			A.fx("z", q[1], 0.3, q[2], P.radius, RED[1], RED[2], RED[3], P.warn + delay)
			local rock = A.part(s, BALL, Vector3.one * 5, Color3.fromRGB(120, 90, 160), SLATE, 0)
			rock.CFrame = CFrame.new(A.W(q[1], P.height, q[2]))
			local glow = Instance.new("Fire"); glow.Color = Color3.fromRGB(255, 120, 40); glow.SecondaryColor = Color3.fromRGB(255, 220, 90); glow.Size = 5; glow.Parent = rock
			s.rocks[i] = { x = q[1], z = q[2], part = rock, t0 = P.warn + delay - P.fall, key = "m" .. i }
		end
	end,
	update = function(A, s)
		local P = s.P
		local done = true
		for _, r in ipairs(s.rocks) do
			local k = (s.t - r.t0) / P.fall
			if k < 1 then
				done = false
				r.part.CFrame = CFrame.new(A.W(r.x, P.height * (1 - math.max(0, k) ^ 2) + 2, r.z))
			elseif not r.hit then
				r.hit = true
				r.part.Transparency = 1
				A.fx("X", r.x, r.z, P.radius)
				for _, p in ipairs(A.players()) do
					if dist(p.x, p.z, r.x, r.z) < P.radius then
						if A.damage(p.m, P.mult, s, r.key) then A.push(p.m, r.x, r.z, P.push, P.up) end
					end
				end
			end
		end
		return done
	end,
}

-- Pisotón orbital: carga y suelta varias ondas separadas (se saltan o se pasa entre ellas). Un golpe por onda.
Attacks.orbitalStomp = {
	defaults = { windup = 1.1, waves = 3, gap = 0.55, speed = 28, maxRadius = 46, band = 2.2, mult = 0.8, push = 35, up = 18 },
	start = function(A, s)
		local e, P = A.boss, s.P
		A.lock(true); A.tint("w"); A.anim("punch")
		s.cx, s.cz = e.x, e.z
		A.fx("z", s.cx, 0.3, s.cz, P.maxRadius, 255, 170, 70, P.windup + P.gap * (P.waves - 1))
		s.waves = {}
		for i = 1, P.waves do
			local w = { parts = makeRing(A, s, 24, Color3.fromRGB(255, 225, 150), 1.1, 1.2, 0.15), t0 = P.windup + (i - 1) * P.gap, key = "o" .. i }
			hideRing(w.parts)
			s.waves[i] = w
		end
	end,
	update = function(A, s)
		local P = s.P
		if s.t < P.windup then A.lift(math.sin(s.t / P.windup * math.pi * 0.5) * 6); return false end
		A.lift(0); A.untint()
		local done = true
		for _, w in ipairs(s.waves) do
			local r = (s.t - w.t0) * P.speed
			if r < 0 then done = false
			elseif r <= P.maxRadius then
				done = false
				if not w.fired then w.fired = true; A.fx("b", s.cx, 0.5, s.cz, 6, 255, 225, 150, 0.3); A.shake(s.cx, s.cz, 30) end
				placeRing(A, w.parts, s.cx, s.cz, r, 0, 0.7)
				for _, p in ipairs(A.players()) do
					local d = dist(p.x, p.z, s.cx, s.cz)
					if not p.air and math.abs(d - r) < P.band then
						if A.damage(p.m, P.mult, s, w.key) then A.push(p.m, s.cx, s.cz, P.push, P.up) end
					end
				end
			else
				hideRing(w.parts)
			end
		end
		return done
	end,
	cleanup = function(A) A.lock(false); A.lift(0); A.untint() end,
}

-- Invocación lunar: lunas que orbitan al jefe y disparan proyectiles esquivables (con línea de aviso antes).
Attacks.lunarSummon = {
	defaults = { moons = 2, phaseExtra = 1, max = 3, duration = 6.5, orbitRadius = 11, height = 9, fireEvery = 1.9, aim = 0.6, shotMult = 0.7, maxShots = 4 },
	combo = true,
	start = function(A, s)
		local P = s.P
		local n = math.min(P.max, P.moons + (A.phase2() and P.phaseExtra or 0))
		s.moons = {}
		for i = 1, n do
			local part = A.part(s, BALL, Vector3.one * 3, Color3.fromRGB(230, 230, 250), NEON, 0)
			local l = Instance.new("PointLight"); l.Color = Color3.fromRGB(200, 200, 255); l.Range = 10; l.Parent = part
			s.moons[i] = { part = part, next = 0.8 + (i - 1) * (P.fireEvery / n), shots = 0 }
		end
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		for i, mo in ipairs(s.moons) do
			local a = s.t * 1.4 + (i - 1) / #s.moons * math.pi * 2
			mo.x, mo.z = e.x + math.cos(a) * P.orbitRadius, e.z + math.sin(a) * P.orbitRadius
			mo.part.CFrame = CFrame.new(A.W(mo.x, P.height + math.sin(s.t * 3 + i), mo.z))
			if mo.shots < P.maxShots and s.t < P.duration - 0.5 then
				if not mo.aimAt and s.t >= mo.next - P.aim then
					local tgt = A.target()
					if tgt then
						mo.aimAt = { tgt.x, tgt.z }
						A.fx("t", mo.x, 2, mo.z, tgt.x, 2, tgt.z, 255, 80, 80, 0.5, P.aim)
					else
						mo.next += P.fireEvery
					end
				elseif mo.aimAt and s.t >= mo.next then
					A.shot(mo.x, mo.z, mo.aimAt[1] - mo.x, mo.aimAt[2] - mo.z, P.shotMult)
					mo.shots += 1
					mo.aimAt = nil
					mo.next += P.fireEvery
				end
			end
		end
		return s.t >= P.duration
	end,
}

-- ===== habilidades nuevas (3 por jefe) =====
-- SkillsForest también REEMPLAZA el Pisotón Patapim de arriba por la versión con onda expansiva.
require(script.Parent.SkillsForest)(Attacks)
require(script.Parent.SkillsDesert)(Attacks)
require(script.Parent.SkillsSecret)(Attacks) -- (restaurado: faltaba en el archivo guardado)
-- SkillsSecret desactivado: ModuleScript ausente

return Attacks
