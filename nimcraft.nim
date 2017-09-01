import math, tables#sequtils

import glfw3
import opengl

const
  chunkSize = 32
  maxChunks = 8192
  maxPlayers = 128
  maxAddrLength = 256
  maxNameLength = 32
  maxPathLength = 256
  maxTextLength = 266
  workers = 4

type Align {.pure} = enum
  left, center, right

type Mode {.pure} = enum
  offline, online

type WorkerStatus {.pure} = enum
  idle, busy, done

type Point = object
  x*, y*, z*: int

type Map = Table[Point, int]

type Sign = object
  x*, y*, z*, face*: int
  text*: string

type Chunk = object
  map*, lights*: Map
  signs*: seq[Sign]
  p*, q*, faces*, signFaces*, dirty*, minY*, maxY*: int
  buffer*, signBuffer*: GLuint

type Worker = object
  id*: int

type Block = object
  x*, y*, z*, w*: int

type State = object
  x*, y*, z*, rx*, ry*, t*: float

type Player = object
  id*: int
  name*: string
  state*, state1*, state2*: State
  buffer*: GLuint

type Attrib = object
  program*, position*, normal*, uv*, matrix*, sampler*, camera*, timer*, extra*, extra1*, extra2*, extra3*: GLuint

type Model = object
  window*: Window
  workers*: seq[Worker]
  chunks*: seq[Chunk]
  createRadius*, renderRadius*, deleteRadius*, signRadius*: int
  players*: seq[Player]
  typing*: bool
  typingBuffer*: string
  messages*: seq[string]
  height*, width*, observe*, observe1*: int
  flying*: bool
  scale*, ortho*: int
  fov*: float
  supressChar*: bool
  mode*: Mode
  modeChanged*: bool
  dbPath*, serverAddr*: string
  serverPort*, dayLength*: int
  timeChanged*: bool
  block0*, block1*, copy*, copy1*: Block

type FPS = object
  fps*, frames*: uint
  since*: float64

var m = Model(
  createRadius: 10,
  renderRadius: 10,
  deleteRadius: 14,
  signRadius: 4,
  dbPath: "nimcraft.db")

proc chunked(x: float): int =
  (x.round / chunkSize).floor.int

proc timeOfDay(): float =
  if m.dayLength <= 0:
    return 0.5
  let t = GetTime() / m.dayLength.float
  t - t.floor

proc getDaylight(): float =
  let
    t = timeOfDay()
    t1 = (t - (if t < 0.5: 0.25 else: 0.85)) * 100
  return 1 - 1 / (1 + -t1.pow(2))

proc getScaleFactor(): float =
  var winW, winH, bufW, bufH: cint
  GetWindowSize(m.window, winW.addr, winH.addr)
  GetFrameBufferSize(m.window, bufW.addr, bufH.addr)
  min(2, max(1, bufW / winW))

type Vec = object
  x*, y*, z*: float

proc getSightVec(rx, ry: float): Vec =
  let
    rx1 = rx - 90.0.degToRad
    m = ry.cos
  Vec(x: rx1.cos * m, y: ry.sin, z: rx1.sin * m)

proc getMotionVec(flying: bool, sz, sx, rx, ry: float): Vec =
  if sz == 0.0 and sx == 0.0:
    return Vec(x: 0.0, y: 0.0, z: 0.0)
  let 
    rx1 = rx + sz.arctan2(sx)
    rxcos = rx1.cos
    rxsin = rx1.sin
  if flying:
    var 
      m = ry.cos
      y = ry.sin
    if sx > 0:
      if sz == 0.0:
        y = 0.0
      m = 1.0
    if sz > 0:
      y = -y
    return Vec(x: rxcos * m, y: y, z: rxsin * m)
  Vec(x: rxcos, y: 0.0, z: rxsin)

proc genBuf(data: var openArray[float]): GLuint =
  glGenBuffers(1, result.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result)
  glBufferData(GL_ARRAY_BUFFER, data.sizeof, data.addr, GL_STATIC_DRAW)
  glBindBuffer(GL_ARRAY_BUFFER, 0)

proc genCrosshairBuf(): GLuint =
  let
    x = float(m.width / 2)
    y = float(m.height / 2)
    p = float(10 * m.scale)
  var data = [x, y - p, x, y + p, x - p, y, x + p, y]
  data.genBuf 

proc resetModel() =
  m.chunks = @[]
  m.players = @[]
  m.observe = 0
  m.observe1 = 0
  m.flying = false
  m.typing = false
  m.typingBuffer = ""
  m.messages = @[]
  m.dayLength = 600
  #setTime(m.dayLength.float64 / 3.0)
  m.timeChanged = true
