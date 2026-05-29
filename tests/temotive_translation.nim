## Pure tests for D-ID emotive translation + capability self-description.

import std/[json, options, unittest]
import gui_assert/talking_head, gui_assert/emotive
import gui_assert_did

suite "D-ID emotionToExpression":

  test "Happy / Excited / Friendly all map to 'happy' at high intensity":
    let h = emotionToExpression(eHappy)
    check h.expr == "happy"
    check h.intensity >= 0.5
    check emotionToExpression(eExcited).expr == "happy"
    check emotionToExpression(eFriendly).expr == "happy"

  test "Surprised maps to 'surprise'":
    check emotionToExpression(eSurprised).expr == "surprise"

  test "Serious / Confident / Thoughtful map to 'serious'":
    check emotionToExpression(eSerious).expr == "serious"
    check emotionToExpression(eConfident).expr == "serious"
    check emotionToExpression(eThoughtful).expr == "serious"

  test "Neutral / Calm degrade to neutral at intensity 0":
    let n = emotionToExpression(eNeutral)
    check n.expr == "neutral"
    check n.intensity == 0.0
    check emotionToExpression(eCalm).expr == "neutral"

suite "D-ID emotiveToProviderSettings":

  test "fully populated config projects emotion + voice tuning":
    var c = initEmotive()
    c.emotion = some(eHappy)
    c.intensity = some(0.65)
    c.voiceSpeed = some(1.1)
    c.voicePitch = some(-1.5)
    let j = emotiveToProviderSettings(c)
    check j["emotion"].getStr == "happy"
    check j["expression_intensity"].getFloat == 0.65
    check j["voice_speed"].getFloat == 1.1
    check j["voice_pitch"].getFloat == -1.5

  test "missing fields produce an empty projection":
    let c = initEmotive()
    let j = emotiveToProviderSettings(c)
    check j.len == 0

  test "caller-set base wins over emotive projection":
    var c = initEmotive()
    c.emotion = some(eHappy)
    let base = %*{"emotion": "serious"}
    let j = emotiveToProviderSettings(c, base)
    check j["emotion"].getStr == "serious"

suite "D-ID applyExpressionsToScript":

  test "Happy adds a 'happy' expression entry":
    var scriptObj = %*{"type": "audio", "audio_url": "..."}
    var c = initEmotive()
    c.emotion = some(eHappy)
    applyExpressionsToScript(scriptObj, c)
    check scriptObj["expressions"][0]["type"].getStr == "happy"

  test "intensity override flows through":
    var scriptObj = %*{"type": "text", "input": "hi"}
    var c = initEmotive()
    c.emotion = some(eSerious)
    c.intensity = some(0.42)
    applyExpressionsToScript(scriptObj, c)
    check scriptObj["expressions"][0]["intensity"].getFloat == 0.42

  test "no emotion leaves the script unchanged":
    var scriptObj = %*{"type": "audio", "audio_url": "..."}
    let before = $scriptObj
    applyExpressionsToScript(scriptObj, initEmotive())
    check $scriptObj == before

suite "D-ID capabilities":

  test "self-describes as supporting both audio + text input":
    check DidCapabilities.supportsAudioInput
    check DidCapabilities.supportsTextInput
    check DidCapabilities.supportsEmotion
    check not DidCapabilities.supportsHeadMotion
    check not DidCapabilities.supportsGreenScreen
