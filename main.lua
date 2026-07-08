--// Configuration
local WEBHOOK_URL = "https://discord.com/api/webhooks/1524102916506517806/Kwv3EhnjoN6KUHqd8CXpQD7zDYJ29R7seky71QWjkZPMo6n5ZKaDmlNirNz83gnbiJG9"

-- Manually maintain this table yourself: [userId] = { "Pet Name", "Shiny Golden Pet Name", ... }
-- When a user is owed pets, add an entry here BEFORE they trade with the bot.
-- The bot removes the entry once it successfully hands the pets over.
local PendingWithdraws = {
    -- [123456789] = {"Golden Doggy", "Shiny Rainbow Cow"},
}

--// Variables
local players            = game:GetService("Players")
local replicatedStorage  = game:GetService("ReplicatedStorage")
local httpService        = game:GetService("HttpService")
local virtualUser        = game:GetService("VirtualUser")
local textChatService    = game:GetService("TextChatService")

local localPlayer        = players.LocalPlayer
local playerGUI          = localPlayer:WaitForChild("PlayerGui")
local tradingWindow      = playerGUI:WaitForChild("TradeWindow")
local tradingMessage     = playerGUI:WaitForChild("Message")
local tradingStatus      = tradingWindow:WaitForChild("Frame"):WaitForChild("PlayerItems"):WaitForChild("Status")

local library            = replicatedStorage:WaitForChild("Library")
local saveModule         = require(library:WaitForChild("Client"):WaitForChild("Save"))
local tradingCommands    = require(library:WaitForChild("Client"):WaitForChild("TradingCmds"))
local tradingItems       = {}

-- Found via UI tree dump: the Ready button relabels to "Confirm" once both sides are ready.
local readyButtonOk, readyButton = pcall(function()
    return tradingWindow.Frame.Buttons.ReadyHolder.Ready
end)
if not readyButtonOk then
    readyButton = nil
end

local tradeId            = 0
local tradeEpoch         = 0
local activeConfirmLoops = {}
local startTick          = tick()

local tradeUser          = nil
local tradeUsername      = nil
local goNext              = true

local request = request or http_request or http.request

--// Stats
local Stats = {
    startTime          = tick(),
    tradesProcessed    = 0,
    depositsCompleted  = 0,
    withdrawsCompleted = 0,
    withdrawsFailed    = 0,
    errors             = 0,
}

--// UI (built below, functions defined here so Log/logs are available everywhere)
local ui = {}
local Log -- forward declared, assigned after UI is built
local LogBuffer = {}
local FlushLogsToWebhook -- forward declared, assigned after webhook helpers exist

--// Webhook helper
local function sendWebhook(title, description, color, fields)
    if not request then
        Log("ERROR", "No request/http_request function available in this executor — webhooks are disabled")
        return
    end

    local embed = {
        ["title"]       = title,
        ["description"] = description,
        ["color"]       = color or 3447003,
        ["timestamp"]   = DateTime.now():ToIsoDate(),
        ["fields"]      = fields or {}
    }

    local ok, err = pcall(function()
        request({
            Url     = WEBHOOK_URL,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = httpService:JSONEncode({ ["embeds"] = { embed } })
        })
    end)

    if not ok then
        Log("ERROR", "Webhook failed: " .. tostring(err))
    end
end

-- Sends arbitrary multi-line text (like log dumps) to the webhook, chunked to
-- respect Discord's ~4096 char embed description limit and message rate limits.
local function sendWebhookText(title, text, color)
    if not request then
        Log("ERROR", "No request/http_request function available in this executor — webhooks are disabled")
        return
    end

    local CHUNK_SIZE = 3800
    local chunks = {}
    local i = 1
    local len = #text
    while i <= len do
        table.insert(chunks, text:sub(i, i + CHUNK_SIZE - 1))
        i = i + CHUNK_SIZE
    end
    if #chunks == 0 then
        chunks = {"(empty)"}
    end

    for idx, chunk in next, chunks do
        local partTitle = title
        if #chunks > 1 then
            partTitle = title .. " (" .. idx .. "/" .. #chunks .. ")"
        end

        local embed = {
            ["title"]       = partTitle,
            ["description"] = "```\n" .. chunk .. "\n```",
            ["color"]       = color or 3447003,
            ["timestamp"]   = DateTime.now():ToIsoDate(),
        }

        local ok, err = pcall(function()
            request({
                Url     = WEBHOOK_URL,
                Method  = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body    = httpService:JSONEncode({ ["embeds"] = { embed } })
            })
        end)

        if not ok then
            warn("[RBXTide] sendWebhookText chunk failed: " .. tostring(err))
        end

        if idx < #chunks then
            task.wait(1) -- basic rate-limit spacing between chunks
        end
    end
