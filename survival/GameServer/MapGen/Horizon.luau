--!nonstrict
-- MapGen/Horizon: montañas lejanas que enmarcan el mapa (cerros y mesetas redondeadas, con capas de color).
-- Son elipsoides (Part + SpecialMesh esférica): 3-4 piezas por montaña, sin colisión, sin consultas
-- (la cámara no choca) y sin sombra. Están FUERA de los muros invisibles: no se pueden alcanzar.
local Props = require(script.Parent.Props)
local c3 = Props.c3

local Horizon = {}

local function blob(f, name, size, pos, color, mat)
	local p = Props.mk(f, name, Enum.PartType.Block, size, CFrame.new(pos), color, mat, false, false)
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	return p
end

function Horizon.build(ctx)
 if ctx.mapId=="desert" or ctx.mapId=="hidden" then return require(script.Parent.BiomeScenery).build(ctx) end
	local cfg, P, rng = ctx.cfg, ctx.P, ctx.rng
	local H = cfg.horizon
	local HALF = ctx.half
	local A, B, TOP = c3(P.horizonA), c3(P.horizonB), c3(P.horizonTop)
	local rockMat = P.glow and Enum.Material.Slate or Enum.Material.Sandstone
	local topMat = (ctx.mapId == "forest") and Enum.Material.Grass or Enum.Material.SmoothPlastic
	for i = 1, H.count do
		-- punto sobre un cuadrado mayor que el mapa (el mapa es cuadrado)
		local t = (i - 1 + rng:number(-0.3, 0.3)) / H.count
		local per = (t % 1) * 4
		local side = math.floor(per)
		local u = per - side
		local D = HALF + cfg.rim.width + rng:number(H.minDist, H.maxDist)
		local s = -D + 2 * D * u
		local x, z
		if side == 0 then x, z = s, -D elseif side == 1 then x, z = D, s elseif side == 2 then x, z = -s, D else x, z = -D, -s end
		local height = rng:number(H.minHeight, H.maxHeight)
		local W = rng:number(120, 220)
		local base = ctx.origin + Vector3.new(x, -10, z)
		if ctx.mapId=="forest" then
   -- Interlocking rock faces give the distant ridges sharp, asymmetric crests.
   for k=0,2 do
    local cliff=Instance.new("WedgePart")
    cliff.Name="ForestRidgeline"
    cliff.Size=Vector3.new(W*.72,height*(1-k*.16),W*.95)
    cliff.CFrame=CFrame.new(base+Vector3.new((k-1)*W*.3,cliff.Size.Y*.36,0))*CFrame.Angles(0,side*math.pi/2+k*.48,0)
    cliff.Color=B:Lerp(A,k*.32)
    cliff.Material=Enum.Material.Slate
    cliff.Anchored=true;cliff.CanCollide=false;cliff.CanTouch=false;cliff.CanQuery=false;cliff.CastShadow=false;cliff.Parent=ctx.f
   end
  elseif rng:chance(0.6) then
			-- meseta redondeada: capas de roca de dos tonos y una tapa verde
			local tiers = rng:integer(2, 3)
			local w, y = W, 0
			local th = height / tiers
			for k = 1, tiers do
				blob(ctx.f, "HorizonMountain", Vector3.new(w, th * 2.1, w * rng:number(0.75, 1)), base + Vector3.new(0, y, 0), (k % 2 == 1) and A or B, rockMat)
				y += th
				w *= rng:number(0.62, 0.78)
			end
			blob(ctx.f, "HorizonTop", Vector3.new(w * 1.25, th * 0.7, w * 1.15), base + Vector3.new(0, y - th * 0.35, 0), TOP, topMat)
		else
			-- cerro redondeado verde con falda de roca
			blob(ctx.f, "HorizonHill", Vector3.new(W, height * 0.9, W * 0.9), base + Vector3.new(0, height * 0.05, 0), A, rockMat)
			blob(ctx.f, "HorizonHill", Vector3.new(W * 0.85, height * 2, W * 0.8), base + Vector3.new(rng:number(-8, 8), 0, rng:number(-8, 8)), TOP, topMat)
		end
		ctx.work(4)
	end
end

return Horizon
