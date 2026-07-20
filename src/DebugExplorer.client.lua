--!nonstrict
--[[
	DebugExplorer — an in-game hierarchy / properties inspector overlay.

	This is a normal LocalScript that you add to a game YOU control. It runs
	inside Roblox's standard scripting sandbox and only reads what any game
	script is allowed to read (the client's replicated DataModel). There is no
	memory reading, injection, or anything that touches another process — it is
	the same idea as Studio's Explorer, embedded in your running game so you can
	inspect state live while reproducing a bug.

	Install: drop this under StarterPlayer > StarterPlayerScripts (see README).
	Toggle:  press the toggle key (default: Right Ctrl) or the on-screen button.

	Limitations (by design / platform rules):
	  * Client-only. It shows what the client can see. ServerScriptService,
	    ServerStorage, and other server-only containers are not visible on the
	    client — inspect those from a Studio "Team Test > Server" view instead.
	  * Script source (`.Source`) is not readable from a regular runtime script,
	    so it is intentionally not shown.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

if not RunService:IsClient() then
	return
end

local player = Players.LocalPlayer
if not player then
	return
end
local playerGui = player:WaitForChild("PlayerGui")

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local CONFIG = {
	ToggleKey = Enum.KeyCode.RightControl,
	StartOpen = false,
	WindowSize = Vector2.new(780, 470),
	AutoRefresh = true,        -- keep the selected instance's properties live
	RefreshInterval = 0.5,     -- seconds between property refreshes
	MaxChildrenPerNode = 300,  -- guard against pathological node counts
	MaxSearchResults = 300,
}

local THEME = {
	Window = Color3.fromRGB(30, 32, 38),
	Panel = Color3.fromRGB(24, 26, 31),
	TitleBar = Color3.fromRGB(40, 44, 52),
	Row = Color3.fromRGB(30, 32, 38),
	RowAlt = Color3.fromRGB(34, 37, 44),
	RowSelected = Color3.fromRGB(52, 86, 130),
	RowHover = Color3.fromRGB(44, 48, 57),
	Text = Color3.fromRGB(232, 234, 238),
	TextDim = Color3.fromRGB(150, 156, 168),
	Accent = Color3.fromRGB(90, 150, 235),
	Border = Color3.fromRGB(58, 62, 72),
	Input = Color3.fromRGB(20, 22, 26),
}

local ROW_HEIGHT = 22
local INDENT = 14

--------------------------------------------------------------------------------
-- Property catalogue
--
-- There is no generic runtime reflection for arbitrary instances, so we keep a
-- curated list of well-known properties grouped by class. For a given instance
-- we take every group whose class it `IsA`, then read each property behind a
-- pcall (missing / protected properties simply do not appear).
--------------------------------------------------------------------------------

local PROPERTY_GROUPS = {
	Instance = { "Name", "ClassName", "Archivable" },
	BasePart = {
		"Anchored", "CanCollide", "CanTouch", "CanQuery", "CastShadow",
		"CollisionGroup", "Color", "Material", "Massless", "Position",
		"Orientation", "Size", "CFrame", "Reflectance", "Transparency",
		"AssemblyLinearVelocity", "AssemblyAngularVelocity", "AssemblyMass",
	},
	Model = { "PrimaryPart", "WorldPivot" },
	Humanoid = {
		"Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight",
		"HipHeight", "MoveDirection", "RigType", "DisplayName", "AutoRotate",
		"PlatformStand", "Sit", "WalkToPoint",
	},
	Player = {
		"DisplayName", "UserId", "AccountAge", "Team", "TeamColor", "Neutral",
		"Character", "CharacterAppearanceId", "FollowUserId",
	},
	ValueBase = { "Value" },
	GuiObject = {
		"Visible", "Active", "AnchorPoint", "BackgroundColor3",
		"BackgroundTransparency", "BorderSizePixel", "Position", "Size",
		"Rotation", "ZIndex", "LayoutOrder", "ClipsDescendants",
	},
	TextLabel = {
		"Text", "TextColor3", "TextScaled", "TextSize", "TextWrapped", "Font",
		"RichText", "TextXAlignment", "TextYAlignment", "TextTransparency",
	},
	TextButton = {
		"Text", "TextColor3", "TextScaled", "TextSize", "TextWrapped", "Font",
		"RichText", "TextXAlignment", "TextYAlignment", "AutoButtonColor",
	},
	TextBox = {
		"Text", "PlaceholderText", "TextColor3", "TextScaled", "TextSize",
		"Font", "ClearTextOnFocus", "MultiLine",
	},
	ImageLabel = { "Image", "ImageColor3", "ImageTransparency", "ScaleType" },
	ImageButton = { "Image", "ImageColor3", "ImageTransparency", "ScaleType", "AutoButtonColor" },
	ScrollingFrame = { "CanvasSize", "CanvasPosition", "ScrollBarThickness", "AutomaticCanvasSize" },
	Camera = { "CameraType", "FieldOfView", "CFrame", "Focus", "CameraSubject" },
	Light = { "Brightness", "Color", "Enabled", "Shadows" },
	PointLight = { "Range" },
	SpotLight = { "Range", "Angle", "Face" },
	Sound = { "SoundId", "Volume", "Playing", "TimePosition", "PlaybackSpeed", "Looped", "TimeLength" },
	Attachment = { "Position", "WorldPosition", "WorldCFrame", "Visible" },
	Decal = { "Texture", "Color3", "Transparency", "Face" },
	Texture = { "Texture", "StudsPerTileU", "StudsPerTileV" },
	ParticleEmitter = { "Enabled", "Rate", "Lifetime", "Speed", "Texture" },
	Beam = { "Enabled", "Attachment0", "Attachment1", "Width0", "Width1" },
	LuaSourceContainer = { "Enabled" },
	Script = { "RunContext", "Enabled" },
	Tool = { "Grip", "CanBeDropped", "Enabled", "RequiresHandle", "ToolTip" },
	Workspace = { "Gravity", "StreamingEnabled", "FallenPartsDestroyHeight", "CurrentCamera" },
	Lighting = {
		"Ambient", "OutdoorAmbient", "Brightness", "ClockTime", "TimeOfDay",
		"FogStart", "FogEnd", "FogColor", "GlobalShadows", "ExposureCompensation",
	},
	Terrain = { "WaterColor", "WaterTransparency", "WaterWaveSize", "WaterWaveSpeed" },
	Constraint = { "Enabled", "Attachment0", "Attachment1" },
	SurfaceGui = { "Adornee", "Face", "AlwaysOnTop", "CanvasSize", "LightInfluence" },
	BillboardGui = { "Adornee", "Size", "StudsOffset", "AlwaysOnTop", "MaxDistance" },
	ProximityPrompt = { "ActionText", "ObjectText", "HoldDuration", "MaxActivationDistance", "Enabled" },
}

--------------------------------------------------------------------------------
-- Value formatting
--------------------------------------------------------------------------------

local function round(n)
	return math.floor(n * 1000 + 0.5) / 1000
end

local function formatValue(v)
	local t = typeof(v)
	if t == "string" then
		local s = v
		if #s > 160 then
			s = string.sub(s, 1, 160) .. "\226\128\166" -- ellipsis
		end
		return string.format("%q", s)
	elseif t == "number" then
		if v ~= v then
			return "nan"
		end
		if v == math.floor(v) and math.abs(v) < 1e15 then
			return tostring(v)
		end
		return tostring(round(v))
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "nil" then
		return "nil"
	elseif t == "Instance" then
		return v.Name .. " (" .. v.ClassName .. ")"
	elseif t == "EnumItem" then
		return "Enum." .. tostring(v.EnumType) .. "." .. v.Name
	elseif t == "Enum" then
		return "Enum." .. tostring(v)
	elseif t == "Vector3" then
		return string.format("%s, %s, %s", round(v.X), round(v.Y), round(v.Z))
	elseif t == "Vector2" then
		return string.format("%s, %s", round(v.X), round(v.Y))
	elseif t == "CFrame" then
		local p = v.Position
		return string.format("pos %s, %s, %s", round(p.X), round(p.Y), round(p.Z))
	elseif t == "Color3" then
		return string.format("%d, %d, %d",
			math.floor(v.R * 255 + 0.5), math.floor(v.G * 255 + 0.5), math.floor(v.B * 255 + 0.5))
	elseif t == "BrickColor" then
		return v.Name
	elseif t == "UDim2" then
		return string.format("{%s, %d}, {%s, %d}", round(v.X.Scale), v.X.Offset, round(v.Y.Scale), v.Y.Offset)
	elseif t == "UDim" then
		return string.format("%s, %d", round(v.Scale), v.Offset)
	elseif t == "NumberRange" then
		return string.format("%s .. %s", round(v.Min), round(v.Max))
	elseif t == "Rect" then
		return string.format("(%s, %s) (%s, %s)", round(v.Min.X), round(v.Min.Y), round(v.Max.X), round(v.Max.Y))
	elseif t == "NumberSequence" or t == "ColorSequence" then
		return t
	end
	return tostring(v)
end

local function gatherProperties(inst)
	local names = {}
	local seen = {}
	for className, list in pairs(PROPERTY_GROUPS) do
		local ok, isa = pcall(function()
			return inst:IsA(className)
		end)
		if ok and isa then
			for _, propName in ipairs(list) do
				if not seen[propName] then
					seen[propName] = true
					table.insert(names, propName)
				end
			end
		end
	end
	table.sort(names)

	local result = {}
	for _, propName in ipairs(names) do
		local ok, value = pcall(function()
			return inst[propName]
		end)
		if ok and typeof(value) ~= "function" then
			table.insert(result, { name = propName, value = value })
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function richEscape(s)
	s = string.gsub(s, "&", "&amp;")
	s = string.gsub(s, "<", "&lt;")
	s = string.gsub(s, ">", "&gt;")
	return s
end

local function hasChildren(inst)
	local ok, kids = pcall(function()
		return inst:GetChildren()
	end)
	return ok and #kids > 0
end

local function safeFullName(inst)
	local ok, name = pcall(function()
		return inst:GetFullName()
	end)
	if ok then
		return name
	end
	return inst.Name
end

--------------------------------------------------------------------------------
-- UI construction
--------------------------------------------------------------------------------

local function make(className, props, children)
	local obj = Instance.new(className)
	for k, v in pairs(props or {}) do
		obj[k] = v
	end
	for _, child in ipairs(children or {}) do
		child.Parent = obj
	end
	return obj
end

local screenGui = make("ScreenGui", {
	Name = "DebugExplorer",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 999999,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

local window = make("Frame", {
	Name = "Window",
	Size = UDim2.fromOffset(CONFIG.WindowSize.X, CONFIG.WindowSize.Y),
	Position = UDim2.new(0.5, -CONFIG.WindowSize.X / 2, 0.5, -CONFIG.WindowSize.Y / 2),
	BackgroundColor3 = THEME.Window,
	BorderSizePixel = 0,
	Visible = CONFIG.StartOpen,
	Active = true,
	Parent = screenGui,
}, {
	make("UICorner", { CornerRadius = UDim.new(0, 8) }),
	make("UIStroke", { Color = THEME.Border, Thickness = 1 }),
})

-- Title bar
local titleBar = make("Frame", {
	Name = "TitleBar",
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundColor3 = THEME.TitleBar,
	BorderSizePixel = 0,
	Parent = window,
}, {
	make("UICorner", { CornerRadius = UDim.new(0, 8) }),
})

make("TextLabel", {
	Name = "Title",
	Size = UDim2.new(0, 210, 1, 0),
	Position = UDim2.fromOffset(12, 0),
	BackgroundTransparency = 1,
	Text = "Debug Explorer",
	TextColor3 = THEME.Text,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = Enum.Font.GothamMedium,
	TextSize = 15,
	Parent = titleBar,
})

local searchBox = make("TextBox", {
	Name = "Search",
	Size = UDim2.new(0, 260, 0, 24),
	Position = UDim2.new(0, 230, 0.5, -12),
	BackgroundColor3 = THEME.Input,
	BorderSizePixel = 0,
	Text = "",
	PlaceholderText = "Search by name or class\226\128\166",
	PlaceholderColor3 = THEME.TextDim,
	TextColor3 = THEME.Text,
	Font = Enum.Font.Gotham,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
	ClearTextOnFocus = false,
	Parent = titleBar,
}, {
	make("UICorner", { CornerRadius = UDim.new(0, 5) }),
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
})

local closeButton = make("TextButton", {
	Name = "Close",
	Size = UDim2.fromOffset(26, 26),
	Position = UDim2.new(1, -32, 0.5, -13),
	BackgroundColor3 = Color3.fromRGB(70, 74, 84),
	BorderSizePixel = 0,
	Text = "\195\151", -- multiplication sign as a close glyph
	TextColor3 = THEME.Text,
	Font = Enum.Font.GothamBold,
	TextSize = 15,
	Parent = titleBar,
}, {
	make("UICorner", { CornerRadius = UDim.new(0, 5) }),
})

-- Body: tree panel (left) + properties panel (right)
local body = make("Frame", {
	Name = "Body",
	Size = UDim2.new(1, -12, 1, -46),
	Position = UDim2.fromOffset(6, 40),
	BackgroundTransparency = 1,
	Parent = window,
})

local treePanel = make("Frame", {
	Name = "TreePanel",
	Size = UDim2.new(0, 320, 1, 0),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
	Parent = body,
}, {
	make("UICorner", { CornerRadius = UDim.new(0, 6) }),
})

local treeScroll = make("ScrollingFrame", {
	Name = "TreeScroll",
	Size = UDim2.new(1, -4, 1, -8),
	Position = UDim2.fromOffset(2, 4),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = THEME.TextDim,
	Parent = treePanel,
}, {
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 0) }),
})

local propsPanel = make("Frame", {
	Name = "PropsPanel",
	Size = UDim2.new(1, -328, 1, 0),
	Position = UDim2.fromOffset(324, 0),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
	Parent = body,
}, {
	make("UICorner", { CornerRadius = UDim.new(0, 6) }),
})

local propsHeader = make("TextLabel", {
	Name = "PropsHeader",
	Size = UDim2.new(1, -16, 0, 40),
	Position = UDim2.fromOffset(8, 6),
	BackgroundTransparency = 1,
	Text = "Select an instance",
	TextColor3 = THEME.TextDim,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextWrapped = true,
	Font = Enum.Font.GothamMedium,
	TextSize = 13,
	Parent = propsPanel,
})

local propsScroll = make("ScrollingFrame", {
	Name = "PropsScroll",
	Size = UDim2.new(1, -8, 1, -54),
	Position = UDim2.fromOffset(4, 48),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = THEME.TextDim,
	Parent = propsPanel,
}, {
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }),
})

