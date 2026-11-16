--!nonstrict
-- Bosses/SkillsSecret: habilidades de los jefes del MAPA SECRETO (La Esok Sekolah, La Vaca Saturno, 67).
-- Cada habilidad: defaults = { name, mult, range, duration, windup, sound, ... }. Cooldowns en Config/BossConfig.
local Kit = require(script.Parent.BossSkillKit)
local dist, smooth, angle, unit = Kit.dist, Kit.smooth, Kit.angle, Kit.unit
local c3 = Kit.c3
local NEON, SM, SLATE, BL, BALL, CYL, UP = Kit.NEON, Kit.SM, Kit.SLATE, Kit.BL, Kit.BALL, Kit.CYL, Kit.UP

return function(Attacks)

-- ======================================================================
-- LA ESOK SEKOLAH (funcionan junto con la noche y la música de miedo: todo en Neon para verse en la oscuridad)
-- ======================================================================
-- 1) Campana maldita: suena la campana y salen círculos de sonido que se expanden despacio. Daño + ralentización breve.
Attacks.cursedBell = {
	defaults = { name = "Campana maldita", mult = 0.8, rings = 2, phaseRings = 3, windup = 0.9, speed = 11, maxRadius = 30, gap = 0.8, band = 2.2,
		slow = 0.6, slowTime = 1.2, sound = "glass", duration = 4 },
	start = function(A, s)
		local e, P = A.boss, s.P
		A.lock(true); A.tint("w")
		s.cx, s.cz = e.x, e.z
		s.bell = A.part(s, BALL, Vector3.new(4, 4, 4), c3(230, 200, 90), Enum.Material.Metal, 0)
		local l = Instance.new("PointLight"); l.Color = c3(255, 220, 140); l.Range = 18; l.Brightness = 3; l.Parent = s.bell
		A.fx("z", s.cx, 0.3, s.cz, P.maxRadius, 200, 140, 255, P.windup)
		s.rings = {}
		for i = 1, (A.phase2() and P.phaseRings or P.rings) do
			local r = { parts = Kit.ring(A, s, 24, c3(220, 170, 255), 0.7, 1.6, 0.05), t0 = P.windup + (i - 1) * P.gap }
			Kit.hide(r.parts)
			s.rings[i] = r
		end
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		s.bell.CFrame = CFrame.new(A.W(s.cx, e.visSize + 4, s.cz)) * CFrame.Angles(math.sin(s.t * 14) * 0.5, 0, 0)
		if s.t < P.windup then return false end
		local done = true
		for _, r in ipairs(s.rings) do
			local rad = (s.t - r.t0) * P.speed
			if rad < 0 then done = false
			elseif rad <= P.maxRadius then
				done = false
				if not r.rang then r.rang = true; A.sound(P.sound, s.cx, s.cz, 0.6); A.untint() end
				Kit.placeRing(A, r.parts, s.cx, s.cz, math.max(1, rad), 0, 1)
				for _, p in ipairs(A.players()) do
					local d = dist(p.x, p.z, s.cx, s.cz)
					if math.abs(d - rad) < P.band then
						if A.damage(p.m, P.mult, s, "bell") then A.slow(p.m, P.slow, P.slowTime) end
					end
				end
			else
				Kit.hide(r.parts)
			end
		end
		return done
	end,
	cleanup = function(A) A.lock(false); A.untint() end,
}

