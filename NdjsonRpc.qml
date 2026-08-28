import QtQuick

// Transport-agnostic NDJSON request/response client.
//
// Extracted from ShojiClient so the same correlation logic serves a Unix socket (ShojiWM) and a
// child process's stdio (MinkaLedger). Only the bytes differ between those; the id correlation,
// the pending-callback map and the event/response dispatch are identical, and duplicating them
// invites the two copies to drift on exactly the details that are easy to get subtly wrong.
//
// The owner supplies `writeLine` and feeds received lines to `feedLine`. This object knows nothing
// about sockets, processes, reconnection or paths.
//
//   send:  { "method": string, "params"?: unknown }         fire-and-forget
//          { "id": number, "method": ..., "params": ... }   expects a response
//   recv:  { "event": string, "payload": unknown }          broadcast
//          { "id": number, "result"|"error": ... }          response
//
// NOT a singleton, deliberately: a socket client is one per process, but a process client is one
// per child, and the ledger app may hold several.
QtObject {
    id: root

    // Set by the owner: takes one line INCLUDING its trailing newline and puts it on the wire.
    property var writeLine: null

    // Every {event, payload} broadcast, unfiltered.
    signal broadcast(string name, var payload)

    // True once a response has landed on the current connection. Owners clear it via reset().
    property bool ready: false

    property int _nextId: 1
    property var _pending: ({})

    // Request with an id-correlated response; onResult(result, error) is optional.
    function request(method, params, onResult) {
        const id = _nextId++;
        if (onResult)
            _pending[id] = onResult;
        _write(params === undefined ? { id, method } : { id, method, params });
        return id;
    }

    // Fire-and-forget command.
    function send(method, params) {
        _write(params === undefined ? { method } : { method, params });
    }

    function _write(message) {
        if (!writeLine)
            return;
        writeLine(JSON.stringify(message) + "\n");
    }

    // Feed one received line. Malformed lines are IGNORED rather than fatal: a half-written line or
    // a stray log write on the same stream must not take the client down.
    function feedLine(line) {
        const trimmed = (line || "").trim();
        if (trimmed.length === 0)
            return;
        let message;
        try {
            message = JSON.parse(trimmed);
        } catch (e) {
            return;
        }
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

    // Drop every outstanding callback. The owner MUST call this whenever the transport drops:
    // a response can never arrive for a request made on a dead connection, and keeping the
    // callbacks would leak them and mis-correlate the next connection's ids.
    function reset() {
        root._pending = {};
        root.ready = false;
    }
}
