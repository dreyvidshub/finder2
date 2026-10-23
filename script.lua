--[[
    DREYVID HUB · DETECTOR  (ESCÁNER EN VIVO)
    ---------------------------------------------------------------
    Lado "detector" del hub. Escanea el servidor en tiempo real y manda lo que
    encuentra al PANEL:
      1) canal directo _G.DreyvidAddReport  -> tarjeta instantánea (<0.1 s)
      2) backend público (POST /reports)     -> para otros jugadores

    Fuentes de escaneo (en orden):
      - RemoteFunction "RF/EggWorld/AskFieldEggSnapshot" (snapshot del servidor)
      - Client.EggState.ReadFieldEggs() (fallback)
      - anuncios del chat (solo como aviso visual, nunca inventa datos)

    - Archivo independiente del panel a propósito.
    - Diseño: azul con bordes blancos (distinto al panel).
    - Lee imágenes reales de los pets: Data.Assets.Directory[cat].Icon
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer
if not player then return end

local CONFIG = {
    API_URL        = "https://zynex-kf4o.onrender.com", -- cámbialo si usas backend privado
    API_KEY        = "",                                -- token opcional (backend privado)
    SCAN_INTERVAL  = 0.75,  -- s entre escaneos (más bajo = más rápido)
    POST_COOLDOWN  = 180,   -- s para no repetir el mismo huevo al backend
    MAX_PER_SCAN   = 6,     -- huevos nuevos que reporta por escaneo
    MIN_INCOME     = 0,     -- 0 = reportar todos los raros
    RARITIES       = { SECRET = true, DIVINE = true, ETERNAL = true },
    MAX_RECENT     = 12,
    EXPECTED_PLACE = 107778070777162, -- "Steal an Egg"
}

---------------------------------------------------------------
-- 1. LIMPIAR VERSIONES ANTERIORES (solo del detector)
---------------------------------------------------------------
local OLD_NAMES = { "ZYNEX_PET_FINDER", "DreyvidHubDetector", "DreyvidDetector" }
do
    local targets = {}
    pcall(function() table.insert(targets, game:GetService("CoreGui")) end)
    pcall(function() table.insert(targets, player:WaitForChild("PlayerGui", 10)) end)
    pcall(function() if gethui then table.insert(targets, gethui()) end end)
    for _, parent in ipairs(targets) do
        if parent then
            for _, name in ipairs(OLD_NAMES) do
                local ok, old = pcall(function() return parent:FindFirstChild(name) end)
                if ok and old then pcall(function() old:Destroy() end) end
            end
        end
    end
end

---------------------------------------------------------------
-- 2. PALETA AZUL + BORDES BLANCOS
---------------------------------------------------------------
local C = {
    bg      = Color3.fromRGB(6, 15, 27),
    bg2     = Color3.fromRGB(10, 25, 43),
    panel   = Color3.fromRGB(12, 32, 55),
    card    = Color3.fromRGB(15, 40, 67),
    cardH   = Color3.fromRGB(21, 53, 86),
    accent  = Color3.fromRGB(46, 156, 255),
    accent2 = Color3.fromRGB(126, 212, 255),
    ice     = Color3.fromRGB(205, 236, 255),
    white   = Color3.fromRGB(255, 255, 255),
    gray    = Color3.fromRGB(152, 183, 213),
    dim     = Color3.fromRGB(92, 124, 155),
    red     = Color3.fromRGB(255, 94, 114),
    green   = Color3.fromRGB(70, 236, 158),
    gold    = Color3.fromRGB(255, 205, 95),
    purple  = Color3.fromRGB(172, 132, 255),
    blue    = Color3.fromRGB(82, 152, 255),
}
local NEON = ColorSequence.new({
    ColorSequenceKeypoint.new(0.0, Color3.fromRGB(0, 120, 255)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(126, 212, 255)),
    ColorSequenceKeypoint.new(1.0, Color3.fromRGB(0, 120, 255)),
})

---------------------------------------------------------------
-- 3. HELPERS DE UI
---------------------------------------------------------------
local function N(class, props)
    local obj = Instance.new(class)
    for k, v in pairs(props or {}) do
        if k ~= "Parent" then pcall(function() obj[k] = v end) end
    end
    if props and props.Parent then obj.Parent = props.Parent end
    return obj
end
local function Corner(parent, r) return N("UICorner", { CornerRadius = UDim.new(0, r or 8), Parent = parent }) end
local function Stroke(parent, color, thickness, transparency)
    return N("UIStroke", {
        Color = color or C.white, Thickness = thickness or 1,
        Transparency = transparency or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Parent = parent,
    })
