## Unit + integration tests for the D-ID GuiAssert plugin.
##
## ## Pure tests (always run)
##
##   * `didBasicAuthHeader` produces the documented base64 encoding,
##   * `buildCreateTalkBody` emits the expected JSON shape,
##   * `resolveApiKey` honours providerSettings → env-var precedence,
##   * `resolveApiBase` strips trailing slashes + defaults correctly,
##   * `didProvider()` is wired up with the canonical name + non-nil
##     callbacks,
##   * `registerDid` integrates with the registry,
##   * `isAvailable()` reflects the presence of `DID_API_KEY`,
##   * cache-key determinism + per-input sensitivity.
##
## ## Mock-server integration test (always run, no network)
##
## A `std/asynchttpserver` mock spun up on a random free localhost
## port mirrors D-ID's `POST /images` / `POST /audios` / `POST /talks`
## / `GET /talks/{id}` / `GET /result.mp4` surface. The mock records
## every request (method, path, headers, body) so the test can
## then assert — by exact value — that the provider sent the
## Authorization header, multipart bodies, and JSON shape D-ID
## expects. The mock returns a small ffmpeg-generated MP4 as the
## "render result"; the test then verifies the provider's
## downloaded file matches the mock's file byte-for-byte, and that
## a second invocation hits the on-disk cache and skips all HTTP.
##
## ## Live test (compile-time-gated via `-d:didLive`)
##
##   nim c -d:didLive -r --hints:off --path:src --path:../GuiAssert/src \
##       tests/tdid.nim
##
## Requires `DID_API_KEY` to be set. Per project policy, the live
## suite never silently skips: a missing key is a test failure.

import std/[asynchttpserver, asyncdispatch, httpcore, json,
            net, options, os, osproc, streams, strformat, strutils,
            tables, times, unittest]

import gui_assert/talking_head
import gui_assert_did

when defined(didLive):
  discard  # std/[osproc, strformat, strutils, times] already imported

# Capture the live API key at module load — pure tests below call
# `delEnv(ApiKeyEnvVar)` to assert "missing key" behaviour, which would
# otherwise wipe the user's real key before the live suite runs.
let PreservedDidApiKey* {.used.} = getEnv(ApiKeyEnvVar)

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

proc thisRepoRoot(): string =
  ## `currentSourcePath` -> .../GuiAssert-Did/tests/tdid.nim
  currentSourcePath().parentDir().parentDir()

# ---------------------------------------------------------------------------
# Fixture synthesis (also used by the mock server's result MP4).
# ---------------------------------------------------------------------------

proc runSh(args: openArray[string]): tuple[code: int, output: string] =
  let bin = findExe(args[0])
  doAssert bin.len > 0, "binary not on PATH: " & args[0]
  var rest: seq[string] = @[]
  for i in 1 ..< args.len: rest.add args[i]
  let p = startProcess(
    command = bin, args = rest, options = {poStdErrToStdOut}
  )
  let raw = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  result = (code: code, output: raw)

proc bundledPortrait(): string =
  let p = thisRepoRoot() / "tests" / "fixtures" / "portrait.png"
  doAssert fileExists(p), "missing portrait fixture: " & p
  p

proc bundledNarration(): string =
  let p = thisRepoRoot() / "tests" / "fixtures" / "narration.wav"
  doAssert fileExists(p), "missing narration fixture: " & p
  p

proc ensureMockMp4(): string =
  ## Produce a small testsrc MP4 (~3 s, ~30 KB) that the mock server
  ## serves as the `result_url` payload. Synthesised once per test run
  ## under /tmp to keep the repo clean.
  let target = "/tmp/tdid-mock-result.mp4"
  if fileExists(target) and getFileSize(target) > 5_000:
    return target
  let ffBin =
    block:
      let env = getEnv("FFMPEG_BIN")
      if env.len > 0 and fileExists(env): env
      else: findExe("ffmpeg")
  doAssert ffBin.len > 0, "ffmpeg missing on PATH; needed by the mock server"
  if fileExists(target): removeFile(target)
  let r = runSh([ffBin, "-hide_banner", "-loglevel", "error", "-y",
                 "-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=25",
                 "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                 "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "64k", "-shortest", target])
  doAssert r.code == 0, "ffmpeg mock MP4 synthesis failed: " & r.output
  result = target

