--!nonstrict
-- Services/LeaderboardService: Top 100 de jugadores con MÁS KILLS EN UNA SOLA RUN (de mayor a menor).
-- Cada récord guarda las kills Y el personaje con el que se consiguieron, en el MISMO valor (atómico):
--   valor = kills * 1000 + slot del personaje (class_01 = 1 … class_999). Así cambiar de personaje después no lo altera.
-- Se guarda el MEJOR récord de cada jugador (no se suma); solo se reemplaza si hay MÁS kills.
-- Studio: tabla en memoria (marcada DEV, no toca servicios reales).
-- Publicado: OrderedDataStore "RunKillsTop_v1" (Top global) + DataStore "RunKillsBest_v1" (récord personal, para la tabla
-- de amigos). NO probado con servidores publicados.
-- Los récords de TIEMPO anteriores ("RunTimeTop_v1" / "RunTimeBest_v1") NO se borran ni se leen como kills.
local Players = game:GetService("Players")
local RunServiceRbx = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")

local LB = {}
LB.SIZE = 100
LB.CACHE_SECONDS = 60
LB.TOP_STORE = "RunKillsTop_v1"
LB.BEST_STORE = "RunKillsBest_v1"
local useMemory = RunServiceRbx:IsStudio()
LB.isDevMemory = useMemory

local memory = {}  -- [userId] = { name, kills, classId }
local names = {}   -- caché de nombres por UserId
local cache, cacheAt, refreshing = {}, -math.huge, false
local store, bestStore
local friendCache = {} -- [userId] = { at, list }

-- ===== codificación: kills + personaje en un solo número =====
local function slotOf(classId)
	local n = tonumber(tostring(classId or ""):match("(%d+)$"))
	return (n and n >= 1 and n <= 999) and n or 0
end
function LB.encode(kills, classId) return math.floor(kills) * 1000 + slotOf(classId) end
function LB.decode(v)
	v = math.floor(tonumber(v) or 0)
	local slot = v % 1000
	return math.floor(v / 1000), slot > 0 and string.format("class_%02d", slot) or nil
end

local function getStore()
	if store then return store end
	local ok, s = pcall(function() return DataStoreService:GetOrderedDataStore(LB.TOP_STORE) end)
	if ok then store = s end
	return store
end
local function getBest()
	if bestStore then return bestStore end
	local ok, s = pcall(function() return DataStoreService:GetDataStore(LB.BEST_STORE) end)
	if ok then bestStore = s end
	return bestStore
end

local function nameOf(userId)
	if names[userId] then return names[userId] end
	local p = Players:GetPlayerByUserId(userId)
	if p then names[userId] = p.DisplayName; return names[userId] end
	local ok, n = pcall(function() return Players:GetNameFromUserIdAsync(userId) end)
	names[userId] = ok and n or ("Jugador " .. tostring(userId))
	return names[userId]
end

-- solo reemplaza si el récord nuevo tiene MÁS kills (con el mismo número de kills se queda el personaje anterior)
local function better(old, new)
	if type(old) ~= "number" then return true end
	local ok = LB.decode(old)
	local nk = LB.decode(new)
	return nk > ok
end

-- Registra las kills de una run terminada con el personaje usado (solo si mejora el récord del jugador)
function LB.submit(player, kills, classId)
	kills = math.floor(tonumber(kills) or 0)
	if kills <= 0 or kills ~= kills then return end
	local uid = player.UserId
	names[uid] = player.DisplayName
	local value = LB.encode(kills, classId)
	if useMemory then
		local cur = memory[uid]
		if not cur or kills > cur.kills then memory[uid] = { name = player.DisplayName, kills = kills, classId = classId } end
		cacheAt = -math.huge
		friendCache[uid] = nil
		return
	end
	task.spawn(function()
		local b = getBest()
		if b then
			pcall(function()
				b:UpdateAsync(tostring(uid), function(old)
					if not better(old, value) then return nil end
					return value
				end)
			end)
		end
		local s = getStore(); if not s then return end
		local ok, err = pcall(function()
			s:UpdateAsync(tostring(uid), function(old)
				if not better(old, value) then return nil end
				return value
			end)
		end)
		if not ok then warn("[Leaderboard] no se pudo guardar: " .. tostring(err)) end
		cacheAt = -math.huge
	end)
