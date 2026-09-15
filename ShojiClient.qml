pragma ComponentBehavior: Bound
pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Shared NDJSON client for the ShojiWM IPC socket — the QML counterpart of
// this repo's Rust crate, one instance per Quickshell process. Transport
// only: socket lifecycle, reconnect-forever, request/response correlation,
// and a raw broadcast signal. App-specific state shapes (window maps,
// workspace views) belong in each app's services, layered on top of this.
//
// The protocol and correlation now live in NdjsonRpc, which this composes:
// identical logic serves MinkaLedger over a child process's stdio, and one
// implementation cannot drift from the other. Everything below is the part
// that is genuinely socket-specific — the path, the connection, reconnecting.
//
//   send:  { "method": string, "params"?: unknown }         fire-and-forget
//          { "id": number, "method": ..., "params": ... }   expects response
//   recv:  { "event": string, "payload": unknown }          broadcast
//          { "id": number, "result"|"error": ... }          response
//
// Strictly non-blocking (design rule R1: never block the render loop); the
// socket is recreated on ShojiWM config hot-reload, so reconnecting forever
// is a feature, not error handling.
Singleton {
    id: root

    // Flip false to drop the connection entirely and stop reconnecting
    // (MinkaMon idles this way: no geometry consumer, no socket traffic).
    property bool wanted: true

    // A peer can stop SERVING a connection without CLOSING it. ShojiWM rebinds
    // its IPC socket on config hot-reload and drops the old server side without
    // shutting the fd, so the client keeps a socket the kernel still reports as
    // ESTABLISHED that will never deliver another byte. There is no error and no
    // EOF, so `connected` stays true, the reconnect Timer below never arms, and
    // the client is wedged silently — MinkaShell sat like that for hours on
    // 1/9/2026 with a dock that could neither click a window nor track focus.
    // Liveness therefore has to be probed, not inferred from the socket state.
    property int probeIdleMs: 15000    // this quiet -> send a probe
    property int probeTimeoutMs: 5000  // probe unanswered this long -> cycle
    property string probeMethod: "workspaces.get"

    property double _lastRxAt: 0
    property double _probeSentAt: 0

    // A FAILED connect wedges a Quickshell 0.3.1 Socket too. When the attempt
    // errors (ServerNotFoundError, ConnectionRefusedError) the Socket only logs
    // it: it keeps the dead QLocalSocket, `connected` stays false, and every
    // later `connected = true` is a no-op because a socket object already
    // exists (Socket::setConnected only dials when it has none). ShojiWM's
    // config hot-reload can take more than the reconnect Timer's one second,
    // so the first retry landed before the new listener and the client never
    // tried again: on 15/9/2026 MinkaShell, MinkaMon and MinkaShot all lost
    // ShojiWM for good after a Super+Shift+R. So every attempt dials on a
    // brand-new Socket, and the one it replaces is destroyed.
    property var socket: null

    readonly property bool connected: root.socket !== null && root.socket.connected
    // True once a response has landed on the current connection.
    readonly property bool ready: rpc.ready

    // Every {event, payload} broadcast, unfiltered.
    signal broadcast(string name, var payload)

    readonly property string socketPath: {
        const runtimeDir = Quickshell.env("XDG_RUNTIME_DIR") || "/tmp";
        const display = Quickshell.env("WAYLAND_DISPLAY") || "wayland-0";
        return `${runtimeDir}/shojiwm-${display}.sock`;
    }

    // Request with an id-correlated response; onResult(result, error) is
    // optional.
    function request(method, params, onResult) {
        return rpc.request(method, params, onResult);
    }

    // Fire-and-forget command.
    function send(method, params) {
        rpc.send(method, params);
    }

    NdjsonRpc {
        id: rpc
        writeLine: line => {
            if (!root.connected)
                return;
            root.socket.write(line);
            root.socket.flush();
        }
        onBroadcast: (name, payload) => root.broadcast(name, payload)
    }

    Component {
        id: socketComponent

        Socket {
            parser: SplitParser {
                onRead: line => {
                    root._lastRxAt = Date.now();
                    rpc.feedLine(line);
                }
            }

            onConnectedChanged: {
                rpc.reset();
                root._lastRxAt = Date.now();
                root._probeSentAt = 0;
            }
            onError: rpc.reset()
        }
    }

    // Drop the current Socket, if any. A connected one is disconnected first;
    // either way it is destroyed rather than reused.
    function dropSocket() {
        const old = root.socket;
        if (old === null)
            return;
        root.socket = null;
        rpc.reset();
        if (old.connected)
            old.connected = false;
        old.destroy();
    }

    // Dial on a fresh Socket.
    function dial() {
        root.dropSocket();
        root.socket = socketComponent.createObject(root, { path: root.socketPath, connected: true });
    }

    onWantedChanged: {
        if (root.wanted)
            root.dial();
        else
            root.dropSocket();
    }

    Component.onCompleted: {
        if (root.wanted)
            root.dial();
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.wanted && !root.connected
        onTriggered: root.dial()
    }

    // Liveness probe for the wedged-but-connected case described above. Only
    // runs while we believe we are connected; the reconnect Timer owns the rest.
    Timer {
        interval: 2000
        repeat: true
        running: root.wanted && root.connected
        onTriggered: {
            const now = Date.now();
            if (root._probeSentAt > 0) {
                if (root._lastRxAt >= root._probeSentAt) {
                    root._probeSentAt = 0;
                } else if (now - root._probeSentAt > root.probeTimeoutMs) {
                    // Nothing came back: drop it and let the reconnect Timer
                    // above dial again on the current socket path.
                    root._probeSentAt = 0;
                    root.dropSocket();
                }
                return;
            }
            if (now - root._lastRxAt > root.probeIdleMs) {
                root._probeSentAt = now;
                rpc.request(root.probeMethod);
            }
        }
    }
}
