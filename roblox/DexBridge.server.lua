--[[
	Roblox Dex Explorer — Bridge Script
	====================================
	Place this Script in ServerScriptService of a place YOU own/control.

	Setup:
	  1. Run the external app:  python main.py
	  2. Copy the auth token from the app UI (or terminal)
	  3. Paste it into AUTH_TOKEN below
	  4. Set BRIDGE_BASE to the app URL (Studio default is fine)
	  5. In Studio: Game Settings → Security → Allow HTTP requests  (HttpService.HttpEnabled)
	  6. Press Play

	This script ONLY talks to your local explorer app. It does not inject into
	other games and will refuse to run without a matching token.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

----------------------------------------------------------------------
-- CONFIG — edit these
----------------------------------------------------------------------
local BRIDGE_BASE = "http://127.0.0.1:3847" -- no trailing slash
local AUTH_TOKEN = "PASTE_TOKEN_HERE"
local POLL_INTERVAL = 0.35 -- seconds
local SESSION_ID = HttpService:GenerateGUID(false)

----------------------------------------------------------------------
-- Safety: refuse to start with a placeholder token
----------------------------------------------------------------------
if AUTH_TOKEN == "" or AUTH_TOKEN == "PASTE_TOKEN_HERE" then
	warn("[DexBridge] Set AUTH_TOKEN to the token from your Roblox Dex app, then Play again.")
	return
end

if not HttpService.HttpEnabled then
	warn("[DexBridge] HttpService.HttpEnabled is false. Enable HTTP requests in Game Settings → Security.")
	return
end

local HEADERS = {
	["Content-Type"] = "application/json",
	["Authorization"] = "Bearer " .. AUTH_TOKEN,
}

local SERVICES = {
	"Workspace",
	"Players",
	"ReplicatedStorage",
	"ReplicatedFirst",
	"ServerStorage",
	"ServerScriptService",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"Lighting",
	"SoundService",
	"Chat",
	"Teams",
	"MaterialService",
	"TextChatService",
}

local READ_PROPERTIES = {
	"Name", "ClassName", "Parent", "Archivable",
	"Transparency", "Reflectance", "Anchored", "CanCollide", "CanTouch", "CanQuery",
	"CastShadow", "Massless", "Material", "BrickColor", "Color", "Size", "Position",
	"Orientation", "CFrame", "Velocity", "RotVelocity", "AssemblyLinearVelocity",
	"Locked", "Shape", "PrimaryPart",
	"Value", "Enabled", "Disabled", "Text", "PlaceholderText", "Image", "ImageColor3",
	"BackgroundColor3", "BackgroundTransparency", "BorderSizePixel", "Visible",
	"ZIndex", "LayoutOrder", "AnchorPoint", "Position", "Size", "AbsoluteSize",
	"AbsolutePosition", "RichText", "Font", "TextSize", "TextColor3", "TextScaled",
	"MaxActivationDistance", "HoldDuration", "RequiresLineOfSight",
	"Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "AutoRotate",
	"Sit", "PlatformStand", "DisplayDistanceType", "NameDisplayDistance",
	"Brightness", "Ambient", "OutdoorAmbient", "ClockTime", "GeographicLatitude",
	"FogColor", "FogStart", "FogEnd", "GlobalShadows",
	"Volume", "PlaybackSpeed", "Looped", "Playing", "TimePosition",
	"Source", -- ModuleScript / Script source only readable in Studio contexts that allow it
}

local EDITABLE = {
	Name = true,
	Transparency = true,
	Reflectance = true,
	Anchored = true,
	CanCollide = true,
	CanTouch = true,
	CanQuery = true,
	CastShadow = true,
	Massless = true,
	Locked = true,
	Value = true,
	Enabled = true,
	Text = true,
	Visible = true,
	Brightness = true,
	ClockTime = true,
	WalkSpeed = true,
	JumpPower = true,
	JumpHeight = true,
	Health = true,
	MaxHealth = true,
	Volume = true,
	PlaybackSpeed = true,
	Looped = true,
	Playing = true,
}

local function encode(value)
	return HttpService:JSONEncode(value)
end

local function decode(text)
	return HttpService:JSONDecode(text)
end

local function request(method, path, bodyTable)
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = BRIDGE_BASE .. path,
			Method = method,
			Headers = HEADERS,
			Body = bodyTable and encode(bodyTable) or nil,
		})
	end)
	if not ok then
		return false, tostring(response)
	end
	if response.StatusCode < 200 or response.StatusCode >= 300 then
		return false, ("HTTP %d: %s"):format(response.StatusCode, tostring(response.Body))
	end
	if response.Body == nil or response.Body == "" then
		return true, {}
	end
	local decodeOk, payload = pcall(decode, response.Body)
	if not decodeOk then
		return false, "Invalid JSON from bridge"
	end
	return true, payload
end

local function splitPath(path)
	local parts = {}
	if typeof(path) ~= "string" or path == "" or path == "game" then
		return parts
	end
	local cleaned = path
	if cleaned:sub(1, 5) == "game." then
		cleaned = cleaned:sub(6)
	elseif cleaned == "game" then
		return parts
	end
	for part in cleaned:gmatch("[^%.]+") do
		table.insert(parts, part)
	end
	return parts
