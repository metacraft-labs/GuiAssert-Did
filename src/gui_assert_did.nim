## D-ID talking-head plugin for GuiAssert.
##
## Implements GuiAssert's `TalkingHeadProvider` contract on top of the
## commercial D-ID REST API (https://docs.d-id.com). Unlike the
## sibling local-ML plugins (Wav2Lip / MuseTalk / SadTalker), this
## plugin has no Python, no model weights, and no GPU toolchain — it
## is a pure-Nim HTTP client that uploads the avatar + narration to
## D-ID, kicks off a "talk" job, polls until completion, and downloads
## the resulting MP4.
##
## ## Wire shape
##
##   * `didProvider()` builds a `TalkingHeadProvider` value with
##     `name = "did"`, an `isAvailable` check (is `DID_API_KEY` set?),
##     and a `generate` proc that performs the upload / create /
##     poll / download cycle.
##   * `registerDid(reg)` is the one-liner plugin registration entry
##     point.
##
## ## Configuration
##
## All knobs are read from `TalkingHeadOpts.providerSettings` (a
## JsonNode), falling back to environment variables / sensible
## defaults. Two settings matter:
##
##   * `api_key` — the D-ID API key. Falls back to `$DID_API_KEY`.
##     `isAvailable()` returns false when neither is set.
##   * `api_base` — the API base URL. Defaults to
##     `https://api.d-id.com`. Tests point this at a local
##     `std/asynchttpserver` mock so the full upload / poll / download
##     cycle is exercised without network.
##
## ## API flow
##
##   1. `POST /images` (multipart) — uploads the portrait image. The
##      response carries an `id` plus a `url` we can pass back in the
##      `/talks` payload as `source_url`.
##   2. `POST /audios` (multipart) — uploads the narration WAV. The
##      response carries a `url` which we hand to `/talks` as
##      `script.audio_url`.
##   3. `POST /talks` (JSON) — creates the talk job. Returns the
##      `talk_id`.
##   4. `GET /talks/{talk_id}` — polled every `intervalMs` until the
##      status is `done` (or `error`). Honours a 5-minute timeout.
##   5. `GET <result_url>` — downloads the rendered MP4 to disk.
##
## Errors at any step raise `TalkingHeadError` with the HTTP status
## code and (when present) the response body excerpt, so failures
## surface with enough context to debug.

import std/[os, options, json, httpclient, base64, strutils,
            times, mimetypes]

import gui_assert/talking_head

type
  DidError* = object of TalkingHeadError
    ## Raised by the low-level HTTP entry points. Subclasses
    ## `TalkingHeadError` so the generic dispatch in
    ## `gui_assert/talking_head` can catch it uniformly.

const
  ProviderName* = "did"
  DefaultDidApiBase* = "https://api.d-id.com"
  DefaultMaxPollSecs* = 300.0
    ## D-ID's docs cap a single talk render around the low-minutes
    ## range; we give 5 minutes of slack before giving up.
  DefaultPollIntervalMs* = 3000
  ApiKeyEnvVar* = "DID_API_KEY"
  ApiBaseSetting* = "api_base"
  ApiKeySetting* = "api_key"

# ---------------------------------------------------------------------------
# Pure helpers — testable without any network access.
# ---------------------------------------------------------------------------

proc didBasicAuthHeader*(apiKey: string): string =
  ## Build the value of the `Authorization` header for D-ID. D-ID uses
  ## HTTP Basic Auth with the API key as the username and an empty
  ## password — i.e. `Basic base64(<key>:)`.
  "Basic " & encode(apiKey & ":")

proc resolveApiKey*(opts: TalkingHeadOpts): string =
  ## Order of precedence: `opts.providerSettings.api_key`, then the
  ## `$DID_API_KEY` env var, then "" (signalling unavailability).
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{ApiKeySetting}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      return n.getStr
  result = getEnv(ApiKeyEnvVar)

proc resolveApiBase*(opts: TalkingHeadOpts): string =
  ## Order of precedence: `opts.providerSettings.api_base`, then the
  ## `DefaultDidApiBase` constant. Trailing slashes are stripped so
  ## downstream string-concatenation stays predictable.
  var base = DefaultDidApiBase
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{ApiBaseSetting}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      base = n.getStr
  while base.endsWith('/'):
    base.setLen(base.len - 1)
  result = base

