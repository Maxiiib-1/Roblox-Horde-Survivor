--!nonstrict
-- Bosses/SkillsDesert: habilidades de los jefes del DESIERTO (Cacto Hipopótamo, Lirili Larila, Sigma Boy).
-- Cada habilidad: defaults = { name, mult, range, duration, windup, sound, ... }. Cooldowns en Config/BossConfig.
local Kit = require(script.Parent.BossSkillKit)
local dist, smooth, angle, unit = Kit.dist, Kit.smooth, Kit.angle, Kit.unit
local c3 = Kit.c3
local NEON, GRASS, SM, BL, BALL, CYL, UP = Kit.NEON, Kit.GRASS, Kit.SM, Kit.BL, Kit.BALL, Kit.CYL, Kit.UP

return function(Attacks)

-- ======================================================================
-- CACTO HIPOPÓTAMO
-- ======================================================================
-- 1) Espinas giratorias: espinas que giran alrededor del cuerpo unos segundos; radio de peligro marcado.
-- Daño si te acercás demasiado (como mucho una vez por intervalo).
Attacks.spinningThorns = {
	defaults = { name = "Espinas giratorias", mult = 0.6, windup = 0.7, duration = 4, extra = 5, spikes = 8, tick = 0.8, sound = "spin" },
	start = function(A, s)
		local e, P = A.boss, s.P
		s.r = e.radius + P.extra
		s.zone = Kit.disc(A, s, e.x, e.z, s.r, c3(120, 255, 90), 0.75, 0.2)
		A.fx("z", e.x, 0.3, e.z, s.r, 120, 255, 90, P.windup)
		s.spikes = {}
		for i = 1, P.spikes do
			local sp = A.part(s, BL, Vector3.new(0.6, 0.6, 3.2), c3(230, 240, 200), SM, 1)
			s.spikes[i] = sp
		end
		s.last = {}
		A.tint("w")
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		s.zone.CFrame = CFrame.new(A.W(e.x, 0.2, e.z)) * UP
		local on = s.t >= P.windup
		if on and not s.started then s.started = true; A.untint(); A.sound(P.sound, e.x, e.z) end
		for i, sp in ipairs(s.spikes) do
			local a = s.t * 4 + (i - 1) / #s.spikes * math.pi * 2
			local rr = s.r - 1.6
			local pos = A.W(e.x + math.cos(a) * rr, 3 + math.sin(s.t * 6 + i) * 0.6, e.z + math.sin(a) * rr)
			sp.CFrame = CFrame.lookAt(pos, pos + Vector3.new(math.cos(a), 0, math.sin(a)))
			sp.Transparency = on and 0 or 1
		end
		if on and s.t < P.windup + P.duration then
			s.zone.Transparency = 0.6 + 0.15 * math.sin(s.t * 8)
			for _, p in ipairs(A.players()) do
				if dist(p.x, p.z, e.x, e.z) < s.r then
					local last = s.last[p.m] or -99
					if A.now() - last >= P.tick then
						s.last[p.m] = A.now()
						A.damage(p.m, P.mult, s, "t" .. math.floor(A.now() / P.tick))
					end
				end
			end
		end
		return s.t >= P.windup + P.duration
	end,
	cleanup = function(A) A.untint() end,
}

-- 2) Escupitajo de arena: varios proyectiles con trayectoria visible; daño leve + ralentización breve.
Attacks.sandSpit = {
	defaults = { name = "Escupitajo de arena", mult = 0.45, count = 3, phaseCount = 5, spread = math.rad(12), range = 40, speed = 30, radius = 1.8,
		windup = 0.45, slow = 0.7, slowTime = 1.5, sound = "splat", duration = 2 },
	start = function(A, s)
		local e, P = A.boss, s.P
		local tgt = A.target()
		s.dx, s.dz = 0, 1
		if tgt then s.dx, s.dz = unit(tgt.x - e.x, tgt.z - e.z) end
		A.face(s.dx, s.dz); A.lock(true)
		s.n = A.phase2() and P.phaseCount or P.count
		s.dirs = {}
		local a0 = angle(s.dx, s.dz)
		for i = 1, s.n do
			local a = a0 + (i - (s.n + 1) / 2) * P.spread
			local ux, uz = math.cos(a), math.sin(a)
			table.insert(s.dirs, { ux, uz })
			local len = A.rayLen(e.x, e.z, ux, uz, P.range)
			A.fx("t", e.x, 0.4, e.z, e.x + ux * len, 0.4, e.z + uz * len, 230, 200, 130, 1.4, P.windup + 0.3)
		end
	end,
	update = function(A, s, dt)
		local e, P = A.boss, s.P
		if s.t < P.windup then return false end
		if not s.fired then
			s.fired = true
			A.anim("fire"); A.sound(P.sound, e.x, e.z)
			for i, d in ipairs(s.dirs) do
				local ball = A.part(s, BALL, Vector3.one * 1.6, c3(220, 190, 120), Enum.Material.Sand, 0)
				Kit.trail(ball, c3(230, 200, 130))
				Kit.shoot(A, s, e.x, e.z, d[1], d[2], { range = P.range, speed = P.speed, radius = P.radius, part = ball, y = 3, key = "sand" .. i,
					onHit = function(pl, pr)
						if A.damage(pl.m, P.mult, s, pr.key) then
							A.slow(pl.m, P.slow, P.slowTime)
							A.particles(pr.x, pr.z, 2, { 230, 200, 130 }, 10, 1.5, 10)
							pr.left = 0
						end
					end })
			end
			A.lock(false)
		end
		local flying = Kit.stepShots(A, s, dt)
		return not flying
	end,
	cleanup = function(A) A.face(nil); A.lock(false) end,
}

