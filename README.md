# roc-websocket

WebSocket (RFC 6455) for Roc, independent of any platform.

| Item | Value |
| --- | --- |
| Modules | `Ws` (shared types and features), `Client`, `Server`, `Protocol`, `Handshake`, `Frame`, `CloseCode`, `Base64`, `Sha1` |
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
- **A server over bytes** (`Server`) for platforms where Roc accepts TCP
  connections itself. The platform adapter supplies a byte stream; no
  randomness.

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
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.6/6rcitHh7bVV7D4A2aubD6H6yLHUgtXLi6jRwxjomSwVv.tar.zst",
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
`Err(Closing)`. `Ws.close_and_wait!(ops, conn, CloseCode.normal, "")` does both.
`Ws.messages(ops, conn)` is a `Stream` of the messages whose last item is the
error that ended it, `Err(Closed(closure))` at the end of the connection.

`Ws.drive!(ops, conn, state, handlers)` runs push-style handlers
(`Ws.Handlers(s, c, e)`) over a pull connection, threading `state`. It returns
the state together with how the run ended, so an error does not lose it:

```roc
handlers = {
	on_open!: |count, conn| Ok((count, conn)),
	on_message!: |count, conn, message| match conn.send!(message) {
		Ok(sent) => Ok((count + 1, sent))
		Err(err) => Err(err)
	},
	on_close!: |count, _conn, _closure| Ok(count),
}
(count, ended) = Ws.drive!(ops, conn, 0, handlers)
# count: the state of on_close!, or of the last handler that succeeded
closure = ended?
```

`ended` is `Ok(closure)` after `on_close!` ran, or `Err(err)` for a handler's
error (other than `Closed`, which only ends the sending: `drive!` delivers the
messages left and calls `on_close!`) or an error of `receive!`. `on_close!`
gets the connection as the last call left it, for what the value holds (a link
to close, an id to forget).

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
| `ReceiveWithin(c, e, r)` | `receive_within!(conn, ms)`: `TimedOut` when `ms` ms have passed since the call, whatever arrives meanwhile (Ping, Pong and partial frames do not extend it); an adapter that cannot bound the whole call leaves the field out; `TimedOut` loses nothing |
| `Poll(c, e, r)` | `poll!`, an idle deadline: `TimedOut` only when one read passes the platform's read deadline with no bytes; any frame, a Ping included, restarts it, so it cannot build a deadline for data messages |
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
`Client.Transport(b, e)`, `Client.Error(e)`, with the same three for `Server`.

### Writing an adapter over bytes

Give `Client.open!` a `Client.Transport(b, e)` record and a link value `b`:
`write_bytes!`, `read_up_to!` (`Data(bytes)`, `End`, or `TimedOut` for a
platform deadline that consumed nothing) and `random_bytes!`. Connect the
stream (and do TLS for `wss://`) before calling it. `conn.link()` gives the
link value back and `conn.map_link(change)` changes it between calls (a read
timeout for one call, for example) without touching the protocol state.

### A server over bytes

The adapter accepts a TCP connection and gives `Server.accept!` a
`Server.Transport(b, e)` record (`write_bytes!` and `read_up_to!`, no
`random_bytes!`) and the link value `b`:

```roc
opened = Server.accept!(transport, link, { protocols: ["chat"], max_message: 1024 * 1024 })?
# opened.protocol: the first of `protocols` (the server's preference) that the client offered, or ""
(state2, ended) = Ws.drive!(Server.ops({}), opened.conn, state, handlers)
```

- `Server.accept! : Server.Transport(b, e), b, Ws.AcceptOptions => Try(Ws.Opened(Server.Conn(b, e)), Server.Error(e))`
  reads the upgrade request, writes the 101 and returns the connection. No
  extension is accepted (`extensions` is `Reported([])`).
- `Server.read_request! : Server.Transport(b, e), b => Try(Server.Request(b, e), Server.Error(e))`
  stops after reading, for an app that decides from the request:
  `request.upgrade()` gives its resource, `Host`, offered subprotocols and
  headers (`Ws.Upgrade`, names lowercased); then `request.accept!(options)`,
  or `request.refuse!({ status: 403, headers: [...], body: "..." }) : Try(b, ...)`
  (a `Ws.Refusal`), which writes the refusal and gives the link back. Any
  final status refuses, 200 to 599: a 3xx with a `Location` header, a 401
  with `WWW-Authenticate`, a 4xx or 5xx. `request.map_link(change)`
  changes the link before either, so an adapter can read the request with a
  short handshake deadline and hand out a request whose connection reads with
  its normal one.
