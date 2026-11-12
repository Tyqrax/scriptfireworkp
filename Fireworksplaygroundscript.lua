local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

-- Einstellungen
local OFFSET_Z = -4        -- Abstand vor dem Charakter
local OFFSET_Y = 0         -- Feinjustierung der Höhe
local START_WAIT = 3       -- Wartezeit nach der ersten Platzierung, bevor gemessen wird
local PROBE_S = 1          -- Abstand der Versuche beim Messen
local SAFETY = 0.3         -- Puffer auf den Cooldown
local MAX_CD = 300         -- Cooldowns über dieser Dauer (Sek.) werden nicht gelernt
local FIRST_TIMEOUT = 60   -- so lange darf die erste Platzierung beim Scan dauern
local RETRY_S = 3          -- Wartezeit nach "abgelehnt"
local DETECT_EVERY = 5     -- Sekunden zwischen Remote-Suchen
local delayMs = 100
local STEP, MIN, MAX = 100, 100, 10000
local enabled = false

-- Zünden + Nachladen
local ZUEND_TOOL = "RemoteDetonator"
local REFILL_NAME = "\195\150\204\183\204\140\204\139"
local cycleMin = 5         -- Intervall in Minuten (1-60)
local autoCycle = false
local lastCycle = 0
local cycleBusy = false
local refillRemote

local EXCLUDE = {
    ["RemoteDetonator"] = true,
}

local ROT = CFrame.new(0, 0, 0,
    -0.50616979598999023, -1.9951214014213292e-09, -0.86243373155593872,
    -1.9951214014213292e-09, 1, -1.1424077239752251e-09,
    0.86243373155593872, 1.1424077239752251e-09, -0.50616979598999023)

local setStatus = function(_) end
local nextTry = {}     -- frühester nächster Versuch pro Toolname
local cooldown = {}    -- bekannte Cooldowns pro Toolname
local lastOk = {}      -- Zeitpunkt der letzten erfolgreichen Platzierung
local skipUntil = {}   -- Tools, die der Scan vorübergehend überspringt
local cached, cachedIndex
local lastDetect = 0

-- Scan-Zustand
local scanMode = "all"       -- "all" = alle nacheinander, "select" = nur Auswahl
local selectedScan = {["script.lua"] = true}      -- [toolname] = true (Standardmäßig ausgewählt)
local queue = {}             -- Tools, die noch gescannt werden
local scanning = false
local learning = nil         -- Tool, dessen Cooldown gerade gemessen wird
local learnSince = 0
local scanTotal, scanIdx = 0, 0
local autoScanOn = true
local refreshScanList = function() end

local function scanInfo()
    return scanTotal > 0 and (" (" .. scanIdx .. "/" .. scanTotal .. ")") or ""
end

-- Profile
local FILE = "AutoPlaceProfiles.json"
local canFile = (writefile and readfile and isfile) and true or false
local profiles = {}
local activeProfile = nil
local selected = nil
local refreshList = function() end