-- 3) Chapuzón del oasis: salta a una zona grande marcada, al caer deja un charco que ralentiza y daña de a poco.
Attacks.oasisSplash = {
	defaults = { name = "Chapuzón del oasis", mult = 0.9, puddleMult = 0.25, radius = 13, puddleRadius = 11, windup = 0.6, flight = 1.0, height = 20,
		puddleTime = 4, tick = 1.0, slow = 0.6, slowTime = 0.6, push = 40, up = 18, sound = "splat", duration = 6 },
	start = function(A, s)
		local e, P = A.boss, s.P
		s.controlsMove = true
		local tgt = A.target()
		local tx, tz = e.x, e.z
		if tgt then tx, tz = tgt.x + A.rng:number(-4, 4), tgt.z + A.rng:number(-4, 4) end
		s.tx, s.tz = A.validPoint(tx, tz)
		s.fx, s.fz = e.x, e.z
		A.tint("w")
		A.fx("z", s.tx, 0.3, s.tz, P.radius, 80, 170, 255, P.windup + P.flight)
		s.mark = Kit.disc(A, s, s.tx, s.tz, P.radius, c3(80, 170, 255), 0.75, 0.22)
		s.last = {}
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		if s.t < P.windup then A.lift(-s.t / P.windup); return false end
		local k = (s.t - P.windup) / P.flight
		if k < 1 then
			e.x = s.fx + (s.tx - s.fx) * smooth(k); e.z = s.fz + (s.tz - s.fz) * smooth(k)
			A.lift(math.sin(k * math.pi) * P.height)
			return false
		end
		if not s.landed then
			s.landed = true
			e.x, e.z = s.tx, s.tz
			A.lift(0); A.untint(); A.sound(P.sound, s.tx, s.tz, 0.7)
			A.particles(s.tx, s.tz, 1, { 120, 190, 255 }, 30, 2.5, 24)
			s.mark.Transparency = 1
			s.puddle = Kit.disc(A, s, s.tx, s.tz, P.puddleRadius, c3(70, 150, 230), 0.35, 0.18)
			for _, p in ipairs(A.players()) do
				if dist(p.x, p.z, s.tx, s.tz) < P.radius then
					if A.damage(p.m, P.mult, s, "land") then A.push(p.m, s.tx, s.tz, P.push, P.up) end
				end
			end
		end
		local pk = s.t - P.windup - P.flight
		if pk < P.puddleTime then
			for _, p in ipairs(A.players()) do
				if dist(p.x, p.z, s.tx, s.tz) < P.puddleRadius then
					A.slow(p.m, P.slow, P.slowTime)
					local last = s.last[p.m] or (A.now() - 0.4) -- el primer tic llega tras un momento: da tiempo a salir
					if A.now() - last >= P.tick then
						s.last[p.m] = A.now()
						A.damage(p.m, P.puddleMult, s, "pud" .. math.floor(A.now() / P.tick))
					end
				end
			end
			if s.puddle then s.puddle.Transparency = 0.35 + 0.5 * smooth((pk - P.puddleTime + 0.6) / 0.6) end
			return false
		end
		return true
	end,
	cleanup = function(A) A.lift(0); A.untint() end,
}