- `Server.Conn(b, e)` has the methods of `Client.Conn` (`send!`, `receive!`,
  `poll!`, `close!`, `ping!`, `pong!`, `send_frame!`, `receive_frame!`,
  `link`, `map_link`); `Server.ops({})` is the record (`Server.Ops(b, e)`).
  Frames it sends are unmasked; a client frame that is not masked fails the
  connection with 1002.
- `Server.Errors(e) = [NotUpgrade(Str), InvalidStatus(U16), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e]`.
  `NotUpgrade(why)`: the request was not a valid upgrade, and the server has
  answered it (400, 405, 426, or 431 for a head over
  `Server.max_request_head`, 16 KiB), or the stream ended or the platform's
  deadline passed before the end of the head (nothing written).
  `InvalidStatus(status)`: `refuse!` with a status outside 200-599 (a 1xx,
  101 among them, ends no HTTP exchange), nothing written.

The request read is bounded by `Server.max_request_head`, handles a request
split across reads, and keeps bytes sent behind the head as the first frames.
`close!` starts the closing handshake as in the client; once `receive!` gives
`Closed`, the adapter closes the stream (`conn.link()`).

When the peer's last messages and its Close arrive in one read, the Close is
answered once those messages are delivered: replies to them are sent first,
and the next `receive!` (or `poll!`, `receive_frame!`, `close!`) writes the
echo and gives `Closed`. This holds for both roles, and matches a push
platform such as Workers, whose runtime delivers the messages before the
close.

### The pure core

```roc
expect Handshake.accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

(protocol, events) = Protocol.new(Server, 1024).receive(bytes_from_the_wire)
# events: [Message(Text("...")), Write(pong_frame), Closed(closure), ...]
```

`examples/sans_io.roc` runs a server handshake and a few frames through the
state machine with no platform; `examples/echo_server.roc` runs `Server.accept!`
and `Ws.drive!` over a scripted link.

## Limits

- No extensions: `permessage-deflate` is never offered, and a server that picks
  one is refused.
- The server answers one connection per `accept!`; serving several at once
  (a loop over `poll!`, or threads) is the adapter's or the app's. The 101
  has no extra headers.
- A server waiting for the client's answer to its Close is bounded only
  through `poll!`, by the app.
- The echo of the peer's Close is held while messages read with it wait to be
  delivered (see above). An app that stops reading after the last message
  (it never calls `receive!`, `poll!`, `receive_frame!` or `close!` again)
  sends no echo, and the peer sees the stream end with no Close.
- `max_message`: with none in `Ws.ConnectRequest` or `Ws.AcceptOptions`, the
  limit is the adapter's, 16 MiB over bytes (`Client.default_max_message`,
  `Server.default_max_message`). A longer message fails the connection with
  1009: `Closed({ code: 1009, by: Us, clean: Bool.False, .. })`.
- `DESIGN.md` has the design, the platform analysis and what is left.

## Tests

```sh
ROC=/path/to/roc scripts/all_tests.sh   # fmt, check, expects, examples, tests/, docs
ROC=/path/to/roc scripts/bundle.sh 0.0.6  # dist/<hash>.tar.zst and its release URL
ROC=/path/to/roc scripts/test_bundle.sh   # the examples and tests against the bundle
```

133 `expect`s in `src/`: RFC 6455 vectors (the handshake key, the section 5.7
frames, fragmentation, close codes), RFC 4648 Base64 vectors, SHA-1 vectors, and
the protocol state machine. `tests/client.roc` runs the client over a scripted
link (28 checks: leftover bytes, a deadline inside a frame, `poll!`, the closing
handshake and `Closing`, the held echo, `max_message`, generic code over a
closed record, `messages`, `drive!`, `close_and_wait!`, refusals).
`tests/server.roc` runs the server (64 checks: a request split across reads, the
bounded read and 431, bad upgrades, refusals with any final status, the
subprotocol choice in the server's order, extensions declined, unmasked client
frames failing with 1002, Ping and Pong, a close by either side, the held echo,
`drive!` with its state on every end), and a client and a server wired together
in memory.

## Changes

### 0.0.6

No type changes. The package now builds on Roc `nightly-2026-11-07-ad3a5d2`.

| Change | Detail |
| --- | --- |
| Roc nightly | Pinned to `nightly-2026-11-07-ad3a5d2`. In this nightly, the size argument of `Stream.custom` is `Try(U64, [Unknown])`. `Ws.messages` passes `Err(Unknown)` as the size. Its type and behaviour do not change. |
| Deadlines | The documentation states the meaning of the two deadline features. See the list below. |