end
local function Tw(obj, duration, props, style, dir)
    local ok, tw = pcall(function()
        return TweenService:Create(obj, TweenInfo.new(duration or 0.2, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
    end)
    if ok and tw then tw:Play() return tw end
    return nil
end
local function PressFX(btn)
    local scale = N("UIScale", { Scale = 1, Parent = btn })
    btn.MouseButton1Down:Connect(function() Tw(scale, 0.12, { Scale = 0.93 }, Enum.EasingStyle.Quad) end)
    local function back() Tw(scale, 0.18, { Scale = 1 }, Enum.EasingStyle.Back) end
    btn.MouseButton1Up:Connect(back)
    btn.MouseLeave:Connect(back)
end

---------------------------------------------------------------
-- 4. DATOS DEL JUEGO
---------------------------------------------------------------
local catalog, areas, earningsModule, eggStateModule
local nameIndex = {}
local iconCache = {}
local snapshotRemote
local dataErrors = {}

local function iconUrlOf(entry)
    if type(entry) ~= "table" then return "" end
    local icon = entry.Icon or entry.Image or entry.ImageId or entry.AssetId or entry.Thumbnail
    if type(icon) == "number" then return "rbxassetid://" .. tostring(icon) end
    if type(icon) == "string" and icon ~= "" then
        if icon:find("rbxasset", 1, true) then return icon end
        if tonumber(icon) then return "rbxassetid://" .. icon end
        return icon
    end
    return ""
end

local function normalizeRarity(value)
    local s = string.upper(tostring(value or ""))
    if s:find("SECRET", 1, true) then return "SECRET" end
    if s:find("DIVIN", 1, true) then return "DIVINE" end
    if s:find("ETERN", 1, true) then return "ETERNAL" end
    return "UNKNOWN"
end
local function rarityColor(rarity)
    if rarity == "DIVINE" then return C.gold end
    if rarity == "ETERNAL" then return C.purple end
    if rarity == "SECRET" then return C.blue end
    return C.accent
end
local function rarityLabel(rarity)
    if rarity == "DIVINE" then return "DIVINO" end
    if rarity == "ETERNAL" then return "ETERNAL" end
    if rarity == "SECRET" then return "SECRETO" end
    return "?"
end
local function fmtMoney(value)
    local v = tonumber(value)
    if not v then return "—" end
    if v >= 1e12 then return string.format("%.2fT/s", v / 1e12) end
    if v >= 1e9 then return string.format("%.2fB/s", v / 1e9) end
    if v >= 1e6 then return string.format("%.2fM/s", v / 1e6) end
    if v >= 1e3 then return string.format("%.1fK/s", v / 1e3) end
    return string.format("%.0f/s", v)
end
local function fmtWeight(value)
    local v = tonumber(value)
    if not v then return "—" end
    return string.format("%.2f kg", v)
end
local function timeAgo(epoch)
    if type(epoch) ~= "number" then return "" end
    local diff = os.time() - epoch
    if diff < 45 then return "ahora" end
    if diff < 3600 then return math.floor(diff / 60) .. "m" end
    if diff < 86400 then return math.floor(diff / 3600) .. "h" end
    return math.floor(diff / 86400) .. "d"
end

local function loadGameData()
    if not catalog then
        local ok = pcall(function()
            local mod = require(ReplicatedStorage.Data.Assets)
            local dir = (type(mod) == "table") and (mod.Directory or mod) or nil
            if type(dir) == "table" then
                catalog = dir
                for _, entry in pairs(dir) do
                    if type(entry) == "table" then
                        local disp = entry.DisplayName or entry._id
                        if disp ~= nil then nameIndex[string.lower(tostring(disp))] = entry end
                    end
                end
            end
        end)
        if not ok then dataErrors.assets = true end
    end
    if not areas then
        local ok = pcall(function()
            local mod = require(ReplicatedStorage.Data.Areas)
            local dir = (type(mod) == "table") and (mod.Directory or mod) or nil
            if type(dir) == "table" then areas = dir end
        end)
        if not ok then dataErrors.areas = true end
    end
    if not earningsModule then
        pcall(function()
            local mod = require(ReplicatedStorage.Shared.Util.AssetEarnings)
            if type(mod) == "table" then earningsModule = mod end
        end)
    end
    if not eggStateModule then
        pcall(function()
            local mod = require(ReplicatedStorage.Client.EggState)
            if type(mod) == "table" then eggStateModule = mod end
        end)
    end
end

local function findSnapshotRemote()
    if snapshotRemote and snapshotRemote.Parent then return snapshotRemote end
    pcall(function()
        local packages = ReplicatedStorage:FindFirstChild("Packages")
        local networking = packages and packages:FindFirstChild("Networking")
        local direct = networking and networking:FindFirstChild("RF/EggWorld/AskFieldEggSnapshot")
        if direct and direct:IsA("RemoteFunction") then snapshotRemote = direct end
    end)
    if snapshotRemote then return snapshotRemote end
    pcall(function()
        for _, inst in ipairs(ReplicatedStorage:GetDescendants()) do
            if inst:IsA("RemoteFunction") then
                local normalized = string.lower(inst.Name):gsub("[^%w]", "")
                if normalized:find("askfieldeggsnapshot", 1, true) then
                    snapshotRemote = inst
                    return
                end
            end
        end
    end)
    return snapshotRemote
end

local areaCache = {}
local function areaName(areaId)
    if areaId == nil then return "" end
    local id = tostring(areaId)
    if areaCache[id] ~= nil then return areaCache[id] end
    local name = ""
    if type(areas) == "table" then
        local entry = areas[id]
        if type(entry) ~= "table" then
            local target = string.lower(id)
            for key, value in pairs(areas) do
                if string.lower(tostring(key)) == target and type(value) == "table" then
                    entry = value
                    break
                end
            end
        end
        if type(entry) == "table" then
            local display = entry.DisplayName or entry.Name or entry._id or id
            local emoji = entry.Emoji and tostring(entry.Emoji) or ""
            name = tostring(display) .. emoji
        end
    end
    if name == "" then name = id end
    areaCache[id] = name
    return name
end

local function readRecords()
    local remote = findSnapshotRemote()
    if remote then
        local ok, snapshot = pcall(function() return remote:InvokeServer() end)
        if ok and type(snapshot) == "table" then
            local records = snapshot.Records or snapshot
            if type(records) == "table" then return records, "SNAPSHOT" end
        end
    end
    if eggStateModule and type(eggStateModule.ReadFieldEggs) == "function" then
        local ok, result = pcall(eggStateModule.ReadFieldEggs)
        if not ok then ok, result = pcall(function() return eggStateModule:ReadFieldEggs() end) end
        if ok and type(result) == "table" then
            local records = result.Records or result
            if type(records) == "table" then return records, "EGGSTATE" end
        end
    end
    return nil, nil
end

local function buildInfo(record, key)
    if type(record) ~= "table" then return nil end
    local category = record.AssetCategory or record.assetCategory or record.Asset or record.Category
    if category == nil then return nil end
    local entry = (catalog and catalog[tostring(category)]) or nil
    local name = (type(entry) == "table" and (entry.DisplayName or entry._id)) or tostring(category)

    local rarity = normalizeRarity(record.assetRarity or record.Rarity
        or (type(entry) == "table" and entry.Rarity and (entry.Rarity.DisplayName or entry.Rarity._id)))
    if not CONFIG.RARITIES[rarity] then return nil end

    local scale = tonumber(record.AssetScale) or 1
    local weight = tonumber(record.Weight or record.WeightKg or record.weight or record.weight_kg)
    if not weight and type(entry) == "table" then
        local base = entry.Egg and tonumber(entry.Egg.WeightKg)
        if not base then base = tonumber(entry.WeightKg) end
        if base then weight = base * scale end
    end

    local income
    if earningsModule then
        local item = { Category = category, Scale = scale, Mutations = record.Mutations or {} }
        local ok, value = pcall(function() return earningsModule.LiveRatePerSecond(item, nil, nil, player) end)
        if ok and type(value) == "number" then income = value end
        if not income then
            local ok2, value2 = pcall(function() return earningsModule.MutationOnlyRatePerSecond(item) end)
            if ok2 and type(value2) == "number" then income = value2 end
        end
    end
    if not income and type(entry) == "table" then
        local rate = tonumber(entry.EarningRate or entry.Earning or entry.IncomeRate)
        if rate then
            local mutations = record.Mutations
            local bonus = 1 + (((type(mutations) == "table" and #mutations) or 0) * 0.25)
            income = rate * scale * bonus
        end
    end
    if not weight and not income then return nil end
    if income and CONFIG.MIN_INCOME > 0 and income < CONFIG.MIN_INCOME then return nil end

    local uid = tostring(record.Uid or record.Id or record.ID or record.RecordId
        or record.Guid or record.UUID or record.InstanceId or key)
    return {
        name = name,
        rarity = rarity,
        weight = weight,
        income = income,
        area = areaName(record.AreaId or record.Area or record.Zone),
        serverId = tostring(game.JobId or ""),
        image = iconUrlOf(entry),
        category = tostring(category),
        uid = uid,
        state = tostring(record.State or ""),
    }
end

---------------------------------------------------------------
-- 5. HTTP
---------------------------------------------------------------
local function getRequest()
    return (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request) or request
end
local function httpCall(method, path, body)
    local req = getRequest()
    if type(req) ~= "function" then return nil, "sin HTTP" end
    local opts = {
        Url = CONFIG.API_URL .. path,
        Method = method,
        Headers = { ["Accept"] = "application/json" },
    }
    if CONFIG.API_KEY ~= "" then opts.Headers["X-API-Key"] = CONFIG.API_KEY end
    if body ~= nil then
        opts.Headers["Content-Type"] = "application/json"
        opts.Body = HttpService:JSONEncode(body)
    end
    local ok, res = pcall(req, opts)
    if not ok or type(res) ~= "table" then return nil, "fallo de red" end
    local status = tonumber(res.StatusCode or res.Status or res.statusCode) or 200
    local text = res.Body or res.body
    return { status = status, body = (type(text) == "string") and text or nil }
end

---------------------------------------------------------------
-- 6. GUI BASE (distinto al panel: lado izquierdo, más ancho)
---------------------------------------------------------------
local function guiParent()
    local parent
    pcall(function()
        local probe = Instance.new("Folder")
        probe.Parent = game:GetService("CoreGui")
        probe:Destroy()
        parent = game:GetService("CoreGui")
    end)
    if not parent then pcall(function() if gethui then parent = gethui() end end) end
    if not parent then parent = player:WaitForChild("PlayerGui", 10) end
    return parent
end

local W, H = 400, 460
local MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local Gui = N("ScreenGui", {
    Name = "DreyvidHubDetector",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 79,
    Parent = guiParent(),
})
if not Gui.Parent then return end

local UI_SCALE = 1
local function computeScale()
    local cam = Workspace.CurrentCamera
    local vp = (cam and cam.ViewportSize) or Vector2.new(1280, 720)
    local base = MOBILE and 0.9 or 1
    UI_SCALE = math.clamp(math.min(base, (vp.Y - 24) / H, (vp.X - 16) / W), 0.5, 1.15)
end
computeScale()

local MAIN_POS = UDim2.new(0, (W / 2) + 18, 0.5, 0) -- lado izquierdo
local Main = N("Frame", {
    Name = "Main",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Size = UDim2.new(0, W, 0, H),
    Position = UDim2.new(0, -W, 0.5, 0),
    BackgroundColor3 = C.bg,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Active = true,
    Visible = false,
    Parent = Gui,
})
Corner(Main, 16)
N("UIGradient", { Color = ColorSequence.new(C.bg2, C.bg), Rotation = 90, Parent = Main })
local MainScale = N("UIScale", { Scale = UI_SCALE, Parent = Main })
Stroke(Main, C.white, 2, 0.04)
local MainStrokeGrad = N("UIGradient", { Color = NEON, Parent = Main:FindFirstChildOfClass("UIStroke") })

pcall(function()
    Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
        computeScale()
        MainScale.Scale = UI_SCALE
    end)
end)

---------------------------------------------------------------
-- 7. HEADER
---------------------------------------------------------------
local Header = N("Frame", {
    Size = UDim2.new(1, 0, 0, 56),
    BackgroundColor3 = C.bg2,
    BorderSizePixel = 0,
    Active = true,
    Parent = Main,
})
Corner(Header, 16)
N("Frame", { Size = UDim2.new(1, 0, 0, 16), Position = UDim2.new(0, 0, 1, -16), BackgroundColor3 = C.bg2, BorderSizePixel = 0, Parent = Header })
N("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(9, 26, 45)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(13, 50, 88)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(9, 26, 45)),
    }),
    Parent = Header,
})
local HeaderLine = N("Frame", { Size = UDim2.new(1, -20, 0, 1), Position = UDim2.new(0, 10, 1, -1), BackgroundColor3 = C.white, BorderSizePixel = 0, Parent = Header })
N("UIGradient", {
    Color = NEON,
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(0.5, 0),
        NumberSequenceKeypoint.new(1, 1),
    }),
    Parent = HeaderLine,
})

