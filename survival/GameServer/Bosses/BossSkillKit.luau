--!nonstrict
-- Bosses/BossSkillKit: piezas reutilizables para las habilidades de los jefes (avisos en el suelo, conos, líneas,
-- anillos, proyectiles). Todo lo que crea pasa por A.part(s, ...) y se destruye solo al terminar la habilidad.
local Kit = {}
Kit.NEON, Kit.SM, Kit.WOOD, Kit.GRASS, Kit.SLATE = Enum.Material.Neon, Enum.Material.SmoothPlastic, Enum.Material.Wood, Enum.Material.Grass, Enum.Material.Slate
Kit.BL, Kit.BALL, Kit.CYL = Enum.PartType.Block, Enum.PartType.Ball, Enum.PartType.Cylinder
Kit.UP = CFrame.Angles(0, 0, math.pi / 2) -- cilindro "acostado" -> vertical / disco en el piso
local NEON, BL, CYL, UP = Kit.NEON, Kit.BL, Kit.CYL, Kit.UP

function Kit.c3(r, g, b) return Color3.fromRGB(r, g, b) end
function Kit.dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end
function Kit.smooth(k) k = math.clamp(k, 0, 1); return k * k * (3 - 2 * k) end
function Kit.angle(dx, dz) return math.atan2(dz, dx) end
function Kit.unit(dx, dz)
	local d = math.sqrt(dx * dx + dz * dz)
	if d < 1e-3 then return 1, 0 end
	return dx / d, dz / d
end

-- ¿el punto está dentro del cono/sector (centro, ángulo, medio ángulo, radio)?
function Kit.inSector(px, pz, cx, cz, ang, half, radius)
	local dx, dz = px - cx, pz - cz
	local d = math.sqrt(dx * dx + dz * dz)
	if d > radius then return false end
	if d < 1.5 then return true end
	local diff = math.abs((math.atan2(dz, dx) - ang + math.pi) % (2 * math.pi) - math.pi)
	return diff <= half
end

-- aviso en forma de cono/arco (franjas planas translúcidas en el piso)
function Kit.sector(A, s, cx, cz, ang, half, radius, color, transp)
	local n = math.clamp(math.floor(half * 2 / 0.22), 3, 14)
	local parts = {}
	for i = 1, n do
		local a = ang - half + (i - 0.5) / n * half * 2
		local w = 2 * radius * math.tan(half / n) + 0.4
		local p = A.part(s, BL, Vector3.new(w, 0.2, radius), color, NEON, transp or 0.62)
		local mx, mz = cx + math.cos(a) * radius / 2, cz + math.sin(a) * radius / 2
		local pos = A.W(mx, 0.3, mz)
		p.CFrame = CFrame.lookAt(pos, pos + Vector3.new(math.cos(a), 0, math.sin(a)))
		parts[i] = p
	end
	return parts
end

function Kit.setAlpha(parts, t) for _, p in ipairs(parts) do if p.Parent then p.Transparency = t end end end

-- disco plano en el piso (radio de peligro, charco, zona)
function Kit.disc(A, s, x, z, r, color, transp, y)
	local p = A.part(s, CYL, Vector3.new(0.2, r * 2, r * 2), color, NEON, transp or 0.7)
	p.CFrame = CFrame.new(A.W(x, y or 0.2, z)) * UP
	return p
end

-- línea plana (aviso de rayo, embestida, sombra)
function Kit.line(A, s, x1, z1, x2, z2, width, color, transp, y)
	local len = math.max(0.5, Kit.dist(x1, z1, x2, z2))
	local p = A.part(s, BL, Vector3.new(width, 0.2, len), color, NEON, transp or 0.55)
	local mid = A.W((x1 + x2) / 2, y or 0.35, (z1 + z2) / 2)
	local tgt = Vector3.new(x2 - x1, 0, z2 - z1)
	p.CFrame = CFrame.lookAt(mid, mid + (tgt.Magnitude > 0.01 and tgt or Vector3.new(0, 0, 1)))
	return p
end
function Kit.moveLine(A, p, x1, z1, x2, z2, y)
	local len = math.max(0.5, Kit.dist(x1, z1, x2, z2))
	p.Size = Vector3.new(p.Size.X, p.Size.Y, len)
	local mid = A.W((x1 + x2) / 2, y or 0.35, (z1 + z2) / 2)
	local tgt = Vector3.new(x2 - x1, 0, z2 - z1)
	p.CFrame = CFrame.lookAt(mid, mid + (tgt.Magnitude > 0.01 and tgt or Vector3.new(0, 0, 1)))
