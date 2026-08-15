--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser       = game:GetService("VirtualUser")
local Workspace         = game:GetService("Workspace")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
local RETRY_SECONDS   = 0.8      -- main loop (slightly faster)
local UPGRADE_SECONDS = 0.05     -- near-instant upgrade checks
local WAIT_SECONDS    = 12       -- waitFor timeout
local HEAL_WAIT_SECONDS = 90     -- low-health chickens need about a minute at Coop
local POLL_INTERVAL   = 0.08     -- waitFor polling (was 0.1)

--------------------------------------------------------------------------------
-- Player & Module Requires
--------------------------------------------------------------------------------
local player        = Players.LocalPlayer
local playerGui     = player:WaitForChild("PlayerGui")
local playerScripts = player:WaitForChild("PlayerScripts")

local remotes        = require(ReplicatedStorage.Core.Remotes)
local dataClient     = require(ReplicatedStorage.Packages.DataService).client
local rebirthBonus   = require(ReplicatedStorage.Core.Progression.RebirthBonus)
local gameConfig     = require(ReplicatedStorage.Content.GameConfig)
local towerFloor     = require(ReplicatedStorage.Features.Battle.tower.TowerFloor)
local coopView       = require(ReplicatedStorage.Features.Coop.CoopView)
local recyclerView   = require(ReplicatedStorage.Features.Scrap.RecyclerView)
local incubatorView  = require(ReplicatedStorage.Features.Incubator.IncubatorView)
local dataController = require(playerScripts.Core.Data.DataController)
local chickenMode    = require(playerScripts:WaitForChild("Features")
                        :WaitForChild("Chicken"):WaitForChild("ChickenMode"))
local chickenOverlay = require(playerScripts.Features.Chicken.ChickenOverlay)

--------------------------------------------------------------------------------
-- Anti-Cheat Blocker (single-instance guard)
--------------------------------------------------------------------------------
local env  = getgenv and getgenv() or _G
local SLOT = "GACFAntiCheatTracer"

do
    local previous = rawget(env, SLOT)
    if type(previous) == "table" and type(previous.Restore) == "function" then
        pcall(previous.Restore)
    end
end

local blocker = { Active = true, BlockedCalls = 0 }
env[SLOT] = blocker

local GUID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function isGuidName(name)
    return type(name) == "string" and string.match(name, GUID_PATTERN) ~= nil
end

do
    local probe      = Instance.new("RemoteEvent")
    local fireServer  = probe.FireServer
    probe:Destroy()

    local oldFireServer
    oldFireServer = hookfunction(fireServer, newcclosure(function(self, ...)
        if blocker.Active
            and not checkcaller()
            and typeof(self) == "Instance"
            and self.ClassName == "RemoteEvent"
            and isGuidName(self.Name)
        then
            blocker.BlockedCalls += 1
            return
        end
        return oldFireServer(self, ...)
    end))

    function blocker.Restore()
        blocker.Active = false
        pcall(hookfunction, fireServer, oldFireServer)
        if rawget(env, SLOT) == blocker then
            env[SLOT] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- Teardown Previous Instance
--------------------------------------------------------------------------------
local shared = env

if shared.AutoTowerState then
    pcall(shared.AutoTowerState.stop)
end

do
    local oldGui = playerGui:FindFirstChild("AutoTowerUI")
    if oldGui then oldGui:Destroy() end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local state = {
    alive       = true,
    enabled     = false,
    mode        = "farm",
    busy        = false,
    surrendered = false,
    restoreId   = nil,
    protectedId = nil,
    connections = {},
}
shared.AutoTowerState = state

--------------------------------------------------------------------------------
-- GUI Builder Helpers
--------------------------------------------------------------------------------
local function makeCorner(parent, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius)
    c.Parent = parent
    return c
end

