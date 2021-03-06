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
  s = 0.0625
  workers = 4

type Align {.pure} = enum
  left, center, right

type Mode {.pure} = enum
  offline, online

type WorkerStatus {.pure} = enum
  idle, busy, done

type 
  Point = tuple[x, y, z: float]
  Vec = Point
  Map = Table[Point, int]

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
  floor(x.round / chunkSize).int

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

proc getSightVec(rx, ry: float): Vec =
  let
    rx1 = rx - 90.0.degToRad
    m = ry.cos
  (rx1.cos * m, ry.sin, rx1.sin * m)

proc getMotionVec(flying: bool, sz, sx, rx, ry: float): Vec =
  if sz == 0 and sx == 0:
    return (0.0, 0.0, 0.0)
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
    return (rxcos * m, y, rxsin * m)
  (rxcos, 0.0, rxsin)

proc genBuf(data: var openArray[float]): GLuint =
  glGenBuffers(1, result.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result)
  glBufferData(GL_ARRAY_BUFFER, data.sizeof, data.addr, GL_STATIC_DRAW)
  glBindBuffer(GL_ARRAY_BUFFER, 0)

proc genCrosshairBuf(): GLuint =
  let
    x: float = m.width / 2
    y: float = m.height / 2
    p = float(10 * m.scale)
  var data = [x, y - p, x, y + p, x - p, y, x + p, y]
  data.genBuf

proc append(data: var openArray[float], ind: var int, args: varargs[float]) =
  for arg in args:  
    data[ind] = arg
    ind.inc

proc genWireframeBuf(x, y, z, n: float): GLuint =
  const
    positions = [
      -1.0,-1,-1,
      -1,  -1, 1,
      -1,   1,-1,
      -1,   1, 1,
       1,  -1,-1,
       1,  -1, 1,
       1,   1,-1,
       1,   1, 1]    
    indices = [
      0, 1, 0, 2, 0, 4, 1, 3,
      1, 5, 2, 3, 2, 6, 3, 7,
      4, 5, 4, 6, 5, 7, 6, 7]
  var
    data: array[72, float]
    ind: int
  for i in indices:
    data.append(
      ind,
      x + n * positions[i],
      y + n * positions[i + 1],
      z + n * positions[i + 2])
  data.genBuf

proc normalize(xyz: var array[3, float]) =
  let d = xyz.mapIt(it.pow(2)).sum.sqrt
  for i in 0..2:
    xyz[i] /= d

proc makeSphere(data: var array[12288, float], ind: var int, r: float, detail: int, a, b, c: array[3, float], 
  ta, tb, tc: array[2, float]) =
  if detail == 0:
    data.append(
      ind,
      a[0] * r, a[1] * r, a[2] * r, a[0], a[1], a[2], ta[0], ta[1],
      b[0] * r, b[1] * r, b[2] * r, b[0], b[1], b[2], tb[0], tb[1],
      c[0] * r, c[1] * r, c[2] * r, c[0], c[1], c[2], tc[0], tc[1])
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
  data.makeSphere(ind, r, detail1, a, ab, ac, ta, tab, tac)
  data.makeSphere(ind, r, detail1, b, bc, ab, tb, tbc, tab)
  data.makeSphere(ind, r, detail1, c, ac, ac, tc, tac, tbc)
  data.makeSphere(ind, r, detail1, ab, bc, ac, tab, tbc, tac)

proc genSkyBuf(): GLuint =
  let
    positions = [
      [0.0, 0,-1], [ 1.0, 0, 0],
      [0.0,-1, 0], [-1.0, 0, 0],
      [0.0, 1, 0], [ 0.0, 0, 1]]    
    indices = [
      [4, 3, 0], [1, 4, 0],
      [3, 4, 5], [4, 1, 5],
      [0, 3, 2], [0, 2, 1],
      [5, 2, 3], [5, 1, 2]]
    uvs = [
      [0.0, 0.5], [0.0, 0.5],
      [0.0, 0.0], [0.0, 0.5],
      [0.0, 1.0], [0.0, 0.5]]
  var 
      data: array[12288, float] 
      ind: int
  for ix in indices:
    data.makeSphere(
      ind, 
      1, 
      3,
      positions[ix[0]],
      positions[ix[1]],
      positions[ix[2]],
      uvs[ix[0]],
      uvs[ix[1]],
      uvs[ix[2]])
  data.genBuf

var blocks: array[256, array[6, int]]

type Mat6x4 = array[6, array[4, float]]