-- ======================================================================
-- LIRILI LARILA
-- ======================================================================
-- 1) Notas cortantes: aviso breve (líneas) y salen varias notas que viajan en línea recta.
Attacks.cuttingNotes = {
	defaults = { name = "Notas cortantes", mult = 0.6, count = 5, phaseCount = 7, spread = math.rad(14), range = 42, speed = 34, radius = 1.6, windup = 0.6,
		sound = "magic", duration = 2 },
	start = function(A, s)
		local e, P = A.boss, s.P
		local tgt = A.target()
		local dx, dz = 0, 1
		if tgt then dx, dz = unit(tgt.x - e.x, tgt.z - e.z) end
		A.face(dx, dz); A.lock(true); A.tint("w")
		s.dirs = {}
		local n = A.phase2() and P.phaseCount or P.count
		local a0 = angle(dx, dz)
		for i = 1, n do
			local a = a0 + (i - (n + 1) / 2) * P.spread
			local ux, uz = math.cos(a), math.sin(a)
			s.dirs[i] = { ux, uz }
			local len = A.rayLen(e.x, e.z, ux, uz, P.range)
			A.fx("t", e.x, 0.4, e.z, e.x + ux * len, 0.4, e.z + uz * len, 120, 220, 255, 1.2, P.windup + 0.2)
		end
	end,
	update = function(A, s, dt)
		local e, P = A.boss, s.P
		if s.t < P.windup then return false end
		if not s.fired then
			s.fired = true
			A.untint(); A.anim("fire"); A.sound(P.sound, e.x, e.z, 1.3)
			for i, d in ipairs(s.dirs) do
				local note = A.part(s, BL, Vector3.new(1.2, 1.8, 0.4), c3(120, 230, 255), NEON, 0)
				local stem = A.part(s, BL, Vector3.new(0.3, 2.4, 0.3), c3(120, 230, 255), NEON, 0)
				Kit.trail(note, c3(150, 230, 255))
				local pr = Kit.shoot(A, s, e.x, e.z, d[1], d[2], { range = P.range, speed = P.speed, radius = P.radius, part = note, y = 3, key = "n" .. i,
					onHit = function(pl, p) A.damage(pl.m, P.mult, s, "notes") end })
				pr.stem = stem
			end
			A.lock(false)
		end
		local flying = Kit.stepShots(A, s, dt)
		for _, p in ipairs(s.projs or {}) do
			if p.stem then
				if p.alive then p.stem.CFrame = p.part.CFrame * CFrame.new(0.5, 1, 0) else p.stem.Transparency = 1 end
			end
		end
		return not flying
	end,
	cleanup = function(A) A.face(nil); A.lock(false); A.untint() end,
}

-- 2) Acorde congelante: círculo de sonido alrededor del jefe; daño leve y ralentización (nunca congela del todo).
Attacks.freezingChord = {
	defaults = { name = "Acorde congelante", mult = 0.45, radius = 14, windup = 0.9, slow = 0.5, slowTime = 2, sound = "ice", duration = 1.4 },
	start = function(A, s)
		local e, P = A.boss, s.P
		A.lock(true); A.tint("w"); A.anim("fire")
		s.cx, s.cz = e.x, e.z
		A.fx("z", s.cx, 0.3, s.cz, P.radius, 140, 220, 255, P.windup)
		s.rings = { Kit.ring(A, s, 20, c3(160, 230, 255), 0.6, 0.6, 0.3), Kit.ring(A, s, 20, c3(160, 230, 255), 0.6, 0.6, 0.3) }
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		if s.t < P.windup then
			for i, r in ipairs(s.rings) do
				local k = ((s.t * 1.6 + i * 0.5) % 1)
				Kit.placeRing(A, r, s.cx, s.cz, P.radius * (0.3 + 0.7 * k), 0, 1 + i)
			end
			return false
		end
		if not s.hit then
			s.hit = true
			A.untint(); A.sound(P.sound, s.cx, s.cz)
			for _, r in ipairs(s.rings) do Kit.placeRing(A, r, s.cx, s.cz, P.radius, 0, 1) end
			A.particles(s.cx, s.cz, 2, { 170, 230, 255 }, 26, 2, 20)
			for _, p in ipairs(A.players()) do
				if dist(p.x, p.z, s.cx, s.cz) < P.radius then
					if A.damage(p.m, P.mult, s, "chord") then A.slow(p.m, P.slow, P.slowTime) end
				end
			end
		end
		return s.t >= P.windup + 0.35
	end,
	cleanup = function(A) A.lock(false); A.untint() end,
}

