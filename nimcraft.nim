import db_sqlite, math, sequtils

import glfw, nimPNG, opengl
from glfw.wrapper import getTime, setTime

proc loadTexture(texture: GLenum, param: GLint, path: string, wrap=false) = 
    var tex: GLuint 
    glGenTextures(1, tex.addr)
    glActiveTexture(texture)
    glBindTexture(GL_TEXTURE_2D, tex)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, param) 
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, param)
    if wrap:
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)

    let png = loadPNG32("textures/" & path)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA.GLint, png.width.int32, png.height.int32, 0, GL_RGBA, GL_UNSIGNED_BYTE, png.data[0].addr)

proc log(result: GLuint, `type`: string) =
    var 
        status: GLint 
        getiv = glGetProgramiv
        getInfo = glGetProgramInfoLog
    if type == "glCompileShader":
        getiv = glGetShaderiv
        getInfo = glGetShaderInfoLog

    getiv(result, GL_INFO_LOG_LENGTH, status.addr)
    if status == 0:
        var info = status.int.newString
        getInfo(result, status, nil, info)
        echo(type & " failed: " & info) 

proc loadShader(`type`: GLenum, path: string): GLuint =
    result = glCreateShader(type)
    var src = [readFile("shaders/" & path).string].allocCStringArray
    glShaderSource(result, 1, src, nil) 
    glCompileShader(result)
    result.log("glCompileShader")
    src.deallocCStringArray

proc loadProgram(vertexPath: string, fragmentPath: string): GLuint =
    result = glCreateProgram()
    var
        vertexShader = loadShader(GL_VERTEX_SHADER, vertexPath)
        fragmentShader = loadShader(GL_FRAGMENT_SHADER, fragmentPath)
    glAttachShader(result, vertexShader)
    glAttachShader(result, fragmentShader)
    glLinkProgram(result)
    result.log("glLinkProgram")
    glDetachShader(result, vertexShader)
    glDetachShader(result, fragmentShader)
    glDeleteShader(vertexShader)
    glDeleteShader(fragmentShader)

proc attrib(program: GLuint, name: string): GLint = 
    result = glGetAttribLocation(program, name)

proc uniform(program: GLuint, name: string): GLint = 
    result = glGetUniformLocation(program, name)

type Attrib = object
    program*: GLuint
    position*, normal*, uv*, matrix*, sampler*, camera*, timer*, extra1*, extra2*, extra3*, extra4*: GLint

type Sign = object
    x*, y*, z*, face*: int
    text*: string

type Chunk = object
    signs*: seq[Sign]

type Message = object
    id*: int 

type State = object
    x*, y*, z*, rx*, ry*, t*: float 

type Player = object
    id*: int 
    buffer*, name*: string
    state*, state1*, state2*: State

type Model = object
    flying*, online*, timeChanged*, typing*: bool 
    dbPath*, typingBuffer*: string
    createChunkRadius*, renderChunkRadius*, deleteChunkRadius*, renderSignRadius*, observe1*, observe2*, dayLength*: int
    chunks*: seq[Chunk]
    messages*: seq[Message]
    players*: seq[Player]

type FPS = object
    fps*, frames*: uint 
    since*: float64 

var m = Model(
    dbPath:            "nimcraft.db",
    createChunkRadius: 10,
    renderChunkRadius: 10,
    deleteChunkRadius: 14,
    renderSignRadius:  4
)

var
    db: DbConn 
    dbEnabled = false

proc dbEnable() =
    dbEnabled = true