local function makeLabel(props, parent)
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Font        = props.Font or Enum.Font.Gotham
    lbl.TextColor3  = props.Color or Color3.fromRGB(220, 222, 228)
    lbl.TextSize    = props.Size or 13
    lbl.Text        = props.Text or ""
    lbl.Position    = props.Position
    lbl.Size        = props.Dims
    if props.Truncate then lbl.TextTruncate = Enum.TextTruncate.AtEnd end
    lbl.Parent = parent
    return lbl
end

local function makeButton(props, parent)
    local btn = Instance.new("TextButton")
    btn.Font            = Enum.Font.GothamBold
    btn.TextColor3      = Color3.new(1, 1, 1)
    btn.TextSize        = props.Size or 14
    btn.Text            = props.Text or ""
    btn.Position        = props.Position
    btn.Size            = props.Dims
    btn.BackgroundColor3 = props.Color
    btn.Parent          = parent
    makeCorner(btn, 8)
    return btn
end

--------------------------------------------------------------------------------
-- Build GUI
--------------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name         = "AutoTowerUI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 1200
gui.Parent       = playerGui

local panel = Instance.new("Frame")
panel.AnchorPoint      = Vector2.new(0.5, 0)
panel.Position         = UDim2.new(0.5, 0, 0, 16)
panel.Size             = UDim2.fromOffset(230, 128)
panel.BackgroundColor3 = Color3.fromRGB(28, 31, 38)
panel.Parent           = gui
makeCorner(panel, 12)

local panelStroke   = Instance.new("UIStroke")
panelStroke.Color     = Color3.fromRGB(255, 190, 54)
panelStroke.Thickness = 2
panelStroke.Parent    = panel

local floorLabel = makeLabel({
    Font     = Enum.Font.GothamBold,
    Color    = Color3.fromRGB(255, 190, 54),
    Size     = 15,
    Text     = "TOWER FLOOR: --",
    Position = UDim2.fromOffset(8, 4),
    Dims     = UDim2.new(1, -16, 0, 20),
}, panel)

local toggle = makeButton({
    Text     = "",
    Size     = 17,
    Color    = Color3.fromRGB(156, 48, 48),
    Position = UDim2.fromOffset(8, 28),
    Dims     = UDim2.new(1, -16, 0, 34),
}, panel)

local modeButton = makeButton({
    Text     = "",
    Color    = Color3.fromRGB(63, 93, 145),
    Position = UDim2.fromOffset(8, 66),
    Dims     = UDim2.new(1, -16, 0, 28),
}, panel)

local statusLabel = makeLabel({
    Text     = "Ready",
    Truncate = true,
    Position = UDim2.fromOffset(8, 101),
    Dims     = UDim2.new(1, -16, 0, 20),
}, panel)

--------------------------------------------------------------------------------
-- GUI Refresh
--------------------------------------------------------------------------------
local COLOR_ON  = Color3.fromRGB(42, 153, 83)
local COLOR_OFF = Color3.fromRGB(156, 48, 48)

local function setStatus(text)
    statusLabel.Text = text
end

local function refreshToggle()
    local on = state.enabled
    toggle.Text            = "AUTO TOWER: " .. (on and "ON" or "OFF")
    toggle.BackgroundColor3 = on and COLOR_ON or COLOR_OFF
end

local function refreshMode()
    modeButton.Text = "MODE: " .. string.upper(state.mode)
end

function state.setMode(mode)
    if mode ~= "farm" and mode ~= "rebirth" then return false end
    state.mode       = mode
    state.surrendered = false
    refreshMode()
    setStatus(mode == "farm" and "Farm mode: no rebirth" or "Rebirth mode")
    return true
end

function state.stop()
    state.alive   = false
    state.enabled = false
    for _, conn in state.connections do
        pcall(conn.Disconnect, conn)
    end
    table.clear(state.connections)
    if gui and gui.Parent then gui:Destroy() end
end

toggle.Activated:Connect(function()
    state.enabled = not state.enabled
    refreshToggle()
    setStatus(state.enabled and "Watching tower" or "Disabled")
end)