proc buildCreateTalkBody*(sourceUrl, audioUrl: string,
                          stitch = true): JsonNode =
  ## Construct the JSON body for `POST /talks`. The `sourceUrl` is the
  ## URL returned by `POST /images` (D-ID dereferences this server-side
  ## to fetch the avatar). The `audioUrl` is the URL field returned by
  ## `POST /audios` (D-ID's `s3://` URL or any HTTPS URL the renderer
  ## can fetch). `stitch: true` blends the lip-sync patch into the
  ## full portrait frame, which is what we want for the talking-head
  ## overlay use-case.
  result = %*{
    "source_url": sourceUrl,
    "script": {
      "type": "audio",
      "audio_url": audioUrl
    },
    "config": {
      "stitch": stitch
    }
  }

proc guessImageMime*(path: string): string =
  ## Best-effort MIME detection for the portrait upload. Defaults to
  ## `image/png` when the extension is unknown — D-ID accepts PNG/JPG
  ## interchangeably for `/images`.
  let ext = path.splitFile.ext.toLowerAscii
  case ext
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".webp": "image/webp"
  of ".gif": "image/gif"
  else:
    var m = newMimetypes()
    let guess = m.getMimetype(ext.strip(chars = {'.'}), default = "image/png")
    if guess.len == 0: "image/png" else: guess

proc guessAudioMime*(path: string): string =
  ## Best-effort MIME detection for the narration upload. Defaults to
  ## `audio/wav` — our pipeline always synthesises WAVs (`say` +
  ## `ffmpeg -ar 16000 -ac 1`).
  let ext = path.splitFile.ext.toLowerAscii
  case ext
  of ".wav": "audio/wav"
  of ".mp3": "audio/mpeg"
  of ".m4a": "audio/mp4"
  of ".ogg": "audio/ogg"
  else: "audio/wav"

# ---------------------------------------------------------------------------
# HTTP client construction.
# ---------------------------------------------------------------------------

proc newDidHttpClient*(apiKey: string, timeoutMs = 60_000): HttpClient =
  ## Build an `HttpClient` pre-configured with the D-ID Basic Auth
  ## header. The `Accept: application/json` hint keeps JSON-only
  ## endpoints returning JSON; multipart endpoints override
  ## `Content-Type` per-call via `MultipartData`.
  ##
  ## We pin `Connection: close` so each call opens a fresh TCP socket.
  ## This sidesteps two pain points:
  ##
  ##  1. `std/asynchttpserver` (used by the mock-server test) closes
  ##     the connection after each response, but `std/httpclient`
  ##     would keep the socket around assuming keep-alive — the next
  ##     request then writes into a half-closed socket and times out
  ##     or fails with "Connection was closed before full request has
  ##     been made". Forcing close end-to-end avoids the race.
  ##  2. Real D-ID requests interleave with potentially many seconds
  ##     of polling sleep; a stale keep-alive socket would often be
  ##     dropped by the upstream proxy by then anyway.
  let headers = newHttpHeaders({
    "Authorization": didBasicAuthHeader(apiKey),
    "Accept": "application/json",
    "User-Agent": "GuiAssert-Did/0.1 (+https://github.com/metacraft-labs/GuiAssert)",
    "Connection": "close",
  })
  result = newHttpClient(timeout = timeoutMs, headers = headers)

proc closeQuietly(client: HttpClient) =
  ## Best-effort close — swallows OSError from already-closed sockets
  ## so callers don't have to wrap every defer in a try.
  try: client.close()
  except CatchableError: discard

template withFreshClient(apiKey: string, body: untyped): untyped =
  ## Build a one-shot HttpClient, run `body` with it bound to
  ## `client`, and close it afterwards. The block-scoped name makes
  ## the per-call client easy to spot vs. the long-lived provider
  ## client. Used to dodge the keep-alive issues described in
  ## `newDidHttpClient`.
  block:
    let client {.inject.} = newDidHttpClient(apiKey)
    try:
      body
    finally:
      closeQuietly(client)

# ---------------------------------------------------------------------------
# Low-level HTTP entry points. Each one performs exactly one D-ID API
# call and raises `DidError` on non-2xx responses. They are kept
# parameter-driven (apiBase passed in) so tests can point them at a
# localhost mock without touching globals.
# ---------------------------------------------------------------------------

