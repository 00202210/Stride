```lua
local Stride = require(game.ReplicatedStorage.Stride)

local Entity = Stride.SchemaOrdered({
	{Name = "x", Type = Stride.Float32},
	{Name = "y", Type = Stride.Float32},
	{Name = "vx", Type = Stride.Float32},
	{Name = "vy", Type = Stride.Float32},
	{Name = "health", Type = Stride.Float32},
})

local count = 3
local buf = Stride.NewBuffer(Entity, count)

-- write initial entities (packed back-to-back)
local at = 0
for i = 1, count do
	at = Stride.Push(Entity, {
		x = i * 10,
		y = i * 5,
		vx = 1 + i * 0.1,
		vy = 0.5 + i * 0.1,
		health = 100,
	}, buf, at)
end

-- x += vx, y += vy (for all records)
Stride.UpdateAddF32(Entity, buf, count, "x", "vx")
Stride.UpdateAddF32(Entity, buf, count, "y", "vy")

-- entities[2].health -= 10
do
	local stride = Entity.Size
	local off = Entity.ByName.health.Offset
	local p = (2 - 1) * stride + off
	buffer.writef32(buf, p, buffer.readf32(buf, p) - 10)
end

-- remove index 1 via swap-with-last (like the native example)
do
	local stride = Entity.Size
	local removeIndex = 1
	local lastIndex = count

	if removeIndex ~= lastIndex then
		buffer.copy(buf, (removeIndex - 1) * stride, buf, (lastIndex - 1) * stride, stride)
	end

	count -= 1
end
```