end

-- anillo de segmentos (onda expansiva / círculo de sonido)
function Kit.ring(A, s, n, color, thick, height, transp)
	local ring = {}
	for i = 1, n do ring[i] = A.part(s, BL, Vector3.new(thick, height, 2), color, NEON, transp or 0.2) end
	return ring
end
function Kit.placeRing(A, ring, cx, cz, radius, spin, yOff)
	local n = #ring
	local seg = math.max(0.6, 2 * math.pi * math.max(radius, 0.5) / n * 1.08)
	for i, p in ipairs(ring) do
		local a = (i - 1) / n * math.pi * 2 + (spin or 0)
		local pos = A.W(cx + math.cos(a) * radius, yOff or 0.7, cz + math.sin(a) * radius)
		p.Size = Vector3.new(p.Size.X, p.Size.Y, seg)
		p.CFrame = CFrame.lookAt(pos, pos + Vector3.new(-math.sin(a), 0, math.cos(a)))
	end
end
function Kit.hide(parts) for _, p in ipairs(parts) do p.Transparency = 1 end end

-- puntos repartidos cerca de los jugadores: el primero cerca (no exacto), el resto alrededor
function Kit.scatter(A, n, nearMin, nearMax, minOff, maxOff)
	local pts = {}
	local targets = A.players()
	if #targets == 0 then return pts end
	local tries = 0
	while #pts < n and tries < n * 8 do
		tries += 1
		local i = #pts + 1
		local tp = targets[(i - 1) % #targets + 1]
		local a = A.rng:number(0, math.pi * 2)
		local d = (i == 1) and A.rng:number(nearMin, nearMax) or A.rng:number(minOff, maxOff)
		local x, z = A.clampPoint(tp.x + math.cos(a) * d, tp.z + math.sin(a) * d)
		local ok = true
		for _, q in ipairs(pts) do if Kit.dist(x, z, q[1], q[2]) < 4 then ok = false; break end end
		if ok then table.insert(pts, { x, z }) end
	end
	return pts
end

-- proyectiles lógicos del jefe: viajan en línea recta, se frenan en paredes y golpean una vez por jugador
function Kit.shoot(A, s, x, z, dx, dz, opts)
	s.projs = s.projs or {}
	local ux, uz = Kit.unit(dx, dz)
	local range = math.min(opts.range or 40, A.rayLen(x, z, ux, uz, opts.range or 40))
	local p = { x = x, z = z, ux = ux, uz = uz, speed = opts.speed or 30, left = range, radius = opts.radius or 2,
		part = opts.part, y = opts.y or 2.5, key = opts.key or ("p" .. (#s.projs + 1)), onHit = opts.onHit, alive = true }
	table.insert(s.projs, p)
	return p
end
function Kit.stepShots(A, s, dt)
	local any = false
	for _, p in ipairs(s.projs or {}) do
		if p.alive then
			local step = math.min(p.left, p.speed * dt)
			p.x += p.ux * step; p.z += p.uz * step; p.left -= step
			if p.part then p.part.CFrame = CFrame.lookAt(A.W(p.x, p.y, p.z), A.W(p.x + p.ux, p.y, p.z + p.uz)) end
			for _, pl in ipairs(A.players()) do
				if Kit.dist(pl.x, pl.z, p.x, p.z) < p.radius + 1.2 then
					if p.onHit then p.onHit(pl, p) end
				end
			end
			if p.left <= 0.01 then p.alive = false; if p.part then p.part.Transparency = 1; for _, c in ipairs(p.part:GetChildren()) do if c:IsA("Trail") then c.Enabled = false end end end
			else any = true end
		end
	end
	return any
end

-- estela visible detrás de un proyectil
function Kit.trail(part, color)
	local a0 = Instance.new("Attachment"); a0.Position = Vector3.new(0, 0.4, 0); a0.Parent = part
	local a1 = Instance.new("Attachment"); a1.Position = Vector3.new(0, -0.4, 0); a1.Parent = part
	local t = Instance.new("Trail"); t.Attachment0 = a0; t.Attachment1 = a1; t.Lifetime = 0.35; t.Color = ColorSequence.new(color)
	t.Transparency = NumberSequence.new(0.2, 1); t.LightEmission = 0.6; t.Parent = part
	return t
end

return Kit
