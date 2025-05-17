--[[
____  ___ __   __
| __|/ _ \\ \ / /
| _|| (_) |> w <
|_|  \___//_/ \_\
FOX's Gaze API v1.0.0-dev

Credits:
  Automatic Gaze - ChloeSpacedOut
  Deterministic Random - Lexize
  Emotional Support - Vicky

Testers:
  Jcera
  ChloeSpacedOut
  XanderCrates
  OhItsElectric
  AuriaFoxGirl

TODO change photoMode to a viewer override that forces everyone's gaze onto a position or entity
TODO fix chat message name detection
TODO make getting eye height safer

TODO make a "gaze" an object which can be enabled, disabled, configured, and created.
TODO make gaze objects able to have separate targets and target overrides
TODO add methods for getting the current gaze block or entity
(Also to allow skulls to have their own gaze that isn't just a mirror of the player's eye position)


--]]

--#REGION ˚♡ Library ♡˚

---@class GazeAPI
local GazeAPI = {}
---@class Gaze
local GazeObject = {}
---@class Gaze.Metatable
local GazeMeta = { __index = GazeObject }

---@type Gaze.Generic[]
local objects = {}

local gazeOverride, currentGaze
local oldOffsetRot, newOffsetRot = vec(0, 0, 0), vec(0, 0, 0)

avatar:store("Gaze.photoMode", false)

local gazeSeed = client.uuidToIntArray(avatar:getUUID()) % 512 + 1

local focusTimer = 0

-- variables that control the gazing. Put them here so you can easily access them and put them in a metatable or something
local socialInterest = 0.7 -- how likley to look at entities compared to blocks
local soundInterest = 0.5  -- how likley it is to look at sounds
local attentionSpan = 20   -- How many ticks until the player loses focus

---`FOXAPI` Raises an error if the value of its argument v is false (i.e., `nil` or `false`); otherwise, returns all its arguments. In case of error, `message` is the error object; when absent, it defaults to `"assertion failed!"`
---@generic T
---@param v? T
---@param message? any
---@param level? integer
---@return T v
function assert(v, message, level)
  return v or error(message or "Assertion failed!", (level or 1) + 1)
end

---Safely gets the eye pos from the gaze target entity
---@param entity Entity
---@return Vector3
local function getEyePos(entity)
  local eyePos = vec(0, entity:getEyeHeight(), 0)
  local eyeOffset = entity:getVariable().eyePos
  eyePos = eyeOffset and eyeOffset.unpack and eyePos:add(eyeOffset:unpack()) or eyePos
  return entity:getPos():add(eyePos --[[@as Vector3]])
end

---Returns the gaze pos, getting it from the entity eye height if the target is an entity
---@param target Entity|Vector3
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

---Checks if the position is obscured, being behind a block from the player, or in the dark
---@param pos Vector3
---@return boolean
local function isObscured(pos)
  pos = getGazePos(pos)
  local hit = select(2, raycast:block(getEyePos(player), pos, "VISUAL"))
  local isBehindWall = (hit - pos):length() > 1

  local playerNbt = player:getNbt()
  local effects = playerNbt.ActiveEffects or playerNbt.active_effects
  local json = tostring(toJson(effects))
  local isNightVision = json:find('"Id":16') or json:find("night_vision")

  if isNightVision then
    return isBehindWall
  else
    local block, sky = world.getLightLevel(pos), world.getSkyLightLevel(pos)
    return isBehindWall or (block < 3 and sky < 3)
  end
end

---@class Random
---@field seed integer
---@operator call(): number

local randomMetatable = {
  ---@param self Random
  __call = function(self, a, b)
    local v = math.sin(self.seed) * 43758.5453123;
    local num = v - math.floor(v);
    self.seed = math.floor(num * ((2 ^ 31) - 1));
    if (type(a) == "number" and type(b) == "number") then
      v = math.lerp(a, b, num);
      return math.floor(v);
    elseif (type(a) == "number") then
      return math.floor(math.lerp(1, a, num))
    else
      return num;
    end
  end,
}

local defaultRandom;

local random = {}

---@param seed? integer
---@return Random
function random.new(seed)
  return setmetatable(
    {
      seed = seed or math.random((2 ^ 31) - 1),
    },
    randomMetatable
  )
end

defaultRandom = random.new(math.random((2 ^ 31) - 1));

---@return Random
function random.static()
  return defaultRandom;
end

local rng = random.new()
local soundRng = random.new()

--#REGION ˚♡ Automatic gaze ♡˚

--#REGION ˚♡ Random (unfocused) ♡˚

-- Written by ChloeSpacedOut :3

local function blockGaze(lookDir)
  local lookOffset = vec(rng(100) - 50, rng(100) - 50)
  local lookRot = vectors.rotateAroundAxis(lookOffset.x, lookDir, vec(1, 0, 0))
  lookRot = vectors.rotateAroundAxis(lookOffset.y, lookRot, vec(0, 1, 0))
  local eyePos = getEyePos(player)
  local _, pos = raycast:block(eyePos, lookRot * 50 + eyePos, "VISUAL")
  return pos