proc dbInit(m: Model) =
    db = open(m.dbPath, nil, nil, nil)
    db.exec("attach database 'auth.db' as auth;".sql)
    db.exec("""create table if not exists auth.identity_token (
        username text not null,
        token    text not null,
        selected int  not null);""".sql)
    db.exec("create unique index if not exists auth.identity_token_username_idx on identity_token (username);".sql)  
    db.exec("""create table if not exists state (
        x  float not null,
        y  float not null,
        z  float not null,
        rx float not null,
        ry float not null);""".sql)
    db.exec("""create table if not exists block (
        p int not null,
        q int not null,
        x int not null,
        y int not null,
        z int not null,
        w int not null);""".sql)
    db.exec("""create table if not exists light (
        p int not null,
        q int not null,
        x int not null,
        y int not null,
        z int not null,
        w int not null);""".sql)
    db.exec("""create table if not exists key (
        p   int not null,
        q   int not null,
        key int not null);""".sql)
    db.exec("""create table if not exists sign (
        p    int  not null,
        q    int  not null,
        x    int  not null,
        y    int  not null,
        z    int  not null,
        face int  not null,
        text text not null);""".sql)
    db.exec("create unique index if not exists block_idx on block (p, q, x, y, z);".sql)  
    db.exec("create unique index if not exists light_idx on light (p, q, x, y, z);".sql)  
    db.exec("create unique index if not exists key_idx on key (p, q);".sql)  
    db.exec("create unique index if not exists sign_xyzface_idx on sign (x, y, z, face);".sql)  
    db.exec("create index if not exists sign_pq_idx on sign (p, q);".sql)  

proc loadState(player: Player): bool = 
    echo db.getRow("select * from state".sql)

proc resetModel() =
    m.chunks = @[]
    m.players = @[]
    m.observe1 = 0
    m.observe2 = 0
    m.flying = false
    m.typingBuffer = ""
    m.typing = false
    m.messages = @[]
    m.dayLength = 600
    setTime(m.dayLength.float64 / 3.0)
    m.timeChanged = true

type Buffer = array[12288, float]

proc normalize(xyz: var array[3, float]) =
    let d = xyz.mapIt(it * it).sum.sqrt
    for x in 0..xyz.high:
        xyz[x] /= d 

proc genSphere2(data: var Buffer, idx: var int, r: float, detail: int, a, b, c: array[3, float], ta, tb, tc: array[2, float]) =
    if detail == 0:
        let arr = [
            a[0] * r, a[1] * r, a[2] * r, a[0], a[1], a[2], ta[0], ta[1],
            b[0] * r, b[1] * r, b[2] * r, b[0], b[1], b[2], tb[0], tb[1],             
            c[0] * r, c[1] * r, c[2] * r, c[0], c[1], c[2], tc[0], tc[1],
        ]
        for i in 0..23:
            data[idx] = arr[i]
            idx += 1 

        return 

    var ab, ac, bc: array[3, float]
    for i in 0..2:
        ab[i] = (a[i] + b[i]) / 2
        ac[i] = (a[i] + c[i]) / 2
        bc[i] = (b[i] + c[i]) / 2

    ab.normalize
    ac.normalize
    bc.normalize
    var 
        tab = [0.0, 1 - ab[1].arccos / PI]
        tac = [0.0, 1 - ac[1].arccos / PI]
        tbc = [0.0, 1 - bc[1].arccos / PI]
    genSphere2(data, idx, r, detail - 1, a, ab, ac, ta, tab, tac)
    genSphere2(data, idx, r, detail - 1, b, bc, ab, tb, tbc, tab)
    genSphere2(data, idx, r, detail - 1, c, ac, ac, tc, tac, tbc)
    genSphere2(data, idx, r, detail - 1, ab, bc, ac, tab, tbc, tac)