-- 3) Torbellino de baile: aviso (gira en el lugar), después gira y se desplaza por un tramo corto con zona de daño.
Attacks.danceWhirlwind = {
	defaults = { name = "Torbellino de baile", mult = 0.9, windup = 0.8, duration = 2.4, speed = 12, extra = 3, sound = "spin" },
	start = function(A, s)
		local e, P = A.boss, s.P
		s.controlsMove = true
		local tgt = A.target()
		s.dx, s.dz = 0, 1
		if tgt then s.dx, s.dz = unit(tgt.x - e.x, tgt.z - e.z) end
		s.r = e.radius + P.extra
		A.tint("w")
		local len = A.rayLen(e.x, e.z, s.dx, s.dz, P.speed * P.duration)
		s.path = Kit.line(A, s, e.x, e.z, e.x + s.dx * len, e.z + s.dz * len, s.r * 2, c3(255, 120, 200), 0.75)
		s.zone = Kit.disc(A, s, e.x, e.z, s.r, c3(255, 120, 200), 0.65, 0.25)
		s.spin = 0
	end,
	update = function(A, s, dt)
		local e, P = A.boss, s.P
		s.spin += dt * (s.t < P.windup and 8 or 22)
		A.face(math.cos(s.spin), math.sin(s.spin))
		s.zone.CFrame = CFrame.new(A.W(e.x, 0.25, e.z)) * UP
		if s.t < P.windup then return false end
		if not s.go then s.go = true; A.untint(); A.sound(P.sound, e.x, e.z); s.path.Transparency = 0.85 end
		if s.t < P.windup + P.duration then
			local nx, nz, ok = A.validPoint(e.x + s.dx * P.speed * dt, e.z + s.dz * P.speed * dt)
			if ok then e.x, e.z = nx, nz end
			for _, p in ipairs(A.players()) do
				if dist(p.x, p.z, e.x, e.z) < s.r then
					if A.damage(p.m, P.mult, s, "whirl") then A.push(p.m, e.x, e.z, 35, 14) end
				end
			end
			return false
		end
		return true
	end,
	cleanup = function(A) A.face(nil); A.untint() end,
}

-- ======================================================================
-- SIGMA BOY
-- ======================================================================
-- 1) Mirada sigma: línea de apuntado que sigue al jugador y se fija; luego un rayo recto que no atraviesa paredes.
Attacks.sigmaGaze = {
	defaults = { name = "Mirada sigma", mult = 1.2, range = 50, width = 3, windup = 1.1, lockAt = 0.75, beamTime = 0.35, sound = "zap", duration = 1.6 },
	start = function(A, s)
		local e, P = A.boss, s.P
		A.lock(true); A.tint("w")
		s.dx, s.dz = 0, 1
		s.aim = Kit.line(A, s, e.x, e.z, e.x, e.z + 1, 0.5, c3(255, 60, 60), 0.3, 3)
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		if s.t < P.lockAt then
			local tgt = A.target()
			if tgt then s.dx, s.dz = unit(tgt.x - e.x, tgt.z - e.z) end
		end
		A.face(s.dx, s.dz)
		s.len = A.rayLen(e.x, e.z, s.dx, s.dz, P.range)
		if s.t < P.windup then
			Kit.moveLine(A, s.aim, e.x, e.z, e.x + s.dx * s.len, e.z + s.dz * s.len, 3)
			s.aim.Size = Vector3.new(s.t >= P.lockAt and P.width or 0.5, 0.2, s.aim.Size.Z)
			s.aim.Transparency = s.t >= P.lockAt and (0.3 + 0.3 * math.abs(math.sin(s.t * 20))) or 0.3
			return false
		end
		if not s.fired then
			s.fired = true
			A.untint(); A.anim("fire"); A.sound(P.sound, e.x, e.z)
			s.aim.Transparency = 1
			s.beam = Kit.line(A, s, e.x, e.z, e.x + s.dx * s.len, e.z + s.dz * s.len, P.width, c3(255, 230, 120), 0.1, 3)
			s.beam.Size = Vector3.new(P.width, P.width, s.beam.Size.Z)
			for _, p in ipairs(A.players()) do
				-- distancia del jugador a la línea del rayo (solo hasta la pared)
				local rx, rz = p.x - e.x, p.z - e.z
				local along = rx * s.dx + rz * s.dz
				local perp = math.abs(rx * s.dz - rz * s.dx)
				if along > 0 and along <= s.len and perp < P.width / 2 + 1 then A.damage(p.m, P.mult, s, "beam") end
			end
		end
		if s.beam then s.beam.Transparency = math.min(1, 0.1 + (s.t - P.windup) / P.beamTime) end
		return s.t >= P.windup + P.beamTime
	end,
	cleanup = function(A) A.lock(false); A.face(nil); A.untint() end,
}

