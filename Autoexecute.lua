-- Code Runner UI v3: An/Aus-Schalter, läuft dauerhaft, Geschwindigkeit live einstellbar
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local MAX_RATE = 1000        -- maximale Ausführungen pro Sekunde
local MAX_PER_FRAME = 100    -- Schutz gegen Einfrieren pro Frame

local okHui, huiParent = pcall(function() return gethui() end)
local guiParent = (okHui and huiParent) or playerGui

for _, p in ipairs({guiParent, playerGui}) do
	local old = p:FindFirstChild("CodeRunnerUI")
	if old then old:Destroy() end
end

local C = {
	bg     = Color3.fromRGB(24, 24, 30),
	bar    = Color3.fromRGB(36, 36, 46),
	field  = Color3.fromRGB(16, 16, 20),
	chip   = Color3.fromRGB(50, 50, 64),
	text   = Color3.fromRGB(235, 235, 240),
	muted  = Color3.fromRGB(150, 150, 165),
	green  = Color3.fromRGB(40, 160, 70),
	red    = Color3.fromRGB(190, 55, 55),
	err    = Color3.fromRGB(255, 120, 120),
	ok     = Color3.fromRGB(120, 230, 140),
}

local function make(class, props, parent)
	local obj = Instance.new(class)
	for k, v in pairs(props) do obj[k] = v end
	obj.Parent = parent
	return obj
end

local function corner(parent, r)
	return make("UICorner", {CornerRadius = UDim.new(0, r or 8)}, parent)
end

local function button(text, color, parent, order)
	local b = make("TextButton", {
		BackgroundColor3 = color,
		Text = text,
		TextColor3 = C.text,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		LayoutOrder = order or 0,
	}, parent)
	corner(b, 8)
	return b
end