-- 2) Pizarrón maldito: símbolos oscuros marcados en el suelo; tras unos segundos liberan energía.
Attacks.cursedBlackboard = {
	defaults = { name = "Pizarrón maldito", mult = 1.0, count = 4, phaseCount = 5, radius = 5.5, windup = 2.0, duration = 0.6,
		nearMin = 3, nearMax = 5, minOffset = 7, maxOffset = 16, sound = "magic" },
	start = function(A, s)
		local P = s.P
		A.anim("fire")
		local n = A.phase2() and P.phaseCount or P.count
		s.boards = {}
		for i, q in ipairs(Kit.scatter(A, n, P.nearMin, P.nearMax, P.minOffset, P.maxOffset)) do
			local disc = Kit.disc(A, s, q[1], q[2], P.radius, c3(120, 40, 200), 0.55, 0.2)
			local board = A.part(s, BL, Vector3.new(P.radius * 1.2, 0.25, P.radius * 0.8), c3(30, 50, 35), SLATE, 0)
			board.CFrame = CFrame.new(A.W(q[1], 0.3, q[2])) * CFrame.Angles(0, A.rng:number(0, 3), 0)
			local mark = A.part(s, BL, Vector3.new(P.radius * 0.9, 0.3, 0.35), c3(220, 120, 255), NEON, 0)
			mark.CFrame = board.CFrame * CFrame.Angles(0, 0.7, 0)
			s.boards[i] = { x = q[1], z = q[2], disc = disc, key = "bb" }
		end
	end,
	update = function(A, s)
		local P = s.P
		if s.t < P.windup then
			for _, b in ipairs(s.boards) do b.disc.Transparency = 0.25 + 0.35 * math.abs(math.sin(s.t * (4 + s.t * 4))) end
			return false
		end
		if not s.fired then
			s.fired = true
			A.sound(P.sound, s.boards[1] and s.boards[1].x or 0, s.boards[1] and s.boards[1].z or 0, 0.7)
			for _, b in ipairs(s.boards) do
				local pillar = A.part(s, CYL, Vector3.new(30, P.radius * 1.6, P.radius * 1.6), c3(200, 110, 255), NEON, 0.3)
				pillar.CFrame = CFrame.new(A.W(b.x, 15, b.z)) * UP
				b.pillar = pillar
				A.particles(b.x, b.z, 2, { 200, 120, 255 }, 18, 2, 18)
				for _, p in ipairs(A.players()) do
					if dist(p.x, p.z, b.x, b.z) < P.radius then A.damage(p.m, P.mult, s, b.key) end
				end
			end
		end
		for _, b in ipairs(s.boards) do if b.pillar then b.pillar.Transparency = 0.3 + 0.7 * ((s.t - P.windup) / P.duration) end end
		return s.t >= P.windup + P.duration
	end,
}

-- 3) Corredor oscuro: puertas de sombra; tras una advertencia, algunas sombras cruzan en línea recta.
-- Los carriles se reparten para que NO todos pasen por donde está el jugador.
Attacks.darkCorridor = {
	defaults = { name = "Corredor oscuro", mult = 1.0, lanes = 4, phaseLanes = 5, active = 3, phaseActive = 4, spacing = 9, length = 70, width = 5,
		windup = 1.4, speed = 30, sound = "wind", duration = 4 },
	start = function(A, s)
		local e, P = A.boss, s.P
		local tgt = A.target()
		local tx, tz = e.x, e.z
		if tgt then tx, tz = tgt.x, tgt.z end
		local ax, az = unit(tx - e.x, tz - e.z)
		s.ux, s.uz = -az, ax
		local nl = A.phase2() and P.phaseLanes or P.lanes
		local na = math.min(nl, A.phase2() and P.phaseActive or P.active)
		local lanes = {}
		for i = 1, nl do
			local off = (i - (nl + 1) / 2) * P.spacing
			if nl % 2 == 1 then off += P.spacing * 0.5 end -- nunca un carril justo sobre el jugador
			table.insert(lanes, off)
		end
		for i = #lanes, 2, -1 do local j = A.rng:integer(1, i); lanes[i], lanes[j] = lanes[j], lanes[i] end
		s.shadows = {}
		for i = 1, na do
			local off = lanes[i]
			local cx, cz = tx + ax * off, tz + az * off
			local x1, z1 = cx - s.ux * P.length / 2, cz - s.uz * P.length / 2
			local x2, z2 = cx + s.ux * P.length / 2, cz + s.uz * P.length / 2
			local door = A.part(s, BL, Vector3.new(P.width, 10, 1.2), c3(25, 10, 40), SM, 0)
			door.CFrame = CFrame.lookAt(A.W(x1, 5, z1), A.W(x2, 5, z2)) * CFrame.Angles(0, math.pi / 2, 0)
			local frame = A.part(s, BL, Vector3.new(P.width + 1, 11, 0.6), c3(170, 60, 255), NEON, 0.2)
			frame.CFrame = door.CFrame * CFrame.new(0, 0.5, 0.5)
			local warn = Kit.line(A, s, x1, z1, x2, z2, P.width, c3(140, 50, 220), 0.6)
			local shadow = A.part(s, BALL, Vector3.new(P.width, 6, P.width), c3(15, 5, 25), SM, 1)
			s.shadows[i] = { x1 = x1, z1 = z1, x2 = x2, z2 = z2, warn = warn, part = shadow, key = "dark" }
		end
	end,
	update = function(A, s)
		local P = s.P
		if s.t < P.windup then
			for _, sh in ipairs(s.shadows) do sh.warn.Transparency = 0.35 + 0.3 * math.abs(math.sin(s.t * 7)) end
			return false
		end
		if not s.go then s.go = true; A.sound(P.sound, s.shadows[1] and s.shadows[1].x1 or 0, s.shadows[1] and s.shadows[1].z1 or 0, 0.5) end
		local k = (s.t - P.windup) * P.speed / P.length
		for _, sh in ipairs(s.shadows) do
			local kk = math.min(1, k)
			local x, z = sh.x1 + (sh.x2 - sh.x1) * kk, sh.z1 + (sh.z2 - sh.z1) * kk
			sh.part.Transparency = k < 1 and 0.15 or 1
			sh.part.CFrame = CFrame.new(A.W(x, 3, z))
			sh.warn.Transparency = 0.8
			if k < 1 then
				for _, p in ipairs(A.players()) do
					if dist(p.x, p.z, x, z) < P.width / 2 + 1.2 then A.damage(p.m, P.mult, s, sh.key) end
				end
			end
		end
		return k >= 1.05
	end,
}

