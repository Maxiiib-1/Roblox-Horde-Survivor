--!nonstrict
-- ServerScriptService/BossCinematic/BossCinematicService (servidor) — rehecho 2026-11-06
-- Entradas cinematográficas de los nueve jefes. El SERVIDOR valida la activación, pausa el mundo (nadie da ni
-- recibe daño: worldStep no corre con world.paused), aparta a los jugadores del lugar del jefe, fija la hora de
-- inicio (hora del servidor) y, al terminar, crea el jefe REAL en el mismo punto, tamaño y orientación.
-- Toda la puesta en escena (modelo animado por articulación, escenografía, VFX, cámara y sonido) corre en cada
-- CLIENTE (StarterPlayerScripts/BossCinematic), sincronizada con esa hora: el grupo entero ve lo mismo.
-- Eventos (ReplicatedStorage.BossCinematic.CinematicEvent):
--   "start"  {theme, t0, dur, portal, boss, front, bossSize, bossName, place}   -> empieza la escena
--   "fight"  {bossName, theme}                                                  -> el jefe real ya existe: PELEA
--   "finish" {music}                                                            -> todo vuelve a la normalidad
--   "music"  {on = false}                                                       -> corta la música del jefe
-- Lo engancha Services/RunService (setupWorld al generar cada etapa; cleanup / bossEnded / playerLeft).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Folder = ReplicatedStorage:WaitForChild("BossCinematic")
local Config = require(Folder:WaitForChild("Config"))
local Event = Folder:WaitForChild("CinematicEvent")

local Service = {}
local deps -- { RunService, BossDirector, MapService, getChar, active, standing, send, sendAll, pause, resume }
local warned = {}
local function warnOnce(key, msg)
	if warned[key] then return end
	warned[key] = true
	warn("[BossCinematic] " .. msg)
end

function Service.init(d) deps = d end

local function waitT(ctx, t)
	local t0 = os.clock()
	while os.clock() - t0 < t do
		if ctx.aborted() then error("abort", 0) end
		task.wait()
	end
end

-- ===== envío a los clientes del grupo =====
local function fireAll(world, kind, data)
	for _, m in ipairs(deps.active(world)) do
		if m.player and m.player.Parent then Event:FireClient(m.player, kind, data) end
	end
end

-- ===== ProximityPrompt del portal =====
local function cinematicBoss(world)
	local name, def, modelId = deps.BossDirector.resolve(world.mapId, world.mapLevel)
	if not name or not Config.Bosses[modelId] then return nil end
	return name, def, modelId
end

function Service.setupWorld(world)
	if not Config.Enabled then return end
	local portal = world.map and world.map.portal
	if not portal then return end
	if not cinematicBoss(world) then return end -- este mapa/nivel no tiene la cinemática: portal de siempre
	if not portal.part then
		warnOnce("noportalpart", "El portal del jefe no tiene la pieza 'Portal': se usa la activación normal.")
		return
	end
	local pp = Instance.new("ProximityPrompt")
	pp.Name = "BossCinematicPrompt"
	pp.ActionText = Config.Prompt.ActionText
	pp.ObjectText = Config.Prompt.ObjectText
	pp.KeyboardKeyCode = Enum.KeyCode.E
	pp.GamepadKeyCode = Enum.KeyCode.ButtonX
	pp.HoldDuration = Config.Prompt.HoldDuration or 0
	pp.MaxActivationDistance = Config.Prompt.MaxActivationDistance or 14
	pp.RequiresLineOfSight = false
	pp.Parent = portal.part
	portal.pp = true -- el aviso "E" propio del juego se oculta para este portal (Hud) y RunService.interact lo rechaza
	world.cinePrompt = pp
	pp.Triggered:Connect(function(player) Service.trigger(world, player) end)
end

-- ===== activación (validada en el servidor) =====
function Service.trigger(world, player)
	local run = deps.RunService.get(player)
	if not run or run.world ~= world or rawget(run, "over") or run.downed or run.dying then return end
	if world.cinematic or world.bossStarted or world.ended or world.destroyed then return end
	local okState = (world.state == "Playing" or world.state == "StageComplete")
	if world.paused or not okState then
		deps.send(run, "Toast", { text = "Esperá a que todos terminen de elegir antes de activar el portal.", short = true })
		return
	end
	local portal = world.map.portal
	local _, _, hrp = deps.getChar(run)
	if not hrp or not portal.part or (hrp.Position - portal.part.Position).Magnitude > (Config.Prompt.MaxActivationDistance or 14) + 6 then return end
	-- bloqueo: una sola cinemática por mundo (aunque varios aprieten E en el mismo instante)
	world.cinematic = { by = player, t0 = os.clock() }
	portal.used = true
	if world.cinePrompt then world.cinePrompt.Enabled = false end
	task.spawn(Service.play, world, run)
end

local PLACE = { forest = "Bosque", desert = "Desierto", hidden = "Zona oculta" }