end

local function instancePath(inst)
	if inst == game then
		return "game"
	end
	local ok, full = pcall(function()
		return inst:GetFullName()
	end)
	if ok and typeof(full) == "string" then
		-- GetFullName returns Workspace.Foo not game.Workspace.Foo
		if full == "Game" or full == "game" then
			return "game"
		end
		return "game." .. full
	end
	return "game"
end

local function resolvePath(path)
	if typeof(path) ~= "string" or path == "" or path == "game" then
		return game
	end
	local parts = splitPath(path)
	local current = game
	for _, name in ipairs(parts) do
		local child = current:FindFirstChild(name)
		if not child and current == game then
			-- Services are reliably reachable via GetService from the DataModel root
			local serviceOk, service = pcall(function()
				return game:GetService(name)
			end)
			if serviceOk and service then
				child = service
			end
		end
		if not child then
			return nil, ("Cannot find '%s' under %s"):format(name, instancePath(current))
		end
		current = child
	end
	return current, nil
end

local function serializeValue(value)
	local t = typeof(value)
	if value == nil then
		return nil, "nil"
	elseif t == "string" or t == "number" or t == "boolean" then
		return value, t
	elseif t == "Instance" then
		return instancePath(value), "Instance"
	elseif t == "Vector3" then
		return { x = value.X, y = value.Y, z = value.Z, __type = "Vector3" }, "Vector3"
	elseif t == "Vector2" then
		return { x = value.X, y = value.Y, __type = "Vector2" }, "Vector2"
	elseif t == "Color3" then
		return { r = value.R, g = value.G, b = value.B, __type = "Color3" }, "Color3"
	elseif t == "BrickColor" then
		return tostring(value), "BrickColor"
	elseif t == "CFrame" then
		local x, y, z = value.Position.X, value.Position.Y, value.Position.Z
		return { position = { x = x, y = y, z = z }, __type = "CFrame" }, "CFrame"
	elseif t == "UDim2" then
		return {
			xScale = value.X.Scale,
			xOffset = value.X.Offset,
			yScale = value.Y.Scale,
			yOffset = value.Y.Offset,
			__type = "UDim2",
		}, "UDim2"
	elseif t == "UDim" then
		return { scale = value.Scale, offset = value.Offset, __type = "UDim" }, "UDim"
	elseif t == "EnumItem" then
		return tostring(value), "EnumItem"
	elseif t == "Axes" or t == "Faces" or t == "PhysicalProperties" or t == "Ray" then
		return tostring(value), t
	else
		local ok, asString = pcall(tostring, value)
		return ok and asString or ("<%s>"):format(t), t
	end
end

local function nodeFromInstance(inst)
	local childCount = 0
	local okCount, children = pcall(function()
		return inst:GetChildren()
	end)
	if okCount then
		childCount = #children
	end
	return {
		name = inst.Name,
		class_name = inst.ClassName,
		path = instancePath(inst),
		child_count = childCount,
		has_children = childCount > 0,
	}
end

local function deserializeValue(value, typeHint)
	if typeof(value) ~= "table" then
		return value
	end
	local tag = value.__type or typeHint
	if tag == "Vector3" then
		return Vector3.new(value.x or 0, value.y or 0, value.z or 0)
	elseif tag == "Color3" then
		return Color3.new(value.r or 0, value.g or 0, value.b or 0)
	end
	return value
end

local function listServices()
	local services = {}
	for _, name in ipairs(SERVICES) do
		local ok, service = pcall(function()
			return game:GetService(name)
		end)
		if ok and service then
			table.insert(services, nodeFromInstance(service))
		end
	end
	return { services = services }
end

local function getChildren(path)
	local inst, err = resolvePath(path)
	if not inst then
		return nil, err
	end
	local children = {}
	local ok, list = pcall(function()
		return inst:GetChildren()
	end)
	if not ok then
		return nil, tostring(list)
	end
	table.sort(list, function(a, b)
		if a.ClassName == b.ClassName then
			return a.Name < b.Name
		end
		return a.ClassName < b.ClassName
	end)
	for _, child in ipairs(list) do
		table.insert(children, nodeFromInstance(child))
	end
	return { children = children }
end

local function getProperties(path)
	local inst, err = resolvePath(path)
	if not inst then
		return nil, err
	end

	local seen = {}
	local props = {}

	local function push(name)
		if seen[name] then
			return
		end
		seen[name] = true
		local ok, value = pcall(function()
			return inst[name]
		end)
		if not ok then
			return
		end
		local serialized, typeName = serializeValue(value)
		local editable = EDITABLE[name] == true
			and (typeName == "string" or typeName == "number" or typeName == "boolean"
				or typeName == "Vector3" or typeName == "Color3")
		table.insert(props, {
			name = name,
			type_name = typeName,
			value = serialized,
			editable = editable,
			readonly = not editable,
		})
	end

	push("Name")
	push("ClassName")
	local parentOk, parent = pcall(function()
		return inst.Parent
	end)
	if parentOk then
		local serialized, typeName = serializeValue(parent)
		table.insert(props, {
			name = "Parent",
			type_name = typeName,
			value = serialized,
			editable = false,
			readonly = true,
		})
		seen.Parent = true
	end

	for _, name in ipairs(READ_PROPERTIES) do
		push(name)
	end

	table.sort(props, function(a, b)
		return a.name < b.name
	end)
	return { properties = props, path = instancePath(inst), class_name = inst.ClassName }
