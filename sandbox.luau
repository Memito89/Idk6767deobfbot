-- ═══════════════════════════════════════════════════════════════════
-- NIGHTFALL LUAU SANDBOX  —  Full Roblox Mock Environment
-- Runs as a lune subprocess. All API calls are logged to stdout
-- as tab-delimited lines prefixed with [NF].
-- The target script is appended after this file at runtime.
-- ═══════════════════════════════════════════════════════════════════

local _LOG_LINES = {}
local function _log(event, ...)
    local parts = { event }
    for _, v in { ... } do
        local s = tostring(v):gsub("\n", "\\n"):gsub("\t", " "):sub(1, 160)
        table.insert(parts, s)
    end
    local line = "[NF]\t" .. table.concat(parts, "\t")
    table.insert(_LOG_LINES, line)
    io.write(line .. "\n")
    io.flush()
end

-- ── Output capture ────────────────────────────────────────────────
local _origPrint = print
print = function(...)
    local parts = {}
    for _, v in { ... } do table.insert(parts, tostring(v)) end
    _log("print", table.concat(parts, "  "))
end
warn = function(...)
    local parts = {}
    for _, v in { ... } do table.insert(parts, tostring(v)) end
    _log("warn", table.concat(parts, "  "))
end
-- Keep error raising so scripts don't silently fail

-- ── Stub constructor ──────────────────────────────────────────────
local function stub(className, name)
    local inst = { ClassName = className, Name = name or className, _children = {} }
    inst.FindFirstChild        = function(_, n) return inst._children[n] end
    inst.FindFirstChildOfClass = function(_, c) return nil end
    inst.WaitForChild          = function(_, n, _t)
        _log("WaitForChild", className, n)
        return inst._children[n] or stub(n, n)
    end
    inst.GetChildren      = function(_) return {} end
    inst.GetDescendants   = function(_) return {} end
    inst.IsA              = function(_, c) return c == className end
    inst.Destroy          = function(_) _log("Destroy", className, name or "?") end
    inst.Clone            = function(_) return stub(className, name) end
    inst.GetPropertyChangedSignal = function(_, p)
        return { Connect = function() end, Wait = function() end }
    end
    setmetatable(inst, {
        __newindex = function(t, k, v)
            rawset(t, k, v)
        end,
    })
    return inst
end

local function signal()
    return {
        Connect    = function(_, fn) return { Disconnect = function() end } end,
        Once       = function(_, fn) end,
        Wait       = function(_) return nil end,
        Disconnect = function(_) end,
    }
end

-- ── Remotes ───────────────────────────────────────────────────────
local function makeRemote(kind, name)
    local r = stub(kind, name)
    r.FireServer = function(_, ...)
        local a = {}; for _, v in { ... } do table.insert(a, tostring(v):sub(1,80)) end
        _log("REMOTE_FireServer", name or "?", table.concat(a, ", "))
    end
    r.FireAllClients = function(_, ...)
        local a = {}; for _, v in { ... } do table.insert(a, tostring(v):sub(1,80)) end
        _log("REMOTE_FireAllClients", name or "?", table.concat(a, ", "))
    end
    r.FireClient = function(_, player, ...)
        _log("REMOTE_FireClient", name or "?", tostring(player))
    end
    r.InvokeServer = function(_, ...)
        _log("REMOTE_InvokeServer", name or "?")
        return nil
    end
    r.InvokeClient = function(_, player, ...)
        _log("REMOTE_InvokeClient", name or "?")
        return nil
    end
    r.OnServerEvent  = signal()
    r.OnClientEvent  = signal()
    r.OnServerInvoke = nil  -- property assign
    r.OnClientInvoke = nil
    return r
end

-- ── HttpService ───────────────────────────────────────────────────
local HttpService = stub("HttpService")
HttpService.GetAsync = function(_, url, cache, headers)
    _log("HTTP_GET", tostring(url))
    return '{"sandbox":true}'
end
HttpService.PostAsync = function(_, url, body, ct, compress, headers)
    _log("HTTP_POST", tostring(url), tostring(body or ""):sub(1, 120))
    return '{"sandbox":true}'
end
HttpService.RequestAsync = function(_, opts)
    _log("HTTP_REQUEST", tostring(opts.Url), tostring(opts.Method or "GET"))
    return { Success = true, StatusCode = 200, Body = '{"sandbox":true}', Headers = {} }
