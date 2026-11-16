--!nonstrict
-- Bosses/SkillsForest: habilidades de los jefes del BOSQUE (Br Br Patapim, Chimpancini, Tung Tung Sahur).
-- Cada habilidad: defaults = { name, mult (daño = daño del jefe x mult), range, duration, windup, sound, ... }.
-- El cooldown de cada una está en Config/BossConfig (lista `attacks` del jefe). Todo el daño lo valida el servidor.
local Kit = require(script.Parent.BossSkillKit)
local dist, smooth, angle, unit = Kit.dist, Kit.smooth, Kit.angle, Kit.unit
local c3 = Kit.c3
local NEON, WOOD, GRASS, SLATE, BL, BALL, CYL, UP = Kit.NEON, Kit.WOOD, Kit.GRASS, Kit.SLATE, Kit.BL, Kit.BALL, Kit.CYL, Kit.UP

return function(Attacks)

-- ======================================================================
-- BR BR PATAPIM
-- ======================================================================
-- Pisotón Patapim (rehecho): levanta el pie con un círculo debajo, golpea el suelo y desde sus pies sale una onda
-- circular que se expande. Daño + knockback al tocarla, una vez por jugador por onda. Se salta o se esquiva alejándose.
-- Fase final: dos ondas seguidas con un pequeño intervalo.
Attacks.patapimStomp = {
	defaults = { name = "Pisotón Patapim", mult = 1.1, windup = 1.0, speed = 26, maxRadius = 26, band = 2.4, push = 55, up = 24,
		phaseWaves = 2, waveGap = 0.5, sound = "heavy", duration = 2.5 },
	start = function(A, s)
		local e, P = A.boss, s.P
		A.lock(true); A.tint("w"); A.anim("punch")
		s.cx, s.cz = e.x, e.z
		s.underRing = Kit.disc(A, s, s.cx, s.cz, e.radius + 2, c3(255, 70, 60), 0.55, 0.25) -- círculo de advertencia debajo
		A.fx("z", s.cx, 0.3, s.cz, P.maxRadius, 255, 140, 60, P.windup) -- alcance máximo de la onda (tenue)
		local n = A.phase2() and P.phaseWaves or 1
		s.waves = {}
		for i = 1, n do
			local w = { t0 = P.windup + (i - 1) * P.waveGap, ring = Kit.ring(A, s, 26, c3(255, 210, 140), 1.2, 1.6, 0.1), key = "wave" .. i }
			Kit.hide(w.ring)
			s.waves[i] = w
		end
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		if s.t < P.windup then
			-- levanta el pie: sube despacio y queda arriba un instante
			local k = s.t / P.windup
			A.lift(math.min(1, k * 1.4) * 5)
			s.underRing.Transparency = 0.35 + 0.3 * math.abs(math.sin(s.t * 10))
			return false
		end
		A.lift(0); A.untint()
		if s.underRing.Parent then s.underRing:Destroy() end
		local done = true
		for _, w in ipairs(s.waves) do
			local r = (s.t - w.t0) * P.speed
			if r < 0 then done = false
			elseif r <= P.maxRadius then
				done = false
				if not w.fired then
					w.fired = true
					A.sound(P.sound, s.cx, s.cz, 0.9)
					A.particles(s.cx, s.cz, 0.5, { 150, 120, 80 }, 26, 3, 22) -- polvo
					A.fx("b", s.cx, 0.5, s.cz, 7, 255, 230, 170, 0.35)
					A.shake(s.cx, s.cz, P.maxRadius)
				end
				Kit.placeRing(A, w.ring, s.cx, s.cz, math.max(1, r), 0, 0.8)
				for _, p in ipairs(A.players()) do
					local d = dist(p.x, p.z, s.cx, s.cz)
					if not p.air and d <= r + P.band and d >= r - P.band * 2 then
						if A.damage(p.m, P.mult, s, w.key) then A.push(p.m, s.cx, s.cz, P.push, P.up) end
					end
				end
			else
				Kit.hide(w.ring)
			end
		end
		return done
	end,
	cleanup = function(A) A.lock(false); A.lift(0); A.untint() end,
}