local Logo = N("Frame", {
    Size = UDim2.new(0, 28, 0, 28),
    Position = UDim2.new(0, 12, 0, 14),
    BackgroundColor3 = C.panel,
    BorderSizePixel = 0,
    Parent = Header,
})
Corner(Logo, 8)
Stroke(Logo, C.white, 1.5, 0.1)
local LogoDia = N("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 0),
    Size = UDim2.new(0, 11, 0, 11),
    Rotation = 45,
    BackgroundColor3 = C.white,
    BorderSizePixel = 0,
    Parent = Logo,
})
Corner(LogoDia, 3)
N("UIGradient", { Color = ColorSequence.new(C.accent2, C.accent), Rotation = 90, Parent = LogoDia })

local Title = N("TextLabel", {
    Size = UDim2.new(1, -140, 0, 19),
    Position = UDim2.new(0, 46, 0, 10),
    BackgroundTransparency = 1,
    Text = "DREYVID HUB",
    TextColor3 = C.white,
    Font = Enum.Font.GothamBlack,
    TextSize = 16,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = Header,
})
local TitleGrad = N("UIGradient", {
    Color = ColorSequence.new(C.white, C.accent2),
    Offset = Vector2.new(-0.2, 0),
    Parent = Title,
})
N("TextLabel", {
    Size = UDim2.new(1, -140, 0, 12),
    Position = UDim2.new(0, 47, 0, 30),
    BackgroundTransparency = 1,
    Text = "DETECTOR  ·  ESCÁNER EN VIVO",
    TextColor3 = C.gray,
    Font = Enum.Font.GothamBold,
    TextSize = 8,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = Header,
})