-- ======================================================================
-- LA VACA SATURNO
-- ======================================================================
-- 1) Rayo cósmico: carga en los cuernos, línea de apuntado (se fija antes), rayo recto de daño alto. Se esquiva de costado.
Attacks.cosmicBeam = {
	defaults = { name = "Rayo cósmico", mult = 1.6, range = 60, width = 3.5, windup = 1.3, lockAt = 0.85, beamTime = 0.4, sound = "zap", duration = 1.8 },
	start = function(A, s)
		local e, P = A.boss, s.P
		A.lock(true); A.tint("w")
		s.dx, s.dz = 0, 1
		s.aim = Kit.line(A, s, e.x, e.z, e.x, e.z + 1, 0.6, c3(255, 220, 120), 0.3, 3)
		s.orb = A.part(s, BALL, Vector3.one * 1, c3(255, 230, 150), NEON, 0)
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		if s.t < P.lockAt then
			local tgt = A.target()
			if tgt then s.dx, s.dz = unit(tgt.x - e.x, tgt.z - e.z) end
		end
		A.face(s.dx, s.dz)
		s.len = A.rayLen(e.x, e.z, s.dx, s.dz, P.range)
		local horn = A.W(e.x + s.dx * 3, e.visSize * 0.9, e.z + s.dz * 3)
		if s.t < P.windup then
			local k = s.t / P.windup
			s.orb.Size = Vector3.one * (1 + k * 4)
			s.orb.CFrame = CFrame.new(horn)
			Kit.moveLine(A, s.aim, e.x, e.z, e.x + s.dx * s.len, e.z + s.dz * s.len, 3)
			s.aim.Size = Vector3.new(s.t >= P.lockAt and P.width or 0.6, 0.2, s.aim.Size.Z)
			s.aim.Transparency = s.t >= P.lockAt and (0.25 + 0.3 * math.abs(math.sin(s.t * 22))) or 0.35
			return false
		end
		if not s.fired then
			s.fired = true
			A.untint(); A.sound(P.sound, e.x, e.z, 0.7)
			s.aim.Transparency = 1; s.orb.Transparency = 1
			s.beam = Kit.line(A, s, e.x, e.z, e.x + s.dx * s.len, e.z + s.dz * s.len, P.width, c3(255, 240, 180), 0.05, 3)
			s.beam.Size = Vector3.new(P.width, P.width, s.beam.Size.Z)
			for _, p in ipairs(A.players()) do
				local rx, rz = p.x - e.x, p.z - e.z
				local along = rx * s.dx + rz * s.dz
				local perp = math.abs(rx * s.dz - rz * s.dx)
				if along > 0 and along <= s.len and perp < P.width / 2 + 1 then A.damage(p.m, P.mult, s, "beam") end
			end
		end
		if s.beam then s.beam.Transparency = math.min(1, 0.05 + (s.t - P.windup) / P.beamTime) end
		return s.t >= P.windup + P.beamTime
	end,
	cleanup = function(A) A.lock(false); A.face(nil); A.untint() end,
}

