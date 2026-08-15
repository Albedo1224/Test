local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local RETRY_SECONDS = 1
local UPGRADE_SECONDS = 0.5
local WAIT_SECONDS = 15
local player = Players.LocalPlayer
local playerScripts = player:WaitForChild("PlayerScripts")
local remotes = require(ReplicatedStorage.Core.Remotes)
local dataClient = require(ReplicatedStorage.Packages.DataService).client
local rebirthBonus = require(ReplicatedStorage.Core.Progression.RebirthBonus)
local coopView = require(ReplicatedStorage.Features.Coop.CoopView)
local recyclerView = require(ReplicatedStorage.Features.Scrap.RecyclerView)
local incubatorView = require(ReplicatedStorage.Features.Incubator.IncubatorView)
local dataController = require(playerScripts.Core.Data.DataController)
local chickenMode = require(playerScripts:WaitForChild("Features"):WaitForChild("Chicken"):WaitForChild("ChickenMode"))
local shared = getgenv and getgenv() or _G

if shared.AutoTowerState then
	shared.AutoTowerState.stop()
end

local oldGui = player:WaitForChild("PlayerGui"):FindFirstChild("AutoTowerUI")
if oldGui then
	oldGui:Destroy()
end

local state = { alive = true, enabled = false, mode = "farm", busy = false, surrendered = false, connections = {} }
shared.AutoTowerState = state

local gui = Instance.new("ScreenGui")
gui.Name = "AutoTowerUI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 1200
gui.Parent = player.PlayerGui

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0)
panel.Position = UDim2.new(0.5, 0, 0, 16)
panel.Size = UDim2.fromOffset(230, 128)
panel.BackgroundColor3 = Color3.fromRGB(28, 31, 38)
panel.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = panel

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 190, 54)
stroke.Thickness = 2
stroke.Parent = panel

local toggle = Instance.new("TextButton")
toggle.Position = UDim2.fromOffset(8, 28)
toggle.Size = UDim2.new(1, -16, 0, 34)
toggle.BackgroundColor3 = Color3.fromRGB(156, 48, 48)
toggle.Font = Enum.Font.GothamBold
toggle.TextColor3 = Color3.new(1, 1, 1)
toggle.TextSize = 17
toggle.Parent = panel

local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(0, 8)
toggleCorner.Parent = toggle

local modeButton = Instance.new("TextButton")
modeButton.Position = UDim2.fromOffset(8, 66)
modeButton.Size = UDim2.new(1, -16, 0, 28)
modeButton.BackgroundColor3 = Color3.fromRGB(63, 93, 145)
modeButton.Font = Enum.Font.GothamBold
modeButton.TextColor3 = Color3.new(1, 1, 1)
modeButton.TextSize = 14
modeButton.Parent = panel

local modeCorner = Instance.new("UICorner")
modeCorner.CornerRadius = UDim.new(0, 8)
modeCorner.Parent = modeButton

local floorLabel = Instance.new("TextLabel")
floorLabel.Position = UDim2.fromOffset(8, 4)
floorLabel.Size = UDim2.new(1, -16, 0, 20)
floorLabel.BackgroundTransparency = 1
floorLabel.Font = Enum.Font.GothamBold
floorLabel.Text = "TOWER FLOOR: --"
floorLabel.TextColor3 = Color3.fromRGB(255, 190, 54)
floorLabel.TextSize = 15
floorLabel.Parent = panel

local status = Instance.new("TextLabel")
status.Position = UDim2.fromOffset(8, 101)
status.Size = UDim2.new(1, -16, 0, 20)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Gotham
status.Text = "Ready"
status.TextColor3 = Color3.fromRGB(220, 222, 228)
status.TextSize = 13
status.TextTruncate = Enum.TextTruncate.AtEnd
status.Parent = panel

local function setStatus(text)
	status.Text = text
end

local function refreshToggle()
	toggle.Text = "AUTO TOWER: " .. (state.enabled and "ON" or "OFF")
	toggle.BackgroundColor3 = state.enabled and Color3.fromRGB(42, 153, 83) or Color3.fromRGB(156, 48, 48)
end

local function refreshMode()
	modeButton.Text = "MODE: " .. string.upper(state.mode)
end

function state.setMode(mode)
	if mode ~= "farm" and mode ~= "rebirth" then
		return false
	end
	state.mode = mode
	state.surrendered = false
	refreshMode()
	setStatus(mode == "farm" and "Farm mode: no rebirth" or "Rebirth mode")
	return true
end

function state.stop()
	state.alive = false
	state.enabled = false
	for _, connection in state.connections do
		connection:Disconnect()
	end
	if gui.Parent then
		gui:Destroy()
	end
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

local function invoke(definition, ...)
	local ok, result = pcall(remotes.invoke, definition, ...)
	if not ok then
		return nil, tostring(result)
	end
	if type(result) == "string" then
		return nil, result
	end
	if type(result) == "table" and result.ok == false then
		return nil, tostring(result.error or "unknown")
	end
	return result, nil