modeButton.Activated:Connect(function()
    state.setMode(state.mode == "farm" and "rebirth" or "farm")
end)

refreshToggle()
refreshMode()

--------------------------------------------------------------------------------
-- Anti-AFK
--------------------------------------------------------------------------------
table.insert(state.connections, player.Idled:Connect(function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.zero)
    end)
end))

--------------------------------------------------------------------------------
-- Utility Helpers
--------------------------------------------------------------------------------
local function invoke(definition, ...)
    local ok, result = pcall(remotes.invoke, definition, ...)
    if not ok then return nil, tostring(result) end
    if type(result) == "string" then return nil, result end
    if type(result) == "table" and result.ok == false then
        return nil, tostring(result.error or "unknown")
    end
    return result, nil
end

local function invokeOk(definition, ...)
    local result, err = invoke(definition, ...)
    return not err and result and (result.ok ~= false), err
end

local function waitFor(check, timeout)
    local deadline = os.clock() + (timeout or WAIT_SECONDS)
    while os.clock() < deadline do
        if check() then return true end
        task.wait(POLL_INTERVAL)
    end
    return false
end

local function waitForChickenAtCoop(chickenId, healFull)
    chickenMode.order("coop")
    remotes.fire(remotes.defs.SetChickenOrder, "coop")

    local nextOrder = os.clock() + 2
    local stableAt
    local lastPosition
    return waitFor(function()
        local now = os.clock()
        local position
        local roster = dataController.roster()
        for body, stats in chickenOverlay.bodies() do
            if roster and roster.activeId == chickenId
                and stats.owner == player.UserId
                and stats.state == "corral"
                and (not healFull or (stats.hpFrac or 1) >= 0.999)
            then
                position = body.Position
                break
            end
        end

        if position then
            local delta = lastPosition and position - lastPosition
            local stopped = delta and Vector3.new(delta.X, 0, delta.Z).Magnitude <= 0.1
            stableAt = stopped and (stableAt or now) or nil
            lastPosition = position
            return stableAt and now - stableAt >= 0.8
        end

        stableAt = nil
        lastPosition = nil
        if now >= nextOrder then
            chickenMode.order("coop")
            remotes.fire(remotes.defs.SetChickenOrder, "coop")
            nextOrder = now + 2
        end
        return false
    end, healFull and HEAL_WAIT_SECONDS or WAIT_SECONDS)
end

local function getArena()
    local plot   = player:GetAttribute("Plot")
    local arenas = Workspace:FindFirstChild("Arenas")
    return plot and arenas and arenas:FindFirstChild("Arena" .. plot)
end

local function isTowerActive()
    local arena = getArena()
    return arena and arena:GetAttribute("TowerActive") == true
end

local function refreshFloor()
    local arena = getArena()
    local floor = arena and tonumber(arena:GetAttribute("TowerFloor"))
    floorLabel.Text = (floor and floor > 0)
        and ("TOWER FLOOR: " .. floor)
        or  "TOWER FLOOR: --"
end

local function isRebirthReady()
    local rebirth = dataController.rebirth()
    local best    = dataController.towerBest() or 0
    local count   = rebirth and rebirth.count or 0
    return rebirthBonus.ready(best, count)
end

local function getRebirthCount()
    local r = dataController.rebirth()
    return r and r.count or 0
end

local function getMoney()
    return dataController.money():toNumber()
end

local function elevatorCost(floor)
    local total = 0
    for i = 1, floor - 1 do
        total += towerFloor.at(i).money
    end

    local purchases = dataController.purchases()
    local vip = purchases and purchases.passes and purchases.passes.elevatorVip == true
    local elevator = gameConfig.premium.elevator
    return math.max(0, math.floor(total * elevator.costFactor
        * (1 - (vip and elevator.vipDiscount or 0)) + 0.5))
end

