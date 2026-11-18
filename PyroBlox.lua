local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer
local pg = LP:WaitForChild("PlayerGui")

-- ===== Einstellungen =====
local ITEM = "display_shell_16"
local SLOT_NAME = "Slot1"
local TARGET = Vector3.new(-413.09442138671875, 1.0462023019790649, 18.172153472900391)
local SHOP = TARGET
local FINISH = TARGET            -- gezündet wird jetzt am Platzierpunkt
local AWAY_DISTANCE = 20         -- so viele Studs nach dem Zünden weglaufen
local DIRECTION_REF = Vector3.new(-413.73162841796875, 0.70886486768722534, 105.0078125)
local TOLERANCE = 4
local WALK_TIMEOUT = 25
local STALL_SECONDS = 5
local LIGHT_RETRY_DELAY = 0.7
local LIGHT_MAX_TRIES = 20
local MONEY_RETRIES = 24
local MONEY_RETRY_WAIT = 5
local SETTLE_SECONDS = 5
local MIN_BIG = 0.5
local delayMs = 100
local waitSec = 90
-- =========================

-- Weglauf-Punkt: 20 Studs vom Platzierpunkt in Richtung DIRECTION_REF
local flatDir = Vector3.new(DIRECTION_REF.X - TARGET.X, 0, DIRECTION_REF.Z - TARGET.Z).Unit
local AWAY = TARGET + flatDir * AWAY_DISTANCE

local PyroRemotes
pcall(function() PyroRemotes = RS:WaitForChild("PyroRemotes", 10) end)
local PlaceEvent = PyroRemotes and PyroRemotes:FindFirstChild("RequestPlace")
local LightEvent = PyroRemotes and PyroRemotes:FindFirstChild("RequestLightAll")
local EffectStarted = PyroRemotes and PyroRemotes:FindFirstChild("EffectStarted")
local UIRequest = PyroRemotes and PyroRemotes:FindFirstChild("UIRequest")

local cash
pcall(function()
    cash = LP:WaitForChild("leaderstats", 10):WaitForChild("Cash", 10)
end)

local running, alive = false, true
local lit = false
local statusLabel, toggleBtn, remainLabel

-- ===== Cash-Überwachung =====
local recent = {}
local bigThreshold = MIN_BIG
local lastBig, bigTotal = nil, 0
local armed = false