local function copyTable(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

local function saveAll()
    if not canFile then return end
    pcall(function()
        writefile(FILE, HttpService:JSONEncode({profiles = profiles, active = activeProfile}))
    end)
end

local function loadAll()
    if not canFile then return end
    pcall(function()
        if isfile(FILE) then
            local d = HttpService:JSONDecode(readfile(FILE))
            profiles = d.profiles or {}
            activeProfile = d.active
            if activeProfile and profiles[activeProfile] then
                cooldown = copyTable(profiles[activeProfile])
                selected = activeProfile
            else
                activeProfile = nil
            end
        end
    end)
end
loadAll()

local function resetState()
    nextTry, lastOk, skipUntil = {}, {}, {}
    learning, queue, scanning = nil, {}, false
    scanTotal, scanIdx = 0, 0
    autoScanOn = true
end

local function buildQueue(tools, force)
    queue = {}
    local now = os.clock()
    for _, t in ipairs(tools) do
        local n = t.Name
        if (skipUntil[n] or 0) <= now then
            if scanMode == "all" then
                if force or cooldown[n] == nil then table.insert(queue, n) end
            elseif selectedScan[n] then
                table.insert(queue, n)
            end
        end
    end
    scanTotal, scanIdx = #queue, 0
    scanning = #queue > 0
    if scanning then setStatus("Scan startet: " .. #queue .. " Tools") end
end

local function onSuccess(name)
    local now = os.clock()
    if cooldown[name] then
        lastOk[name] = now
        nextTry[name] = now + cooldown[name] + SAFETY
        setStatus(name .. ": platziert (CD " .. string.format("%.1f", cooldown[name]) .. "s)")
    elseif learning == name and lastOk[name] then
        local cd = now - lastOk[name]
        if cd <= MAX_CD then
            cooldown[name] = cd
            setStatus(name .. ": CD " .. string.format("%.1f", cd) .. "s" .. scanInfo())
        end
        lastOk[name] = now
        nextTry[name] = now + (cooldown[name] or RETRY_S) + SAFETY
        learning = nil
        refreshScanList()
    else
        lastOk[name] = now
        nextTry[name] = now + START_WAIT
        learning = name
        setStatus(name .. ": platziert, messe CD..." .. scanInfo())
    end
end

local function onReject(name)
    local now = os.clock()
    if cooldown[name] then
        cooldown[name] = math.min(MAX_CD, cooldown[name] + 0.5)
        nextTry[name] = now + 1
        setStatus(name .. ": abgelehnt, CD +0.5s")
    elseif learning == name then
        nextTry[name] = now + PROBE_S
        setStatus("Messe " .. name .. ": " .. string.format("%.0f", now - (lastOk[name] or learnSince)) .. "s" .. scanInfo())
    else
        nextTry[name] = now + RETRY_S
        setStatus(name .. ": abgelehnt")
    end
end

local function remoteFolders()
    local result = {}
    for _, f in ipairs(RS:GetChildren()) do
        if f:IsA("Folder") then
            local k = f:GetChildren()
            if #k >= 5 then
                local onlyRemotes = true
                for _, c in ipairs(k) do
                    if not (c:IsA("RemoteEvent") or c:IsA("RemoteFunction")) then
                        onlyRemotes = false
                        break
                    end
                end
                if onlyRemotes then table.insert(result, k) end
            end
        end
    end
    return result
end

local function scanTools()
    local list, seen = {}, {}
    local function add(container)
        if not container then return end
        for _, v in ipairs(container:GetChildren()) do
            if v:IsA("Tool") and not seen[v.Name] and not EXCLUDE[v.Name] then
                seen[v.Name] = true
                table.insert(list, v)
            end
        end
    end
    add(player.Character)
    add(player:FindFirstChild("Backpack"))
    return list
end

local function targetCFrame(root)
    local origin = (root.CFrame * CFrame.new(0, 0, OFFSET_Z)).Position
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = {player.Character}
    params.FilterType = Enum.RaycastFilterType.Exclude
    local hit = workspace:Raycast(origin + Vector3.new(0, 5, 0), Vector3.new(0, -50, 0), params)
    local pos = hit and hit.Position or (origin - Vector3.new(0, 2.5, 0))
    return CFrame.new(pos + Vector3.new(0, OFFSET_Y, 0)) * ROT
end

local function tryRemote(remote, payload)
    local done, ok, res = false, false, nil
    task.spawn(function()
        ok, res = pcall(function() return remote:InvokeServer(payload) end)
        done = true
    end)
    local t = 0
    while not done and t < 1.5 do
        task.wait(0.05)
        t = t + 0.05
    end
    return done and ok, res
end

local function detect(payload)
    for _, kids in ipairs(remoteFolders()) do
        for i, r in ipairs(kids) do
            if r:IsA("RemoteFunction") then
                setStatus("Suche Remote " .. i .. "/" .. #kids)
                local ok, res = tryRemote(r, payload)
                if ok and res then
                    cached, cachedIndex = r, i
                    return true
                end
            end
        end
    end
    return false
end

local function fire(tool)
    local name = tool.Name
    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then
        setStatus("Kein Charakter")
        return false
    end
    local payload = {Type = "Place", Tool = tool, TargetFrame = targetCFrame(root)}

    if not (cached and cached.Parent) then
        cached = nil
        if os.clock() - lastDetect < DETECT_EVERY then
            nextTry[name] = os.clock() + 1
            return false
        end
        lastDetect = os.clock()
        if detect(payload) then
            onSuccess(name)
        else
            nextTry[name] = os.clock() + RETRY_S
            setStatus("Kein Remote passt (Cooldown/Position?)")
        end
        return true
    end

    local remote = cached
    task.spawn(function()
        local ok, res = pcall(function() return remote:InvokeServer(payload) end)
        if ok and res then
            onSuccess(name)
        elseif ok then
            onReject(name)
        else
            cached = nil
            setStatus("Fehler " .. tostring(res):sub(1, 25))
        end
    end)
    return true
end

-- Zünden + Nachladen
local function findRefill()
    if refillRemote and refillRemote.Parent then return refillRemote end
    for _, f in ipairs(RS:GetChildren()) do
        if f:IsA("Folder") then
            local r = f:FindFirstChild(REFILL_NAME)
            if r and r:IsA("RemoteFunction") then
                refillRemote = r
                return r
            end
        end
    end
end

local function runCycle()
    cycleBusy = true
    lastCycle = os.clock()

    -- 1. Zünden
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local bp = player:FindFirstChild("Backpack")
    local tool = (char and char:FindFirstChild(ZUEND_TOOL)) or (bp and bp:FindFirstChild(ZUEND_TOOL))
    if hum and tool then
        local prev = char:FindFirstChildOfClass("Tool")
        if prev == tool then prev = nil end
        hum:EquipTool(tool)
        task.wait(0.4)
        tool:Activate()
        task.wait(0.6)
        if prev and prev.Parent then hum:EquipTool(prev) end
    else
        setStatus("Detonator nicht gefunden")
    end

    -- 2. Sofort nachladen
    local r = findRefill()
    if r then
        local ok, res = pcall(function()
            return r:InvokeServer({Type = "RefreshStacks"})
        end)
        if ok then
            setStatus("Gezündet + nachgeladen")
        else
            refillRemote = nil
            setStatus("Nachladen Fehler")
        end
    else
        setStatus("Nachlade-Remote nicht gefunden")
    end

    task.wait(0.3)
    lastCycle = os.clock()
    cycleBusy = false
end

-- UI
local parent = (gethui and gethui()) or game:GetService("CoreGui")
local old = parent:FindFirstChild("PlaceControlGui")
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "PlaceControlGui"
gui.ResetOnSpawn = false
gui.Parent = parent

local function mkBtn(par, text, x, y, w, h, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, w, 0, h)
    b.Position = UDim2.new(0, x, 0, y)
    b.BackgroundColor3 = color or Color3.fromRGB(60, 60, 70)
    b.Text = text
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 12
    b.Parent = par
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 220, 0, 282)
frame.Position = UDim2.new(0.5, -110, 0.08, 0)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 26)
title.BackgroundTransparency = 1
title.Text = "Auto Place"
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.Parent = frame

local toggle = mkBtn(frame, "AUS", 10, 30, 200, 36, Color3.fromRGB(170, 50, 50))
toggle.TextSize = 16

local minus = mkBtn(frame, "-", 10, 74, 40, 34)
minus.TextSize = 20
local plus = mkBtn(frame, "+", 170, 74, 40, 34)
plus.TextSize = 20

local speedLabel = Instance.new("TextLabel")
speedLabel.Size = UDim2.new(0, 100, 0, 34)
speedLabel.Position = UDim2.new(0, 60, 0, 74)
speedLabel.BackgroundTransparency = 1
speedLabel.TextColor3 = Color3.new(1, 1, 1)
speedLabel.Font = Enum.Font.Gotham
speedLabel.TextSize = 15
speedLabel.Parent = frame

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -20, 0, 26)
statusLabel.Position = UDim2.new(0, 10, 0, 112)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextWrapped = true
statusLabel.Text = "Bereit"
statusLabel.Parent = frame