-- ===== secuencia =====
function Service.play(world, run)
	local name, def, modelId = cinematicBoss(world)
	local T = Config.Timing
	local ctx = { dead = false }
	local deadline = os.clock() + (Config.MaxSeconds or 40)
	function ctx.aborted()
		return world.ended or world.destroyed or #deps.active(world) == 0 or os.clock() > deadline
	end
	local paused = {}
	local function lockAll()
		for _, m in ipairs(deps.active(world)) do
			if not paused[m] then paused[m] = true; deps.pause(m, "cinematic") end
		end
	end
	local function unlockAll()
		for m in pairs(paused) do
			if not rawget(m, "over") then deps.resume(m, "cinematic") end
		end
		paused = {}
	end

	-- geometría (espacio del mundo): portal, frente (hacia el inicio) y punto exacto del jefe
	local portal = world.map.portal
	local O = world.origin
	local function ground(x, z) return O + Vector3.new(x, world.map.height(x, z), z) end
	local P = portal.part.Position
	local f = Vector3.new(-portal.x, 0, -portal.z)
	f = f.Magnitude > 0.01 and f.Unit or Vector3.new(0, 0, 1)
	local visSize = deps.BossDirector.visSizeOf(def)     -- tamaño EXACTO del jefe
	local bx, bz = deps.BossDirector.spawnPoint(world, def.size or 14, Config.BossDistance)
	local B = ground(bx, bz)                             -- donde aparece el jefe real
	local dur = (Config.Durations and Config.Durations[modelId]) or 12

	local okRun, err = pcall(function()
		lockAll()
		-- jugadores fuera del lugar donde va a estar el jefe (en fila, mirando al portal)
		local list = deps.active(world)
		for i, m in ipairs(list) do
			local _, _, hrp = deps.getChar(m)
			if hrp and (Vector3.new(hrp.Position.X, 0, hrp.Position.Z) - Vector3.new(B.X, 0, B.Z)).Magnitude < visSize * 0.7 then
				local side = f:Cross(Vector3.yAxis)
				local p = B + f * (visSize * 0.8) + side * ((i - (#list + 1) / 2) * 4)
				p = ground(p.X - O.X, p.Z - O.Z) + Vector3.new(0, 3, 0)
				hrp.CFrame = CFrame.lookAt(p, Vector3.new(P.X, p.Y, P.Z))
			end
		end
		local lead = Config.LeadIn or 0.4
		local t0 = workspace:GetServerTimeNow() + lead
		fireAll(world, "start", { theme = modelId, t0 = t0, dur = dur, portal = P, portalGround = ground(portal.x, portal.z), front = f, boss = B,
			bossSize = visSize, bossName = name, place = (PLACE[world.mapId] or tostring(world.mapId)) .. " · Nivel " .. tostring(world.mapLevel), by = run.player.DisplayName })
		waitT(ctx, lead + dur)
		-- solo Studio: workspace.CineDebugHold mantiene la escena abierta para revisarla cuadro por cuadro
		while game:GetService("RunService"):IsStudio() and workspace:GetAttribute("CineDebugHold") and not (world.ended or world.destroyed) do
			deadline = os.clock() + (Config.MaxSeconds or 40)
			task.wait(0.1)
		end
		-- el jefe REAL reemplaza al de la cinemática: mismo punto, tamaño y mirada (sin subir del suelo)
		local h = (run.world == world and not rawget(run, "over")) and run or deps.active(world)[1]
		if not h then error("abort", 0) end
		deps.RunService.startBoss(h, { at = { bx, bz }, noSummon = true, face = f })
		fireAll(world, "fight", { bossName = name, theme = modelId })
		waitT(ctx, T.fightText or 1.4)
	end)

	ctx.dead = true
	if not okRun and err ~= "abort" then warn("[BossCinematic] la cinemática falló: " .. tostring(err)) end
	-- siempre: se libera a todos, el jefe existe y empieza el combate (aunque la escena se haya cortado)
	if not world.ended and not world.destroyed and not world.bossStarted then
		local h = deps.active(world)[1]
		if h then deps.RunService.startBoss(h, { at = { bx, bz }, noSummon = true, face = f }) end
	end
	unlockAll()
	if not world.ended and not world.destroyed then fireAll(world, "finish", { music = true }) end
	world.cinematic = nil
end

-- ===== ganchos =====
-- el mundo se destruye (cambio de etapa/mapa, fin de la run): los clientes que estaban viendo la escena la cortan
function Service.cleanup(world)
	if world.cinematic then pcall(fireAll, world, "finish", { music = false }) end
end

-- jefe vencido: se corta la música del jefe
function Service.bossEnded(world)
	fireAll(world, "music", { on = false })
end

-- un jugador sale de la partida: su cámara/controles vuelven a la normalidad y se corta su música
function Service.playerLeft(run)
	if run.player and run.player.Parent then Event:FireClient(run.player, "finish", { music = false }) end
end

return Service