local function HeaderBtn(text, offsetX, isClose)
    local btn = N("TextButton", {
        Size = UDim2.new(0, 24, 0, 24),
        Position = UDim2.new(1, offsetX, 0, 16),
        BackgroundColor3 = isClose and Color3.fromRGB(72, 20, 34) or C.card,
        Text = text,
        TextColor3 = C.white,
        Font = Enum.Font.GothamBlack,
        TextSize = (text == "X") and 10 or 13,
        AutoButtonColor = false,
        Parent = Header,
    })
    Corner(btn, 7)
    local st = Stroke(btn, C.white, 1, 0.35)
    btn.MouseEnter:Connect(function() Tw(st, 0.15, { Color = C.accent, Transparency = 0 }) end)
    btn.MouseLeave:Connect(function() Tw(st, 0.15, { Color = C.white, Transparency = 0.35 }) end)
    PressFX(btn)
    return btn
end
local MinBtn = HeaderBtn("-", -62, false)
local CloseBtn = HeaderBtn("X", -32, true)

---------------------------------------------------------------
-- 8. ESTADO, STATS, ÚLTIMA DETECCIÓN, LISTA
---------------------------------------------------------------
local StatusFrame = N("Frame", {
    Size = UDim2.new(1, -24, 0, 42),
    Position = UDim2.new(0, 12, 0, 64),
    BackgroundColor3 = C.panel,
    BorderSizePixel = 0,
    Parent = Main,
})
Corner(StatusFrame, 10)
Stroke(StatusFrame, C.white, 1, 0.35)
local StatusDot = N("Frame", {
    Size = UDim2.new(0, 8, 0, 8),
    Position = UDim2.new(0, 12, 0, 12),
    BackgroundColor3 = C.green,
    BorderSizePixel = 0,
    Parent = StatusFrame,
})
Corner(StatusDot, 4)
local StatusLabel = N("TextLabel", {
    Size = UDim2.new(1, -80, 0, 16),
    Position = UDim2.new(0, 28, 0, 6),
    BackgroundTransparency = 1,
    Text = "Iniciando escáner…",
    TextColor3 = C.white,
    Font = Enum.Font.GothamBlack,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = StatusFrame,
})
local SourceLabel = N("TextLabel", {
    Size = UDim2.new(1, -28, 0, 12),
    Position = UDim2.new(0, 28, 0, 23),
    BackgroundTransparency = 1,
    Text = "fuente: —   ·   latencia: —",
    TextColor3 = C.gray,
    Font = Enum.Font.Gotham,
    TextSize = 8,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = StatusFrame,
})
TweenService:Create(StatusDot, TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { BackgroundTransparency = 0.65 }):Play()

local StatsFrame = N("Frame", {
    Size = UDim2.new(1, -24, 0, 40),
    Position = UDim2.new(0, 12, 0, 112),
    BackgroundTransparency = 1,
    Parent = Main,
})
N("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 8),
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent = StatsFrame,
})
local statLabels = {}
local function makeStat(index, caption)
    local box = N("Frame", {
        Size = UDim2.new(1 / 3, -6, 1, 0),
        BackgroundColor3 = C.panel,
        BorderSizePixel = 0,
        LayoutOrder = index,
        Parent = StatsFrame,
    })
    Corner(box, 9)
    Stroke(box, C.white, 1, 0.4)
    local value = N("TextLabel", {
        Size = UDim2.new(1, 0, 0, 20),
        Position = UDim2.new(0, 0, 0, 5),
        BackgroundTransparency = 1,
        Text = "0",
        TextColor3 = C.white,
        Font = Enum.Font.GothamBlack,
        TextSize = 16,
        Parent = box,
    })
    N("TextLabel", {
        Size = UDim2.new(1, 0, 0, 10),
        Position = UDim2.new(0, 0, 0, 25),
        BackgroundTransparency = 1,
        Text = caption,
        TextColor3 = C.dim,
        Font = Enum.Font.GothamBold,
        TextSize = 7,
        Parent = box,
    })
    return value
end
statLabels.scans = makeStat(1, "ESCANEOS")
statLabels.found = makeStat(2, "HALLAZGOS")
statLabels.sent = makeStat(3, "ENVIADOS")

local LastFrame = N("Frame", {
    Size = UDim2.new(1, -24, 0, 82),
    Position = UDim2.new(0, 12, 0, 158),
    BackgroundColor3 = C.card,
    BorderSizePixel = 0,
    Parent = Main,
})
Corner(LastFrame, 11)
local LastStroke = Stroke(LastFrame, C.white, 1.2, 0.3)
N("TextLabel", {
    Size = UDim2.new(1, -20, 0, 11),
    Position = UDim2.new(0, 10, 0, 4),
    BackgroundTransparency = 1,
    Text = "ÚLTIMA DETECCIÓN",
    TextColor3 = C.accent2,
    Font = Enum.Font.GothamBlack,
    TextSize = 7,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = LastFrame,
})
local lastThumb = N("Frame", {
    Size = UDim2.new(0, 54, 0, 54),
    Position = UDim2.new(0, 10, 0, 19),
    BackgroundColor3 = C.panel,
    BorderSizePixel = 0,
    Parent = LastFrame,
})
Corner(lastThumb, 9)
Stroke(lastThumb, C.white, 1, 0.4)
local lastImage = N("ImageLabel", {
    Size = UDim2.new(1, -4, 1, -4),
    Position = UDim2.new(0, 2, 0, 2),
    BackgroundTransparency = 1,
    Image = "",
    Visible = false,
    ScaleType = Enum.ScaleType.Fit,
    Parent = lastThumb,
})
Corner(lastImage, 8)
local lastInitial = N("TextLabel", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    Text = "?",
    TextColor3 = C.accent2,
    Font = Enum.Font.GothamBlack,
    TextSize = 22,
    Parent = lastThumb,
})
local lastName = N("TextLabel", {
    Size = UDim2.new(1, -170, 0, 17),
    Position = UDim2.new(0, 72, 0, 18),
    BackgroundTransparency = 1,
    Text = "Esperando detección…",
    TextColor3 = C.white,
    Font = Enum.Font.GothamBlack,
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Parent = LastFrame,
})
local lastBadge = N("TextLabel", {
    Size = UDim2.new(0, 58, 0, 14),
    Position = UDim2.new(1, -68, 0, 20),
    BackgroundColor3 = C.accent,
    BackgroundTransparency = 0.7,
    Text = "—",
    TextColor3 = C.accent,
    Font = Enum.Font.GothamBlack,
    TextSize = 7,
    Visible = false,
    Parent = LastFrame,
})
Corner(lastBadge, 5)
Stroke(lastBadge, C.white, 1, 0.35)
local lastMeta = N("TextLabel", {
    Size = UDim2.new(1, -84, 0, 13),
    Position = UDim2.new(0, 72, 0, 37),
    BackgroundTransparency = 1,
    Text = "Peso: —   ·   Ingreso: —",
    TextColor3 = C.ice,
    Font = Enum.Font.GothamBold,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Parent = LastFrame,
})
local lastArea = N("TextLabel", {
    Size = UDim2.new(1, -84, 0, 12),
    Position = UDim2.new(0, 72, 0, 53),
    BackgroundTransparency = 1,
    Text = "Zona: —   ·   —",
    TextColor3 = C.dim,
    Font = Enum.Font.Gotham,
    TextSize = 8,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Parent = LastFrame,
})
local lastAreaName, lastDetectedAt = "—", os.time()

