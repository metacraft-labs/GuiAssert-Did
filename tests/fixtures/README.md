# Test fixtures

## `portrait.png` — Albert Einstein head shot

400x400 PNG, downscaled + cropped from the Wikimedia Commons file
[`Albert_Einstein_Head.jpg`](https://commons.wikimedia.org/wiki/File:Albert_Einstein_Head.jpg),
which is in the **public domain** worldwide (the underlying photograph
was published before 1929 and its copyright has expired in the United
States; the file is tagged `PD-US-expired` on Wikimedia Commons).

The crop + downscale was applied with:

```
ffmpeg -i Albert_Einstein_Head.jpg \
    -vf "scale=400:-1,crop=400:400:0:60" portrait.png
```

This fixture is used by both the mock-server integration test and the
`-d:didLive` live test in `tests/tdid.nim`. The live test honours
`$GUI_ASSERT_DID_TEST_AVATAR` as an override; supply any portrait
PNG/JPG with a recognisable face.

## `narration.wav` — short test narration

A ~3.5 second WAV (16 kHz mono PCM) of the phrase
"Hello from GuiAssert D-ID. This is a test render.", generated via
macOS `say` and resampled with `ffmpeg`:

```
say -o tmp.aiff "Hello from GuiAssert D-ID. This is a test render."
ffmpeg -i tmp.aiff -ar 16000 -ac 1 narration.wav
```

The live test honours `$GUI_ASSERT_DID_TEST_WAV` as an override.