-- Floating toggle button (always visible so the window can be reopened)
local toggleButton = make("TextButton", {
	Name = "Toggle",
	Size = UDim2.fromOffset(120, 30),
	Position = UDim2.new(0, 12, 1, -42),
	BackgroundColor3 = THEME.Accent,
	BorderSizePixel = 0,
	Text = "Explorer",
	TextColor3 = Color3.new(1, 1, 1),
	Font = Enum.Font.GothamMedium,
	TextSize = 14,
	Parent = screenGui,
}, {
	make("UICorner", { CornerRadius = UDim.new(0, 6) }),
})

--------------------------------------------------------------------------------
-- State + behaviour
--------------------------------------------------------------------------------

local expanded = {}            -- [instance] = true
local selectedInstance = nil
local rowButtons = {}          -- [instance] = TextButton (current tree rows)

expanded[game] = true

local buildTree -- forward declaration

local function clearChildren(container)
	for _, child in ipairs(container:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

-- 3D selection highlight
local currentHighlight = nil
local function updateHighlight(inst)
	if currentHighlight then
		currentHighlight:Destroy()
		currentHighlight = nil
	end
	if not inst then
		return
	end
	local ok, isPV = pcall(function()
		return inst:IsA("PVInstance")
	end)
	if ok and isPV then
		pcall(function()
			local h = Instance.new("Highlight")
			h.Adornee = inst
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.FillColor = THEME.Accent
			h.FillTransparency = 0.65
			h.OutlineColor = Color3.new(1, 1, 1)
			h.Parent = inst
			currentHighlight = h
		end)
	end
end

local refreshProperties -- forward declaration

local function setRowColor(button, isSelected, index)
	if isSelected then
		button.BackgroundColor3 = THEME.RowSelected
	elseif index and index % 2 == 0 then
		button.BackgroundColor3 = THEME.RowAlt
	else
		button.BackgroundColor3 = THEME.Row
	end
end

local function selectInstance(inst)
	local previous = selectedInstance
	selectedInstance = inst

	if previous and rowButtons[previous] then
		setRowColor(rowButtons[previous], false, rowButtons[previous]:GetAttribute("RowIndex"))
	end
	if inst and rowButtons[inst] then
		setRowColor(rowButtons[inst], true)
	end

	updateHighlight(inst)
	refreshProperties()
end

function refreshProperties()
	clearChildren(propsScroll)
	local inst = selectedInstance
	if not inst then
		propsHeader.Text = "Select an instance"
		propsHeader.TextColor3 = THEME.TextDim
		return
	end

	propsHeader.TextColor3 = THEME.Text
	propsHeader.Text = string.format(
		'<b>%s</b>  <font color="#8A90A0">%s</font>\n<font color="#8A90A0" size="11">%s</font>',
		richEscape(inst.Name), richEscape(inst.ClassName), richEscape(safeFullName(inst))
	)
	propsHeader.RichText = true

	local props = gatherProperties(inst)
	local order = 0
	for _, entry in ipairs(props) do
		order = order + 1
		local isInstanceRef = typeof(entry.value) == "Instance"

		local row = make("Frame", {
			Name = entry.name,
			Size = UDim2.new(1, -8, 0, 20),
			BackgroundColor3 = (order % 2 == 0) and THEME.RowAlt or THEME.Row,
			BackgroundTransparency = 0.4,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Parent = propsScroll,
		})

		make("TextLabel", {
			Size = UDim2.new(0.4, 0, 1, 0),
			Position = UDim2.fromOffset(6, 0),
			BackgroundTransparency = 1,
			Text = entry.name,
			TextColor3 = THEME.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Font = Enum.Font.Gotham,
			TextSize = 12,
			Parent = row,
		})

		local valueText = formatValue(entry.value)
		if isInstanceRef then
			local jump = make("TextButton", {
				Size = UDim2.new(0.6, -12, 1, 0),
				Position = UDim2.new(0.4, 6, 0, 0),
				BackgroundTransparency = 1,
				Text = valueText,
				TextColor3 = THEME.Accent,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				Parent = row,
			})
			local target = entry.value
			jump.MouseButton1Click:Connect(function()
				local node = target.Parent
				while node do
					expanded[node] = true
					node = node.Parent
				end
				searchBox.Text = ""
				buildTree()
				selectInstance(target)
			end)
		else
			make("TextLabel", {
				Size = UDim2.new(0.6, -12, 1, 0),
				Position = UDim2.new(0.4, 6, 0, 0),
				BackgroundTransparency = 1,
				Text = valueText,
				TextColor3 = THEME.Text,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				Parent = row,
			})
		end
	end

	if order == 0 then
		make("TextLabel", {
			Size = UDim2.new(1, -8, 0, 20),
			BackgroundTransparency = 1,
			Text = "No readable properties.",
			TextColor3 = THEME.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = Enum.Font.Gotham,
			TextSize = 12,
			LayoutOrder = 1,
			Parent = propsScroll,
		})
	end
end

--------------------------------------------------------------------------------
-- Tree rendering
--------------------------------------------------------------------------------

local function createTreeRow(inst, depth, index)
	local expandable = hasChildren(inst)
	local isOpen = expanded[inst] == true

	local row = make("TextButton", {
		Name = "Row",
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundColor3 = THEME.Row,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = index,
		Parent = treeScroll,
	})
	row:SetAttribute("RowIndex", index)
	setRowColor(row, inst == selectedInstance, index)

	if expandable then
		local arrow = make("TextButton", {
			Size = UDim2.fromOffset(16, ROW_HEIGHT),
			Position = UDim2.fromOffset(depth * INDENT, 0),
			BackgroundTransparency = 1,
			Text = isOpen and "\226\150\188" or "\226\150\182", -- ▼ / ▶
			TextColor3 = THEME.TextDim,
			Font = Enum.Font.Gotham,
			TextSize = 10,
			Parent = row,
		})
		arrow.MouseButton1Click:Connect(function()
			expanded[inst] = not expanded[inst]
			buildTree()
		end)
	end

	make("TextLabel", {
		Size = UDim2.new(1, -(depth * INDENT + 18), 1, 0),
		Position = UDim2.fromOffset(depth * INDENT + 18, 0),
		BackgroundTransparency = 1,
		RichText = true,
		Text = string.format('%s <font color="#8A90A0">%s</font>',
			richEscape(inst.Name), richEscape(inst.ClassName)),
		TextColor3 = THEME.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		Parent = row,
	})

	row.MouseEnter:Connect(function()
		if inst ~= selectedInstance then
			row.BackgroundColor3 = THEME.RowHover
		end
	end)
	row.MouseLeave:Connect(function()
		if inst ~= selectedInstance then
			setRowColor(row, false, index)
		end
	end)
	row.MouseButton1Click:Connect(function()
		selectInstance(inst)
	end)

	rowButtons[inst] = row
	return row
end

local function createNoteRow(text, depth, index)
	make("TextLabel", {
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = THEME.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamItalic,
		TextSize = 12,
		LayoutOrder = index,
		Parent = treeScroll,
	}, {
		make("UIPadding", { PaddingLeft = UDim.new(0, depth * INDENT + 18) }),
	})
end

local function buildHierarchy()
	local index = 0
	local function walk(inst, depth)
		index = index + 1
		createTreeRow(inst, depth, index)
		if expanded[inst] then
			local ok, kids = pcall(function()
				return inst:GetChildren()
			end)
			if ok then
				local shown = 0
				for _, child in ipairs(kids) do
					if shown >= CONFIG.MaxChildrenPerNode then
						index = index + 1
						createNoteRow(
							string.format("\226\128\166 %d more not shown", #kids - shown),
							depth + 1, index)
						break
					end
					shown = shown + 1
					walk(child, depth + 1)
				end
			end
		end
	end
	walk(game, 0)
end

local function buildSearch(query)
	local lowered = string.lower(query)
	local index = 0
	local matches = 0
	local ok, descendants = pcall(function()
		return game:GetDescendants()
	end)
	if not ok then
		return
	end
	for _, inst in ipairs(descendants) do
		local hay = string.lower(inst.Name .. " " .. inst.ClassName)
		if string.find(hay, lowered, 1, true) then
			index = index + 1
			matches = matches + 1
			local row = createTreeRow(inst, 0, index)
			-- replace the label text with a path-aware label
			for _, child in ipairs(row:GetChildren()) do
				if child:IsA("TextLabel") then
					child.Text = string.format('%s <font color="#8A90A0">%s</font>',
						richEscape(inst.Name), richEscape(inst.ClassName))
				end
			end
			if matches >= CONFIG.MaxSearchResults then
				index = index + 1
				createNoteRow("\226\128\166 more results hidden (refine the search)", 0, index)
				break
			end
		end
	end
	if matches == 0 then
		createNoteRow("No matches.", 0, 1)
	end
end

function buildTree()
	rowButtons = {}
	clearChildren(treeScroll)
	local query = searchBox.Text
	if query ~= nil and string.gsub(query, "%s", "") ~= "" then
		buildSearch(query)
	else
		buildHierarchy()
	end
end

--------------------------------------------------------------------------------
-- Window controls: toggle, drag, search, auto-refresh
--------------------------------------------------------------------------------

local function setVisible(visible)
	window.Visible = visible
	if visible then
		buildTree()
	end
end

toggleButton.MouseButton1Click:Connect(function()
	setVisible(not window.Visible)
end)

closeButton.MouseButton1Click:Connect(function()
	setVisible(false)
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == CONFIG.ToggleKey then
		setVisible(not window.Visible)
	end
end)

-- Search box (debounced via a simple change handler)
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	if window.Visible then
		buildTree()
	end
end)

-- Dragging the window by its title bar
do
	local dragging = false
	local dragStart = Vector2.new(0, 0)
	local startPos = window.Position

	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = window.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			window.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
end

-- Keep the selected instance's properties live while it is on screen.
if CONFIG.AutoRefresh then
	task.spawn(function()
		while screenGui.Parent do
			task.wait(CONFIG.RefreshInterval)
			if window.Visible and selectedInstance then
				local ok, alive = pcall(function()
					return selectedInstance.Parent ~= nil or selectedInstance == game
				end)
				if ok and alive then
					refreshProperties()
				else
					selectInstance(nil)
				end
			end
		end
	end)
end

if CONFIG.StartOpen then
	buildTree()
end