local lastSection = N("TextLabel", {
    Size = UDim2.new(1, -24, 0, 12),
    Position = UDim2.new(0, 14, 0, 245),
    BackgroundTransparency = 1,
    Text = "ÚLTIMAS DETECCIONES",
    TextColor3 = C.gray,
    Font = Enum.Font.GothamBold,
    TextSize = 8,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = Main,
})

local List = N("ScrollingFrame", {
    Size = UDim2.new(1, -24, 0, 124),
    Position = UDim2.new(0, 12, 0, 261),
    BackgroundColor3 = C.panel,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.accent2,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    Parent = Main,
})
Corner(List, 9)
Stroke(List, C.white, 1, 0.45)
N("UIListLayout", {
    Padding = UDim.new(0, 5),
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent = List,
})
N("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), Parent = List })
local listEmpty = N("TextLabel", {
    Size = UDim2.new(1, -12, 0, 30),
    BackgroundTransparency = 1,
    Text = "Aún no hay hallazgos en este servidor.",
    TextColor3 = C.dim,
    Font = Enum.Font.Gotham,
    TextSize = 9,
    TextWrapped = true,
    Parent = List,
})

local ScanBtn = N("TextButton", {
    Size = UDim2.new(0, 106, 0, 26),
    Position = UDim2.new(0, 12, 1, -38),
    BackgroundColor3 = C.accent,
    Text = "ESCANEAR",
    TextColor3 = C.white,
    Font = Enum.Font.GothamBlack,
    TextSize = 9,
    AutoButtonColor = false,
    Parent = Main,
})
Corner(ScanBtn, 8)
Stroke(ScanBtn, C.white, 1.2, 0.2)
PressFX(ScanBtn)
local ApiBtn = N("TextButton", {
    Size = UDim2.new(0, 64, 0, 26),
    Position = UDim2.new(0, 124, 1, -38),
    BackgroundColor3 = C.panel,
    Text = "API",
    TextColor3 = C.ice,
    Font = Enum.Font.GothamBlack,
    TextSize = 9,
    AutoButtonColor = false,
    Parent = Main,
})
Corner(ApiBtn, 8)
Stroke(ApiBtn, C.white, 1, 0.45)
PressFX(ApiBtn)
local HopBtn = N("TextButton", {
    Size = UDim2.new(0, 130, 0, 26),
    Position = UDim2.new(1, -142, 1, -38),
    BackgroundColor3 = C.panel,
    Text = "SIGUIENTE SERVIDOR",
    TextColor3 = C.ice,
    Font = Enum.Font.GothamBlack,
    TextSize = 8,
    AutoButtonColor = false,
    Parent = Main,
})
Corner(HopBtn, 8)
Stroke(HopBtn, C.white, 1, 0.45)
PressFX(HopBtn)

local Toast = N("TextLabel", {
    Size = UDim2.new(1, -40, 0, 24),
    Position = UDim2.new(0, 20, 1, -74),
    BackgroundColor3 = C.panel,
    BackgroundTransparency = 1,
    Text = "",
    TextColor3 = C.white,
    Font = Enum.Font.GothamBold,
    TextSize = 9,
    Visible = false,
    ZIndex = 40,
    Parent = Main,
})
Corner(Toast, 8)
local ToastStroke = Stroke(Toast, C.accent, 1, 0.2)
local toastToken = 0
local function toast(text, color)
    toastToken = toastToken + 1
    local token = toastToken
    Toast.Text = text
    Toast.TextColor3 = color or C.white
    Toast.Visible = true
    Toast.BackgroundTransparency = 0.1
    ToastStroke.Transparency = 0
    task.delay(2.2, function()
        if token ~= toastToken then return end
        Tw(Toast, 0.4, { BackgroundTransparency = 1 })
        Tw(ToastStroke, 0.4, { Transparency = 1 })
        task.wait(0.45)
        if token == toastToken then Toast.Visible = false end
    end)
end

local function setStatus(text, color)
    StatusLabel.Text = text
    StatusLabel.TextColor3 = color or C.white
    StatusDot.BackgroundColor3 = color or C.green
end

---------------------------------------------------------------
-- 9. LÓGICA DEL ESCÁNER
---------------------------------------------------------------
local stats = { scans = 0, found = 0, sent = 0, lastMs = 0 }
local known = {}
local postedAt = {}
local recent = {}
local lastSnapshotByName = {}
local lastSource = "—"

local function updateStats()
    statLabels.scans.Text = tostring(stats.scans)
    statLabels.found.Text = tostring(stats.found)
    statLabels.sent.Text = tostring(stats.sent)
    SourceLabel.Text = "fuente: " .. lastSource .. "   ·   latencia: " .. stats.lastMs .. " ms"
end

local function pushToPanel(info)
    local add = _G.DreyvidAddReport
    if type(add) ~= "function" then return false end
    local ok = pcall(add, {
        name = info.name,
        rarity = info.rarity,
        weight = info.weight,
        income = info.income,
        area = info.area,
        server_id = info.serverId,
        image = info.image,
        category = info.category,
        createdAt = os.time(),
    })
    return ok
end

local function postReport(info)
    local uid = tostring(info.uid or "")
    local now = os.time()
    if uid ~= "" and postedAt[uid] and (now - postedAt[uid]) < CONFIG.POST_COOLDOWN then
        return false
    end
    local payload = {
        name = info.name,
        rarity = info.rarity,
        weight = info.weight,
        income = info.income,
        server_id = info.serverId,
        area = info.area,
        image = info.image,
        place_id = game.PlaceId,
    }
    local res = httpCall("POST", "/reports", payload)
    if res and res.status >= 400 and (payload.image or payload.place_id) then
        -- backend viejo (no acepta campos extra): reintenta con los campos clásicos
        payload.image = nil
        payload.place_id = nil
        res = httpCall("POST", "/reports", payload)
    end
    if res and res.status < 400 then
        postedAt[uid] = now
        stats.sent = stats.sent + 1
        updateStats()
        return true
    end
    return false
end

local recentCards = {}
local function addRecent(info)
    table.insert(recent, 1, info)
    while #recent > CONFIG.MAX_RECENT do table.remove(recent) end

    local card = N("Frame", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = C.card,
        BorderSizePixel = 0,
        LayoutOrder = 1,
        Parent = List,
    })
    Corner(card, 7)
    local st = Stroke(card, C.white, 1, 0.55)
    table.insert(recentCards, 1, card)
    for index, recentCard in ipairs(recentCards) do recentCard.LayoutOrder = index end
    while #recentCards > CONFIG.MAX_RECENT do
        local old = table.remove(recentCards)
        if old then old:Destroy() end
    end

    local thumb = N("Frame", {
        Size = UDim2.new(0, 24, 0, 24),
        Position = UDim2.new(0, 5, 0, 5),
        BackgroundColor3 = C.panel,
        BorderSizePixel = 0,
        Parent = card,
    })
    Corner(thumb, 5)
    Stroke(thumb, C.white, 1, 0.5)
    if info.image and info.image ~= "" then
        local img = N("ImageLabel", {
            Size = UDim2.new(1, -2, 1, -2),
            Position = UDim2.new(0, 1, 0, 1),
            BackgroundTransparency = 1,
            Image = info.image,
            ScaleType = Enum.ScaleType.Fit,
            Parent = thumb,
        })
        Corner(img, 4)
    else
        N("TextLabel", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            Text = string.upper(string.sub(info.name, 1, 1)),
            TextColor3 = C.accent2,
            Font = Enum.Font.GothamBlack,
            TextSize = 11,
            Parent = thumb,
        })
    end
    N("TextLabel", {
        Size = UDim2.new(1, -90, 0, 13),
        Position = UDim2.new(0, 34, 0, 3),
        BackgroundTransparency = 1,
        Text = info.name .. "  ·  " .. rarityLabel(info.rarity),
        TextColor3 = C.white,
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = card,
    })
    N("TextLabel", {
        Size = UDim2.new(1, -90, 0, 11),
        Position = UDim2.new(0, 34, 0, 17),
        BackgroundTransparency = 1,
        Text = fmtWeight(info.weight) .. "   ·   " .. fmtMoney(info.income) .. "   ·   " .. tostring(info.area),
        TextColor3 = C.dim,
        Font = Enum.Font.Gotham,
        TextSize = 8,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = card,
    })
    N("TextLabel", {
        Size = UDim2.new(0, 60, 1, 0),
        Position = UDim2.new(1, -62, 0, 0),
        BackgroundTransparency = 1,
        Text = timeAgo(os.time()),
        TextColor3 = C.accent2,
        Font = Enum.Font.GothamBold,
        TextSize = 7,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = card,
    })
    local tw = N("UIScale", { Scale = 0.9, Parent = card })
    Tw(tw, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
    if listEmpty and listEmpty.Parent then listEmpty:Destroy() end
end

local function updateLast(info)
    lastImage.Image = info.image or ""
    lastImage.Visible = (info.image ~= nil and info.image ~= "")
    lastInitial.Visible = not lastImage.Visible
    lastInitial.Text = string.upper(string.sub(info.name, 1, 1))
    lastName.Text = info.name
    local color = rarityColor(info.rarity)
    lastBadge.Visible = true
    lastBadge.Text = rarityLabel(info.rarity)
    lastBadge.TextColor3 = color
    lastBadge.BackgroundColor3 = color
    lastMeta.Text = "Peso: " .. fmtWeight(info.weight) .. "   ·   Ingreso: " .. fmtMoney(info.income)
    lastAreaName = tostring(info.area)
    lastDetectedAt = os.time()
    lastArea.Text = "Zona: " .. lastAreaName .. "   ·   ahora"
    Tw(LastStroke, 0.2, { Transparency = 0 }, Enum.EasingStyle.Quad)
    task.delay(0.7, function() if LastStroke.Parent then Tw(LastStroke, 0.6, { Transparency = 0.3 }) end end)
end

-- forward (los botones se conectan al final)
local scan

local function doScan()
    local started = os.clock()
    local records, source = readRecords()
    stats.scans = stats.scans + 1
    lastSource = source or "—"
    if not records then
        stats.lastMs = math.floor((os.clock() - started) * 1000)
        updateStats()
        setStatus("SIN DATOS DEL JUEGO · reintentando", C.gold)
        return
    end

    local hasSlot = false
    for _, record in pairs(records) do
        if type(record) == "table" and tostring(record.State or "") == "Slot" then
            hasSlot = true
            break
        end
    end

    local candidates = {}
    lastSnapshotByName = {}
    for key, record in pairs(records) do
        if type(record) == "table" then
            local state = tostring(record.State or "")
            if (not hasSlot) or state == "Slot" then
                local info = buildInfo(record, key)
                if info then
                    lastSnapshotByName[string.lower(info.name)] = info
                    local identity = info.uid .. "|" .. info.category
                    if not known[identity] then
                        table.insert(candidates, { identity = identity, info = info })
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        return (a.info.income or 0) > (b.info.income or 0)
    end)

    local reported = 0
    for i = 1, #candidates do
        if reported >= CONFIG.MAX_PER_SCAN then break end
        local candidate = candidates[i]
        known[candidate.identity] = os.time()
        local info = candidate.info
        stats.found = stats.found + 1
        pushToPanel(info)
        addRecent(info)
        updateLast(info)
        reported = reported + 1
        task.delay((i - 1) * 0.12, function()
            local ok, err = pcall(function() return postReport(info) end)
            if not ok then setStatus("FALLO AL ENVIAR · " .. tostring(err), C.red) end
        end)
    end

    stats.lastMs = math.floor((os.clock() - started) * 1000)
    updateStats()
    if reported > 0 then
        setStatus("DETECTADO · " .. reported .. " nuevo(s) en este servidor", C.green)
    else
        setStatus("ESCANEANDO EL SERVIDOR…", C.accent2)
    end