# ---------------------------------------------------------------------------
# Pure tests
# ---------------------------------------------------------------------------

suite "did basic auth header":

  test "encodes API key in the documented base64 form":
    # "foo:" base64 = "Zm9vOg==" — the canonical D-ID example.
    check didBasicAuthHeader("foo") == "Basic Zm9vOg=="

  test "treats arbitrary keys as opaque ascii":
    let key = "DUMMY_KEY"
    # base64("DUMMY_KEY:") = "RFVNTVlfS0VZOg=="
    check didBasicAuthHeader(key) == "Basic RFVNTVlfS0VZOg=="

suite "did create-talk body":

  test "builds the documented JSON shape":
    let body = buildCreateTalkBody("https://cdn.example/img.png", "aud_42")
    check body["source_url"].getStr == "https://cdn.example/img.png"
    check body["script"]["type"].getStr == "audio"
    check body["script"]["audio_url"].getStr == "aud_42"
    check body["config"]["stitch"].getBool == true

  test "stitch=false produces config.stitch=false":
    let body = buildCreateTalkBody("u", "a", stitch = false)
    check body["config"]["stitch"].getBool == false

suite "did opts resolution":

  test "resolveApiKey prefers providerSettings over env":
    putEnv(ApiKeyEnvVar, "ENV_KEY")
    let opts = TalkingHeadOpts(
      providerSettings: %*{"api_key": "OPTS_KEY"}
    )
    check resolveApiKey(opts) == "OPTS_KEY"
    delEnv(ApiKeyEnvVar)

  test "resolveApiKey falls back to env when providerSettings empty":
    putEnv(ApiKeyEnvVar, "ENV_ONLY")
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveApiKey(opts) == "ENV_ONLY"
    delEnv(ApiKeyEnvVar)

  test "resolveApiKey returns empty when neither set":
    delEnv(ApiKeyEnvVar)
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveApiKey(opts) == ""

  test "resolveApiBase strips trailing slashes":
    let opts = TalkingHeadOpts(
      providerSettings: %*{"api_base": "http://x.test:9000///"}
    )
    check resolveApiBase(opts) == "http://x.test:9000"

  test "resolveApiBase defaults to the public D-ID endpoint":
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveApiBase(opts) == DefaultDidApiBase
    check DefaultDidApiBase == "https://api.d-id.com"

suite "did provider value":

  test "didProvider builds a provider with the canonical name":
    let p = didProvider()
    check p.name == ProviderName
    check p.name == "did"
    check (not p.isAvailable.isNil)
    check (not p.generate.isNil)

  test "registerDid exposes the plugin via the registry":
    let r = newRegistry()
    check (not hasProvider(r, "did"))
    registerDid(r)
    check hasProvider(r, "did")
    let got = getProvider(r, "did")
    check got.name == "did"
    # Built-in stock_avatar must remain registered.
    check hasProvider(r, "stock_avatar")

  test "registry resolves the 'd-id' alias to 'did'":
    let r = newRegistry()
    registerDid(r)
    check hasProvider(r, "d-id")
    check getProvider(r, "d-id").name == "did"

suite "did isAvailable":

  test "returns false when DID_API_KEY is unset":
    delEnv(ApiKeyEnvVar)
    check (not didIsAvailable())

  test "returns true when DID_API_KEY is set":
    putEnv(ApiKeyEnvVar, "anything-nonempty")
    check didIsAvailable()
    delEnv(ApiKeyEnvVar)

suite "did cache key":

  setup:
    let cacheTmp = getTempDir() / "tdid_cachekey"
    if dirExists(cacheTmp): removeDir(cacheTmp)
    createDir(cacheTmp)
    let avatar1 = cacheTmp / "a1.png"
    let avatar2 = cacheTmp / "a2.png"
    let nar1 = cacheTmp / "n1.wav"
    let nar2 = cacheTmp / "n2.wav"
    writeFile(avatar1, "PNG-bytes-A")
    writeFile(avatar2, "PNG-bytes-B")
    writeFile(nar1, "RIFF-A")
    writeFile(nar2, "RIFF-B")

  test "same inputs produce the same key":
    let k1 = cacheKeyFor(avatar1, nar1, ProviderName, "auto")
    let k2 = cacheKeyFor(avatar1, nar1, ProviderName, "auto")
    check k1 == k2
    check k1.len == 16

  test "different avatar -> different key":
    let k1 = cacheKeyFor(avatar1, nar1, ProviderName, "auto")
    let k2 = cacheKeyFor(avatar2, nar1, ProviderName, "auto")
    check k1 != k2

  test "different audio -> different key":
    let k1 = cacheKeyFor(avatar1, nar1, ProviderName, "auto")
    let k2 = cacheKeyFor(avatar1, nar2, ProviderName, "auto")
    check k1 != k2