local function chooseElevatorFloor()
    local elevator = gameConfig.premium.elevator
    local chicken = dataController.chicken()
    local best = dataController.towerBest() or 0

    if not elevator.enabled or not chicken or (chicken.level or 1) < 2
        or best < elevator.minFloor + 1
    then
        return nil, "BOTTOM"
    end

    local money = getMoney()
    local front = best + 1
    if money >= elevatorCost(front) then
        return front, "FRONT"
    end

    local warm = math.max(elevator.minFloor, best - 4)
    if warm < front - 1 and money >= elevatorCost(warm) then
        return warm, "WARM"
    end

    return nil, "BOTTOM"
end

--------------------------------------------------------------------------------
-- Upgrade Logic (all upgrades in one pass for speed)
--------------------------------------------------------------------------------
local function upgradeOne()
    local money   = getMoney()
    local rebirth = dataController.rebirth()
    local rCount  = rebirth and rebirth.count or 0

    -- Coop upgrades
    local coop = dataClient:get({ "coop" })
    if type(coop) == "table" then
        local generators = type(coop.generators) == "table" and coop.generators or {}
        local slots      = tonumber(coop.slots) or 0
        local genCount   = #generators

        -- Expand coop
        if genCount >= slots
            and coopView.canExpand(slots)
            and money >= coopView.expandCost(slots)
        then
            setStatus("Upgrading Coop...")
            return invokeOk(remotes.defs.ExpandCoop)
        end

        -- Buy generator
        if coopView.canBuyGenerator(slots, genCount)
            and money >= coopView.buyGeneratorCost(genCount)
        then
            setStatus("Buying Feeder...")
            return invokeOk(remotes.defs.BuyGenerator, genCount + 1)
        end

        -- Upgrade cheapest generator
        local cheapest
        for _, gen in generators do
            local level = tonumber(gen.level) or 1
            local s     = tonumber(gen.slot)
            local cost  = coopView.upgradeCost(level)
            if s and coopView.canUpgrade(level) and cost <= money then
                if not cheapest or cost < cheapest.cost then
                    cheapest = { slot = s, cost = cost }
                end
            end
        end
        if cheapest then
            setStatus("Upgrading Feeder...")
            return invokeOk(remotes.defs.UpgradeGenerator, cheapest.slot)
        end
    end

    -- Recycler upgrade
    local scrap         = dataClient:get({ "scrap" })
    local recyclerLevel = type(scrap) == "table" and (scrap.recyclerLevel or 0) or 0

    if player:GetAttribute(recyclerView.LockedAttr) ~= true
        and player:GetAttribute(recyclerView.BusyAttr) ~= true
        and recyclerView.canUpgrade(recyclerLevel, rCount)
        and recyclerView.floorUnlocked(recyclerLevel, dataController.towerBest() or 0)
        and recyclerView.upgradeCost(recyclerLevel) <= money
    then
        setStatus("Upgrading Recycler...")
        return invokeOk(remotes.defs.UpgradeRecycler)
    end

    -- Incubator upgrade
    local incubator      = dataClient:get({ "incubator" })
    local incubatorLevel = type(incubator) == "table" and (incubator.level or 0) or 0

    if incubatorView.canUpgrade(incubatorLevel, rCount)
        and incubatorView.upgradeCost(incubatorLevel + 1) <= money
    then
        setStatus("Upgrading Incubator...")
        return invokeOk(remotes.defs.IncubatorUpgrade)
    end

    return false
end

--------------------------------------------------------------------------------
-- Rebirth Logic
--------------------------------------------------------------------------------
local function findHighestChicken(chickens)
    local best
    for _, c in chickens do
        if not best or (c.level or 1) > (best.level or 1) then
            best = c
        end
    end
    return best
end