end

-- Devuelve { {rank, userId, name, kills, classId}, ... } (máx. 100), con caché de 60 s
function LB.top()
	if os.clock() - cacheAt < LB.CACHE_SECONDS or refreshing then return cache end
	refreshing = true
	local list = {}
	if useMemory then
		for uid, r in pairs(memory) do table.insert(list, { userId = uid, name = r.name, kills = r.kills, classId = r.classId }) end
	else
		local s = getStore()
		if s then
			local ok, page = pcall(function() return s:GetSortedAsync(false, LB.SIZE):GetCurrentPage() end)
			if ok and page then
				for _, e in ipairs(page) do
					local uid = tonumber(e.key)
					local k, cls = LB.decode(e.value)
					if uid and k > 0 then table.insert(list, { userId = uid, name = nameOf(uid), kills = k, classId = cls }) end
				end
			else
				refreshing = false
				return cache -- si falla, se muestra la última tabla conocida
			end
		end
	end
	table.sort(list, function(a, b) return a.kills > b.kills end)
	while #list > LB.SIZE do table.remove(list) end
	for i, e in ipairs(list) do e.rank = i end
	cache, cacheAt, refreshing = list, os.clock(), false
	return cache
end

-- Tabla de AMIGOS: tus amigos de Roblox (y tú) ordenados por su récord de kills. Caché de 2 min por jugador.
function LB.friends(player)
	local uid = player.UserId
	local c = friendCache[uid]
	if c and os.clock() - c.at < 120 then return c.list end
	local ids = { [uid] = true }
	pcall(function()
		local pages = Players:GetFriendsAsync(uid)
		local n = 0
		while n < 200 do
			for _, f in ipairs(pages:GetCurrentPage()) do
				ids[f.Id] = true; names[f.Id] = names[f.Id] or f.DisplayName or f.Username; n += 1
			end
			if pages.IsFinished then break end
			pages:AdvanceToNextPageAsync()
		end
	end)
	local list = {}
	if useMemory then
		for id in pairs(ids) do
			local r = memory[id]
			if r then table.insert(list, { userId = id, name = r.name, kills = r.kills, classId = r.classId }) end
		end
	else
		local b = getBest()
		local reads = 0
		for id in pairs(ids) do
			reads += 1
			if reads > 60 or not b then break end -- límite de lecturas por consulta
			local ok, v = pcall(function() return b:GetAsync(tostring(id)) end)
			if ok and type(v) == "number" then
				local k, cls = LB.decode(v)
				if k > 0 then table.insert(list, { userId = id, name = nameOf(id), kills = k, classId = cls }) end
			end
		end
	end
	table.sort(list, function(a, b) return a.kills > b.kills end)
	for i, e in ipairs(list) do e.rank = i end
	friendCache[uid] = { at = os.clock(), list = list }
	return list
end

function LB.invalidateFriends(player) friendCache[player.UserId] = nil end

-- ===== Tabla EN GRUPO (2026-11-02): runs cooperativas (2 a 4 jugadores) ordenadas por las kills de TODO el grupo =====
-- Clave = UserIds del grupo ordenados ("123_456_789"): se guarda el mejor total de ESE grupo (no se suma entre runs).
-- Publicado: OrderedDataStore "GroupRunKillsTop_v1" (total) + DataStore "GroupRunInfo_v1" (nombres y personajes)
-- + DataStore "GroupRunBest_v1" (mejor run en grupo de cada jugador, para el pie de la tabla). NO probado publicado.
LB.GROUP_TOP_STORE, LB.GROUP_INFO_STORE, LB.GROUP_BEST_STORE = "GroupRunKillsTop_v1", "GroupRunInfo_v1", "GroupRunBest_v1"
LB.GROUP_SIZE = 50
local groupMem = {}      -- [key] = { kills, names, classes, ids }
local groupBestMem = {}  -- [userId] = { kills, names }
local gCache, gCacheAt, gRefreshing = {}, -math.huge, false
local gTop, gInfo, gBest
local function ds(kind)
	local ok, s = pcall(function()
		if kind == "top" then return DataStoreService:GetOrderedDataStore(LB.GROUP_TOP_STORE) end
		return DataStoreService:GetDataStore(kind == "info" and LB.GROUP_INFO_STORE or LB.GROUP_BEST_STORE)
	end)
	return ok and s or nil
