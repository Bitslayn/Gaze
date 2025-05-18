--[[
____  ___ __   __
| __|/ _ \\ \ / /
| _|| (_) |> w <
|_|  \___//_/ \_\
FOX's Gaze API v1.0.0-dev2

Contributors:
  ChloeSpacedOut - Automatic Gaze
  Lexize - Deterministic Random

Testers: Jcera, XanderCrates, OhItsElectric, AuriaFoxGirl

--]]

--#REGION ˚♡ Assert ♡˚

---`FOXAPI` Raises an error if the value of its argument v is false (i.e., `nil` or `false`); otherwise, returns all its arguments. In case of error, `message` is the error object; when absent, it defaults to `"assertion failed!"`
---@generic T
---@param v? T
---@param message? any
---@param level? integer
---@return T v
local function assert(v, message, level)
  return v or error(message or "Assertion failed!", (level or 1) + 1)
end

--#ENDREGION
--#REGION ˚♡ Random ♡˚

---@class Random.Kate
---@field seed integer
---@operator call(): number

local randomMetatable = {
  ---@param self Random.Kate
  __call = function(self, m)
    local v = math.sin(self.seed) * 43758.5453123
    local num = v - math.floor(v)
    self.seed = math.floor(num * ((2 ^ 31) - 1))
    return math.floor(math.lerp(1, m, num))
  end,
}

local random = {}

---@return Random.Kate
function random.new()
  return setmetatable({ seed = 0 }, randomMetatable)
end

