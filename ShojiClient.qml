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

    readonly property bool connected: socket.connected
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
            if (!socket.connected)
                return;
            socket.write(line);
            socket.flush();
        }
        onBroadcast: (name, payload) => root.broadcast(name, payload)
    }

    Socket {
        id: socket
        path: root.socketPath
        connected: root.wanted

        parser: SplitParser {
            onRead: line => rpc.feedLine(line)
        }

        onConnectedChanged: rpc.reset()
        onError: rpc.reset()
    }

    onWantedChanged: socket.connected = wanted

    Timer {
        interval: 1000
        repeat: true
        running: root.wanted && !socket.connected
        onTriggered: socket.connected = true
    }
}
