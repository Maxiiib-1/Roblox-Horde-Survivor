--!nonstrict
-- Services/NetworkService: única entrada del cliente. Valida tipos, rangos, runId, estado, frecuencia y deduplica.
-- No existe ningún remote del tipo GiveGold/SetLevel/DamageEnemy/UnlockAll.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("GameShared")
local Protocol = require(Shared.Network.Protocol)
local ClassesCat = require(Shared.Catalogs.Classes)
local MapsCat = require(Shared.Catalogs.Maps)
local HatsOk = { hat_01 = true }

local Services = script.Parent
local RunService = require(Services.RunService)
local Offers = require(Services.OfferService)
local Profile = require(Services.Parent.Persistence.ProfileService)
local ClassEffects = require(Services.Parent.Classes.ClassEffects)
local Leaderboard = require(Services.LeaderboardService)
local Party = require(Services.PartyService)
local Gate = require(Services.GroupLoadingGate)

local Net = {}
local lastCall = {} -- [userId][action] = os.clock()

local SETTINGS_SCHEMA = {
	master = { "number", 0, 1 }, music = { "number", 0, 1 }, sfx = { "number", 0, 1 }, hudScale = { "number", 0.7, 1.4 },
	quality = { "int", 1, 3 }, shake = { "number", 0, 1 }, flashes = { "number", 0, 1 }, damageNumbers = { "bool" }, autoAim = { "bool" },
	sensitivity = { "number", 0.3, 2 },
	challengeMode = { "int", 0, 3 }, -- 2026-11-05: modo de desafío elegido en la pantalla de mapas (0 = ninguno)
}

local function limited(player, action)
	local now = os.clock()
	local t = lastCall[player.UserId]
	if not t then t = {}; lastCall[player.UserId] = t end
	local minI = Protocol.limits.minIntervalSeconds[action] or 0.1
	if t[action] and now - t[action] < minI then return true end
	t[action] = now
	return false
end

local function ack(remotes, player, requestId, ok, err, extra)
	local payload = { requestId = requestId, ok = ok, err = err }
	if extra then for k, v in pairs(extra) do payload[k] = v end end
	remotes.Ack:FireClient(player, payload)
end

local function validReq(requestId)
	return type(requestId) == "string" and #requestId > 0 and #requestId <= 40
end