local gui = make("ScreenGui", {
	Name = "CodeRunnerUI",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, guiParent)

local viewport = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2.new(800, 600)
local width = math.clamp(viewport.X - 24, 240, 290)
local FULL_H = 316
local BAR_H = 34

local frame = make("Frame", {
	Size = UDim2.fromOffset(width, FULL_H),
	Position = UDim2.fromOffset(12, 50),
	BackgroundColor3 = C.bg,
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, gui)
corner(frame, 12)
make("UIStroke", {Color = C.chip, Thickness = 1}, frame)

-- Titelleiste
local bar = make("Frame", {
	Size = UDim2.new(1, 0, 0, BAR_H),
	BackgroundColor3 = C.bar,
	BorderSizePixel = 0,
}, frame)
corner(bar, 12)

make("TextLabel", {
	Size = UDim2.new(1, -84, 1, 0),
	Position = UDim2.fromOffset(12, 0),
	BackgroundTransparency = 1,
	Text = "Code Runner",
	TextColor3 = C.text,
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
}, bar)

local minBtn = make("TextButton", {
	Size = UDim2.fromOffset(42, BAR_H),
	Position = UDim2.new(1, -84, 0, 0),
	BackgroundTransparency = 1,
	Text = "–",
	TextColor3 = C.text,
	Font = Enum.Font.GothamBold,
	TextSize = 20,
}, bar)

local closeBtn = make("TextButton", {
	Size = UDim2.fromOffset(42, BAR_H),
	Position = UDim2.new(1, -42, 0, 0),
	BackgroundTransparency = 1,
	Text = "✕",
	TextColor3 = C.err,
	Font = Enum.Font.GothamBold,
	TextSize = 15,
}, bar)

-- Inhalt
local body = make("Frame", {
	Size = UDim2.new(1, 0, 1, -BAR_H),
	Position = UDim2.fromOffset(0, BAR_H),
	BackgroundTransparency = 1,
}, frame)
make("UIPadding", {
	PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
}, body)
make("UIListLayout", {
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, body)

local codeBox = make("TextBox", {
	Size = UDim2.new(1, 0, 0, 90),
	BackgroundColor3 = C.field,
	TextColor3 = C.text,
	PlaceholderText = "-- Code hier einfügen",
	PlaceholderColor3 = C.muted,
	Text = 'print("Hallo von Executor!")',
	Font = Enum.Font.Code,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	MultiLine = true,
	ClearTextOnFocus = false,
	TextWrapped = true,
	LayoutOrder = 1,
}, body)
corner(codeBox, 8)
make("UIPadding", {
	PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
	PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
}, codeBox)

-- Geschwindigkeit: Label + [-] [Eingabe] [+]
local rateRow = make("Frame", {
	Size = UDim2.new(1, 0, 0, 40),
	BackgroundTransparency = 1,
	LayoutOrder = 2,
}, body)

make("TextLabel", {
	Size = UDim2.new(1, -140, 1, 0),
	BackgroundTransparency = 1,
	Text = "Pro Sekunde\n(0 = max. Tempo)",
	TextColor3 = C.text,
	Font = Enum.Font.Gotham,
	TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextWrapped = true,
}, rateRow)

local minusBtn = button("−", C.chip, rateRow)
minusBtn.Size = UDim2.fromOffset(40, 40)
minusBtn.Position = UDim2.new(1, -140, 0, 0)

local rateBox = make("TextBox", {
	Size = UDim2.fromOffset(56, 40),
	Position = UDim2.new(1, -96, 0, 0),
	BackgroundColor3 = C.field,
	TextColor3 = C.text,
	Text = "10",
	Font = Enum.Font.Code,
	TextSize = 16,
	ClearTextOnFocus = false,
}, rateRow)
corner(rateBox, 8)

local plusBtn = button("+", C.chip, rateRow)
plusBtn.Size = UDim2.fromOffset(40, 40)
plusBtn.Position = UDim2.new(1, -40, 0, 0)

-- Presets
local presetRow = make("Frame", {
	Size = UDim2.new(1, 0, 0, 28),
	BackgroundTransparency = 1,
	LayoutOrder = 3,
}, body)
make("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 5),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, presetRow)

local presets = {1, 10, 30, 60, 120}
local rate = 10

local function applyRate(n)
	rate = math.clamp(math.floor(n), 0, MAX_RATE)
	rateBox.Text = tostring(rate)
end

for i, v in ipairs(presets) do
	local b = button(tostring(v), C.chip, presetRow, i)
	b.Size = UDim2.new(1 / #presets, -4, 1, 0)
	b.TextSize = 12
	b.Activated:Connect(function() applyRate(v) end)
end

minusBtn.Activated:Connect(function()
	local step = rate > 100 and 10 or (rate > 20 and 5 or 1)
	applyRate(rate - step)
end)
plusBtn.Activated:Connect(function()
	local step = rate >= 100 and 10 or (rate >= 20 and 5 or 1)
	applyRate(rate + step)
end)
rateBox.FocusLost:Connect(function()
	local n = tonumber((rateBox.Text:gsub(",", ".")))
	applyRate(n and math.max(n, 0) or rate)
end)

-- An/Aus-Schalter
local toggleBtn = button("▶  AN", C.green, body, 4)
toggleBtn.Size = UDim2.new(1, 0, 0, 44)
toggleBtn.TextSize = 17

local status = make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 30),
	BackgroundTransparency = 1,
	Text = "Aus",
	TextColor3 = C.muted,
	Font = Enum.Font.Gotham,
	TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextWrapped = true,
	LayoutOrder = 5,
}, body)

local function setStatus(text, color)
	status.Text = text
	status.TextColor3 = color or C.muted
end

-- Logik
local running = false
local connection

local function setToggleLook()
	if running then
		toggleBtn.Text = "■  AUS"
		toggleBtn.BackgroundColor3 = C.red
	else
		toggleBtn.Text = "▶  AN"
		toggleBtn.BackgroundColor3 = C.green
	end
end

local function stop(message, color)
	running = false
	if connection then
		connection:Disconnect()
		connection = nil
	end
	setToggleLook()
	setStatus(message or "Aus", color)
end

local function start()
	local fn, err = loadstring(codeBox.Text)
	if not fn then
		setStatus("Syntaxfehler: " .. tostring(err), C.err)
		return
	end

	running = true
	setToggleLook()

	local budget = 0
	local totalRuns = 0
	local runsSinceUpdate = 0
	local lastUpdate = os.clock()

	connection = RunService.Heartbeat:Connect(function(dt)
		if not running then return end

		local n = 0
		if rate == 0 then
			-- so schnell wie möglich: einmal pro Frame
			n = 1
			local ok, e = pcall(fn)
			if not ok then
				stop("Fehler: " .. tostring(e), C.err)
				return
			end
		else
			-- rate wird live gelesen, Änderungen wirken sofort
			budget += rate * dt
			while budget >= 1 and n < MAX_PER_FRAME do
				budget -= 1
				n += 1
				local ok, e = pcall(fn)
				if not ok then
					stop("Fehler: " .. tostring(e), C.err)
					return
				end
			end
			if budget > MAX_PER_FRAME then budget = 0 end
		end

		totalRuns += n
		runsSinceUpdate += n

		local now = os.clock()
		if now - lastUpdate >= 0.5 then
			local actual = runsSinceUpdate / (now - lastUpdate)
			setStatus(("An | Ist %.0f/s | Gesamt %d"):format(actual, totalRuns), C.ok)
			lastUpdate = now
			runsSinceUpdate = 0
		end
	end)
end

toggleBtn.Activated:Connect(function()
	if running then
		stop("Aus")
	else
		start()
	end
end)

-- Minimieren / Schließen
local minimized = false
minBtn.Activated:Connect(function()
	minimized = not minimized
	frame.Size = UDim2.fromOffset(width, minimized and BAR_H or FULL_H)
	minBtn.Text = minimized and "+" or "–"
end)

closeBtn.Activated:Connect(function()
	stop()
	gui:Destroy()
end)

-- Verschieben (Maus + Touch)
local dragging, dragStart, startPos
bar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging, dragStart, startPos = true, input.Position, frame.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then dragging = false end
		end)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - dragStart
		local vp = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or viewport
		local x = math.clamp(startPos.X.Offset + d.X, 0, math.max(0, vp.X - width))
		local y = math.clamp(startPos.Y.Offset + d.Y, 0, math.max(0, vp.Y - BAR_H))
		frame.Position = UDim2.fromOffset(x, y)
	end
end)
