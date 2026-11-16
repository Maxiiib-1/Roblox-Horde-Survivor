--!nonstrict
-- Services/CharacterSkin: durante la run el jugador se ve como su personaje (modelo de Visuals/Brainrots, con su skin).
-- El modelo se suelda al HumanoidRootPart con un Weld (sin colisión, sin masa) y el avatar de Roblox se oculta.
-- No cambia el HumanoidRootPart ni la hitbox: el combate usa la posición lógica del servidor.
-- setSlide inclina el modelo al deslizarse; shatter lo rompe en bloques al morir.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("GameShared")
local Brainrots = require(Shared.Visuals.Brainrots)
local Presentation = require(Shared.Catalogs.ClassPresentationRegistry)

local Skin = {}
Skin.TARGET_HEIGHT = 5.2 -- studs, parecido a un avatar R15
local NAME = "BrainrotSkin"
local active = {} -- [player] = { classId, skinId } mientras dura la run (para re-aplicar si el avatar reaparece)
local hooked = {}
local welds = {}  -- [player] = { weld, c0, s }

local function setHidden(char, hidden)
	for _, d in ipairs(char:GetDescendants()) do
		if d:FindFirstAncestor(NAME) then continue end
		if (d:IsA("BasePart") and d.Name ~= "HumanoidRootPart") or d:IsA("Decal") then
			if hidden then
				if d:GetAttribute("SkinOrigT") == nil then d:SetAttribute("SkinOrigT", d.Transparency) end
				d.Transparency = 1
			else
				local o = d:GetAttribute("SkinOrigT")
				if o ~= nil then d.Transparency = o; d:SetAttribute("SkinOrigT", nil) end
			end
		end
	end
end

-- animaciones por defecto del personaje de Roblox (está oculto): se apagan mientras tiene el brainrot, porque
-- moverían los huesos del modelo que se llaman igual que partes de Roblox (Head, Torso…)
local function setDefaultAnims(char, on)
	local animate = char:FindFirstChild("Animate")
	if animate and animate:IsA("LuaSourceContainer") then animate.Disabled = not on end
	if not on then
		local hum = char:FindFirstChildOfClass("Humanoid")
		local animator = hum and hum:FindFirstChildOfClass("Animator")
		if animator then for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do tr:Stop(0) end end
	end
end

local function strip(player)
	welds[player] = nil
	local char = player.Character
	if not char then return end
	local m = char:FindFirstChild(NAME)
	if m then m:Destroy() end
	setHidden(char, false)
	setDefaultAnims(char, true)
end

function Skin.remove(player)
	active[player] = nil
	strip(player)
end

local build

function Skin.apply(player, classId, skinId)
	active[player] = { classId, skinId }
	if not hooked[player] then
		hooked[player] = true
		player.CharacterAdded:Connect(function(char)
			char:WaitForChild("HumanoidRootPart", 5)
			task.wait(0.2)
			local a = active[player]
			if a and player.Character == char then pcall(build, player, a[1], a[2]) end
		end)
		player.AncestryChanged:Connect(function(_, parent) if not parent then active[player] = nil; hooked[player] = nil; welds[player] = nil end end)
	end
	build(player, classId, skinId)
end

build = function(player, classId, skinId)
	strip(player)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local pres = Presentation[classId]
	if not (hrp and hum and pres) then return end
	-- escala: alto objetivo, limitando el ancho para que aviones y tiburones no sean gigantes
	-- medidas de referencia del modelo (los del pack usan las de siempre: así el tamaño no cambia aunque estén en T-pose)
	local ext = Brainrots.extentsOf(pres.model)
	if not ext then
		local probe = Brainrots.build(pres.model, 1, false, CFrame.new(), nil)
		ext = probe:GetExtentsSize()
		probe:Destroy()
	end
	local s = Skin.TARGET_HEIGHT / math.max(ext.Y, math.max(ext.X, ext.Z) * 0.6)
	local groundOffset = hum.HipHeight + hrp.Size.Y / 2
	local cf = hrp.CFrame * CFrame.new(0, -groundOffset + s / 2, 0)
	local model = Brainrots.build(pres.model, s, false, cf, nil, { attach = true, skin = skinId })
	model.Name = NAME
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then d.CanCollide = false; d.CanQuery = false; d.CanTouch = false; d.Massless = true end
	end
	local w = Instance.new("Weld")
	w.Part0 = hrp; w.Part1 = model.PrimaryPart
	w.C0 = hrp.CFrame:ToObjectSpace(cf)
	w.Parent = model.PrimaryPart
	welds[player] = { weld = w, c0 = w.C0, s = s }
	setHidden(char, true)
	setDefaultAnims(char, false)
	model.Parent = char
end

-- deslizamiento: el modelo se recuesta hacia atrás y baja un poco
function Skin.setSlide(player, on)
	local w = welds[player]
	if not w or not w.weld.Parent then return end
	if on then
		w.weld.C0 = w.c0 * CFrame.new(0, -w.s * 0.28, 0) * CFrame.Angles(1.15, 0, 0)
	else
		w.weld.C0 = w.c0
	end
end

-- muerte: el personaje se rompe en sus bloques, que saltan y caen
function Skin.shatter(player)
	local char = player.Character
	local m = char and char:FindFirstChild(NAME)
	if not m then return end
	welds[player] = nil
	local center = m.PrimaryPart and m.PrimaryPart.Position or char:GetPivot().Position
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") then d:Destroy() end
	end
	for _, p in ipairs(m:GetDescendants()) do
		if p:IsA("BasePart") and p ~= m.PrimaryPart then
			p.Anchored = false; p.Massless = false; p.CanCollide = true
			local dir = (p.Position - center)
			dir = (dir.Magnitude > 0.05 and dir.Unit or Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit)
			p.AssemblyLinearVelocity = dir * math.random(14, 26) + Vector3.new(0, math.random(18, 30), 0)
			p.AssemblyAngularVelocity = Vector3.new(math.random(-8, 8), math.random(-8, 8), math.random(-8, 8))
		end
	end
end

return Skin
