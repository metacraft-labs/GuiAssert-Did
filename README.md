# GuiAssert-Did

D-ID talking-head plugin for [GuiAssert]. Implements GuiAssert's
`TalkingHeadProvider` contract by speaking the commercial
[D-ID REST API](https://docs.d-id.com) — no Python, no model weights,
no GPU toolchain. Pure-Nim HTTP client.

D-ID is a commercial service that animates a portrait photo with
lip-synced narration. Compared with the local-ML siblings
(`GuiAssert-Wav2Lip`, `GuiAssert-MuseTalk`, `GuiAssert-SadTalker`)
it trades a recurring per-second fee for zero install cost and zero
local compute.

[GuiAssert]: ../GuiAssert/

## Layout

```
GuiAssert-Did/
├── flake.nix                            nim + ffmpeg-full + openssl + cacert devShell (no Python)
├── gui_assert_did.nimble                nimble package
├── src/
│   └── gui_assert_did.nim               plugin implementation (TalkingHeadProvider)
└── tests/
    ├── fixtures/
    │   ├── README.md                    fixture provenance
    │   ├── portrait.png                 PD-US-expired Einstein portrait, 400x400
    │   └── narration.wav                ~3.5 s test narration (16 kHz mono)
    └── tdid.nim                         pure + mock-server tests + `-d:didLive` gated live test
```

## Cost of setup

| Resource | Approx.                                                                                                                               |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Disk     | None beyond Nim build artefacts                                                                                                       |
| Network  | Per-render uploads / download, modest                                                                                                 |
| Time     | First call ~10–30 s end-to-end                                                                                                        |
| Dollars  | **$5.90/mo** entry tier (10 min/mo)<br/>**$0.10–0.40 per second** of generated video on higher tiers<br/>Free trial: ~5 min on signup |
| API key  | Yes — `DID_API_KEY` env var                                                                                                           |

Pricing is set by D-ID; see [their pricing page](https://www.d-id.com/pricing/)
for current numbers. The free trial is generally enough to validate
the plugin end-to-end (one or two short renders).

## Setup

```sh
nix develop
export DID_API_KEY="..."   # from https://studio.d-id.com → Account → API keys
```

No install script. No model weights. The `nix develop` shell
provisions Nim, ffmpeg (for fixture synthesis + ffprobe validation),
OpenSSL, and a CA bundle so TLS to `api.d-id.com` works without user
setup.

## Wiring into a runner

```nim
import gui_assert/talking_head
import gui_assert_did

let reg = newRegistry()         # registry pre-populated with `stock_avatar`
registerDid(reg)                # now `did` is also registered

var opts = TalkingHeadOpts(
  avatarImagePath: some(avatarPng),
  device: "auto",
  cacheDir: some("/tmp/did-cache"),
  providerSettings: newJObject(),    # api_key falls back to $DID_API_KEY
)
generateTalkingHead(reg, "did", narrationWav, outputMp4, opts)
```

### Configuration

All knobs live under `TalkingHeadOpts.providerSettings` (a `JsonNode`),
with environment-variable fallbacks:

| Setting    | YAML key   | Env fallback  | Default                | Purpose                                                      |
| ---------- | ---------- | ------------- | ---------------------- | ------------------------------------------------------------ |
| `api_key`  | `api_key`  | `DID_API_KEY` | _(none)_               | D-ID API key.                                                |
| `api_base` | `api_base` | _(none)_      | `https://api.d-id.com` | API endpoint. Override to point at a mock or staging server. |

The provider name is `"did"`. The `"d-id"` alias also resolves
correctly via `normalizeProviderName`.

## API flow

The provider performs four sequential HTTP calls per render (plus
poll round-trips):

1. `POST /images` — uploads the portrait as `multipart/form-data`,
   returns `{id, url}`. The `url` is what `POST /talks` uses as
   `source_url`.
2. `POST /audios` — uploads the narration WAV as
   `multipart/form-data`, returns `{id}`. Passed to `POST /talks` as
   `script.audio_id`.
3. `POST /talks` — JSON body of the form documented in D-ID's docs:
   ```json
   {
     "source_url": "https://...img.png",
     "script": { "type": "audio", "audio_id": "aud_..." },
     "config": { "stitch": true }
   }
   ```
   Returns the talk id.
4. `GET /talks/{id}` — polled every 3 s (5-minute timeout) until
   `status: done`, then `GET <result_url>` downloads the MP4.

Authentication uses HTTP Basic Auth: `Authorization: Basic
base64(DID_API_KEY:)` (the documented D-ID form).

## Caching

The plugin reuses GuiAssert's generic on-disk cache
(`applyCache` + `cacheKeyFor`). The cache key hashes the SHA-1 of the
portrait, the SHA-1 of the narration WAV, the provider name (`"did"`),
and the requested device — so identical inputs short-circuit the API
calls entirely on the second invocation. This is doubly important
here because every cache hit avoids spending real money.

The mock-server test validates the cache-hit path: a second
`generate` call against the same inputs issues zero HTTP requests.

## Tests

```sh
# Pure unit tests + mock-server integration test — no network.
nim c -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/tdid.nim

# Live end-to-end against api.d-id.com — requires DID_API_KEY.
nim c -d:didLive -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/tdid.nim
```

The `--threads:on` flag is required because the mock-server test
spawns a thread that drives `asyncdispatch.poll()` while the main
thread issues blocking `std/httpclient` calls.

The mock-server suite spins up a `std/asynchttpserver` on a random
localhost port, records every request the provider issues (method,
path, headers, body), and asserts:

- Every request carries `Authorization: Basic
RFVNTVlfS0VZOg==` (the base64 of `DUMMY_KEY:`).
- `POST /images` and `POST /audios` use `multipart/form-data` and
  embed the fixture bytes verbatim.
- `POST /talks` carries exactly the JSON shape D-ID documents.
- The downloaded MP4 is byte-identical to the mock's golden file.
- A second call hits the on-disk cache and issues zero HTTP traffic.

The live test fails the run if `DID_API_KEY` is missing — per
project policy, there are no graceful skips. CI that does not want
to spend real D-ID credit simply compiles without `-d:didLive`.

## License

MIT — see `LICENSE`. D-ID itself is a commercial service governed by
its own [terms of service](https://www.d-id.com/terms-of-use/); the
plugin only speaks the public REST API.

## Native contributor hooks

The plugin remains a pure Nim HTTP client. Its developer shell also supplies
native Python, UV, Prek and the portable formatters from its existing pin.
The committed hook config runs the seven standard checks and actual public lint.

Select the verified matching managed-hook engine as `REPROBUILD_REPRO`.
From this repository root, bootstrap its genuine managed layout first:

```sh
direnv exec . nix develop --no-update-lock-file --no-write-lock-file --command "$REPROBUILD_REPRO" hooks ensure --vcs .
direnv exec . nix develop --no-update-lock-file --no-write-lock-file --command python3 tools/install-canonical-hooks.py --repro "$REPROBUILD_REPRO"
direnv exec . nix develop --no-update-lock-file --no-write-lock-file --command prek run --all-files
```

The installer verifies the complete matching engine and dispatcher bytes,
preserves known local hooks and pre-push bodies/modes, and refuses unknown or
external hook ownership. Its installed native Prek body persistently selects
canonical upstream hook implementations even when the caller selector is absent.
System Python selection uses the owning native interpreter without managed
Python downloads. Linux qualification does not establish native Windows tools.
Original test and required live API prerequisites remain unchanged.