-- 1) Golpe de tronco: arco de aviso delante; daño dentro del arco y knockback LATERAL. Se esquiva yendo a los costados.
Attacks.trunkSlam = {
	defaults = { name = "Golpe de tronco", mult = 1.0, range = 17, halfAngle = math.rad(50), windup = 0.9, push = 50, up = 16, sound = "bat", duration = 1.2 },
	start = function(A, s)
		local e, P = A.boss, s.P
		local tgt = A.target()
		local dx, dz = 0, 1
		if tgt then dx, dz = unit(tgt.x - e.x, tgt.z - e.z) end
		s.ang = angle(dx, dz); s.dx, s.dz = dx, dz
		A.lock(true); A.face(dx, dz); A.tint("w")
		s.warn = Kit.sector(A, s, e.x, e.z, s.ang, P.halfAngle, P.range, c3(255, 90, 60), 0.6)
		-- tronco levantado (visual)
		s.log = A.part(s, CYL, Vector3.new(9, 2, 2), c3(118, 78, 44), WOOD, 0)
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		local k = math.min(1, s.t / P.windup)
		local swing = (s.t < P.windup) and (-1.3 + k * 0.3) or (-1 + math.min(1, (s.t - P.windup) / 0.15) * 2.3)
		local base = A.W(e.x, 6, e.z)
		s.log.CFrame = CFrame.lookAt(base, base + Vector3.new(s.dx, 0, s.dz)) * CFrame.Angles(swing, 0, 0) * CFrame.new(0, 0, -4.5) * CFrame.Angles(0, math.pi / 2, 0)
		Kit.setAlpha(s.warn, 0.45 + 0.25 * math.abs(math.sin(s.t * 9)))
		if s.t < P.windup then return false end
		if not s.hit then
			s.hit = true
			A.untint(); A.anim("punch"); A.sound(P.sound, e.x, e.z)
			A.particles(e.x + s.dx * 8, e.z + s.dz * 8, 1, { 140, 100, 60 }, 14, 2, 14)
			for _, p in ipairs(A.players()) do
				if Kit.inSector(p.x, p.z, e.x, e.z, s.ang, P.halfAngle, P.range) then
					if A.damage(p.m, P.mult, s, "trunk") then
						-- knockback lateral: hacia el costado del arco en el que está el jugador
						local side = (s.dx * (p.z - e.z) - s.dz * (p.x - e.x)) >= 0 and 1 or -1
						A.pushDir(p.m, -s.dz * side, s.dx * side, P.push, P.up)
					end
				end
			end
		end
		return s.t >= P.windup + 0.3
	end,
	cleanup = function(A) A.lock(false); A.face(nil); A.untint() end,
}

-- 2) Semillas explosivas: lanza 3-5 semillas (en arco); círculo debajo de cada una; explotan tras un retraso.
Attacks.explosiveSeeds = {
	defaults = { name = "Semillas explosivas", mult = 0.9, count = 3, phaseCount = 5, max = 5, flight = 0.6, fuse = 1.0, radius = 5,
		nearMin = 2.5, nearMax = 4, minOffset = 6, maxOffset = 14, sound = "bombx", duration = 2 },
	start = function(A, s)
		local e, P = A.boss, s.P
		A.anim("fire"); A.sound("throw", e.x, e.z)
		local n = math.min(P.max, A.phase2() and P.phaseCount or P.count)
		s.seeds = {}
		for i, q in ipairs(Kit.scatter(A, n, P.nearMin, P.nearMax, P.minOffset, P.maxOffset)) do
			local seed = A.part(s, BALL, Vector3.one * 1.8, c3(110, 70, 40), WOOD, 0)
			local glow = Instance.new("PointLight"); glow.Color = c3(255, 120, 60); glow.Range = 8; glow.Parent = seed
			local warn = Kit.disc(A, s, q[1], q[2], P.radius, c3(255, 110, 50), 0.6, 0.22)
			s.seeds[i] = { x = q[1], z = q[2], part = seed, warn = warn, delay = (i - 1) * 0.12, key = "s" .. i }
		end
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		local done = true
		for _, sd in ipairs(s.seeds) do
			local k = (s.t - sd.delay) / P.flight
			if k < 1 then
				done = false
				local kk = math.max(0, k)
				local x, z = e.x + (sd.x - e.x) * kk, e.z + (sd.z - e.z) * kk
				sd.part.CFrame = CFrame.new(A.W(x, 8 + math.sin(kk * math.pi) * 10 - kk * 7, z))
			elseif s.t < sd.delay + P.flight + P.fuse then
				done = false
				sd.part.CFrame = CFrame.new(A.W(sd.x, 1, sd.z))
				sd.warn.Transparency = 0.3 + 0.35 * math.abs(math.sin(s.t * 12))
			elseif not sd.boom then
				sd.boom = true
				sd.part.Transparency = 1; sd.warn.Transparency = 1
				A.fx("X", sd.x, sd.z, P.radius)
				A.particles(sd.x, sd.z, 1, { 255, 150, 60 }, 16, 2.5, 18)
				for _, p in ipairs(A.players()) do
					if dist(p.x, p.z, sd.x, sd.z) < P.radius then
						if A.damage(p.m, P.mult, s, sd.key) then A.push(p.m, sd.x, sd.z, 30, 14) end
					end
				end
			end
		end
		return done
	end,
}