end

local viewRange = vec(4, 4, 4)
local function entityGaze(lookDir)
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

local function pullRandomEntity(seenEntities, rarityCount)
  local count = 0
  for _, seenEntity in ipairs(seenEntities) do
    count = count + seenEntity.lookChance
    if count >= rng(rarityCount) then
      return seenEntity.entity
    end
  end
end

-- Determine gaze from visible blocks or entities

function events.tick()
  if focusTimer > 0 then
    focusTimer = focusTimer - 1
    return
  end

  local time = world.getTime()
  rng.seed = time * gazeSeed
  if time % 5 ~= 0 or rng(100) >= 10 then return end -- Rolls the chance which the player will change their gaze this tick

  local lookDir = player:getLookDir()
  local seenEntities = entityGaze(lookDir)

  if #seenEntities ~= 0 and rng(100) < socialInterest * 100 then
    local rarityCount = 0
    for _, v in pairs(seenEntities) do
      rarityCount = rarityCount + v.lookChance
    end
    currentGaze = pullRandomEntity(seenEntities, rarityCount)
    if isObscured(currentGaze) then
      currentGaze = blockGaze(lookDir)
    end
  else
    currentGaze = blockGaze(lookDir)
  end
end

--#ENDREGION
--#REGION ˚♡ Contextual (focused) ♡˚

-- Set gaze based on sounds

function events.on_play_sound(_, pos, volume)
  if not player:isLoaded() then return end
  if focusTimer ~= 0 then return end

  local time = world.getTime(client:getFrameTime())
  soundRng.seed = time * gazeSeed

  local distance = (player:getPos() - pos):length()
  if distance < 1 or soundRng(100) >= soundInterest * 200 / distance * volume then return end

  focusTimer = attentionSpan
  currentGaze = pos
end

-- Set the target gaze to an entity if you're moving fast or swing

function events.tick()
  if focusTimer ~= 0 then return end
  if player:getVelocity().x_z:length() < 0.25 and player:getSwingTime() ~= 1 then return end

  focusTimer = attentionSpan
  currentGaze = player:getTargetedEntity(5)
end

-- Set gaze to attacker if the player takes damage

function events.damage(_, attacker)
  if focusTimer ~= 0 then return end

  focusTimer = attentionSpan
  currentGaze = attacker
end

-- Set gaze to player that's chatting

---@param chatterName string
function pings.chatGaze(chatterName)
  focusTimer = attentionSpan
  currentGaze = world.getPlayers()[chatterName]
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

--#ENDREGION
--#REGION ˚♡ Loops ♡˚

local viewer = client:getViewer()

function events.tick()
  local cameraPos = viewer:getVariable("Gaze.photoMode") and client:getCameraPos()
  local thisGaze = cameraPos or gazeOverride or currentGaze
  local time = world.getTime()

  local x, y
  local gazePos = getGazePos(thisGaze)
  if gazePos and thisGaze == currentGaze and time % 20 == 0 and isObscured(gazePos) then
    thisGaze, currentGaze = nil, nil
  end

  if thisGaze then
    x, y = getEyeDir(gazePos)
  else
    local headRot = ((vanilla_model.HEAD:getOriginRot() + 180) % 360 - 180).xy
    x, y = vectors.angleToDir(headRot):mul(1, -1):unpack()
  end

  oldOffsetRot = newOffsetRot
  newOffsetRot = math.lerp(oldOffsetRot, thisGaze and vec(y, -x, 0) or vec(0, 0, 0), 0.5)

  x, y = -x, -y
  for _, object in pairs(objects) do object.tick(object, x, y, time) end
end

function events.render(delta)
  vanilla_model.HEAD:setOffsetRot(math.lerp(oldOffsetRot, newOffsetRot, delta) * 22.5)

  for _, object in pairs(objects) do object.render(object, delta) end
end

--#ENDREGION

--#ENDREGION
--#REGION ˚♡ API ♡˚

---@class Gaze.Generic
---@field package tick fun(self: Gaze.Generic, x: number, y: number, time: number)
---@field package render fun(self: Gaze.Generic, delta: number)
---@field package zero fun(self: Gaze.Generic)

--#REGION ˚♡ Eye ♡˚

---@class Gaze.Eye: Gaze, Gaze.Generic
---@field package enabled boolean
---@field horizontal Animation
---@field vertical Animation
---@field package lerp {old: Vector2, new: Vector2}

---@param self Gaze.Eye
---@param x number
---@param y number
local function eyeTick(self, x, y)
  if not self.enabled then return end

  self.lerp.old = self.lerp.new
  self.lerp.new = vec(x, y)
end

