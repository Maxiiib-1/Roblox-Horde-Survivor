-- ModuleScript en ServerScriptService/GameServer/Services.
-- El servidor decide cuándo empezar. Un cliente solo puede declarar lista su propia carga.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Gate = {}
local folder = ReplicatedStorage:FindFirstChild("BrainrotLoading") or Instance.new("Folder")
folder.Name = "BrainrotLoading"
folder.Parent = ReplicatedStorage
local state = folder:FindFirstChild("State") or Instance.new("RemoteEvent")
state.Name = "State"; state.Parent = folder
local ready = folder:FindFirstChild("Ready") or Instance.new("RemoteEvent")
ready.Name = "Ready"; ready.Parent = folder
local travel = folder:FindFirstChild("Travel") or Instance.new("RemoteEvent")
travel.Name = "Travel"; travel.Parent = folder
local travelReady = folder:FindFirstChild("TravelReady") or Instance.new("RemoteEvent")
travelReady.Name = "TravelReady"; travelReady.Parent = folder

local active = {} -- [runId] = gate
local byUser = {} -- [userId] = gate
local departure = {} -- [userId] = { token = string, ready = boolean }

local ASSET_PROPS = {
	Decal = { "Texture" }, Texture = { "Texture" }, MeshPart = { "MeshId", "TextureID" },
	SpecialMesh = { "MeshId", "TextureId" }, ImageLabel = { "Image" }, ImageButton = { "Image" },
	Sound = { "SoundId" }, ParticleEmitter = { "Texture" }, Beam = { "Texture" },
	Trail = { "Texture" }, Animation = { "AnimationId" },
}
local function collectAssets(worldFolderName)
	local roots = {}
	local runtime = workspace:FindFirstChild("Runtime")
	local runs = runtime and runtime:FindFirstChild("Runs")
	local world = runs and runs:FindFirstChild(worldFolderName)
	if world then roots[#roots + 1] = world end
	for _, name in ipairs({ "GameAssets", "Assets" }) do
		local root = ReplicatedStorage:FindFirstChild(name)
		if root then roots[#roots + 1] = root end
	end
	local seen, ids = {}, {}
	for _, root in ipairs(roots) do
		for _, obj in ipairs(root:GetDescendants()) do
			local props = ASSET_PROPS[obj.ClassName]
			if props then
				for _, prop in ipairs(props) do
					local ok, value = pcall(function() return obj[prop] end)
					if ok and type(value) == "string" and value ~= "" and not seen[value] then
						seen[value] = true; ids[#ids + 1] = value
					end
				end
			end
		end
	end
	return ids
end

travelReady.OnServerEvent:Connect(function(player, token)
	local d = departure[player.UserId]
	if d and d.token == token then d.ready = true end
end)

function Gate.prepareTeleport(players)
	local token = game:GetService("HttpService"):GenerateGUID(false)
	local roster = {}
	for _, player in ipairs(players) do roster[#roster + 1] = { userId = player.UserId, name = player.DisplayName, ready = false } end
	for _, player in ipairs(players) do
		departure[player.UserId] = { token = token, ready = false }
		travel:FireClient(player, "show", token, roster)
	end
	local deadline = os.clock() + 8
	while os.clock() < deadline do
		local all = true
		for _, player in ipairs(players) do
			local d = departure[player.UserId]
			if not (player.Parent and d and d.token == token and d.ready) then all = false; break end
		end
		if all then
			for _, player in ipairs(players) do departure[player.UserId] = nil end
			return true
		end
		task.wait(0.1)
	end
	Gate.cancelTeleport(players)
	return false
end

function Gate.cancelTeleport(players)
	for _, player in ipairs(players) do
		departure[player.UserId] = nil
		if player.Parent then travel:FireClient(player, "cancel") end
	end
end

local function members(g)
	local out = {}
	for _, userId in ipairs(g.ids) do
		local player = Players:GetPlayerByUserId(userId)
		out[#out + 1] = {
			userId = userId,
			name = player and player.DisplayName or "Conectando...",
			ready = g.ready[userId] == true,
		}
	end
	return out
end
local function send(g, kind, message)
	local payload = {
		kind = kind, runId = g.id, worldFolderName = g.worldFolderName,
		members = members(g), assetIds = kind == "preload" and g.assetIds or nil, message = message,
	}
	for _, userId in ipairs(g.ids) do
		local player = Players:GetPlayerByUserId(userId)
		if player then state:FireClient(player, payload) end
	end
end
local function forget(g)
	active[g.id] = nil
	for _, id in ipairs(g.ids) do if byUser[id] == g then byUser[id] = nil end end
end

-- Ejecutar SOLO tras generar y replicar el mapa y ANTES de activar reloj, enemigos o movimiento.
-- expectedIds: los UserId enviados en TeleportData.coop.members.
-- onAllReady: función que activa la partida y devuelve true si pudo hacerlo.
function Gate.begin(runId, expectedIds, worldFolderName, onAllReady, onFail)
	assert(type(runId) == "string" and type(worldFolderName) == "string")
	assert(type(expectedIds) == "table" and type(onAllReady) == "function")
	assert(not active[runId], "La barrera ya existe")
	local ids, seen = {}, {}
	for _, id in ipairs(expectedIds) do
		if type(id) == "number" and not seen[id] then
			seen[id] = true
			ids[#ids + 1] = id
		end
	end
	assert(#ids > 0, "No hay integrantes esperados")
	local g = { id = runId, ids = ids, ready = {}, worldFolderName = worldFolderName, assetIds = collectAssets(worldFolderName), onAllReady = onAllReady, onFail = onFail, done = false, failed = false }
	active[runId] = g
	for _, id in ipairs(ids) do byUser[id] = g end
	send(g, "preload")
	return g
end

function Gate.fail(g, message)
	if not g or g.done or g.failed then return end
	g.failed = true
	if g.onFail then pcall(g.onFail) end
	send(g, "error", message or "La carga se interrumpió. Volvé al menú.")
	forget(g)
end

function Gate.errorPlayers(ids, message)
	for _, id in ipairs(ids) do
		local player = Players:GetPlayerByUserId(id)
		if player then state:FireClient(player, { kind = "error", message = message }) end
	end
end

ready.OnServerEvent:Connect(function(player, runId)
	local g = byUser[player.UserId]
	if not g then return end
	if runId == "hello" then
		send(g, g.failed and "error" or "preload")
		return
	end
	if g.done or g.failed or runId ~= g.id or g.ready[player.UserId] then return end
	g.ready[player.UserId] = true
	send(g, "waiting")
	for _, id in ipairs(g.ids) do
		if not g.ready[id] then return end
		if not Players:GetPlayerByUserId(id) then
			Gate.fail(g, "Un integrante se desconectó. Volvé al menú.")
			return
		end
	end
	local ok, released = pcall(g.onAllReady)
	if not ok or released ~= true then
		Gate.fail(g, "No se pudo iniciar la partida. Volvé al menú.")
		return
	end
	g.done = true
	send(g, "start")
	forget(g)
end)

Players.PlayerRemoving:Connect(function(player)
	local g = byUser[player.UserId]
	if g then Gate.fail(g, "Un integrante se desconectó. Volvé al menú.") end
end)

return Gate