proc makeCube(ao, light: Mat6x4, 
  left, right, top, bottom, front, back, 
  wleft, wright, wtop, wbottom, wfront, wback: int, 
  x, y, z, n: float): array[360, float] =
  const
    positions = [
      [[-1.0,-1,-1], [-1.0,-1, 1], [-1.0, 1,-1], [-1.0, 1, 1]],
      [[ 1.0,-1,-1], [ 1.0,-1, 1], [ 1.0, 1,-1], [ 1.0, 1, 1]],
      [[-1.0, 1,-1], [-1.0, 1, 1], [ 1.0, 1,-1], [ 1.0, 1, 1]],
      [[-1.0,-1,-1], [-1.0,-1, 1], [ 1.0,-1,-1], [ 1.0,-1, 1]],
      [[-1.0,-1,-1], [-1.0, 1,-1], [ 1.0,-1,-1], [ 1.0, 1,-1]],
      [[-1.0,-1, 1], [-1.0, 1, 1], [ 1.0,-1, 1], [ 1.0, 1, 1]]]
    indices = [
      [0, 3, 2, 0, 1, 3],
      [0, 3, 1, 0, 2, 3],
      [0, 3, 2, 0, 1, 3],
      [0, 3, 1, 0, 2, 3],
      [0, 3, 2, 0, 1, 3],
      [0, 3, 1, 0, 2, 3]]   
    flipped = [
      [0, 1, 2, 1, 3, 2],
      [0, 2, 1, 2, 3, 1],
      [0, 1, 2, 1, 3, 2],
      [0, 2, 1, 2, 3, 1],
      [0, 1, 2, 1, 3, 2],
      [0, 2, 1, 2, 3, 1]]
    normals = [
      [-1.0, 0, 0],
      [ 1.0, 0, 0],
      [ 0.0, 1, 0],
      [ 0.0,-1, 0],
      [ 0.0, 0,-1],
      [ 0.0, 0, 1]] 
    uvs = [
      [[0.0, 0], [1.0, 0], [0.0, 1], [1.0, 1]],
      [[1.0, 0], [0.0, 0], [1.0, 1], [0.0, 1]],
      [[0.0, 1], [0.0, 0], [1.0, 1], [1.0, 0]],
      [[0.0, 0], [0.0, 1], [1.0, 0], [1.0, 1]],
      [[0.0, 0], [0.0, 1], [1.0, 0], [1.0, 1]],
      [[1.0, 0], [1.0, 1], [0.0, 0], [0.0, 1]]]
    a = 0 + 1 / 2048.0
    b = s - 1 / 2048.0
  let
    faces = [left, right, top, bottom, front, back]
    tiles = [wleft, wright, wtop, wbottom, wfront, wback]
  var ind: int
  for i in 0..5:
    if faces[i] == 0:
      continue
    let
      du = float(tiles[i] mod 16) * s
      dv = tiles[i] / 16 * s
      aoi = ao[i]
      flip = aoi[0] + aoi[3] > aoi[1] + aoi[2]
      norm = normals[i]
    for v in 0..5:
      let 
        j = if flip: flipped[i][v] else: indices[i][v]      
        pos = positions[i][j]
        uv = uvs[i][j]
      result.append(
        ind,
        x + n * pos[0],
        y + n * pos[1],
        z + n * pos[2],
        norm[0],
        norm[1],
        norm[2],
        du + (if uv[0] == 0: a else: b),
        dv + (if uv[1] == 0: a else: b),
        aoi[j],
        light[i][j])

proc fill(mat: var Mat6x4, x: float) =
  for i in 0..5:
    for j in 0..3:
      mat[i][j] = x 

proc genCubeBuf(x, y, z, n: float, w: int): GLuint =
  var ao, light: Mat6x4
  light.fill(0.5)
  let b = blocks[w]
  var data = makeCube(ao, light, 1, 1, 1, 1, 1, 1, b[0], b[1], b[2], b[3], b[4], b[5], x, y, z, n)
  data.genBuf
             
var plants: array[256, int]
plants[17] = 48 # tall grass
plants[18] = 49 # yellow flower
plants[19] = 50 # red flower 
plants[20] = 51 # purple flower 
plants[21] = 52 # sun flower 
plants[22] = 53 # white flower 
plants[23] = 54 # blue flower 

type 
  Mat = array[16, float]
  Vec4 = array[4, float]