end

local function waitFor(check)
	local deadline = os.clock() + WAIT_SECONDS
	repeat
		if check() then
			return true
		end
		task.wait(0.1)
	until os.clock() >= deadline
	return false
end

local function towerArena()
	local plot = player:GetAttribute("Plot")
	local arenas = Workspace:FindFirstChild("Arenas")
	return plot and arenas and arenas:FindFirstChild("Arena" .. plot)
end

local function towerActive()
	local arena = towerArena()
	return arena and arena:GetAttribute("TowerActive") == true
end

local function refreshFloor()
	local arena = towerArena()
	local floor = arena and tonumber(arena:GetAttribute("TowerFloor"))
	floorLabel.Text = floor and floor > 0 and ("TOWER FLOOR: " .. floor) or "TOWER FLOOR: --"
end

local function rebirthReady()
	local rebirth = dataController.rebirth()
	return rebirthBonus.ready(dataController.towerBest() or 0, rebirth and rebirth.count or 0)
end

local function upgradeOne()
	local money = dataController.money():toNumber()
	local coop = dataClient:get({ "coop" })
	if type(coop) == "table" then
		local generators = type(coop.generators) == "table" and coop.generators or {}
		local slots = tonumber(coop.slots) or 0
		if #generators >= slots and coopView.canExpand(slots) and money >= coopView.expandCost(slots) then
			setStatus("Upgrading Coop...")
			local result, err = invoke(remotes.defs.ExpandCoop)
			return not err and result and result.ok == true
		end
		if coopView.canBuyGenerator(slots, #generators) and money >= coopView.buyGeneratorCost(#generators) then
			setStatus("Buying Feeder...")
			local result, err = invoke(remotes.defs.BuyGenerator, #generators + 1)
			return not err and result and result.ok == true
		end

		local cheapest
		for _, generator in generators do
			local level = tonumber(generator.level) or 1
			local slot = tonumber(generator.slot)
			local cost = coopView.upgradeCost(level)
			if slot and coopView.canUpgrade(level) and cost <= money and (not cheapest or cost < cheapest.cost) then
				cheapest = { slot = slot, cost = cost }
			end
		end
		if cheapest then
			setStatus("Upgrading Feeder...")
			local result, err = invoke(remotes.defs.UpgradeGenerator, cheapest.slot)
			return not err and result and result.ok == true
		end
	end

	local scrap = dataClient:get({ "scrap" })
	local rebirth = dataController.rebirth()
	local recyclerLevel = type(scrap) == "table" and (scrap.recyclerLevel or 0) or 0
	local recyclerCost = recyclerView.upgradeCost(recyclerLevel)
	if player:GetAttribute(recyclerView.LockedAttr) ~= true
		and player:GetAttribute(recyclerView.BusyAttr) ~= true
		and recyclerView.canUpgrade(recyclerLevel, rebirth and rebirth.count or 0)
		and recyclerView.floorUnlocked(recyclerLevel, dataController.towerBest() or 0)
		and recyclerCost <= money
	then
		setStatus("Upgrading Recycler...")
		local result, err = invoke(remotes.defs.UpgradeRecycler)
		return not err and result and result.ok == true
	end

	local incubator = dataClient:get({ "incubator" })
	local incubatorLevel = type(incubator) == "table" and (incubator.level or 0) or 0
	local canUpgrade = incubatorView.canUpgrade(incubatorLevel, rebirth and rebirth.count or 0)
	if canUpgrade and incubatorView.upgradeCost(incubatorLevel + 1) <= money then
		setStatus("Upgrading Incubator...")
		local result, err = invoke(remotes.defs.IncubatorUpgrade)
		return not err and result and result.ok == true
	end

	return false
end

local function prepareAndRebirth()
	state.busy = true
	local roster = dataController.roster()
	local chickens = roster and roster.chickens or {}
	local incubator = dataClient:get({ "incubator" })
	if type(incubator) ~= "table" or (incubator.level or 0) < 1 then
		setStatus("Incubator is locked")
		state.busy = false
		return
	end

	local highest = chickens[1]
	for _, chicken in chickens do
		if not highest or (chicken.level or 1) > (highest.level or 1) then
			highest = chicken
		end
	end
	local incubated = incubator.chicken
	local alreadyStored = incubated and (incubated.id == state.protectedId or not highest or (incubated.level or 1) >= (highest.level or 1))
	if alreadyStored then
		highest = incubated
	else
		state.protectedId = highest and highest.id
	end

	local deployed
	for _, chicken in chickens do
		if chicken.id ~= highest.id then
			deployed = chicken
			break
		end
	end
	if not deployed then
		setStatus("Need another chicken in Flock")
		state.busy = false
		return
	end

	setStatus("Deploying backup chicken...")
	local _, err = invoke(remotes.defs.SetActiveChicken, deployed.id)
	if err or not waitFor(function()
		local current = dataController.roster()
		return current and current.activeId == deployed.id
	end) then
		setStatus("Deploy error: " .. tostring(err or "timeout"))
		state.busy = false
		return
	end

	chickenMode.order("coop")
	remotes.fire(remotes.defs.SetChickenOrder, "coop")
	if not waitFor(function()
		return chickenMode.where() == "corral"
	end) then
		setStatus("Chicken not at Flock")
		state.busy = false
		return
	end

	if incubator.chicken and not alreadyStored then
		setStatus("Removing incubator chicken...")
		_, err = invoke(remotes.defs.IncubatorRemove)
		if err or not waitFor(function()
			local current = dataClient:get({ "incubator" })
			return type(current) == "table" and current.chicken == nil
		end) then
			setStatus("Remove error: " .. tostring(err or "timeout"))
			state.busy = false
			return
		end
	end

	if not alreadyStored then
		setStatus("Storing highest-level chicken...")
		_, err = invoke(remotes.defs.IncubatorInsert, highest.id)
		if err or not waitFor(function()
			local current = dataClient:get({ "incubator" })
			return type(current) == "table" and current.chicken and current.chicken.id == highest.id
		end) then
			setStatus("Swap error: " .. tostring(err or "timeout"))
			state.busy = false
			return
		end
	end
	if state.mode ~= "rebirth" then
		state.restoreId = highest.id
		setStatus("Rebirth cancelled; restoring chicken")
		state.busy = false
		return
	end

	setStatus("Rebirthing...")
	local rebirthBefore = dataController.rebirth()
	rebirthBefore = rebirthBefore and rebirthBefore.count or 0
	local result
	result, err = invoke(remotes.defs.Rebirth)
	if err or not (result and result.ok) then
		setStatus("Rebirth error: " .. tostring(err or (result and result.error) or "unknown"))
	else
		setStatus("Rebirth complete")
		state.restoreId = highest.id
		waitFor(function()
			local current = dataController.rebirth()
			return current and (current.count or 0) > rebirthBefore
		end)
	end
	state.busy = false
end

local function restoreChicken()
	state.busy = true
	local chickenId = state.restoreId
	local roster = dataController.roster()
	local found = false
	for _, chicken in (roster and roster.chickens or {}) do
		if chicken.id == chickenId then
			found = true
			break
		end
	end

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
			local current = dataController.roster()
			for _, chicken in (current and current.chickens or {}) do
				if chicken.id == chickenId then
					return true
				end
			end
			return false
		end) then
			setStatus("Restore error: " .. tostring(err or "timeout"))
			state.busy = false
			return
		end
	end

	setStatus("Deploying strongest chicken...")
	local _, err = invoke(remotes.defs.SetActiveChicken, chickenId)
	if err or not waitFor(function()
		local current = dataController.roster()
		return current and current.activeId == chickenId
	end) then
		setStatus("Deploy error: " .. tostring(err or "timeout"))
	else
		state.restoreId = nil
		state.protectedId = nil
		setStatus("Strongest chicken restored")
	end
	state.busy = false
end

assert(RETRY_SECONDS >= 1 and UPGRADE_SECONDS >= 0.25 and WAIT_SECONDS >= RETRY_SECONDS, "Invalid auto tower timing")
assert(coopView.canBuyGenerator(2, 1) and not coopView.canBuyGenerator(1, 1), "Invalid Coop slot logic")

table.insert(state.connections, remotes.onClient(remotes.defs.TowerContinueOffer, function(offer)
	if state.enabled and type(offer) == "table" and offer.open == true and offer.paid == true then
		setStatus("No Thanks: tower continue")
		remotes.fire(remotes.defs.TowerContinueDecline)
	end
end))

task.spawn(function()
	while state.alive and shared.AutoTowerState == state do
		refreshFloor()
		if not state.busy and (state.enabled or state.restoreId) then
			if state.restoreId then
				restoreChicken()
			elseif state.mode == "rebirth" and rebirthReady() then
				if towerActive() then
					if not state.surrendered or os.clock() - state.surrendered >= 5 then
						state.surrendered = os.clock()
						setStatus("Ready: leaving tower...")
						task.spawn(invoke, remotes.defs.TowerSurrender)
					end
				else
					state.surrendered = false
					prepareAndRebirth()
				end
			elseif not towerActive() then
				state.surrendered = false
				chickenMode.order("tower")
				setStatus("Starting tower...")
				local _, err = invoke(remotes.defs.TowerStart)
				if err and err ~= "busy" then
					setStatus("Tower error: " .. err)
				end
			else
				setStatus("Fighting tower")
			end
		end
		task.wait(RETRY_SECONDS)
	end
end)

task.spawn(function()
	while state.alive and shared.AutoTowerState == state do
		if state.enabled and not state.busy and towerActive() and (state.mode == "farm" or not rebirthReady()) then
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
