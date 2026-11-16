--!nonstrict
-- MapGen/TerrainWriter: escribe el relieve en el Terrain de Roblox (WriteVoxels) por franjas, cediendo frames.
-- Materiales según el lugar: césped en lo llano, barrancos con franjas de dos tonos en las pendientes fuertes,
-- tierra clara en los caminos, arena en la orilla de los lagos y barro en el fondo.
local Terrain = workspace.Terrain
local VOX = 4

local TerrainWriter = {}
TerrainWriter.SINK = 2.0 -- (medido) el Terrain suave queda ~2 studs por encima de la altura escrita

local function mat(name) return Enum.Material[name] end
local function c3(t) return Color3.fromRGB(t[1], t[2], t[3]) end

function TerrainWriter.colors(B)
	pcall(function() Terrain.Decoration = true; Terrain.GrassLength = 0.35 end)
	pcall(function()
		Terrain:SetMaterialColor(mat(B.top), c3(B.topColor))
		if B.topAlt ~= B.top then Terrain:SetMaterialColor(mat(B.topAlt), c3(B.topAltColor)) end
		Terrain:SetMaterialColor(mat(B.cliffA), c3(B.cliffAColor))
		Terrain:SetMaterialColor(mat(B.cliffB), c3(B.cliffBColor))
		Terrain:SetMaterialColor(mat(B.path), c3(B.pathColor))
		Terrain:SetMaterialColor(mat(B.shore), c3(B.shoreColor))
		Terrain:SetMaterialColor(mat(B.bottom), c3(B.bottomColor))
		Terrain.WaterColor = c3(B.water); Terrain.WaterTransparency = 0.35; Terrain.WaterWaveSize = 0.05; Terrain.WaterReflectance = 0.6
	end)
end

-- map: { heightmap, origin, size }  B: paleta del bioma  cfg: MapGenConfig  work(n): cede frames
function TerrainWriter.write(map, B, cfg, work)
	local HM = map.heightmap
	local origin = map.origin
	local half = map.half
	local ext = math.ceil((map.size / 2 + cfg.rim.width + 64) / VOX) * VOX
	local yMin = -math.ceil((cfg.terrace.step * 1.2 + 14) / VOX) * VOX -- por debajo del fondo de valles y lagos
	local yMax = math.ceil((cfg.maxHeight + 26 + cfg.rim.height + 8) / VOX) * VOX
	local ox = math.floor((origin.X - ext) / VOX) * VOX
	local oz = math.floor((origin.Z - ext) / VOX) * VOX
	local nx = math.floor(ext * 2 / VOX)
	local nz = nx
	local ny = math.floor((yMax - yMin) / VOX)
	local oy = origin.Y + yMin
	TerrainWriter.colors(B)
	local TOP, ALT = mat(B.top), mat(B.topAlt)
	local CA, CB = mat(B.cliffA), mat(B.cliffB)
	local PATH, SHORE, BOTTOM = mat(B.path), mat(B.shore), mat(B.bottom)
	local WATER, AIR = Enum.Material.Water, Enum.Material.Air
	local lakes = HM.p.lakes
	local pathHalf = (HM.p.pathW or 12) * 0.5
 local forest=B==cfg.biomes.forest
	local sink = TerrainWriter.SINK
	-- franjas de los barrancos: dos tonos alternados cada ~5 studs de altura (como capas de roca)
	local function strata(yWorld) return (math.floor((yWorld + 1000) / 5) % 3 == 2) and CB or CA end
	local STRIP = 16
	local strips = 0
	for sx = 0, nx - 1, STRIP do
		local w = math.min(STRIP, nx - sx)
		local mats, occs = table.create(w), table.create(w)
		for i = 1, w do
			local mcol, ocol = table.create(ny), table.create(ny)
			for j = 1, ny do mcol[j] = table.create(nz); ocol[j] = table.create(nz) end
			local wx = ox + (sx + i - 1) * VOX + VOX / 2 - origin.X
			for k = 1, nz do
				local wz = oz + (k - 1) * VOX + VOX / 2 - origin.Z
				local h = HM:get(wx, wz)
				local hx1, hx2 = HM:get(wx + VOX, wz), HM:get(wx - VOX, wz)
				local hz1, hz2 = HM:get(wx, wz + VOX), HM:get(wx, wz - VOX)
				local slope = math.max(math.abs(hx1 - hx2), math.abs(hz1 - hz2)) / (2 * VOX)
				local low = math.min(hx1, hx2, hz1, hz2)
				local top
				local pathDistance=HM:pathDist(wx,wz)
                local inside = math.abs(wx) < half + 2 and math.abs(wz) < half + 2
				if slope > (inside and 0.55 or 0.75) then -- el borde exterior sube con césped (no parece un muro)
					top = nil -- barranco: franjas
				elseif inside and slope < 0.8 and pathDistance < pathHalf then
					top = PATH
				elseif forest then
     local humus=math.noise(wx/34,wz/34,2.1)+.48*math.noise(wx/91,wz/91,5.3)
     if pathDistance < pathHalf+2.6+math.noise(wx/12,wz/12,1)*3 then
      top=humus>0 and BOTTOM or PATH
     elseif humus>.34 then
      top=BOTTOM
     else
      top=humus>-.08 and ALT or TOP
     end
    elseif math.noise(wx / 46, wz / 46, 7.31) < 0.3 then
					top = ALT
				else
					top = TOP
				end
				local water = nil
				for _, lk in ipairs(lakes) do
					local dx, dz = wx - lk[1], wz - lk[2]
					local d2 = dx * dx + dz * dz
					if d2 < (lk[3] + 7) ^ 2 then
						if d2 < (lk[3] - 3) ^ 2 then top = BOTTOM elseif top ~= BOTTOM then top = SHORE end
						if d2 < (lk[3] + 4) ^ 2 then water = math.max(water or -1e9, lk[5] - yMin) end
					end
				end
				local hy = h - yMin - sink
 if B==cfg.biomes.hidden and (math.abs(wx)>half+12 or math.abs(wz)>half+12) then hy=-100000;water=nil end
				local faceFrom = low - yMin - sink - VOX * 1.5 -- desde dónde se ve la pared del barranco
				for j = 1, ny do
					local y0 = (j - 1) * VOX
					local occ = math.clamp((hy - y0) / VOX, 0, 1)
					if occ > 0 then
						ocol[j][k] = occ
						local yWorld = yMin + y0
						if top == nil then
							mcol[j][k] = (y0 >= faceFrom) and strata(yWorld) or CA
						elseif (hy - y0) < VOX * 2 then
							mcol[j][k] = top
						else
							mcol[j][k] = strata(yWorld)
						end
					elseif water and water > y0 then
						ocol[j][k] = 1
						mcol[j][k] = WATER
					else
						ocol[j][k] = 0
						mcol[j][k] = AIR
					end
				end
			end
			mats[i], occs[i] = mcol, ocol
		end
		local region = Region3.new(Vector3.new(ox + sx * VOX, oy, oz), Vector3.new(ox + (sx + w) * VOX, oy + ny * VOX, oz + nz * VOX))
		Terrain:WriteVoxels(region, VOX, mats, occs)
		strips += 1
		if strips % cfg.batch.terrainStrips == 0 then work(nil, true) end
	end
	map.terrainRegion = { cf = CFrame.new(ox + nx * VOX / 2, oy + ny * VOX / 2, oz + nz * VOX / 2), size = Vector3.new(nx * VOX + 8, ny * VOX + 8, nz * VOX + 8) }
end

return TerrainWriter