end

scan = function(manual)
    if manual then
        setStatus("ESCANEANDO (manual)…", C.accent2)
        task.spawn(function()
            local ok, err = pcall(doScan)
            if not ok then setStatus("ERROR DE ESCANEO: " .. tostring(err), C.red) end
        end)
        return
    end
    doScan()
end

---------------------------------------------------------------
-- 10. CHAT (aviso visual, sin inventar datos)
---------------------------------------------------------------
local function onAnnouncement(text)
    if type(text) ~= "string" then return end
    local lower = string.lower(text)
    if not (lower:find("ha aparecido", 1, true)
        or lower:find("has appeared", 1, true)
        or lower:find("ha nacido", 1, true)
        or lower:find("apareció", 1, true)) then
        return
    end
    local matched
    for name, info in pairs(lastSnapshotByName) do
        if lower:find(name, 1, true) then matched = info break end
    end
    if matched then
        setStatus("ANUNCIO: " .. matched.name .. " · " .. matched.area, C.gold)
        pushToPanel(matched)
        task.delay(0.2, function() pcall(function() postReport(matched) end) end)
    else
        setStatus("ANUNCIO DETECTADO · sin registro verificable", C.gold)
    end
end

pcall(function()
    TextChatService.MessageReceived:Connect(function(message)
        local source = message.TextSource
        if source and source.UserId then return end -- ignora mensajes de jugadores
        if type(message.Text) == "string" then onAnnouncement(message.Text) end
    end)
end)