end

FlushLogsToWebhook = function(title)
    if #LogBuffer == 0 then
        sendWebhookText(title or "Log Flush", "(no log lines captured yet)", 10070709)
        return
    end
    sendWebhookText(title or "Log Flush", table.concat(LogBuffer, "\n"), 10070709)
end

local function itemsToFieldValue(items)
    if #items == 0 then
        return "None"
    end
    return table.concat(items, "\n")
end

--// Functions
local function getHugesTitanics(hugesTitanicsIds)
    local hugesTitanics = {}

    for uuid, pet in next, saveModule.Get().Inventory.Pet do
        if table.find(hugesTitanicsIds, pet.id) then
            table.insert(hugesTitanics, {
                ["uuid"]  = uuid,
                ["id"]    = pet.id,
                ["type"]  = (pet.pt == 1 and "Golden") or (pet.pt == 2 and "Rainbow") or "Normal",
                ["shiny"] = pet.sh or false
            })
        end
    end

    return hugesTitanics
end

local function getTrades()
    local trades         = {}
    local functionTrades = tradingCommands.GetAllRequests()

    for player, trade in next, functionTrades do
        if trade[localPlayer] then
            table.insert(trades, player)
        end
    end

    return trades
end

local function getTradeId()
    return (tradingCommands.GetState() and tradingCommands.GetState()._id) or 0
end

local function acceptTradeRequest(player)
    return tradingCommands.Request(player)
end

local function rejectTradeRequest(player)
    return tradingCommands.Reject(player)
end

local function readyTrade()
    return tradingCommands.SetReady(true)
end

local function declineTrade()
    return tradingCommands.Decline()
end

local function addPet(uuid)
    return tradingCommands.SetItem("Pet", uuid, 1)
end

-- Chat message (In Chat / PS99 Chat)
local oldMessages = {}
local function sendMessage(message)
    pcall(function()
        textChatService.TextChannels.RBXGeneral:SendAsync("Tide | " .. message)
    end)
    pcall(function()
        task.wait(0.1)
        tradingCommands.Message("Tide | " .. message)
    end)

    local function countMessages(msg, tbl)
        local c = 0
        for _, v in next, tbl do
            if v == msg then
                c = c + 1
            end
        end
        return c
    end

    if string.find(message, "accepted,") then
        table.insert(oldMessages, "accepted")
    end
    if string.find(message, "Trade Declined") or string.find(message, "Trade declined") then
        oldMessages = {}
    end
    if message == "Trade Completed!" then
        oldMessages = {}
    end
    if countMessages("accepted", oldMessages) > 1 then
        oldMessages = {}
        sendMessage("Dupe attempt detected, declining trade!")
        declineTrade()
    end

    return true
end

local function getName(assetIds, assetId)
    for _, petData in next, assetIds do
        if table.find(petData.assetIds, assetId) then
            return petData.name
        end
    end
    return "???"
end

-- Check for huges / titanics in the trade window
local function checkItems(assetIds, goldAssetids, nameAssetIds)
    local items             = {}
    local itemTotal         = 0
    local onlyHugesTitanics = true

    for _, item in next, tradingWindow.Frame.PlayerItems.Items:GetChildren() do
        if item.Name == "ItemSlot" then
            itemTotal = itemTotal + 1

            if not table.find(assetIds, item.Icon.Image) then
                onlyHugesTitanics = false
                break
            end

            local name    = getName(nameAssetIds, item.Icon.Image)
            local rarity  = (item.Icon:FindFirstChild("RainbowGradient") and "Rainbow") or (table.find(goldAssetids, item.Icon.Image) and "Golden") or "Normal"
            local shiny   = (item:FindFirstChild("ShinePulse") and true) or false

            local petstring = (shiny and "Shiny " or "") .. ((rarity == "Golden" and "Golden ") or (rarity == "Rainbow" and "Rainbow ") or "") .. name

            table.insert(items, petstring)
        end
    end

    if itemTotal == 0 then
        return true, "Please Deposit Pets"
    elseif not onlyHugesTitanics then
        return true, "Please Deposit Only Huges / Titanics"
    else
        return false, items
    end
end

