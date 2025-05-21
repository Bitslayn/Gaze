--[[
____  ___ __   __
| __|/ _ \\ \ / /
| _|| (_) |> w <
|_|  \___//_/ \_\
FOX's Gaze API v1.0.0

Contributors:
  ChloeSpacedOut - Automatic Gaze
  Lexize - Deterministic Random
  Vicky - Wiki

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
  __call = function(self, a, b)
    local v = math.sin(self.seed) * 43758.5453123
    local num = v - math.floor(v)
    self.seed = math.floor(num * ((2 ^ 31) - 1))
    return a and math.floor(math.lerp(b and a or 1, b or a, num)) or num
  end,
}

local random = {}

---@param seed? integer
---@return Random.Kate
function random.new(seed)
  return setmetatable(
    {
      seed = seed or 0,
    },
    randomMetatable
  )
end

local avatarUUIDInt = client.uuidToIntArray(avatar:getUUID())
local uuidRng = random.new(avatarUUIDInt)

--#ENDREGION
--#REGION ˚♡ Particles ♡˚

---@param a Vector3
---@param b Vector3
local function drawLine(a, b)
  particles["minecraft:end_rod"]
      :setPos(math.lerp(a, b, math.random()))
      :setLifetime(math.round((a - b):length()))
      :setScale(0.25)
      :spawn()
  particles["minecraft:end_rod"]
      :setPos(b)
      :setLifetime(1)
      :setScale(0.5)
      :setColor(vectors.hexToRGB("#fc6c85"))
      :spawn()
end

--#ENDREGION
--#REGION ˚♡ UUID Generator ♡˚

---@param rng Random.Kate
local function newUUID(rng)
  local ints = {}
  for _ = 1, 4 do
    table.insert(ints, rng(-2147483648, 2147483647))
  end
  return client.intUUIDToString(table.unpack(ints))
end

--#ENDREGION
--#REGION ˚♡ Gaze ♡˚

--#REGION ˚♡ Common ♡˚

local vec_i = figuraMetatables.Vector3.__index

---@type FOXGaze
local primaryGaze

---Safely gets the eye pos from the gaze target entity
---@param self FOXGaze
---@return Vector3
local function getHeadPos(self)
  return (self.eyePivot or self.head):partToWorldMatrix():apply()
end

---Gets the eular rotation of the head part
---@param head ModelPart
---@return Vector3
local function getHeadRot(head)
  local headMat = head:partToWorldMatrix()
  if headMat.v11 ~= headMat.v11 then return vec(0, 0, 0) end -- NaN check
  local dir = headMat:applyDir(0, 0, -1)
  return vec(
    math.atan2(dir.y, dir.xz:length()),
    math.atan2(dir.x, dir.z),
    0
  ):toDeg():mul(-1, -1, 1)
end

---Safely gets the eye pos from the gaze target entity
---@param entity Entity
---@return Vector3
local function getEyePos(entity)
  local vecSuccess, eyeOffset = pcall(vec_i, entity:getVariable().eyePos, "xyz")
  return entity:getPos():add(0, entity:getEyeHeight(), 0):add(vecSuccess and eyeOffset or nil)
end

---Returns the gaze pos, getting it from the entity eye height if the target is an entity
---
---Only used for gaze targets
---@param target FOXGazeTarget
---@return Vector3
local function getTargetPos(target)
  return target and target.getUUID and getEyePos(target --[[@as Entity]]) or
      target --[[@as Vector3]]
end

---Converts a position relative to where the player is facing
---@param self FOXGaze
---@param pos Vector3
---@param particle boolean?
---@return number, number, boolean
local function getEyeDir(self, pos, particle)
  local eyePos, headRot
  if self and self.head then
    eyePos = getHeadPos(self)
    headRot = getHeadRot(self.head)
  else
    eyePos = getEyePos(player)
    headRot = player:getRot().xy_
  end

  local zFlip = math.sign((headRot.y + 90) % 360 - 180) -- Fixes gaze variation between facing positive and negative z

  local targetDir = (pos - eyePos):normalize()
  local eyeDir = matrices.mat4():rotate(headRot:mul(zFlip, 1)):apply(targetDir)

  local x, y, z = eyeDir:unpack()
  x = z < 0 and (x <= 0 and 1 or -1) or -x -- Avoid looking through the skull

  if particle then
    drawLine(eyePos, pos)
  end

  return x, y, z > 0
end

---Checks if the position is obscured
---@param pos Vector3
---@return boolean
local function isObscured(self, pos)
  local hit = select(2,
    raycast:block(self.head and getHeadPos(self) or getEyePos(player), pos, "VISUAL"))
  local isBehindWall = (hit - pos):length() > 1
  return isBehindWall
end

--#ENDREGION
--#REGION ˚♡ Update ♡˚

local viewer = client:getViewer()

---@param self FOXGaze
---@param time number Delta or time
---@param isRender boolean
local function updateGaze(self, time, isRender)
  if isRender then
    if self.head then
      if self.isPrimary then
        self.head:setRot(vanilla_model.HEAD:getOriginRot())
      end
      self.head:setOffsetRot(math.lerp(self.headRot.old, self.headRot.new, time))
    end

    for _, object in pairs(self.children) do object.render(object, time) end
  else
    local target = viewer:getVariable("FOXGaze.globalTarget") or self.override or self.target

    self.random.seed = time * self.seed

    local x, y
    local method

    if type(target) ~= "Vector2" then
      local gazePos = getTargetPos(target)
      if gazePos and time % 20 == 0 and isObscured(self, gazePos) then
        target, self.target = nil, nil
      end

      if target then
        x, y = getEyeDir(self, gazePos, viewer:getVariable("FOXGaze.debugMode"))
        method = target.x and "Blocks" or "Entities"
      else
        local headRot
        if self.head then
          headRot = getHeadRot(self.head).xy
        else
          headRot = ((vanilla_model.HEAD:getOriginRot() + 180) % 360 - 180).xy
        end
        x, y = vectors.angleToDir(headRot):unpack()
        y = -y
        if self.head then
          x, y = -x, -y
        end
        method = "Direction"
      end
    else
      x, y = target:unpack()
      method = "Direction"
    end

    local s = self.config.turnStrength
    self.headRot.target = self.config["face" .. method] and vec(y * s, -x * s, 0) or vec(0, 0, 0)

    self.headRot.old = self.headRot.new
    ---@diagnostic disable-next-line: assign-type-mismatch
    self.headRot.new = math.lerp(self.headRot.old, self.headRot.target, 1 - self.config.turnDampen)

    for _, object in pairs(self.children) do object.tick(object, -x, y, time) end
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
  local eyePos = self.head and getHeadPos(self) or getEyePos(player)
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

-- Set gaze based on sounds

local soundQueue

function events.on_play_sound(sound, pos, volume)
  soundQueue = { sound, pos, volume, world.getTime() }
end

---@param self FOXGaze
---@param sound string
---@param pos Vector3
---@param volume number
local function soundGaze(self, sound, pos, volume)
  if self.config.soundInterest <= 0 then return end
  if string.find(sound, "step") then return end

  local distance = (player:getPos() - pos):length()
  if distance < 1 or self.random(100) >= self.config.soundInterest * 200 / distance * volume then return end
  self.focus = self.config.actionCooldown
  self.target = pos
  soundQueue = nil
  return true
end

-- Set gaze to attacker if the player takes damage

local damageQueue

function events.damage(_, attacker)
  damageQueue = { attacker, world.getTime() }
end

---@param self FOXGaze
---@param attacker Entity
local function damageGaze(self, attacker)
  self.focus = self.config.actionCooldown
  self.target = attacker
  damageQueue = nil
end

-- Set gaze to player that's chatting

local chatQueue

---@param chatterName string
function pings.chatGaze(chatterName)
  chatQueue = { chatterName, world.getTime() }
end

---@param self FOXGaze
---@param chatterName string
local function chatGaze(self, chatterName)
  if self.config.socialInterest <= 0 then return end
  if self.random(100) > (self.config.socialInterest * 100) then return end
  self.focus = self.config.actionCooldown
  self.target = world.getPlayers()[chatterName]
  chatQueue = nil
  return true
end

function events.chat_receive_message(_, json)
  if not player:isLoaded() then return end
  json = parseJson(json)
  if not json.with then return end
  local chatterName = json.with[1]
  local chatter = world.getPlayers()[chatterName]
  if not chatter or chatter == player or (player:getPos() - chatter:getPos()):length() > 5 then return end
  local visible = select(3, getEyeDir(nil, getEyePos(chatter)))
  if not visible then return end

  pings.chatGaze(chatterName)
end

--#ENDREGION
--#REGION ˚♡ Controller ♡˚

---Determine gaze from visible blocks or entities
---@param self FOXGaze
---@param time number
local function gazeController(self, time)
  self.random.seed = math.floor(time / 10) * 10 * self.seed
  self.shouldBlink = time % self.config.blinkFrequency == 0 and self.random(100) < 5

  if not self.config.doRandomGaze then return end

  if self.focus > 0 then
    self.focus = self.focus - 1
  end
  if player:getVelocity().x_z:length() > 0.25 or player:getSwingTime() == 1 then
    self.focus = self.config.actionCooldown
    self.target = player:getTargetedEntity(5)
    return
  end
  if self.focus <= 0 then
    if soundQueue then
      if soundGaze(self, table.unpack(soundQueue)) then return end
    end
    if damageQueue then
      damageGaze(self, table.unpack(damageQueue))
      return
    end
    if chatQueue then
      if chatGaze(self, table.unpack(chatQueue)) then return end
    end
  end

  if time % self.config.lookInterval ~= 0 or self.random(100) >= (self.config.lookChance * 100) then return end -- Rolls the chance which the player will change their gaze this tick

  self.random.seed = time * self.seed

  local lookDir = player:getLookDir()
  local seenEntities = entityGaze(self, lookDir)

  if self.config.socialInterest > 0 and #seenEntities ~= 0 and self.random(100) < (self.config.socialInterest * 100) then
    local rarityCount = 0
    for _, v in pairs(seenEntities) do
      rarityCount = rarityCount + v.lookChance
    end
    self.target = pullRandomEntity(self, seenEntities, rarityCount)
    if self.target and isObscured(self, getTargetPos(self.target)) then
      self.target = blockGaze(self, lookDir)
    end
  else
    self.target = blockGaze(self, lookDir)
  end
end

--#ENDREGION

--#ENDREGION
--#REGION ˚♡ Tick & Render ♡˚

---@type FOXGaze[]
local gazes = {}

local running = false

local function tick()
  local time = world.getTime()
  for _, gazeObject in pairs(gazes) do
    if gazeObject.enabled then
      gazeController(gazeObject, time)
      gazeObject(time)
    end
  end

  if soundQueue and (time - soundQueue[4]) >= 60 then soundQueue = nil end
  if damageQueue and (time - damageQueue[2]) >= 60 then damageQueue = nil end
  if chatQueue and (time - chatQueue[2]) >= 60 then chatQueue = nil end

  if not primaryGaze then return end

  primaryGaze.headRot.old = primaryGaze.headRot.new
  ---@diagnostic disable-next-line: assign-type-mismatch
  primaryGaze.headRot.new = math.lerp(primaryGaze.headRot.old, primaryGaze.headRot.target,
    1 - primaryGaze.config.turnDampen)
end

local function render(delta)
  for _, gazeObject in pairs(gazes) do
    if gazeObject.enabled then
      gazeObject(delta, true)
    end
  end

  if not primaryGaze then return end

  vanilla_model.HEAD:setOffsetRot(math.lerp(primaryGaze.headRot.old, primaryGaze.headRot.new, delta))
end

--#ENDREGION

--#ENDREGION
--#REGION ˚♡ Classes ♡˚

--#REGION ˚♡ FOXGaze.Generic ♡˚

---@class FOXGaze.Generic
---@field package enabled boolean
---@field package uuid string
local generic = {}

---Enables this FOXGaze object
---@generic self
---@param self FOXGaze.Generic|self
---@return self
function generic:enable()
  self.enabled = true
  return self
end

---Disables this FOXGaze object
---@generic self
---@param self FOXGaze.Generic|self
---@return self
function generic:disable()
  self.enabled = false
  return self
end

---Sets this FOXGaze object's enabled state
---@generic self
---@param self FOXGaze.Generic|self
---@param boolean boolean
---@return self
function generic:setEnabled(boolean)
  self.enabled = boolean
  return self
end

---Permanently removes this FOXGaze object
---@generic self
---@param self FOXGaze.Any|self
function generic:remove()
  self.parent.children[self.uuid] = nil
end

---Returns the UUID of this FOXGaze object
---@generic self
---@param self FOXGaze.Generic|self
---@return string
function generic:getUUID()
  return self.uuid
end

--#ENDREGION
--#REGION ˚♡ FOXGaze.Eye ♡˚

---@class FOXGaze.Eye: FOXGaze.Generic
---@field element ModelPart
---@field left number
---@field right number
---@field up number
---@field down number
---@field side boolean
---@field package lerp {old: Vector3, new: Vector3}
---@field package parent FOXGaze
local eye = {}

local eyeMeta = {
  __type = "FOXGaze.Eye",
  __index = function(_, key)
    return eye[key] or generic[key]
  end,
}

---Updates this eye's target position
---@param x number
---@param y number
---@return self
---@package
function eye:tick(x, y)
  if not self.enabled then return self end

  x = -x

  local eyeX = x < 0 and x * self.right or x * self.left
  local eyeY = y < 0 and y * self.down or y * self.up

  self.lerp.old = self.lerp.new
  self.lerp.new = self.side and vec(0, eyeY, eyeX) or vec(eyeX, eyeY, 0)
  return self
end

---Lerps this eye's position
---@return self
---@package
function eye:render(delta)
  if not self.enabled then return self end

  self.element:setPos(math.lerp(self.lerp.old, self.lerp.new, delta))
  return self
end

---Sets this eye's target position to its initial position
---@return self
function eye:zero()
  self.element:setPos()
  return self
end

--#ENDREGION
--#REGION ˚♡ FOXGaze.Animation ♡˚

---@class FOXGaze.Animation: FOXGaze.Generic
---@field horizontal Animation
---@field vertical Animation
---@field dampen number
---@field package lerp {old: Vector2, new: Vector2}
---@field package parent FOXGaze
local anim = {}

local animMeta = {
  __type = "FOXGaze.Animation",
  __index = function(_, key)
    return anim[key] or generic[key]
  end,
}

---Updates this animation's target time
---@param x number
---@param y number
---@return self
---@package
function anim:tick(x, y)
  if not self.enabled then return self end

  self.lerp.old = self.lerp.new
  ---@diagnostic disable-next-line: assign-type-mismatch
  self.lerp.new = math.lerp(self.lerp.old, vec(x, -y), 1 - self.dampen)
  return self
end

---Lerps this animation's time
---@param delta any
---@return self
---@package
function anim:render(delta)
  if not self.enabled then return self end

  local x, y = math.lerp(self.lerp.old, self.lerp.new, delta):add(1, 1):div(2, 2):unpack()
  self.horizontal:setTime(x)
  self.vertical:setTime(y)
  return self
end

---Sets this animation's target time to 0.5
---@return self
function anim:zero()
  self.horizontal:setTime(0.5)
  self.vertical:setTime(0.5)
  return self
end

--#ENDREGION
--#REGION ˚♡ FOXGaze.UV ♡˚

---@class FOXGaze.UV: FOXGaze.Generic
---@field element ModelPart
---@field package parent FOXGaze
local uv = {}

local uvMeta = {
  __type = "FOXGaze.Animation",
  __index = function(_, key)
    return uv[key] or generic[key]
  end,
}

---Sets the UV
---@param x number
---@param y number
---@return self
---@package
function uv:tick(x, y)
  if not self.enabled then return self end

  local UV = vec(math.round(x), math.round(-y)):div(3, 3)
  self.element:setUV(UV)
  return self
end

---Does nothing
---@return self
---@package
function uv:render() return self end

---Sets the UV back to the initial UV
---@return self
function uv:zero()
  self.element:setUV()
  return self
end

--#ENDREGION
--#REGION ˚♡ FOXGaze.Blink ♡˚

---@class FOXGaze.Blink: FOXGaze.Generic
---@field animation Animation
---@field package timer number
---@field package parent FOXGaze
local blink = {}

local blinkMeta = {
  __type = "FOXGaze.Blink",
  __index = function(_, key)
    return blink[key] or generic[key]
  end,
}

---Plays the blink animation if it's time to blink
---@return self
---@package
function blink:tick()
  if not (self.enabled and self.parent.shouldBlink) or player:getPose() == "SLEEPING" then return self end
  self.animation:play()
  return self
end

---Does nothing
---@return self
---@package
function blink:render() return self end

---Stops playing the blinking animation if it's playing
---@return self
function blink:zero()
  self.animation:stop()
  return self
end

--#ENDREGION
--#REGION ˚♡ FOXGaze ♡˚

---@class FOXGaze.Any: FOXGaze.Eye, FOXGaze.Animation, FOXGaze.UV, FOXGaze.Blink

---@class FOXGazeConfigs
---@field socialInterest number `0.8` A number from 0 to 1, how interested this gaze is in entities, 0 being completely uninterested
---@field soundInterest number `0.5` A number from 0 to 1, how interested this gaze is in sounds, 0 being completely uninterested
---@field actionCooldown number `20` After an action takes focus (i.e. played sound or chat message), how many ticks until another action can take away focus. Doesn't apply to random focuses
---@field lookInterval number `5` How often in ticks the gaze has a chance to change
---@field lookChance number `0.1` A number from 0 to 1, the chance at which the gaze will automatically change
---@field blinkFrequency number `7` How often in ticks the gaze has a chance to blink
---@field turnStrength number `22.5` The furthest the head should rotate in a single direction
---@field turnDampen number `0.7` A number from 0 to 1, with 0 being default with no dampening, and 1 being your head doesn't turn at all.
---@field faceEntities boolean `true` Whether the head should rotate when the gaze looks at entities
---@field faceBlocks boolean `false` Whether the head should rotate when the gaze looks at blocks
---@field faceDirection boolean `false` Whether the head should rotate when there are no gaze targets, or the player is focused
---@field doRandomGaze boolean `true` Whether this gaze should run processes to automatically set the target gaze

---@class FOXGaze: FOXGaze.Generic
---@field isPrimary boolean Whether this gaze is considered the primary gaze. The primary gaze directly sets the vanilla head's offset rotation
---@field package head ModelPart?
---@field package eyePivot ModelPart?
---@field package headRot FOXGazeHeadLerp
---@field package target FOXGazeTarget?
---@field package override FOXGazeTarget?
---@field package random Random.Kate
---@field package uuidRandom Random.Kate
---@field package focus number
---@field package shouldBlink boolean
---@field config FOXGazeConfigs This gaze's configs
---@field children table<string, FOXGaze.Any> Stores all the created eyes, anims, UVs, and blinks for this gaze
---@field package seed number
local gaze = {}

local gazeMeta = {
  __type = "FOXGaze",
  __index = function(_, key)
    return gaze[key] or generic[key]
  end,
  __call = updateGaze,
}

---Creates a new eye
---
---The left, right, up, and down params are the bounds. The left and right bounds should be mirrored for each eye
---
---Below are some recommendations for left and right eye bounds
---
---`Left eye` - 0.25, 1.25, 0.5, 0.5
---
---`Right eye` - 1.25, 0.25, 0.5, 0.5
---
---If the eye is on the side of the head, make set side to true
---@param self FOXGaze
---@param element ModelPart
---@param left number?
---@param right number?
---@param up number?
---@param down number?
---@param side boolean?
---@return FOXGaze.Eye
function gaze:newEye(element, left, right, up, down, side)
  assert(type(element) == "ModelPart", "ModelPart expected!", 2)
  local uuid = newUUID(self.uuidRandom)
  assert(not self.children[uuid], "UUID collision occured!", 2)
  local object = setmetatable({
    enabled = true,
    uuid = uuid,
    parent = self,
    element = element,
    left = left or 0.25,
    right = right or 1.25,
    up = up or 0.5,
    down = down or 0.5,
    side = side,
    lerp = { old = vec(0, 0, 0), new = vec(0, 0, 0) },
  }, eyeMeta)
  self.children[object.uuid] = object
  return object
end

---Creates a new animation
---
---The horizontal animation should look negative x or left at 0 seconds, center at 0.5 seconds, and positive x or right at 1 seconds
---
---The vertical animation should look up at 0 seconds, center at 0.5 seconds, and down at 1 seconds
---
---The dampen argument can be a number from 0 to 1, with 0 being default with no dampening, and 1 being your animation doesn't play at all.
---@param self FOXGaze
---@param horizontal Animation
---@param vertical Animation
---@param dampen number?
---@return FOXGaze.Animation
function gaze:newAnim(horizontal, vertical, dampen)
  local check = (horizontal and horizontal.play) and (vertical and vertical.play)
  assert(check, "Illegal arguments! Expected 2 animations!", 2)

  horizontal:play():pause():setTime(0.5)
  vertical:play():pause():setTime(0.5)

  local uuid = newUUID(self.uuidRandom)
  assert(not self.children[uuid], "UUID collision occured!", 2)

  local object = setmetatable({
    enabled = true,
    uuid = uuid,
    parent = self,
    horizontal = horizontal,
    vertical = vertical,
    dampen = dampen or 0,
    lerp = { old = vec(0, 0), new = vec(0, 0) },
  }, animMeta)
  self.children[object.uuid] = object
  return object
end

---Creates a new UV
---
---The ModelPart should be the player's face, with the UV mapped to the center of a set of 9 faces in a square
---
---The top right face should look up-right, and the bottom left face should look bottom-left
---@param self FOXGaze
---@param element ModelPart
---@return FOXGaze.UV
function gaze:newUV(element)
  assert(type(element) == "ModelPart", "ModelPart expected!", 2)
  local uuid = newUUID(self.uuidRandom)
  assert(not self.children[uuid], "UUID collision occured!", 2)

  local object = setmetatable({
    enabled = true,
    uuid = uuid,
    parent = self,
    element = element,
  }, uvMeta)
  self.children[object.uuid] = object
  return object
end

---Creates a new blink animation
---
---The animation will play randomly when the player isn't sleeping
---@param animation Animation
---@return FOXGaze.Blink
function gaze:newBlink(animation)
  assert(type(animation) == "Animation", "Blink animation expected!", 2)
  local uuid = newUUID(self.uuidRandom)
  assert(not self.children[uuid], "UUID collision occured!", 2)

  local object = setmetatable({
    enabled = true,
    uuid = uuid,
    parent = self,
    animation = animation,
  }, blinkMeta)
  self.children[object.uuid] = object
  return object
end

---Sets this gaze's target override
---@param target FOXGazeTarget
---@return FOXGaze
function gaze:setTargetOverride(target)
  self.override = target
  return self
end

---Returns the target or nil
---@return FOXGazeTarget?
function gaze:getTarget()
  return self.target
end

---Returns the target override or nil
---@return FOXGazeTarget?
function gaze:getTargetOverride()
  return self.override
end

---Runs `zero` on all this gaze's children, resets the head offset rotation, and clears the target
---@return FOXGaze
function gaze:zero()
  self.target = nil
  self.headRot.target = vec(0, 0, 0)
  for _, object in pairs(self.children) do
    object:zero()
  end
  return self
end

---Removes this gaze, and all its children
function gaze:remove()
  gazes[self.uuid] = nil
  if #gazes > 0 then return end

  running = false
  events.tick:remove(tick)
  events.render:remove(render)
end

---Sets the current gaze as primary, allowing this gaze to set the vanilla head offset rotation
---@return FOXGaze
function gaze:setAsPrimary()
  primaryGaze.isPrimary = false
  self.isPrimary = true
  primaryGaze = self
  return self
end

--#ENDREGION
--#REGION ˚♡ FOXGazeAPI ♡˚

---@alias FOXGazeTarget Vector2|Vector3|Entity

---@class FOXGazeAPI
local api = {}

---Creates a new gaze. A gaze controls looking and can be created per head
---
---Gazes can have eyes, animations that follow your gaze, UV eyes, and blinking animations.
---@param head ModelPart?
---@param eyePivot ModelPart?
---@return FOXGaze
function api:newGaze(head, eyePivot)
  local objectUUID = newUUID(uuidRng)
  assert(not gazes[objectUUID], "UUID collision occured!", 2)
  local objectUUIDInt = client.uuidToIntArray(objectUUID)
  local objectSeed = objectUUIDInt % 2048 + 1

  if not running then
    running = true
    events.tick:register(tick)
    events.render:register(render)
  end

  local object = setmetatable({
    enabled = true,
    uuid = objectUUID,
    isPrimary = not primaryGaze,
    head = head,
    eyePivot = eyePivot,
    ---@class FOXGazeHeadLerp
    headRot = {
      target = vec(0, 0, 0),
      old = vec(0, 0, 0),
      new = vec(0, 0, 0),
    },
    target = nil,
    override = nil,
    random = random.new(),
    uuidRandom = random.new(objectUUIDInt),
    focus = 0,
    shouldBlink = false,
    ---@class FOXGazeConfigs
    config = {
      socialInterest = 0.8,
      soundInterest = 0.5,
      actionCooldown = 20,
      lookInterval = 5,
      lookChance = 0.1,
      blinkFrequency = 7,
      turnStrength = 22.5,
      turnDampen = 0.7,
      faceEntities = true,
      faceBlocks = false,
      faceDirection = false,
      doRandomGaze = true,
    },
    children = {},
    seed = objectSeed,
  }, gazeMeta)
  primaryGaze = object.isPrimary and object or primaryGaze
  gazes[objectUUID] = object
  return object
end

---Sets the target override for all gazes of all players. This is only applied on the host.
---@param target FOXGazeTarget
function api:setGlobalTargetOverride(target)
  avatar:store("FOXGaze.globalTarget", target)
end

---Returns the viewer's target override
---@return FOXGazeTarget target
function api:getGlobalTargetOverride()
  return viewer:getVariable("FOXGaze.globalTarget")
end

---Sets the enabled state for debug mode
---
---Debug mode draws a line of particles from all gazes of all players to their gaze targets. This is only seen by the host.
---@param boolean boolean
function api:debugMode(boolean)
  avatar:store("FOXGaze.debugMode", boolean)
end

---Makes the current primary gaze no longer primary
function api:unsetPrimary()
  primaryGaze.isPrimary = false
  primaryGaze = nil
end

--#ENDREGION

--#ENDREGION
--#REGION ˚♡ FOXLib ♡˚

-- This exposes information like library version and name to your avatar vars. This is helpful with debugging

-- DO NOT TOUCH

local _NAME = "Gaze"
local _VER = "1.0.0"
local _BRANCH = "dev"

_FOX = _FOX or {}
_FOX[_NAME] = { name = _NAME, ver = _VER, branch = _BRANCH }
avatar:store("FOXLib", _FOX)

--#ENDREGION

return api