local profToggle = mkBtn(frame, "Profile ein/aus", 10, 146, 200, 28)
local scanToggle = mkBtn(frame, "Scan-Fenster ein/aus", 10, 178, 200, 28)

-- Zünden + Nachladen: Minuten wählen
local cMinus = mkBtn(frame, "-", 10, 210, 40, 30)
cMinus.TextSize = 20
local cPlus = mkBtn(frame, "+", 170, 210, 40, 30)
cPlus.TextSize = 20

local cLabel = Instance.new("TextLabel")
cLabel.Size = UDim2.new(0, 100, 0, 30)
cLabel.Position = UDim2.new(0, 60, 0, 210)
cLabel.BackgroundTransparency = 1
cLabel.TextColor3 = Color3.new(1, 1, 1)
cLabel.Font = Enum.Font.Gotham
cLabel.TextSize = 13
cLabel.Parent = frame

local cycleBtn = mkBtn(frame, "Zünden + Nachladen: AUS", 10, 244, 200, 30, Color3.fromRGB(170, 50, 50))

setStatus = function(t) statusLabel.Text = t end

local function refreshSpeed() speedLabel.Text = delayMs .. " ms" end
refreshSpeed()

local function refreshCycleLabel()
    if autoCycle then
        local left = math.max(0, math.ceil(cycleMin * 60 - (os.clock() - lastCycle)))
        cLabel.Text = cycleMin .. " min (" .. math.floor(left / 60) .. ":" .. string.format("%02d", left % 60) .. ")"
    else
        cLabel.Text = cycleMin .. " min"
    end