end
HttpService.JSONEncode = function(_, t)
    -- minimal encode
    if type(t) == "table" then return "{}" end
    return tostring(t)
end
HttpService.JSONDecode = function(_, s)
    _log("JSON_Decode", tostring(s):sub(1, 60))
    return {}
end
HttpService.GenerateGUID = function(_, wrapBraces)
    return "{00000000-0000-0000-0000-000000000000}"
end
HttpService.UrlEncode = function(_, s) return s end

-- ── DataStoreService ──────────────────────────────────────────────
local _ds = {}
local DataStoreService = stub("DataStoreService")
local function makeStore(name, scope)
    scope = scope or "global"
    local key = name .. "/" .. scope
    if not _ds[key] then
        local store = { _data = {} }
        store.GetAsync = function(_, k)
            _log("DS_GetAsync", name, tostring(k))
            return store._data[k]
        end
        store.SetAsync = function(_, k, v, ids, opts)
            _log("DS_SetAsync", name, tostring(k), tostring(v):sub(1, 80))
            store._data[k] = v
            return true
        end
        store.UpdateAsync = function(_, k, fn)
            _log("DS_UpdateAsync", name, tostring(k))
            local new = fn(store._data[k])
            store._data[k] = new
            return new
        end
        store.RemoveAsync = function(_, k)
            _log("DS_RemoveAsync", name, tostring(k))
            store._data[k] = nil
        end
        store.GetSortedAsync = function(_, ascending, pageSize, minVal, maxVal)
            _log("DS_GetSortedAsync", name)
            return { GetCurrentPage = function() return {} end, IsFinished = true }
        end
        store.IncrementAsync = function(_, k, delta)
            _log("DS_IncrementAsync", name, tostring(k), tostring(delta))
            store._data[k] = (store._data[k] or 0) + (delta or 1)
            return store._data[k]
        end
        _ds[key] = store
    end
    return _ds[key]
end
DataStoreService.GetDataStore        = function(_, n, s) _log("DS_GetDataStore", n, s or "global"); return makeStore(n, s) end
DataStoreService.GetOrderedDataStore = function(_, n, s) _log("DS_GetOrderedDataStore", n); return makeStore(n, s) end
DataStoreService.GetGlobalDataStore  = function(_) return makeStore("__global") end

-- ── MessagingService ──────────────────────────────────────────────
local MessagingService = stub("MessagingService")
MessagingService.PublishAsync  = function(_, topic, msg) _log("MSG_Publish", topic, tostring(msg):sub(1,100)) end
MessagingService.SubscribeAsync = function(_, topic, fn) _log("MSG_Subscribe", topic); return {Disconnect=function()end} end

-- ── TeleportService ───────────────────────────────────────────────
local TeleportService = stub("TeleportService")
TeleportService.Teleport               = function(_, pid, p) _log("TELEPORT", tostring(pid)) end
TeleportService.TeleportAsync          = function(_, pid, ps) _log("TELEPORT_Async", tostring(pid)) end
TeleportService.TeleportToPrivateServer = function(_, pid, code) _log("TELEPORT_Private", tostring(pid), tostring(code)) end
TeleportService.TeleportToSpawnByName  = function(_, pid, spawnName) _log("TELEPORT_Spawn", tostring(pid), spawnName) end
TeleportService.GetLocalPlayerTeleportData = function(_) return nil end

-- ── MarketplaceService ────────────────────────────────────────────
local MarketplaceService = stub("MarketplaceService")
MarketplaceService.PromptProductPurchase  = function(_, p, id) _log("MKT_PromptProduct", tostring(id)) end
MarketplaceService.PromptGamePassPurchase = function(_, p, id) _log("MKT_PromptGamePass", tostring(id)) end
MarketplaceService.UserOwnsGamePassAsync  = function(_, uid, id) _log("MKT_OwnsGamePass", tostring(uid), tostring(id)); return false end
MarketplaceService.GetProductInfo         = function(_, id, t) _log("MKT_GetProductInfo", tostring(id)); return {Name="SandboxItem",Description="",PriceInRobux=0} end
MarketplaceService.PromptPurchase         = function(_, p, id) _log("MKT_PromptPurchase", tostring(id)) end

