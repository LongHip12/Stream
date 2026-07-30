local SERVER = "https://lonelyhubstreaming.onrender.com"
local WS_URL = SERVER:gsub("https://", "wss://"):gsub("http://", "ws://") .. "/ws?role=jpeg-viewer"

local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

local DISPLAY_FPS      = 30
local DISPLAY_INTERVAL = 1 / DISPLAY_FPS
local MAX_QUEUE        = 4
local SLOT_COUNT       = 3

local connected       = false
local hasFirstFrame   = false
local lastDisplayTime = 0
local frameConnection = nil
local writeSlot       = 1
local frameQueue      = {}
local destroyed       = false

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "StreamViewer"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 999
screenGui.Parent = PlayerGui

local mainFrame = Instance.new("Frame")
mainFrame.Name = "Main"
mainFrame.Size = UDim2.new(0, 480, 0, 320)
mainFrame.Position = UDim2.new(0.5, -240, 0.5, -160)
mainFrame.BackgroundColor3 = Color3.fromRGB(13, 13, 13)
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants = true
mainFrame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = mainFrame

local shadow = Instance.new("ImageLabel")
shadow.Name = "Shadow"
shadow.Size = UDim2.new(1, 40, 1, 40)
shadow.Position = UDim2.new(0, -20, 0, -20)
shadow.BackgroundTransparency = 1
shadow.Image = "rbxassetid://5554236805"
shadow.ImageColor3 = Color3.new(0, 0, 0)
shadow.ImageTransparency = 0.5
shadow.ScaleType = Enum.ScaleType.Slice
shadow.SliceCenter = Rect.new(23, 23, 277, 277)
shadow.ZIndex = 0
shadow.Parent = mainFrame

local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 40)
titleBar.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
titleBar.BorderSizePixel = 0
titleBar.ZIndex = 10
titleBar.Parent = mainFrame

local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 10)
titleCorner.Parent = titleBar

local titleBarFix = Instance.new("Frame")
titleBarFix.Size = UDim2.new(1, 0, 0.5, 0)
titleBarFix.Position = UDim2.new(0, 0, 0.5, 0)
titleBarFix.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
titleBarFix.BorderSizePixel = 0
titleBarFix.ZIndex = 10
titleBarFix.Parent = titleBar

local titleDot = Instance.new("Frame")
titleDot.Name = "Dot"
titleDot.Size = UDim2.new(0, 8, 0, 8)
titleDot.Position = UDim2.new(0, 14, 0.5, -4)
titleDot.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
titleDot.BorderSizePixel = 0
titleDot.ZIndex = 11
titleDot.Parent = titleBar
Instance.new("UICorner", titleDot).CornerRadius = UDim.new(1, 0)

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.Size = UDim2.new(1, -80, 1, 0)
titleLabel.Position = UDim2.new(0, 30, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "Stream Viewer"
titleLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
titleLabel.TextSize = 14
titleLabel.Font = Enum.Font.GothamMedium
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.ZIndex = 11
titleLabel.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Name = "Close"
closeBtn.Size = UDim2.new(0, 32, 0, 32)
closeBtn.Position = UDim2.new(1, -38, 0.5, -16)
closeBtn.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.TextSize = 13
closeBtn.Font = Enum.Font.GothamBold
closeBtn.BorderSizePixel = 0
closeBtn.ZIndex = 12
closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

local viewArea = Instance.new("Frame")
viewArea.Name = "ViewArea"
viewArea.Size = UDim2.new(1, -20, 1, -60)
viewArea.Position = UDim2.new(0, 10, 0, 50)
viewArea.BackgroundColor3 = Color3.fromRGB(5, 5, 5)
viewArea.BorderSizePixel = 0
viewArea.ZIndex = 2
viewArea.Parent = mainFrame
Instance.new("UICorner", viewArea).CornerRadius = UDim.new(0, 8)

local streamImageA = Instance.new("ImageLabel")
streamImageA.Name = "StreamImageA"
streamImageA.Size = UDim2.new(1, 0, 1, 0)
streamImageA.BackgroundTransparency = 1
streamImageA.Image = ""
streamImageA.ScaleType = Enum.ScaleType.Fit
streamImageA.ZIndex = 3
streamImageA.Visible = true
streamImageA.Parent = viewArea

local streamImageB = Instance.new("ImageLabel")
streamImageB.Name = "StreamImageB"
streamImageB.Size = UDim2.new(1, 0, 1, 0)
streamImageB.BackgroundTransparency = 1
streamImageB.Image = ""
streamImageB.ScaleType = Enum.ScaleType.Fit
streamImageB.ZIndex = 2
streamImageB.Visible = true
streamImageB.Parent = viewArea

local activeImage   = streamImageA
local inactiveImage = streamImageB

local statusOverlay = Instance.new("Frame")
statusOverlay.Name = "StatusOverlay"
statusOverlay.Size = UDim2.new(1, 0, 1, 0)
statusOverlay.BackgroundColor3 = Color3.fromRGB(5, 5, 5)
statusOverlay.BackgroundTransparency = 0
statusOverlay.BorderSizePixel = 0
statusOverlay.ZIndex = 5
statusOverlay.Parent = viewArea

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "StatusLabel"
statusLabel.Size = UDim2.new(1, -20, 0, 40)
statusLabel.Position = UDim2.new(0, 10, 0.5, -20)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Connecting..."
statusLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
statusLabel.TextSize = 15
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.TextWrapped = true
statusLabel.ZIndex = 6
statusLabel.Parent = statusOverlay

local function setStatus(text, color)
    statusLabel.Text = text
    statusLabel.TextColor3 = color or Color3.fromRGB(150, 150, 150)
end

local function showOverlay(show)
    statusOverlay.Visible = show
end

local function setDot(live)
    titleDot.BackgroundColor3 = live
        and Color3.fromRGB(34, 197, 94)
        or  Color3.fromRGB(60, 60, 60)
end

local dragging = false
local dragStart, startPos

titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging  = true
        dragStart = input.Position
        startPos  = mainFrame.Position
    end
end)