end
refreshCycleLabel()

cMinus.MouseButton1Click:Connect(function()
    cycleMin = math.max(1, cycleMin - 1)
    refreshCycleLabel()
end)

cPlus.MouseButton1Click:Connect(function()
    cycleMin = math.min(60, cycleMin + 1)
    refreshCycleLabel()
end)

cycleBtn.MouseButton1Click:Connect(function()
    autoCycle = not autoCycle
    cycleBtn.Text = autoCycle and "Zünden + Nachladen: AN" or "Zünden + Nachladen: AUS"
    cycleBtn.BackgroundColor3 = autoCycle and Color3.fromRGB(50, 150, 70) or Color3.fromRGB(170, 50, 50)
    lastCycle = os.clock()
    refreshCycleLabel()
end)

task.spawn(function()
    while gui.Parent do
        refreshCycleLabel()
        task.wait(1)
    end
end)

-- Profil-Fenster (rechts)
local pframe = Instance.new("Frame")
pframe.Size = UDim2.new(0, 240, 0, 250)
pframe.Position = UDim2.new(1, 8, 0, 0)
pframe.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
pframe.BorderSizePixel = 0
pframe.Parent = frame
Instance.new("UICorner", pframe).CornerRadius = UDim.new(0, 8)

local ptitle = Instance.new("TextLabel")
ptitle.Size = UDim2.new(1, 0, 0, 22)
ptitle.BackgroundTransparency = 1
ptitle.Text = "Profile"
ptitle.TextColor3 = Color3.new(1, 1, 1)
ptitle.Font = Enum.Font.GothamBold
ptitle.TextSize = 14
ptitle.Parent = pframe

local nameBox = Instance.new("TextBox")
nameBox.Size = UDim2.new(1, -16, 0, 28)
nameBox.Position = UDim2.new(0, 8, 0, 24)
nameBox.BackgroundColor3 = Color3.fromRGB(50, 50, 58)
nameBox.TextColor3 = Color3.new(1, 1, 1)
nameBox.PlaceholderText = "Profilname / Import-Text"
nameBox.PlaceholderColor3 = Color3.fromRGB(140, 140, 150)
nameBox.Text = ""
nameBox.ClearTextOnFocus = false
nameBox.ClipsDescendants = true
nameBox.TextXAlignment = Enum.TextXAlignment.Left
nameBox.Font = Enum.Font.Gotham
nameBox.TextSize = 12
nameBox.Parent = pframe
Instance.new("UICorner", nameBox).CornerRadius = UDim.new(0, 6)