function Net.init(remotes)
	RunService.setRemotes(remotes)

	local function bind(name, fn)
		remotes[name].OnServerEvent:Connect(function(player, ...)
			if limited(player, name) then return end
			local ok, err = pcall(fn, player, ...)
			if not ok then warn("[Net] " .. name .. ": " .. tostring(err)) end
		end)
	end

	bind("RequestProfile", function(player)
		local rec = Profile.get(player)
		if rec then remotes.ProfileData:FireClient(player, Profile.publicData(player))
		else remotes.ProfileData:FireClient(player, { loading = true, error = (Profile.load(player) or {}).error }) end
	end)

	bind("RequestLeaderboard", function(player, scope)
		scope = (scope == "friends" or scope == "group") and scope or "global"
		local rows = {}
		if scope == "group" then
			-- runs en grupo: {puesto, "Ana + Beto", kills totales, estoyEnElGrupo, nil, "2 jugadores"}
			local me = tostring(player.UserId)
			for _, e in ipairs(Leaderboard.groupTop()) do
				rows[#rows + 1] = { e.rank, table.concat(e.names, " + "), e.kills, table.find(e.ids, me) ~= nil, nil, ("%d jugadores"):format(#e.names) }
			end
			local best = Leaderboard.myGroupBest(player)
			remotes.LeaderboardData:FireClient(player, { rows = rows, scope = scope, dev = Leaderboard.isDevMemory, myBest = best and best.kills or 0, myBestText = best and table.concat(best.names, " + ") or nil, metric = "kills" })
			return
		end
		local list = scope == "friends" and Leaderboard.friends(player) or Leaderboard.top()
		for _, e in ipairs(list) do rows[#rows + 1] = { e.rank, e.name, e.kills, e.userId == player.UserId, e.classId } end -- {puesto, nombre, kills, soyYo, personaje}
		local rec = Profile.get(player)
		remotes.LeaderboardData:FireClient(player, { rows = rows, scope = scope, dev = Leaderboard.isDevMemory, myBest = rec and rec.data.bestRunKills or 0, myBestClass = rec and rec.data.bestRunKillsClass or nil, metric = "kills" })
	end)

	bind("RequestUpgrade", function(player, upgradeId, requestId)
		if not (Protocol.isId(upgradeId) and validReq(requestId)) then return end
		local ok, err = Profile.purchaseUpgrade(player, upgradeId, requestId)
		ack(remotes, player, requestId, ok, err)
		remotes.ProfileData:FireClient(player, Profile.publicData(player))
	end)

	bind("RequestToggle", function(player, id)
		if not Protocol.isId(id) then return end
		local ok, err = Profile.toggle(player, id)
		if not ok then remotes.Ack:FireClient(player, { ok = false, err = err }) end
		remotes.ProfileData:FireClient(player, Profile.publicData(player))
	end)

	bind("RequestSelectSkin", function(player, classId, skinId)
		if not (Protocol.isId(classId) and Protocol.isId(skinId)) then return end
		local ok, err = Profile.selectSkin(player, classId, skinId)
		if not ok then remotes.Ack:FireClient(player, { ok = false, err = err }) end
		remotes.ProfileData:FireClient(player, Profile.publicData(player))
	end)

	bind("RequestSpin", function(player, requestId)
		if not validReq(requestId) then return end
		local allowPaid = require(Services.CommerceService).canRandom(player)
		local ok, res = Profile.spin(player, workspace:GetServerTimeNow(), allowPaid)
		ack(remotes, player, requestId, ok, (not ok) and res or nil, ok and { spin = res } or nil)
		remotes.ProfileData:FireClient(player, Profile.publicData(player))
	end)

	bind("RequestBuyEgg", function(player, eggId, requestId)
		if not (Protocol.isId(eggId) and validReq(requestId)) then return end
		local ok, res = Profile.buyEgg(player, eggId, requestId)
		if not ok and res == "duplicate" then return end
		ack(remotes, player, requestId, ok, (not ok) and res or nil, ok and { egg = res } or nil)
		remotes.ProfileData:FireClient(player, Profile.publicData(player))
	end)

	-- Huevos de jefe: el cliente solo pide; el servidor valida dueño, estado y tiempo con SU reloj
	local function pushProfile(player)
		local pd = Profile.publicData(player)
		if pd then remotes.ProfileData:FireClient(player, pd) end
	end
	local function saveSoon(player)
		task.spawn(function() Profile.save(player) end) -- si ya hay un guardado en curso, lo toma el autoguardado
	end
	bind("RequestIncubateEgg", function(player, uid, requestId)
		if not (Protocol.isId(uid) and validReq(requestId)) then return end
		local ok, res = Profile.incubateEgg(player, uid, workspace:GetServerTimeNow())
		ack(remotes, player, requestId, ok, (not ok) and res or nil, ok and { incubate = res } or nil)
		if ok then saveSoon(player) end
		pushProfile(player)
	end)

	bind("RequestOpenEgg", function(player, uid, requestId)
		if not (Protocol.isId(uid) and validReq(requestId)) then return end
		local ok, res = Profile.openBossEgg(player, uid, workspace:GetServerTimeNow())
		ack(remotes, player, requestId, ok, (not ok) and res or nil, ok and { opened = res } or nil)
		if ok then saveSoon(player) end
		pushProfile(player)
	end)

	bind("RequestPlacePet", function(player, petId, on)
		if not Protocol.isId(petId) or type(on) ~= "boolean" then return end
		local ok, err = Profile.placePet(player, petId, on)
		if not ok then remotes.Ack:FireClient(player, { ok = false, err = err }) end
		remotes.ProfileData:FireClient(player, Profile.publicData(player))
	end)

	bind("RequestEquipPet", function(player, petId)
		if not Protocol.isId(petId) then return end
		local ok, err = Profile.equipPet(player, petId)
		if not ok then remotes.Ack:FireClient(player, { ok = false, err = err }) end
		remotes.ProfileData:FireClient(player, Profile.publicData(player))
	end)

	bind("RequestSlide", function(player, runId)
		if not Protocol.isId(runId) then return end
		local run = RunService.get(player)
		if not run or run.over or run.id ~= runId then return end
		RunService.slide(run)
	end)

	bind("RequestStartRun", function(player, classId, mapId, tier, requestId)
		if not validReq(requestId) then return end
		if not (Protocol.isId(classId) and Protocol.isId(mapId) and Protocol.isInt(tier, 1, 3)) then return ack(remotes, player, requestId, false, "invalid_args") end
		-- cooperativo: si está en un grupo, el líder arranca para todos y los demás solo eligen personaje
		local res, perr = Party.tryStart(player, classId, mapId, tier)
		if res == "member_ready" then return ack(remotes, player, requestId, true, nil, { partyReady = true }) end
		if res == "teleporting" then return ack(remotes, player, requestId, true, nil, { teleporting = true }) end
		if res == false then return ack(remotes, player, requestId, false, perr) end
		if type(res) == "table" then return ack(remotes, player, requestId, true, nil, { runId = res.id }) end
		local run, result = RunService.startGroup({ { player = player, classId = classId } }, mapId, tier, nil, true)
		if not run then return ack(remotes, player, requestId, false, result) end
		local world = result
		Gate.begin(world.folder.Name, { player.UserId }, world.folder.Name, function()
			return RunService.releasePrepared(world)
		end, function()
			RunService.abortPrepared(world)
		end)
		ack(remotes, player, requestId, true, nil, { runId = run.id })
	end)

	local function ownRun(player, runId)
		local run = RunService.get(player)
		if not run or run.over or run.id ~= runId then return nil end -- respuestas de un runId anterior se ignoran
		return run
	end

	bind("RequestInteract", function(player, runId, interactionId, requestId)
		if not (Protocol.isId(runId) and Protocol.isId(interactionId) and validReq(requestId)) then return end
		local run = ownRun(player, runId); if not run then return end
		if RunService.dedupe(run, requestId) then return end
		local ok, err = RunService.interact(run, interactionId)
		ack(remotes, player, requestId, ok, err)
		if not ok and err == "no_gold" then remotes.Toast:FireClient(player, { text = "No tienes suficiente oro." }) end
	end)

	bind("RequestChooseOffer", function(player, runId, offerId, optionId, requestId)
		if not (Protocol.isId(runId) and Protocol.isInt(offerId, 1, 1e6) and Protocol.isId(optionId) and validReq(requestId)) then return end
		local run = ownRun(player, runId); if not run then return end
		if RunService.dedupe(run, requestId) then return end -- dos peticiones idénticas aplican una sola mejora
		local ok, err = Offers.choose(run, offerId, optionId)
		ack(remotes, player, requestId, ok, err)
	end)

	bind("RequestOfferAction", function(player, runId, offerId, actionId, targetOptionId, requestId)
		if not (Protocol.isId(runId) and Protocol.isInt(offerId, 1, 1e6) and Protocol.isId(actionId) and validReq(requestId)) then return end
		if targetOptionId ~= nil and not Protocol.isId(targetOptionId) then return end
		local run = ownRun(player, runId); if not run then return end
		if RunService.dedupe(run, requestId) then return end
		local ok, err = Offers.action(run, offerId, actionId, targetOptionId)
		ack(remotes, player, requestId, ok, err)
	end)

	bind("RequestAbility", function(player, runId, abilityId, seq, aimDir)
		if not (Protocol.isId(runId) and Protocol.isId(abilityId) and Protocol.isFiniteNumber(seq)) then return end
		local run = ownRun(player, runId); if not run or run.paused then return end
		if abilityId == "class_04" and ClassEffects.tryAbility(run) then
			remotes.Toast:FireClient(player, { text = "Pulso defensivo", short = true })
		end
	end)

	bind("UpdateAim", function(player, runId, seq, dir, active)
		if not (Protocol.isId(runId) and Protocol.isFiniteNumber(seq)) then return end
		local run = ownRun(player, runId); if not run then return end
		if active == false or dir == nil then run.aimActive = false; return end
		if not Protocol.isDirection(dir) then return end
		local flat = Vector3.new(dir.X, 0, dir.Z)
		if flat.Magnitude < 1e-3 then return end
		run.aimDir = flat.Unit
		run.aimActive = true
	end)

	bind("RequestPause", function(player, runId)
		if not Protocol.isId(runId) then return end
		local run = ownRun(player, runId); if not run then return end
		run.pause(run, "menu")
	end)
	bind("RequestResume", function(player, runId)
		if not Protocol.isId(runId) then return end
		local run = ownRun(player, runId); if not run then return end
		run.resume(run, "menu") -- una oferta pendiente mantiene su propia razón de pausa
	end)

	bind("RequestRestart", function(player, runId, requestId)
		if not (Protocol.isId(runId) and validReq(requestId)) then return end
		local run = ownRun(player, runId); if not run then return end
		if RunService.isCoop(run) then return ack(remotes, player, requestId, false, "coop_restart") end -- en grupo no se reinicia solo
		local classId, mapId, tier = run.classId, run.mapId, run.mapLevel
		RunService.abandon(player)
		task.wait(0.7)
		local nr, err = RunService.start(player, classId, mapId, tier)
		ack(remotes, player, requestId, nr ~= nil, err, nr and { runId = nr.id } or nil)
	end)

	bind("RequestReturnToLobby", function(player, runId)
		if not Protocol.isId(runId) then return end
		local run = RunService.get(player)
		if run and not run.over and run.id == runId then RunService.abandon(player) end
	end)

	bind("RequestShopPurchase", function(player, itemId, requestId)
		if not (Protocol.isId(itemId) and validReq(requestId)) then return end
		local ok, err = Profile.purchase(player, itemId, requestId, workspace:GetServerTimeNow())
		ack(remotes, player, requestId, ok, err)
		remotes.ProfileData:FireClient(player, Profile.publicData(player))
	end)

	bind("RequestSelectHat", function(player, hatId)
		local rec = Profile.get(player); if not rec then return end
		if hatId == "" or hatId == nil then rec.data.equippedHat = false
		elseif type(hatId) == "string" and HatsOk[hatId] and rec.data.unlockedHats[hatId] then rec.data.equippedHat = hatId
		else return end
		Profile.markDirty(player)
		player:SetAttribute("HatRefresh", (player:GetAttribute("HatRefresh") or 0) + 1)
		remotes.ProfileData:FireClient(player, Profile.publicData(player))
	end)

	bind("RequestSettingsUpdate", function(player, key, value)
		local rec = Profile.get(player); if not rec then return end
		local schema = type(key) == "string" and SETTINGS_SCHEMA[key]
		if not schema then return end
		local kind = schema[1]
		if kind == "bool" then if type(value) ~= "boolean" then return end
		elseif kind == "int" then if not Protocol.isInt(value, schema[2], schema[3]) then return end
		else if not (Protocol.isFiniteNumber(value) and value >= schema[2] and value <= schema[3]) then return end end
		rec.data.settings[key] = value
		Profile.markDirty(player)
	end)

	bind("RequestClaimMission", function(player, missionId, requestId)
		-- Las misiones se completan solas al liquidar cada run (ProfileService.checkMissions); no hay nada que reclamar.
		if validReq(requestId) then ack(remotes, player, requestId, false, "auto") end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastCall[player.UserId] = nil
		RunService.onPlayerRemoving(player)
		Profile.release(player)
	end)
end

return Net