-- 2) Tormenta de leche: gotas de leche desde el cielo con zonas marcadas; al caer dañan y dejan charcos que ralentizan.
Attacks.milkStorm = {
	defaults = { name = "Tormenta de leche", mult = 0.8, count = 5, phaseCount = 7, radius = 5, puddleRadius = 5, warn = 1.2, fall = 0.5, height = 60,
		puddleTime = 4, slow = 0.6, slowTime = 0.5, nearMin = 2.5, nearMax = 4, minOffset = 6, maxOffset = 16, sound = "splat", duration = 6 },
	combo = true,
	start = function(A, s)
		local P = s.P
		A.anim("fire")
		local n = A.phase2() and P.phaseCount or P.count
		s.drops = {}
		for i, q in ipairs(Kit.scatter(A, n, P.nearMin, P.nearMax, P.minOffset, P.maxOffset)) do
			local delay = (i - 1) * 0.15
			A.fx("z", q[1], 0.3, q[2], P.radius, 255, 255, 255, P.warn + delay)
			local drop = A.part(s, BALL, Vector3.one * 3.5, c3(250, 250, 245), SM, 0)
			s.drops[i] = { x = q[1], z = q[2], part = drop, t0 = P.warn + delay - P.fall, key = "milk" .. i }
		end
	end,
	update = function(A, s)
		local P = s.P
		local last = 0
		for _, d in ipairs(s.drops) do
			local k = (s.t - d.t0) / P.fall
			if k < 1 then
				d.part.CFrame = CFrame.new(A.W(d.x, P.height * (1 - math.max(0, k) ^ 2) + 1.5, d.z))
			elseif not d.hit then
				d.hit = true; d.landT = s.t
				d.part.Transparency = 1
				A.sound(P.sound, d.x, d.z)
				A.particles(d.x, d.z, 1, { 255, 255, 250 }, 14, 2, 14)
				d.puddle = Kit.disc(A, s, d.x, d.z, P.puddleRadius, c3(250, 250, 245), 0.25, 0.18)
				d.puddle.Material = SM
				for _, p in ipairs(A.players()) do
					if dist(p.x, p.z, d.x, d.z) < P.radius then A.damage(p.m, P.mult, s, d.key) end
				end
			end
			if d.hit and s.t - d.landT < P.puddleTime then
				for _, p in ipairs(A.players()) do
					if dist(p.x, p.z, d.x, d.z) < P.puddleRadius then A.slow(p.m, P.slow, P.slowTime) end
				end
				d.puddle.Transparency = 0.25 + 0.75 * smooth((s.t - d.landT - P.puddleTime + 0.5) / 0.5)
			end
			last = math.max(last, d.t0 + P.fall + P.puddleTime)
		end
		return s.t >= last
	end,
}