local bSave   = mkBtn(pframe, "Speichern", 8, 58, 70, 30, Color3.fromRGB(50, 110, 160))
local bAct    = mkBtn(pframe, "Aktivieren", 85, 58, 70, 30, Color3.fromRGB(50, 150, 70))
local bDel    = mkBtn(pframe, "Löschen", 162, 58, 70, 30, Color3.fromRGB(170, 50, 50))
local bExp    = mkBtn(pframe, "Export", 8, 92, 70, 30)
local bImp    = mkBtn(pframe, "Import", 85, 92, 70, 30)
local bReset  = mkBtn(pframe, "Neu lernen", 162, 92, 70, 30)

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, -16, 0, 118)
list.Position = UDim2.new(0, 8, 0, 128)
list.BackgroundColor3 = Color3.fromRGB(40, 40, 46)
list.BorderSizePixel = 0
list.ScrollBarThickness = 4
list.CanvasSize = UDim2.new(0, 0, 0, 0)
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = pframe
local layout = Instance.new("UIListLayout", list)
layout.Padding = UDim.new(0, 3)

refreshList = function()
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    local names = {}
    for n in pairs(profiles) do table.insert(names, n) end
    table.sort(names)
    for _, n in ipairs(names) do
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -6, 0, 26)
        b.BackgroundColor3 = (n == selected) and Color3.fromRGB(70, 90, 140) or Color3.fromRGB(60, 60, 70)
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Font = Enum.Font.Gotham
        b.TextSize = 13
        b.Text = (n == activeProfile and "▶ " or "") .. n
        b.Parent = list
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
        b.MouseButton1Click:Connect(function()
            selected = n
            nameBox.Text = n
            refreshList()
        end)
    end
end

local function curName()
    local t = nameBox.Text:match("^%s*(.-)%s*$") or ""
    if t == "" or t:sub(1, 1) == "{" then t = selected end
    return t
end

bSave.MouseButton1Click:Connect(function()
    local n = curName()
    if not n or n == "" then setStatus("Erst Namen eingeben") return end
    if next(cooldown) == nil then setStatus("Noch nichts gelernt") return end
    profiles[n] = copyTable(cooldown)
    selected, activeProfile = n, n
    saveAll()
    refreshList()
    setStatus("Gespeichert: " .. n .. (canFile and "" or " (nur bis Neustart)"))
end)

bAct.MouseButton1Click:Connect(function()
    local n = curName()
    if not n or not profiles[n] then setStatus("Profil nicht gefunden") return end
    cooldown = copyTable(profiles[n])
    activeProfile, selected = n, n
    resetState()
    saveAll()
    refreshList()
    refreshScanList()
    setStatus("Aktiv: " .. n)
end)

bDel.MouseButton1Click:Connect(function()
    local n = curName()
    if not n or not profiles[n] then setStatus("Profil nicht gefunden") return end
    profiles[n] = nil
    if activeProfile == n then activeProfile = nil end
    if selected == n then selected = nil end
    nameBox.Text = ""
    saveAll()
    refreshList()
    setStatus("Gelöscht: " .. n)
end)

bExp.MouseButton1Click:Connect(function()
    local n = curName()
    if not n or not profiles[n] then setStatus("Profil nicht gefunden") return end
    local str = HttpService:JSONEncode({n = n, c = profiles[n]})
    if setclipboard then
        setclipboard(str)
        setStatus("Kopiert: " .. n)
    else
        nameBox.Text = str
        setStatus("Text im Feld, selbst kopieren")
    end
end)

bImp.MouseButton1Click:Connect(function()
    local ok, d = pcall(function() return HttpService:JSONDecode(nameBox.Text) end)
    if not ok or type(d) ~= "table" or type(d.n) ~= "string" or type(d.c) ~= "table" then
        setStatus("Import: Text im Feld ungültig")
        return
    end
    local clean = {}
    for k, v in pairs(d.c) do
        if type(k) == "string" and type(v) == "number" then clean[k] = v end
    end
    profiles[d.n] = clean
    selected = d.n
    nameBox.Text = d.n
    saveAll()
    refreshList()
    setStatus("Importiert: " .. d.n)
end)