suite "did generate input validation":

  test "missing avatarImagePath raises TalkingHeadError":
    putEnv(ApiKeyEnvVar, "DUMMY")
    try:
      let r = newRegistry()
      registerDid(r)
      let tmp = getTempDir() / "tdid_no_avatar"
      if dirExists(tmp): removeDir(tmp)
      createDir(tmp)
      let nar = tmp / "n.wav"
      writeFile(nar, "RIFF")
      let outMp4 = tmp / "out.mp4"
      let opts = TalkingHeadOpts(avatarImagePath: none(string),
                                 cacheDir: some(tmp / "cache"))
      expect TalkingHeadError:
        generateTalkingHead(r, "did", nar, outMp4, opts)
    finally:
      delEnv(ApiKeyEnvVar)

  test "missing API key raises TalkingHeadError at generate time":
    delEnv(ApiKeyEnvVar)
    let r = newRegistry()
    # Build the provider directly because registerDid()'s availability
    # check would short-circuit dispatch through the registry; here we
    # want to exercise the in-generate fallback path.
    let p = didProvider()
    let tmp = getTempDir() / "tdid_no_key"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let avatar = tmp / "a.png"
    writeFile(avatar, "PNG")
    let nar = tmp / "n.wav"
    writeFile(nar, "RIFF")
    let outMp4 = tmp / "out.mp4"
    let opts = TalkingHeadOpts(
      avatarImagePath: some(avatar),
      cacheDir: some(tmp / "cache"),
      providerSettings: newJObject(),
    )
    expect TalkingHeadError:
      p.generate(nar, outMp4, opts)

# ---------------------------------------------------------------------------
# Mock-server integration test (no network).
# ---------------------------------------------------------------------------

type
  RecordedRequest = object
    httpMethod: string
    path: string
    authHeader: string
    contentType: string
    body: string

# Shared global state for the mock server. asynchttpserver's request
# handler is a `proc(req): Future[void]`, which can't easily close
# over per-test locals when we're also pinning -d:taintMode. Globals
# in test code are the path of least resistance.
var mockRequests: seq[RecordedRequest]
var mockResultMp4Path: string
var mockPollCount: int
var mockPollsBeforeDone: int
var mockServerPort: int

proc firstHeader(h: HttpHeaders, name: string): string =
  if h.hasKey(name):
    let vals = h.table[name.toLowerAscii]
    if vals.len > 0: return vals[0]
  return ""

proc mockHandler(req: Request): Future[void] {.async, gcsafe.} =
  {.cast(gcsafe).}:
    var rec = RecordedRequest(
      httpMethod: $req.reqMethod,
      path: req.url.path,
      authHeader: firstHeader(req.headers, "authorization"),
      contentType: firstHeader(req.headers, "content-type"),
      body: req.body,
    )
    mockRequests.add rec

    let m = req.reqMethod
    let p = req.url.path
    let portStr = $mockServerPort

    if m == HttpPost and p == "/images":
      let payload = %*{
        "id": "img_TEST",
        "url": "http://localhost:" & portStr & "/uploads/img_TEST.png"
      }
      await req.respond(Http201, $payload,
                        newHttpHeaders({"Content-Type": "application/json"}))
      return

    if m == HttpPost and p == "/audios":
      let payload = %*{
        "id": "aud_TEST",
        "url": "http://localhost:" & portStr & "/uploads/aud_TEST.wav"
      }
      await req.respond(Http201, $payload,
                        newHttpHeaders({"Content-Type": "application/json"}))
      return

    if m == HttpPost and p == "/talks":
      let payload = %*{"id": "tlk_TEST"}
      await req.respond(Http201, $payload,
                        newHttpHeaders({"Content-Type": "application/json"}))
      return

    if m == HttpGet and p == "/talks/tlk_TEST":
      mockPollCount.inc
      if mockPollCount <= mockPollsBeforeDone:
        let payload = %*{"status": "started"}
        await req.respond(Http200, $payload,
                          newHttpHeaders({"Content-Type": "application/json"}))
      else:
        let payload = %*{
          "status": "done",
          "result_url": "http://localhost:" & portStr & "/result.mp4"
        }
        await req.respond(Http200, $payload,
                          newHttpHeaders({"Content-Type": "application/json"}))
      return

    if m == HttpGet and p == "/result.mp4":
      let bytes = readFile(mockResultMp4Path)
      await req.respond(Http200, bytes,
                        newHttpHeaders({"Content-Type": "video/mp4"}))
      return

    await req.respond(Http404, "mock: no route for " & $m & " " & p,
                      newHttpHeaders({"Content-Type": "text/plain"}))