-- 3) Rugido de la selva: cono frontal; daño leve y ralentización. Las paredes lo cortan.
Attacks.jungleRoar = {
	defaults = { name = "Rugido de la selva", mult = 0.45, range = 24, halfAngle = math.rad(35), windup = 1.0, slow = 0.6, slowTime = 2.5,
		sound = "wind", duration = 1.6 },
	start = function(A, s)
		local e, P = A.boss, s.P
		local tgt = A.target()
		local dx, dz = 0, 1
		if tgt then dx, dz = unit(tgt.x - e.x, tgt.z - e.z) end
		s.ang = angle(dx, dz)
		A.lock(true); A.face(dx, dz); A.tint("w")
		s.warn = Kit.sector(A, s, e.x, e.z, s.ang, P.halfAngle, P.range, c3(120, 230, 90), 0.6)
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		if s.t < P.windup then
			Kit.setAlpha(s.warn, 0.4 + 0.3 * math.abs(math.sin(s.t * 8)))
			A.lift(math.sin(s.t * 25) * 0.4)
			return false
		end
		if not s.hit then
			s.hit = true
			A.lift(0); A.untint(); A.anim("fire"); A.sound(P.sound, e.x, e.z, 0.7)
			A.particles(e.x + math.cos(s.ang) * 6, e.z + math.sin(s.ang) * 6, 3, { 170, 255, 140 }, 22, 3, 30)
			for _, p in ipairs(A.players()) do
				if Kit.inSector(p.x, p.z, e.x, e.z, s.ang, P.halfAngle, P.range) and not A.blocked(e.x, e.z, p.x, p.z) then
					if A.damage(p.m, P.mult, s, "roar") then A.slow(p.m, P.slow, P.slowTime) end
				end
			end
		end
		Kit.setAlpha(s.warn, math.min(1, 0.4 + (s.t - P.windup) * 2))
		return s.t >= P.windup + 0.4
	end,
	cleanup = function(A) A.lock(false); A.face(nil); A.lift(0); A.untint() end,
}

-- ======================================================================
-- CHIMPANCINI
-- ======================================================================
-- 1) Banana bumerán: aviso (línea), la banana va hacia el jugador y vuelve. Pega al ir y al volver (una vez cada tramo).
Attacks.bananaBoomerang = {
	defaults = { name = "Banana bumerán", mult = 0.8, range = 32, speed = 30, radius = 2.2, windup = 0.5, sound = "banana", duration = 3 },
	start = function(A, s)
		local e, P = A.boss, s.P
		local tgt = A.target()
		local dx, dz = 0, 1
		if tgt then dx, dz = unit(tgt.x - e.x, tgt.z - e.z) end
		s.dx, s.dz = dx, dz
		s.len = math.min(P.range, A.rayLen(e.x, e.z, dx, dz, P.range))
		A.face(dx, dz); A.anim("fire")
		s.warn = Kit.line(A, s, e.x, e.z, e.x + dx * s.len, e.z + dz * s.len, 2.4, c3(255, 220, 60), 0.55)
		s.banana = A.part(s, CYL, Vector3.new(0.9, 2.6, 2.6), c3(250, 220, 60), Enum.Material.SmoothPlastic, 0)
		Kit.trail(s.banana, c3(255, 230, 90))
		s.pos = 0; s.dir = 1
	end,
	update = function(A, s, dt)
		local e, P = A.boss, s.P
		if s.t < P.windup then s.banana.CFrame = CFrame.new(A.W(e.x, 6, e.z)); return false end
		if s.warn.Parent then s.warn:Destroy(); A.sound(P.sound, e.x, e.z) end
		s.pos += s.dir * P.speed * dt
		if s.dir == 1 and s.pos >= s.len then s.pos = s.len; s.dir = -1 end
		local x, z = e.x + s.dx * s.pos, e.z + s.dz * s.pos
		if s.dir == -1 then
			-- de vuelta hacia donde esté el jefe ahora
			x, z = e.x + s.dx * s.pos, e.z + s.dz * s.pos
		end
		s.banana.CFrame = CFrame.new(A.W(x, 3, z)) * CFrame.Angles(0, s.t * 18, 0) * UP
		for _, p in ipairs(A.players()) do
			if dist(p.x, p.z, x, z) < P.radius + 1.2 then
				local key = s.dir == 1 and "ida" or "vuelta"
				A.damage(p.m, P.mult, s, key)
			end
		end
		return s.dir == -1 and s.pos <= 1
	end,
	cleanup = function(A) A.face(nil) end,
}

