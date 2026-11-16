--!nonstrict
-- Fixed tier chances: completing easier tiers never increases the secret chance.
local Classes = require(game.ReplicatedStorage.GameShared.Catalogs.Classes)
local Reward = {}
local DEFAULT = { [1] = 0, [2] = 0, [3] = 60, [4] = 25, [5] = 10, [6] = 4, [7] = 0.99, [8] = 0.01 }
local weights = table.clone(DEFAULT)
-- Optional Experience Config JSON: RouletteCharacterTierWeights (keys "3" .. "8").
-- Bad/unavailable configs retain the published defaults. No yields in reward grants.
task.spawn(function()
	local ok, snapshot = pcall(function() return game:GetService("ConfigService"):GetConfigAsync() end)
	if not ok then return end
	local function read()
		local value = snapshot:GetValue("RouletteCharacterTierWeights")
		if type(value) == "string" then local success, decoded = pcall(game:GetService("HttpService").JSONDecode, game:GetService("HttpService"), value); value = success and decoded or nil end
		if type(value) ~= "table" then return end
		local nextWeights = table.clone(DEFAULT)
		for tier = 3, 8 do
			local w = tonumber(value[tostring(tier)] or value[tier])
			if not w or w < 0 or w > 100 or w ~= w then return end
			nextWeights[tier] = w
		end
		local sum = 0; for _, w in pairs(nextWeights) do sum += w end
		if math.abs(sum - 100) > 0.0001 then return end
		weights = nextWeights
	end
	pcall(read)
	snapshot.UpdateAvailable:Connect(function() pcall(function() snapshot:Refresh(); read() end) end)
end)
function Reward.tierChances() return table.clone(weights) end
function Reward.rollCharacter(owned, random)
	local roll = random:NextNumber(0, 100)
	local tier, cumulative = 8, 0
	for i = 3, 8 do cumulative += weights[i]; if roll < cumulative then tier = i; break end end
	local candidates = {}
	for _, class in ipairs(Classes.list) do
		if class.fixedTier == tier and not owned[class.id] then candidates[#candidates + 1] = class.id end
	end
	if #candidates == 0 then return nil, tier end
	return candidates[random:NextInteger(1, #candidates)], tier
end
return Reward
