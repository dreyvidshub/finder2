-- ZYNEX PET FINDER - independiente de Sodium Hub
-- Solo deteccion/lectura de datos y reportes. No contiene robo automatico.
-- Ejecutar en Delta despues de entrar al juego.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer
if not player then return end

local API_URL = "https://zynex-kf4o.onrender.com/reports"
local SCAN_SECONDS = 2
local REPORT_COOLDOWN = 30
local REPORT_REFRESH_SECONDS = 3
local KNOWN_EGGS = {
 {name="Royal Skywhale",rarity="Divine"},{name="ArchAngel",rarity="Divine"},{name="Pegasus",rarity="Eternal"},{name="World Burner",rarity="Divine"},{name="Nightflame",rarity="Divine"},{name="Kitsune",rarity="Divine"},{name="Unicorn",rarity="Divine"},
 {name="Celestial Sunlion",rarity="Eternal"},{name="Oni Tiger",rarity="Eternal"},{name="Gorilla King",rarity="Eternal"},{name="Lunar Dragon",rarity="Eternal"},{name="Mosasaurus",rarity="Eternal"},{name="El Maja",rarity="Eternal"},{name="Phoenix",rarity="Eternal"},{name="Lava Dragon",rarity="Eternal"},{name="Ice Dragon",rarity="Eternal"},
 {name="Gargoyle",rarity="Secret"},{name="Pure Jellyfish",rarity="Secret"},{name="TRex",rarity="Secret"},{name="Starry Fox",rarity="Secret"},{name="Mutant Shark",rarity="Secret"},{name="Stag",rarity="Secret"},{name="Cosmic Dragon",rarity="Secret"},{name="Cosmic Skeleton Boss",rarity="Secret"},{name="Kraken",rarity="Secret"},{name="Cerberus",rarity="Secret"},{name="Yeti",rarity="Secret"},{name="King Snake",rarity="Secret"}
}
local selectedFilter = "ALL"
local backendReports = {}
local lastReported, lastAnnouncement = {}, ""
local rows, currentFilter = {}, "TODOS"
local statusText = "Iniciando lector de datos..."

local C = {
 bg=Color3.fromRGB(16,12,22), panel=Color3.fromRGB(29,21,39), card=Color3.fromRGB(43,31,57),
 pink=Color3.fromRGB(244,79,170), white=Color3.fromRGB(248,242,255), muted=Color3.fromRGB(190,174,208),
 green=Color3.fromRGB(120,235,165), gold=Color3.fromRGB(255,205,100), red=Color3.fromRGB(255,105,120)
}
local function safeText(v) return tostring(v == nil and "?" or v) end
-- Convierte los anuncios enriquecidos de Roblox a texto simple antes de mostrarlos.
local function cleanMarkup(v)
 v=tostring(v or "")
 v=v:gsub("<[^>]->", "")
 v=v:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'")
 v=v:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
 return v
end
local function numberText(v)
 v=tonumber(v); if not v then return "No disponible" end
 if v>=1e9 then return string.format("%.2fB/s",v/1e9) end
 if v>=1e6 then return string.format("%.2fM/s",v/1e6) end
 if v>=1e3 then return string.format("%.2fK/s",v/1e3) end
 return string.format("%.2f/s",v)
end
local function reqFunction() return (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request) or request end
local function httpCall(url, method, body)
 local req=reqFunction(); if type(req)~="function" then return false,"Delta no expone una funcion HTTP" end
 local opt={Url=url,Method=method,Headers={ ["Content-Type"]="application/json", ["Accept"]="application/json" }}
 if body then opt.Body=HttpService:JSONEncode(body) end
 local ok,res=pcall(req,opt)
 if not ok or not res then return false,"Fallo HTTP" end
 local code=tonumber(res.StatusCode or res.Status or 200) or 200
 if code<200 or code>=300 then return false,"HTTP "..tostring(code).."" end
 return true,res.Body or res.body or "{}"
end

-- Acceso independiente a los modulos de datos del juego. Si Delta bloquea require,
-- el script lo informa y nunca inventa precio/peso.
local function findModule(path, name)
 local node=ReplicatedStorage
 for _,part in ipairs(path) do node=node and node:FindFirstChild(part) end
 if node and node:IsA("ModuleScript") then return node end
 for _,d in ipairs(ReplicatedStorage:GetDescendants()) do
  if d:IsA("ModuleScript") and d.Name==name then return d end
 end
 return nil