-- 2) Lianas atrapadoras: círculos de aviso; salen lianas; tocarlas ralentiza un poco y hace daño leve.
Attacks.vineTrap = {
	defaults = { name = "Lianas atrapadoras", mult = 0.4, count = 5, phaseCount = 7, max = 8, windup = 1.0, duration = 3, radius = 2.4,
		slow = 0.55, slowTime = 1.5, nearMin = 2.5, nearMax = 4, minOffset = 5, maxOffset = 15, sound = "slap" },
	start = function(A, s)
		local P = s.P
		A.anim("fire")
		local n = math.min(P.max, A.phase2() and P.phaseCount or P.count)
		s.vines = {}
		for i, q in ipairs(Kit.scatter(A, n, P.nearMin, P.nearMax, P.minOffset, P.maxOffset)) do
			A.fx("z", q[1], 0.3, q[2], P.radius + 0.5, 90, 200, 70, P.windup)
			s.vines[i] = { x = q[1], z = q[2], key = "v" .. i }
		end
	end,
	update = function(A, s)
		local P = s.P
		if s.t < P.windup then return false end
		local k = s.t - P.windup
		if not s.built then
			s.built = true
			A.sound(P.sound, s.vines[1] and s.vines[1].x or 0, s.vines[1] and s.vines[1].z or 0)
			for _, v in ipairs(s.vines) do
				v.parts = {}
				for j = 1, 3 do v.parts[j] = A.part(s, CYL, Vector3.new(8, 0.8, 0.8), c3(60 + j * 15, 150, 50), GRASS, 0) end
			end
		end
		local up = (k < 0.25) and smooth(k / 0.25) or ((k > P.duration) and (1 - smooth((k - P.duration) / 0.3)) or 1)
		for _, v in ipairs(s.vines) do
			for j, part in ipairs(v.parts) do
				local a = j * 2.1 + s.t * 1.5
				local base = A.W(v.x + math.cos(a) * 0.9, -8 + up * 8, v.z + math.sin(a) * 0.9)
				part.CFrame = CFrame.new(base + Vector3.new(0, 4, 0)) * CFrame.Angles(math.sin(s.t * 3 + j) * 0.25, a, math.cos(s.t * 3 + j) * 0.25) * UP
			end
			if up > 0.6 and k < P.duration then
				for _, p in ipairs(A.players()) do
					if dist(p.x, p.z, v.x, v.z) < P.radius then
						if A.damage(p.m, P.mult, s, v.key) then A.slow(p.m, P.slow, P.slowTime) end
					end
				end
			end
		end
		return k > P.duration + 0.32
	end,
}