proc parseUploadResponse(body: string, kind: string): tuple[id, url: string] =
  ## Parse the JSON body of a successful `POST /images` or
  ## `POST /audios` call. D-ID returns at least `id`; `url` is optional
  ## (only `/images` returns it, but our code falls back to using `id`
  ## as `source_url` when no URL is present).
  let parsed =
    try: parseJson(body)
    except JsonParsingError as e:
      raise newException(DidError,
        kind & ": expected JSON response, got: " & e.msg & "\nBody: " & body)
  if parsed.kind != JObject:
    raise newException(DidError,
      kind & ": expected JSON object, got " & $parsed.kind & ": " & body)
  let idNode = parsed{"id"}
  if idNode.isNil or idNode.kind != JString or idNode.getStr.len == 0:
    raise newException(DidError,
      kind & ": response missing 'id': " & body)
  result.id = idNode.getStr
  let urlNode = parsed{"url"}
  if not urlNode.isNil and urlNode.kind == JString:
    result.url = urlNode.getStr

proc raiseHttp(prefix: string, resp: Response) {.noreturn.} =
  ## Helper for surfacing non-2xx HTTP responses with body context.
  var body = ""
  try: body = resp.body
  except CatchableError: discard
  let excerpt =
    if body.len > 800: body[0 ..< 800] & " ...(truncated)"
    else: body
  raise newException(DidError,
    prefix & ": HTTP " & resp.status & "\n" & excerpt)

proc uploadImage*(client: HttpClient, apiBase, imagePath: string):
    tuple[id, url: string] =
  ## `POST /images` with multipart/form-data. Returns the D-ID image
  ## `id` plus the dereferenceable `url` (the URL is what we then pass
  ## as `source_url` in `POST /talks`).
  if not fileExists(imagePath):
    raise newException(DidError,
      "uploadImage: portrait not found: " & imagePath)
  let data = newMultipartData()
  data.addFiles({"image": imagePath}, mimeDb = newMimetypes())
  let resp = client.request(apiBase & "/images",
                            httpMethod = HttpPost, multipart = data)
  if not resp.code.is2xx:
    raiseHttp("POST /images", resp)
  result = parseUploadResponse(resp.body, "POST /images")

proc uploadAudio*(client: HttpClient, apiBase, audioPath: string):
    tuple[id, url: string] =
  ## `POST /audios` with multipart/form-data. Returns the D-ID audio
  ## `id` plus the dereferenceable `url`. The `url` is referenced from
  ## `POST /talks` as `script.audio_url`.
  if not fileExists(audioPath):
    raise newException(DidError,
      "uploadAudio: narration WAV not found: " & audioPath)
  let data = newMultipartData()
  data.addFiles({"audio": audioPath}, mimeDb = newMimetypes())
  let resp = client.request(apiBase & "/audios",
                            httpMethod = HttpPost, multipart = data)
  if not resp.code.is2xx:
    raiseHttp("POST /audios", resp)
  result = parseUploadResponse(resp.body, "POST /audios")

proc createTalk*(client: HttpClient, apiBase, sourceUrl, audioUrl: string):
    string =
  ## `POST /talks` with the create-talk JSON body. Returns the
  ## `talk_id` D-ID assigned to the job.
  let body = buildCreateTalkBody(sourceUrl, audioUrl)
  client.headers["Content-Type"] = "application/json"
  let resp = client.request(apiBase & "/talks",
                            httpMethod = HttpPost, body = $body)
  # `request` mutates the shared header table; drop the Content-Type so
  # subsequent multipart calls aren't confused. (httpclient lets the
  # multipart sender set its own value.)
  client.headers.del("Content-Type")
  if not resp.code.is2xx:
    raiseHttp("POST /talks", resp)
  let parsed =
    try: parseJson(resp.body)
    except JsonParsingError as e:
      raise newException(DidError,
        "POST /talks: bad JSON: " & e.msg & "\nBody: " & resp.body)
  let idNode = parsed{"id"}
  if idNode.isNil or idNode.kind != JString or idNode.getStr.len == 0:
    raise newException(DidError,
      "POST /talks: response missing 'id': " & resp.body)
  result = idNode.getStr