bReset.MouseButton1Click:Connect(function()
    cooldown = {}
    activeProfile = nil
    resetState()
    saveAll()
    refreshList()
    refreshScanList()
    setStatus("Cooldowns werden neu gelernt")
end)

profToggle.MouseButton1Click:Connect(function()
    pframe.Visible = not pframe.Visible
end)

-- Scan-Fenster (links)
local sframe = Instance.new("Frame")
sframe.Size = UDim2.new(0, 240, 0, 238)
sframe.Position = UDim2.new(0, -248, 0, 0)
sframe.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
sframe.BorderSizePixel = 0
sframe.Parent = frame
Instance.new("UICorner", sframe).CornerRadius = UDim.new(0, 8)

local stitle = Instance.new("TextLabel")
stitle.Size = UDim2.new(1, 0, 0, 22)
stitle.BackgroundTransparency = 1
stitle.Text = "Scan"
stitle.TextColor3 = Color3.new(1, 1, 1)
stitle.Font = Enum.Font.GothamBold
stitle.TextSize = 14
stitle.Parent = sframe

local bMode = mkBtn(sframe, "Modus: Alle nacheinander", 8, 24, 224, 28, Color3.fromRGB(80, 70, 130))

local slist = Instance.new("ScrollingFrame")
slist.Size = UDim2.new(1, -16, 0, 110)
slist.Position = UDim2.new(0, 8, 0, 56)
slist.BackgroundColor3 = Color3.fromRGB(40, 40, 46)
slist.BorderSizePixel = 0
slist.ScrollBarThickness = 4
slist.CanvasSize = UDim2.new(0, 0, 0, 0)
slist.AutomaticCanvasSize = Enum.AutomaticSize.Y
slist.Parent = sframe
local slayout = Instance.new("UIListLayout", slist)
slayout.Padding = UDim.new(0, 3)

local bRefresh = mkBtn(sframe, "Liste neu laden", 8, 170, 108, 28)
local bSelAll  = mkBtn(sframe, "Alle wählen", 124, 170, 108, 28)
local bStart   = mkBtn(sframe, "Scan starten", 8, 202, 108, 28, Color3.fromRGB(50, 150, 70))
local bStop    = mkBtn(sframe, "Abbrechen", 124, 202, 108, 28, Color3.fromRGB(170, 50, 50))

refreshScanList = function()
    for _, c in ipairs(slist:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    for _, t in ipairs(scanTools()) do
        local n = t.Name
        local cd = cooldown[n]
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -6, 0, 24)
        b.BackgroundColor3 = selectedScan[n] and Color3.fromRGB(70, 90, 140) or Color3.fromRGB(60, 60, 70)
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Font = Enum.Font.Gotham
        b.TextSize = 12
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.Text = (selectedScan[n] and " [x] " or " [ ] ") .. n .. (cd and (" · " .. string.format("%.1f", cd) .. "s") or " · ?")
        b.Parent = slist
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
        b.MouseButton1Click:Connect(function()
            selectedScan[n] = not selectedScan[n] or nil
            refreshScanList()
        end)
    end
end

bMode.MouseButton1Click:Connect(function()
    scanMode = (scanMode == "all") and "select" or "all"
    bMode.Text = (scanMode == "all") and "Modus: Alle nacheinander" or "Modus: Nur Auswahl"
    learning, queue, scanning = nil, {}, false
    setStatus(scanMode == "all" and "Modus: alle nacheinander" or "Modus: nur Auswahl")
end)

bRefresh.MouseButton1Click:Connect(refreshScanList)

bSelAll.MouseButton1Click:Connect(function()
    local anyOff = false
    for _, t in ipairs(scanTools()) do
        if not selectedScan[t.Name] then anyOff = true break end
    end
    selectedScan = {}
    if anyOff then
        for _, t in ipairs(scanTools()) do selectedScan[t.Name] = true end
    end
    refreshScanList()
end)

