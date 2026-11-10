import QtQuick
import QtTest
import Quickshell.Io
import "../.."

// The panel's edit path, offscreen, against stand-ins for Quickshell's Process
// (tests/qml/imports/Quickshell/Io: nothing runs, every start and every write to
// stdin is recorded in ProcessLog) and for the shell kit:
//
// - a drag is echoed into the panel's own bands on the move it happens, so the
//   curve and the readouts move with the hand (docs/spec-v4.md §3.2);
// - while the live editor is armed the moves are streamed to it, coalesced to
//   the last value per control, and the release is one commit (§3.1.2);
// - with the limiter on the preamp is held during the drag and the readout says
//   where it will settle; without it the preamp follows (§3.5.1);
// - a 10-band fader edit is the fitted gains of every band (§3.3);
// - an undo right after a nudge waits for the nudge's commit (§3.4);
// - without the live editor the same edits go through the command queue
//   (§3.1.2), and a gesture begun there stays there when the editor arms;
// - a stale commit, an editor that exits, and a panel closed mid-drag leave
//   nothing waiting: no edit stuck in flight, no deferred command held back.
Item {
  id: scene
  width: 520
  height: 1000

  function bands8() {
    return [
      { type: "lowshelf", freq: 80, q: 0.71, gain: 0 },
      { type: "peaking", freq: 120, q: 1.0, gain: 0 },
      { type: "peaking", freq: 250, q: 1.0, gain: 0 },
      { type: "peaking", freq: 500, q: 1.0, gain: 0 },
      { type: "peaking", freq: 1000, q: 1.0, gain: 0 },
      { type: "peaking", freq: 2000, q: 1.0, gain: 0 },
      { type: "peaking", freq: 4000, q: 1.0, gain: 0 },
      { type: "highshelf", freq: 8000, q: 0.71, gain: 0 }
    ]
  }
  function bands10() {
    var out = [], iso = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    for (var i = 0; i < iso.length; i++) out.push({ type: "peaking", freq: iso[i], q: 1.41, gain: 0 })
    return out
  }
  function baseStatus(mode) {
    return {
      enabled: true, sinkPresent: true, mode: mode, preset: "Flat", presetDirty: false,
      bands: mode === "graphic" ? bands10() : bands8(), presets: [{ name: "Flat", builtin: true, category: "reference" }],
      headroom: "auto", limiter: "on", outputStage: true, preamp: 0, relief: 0, deviceRelief: 0,
      preampCeiling: 0, sampleRate: 48000, canUndo: false, canRedo: false, listen: null,
      slots: 8, maxSlots: 16
    }
  }

  Panel { id: panel }

  TestCase {
    name: "Panel"
    when: windowShown

    function armLive(mode) {
      panel.opened = false
      wait(10)
      ProcessLog.finish(" live", 0)
      ProcessLog.clear()
      panel.status = scene.baseStatus(mode)
      panel.liveStarts = 0
      panel.opened = true
      wait(10)
      verify(ProcessLog.find(" live") !== null, "the panel starts the live editor when it opens")
      ProcessLog.feed(" live", "ready " + mode + ":8:8")
      verify(panel.liveArmed, "and arms it on ready")
    }

    function cleanup() {
      // Closing ends any gesture still open (an Escape mid-drag does the same).
      panel.opened = false
      wait(30)
      ProcessLog.finish(" live", 0)
      verify(!panel.editing, "no gesture outlives the panel")
    }

    function test_aDragIsEchoedStreamedAndCommittedOnce() {
      armLive("parametric")
      panel.editGain(2, 3, false)
      compare(panel.bands[2].gain, 3, "the move is echoed into the panel's bands at once")
      wait(40)
      compare(ProcessLog.written(" live"), "gain 2 3\n", "and streamed")
      // Three moves inside one flush window are one line, the last value.
      panel.editGain(2, 4, false)
      panel.editGain(2, 4.5, false)
      panel.editGain(2, 5, false)
      wait(40)
      compare(ProcessLog.written(" live"), "gain 2 3\ngain 2 5\n", "a burst is coalesced to its last value")
      wait(100)
      panel.editGain(2, 5, true)
      wait(40)
      compare(ProcessLog.written(" live"), "gain 2 3\ngain 2 5\ncommit\n",
        "the release adds no repeated value, only the commit")
      compare(panel.liveCommitsPending, 1)
      // A poll answered now would paint stale bands over the echo: it waits.
      var stale = scene.baseStatus("parametric")
      panel.applyStatus(JSON.stringify(stale))
      compare(panel.bands[2].gain, 5, "a status read during the commit does not undo the echo")
      var after = scene.baseStatus("parametric")
      after.bands[2].gain = 5
      after.preamp = -5
      after.canUndo = true
      ProcessLog.feed(" live", "status " + JSON.stringify(after))
      compare(panel.liveCommitsPending, 0)
      compare(panel.preamp, -5, "the commit's status is the panel's status")
      verify(panel.canUndo)
    }

    function test_aParametricReleaseIsOneCommitForGainAndFrequency() {
      armLive("parametric")
      panel.editGain(4, 2, false)
      panel.editFreq(4, 1200, false)
      wait(120)
      panel.editGain(4, 2.5, true)
      panel.editFreq(4, 1250, true)
      wait(40)
      var text = ProcessLog.written(" live")
      compare(text.split("commit").length - 1, 1, "one commit for the two final values: " + JSON.stringify(text))
      verify(text.indexOf("freq 4 1250") >= 0 && text.indexOf("gain 4 2.5") >= 0, "both values are sent")
    }

    function test_thePreampIsHeldWhileTheLimiterIsOn() {
      armLive("parametric")
      panel.editGain(2, 6, false)
      compare(panel.preamp, 0, "with the limiter on the preamp in force stays")
      verify(panel.settlePreamp < -5, "but the panel knows where it will settle")
      verify(panel.preampReadout.indexOf("→") > 0, "and says both: " + panel.preampReadout)
      wait(100)
      panel.editGain(2, 6, true)
      ProcessLog.feed(" live", "status " + JSON.stringify(scene.baseStatus("parametric")))
      // Without a limiter nothing would catch the clip: the preamp follows.
      var s = scene.baseStatus("parametric")
      s.limiter = "off"
      panel.status = s
      panel.editGain(2, 6, false)
      compare(panel.preamp, panel.settlePreamp, "with the limiter off it follows the bands")
      verify(panel.preamp < -5)
    }

    function test_aFaderEditSendsTheFittedGainsOfEveryBand() {
      armLive("graphic")
      panel.editGraphic(5, 6, false)
      wait(40)
      var text = ProcessLog.written(" live")
      verify(text.indexOf("gains ") === 0, "a fader sends every band's gain: " + text)
      compare(text.trim().split(" ").length, 11, "ten gains")
      fuzzyCompare(panel.handleGains[5], 6, 0.05, "the fader's band reads its value on the curve")
      fuzzyCompare(panel.handleGains[4], 0, 0.05, "and its neighbour does not move")
      verify(panel.bands[4].gain < 0, "the neighbour's bell moved to hold it there")
    }

    function test_anUndoRightAfterANudgeWaitsForItsCommit() {
      armLive("parametric")
      var s = panel.status
      panel.editGain(1, 1.5, true)
      verify(liveCommitSettling(), "a nudge's commit waits for the run of nudges to end")
      panel.undo()
      wait(20)
      verify(ProcessLog.written(" live").indexOf("commit") >= 0, "the undo sends the nudge's commit first")
      compare(ProcessLog.startedWith("omarchy-equalizer undo").length, 0, "and does not run before it is filed")
      var after = scene.baseStatus("parametric")
      after.bands[1].gain = 1.5
      after.canUndo = true
      ProcessLog.feed(" live", "status " + JSON.stringify(after))
      compare(ProcessLog.startedWith("omarchy-equalizer undo").length, 1, "then the undo runs")
      ProcessLog.finish("omarchy-equalizer undo", 0)
    }

    function liveCommitSettling() { return panel.editInFlight && panel.liveCommitsPending === 0 }

    function test_aStaleCommitIsAnsweredAndNothingWaits() {
      armLive("parametric")
      panel.editGain(3, 2, false)
      wait(100)
      panel.editGain(3, 2.5, true)
      wait(20)
      compare(panel.liveCommitsPending, 1)
      panel.run(["set-mode", "graphic"])
      compare(ProcessLog.startedWith("set-mode").length, 0, "a command waits for the commit")
      // The state moved under the edit: the editor answers stale, then the status.
      ProcessLog.feed(" live", "stale")
      ProcessLog.feed(" live", "status " + JSON.stringify(scene.baseStatus("parametric")))
      compare(panel.liveCommitsPending, 0, "the commit is answered")
      verify(!panel.editInFlight, "and nothing is left in flight")
      compare(ProcessLog.startedWith("set-mode").length, 1, "the waiting command runs")
      ProcessLog.finish("set-mode", 0)
    }

    function test_anEditorThatExitsReleasesEverything() {
      armLive("parametric")
      panel.editGain(1, 1, false)
      wait(100)
      panel.editGain(1, 1.5, true)
      wait(20)
      panel.run(["reset"])
      compare(ProcessLog.startedWith(" reset").length, 0)
      ProcessLog.finish(" live", 1)
      compare(panel.liveCommitsPending, 0, "an editor that is gone owes no answer")
      verify(!panel.liveArmed)
      compare(ProcessLog.startedWith(" reset").length, 1, "the waiting command runs")
      ProcessLog.finish(" reset", 0)
    }

    function test_aDragBegunOnTheQueueStaysOnIt() {
      panel.opened = false
      wait(10)
      ProcessLog.finish(" live", 0)
      ProcessLog.clear()
      panel.status = scene.baseStatus("parametric")
      panel.liveStarts = 0
      panel.opened = true
      wait(10)
      verify(ProcessLog.find(" live") !== null)
      // Not ready yet: the drag starts on the queue.
      panel.editGain(2, 1, false)
      compare(ProcessLog.startedWith("set-gain 2 1").length, 1)
      ProcessLog.feed(" live", "ready parametric:8:8")
      verify(panel.liveArmed)
      panel.editGain(2, 2, false)
      wait(100)
      panel.editGain(2, 3, true)
      wait(40)
      compare(ProcessLog.written(" live"), "", "the editor armed mid-drag is not used for the rest of it")
      ProcessLog.finish("set-gain 2 1", 0)
      var started = ProcessLog.startedWith("set-gain")
      compare(started[started.length - 1].slice(-12), "set-gain 2 3", "the queue carries it to the end")
      ProcessLog.finish("set-gain 2 3", 0)
      // The next gesture, with nothing queued, goes live.
      wait(80)
      panel.editGain(2, 4, true)
      wait(40)
      verify(ProcessLog.written(" live").indexOf("gain 2 4") >= 0, "the next gesture is live")
    }

    function test_aCommitDecidedInTheCloseTurnIsSentBeforeTheEnd() {
      armLive("parametric")
      // A field committing as the panel closes: the final value and the close
      // in one turn, before Qt.callLater has resolved the commit.
      panel.editFreq(4, 1500, true)
      panel.opened = false
      var text = ProcessLog.written(" live")
      verify(text.indexOf("freq 4 1500") >= 0 && text.indexOf("commit") > text.indexOf("freq 4 1500"),
        "the value and its commit are written before the input ends: " + JSON.stringify(text))
    }

    function test_aCloseMidDragEndsTheGesture() {
      armLive("parametric")
      panel.editGain(5, 2, false)
      wait(100)
      verify(panel.editing)
      panel.opened = false
      wait(20)
      verify(!panel.editing, "the close ends the gesture")
      verify(ProcessLog.written(" live").indexOf("commit") >= 0, "and files what it reached")
    }

    function test_withoutTheLiveEditorTheQueueCarriesTheEdit() {
      panel.opened = false
      wait(10)
      ProcessLog.finish(" live", 0)
      ProcessLog.clear()
      var s = scene.baseStatus("parametric")
      s.enabled = false
      panel.status = s
      panel.opened = true
      wait(10)
      compare(ProcessLog.find(" live"), null, "no live editor while the equalizer is off")
      panel.editGain(3, 2, false)
      compare(ProcessLog.startedWith("set-gain 3 2").length, 1, "the first move goes through the queue at once")
      panel.editGain(3, 2.5, false)
      panel.editGain(3, 3, false)
      compare(ProcessLog.startedWith("set-gain").length, 1, "moves inside the 60 ms window wait")
      ProcessLog.finish("set-gain 3 2", 0)
      wait(90)
      var started = ProcessLog.startedWith("set-gain")
      compare(started[started.length - 1].slice(-12), "set-gain 3 3", "the window sends the last value: " + started.join(","))
      panel.editGain(3, 4, true)
      ProcessLog.finish("set-gain 3 3", 0)
      started = ProcessLog.startedWith("set-gain")
      compare(started[started.length - 1].slice(-12), "set-gain 3 4", "and the release sends the final one")
      ProcessLog.finish("set-gain 3 4", 0)
    }
  }
}