---------------------------------------------------------------
-- 11. SERVIDORES / API
---------------------------------------------------------------
local function getPublicServer()
    local req = getRequest()
    if type(req) ~= "function" then return nil, "sin HTTP" end
    local url = "https://games.roblox.com/v1/games/" .. tostring(game.PlaceId)
        .. "/servers/Public?sortOrder=Asc&limit=100&excludeFullGames=true"
    local ok, res = pcall(req, { Url = url, Method = "GET", Headers = { ["Accept"] = "application/json" } })
    if not ok or type(res) ~= "table" then return nil, "no se pudo consultar la lista" end
    local status = tonumber(res.StatusCode or res.Status or 200) or 200
    if status < 200 or status >= 300 then return nil, "lista pública: HTTP " .. tostring(status) end
    local body = res.Body or res.body
    if type(body) ~= "string" then return nil, "respuesta inválida" end
    local decoded, data = pcall(function() return HttpService:JSONDecode(body) end)
    if not decoded or type(data) ~= "table" or type(data.data) ~= "table" then
        return nil, "respuesta inválida"
    end
    local candidates = {}
    for _, server in ipairs(data.data) do
        local sid = tostring(server.id or "")
        local playing = tonumber(server.playing) or 0
        local maxPlayers = tonumber(server.maxPlayers) or 0
        if sid ~= "" and sid ~= tostring(game.JobId) and (maxPlayers == 0 or playing < maxPlayers) then
            table.insert(candidates, sid)
        end
    end
    if #candidates == 0 then return nil, "no hay otro servidor disponible" end
    return candidates[math.random(#candidates)]
end

HopBtn.MouseButton1Click:Connect(function()
    if HopBtn.Text == "BUSCANDO…" then return end
    HopBtn.Text = "BUSCANDO…"
    HopBtn.Active = false
    setStatus("BUSCANDO OTRO SERVIDOR…", C.gold)
    task.spawn(function()
        local sid, err = getPublicServer()
        if not sid then
            setStatus(err or "no se encontró servidor", C.red)
            HopBtn.Text = "SIGUIENTE SERVIDOR"
            HopBtn.Active = true
            return
        end
        setStatus("ENTRANDO A OTRO SERVIDOR…", C.green)
        local ok = pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, sid, player)
        end)
        if not ok then
            setStatus("no se pudo teletransportar", C.red)
            HopBtn.Text = "SIGUIENTE SERVIDOR"
            HopBtn.Active = true
            return
        end
        task.delay(8, function()
            HopBtn.Text = "SIGUIENTE SERVIDOR"
            HopBtn.Active = true
        end)
    end)
end)

ApiBtn.MouseButton1Click:Connect(function()
    ApiBtn.Text = "…"
    task.spawn(function()
        local res, err = httpCall("GET", "/health")
        if not res then
            setStatus("API SIN CONEXIÓN · " .. tostring(err or ""), C.red)
        elseif res.status == 503 then
            setStatus("API DESPERTANDO (503) · espera ~40 s", C.gold)
        elseif res.status < 400 then
            setStatus("API ONLINE · " .. tostring(res.body or ""):sub(1, 60), C.green)
        else
            setStatus("API ERROR HTTP " .. res.status, C.red)
        end
        ApiBtn.Text = "API"
    end)
end)

ScanBtn.MouseButton1Click:Connect(function() scan(true) end)

---------------------------------------------------------------
-- 12. MINIMIZAR / CERRAR / ARRASTRAR
---------------------------------------------------------------
local FloatBtn = N("TextButton", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Size = UDim2.new(0, 46, 0, 46),
    Position = UDim2.new(0, 42, 0.5, 0),
    BackgroundColor3 = C.bg2,
    Text = "",
    AutoButtonColor = false,
    Visible = false,
    Parent = Gui,
})
Corner(FloatBtn, 13)
Stroke(FloatBtn, C.white, 2, 0.05)
local FloatScale = N("UIScale", { Scale = UI_SCALE, Parent = FloatBtn })
N("TextLabel", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    Text = "D",
    TextColor3 = C.accent2,
    Font = Enum.Font.GothamBlack,
    TextSize = 22,
    Parent = FloatBtn,
})
TweenService:Create(FloatBtn, TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
    Position = UDim2.new(0, 42, 0.5, -7),
}):Play()

local minimized = false
local function toggleMinimize()
    if not Main.Parent then return end
    minimized = not minimized
    if minimized then
        Tw(MainScale, 0.28, { Scale = UI_SCALE * 0.6 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
        Tw(Main, 0.3, { BackgroundTransparency = 1 })
        task.delay(0.3, function()
            if minimized then
                Main.Visible = false
                Main.BackgroundTransparency = 0
                MainScale.Scale = UI_SCALE
            end
        end)
        FloatBtn.Visible = true
        FloatScale.Scale = 0.2
        Tw(FloatScale, 0.4, { Scale = UI_SCALE }, Enum.EasingStyle.Back)
    else
        FloatBtn.Visible = false
        Main.Visible = true
        MainScale.Scale = UI_SCALE * 0.65
        Main.BackgroundTransparency = 1
        Tw(MainScale, 0.45, { Scale = UI_SCALE }, Enum.EasingStyle.Back)
        Tw(Main, 0.35, { BackgroundTransparency = 0 })
    end
end
MinBtn.MouseButton1Click:Connect(toggleMinimize)
FloatBtn.MouseButton1Click:Connect(toggleMinimize)
CloseBtn.MouseButton1Click:Connect(function()
    _G.DreyvidDetectorReady = nil
    Gui:Destroy()
end)

do
    local dragging, dragStart, startPos = false, nil, nil
    Header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = Main.Position
        end
    end)
    Header.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            if not dragStart or not startPos then return end
            local delta = input.Position - dragStart
            Main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

UserInputService.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift then toggleMinimize() end
end)