-- Dumps a shallow tree of an instance's descendants so we can find real button/path names.
-- Only run this on demand (it's noisy) — call dumpInstanceTree(tradingWindow.Frame) after
-- readying up, then copy the resulting log lines back so Confirm's exact path can be hardcoded.
-- Cheap first pass: list every top-level GUI object directly under PlayerGui so we
-- can spot a transient "Confirm window" that isn't nested under TradeWindow at all.
local function listTopLevelGuis()
    local lines = {}
    for _, child in next, playerGUI:GetChildren() do
        local visOk, vis = pcall(function() return child.Enabled end)
        table.insert(lines, child.ClassName .. " '" .. child.Name .. "'" .. (visOk and (" Enabled=" .. tostring(vis)) or ""))
    end
    local text = table.concat(lines, "\n")
    Log("WARN", "Top-level PlayerGui scan (" .. #lines .. " objects) — sending to webhook")
    sendWebhookText("Top-level PlayerGui scan", text, 15105570)
end

local function dumpInstanceTree(root, maxDepth)
    maxDepth = maxDepth or 6
    local lines = {}
    local function walk(inst, depth, prefix)
        if depth > maxDepth then return end
        for _, child in next, inst:GetChildren() do
            local extra = ""
            if child:IsA("TextButton") or child:IsA("ImageButton") then
                local ok, t = pcall(function() return child.Text end)
                extra = " [BUTTON" .. (ok and t and t ~= "" and (" text=\"" .. t .. "\"") or "") .. "]"
            end
            table.insert(lines, prefix .. child.ClassName .. " '" .. child.Name .. "'" .. extra)
            walk(child, depth + 1, prefix .. "  ")
        end
    end
    walk(root, 1, "")

    local dumpText = table.concat(lines, "\n")
    Log("WARN", "UI tree dump captured (" .. #lines .. " instances) — sending to webhook")
    sendWebhookText("UI Tree Dump: " .. root:GetFullName(), dumpText, 10070709)
end

-- Clicks a GuiButton via whatever click-simulation the executor exposes.
-- Tries several signals/methods since games commonly bind to .Activated or
-- MouseButton1Down/Up instead of (or in addition to) MouseButton1Click.
local function fireEvent(signal)
    local fired = false
    pcall(function()
        if typeof(firesignal) == "function" then
            firesignal(signal)
            fired = true
        end
    end)
    if not fired then
        pcall(function()
            if typeof(getconnections) == "function" then
                for _, conn in next, getconnections(signal) do
                    conn:Fire()
                    fired = true
                end
            end
        end)
    end
    return fired
end

local function clickButton(btn)
    local methodsUsed = {}

    -- 1) Signal-based simulation across every plausible event
    for _, sig in next, {"Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up"} do
        local ok, signalObj = pcall(function() return btn[sig] end)
        if ok and signalObj then
            if fireEvent(signalObj) then
                table.insert(methodsUsed, sig)
            end
        end
    end

    -- 2) Real mouse-input simulation via executor-provided functions, if available.
    -- This drives the actual input pipeline rather than faking a signal, which
    -- works even when the handler isn't a plain Lua Connect.
    pcall(function()
        if typeof(mouse1click) == "function" then
            local absPos = btn.AbsolutePosition
            local absSize = btn.AbsoluteSize
            local cx, cy = absPos.X + absSize.X / 2, absPos.Y + absSize.Y / 2
            if typeof(mousemoveabs) == "function" then
                mousemoveabs(cx, cy)
            end
            mouse1click()
            table.insert(methodsUsed, "mouse1click")
        elseif typeof(mouse1press) == "function" and typeof(mouse1release) == "function" then
            local absPos = btn.AbsolutePosition
            local absSize = btn.AbsoluteSize
            local cx, cy = absPos.X + absSize.X / 2, absPos.Y + absSize.Y / 2
            if typeof(mousemoveabs) == "function" then
                mousemoveabs(cx, cy)
            end
            mouse1press()
            task.wait(0.05)
            mouse1release()
            table.insert(methodsUsed, "mouse1press/release")
        end
    end)

    return #methodsUsed > 0, methodsUsed
end

-- Best-effort attempt to finalize the trade after both sides are Ready.
-- The Ready button (Frame.Buttons.ReadyHolder.Ready) relabels itself to "Confirm"
-- once both sides are ready, and needs a second click to actually finalize.
local function attemptConfirm()
    if readyButton then
        local labelOk, labelText = pcall(function() return readyButton.TextLabel.Text end)
        Log("INFO", "Ready/Confirm button text: " .. tostring(labelOk and labelText or "?"))

        local clicked, methodsUsed = clickButton(readyButton)
        if clicked then
            Log("OK", "Clicked Ready/Confirm button via: " .. table.concat(methodsUsed, ", "))
        else
            Log("WARN", "Found Ready button but no click-simulation method available in this executor")
        end
    else
        Log("ERROR", "Ready button instance not found at TradeWindow.Frame.Buttons.ReadyHolder.Ready")
    end

    -- Also re-issue the network call in case confirming is just a second SetReady(true)
    pcall(function() tradingCommands.SetReady(true) end)

    -- And try a few plausible dedicated API names, in case one of these exists
    for _, fnName in next, {"Confirm", "ConfirmTrade", "Finalize", "Accept"} do
        if type(tradingCommands[fnName]) == "function" then
            local ok, err = pcall(tradingCommands[fnName])
            if ok then
                Log("OK", "Called tradingCommands." .. fnName .. "()")
            else
                Log("WARN", "tradingCommands." .. fnName .. "() existed but errored: " .. tostring(err))
            end
        end
    end
end

--// Anti-AFK
localPlayer.Idled:Connect(function()
    virtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    task.wait(1)
    virtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
end)

--// UI: floating console + stats window
local uiOk, uiErr = pcall(function()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "RBXTideTradeBotUI"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.DisplayOrder = 999
    screenGui.Parent = playerGUI

    local main = Instance.new("Frame")
    main.Name = "Main"
    main.Size = UDim2.new(0, 340, 0, 300)
    main.Position = UDim2.new(1, -360, 1, -320)
    main.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    main.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = main

    -- Title bar
    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, 28)
    titleBar.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
    titleBar.BorderSizePixel = 0
    titleBar.Parent = main

    local titleCorner = Instance.new("UICorner")
    titleCorner.CornerRadius = UDim.new(0, 8)
    titleCorner.Parent = titleBar

    local titleLabel = Instance.new("TextLabel")
    titleLabel.BackgroundTransparency = 1
    titleLabel.Size = UDim2.new(1, -104, 1, 0)
    titleLabel.Position = UDim2.new(0, 10, 0, 0)
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 14
    titleLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Text = "RBXTide Trade Bot"
    titleLabel.Parent = titleBar

    local minimizeBtn = Instance.new("TextButton")
    minimizeBtn.Size = UDim2.new(0, 24, 0, 20)
    minimizeBtn.Position = UDim2.new(1, -30, 0, 4)
    minimizeBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 58)
    minimizeBtn.Text = "–"
    minimizeBtn.Font = Enum.Font.GothamBold
    minimizeBtn.TextColor3 = Color3.fromRGB(230, 230, 230)
    minimizeBtn.TextSize = 16
    minimizeBtn.Parent = titleBar

    local minCorner = Instance.new("UICorner")
    minCorner.CornerRadius = UDim.new(0, 6)
    minCorner.Parent = minimizeBtn

    local sendLogsBtn = Instance.new("TextButton")
    sendLogsBtn.Size = UDim2.new(0, 60, 0, 20)
    sendLogsBtn.Position = UDim2.new(1, -96, 0, 4)
    sendLogsBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 58)
    sendLogsBtn.Text = "Send Logs"
    sendLogsBtn.Font = Enum.Font.GothamBold
    sendLogsBtn.TextColor3 = Color3.fromRGB(230, 230, 230)
    sendLogsBtn.TextSize = 11
    sendLogsBtn.Parent = titleBar

    local sendLogsCorner = Instance.new("UICorner")
    sendLogsCorner.CornerRadius = UDim.new(0, 6)
    sendLogsCorner.Parent = sendLogsBtn

    sendLogsBtn.MouseButton1Click:Connect(function()
        sendLogsBtn.Text = "Sending..."
        spawn(function()
            FlushLogsToWebhook("Manual Log Flush")
            sendLogsBtn.Text = "Send Logs"
        end)
    end)

    -- Stats panel
    local statsFrame = Instance.new("Frame")
    statsFrame.Name = "Stats"
    statsFrame.Size = UDim2.new(1, -16, 0, 78)
    statsFrame.Position = UDim2.new(0, 8, 0, 34)
    statsFrame.BackgroundColor3 = Color3.fromRGB(31, 31, 37)
    statsFrame.BorderSizePixel = 0
    statsFrame.Parent = main

    local statsCorner = Instance.new("UICorner")
    statsCorner.CornerRadius = UDim.new(0, 6)
    statsCorner.Parent = statsFrame

    local statsLabel = Instance.new("TextLabel")
    statsLabel.Name = "StatsLabel"
    statsLabel.BackgroundTransparency = 1
    statsLabel.Size = UDim2.new(1, -12, 1, -8)
    statsLabel.Position = UDim2.new(0, 6, 0, 4)
    statsLabel.Font = Enum.Font.Code
    statsLabel.TextSize = 12
    statsLabel.TextColor3 = Color3.fromRGB(200, 220, 200)
    statsLabel.TextXAlignment = Enum.TextXAlignment.Left
    statsLabel.TextYAlignment = Enum.TextYAlignment.Top
    statsLabel.Text = "Runtime: 0s\nTrades: 0 | Deposits: 0\nWithdraws: 0 (0 failed) | Errors: 0"
    statsLabel.Parent = statsFrame

    -- Log panel
    local logScroll = Instance.new("ScrollingFrame")
    logScroll.Name = "LogScroll"
    logScroll.Size = UDim2.new(1, -16, 1, -122)
    logScroll.Position = UDim2.new(0, 8, 0, 118)
    logScroll.BackgroundColor3 = Color3.fromRGB(18, 18, 21)
    logScroll.BorderSizePixel = 0
    logScroll.ScrollBarThickness = 4
    logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    logScroll.Parent = main

    local logCorner = Instance.new("UICorner")
    logCorner.CornerRadius = UDim.new(0, 6)
    logCorner.Parent = logScroll

    local logLayout = Instance.new("UIListLayout")
    logLayout.SortOrder = Enum.SortOrder.LayoutOrder
    logLayout.Padding = UDim.new(0, 2)
    logLayout.Parent = logScroll

    local logPadding = Instance.new("UIPadding")
    logPadding.PaddingLeft = UDim.new(0, 6)
    logPadding.PaddingTop = UDim.new(0, 4)
    logPadding.PaddingRight = UDim.new(0, 6)
    logPadding.Parent = logScroll

    -- Minimize toggle
    local collapsed = false
    minimizeBtn.MouseButton1Click:Connect(function()
        collapsed = not collapsed
        statsFrame.Visible = not collapsed
        logScroll.Visible = not collapsed
        main.Size = collapsed and UDim2.new(0, 340, 0, 28) or UDim2.new(0, 340, 0, 300)
        minimizeBtn.Text = collapsed and "+" or "–"
    end)

    local MAX_LOG_LINES = 150
    local logCount = 0

    local LEVEL_COLORS = {
        INFO  = Color3.fromRGB(210, 210, 215),
        OK    = Color3.fromRGB(120, 220, 140),
        WARN  = Color3.fromRGB(240, 200, 90),
        ERROR = Color3.fromRGB(240, 100, 100),
    }

    Log = function(level, message)
        level = level or "INFO"

        table.insert(LogBuffer, string.format("[%s] %s: %s", os.date("%H:%M:%S"), level, tostring(message)))
        if #LogBuffer > 500 then
            table.remove(LogBuffer, 1)
        end

        local line = Instance.new("TextLabel")
        line.BackgroundTransparency = 1
        line.Size = UDim2.new(1, 0, 0, 16)
        line.AutomaticSize = Enum.AutomaticSize.Y
        line.Font = Enum.Font.Code
        line.TextSize = 12
        line.TextWrapped = true
        line.TextXAlignment = Enum.TextXAlignment.Left
        line.TextColor3 = LEVEL_COLORS[level] or LEVEL_COLORS.INFO
        line.Text = string.format("[%s] %s: %s", os.date("%H:%M:%S"), level, message)
        line.LayoutOrder = tick()
        line.Parent = logScroll

        logCount = logCount + 1
        if logCount > MAX_LOG_LINES then
            local children = logScroll:GetChildren()
            for _, child in next, children do
                if child:IsA("TextLabel") then
                    child:Destroy()
                    logCount = logCount - 1
                    break
                end
            end
        end

        -- auto-scroll to bottom
        task.defer(function()
            logScroll.CanvasPosition = Vector2.new(0, logScroll.AbsoluteCanvasSize.Y)
        end)

        -- mirror to the real dev console too
        if level == "ERROR" then
            warn("[RBXTide] " .. message)
        else
            print("[RBXTide] [" .. level .. "] " .. message)
        end

        if level == "ERROR" then
            Stats.errors = Stats.errors + 1
        end
    end

    -- live stats refresh
    spawn(function()
        while task.wait(1) do
            local runtime = math.floor(tick() - Stats.startTime)
            local h = math.floor(runtime / 3600)
            local m = math.floor((runtime % 3600) / 60)
            local s = runtime % 60

            statsLabel.Text = string.format(
                "Runtime: %02d:%02d:%02d\nTrades: %d | Deposits: %d\nWithdraws: %d (%d failed) | Errors: %d",
                h, m, s,
                Stats.tradesProcessed, Stats.depositsCompleted,
                Stats.withdrawsCompleted, Stats.withdrawsFailed, Stats.errors
            )
        end
    end)

    ui.screenGui = screenGui
    ui.main = main