proc genSphere(data: var Buffer, r: float, detail: int) = 
    var indices = [
        [4, 3, 0], [1, 4, 0],
        [3, 4, 5], [4, 1, 5],
        [0, 3, 2], [0, 2, 1],
        [5, 2, 3], [5, 1, 2],
    ]
    var positions = [
        [0.0, 0.0, -1.0], [1.0, 0.0, 0.0],
        [0.0, -1.0, 0.0], [-1.0, 0.0, 0.0],
        [0.0, 1.0, 0.0], [0.0, 0.0, 1.0],
    ]   
    var uvs = [
        [0.0, 0.5], [0.0, 0.5],
        [0.0, 0.0], [0.0, 0.5],
        [0.0, 1.0], [0.0, 0.5],
    ]
    var idx: int
    for i in 0..7:
        genSphere2(
            data, idx, r, detail,
            positions[indices[i][0]],
            positions[indices[i][1]],
            positions[indices[i][2]],
            uvs[indices[i][0]],
            uvs[indices[i][1]],
            uvs[indices[i][2]]
        )

proc genBuffer(data: var Buffer): GLuint = 
    glGenBuffers(1, result.addr)
    glBindBuffer(GL_ARRAY_BUFFER, result)
    glBufferData(GL_ARRAY_BUFFER, data.len, data.addr, GL_STATIC_DRAW)
    glBindBuffer(GL_ARRAY_BUFFER, 0)

proc genSkyBuffer(): GLuint = 
    var data: Buffer 
    genSphere(data, 1, 3)
    result = genBuffer(data)

proc main() =
    init()

    var win = newGlWin(title="nimcraft")
    win.cursorMode = CursorMode.cmDisabled
    makeContextCurrent(win)
    swapInterval(1)

    loadExtensions()
    glEnable(GL_CULL_FACE) 
    glEnable(GL_DEPTH_TEST) 
    glLogicOp(GL_INVERT)
    glClearColor(0, 0, 0, 1)

    loadTexture(GL_TEXTURE0, GL_NEAREST, "texture.png") 
    loadTexture(GL_TEXTURE1, GL_LINEAR, "font.png") 
    loadTexture(GL_TEXTURE2, GL_LINEAR, "sky.png", true)
    loadTexture(GL_TEXTURE3, GL_NEAREST, "sign.png")

    var p = loadProgram("block_vertex.glsl", "block_fragment.glsl")
    discard Attrib(
        program:  p,
        position: p.attrib("position"), 
        normal:   p.attrib("normal"), 
        uv:       p.attrib("uv"), 
        matrix:   p.uniform("matrix"),
        sampler:  p.uniform("sampler"),
        camera:   p.uniform("camera"),
        timer:    p.uniform("timer"),        
        extra1:   p.uniform("sky_sampler"),
        extra2:   p.uniform("daylight"),
        extra3:   p.uniform("fog_distance"),
        extra4:   p.uniform("ortho")
    )
    p = loadProgram("line_vertex.glsl", "line_fragment.glsl")
    discard Attrib(
        program:  p,
        position: p.attrib("position"), 
        matrix:   p.uniform("matrix")
    )
    p = loadProgram("text_vertex.glsl", "text_fragment.glsl")
    discard Attrib(
        program:  p,
        position: p.attrib("position"), 
        uv:       p.attrib("uv"), 
        matrix:   p.uniform("matrix"),
        sampler:  p.uniform("sampler"),
        extra1:   p.uniform("is_sign")
    )
    p = loadProgram("sky_vertex.glsl", "sky_fragment.glsl")
    discard Attrib(
        program:  p,
        position: p.attrib("position"), 
        normal:   p.attrib("normal"), 
        uv:       p.attrib("uv"), 
        matrix:   p.uniform("matrix"),
        sampler:  p.uniform("sampler"),
        timer:    p.uniform("timer")
    )

    # initialize worker threads

    var running = true
    while running:
        if not m.online:
            dbEnable()
            dbInit(m)
        break

    # client initialization

    resetModel()
    var 
        fps = FPS()
        lastCommit = getTime()
        lastUpdate = getTime()
        skyBuffer = genSkyBuffer()
        me = Player()

    m.players.add(me)
    var loaded = me.loadState

    while not win.shouldClose:
        swapBufs(win)
        pollEvents()

    terminate()

main()