end
local function loadModule(path,name)
 local m=findModule(path,name); if not m then return nil,"No se encontro "..name end
 local ok,result=pcall(require,m)
 if ok and type(result)=="table" then return result end
 return nil,"Delta no pudo leer "..name
end
local EggState, eggStateErr=loadModule({"Client","EggState"},"EggState")
local AssetEarnings, earningsErr=loadModule({"Shared","Util","AssetEarnings"},"AssetEarnings")
local AssetsModule, assetsErr=loadModule({"Data","Assets"},"Assets")
local AssetsDir=AssetsModule and AssetsModule.Directory
local dataReady=EggState~=nil

local function calcRecord(rec)
 if type(rec)~="table" or not rec.AssetCategory then return nil end
 local dir=AssetsDir and AssetsDir[rec.AssetCategory]
 local name=(dir and dir.DisplayName) or tostring(rec.AssetCategory)
 local rarity=(dir and dir.Rarity and (dir.Rarity.DisplayName or dir.Rarity._id)) or "UNKNOWN"
 local base=dir and dir.Egg and tonumber(dir.Egg.WeightKg)
 local scale=tonumber(rec.AssetScale) or 1
 local kg=base and (base*scale) or nil
 local item={Category=rec.AssetCategory,Scale=scale,Mutations=rec.Mutations or {}}
 local income=nil
 if AssetEarnings then
  local ok,val=pcall(AssetEarnings.LiveRatePerSecond,item,nil,nil,player)
  if ok and type(val)=="number" then income=val else
   ok,val=pcall(AssetEarnings.MutationOnlyRatePerSecond,item)
   if ok and type(val)=="number" then income=val end
  end
 end
 return {name=name,rarity=tostring(rarity),weight=kg,income=income,uid=tostring(rec.Uid or ""),category=tostring(rec.AssetCategory),state=tostring(rec.State or "")}
end
local function getRecords()
 if not EggState or type(EggState.ReadFieldEggs)~="function" then return nil end
 local ok,data=pcall(EggState.ReadFieldEggs)
 if ok and type(data)=="table" and type(data.Records)=="table" then return data.Records end
 return nil
end
local function findMatchingRecord(name)
 local records=getRecords(); if not records then return nil end
 local target=string.lower(name or "")
 local best
 for _,rec in pairs(records) do
  local info=calcRecord(rec)
  if info then
   local n=string.lower(info.name)
   if n==target or (target~="" and (n:find(target,1,true) or target:find(n,1,true))) then
    if info.income~=nil or info.weight~=nil then best=info; break end
    best=best or info
   end
  end
 end
 return best
end

local gui=Instance.new("ScreenGui")
gui.Name="ZYNEX_PET_FINDER"
gui.ResetOnSpawn=false; gui.IgnoreGuiInset=true
pcall(function() gui.Parent=player:WaitForChild("PlayerGui") end)
if not gui.Parent then return end
local function make(class,props,parent)
 local o=Instance.new(class); for k,v in pairs(props or {}) do pcall(function() o[k]=v end) end; o.Parent=parent; return o
end
local function corner(o,r) make("UICorner",{CornerRadius=UDim.new(0,r or 9)},o) end
local function label(parent,text,size,color,bold)
 return make("TextLabel",{BackgroundTransparency=1,Text=text or "",TextSize=size or 12,TextColor3=color or C.white,Font=bold and Enum.Font.GothamBold or Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Center,TextWrapped=true},parent)
end
local function button(parent,text)
 local b=make("TextButton",{BackgroundColor3=C.card,Text=text,TextColor3=C.white,TextSize=11,Font=Enum.Font.GothamBold,AutoButtonColor=true},parent); corner(b,7); return b
