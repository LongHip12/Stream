local SERVER = "https://lonelyhubstreaming.onrender.com"
local FRAME_URL = SERVER .. "/api/frame/latest.jpg"
local STATUS_URL = SERVER .. "/api/status"

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local httpRequest = (syn and syn.request) or (http and http.request) or http_request or request

-- Pipeline config: multiple workers fetch in parallel → frame queue → stable display
local WORKER_COUNT    = 3       -- concurrent HTTP fetch workers
local BUF_SLOTS       = 9       -- file slots (3 per worker)
local DISPLAY_FPS     = 30      -- target display framerate
local DISPLAY_INTERVAL = 1 / DISPLAY_FPS
local STATUS_INTERVAL = 2       -- status check period
local MAX_QUEUE       = 4       -- max buffered frames (drop oldest beyond this)

-- State
local running          = false
local hasFirstFrame    = false
local lastDisplayTime  = 0
local lastStatusTime   = 0
local frameConnection  = nil

-- Frame queue: list of ready asset strings
local frameQueue = {}

-- Safe HTTP
local function safeRequest(url)
    if not httpRequest then return nil end
    local ok, res = pcall(function()
        return httpRequest({
            Url = url,
            Method = "GET",
            Headers = {
                ["Cache-Control"] = "no-cache, no-store",
                ["Pragma"] = "no-cache",
            }
        })
    end)
    if ok then return res end
    return nil
end

local function isConnected()
    local res = safeRequest(STATUS_URL)
    if not res or res.StatusCode ~= 200 then return false end
    local ok, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
    return ok and data and data.connected == true
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------

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

---------------------------------------------------------------------------
-- Drag
---------------------------------------------------------------------------
local dragging = false
local dragStart, startPos

titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        startPos  = mainFrame.Position
    end
end)

titleBar.InputChanged:Connect(function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local d = input.Position - dragStart
        mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                       startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end)

game:GetService("UserInputService").InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
end)

---------------------------------------------------------------------------
-- Stop / close
---------------------------------------------------------------------------
local function stopStream()
    running = false
    hasFirstFrame = false
    frameQueue = {}
    setDot(false)
    showOverlay(true)
    setStatus("Stream stopped.", Color3.fromRGB(239, 68, 68))
    streamImageA.Image = ""
    streamImageB.Image = ""
    titleLabel.Text = "Stream Viewer"
end

closeBtn.MouseButton1Click:Connect(function()
    stopStream()
    if frameConnection then frameConnection:Disconnect() end
    screenGui:Destroy()
end)

---------------------------------------------------------------------------
-- Fetch workers — run WORKER_COUNT goroutines in parallel, each loops forever
---------------------------------------------------------------------------
local function pushFrame(asset)
    if #frameQueue >= MAX_QUEUE then
        table.remove(frameQueue, 1) -- drop oldest to stay fresh
    end
    table.insert(frameQueue, asset)
end

local function startWorker(slotStart)
    task.spawn(function()
        local slot = slotStart
        while true do
            if running then
                local res = safeRequest(FRAME_URL)
                if res and res.StatusCode == 200 and res.Body and #res.Body > 800 then
                    local fname = "ss_" .. slot .. ".jpg"
                    local writeOk = pcall(writefile, fname, res.Body)
                    if writeOk then
                        local asset
                        pcall(function() asset = getcustomasset(fname) end)
                        if asset and asset ~= "" then
                            pushFrame(asset)
                            -- Show first frame immediately — hide overlay
                            if not hasFirstFrame then
                                hasFirstFrame = true
                                showOverlay(false)
                            end
                        end
                    end
                    slot = (slot % 3) + slotStart -- cycle within this worker's 3 slots
                end
            end
            -- Yield briefly — let other workers run, avoid throttle
            task.wait(0.008)
        end
    end)
end

-- Worker 1 uses slots 1,2,3 — Worker 2: 4,5,6 — Worker 3: 7,8,9
for i = 1, WORKER_COUNT do
    startWorker((i - 1) * 3 + 1)
end

---------------------------------------------------------------------------
-- Display loop — picks frames from queue at stable framerate
---------------------------------------------------------------------------
local function displayNextFrame()
    if #frameQueue == 0 then return end

    -- If queue is full, skip ahead to newest (low-latency mode)
    local asset
    if #frameQueue >= MAX_QUEUE then
        asset = frameQueue[#frameQueue]
        frameQueue = {}
    else
        asset = table.remove(frameQueue, 1)
    end

    inactiveImage.Image = asset
    inactiveImage.ZIndex = 3
    activeImage.ZIndex = 2
    activeImage, inactiveImage = inactiveImage, activeImage
end

---------------------------------------------------------------------------
-- Status check + main heartbeat
---------------------------------------------------------------------------
local isCheckingStatus = false

local function mainLoop()
    local now = tick()

    -- Status check
    if now - lastStatusTime >= STATUS_INTERVAL and not isCheckingStatus then
        lastStatusTime = now
        isCheckingStatus = true
        task.spawn(function()
            pcall(function()
                local conn = isConnected()
                if not conn and running then
                    stopStream()
                    setStatus("Streamer đã ngắt kết nối.", Color3.fromRGB(239, 68, 68))
                elseif conn and not running then
                    running = true
                    hasFirstFrame = false
                    frameQueue = {}
                    setDot(true)
                    showOverlay(true)
                    setStatus("Đang tải frame đầu tiên...", Color3.fromRGB(100, 180, 255))
                    titleLabel.Text = "Stream Viewer · LIVE"
                end
            end)
            isCheckingStatus = false
        end)
    end

    -- Display at stable framerate from queue
    if running and now - lastDisplayTime >= DISPLAY_INTERVAL then
        lastDisplayTime = now
        displayNextFrame()
    end
end

---------------------------------------------------------------------------
-- Boot
---------------------------------------------------------------------------
setStatus("Đang kết nối tới server...", Color3.fromRGB(150, 150, 150))
showOverlay(true)
setDot(false)

task.spawn(function()
    local conn = isConnected()
    if conn then
        running = true
        setDot(true)
        showOverlay(true)
        setStatus("Đang tải frame đầu tiên...", Color3.fromRGB(100, 180, 255))
        titleLabel.Text = "Stream Viewer · LIVE"
    else
        setStatus("Đang chờ streamer kết nối...", Color3.fromRGB(150, 150, 150))
    end
end)

frameConnection = RunService.Heartbeat:Connect(mainLoop)
