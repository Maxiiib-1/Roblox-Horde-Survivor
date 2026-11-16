-- Carved forest boundary, built into the map's disposable Border layer.
local Props=require(script.Parent.Props)
local Forest={}
local stone=Color3.fromRGB(70,90,86)
local slate=Color3.fromRGB(43,62,66)
local bronze=Color3.fromRGB(170,142,88)
local moss=Color3.fromRGB(65,112,68)
local leaf=Color3.fromRGB(74,143,80)
local jade=Color3.fromRGB(99,195,152)
local block=Enum.PartType.Block
local rock=Enum.Material.Slate
local function mural(ctx,x,z,index,inward)
 local ground=ctx.at(x,z,0)
 local frame=CFrame.lookAt(ground,ground+inward)
 local height=31+(index%3)*3
 local function part(name,size,localCF,color,material,shape)
  return Props.mk(ctx.f,name,shape or block,size,frame*localCF,color,material,false,true)
 end
 local function line(name,a,b,width,color,material)
  return part(name,Vector3.new(width,width,(b-a).Magnitude+.2),CFrame.lookAt((a+b)/2,b),color,material)
 end
 for wing=-1,1 do
  local h=height-math.abs(wing)*6
  part("MuralStone",Vector3.new(17.8,h+9,5),CFrame.new(wing*18,h*.5-4,0),stone,rock)
  part("MossCoping",Vector3.new(19,1.2,5.8),CFrame.new(wing*18,h+.7,0),moss,Enum.Material.Grass)
  part("BasaltFooting",Vector3.new(19,5,6),CFrame.new(wing*18,1,0),slate,rock)
 end
 for _,u in {-27,-9,9,27} do
  local h=height-(math.abs(u)>20 and 6 or 0)
  part("MuralButtress",Vector3.new(2.5,h+7,6.4),CFrame.new(u,h/2-3,0),slate,rock)
 end
 local face=-2.8
 -- Sun medallion and a branching tree in raised mineral inlay.
 local sun=Vector3.new(0,height-6,face)
 for i=0,11 do
  local a,b=i*math.pi/6,(i+1)*math.pi/6
  line("SunInlay",sun+Vector3.new(math.sin(a)*3.3,math.cos(a)*3.3,0),sun+Vector3.new(math.sin(b)*3.3,math.cos(b)*3.3,0),.64,bronze,Enum.Material.Metal)
 end
 line("TreeRelief",Vector3.new(0,5,face),Vector3.new(0,height-11,face),1.15,jade,rock)
 for side=-1,1,2 do
  for k=0,2 do
   local root=Vector3.new(0,8+k*4,face)
   local joint=root+Vector3.new(side*(6-k),3,0)
   line("TreeRelief",root,joint,.85,jade,rock)
   line("TreeRelief",joint,joint+Vector3.new(side*2,3,0),.65,jade,rock)
  end
  for j=1,2 do
   local sx=side*(13+j*4)
   local start=Vector3.new(sx,height-5,-3.25)
   for k=1,5 do
    local tip=Vector3.new(sx+math.sin(index+j+k*.8)*1.8,height-5-k*(2.6+j*.55),-3.35)
    line("HangingVine",start,tip,.36,moss,Enum.Material.Wood)
    part("VineLeaf",Vector3.new(2.2,.44,1.05),CFrame.new(tip)*CFrame.Angles(0,.25,(-1)^k*.55),leaf,Enum.Material.Grass,Enum.PartType.Ball)
    start=tip
   end
  end
 end
 ctx.work(86)
end
function Forest.border(ctx)
 local outer=ctx.half+12
 local count=math.ceil(2*outer/52)
 local width=2*outer/count
 for side,inward in ipairs({Vector3.zAxis,-Vector3.xAxis,-Vector3.zAxis,Vector3.xAxis}) do
  for i=1,count do
   local along=-outer+(i-.5)*width
   local x=inward.X==0 and along or -inward.X*outer
   local z=inward.Z==0 and along or -inward.Z*outer
   local ground=ctx.at(x,z,0)
   local low,high=ground.Y,ground.Y
   for k=-4,4 do
    local off=width*k/8
    local y=ctx.at(x+(inward.X==0 and off or 0),z+(inward.Z==0 and off or 0),0).Y
    low=math.min(low,y);high=math.max(high,y)
   end
   local top=high+48+4*math.sin(i*.8+side)
   local height=top-low+16
   local crest=Vector3.new(ground.X,top,ground.Z)
   local frame=CFrame.lookAt(crest,crest+inward)
   local function p(name,size,cf,color,mat,shape)
    return Props.mk(ctx.f,name,shape or block,size,frame*cf,color,mat,false,true)
   end
   p("ForestCurtainWall",Vector3.new(width+.4,height,6),CFrame.new(0,-height/2,0),stone,rock)
   p("ForestWallCoping",Vector3.new(width+.4,1.4,7),CFrame.new(0,.6,0),moss,Enum.Material.Grass)
   p("ForestWallFrieze",Vector3.new(width+.2,.65,.4),CFrame.new(0,-3,-3.1),bronze,Enum.Material.Metal)
   p("ForestWallPier",Vector3.new(2.6,height+1,7.4),CFrame.new(-width/2,-height/2,0),slate,rock)
   local last=Vector3.new(width*.28,.7,-3.6)
   for k=1,5 do
    local tip=Vector3.new(width*.28+math.sin(k*.8+i)*2,.7-k*(3+i%3),-3.85)
    p("CurtainVine",Vector3.new(.56,.56,(last-tip).Magnitude+.1),CFrame.lookAt((last+tip)/2,tip),moss,Enum.Material.Wood)
    p("CurtainLeaf",Vector3.new(3,.8,.55),CFrame.new(tip)*CFrame.Angles(0,0,(-1)^k*.5),leaf,Enum.Material.Grass,Enum.PartType.Ball)
    last=tip
   end
   if i==math.ceil(count*.2) or i==math.ceil(count*.5) or i==math.ceil(count*.8) then
    mural(ctx,x+inward.X*3.9,z+inward.Z*3.9,side*count+i,inward)
   end
   ctx.work(15)
  end
 end
end
return Forest