end

-- members = { { userId, name, kills, classId }, ... } (todos los del grupo, aunque alguno haya salido antes)
function LB.submitGroup(members)
	if type(members) ~= "table" or #members < 2 then return end
	local ids, names, classes, total = {}, {}, {}, 0
	table.sort(members, function(a, b) return (a.kills or 0) > (b.kills or 0) end)
	for _, m in ipairs(members) do
		total += math.max(0, math.floor(tonumber(m.kills) or 0))
		table.insert(ids, tostring(m.userId)); table.insert(names, tostring(m.name)); table.insert(classes, m.classId or "")
		names[#names] = names[#names]:sub(1, 20)

	end
	if total <= 0 then return end
	local sorted = table.clone(ids); table.sort(sorted)
	local key = table.concat(sorted, "_")
	local info = { kills = total, names = names, classes = classes, ids = ids }
	if useMemory then
		local cur = groupMem[key]
		if not cur or total > cur.kills then groupMem[key] = info end
		for _, id in ipairs(ids) do
			local uid = tonumber(id)
			if uid then
				local b = groupBestMem[uid]
				if not b or total > b.kills then groupBestMem[uid] = { kills = total, names = names } end
			end
		end
		gCacheAt = -math.huge
		return
	end
	task.spawn(function()
		local top, inf, best = gTop or ds("top"), gInfo or ds("info"), gBest or ds("best")
		gTop, gInfo, gBest = top, inf, best
		local improved = false
		if top then
			pcall(function()
				top:UpdateAsync(key, function(old)
					if type(old) == "number" and old >= total then return nil end
					improved = true
					return total
				end)
			end)
		end
		if improved and inf then pcall(function() inf:SetAsync(key, info) end) end
		if best then
			for _, id in ipairs(ids) do
				if tonumber(id) and tonumber(id) > 0 then
					pcall(function()
						best:UpdateAsync(id, function(old)
							if type(old) == "table" and (old.kills or 0) >= total then return nil end
							return { kills = total, names = names }
						end)
					end)
				end
			end
		end
		gCacheAt = -math.huge
	end)
end

-- Devuelve { { rank, key, kills, names = {...}, classes = {...}, ids = {...} }, ... } (máx. 50, caché de 60 s)
function LB.groupTop()
	if os.clock() - gCacheAt < LB.CACHE_SECONDS or gRefreshing then return gCache end
	gRefreshing = true
	local list = {}
	if useMemory then
		for key, r in pairs(groupMem) do table.insert(list, { key = key, kills = r.kills, names = r.names, classes = r.classes, ids = r.ids }) end
	else
		gTop = gTop or ds("top"); gInfo = gInfo or ds("info")
		if gTop then
			local ok, page = pcall(function() return gTop:GetSortedAsync(false, LB.GROUP_SIZE):GetCurrentPage() end)
			if not (ok and page) then gRefreshing = false; return gCache end
			for _, e in ipairs(page) do
				local info
				if gInfo then pcall(function() info = gInfo:GetAsync(e.key) end) end
				info = type(info) == "table" and info or {}
				table.insert(list, { key = e.key, kills = e.value, names = info.names or { "Grupo" }, classes = info.classes or {}, ids = info.ids or string.split(e.key, "_") })
			end
		end
	end
	table.sort(list, function(a, b) return a.kills > b.kills end)
	while #list > LB.GROUP_SIZE do table.remove(list) end
	for i, e in ipairs(list) do e.rank = i end
	gCache, gCacheAt, gRefreshing = list, os.clock(), false
	return gCache
end

-- mejor run en grupo de un jugador { kills, names } o nil
function LB.myGroupBest(player)
	if useMemory then return groupBestMem[player.UserId] end
	gBest = gBest or ds("best")
	if not gBest then return nil end
	local ok, v = pcall(function() return gBest:GetAsync(tostring(player.UserId)) end)
	return ok and type(v) == "table" and v or nil
end

return LB