proc pickFreePort(): int =
  ## Bind to port 0 to let the OS allocate a free port, then close
  ## the socket and reuse the number. There's a tiny race window
  ## before the asynchttpserver claims the port, but it's good enough
  ## for a single-test-run mock and avoids hardcoding ports that
  ## might collide on CI.
  let s = newSocket()
  s.bindAddr(Port(0))
  let (_, port) = s.getLocalAddr
  s.close()
  result = int(port)

var mockServerThread: Thread[int]
var mockServerStopFlag: bool

proc mockServerThreadProc(port: int) {.thread.} =
  {.cast(gcsafe).}:
    let server = newAsyncHttpServer()
    asyncCheck server.serve(Port(port), mockHandler, address = "127.0.0.1")
    while not mockServerStopFlag:
      # Drive the asyncdispatch loop on this dedicated thread so the
      # main thread can issue blocking httpclient calls.
      poll(50)
    server.close()

proc startMockServer(): tuple[port: int, stop: proc() {.gcsafe.}] =
  let port = pickFreePort()
  mockServerPort = port
  mockRequests = @[]
  mockPollCount = 0
  mockServerStopFlag = false
  createThread(mockServerThread, mockServerThreadProc, port)
  # Give the server thread a moment to bind + start serving before we
  # let the caller fire requests at it.
  sleep(150)
  let stop = proc() {.gcsafe.} =
    mockServerStopFlag = true
    joinThread(mockServerThread)
  result = (port: port, stop: stop)

