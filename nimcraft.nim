import tables#math, sequtils

import opengl
#from glfw.wrapper import getTime, setTime

const
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
  #window*: GLFWwindow
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
