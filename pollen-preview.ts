import { join, basename } from "https://deno.land/std/path/mod.ts"
import { ensureDir, ensureSymlink } from "https://deno.land/std/fs/mod.ts"

const appName = Deno.args[0]
const denoPort = parseInt(Deno.args[1])
const emacsPort = parseInt(Deno.args[2])

// tmpfs temp dir — lives in RAM, auto-cleaned on reboot
const globalTmp = "/dev/shm"
const sessionDir = join(globalTmp, `pollen-preview-${Deno.pid}`)

const server = Deno.serve({ port: denoPort, hostname: "127.0.0.1" }, (req) => {
  if (req.headers.get("upgrade") !== "websocket") return new Response("no", { status: 400 })
  const { socket, response } = Deno.upgradeWebSocket(req)
  emacsSocket = socket
  socket.onmessage = (e) => {
    if (typeof e.data === "string") messageDispatcher(e.data)
  }
  return response
})

let emacsSocket: WebSocket | null = null
let toEmacsWs: WebSocket | null = null

let tempDir = ""
let rootDir = ""
let httpPort = 0
let renderTimer: number | null = null
let rendering = false
let renderPending = false
let renderVersion = 0
let watcher: Deno.FsWatcher | null = null

function evalInEmacs(code: string) {
  if (toEmacsWs && toEmacsWs.readyState === WebSocket.OPEN) {
    toEmacsWs.send(JSON.stringify({ type: "eval-code", content: code }))
  }
}

toEmacsWs = new WebSocket(`ws://127.0.0.1:${emacsPort}`)
toEmacsWs.onerror = () => {}
toEmacsWs.onclose = () => {}

async function messageDispatcher(message: string) {
  try {
    const parsed = JSON.parse(message)
    const [cmd, ...args] = parsed[1]

    switch (cmd) {
      case "start": {
        rootDir = args[0]
        const hash = Array.from(
          new Uint8Array(await crypto.subtle.digest("SHA-1", new TextEncoder().encode(rootDir)))
        ).map(b => b.toString(16).padStart(2, "0")).join("").slice(0, 12)
        tempDir = join(sessionDir, hash)
        await ensureDir(tempDir)
        await symlinkProject()
        try { await Deno.remove(join(tempDir, "compiled"), { recursive: true }) } catch {}
        // Initial render before starting server
        await doRender()
        startWatcher()
        await startHttpServer()
        break
      }
      case "sync": {
        const path: string = args[0]
        const content: string = args[1]
        await writeAndRender(path, content)
        break
      }
      case "stop": {
        if (watcher) { watcher.close(); watcher = null }
        // Clean up tmpfs session dir
        try { await Deno.remove(sessionDir, { recursive: true }) } catch {}
        break
      }
    }
  } catch (e) {
    console.error('[pollen-preview] error:', e)
  }
}

async function symlinkProject() {
  for await (const entry of Deno.readDir(rootDir)) {
    if (entry.name === ".pollen-preview" || entry.name.startsWith(".")) continue
    try {
      await ensureSymlink(
        join(rootDir, entry.name),
        join(tempDir, entry.name)
      )
    } catch {}
  }
}

async function writeAndRender(filePath: string, content: string) {
  const name = basename(filePath)
  const target = join(tempDir, name)
  try { await Deno.remove(target) } catch {}
  await Deno.writeTextFile(target, content)
  scheduleRender()
}

function scheduleRender() {
  if (renderTimer !== null) clearTimeout(renderTimer)
  renderTimer = setTimeout(() => {
    if (rendering) {
      renderPending = true
    } else {
      doRender()
    }
  }, 400)
}

async function doRender() {
  rendering = true
  renderPending = false
  try {
    // Clean Pollen cache before render to avoid stale data
    try { await Deno.remove(join(tempDir, "compiled"), { recursive: true }) } catch {}
    const cmd = new Deno.Command("raco", {
      args: ["pollen", "render", "--"],
      cwd: tempDir,
      stdout: "null",
      stderr: "piped",
    })
    const { success, stderr } = await cmd.output()
    if (!success) {
      const err = new TextDecoder().decode(stderr).trim()
      evalInEmacs(`(message "[pollen-preview] %s" ${JSON.stringify(err.split("\n").pop())})`)
    } else {
      renderVersion++
      await Deno.writeTextFile(join(tempDir, ".render-version"), String(renderVersion))
    }
  } catch {}
  rendering = false
  if (renderPending) doRender()
}

function startWatcher() {
  const pollenRx = /\.(pm|pmd|pp|ptree|rkt)$/
  try {
    watcher = Deno.watchFs(rootDir)
    ;(async () => {
      for await (const event of watcher!) {
        if (event.kind === "modify" || event.kind === "create") {
          if (event.paths.some((p) => pollenRx.test(p) && !p.includes(".pollen-preview"))) {
            for (const p of event.paths) {
              if (pollenRx.test(p) && !p.includes(".pollen-preview")) {
                try {
                  const content = await Deno.readTextFile(p)
                  const target = join(tempDir, basename(p))
                  try { await Deno.remove(target) } catch {}
                  await Deno.writeTextFile(target, content)
                } catch {}
              }
            }
            scheduleRender()
          }
        }
      }
    })()
  } catch {}
}

async function startHttpServer() {
  const httpServer = Deno.serve({ port: 0, hostname: "127.0.0.1" }, handler)
  httpPort = httpServer.addr.port
  console.error(`[pollen-preview] HTTP :${httpPort}`)
  evalInEmacs(`(pollen-preview--server-ready ${httpPort})`)
}

const RELOAD_SCRIPT = `<script>
(function(){
  var v=0;
  function check(){
    fetch('/__pollen_version?_='+Date.now())
      .then(function(r){return r.text()})
      .then(function(t){
        var n=parseInt(t);
        if(v===0){v=n;return}
        if(n>v){location.reload()}
      })
      .catch(function(){});
  }
  setInterval(check,200);
})();
</script>`

async function handler(req: Request): Promise<Response> {
  const url = new URL(req.url)
  const path = url.pathname

  if (path === "/__pollen_version") {
    return new Response(String(renderVersion), {
      headers: { "Cache-Control": "no-cache" },
    })
  }

  const candidates = path === "/"
    ? ["index.html", "index"]
    : path.endsWith(".html")
      ? [path, path.slice(0, -5)]
      : [path, path + ".html"]

  for (const c of candidates) {
    const filePath = join(tempDir, c)
    try {
      let content = await Deno.readTextFile(filePath)
      const isHtml = c.endsWith(".html") || !c.includes(".")
      if (isHtml) {
        content = content.replace(/<\/?root>/g, "")
        content = content.replace("</head>", RELOAD_SCRIPT + "</head>")
      }
      const ext = (c.split(".").pop() || "").toLowerCase()
      const ct: Record<string, string> = {
        html: "text/html", css: "text/css", js: "text/javascript",
        png: "image/png", jpg: "image/jpeg", svg: "image/svg+xml",
      }
      return new Response(content, {
        headers: { "Content-Type": ct[ext] || "text/html; charset=utf-8" },
      })
    } catch {}
  }
  return new Response("Not found", { status: 404 })
}