suite "did mock-server integration":

  test "uploads + polls + downloads through a local mock and caches the result":
    let avatar = bundledPortrait()
    let narration = bundledNarration()
    let resultMp4 = ensureMockMp4()
    mockResultMp4Path = resultMp4
    mockPollsBeforeDone = 2  # /talks/tlk_TEST first returns started twice

    let (port, stop) = startMockServer()
    defer: stop()

    # Sanity: port should be open.
    let portStr = $port
    echo &"  mock server listening on http://localhost:{portStr}"

    # Provider with millisecond polling so the test runs fast.
    let provider = didProviderWithPolling(maxPollSecs = 30.0,
                                           pollIntervalMs = 50)

    let tmp = getTempDir() / "tdid_mock"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let outMp4 = tmp / "did-mock.mp4"
    let opts = TalkingHeadOpts(
      avatarImagePath: some(avatar),
      device: "auto",
      cacheDir: some(tmp / "cache"),
      providerSettings: %*{
        "api_base": "http://localhost:" & portStr,
        "api_key": "DUMMY_KEY",
      },
    )

    let started = epochTime()
    provider.generate(narration, outMp4, opts)
    let dt = epochTime() - started
    echo &"  full mock round-trip took {dt*1000:.1f} ms"

    # ----- Recorded-request trace -----
    echo "  recorded requests (", $mockRequests.len, "):"
    for i, r in mockRequests:
      let bodyPreview =
        if r.body.len <= 120: r.body
        else: r.body[0 ..< 120] & " ...(+" & $(r.body.len - 120) & " bytes)"
      echo &"    [{i}] {r.httpMethod} {r.path}"
      echo &"        Authorization: {r.authHeader}"
      echo &"        Content-Type: {r.contentType}"
      echo &"        body[{r.body.len}]: {bodyPreview}"

    # ----- Assertion checks -----
    # With mockPollsBeforeDone=2 the trace is:
    #   [0] POST /images
    #   [1] POST /audios
    #   [2] POST /talks
    #   [3] GET /talks/tlk_TEST (response: status=started)
    #   [4] GET /talks/tlk_TEST (response: status=started)
    #   [5] GET /talks/tlk_TEST (response: status=done, result_url=...)
    #   [6] GET /result.mp4
    check mockRequests.len == 7

    check mockRequests[0].httpMethod == "POST"
    check mockRequests[0].path == "/images"
    check mockRequests[1].httpMethod == "POST"
    check mockRequests[1].path == "/audios"
    check mockRequests[2].httpMethod == "POST"
    check mockRequests[2].path == "/talks"
    check mockRequests[3].httpMethod == "GET"
    check mockRequests[3].path == "/talks/tlk_TEST"
    check mockRequests[4].httpMethod == "GET"
    check mockRequests[4].path == "/talks/tlk_TEST"
    check mockRequests[5].httpMethod == "GET"
    check mockRequests[5].path == "/talks/tlk_TEST"
    check mockRequests[6].httpMethod == "GET"
    check mockRequests[6].path == "/result.mp4"

    # ----- Authorization header exact-string check -----
    # base64("DUMMY_KEY:") == "RFVNTVlfS0VZOg=="
    # The result-download (request [6]) intentionally drops the auth
    # header — D-ID's CDN is a presigned AWS S3 URL that rejects
    # SigV4-conflicting `Authorization` headers.
    let expectedAuth = "Basic RFVNTVlfS0VZOg=="
    for i, r in mockRequests:
      if i == 6:
        check r.authHeader == ""
      else:
        check r.authHeader == expectedAuth

    # ----- Multipart Content-Type on uploads -----
    check mockRequests[0].contentType.startsWith("multipart/form-data")
    check mockRequests[1].contentType.startsWith("multipart/form-data")

    # ----- Image upload body actually contains the portrait bytes -----
    let portraitBytes = readFile(avatar)
    # The first few bytes of a PNG are: 89 50 4E 47 0D 0A 1A 0A. The
    # multipart body wraps the file with form-data headers; check that
    # the raw PNG signature appears verbatim.
    check portraitBytes[0 .. 7] == "\x89PNG\r\n\x1a\n"
    check mockRequests[0].body.contains(portraitBytes[0 .. 31])
    check mockRequests[0].body.len > portraitBytes.len  # plus multipart headers

    # ----- Audio upload body actually contains the narration bytes -----
    let narrationBytes = readFile(narration)
    # WAV files begin with "RIFF....WAVE".
    check narrationBytes[0 .. 3] == "RIFF"
    check narrationBytes.find("WAVE") == 8
    check mockRequests[1].body.contains(narrationBytes[0 .. 31])

    # ----- POST /talks JSON body shape -----
    let talksBody = parseJson(mockRequests[2].body)
    check talksBody["source_url"].getStr ==
      "http://localhost:" & portStr & "/uploads/img_TEST.png"
    check talksBody["script"]["type"].getStr == "audio"
    check talksBody["script"]["audio_url"].getStr ==
      "http://localhost:" & portStr & "/uploads/aud_TEST.wav"
    check talksBody["config"]["stitch"].getBool == true
    check mockRequests[2].contentType == "application/json"

    # ----- Poll GETs have empty body -----
    for i in 3..5:
      check mockRequests[i].body.len == 0

    # ----- Download produced a byte-identical MP4 -----
    check fileExists(outMp4)
    let downloaded = readFile(outMp4)
    let golden = readFile(resultMp4)
    check downloaded.len == golden.len
    check downloaded == golden
    echo &"  downloaded MP4 = {downloaded.len} bytes; matches mock-served golden"

    # ----- Cache hit on the second invocation skips all HTTP -----
    let beforeCount = mockRequests.len
    let outMp4_2 = tmp / "did-mock-2.mp4"
    let secondStart = epochTime()
    provider.generate(narration, outMp4_2, opts)
    let secondDt = epochTime() - secondStart
    echo &"  cache-hit second call took {secondDt*1000:.1f} ms"
    check mockRequests.len == beforeCount  # no new HTTP traffic
    check fileExists(outMp4_2)
    check getFileSize(outMp4_2) == golden.len
    check readFile(outMp4_2) == golden

