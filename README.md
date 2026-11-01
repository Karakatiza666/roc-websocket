# roc-websocket

WebSocket (RFC 6455) for Roc, independent of any platform.

| Item | Value |
| --- | --- |
| Modules | `Ws` (shared types and features), `Client`, `Protocol`, `Handshake`, `Frame`, `CloseCode`, `Base64`, `Sha1` |
| Dependencies | none |
| Compiler | the Zig compiler (2026 nightlies). `.roc-version` names the nightly for CI. |
| Tests | `scripts/all_tests.sh` |
| License | UPL-1.0 (`LICENSE`) |

- **Shared types** (`Ws`): messages, how a connection closed, and each feature a
  platform may offer, as an extensible record alias. An adapter is a record of
  the operations its platform supports, so code that needs a feature does not
  compile with an adapter that lacks it.
- **A pure core with no I/O**: frames and masking (`Frame`), close codes
  (`CloseCode`), the opening handshake for both roles with `Sec-WebSocket-Accept`
  (`Handshake`, `Sha1`, `Base64`), and a state machine that assembles fragments,
  answers pings and runs the closing handshake (`Protocol`).
- **A client over bytes** (`Client`) for platforms where Roc owns the TCP
  connection. The platform adapter supplies a byte stream and randomness.

Adapters are separate packages, such as
[roc-basic-webserver-websocket](https://github.com/Karakatiza666/roc-basic-webserver-websocket)
and roc-cloudflare-workers-websocket. A platform that hands out whole messages
(Cloudflare Workers) implements `Ws.Core` directly and uses none of the pure core.

## Use

Add the package to the header with its release URL. The release notes of each
[release](https://github.com/Karakatiza666/roc-websocket/releases) give the URL.

```roc
app [...] {
	pf: platform "...",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.2/8ruw5bazzn7Xrtd3nGUTv5aGRVg3tSskgxeWbyGYsFZL.tar.zst",
}

import ws.Ws
```

### Connections are values

Each call takes the connection and returns the updated one, so the protocol
state (bytes read past a frame, a half-received message, a pending close)
carries from one call to the next. A platform whose host keeps the state
returns the same handle unchanged.

```roc
## Works with any adapter: `ops` is its operations record, `conn` a connection.
echo_once! : Ws.Core(c, e, r), c => Try(c, [Closed(Ws.Closure), Closing, ..e])
echo_once! = |ops, conn| {
	(conn2, message) = (ops.receive!)(conn)?
	(ops.send!)(conn2, message)
}
```

A client connection from `Client.open!` also has the operations as methods:
`conn.send!(Text("hi"))?`, `(conn2, reply) = conn.receive!()?`.

`close!` starts the closing handshake; `receive!` delivers the messages still on
their way and ends with `Err(Closed({ by: Us, .. }))`; meanwhile `send!` gives `Err(Closing)`.
`Ws.close_and_wait!(ops, conn, 1000, "")`
does both. `Ws.drive!(ops, conn, state, handlers)` runs push-style handlers
over a pull connection, threading `state`. `Ws.messages(ops, conn)` is a `Stream`
of the messages.

### Features

Every effectful field returns `[Closed(Ws.Closure), Closing, ..e]`. These two
tags are shared by every adapter: `Closed(closure)` once the connection has
ended, `Closing` from a field that sends when this endpoint can no longer send
and the closure is not known to it yet (the closing handshake is under way, or
the platform gives the closure only to `receive!` or `on_close!`). `e` holds the platform's tags and the tags a feature
adds (`InvalidClose(Str)`, `ControlTooLong(U64)`, `BadFrame(Str)`,
`Refused(Str)`, ...). One adapter uses one `e` for all its fields. In each alias
`c` is the connection and `r` the rest of the record.

| Alias | Fields |
| --- | --- |
| `Core(c, e, r)` | `send!`, `receive!`, `close!` |
| `Sender(c, e, r)` | `send!`, `close!`, for push-model servers |
| `Ping(c, e, r)`, `Pong(c, e, r)` | `ping!`, `pong!` (payload at most 125 bytes) |
| `Frames(c, e, r)` | `send_frame!`, `receive_frame!` |
| `ReceiveWithin(c, e, r)` | `receive_within!(conn, ms)`, `TimedOut` loses nothing |
| `Poll(c, e, r)` | `poll!`, `Idle` when the platform's own read deadline passed |
| `Buffered(c, e, r)` | `buffered_amount!` |
| `AutoResponse(c, e, r)` | a fixed text reply the runtime sends by itself; `c` is its scope (a connection or a whole server) |
| `Persist(c, e, r)` | per-connection state that survives the server leaving memory |
| `Topics(c, e, r)` | `subscribe!`, `unsubscribe!`, `publish!` |
| `Dial(c, e, r)` | open a client connection: `Opened(c)`, whose `extensions` are `Reported(list)` or `NotReported` |
| `Accept(q, p, c, e, r)` | accept an upgrade: `{ response : p, opened }`, `p` the 101 response a request handler returns to its runtime, or `{}` |
| `Handlers(s, c, e)` | push-model callbacks with state `s` |
| `Bytes(b, e, r)`, `Random(b, e, r)` | what the pure client needs from a platform |

Pre-composed: `Basic(c, e)`, `Raw(c, e)` (core, ping, pong, frames), `Timed(c, e)`,
`Push(c, e)`, `Transport(b, e)`, and `Client.Ops(b, e)` (`Raw` and `Poll`),
`Client.Link(b, e)`, `Client.Error(e)`.

### Writing an adapter over bytes

Give `Client.open!` a `Client.Link(b, e)` record and a link value `b`:
`write_bytes!`, `read_up_to!` (`Data(bytes)`, `End`, or `TimedOut` for a
platform deadline that consumed nothing) and `random_bytes!`. Connect the
stream (and do TLS for `wss://`) before calling it.

### The pure core

```roc
expect Handshake.accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

(protocol, events) = Protocol.new(Server, 1024).receive(bytes_from_the_wire)
# events: [Message(Text("...")), Write(pong_frame), Closed(closure), ...]
```

`examples/sans_io.roc` runs a server handshake and a few frames through the
state machine with no platform.

## Limits

- No extensions: `permessage-deflate` is never offered, and a server that picks
  one is refused.
- No server driver yet. The server handshake (`Handshake.parse_upgrade`,
  `accept_response`) and `Protocol` in the `Server` role are done and tested.
- `DESIGN.md` has the design, the platform analysis and what is left.

## Tests

```sh
ROC=/path/to/roc scripts/all_tests.sh   # fmt, check, expects, examples, tests/client.roc, docs
ROC=/path/to/roc scripts/bundle.sh 0.0.2  # dist/<hash>.tar.zst and its release URL
ROC=/path/to/roc scripts/test_bundle.sh   # the examples and tests against the bundle
```

124 `expect`s in `src/`: RFC 6455 vectors (the handshake key, the section 5.7
frames, fragmentation, close codes), RFC 4648 Base64 vectors, SHA-1 vectors, and
the protocol state machine. `tests/client.roc` runs the client over a scripted
link (21 checks: leftover bytes, a deadline inside a frame, `poll!`, the closing
handshake and `Closing`, `drive!`, `close_and_wait!`, refusals).

## Changes

### 0.0.2

Changes from the Cloudflare Workers adapter (DESIGN.md 0.10). Breaking:

- Every row is `[Closed(Ws.Closure), Closing, ..e]`. A field that sends gives
  `Closing` when it cannot send and does not know the closure; the client gives
  it after `close!` in place of a made-up `Closed`. `Ws.close_and_wait!` waits
  for a connection that is closing already.
- `Opened.extensions : [Reported(List(Str)), NotReported]`. The client gives
  `Reported([])`.
- `Accept(q, p, c, e, r)`: `accept!` gives `{ response : p, opened }`.
- `AutoResponse` documents its scope `c`.

### 0.0.1

The first release: the shared feature types, the pure core, and the client over
bytes.
