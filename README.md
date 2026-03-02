# native
```lua
type NativeEntity = {
  x: number,
  y: number,
  vx: number,
  vy: number,
  health: number,
}

local entities = table.create(3) :: {NativeEntity}

for i = 1, 3 do
  entities[i] = {
    x = i * 10,
    y = i * 5,
    vx = 1 + i * 0.1,
    vy = 0.5 + i * 0.1,
    health = 100,
  }
end

for i = 1, #entities do
  local e = entities[i]
  e.x = e.x + e.vx
  e.y = e.y + e.vy
end

entities[2].health = entities[2].health - 10

local removeIndex = 1
local last = #entities
entities[removeIndex] = entities[last]
entities[last] = nil
```
# stride
```lua
local Stride = require(game.ReplicatedStorage.Stride)

local Layout = Stride.Layout({
  {name = "x", _type = "f32"},
  {name = "y", _type = "f32"},
  {name = "vx", _type = "f32"},
  {name = "vy", _type = "f32"},
  {name = "health", _type = "f32"},
})

local store = Stride.new(Layout, 3)

local getX, setX = store:Accessor("x")
local getY, setY = store:Accessor("y")
local _, setVx = store:Accessor("vx")
local _, setVy = store:Accessor("vy")
local getHealth, setHealth = store:Accessor("health")

local first = store:CreateMany(3)
for i = 1, 3 do
  local id = first + i - 1
  setX(id, i * 10)
  setY(id, i * 5)
  setVx(id, 1 + i * 0.1)
  setVy(id, 0.5 + i * 0.1)
  setHealth(id, 100)
end

store:Accumulate("x", "vx")
store:Accumulate("y", "vy")

setHealth(2, getHealth(2) - 10)

store:Destroy(1)
```