end
local opener=button(gui,"ZYNEX",nil); opener.Size=UDim2.fromOffset(72,40); opener.Position=UDim2.new(0,10,.5,-20); opener.BackgroundColor3=C.pink
local main=make("Frame",{Name="Panel",Size=UDim2.new(.90,0,.76,0),Position=UDim2.new(.05,0,.12,0),BackgroundColor3=C.bg},gui); corner(main,11)
make("UIStroke",{Color=C.pink,Thickness=1.4,Transparency=.12},main)
make("UISizeConstraint",{MinSize=Vector2.new(280,300),MaxSize=Vector2.new(720,650)},main)
local header=make("Frame",{Size=UDim2.new(1,0,0,42),BackgroundColor3=C.panel},main); corner(header,10)
label(header,"👑 ZYNEX PET FINDER   •   BUSCANDO HUEVOS...",13,C.pink,true).Position=UDim2.new(0,12,0,0)
local close=button(header,"×"); close.Size=UDim2.fromOffset(26,24); close.Position=UDim2.new(1,-31,0,9)
local status=label(main,statusText,10,C.gold,true); status.Position=UDim2.new(0,10,0,44); status.Size=UDim2.new(1,-20,0,20)
local last=make("Frame",{Position=UDim2.new(0,8,0,60),Size=UDim2.new(1,-16,0,76),BackgroundColor3=C.panel},main); corner(last,9)
local lastTitle=label(last,"Esperando anuncio de huevo...",13,C.white,true); lastTitle.Position=UDim2.new(0,10,0,4); lastTitle.Size=UDim2.new(1,-20,0,23)
local lastDetails=label(last,"Ingreso: --  |  Peso: -- kg\nRareza: --\nZona: --",10,C.muted,false); lastDetails.Position=UDim2.new(0,10,0,28); lastDetails.Size=UDim2.new(1,-20,0,52)
local listTitle=label(main,"✦ REPORTES RECIENTES",10,C.pink,true)
listTitle.Text="✦ REPORTES RECIENTES • ACTUALIZA CADA 3 S"
listTitle.Position=UDim2.new(0,128,0,143)
listTitle.Size=UDim2.new(1,-138,0,22)
local list=make("ScrollingFrame",{Position=UDim2.new(0,8,0,174),Size=UDim2.new(1,-16,1,-221),BackgroundColor3=C.panel,BorderSizePixel=0,ScrollBarThickness=4,CanvasSize=UDim2.new(0,0,0,0)},main); corner(list,8)
local empty=label(list,"Todavia no se detectaron anuncios.",11,C.muted,false); empty.Position=UDim2.new(0,8,0,8); empty.Size=UDim2.new(1,-16,0,36)
local refresh=button(main,"REVISAR DATOS"); refresh.Text="REVISAR"; refresh.Size=UDim2.fromOffset(82,26); refresh.Position=UDim2.new(0,8,1,-32)
local test=button(main,"PROBAR API"); test.Text="API"; test.Size=UDim2.fromOffset(58,26); test.Position=UDim2.new(0,98,1,-32)
local hop=button(main,"SIGUIENTE SERVIDOR"); hop.Size=UDim2.fromOffset(126,26); hop.Position=UDim2.new(1,-134,1,-32); hop.BackgroundColor3=C.pink

-- Arrastrar con dedo o raton desde la barra superior
local dragging,dragInput,dragStart,startPos=false,nil,nil,nil
header.InputBegan:Connect(function(input)
 if input.UserInputType==Enum.UserInputType.Touch or input.UserInputType==Enum.UserInputType.MouseButton1 then
  dragging=true; dragStart=input.Position; startPos=main.Position
  input.Changed:Connect(function() if input.UserInputState==Enum.UserInputState.End then dragging=false end end)
 end
end)
header.InputChanged:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseMovement or input.UserInputType==Enum.UserInputType.Touch then dragInput=input end end)
UserInputService.InputChanged:Connect(function(input)
 if dragging and (input==dragInput or input.UserInputType==Enum.UserInputType.Touch or input.UserInputType==Enum.UserInputType.MouseMovement) and dragStart and startPos then
  local d=input.Position-dragStart; main.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y)
 end
end)
local function setStatus(txt,color) status.Text=txt; status.TextColor3=color or C.gold end
local TeleportService = game:GetService("TeleportService")
local function getPublicServer()
 local url="https://games.roblox.com/v1/games/"..tostring(game.PlaceId).."/servers/Public?sortOrder=Asc&limit=100&excludeFullGames=true"
 local req=reqFunction()
 if type(req)~="function" then return nil,"Delta no permite solicitudes HTTP" end
 local ok,res=pcall(req,{Url=url,Method="GET",Headers={ ["Accept"]="application/json" }})
 if not ok or not res then return nil,"No se pudo consultar la lista pública" end
 local code=tonumber(res.StatusCode or res.Status or 200) or 200
 if code<200 or code>=300 then return nil,"Lista pública: HTTP "..tostring(code) end
 local parsed,data=pcall(function() return HttpService:JSONDecode(res.Body or res.body or "{}") end)
 if not parsed or type(data)~="table" or type(data.data)~="table" then return nil,"Respuesta de servidores inválida" end
 for _,server in ipairs(data.data) do
  local sid=tostring(server.id or "")
  local playing=tonumber(server.playing) or 0
  local maxPlayers=tonumber(server.maxPlayers) or 0
  if sid~="" and sid~=game.JobId and (maxPlayers==0 or playing<maxPlayers) then return sid end
 end
 return nil,"No se encontró otro servidor disponible en la primera página"