-- 3) Salto simiesco: marca un círculo grande donde va a caer, salta en arco y al aterrizar daña y empuja (sin onda viajera).
Attacks.apeLeap = {
	defaults = { name = "Salto simiesco", mult = 1.1, radius = 12, windup = 0.5, flight = 0.9, height = 22, push = 55, up = 24, sound = "heavy", duration = 1.8 },
	start = function(A, s)
		local e, P = A.boss, s.P
		s.controlsMove = true
		local tgt = A.target()
		local tx, tz = e.x, e.z
		if tgt then tx, tz = tgt.x + A.rng:number(-3, 3), tgt.z + A.rng:number(-3, 3) end
		local x, z, ok = A.validPoint(tx, tz)
		s.tx, s.tz = x, z
		s.fx, s.fz = e.x, e.z
		A.tint("w")
		A.fx("z", s.tx, 0.3, s.tz, P.radius, 255, 80, 60, P.windup + P.flight)
		s.mark = Kit.disc(A, s, s.tx, s.tz, P.radius, c3(255, 80, 60), 0.75, 0.22)
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		if s.t < P.windup then A.lift(-s.t / P.windup * 1.5); return false end
		local k = (s.t - P.windup) / P.flight
		if k < 1 then
			e.x = s.fx + (s.tx - s.fx) * smooth(k)
			e.z = s.fz + (s.tz - s.fz) * smooth(k)
			A.lift(math.sin(k * math.pi) * P.height)
			return false
		end
		if not s.landed then
			s.landed = true
			e.x, e.z = s.tx, s.tz
			A.lift(0); A.untint(); A.sound(P.sound, s.tx, s.tz)
			A.fx("b", s.tx, 0.5, s.tz, P.radius, 255, 200, 120, 0.4)
			A.particles(s.tx, s.tz, 0.5, { 150, 120, 80 }, 24, 3, 20)
			for _, p in ipairs(A.players()) do
				if dist(p.x, p.z, s.tx, s.tz) < P.radius then
					if A.damage(p.m, P.mult, s, "land") then A.push(p.m, s.tx, s.tz, P.push, P.up) end
				end
			end
		end
		return s.t >= P.windup + P.flight + 0.25
	end,
	cleanup = function(A) A.lift(0); A.untint() end,
}

-- ======================================================================
-- TUNG TUNG SAHUR
-- ======================================================================
-- 1) Redoble paralizante: golpea el tambor varias veces (señal visual y sonora en cada golpe) y el último
-- redoble daña y ralentiza en un cono frontal. Se esquiva saliendo del cono.
Attacks.paralyzingDrumroll = {
	defaults = { name = "Redoble paralizante", mult = 0.8, beats = 3, beatGap = 0.45, range = 20, halfAngle = math.rad(40), slow = 0.6, slowTime = 1.5,
		sound = "bat", duration = 1.8 },
	start = function(A, s)
		local e, P = A.boss, s.P
		local tgt = A.target()
		local dx, dz = 0, 1
		if tgt then dx, dz = unit(tgt.x - e.x, tgt.z - e.z) end
		s.ang = angle(dx, dz)
		A.lock(true); A.face(dx, dz)
		s.warn = Kit.sector(A, s, e.x, e.z, s.ang, P.halfAngle, P.range, c3(255, 170, 60), 0.75)
		s.beat = 0
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		local beat = math.floor(s.t / P.beatGap) + 1
		if beat > s.beat and s.beat < P.beats then
			s.beat = math.min(beat, P.beats)
			A.anim("punch"); A.sound(P.sound, e.x, e.z, 0.8 + s.beat * 0.15)
			A.fx("b", e.x, 2, e.z, 4 + s.beat * 2, 255, 200, 100, 0.25)
			Kit.setAlpha(s.warn, 0.75 - s.beat * 0.12) -- el cono se marca más con cada golpe
		end
		if s.t >= P.beats * P.beatGap and not s.hit then
			s.hit = true
			A.sound("boom", e.x, e.z)
			A.particles(e.x + math.cos(s.ang) * 8, e.z + math.sin(s.ang) * 8, 2, { 255, 200, 90 }, 20, 2.5, 26)
			for _, p in ipairs(A.players()) do
				if Kit.inSector(p.x, p.z, e.x, e.z, s.ang, P.halfAngle, P.range) and not A.blocked(e.x, e.z, p.x, p.z) then
					if A.damage(p.m, P.mult, s, "drum") then A.slow(p.m, P.slow, P.slowTime) end
				end
			end
		end
		return s.t >= P.beats * P.beatGap + 0.35
	end,
	cleanup = function(A) A.lock(false); A.face(nil) end,
}

