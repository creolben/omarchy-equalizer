import QtQuick
import QtTest
import "../.."

// KeyField: the panel's fields must be drawn from key events, never from a
// native Qt text input, so the shell never reads the clipboard on their behalf.
// These tests run offscreen against stand-ins for the shell kit
// (tests/qml/imports); tests/run-tests.sh runs them through qmltestrunner when
// it is installed, so `bash tests/run-tests.sh` covers them everywhere else.
Item {
  id: scene
  width: 400
  height: 200

  property var edits: []
  property int acceptedCount: 0
  property int finishedCount: 0

  KeyField {
    id: field
    y: 0
    width: 200
    value: "Hello"
    placeholderText: "Name"
    onTextEdited: scene.edits = scene.edits.concat([text])
    onAccepted: scene.acceptedCount++
    onEditingFinished: scene.finishedCount++
  }

  // The band row's shape: digits and a dot only, capped length.
  KeyField {
    id: numeric
    y: 60
    width: 100
    value: "1000"
    allowedCharacters: /[0-9.]/
    maximumLength: 7
    onTextEdited: scene.edits = scene.edits.concat([text])
    onAccepted: scene.acceptedCount++
    onEditingFinished: scene.finishedCount++
  }

  Item { id: elsewhere; y: 120; width: 10; height: 10; activeFocusOnTab: true }

  TestCase {
    name: "KeyField"
    when: windowShown

    function init() {
      elsewhere.forceActiveFocus()
      field.value = "Hello"; field.text = field.value
      numeric.value = "1000"; numeric.text = numeric.value
      scene.edits = []
      scene.acceptedCount = 0
      scene.finishedCount = 0
    }

    function focusField(f) { mouseClick(f, 20, f.height / 2) }

    function test_typing_appends_and_backspace_edits() {
      focusField(field)
      keyClick(Qt.Key_X)
      compare(field.text, "Hellox")
      compare(scene.edits, ["Hellox"])
      keyClick(Qt.Key_Backspace)
      compare(field.text, "Hello")
    }

    function test_model_update_follows_only_unfocused() {
      field.value = "World"
      compare(field.text, "World", "an unfocused field follows the model")
      focusField(field)
      keyClick(Qt.Key_X)
      field.value = "Other"
      compare(field.text, "Worldx", "a model echo does not clobber the draft")
    }

    function test_return_accepts_once_without_finishing() {
      focusField(field)
      keyClick(Qt.Key_Return)
      compare(scene.acceptedCount, 1)
      compare(scene.finishedCount, 0, "Return must not also finish: one commit per gesture")
    }

    function test_focus_loss_finishes_once() {
      focusField(field)
      elsewhere.forceActiveFocus()
      compare(scene.finishedCount, 1)
      compare(scene.acceptedCount, 0)
    }

    function test_escape_reverts_to_value() {
      focusField(field)
      keyClick(Qt.Key_X)
      keyClick(Qt.Key_Escape)
      compare(field.text, "Hello", "Escape restores the model's text")
    }

    function test_ctrl_u_clears_and_ctrl_v_does_nothing() {
      focusField(field)
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(field.text, "Hello", "there is no paste")
      keyClick(Qt.Key_U, Qt.ControlModifier)
      compare(field.text, "")
    }

    function test_allowed_characters_and_maximum_length() {
      focusField(numeric)
      keyClick(Qt.Key_A)
      compare(numeric.text, "1000", "letters are rejected by the pattern")
      for (var i = 0; i < 4; i++) keyClick(Qt.Key_Backspace)
      compare(numeric.text, "")
      keyClick(Qt.Key_7); keyClick(Qt.Key_5)
      compare(numeric.text, "75")
      for (var j = 0; j < 8; j++) keyClick(Qt.Key_6)
      compare(numeric.text, "7566666", "the length cap holds")
    }
  }
}