-- ── Players ───────────────────────────────────────────────────────
local function makePlayer(name, userId)
    local char = stub("Model", name)
    char.Humanoid = { Health = 100, MaxHealth = 100, WalkSpeed = 16, JumpPower = 50, IsDead = function() return false end }
    char.HumanoidRootPart = stub("Part", "HumanoidRootPart")
    char.HumanoidRootPart.Position = { X = 0, Y = 0, Z = 0 }

    local p = stub("Player", name)
    p.Name           = name
    p.UserId         = userId
    p.DisplayName    = name
    p.AccountAge     = 100
    p.MembershipType = "None"
    p.Character      = char
    p.Backpack        = stub("Backpack")
    p.PlayerGui       = stub("PlayerGui")
    p.leaderstats     = stub("Folder", "leaderstats")

    p.Kick = function(_, reason)
        _log("PLAYER_Kick", name, tostring(reason or "no reason"))
    end
    p.GetRankInGroup  = function(_, gid) _log("GetRankInGroup", name, tostring(gid)); return 0 end
    p.IsInGroup       = function(_, gid) _log("IsInGroup", name, tostring(gid)); return false end
    p.GetFriendsAsync = function(_) return { GetCurrentPage = function() return {} end, IsFinished = true } end
    p.LoadCharacter   = function(_) _log("LoadCharacter", name) end
    p.CharacterAdded  = signal()
    p.CharacterRemoving = signal()

    return p
end
local _lp = makePlayer("SandboxPlayer", 1)

local Players = stub("Players")
Players.LocalPlayer = _lp
Players.MaxPlayers  = 50
Players.GetPlayers  = function(_) _log("Players_GetPlayers"); return { _lp } end
Players.GetPlayerByUserId = function(_, uid) _log("GetPlayerByUserId", tostring(uid)); return _lp end
Players.GetPlayerFromCharacter = function(_, char) return _lp end
Players.PlayerAdded    = signal()
Players.PlayerRemoving = signal()

-- ── Chat ──────────────────────────────────────────────────────────
local Chat = stub("Chat")
Chat.Chat                = function(_, part, msg, color) _log("CHAT_Send", tostring(msg):sub(1, 200)) end
Chat.FilterStringAsync   = function(_, s) return s end
Chat.FilterStringForBroadcast = function(_, s) return s end

-- ── RunService ────────────────────────────────────────────────────
local RunService = stub("RunService")
RunService.IsServer   = function() return true end
RunService.IsClient   = function() return false end
RunService.IsStudio   = function() return false end
RunService.IsRunning  = function() return true end
RunService.Heartbeat  = signal()
RunService.Stepped    = signal()
RunService.RenderStepped = signal()

-- ── ReplicatedStorage / ServerStorage ────────────────────────────
local ReplicatedStorage = stub("ReplicatedStorage")
ReplicatedStorage.WaitForChild = function(_, name, t)
    _log("ReplicatedStorage_WaitForChild", name)
    return makeRemote("RemoteEvent", name)
end
ReplicatedStorage.FindFirstChild = function(_, name)
    _log("ReplicatedStorage_FindFirstChild", name)
    return nil
end

local ServerStorage = stub("ServerStorage")
ServerStorage.WaitForChild = function(_, name, t)
    _log("ServerStorage_WaitForChild", name)
    return nil
end

-- ── Workspace ────────────────────────────────────────────────────
local workspace = stub("Workspace", "Workspace")
workspace.CurrentCamera = stub("Camera", "Camera")
workspace.Gravity       = 196.2
workspace.WaitForChild = function(_, name, t)
    _log("Workspace_WaitForChild", name)
    return stub("Model", name)
end

-- ── Lighting / other services ─────────────────────────────────────
local Lighting    = stub("Lighting");    Lighting.Brightness = 2; Lighting.ClockTime = 14
local SoundService = stub("SoundService")
local StarterGui  = stub("StarterGui");  StarterGui.ResetPlayerGuiOnSpawn = true

-- ── TextChatService ───────────────────────────────────────────────
local TextChatService = stub("TextChatService")
TextChatService.SendAsync = function(_, msg)
    _log("TextChatService_Send", tostring(msg):sub(1,200))
end