-- 2) Aura de superioridad: aura visible alrededor del jefe; daño leve periódico (una vez por intervalo).
Attacks.superiorityAura = {
	defaults = { name = "Aura de superioridad", mult = 0.35, radius = 12, windup = 0.7, duration = 5, tick = 1.0, sound = "aura" },
	start = function(A, s)
		local e, P = A.boss, s.P
		A.fx("z", e.x, 0.3, e.z, P.radius, 150, 150, 255, P.windup)
		s.disc = Kit.disc(A, s, e.x, e.z, P.radius, c3(150, 150, 255), 0.8, 0.22)
		s.ring = Kit.ring(A, s, 22, c3(170, 170, 255), 0.5, 1.4, 0.3)
		s.last = {}
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		s.disc.CFrame = CFrame.new(A.W(e.x, 0.22, e.z)) * UP
		Kit.placeRing(A, s.ring, e.x, e.z, P.radius, s.t, 1.2)
		if s.t < P.windup then return false end
		if not s.on then s.on = true; A.sound(P.sound, e.x, e.z); s.disc.Transparency = 0.6 end
		for _, p in ipairs(A.players()) do
			if dist(p.x, p.z, e.x, e.z) < P.radius then
				local last = s.last[p.m] or -99
				if A.now() - last >= P.tick then
					s.last[p.m] = A.now()
					A.damage(p.m, P.mult, s, "a" .. math.floor(A.now() / P.tick))
				end
			end
		end
		return s.t >= P.windup + P.duration
	end,
}

-- 3) Dash sigma: hasta 3 desplazamientos rápidos; cada uno muestra la dirección antes y termina con daño en zona chica.
Attacks.sigmaDash = {
	defaults = { name = "Dash sigma", mult = 0.9, dashes = 3, length = 18, warn = 0.55, dashTime = 0.22, gap = 0.45, radius = 6, push = 40, up = 16, sound = "dash" },
	start = function(A, s)
		s.controlsMove = true
		s.i = 0; s.phaseT = 0; s.state = "next"
	end,
	update = function(A, s, dt)
		local e, P = A.boss, s.P
		s.phaseT += dt
		if s.state == "next" then
			s.i += 1
			if s.i > P.dashes then return true end
			local tgt = A.target()
			local dx, dz = 0, 1
			if tgt then dx, dz = unit(tgt.x - e.x, tgt.z - e.z) end
			local len = math.min(P.length, A.rayLen(e.x, e.z, dx, dz, P.length))
			local tx, tz, ok = A.validPoint(e.x + dx * len, e.z + dz * len)
			s.fx, s.fz, s.tx, s.tz = e.x, e.z, tx, tz
			A.face(dx, dz); A.tint("w")
			if s.arrow and s.arrow.Parent then s.arrow:Destroy() end
			s.arrow = Kit.line(A, s, e.x, e.z, tx, tz, 2.5, c3(150, 150, 255), 0.45)
			A.fx("z", tx, 0.3, tz, P.radius, 150, 150, 255, P.warn + P.dashTime)
			s.state = "warn"; s.phaseT = 0
		elseif s.state == "warn" and s.phaseT >= P.warn then
			s.state = "dash"; s.phaseT = 0; A.untint(); A.sound(P.sound, e.x, e.z)
		elseif s.state == "dash" then
			local k = math.min(1, s.phaseT / P.dashTime)
			e.x = s.fx + (s.tx - s.fx) * k; e.z = s.fz + (s.tz - s.fz) * k
			if k >= 1 then
				if s.arrow then s.arrow.Transparency = 1 end
				A.fx("b", s.tx, 0.5, s.tz, P.radius, 150, 150, 255, 0.3)
				A.particles(s.tx, s.tz, 1, { 170, 170, 255 }, 12, 2, 14)
				for _, p in ipairs(A.players()) do
					if dist(p.x, p.z, s.tx, s.tz) < P.radius then
						if A.damage(p.m, P.mult, s, "d" .. s.i) then A.push(p.m, s.tx, s.tz, P.push, P.up) end
					end
				end
				s.state = "gap"; s.phaseT = 0
			end
		elseif s.state == "gap" and s.phaseT >= P.gap then
			s.state = "next"
		end
		return false
	end,
	cleanup = function(A) A.face(nil); A.untint() end,
}

end
