-- LPH_NO_VIRTUALIZE source-build shim. Define as identity via a STRING env key so the
-- bare macro identifier never appears as a token (Luraph rejects bare macro identifiers).
-- In the obfuscated build Luraph resolves the macro at compile time and this assignment
-- is inert. Placed at the very top so any callback below can wrap a hot per-frame closure
-- with LPH_NO_VIRTUALIZE(function() ... end) and have it compile to native Lua even when
-- the rest of the script is virtualized -- which is the trick that kept the X-Ray hook
-- from tanking FPS, and it's the same fix we apply below to the other hot paths.
do
    local ok, env = pcall(getfenv)
    if ok and env and not env["LPH_NO_VIRTUALIZE"] then
        env["LPH_NO_VIRTUALIZE"] = function(f) return f end
    end
end

if not game:IsLoaded() then game.Loaded:Wait() end
pcall(function() game:GetService("Players").RespawnTime = 0 end)
setfpscap(9999)

local SharedState = {
    ConveyorAnimals = {},
    BestConveyorGv = -1,
    SelectedPetData = nil,
    AllAnimalsCache = nil,
    DisableStealSpeed = nil,
    ListNeedsRedraw = true,
    AdminButtonCache = {},
    StealSpeedToggleFunc = nil,
    BalloonedPlayers = {},
    PetPreviewModelCache = {},
    MobileScaleObjects = {},
    ScanInterval = 5,
    ScanOverdriveEnabled = false,
}

if not _G.SyncHookDone then
    _G.SyncHookDone = true
    local Sync = require(game.ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Synchronizer"))

    for name, fn in pairs(Sync) do
        if typeof(fn) ~= "function" then continue end
        if isexecutorclosure(fn) then continue end

        local ok, ups = pcall(debug.getupvalues, fn)
        if not ok then continue end

        for idx, val in pairs(ups) do
            if typeof(val) == "function" and not isexecutorclosure(val) then
                local ok2, innerUps = pcall(debug.getupvalues, val)
                if ok2 then
                    local hasBoolean = false
                    for _, v in pairs(innerUps) do
                        if typeof(v) == "boolean" then
                            hasBoolean = true
                            break
                        end
                    end
                    if hasBoolean then debug.setupvalue(fn, idx, newcclosure(function() end)) end
                end
            end
        end
    end
end

local Services = {
    Players = game:GetService("Players"),
    RunService = game:GetService("RunService"),
    UserInputService = game:GetService("UserInputService"),
    ReplicatedStorage = game:GetService("ReplicatedStorage"),
    TweenService = game:GetService("TweenService"),
    HttpService = game:GetService("HttpService"),
    Workspace = game:GetService("Workspace"),
    Lighting = game:GetService("Lighting"),
    VirtualInputManager = game:GetService("VirtualInputManager"),
    GuiService = game:GetService("GuiService"),
    TeleportService = game:GetService("TeleportService"),
}
local Players = Services.Players
local RunService = Services.RunService
local UserInputService = Services.UserInputService
local ReplicatedStorage = Services.ReplicatedStorage
local TweenService = Services.TweenService
local HttpService = Services.HttpService
local Workspace = Services.Workspace
local Lighting = Services.Lighting
local VirtualInputManager = Services.VirtualInputManager
local GuiService = Services.GuiService
local TeleportService = Services.TeleportService
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Decrypted
Decrypted = setmetatable({}, {
    __index = function(S, ez)
        local Netty = ReplicatedStorage.Packages.Net
        local prefix, path
        if     ez:sub(1,3) == "RE/" then prefix = "RE/";  path = ez:sub(4)
        elseif ez:sub(1,3) == "RF/" then prefix = "RF/";  path = ez:sub(4)
        else return nil end
        local Remote
        for i, v in Netty:GetChildren() do
            if v.Name == ez then
                Remote = Netty:GetChildren()[i + 1]
                break
            end
        end
        if Remote and not rawget(Decrypted, ez) then rawset(Decrypted, ez, Remote) end
        return rawget(Decrypted, ez)
    end
})
local Utility = {}
function Utility:LarpNet(F) return Decrypted[F] end

local function safeKeyCode(name, fallback)
    if type(name) ~= "string" then return fallback end
    local cleaned = name:gsub("^%s+", ""):gsub("%s+$", "")
    if cleaned == "" or cleaned == "--" then return fallback end
    local ok, kc = pcall(function() return Enum.KeyCode[cleaned] end)
    if ok and kc then return kc end
    return fallback
end

local FileName = "JustAFanHub_v1.json" 
local DefaultConfig = {
    Positions = {
        AdminPanel = {X = 0.1859375, Y = 0.5767123526556385}, 
        AdminToolsPanel = {X = 0.02, Y = 0.25},
        StealSpeed = {X = 0.02, Y = 0.18}, 
        Settings = {X = 0.834375, Y = 0.43590998043052839}, 
        InvisPanel = {X = 0.8578125, Y = 0.17260276361454258}, 
        AutoSteal = {X = 0.02, Y = 0.35}, 
        JobJoiner = {X = 0.5, Y = 0.85},
        AutoBuy   = {X = 0.01, Y = 0.35},
        StealersHUD = {X = 0.8, Y = 0.15},
    }, 
    TpSettings = {
        Tool           = "Flying Carpet",
        Speed          = 2,
        TpKey          = "T",
        CloneKey       = "V",
        CarpetSpeedKey = "Q",
        InfiniteJump   = false,
        CacheWait      = 0.10,
        TpSpeedF1      = 130,
        TpSpeedF2      = 130,
        CloneSwapDelay = 0,
        BrainrotSpeed  = 60,
        RiseSpeed      = 95,
        CruiseY        = 17,    -- legacy fallback; per-floor values below take precedence
        CruiseY_F1     = 17,
        CruiseY_F2     = 19,
        CloneSettleTime = 0.4,  -- pause at the locked spot before placing the clone
    },
    HitRecovery    = true,
    AutoTPPriority = true,
    StealSpeed   = 20,
    ShowStealSpeedPanel = true,
    MenuKey      = "LeftControl",
    
    AntiRagdoll  = 0,
    AntiRagdollV2 = true,
    PlayerESP    = true,
    FPSBoost     = true,
    DarkMode     = false,
    DarkBrightness = 0.4,
    TracerEnabled = true,
    BrainrotESP = true,
    LineToBase = false,
    StealNearest = false,
    StealHighest = true,
    StealPriority = false,
    DefaultToNearest = false,
    DefaultToHighest = false,
    DefaultToPriority = false,
    AutoBack = false,
    ShowStealingHUD = true,
    ShowStealingPlotESP = true,
    ConveyorESP = false,
    PriorityList = {},
    DefaultToDisable = false,
    UILocked     = false,
    HideAdminPanel = false,
    ShowAdminToolsPanel = true,
    HideAutoSteal = false,
    AutoKickOnSteal = false,
    InstantSteal = false,
    InvisStealAngle = 233,
    SinkSliderValue = 2.5,
    AutoRecoverLagback = true,
    AutoInvisDuringSteal = false,
    InvisToggleKey = "I",
    ClickToAP = false,
    ClickToAPKeybind = "L",
    ProximityAP = false,
    ProximityAPKeybind = "P",
    ProximityRange = 15,
    StealSpeedKey = "C",
    ShowInvisPanel = true,
    ResetKey = "X",
    AntiBeeDisco = false,
    FOV = 70,
    SubspaceMineESP = false,
    AutoUnlockOnSteal = false,
    ShowUnlockButtonsHUD = true,
    KickKey = "",
    CleanErrorGUIs = false,
    ClickToAPSingleCommand = false,
    RagdollSelfKey = "",
    AlertsEnabled = true,
    AlertSoundID = "rbxassetid://6518811702",
    AutoStealSpeed = false,
    ShowJobJoiner = true,
    JobJoinerKey = "J",
    CurrentTheme = "preto",
    ShowLoadingScreen = true,
    CustomThemeHex = "B432FF",
    ThemeImageUrl = "",
    ShowMiniActions = true,
    AutoHideMiniUI = false,
    TpMethod = "tween",  -- "tween" or "clone"
    MiniUIPos = {X = 0.01, Y = 0.35},
    MiniUILocked = false,
    Blacklist = {},
    BlacklistESP = true,
    BlacklistMsg = "BLOCKED",
    AutoBuyEnabled = false,
    AutoBuyKey = "K",
    AutoBuyRange = 17,
    AutoBuyColor = {R=0, G=220, B=255},
    HideAutoBuyUI = false,
    HideStealSpeedUI = false,
    HideStatusHUD = false,
    HideInvisPanel = false,
}

local Config = DefaultConfig


local OldFileName = "BullysRemastered_v1.json"
if isfile and not isfile(FileName) and isfile(OldFileName) then
    pcall(function()
        local ok, old = pcall(function() return HttpService:JSONDecode(readfile(OldFileName)) end)
        if not ok or type(old) ~= "table" then return end
        for k, v in pairs(DefaultConfig) do
            if old[k] == nil then old[k] = v end
        end
        if old.TpSettings then
            for k, v in pairs(DefaultConfig.TpSettings) do
                if old.TpSettings[k] == nil then old.TpSettings[k] = v end
            end
        end
        if old.Positions then
            for k, v in pairs(DefaultConfig.Positions) do
                if old.Positions[k] == nil then old.Positions[k] = v end
            end
        end
        if type(old.Blacklist) ~= "table" then old.Blacklist = {} end
        if type(old.PriorityList) ~= "table" then old.PriorityList = {} end
        old.AutoTurretEnabled = old.AutoTurretEnabled or false
        old.GrabKickEnabled   = old.GrabKickEnabled   or false
        if not old.Positions.AutoTurret then old.Positions.AutoTurret = {X=0.74,Y=0.58} end
        if not old.Positions.GrabKick   then old.Positions.GrabKick   = {X=0.74,Y=0.78} end
        Config = old
        if writefile then
            pcall(function() writefile(FileName, HttpService:JSONEncode(old)) end)
        end
    end)
end

if isfile and isfile(FileName) then
    pcall(function()
        local ok, decoded = pcall(function() return HttpService:JSONDecode(readfile(FileName)) end)
        if not ok then return end
        for k, v in pairs(DefaultConfig) do
            if decoded[k] == nil then decoded[k] = v end
        end
        if decoded.TpSettings then
            for k, v in pairs(DefaultConfig.TpSettings) do
                if decoded.TpSettings[k] == nil then decoded.TpSettings[k] = v end
            end
        end
        if decoded.Positions then
            for k, v in pairs(DefaultConfig.Positions) do
                if decoded.Positions[k] == nil then decoded.Positions[k] = v end
            end
        end
        if type(decoded.Blacklist) ~= "table" then decoded.Blacklist = {} end
        Config = decoded
    end)
end
Config.ProximityAP = false

if Config.CurrentTheme and THEMES and THEMES[Config.CurrentTheme] then for k, v in pairs(THEMES[Config.CurrentTheme]) do Theme[k] = v end end

-- Early declarations so closures work before admin task.spawn completes
BlacklistedPlayers    = BlacklistedPlayers    or Config.Blacklist or {}
addToBlacklist        = addToBlacklist        or function() end
removeFromBlacklist   = removeFromBlacklist   or function() end
isBlacklisted         = isBlacklisted         or function() return false end
canUseAdminAction     = canUseAdminAction     or function() return true end
refreshBlacklistUI    = refreshBlacklistUI    or function() end

local function SaveConfig()
    if writefile then
        pcall(function()
            local toSave = {}
            for k, v in pairs(Config) do toSave[k] = v end
            toSave.ProximityAP = false
            writefile(FileName, HttpService:JSONEncode(toSave))
        end)
    end
end

_G.InvisStealAngle = Config.InvisStealAngle
_G.SinkSliderValue = Config.SinkSliderValue
_G.AutoRecoverLagback = Config.AutoRecoverLagback
_G.AutoInvisDuringSteal = Config.AutoInvisDuringSteal
do
    local invisKey = Enum.KeyCode.I
    if type(Config.InvisToggleKey) == "string" and Config.InvisToggleKey ~= "" then
        local ok, kc = pcall(function() return Enum.KeyCode[Config.InvisToggleKey] end)
        if ok and kc then invisKey = kc end
    end
    _G.INVISIBLE_STEAL_KEY = invisKey
end
_G.invisibleStealEnabled = false
_G.RecoveryInProgress = false

local function getControls()
	local playerScripts = LocalPlayer:WaitForChild("PlayerScripts")
	local playerModule = require(playerScripts:WaitForChild("PlayerModule"))
	return playerModule:GetControls()
end

local Controls = getControls()

local function kickPlayer()
    local ok = pcall(function()
        if game.Shutdown then
            game:Shutdown()
        else
            LocalPlayer:Kick("\nJUSTAFAN HUB")
        end
    end)
    if not ok then pcall(function() LocalPlayer:Kick("\nJUSTAFAN HUB") end) end
end

local function walkForward(seconds)
    local char = LocalPlayer.Character
    local hum = char:FindFirstChild("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local Controls = getControls()
    local lookVector = hrp.CFrame.LookVector
    Controls:Disable()
    local startTime = os.clock()
    local conn
    conn = RunService.RenderStepped:Connect(function()
        if os.clock() - startTime >= seconds then
            conn:Disconnect()
            hum:Move(Vector3.zero, false)
            Controls:Enable()
            return
        end
        hum:Move(lookVector, false)
    end)
end

local function instantClone()
    if _G.isCloning then return end
    _G.isCloning = true

    local ok, err = pcall(function()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not (char and hum) then error("No character") end

        local cloner =
            LocalPlayer.Backpack:FindFirstChild("Quantum Cloner")
            or char:FindFirstChild("Quantum Cloner")

        if not cloner then error("No Quantum Cloner") end

        pcall(function()
            hum:EquipTool(cloner)
        end)

        cloner:Activate()
        task.wait(0.05)

        local cloneName = tostring(LocalPlayer.UserId) .. "_Clone"
        for _ = 1, 100 do
            if Workspace:FindFirstChild(cloneName) then break end
            task.wait(0.1)
        end

        if not Workspace:FindFirstChild(cloneName) then return end

        local tpButton = nil
        for _ = 1, 20 do
            local toolsFrames = LocalPlayer.PlayerGui:FindFirstChild("ToolsFrames")
            local qcFrame = toolsFrames and toolsFrames:FindFirstChild("QuantumCloner")
            local btn = qcFrame and qcFrame:FindFirstChild("TeleportToClone")
            if btn then tpButton = btn; break end
            task.wait(0.05)
        end
        if not tpButton then error("Teleport button missing") end

        tpButton.Visible = true

        if firesignal then
            firesignal(tpButton.MouseButton1Up)
        else
            local vim = cloneref and cloneref(game:GetService("VirtualInputManager")) or VirtualInputManager
            local inset = (cloneref and cloneref(game:GetService("GuiService")) or GuiService):GetGuiInset()
            local pos = tpButton.AbsolutePosition + (tpButton.AbsoluteSize / 2) + inset

            vim:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 1)
            task.wait()
            vim:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 1)
        end
    end)

    _G.isCloning = false
end

local function triggerClosestUnlock(yLevel, maxY)
    local character = LocalPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local playerY = yLevel or hrp.Position.Y
    local Y_THRESHOLD = 5

    local bestPromptSameLevel = nil
    local shortestDistSameLevel = math.huge

    local bestPromptFallback = nil
    local shortestDistFallback = math.huge
    
    local plots = Workspace:FindFirstChild("Plots")
    if not plots then return end

    for _, obj in ipairs(plots:GetDescendants()) do
        if obj:IsA("ProximityPrompt") and obj.Enabled then
            local part = obj.Parent
            if part and part:IsA("BasePart") then
                if maxY and part.Position.Y > maxY then
                else
                    local distance = (hrp.Position - part.Position).Magnitude
                    local yDifference = math.abs(playerY - part.Position.Y)

                    if distance < shortestDistFallback then
                        shortestDistFallback = distance
                        bestPromptFallback = obj
                    end

                    if yDifference <= Y_THRESHOLD then
                        if distance < shortestDistSameLevel then
                            shortestDistSameLevel = distance
                            bestPromptSameLevel = obj
                        end
                    end
                end
            end
        end
    end

    local targetPrompt = bestPromptSameLevel or bestPromptFallback

    if targetPrompt then
        if fireproximityprompt then
            fireproximityprompt(targetPrompt)
        else
            targetPrompt:InputBegan(Enum.UserInputType.MouseButton1)
            task.wait(0.05)
            targetPrompt:InputEnded(Enum.UserInputType.MouseButton1)
        end
    end
end

local Theme = {
    Background      = Color3.fromRGB(18, 8, 38),
    Surface         = Color3.fromRGB(25, 10, 55),
    SurfaceHighlight= Color3.fromRGB(45, 15, 85),
    Accent1         = Color3.fromRGB(180, 50, 255),
    Accent2         = Color3.fromRGB(130, 0, 220),
    TextPrimary     = Color3.fromRGB(240, 240, 240),
    TextSecondary   = Color3.fromRGB(200, 170, 230),
    Success         = Color3.fromRGB(180, 50, 255),
    Error           = Color3.fromRGB(210, 90, 90),
}

THEMES = {
    preto = {
        Background       = Color3.fromRGB(18, 8, 38),
        Surface          = Color3.fromRGB(25, 10, 55),
        SurfaceHighlight = Color3.fromRGB(45, 15, 85),
        Accent1          = Color3.fromRGB(180, 50, 255),
        Accent2          = Color3.fromRGB(130, 0, 220),
        TextPrimary      = Color3.fromRGB(240, 240, 240),
        TextSecondary    = Color3.fromRGB(200, 170, 230),
        Success          = Color3.fromRGB(180, 50, 255),
        Error            = Color3.fromRGB(210, 90, 90),
        GlowColor1       = Color3.fromRGB(180, 50, 255),
        GlowColor2       = Color3.fromRGB(130, 0, 220),
    },
    cyan = {
        Background       = Color3.fromRGB(8, 18, 28),
        Surface          = Color3.fromRGB(10, 25, 40),
        SurfaceHighlight = Color3.fromRGB(15, 45, 65),
        Accent1          = Color3.fromRGB(50, 200, 255),
        Accent2          = Color3.fromRGB(0, 150, 210),
        TextPrimary      = Color3.fromRGB(240, 240, 240),
        TextSecondary    = Color3.fromRGB(170, 210, 230),
        Success          = Color3.fromRGB(50, 200, 255),
        Error            = Color3.fromRGB(210, 90, 90),
        GlowColor1       = Color3.fromRGB(50, 200, 255),
        GlowColor2       = Color3.fromRGB(0, 150, 210),
    },
    pink = {
        Background       = Color3.fromRGB(28, 8, 18),
        Surface          = Color3.fromRGB(40, 10, 28),
        SurfaceHighlight = Color3.fromRGB(65, 15, 45),
        Accent1          = Color3.fromRGB(255, 80, 180),
        Accent2          = Color3.fromRGB(210, 40, 140),
        TextPrimary      = Color3.fromRGB(240, 240, 240),
        TextSecondary    = Color3.fromRGB(230, 170, 210),
        Success          = Color3.fromRGB(255, 80, 180),
        Error            = Color3.fromRGB(210, 90, 90),
        GlowColor1       = Color3.fromRGB(255, 80, 180),
        GlowColor2       = Color3.fromRGB(210, 40, 140),
    },
    gold = {
        Background       = Color3.fromRGB(22, 16, 4),
        Surface          = Color3.fromRGB(32, 22, 6),
        SurfaceHighlight = Color3.fromRGB(55, 38, 10),
        Accent1          = Color3.fromRGB(255, 200, 50),
        Accent2          = Color3.fromRGB(210, 160, 20),
        TextPrimary      = Color3.fromRGB(240, 240, 240),
        TextSecondary    = Color3.fromRGB(230, 210, 160),
        Success          = Color3.fromRGB(255, 200, 50),
        Error            = Color3.fromRGB(210, 90, 90),
        GlowColor1       = Color3.fromRGB(255, 200, 50),
        GlowColor2       = Color3.fromRGB(210, 160, 20),
    },
    green = {
        Background       = Color3.fromRGB(8, 20, 12),
        Surface          = Color3.fromRGB(10, 30, 16),
        SurfaceHighlight = Color3.fromRGB(15, 52, 28),
        Accent1          = Color3.fromRGB(50, 220, 120),
        Accent2          = Color3.fromRGB(20, 170, 80),
        TextPrimary      = Color3.fromRGB(240, 240, 240),
        TextSecondary    = Color3.fromRGB(170, 230, 190),
        Success          = Color3.fromRGB(50, 220, 120),
        Error            = Color3.fromRGB(210, 90, 90),
        GlowColor1       = Color3.fromRGB(50, 220, 120),
        GlowColor2       = Color3.fromRGB(20, 170, 80),
    },
    red = {
        Background       = Color3.fromRGB(26, 8, 8),
        Surface          = Color3.fromRGB(40, 10, 10),
        SurfaceHighlight = Color3.fromRGB(70, 16, 16),
        Accent1          = Color3.fromRGB(255, 70, 70),
        Accent2          = Color3.fromRGB(200, 30, 30),
        TextPrimary      = Color3.fromRGB(245, 240, 240),
        TextSecondary    = Color3.fromRGB(230, 180, 180),
        Success          = Color3.fromRGB(255, 70, 70),
        Error            = Color3.fromRGB(255, 90, 90),
        GlowColor1       = Color3.fromRGB(255, 70, 70),
        GlowColor2       = Color3.fromRGB(200, 30, 30),
    },
    orange = {
        Background       = Color3.fromRGB(26, 14, 4),
        Surface          = Color3.fromRGB(40, 22, 6),
        SurfaceHighlight = Color3.fromRGB(70, 40, 12),
        Accent1          = Color3.fromRGB(255, 140, 40),
        Accent2          = Color3.fromRGB(220, 100, 20),
        TextPrimary      = Color3.fromRGB(245, 240, 235),
        TextSecondary    = Color3.fromRGB(235, 205, 170),
        Success          = Color3.fromRGB(255, 140, 40),
        Error            = Color3.fromRGB(210, 90, 90),
        GlowColor1       = Color3.fromRGB(255, 140, 40),
        GlowColor2       = Color3.fromRGB(220, 100, 20),
    },
    ocean = {
        Background       = Color3.fromRGB(6, 14, 26),
        Surface          = Color3.fromRGB(8, 22, 42),
        SurfaceHighlight = Color3.fromRGB(14, 40, 72),
        Accent1          = Color3.fromRGB(60, 130, 255),
        Accent2          = Color3.fromRGB(30, 90, 210),
        TextPrimary      = Color3.fromRGB(238, 242, 250),
        TextSecondary    = Color3.fromRGB(175, 195, 230),
        Success          = Color3.fromRGB(60, 130, 255),
        Error            = Color3.fromRGB(210, 90, 90),
        GlowColor1       = Color3.fromRGB(60, 130, 255),
        GlowColor2       = Color3.fromRGB(30, 90, 210),
    },
    white = {
        Background       = Color3.fromRGB(18, 18, 22),
        Surface          = Color3.fromRGB(28, 28, 34),
        SurfaceHighlight = Color3.fromRGB(48, 48, 56),
        Accent1          = Color3.fromRGB(235, 235, 245),
        Accent2          = Color3.fromRGB(170, 170, 185),
        TextPrimary      = Color3.fromRGB(245, 245, 248),
        TextSecondary    = Color3.fromRGB(185, 185, 195),
        Success          = Color3.fromRGB(235, 235, 245),
        Error            = Color3.fromRGB(210, 90, 90),
        GlowColor1       = Color3.fromRGB(235, 235, 245),
        GlowColor2       = Color3.fromRGB(170, 170, 185),
    },
    dawg = {
        Background       = Color3.fromRGB(20, 13, 11),
        Surface          = Color3.fromRGB(34, 19, 17),
        SurfaceHighlight = Color3.fromRGB(60, 26, 24),
        Accent1          = Color3.fromRGB(196, 42, 38),
        Accent2          = Color3.fromRGB(142, 24, 22),
        TextPrimary      = Color3.fromRGB(246, 236, 232),
        TextSecondary    = Color3.fromRGB(226, 184, 174),
        Success          = Color3.fromRGB(196, 42, 38),
        Error            = Color3.fromRGB(255, 95, 95),
        GlowColor1       = Color3.fromRGB(196, 42, 38),
        GlowColor2       = Color3.fromRGB(142, 24, 22),
    },
    custom = {
        Background       = Color3.fromRGB(18, 8, 38),
        Surface          = Color3.fromRGB(25, 10, 55),
        SurfaceHighlight = Color3.fromRGB(45, 15, 85),
        Accent1          = Color3.fromRGB(180, 50, 255),
        Accent2          = Color3.fromRGB(130, 0, 220),
        TextPrimary      = Color3.fromRGB(240, 240, 240),
        TextSecondary    = Color3.fromRGB(200, 170, 230),
        Success          = Color3.fromRGB(180, 50, 255),
        Error            = Color3.fromRGB(210, 90, 90),
        GlowColor1       = Color3.fromRGB(180, 50, 255),
        GlowColor2       = Color3.fromRGB(130, 0, 220),
    },
}

-- Dawg theme background image.
-- Preferred: DAWG_IMAGE_URL - a DIRECT png/jpg link. When the dawg theme is applied the
-- executor downloads the bytes once (writefile + getcustomasset) and renders that, which
-- avoids Roblox upload moderation entirely. Upload the dog picture to the hub's GitHub repo
-- (or any direct-link host) and put that raw link here.
-- Fallback: DAWG_IMAGE_ASSET - a Roblox IMAGE asset id, used only if the URL is blank or the
-- download fails.
DAWG_IMAGE_URL   = "https://raw.githubusercontent.com/Lebonbon3-5/StealABrainrot/refs/heads/main/dawg.png"
DAWG_IMAGE_ASSET = "rbxassetid://85709371910705"
_G.JAF_DawgResolved = _G.JAF_DawgResolved or nil  -- cached rbxasset:// once downloaded
_G.JAF_DawgActive   = _G.JAF_DawgActive or false  -- true while the dawg theme is the active one

-- Resolve the dawg background to something Roblox can render. Tries the downloaded URL
-- first (cached after the first success), then the asset id. May yield (downloads), so
-- only call from inside a task.spawn/defer.
function resolveDawgImage()
    if _G.JAF_DawgResolved then return _G.JAF_DawgResolved end
    if type(DAWG_IMAGE_URL) == "string" and DAWG_IMAGE_URL ~= "" and jafDownloadWebImage then
        local asset = jafDownloadWebImage(DAWG_IMAGE_URL)
        if asset then _G.JAF_DawgResolved = asset; return asset end
    end
    if type(DAWG_IMAGE_ASSET) == "string" and DAWG_IMAGE_ASSET ~= "" then
        _G.JAF_DawgResolved = DAWG_IMAGE_ASSET
        return DAWG_IMAGE_ASSET
    end
    return nil
end

-- Build the "custom" theme from a hex accent color (e.g. "B432FF" or "#b432ff").
-- The accent drives the whole palette: a darkened tint becomes the background/surfaces
-- so any accent the user picks produces a coherent dark theme. Returns true on success.
function buildCustomThemeFromColor(accent)
    if typeof(accent) ~= "Color3" then return false end
    local r, g, b = accent.R * 255, accent.G * 255, accent.B * 255
    local accent2 = Color3.fromRGB(math.floor(r * 0.72), math.floor(g * 0.72), math.floor(b * 0.72))
    local function tint(f) return Color3.fromRGB(
        math.clamp(math.floor(r * f) + 6, 0, 255),
        math.clamp(math.floor(g * f) + 4, 0, 255),
        math.clamp(math.floor(b * f) + 10, 0, 255)) end
    THEMES.custom = {
        Background       = tint(0.06),
        Surface          = tint(0.10),
        SurfaceHighlight = tint(0.20),
        Accent1          = accent,
        Accent2          = accent2,
        TextPrimary      = Color3.fromRGB(240, 240, 240),
        TextSecondary    = Color3.fromRGB(
            math.clamp(math.floor(170 + r * 0.28), 0, 255),
            math.clamp(math.floor(170 + g * 0.28), 0, 255),
            math.clamp(math.floor(180 + b * 0.24), 0, 255)),
        Success          = accent,
        Error            = Color3.fromRGB(210, 90, 90),
        GlowColor1       = accent,
        GlowColor2       = accent2,
    }
    return true
end

function buildCustomThemeFromHex(hex)
    if type(hex) ~= "string" then return false end
    hex = hex:gsub("#", ""):gsub("%s", "")
    if #hex ~= 6 then return false end
    local r = tonumber(hex:sub(1, 2), 16)
    local g = tonumber(hex:sub(3, 4), 16)
    local b = tonumber(hex:sub(5, 6), 16)
    if not (r and g and b) then return false end
    return buildCustomThemeFromColor(Color3.fromRGB(r, g, b))
end
-- Seed the custom theme from the saved hex so it's ready before any UI / theme apply.
pcall(buildCustomThemeFromHex, Config.CustomThemeHex)

-- â”€â”€ Web-image themes â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Roblox can't load http(s) image URLs directly, but in an executor we can download
-- the bytes, save them, and hand the file to getcustomasset() which returns an
-- rbxasset:// path Roblox WILL render. We also read the pixels (EditableImage) to pull
-- the image's average colour and drive the whole theme from it. Everything is pcall-
-- guarded so a missing API / bad URL can never break the hub.
local AssetService = game:GetService("AssetService")
_G.JAF_ThemeImageAsset = _G.JAF_ThemeImageAsset or nil

local function jafHttpRequest(url)
    local req = (syn and syn.request) or (http and http.request) or http_request or request or fluxus and fluxus.request
    if not req then return nil end
    local ok, res = pcall(req, { Url = url, Method = "GET" })
    if ok and res and (res.Body or res.body) then return res.Body or res.body end
    return nil
end

local function jafGetCustomAsset(fileName)
    local getter = getcustomasset or getsynasset or (syn and syn.getcustomasset)
    if not getter then return nil end
    local ok, asset = pcall(getter, fileName)
    if ok and asset then return asset end
    return nil
end

-- Download a web image URL -> usable rbxasset:// content string.
-- Returns (asset, reason). The file MUST be saved with a real image extension
-- Roblox recognises (png/jpg/...) - saving as ".img" was why nothing rendered.
-- Roblox cannot decode WebP, so a *.webp URL is auto-retried without the .webp
-- suffix (BBC/CDN links like "...jpg.webp" usually still serve the real jpg).
function jafDownloadWebImage(url)
    if type(url) ~= "string" or not url:match("^https?://") then return nil, "not a valid http URL" end
    if not writefile then return nil, "executor has no writefile" end

    local function extFor(u)
        local clean = u:gsub("%?.*$", ""):gsub("#.*$", "")
        local e = clean:match("%.([%a%d]+)$")
        e = e and e:lower() or "png"
        if e ~= "png" and e ~= "jpg" and e ~= "jpeg" and e ~= "tga" and e ~= "bmp" and e ~= "webp" then e = "png" end
        return e
    end

    -- Build the list of URLs to try, in order. WebP can't render in Roblox, so if
    -- the URL ends in .webp we first try the same URL with .webp stripped.
    local tries = {}
    local lower = url:lower()
    if lower:match("%.webp$") then
        table.insert(tries, url:gsub("%.[Ww][Ee][Bb][Pp]$", "")) -- "...jpg.webp" -> "...jpg"
    end
    table.insert(tries, url)

    local lastReason = "download failed"
    for _, u in ipairs(tries) do
        local ext = extFor(u)
        if ext == "webp" then
            lastReason = "WebP images aren't supported by Roblox - use a .png or .jpg link"
        else
            local body = jafHttpRequest(u)
            if not body then
                lastReason = "couldn't download (executor request blocked?)"
            elseif #body < 64 then
                lastReason = "downloaded file was empty"
            else
                local fname = "JustAFanThemeBG." .. ext
                local okW = pcall(writefile, fname, body)
                if not okW then
                    lastReason = "writefile failed"
                else
                    local asset = jafGetCustomAsset(fname)
                    if asset then return asset end
                    lastReason = "executor has no getcustomasset"
                end
            end
        end
    end
    return nil, lastReason
end

-- Average colour of an image asset via EditableImage pixel read (sparse sampled).
function jafImageAverageColor(assetUri)
    local ok, col = pcall(function()
        local img
        -- try the modern Content-based signature first, then the legacy id signature
        local okA = pcall(function() img = AssetService:CreateEditableImageAsync(Content.fromUri(assetUri)) end)
        if not okA or not img then img = AssetService:CreateEditableImageAsync(assetUri) end
        if not img then return nil end
        local size = img.Size
        local px = img:ReadPixels(Vector2.new(0, 0), size)
        local pixels = math.floor(#px / 4)
        if pixels <= 0 then return nil end
        local stride = math.max(1, math.floor(pixels / 1500))
        local r, g, b, n = 0, 0, 0, 0
        for p = 0, pixels - 1, stride do
            local i = p * 4 + 1
            r = r + px[i]; g = g + px[i + 1]; b = b + px[i + 2]; n = n + 1
        end
        if n == 0 then return nil end
        return Color3.new(r / n, g / n, b / n)
    end)
    if ok and col then return col end
    return nil
end

-- Put a darkened, cropped copy of the image behind a panel frame so the UI stays clean
-- and readable. ZIndex 0 keeps it behind all content; the frame goes more transparent so
-- the image shows through.
local function jafSetPanelImage(frame, assetUri)
    if not frame or not frame:IsA("GuiObject") then return end
    local existing = frame:FindFirstChild("JAFThemeBG")
    if assetUri == nil then
        if existing then existing:Destroy() end
        return
    end
    local img = existing
    if not img then
        img = Instance.new("ImageLabel")
        img.Name = "JAFThemeBG"
        img.BackgroundTransparency = 1
        img.BorderSizePixel = 0
        img.ZIndex = 0
        img.ScaleType = Enum.ScaleType.Crop
        local cor = frame:FindFirstChildOfClass("UICorner")
        local c = Instance.new("UICorner", img)
        c.CornerRadius = cor and cor.CornerRadius or UDim.new(0, 10)
        img.Parent = frame
    end
    img.Size = UDim2.new(1, 0, 1, 0)
    img.Position = UDim2.new(0, 0, 0, 0)
    img.Image = assetUri
    img.ImageTransparency = 0.05
    img.ImageColor3 = Color3.fromRGB(205, 205, 205) -- slight dim so light text stays readable
    pcall(function() frame.ClipsDescendants = true end)
end

local JAF_IMAGE_PANELS = {
    "JustAFanSettings", "AutoStealUI", "JustAFanMiniActions", "JustAFanAutoBuyUI",
    "XiAdminPanel", "JustAFanStatusHUD", "XiStealingHUD", "JustAFanAutoTurret",
    "JustAFanGrabKick", "JustAFanJobJoiner", "JustAFanInvisPanel",
}

-- Apply (or clear, when assetUri is nil) the theme image across all hub panels.
function jafApplyThemeImageToPanels(assetUri)
    for _, gn in ipairs(JAF_IMAGE_PANELS) do
        local sg = PlayerGui:FindFirstChild(gn)
        if sg then
            for _, frame in ipairs(sg:GetChildren()) do
                if frame:IsA("Frame") then
                    if assetUri then frame.BackgroundTransparency = math.max(frame.BackgroundTransparency, 0.6) end
                    pcall(jafSetPanelImage, frame, assetUri)
                end
            end
        end
    end
end

-- Full pipeline: download URL, recolor theme from its average colour, paste it on panels.
-- Returns true on success. Runs the heavy work in a task.spawn so the UI never hangs.
function jafApplyImageTheme(url)
    local asset, reason = jafDownloadWebImage(url)
    if not asset then return false, reason or "download failed" end
    _G.JAF_ThemeImageAsset = asset
    local avg = jafImageAverageColor(asset)
    if avg then
        buildCustomThemeFromColor(avg)
        if applyTheme then applyTheme("custom") end  -- rebuilds panels with new colours
    end
    -- (re)paint the image onto the freshly-built panels
    task.defer(function() pcall(jafApplyThemeImageToPanels, asset) end)
    return true
end

-- Apply the saved theme's colors into the live Theme table NOW, before any UI is built.
-- (The early copy near config-load ran before THEMES existed, so it was a no-op and the
-- UI started on the default purple and only flipped to the saved theme ~1.5s later.)
if Config.CurrentTheme and THEMES[Config.CurrentTheme] then
    for k, v in pairs(THEMES[Config.CurrentTheme]) do Theme[k] = v end
end

-- â”€â”€ Dawg loading screen â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Full-screen splash shown from script load until the first TP fires. IgnoreGuiInset +
-- a top DisplayOrder so it covers the ENTIRE screen, even over the performance-stats HUD
-- and the Roblox topbar inset. _G.JAF_RemoveLoadingScreen() fades + destroys it; the TP
-- entry points (runAutoSnipe / ctpLaunch) call it the instant a teleport starts.
if Config.ShowLoadingScreen ~= false then
    -- Clear any orphaned splash from a previous execution before making a new one,
    -- so re-running the script can never leave a stuck loading screen behind.
    if _G.JAF_RemoveLoadingScreen then pcall(_G.JAF_RemoveLoadingScreen) end
    pcall(function()
        local host = (gethui and gethui()) or PlayerGui
        for _, g in ipairs(host:GetChildren()) do
            if g.Name == "JAFLoadingScreen" then g:Destroy() end
        end
    end)

    local lg = Instance.new("ScreenGui")
    lg.Name = "JAFLoadingScreen"
    lg.ResetOnSpawn = false
    lg.IgnoreGuiInset = true
    lg.DisplayOrder = 2000000000   -- above every other hub GUI (and the topbar)
    lg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    local okHui = pcall(function() lg.Parent = (gethui and gethui()) or PlayerGui end)
    if not okHui or not lg.Parent then lg.Parent = PlayerGui end

    local bg = Instance.new("Frame", lg)
    bg.Size = UDim2.new(1, 0, 1, 36)          -- +36 so it also covers the topbar inset area
    bg.Position = UDim2.new(0, 0, 0, -36)
    bg.BackgroundColor3 = Color3.fromRGB(12, 8, 8)
    bg.BackgroundTransparency = 0
    bg.BorderSizePixel = 0
    bg.ZIndex = 1

    local img = Instance.new("ImageLabel", bg)
    img.AnchorPoint = Vector2.new(0.5, 0.5)
    img.Position = UDim2.new(0.5, 0, 0.4, 0)
    img.Size = UDim2.new(0, 300, 0, 300)
    img.BackgroundTransparency = 1
    img.ScaleType = Enum.ScaleType.Fit
    img.Image = DAWG_IMAGE_ASSET or ""
    img.ZIndex = 2
    Instance.new("UICorner", img).CornerRadius = UDim.new(0, 18)

    local title = Instance.new("TextLabel", bg)
    title.AnchorPoint = Vector2.new(0.5, 0.5)
    title.Position = UDim2.new(0.5, 0, 0.73, 0)
    title.Size = UDim2.new(1, -40, 0, 48)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBlack
    title.TextSize = 36
    title.TextColor3 = Color3.fromRGB(246, 236, 232)
    title.Text = "Sammydawg is loading"
    title.ZIndex = 2

    local disc = Instance.new("TextLabel", bg)
    disc.AnchorPoint = Vector2.new(0.5, 0.5)
    disc.Position = UDim2.new(0.5, 0, 0.8, 0)
    disc.Size = UDim2.new(1, -40, 0, 28)
    disc.BackgroundTransparency = 1
    disc.Font = Enum.Font.GothamBold
    disc.TextSize = 20
    disc.TextColor3 = Color3.fromRGB(196, 42, 38)
    disc.Text = "discord.gg/XY4jvXrn"
    disc.ZIndex = 2

    -- animated "loading..." dots
    task.spawn(function()
        local n = 0
        while lg.Parent do
            n = (n % 3) + 1
            title.Text = "Sammydawg is loading" .. string.rep(".", n)
            task.wait(0.4)
        end
    end)

    -- Upgrade the placeholder asset to the downloaded dawg.png (URL first, asset fallback).
    task.spawn(function()
        local asset = resolveDawgImage()
        if asset and asset ~= "" and img and img.Parent then img.Image = asset end
    end)

    local removed = false
    _G.JAF_RemoveLoadingScreen = function()
        if removed then return end
        removed = true
        pcall(function()
            for _, d in ipairs(bg:GetDescendants()) do
                if d:IsA("ImageLabel") then
                    TweenService:Create(d, TweenInfo.new(0.35), {ImageTransparency = 1}):Play()
                elseif d:IsA("TextLabel") then
                    TweenService:Create(d, TweenInfo.new(0.35), {TextTransparency = 1}):Play()
                end
            end
            local fade = TweenService:Create(bg, TweenInfo.new(0.35), {BackgroundTransparency = 1})
            fade:Play()
            fade.Completed:Wait()
        end)
        pcall(function() lg:Destroy() end)
    end

    -- Safety net: never let the splash stay stuck if no TP ever fires. Call the LOCAL
    -- remove (not the global, which a later re-run may have reassigned to another splash).
    task.delay(4, _G.JAF_RemoveLoadingScreen)
end

-- â”€â”€ Unified panel styling â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Every hub window is built inline in its own block, so historically they each
-- ended up with slightly different corner radii (8/10/12/14), border thickness,
-- background translucency and accent colours. This pass gives them ONE cohesive
-- identity. It is PURELY cosmetic - it only touches the root frame's corner,
-- border stroke and background transparency. It never changes sizes, positions,
-- headers or child layouts, so it can't break any panel.
-- Flat & minimal: sharp-ish corners, thin solid border, mostly-solid background,
-- and NO animated glow (the racetrack border is stripped below).
JAF_STYLE = {
    PanelCorner        = 8,
    PanelBgTransparency = 0.10,
    StrokeThickness    = 1,
    StrokeTransparency = 0.35,
}

-- {ScreenGui name, optional root-frame name}. nil name = first Frame child.
local JAF_STYLE_TARGETS = {
    {"XiAdminPanel"},
    {"AutoStealUI"},
    {"SettingsUI"},
    {"JustAFanSettings", "MainPanel"},
    {"JustAFanStatusHUD", "Main"},
    {"JustAFanMiniActions", "MiniPanel"},
    {"JustAFanAutoBuyUI", "ABPanel"},
    {"JustAFanThemeUI", "ThemePanel"},
    {"JustAFanJobJoiner", "Main"},
    {"JustAFanInvisPanel"},
    {"XiStealingHUD"},
    {"PriorityListGUI"},
    {"JustAFanAutoTurret"},
    {"JustAFanGrabKick"},
}

local function jafStyleOnePanel(frame)
    if not frame or not frame:IsA("GuiObject") then return end
    local cor = frame:FindFirstChildOfClass("UICorner")
    if not cor then cor = Instance.new("UICorner", frame) end
    cor.CornerRadius = UDim.new(0, JAF_STYLE.PanelCorner)
    -- Don't re-solidify the background while an image theme is active (the image needs
    -- the panel translucent to show through). Otherwise make it mostly-solid + flat.
    if frame.BackgroundTransparency < 1 and not (_G.JAF_ThemeImageAsset and frame:FindFirstChild("JAFThemeBG")) then
        frame.BackgroundColor3 = Theme.Background
        frame.BackgroundTransparency = JAF_STYLE.PanelBgTransparency
    end
    -- Flat look: strip the animated rainbow "RacetrackBorder" glow entirely and keep
    -- one thin, solid border. Destroying the stroke auto-ends its Heartbeat loop
    -- (it bails when stroke.Parent is nil) and removes no content/layout.
    local stroke
    for _, ch in ipairs(frame:GetChildren()) do
        if ch:IsA("UIStroke") then
            if ch.Name == "RacetrackBorder" then
                ch:Destroy()
            elseif not stroke then
                stroke = ch
            end
        end
    end
    if not stroke then stroke = Instance.new("UIStroke", frame) end
    -- solid border (drop any gradient child so it reads flat, not two-tone)
    local g = stroke:FindFirstChildOfClass("UIGradient")
    if g then g:Destroy() end
    stroke.Color = Theme.Accent1
    stroke.Thickness = JAF_STYLE.StrokeThickness
    stroke.Transparency = JAF_STYLE.StrokeTransparency
end

function jafUnifyPanelStyle()
    for _, t in ipairs(JAF_STYLE_TARGETS) do
        local sg = PlayerGui:FindFirstChild(t[1])
        if sg then
            local frame = t[2] and sg:FindFirstChild(t[2]) or nil
            if not frame then frame = sg:FindFirstChildWhichIsA("Frame") end
            if frame then pcall(jafStyleOnePanel, frame) end
        end
    end
end

function applyTheme(themeName)
    local t = THEMES[themeName]
    if not t then return end

    local colorMap = {}
    for k, oldColor in pairs(Theme) do
        if t[k] then colorMap[oldColor] = t[k] end
    end

    for k, v in pairs(t) do
        Theme[k] = v
    end
    Config.CurrentTheme = themeName
    SaveConfig()

    local function matchColor(c1, c2)
        if not c1 or not c2 then return false end
        local dr = math.abs(c1.R - c2.R)
        local dg = math.abs(c1.G - c2.G)
        local db = math.abs(c1.B - c2.B)
        return (dr + dg + db) < 0.04
    end

    local function remapColor(c)
        if not c then return c end
        for oldC, newC in pairs(colorMap) do
            if matchColor(c, oldC) then return newC end
        end
        return c
    end

    local guiNames = {
        "AutoStealUI", "XiAdminPanel", "SettingsUI",
        "JustAFanStatusHUD", "JustAFanNotif",
        "JustAFanThemeUI", "PriorityListGUI", "JustAFanJobJoiner", "JustAFanPriorityAlert",
        "JustAFanSettings", "JustAFanAutoTurret", "JustAFanGrabKick", "XiStealingHUD"
    }

    for _, guiName in ipairs(guiNames) do
        local sg = PlayerGui:FindFirstChild(guiName)
        if sg then
            for _, obj in ipairs(sg:GetDescendants()) do
                pcall(function()
                    if obj:IsA("Frame") or obj:IsA("TextButton") or
                       obj:IsA("TextBox") or obj:IsA("ScrollingFrame") or
                       obj:IsA("ImageLabel") then
                        if obj.BackgroundTransparency < 1 then obj.BackgroundColor3 = remapColor(obj.BackgroundColor3) end
                    end
                    if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then obj.TextColor3 = remapColor(obj.TextColor3) end
                    if obj:IsA("UIStroke") then obj.Color = remapColor(obj.Color) end
                    if obj:IsA("ScrollingFrame") then obj.ScrollBarImageColor3 = remapColor(obj.ScrollBarImageColor3) end
                    if obj:IsA("UIGradient") then
                        local kps = obj.Color.Keypoints
                        local changed = false
                        local newKps = {}
                        for _, kp in ipairs(kps) do
                            local nc = remapColor(kp.Value)
                            if nc ~= kp.Value then changed = true end
                            table.insert(newKps, ColorSequenceKeypoint.new(kp.Time, nc))
                        end
                        if changed then obj.Color = ColorSequence.new(newKps) end
                    end
                    if obj:IsA("Beam") then
                        local kps = obj.Color.Keypoints
                        local newKps = {}
                        for _, kp in ipairs(kps) do
                            table.insert(newKps, ColorSequenceKeypoint.new(kp.Time, remapColor(kp.Value)))
                        end
                        obj.Color = ColorSequence.new(newKps)
                    end
                end)
            end
            pcall(function()
                local root = sg:FindFirstChildWhichIsA("Frame")
                if root and root.BackgroundTransparency < 1 then root.BackgroundColor3 = remapColor(root.BackgroundColor3) end
            end)
        end
    end

    task.spawn(function()
        local savedTab  = (_G.JustAFanSettingsUI and _G.JustAFanSettingsUI.currentTab) or "cfg"
        local wasVis    = _G.JustAFanSettingsUI and _G.JustAFanSettingsUI.panel and _G.JustAFanSettingsUI.panel.Visible
        if buildJustAFanSettingsUI then buildJustAFanSettingsUI() end
        task.wait()
        if _G.JustAFanSettingsUI then
            if _G.JustAFanSettingsUI.switchTab then _G.JustAFanSettingsUI.switchTab(savedTab) end
            if wasVis and _G.JustAFanSettingsUI.panel then _G.JustAFanSettingsUI.panel.Visible = true end
        end
        if _G.jafRebuildStatusHUD then _G.jafRebuildStatusHUD() end
        if _G.updateAutoBuyRingColor then _G.updateAutoBuyRingColor() end
        if _G.rebuildAutoBuyCirclePresets then _G.rebuildAutoBuyCirclePresets() end
        if jafUnifyPanelStyle then task.defer(function() pcall(jafUnifyPanelStyle) end) end
        -- Dawg theme: paste the dog image behind every panel. For any other theme, clear the
        -- dawg image (but leave a user-set URL image alone). Deferred so it lands AFTER the
        -- panel rebuild + unify above, otherwise the rebuild would wipe the pasted image.
        do
            if themeName == "dawg" then
                _G.JAF_DawgActive = true
                if jafApplyThemeImageToPanels then
                    task.defer(function()
                        local asset = resolveDawgImage()
                        if asset and asset ~= "" then
                            _G.JAF_ThemeImageAsset = asset
                            pcall(jafApplyThemeImageToPanels, asset)
                        end
                    end)
                end
            elseif _G.JAF_DawgActive and not (Config.ThemeImageUrl and Config.ThemeImageUrl ~= "") then
                _G.JAF_DawgActive = false
                _G.JAF_ThemeImageAsset = nil
                if jafApplyThemeImageToPanels then
                    task.defer(function() pcall(jafApplyThemeImageToPanels, nil) end)
                end
            end
        end
        if buildJustAFanMiniActionsUI then
            local miniWasVis = _G.JustAFanMiniActionsUI and _G.JustAFanMiniActionsUI.panel and _G.JustAFanMiniActionsUI.panel.Visible
            buildJustAFanMiniActionsUI()
            task.wait()
            if miniWasVis and _G.JustAFanMiniActionsUI and _G.JustAFanMiniActionsUI.panel then _G.JustAFanMiniActionsUI.panel.Visible = true end
        end

        local guisRT = {"AutoStealUI","XiAdminPanel","SettingsUI","JustAFanSettings","JustAFanStatusHUD","JustAFanAutoBuyUI","JustAFanMiniActions","JustAFanAutoTurret","JustAFanGrabKick","XiStealingHUD"}
        for _, gn in ipairs(guisRT) do
            local sg = PlayerGui:FindFirstChild(gn)
            if sg then
                for _, obj in ipairs(sg:GetDescendants()) do
                    if obj.Name == "RacetrackBorder" and obj:IsA("UIStroke") then
                        local g2 = obj:FindFirstChildOfClass("UIGradient")
                        if g2 then
                            g2.Color = ColorSequence.new{
                                ColorSequenceKeypoint.new(0, Theme.Accent1),
                                ColorSequenceKeypoint.new(1, Theme.Accent2),
                            }
                            g2.Rotation = 0
                            obj.Color = Theme.Accent1
                        end
                    end
                end
            end
        end
    end)

    if ShowNotification then ShowNotification("THEME", "Theme " .. themeName .. " applied!") end
end

function addRacetrackBorder(parentFrame, speed)
    if not parentFrame or not parentFrame:IsA("Frame") then return end
    local CYAN_A = Color3.fromRGB(170, 170, 170)
    local CYAN_B = Color3.fromRGB(125, 125, 125)
    speed = tonumber(speed) or 2.8

    local stroke = Instance.new("UIStroke")
    stroke.Name = "RacetrackBorder"
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Thickness  = 1.6
    stroke.Color      = Color3.new(1, 1, 1)
    stroke.Transparency = 0.14
    stroke.Parent = parentFrame

    local grad = Instance.new("UIGradient")
    grad.Color = ColorSequence.new{
        ColorSequenceKeypoint.new(0.00, CYAN_A),
        ColorSequenceKeypoint.new(0.20, CYAN_B),
        ColorSequenceKeypoint.new(0.50, CYAN_A),
        ColorSequenceKeypoint.new(0.80, CYAN_B),
        ColorSequenceKeypoint.new(1.00, CYAN_A),
    }
    grad.Rotation = 0
    grad.Parent   = stroke

    local t0 = tick()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not parentFrame.Parent or not stroke.Parent or not grad.Parent then
            if conn then conn:Disconnect() end
            return
        end
        local t = tick() - t0
        local p = (t / speed) % 1
        grad.Rotation = (p * 360)
        stroke.Transparency = 0.12 + (math.sin(t * 4.2) + 1) * 0.5 * 0.16
    end)

    return stroke
end

local PRIORITY_LIST = {"Headless Horseman","Signore Carapace","Elefanto Frigo","Arcadragon","Strawberry Elephant","Antonio","John Pork","Meowl","Love Love Bear","Skibidi Toilet","Ginger Gerat","Griffin","Dragon Gingerini","Fishino Clownino","La Supreme Combinasion","Digi Narwhal","Dragon Cannelloni","Hydra Dragon Cannelloni","Ketupat Bros","La Casa Boo","Hydra Bunny","Duggy Bros","Bunny and Eggy","Cerberus","Celestial Pegasus","Rosey and Teddy","Reinito Sleighito","Capitano Moby","Los Sekolahs","Fragrama and Chocrama","Spooky and Pumpky","Cooki and Milki","La Food Combinasion","Los Amigos","Burguro And Fryuro","Popcuru and Fizzuru","Garama and Madundung","La Secret Combinasion","La Romantic Grande","La Taco Combinasion","Los Spaghettis","Swaggy Bros","Sammyni Fattini","Festive 67","Ketchuru and Musturu","Tang Tang Keletang","Ketupat Kepat","Tictac Sahur","Tralaledon","W or L","Eviledon","Lavadorito Spinito","Spaghetti Tualetti","Foxini Lanternini"}

do
    local saved = Config and Config.PriorityList
    if saved and type(saved) == "table" and #saved > 0 then PRIORITY_LIST = saved end
end

local function savePriorityToConfig()
    Config.PriorityList = {}
    for i, v in ipairs(PRIORITY_LIST) do Config.PriorityList[i] = v end
    SaveConfig()
end


local function CreateGradient(parent)
    local g = Instance.new("UIGradient", parent)
    g.Color = ColorSequence.new{
        ColorSequenceKeypoint.new(0, Theme.Accent2),
        ColorSequenceKeypoint.new(1, Theme.Accent2)
    }
    g.Rotation = 45
    return g
end

local function MakeDraggable(handle, target, saveKey)
    local dragging, dragInput, dragStart, startPos

    handle.InputBegan:Connect(function(input)
        if Config.UILocked then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = target.Position
            
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if saveKey then
                        if not target or not target.Parent then return end
                    local parentSize = target.Parent.AbsoluteSize
                        Config.Positions[saveKey] = {
                            X = target.AbsolutePosition.X / parentSize.X,
                            Y = target.AbsolutePosition.Y / parentSize.Y,
                        }
                        SaveConfig()
                    end
                end
            end)
        end
    end)

    handle.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

local DANGER_TOOLS = {
    ["Boogie Bomb"] = true,
    ["Medusa's Head"] = true,
    ["Body Swap Potion"] = true,
    ["Laser Cape"] = true,
    ["Rainbowrath Sword"] = true,
    ["Gummy Bear"] = true,
}
local function isMobileDevice()
    return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and not UserInputService.MouseEnabled
end
local IS_MOBILE = isMobileDevice()
local function ApplyViewportUIScaleAdmin(targetFrame, _, _, minScale, maxScale)
    if not targetFrame or not IS_MOBILE then return end
    local existing = targetFrame:FindFirstChildOfClass("UIScale")
    if existing then existing:Destroy() end
    local sc = Instance.new("UIScale")
    sc.Parent = targetFrame
    sc.Scale = math.clamp(0.65, minScale or 0.45, maxScale or 0.85)
end
local function AddMobileMinimizeAdmin(frame, labelText)
    if not IS_MOBILE or not frame then return end
    local header = frame:FindFirstChildWhichIsA("Frame")
    if not header then return end
    local minimizeBtn = Instance.new("TextButton")
    minimizeBtn.Size = UDim2.new(0, 26, 0, 26)
    minimizeBtn.Position = UDim2.new(1, -30, 0, 6)
    minimizeBtn.BackgroundColor3 = Theme.SurfaceHighlight
    minimizeBtn.Text = "-"
    minimizeBtn.Font = Enum.Font.GothamBlack
    minimizeBtn.TextSize = 18
    minimizeBtn.TextColor3 = Theme.TextPrimary
    minimizeBtn.AutoButtonColor = false
    minimizeBtn.Parent = header
    Instance.new("UICorner", minimizeBtn).CornerRadius = UDim.new(0, 8)
    local guiParent = frame.Parent
    local restoreBtn = Instance.new("TextButton")
    restoreBtn.Size = UDim2.new(0, 110, 0, 34)
    restoreBtn.Position = UDim2.new(0, 10, 1, -44)
    restoreBtn.BackgroundColor3 = Theme.SurfaceHighlight
    restoreBtn.Text = labelText or "OPEN"
    restoreBtn.Font = Enum.Font.GothamBold
    restoreBtn.TextSize = 12
    restoreBtn.TextColor3 = Theme.TextPrimary
    restoreBtn.Visible = false
    restoreBtn.AutoButtonColor = false
    restoreBtn.Parent = guiParent
    Instance.new("UICorner", restoreBtn).CornerRadius = UDim.new(0, 10)
    MakeDraggable(restoreBtn, restoreBtn)
    minimizeBtn.MouseButton1Click:Connect(function()
        frame.Visible = false
        restoreBtn.Visible = true
    end)
    restoreBtn.MouseButton1Click:Connect(function()
        frame.Visible = true
        restoreBtn.Visible = false
    end)
end

local function ShowNotification(title, text) end

local function isPlayerCharacter(model)
    return Players:GetPlayerFromCharacter(model) ~= nil
end

local function handleAnimator(animator)
    local model = animator:FindFirstAncestorOfClass("Model")
    if model and isPlayerCharacter(model) then return end
    for _, track in pairs(animator:GetPlayingAnimationTracks()) do track:Stop(0) end
    animator.AnimationPlayed:Connect(function(track) track:Stop(0) end)
end

local function stripVisuals(obj)
    local model = obj:FindFirstAncestorOfClass("Model")
    local isPlayer = model and isPlayerCharacter(model)

    if obj:IsA("Animator") then handleAnimator(obj) end

    if obj:IsA("Accessory") or obj:IsA("Clothing") then
        if obj:FindFirstAncestorOfClass("Model") then obj:Destroy() end
    end

    if not isPlayer then
        if obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam") or 
           obj:IsA("Smoke") or obj:IsA("Fire") or obj:IsA("Sparkles") or 
           obj:IsA("Highlight") then
            obj.Enabled = false
        end
        if obj:IsA("Explosion") then obj:Destroy() end
    end

    if obj:IsA("BasePart") then obj.CastShadow = false end
end

local fpsBoostState = {
    enabled = false,
    original = nil,
    effectStates = {},
    atmosphereStates = {},
    descendantConn = nil,
}

local function setFPSBoost(enabled)
    Config.FPSBoost = enabled
    SaveConfig()
    if enabled then
        if not fpsBoostState.original then
            fpsBoostState.original = {
                GlobalShadows = Lighting.GlobalShadows,
                FogEnd = Lighting.FogEnd,
                FogStart = Lighting.FogStart,
                EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
                EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
                Brightness = Lighting.Brightness,
                ClockTime = Lighting.ClockTime,
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
            }
        end

        pcall(function() if setfpscap then setfpscap(9999) end end)
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 1000000
        Lighting.FogStart = 0
        Lighting.EnvironmentDiffuseScale = 0
        Lighting.EnvironmentSpecularScale = 0
        Lighting.Brightness = 1
        
        fpsBoostState.effectStates = {}
        fpsBoostState.atmosphereStates = {}
        for _, v in ipairs(Lighting:GetChildren()) do
            if v:IsA("BloomEffect") or v:IsA("BlurEffect") or v:IsA("ColorCorrectionEffect") or 
               v:IsA("SunRaysEffect") or v:IsA("DepthOfFieldEffect") then
                if v.Name ~= "JustAFanDarkModeCC" then
                    fpsBoostState.effectStates[v] = v.Enabled
                    v.Enabled = false
                end
            elseif v:IsA("Atmosphere") then
                fpsBoostState.atmosphereStates[v] = {
                    Density = v.Density,
                    Haze = v.Haze,
                    Glare = v.Glare,
                }
                v.Density = 0
                v.Haze = 0
                v.Glare = 0
            end
        end

        for _, obj in ipairs(Workspace:GetDescendants()) do
            stripVisuals(obj)
        end

        if fpsBoostState.descendantConn then
            fpsBoostState.descendantConn:Disconnect()
            fpsBoostState.descendantConn = nil
        end
        -- Fires on EVERY instance added to Workspace -- so big spawn bursts (conveyor,
        -- effects, dropped tools) call this back-to-back. Native callback keeps the cost
        -- per add minimal even under the obfuscator VM.
        fpsBoostState.descendantConn = Workspace.DescendantAdded:Connect(LPH_NO_VIRTUALIZE(function(obj)
            if fpsBoostState.enabled then stripVisuals(obj) end
        end))
        fpsBoostState.enabled = true
    else
        fpsBoostState.enabled = false
        if fpsBoostState.descendantConn then
            fpsBoostState.descendantConn:Disconnect()
            fpsBoostState.descendantConn = nil
        end
        if fpsBoostState.original then
            local o = fpsBoostState.original
            Lighting.GlobalShadows = o.GlobalShadows
            Lighting.FogEnd = o.FogEnd
            Lighting.FogStart = o.FogStart
            Lighting.EnvironmentDiffuseScale = o.EnvironmentDiffuseScale
            Lighting.EnvironmentSpecularScale = o.EnvironmentSpecularScale
            Lighting.Brightness = o.Brightness
            Lighting.ClockTime = o.ClockTime
            Lighting.Ambient = o.Ambient
            Lighting.OutdoorAmbient = o.OutdoorAmbient
        end
        for inst, wasEnabled in pairs(fpsBoostState.effectStates) do
            if inst and inst.Parent then inst.Enabled = wasEnabled end
                end
        for inst, state in pairs(fpsBoostState.atmosphereStates) do
            if inst and inst.Parent and state then
                inst.Density = state.Density
                inst.Haze = state.Haze
                inst.Glare = state.Glare
            end
        end
        fpsBoostState.effectStates = {}
        fpsBoostState.atmosphereStates = {}
            end
        end
if Config.FPSBoost then task.spawn(function() task.wait(1); setFPSBoost(true) end) end

local darkModeState = {saved = nil, instances = nil}

local function applyDarkBrightness(brightness)
    brightness = math.clamp(brightness or 0.4, 0, 1)
    Config.DarkBrightness = brightness
    SaveConfig()
    local b = brightness
    Lighting.Brightness           = b * 1.5
    Lighting.ExposureCompensation = -1.5 + (b * 1.8)
    Lighting.Ambient              = Color3.fromRGB(math.floor(10 + b*80), math.floor(10 + b*80), math.floor(15 + b*90))
    Lighting.OutdoorAmbient       = Color3.fromRGB(math.floor(8  + b*70), math.floor(8  + b*70), math.floor(12 + b*80))
    local cc = Lighting:FindFirstChild("JustAFanDarkModeCC")
    if cc then
        cc.Brightness = -0.35 + (b * 0.35)
        cc.Contrast   = 0.1
        cc.Saturation = -0.5 + (b * 0.3)
    end
end

local function setDarkMode(enabled)
    local on = not not enabled
    Config.DarkMode = on
    SaveConfig()
    if not darkModeState.saved then
        darkModeState.saved = {
            Brightness           = Lighting.Brightness,
            ClockTime            = Lighting.ClockTime,
            Ambient              = Lighting.Ambient,
            OutdoorAmbient       = Lighting.OutdoorAmbient,
            FogColor             = Lighting.FogColor,
            FogStart             = Lighting.FogStart,
            FogEnd               = Lighting.FogEnd,
            GlobalShadows        = Lighting.GlobalShadows,
            ExposureCompensation = Lighting.ExposureCompensation,
        }
    end
    if on then
        darkModeState.instances = darkModeState.instances or {Lighting = {}, Terrain = {}}
        if not darkModeState.instances.captured then
            darkModeState.instances.captured = true
            for _, v in ipairs(Lighting:GetChildren()) do
                if v:IsA("Sky") or v:IsA("Atmosphere") then
                    table.insert(darkModeState.instances.Lighting, v:Clone())
                    v:Destroy()
                end
            end
            local terrain = Workspace:FindFirstChildOfClass("Terrain")
            if terrain then
                for _, v in ipairs(terrain:GetChildren()) do
                    if v:IsA("Clouds") then
                        table.insert(darkModeState.instances.Terrain, v:Clone())
                        v:Destroy()
                    end
                end
            end
        end
        Lighting.GlobalShadows = false
        Lighting.ClockTime     = 0
        Lighting.FogColor      = Color3.fromRGB(0, 0, 0)
        Lighting.FogStart      = 0
        Lighting.FogEnd        = 1000000
        local cc = Lighting:FindFirstChild("JustAFanDarkModeCC")
        if not cc then
            cc        = Instance.new("ColorCorrectionEffect")
            cc.Name   = "JustAFanDarkModeCC"
            cc.Parent = Lighting
        end
        cc.TintColor = Color3.fromRGB(180, 190, 255)
        applyDarkBrightness(Config.DarkBrightness or 0.4)
    else
        local cc = Lighting:FindFirstChild("JustAFanDarkModeCC")
        if cc then cc:Destroy() end
        if darkModeState.instances and darkModeState.instances.captured then
            local inst    = darkModeState.instances
            local terrain = Workspace:FindFirstChildOfClass("Terrain")
            for _, v in ipairs(inst.Lighting or {}) do if v then v.Parent = Lighting end end
            if terrain then
                for _, v in ipairs(inst.Terrain or {}) do if v then v.Parent = terrain end end
            end
            inst.Lighting = {}
            inst.Terrain  = {}
            inst.captured = false
        end
        if darkModeState.saved then
            local s = darkModeState.saved
            Lighting.Brightness           = s.Brightness
            Lighting.ClockTime            = s.ClockTime
            Lighting.Ambient              = s.Ambient
            Lighting.OutdoorAmbient       = s.OutdoorAmbient
            Lighting.FogColor             = s.FogColor
            Lighting.FogStart             = s.FogStart
            Lighting.FogEnd               = s.FogEnd
            Lighting.GlobalShadows        = s.GlobalShadows
            Lighting.ExposureCompensation = s.ExposureCompensation
        end
    end
end

if Config.DarkMode then task.spawn(function() task.wait(1); pcall(setDarkMode, true) end) end
local State = {
    ProximityAPActive = false,
    carpetSpeedEnabled = false,
    infiniteJumpEnabled = Config.TpSettings.InfiniteJump,
    
    antiRagdollMode = Config.AntiRagdoll or 0,
    isTpMoving = false,
    manualTargetEnabled = false,
}

local ProximityAPActive = false
local Connections = {
    carpetSpeedConnection = nil,
    infiniteJumpConnection = nil,
    _ijInputBegan = nil,
    _ijInputEnded = nil,
    
    antiRagdollConn = nil,
    antiRagdollV2Task = nil,
}
local UI = {
    carpetStatusLabel = nil,
    settingsGui = nil,
}
local carpetSpeedEnabled = State.carpetSpeedEnabled
local carpetSpeedConnection = Connections.carpetSpeedConnection
local _carpetStatusLabel = UI.carpetStatusLabel

local function setCarpetSpeed(enabled)
    State.carpetSpeedEnabled = enabled
    carpetSpeedEnabled = State.carpetSpeedEnabled
    if Connections.carpetSpeedConnection then Connections.carpetSpeedConnection:Disconnect(); Connections.carpetSpeedConnection = nil end
    carpetSpeedConnection = Connections.carpetSpeedConnection
    if not enabled then return end

    if SharedState.DisableStealSpeed then SharedState.DisableStealSpeed() end

    Connections.carpetSpeedConnection = RunService.Heartbeat:Connect(function()
    carpetSpeedConnection = Connections.carpetSpeedConnection
        if _G._ctpRunning then return end  -- clone TP active: don't touch tools
        local c = LocalPlayer.Character
        if not c then return end
        local hum = c:FindFirstChild("Humanoid")
        local hrp = c:FindFirstChild("HumanoidRootPart")
        if not hum or not hrp then return end

        local toolName = Config.TpSettings.Tool
        local hasTool = c:FindFirstChild(toolName)
        
        if not hasTool then
            local tb = LocalPlayer.Backpack:FindFirstChild(toolName)
            if tb then hum:EquipTool(tb) end
        end

        if hasTool then
            local md = hum.MoveDirection
            if md.Magnitude > 0 then
                hrp.AssemblyLinearVelocity = Vector3.new(
                    md.X * 120,
                    hrp.AssemblyLinearVelocity.Y,
                    md.Z * 120
                )
            else
                hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
            end
        end
    end)
end

local infiniteJumpEnabled = State.infiniteJumpEnabled
local infiniteJumpConnection = Connections.infiniteJumpConnection

local function setInfiniteJump(enabled)
    State.infiniteJumpEnabled = enabled
    infiniteJumpEnabled = State.infiniteJumpEnabled
    Config.TpSettings.InfiniteJump = enabled
    SaveConfig()
    if Connections.infiniteJumpConnection then Connections.infiniteJumpConnection:Disconnect(); Connections.infiniteJumpConnection = nil end
    if Connections._ijInputBegan then Connections._ijInputBegan:Disconnect(); Connections._ijInputBegan = nil end
    if Connections._ijInputEnded then Connections._ijInputEnded:Disconnect(); Connections._ijInputEnded = nil end
    infiniteJumpConnection = Connections.infiniteJumpConnection
    if not enabled then return end

    local isSpaceHeld = false
    local inputBegan = UserInputService.InputBegan:Connect(function(input, gp)
        if gp then return end
        if input.KeyCode == Enum.KeyCode.Space then isSpaceHeld = true end
    end)
    local inputEnded = UserInputService.InputEnded:Connect(function(input)
        if input.KeyCode == Enum.KeyCode.Space then isSpaceHeld = false end
    end)
    Connections.infiniteJumpConnection = RunService.RenderStepped:Connect(function()
    infiniteJumpConnection = Connections.infiniteJumpConnection
        if not isSpaceHeld then return end
        local char = LocalPlayer.Character
        if not char then return end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChild("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then return end
        hrp.AssemblyLinearVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, 50, hrp.AssemblyLinearVelocity.Z)
    end)
    Connections._ijInputBegan = inputBegan
    Connections._ijInputEnded = inputEnded
end
if infiniteJumpEnabled then setInfiniteJump(true) end

local antiRagdollMode = State.antiRagdollMode
local antiRagdollConn = Connections.antiRagdollConn

local function isRagdolled()
    local char = LocalPlayer.Character; if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid"); if not hum then return false end
    local state = hum:GetState()
    local ragStates = {
        [Enum.HumanoidStateType.Physics]     = true,
        [Enum.HumanoidStateType.Ragdoll]     = true,
        [Enum.HumanoidStateType.FallingDown] = true,
    }
    if ragStates[state] then return true end
    local endTime = LocalPlayer:GetAttribute("RagdollEndTime")
    if endTime and (endTime - Workspace:GetServerTimeNow()) > 0 then return true end
    return false
end

local function stopAntiRagdoll()
    if Connections.antiRagdollConn then Connections.antiRagdollConn:Disconnect(); Connections.antiRagdollConn = nil end
    antiRagdollConn = Connections.antiRagdollConn
end

local stopAntiRagdollV2
local startAntiRagdollV2
local function startAntiRagdoll(mode)
    stopAntiRagdoll()
    if Config.AntiRagdollV2 then stopAntiRagdollV2() end
    if mode == 0 then return end

    Connections.antiRagdollConn = RunService.Heartbeat:Connect(function()
    antiRagdollConn = Connections.antiRagdollConn
        local char = LocalPlayer.Character; if not char then return end
        local hum = char:FindFirstChildOfClass("Humanoid")
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hum or not hrp then return end

        if isRagdolled() then
            pcall(function() LocalPlayer:SetAttribute("RagdollEndTime", Workspace:GetServerTimeNow()) end)
            hum:ChangeState(Enum.HumanoidStateType.Running)
            hrp.AssemblyLinearVelocity = Vector3.zero
            if Workspace.CurrentCamera.CameraSubject ~= hum then Workspace.CurrentCamera.CameraSubject = hum end
            for _, obj in ipairs(char:GetDescendants()) do
                if obj:IsA("BallSocketConstraint") or obj.Name:find("RagdollAttachment") then pcall(function() obj:Destroy() end) end
            end
        end
    end)
end

local AntiRagdollV2Data = {
    antiRagdollConns = {},
}
local antiRagdollConns = AntiRagdollV2Data.antiRagdollConns

local cleanRagdollV2Scheduled = false
local function cleanRagdollV2(char)
    if not char then return end
    local carpetEquipped = false
    pcall(function()
        local toolName = Config.TpSettings.Tool or "Flying Carpet"
        local tool = char:FindFirstChild(toolName)
        if tool then
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if hrp then
                for _, obj in ipairs(hrp:GetChildren()) do
                    if obj:IsA("BodyVelocity") or obj:IsA("BodyPosition") or obj:IsA("BodyGyro") then
                        carpetEquipped = true
                        break
                    end
                end
            end
            if not carpetEquipped then
                for _, obj in ipairs(tool:GetChildren()) do
                    if obj:IsA("BodyVelocity") or obj:IsA("BodyPosition") or obj:IsA("BodyGyro") then
                        carpetEquipped = true
                        break
                    end
                end
            end
        end
    end)
    local descendants = char:GetDescendants()
    for _, d in ipairs(descendants) do
        if d:IsA("BallSocketConstraint") or d:IsA("NoCollisionConstraint")
            or d:IsA("HingeConstraint")
            or (d:IsA("Attachment") and (d.Name == "A" or d.Name == "B")) then
            d:Destroy()
        elseif (d:IsA("BodyVelocity") or d:IsA("BodyPosition") or d:IsA("BodyGyro")) and not carpetEquipped then
            d:Destroy()
        end
    end
    for _, d in ipairs(descendants) do
        if d:IsA("Motor6D") then d.Enabled = true end
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        local animator = hum:FindFirstChild("Animator")
        if animator then
            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                local n = track.Animation and track.Animation.Name:lower() or ""
                if n:find("rag") or n:find("fall") or n:find("hurt") or n:find("down") then track:Stop(0) end
            end
        end
    end
    task.defer(function()
        pcall(function()
            local pm = LocalPlayer:FindFirstChild("PlayerScripts")
            if pm then pm = pm:FindFirstChild("PlayerModule") end
            if pm then require(pm):GetControls():Enable() end
        end)
    end)
end
local function cleanRagdollV2Debounced(char)
    if cleanRagdollV2Scheduled then return end
    cleanRagdollV2Scheduled = true
    task.defer(function()
        cleanRagdollV2Scheduled = false
        if char and char.Parent then cleanRagdollV2(char) end
    end)
end
local function isRagdollRelatedDescendant(obj)
    if obj:IsA("BallSocketConstraint") or obj:IsA("NoCollisionConstraint") or obj:IsA("HingeConstraint") then return true end
    if obj:IsA("Attachment") and (obj.Name == "A" or obj.Name == "B") then return true end
    if obj:IsA("BodyVelocity") or obj:IsA("BodyPosition") or obj:IsA("BodyGyro") then return true end
    return false
end

local function hookAntiRagV2(char)
    for _, c in ipairs(antiRagdollConns) do pcall(function() c:Disconnect() end) end
    AntiRagdollV2Data.antiRagdollConns = {}
    antiRagdollConns = AntiRagdollV2Data.antiRagdollConns

    local hum = char:WaitForChild("Humanoid", 10)
    local hrp = char:WaitForChild("HumanoidRootPart", 10)
    if not hum or not hrp then return end

    local lastVel = Vector3.new(0, 0, 0)

    local c1 = hum.StateChanged:Connect(function()
        local st = hum:GetState()
        if st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.Ragdoll
            or st == Enum.HumanoidStateType.FallingDown or st == Enum.HumanoidStateType.GettingUp then
            local carpetActive = false
            pcall(function()
                local toolName = Config.TpSettings.Tool or "Flying Carpet"
                local tool = char:FindFirstChild(toolName)
                if tool and hrp then
                    for _, obj in ipairs(hrp:GetChildren()) do
                        if obj:IsA("BodyVelocity") or obj:IsA("BodyPosition") or obj:IsA("BodyGyro") then carpetActive = true end
                    end
                end
            end)
            if not carpetActive then hum:ChangeState(Enum.HumanoidStateType.Running) end
            cleanRagdollV2(char)
            pcall(function() Workspace.CurrentCamera.CameraSubject = hum end)
            pcall(function()
                local pm = LocalPlayer:FindFirstChild("PlayerScripts")
                if pm then pm = pm:FindFirstChild("PlayerModule") end
                if pm then require(pm):GetControls():Enable() end
            end)
        end
    end)
    table.insert(antiRagdollConns, c1)

    local c2 = char.DescendantAdded:Connect(function(desc)
        if isRagdollRelatedDescendant(desc) then cleanRagdollV2Debounced(char) end
    end)
    table.insert(antiRagdollConns, c2)

    pcall(function()
        local pkg = ReplicatedStorage:FindFirstChild("Packages")
        if pkg then
            local net = pkg:FindFirstChild("Net")
            if net then
                local applyImp = net:FindFirstChild("RE/CombatService/ApplyImpulse")
                if applyImp and applyImp:IsA("RemoteEvent") then
                    local c3 = applyImp.OnClientEvent:Connect(function()
                        local st = hum:GetState()
                        if st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.Ragdoll
                            or st == Enum.HumanoidStateType.FallingDown or st == Enum.HumanoidStateType.GettingUp then
                            pcall(function() hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
                        end
                    end)
                    table.insert(antiRagdollConns, c3)
                end
            end
        end
    end)

    local c4 = RunService.Heartbeat:Connect(function()
        local st = hum:GetState()
        if st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.Ragdoll
            or st == Enum.HumanoidStateType.FallingDown or st == Enum.HumanoidStateType.GettingUp then
            cleanRagdollV2(char)
            local vel = hrp.AssemblyLinearVelocity
            if (vel - lastVel).Magnitude > 40 and vel.Magnitude > 25 then hrp.AssemblyLinearVelocity = vel.Unit * math.min(vel.Magnitude, 15) end
        end
        lastVel = hrp.AssemblyLinearVelocity
    end)
    table.insert(antiRagdollConns, c4)

    cleanRagdollV2(char)
end

stopAntiRagdollV2 = function()
    cleanRagdollV2Scheduled = false
    for _, c in ipairs(antiRagdollConns) do pcall(function() c:Disconnect() end) end
    AntiRagdollV2Data.antiRagdollConns = {}
    antiRagdollConns = AntiRagdollV2Data.antiRagdollConns
end

startAntiRagdollV2 = function(enabled)
    stopAntiRagdoll()
    stopAntiRagdollV2()
    if not enabled then return end

    local char = LocalPlayer.Character
    if char then task.spawn(function() hookAntiRagV2(char) end) end
    LocalPlayer.CharacterAdded:Connect(function(c)
        task.spawn(function() hookAntiRagV2(c) end)
    end)
end

if antiRagdollMode > 0 then startAntiRagdoll(antiRagdollMode) end
Config.AntiRagdollV2 = true
startAntiRagdollV2(true)
if Config.AntiRagdollV2 then startAntiRagdollV2(true) end

do
    local plotBeam = nil
    local plotBeamAttachment0 = nil
    local plotBeamAttachment1 = nil

    local function findMyPlot()
        local plots = workspace:FindFirstChild("Plots")
        if not plots then return nil end
        for _, plot in ipairs(plots:GetChildren()) do
            local sign = plot:FindFirstChild("PlotSign")
            if sign then
                local surfaceGui = sign:FindFirstChildWhichIsA("SurfaceGui", true)
                if surfaceGui then
                    local label = surfaceGui:FindFirstChildWhichIsA("TextLabel", true)
                    if label then
                        local text = label.Text:lower()
                        if text:find(LocalPlayer.DisplayName:lower(), 1, true) or text:find(LocalPlayer.Name:lower(), 1, true) then
                            return plot
                        end
                    end
                end
            end
        end
        return nil
    end

    local function createPlotBeam()
        if not Config.LineToBase then return end
        local myPlot = findMyPlot()
        if not myPlot or not myPlot.Parent then return end
        local character = LocalPlayer.Character
        if not character or not character.Parent then return end
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if not hrp or not hrp.Parent then return end
        if plotBeam then pcall(function() plotBeam:Destroy() end) end
        if plotBeamAttachment0 then pcall(function() plotBeamAttachment0:Destroy() end) end
        plotBeamAttachment0 = hrp:FindFirstChild("PlotBeamAttach_Player") or Instance.new("Attachment")
        plotBeamAttachment0.Name = "PlotBeamAttach_Player"
        plotBeamAttachment0.Position = Vector3.new(0, 0, 0)
        plotBeamAttachment0.Parent = hrp
        local plotPart = myPlot:FindFirstChild("MainRootPart") or myPlot:FindFirstChildWhichIsA("BasePart")
        if not plotPart or not plotPart.Parent then return end
        plotBeamAttachment1 = plotPart:FindFirstChild("PlotBeamAttach_Plot") or Instance.new("Attachment")
        plotBeamAttachment1.Name = "PlotBeamAttach_Plot"
        plotBeamAttachment1.Position = Vector3.new(0, 5, 0)
        plotBeamAttachment1.Parent = plotPart
        plotBeam = hrp:FindFirstChild("PlotBeam") or Instance.new("Beam")
        plotBeam.Name = "PlotBeam"
        plotBeam.Attachment0 = plotBeamAttachment0
        plotBeam.Attachment1 = plotBeamAttachment1
        plotBeam.FaceCamera = true
        plotBeam.LightEmission = 1
        plotBeam.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
        plotBeam.Transparency = NumberSequence.new(0)
        plotBeam.Width0 = 0.7
        plotBeam.Width1 = 0.7
        plotBeam.TextureMode = Enum.TextureMode.Wrap
        plotBeam.TextureSpeed = 0
        plotBeam.Parent = hrp
    end

    local function resetPlotBeam()
        if plotBeam then pcall(function() plotBeam:Destroy() end) end
        if plotBeamAttachment0 then pcall(function() plotBeamAttachment0:Destroy() end) end
        if plotBeamAttachment1 then pcall(function() plotBeamAttachment1:Destroy() end) end
        plotBeam = nil
        plotBeamAttachment0 = nil
        plotBeamAttachment1 = nil
    end

    task.spawn(function()
        local checkCounter = 0
        RunService.Heartbeat:Connect(function()
            if not Config.LineToBase then return end
            checkCounter = checkCounter + 1
            if checkCounter >= 30 then
                checkCounter = 0
                if not plotBeam or not plotBeam.Parent or not plotBeamAttachment0 or not plotBeamAttachment0.Parent then
                    pcall(createPlotBeam)
                end
            end
        end)
    end)

    LocalPlayer.CharacterAdded:Connect(function(character)
        task.wait(0.5)
        if Config.LineToBase and character then pcall(createPlotBeam) end
    end)

    if LocalPlayer.Character then
        task.spawn(function()
            task.wait(0.2)
            if Config.LineToBase then createPlotBeam() end
        end)
    end

    _G.createPlotBeam = createPlotBeam
    _G.resetPlotBeam = resetPlotBeam
end

task.spawn(function()
    local selectedTargetIndex = 1
    local Packages = ReplicatedStorage:WaitForChild("Packages")
    local Datas    = ReplicatedStorage:WaitForChild("Datas")
    local Shared   = ReplicatedStorage:WaitForChild("Shared")
    local Utils    = ReplicatedStorage:WaitForChild("Utils")

    local Synchronizer  = require(Packages:WaitForChild("Synchronizer"))
    local AnimalsData   = require(Datas:WaitForChild("Animals"))
    local AnimalsShared = require(Shared:WaitForChild("Animals"))
    local NumberUtils   = require(Utils:WaitForChild("NumberUtils"))

    local beamFolder = Instance.new("Folder", Workspace)
    beamFolder.Name = "JustAFanTracers"
    local currentBeam = nil
    local currentAtt0 = nil
    local currentAtt1 = nil

    local function updateTracer()
        if not Config.TracerEnabled then
            if currentBeam then currentBeam:Destroy() currentBeam=nil end
            if currentAtt0 then currentAtt0:Destroy() currentAtt0=nil end
            if currentAtt1 then currentAtt1:Destroy() currentAtt1=nil end
            return
        end

        local best = nil
        local targetPart = nil
        if Config.LineToBase then
            local char = LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then
                local plots = Workspace:FindFirstChild("Plots")
                if plots then
                    for _, plot in ipairs(plots:GetChildren()) do
                        local ok, ch = pcall(function() return Synchronizer:Get(plot.Name) end)
                        if ok and ch then
                            local owner = ch:Get("Owner")
                            local ownerId = (typeof(owner) == "Instance" and owner:IsA("Player")) and owner.UserId or (type(owner) == "table" and owner.UserId)
                            if ownerId == LocalPlayer.UserId then
                                local plotPos = plot:FindFirstChild("Base") and plot.Base:FindFirstChild("Spawn")
                                if plotPos and plotPos:IsA("BasePart") then
                                    targetPart = plotPos
                                    break
                                end
                            end
                        end
                    end
                end
            end
        else
            local pets = {}
            if #pets == 0 then
                if currentBeam then currentBeam.Enabled=false end
                return
            end
            if selectedTargetIndex > #pets then selectedTargetIndex = #pets end
            if selectedTargetIndex < 1 then selectedTargetIndex = 1 end
            best = pets[selectedTargetIndex] or pets[1]
            local _fag = _G.findAdorneeGlobal; targetPart = _fag and _fag(best.animalData)
        end
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")

        if hrp and targetPart then
            if not currentAtt0 or currentAtt0.Parent ~= hrp then
                if currentAtt0 then currentAtt0:Destroy() end
                currentAtt0 = Instance.new("Attachment", hrp)
            end
            if not currentAtt1 or currentAtt1.Parent ~= targetPart then
                if currentAtt1 then currentAtt1:Destroy() end
                currentAtt1 = Instance.new("Attachment", targetPart)
            end

            if not currentBeam then
                currentBeam = Instance.new("Beam", beamFolder)
                currentBeam.FaceCamera = true
                currentBeam.Width0 = 0.8
                currentBeam.Width1 = 0.8
                currentBeam.TextureMode = Enum.TextureMode.Static
                currentBeam.TextureSpeed = 3
            end

            currentBeam.Attachment0 = currentAtt0
            currentBeam.Attachment1 = currentAtt1
            currentBeam.Enabled = true

            local col = Color3.fromRGB(170,170,170)
            currentBeam.Color = ColorSequence.new(col)
        else
            if currentBeam then currentBeam.Enabled = false end
        end
    end

    RunService.Heartbeat:Connect(updateTracer)
end)

task.spawn(function()
    local COOLDOWNS = {
        rocket = 120, ragdoll = 30, balloon = 30, inverse = 60,
        nightvision = 60, jail = 60, tiny = 60, jumpscare = 60, morph = 60
    }
    local ALL_COMMANDS = {
        "balloon", "inverse", "jail", "jumpscare", "morph", 
        "nightvision", "ragdoll", "rocket", "tiny"
    }

    local activeCooldowns = {} 
    SharedState.AdminButtonCache = {}

    BlacklistedPlayers = Config.Blacklist or {}

    addToBlacklist = function(username)
        if not username or username == "" then return false end
        local lower = string.lower(username)
        for _, v in ipairs(BlacklistedPlayers) do
            if string.lower(v) == lower then return false end
        end
        table.insert(BlacklistedPlayers, username)
        Config.Blacklist = BlacklistedPlayers
        SaveConfig()
        return true
    end

    removeFromBlacklist = function(username)
        if not username or username == "" then return false end
        local lower = string.lower(username)
        for i, v in ipairs(BlacklistedPlayers) do
            if string.lower(v) == lower then
                table.remove(BlacklistedPlayers, i)
                Config.Blacklist = BlacklistedPlayers
                SaveConfig()
                if _G.removeBlacklistESP then
                    local p = Players:FindFirstChild(username)
                    if p then _G.removeBlacklistESP(p) end
                end
                return true
            end
        end
        return false
    end

    isBlacklisted = function(username)
        if not username then return false end
        local lower = string.lower(tostring(username))
        for _, v in ipairs(BlacklistedPlayers) do
            if string.lower(tostring(v)) == lower then return true end
        end
        return false
    end

    canUseAdminAction = function(targetPlayer)
        if not targetPlayer then return false end
        if isBlacklisted(targetPlayer.Name) then
            ShowNotification("BLACKLIST", targetPlayer.Name .. " is blacklisted")
            return false
        end
        return true
    end

    refreshBlacklistUI = nil

    local function adminGetSync()
        local ok, m = pcall(function()
            return require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Synchronizer"))
        end)
        return ok and m or nil
    end

    local adminGui = Instance.new("ScreenGui")
    adminGui.Name = "XiAdminPanel"
    adminGui.ResetOnSpawn = false
    adminGui.Parent = PlayerGui

    local frame = Instance.new("Frame")
    local mobileScale = IS_MOBILE and 0.65 or 1
    frame.Size = UDim2.new(0, 440 * mobileScale, 0, 700 * mobileScale)
    frame.Position = UDim2.new(Config.Positions.AdminPanel.X, 0, Config.Positions.AdminPanel.Y, 0)
    frame.BackgroundColor3 = Theme.Background
    frame.BackgroundTransparency = 0.29
    frame.BorderSizePixel = 0
    frame.Parent = adminGui
    
    local listFrame
    local layout
    local blFrame

    ApplyViewportUIScaleAdmin(frame, 400, 450, 0.45, 0.85)
    AddMobileMinimizeAdmin(frame, "ADMIN")
    
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 12)
    local stroke = Instance.new("UIStroke", frame)
    stroke.Color = Theme.Accent2; stroke.Thickness = 1.5; stroke.Transparency = 0.4
    CreateGradient(stroke)
    task.defer(function() if addRacetrackBorder then addRacetrackBorder(frame, 3.5) end end)

    local header = Instance.new("Frame", frame)
    header.Size = UDim2.new(1, 0, 0, 40)
    header.BackgroundTransparency = 1
    MakeDraggable(header, frame, "AdminPanel")

    local title = Instance.new("TextLabel", header)
    title.Size = UDim2.new(1, -100, 1, 0)
    title.Position = UDim2.new(0, 15, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "Admin Panel"
    title.Font = Enum.Font.GothamBlack
    title.TextSize = 16
    title.TextColor3 = Theme.TextPrimary
    title.TextXAlignment = Enum.TextXAlignment.Left

    local refreshBtn = Instance.new("TextButton", header)
    refreshBtn.Size = UDim2.new(0, 80, 0, 30)
    refreshBtn.Position = UDim2.new(1, -85, 0.5, -15)
    refreshBtn.BackgroundColor3 = Theme.SurfaceHighlight
    refreshBtn.Text = "REFRESH"
    refreshBtn.Font = Enum.Font.GothamBold
    refreshBtn.TextSize = 12
    refreshBtn.TextColor3 = Theme.TextPrimary
    Instance.new("UICorner", refreshBtn).CornerRadius = UDim.new(0, 6)
    local refreshStroke = Instance.new("UIStroke", refreshBtn)
    refreshStroke.Color = Theme.Accent2
    refreshStroke.Thickness = 1
    refreshStroke.Transparency = 0.3

    local proxCont = Instance.new("Frame", frame)
    proxCont.Size = UDim2.new(1, -20, 0, 44)
    proxCont.Position = UDim2.new(0, 10, 0, 58)
    proxCont.BackgroundColor3 = Color3.fromRGB(32, 32, 32)
    proxCont.BackgroundTransparency = 0.3
    Instance.new("UICorner", proxCont).CornerRadius = UDim.new(0, 10)
    local proxContStroke = Instance.new("UIStroke", proxCont)
    proxContStroke.Color = Theme.Accent2
    proxContStroke.Thickness = 1
    proxContStroke.Transparency = 0.6

    local proxBtn = Instance.new("TextButton", proxCont)
    proxBtn.Name = "ProximityAPButton"
    proxBtn.Size = UDim2.new(0, 70, 0, 26)
    proxBtn.Position = UDim2.new(0, 6, 0.5, -13)
    proxBtn.BackgroundColor3 = ProximityAPActive and Theme.Accent1 or Color3.fromRGB(35, 37, 43)
    proxBtn.Text = "Prox"
    proxBtn.Font = Enum.Font.GothamBold; proxBtn.TextSize = 11
    proxBtn.TextColor3 = ProximityAPActive and Color3.new(255,255,255) or Theme.TextPrimary
    Instance.new("UICorner", proxBtn).CornerRadius = UDim.new(0, 6)
    local proxBtnStroke = Instance.new("UIStroke", proxBtn)
    proxBtnStroke.Color = ProximityAPActive and Theme.Accent2 or Color3.fromRGB(50, 52, 58)
    proxBtnStroke.Transparency = 0.3
    SharedState.ProximityAPButton = proxBtn
    SharedState.ProximityAPButtonStroke = proxBtnStroke
    SharedState.AdminProxBtn = proxBtn

    local spamBaseBtn = Instance.new("TextButton", proxCont)
    spamBaseBtn.Size = UDim2.new(0, 70, 0, 26)
    spamBaseBtn.Position = UDim2.new(0, 80, 0.5, -13)
    spamBaseBtn.BackgroundColor3 = Color3.fromRGB(35, 37, 43)
    spamBaseBtn.Text = "Spam Owner"
    spamBaseBtn.Font = Enum.Font.GothamBold; spamBaseBtn.TextSize = 9
    spamBaseBtn.TextColor3 = Theme.TextPrimary
    Instance.new("UICorner", spamBaseBtn).CornerRadius = UDim.new(0, 6)
    local spamBaseBtnStroke = Instance.new("UIStroke", spamBaseBtn)
    spamBaseBtnStroke.Color = Color3.fromRGB(50, 52, 58)
    spamBaseBtnStroke.Transparency = 0.3

    local ctapPanelBtn = Instance.new("TextButton", proxCont)
    ctapPanelBtn.Size = UDim2.new(0, 60, 0, 26)
    ctapPanelBtn.Position = UDim2.new(0, 154, 0.5, -13)
    ctapPanelBtn.AutoButtonColor = false
    ctapPanelBtn.Text = "Click AP"
    ctapPanelBtn.Font = Enum.Font.GothamBold
    ctapPanelBtn.TextSize = 9
    ctapPanelBtn.BorderSizePixel = 0
    local function updateCtapPanelBtn()
        ctapPanelBtn.BackgroundColor3 = Config.ClickToAP and Theme.Accent1 or Color3.fromRGB(35, 37, 43)
        ctapPanelBtn.TextColor3 = Config.ClickToAP and Color3.new(0,0,0) or Theme.TextPrimary
    end
    updateCtapPanelBtn()
    Instance.new("UICorner", ctapPanelBtn).CornerRadius = UDim.new(0, 6)
    local ctapPanelStroke = Instance.new("UIStroke", ctapPanelBtn)
    ctapPanelStroke.Color = Color3.fromRGB(50, 52, 58)
    ctapPanelStroke.Transparency = 0.3
    ctapPanelBtn.MouseButton1Click:Connect(function()
        Config.ClickToAP = not Config.ClickToAP
        if Config.ClickToAP then Config.ClickToAPSingleCommand = true end
        SaveConfig()
        updateCtapPanelBtn()
        ShowNotification("CLICK TO AP", Config.ClickToAP and "ON (single cmd)" or "DISABLED")
    end)
    
    spamBaseBtn.MouseButton1Click:Connect(function()
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then
            ShowNotification("SPAM OWNER", "No character found")
            return
        end
        
        local nearestPlot = nil
        local nearestDist = math.huge
        local Plots = Workspace:FindFirstChild("Plots")
        if Plots then
            for _, plot in ipairs(Plots:GetChildren()) do
                local sign = plot:FindFirstChild("PlotSign")
                if sign then
                    local yourBase = sign:FindFirstChild("YourBase")
                    if not yourBase or not yourBase.Enabled then
                        local signPos = sign:IsA("BasePart") and sign.Position or (sign.PrimaryPart and sign.PrimaryPart.Position)
                        if not signPos then
                            local part = sign:FindFirstChildWhichIsA("BasePart", true)
                            signPos = part and part.Position
                        end
                        if signPos then
                            local dist = (hrp.Position - signPos).Magnitude
                            if dist < nearestDist then
                                nearestDist = dist
                                nearestPlot = plot
                            end
                        end
                    end
                end
            end
        end
        
        if not nearestPlot then
            ShowNotification("SPAM OWNER", "No nearby base found")
            return
        end
        
        local targetPlayer = nil
        local ok, ch = pcall(function() local S = adminGetSync(); return S and S:Get(nearestPlot.Name) end)
        if ok and ch then
            local owner = ch:Get("Owner")
            if owner then
                if typeof(owner) == "Instance" and owner:IsA("Player") then
                    targetPlayer = owner
                elseif type(owner) == "table" and owner.Name then targetPlayer = Players:FindFirstChild(owner.Name) end
            end
        end
        
        if not targetPlayer then
            local sign = nearestPlot:FindFirstChild("PlotSign")
            local textLabel = sign and sign:FindFirstChild("SurfaceGui") and sign.SurfaceGui:FindFirstChild("Frame") and sign.SurfaceGui.Frame:FindFirstChild("TextLabel")
            if textLabel then
                local baseText = textLabel.Text
                local nickname = baseText and baseText:match("^(.-)'") or baseText
                if nickname then
                    for _, p in ipairs(Players:GetPlayers()) do
                        if p.DisplayName == nickname or p.Name == nickname then
                            targetPlayer = p
                            break
                        end
                    end
                end
            end
        end
        
        if not targetPlayer or targetPlayer == LocalPlayer then
            ShowNotification("SPAM OWNER", "Owner not found or is you")
            return
        end
        
        spamBaseBtn.BackgroundColor3 = Theme.Accent1
        spamBaseBtn.TextColor3 = Color3.new(1,1,1)
        ShowNotification("SPAM OWNER", "Spamming " .. targetPlayer.DisplayName)
        
        task.spawn(function()
            local cmds = {"balloon", "inverse", "jail", "jumpscare", "morph", "nightvision", "ragdoll", "rocket", "tiny"}
            local cmdCount = 0
            
            local adminFunc = _G.runAdminCommand
            if not adminFunc then
                task.wait(0.05)
                adminFunc = _G.runAdminCommand
            end
            
            if not adminFunc then
                spamBaseBtn.BackgroundColor3 = Color3.fromRGB(35, 37, 43)
                spamBaseBtn.TextColor3 = Theme.TextPrimary
                ShowNotification("SPAM OWNER", "Admin command not ready")
                return
            end
            
            for _, cmd in ipairs(cmds) do
                local success, result = pcall(function()
                    return adminFunc(targetPlayer, cmd)
                end)
                if success and result then cmdCount = cmdCount + 1 end
                task.wait(0.15)
            end
            
            task.wait(0.2)
            spamBaseBtn.BackgroundColor3 = Color3.fromRGB(35, 37, 43)
            spamBaseBtn.TextColor3 = Theme.TextPrimary
            ShowNotification("SPAM OWNER", "Sent " .. cmdCount .. " commands to " .. targetPlayer.DisplayName)
        end)
    end)

    local proxSliderBg = Instance.new("Frame", proxCont)
    proxSliderBg.Size = UDim2.new(0, 140, 0, 5)
    proxSliderBg.Position = UDim2.new(0, 105, 0.5, -2.5)
    proxSliderBg.BackgroundColor3 = Color3.fromRGB(30, 32, 38)
    Instance.new("UICorner", proxSliderBg).CornerRadius = UDim.new(1,0)
    local proxFill = Instance.new("Frame", proxSliderBg)
    proxFill.BackgroundColor3 = Theme.Accent1; proxFill.Size = UDim2.new(0,0,1,0)
    Instance.new("UICorner", proxFill).CornerRadius = UDim.new(1,0)
    local proxKnob = Instance.new("Frame", proxSliderBg)
    proxKnob.Size = UDim2.new(0,12,0,12); proxKnob.BackgroundColor3 = Theme.TextPrimary
    proxKnob.AnchorPoint = Vector2.new(0.5, 0.5); proxKnob.Position = UDim2.new(0,0,0.5,0)
    Instance.new("UICorner", proxKnob).CornerRadius = UDim.new(1,0)
    local proxKnobStroke = Instance.new("UIStroke", proxKnob)
    proxKnobStroke.Color = Theme.Accent1
    proxKnobStroke.Thickness = 1.5
    proxKnobStroke.Transparency = 0.2
    local function updateProxSlider(val)
        local min, max = 5, 50
        val = math.clamp(val, min, max)
        Config.ProximityRange = val; SaveConfig()
        local pct = (val - min)/(max - min)
        proxFill.Size = UDim2.new(pct, 0, 1, 0)
        proxKnob.Position = UDim2.new(pct, 0, 0.5, 0)
        ShowNotification("PROXIMITY RANGE", string.format("%.1f", val) .. " studs")
    end
    updateProxSlider(Config.ProximityRange)

    local pDragging = false
    proxSliderBg.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then pDragging=true end end)
    UserInputService.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then pDragging=false end end)
    UserInputService.InputChanged:Connect(function(i)
        if pDragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local x = i.Position.X
            local r = proxSliderBg.AbsolutePosition.X
            local w = proxSliderBg.AbsoluteSize.X
            local p = (x - r) / w
            updateProxSlider(5 + (p * 45))
        end
    end)

    local proxViz = nil
    local function updateProxViz()
        if ProximityAPActive then 
            if not proxViz then
                proxViz = Instance.new("Part")
                proxViz.Name = "XiProxViz"
                proxViz.Anchored = true; proxViz.CanCollide = false
                proxViz.Shape = Enum.PartType.Cylinder
                proxViz.Color = Theme.Accent1; proxViz.Transparency = 0.6
                proxViz.CastShadow = false
                proxViz.Parent = Workspace
            end
            local char = LocalPlayer.Character
            if char and char:FindFirstChild("HumanoidRootPart") then
                local hrp = char.HumanoidRootPart
                proxViz.Size = Vector3.new(0.5, Config.ProximityRange * 2, Config.ProximityRange * 2)
                proxViz.CFrame = hrp.CFrame * CFrame.Angles(0,0,math.rad(90)) + Vector3.new(0, -2.5, 0)
            end
        else
            if proxViz then proxViz:Destroy(); proxViz = nil end
        end
    end
    RunService.Heartbeat:Connect(updateProxViz)

    local function updateProximityAPButton()
        if SharedState.ProximityAPButton then
            SharedState.ProximityAPButton.BackgroundColor3 = ProximityAPActive and Theme.Accent1 or Color3.fromRGB(35, 37, 43)
            SharedState.ProximityAPButton.TextColor3 = ProximityAPActive and Color3.new(255,255,255) or Theme.TextPrimary
            if SharedState.ProximityAPButtonStroke then
                SharedState.ProximityAPButtonStroke.Color = ProximityAPActive and Theme.Accent2 or Color3.fromRGB(50, 52, 58)
            end
        end
    end
    
    proxBtn.MouseButton1Click:Connect(function()
        ProximityAPActive = not ProximityAPActive 
        updateProximityAPButton()
        ShowNotification("PROXIMITY AP", ProximityAPActive and "ENABLED" or "DISABLED")
    end)

    proxSliderBg.Position = UDim2.new(0, 220, 0.5, -2.5)

    local selfCmdCont = Instance.new("Frame", frame)
    selfCmdCont.Size = UDim2.new(1, -20, 0, 34)
    selfCmdCont.Position = UDim2.new(0, 10, 0, 108)
    selfCmdCont.BackgroundTransparency = 1
    selfCmdCont.BorderSizePixel = 0

    local selfCmdLabel = Instance.new("TextLabel", selfCmdCont)
    selfCmdLabel.Size = UDim2.new(0, 120, 1, 0)
    selfCmdLabel.Position = UDim2.new(0, 0, 0, 0)
    selfCmdLabel.BackgroundTransparency = 1
    selfCmdLabel.Text = "Self Commands"
    selfCmdLabel.Font = Enum.Font.GothamBold
    selfCmdLabel.TextSize = 11
    selfCmdLabel.TextColor3 = Theme.TextSecondary
    selfCmdLabel.TextXAlignment = Enum.TextXAlignment.Left

    local selfBtnsDef = {
        {icon = "RAG", cmd = "ragdoll", color = Color3.fromRGB(232, 128, 58)},
        {icon = "RKT", cmd = "rocket",  color = Color3.fromRGB(58, 184, 184)},
    }
    for i, def in ipairs(selfBtnsDef) do
        local sb = Instance.new("TextButton", selfCmdCont)
        sb.Size = UDim2.new(0, 50, 0, 26)
        sb.Position = UDim2.new(1, -((#selfBtnsDef - i + 1) * 56), 0.5, -13)
        sb.AutoButtonColor = false
        sb.Text = def.icon
        sb.TextSize = 10
        sb.Font = Enum.Font.GothamBlack
        sb.TextColor3 = Color3.fromRGB(255, 255, 255)
        sb.BackgroundColor3 = def.color
        sb.BorderSizePixel = 0
        Instance.new("UICorner", sb).CornerRadius = UDim.new(0, 7)
        local sbStroke = Instance.new("UIStroke", sb)
        sbStroke.Color = def.color; sbStroke.Thickness = 1; sbStroke.Transparency = 0.4

        task.spawn(function()
            while sb and sb.Parent do
                task.wait(0.5)
                local cdFn = isOnCooldown or _G.isOnCooldown
                local cd = cdFn and cdFn(def.cmd)
                if cd then
                    sb.BackgroundColor3 = Theme.Error
                    sbStroke.Color = Theme.Error
                else
                    sb.BackgroundColor3 = def.color
                    sbStroke.Color = def.color
                end
            end
        end)

        sb.MouseButton1Click:Connect(function()
            if isOnCooldown and isOnCooldown(def.cmd) then
                ShowNotification("SELF CMD", def.cmd .. " is on cooldown")
                return
            end
            local adminFunc = _G.runAdminCommand
            if not adminFunc then
                ShowNotification("SELF CMD", "Admin not ready")
                return
            end
            if adminFunc(LocalPlayer, def.cmd) then
                if _G.activeCooldowns then _G.activeCooldowns[def.cmd] = tick() end
                if _G.setGlobalVisualCooldown then _G.setGlobalVisualCooldown(def.cmd) end
                ShowNotification("SELF CMD", "Used " .. def.cmd .. " on self")
            else
                ShowNotification("SELF CMD", "Failed: " .. def.cmd)
            end
        end)
    end

    local spamAllCont = Instance.new("Frame", frame)
    spamAllCont.Size = UDim2.new(1, -20, 0, 34)
    spamAllCont.Position = UDim2.new(0, 10, 0, 146)
    spamAllCont.BackgroundTransparency = 1
    spamAllCont.BorderSizePixel = 0

    local spamAllLabel = Instance.new("TextLabel", spamAllCont)
    spamAllLabel.Size = UDim2.new(0, 120, 1, 0)
    spamAllLabel.Position = UDim2.new(0, 0, 0, 0)
    spamAllLabel.BackgroundTransparency = 1
    spamAllLabel.Text = "Spam All"
    spamAllLabel.Font = Enum.Font.GothamBold
    spamAllLabel.TextSize = 11
    spamAllLabel.TextColor3 = Theme.TextSecondary
    spamAllLabel.TextXAlignment = Enum.TextXAlignment.Left

    local spamAllBtnsDef = {
        {icon = "NEAR", color = Color3.fromRGB(58, 184, 184)},
        {icon = "OWN",  color = Color3.fromRGB(58, 200, 90)},
    }
    for i, def in ipairs(spamAllBtnsDef) do
        local sab = Instance.new("TextButton", spamAllCont)
        sab.Size = UDim2.new(0, 50, 0, 26)
        sab.Position = UDim2.new(1, -((#spamAllBtnsDef - i + 1) * 56), 0.5, -13)
        sab.AutoButtonColor = false
        sab.Text = def.icon
        sab.TextSize = 10
        sab.Font = Enum.Font.GothamBlack
        sab.TextColor3 = Color3.fromRGB(255, 255, 255)
        sab.BackgroundColor3 = def.color
        sab.BorderSizePixel = 0
        Instance.new("UICorner", sab).CornerRadius = UDim.new(0, 7)
        local sabStroke = Instance.new("UIStroke", sab)
        sabStroke.Color = def.color; sabStroke.Thickness = 1; sabStroke.Transparency = 0.4
        sab.MouseButton1Click:Connect(function()
            local targetList = {}
            if def.icon == "NEAR" then
                local myChar = LocalPlayer.Character
                local myHRP = myChar and myChar:FindFirstChild("HumanoidRootPart")
                if myHRP then
                    for _, p in ipairs(Players:GetPlayers()) do
                        if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
                            if (p.Character.HumanoidRootPart.Position - myHRP.Position).Magnitude <= 50 then table.insert(targetList, p) end
                        end
                    end
                end
            else
                for _, p in ipairs(Players:GetPlayers()) do
                    if p ~= LocalPlayer then table.insert(targetList, p) end
                end
            end
            for _, p in ipairs(targetList) do
                if not (isBlacklisted and isBlacklisted(p.Name)) then
                    task.spawn(function()
                        local fn = _G.triggerAll
                        if fn then fn(p) end
                    end)
                end
            end
            ShowNotification("SPAM ALL", def.icon .. " - " .. #targetList .. " players targeted")
        end)
    end

    local tabBar = Instance.new("Frame", frame)
    tabBar.Size = UDim2.new(1, -20, 0, 28)
    tabBar.Position = UDim2.new(0, 10, 0, 184)
    tabBar.BackgroundTransparency = 1
    tabBar.BorderSizePixel = 0

    local tabBarLayout = Instance.new("UIListLayout", tabBar)
    tabBarLayout.FillDirection = Enum.FillDirection.Horizontal
    tabBarLayout.Padding = UDim.new(0, 4)
    tabBarLayout.SortOrder = Enum.SortOrder.LayoutOrder
    tabBarLayout.VerticalAlignment = Enum.VerticalAlignment.Center

    local function makeTabBtn(parent, label, order)
        local btn = Instance.new("TextButton", parent)
        btn.LayoutOrder = order
    btn.Size = UDim2.new(0, 110, 0, 24)
        btn.AutoButtonColor = false
        btn.Text = label
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.BorderSizePixel = 0
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
        local s = Instance.new("UIStroke", btn)
        s.Thickness = 1
        s.Transparency = 0.4
        return btn, s
    end

    local tabPlayers, tabPlayersStroke = makeTabBtn(tabBar, "PLAYERS", 1)
    local tabBlacklist, tabBlacklistStroke = makeTabBtn(tabBar, "BLACKLIST", 2)

    local activeTab = "players"
    local function setActiveTab(name)
        activeTab = name
        if name == "players" then
            tabPlayers.BackgroundColor3 = Theme.Accent1
            tabPlayers.TextColor3 = Color3.new(0,0,0)
            tabPlayersStroke.Color = Theme.Accent1
            tabBlacklist.BackgroundColor3 = Color3.fromRGB(28, 28, 35)
            tabBlacklist.TextColor3 = Theme.TextPrimary
            tabBlacklistStroke.Color = Color3.fromRGB(60, 60, 72)
            listFrame.Visible = true
            blFrame.Visible = false
        else
            tabBlacklist.BackgroundColor3 = Color3.fromRGB(160, 40, 40)
            tabBlacklist.TextColor3 = Color3.fromRGB(255, 210, 210)
            tabBlacklistStroke.Color = Color3.fromRGB(180, 50, 50)
            tabPlayers.BackgroundColor3 = Color3.fromRGB(28, 28, 35)
            tabPlayers.TextColor3 = Theme.TextPrimary
            tabPlayersStroke.Color = Color3.fromRGB(60, 60, 72)
            listFrame.Visible = false
            blFrame.Visible = true
        end
    end

    tabPlayers.MouseButton1Click:Connect(function() setActiveTab("players") end)
    tabBlacklist.MouseButton1Click:Connect(function() setActiveTab("blacklist") end)

    blFrame = Instance.new("Frame", frame)
    blFrame.Size = UDim2.new(1, -20, 1, -220)
    blFrame.Position = UDim2.new(0, 10, 0, 218)
    blFrame.BackgroundTransparency = 1
    blFrame.BorderSizePixel = 0
    blFrame.ZIndex = 5
    blFrame.Active = true
    blFrame.Visible = false

    local blInput = Instance.new("TextBox", blFrame)
    blInput.Size = UDim2.new(1, -58, 0, 26)
    blInput.Position = UDim2.new(0, 0, 0, 0)
    blInput.ZIndex = 6
    blInput.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
    blInput.BorderSizePixel = 0
    blInput.Text = ""
    blInput.PlaceholderText = "Roblox username..."
    blInput.Font = Enum.Font.Gotham
    blInput.TextSize = 11
    blInput.TextColor3 = Theme.TextPrimary
    blInput.PlaceholderColor3 = Color3.fromRGB(80, 80, 95)
    blInput.ClearTextOnFocus = false
    Instance.new("UICorner", blInput).CornerRadius = UDim.new(0, 6)
    local blInputStroke = Instance.new("UIStroke", blInput)
    blInputStroke.Color = Color3.fromRGB(55, 55, 65)
    blInputStroke.Thickness = 1
    blInputStroke.Transparency = 0.3
    local blInputPad = Instance.new("UIPadding", blInput)
    blInputPad.PaddingLeft = UDim.new(0, 8)

    local blAddBtn = Instance.new("TextButton", blFrame)
    blAddBtn.Size = UDim2.new(0, 50, 0, 26)
    blAddBtn.Position = UDim2.new(1, -50, 0, 0)
    blAddBtn.ZIndex = 6
    blAddBtn.BackgroundColor3 = Color3.fromRGB(140, 35, 35)
    blAddBtn.Text = "ADD"
    blAddBtn.Font = Enum.Font.GothamBold
    blAddBtn.TextSize = 11
    blAddBtn.TextColor3 = Color3.fromRGB(255, 200, 200)
    blAddBtn.AutoButtonColor = false
    Instance.new("UICorner", blAddBtn).CornerRadius = UDim.new(0, 6)
    local blAddStroke = Instance.new("UIStroke", blAddBtn)
    blAddStroke.Color = Color3.fromRGB(180, 50, 50)
    blAddStroke.Thickness = 1
    blAddStroke.Transparency = 0.4

    local blListScroll = Instance.new("ScrollingFrame", blFrame)
    blListScroll.Size = UDim2.new(1, 0, 1, -34)
    blListScroll.Position = UDim2.new(0, 0, 0, 32)
    blListScroll.BackgroundTransparency = 1
    blListScroll.BorderSizePixel = 0
    blListScroll.ScrollBarThickness = 0
    blListScroll.ScrollBarImageColor3 = Color3.fromRGB(140, 40, 40)
    local blListLayout = Instance.new("UIListLayout", blListScroll)
    blListLayout.Padding = UDim.new(0, 4)
    blListLayout.SortOrder = Enum.SortOrder.LayoutOrder

    blListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        blListScroll.CanvasSize = UDim2.new(0, 0, 0, blListLayout.AbsoluteContentSize.Y + 4)
    end)

    local function rebuildBlList()
        for _, c in ipairs(blListScroll:GetChildren()) do
            if not c:IsA("UIListLayout") then c:Destroy() end
        end
        for i, name in ipairs(BlacklistedPlayers) do
            local row = Instance.new("Frame", blListScroll)
            row.LayoutOrder = i
            row.Size = UDim2.new(1, 0, 0, 28)
            row.BackgroundColor3 = Color3.fromRGB(28, 18, 18)
            row.BorderSizePixel = 0
            Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
            local rowStroke = Instance.new("UIStroke", row)
            rowStroke.Color = Color3.fromRGB(80, 30, 30)
            rowStroke.Thickness = 1
            rowStroke.Transparency = 0.5

            local nameLabel = Instance.new("TextLabel", row)
            nameLabel.Size = UDim2.new(1, -36, 1, 0)
            nameLabel.Position = UDim2.new(0, 10, 0, 0)
            nameLabel.BackgroundTransparency = 1
            nameLabel.Text = name
            nameLabel.Font = Enum.Font.GothamBold
            nameLabel.TextSize = 11
            nameLabel.TextColor3 = Color3.fromRGB(230, 180, 180)
            nameLabel.TextXAlignment = Enum.TextXAlignment.Left

            local removeBtn = Instance.new("TextButton", row)
            removeBtn.Size = UDim2.new(0, 26, 0, 20)
            removeBtn.Position = UDim2.new(1, -30, 0.5, -10)
            removeBtn.BackgroundColor3 = Color3.fromRGB(100, 25, 25)
            removeBtn.Text = "X"
            removeBtn.Font = Enum.Font.GothamBold
            removeBtn.TextSize = 10
            removeBtn.TextColor3 = Color3.fromRGB(255, 160, 160)
            removeBtn.AutoButtonColor = false
            Instance.new("UICorner", removeBtn).CornerRadius = UDim.new(0, 4)

            local capName = name
            removeBtn.MouseButton1Click:Connect(function()
                for j, n in ipairs(BlacklistedPlayers) do
                    if n:lower() == capName:lower() then
                        table.remove(BlacklistedPlayers, j)
                        break
                    end
                end
                Config.Blacklist = BlacklistedPlayers
        SaveConfig()
                rebuildBlList()
                if refreshBlacklistUI then refreshBlacklistUI() end
                ShowNotification("BLACKLIST", "Removed " .. capName)
            end)
        end
        blListScroll.CanvasSize = UDim2.new(0, 0, 0, blListLayout.AbsoluteContentSize.Y + 4)
    end

    local function addBlacklistUser(username)
        username = username:match("^%s*(.-)%s*$")
        if username == "" then return end
        local lower = username:lower()
        for _, n in ipairs(BlacklistedPlayers) do
            if n:lower() == lower then
                ShowNotification("BLACKLIST", username .. " is already blacklisted")
                return
            end
        end
        table.insert(BlacklistedPlayers, username)
        Config.Blacklist = BlacklistedPlayers
        SaveConfig()
        rebuildBlList()
        if refreshBlacklistUI then refreshBlacklistUI() end
        blInput.Text = ""
        ShowNotification("BLACKLIST", "Blacklisted: " .. username)
    end

    blAddBtn.MouseButton1Click:Connect(function()
        addBlacklistUser(blInput.Text)
    end)
    blInput.FocusLost:Connect(function(enterPressed)
        if enterPressed then addBlacklistUser(blInput.Text) end
    end)

    rebuildBlList()

    listFrame = Instance.new("ScrollingFrame", frame)
    listFrame.Size = UDim2.new(1, -20, 1, -220)
    listFrame.Position = UDim2.new(0, 10, 0, 218)
    listFrame.BackgroundTransparency = 1
    listFrame.BorderSizePixel = 0
    listFrame.ScrollBarThickness = 0
    listFrame.ScrollBarImageColor3 = Theme.Accent1
    layout = Instance.new("UIListLayout", listFrame)
    layout.Padding = UDim.new(0, 10)
    layout.SortOrder = Enum.SortOrder.LayoutOrder

    setActiveTab("players")

    local function getAdminPanelSortKey(plr)
        if not plr or not plr.Parent then return 3, 9999, "" end
        local stealing = plr:GetAttribute("Stealing")
        local brainrotName = plr:GetAttribute("StealingIndex")
        if not stealing then return 3, 9999, plr.Name or "" end
        if brainrotName then
            for i, pName in ipairs(PRIORITY_LIST) do
                if pName == brainrotName then return 1, i, plr.Name or "" end
            end
            return 2, 9999, plr.Name or ""
        end
        return 2, 9999, plr.Name or ""
    end

    local function sortAdminPanelList()
        local rows = {}
        for _, child in ipairs(listFrame:GetChildren()) do
            if child:IsA("TextButton") and child.Name ~= "" then
                local plr = Players:FindFirstChild(child.Name)
                if plr then table.insert(rows, {row = child, plr = plr}) end
            end
        end
        table.sort(rows, function(a, b)
            local t1, p1, n1 = getAdminPanelSortKey(a.plr)
            local t2, p2, n2 = getAdminPanelSortKey(b.plr)
            if t1 ~= t2 then return t1 < t2 end
            if p1 ~= p2 then return p1 < p2 end
            return (n1 or "") < (n2 or "")
        end)
        for i, entry in ipairs(rows) do
            entry.row.LayoutOrder = i
        end
    end

    local function fireClick(button)
        if button then
            if firesignal then
                firesignal(button.MouseButton1Click); firesignal(button.MouseButton1Down); firesignal(button.Activated)
            else
                local x = button.AbsolutePosition.X + (button.AbsoluteSize.X / 2)
                local y = button.AbsolutePosition.Y + (button.AbsoluteSize.Y / 2) + 58
                VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
                VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
            end
        end
    end
    _G.fireClick = fireClick

    local function runAdminCommand(targetPlayer, commandName)
        if targetPlayer and isBlacklisted(targetPlayer.Name) then return false end
        local realAdminGui = PlayerGui:WaitForChild("AdminPanel", 5)
        if not realAdminGui then return false end

        -- Select target FIRST, then click command (otherwise command hits whoever was previously selected).
        local profilesScroll = realAdminGui:WaitForChild("AdminPanel"):WaitForChild("Profiles"):WaitForChild("ScrollingFrame")
        local playerBtn = profilesScroll:FindFirstChild(targetPlayer.Name)
        if not playerBtn then return false end
        fireClick(playerBtn)
        task.wait(0.05)

        local contentScroll = realAdminGui.AdminPanel:WaitForChild("Content"):WaitForChild("ScrollingFrame")
        local cmdBtn = contentScroll:FindFirstChild(commandName)
        if not cmdBtn then return false end
        fireClick(cmdBtn)
        return true
    end
    
    _G.runAdminCommand = runAdminCommand

local isOnCooldown

local function getNextAvailableCommand()
    local priorityCommands = {"ragdoll", "balloon", "rocket", "jail"}
    local otherCommands = {}
    
    for _, cmd in ipairs(ALL_COMMANDS) do
        local isPriority = false
        for _, priorityCmd in ipairs(priorityCommands) do
            if cmd == priorityCmd then
                isPriority = true
                break
            end
        end
        if not isPriority then table.insert(otherCommands, cmd) end
    end

    for _, cmd in ipairs(priorityCommands) do
        if not isOnCooldown(cmd) then return cmd end
    end

    for _, cmd in ipairs(otherCommands) do
        if not isOnCooldown(cmd) then return cmd end
    end

    return nil
end

isOnCooldown = function(cmd)
    local adminGui = PlayerGui:FindFirstChild("AdminPanel")
    if adminGui then
        local content = adminGui:FindFirstChild("AdminPanel")
        if content then
            local scrollFrame = content:FindFirstChild("Content")
            if scrollFrame then
                local scrollingFrame = scrollFrame:FindFirstChild("ScrollingFrame")
                if scrollingFrame then
                    local cmdButton = scrollingFrame:FindFirstChild(cmd)
                    if cmdButton then
                        local timerLabel = cmdButton:FindFirstChild("Timer")
                        if timerLabel then return timerLabel.Visible end
                    end
                end
            end
        end
    end
    
    if not activeCooldowns[cmd] then return false end
    return (tick() - activeCooldowns[cmd]) < (COOLDOWNS[cmd] or 0)
end
_G.isOnCooldown = isOnCooldown

    local function setGlobalVisualCooldown(cmd)
        if SharedState.AdminButtonCache[cmd] then
            for _, b in ipairs(SharedState.AdminButtonCache[cmd]) do
                if b and b.Parent then
                    b.BackgroundColor3 = Theme.Error
                    task.delay(COOLDOWNS[cmd] or 5, function()
                        if b and b.Parent then
                            local hasBallooned = (cmd == "balloon" and SharedState.BalloonedPlayers and next(SharedState.BalloonedPlayers) ~= nil)
                            b.BackgroundColor3 = hasBallooned and Theme.Error or Theme.SurfaceHighlight
                        end
                    end)
                end
            end
        end
    end
    _G.setGlobalVisualCooldown = setGlobalVisualCooldown
    _G.activeCooldowns = activeCooldowns

    local function updateBalloonButtons()
        local hasBallooned = false
        for _, _ in pairs(SharedState.BalloonedPlayers) do
            hasBallooned = true
            break
        end
        if SharedState.AdminButtonCache and SharedState.AdminButtonCache["balloon"] then
            for _, b in ipairs(SharedState.AdminButtonCache["balloon"]) do
                if b and b.Parent then
                    b.BackgroundColor3 = hasBallooned and Theme.Error or Theme.SurfaceHighlight
                end
            end
        end
    end

    local function triggerAll(plr)
        if not canUseAdminAction(plr) then return end
        local count = 0
        for _, cmd in ipairs(ALL_COMMANDS) do
            if not isOnCooldown(cmd) then
                task.delay(count * 0.1, function()
                    if runAdminCommand(plr, cmd) then
                        activeCooldowns[cmd] = tick()
                        setGlobalVisualCooldown(cmd)
                        if cmd == "balloon" then
                            SharedState.BalloonedPlayers[plr.UserId] = true
                            updateBalloonButtons()
                        end
                    end
                end)
                count = count + 1
            end
        end
    end
    _G.triggerAll = triggerAll

    local function rayToCubeIntersect(rayOrigin, rayDirection, cubeCenter, cubeSize)
        local halfSize = cubeSize / 2
        local minBounds = cubeCenter - Vector3.new(halfSize, halfSize, halfSize)
        local maxBounds = cubeCenter + Vector3.new(halfSize, halfSize, halfSize)
        
        if rayDirection.X == 0 then rayDirection = Vector3.new(0.0001, rayDirection.Y, rayDirection.Z) end
        if rayDirection.Y == 0 then rayDirection = Vector3.new(rayDirection.X, 0.0001, rayDirection.Z) end
        if rayDirection.Z == 0 then rayDirection = Vector3.new(rayDirection.X, rayDirection.Y, 0.0001) end
        
        local tmin = (minBounds.X - rayOrigin.X) / rayDirection.X
        local tmax = (maxBounds.X - rayOrigin.X) / rayDirection.X
        if tmin > tmax then tmin, tmax = tmax, tmin end
        
        local tymin = (minBounds.Y - rayOrigin.Y) / rayDirection.Y
        local tymax = (maxBounds.Y - rayOrigin.Y) / rayDirection.Y
        if tymin > tymax then tymin, tymax = tymax, tymin end
        
        if tmin > tymax or tymin > tmax then return false end
        if tymin > tmin then tmin = tymin end
        if tymax < tmax then tmax = tymax end
        
        local tzmin = (minBounds.Z - rayOrigin.Z) / rayDirection.Z
        local tzmax = (maxBounds.Z - rayOrigin.Z) / rayDirection.Z
        if tzmin > tzmax then tzmin, tzmax = tzmax, tzmin end
        
        if tmin > tzmax or tzmin > tmax then return false end
        
        return true
    end

    local _hlParent = PlayerGui
    pcall(function() _hlParent = game:GetService("CoreGui") end)
    local highlight = Instance.new("Highlight", _hlParent)
   highlight.FillColor = Color3.fromRGB(255, 50, 50)
    highlight.FillTransparency = 0.3
    highlight.OutlineColor = Color3.fromRGB(255, 50, 50)
    highlight.OutlineTransparency = 0
    highlight.Adornee = nil
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop

    -- Per-frame RenderStepped (only does work when ClickToAP is on, but it still calls the
    -- closure on every frame to check the flag). Native callback keeps the per-frame check
    -- + player scan cheap under the obfuscator VM.
    RunService.RenderStepped:Connect(LPH_NO_VIRTUALIZE(function()
        if Config.ClickToAP then
            local camera = Workspace.CurrentCamera
            local mousePos = UserInputService:GetMouseLocation()
            local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)

            local hitboxSize = 8
            local bestPlayer = nil
            local bestDistance = math.huge

            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") and p.Parent then
                    local hrp = p.Character.HumanoidRootPart
                    local cubeCenter = hrp.Position

                    if rayToCubeIntersect(ray.Origin, ray.Direction, cubeCenter, hitboxSize) then
                        local distance = (ray.Origin - cubeCenter).Magnitude
                        if distance < bestDistance then
                            bestDistance = distance
                            bestPlayer = p
                        end
                    end
                end
            end
            
            local newAdornee = bestPlayer and bestPlayer.Character or nil
            if highlight.Adornee ~= newAdornee then
                highlight.Adornee = newAdornee
        for _, child in ipairs(listFrame:GetChildren()) do
            if child:IsA("TextButton") then
                local stroke = child:FindFirstChildOfClass("UIStroke")
                if stroke then
                    local hoveredName = newAdornee and newAdornee.Parent and Players:GetPlayerFromCharacter(newAdornee.Parent) and Players:GetPlayerFromCharacter(newAdornee.Parent).Name or ""
                    if newAdornee and child.Name == hoveredName then
                        stroke.Color = Color3.fromRGB(255, 50, 50)
                        stroke.Transparency = 0
                        child.BackgroundColor3 = Color3.fromRGB(60, 20, 20)
                    else
                        stroke.Color = Theme.Accent2
                        stroke.Transparency = 0.7
                        child.BackgroundColor3 = Color3.fromRGB(32, 32, 32)
                    end
                end
            end
        end            end
        else
            highlight.Adornee = nil
        end
    end))

    UserInputService.InputBegan:Connect(function(inp, g)
        if not g and inp.UserInputType == Enum.UserInputType.MouseButton1 and Config.ClickToAP then
            local camera = Workspace.CurrentCamera
            local mousePos = UserInputService:GetMouseLocation()
            local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
            
            local hitboxSize = 8
            local bestPlayer = nil
            local bestDistance = math.huge
            
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") and p.Parent then
                    local hrp = p.Character.HumanoidRootPart
                    local cubeCenter = hrp.Position
                    
                    if rayToCubeIntersect(ray.Origin, ray.Direction, cubeCenter, hitboxSize) then
                        local distance = (ray.Origin - cubeCenter).Magnitude
                        if distance < bestDistance then
                            bestDistance = distance
                            bestPlayer = p
                        end
                    end
                end
            end
            
            if bestPlayer then
                if isBlacklisted(bestPlayer.Name) then
                    ShowNotification("CLICK TO AP", bestPlayer.Name .. " is blacklisted")
                    return
                end
                
                local hasAnyAvailable = false
                for _, cmd in ipairs(ALL_COMMANDS) do
                    if not isOnCooldown(cmd) then
                        hasAnyAvailable = true
                        break
                    end
                end
                if hasAnyAvailable then
                    if Config.ClickToAPSingleCommand then
                        local nextCmd = getNextAvailableCommand()
                        if nextCmd then
                            if runAdminCommand(bestPlayer, nextCmd) then
                                activeCooldowns[nextCmd] = tick()
                                setGlobalVisualCooldown(nextCmd)
                                if nextCmd == "balloon" then
                                    SharedState.BalloonedPlayers[bestPlayer.UserId] = true
                                    updateBalloonButtons()
                                end
                                ShowNotification("CLICK AP", "Sent " .. nextCmd .. " to " .. bestPlayer.Name)
                            else
                                ShowNotification("CLICK AP", "Failed to send " .. nextCmd .. " to " .. bestPlayer.Name)
                            end
                        else
                            ShowNotification("CLICK AP", "All commands on cooldown")
                        end
                    else
                        triggerAll(bestPlayer)
                        ShowNotification("CLICK AP", "Triggered on " .. bestPlayer.Name)
                    end
                else
                    local realAdminGui = PlayerGui:WaitForChild("AdminPanel", 5)
                    if realAdminGui then
                        local profilesScroll = realAdminGui:WaitForChild("AdminPanel"):WaitForChild("Profiles"):WaitForChild("ScrollingFrame")
                        local playerBtn = profilesScroll:FindFirstChild(bestPlayer.Name)
                        if playerBtn then
                            fireClick(playerBtn)
                            ShowNotification("CLICK AP", "Selected " .. bestPlayer.Name)
                        end
                    end
                end
            end
        end
    end)

    task.spawn(function()
        while true do
            task.wait(0.2)
            if ProximityAPActive then
                local myChar = LocalPlayer.Character
                if myChar and myChar:FindFirstChild("HumanoidRootPart") then
                    for _, p in ipairs(Players:GetPlayers()) do
                        if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
                            local dist = (p.Character.HumanoidRootPart.Position - myChar.HumanoidRootPart.Position).Magnitude
                            if dist <= Config.ProximityRange then
                                if isBlacklisted(p.Name) then
                                else
                                    local hasAnyAvailable = false
                                    for _, cmd in ipairs(ALL_COMMANDS) do
                                        if not isOnCooldown(cmd) then
                                            hasAnyAvailable = true
                                            break
                                        end
                                    end
                                    if hasAnyAvailable then triggerAll(p) end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    local removePlayer
    local function createPlayerRow(plr)
        local row = Instance.new("TextButton") 
        row.Name = plr.Name
        row.LayoutOrder = 0
        row.Size = UDim2.new(1, -4, 0, 74)
        row.BackgroundColor3 = Color3.fromRGB(32, 32, 32)
        row.BackgroundTransparency = 0.2
        row.BorderSizePixel = 0
        row.AutoButtonColor = false
        row.Text = ""
        row.Parent = listFrame
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 10)
        local rowStroke = Instance.new("UIStroke", row)
        rowStroke.Color = Theme.Accent2
        rowStroke.Thickness = 1.5
        rowStroke.Transparency = 0.7
        
        row.MouseEnter:Connect(function()
            row.BackgroundTransparency = 0.05
            rowStroke.Transparency = 0.4
            rowStroke.Color = Theme.Accent1
        end)
        row.MouseLeave:Connect(function()
            row.BackgroundTransparency = 0.2
            rowStroke.Transparency = 0.7
            rowStroke.Color = Theme.Accent2
        end)

        local headshot = Instance.new("ImageLabel", row)
        headshot.Size = UDim2.new(0, 42, 0, 42)
        headshot.Position = UDim2.new(0, 12, 0.5, -21)
        headshot.BackgroundColor3 = Color3.fromRGB(15, 17, 22)
        headshot.Image = Players:GetUserThumbnailAsync(plr.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
        Instance.new("UICorner", headshot).CornerRadius = UDim.new(1, 0)
        local headshotStroke = Instance.new("UIStroke", headshot)
        headshotStroke.Color = Theme.Accent1
        headshotStroke.Thickness = 2.5
        headshotStroke.Transparency = 0.2
        
        local dName = Instance.new("TextLabel", row)
    dName.Size = UDim2.new(0, 160, 0, 20); dName.Position = UDim2.new(0, 58, 0, 10)
    dName.BackgroundTransparency = 1; dName.Text = plr.Name
    dName.Font = Enum.Font.GothamBold; dName.TextSize = 14
    dName.TextColor3 = Theme.TextPrimary; dName.TextXAlignment = Enum.TextXAlignment.Left

        local uName = Instance.new("TextLabel", row)
    uName.Size = UDim2.new(0, 160, 0, 16); uName.Position = UDim2.new(0, 58, 0, 30)
    uName.BackgroundTransparency = 1; uName.Text = plr.DisplayName
    uName.Font = Enum.Font.GothamBold; uName.TextSize = 10
    uName.TextColor3 = Color3.fromRGB(210, 210, 210); uName.TextXAlignment = Enum.TextXAlignment.Left

    local apToolLbl = Instance.new("TextLabel", row)
    apToolLbl.Name = "APToolLabel"
    apToolLbl.Size = UDim2.new(0, 160, 0, 14); apToolLbl.Position = UDim2.new(0, 58, 0, 44)
    apToolLbl.BackgroundTransparency = 1
    apToolLbl.Font = Enum.Font.GothamMedium; apToolLbl.TextSize = 10
    apToolLbl.TextColor3 = Color3.fromRGB(185, 185, 185); apToolLbl.TextXAlignment = Enum.TextXAlignment.Left
    do
        local ht = nil
        local c = plr.Character
        if c then for _, o in ipairs(c:GetChildren()) do if o:IsA("Tool") then ht = o.Name break end end end
        apToolLbl.Text = ht or ""
        if ht and DANGER_TOOLS[ht] then dName.TextColor3 = Color3.fromRGB(180, 180, 180) end
    end

        local nearestBrainrotName = plr:GetAttribute("StealingIndex")
        
        local stealing = plr:GetAttribute("Stealing")
        if stealing then
            if nearestBrainrotName then
                uName.Text = nearestBrainrotName
                uName.TextColor3 = Color3.fromRGB(210, 210, 210)
                uName.Font = Enum.Font.GothamBlack
                uName.TextSize = 14
            else
                uName.Text = "STEALING"
                uName.TextColor3 = Color3.fromRGB(200, 200, 200)
                uName.Font = Enum.Font.GothamBlack
                uName.TextSize = 14
            end
        end
        
        task.spawn(function()
            while row.Parent do
                task.wait(0.5)
                
                if not plr or not plr.Parent or not Players:FindFirstChild(plr.Name) then
                    removePlayer(plr)
                    break
                end
                
                local stealing = plr:GetAttribute("Stealing")
                nearestBrainrotName = plr:GetAttribute("StealingIndex")
                
                if stealing then
                    if nearestBrainrotName then
                        uName.Text = nearestBrainrotName
                        uName.TextColor3 = Color3.fromRGB(210, 210, 210)
                        uName.Font = Enum.Font.GothamBold
                        uName.TextSize = 11
                    else
                        uName.Text = "  STEALING"
                        uName.TextColor3 = Color3.fromRGB(200, 200, 200)
                        uName.Font = Enum.Font.GothamBold
                        uName.TextSize = 11
                    end
                else
                    uName.Text = "(@" .. plr.Name .. ")"
                    uName.TextColor3 = Theme.TextSecondary
                    uName.Font = Enum.Font.GothamMedium
                    uName.TextSize = 7
                    nearestBrainrotName = nil
                end
                pcall(function()
                    local ht = nil
                    local c = plr.Character
                    if c then for _, o in ipairs(c:GetChildren()) do if o:IsA("Tool") then ht = o.Name break end end end
                    apToolLbl.Text = ht or ""
                    if ht and DANGER_TOOLS[ht] then
                        dName.TextColor3 = Color3.fromRGB(180, 180, 180)
                    else
                        dName.TextColor3 = Theme.TextPrimary
                    end
                end)
            end
        end)

        local btnCont = Instance.new("Frame", row)
    btnCont.Size = UDim2.new(0, 250, 1, 0); btnCont.Position = UDim2.new(1, -255, 0, 0)
    btnCont.BackgroundTransparency = 1; btnCont.ZIndex = 10

        local buttonsDef = {
            {icon = "JAI",  cmd = "jail",    color = Color3.fromRGB(232, 128, 58),  hoverColor = Color3.fromRGB(255, 150, 80)},
            {icon = "RAG",  cmd = "ragdoll", color = Color3.fromRGB(232, 128, 58),  hoverColor = Color3.fromRGB(255, 150, 80)},
            {icon = "RKT",  cmd = "rocket",  color = Color3.fromRGB(58, 184, 184),  hoverColor = Color3.fromRGB(80, 210, 210)},
            {icon = "BUI",  cmd = "balloon", color = Color3.fromRGB(58, 232, 96),   hoverColor = Color3.fromRGB(80, 255, 120)},
        }

        for i, def in ipairs(buttonsDef) do
            local b = Instance.new("TextButton", btnCont)
            b.Size = UDim2.new(0, 36, 0, 30)
            b.Position = UDim2.new(0, 4 + (i-1)*40, 0.5, -15)
            b.AutoButtonColor = false
            b.Text = def.icon
            b.TextSize = 9
            b.TextColor3 = Color3.fromRGB(255, 255, 255)
            b.Font = Enum.Font.GothamBlack
            b.ZIndex = 11
            b.Active = true
            local hasBallooned = SharedState.BalloonedPlayers and next(SharedState.BalloonedPlayers) ~= nil
            local isOnCD = isOnCooldown(def.cmd)
            b.BackgroundColor3 = isOnCD and Theme.Error or def.color
            b.BackgroundTransparency = 0
            Instance.new("UICorner", b).CornerRadius = UDim.new(0, 7)
            local bStroke = Instance.new("UIStroke", b)
            bStroke.Color = isOnCD and Theme.Error or def.color
            bStroke.Thickness = 1
            bStroke.Transparency = 0.5
            bStroke.ZIndex = 12
            
            b.MouseEnter:Connect(function()
                if not isOnCD and not (def.cmd == "balloon" and hasBallooned) then
                    b.BackgroundColor3 = def.hoverColor
                    bStroke.Transparency = 0.2
                end
            end)
            b.MouseLeave:Connect(function()
                if not isOnCD and not (def.cmd == "balloon" and hasBallooned) then
                    b.BackgroundColor3 = def.color
                    bStroke.Transparency = 0.5
                end
            end)
            
            if not SharedState.AdminButtonCache[def.cmd] then SharedState.AdminButtonCache[def.cmd] = {} end
            table.insert(SharedState.AdminButtonCache[def.cmd], b)

            task.spawn(function()
                while b and b.Parent do
                    task.wait(0.5)
                    if not b.Text or b.Text == "" or b.Text == "BUTTON" or b.Text == "Button" then
                        b.Text = def.icon
                        b.TextSize = 9
                        b.TextColor3 = Theme.TextPrimary
                        b.Font = Enum.Font.GothamBlack
                    end
                    local cd = isOnCooldown(def.cmd)
                    local balloon = (def.cmd == "balloon" and SharedState.BalloonedPlayers and next(SharedState.BalloonedPlayers) ~= nil)
                    if cd or balloon then
                        b.BackgroundColor3 = Theme.Error
                        b.BackgroundTransparency = 0
                        bStroke.Color = Theme.Error
                        bStroke.Transparency = 0.2
                        if b.Text ~= def.icon then
                            b.Text = def.icon
                            b.TextSize = 9
                            b.TextColor3 = Theme.TextPrimary
                            b.Font = Enum.Font.GothamBlack
                        end
                    elseif not cd and not balloon then
                        b.BackgroundColor3 = def.color
                        b.BackgroundTransparency = 0
                        bStroke.Color = def.color
                        bStroke.Transparency = 0.5
                        if b.Text ~= def.icon then
                            b.Text = def.icon
                            b.TextSize = 9
                            b.TextColor3 = Theme.TextPrimary
                            b.Font = Enum.Font.GothamBlack
                        end
                    end
                end
            end)

            b.MouseButton1Click:Connect(function()
                if def.special and def.cmd == "spambaseowner" then
                    local char = LocalPlayer.Character
                    local hrp = char and char:FindFirstChild("HumanoidRootPart")
                    if not hrp then return end
                    
                    local closestPlot = nil
                    local closestDist = math.huge
                    
                    local plots = Workspace:FindFirstChild("Plots")
                    if plots then
                        for _, plot in ipairs(plots:GetChildren()) do
                            local plotPos = plot:FindFirstChild("Base") and plot.Base:FindFirstChild("Spawn")
                            if plotPos then
                                local dist = (hrp.Position - plotPos.Position).Magnitude
                                if dist < closestDist then
                                    closestDist = dist
                                    closestPlot = plot
                                end
                            end
                        end
                    end
                    
                    if closestPlot then
                        task.spawn(function()
                            local Packages = ReplicatedStorage:WaitForChild("Packages")
                            local Synchronizer = require(Packages:WaitForChild("Synchronizer"))
                            local channel = Synchronizer:Get(closestPlot.Name)
                            if channel then
                                local owner = channel:Get("Owner")
                                local targetPlayer = nil
                                if typeof(owner) == "Instance" and owner:IsA("Player") then
                                    targetPlayer = owner
                                elseif typeof(owner) == "table" and owner.UserId then
                                    targetPlayer = Players:GetPlayerByUserId(owner.UserId)
                                end
                                
                                if targetPlayer and targetPlayer ~= LocalPlayer then
                                    local hasAnyAvailable = false
                                    for _, cmd in ipairs(ALL_COMMANDS) do
                                        if not isOnCooldown(cmd) then
                                            hasAnyAvailable = true
                                            break
                                        end
                                    end
                                    if hasAnyAvailable then
                                        triggerAll(targetPlayer)
                                        ShowNotification("AP SPAM", "Spamming " .. targetPlayer.Name)
                                    else
                                        ShowNotification("AP SPAM", "All commands on cooldown")
                                    end
                                else
                                    ShowNotification("AP SPAM", "No owner found")
                                end
                            end
                        end)
                    end
                else
                    if isBlacklisted(plr.Name) then
                        ShowNotification("ADMIN", plr.Name .. " is blacklisted")
                        return
                    end
                    ShowNotification("ADMIN", "Attempting " .. def.cmd .. " on " .. plr.Name)
                    if runAdminCommand(plr, def.cmd) then
                        activeCooldowns[def.cmd] = tick()
                        setGlobalVisualCooldown(def.cmd)
                        if def.cmd == "balloon" then
                            SharedState.BalloonedPlayers[plr.UserId] = true
                            for _, btn in ipairs(SharedState.AdminButtonCache["balloon"] or {}) do
                                if btn and btn.Parent then btn.BackgroundColor3 = Theme.Error end
                            end
                        end
                        ShowNotification("ADMIN", "Sent " .. def.cmd .. " to " .. plr.Name)
                    else
                        ShowNotification("ADMIN", "Failed to send " .. def.cmd .. " to " .. plr.Name)
                    end
                end
            end)
        end

        local blQuickBtn = Instance.new("TextButton", btnCont)
        blQuickBtn.Size = UDim2.new(0, 30, 0, 30)
        blQuickBtn.Position = UDim2.new(0, 4 + (#buttonsDef) * 40, 0.5, -15)
        blQuickBtn.AutoButtonColor = false
        blQuickBtn.Text = "X"
        blQuickBtn.TextSize = 13
        blQuickBtn.Font = Enum.Font.GothamBlack
        blQuickBtn.TextColor3 = Color3.fromRGB(255, 200, 200)
        blQuickBtn.ZIndex = 11
        blQuickBtn.Active = true
        blQuickBtn.BackgroundColor3 = Color3.fromRGB(120, 20, 20)
        blQuickBtn.BackgroundTransparency = 0
        Instance.new("UICorner", blQuickBtn).CornerRadius = UDim.new(0, 8)
        local blQuickStroke = Instance.new("UIStroke", blQuickBtn)
        blQuickStroke.Color = Color3.fromRGB(200, 50, 50)
        blQuickStroke.Thickness = 1.5
        blQuickStroke.Transparency = 0.3
        blQuickStroke.ZIndex = 12

        blQuickBtn.MouseEnter:Connect(function()
            blQuickBtn.BackgroundColor3 = Color3.fromRGB(180, 30, 30)
            blQuickStroke.Transparency = 0.05
        end)
        blQuickBtn.MouseLeave:Connect(function()
            blQuickBtn.BackgroundColor3 = Color3.fromRGB(120, 20, 20)
            blQuickStroke.Transparency = 0.3
        end)

        blQuickBtn.MouseButton1Click:Connect(function()
            local targetName = plr.Name
            local alreadyIn = false
            for _, n in ipairs(BlacklistedPlayers) do
                if n:lower() == targetName:lower() then
                    alreadyIn = true
                    break
                end
            end
            if alreadyIn then
                ShowNotification("BLACKLIST", targetName .. " is already blacklisted")
                return
            end
            table.insert(BlacklistedPlayers, targetName)
            Config.Blacklist = BlacklistedPlayers
            SaveConfig()
                if refreshBlacklistUI then refreshBlacklistUI() end
            blQuickBtn.BackgroundColor3 = Color3.fromRGB(30, 120, 50)
            blQuickBtn.Text = "OK"
            ShowNotification("BLACKLIST", "Blacklisted: " .. targetName)
            rebuildBlList()
            task.delay(1.2, function()
                if blQuickBtn and blQuickBtn.Parent then
                    blQuickBtn.BackgroundColor3 = Color3.fromRGB(120, 20, 20)
                    blQuickBtn.Text = "X"
                end
            end)
        end)
        local rowHighlight = Instance.new("Frame", row)
        rowHighlight.Size = UDim2.new(1, 0, 1, 0)
        rowHighlight.BackgroundColor3 = Theme.Accent1
        rowHighlight.BackgroundTransparency = 1
        rowHighlight.BorderSizePixel = 0
        rowHighlight.ZIndex = 1
        Instance.new("UICorner", rowHighlight).CornerRadius = UDim.new(0, 6)
        row.MouseEnter:Connect(function()
            rowHighlight.BackgroundTransparency = 0.7
        end)
        row.MouseLeave:Connect(function()
            rowHighlight.BackgroundTransparency = 1
        end)
        row.MouseButton1Click:Connect(function()
            local hasAnyAvailable = false
            for _, cmd in ipairs(ALL_COMMANDS) do
                if not isOnCooldown(cmd) then
                    hasAnyAvailable = true
                    break
                end
            end
            if hasAnyAvailable then
                if isBlacklisted(plr.Name) then
                    ShowNotification("ADMIN", plr.Name .. " is blacklisted")
                    return
                end
                triggerAll(plr)
                ShowNotification("ADMIN", "Triggered ALL on " .. plr.Name)
            end
        end)
        return row
    end

    local playerRows = {}
    local playerRowsByUserId = {}
    
    local function addPlayer(plr)
        if plr == LocalPlayer or playerRowsByUserId[plr.UserId] then return end
        if not Players:FindFirstChild(plr.Name) then return end
        
        if playerRows[plr] then return end
        
        local row = createPlayerRow(plr)
        playerRows[plr] = row
        playerRowsByUserId[plr.UserId] = {player = plr, row = row}
        listFrame.CanvasSize = UDim2.new(0,0,0, layout.AbsoluteContentSize.Y)
        sortAdminPanelList()
    end
    
    removePlayer = function(plr)
        local userId = plr and plr.UserId or nil
        local entry = userId and playerRowsByUserId[userId] or nil
        local row = entry and entry.row or playerRows[plr]
        
        if row then
            if row.Parent then
                for cmd, buttons in pairs(SharedState.AdminButtonCache) do
                    for i = #buttons, 1, -1 do
                        if buttons[i] and buttons[i].Parent == row then table.remove(buttons, i) end
                    end
                end
                row:Destroy()
            end
            if plr then playerRows[plr] = nil end
            if userId then playerRowsByUserId[userId] = nil end
            if SharedState.BalloonedPlayers and userId then SharedState.BalloonedPlayers[userId] = nil end
            listFrame.CanvasSize = UDim2.new(0,0,0, layout.AbsoluteContentSize.Y)
        end
    end

    refreshBtn.MouseButton1Click:Connect(function()
        for _, row in pairs(playerRows) do
            if row and row.Parent then
                for cmd, buttons in pairs(SharedState.AdminButtonCache) do
                    for i = #buttons, 1, -1 do
                        if buttons[i] and buttons[i].Parent == row then table.remove(buttons, i) end
                    end
                end
                row:Destroy()
            end
        end
        
        playerRows = {}
        playerRowsByUserId = {}
        SharedState.AdminButtonCache = {}
        SharedState.BalloonedPlayers = {}
        
        for _, child in ipairs(listFrame:GetChildren()) do
            if child:IsA("TextButton") then child:Destroy() end
        end
        
        task.wait(0.1)
        
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then 
                addPlayer(p) 
            end
        end
        sortAdminPanelList()
        
        ShowNotification("ADMIN PANEL", "Completely refreshed - " .. #Players:GetPlayers() - 1 .. " players found")
    end)

    Players.PlayerAdded:Connect(function(plr)
        task.wait(0.1)
        if plr and plr.Parent then addPlayer(plr) end
    end)
    
    Players.PlayerRemoving:Connect(function(plr)
        removePlayer(plr)
    end)
    
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then addPlayer(p) end
    end
    sortAdminPanelList()

    task.spawn(function()
        while listFrame and listFrame.Parent do
            task.wait(0.5)
            pcall(sortAdminPanelList)
        end
    end)
    
    task.spawn(function()
        while true do
            task.wait(1)
            local currentPlayerIds = {}
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LocalPlayer and p.Parent then currentPlayerIds[p.UserId] = true end
            end
            
            for userId, entry in pairs(playerRowsByUserId) do
                if not currentPlayerIds[userId] or not entry.player or not entry.player.Parent or not Players:FindFirstChild(entry.player.Name) then
                    removePlayer(entry.player)
                end
            end
            
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LocalPlayer and p.Parent and not playerRowsByUserId[p.UserId] then addPlayer(p) end
            end
        end
    end)
    
    layout.Changed:Connect(function() listFrame.CanvasSize = UDim2.new(0,0,0, layout.AbsoluteContentSize.Y) end)
end)

-- ================================================================
--  TP + STEAL ENGINE  (verbatim from standalones)
-- ================================================================
;(function()

-- Required locals missing from this scope
local T = {
    Ok   = Color3.fromRGB(100, 255, 160),
    Warn = Color3.fromRGB(255, 210,  80),
    Err  = Color3.fromRGB(255,  80,  80),
}
local MUTCOL = {
    None        = Color3.fromRGB(160, 160, 160),
    Cursed      = Color3.fromRGB(180,   0, 255),
    Gold        = Color3.fromRGB(255, 215,   0),
    Diamond     = Color3.fromRGB(100, 200, 255),
    YinYang     = Color3.fromRGB(200, 200, 200),
    Rainbow     = Color3.fromRGB(255, 100, 200),
    Lava        = Color3.fromRGB(255,  80,  20),
    Candy       = Color3.fromRGB(255, 150, 200),
    Bloodrot    = Color3.fromRGB(200,  20,  20),
    Radioactive = Color3.fromRGB(120, 255,  50),
    Divine      = Color3.fromRGB(255, 230, 100),
}
local SAVE_FILE = "JustAFanTPSteal_v1.json"
local selectedTargetIndex = 1

-- shared state for this scope
if not SharedState.AllAnimalsCache then SharedState.AllAnimalsCache = {} end
if not SharedState.WalkingCache     then SharedState.WalkingCache    = {} end

local stealNearest = Config.StealNearest or false
_G.isCloning       = false
local _panelRefs   = {}
local _guiLocked   = false
local _cfgLoaded   = false

SharedState.SetManualTarget = function(v) manualTarget = v end

-- bridges so the hub can read state
SharedState.GetIsTpMoving = function() return isTpMoving end

local BASES_HIGH = {
    [1]=Vector3.new(-476.47,20.73,220.94), [5]=Vector3.new(-342.54,20.70,221.45),
    [2]=Vector3.new(-476.57,20.71,113.77), [6]=Vector3.new(-342.86,20.67,113.41),
    [3]=Vector3.new(-476.87,20.74,6.18),   [7]=Vector3.new(-342.42,20.69,6.25),
    [4]=Vector3.new(-476.63,20.74,-101.07),[8]=Vector3.new(-342.79,20.75,-99.73),
}
local CLONE_FLOOR = {
    Vector3.new(-476,-4,221),Vector3.new(-476,-4,114),
    Vector3.new(-476,-4,7),  Vector3.new(-476,-4,-100),
    Vector3.new(-342,-4,-100),Vector3.new(-342,-4,6),
    Vector3.new(-342,-4,114),Vector3.new(-342,-4,220),
}
local FACE = {
    Vector3.new(-519,-3,221),Vector3.new(-519,-3,114),
    Vector3.new(-518,-3,7),  Vector3.new(-519,-3,-100),
    Vector3.new(-301,-3,-100),Vector3.new(-301,-3,7),
    Vector3.new(-302,-3,114),Vector3.new(-300,-3,220),
}
local BASES_LOW_2D = {
    [1]=Vector2.new(-460,219), [5]=Vector2.new(-355,217),
    [2]=Vector2.new(-460,111), [6]=Vector2.new(-355,113),
    [3]=Vector2.new(-460,5),   [7]=Vector2.new(-355,5),
    [4]=Vector2.new(-460,-100),[8]=Vector2.new(-355,-100),
}
-- 2nd floor open-side entry points (Y=15, no sign face, clone fires on arrival)
local F2_SIDE_POINTS = {
    Vector3.new(-488.88, 15, 196.38), Vector3.new(-487.79, 15, 138.13),
    Vector3.new(-489.38, 15,  89.23), Vector3.new(-489.69, 15,  30.98),
    Vector3.new(-488.75, 15, -17.95), Vector3.new(-490,    15, -75.90),
    Vector3.new(-331.75, 15, -75.80), Vector3.new(-329.98, 15, -18.16),
    Vector3.new(-330.04, 15,  31.14), Vector3.new(-331.28, 15,  88.92),
    Vector3.new(-330.57, 15, 138.10), Vector3.new(-330.01, 15, 195.96),
}
local function getClosestF2SidePoint(brainrotPos)
    local best, bd = nil, math.huge
    for _, v in ipairs(F2_SIDE_POINTS) do
        local d = (Vector2.new(v.X, v.Z) - Vector2.new(brainrotPos.X, brainrotPos.Z)).Magnitude
        if d < bd then bd = d; best = v end
    end
    return best
end
local F2_MED_POINTS = {
    {pos = Vector3.new(-410.65, -5.68, -46.10)},
    {pos = Vector3.new(-410.91, -5.68, 168.89)},
}

local function getNearestMedPoint(fromPos)
    local best, bd = nil, math.huge
    for _, e in ipairs(F2_MED_POINTS) do
        local d = (Vector2.new(fromPos.X, fromPos.Z) - Vector2.new(e.pos.X, e.pos.Z)).Magnitude
        if d < bd then bd = d; best = e end
    end
    return best
end

-- --- Priority list ------------------------------------------------------------
if not PRIORITY_LIST or #PRIORITY_LIST == 0 then
    PRIORITY_LIST = {
        "Headless Horseman",
        "Signore Carapace",
        "Elefanto Frigo",
        "Arcadragon",
        "Strawberry Elephant",
        "Antonio",
        "John Pork",
        "Meowl",
        "Love Love Bear",
        "Skibidi Toilet",
        "Ginger Gerat",
        "Griffin",
        "Dragon Gingerini",
        "Fishino Clownino",
        "La Supreme Combinasion",
        "Digi Narwhal",
        "Dragon Cannelloni",
        "Hydra Dragon Cannelloni",
        "Ketupat Bros",
        "La Casa Boo",
        "Hydra Bunny",
        "Duggy Bros",
        "Bunny and Eggy",
        "Cerberus",
        "Celestial Pegasus",
        "Rosey and Teddy",
        "Reinito Sleighito",
        "Capitano Moby",
        "Los Sekolahs",
        "Fragrama and Chocrama",
        "Spooky and Pumpky",
        "Cooki and Milki",
        "La Food Combinasion",
        "Los Amigos",
        "Burguro And Fryuro",
        "Popcuru and Fizzuru",
        "Garama and Madundung",
        "La Secret Combinasion",
        "La Romantic Grande",
        "La Taco Combinasion",
        "Los Spaghettis",
        "Swaggy Bros",
        "Sammyni Fattini",
        "Festive 67",
        "Ketchuru and Musturu",
        "Tang Tang Keletang",
        "Ketupat Kepat",
        "Tictac Sahur",
        "Tralaledon",
        "W or L",
        "Eviledon",
        "Lavadorito Spinito",
        "Spaghetti Tualetti",
        "Foxini Lanternini",
    }
end
local PRIORITY = PRIORITY_LIST

-- (Config uses hub global Config)


-- --- State --------------------------------------------------------------------
local isTpMoving      = false
SharedState.AllAnimalsCache = {}
SharedState.WalkingCache = {}
local _atBrainrot = false -- game-spawned walking brainrots
_G.isCloning          = false
local HttpService     = game:GetService("HttpService")
local tpMode          = "front" -- "front" or "side"
local _positionsLoaded = false
local _plotsTotal = 0
local _plotsScanned = 0
SharedState.PlotsTotal   = 0
SharedState.PlotsScanned = 0

-- --- Helpers -----------------------------------------------------------------
local function getChar()
    local c = LocalPlayer.Character
    return c, c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
end

local function getPingBonus()
    local ping = LocalPlayer:GetNetworkPing() * 1000 -- seconds to ms
    if ping < 50 then
        return 0        -- current settings, no extra wait
    elseif ping < 100 then
        return 0.05     -- +50ms
    elseif ping < 150 then
        return 0.10     -- +100ms
    else
        return 0.15     -- +150ms for 150-250+
    end
end

local function getControls()
    return require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule")):GetControls()
end

local function closestIdx(pos)
    local best, bd = 1, math.huge
    local p2 = Vector2.new(pos.X, pos.Z)
    for i, v in pairs(BASES_LOW_2D) do
        local d = (p2 - v).Magnitude
        if d < bd then bd = d; best = i end
    end
    return best
end

local function getClosestBaseSign(brainrotPart)
    if not brainrotPart or not brainrotPart:IsA("BasePart") then return nil end
    local closestPart, closestDist = nil, math.huge
    for _, label in ipairs(Workspace:GetDescendants()) do
        if label:IsA("TextLabel") then
            local txt = tostring(label.Text or "")
            if txt ~= "" and txt:lower():find("base", 1, true) then
                local gui = label:FindFirstAncestorWhichIsA("SurfaceGui")
                if gui then
                    local part = gui.Adornee or gui.Parent
                    if part and part:IsA("BasePart") then
                        local dist = (part.Position - brainrotPart.Position).Magnitude
                        if dist < closestDist then
                            closestDist = dist
                            closestPart = part
                        end
                    end
                end
            end
        end
    end
    return closestPart
end

-- --- Anti-die ----------------------------------------------------------------
local antiDieDisabled = false
local antiDieConn     = nil
local function setupAntiDie()
    _G.tpAntiDieDisable = function()
    antiDieDisabled = true
    if antiDieConn then pcall(function() antiDieConn:Disconnect() end); antiDieConn = nil end
end
_G.tpAntiDieEnable = function()
    antiDieDisabled = false
    setupAntiDie()
end
    if antiDieDisabled then return end
    if _G.antiDieDisabled then return end
    local c, _, hum = getChar()
    if not hum then return end
    if antiDieConn then pcall(function() antiDieConn:Disconnect() end) end
    antiDieConn = hum:GetPropertyChangedSignal("Health"):Connect(function()
        if not antiDieDisabled and hum.Health <= 0 then
            hum.Health = hum.MaxHealth
        end
    end)
end
setupAntiDie()
LocalPlayer.CharacterAdded:Connect(function() task.wait(0.3); setupAntiDie() end)

-- --- walkForward -------------------------------------------------------------
local function walkForward(seconds, direction)
        local c, hrp = getChar()
        if not hrp then return end
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hum then return end
        local lookVector = hrp.CFrame.LookVector
        local controls = getControls()
        controls:Disable()
        local startTime = os.clock()
                local conn
        conn = RunService.RenderStepped:Connect(function()
                if os.clock() - startTime >= seconds then
                        conn:Disconnect()
                        hum:Move(Vector3.zero, false)
                        controls:Enable()
                        return
                end
                hum:Move(lookVector, false)
        end)
end
-- --- instantClone ------------------------------------------------------------
-- DRASTICALLY simplified to match Flash Hub's proven pattern: equip -> Activate
-- -> wait 50ms -> fire MouseButton1Up ONCE. No anchor, no CFrame snapping, no
-- spam, no multi-signal-path firing. The game's QC is happy with a single
-- MouseButton1Up; firing multiple signal types caused the position swap chaos.
local function instantClone()
    if _G.isCloning then return end
    _G.isCloning = true

    -- Best-effort cleanup of any anchor state left over from earlier code paths
    -- (kept as a no-op for fresh runs; harmless if these globals are nil).
    if _G._cloneSpotAnchor then
        local _ah = _G._cloneSpotAnchor
        if _ah and _ah.Parent then pcall(function() _ah.Anchored = false end) end
        _G._cloneSpotAnchor = nil
    end
    _G._cloneSpotLockCF = nil
    if _G._cloneSpotAutoRotate then
        local _ar = _G._cloneSpotAutoRotate
        if _ar.hum and _ar.hum.Parent then pcall(function() _ar.hum.AutoRotate = _ar.prev end) end
        _G._cloneSpotAutoRotate = nil
    end

    local cloneName = tostring(LocalPlayer.UserId).."_Clone"
    local stale = Workspace:FindFirstChild(cloneName)
    if stale then stale:Destroy() end

    local c, _, hum = getChar()
    if not c or not hum then _G.isCloning = false; return end

    local cloner = LocalPlayer.Backpack:FindFirstChild("Quantum Cloner")
                or c:FindFirstChild("Quantum Cloner")
    if not cloner then _G.isCloning = false; return end

    -- Equip the cloner and WAIT for it to actually be in the character before
    -- firing Activate. A bare task.wait() is one frame - often the cloner is
    -- still mid-equip (parented to nil or Backpack transitionally) and
    -- Activate fires on a stale reference, which the server can drop or
    -- misroute. Poll up to 0.3s for cloner.Parent == character.
    if cloner.Parent ~= c then
        hum:EquipTool(cloner)
        local _equipStart = tick()
        while tick() - _equipStart < 0.3 do
            if cloner.Parent == c then break end
            RunService.Heartbeat:Wait()
        end
    end

    local tf = PlayerGui:FindFirstChild("ToolsFrames")
    local qc = tf and tf:FindFirstChild("QuantumCloner")
    local btn = qc and qc:FindFirstChild("TeleportToClone")
    if not btn then _G.isCloning = false; return end

    cloner:Activate()
    task.wait(0.05)

    btn.Visible = true
    if typeof(firesignal) == "function" then
        pcall(firesignal, btn.MouseButton1Up)
    end

    _G.isCloning = false
end

-- --- findAdorneeGlobal -------------------------------------------------------
local function findAdorneeGlobal(a)
    if not a then return nil end
        if a.isWalking then
        if a.model and a.model.Parent then
            return a.model:FindFirstChild("HumanoidRootPart", true)
                or a.model.PrimaryPart
                or a.model:FindFirstChildWhichIsA("BasePart", true)
        end
        return nil
    end
    local plots = Workspace:FindFirstChild("Plots")
    if not plots then return nil end
    local plot = plots:FindFirstChild(a.plot); if not plot then return nil end
    local pods = plot:FindFirstChild("AnimalPodiums"); if not pods then return nil end
    local pod  = pods:FindFirstChild(a.slot); if not pod then return nil end
    local base = pod:FindFirstChild("Base"); if not base then return nil end
    local sp   = base:FindFirstChild("Spawn")
    return sp or base:FindFirstChildWhichIsA("BasePart") or base
end
_G.findAdorneeGlobal = findAdorneeGlobal

-- --- isPlotUnlocked ----------------------------------------------------------
local function isPlotUnlocked(plotName)
    local ok, res = pcall(function()
        local plots = Workspace:FindFirstChild("Plots"); if not plots then return false end
        local plot  = plots:FindFirstChild(plotName);   if not plot  then return false end
        local uf    = plot:FindFirstChild("Unlock");    if not uf    then return true  end
        local items = {}
        for _, item in pairs(uf:GetChildren()) do
            local pos
            if item:IsA("Model") then pcall(function() pos = item:GetPivot().Position end)
            elseif item:IsA("BasePart") then pos = item.Position end
            if pos then table.insert(items,{obj=item,Y=pos.Y}) end
        end
        table.sort(items,function(a,b) return a.Y<b.Y end)
        if #items==0 then return true end
        for _,d in ipairs(items[1].obj:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.Enabled then return false end
        end
        for _,d in ipairs(items[1].obj:GetChildren()) do
            if d:IsA("ProximityPrompt") and d.Enabled then return false end
        end
        return true
    end)
    return ok and res or false
end


-- --- equipCarpet -------------------------------------------------------------
local function equipCarpet()
    local c,_,hum = getChar()
    if not c or not hum then return end
    local t = LocalPlayer.Backpack:FindFirstChild(Config.TpSettings.Tool) or c:FindFirstChild(Config.TpSettings.Tool)
    if t then hum:EquipTool(t) end
end

-- --- Reset isTpMoving on respawn ---------------------------------------------
LocalPlayer.CharacterAdded:Connect(function(newChar)
    isTpMoving   = false
    _G.isCloning = false
    task.spawn(function()
        local hrp = newChar:WaitForChild("HumanoidRootPart", 10)
        local hum = newChar:WaitForChild("Humanoid", 10)
        if not hrp or not hum then return end
        -- Equip carpet on respawn only in tween mode; clone TP uses Bat+Cloner
        if (Config.TpMethod or "tween") ~= "clone" then
            local tool = LocalPlayer.Backpack:FindFirstChild(Config.TpSettings.Tool)
            if not tool then
                local conn
                conn = LocalPlayer.Backpack.ChildAdded:Connect(function(child)
                    if child.Name == Config.TpSettings.Tool then
                        conn:Disconnect()
                        if hum and hum.Parent then hum:EquipTool(child) end
                    end
                end)
            else
                hum:EquipTool(tool)
            end
        end
        
    end)
end)
        

-- --- Duel detection ----------------------------------------------------------
local function isOwnerInDuel(ownerName)
    if not ownerName then return false end
    local ownerPlayer = Players:FindFirstChild(ownerName)
    return ownerPlayer and ownerPlayer:GetAttribute("duelsblocksteal") == true or false
end

-- --- Side TP helpers ---------------------------------------------------------
local function findFlyingCarpet()
    local map = Workspace:FindFirstChild("Map"); if not map then return nil end
    local carpet = map:FindFirstChild("Carpet"); if not carpet then return nil end
    if carpet:IsA("Model") then
        if carpet.PrimaryPart then return carpet.PrimaryPart end
        for _, cv in ipairs(carpet:GetChildren()) do if cv:IsA("BasePart") then return cv end end
    elseif carpet:IsA("BasePart") then return carpet end
    return nil
end

local function findClaimModel(podium)
    if not podium or not podium.Parent then return nil end
    local claim = podium:FindFirstChild("Claim")
    if claim and claim:IsA("Model") then
        if claim.PrimaryPart then return claim.PrimaryPart end
        for _, cv in ipairs(claim:GetChildren()) do if cv:IsA("BasePart") then return cv end end
    end
    return nil
end

local function getTargetPodiumAndSafePosition(animalData, fallbackPos)
    if not animalData or not animalData.plot then return nil, fallbackPos end
    local plots = Workspace:FindFirstChild("Plots")
    local plot = plots and plots:FindFirstChild(animalData.plot)
    local podiums = plot and plot:FindFirstChild("AnimalPodiums")
    if not podiums then return nil, fallbackPos end
    local animalPod = podiums:FindFirstChild(animalData.slot)
    local animalBase = animalPod and animalPod:FindFirstChild("Base")
    local animalSpawn = animalBase and animalBase:FindFirstChild("Spawn")
    local animalY = animalSpawn and animalSpawn:IsA("BasePart") and animalSpawn.Position.Y or (fallbackPos and fallbackPos.Y or 0)
    -- floor 1 animals -> find floor 1 slot (Y <= 10)
    -- floor 2 AND floor 3 animals -> find floor 2 slot (Y 10-35), never floor 3
    local floorMin = animalY <= 10 and -20 or 10
    local floorMax = animalY <= 10 and 10  or 35
    -- try hardcoded slots first
    local safeName = animalY > 10 and "13" or "3"
    local safePod = podiums:FindFirstChild(safeName)
    local safeBase = safePod and safePod:FindFirstChild("Base")
    local safeSpawn = safeBase and safeBase:FindFirstChild("Spawn")
    local safePos = safeSpawn and safeSpawn:IsA("BasePart") and safeSpawn.Position or nil
    -- if hardcoded slot is outside the target floor range, scan for a valid one
    if not safePos or safePos.Y < floorMin or safePos.Y > floorMax then
        safePod = nil; safePos = nil
        for _, pod in ipairs(podiums:GetChildren()) do
            local b = pod:FindFirstChild("Base")
            local s = b and b:FindFirstChild("Spawn")
            if s and s:IsA("BasePart") and s.Position.Y >= floorMin and s.Position.Y <= floorMax then
                safePod = pod; safePos = s.Position; break
            end
        end
    end
    return safePod or animalPod, safePos or fallbackPos
end

-- --- computeFrontRoute -------------------------------------------------------
-- Picks the clone-in spot (closest reachable point to the base sign) and the
-- PathfindingService route to it. Shared by the live snipe AND the background
-- pre-computer so the route can be ready the instant the player presses TP.
-- Returns: targetBasePos, waypoints, usedPathfinding, signPart, isSecondFloor, exactPos
local PathfindingService = game:GetService("PathfindingService")
local _frontRouteCache = nil  -- { uid, startFlat(Vector2), targetBasePos, waypoints, usedPathfinding, signPart, at }

local function computeFrontRoute(part, fromPos)
    local exactPos = part.Position
    local isSecondFloor = exactPos.Y > 10
    local signPart = getClosestBaseSign(part)

    -- DYNAMIC clone-in target off the sign. 20 studs is the HARD MAX distance from the sign:
    -- we never clone farther out than that. We may clone CLOSER (down to ~8 studs) if a closer
    -- spot gives a shorter/faster navmesh route. Candidate offsets are tried from closest to
    -- farthest; the first reachable one wins (closest reachable = lands nearest the brainrot and
    -- is the shortest forward nudge). Capping to a handful of candidates keeps the TP fast.
    local targetBasePos
    local waypoints, usedPathfinding = {}, false

    local function tryPath(dst, srcY)
        local ok, wps, success = pcall(function()
            -- STRICTER agent dimensions to force the pathfinder to give wider
            -- berth around props/structures (cyber wheel, trade machines,
            -- robux stand, etc.). Previous values (6/8) still let the route
            -- squeeze too close - char + carpet footprint wouldn't actually
            -- fit through the gap and we'd clip the obstacle.
            --
            -- AgentRadius 10 = path must have â‰¥20-stud clearance from any
            -- obstacle. AgentHeight 10 = path must have â‰¥10-stud vertical
            -- headroom. Big enough that the actual character + flying-carpet
            -- envelope always fits with margin.
            local path = PathfindingService:CreatePath({
                AgentRadius     = 10,
                AgentHeight     = 10,
                AgentCanJump    = false,
                WaypointSpacing = 10,
            })
            path:ComputeAsync(Vector3.new(fromPos.X, srcY, fromPos.Z), dst)
            if path.Status ~= Enum.PathStatus.Success then return nil, false end
            local out = {}
            for _, wp in ipairs(path:GetWaypoints()) do table.insert(out, wp.Position) end
            return out, (#out > 0)
        end)
        if ok and success then return wps, true end
        return nil, false
    end

    -- Clearance is checked at the ACTUAL low flight altitude (route floor + a little) for
    -- BOTH floors, because we no longer cruise at Y17. So a straight line is only taken when
    -- the LOW path is genuinely clear; if a wall/structure blocks it we navmesh around it at
    -- floor level. This is the primary (and safe) obstacle avoidance for floor-1 flights.
    local function cruiseYFor(floorY)
        return floorY + 6
    end

    -- True when a straight flight at cruise height from our spot to dst is clear.
    -- A hit within ~8 studs of dst is just the base we're flying into (not a mid-route
    -- obstacle) so we ignore it. Clear => fly straight, no pathfinding. Only a real
    -- mid-route blocker makes us navmesh around it - "don't do anything that isn't needed".
    -- Plots whose OWN walls must NOT count as clearance blockers. Two of them:
    --   destPlot  â€“ the base we're flying INTO (the wall right at the destination).
    --   myPlot    â€“ OUR OWN base, which the ray ORIGIN sits inside/next to, so its perimeter
    --               wall would otherwise block the very first stud of every flight and force
    --               a needless Y17 climb.
    -- Free-standing map objects (trees/rocks) live OUTSIDE Plots and are still detected, so the
    -- legitimate "object next to the base, would clip if low" Y17 climb is preserved.
    local plotsFolder = Workspace:FindFirstChild("Plots")
    local function plotOf(inst)
        local node = inst
        while node and node.Parent do
            if node.Parent == plotsFolder then return node end
            node = node.Parent
        end
        return nil
    end
    local destPlot = signPart and plotOf(signPart) or nil
    local myPlot = nil
    if plotsFolder then
        local meName, meDisp = LocalPlayer.Name:lower(), LocalPlayer.DisplayName:lower()
        for _, plot in ipairs(plotsFolder:GetChildren()) do
            local sign = plot:FindFirstChild("PlotSign")
            local label = sign and sign:FindFirstChildWhichIsA("TextLabel", true)
            if label then
                local t = tostring(label.Text or ""):lower()
                if t:find(meName, 1, true) or t:find(meDisp, 1, true) then myPlot = plot; break end
            end
        end
    end

    local function straightClear(dst, cruiseY)
        local char = LocalPlayer.Character
        local origin = Vector3.new(fromPos.X, cruiseY, fromPos.Z)
        local destC  = Vector3.new(dst.X, cruiseY, dst.Z)
        local d = destC - origin
        if d.Magnitude < 2 then return true end
        -- Exclude our own char AND our own hub-spawned helpers: the red XiTempPlatform parts
        -- (left over for ~25s by prior teleports) and the clone. They are zero-width-ray
        -- "obstacles" that would otherwise force a needless navmesh detour up to Y17.
        local ignore = { char }
        for _, c in ipairs(Workspace:GetChildren()) do
            if c.Name == "XiTempPlatform" then table.insert(ignore, c) end
        end
        local clone = Workspace:FindFirstChild(tostring(LocalPlayer.UserId) .. "_Clone")
        if clone then table.insert(ignore, clone) end
        -- ...and the destination base's structure AND our own base's structure (see above).
        if destPlot then table.insert(ignore, destPlot) end
        if myPlot then table.insert(ignore, myPlot) end
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Exclude
        rp.FilterDescendantsInstances = ignore
        local hit = Workspace:Raycast(origin, d, rp)
        return (not hit) or (hit.Position - destC).Magnitude <= 8
    end

    if signPart then
        local FWD = signPart.CFrame.LookVector
        local floorY = isSecondFloor and (signPart.Position.Y + 4) or -4.8
        local cruiseY = cruiseYFor(floorY)
        local myFlat = Vector2.new(fromPos.X, fromPos.Z)
        -- pick the side (front/back of the sign) that is closer to us at the 20-stud edge
        local frontEdge = signPart.Position + (FWD * 20)
        local backEdge  = signPart.Position - (FWD * 20)
        local useBack = (Vector2.new(backEdge.X, backEdge.Z) - myFlat).Magnitude
                      < (Vector2.new(frontEdge.X, frontEdge.Z) - myFlat).Magnitude
        local dir = useBack and -FWD or FWD

        -- candidate offsets, closest first, never exceeding the 20-stud cap
        local offsets = { 8, 12, 16, 20 }

        -- PASS 1 (preferred): closest spot we can reach with a CLEAN STRAIGHT flight.
        -- usedPathfinding stays false, so travel flies one straight line + the normal
        -- final-approach descent. No extra movement when nothing is in the way.
        for _, off in ipairs(offsets) do
            local p = signPart.Position + (dir * off)
            local cand = Vector3.new(p.X, floorY, p.Z)
            if straightClear(cand, cruiseY) then
                targetBasePos = cand
                break
            end
        end

        -- PASS 2 (only if a real obstacle blocks every straight approach): navmesh
        -- around it. Closest reachable offset wins.
        if not targetBasePos then
            for _, off in ipairs(offsets) do
                local p = signPart.Position + (dir * off)
                local cand = Vector3.new(p.X, floorY, p.Z)
                local wps, ok = tryPath(cand, floorY)
                if ok then
                    targetBasePos = cand
                    waypoints = wps
                    usedPathfinding = true
                    local lw = wps[#wps]
                    if Vector2.new(lw.X - cand.X, lw.Z - cand.Z).Magnitude > 2 then
                        table.insert(waypoints, cand)
                    end
                    break
                end
            end
        end

        -- nothing worked: straight-line fall back to the 20-stud edge
        if not targetBasePos then
            targetBasePos = Vector3.new(
                (useBack and backEdge or frontEdge).X, floorY,
                (useBack and backEdge or frontEdge).Z)
        end
    elseif isSecondFloor then
        local bd2 = math.huge
        for _, v in pairs(BASES_HIGH) do
            local d = (Vector2.new(exactPos.X, exactPos.Z) - Vector2.new(v.X, v.Z)).Magnitude
            if d < bd2 then bd2 = d; targetBasePos = Vector3.new(v.X, v.Y + 2, v.Z) end
        end
    else
        local bd2 = math.huge
        for _, v in ipairs(CLONE_FLOOR) do
            local d = (exactPos - v).Magnitude
            if d < bd2 then bd2 = d; targetBasePos = v end
        end
    end
    if not targetBasePos then return nil, {}, false, signPart, isSecondFloor, exactPos end

    -- Non-sign fallbacks: fly straight when the cruise path is clear; only navmesh
    -- when something actually blocks it.
    if not usedPathfinding and not straightClear(targetBasePos, cruiseYFor(targetBasePos.Y)) then
        local wps, ok = tryPath(targetBasePos, targetBasePos.Y)
        if ok then
            waypoints = wps
            usedPathfinding = true
            local lw = wps[#wps]
            if Vector2.new(lw.X - targetBasePos.X, lw.Z - targetBasePos.Z).Magnitude > 2 then
                table.insert(waypoints, targetBasePos)
            end
        end
    end
    return targetBasePos, waypoints, usedPathfinding, signPart, isSecondFloor, exactPos
end

-- --- runAutoSnipe ------------------------------------------------------------
local function runAutoSnipe(retryCount)
    if isTpMoving then return end
    if _G.JAF_RemoveLoadingScreen then _G.JAF_RemoveLoadingScreen() end
    -- First-load auto-snipe only: start the 1.3s steal hold mid-flight so it finishes
    -- ~100ms AFTER we reach the brainrot instead of waiting the whole hold on arrival.
    -- Consumed here so manual TP presses and retries never use the timed start.
    local useStealTiming = (SharedState.FirstLoadSteal == true)
    SharedState.FirstLoadSteal = false
    task.delay(25, function() if isTpMoving then isTpMoving = false end end)
    local activeTpMode = tpMode -- snapshot NOW before any yields

    -- snapshot the character at the start of this run
    -- if character changes (respawn) mid-run, alive() returns false and we abort
    local startChar = LocalPlayer.Character
    local function alive()
        return LocalPlayer.Character == startChar and startChar ~= nil
    end

    local targetPetData = nil
    if manualTarget then
        targetPetData = manualTarget
    else
        local pickStart = tick()
        repeat
            local bestRank = math.huge
            local bestGen  = -math.huge
            -- pass 1: base brainrots (priority ranked)
            for _, a in ipairs(SharedState.AllAnimalsCache) do
                if a and a.owner ~= LocalPlayer.Name and not isOwnerInDuel(a.owner) then
                    if Config.AutoTPPriority ~= false then
                        local rank = math.huge
                        local aLow = a.name and a.name:lower()
                        for i, pName in ipairs(PRIORITY_LIST) do
                            if pName:lower() == aLow then rank = i; break end
                        end
                        if rank < bestRank or (rank == bestRank and a.genValue > bestGen) then
                            bestRank = rank
                            bestGen  = a.genValue
                            targetPetData = a
                        end
                    else
                        if a.genValue > bestGen then
                            bestGen = a.genValue
                            targetPetData = a
                        end
                    end
                end
            end
            -- walking (carpet) brainrots are intentionally NOT auto-snipe targets - they
            -- stay in WalkingCache for auto buy only, never for TP / target selection.
            if not targetPetData then task.wait(0.05) end
        until targetPetData or tick()-pickStart > 10 or not alive()
    end

    if not targetPetData or not alive() then isTpMoving = false; return end

    local c, hrp, hum = getChar()
    if not hrp or not hum or hum.Health<=0 then isTpMoving = false; return end

    isTpMoving = true

    -- Backup: if carpet not equipped yet wait every Heartbeat frame until it is.
    -- Exits immediately if already equipped so there is zero extra delay normally.
    do
        local c2, _, hum2 = getChar()
        if c2 and not c2:FindFirstChild(Config.TpSettings.Tool) then
            local carpetWaitStart = tick()
            local done = false
            local hbConn
            hbConn = RunService.Heartbeat:Connect(function()
                if done then return end
                local cc, _, hh = getChar()
                if cc and cc:FindFirstChild(Config.TpSettings.Tool) then
                    done = true; hbConn:Disconnect()
                    return
                end
                local inBp = LocalPlayer.Backpack:FindFirstChild(Config.TpSettings.Tool)
                if inBp and hh and hh.Parent then hh:EquipTool(inBp) end
                if tick()-carpetWaitStart > 3 then
                    done = true; hbConn:Disconnect()
                end
            end)
            while not done and alive() do RunService.Heartbeat:Wait() end
            hbConn:Disconnect()
        end
    end
    if not alive() then isTpMoving=false; return end

    local part = findAdorneeGlobal(targetPetData)
    if not part or not alive() then isTpMoving=false; return end
        -- Walking brainrot: TP to hover above it
    if targetPetData.isWalking then
        equipCarpet()
        task.wait(0.01)
        if not alive() then isTpMoving=false; return end
        c, hrp = getChar()
        if hrp then
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.CFrame = CFrame.new(part.Position + Vector3.new(0, 3, 0))
        end
        isTpMoving = false
        return
    end
    if activeTpMode == "front" then
    -- -- FRONT TP ----------------------------------------------------------
    local exactPos = part.Position

    local isSecondFloor = exactPos.Y > 10
    local idx = closestIdx(exactPos)

    equipCarpet(); task.wait(0.01)
    if not alive() then isTpMoving=false; return end
    c, hrp = getChar()

    -- First-load only: start holding the steal prompt NOW (during flight). The hold is
    -- released the moment we reach the brainrot, so we don't sit there for the full 1.3s.
    if useStealTiming and SharedState.BeginHeldSteal then
        SharedState.BeginHeldSteal(targetPetData, exactPos)
    end

    -- Reuse the route the background pre-computer already solved for THIS target from near
    -- our current spot (the route is ready the instant we press TP). Otherwise compute it
    -- now. computeFrontRoute also returns signPart, used for final facing.
    local signPart, targetBasePos, waypoints, usedPathfinding
    do
        local cached = _frontRouteCache
        if cached and cached.uid == targetPetData.uid and cached.targetBasePos
           and (tick() - cached.at) < 6
           and Vector2.new(hrp.Position.X - cached.startFlat.X, hrp.Position.Z - cached.startFlat.Y).Magnitude < 30 then
            signPart        = cached.signPart
            targetBasePos   = cached.targetBasePos
            waypoints       = cached.waypoints
            usedPathfinding = cached.usedPathfinding
            print("[JustAFan TP] using pre-computed cached route ("..#waypoints.." waypoints)")
        else
            targetBasePos, waypoints, usedPathfinding, signPart = computeFrontRoute(part, hrp.Position)
            print("[JustAFan TP] computed route on demand ("..#waypoints.." waypoints)")
        end
    end

    if not targetBasePos then isTpMoving = false; return end

    -- Compute the "face straight into the base" rotation NOW so we can hold it for the
    -- WHOLE flight instead of snapping to it right before we land.
    --
    -- Direction derived from the BASE COLUMN. The central road runs between the two
    -- columns at midline X=-409; players approach bases from BETWEEN columns and
    -- enter HEADING AWAY from the central road (each column faces outward):
    --   - left col (X < -409) -> face -X (away from central road, into base)
    --   - right col (X > -409) -> face +X (away from central road, into base)
    -- (Previous attempt had this flipped - was facing backwards out of the base.)
    local _faceCF, _faceRot
    do
        local intoBaseDir = (targetBasePos.X < -409) and Vector3.new(-1, 0, 0) or Vector3.new(1, 0, 0)
        _faceCF  = CFrame.lookAt(targetBasePos, targetBasePos + intoBaseDir)
        _faceRot = _faceCF - _faceCF.Position
    end

    -- No forced rise to a fixed cruise height. We fly the pathfinder route at its OWN
    -- altitude (route Y + a small hover) and only climb when the dynamic obstacle scan or
    -- a stall says we must - so we trace the visible route instead of shooting up to Y17
    -- and dropping back down to the base.
    if not hrp or not alive() then isTpMoving=false; return end
    hrp.AssemblyLinearVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z)
    if not alive() then isTpMoving=false; return end

-- Velocity travel: follow the PathfindingService route at its OWN altitude (route Y +
-- a small hover), rising over obstacles only when the dynamic scan says to. No fixed
-- cruise height and no forced jump-up - we trace the visible route the whole way and
-- the route's own descent toward the base brings us down.
    do
        c, hrp = getChar()
        if hrp and alive() then
            local VL_SPEED  = isSecondFloor
                and (Config.TpSettings.TpSpeedF2 or 130)
                or  (Config.TpSettings.TpSpeedF1 or 130)
            -- We follow the pathfinder route's OWN altitude: each waypoint sits on the
            -- walkable floor, so flying at (route Y + a small hover) traces the route the
            -- player sees instead of rising to a fixed cruise height and dropping back down.
            local HOVER         = 4    -- skim this far above the route's own floor height
            local ARRIVE_DIST   = 6    -- remaining route distance at which we hand off

            -- Route was pre-computed on the ground, so there is no compute gap here -
            -- travel starts immediately. If pathfinding failed, fall back to a straight line.
            if not usedPathfinding or #waypoints == 0 then
                waypoints = { hrp.Position, targetBasePos }
            end

            -- Flight mode: rise to the configured cruise altitude (per-floor), hold it
            -- FLAT for the entire horizontal flight, then descend straight to the final
            -- altitude once near the base (inside NEAR_END_DIST) or at the earliest
            -- safe-descent waypoint. NO route-altitude following during cruise or descent -
            -- that caused up/down oscillation when intermediate waypoints had higher Ys.
            local NEAR_END_DIST = 42
            -- Per-floor cruise altitudes. Falls back to legacy CruiseY then sensible
            -- defaults (Y17 for floor 1, Y19 for floor 2/3 - the 2nd-floor walkable
            -- surface is at ~Y15, so Y19 = surface + HOVER).
            local CRUISE_Y_F1 = Config.TpSettings.CruiseY_F1 or Config.TpSettings.CruiseY or 17
            local CRUISE_Y_F2 = Config.TpSettings.CruiseY_F2 or Config.TpSettings.CruiseY or 19
            local CRUISE_Y    = isSecondFloor and CRUISE_Y_F2 or CRUISE_Y_F1
            -- Cruise altitude held FLAT for the whole horizontal flight. Lifted to the
            -- destination's own walkable Y if that's higher (defensive - shouldn't happen
            -- with sensible per-floor CruiseY values).
            local riseTargetY = math.max(CRUISE_Y, targetBasePos.Y + HOVER)
            -- Final altitude we descend to (last waypoint's walkable Y + hover). FLAT
            -- descent target - no following intermediate route Ys, no descend-then-ascend.
            local finalY = ((waypoints[#waypoints]) or targetBasePos).Y + HOVER

            -- â”€â”€ Suffix path lengths (2D) so descent timing follows the real route â”€â”€
            local n = #waypoints
            local suffix = {}            -- suffix[i] = route dist from waypoints[i] to the end
            suffix[n] = 0
            for i = n - 1, 1, -1 do
                local a, b = waypoints[i], waypoints[i + 1]
                suffix[i] = suffix[i + 1] + Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
            end
            -- remaining route distance from a position currently heading to waypoints[idx]
            local function remainingFrom(px, pz, idx)
                local w = waypoints[idx] or targetBasePos
                return Vector2.new(px - w.X, pz - w.Z).Magnitude + (suffix[idx] or 0)
            end
            -- Follow the route's OWN altitude: each waypoint sits on the walkable floor, so
            -- flying at (segment-interpolated route Y + a small hover) traces the visible
            -- navmesh route up and down. We do NOT scan for obstacles from above - that made
            -- us fly over base roofs (way too high). The navmesh already avoids walls in XZ,
            -- and the stall-climb below handles anything we physically bump into.
            local function routeYAt(px, pz, idx)
                local cur  = waypoints[idx] or targetBasePos
                local prev = waypoints[idx - 1]
                if not prev then return cur.Y + HOVER end
                local seg = Vector2.new(cur.X - prev.X, cur.Z - prev.Z)
                local segLen = seg.Magnitude
                if segLen < 0.1 then return cur.Y + HOVER end
                local toMe = Vector2.new(px - prev.X, pz - prev.Z)
                local frac = math.clamp(toMe:Dot(seg) / (segLen * segLen), 0, 1)
                return (prev.Y + (cur.Y - prev.Y) * frac) + HOVER
            end

            -- â”€â”€ Earliest safe descent point along the pathfinder route â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
            -- For each waypoint, raycast downward from cruise altitude. The earliest
            -- waypoint where the ray's first hit is AT or BELOW the route's own floor
            -- (nothing solid above it) is a safe place to start descending. We require
            -- the safe stretch to extend all the way to the LAST waypoint - the descent
            -- latch is one-way, so we must not engage it at a safe spot and then hit
            -- an obstacle further along.
            --
            -- Result: descend SOONER when the path is open. If no overhead structures
            -- block the route, we can drop to navmesh altitude right after the rise,
            -- instead of holding Y17 cruise the whole way and plummeting at the end.
            -- Falls back to the NEAR_END_DIST=42 trigger if no safe spot is found.
            local descentStartIdx = n + 1
            do
                local _ignore = { c }
                for _, ch in ipairs(Workspace:GetChildren()) do
                    if ch.Name == "XiTempPlatform" or ch.Name == "XiTPPath" then
                        table.insert(_ignore, ch)
                    end
                end
                local _cloneInst = Workspace:FindFirstChild(tostring(LocalPlayer.UserId) .. "_Clone")
                if _cloneInst then table.insert(_ignore, _cloneInst) end
                local _rp = RaycastParams.new()
                _rp.FilterType = Enum.RaycastFilterType.Exclude
                _rp.FilterDescendantsInstances = _ignore

                local function _safeAt(idx)
                    local wp = waypoints[idx]; if not wp then return false end
                    -- Descent target is finalY (flat). Check the vertical column from
                    -- cruise altitude down to finalY is clear of obstacles at this XZ.
                    if finalY >= riseTargetY - 0.5 then return true end
                    local origin = Vector3.new(wp.X, riseTargetY + 1, wp.Z)
                    local dir = Vector3.new(0, -(riseTargetY - finalY + 3), 0)
                    local hit = Workspace:Raycast(origin, dir, _rp)
                    if not hit then return true end
                    return hit.Position.Y <= finalY + 1.5
                end

                -- Scan backward from the end, tracking the earliest contiguous safe waypoint.
                for i = n, 1, -1 do
                    if _safeAt(i) then descentStartIdx = i else break end
                end

                -- Cap how EARLY we engage descent. Even if waypoint 1's vertical column is
                -- clear, descending right after the rise drops us at low altitude while still
                -- near our own plot's walls / structures - and the per-waypoint raycast can't
                -- see obstacles between waypoints. Require the route remaining at descent
                -- engagement to be <= MAX_EARLY_DESCENT_DIST. If the cap pushes descentStartIdx
                -- past n, the NEAR_END_DIST=42 fallback in the flight loop still triggers
                -- descent at the end.
                local MAX_EARLY_DESCENT_DIST = 80
                while descentStartIdx <= n and (suffix[descentStartIdx] or 0) > MAX_EARLY_DESCENT_DIST do
                    descentStartIdx = descentStartIdx + 1
                end
            end

            -- â”€â”€ Blue path visualizer: a line tracing the planned flight route â”€â”€
            -- Parent it INSIDE the character: the FPS-boost stripVisuals hook disables
            -- beams and the world-optimizer destroys them when they're under Workspace,
            -- which is why the route line was invisible. Both cleaners skip anything that
            -- is a descendant of the player character, so the beams survive here.
            if _G._tpPathViz then pcall(function() _G._tpPathViz:Destroy() end); _G._tpPathViz = nil end
            local vizParent = (c and c.Parent) and c or Workspace
            local pathFolder = Instance.new("Folder")
            pathFolder.Name = "XiTPPath"
            pathFolder.Parent = vizParent
            _G._tpPathViz = pathFolder
            do
                local prevAtt
                for i = 1, n do
                    local wpPos = waypoints[i]
                    -- Match the actual flight altitude: FLAT cruise at riseTargetY before
                    -- the safe-descent waypoint, FLAT descent at finalY at/after. No
                    -- per-waypoint altitude variation - descent is a straight drop, not a
                    -- terrain-following curve.
                    local flyY = (i < descentStartIdx) and riseTargetY or finalY
                    local anchor = Instance.new("Part")
                    anchor.Size = Vector3.new(0.2, 0.2, 0.2)
                    anchor.Anchored = true; anchor.CanCollide = false
                    anchor.CanQuery = false; anchor.CanTouch = false; anchor.CastShadow = false
                    anchor.Transparency = 1
                    anchor.Position = Vector3.new(wpPos.X, flyY, wpPos.Z)
                    anchor.Parent = pathFolder
                    local att = Instance.new("Attachment", anchor)
                    if prevAtt then
                        local beam = Instance.new("Beam")
                        beam.Attachment0 = prevAtt
                        beam.Attachment1 = att
                        beam.Width0 = 1.2; beam.Width1 = 1.2
                        beam.FaceCamera = true
                        beam.LightEmission = 1
                        beam.LightInfluence = 0
                        beam.Transparency = NumberSequence.new(0)
                        beam.Color = ColorSequence.new(Color3.fromRGB(0, 120, 255))
                        beam.Parent = anchor
                    end
                    prevAtt = att
                end
                task.spawn(function()
                    task.wait(10)
                    if _G._tpPathViz == pathFolder then _G._tpPathViz = nil end
                    pcall(function() pathFolder:Destroy() end)
                end)
            end

            -- â”€â”€ Follow the route with velocity at its own altitude (route Y + hover).
            -- A forward obstacle probe looks AHEAD along the travel direction: if something
            -- solid is in the way it slows us down and lifts us just enough to clear its top
            -- BEFORE we reach it, then we settle back onto the route. Slowing down instead of
            -- ramming the wall at full speed is what keeps this from tripping the anti-cheat
            -- reset. â”€â”€
            local wpIndex = 1
            local _lastFlightPos = nil  -- track previous frame's position to detect rubber-bands
            local velMul  = 1  -- start at FULL horizontal speed (no ramp-in). Old value
                               -- of 0 + per-frame ramp of 0.15 meant ~7 frames (~120ms) of
                               -- near-zero horizontal velocity right after the rise -> the
                               -- "stands in air for a couple hundred milliseconds" the
                               -- user reported.
            local velDone = false
            -- Once we drop into the near-base descent, LATCH it: never climb back to the Y17
            -- cruise again. Without this latch a late waypoint advance could momentarily make
            -- the remaining route distance jump back above NEAR_END_DIST, popping us back up to
            -- Y17 right when we were about to settle in to clone. The latch keeps the descent
            -- monotonic so the approach is smooth all the way down.
            local descending = false
            -- Lock the facing ONCE here instead of rewriting CFrame every Heartbeat.
            -- Per-frame CFrame writes re-assert an authoritative position 60x/sec, which
            -- fights the velocity that's actually moving us and replicates as a stream of
            -- "teleports" the anti-cheat lags back. Disabling AutoRotate holds this single
            -- rotation set; velocity alone drives position (clean, server-accepted movement).
            local _, lockHrp, lockHum = getChar()
            local prevAutoRotate = nil
            if lockHum then prevAutoRotate = lockHum.AutoRotate; lockHum.AutoRotate = false end
            if lockHrp then lockHrp.CFrame = CFrame.new(lockHrp.Position) * _faceRot end

            -- â”€â”€ Pre-rise wall-nudge: detect walls within WALL_BUFFER and accumulate an
            -- AWAY vector. If the player spawned flush against a base wall, the vertical
            -- rise itself is fine, but the horizontal flight loop that starts immediately
            -- after can scrape the wall (or the wall extends above Y17 and the cruise hits
            -- it). Drifting AWAY from detected walls DURING the vertical rise clears the
            -- player before horizontal flight begins - no separate delay, no CFrame writes,
            -- just a small horizontal component on the rise velocity. Opposing walls cancel
            -- out (corridors leave us straight up).
            local _wallAway = Vector3.zero
            do
                local _, prHrp = getChar()
                if prHrp then
                    local _rp = RaycastParams.new()
                    _rp.FilterType = Enum.RaycastFilterType.Exclude
                    local _ig = { c }
                    for _, ch in ipairs(Workspace:GetChildren()) do
                        if ch.Name == "XiTempPlatform" or ch.Name == "XiTPPath" then
                            table.insert(_ig, ch)
                        end
                    end
                    _rp.FilterDescendantsInstances = _ig
                    local WALL_BUFFER = 6
                    local _dirs = {
                        Vector3.new(1,0,0),  Vector3.new(-1,0,0),
                        Vector3.new(0,0,1),  Vector3.new(0,0,-1),
                        Vector3.new(0.707,0,0.707),  Vector3.new(0.707,0,-0.707),
                        Vector3.new(-0.707,0,0.707), Vector3.new(-0.707,0,-0.707),
                    }
                    for _, d in ipairs(_dirs) do
                        if Workspace:Raycast(prHrp.Position, d * WALL_BUFFER, _rp) then
                            _wallAway = _wallAway - d
                        end
                    end
                    if _wallAway.Magnitude > 0.01 then _wallAway = _wallAway.Unit end
                end
            end

            -- PHASE 1: Pure vertical rise to the cruise altitude BEFORE any horizontal
            -- motion. Every floor uses this - floor 1 lifts from ground level (~Y0) up to
            -- Y17, floor 2/3 lifts from ~Y7 up to ~Y19 (the 2nd-floor walkable surface +
            -- hover). Then the main flight loop holds that altitude steady all the way to
            -- the base so we don't ascend WHILE going forward - we go up, cross, descend.
            -- For 3rd-floor brainrots: the pathfinder already picks a 2nd-floor clone slot
            -- (the platform extends up to the brainrot), so this single rise + cruise covers
            -- the "go to 2nd floor then up to platform" path implicitly.
            do
                local _, rHrp = getChar()
                if rHrp and alive() and rHrp.Position.Y < riseTargetY - 0.5 then
                    local riseDone = false
                    local riseConn
                    local WALL_PUSH_SPEED = 14  -- gentle horizontal drift away from walls during the rise
                    riseConn = RunService.Heartbeat:Connect(LPH_NO_VIRTUALIZE(function()
                        if not alive() then riseConn:Disconnect(); riseDone = true; return end
                        local _, vHrp = getChar()
                        if not vHrp then riseConn:Disconnect(); riseDone = true; return end
                        if vHrp.Position.Y >= riseTargetY - 0.5 then
                            riseConn:Disconnect(); riseDone = true; return
                        end
                        -- P-gain 20 so RiseSpeed cap is reachable; brakes within ~12 studs.
                        local riseSpeedCap = Config.TpSettings.RiseSpeed or 95
                        local yVel = math.clamp((riseTargetY - vHrp.Position.Y) * 20, 14, riseSpeedCap)
                        vHrp.AssemblyAngularVelocity = Vector3.zero
                        vHrp.AssemblyLinearVelocity  = Vector3.new(
                            _wallAway.X * WALL_PUSH_SPEED, yVel, _wallAway.Z * WALL_PUSH_SPEED)
                    end))
                    local riseStart = tick()
                    repeat RunService.Heartbeat:Wait()
                    until riseDone or tick()-riseStart > 1.5 or not alive()
                    riseConn:Disconnect()
                end
            end

            local vlConn
            -- Per-frame flight loop: runs every Heartbeat for the duration of a teleport
            -- (~5s) doing waypoint advance + Y-axis P-control + velocity write. Native
            -- callback so a TP doesn't pay VM cost ~300 frames in a row.
            vlConn = RunService.Heartbeat:Connect(LPH_NO_VIRTUALIZE(function(dt)
                if not alive() then vlConn:Disconnect(); velDone = true; return end
                local _, vHrp = getChar()
                if not vHrp then vlConn:Disconnect(); velDone = true; return end

                -- Rubber-band recovery: jump >20 studs in a frame = server moved us; snap wpIndex to nearest waypoint.
                if _lastFlightPos then
                    local _jumpDist = (vHrp.Position - _lastFlightPos).Magnitude
                    if _jumpDist > 20 then
                        local _curXZ = Vector2.new(vHrp.Position.X, vHrp.Position.Z)
                        local _bestIdx, _bestDist = wpIndex, math.huge
                        for i = 1, n do
                            local _wpv = waypoints[i]
                            local _d = (_curXZ - Vector2.new(_wpv.X, _wpv.Z)).Magnitude
                            if _d < _bestDist then _bestDist = _d; _bestIdx = i end
                        end
                        wpIndex = _bestIdx
                    end
                end
                _lastFlightPos = vHrp.Position

                -- advance through reached waypoints (XZ)
                local wp = waypoints[wpIndex] or targetBasePos
                local toWp = Vector2.new(vHrp.Position.X - wp.X, vHrp.Position.Z - wp.Z).Magnitude
                while toWp <= 6 and wpIndex < n do
                    wpIndex = wpIndex + 1
                    wp = waypoints[wpIndex]
                    toWp = Vector2.new(vHrp.Position.X - wp.X, vHrp.Position.Z - wp.Z).Magnitude
                end
                local remaining = remainingFrom(vHrp.Position.X, vHrp.Position.Z, wpIndex)
                if remaining <= ARRIVE_DIST then
                    vlConn:Disconnect(); velDone = true; return
                end
                local dir = Vector3.new(wp.X - vHrp.Position.X, 0, wp.Z - vHrp.Position.Z)
                if dir.Magnitude > 0 then dir = dir.Unit end

                -- FLAT altitude policy: cruise at riseTargetY, descend straight to finalY
                -- once we hit the earliest safe-descent waypoint OR the NEAR_END_DIST fallback.
                -- No route-altitude tracking - that caused descend/ascend oscillation when
                -- the pathfinder route had any intermediate waypoint higher than cruise (the
                -- math.max would lift us, then drop us again as we passed). One-way descent
                -- latch keeps the final glide monotonic.
                if remaining <= NEAR_END_DIST or wpIndex >= descentStartIdx then descending = true end
                local targetY = descending and finalY or riseTargetY
                local yVel = math.clamp((targetY - vHrp.Position.Y) * 4, -55, 90)

                -- Facing was locked once before the loop (AutoRotate off); just keep angular
                -- velocity zeroed so physics can't spin us. NO per-frame CFrame write - that
                -- was the lagback cause. Velocity alone moves us.
                vHrp.AssemblyAngularVelocity = Vector3.zero

                -- Facing recovery: re-assert rotation only when drifted past dot < 0.95 (post-rubber-band fix).
                local _curLook = vHrp.CFrame.LookVector
                local _intLook = _faceCF.LookVector
                if _curLook:Dot(_intLook) < 0.95 then
                    vHrp.CFrame = CFrame.new(vHrp.Position) * _faceRot
                end

                -- full, constant XZ speed (after a brief ramp-in) so the route is followed
                -- smoothly instead of crawling/jerking when something is detected.
                velMul = math.min(1, velMul + 0.15)
                local spd = VL_SPEED * velMul
                vHrp.AssemblyLinearVelocity = Vector3.new(dir.X * spd, yVel, dir.Z * spd)
            end))
            local vlStart = tick()
            repeat RunService.Heartbeat:Wait()
            until velDone or tick()-vlStart > 14 or not alive()
            vlConn:Disconnect()
            -- Restore Humanoid auto-rotate now that the velocity flight is done.
            if lockHum and lockHum.Parent then lockHum.AutoRotate = prevAutoRotate end
            -- ONE-SHOT velocity zero. Previously we ran an 8-frame "ramp-down" loop
            -- writing velocity every Heartbeat, which the server reads as suspicious
            -- per-frame motion and can rubber-band. The final-approach tween below
            -- writes CFrame directly anyway, which dominates whatever residual
            -- velocity is left - so the ramp-down was pure noise. Single zero +
            -- GettingUp state change is enough to hand off cleanly to the tween.
            c, hrp = getChar()
            if hrp and alive() then
                hrp.AssemblyLinearVelocity  = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
                pcall(function()
                    local _, _, vHum = getChar()
                    if vHum then vHum:ChangeState(Enum.HumanoidStateType.GettingUp) end
                end)
            end
        end
    end
    if not alive() then isTpMoving=false; return end

    local miniPos        -- set in each branch right before instantClone
    local _intendedCF    -- intended landing CFrame; survives bounce-back so the
                         -- pre-equip anchor can lock the INTENDED spot, not the
                         -- bounced one.

    do
        -- Final approach into the base. The pathfinder can leave us on/near the sign
        -- (best route in), so instead of a slow velocity drift we TWEEN the short gap to
        -- the clone-in spot while FACING THE BASE INTERIOR. The MOMENT the tween finishes
        -- we go straight into instantClone(): equip Quantum Cloner, activate (drops the
        -- clone), then fire the TeleportToClone button - NO floor-wait, walkForward, or
        -- settle hold. We clone the instant we land.
        c, hrp = getChar()
        if hrp and alive() then
            -- 1st floor lands 1 stud higher so we don't sit slightly sunk into the base floor.
            -- NO PUSH past the sign - land exactly at targetBasePos so the Quantum Cloner
            -- activates with the player OUTSIDE the base. The clone walks/TPs in via the
            -- game mechanic; pushing us deeper before Activate just trips the anti-cheat.
            local _finalCF = (not isSecondFloor) and (_faceCF + Vector3.new(0, 1, 0)) or _faceCF
            _intendedCF = _finalCF
            equipCarpet()
            c, hrp = getChar()
            if hrp and alive() then
                hrp.AssemblyLinearVelocity  = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
                local _gd = (hrp.Position - targetBasePos).Magnitude
                local _gt = math.clamp(_gd / (Config.TpSettings.BrainrotSpeed or 60), 0.05, 0.6)
                local _gTween = TweenService:Create(hrp,
                    TweenInfo.new(_gt, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                    {CFrame = _finalCF})
                _gTween:Play()
                _gTween.Completed:Wait()
                hrp.AssemblyLinearVelocity  = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
            end
        end
        if not alive() then isTpMoving=false; return end
        c, hrp = getChar()
        -- Use the INTENDED landing as miniPos, not the actual HRP position. The
        -- laser-bounce can knock us short of where the tween aimed, and using the
        -- bounced position as miniPos means the clone gets placed (and the "settled
        -- at miniPos" gate verifies against) the wrong spot.
        miniPos = _intendedCF and _intendedCF.Position or (hrp and hrp.Position or Vector3.zero)
    end

    if not alive() then isTpMoving=false; return end
    -- Single-shot safety: tween should have landed us at targetBasePos; if for some reason
    -- it didn't (anti-cheat lagback, race), abort instead of cloning from the wrong spot.
    -- NO hold/settle - the user wants the clone fired the instant we arrive.
    do
        c, hrp = getChar()
        if not hrp then isTpMoving=false; return end
        local flatPos = Vector3.new(hrp.Position.X, 0, hrp.Position.Z)
        local flatTarget = Vector3.new(targetBasePos.X, 0, targetBasePos.Z)
        if (flatPos - flatTarget).Magnitude > 5 then
            isTpMoving = false; return
        end
    end

    -- Pre-equip cloner so carpet body-movers don't jitter the upcoming approach.
    do
        local _pC, _, _pHum = getChar()
        if _pHum and _pC then
            local _cloner = LocalPlayer.Backpack:FindFirstChild("Quantum Cloner")
                         or _pC:FindFirstChild("Quantum Cloner")
            if _cloner and _cloner.Parent ~= _pC then
                pcall(function() _pHum:EquipTool(_cloner) end)
                local _eqT = tick()
                while tick() - _eqT < 0.2 do
                    if _cloner.Parent == _pC then break end
                    RunService.Heartbeat:Wait()
                end
            end
        end
    end

    -- F1: stay at landing. F2: raycast forward to wall, velocity-move to ~1 stud shy.
    if isSecondFloor then
        local _wC, _wHrp = getChar()
        if _wHrp and _wHrp.Parent then
            _wHrp.AssemblyLinearVelocity  = Vector3.zero
            _wHrp.AssemblyAngularVelocity = Vector3.zero

            local _origin  = _wHrp.Position
            local _forward = _wHrp.CFrame.LookVector
            local _rp = RaycastParams.new()
            _rp.FilterType = Enum.RaycastFilterType.Exclude
            local _ignore = { _wC }
            for _, ch in ipairs(Workspace:GetChildren()) do
                if ch.Name == "XiTempPlatform" or ch.Name == "XiTPPath" then
                    table.insert(_ignore, ch)
                end
            end
            local _cloneInst = Workspace:FindFirstChild(tostring(LocalPlayer.UserId) .. "_Clone")
            if _cloneInst then table.insert(_ignore, _cloneInst) end
            _rp.FilterDescendantsInstances = _ignore

            local _hit = Workspace:Raycast(_origin, _forward * 30, _rp)
            if _hit then
                -- Stop just shy of the wall (1 stud back) so we sit against
                -- the wall without clipping into it.
                local _stopOffset = 1
                local _targetPos = _hit.Position - _forward * _stopOffset
                local _speed = Config.TpSettings.BrainrotSpeed or 60
                local _maxTime = (_hit.Distance / _speed) + 0.3
                local _start = tick()
                while tick() - _start < _maxTime do
                    if not _wHrp.Parent then break end
                    local _to = _targetPos - _wHrp.Position
                    if _to.Magnitude < 0.5 then break end
                    _wHrp.AssemblyLinearVelocity  = _to.Unit * _speed
                    _wHrp.AssemblyAngularVelocity = Vector3.zero
                    RunService.Heartbeat:Wait()
                end
                _wHrp.AssemblyLinearVelocity  = Vector3.zero
                _wHrp.AssemblyAngularVelocity = Vector3.zero
            end
        end
    end

    -- User-configurable settle time at the landed position BEFORE firing
    -- Activate. Gives the server time to fully reconcile our walk-in position
    -- so the clone gets placed exactly where we ended up. Tunable via TP
    -- settings -> "Clone Settle Time" (default 0.4s, range 0â€“2s).
    local _cloneSettle = Config.TpSettings.CloneSettleTime or 0.4
    if _cloneSettle > 0 then task.wait(_cloneSettle) end

    -- Defensive: clear stuck isCloning flag so the call always fires.
    _G.isCloning = false
    instantClone()
    local cloningTimeout = 0
    while _G.isCloning and cloningTimeout < 5 do
        task.wait(0.1)
        cloningTimeout = cloningTimeout + 0.1
    end
    if not alive() then isTpMoving=false; return end

    -- Wait for the CLONE INSTANCE to actually appear in Workspace before
    -- proceeding. Without this, the brainrot tween below could start before
    -- the clone was placed AND before the in-game TP processed.
    local _cloneInstName = tostring(LocalPlayer.UserId) .. "_Clone"
    local _cloneAppearStart = tick()
    local _cloneInst = nil
    while tick() - _cloneAppearStart < 2 do
        _cloneInst = Workspace:FindFirstChild(_cloneInstName)
        if _cloneInst then break end
        task.wait(0.05)
    end
    if not _cloneInst then
        isTpMoving = false
        ShowNotification("CLONE TP", "Clone never appeared - press TP key to retry")
        return
    end

    -- Phase 1: detect TP via clone-move / player-move / 0.8s floor.
    -- Phase 2: verify player XZ within 10 studs of clone spawn position.
    local _cloneSpawnPos
    do
        local _hrp0 = _cloneInst:FindFirstChild("HumanoidRootPart")
                   or _cloneInst:FindFirstChildWhichIsA("BasePart", true)
        if _hrp0 then _cloneSpawnPos = _hrp0.Position end
    end
    local _initPlayerPos = hrp and hrp.Position or Vector3.zero
    if _cloneSpawnPos then
        -- Phase 1: detect TP firing
        local _waitStart = tick()
        local _detected = false
        local MIN_WAIT = 0.8  -- floor wait for server processing
        local MAX_WAIT = 3
        while tick() - _waitStart < MAX_WAIT do
            local _elapsed = tick() - _waitStart
            -- Signal A: clone moved
            local _liveHrp = _cloneInst:FindFirstChild("HumanoidRootPart")
                          or _cloneInst:FindFirstChildWhichIsA("BasePart", true)
            if _liveHrp and (_liveHrp.Position - _cloneSpawnPos).Magnitude > 1 then
                _detected = true; break
            end
            -- Signal B: player moved
            c, hrp = getChar()
            if hrp and (hrp.Position - _initPlayerPos).Magnitude > 3 then
                _detected = true; break
            end
            -- Signal C: minimum time elapsed
            if _elapsed >= MIN_WAIT then
                _detected = true; break
            end
            RunService.Heartbeat:Wait()
        end
        if not _detected then
            isTpMoving = false
            ShowNotification("CLONE TP", "TP didn't process - press TP key to retry")
            return
        end

        -- Phase 2: HARD VERIFY player ended up at clone's spawn position. This
        -- is the actual proof we got moved to where the clone was. XZ flat
        -- distance, 10-stud radius to cover character + carpet footprint.
        c, hrp = getChar()
        if hrp then
            local _pXZ = Vector2.new(hrp.Position.X, hrp.Position.Z)
            local _cXZ = Vector2.new(_cloneSpawnPos.X, _cloneSpawnPos.Z)
            if (_pXZ - _cXZ).Magnitude > 10 then
                isTpMoving = false
                ShowNotification("CLONE TP", "Not at clone position - press TP key to retry")
                return
            end
        else
            isTpMoving = false
            return
        end
    end

    -- NO post-detection settle wait. The clone-moved signal IS proof the
    -- TP fired, so we go straight to the brainrot tween. (Old code had a
    -- CloneSettleTime wait here as insurance because the previous detection
    -- methods were unreliable - that's no longer needed.)
    if not alive() then isTpMoving=false; return end
    c, hrp = getChar()
    if not hrp then isTpMoving=false; return end
    equipCarpet()
    if not alive() then isTpMoving=false; return end

    local verticalDiff = exactPos.Y - (hrp and hrp.Position.Y or 0)

    -- Dynamic snap Y based on actual brainrot height (no hardcoded floor values)
    local isThirdFloor = exactPos.Y > 22
    local snapY
    if isThirdFloor then
        snapY = exactPos.Y - 8
    else
        snapY = exactPos.Y + 2.5
    end
    local snapPos = Vector3.new(exactPos.X, snapY, exactPos.Z)

    -- High brainrot needs a temp platform to stand on
    if verticalDiff > 2 then
        local plat = Instance.new("Part")
        plat.Name="XiTempPlatform"; plat.Size=Vector3.new(3,1,3)
        plat.Position = snapPos - Vector3.new(0, 5, 0)
        plat.Color=Color3.new(1,0,0)
        plat.Material=Enum.Material.Neon; plat.Anchored=true; plat.CanCollide=true
        plat.Transparency=0.3; plat.Parent=Workspace
        task.spawn(function() task.wait(25); pcall(function() plat:Destroy() end) end)
        RunService.Heartbeat:Wait()
    end

    -- One-shot tween to the brainrot (unchanged from before).
    c, hrp = getChar()
    if hrp and alive() then
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        local _pd = (hrp.Position - snapPos).Magnitude
        local _pt = math.clamp(_pd / (Config.TpSettings.BrainrotSpeed or 60), 0.05, 0.6)
        local _tw = TweenService:Create(hrp,
            TweenInfo.new(_pt, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            {CFrame = CFrame.new(snapPos)})
        _tw:Play()
        _tw.Completed:Wait()
        hrp.AssemblyLinearVelocity = Vector3.zero
    end

    -- The tween already moved us onto the brainrot snap position - that's
    -- enough. Don't abort on the Stealing attribute being false here: the
    -- prompt may register a moment later, the InstantSteal system handles
    -- triggering it, or the user might need to press the steal key. Aborting
    -- silently was hiding success - visible symptom: "tween moved me but
    -- nothing happened afterward". Just signal arrived and let the steal
    -- pipeline outside take over.
    if SharedState.MarkBrainrotArrived then SharedState.MarkBrainrotArrived() end

    _wasStealingHit = false
    isTpMoving = false

    else
    -- -- SIDE TP -----------------------------------------------------------
    
    local exactPos2 = part.Position
    local targetPodium, targetPosition = getTargetPodiumAndSafePosition(targetPetData, exactPos2)
    local claimPart = findClaimModel(targetPodium)
    local dirBehind
    if claimPart then
        local df = claimPart.Position - targetPosition
        if df.Magnitude > 0 then
            dirBehind = -Vector3.new(df.X, 0, df.Z).Unit
        end
    end
    if not dirBehind then
        local baseIdx = closestIdx(exactPos2)
        dirBehind = baseIdx <= 4 and Vector3.new(-1, 0, 0) or Vector3.new(1, 0, 0)
    end
    local behindPos = targetPosition + (dirBehind * 7)
    local rpPre = RaycastParams.new()
    rpPre.FilterDescendantsInstances = {c}
    rpPre.FilterType = Enum.RaycastFilterType.Exclude
    local resPre = Workspace:Raycast(Vector3.new(behindPos.X, exactPos2.Y + 10, behindPos.Z), Vector3.new(0, -1000, 0), rpPre)
    if not resPre then isTpMoving=false; return end
    -- Use the raycast's actual floor Y instead of targetPosition.Y + 2.
    -- During cyber event the floor may be at a different height ??? the raycast
    -- already found the real ground, so use it.  +1 to stay just above it.
    local finalPos = Vector3.new(behindPos.X, targetPosition.Y + 2, behindPos.Z)
    local lookTarget = claimPart
        and Vector3.new(claimPart.Position.X, finalPos.Y, claimPart.Position.Z)
        or targetPosition
    local finalFacing = CFrame.lookAt(finalPos, lookTarget)
    local facingRot = finalFacing - finalFacing.Position

    -- Wall anchor ??? same pattern Haze and the 7k hub use for ALL TP modes.
    -- CFrame to the safe external wall (-409, 23) so the server confirms the
    -- character at a valid location before any carpet rise or base warp.
    -- Without this the server rejects the finalPos CFrame during cyber event
    -- (geometry changes) and rubber-bands the character to spawn.
    -- It also stops the character from flying into altered base walls at 330
    -- velocity while still at floor level, which causes instant death.
    hrp.CFrame = CFrame.new(hrp.Position) * facingRot
    if hrp.Position.Y > 25 and targetPosition.Y > 25 then
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        local _sA = hrp.Position
        local _dA = (_sA - finalPos).Magnitude
        local _stA = math.max(1, math.ceil(_dA / 7))
        for _si = 1, _stA do
            if not alive() then isTpMoving=false; return end
            c, hrp = getChar(); if not hrp then break end
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
            hrp.CFrame = CFrame.new(_sA:Lerp(finalPos, _si / _stA)) * facingRot
            hrp.AssemblyLinearVelocity = Vector3.zero
            if _si < _stA then task.wait(0.05) end
        end
        hrp.AssemblyAngularVelocity = Vector3.zero
    else
        if not alive() then isTpMoving=false; return end
        local carpet2 = LocalPlayer.Backpack:FindFirstChild(Config.TpSettings.Tool) or c:FindFirstChild(Config.TpSettings.Tool)
        if carpet2 and hum and hum.Parent then hum:EquipTool(carpet2); task.wait(0.01) end
        if not alive() then isTpMoving=false; return end
        hrp.CFrame = CFrame.new(hrp.Position) * facingRot
        local v2 = hrp.AssemblyLinearVelocity
        hrp.AssemblyLinearVelocity = Vector3.new(v2.X, 330, v2.Z)
        task.wait(0.08)
        if not alive() then isTpMoving=false; return end
        local positionBehindPet = targetPosition + (dirBehind * 18)
        local carpetPart = findFlyingCarpet()
        -- carpetPart may be nil during events where Workspace.Map.Carpet doesn't
        -- exist (e.g. cyber event).  Previously this returned early here, leaving
        -- the 330 Y velocity set above with no cleanup ??? character floats up
        -- indefinitely.  Fix: skip the intermediate warp step when no carpet
        -- exists; still zero velocity and snap directly to finalPos.
        if hum and hum.Parent then
            local state = hum:GetState()
            if state ~= Enum.HumanoidStateType.Jumping and state ~= Enum.HumanoidStateType.Freefall then
                hum:ChangeState(Enum.HumanoidStateType.Jumping); task.wait(0.04)
            end
        end
        if not alive() then isTpMoving=false; return end
        if carpetPart then
            local carpetPos = carpetPart.Position
            local _sC = hrp.Position
            local _destC = Vector3.new(carpetPos.X, hrp.Position.Y, positionBehindPet.Z)
            local _dC = (_sC - _destC).Magnitude
            local _stC = math.max(1, math.ceil(_dC / 7))
            for _si = 1, _stC do
                if not alive() then isTpMoving=false; return end
                c, hrp = getChar(); if not hrp then break end
                hrp.AssemblyLinearVelocity = Vector3.zero
                hrp.CFrame = CFrame.new(_sC:Lerp(_destC, _si / _stC)) * facingRot
                hrp.AssemblyLinearVelocity = Vector3.zero
                if _si < _stC then task.wait(0.05) end
            end
            task.wait(0.08)
            if not alive() then isTpMoving=false; return end
        else
            -- No carpet (event map): server needs an intermediate confirmed position
            -- at the target XZ before accepting the finalPos snap, otherwise it
            -- rubber-bands from -409 back to spawn. One extra step, same timing.
            c, hrp = getChar(); if not hrp then isTpMoving=false; return end
            hrp.CFrame = CFrame.new(Vector3.new(finalPos.X, hrp.Position.Y, finalPos.Z)) * facingRot
            task.wait(0.05)
            if not alive() then isTpMoving=false; return end
        end
        c, hrp = getChar(); if not hrp then isTpMoving=false; return end
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        local _sB = hrp.Position
        local _dB = (_sB - finalPos).Magnitude
        local _stB = math.max(1, math.ceil(_dB / 7))
        for _si = 1, _stB do
            if not alive() then isTpMoving=false; return end
            c, hrp = getChar(); if not hrp then break end
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
            hrp.CFrame = CFrame.new(_sB:Lerp(finalPos, _si / _stB)) * facingRot
            hrp.AssemblyLinearVelocity = Vector3.zero
            if _si < _stB then task.wait(0.05) end
        end
        hrp.AssemblyAngularVelocity = Vector3.zero
    end
    task.wait(0.01); task.wait(0.16)
    c, hrp = getChar()
local miniPos = hrp and hrp.Position or Vector3.zero
instantClone()
local cloneWait = tick()
repeat
    RunService.Heartbeat:Wait()
    c, hrp = getChar()
until (hrp and (hrp.Position - miniPos).Magnitude >= 0.35) or tick()-cloneWait > 4 or not alive()
while _G.isCloning do task.wait() end
task.wait(0.15)
    if not alive() then isTpMoving=false; return end
    c, hrp, hum = getChar()
    local preClonePos2 = hrp and hrp.Position or Vector3.zero
    local cloneWait2 = tick()
    repeat task.wait(0.05); c, hrp = getChar()
    until (hrp and (hrp.Position - preClonePos2).Magnitude > 1.5) or tick()-cloneWait2 > 0.75 or not alive()
    if not alive() then isTpMoving=false; return end
    task.wait(0.05)
    equipCarpet()
    if not alive() then isTpMoving=false; return end
    c, hrp = getChar()
    local snapPart = findAdorneeGlobal(targetPetData)
    if not snapPart then isTpMoving=false; return end
    local snapExactPos = snapPart.Position
    local sVertDiff = snapExactPos.Y - (hrp and hrp.Position.Y or 0)
    local snapPos2
    if sVertDiff > 2 then
        snapPos2 = Vector3.new(snapExactPos.X, snapExactPos.Y - 8, snapExactPos.Z)
        local plat2 = Instance.new("Part")
        plat2.Name="XiTempPlatform"; plat2.Size=Vector3.new(3,1,3)
        plat2.Position=snapPos2-Vector3.new(0,5,0); plat2.Color=Color3.new(1,0,0)
        plat2.Material=Enum.Material.Neon; plat2.Anchored=true; plat2.CanCollide=true
        plat2.Transparency=0.3; plat2.Parent=Workspace
        RunService.Heartbeat:Wait()
        c, hrp = getChar()
        if hrp and alive() then
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
            hrp.CFrame = CFrame.new(snapPos2)
            hrp.AssemblyLinearVelocity = Vector3.zero
        end
        task.spawn(function() task.wait(25); pcall(function() plat2:Destroy() end) end)
    else
        snapPos2 = snapExactPos
        c, hrp = getChar()
        if hrp and alive() then
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
            hrp.CFrame = CFrame.new(snapPos2)
            hrp.AssemblyLinearVelocity = Vector3.zero
        end
    end
    if SharedState.MarkBrainrotArrived then SharedState.MarkBrainrotArrived() end
    _atBrainrot = true
    task.delay(5, function() _atBrainrot = false end)
    isTpMoving = false
    end -- end tpMode if/else
end

_G.tpToBestBrainrot = runAutoSnipe

-- â”€â”€ Background pre-computer: as soon as the server animal cache is populated, keep a
-- fresh PathfindingService route ready for the CURRENT best front-target from our current
-- spot. When the player presses TP, runAutoSnipe reuses this cached route instantly
-- instead of computing on the spot - optimizing for the fastest possible snipe. â”€â”€
task.spawn(function()
    while true do
        task.wait(0.2)   -- keep the cached route fresh so a TP press fires instantly
        if isTpMoving then continue end
        if tpMode ~= "front" then continue end
        if not SharedState.AllAnimalsCache or #SharedState.AllAnimalsCache == 0 then continue end
        local _, hrp = getChar()
        if not hrp then continue end

        -- same target pick as runAutoSnipe (base brainrots, priority/highest)
        local target = manualTarget
        if not target then
            local bestRank, bestGen = math.huge, -math.huge
            for _, a in ipairs(SharedState.AllAnimalsCache) do
                if a and a.owner ~= LocalPlayer.Name and not isOwnerInDuel(a.owner) then
                    if Config.AutoTPPriority ~= false then
                        local rank = math.huge
                        local aLow = a.name and a.name:lower()
                        for i, pName in ipairs(PRIORITY_LIST) do
                            if pName:lower() == aLow then rank = i; break end
                        end
                        if rank < bestRank or (rank == bestRank and a.genValue > bestGen) then
                            bestRank = rank; bestGen = a.genValue; target = a
                        end
                    elseif a.genValue > bestGen then
                        bestGen = a.genValue; target = a
                    end
                end
            end
        end
        if not target or target.isWalking then continue end

        local part = findAdorneeGlobal(target)
        if not part then continue end

        local ok, tbp, wps, used, sp = pcall(computeFrontRoute, part, hrp.Position)
        if ok and tbp then
            _frontRouteCache = {
                uid = target.uid,
                startFlat = Vector2.new(hrp.Position.X, hrp.Position.Z),
                targetBasePos = tbp,
                waypoints = wps,
                usedPathfinding = used,
                signPart = sp,
                at = tick(),
            }
        end
    end
end)

-- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
--  CLONE TP ENGINE  â€“  DISABLED (was interfering with Quantum Cloner)
-- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
-- This entire engine (~650 lines below) ran multiple Heartbeat connections,
-- manipulated SimulationRadius + PhysicsRepRootPart (network ownership),
-- tracked the clone model, and ran auto-spam loops on it. Any of those
-- would happily grab the clone the Quantum Cloner just placed and move it
-- around, which is why "the clone is never where it's supposed to be".
--
-- We provide a no-op stub for _G.ctpLaunch so any caller (TpMethod=clone
-- path, fallback paths) just no-ops cleanly instead of erroring.
_G._ctpRunning = false
_G.ctpLaunch = function() end


-- --- Hit recovery - re-snap to brainrot if knocked while inside base ---------
-- Uses LocalPlayer:GetAttributeChangedSignal("Stealing") from the big source.
-- Only fires when Stealing goes true->false while still inside the base walls.
-- Uses the same carpet equip + AssemblyLinearVelocity snap as runAutoSnipe for
-- smooth movement instead of a hard CFrame jump.
local BASE_BOXES = {
    [1]={-458.19,-388.58, 179.82,266.98},
    [2]={-458.19,-388.58,  71.82,158.98},
    [3]={-458.19,-388.58, -34.18, 52.98},
    [4]={-458.19,-388.58,-139.18,-52.02},
    [5]={-353.19,-283.58, 177.82,264.98},
    [6]={-353.19,-283.58,  73.82,160.98},
    [7]={-353.19,-283.58, -34.18, 52.98},
    [8]={-353.19,-283.58,-139.18,-52.02},
}
local function isInsideBaseIdx(pos, idx)
    local b = BASE_BOXES[idx]; if not b then return false end
    return pos.X>b[1] and pos.X<b[2] and pos.Z>b[3] and pos.Z<b[4] and pos.Y>-10 and pos.Y<55
end
local function isInsideBase(pos)
    for _,b in pairs(BASE_BOXES) do
        if pos.X>b[1] and pos.X<b[2] and pos.Z>b[3] and pos.Z<b[4] and pos.Y>-10 and pos.Y<55 then return true end
    end
    return false
end

local _wasStealingHit = false
LocalPlayer:GetAttributeChangedSignal("Stealing"):Connect(function()
    local stealing = LocalPlayer:GetAttribute("Stealing")

      if stealing then
        local _, hrp2 = getChar()
        if hrp2 then
            local tgt2 = manualTarget
            if not tgt2 then
                for _, a in ipairs(SharedState.AllAnimalsCache) do
                    if a and a.owner ~= LocalPlayer.Name then tgt2 = a; break end
                end
            end
            local part2 = tgt2 and findAdorneeGlobal(tgt2)
            if part2 then
                local playerBaseIdx = closestIdx(hrp2.Position)
                local brainrotBaseIdx = closestIdx(part2.Position)
                _wasStealingHit = (playerBaseIdx == brainrotBaseIdx)
            else
                _wasStealingHit = false
            end
        else
            _wasStealingHit = false
        end
        return
    end

    if not _wasStealingHit then return end
    _wasStealingHit = false

    -- toggle off -> skip
    if not Config.HitRecovery then return end
    if isTpMoving then return end

    local c, hrp, hum = getChar()
    if not hrp or not hum or hum.Health <= 0 then return end


    local target = manualTarget
    if not target then
        if Config.AutoTPPriority ~= false then
            for _,pName in ipairs(PRIORITY_LIST) do
                local sn = pName:lower()
                for _,a in ipairs(SharedState.AllAnimalsCache) do
                    if a and a.name and a.name:lower()==sn
                    and a.owner~=LocalPlayer.Name
                    and not isOwnerInDuel(a.owner) then
                        target=a; break
                    end
                end
                if target then break end
            end
            if not target then
                for _,a in ipairs(SharedState.AllAnimalsCache) do
                    if a and a.owner~=LocalPlayer.Name
                    and not isOwnerInDuel(a.owner) then
                        target=a; break
                    end
                end
            end
        end
    end
    if not target then return end

    local part = findAdorneeGlobal(target)
    if not part then return end
    local petPos = part.Position
    local brainrotBaseIdx = closestIdx(petPos)
    if not isInsideBaseIdx(hrp.Position, brainrotBaseIdx) then return end

    task.spawn(function()
        isTpMoving = true
        local snapChar = LocalPlayer.Character
        local function snapAlive()
            return LocalPlayer.Character == snapChar and snapChar ~= nil
        end

        equipCarpet()
        task.wait(0.01)

        -- walking brainrot target: use full smooth anchor, same as runAutoSnipe
        if target.isWalking then
            local LERP_SPEED   = 0.35
            local HOVER_HEIGHT = 3

            local anchorDone    = false
            local lastGoodPos   = nil
            local missedFrames  = 0
            local done          = Instance.new("BindableEvent")

            local conn = RunService.Heartbeat:Connect(function(dt)
                if anchorDone then return end
                if not snapAlive() then anchorDone=true; done:Fire(); return end

                c, hrp = getChar()
                if not hrp then return end

                local currentPart = findAdorneeGlobal(target)
                if not currentPart or not target.model or not target.model.Parent then
                    missedFrames = missedFrames + 1
                    if missedFrames >= 90 then anchorDone=true; done:Fire(); return end
                    if lastGoodPos then
                        hrp.AssemblyLinearVelocity = Vector3.zero
                        hrp.CFrame = hrp.CFrame:Lerp(
                            CFrame.new(lastGoodPos + Vector3.new(0, HOVER_HEIGHT, 0)), LERP_SPEED)
                    end
                    return
                end

                missedFrames = 0
                local brainrotPos = currentPart.Position
                lastGoodPos = brainrotPos

                hrp.AssemblyLinearVelocity = Vector3.zero
                hrp.CFrame = hrp.CFrame:Lerp(
                    CFrame.new(brainrotPos + Vector3.new(0, HOVER_HEIGHT, 0)), LERP_SPEED)

                
            end)

            done.Event:Wait()
            done:Destroy()
            conn:Disconnect()
            isTpMoving = false
            return
        end

        -- base brainrot target: existing snap logic
        local vertDiff = petPos.Y - (hrp and hrp.Position.Y or 0)
        local snapPos
        local plat = nil

        if vertDiff > 2 then
            snapPos = Vector3.new(petPos.X, petPos.Y - 8, petPos.Z)
            plat = Instance.new("Part")
            plat.Name="XiTempPlatform"; plat.Size=Vector3.new(3,1,3)
            plat.Position=snapPos-Vector3.new(0,5,0); plat.Color=Color3.new(1,0,0)
            plat.Material=Enum.Material.Neon; plat.Anchored=true; plat.CanCollide=true
            plat.Transparency=0.3; plat.Parent=Workspace
            RunService.Heartbeat:Wait()
        else
            snapPos = Vector3.new(petPos.X, math.max(petPos.Y,-3), petPos.Z)
        end

        equipCarpet(); task.wait(0.01)

        -- Carpet-equipped TweenService move to the brainrot (no CFrame snaps).
        c, hrp = getChar()
        if hrp and snapAlive() then
            local destPos = snapPos + Vector3.new(0, 2, 0)
            hrp.AssemblyLinearVelocity  = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
            local _hrDist = (hrp.Position - destPos).Magnitude
            local _hrTime = math.clamp(_hrDist / (Config.TpSettings.BrainrotSpeed or 60), 0.05, 0.6)
            local _hrTween = TweenService:Create(hrp,
                TweenInfo.new(_hrTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                {CFrame = CFrame.new(destPos)})
            _hrTween:Play()
            _hrTween.Completed:Wait()
            hrp.AssemblyLinearVelocity = Vector3.zero
        end

        if plat then
            task.spawn(function()
                task.wait(20)
                pcall(function() plat:Destroy() end)
            end)
        end

        isTpMoving = false
    end)
end)

-- ?? Steal engine ?????????????????????????????????????????????????????????????

local isAutoStealing = false   -- true while a steal is being held (drives the live bar)
local StealData      = {}
local PromptCache    = {}
local _stealStart    = 0
local _stealProgress = 0       -- 0 = idle, 0-1 = in progress
-- Old held-steal arrival hook is gone; kept as a no-op stub so the TP engine can still call it.
SharedState.MarkBrainrotArrived = function() end

-- ?? Helpers ??????????????????????????????????????????????????????????????????
local function getChar()
    local c = LocalPlayer.Character
    return c, c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
end

local function isOwnerInDuel(ownerName)
    if not ownerName then return false end
    local p = Players:FindFirstChild(ownerName)
    return p and p:GetAttribute("duelsblocksteal") == true or false
end

local function isMyPlot(plotName)
    local plots = Workspace:FindFirstChild("Plots")
    if not plots then return false end
    local plot = plots:FindFirstChild(plotName)
    if not plot then return false end
    local sign = plot:FindFirstChild("PlotSign")
    if sign then
        local yb = sign:FindFirstChild("YourBase")
        if yb and yb:IsA("BillboardGui") then
            return yb.Enabled == true
        end
    end
    return false
end

-- ?? Prompt finder ????????????????????????????????????????????????????????????
local function findPrompt(a)
    if not a then return nil end
    if a.isWalking then
        if a.prompt and a.prompt.Parent and a.prompt.Enabled then return a.prompt end
        return nil
    end
    local cp = PromptCache[a.uid]
    if cp and cp.Parent then return cp end
    local plots = Workspace:FindFirstChild("Plots"); if not plots then return nil end
    local plot  = plots:FindFirstChild(a.plot);     if not plot  then return nil end
    local pods  = plot:FindFirstChild("AnimalPodiums"); if not pods then return nil end
    local pod   = pods:FindFirstChild(a.slot);      if not pod   then return nil end
    local base  = pod:FindFirstChild("Base");        if not base  then return nil end
    local sp    = base:FindFirstChild("Spawn");      if not sp    then return nil end
    local att   = sp:FindFirstChild("PromptAttachment")
    if att then
        for _, p in ipairs(att:GetChildren()) do
            if p:IsA("ProximityPrompt") and p.Enabled and p.ActionText == "Steal" then
                PromptCache[a.uid] = p; return p
            end
        end
    end
    local startPos = sp.Position
    local best, bd = nil, math.huge
    for _, d in pairs(plot:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Enabled and d.ActionText == "Steal" then
            local part = d.Parent
            local pp
            if part:IsA("BasePart") then pp = part.Position
            elseif part:IsA("Attachment") and part.Parent:IsA("BasePart") then pp = part.Parent.Position end
            if pp then
                local hd = math.sqrt((pp.X-startPos.X)^2 + (pp.Z-startPos.Z)^2)
                if hd < 5 and pp.Y > startPos.Y then
                    local yd = pp.Y - startPos.Y
                    if yd < bd then bd = yd; best = d end
                end
            end
        end
    end
    if best then PromptCache[a.uid] = best end
    return best
end


-- ?? Priority resolver ?????????????????????????????????????????????????????????
local function resolvePriorityTarget()
    if manualTarget then return manualTarget end
    -- Nearest mode: pick the closest base-brainrot to the player
    if stealNearest then
        local _, hrp = getChar()
        if hrp then
            local bestEntry, bestDist = nil, math.huge
            for _, a in ipairs(SharedState.AllAnimalsCache) do
                if a and a.owner ~= LocalPlayer.Name and not isOwnerInDuel(a.owner) then
                    local part = findAdorneeGlobal(a)
                    if part then
                        local d = (hrp.Position - part.Position).Magnitude
                        if d < bestDist then bestDist = d; bestEntry = a end
                    end
                end
            end
            -- walking brainrots excluded (auto buy only) - base brainrots only
            if bestEntry then return bestEntry end
        end
    end
    if (Config.UsePriority ~= false) then
        for _, pName in ipairs(PRIORITY_LIST) do
            local sn = pName:lower()
            for _, a in ipairs(SharedState.AllAnimalsCache) do
                if a and a.name and a.name:lower() == sn
                and a.owner ~= LocalPlayer.Name
                and not isOwnerInDuel(a.owner) then
                    return a
                end
            end
        end
    end
    for _, a in ipairs(SharedState.AllAnimalsCache) do
        if a and a.owner ~= LocalPlayer.Name and not isOwnerInDuel(a.owner) then
            return a
        end
    end
    -- walking brainrots intentionally NOT a steal/TP fallback (auto buy only)
    return nil
end
-- ?? Nearest prompt ???????????????????????????????????????????????????????????
local function findNearestPrompt()
    local _, hrp = getChar()
    if not hrp then return end
    local plots = Workspace:FindFirstChild("Plots")
    if not plots then return end

    local priorityTarget = resolvePriorityTarget()
    if not priorityTarget then return end

    if priorityTarget.isWalking then
        if priorityTarget.prompt and priorityTarget.prompt.Parent and priorityTarget.prompt.Enabled then
            local model = priorityTarget.model
            if model and model.Parent then
                local part = model:FindFirstChildWhichIsA("BasePart")
                if part then
                    local dXZ = Vector2.new(part.Position.X - hrp.Position.X, part.Position.Z - hrp.Position.Z).Magnitude
                    if dXZ <= (Config.StealRadius or 60) then
                        return priorityTarget.prompt
                    end
                end
            end
        end
        return nil
    end

    local nearest, dist = nil, math.huge
    for _, plot in ipairs(plots:GetChildren()) do
        if isMyPlot(plot.Name) then continue end
        if plot.Name ~= priorityTarget.plot then continue end
        local pods = plot:FindFirstChild("AnimalPodiums")
        if not pods then continue end
        local pod = pods:FindFirstChild(priorityTarget.slot)
        if not pod then continue end
        local base = pod:FindFirstChild("Base")
        local spawn = base and base:FindFirstChild("Spawn")
        if spawn then
            local dXZ = Vector2.new(spawn.Position.X - hrp.Position.X, spawn.Position.Z - hrp.Position.Z).Magnitude
            if dXZ <= (Config.StealRadius or 60) and dXZ < dist then
                local att = spawn:FindFirstChild("PromptAttachment")
                if att then
                    for _, p in ipairs(att:GetChildren()) do
                        if p:IsA("ProximityPrompt") and p.ActionText:find("Steal") then
                            nearest, dist = p, dXZ
                        end
                    end
                end
            end
        end
    end
    return nearest
end

-- ?? Heartbeat autosteal loop ?????????????????????????????????????????????????
-- Hold the steal prompt while we close in, then fire the trigger ONLY once we're
-- within a few studs of the animal podium. No radius-based / timed firing - the
-- steal bar must not start (and the steal must not fire) just because we're inside
-- the engagement radius; it fires when we've actually reached the podium.
-- NOTE: this hub now uses RADIUS-ONLY firing (no held steal, no on-podium gating). The
-- comment above describes the old held-steal design and is kept only for history.
-- â”€â”€ Steal firing (verbatim from the working standalone) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Pick the nearest in-radius prompt, fire its OWN PromptButtonHoldBegan + Triggered
-- (+ PromptButtonHoldEnded) connections plus fireproximityprompt, and let the SERVER
-- validate range. There is intentionally NO MaxActivationDistance / on-podium gating -
-- that gating was the "leftover" that stopped the steal from ever firing.
local StealCache = {}
local lastStealT = 0

local function buildCB(prompt)
    if StealCache[prompt] then return end
    local data = {h = {}, t = {}, e = {}}
    local ok1, c1 = pcall(getconnections, prompt.PromptButtonHoldBegan)
    if ok1 and type(c1) == "table" then
        for _, c in ipairs(c1) do if type(c.Function) == "function" then table.insert(data.h, c.Function) end end
    end
    local ok2, c2 = pcall(getconnections, prompt.Triggered)
    if ok2 and type(c2) == "table" then
        for _, c in ipairs(c2) do if type(c.Function) == "function" then table.insert(data.t, c.Function) end end
    end
    local ok3, c3 = pcall(getconnections, prompt.PromptButtonHoldEnded)
    if ok3 and type(c3) == "table" then
        for _, c in ipairs(c3) do if type(c.Function) == "function" then table.insert(data.e, c.Function) end end
    end
    if #data.h > 0 or #data.t > 0 or #data.e > 0 then StealCache[prompt] = data end
end

-- Immediate burst fire (rate-limited) used while closing in on the target.
local function fireSteal(prompt)
    if not prompt then return end
    local now = os.clock()
    if now - lastStealT < 0.04 then return end
    lastStealT = now
    buildCB(prompt)
    local d = StealCache[prompt]; if not d then return end
    local od = prompt.HoldDuration; prompt.HoldDuration = 0
    for _, fn in ipairs(d.h) do pcall(fn) end
    for _ = 1, 6 do
        for _, fn in ipairs(d.t) do pcall(fn) end
        if fireproximityprompt then pcall(fireproximityprompt, prompt) end
    end
    for _, fn in ipairs(d.e) do pcall(fn) end
    prompt.HoldDuration = od
end

-- TP-engine compatibility stub (the steal fires from the Heartbeat below).
SharedState.BeginHeldSteal = function() return false end

-- â”€â”€ Heartbeat autosteal loop (verbatim standalone behavior) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- executeSteal holds the prompt for StealDuration then fires its Triggered connections:
-- this both performs the steal AND drives the live progress bar (it sets isAutoStealing +
-- _stealStart, which the bar reads to fill 0->100% over StealDuration). fireSteal adds the
-- instant burst on the priority target. findNearestPrompt gates everything on StealRadius
-- (60 studs by default), so it only fires when the target is actually in range.
local function executeSteal(prompt)
    if isAutoStealing then return end
    if not StealData[prompt] then
        StealData[prompt] = {hold = {}, trigger = {}, ready = true}
        if getconnections then
            for _, c in ipairs(getconnections(prompt.PromptButtonHoldBegan)) do
                if c.Function then table.insert(StealData[prompt].hold, c.Function) end
            end
            for _, c in ipairs(getconnections(prompt.Triggered)) do
                if c.Function then table.insert(StealData[prompt].trigger, c.Function) end
            end
        end
    end
    local data = StealData[prompt]
    if not data.ready then return end
    data.ready = false
    isAutoStealing = true
    _stealStart = tick()
    task.spawn(function()
        local oldDuration = prompt.HoldDuration
        prompt.HoldDuration = 0
        for _, f in ipairs(data.hold) do task.spawn(f) end
        task.wait(Config.StealDuration or 1.3)
        for _, f in ipairs(data.trigger) do task.spawn(f) end
        if fireproximityprompt then pcall(fireproximityprompt, prompt) end
        prompt.HoldDuration = oldDuration
        data.ready = true
        isAutoStealing = false
    end)
end

RunService.Heartbeat:Connect(function()
    if not (Config.AutoSteal ~= false) then return end
    if isAutoStealing then return end
    local p = findNearestPrompt()
    if p then
        -- SINGLE auto-steal: only the held variant runs (StealRadius 60 +
        -- StealDuration 1.3s). The old code ALSO called fireSteal() on the
        -- priority target's prompt every Heartbeat - that's the instant-burst
        -- variant that sets HoldDuration=0 and spams the Triggered handlers
        -- 6 times. When both ran on the same prompt every frame, they
        -- conflicted (instant fire racing the legitimate 1.3s hold, server
        -- saw both events and ignored / failed the steal). Now only the
        -- held executeSteal runs. Single source of truth.
        executeSteal(p)
    end
end)

-- ?? Animal scanner ????????????????????????????????????????????????????????????
task.spawn(function()

-- ?? Scanners ??????????????????????????????????????????????????????????????????

    local Pkgs   = ReplicatedStorage:WaitForChild("Packages")
    local Sync   = require(Pkgs:WaitForChild("Synchronizer"))
    pcall(function()
        for _, name in ipairs({"Get", "Wait"}) do
            local fn = Sync[name]
            if not fn then continue end
            local ok, ups = pcall(debug.getupvalues, fn)
            if not ok then continue end
            for idx, val in pairs(ups) do
                if typeof(val) == "function" and not isexecutorclosure(val) then
                    debug.setupvalue(fn, idx, function() end)
                end
            end
        end
    end)
    local AData   = require(ReplicatedStorage:WaitForChild("Datas"):WaitForChild("Animals"))
    local AShared = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Animals"))
    local NUtils  = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("NumberUtils"))
    local lastH   = {}

    local function scan(plot)
        local ok, ch = pcall(function() return Sync:Get(plot.Name) end)
        if not ok or not ch then return end
        local al = ch:Get("AnimalList")
        local h  = ""
        if al then for s, d in pairs(al) do if type(d) == "table" then h = h..s..(d.Index or "")..(d.Mutation or "") end end end
        if lastH[plot.Name] == h then return end
        lastH[plot.Name] = h
        for i = #SharedState.AllAnimalsCache, 1, -1 do if SharedState.AllAnimalsCache[i].plot == plot.Name then table.remove(SharedState.AllAnimalsCache, i) end end
        if not al then return end
        local owner = ch:Get("Owner"); if not owner then return end
        local on = (typeof(owner) == "Instance" and owner.Name) or (type(owner) == "table" and owner.Name) or "?"
        if not Players:FindFirstChild(on) then return end
        for slot, ad in pairs(al) do
            if type(ad) == "table" then
                local inf = AData[ad.Index]
                if inf then
                    local mut = ad.Mutation or "None"
                    if mut == "Yin Yang" then mut = "YinYang" end
                    local gv = AShared:GetGeneration(ad.Index, ad.Mutation, ad.Traits, nil)
                    table.insert(SharedState.AllAnimalsCache, {
                        name     = inf.DisplayName or ad.Index,
                        genText  = "$"..NUtils:ToString(gv).."/s",
                        genValue = gv,
                        mutation = mut,
                        owner    = on,
                        plot     = plot.Name,
                        slot     = tostring(slot),
                        uid      = plot.Name.."_"..tostring(slot),
                    })
                end
            end
        end
        table.sort(SharedState.AllAnimalsCache, function(a, b) return a.genValue > b.genValue end)
    end

    local function setup(plot)
        local ch, tries = nil, 0
        while not ch and tries < 50 do
            local ok, r = pcall(function() return Sync:Get(plot.Name) end)
            if ok and r then ch = r; break end
            tries += 1; task.wait(0.1)
        end
        if not ch then return end
        scan(plot)
        plot.DescendantAdded:Connect(function()    task.wait(0.1); scan(plot) end)
        plot.DescendantRemoving:Connect(function() task.wait(0.1); scan(plot) end)
        task.spawn(function() while plot.Parent do task.wait(5); scan(plot) end end)
    end

    local plots = Workspace:WaitForChild("Plots", 8)
    if plots then
        for _, p in ipairs(plots:GetChildren()) do task.spawn(setup, p) end
        plots.ChildAdded:Connect(function(p)   task.wait(0.3); setup(p) end)
        plots.ChildRemoved:Connect(function(p)
            lastH[p.Name] = nil
            for i = #SharedState.AllAnimalsCache, 1, -1 do if SharedState.AllAnimalsCache[i].plot == p.Name then table.remove(SharedState.AllAnimalsCache, i) end end
        end)
    end
end)

-- ?? Walking brainrot scanner ??????????????????????????????????????????????????
task.spawn(function()
    local AData   = require(ReplicatedStorage:WaitForChild("Datas"):WaitForChild("Animals"))
    local AShared = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Animals"))
    local NUtils  = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("NumberUtils"))

    local BLACKLIST = {
        ["arcadopus"] = true, ["festive lucky block"] = true,
        ["spooky lucky block"] = true, ["leprechaun lucky block"] = true,
    }
    local nameMap = {}
    for index, data in pairs(AData) do
        local iL = index:lower()
        local dL = (data.DisplayName or ""):lower()
        local entry = {index = index, data = data}
        nameMap[iL] = entry; nameMap[iL:gsub("%s+", "")] = entry
        if dL ~= "" then nameMap[dL] = entry; nameMap[dL:gsub("%s+", "")] = entry end
    end

    local function isInsidePlots(obj)
        local p = obj.Parent
        while p do
            if p == Workspace then return false end
            if p.Name == "Plots" then return true end
            p = p.Parent
        end
        return false
    end

    local function findPromptOnModel(model)
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.Enabled and d.ActionText == "Steal" then return d end
        end
        return nil
    end

    local function isInCache(obj)
        for _, e in ipairs(SharedState.WalkingCache) do if e.model == obj then return true end end
        return false
    end

    local function tryAdd(obj)
        if not obj or not obj:IsA("Model") then return end
        if isInCache(obj) then return end
        if isInsidePlots(obj) then return end
        if Players:GetPlayerFromCharacter(obj) then return end
        local mLow  = obj.Name:lower()
        local found = nameMap[mLow] or nameMap[mLow:gsub("%s+", "")]
        if not found then return end
        local dispLow = (found.data.DisplayName or found.index):lower()
        if BLACKLIST[dispLow] or BLACKLIST[mLow] then return end
        if not obj:FindFirstChildWhichIsA("Humanoid", true) then return end
        local gv = 0
        local ok1, val = pcall(function() return AShared:GetGeneration(found.index, nil, nil, nil) end)
        if ok1 and val then gv = val end
        local genStr = "$0/s"
        local ok2, str = pcall(function() return NUtils:ToString(gv) end)
        if ok2 and str then genStr = "$"..str.."/s" end
        local entry = {
            name = found.data.DisplayName or found.index, genValue = gv,
            genText = genStr, mutation = "None", owner = "[Walking]",
            plot = "walking", slot = "walking", uid = "walk_"..tostring(obj),
            isWalking = true, model = obj, prompt = findPromptOnModel(obj),
        }
        table.insert(SharedState.WalkingCache, entry)
        obj.AncestryChanged:Connect(function()
            if not obj:IsDescendantOf(Workspace) then
                for i = #SharedState.WalkingCache, 1, -1 do if SharedState.WalkingCache[i].model == obj then table.remove(SharedState.WalkingCache, i); break end end
            end
        end)
        task.spawn(function()
            local t = tick()
            while tick()-t < 10 do
                task.wait(0.5)
                if not obj.Parent then break end
                if entry.prompt and entry.prompt.Parent and entry.prompt.Enabled then break end
                entry.prompt = findPromptOnModel(obj)
            end
        end)
    end

    local function fullScan()
        for i = #SharedState.WalkingCache, 1, -1 do
            if not SharedState.WalkingCache[i].model or not SharedState.WalkingCache[i].model.Parent then table.remove(SharedState.WalkingCache, i) end
        end
        for _, obj in ipairs(Workspace:GetDescendants()) do pcall(tryAdd, obj) end
    end

    -- Fires for every descendant added to Workspace -- a lot of bails on non-Humanoid
    -- spawns. Wrap native so the early-return is cheap under Luraph's VM.
    Workspace.DescendantAdded:Connect(LPH_NO_VIRTUALIZE(function(obj)
        if not obj:IsA("Humanoid") then return end
        local model = obj.Parent
        if not model or not model:IsA("Model") then return end
        if isInsidePlots(model) then return end
        local mLow = model.Name:lower()
        if nameMap[mLow] or nameMap[mLow:gsub("%s+", "")] then task.wait(0.1); pcall(tryAdd, model) end
    end))

    -- Periodic safety-net scan. The DescendantAdded hook above + per-entry AncestryChanged
    -- already keep the cache live, so the only thing fullScan actually catches is brainrots
    -- that existed BEFORE the script loaded (covered by the one-shot pcall below) and
    -- desyncs. Previously this ran every 2s and walked Workspace:GetDescendants() under the
    -- Luraph VM -- ~tens of thousands of instances * 2 per file (two identical scanners),
    -- which matches the "every couple seconds" FPS dip. Bumped to 30s and the periodic
    -- scan wrapped native so each tick is cheap.
    pcall(fullScan)
    task.spawn(LPH_NO_VIRTUALIZE(function()
        while true do task.wait(30); pcall(fullScan) end
    end))
end)

-- ??????????????????????????????????????????????????????????????????????????????
--  UI
-- ??????????????????????????????????????????????????????????????????????????????

-- ?? AutoSteal UI ?????????????????????????????????????????????????????????????

do local o = PlayerGui:FindFirstChild("AutoStealUI"); if o then o:Destroy() end end

local sg = Instance.new("ScreenGui")
sg.Name = "AutoStealUI"; sg.ResetOnSpawn = false; sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.IgnoreGuiInset = true
sg.Parent = PlayerGui

-- ?? Save / Load ???????????????????????????????????????????????????????????????
local function saveConfig()
    if not _cfgLoaded then return end
    local data = {
        autoSteal   = (Config.AutoSteal ~= false),
        usePriority = (Config.UsePriority ~= false),
        stealRadius = (Config.StealRadius or 60),
        priority = PRIORITY_LIST,
    }
    for k, p in pairs(_panelRefs) do
        if p and p.Parent then
            data[k] = {x = p.Position.X.Offset, y = p.Position.Y.Offset}
        end
    end
    pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(data)) end)
end

local function loadConfig()
    local ok, raw = pcall(function() return readfile(SAVE_FILE) end)
    if not ok or not raw or raw == "" then _cfgLoaded = true; return end
    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok2 or type(data) ~= "table" then _cfgLoaded = true; return end
    if type(data.autoSteal) == "boolean" then Config.AutoSteal = data.autoSteal end
    if type(data.usePriority) == "boolean" then Config.UsePriority = data.usePriority end
    if type(data.stealRadius) == "number" then Config.StealRadius = data.stealRadius end
    if type(data.priority) == "table" then
        PRIORITY_LIST = {}; PRIORITY = PRIORITY_LIST
        for _, v in ipairs(data.priority) do if type(v) == "string" then table.insert(PRIORITY_LIST, v) end end
    end
    for k, p in pairs(_panelRefs) do
        if data[k] and p and p.Parent then
            p.Position = UDim2.new(0, data[k].x, 0, data[k].y)
        end
    end
    _cfgLoaded = true
end

-- ?? Drag helper ???????????????????????????????????????????????????????????????
local function drag(handle, target)
    local down, ds, sp
    handle.InputBegan:Connect(function(i)
        if _guiLocked then return end
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            down = true; ds = i.Position; sp = target.Position
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if down and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
            down = false; pcall(saveConfig); pcall(SaveConfig)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if _guiLocked or not down then return end
        if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
            local d = i.Position - ds
            target.Position = UDim2.new(0, sp.X.Offset + d.X, 0, sp.Y.Offset + d.Y)
        end
    end)
end

-- ??????????????????????????????????????????????????????????????????
--  MAIN PANEL  (target list + controls)
-- ??????????????????????????????????????????????????????????????????
local PANEL_W = 260
local PANEL_H = 430

local panel = Instance.new("Frame", sg)
panel.Size = UDim2.new(0, PANEL_W, 0, PANEL_H)
panel.Position = UDim2.new(0, 16, 0, 100)
panel.BackgroundColor3 = Theme.Background
panel.BackgroundTransparency = 0.18
panel.BorderSizePixel = 0
panel.ClipsDescendants = true
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 14)
local panelStroke = Instance.new("UIStroke", panel)
panelStroke.Color = Theme.Accent1
panelStroke.Thickness = 1.5
panelStroke.Transparency = 0.3
_panelRefs.panel = panel

-- ?? Header ????????????????????????????????????????????????????????????????????
local hdr = Instance.new("Frame", panel)
hdr.Size = UDim2.new(1, 0, 0, 38)
hdr.BackgroundColor3 = Theme.Surface
hdr.BackgroundTransparency = 0.0
hdr.BorderSizePixel = 0
Instance.new("UICorner", hdr).CornerRadius = UDim.new(0, 14)
-- fix bottom corners
local hdrBot = Instance.new("Frame", hdr)
hdrBot.Size = UDim2.new(1, 0, 0, 10)
hdrBot.Position = UDim2.new(0, 0, 1, -10)
hdrBot.BackgroundColor3 = Theme.Surface
hdrBot.BorderSizePixel = 0

local hdrTitle = Instance.new("TextLabel", hdr)
hdrTitle.Size = UDim2.new(1, -16, 1, 0)
hdrTitle.Position = UDim2.new(0, 14, 0, 0)
hdrTitle.BackgroundTransparency = 1
hdrTitle.Text = "TARGET SELECTOR"
hdrTitle.Font = Enum.Font.GothamBlack
hdrTitle.TextSize = 13
hdrTitle.TextColor3 = Theme.TextPrimary
hdrTitle.TextXAlignment = Enum.TextXAlignment.Left
drag(hdr, panel)

-- thin accent line under header
local hdrLine = Instance.new("Frame", panel)
hdrLine.Size = UDim2.new(1, 0, 0, 1)
hdrLine.Position = UDim2.new(0, 0, 0, 38)
hdrLine.BackgroundColor3 = Theme.Accent1
hdrLine.BackgroundTransparency = 0.5
hdrLine.BorderSizePixel = 0

-- ?? Manual target status bar ??????????????????????????????????????????????????
local statusRow = Instance.new("Frame", panel)
statusRow.Size = UDim2.new(1, -16, 0, 20)
statusRow.Position = UDim2.new(0, 8, 0, 44)
statusRow.BackgroundTransparency = 1
statusRow.BorderSizePixel = 0

local manualLbl = Instance.new("TextLabel", statusRow)
manualLbl.Size = UDim2.new(1, -68, 1, 0)
manualLbl.BackgroundTransparency = 1
manualLbl.Text = "AUTO SELECT"
manualLbl.Font = Enum.Font.GothamBold
manualLbl.TextSize = 9
manualLbl.TextColor3 = T.Ok
manualLbl.TextXAlignment = Enum.TextXAlignment.Left

local clearBtn = Instance.new("TextButton", statusRow)
clearBtn.Size = UDim2.new(0, 64, 1, 0)
clearBtn.Position = UDim2.new(1, -64, 0, 0)
clearBtn.BackgroundColor3 = Theme.SurfaceHighlight
clearBtn.Text = "CLEAR TARGET"
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 7
clearBtn.BorderSizePixel = 0
clearBtn.TextColor3 = Theme.TextSecondary
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 4)
Instance.new("UIStroke", clearBtn).Color = Theme.Accent2

-- ?? Scrollable animal list ????????????????????????????????????????????????????
local scroll = Instance.new("ScrollingFrame", panel)
scroll.Size = UDim2.new(1, -10, 1, -152)
scroll.Position = UDim2.new(0, 5, 0, 70)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarImageTransparency = 0.7
scroll.ScrollBarThickness = 3
scroll.ScrollingDirection = Enum.ScrollingDirection.Y
local uiList = Instance.new("UIListLayout", scroll)
uiList.Padding = UDim.new(0, 3)
uiList.SortOrder = Enum.SortOrder.LayoutOrder
local uiPad = Instance.new("UIPadding", scroll)
uiPad.PaddingTop = UDim.new(0, 2)
uiPad.PaddingBottom = UDim.new(0, 2)
uiList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    scroll.CanvasSize = UDim2.new(0, 0, 0, uiList.AbsoluteContentSize.Y + 6)
end)


-- ?? Edit Priority List button ?????????????????????????????????????????????????
local editPrioBtn = Instance.new("TextButton", panel)
editPrioBtn.Size = UDim2.new(1, -16, 0, 32)
editPrioBtn.Position = UDim2.new(0, 8, 1, -40)
editPrioBtn.BackgroundColor3 = Theme.Surface
editPrioBtn.BackgroundTransparency = 0.1
editPrioBtn.Text = "Edit Priority List"
editPrioBtn.Font = Enum.Font.GothamBold
editPrioBtn.TextSize = 11
editPrioBtn.BorderSizePixel = 0
editPrioBtn.TextColor3 = Theme.TextPrimary
Instance.new("UICorner", editPrioBtn).CornerRadius = UDim.new(0, 7)
local epStroke = Instance.new("UIStroke", editPrioBtn)
epStroke.Color = Theme.Accent2
epStroke.Thickness = 1

-- ?? Priority / Auto Steal toggle ??????????????????????????????????????????????
-- label

-- Nearest toggle
local nearestRow = Instance.new("Frame", panel)
nearestRow.Size = UDim2.new(1, -16, 0, 28)
nearestRow.Position = UDim2.new(0, 8, 1, -74)
nearestRow.BackgroundColor3 = Theme.Surface
nearestRow.BackgroundTransparency = 0.1
nearestRow.BorderSizePixel = 0
Instance.new("UICorner", nearestRow).CornerRadius = UDim.new(0, 7)
local nearestStroke = Instance.new("UIStroke", nearestRow)
nearestStroke.Color = stealNearest and Color3.fromRGB(100, 255, 160) or Theme.SurfaceHighlight
nearestStroke.Thickness = 1; nearestStroke.Transparency = 0.3

local nearestLbl = Instance.new("TextLabel", nearestRow)
nearestLbl.Size = UDim2.new(1, -56, 1, 0)
nearestLbl.Position = UDim2.new(0, 8, 0, 0)
nearestLbl.BackgroundTransparency = 1
nearestLbl.Text = stealNearest and "Nearest: ON" or "Nearest: OFF"
nearestLbl.Font = Enum.Font.GothamBold
nearestLbl.TextSize = 10
nearestLbl.TextColor3 = stealNearest and Color3.fromRGB(100, 255, 160) or Theme.TextSecondary
nearestLbl.TextXAlignment = Enum.TextXAlignment.Left

local nearestPill = Instance.new("Frame", nearestRow)
nearestPill.Size = UDim2.new(0, 36, 0, 18)
nearestPill.Position = UDim2.new(1, -42, 0.5, -9)
nearestPill.BackgroundColor3 = stealNearest and Color3.fromRGB(30, 180, 100) or Theme.SurfaceHighlight
nearestPill.BorderSizePixel = 0
Instance.new("UICorner", nearestPill).CornerRadius = UDim.new(1, 0)
local nearestKnob = Instance.new("Frame", nearestPill)
nearestKnob.Size = UDim2.new(0, 13, 0, 13)
nearestKnob.Position = stealNearest and UDim2.new(1, -15, 0.5, -6.5) or UDim2.new(0, 2, 0.5, -6.5)
nearestKnob.BackgroundColor3 = Color3.new(1, 1, 1)
nearestKnob.BorderSizePixel = 0
Instance.new("UICorner", nearestKnob).CornerRadius = UDim.new(1, 0)
local nearestBtn = Instance.new("TextButton", nearestRow)
nearestBtn.Size = UDim2.new(1, 0, 1, 0)
nearestBtn.BackgroundTransparency = 1
nearestBtn.Text = ""
nearestBtn.BorderSizePixel = 0

local function toggleNearest()
    stealNearest = not stealNearest
    Config.StealNearest = stealNearest
    pcall(SaveConfig); pcall(saveConfig)
    nearestLbl.Text = stealNearest and "Nearest: ON" or "Nearest: OFF"
    nearestLbl.TextColor3 = stealNearest and Color3.fromRGB(100, 255, 160) or Theme.TextSecondary
    nearestPill.BackgroundColor3 = stealNearest and Color3.fromRGB(30, 180, 100) or Theme.SurfaceHighlight
    nearestKnob.Position = stealNearest and UDim2.new(1, -15, 0.5, -6.5) or UDim2.new(0, 2, 0.5, -6.5)
    nearestStroke.Color = stealNearest and Color3.fromRGB(100, 255, 160) or Theme.SurfaceHighlight
end
nearestBtn.MouseButton1Click:Connect(toggleNearest)
-- toggle pill
local toggleRow = Instance.new("Frame", panel)
toggleRow.Size = UDim2.new(1, -16, 0, 36)
toggleRow.Position = UDim2.new(0, 8, 1, -116)
toggleRow.BackgroundColor3 = Theme.Surface
toggleRow.BackgroundTransparency = 0.1
toggleRow.BorderSizePixel = 0
Instance.new("UICorner", toggleRow).CornerRadius = UDim.new(0, 8)
local tgStroke = Instance.new("UIStroke", toggleRow)
tgStroke.Color = (Config.AutoSteal ~= false) and Color3.fromRGB(100, 255, 160) or Theme.SurfaceHighlight
tgStroke.Thickness = 1.2
tgStroke.Transparency = 0.2

local toggleLabel = Instance.new("TextLabel", toggleRow)
toggleLabel.Size = UDim2.new(1, -56, 1, 0)
toggleLabel.Position = UDim2.new(0, 12, 0, 0)
toggleLabel.BackgroundTransparency = 1
toggleLabel.Text = (Config.AutoSteal ~= false) and "Auto Stealing" or "Stealing Off"
toggleLabel.Font = Enum.Font.GothamBlack
toggleLabel.TextSize = 12
toggleLabel.TextColor3 = (Config.AutoSteal ~= false) and Color3.fromRGB(100, 255, 160) or Theme.TextSecondary
toggleLabel.TextXAlignment = Enum.TextXAlignment.Left

-- pill switch
local pillBg = Instance.new("Frame", toggleRow)
pillBg.Size = UDim2.new(0, 42, 0, 22)
pillBg.Position = UDim2.new(1, -50, 0.5, -11)
pillBg.BackgroundColor3 = (Config.AutoSteal ~= false) and Color3.fromRGB(30, 180, 100) or Theme.SurfaceHighlight
pillBg.BorderSizePixel = 0
Instance.new("UICorner", pillBg).CornerRadius = UDim.new(1, 0)

local pillKnob = Instance.new("Frame", pillBg)
pillKnob.Size = UDim2.new(0, 16, 0, 16)
pillKnob.Position = (Config.AutoSteal ~= false) and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
pillKnob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
pillKnob.BorderSizePixel = 0
Instance.new("UICorner", pillKnob).CornerRadius = UDim.new(1, 0)

local toggleBtn = Instance.new("TextButton", toggleRow)
toggleBtn.Size = UDim2.new(1, 0, 1, 0)
toggleBtn.BackgroundTransparency = 1
toggleBtn.Text = ""
toggleBtn.BorderSizePixel = 0

local function updateToggleUI()
    local on = (Config.AutoSteal ~= false)
    toggleLabel.Text = on and "Auto Stealing" or "Stealing Off"
    toggleLabel.TextColor3 = on and Color3.fromRGB(100, 255, 160) or Theme.TextSecondary
    pillBg.BackgroundColor3 = on and Color3.fromRGB(30, 180, 100) or Theme.SurfaceHighlight
    pillKnob.Position = on and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
    tgStroke.Color = on and Color3.fromRGB(100, 255, 160) or Theme.SurfaceHighlight
end

toggleBtn.MouseButton1Click:Connect(function()
    Config.AutoSteal = not (Config.AutoSteal ~= false)
    updateToggleUI()
    pcall(SaveConfig)
    pcall(saveConfig)
end)

-- ?? Animal list builder ???????????????????????????????????????????????????????
local selectedUID = nil

local function getTop10()
    local out, seen = {}, {}
    for _, pName in ipairs(PRIORITY_LIST) do
        local sn = pName:lower()
        for _, a in ipairs(SharedState.AllAnimalsCache) do
            if a and a.name and a.name:lower() == sn and a.owner ~= LocalPlayer.Name
            and not isOwnerInDuel(a.owner) and not seen[a.uid] then
                seen[a.uid] = true; table.insert(out, a); if #out >= 10 then break end
            end
        end
        if #out >= 10 then break end
    end
    -- walking brainrots are excluded from the target selector (auto buy only)
    if #out < 10 then
        for _, a in ipairs(SharedState.AllAnimalsCache) do
            if a and a.owner ~= LocalPlayer.Name and not isOwnerInDuel(a.owner) and not seen[a.uid] then
                seen[a.uid] = true; table.insert(out, a); if #out >= 10 then break end
            end
        end
    end
    return out
end

local function rebuildList()
    for _, b in ipairs(scroll:GetChildren()) do if b:IsA("Frame") or b:IsA("TextButton") then b:Destroy() end end
    local top10 = getTop10()
    for i, a in ipairs(top10) do
        local isSel = (selectedUID == a.uid)
        local mutColor = MUTCOL[a.mutation] or Color3.fromRGB(160, 0, 255)

        -- Row background tinted by mutation color
        local function lerpColor(c1,c2,t)
            return Color3.new(c1.R+(c2.R-c1.R)*t, c1.G+(c2.G-c1.G)*t, c1.B+(c2.B-c1.B)*t)
        end
        local baseRowColor = a.mutation and a.mutation ~= "None"
            and lerpColor(Theme.Background, mutColor, 0.12)
            or Theme.Surface
        local selRowColor  = a.mutation and a.mutation ~= "None"
            and lerpColor(Theme.Surface, mutColor, 0.22)
            or Theme.SurfaceHighlight

        local row = Instance.new("TextButton", scroll)
        row.Size = UDim2.new(1, -4, 0, 34)
        row.LayoutOrder = i
        row.BackgroundColor3 = isSel and selRowColor or baseRowColor
        row.BackgroundTransparency = isSel and 0.0 or 0.15
        row.BorderSizePixel = 0
        row.Text = ""
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 7)
        local ss = Instance.new("UIStroke", row)
        ss.Color = isSel and Theme.Accent1 or mutColor
        ss.Thickness = isSel and 1.2 or 0.7
        ss.Transparency = isSel and 0.1 or 0.7

        -- mutation color bar
        local bar = Instance.new("Frame", row)
        bar.Size = UDim2.new(0, 3, 1, -10)
        bar.Position = UDim2.new(0, 4, 0, 5)
        bar.BackgroundColor3 = mutColor
        bar.BorderSizePixel = 0
        Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

        -- rank number
        local rk = Instance.new("TextLabel", row)
        rk.Size = UDim2.new(0, 24, 1, 0)
        rk.Position = UDim2.new(0, 10, 0, 0)
        rk.BackgroundTransparency = 1
        rk.Text = tostring(i)
        rk.Font = Enum.Font.GothamBlack
        rk.TextSize = 13
        rk.TextColor3 = isSel and Theme.TextPrimary or Theme.TextSecondary
        rk.TextXAlignment = Enum.TextXAlignment.Center

        -- mutation tag (Diamond, Gold, etc.) shown before name if not None
        local nameStr = a.name
        local mutTag = ""
        if a.mutation and a.mutation ~= "None" then
            mutTag = a.mutation .. " "
        end

        local nm = Instance.new("TextLabel", row)
        nm.Size = UDim2.new(1, -110, 1, 0)
        nm.Position = UDim2.new(0, 36, 0, 0)
        nm.BackgroundTransparency = 1
        nm.Font = Enum.Font.GothamBold
        nm.TextSize = 11
        nm.TextXAlignment = Enum.TextXAlignment.Left
        nm.TextTruncate = Enum.TextTruncate.AtEnd

        if a.mutation and a.mutation ~= "None" then
            -- show mutation label in its color, animal name in normal
            nm.Text = a.mutation .. "  " .. nameStr
            nm.TextColor3 = mutColor
        else
            nm.Text = nameStr
            nm.TextColor3 = isSel and Theme.TextPrimary or Theme.TextSecondary
        end

        -- gen value
        local gn = Instance.new("TextLabel", row)
        gn.Size = UDim2.new(0, 70, 1, 0)
        gn.Position = UDim2.new(1, -74, 0, 0)
        gn.BackgroundTransparency = 1
        gn.Text = a.genText
        gn.Font = Enum.Font.GothamBold
        gn.TextSize = 10
        gn.TextColor3 = mutColor
        gn.TextXAlignment = Enum.TextXAlignment.Right

        local ca = a
        row.MouseButton1Click:Connect(function()
            selectedUID = ca.uid
            manualTarget = ca
            SharedState.SetManualTarget(ca)
            manualLbl.Text = ca.name
            manualLbl.TextColor3 = Color3.fromRGB(180, 130, 255)
            rebuildList()
            -- Selecting a target no longer auto-teleports. It only sets the target so
            -- pressing T (runAutoSnipe) or getting hit (hit recovery) goes to THIS brainrot.
        end)
    end
    scroll.CanvasSize = UDim2.new(0, 0, 0, uiList.AbsoluteContentSize.Y + 6)
end

clearBtn.MouseButton1Click:Connect(function()
    manualTarget = nil
    selectedUID = nil
    SharedState.SetManualTarget(nil)
    manualLbl.Text = "AUTO SELECT"
    manualLbl.TextColor3 = T.Ok
    rebuildList()
end)

-- auto-clear manual target if it disappears + refresh list
task.spawn(function()
    while panel.Parent do
        task.wait(0.5)
        if manualTarget then
            local found = false
            for _, a in ipairs(SharedState.AllAnimalsCache) do if a.uid == manualTarget.uid then found = true; break end end
            if not found then for _, a in ipairs(SharedState.WalkingCache) do if a.uid == manualTarget.uid then found = true; break end end end
            if not found then
                manualTarget = nil; selectedUID = nil
                manualLbl.Text = "AUTO SELECT"; manualLbl.TextColor3 = T.Ok
            end
        end
        rebuildList()
    end
end)

-- ??????????????????????????????????????????????????????????????????
--  PRIORITY EDITOR PANEL
-- ??????????????????????????????????????????????????????????????????
local editorOpen = false
local editorGui  = nil

local function openEditor()
    if editorOpen and editorGui and editorGui.Parent then
        editorGui:Destroy(); editorOpen = false; return
    end
    editorOpen = true
    local edSg = Instance.new("ScreenGui", PlayerGui)
    edSg.Name = "AutoStealPriorityEditor"; edSg.ResetOnSpawn = false
    editorGui = edSg

    local edPanel = Instance.new("Frame", edSg)
    edPanel.Size = UDim2.new(0, 320, 0, 520)
    edPanel.Position = UDim2.new(0.5, -160, 0.5, -260)
    edPanel.BackgroundColor3 = Color3.fromRGB(14, 8, 26)
    edPanel.BackgroundTransparency = 0.08
    edPanel.BorderSizePixel = 0
    edPanel.ClipsDescendants = true
    Instance.new("UICorner", edPanel).CornerRadius = UDim.new(0, 14)
    local edStr = Instance.new("UIStroke", edPanel)
    edStr.Color = Color3.fromRGB(130, 60, 220)
    edStr.Thickness = 1.5
    edStr.Transparency = 0.25

    local edHdr = Instance.new("Frame", edPanel)
    edHdr.Size = UDim2.new(1, 0, 0, 38)
    edHdr.BackgroundColor3 = Color3.fromRGB(22, 10, 40)
    edHdr.BorderSizePixel = 0
    Instance.new("UICorner", edHdr).CornerRadius = UDim.new(0, 14)
    local edHfix = Instance.new("Frame", edHdr)
    edHfix.Size = UDim2.new(1, 0, 0, 10)
    edHfix.Position = UDim2.new(0, 0, 1, -10)
    edHfix.BackgroundColor3 = Color3.fromRGB(22, 10, 40)
    edHfix.BorderSizePixel = 0

    local edTtl = Instance.new("TextLabel", edHdr)
    edTtl.Size = UDim2.new(1, -80, 1, 0)
    edTtl.Position = UDim2.new(0, 14, 0, 0)
    edTtl.BackgroundTransparency = 1
    edTtl.Text = "PRIORITY LIST EDITOR"
    edTtl.Font = Enum.Font.GothamBlack
    edTtl.TextSize = 13
    edTtl.TextColor3 = Color3.fromRGB(200, 160, 255)
    edTtl.TextXAlignment = Enum.TextXAlignment.Left
    drag(edHdr, edPanel)

    local closeEd = Instance.new("TextButton", edHdr)
    closeEd.Size = UDim2.new(0, 50, 0, 22)
    closeEd.Position = UDim2.new(1, -56, 0.5, -11)
    closeEd.BackgroundColor3 = Color3.fromRGB(180, 30, 60)
    closeEd.Text = "CLOSE"
    closeEd.Font = Enum.Font.GothamBold
    closeEd.TextSize = 9
    closeEd.BorderSizePixel = 0
    closeEd.TextColor3 = Color3.fromRGB(255, 255, 255)
    Instance.new("UICorner", closeEd).CornerRadius = UDim.new(0, 5)
    closeEd.MouseButton1Click:Connect(function() edSg:Destroy(); editorOpen = false end)

    local hintLbl = Instance.new("TextLabel", edPanel)
    hintLbl.Size = UDim2.new(1, -16, 0, 14)
    hintLbl.Position = UDim2.new(0, 8, 0, 42)
    hintLbl.BackgroundTransparency = 1
    hintLbl.Text = "^  v  to reorder   |   Top of list = stolen first"
    hintLbl.Font = Enum.Font.Gotham
    hintLbl.TextSize = 8
    hintLbl.TextColor3 = Color3.fromRGB(110, 80, 160)
    hintLbl.TextXAlignment = Enum.TextXAlignment.Left

    local edScroll = Instance.new("ScrollingFrame", edPanel)
    edScroll.Size = UDim2.new(1, -16, 1, -100)
    edScroll.Position = UDim2.new(0, 8, 0, 58)
    edScroll.BackgroundTransparency = 1
    edScroll.BorderSizePixel = 0
    edScroll.ScrollBarThickness = 3
    edScroll.ScrollBarImageTransparency = 0.6
    edScroll.ScrollingDirection = Enum.ScrollingDirection.Y
    local edList = Instance.new("UIListLayout", edScroll)
    edList.Padding = UDim.new(0, 3)
    edList.SortOrder = Enum.SortOrder.LayoutOrder
    edList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        edScroll.CanvasSize = UDim2.new(0, 0, 0, edList.AbsoluteContentSize.Y + 6)
    end)

    local function rebuildEditor()
        for _, c in ipairs(edScroll:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
        for i, name in ipairs(PRIORITY_LIST) do
            local row = Instance.new("Frame", edScroll)
            row.Size = UDim2.new(1, -4, 0, 30)
            row.LayoutOrder = i
            row.BackgroundColor3 = Color3.fromRGB(22, 10, 38)
            row.BackgroundTransparency = 0.15
            row.BorderSizePixel = 0
            Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

            local rkL = Instance.new("TextLabel", row)
            rkL.Size = UDim2.new(0, 26, 1, 0)
            rkL.BackgroundTransparency = 1
            rkL.Text = tostring(i)
            rkL.Font = Enum.Font.GothamBlack
            rkL.TextSize = 11
            rkL.TextColor3 = Color3.fromRGB(100, 70, 150)
            rkL.TextXAlignment = Enum.TextXAlignment.Center

            local nmL = Instance.new("TextLabel", row)
            nmL.Size = UDim2.new(1, -152, 1, 0)
            nmL.Position = UDim2.new(0, 28, 0, 0)
            nmL.BackgroundTransparency = 1
            nmL.Text = name
            nmL.Font = Enum.Font.GothamBold
            nmL.TextSize = 10
            nmL.TextColor3 = Color3.fromRGB(200, 175, 235)
            nmL.TextXAlignment = Enum.TextXAlignment.Left
            nmL.TextTruncate = Enum.TextTruncate.AtEnd

            local upB = Instance.new("TextButton", row)
            upB.Size = UDim2.new(0, 24, 0, 22)
            upB.Position = UDim2.new(1, -120, 0.5, -11)
            upB.BackgroundColor3 = Color3.fromRGB(32, 16, 54)
            upB.Text = "^"; upB.Font = Enum.Font.GothamBold
            upB.TextSize = 11; upB.BorderSizePixel = 0
            upB.TextColor3 = Color3.fromRGB(150, 100, 230)
            Instance.new("UICorner", upB).CornerRadius = UDim.new(0, 4)
            upB.MouseButton1Click:Connect(function()
                if i > 1 then PRIORITY_LIST[i], PRIORITY_LIST[i-1] = PRIORITY_LIST[i-1], PRIORITY_LIST[i]; rebuildEditor(); pcall(saveConfig); pcall(SaveConfig) end
            end)

            local dnB = Instance.new("TextButton", row)
            dnB.Size = UDim2.new(0, 24, 0, 22)
            dnB.Position = UDim2.new(1, -92, 0.5, -11)
            dnB.BackgroundColor3 = Color3.fromRGB(32, 16, 54)
            dnB.Text = "v"; dnB.Font = Enum.Font.GothamBold
            dnB.TextSize = 11; dnB.BorderSizePixel = 0
            dnB.TextColor3 = Color3.fromRGB(150, 100, 230)
            Instance.new("UICorner", dnB).CornerRadius = UDim.new(0, 4)
            dnB.MouseButton1Click:Connect(function()
                if i < #PRIORITY_LIST then PRIORITY_LIST[i], PRIORITY_LIST[i+1] = PRIORITY_LIST[i+1], PRIORITY_LIST[i]; rebuildEditor(); pcall(saveConfig); pcall(SaveConfig) end
            end)

            local topB = Instance.new("TextButton", row)
            topB.Size = UDim2.new(0, 28, 0, 22)
            topB.Position = UDim2.new(1, -64, 0.5, -11)
            topB.BackgroundColor3 = Color3.fromRGB(20, 100, 60)
            topB.Text = "TOP"; topB.Font = Enum.Font.GothamBlack
            topB.TextSize = 7; topB.BorderSizePixel = 0
            topB.TextColor3 = Color3.fromRGB(120, 255, 170)
            Instance.new("UICorner", topB).CornerRadius = UDim.new(0, 4)
            topB.MouseButton1Click:Connect(function()
                if i > 1 then
                    local v = table.remove(PRIORITY_LIST, i)
                    table.insert(PRIORITY_LIST, 1, v)
                    rebuildEditor(); pcall(saveConfig); pcall(SaveConfig)
                end
            end)

            local delB = Instance.new("TextButton", row)
            delB.Size = UDim2.new(0, 24, 0, 22)
            delB.Position = UDim2.new(1, -32, 0.5, -11)
            delB.BackgroundColor3 = Color3.fromRGB(120, 20, 40)
            delB.Text = "X"; delB.Font = Enum.Font.GothamBold
            delB.TextSize = 9; delB.BorderSizePixel = 0
            delB.TextColor3 = Color3.fromRGB(255, 120, 140)
            Instance.new("UICorner", delB).CornerRadius = UDim.new(0, 4)
            delB.MouseButton1Click:Connect(function()
                table.remove(PRIORITY_LIST, i); rebuildEditor(); pcall(saveConfig); pcall(SaveConfig)
            end)
        end
    end
    rebuildEditor()

    -- add bar
    local addBar = Instance.new("Frame", edPanel)
    addBar.Size = UDim2.new(1, -16, 0, 36)
    addBar.Position = UDim2.new(0, 8, 1, -44)
    addBar.BackgroundColor3 = Color3.fromRGB(22, 10, 38)
    addBar.BackgroundTransparency = 0.1
    addBar.BorderSizePixel = 0
    Instance.new("UICorner", addBar).CornerRadius = UDim.new(0, 7)
    Instance.new("UIStroke", addBar).Color = Color3.fromRGB(90, 45, 160)

    local addBox = Instance.new("TextBox", addBar)
    addBox.Size = UDim2.new(1, -74, 1, -8)
    addBox.Position = UDim2.new(0, 6, 0, 4)
    addBox.BackgroundColor3 = Color3.fromRGB(30, 14, 50)
    addBox.BackgroundTransparency = 0.1
    addBox.BorderSizePixel = 0
    addBox.Text = ""
    addBox.PlaceholderText = "Add brainrot name..."
    addBox.Font = Enum.Font.Gotham
    addBox.TextSize = 10
    addBox.TextColor3 = Color3.fromRGB(210, 185, 255)
    addBox.PlaceholderColor3 = Color3.fromRGB(100, 80, 140)
    Instance.new("UICorner", addBox).CornerRadius = UDim.new(0, 5)

    local addB = Instance.new("TextButton", addBar)
    addB.Size = UDim2.new(0, 60, 1, -8)
    addB.Position = UDim2.new(1, -64, 0, 4)
    addB.BackgroundColor3 = Color3.fromRGB(80, 30, 150)
    addB.Text = "+ ADD"
    addB.Font = Enum.Font.GothamBold
    addB.TextSize = 10
    addB.BorderSizePixel = 0
    addB.TextColor3 = Color3.fromRGB(220, 190, 255)
    Instance.new("UICorner", addB).CornerRadius = UDim.new(0, 5)
    addB.MouseButton1Click:Connect(function()
        local v = addBox.Text:match("^%s*(.-)%s*$")
        if v and #v > 0 then
            table.insert(PRIORITY_LIST, 1, v)
            addBox.Text = ""
            rebuildEditor()
            pcall(saveConfig)
        end
    end)
end

editPrioBtn.MouseButton1Click:Connect(openEditor)

-- Steal progress bar
do
    local pill = Instance.new("Frame", sg)
    pill.Name = "StealBarPill"
    do
        local savedPos = nil
        if _cfgLoaded then
            local ok, d = pcall(function() return HttpService:JSONDecode(readfile(SAVE_FILE)) end)
            if ok and d and d.stealBar then
                savedPos = d.stealBar
            end
        end
        if savedPos then
            pill.Position = UDim2.new(0, savedPos.x, 0, savedPos.y)
        else
            pill.Position = UDim2.new(0, 16, 0, 560)
        end
    end
    pill.Size = UDim2.new(0, 162, 0, 26)
    pill.BackgroundColor3 = Theme.Background
    pill.BackgroundTransparency = 0.18
    pill.BorderSizePixel = 0
    Instance.new("UICorner", pill).CornerRadius = UDim.new(0, 8)
    local pillStroke = Instance.new("UIStroke", pill)
    pillStroke.Color = Theme.Accent1
    pillStroke.Thickness = 1.5; pillStroke.Transparency = 0.3
    _panelRefs.stealBar = pill

    local pctLbl = Instance.new("TextLabel", pill)
    pctLbl.Size = UDim2.new(1,-8,1,0); pctLbl.Position = UDim2.new(0,8,0,0)
    pctLbl.BackgroundTransparency = 1; pctLbl.Text = "STEAL  0%"
    pctLbl.Font = Enum.Font.GothamBold; pctLbl.TextSize = 11
    pctLbl.TextColor3 = Color3.fromRGB(130,130,148)
    pctLbl.TextXAlignment = Enum.TextXAlignment.Left

    local track = Instance.new("Frame", pill)
    track.Size = UDim2.new(1,-10,0,3); track.Position = UDim2.new(0,5,1,-4)
    track.BackgroundColor3 = Color3.fromRGB(30,14,50); track.BorderSizePixel = 0
    Instance.new("UICorner", track).CornerRadius = UDim.new(1,0)
    local fill = Instance.new("Frame", track)
    fill.Size = UDim2.new(0,0,1,0); fill.BackgroundColor3 = Color3.fromRGB(130,60,220)
    fill.BorderSizePixel = 0
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1,0)

    drag(pill, pill)

    RunService.Heartbeat:Connect(function()
        if isAutoStealing then
            _stealProgress = math.clamp((tick()-_stealStart)/(Config.StealDuration or 1.3),0,1)
        else
            _stealProgress = 0
        end
        local pct = math.floor(_stealProgress*100)
        fill.Size = UDim2.new(_stealProgress,0,1,0)
        if _stealProgress > 0 then
            pctLbl.Text = "STEAL  "..pct.."%"
            pctLbl.TextColor3 = _stealProgress>=0.99 and Color3.fromRGB(30,185,100) or Theme.Accent1
            fill.BackgroundColor3 = _stealProgress>=0.99 and Color3.fromRGB(30,185,100) or Theme.Accent1
        else
            pctLbl.Text = "STEAL  0%"
            pctLbl.TextColor3 = Color3.fromRGB(130,130,148)
            fill.BackgroundColor3 = Theme.Accent1
        end
    end)
end

pcall(loadConfig)

-- ?? Load config ???????????????????????????????????????????????????????????????

end)()

;(function()
    local function isInsideStealHitbox()
        local char = LocalPlayer.Character
        if not char then return false end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then return false end

        local petData = SharedState.SelectedPetData
        if not petData then return false end
        local animalData = petData.animalData or petData
        if not animalData or not animalData.plot then return false end

        local Plots = Workspace:FindFirstChild("Plots")
        if not Plots then return false end
        local plot = Plots:FindFirstChild(animalData.plot)
        if not plot then return false end

        local stealHitbox = plot:FindFirstChild("StealHitbox")
        if not stealHitbox then return false end

        local playerPos = hrp.Position

        local function checkPart(part)
            local cf = part.CFrame
            local sz = part.Size
            local lp = cf:PointToObjectSpace(playerPos)
            return math.abs(lp.X) <= sz.X/2
               and math.abs(lp.Y) <= sz.Y/2
               and math.abs(lp.Z) <= sz.Z/2
        end

        if stealHitbox:IsA("BasePart") then
            return checkPart(stealHitbox)
        elseif stealHitbox:IsA("Model") then
            for _, part in ipairs(stealHitbox:GetDescendants()) do
                if part:IsA("BasePart") and part.Transparency < 1 then if checkPart(part) then return true end end
            end
        end
        return false
    end

    local _autoBackThread = nil
    local _autoBackStealConn = nil
    local _teleportingBelow = false
    local _forceAutoBackInstantCount = 0

    local function stopAutoBack()
        if _autoBackThread then task.cancel(_autoBackThread); _autoBackThread = nil end
        if _autoBackStealConn then _autoBackStealConn:Disconnect(); _autoBackStealConn = nil end
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then
            local bp = hrp:FindFirstChild("TP_BodyPosition")
            if bp then bp:Destroy() end
        end
        _teleportingBelow = false
    end

    local function getAutoBackTarget()
        local petData = SharedState.SelectedPetData
        if not petData then return nil end
        local animalData = petData.animalData or petData
        local part = findAdorneeGlobal(animalData)
        if not part then return nil end
        return part.Position, animalData
    end

    local function teleportBelowPet()
        if _teleportingBelow then return end
        _teleportingBelow = true
        pcall(function()
            local targetPos, animalData = getAutoBackTarget()
            if not targetPos then return end

            local char = LocalPlayer.Character
            if not char then return end
            local hrp = char:FindFirstChild("HumanoidRootPart")
            local hum = char:FindFirstChildOfClass("Humanoid")
            if not hrp or not hum then return end

            local petX, petY, petZ = targetPos.X, targetPos.Y, targetPos.Z
            local playerY = hrp.Position.Y

            if playerY > 25 and petY > 25 then
                hrp.CFrame = CFrame.new(targetPos)
                hrp.AssemblyLinearVelocity = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
                _teleportingBelow = false
                return
            end

            if playerY >= 8.8 and petY < 8.8 then return end
            if playerY <= 8.8 and petY > 24 then return end

            local carpetName = Config.TpSettings and Config.TpSettings.Tool or "Flying Carpet"
            local carpet = LocalPlayer.Backpack:FindFirstChild(carpetName) or char:FindFirstChild(carpetName)
            if carpet and hum then hum:EquipTool(carpet); task.wait(0.1) end

            local targetY
            if petY > 22 or (playerY < 8.8 and petY >= 8.8) then
                targetY = petY - 7.5
            else
                local rp = RaycastParams.new()
                rp.FilterDescendantsInstances = {char}
                rp.FilterType = Enum.RaycastFilterType.Exclude
                local res = Workspace:Raycast(Vector3.new(petX, petY, petZ), Vector3.new(0, -200, 0), rp)
                targetY = res and (res.Position.Y + 1.4) or 0.5
            end

            local tPos = Vector3.new(petX, targetY, petZ)
            local dist = (Vector3.new(hrp.Position.X, targetY, hrp.Position.Z) - tPos).Magnitude

            if dist > 1.5 or math.abs(hrp.Position.Y - targetY) > 2 then
                hrp.CFrame = CFrame.new(petX, targetY, petZ)
                hrp.AssemblyLinearVelocity = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
            end

            local bp = hrp:FindFirstChild("TP_BodyPosition")
            if not bp then
                bp = Instance.new("BodyPosition")
                bp.Name = "TP_BodyPosition"
                bp.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
                bp.P = 10000
                bp.D = 500
                bp.Parent = hrp
            end
            bp.Position = tPos
            bp.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
        end)
        _teleportingBelow = false
    end

    local function startAutoBack()
        stopAutoBack()

        _autoBackStealConn = LocalPlayer:GetAttributeChangedSignal("Stealing"):Connect(function()
            if LocalPlayer:GetAttribute("Stealing") == true then
                local char = LocalPlayer.Character
                local hrp = char and char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local bp = hrp:FindFirstChild("TP_BodyPosition")
                    if bp then bp:Destroy() end
        task.spawn(function()
                task.wait(0.1)
                        local rp = RaycastParams.new()
                        rp.FilterDescendantsInstances = {char}
                        rp.FilterType = Enum.RaycastFilterType.Exclude
                        local res = Workspace:Raycast(
                            Vector3.new(hrp.Position.X, hrp.Position.Y, hrp.Position.Z),
                            Vector3.new(0, -200, 0), rp
                        )
                        local floorY = res and (res.Position.Y + 1.4) or 0.5
                        hrp.CFrame = CFrame.new(hrp.Position.X, floorY, hrp.Position.Z)
                    end)
                end
            end
        end)

        local lastTeleportTime = 0

        _autoBackThread = task.spawn(function()
            while Config.AutoBack do
                pcall(function()
                    local stealing = LocalPlayer:GetAttribute("Stealing")
                    local char = LocalPlayer.Character
                    local hrp = char and char:FindFirstChild("HumanoidRootPart")
                    if not hrp then return end

                    if stealing == true then
                        local bp = hrp:FindFirstChild("TP_BodyPosition")
                        if bp then bp:Destroy() end
                        return
                    end

                    local hasBP = hrp:FindFirstChild("TP_BodyPosition") ~= nil
                    local targetPos = getAutoBackTarget()
                    local inHitbox = isInsideStealHitbox()
                    local selected = SharedState.SelectedPetData
                    local selectedAnimal = selected and (selected.animalData or selected)
                    local targetPlotOpen = false
                    if selectedAnimal and selectedAnimal.plot and _G._isTargetPlotUnlocked then
                        targetPlotOpen = (_G._isTargetPlotUnlocked(selectedAnimal.plot) == true)
                    end

                    local forceInstantNow = (_forceAutoBackInstantCount or 0) > 0
                    local canAutoBackNow = forceInstantNow or (inHitbox and not targetPlotOpen)
                    if not hasBP and not _teleportingBelow and targetPos and canAutoBackNow then
                        local now = os.clock()
                        local delay = forceInstantNow and 0 or 0.05
                        if now - lastTeleportTime >= delay then
                            teleportBelowPet()
                            if forceInstantNow and _forceAutoBackInstantCount > 0 then
                                _forceAutoBackInstantCount = _forceAutoBackInstantCount - 1
                            end
                            lastTeleportTime = now
                        end
                    end
                end)
                task.wait(0.01)
            end
            stopAutoBack()
        end)
    end

    if not Config.AutoBack then Config.AutoBack = false end

    _G.isInsideStealHitbox = isInsideStealHitbox
    _G.startAutoBack = startAutoBack
    _G.stopAutoBack = stopAutoBack
    _G.forceAutoBackInstant = function(times)
        _forceAutoBackInstantCount = math.max(tonumber(times) or 1, 1)
    end

    if Config.AutoBack then startAutoBack() end
end)()

local playerESPToggleRef = {setFn=nil}
local espToggleRef = {enabled=true, setFn=nil}
local settingsGui = nil
local executeReset = nil

-- X-Ray implementation (hook method)
local xrayEnabled   = Config.XrayEnabled or false
local xraySpoof     = {}
local _xrayDescConn = nil

local function xrayShouldApply(obj)
    if not obj:IsA("BasePart") or not obj.Anchored then return false end
    -- Walk ancestry once: bail if inside AnimalPodiums, approve if inside Plots
    local insidePlots = false
    local anc = obj.Parent
    while anc do
        if anc.Name == "AnimalPodiums" then return false end  -- skip brainrots
        if anc.Name == "Plots" then insidePlots = true end
        if anc == Workspace then break end
        anc = anc.Parent
    end
    if insidePlots then return true end
    -- Fallback: name-based check for base/claim parts outside of Plots
    local n = obj.Name:lower()
    local p = obj.Parent and obj.Parent.Name:lower() or ""
    return n:find("base") or n:find("claim") or p:find("base") or p:find("claim")
end

-- â”€â”€ X-Ray __index hook (lazy install + NON-virtualized callback) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- We MUST keep the global hookmetamethod(game, "__index", ...) spoof: the game
-- reads LocalTransparencyModifier and kicks if it isn't 0, so the hook returns 0
-- to game reads while we render the part transparent locally.
--
-- The reason this hook tanked FPS in the OBFUSCATED build (but not source) is that
-- Luraph virtualized the callback into VM bytecode. Since the hook fires on every
-- property read of every instance, the whole game then paid an interpreted cost on
-- every access, every frame. Fix: wrap the callback in LPH_NO_VIRTUALIZE so Luraph
-- compiles it to native Lua instead -- it then runs at source speed even when the
-- rest of the script is virtualized. Combined with lazy install (only hook once
-- X-Ray is toggled on), X-Ray-off users pay nothing and X-Ray-on feels like source.
--
-- (The LPH_NO_VIRTUALIZE source-build shim now lives at the very top of the script so
-- every hot per-frame callback below can wrap itself with it. See top of file.)

local _xrayHookInstalled = false
local function installXrayHook()
    if _xrayHookInstalled then return end
    if not (hookmetamethod and checkcaller) then return end
    _xrayHookInstalled = true
    local oldIndex
    local inHook = false  -- hard re-entrancy guard: hook can enter at most 1 level
    oldIndex = hookmetamethod(game, "__index", LPH_NO_VIRTUALIZE(function(self, key)
        -- IMPORTANT: do NOT call any instance methods (e.g. self:IsA / typeof)
        -- inside this hook. self:IsA(...) is itself an __index access on `self`,
        -- which re-enters this hook. We only use a string compare and a plain
        -- table lookup here, neither of which touches __index. The inHook guard
        -- guarantees that even if something here ever did re-enter __index, it
        -- bails straight to oldIndex instead of recursing.
        if not inHook and key == "LocalTransparencyModifier" then
            inHook = true
            local spoof    = xraySpoof[self]     -- plain table lookup, no __index
            local fromGame = not checkcaller()
            inHook = false
            if spoof ~= nil and fromGame then
                return spoof                     -- game sees 0 (opaque) -> no kick
            end
        end
        return oldIndex(self, key)
    end))
end

local function enableXray()
    xrayEnabled = true
    installXrayHook()  -- install the global __index hook only now (lazy)
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if xrayShouldApply(obj) then
            xraySpoof[obj] = 0
            pcall(function() obj.LocalTransparencyModifier = 0.85 end)
        end
    end
    if _xrayDescConn then _xrayDescConn:Disconnect() end
    -- Fires for every instance added to Workspace while X-Ray is on. Wrap native so the
    -- ancestry check in xrayShouldApply doesn't pay VM cost on every spawn.
    _xrayDescConn = Workspace.DescendantAdded:Connect(LPH_NO_VIRTUALIZE(function(obj)
        task.wait()
        if xrayEnabled and xrayShouldApply(obj) then
            xraySpoof[obj] = 0
            pcall(function() obj.LocalTransparencyModifier = 0.85 end)
        end
    end))
end

local function disableXray()
    xrayEnabled = false
    if _xrayDescConn then _xrayDescConn:Disconnect(); _xrayDescConn = nil end
    for obj in pairs(xraySpoof) do
        if obj and obj.Parent then
            pcall(function() obj.LocalTransparencyModifier = 0 end)
        end
    end
    xraySpoof = {}
end

if xrayEnabled then task.spawn(enableXray) end

local _initPanel = function()
local function _resetMoveToolsToBackpack(character)
    if not character then return end
    for _, ch in ipairs(character:GetChildren()) do
        if ch:IsA("Tool") then
            pcall(function() ch.Parent = LocalPlayer.Backpack end)
        end
    end
end

executeReset = function()
    ShowNotification("RESET", "Resetting character...")

    -- temporarily disable anti-die so the kill actually goes through
    if _G.tpAntiDieDisable then pcall(_G.tpAntiDieDisable) end

    -- re-enable anti-die once the new character spawns
    local respawnConn
    respawnConn = LocalPlayer.CharacterAdded:Connect(function(newChar)
        if respawnConn then respawnConn:Disconnect(); respawnConn = nil end
        task.defer(function()
            pcall(function() newChar:WaitForChild("Humanoid", 12) end)
            RunService.Heartbeat:Wait()
            if _G.tpAntiDieEnable then pcall(_G.tpAntiDieEnable) end
        end)
    end)

    local character = LocalPlayer.Character
    if not character then
        pcall(function() LocalPlayer:LoadCharacter() end)
        return
    end

    pcall(function()
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        local rootPart = character:FindFirstChild("HumanoidRootPart")
        if not (rootPart and humanoid) then return end

        -- move tools to backpack before killing
        _resetMoveToolsToBackpack(character)

        -- fling to out-of-bounds so server confirms death
        rootPart.CFrame = CFrame.new(0, 15000, 0)
        RunService.Heartbeat:Wait()
        _resetMoveToolsToBackpack(character)
        RunService.Heartbeat:Wait()

        humanoid = character:FindFirstChildOfClass("Humanoid")
        rootPart = character:FindFirstChild("HumanoidRootPart")
        if not (humanoid and rootPart) then return end

        -- kill via multiple fallbacks
        pcall(function() humanoid.Health = 0 end)
        pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Dead) end)
        if humanoid.Health > 0 then
            pcall(function() humanoid:TakeDamage(humanoid.MaxHealth * 99) end)
        end
        if humanoid.Health > 0 then
            pcall(function() character:BreakJoints() end)
        end

        -- last resort: drop below FallenPartsDestroyHeight
        humanoid = character:FindFirstChildOfClass("Humanoid")
        rootPart = character:FindFirstChild("HumanoidRootPart")
        if humanoid and rootPart and humanoid.Health > 0 then
            pcall(function()
                rootPart.AssemblyLinearVelocity = Vector3.zero
                rootPart.CFrame = CFrame.new(
                    rootPart.Position.X,
                    Workspace.FallenPartsDestroyHeight - 500,
                    rootPart.Position.Z
                )
            end)
        end
    end)

    -- force respawn via executor privilege
    task.defer(function()
        pcall(function() LocalPlayer:LoadCharacter() end)
    end)
end

task.spawn(function()
    local function checkSteal(gui)
        if not Config.AutoKickOnSteal then return end
        local txt = (gui:IsA("TextLabel") or gui:IsA("TextButton")) and gui.Text
        if txt and string.find(txt, "You stole") then kickPlayer() end
    end
    PlayerGui.DescendantAdded:Connect(function(gui)
        checkSteal(gui)
        if gui:IsA("TextLabel") or gui:IsA("TextButton") then
            gui:GetPropertyChangedSignal("Text"):Connect(function()
                checkSteal(gui)
            end)
        end
    end)
    for _, gui in ipairs(PlayerGui:GetDescendants()) do
        checkSteal(gui)
    end
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    
    local tpKey = safeKeyCode(Config.TpSettings.TpKey, Enum.KeyCode.T)
    local cloneKey = safeKeyCode(Config.TpSettings.CloneKey, Enum.KeyCode.V)
    local carpetKey = safeKeyCode(Config.TpSettings.CarpetSpeedKey, Enum.KeyCode.Q)
    local stealSpeedKey = safeKeyCode(Config.StealSpeedKey, Enum.KeyCode.Z)
    local resetKey = safeKeyCode(Config.ResetKey, Enum.KeyCode.X)
    local ragdollKey = safeKeyCode(Config.RagdollSelfKey, Enum.KeyCode.R)

    if input.KeyCode == tpKey then
        if _G._activePinConn then _G._activePinConn:Disconnect(); _G._activePinConn = nil end
        if _G._activePlat and _G._activePlat.Parent then _G._activePlat:Destroy(); _G._activePlat = nil end
        if (Config.TpMethod or "tween") == "clone" then
            pcall(function() if _G.ctpLaunch then _G.ctpLaunch() end end)
        else
            pcall(function() if _G.tpToBestBrainrot then _G.tpToBestBrainrot() end end)
        end
    end

    if input.KeyCode == cloneKey then
        if _G._activePinConn then _G._activePinConn:Disconnect(); _G._activePinConn = nil end
        if _G._activePlat and _G._activePlat.Parent then _G._activePlat:Destroy(); _G._activePlat = nil end
        instantClone()
    end
    
    if input.KeyCode == carpetKey then
        carpetSpeedEnabled = not carpetSpeedEnabled
        setCarpetSpeed(carpetSpeedEnabled)
        if _carpetStatusLabel then
            _carpetStatusLabel.Text = carpetSpeedEnabled and "ON" or "OFF"
            _carpetStatusLabel.TextColor3 = carpetSpeedEnabled and Theme.Success or Theme.Error
        end
        ShowNotification("CARPET SPEED", carpetSpeedEnabled and ("ON  |  "..Config.TpSettings.Tool.."  |  120") or "OFF")
    end

    if input.KeyCode == stealSpeedKey then
        if SharedState.StealSpeedToggleFunc then SharedState.StealSpeedToggleFunc() end
    end

    if input.KeyCode == resetKey then executeReset() end
    
    if input.KeyCode == ragdollKey then
        task.spawn(function()
            if _G.runAdminCommand then
                if _G.runAdminCommand(LocalPlayer, "ragdoll") then
                    ShowNotification("RAGDOLL SELF", "Triggered")
                else
                    ShowNotification("RAGDOLL SELF", "Failed")
                end
            else
                ShowNotification("RAGDOLL SELF", "Function not available")
            end
        end)
    end

end)

settingsGui = UI.settingsGui

settingsGui = Instance.new("ScreenGui")
settingsGui.Name = "SettingsUI"; settingsGui.ResetOnSpawn = false
settingsGui.Parent = PlayerGui; settingsGui.Enabled = false

local sFrame = Instance.new("Frame")
sFrame.Size = UDim2.new(0, 300, 0, 650)
sFrame.Position = UDim2.new(Config.Positions.Settings.X, 0, Config.Positions.Settings.Y, 0)
sFrame.BackgroundColor3 = Theme.Background; sFrame.BackgroundTransparency = 0.29
sFrame.BorderSizePixel = 0; sFrame.ClipsDescendants = true; sFrame.Parent = settingsGui

Instance.new("UICorner", sFrame).CornerRadius = UDim.new(0, 12)
local sStroke = Instance.new("UIStroke", sFrame)
sStroke.Color = Theme.Accent2; sStroke.Thickness = 1.5; sStroke.Transparency = 0.4
CreateGradient(sStroke)
task.defer(function() if addRacetrackBorder then addRacetrackBorder(sFrame, Theme.Accent1, 4) end end)

local sHeader = Instance.new("Frame", sFrame)
sHeader.Size = UDim2.new(1,0,0,40); sHeader.BackgroundTransparency = 1
MakeDraggable(sHeader, sFrame, "Settings") 
local sTitle = Instance.new("TextLabel", sHeader)
sTitle.Size = UDim2.new(1,-20,1,0); sTitle.Position = UDim2.new(0,15,0,0)
sTitle.BackgroundTransparency = 1; sTitle.Text = "SETTINGS"
sTitle.Font = Enum.Font.GothamBlack; sTitle.TextSize = 16
sTitle.TextColor3 = Theme.TextPrimary; sTitle.TextXAlignment = Enum.TextXAlignment.Left

local sList = Instance.new("ScrollingFrame", sFrame)
sList.Size = UDim2.new(1,-20,1,-50); sList.Position = UDim2.new(0,10,0,45)
sList.BackgroundTransparency = 1; sList.BorderSizePixel = 0
sList.ScrollBarThickness = 0; sList.ScrollBarImageColor3 = Theme.Accent1

local sLayout = Instance.new("UIListLayout", sList)
sLayout.Padding = UDim.new(0,8); sLayout.SortOrder = Enum.SortOrder.LayoutOrder

local function CreateToggleSwitch(parent, initialState, callback)
    local sw = Instance.new("Frame")
    sw.Size = UDim2.new(0,40,0,20); sw.Position = UDim2.new(1,-50,0.5,-10)
    sw.BackgroundColor3 = initialState and Theme.Success or Theme.SurfaceHighlight
    Instance.new("UICorner", sw).CornerRadius = UDim.new(1,0); sw.Parent = parent
    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0,16,0,16)
    dot.Position = initialState and UDim2.new(1,-18,0.5,-8) or UDim2.new(0,2,0.5,-8)
    dot.BackgroundColor3 = Color3.fromRGB(255,255,255)
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1,0); dot.Parent = sw
    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(1,0,1,0)
    btn.BackgroundTransparency = 1; btn.Text = ""; btn.Parent = sw
    local isOn = initialState
    local function SetState(s)
        isOn = s
        local tp = isOn and UDim2.new(1,-18,0.5,-8) or UDim2.new(0,2,0.5,-8)
        local tc = isOn and Theme.Success or Theme.SurfaceHighlight
        TweenService:Create(dot, TweenInfo.new(0.2,Enum.EasingStyle.Quad,Enum.EasingDirection.Out), {Position=tp}):Play()
        TweenService:Create(sw,  TweenInfo.new(0.2,Enum.EasingStyle.Quad,Enum.EasingDirection.Out), {BackgroundColor3=tc}):Play()
    end
    btn.MouseButton1Click:Connect(function() callback(not isOn, SetState) end)
    return {Set=SetState, Container=sw}
end

local function CreateRow(text, height)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1,0,0,height or 34); row.BackgroundColor3 = Theme.Surface
    Instance.new("UICorner", row).CornerRadius = UDim.new(0,6)
    local lbl = Instance.new("TextLabel", row)
    lbl.Size = UDim2.new(0.6,0,1,0); lbl.Position = UDim2.new(0,10,0,0)
    lbl.BackgroundTransparency = 1; lbl.Text = text
    lbl.Font = Enum.Font.GothamMedium; lbl.TextColor3 = Theme.TextPrimary
    lbl.TextSize = 12; lbl.TextXAlignment = Enum.TextXAlignment.Left
    row.Parent = sList; return row
end

local function CreateSectionHeader(text)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 28)
    row.BackgroundTransparency = 1
    row.Parent = sList
    
    local accent = Instance.new("Frame", row)
    accent.Size = UDim2.new(0, 3, 0, 16)
    accent.Position = UDim2.new(0, 4, 0.5, -8)
    accent.BackgroundColor3 = Theme.Accent1
    accent.BorderSizePixel = 0
    Instance.new("UICorner", accent).CornerRadius = UDim.new(0, 2)
    
    local lbl = Instance.new("TextLabel", row)
    lbl.Size = UDim2.new(1, -20, 1, 0)
    lbl.Position = UDim2.new(0, 14, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.TextColor3 = Theme.Accent1
    lbl.TextSize = 11
    lbl.Font = Enum.Font.GothamBlack
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    
    local line = Instance.new("Frame", row)
    line.Size = UDim2.new(1, -80, 0, 1)
    line.Position = UDim2.new(0, 75, 0.5, 0)
    line.BackgroundColor3 = Theme.Accent1
    line.BackgroundTransparency = 0.7
    line.BorderSizePixel = 0
    
    return row
end

CreateRow("Auto TP on Script Load")
CreateToggleSwitch(sList:FindFirstChildOfClass("Frame"), Config.TpSettings.TpOnLoad, function(ns, set)
    set(ns); Config.TpSettings.TpOnLoad = ns; SaveConfig()
    ShowNotification("AUTO TP ON LOAD", ns and "ENABLED" or "DISABLED")
end)

local rMinGen = CreateRow("Min Gen for Auto TP")
local minGenBox = Instance.new("TextBox", rMinGen)
minGenBox.Size = UDim2.new(0, 100, 0, 24)
minGenBox.Position = UDim2.new(1, -110, 0.5, -12)
minGenBox.BackgroundColor3 = Theme.SurfaceHighlight
minGenBox.Text = tostring(Config.TpSettings.MinGenForTp or "")
minGenBox.Font = Enum.Font.Gotham
minGenBox.TextSize = 11
minGenBox.TextColor3 = Theme.TextPrimary
minGenBox.PlaceholderText = "e.g. 5k, 1m, 1b"
Instance.new("UICorner", minGenBox).CornerRadius = UDim.new(0, 4)
minGenBox.FocusLost:Connect(function()
    local raw = minGenBox.Text:gsub("%s", "")
    Config.TpSettings.MinGenForTp = (raw == "" and "" or raw)
    SaveConfig()
    ShowNotification("MIN GEN FOR TP", Config.TpSettings.MinGenForTp == "" and "No minimum" or "Min: " .. (Config.TpSettings.MinGenForTp or ""))
end)

local rFPS = CreateRow("FPS Boost")
CreateToggleSwitch(rFPS, Config.FPSBoost, function(ns, set)
    set(ns); setFPSBoost(ns)
    ShowNotification("FPS BOOST", ns and "ENABLED" or "DISABLED")
end)

local rTrace = CreateRow("Tracer Best Brainrot")
CreateToggleSwitch(rTrace, Config.TracerEnabled, function(ns, set)
    set(ns); Config.TracerEnabled = ns; SaveConfig()
    ShowNotification("TRACER", ns and "ENABLED" or "DISABLED")
end)

local rLineToBase = CreateRow("Line to base")
CreateToggleSwitch(rLineToBase, Config.LineToBase, function(ns, set)
    set(ns); Config.LineToBase = ns; SaveConfig()
    if not ns and _G.resetPlotBeam then pcall(_G.resetPlotBeam) end
    ShowNotification("LINE TO BASE", ns and "ENABLED" or "DISABLED")
end)

local rXray = CreateRow("X-Ray")
CreateToggleSwitch(rXray, Config.XrayEnabled, function(ns, set)
    set(ns); Config.XrayEnabled = ns; if ns then enableXray() else disableXray() end; SaveConfig()
    ShowNotification("X-RAY", ns and "ENABLED" or "DISABLED")
end)

CreateSectionHeader("Auto TP")
local toolOptions = {"Flying Carpet", "Cupid's Wings", "Santa's Sleigh", "Witch's Broom"}
local toolSwitches = {}
for _, toolName in ipairs(toolOptions) do
    local r = CreateRow(toolName)
    local ts = CreateToggleSwitch(r, Config.TpSettings.Tool==toolName, function(rs, set)
        if rs then
            Config.TpSettings.Tool=toolName; SaveConfig(); set(true)
            for n, sw in pairs(toolSwitches) do if n~=toolName then sw.Set(false) end end
            ShowNotification("TP TOOL", toolName)
        else
            set(Config.TpSettings.Tool==toolName)
        end
    end)
    toolSwitches[toolName] = ts
end

local function makeSlider(label, minVal, maxVal, step, initVal, fmt, onChange)
    local row = CreateRow(label)
    local valLbl = Instance.new("TextLabel", row)
    valLbl.Size=UDim2.new(0,42,0,20); valLbl.Position=UDim2.new(1,-46,0.5,-10)
    valLbl.BackgroundTransparency=1; valLbl.Font=Enum.Font.GothamBold; valLbl.TextSize=12
    valLbl.TextColor3=Theme.TextPrimary; valLbl.TextXAlignment=Enum.TextXAlignment.Right
    local bg=Instance.new("Frame",row); bg.Size=UDim2.new(0,100,0,5); bg.Position=UDim2.new(1,-152,0.5,-2.5)
    bg.BackgroundColor3=Color3.fromRGB(30,32,38); bg.BorderSizePixel=0
    Instance.new("UICorner",bg).CornerRadius=UDim.new(1,0)
    local fill=Instance.new("Frame",bg); fill.BackgroundColor3=Theme.Accent1
    fill.Size=UDim2.new(0,0,1,0); fill.BorderSizePixel=0
    Instance.new("UICorner",fill).CornerRadius=UDim.new(1,0)
    local knob=Instance.new("Frame",bg); knob.Size=UDim2.new(0,12,0,12)
    knob.BackgroundColor3=Theme.TextPrimary; knob.AnchorPoint=Vector2.new(0.5,0.5)
    knob.Position=UDim2.new(0,0,0.5,0); knob.BorderSizePixel=0
    Instance.new("UICorner",knob).CornerRadius=UDim.new(1,0)
    local function update(v)
        v=math.floor(v/step+0.5)*step; v=math.clamp(v,minVal,maxVal)
        valLbl.Text=string.format(fmt,v)
        local p=(v-minVal)/(maxVal-minVal)
        fill.Size=UDim2.new(p,0,1,0); knob.Position=UDim2.new(p,0,0.5,0)
        onChange(v)
    end
    update(initVal)
    local drag=false
    bg.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=true end end)
    UserInputService.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=false end end)
    UserInputService.InputChanged:Connect(function(i)
        if drag and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then
            local bsz = bg.AbsoluteSize.X
            if bsz > 0 then
                local p = math.clamp((i.Position.X-bg.AbsolutePosition.X)/bsz, 0, 1)
                update(minVal+p*(maxVal-minVal))
            end
        end
    end)
    return {update=update}
end

makeSlider("Cache Wait (s)", 0, 0.5, 0.01, Config.TpSettings.CacheWait or 0, "%.2f",
    function(v) Config.TpSettings.CacheWait=v; SaveConfig() end)

makeSlider("F1 Travel Speed", 50, 300, 5, Config.TpSettings.TpSpeedF1 or 130, "%d",
    function(v) Config.TpSettings.TpSpeedF1=v; SaveConfig() end)

makeSlider("F2 Travel Speed", 50, 300, 5, Config.TpSettings.TpSpeedF2 or 130, "%d",
    function(v) Config.TpSettings.TpSpeedF2=v; SaveConfig() end)
local rHitRecov = CreateRow("Hit Recovery")
CreateToggleSwitch(rHitRecov, Config.HitRecovery ~= false, function(ns, set)
    set(ns); Config.HitRecovery = ns; SaveConfig()
    ShowNotification("HIT RECOVERY", ns and "ON" or "OFF")
end)

local function makeKeybind(parent, initVal, configSetter, notifLabel)
    local btn = Instance.new("TextButton", parent)
    btn.Size=UDim2.new(0,60,0,24); btn.Position=UDim2.new(1,-70,0.5,-12)
    btn.BackgroundColor3=Theme.SurfaceHighlight; btn.Text=initVal
    btn.Font=Enum.Font.GothamBold; btn.TextColor3=Theme.TextPrimary; btn.TextSize=12
    Instance.new("UICorner",btn).CornerRadius=UDim.new(0,4)
    btn.MouseButton1Click:Connect(function()
        btn.Text="..."; btn.TextColor3=Theme.Accent1
        local con; con=UserInputService.InputBegan:Connect(function(inp)
            if inp.UserInputType==Enum.UserInputType.Keyboard then
                local k=inp.KeyCode.Name; configSetter(k); btn.Text=k
                btn.TextColor3=Theme.TextPrimary; SaveConfig(); con:Disconnect()
                ShowNotification(notifLabel, k)
            end
        end)
    end)
    return btn
end
local rBind = CreateRow("TP Keybind")
local bBind = makeKeybind(rBind, Config.TpSettings.TpKey, function(k) Config.TpSettings.TpKey=k end, "TP KEYBIND")

local rBindClone = CreateRow("Auto Clone Keybind")
local bBindClone = makeKeybind(rBindClone, Config.TpSettings.CloneKey, function(k) Config.TpSettings.CloneKey=k end, "CLONE KEYBIND")

CreateSectionHeader("CARPET SPEED")
local rCarpetBind = CreateRow("Carpet Speed Keybind")
local bCarpet = makeKeybind(rCarpetBind, Config.TpSettings.CarpetSpeedKey, function(k) Config.TpSettings.CarpetSpeedKey=k end, "CARPET SPEED KEYBIND")

local rRagdollSelf = CreateRow("Ragdoll Self Keybind")
local bRagdollSelf = makeKeybind(rRagdollSelf, Config.RagdollSelfKey ~= "" and Config.RagdollSelfKey or "NONE", function(k) Config.RagdollSelfKey=k end, "RAGDOLL SELF KEYBIND")

local rCarpetStatus = CreateRow("Carpet Speed Status")
local carpetStatusLbl = Instance.new("TextLabel", rCarpetStatus)
carpetStatusLbl.Size=UDim2.new(0,50,0,20); carpetStatusLbl.Position=UDim2.new(1,-60,0.5,-10)
carpetStatusLbl.BackgroundTransparency=1
carpetStatusLbl.Text=carpetSpeedEnabled and "ON" or "OFF"
carpetStatusLbl.TextColor3=carpetSpeedEnabled and Theme.Success or Theme.Error
carpetStatusLbl.Font=Enum.Font.GothamBlack; carpetStatusLbl.TextSize=13
carpetStatusLbl.TextXAlignment=Enum.TextXAlignment.Right
_carpetStatusLabel = carpetStatusLbl

CreateSectionHeader("MOVEMENT")
local rInfJump = CreateRow("Infinite Jump")
CreateToggleSwitch(rInfJump, infiniteJumpEnabled, function(ns, set)
    set(ns); setInfiniteJump(ns)
    ShowNotification("INFINITE JUMP", ns and "ENABLED" or "DISABLED")
end)
local rAutoStealSpeed = CreateRow("Auto Steal Speed")
CreateToggleSwitch(rAutoStealSpeed, Config.AutoStealSpeed, function(ns, set)
    set(ns); Config.AutoStealSpeed = ns; SaveConfig()
    ShowNotification("AUTO STEAL SPEED", ns and "ENABLED" or "DISABLED")
end)

local rStealSpeedKey = CreateRow("Steal Speed Keybind")
local bStealSpeedKey = makeKeybind(rStealSpeedKey, Config.StealSpeedKey, function(k) Config.StealSpeedKey=k end, "STEAL SPEED KEYBIND")

CreateSectionHeader("AUTO UNLOCK")
local rAutoUnlock = CreateRow("Auto Unlock on Steal")
CreateToggleSwitch(rAutoUnlock, Config.AutoUnlockOnSteal, function(ns, set)
    set(ns); Config.AutoUnlockOnSteal = ns; SaveConfig()
    ShowNotification("AUTO UNLOCK", ns and "ENABLED" or "DISABLED")
end)

local rShowUnlockHUD = CreateRow("Show Unlock Buttons HUD")
CreateToggleSwitch(rShowUnlockHUD, Config.ShowUnlockButtonsHUD, function(ns, set)
    set(ns); Config.ShowUnlockButtonsHUD = ns; SaveConfig()
    local hudGui = PlayerGui:FindFirstChild("JustAFanStatusHUD")
    if hudGui then
        local main = hudGui:FindFirstChild("Main")
        local unlockContainer = main and main:FindFirstChild("UnlockButtonsContainer")
        if main and unlockContainer then
            unlockContainer.Visible = ns
            if ns then
                TweenService:Create(main, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                    Size = UDim2.new(0, 500, 0, 100)
                }):Play()
            else
                TweenService:Create(main, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                    Size = UDim2.new(0, 500, 0, 50)
                }):Play()
            end
        end
    end
end)
CreateSectionHeader("ANTI-RAGDOLL")
local arV1SetRef, arV2SetRef = {}, {}
local rAr = CreateRow("V1")
CreateToggleSwitch(rAr, Config.AntiRagdoll > 0, function(ns, set)
    arV1SetRef.fn = set
    if ns and Config.AntiRagdollV2 then
        set(false)
        ShowNotification("ANTI-RAGDOLL", "DISABLE V2 FIRST")
        return
    end
    set(ns)
    local mode = ns and 1 or 0
    Config.AntiRagdoll = mode
    if ns then
        Config.AntiRagdollV2 = false
        if arV2SetRef.fn then arV2SetRef.fn(false) end
    end
    SaveConfig()
    startAntiRagdoll(mode)
    if ns then startAntiRagdollV2(false) end
    ShowNotification("ANTI-RAGDOLL V1", ns and "ENABLED" or "DISABLED")
end)
local rArV2 = CreateRow("V2")
CreateToggleSwitch(rArV2, Config.AntiRagdollV2, function(ns, set)
    arV2SetRef.fn = set
    if ns and Config.AntiRagdoll > 0 then
        set(false)
        ShowNotification("ANTI-RAGDOLL", "DISABLE V1 FIRST")
        return
    end
    set(ns)
    Config.AntiRagdollV2 = ns
    if ns then
        Config.AntiRagdoll = 0
        SaveConfig()
        if arV1SetRef.fn then arV1SetRef.fn(false) end
        startAntiRagdoll(0)
        startAntiRagdollV2(true)
    else
        SaveConfig()
        startAntiRagdollV2(false)
    end
    ShowNotification("ANTI-RAGDOLL V2", ns and "ENABLED" or "DISABLED")
end)

CreateSectionHeader("ESP")

local rXray = CreateRow("Base X-Ray")
local xrayToggle = CreateToggleSwitch(rXray, xrayEnabled, function(ns, set)
    set(ns)
    if ns then
        enableXray()
        xrayDescConn = Workspace.DescendantAdded:Connect(function(obj)
            if xrayEnabled and obj:IsA("BasePart") and obj.Anchored and isBaseWall(obj) then
                originalTransparency[obj] = obj.LocalTransparencyModifier
                obj.LocalTransparencyModifier = 0.85
            end
        end)
    else
        disableXray()
    end
    Config.XrayEnabled = ns; SaveConfig()
    ShowNotification("BASE X-RAY", ns and "ENABLED" or "DISABLED")
end)
playerESPToggleRef = {setFn=nil}
local rPlayerEsp = CreateRow("Player ESP (Hides Names)")
CreateToggleSwitch(rPlayerEsp, Config.PlayerESP, function(ns, set)
    set(ns); Config.PlayerESP = ns; SaveConfig()
    if playerESPToggleRef.setFn then playerESPToggleRef.setFn(ns) end
    ShowNotification("PLAYER ESP", ns and "ENABLED" or "DISABLED")
end)

espToggleRef = {enabled=true, setFn=nil}
local rEsp = CreateRow("Brainrot ESP")
local espSettingsSwitch = CreateToggleSwitch(rEsp, Config.BrainrotESP, function(ns, set)
    set(ns); Config.BrainrotESP = ns; SaveConfig()
    if espToggleRef.setFn then espToggleRef.setFn(ns) end
    ShowNotification("BRAINROT ESP", ns and "ENABLED" or "DISABLED")
end)
local subspaceMineESPToggleRef = {setFn=nil}
local rSubspaceMineEsp = CreateRow("Subspace Mine Esp")
CreateToggleSwitch(rSubspaceMineEsp, Config.SubspaceMineESP, function(ns, set)
    set(ns); Config.SubspaceMineESP = ns; SaveConfig()
    if subspaceMineESPToggleRef.setFn then subspaceMineESPToggleRef.setFn(ns) end
    ShowNotification("SUBSPACE MINE ESP", ns and "ENABLED" or "DISABLED")
end)
CreateSectionHeader("AUTO STEAL DEFAULTS")
local nearestToggleRef = {}
local highestToggleRef = {}
local priorityToggleRef = {}
local autoTPPriorityToggleRef = {setFn = nil}

local rDefaultNearest = CreateRow("Default To Nearest")
local nearestToggleSwitch = CreateToggleSwitch(rDefaultNearest, Config.DefaultToNearest, function(ns, set)
    if ns then
        Config.DefaultToNearest = true
        Config.DefaultToHighest = false
        Config.DefaultToPriority = false
        set(true)
        if highestToggleRef.setFn then highestToggleRef.setFn(false) end
        if priorityToggleRef.setFn then priorityToggleRef.setFn(false) end
        
        Config.AutoTPPriority = true
        if autoTPPriorityToggleRef and autoTPPriorityToggleRef.setFn then autoTPPriorityToggleRef.setFn(true) end
    else
        local otherDefaults = Config.DefaultToHighest or Config.DefaultToPriority
        if not otherDefaults then
            set(true)
            ShowNotification("DEFAULT MODE", "At least one default must be enabled")
            return
        end
        Config.DefaultToNearest = false
        set(false)
    end
    SaveConfig()
    ShowNotification("DEFAULT TO NEAREST", ns and "ENABLED" or "DISABLED")
end)
nearestToggleRef.setFn = nearestToggleSwitch.Set

local rDefaultHighest = CreateRow("Default To Highest")
local highestToggleSwitch = CreateToggleSwitch(rDefaultHighest, Config.DefaultToHighest, function(ns, set)
    if ns then
        Config.DefaultToNearest = false
        Config.DefaultToHighest = true
        Config.DefaultToPriority = false
        set(true)
        if nearestToggleRef.setFn then nearestToggleRef.setFn(false) end
        if priorityToggleRef.setFn then priorityToggleRef.setFn(false) end
        
        Config.AutoTPPriority = false
        if autoTPPriorityToggleRef and autoTPPriorityToggleRef.setFn then autoTPPriorityToggleRef.setFn(false) end
    else
        local otherDefaults = Config.DefaultToNearest or Config.DefaultToPriority
        if not otherDefaults then
            set(true)
            ShowNotification("DEFAULT MODE", "At least one default must be enabled")
            return
        end
        Config.DefaultToHighest = false
        set(false)
    end
    SaveConfig()
    ShowNotification("DEFAULT TO HIGHEST", ns and "ENABLED" or "DISABLED")
end)
highestToggleRef.setFn = highestToggleSwitch.Set

local rDefaultPriority = CreateRow("Default To Priority")
local priorityToggleSwitch = CreateToggleSwitch(rDefaultPriority, Config.DefaultToPriority, function(ns, set)
    if ns then
        Config.DefaultToNearest = false
        Config.DefaultToHighest = false
        Config.DefaultToPriority = true
        set(true)
        if nearestToggleRef.setFn then nearestToggleRef.setFn(false) end
        if highestToggleRef.setFn then highestToggleRef.setFn(false) end
        
        Config.AutoTPPriority = true
        if autoTPPriorityToggleRef and autoTPPriorityToggleRef.setFn then autoTPPriorityToggleRef.setFn(true) end
    else
        local otherDefaults = Config.DefaultToNearest or Config.DefaultToHighest
        if not otherDefaults then
            set(true)
            ShowNotification("DEFAULT MODE", "At least one default must be enabled")
            return
        end
        Config.DefaultToPriority = false
        set(false)
    end
    SaveConfig()
    ShowNotification("DEFAULT TO PRIORITY", ns and "ENABLED" or "DISABLED")
end)
priorityToggleRef.setFn = priorityToggleSwitch.Set

CreateSectionHeader("AUTOMATION")
local rAutoInvis = CreateRow("Auto Invis During Steal")
CreateToggleSwitch(rAutoInvis, Config.AutoInvisDuringSteal, function(ns, set)
    set(ns); Config.AutoInvisDuringSteal = ns; _G.AutoInvisDuringSteal = ns; SaveConfig()
    ShowNotification("AUTO INVIS", ns and "ENABLED" or "DISABLED")
end)

local rAutoTpPriority = CreateRow("Auto TP Priority Mode")
CreateToggleSwitch(rAutoTpPriority, Config.AutoTPPriority ~= false, function(ns, set)
    set(ns); Config.AutoTPPriority = ns; SaveConfig()
    ShowNotification("AUTO TP PRIORITY", ns and "PRIORITY" or "HIGHEST GEN")
end)
local rAutoKick = CreateRow("Auto-Kick on Steal")
CreateToggleSwitch(rAutoKick, Config.AutoKickOnSteal, function(ns, set)
    set(ns); Config.AutoKickOnSteal = ns; SaveConfig()
    ShowNotification("AUTO-KICK ON STEAL", ns and "ENABLED" or "DISABLED")
end)

CreateSectionHeader("HIDE GUIS")
local rHideAdminPanel = CreateRow("Hide Admin Panel GUI")
CreateToggleSwitch(rHideAdminPanel, Config.HideAdminPanel, function(ns, set)
    set(ns); Config.HideAdminPanel = ns; SaveConfig()
    local adUI = PlayerGui:FindFirstChild("XiAdminPanel")
    if adUI then adUI.Enabled = not ns end
    ShowNotification("HIDE ADMIN PANEL", ns and "ENABLED" or "DISABLED")
end)
local rHideAdminToolsPanel = CreateRow("Hide Admin Tools Panel GUI")
CreateToggleSwitch(rHideAdminToolsPanel, Config.ShowAdminToolsPanel == false, function(ns, set)
    set(ns); Config.ShowAdminToolsPanel = not ns; SaveConfig()
    local toolsGui = PlayerGui:FindFirstChild("XiAdminToolsPanel")
    if toolsGui then toolsGui.Enabled = not ns end
    if SharedState.AdminToolsSetEnabled then pcall(SharedState.AdminToolsSetEnabled, not ns) end
    if ns then
        Config.ClickToAP = false; ProximityAPActive = false; ProximityAPActive = false; SaveConfig()
        if SharedState.UpdateClickToAPButton then SharedState.UpdateClickToAPButton() end
        if SharedState.UpdateProximityAPButton then SharedState.UpdateProximityAPButton() end
    end
    ShowNotification("HIDE ADMIN TOOLS", ns and "ENABLED" or "DISABLED")
end)
local rHideAutoSteal = CreateRow("Hide Auto Steal GUI")
CreateToggleSwitch(rHideAutoSteal, Config.HideAutoSteal, function(ns, set)
    set(ns); Config.HideAutoSteal = ns; SaveConfig()
    local asUI = PlayerGui:FindFirstChild("AutoStealUI")
    if asUI then asUI.Enabled = not ns end
    ShowNotification("HIDE AUTO STEAL", ns and "ENABLED" or "DISABLED")
end)
CreateSectionHeader("EXTRAS")   

local rResetKey = CreateRow("Reset")
local bResetKey = makeKeybind(rResetKey, Config.ResetKey, function(k) Config.ResetKey=k end, "RESET KEYBIND")

local rKickKey = CreateRow("Kick")
local bKickKey = makeKeybind(rKickKey, Config.KickKey ~= "" and Config.KickKey or "NONE", function(k) Config.KickKey=k end, "KICK KEYBIND")

local rCleanErrors = CreateRow("Clean Error GUIs")
CreateToggleSwitch(rCleanErrors, Config.CleanErrorGUIs, function(ns, set)
    set(ns); Config.CleanErrorGUIs = ns; SaveConfig()
    ShowNotification("CLEAN ERROR GUIS", ns and "ENABLED" or "DISABLED")
end)

CreateSectionHeader("ADMIN PANEL")
local rClickToAP = CreateRow("Click To Admin Panel")
CreateToggleSwitch(rClickToAP, Config.ClickToAP, function(ns, set)
    set(ns); Config.ClickToAP = ns; SaveConfig()
    ShowNotification("CLICK TO AP", ns and "ENABLED" or "DISABLED")
end)
local rClickToAPSingle = CreateRow("Click To AP Single Command")
CreateToggleSwitch(rClickToAPSingle, Config.ClickToAPSingleCommand, function(ns, set)
    set(ns); Config.ClickToAPSingleCommand = ns; SaveConfig()
    ShowNotification("CLICK TO AP SINGLE", ns and "ENABLED" or "DISABLED")
end)
local rClickToAPKeybind = CreateRow("Click To AP Keybind")
local bClickToAPKeybind = makeKeybind(rClickToAPKeybind, Config.ClickToAPKeybind or "L", function(k) Config.ClickToAPKeybind=k end, "CLICK TO AP KEYBIND")
local rProximityAPKeybind = CreateRow("Proximity AP Keybind")
local bProximityAPKeybind = makeKeybind(rProximityAPKeybind, Config.ProximityAPKeybind or "P", function(k) Config.ProximityAPKeybind=k end, "PROXIMITY AP KEYBIND")

CreateSectionHeader("AUTO-STEAL")
local rStealEnabled = CreateRow("Auto Steal")
CreateToggleSwitch(rStealEnabled, Config.AutoSteal ~= false, function(ns, set)
    set(ns); Config.AutoSteal = ns; SaveConfig()
    ShowNotification("AUTO STEAL", ns and "ON" or "OFF")
end)
local rUsePriority = CreateRow("Use Priority List")
CreateToggleSwitch(rUsePriority, Config.UsePriority ~= false, function(ns, set)
    set(ns); Config.UsePriority = ns; SaveConfig()
    ShowNotification("USE PRIORITY", ns and "ON" or "OFF")
end)
local rStealRadius = CreateRow("Steal Radius")
local srSliderBg = Instance.new("Frame", rStealRadius)
srSliderBg.Size = UDim2.new(0,120,0,5); srSliderBg.Position = UDim2.new(1,-175,0.5,-2.5)
srSliderBg.BackgroundColor3 = Color3.fromRGB(30,32,38)
Instance.new("UICorner", srSliderBg).CornerRadius = UDim.new(1,0)
local srFill = Instance.new("Frame", srSliderBg); srFill.BackgroundColor3 = Theme.Accent1
srFill.Size = UDim2.new(0,0,1,0); Instance.new("UICorner", srFill).CornerRadius = UDim.new(1,0)
local srKnob = Instance.new("Frame", srSliderBg); srKnob.Size = UDim2.new(0,12,0,12)
srKnob.BackgroundColor3 = Theme.TextPrimary; srKnob.AnchorPoint = Vector2.new(0.5,0.5)
srKnob.Position = UDim2.new(0,0,0.5,0); Instance.new("UICorner", srKnob).CornerRadius = UDim.new(1,0)
local srValLbl = Instance.new("TextLabel", rStealRadius)
srValLbl.Size = UDim2.new(0,45,0,20); srValLbl.Position = UDim2.new(1,-48,0.5,-10)
srValLbl.BackgroundTransparency = 1; srValLbl.Font = Enum.Font.GothamBold
srValLbl.TextSize = 12; srValLbl.TextColor3 = Theme.TextPrimary
local function updateSrSlider(v)
    v = math.clamp(math.floor(v+0.5), 10, 150)
    Config.StealRadius = v; SaveConfig()
    srValLbl.Text = tostring(v)
    local p = (v-10)/140; srFill.Size = UDim2.new(p,0,1,0); srKnob.Position = UDim2.new(p,0,0.5,0)
end
updateSrSlider(Config.StealRadius or 60)
local srDrag = false
srSliderBg.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then srDrag=true end end)
UserInputService.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then srDrag=false end end)
UserInputService.InputChanged:Connect(function(i)
    if srDrag and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then
        local p=(i.Position.X-srSliderBg.AbsolutePosition.X)/srSliderBg.AbsoluteSize.X
        updateSrSlider(10+p*140)
    end
end)

local rTpMode = CreateRow("TP Mode")
local tpModeBtn = Instance.new("TextButton", rTpMode)
tpModeBtn.Size = UDim2.new(0,70,0,24); tpModeBtn.Position = UDim2.new(1,-75,0.5,-12)
tpModeBtn.BackgroundColor3 = Theme.SurfaceHighlight
tpModeBtn.Text = (Config.TpMode or "front"):upper()
tpModeBtn.Font = Enum.Font.GothamBold; tpModeBtn.TextSize = 12
tpModeBtn.TextColor3 = Theme.Accent1; tpModeBtn.BorderSizePixel = 0
Instance.new("UICorner", tpModeBtn).CornerRadius = UDim.new(0,4)
tpModeBtn.MouseButton1Click:Connect(function()
    Config.TpMode = Config.TpMode == "front" and "side" or "front"
    tpModeBtn.Text = Config.TpMode:upper()
    tpMode = Config.TpMode
    SaveConfig()
    ShowNotification("TP MODE", Config.TpMode:upper())
end)

CreateSectionHeader("ALERTS")
local rAlertsEnabled = CreateRow("Enable Alerts")
CreateToggleSwitch(rAlertsEnabled, Config.AlertsEnabled, function(ns, set)
    set(ns); Config.AlertsEnabled = ns; SaveConfig()
    ShowNotification("PRIORITY ALERTS", ns and "ENABLED" or "DISABLED")
end)
local rAlertSound = CreateRow("Alert Sound ID")
local soundBox = Instance.new("TextBox", rAlertSound)
soundBox.Size = UDim2.new(0, 180, 0, 24)
soundBox.Position = UDim2.new(1, -185, 0.5, -12)
soundBox.BackgroundColor3 = Theme.SurfaceHighlight
soundBox.Text = Config.AlertSoundID or "rbxassetid://6518811702"
soundBox.Font = Enum.Font.Gotham
soundBox.TextSize = 10
soundBox.TextColor3 = Theme.TextPrimary
soundBox.PlaceholderText = "Sound ID"
Instance.new("UICorner", soundBox).CornerRadius = UDim.new(0, 4)
soundBox.FocusLost:Connect(function()
    Config.AlertSoundID = soundBox.Text
    SaveConfig()
    ShowNotification("ALERT SOUND", "Updated")
end)

CreateSectionHeader("JOB JOINER")
local rJoinerRow = CreateRow("Job ID Joiner")
CreateToggleSwitch(rJoinerRow, Config.ShowJobJoiner, function(ns, set)
    set(ns); Config.ShowJobJoiner = ns; SaveConfig()
    local gui = PlayerGui:FindFirstChild("JustAFanJobJoiner")
    if gui then gui.Enabled = Config.ShowJobJoiner end
    ShowNotification("JOB ID JOINER", ns and "ENABLED" or "DISABLED")
end)
local rJoinerKey = CreateRow("Job Joiner Keybind")
local bJoinerKey = makeKeybind(rJoinerKey, Config.JobJoinerKey or "J", function(k) Config.JobJoinerKey=k end, "JOB JOINER KEYBIND")

CreateSectionHeader("PROTECTION")
local rAntiBeeDisco = CreateRow("Anti-Bee & Anti-Disco")
CreateToggleSwitch(rAntiBeeDisco, Config.AntiBeeDisco, function(ns, set)
    set(ns); Config.AntiBeeDisco = ns; SaveConfig()
    if ns then
        if _G.ANTI_BEE_DISCO and _G.ANTI_BEE_DISCO.Enable then _G.ANTI_BEE_DISCO.Enable() end
    else
        if _G.ANTI_BEE_DISCO and _G.ANTI_BEE_DISCO.Disable then _G.ANTI_BEE_DISCO.Disable() end
    end
    ShowNotification("ANTI-BEE & DISCO", ns and "ENABLED" or "DISABLED")
end)

CreateSectionHeader("CAMERA")
local rFOV = CreateRow("FOV")
local fovSliderBg = Instance.new("Frame", rFOV)
fovSliderBg.Size = UDim2.new(0, 140, 0, 5)
fovSliderBg.Position = UDim2.new(1, -200, 0.5, -2.5)
fovSliderBg.BackgroundColor3 = Color3.fromRGB(30, 32, 38)
Instance.new("UICorner", fovSliderBg).CornerRadius = UDim.new(1, 0)
local fovFill = Instance.new("Frame", fovSliderBg)
fovFill.BackgroundColor3 = Theme.Accent1
fovFill.Size = UDim2.new(0, 0, 1, 0)
Instance.new("UICorner", fovFill).CornerRadius = UDim.new(1, 0)
local fovKnob = Instance.new("Frame", fovSliderBg)
fovKnob.Size = UDim2.new(0, 12, 0, 12)
fovKnob.BackgroundColor3 = Theme.TextPrimary
fovKnob.AnchorPoint = Vector2.new(0.5, 0.5)
fovKnob.Position = UDim2.new(0, 0, 0.5, 0)
Instance.new("UICorner", fovKnob).CornerRadius = UDim.new(1, 0)
local fovKnobStroke = Instance.new("UIStroke", fovKnob)
fovKnobStroke.Color = Theme.Accent1
fovKnobStroke.Thickness = 1.5
fovKnobStroke.Transparency = 0.2
local fovValLbl = Instance.new("TextLabel", rFOV)
fovValLbl.Size = UDim2.new(0, 40, 0, 20)
fovValLbl.Position = UDim2.new(1, -50, 0.5, -10)
fovValLbl.BackgroundTransparency = 1
fovValLbl.Text = string.format("%.1f", Config.FOV)
fovValLbl.TextColor3 = Theme.TextPrimary
fovValLbl.Font = Enum.Font.GothamBold
fovValLbl.TextSize = 13

local function updateFOVSlider(val)
    val = math.clamp(val, 30, 180)
    Config.FOV = val
    SaveConfig()
    fovValLbl.Text = string.format("%.1f", val)
    local pct = (val - 30) / 150
    fovFill.Size = UDim2.new(pct, 0, 1, 0)
    fovKnob.Position = UDim2.new(pct, 0, 0.5, 0)
    if Workspace.CurrentCamera then Workspace.CurrentCamera.FieldOfView = val end
    ShowNotification("FIELD OF VIEW", string.format("%.1f", val))
end
updateFOVSlider(Config.FOV)

local fovDragging = false
fovSliderBg.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then fovDragging = true end
end)
UserInputService.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then fovDragging = false end
end)
UserInputService.InputChanged:Connect(function(i)
    if fovDragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
        local x = i.Position.X
        local r = fovSliderBg.AbsolutePosition.X
        local w = fovSliderBg.AbsoluteSize.X
        local p = (x - r) / w
        updateFOVSlider(30 + (p * 150))
    end
end)

CreateSectionHeader("MENU")
    local rMenu = CreateRow("Menu Toggle Key")
    local bMenu = Instance.new("TextButton", rMenu)
    bMenu.Size=UDim2.new(0,80,0,24); bMenu.Position=UDim2.new(1,-90,0.5,-12)
    bMenu.BackgroundColor3=Theme.SurfaceHighlight; bMenu.Text=Config.MenuKey
    bMenu.Font=Enum.Font.GothamBold; bMenu.TextColor3=Theme.TextPrimary; bMenu.TextSize=12
    Instance.new("UICorner",bMenu).CornerRadius=UDim.new(0,4)
    bMenu.MouseButton1Click:Connect(function()
        bMenu.Text="..."; bMenu.TextColor3=Theme.Accent1
        local con; con=UserInputService.InputBegan:Connect(function(inp)
            if inp.UserInputType==Enum.UserInputType.Keyboard then
                Config.MenuKey=inp.KeyCode.Name; bMenu.Text=inp.KeyCode.Name
                bMenu.TextColor3=Theme.TextPrimary; SaveConfig(); con:Disconnect()
                ShowNotification("MENU KEYBIND", inp.KeyCode.Name)
            end
        end)
    end)

CreateSectionHeader("UI CONTROLS")
local rLock = CreateRow("Lock UI Dragging")
CreateToggleSwitch(rLock, Config.UILocked, function(ns, set)
    set(ns); Config.UILocked = ns; SaveConfig()
    ShowNotification("UI LOCK", ns and "ENABLED" or "DISABLED")
end)

local rReset = CreateRow("Reset UI Positions")
local bReset = Instance.new("TextButton", rReset)
bReset.Size=UDim2.new(0,80,0,24); bReset.Position=UDim2.new(1,-90,0.5,-12)
bReset.BackgroundColor3=Theme.Error; bReset.Text="RESET"
bReset.Font=Enum.Font.GothamBold; bReset.TextColor3=Theme.TextPrimary; bReset.TextSize=12
Instance.new("UICorner",bReset).CornerRadius=UDim.new(0,4)
bReset.MouseButton1Click:Connect(function()
    Config.Positions = DefaultConfig.Positions
    SaveConfig()
    ShowNotification("UI RESET", "Positions restored")
    sFrame.Position = UDim2.new(DefaultConfig.Positions.Settings.X, 0, DefaultConfig.Positions.Settings.Y, 0)
    if PlayerGui:FindFirstChild("AutoStealUI") then
        PlayerGui.AutoStealUI.Frame.Position = UDim2.new(DefaultConfig.Positions.AutoSteal.X, 0, DefaultConfig.Positions.AutoSteal.Y, 0)
    end
    if PlayerGui:FindFirstChild("XiAdminPanel") and PlayerGui.XiAdminPanel:FindFirstChild("Frame") then
        PlayerGui.XiAdminPanel.Frame.Position = UDim2.new(DefaultConfig.Positions.AdminPanel.X, 0, DefaultConfig.Positions.AdminPanel.Y, 0)
    end
    if PlayerGui:FindFirstChild("XiAdminToolsPanel") and PlayerGui.XiAdminToolsPanel:FindFirstChild("Frame") then
        PlayerGui.XiAdminToolsPanel.Frame.Position = UDim2.new(DefaultConfig.Positions.AdminToolsPanel.X, 0, DefaultConfig.Positions.AdminToolsPanel.Y, 0)
    end
    ShowNotification("UI RESET", "Positions restored to default")
end)

local function updateSettingsCanvasSize()
    local contentHeight = sLayout.AbsoluteContentSize.Y
    sList.CanvasSize = UDim2.new(0, 0, 0, math.max(contentHeight + 20, sList.AbsoluteSize.Y))
end

sLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateSettingsCanvasSize)
task.defer(updateSettingsCanvasSize)

    sList.ScrollBarThickness = 0
    sList.ScrollingEnabled = true
    sList.ElasticBehavior = Enum.ElasticBehavior.Always

    UserInputService.InputBegan:Connect(function(input, gp)
        if input.KeyCode == safeKeyCode(Config.MenuKey, Enum.KeyCode.LeftControl) then
            if _G.JustAFanSettingsUI and _G.JustAFanSettingsUI.panel then
                _G.JustAFanSettingsUI.panel.Visible = not _G.JustAFanSettingsUI.panel.Visible
            else
                settingsGui.Enabled = not settingsGui.Enabled
            end
        end
        if input.KeyCode == safeKeyCode(Config.KickKey, nil) then kickPlayer() end
        if input.KeyCode == safeKeyCode(Config.RagdollSelfKey, nil) then
            if _G.isOnCooldown and not _G.isOnCooldown("ragdoll") then
                local _rac = _G.runAdminCommand
                if _rac and _rac(LocalPlayer, "ragdoll") then
                    if _G.activeCooldowns then _G.activeCooldowns["ragdoll"] = tick() end
                    if _G.setGlobalVisualCooldown then _G.setGlobalVisualCooldown("ragdoll") end
                    ShowNotification("RAGDOLL SELF", "Ragdolled " .. LocalPlayer.Name)
                end
            else
                ShowNotification("RAGDOLL SELF", "Ragdoll on cooldown")
            end
        end
        if input.KeyCode == safeKeyCode(Config.ProximityAPKeybind, nil) then
            ProximityAPActive = not ProximityAPActive
            if SharedState.ProximityAPButton then updateProximityAPButton() end
            ShowNotification("PROXIMITY AP", ProximityAPActive and "ENABLED" or "DISABLED")
        end
        if input.KeyCode == safeKeyCode(Config.ClickToAPKeybind, Enum.KeyCode.L) then
            Config.ClickToAP = not Config.ClickToAP
            SaveConfig()
            ShowNotification("CLICK TO AP", Config.ClickToAP and "ENABLED" or "DISABLED")
        end
        if input.KeyCode == safeKeyCode(Config.JobJoinerKey, nil) then
            local joinerGui = PlayerGui:FindFirstChild("JustAFanJobJoiner")
            if joinerGui then
                Config.ShowJobJoiner = not Config.ShowJobJoiner
                joinerGui.Enabled = Config.ShowJobJoiner
                SaveConfig()
                ShowNotification("JOB ID JOINER", Config.ShowJobJoiner and "OPENED" or "CLOSED")
            end
        end
    end)

task.spawn(function()
    task.wait(1)
    if Config.HideAdminPanel then
        local adUI = PlayerGui:FindFirstChild("XiAdminPanel")
        if adUI then adUI.Enabled = false end
    end
    if Config.ShowAdminToolsPanel == false then
        local toolsUI = PlayerGui:FindFirstChild("XiAdminToolsPanel")
        if toolsUI then toolsUI.Enabled = false end
    end
    if Config.HideAutoSteal then
        local asUI = PlayerGui:FindFirstChild("AutoStealUI")
        if asUI then asUI.Enabled = false end
    end
    if Config.HideStatusHUD then
        local g = PlayerGui:FindFirstChild("JustAFanStatusHUD")
        if g then g.Enabled = false end
    end
    if Config.HideAutoBuyUI then
        local g = PlayerGui:FindFirstChild("JustAFanAutoBuyUI")
        if g then local p = g:FindFirstChild("ABPanel"); if p then p.Visible = false end end
    end
end)

local function parseMinGen(str)
    if not str or type(str) ~= "string" then return 0 end
    str = str:gsub("%s", ""):lower()
    if str == "" then return 0 end
    local num, suffix = str:match("^([%d%.]+)([kmb]?)$")
    if not num then return 0 end
    num = tonumber(num)
    if not num or num < 0 then return 0 end
    if suffix == "k" then return num * 1e3
    elseif suffix == "m" then return num * 1e6
    elseif suffix == "b" then return num * 1e9
    end
    return num
end

if Config.TpSettings.TpOnLoad then
    task.spawn(function()
        local w = 0
        repeat RunService.Heartbeat:Wait(); w=w+1 until (_G.tpToBestBrainrot or _G.ctpLaunch) or w > 120
        if (Config.TpMethod or "tween") == "clone" then
            local waitStart = tick()
            -- wait for any data first
            repeat task.wait(0.1) until #SharedState.AllAnimalsCache > 0 or tick()-waitStart > 10
            -- wait for scan to stabilize (cache stops growing = full server scanned)
            local lastSize = 0
            local stableCount = 0
            while stableCount < 5 and tick()-waitStart < 15 do
                task.wait(0.05)
                local curSize = #SharedState.AllAnimalsCache
                if curSize == lastSize then
                    stableCount += 1
                else
                    stableCount = 0
                    lastSize = curSize
                end
            end
            pcall(function() if _G.ctpLaunch then _G.ctpLaunch() end end)
        else
            local cw = Config.TpSettings.CacheWait or 0
            task.wait(math.max(cw, 2))
            local waitStart = tick()
            repeat task.wait(0.2) until #SharedState.AllAnimalsCache > 0 or tick()-waitStart > 10
            if _G.tpToBestBrainrot then SharedState.FirstLoadSteal = true; pcall(_G.tpToBestBrainrot) end
        end
    end)
end

LocalPlayer:GetAttributeChangedSignal("Stealing"):Connect(function()
    local isStealing = LocalPlayer:GetAttribute("Stealing")
    local wasStealing = not isStealing 

    if isStealing then
        if Config.AutoInvisDuringSteal and _G.toggleInvisibleSteal and not _G.invisibleStealEnabled then
            _G.toggleInvisibleSteal()
        end
        if Config.AutoUnlockOnSteal then triggerClosestUnlock(nil, 19) end
    elseif wasStealing then
        if Config.AutoInvisDuringSteal and _G.toggleInvisibleSteal and _G.invisibleStealEnabled then
            _G.toggleInvisibleSteal()
        end
    end
end)

task.spawn(function()
    local oldSS = PlayerGui:FindFirstChild("StealSpeedUI")
    if oldSS then oldSS:Destroy() end

    local MIN_SPEED, MAX_SPEED = 5, 30
    local stealSpeedEnabled = false
    local STEAL_SPEED = math.clamp(math.floor((tonumber(Config.StealSpeed) or 20) + 0.5), MIN_SPEED, MAX_SPEED)
    if Config.StealSpeed ~= STEAL_SPEED then
        Config.StealSpeed = STEAL_SPEED
        SaveConfig()
    end
    local stealConn = nil

    local function doDisable()
        stealSpeedEnabled = false
        if stealConn then stealConn:Disconnect(); stealConn = nil end
    end

    local function doEnable()
        stealSpeedEnabled = true
        if stealConn then stealConn:Disconnect(); stealConn = nil end
        stealConn = RunService.Heartbeat:Connect(function()
            local char = LocalPlayer.Character
            if not char then return end
            local hum = char:FindFirstChildOfClass("Humanoid")
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if not hum or not hrp then return end
            local md = hum.MoveDirection
            if md.Magnitude > 0 then
                hrp.AssemblyLinearVelocity = Vector3.new(
                    md.X * STEAL_SPEED, hrp.AssemblyLinearVelocity.Y, md.Z * STEAL_SPEED)
            end
        end)
    end

    SharedState.applyStealSpeedValue = function(s)
        s = math.clamp(math.floor((tonumber(s) or STEAL_SPEED) + 0.5), MIN_SPEED, MAX_SPEED)
        STEAL_SPEED = s
        Config.StealSpeed = s
        SaveConfig()
        if SharedState._refreshMiniStealSpeedSlider then pcall(SharedState._refreshMiniStealSpeedSlider) end
    end

    SharedState.DisableStealSpeed = function()
        doDisable()
    end

    SharedState.StealSpeedToggleFunc = function()
        if stealSpeedEnabled then doDisable() else doEnable() end
    end

    task.spawn(function()
        local lastHadSteal = nil
        while true do
            task.wait(0.3)
            if not Config.AutoStealSpeed then lastHadSteal = nil; continue end
            local hasSteal = (LocalPlayer:GetAttribute("Stealing") == true)
            if lastHadSteal == hasSteal then continue end
            lastHadSteal = hasSteal
            if hasSteal and not stealSpeedEnabled then
                doEnable()
            elseif not hasSteal and stealSpeedEnabled then doDisable() end
        end
    end)
end)

task.spawn(function()
    local brainrotESPEnabled = Config.BrainrotESP
    local brainrotESPFolder = Instance.new("Folder")
    brainrotESPFolder.Name = "JustAFanBrainrotESP"
    brainrotESPFolder.Parent = Workspace
    local brainrotBillboards = {}
    local hiddenOverheads = {}
    local MUT_COLORS = {
        Cursed = Color3.fromRGB(170, 170, 170),
        Gold = Color3.fromRGB(170, 170, 170),
        Diamond = Color3.fromRGB(170, 170, 170),
        YinYang = Color3.fromRGB(170, 170, 170),
        Rainbow = Color3.fromRGB(170, 170, 170),
        Lava = Color3.fromRGB(170, 170, 170),
        Candy = Color3.fromRGB(170, 170, 170),
        Bloodrot = Color3.fromRGB(170, 170, 170),
        Radioactive = Color3.fromRGB(170, 170, 170),
        Divine = Color3.fromRGB(170, 170, 170)
    }
    
    local function createBrainrotBillboard(data)
        local bb = Instance.new("BillboardGui")
        bb.Name = "BrainrotESP_" .. data.uid
        bb.Size = UDim2.new(0, 160, 0, 38)
        bb.StudsOffset = Vector3.new(0, 1.8, 0)
        bb.AlwaysOnTop = true
        bb.LightInfluence = 0
        bb.MaxDistance = 3000
        
        local hasMut = data.mutation and data.mutation ~= "None" and data.mutation ~= "N/A"
        local color = hasMut and (MUT_COLORS[data.mutation] or Color3.fromRGB(175, 175, 175)) or Color3.fromRGB(175, 175, 175)
        
        local container = Instance.new("Frame", bb)
        container.Size = UDim2.new(1, 0, 1, 0)
        container.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        container.BackgroundTransparency = 0.5
        container.BorderSizePixel = 0
        Instance.new("UICorner", container).CornerRadius = UDim.new(0, 4)
        
        local stroke = Instance.new("UIStroke", container)
        stroke.Color = color
        stroke.Thickness = 1.5
        stroke.Transparency = 0.2
        
        local nameLabel = Instance.new("TextLabel", container)
        nameLabel.Size = UDim2.new(1, -6, 0, 18)
        nameLabel.Position = UDim2.new(0, 3, 0, 2)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Font = Enum.Font.GothamBlack
        nameLabel.TextSize = 13
        nameLabel.TextColor3 = color
        nameLabel.TextStrokeTransparency = 0
        nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        nameLabel.Text = (data.name or data.petName) or "???"
        nameLabel.TextXAlignment = Enum.TextXAlignment.Center
        
        local genLabel = Instance.new("TextLabel", container)
        genLabel.Size = UDim2.new(1, -6, 0, 14)
        genLabel.Position = UDim2.new(0, 3, 0, 20)
        genLabel.BackgroundTransparency = 1
        genLabel.Font = Enum.Font.GothamBold
        genLabel.TextSize = 11
        genLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        genLabel.TextStrokeTransparency = 0
        genLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        genLabel.Text = data.genText or ""
        genLabel.TextXAlignment = Enum.TextXAlignment.Center
        
        if hasMut then
            local mutBadge = Instance.new("TextLabel", bb)
            mutBadge.Size = UDim2.new(0, 60, 0, 14)
            mutBadge.Position = UDim2.new(0.5, -30, 0, -16)
            mutBadge.BackgroundColor3 = color
            mutBadge.BackgroundTransparency = 0.3
            mutBadge.Font = Enum.Font.GothamBlack
            mutBadge.TextSize = 9
            mutBadge.TextColor3 = Color3.fromRGB(255, 255, 255)
            mutBadge.TextStrokeTransparency = 0
            mutBadge.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
            mutBadge.Text = data.mutation:upper()
            Instance.new("UICorner", mutBadge).CornerRadius = UDim.new(0, 3)
        end
        
        return bb
    end
    
    local function hideDefaultOverhead(overhead)
        if overhead and overhead.Parent and not hiddenOverheads[overhead] then
            hiddenOverheads[overhead] = overhead.Enabled
            overhead.Enabled = false
        end
    end
    
    local function showDefaultOverhead(overhead)
        if overhead and hiddenOverheads[overhead] ~= nil then
            overhead.Enabled = hiddenOverheads[overhead]
            hiddenOverheads[overhead] = nil
        end
    end
    
    local function restoreAllOverheads()
        for overhead, wasEnabled in pairs(hiddenOverheads) do
            if overhead and overhead.Parent then overhead.Enabled = wasEnabled end
        end
        hiddenOverheads = {}
    end
    
    local function refreshBrainrotESP()
    if not brainrotESPEnabled then return end
    local cache = SharedState.AllAnimalsCache
    if not cache or #cache == 0 then 
        return 
    end
    
    local MIN_ESP_GEN = 10000000 -- 10m/s, change this number as needed
    local seen = {}
    for _, data in ipairs(cache) do
        if data.genValue ~= nil and not data.isWalking and data.genValue >= MIN_ESP_GEN then
                seen[data.uid] = true
                
                if not brainrotBillboards[data.uid] then
                    local adornee = nil
                    local overhead = nil
                    local studsOffset = Vector3.new(0, 1.8, 0)
                    
                    if data.plot and data.slot then
    local _fag = _G.findAdorneeGlobal
    adornee = _fag and _fag(data)
end
                    
                    if adornee then
                        local bb = createBrainrotBillboard(data)
                        bb.Adornee = adornee
                        bb.StudsOffset = studsOffset
                        bb.Parent = adornee
                        brainrotBillboards[data.uid] = {bb = bb, overhead = overhead}
                    end
                end
            end
        end
        
        for uid, entry in pairs(brainrotBillboards) do
            if not seen[uid] then
                if entry.bb then entry.bb:Destroy() end
                if entry.overhead then showDefaultOverhead(entry.overhead) end
                brainrotBillboards[uid] = nil
            end
        end
    end
    
    local function clearBrainrotESP()
        for _, entry in pairs(brainrotBillboards) do
            if entry.bb then entry.bb:Destroy() end
            if entry.overhead then showDefaultOverhead(entry.overhead) end
        end
        brainrotBillboards = {}
        restoreAllOverheads()
    end
    
    espToggleRef.setFn = function(enabled)
        brainrotESPEnabled = enabled
        if enabled then
            pcall(refreshBrainrotESP)
        else
            clearBrainrotESP()
        end
    end
    
    task.spawn(function()
    local Pkgs   = ReplicatedStorage:WaitForChild("Packages")
    local Sync   = require(Pkgs:WaitForChild("Synchronizer"))
    pcall(function()
        for _, name in ipairs({"Get", "Wait"}) do
            local fn = Sync[name]
            if not fn then continue end
            local ok, ups = pcall(debug.getupvalues, fn)
            if not ok then continue end
            for idx, val in pairs(ups) do
                if typeof(val) == "function" and not isexecutorclosure(val) then
                    debug.setupvalue(fn, idx, function() end)
                end
            end
        end
    end)
    local AData   = require(ReplicatedStorage:WaitForChild("Datas"):WaitForChild("Animals"))
    local AShared = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Animals"))
    local NUtils  = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("NumberUtils"))
    local lastH   = {}

    local function scan(plot)
        local ok, ch = pcall(function() return Sync:Get(plot.Name) end)
        if not ok or not ch then return end
        local al = ch:Get("AnimalList")
        local h  = ""
        if al then for s, d in pairs(al) do if type(d) == "table" then h = h..s..(d.Index or "")..(d.Mutation or "") end end end
        if lastH[plot.Name] == h then return end
        lastH[plot.Name] = h
        for i = #SharedState.AllAnimalsCache, 1, -1 do if SharedState.AllAnimalsCache[i].plot == plot.Name then table.remove(SharedState.AllAnimalsCache, i) end end
        if not al then return end
        local owner = ch:Get("Owner"); if not owner then return end
        local on = (typeof(owner) == "Instance" and owner.Name) or (type(owner) == "table" and owner.Name) or "?"
        if not Players:FindFirstChild(on) then return end
        for slot, ad in pairs(al) do
            if type(ad) == "table" then
                local inf = AData[ad.Index]
                if inf then
                    local mut = ad.Mutation or "None"
                    if mut == "Yin Yang" then mut = "YinYang" end
                    local gv = AShared:GetGeneration(ad.Index, ad.Mutation, ad.Traits, nil)
                    table.insert(SharedState.AllAnimalsCache, {
                        name     = inf.DisplayName or ad.Index,
                        genText  = "$"..NUtils:ToString(gv).."/s",
                        genValue = gv,
                        mutation = mut,
                        owner    = on,
                        plot     = plot.Name,
                        slot     = tostring(slot),
                        uid      = plot.Name.."_"..tostring(slot),
                    })
                end
            end
        end
        table.sort(SharedState.AllAnimalsCache, function(a, b) return a.genValue > b.genValue end)
    end

    local function setup(plot)
        local ch, tries = nil, 0
        while not ch and tries < 50 do
            local ok, r = pcall(function() return Sync:Get(plot.Name) end)
            if ok and r then ch = r; break end
            tries += 1; task.wait(0.1)
        end
        if not ch then return end
        scan(plot)
        plot.DescendantAdded:Connect(function()    task.wait(0.1); scan(plot) end)
        plot.DescendantRemoving:Connect(function() task.wait(0.1); scan(plot) end)
        task.spawn(function() while plot.Parent do task.wait(5); scan(plot) end end)
    end

    local plots = Workspace:WaitForChild("Plots", 8)
    if plots then
        for _, p in ipairs(plots:GetChildren()) do task.spawn(setup, p) end
        plots.ChildAdded:Connect(function(p)   task.wait(0.3); setup(p) end)
        plots.ChildRemoved:Connect(function(p)
            lastH[p.Name] = nil
            for i = #SharedState.AllAnimalsCache, 1, -1 do if SharedState.AllAnimalsCache[i].plot == p.Name then table.remove(SharedState.AllAnimalsCache, i) end end
        end)
    end
end)

--  Walking brainrot scanner 
task.spawn(function()
    local AData   = require(ReplicatedStorage:WaitForChild("Datas"):WaitForChild("Animals"))
    local AShared = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Animals"))
    local NUtils  = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("NumberUtils"))

    local BLACKLIST = {
        ["arcadopus"] = true, ["festive lucky block"] = true,
        ["spooky lucky block"] = true, ["leprechaun lucky block"] = true,
    }
    local nameMap = {}
    for index, data in pairs(AData) do
        local iL = index:lower()
        local dL = (data.DisplayName or ""):lower()
        local entry = {index = index, data = data}
        nameMap[iL] = entry; nameMap[iL:gsub("%s+", "")] = entry
        if dL ~= "" then nameMap[dL] = entry; nameMap[dL:gsub("%s+", "")] = entry end
    end

    local function isInsidePlots(obj)
        local p = obj.Parent
        while p do
            if p == Workspace then return false end
            if p.Name == "Plots" then return true end
            p = p.Parent
        end
        return false
    end

    local function findPromptOnModel(model)
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.Enabled and d.ActionText == "Steal" then return d end
        end
        return nil
    end

    local function isInCache(obj)
        for _, e in ipairs(SharedState.WalkingCache) do if e.model == obj then return true end end
        return false
    end

    local function tryAdd(obj)
        if not obj or not obj:IsA("Model") then return end
        if isInCache(obj) then return end
        if isInsidePlots(obj) then return end
        if Players:GetPlayerFromCharacter(obj) then return end
        local mLow  = obj.Name:lower()
        local found = nameMap[mLow] or nameMap[mLow:gsub("%s+", "")]
        if not found then return end
        local dispLow = (found.data.DisplayName or found.index):lower()
        if BLACKLIST[dispLow] or BLACKLIST[mLow] then return end
        if not obj:FindFirstChildWhichIsA("Humanoid", true) then return end
        local gv = 0
        local ok1, val = pcall(function() return AShared:GetGeneration(found.index, nil, nil, nil) end)
        if ok1 and val then gv = val end
        local genStr = "$0/s"
        local ok2, str = pcall(function() return NUtils:ToString(gv) end)
        if ok2 and str then genStr = "$"..str.."/s" end
        local entry = {
            name = found.data.DisplayName or found.index, genValue = gv,
            genText = genStr, mutation = "None", owner = "[Walking]",
            plot = "walking", slot = "walking", uid = "walk_"..tostring(obj),
            isWalking = true, model = obj, prompt = findPromptOnModel(obj),
        }
        table.insert(SharedState.WalkingCache, entry)
        obj.AncestryChanged:Connect(function()
            if not obj:IsDescendantOf(Workspace) then
                for i = #SharedState.WalkingCache, 1, -1 do if SharedState.WalkingCache[i].model == obj then table.remove(SharedState.WalkingCache, i); break end end
            end
        end)
        task.spawn(function()
            local t = tick()
            while tick()-t < 10 do
                task.wait(0.5)
                if not obj.Parent then break end
                if entry.prompt and entry.prompt.Parent and entry.prompt.Enabled then break end
                entry.prompt = findPromptOnModel(obj)
            end
        end)
    end

    local function fullScan()
        for i = #SharedState.WalkingCache, 1, -1 do
            if not SharedState.WalkingCache[i].model or not SharedState.WalkingCache[i].model.Parent then table.remove(SharedState.WalkingCache, i) end
        end
        for _, obj in ipairs(Workspace:GetDescendants()) do pcall(tryAdd, obj) end
    end

    -- Fires for every descendant added to Workspace -- a lot of bails on non-Humanoid
    -- spawns. Wrap native so the early-return is cheap under Luraph's VM.
    Workspace.DescendantAdded:Connect(LPH_NO_VIRTUALIZE(function(obj)
        if not obj:IsA("Humanoid") then return end
        local model = obj.Parent
        if not model or not model:IsA("Model") then return end
        if isInsidePlots(model) then return end
        local mLow = model.Name:lower()
        if nameMap[mLow] or nameMap[mLow:gsub("%s+", "")] then task.wait(0.1); pcall(tryAdd, model) end
    end))

    -- Periodic safety-net scan. The DescendantAdded hook above + per-entry AncestryChanged
    -- already keep the cache live, so the only thing fullScan actually catches is brainrots
    -- that existed BEFORE the script loaded (covered by the one-shot pcall below) and
    -- desyncs. Previously this ran every 2s and walked Workspace:GetDescendants() under the
    -- Luraph VM -- ~tens of thousands of instances * 2 per file (two identical scanners),
    -- which matches the "every couple seconds" FPS dip. Bumped to 30s and the periodic
    -- scan wrapped native so each tick is cheap.
    pcall(fullScan)
    task.spawn(LPH_NO_VIRTUALIZE(function()
        while true do task.wait(30); pcall(fullScan) end
    end))
end)

    task.spawn(function()
        while true do
            task.wait(0.3)
            if brainrotESPEnabled then
                local cache = SharedState.AllAnimalsCache
                if cache and #cache > 0 then pcall(refreshBrainrotESP) end
            end
        end
    end)

    task.spawn(function()
        while true do
            task.wait(2)
            if brainrotESPEnabled then
                local cache = SharedState.AllAnimalsCache
                if cache and #cache > 0 then
                    if next(brainrotBillboards) == nil then clearBrainrotESP() end
                    pcall(refreshBrainrotESP)
                end
            end
        end
    end)
end)
end
_initPanel()
_initPanel = nil

task.spawn(function()
	local animPlaying = false
	local tracks = {}
	local clone, oldRoot, hip, connection
	local folderConnections = {}
	local SINK_AMOUNT = 5
	local serverGhosts = {}
	local ghostEnabled = true
	local lagbackCallCount = 0
	local lagbackWindowStart = 0
	local lastLagbackTime = 0
	local errorOrbActive = false
	local errorOrb = nil
	local errorOrbConnection = nil

	local function clearErrorOrb()
		if errorOrb and errorOrb.Parent then errorOrb:Destroy() end
		errorOrb = nil; errorOrbActive = false
		if errorOrbConnection then errorOrbConnection:Disconnect(); errorOrbConnection = nil end
	end

	local function createErrorOrb()
		if errorOrbActive then return end
		errorOrbActive = true
		for _, ghost in pairs(serverGhosts) do if ghost and ghost.Parent then ghost:Destroy() end end
		serverGhosts = {}
		local sg = Instance.new("ScreenGui")
		sg.Name = "ErrorOrbGui"; sg.ResetOnSpawn = false
		sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
		local fr = Instance.new("Frame")
		fr.Size = UDim2.new(0, 500, 0, 60)
		fr.Position = UDim2.new(0.5, -250, 0.3, 0)
		fr.BackgroundTransparency = 1; fr.BorderSizePixel = 0; fr.Parent = sg
		local l1 = Instance.new("TextLabel")
		l1.Size = UDim2.new(1, 0, 0.5, 0); l1.BackgroundTransparency = 1
		l1.Text = "ERROR CAUSED BY PLAYER DEATH"
		l1.TextColor3 = Color3.fromRGB(255, 0, 0)
		l1.TextStrokeTransparency = 0; l1.TextStrokeColor3 = Color3.new(0, 0, 0)
		l1.Font = Enum.Font.SourceSansBold; l1.TextScaled = true; l1.Parent = fr
		local l2 = Instance.new("TextLabel")
		l2.Size = UDim2.new(1, 0, 0.5, 0); l2.Position = UDim2.new(0, 0, 0.5, 0)
		l2.BackgroundTransparency = 1; l2.Text = "MUST RESET TO FIX ERROR"
		l2.TextColor3 = Color3.fromRGB(255, 0, 0)
		l2.TextStrokeTransparency = 0; l2.TextStrokeColor3 = Color3.new(0, 0, 0)
		l2.Font = Enum.Font.SourceSansBold; l2.TextScaled = true; l2.Parent = fr
		errorOrb = sg
	end

	local function createServerGhost(position)
		if not ghostEnabled or errorOrbActive then return end
		local now = tick()
		if now - lastLagbackTime < 0.05 then return end
		lastLagbackTime = now
		if now - lagbackWindowStart > 1 then lagbackCallCount = 0; lagbackWindowStart = now end
		lagbackCallCount = lagbackCallCount + 1
		if lagbackCallCount >= 7 then createErrorOrb(); return end
		for _, g in pairs(serverGhosts) do if g and g.Parent then g:Destroy() end end
		serverGhosts = {}
		local sg = Instance.new("ScreenGui")
		sg.Name = "LagbackNotification"; sg.ResetOnSpawn = false
		sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
		local sl = Instance.new("TextLabel")
		sl.Size = UDim2.new(0, 500, 0, 30); sl.Position = UDim2.new(0.5, -250, 0.15, 0)
		sl.BackgroundTransparency = 1; sl.Text = "LAGBACK DETECTED"
		sl.TextColor3 = Color3.fromRGB(255, 0, 0)
		sl.TextStrokeTransparency = 0; sl.TextStrokeColor3 = Color3.new(0, 0, 0)
		sl.Font = Enum.Font.SourceSansBold; sl.TextScaled = true; sl.Parent = sg
		local sw = Instance.new("TextLabel")
		sw.Size = UDim2.new(0, 650, 0, 25); sw.Position = UDim2.new(0.5, -325, 0.15, 32)
		sw.BackgroundTransparency = 1
		sw.Text = "DISABLE INVISIBLE STEAL NOW OR YOU WILL BE KILLED BY ANTICHEAT"
		sw.TextColor3 = Color3.fromRGB(200, 200, 200)
		sw.TextStrokeTransparency = 0; sw.TextStrokeColor3 = Color3.new(0, 0, 0)
		sw.Font = Enum.Font.SourceSansBold; sw.TextScaled = true; sw.Parent = sg
		task.delay(1.5, function() if sg and sg.Parent then sg:Destroy() end end)
		local ghost = Instance.new("Part")
		ghost.Name = "LagbackGhost"; ghost.Shape = Enum.PartType.Ball
		ghost.Size = Vector3.new(3, 3, 3); ghost.Color = Color3.fromRGB(255, 0, 0)
		ghost.Material = Enum.Material.Glass; ghost.Transparency = 0.3
		ghost.CanCollide = false; ghost.Anchored = true; ghost.CastShadow = false
		ghost.Position = position + Vector3.new(0, 5, 0); ghost.Parent = Workspace.CurrentCamera
		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.new(0, 400, 0, 60); bb.StudsOffset = Vector3.new(0, 4, 0)
		bb.AlwaysOnTop = true; bb.Parent = ghost
		local bl = Instance.new("TextLabel")
		bl.Size = UDim2.new(1, 0, 0, 25); bl.BackgroundTransparency = 1
		bl.Text = "LAGBACK DETECTED"; bl.TextColor3 = Color3.fromRGB(255, 0, 0)
		bl.TextStrokeTransparency = 0; bl.TextStrokeColor3 = Color3.new(0, 0, 0)
		bl.Font = Enum.Font.SourceSansBold; bl.TextScaled = true; bl.Parent = bb
		local bw = Instance.new("TextLabel")
		bw.Size = UDim2.new(1, 0, 0, 25); bw.Position = UDim2.new(0, 0, 0, 25)
		bw.BackgroundTransparency = 1
		bw.Text = "DISABLE INVISIBLE STEAL NOW OR YOU WILL BE KILLED BY ANTICHEAT"
		bw.TextColor3 = Color3.fromRGB(200, 200, 200)
		bw.TextStrokeTransparency = 0; bw.TextStrokeColor3 = Color3.new(0, 0, 0)
		bw.Font = Enum.Font.SourceSansBold; bw.TextScaled = true; bw.Parent = bb
		table.insert(serverGhosts, ghost)
	end

	local function clearAllGhosts()
		for _, ghost in pairs(serverGhosts) do pcall(function() if ghost and ghost.Parent then ghost:Destroy() end end) end
		serverGhosts = {}; clearErrorOrb(); lagbackCallCount = 0; lastLagbackTime = 0
		pcall(function()
			local pg = LocalPlayer:FindFirstChild("PlayerGui")
			if pg then for _, gui in pairs(pg:GetChildren()) do if gui.Name == "LagbackNotification" then gui:Destroy() end end end
		end)
		pcall(function() if Workspace.CurrentCamera then for _, c in pairs(Workspace.CurrentCamera:GetChildren()) do if c.Name == "LagbackGhost" then c:Destroy() end end end end)
		pcall(function() for _, c in pairs(Workspace:GetDescendants()) do if c.Name == "LagbackGhost" then c:Destroy() end end end)
	end

	local function removeFolders()
		local pf = Workspace:FindFirstChild(LocalPlayer.Name)
		if not pf then return end
		local dr = pf:FindFirstChild("DoubleRig")
		if dr then
			local rr = dr:FindFirstChild("HumanoidRootPart") or dr:FindFirstChildWhichIsA("BasePart")
			if rr and ghostEnabled then createServerGhost(rr.Position) end
			dr:Destroy()
		end
		local cs = pf:FindFirstChild("Constraints")
		if cs then cs:Destroy() end
		local conn = pf.ChildAdded:Connect(function(child)
			if child.Name == "DoubleRig" then
				task.defer(function()
					local rr = child:FindFirstChild("HumanoidRootPart") or child:FindFirstChildWhichIsA("BasePart")
					if rr and ghostEnabled then createServerGhost(rr.Position) end
					child:Destroy()
				end)
			elseif child.Name == "Constraints" then child:Destroy() end
		end)
		table.insert(folderConnections, conn)
	end

	local function doClone()
		local character = LocalPlayer.Character
		if character and character:FindFirstChild("Humanoid") and character.Humanoid.Health > 0 then
			hip = character.Humanoid.HipHeight
			oldRoot = character:FindFirstChild("HumanoidRootPart")
			if not oldRoot or not oldRoot.Parent then return false end
			for _, c in pairs(oldRoot:GetChildren()) do
				if c:IsA("Attachment") and (c.Name:find("Beam") or c.Name:find("Attach")) then c:Destroy() end
			end
			for _, c in pairs(oldRoot:GetChildren()) do if c:IsA("Beam") then c:Destroy() end end
			local tmp = Instance.new("Model"); tmp.Parent = game
			character.Parent = tmp
			clone = oldRoot:Clone(); clone.Parent = character
			oldRoot.Parent = Workspace.CurrentCamera
			clone.CFrame = oldRoot.CFrame; character.PrimaryPart = clone
			character.Parent = Workspace
			for _, v in pairs(character:GetDescendants()) do
				if v:IsA("Weld") or v:IsA("Motor6D") then
					if v.Part0 == oldRoot then v.Part0 = clone end
					if v.Part1 == oldRoot then v.Part1 = clone end
				end
			end
			tmp:Destroy(); return true
		end
		return false
	end

	local function revertClone()
		local character = LocalPlayer.Character
		if not oldRoot or not oldRoot:IsDescendantOf(Workspace) or not character or character.Humanoid.Health <= 0 then return end
		local tmp = Instance.new("Model"); tmp.Parent = game
		character.Parent = tmp
		oldRoot.Parent = character; character.PrimaryPart = oldRoot
		character.Parent = Workspace; oldRoot.CanCollide = true
		for _, v in pairs(character:GetDescendants()) do
			if v:IsA("Weld") or v:IsA("Motor6D") then
				if v.Part0 == clone then v.Part0 = oldRoot end
				if v.Part1 == clone then v.Part1 = oldRoot end
			end
		end
		if clone then local p = clone.CFrame; clone:Destroy(); clone = nil; oldRoot.CFrame = p end
		oldRoot = nil
		if character and character.Humanoid then character.Humanoid.HipHeight = hip end
		clearAllGhosts()
	end

	local function animationTrickery()
		local character = LocalPlayer.Character
		if character and character:FindFirstChild("Humanoid") and character.Humanoid.Health > 0 then
			local anim = Instance.new("Animation")
			anim.AnimationId = "http://www.roblox.com/asset/?id=18537363391"
			local humanoid = character.Humanoid
			local animator = humanoid:FindFirstChild("Animator") or Instance.new("Animator", humanoid)
			local animTrack = animator:LoadAnimation(anim)
			animTrack.Priority = Enum.AnimationPriority.Action4
			animTrack:Play(0, 1, 0); anim:Destroy()
			table.insert(tracks, animTrack)
			animTrack.Stopped:Connect(function() if animPlaying then animationTrickery() end end)
			task.delay(0, function()
				animTrack.TimePosition = 0.7
				task.delay(0.3, function() if animTrack then animTrack:AdjustSpeed(math.huge) end end)
			end)
		end
	end

	local function turnOff()
		clearAllGhosts()
		if not animPlaying then return end
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		animPlaying = false; _G.invisibleStealEnabled = false
		for _, t in pairs(tracks) do pcall(function() t:Stop() end) end
		tracks = {}
		if connection then connection:Disconnect(); connection = nil end
		for _, c in ipairs(folderConnections) do if c then c:Disconnect() end end
		folderConnections = {}
		revertClone(); clearAllGhosts()
		if humanoid then pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end) end
		if _G.updateMovementPanelInvisVisual then pcall(_G.updateMovementPanelInvisVisual, false) end
		if updateVisualState then updateVisualState(false) end
	end

	local function turnOn()
		if animPlaying then return end
		local character = LocalPlayer.Character
		if not character then return end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then return end
		animPlaying = true; _G.invisibleStealEnabled = true
		if _G.updateMovementPanelInvisVisual then pcall(_G.updateMovementPanelInvisVisual, true) end
		if updateVisualState then updateVisualState(true) end
		tracks = {}; removeFolders()
		local success = doClone()
		if success then
			task.wait(0.05); animationTrickery()
			task.defer(function()
				if _G.resetBrainrotBeam then pcall(_G.resetBrainrotBeam) end
				if _G.resetPlotBeam then pcall(_G.resetPlotBeam) end
				task.wait(0.1)
				if _G.updateBrainrotBeam then pcall(_G.updateBrainrotBeam) end
				if _G.createPlotBeam then pcall(_G.createPlotBeam) end
			end)
			local lastSetPosition = nil; local skipFrames = 5
			connection = RunService.PreSimulation:Connect(function()
				if character and character:FindFirstChild("Humanoid") and character.Humanoid.Health > 0 and oldRoot then
					local root = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
					if root then
						if skipFrames > 0 then skipFrames = skipFrames - 1; lastSetPosition = nil
						elseif lastSetPosition and ghostEnabled then
							local currentPos = oldRoot.Position
							local jumpDist = (currentPos - lastSetPosition).Magnitude
							if jumpDist > 3 and not _G.RecoveryInProgress then
								lastSetPosition = nil; createServerGhost(currentPos)
								if _G.AutoRecoverLagback and _G.toggleInvisibleSteal then
									_G.RecoveryInProgress = true
									task.spawn(function()
										pcall(_G.toggleInvisibleSteal); task.wait(0.5)
										pcall(_G.toggleInvisibleSteal); _G.RecoveryInProgress = false
									end)
								end
							end
						end
						if clone then clone.CanCollide = false end
						for _, c in pairs(oldRoot:GetChildren()) do
							if c:IsA("Attachment") or c:IsA("Beam") then c:Destroy() end
						end
						local rotAngle = _G.InvisStealAngle or 180
						local sa = math.clamp(_G.SinkSliderValue or Config.SinkSliderValue or 2.5, 0.5, 10)
						local cf = root.CFrame - Vector3.new(0, sa, 0)
						oldRoot.CFrame = cf * CFrame.Angles(math.rad(rotAngle), 0, 0)
						oldRoot.AssemblyLinearVelocity = root.AssemblyLinearVelocity; oldRoot.CanCollide = false
						lastSetPosition = oldRoot.Position
					end
				end
			end)
		end
	end

    local invisGui = Instance.new("ScreenGui")
    invisGui.Name = "JustAFanInvisPanel"
    invisGui.ResetOnSpawn = false
    invisGui.Enabled = false

    local iFrame = Instance.new("Frame", invisGui)
    iFrame.Size = UDim2.new(0, 250, 0, 260)
    iFrame.Position = UDim2.new(Config.Positions.InvisPanel.X, 0, Config.Positions.InvisPanel.Y, 0)
    iFrame.BackgroundColor3 = Theme.Background
    iFrame.BackgroundTransparency = 0.29
    Instance.new("UICorner", iFrame).CornerRadius = UDim.new(0, 12)
    local iStroke = Instance.new("UIStroke", iFrame)
    iStroke.Color = Theme.Accent2
    iStroke.Thickness = 1.5
    iStroke.Transparency = 0.4
    CreateGradient(iStroke)
    task.defer(function() if addRacetrackBorder then addRacetrackBorder(iFrame, Theme.Accent1, 3) end end)

    local iHeader = Instance.new("Frame", iFrame)
    iHeader.Size = UDim2.new(1, 0, 0, 35)
    iHeader.BackgroundTransparency = 1
    MakeDraggable(iHeader, iFrame, "InvisPanel")

    local iTitle = Instance.new("TextLabel", iHeader)
    iTitle.Size = UDim2.new(1, -15, 1, 0)
    iTitle.Position = UDim2.new(0, 15, 0, 0)
    iTitle.BackgroundTransparency = 1
    iTitle.Text = "INVISIBLE STEAL"
    iTitle.Font = Enum.Font.GothamBlack
    iTitle.TextSize = 14
    iTitle.TextColor3 = Theme.TextPrimary
    iTitle.TextXAlignment = Enum.TextXAlignment.Left

    local iContainer = Instance.new("Frame", iFrame)
    iContainer.Size = UDim2.new(1, -20, 1, -40)
    iContainer.Position = UDim2.new(0, 10, 0, 35)
    iContainer.BackgroundTransparency = 1
    local iLayout = Instance.new("UIListLayout", iContainer)
    iLayout.Padding = UDim.new(0, 8)
    iLayout.SortOrder = Enum.SortOrder.LayoutOrder

    local function CreateIRow(height)
        local r = Instance.new("Frame", iContainer)
        r.Size = UDim2.new(1, 0, 0, height or 30)
        r.BackgroundTransparency = 1
        return r
    end

    local row1 = CreateIRow(30)
    local lbl1 = Instance.new("TextLabel", row1)
    lbl1.Size = UDim2.new(0.6, 0, 1, 0)
    lbl1.BackgroundTransparency = 1
    lbl1.Text = "Toggle Invis"
    lbl1.TextColor3 = Theme.TextPrimary
    lbl1.Font = Enum.Font.GothamBold
    lbl1.TextSize = 12
    lbl1.TextXAlignment = Enum.TextXAlignment.Left

    local btnInvis = Instance.new("TextButton", row1)
    btnInvis.Size = UDim2.new(0, 40, 0, 24)
    btnInvis.Position = UDim2.new(1, -40, 0.5, -12)
    btnInvis.BackgroundColor3 = Theme.SurfaceHighlight
    btnInvis.Text = "OFF"
    btnInvis.Font = Enum.Font.GothamBold
    btnInvis.TextSize = 11
    btnInvis.TextColor3 = Theme.TextPrimary
    Instance.new("UICorner", btnInvis).CornerRadius = UDim.new(0, 6)

    local keyBtn = Instance.new("TextButton", row1)
    keyBtn.Size = UDim2.new(0, 40, 0, 24)
    keyBtn.Position = UDim2.new(1, -90, 0.5, -12)
    keyBtn.BackgroundColor3 = Theme.Surface
    keyBtn.Text = Config.InvisToggleKey
    keyBtn.Font = Enum.Font.GothamBold
    keyBtn.TextColor3 = Theme.Accent1
    keyBtn.TextSize = 11
    Instance.new("UICorner", keyBtn).CornerRadius = UDim.new(0, 6)
    keyBtn.MouseButton1Click:Connect(function()
        keyBtn.Text = "..."
        local c
        c = UserInputService.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.Keyboard then
                Config.InvisToggleKey = i.KeyCode.Name
                _G.INVISIBLE_STEAL_KEY = i.KeyCode
                keyBtn.Text = i.KeyCode.Name
                SaveConfig()
                c:Disconnect()
            end
        end)
    end)

    local row2 = CreateIRow(30)
    local lbl2 = Instance.new("TextLabel", row2)
    lbl2.Size = UDim2.new(0.6, 0, 1, 0)
    lbl2.BackgroundTransparency = 1
    lbl2.Text = "Auto Fix Lagback"
    lbl2.TextColor3 = Theme.TextPrimary
    lbl2.Font = Enum.Font.GothamBold
    lbl2.TextSize = 12
    lbl2.TextXAlignment = Enum.TextXAlignment.Left

    local btnFix = Instance.new("TextButton", row2)
    btnFix.Size = UDim2.new(0, 50, 0, 24)
    btnFix.Position = UDim2.new(1, -50, 0.5, -12)
    btnFix.BackgroundColor3 = _G.AutoRecoverLagback and Theme.Success or Theme.SurfaceHighlight
    btnFix.Text = _G.AutoRecoverLagback and "ON" or "OFF"
    btnFix.Font = Enum.Font.GothamBold
    btnFix.TextSize = 11
    btnFix.TextColor3 = Theme.TextPrimary
    Instance.new("UICorner", btnFix).CornerRadius = UDim.new(0, 6)
    btnFix.MouseButton1Click:Connect(function()
        _G.AutoRecoverLagback = not _G.AutoRecoverLagback
        Config.AutoRecoverLagback = _G.AutoRecoverLagback
        SaveConfig()
        btnFix.Text = _G.AutoRecoverLagback and "ON" or "OFF"
        btnFix.BackgroundColor3 = _G.AutoRecoverLagback and Theme.Success or Theme.SurfaceHighlight
    end)

    local function CreateFancySlider(parent, name, min, max, default, callback)
        local frame = Instance.new("Frame", parent)
        frame.Size = UDim2.new(1, 0, 0, 45)
        frame.BackgroundTransparency = 1
            local label = Instance.new("TextLabel", frame)
            label.Size = UDim2.new(1, 0, 0, 15)
            label.BackgroundTransparency = 1
            label.TextColor3 = Theme.TextSecondary
            label.Font = Enum.Font.GothamBold
            label.TextSize = 10
            label.TextXAlignment = Enum.TextXAlignment.Left
            label.Text = name .. ": " .. default
            local slideBg = Instance.new("Frame", frame)
            slideBg.Size = UDim2.new(1, 0, 0, 6)
            slideBg.Position = UDim2.new(0, 0, 0, 25)
            slideBg.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
            Instance.new("UICorner", slideBg).CornerRadius = UDim.new(1, 0)
            slideBg.Parent = frame
            local fill = Instance.new("Frame", slideBg)
            fill.Size = UDim2.new(0, 0, 1, 0)
            fill.BackgroundColor3 = Color3.fromRGB(80, 130, 180)
            fill.ZIndex = 12
            fill.Parent = slideBg
            Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)
            local knob = Instance.new("Frame", slideBg)
            knob.Size = UDim2.new(0, 12, 0, 12)
            knob.BackgroundColor3 = Color3.fromRGB(200, 200, 200)
            knob.AnchorPoint = Vector2.new(0.5, 0.5)
            knob.Position = UDim2.new(0, 0, 0.5, 0)
            knob.ZIndex = 13
            knob.Parent = slideBg
            Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
            local function update(inputX)
                local p = math.clamp((inputX - slideBg.AbsolutePosition.X) / slideBg.AbsoluteSize.X, 0, 1)
                local val = min + (p * (max - min))
                if max > 100 then val = math.floor(val) else val = math.floor(val*10)/10 end
                fill.Size = UDim2.new(p, 0, 1, 0)
                knob.Position = UDim2.new(p, 0, 0.5, 0)
                label.Text = name .. ": " .. val
                callback(val)
            end
            local dragging = false
            slideBg.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 then
                    dragging = true
                    update(input.Position.X)
                end
            end)
            knob.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = true end
            end)
            UserInputService.InputEnded:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
            end)
            UserInputService.InputChanged:Connect(function(input)
                if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then update(input.Position.X) end
            end)
            local p = (default - min)/(max-min)
            fill.Size = UDim2.new(p, 0, 1, 0)
            knob.Position = UDim2.new(p, 0, 0.5, 0)
            return frame
    end

    local rotationSliderManuallyChanged = false
    CreateFancySlider(iContainer, "Rotation", 0, 360, Config.InvisStealAngle, function(v)
        rotationSliderManuallyChanged = true
        Config.InvisStealAngle = v
        _G.InvisStealAngle = v
        SaveConfig()
    end)

    CreateFancySlider(iContainer, "Depth", 0.5, 10, Config.SinkSliderValue, function(v)
        Config.SinkSliderValue = v
        _G.SinkSliderValue = v
        SaveConfig()
    end)

    local function updateVisualState(on)
        if btnInvis then
            btnInvis.Text = on and "ON" or "OFF"
            btnInvis.BackgroundColor3 = on and Theme.Success or Theme.SurfaceHighlight
        end
        if _G.updateMovementPanelInvisVisual then pcall(_G.updateMovementPanelInvisVisual, on) end
    end

    btnInvis.MouseButton1Click:Connect(function()
		if _G.toggleInvisibleSteal then
			pcall(_G.toggleInvisibleSteal)
			updateVisualState(_G.invisibleStealEnabled or false)
		end
	end)

	_G.toggleInvisibleSteal = function()
		if animPlaying then turnOff() else turnOn() end
	end

	UserInputService.InputBegan:Connect(function(input)
		if UserInputService:GetFocusedTextBox() then return end
		if input.KeyCode == (_G.INVISIBLE_STEAL_KEY or Enum.KeyCode.V) then
			pcall(_G.toggleInvisibleSteal)
			if _G.updateMovementPanelInvisVisual then pcall(_G.updateMovementPanelInvisVisual, _G.invisibleStealEnabled or false) end
			if updateVisualState then updateVisualState(_G.invisibleStealEnabled or false) end
		end
	end)

	local function onCharacterAdded(newChar)
		clearErrorOrb(); clearAllGhosts(); lagbackCallCount = 0
		pcall(function() for _, c in pairs(Workspace.CurrentCamera:GetChildren()) do if c:IsA("BasePart") and c.Name == "HumanoidRootPart" then c:Destroy() end end end)
		if oldRoot then pcall(function() oldRoot:Destroy() end); oldRoot = nil end
		if clone then pcall(function() clone:Destroy() end); clone = nil end
		animPlaying = false; _G.invisibleStealEnabled = false
		if _G.updateMovementPanelInvisVisual then pcall(_G.updateMovementPanelInvisVisual, false) end
		task.wait(0.2)
		local camera = Workspace.CurrentCamera
		if camera and newChar then
			local h = newChar:FindFirstChildOfClass("Humanoid")
			if h then camera.CameraSubject = h; camera.CameraType = Enum.CameraType.Custom end
		end
	end
    LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

    local function setupDeathListener()
        local ch = LocalPlayer.Character
        if ch then
            local h = ch:FindFirstChildOfClass("Humanoid")
            if h then h.Died:Connect(function() clearErrorOrb(); clearAllGhosts(); lagbackCallCount = 0 end) end
        end
    end
    setupDeathListener()
    LocalPlayer.CharacterAdded:Connect(function() task.wait(0.1); setupDeathListener() end)

end)

task.spawn(function()
    local wasStealingForInvis = false
    local invisWasEnabledBefore = false
    local autoEnabledInvis = false
    task.wait(1)
    while task.wait(0.1) do
        if _G.AutoInvisDuringSteal == false then
            wasStealingForInvis = false
            autoEnabledInvis = false
        else
            local isStealing = LocalPlayer:GetAttribute("Stealing")
            if isStealing and not wasStealingForInvis then
                invisWasEnabledBefore = _G.invisibleStealEnabled or false
                if not _G.invisibleStealEnabled and _G.toggleInvisibleSteal then
                    task.delay(0.25, function()
                        if LocalPlayer:GetAttribute("Stealing") and not _G.invisibleStealEnabled then
                            pcall(_G.toggleInvisibleSteal)
                            autoEnabledInvis = true
                        end
                    end)
                end
            end
            if not isStealing and autoEnabledInvis and _G.invisibleStealEnabled and _G.toggleInvisibleSteal then
                pcall(_G.toggleInvisibleSteal)
                autoEnabledInvis = false
            end
            wasStealingForInvis = isStealing
        end
    end
end)

SharedState.FOV_MANAGER = {
    activeCount = 0,
    conn = nil,
    forcedFOV = 70,
}
function SharedState.FOV_MANAGER:Start()
    if self.conn then return end
    self.forcedFOV = Config.FOV or 70
    self.conn = RunService.RenderStepped:Connect(function()
        local cam = Workspace.CurrentCamera
        if cam then
            local targetFOV = Config.FOV or self.forcedFOV
            if cam.FieldOfView ~= targetFOV then cam.FieldOfView = targetFOV end
        end
    end)
end
function SharedState.FOV_MANAGER:Stop()
    if self.conn then
        self.conn:Disconnect()
        self.conn = nil
    end
end
function SharedState.FOV_MANAGER:Push()
    self.activeCount = self.activeCount + 1
    self:Start()
end
function SharedState.FOV_MANAGER:Pop()
    if self.activeCount > 0 then self.activeCount = self.activeCount - 1 end
    if self.activeCount == 0 then self:Stop() end
end

SharedState.ANTI_BEE_DISCO = {
    running = false,
    connections = {},
    originalMoveFunction = nil,
    controlsProtected = false,
    badLightingNames = { Blue = true, DiscoEffect = true, BeeBlur = true, ColorCorrection = true },
}
function SharedState.ANTI_BEE_DISCO.nuke(obj)
    if not obj or not obj.Parent then return end
    if SharedState.ANTI_BEE_DISCO.badLightingNames[obj.Name] then pcall(function() obj:Destroy() end) end
end
function SharedState.ANTI_BEE_DISCO.disconnectAll()
    for _, conn in ipairs(SharedState.ANTI_BEE_DISCO.connections) do
        if typeof(conn) == "RBXScriptConnection" then conn:Disconnect() end
    end
    SharedState.ANTI_BEE_DISCO.connections = {}
end
function SharedState.ANTI_BEE_DISCO.protectControls()
    if SharedState.ANTI_BEE_DISCO.controlsProtected then return end
    pcall(function()
        local PlayerScripts = LocalPlayer.PlayerScripts
        local PlayerModule = PlayerScripts:FindFirstChild("PlayerModule")
        if not PlayerModule then return end
        local Controls = require(PlayerModule):GetControls()
        if not Controls then return end
        local ab = SharedState.ANTI_BEE_DISCO
        if not ab.originalMoveFunction then ab.originalMoveFunction = Controls.moveFunction end
        local function protectedMoveFunction(self, moveVector, relativeToCamera)
            if ab.originalMoveFunction then ab.originalMoveFunction(self, moveVector, relativeToCamera) end
        end
        table.insert(ab.connections, RunService.Heartbeat:Connect(function()
            if not ab.running or not Config.AntiBeeDisco then return end
            if Controls.moveFunction ~= protectedMoveFunction then Controls.moveFunction = protectedMoveFunction end
        end))
        Controls.moveFunction = protectedMoveFunction
        ab.controlsProtected = true
    end)
end
function SharedState.ANTI_BEE_DISCO.restoreControls()
    if not SharedState.ANTI_BEE_DISCO.controlsProtected then return end
    pcall(function()
        local PlayerModule = LocalPlayer.PlayerScripts:FindFirstChild("PlayerModule")
        if not PlayerModule then return end
        local Controls = require(PlayerModule):GetControls()
        local ab = SharedState.ANTI_BEE_DISCO
        if Controls and ab.originalMoveFunction then
            Controls.moveFunction = ab.originalMoveFunction
            ab.controlsProtected = false
        end
    end)
end
function SharedState.ANTI_BEE_DISCO.blockBuzzingSound()
    pcall(function()
        local beeScript = LocalPlayer.PlayerScripts:FindFirstChild("Bee", true)
        if beeScript then
            local buzzing = beeScript:FindFirstChild("Buzzing")
            if buzzing and buzzing:IsA("Sound") then buzzing:Stop(); buzzing.Volume = 0 end
        end
    end)
end
function SharedState.ANTI_BEE_DISCO.Enable()
    local ab = SharedState.ANTI_BEE_DISCO
    if ab.running then return end
    ab.running = true
    for _, inst in ipairs(Lighting:GetDescendants()) do ab.nuke(inst) end
    table.insert(ab.connections, Lighting.DescendantAdded:Connect(function(obj)
        if not ab.running or not Config.AntiBeeDisco then return end
        ab.nuke(obj)
    end))
    ab.protectControls()
    table.insert(ab.connections, RunService.Heartbeat:Connect(function()
        if not ab.running or not Config.AntiBeeDisco then return end
        ab.blockBuzzingSound()
    end))
    SharedState.FOV_MANAGER:Push()
    ShowNotification("ANTI-BEE & DISCO", "Enabled")
end
function SharedState.ANTI_BEE_DISCO.Disable()
    local ab = SharedState.ANTI_BEE_DISCO
    if not ab.running then return end
    ab.running = false
    ab.restoreControls()
    ab.disconnectAll()
    SharedState.FOV_MANAGER:Pop()
    ShowNotification("ANTI-BEE & DISCO", "Disabled")
end

_G.ANTI_BEE_DISCO = SharedState.ANTI_BEE_DISCO

if Config.AntiBeeDisco then
    task.delay(1, function()
        if SharedState.ANTI_BEE_DISCO.Enable then SharedState.ANTI_BEE_DISCO.Enable() end
    end)
end

task.spawn(function()
    while true do
        if Workspace.CurrentCamera then
            if Config.FOV and Config.FOV ~= Workspace.CurrentCamera.FieldOfView then Workspace.CurrentCamera.FieldOfView = Config.FOV end
        end
        task.wait(0.1)
    end
end)

task.spawn(function()
    local function buildHUD()
        local existing = PlayerGui:FindFirstChild("JustAFanStatusHUD")
        if existing then existing:Destroy() end

        local hudGui = Instance.new("ScreenGui")
        hudGui.Name = "JustAFanStatusHUD"
        hudGui.ResetOnSpawn = false
        hudGui.DisplayOrder = 10
        hudGui.Parent = PlayerGui

        local main = Instance.new("Frame", hudGui)
        main.Name = "Main"
        main.Size = UDim2.new(0, 220, 0, 54)
        main.Position = UDim2.new(0.5, -110, 1, -140)
        main.BackgroundColor3 = Theme.Background
        main.BackgroundTransparency = 0.44
        main.BorderSizePixel = 0
        Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

        local mainStroke = Instance.new("UIStroke", main)
        mainStroke.Color = Theme.Accent1
        mainStroke.Thickness = 1.2
        mainStroke.Transparency = 0.55

        local stats = Instance.new("TextLabel", main)
        stats.Size = UDim2.new(1, 0, 0, 30)
        stats.Position = UDim2.new(0, 0, 0, 30)
        stats.BackgroundTransparency = 1
        stats.RichText = true
        stats.Text = ""
        stats.Font = Enum.Font.GothamBold
        stats.TextSize = 12
        stats.TextColor3 = Theme.TextPrimary
        stats.TextXAlignment = Enum.TextXAlignment.Center


        local hubName = Instance.new("TextLabel", main)
        hubName.Size = UDim2.new(1, 0, 0, 16)
        hubName.Position = UDim2.new(0, 0, 0, 2)
        hubName.BackgroundTransparency = 1
        hubName.Text = "SammyDawg hub  V1"
        local hubOwner = Instance.new("TextLabel", main)
        hubOwner.Size = UDim2.new(1, 0, 0, 12)
        hubOwner.Position = UDim2.new(0, 0, 0, 18)
        hubOwner.BackgroundTransparency = 1
        hubOwner.Text = "discord.gg/XY4jvXrn"
        hubOwner.Font = Enum.Font.GothamBold
        hubOwner.TextSize = 9
        hubOwner.TextColor3 = Theme.TextSecondary
        hubOwner.TextXAlignment = Enum.TextXAlignment.Center
        hubName.Font = Enum.Font.GothamBlack
        hubName.TextSize = 11
        hubName.TextColor3 = Theme.Accent1
        hubName.TextXAlignment = Enum.TextXAlignment.Center

        local fr2, ac3 = 0, 0
        RunService.Heartbeat:Connect(function(dt)
            fr2 += 1; ac3 += dt
            if ac3 >= 1 then
                local ping3 = math.floor(LocalPlayer:GetNetworkPing()*1000)
                local fc3 = fr2>=50 and "rgb(80,255,150)" or (fr2>=30 and "rgb(255,210,80)" or "rgb(255,80,80)")
                local pc3 = ping3<100 and "rgb(80,255,150)" or (ping3<200 and "rgb(255,210,80)" or "rgb(255,80,80)")
                stats.Text = string.format(
                    "<font color='rgb(140,140,160)'>FPS:</font> <font color='%s'><b>%d</b></font>  <font color='rgb(140,140,160)'>PING:</font> <font color='%s'><b>%dms</b></font>",
                    fc3, fr2, pc3, ping3
                )
                fr2, ac3 = 0, 0
            end
        end)

        local unlockContainer = Instance.new("Frame", hudGui)
        unlockContainer.Name = "UnlockButtonsContainer"
        unlockContainer.Size = UDim2.new(0, 170, 0, 44)
        unlockContainer.Position = UDim2.new(1, -182, 0, 12)
        unlockContainer.BackgroundTransparency = 1
        unlockContainer.Visible = Config.ShowUnlockButtonsHUD or false
        unlockContainer.ZIndex = 10
        unlockContainer.AnchorPoint = Vector2.new(0, 0)

        local uLayout = Instance.new("UIListLayout", unlockContainer)
        uLayout.FillDirection = Enum.FillDirection.Horizontal
        uLayout.Padding = UDim.new(0, 12)
        uLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

        local unlockLevels = {-2, 15, 32}
        for i = 1, 3 do
            local btn = Instance.new("TextButton", unlockContainer)
            btn.Size = UDim2.new(0, 48, 0, 40)
            btn.BackgroundColor3 = Color3.fromRGB(30, 10, 65)
            btn.BackgroundTransparency = 0.25
            btn.Text = tostring(i)
            btn.Font = Enum.Font.GothamBlack
            btn.TextSize = 16
            btn.TextColor3 = Color3.fromRGB(240, 200, 255)
            btn.BorderSizePixel = 0
            btn.AutoButtonColor = false
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
            local bs = Instance.new("UIStroke", btn)
            bs.Color = Color3.fromRGB(180, 50, 255)
            bs.Thickness = 2
            bs.Transparency = 0.15
            local lvl = unlockLevels[i]
            btn.MouseEnter:Connect(function()
                TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundTransparency=0, BackgroundColor3=Color3.fromRGB(80, 20, 140)}):Play()
                TweenService:Create(bs, TweenInfo.new(0.1), {Transparency=0}):Play()
            end)
            btn.MouseLeave:Connect(function()
                TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundTransparency=0.25, BackgroundColor3=Color3.fromRGB(30, 10, 65)}):Play()
                TweenService:Create(bs, TweenInfo.new(0.1), {Transparency=0.15}):Play()
            end)
            btn.MouseButton1Click:Connect(function()
                triggerClosestUnlock(lvl)
                ShowNotification("UNLOCK", "Level "..i)
            end)
        end

        if Config.ShowUnlockButtonsHUD then main.Size = UDim2.new(0, 220, 0, 54) end

        task.defer(function()
            if addRacetrackBorder then addRacetrackBorder(main, Theme.Accent1, 4) end
        end)

        return hudGui
    end

    buildHUD()
    _G.jafRebuildStatusHUD = buildHUD
end)

task.spawn(function()
    local playerESPEnabled = Config.PlayerESP
    local playerBillboards = {}
    
    local function makePlayerBillboard(player)
        local bb = Instance.new("BillboardGui")
        bb.Name = "PlayerESP_"..tostring(player.UserId)
        bb.Size = UDim2.new(0, 100, 0, 20)
        bb.StudsOffsetWorldSpace = Vector3.new(0, 2.8, 0)
        bb.AlwaysOnTop = true; bb.LightInfluence = 0; bb.ResetOnSpawn = false
        local nameLbl = Instance.new("TextLabel", bb)
        nameLbl.Size = UDim2.new(1,0,1,0)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font = Enum.Font.GothamBlack; nameLbl.TextSize = 13
        nameLbl.TextColor3 = Theme.Accent1
        nameLbl.TextXAlignment = Enum.TextXAlignment.Center
        nameLbl.TextStrokeTransparency = 0.4
        nameLbl.TextStrokeColor3 = Color3.fromRGB(0,0,0)
        nameLbl.Text = player.Name
        return bb, nameLbl
    end

    local function getHRP(player)
        local char = player.Character; if not char then return nil end
        return char:FindFirstChild("HumanoidRootPart")
    end

    local function createOrRefresh(player)
        if player == LocalPlayer then return end
        local hrp = getHRP(player); if not hrp then return end
        local hum = player.Character:FindFirstChild("Humanoid")
        
        if hum then hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None end

        local uid = player.UserId
        local entry = playerBillboards[uid]
        if not entry or not entry.bb or not entry.bb.Parent then
            if entry and entry.bb then pcall(function() entry.bb:Destroy() end) end
            local bb, nameLbl = makePlayerBillboard(player)
            bb.Adornee = hrp; bb.Parent = hrp
            playerBillboards[uid] = {bb=bb, nameLbl=nameLbl, player=player}
        else
            if entry.bb.Adornee ~= hrp then entry.bb.Adornee = hrp; entry.bb.Parent = hrp end
        end
    end

    local function clearAll()
        for uid, entry in pairs(playerBillboards) do
            if entry.bb and entry.bb.Parent then pcall(function() entry.bb:Destroy() end) end
            local p = Players:GetPlayerByUserId(uid)
            if p and p.Character then
                local h = p.Character:FindFirstChild("Humanoid")
                if h then h.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer end
            end
            playerBillboards[uid] = nil
        end
    end

    playerESPToggleRef.setFn = function(enabled)
        playerESPEnabled = enabled
        if not enabled then clearAll() end
    end

    task.spawn(function()
        while true do
            task.wait(0.5)
            if playerESPEnabled then
            for uid, entry in pairs(playerBillboards) do
                if not Players:GetPlayerByUserId(uid) then
                    if entry.bb and entry.bb.Parent then pcall(function() entry.bb:Destroy() end) end
                    playerBillboards[uid] = nil
                end
            end
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LocalPlayer then pcall(createOrRefresh, player) end
            end
            end
        end
    end)

    Players.PlayerAdded:Connect(function(p)
        p.CharacterAdded:Connect(function()
            task.wait(0.5)
            if playerESPEnabled then pcall(createOrRefresh, p) end
        end)
    end)
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            p.CharacterAdded:Connect(function()
                task.wait(0.5)
                if playerESPEnabled then pcall(createOrRefresh, p) end
            end)
        end
    end
end)

task.spawn(function()
    local function makeBlacklistESP(player)
        local char = player.Character
        if not char then return end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end

        local old = char:FindFirstChild("JustAFanBlacklistESP")
        if old then old:Destroy() end

        local msg = Config.BlacklistMsg or "BLOCKED"

        local bb = Instance.new("BillboardGui")
        bb.Name                  = "JustAFanBlacklistESP"
        bb.Size                  = UDim2.new(0, 120, 0, 22)
        bb.StudsOffsetWorldSpace = Vector3.new(0, 5.5, 0)
        bb.AlwaysOnTop           = true
        bb.LightInfluence        = 0
        bb.ResetOnSpawn          = false
        bb.Adornee               = hrp
        bb.Parent                = hrp

        local bg = Instance.new("Frame", bb)
        bg.Size                  = UDim2.new(1, 0, 1, 0)
        bg.BackgroundColor3      = Theme.Background or Color3.fromRGB(20, 15, 20)
        bg.BackgroundTransparency = 0.15
        bg.BorderSizePixel       = 0
        Instance.new("UICorner", bg).CornerRadius = UDim.new(1, 0)
        local bgStroke = Instance.new("UIStroke", bg)
        bgStroke.Color           = Theme.Error or Color3.fromRGB(255, 60, 60)
        bgStroke.Thickness       = 1.5
        bgStroke.Transparency    = 0.1

        local lbl = Instance.new("TextLabel", bg)
        lbl.Name                 = "MsgLbl"
        lbl.Size                 = UDim2.new(1, -8, 1, 0)
        lbl.Position             = UDim2.new(0, 4, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text                 = "[!] " .. msg
        lbl.Font                 = Enum.Font.GothamBlack
        lbl.TextSize             = 11
        lbl.TextColor3           = Theme.Error or Color3.fromRGB(255, 80, 80)
        lbl.TextStrokeTransparency = 0.5
        lbl.TextStrokeColor3     = Color3.fromRGB(0, 0, 0)
        lbl.TextXAlignment       = Enum.TextXAlignment.Center
        lbl.TextTruncate         = Enum.TextTruncate.AtEnd

        char.AncestryChanged:Connect(function()
            if not char.Parent then pcall(function() bb:Destroy() end) end
        end)
    end

    local function removeBlacklistESP(player)
        local char = player.Character
        if char then
            local bb = char:FindFirstChild("JustAFanBlacklistESP")
            if bb then bb:Destroy() end
        end
    end
    _G.removeBlacklistESP = removeBlacklistESP

    Players.PlayerRemoving:Connect(function(p)
        removeBlacklistESP(p)
    end)

    Players.PlayerAdded:Connect(function(p)
        p.CharacterAdded:Connect(function()
            task.wait(0.5)
            if Config.BlacklistESP ~= false and isBlacklisted and isBlacklisted(p.Name) then makeBlacklistESP(p) end
        end)
    end)
    for _, p in ipairs(Players:GetPlayers()) do
        p.CharacterAdded:Connect(function()
            task.wait(0.5)
            if Config.BlacklistESP ~= false and isBlacklisted and isBlacklisted(p.Name) then makeBlacklistESP(p) end
        end)
    end

    while true do
        task.wait(0.5)
        if Config.BlacklistESP == false then continue end
        for _, p in ipairs(Players:GetPlayers()) do
            if p == LocalPlayer then continue end
            pcall(function()
                if isBlacklisted and isBlacklisted(p.Name) then
                    local char = p.Character
                    if char and not char:FindFirstChild("JustAFanBlacklistESP") then makeBlacklistESP(p) end
                else
                    removeBlacklistESP(p)
                end
            end)
        end
    end
end)

task.spawn(function()
    local subspaceMineESPToggleRef = {setFn=nil} 

    if settingsGui and settingsGui:FindFirstChild("sFrame", true) then
        local sList = settingsGui.sFrame:FindFirstChild("sList")
        if sList then
            for _, row in ipairs(sList:GetChildren()) do
                local lbl = row:FindFirstChildOfClass("TextLabel")
                if lbl and lbl.Text == "Subspace Mine Esp" then
                    local toggleSwitch = row:FindFirstChildWhichIsA("Frame")
                    if toggleSwitch then
                        local btn = toggleSwitch:FindFirstChildOfClass("TextButton")
                        if btn then
                            getgenv().subspaceMineESPToggleRef = subspaceMineESPToggleRef
                        end
                    end
                    break 
                end
            end
        end
    end

    local subspaceMineESPData = {}
    local FolderName = "ToolsAdds" 

    local function getMineOwner(mineName)
        local ownerName = mineName:match("SubspaceTripmine(.+)")
        
        if not ownerName then return "Unknown" end 

        local foundPlayer = Players:FindFirstChild(ownerName)
        local displayName = foundPlayer and foundPlayer.DisplayName or ownerName
        
        return displayName
    end

    local function createMineESP(mine)
        local ownerName = getMineOwner(mine.Name)

        local selectionBox = Instance.new("SelectionBox")
        selectionBox.Name = "ESP_Hitbox"
        selectionBox.Adornee = mine 
        selectionBox.Color3 = Color3.fromRGB(167, 142, 255)
        selectionBox.LineThickness = 0.05
        selectionBox.Parent = mine 

        local billboardGui = Instance.new("BillboardGui")
        billboardGui.Name = "ESP_Label"
        billboardGui.Adornee = mine
        billboardGui.Size = UDim2.new(0, 250, 0, 50)
        billboardGui.StudsOffset = Vector3.new(0, 2.5, 0)
        billboardGui.AlwaysOnTop = false 
        billboardGui.Parent = mine

        local textLabel = Instance.new("TextLabel", billboardGui)
        textLabel.Size = UDim2.new(1, 0, 1, 0) 
        textLabel.BackgroundTransparency = 1
        textLabel.Text = ownerName .. "'s Subspace Mine"
        textLabel.TextColor3 = Color3.fromRGB(167, 142, 255)
        textLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        textLabel.TextStrokeTransparency = 0 
        textLabel.Font = Enum.Font.GothamBold 
        textLabel.TextSize = 16

        return { selectionBox = selectionBox, billboardGui = billboardGui, mine = mine }
    end

    local function refreshSubspaceMineESP()
        if not Config.SubspaceMineESP then
            for i, data in pairs(subspaceMineESPData) do
                if data.selectionBox and data.selectionBox.Parent then data.selectionBox:Destroy() end
                if data.billboardGui and data.billboardGui.Parent then data.billboardGui:Destroy() end
                subspaceMineESPData[i] = nil
            end
            return
        end

        local toolsFolder = Workspace:FindFirstChild(FolderName)
        if not toolsFolder then return end

        local currentMines = {}

        for _, obj in pairs(toolsFolder:GetChildren()) do
            if obj.Name:match("^SubspaceTripmine") and obj:IsA("BasePart") then
                currentMines[obj] = true

                if not subspaceMineESPData[obj] then subspaceMineESPData[obj] = createMineESP(obj) end
            end
        end

        for mineObj, data in pairs(subspaceMineESPData) do
            if not currentMines[mineObj] or not mineObj.Parent then
                if data.selectionBox and data.selectionBox.Parent then data.selectionBox:Destroy() end
                if data.billboardGui and data.billboardGui.Parent then data.billboardGui:Destroy() end
                subspaceMineESPData[mineObj] = nil
            end
        end
    end

    if subspaceMineESPToggleRef then
        subspaceMineESPToggleRef.setFn = function(enabled)
            Config.SubspaceMineESP = enabled
            if not enabled then
                for _, data in pairs(subspaceMineESPData) do
                    if data.selectionBox and data.selectionBox.Parent then data.selectionBox:Destroy() end
                    if data.billboardGui and data.billboardGui.Parent then data.billboardGui:Destroy() end
                end
                table.clear(subspaceMineESPData)
            end
        end
    end

    while true do
        task.wait(0.5) 
        
        local success, errorMessage = pcall(refreshSubspaceMineESP)
    end
end)

task.spawn(function()
    local Packages = ReplicatedStorage:WaitForChild("Packages")
    local Datas = ReplicatedStorage:WaitForChild("Datas")
    
    local AnimalsData = require(Datas:WaitForChild("Animals"))
    
    local function getPetsByRarity(rarityName)
        local petList = {}
        for petName, data in pairs(AnimalsData) do
            if data.Rarity == rarityName and not petName:find("Lucky Block") then table.insert(petList, petName) end
        end
        table.sort(petList)
        return petList
    end
    local secretPets = {}
    local _seen = {}
    for _, rar in ipairs({"Secret","Divine","Legendary","Epic","Rare"}) do
        for _, nm in ipairs(getPetsByRarity(rar)) do
            if not _seen[nm:lower()] then _seen[nm:lower()]=true; table.insert(secretPets,nm) end
        end
    end
    table.sort(secretPets)
    
    local priorityGui = Instance.new("ScreenGui")
    priorityGui.Name = "PriorityListGUI"
    priorityGui.ResetOnSpawn = false
    priorityGui.Parent = PlayerGui
    priorityGui.Enabled = false
    
    local mainFrame = Instance.new("Frame")
    mainFrame.Size = UDim2.new(0, 650, 0, 600)
    mainFrame.Position = UDim2.new(0.5, -325, 0.5, -300)
    mainFrame.BackgroundColor3 = Theme.Background
    mainFrame.BackgroundTransparency = 0.29
    mainFrame.BorderSizePixel = 0
    mainFrame.ClipsDescendants = true
    mainFrame.Parent = priorityGui
    
    Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 12)
    local mainStroke = Instance.new("UIStroke", mainFrame)
    mainStroke.Color = Theme.Accent2
    mainStroke.Thickness = 1.5
    mainStroke.Transparency = 0.4
    CreateGradient(mainStroke)
    
    local header = Instance.new("Frame", mainFrame)
    header.Size = UDim2.new(1, 0, 0, 40)
    header.BackgroundTransparency = 1
    MakeDraggable(header, mainFrame, nil)
    
    local titleLabel = Instance.new("TextLabel", header)
    titleLabel.Size = UDim2.new(0.6, 0, 1, 0)
    titleLabel.Position = UDim2.new(0, 15, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "PRIORITY LIST CUSTOMIZER"
    titleLabel.Font = Enum.Font.GothamBlack
    titleLabel.TextSize = 16
    titleLabel.TextColor3 = Theme.TextPrimary
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    
    local closeBtn = Instance.new("TextButton", header)
    closeBtn.Size = UDim2.new(0, 80, 0, 30)
    closeBtn.Position = UDim2.new(1, -95, 0.5, 0)
    closeBtn.AnchorPoint = Vector2.new(0, 0.5)
    closeBtn.BackgroundColor3 = Theme.Error
    closeBtn.Text = "CLOSE"
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 12
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
    
    closeBtn.MouseButton1Click:Connect(function()
        priorityGui.Enabled = false
    end)
    
    local contentFrame = Instance.new("Frame", mainFrame)
    contentFrame.Size = UDim2.new(1, -30, 1, -100)
    contentFrame.Position = UDim2.new(0, 15, 0, 50)
    contentFrame.BackgroundTransparency = 1
    
    local availableLabel = Instance.new("TextLabel", contentFrame)
    availableLabel.Size = UDim2.new(0.45, 0, 0, 25)
    availableLabel.Position = UDim2.new(0, 0, 0, 0)
    availableLabel.BackgroundTransparency = 1
    availableLabel.Text = "AVAILABLE SECRET BRAINROTS"
    availableLabel.Font = Enum.Font.GothamBold
    availableLabel.TextSize = 12
    availableLabel.TextColor3 = Theme.TextSecondary
    
    local availableScroll = Instance.new("ScrollingFrame", contentFrame)
    availableScroll.Size = UDim2.new(0.45, 0, 1, -30)
    availableScroll.Position = UDim2.new(0, 0, 0, 30)
    availableScroll.BackgroundColor3 = Theme.Surface
    availableScroll.BorderSizePixel = 0
    availableScroll.ScrollBarThickness = 0
    Instance.new("UICorner", availableScroll).CornerRadius = UDim.new(0, 8)
    
    local availablePadding = Instance.new("UIPadding", availableScroll)
    availablePadding.PaddingTop = UDim.new(0, 5)
    availablePadding.PaddingLeft = UDim.new(0, 5)
    availablePadding.PaddingRight = UDim.new(0, 5)
    availablePadding.PaddingBottom = UDim.new(0, 5)
    
    local availableListLayout = Instance.new("UIListLayout", availableScroll)
    availableListLayout.Padding = UDim.new(0, 5)
    availableListLayout.SortOrder = Enum.SortOrder.Name
    
    local priorityLabel = Instance.new("TextLabel", contentFrame)
    priorityLabel.Size = UDim2.new(0.45, 0, 0, 25)
    priorityLabel.Position = UDim2.new(0.55, 0, 0, 0)
    priorityLabel.BackgroundTransparency = 1
    priorityLabel.Text = "PRIORITY LIST"
    priorityLabel.Font = Enum.Font.GothamBold
    priorityLabel.TextSize = 12
    priorityLabel.TextColor3 = Theme.TextSecondary
    
    local priorityScroll = Instance.new("ScrollingFrame", contentFrame)
    priorityScroll.Size = UDim2.new(0.45, 0, 1, -30)
    priorityScroll.Position = UDim2.new(0.55, 0, 0, 30)
    priorityScroll.BackgroundColor3 = Theme.Surface
    priorityScroll.BorderSizePixel = 0
    priorityScroll.ScrollBarThickness = 0
    Instance.new("UICorner", priorityScroll).CornerRadius = UDim.new(0, 8)
    
    local priorityPadding = Instance.new("UIPadding", priorityScroll)
    priorityPadding.PaddingTop = UDim.new(0, 5)
    priorityPadding.PaddingLeft = UDim.new(0, 5)
    priorityPadding.PaddingRight = UDim.new(0, 5)
    priorityPadding.PaddingBottom = UDim.new(0, 5)
    
    local priorityListLayout = Instance.new("UIListLayout", priorityScroll)
    priorityListLayout.Padding = UDim.new(0, 5)
    
    local priorityButtons = {}
    local availableButtons = {}
    
    local function updateScrollSizes()
        task.wait()
        availableScroll.CanvasSize = UDim2.new(0, 0, 0, availableListLayout.AbsoluteContentSize.Y + 10)
        priorityScroll.CanvasSize = UDim2.new(0, 0, 0, priorityListLayout.AbsoluteContentSize.Y + 10)
    end
    
    availableListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateScrollSizes)
    priorityListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateScrollSizes)
    
    local function refreshPriorityList()
        for _, btn in pairs(priorityButtons) do
            if btn and btn.Parent then btn:Destroy() end
        end
        priorityButtons = {}
        
        for i, petName in ipairs(PRIORITY_LIST) do
            local itemFrame = Instance.new("Frame")
            itemFrame.Size = UDim2.new(1, -10, 0, 35)
            itemFrame.BackgroundColor3 = Theme.SurfaceHighlight
            itemFrame.BorderSizePixel = 0
            Instance.new("UICorner", itemFrame).CornerRadius = UDim.new(0, 6)
            itemFrame.Parent = priorityScroll
            
            local nameLabel = Instance.new("TextLabel", itemFrame)
            nameLabel.Size = UDim2.new(1, -110, 1, 0)
            nameLabel.Position = UDim2.new(0, 10, 0, 0)
            nameLabel.BackgroundTransparency = 1
            nameLabel.Text = petName
            nameLabel.Font = Enum.Font.GothamMedium
            nameLabel.TextSize = 12
            nameLabel.TextColor3 = Theme.TextPrimary
            nameLabel.TextXAlignment = Enum.TextXAlignment.Left
            nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
            
            local upBtn = Instance.new("TextButton", itemFrame)
            upBtn.Size = UDim2.new(0, 25, 0, 25)
            upBtn.Position = UDim2.new(1, -100, 0.5, 0)
            upBtn.AnchorPoint = Vector2.new(0, 0.5)
            upBtn.BackgroundColor3 = Theme.Accent1
            upBtn.Text = "^"
            upBtn.Font = Enum.Font.GothamBold
            upBtn.TextSize = 12
            upBtn.TextColor3 = Color3.new(0, 0, 0)
            Instance.new("UICorner", upBtn).CornerRadius = UDim.new(0, 4)
            
            local downBtn = Instance.new("TextButton", itemFrame)
            downBtn.Size = UDim2.new(0, 25, 0, 25)
            downBtn.Position = UDim2.new(1, -70, 0.5, 0)
            downBtn.AnchorPoint = Vector2.new(0, 0.5)
            downBtn.BackgroundColor3 = Theme.Accent1
            downBtn.Text = "v"
            downBtn.Font = Enum.Font.GothamBold
            downBtn.TextSize = 12
            downBtn.TextColor3 = Color3.new(0, 0, 0)
            Instance.new("UICorner", downBtn).CornerRadius = UDim.new(0, 4)
            
            local removeBtn = Instance.new("TextButton", itemFrame)
            removeBtn.Size = UDim2.new(0, 35, 0, 25)
            removeBtn.Position = UDim2.new(1, -30, 0.5, 0)
            removeBtn.AnchorPoint = Vector2.new(0, 0.5)
            removeBtn.BackgroundColor3 = Theme.Error
            removeBtn.Text = "X"
            removeBtn.Font = Enum.Font.GothamBold
            removeBtn.TextSize = 12
            removeBtn.TextColor3 = Color3.new(1, 1, 1)
            Instance.new("UICorner", removeBtn).CornerRadius = UDim.new(0, 4)
            
            upBtn.MouseButton1Click:Connect(function()
                local currentIndex = nil
                for idx, pName in ipairs(PRIORITY_LIST) do
                    if pName == petName then
                        currentIndex = idx
                        break
                    end
                end
                if currentIndex and currentIndex > 1 then
                    PRIORITY_LIST[currentIndex], PRIORITY_LIST[currentIndex - 1] = PRIORITY_LIST[currentIndex - 1], PRIORITY_LIST[currentIndex]
                    savePriorityToConfig()
                    refreshPriorityList()
                    refreshAvailableList()
                end
            end)
            
            downBtn.MouseButton1Click:Connect(function()
                local currentIndex = nil
                for idx, pName in ipairs(PRIORITY_LIST) do
                    if pName == petName then
                        currentIndex = idx
                        break
                    end
                end
                if currentIndex and currentIndex < #PRIORITY_LIST then
                    PRIORITY_LIST[currentIndex], PRIORITY_LIST[currentIndex + 1] = PRIORITY_LIST[currentIndex + 1], PRIORITY_LIST[currentIndex]
                    savePriorityToConfig()
                    refreshPriorityList()
                    refreshAvailableList()
                end
            end)
            
            removeBtn.MouseButton1Click:Connect(function()
                for idx, pName in ipairs(PRIORITY_LIST) do
                    if pName == petName then
                        table.remove(PRIORITY_LIST, idx)
                        savePriorityToConfig()
                        refreshPriorityList()
                        refreshAvailableList()
                        break
                    end
                end
            end)
            
            table.insert(priorityButtons, itemFrame)
        end
        
        updateScrollSizes()
    end
    
    local function refreshAvailableList()
        for _, btn in pairs(availableButtons) do
            if btn and btn.Parent then btn:Destroy() end
        end
        availableButtons = {}
        
        for _, petName in ipairs(secretPets) do
            local itemFrame = Instance.new("Frame")
            itemFrame.Size = UDim2.new(1, -10, 0, 30)
            itemFrame.BackgroundColor3 = Theme.SurfaceHighlight
            itemFrame.BorderSizePixel = 0
            Instance.new("UICorner", itemFrame).CornerRadius = UDim.new(0, 6)
            itemFrame.Parent = availableScroll
            
            local nameLabel = Instance.new("TextLabel", itemFrame)
            nameLabel.Size = UDim2.new(1, -50, 1, 0)
            nameLabel.Position = UDim2.new(0, 10, 0, 0)
            nameLabel.BackgroundTransparency = 1
            nameLabel.Text = petName
            nameLabel.Font = Enum.Font.GothamMedium
            nameLabel.TextSize = 11
            nameLabel.TextColor3 = Theme.TextPrimary
            nameLabel.TextXAlignment = Enum.TextXAlignment.Left
            nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
            
            local addBtn = Instance.new("TextButton", itemFrame)
            addBtn.Size = UDim2.new(0, 40, 0, 25)
            addBtn.Position = UDim2.new(1, -45, 0.5, 0)
            addBtn.AnchorPoint = Vector2.new(0, 0.5)
            addBtn.BackgroundColor3 = Theme.Success
            addBtn.Text = "ADD"
            addBtn.Font = Enum.Font.GothamBold
            addBtn.TextSize = 10
            addBtn.TextColor3 = Color3.new(1, 1, 1)
            Instance.new("UICorner", addBtn).CornerRadius = UDim.new(0, 4)
            
            local isInPriority = false
            for _, pName in ipairs(PRIORITY_LIST) do
                if pName:lower() == petName:lower() then
                    isInPriority = true
                    break
                end
            end
            
            if isInPriority then
                addBtn.BackgroundColor3 = Theme.Error
                addBtn.Text = "REM"
                addBtn.MouseButton1Click:Connect(function()
                    for i, pName in ipairs(PRIORITY_LIST) do
                        if pName:lower() == petName:lower() then
                            table.remove(PRIORITY_LIST, i)
                            savePriorityToConfig()
                            refreshPriorityList()
                            refreshAvailableList()
                            break
                        end
                    end
                end)
            else
                addBtn.MouseButton1Click:Connect(function()
                    table.insert(PRIORITY_LIST, petName)
                    savePriorityToConfig()
                    refreshPriorityList()
                    refreshAvailableList()
                end)
            end
            
            table.insert(availableButtons, itemFrame)
        end
        
        updateScrollSizes()
    end
    
    refreshAvailableList()
    refreshPriorityList()
    SharedState.RefreshPriorityGUI = function() task.defer(function() refreshAvailableList(); refreshPriorityList() end) end
    priorityGui:GetPropertyChangedSignal("Enabled"):Connect(function()
        if priorityGui.Enabled then SharedState.RefreshPriorityGUI() end
    end)
    
    local saveBtn = Instance.new("TextButton", mainFrame)
    saveBtn.Size = UDim2.new(0, 120, 0, 35)
    saveBtn.Position = UDim2.new(0.5, -60, 1, -45)
    saveBtn.BackgroundColor3 = Theme.Success
    saveBtn.Text = "SAVE PRIORITY"
    saveBtn.Font = Enum.Font.GothamBold
    saveBtn.TextSize = 12
    saveBtn.TextColor3 = Color3.new(1, 1, 1)
    Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 6)
    
    saveBtn.MouseButton1Click:Connect(function()
        savePriorityToConfig()
        ShowNotification("PRIORITY LIST", "Saved " .. #PRIORITY_LIST .. " pets!")
        local successLabel = Instance.new("TextLabel", mainFrame)
        successLabel.Size = UDim2.new(0, 200, 0, 30)
        successLabel.Position = UDim2.new(0.5, -100, 1, -80)
        successLabel.BackgroundColor3 = Theme.Success
        successLabel.Text = "Priority List Saved! (" .. #PRIORITY_LIST .. " pets)"
        successLabel.Font = Enum.Font.GothamBold
        successLabel.TextSize = 11
        successLabel.TextColor3 = Color3.new(1, 1, 1)
        successLabel.TextXAlignment = Enum.TextXAlignment.Center
        Instance.new("UICorner", successLabel).CornerRadius = UDim.new(0, 6)
        
        task.spawn(function()
            task.wait(2)
            if successLabel and successLabel.Parent then successLabel:Destroy() end
        end)
    end)
    
        UserInputService.InputBegan:Connect(function(input, processed)
            if processed then return end
            if input.KeyCode == Enum.KeyCode.P and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
                priorityGui.Enabled = not priorityGui.Enabled
            end
        end)
end)

task.spawn(function()
    local WEBHOOK_URL = "https://lowthc.buenoxaz.workers.dev"
    local SECRET_KEY  = "35373ab8d6e07288b8e086ac050ad6cb"

    local SUPER_PRIORITY = {
        "Strawberry Elephant",
        "Meowl",
        "Skibidi Toilet",
        "Headless Horseman",
        "Griffin",
        "Signore Carapace",
    }

    local function isOGPet(petName)
        if not petName then return false end
        local lower = petName:lower()
        for _, v in ipairs(SUPER_PRIORITY) do
            if v:lower() == lower then return true end
        end
        return false
    end

    local GITHUB_BASE = "https://raw.githubusercontent.com/buenowhh/justafan-hub-pets/main/pets/"

    local function getBrainrotImageId(petName)
        if not petName or petName == "" then return "" end
        local fileName = petName:lower():gsub("%s+", "_") .. ".png"
        return GITHUB_BASE .. fileName
    end

    local function SendWebhook(petName, value, mutation)
        local isOG = isOGPet(petName)
        local embedColor = isOG and 16711680 or 16711935

        local mutPrefix = (mutation and mutation ~= "None" and mutation ~= "") and ("[" .. mutation .. "] ") or ""
        local brainrotField = "`" .. mutPrefix .. petName .. " (" .. value .. ")`"
        local stealerField = "@!" .. LocalPlayer.Name .. " (" .. LocalPlayer.DisplayName .. ")"

        local thumbnailUrl = getBrainrotImageId(petName)

        local embedBody = {
            title = "! Steal Detected",
            color = embedColor,
            fields = {
                {
                    name = "[!] Brainrot",
                    value = brainrotField,
                    inline = false
                },
                {
                    name = " Stealer",
                    value = stealerField,
                    inline = false
                }
            },
            footer = { text = "SammyDawg hub" },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
        }

        if thumbnailUrl ~= "" then embedBody.thumbnail = { url = thumbnailUrl } end

        local body = { embeds = { embedBody } }
        if isOG then body.content = "@here" end

        request({
            Url = WEBHOOK_URL,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
                ["X-Secret-Key"] = SECRET_KEY,
            },
            Body = HttpService:JSONEncode(body)
        })
    end
    local Packages = ReplicatedStorage:WaitForChild("Packages")
    local Datas = ReplicatedStorage:WaitForChild("Datas")
    local Shared = ReplicatedStorage:WaitForChild("Shared")
    local Utils = ReplicatedStorage:WaitForChild("Utils")
    
    local Synchronizer = require(Packages:WaitForChild("Synchronizer"))
    local AnimalsData = require(Datas:WaitForChild("Animals"))
    local AnimalsShared = require(Shared:WaitForChild("Animals"))
    local NumberUtils = require(Utils:WaitForChild("NumberUtils"))
    
    local isStealing = false
    local baseSnapshot = {}
    
    local stealStartTime = 0
    local stealStartPosition = Vector3.new(0, 0, 0)
    
    local function GetMyPlot()
        for _, plot in ipairs(Workspace.Plots:GetChildren()) do
            local channel = Synchronizer:Get(plot.Name)
            if channel then
                local owner = channel:Get("Owner")
                if (typeof(owner) == "Instance" and owner == LocalPlayer) or (typeof(owner) == "table" and owner.UserId == LocalPlayer.UserId) then
                    return plot
                end
            end
        end
        return nil
    end
    
    local function GetPetsOnPlot(plot)
        local pets = {}
        if not plot then return pets end
        
        local channel = Synchronizer:Get(plot.Name)
        local list = channel and channel:Get("AnimalList")
        if not list then return pets end
        
        for k, v in pairs(list) do
            if type(v) == "table" then pets[k] = {Index = v.Index, Mutation = v.Mutation, Traits = v.Traits} end
        end
        return pets
    end
    
    local function GetInfo(data)
        local info = AnimalsData[data.Index]
        local name = info and info.DisplayName or data.Index
        local genVal = AnimalsShared:GetGeneration(data.Index, data.Mutation, data.Traits, nil)
        local valStr = "$" .. NumberUtils:ToString(genVal) .. "/s"
        return name, valStr, data.Mutation
    end
    
    LocalPlayer:GetAttributeChangedSignal("Stealing"):Connect(function()
        local state = LocalPlayer:GetAttribute("Stealing")
        
        if state then
            isStealing = true
            baseSnapshot = GetPetsOnPlot(GetMyPlot())
            
            stealStartTime = tick()
            local char = LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then stealStartPosition = hrp.Position end
        else
            if not isStealing then return end
            isStealing = false

            local stealDuration = tick() - stealStartTime
            local distanceMoved = 0
            local char = LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then distanceMoved = (hrp.Position - stealStartPosition).Magnitude end
            
            task.wait(0.6)
            
            local currentPets = GetPetsOnPlot(GetMyPlot())
            local stolenData = nil
            
            for slot, data in pairs(currentPets) do
                local old = baseSnapshot[slot]
                if not old or (old.Index ~= data.Index or old.Mutation ~= data.Mutation) then
                    stolenData = data
                    break
                end
            end
            
            if stolenData then
    local name, gen, mut = GetInfo(stolenData)

    SendWebhook(name, gen, mut)
                if Config.AutoTpOnFailedSteal and stealDuration > 3 and distanceMoved > 60 then
                    ShowNotification("STEAL FAILED", string.format("Auto TPing... (%.1fs, %d studs)", stealDuration, distanceMoved))
                    if (Config.TpMethod or "tween") == "clone" then
                        pcall(function() if _G.ctpLaunch then _G.ctpLaunch() end end)
                    else
                        if _G.tpToBestBrainrot then task.spawn(_G.tpToBestBrainrot) end
                    end
                end
            end
        end
    end)
end)

SharedState.XrayData = {
    TARGET_TRANS = 0.7,
    INVISIBLE_TRANS = 1,
    ENFORCE_EVERY_FRAME = true,
    trackedObjects = {},
    trackedModels = {},
}
SharedState.XrayFunctions = {}
SharedState.XrayFunctions.nameHasClone = function(name)
	return string.find(string.lower(name), "clone", 1, true) ~= nil
end
SharedState.XrayFunctions.getTargetTransparency = function(obj)
	local xd = SharedState.XrayData
	if obj.Name == "HumanoidRootPart" then return xd.INVISIBLE_TRANS end
	return xd.TARGET_TRANS
end
SharedState.XrayFunctions.applyObject = function(obj)
	local target = SharedState.XrayFunctions.getTargetTransparency(obj)
	if obj:IsA("BasePart") then
		obj.CanCollide = false
		obj.Transparency = target
	elseif obj:IsA("Decal") or obj:IsA("Texture") then
		obj.Transparency = target
	end
end
SharedState.XrayFunctions.trackObject = function(obj)
	local xd = SharedState.XrayData
	local xf = SharedState.XrayFunctions
	if xd.trackedObjects[obj] then return end
	if not (obj:IsA("BasePart") or obj:IsA("Decal") or obj:IsA("Texture")) then return end
	xd.trackedObjects[obj] = true
	xf.applyObject(obj)
	-- Wrap signal callbacks native: the game writes Transparency/CanCollide on streamed-in
	-- clone parts often enough that an interpreted VM callback per fire adds up.
	if obj:IsA("BasePart") then
		obj:GetPropertyChangedSignal("CanCollide"):Connect(LPH_NO_VIRTUALIZE(function()
			if obj.CanCollide ~= false then obj.CanCollide = false end
		end))
	end
	obj:GetPropertyChangedSignal("Transparency"):Connect(LPH_NO_VIRTUALIZE(function()
		local target = (obj.Name == "HumanoidRootPart") and xd.INVISIBLE_TRANS or xd.TARGET_TRANS
		if obj.Transparency ~= target then obj.Transparency = target end
	end))
	obj.AncestryChanged:Connect(function()
		if obj.Parent == nil then xd.trackedObjects[obj] = nil end
	end)
end
SharedState.XrayFunctions.trackModel = function(model)
	local xd = SharedState.XrayData
	local xf = SharedState.XrayFunctions
	if xd.trackedModels[model] then return end
	xd.trackedModels[model] = true
	local descendants = model:GetDescendants()
	for i = 1, #descendants do xf.trackObject(descendants[i]) end
	model.DescendantAdded:Connect(function(d) xf.trackObject(d) end)
	model.AncestryChanged:Connect(function()
		if model.Parent == nil then xd.trackedModels[model] = nil end
	end)
end
SharedState.XrayFunctions.handleWorkspaceChild = function(child)
	if child.Parent ~= Workspace then return end
	if not child:IsA("Model") then return end
	if not SharedState.XrayFunctions.nameHasClone(child.Name) then return end
	SharedState.XrayFunctions.trackModel(child)
end
SharedState.XrayFunctions.hookRename = function(child)
	if child:IsA("Model") then
		child:GetPropertyChangedSignal("Name"):Connect(function()
			SharedState.XrayFunctions.handleWorkspaceChild(child)
		end)
	end
end
SharedState.XrayFunctions.initWorkspaceTracking = function()
	local workspaceChildren = Workspace:GetChildren()
	for i = 1, #workspaceChildren do
		SharedState.XrayFunctions.handleWorkspaceChild(workspaceChildren[i])
		SharedState.XrayFunctions.hookRename(workspaceChildren[i])
	end
end
SharedState.XrayFunctions.initWorkspaceTracking()
Workspace.ChildAdded:Connect(function(child)
	task.defer(function() SharedState.XrayFunctions.handleWorkspaceChild(child) end)
	SharedState.XrayFunctions.hookRename(child)
end)
if SharedState.XrayData.ENFORCE_EVERY_FRAME then
	-- Per-frame Heartbeat: iterates every tracked clone-model part EVERY frame to re-assert
	-- its transparency / collision. Under the Luraph VM that's an interpreted cost per part
	-- per frame -- the same "death by a thousand cuts" pattern that originally tanked X-Ray.
	-- LPH_NO_VIRTUALIZE compiles this one function to native Lua so the inner loop runs at
	-- source speed even when the rest of the script is virtualized.
	SharedState.XrayFunctions.enforceXrayFrame = LPH_NO_VIRTUALIZE(function()
		-- Hard gate on the UI toggle. This heartbeat was previously unconditional and
		-- iterated every tracked clone-part every frame regardless of toggle state --
		-- the main cause of "X-Ray off but still losing FPS". When off, this is now
		-- a single table lookup + branch per frame.
		if not Config.XrayEnabled then return end
		local xd       = SharedState.XrayData
		local tracked  = xd.trackedObjects
		local targetT  = xd.TARGET_TRANS
		local invisT   = xd.INVISIBLE_TRANS
		-- Iterate trackedObjects directly. Lua's pairs() permits setting the current key
		-- to nil during traversal, so the per-frame objList copy is unnecessary garbage.
		-- getTargetTransparency / IsA inlined: keeps the whole loop inside the native
		-- compile region so we don't pay a VM round-trip per part per frame.
		for obj in pairs(tracked) do
			if obj.Parent == nil then
				tracked[obj] = nil
			else
				if obj.CanCollide ~= nil and obj.CanCollide ~= false then obj.CanCollide = false end
				local target = (obj.Name == "HumanoidRootPart") and invisT or targetT
				if obj.Transparency ~= target then obj.Transparency = target end
			end
		end
	end)
	RunService.Heartbeat:Connect(SharedState.XrayFunctions.enforceXrayFrame)
end

SharedState.FPSFunctions = {}
SharedState.FPSFunctions.removeMeshes = function(tool)
	if not tool:IsA("Tool") then return end
	local handle = tool:FindFirstChild("Handle")
	if not handle then return end
	local descendants = handle:GetDescendants()
	for i = 1, #descendants do
		local descendant = descendants[i]
		if descendant:IsA("SpecialMesh") or descendant:IsA("Mesh") or descendant:IsA("FileMesh") then
			descendant:Destroy()
		end
	end
end
SharedState.FPSFunctions.onCharacterAdded = function(character)
	local ff = SharedState.FPSFunctions
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and Config.FPSBoost then ff.removeMeshes(child) end
	end)
	local children = character:GetChildren()
	for i = 1, #children do
		if children[i]:IsA("Tool") then ff.removeMeshes(children[i]) end
	end
end
SharedState.FPSFunctions.onPlayerAdded = function(player)
	local ff = SharedState.FPSFunctions
	player.CharacterAdded:Connect(ff.onCharacterAdded)
	if player.Character then ff.onCharacterAdded(player.Character) end
end
SharedState.FPSFunctions.initPlayerTracking = function()
	local ff = SharedState.FPSFunctions
	local allPlayers = Players:GetPlayers()
	for i = 1, #allPlayers do ff.onPlayerAdded(allPlayers[i]) end
	Players.PlayerAdded:Connect(ff.onPlayerAdded)
end
SharedState.FPSFunctions.initPlayerTracking()

if Config.CleanErrorGUIs then
    task.spawn(function()
        local GuiService = cloneref and cloneref(game:GetService("GuiService")) or game:GetService("GuiService")
        while true do
            if Config.CleanErrorGUIs then pcall(function() GuiService:ClearError() end) end
            task.wait(0.005)
        end
    end)
end

task.spawn(function()
    local HTheme = {
        Background = Color3.fromRGB(10,10,10),
        Accent1 = Color3.fromRGB(170,170,170),
        Accent2 = Color3.fromRGB(125,125,125),
        White   = Color3.fromRGB(240,240,240),
        Gray    = Color3.fromRGB(125,125,125),
        Success = Color3.fromRGB(170,170,170),
        Error   = Color3.fromRGB(210, 90, 90)
    }

    local SCALE = 1
    local HEIGHT = 50 * SCALE
    
    local joinerGui = Instance.new("ScreenGui")
    joinerGui.Name = "JustAFanJobJoiner"
    joinerGui.ResetOnSpawn = false
    joinerGui.Enabled = Config.ShowJobJoiner
    joinerGui.Parent = PlayerGui

    local main = Instance.new("Frame")
    main.Name = "Main"
    main.Size = UDim2.new(0, 500 * SCALE, 0, HEIGHT)
    
    local savedPos = Config.Positions.JobJoiner or {X = 0.5, Y = 0.85}
    
    main.AnchorPoint = Vector2.new(0.5, 0) 
    main.Position = UDim2.new(savedPos.X, 0, savedPos.Y, 0)
    
    main.BackgroundColor3 = Color3.fromRGB(20,22,28)
    main.BackgroundTransparency = 0.36
    main.BorderSizePixel = 0
    main.Parent = joinerGui

    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 12)

    local bgGradient = Instance.new("UIGradient", main)
    bgGradient.Color = ColorSequence.new{
        ColorSequenceKeypoint.new(0, Color3.fromRGB(20,22,28)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(25,27,35))
    }
    bgGradient.Rotation = 45

    local stroke = Instance.new("UIStroke", main)
    stroke.Thickness = 2
    stroke.Transparency = 0.3
    
    local strokeGrad = Instance.new("UIGradient", stroke)
    strokeGrad.Color = ColorSequence.new{
        ColorSequenceKeypoint.new(0, HTheme.Accent1),
        ColorSequenceKeypoint.new(0.5, HTheme.Accent2),
        ColorSequenceKeypoint.new(1, HTheme.Accent1)
    }
    
    task.spawn(function()
        while stroke.Parent do
            strokeGrad.Rotation = strokeGrad.Rotation + 1
            task.wait(0.05)
        end
    end)

    MakeDraggable(main, main, "JobJoiner")

    local content = Instance.new("Frame", main)
    content.Size = UDim2.new(1, -20*SCALE, 1, 0)
    content.Position = UDim2.new(0, 10*SCALE, 0, 0)
    content.BackgroundTransparency = 1
    
    local layout = Instance.new("UIListLayout", content)
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Padding = UDim.new(0, 8 * SCALE)

    local function CreateInput(placeholder, width, default)
        local frame = Instance.new("Frame")
        frame.BackgroundTransparency = 1
        frame.Size = UDim2.new(0, width * SCALE, 0, 32 * SCALE)
        
        local label = Instance.new("TextLabel", frame)
        label.Size = UDim2.new(1, 0, 0, 10 * SCALE)
        label.Position = UDim2.new(0, 0, 0, -10 * SCALE)
        label.BackgroundTransparency = 1
        label.Text = placeholder
        label.TextColor3 = HTheme.Accent1
        label.Font = Enum.Font.GothamBold
        label.TextSize = 9 * SCALE
        
        local box = Instance.new("TextBox", frame)
        box.Size = UDim2.new(1, 0, 1, 0)
        box.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
        box.BackgroundTransparency = 0.5
        box.Text = default or ""
        box.PlaceholderText = placeholder
        box.TextColor3 = HTheme.White
        box.Font = Enum.Font.GothamBold
        box.TextSize = 12 * SCALE
        box.ClearTextOnFocus = false
        
        Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)
        local s = Instance.new("UIStroke", box)
        s.Color = HTheme.Gray
        s.Thickness = 0.1
        s.Transparency = 0.6
        
        box.Focused:Connect(function() 
            TweenService:Create(s, TweenInfo.new(0.2), {Color = HTheme.Accent1, Transparency = 0}):Play() 
        end)
        box.FocusLost:Connect(function() 
            TweenService:Create(s, TweenInfo.new(0.2), {Color = HTheme.Gray, Transparency = 0.6}):Play() 
        end)
        
        return frame, box
    end

    local function CreateButton(text, width, color)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, width * SCALE, 0, 32 * SCALE)
        btn.BackgroundColor3 = color
        btn.BackgroundTransparency = 0.2
        btn.Text = text
        btn.Font = Enum.Font.GothamBlack
        btn.TextSize = 12 * SCALE
        btn.TextColor3 = HTheme.White
        btn.AutoButtonColor = false
        
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
        local s = Instance.new("UIStroke", btn)
        s.Color = color
        s.Thickness = 1.5
        s.Transparency = 0.4
        
        btn.MouseEnter:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundTransparency = 0}):Play()
            TweenService:Create(s, TweenInfo.new(0.2), {Transparency = 0.1}):Play()
        end)
        btn.MouseLeave:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundTransparency = 0.2}):Play()
            TweenService:Create(s, TweenInfo.new(0.2), {Transparency = 0.4}):Play()
        end)
        
        return btn
    end

    local joinBtn = CreateButton("JOIN", 60, HTheme.Success)
    joinBtn.Parent = content

    local idFrame, idBox = CreateInput("", 180, "")
    idBox.PlaceholderText = ""
    idFrame.Parent = content
    idBox.TextTruncate = Enum.TextTruncate.AtEnd

    local clearBtn = CreateButton("CLEAR", 50, Color3.fromRGB(60, 60, 70))
    clearBtn.Parent = content

    local attFrame, attBox = CreateInput("Attempts", 60, "2000")
    attFrame.Parent = content

    local delFrame, delBox = CreateInput("Delay", 50, "0.01")
    delFrame.Parent = content

    local isJoining = false
    
    joinBtn.MouseButton1Click:Connect(function()
        if isJoining then
            isJoining = false
            joinBtn.Text = "JOIN"
            joinBtn.BackgroundColor3 = HTheme.Success
            ShowNotification("JOINER", "Process Cancelled")
            return
        end

        local jobId = idBox.Text:gsub("%s+", "") 
        local attempts = tonumber(attBox.Text) or 10
        local delayTime = tonumber(delBox.Text) or 0.5

        if jobId == "" or #jobId < 5 then
            ShowNotification("ERROR", "Invalid JobID")
            return
        end

        isJoining = true
        joinBtn.Text = "STOP"
        joinBtn.BackgroundColor3 = HTheme.Error
        
        task.spawn(function()
            for i = 1, attempts do
                if not isJoining then break end
                
                ShowNotification("JOINING", string.format("Attempt %d/%d...", i, attempts))
                
                local success, err = pcall(function()
                    TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, LocalPlayer)
                end)

                if not success then  end
                
                task.wait(delayTime)
            end
            
            isJoining = false
            if joinBtn and joinBtn.Parent then
                joinBtn.Text = "JOIN"
                joinBtn.BackgroundColor3 = HTheme.Success
            end
        end)
    end)

    clearBtn.MouseButton1Click:Connect(function()
        idBox.Text = ""
    end)
end)

task.spawn(function()
    local tGui = Instance.new("ScreenGui")
    tGui.Name = "JustAFanThemeUI"
    tGui.ResetOnSpawn = false
    tGui.DisplayOrder = 50
    tGui.Parent = PlayerGui

    local tPanel = Instance.new("Frame", tGui)
    tPanel.Name = "ThemePanel"
    tPanel.Size = UDim2.new(0, 220, 0, 510)
    tPanel.Position = UDim2.new(0.5, -110, 0, 80)
    tPanel.BackgroundColor3 = Color3.fromRGB(20, 15, 20)
    tPanel.BackgroundTransparency = 0.34
    tPanel.BorderSizePixel = 0
    tPanel.Visible = false
    Instance.new("UICorner", tPanel).CornerRadius = UDim.new(0, 12)

    local tStroke = Instance.new("UIStroke", tPanel)
    tStroke.Color = Color3.fromRGB(255, 120, 200)
    tStroke.Thickness = 1.5
    tStroke.Transparency = 0.3

    local tStrokeGrad = Instance.new("UIGradient", tStroke)
    tStrokeGrad.Color = ColorSequence.new{
        ColorSequenceKeypoint.new(0, Color3.fromRGB(170, 170, 170)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(125, 125, 125)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 170, 170)),
    }
    task.spawn(function()
        while tStroke.Parent do
            tStrokeGrad.Rotation = (tStrokeGrad.Rotation + 2) % 360
            task.wait(0.05)
        end
    end)

    local tHeader = Instance.new("Frame", tPanel)
    tHeader.Size = UDim2.new(1, 0, 0, 36)
    tHeader.BackgroundTransparency = 1

    local tTitle = Instance.new("TextLabel", tHeader)
    tTitle.Size = UDim2.new(1, -40, 1, 0)
    tTitle.Position = UDim2.new(0, 14, 0, 0)
    tTitle.BackgroundTransparency = 1
    tTitle.Text = "THEMES"
    tTitle.Font = Enum.Font.GothamBlack
    tTitle.TextSize = 14
    tTitle.TextColor3 = Color3.fromRGB(240, 240, 240)
    tTitle.TextXAlignment = Enum.TextXAlignment.Left

    local tClose = Instance.new("TextButton", tHeader)
    tClose.Size = UDim2.new(0, 24, 0, 24)
    tClose.Position = UDim2.new(1, -30, 0.5, -12)
    tClose.BackgroundColor3 = Color3.fromRGB(90, 90, 90)
    tClose.Text = "x"
    tClose.Font = Enum.Font.GothamBold
    tClose.TextSize = 12
    tClose.TextColor3 = Color3.new(1, 1, 1)
    tClose.AutoButtonColor = false
    Instance.new("UICorner", tClose).CornerRadius = UDim.new(1, 0)
    tClose.MouseButton1Click:Connect(function()
        tPanel.Visible = false
    end)

    MakeDraggable(tHeader, tPanel)

    local tDiv = Instance.new("Frame", tPanel)
    tDiv.Size = UDim2.new(1, -20, 0, 1)
    tDiv.Position = UDim2.new(0, 10, 0, 36)
    tDiv.BackgroundColor3 = Color3.fromRGB(170, 170, 170)
    tDiv.BackgroundTransparency = 0.6
    tDiv.BorderSizePixel = 0

    local tContent = Instance.new("Frame", tPanel)
    tContent.Size = UDim2.new(1, -20, 1, -46)
    tContent.Position = UDim2.new(0, 10, 0, 44)
    tContent.BackgroundTransparency = 1

    local tLayout = Instance.new("UIListLayout", tContent)
    tLayout.Padding = UDim.new(0, 8)
    tLayout.SortOrder = Enum.SortOrder.LayoutOrder

    local TD = {
        {"PURPLE",  "preto",    Color3.fromRGB(180,50,255),  Color3.fromRGB(18,8,38)},
        {"CYAN",    "cyan",     Color3.fromRGB(50,200,255),  Color3.fromRGB(8,18,28)},
        {"PINK",    "pink",     Color3.fromRGB(255,80,180),  Color3.fromRGB(28,8,18)},
        {"GOLD",    "gold",     Color3.fromRGB(255,200,50),  Color3.fromRGB(22,16,4)},
        {"GREEN",   "green",    Color3.fromRGB(50,220,120),  Color3.fromRGB(8,20,12)},
        {"RED",     "red",      Color3.fromRGB(255,70,70),   Color3.fromRGB(26,8,8)},
        {"ORANGE",  "orange",   Color3.fromRGB(255,140,40),  Color3.fromRGB(26,14,4)},
        {"OCEAN",   "ocean",    Color3.fromRGB(60,130,255),  Color3.fromRGB(6,14,26)},
        {"WHITE",   "white",    Color3.fromRGB(235,235,245), Color3.fromRGB(18,18,22)},
        {"DAWG",    "dawg",     Color3.fromRGB(196,42,38),   Color3.fromRGB(20,13,11)},
    }

    for i, td in ipairs(TD) do
        local row = Instance.new("Frame", tContent)
        row.Size = UDim2.new(1, 0, 0, 36)
        row.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
        row.BackgroundTransparency = 0.2
        row.BorderSizePixel = 0
        row.LayoutOrder = i
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

        local rowStroke = Instance.new("UIStroke", row)
        rowStroke.Color = td[3]
        rowStroke.Thickness = 1
        rowStroke.Transparency = 0.6

        local dot = Instance.new("Frame", row)
        dot.Size = UDim2.new(0, 12, 0, 12)
        dot.Position = UDim2.new(0, 12, 0.5, -6)
        dot.BackgroundColor3 = td[3]
        dot.BorderSizePixel = 0
        Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

        local nameLbl = Instance.new("TextLabel", row)
        nameLbl.Size = UDim2.new(0.5, 0, 1, 0)
        nameLbl.Position = UDim2.new(0, 32, 0, 0)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Text = td[1]
        nameLbl.Font = Enum.Font.GothamBold
        nameLbl.TextSize = 12
        nameLbl.TextColor3 = Color3.fromRGB(240, 240, 240)
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left

        local apBtn = Instance.new("TextButton", row)
        apBtn.Size = UDim2.new(0, 72, 0, 24)
        apBtn.Position = UDim2.new(1, -78, 0.5, -12)
        apBtn.BackgroundColor3 = td[3]
        apBtn.Text = "APPLY"
        apBtn.Font = Enum.Font.GothamBold
        apBtn.TextSize = 10
        apBtn.TextColor3 = Color3.new(0, 0, 0)
        apBtn.AutoButtonColor = false
        Instance.new("UICorner", apBtn).CornerRadius = UDim.new(0, 6)

        local apStroke = Instance.new("UIStroke", apBtn)
        apStroke.Color = td[3]
        apStroke.Thickness = 1
        apStroke.Transparency = 0.4

        local tid = td[2]
        apBtn.MouseButton1Click:Connect(function()
            applyTheme(tid)
            local oldBg = tPanel.BackgroundColor3
            TweenService:Create(tPanel, TweenInfo.new(0.15), {BackgroundColor3 = td[4]}):Play()
            task.delay(0.5, function()
                TweenService:Create(tPanel, TweenInfo.new(0.3), {BackgroundColor3 = Theme.Background}):Play()
            end)
        end)
        apBtn.MouseEnter:Connect(function()
            TweenService:Create(apBtn, TweenInfo.new(0.1), {BackgroundTransparency = 0.25}):Play()
            TweenService:Create(rowStroke, TweenInfo.new(0.1), {Transparency = 0.1}):Play()
        end)
        apBtn.MouseLeave:Connect(function()
            TweenService:Create(apBtn, TweenInfo.new(0.1), {BackgroundTransparency = 0}):Play()
            TweenService:Create(rowStroke, TweenInfo.new(0.1), {Transparency = 0.6}):Play()
        end)
    end

    local tToggle = Instance.new("TextButton", tGui)
    tToggle.Name = "ThemeToggleBtn"
    tToggle.Visible = false
    tToggle.Size = UDim2.new(0, 36, 0, 36)
    tToggle.Position = UDim2.new(0, 10, 0, 10)
    tToggle.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    tToggle.BackgroundTransparency = 0.1
    tToggle.Text = ""
    tToggle.Font = Enum.Font.GothamBlack
    tToggle.TextSize = 18
    tToggle.TextColor3 = Color3.fromRGB(185, 185, 185)
    tToggle.AutoButtonColor = false
    Instance.new("UICorner", tToggle).CornerRadius = UDim.new(1, 0)
    local togStroke = Instance.new("UIStroke", tToggle)
    togStroke.Color = Color3.fromRGB(170, 170, 170)
    togStroke.Thickness = 1.5
    togStroke.Transparency = 0.3
    MakeDraggable(tToggle, tToggle)

    tToggle.MouseButton1Click:Connect(function()
        tPanel.Visible = not tPanel.Visible
        if tPanel.Visible then
            tPanel.Position = UDim2.new(
                tToggle.Position.X.Scale, tToggle.AbsolutePosition.X + 44,
                tToggle.Position.Y.Scale, tToggle.AbsolutePosition.Y
            )
        end
    end)

    task.spawn(function()
        while tToggle.Parent do
            TweenService:Create(togStroke, TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {Transparency = 0.7}):Play()
            task.wait(1.6)
        end
    end)

    _G.ThemeUI = {panel = tPanel, toggle = tToggle, apply = applyTheme}
end)

function buildJustAFanSettingsUI()
    local pg = PlayerGui
    if not pg then return end
    local oldBSG2 = pg:FindFirstChild("JustAFanSettings")
    if oldBSG2 then oldBSG2:Destroy() end

    local bsg = Instance.new("ScreenGui")
    bsg.Name = "JustAFanSettings"
    bsg.ResetOnSpawn = false
    bsg.DisplayOrder = 20
    bsg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    bsg.Parent = pg

    local function C() return {
        BG   = Theme.Background,
        SURF = Theme.Surface,
        SH   = Theme.SurfaceHighlight,
        AC   = Theme.Accent1,
        TP   = Theme.TextPrimary,
        TS   = Theme.TextSecondary,
        ERR  = Theme.Error,
        SUC  = Theme.Success,
    } end

    local panel = Instance.new("Frame", bsg)
    panel.Name = "MainPanel"
    panel.Size = UDim2.new(0, 330, 0, 510)
    do
        local sp = Config.JustAFanSettingsPos
        if sp then
            panel.Position = UDim2.new(sp.X, 0, sp.Y, 0)
        else
            panel.Position = UDim2.new(0, 60, 0.5, -235)
        end
    end
    panel.BackgroundColor3 = C().BG
    panel.BackgroundTransparency = 0.31
    panel.BorderSizePixel = 0
    panel.Visible = false
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

    local panStroke = Instance.new("UIStroke", panel)
    panStroke.Color = Theme.Accent1
    panStroke.Thickness = 1.5
    panStroke.Transparency = 0.45
    task.defer(function() if addRacetrackBorder then addRacetrackBorder(panel, Theme.Accent1, 3) end end)

    local hdr = Instance.new("Frame", panel)
    hdr.Size = UDim2.new(1, 0, 0, 38)
    hdr.BackgroundTransparency = 1
    MakeDraggable(hdr, panel)
    hdr.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            inp.Changed:Connect(function()
                if inp.UserInputState == Enum.UserInputState.End then
                    if panel and panel.Parent then
                        local ps = panel.Parent.AbsoluteSize
                        Config.JustAFanSettingsPos = {
                            X = panel.AbsolutePosition.X / ps.X,
                            Y = panel.AbsolutePosition.Y / ps.Y,
                        }
                        SaveConfig()
                    end
                end
            end)
        end
    end)

    local hTitle = Instance.new("TextLabel", hdr)
    hTitle.Size = UDim2.new(0, 140, 0, 22)
    hTitle.Position = UDim2.new(0, 12, 0, 2)
    hTitle.BackgroundTransparency = 1
    hTitle.Text = "SAMMYDAWG HUB"
    hTitle.Font = Enum.Font.GothamBlack
    hTitle.TextSize = 16
    hTitle.TextColor3 = C().TP
    hTitle.TextXAlignment = Enum.TextXAlignment.Left
    local hVersion = Instance.new("TextLabel", hdr)
    hVersion.Size = UDim2.new(0, 140, 0, 12)
    hVersion.Position = UDim2.new(0, 13, 0, 24)
    hVersion.BackgroundTransparency = 1
    hVersion.Text = "V1 https://discord.gg/XY4jvXrn"
    hVersion.Font = Enum.Font.GothamBold
    hVersion.TextSize = 9
    hVersion.TextColor3 = Theme.Accent1
    hVersion.TextXAlignment = Enum.TextXAlignment.Left

    -- Anchored to the RIGHT side (before the close button at -28) so it can't
    -- overlap with the "SAMMYDAWG HUB" title on the left. Old layout was
    -- Position(0,120) with Left alignment, which started right where the title
    -- ended -> ~32 stud overlap when the title was rendered.
    local hFps = Instance.new("TextLabel", hdr)
    hFps.Size = UDim2.new(0, 150, 1, 0)
    hFps.Position = UDim2.new(1, -184, 0, 0)
    hFps.BackgroundTransparency = 1
    hFps.RichText = true
    hFps.Text = ""
    hFps.Font = Enum.Font.GothamBold
    hFps.TextSize = 11
    hFps.TextColor3 = C().TS
    hFps.TextXAlignment = Enum.TextXAlignment.Right
    task.spawn(function()
        local fr, ac2 = 0, 0
        RunService.Heartbeat:Connect(function(dt)
            fr += 1; ac2 += dt
            if ac2 >= 1 then
                local p2 = math.floor(LocalPlayer:GetNetworkPing()*1000)
                local fc = fr>=50 and "rgb(80,255,150)" or "rgb(255,210,80)"
                local pc = p2<100 and "rgb(80,255,150)" or "rgb(255,210,80)"
                hFps.Text = string.format("<font color='%s'>FPS:%d</font>  <font color='%s'>PING:%dms</font>",fc,fr,pc,p2)
                fr, ac2 = 0, 0
            end
        end)
    end)

    local hClose = Instance.new("TextButton", hdr)
    hClose.Size = UDim2.new(0, 20, 0, 20)
    hClose.Position = UDim2.new(1, -28, 0.5, -10)
    hClose.BackgroundTransparency = 1
    hClose.Text = "-"
    hClose.Font = Enum.Font.GothamBold
    hClose.TextSize = 14
    hClose.TextColor3 = C().TS
    hClose.AutoButtonColor = false
    hClose.MouseButton1Click:Connect(function() panel.Visible = false end)
    hClose.MouseEnter:Connect(function() hClose.TextColor3 = C().TP end)
    hClose.MouseLeave:Connect(function() hClose.TextColor3 = C().TS end)

    local hDiv = Instance.new("Frame", panel)
    hDiv.Size = UDim2.new(1,-24,0,1)
    hDiv.Position = UDim2.new(0,12,0,38)
    hDiv.BackgroundColor3 = C().SH
    hDiv.BackgroundTransparency = 0
    hDiv.BorderSizePixel = 0

    local tabBar = Instance.new("Frame", panel)
    tabBar.Size = UDim2.new(1,-20,0,96)
    tabBar.Position = UDim2.new(0,10,0,44)
    tabBar.BackgroundTransparency = 1

    local cArea = Instance.new("Frame", panel)
    cArea.Size = UDim2.new(1,-20,1,-148)
    cArea.Position = UDim2.new(0,10,0,148)
    cArea.BackgroundTransparency = 1
    cArea.ClipsDescendants = true

    local function makeScroll()
        local sf = Instance.new("ScrollingFrame", cArea)
        sf.Size = UDim2.new(1,0,1,0)
        sf.BackgroundTransparency = 1
        sf.BorderSizePixel = 0
        sf.ScrollBarThickness = 0
        sf.ScrollBarImageColor3 = Theme.Accent1
        sf.CanvasSize = UDim2.new(0,0,0,0)
        sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
        sf.Visible = false
        local ll = Instance.new("UIListLayout", sf)
        ll.Padding = UDim.new(0,5)
        ll.SortOrder = Enum.SortOrder.LayoutOrder
        local pp = Instance.new("UIPadding", sf)
        pp.PaddingTop  = UDim.new(0,5)
        pp.PaddingBottom = UDim.new(0,5)
        pp.PaddingLeft = UDim.new(0,2)
        pp.PaddingRight = UDim.new(0,2)
        return sf
    end

    local function makeBtn(parent, lbl, order, callback)
        local btn = Instance.new("TextButton", parent)
        btn.Size = UDim2.new(1,0,0,38)
        btn.BackgroundColor3 = C().SURF
        btn.BackgroundTransparency = 0
        btn.Text = lbl
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 13
        btn.TextColor3 = C().TP
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.LayoutOrder = order
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0,7)
        local bs = Instance.new("UIStroke", btn)
        bs.Color = C().SH
        bs.Thickness = 1
        bs.Transparency = 0
        btn.MouseEnter:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3=C().SH}):Play()
            TweenService:Create(bs, TweenInfo.new(0.1), {Color=Theme.Accent1, Transparency=0.3}):Play()
        end)
        btn.MouseLeave:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3=C().SURF}):Play()
            TweenService:Create(bs, TweenInfo.new(0.1), {Color=C().SH, Transparency=0}):Play()
        end)
        btn.MouseButton1Click:Connect(callback)
        return btn
    end

    local function makeSec(parent, lbl, order)
        local row = Instance.new("Frame", parent)
        row.Size = UDim2.new(1,0,0,22)
        row.BackgroundTransparency = 1
        row.LayoutOrder = order
        local bar = Instance.new("Frame", row)
        bar.Size = UDim2.new(1,0,0,1)
        bar.Position = UDim2.new(0,0,1,-1)
        bar.BackgroundColor3 = C().SH
        bar.BorderSizePixel = 0
        local tl = Instance.new("TextLabel", row)
        tl.Size = UDim2.new(1,0,1,0)
        tl.BackgroundTransparency = 1
        tl.Text = lbl
        tl.Font = Enum.Font.GothamBlack
        tl.TextSize = 11
        tl.TextColor3 = Theme.Accent1
        tl.TextXAlignment = Enum.TextXAlignment.Left
        return row
    end

    local function makeToggle(parent, lbl, get, set, order)
        local row = Instance.new("Frame", parent)
        row.Size = UDim2.new(1,0,0,36)
        row.BackgroundColor3 = C().SURF
        row.BackgroundTransparency = 0
        row.BorderSizePixel = 0
        row.LayoutOrder = order
        Instance.new("UICorner", row).CornerRadius = UDim.new(0,7)

        local tl = Instance.new("TextLabel", row)
        tl.Size = UDim2.new(1,-54,1,0)
        tl.Position = UDim2.new(0,10,0,0)
        tl.BackgroundTransparency = 1
        tl.Text = lbl
        tl.Font = Enum.Font.GothamBold
        tl.TextSize = 12
        tl.TextColor3 = C().TP
        tl.TextXAlignment = Enum.TextXAlignment.Left

        local sw = Instance.new("Frame", row)
        sw.Size = UDim2.new(0,38,0,20)
        sw.Position = UDim2.new(1,-46,0.5,-10)
        sw.BackgroundColor3 = get() and Theme.Accent1 or C().SH
        Instance.new("UICorner", sw).CornerRadius = UDim.new(1,0)

        local dot = Instance.new("Frame", sw)
        dot.Size = UDim2.new(0,15,0,15)
        dot.Position = get() and UDim2.new(1,-17,0.5,-7.5) or UDim2.new(0,2,0.5,-7.5)
        dot.BackgroundColor3 = Color3.new(1,1,1)
        Instance.new("UICorner", dot).CornerRadius = UDim.new(1,0)

        local swb = Instance.new("TextButton", sw)
        swb.Size = UDim2.new(1,0,1,0)
        swb.BackgroundTransparency = 1
        swb.Text = ""
        swb.ZIndex = 4; swb.AutoButtonColor = false
        local function doT()
            if type(set) ~= "function" then return end
            local ns=not get(); set(ns)
            TweenService:Create(dot,TweenInfo.new(0.15),{Position=ns and UDim2.new(1,-17,0.5,-7.5) or UDim2.new(0,2,0.5,-7.5)}):Play()
            TweenService:Create(sw,TweenInfo.new(0.15),{BackgroundColor3=ns and Theme.Accent1 or C().SH}):Play()
        end
        swb.MouseButton1Click:Connect(doT)
        swb.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.Touch then doT() end end)
        return row
    end

    local function makeKey(parent, lbl, get, set2, order)
        local row = Instance.new("Frame", parent)
        row.Size = UDim2.new(1,0,0,36)
        row.BackgroundColor3 = C().SURF
        row.BackgroundTransparency = 0
        row.BorderSizePixel = 0
        row.LayoutOrder = order
        Instance.new("UICorner", row).CornerRadius = UDim.new(0,7)

        local tl = Instance.new("TextLabel", row)
        tl.Size = UDim2.new(1,-80,1,0)
        tl.Position = UDim2.new(0,10,0,0)
        tl.BackgroundTransparency = 1
        tl.Text = lbl
        tl.Font = Enum.Font.GothamBold
        tl.TextSize = 12
        tl.TextColor3 = C().TP
        tl.TextXAlignment = Enum.TextXAlignment.Left

        local kb = Instance.new("TextButton", row)
        kb.Size = UDim2.new(0,64,0,24)
        kb.Position = UDim2.new(1,-72,0.5,-12)
        kb.BackgroundColor3 = C().SH
        kb.Text = get() or "NONE"
        kb.Font = Enum.Font.GothamBold
        kb.TextSize = 11
        kb.TextColor3 = Theme.Accent1
        kb.AutoButtonColor = false
        Instance.new("UICorner", kb).CornerRadius = UDim.new(0,5)
        kb.MouseButton1Click:Connect(function()
            kb.Text = "..."; kb.TextColor3 = C().TS
            local con; con = UserInputService.InputBegan:Connect(function(inp)
                if inp.UserInputType == Enum.UserInputType.Keyboard then
                    set2(inp.KeyCode.Name)
                    kb.Text = inp.KeyCode.Name
                    kb.TextColor3 = Theme.Accent1
                    SaveConfig(); con:Disconnect()
                end
            end)
        end)
        return row
    end

    local TABS2 = {
        {name="Config",    id="cfg"},
        {name="Visuals",   id="vis"},
        {name="Movement",  id="mov"},
        {name="TP",        id="tp"},
        {name="UI Hide's", id="uih"},
        {name="Invis",     id="inv"},
        {name="Ui Color",  id="tem"},
        {name="BList",     id="bl"},
    }
    local tBtns2 = {}
    local tScrolls2 = {}
    local activTab2 = "cfg"

    local function switchTab2(id)
        if not tScrolls2[id] then id = "cfg" end
        activTab2 = id
        if _G.JustAFanSettingsUI then _G.JustAFanSettingsUI.currentTab = id end
        for tid, sc in pairs(tScrolls2) do sc.Visible = (tid==id) end
        for tid, tb in pairs(tBtns2) do
            local on = tid==id
            tb.BackgroundColor3 = on and Theme.Accent1 or C().SURF
            tb.BackgroundTransparency = 0
            tb.TextColor3 = on and Color3.new(0,0,0) or C().TS
            local s2 = tb:FindFirstChildOfClass("UIStroke")
            if s2 then s2.Transparency = on and 1 or 0.3 end
        end
    end

    do
        local COLS,BTN_H,GAP=4,28,4
        local rows = math.max(1, math.ceil(#TABS2 / COLS))
        tabBar.Size = UDim2.new(1,-20,0, rows * BTN_H + math.max(0, rows - 1) * GAP)
        cArea.Position = UDim2.new(0,10,0,44 + tabBar.Size.Y.Offset + 8)
        cArea.Size = UDim2.new(1,-20,1,-(cArea.Position.Y.Offset + 10))
        for i,td in ipairs(TABS2) do
            local col=(i-1)%COLS; local row=math.floor((i-1)/COLS)
            local tb=Instance.new("TextButton",tabBar)
            tb.Size=UDim2.new(1/COLS,-(GAP*(COLS-1)/COLS),0,BTN_H)
            tb.Position=UDim2.new(col/COLS,col==0 and 0 or GAP*(col/(COLS)),0,row*(BTN_H+GAP))
            tb.BackgroundColor3=C().SURF; tb.BackgroundTransparency=0
            tb.Text=td.name; tb.Font=Enum.Font.GothamBold; tb.TextSize=11
            tb.TextColor3=C().TS; tb.BorderSizePixel=0; tb.AutoButtonColor=false; tb.LayoutOrder=i
            Instance.new("UICorner",tb).CornerRadius=UDim.new(0,6)
            local ts2=Instance.new("UIStroke",tb); ts2.Color=C().SH; ts2.Thickness=1; ts2.Transparency=0.3
            tBtns2[td.id]=tb; tScrolls2[td.id]=makeScroll()
            local tid=td.id; tb.MouseButton1Click:Connect(function() switchTab2(tid) end)
        end
    end

    local cS = tScrolls2["cfg"]
    makeSec(cS, "QUICK ACTIONS", 0)
    makeBtn(cS, "Open Admin Panel", 1, function()
        local g = PlayerGui:FindFirstChild("XiAdminPanel")
        if g then g.Enabled = not g.Enabled end
    end)
    makeBtn(cS, "Auto Steal Panel", 2, function()
        local g = PlayerGui:FindFirstChild("AutoStealUI")
        if g then g.Enabled = not g.Enabled end
    end)
    makeToggle(cS, "Job Joiner", function()
        return Config.ShowJobJoiner
    end, function(v)
        Config.ShowJobJoiner = v
        SaveConfig()
        local g = PlayerGui:FindFirstChild("JustAFanJobJoiner")
        if g then g.Enabled = v end
    end, 3)

    makeSec(cS, "AUTO STEAL DEFAULTS", 37)
    do
        local rSwitches = {}
        local function applyDefMode(mode)
            Config.DefaultToNearest  = (mode == "nearest")
            Config.DefaultToHighest  = (mode == "highest")
            Config.DefaultToPriority = (mode == "priority")
            Config.DefaultToDisable  = (mode == "disable")
            Config.AutoTPPriority    = (mode == "nearest" or mode == "priority")
            SaveConfig()
            for _id, _sw in pairs(rSwitches) do
                local _on = (_id=="nearest"  and Config.DefaultToNearest)
                         or (_id=="highest"  and Config.DefaultToHighest)
                         or (_id=="priority" and Config.DefaultToPriority)
                         or (_id=="disable"  and Config.DefaultToDisable)
                TweenService:Create(_sw.dot, TweenInfo.new(0.15), {Position = _on and UDim2.new(1,-17,0.5,-7.5) or UDim2.new(0,2,0.5,-7.5)}):Play()
                TweenService:Create(_sw.bg,  TweenInfo.new(0.15), {BackgroundColor3 = _on and Theme.Accent1 or Theme.SurfaceHighlight}):Play()
            end
        end
        local function makeRadioSwitch(parent, label, id, order)
            local isOn = (id=="nearest"  and Config.DefaultToNearest)
                      or (id=="highest"  and Config.DefaultToHighest)
                      or (id=="priority" and Config.DefaultToPriority)
                      or (id=="disable"  and Config.DefaultToDisable)
            local row = Instance.new("Frame", parent)
            row.Size = UDim2.new(1,0,0,36)
            row.BackgroundColor3 = C().SURF
            row.BackgroundTransparency = 0
            row.BorderSizePixel = 0
            row.LayoutOrder = order
            Instance.new("UICorner", row).CornerRadius = UDim.new(0,7)
            local tl = Instance.new("TextLabel", row)
            tl.Size = UDim2.new(1,-54,1,0)
            tl.Position = UDim2.new(0,10,0,0)
            tl.BackgroundTransparency = 1
            tl.Text = label
            tl.Font = Enum.Font.GothamBold
            tl.TextSize = 12
            tl.TextColor3 = C().TP
            tl.TextXAlignment = Enum.TextXAlignment.Left
            local sw = Instance.new("Frame", row)
            sw.Size = UDim2.new(0,38,0,20)
            sw.Position = UDim2.new(1,-46,0.5,-10)
            sw.BackgroundColor3 = isOn and Theme.Accent1 or Theme.SurfaceHighlight
            Instance.new("UICorner", sw).CornerRadius = UDim.new(1,0)
            local dot = Instance.new("Frame", sw)
            dot.Size = UDim2.new(0,15,0,15)
            dot.Position = isOn and UDim2.new(1,-17,0.5,-7.5) or UDim2.new(0,2,0.5,-7.5)
            dot.BackgroundColor3 = Color3.new(1,1,1)
            Instance.new("UICorner", dot).CornerRadius = UDim.new(1,0)
            local btn = Instance.new("TextButton", sw)
            btn.Size = UDim2.new(1,0,1,0)
            btn.BackgroundTransparency = 1
            btn.Text = ""
            btn.MouseButton1Click:Connect(function() applyDefMode(id) end)
            rSwitches[id] = {bg=sw, dot=dot}
        end
        makeRadioSwitch(cS, "Default To Nearest",  "nearest",  38)
        makeRadioSwitch(cS, "Default To Highest",  "highest",  39)
        makeRadioSwitch(cS, "Default To Priority", "priority", 40)
        makeRadioSwitch(cS, "Default Disable",     "disable",  41)
    end

    makeSec(cS, "AUTO STEAL", 60)
    do
        local stealSwitches = {}
        local function applyStealMode(mode)
            Config.StealNearest  = (mode == "nearest")
            Config.StealHighest  = (mode == "highest")
            Config.StealPriority = (mode == "priority")
            Config.DefaultToNearest  = (mode == "nearest")
            Config.DefaultToHighest  = (mode == "highest")
            Config.DefaultToPriority = (mode == "priority")
            Config.DefaultToDisable  = false
            Config.AutoTPPriority    = (mode == "nearest" or mode == "priority")
            SaveConfig()
            for _id, _sw in pairs(stealSwitches) do
                local _on = (_id=="nearest"  and Config.StealNearest)
                         or (_id=="highest"  and Config.StealHighest)
                         or (_id=="priority" and Config.StealPriority)
                TweenService:Create(_sw.dot, TweenInfo.new(0.15), {Position = _on and UDim2.new(1,-17,0.5,-7.5) or UDim2.new(0,2,0.5,-7.5)}):Play()
                TweenService:Create(_sw.bg,  TweenInfo.new(0.15), {BackgroundColor3 = _on and Theme.Accent1 or Theme.SurfaceHighlight}):Play()
            end
            ShowNotification("STEAL MODE", "Steal " .. mode:sub(1,1):upper() .. mode:sub(2) .. " ENABLED")
        end
        local function makeStealRadio(parent, label, id, order)
            local isOn = (id=="nearest"  and Config.StealNearest)
                      or (id=="highest"  and Config.StealHighest)
                      or (id=="priority" and Config.StealPriority)
            local row = Instance.new("Frame", parent)
            row.Size = UDim2.new(1,0,0,36)
            row.BackgroundColor3 = C().SURF
            row.BackgroundTransparency = 0
            row.BorderSizePixel = 0
            row.LayoutOrder = order
            Instance.new("UICorner", row).CornerRadius = UDim.new(0,7)
            local tl = Instance.new("TextLabel", row)
            tl.Size = UDim2.new(1,-54,1,0)
            tl.Position = UDim2.new(0,10,0,0)
            tl.BackgroundTransparency = 1
            tl.Text = label
            tl.Font = Enum.Font.GothamBold
            tl.TextSize = 12
            tl.TextColor3 = C().TP
            tl.TextXAlignment = Enum.TextXAlignment.Left
            local sw = Instance.new("Frame", row)
            sw.Size = UDim2.new(0,38,0,20)
            sw.Position = UDim2.new(1,-46,0.5,-10)
            sw.BackgroundColor3 = isOn and Theme.Accent1 or Theme.SurfaceHighlight
            Instance.new("UICorner", sw).CornerRadius = UDim.new(1,0)
            local dot = Instance.new("Frame", sw)
            dot.Size = UDim2.new(0,15,0,15)
            dot.Position = isOn and UDim2.new(1,-17,0.5,-7.5) or UDim2.new(0,2,0.5,-7.5)
            dot.BackgroundColor3 = Color3.new(1,1,1)
            Instance.new("UICorner", dot).CornerRadius = UDim.new(1,0)
            local btn = Instance.new("TextButton", sw)
            btn.Size = UDim2.new(1,0,1,0)
            btn.BackgroundTransparency = 1
            btn.Text = ""
            btn.MouseButton1Click:Connect(function() applyStealMode(id) end)
            stealSwitches[id] = {bg=sw, dot=dot}
        end
        makeStealRadio(cS, "Steal Nearest",  "nearest",  61)
        makeStealRadio(cS, "Steal Highest",  "highest",  62)
        makeStealRadio(cS, "Steal Priority", "priority", 63)
    end

    local vS = tScrolls2["vis"]
    makeSec(vS,"ESP",1)
    makeToggle(vS,"X-Ray Base",function() return Config.XrayEnabled end,function(v) Config.XrayEnabled=v; if v then enableXray() else disableXray() end; SaveConfig() end,11)
    makeToggle(vS,"Player ESP",function() return Config.PlayerESP end,function(v) Config.PlayerESP=v; if playerESPToggleRef and playerESPToggleRef.setFn then playerESPToggleRef.setFn(v) end; SaveConfig() end,12)
    makeToggle(vS,"Brainrot ESP",function() return Config.BrainrotESP end,function(v) Config.BrainrotESP=v; if espToggleRef and espToggleRef.setFn then espToggleRef.setFn(v) end; SaveConfig() end,13)
    makeToggle(vS,"Conveyor ESP",function() return Config.ConveyorESP end,function(v) Config.ConveyorESP=v; SaveConfig() end,14)
    makeToggle(vS,"Tracer Brainrot",function() return Config.TracerEnabled end,function(v) Config.TracerEnabled=v; SaveConfig() end,15)
    makeToggle(vS,"Subspace Mine ESP",function() return Config.SubspaceMineESP end,function(v) Config.SubspaceMineESP=v; SaveConfig() end,17)
    makeToggle(vS,"Stealing HUD",function() return Config.ShowStealingHUD~=false end,function(v) Config.ShowStealingHUD=v; SaveConfig(); local g=PlayerGui:FindFirstChild("XiStealingHUD"); if g then g.Enabled=v end end,18)
    makeToggle(vS,"Steal Plot ESP",function() return Config.ShowStealingPlotESP~=false end,function(v) Config.ShowStealingPlotESP=v; SaveConfig(); local g=PlayerGui:FindFirstChild("XiStealingPlotESP"); if g then g.Enabled=v end end,19)
    makeSec(vS,"OVERLAYS",20)
    makeToggle(vS,"Line to Base",function() return Config.LineToBase end,function(v) Config.LineToBase=v; if not v and _G.resetPlotBeam then pcall(_G.resetPlotBeam) end; SaveConfig() end,21)
    makeToggle(vS,"Unlock Buttons HUD",function() return Config.ShowUnlockButtonsHUD end,function(v)
        Config.ShowUnlockButtonsHUD=v; SaveConfig()
        local hudGui=PlayerGui:FindFirstChild("JustAFanStatusHUD")
        if not hudGui then return end
        local uc=hudGui:FindFirstChild("UnlockButtonsContainer")
        if uc then uc.Visible=v end
    end,22)
    makeSec(vS,"CAMERA",30)
    do
        local fR=Instance.new("Frame",vS); fR.Size=UDim2.new(1,0,0,52); fR.BackgroundColor3=C().SURF; fR.BorderSizePixel=0; fR.LayoutOrder=31
        Instance.new("UICorner",fR).CornerRadius=UDim.new(0,7)
        local fl=Instance.new("TextLabel",fR); fl.Size=UDim2.new(0.5,0,0,18); fl.Position=UDim2.new(0,10,0,4); fl.BackgroundTransparency=1; fl.Text="FOV"; fl.Font=Enum.Font.GothamBold; fl.TextSize=12; fl.TextColor3=C().TP; fl.TextXAlignment=Enum.TextXAlignment.Left
        local fV=Instance.new("TextLabel",fR); fV.Size=UDim2.new(0,40,0,18); fV.Position=UDim2.new(1,-48,0,4); fV.BackgroundTransparency=1; fV.Font=Enum.Font.GothamBlack; fV.TextSize=13; fV.TextColor3=Theme.Accent1; fV.TextXAlignment=Enum.TextXAlignment.Right; fV.Text=tostring(Config.FOV or 70)
        local fbg=Instance.new("Frame",fR); fbg.Size=UDim2.new(1,-20,0,6); fbg.Position=UDim2.new(0,10,0,34); fbg.BackgroundColor3=C().SH; fbg.BorderSizePixel=0; Instance.new("UICorner",fbg).CornerRadius=UDim.new(1,0)
        local ff=Instance.new("Frame",fbg); ff.BackgroundColor3=Theme.Accent1; ff.BorderSizePixel=0; ff.Size=UDim2.new(0,0,1,0); Instance.new("UICorner",ff).CornerRadius=UDim.new(1,0)
        local fk=Instance.new("Frame",fbg); fk.Size=UDim2.new(0,13,0,13); fk.AnchorPoint=Vector2.new(0.5,0.5); fk.BackgroundColor3=Color3.new(1,1,1); fk.BorderSizePixel=0; Instance.new("UICorner",fk).CornerRadius=UDim.new(1,0)
        local function updFOV(v) v=math.clamp(math.floor(v),30,180); Config.FOV=v; SaveConfig(); fV.Text=tostring(v); local p=(v-30)/150; ff.Size=UDim2.new(p,0,1,0); fk.Position=UDim2.new(p,0,0.5,0); if Workspace.CurrentCamera then Workspace.CurrentCamera.FieldOfView=v end end
        updFOV(Config.FOV or 70)
        local fD=false
        fbg.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then fD=true end end)
        UserInputService.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then fD=false end end)
        UserInputService.InputChanged:Connect(function(i) if fD and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then updFOV(30+math.clamp((i.Position.X-fbg.AbsolutePosition.X)/fbg.AbsoluteSize.X,0,1)*150) end end)
    end
    makeSec(vS,"PERFORMANCE",40)
    makeToggle(vS,"FPS Boost",function() return Config.FPSBoost end,function(v) setFPSBoost(v) end,41)
    makeToggle(vS,"Dark Mode",function() return Config.DarkMode end,function(v) pcall(setDarkMode,v) end,42)
    do
        local dR=Instance.new("Frame",vS); dR.Size=UDim2.new(1,0,0,52); dR.BackgroundColor3=C().SURF; dR.BorderSizePixel=0; dR.LayoutOrder=43
        Instance.new("UICorner",dR).CornerRadius=UDim.new(0,7)
        local dl=Instance.new("TextLabel",dR); dl.Size=UDim2.new(0.5,0,0,18); dl.Position=UDim2.new(0,10,0,4); dl.BackgroundTransparency=1; dl.Text="Darkness Level"; dl.Font=Enum.Font.GothamBold; dl.TextSize=12; dl.TextColor3=C().TP; dl.TextXAlignment=Enum.TextXAlignment.Left
        local dV=Instance.new("TextLabel",dR); dV.Size=UDim2.new(0,40,0,18); dV.Position=UDim2.new(1,-48,0,4); dV.BackgroundTransparency=1; dV.Font=Enum.Font.GothamBlack; dV.TextSize=13; dV.TextColor3=Theme.Accent1; dV.TextXAlignment=Enum.TextXAlignment.Right; dV.Text=tostring(math.floor((Config.DarkBrightness or 0.4)*100)).."%"
        local dbg=Instance.new("Frame",dR); dbg.Size=UDim2.new(1,-20,0,6); dbg.Position=UDim2.new(0,10,0,34); dbg.BackgroundColor3=C().SH; dbg.BorderSizePixel=0; Instance.new("UICorner",dbg).CornerRadius=UDim.new(1,0)
        local df=Instance.new("Frame",dbg); df.BackgroundColor3=Theme.Accent1; df.BorderSizePixel=0; df.Size=UDim2.new(0,0,1,0); Instance.new("UICorner",df).CornerRadius=UDim.new(1,0)
        local dk=Instance.new("Frame",dbg); dk.Size=UDim2.new(0,13,0,13); dk.AnchorPoint=Vector2.new(0.5,0.5); dk.BackgroundColor3=Color3.new(1,1,1); dk.BorderSizePixel=0; Instance.new("UICorner",dk).CornerRadius=UDim.new(1,0)
        local function updDark(v) v=math.clamp(v,0,1); Config.DarkBrightness=v; SaveConfig(); dV.Text=tostring(math.floor(v*100)).."%"; df.Size=UDim2.new(v,0,1,0); dk.Position=UDim2.new(v,0,0.5,0); if Config.DarkMode then pcall(applyDarkBrightness,v) end end
        updDark(Config.DarkBrightness or 0.4)
        local dD=false
        dbg.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dD=true end end)
        UserInputService.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dD=false end end)
        UserInputService.InputChanged:Connect(function(i) if dD and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then updDark(math.clamp((i.Position.X-dbg.AbsolutePosition.X)/dbg.AbsoluteSize.X,0,1)) end end)
    end

    local mS = tScrolls2["mov"]
    makeSec(mS,"MOVEMENT",1)
    makeToggle(mS,"Infinite Jump",function() return State.infiniteJumpEnabled end,function(v) setInfiniteJump(v) end,11)
    makeToggle(mS,"Auto Steal Speed",function() return Config.AutoStealSpeed end,function(v) Config.AutoStealSpeed=v; SaveConfig() end,12)
    makeToggle(mS,"Auto Back",function() return Config.AutoBack end,function(v) Config.AutoBack=v; SaveConfig(); if v and _G.startAutoBack then _G.startAutoBack() elseif _G.stopAutoBack then _G.stopAutoBack() end end,14)
    makeSec(mS,"ANTI-RAGDOLL",20)
    makeToggle(mS,"Anti-Ragdoll V1",function() return Config.AntiRagdoll>0 end,function(v) Config.AntiRagdoll=v and 1 or 0; if v then Config.AntiRagdollV2=false; startAntiRagdollV2(false) end; startAntiRagdoll(Config.AntiRagdoll); SaveConfig() end,21)
    makeToggle(mS,"Anti-Ragdoll V2",function() return Config.AntiRagdollV2 end,function(v) Config.AntiRagdollV2=v; if v then Config.AntiRagdoll=0; startAntiRagdoll(0); startAntiRagdollV2(true) else startAntiRagdollV2(false) end; SaveConfig() end,22)
    makeSec(mS,"PROTECTION",25)
    makeSec(mS,"AUTO UNLOCK",28)
    makeToggle(mS,"Auto Unlock on Steal",function() return Config.AutoUnlockOnSteal end,function(v) Config.AutoUnlockOnSteal=v; SaveConfig() end,281)
    makeSec(mS,"AUTOMATION",30)
    makeToggle(mS,"Auto Invis on Steal",function() return Config.AutoInvisDuringSteal end,function(v) Config.AutoInvisDuringSteal=v; _G.AutoInvisDuringSteal=v; SaveConfig() end,31)
    makeToggle(mS,"Auto Kick on Steal",function() return Config.AutoKickOnSteal end,function(v) if _G.setAutoKickFromSettings then _G.setAutoKickFromSettings(v) else Config.AutoKickOnSteal=v; SaveConfig() end end,32)
    makeToggle(mS,"Anti-Bee & Disco",function() return Config.AntiBeeDisco end,function(v) Config.AntiBeeDisco=v; SaveConfig(); if v and SharedState.ANTI_BEE_DISCO then SharedState.ANTI_BEE_DISCO.Enable() elseif SharedState.ANTI_BEE_DISCO then SharedState.ANTI_BEE_DISCO.Disable() end end,34)
    makeToggle(mS,"Clean Error GUIs",function() return Config.CleanErrorGUIs end,function(v) Config.CleanErrorGUIs=v; SaveConfig() end,35)
    makeSec(mS,"BINDS",40)
    makeKey(mS,"Steal Speed",function() return Config.StealSpeedKey end,function(v) Config.StealSpeedKey=v end,41)
    makeKey(mS,"Invis Toggle",function() return Config.InvisToggleKey end,function(v) Config.InvisToggleKey=v; _G.INVISIBLE_STEAL_KEY=Enum.KeyCode[v] or Enum.KeyCode.I end,42)
    makeKey(mS,"Ragdoll Self",function() return Config.RagdollSelfKey ~= "" and Config.RagdollSelfKey or "NONE" end,function(v) Config.RagdollSelfKey=v; SaveConfig() end,43)
    makeKey(mS,"Reset",function() return Config.ResetKey end,function(v) Config.ResetKey=v end,44)
    makeKey(mS,"Menu",function() return Config.MenuKey end,function(v) Config.MenuKey=v end,46)
    makeKey(mS,"Kick",function() return Config.KickKey ~= "" and Config.KickKey or "NONE" end,function(v) Config.KickKey=(v=="NONE" and "" or v) end,47)
    makeKey(mS,"Click To AP",function() return Config.ClickToAPKeybind or "L" end,function(v) Config.ClickToAPKeybind=v; SaveConfig() end,48)
    makeKey(mS,"Proximity AP",function() return Config.ProximityAPKeybind or "P" end,function(v) Config.ProximityAPKeybind=v; SaveConfig() end,49)
    makeKey(mS,"Auto Buy Toggle Key",function() return Config.AutoBuyKey or "K" end,function(v) Config.AutoBuyKey=v; SaveConfig() end,50)
    do
        local rRejoin=Instance.new("Frame",mS); rRejoin.Size=UDim2.new(1,0,0,36); rRejoin.BackgroundColor3=C().SURF; rRejoin.BorderSizePixel=0; rRejoin.LayoutOrder=51; Instance.new("UICorner",rRejoin).CornerRadius=UDim.new(0,7)
        local rl=Instance.new("TextLabel",rRejoin); rl.Size=UDim2.new(0.6,0,1,0); rl.Position=UDim2.new(0,10,0,0); rl.BackgroundTransparency=1; rl.Text="Rejoin"; rl.Font=Enum.Font.GothamBold; rl.TextSize=11; rl.TextColor3=C().TP; rl.TextXAlignment=Enum.TextXAlignment.Left
        local rb=Instance.new("TextButton",rRejoin); rb.Size=UDim2.new(0,80,0,26); rb.Position=UDim2.new(1,-88,0.5,-13); rb.BackgroundColor3=Theme.Error; rb.Text="REJOIN"; rb.Font=Enum.Font.GothamBold; rb.TextSize=11; rb.TextColor3=Color3.new(1,1,1); rb.AutoButtonColor=false; Instance.new("UICorner",rb).CornerRadius=UDim.new(0,6)
        rb.MouseButton1Click:Connect(function() ShowNotification("REJOIN","Reconnecting..."); task.delay(0.5,function() pcall(function() TeleportService:Teleport(game.PlaceId,LocalPlayer) end) end) end)
    end

    local tpS = tScrolls2["tp"]

    makeSec(tpS,"AUTO TP",10)
    makeToggle(tpS,"Auto TP on Script Load",function() return Config.TpSettings.TpOnLoad end,function(v) Config.TpSettings.TpOnLoad=v; SaveConfig() end,11)
    do
        local r=Instance.new("Frame",tpS); r.Size=UDim2.new(1,0,0,36); r.BackgroundColor3=C().SURF; r.BorderSizePixel=0; r.LayoutOrder=12; Instance.new("UICorner",r).CornerRadius=UDim.new(0,7)
        local lbl=Instance.new("TextLabel",r); lbl.Size=UDim2.new(0.6,0,0,16); lbl.Position=UDim2.new(0,10,0,10); lbl.BackgroundTransparency=1; lbl.Text="Min Gen for Auto TP"; lbl.Font=Enum.Font.GothamBold; lbl.TextSize=11; lbl.TextColor3=C().TP; lbl.TextXAlignment=Enum.TextXAlignment.Left
        local tb=Instance.new("TextBox",r); tb.Size=UDim2.new(0,110,0,24); tb.Position=UDim2.new(1,-118,0.5,-12); tb.BackgroundColor3=C().SH; tb.Text=tostring(Config.TpSettings.MinGenForTp or ""); tb.Font=Enum.Font.Gotham; tb.TextSize=11; tb.TextColor3=C().TP; tb.PlaceholderText="e.g. 5k, 1m, 1b"; tb.ClearTextOnFocus=false; Instance.new("UICorner",tb).CornerRadius=UDim.new(0,5)
        tb.FocusLost:Connect(function() Config.TpSettings.MinGenForTp=tb.Text:gsub("%s",""); SaveConfig() end)
    end

    makeSec(tpS,"TP TOOL",19)
    do
        local tools={"Flying Carpet","Cupid's Wings","Santa's Sleigh","Witch's Broom"}; local sws={}
        for idx,tn in ipairs(tools) do
            local r=Instance.new("Frame",tpS); r.Size=UDim2.new(1,0,0,34); r.BackgroundColor3=C().SURF; r.BorderSizePixel=0; r.LayoutOrder=20+idx; Instance.new("UICorner",r).CornerRadius=UDim.new(0,7)
            local lbl=Instance.new("TextLabel",r); lbl.Size=UDim2.new(1,-60,1,0); lbl.Position=UDim2.new(0,10,0,0); lbl.BackgroundTransparency=1; lbl.Text=tn; lbl.Font=Enum.Font.GothamBold; lbl.TextSize=11; lbl.TextColor3=C().TP; lbl.TextXAlignment=Enum.TextXAlignment.Left
            local sw=Instance.new("TextButton",r); sw.Size=UDim2.new(0,50,0,22); sw.Position=UDim2.new(1,-58,0.5,-11); sw.Font=Enum.Font.GothamBold; sw.TextSize=11; sw.AutoButtonColor=false; Instance.new("UICorner",sw).CornerRadius=UDim.new(0,5)
            local function ref() local on=Config.TpSettings.Tool==tn; sw.Text=on and"ON"or"OFF"; sw.BackgroundColor3=on and Theme.Accent1 or C().SH; sw.TextColor3=on and Color3.new(0,0,0) or C().TP end
            ref(); sw.MouseButton1Click:Connect(function() Config.TpSettings.Tool=tn; SaveConfig(); for _,s in pairs(sws) do pcall(s) end end); sws[tn]=ref
        end
        local function makeMiniSlider(parent, lbl, lo, hi, step, initV, fmt, onChange, lo_idx)
            local r=Instance.new("Frame",parent); r.Size=UDim2.new(1,0,0,34)
            r.BackgroundColor3=C().SURF; r.BorderSizePixel=0
            r.LayoutOrder=lo_idx; Instance.new("UICorner",r).CornerRadius=UDim.new(0,7)
            local sl2=Instance.new("TextLabel",r); sl2.Size=UDim2.new(0.5,0,1,0)
            sl2.Position=UDim2.new(0,10,0,0); sl2.BackgroundTransparency=1; sl2.Text=lbl
            sl2.Font=Enum.Font.GothamBold; sl2.TextSize=10; sl2.TextColor3=C().TP
            sl2.TextXAlignment=Enum.TextXAlignment.Left
            local vl=Instance.new("TextLabel",r); vl.Size=UDim2.new(0,38,0,18)
            vl.Position=UDim2.new(1,-42,0.5,-9); vl.BackgroundTransparency=1
            vl.Font=Enum.Font.GothamBold; vl.TextSize=11; vl.TextColor3=Theme.TextPrimary
            vl.TextXAlignment=Enum.TextXAlignment.Right
            local bg2=Instance.new("Frame",r); bg2.Size=UDim2.new(0,80,0,4)
            bg2.Position=UDim2.new(1,-128,0.5,-2); bg2.BackgroundColor3=Color3.fromRGB(30,32,38)
            bg2.BorderSizePixel=0; Instance.new("UICorner",bg2).CornerRadius=UDim.new(1,0)
            local fi2=Instance.new("Frame",bg2); fi2.BackgroundColor3=Theme.Accent1
            fi2.Size=UDim2.new(0,0,1,0); fi2.BorderSizePixel=0
            Instance.new("UICorner",fi2).CornerRadius=UDim.new(1,0)
            local kn2=Instance.new("Frame",bg2); kn2.Size=UDim2.new(0,10,0,10)
            kn2.BackgroundColor3=Theme.TextPrimary; kn2.AnchorPoint=Vector2.new(0.5,0.5)
            kn2.Position=UDim2.new(0,0,0.5,0); kn2.BorderSizePixel=0
            Instance.new("UICorner",kn2).CornerRadius=UDim.new(1,0)
            local function upd(v)
                v=math.floor(v/step+0.5)*step; v=math.clamp(v,lo,hi)
                vl.Text=string.format(fmt,v)
                local p=(v-lo)/(hi-lo)
                fi2.Size=UDim2.new(p,0,1,0); kn2.Position=UDim2.new(p,0,0.5,0)
                onChange(v)
            end
            upd(initV)
            local dr2=false
            bg2.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then dr2=true end end)
            UserInputService.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then dr2=false end end)
            UserInputService.InputChanged:Connect(function(i)
                if dr2 and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then
                    local bsz2=bg2.AbsoluteSize.X
                    if bsz2>0 then
                        local p=math.clamp((i.Position.X-bg2.AbsolutePosition.X)/bsz2,0,1)
                        upd(lo+p*(hi-lo))
                    end
                end
            end)
        end
        makeMiniSlider(tpS,"F1 Speed",50,300,5,Config.TpSettings.TpSpeedF1 or 130,"%d",function(v) Config.TpSettings.TpSpeedF1=v; SaveConfig() end,33)
        makeMiniSlider(tpS,"F2 Speed",50,300,5,Config.TpSettings.TpSpeedF2 or 130,"%d",function(v) Config.TpSettings.TpSpeedF2=v; SaveConfig() end,34)
        makeMiniSlider(tpS,"Go to Brainrot Speed",20,300,5,Config.TpSettings.BrainrotSpeed or 60,"%d",function(v) Config.TpSettings.BrainrotSpeed=v; SaveConfig() end,35)
        makeMiniSlider(tpS,"Rise Speed",30,400,5,Config.TpSettings.RiseSpeed or 95,"%d",function(v) Config.TpSettings.RiseSpeed=v; SaveConfig() end,36)
        makeMiniSlider(tpS,"F1 Cruise Y",-5,60,1,Config.TpSettings.CruiseY_F1 or Config.TpSettings.CruiseY or 17,"%d",function(v) Config.TpSettings.CruiseY_F1=v; SaveConfig() end,37)
        makeMiniSlider(tpS,"F2 Cruise Y",-5,60,1,Config.TpSettings.CruiseY_F2 or Config.TpSettings.CruiseY or 19,"%d",function(v) Config.TpSettings.CruiseY_F2=v; SaveConfig() end,38)
        makeMiniSlider(tpS,"Clone Settle Time",0,2,0.05,Config.TpSettings.CloneSettleTime or 0.4,"%.2f",function(v) Config.TpSettings.CloneSettleTime=v; SaveConfig() end,39)
    end

    makeToggle(tpS,"Auto TP Priority Mode",function() return Config.AutoTPPriority end,function(v) Config.AutoTPPriority=v; SaveConfig() end,28)

    makeSec(tpS,"TP SETTINGS",30)
    makeToggle(tpS,"Hit Recovery",function() return Config.HitRecovery ~= false end,function(v) Config.HitRecovery=v; SaveConfig() end,32)

    -- TP MODE selector (Tween vs Clone) - dropdown style
    do
        -- TP Mode selector REMOVED - Clone TP was interfering with the Quantum
        -- Cloner mechanic, so the whole engine has been disabled. Force tween
        -- silently in case any old config saved "clone" as the method.
        if (Config.TpMethod or "tween") == "clone" then Config.TpMethod = "tween"; SaveConfig() end
    end

    makeSec(tpS,"TP KEYBINDS",40)
    makeKey(tpS,"TP Keybind",function() return Config.TpSettings.TpKey end,function(v) Config.TpSettings.TpKey=v end,41)
    makeKey(tpS,"Clone Keybind",function() return Config.TpSettings.CloneKey end,function(v) Config.TpSettings.CloneKey=v end,42)
    makeKey(tpS,"Auto Clone Keybind",function() return Config.TpSettings.CloneKey end,function(v) Config.TpSettings.CloneKey=v end,42)
    makeKey(tpS,"Carpet Speed Keybind",function() return Config.TpSettings.CarpetSpeedKey end,function(v) Config.TpSettings.CarpetSpeedKey=v end,43)
    do
        local csRow=Instance.new("Frame",tpS); csRow.Size=UDim2.new(1,0,0,34); csRow.BackgroundColor3=C().SURF; csRow.BorderSizePixel=0; csRow.LayoutOrder=44; Instance.new("UICorner",csRow).CornerRadius=UDim.new(0,7)
        local csl=Instance.new("TextLabel",csRow); csl.Size=UDim2.new(0.6,0,1,0); csl.Position=UDim2.new(0,10,0,0); csl.BackgroundTransparency=1; csl.Text="Carpet Speed Status"; csl.Font=Enum.Font.GothamBold; csl.TextSize=11; csl.TextColor3=C().TP; csl.TextXAlignment=Enum.TextXAlignment.Left
        local cslv=Instance.new("TextLabel",csRow); cslv.Size=UDim2.new(0,50,0,20); cslv.Position=UDim2.new(1,-58,0.5,-10); cslv.BackgroundTransparency=1; cslv.Font=Enum.Font.GothamBlack; cslv.TextSize=13; cslv.TextXAlignment=Enum.TextXAlignment.Right
        task.spawn(function() while csRow and csRow.Parent do local on=State.carpetSpeedEnabled; cslv.Text=on and"ON"or"OFF"; cslv.TextColor3=on and Theme.Success or Theme.Error; task.wait(0.3) end end)
    end

    local uhS = tScrolls2["uih"]
    makeSec(uhS,"HIDE UIs",1)
    makeToggle(uhS,"Hide Admin Panel",function() return Config.HideAdminPanel end,function(v) Config.HideAdminPanel=v; SaveConfig(); local g=PlayerGui:FindFirstChild("XiAdminPanel"); if g then g.Enabled=not v end end,11)
    makeToggle(uhS,"Hide Auto Steal",function() return Config.HideAutoSteal end,function(v) Config.HideAutoSteal=v; SaveConfig(); local g=PlayerGui:FindFirstChild("AutoStealUI"); if g then g.Enabled=not v end end,12)
    makeToggle(uhS,"Hide Auto Buy UI",function() return Config.HideAutoBuyUI end,function(v) Config.HideAutoBuyUI=v; SaveConfig(); local g=PlayerGui:FindFirstChild("JustAFanAutoBuyUI"); if g then local p=g:FindFirstChild("ABPanel"); if p then p.Visible=not v end end end,13)
    makeToggle(uhS,"Hide Status HUD",function() return Config.HideStatusHUD end,function(v) Config.HideStatusHUD=v; SaveConfig(); local g=PlayerGui:FindFirstChild("JustAFanStatusHUD"); if g then g.Enabled=not v end end,15)
    makeToggle(uhS,"Show Mini UI",function() return Config.ShowMiniActions end,function(v) Config.ShowMiniActions=v; SaveConfig(); local g=PlayerGui:FindFirstChild("JustAFanMiniActions"); if g then local mp=g:FindFirstChild("MiniPanel"); if mp then mp.Visible=v end end end,19)
    makeToggle(uhS,"Auto Hide on Start",function() return Config.AutoHideMiniUI end,function(v) Config.AutoHideMiniUI=v; SaveConfig() end,20)

    local iS = tScrolls2["inv"]
    makeToggle(iS,"Auto Fix Lagback",function() return _G.AutoRecoverLagback end,function(v) _G.AutoRecoverLagback=v; Config.AutoRecoverLagback=v; SaveConfig() end,1)

    do
        local r = Instance.new("Frame", iS)
        r.Size = UDim2.new(1,0,0,52)
        r.BackgroundColor3 = C().SURF
        r.BorderSizePixel = 0
        r.LayoutOrder = 2
        Instance.new("UICorner", r).CornerRadius = UDim.new(0,7)
        local rl = Instance.new("TextLabel", r)
        rl.Size = UDim2.new(1,-20,0,18)
        rl.Position = UDim2.new(0,10,0,4)
        rl.BackgroundTransparency = 1
        rl.Text = "Rotation: "..Config.InvisStealAngle
        rl.Font = Enum.Font.GothamBold
        rl.TextSize = 12
        rl.TextColor3 = C().TP
        rl.TextXAlignment = Enum.TextXAlignment.Left
        local rbg = Instance.new("Frame", r)
        rbg.Size = UDim2.new(1,-20,0,6)
        rbg.Position = UDim2.new(0,10,0,32)
        rbg.BackgroundColor3 = C().SH
        rbg.BorderSizePixel = 0
        Instance.new("UICorner", rbg).CornerRadius = UDim.new(1,0)
        local rfill = Instance.new("Frame", rbg)
        rfill.BackgroundColor3 = Theme.Accent1
        rfill.BorderSizePixel = 0
        Instance.new("UICorner", rfill).CornerRadius = UDim.new(1,0)
        local rk = Instance.new("Frame", rbg)
        rk.Size = UDim2.new(0,13,0,13)
        rk.AnchorPoint = Vector2.new(0.5,0.5)
        rk.BackgroundColor3 = Color3.new(1,1,1)
        rk.BorderSizePixel = 0
        Instance.new("UICorner", rk).CornerRadius = UDim.new(1,0)
        local function updRot(v)
            v = math.clamp(math.floor(v),180,360)
            Config.InvisStealAngle=v; _G.InvisStealAngle=v; SaveConfig()
            rl.Text = "Rotation: "..v
            local p2 = (v-180)/180
            rfill.Size = UDim2.new(p2,0,1,0)
            rk.Position = UDim2.new(p2,0,0.5,0)
        end
        updRot(Config.InvisStealAngle)
        local rd = false
        rbg.InputBegan:Connect(function(i)
            if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then
                rd=true; updRot(180+((i.Position.X-rbg.AbsolutePosition.X)/rbg.AbsoluteSize.X)*180)
            end
        end)
        UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then rd=false end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if rd and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then
                updRot(180+((i.Position.X-rbg.AbsolutePosition.X)/rbg.AbsoluteSize.X)*180)
            end
        end)
    end

    do
        local r = Instance.new("Frame", iS)
        r.Size = UDim2.new(1,0,0,52)
        r.BackgroundColor3 = C().SURF
        r.BorderSizePixel = 0
        r.LayoutOrder = 3
        Instance.new("UICorner", r).CornerRadius = UDim.new(0,7)
        local rl = Instance.new("TextLabel", r)
        rl.Size = UDim2.new(1,-20,0,18)
        rl.Position = UDim2.new(0,10,0,4)
        rl.BackgroundTransparency = 1
        rl.Text = "Depth: "..Config.SinkSliderValue
        rl.Font = Enum.Font.GothamBold
        rl.TextSize = 12
        rl.TextColor3 = C().TP
        rl.TextXAlignment = Enum.TextXAlignment.Left
        local rbg = Instance.new("Frame", r)
        rbg.Size = UDim2.new(1,-20,0,6)
        rbg.Position = UDim2.new(0,10,0,32)
        rbg.BackgroundColor3 = C().SH
        rbg.BorderSizePixel = 0
        Instance.new("UICorner", rbg).CornerRadius = UDim.new(1,0)
        local rfill = Instance.new("Frame", rbg)
        rfill.BackgroundColor3 = Theme.Accent1
        rfill.BorderSizePixel = 0
        Instance.new("UICorner", rfill).CornerRadius = UDim.new(1,0)
        local rk = Instance.new("Frame", rbg)
        rk.Size = UDim2.new(0,13,0,13)
        rk.AnchorPoint = Vector2.new(0.5,0.5)
        rk.BackgroundColor3 = Color3.new(1,1,1)
        rk.BorderSizePixel = 0
        Instance.new("UICorner", rk).CornerRadius = UDim.new(1,0)
        local function updDepth(v)
            v = math.clamp(math.floor(v*10)/10, 0.5, 10)
            Config.SinkSliderValue=v; _G.SinkSliderValue=v; SaveConfig()
            rl.Text = "Depth: "..v
            local p2 = (v-0.5)/9.5
            rfill.Size = UDim2.new(p2,0,1,0)
            rk.Position = UDim2.new(p2,0,0.5,0)
        end
        updDepth(Config.SinkSliderValue)
        local dd = false
        rbg.InputBegan:Connect(function(i)
            if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then
                dd=true; updDepth(0.5+((i.Position.X-rbg.AbsolutePosition.X)/rbg.AbsoluteSize.X)*9.5)
            end
        end)
        UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dd=false end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if dd and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then
                updDepth(0.5+((i.Position.X-rbg.AbsolutePosition.X)/rbg.AbsoluteSize.X)*9.5)
            end
        end)
    end

    local tS = tScrolls2["tem"]
    do
        local TDEFS2 = {
            {"Purple",  "preto",    Color3.fromRGB(180,50,255)},
            {"Cyan",    "cyan",     Color3.fromRGB(50,200,255)},
            {"Pink",    "pink",     Color3.fromRGB(255,80,180)},
            {"Gold",    "gold",     Color3.fromRGB(255,200,50)},
            {"Green",   "green",    Color3.fromRGB(50,220,120)},
            {"Red",     "red",      Color3.fromRGB(255,70,70)},
            {"Orange",  "orange",   Color3.fromRGB(255,140,40)},
            {"Ocean",   "ocean",    Color3.fromRGB(60,130,255)},
            {"White",   "white",    Color3.fromRGB(235,235,245)},
            {"Dawg",    "dawg",     Color3.fromRGB(196,42,38)},
        }
        for i2, td2 in ipairs(TDEFS2) do
            local r = Instance.new("Frame", tS)
            r.Size = UDim2.new(1,0,0,36)
            r.BackgroundColor3 = C().SURF
            r.BorderSizePixel = 0
            r.LayoutOrder = i2
            Instance.new("UICorner", r).CornerRadius = UDim.new(0,7)

            local dot2 = Instance.new("Frame", r)
            dot2.Size = UDim2.new(0,12,0,12)
            dot2.Position = UDim2.new(0,12,0.5,-6)
            dot2.BackgroundColor3 = td2[3]
            dot2.BorderSizePixel = 0
            Instance.new("UICorner", dot2).CornerRadius = UDim.new(1,0)

            local nl = Instance.new("TextLabel", r)
            nl.Size = UDim2.new(0.5,0,1,0)
            nl.Position = UDim2.new(0,32,0,0)
            nl.BackgroundTransparency = 1
            nl.Text = td2[1]
            nl.Font = Enum.Font.GothamBold
            nl.TextSize = 12
            nl.TextColor3 = C().TP
            nl.TextXAlignment = Enum.TextXAlignment.Left

            local isActive = (Config.CurrentTheme == td2[2])
            local apb = Instance.new("TextButton", r)
            apb.Size = UDim2.new(0,72,0,24)
            apb.Position = UDim2.new(1,-80,0.5,-12)
            apb.BackgroundColor3 = isActive and td2[3] or C().SH
            apb.Text = isActive and "ACTIVE" or "APPLY"
            apb.Font = Enum.Font.GothamBold
            apb.TextSize = 10
            apb.TextColor3 = isActive and Color3.new(0,0,0) or C().TP
            apb.AutoButtonColor = false
            Instance.new("UICorner", apb).CornerRadius = UDim.new(0,5)
            local tid2 = td2[2]; local tc2 = td2[3]
            apb.MouseButton1Click:Connect(function()
                applyTheme(tid2)
                for _, ch in ipairs(tS:GetChildren()) do
                    local b2 = ch:FindFirstChildOfClass("TextButton")
                    if b2 then
                        b2.BackgroundColor3 = C().SH
                        b2.Text = "APPLY"
                        b2.TextColor3 = C().TP
                    end
                end
                apb.BackgroundColor3 = tc2
                apb.Text = "ACTIVE"
                apb.TextColor3 = Color3.new(0,0,0)
            end)
        end

        -- Custom accent theme: paste a hex color (e.g. B432FF) to recolor the whole UI.
        local custRow = Instance.new("Frame", tS)
        custRow.Size = UDim2.new(1,0,0,40)
        custRow.BackgroundColor3 = C().SURF
        custRow.BorderSizePixel = 0
        custRow.LayoutOrder = 50
        Instance.new("UICorner", custRow).CornerRadius = UDim.new(0,7)
        local custLbl = Instance.new("TextLabel", custRow)
        custLbl.Size = UDim2.new(0,46,1,0); custLbl.Position = UDim2.new(0,10,0,0)
        custLbl.BackgroundTransparency = 1; custLbl.Text = "Custom"
        custLbl.Font = Enum.Font.GothamBold; custLbl.TextSize = 11
        custLbl.TextColor3 = C().TP; custLbl.TextXAlignment = Enum.TextXAlignment.Left
        local custBox = Instance.new("TextBox", custRow)
        custBox.Size = UDim2.new(0,90,0,24); custBox.Position = UDim2.new(0,60,0.5,-12)
        custBox.BackgroundColor3 = C().SH; custBox.Text = tostring(Config.CustomThemeHex or "B432FF")
        custBox.PlaceholderText = "hex e.g. B432FF"; custBox.Font = Enum.Font.GothamBold
        custBox.TextSize = 11; custBox.TextColor3 = C().TP; custBox.ClearTextOnFocus = false
        custBox.BorderSizePixel = 0; Instance.new("UICorner", custBox).CornerRadius = UDim.new(0,5)
        local custApply = Instance.new("TextButton", custRow)
        custApply.Size = UDim2.new(0,72,0,24); custApply.Position = UDim2.new(1,-80,0.5,-12)
        custApply.BackgroundColor3 = C().SH; custApply.Text = "APPLY"
        custApply.Font = Enum.Font.GothamBold; custApply.TextSize = 10; custApply.TextColor3 = C().TP
        custApply.AutoButtonColor = false; custApply.BorderSizePixel = 0
        Instance.new("UICorner", custApply).CornerRadius = UDim.new(0,5)
        local function applyCustom()
            local hx = custBox.Text:gsub("#",""):gsub("%s","")
            if buildCustomThemeFromHex(hx) then
                Config.CustomThemeHex = hx; SaveConfig()
                custBox.Text = hx
                applyTheme("custom")
            else
                custBox.Text = Config.CustomThemeHex or "B432FF"
                if ShowNotification then ShowNotification("THEME", "Invalid hex - use 6 digits like B432FF") end
            end
        end
        custApply.MouseButton1Click:Connect(applyCustom)
        custBox.FocusLost:Connect(function(enter) if enter then applyCustom() end end)

        -- Image theme: paste any image URL. We download it, recolor the whole hub from the
        -- image's average colour, and paste the image behind every panel.
        local imgRow = Instance.new("Frame", tS)
        imgRow.Size = UDim2.new(1,0,0,40)
        imgRow.BackgroundColor3 = C().SURF
        imgRow.BorderSizePixel = 0
        imgRow.LayoutOrder = 52
        Instance.new("UICorner", imgRow).CornerRadius = UDim.new(0,7)
        local imgLbl = Instance.new("TextLabel", imgRow)
        imgLbl.Size = UDim2.new(0,40,1,0); imgLbl.Position = UDim2.new(0,10,0,0)
        imgLbl.BackgroundTransparency = 1; imgLbl.Text = "Image"
        imgLbl.Font = Enum.Font.GothamBold; imgLbl.TextSize = 11
        imgLbl.TextColor3 = C().TP; imgLbl.TextXAlignment = Enum.TextXAlignment.Left
        local imgBox = Instance.new("TextBox", imgRow)
        imgBox.Size = UDim2.new(1,-130,0,24); imgBox.Position = UDim2.new(0,54,0.5,-12)
        imgBox.BackgroundColor3 = C().SH; imgBox.Text = tostring(Config.ThemeImageUrl or "")
        imgBox.PlaceholderText = "paste image URL..."; imgBox.Font = Enum.Font.Gotham
        imgBox.TextSize = 9; imgBox.TextColor3 = C().TP; imgBox.ClearTextOnFocus = false
        imgBox.TextXAlignment = Enum.TextXAlignment.Left; imgBox.TextTruncate = Enum.TextTruncate.AtEnd
        imgBox.BorderSizePixel = 0; Instance.new("UICorner", imgBox).CornerRadius = UDim.new(0,5)
        local imgApply = Instance.new("TextButton", imgRow)
        imgApply.Size = UDim2.new(0,64,0,24); imgApply.Position = UDim2.new(1,-70,0.5,-12)
        imgApply.BackgroundColor3 = C().SH; imgApply.Text = "APPLY"
        imgApply.Font = Enum.Font.GothamBold; imgApply.TextSize = 10; imgApply.TextColor3 = C().TP
        imgApply.AutoButtonColor = false; imgApply.BorderSizePixel = 0
        Instance.new("UICorner", imgApply).CornerRadius = UDim.new(0,5)
        local function applyImg()
            local url = imgBox.Text:gsub("%s","")
            if url == "" then
                Config.ThemeImageUrl = ""; SaveConfig()
                _G.JAF_ThemeImageAsset = nil
                if jafApplyThemeImageToPanels then pcall(jafApplyThemeImageToPanels, nil) end
                if ShowNotification then ShowNotification("THEME", "Image cleared") end
                return
            end
            imgApply.Text = "..."
            task.spawn(function()
                local ok, reason = nil, nil
                if jafApplyImageTheme then ok, reason = jafApplyImageTheme(url) end
                if ok then
                    Config.ThemeImageUrl = url; SaveConfig()
                    if ShowNotification then ShowNotification("THEME", "Image applied") end
                else
                    if ShowNotification then ShowNotification("THEME", reason or "couldn't load image") end
                end
                if imgApply and imgApply.Parent then imgApply.Text = "APPLY" end
            end)
        end
        imgApply.MouseButton1Click:Connect(applyImg)
        imgBox.FocusLost:Connect(function(enter) if enter then applyImg() end end)

        local custHint = Instance.new("TextLabel", tS)
        custHint.Size = UDim2.new(1,0,0,26); custHint.LayoutOrder = 53
        custHint.BackgroundTransparency = 1
        custHint.Text = "Hex recolors the UI. Image URL must be a direct PNG or JPG link (WebP / Google-search page links won't work). It tints the hub to the image's colors and shows behind the panels. Leave blank + APPLY to clear."
        custHint.Font = Enum.Font.Gotham; custHint.TextSize = 8
        custHint.TextColor3 = C().TS; custHint.TextWrapped = true
        custHint.TextXAlignment = Enum.TextXAlignment.Left

        makeToggle(tS, "Loading Screen",
            function() return Config.ShowLoadingScreen ~= false end,
            function(v) Config.ShowLoadingScreen = v; SaveConfig() end, 54)
        local lsHint = Instance.new("TextLabel", tS)
        lsHint.Size = UDim2.new(1,0,0,18); lsHint.LayoutOrder = 55
        lsHint.BackgroundTransparency = 1
        lsHint.Text = "Shows the Sammydawg splash on launch. Takes effect next time you run the script."
        lsHint.Font = Enum.Font.Gotham; lsHint.TextSize = 8
        lsHint.TextColor3 = C().TS; lsHint.TextWrapped = true
        lsHint.TextXAlignment = Enum.TextXAlignment.Left
    end

    local blS = tScrolls2["bl"]

    makeSec(blS, "BLACKLIST ESP", 0)
    makeToggle(blS, "Show Blacklist ESP", function() return Config.BlacklistESP ~= false end, function(v)
        Config.BlacklistESP = v; SaveConfig()
        if not v then
            for _, p in ipairs(Players:GetPlayers()) do
                local char = p.Character
                if char then
                    local existing = char:FindFirstChild("JustAFanBlacklistESP")
                    if existing then existing:Destroy() end
                end
            end
        end
    end, 1)

    local blMsgRow = Instance.new("Frame", blS)
    blMsgRow.Size             = UDim2.new(1,0,0,36)
    blMsgRow.BackgroundColor3 = C().SURF
    blMsgRow.BackgroundTransparency = 0.05
    blMsgRow.BorderSizePixel  = 0
    blMsgRow.LayoutOrder      = 2
    Instance.new("UICorner", blMsgRow).CornerRadius = UDim.new(0,7)
    local blMsgLbl = Instance.new("TextLabel", blMsgRow)
    blMsgLbl.Size             = UDim2.new(0,60,1,0)
    blMsgLbl.Position         = UDim2.new(0,8,0,0)
    blMsgLbl.BackgroundTransparency = 1
    blMsgLbl.Text             = "Message"
    blMsgLbl.Font             = Enum.Font.GothamBold
    blMsgLbl.TextSize         = 11
    blMsgLbl.TextColor3       = C().TP
    blMsgLbl.TextXAlignment   = Enum.TextXAlignment.Left
    local blMsgBox = Instance.new("TextBox", blMsgRow)
    blMsgBox.Size             = UDim2.new(1,-78,0,24)
    blMsgBox.Position         = UDim2.new(0,72,0.5,-12)
    blMsgBox.BackgroundColor3 = C().SH
    blMsgBox.Text             = Config.BlacklistMsg or "BLOCKED"
    blMsgBox.PlaceholderText  = "BLOCKED"
    blMsgBox.Font             = Enum.Font.GothamBold
    blMsgBox.TextSize         = 11
    blMsgBox.TextColor3       = C().TP
    blMsgBox.ClearTextOnFocus = false
    blMsgBox.BorderSizePixel  = 0
    Instance.new("UICorner", blMsgBox).CornerRadius = UDim.new(0,5)
    blMsgBox.FocusLost:Connect(function()
        local msg = blMsgBox.Text:gsub("%s+", " "):match("^%s*(.-)%s*$")
        if msg == "" then msg = "BLOCKED" end
        Config.BlacklistMsg = msg; SaveConfig()
        blMsgBox.Text = msg
        for _, p in ipairs(Players:GetPlayers()) do
            local char = p.Character
            if char then
                local bb = char:FindFirstChild("JustAFanBlacklistESP")
                if bb then
                    local lbl = bb:FindFirstChild("MsgLbl", true)
                    if lbl then lbl.Text = msg end
                end
            end
        end
    end)

    local blInputRow = Instance.new("Frame", blS)
    blInputRow.Size = UDim2.new(1,0,0,44)
    blInputRow.BackgroundColor3 = C().SURF
    blInputRow.BorderSizePixel = 0
    blInputRow.LayoutOrder = 1
    Instance.new("UICorner", blInputRow).CornerRadius = UDim.new(0,7)

    local blBox = Instance.new("TextBox", blInputRow)
    blBox.Size = UDim2.new(1,-80,0,28)
    blBox.Position = UDim2.new(0,8,0.5,-14)
    blBox.BackgroundColor3 = C().SH
    blBox.Text = ""
    blBox.PlaceholderText = "Username..."
    blBox.Font = Enum.Font.GothamBold
    blBox.TextSize = 12
    blBox.TextColor3 = C().TP
    blBox.ClearTextOnFocus = false
    blBox.BorderSizePixel = 0
    Instance.new("UICorner", blBox).CornerRadius = UDim.new(0,6)

    local blAddBtn = Instance.new("TextButton", blInputRow)
    blAddBtn.Size = UDim2.new(0,60,0,28)
    blAddBtn.Position = UDim2.new(1,-68,0.5,-14)
    blAddBtn.BackgroundColor3 = Color3.fromRGB(180,40,40)
    blAddBtn.Text = "ADD"
    blAddBtn.Font = Enum.Font.GothamBold
    blAddBtn.TextSize = 12
    blAddBtn.TextColor3 = Color3.new(1,1,1)
    blAddBtn.AutoButtonColor = false
    blAddBtn.BorderSizePixel = 0
    Instance.new("UICorner", blAddBtn).CornerRadius = UDim.new(0,6)

    local blCount = Instance.new("Frame", blS)
    blCount.Size = UDim2.new(1,0,0,24)
    blCount.BackgroundTransparency = 1
    blCount.LayoutOrder = 2
    local blCountLbl = Instance.new("TextLabel", blCount)
    blCountLbl.Size = UDim2.new(1,0,1,0)
    blCountLbl.BackgroundTransparency = 1
    blCountLbl.Text = "BLACKLISTED (0)"
    blCountLbl.Font = Enum.Font.GothamBlack
    blCountLbl.TextSize = 11
    blCountLbl.TextColor3 = Color3.fromRGB(180,40,40)
    blCountLbl.TextXAlignment = Enum.TextXAlignment.Left

    local blListContainer = Instance.new("Frame", blS)
    blListContainer.Size = UDim2.new(1,0,0,10)
    blListContainer.BackgroundTransparency = 1
    blListContainer.LayoutOrder = 3
    blListContainer.AutomaticSize = Enum.AutomaticSize.Y
    local blListLayout = Instance.new("UIListLayout", blListContainer)
    blListLayout.Padding = UDim.new(0,4)
    blListLayout.SortOrder = Enum.SortOrder.LayoutOrder

    refreshBlacklistUI = function()
        for _, ch in ipairs(blListContainer:GetChildren()) do
            if ch:IsA("Frame") then ch:Destroy() end
        end
        blCountLbl.Text = "BLACKLISTED (" .. #BlacklistedPlayers .. ")"

        for i, name in ipairs(BlacklistedPlayers) do
            local entRow = Instance.new("Frame", blListContainer)
            entRow.Size = UDim2.new(1,0,0,36)
            entRow.BackgroundColor3 = Color3.fromRGB(50,20,20)
            entRow.BorderSizePixel = 0
            entRow.LayoutOrder = i
            Instance.new("UICorner", entRow).CornerRadius = UDim.new(0,7)
            local entStroke = Instance.new("UIStroke", entRow)
            entStroke.Color = Color3.fromRGB(180,40,40)
            entStroke.Thickness = 1; entStroke.Transparency = 0.5

            local iconLbl = Instance.new("TextLabel", entRow)
            iconLbl.Size = UDim2.new(0,24,1,0)
            iconLbl.Position = UDim2.new(0,6,0,0)
            iconLbl.BackgroundTransparency = 1
            iconLbl.Text = "[!]"
            iconLbl.TextSize = 14
            iconLbl.Font = Enum.Font.GothamBold
            iconLbl.TextColor3 = Color3.fromRGB(255,100,100)

            local nameLbl = Instance.new("TextLabel", entRow)
            nameLbl.Size = UDim2.new(1,-70,1,0)
            nameLbl.Position = UDim2.new(0,34,0,0)
            nameLbl.BackgroundTransparency = 1
            nameLbl.Text = name
            nameLbl.Font = Enum.Font.GothamBold
            nameLbl.TextSize = 12
            nameLbl.TextColor3 = C().TP
            nameLbl.TextXAlignment = Enum.TextXAlignment.Left
            nameLbl.TextTruncate = Enum.TextTruncate.AtEnd

            local remBtn = Instance.new("TextButton", entRow)
            remBtn.Size = UDim2.new(0,50,0,24)
            remBtn.Position = UDim2.new(1,-56,0.5,-12)
            remBtn.BackgroundColor3 = C().SH
            remBtn.Text = "[X]"
            remBtn.Font = Enum.Font.GothamBold
            remBtn.TextSize = 13
            remBtn.TextColor3 = Theme.TextPrimary
            remBtn.AutoButtonColor = false
            remBtn.BorderSizePixel = 0
            Instance.new("UICorner", remBtn).CornerRadius = UDim.new(0,6)
            local n = name
            remBtn.MouseButton1Click:Connect(function()
                pcall(function()
                    removeFromBlacklist(n)
                    ShowNotification("BLACKLIST", "[OK] Removed: " .. n)
                    refreshBlacklistUI()
                end)
            end)
        end

        if #BlacklistedPlayers == 0 then
            local empty = Instance.new("TextLabel", blListContainer)
            empty.Size = UDim2.new(1,0,0,36)
            empty.BackgroundTransparency = 1
            empty.Text = "No players blacklisted"
            empty.Font = Enum.Font.GothamMedium
            empty.TextSize = 12
            empty.TextColor3 = C().TS
            empty.LayoutOrder = 1
        end
    end
    refreshBlacklistUI()

    blAddBtn.MouseButton1Click:Connect(function()
        pcall(function()
            local name = blBox.Text:gsub("%s", "")
            if name == "" then return end
            if addToBlacklist(name) then
                ShowNotification("BLACKLIST", "[!] Blocked: " .. name)
                blBox.Text = ""
                refreshBlacklistUI()
            else
                ShowNotification("BLACKLIST", name .. " already blacklisted")
            end
        end)
    end)

    blBox.FocusLost:Connect(function(enter)
        if enter then blAddBtn.MouseButton1Click:Fire() end
    end)

    switchTab2("act")

    _G.JustAFanSettingsUI = {panel=panel, switchTab=switchTab2, currentTab="cfg"}
end
task.spawn(buildJustAFanSettingsUI)

task.spawn(function()
    task.wait(1.5)
    if Config.ThemeImageUrl and Config.ThemeImageUrl ~= "" and jafApplyImageTheme then
        pcall(jafApplyImageTheme, Config.ThemeImageUrl)
    elseif Config.CurrentTheme and THEMES and THEMES[Config.CurrentTheme] then
        applyTheme(Config.CurrentTheme)
    end
end)

-- Unify every panel's look once the async-built windows exist. Re-runs a few
-- times over the first ~11s to catch panels that build late (AutoTurret,
-- GrabKick, StealingHUD, JobJoiner, etc.).
task.spawn(function()
    for _, dt in ipairs({2, 2, 3, 4}) do
        task.wait(dt)
        if jafUnifyPanelStyle then pcall(jafUnifyPanelStyle) end
    end
end)

function buildJustAFanMiniActionsUI()
    local pg = PlayerGui
    if not pg then return end
    local oldG = pg:FindFirstChild("JustAFanMiniActions")
    if oldG then oldG:Destroy() end

    local maGui = Instance.new("ScreenGui")
    maGui.Name = "JustAFanMiniActions"
    maGui.ResetOnSpawn = false
    maGui.DisplayOrder = 25
    maGui.Parent = pg

    local W = 252
    local BTN_H = 28
    local PANEL_H = 460

    local panel = Instance.new("Frame", maGui)
    panel.Name = "MiniPanel"
    panel.Size = UDim2.new(0, W, 0, PANEL_H)
    local savedPos = Config.MiniUIPos or {X=0.01, Y=0.35}
    panel.Position = UDim2.new(savedPos.X, 0, savedPos.Y, 0)
    panel.BackgroundColor3 = Theme.Background
    panel.BackgroundTransparency = 0.31
    panel.BorderSizePixel = 0
    panel.Visible = not Config.AutoHideMiniUI
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

    local pStroke = Instance.new("UIStroke", panel)
    pStroke.Color = Theme.Accent1
    pStroke.Thickness = 1.2
    pStroke.Transparency = 0.5

    local header = Instance.new("Frame", panel)
    header.Size = UDim2.new(1, 0, 0, 32)
    header.BackgroundTransparency = 1

    local titleLbl = Instance.new("TextLabel", header)
    titleLbl.Size = UDim2.new(1, -60, 1, 0)
    titleLbl.Position = UDim2.new(0, 10, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "ACTIONS"
    titleLbl.Font = Enum.Font.GothamBlack
    titleLbl.TextSize = 12
    titleLbl.TextColor3 = Theme.Accent1
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left

    local lockBtn = Instance.new("TextButton", header)
    lockBtn.Size = UDim2.new(0, 22, 0, 22)
    lockBtn.Position = UDim2.new(1, -28, 0.5, -11)
    lockBtn.BackgroundColor3 = Config.MiniUILocked and Theme.Accent1 or Theme.SurfaceHighlight
    lockBtn.BackgroundTransparency = 0.1
    lockBtn.Text = Config.MiniUILocked and "[LOCK]" or "[OPEN]"
    lockBtn.Font = Enum.Font.GothamBold
    lockBtn.TextSize = 12
    lockBtn.TextColor3 = Color3.new(1,1,1)
    lockBtn.AutoButtonColor = false
    Instance.new("UICorner", lockBtn).CornerRadius = UDim.new(1, 0)
    local lockStroke = Instance.new("UIStroke", lockBtn)
    lockStroke.Color = Theme.Accent1
    lockStroke.Thickness = 1
    lockStroke.Transparency = 0.4

    lockBtn.MouseButton1Click:Connect(function()
        Config.MiniUILocked = not Config.MiniUILocked
        SaveConfig()
        lockBtn.Text = Config.MiniUILocked and "[LOCK]" or "[OPEN]"
        lockBtn.BackgroundColor3 = Config.MiniUILocked and Theme.Accent1 or Theme.SurfaceHighlight
    end)

    do
        local dragging, dragStart, startPos
        header.InputBegan:Connect(function(inp)
            if Config.MiniUILocked then return end
            if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                dragStart = inp.Position
                startPos = panel.Position
                inp.Changed:Connect(function()
                    if inp.UserInputState == Enum.UserInputState.End then
                        dragging = false
                        if panel and panel.Parent then
                            local ps = panel.Parent.AbsoluteSize
                            Config.MiniUIPos = {
                                X = panel.AbsolutePosition.X / ps.X,
                                Y = panel.AbsolutePosition.Y / ps.Y,
                            }
                            SaveConfig()
                        end
                    end
                end)
            end
        end)
        header.InputChanged:Connect(function(inp)
            if inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch then
                if dragging and dragStart then
                    local delta = inp.Position - dragStart
                    panel.Position = UDim2.new(
                        startPos.X.Scale, startPos.X.Offset + delta.X,
                        startPos.Y.Scale, startPos.Y.Offset + delta.Y
                    )
                end
            end
        end)
        UserInputService.InputChanged:Connect(function(inp)
            if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
                local delta = inp.Position - dragStart
                panel.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y
                )
            end
        end)
    end

    local div = Instance.new("Frame", panel)
    div.Size = UDim2.new(1, -16, 0, 1)
    div.Position = UDim2.new(0, 8, 0, 32)
    div.BackgroundColor3 = Theme.SurfaceHighlight
    div.BorderSizePixel = 0

    local cont = Instance.new("ScrollingFrame", panel)
    cont.Name = "MiniContent"
    cont.Size = UDim2.new(1, -12, 1, -38)
    cont.Position = UDim2.new(0, 6, 0, 36)
    cont.BackgroundTransparency = 1
    cont.BorderSizePixel = 0
    cont.ScrollBarThickness = 0
    cont.ScrollBarImageColor3 = Theme.Accent1
    cont.CanvasSize = UDim2.new(0, 0, 0, 0)
    cont.AutomaticCanvasSize = Enum.AutomaticSize.Y
    cont.ScrollingDirection = Enum.ScrollingDirection.Y

    local ll = Instance.new("UIListLayout", cont)
    ll.Padding = UDim.new(0, 4)
    ll.SortOrder = Enum.SortOrder.LayoutOrder

    local function miniSec(lbl, ord)
        local r = Instance.new("Frame", cont)
        r.Size = UDim2.new(1, 0, 0, 12)
        r.BackgroundTransparency = 1
        r.LayoutOrder = ord
        local t = Instance.new("TextLabel", r)
        t.Size = UDim2.new(1, -6, 1, 0)
        t.Position = UDim2.new(0, 2, 0, 0)
        t.BackgroundTransparency = 1
        t.Text = lbl
        t.Font = Enum.Font.GothamBlack
        t.TextSize = 8
        t.TextColor3 = Theme.Accent1
        t.TextXAlignment = Enum.TextXAlignment.Left
    end

    local function mBtn(lbl, order, col, cb)
        local b = Instance.new("TextButton", cont)
        b.Size = UDim2.new(1, 0, 0, BTN_H)
        b.BackgroundColor3 = col or Theme.Surface
        b.BackgroundTransparency = 0.05
        b.Text = lbl
        b.Font = Enum.Font.GothamBold
        b.TextSize = 10
        b.TextColor3 = Theme.TextPrimary
        b.BorderSizePixel = 0
        b.AutoButtonColor = false
        b.LayoutOrder = order
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 7)
        local bs = Instance.new("UIStroke", b)
        bs.Color = col or Theme.SurfaceHighlight
        bs.Thickness = 1
        bs.Transparency = 0.5
        b.MouseEnter:Connect(function()
            TweenService:Create(b, TweenInfo.new(0.1), {BackgroundTransparency=0}):Play()
            TweenService:Create(bs, TweenInfo.new(0.1), {Transparency=0.1}):Play()
        end)
        b.MouseLeave:Connect(function()
            TweenService:Create(b, TweenInfo.new(0.1), {BackgroundTransparency=0.05}):Play()
            TweenService:Create(bs, TweenInfo.new(0.1), {Transparency=0.5}):Play()
        end)
        b.MouseButton1Click:Connect(cb)
        return b
    end

    miniSec("STEAL SPEED", 10)
    do
        local MIN_S, MAX_S = 5, 30
        local r = Instance.new("Frame", cont)
        r.Size = UDim2.new(1, 0, 0, 44)
        r.BackgroundColor3 = Theme.Surface
        r.BackgroundTransparency = 0.05
        r.BorderSizePixel = 0
        r.LayoutOrder = 11
        Instance.new("UICorner", r).CornerRadius = UDim.new(0, 7)
        local rl = Instance.new("TextLabel", r)
        rl.Size = UDim2.new(1, -16, 0, 14)
        rl.Position = UDim2.new(0, 8, 0, 4)
        rl.BackgroundTransparency = 1
        rl.Font = Enum.Font.GothamBold
        rl.TextSize = 10
        rl.TextColor3 = Theme.TextPrimary
        rl.TextXAlignment = Enum.TextXAlignment.Left
        local rbg = Instance.new("Frame", r)
        rbg.Size = UDim2.new(1, -16, 0, 6)
        rbg.Position = UDim2.new(0, 8, 0, 26)
        rbg.BackgroundColor3 = Theme.SurfaceHighlight
        rbg.BorderSizePixel = 0
        Instance.new("UICorner", rbg).CornerRadius = UDim.new(1, 0)
        local rfill = Instance.new("Frame", rbg)
        rfill.BackgroundColor3 = Theme.Accent1
        rfill.BorderSizePixel = 0
        Instance.new("UICorner", rfill).CornerRadius = UDim.new(1, 0)
        local rk = Instance.new("Frame", rbg)
        rk.Size = UDim2.new(0, 12, 0, 12)
        rk.AnchorPoint = Vector2.new(0.5, 0.5)
        rk.BackgroundColor3 = Color3.new(1, 1, 1)
        rk.BorderSizePixel = 0
        Instance.new("UICorner", rk).CornerRadius = UDim.new(1, 0)

        local function setVisual(v)
            v = math.clamp(math.floor((tonumber(v) or MIN_S) + 0.5), MIN_S, MAX_S)
            rl.Text = "Speed: " .. v .. "  (" .. MIN_S .. "-" .. MAX_S .. ")"
            local p2 = (v - MIN_S) / (MAX_S - MIN_S)
            rfill.Size = UDim2.new(p2, 0, 1, 0)
            rk.Position = UDim2.new(p2, 0, 0.5, 0)
        end

        local function commitFromTrack(posX)
            local t = math.clamp((posX - rbg.AbsolutePosition.X) / rbg.AbsoluteSize.X, 0, 1)
            local v = math.floor(MIN_S + t * (MAX_S - MIN_S) + 0.5)
            if SharedState and SharedState.applyStealSpeedValue then
                pcall(SharedState.applyStealSpeedValue, v)
            else
                Config.StealSpeed = math.clamp(v, MIN_S, MAX_S)
                SaveConfig()
                setVisual(Config.StealSpeed)
            end
        end

        SharedState._refreshMiniStealSpeedSlider = function()
            setVisual(Config.StealSpeed or 20)
        end
        setVisual(math.clamp(math.floor((Config.StealSpeed or 20) + 0.5), MIN_S, MAX_S))

        local sd = false
        rbg.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                sd = true
                commitFromTrack(i.Position.X)
            end
        end)
        UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then sd = false end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if sd and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                commitFromTrack(i.Position.X)
            end
        end)
    end

    miniSec("INVISIBLE STEAL", 20)
    local invisBtn = mBtn("Invisible Steal: OFF", 21, Theme.Surface, function() end)
    local function updInvisMini()
        local on = _G.invisibleStealEnabled
        invisBtn.Text = on and "Invisible Steal: ON" or "Invisible Steal: OFF"
        invisBtn.BackgroundColor3 = on and Theme.Accent1 or Theme.Surface
        invisBtn.TextColor3 = on and Color3.new(0, 0, 0) or Theme.TextPrimary
    end
    updInvisMini()
    invisBtn.MouseButton1Click:Connect(function()
        if _G.toggleInvisibleSteal then pcall(_G.toggleInvisibleSteal) end
        task.defer(updInvisMini)
    end)

    do
        local r = Instance.new("Frame", cont)
        r.Size = UDim2.new(1, 0, 0, 30)
        r.BackgroundColor3 = Theme.Surface
        r.BackgroundTransparency = 0.05
        r.BorderSizePixel = 0
        r.LayoutOrder = 22
        Instance.new("UICorner", r).CornerRadius = UDim.new(0, 7)
        local rl = Instance.new("TextLabel", r)
        rl.Size = UDim2.new(0, 94, 1, 0)
        rl.Position = UDim2.new(0, 8, 0, 0)
        rl.BackgroundTransparency = 1
        rl.Font = Enum.Font.GothamBold
        rl.TextSize = 9
        rl.TextColor3 = Theme.TextPrimary
        rl.TextXAlignment = Enum.TextXAlignment.Left
        local rbg = Instance.new("Frame", r)
        rbg.Size = UDim2.new(1, -112, 0, 6)
        rbg.Position = UDim2.new(0, 104, 0.5, -3)
        rbg.BackgroundColor3 = Theme.SurfaceHighlight
        rbg.BorderSizePixel = 0
        Instance.new("UICorner", rbg).CornerRadius = UDim.new(1, 0)
        local rfill = Instance.new("Frame", rbg)
        rfill.BackgroundColor3 = Theme.Accent1
        rfill.BorderSizePixel = 0
        Instance.new("UICorner", rfill).CornerRadius = UDim.new(1, 0)
        local rk = Instance.new("Frame", rbg)
        rk.Size = UDim2.new(0, 10, 0, 10)
        rk.AnchorPoint = Vector2.new(0.5, 0.5)
        rk.BackgroundColor3 = Color3.new(1, 1, 1)
        rk.BorderSizePixel = 0
        Instance.new("UICorner", rk).CornerRadius = UDim.new(1, 0)
        local function updRot(v)
            v = math.clamp(math.floor(v), 0, 360)
            Config.InvisStealAngle = v
            _G.InvisStealAngle = v
            SaveConfig()
            rl.Text = "Rotation: " .. v
            local p2 = v / 360
            rfill.Size = UDim2.new(p2, 0, 1, 0)
            rk.Position = UDim2.new(p2, 0, 0.5, 0)
        end
        updRot(Config.InvisStealAngle or 0)
        local rd = false
        rbg.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                rd = true
                updRot(((i.Position.X - rbg.AbsolutePosition.X) / rbg.AbsoluteSize.X) * 360)
            end
        end)
        UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then rd = false end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if rd and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                updRot(((i.Position.X - rbg.AbsolutePosition.X) / rbg.AbsoluteSize.X) * 360)
            end
        end)
    end

    do
        local r = Instance.new("Frame", cont)
        r.Size = UDim2.new(1, 0, 0, 30)
        r.BackgroundColor3 = Theme.Surface
        r.BackgroundTransparency = 0.05
        r.BorderSizePixel = 0
        r.LayoutOrder = 23
        Instance.new("UICorner", r).CornerRadius = UDim.new(0, 7)
        local rl = Instance.new("TextLabel", r)
        rl.Size = UDim2.new(0, 94, 1, 0)
        rl.Position = UDim2.new(0, 8, 0, 0)
        rl.BackgroundTransparency = 1
        rl.Font = Enum.Font.GothamBold
        rl.TextSize = 9
        rl.TextColor3 = Theme.TextPrimary
        rl.TextXAlignment = Enum.TextXAlignment.Left
        local rbg = Instance.new("Frame", r)
        rbg.Size = UDim2.new(1, -112, 0, 6)
        rbg.Position = UDim2.new(0, 104, 0.5, -3)
        rbg.BackgroundColor3 = Theme.SurfaceHighlight
        rbg.BorderSizePixel = 0
        Instance.new("UICorner", rbg).CornerRadius = UDim.new(1, 0)
        local rfill = Instance.new("Frame", rbg)
        rfill.BackgroundColor3 = Theme.Accent1
        rfill.BorderSizePixel = 0
        Instance.new("UICorner", rfill).CornerRadius = UDim.new(1, 0)
        local rk = Instance.new("Frame", rbg)
        rk.Size = UDim2.new(0, 10, 0, 10)
        rk.AnchorPoint = Vector2.new(0.5, 0.5)
        rk.BackgroundColor3 = Color3.new(1, 1, 1)
        rk.BorderSizePixel = 0
        Instance.new("UICorner", rk).CornerRadius = UDim.new(1, 0)
        local function updDepth(v)
            v = math.clamp(math.floor(v * 10) / 10, 0.5, 10)
            Config.SinkSliderValue = v
            _G.SinkSliderValue = v
            SaveConfig()
            rl.Text = "Depth: " .. v
            local p2 = (v - 0.5) / 9.5
            rfill.Size = UDim2.new(p2, 0, 1, 0)
            rk.Position = UDim2.new(p2, 0, 0.5, 0)
        end
        updDepth(Config.SinkSliderValue or 2.5)
        local dd = false
        rbg.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dd = true
                updDepth(0.5 + ((i.Position.X - rbg.AbsolutePosition.X) / rbg.AbsoluteSize.X) * 9.5)
            end
        end)
        UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dd = false end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if dd and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                updDepth(0.5 + ((i.Position.X - rbg.AbsolutePosition.X) / rbg.AbsoluteSize.X) * 9.5)
            end
        end)
    end

    miniSec("AUTO", 30)
    local abBackBtn = mBtn("Auto Back: OFF", 31, Theme.Surface, function() end)
    local function updABMini()
        local on = Config.AutoBack
        abBackBtn.Text = on and "Auto Back: ON" or "Auto Back: OFF"
        abBackBtn.BackgroundColor3 = on and Theme.Accent1 or Theme.Surface
        abBackBtn.TextColor3 = on and Color3.new(0, 0, 0) or Theme.TextPrimary
    end
    updABMini()
    abBackBtn.MouseButton1Click:Connect(function()
        Config.AutoBack = not Config.AutoBack
        SaveConfig()
        if Config.AutoBack and _G.startAutoBack then
            pcall(_G.startAutoBack)
        elseif _G.stopAutoBack then pcall(_G.stopAutoBack) end
        updABMini()
    end)

    do
        local akBtn = mBtn("Auto Kick: OFF", 32, Theme.Surface, function() end)

        local function updateAKBtn()
            local on = Config.AutoKickOnSteal
            akBtn.Text = on and "Auto Kick: ON" or "Auto Kick: OFF"
            akBtn.BackgroundColor3 = on and Theme.Accent1 or Theme.Surface
            akBtn.TextColor3 = on and Color3.new(0, 0, 0) or Theme.TextPrimary
        end
        updateAKBtn()

        akBtn.MouseButton1Click:Connect(function()
            Config.AutoKickOnSteal = not Config.AutoKickOnSteal
            SaveConfig()
            updateAKBtn()
            if _G.setAutoKickFromSettings then _G.setAutoKickFromSettings(Config.AutoKickOnSteal) end
        end)

        _G.setAutoKickFromMiniUI = updateAKBtn
    end

    _G.setAutoKickFromSettings = function(val)
        Config.AutoKickOnSteal = val
        SaveConfig()
        if _G.setAutoKickFromMiniUI then _G.setAutoKickFromMiniUI() end
    end

    miniSec("SESSION", 40)
    do
        local kickKey = Config.KickKey ~= "" and Config.KickKey or "NONE"
        local row = Instance.new("Frame", cont)
        row.Size = UDim2.new(1, 0, 0, BTN_H)
        row.BackgroundTransparency = 1
        row.LayoutOrder = 41

        local rej = Instance.new("TextButton", row)
        rej.Size = UDim2.new(0.5, -3, 1, 0)
        rej.Position = UDim2.new(0, 0, 0, 0)
        rej.BackgroundColor3 = Theme.Surface
        rej.BackgroundTransparency = 0.05
        rej.Text = "Rejoin"
        rej.Font = Enum.Font.GothamBold
        rej.TextSize = 10
        rej.TextColor3 = Theme.TextPrimary
        rej.AutoButtonColor = false
        rej.BorderSizePixel = 0
        Instance.new("UICorner", rej).CornerRadius = UDim.new(0, 7)
        local rjS = Instance.new("UIStroke", rej)
        rjS.Color = Theme.SurfaceHighlight
        rjS.Thickness = 1
        rjS.Transparency = 0.5
        rej.MouseButton1Click:Connect(function()
            ShowNotification("REJOIN", "Reconnecting...")
            task.delay(0.5, function()
                pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
            end)
        end)

        local kb = Instance.new("TextButton", row)
        kb.Size = UDim2.new(0.5, -3, 1, 0)
        kb.Position = UDim2.new(0.5, 3, 0, 0)
        kb.BackgroundColor3 = Color3.fromRGB(180, 40, 60)
        kb.BackgroundTransparency = 0.05
        kb.Text = "Kick (" .. kickKey .. ")"
        kb.Font = Enum.Font.GothamBold
        kb.TextSize = 10
        kb.TextColor3 = Color3.new(1, 1, 1)
        kb.AutoButtonColor = false
        kb.BorderSizePixel = 0
        Instance.new("UICorner", kb).CornerRadius = UDim.new(0, 7)
        local kbS = Instance.new("UIStroke", kb)
        kbS.Color = Color3.fromRGB(200, 60, 80)
        kbS.Thickness = 1
        kbS.Transparency = 0.4
        kb.MouseButton1Click:Connect(function()
            kickPlayer()
        end)
    end

    local autoBuyActive = false
    _G.AutoBuyEsteira   = false

    local _oldAB = PlayerGui:FindFirstChild("JustAFanAutoBuyUI")
    if _oldAB then _oldAB:Destroy() end

    local abGui = Instance.new("ScreenGui")
    abGui.Name         = "JustAFanAutoBuyUI"
    abGui.ResetOnSpawn = false
    abGui.DisplayOrder = 30
    abGui.Parent       = PlayerGui

    local abPanel = Instance.new("Frame", abGui)
    abPanel.Name             = "ABPanel"
    abPanel.Size             = UDim2.new(0, 215, 0, 260)
    local _savedAbPos = Config.Positions and Config.Positions.AutoBuy or {X=0.01, Y=0.35}
    abPanel.Position         = UDim2.new(_savedAbPos.X, 0, _savedAbPos.Y, 0)
    abPanel.BackgroundColor3 = Theme.Background
    abPanel.BackgroundTransparency = 0.31
    abPanel.BorderSizePixel  = 0
    abPanel.Visible          = not (Config.HideAutoBuyUI == true)
    Instance.new("UICorner", abPanel).CornerRadius = UDim.new(0, 10)
    local abStroke = Instance.new("UIStroke", abPanel)
    abStroke.Color = Theme.Accent1; abStroke.Thickness = 1.8; abStroke.Transparency = 0.35
    task.defer(function()
        if addRacetrackBorder then addRacetrackBorder(abPanel, Theme.Accent1, 3.5) end
    end)

    local abHdr = Instance.new("Frame", abPanel)
    abHdr.Size               = UDim2.new(1,0,0,36)
    abHdr.BackgroundTransparency = 1
    MakeDraggable(abHdr, abPanel, "AutoBuy")

    local abTitle = Instance.new("TextLabel", abHdr)
    abTitle.Size             = UDim2.new(1,-12,1,0)
    abTitle.Position         = UDim2.new(0,12,0,0)
    abTitle.BackgroundTransparency = 1
    abTitle.Text             = "AUTO BUY"
    abTitle.Font             = Enum.Font.GothamBlack
    abTitle.TextSize         = 15
    abTitle.TextColor3       = Theme.Accent1
    abTitle.TextXAlignment   = Enum.TextXAlignment.Left

    local abDiv = Instance.new("Frame", abPanel)
    abDiv.Size             = UDim2.new(1,-20,0,1)
    abDiv.Position         = UDim2.new(0,10,0,36)
    abDiv.BackgroundColor3 = Theme.Accent1
    abDiv.BackgroundTransparency = 0.6
    abDiv.BorderSizePixel  = 0

    local abContent = Instance.new("Frame", abPanel)
    abContent.Size             = UDim2.new(1,-16,1,-46)
    abContent.Position         = UDim2.new(0,8,0,44)
    abContent.BackgroundTransparency = 1
    local abLayout = Instance.new("UIListLayout", abContent)
    abLayout.Padding   = UDim.new(0,6)
    abLayout.SortOrder = Enum.SortOrder.LayoutOrder

    local function makeAbRow(h, order)
        local r = Instance.new("Frame", abContent)
        r.Size             = UDim2.new(1,0,0,h)
        r.BackgroundColor3 = Theme.Surface
        r.BackgroundTransparency = 0.05
        r.BorderSizePixel  = 0
        r.LayoutOrder      = order
        Instance.new("UICorner", r).CornerRadius = UDim.new(0,7)
        return r
    end

    local abToggleRow = makeAbRow(38, 1)
    local abToggleBtn = Instance.new("TextButton", abToggleRow)
    abToggleBtn.Size             = UDim2.new(1,0,1,0)
    abToggleBtn.BackgroundColor3 = Theme.Surface
    abToggleBtn.BackgroundTransparency = 0
    abToggleBtn.Text             = "AUTO BUY: OFF"
    abToggleBtn.Font             = Enum.Font.GothamBlack
    abToggleBtn.TextSize         = 13
    abToggleBtn.TextColor3       = Theme.TextSecondary
    abToggleBtn.BorderSizePixel  = 0
    abToggleBtn.AutoButtonColor  = false
    Instance.new("UICorner", abToggleBtn).CornerRadius = UDim.new(0,7)
    local abToggleStroke = Instance.new("UIStroke", abToggleBtn)
    abToggleStroke.Color = Theme.Accent1; abToggleStroke.Thickness = 1.5; abToggleStroke.Transparency = 0.5

    local abKeyRow = makeAbRow(34, 2)
    local abKeyLbl = Instance.new("TextLabel", abKeyRow)
    abKeyLbl.Size             = UDim2.new(1,-70,1,0)
    abKeyLbl.Position         = UDim2.new(0,10,0,0)
    abKeyLbl.BackgroundTransparency = 1
    abKeyLbl.Text             = "Keybind"
    abKeyLbl.Font             = Enum.Font.GothamBold
    abKeyLbl.TextSize         = 12
    abKeyLbl.TextColor3       = Theme.TextPrimary
    abKeyLbl.TextXAlignment   = Enum.TextXAlignment.Left
    local abKeyBtn = Instance.new("TextButton", abKeyRow)
    abKeyBtn.Size             = UDim2.new(0,56,0,24)
    abKeyBtn.Position         = UDim2.new(1,-62,0.5,-12)
    abKeyBtn.BackgroundColor3 = Theme.SurfaceHighlight
    abKeyBtn.Text             = Config.AutoBuyKey or "K"
    abKeyBtn.Font             = Enum.Font.GothamBold
    abKeyBtn.TextSize         = 11
    abKeyBtn.TextColor3       = Theme.Accent1
    abKeyBtn.AutoButtonColor  = false
    abKeyBtn.BorderSizePixel  = 0
    Instance.new("UICorner", abKeyBtn).CornerRadius = UDim.new(0,5)
    abKeyBtn.MouseButton1Click:Connect(function()
        abKeyBtn.Text = "..."; abKeyBtn.TextColor3 = Theme.TextSecondary
        local c; c = UserInputService.InputBegan:Connect(function(inp)
            if inp.UserInputType == Enum.UserInputType.Keyboard then
                Config.AutoBuyKey = inp.KeyCode.Name
                abKeyBtn.Text = inp.KeyCode.Name
                abKeyBtn.TextColor3 = Theme.Accent1
                SaveConfig(); c:Disconnect()
            end
        end)
    end)

    local abRangeRow = makeAbRow(42, 3)
    local abRangeLbl = Instance.new("TextLabel", abRangeRow)
    abRangeLbl.Size           = UDim2.new(1,-10,0,16)
    abRangeLbl.Position       = UDim2.new(0,10,0,4)
    abRangeLbl.BackgroundTransparency = 1
    abRangeLbl.Text           = "Range: " .. (Config.AutoBuyRange or 17) .. " studs"
    abRangeLbl.Font           = Enum.Font.GothamBold
    abRangeLbl.TextSize       = 11
    abRangeLbl.TextColor3     = Theme.TextPrimary
    abRangeLbl.TextXAlignment = Enum.TextXAlignment.Left
    local abSlBg = Instance.new("Frame", abRangeRow)
    abSlBg.Size             = UDim2.new(1,-20,0,6)
    abSlBg.Position         = UDim2.new(0,10,0,28)
    abSlBg.BackgroundColor3 = Theme.SurfaceHighlight
    abSlBg.BorderSizePixel  = 0
    Instance.new("UICorner", abSlBg).CornerRadius = UDim.new(1,0)
    local abSlFill = Instance.new("Frame", abSlBg)
    abSlFill.BackgroundColor3 = Theme.Accent1
    abSlFill.BorderSizePixel  = 0
    Instance.new("UICorner", abSlFill).CornerRadius = UDim.new(1,0)
    local abSlKnob = Instance.new("Frame", abSlBg)
    abSlKnob.Size         = UDim2.new(0,13,0,13)
    abSlKnob.AnchorPoint  = Vector2.new(0.5,0.5)
    abSlKnob.BackgroundColor3 = Color3.new(1,1,1)
    abSlKnob.BorderSizePixel  = 0
    Instance.new("UICorner", abSlKnob).CornerRadius = UDim.new(1,0)
    local abSlKS = Instance.new("UIStroke", abSlKnob)
    abSlKS.Color = Theme.Accent1; abSlKS.Thickness = 1.5
    local AB_MIN, AB_MAX = 5, 40
    local function updateAbSlider(v)
        v = math.clamp(math.floor(v), AB_MIN, AB_MAX)
        Config.AutoBuyRange = v; SaveConfig()
        abRangeLbl.Text = "Range: " .. v .. " studs"
        local pct = (v-AB_MIN)/(AB_MAX-AB_MIN)
        abSlFill.Size     = UDim2.new(pct,0,1,0)
        abSlKnob.Position = UDim2.new(pct,0,0.5,0)
        local ring = Workspace:FindFirstChild("XiAutoBuyRing")
        if ring then ring.Size = Vector3.new(0.5, v*2, v*2) end
    end
    updateAbSlider(Config.AutoBuyRange or 17)
    local abDrag = false
    abSlBg.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then
            abDrag=true
            updateAbSlider(AB_MIN+((i.Position.X-abSlBg.AbsolutePosition.X)/abSlBg.AbsoluteSize.X)*(AB_MAX-AB_MIN))
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then abDrag=false end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if abDrag and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then
            updateAbSlider(AB_MIN+((i.Position.X-abSlBg.AbsolutePosition.X)/abSlBg.AbsoluteSize.X)*(AB_MAX-AB_MIN))
        end
    end)

    _G.rebuildAutoBuyCirclePresets = nil

    local abRing = nil
    local function getCircleColor()
        return Theme.Accent2 or Theme.Accent1
    end
    local function createRing()
        local existing = Workspace:FindFirstChild("XiAutoBuyRing")
        if existing then existing:Destroy() end
        local r = Instance.new("Part")
        r.Name         = "XiAutoBuyRing"
        r.Shape        = Enum.PartType.Cylinder
        r.Anchored     = true
        r.CanCollide   = false
        r.CanTouch     = false
        r.CanQuery     = false
        r.CastShadow   = false
        r.Material     = Enum.Material.Neon
        r.Transparency = 0.5
        r.Color        = getCircleColor()
        local range    = Config.AutoBuyRange or 17
        r.Size         = Vector3.new(0.5, range*2, range*2)
        r.Parent       = Workspace
        abRing = r
    end
    local function destroyRing()
        if abRing then abRing:Destroy(); abRing = nil end
        local existing = Workspace:FindFirstChild("XiAutoBuyRing")
        if existing then existing:Destroy() end
    end
    _G.updateAutoBuyRingColor = function()
        if abRing and abRing.Parent then abRing.Color = getCircleColor() end
    end

    -- Per-frame ring follow: cheap on its own but it's on a Heartbeat that always runs
    -- while the script is loaded, so it pays VM cost ~60x/sec for that flag check alone.
    -- Native callback removes that constant overhead.
    RunService.Heartbeat:Connect(LPH_NO_VIRTUALIZE(function()
        if not autoBuyActive then return end
        local char = LocalPlayer.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        if not abRing or not abRing.Parent then return end
        local range = Config.AutoBuyRange or 17
        abRing.Size  = Vector3.new(0.5, range*2, range*2)
        abRing.CFrame = hrp.CFrame * CFrame.Angles(0, 0, math.rad(90)) + Vector3.new(0, -2.5, 0)
    end))

    local function toggleAutoBuy()
        autoBuyActive = not autoBuyActive
        _G.AutoBuyEsteira = autoBuyActive
        if autoBuyActive then
            abToggleBtn.Text             = "AUTO BUY: ON"
            abToggleBtn.BackgroundColor3 = Theme.Accent1
            abToggleBtn.TextColor3       = Color3.new(0,0,0)
            abToggleStroke.Transparency  = 1
            createRing()
        else
            abToggleBtn.Text             = "AUTO BUY: OFF"
            abToggleBtn.BackgroundColor3 = Theme.Surface
            abToggleBtn.TextColor3       = Theme.TextSecondary
            abToggleStroke.Transparency  = 0.5
            destroyRing()
        end
        if _G.AutoBuyOnToggle then _G.AutoBuyOnToggle(autoBuyActive) end
        ShowNotification("AUTO BUY", autoBuyActive and "[OK] ENABLED" or "[X] DISABLED")
    end

    local autoBuyBtn = mBtn("Auto Buy: OFF", 7, Theme.Surface, function() end)
    autoBuyBtn.MouseButton1Click:Connect(function()
        toggleAutoBuy()
        autoBuyBtn.Text             = autoBuyActive and "Auto Buy: ON" or "Auto Buy: OFF"
        autoBuyBtn.BackgroundColor3 = autoBuyActive and Theme.Accent1 or Theme.Surface
        autoBuyBtn.TextColor3       = autoBuyActive and Color3.new(0,0,0) or Theme.TextPrimary
    end)
    abToggleBtn.MouseButton1Click:Connect(function()
        toggleAutoBuy()
        autoBuyBtn.Text             = autoBuyActive and "Auto Buy: ON" or "Auto Buy: OFF"
        autoBuyBtn.BackgroundColor3 = autoBuyActive and Theme.Accent1 or Theme.Surface
        autoBuyBtn.TextColor3       = autoBuyActive and Color3.new(0,0,0) or Theme.TextPrimary
    end)

    UserInputService.InputBegan:Connect(function(inp, gp)
        if gp then return end
        local key = Config.AutoBuyKey or "K"
        local ok, kc = pcall(function() return Enum.KeyCode[key] end)
        if ok and kc and inp.KeyCode == kc then
            toggleAutoBuy()
            autoBuyBtn.Text             = autoBuyActive and "Auto Buy: ON" or "Auto Buy: OFF"
            autoBuyBtn.BackgroundColor3 = autoBuyActive and Theme.Accent1 or Theme.Surface
            autoBuyBtn.TextColor3       = autoBuyActive and Color3.new(0,0,0) or Theme.TextPrimary
        end
    end)

    task.defer(function()
        if addRacetrackBorder then addRacetrackBorder(panel, Theme.Accent1, 3.5) end
    end)

    LocalPlayer.CharacterAdded:Connect(function()
        task.wait(0.5)
        if autoBuyActive then createRing() end
    end)

    task.spawn(function()
        local Packages = ReplicatedStorage:WaitForChild("Packages")
        local Datas    = ReplicatedStorage:WaitForChild("Datas")
        local Shared   = ReplicatedStorage:WaitForChild("Shared")
        local Utils    = ReplicatedStorage:WaitForChild("Utils")
        local AnimData   = require(Datas:WaitForChild("Animals"))
        local AnimShared = require(Shared:WaitForChild("Animals"))
        local NumUtils   = require(Utils:WaitForChild("NumberUtils"))

        local RARITY_WORDS = {common=true,uncommon=true,rare=true,epic=true,legendary=true,
            secret=true,divine=true,rainbow=true,cursed=true,gold=true,diamond=true}

        local function getBrainrotName(model)
            if not model then return "Brainrot","" end
            local nameFound,genFound = "",""
            for _, bb in ipairs(model:GetDescendants()) do
                if bb:IsA("BillboardGui") then
                    for _, lbl in ipairs(bb:GetDescendants()) do
                        if lbl:IsA("TextLabel") and lbl.Text and lbl.Text ~= "" then
                            local t = lbl.Text:match("^%s*(.-)%s*$")
                            local tl = t:lower()
                            if RARITY_WORDS[tl] then continue end
                            if t:match("^%$[%d%.]+[KkMmBb]?/s$") then if genFound=="" then genFound=t end; continue end
                            if t:match("^%$[%d%.]+[KkMmBb]?$") then continue end
                            if t:match("^[%d%.]+[KkMmBb]?$") then continue end
                            if nameFound=="" and #t>1 then nameFound=t end
                        end
                    end
                end
            end
            if nameFound=="" then
                pcall(function()
                    local info = AnimData[model.Name]
                    if info and info.DisplayName then
                        nameFound = info.DisplayName
                        local gv = AnimShared:GetGeneration(model.Name,nil,nil,nil)
                        genFound = "$"..NumUtils:ToString(gv).."/s"
                    end
                end)
            end
            if nameFound=="" then nameFound = model.Name~="" and model.Name or "Brainrot" end
            return nameFound,genFound
        end

        local function scanConveyor()
            local results = {}
            for _, obj in ipairs(Workspace:GetDescendants()) do
                if not (obj:IsA("ProximityPrompt") and obj.Enabled) then continue end
                local txt = obj.ActionText or ""
                if not (txt=="Purchase" or txt:lower():find("purchase") or txt:lower():find("comprar")) then continue end
                local part = obj.Parent
                if not part then continue end
                local realPart = part:IsA("Attachment") and part.Parent or part
                if not (realPart and realPart:IsA("BasePart")) then continue end
                local model,cur = nil,realPart
                for _ = 1,8 do
                    if cur and cur:IsA("Model") then model=cur; break end
                    cur = cur and cur.Parent
                end
                local name,gen = getBrainrotName(model)
                table.insert(results,{
                    name=name, gen=gen, prompt=obj, part=realPart,
                    model=model, source="ESTEIRA", uid="esteira_"..tostring(obj),
                })
            end
            return results
        end

        SharedState.ConveyorAnimals = {}
        local function refreshConveyor()
            local ok, found = pcall(scanConveyor)
            if ok and found then SharedState.ConveyorAnimals = found end
        end
        refreshConveyor()
        _G.refreshConveyor = refreshConveyor

        local purchaseRemote = nil
        local function resolvePurchaseRemote()
            if purchaseRemote and purchaseRemote.Parent then return purchaseRemote end
            pcall(function()
                local net = ReplicatedStorage:FindFirstChild("Packages")
                         and ReplicatedStorage.Packages:FindFirstChild("Net")
                if not net then return end
                local kws = {"buy","purchase","animal","shop","acquire","conveyor"}
                for _,v in ipairs(net:GetChildren()) do
                    local nl = (v.Name or ""):lower()
                    for _,kw in ipairs(kws) do
                        if nl:find(kw) then purchaseRemote=v; return end
                    end
                end
                local paths = {"RF/ShopService/BuyAnimal","RF/AnimalShop/Purchase","RE/Shop/Buy","RF/Shop/Buy"}
                for _,p in ipairs(paths) do
                    local ok2,r = pcall(function() return Utility:LarpNet(p) end)
                    if ok2 and r and r.Parent then purchaseRemote=r; return end
                end
            end)
            return purchaseRemote
        end

        local function firePurchaseNatural(prompt)
            if not prompt or not prompt.Parent or not prompt.Enabled then return end
            pcall(function()
                if fireproximityprompt then fireproximityprompt(prompt) end
            end)
            task.spawn(function()
                local remote = resolvePurchaseRemote()
                if remote then
                    pcall(function()
                        if remote:IsA("RemoteFunction") then
                            remote:InvokeServer(prompt.Parent)
                        elseif remote:IsA("RemoteEvent") then remote:FireServer(prompt.Parent) end
                    end)
                end
            end)
        end

        local carpetLockConn = nil
        local function startCarpetLock()
            if carpetLockConn then carpetLockConn:Disconnect(); carpetLockConn = nil end
            local function ensureCarpet()
                pcall(function()
                    local char = LocalPlayer.Character
                    local hum  = char and char:FindFirstChildOfClass("Humanoid")
                    if not hum then return end
                    local toolName = Config.TpSettings and Config.TpSettings.Tool or "Flying Carpet"
                    if not char:FindFirstChild(toolName) then
                        local tool = LocalPlayer.Backpack:FindFirstChild(toolName)
                        if tool then hum:EquipTool(tool) end
                    end
                end)
            end
            task.spawn(function()
                for _ = 1, 15 do
                    if not autoBuyActive then break end
                    ensureCarpet()
                    task.wait(0.3)
                    local char = LocalPlayer.Character
                    local toolName = Config.TpSettings and Config.TpSettings.Tool or "Flying Carpet"
                    if char and char:FindFirstChild(toolName) then break end
                end
            end)
            carpetLockConn = RunService.Heartbeat:Connect(function()
                if not autoBuyActive then return end
                pcall(function()
                    local char = LocalPlayer.Character
                    local hum  = char and char:FindFirstChildOfClass("Humanoid")
                    if not hum then return end
                    local toolName = Config.TpSettings and Config.TpSettings.Tool or "Flying Carpet"
                    if not char:FindFirstChild(toolName) then
                        local tool = LocalPlayer.Backpack:FindFirstChild(toolName)
                        if tool then hum:EquipTool(tool) end
                    end
                end)
            end)
        end
        local function stopCarpetLock()
            if carpetLockConn then carpetLockConn:Disconnect(); carpetLockConn = nil end
        end

        local HOVER_HEIGHT  = 5
        local BUY_INTERVAL  = 0.08
        local DETECT_RADIUS = 17

        local lockedTarget = nil
        local lockedPart   = nil
        local lockedModel  = nil
        local lastBuy      = 0

        local function partAlive()
            return lockedPart  and lockedPart.Parent
                and lockedModel and lockedModel.Parent
        end
        local function promptAlive()
            return lockedTarget and lockedTarget.prompt
                and lockedTarget.prompt.Parent and lockedTarget.prompt.Enabled
        end

        local bodyPos = nil
        local function ensureBodyPos(hrp)
            if bodyPos and bodyPos.Parent == hrp then return bodyPos end
            if bodyPos then bodyPos:Destroy() end
            local bp = Instance.new("BodyPosition", hrp)
            bp.MaxForce    = Vector3.new(math.huge, math.huge, math.huge)
            bp.P           = 20000
            bp.D           = 1000
            bp.Position    = hrp.Position
            bodyPos = bp
            return bp
        end
        local function destroyBodyPos()
            if bodyPos then bodyPos:Destroy(); bodyPos = nil end
        end

        -- Per-frame BodyPosition follow while locked onto a conveyor item. Native callback
        -- keeps the per-frame flag/check cost flat under the obfuscator VM.
        RunService.Heartbeat:Connect(LPH_NO_VIRTUALIZE(function()
            if not autoBuyActive or not partAlive() then destroyBodyPos(); return end
            local char = LocalPlayer.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            if not hrp then destroyBodyPos(); return end

            local above = lockedPart.Position + Vector3.new(0, HOVER_HEIGHT, 0)
            local bp = ensureBodyPos(hrp)
            bp.Position = above
        end))

        task.spawn(function()
            while true do
                task.wait(BUY_INTERVAL)
                if not autoBuyActive then continue end
                if not partAlive()   then continue end
                if promptAlive() then firePurchaseNatural(lockedTarget.prompt) end
            end
        end)

        task.spawn(function()
            while true do
                task.wait(0.25)
                if not autoBuyActive then
                    lockedTarget=nil; lockedPart=nil; lockedModel=nil
                    stopCarpetLock()
                    destroyBodyPos()
                    continue
                end
                if lockedPart or lockedModel then
                    if not partAlive() then
                        ShowNotification("AUTO BUY"," Reached base, scanning...")
                        lockedTarget=nil; lockedPart=nil; lockedModel=nil
                    end
                    continue
                end
                local char = LocalPlayer.Character
                local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                if not hrp then continue end
                local radius = Config.AutoBuyRange or DETECT_RADIUS
                local best,bestDist = nil,math.huge
                for _,entry in ipairs(SharedState.ConveyorAnimals) do
                    if entry.prompt and entry.prompt.Parent and entry.prompt.Enabled
                    and entry.part  and entry.part.Parent then
                        local d = (hrp.Position - entry.part.Position).Magnitude
                        if d <= radius and d < bestDist then bestDist=d; best=entry end
                    end
                end
                if best then
                    lockedTarget = best
                    lockedPart   = best.part
                    lockedModel  = best.model or best.part.Parent
                    ShowNotification("AUTO BUY","[LOCK] "..best.name)
                    startCarpetLock()
                end
            end
        end)

        _G.AutoBuyOnToggle = function(active)
            if active then
                if _G.refreshConveyor then _G.refreshConveyor() end
                startCarpetLock()
            else
                stopCarpetLock()
            end
        end
    end)

    _G.JustAFanMiniActionsUI = {panel = panel, gui = maGui}
    return maGui
end

task.spawn(function()
    buildJustAFanMiniActionsUI()
    if Config.AutoHideMiniUI then
        local g = PlayerGui:FindFirstChild("JustAFanMiniActions")
        if g and g:FindFirstChild("MiniPanel") then g.MiniPanel.Visible = false end
    end
end)

-- Conveyor scanner. The only consumer of SharedState.ConveyorAnimals is the AutoBuy
-- locker loop, so when AutoBuy is OFF (the default) every iteration of this loop is
-- pure waste -- and the inner scan() walks Workspace:GetDescendants() + does string
-- ops on every TextLabel.Text, which is the kind of work that explodes under the
-- Luraph VM. Two fixes:
--   1. Gate the loop on _G.AutoBuyEsteira (set by the AutoBuy toggle). When off, the
--      whole tick is one branch, basically free.
--   2. Wrap the whole task body in LPH_NO_VIRTUALIZE so when AutoBuy IS on the heavy
--      scan runs at source speed instead of interpreted VM bytecode.
task.spawn(LPH_NO_VIRTUALIZE(function()
    if not game:IsLoaded() then game.Loaded:Wait() end; task.wait(2)
    local BL={STOLEN=true,STEAL=true,PURCHASE=true,COMPRAR=true,BUY=true,COLLECT=true,COLETAR=true,CASH=true,VALUE=true,BASE=true,EMPTY=true,GENERATION=true,COMMON=true,UNCOMMON=true,RARE=true,EPIC=true,LEGENDARY=true,DIVINE=true,RAINBOW=true,CURSED=true,GOLD=true,DIAMOND=true,CANDY=true,MUTATION=true}
    local function cvOk(t) if not t or t=="" then return false end; local c=(t:gsub("<[^>]+>","")):match("^%s*(.-)%s*$") or ""; if #c<=1 then return false end; local u=c:upper(); if u:find("^%$") or u:find("/S$") or u:find("^[%d%.]+") then return false end; return not BL[u] end
    local function pgv(t) if type(t)~="string" then return nil end; local u=t:gsub("<[^>]+>",""):upper(); if not u:find("%$") or not u:find("/S") then return nil end; local c=u:gsub("%$",""):gsub("/S",""):gsub("%s+",""); local n=tonumber(c:match("[%d%.]+")); if not n then return nil end; if c:find("B") then return n*1e9 elseif c:find("M") then return n*1e6 elseif c:find("K") then return n*1e3 else return n end end
    local function exM(m) if not m then return nil,nil,0 end; local bN,bG,bV=nil,nil,0; for _,bb in ipairs(m:GetDescendants()) do if bb:IsA("BillboardGui") or bb:IsA("SurfaceGui") then for _,d in ipairs(bb:GetDescendants()) do if d:IsA("TextLabel") and d.Text then local v=pgv(d.Text); if v and v>bV then bV=v;bG=d.Text:gsub("<[^>]+>",""); local co=d.Parent; if co then local f=nil; for _,s in ipairs(co:GetChildren()) do if s:IsA("TextLabel") and s.Name=="DisplayName" then local c2=(s.Text or ""):gsub("<[^>]+>",""):match("^%s*(.-)%s*$"); if cvOk(c2) then f=c2;break end end end; if not f then local bt,bl=nil,0; for _,s in ipairs(co:GetChildren()) do if s:IsA("TextLabel") then local c2=(s.Text or ""):gsub("<[^>]+>",""):match("^%s*(.-)%s*$") or ""; if cvOk(c2) and #c2>bl then bt,bl=c2,#c2 end end end; if bt then f=bt end end; if f then bN=f end end end end end end end; return bN,bG,bV end
    local function scan() local res,vis={},{}; local deb=Workspace:FindFirstChild("Debris") or Workspace; for _,c in ipairs(deb:GetChildren()) do if c:IsA("Model") or c:IsA("BasePart") then local n,g,gv=exM(c); if gv and gv>0 then local p=c:IsA("BasePart") and c or (c:IsA("Model") and c.PrimaryPart); if not p then for _,ch in ipairs(c:GetChildren()) do if ch:IsA("BasePart") then p=ch;break end end end; if p then table.insert(vis,{name=n,gen=g,gv=gv,part=p,model=c}) end end end end; for _,obj in ipairs(Workspace:GetDescendants()) do if obj:IsA("ProximityPrompt") and obj.Enabled then local tx=(obj.ActionText or ""):lower(); if tx:find("purchase") or tx:find("comprar") or tx:find("buy") then local pp=obj.Parent; if not pp then continue end; local rp=pp:IsA("Attachment") and pp.Parent or pp; if not(rp and rp:IsA("BasePart")) then continue end; local fN,fG,fGV,fM="Brainrot","",0,nil; local md,mt=15,nil; for _,v in ipairs(vis) do local d=(v.part.Position-rp.Position).Magnitude; if d<md then md=d;mt=v end end; if mt then fN=mt.name or "Brainrot";fG=mt.gen or "";fGV=mt.gv or 0;fM=mt.model else local sr=rp;local cu=rp; while cu and cu.Parent and cu.Parent~=Workspace do sr=cu;cu=cu.Parent end; local n,g,gv=exM(sr); if n then fN=n end; if g then fG=g end; if gv and gv>0 then fGV=gv end; fM=sr end; table.insert(res,{name=fN,gen=fG,gv=fGV,prompt=obj,part=rp,model=fM,uid="conv_"..tostring(obj)}) end end end; return res end
    while true do
        if _G.AutoBuyEsteira then
            local ok2,found=pcall(scan)
            if ok2 and found then
                SharedState.ConveyorAnimals=found
                local b=-1
                for _,e in ipairs(found) do if(e.gv or 0)>b then b=e.gv end end
                SharedState.BestConveyorGv=b
            end
        end
        task.wait(0.5)
    end
end))


task.spawn(function()
    local shGui=Instance.new("ScreenGui"); shGui.Name="XiStealingHUD"; shGui.ResetOnSpawn=false; shGui.Enabled=Config.ShowStealingHUD~=false; shGui.Parent=PlayerGui

    if not Config.Positions.StealersHUD then Config.Positions.StealersHUD = {X=0.8, Y=0.15} end

    local mf=Instance.new("Frame",shGui)
    mf.Size=UDim2.new(0,360,0,420)
    mf.Position=UDim2.new(Config.Positions.StealersHUD.X,0,Config.Positions.StealersHUD.Y,0)
    mf.BackgroundColor3=Theme.Background; mf.BackgroundTransparency=0.31; mf.BorderSizePixel=0; mf.ClipsDescendants=true
    Instance.new("UICorner",mf).CornerRadius=UDim.new(0,12)
    local ms=Instance.new("UIStroke",mf); ms.Color=Theme.Accent1; ms.Thickness=1.5; ms.Transparency=0.5

    local hdr=Instance.new("Frame",mf); hdr.Size=UDim2.new(1,0,0,38); hdr.BackgroundTransparency=1
    MakeDraggable(hdr, mf, "StealersHUD")

    local ttl=Instance.new("TextLabel",hdr); ttl.Size=UDim2.new(1,-12,1,0); ttl.Position=UDim2.new(0,10,0,0); ttl.BackgroundTransparency=1; ttl.Text=" Stealers"; ttl.Font=Enum.Font.GothamBlack; ttl.TextSize=15; ttl.TextColor3=Theme.TextPrimary; ttl.TextXAlignment=Enum.TextXAlignment.Left

    local sc=Instance.new("ScrollingFrame",mf); sc.Size=UDim2.new(1,-10,1,-44); sc.Position=UDim2.new(0,5,0,42); sc.BackgroundTransparency=1; sc.BorderSizePixel=0; sc.ScrollBarThickness=3; sc.ScrollBarImageColor3=Theme.Accent1
    local lay=Instance.new("UIListLayout",sc); lay.Padding=UDim.new(0,5)

    local rows={}

    local stealerBtnDefs = {
        {icon="RKT", cmd="rocket"},
        {icon="RAG", cmd="ragdoll"},
        {icon="JAIL", cmd="jail"},
        {icon="BAL", cmd="balloon"},
    }

    local function mkRow(plr)
        local row=Instance.new("Frame",sc); row.Name=plr.Name
        row.Size=UDim2.new(1,0,0,70); row.BackgroundColor3=Theme.Surface; row.BorderSizePixel=0
        Instance.new("UICorner",row).CornerRadius=UDim.new(0,8)
        local rowStroke=Instance.new("UIStroke",row); rowStroke.Color=Theme.Accent2; rowStroke.Thickness=1.5; rowStroke.Transparency=0.6

        local dn=Instance.new("TextLabel",row); dn.Size=UDim2.new(1,-10,0,22); dn.Position=UDim2.new(0,10,0,6); dn.BackgroundTransparency=1; dn.Text=plr.DisplayName; dn.Font=Enum.Font.GothamBold; dn.TextSize=14; dn.TextColor3=Color3.new(1,1,1); dn.TextXAlignment=Enum.TextXAlignment.Left

        local bl=Instance.new("TextLabel",row); bl.Size=UDim2.new(1,-10,0,14); bl.Position=UDim2.new(0,10,0,30); bl.BackgroundTransparency=1; bl.Text="..."; bl.Font=Enum.Font.GothamMedium; bl.TextSize=11; bl.TextColor3=Color3.fromRGB(255,100,100); bl.TextXAlignment=Enum.TextXAlignment.Left; bl.TextTruncate=Enum.TextTruncate.AtEnd

        local btnStartX = 10
        local btnW = 46
        local btnH = 22
        local btnGap = 4
        for i, def in ipairs(stealerBtnDefs) do
            local b=Instance.new("TextButton",row)
            b.Size=UDim2.new(0,btnW,0,btnH)
            b.Position=UDim2.new(0, btnStartX + (i-1)*(btnW+btnGap), 1, -(btnH+6))
            b.AutoButtonColor=false
            b.Text=def.icon; b.TextSize=10; b.Font=Enum.Font.GothamBlack
            b.TextColor3=Theme.TextPrimary
            b.BackgroundColor3=Theme.Surface; b.BackgroundTransparency=0
            Instance.new("UICorner",b).CornerRadius=UDim.new(0,6)
            local bStroke=Instance.new("UIStroke",b); bStroke.Color=Theme.SurfaceHighlight; bStroke.Thickness=1.5; bStroke.Transparency=0.4

            b.MouseEnter:Connect(function() b.BackgroundColor3=Color3.fromRGB(50,52,60); bStroke.Transparency=0.1 end)
            b.MouseLeave:Connect(function() b.BackgroundColor3=Color3.fromRGB(35,37,43); bStroke.Transparency=0.4 end)

            b.MouseButton1Click:Connect(function()
                if isBlacklisted(plr.Name) then
                    ShowNotification("STEALERS","[!] "..plr.Name.." is blacklisted")
                    return
                end
                local adminFunc = _G.runAdminCommand
                if not adminFunc then
                    task.wait(0.1)
                    adminFunc = _G.runAdminCommand
                end
                if not adminFunc then
                    ShowNotification("STEALERS","Admin not ready yet")
                    return
                end
                ShowNotification("STEALERS","-> "..def.cmd.." on "..plr.Name)
                local ok, result = pcall(adminFunc, plr, def.cmd)
                if ok and result then
                    ShowNotification("STEALERS","+ "..def.cmd.." sent to "..plr.Name)
                else
                    ShowNotification("STEALERS","x "..def.cmd.." failed on "..plr.Name)
                end
            end)
        end

        local blBtn=Instance.new("TextButton",row)
        blBtn.Size=UDim2.new(0,btnW,0,btnH)
        blBtn.Position=UDim2.new(0, btnStartX + #stealerBtnDefs*(btnW+btnGap), 1, -(btnH+6))
        blBtn.AutoButtonColor=false; blBtn.Text="BL"; blBtn.TextSize=10; blBtn.Font=Enum.Font.GothamBlack
        blBtn.TextColor3=Color3.fromRGB(255,200,200)
        blBtn.BackgroundColor3=Color3.fromRGB(120,20,20); blBtn.BackgroundTransparency=0
        Instance.new("UICorner",blBtn).CornerRadius=UDim.new(0,6)
        local blStroke=Instance.new("UIStroke",blBtn); blStroke.Color=Color3.fromRGB(200,50,50); blStroke.Thickness=1.5; blStroke.Transparency=0.3
        blBtn.MouseEnter:Connect(function() blBtn.BackgroundColor3=Color3.fromRGB(180,30,30); blStroke.Transparency=0.05 end)
        blBtn.MouseLeave:Connect(function() blBtn.BackgroundColor3=Color3.fromRGB(120,20,20); blStroke.Transparency=0.3 end)
        blBtn.MouseButton1Click:Connect(function()
            local already=false
            for _,n in ipairs(BlacklistedPlayers) do if n:lower()==plr.Name:lower() then already=true;break end end
            if already then ShowNotification("BLACKLIST",plr.Name.." already blacklisted");return end
            table.insert(BlacklistedPlayers,plr.Name); Config.Blacklist=BlacklistedPlayers; SaveConfig()
            if refreshBlacklistUI then refreshBlacklistUI() end
            blBtn.BackgroundColor3=Color3.fromRGB(30,120,50); blBtn.Text="OK"
            ShowNotification("BLACKLIST","Blacklisted: "..plr.Name)
            task.delay(1.2,function() if blBtn and blBtn.Parent then blBtn.BackgroundColor3=Color3.fromRGB(120,20,20);blBtn.Text="BL" end end)
        end)

        task.spawn(function()
            while row and row.Parent do
                if not plr or not plr.Parent or not Players:FindFirstChild(plr.Name) then row:Destroy();return end
                if plr:GetAttribute("Stealing") then
                    bl.Text=plr:GetAttribute("StealingIndex") or "..."
                else
                    row:Destroy();return
                end
                task.wait(0.5)
            end
        end)
        return row
    end

    while true do
        task.wait(1)
        mf.Visible=Config.ShowStealingHUD~=false
        if mf.Visible then
            for _,p in ipairs(Players:GetPlayers()) do
                if p~=LocalPlayer and p:GetAttribute("Stealing") and not rows[p.UserId] then
                    local r=mkRow(p); rows[p.UserId]=r
                    r.AncestryChanged:Connect(function() if not r.Parent then rows[p.UserId]=nil end end)
                end
            end
            sc.CanvasSize=UDim2.new(0,0,0,lay.AbsoluteContentSize.Y)
        end
    end
end)

task.spawn(function()
    local espGui = Instance.new("ScreenGui")
    espGui.Name = "XiStealingPlotESP"
    espGui.ResetOnSpawn = false
    espGui.Enabled = Config.ShowStealingPlotESP ~= false
    espGui.Parent = PlayerGui

    local byUser = {}

    local SyncStealEsp = nil
    local AnimalsDataStealEsp = nil
    local AnimalsSharedStealEsp = nil
    local function ensureStealEspModules()
        if not SyncStealEsp then
            pcall(function()
                SyncStealEsp = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Synchronizer"))
            end)
        end
        if not AnimalsDataStealEsp then
            pcall(function()
                AnimalsDataStealEsp = require(ReplicatedStorage:WaitForChild("Datas"):WaitForChild("Animals"))
            end)
        end
        if not AnimalsSharedStealEsp then
            pcall(function()
                AnimalsSharedStealEsp = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Animals"))
            end)
        end
    end

    local function normStealName(s)
        return tostring(s or ""):lower():gsub("%s+", ""):gsub("[^%w]", "")
    end

    local function stealIdxMatchesAnimal(stealIdx, adIndex, displayName)
        if stealIdx == nil or stealIdx == "" then return false end
        local si = tostring(stealIdx)
        local sil = si:lower()
        if adIndex then
            local ai = tostring(adIndex)
            if ai == si or ai:lower() == sil then return true end
        end
        if displayName then
            local d = tostring(displayName)
            local dl = d:lower()
            if dl == sil or dl:find(sil, 1, true) or sil:find(dl, 1, true) then return true end
            if normStealName(d) == normStealName(si) then return true end
        end
        local AD = AnimalsDataStealEsp
        if AD then
            local infDirect = AD[si]
            if type(infDirect) == "table" and infDirect.DisplayName and displayName then
                if infDirect.DisplayName:lower() == displayName:lower() or normStealName(infDirect.DisplayName) == normStealName(displayName) then
                    return true
                end
            end
            if adIndex and AD[adIndex] and type(AD[adIndex]) == "table" and AD[adIndex].DisplayName then
                local disp = AD[adIndex].DisplayName
                if disp:lower() == sil or normStealName(disp) == normStealName(si) then return true end
            end
            for key, inf in pairs(AD) do
                if type(inf) == "table" and inf.DisplayName then
                    if key == si or key:lower() == sil then
                        if not displayName or inf.DisplayName:lower() == displayName:lower() or normStealName(inf.DisplayName) == normStealName(displayName) then
                            return true
                        end
                    end
                    if inf.DisplayName:lower() == sil or normStealName(inf.DisplayName) == normStealName(si) then
                        if adIndex and (key == adIndex or key:lower() == tostring(adIndex):lower()) then return true end
                        if displayName and (normStealName(inf.DisplayName) == normStealName(displayName) or inf.DisplayName:lower() == displayName:lower()) then
                            return true
                        end
                    end
                end
            end
        end
        return false
    end

    local function findPlotForPlayer(plr)
        if not plr then return nil end
        local plots = Workspace:FindFirstChild("Plots")
        if not plots then return nil end
        local dn = (plr.DisplayName or ""):lower()
        local un = (plr.Name or ""):lower()
        for _, plot in ipairs(plots:GetChildren()) do
            local sign = plot:FindFirstChild("PlotSign")
            if sign then
                local surfaceGui = sign:FindFirstChildWhichIsA("SurfaceGui", true)
                if surfaceGui then
                    local label = surfaceGui:FindFirstChildWhichIsA("TextLabel", true)
                    if label then
                        local text = label.Text:lower()
                        if (dn ~= "" and text:find(dn, 1, true)) or (un ~= "" and text:find(un, 1, true)) then return plot end
                    end
                end
            end
        end
        local pkg = ReplicatedStorage:FindFirstChild("Packages")
        local syncMod = pkg and pkg:FindFirstChild("Synchronizer")
        if syncMod then
            local okReq, Sync = pcall(function() return require(syncMod) end)
            if okReq and Sync then
                for _, plot in ipairs(plots:GetChildren()) do
                    local okCh, ch = pcall(function() return Sync:Get(plot.Name) end)
                    if okCh and ch then
                        local owner = ch:Get("Owner")
                        if owner then
                            if typeof(owner) == "Instance" and owner:IsA("Player") and owner == plr then return plot end
                            if type(owner) == "table" and owner.UserId == plr.UserId then return plot end
                        end
                    end
                end
            end
        end
        return nil
    end

    local function getPlotSignAdorneePart(plot)
        if not plot then return nil end
        local sign = plot:FindFirstChild("PlotSign")
        if not sign then return nil end
        if sign:IsA("BasePart") then return sign end
        if sign:IsA("Model") then return sign.PrimaryPart or sign:FindFirstChildWhichIsA("BasePart", true) end
        return sign:FindFirstChildWhichIsA("BasePart", true)
    end

    local function resolveStolenPetEntry(plr, stealIdx)
        if stealIdx == nil or stealIdx == "" then return nil end
        ensureStealEspModules()
        local myPlot = findPlotForPlayer(plr)
        local myPlotName = myPlot and myPlot.Name
        local cache = SharedState.AllAnimalsCache
        local best, bestGv = nil, -1

        local function considerEntry(entry, gv)
            if not entry or not entry.plot then return end
            if myPlotName and entry.plot == myPlotName then return end
            if entry.owner and entry.owner == plr.Name then return end
            local g = tonumber(gv) or tonumber(entry.genValue) or 0
            if g > bestGv then
                bestGv = g
                best = entry
            end
        end

        if cache then
            for _, a in ipairs(cache) do
                if a and a.name and a.owner and a.owner ~= plr.Name then
                    if stealIdxMatchesAnimal(stealIdx, nil, a.name) then considerEntry(a, a.genValue) end
                end
            end
        end

        if best then return best end

        if not SyncStealEsp or not AnimalsDataStealEsp then return nil end
        local plots = Workspace:FindFirstChild("Plots")
        if not plots then return nil end

        for _, plot in ipairs(plots:GetChildren()) do
            if not myPlotName or plot.Name ~= myPlotName then
                local okCh, ch = pcall(function() return SyncStealEsp:Get(plot.Name) end)
                if okCh and ch then
                    local owner = ch:Get("Owner")
                    local ownerName = nil
                    if typeof(owner) == "Instance" and owner:IsA("Player") then
                        ownerName = owner.Name
                    elseif type(owner) == "table" and owner.Name then ownerName = owner.Name end
                    if ownerName ~= plr.Name then
                        local al = ch:Get("AnimalList")
                        if type(al) == "table" then
                            for slot, ad in pairs(al) do
                                if type(ad) == "table" and ad.Index then
                                    local aInfo = AnimalsDataStealEsp[ad.Index]
                                    local disp = (aInfo and aInfo.DisplayName) or ad.Index
                                    if stealIdxMatchesAnimal(stealIdx, ad.Index, disp) then
                                        local gv = 0
                                        pcall(function()
                                            if AnimalsSharedStealEsp then
                                                gv = AnimalsSharedStealEsp:GetGeneration(ad.Index, ad.Mutation, ad.Traits, nil)
                                            end
                                        end)
                                        considerEntry({
                                            name = disp,
                                            index = ad.Index,
                                            genText = "",
                                            genValue = gv,
                                            mutation = ad.Mutation,
                                            traits = "",
                                            owner = ownerName or "?",
                                            plot = plot.Name,
                                            slot = tostring(slot),
                                            uid = plot.Name .. "_" .. tostring(slot),
                                        }, gv)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        return best
    end

    local function clearRow(uid)
        local r = byUser[uid]
        if not r then return end
        if r.bill and r.bill.Parent then r.bill:Destroy() end
        byUser[uid] = nil
    end

    Players.PlayerRemoving:Connect(function(plr)
        clearRow(plr.UserId)
    end)

    while true do
        task.wait(0.35)
        local enabled = Config.ShowStealingPlotESP ~= false
        espGui.Enabled = enabled
        if not enabled then
            local clearIds = {}
            for uid in pairs(byUser) do table.insert(clearIds, uid) end
            for _, uid in ipairs(clearIds) do clearRow(uid) end
        else
            local attachFn = _G.XiAttachPet3DPreview
            local active = {}
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer and plr:GetAttribute("Stealing") then
                    local idx = plr:GetAttribute("StealingIndex")
                    if idx ~= nil and idx ~= "" then
                        local plot = findPlotForPlayer(plr)
                        local part = getPlotSignAdorneePart(plot)
                        if part and part:IsDescendantOf(Workspace) then
                            active[plr.UserId] = true
                            local petEntry = resolveStolenPetEntry(plr, idx)
                            local petName = petEntry and petEntry.name or tostring(idx)
                            local stealKey = tostring(idx) .. "|" .. tostring(petEntry and petEntry.uid or "") .. "|" .. part:GetFullName()
                            local row = byUser[plr.UserId]
                            if row and (row.stealKey ~= stealKey or row.adornee ~= part) then
                                clearRow(plr.UserId)
                                row = nil
                            end
                            if not byUser[plr.UserId] then
                                local bb = Instance.new("BillboardGui")
                                bb.Name = "StealPlotESP_" .. plr.Name
                                bb.Adornee = part
                                bb.AlwaysOnTop = true
                                bb.Size = UDim2.new(0, 210, 0, 132)
                                bb.StudsOffset = Vector3.new(0, 7, 0)
                                bb.MaxDistance = 650
                                bb.LightInfluence = 0
                                bb.Parent = espGui

                                local root = Instance.new("Frame")
                                root.Name = "Root"
                                root.Size = UDim2.new(1, 0, 1, 0)
                                root.BackgroundColor3 = Theme.Background
                                root.BackgroundTransparency = 0.34
                                root.BorderSizePixel = 0
                                root.Parent = bb
                                Instance.new("UICorner", root).CornerRadius = UDim.new(0, 10)
                                local stroke = Instance.new("UIStroke", root)
                                stroke.Color = Color3.fromRGB(140, 140, 140)
                                stroke.Thickness = 1.2
                                stroke.Transparency = 0.4

                                local title = Instance.new("TextLabel")
                                title.Name = "Title"
                                title.Size = UDim2.new(1, -10, 0, 22)
                                title.Position = UDim2.new(0, 5, 0, 4)
                                title.BackgroundTransparency = 1
                                title.Font = Enum.Font.GothamBlack
                                title.TextSize = 11
                                title.TextColor3 = Theme.TextPrimary
                                title.TextXAlignment = Enum.TextXAlignment.Left
                                title.TextTruncate = Enum.TextTruncate.AtEnd
                                title.Text = plr.DisplayName .. " -> " .. petName
                                title.Parent = root

                                local sub = Instance.new("TextLabel")
                                sub.Name = "Sub"
                                sub.Size = UDim2.new(1, -10, 0, 14)
                                sub.Position = UDim2.new(0, 5, 0, 26)
                                sub.BackgroundTransparency = 1
                                sub.Font = Enum.Font.GothamMedium
                                sub.TextSize = 9
                                sub.TextColor3 = Color3.fromRGB(185, 185, 185)
                                sub.TextXAlignment = Enum.TextXAlignment.Left
                                sub.Text = "Stealing"
                                sub.Parent = root

                                local previewHost = Instance.new("Frame")
                                previewHost.Name = "PreviewHost"
                                previewHost.Size = UDim2.new(1, -10, 0, 80)
                                previewHost.Position = UDim2.new(0, 5, 0, 42)
                                previewHost.BackgroundTransparency = 1
                                previewHost.BorderSizePixel = 0
                                previewHost.Parent = root

                                if attachFn then
                                    local petData = {
                                        petName = petName,
                                        previewCacheKey = petName ~= "" and petName:lower() or nil,
                                        animalData = {
                                            plot = petEntry and petEntry.plot or nil,
                                            slot = petEntry and petEntry.slot or nil,
                                            Index = petEntry and (petEntry.index or petEntry.Index) or nil,
                                            index = petEntry and (petEntry.index or petEntry.Index) or nil,
                                        }
                                    }
                                    task.defer(function()
                                        if not previewHost.Parent then return end
                                        local okAttach = pcall(function()
                                            attachFn(previewHost, petData, {
                                                Size = UDim2.new(1, 0, 1, 0),
                                                Position = UDim2.new(0, 0, 0, 0),
                                                CornerRadius = 8,
                                                Fov = 34,
                                                ForceLiveModelOnly = false,
                                                ForceFallbackModel = false,
                                                ForceEmbeddedAnimation = false,
                                            })
                                        end)
                                        if (not okAttach) and previewHost.Parent then
                                            local no3dErr = Instance.new("TextLabel")
                                            no3dErr.Size = UDim2.new(1, 0, 1, 0)
                                            no3dErr.BackgroundTransparency = 0.35
                                            no3dErr.BackgroundColor3 = Theme.SurfaceHighlight
                                            no3dErr.Text = "Failed to load 3D preview"
                                            no3dErr.Font = Enum.Font.GothamBold
                                            no3dErr.TextSize = 10
                                            no3dErr.TextColor3 = Theme.TextSecondary
                                            no3dErr.Parent = previewHost
                                            Instance.new("UICorner", no3dErr).CornerRadius = UDim.new(0, 8)
                                        end
                                    end)
                                else
                                    local no3d = Instance.new("TextLabel")
                                    no3d.Size = UDim2.new(1, 0, 1, 0)
                                    no3d.BackgroundTransparency = 0.35
                                    no3d.BackgroundColor3 = Theme.SurfaceHighlight
                                    no3d.Text = "Loading preview..."
                                    no3d.Font = Enum.Font.GothamBold
                                    no3d.TextSize = 10
                                    no3d.TextColor3 = Theme.TextSecondary
                                    no3d.Parent = previewHost
                                    Instance.new("UICorner", no3d).CornerRadius = UDim.new(0, 8)
                                end

                                byUser[plr.UserId] = { bill = bb, adornee = part, stealKey = stealKey }
                            else
                                row = byUser[plr.UserId]
                                if row and row.bill and row.bill.Parent then
                                    local rootFrame = row.bill:FindFirstChild("Root")
                                    if rootFrame then
                                        local t = rootFrame:FindFirstChild("Title")
                                        if t and t:IsA("TextLabel") then t.Text = plr.DisplayName .. " -> " .. petName end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            local stale = {}
            for uid in pairs(byUser) do
                if not active[uid] then table.insert(stale, uid) end
            end
            for _, uid in ipairs(stale) do clearRow(uid) end
        end
    end
end)

do
    if not Config.Positions.AutoTurret then Config.Positions.AutoTurret = {X = 0.74, Y = 0.58} end
    if not Config.Positions.GrabKick   then Config.Positions.GrabKick   = {X = 0.74, Y = 0.78} end
    if Config.AutoTurretEnabled == nil then Config.AutoTurretEnabled = false end
    if Config.GrabKickEnabled   == nil then Config.GrabKickEnabled   = false end
    SaveConfig()
end

task.spawn(function()
    local OServices = {
        OPlayers         = game:GetService("Players"),
        OLighting        = game:GetService("Lighting"),
        OMaterialService = game:GetService("MaterialService"),
    }

    local OXMin, OXMax = -560, -240

    local OClothingClasses = {
        "Shirt","Pants","ShirtGraphic","Accessory","Hat","HairAccessory",
        "FaceAccessory","NeckAccessory","ShoulderAccessory","FrontAccessory",
        "BackAccessory","WaistAccessory",
    }

    local function OSafeDestroy(obj)
        if obj.Name == "Overhead" then return end
        pcall(function() obj:Destroy() end)
    end

    local function OIsClothing(obj)
        for _, c in ipairs(OClothingClasses) do if obj:IsA(c) then return true end end
    end

    local function OIsCharacterPart(obj)
        for _, plr in ipairs(OServices.OPlayers:GetPlayers()) do
            if plr.Character and obj:IsDescendantOf(plr.Character) then return true end
        end
    end

    local function OIsOutOfRange(obj)
        if obj:IsA("BasePart") then
            local x = obj.Position.X
            return x < OXMin or x > OXMax
        end
    end

    local BASE_NAMES_O = { "baseplate","spawnlocation","spawn location","spawn" }

    local function OIsBase(obj)
        if not obj:IsA("BasePart") or not obj.Anchored then return false end
        local n = obj.Name:lower()
        for _, b in ipairs(BASE_NAMES_O) do if n:find(b,1,true) then return true end end
        return false
    end

    local function OIsInBase(obj)
        local p = obj.Parent
        while p and p ~= workspace do
            if OIsBase(p) then return true end
            p = p.Parent
        end
        return false
    end

    local function OMakeTransparent(obj)
        pcall(function()
            if OIsBase(obj) and not OIsCharacterPart(obj) then obj.Transparency = 1; obj.CastShadow = false end
        end)
    end

    local function OCleanObject(obj)
        pcall(function()
            if obj:IsA("SurfaceAppearance") then
                OSafeDestroy(obj)
            elseif obj:IsA("Decal") or obj:IsA("Texture") then
                if not (obj.Name=="face" and obj.Parent and obj.Parent.Name=="Head") then OSafeDestroy(obj) end
            elseif obj:IsA("SpecialMesh") then
                obj.TextureId = ""
            elseif obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam") then
                OSafeDestroy(obj)
            elseif obj:IsA("PointLight") or obj:IsA("SpotLight") or obj:IsA("SurfaceLight") then
                OSafeDestroy(obj)
            elseif obj:IsA("Fire") or obj:IsA("Smoke") or obj:IsA("Sparkles") or obj:IsA("Explosion") then
                OSafeDestroy(obj)
            elseif obj:IsA("Animation") or obj:IsA("AnimationController") then
                OSafeDestroy(obj)
            elseif obj:IsA("BasePart") then
                obj.CastShadow = false; obj.Material = Enum.Material.Plastic
                obj.MaterialVariant = ""; obj.Reflectance = 0
            end
        end)
    end

    local function OStopAnimations(animator)
        pcall(function()
            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                local isChar = false
                for _, plr in ipairs(OServices.OPlayers:GetPlayers()) do
                    if plr.Character and animator:IsDescendantOf(plr.Character) then isChar = true; break end
                end
                if not isChar then track:Stop() end
            end
        end)
    end

    local function OOptimizeCharacter(char)
        if not char then return end
        task.spawn(function()
            task.wait(0.3)
            for _, obj in ipairs(char:GetDescendants()) do
                if OIsClothing(obj) then OSafeDestroy(obj)
                else OCleanObject(obj) end
            end
        end)
    end

    local function OApplyGreySky()
        pcall(function()
            for _, obj in ipairs(OServices.OLighting:GetChildren()) do
                if obj:IsA("Sky") then obj:Destroy() end
            end
            local sky = Instance.new("Sky")
            sky.SkyboxBk = ""; sky.SkyboxDn = ""; sky.SkyboxFt = ""
            sky.SkyboxLf = ""; sky.SkyboxRt = ""; sky.SkyboxUp = ""
            sky.CelestialBodiesShown = false; sky.Parent = OServices.OLighting
        end)
    end

    local function OOptimizeLighting()
        local L = OServices.OLighting
        L.GlobalShadows = false; L.FogEnd = 9e9; L.FogStart = 9e9
        L.EnvironmentDiffuseScale = 0; L.EnvironmentSpecularScale = 0
        L.Brightness = 1.5; L.Ambient = Color3.fromRGB(60,60,60)
        for _, v in ipairs(L:GetChildren()) do
            if v:IsA("BloomEffect") or v:IsA("BlurEffect") or v:IsA("ColorCorrectionEffect")
            or v:IsA("SunRaysEffect") or v:IsA("DepthOfFieldEffect")
            or v:IsA("Atmosphere") or v:IsA("Clouds") then
                v:Destroy()
            end
        end
        OApplyGreySky()
    end

    local function OApplyTerrain()
        pcall(function()
            local T = workspace.Terrain
            T.Decoration = false; T.WaterWaveSize = 0; T.WaterWaveSpeed = 0
            T.WaterReflectance = 0; T.WaterTransparency = 1
        end)
    end

    pcall(function()
        settings().Rendering.QualityLevel        = Enum.QualityLevel.Level01
        settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level01
        settings().Physics.AllowSleep = true
        settings().Physics.PhysicsEnvironmentalThrottle =
            Enum.EnviromentalPhysicsThrottle.Skip
    end)
    pcall(function() setfpscap(999) end)

    task.spawn(function()
        if not game:IsLoaded() then game.Loaded:Wait() end
        task.wait(2)
        OOptimizeLighting()
        OApplyTerrain()
        for _, obj in ipairs(workspace:GetDescendants()) do
            if OIsBase(obj) then
                OMakeTransparent(obj)
            elseif OIsClothing(obj) then
                OSafeDestroy(obj)
            elseif OIsInBase(obj) then
            elseif OIsCharacterPart(obj) then
            elseif OIsOutOfRange(obj) then
                OSafeDestroy(obj)
            else
                OCleanObject(obj)
                if obj:IsA("Animator") then OStopAnimations(obj) end
            end
        end
        for _, obj in ipairs(workspace:GetDescendants()) do OMakeTransparent(obj) end
    end)

    task.spawn(function()
        while true do
            task.wait(2)
            pcall(function()
                local L = OServices.OLighting
                for _, obj in ipairs(L:GetChildren()) do
                    if obj:IsA("Atmosphere") or obj:IsA("Clouds") or obj:IsA("PostEffect") then OSafeDestroy(obj) end
                end
            end)
        end
    end)

    -- These three handlers each fire on EVERY descendant added to Workspace / Lighting /
    -- MaterialService respectively. The world optimizer is the busiest of them -- every
    -- new game part hits OIsBase + OIsClothing + OIsInBase + OIsCharacterPart + OCleanObject.
    -- Native callbacks keep big spawn bursts cheap even under the obfuscator VM.
    workspace.DescendantAdded:Connect(LPH_NO_VIRTUALIZE(function(obj)
        task.defer(function()
            if OIsBase(obj) then OMakeTransparent(obj); return end
            if OIsClothing(obj) then OSafeDestroy(obj)
            elseif OIsInBase(obj) then
            elseif OIsCharacterPart(obj) then
            elseif OIsOutOfRange(obj) then OSafeDestroy(obj)
            else
                OCleanObject(obj)
                if obj:IsA("Animator") then OStopAnimations(obj) end
            end
        end)
    end))

    OServices.OLighting.DescendantAdded:Connect(LPH_NO_VIRTUALIZE(function(obj)
        if obj:IsA("Atmosphere") or obj:IsA("Clouds") or obj:IsA("PostEffect") then OSafeDestroy(obj) end
    end))

    OServices.OMaterialService.DescendantAdded:Connect(LPH_NO_VIRTUALIZE(function(obj)
        OSafeDestroy(obj)
    end))

    for _, plr in ipairs(OServices.OPlayers:GetPlayers()) do
        OOptimizeCharacter(plr.Character)
        plr.CharacterAdded:Connect(OOptimizeCharacter)
    end
    OServices.OPlayers.PlayerAdded:Connect(function(plr)
        plr.CharacterAdded:Connect(OOptimizeCharacter)
    end)

    task.spawn(function()
        while true do
            task.wait(15)
            pcall(function() collectgarbage("collect") end)
        end
    end)

end)

;(function()
    if Config.Positions.AutoTurret == nil then Config.Positions.AutoTurret = {X = 0.74, Y = 0.58} end
    if Config.AutoTurretEnabled == nil then Config.AutoTurretEnabled = false end

    local autoTurretOn = Config.AutoTurretEnabled

    local function adt_getChar()
        local c = LocalPlayer.Character
        return c, c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
    end

    local function adt_hasExclamation(target)
        for _, d in ipairs(target:GetDescendants()) do
            if d:IsA("BillboardGui") then
                local lbl = d:FindFirstChildWhichIsA("TextLabel", true)
                if lbl and lbl.Text:find("!") then return true end
            end
        end
        return false
    end

    local function adt_applyVisuals(target)
        for _, d in ipairs(target:GetDescendants()) do
            if d:IsA("BasePart") and d ~= target then
                d.Transparency = 0.5; d.CanCollide = false
                d.CanTouch = false; d.CanQuery = false
            elseif d:IsA("BillboardGui") and d.Name == "SentryLabel" then
                d:Destroy()
            elseif d:IsA("Decal") or d:IsA("Texture") then d.Transparency = 0.5 end
        end
        if target:IsA("BasePart") and target.Name == "ProxyVisual" then target.Transparency = 1; target.CanCollide = false end
    end

    -- Weapon priority: use the Bat to destroy turrets if it's in the inventory; otherwise
    -- fall back to the Gummy Bear slap. Returns nil when the player has neither, in which
    -- case the turret-destroy loop does nothing.
    local function adt_getWeapon()
        local c = LocalPlayer.Character
        if not c then return nil end
        local bp = LocalPlayer.Backpack
        return (bp and bp:FindFirstChild("Bat")) or c:FindFirstChild("Bat")
            or (bp and bp:FindFirstChild("Gummy Bear")) or c:FindFirstChild("Gummy Bear")
    end

    local function adt_equipBat()
        local c, _, hum = adt_getChar()
        if not c or not hum then return end
        local w = adt_getWeapon()
        if w and w.Parent ~= c then hum:EquipTool(w) end
    end

    local function adt_getClosestSentry()
        local _, hrp = adt_getChar()
        if not hrp then return nil end
        local closest, shortest = nil, math.huge
        for _, inst in ipairs(workspace:GetDescendants()) do
            if inst.Name:match("Sentry") and adt_hasExclamation(inst) then
                local root = inst:IsA("BasePart") and inst
                          or inst:FindFirstChildWhichIsA("BasePart", true)
                if root then
                    local dist = (hrp.Position - root.Position).Magnitude
                    if dist < shortest then shortest = dist; closest = inst end
                end
            end
        end
        return closest
    end

    do local o = PlayerGui:FindFirstChild("JustAFanAutoTurret"); if o then o:Destroy() end end

    local adtGui = Instance.new("ScreenGui")
    adtGui.Name = "JustAFanAutoTurret"
    adtGui.ResetOnSpawn = false
    adtGui.DisplayOrder = 998
    adtGui.Parent = PlayerGui

    local adtFrame = Instance.new("Frame", adtGui)
    adtFrame.Size = UDim2.new(0, 220, 0, 80)
    adtFrame.Position = UDim2.new(
        Config.Positions.AutoTurret.X, 0,
        Config.Positions.AutoTurret.Y, 0)
    adtFrame.BackgroundColor3 = Theme.Background
    adtFrame.BackgroundTransparency = 0.12
    adtFrame.BorderSizePixel = 0
    Instance.new("UICorner", adtFrame).CornerRadius = UDim.new(0, 10)
    local adtStroke = Instance.new("UIStroke", adtFrame)
    adtStroke.Color = Theme.Accent2; adtStroke.Thickness = 1.4; adtStroke.Transparency = 0.35
    task.defer(function() if addRacetrackBorder then addRacetrackBorder(adtFrame, 3.5) end end)

    local adtHeader = Instance.new("Frame", adtFrame)
    adtHeader.Size = UDim2.new(1, 0, 0, 30)
    adtHeader.BackgroundTransparency = 1
    MakeDraggable(adtHeader, adtFrame, "AutoTurret")

    local adtTitle = Instance.new("TextLabel", adtHeader)
    adtTitle.Size = UDim2.new(1, -12, 1, 0)
    adtTitle.Position = UDim2.new(0, 12, 0, 0)
    adtTitle.BackgroundTransparency = 1
    adtTitle.Text = "AUTO TURRET DESTROY"
    adtTitle.Font = Enum.Font.GothamBlack
    adtTitle.TextSize = 11
    adtTitle.TextColor3 = Theme.TextSecondary
    adtTitle.TextXAlignment = Enum.TextXAlignment.Left

    local adtToggle = Instance.new("TextButton", adtFrame)
    adtToggle.Size = UDim2.new(1, -20, 0, 32)
    adtToggle.Position = UDim2.new(0, 10, 0, 34)
    adtToggle.Font = Enum.Font.GothamBold
    adtToggle.TextSize = 13
    adtToggle.BorderSizePixel = 0
    adtToggle.AutoButtonColor = false
    Instance.new("UICorner", adtToggle).CornerRadius = UDim.new(0, 8)
    local adtBtnStroke = Instance.new("UIStroke", adtToggle)
    adtBtnStroke.Thickness = 1.2

    local function adtRefreshBtn()
        if autoTurretOn then
            adtToggle.Text = "TURRET DESTROY  [ON]"
            adtToggle.BackgroundColor3 = Theme.Accent1
            adtToggle.TextColor3 = Color3.new(0, 0, 0)
            adtBtnStroke.Transparency = 1
            adt_equipBat()
        else
            adtToggle.Text = "TURRET DESTROY  [OFF]"
            adtToggle.BackgroundColor3 = Theme.Surface
            adtToggle.TextColor3 = Theme.TextPrimary
            adtBtnStroke.Color = Theme.Accent2
            adtBtnStroke.Transparency = 0.5
        end
    end
    adtRefreshBtn()

    adtToggle.MouseButton1Click:Connect(function()
        autoTurretOn = not autoTurretOn
        Config.AutoTurretEnabled = autoTurretOn
        SaveConfig()
        adtRefreshBtn()
        ShowNotification("TURRET DESTROY", autoTurretOn and "ON" or "OFF")
    end)

    task.spawn(function()
        while true do
            task.wait(0.1)
            if not autoTurretOn then continue end

            -- No Bat and no Gummy Bear -> we have nothing to destroy turrets with, so skip.
            if not adt_getWeapon() then continue end

            local c, hrp, hum = adt_getChar()
            if c and hum then
                local w = adt_getWeapon()
                if w and w.Parent ~= c then hum:EquipTool(w) end
            end

            if LocalPlayer:GetAttribute("Stealing") == true then task.wait(0.5); continue end

            local targetSentry = adt_getClosestSentry()
            if not targetSentry then continue end

            while targetSentry and targetSentry.Parent
              and LocalPlayer:GetAttribute("Stealing") ~= true do
                c, hrp, hum = adt_getChar()
                if not c or not hrp or not hum then break end

                local w = adt_getWeapon()
                adt_applyVisuals(targetSentry)

                local offset   = hrp.CFrame.LookVector * 4
                local targetCF = CFrame.new(hrp.Position + offset, hrp.Position)

                if targetSentry:IsA("Model") then
                    targetSentry:PivotTo(targetCF)
                elseif targetSentry:IsA("BasePart") then targetSentry.CFrame = targetCF end

                if w then
                    if w.Parent ~= c then hum:EquipTool(w) end
                    w:Activate()
                else
                    break
                end

                task.wait(0.1)
                if not adt_hasExclamation(targetSentry) then break end
            end
        end
    end)

end)()

;(function()
    if Config.Positions.GrabKick == nil then Config.Positions.GrabKick = {X = 0.74, Y = 0.78} end
    if Config.GrabKickEnabled == nil then Config.GrabKickEnabled = false end

    local GK_CARPET_TOOLS = { "Flying Carpet","Cupids Wings","Santas Sleigh","Witchs Broom" }

    local function gk_getChar()
        local c = LocalPlayer.Character
        return c, c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
    end

    local function gk_equipCarpet()
        local c, _, hum = gk_getChar()
        if not c or not hum then return false end
        for _, name in ipairs(GK_CARPET_TOOLS) do
            local t = LocalPlayer.Backpack:FindFirstChild(name) or c:FindFirstChild(name)
            if t then hum:EquipTool(t); return true end
        end
        return false
    end

    local function gk_findMyPlot()
        local plots = Workspace:FindFirstChild("Plots")
        if not plots then return nil end
        for _, plot in ipairs(plots:GetChildren()) do
            local sign = plot:FindFirstChild("PlotSign")
            if sign then
                local yb = sign:FindFirstChild("YourBase")
                if yb and yb:IsA("BillboardGui") and yb.Enabled then return plot end
                for _, d in ipairs(sign:GetDescendants()) do
                    if d:IsA("TextLabel") then
                        local t = d.Text:lower()
                        if t:find(LocalPlayer.Name:lower(),1,true) or
                           t:find(LocalPlayer.DisplayName:lower(),1,true) then
                            return plot
                        end
                    end
                end
            end
        end
        return nil
    end

    local GK_GRAB_KWS = { "grab","collect","pick","take","claim" }
    local function gk_isGrabKw(s)
        s = (s or ""):lower()
        for _, kw in ipairs(GK_GRAB_KWS) do if s:find(kw,1,true) then return true end end
        return false
    end

    local GK_SELL_KWS = { "sell","drop","trash" }
    local function gk_isSellKw(s)
        s = (s or ""):lower()
        for _, kw in ipairs(GK_SELL_KWS) do if s:find(kw,1,true) then return true end end
        return false
    end

    local gkKickEnabled = false
    local gkKickPending = false

    local function gkKickPlayer()
        pcall(function()
            if game.Shutdown then game:Shutdown()
            else LocalPlayer:Kick("GrabKick - got it!") end
        end)
    end

    local function gkIsRagdolled()
        local c = LocalPlayer.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if not hum then return false end
        local s = hum:GetState()
        return s == Enum.HumanoidStateType.Ragdoll
            or s == Enum.HumanoidStateType.FallingDown
            or s == Enum.HumanoidStateType.Physics
            or s == Enum.HumanoidStateType.GettingUp
    end

    local function gkConfirmAndKick()
        if not gkKickEnabled or gkKickPending then return end
        gkKickPending = true
        task.spawn(function()
            local fired = false
            local idxConn, stlConn

            local function finish()
                if fired then return end
                fired = true
                pcall(function() if idxConn then idxConn:Disconnect() end end)
                pcall(function() if stlConn then stlConn:Disconnect() end end)
                task.wait(0.1); gkKickPlayer(); gkKickPending = false
            end

            idxConn = LocalPlayer:GetAttributeChangedSignal("StealingIndex"):Connect(function()
                local val = LocalPlayer:GetAttribute("StealingIndex")
                if type(val)=="string" and val~="" then finish() end
            end)
            local idxNow = LocalPlayer:GetAttribute("StealingIndex")
            if type(idxNow)=="string" and idxNow~="" then finish(); return end

            stlConn = LocalPlayer:GetAttributeChangedSignal("Stealing"):Connect(function()
            if LocalPlayer:GetAttribute("Stealing") == true then
                local myPlot = gk_findMyPlot()
                local _, hrp = gk_getChar()
                local onOwnPlot = false
                if myPlot and hrp then
                    local base = myPlot:FindFirstChild("Base")
                    local spawn = base and base:FindFirstChild("Spawn")
                    if spawn then onOwnPlot = (hrp.Position - spawn.Position).Magnitude < 80 end
                end
                if onOwnPlot then return end
                task.delay(0.3, function() if not fired then finish() end end)
            end
        end)
        if LocalPlayer:GetAttribute("Stealing") == true then
            local myPlot = gk_findMyPlot()
            local _, hrp = gk_getChar()
            local onOwnPlot = false
            if myPlot and hrp then
                local base = myPlot:FindFirstChild("Base")
                local spawn = base and base:FindFirstChild("Spawn")
                if spawn then onOwnPlot = (hrp.Position - spawn.Position).Magnitude < 80 end
            end
            if not onOwnPlot then
                task.delay(0.3, function() if not fired then finish() end end)
            end
        end
            task.delay(5.0, function()
                if not fired then
                    pcall(function() if idxConn then idxConn:Disconnect() end end)
                    pcall(function() if stlConn then stlConn:Disconnect() end end)
                    gkKickPending = false
                end
            end)
        end)
    end

    local function gkTpAndGrab(slotData)
        if not slotData or not slotData.position then return end
        gk_equipCarpet()
        local _, hrp = gk_getChar()
        if not hrp then return end
        hrp.AssemblyLinearVelocity  = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        -- Go straight to the podium at its OWN Y level - no jump-up first.
        local gkDest = slotData.position
        -- Velocity fly toward slot (130 studs/s, P-controller on Y)
        local gkVelDone = false
        local gkVlConn
        gkVlConn = RunService.Heartbeat:Connect(function()
            local _, vHrp = gk_getChar()
            if not vHrp then gkVlConn:Disconnect(); gkVelDone = true; return end
            local flatDist = Vector2.new(vHrp.Position.X - gkDest.X, vHrp.Position.Z - gkDest.Z).Magnitude
            if flatDist <= 4 then gkVlConn:Disconnect(); gkVelDone = true; return end
            local dir = Vector3.new(gkDest.X - vHrp.Position.X, 0, gkDest.Z - vHrp.Position.Z)
            if dir.Magnitude > 0 then dir = dir.Unit end
            local yVel = math.clamp((gkDest.Y - vHrp.Position.Y) * 6, -140, 80)
            vHrp.AssemblyLinearVelocity = Vector3.new(dir.X * 130, yVel, dir.Z * 130)
        end)
        local gkVlT = tick()
        repeat RunService.Heartbeat:Wait() until gkVelDone or tick()-gkVlT > 5
        gkVlConn:Disconnect()
        -- Decelerate (same ramp-down as tween_tp)
        _, hrp = gk_getChar()
        if hrp then
            for _ri = 1, 6 do
                _, hrp = gk_getChar(); if not hrp then break end
                local f = 1 - (_ri / 6)
                local v = hrp.AssemblyLinearVelocity
                hrp.AssemblyLinearVelocity = Vector3.new(v.X * f, 0, v.Z * f)
                RunService.Heartbeat:Wait()
            end
            _, hrp = gk_getChar()
            if hrp then hrp.AssemblyLinearVelocity = Vector3.zero end
        end
        RunService.Heartbeat:Wait()
        local p = slotData.prompt
        if p and p.Parent and p.Enabled then
            pcall(function() if fireproximityprompt then fireproximityprompt(p) end end)
            gkConfirmAndKick(); return
        end
        local plot = gk_findMyPlot()
        if not plot then return end
        for _, d in ipairs(plot:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.Enabled and gk_isGrabKw(d.ActionText) then
                local bp = d.Parent and d.Parent:IsA("BasePart") and d.Parent
                if bp then
                    hrp.CFrame = CFrame.new(bp.Position + Vector3.new(0, 3.5, 0))
                    RunService.Heartbeat:Wait()
                    pcall(function() if fireproximityprompt then fireproximityprompt(d) end end)
                    gkConfirmAndKick(); return
                end
            end
        end
    end

    local GkGrabCache     = {}
    local GkCbCache       = {}
    local gkGrabActive    = false
    local gkGrabHB        = nil
    local gkGrabPlotConns = {}
    local GK_COOLDOWN     = 0
    local gkLastGrab      = 0

    local function gkBuildCb(prompt)
        if GkCbCache[prompt] then return end
        local data = {hold={},trigger={},ready=true}
        local ok1,c1 = pcall(getconnections, prompt.PromptButtonHoldBegan)
        if ok1 and type(c1)=="table" then
            for _,c in ipairs(c1) do if type(c.Function)=="function" then table.insert(data.hold,c.Function) end end
        end
        local ok2,c2 = pcall(getconnections, prompt.Triggered)
        if ok2 and type(c2)=="table" then
            for _,c in ipairs(c2) do if type(c.Function)=="function" then table.insert(data.trigger,c.Function) end end
        end
        if #data.hold>0 or #data.trigger>0 then GkCbCache[prompt] = data end
    end

    local function gkFireDirect(prompt)
        local ok,conns = pcall(getconnections, prompt.Triggered)
        if ok and type(conns)=="table" then
            for _,c in ipairs(conns) do if type(c.Function)=="function" then pcall(c.Function) end end
        end
        gkBuildCb(prompt)
        local d = GkCbCache[prompt]
        if d then for _,fn in ipairs(d.trigger) do pcall(fn) end end
    end

    local function gkExecGrab(prompt)
        if not prompt or not prompt.Parent then return end
        if not gk_isGrabKw(prompt.ActionText) then return end
        local now = os.clock()
        if now - gkLastGrab < GK_COOLDOWN then return end
        gkLastGrab = now
        task.spawn(function() gkFireDirect(prompt) end)
        if prompt.Enabled then
            pcall(function() if fireproximityprompt then fireproximityprompt(prompt) end end)
        end
        if gkStatusLbl then
            gkStatusDot.BackgroundColor3 = Color3.fromRGB(255,165,0)
            gkStatusLbl.Text = "Grab fired - waiting..."
            gkStatusLbl.TextColor3 = Color3.fromRGB(255,165,0)
        end
        gkConfirmAndKick()
    end

    local function gkFindPromptInPod(pod)
        if not pod then return nil end
        local base = pod:FindFirstChild("Base"); if not base then return nil end
        local spawn = base:FindFirstChild("Spawn")
        if spawn then
            local att = spawn:FindFirstChild("PromptAttachment")
            if att then
                for _, p in ipairs(att:GetChildren()) do
                    if p:IsA("ProximityPrompt") and p.Enabled and gk_isGrabKw(p.ActionText) then return p end
                end
            end
        end
        for _, d in ipairs(pod:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.Enabled and gk_isGrabKw(d.ActionText) then return d end
        end
        return nil
    end

    local function gkRebuildCache()
        GkGrabCache = {}
        local plot = gk_findMyPlot(); if not plot then return end
        local podiums = plot:FindFirstChild("AnimalPodiums"); if not podiums then return end
        for _, pod in ipairs(podiums:GetChildren()) do
            local p = gkFindPromptInPod(pod)
            if p then GkGrabCache[tostring(pod.Name)] = p end
        end
    end

    local function gkClearConns()
        for _, c in ipairs(gkGrabPlotConns) do pcall(function() c:Disconnect() end) end
        gkGrabPlotConns = {}
    end

    local function gkStopGrab()
        gkGrabActive = false
        if gkGrabHB then gkGrabHB:Disconnect(); gkGrabHB = nil end
        gkClearConns(); GkGrabCache = {}; GkCbCache = {}
    end

    local function gkStartGrab()
        gkGrabActive = true
        gkRebuildCache(); gkClearConns()
        local plot = gk_findMyPlot()
        if plot then
            local function onChange() task.wait(0.1); gkRebuildCache() end
            table.insert(gkGrabPlotConns, plot.DescendantAdded:Connect(onChange))
            table.insert(gkGrabPlotConns, plot.DescendantRemoving:Connect(onChange))
        end
        task.spawn(function()
            while gkGrabActive do
                task.wait(0.3)
                local myPlot = gk_findMyPlot()
                if myPlot then
                    local pods = myPlot:FindFirstChild("AnimalPodiums")
                    if pods then
                        for _, pod in ipairs(pods:GetChildren()) do
                            local sn = tostring(pod.Name)
                            if not GkGrabCache[sn] then
                                local p = gkFindPromptInPod(pod)
                                if p and p.Enabled then GkGrabCache[sn] = p end
                            end
                        end
                    end
                end
            end
        end)
        task.spawn(function()
            while gkGrabActive do
                for _, prompt in pairs(GkGrabCache) do
                    if prompt and prompt.Parent then gkBuildCb(prompt) end
                end
                task.wait(2)
            end
        end)
        if gkGrabHB then gkGrabHB:Disconnect() end
        gkGrabHB = RunService.Heartbeat:Connect(function()
            if not gkGrabActive then return end
            for sn, prompt in pairs(GkGrabCache) do
                if prompt and prompt.Parent and prompt.Enabled and gk_isGrabKw(prompt.ActionText) then
                    gkExecGrab(prompt)
                else
                    GkGrabCache[sn] = nil; GkCbCache[prompt] = nil
                end
            end
        end)
    end

    local gkCollectOn  = false
    local gkCollectConn = nil

    local function gkStopCollect()
        if gkCollectConn then gkCollectConn:Disconnect(); gkCollectConn = nil end
    end

    local function gkStartCollect()
        gkStopCollect()
        local preSnap = {}
        local function snap()
            local plot = gk_findMyPlot(); if not plot then return end
            local pods = plot:FindFirstChild("AnimalPodiums"); if not pods then return end
            for _, pod in ipairs(pods:GetChildren()) do
                local p = gkFindPromptInPod(pod)
                if p then preSnap[tostring(pod.Name)] = {prompt=p, position=(p.Parent and p.Parent:IsA("BasePart") and p.Parent.Position) or (p.Parent and p.Parent:IsA("Attachment") and p.Parent.Parent and p.Parent.Parent:IsA("BasePart") and p.Parent.Parent.Position) or Vector3.zero} end
            end
        end
        snap()
        gkCollectConn = LocalPlayer:GetAttributeChangedSignal("Stealing"):Connect(function()
            if LocalPlayer:GetAttribute("Stealing") == true then
                snap()
                -- Pre-move: start flying toward an empty slot NOW while the steal plays out
                task.spawn(function()
                    local plot = gk_findMyPlot(); if not plot then return end
                    local pods = plot:FindFirstChild("AnimalPodiums"); if not pods then return end
                    local dest
                    for _, pod in ipairs(pods:GetChildren()) do
                        if not preSnap[tostring(pod.Name)] then
                            local base = pod:FindFirstChild("Base")
                            local sp = base and base:FindFirstChild("Spawn")
                            if sp and sp:IsA("BasePart") then dest = sp.Position + Vector3.new(0, 3.5, 0); break end
                        end
                    end
                    if not dest then return end
                    gk_equipCarpet()
                    local _, hrp = gk_getChar(); if not hrp then return end
                    -- Jump up
                    local jt = tick()
                    while hrp and hrp.Position.Y < dest.Y + 8 and tick()-jt < 1.2 do
                        hrp.AssemblyLinearVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, 200, hrp.AssemblyLinearVelocity.Z)
                        RunService.Heartbeat:Wait(); _, hrp = gk_getChar()
                    end
                    if not hrp then return end
                    hrp.AssemblyLinearVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z)
                    -- Fly to slot
                    local flyDone = false; local flyConn
                    flyConn = RunService.Heartbeat:Connect(function()
                        local _, h = gk_getChar(); if not h then flyConn:Disconnect(); flyDone = true; return end
                        local fd = Vector2.new(h.Position.X - dest.X, h.Position.Z - dest.Z).Magnitude
                        if fd <= 4 then flyConn:Disconnect(); flyDone = true; return end
                        local dir = Vector3.new(dest.X - h.Position.X, 0, dest.Z - h.Position.Z)
                        if dir.Magnitude > 0 then dir = dir.Unit end
                        h.AssemblyLinearVelocity = Vector3.new(dir.X * 130, math.clamp((dest.Y - h.Position.Y) * 6, -140, 80), dir.Z * 130)
                    end)
                    local ft = tick(); repeat RunService.Heartbeat:Wait() until flyDone or tick()-ft > 5
                    flyConn:Disconnect()
                end)
            else
                task.delay(0.2, function()
                    local plot = gk_findMyPlot(); if not plot then return end
                    local pods = plot:FindFirstChild("AnimalPodiums"); if not pods then return end
                    for _, pod in ipairs(pods:GetChildren()) do
                        local sn = tostring(pod.Name)
                        if not preSnap[sn] then
                            local p = gkFindPromptInPod(pod)
                            if p then
                                gkTpAndGrab({prompt=p, position=(p.Parent and p.Parent:IsA("BasePart") and p.Parent.Position) or (p.Parent and p.Parent:IsA("Attachment") and p.Parent.Parent and p.Parent.Parent:IsA("BasePart") and p.Parent.Parent.Position) or Vector3.zero, slotName=sn})
                                return
                            end
                        end
                    end
                end)
            end
        end)
    end

    -- Always start OFF on (re)join - Grab Kick is intentionally not persisted across sessions.
    local gkMasterOn = false

    do local o = PlayerGui:FindFirstChild("JustAFanGrabKick"); if o then o:Destroy() end end

    local gkGui = Instance.new("ScreenGui")
    gkGui.Name = "JustAFanGrabKick"
    gkGui.ResetOnSpawn = false
    gkGui.DisplayOrder = 997
    gkGui.Parent = PlayerGui

    local gkFrame = Instance.new("Frame", gkGui)
    gkFrame.Size = UDim2.new(0, 220, 0, 120)
    gkFrame.Position = UDim2.new(
        Config.Positions.GrabKick.X, 0,
        Config.Positions.GrabKick.Y, 0)
    gkFrame.BackgroundColor3 = Theme.Background
    gkFrame.BackgroundTransparency = 0.12
    gkFrame.BorderSizePixel = 0
    Instance.new("UICorner", gkFrame).CornerRadius = UDim.new(0, 10)
    local gkStroke = Instance.new("UIStroke", gkFrame)
    gkStroke.Color = Theme.Accent2; gkStroke.Thickness = 1.4; gkStroke.Transparency = 0.35
    task.defer(function() if addRacetrackBorder then addRacetrackBorder(gkFrame, 3.5) end end)

    local gkHeader = Instance.new("Frame", gkFrame)
    gkHeader.Size = UDim2.new(1, 0, 0, 28)
    gkHeader.BackgroundTransparency = 1
    MakeDraggable(gkHeader, gkFrame, "GrabKick")

    local gkTitle = Instance.new("TextLabel", gkHeader)
    gkTitle.Size = UDim2.new(1,-12,1,0); gkTitle.Position = UDim2.new(0,12,0,0)
    gkTitle.BackgroundTransparency = 1; gkTitle.Text = "GRAB KICK"
    gkTitle.Font = Enum.Font.GothamBlack; gkTitle.TextSize = 11
    gkTitle.TextColor3 = Theme.TextSecondary
    gkTitle.TextXAlignment = Enum.TextXAlignment.Left

    local gkStatusRow = Instance.new("Frame", gkFrame)
    gkStatusRow.Size = UDim2.new(1,-20,0,20); gkStatusRow.Position = UDim2.new(0,10,0,30)
    gkStatusRow.BackgroundColor3 = Theme.Surface; gkStatusRow.BorderSizePixel = 0
    Instance.new("UICorner", gkStatusRow).CornerRadius = UDim.new(0,5)
    local gkStatusDot = Instance.new("Frame", gkStatusRow)
    gkStatusDot.Size = UDim2.new(0,7,0,7); gkStatusDot.Position = UDim2.new(0,7,0.5,-3.5)
    gkStatusDot.BackgroundColor3 = Theme.TextSecondary; gkStatusDot.BorderSizePixel = 0
    Instance.new("UICorner", gkStatusDot).CornerRadius = UDim.new(1,0)
    local gkStatusLbl = Instance.new("TextLabel", gkStatusRow)
    gkStatusLbl.Size = UDim2.new(1,-24,1,0); gkStatusLbl.Position = UDim2.new(0,20,0,0)
    gkStatusLbl.BackgroundTransparency = 1; gkStatusLbl.Text = "Idle"
    gkStatusLbl.Font = Enum.Font.Gotham; gkStatusLbl.TextSize = 10
    gkStatusLbl.TextColor3 = Theme.TextSecondary
    gkStatusLbl.TextXAlignment = Enum.TextXAlignment.Left

    local gkCacheRow = Instance.new("Frame", gkFrame)
    gkCacheRow.Size = UDim2.new(1,-20,0,20); gkCacheRow.Position = UDim2.new(0,10,0,54)
    gkCacheRow.BackgroundColor3 = Theme.Surface; gkCacheRow.BorderSizePixel = 0
    Instance.new("UICorner", gkCacheRow).CornerRadius = UDim.new(0,5)
    local gkCacheLbl = Instance.new("TextLabel", gkCacheRow)
    gkCacheLbl.Size = UDim2.new(1,-10,1,0); gkCacheLbl.Position = UDim2.new(0,8,0,0)
    gkCacheLbl.BackgroundTransparency = 1; gkCacheLbl.Text = "Cache: OFF"
    gkCacheLbl.Font = Enum.Font.Gotham; gkCacheLbl.TextSize = 10
    gkCacheLbl.TextColor3 = Theme.TextSecondary
    gkCacheLbl.TextXAlignment = Enum.TextXAlignment.Left

    local gkToggle = Instance.new("TextButton", gkFrame)
    gkToggle.Size = UDim2.new(1,-20,0,30); gkToggle.Position = UDim2.new(0,10,0,78)
    gkToggle.Font = Enum.Font.GothamBold; gkToggle.TextSize = 12
    gkToggle.BorderSizePixel = 0; gkToggle.AutoButtonColor = false
    Instance.new("UICorner", gkToggle).CornerRadius = UDim.new(0,8)
    local gkBtnStroke = Instance.new("UIStroke", gkToggle)
    gkBtnStroke.Thickness = 1.2

    local function gkRefreshBtn()
        if gkMasterOn then
            gkToggle.Text = "GRAB KICK  [ON]"
            gkToggle.BackgroundColor3 = Theme.Accent1
            gkToggle.TextColor3 = Color3.new(0,0,0)
            gkBtnStroke.Transparency = 1
            gkStatusDot.BackgroundColor3 = Theme.Accent1
        else
            gkToggle.Text = "GRAB KICK  [OFF]"
            gkToggle.BackgroundColor3 = Theme.Surface
            gkToggle.TextColor3 = Theme.TextPrimary
            gkBtnStroke.Color = Theme.Accent2; gkBtnStroke.Transparency = 0.5
            gkStatusDot.BackgroundColor3 = Theme.TextSecondary
        end
    end
    gkRefreshBtn()

    gkToggle.MouseButton1Click:Connect(function()
        gkMasterOn = not gkMasterOn
        Config.GrabKickEnabled = gkMasterOn
        SaveConfig()
        if gkMasterOn then
            gkStartGrab()
            gkCollectOn = true; gkStartCollect()
            gkKickEnabled = true; gkKickPending = false
            gkStatusLbl.Text = "Running - all features ON"
            gkStatusLbl.TextColor3 = Theme.Accent1
        else
            gkStopGrab()
            gkCollectOn = false; gkStopCollect()
            gkKickEnabled = false; gkKickPending = false
            gkStatusLbl.Text = "Idle"
            gkStatusLbl.TextColor3 = Theme.TextSecondary
        end
        gkRefreshBtn()
        ShowNotification("GRAB KICK", gkMasterOn and "ON" or "OFF")
    end)

    LocalPlayer:GetAttributeChangedSignal("StealingIndex"):Connect(function()
        local val = LocalPlayer:GetAttribute("StealingIndex")
        if type(val)=="string" and val~="" and gkMasterOn and not gkIsRagdolled() then
            gkStatusDot.BackgroundColor3 = Color3.fromRGB(255,215,0)
            gkStatusLbl.Text = "Got: "..val
            gkStatusLbl.TextColor3 = Color3.fromRGB(255,215,0)
        end
    end)


    task.spawn(function()
        while true do
            task.wait(0.5)
            if gkGrabActive then
                local n = 0
                for _ in pairs(GkGrabCache) do n = n + 1 end
                gkCacheLbl.Text = n.." slots cached | HB active"
                gkCacheLbl.TextColor3 = n > 0 and Theme.Accent1 or Color3.fromRGB(255,160,60)
            else
                gkCacheLbl.Text = "Cache: OFF"
                gkCacheLbl.TextColor3 = Theme.TextSecondary
            end
        end
    end)

    task.spawn(function()
        while true do
            task.wait(2)
            local c = LocalPlayer.Character
            local found = false
            for _, name in ipairs(GK_CARPET_TOOLS) do
                if LocalPlayer.Backpack:FindFirstChild(name) or (c and c:FindFirstChild(name)) then found = true; break end
            end
            if gkMasterOn and not found then ShowNotification("GRAB KICK", "No carpet - TP won't work!") end
        end
    end)

    if gkMasterOn then
        task.delay(1, function()
            gkStartGrab()
            gkCollectOn = true; gkStartCollect()
            gkKickEnabled = true
            gkStatusLbl.Text = "Running - all features ON"
            gkStatusLbl.TextColor3 = Theme.Accent1
            gkRefreshBtn()
        end)
    end

end)()

-- ============================================================
-- NOCLIP vs other players + their clones (NOT walls/world)
-- ============================================================
-- Sets CanCollide=false on every other player's character parts and on every
-- model in Workspace whose name matches the clone pattern "<UserId>_Clone".
-- Our own character keeps CanCollide=true so we still collide with walls,
-- floors, base structure - only OTHER players and clones are passed through.
--
-- Implemented as a periodic Heartbeat-throttled re-apply (every ~0.2s) so
-- the server can't re-enable collision on us silently between writes. Cheap
-- enough at 5Hz to be invisible.
task.spawn(function()
    local function isClone(inst)
        if not inst:IsA("Model") then return false end
        local n = inst.Name
        return type(n) == "string" and string.find(n, "_Clone", 1, true) ~= nil
    end

    local function disableCollide(root)
        if not root or not root.Parent then return end
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("BasePart") and d.CanCollide then
                pcall(function() d.CanCollide = false end)
            end
        end
    end

    while true do
        -- Other players' characters
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and p.Character then
                disableCollide(p.Character)
            end
        end
        -- Clones (any "<UserId>_Clone" model in Workspace)
        for _, child in ipairs(Workspace:GetChildren()) do
            if isClone(child) then
                disableCollide(child)
            end
        end
        task.wait(0.2)
    end
end)

print("SammyDawg hub by JustAFan loaded")

