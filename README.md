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
implements `Ws.Core` directly and uses none of the pure core.

## Use

Add the package to the header with its release URL. The release notes of each
[release](https://github.com/Karakatiza666/roc-websocket/releases) give the URL.

```roc
app [...] {
	pf: platform "...",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.3/FvsFHmH7m6LoMumXLxEHEfUoApGWdkgoFshfYEctaMNM.tar.zst",
}

import ws.Ws
```

### Connections are values

Each call takes the connection and returns the updated one, so the protocol
state (bytes read past a frame, a half-received message, a pending close)
carries from one call to the next. A platform whose host keeps the state
returns the same handle unchanged.

Code that needs a few operations takes a closed record of exactly those
fields, so it works with every adapter that has them. `Ws.Error(e)` is the
error union every field shares:

```roc
## Answers one message with the same message.
echo_once! : { send! : c, Ws.Message => Try(c, Ws.Error(e)), receive! : c => Try((c, Ws.Message), Ws.Error(e)) }, c => Try(c, Ws.Error(e))
echo_once! = |ws, conn| {
	(conn2, message) = (ws.receive!)(conn)?
	(ws.send!)(conn2, message)
}
```

The app picks the fields from its adapter's operations record:
`echo_once!({ send!: ops.send!, receive!: ops.receive! }, conn)`. A layer that
forwards a whole adapter takes the open alias instead, `Ws.Core(c, e, r)`.
A connection of an adapter usually has the operations as methods too:
`conn.send!(Text("hi"))?`, `(conn2, reply) = conn.receive!()?`.

`close!` starts the closing handshake; `receive!` delivers the messages still on
their way and ends with `Err(Closed({ by: Us, .. }))`; meanwhile `send!` gives
`Err(Closing)`. `Ws.close_and_wait!(ops, conn, CloseCode.normal, "")` does both. `Ws.drive!(ops, conn, state, handlers)` runs push-style handlers
over a pull connection, threading `state`. `Ws.messages(ops, conn)` is a `Stream`
of the messages whose last item is the error that ended it, `Err(Closed(closure))`
at the end of the connection.

### Features

Every effectful field returns `Ws.Error(e)`, which is
`[Closed(Ws.Closure), Closing, ..e]`. These two tags are shared by every adapter: `Closed(closure)` once the connection has
ended, `Closing` from a field that sends when this endpoint can no longer send
and the closure is not known to it yet (the closing handshake is under way, or
the platform gives the closure only to `receive!` or `on_close!`). `e` holds the platform's tags and the tags a feature
adds (`InvalidClose(Str)`, `ControlTooLong(U64)`, `BadFrame(Str)`,
`Refused(Str)`, ...). One adapter uses one `e` for all its fields. In each alias
`c` is the connection and `r` the rest of the record. By convention a module's
`Errors` is its row `e` and its `Error` the whole union (`Client.Errors(e)`,
`Client.Error(e)`).

| Alias | Fields |
| --- | --- |
| `Core(c, e, r)` | `send!`, `receive!`, `close!` |
| `Sender(c, e, r)` | `send!`, `close!`, for push-model servers |
| `Ping(c, e, r)`, `Pong(c, e, r)` | `ping!`, `pong!` (payload at most 125 bytes) |
| `Frames(c, e, r)` | `send_frame!`, `receive_frame!` |
| `ReceiveWithin(c, e, r)` | `receive_within!(conn, ms)`, `TimedOut` loses nothing |
| `Poll(c, e, r)` | `poll!`, `TimedOut` when the platform's own read deadline passed |
| `Buffered(c, e, r)` | `buffered_amount!` |
| `AutoResponse(c, e, r)` | a fixed text reply the runtime sends by itself; `c` is its scope (a connection or a whole server) |
| `Persist(c, e, r)` | per-connection state that survives the server leaving memory |
| `Topics(c, e, r)` | `subscribe!`, `unsubscribe!`, `publish!` |
| `Connect(c, e, r)` | `connect!(request)` opens a client connection: `Opened(c)`, whose `extensions` are `Reported(list)` or `NotReported` |
| `Accept(q, p, c, e, r)` | accept an upgrade: `{ response : p, opened }`, `p` the 101 response a request handler returns to its runtime, or `{}` |
| `Handlers(s, c, e)` | push-model callbacks with state `s` |
| `Bytes(b, e, r)`, `Random(b, e, r)` | what the pure client needs from a platform |

Pre-composed: `Basic(c, e)`, `Raw(c, e)` (core, ping, pong, frames), `Timed(c, e)`,
`Push(c, e)`, `Transport(b, e)`, and `Client.Ops(b, e)` (`Raw` and `Poll`),
`Client.Transport(b, e)`, `Client.Error(e)`.

### Writing an adapter over bytes

Give `Client.open!` a `Client.Transport(b, e)` record and a link value `b`:
`write_bytes!`, `read_up_to!` (`Data(bytes)`, `End`, or `TimedOut` for a
platform deadline that consumed nothing) and `random_bytes!`. Connect the
stream (and do TLS for `wss://`) before calling it. `conn.link()` gives the
link value back.

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
ROC=/path/to/roc scripts/bundle.sh 0.0.3  # dist/<hash>.tar.zst and its release URL
ROC=/path/to/roc scripts/test_bundle.sh   # the examples and tests against the bundle
```

124 `expect`s in `src/`: RFC 6455 vectors (the handshake key, the section 5.7
frames, fragmentation, close codes), RFC 4648 Base64 vectors, SHA-1 vectors, and
the protocol state machine. `tests/client.roc` runs the client over a scripted
link (23 checks: leftover bytes, a deadline inside a frame, `poll!`, the closing
handshake and `Closing`, generic code over a closed record, `messages`, `drive!`,
`close_and_wait!`, refusals).

## Changes

### 0.0.3

API cleanup from an audit of the two adapters. Breaking, with the migration:

- `Ws.Poll`: `poll!` gives `TimedOut`, not `Idle`, when the platform's read
  deadline passes, the same tag as `Ws.ReceiveWithin` and `Ws.Bytes`. Match
  `Ok((conn, TimedOut))` in place of `Ok((conn, Idle))`; an adapter that
  implements `Poll` returns `TimedOut`.
- `Client.Link(b, e)` is now `Client.Transport(b, e)` (the operations record
  `Client.open!` takes; the link value is still `b`). Rename it in type
  annotations.
- `Client.Conn(b, e)` is opaque: its fields cannot be read or built outside
  `Client`. `conn.link()` gives the link value (it was `conn.link`).
- `Client.read_size` is no longer public.
- `Ws.Dial(c, e, r)` is now `Ws.Connect(c, e, r)`, matching `Accept` and
  `accept!`; the field is still `connect!`. Rename it in type annotations.
- `Ws.Request` is now `Ws.ConnectRequest` (the `Accept` alias's `q` is the
  server's incoming request). Rename it in type annotations.
- `Ws.messages` no longer drops the closure: the stream's last item is
  `Err(Closed(closure))` (any other error was already an `Err` item). Code that
  treated every `Err` item as a failure should match `Err(Closed(_))` as the
  normal end.

Added: `Ws.Error(e)`, a name for `[Closed(Ws.Closure), Closing, ..e]`, used by
every alias; `Client.Error(e)` is `Ws.Error(Client.Errors(e))`, the same type
as before. Writing the union out still works.

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