# ---------------------------------------------------------------------------
# Live test — compile-time-gated. Real D-ID API.
# ---------------------------------------------------------------------------
when defined(didLive):

  proc ffprobeJson(path: string): JsonNode =
    let ffprobe =
      block:
        let env = getEnv("FFPROBE_BIN")
        if env.len > 0 and fileExists(env): env
        else: findExe("ffprobe")
    doAssert ffprobe.len > 0 and fileExists(ffprobe),
      "ffprobe not on PATH; install ffmpeg to run the live D-ID test."
    let p = startProcess(
      command = ffprobe,
      args = @["-hide_banner", "-v", "error", "-print_format", "json",
               "-show_streams", "-show_format", path],
      options = {poStdErrToStdOut}
    )
    let raw = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    doAssert code == 0, "ffprobe failed (" & $code & "): " & raw
    parseJson(raw)

  proc ensureLiveNarration(): string =
    let envOverride = getEnv("GUI_ASSERT_DID_TEST_WAV")
    if envOverride.len > 0:
      doAssert fileExists(envOverride),
        "GUI_ASSERT_DID_TEST_WAV points at a non-existent path: " & envOverride
      return envOverride
    let bundled = thisRepoRoot() / "tests" / "fixtures" / "narration.wav"
    doAssert fileExists(bundled),
      "no narration fixture at " & bundled &
      " (set GUI_ASSERT_DID_TEST_WAV to override)"
    result = bundled

  proc ensureLivePortrait(): string =
    let envOverride = getEnv("GUI_ASSERT_DID_TEST_AVATAR")
    if envOverride.len > 0:
      doAssert fileExists(envOverride),
        "GUI_ASSERT_DID_TEST_AVATAR points at a non-existent path: " &
        envOverride
      return envOverride
    let bundled = thisRepoRoot() / "tests" / "fixtures" / "portrait.png"
    doAssert fileExists(bundled),
      "no portrait fixture at " & bundled &
      " (set GUI_ASSERT_DID_TEST_AVATAR to override)"
    result = bundled

  suite "did live render against api.d-id.com":

    test "renders a real talking-head MP4 via the D-ID API":
      doAssert PreservedDidApiKey.len > 0,
        "DID_API_KEY is not set. Live D-ID tests require a real API " &
        "key from https://studio.d-id.com (free trial is 5 minutes). " &
        "Export DID_API_KEY=<your key> and re-run with -d:didLive."
      # Restore the env var: pure tests above call `delEnv(ApiKeyEnvVar)`,
      # which also makes the provider's `isAvailable` check return false.
      putEnv(ApiKeyEnvVar, PreservedDidApiKey)

      let avatar = ensureLivePortrait()
      let narration = ensureLiveNarration()

      let tmp = getTempDir() / "tdid_live"
      if dirExists(tmp): removeDir(tmp)
      createDir(tmp)

      let r = newRegistry()
      registerDid(r)

      let outMp4 = tmp / "live.mp4"
      let opts = TalkingHeadOpts(
        avatarImagePath: some(avatar),
        device: "auto",
        cacheDir: some(tmp / "cache"),
        providerSettings: %*{"api_key": PreservedDidApiKey},
        extraArgs: @[],
      )

      let started = epochTime()
      generateTalkingHead(r, "did", narration, outMp4, opts)
      let dt = epochTime() - started
      echo &"  live D-ID render took {dt:.1f}s"

      doAssert fileExists(outMp4), "no MP4 at " & outMp4
      let sz = getFileSize(outMp4)
      echo &"  output: {sz} bytes"
      check sz > 50_000

      let probe = ffprobeJson(outMp4)
      var hasVideo = false
      var hasAudio = false
      for s in probe{"streams"}.items:
        let kind = s{"codec_type"}.getStr()
        if kind == "video": hasVideo = true
        elif kind == "audio": hasAudio = true
      check hasVideo
      check hasAudio

      let videoDur = parseFloat(probe{"format", "duration"}.getStr())
      let narProbe = ffprobeJson(narration)
      let narDur = parseFloat(narProbe{"format", "duration"}.getStr())
      echo &"  narration dur: {narDur:.3f}s; talking-head dur: {videoDur:.3f}s"
      check abs(videoDur - narDur) <= 0.5

      # Cache hit — second call must be near-instant.
      let secondStart = epochTime()
      let outMp4_2 = tmp / "live2.mp4"
      generateTalkingHead(r, "did", narration, outMp4_2, opts)
      let secondDt = epochTime() - secondStart
      echo &"  second call (cache hit) took {secondDt:.3f}s"
      check secondDt < 5.0
      check fileExists(outMp4_2)
      check getFileSize(outMp4_2) == getFileSize(outMp4)
