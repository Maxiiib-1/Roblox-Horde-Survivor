--!nonstrict
-- Services/PartyService: grupos de hasta 4 amigos (cooperativo).
-- Flujo: en el servidor público se arma el grupo (invitar / aceptar). Cada miembro elige su personaje con JUGAR.
-- Cuando el líder empieza, el grupo viaja a un SERVIDOR PRIVADO reservado solo para ellos y la partida arranca sola.
-- En Studio (no se puede teletransportar) y dentro de un servidor privado, la partida empieza en el mismo servidor.

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local RunServiceRbx = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("GameShared")
local GameConfig = require(Shared.Config.GameConfig)
local ClassesCat = require(Shared.Catalogs.Classes)
local MapsCat = require(Shared.Catalogs.Maps)
local Progression = require(Shared.Util.Progression)
local Gate = require(script.Parent.GroupLoadingGate)
local HttpService = game:GetService("HttpService")

local Party = {}
local COOP = GameConfig.coop
local MAX = COOP.maxPlayers

local remotes, RunService, Profile
local byUser = {}    -- [userId] = party
local invites = {}   -- [userIdInvitado] = { [userIdLider] = os.clock() }
local pendingGroup = nil -- servidor privado: grupo que llega por teletransporte
local failedSessions = {} -- un grupo incompleto no puede recrear la espera al llegar tarde

local function isReserved()
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end
Party.isReserved = isReserved

local function canTeleport()
	return not RunServiceRbx:IsStudio() and not isReserved() and game.PlaceId ~= 0
end

local function firstUnlocked(player)
	for _, c in ipairs(ClassesCat.list) do
		if Profile.canUseClass(player, c.id) then return c.id end
	end
	return "class_01"
end

local function classFor(party, player)
	local c = party.classes[player.UserId]
	if c and ClassesCat.byId[c] and Profile.canUseClass(player, c) then return c end
	return firstUnlocked(player)
end