bStart.MouseButton1Click:Connect(function()
    if not enabled then setStatus("Erst auf AN schalten") return end
    skipUntil = {}
    learning = nil
    autoScanOn = true
    buildQueue(scanTools(), true)
    if not scanning then setStatus("Nichts zu scannen (Auswahl leer?)") end
end)

bStop.MouseButton1Click:Connect(function()
    learning, queue, scanning = nil, {}, false
    autoScanOn = false
    setStatus("Scan abgebrochen")
end)

scanToggle.MouseButton1Click:Connect(function()
    sframe.Visible = not sframe.Visible
end)

refreshList()
refreshScanList()
if not canFile then setStatus("Hinweis: kein writefile, Profile nur bis Neustart") end

toggle.MouseButton1Click:Connect(function()
    enabled = not enabled
    toggle.Text = enabled and "AN" or "AUS"
    toggle.BackgroundColor3 = enabled and Color3.fromRGB(50, 150, 70) or Color3.fromRGB(170, 50, 50)
    if enabled then
        resetState()
        refreshScanList()
    else
        setStatus("Gestoppt")
    end
end)

minus.MouseButton1Click:Connect(function()
    delayMs = math.max(MIN, delayMs - STEP)
    refreshSpeed()
end)

plus.MouseButton1Click:Connect(function()
    delayMs = math.min(MAX, delayMs + STEP)
    refreshSpeed()
end)

-- Hauptschleife
task.spawn(function()
    while gui.Parent do
        if enabled then
            -- Zünden + Nachladen, wenn die eingestellte Zeit abgelaufen ist
            if autoCycle and not cycleBusy and os.clock() - lastCycle >= cycleMin * 60 then
                runCycle()
            end

            local sent = false
            local tools = scanTools()
            local byName = {}
            for _, t in ipairs(tools) do byName[t.Name] = t end

            -- Automatischer Scan (nur Modus "Alle", nur Tools ohne bekannten Cooldown)
            if not scanning and autoScanOn and scanMode == "all" then
                buildQueue(tools, false)
            end

            if scanning then
                -- Messung abbrechen, wenn Tool weg, erste Platzierung nicht klappt oder zu lange
                if learning then
                    local now = os.clock()
                    local gone = not byName[learning]
                    local stuckFirst = not lastOk[learning] and (now - learnSince) > FIRST_TIMEOUT
                    local tooLong = (now - learnSince) > MAX_CD
                    if gone or stuckFirst or tooLong then
                        skipUntil[learning] = now + 120
                        setStatus("Übersprungen: " .. learning)
                        learning = nil
                    end
                end

                -- nächstes Tool aus der Warteschlange holen
                while not learning and #queue > 0 do
                    local n = table.remove(queue, 1)
                    if byName[n] then
                        learning = n
                        learnSince = os.clock()
                        scanIdx = scanIdx + 1
                        cooldown[n] = nil
                        lastOk[n] = nil
                        nextTry[n] = 0
                    end
                end

                if not learning then
                    scanning = false
                    scanTotal, scanIdx = 0, 0
                    setStatus("Scan fertig, platziere alle")
                    refreshScanList()
                else
                    -- NUR das gemessene Tool wird platziert
                    local tool = byName[learning]
                    if tool and os.clock() >= (nextTry[learning] or 0) then
                        nextTry[learning] = os.clock() + PROBE_S
                        if fire(tool) then
                            sent = true
                            task.wait(delayMs / 1000)
                        end
                    end
                end
            else
                -- Normalbetrieb: alle Tools mit bekanntem Cooldown
                for _, tool in ipairs(tools) do
                    if not enabled or not gui.Parent or scanning then break end
                    local name = tool.Name
                    if cooldown[name] and tool.Parent and os.clock() >= (nextTry[name] or 0) then
                        nextTry[name] = os.clock() + PROBE_S
                        if fire(tool) then
                            sent = true
                            task.wait(delayMs / 1000)
                        end
                    end
                end
            end
            if not sent then task.wait(0.2) end
        else
            task.wait(0.1)
        end
    end
end)
