--!nonstrict
-- MapGen/Props: piezas básicas redondeadas y coloridas (árboles, rocas, flores, carteles…). Sin assets externos.
-- Reglas de rendimiento: la decoración chica no colisiona, no se consulta (CanQuery) y no proyecta sombra;
-- solo los troncos, las copas grandes, las rocas grandes y las estructuras proyectan sombra.
local Props = {}
local BL, BALL, CYL = Enum.PartType.Block, Enum.PartType.Ball, Enum.PartType.Cylinder
Props.BL, Props.BALL, Props.CYL = BL, BALL, CYL
local WOOD, GRASS, SM = Enum.Material.Wood, Enum.Material.Grass, Enum.Material.SmoothPlastic
local SLATE, NEON = Enum.Material.Slate, Enum.Material.Neon
local UP = CFrame.Angles(0, 0, math.pi / 2) -- cilindro vertical

function Props.c3(t) return Color3.fromRGB(t[1], t[2], t[3]) end
local c3 = Props.c3

Props.count = 0 -- piezas creadas (para medir)

-- pieza anclada. collide = colisiona (y se puede consultar); shadow = proyecta sombra
function Props.mk(parent, name, shape, size, cf, color, material, collide, shadow)
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape or BL
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or SM
	p.Anchored = true
	p.CanCollide = collide == true
	p.CanQuery = collide == true -- la cámara no choca con copas ni flores
	p.CanTouch = false
	p.CastShadow = shadow == true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	Props.count += 1
	return p
end
local mk = Props.mk

local function vertical(f, name, pos, len, dia, color, mat, collide, shadow)
	return mk(f, name, CYL, Vector3.new(len, dia, dia), CFrame.new(pos) * UP, color, mat, collide, shadow)
end
Props.vertical = vertical

