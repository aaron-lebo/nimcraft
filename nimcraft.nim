import math, sequtils, tables

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
  if sz == 0 and sx == 0:
    return Vec(x: 0, y: 0, z: 0)
  let 
    rx1 = rx + sz.arctan2(sx)
    rxcos = rx1.cos
    rxsin = rx1.sin
  if flying:
    var 
      m = ry.cos
      y = ry.sin
    if sx > 0:
      if sz == 0:
        y = 0
      m = 1
    if sz > 0:
      y = -y
    return Vec(x: rxcos * m, y: y, z: rxsin * m)
  Vec(x: rxcos, y: 0, z: rxsin)

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
  var data = [
    x, y - p, x, y + p, 
    x - p, y, x + p, y]
  data.genBuf 

proc genCubeWireframeBuf(x, y, z, n: float): GLuint =
  const 
    positions = [
      -1.0, -1, -1,
      -1, -1, +1,
      -1, +1, -1,
      -1, +1, +1,
      +1, -1, -1,
      +1, -1, +1,
      +1, +1, -1,
      +1, +1, +1]
    indices = [
      0, 1, 0, 2, 0, 4, 1, 3,
      1, 5, 2, 3, 2, 6, 3, 7,
      4, 5, 4, 6, 5, 7, 6, 7]
  var 
    data: array[72, float]
    ind: int
  for i in indices:
    data[ind] = x + n * positions[i]
    data[ind + 1] = y + n * positions[i + 1]
    data[ind + 2] = z + n * positions[i + 2]
    ind += 3
  data.genBuf 

proc normalize(xyz: var array[3, float]) =
  let d = xyz.mapIt(it.pow(2)).sum.sqrt
  for x in 0..xyz.high:
    xyz[x] /= d

proc genSphere1(data: var openArray[float], ind: var int, r: float, detail: int, a, b, c: array[3, float], ta, tb, tc: array[2, float]) =
  if detail == 0:
    for x in [
      a[0] * r, a[1] * r, a[2] * r, a[0], a[1], a[2], ta[0], ta[1],
      b[0] * r, b[1] * r, b[2] * r, b[0], b[1], b[2], tb[0], tb[1],
      c[0] * r, c[1] * r, c[2] * r, c[0], c[1], c[2], tc[0], tc[1]]:
      data[ind] = x 
      ind += 1
    return

  var ab, ac, bc: array[3, float]
  for i in 0..2:
    ab[i] = (a[i] + b[i]) / 2
    ac[i] = (a[i] + c[i]) / 2
    bc[i] = (b[i] + c[i]) / 2
 
  ab.normalize
  ac.normalize
  bc.normalize
  let 
    tab = [0.0, 1 - ab[1].arccos / PI]
    tac = [0.0, 1 - ac[1].arccos / PI]
    tbc = [0.0, 1 - bc[1].arccos / PI]
    detail1 = detail - 1
  genSphere1(data, ind, r, detail1, a, ab, ac, ta, tab, tac)
  genSphere1(data, ind, r, detail1, b, bc, ab, tb, tbc, tab)
  genSphere1(data, ind, r, detail1, c, ac, ac, tc, tac, tbc)
  genSphere1(data, ind, r, detail1, ab, bc, ac, tab, tbc, tac)

proc genSphere(data: var openArray[float], r: float, detail: int) =
  let 
    indices = [
      [4, 3, 0], [1, 4, 0],
      [3, 4, 5], [4, 1, 5],
      [0, 3, 2], [0, 2, 1],
      [5, 2, 3], [5, 1, 2]]
    positions = [
      [0.0, 0, -1], [1.0, 0, 0],
      [0.0, -1, 0], [-1.0, 0, 0],
      [0.0, 1, 0], [0.0, 0, 1]]
    uvs = [
      [0.0, 0.5], [0.0, 0.5],
      [0.0, 0.0], [0.0, 0.5],
      [0.0, 1.0], [0.0, 0.5]]
  var ind: int
  for i in 0..7:
    genSphere1(
      data, ind, r, detail,
        positions[indices[i][0]],
        positions[indices[i][1]],
        positions[indices[i][2]],
        uvs[indices[i][0]],
        uvs[indices[i][1]],
        uvs[indices[i][2]])

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