-- 3) Portal interplanetario: dos portales visibles; la Vaca entra por uno y sale por el otro (marcado antes),
-- con una explosión pequeña al salir. Nunca dentro de una pared ni fuera del mapa.
Attacks.interplanetaryPortal = {
	defaults = { name = "Portal interplanetario", mult = 0.9, trips = 2, warn = 1.0, travel = 0.4, stay = 1.2, radius = 7, minFromPlayer = 10, push = 45, up = 20,
		sound = "magic", duration = 5 },
	start = function(A, s)
		local e, P = A.boss, s.P
		s.controlsMove = true
		s.ax, s.az = e.x, e.z
		local tgt = A.target()
		local bx, bz
		for _ = 1, 16 do
			local a = A.rng:number(0, math.pi * 2)
			local d = A.rng:number(14, 24)
			local cx, cz = (tgt and tgt.x or e.x) + math.cos(a) * d, (tgt and tgt.z or e.z) + math.sin(a) * d
			local x, z, ok = A.validPoint(cx, cz)
			if ok and (not tgt or dist(x, z, tgt.x, tgt.z) >= P.minFromPlayer) then bx, bz = x, z; break end
		end
		if not bx then bx, bz = e.x, e.z end
		s.bx, s.bz = bx, bz
		local function portal(x, z, col)
			local p = A.part(s, CYL, Vector3.new(0.6, 12, 12), col, NEON, 0.25)
			p.CFrame = CFrame.new(A.W(x, 0.4, z)) * UP
			local ring = A.part(s, CYL, Vector3.new(0.4, 14, 14), c3(255, 255, 255), NEON, 0.6)
			ring.CFrame = CFrame.new(A.W(x, 0.3, z)) * UP
			return p
		end
		s.pa = portal(s.ax, s.az, c3(255, 170, 90))
		s.pb = portal(s.bx, s.bz, c3(120, 170, 255))
		s.trip = 0; s.phaseT = 0; s.state = "warn"
		A.fx("z", s.bx, 0.3, s.bz, P.radius, 255, 80, 60, P.warn + P.travel)
	end,
	update = function(A, s, dt)
		local e, P = A.boss, s.P
		s.phaseT += dt
		if s.state == "warn" then
			if s.phaseT >= P.warn then s.state = "travel"; s.phaseT = 0; A.hide(true); A.immune(P.travel + 0.1); A.sound(P.sound, e.x, e.z) end
		elseif s.state == "travel" then
			if s.phaseT >= P.travel then
				s.trip += 1
				local tx, tz = s.bx, s.bz
				if s.trip % 2 == 0 then tx, tz = s.ax, s.az end
				e.x, e.z = tx, tz
				A.hide(false)
				A.fx("X", tx, tz, P.radius)
				for _, p in ipairs(A.players()) do
					if dist(p.x, p.z, tx, tz) < P.radius then
						if A.damage(p.m, P.mult, s, "exit" .. s.trip) then A.push(p.m, tx, tz, P.push, P.up) end
					end
				end
				if s.trip >= P.trips then return true end
				s.state = "stay"; s.phaseT = 0
			end
		elseif s.state == "stay" and s.phaseT >= P.stay then
			local nx, nz = s.ax, s.az
			if s.trip % 2 == 0 then nx, nz = s.bx, s.bz end
			A.fx("z", nx, 0.3, nz, P.radius, 255, 80, 60, P.warn + P.travel)
			s.state = "warn"; s.phaseT = 0
		end
		return false
	end,
	cleanup = function(A) A.hide(false) end,
}