local function prepareAndRebirth()
    state.busy = true

    local roster   = dataController.roster()
    local chickens = roster and roster.chickens or {}
    local towerChickenId = roster and roster.activeId
    local incubator = dataClient:get({ "incubator" })

    if type(incubator) ~= "table" or (incubator.level or 0) < 1 then
        setStatus("Incubator is locked")
        state.busy = false
        return
    end

    -- Find strongest chicken
    local highest      = findHighestChicken(chickens)
    local incubated    = incubator.chicken
    local alreadyStored = incubated
        and (incubated.id == state.protectedId
             or not highest
             or (incubated.level or 1) >= (highest.level or 1))

    if alreadyStored then
        highest = incubated
    elseif highest then
        state.protectedId = highest.id
    end

    -- Find a backup chicken to deploy
    local deployed
    for _, c in chickens do
        if c.id ~= highest.id then
            deployed = c
            break
        end
    end
    if not deployed then
        setStatus("Need another chicken in Flock")
        state.busy = false
        return
    end

    -- Recall the current tower chicken before changing the active slot.
    setStatus("Waiting current chicken at Coop...")
    if not towerChickenId or not waitForChickenAtCoop(towerChickenId) then
        setStatus("Current chicken did not reach Coop")
        state.busy = false
        return
    end

    -- Deploy backup
    setStatus("Deploying backup chicken...")
    local _, err = invoke(remotes.defs.SetActiveChicken, deployed.id)
    if err or not waitFor(function()
        local r = dataController.roster()
        return r and r.activeId == deployed.id
    end) then
        setStatus("Deploy error: " .. tostring(err or "timeout"))
        state.busy = false
        return
    end

    -- Keep the newly deployed backup at Coop as well.
    if not waitForChickenAtCoop(deployed.id) then
        setStatus("Chicken not at Flock")
        state.busy = false
        return
    end

    -- Clear incubator if needed
    if incubator.chicken and not alreadyStored then
        setStatus("Removing incubator chicken...")
        _, err = invoke(remotes.defs.IncubatorRemove)
        if err or not waitFor(function()
            local cur = dataClient:get({ "incubator" })
            return type(cur) == "table" and cur.chicken == nil
        end) then
            setStatus("Remove error: " .. tostring(err or "timeout"))
            state.busy = false
            return
        end
    end

    -- Store highest in incubator
    if not alreadyStored then
        setStatus("Storing highest-level chicken...")
        _, err = invoke(remotes.defs.IncubatorInsert, highest.id)
        if err or not waitFor(function()
            local cur = dataClient:get({ "incubator" })
            return type(cur) == "table" and cur.chicken and cur.chicken.id == highest.id
        end) then
            setStatus("Swap error: " .. tostring(err or "timeout"))
            state.busy = false
            return
        end
    end

    -- Check mode hasn't changed
    if state.mode ~= "rebirth" then
        state.restoreId = highest.id
        setStatus("Rebirth cancelled; restoring chicken")
        state.busy = false
        return
    end

    -- Execute rebirth
    setStatus("Rebirthing...")
    local countBefore = getRebirthCount()
    local result
    result, err = invoke(remotes.defs.Rebirth)

    if err or not (result and result.ok) then
        setStatus("Rebirth error: " .. tostring(err or (result and result.error) or "unknown"))
    else
        setStatus("Rebirth complete")
        state.restoreId = highest.id
        waitFor(function() return getRebirthCount() > countBefore end)
    end

    state.busy = false
end

--------------------------------------------------------------------------------
-- Restore Chicken Logic
--------------------------------------------------------------------------------
local function restoreChicken()
    state.busy = true
    local chickenId = state.restoreId

    -- Check flock first
    local roster = dataController.roster()
    local found  = false
    for _, c in (roster and roster.chickens or {}) do
        if c.id == chickenId then found = true; break end
    end

    -- If not in flock, pull from incubator
    if not found then
        local incubator = dataClient:get({ "incubator" })
        if not (type(incubator) == "table" and incubator.chicken and incubator.chicken.id == chickenId) then
            setStatus("Protected chicken not found")
            state.busy = false
            return
        end

        setStatus("Removing strongest chicken...")
        local _, err = invoke(remotes.defs.IncubatorRemove)
        if err or not waitFor(function()
            local r = dataController.roster()
            for _, c in (r and r.chickens or {}) do
                if c.id == chickenId then return true end
            end
            return false
        end) then
            setStatus("Restore error: " .. tostring(err or "timeout"))
            state.busy = false
            return
        end
    end

    -- Deploy it
    setStatus("Deploying strongest chicken...")
    local _, err = invoke(remotes.defs.SetActiveChicken, chickenId)
    if err or not waitFor(function()
        local r = dataController.roster()
        return r and r.activeId == chickenId
    end) then
        setStatus("Deploy error: " .. tostring(err or "timeout"))
    else
        state.restoreId   = nil
        state.protectedId = nil
        setStatus("Strongest chicken restored")
    end

    state.busy = false
