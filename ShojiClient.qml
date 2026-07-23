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
    property bool ready: false

    // Every {event, payload} broadcast, unfiltered.
    signal broadcast(string name, var payload)

    readonly property string socketPath: {
        const runtimeDir = Quickshell.env("XDG_RUNTIME_DIR") || "/tmp";
        const display = Quickshell.env("WAYLAND_DISPLAY") || "wayland-0";
        return `${runtimeDir}/shojiwm-${display}.sock`;
    }

    property int _nextId: 1
    property var _pending: ({})

    // Request with an id-correlated response; onResult(result, error) is
    // optional.
    function request(method, params, onResult) {
        const id = _nextId++;
        if (onResult)
            _pending[id] = onResult;
        _write(params === undefined ? { id, method } : { id, method, params });
    }

    // Fire-and-forget command.
    function send(method, params) {
        _write(params === undefined ? { method } : { method, params });
    }

    function _write(message) {
        if (!socket.connected)
            return;
        socket.write(JSON.stringify(message) + "\n");
        socket.flush();
    }

    function _handleMessage(message) {
        if (message.event !== undefined) {
            root.broadcast(message.event, message.payload);
            return;
        }
        if (message.id !== undefined) {
            root.ready = true;
            const callback = root._pending[message.id];
            if (callback) {
                delete root._pending[message.id];
                callback(message.result, message.error);
            }
        }
    }

    Socket {
        id: socket
        path: root.socketPath
        connected: root.wanted

        parser: SplitParser {
            onRead: line => {
                const trimmed = line.trim();
                if (trimmed.length === 0)
                    return;
                let message;
                try {
                    message = JSON.parse(trimmed);
                } catch (e) {
                    return; // ignore malformed lines
                }
                root._handleMessage(message);
            }
        }

        onConnectedChanged: {
            root._pending = {};
            if (!connected)
                root.ready = false;
        }

        onError: root.ready = false
    }

    onWantedChanged: socket.connected = wanted

    Timer {
        interval: 1000
        repeat: true
        running: root.wanted && !socket.connected
        onTriggered: socket.connected = true
    }
}