-- ======================================================================
-- 67
-- ======================================================================
-- 1) Doble impacto 6-7: dos zonas seguidas; golpea la primera ("6") y después la segunda ("7").
Attacks.doubleImpact = {
	defaults = { name = "Doble impacto 6-7", mult = 1.0, radius = 7, spacing = 11, windup = 1.0, gap = 0.6, push = 45, up = 20, sound = "sixseven", duration = 2 },
	start = function(A, s)
		local e, P = A.boss, s.P
		local tgt = A.target()
		local tx, tz = e.x, e.z + 10
		if tgt then tx, tz = tgt.x, tgt.z end
		local dx, dz = unit(tx - e.x, tz - e.z)
		A.lock(true); A.face(dx, dz); A.tint("w")
		local x1, z1 = A.clampPoint(tx - dx * P.spacing * 0.3, tz - dz * P.spacing * 0.3)
		local x2, z2 = A.clampPoint(x1 + dx * P.spacing, z1 + dz * P.spacing)
		s.zones = { { x = x1, z = z1, at = P.windup, label = "6" }, { x = x2, z = z2, at = P.windup + P.gap, label = "7" } }
		for i, zn in ipairs(s.zones) do
			A.fx("z", zn.x, 0.3, zn.z, P.radius, 255, i == 1 and 90 or 160, 60, zn.at)
			local tag = A.part(s, BL, Vector3.one * 0.2, c3(255, 255, 255), SM, 1)
			tag.CFrame = CFrame.new(A.W(zn.x, 6, zn.z))
			local bb = Instance.new("BillboardGui"); bb.Size = UDim2.fromOffset(80, 80); bb.AlwaysOnTop = true; bb.LightInfluence = 0; bb.Parent = tag
			local tl = Instance.new("TextLabel"); tl.Size = UDim2.fromScale(1, 1); tl.BackgroundTransparency = 1; tl.Font = Enum.Font.FredokaOne
			tl.TextScaled = true; tl.Text = zn.label; tl.TextColor3 = c3(255, 220, 90); tl.TextStrokeTransparency = 0; tl.Parent = bb
			zn.tag = tag
		end
	end,
	update = function(A, s)
		local P = s.P
		local done = true
		for i, zn in ipairs(s.zones) do
			if not zn.hit then
				if s.t >= zn.at then
					zn.hit = true
					zn.tag.Transparency = 1; local bb = zn.tag:FindFirstChildOfClass("BillboardGui"); if bb then bb.Enabled = false end
					A.anim("punch"); A.sound(P.sound, zn.x, zn.z, i == 1 and 1 or 1.15)
					A.fx("b", zn.x, 0.5, zn.z, P.radius, 255, 200, 90, 0.35)
					A.particles(zn.x, zn.z, 0.5, { 255, 200, 90 }, 16, 2.5, 16)
					for _, p in ipairs(A.players()) do
						if dist(p.x, p.z, zn.x, zn.z) < P.radius then
							-- el "6" empuja poco (para no lanzarte dentro del "7"); el "7" empuja fuerte
							if A.damage(p.m, P.mult, s, "z" .. i) then A.push(p.m, zn.x, zn.z, i == 1 and P.push * 0.3 or P.push, P.up) end
						end
					end
				else
					done = false
				end
			end
		end
		return done and s.t >= P.windup + P.gap + 0.2
	end,
	cleanup = function(A) A.lock(false); A.face(nil); A.untint() end,
}

-- 2) Cuenta regresiva: contador visible sobre una zona; al llegar a cero explota. Hay tiempo para salir y no cubre toda la arena.
Attacks.countdown = {
	defaults = { name = "Cuenta regresiva", mult = 1.4, radius = 10, from = 3, sound = "tick", boomSound = "boom", duration = 3.5 },
	start = function(A, s)
		local e, P = A.boss, s.P
		local tgt = A.target()
		local tx, tz = e.x, e.z
		if tgt then tx, tz = tgt.x, tgt.z end
		s.x, s.z = A.clampPoint(tx, tz)
		A.anim("fire")
		s.disc = Kit.disc(A, s, s.x, s.z, P.radius, c3(255, 60, 60), 0.6, 0.22)
		s.edge = Kit.ring(A, s, 24, c3(255, 90, 90), 0.5, 1.2, 0.1)
		Kit.placeRing(A, s.edge, s.x, s.z, P.radius, 0, 0.8)
		local tag = A.part(s, BL, Vector3.one * 0.2, c3(255, 255, 255), SM, 1)
		tag.CFrame = CFrame.new(A.W(s.x, 9, s.z))
		local bb = Instance.new("BillboardGui"); bb.Size = UDim2.fromOffset(140, 140); bb.AlwaysOnTop = true; bb.LightInfluence = 0; bb.Parent = tag
		local tl = Instance.new("TextLabel"); tl.Size = UDim2.fromScale(1, 1); tl.BackgroundTransparency = 1; tl.Font = Enum.Font.FredokaOne
		tl.TextScaled = true; tl.TextColor3 = c3(255, 80, 80); tl.TextStrokeTransparency = 0; tl.Parent = bb
		s.label = tl
		s.shown = -1
	end,
	update = function(A, s)
		local P = s.P
		local left = math.ceil(P.from - s.t)
		if left > 0 then
			if left ~= s.shown then
				s.shown = left; s.label.Text = tostring(left)
				A.sound(P.sound, s.x, s.z, 1 + (P.from - left) * 0.15)
			end
			s.disc.Transparency = 0.6 - 0.35 * (s.t / P.from) + 0.1 * math.sin(s.t * 12)
			return false
		end
		if not s.boom then
			s.boom = true
			s.label.Text = "0"
			A.fx("X", s.x, s.z, P.radius)
			A.particles(s.x, s.z, 1, { 255, 120, 60 }, 30, 3, 26)
			for _, p in ipairs(A.players()) do
				if dist(p.x, p.z, s.x, s.z) < P.radius then
					if A.damage(p.m, P.mult, s, "boom") then A.push(p.m, s.x, s.z, 55, 24) end
				end
			end
		end
		return s.t >= P.from + 0.3
	end,
}