---@param self Gaze.Eye
---@param delta number
local function eyeRender(self, delta)
  if not self.enabled then return end
  local x, y = math.lerp(self.lerp.old, self.lerp.new, delta)
      ---@diagnostic disable-next-line: param-type-mismatch
      :add(1, 1):div(2, 2):unpack()

  self.horizontal:setTime(x)
  self.vertical:setTime(y)
end

local function eyeZero(self)
  self.horizontal:setTime(0.5)
  self.vertical:setTime(0.5)
end

---Creates a new eye. Takes in arguments defining how far the eye can move. Multiple eyes can be defined by running the function multiple times
---
---The modelpart's neutral position is where it will be when the gaze is directly in front of the face
---
---Returns an object that can be used to disable the eye or remove it entirely
---@param horizontal Animation
---@param vertical Animation
---@return Gaze.Eye
function GazeAPI.newEye(horizontal, vertical)
  horizontal:play():pause():setTime(0.5)
  vertical:play():pause():setTime(0.5)

  local eye = setmetatable({
    enabled = true,

    horizontal = horizontal,
    vertical = vertical,

    lerp = { old = vec(0, 0), new = vec(0, 0) },

    tick = eyeTick,
    render = eyeRender,
    zero = eyeZero,
  }, GazeMeta --[[@as Gaze.Eye]])
  objects[eye] = eye
  return eye
end

--#ENDREGION
--#REGION ˚♡ Pixel Eye ♡˚

---@class Gaze.EyeUV: Gaze, Gaze.Generic
---@field package enabled boolean
---@field element ModelPart

---@param self Gaze.EyeUV
---@param x number
---@param y number
local function eyeUVTick(self, x, y)
  if not self.enabled then return end

  local UV = vec(math.round(x), math.round(y)):div(3, 3)
  self.element:setUV(UV)
end

local function eyeUVRender() end

---@param self Gaze.EyeUV
local function eyeUVZero(self)
  self.element:setUVPixels()
end

---Creates a new UV eye. This will set the UV based on the player's gaze
---
---Returns an object that can be used to disable the eye or remove it entirely
---@param element ModelPart
---@return Gaze.EyeUV
function GazeAPI.newEyeUV(element)
  local eye = setmetatable({
    enabled = true,

    element = element,

    tick = eyeUVTick,
    render = eyeUVRender,
    zero = eyeUVZero,
  }, GazeMeta --[[@as Gaze.EyeUV]])
  objects[eye] = eye
  return eye
end

--#ENDREGION
--#REGION ˚♡ Blink ♡˚

---@class Gaze.Blink: Gaze, Gaze.Generic
---@field enabled boolean
---@field animation Animation
---@field frequency number
---@field package timer number

local function blinkTick(self, _, _, time)
  if not self.enabled then return end
  if player:getPose() == "SLEEPING" then return end
  if time % self.frequency == 0 and rng(100) < 5 then
    self.animation:play()
  end
end

local function blinkRender() end

local function blinkZero(self)
  self.animation:stop()
end

---Sets a new animation to use for blinking. Multiple blinking animations can be created by running the function multiple times
---
---Returns an object that can be used to disable the blink animation or remove it entirely
---@param animation Animation
---@param frequency number?
---@return Gaze.Blink
function GazeAPI.newBlink(animation, frequency)
  local blink = setmetatable({
    enabled = true,

    animation = animation,
    frequency = frequency or 7,

    tick = blinkTick,
    render = blinkRender,
    zero = blinkZero,
  }, GazeMeta --[[@as Gaze.Blink]])
  objects[blink] = blink
  return blink
end

--#ENDREGION
--#REGION ˚♡ Generic Object ♡˚

---Enables this object
---@generic self
---@param self self
---@return self
function GazeObject:enable()
  self.enabled = true
  return self
end

---Disables this object
---@generic self
---@param self self
---@return self
function GazeObject:disable()
  self.enabled = false
  return self
end

---Sets this object's enabled state to the provided boolean
---@generic self
---@param self self
---@param boolean boolean
---@return self
function GazeObject:setEnabled(boolean)
  self.enabled = boolean
  return self
end

---Permanently deletes this object
---@generic self
---@param self self
function GazeObject:flush()
  objects[self] = nil
end

---Resets this object, useful when you are also disabling the object
---@generic self
---@param self self
---@return self
function GazeObject:zero()
  self --[[@as Gaze.Generic]]:zero()
  return self
end

--#ENDREGION
--#REGION ˚♡ Management ♡˚

---Overrides the current gaze to the provided block position or entity uuid
---
---If set to nil, reverts the gaze to being managed by the library
---@param gaze Vector3|Entity? Block coordinate or uuid
function GazeAPI.setGaze(gaze)
  local t = type(gaze)
  assert(t == "Vector3" or t == "nil" or gaze.getUUID,
    "The gaze must be set to either a valid entity or a world coordinate", 2)

  gazeOverride = gaze
end

--#ENDREGION

--#ENDREGION

return GazeAPI