end
hop.MouseButton1Click:Connect(function()
 hop.Active=false; hop.Text="BUSCANDO..."; setStatus("Buscando otro servidor público...",C.gold)
 task.spawn(function()
  local sid,err=getPublicServer()
  if not sid then setStatus(err or "No se encontró servidor",C.red); hop.Text="SIGUIENTE SERVIDOR"; hop.Active=true; return end
  setStatus("Entrando a otro servidor... Auto Execute debe volver a cargar el detector",C.green)
  local ok,why=pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId,sid,player) end)
  if not ok then setStatus("No se pudo teletransportar: "..tostring(why),C.red); hop.Text="SIGUIENTE SERVIDOR"; hop.Active=true end
 end)
end)

local function renderRows()
 for _,child in ipairs(list:GetChildren()) do if child~=empty then child:Destroy() end end
 local display={}
 for _,r in ipairs(rows) do if selectedFilter=="ALL" or string.upper(tostring(r.rarity or "")):find(selectedFilter,1,true) then table.insert(display,r) end end
 for _,r in ipairs(backendReports) do if selectedFilter=="ALL" or string.upper(tostring(r.rarity or "")):find(selectedFilter,1,true) then table.insert(display,r) end end
 empty.Visible=(#display==0); if #display==0 then empty.Text="Esperando huevos o reportes del servicio..."; list.CanvasSize=UDim2.new(0,0,0,50); return end
 local y=6
 for i=1,math.min(#display,25) do
  local r=display[i]; local fromApi=r._backend==true
  local card=make("Frame",{Position=UDim2.new(0,5,0,y),Size=UDim2.new(1,-10,0,fromApi and 77 or 59),BackgroundColor3=C.card},list); corner(card,6)
  local title=label(card,tostring(r.name or "Huevo detectado").."  •  "..string.upper(tostring(r.rarity or "?")),10,C.pink,true); title.Position=UDim2.new(0,7,0,2); title.Size=UDim2.new(1,-14,0,19)
  local weight=r.weight_kg or r.weight; local income=r.income_per_second or r.income
  local details=label(card,"Peso: "..(weight and (string.format("%.2f",tonumber(weight) or 0).." kg") or "?").."  |  Ingreso: "..(income and numberText(income) or "?").."\nZona: "..tostring(r.area or "?").."  •  "..(fromApi and "REPORTE" or "EN ESTE SERVIDOR"),9,C.white,false); details.Position=UDim2.new(0,7,0,21); details.Size=UDim2.new(1,-14,0,30)
  if fromApi then
   local join=button(card,"JOIN ↗"); join.Size=UDim2.fromOffset(62,22); join.Position=UDim2.new(1,-69,1,-25); join.TextSize=9
   join.MouseButton1Click:Connect(function()
    local sid=tostring(r.server_id or "")
    if sid=="" or sid=="no ID" or sid=="backend-test" then setStatus("Este reporte no tiene un servidor válido",C.gold); return end
    local ok,err=pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId,sid,player) end)
    if not ok then setStatus("Roblox no permitió entrar a esa instancia",C.red) else setStatus("Intentando entrar al servidor...",C.green) end
   end)
  end
  y=y+(fromApi and 83 or 65)
 end
 list.CanvasSize=UDim2.new(0,0,0,y+4)