-- 3) Glitch 67: copias distorsionadas (sin vida, no reciben daño); el 67 real reaparece en otro lugar (marcado antes)
-- y deja una zona chica de daño donde aparece.
Attacks.glitch67 = {
	defaults = { name = "Glitch 67", mult = 0.9, copies = 3, phaseCopies = 4, duration = 2.6, warn = 0.8, radius = 6, minMove = 12, sound = "zap", push = 40, up = 18 },
	start = function(A, s)
		local e, P = A.boss, s.P
		s.controlsMove = true
		A.sound(P.sound, e.x, e.z, 0.6)
		local n = A.phase2() and P.phaseCopies or P.copies
		s.copies = {}
		for i = 1, n do
			local a = (i - 1) / n * math.pi * 2 + A.rng:number(-0.3, 0.3)
			local x, z = A.clampPoint(e.x + math.cos(a) * 10, e.z + math.sin(a) * 10)
			local m = A.buildModel(e.modelId, e.visSize, A.W(x, e.visSize / 2, z))
			if m then
				for _, d in ipairs(m:GetDescendants()) do
					if d:IsA("BasePart") and d.Transparency < 0.9 then d.Transparency = math.max(d.Transparency, 0.4); d.Color = d.Color:Lerp(c3(255, 40, 160), 0.5) end
				end
				table.insert(s.parts, m)
				table.insert(s.copies, { m = m, x = x, z = z })
			end
		end
		A.hide(true); A.immune(P.duration + 0.2)
		local tgt = A.target()
		for _ = 1, 16 do
			local a = A.rng:number(0, math.pi * 2)
			local d = A.rng:number(10, 20)
			local cx, cz = (tgt and tgt.x or e.x) + math.cos(a) * d, (tgt and tgt.z or e.z) + math.sin(a) * d
			local x, z, ok = A.validPoint(cx, cz)
			if ok and dist(x, z, e.x, e.z) >= P.minMove then s.rx, s.rz = x, z; break end
		end
		if not s.rx then s.rx, s.rz = e.x, e.z end
	end,
	update = function(A, s)
		local e, P = A.boss, s.P
		for i, c in ipairs(s.copies) do
			if c.m.PrimaryPart then
				local jx, jz = A.rng:number(-0.8, 0.8), A.rng:number(-0.8, 0.8)
				c.m.PrimaryPart.CFrame = CFrame.new(A.W(c.x + jx, e.visSize / 2, c.z + jz)) * CFrame.Angles(0, s.t * 3 + i, A.rng:number(-0.15, 0.15))
			end
		end
		if not s.warned and s.t >= P.duration - P.warn then
			s.warned = true
			A.fx("z", s.rx, 0.3, s.rz, P.radius, 255, 40, 160, P.warn)
		end
		if s.t >= P.duration then
			e.x, e.z = s.rx, s.rz
			A.hide(false)
			A.fx("b", s.rx, 0.5, s.rz, P.radius, 255, 40, 160, 0.4)
			for _, p in ipairs(A.players()) do
				if dist(p.x, p.z, s.rx, s.rz) < P.radius then
					if A.damage(p.m, P.mult, s, "glitch") then A.push(p.m, s.rx, s.rz, P.push, P.up) end
				end
			end
			return true
		end
		return false
	end,
	cleanup = function(A) A.hide(false) end,
}

end