-- ── Service map ───────────────────────────────────────────────────
local _services = {
    HttpService       = HttpService,
    DataStoreService  = DataStoreService,
    MessagingService  = MessagingService,
    TeleportService   = TeleportService,
    MarketplaceService = MarketplaceService,
    Players           = Players,
    Chat              = Chat,
    RunService        = RunService,
    ReplicatedStorage = ReplicatedStorage,
    ServerStorage     = ServerStorage,
    Workspace         = workspace,
    Lighting          = Lighting,
    SoundService      = SoundService,
    StarterGui        = StarterGui,
    TextChatService   = TextChatService,
    Teams             = stub("Teams"),
    BadgeService      = stub("BadgeService"),
    GroupService      = stub("GroupService"),
    PolicyService     = stub("PolicyService"),
    CoreGui           = stub("CoreGui"),
    UserInputService  = stub("UserInputService"),
    ContextActionService = stub("ContextActionService"),
    TweenService      = { Create = function(_, inst, info, props) return { Play=function()end, Pause=function()end, Cancel=function()end, Completed=signal() } end },
    PathfindingService = stub("PathfindingService"),
    PhysicsService    = stub("PhysicsService"),
    CollectionService = {
        AddTag    = function(_, inst, tag) _log("CollectionService_AddTag", tag) end,
        RemoveTag = function(_, inst, tag) end,
        HasTag    = function(_, inst, tag) return false end,
        GetTagged = function(_, tag) return {} end,
        GetTags   = function(_, inst) return {} end,
    },
    ScriptContext     = stub("ScriptContext"),
    Selection         = stub("Selection"),
    VirtualUser       = { ClickButton2D = function(_, pos) _log("VirtualUser_Click") end },
    GuiService        = stub("GuiService"),
}

-- ── game object ──────────────────────────────────────────────────
local game = {
    Name      = "SandboxGame",
    PlaceId   = 1234567890,
    GameId    = 9876543210,
    JobId     = "sandbox-00000000-0000-0000-0000-000000000000",
    PlaceVersion = 1,
    Workspace = workspace,
    Players   = Players,
}
game.GetService = function(_, name)
    _log("GetService", name)
    if _services[name] then return _services[name] end
    local s = stub(name)
    _services[name] = s
    return s
end
game.HttpGet = function(_, url, sync)
    _log("HTTP_GET_game", url)
    return '{"sandbox":true}'
end
game.HttpGetAsync = function(_, url, headers)
    _log("HTTP_GET_Async", url)
    return '{"sandbox":true}'
end
game.GetObjects = function(_, url)
    _log("GetObjects_url", url)
    return {}
end
game.IsLoaded = function(_) return true end
game.Loaded   = signal()
setmetatable(game, {
    __index = function(_, k)
        if _services[k] then return _services[k] end
        return nil
    end
})

-- expose game.service shorthand
for k, v in _services do
    if rawget(game, k) == nil then rawset(game, k, v) end
end

-- ── Instance.new ─────────────────────────────────────────────────
Instance = {
    new = function(className, parent)
        _log("Instance_new", className)
        if className == "RemoteEvent" or className == "RemoteFunction" then
            return makeRemote(className, "dynamic_" .. className)
        end
        if className == "Script" or className == "LocalScript" or className == "ModuleScript" then
            _log("SCRIPT_INJECT", className)
        end
        if className == "BindableEvent" then
            local b = stub("BindableEvent")
            b.Fire = function(_, ...) _log("BindableEvent_Fire") end
            b.Event = signal()
            return b
        end
        return stub(className)
    end,
    fromExisting = function(inst) return inst end,
}

-- ── require mock ─────────────────────────────────────────────────
require = function(id)
    _log("require", tostring(id))
    return setmetatable({}, {
        __index = function(_, k) return function(...) end end,
        __call  = function(_, ...) end,
    })
end