proc pollTalkOnce*(client: HttpClient, apiBase, talkId: string):
    tuple[status, resultUrl, rawBody: string] =
  ## Single `GET /talks/{id}` round-trip. Exposed for tests that want
  ## to inspect the polling cadence without the sleep loop.
  let resp = client.request(apiBase & "/talks/" & talkId,
                            httpMethod = HttpGet)
  if not resp.code.is2xx:
    raiseHttp("GET /talks/" & talkId, resp)
  let parsed =
    try: parseJson(resp.body)
    except JsonParsingError as e:
      raise newException(DidError,
        "GET /talks/" & talkId & ": bad JSON: " & e.msg &
        "\nBody: " & resp.body)
  result.rawBody = resp.body
  result.status =
    if parsed{"status"}.isNil: ""
    else: parsed{"status"}.getStr
  let urlNode = parsed{"result_url"}
  if not urlNode.isNil and urlNode.kind == JString:
    result.resultUrl = urlNode.getStr

proc pollTalk*(apiKey, apiBase, talkId: string,
               maxSecs = DefaultMaxPollSecs,
               intervalMs = DefaultPollIntervalMs): string =
  ## `GET /talks/{id}` until `status: "done"` or `status: "error"`,
  ## subject to `maxSecs` wall-clock cap. Returns the `result_url` from
  ## which the rendered MP4 can be downloaded.
  ##
  ## Each poll opens its own HttpClient (see `newDidHttpClient` for the
  ## keep-alive rationale).
  let deadline = epochTime() + maxSecs
  while true:
    var status, resultUrl, body: string
    withFreshClient(apiKey):
      let one = pollTalkOnce(client, apiBase, talkId)
      status = one.status
      resultUrl = one.resultUrl
      body = one.rawBody
    case status
    of "done":
      if resultUrl.len == 0:
        raise newException(DidError,
          "GET /talks/" & talkId & ": status=done but no result_url: " &
          body)
      return resultUrl
    of "error", "rejected":
      raise newException(DidError,
        "D-ID talk " & talkId & " failed with status=" & status & ": " &
        body)
    else:
      discard
    if epochTime() >= deadline:
      raise newException(DidError,
        "D-ID talk " & talkId & " did not reach status=done within " &
        $maxSecs & "s (last status=" & status & ")")
    sleep(intervalMs)

proc downloadResult*(client: HttpClient, resultUrl, outputPath: string) =
  ## Download the rendered MP4. `result_url` is served from D-ID's CDN
  ## (presigned AWS S3 URL in production). S3 *rejects* requests that
  ## carry a stray `Authorization` header alongside the SigV4 query
  ## parameters, so we build a fresh unauthenticated client just for
  ## the download — the `client` argument is kept for API symmetry but
  ## is intentionally unused.
  discard client
  let outParent = outputPath.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)
  let dlHeaders = newHttpHeaders({
    "User-Agent": "GuiAssert-Did/0.1 (+https://github.com/metacraft-labs/GuiAssert)",
    "Connection": "close",
  })
  let dl = newHttpClient(timeout = 60_000, headers = dlHeaders)
  try:
    let resp = dl.request(resultUrl, httpMethod = HttpGet)
    if not resp.code.is2xx:
      raiseHttp("GET " & resultUrl, resp)
    writeFile(outputPath, resp.body)
  finally:
    try: dl.close() except CatchableError: discard
  if not fileExists(outputPath) or getFileSize(outputPath) == 0:
    raise newException(DidError,
      "D-ID result download produced no bytes at " & outputPath)

# ---------------------------------------------------------------------------
# Provider integration. Glues the HTTP layer to GuiAssert's contract.
# ---------------------------------------------------------------------------

proc didIsAvailable*(): bool {.gcsafe.} =
  ## True iff a D-ID API key is set in the environment. We can't check
  ## the per-call `opts.providerSettings.api_key` here because
  ## `isAvailable` is parameterless by contract; the provider's
  ## `generate` proc re-resolves the key (including the YAML override
  ## path) and raises a clear error if the resolved key is empty.
  getEnv(ApiKeyEnvVar).len > 0