---@param str string
local function stringRandom(str)
  local n = 0
  for _, v in pairs({ string.byte(str, 1, #str) }) do
    n = n + v
  end
  return n
end

--#ENDREGION
--#REGION ˚♡ Gaze ♡˚

--#REGION ˚♡ Common ♡˚

local vec_i = figuraMetatables.Vector3.__index

---Safely gets the eye pos from the gaze target entity
---@param entity Entity
---@return Vector3
local function getEyePos(entity)
  local vecSuccess, eyeOffset = pcall(vec_i, entity:getVariable().eyePos, "xyz")
  return entity:getPos():add(0, entity:getEyeHeight(), 0):add(vecSuccess and eyeOffset or nil)
end

---Returns the gaze pos, getting it from the entity eye height if the target is an entity
---@param target FOXGazeTarget
---@return Vector3
local function getGazePos(target)
  return target and target.getUUID and getEyePos(target --[[@as Entity]]) or target --[[@as Vector3]]
end

---Converts a position relative to where the player is facing
---@param pos Vector3
---@return number, number, boolean
local function getEyeDir(pos)
  local targetDir = (pos - getEyePos(player)):normalize()
  local eyeDir = matrices.mat4():rotate(player:getRot().xy_):apply(targetDir)

  local x, y, z = eyeDir:unpack()
  x = z < 0 and (x <= 0 and 1 or -1) or -x -- Avoid looking through the skull

  return x, y, z > 0
end

---Checks if the position is obscured
---@param pos Vector3
---@return boolean
local function isObscured(pos)
  local hit = select(2, raycast:block(getEyePos(player), pos, "VISUAL"))
  local isBehindWall = (hit - pos):length() > 1
  return isBehindWall
end

--#ENDREGION
--#REGION ˚♡ Update ♡˚

local oldOffsetRot, newOffsetRot = vec(0, 0, 0), vec(0, 0, 0)
local viewer = client:getViewer()

---@param self FOXGaze
---@param isRender boolean
local function updateGaze(self, isRender)
  if isRender then
    local delta = client:getFrameTime()

    vanilla_model.HEAD:setOffsetRot(math.lerp(oldOffsetRot, newOffsetRot, delta) * self.config.turnStrength)
    for _, object in pairs(self.children) do object.render(object, delta) end
  else
    local target = viewer:getVariable("FOXGaze.globalGaze") or self.override or self.target
    local time = world.getTime()

    self.random.seed = time * self.seed

    local x, y
    if type(target) ~= "Vector2" then
      local gazePos = getGazePos(target)
      if gazePos and time % 20 == 0 and isObscured(gazePos) then
        target = nil
      end

      if target then
        x, y = getEyeDir(gazePos)
      else
        local headRot = ((vanilla_model.HEAD:getOriginRot() + 180) % 360 - 180).xy
        x, y = vectors.angleToDir(headRot):mul(1, -1):unpack()
      end
    else
      x, y = target:unpack()
    end

    oldOffsetRot = newOffsetRot
    newOffsetRot = math.lerp(oldOffsetRot, target and vec(y, -x, 0) or vec(0, 0, 0), 0.5)

    x, y = -x, -y

    for _, object in pairs(self.children) do object.tick(object, x, y, time) end
  end
end

--#ENDREGION
--#REGION ˚♡ Focus ♡˚

--#REGION ˚♡ Random (unfocused) ♡˚

-- Written by ChloeSpacedOut :3

---@param self FOXGaze
---@param lookDir Vector3
local function blockGaze(self, lookDir)
  local lookOffset = vec(self.random(100) - 50, self.random(100) - 50)
  local lookRot = vectors.rotateAroundAxis(lookOffset.x, lookDir, vec(1, 0, 0))
  lookRot = vectors.rotateAroundAxis(lookOffset.y, lookRot, vec(0, 1, 0))
  local eyePos = getEyePos(player)
  local _, pos = raycast:block(eyePos, lookRot * 50 + eyePos, "VISUAL")
  return pos
end

local viewRange = vec(4, 4, 4)

---@param lookDir Vector3
local function entityGaze(_, lookDir)
  local seenEntities = {}
  local playerPos = player:getPos()
  local viewCenter = playerPos + lookDir * 4
  local entities = world.getEntities(viewCenter - viewRange, viewCenter + viewRange)

  if #entities > 20 then return seenEntities end

  for _, entity in pairs(entities) do
    if player ~= entity then
      local pos = entity:getPos()
      local distance = (pos - playerPos):length()
      local speedMod = (entity:getVelocity():length() + 1) * 1000

      table.insert(seenEntities, {
        lookChance = 20 / distance * speedMod,
        entity = entity,
      })
    end
  end

  return seenEntities
end

---@param self FOXGaze
---@param seenEntities {lookChance: number, entity: Entity}
---@param rarityCount number
local function pullRandomEntity(self, seenEntities, rarityCount)
  local count = 0
  for _, seenEntity in ipairs(seenEntities) do
    count = count + seenEntity.lookChance
    if count >= self.random(rarityCount) then
      return seenEntity.entity
    end
  end
end

--#ENDREGION
--#REGION ˚♡ Contextual (focused) ♡˚

-- Set the target gaze to an entity if you're moving fast or swing

---@param self FOXGaze
local function swingGaze(self)
  if self.focus ~= 0 then return end
  if player:getVelocity().x_z:length() < 0.25 and player:getSwingTime() ~= 1 then return end

  self.focus = world.getTime() % self.config.dynamicsCooldown + 1
  self.target = player:getTargetedEntity(5)
end

-- Set gaze based on sounds

local soundQueue

function events.on_play_sound(sound, pos, volume)
  soundQueue = { sound, pos, volume }
end

---@param self FOXGaze
---@param sound string
---@param pos Vector3
---@param volume number
local function soundGaze(self, sound, pos, volume)
  if self.focus ~= 0 then return end
  if string.find(sound, "step") then return end

  local distance = (player:getPos() - pos):length()
  if distance < 1 or self.random(100) >= self.config.soundInterest * 200 / distance * volume then return end

  self.focus = self.config.dynamicsCooldown
  self.target = pos
end

-- Set gaze to attacker if the player takes damage

local damageQueue

function events.damage(_, attacker)
  damageQueue = { attacker }
end

---@param self FOXGaze
---@param attacker Entity
local function damageGaze(self, attacker)
  if self.focus ~= 0 then return end

  self.focus = world.getTime() % self.config.dynamicsCooldown + 1
  self.target = attacker
end

-- Set gaze to player that's chatting

local chatQueue

---@param chatterName string
function pings.chatGaze(chatterName)
  chatQueue = { chatterName }
end

---@param self FOXGaze
---@param chatterName string
local function chatGaze(self, chatterName)
  self.focus = world.getTime() % self.config.dynamicsCooldown + 1
  self.target = world.getPlayers()[chatterName]
end

function events.chat_receive_message(_, json)
  if not player:isLoaded() then return end
  json = parseJson(json)
  if not json.with then return end
  local chatterName = json.with[1]
  local chatter = world.getPlayers()[chatterName]
  if not chatter or chatter == player or (player:getPos() - chatter:getPos()):length() > 5 then return end
  local visible = select(3, getEyeDir(getEyePos(chatter)))
  if not visible then return end

  pings.chatGaze(chatterName)
end

--#ENDREGION
--#REGION ˚♡ Controller ♡˚

---Determine gaze from visible blocks or entities
---@param self FOXGaze
local function gazeController(self)
  swingGaze(self)

  if soundQueue then
    soundGaze(self, table.unpack(soundQueue))
  end
  if damageQueue then
    damageGaze(self, table.unpack(damageQueue))
  end
  if chatQueue then
    chatGaze(self, table.unpack(chatQueue))
  end

  if self.focus > 0 then
    self.focus = self.focus - 1
    return
  end

  local time = world.getTime()
  self.random.seed = time * self.seed
  if time % 5 ~= 0 or self.random(100) >= 10 then return end -- Rolls the chance which the player will change their gaze this tick

  local lookDir = player:getLookDir()
  local seenEntities = entityGaze(self, lookDir)

  if #seenEntities ~= 0 and self.random(100) < self.config.socialInterest * 100 then
    local rarityCount = 0
    for _, v in pairs(seenEntities) do
      rarityCount = rarityCount + v.lookChance
    end
    self.target = pullRandomEntity(self, seenEntities, rarityCount)
    if self.target and isObscured(getGazePos(self.target)) then
      self.target = blockGaze(self, lookDir)
    end
  else
    self.target = blockGaze(self, lookDir)
  end
end

--#ENDREGION

--#ENDREGION
--#REGION ˚♡ Loop ♡˚

---@type FOXGaze[]
local gazes = {}

function events.tick()
  for _, gazeObject in pairs(gazes) do
    if gazeObject.enabled then
      gazeController(gazeObject)
      gazeObject(false)
    end
  end
  soundQueue, damageQueue, chatQueue = nil, nil, nil
end

function events.render()
  for _, gazeObject in pairs(gazes) do
    if gazeObject.enabled then
      gazeObject(true)
    end
  end
end

--#ENDREGION

--#ENDREGION
--#REGION ˚♡ Classes ♡˚

--#REGION ˚♡ FOXGaze.Generic ♡˚

---@class FOXGaze.Generic
---@field package tick fun(self: FOXGaze.Generic, x: number, y: number, time: number)
---@field package render fun(self: FOXGaze.Generic, delta: number)
---@field package zero fun(self: FOXGaze.Generic)
local generic = {}

---@generic self
---@param self self
---@return self
function generic:enable()
  self.enabled = true
  return self
end

---@generic self
---@param self self
---@return self
function generic:disable()
  self.enabled = false
  return self
end

---@generic self
---@param self self
---@param boolean boolean
---@return self
function generic:setEnabled(boolean)
  self.enabled = boolean
  return self
end

--#ENDREGION
--#REGION ˚♡ FOXGaze.Eye ♡˚

---@class FOXGaze.Eye: FOXGaze.Generic
---@field package enabled boolean
---@field element ModelPart
---@field left number
---@field right number
---@field up number
---@field down number
---@field horizontal boolean
---@field package lerp {old: Vector3, new: Vector3}
local eye = {}

local eyeMeta = {
  __type = "FOXGaze.Eye",
  __index = function(_, key)
    return eye[key] or generic[key]
  end,
}

---@param x number
---@param y number
function eye:tick(x, y)
  if not self.enabled then return end

  x, y = -x, -y

  local eyeX = x < 0 and x * self.left or x * self.right
  local eyeY = y < 0 and y * self.down or y * self.up

  self.lerp.old = self.lerp.new
  self.lerp.new = self.horizontal and vec(0, eyeY, eyeX) or vec(eyeX, eyeY, 0)
end

function eye:render(delta)
  if not self.enabled then return end
  self.element:setPos(math.lerp(self.lerp.old, self.lerp.new, delta))
end

function eye:zero()
  self.element:setPos()
end

--#ENDREGION
--#REGION ˚♡ FOXGaze.Animation ♡˚

---@class FOXGaze.Animation: FOXGaze.Generic
---@field package enabled boolean
---@field horizontal Animation
---@field vertical Animation
---@field package lerp {old: Vector2, new: Vector2}
local anim = {}

local animMeta = {
  __type = "FOXGaze.Animation",
  __index = function(_, key)
    return anim[key] or generic[key]
  end,
}

---@param x number
---@param y number
function anim:tick(x, y)
  if not self.enabled then return end

  self.lerp.old = self.lerp.new
  self.lerp.new = vec(x, y)
end

function anim:render(delta)
  if not self.enabled then return end

  local x, y = math.lerp(self.lerp.old, self.lerp.new, delta):add(1, 1):div(2, 2):unpack()
  self.horizontal:setTime(x)
  self.vertical:setTime(y)
end

function anim:zero()
  self.horizontal:setTime(0.5)
  self.vertical:setTime(0.5)
end

--#ENDREGION
--#REGION ˚♡ FOXGaze.UV ♡˚

---@class FOXGaze.UV: FOXGaze.Generic
---@field package enabled boolean
---@field element ModelPart
local uv = {}

local uvMeta = {
  __type = "FOXGaze.Animation",
  __index = function(_, key)
    return uv[key] or generic[key]
  end,
}

---@param x number
---@param y number
function uv:tick(x, y)
  if not self.enabled then return end

  local UV = vec(math.round(x), math.round(y)):div(3, 3)
  self.element:setUV(UV)
end

function uv:render() end

function uv:zero()
  self.element:setUVPixels()
end

--#ENDREGION
--#REGION ˚♡ FOXGaze.Blink ♡˚

---@class FOXGaze.Blink: FOXGaze.Generic
---@field package enabled boolean
---@field animation Animation
---@field frequency number
---@field package timer number
---@field package parent FOXGaze
local blink = {}

local blinkMeta = {
  __type = "FOXGaze.Blink",
  __index = function(_, key)
    return blink[key] or generic[key]
  end,
}

function blink:tick(_, _, time)
  if not self.enabled then return end
  if player:getPose() == "SLEEPING" then return end
  if time % self.frequency == 0 and self.parent.random(100) < 5 then
    self.animation:play()
  end
end

function blink:render() end

function blink:zero()
  self.animation:stop()
end

--#ENDREGION
--#REGION ˚♡ FOXGaze ♡˚

---@class FOXGaze.Any: FOXGaze.Eye, FOXGaze.Animation, FOXGaze.UV, FOXGaze.Blink

---@class FOXGaze: FOXGaze.Generic
---@field package enabled boolean
---@field package target FOXGazeTarget
---@field package override FOXGazeTarget
---@field package random Random.Kate
---@field package children FOXGaze.Any
---@field package seed number
---@field package focus number
---@field config {socialInterest: number, soundInterest: number, dynamicsCooldown: number, turnStrength: number}
local gaze = {}

local gazeMeta = {
  __type = "FOXGaze",
  __index = function(_, key)
    return gaze[key] or generic[key]
  end,
  __call = updateGaze,
}

---@param self FOXGaze
---@param element ModelPart
---@param left number?
---@param right number?
---@param up number?
---@param down number?
---@param horizontal boolean?
---@return FOXGaze.Eye
function gaze:newEye(element, left, right, up, down, horizontal)
  local object = setmetatable({
    enabled = true,
    element = element,
    left = left or 0.25,
    right = right or 1.25,
    up = up or 0.5,
    down = down or 0.5,
    horizontal = horizontal,
    lerp = { old = vec(0, 0), new = vec(0, 0) },
  }, eyeMeta)
  table.insert(self.children, object)
  return object
end

---@param self FOXGaze
---@param horizontal Animation
---@param vertical Animation
---@return FOXGaze.Animation
function gaze:newAnim(horizontal, vertical)
  local check = (horizontal and horizontal.play) and (vertical and vertical.play)
  assert(check, "Illegal arguments! Expected 2 animations!", 2)

  horizontal:play():pause():setTime(0.5)
  vertical:play():pause():setTime(0.5)

  local object = setmetatable({
    enabled = true,
    horizontal = horizontal,
    vertical = vertical,
    lerp = { old = vec(0, 0), new = vec(0, 0) },
  }, animMeta)
  table.insert(self.children, object)
  return object
end

---@param self FOXGaze
---@param element ModelPart
---@return FOXGaze.UV
function gaze:newUV(element)
  local object = setmetatable({
    enabled = true,
    element = element,
  }, uvMeta)
  table.insert(self.children, object)
  return object
end

---@param animation Animation
---@param frequency number?
---@return FOXGaze.Blink
function gaze:newBlink(animation, frequency)
  local object = setmetatable({
    enabled = true,
    animation = animation,
    frequency = frequency or 7,
    parent = self,
  }, blinkMeta)
  table.insert(self.children, object)
  return object
end

---@param target FOXGazeTarget
---@return FOXGaze
function gaze:setGaze(target)
  self.override = target
  return self
end

---@param override boolean
---@return FOXGazeTarget
function gaze:getGaze(override)
  return self[override and "override" or "target"]
end

---@return FOXGaze
function gaze:zero()
  self.target = nil
  vanilla_model.HEAD:setOffsetRot()
  for _, object in pairs(self.children) do
    object:zero()
  end
  return self
end

--#ENDREGION
--#REGION ˚♡ FOXGazeAPI ♡˚

---@alias FOXGazeTarget Vector2|Vector3|Entity

---@class FOXGazeAPI
local api = {}

---@param name string?
---@return FOXGaze
function api:newGaze(name)
  local objectSeed = client.uuidToIntArray(avatar:getUUID()) % 512 + 1
  local nameSeed = (name and stringRandom(name) or 0) % 512 + 1

  local object = setmetatable({
    name = name or tostring(math.random()),
    enabled = true,
    target = nil,
    override = nil,
    random = random.new(),
    focus = 0,
    config = {
      socialInterest = 0.8,
      soundInterest = 0.5,
      dynamicsCooldown = 40,
      turnStrength = 22.5,
    },
    children = {},
    seed = objectSeed * nameSeed,
  }, gazeMeta)
  gazes[object.name] = object
  return object
end

---@param target FOXGazeTarget
function api:setGlobalGaze(target)
  avatar:store("FOXGaze.globalGaze", target)
end

--#ENDREGION

--#ENDREGION

return api