titleBar.InputChanged:Connect(function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local d = input.Position - dragStart
        mainFrame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + d.X,
            startPos.Y.Scale, startPos.Y.Offset + d.Y
        )
    end
end)

game:GetService("UserInputService").InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
end)

local function pushFrame(asset)
    if #frameQueue >= MAX_QUEUE then
        table.remove(frameQueue, 1)
    end
    table.insert(frameQueue, asset)
end

local function onConnected()
    connected     = true
    hasFirstFrame = false
    frameQueue    = {}
    setDot(true)
    showOverlay(true)
    setStatus("Đang tải frame đầu tiên...", Color3.fromRGB(100, 180, 255))
    titleLabel.Text = "Stream Viewer · LIVE"
end

local function onDisconnected()
    connected     = false
    hasFirstFrame = false
    frameQueue    = {}
    setDot(false)
    showOverlay(true)
    setStatus("Streamer ngoại tuyến", Color3.fromRGB(239, 68, 68))
    streamImageA.Image = ""
    streamImageB.Image = ""
    titleLabel.Text = "Stream Viewer"
end

local function processFrame(data)
    local fname = "sv_" .. writeSlot .. ".jpg"
    writeSlot = (writeSlot % SLOT_COUNT) + 1
    local ok = pcall(writefile, fname, data)
    if not ok then return end
    local asset
    pcall(function() asset = getcustomasset(fname) end)
    if not asset or asset == "" then return end
    pushFrame(asset)
    if not hasFirstFrame then
        hasFirstFrame = true
        showOverlay(false)
    end
end

local function displayNextFrame()
    if #frameQueue == 0 then return end
    local asset
    if #frameQueue >= MAX_QUEUE then
        asset      = frameQueue[#frameQueue]
        frameQueue = {}
    else
        asset = table.remove(frameQueue, 1)
    end
    inactiveImage.Image  = asset
    inactiveImage.ZIndex = 3
    activeImage.ZIndex   = 2
    activeImage, inactiveImage = inactiveImage, activeImage
end

local function connectWS()
    if destroyed then return end

    setStatus("Đang kết nối...", Color3.fromRGB(150, 150, 150))

    local ok, ws = pcall(WebSocket.connect, WS_URL)
    if not ok or not ws then
        task.delay(2, connectWS)
        return
    end

    ws.OnMessage:Connect(function(msg)
        if destroyed then return end
        if type(msg) ~= "string" or #msg == 0 then return end

        local b1, b2 = msg:byte(1, 2)
        if b1 == 0xFF and b2 == 0xD8 then
            if connected then processFrame(msg) end
            return
        end

        local parsed, data = pcall(HttpService.JSONDecode, HttpService, msg)
        if not parsed then return end

        if data.type == "status" then
            if data.connected and not connected then
                onConnected()
            elseif not data.connected and connected then
                onDisconnected()
            elseif not data.connected then
                setStatus("Đang chờ streamer...", Color3.fromRGB(150, 150, 150))
                showOverlay(true)
            end
        end
    end)

    ws.OnClose:Connect(function()
        if destroyed then return end
        connected = false
        setStatus("Mất kết nối, thử lại...", Color3.fromRGB(200, 150, 50))
        task.delay(2, connectWS)
    end)
end

closeBtn.MouseButton1Click:Connect(function()
    destroyed = true
    if frameConnection then frameConnection:Disconnect() end
    screenGui:Destroy()
end)

local function mainLoop()
    if destroyed then return end
    local now = tick()
    if connected and now - lastDisplayTime >= DISPLAY_INTERVAL then
        lastDisplayTime = now
        displayNextFrame()
    end
end

showOverlay(true)
setStatus("Đang kết nối tới server...", Color3.fromRGB(150, 150, 150))
setDot(false)

frameConnection = RunService.Heartbeat:Connect(mainLoop)
task.spawn(connectWS)