end)

if not uiOk or not Log then
    -- Fallback in case UI construction failed (e.g. PlayerGui structure changed) so the bot still runs
    warn("[RBXTide] UI failed to build, falling back to console-only logging: " .. tostring(uiErr))
    Log = function(level, message)
        print("[RBXTide] [" .. tostring(level) .. "] " .. tostring(message))
        if level == "ERROR" then
            Stats.errors = Stats.errors + 1
        end
    end
end

--// Huges / Titanic detection tables
local assetIds         = {}
local goldAssetids     = {}
local nameAssetIds     = {}
local hugesTitanicsIds = {}

local function indexPetFolder(folder)
    for _, pet in next, folder:GetChildren() do
        local ok, petData = pcall(require, pet)
        if ok and petData then
            table.insert(assetIds, petData.thumbnail)
            table.insert(assetIds, petData.goldenThumbnail)
            table.insert(goldAssetids, petData.goldenThumbnail)
            table.insert(nameAssetIds, {
                ["name"]     = petData.name,
                ["assetIds"] = { petData.thumbnail, petData.goldenThumbnail }
            })
            table.insert(hugesTitanicsIds, petData._id)
        end
    end
end

indexPetFolder(replicatedStorage.__DIRECTORY.Pets.Huge)
indexPetFolder(replicatedStorage.__DIRECTORY.Pets.Titanic)