end

local function setProperty(path, propertyName, value)
	if typeof(propertyName) ~= "string" or propertyName == "" then
		return nil, "property_name required"
	end
	if not EDITABLE[propertyName] then
		return nil, ("Property '%s' is not editable through DexBridge"):format(propertyName)
	end
	local inst, err = resolvePath(path)
	if not inst then
		return nil, err
	end
	local currentOk, current = pcall(function()
		return inst[propertyName]
	end)
	local typeHint = currentOk and typeof(current) or nil
	local decoded = deserializeValue(value, typeHint)
	local setOk, setErr = pcall(function()
		inst[propertyName] = decoded
	end)
	if not setOk then
		return nil, tostring(setErr)
	end
	return { path = instancePath(inst), property_name = propertyName, value = serializeValue(decoded) }
end

local function search(query, limit)
	limit = math.clamp(tonumber(limit) or 80, 1, 200)
	if typeof(query) ~= "string" or query == "" then
		return { matches = {} }
	end
	local needle = string.lower(query)
	local matches = {}

	local function consider(inst)
		if #matches >= limit then
			return
		end
		local name = string.lower(inst.Name)
		local className = string.lower(inst.ClassName)
		if string.find(name, needle, 1, true) or string.find(className, needle, 1, true) then
			table.insert(matches, nodeFromInstance(inst))
		end
	end

	for _, name in ipairs(SERVICES) do
		local ok, service = pcall(function()
			return game:GetService(name)
		end)
		if ok and service then
			consider(service)
			local descOk, descendants = pcall(function()
				return service:GetDescendants()
			end)
			if descOk then
				for _, inst in ipairs(descendants) do
					consider(inst)
					if #matches >= limit then
						break
					end
				end
			end
		end
		if #matches >= limit then
			break
		end
	end

	return { matches = matches, query = query }
end

local function handleCommand(cmd)
	local op = cmd.op
	if op == "ping" then
		return {
			pong = true,
			place_id = game.PlaceId,
			job_id = game.JobId,
			studio = RunService:IsStudio(),
		}
	elseif op == "list_services" then
		return listServices()
	elseif op == "get_children" then
		return getChildren(cmd.path)
	elseif op == "get_properties" then
		return getProperties(cmd.path)
	elseif op == "set_property" then
		return setProperty(cmd.path, cmd.property_name, cmd.value)
	elseif op == "search" then
		return search(cmd.query, cmd.limit)
	elseif op == "get_full_name" then
		local inst, err = resolvePath(cmd.path)
		if not inst then
			return nil, err
		end
		return { path = instancePath(inst) }
	elseif op == "get_descendants_count" then
		local inst, err = resolvePath(cmd.path)
		if not inst then
			return nil, err
		end
		local ok, descendants = pcall(function()
			return inst:GetDescendants()
		end)
		if not ok then
			return nil, tostring(descendants)
		end
		return { count = #descendants }
	end
	return nil, "Unknown op: " .. tostring(op)
end

local function postResult(id, okFlag, data, err)
	request("POST", "/bridge/result", {
		id = id,
		ok = okFlag and true or false,
		data = data,
		error = err,
	})
end

local function pollOnce()
	local body = {
		session_id = SESSION_ID,
		place_id = game.PlaceId,
		place_name = (game.Name ~= "" and game.Name) or ("Place_" .. tostring(game.PlaceId)),
		job_id = game.JobId,
		studio = RunService:IsStudio(),
		player_count = #Players:GetPlayers(),
	}
	local ok, payload = request("POST", "/bridge/poll", body)
	if not ok then
		return false, payload
	end

	local commands = payload.commands or {}
	for _, cmd in ipairs(commands) do
		-- pcall only keeps the first return value, so wrap (data, err) in a table.
		local callOk, boxed = pcall(function()
			local data, err = handleCommand(cmd)
			return { data = data, err = err }
		end)
		if not callOk then
			postResult(cmd.id, false, nil, tostring(boxed))
		elseif boxed.data == nil and typeof(boxed.err) == "string" then
			postResult(cmd.id, false, nil, boxed.err)
		else
			postResult(cmd.id, true, boxed.data, nil)
		end
	end
	return true, #commands
end

print(("[DexBridge] Starting — session %s → %s"):format(SESSION_ID, BRIDGE_BASE))

task.spawn(function()
	local failures = 0
	while true do
		local ok, info = pollOnce()
		if ok then
			failures = 0
		else
			failures += 1
			if failures == 1 or failures % 20 == 0 then
				warn("[DexBridge] Poll failed: " .. tostring(info))
			end
		end
		task.wait(POLL_INTERVAL)
	end
end)