-- ===== Estado para el cliente =====
local function payloadFor(player)
	local p = byUser[player.UserId]
	local members = {}
	if p then
		for _, m in ipairs(p.members) do
			members[#members + 1] = { userId = m.UserId, name = m.DisplayName, leader = (m == p.leader), classId = p.classes[m.UserId], ready = p.classes[m.UserId] ~= nil }
		end
	end
	local inv = {}
	for lid in pairs(invites[player.UserId] or {}) do
		local lp = Players:GetPlayerByUserId(lid)
		if lp then inv[#inv + 1] = { userId = lid, name = lp.DisplayName } end
	end
	local others = {}
	for _, o in ipairs(Players:GetPlayers()) do
		if o ~= player then
			local op = byUser[o.UserId]
			others[#others + 1] = { userId = o.UserId, name = o.DisplayName, sameParty = (p ~= nil and op == p), inParty = op ~= nil,
				busy = RunService.get(o) ~= nil, invited = (invites[o.UserId] or {})[player.UserId] ~= nil }
		end
	end
	return {
		members = members, invites = inv, players = others, max = MAX,
		isLeader = (p ~= nil and p.leader == player), inParty = p ~= nil and #p.members > 1,
		reserved = isReserved(), hpPerExtra = COOP.hpPerExtra, dmgPerExtra = COOP.dmgPerExtra,
	}
end

function Party.sync(player)
	if remotes and player.Parent then remotes.PartyData:FireClient(player, payloadFor(player)) end
end

function Party.syncAll()
	for _, pl in ipairs(Players:GetPlayers()) do Party.sync(pl) end
end

local function toast(player, text)
	if remotes and player.Parent then remotes.Toast:FireClient(player, { text = text }) end
end

-- ===== Operaciones =====
local function newParty(leader)
	local p = { leader = leader, members = { leader }, classes = {} }
	byUser[leader.UserId] = p
	return p
end

local function removeMember(player, silent)
	local p = byUser[player.UserId]
	if not p then return end
	byUser[player.UserId] = nil
	local idx = table.find(p.members, player)
	if idx then table.remove(p.members, idx) end
	p.classes[player.UserId] = nil
	if #p.members == 0 then return end
	if p.leader == player then
		p.leader = p.members[1]
		if not silent then toast(p.leader, "Ahora eres el líder del grupo.") end
	end
	if #p.members == 1 then
		-- grupo de uno: se disuelve
		local last = p.members[1]
		byUser[last.UserId] = nil
		if not silent then toast(last, "Tu grupo se disolvió.") end
	else
		for _, m in ipairs(p.members) do
			if not silent then toast(m, ("%s salió del grupo."):format(player.DisplayName)) end
		end
	end
end

local function invite(leader, targetId)
	local target = Players:GetPlayerByUserId(targetId)
	if not target or target == leader then return false, "invalid" end
	local p = byUser[leader.UserId]
	if p and p.leader ~= leader then return false, "not_leader" end
	if p and #p.members >= MAX then return false, "party_full" end
	if p and table.find(p.members, target) then return false, "already_member" end
	invites[targetId] = invites[targetId] or {}
	invites[targetId][leader.UserId] = os.clock()
	toast(target, ("?? %s te invitó a su grupo. Abre GRUPO en el menú para aceptar."):format(leader.DisplayName))
	toast(leader, ("Invitación enviada a %s."):format(target.DisplayName))
	return true
end

local function accept(player, leaderId)
	local list = invites[player.UserId]
	if not (list and list[leaderId]) then return false, "no_invite" end
	list[leaderId] = nil
	local leader = Players:GetPlayerByUserId(leaderId)
	if not leader then return false, "invalid" end
	if RunService.get(player) or RunService.get(leader) then return false, "in_run" end
	local p = byUser[leaderId]
	if p and p.leader ~= leader then p = nil end
	if not p then
		if byUser[leaderId] then return false, "invalid" end -- el que invitó ya está en otro grupo como miembro
		p = newParty(leader)
	end
	if #p.members >= MAX then return false, "party_full" end
	if byUser[player.UserId] then removeMember(player, true) end
	table.insert(p.members, player)
	byUser[player.UserId] = p
	for _, m in ipairs(p.members) do
		toast(m, ("?? %s se unió al grupo (%d/%d)."):format(player.DisplayName, #p.members, MAX))
	end
	return true
end

-- ===== Inicio de la partida del grupo =====
local function startLocal(p, mapId, level, expectedIds)
	local entries = { { player = p.leader, classId = classFor(p, p.leader) } }
	for _, m in ipairs(p.members) do
		if m ~= p.leader and m.Parent then entries[#entries + 1] = { player = m, classId = classFor(p, m) } end
	end
	local run, result, who = RunService.startGroup(entries, mapId, level, nil, true)
	if not run then
		local msg = ({ run_active = "%s ya está en una partida.", no_character = "%s todavía no apareció.", no_profile = "El perfil de %s no cargó.", class_locked = "%s no tiene ese personaje." })[result]
		for _, m in ipairs(p.members) do toast(m, msg and msg:format(who and who.DisplayName or "?") or ("No se pudo iniciar: " .. tostring(result))) end
		return nil, result
	end
	local world = result
	local ids = expectedIds or {}
	if not expectedIds then for _, m in ipairs(p.members) do ids[#ids + 1] = m.UserId end end
	Gate.begin(world.folder.Name, ids, world.folder.Name, function()
		return RunService.releasePrepared(world)
	end, function()
		RunService.abortPrepared(world)
	end)
	return run
end

local function teleportParty(p, mapId, level)
	local okR, code = pcall(TeleportService.ReserveServerAsync, TeleportService, game.PlaceId)
	if not okR then return false, "reserve_failed" end
	local ids, classes, names = {}, {}, {}
	for _, m in ipairs(p.members) do
		ids[#ids + 1] = m.UserId
		classes[tostring(m.UserId)] = classFor(p, m)
		names[tostring(m.UserId)] = m.DisplayName
	end
	local opts = Instance.new("TeleportOptions")
	opts.ReservedServerAccessCode = code
	opts:SetTeleportData({ publicLobbyJobId = game.PrivateServerId == "" and game.JobId or nil, coop = { sessionId = HttpService:GenerateGUID(false), leader = p.leader.UserId, members = ids, classes = classes, names = names, mapId = mapId, level = level } })
	if not Gate.prepareTeleport(p.members) then return false, "loading_ui_unavailable" end
	for _, m in ipairs(p.members) do toast(m, "?? Viajando al servidor del grupo…") end
	local okT, err = pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, p.members, opts)
	if not okT then
		Gate.cancelTeleport(p.members)
		for _, m in ipairs(p.members) do toast(m, "No se pudo viajar al servidor del grupo: " .. tostring(err)) end
		return false, "teleport_failed"
	end
	return true
end

-- Lo llama NetworkService al recibir RequestStartRun. Devuelve:
--   nil              -> no hay grupo: partida en solitario normal
--   "member_ready"   -> un miembro (no líder) eligió su personaje
--   "teleporting"    -> el grupo viaja al servidor privado
--   run              -> partida del grupo iniciada en este servidor
--   false, err       -> error
function Party.tryStart(player, classId, mapId, level)
	local p = byUser[player.UserId]
	if not p or #p.members < 2 then return nil end
	if not (ClassesCat.byId[classId] and Profile.canUseClass(player, classId)) then return false, "class_locked" end
	p.classes[player.UserId] = classId
	if p.leader ~= player then
		Party.syncAll()
		for _, m in ipairs(p.members) do
			if m ~= player then toast(m, ("%s eligió personaje y está listo."):format(player.DisplayName)) end
		end
		return "member_ready"
	end
	-- líder: valida el mapa y que nadie esté jugando
	if not MapsCat.byId[mapId] then return false, "invalid_ids" end
	local rec = Profile.get(player)
	if not rec or not Progression.isLevelUnlocked(rec.data.mapProgress, mapId, level) then return false, "map_locked" end
	for _, m in ipairs(p.members) do
		local r = RunService.get(m)
		if r and not r.over then return false, "member_busy" end
	end
	if canTeleport() then
		local ok, err = teleportParty(p, mapId, level)
		if not ok then return false, err end
		return "teleporting"
	end
	local run, err = startLocal(p, mapId, level)
	if not run then return false, err end
	return run
end

-- ===== Servidor privado: llegada del grupo =====
function Party.onProfileReady(player)
	if not isReserved() then return end
	local ok, data = pcall(function() return player:GetJoinData().TeleportData end)
	local coop = ok and type(data) == "table" and data.coop
	if type(coop) ~= "table" or type(coop.members) ~= "table" or type(coop.sessionId) ~= "string" then return end
	if not table.find(coop.members, player.UserId) then return end
	if failedSessions[coop.sessionId] then
		Gate.errorPlayers({ player.UserId }, "El grupo no llegó completo. Volvé al menú.")
		return
	end
	if not pendingGroup then
		pendingGroup = { sessionId = coop.sessionId, leaderId = coop.leader, ids = coop.members, classes = coop.classes or {}, mapId = coop.mapId, level = coop.level, arrived = {}, started = false, t0 = os.clock() }
		local g = pendingGroup
		task.spawn(function()
			while not g.started do
				local all = true
				for _, id in ipairs(g.ids) do
					local pl = Players:GetPlayerByUserId(id)
					if not (g.arrived[id] and pl and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")) then all = false end
				end
				if all then break end
				if os.clock() - g.t0 > COOP.arrivalTimeout then
					g.started = true; failedSessions[g.sessionId] = true; pendingGroup = nil
					Gate.errorPlayers(g.ids, "El grupo no llegó completo. Volvé al menú.")
					return
				end
				task.wait(0.5)
			end
			if g.started then return end
			g.started = true; pendingGroup = nil
			local leader = Players:GetPlayerByUserId(g.leaderId)
			if not leader then Gate.errorPlayers(g.ids, "El líder no llegó. Volvé al menú."); return end
			local p = newParty(leader)
			for _, id in ipairs(g.ids) do
				local m = Players:GetPlayerByUserId(id)
				if not m then
					failedSessions[g.sessionId] = true
					Gate.errorPlayers(g.ids, "Un integrante se desconectó. Volvé al menú.")
					return
				end
				if m ~= leader then table.insert(p.members, m); byUser[id] = p end
			end
			for _, m in ipairs(p.members) do p.classes[m.UserId] = g.classes[tostring(m.UserId)] end
			Party.syncAll()
			local run = startLocal(p, g.mapId, g.level, g.ids)
			if not run then Gate.errorPlayers(g.ids, "No se pudo preparar la partida. Volvé al menú.") end
		end)
	end
	if pendingGroup.sessionId ~= coop.sessionId then return end
	pendingGroup.arrived[player.UserId] = true
end

-- ===== Red =====
function Party.init(r, runService, profile)
	remotes, RunService, Profile = r, runService, profile
	TeleportService.TeleportInitFailed:Connect(function(player)
  if player:GetAttribute("ReturningToLobby") then return end
  toast(player, "No se pudo entrar al servidor privado. Vuelve a intentar desde JUGAR.")
 end)

	remotes.RequestParty.OnServerEvent:Connect(function(player, action, arg)
		if type(action) ~= "string" or #action > 16 then return end
		local ok, err = true, nil
		if action == "invite" and type(arg) == "number" then ok, err = invite(player, arg)
		elseif action == "accept" and type(arg) == "number" then ok, err = accept(player, arg)
		elseif action == "decline" and type(arg) == "number" then
			if invites[player.UserId] then invites[player.UserId][arg] = nil end
		elseif action == "leave" then
			removeMember(player)
			if isReserved() and not RunService.get(player) then
				-- en el servidor privado, salir del grupo te devuelve a un servidor público
				toast(player, "Volviendo al servidor público…")
				pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, { player })
			end
		elseif action == "kick" and type(arg) == "number" then
			local p = byUser[player.UserId]
			local target = Players:GetPlayerByUserId(arg)
			if p and p.leader == player and target and byUser[arg] == p then
				removeMember(target)
				toast(target, "El líder te sacó del grupo.")
			end
		elseif action == "refresh" then
			-- solo reenvía el estado
		else
			return
		end
		if not ok and err then
			local msgs = { party_full = "El grupo está lleno (máx. 4).", not_leader = "Solo el líder puede invitar.", in_run = "Esperen a terminar la partida.", no_invite = "La invitación ya no está.", already_member = "Ya está en tu grupo." }
			toast(player, msgs[err] or ("No se pudo: " .. tostring(err)))
		end
		Party.syncAll()
	end)
	Players.PlayerAdded:Connect(function() task.wait(1); Party.syncAll() end)
	Players.PlayerRemoving:Connect(function(player)
		removeMember(player)
		invites[player.UserId] = nil
		for _, list in pairs(invites) do list[player.UserId] = nil end
		task.defer(Party.syncAll)
	end)
end

return Party