local function pick(rng, list) return list[rng:integer(1, #list)] end

-- ===== árboles (devuelven: altura de trepada para los enemigos, radio del tronco) =====
-- (2026-10-29) árboles rehechos: tronco afinado en dos tramos con raíces y ramas, copas de varias esferas con sombreado
-- (abajo más oscuro, arriba más claro), pinos en 5 pisos octogonales, palmeras curvas con anillos, hojas en dos tramos
-- y cocos. Cada árbol varía en tamaño, inclinación, giro y tono.
local BLACK, WHITE = Color3.new(0, 0, 0), Color3.new(1, 1, 1)

-- tramo de cilindro entre dos puntos (el eje del cilindro de Roblox es X)
local function beam(f, name, a, b, dia, color, mat, collide, shadow)
	local len = (b - a).Magnitude
	return mk(f, name, CYL, Vector3.new(len + dia * 0.25, dia, dia), CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.pi / 2, 0), color, mat, collide, shadow)
end
Props.beam = beam

-- roble: tronco con raíces y 2 ramas, copa de 7 esferas sombreadas (verde o "florecido" con colores)
function Props.oak(f, rng, pos, h, P, colorful)
	local k = h / 11
	local trunk = c3(P.trunk):Lerp(BLACK, rng:number(0, 0.12))
	local lean = Vector3.new(rng:number(-0.05, 0.05), 0, rng:number(-0.05, 0.05)) * h
	local mid = pos + Vector3.new(0, h * 0.42, 0) + lean * 0.4
	local top = pos + Vector3.new(0, h * 0.8, 0) + lean
	beam(f, "TreeTrunk", pos - Vector3.new(0, 0.6, 0), mid, 2.3 * k, trunk, WOOD, true, true)
	beam(f, "TreeTrunk", mid, top, 1.55 * k, trunk, WOOD, false, true)
	local yaw = rng:number(0, math.pi * 2)
	-- raíces
	for i = 1, 3 do
		local ra = yaw + i * 2.09
		local out = Vector3.new(math.cos(ra), 0, math.sin(ra))
		beam(f, "TreeRoot", pos + Vector3.new(0, 0.7 * k, 0), pos + out * 1.9 * k - Vector3.new(0, 0.3, 0), 0.75 * k, trunk:Lerp(BLACK, 0.08), WOOD, false, false)
	end
	-- ramas hacia la copa
	for i = 1, 2 do
		local ba = yaw + i * math.pi + rng:number(-0.4, 0.4)
		local from = mid:Lerp(top, rng:number(0.25, 0.6))
		local to = from + Vector3.new(math.cos(ba) * 2.8 * k, 2.4 * k, math.sin(ba) * 2.8 * k)
		beam(f, "TreeBranch", from, to, 0.7 * k, trunk, WOOD, false, false)
	end
	-- copa
	local c = top + Vector3.new(0, 1.6 * k, 0)
	local base, mat
	if colorful then base = c3(pick(rng, P.blossom)); mat = SM else base = c3(pick(rng, P.leaves)); mat = GRASS end
	base = base:Lerp(rng:chance(0.5) and WHITE or BLACK, rng:number(0, 0.08))
	local low, high = base:Lerp(BLACK, 0.14), base:Lerp(WHITE, colorful and 0.3 or 0.16)
	mk(f, "TreeLeaves", BALL, Vector3.one * rng:number(7.2, 8.4) * k, CFrame.new(c), base, mat, false, true)
	for i = 1, 5 do
		local la = yaw + i * 1.2566 + rng:number(-0.25, 0.25)
		local r = rng:number(3, 3.9) * k
		local dy = rng:number(-1.6, 1.2) * k
		local col = dy < 0 and low or base:Lerp(high, 0.4)
		mk(f, "TreeLeaves", BALL, Vector3.one * rng:number(4.6, 6) * k, CFrame.new(c + Vector3.new(math.cos(la) * r, dy, math.sin(la) * r)), col, mat, false, i <= 2)
	end
	mk(f, "TreeLeaves", BALL, Vector3.one * rng:number(4.4, 5.2) * k, CFrame.new(c + Vector3.new(rng:number(-0.6, 0.6) * k, 3.1 * k, rng:number(-0.6, 0.6) * k)), high, mat, false, false)
	if colorful and rng:chance(0.6) then -- flores caídas al pie
		for _ = 1, 3 do
			local fa = rng:number(0, math.pi * 2)
			local fd = rng:number(2, 4.5) * k
			mk(f, "Petals", CYL, Vector3.new(0.12, 1.1, 1.1), CFrame.new(pos + Vector3.new(math.cos(fa) * fd, 0.1, math.sin(fa) * fd)) * UP, high, SM, false, false)
		end
	end
	return h * 0.75, 2.4 * k
end

-- pino: tronco afinado y 5 pisos octogonales (dos bloques girados 45°) que se achican hacia la punta
function Props.pine(f, rng, pos, h, P)
	local trunk = c3(P.trunk):Lerp(BLACK, 0.25)
	beam(f, "PineTrunk", pos - Vector3.new(0, 0.5, 0), pos + Vector3.new(0, h * 0.55, 0), 1.35, trunk, WOOD, true, true)
	local yaw = rng:number(0, math.pi / 2)
	local leafA, leafB = c3(P.leaves[2]), c3(P.leaves[1])
	local tiers = 5
	local wide = rng:number(7.4, 8.8)
	for i = 0, tiers - 1 do
		local t = i / (tiers - 1)
		local w = wide * (1 - t * 0.8)
		local th = h * 0.16
		local y = h * 0.2 + t * h * 0.66
		local col = leafA:Lerp(leafB, t):Lerp(WHITE, t * 0.06)
		local spin = yaw + i * 0.35
		mk(f, "PineLeaves", BL, Vector3.new(w, th, w), CFrame.new(pos + Vector3.new(0, y, 0)) * CFrame.Angles(0, spin, 0), col, GRASS, false, i == 0)
		mk(f, "PineLeaves", BL, Vector3.new(w * 0.78, th * 1.12, w * 0.78), CFrame.new(pos + Vector3.new(0, y + th * 0.1, 0)) * CFrame.Angles(0, spin + 0.785, 0), col:Lerp(WHITE, 0.05), GRASS, false, false)
	end
	mk(f, "PineTop", BL, Vector3.new(1.1, h * 0.12, 1.1), CFrame.new(pos + Vector3.new(0, h * 0.95, 0)) * CFrame.Angles(0, yaw + 0.4, 0), leafB:Lerp(WHITE, 0.08), GRASS, false, false)
	return h * 0.6, 1.8
end

-- palmera: tronco curvo de 5 tramos con anillos, 7 hojas en dos tramos que caen y cocos
function Props.palm(f, rng, pos, h, P)
	local a = rng:number(0, math.pi * 2)
	local lean = Vector3.new(math.cos(a), 0, math.sin(a))
	local bend = rng:number(0.15, 0.35)
	local trunk = c3(P.trunk)
	local prev = pos - Vector3.new(0, 0.4, 0)
	local n = 5
	for s = 1, n do
		local t = s / n
		local nxt = pos + Vector3.new(0, h * t, 0) + lean * (t * t * h * bend)
		beam(f, "PalmTrunk", prev, nxt, 1.25 - t * 0.4, (s % 2 == 0) and trunk or trunk:Lerp(BLACK, 0.18), WOOD, s == 1, s <= 2)
		prev = nxt
	end
	local crown = prev
	local leaf = c3(P.leaves[1])
	for i = 1, 7 do
		local fa = a + i * 0.8976 + rng:number(-0.15, 0.15)
		local out = Vector3.new(math.cos(fa), 0, math.sin(fa))
		local p1 = crown + out * 2.6 + Vector3.new(0, 0.7, 0)
		local p2 = p1 + out * 2.8 - Vector3.new(0, rng:number(1.4, 2.2), 0)
		local col = leaf:Lerp((i % 2 == 0) and c3(P.leaves[3]) or c3(P.leaves[2]), 0.5)
		mk(f, "PalmLeaf", BL, Vector3.new(1.6, 0.16, (p1 - crown).Magnitude + 0.4), CFrame.lookAt((crown + p1) / 2, p1), col, GRASS, false, i <= 2)
		mk(f, "PalmLeaf", BL, Vector3.new(1.2, 0.14, (p2 - p1).Magnitude + 0.3), CFrame.lookAt((p1 + p2) / 2, p2), col:Lerp(BLACK, 0.08), GRASS, false, false)
	end
	for i = 1, rng:integer(2, 3) do
		local ca = a + i * 2.1
		mk(f, "Coconut", BALL, Vector3.one * 0.85, CFrame.new(crown + Vector3.new(math.cos(ca) * 0.7, -0.6, math.sin(ca) * 0.7)), Color3.fromRGB(110, 76, 40), SM, false, false)
	end
	return h * 0.7, 1.4
end

-- hongo gigante (con lunares que brillan en la Zona oculta)
function Props.mushroom(f, rng, pos, h, P, capColor)
	vertical(f, "MushroomStem", pos + Vector3.new(0, h * 0.4, 0), h * 0.8, 1.5 * (h / 7), c3(P.trunk), SM, true, true)
	local cap = capColor or c3(pick(rng, P.blossom))
	local cs = 7 * (h / 7)
	mk(f, "MushroomCap", BALL, Vector3.one * cs, CFrame.new(pos + Vector3.new(0, h * 0.82 + cs * 0.12, 0)), cap, SM, false, true)
	for k = 1, 2 do
		local ka = k * 2.6 + rng:number(0, 1)
		mk(f, "MushroomSpot", BALL, Vector3.one * 0.9 * (h / 7), CFrame.new(pos + Vector3.new(math.cos(ka) * 2 * (h / 7), h * 0.82 + cs * 0.45, math.sin(ka) * 2 * (h / 7))), Color3.fromRGB(255, 236, 250), P.glow and NEON or SM, false, false)
	end
	return h * 0.8, 1.8
end

-- cactus con brazos
function Props.cactus(f, rng, pos, P)
	local g, gd = Color3.fromRGB(80, 156, 72), Color3.fromRGB(60, 128, 58)
	vertical(f, "Cactus", pos + Vector3.new(0, 3.5, 0), 7, 1.6, g, GRASS, true, true)
	mk(f, "Cactus", BALL, Vector3.one * 1.6, CFrame.new(pos + Vector3.new(0, 7, 0)), g, GRASS, false, false)
	local yaw = CFrame.Angles(0, rng:number(0, math.pi), 0)
	local s = rng:chance(0.5) and 1 or -1
	mk(f, "Cactus", CYL, Vector3.new(1.6, 0.9, 0.9), CFrame.new(pos) * yaw * CFrame.new(s * 1.3, 3.4, 0), gd, GRASS, false, false)
	mk(f, "Cactus", CYL, Vector3.new(2.4, 0.9, 0.9), CFrame.new(pos) * yaw * CFrame.new(s * 1.95, 4.5, 0) * UP, gd, GRASS, false, false)
	if rng:chance(0.35) then mk(f, "CactusFlower", BALL, Vector3.one * 0.8, CFrame.new(pos + Vector3.new(0, 7.8, 0)), c3(pick(rng, P.flowers)), SM, false, false) end
	return 7, 1.5
end

-- cristal (Zona oculta)
function Props.crystal(f, rng, pos, P)
	local col = c3(pick(rng, P.blossom))
	local s = rng:number(6, 9)
	mk(f, "Crystal", BL, Vector3.new(2, s, 2), CFrame.new(pos + Vector3.new(0, s * 0.42, 0)) * CFrame.Angles(rng:number(-0.25, 0.25), rng:number(0, 6), rng:number(-0.25, 0.25)), col, NEON, true, false)
	mk(f, "Crystal", BL, Vector3.new(1.2, s * 0.55, 1.2), CFrame.new(pos + Vector3.new(1.2, s * 0.22, 0.6)) * CFrame.Angles(0.3, rng:number(0, 6), -0.35), col:Lerp(Color3.new(1, 1, 1), 0.2), NEON, false, false)
	return s * 0.85, 1.6
end

-- arbusto: 4 esferas de tamaños y tonos distintos (a veces con flores)
function Props.bush(f, rng, pos, P)
	local base = c3(P.leaves[2])
	local yaw = rng:number(0, math.pi * 2)
	local s0 = rng:number(3.4, 4.4)
	mk(f, "Bush", BALL, Vector3.one * s0, CFrame.new(pos + Vector3.new(0, s0 * 0.3, 0)), base, GRASS, false, true)
	for i = 1, 3 do
		local ba = yaw + i * 2.09
		local s = rng:number(2.2, 3.2)
		local col = (i == 2) and c3(P.leaves[3]) or base:Lerp(c3(P.leaves[1]), 0.5)
		mk(f, "Bush", BALL, Vector3.one * s, CFrame.new(pos + Vector3.new(math.cos(ba) * s0 * 0.38, s * 0.35, math.sin(ba) * s0 * 0.38)), col, GRASS, false, false)
	end
	if P.flowers and rng:chance(0.4) then
		for i = 1, 2 do
			mk(f, "BushFlower", BALL, Vector3.one * 0.7, CFrame.new(pos + Vector3.new(rng:number(-1, 1), s0 * 0.62, rng:number(-1, 1))), c3(pick(rng, P.flowers)), SM, false, false)
		end
	end
	return 0, 0 -- no bloquea
end

-- ===== rocas redondeadas (con musgo en el Bosque, brillo en la Zona oculta) =====
function Props.rock(f, rng, pos, r, P, collide)
	local col = c3(P.rock)
	local mat = SLATE
	local main = mk(f, "Rock", BALL, Vector3.one * r * 2, CFrame.new(pos + Vector3.new(0, r * 0.3, 0)), col:Lerp(Color3.new(1, 1, 1), rng:number(0, 0.1)), mat, collide, collide)
	local a = rng:number(0, math.pi * 2)
	local r2 = r * rng:number(0.55, 0.75)
	mk(f, "Rock", BALL, Vector3.one * r2 * 2, CFrame.new(pos + Vector3.new(math.cos(a) * r * 0.9, r2 * 0.15, math.sin(a) * r * 0.9)), col:Lerp(Color3.new(0, 0, 0), 0.08), mat, collide and r2 > 2, false)
	if P.moss then
		mk(f, "RockMoss", BALL, Vector3.one * r * 1.15, CFrame.new(pos + Vector3.new(r * 0.15, r * 0.95, -r * 0.1)), c3(P.moss), GRASS, false, false)
	elseif P.glow then
		mk(f, "RockGlow", BL, Vector3.new(0.6, r * 0.9, 0.6), CFrame.new(pos + Vector3.new(0, r * 1.25, 0)) * CFrame.Angles(0.2, a, 0.2), c3(P.blossom[2]), NEON, false, false)
	end
	return r * 1.25, main
end

-- ===== flores =====
function Props.flowers(f, rng, pos, P, n)
	for _ = 1, n do
		local a = rng:number(0, math.pi * 2)
		local d = rng:number(0, 2.4)
		local s = rng:number(0.55, 0.85)
		mk(f, "Flower", BALL, Vector3.one * s, CFrame.new(pos + Vector3.new(math.cos(a) * d, 0.5 + s * 0.3, math.sin(a) * d)), c3(pick(rng, P.flowers)), P.glow and NEON or SM, false, false)
	end
end

-- girasol (detalle del Bosque)
function Props.sunflower(f, rng, pos)
	local h = rng:number(2.4, 3.4)
	mk(f, "SunflowerStem", BL, Vector3.new(0.22, h, 0.22), CFrame.new(pos + Vector3.new(0, h / 2, 0)), Color3.fromRGB(70, 150, 60), SM, false, false)
	mk(f, "Sunflower", CYL, Vector3.new(0.25, 1.5, 1.5), CFrame.new(pos + Vector3.new(0, h, 0)) * CFrame.Angles(0, rng:number(0, 6), 0) * CFrame.Angles(0, 0, 0.3), Color3.fromRGB(252, 206, 40), SM, false, false)
end

-- ===== detalles =====
function Props.cairn(f, rng, pos, P)
	local col = c3(P.stone)
	local y = 0
	for i = 1, 3 do
		local s = 1.6 - i * 0.35
		mk(f, "Cairn", BALL, Vector3.one * s, CFrame.new(pos + Vector3.new(rng:number(-0.1, 0.1), y + s * 0.45, rng:number(-0.1, 0.1))), col:Lerp(Color3.new(0, 0, 0), i * 0.05), SLATE, false, false)
		y += s * 0.8
	end
end

function Props.log(f, rng, pos, P)
	local yaw = rng:number(0, math.pi)
	mk(f, "Log", CYL, Vector3.new(rng:number(4, 6), 1.1, 1.1), CFrame.new(pos + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, yaw, 0), c3(P.trunk), WOOD, false, false)
	mk(f, "LogMoss", BALL, Vector3.one * 0.9, CFrame.new(pos + Vector3.new(0, 1.05, 0)), c3(P.leaves[3]), GRASS, false, false)
end

function Props.stump(f, rng, pos, P)
	vertical(f, "Stump", pos + Vector3.new(0, 0.5, 0), 1.2, rng:number(1.4, 2), c3(P.trunk), WOOD, false, false)
	mk(f, "StumpTop", CYL, Vector3.new(0.12, 1.3, 1.3), CFrame.new(pos + Vector3.new(0, 1.12, 0)) * UP, Color3.fromRGB(214, 176, 120), WOOD, false, false)
end

function Props.smallShrooms(f, rng, pos, P)
	for i = 1, rng:integer(2, 3) do
		local o = pos + Vector3.new(rng:number(-1.2, 1.2), 0, rng:number(-1.2, 1.2))
		local h = rng:number(0.7, 1.2)
		mk(f, "ShroomStem", CYL, Vector3.new(h, 0.35, 0.35), CFrame.new(o + Vector3.new(0, h / 2, 0)) * UP, Color3.fromRGB(240, 232, 220), SM, false, false)
		mk(f, "ShroomCap", BALL, Vector3.one * (0.9 + h * 0.4), CFrame.new(o + Vector3.new(0, h, 0)), P.glow and c3(P.blossom[2]) or Color3.fromRGB(226, 52, 48), P.glow and NEON or SM, false, false)
	end
end

-- cartel con flechas a los lugares (texto con SurfaceGui; sin premios)
function Props.signpost(f, pos, entries, P)
	local wood = c3(P.trunk)
	vertical(f, "SignPost", pos + Vector3.new(0, 3, 0), 6, 0.55, wood, WOOD, false, true)
	for i, e in ipairs(entries) do
		local y = 5.6 - (i - 1) * 1.15
		local dir = Vector3.new(e.dx, 0, e.dz)
		if dir.Magnitude < 1e-3 then dir = Vector3.new(0, 0, -1) end
		dir = dir.Unit
		local center = pos + Vector3.new(0, y, 0) + dir * 2.3
		local board = mk(f, "SignBoard", BL, Vector3.new(0.22, 0.95, 4.6), CFrame.lookAt(center, center + dir), Color3.fromRGB(226, 196, 140), WOOD, false, false)
		for _, face in ipairs({ Enum.NormalId.Left, Enum.NormalId.Right }) do
			local g = Instance.new("SurfaceGui")
			g.Face = face
			g.CanvasSize = Vector2.new(460, 95)
			g.LightInfluence = 0.6
			local t = Instance.new("TextLabel")
			t.Size = UDim2.fromScale(1, 1)
			t.BackgroundTransparency = 1
			t.Font = Enum.Font.FredokaOne
			t.TextScaled = true
			t.TextColor3 = Color3.fromRGB(70, 44, 24)
			t.Text = (face == Enum.NormalId.Right) and (e.text .. "  ?") or ("?  " .. e.text)
			t.Parent = g
			g.Parent = board
		end
	end
end

-- cartel flotante con el nombre de un lugar (se ve al acercarse)
function Props.nameTag(f, pos, text, color)
	if not text or text == "" then return nil end -- las estructuras ya no tienen nombre (2026-10-29)
	local a = mk(f, "LandmarkName", BL, Vector3.one * 0.2, CFrame.new(pos), Color3.new(1, 1, 1), SM, false, false)
	a.Transparency = 1
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(360, 46)
	bb.MaxDistance = 140
	bb.LightInfluence = 0
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.Text = text
	t.TextColor3 = color or Color3.fromRGB(255, 236, 140)
	t.TextStrokeTransparency = 0.1
	t.Parent = bb
	bb.Parent = a
	return a
end

return Props
