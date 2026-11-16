
local Props=require(script.Parent.Props)
local M={}
function M.build(c)
 local hidden=c.mapId=="hidden";if not hidden and c.mapId~="desert" then return end
 local rng=c.rng;local O=c.origin;local H=c.half
 local dark=Color3.fromRGB(34,27,55);local glow=Color3.fromRGB(159,90,255)
 local sand=Color3.fromRGB(193,118,64)
 local function p(n,sz,pos,col,mat,rot,solid)
  return Props.mk(c.f,n,Enum.PartType.Block,sz,CFrame.new(O+pos)*(rot or CFrame.identity),col,mat,solid,false)
 end
 local function link(n,a,b,w,col)
  return p(n,Vector3.new(w,w,(a-b).Magnitude),(a+b)/2,col,Enum.Material.Neon,CFrame.lookAt(a,b).Rotation)
 end
 for side=0,3 do
  for i=0,19 do
   local u=-H+(i+.5)*H/10
   local cf=CFrame.Angles(0,side*math.pi/2,0)
   local at=cf*Vector3.new(u,0,-H-14)
   if hidden then
    local y=c.HM:get(at.X,at.Z)
    p("FracturedPlateEdge",Vector3.new(H/10+5,y+78,38),at+Vector3.new(0,(y-72)/2,0),dark,Enum.Material.Basalt,cf*CFrame.Angles(0,0,rng:number(-.08,.08)))
    local a=cf*Vector3.new(u-30,y+2,-H+1)
    local b=cf*Vector3.new(u+30,y+2,-H+1)
    -- y does not rotate about vertical
    link("VoidBoundarySeam",a,b,.65,glow)
    if i%3==0 then
     local q=cf*Vector3.new(u,y+20+rng:number(0,35),-H-65)
     p("FloatingObsidian",Vector3.new(25,40,22),q,dark,Enum.Material.Slate,CFrame.Angles(.3,i,.4))
     link("FloatingCrystalVein",q-Vector3.yAxis*12,q+Vector3.yAxis*12,.7,glow)
    end
   else
    local h=rng:number(90,155)
    for tier=0,3 do
     p("CanyonStrata",Vector3.new(H/10+14,32,95-tier*12),at+Vector3.new(0,-8+tier*h/4,0),sand:Lerp(Color3.fromRGB(239,185,111),tier/4),Enum.Material.Sandstone,cf)
    end
   end
   c.work(6)
  end
 end
 if hidden then
  p("FloatingPlateUnderside",Vector3.new(H*2,38,H*2),Vector3.new(0,-55,0),dark,Enum.Material.Basalt)
  for i=1,22 do
   local a=i*math.pi*2/22;local q=Vector3.new(math.cos(a)*(H+110),rng:number(-70,130),math.sin(a)*(H+110))
   p("OrbitingRuin",Vector3.new(35,12,50),q,dark,Enum.Material.Slate,CFrame.Angles(.3,a,.3))
  end
  local center=Vector3.new(-420,470,-720)
  local planet=Props.mk(c.f,"FracturedPlanet",Enum.PartType.Ball,Vector3.one*210,CFrame.new(O+center),Color3.fromRGB(53,38,95),Enum.Material.Slate,false,false)
  local tilt=CFrame.Angles(.5,0,.3)
  for i=0,63 do
   local a,b=i*math.pi/32,(i+1)*math.pi/32
   link("PlanetOrbitalRing",center+tilt*Vector3.new(math.cos(a)*155,0,math.sin(a)*155),center+tilt*Vector3.new(math.cos(b)*155,0,math.sin(b)*155),2.5,i%3==0 and Color3.fromRGB(91,216,255) or glow)
  end
  for i=1,150 do
   local a=rng:number(0,math.pi*2);local elevation=rng:number(.2,1.4);local rad=1100
   local q=Vector3.new(math.cos(a)*math.cos(elevation),math.sin(elevation),math.sin(a)*math.cos(elevation))*rad
   p("CosmicStar",Vector3.one*rng:number(.7,2),q,i%3==0 and Color3.fromRGB(105,185,255) or Color3.fromRGB(236,222,255),Enum.Material.Neon)
   if i%30==0 then c.work(35) end
  end
 else
  for tier=0,7 do
   p("BrokenPyramid",Vector3.new(170-tier*19,18,170-tier*19),Vector3.new(200,tier*18,-H-150),sand:Lerp(Color3.fromRGB(241,195,128),tier/10),Enum.Material.Sandstone,CFrame.Angles(0,.3,0))
  end
 end
end
function M.ruins(c)
 if c.mapId~="hidden" and c.mapId~="desert" then return end
 local hidden=c.mapId=="hidden"
 for i=1,25 do
  local x,z=c.rng:number(-c.half+90,c.half-90),c.rng:number(-c.half+90,c.half-90)
  if x*x+z*z>10000 and c.free(x,z,24,6) and not c.inWater(x,z,25) and c.HM:slope(x,z)<.18 and c.HM:pathDist(x,z)>38 then
   local yaw=c.rng:number(0,6.28);local base=CFrame.new(c.at(x,z))*CFrame.Angles(0,yaw,0)
   for j=-2,2 do
    local pos=base*Vector3.new(j*6,0,0)
    pos=Vector3.new(pos.X,c.at(pos.X-c.origin.X,pos.Z-c.origin.Z).Y,pos.Z)
    local h=c.rng:number(8,17)
    Props.mk(c.f,hidden and "ObsidianWall" or "BuriedSandstoneWall",nil,Vector3.new(6,h,4),CFrame.new(pos+Vector3.yAxis*h/2)*base.Rotation,hidden and Color3.fromRGB(40,31,57) or Color3.fromRGB(205,151,91),hidden and Enum.Material.Basalt or Enum.Material.Sandstone,true,true)
    c.addObs({x=pos.X-c.origin.X,z=pos.Z-c.origin.Z,r=4,height=h})
    if hidden then Props.mk(c.f,"VoidWallCrack",nil,Vector3.new(.18,h*.7,4.1),CFrame.new(pos+Vector3.yAxis*h*.5)*base.Rotation,Color3.fromRGB(156,76,239),Enum.Material.Neon,false,false) end
   end
   c.work(12)
  end
 end
end
return M
