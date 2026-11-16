--!nonstrict
local Players=game:GetService("Players")
local Market=game:GetService("MarketplaceService")
local Policy=game:GetService("PolicyService")
local Shared=game.ReplicatedStorage.GameShared
local Config=require(Shared.Config.CommerceConfig)
local Profile=require(script.Parent.Parent.Persistence.ProfileService)
local Shop=require(Shared.Util.ShopRotation)
local Pets=require(Shared.Catalogs.Pets)
local Classes=require(Shared.Catalogs.Classes)
local Names=require(Shared.Catalogs.ClassPresentationRegistry)
local Skins=require(script.Parent.RouletteRewards)
local C={}; local remotes; local policies={}; local locks={}; local last={}
function C.canRandom(player)
 if policies[player] ~= nil then return policies[player] end
 local ok,p=pcall(Policy.GetPolicyInfoForPlayerAsync,Policy,player)
 if not ok then return false end
 policies[player]=p.ArePaidRandomItemsRestricted == false
 return policies[player]
end
function C.refreshVIP(player)
 if Config.VIP.id <= 0 then player:SetAttribute("RobuxVIP",false); return end
 local ok,owns=pcall(Market.UserOwnsGamePassAsync,Market,player.UserId,Config.VIP.id)
 if ok then player:SetAttribute("RobuxVIP",owns) end
end
local function odds(offer,d)
 local lines={}
 local function line(name,chance) table.insert(lines,string.format("%s: %.6g%%",name,chance)) end
 local function egg(id,scale)
  for _,p in ipairs(Pets.list) do local ch=Pets.chance(id,p.id); if ch>0 then line(p.name,ch*100*scale) end end
 end
 if offer.kind=="egg" then egg(offer.egg,1)
 elseif offer.kind=="weapon" or offer.kind=="tome" then
  local list=offer.kind=="weapon" and Shop.weaponList or Shop.tomeList
  local owned=offer.kind=="weapon" and d.ownedWeapons or d.ownedTomes
  local cat=require(offer.kind=="weapon" and Shared.Catalogs.Weapons or Shared.Catalogs.Tomes)
  local missing={}; for _,e in ipairs(list) do if not owned[e.id] then table.insert(missing,e.id) end end
  for _,id in ipairs(missing) do line(cat.byId[id].name,100/#missing) end
  if #missing==0 then line("Colección completa: 1.000 plata",100) end
 elseif offer.kind=="spin" then
  local total=0; for _,s in ipairs(Pets.wheel) do total+=s.weight end
  for _,s in ipairs(Pets.wheel) do
   local chance=s.weight/total*100; line(s.name,chance)
   if s.kind=="egg" then egg(s.egg,chance/100)
   elseif s.kind=="character" then
    for tier,weight in pairs(Skins.tierChances()) do
     local pool={}; for _,c in ipairs(Classes.list) do if c.fixedTier==tier and not d.unlockedClasses[c.id] then table.insert(pool,c) end end
     if #pool==0 and weight>0 then line("Rareza "..tier.." completa: 300 plata",chance*weight/100) end
     for _,c in ipairs(pool) do line((Names[c.id] or {}).name or c.id,chance*weight/100/#pool) end
    end
   elseif s.kind=="skin" then
    local mine,others={},{}
    for _,c in ipairs(Classes.list) do
     if not d.rouletteExclusive and not ((d.classProgress[c.id] or {}).rouletteExclusive) then table.insert(d.unlockedClasses[c.id] and mine or others,c.id) end
    end
    local pool=#mine>0 and mine or others
    if #pool==0 then line("Todas las skins: 1.000 plata",chance) end
    for _,id in ipairs(pool) do line("Skin de "..((Names[id] or {}).name or id),chance/#pool) end
   end
  end
  table.insert(lines,"Inventario de huevos lleno: el huevo se cambia por 300 plata. Las probabilidades se actualizan según tu colección al girar.")
 end
 return table.concat(lines,"\n")
end
function C.init(r)
 remotes=r
 local remote=Instance.new("RemoteFunction"); remote.Name="RobuxShop"; remote.Parent=Shared.Network
 remote.OnServerInvoke=function(player,action,key)
  if type(key)~="string" or #key>60 or (action~="info" and action~="buy") then return {error="Solicitud inválida."} end
  local now=os.clock(); if last[player] and now-last[player]<0.3 then return {error="Esperá un momento."} end; last[player]=now
  local o=key=="vip" and Config.VIP or Config.products[key]
  local rec=Profile.get(player); if not o or not rec then return {error="Tu perfil todavía no está listo."} end
  if o.random and not C.canRandom(player) then return {error="Esta compra aleatoria no está disponible para tu cuenta."} end
  local owned=o.kind=="class" and rec.data.unlockedClasses[o.classId] or o.kind=="vip" and player:GetAttribute("RobuxVIP")
  if owned then return {error="Ya lo tenés."} end
  if action=="info" then return {name=o.name,description=o.description,odds=odds(o,rec.data),id=o.id,kind=o.kind} end
  if o.id<=0 then return {error="Próximamente: esta compra todavía no está habilitada."} end
  local ok=pcall(function()
   if o.kind=="vip" then Market:PromptGamePassPurchase(player,o.id) else Market:PromptProductPurchase(player,o.id) end
  end)
  return ok and {ok=true} or {error="Roblox no pudo abrir la compra. Intentá de nuevo."}
 end
 Market.ProcessReceipt=function(receipt)
  local player=Players:GetPlayerByUserId(receipt.PlayerId)
  if not player or locks[player] then return Enum.ProductPurchaseDecision.NotProcessedYet end
  local offer
  for _,o in pairs(Config.products) do if o.id>0 and o.id==receipt.ProductId then offer=o; break end end
  if not offer then return Enum.ProductPurchaseDecision.NotProcessedYet end
  locks[player]=true
  local ok,saved,result=pcall(Profile.grantRobux,player,tostring(receipt.PurchaseId),offer)
  locks[player]=nil
  if not ok or not saved then return Enum.ProductPurchaseDecision.NotProcessedYet end
  if player.Parent then
   remotes.ProfileData:FireClient(player,Profile.publicData(player))
   remotes.Toast:FireClient(player,{text="Compra entregada: "..offer.name..(result.id and (" · "..result.id) or "")})
  end
  return Enum.ProductPurchaseDecision.PurchaseGranted
 end
 Market.PromptGamePassPurchaseFinished:Connect(function(player,id,purchased)
  if id==Config.VIP.id and purchased then
   C.refreshVIP(player)
   remotes.ProfileData:FireClient(player,Profile.publicData(player))
   remotes.Toast:FireClient(player,{text="VIP adquirido. Tus bonus se aplican desde la próxima partida."})
  end
 end)
 Players.PlayerRemoving:Connect(function(p) policies[p]=nil;last[p]=nil;locks[p]=nil end)
end
return C