The meaning of the two deadline features:

- `Ws.ReceiveWithin`: `receive_within!(c, ms)` is a total deadline. It gives
  `TimedOut` when `ms` milliseconds have passed since the call, whatever
  arrives meanwhile; Ping, Pong and partial frames do not extend it. An adapter
  that cannot bound the whole call leaves the field out.
- `Ws.Poll`: `poll!` is an idle deadline. It gives `TimedOut` only when one
  read passes the platform's read deadline with no bytes. Any frame, a Ping
  included, restarts it, so it cannot be used to build a deadline for data
  messages. An adapter that implements `receive_within!` as `map_link`, then
  `poll!`, then `map_link` must keep the total deadline in the link and answer
  `TimedOut` from `read_up_to!` itself once it has passed.
- `tests/client.roc` checks that composition over a link whose peer sends a
  Ping per read, with a counter as the clock (the package has no clock). The
  real-time test is in roc-basic-cli-websocket's e2e suite.

### 0.0.5

Breaking, with the migration:

- `Ws.Handlers`: `on_close!` gets the connection, after the state as in
  `on_open!` and `on_message!`:
  `on_close! : s, c, Ws.Closure => Try(s, Ws.Error(e))`.

  ```roc
  # 0.0.4
  on_close!: |state, closure| Ok(state),
  # 0.0.5
  on_close!: |state, _conn, closure| Ok(state),
  ```
- `Ws.drive!` returns the state with how the run ended,
  `(s, Try(Ws.Closure, Ws.Error(e)))`, so an error no longer loses the state.
  It is not a `Try`, so `drive!(...)?` no longer compiles:

  ```roc
  # 0.0.4
  state2 = Ws.drive!(ops, conn, state, handlers)?
  # 0.0.5
  (state2, ended) = Ws.drive!(ops, conn, state, handlers)
  closure = ended?
  ```

  `Ok(closure)` comes after `on_close!`, whose state is `state2`; with
  `Err(err)`, `state2` is the state of the last handler that succeeded (the
  initial state when `on_open!` fails).
- `Ws.drive!`: a handler that fails with `Closed` no longer ends the run; the
  messages left are delivered from the connection as it was before that
  call, and `on_close!` runs. Other handler errors end it as before.
- The echo of the peer's Close waits until the messages read with it are
  delivered, so a reply to one of them is sent (it gave `Closed` before). An
  app that never reads again after the last message sends no echo. Both
  roles.

Added:

- `Server`: `Server.accept!`, `Server.read_request!`, `Server.Request(b, e)`
  (`upgrade`, `accept!`, `refuse!`, `map_link`), `Server.Conn(b, e)`,
  `Server.ops`, `Server.Ops`, `Server.Transport`, `Server.Errors`,
  `Server.Error`, `Server.default_max_message`, `Server.max_request_head`.
  The subprotocol is the first of `options.protocols` (the server's order of
  preference) that the client offered. `refuse!` takes any final status,
  200 to 599.
- `Ws.Upgrade`, the request a server sees (`resource`, `host`, `protocols`,
  `headers`), and `Ws.Refusal`, how it refuses (`status`, `headers`, `body`).
  Shared by every server adapter; how a refusal is sent is the platform's.
- `Handshake.refusal(status, headers, body)`, any refusal response
  (`Handshake.rejection` is `refusal(status, [], why)`, and its output is
  unchanged), with reason phrases for 200, 301, 302, 303, 307, 308, 401, 403,
  404, 408, 429, 431, 500 and 503; `Handshake.head_end(bytes, from)`.
- `Protocol.expects`, the masking a received frame must have.

Changed, not breaking:

- `Handshake.choose_protocol(upgrade, supported)` picks by the order of
  `supported`, not of the client's offer.
- `max_message` is documented on `Ws.ConnectRequest` and `Ws.AcceptOptions`.
- `Client.Conn` now holds the frame I/O that it shares with `Server.Conn`; its
  methods, types and behaviour are otherwise unchanged.
- Pinned to Roc `nightly-2026-11-03-34bd006`.

### 0.0.4

Added, non-breaking: `Client.Conn.map_link : Conn(b, e), (b -> b) -> Conn(b, e)`.
`Conn` is opaque, so an adapter could not change its link; `map_link` applies a
function to the link value and keeps the protocol state (bytes read past a
frame, a half-received message, a pending close). An adapter whose stream has a
per-call read timeout can set it, then call `poll!`. (That bounds each read,
not the call: see 0.0.6, which says how to make the deadline total.)

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