proc identity(): Mat =
  [1.0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

proc rotation(x0, y0, z0, angle: float): Mat =
  var xyz = [x0, y0, z0]  
  xyz.normalize
  let 
    (x, y, z) = (xyz[0], xyz[1], xyz[2])
    s = angle.sin
    c = angle.cos
    m = 1 - c
  [m * x * x + c,     m * x * y - z * s, m * z * x + y * s,     0, 
   m * x * y + z * s, m * y * y + c,     m * y * z * y - x * s, 0,
   m * z * x - y * s, m * y * z + x * s, m * z * z + c,         0, 
   0,                 0,                 0,                     1]

proc translation(dx, dy, dz: float): Mat =
  [1.0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, dx, dy, dz, 1]

proc multiply(a: var Mat, b: Mat) =
  for c in 0..3: 
    for r in 0..3: 
      a[c * 4 + r] = (0..3).mapIt(a[it * 4 + r] * b[c * 4 + it]).sum

proc multiply(vec: var Vec4, mat: Mat) =
  for i in 0..3: 
    vec[i] = (0..3).mapIt(mat[it * 4 + i] * vec[it]).sum

proc rotate(m: var Mat, x, y, z, angle: float) =
  m.multiply(rotation(x, y, z, angle))

proc translate(m: var Mat, x, y, z: float) =
  m.multiply(translation(x, y, z))

proc apply(data: var openArray[float], mat: Mat, count, offset, stride: int) =
  var ind: int
  for i in 0..<count:
    var vec: Vec4
    for j in 0..2:
      vec[j] = data[offset + stride * i + j]
    vec.multiply(mat)
    data.append(ind, vec[0], vec[1], vec[2])
                 
proc makePlant(ao, light, x, y, z, n: float, w: int, rotation: float): array[240, float] =
  const
    positions = [
      [[ 0.0,-1,-1], [ 0.0,-1, 1], [ 0.0, 1,-1], [ 0.0, 1, 1]],
      [[ 0.0,-1,-1], [ 0.0,-1, 1], [ 0.0, 1,-1], [ 0.0, 1, 1]],
      [[-1.0,-1, 0], [-1.0, 1, 0], [ 1.0,-1, 0], [ 1.0, 1, 0]],
      [[-1.0,-1, 0], [-1.0, 1, 0], [ 1.0,-1, 0], [ 1.0, 1, 0]]]
    indices = [
      [0, 3, 2, 0, 1, 3],
      [0, 3, 1, 0, 2, 3],
      [0, 3, 2, 0, 1, 3],
      [0, 3, 1, 0, 2, 3]]   
    normals = [
      [-1.0, 0, 0],
      [ 1.0, 0, 0],
      [ 0.0, 0,-1],
      [ 0.0, 0, 1]] 
    uvs = [
      [[0.0, 0], [1.0, 0], [0.0, 1], [1.0, 1]],
      [[1.0, 0], [0.0, 0], [1.0, 1], [0.0, 1]],
      [[0.0, 0], [0.0, 1], [1.0, 0], [1.0, 1]],
      [[1.0, 0], [1.0, 1], [0.0, 0], [0.0, 1]]]
  let
    du = float(plants[w] mod 16) * s
    dv = plants[w] / 16 * s
  var ind: int
  for i in 0..3:
    let norm = normals[i]
    for v in 0..5:
      let 
        j = indices[i][v]     
        pos = positions[i][j]
        uv = uvs[i][j]
      result.append(
        ind,
        n * pos[0],
        n * pos[1],
        n * pos[2],
        norm[0],
        norm[1],
        norm[2],
        du + (if uv[0] == 0: 0.0 else: s),
        dv + (if uv[1] == 0: 0.0 else: s),
        ao,
        light)
  var m = identity()
  m.rotate(0, 1, 0, rotation.degToRad)
  result.apply(m, 24, 3, 10)
  m.translate(x, y, z)
  result.apply(m, 24, 0, 10)

proc genPlantBuf(x, y, z, n: float, w: int): GLuint =
  var data = makePlant(0, 1, x, y, z, n, w, 45) 
  data.genBuf

proc genPlayerBuf(x, y, z, rx, ry: float): GLuint =
  var ao, light: Mat6x4
  light.fill(0.8)
  var
    m = identity()
    data = makeCube(ao, light, 1, 1, 1, 1, 1, 1, 226, 224, 241, 209, 225, 227, 0, 0, 0, 0.4)
  m.rotate(0, 1, 0, rx)
  m.rotate(rx.cos, 0, rx.sin, -ry)
  data.apply(m, 36, 3, 10)
  m.translate(x, y, z)
  data.apply(m, 36, 0, 10)
  data.genBuf

proc genTextBuf(x0, y, n: float, text: string): GLuint =
  const s2 = s * 2
  var 
    ind: int 
    data: seq[float] 
    x = x0
  for i in 0..<text.len:
    let 
      w = text[i].int - 32
      du = float(w mod 16) * s
      dus = du + s
      dv = 1 - w / 16 * s2 - s2 
      dvs = dv + s2
      xmn = x - n
      xpn = x + n
      m = n / 2
      ymm = y - m
      ypm = y + m
    data.append(
      ind, 
      xmn, ymm,
      du, dv,
      xpn, ymm,
      dus, dv,
      xpn, ypm,
      dus, dvs,
      xmn, ymm,
      du, dv,
      xpn, ypm,
      dus, dvs,
      xmn, ypm,
      du, dvs)
    x += n
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