-- ── loadstring: actually execute via load() so deobfuscated chains work ──
local _load = load
loadstring = function(src, chunkName)
    _log("loadstring", tostring(chunkName or "chunk"), tostring(#src) .. " chars")
    local fn, err = _load(src, chunkName or "@loadstring", "t")
    if err then
        _log("loadstring_compile_error", err)
        return nil, err
    end
    return fn
end

-- ── Executor / exploit API mocks ─────────────────────────────────
getgenv = function() return _G end
getsenv = function(s) return {} end
getrenv = function() return {} end
getrawmetatable = getmetatable
setrawmetatable = setmetatable
hookfunction = function(fn, hook)
    _log("EXEC_hookfunction")
    return fn
end
newcclosure = function(fn)
    _log("EXEC_newcclosure")
    return fn
end
getupvalues = function(fn)
    _log("EXEC_getupvalues")
    return {}
end
setupvalue = function(fn, i, v)
    _log("EXEC_setupvalue", tostring(i))
end
getupvalue = function(fn, i)
    _log("EXEC_getupvalue", tostring(i))
    return nil
end
checkcaller      = function() return false end
isexecutorclosure = function() return false end
iscclosure       = function() return false end
islclosure       = function(fn) return type(fn) == "function" end
clonefunction    = function(fn) return fn end
decompile        = function(fn) _log("EXEC_decompile"); return "-- decompile not available in sandbox" end
getconnections   = function(sig) _log("EXEC_getconnections"); return {} end
firesignal       = function(sig, ...) _log("EXEC_firesignal") end
fireclickdetector = function(d, dist) _log("EXEC_fireclickdetector") end
fireproximityprompt = function(p) _log("EXEC_fireproximityprompt") end
gethiddenproperty = function(inst, prop)
    _log("EXEC_gethiddenproperty", tostring(prop))
    return nil
end
sethiddenproperty = function(inst, prop, val)
    _log("EXEC_sethiddenproperty", tostring(prop), tostring(val):sub(1,60))
end
getspecialinfo = function(inst) return {} end
getcallbackvalue = function(inst, prop) return nil end

-- ── Clipboard ────────────────────────────────────────────────────
setclipboard = function(text)
    _log("CLIPBOARD_set", tostring(text):sub(1, 200))
end
toclipboard = setclipboard
getclipboard = function()
    _log("CLIPBOARD_get")
    return ""
end

-- ── File system ──────────────────────────────────────────────────
writefile = function(path, data)
    _log("FS_writefile", tostring(path), tostring(#(data or "")) .. " bytes")
end
readfile = function(path)
    _log("FS_readfile", tostring(path))
    return ""
end
listfiles = function(path)
    _log("FS_listfiles", tostring(path))
    return {}
end
appendfile = function(path, data)
    _log("FS_appendfile", tostring(path))
end
isfile    = function(path) _log("FS_isfile", tostring(path)); return false end
isfolder  = function(path) _log("FS_isfolder", tostring(path)); return false end
makefolder = function(path) _log("FS_makefolder", tostring(path)) end
delfolder  = function(path) _log("FS_delfolder", tostring(path)) end
delfile    = function(path) _log("FS_delfile", tostring(path)) end

-- ── Network (executor-style) ──────────────────────────────────────
local function _netRequest(opts)
    local url = type(opts) == "string" and opts or tostring(opts.Url or opts.url or "?")
    local method = (type(opts) == "table" and (opts.Method or opts.method)) or "GET"
    _log("NET_request", method, url)
    return { Success = true, StatusCode = 200, StatusMessage = "OK",
             Body = '{"sandbox":true}', Headers = {} }
end
request  = _netRequest
http     = { request = _netRequest }
syn      = {
    request            = _netRequest,
    protect_gui        = function(g) _log("SYN_protect_gui") end,
    queue_on_teleport  = function(code) _log("SYN_queue_teleport", tostring(#code) .. " chars") end,
    get_bytecode       = function(fn) _log("SYN_get_bytecode"); return "" end,
    create_secure_function = function(fn) return fn end,
}
fluxus   = { request = _netRequest, queue_on_teleport = syn.queue_on_teleport }
KRNL_LOADED = true
SENTINEL_V2 = true
pebc_enabled = true

-- ── task ─────────────────────────────────────────────────────────
task = {
    wait  = function(t) return t or 0 end,
    spawn = function(fn, ...)
        if type(fn) ~= "function" then return end
        local ok, err = pcall(fn, ...)
        if not ok then _log("task_spawn_error", tostring(err)) end
    end,
    defer = function(fn, ...)
        if type(fn) ~= "function" then return end
        local ok, err = pcall(fn, ...)
        if not ok then _log("task_defer_error", tostring(err)) end
    end,
    delay = function(t, fn, ...)
        _log("task_delay_scheduled", tostring(t or 0) .. "s")
        -- don't actually wait; just note it
    end,
    cancel = function() end,
    synchronize = function() end,
    desynchronize = function() end,
}
wait  = task.wait
spawn = task.spawn
delay = task.delay

-- ── Roblox type stubs ─────────────────────────────────────────────
Vector3 = {
    new     = function(x,y,z) return {X=x or 0,Y=y or 0,Z=z or 0,Magnitude=math.sqrt((x or 0)^2+(y or 0)^2+(z or 0)^2)} end,
    zero    = {X=0,Y=0,Z=0,Magnitude=0},
    one     = {X=1,Y=1,Z=1,Magnitude=math.sqrt(3)},
    yAxis   = {X=0,Y=1,Z=0},
    xAxis   = {X=1,Y=0,Z=0},
    zAxis   = {X=0,Y=0,Z=1},
    fromNormalId = function(_, id) return Vector3.new() end,
}
Vector2 = { new = function(x,y) return {X=x or 0,Y=y or 0} end, zero={X=0,Y=0} }
CFrame  = {
    new     = function(x,y,z,...) return {Position=Vector3.new(x,y,z), p=Vector3.new(x,y,z)} end,
    Angles  = function(r,p,y) return CFrame.new() end,
    fromEulerAnglesXYZ = function(...) return CFrame.new() end,
    fromMatrix = function(...) return CFrame.new() end,
    identity = {Position=Vector3.new()},
}
Color3   = {
    new      = function(r,g,b) return {R=r or 0,G=g or 0,B=b or 0} end,
    fromRGB  = function(r,g,b) return Color3.new((r or 0)/255,(g or 0)/255,(b or 0)/255) end,
    fromHSV  = function(h,s,v) return Color3.new() end,
}
UDim2    = { new = function(xs,xo,ys,yo) return {X={Scale=xs,Offset=xo},Y={Scale=ys,Offset=yo}} end }
UDim     = { new = function(s,o) return {Scale=s,Offset=o} end }
TweenInfo = { new = function(...) return {} end }
NumberRange = { new = function(min,max) return {Min=min,Max=max} end }
NumberSequence = { new = function(v,...) return {} end }
ColorSequence  = { new = function(v,...) return {} end }
Ray       = { new = function(o,d) return {Origin=o,Direction=d} end }
Region3   = { new = function(a,b) return {} end }
BrickColor = {
    new     = function(s) return {Name=tostring(s),Color=Color3.new()} end,
    palette = function(i) return BrickColor.new("Medium stone grey") end,
    White   = function() return BrickColor.new("White") end,
    Black   = function() return BrickColor.new("Black") end,
    Red     = function() return BrickColor.new("Bright red") end,
}
Axes       = { new = function(...) return {} end }
Faces      = { new = function(...) return {} end }
PhysicalProperties = { new = function(...) return {} end }
Font       = { new = function(...) return {} end }
Enum = setmetatable({}, {
    __index = function(_, enumType)
        return setmetatable({}, {
            __index = function(_, item) return item end,
            __call  = function(_, v) return v end,
        })
    end,
})

-- ── pcall: log errors without crashing sandbox ────────────────────
local _pcall = pcall
pcall = function(fn, ...)
    local results = table.pack(_pcall(fn, ...))
    if not results[1] then
        _log("pcall_error", tostring(results[2]))
    end
    return table.unpack(results, 1, results.n)
end
xpcall = function(fn, handler, ...)
    local results = table.pack(_pcall(fn, ...))
    if not results[1] then
        _log("xpcall_error", tostring(results[2]))
        _pcall(handler, results[2])
    end
    return table.unpack(results, 1, results.n)
end

-- string extras Roblox has
string.split = string.split or function(s, sep)
    local out, pat = {}, "([^" .. sep .. "]*)" .. sep .. "?"
    for part in s:gmatch(pat) do table.insert(out, part) end
    return out
end
table.find = table.find or function(t, v)
    for i, x in ipairs(t) do if x == v then return i end end
end
table.clear = table.clear or function(t) for k in pairs(t) do t[k]=nil end end
table.clone = table.clone or function(t)
    local c = {}
    for k,v in pairs(t) do c[k]=v end
    return c
end

_log("SANDBOX_READY", "lune sandbox v2 loaded")
-- ════════════ USER SCRIPT BEGINS BELOW ════════════