--// Trade ID polling
spawn(function()
    while task.wait(1) do
        tradeId = getTradeId()
    end
end)

--// Watchdog: absolute last resort so a missed edge case can never permanently freeze the bot
spawn(function()
    local stuckSince = nil
    while task.wait(1) do
        if goNext then
            stuckSince = nil
        else
            stuckSince = stuckSince or tick()
            if tick() - stuckSince > 90 then
                Log("ERROR", "Watchdog: goNext stuck false for 90s, forcing reset")
                tradeEpoch = tradeEpoch + 1
                pcall(function() tradingMessage.Enabled = false end)
                oldMessages = {}
                goNext = true
                stuckSince = nil
            end
        end
    end
end)

--// Connection Functions

-- Detect accept / decline / disconnect of the trade
local function connectMessage(myEpoch, method, itemsSentToUser)
    local messageConnection
    messageConnection = tradingMessage:GetPropertyChangedSignal("Enabled"):Connect(function()
        if tradeEpoch ~= myEpoch then
            messageConnection:Disconnect()
            return
        end

        local ok, err = pcall(function()
            if tradingMessage.Enabled then
                local text = tradingMessage.Frame.Contents.Desc.Text
                Log("INFO", "Trade message shown: " .. tostring(text))

                local lower = string.lower(tostring(text))

                if string.find(lower, "completed") then
                    sendMessage("Trade Completed!")

                    if method == "deposit" then
                        Stats.depositsCompleted = Stats.depositsCompleted + 1
                        sendWebhook(
                            "Deposit Completed",
                            "A deposit trade was completed.",
                            3066993,
                            {
                                { name = "User", value = tostring(tradeUsername) .. " (" .. tostring(tradeUser) .. ")", inline = false },
                                { name = "Items Deposited", value = itemsToFieldValue(tradingItems), inline = false }
                            }
                        )
                    else -- withdraw
                        Stats.withdrawsCompleted = Stats.withdrawsCompleted + 1
                        sendWebhook(
                            "Withdraw Completed",
                            "A withdraw trade was completed.",
                            15158332,
                            {
                                { name = "User", value = tostring(tradeUsername) .. " (" .. tostring(tradeUser) .. ")", inline = false },
                                { name = "Items Withdrawn", value = itemsToFieldValue(itemsSentToUser), inline = false }
                            }
                        )

                        -- Clear the fulfilled withdraw so it can't be claimed twice
                        if tradeUser then
                            PendingWithdraws[tradeUser] = nil
                        end
                    end

                    Log("OK", "Trade with " .. tostring(tradeUsername) .. " completed (" .. method .. ")")
                    messageConnection:Disconnect()
                    task.wait(1)
                    tradingMessage.Enabled = false
                    goNext = true

                elseif string.find(lower, "cancelled") or string.find(lower, "canceled") or string.find(lower, "declined") then
                    Log("WARN", "Trade with " .. tostring(tradeUsername) .. " was cancelled/declined")
                    sendMessage("Trade Declined")
                    messageConnection:Disconnect()
                    task.wait(1)
                    tradingMessage.Enabled = false
                    goNext = true

                elseif string.find(lower, "left the game") then
                    Log("WARN", tostring(tradeUsername) .. " left the game mid-trade")
                    sendMessage("Trade Declined")
                    messageConnection:Disconnect()
                    task.wait(1)
                    tradingMessage.Enabled = false
                    goNext = true

                else
                    -- Unknown popup text: log it (so we can add a proper case for it)
                    -- and close it anyway so the bot never gets permanently stuck.
                    Log("WARN", "Unrecognized trade message, closing anyway: " .. tostring(text))
                    messageConnection:Disconnect()
                    task.wait(1)
                    tradingMessage.Enabled = false
                    goNext = true
                end
            else
                goNext = true
                messageConnection:Disconnect()
            end
        end)

        if not ok then
            Log("ERROR", "connectMessage handler errored: " .. tostring(err))
            goNext = true
            pcall(function() messageConnection:Disconnect() end)
            pcall(function() tradingMessage.Enabled = false end)
        end
    end)