proc didGenerateImpl(narrationWav, outputMp4: string,
                     opts: TalkingHeadOpts,
                     maxPollSecs: float,
                     pollIntervalMs: int) {.gcsafe.} =
  ## Real `generate` body, parameterised on the polling cadence so the
  ## mock-server test can run the full upload / poll / download cycle
  ## in milliseconds. The public `generateDid` proc forwards to here
  ## with the production defaults.
  if opts.avatarImagePath.isNone or opts.avatarImagePath.get.len == 0:
    raise newException(TalkingHeadError,
      "did provider requires avatarImagePath to be set " &
      "(a portrait PNG/JPG).")
  let avatar = opts.avatarImagePath.get
  if not fileExists(avatar):
    raise newException(TalkingHeadError,
      "did provider: avatar image not found: " & avatar)
  if not fileExists(narrationWav):
    raise newException(TalkingHeadError,
      "did provider: narration WAV not found: " & narrationWav)

  let apiKey = resolveApiKey(opts)
  if apiKey.len == 0:
    raise newException(TalkingHeadError,
      "did provider: API key not set. Either export DID_API_KEY=<key> " &
      "or pass it via TalkingHeadOpts.providerSettings.api_key.")
  let apiBase = resolveApiBase(opts)

  let device = effectiveDevice(opts)
  let cacheDir = effectiveCacheDir(opts)
  if not dirExists(cacheDir):
    createDir(cacheDir)
  let key = cacheKeyFor(avatar, narrationWav, ProviderName, device)

  let generator = proc() =
    # One short-lived HttpClient per API call. See
    # `newDidHttpClient` for the rationale (keep-alive races with
    # asynchttpserver + long polling-sleep gaps).
    var image: tuple[id, url: string]
    withFreshClient(apiKey):
      image = uploadImage(client, apiBase, avatar)
    # Prefer the dereferenceable URL when D-ID returned one; some
    # endpoints accept the bare `id` for `source_url` but the URL form
    # is the documented happy path.
    let sourceUrl =
      if image.url.len > 0: image.url
      else: image.id
    var audio: tuple[id, url: string]
    withFreshClient(apiKey):
      audio = uploadAudio(client, apiBase, narrationWav)
    var talkId: string
    withFreshClient(apiKey):
      talkId = createTalk(client, apiBase, sourceUrl, audio.url)
    let resultUrl = pollTalk(apiKey, apiBase, talkId,
                             maxSecs = maxPollSecs,
                             intervalMs = pollIntervalMs)
    withFreshClient(apiKey):
      downloadResult(client, resultUrl, outputMp4)

  {.cast(gcsafe).}:
    discard applyCache(cacheDir, key, outputMp4, generator)

proc generateDid*(narrationWav, outputMp4: string,
                  opts: TalkingHeadOpts) {.gcsafe.} =
  ## Production-defaults entry point. Tests that need fast polling can
  ## use `didProviderWithPolling` (below) to build a provider with a
  ## millisecond-interval poll, avoiding the 3-second production
  ## default.
  didGenerateImpl(narrationWav, outputMp4, opts,
                  DefaultMaxPollSecs, DefaultPollIntervalMs)

proc didProvider*(): TalkingHeadProvider =
  ## Build the D-ID provider value with production polling defaults.
  result = TalkingHeadProvider(
    name: ProviderName,
    isAvailable: didIsAvailable,
    generate: generateDid,
  )

proc didProviderWithPolling*(maxPollSecs: float,
                             pollIntervalMs: int): TalkingHeadProvider =
  ## Variant for tests: lets the mock-server suite drive the full
  ## cycle without sleeping for seconds between polls. Production
  ## callers use `didProvider()`.
  let captured = (maxPollSecs, pollIntervalMs)
  let gen = proc(narrationWav, outputMp4: string,
                 opts: TalkingHeadOpts) {.gcsafe.} =
    {.cast(gcsafe).}:
      didGenerateImpl(narrationWav, outputMp4, opts,
                      captured[0], captured[1])
  result = TalkingHeadProvider(
    name: ProviderName,
    isAvailable: didIsAvailable,
    generate: gen,
  )

proc registerDid*(r: TalkingHeadRegistry) =
  ## One-liner plugin entry point. Callers do:
  ##
  ## ```nim
  ## import gui_assert/talking_head
  ## import gui_assert_did
  ##
  ## let reg = newRegistry()
  ## registerDid(reg)
  ## generateTalkingHead(reg, "did", wav, mp4, opts)
  ## ```
  r.registerProvider(didProvider())
