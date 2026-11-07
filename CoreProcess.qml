import QtQuick
import Quickshell.Io

// Lifecycle wrapper for a helper child process: one Process, its stdout/stderr as
// line signals, optional restart-on-exit. Extracted so every Minka app stops hand-rolling
// the same Process + SplitParser + restart-Timer plumbing around its core (MinkaMon's
// sampler, MinkaLedger's stdio core, MinkaSyu's checker core).
//
// Deliberately transport-dumb, the mirror image of NdjsonRpc: this owns the child and its
// pipes, nothing about what the bytes mean. An owner parses lines itself, or wires them
// straight into an NdjsonRpc (`onLine: line => rpc.feedLine(line)`,
// `writeLine: line => core.write(line)`).
//
// Writes are NOT queued. A line handed to write() while the child is down is dropped, and
// nothing is ever replayed across a restart: replaying could re-send a request the dying
// child already acted on. Owners that must not lose early requests queue them above this
// layer and flush on `started` (MinkaLedger does exactly that).
//
// NOT a singleton: one instance per child process, like NdjsonRpc.
QtObject {
    id: root

    // argv for the child. Changing it does not restart a running child.
    property var command: []

    // Start the child as soon as this object exists.
    property bool autoStart: true

    // Restart the child whenever it exits (MinkaMon's sampler). Off by default:
    // for cores like MinkaLedger's, an exit is an error to surface, not to paper over.
    property bool autoRestart: false
    property int restartDelay: 3000

    // A plain property, NOT a binding to _proc.running, and assigned
    // in onRunningChanged BEFORE started/exited are emitted. A
    // binding would still hold the old value while the notification
    // that should update it is in flight -- which is exactly when
    // owners flush their queued requests (onStarted). They read
    // running=false, re-queue into a queue nothing flushes again,
    // and the window stays blank forever (MinkaLedger, 7/11/2026).
    property bool running: false

    // One stdout line, trailing newline stripped (SplitParser semantics).
    signal line(string text)

    // One stderr line. Owners typically surface these somewhere visible: stderr is where
    // a missing binary or unreadable data file first announces itself.
    signal stderrLine(string text)

    signal started()
    signal exited()

    function write(text) {
        if (_proc.running)
            _proc.write(text);
    }

    function start() {
        _proc.running = true;
    }

    function stop() {
        _proc.running = false;
    }

    property Process _proc: Process {
        command: root.command

        stdout: SplitParser {
            onRead: line => root.line(line)
        }
        // Without a parser Quickshell closes the channel and Qt discards it.
        stderr: SplitParser {
            onRead: line => root.stderrLine(line)
        }

        onRunningChanged: {
            // Set the public value first: by the time an owner's
            // onStarted/onExited handler runs, core.running must
            // already tell the truth (see the note on `running`).
            root.running = running;
            if (running)
                root.started();
            else
                root.exited();
        }
    }

    property Timer _restartTimer: Timer {
        interval: root.restartDelay
        repeat: true
        running: root.autoRestart && !root._proc.running
        onTriggered: root._proc.running = true
    }

    Component.onCompleted: {
        if (root.autoStart)
            root._proc.running = true;
    }
}
