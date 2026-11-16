-- Return only completed reserved matches to a public lobby.
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local Runtime = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Return = {}
local pending = {}
local fallbackServer = HttpService:GenerateGUID(false)
function Return.begin(player, profile, remotes)
 if Runtime:IsStudio() or game.PrivateServerId == "" or game.PrivateServerOwnerId ~= 0 or not player.Parent then return end
 if pending[player] then return end
 local state = {}
 pending[player] = state
 player:SetAttribute("ReturningToLobby", true)
 local function toast(message)
  if player.Parent and remotes then remotes.Toast:FireClient(player, {text = message}) end
 end
 toast("Partida terminada. Volviendo al lobby público en 8 segundos…")
 task.spawn(function()
  task.wait(8)
  local attempt = 0
  while player.Parent and pending[player] == state do
   -- Wait for any concurrent save and persist rewards before leaving.
   local saved = profile.save(player)
   if saved then
    attempt += 1
    local options = Instance.new("TeleportOptions")
    local join = player:GetJoinData()
    local data = join and join.TeleportData
    local lobbyId = type(data) == "table" and data.publicLobbyJobId
    options.ServerInstanceId = type(lobbyId) == "string" and lobbyId ~= "" and lobbyId or fallbackServer
    -- Deliberately omit coop: the destination must open the menu, not start another run.
    options:SetTeleportData({returnedFromRun = true})
    state.failed = false
    local ok, err = pcall(function() TeleportService:TeleportAsync(game.PlaceId, {player}, options) end)
    if not ok then state.failed = true; warn("[ReturnToLobby] " .. tostring(err)) end
    if ok then
     local deadline = os.clock() + 25
     repeat task.wait(0.5) until not player.Parent or state.failed or os.clock() >= deadline
    end
   end
   if not player.Parent then break end
   toast(saved and "Reintentando el regreso al lobby público…" or "Guardando tus premios antes de volver al lobby…")
   task.wait(math.min(15, 3 + attempt * 2))
  end
  pending[player] = nil
 end)
end
TeleportService.TeleportInitFailed:Connect(function(player)
 local state = pending[player]
 if state then state.failed = true end
end)
Players.PlayerRemoving:Connect(function(player) pending[player] = nil end)
return Return