---------------------------------------------------------------
-- 13. BUCLE DE ESCANEO + ANIMACIONES
---------------------------------------------------------------
loadGameData()
_G.DreyvidDetectorReady = true

task.spawn(function()
    while Gui.Parent do
        local ok, err = pcall(doScan)
        if not ok then setStatus("ERROR DEL ESCÁNER: " .. tostring(err), C.red) end
        task.wait(CONFIG.SCAN_INTERVAL)
    end
end)

-- refrescar textos relativos cada 1 s
task.spawn(function()
    while Gui.Parent do
        task.wait(1)
        if Main.Visible then
            lastArea.Text = "Zona: " .. lastAreaName .. "   ·   " .. timeAgo(lastDetectedAt)
        end
    end
end)

do
    local t0 = os.clock()
    local acc = 0
    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not Gui.Parent then conn:Disconnect() return end
        acc = acc + dt
        local step = MOBILE and (1 / 30) or (1 / 60)
        if acc < step then return end
        acc = 0
        local t = os.clock() - t0
        if Main.Visible then
            TitleGrad.Offset = Vector2.new(((t * 0.25) % 1) * 2 - 1, 0)
            LogoDia.Rotation = 45 + math.sin(t * 1.4) * 8
            MainStrokeGrad.Rotation = (t * 40) % 360
        end
    end)
end

---------------------------------------------------------------
-- 14. ENTRADA (splash + mostrar)
---------------------------------------------------------------
local function showPanel()
    Main.Visible = true
    Main.BackgroundTransparency = 1
    MainScale.Scale = UI_SCALE * 0.92
    TweenService:Create(Main, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = MAIN_POS,
        BackgroundTransparency = 0,
    }):Play()
    Tw(MainScale, 0.5, { Scale = UI_SCALE }, Enum.EasingStyle.Back)
end

local okSplash = pcall(function()
    local splash = N("Frame", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundColor3 = C.bg,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 90,
        Parent = Gui,
    })
    N("UIGradient", {
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(2, 10, 22)),
            ColorSequenceKeypoint.new(0.5, Color3.fromRGB(4, 18, 36)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(2, 10, 22)),
        }),
        Rotation = 35,
        Parent = splash,
    })
    Tw(splash, 0.3, { BackgroundTransparency = 0.02 })

    local box = N("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(0, 420, 0, 180),
        BackgroundTransparency = 1,
        ZIndex = 91,
        Parent = splash,
    })
    local boxScale = N("UIScale", { Scale = math.clamp(UI_SCALE * 1.02, 0.55, 1.2), Parent = box })

    local logo = N("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0, 30),
        Size = UDim2.new(0, 28, 0, 28),
        Rotation = 45,
        BackgroundColor3 = C.accent2,
        BorderSizePixel = 0,
        ZIndex = 92,
        Parent = box,
    })
    Corner(logo, 5)
    local logoScale = N("UIScale", { Scale = 0, Parent = logo })

    local letters = {}
    local word = "DREYVID"
    local widths = {}
    local total = 0
    for i = 1, #word do
        local w = (word:sub(i, i) == "I") and 16 or 34
        widths[i] = w
        total = total + w + 4
    end
    local x = (420 - total) / 2
    for i = 1, #word do
        local label = N("TextLabel", {
            Size = UDim2.new(0, widths[i], 0, 46),
            Position = UDim2.new(0, x, 0, 84),
            BackgroundTransparency = 1,
            Text = word:sub(i, i),
            TextColor3 = C.accent2,
            TextTransparency = 1,
            Font = Enum.Font.GothamBlack,
            TextSize = 40,
            ZIndex = 92,
            Parent = box,
        })
        local st = N("UIStroke", { Color = C.white, Thickness = 1.6, Transparency = 1, Parent = label })
        table.insert(letters, { label = label, stroke = st, x = x })
        x = x + widths[i] + 4
    end

    local sub = N("TextLabel", {
        Size = UDim2.new(1, 0, 0, 16),
        Position = UDim2.new(0, 0, 0, 136),
        BackgroundTransparency = 1,
        Text = "HUB  ·  DETECTOR",
        TextColor3 = C.gray,
        TextTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        ZIndex = 92,
        Parent = box,
    })
    local bar = N("Frame", {
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, 160),
        Size = UDim2.new(0, 0, 0, 3),
        BackgroundColor3 = C.white,
        BorderSizePixel = 0,
        ZIndex = 92,
        Parent = box,
    })
    Corner(bar, 2)
    N("UIGradient", { Color = NEON, Parent = bar })

    local alive = true
    local t0 = os.clock()
    local conn = RunService.Heartbeat:Connect(function()
        if not alive then return end
        local t = os.clock() - t0
        logo.Rotation = 45 + t * 80
        for i, item in ipairs(letters) do
            local k = (math.sin(t * 4 - i * 0.6) + 1) / 2
            item.label.TextColor3 = C.accent2:Lerp(C.white, k * 0.8)
        end
    end)

    task.spawn(function()
        Tw(logoScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
        task.wait(0.25)
        for _, item in ipairs(letters) do
            item.label.Position = UDim2.new(0, item.x, 0, 66)
            Tw(item.label, 0.4, {
                TextTransparency = 0,
                Position = UDim2.new(0, item.x, 0, 84),
            }, Enum.EasingStyle.Back)
            Tw(item.stroke, 0.4, { Transparency = 0.6 })
            task.wait(0.06)
        end
        Tw(sub, 0.35, { TextTransparency = 0 })
        Tw(bar, 0.9, { Size = UDim2.new(0, 230, 0, 3) }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
        task.wait(0.95)
        Tw(boxScale, 0.3, { Scale = boxScale.Scale * 1.1 }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
        Tw(splash, 0.35, { BackgroundTransparency = 1 })
        for _, item in ipairs(letters) do
            Tw(item.label, 0.25, { TextTransparency = 1 })
            Tw(item.stroke, 0.25, { Transparency = 1 })
        end
        Tw(sub, 0.25, { TextTransparency = 1 })
        Tw(bar, 0.25, { BackgroundTransparency = 1 })
        Tw(logo, 0.25, { BackgroundTransparency = 1 })
        task.wait(0.15)
        showPanel()
        task.wait(0.2)
        alive = false
        pcall(function() conn:Disconnect() end)
        splash:Destroy()
    end)
end)

if not okSplash then
    showPanel()
end

if tonumber(game.PlaceId) ~= CONFIG.EXPECTED_PLACE then
    setStatus("OJO: PlaceId distinto al de Steal an Egg (" .. tostring(game.PlaceId) .. ")", C.gold)
end

print("DREYVID HUB · DETECTOR cargado. Escaneando el servidor y enviando al PANEL.")