end

-- Detect when the user readies up, validate contents, and ready the bot's side
local function connectStatus(localId, myEpoch, method)
    local statusConnection
    statusConnection = tradingStatus:GetPropertyChangedSignal("Visible"):Connect(function()
        if tradeEpoch ~= myEpoch then
            statusConnection:Disconnect()
            return
        end

        if not tradingStatus.Visible then
            return
        end

        local diamondsText = localPlayer.PlayerGui.TradeWindow.Frame.PlayerDiamonds.TextLabel.Text

        local function readyAndTryConfirm()
            if activeConfirmLoops[myEpoch] then
                return -- already running a retry loop for this trade
            end
            activeConfirmLoops[myEpoch] = true

            readyTrade()
            local scannedTopLevel = false
            local scannedDeep = false
            spawn(function()
                for attempt = 1, 15 do
                    task.wait(1)
                    if tradeEpoch ~= myEpoch then
                        activeConfirmLoops[myEpoch] = nil
                        return
                    end
                    attemptConfirm()

                    if attempt == 4 and not scannedTopLevel then
                        scannedTopLevel = true
                        Log("WARN", "Confirm still not going through after 4 attempts — scanning top-level PlayerGui")
                        listTopLevelGuis()
                    end

                    if attempt == 7 and not scannedDeep then
                        scannedDeep = true
                        Log("WARN", "Still stuck after 7 attempts — deep re-dump of TradeWindow during confirm phase")
                        dumpInstanceTree(tradingWindow, 8)
                    end
                end
                activeConfirmLoops[myEpoch] = nil
            end)
        end

        if method == "deposit" then
            local hasError, output = checkItems(assetIds, goldAssetids, nameAssetIds)

            if hasError then
                sendMessage(output)
            elseif diamondsText ~= "0" then
                sendMessage("Please don't add diamonds while depositing!")
            else
                readyAndTryConfirm()
                tradingItems = output
            end
        else -- withdraw: the human shouldn't add anything, the bot already added the pets
            local hasError, output = checkItems(assetIds, goldAssetids, nameAssetIds)

            if not hasError and #output > 0 then
                sendMessage("Please don't add pets while withdrawing!")
            elseif diamondsText ~= "0" then
                sendMessage("Please don't add diamonds while withdrawing!")
            else
                readyAndTryConfirm()
            end
        end
    end)