end
local function validRecentReport(r)
 if type(r)~="table" then return false end
 local name=tostring(r.name or "")
 local rarity=string.lower(tostring(r.rarity or ""))
 local lowerName=string.lower(name)
 -- Excluir nombres de piezas/modelos del mapa y reportes sin datos medibles.
 if lowerName=="" or lowerName:find("meshes/",1,true) or lowerName:find("models for egg",1,true)
  or lowerName:find("firstareaegg",1,true) or lowerName:find("slot_",1,true)
  or rarity=="unknown" or rarity=="" then return false end
 local weight=tonumber(r.weight_kg or r.weight)
 local income=tonumber(r.income_per_second or r.income)
 if not weight and not income then return false end
 if not (rarity:find("secret",1,true) or rarity:find("divine",1,true) or rarity:find("eternal",1,true)) then return false end
 -- Mostrar solo reportes de los últimos 10 minutos.
 local stamp=tostring(r.created_at or "")
 local y,mo,d,h,mi,se=stamp:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
 if not y then return false end
 local ok,epoch=pcall(function() return os.time({year=tonumber(y),month=tonumber(mo),day=tonumber(d),hour=tonumber(h),min=tonumber(mi),sec=tonumber(se),isdst=false}) end)
 if not ok or not epoch then return false end
 local age=os.time()-epoch
 -- API timestamps are UTC; adjust local timezone offset when parsing local time.
 local utcNow=os.date("!*t")
 local localNow=os.date("*t")
 local offset=os.difftime(os.time(localNow),os.time(utcNow))
 age=age+offset
 return age>=-120 and age<=600