if cash then
    local prev = cash.Value
    cash.Changed:Connect(function(v)
        local d = v - prev
        prev = v
        if d <= 0 then return end
        if armed then
            if d > bigThreshold then
                lastBig = tick()
                bigTotal += d
            end
        else
            recent[#recent + 1] = { tick(), d }
            while #recent > 0 and tick() - recent[1][1] > 20 do
                table.remove(recent, 1)
            end
        end
    end)
end

local function armMoneyWatch()
    local maxD = 0
    for _, r in ipairs(recent) do
        if tick() - r[1] <= 20 and r[2] > maxD then maxD = r[2] end
    end
    bigThreshold = math.max(maxD * 3, MIN_BIG)
    lastBig, bigTotal = nil, 0
    armed = true
end

if EffectStarted then
    EffectStarted.OnClientEvent:Connect(function(data)
        if type(data) == "table" and data.ownerUserId == LP.UserId and data.lightAll then
            lit = true
        end
    end)
end

local function setStatus(t)
    if statusLabel then statusLabel.Text = "Status: " .. t end
end

local function setToggleVisual()
    if not toggleBtn then return end
    toggleBtn.Text = running and "AN" or "AUS"
    toggleBtn.BackgroundColor3 = running and Color3.fromRGB(50, 160, 70) or Color3.fromRGB(170, 50, 50)
end

local function getRemaining()
    local ok, res = pcall(function()
        local n = pg:FindFirstChild("PyroUI")
        n = n and n:FindFirstChild("HUD")
        n = n and n:FindFirstChild("Hotbar")
        n = n and n:FindFirstChild("Slots")
        local slot = n and n:FindFirstChild(SLOT_NAME)
        if not slot then return 0 end
        local sc = slot:FindFirstChild("StackCount")
        if not sc or not sc.Visible then return 0 end
        local txt = sc.Text or ""
        local num = txt:match("[x×]%s*(%d+)")
        if num then return tonumber(num) end
        if txt:match("%d") then return 1 end
        return 0
    end)
    if ok then return res end
    return 0
end

local function updateRemaining()
    local r = getRemaining()
    if remainLabel then remainLabel.Text = "Übrig: " .. tostring(r) end
    return r
end

local function getChar()
    local char = LP.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hrp and hum and hum.Health > 0 then return hrp, hum end
end

local function flatDist(a, b)
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function ensureAt(pos)
    local hrp, hum = getChar()
    if not hrp then return false end
    if flatDist(hrp.Position, pos) <= TOLERANCE then return true end
    setStatus("Laufe zum Ziel...")
    local start = tick()
    while running and alive and tick() - start < WALK_TIMEOUT do
        hrp, hum = getChar()
        if not hrp then return false end
        if flatDist(hrp.Position, pos) <= TOLERANCE then return true end
        hum:MoveTo(Vector3.new(pos.X, hrp.Position.Y, pos.Z))
        task.wait(0.1)
    end
    return false
end

local function stopRunning(msg)
    running = false
    armed = false
    if msg then setStatus(msg) end
    setToggleVisual()
end

-- Am Platzierpunkt zünden, dann 20 Studs weglaufen
local function finishSequence()
    if not LightEvent then
        stopRunning("RequestLightAll fehlt!")
        return false
    end
    lit = false
    armMoneyWatch()
    for i = 1, LIGHT_MAX_TRIES do
        if not (running and alive) then return false end
        if not ensureAt(FINISH) then
            stopRunning("Platzierpunkt nicht erreicht")
            return false
        end
        setStatus("Zünde... Versuch " .. i .. "/" .. LIGHT_MAX_TRIES)
        pcall(function() LightEvent:FireServer(1) end)
        local t = tick()
        while tick() - t < LIGHT_RETRY_DELAY do
            if lit then
                setStatus("Gezündet, laufe " .. AWAY_DISTANCE .. " Studs weg...")
                if ensureAt(AWAY) then return true end
                stopRunning("Weglaufen nicht geschafft")
                return false
            end
            task.wait(0.05)
        end
    end
    stopRunning("Zünden nicht bestätigt")
    return false
end

local function buy(qty)
    local before = getRemaining()
    local ok, res = pcall(function()
        return UIRequest:InvokeServer("Purchase", { id = ITEM, qty = qty })
    end)
    print("KAUF", qty, ok, res)
    local t = tick()
    while tick() - t < 1.5 do
        if getRemaining() > before then return true end
        task.wait(0.1)
    end
    return false
end

local function buyAll()
    local n = 0
    while running and alive and buy(10) do
        n += 1
        updateRemaining()
    end
    while running and alive and buy(1) do
        n += 1
        updateRemaining()
    end
    return n
end

local function buyPhase()
    if not UIRequest then
        stopRunning("UIRequest fehlt!")
        return false
    end
    for attempt = 1, MONEY_RETRIES do
        if not (running and alive) then return false end
        if not ensureAt(SHOP) then
            stopRunning("Shop-Position nicht erreicht")
            return false
        end
        setStatus("Kaufe... Versuch " .. attempt .. "/" .. MONEY_RETRIES)
        if buyAll() > 0 then return true end
        local t = tick()
        while tick() - t < MONEY_RETRY_WAIT and running and alive do
            task.wait(0.2)
        end
    end
    stopRunning("Kein Geld / Kauf nicht möglich")
    return false
end

local function waitForMoney()
    local start = tick()
    if not cash then
        armed = false
        while running and alive and tick() - start < 30 do
            setStatus("Warte (ohne Cash-Wert)...")
            task.wait(0.2)
        end
        return
    end
    while running and alive and tick() - start < waitSec do
        if lastBig then
            setStatus(string.format("Auszahlung: +%.0f", bigTotal))
            if tick() - lastBig >= SETTLE_SECONDS then break end
        else
            setStatus("Warte auf Auszahlung: " .. math.ceil(waitSec - (tick() - start)) .. "s")
        end
        task.wait(0.2)
    end
    armed = false
end

local function loop()
    local lastRem, lastChange = nil, tick()
    local placedAny = false
    while alive do
        local rem = updateRemaining()
        if running then
            if rem <= 0 then
                if placedAny then
                    if finishSequence() then
                        placedAny = false
                        waitForMoney()
                    else
                        placedAny = false
                    end
                end
                if running then buyPhase() end
                lastRem = nil
                lastChange = tick()
            else
                if rem ~= lastRem then
                    lastRem = rem
                    lastChange = tick()
                end
                if tick() - lastChange > STALL_SECONDS then
                    if finishSequence() then
                        placedAny = false
                        waitForMoney()
                        if running then buyPhase() end
                    end
                    lastRem = nil
                    lastChange = tick()
                elseif ensureAt(TARGET) then
                    setStatus("Platziere...")
                    if PlaceEvent then
                        pcall(function() PlaceEvent:FireServer(ITEM, TARGET) end)
                        placedAny = true
                    else
                        stopRunning("RequestPlace fehlt!")
                    end
                    task.wait(math.max(delayMs, 0) / 1000)
                else
                    task.wait(0.2)
                end
            end
        else
            lastRem = nil
            lastChange = tick()
            task.wait(0.2)
        end
    end
end

-- ===== UI =====
local function make(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end

local ok, err = pcall(function()
    local old = pg:FindFirstChild("AutoPlaceUI")
    if old then old:Destroy() end

    local gui = make("ScreenGui", {
        Name = "AutoPlaceUI", ResetOnSpawn = false, IgnoreGuiInset = true,
        DisplayOrder = 999, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, pg)

    local frame = make("Frame", {
        Size = UDim2.new(0, 230, 0, 255),
        Position = UDim2.new(0.5, -115, 0.1, 0),
        BackgroundColor3 = Color3.fromRGB(30, 30, 36),
        BorderSizePixel = 0, ZIndex = 1,
    }, gui)
    make("UICorner", {CornerRadius = UDim.new(0, 8)}, frame)

    make("TextLabel", {
        Size = UDim2.new(1, -40, 0, 28), Position = UDim2.new(0, 8, 0, 0),
        BackgroundTransparency = 1, Text = "Auto Place + Kauf",
        TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.SourceSansBold,
        TextSize = 18, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 2,
    }, frame)

    local close = make("TextButton", {
        Size = UDim2.new(0, 26, 0, 26), Position = UDim2.new(1, -30, 0, 2),
        BackgroundColor3 = Color3.fromRGB(170, 50, 50), Text = "X",
        TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.SourceSansBold,
        TextSize = 16, ZIndex = 2,
    }, frame)
    make("UICorner", {CornerRadius = UDim.new(0, 6)}, close)

    toggleBtn = make("TextButton", {
        Size = UDim2.new(1, -20, 0, 36), Position = UDim2.new(0, 10, 0, 34),
        BackgroundColor3 = Color3.fromRGB(170, 50, 50), Text = "AUS",
        TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.SourceSansBold,
        TextSize = 20, ZIndex = 2,
    }, frame)
    make("UICorner", {CornerRadius = UDim.new(0, 6)}, toggleBtn)

    make("TextLabel", {
        Size = UDim2.new(1, -20, 0, 18), Position = UDim2.new(0, 10, 0, 76),
        BackgroundTransparency = 1, Text = "Verzögerung (ms):",
        TextColor3 = Color3.fromRGB(200, 200, 200), Font = Enum.Font.SourceSans,
        TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 2,
    }, frame)

    local box = make("TextBox", {
        Size = UDim2.new(1, -20, 0, 28), Position = UDim2.new(0, 10, 0, 96),
        BackgroundColor3 = Color3.fromRGB(50, 50, 58), Text = tostring(delayMs),
        TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.SourceSans,
        TextSize = 18, ClearTextOnFocus = false, ZIndex = 2,
    }, frame)
    make("UICorner", {CornerRadius = UDim.new(0, 6)}, box)

    local function setDelay(v)
        v = math.max(0, math.floor(v))
        delayMs = v
        box.Text = tostring(v)
    end
    box.FocusLost:Connect(function()
        local n = tonumber(box.Text)
        if n then setDelay(n) else box.Text = tostring(delayMs) end
    end)

    for i, s in ipairs({-10, -1, 1, 10}) do
        local b = make("TextButton", {
            Size = UDim2.new(0.25, -6, 0, 26),
            Position = UDim2.new(0.25 * (i - 1), (i == 1) and 10 or 4, 0, 130),
            BackgroundColor3 = Color3.fromRGB(60, 60, 70),
            Text = (s > 0 and "+" or "") .. s, TextColor3 = Color3.new(1, 1, 1),
            Font = Enum.Font.SourceSansBold, TextSize = 16, ZIndex = 2,
        }, frame)
        make("UICorner", {CornerRadius = UDim.new(0, 6)}, b)
        b.MouseButton1Click:Connect(function() setDelay(delayMs + s) end)
    end

    remainLabel = make("TextLabel", {
        Size = UDim2.new(1, -20, 0, 24), Position = UDim2.new(0, 10, 0, 160),
        BackgroundTransparency = 1, Text = "Übrig: ?",
        TextColor3 = Color3.fromRGB(120, 220, 140), Font = Enum.Font.SourceSansBold,
        TextSize = 20, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 2,
    }, frame)

    make("TextLabel", {
        Size = UDim2.new(0.6, -10, 0, 26), Position = UDim2.new(0, 10, 0, 188),
        BackgroundTransparency = 1, Text = "Max. Warten (s):",
        TextColor3 = Color3.fromRGB(200, 200, 200), Font = Enum.Font.SourceSans,
        TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 2,
    }, frame)

    local waitBox = make("TextBox", {
        Size = UDim2.new(0.4, -10, 0, 26), Position = UDim2.new(0.6, 0, 0, 188),
        BackgroundColor3 = Color3.fromRGB(50, 50, 58), Text = tostring(waitSec),
        TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.SourceSans,
        TextSize = 18, ClearTextOnFocus = false, ZIndex = 2,
    }, frame)
    make("UICorner", {CornerRadius = UDim.new(0, 6)}, waitBox)
    waitBox.FocusLost:Connect(function()
        local n = tonumber(waitBox.Text)
        if n then waitSec = math.max(0, math.floor(n)) end
        waitBox.Text = tostring(waitSec)
    end)

    statusLabel = make("TextLabel", {
        Size = UDim2.new(1, -20, 0, 14), Position = UDim2.new(0, 10, 1, -22),
        BackgroundTransparency = 1, Text = "Status: Aus",
        TextColor3 = Color3.fromRGB(160, 160, 160), Font = Enum.Font.SourceSans,
        TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 2,
    }, frame)

    toggleBtn.MouseButton1Click:Connect(function()
        running = not running
        if not running then armed = false setStatus("Aus") end
        setToggleVisual()
    end)

    close.MouseButton1Click:Connect(function()
        alive = false
        running = false
        gui:Destroy()
    end)

    local dragging, dragStart, startPos
    frame.InputBegan:Connect(function(input)
        if (input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch)
            and input.Position.Y - frame.AbsolutePosition.Y < 30 then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end)

if not ok then warn("UI-Fehler: " .. tostring(err)) end

task.spawn(loop)
