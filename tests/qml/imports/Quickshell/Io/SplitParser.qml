import QtQuick

// Test stand-in for Quickshell's SplitParser: a test emits read() through ProcessLog.feed.
QtObject { signal read(string data) }