end

--------------------------------------------------------------------------------
-- Assertions
--------------------------------------------------------------------------------
assert(RETRY_SECONDS >= 0.5 and UPGRADE_SECONDS >= 0.05 and WAIT_SECONDS >= RETRY_SECONDS,
    "Invalid auto tower timing")

--------------------------------------------------------------------------------
-- Event: Decline Paid Continue Offers
--------------------------------------------------------------------------------
table.insert(state.connections, remotes.onClient(remotes.defs.TowerContinueOffer, function(offer)
    if state.enabled and type(offer) == "table" and offer.open and offer.paid then
        setStatus("No Thanks: tower continue")
        remotes.fire(remotes.defs.TowerContinueDecline)
    end
end))

--------------------------------------------------------------------------------
-- Main Loop: Tower Control
--------------------------------------------------------------------------------
task.spawn(function()
    while state.alive and shared.AutoTowerState == state do
        refreshFloor()

        if not state.busy and (state.enabled or state.restoreId) then
            if state.restoreId then
                restoreChicken()

            elseif state.mode == "rebirth" and isRebirthReady() then
                if isTowerActive() then
                    local now = os.clock()
                    if not state.surrendered or (now - state.surrendered) >= 5 then
                        state.surrendered = now
                        setStatus("Ready: leaving tower...")
                        task.spawn(invoke, remotes.defs.TowerSurrender)
                    end
                else
                    state.surrendered = false
                    prepareAndRebirth()
                end

            elseif not isTowerActive() then
                state.surrendered = false
                local mode = state.mode
                local ready = true

                if mode == "farm" then
                    local roster = dataController.roster()
                    local chickenId = roster and roster.activeId
                    setStatus("Farm: waiting for full health...")
                    ready = chickenId and waitForChickenAtCoop(chickenId, true) or false
                    if not ready then
                        setStatus("Farm: heal timeout")
                    end
                end

                if ready and state.enabled and state.mode == mode then
                    state.busy = true
                    local elevatorFloor, elevatorMode = chooseElevatorFloor()
                    if elevatorFloor then
                        setStatus("Elevator: " .. elevatorMode .. " " .. elevatorFloor)
                        local _, elevatorErr = invoke(remotes.defs.TowerElevator, elevatorFloor)
                        if elevatorErr then
                            elevatorMode = "BOTTOM"
                        end
                    end

                    chickenMode.order("tower")
                    setStatus("Starting tower: " .. elevatorMode)
                    local _, err = invoke(remotes.defs.TowerStart)
                    if err and err ~= "busy" then
                        setStatus("Tower error: " .. err)
                    end
                    state.busy = false
                end
            else
                setStatus("Fighting tower")
            end
        end

        task.wait(RETRY_SECONDS)
    end
end)

--------------------------------------------------------------------------------
-- Upgrade Loop
--------------------------------------------------------------------------------
task.spawn(function()
    while state.alive and shared.AutoTowerState == state do
        if state.enabled
            and not state.busy
            and (state.mode == "farm" or not isRebirthReady())
        then
            state.busy = true
            local ok, err = pcall(upgradeOne)
            state.busy = false
            if not ok then
                setStatus("Upgrade error: " .. tostring(err))
            end
        end
        task.wait(UPGRADE_SECONDS)
    end
end)