-- 2) Mazazo vertical: levanta el bate, marca una zona chica y golpea de arriba. Fácil de esquivar moviéndose.
Attacks.verticalSmash = {
	defaults = { name = "Mazazo vertical", mult = 1.3, radius = 6, distance = 9, windup = 1.1, push = 45, up = 20, sound = "heavy", duration = 1.5 },
	start = function(A, s)
		local e, P = A.boss, s.P
		local tgt = A.target()
		local dx, dz = 0, 1
		if tgt then dx, dz = unit(tgt.x - e.x, tgt.z - e.z) end
		local d = tgt and math.min(dist(tgt.x, tgt.z, e.x, e.z), e.radius + P.distance) or e.radius + P.distance
		s.x, s.z = A.clampPoint(e.x + dx * d, e.z + dz * d)
		A.lock(true); A.face(dx, dz); A.tint("w")
		A.fx("z", s.x, 0.3, s.z, P.radius, 255, 60, 60, P.windup)
		s.bat = A.part(s, CYL, Vector3.new(10, 1.6, 1.6), c3(150, 100, 60), WOOD, 0)
		s.dx, s.dz = dx, dz
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		local k = s.t < P.windup and (s.t / P.windup) or 1
		local smashK = s.t < P.windup and 0 or math.min(1, (s.t - P.windup) / 0.12)
		local rise = (1 - smashK) * (k * 1.6)
		local base = A.W(e.x, 7, e.z)
		s.bat.CFrame = CFrame.lookAt(base, base + Vector3.new(s.dx, 0, s.dz)) * CFrame.Angles(rise - 0.2, 0, 0) * CFrame.new(0, 0, -5) * CFrame.Angles(0, math.pi / 2, 0)
		if s.t < P.windup then return false end
		if not s.hit then
			s.hit = true
			A.untint(); A.anim("punch"); A.sound(P.sound, s.x, s.z)
			A.fx("b", s.x, 0.5, s.z, P.radius, 255, 140, 80, 0.35)
			A.particles(s.x, s.z, 0.5, { 140, 110, 80 }, 18, 2.5, 16)
			for _, p in ipairs(A.players()) do
				if dist(p.x, p.z, s.x, s.z) < P.radius then
					if A.damage(p.m, P.mult, s, "smash") then A.push(p.m, s.x, s.z, P.push, P.up) end
				end
			end
		end
		return s.t >= P.windup + 0.35
	end,
	cleanup = function(A) A.lock(false); A.face(nil); A.untint() end,
}

-- 3) Marcha del amanecer: avanza despacio por una ruta corta; golpes alternados izquierda/derecha con aviso.
Attacks.dawnMarch = {
	defaults = { name = "Marcha del amanecer", mult = 0.8, duration = 4, speed = 5, every = 0.8, warn = 0.5, radius = 6, side = 8, push = 35, up = 14, sound = "bat" },
	start = function(A, s)
		local e, P = A.boss, s.P
		s.controlsMove = true
		local tgt = A.target()
		s.dx, s.dz = 0, 1
		if tgt then s.dx, s.dz = unit(tgt.x - e.x, tgt.z - e.z) end
		A.face(s.dx, s.dz)
		s.hits = s.hits or {}
		s.strikes = {}
		s.nextT = P.every * 0.5
		s.n = 0
		A.fx("t", e.x, 0.4, e.z, e.x + s.dx * P.speed * P.duration, 0.4, e.z + s.dz * P.speed * P.duration, 255, 200, 90, 3, 0.8) -- ruta
	end,
	update = function(A, s, dt)
		local e, P = A.boss, s.P
		if s.t < P.duration then
			local nx, nz, ok = A.validPoint(e.x + s.dx * P.speed * dt, e.z + s.dz * P.speed * dt)
			if ok then e.x, e.z = nx, nz end
			if s.t >= s.nextT then
				s.n += 1
				s.nextT += P.every
				local side = (s.n % 2 == 1) and 1 or -1
				local px, pz = -s.dz * side, s.dx * side
				local x, z = e.x + px * P.side + s.dx * (P.warn * P.speed), e.z + pz * P.side + s.dz * (P.warn * P.speed)
				A.fx("z", x, 0.3, z, P.radius, 255, 120, 60, P.warn)
				table.insert(s.strikes, { x = x, z = z, at = s.t + P.warn, key = "m" .. s.n })
			end
		end
		local pending = false
		for _, st in ipairs(s.strikes) do
			if not st.done then
				if s.t >= st.at then
					st.done = true
					A.anim("punch"); A.sound(P.sound, st.x, st.z)
					A.fx("b", st.x, 0.5, st.z, P.radius, 255, 170, 90, 0.3)
					for _, p in ipairs(A.players()) do
						if dist(p.x, p.z, st.x, st.z) < P.radius then
							if A.damage(p.m, P.mult, s, st.key) then A.push(p.m, st.x, st.z, P.push, P.up) end
						end
					end
				else
					pending = true
				end
			end
		end
		return s.t >= P.duration and not pending
	end,
	cleanup = function(A) A.face(nil) end,
}

end