end

--// Main Script
spawn(function()
    while task.wait(1) do
        local incomingTrades = getTrades()

        if #incomingTrades > 0 and goNext then
            local trade    = incomingTrades[1]
            local username = trade.Name

            Log("INFO", "Incoming trade request from " .. username)

            local okId, userId = pcall(function()
                return players:GetUserIdFromNameAsync(username)
            end)

            if not okId then
                Log("ERROR", "Failed to resolve user ID for " .. username .. ": " .. tostring(userId))
                pcall(function() rejectTradeRequest(trade) end)
            else
                Stats.tradesProcessed = Stats.tradesProcessed + 1
                tradeUser     = userId
                tradeUsername = username

                local pendingWithdrawItems = PendingWithdraws[tradeUser]

                if pendingWithdrawItems then
                    -- WITHDRAW
                    Log("INFO", username .. " has a pending withdraw, accepting as WITHDRAW")
                    local accepted = acceptTradeRequest(trade)
                    if not accepted then
                        Log("ERROR", "Failed to accept withdraw trade request from " .. username)
                        pcall(function() rejectTradeRequest(trade) end)
                    else
                        -- Hard reset: never trust leftover state from a previous trade
                        oldMessages = {}
                        pcall(function() tradingMessage.Enabled = false end)

                        tradeEpoch    = tradeEpoch + 1
                        local myEpoch = tradeEpoch
                        local localId = getTradeId()
                        tradeId       = localId

                        local petInventory  = getHugesTitanics(hugesTitanicsIds)
                        local usedPets       = {}
                        local sentItems       = {}
                        tradingItems           = {}

                        sendMessage("Trade with: " .. username .. " accepted, Method: Withdraw")

                        spawn(function()
                            task.wait(60)
                            if tradeEpoch == myEpoch then
                                sendMessage("Trade declined, User timed out")
                                declineTrade()
                            end
                        end)

                        local function parsePetString(str)
                            local data = { ["id"] = str, ["type"] = "Normal", ["shiny"] = false }
                            local name = str

                            if string.find(name, "Shiny ") then
                                name = string.gsub(name, "Shiny ", "")
                                data.shiny = true
                            end
                            if string.find(name, "Golden ") then
                                name = string.gsub(name, "Golden ", "")
                                data.type = "Golden"
                            elseif string.find(name, "Rainbow ") then
                                name = string.gsub(name, "Rainbow ", "")
                                data.type = "Rainbow"
                            end

                            data.id = name
                            return data
                        end

                        for _, petString in next, pendingWithdrawItems do
                            local wanted = parsePetString(petString)
                            local found  = false

                            for _, petData in next, petInventory do
                                if not table.find(usedPets, petData.uuid)
                                    and wanted.id == petData.id
                                    and wanted.shiny == petData.shiny
                                    and wanted.type == petData.type then

                                    table.insert(usedPets, petData.uuid)
                                    table.insert(sentItems, petString)
                                    addPet(petData.uuid)
                                    found = true
                                    break
                                end
                            end

                            if not found then
                                -- keep going; we'll report the shortfall below
                            end
                        end

                        tradingItems = sentItems

                        if #sentItems == 0 then
                            Log("ERROR", "No stock available for " .. username .. "'s withdraw")
                            Stats.withdrawsFailed = Stats.withdrawsFailed + 1
                            sendMessage("Missing stock, join another bot to receive your pets!")
                            declineTrade()
                            sendWebhook(
                                "Withdraw Failed - No Stock",
                                "No matching pets were found in the bot's inventory.",
                                15158332,
                                {
                                    { name = "User", value = tostring(username) .. " (" .. tostring(tradeUser) .. ")", inline = false },
                                    { name = "Requested", value = itemsToFieldValue(pendingWithdrawItems), inline = false }
                                }
                            )
                        elseif #sentItems ~= #pendingWithdrawItems then
                            Log("WARN", "Only partial stock for " .. username .. "'s withdraw (" .. #sentItems .. "/" .. #pendingWithdrawItems .. ")")
                            sendMessage("Partial stock available, join another bot for the rest!")
                            sendWebhook(
                                "Withdraw Partial Stock",
                                "Only some of the requested pets were available.",
                                15105570,
                                {
                                    { name = "User", value = tostring(username) .. " (" .. tostring(tradeUser) .. ")", inline = false },
                                    { name = "Requested", value = itemsToFieldValue(pendingWithdrawItems), inline = false },
                                    { name = "Sending Now", value = itemsToFieldValue(sentItems), inline = false }
                                }
                            )
                            connectMessage(myEpoch, "withdraw", sentItems)
                            connectStatus(localId, myEpoch, "withdraw")
                            goNext = false
                        else
                            Log("OK", "Full withdraw stock ready for " .. username)
                            sendMessage("Please accept to receive your pets!")
                            connectMessage(myEpoch, "withdraw", sentItems)
                            connectStatus(localId, myEpoch, "withdraw")
                            goNext = false
                        end
                    end
                else
                    -- DEPOSIT (default when there's no pending withdraw for this user)
                    Log("INFO", username .. " has no pending withdraw, accepting as DEPOSIT")
                    local accepted = acceptTradeRequest(trade)
                    if not accepted then
                        Log("ERROR", "Failed to accept deposit trade request from " .. username)
                        pcall(function() rejectTradeRequest(trade) end)
                    else
                        -- Hard reset: never trust leftover state from a previous trade
                        oldMessages = {}
                        pcall(function() tradingMessage.Enabled = false end)

                        tradeEpoch    = tradeEpoch + 1
                        local myEpoch = tradeEpoch
                        local localId = getTradeId()
                        tradeId       = localId
                        tradingItems  = {}

                        sendMessage("Trade with: " .. username .. " accepted, Method: Deposit")

                        spawn(function()
                            task.wait(60)
                            if tradeEpoch == myEpoch then
                                sendMessage("Trade declined, User timed out")
                                declineTrade()
                            end
                        end)

                        connectMessage(myEpoch, "deposit", {})
                        connectStatus(localId, myEpoch, "deposit")
                        goNext = false
                    end
                end
            end
        end
    end
end)

print("[RBXTide Trade Bot] script loaded in " .. tostring(tick() - startTick) .. "s")