end
local function fetchReports()
 local ok,body=httpCall(API_URL,"GET")
 if not ok then setStatus("Detector activo • reportes no disponibles",C.gold); return end
 local parsed,data=pcall(function() return HttpService:JSONDecode(body) end)
 if not parsed then setStatus("Respuesta de reportes inválida",C.gold); return end
 local arr=data.reports or data
 if type(arr)~="table" then arr={} end
 backendReports={}
 for _,r in ipairs(arr) do
  if validRecentReport(r) then r._backend=true; table.insert(backendReports,r) end
 end
 table.sort(backendReports,function(a,b) return tostring(a.created_at or "")>tostring(b.created_at or "") end)
 while #backendReports>20 do table.remove(backendReports) end
 setStatus("SERVICIO CONECTADO • "..#backendReports.." RECIENTES",C.green)
 renderRows()
end

local filterBtn=button(main,"TODOS • FILTRO"); filterBtn.Size=UDim2.fromOffset(112,26); filterBtn.Position=UDim2.new(0,8,0,140)
filterBtn.MouseButton1Click:Connect(function() local opts={"ALL","SECRET","DIVINE","ETERNAL"}; local at=1; for i,v in ipairs(opts) do if v==selectedFilter then at=i end end; selectedFilter=opts[at%#opts+1]; filterBtn.Text=selectedFilter=="ALL" and "TODOS • FILTRO" or selectedFilter; renderRows() end)
local function postReport(info,area)
 if not info or not info.name then return false,"Sin datos del huevo" end
 if info.income==nil and info.weight==nil then return false,"Datos reales incompletos; no se envia reporte" end
 local now=os.time(); local key=string.lower(info.name).."|"..tostring(info.uid)
 if lastReported[key] and now-lastReported[key]<REPORT_COOLDOWN then return true,"Ya reportado recientemente" end
 local payload={name=info.name,rarity=info.rarity or "UNKNOWN",weight=info.weight,income=info.income,server_id=game.JobId,area=area}
 local ok,result=httpCall(API_URL,"POST",payload)
 if ok then lastReported[key]=now; return true,"Reporte enviado al backend" end
 return false,result
end
local function onAnnouncement(message,source)
 if type(message)~="string" then return end
 local lower=string.lower(message)
 if not (lower:find("ha aparecido",1,true) or lower:find("has appeared",1,true) or lower:find("appeared",1,true) or lower:find("spawned",1,true)) then return end
 if #message<8 or message==lastAnnouncement then return end
 lastAnnouncement=message
 local eggName=message
 eggName=eggName:gsub("^[^:]+:%s*","")
 eggName=eggName:gsub("^[%p%s]+","")
 eggName=eggName:gsub("^[Aa]%s+","")
 eggName=eggName:gsub("[!%.%?]+$","")
 eggName=eggName:gsub("[Hh]a aparecido%s+","")
 eggName=eggName:gsub("[Hh]as appeared%s+","")
 eggName=eggName:gsub("[Aa]ppeared%s+","")
 eggName=eggName:gsub("[Ss]pawned%s+","")
 eggName=eggName:gsub("%s+en%s+.+$","")
 eggName=eggName:gsub("%s+in%s+.+$","")
 eggName=eggName:gsub("%s+at%s+.+$","")
 eggName=eggName:gsub("%s+🌌.*$","")
 eggName=eggName:gsub("^%s+",""):gsub("%s+$","")
 local announcedRarity, knownName
 local lowerEgg=string.lower(eggName)
 for _,entry in ipairs(KNOWN_EGGS) do
  if lowerEgg:find(string.lower(entry.name),1,true) then knownName=entry.name; break end
 end
 local rarityWord=lowerEgg:match("(divine)") or lowerEgg:match("(eternal)") or lowerEgg:match("(secret)")
 if rarityWord then announcedRarity=rarityWord:sub(1,1):upper()..rarityWord:sub(2) end
 local info=findMatchingRecord(knownName or eggName)
 if not info and knownName then
  -- Aun sin registro local, mostrar el anuncio conocido sin inventar peso ni ingreso.
  info={name=knownName,rarity=announcedRarity or "UNKNOWN",weight=nil,income=nil,uid="announcement:"..knownName}
 end
 if info and announcedRarity then info.rarity=announcedRarity end
 local area=message:match("%s+en%s+(.+)$") or message:match("%s+in%s+(.+)$") or "No identificada"
 area=cleanMarkup(area):gsub("[!%.%?]+$", "")
 if info then
  lastTitle.Text=info.name
  lastDetails.Text="Ingreso: "..(info.income and numberText(info.income) or "No disponible").."  |  Peso: "..(info.weight and string.format("%.2f kg",info.weight) or "No disponible").."\nRareza: "..safeText(info.rarity).."\nZona: "..area
  info.area=area; table.insert(rows,1,info); while #rows>30 do table.remove(rows) end; renderRows()
  local ok,msg=postReport(info,area)
  setStatus("Anuncio detectado • "..msg,ok and C.green or C.gold)
 else
  lastTitle.Text=eggName~="" and eggName or "Anuncio detectado"
  lastDetails.Text="Datos del juego no coinciden con un registro local.\nIngreso: NO DISPONIBLE  |  Peso: NO DISPONIBLE\nZona: "..area
  setStatus("Anuncio detectado; sin registro verificable en datos locales",C.gold)
  table.insert(rows,1,{name=lastTitle.Text,rarity="?",area=area}); while #rows>30 do table.remove(rows) end; renderRows()
 end
end

local function checkData()
 local records=getRecords()
 if records then
  local n=0; for _,r in pairs(records) do if r.AssetCategory then n=n+1 end end
  setStatus("Lector activo • "..n.." registros del juego • sin robo automatico",C.green)
 else
  setStatus("No se pudo leer EggState: "..safeText(eggStateErr or earningsErr or assetsErr),C.gold)
 end
end
refresh.MouseButton1Click:Connect(checkData)
test.MouseButton1Click:Connect(function()
 local ok,res=httpCall("https://zynex-kf4o.onrender.com/","GET")
 if ok then setStatus("API online • "..tostring(res):sub(1,100),C.green) else setStatus("API no accesible: "..tostring(res),C.red) end
end)
close.MouseButton1Click:Connect(function() main.Visible=false; opener.Visible=true end)
opener.MouseButton1Click:Connect(function() main.Visible=true; opener.Visible=false end)
opener.Visible=false

-- Anuncios de TextChatService y chat clasico
pcall(function()
 TextChatService.MessageReceived:Connect(function(msg)
  local textValue=msg.Text
  if textValue then onAnnouncement(textValue,"TextChatService") end
 end)
end)
for _,plr in ipairs(Players:GetPlayers()) do
 plr.Chatted:Connect(function(msg) onAnnouncement(msg,"Chatted") end)
end
Players.PlayerAdded:Connect(function(plr) plr.Chatted:Connect(function(msg) onAnnouncement(msg,"Chatted") end) end)
checkData()
task.spawn(function() while gui.Parent do task.wait(REPORT_REFRESH_SECONDS); if main.Visible then fetchReports() end end end)
fetchReports()
print("ZYNEX PET FINDER cargado. Independiente de Sodium Hub; no ejecuta robo automatico.")
task.spawn(function()
 while gui.Parent do task.wait(SCAN_SECONDS); if main.Visible then
  if dataReady then
   local records=getRecords()
   if not records then setStatus("Lector activo; esperando datos del juego",C.gold) end
  end
 end end
end)
