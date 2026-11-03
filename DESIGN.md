# roc-websocket: design and platform analysis

Status: version 0.0.4 is implemented in `src/` (shared types, pure core, byte-level
client), and the byte-level server driver of 0.13 since (not released yet), with adapters in the sibling repos `roc-basic-webserver-websocket` and
`roc-cloudflare-workers-websocket`. Section 0 lists what the implementation settled or
changed; where it disagrees with a later section, section 0 wins. The rest is the
original analysis, kept for its platform findings and citations.

Citations are `file:line`. Paths are abbreviated:

| Short | Full path / source |
| --- | --- |
| `surreal/` | `examples/reifying/surreal/` on the `reify` branch of Karakatiza666/roc (not yet published) |
| `cli/` | basic-cli 0.26.0 bundle, `~/.cache/roc/packages/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t/` |
| `bws/` | basic-webserver tag 0.19.0 (commit `1654ae3f7f`), cloned read-only |
| `cfw/` | the `cloudflare-workers` platform ([roc-cloudflare-workers](https://github.com/Karakatiza666/roc-cloudflare-workers)) |
| `Builtin.roc` | `src/build/roc/Builtin.roc` in roc-lang/roc |

"Inference" marks a claim that was not read in code or verified by a probe.

---

## 0. Implementation (versions 0.0.1 to 0.0.4): settled and changed decisions

### 0.1 Modules

| Module | Contents |
| --- | --- |
| `Ws` | `Error(e)`, `Message`, `Closure`, `ConnectRequest`, `Opened(c)`, `AcceptOptions`; the feature aliases; the pre-composed aliases; `messages`, `close_and_wait!`, `drive!` (generic over any adapter's operations), `dropped` |
| `Frame` | `Frame := { fin, opcode, payload }` (`is_eq` derived), `Opcode`, `Masking`, `Expect`, `Header`; `encode`, `header`, `decode`, `mask`, `fragments`, constructors |
| `CloseCode` | named codes, `is_sendable` (1000-1003, 1007-1014, 3000-4999), `payload`, `parse` |
| `Base64`, `Sha1` | encode/decode; SHA-1 (FIPS 180-4) |
| `Handshake` | `parse_url`, `client_request`, `check_response` (status, Upgrade, Connection, Sec-WebSocket-Accept, no extensions, offered subprotocol only), `parse_upgrade`, `accept_response`, `choose_protocol`, `rejection` (400/405/426), `refusal` (any status, headers, body), `accept_key`, `head_wanted`, `head_end` |
| `Protocol` | sans-IO receive state machine, both roles: `new`, `receive : Protocol, List(U8) -> (Protocol, List(Event))`, `close`, `fail`, `ended`, `closure`, `closing`, `push`/`take_frame` (raw frames), `wanted`, `is_idle`, `is_open`, `is_done`, `masking`, `expects` |
| `Client` | `Client.Conn(b, e)` (opaque; methods `send!`, `receive!`, `poll!`, `close!`, `ping!`, `pong!`, `send_frame!`, `receive_frame!`, `link`, `map_link`), `Client.open!`, `Client.ops`, `Client.default_max_message`, `Client.Errors`, `Client.Error`, `Client.Transport`, `Client.Ops` |
| `Server` | `Server.Conn(b, e)` (opaque; the methods of `Client.Conn`), `Server.Request(b, e)` (opaque; `upgrade`, `accept!`, `refuse!`), `Server.accept!`, `Server.read_request!`, `Server.ops`, `Server.Errors`, `Server.Error`, `Server.Transport`, `Server.Ops`, `Server.Refusal`, `Server.default_max_message`, `Server.max_request_head` (0.13) |
| `Session` | not exposed: frame I/O over a byte link after the handshake, for both roles (0.13) |

`Assembler` and `Mask` (section 4) are not separate modules: assembly is part of
`Protocol`, masking is `Frame.mask`.

### 0.2 The connection is a value (changes 3.2, 3.3, 3.5)

Each effectful call takes the connection and returns the updated one with its
result, so the protocol state carries from call to call:

```roc
Error(e) : [Closed(Ws.Closure), Closing, ..e]

Core(c, e, r) : {
	send! : c, Ws.Message => Try(c, Ws.Error(e)),
	receive! : c => Try((c, Ws.Message), Ws.Error(e)),
	close! : c, U16, Str => Try(c, Ws.Error(e)),
	..r
}
```

Every feature alias takes `c, e, r` in that order, after its own parameters
(`Accept(q, p, c, e, r)`); `Handlers(s, c, e)` is a closed record. An adapter's operations are a
record typed by the aliases it supports (`WsClient.ops : Client.Ops(...)`), and
the connection a separate value: generic code takes both,
`Ws.close_and_wait!(ops, conn, 1000, "")`. A client connection is the opaque
`Client.Conn(b, e)` (since 0.0.3; `conn.link()` gives the link value), so app code can also call its methods directly:
`(conn2, message) = conn.receive!()?`. A generic operations record is a
function, `Client.ops({})`, because a value cannot be polymorphic; an adapter
with concrete types exposes a plain value.

Check against the other platform shapes:

- **A message-level platform whose host keeps the state** (Cloudflare Workers):
  `c` is the host's socket handle, and every call returns it unchanged. Nothing
  else changes for such an adapter.
- **Push `Handlers`**: `Handlers(s, c, e)` threads the application's state `s`
  and the connection through the calls: `on_message! : s, c, Ws.Message =>
  Try((s, c), Ws.Error(e))`. `Ws.drive!` runs handlers over a pull
  connection and is tested. On a runtime that drops the server between events
  (a hibernating Durable Object) the adapter persists `s` itself or the
  application keeps `s` as `{}`.
- **Inputs of the pure client**: the link is a value `b` too.
  `Bytes(b, e, r)` has `read_up_to! : b, U64 => Try((b, [Data(List(U8)), End, TimedOut]), ...)`
  and `Random(b, e, r)` has `random_bytes! : b, U64 => Try((b, List(U8)), ...)`,
  so a link may carry a generator's state. A read that hit a platform
  deadline is `Ok(TimedOut)` with the link, not an error.

Errors drop the connection: after an `Err` other than one the call documents as
leaving the connection usable, the caller has only the value from before the
call. The client never returns an error that loses state: a platform deadline is
`TimedOut` in the `Ok` side of `poll!` (`Idle` before 0.0.3), and `receive!` keeps waiting through it.

### 0.3 The two forced decisions of the stateless version, revisited

Version 0.1 had no state between calls, which forced two things. Both are gone:

1. **`close!` starts the close; `receive!` finishes it.** `close!` sends Close
   and returns the connection. `receive!` then delivers the messages already on
   their way and ends with `Closed({ by: Us, clean: True, .. })` when the peer's
   Close arrives. `send!` after `close!` is `Closing` (0.0.1 gave `Closed` with
   the code sent and `clean: False`, a closure made up before the end; 0.10). The
   blocking form is the generic helper `Ws.close_and_wait!`, which works with any
   adapter. Once a connection has ended, every call on it returns the same
   `Closed` closure (0.1 gave 1006 after the first).
2. **Reads keep leftover bytes.** The client reads up to 64 KiB at a time. Bytes
   past the current frame stay in the `Protocol`, messages of one read wait in an
   inbox, and the handshake head and the first frames may arrive in one read.
   A platform deadline inside a frame loses nothing, since the partial frame is in
   the returned connection. On basic-webserver this replaces 0.1's exact-size
   reads, which avoided the lost bytes of a timed-out `read_exactly!` only by
   reading one header field at a time.

### 0.4 Errors: one row shape everywhere (changes 3.2, 3.3, 3.6)

Every effectful field of every alias returns `Ws.Error(e)`, `[Closed(Ws.Closure), Closing, ..e]`, with
the same `e` in every field of an adapter, including the inputs `Bytes` and
`Random`. Fields with their own fixed tags do not work in code generic in `e`,
verified with this compiler:

- A rigid row cannot be widened: a value of `[..e]` is rejected where
  `[Closed(Closure), BadFrame(Str), ..e]` is expected, and a match arm
  `Err(other) => Err(other)` keeps the full type (the narrowing limit of 3.6
  item 2 also holds for widening).
- A tag may not be both a fixed tag of an alias and inside the row passed to it
  (`Core([Closed(U16), Io(Str)], {})` is a type mismatch, reported as "the
  annotation says it should be: `[]`").

So a failure a feature adds is a tag of `e` by documented convention:
`InvalidClose(Str)`, `ControlTooLong(U64)`, `BadFrame(Str)`, `TooLarge(U64)`,
`Refused(Str)`, `NotUpgrade(Str)`. The client fixes its tags in
`Client.Errors(e) = [Refused(Str), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e]`
and requires the link's row to be `Client.Errors(e)`, so link errors flow into
connection errors with no mapping. A platform adds only its own tags
(basic-webserver: `[Tcp(Str), Connect(Str), Entropy(Str)]`). `Closed` and
`Closing` are the shared tags (Q6 settled; `Closing` since 0.0.2, 0.10). Outcomes that are not failures are in the `Ok` side:
`ReceiveWithin` and `Poll` give `TimedOut` (one tag for "the deadline passed,
nothing lost", whoever chose the deadline), `Persist.saved!` gives `Nothing`.
Naming: a module's `Errors` is its row `e`, its `Error` the whole union
(`Client.Error(e) = Ws.Error(Client.Errors(e))`).

### 0.5 Features (changes 3.3; generic, not shaped by one platform)

Each alias describes a feature as it appears on any platform that has it:
`Core`, `Sender`, `Ping`, `Pong`, `Frames`, `ReceiveWithin` (a deadline the
application picks), `Poll` (a receive bounded by the platform's own read
deadline, which is what basic-webserver can do exactly), `Buffered`,
`AutoResponse` (a fixed text reply the runtime sends by itself), `Persist`
(per-connection state that survives the server leaving memory), `Topics`
(publish/subscribe groups), `Connect` (`Dial` before 0.0.3), `Accept`, `Handlers`, and the inputs `Bytes`
and `Random`. Generalized or dropped from 3.3: `Hibernation` became `Persist`
without tags (connection tags are a Workers notion; the general grouping feature
is `Topics`); `AutoResponse` lost `auto_response_ms!` (a Workers timestamp).
WebSocketPair and Durable Object specifics stay in the Cloudflare adapter.
Negotiated values stay values: `Opened(c) = { conn, protocol, extensions }`, with
`extensions : [Reported(List(Str)), NotReported]` since 0.0.2 (0.10).

Pre-composed aliases: `Basic(c, e)`, `Raw(c, e)` (core, ping, pong, frames),
`Timed(c, e)`, `Push(c, e)`, `Transport(b, e)`; the client adds `Client.Ops(b, e)`
(`Raw` and `Poll`), `Client.Transport(b, e)` (`Client.Link` before 0.0.3) and
`Client.Error(e)`.

### 0.6 Adapters are packages (Q1 settled)

An adapter is a separate package that depends on its platform and on
roc-websocket (`roc-basic-webserver-websocket`, `roc-cloudflare-workers-websocket`,
which uses no pure core). A package that names a platform works when the app names the
identical platform URL. `roc bundle` refuses an adapter while it depends on
roc-websocket by path, so roc-websocket is released first.

### 0.7 Randomness (Q4 settled)

Randomness is an input feature, `Ws.Random(b, e, r)`, implemented by each
adapter: 16 bytes for the key, 4 per frame for the mask. basic-webserver has no
random effect; its adapter reads `/dev/urandom` with
`File.open_reader_with_capacity!`/`read_line!` (the only file read it has is by
line), drops the newline, hashes at least 48 bytes (each uniform over 255 values,
over 383 bits) with `Crypto.SHA256` and uses the 32-byte digest. Unix only.

### 0.8 Not done yet

The server side of the basic-cli adapter (`WsServer`, 0.13; the driver is
done), `wss://` in the pure client, sending a message in fragments by size (the
caller uses `Frame.fragments` with `send_frame!`), extra headers on the
server's 101, and a bounded wait for the answer to a Close (an app uses
`poll!`).

### 0.9 Compiler issues met

- `x = conn.receive!()?` in an app's `main!`, with the connection's error row
  closed (`Client.Error([])`), passes `roc check` and then panics in post-check
  monotype: "instantiation widened a closed tag union"
  (`src/postcheck/monotype/solve.zig:8129`). A `match` avoids it, and
  `tests/client.roc` uses a helper `ok` instead of `?`. The same `?` in the
  basic-webserver example (a closed row with platform tags) works. A small
  standalone copy did not reproduce; the full repro is kept outside the repo.
- `roc fmt` joins a multi-line record alias that has an extension row (`..r`)
  onto one line, so the feature aliases are long lines.

### 0.10 Changes in 0.0.2, from the Cloudflare Workers adapter

The adapter for the cloudflare-workers platform found three places where the
shared types asked for something a platform in general cannot give:

- **`Closing`.** A send on a connection that is closing or closed had to give
  `Closed(Ws.Closure)`. A push-model server learns the closure only in its
  close callback (a Durable Object's `webSocketClose`; the same for Bun, Deno,
  browsers), and during the closing handshake no endpoint knows the final
  closure yet; the 0.0.1 client made one up (`clean: False`). Now every row is
  `[Closed(Ws.Closure), Closing, ..e]`: `Closing` from a field that sends when
  the closure is not known to it, `Closed` once it is. One row for every field,
  receiving ones included (they never give `Closing`), so generic code mixes
  fields with no widening (0.4). `Ws.close_and_wait!` waits for a connection
  that is closing already.
- **`Opened.extensions : [Reported(List(Str)), NotReported]`.** A runtime that
  negotiates and applies an extension itself may not tell the application
  (workerd negotiates `permessage-deflate` while the socket's `extensions` is
  `""`). The client gives `Reported([])`: it offers none.
- **`Accept(q, p, c, e, r)`** gives `{ response : p, opened : Ws.Opened(c) }`.
  On a platform whose request handler returns the 101 response (Workers,
  Deno's `upgradeWebSocket`), the application returns `response` to its
  runtime and uses the connection in work that runs after; a server that
  writes the response itself uses `p = {}`.
- **`AutoResponse` scope**, documented: `c` is the scope the runtime sets the
  reply for, a connection or a whole server.

### 0.11 Changes in 0.0.3, from an audit of the API and the two adapters

- **`Ws.Error(e)`** names the shared row; every alias and helper uses it.
  Purely a name: the type is unchanged.
- **`Poll` gives `TimedOut`**, not `Idle`. The client's `poll!` mapped the
  link's `TimedOut` to `Idle`: two names for one outcome. `ReceiveWithin`,
  `Poll` and `Bytes` now share `TimedOut`.
- **`Client.Link` became `Client.Transport`**: in the client, `link` also named
  the link value `b` (`conn.link`, the adapter's `Link` type), while
  `Client.Link` was the operations record. `Client.Transport(b, e)` is
  `Ws.Transport(b, Client.Errors(e))`.
- **`Client.Conn` is opaque** (`::`): an app could build one with no handshake
  or read its protocol state. `conn.link()` gives the link value back.
  `Client.read_size` is private.
- Docs: the module doc of `Ws` named only `Closed` as shared; `AcceptOptions`
  did not document `max_message`; `Client.poll!` named a platform's deadline.
- **`Dial` became `Connect`** (its field is `connect!`, as `Accept` has
  `accept!`), and **`Ws.Request` became `Ws.ConnectRequest`**: `q` in `Accept`
  is a request too, the server's.
- **`Ws.messages` ends with the closure**: its last item is
  `Err(Closed(closure))`, the error that ended it, as for any other error.
  It used to end with no item, so the closure was lost.

### 0.12 Changes in 0.0.4

- **`Client.Conn.map_link`** (additive): `Conn(b, e), (b -> b) -> Conn(b, e)`.
  `Conn` is opaque, so an adapter could not change its link, such as a stream's
  read timeout for one call. `map_link` leaves the protocol state alone. An
  adapter implements `Ws.ReceiveWithin` as `map_link` (set the timeout), then
  `poll!`, then `map_link` (restore it). It is generic: it knows nothing about
  what `b` holds.

Considered and kept (each a design choice, listed in the 0.0.3 audit):
`Errors`/`Error` (one letter apart, but now a stated convention), `Basic` and `Push` (one-alias compositions), `Closing` in the rows of
receiving fields (needed so generic code mixes fields with no widening, 0.4),
`Handlers(s, c, e)` with the state first, and the helpers taking open records
(`{ receive! : ..., .. }`, so an adapter's whole record passes as is).

### 0.13 The server driver over bytes

This replaces the `accept!` sketch of 3.5. It is the server half of what
`Client` is: for a platform where Roc owns the wire and accepts TCP
connections itself (basic-cli's `Tcp.listen!`/`accept!`). The platform adapter
accepts the TCP connection and gives the driver a byte link; the driver reads
the HTTP upgrade request, answers it, and returns a connection that does frame
I/O in the `Server` role.

#### Module layout: `Server` beside `Client`, one private `Session` under both

```
Client  (public)  the opening handshake of a client; Client.Conn holds a Session
Server  (public)  the opening handshake of a server; Server.Conn holds a Session
Session (private) frame I/O over a byte link after the handshake, either role
```

After the handshake the two roles differ in two facts: the masking of a frame
this endpoint sends (a client masks with 4 random bytes, a server does not
mask) and the masking a received frame must have (`Protocol` checks that, from
its role). Everything else (the read loop, leftover bytes, the inbox, Ping
replies, the closing handshake, raw frames, `poll!`) is the same code. So it
lives once, in a module `Session` that the package does not expose:

```roc
Session(b, e) :: {
	bytes : Ws.Bytes(b, Session.Errors(e), {}),
	mask! : b => Try((b, Frame.Masking), Ws.Error(Session.Errors(e))),
	link : b,
	protocol : Protocol,
	inbox : List(Ws.Message),
}
Session.Errors(e) : [InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e]
```

`mask!` is the one role-specific step: the client's reads 4 bytes with
`random_bytes!` and gives `Masked(key)`; the server's gives `Unmasked` and
touches nothing. So the server needs no `Random` feature.

`Client.Conn(b, e)` and `Server.Conn(b, e)` stay two opaque types, each
holding a `Session` and forwarding its methods to it. Considered and rejected:

- **One public `Conn` with the role inside** (`Client.Conn` and `Server.Conn`
  aliases of one type). Less forwarding code, but a server connection would be
  accepted where a client connection is expected, and qualified calls such as
  `Client.Conn.send!(conn, m)` would stop resolving (an alias has no methods):
  a breaking change with nothing gained by the user.
- **A second copy of the client's driver in `Server`**: about 200 lines of the
  subtlest code of the package (leftover bytes, a deadline inside a frame, the
  1009 check before a frame's payload arrives), kept in step twice.

`Client`'s public API does not change: `Client.Conn` keeps its methods, and
`Client.Errors(e)` is the same row (`Session.Errors([Refused(Str), ..e])` is
the same union with the tags in another order).

#### API

```roc
Server :: [].{
	## The tags the server adds to the platform's row `e`.
	Errors(e) : [NotUpgrade(Str), InvalidStatus(U16), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e]
	Error(e) : Ws.Error(Server.Errors(e))

	## What the server needs from a platform: a byte stream, no randomness.
	Transport(b, e) : Ws.Bytes(b, Server.Errors(e), {})

	## The composition of Client.Ops: core, ping, pong, frames and poll.
	Ops(b, e) : Ws.Core(Server.Conn(b, e), Server.Errors(e), Ws.Ping(..., Ws.Pong(..., Ws.Frames(..., Ws.Poll(..., {})))))

	## How the application refuses an upgrade: a status from 400 to 599,
	## extra headers (default none) and a text body (default none).
	Refusal : { status : U16, headers ?: List(Handshake.Header), body ?: Str }

	## An upgrade request read from the link and validated, not answered yet.
	Request(b, e) :: { ... }.{
		upgrade : Server.Request(b, e) -> Handshake.Upgrade
		accept! : Server.Request(b, e), Ws.AcceptOptions => Try(Ws.Opened(Server.Conn(b, e)), Server.Error(e))
		refuse! : Server.Request(b, e), Server.Refusal => Try(b, Server.Error(e))
	}

	## A server connection, with the methods of Client.Conn.
	Conn(b, e) :: { session : Session(b, [NotUpgrade(Str), InvalidStatus(U16), ..e]) }.{
		link, map_link, send!, receive!, poll!, close!, ping!, pong!, send_frame!, receive_frame!
	}

	read_request! : Server.Transport(b, e), b => Try(Server.Request(b, e), Server.Error(e))
	accept! : Server.Transport(b, e), b, Ws.AcceptOptions => Try(Ws.Opened(Server.Conn(b, e)), Server.Error(e))
	ops : {} -> Server.Ops(b, e)
	default_max_message : U64
	max_request_head : U64
}
```

How it mirrors the client:

| Client | Server |
| --- | --- |
| `Client.open!(transport, link, request : Ws.ConnectRequest)` | `Server.accept!(transport, link, options : Ws.AcceptOptions)` |
| `Client.Transport(b, e)`: `Ws.Transport`, bytes and randomness | `Server.Transport(b, e)`: `Ws.Bytes`, bytes only |
| `Client.Errors(e)`: `Refused(Str)` and the frame tags | `Server.Errors(e)`: `NotUpgrade(Str)`, `InvalidStatus(U16)` and the frame tags |
| `Client.Conn(b, e)`, `Client.Ops(b, e)`, `Client.ops({})` | `Server.Conn(b, e)`, `Server.Ops(b, e)`, `Server.ops({})` |
| an adapter's `Ws.Connect`: `connect!: \|request\| ... Client.open!(transport, link, request)` | an adapter's `Ws.Accept`: `accept!: \|q, options\| ... Server.accept!(transport, link, options)`, wrapped as `{ response: {}, opened }` |

`p = {}` in `Ws.Accept`, because this server writes its 101 itself (0.10).

Two levels, as the client has `Client.open!` and then the methods:

- **`Server.accept!(transport, link, options)`** does everything: read the
  request, choose the first subprotocol of the client's offer that is in
  `options.protocols` (`Handshake.choose_protocol`; none when nothing
  matches, never a refusal, since RFC 6455 section 4.2.2 lets a server
  answer with no subprotocol), write the 101, and return
  `Ws.Opened(Server.Conn(b, e))`.
- **`Server.read_request!(transport, link)`** stops after the read, for an
  application that looks at the request first: `request.upgrade()` has the
  resource, `Host`, the offered subprotocols and every header. It then calls
  `request.accept!(options)` (a choice of its own passes
  `protocols: [chosen]`), or `request.refuse!({ status: 403, body: "..." })`,
  which writes the refusal and gives the link back for the adapter to close.
  A status outside 400-599 is `Err(InvalidStatus(status))` and writes
  nothing; the request value stays usable.

Extensions: the 101 never has `Sec-WebSocket-Extensions`, which is how a
server declines every extension offered (RFC 6455 section 9.1).
`opened.extensions` is `Reported([])`: the client's "no extensions" limit.

#### Errors

`Server.Errors(e)` follows the `Errors`/`Error` convention (0.4). The adapter's
link row is `Server.Errors(e)`, so link errors flow into every result with no
mapping, as in the client. `NotUpgrade(Str)` is the tag `Ws.Accept` documents
for a request that is not a valid upgrade; the driver gives it after writing
the matching answer:

| Request | Answer written | Result |
| --- | --- | --- |
| not a valid upgrade (`Handshake.parse_upgrade`) | 400, 405, or 426 with `Sec-WebSocket-Version: 13` | `Err(NotUpgrade(why))` |
| no end of the head within `max_request_head` bytes | 431 | `Err(NotUpgrade(why))` |
| a head that is not UTF-8 | 400 | `Err(NotUpgrade(why))` |
| the stream ends before the end of the head | nothing | `Err(NotUpgrade(why))` |
| the platform's read deadline passes before the end of the head | nothing | `Err(NotUpgrade(why))` |
| the application refuses with `refuse!` | its status, headers and body | `Ok(link)` |

`InvalidStatus(U16)` is `refuse!` given a status that is not a refusal.
`Closed`, `Closing`, `InvalidClose`, `ControlTooLong` and `BadFrame` mean what
they mean for the client.

#### Reading the request: bounds, splits, leftover bytes

- **Bounded.** `max_request_head` is 16 KiB, the client's limit on a response
  head. Each read asks for at most the bytes still allowed
  (`max_request_head` minus what was read), so the driver never holds more
  than 16 KiB of a request, whatever the client sends; at the limit with no
  `\r\n\r\n` it answers 431.
- **Split across reads.** The bytes of each read are appended and the end of
  the head is searched from 3 bytes before the new ones, so a `\r\n\r\n` split
  between two reads is found and each byte is scanned about once.
- **Bytes after the head.** A client may send its first frames right behind
  the request, in the same TCP segment. The bytes after `\r\n\r\n` stay in the
  `Request`; `accept!` writes the 101 first and then feeds them to the
  `Protocol`, so a first message is not lost and any frame it provokes (a
  Pong, or the Close 1002 for an unmasked frame) is written after the 101.
  `refuse!` drops them.
- **Deadlines.** A read that hits the platform's deadline fails the handshake
  (above), as the client's gives `Refused`, so an idle client holds the server
  for at most one deadline.

#### Frames in the Server role

The `Protocol` in the `Server` role requires masked frames: an unmasked client
frame fails the connection with 1002 (the Close is written, `receive!` gives
`Closed({ code: 1002, by: Us, .. })`). Frames the server sends are unmasked:
messages, Pongs, Close. `max_message` (from `Ws.AcceptOptions`, default
`Server.default_max_message`, 16 MiB) fails a larger message with 1009, as in
the client.

#### Close from the server side

- **The server starts it**: `conn.close!(code, reason)` writes Close and
  returns; `receive!` delivers the messages on their way and ends with
  `Closed({ by: Us, clean: True, .. })` when the client's Close arrives;
  meanwhile senders give `Closing`. `Ws.close_and_wait!(Server.ops({}), ...)`
  does both. RFC 6455 section 7.1.1 says the server closes the TCP connection
  first once the handshake is over: that is the adapter's part (close or drop
  the stream in `conn.link()`). Waiting for a client that never answers is
  bounded only through `poll!`: a server that will not wait forever polls and
  gives up after its own limit.
- **The client starts it**: the `Protocol` echoes the code, `receive!` gives
  `Closed({ by: Peer, clean: True, .. })`, and the adapter closes the stream.
- **Messages read with the client's Close** (changed on `server-revisions`):
  when the peer's last messages and its Close arrive in one read, `Session`
  holds the echo until those messages are delivered. Sending stays allowed
  while it is held, so replies to them go out before the echo; the next
  `receive!`, `poll!`, `receive_frame!` or `close!` that finds the inbox empty
  writes it. RFC 6455 section 5.5.1 lets an endpoint delay its echo. Before,
  the echo went out at once and every reply gave `Closed`: an echo server
  over `Ws.drive!` lost those replies, and `drive!` ended with that error, so
  `on_close!` never ran and the application state was lost
  (roc-basic-cli-websocket's `serve!` showed it with a client that sends and
  closes in one write). It also matches a push platform, where the runtime
  delivers the messages before the close event and replies to them succeed.
  A Close that comes with no message before it is still echoed at once, and
  a Close of a failed connection (by `Us`) is never held.
- **`Ws.drive!` and a handler's `Closed`**: a handler that fails with
  `Closed` sent on a connection that had already ended (a protocol failure
  read with its message, for example). `drive!` then reads on from the
  connection it gave the handler, which delivers the messages left and the
  closure, and calls `on_close!`; other handler errors end the run.
- **`Server.Request.map_link`**: an adapter reads the request with a short
  handshake deadline and restores the connection's read timeout before it
  hands out the request, so a request needs no adapter wrapper.

#### Push handlers

Nothing new: `Ws.drive!` is generic over `{ receive! : ..., .. }`, so
`Ws.drive!(Server.ops({}), opened.conn, state, handlers)` runs a
`Ws.Handlers(s, Server.Conn(b, e), Server.Errors(e))` record over a server
connection, the same call as over a client connection, and a Cloudflare
Worker's accepted socket (a `Core` record) runs the same handlers through it.
A handler closes with `(ops.close!)(c, code, reason)` and returns the closing
connection; `drive!` then reads until the client answers and calls
`on_close!`.

#### What a basic-cli adapter adds

A `WsServer` module in roc-basic-cli-websocket, as thin as `WsClient`:

- `WsServer.Errors : [Tcp(IOErr), Interrupted]` (no `Connect`, no `Entropy`),
  `WsServer.Link : { read : Tcp.Connection, write : Tcp.Connection }` (the
  client's link: one socket with a read timeout and a write timeout),
  `WsServer.Conn : Server.Conn(WsServer.Link, WsServer.Errors)`,
  `WsServer.Error : Server.Error(WsServer.Errors)`.
- `WsServer.transport : Server.Transport(WsServer.Link, WsServer.Errors)`: the
  `write_bytes!` and `read_up_to!` of `WsClient.transport`, with no
  `random_bytes!`.
- `WsServer.accept! : Tcp.Listener, Ws.AcceptOptions, WsServer.Options => Try(Ws.Opened(WsServer.Conn), WsServer.Error)`
  (`listener.accept!` with `accept_timeout` and `io_timeout`, then
  `Server.accept!`), `WsServer.read_request!` for the two-step form, and
  `WsServer.accept`, the `Ws.Accept(Tcp.Listener, {}, WsServer.Conn, ...)`
  record.
- `WsServer.ops` and `WsServer.receive_within!`, the client's (`map_link`
  with a shorter read timeout, then `poll!`).
- Serving one connection at a time is `accept!` then `Ws.drive!` in a loop.
  Several at once is a round-robin over `poll!` with a short read timeout
  (3.4): basic-cli has no readiness primitive, so latency grows with the
  number of clients. That loop belongs in the adapter or the app.

#### Pure-core additions

`Handshake.refusal : U16, List(Handshake.Header), Str -> Str` writes any
refusal; `Handshake.rejection(status, why)` is `refusal(status, [], why)`.
The reason phrases cover the statuses a server refuses with (400, 401, 403,
404, 405, 408, 426, 429, 431, 500, 503). `Handshake.head_end(bytes, from)`
finds the end of a head from an offset, for a reader that appends bytes (the
client's and the server's head reads). `Protocol.expects` gives the masking
a received frame must have, so `Session` checks a too-large frame header for
either role (the client's code assumed unmasked frames).

#### Tests

`tests/server.roc` drives the server over a scripted link, and a client and
a server wired together in memory: the client's link runs `Server.accept!`
on what the client wrote when it first reads, so `Client.open!` reads the
server's real 101; after that a test moves the written bytes from one end to
the other. A link can be set to fail its writes with the bytes it was given,
which is how a test sees what a call wrote before it ended in an error (a
refusal before `NotUpgrade`, a Close echo before `Closed`): an error drops the
connection value (0.2), and with a link that is a pure value the bytes go
with it.

---

## 1. Verdict

**One message-level surface for all three platforms: yes. One fully-featured
surface where every platform implements everything: no, and it should not be
attempted.**

The three platforms do not differ on the *message* level. Every one of them can
give "send a text or binary message, receive the next message, close with a
code and a reason, learn how it closed". They differ on three other axes:

1. **Who owns the protocol.** On basic-cli and basic-webserver Roc owns the wire
   (Tcp bytes), so Roc can do anything RFC 6455 allows: raw frames, ping/pong,
   fragmentation, custom close handshake. On Cloudflare the runtime owns the wire;
   Roc sees whole messages only (`cfw/platform/WebSocket.roc:19`,
   `cfw/js/helpers.js:151-156`) and the runtime answers pings itself.
2. **Who drives the loop.** basic-cli is pull (blocking reads). Cloudflare Workers is *also*
   pull for a Worker-accepted socket and for a client socket (`receive!`,
   `cfw/platform/WebSocket.roc:103`), and push only for a Durable Object with
   hibernation (`web_socket_message!` handler, `cfw/platform/Object.roc:412`).
   basic-webserver can only pull, and only as a client.
3. **Server role at all.** basic-cli: possible (Tcp.listen!/accept!,
   `cli/Tcp.roc:95,120`), single-threaded. Cloudflare Workers: yes, two forms. basic-webserver:
   no, by design and by code (section 6.2).

So Cloudflare is not the lowest common denominator in a harmful sense: its
message model *is* the common denominator, and it is also the richest platform
for server features (hibernation, tags, attachments, auto-response, broadcast).
What it lacks (raw frames, protocol-level ping, explicit pong) are things most
applications never need. The right shape is a message-level core that every
platform implements, plus **optional features that an adapter exposes only if it supports them**, as
plain record fields typed by extensible aliases from the shared package (3.3).

Pull vs push: **pull for connections, push for servers**, with a pure adapter
from pull to push so one handler record runs everywhere (section 3.4). Push
cannot be turned into pull on a hibernating Durable Object (there is no
`receive!` and no Roc state across events, `cfw/platform/Object.roc:146-147`),
so push is the only portable *server* shape; pull is the natural *client* shape
on all three.

---

## 2. Layering

```
 app code
   |  Ws.Conn (pull)           Ws.Handlers (push)
   |        \                    /
   |   Ws.serve! / Ws.drive!  (pull -> push, pure Roc)
   |
 roc-websocket, platform-free
   +-- message API: Message, Closure, Core, feature aliases (Ping, ...), Handlers
   +-- pure core (sans-IO): Frame, Handshake, Sha1, Base64, Assembler, CloseCode, Protocol
   +-- Ws.over_bytes : ByteLink -> Conn   (drives Protocol over a byte link)
   |
 adapters (thin, app-side or platform-side; a package cannot import a platform)
   +-- basic-cli:        Tcp.Connection + Random  -> ByteLink -> Conn
   +-- basic-webserver:  Tcp.Connection + entropy -> ByteLink -> Conn   (client only)
   +-- cfw Worker:       pf.WebSocket            -> Conn                (no pure core)
   +-- cfw DO:           Object.Socket events    -> Sender + Handlers    (no pure core)
```

Why adapters live outside the package: a Roc package cannot import a platform's
modules, so the package can only describe the shape of what it needs. Two ways
were checked:

- **A record of functions** (`ByteLink`, `Conn`), as `Surreal.Transport` does
  today (`surreal/Surreal.roc:2460-2465`, built in `surreal/watch.roc:235-241`).
  Works on every platform. Probes `cli.roc`, `bws/app.roc`, `cloudflare-workers/app.roc`.
- **A `where` clause on effectful methods**: `of : c -> Link where
  [c.write_bytes! : c, List(U8) => Try({}, ew), c.read_exactly! : c, U64 =>
  Try(List(U8), er)]` accepts basic-cli's `Tcp.Connection` directly (probe
  `where_clause.roc`, type-checks and runs). It does not generalise: basic-webserver
  names the write `write!` (`bws/platform/Tcp.roc:60`), and the platform's message type
  is a nominal `WebSocket.Message := [Text(Str), Bytes(List(U8))]`
  (`cfw/platform/WebSocket.roc:19`) that the package cannot construct.
  Also, a `where` clause cannot ask for `to_inspect` on a structural error union
  (probe finding: "does not have a method named to_inspect" for
  `[Interrupted, TcpErr(IOErr)]`). So the record is the primary mechanism; the
  `where` form is an optional convenience for basic-cli only.

Recommendation: ship the adapters as source files in this repo under
`adapters/<platform>/` that an app copies or imports as a local module, and
(cloudflare-workers only, since it is the user's platform) optionally have cloudflare-workers itself
depend on roc-websocket and expose `WebSocket.conn` / `Object.Socket.peer`
(the platform's header already takes package dependencies,
`cfw/platform/main.roc:7-10`). Open question Q1.

---

## 3. API surface

All names are proposals. One public type module per concept, per the package
conventions. Error unions are open where the platform adds its own detail.

### 3.1 Messages and closure

```roc
Message : [Text(Str), Binary(List(U8))]

## How a connection ended. `code` is 1005 when the peer sent no code and 1006
## when the connection dropped with no close frame (RFC 6455 7.1.5, 7.4.1).
Closure : { code : U16, reason : Str, clean : Bool, by : [Peer, Us, Transport] }

Err : [Closed(Closure), Failed(Str), TooLarge(U64), Protocol(Str)]
```

`by` is new relative to the platform's `Closed : { code, reason, clean }`
(`cfw/platform/WebSocket.roc:30`); cloudflare-workers can fill it from whether `close!` was
called first (inference: the JS `close` event does not say who started it).

### 3.2 The adapter value and its shared core

An adapter is a record. The package defines each feature once, as an
**extensible record alias** (`..r` is the rest of the row), and an adapter's type
is the composition of the aliases it supports. There is no `Features` record, no
`Supported`/`Unsupported` tag: a feature the platform lacks has no field.

```roc
## What every connection can do, on every platform. `e` is the platform's extra
## error tags (3.6), `r` the rest of the record.
Core(e, r) : {
	send! : Message => Try({}, [Closed(Closure), ..e]),
	receive! : {} => Try(Message, [Closed(Closure), ..e]),
	close! : U16, Str => Try({}, [..e]),
	..r
}

## Server side of a push model (hibernating Durable Object): no receive!.
Sender(e, r) : { send! : Message => Try({}, [Closed(Closure), ..e]), close! : U16, Str => Try({}, [..e]), ..r }

## The messages until the close (not a field; a function over the closed
## record it needs, 3.5): Err(NoMore) at a clean close, a `Failed` item for an
## error, as `Surreal.messages` does (surreal/Surreal.roc:3767-3782).
messages : { receive! : {} => Try(Message, [Closed(Closure), ..e]) } -> Stream(Try(Message, [Closed(Closure), ..e]))
```

Probes use a bare `Closed` and a two-field `Core`; a payload tag and `close!`
are the same mechanism (inference, not separately probed). Records, not opaque
types, so an adapter is just a record literal and dispatch is on the value, the
same strategy as the SurrealDB transports.

### 3.3 Features as shared extensible aliases

```roc
## Protocol-level ping. basic-cli, basic-webserver.
Ping(e, r) : { ping! : List(U8) => Try({}, [Closed(Closure), ..e]), ..r }

## Frame-level access (send fragments and control frames, read raw frames).
Frames(e, r) : { send_frame! : Frame => Try({}, [Closed(Closure), ..e]), receive_frame! : {} => Try(Frame, [Closed(Closure), ..e]), ..r }

## A receive that gives up after a deadline without losing a message.
## basic-cli: Connection.with_timeout (cli/Tcp.roc:157-170). cloudflare-workers: Io.timeout.
ReceiveWithin(e, r) : { receive_within! : U64 => Try(Message, [TimedOut, Closed(Closure), ..e]), ..r }

## A text request the platform answers with no wake (Cloudflare DO only,
## cfw/platform/Object.roc:386). App-level ping, not protocol ping.
AutoResponse(e, r) : { set_auto_response! : { request : Str, response : Str } => Try({}, [TooLarge, ..e]), clear_auto_response! : {} => {}, auto_response_ms! : {} => Try(U64, [NotFound]), ..r }

## Survives the server leaving memory (Cloudflare DO only): tags and a bytes
## attachment (cfw/platform/Object.roc:169, 549).
Hibernation(e, r) : { tags! : {} => List(Str), attachment! : {} => Try(List(U8), [NotFound]), set_attachment! : List(U8) => Try({}, [TooLarge, ..e]), ..r }
```

Adapters, written as the composition of what they support:

```roc
cli_adapter : Core([Io(Str)], Ping([Io(Str)], ReceiveWithin([Io(Str)], {})))
worker_adapter : Core([Failed(Str)], {})
do_peer : Sender([Failed(Str)], AutoResponse([], Hibernation([], {})))
```

Platform-specific extras are ordinary extra fields next to the shared ones,
reusing a shared alias when another platform has the same feature (the
Durable Object's `AutoResponse`, `Hibernation`) and a plain inline field when
nobody else does (for example a Workers-only `broadcast!`). Promote an extra to a
shared alias the day a second platform gains it; consumers that picked the
field by name keep working.

**Discovery is by type.** A function that needs `ping!` takes
`{ ping! : ..., .. }`; handing it an adapter without the field is a compile
error, not a runtime `Unsupported`. Verified (`probes/fields/features_ok.roc`,
`features_reject.roc`): `keepalive! : { ping! : List(U8) => Try({}, [Closed]), .. } => Try({}, [Closed])`
accepts a `Core(Ping({}))` and rejects a `Core({})` with

```
The first argument being passed to this function has the wrong type.
This argument has the type:       Core({})
But keepalive! needs the first argument to be:
    { ping!: List(U8) => Try({}, [Closed]), .. }
```

Rules: the core API never depends on a feature. A field exists only when the
platform does it exactly, never emulated (`ping` is not emulated on Cloudflare
by a text message; that is `AutoResponse`, a different feature).

**Not fields: runtime-only facts.** Things that are not known until the
connection is up or the request arrives stay values and `Try` results: the
negotiated subprotocol and extensions (a return value of the connect/accept
call, `{ conn, protocol }`), a server refusing the upgrade (`Err(Refused(..))`
from `client!`), and whether cloudflare-workers is in a Durable Object or a plain Worker
(which adapter constructor the app calls; the DO adapter is the one that yields
a `Sender`, so the distinction is already in the type of the value, not a flag).
Backpressure is no longer modelled: none of the three platforms exposes a
buffered amount today, and a `Buffered` alias can be added the day one does.

### 3.4 Servers: push handlers

```roc
## `p` is a closed record of what the handlers use, e.g. { send! : ..., close! : ... }.
Handlers(p, e) : {
	on_open! : p => Try({}, e),
	on_message! : p, Message => Try({}, e),
	on_close! : p, Closure => Try({}, e),
}

## Run handlers over a pull connection until it closes (pure Roc).
drive! : Core(x, {}), Handlers(Core(x, {}), e) => Try({}, [Handler(e), Closed(Closure), ..x])
```

- cfw DO:   the app's `web_socket_message!`/`web_socket_close!` call
  `on_message!`/`on_close!` with the per-event `Sender` record (an adapter, 7.3). Roc keeps no
  state across events (`cfw/MODULES.md` 12.1 "Hibernation"), so per-socket state
  goes through the `Hibernation` fields or object storage, not a closure.
- Workers Worker accept, basic-cli server: `drive!` over a `Core` record.
- basic-cli multi-client server: a round-robin `serve!` that polls each
  connection with a short `with_timeout` read (a timed-out read "consumes
  nothing", `cli/Tcp.roc` Connection docs, line 142). Latency grows with
  the number of clients; there is no select/poll primitive (inference from the
  hosted list in `cli/main.roc:114-130`, which has no poll).

State in handlers is open question Q3.

### 3.5 Opening connections

```roc
## Client request; the adapter turns it into a platform call.
Connect : { url : Str, protocols : List(Str), headers : List((Str, Str)), max_message : U64 }

## Over raw bytes (basic-cli, basic-webserver): do the handshake, return a Conn.
ByteLink : {
	write! : List(U8) => Try({}, Str),
	read_up_to! : U64 => Try(List(U8), [Closed, TimedOut, Failed(Str)]),
	random! : U64 => Try(List(U8), Str),
}
## `Opened` carries the runtime-only facts (negotiated protocol) as values.
Opened(c) : { conn : c, protocol : Str }
client! : ByteLink, Connect => Try(Opened(Core([Io(Str)], Ping([Io(Str)], {}))), [Refused(Str), ..])

## Server side over raw bytes (basic-cli): read the HTTP upgrade request,
## validate, answer 101 with Sec-WebSocket-Accept, return a Conn.
accept! : ByteLink, { protocols : List(Str), max_message : U64 } => Try(Opened(Core([Io(Str)], Ping([Io(Str)], {}))), [NotUpgrade(Str), ..])
```

Consumers (a package that wraps the API, such as the SurrealDB client) take a
**closed record of exactly the fields they need**, and the app picks them from
its adapter:

```roc
Session(e) : { send! : Message => Try({}, [Closed, ..e]), receive! : {} => Try(Message, [Closed, ..e]) }
session = Surreal.connect!({ send!: a.send!, receive!: a.receive! })
```

The consumer then states its needs in its own type, never mentions the adapter
or platform, and the app decides which of its fields to hand over (an app can
also swap in a wrapped `send!` that logs). A closed record rejects extra fields,
so the pick is explicit (verified: handing the full `cli_adapter` to a closed
record of two fields is a type mismatch, `probes/fields/closed_pick_reject.roc`). The
alternative is to carry a row parameter, `Session(c)` with `c` the open
record: the app passes the adapter as is, but the row leaks into every
signature that mentions the session and an unused extra field is still part of
its type. Closed record is the default; the open row is for a layer that
forwards the whole adapter further.

`read_up_to!`, not `read_exactly!`: basic-webserver drops the bytes of a
`read_exactly!` that times out midway (`bws/src/tcp.rs:400-420`: the partial
`buffer` is local), so the core must keep its own buffer. Cloudflare needs none
of this: `WebSocket.connect_with!` and `accept!` already exist
(`cfw/platform/WebSocket.roc:42,64`).

### 3.6 Errors and open tag unions

Question: do open tag unions remove the need for every platform to use the same
error type for a shared feature? **Mostly yes, at a cost.** Verified with
`roc check` in `probes/fields/`:

- A shared alias takes an error-row parameter, `Core(e, r)` with
  `Try({}, [Closed, ..e])`. Platforms instantiate it with their own tags:
  `Core([Io(Str)], Ping([Io(Str)], {}))` for basic-cli and
  `Core([TooLarge(U64)], {})` for Cloudflare (`errors_ok.roc`: 0 errors).
- A consumer written over `e` serves both adapters in one program, with
  different extra tags, and each caller's result keeps its own tags, so a caller
  can match `Io(s)` or `TooLarge(n)` exhaustively (`errors_ok.roc`, `main!`).
- A consumer that spells the error row takes only adapters with exactly that row:
  `send_only! : { send! : Message => Try({}, [Closed, Io(Str)]) } => ...`
  accepts the basic-cli field and rejects the Cloudflare one (`errors_closed_consumer*.roc`):

```
This argument has the type:       { send!: Message => Try({}, [Closed, TooLarge(U64)]) }
But send_only! needs the first argument to be:
                                  { send!: Message => Try({}, [Closed, Io(Str)]) }
```

Costs and limits:

1. **An extra type parameter on every alias**, and one row per alias: all fields
   of `Core` share the same `e`. Each alias has its own `e`, so `Ping` may carry
   a different row than `Core` in one adapter (verified in
   `errors_closed_consumer.roc`), but a consumer that needs `Core` and `Ping`
   with one `e` then rejects such an adapter. The convention that avoids it:
   an adapter instantiates all its aliases with one row.
2. **A consumer cannot narrow `Closed` out of `..e`.** A catch-all arm
   `Err(other) => return Err(other)` still has type `[Closed, ..e]`, so
   `Try({}, [..e])` is rejected (`errors_narrow_fails.roc`):

```
This return does not match the function's return type.
Err(other) => return Err(other)
It has the type:           [Err([Closed, ..e]), Ok({})]
But the function's return type is:   Try({}, [..e])
```

   A consumer that handles `Closed` therefore still returns `[Closed, ..e]`,
   and its caller must match `Closed` again (the compiler says so: "Missing
   patterns: Err Closed"). The workable convention: `Closed` is the one tag every
   adapter shares and the final caller, not a library, consumes it.
3. A closed consumer record spells the row (`[Closed, Io(Str)]`), so it is tied
   to a platform; a library meant for all platforms must be generic in `e`
   (ordinary Roc generics, no extra syntax at the use site, but `e` appears in
   every signature that mentions an alias).
4. The `where [...]` route is no better for this: it cannot constrain error
   tags either (section 2 finding on `to_inspect`).

So the shared **tag** (`Closed`) is still shared by convention, but the
**remainder** is per platform and flows through generic code unchanged. Without
the row parameter every platform would have to share one closed `Err`; with it,
platform-specific failures need no mapping layer.

---

## 4. Pure core (platform-free, no effects)

Only basic-cli and basic-webserver use it. Cloudflare delivers whole messages
and never needs it.

| Module | Contents | Starting point |
| --- | --- | --- |
| `Frame` | encode/decode for both roles: FIN, RSV, opcode, 7/16/64-bit length, mask, control-frame limit 125, client must mask / server must not | `surreal/Ws.roc:59` (`frame`, client only), `:87` (`decode`, rejects fragments `:96-100` and masked frames `:106`) |
| `Mask` | XOR with a 4-byte key; key source | `surreal/Ws.roc` inside `frame` |
| `Base64` | encode (key), decode (validate a client key is 16 bytes) | `surreal/Ws.roc:157` (encode only) |
| `Sha1` | SHA-1 for `Sec-WebSocket-Accept`. Builtins have only SHA-256 and BLAKE3 (`Builtin.roc:3032-3043`) | new; the client today skips the check (`surreal/Ws.roc:36-38`) |
| `Handshake` | client request, server response, header parsing, subprotocol choice, `Sec-WebSocket-Accept` compute and check | `surreal/Ws.roc:18` (`upgrade`), `:38` (`accepted`) |
| `Assembler` | continuation frames into one message, control frames interleaved, `max_message` limit, UTF-8 check of a whole text message (`Str.from_utf8`) | new |
| `CloseCode` | parse the close payload (code + reason), validate codes (1000-1003, 1007-1011, 3000-4999 sendable; 1005/1006/1015 never sent), reason at most 123 bytes | new; today only the first 2 bytes are echoed (`surreal/Ws.roc:136`) |
| `Protocol` | sans-IO state machine: `step : State, Input -> (State, List(Output))`, inputs `Bytes`, `Send`, `Close`, `Ping`, outputs `Write`, `Deliver`, `Closed`; the close handshake (send Close, wait for the peer's Close, then end) | `surreal/Surreal.roc:3735-3765` (`next_message!`, `read_frame!`), effectful today |

The only effects an adapter supplies are bytes in, bytes out, and random bytes
(16 for the key, 4 per client frame). Timers are not needed by the core: a
keepalive ping is the app's choice through the `Ping` field.

Randomness: RFC 6455 10.3 requires unpredictable masks. Option (inference, Q5):
take one 32-byte seed from the platform and derive masks with
`Crypto.BLAKE3.hash(seed ++ counter)` from the builtins, so the adapter needs
entropy once per connection, not per frame.

Not in scope: extensions (permessage-deflate). The handshake must refuse to
offer them.

---

## 5. Per-platform mapping

| | basic-cli 0.26.0 | basic-webserver 0.19.0 | Workers Worker / client | Workers Durable Object |
| --- | --- | --- | --- | --- |
| Client | Yes, today (Surreal) | Yes, over Tcp, with limits | Yes, `WebSocket.connect_with!` | Yes, but a client socket does not hibernate (MODULES.md 12.2) |
| Server | Possible: `Tcp.listen!`/`accept!` + pure handshake + Sha1 | **No** | Yes, `WebSocket.accept!` + `response.after` | Yes, `self.accept!`, hibernation |
| `wss://` (TLS) | No: Tcp has no TLS (no TLS in `cli/Tcp.roc`; TLS only in `Http`, `cli/Http.roc:27`) | No: rustls only for `Http.send!` (`bws/Cargo.toml:42-45`) | Yes (MODULES.md 12.3 edge table) | Yes |
| Model | Pull | Pull, inside one handler or one SSE transition | Pull (`receive!`), `Io.race!` | Push (handler record) |
| Needs pure core | Yes | Yes | No | No |
| Randomness | `Random.seed_u64!` (`cli/Random.roc:8`) | **None** (no random effect in the hosted list, `bws/platform/Host.roc:115-189`) | `WebCrypto.random!` (not needed) | not needed |
| Adapter type (4 rows: fields present) | `Core(e, Ping(e, ReceiveWithin(e, {})))`, `Frames` optional | `Core(e, Ping(e, {}))` (no `receive_within!`: fixed 30 s host timeout, `bws/src/tcp.rs:22`, so only with a Roc-side buffer, 6.2); `Frames` optional | `Core(e, ReceiveWithin(e, {}))` (`Io.timeout`); no `ping!`, no frames (runtime) | `Sender(e, AutoResponse(.., Hibernation(.., {})))`; no `receive!`, no `ping!` |
| Extras beside shared fields | none | none | Workers-only extras as inline fields | `broadcast!`, `sockets!` inline |
| Outbound buffering | Blocking writes | Blocking writes (30 s) | Unbounded (`send` returns at once; inbound queue unbounded, `cfw/js/helpers.js:151-156`) | Unbounded |
| Size limit | none in platform | 8 MiB per read (`bws/src/tcp.rs:23`) | Cloudflare limit (inference: 32 MiB per message per current Cloudflare docs; not in cloudflare-workers code) | same |
| Concurrent use | one thread; shared buffer | `StreamBusy` on concurrent use (`bws/src/tcp.rs:221-222`, `bws/platform/Tcp.roc:12-15`) | one task (ref, MC13) | one event (`cfw/platform/Object.roc:146-147`) |

---

## 6. Platform analysis and gaps

### 6.1 basic-cli 0.26.0

Has: `Tcp.connect!` with connect and I/O timeouts (`cli/Tcp.roc:365`),
`read_up_to!`/`read_exactly!`/`read_line!`/`write_bytes!` (`:177-257`),
`listen!`/`accept!` (`:95,120`), `with_timeout` for polling (`:157-170`), a
timed-out read consumes nothing (Connection docs, `:142`),
`Random.seed_u64!` (`cli/Random.roc:8`). The Surreal client proves the client
path end to end.

Gaps:
- No TLS on Tcp, so no `wss://`. Smallest change (upstream, not the user's
  platform): `Tcp.connect_tls!` with rustls, the stack `Http` already links.
  Until then a TLS terminator (stunnel) is the only way, and that is outside
  this package.
- No readiness/poll over many connections; a server is round-robin polling.
- Server needs SHA-1 in pure Roc (package work, not a platform change).

### 6.2 basic-webserver 0.19.0

Re-verified:
- Entry points are only `init!`, `respond!`, `shutdown!` (`bws/platform/main.roc:12-14`);
  context is immutable (`bws/design.md` table at 91, section 144-154).
- Tcp is client only: `connect!` (`bws/platform/Tcp.roc:105-116`), no listen.
  Each operation has a 30 s host deadline (`bws/src/tcp.rs:22`, set at `:151,161,
  320-321`), reads materialize at most 8 MiB (`:23`), at most 64 open streams
  (`:24`), and a second concurrent user gets `StreamBusy` (`:221-222`).
- A timed-out `read_exactly!` loses the bytes it already read (`bws/src/tcp.rs:400-420`).
  `read_up_to!` uses `fill_buf` and consumes nothing on timeout (`:155-165`).
- No random effect at all (hosted list `bws/platform/Host.roc:115-189`). The
  probe reads `/dev/urandom` through `File.open_reader!`/`read_line!`, which
  type-checks but is not acceptable as the design (Unix-only, line-based).
- SSE is a host-parked source: `Sse.unfold! : state, (state => Try(Step(state), err)) => Source`
  (`bws/platform/Sse.roc:152`), `Step` = `Emit | Wait | End` with a wake time
  (`:143-147`), the host calls the transition (`advance_for_host!`, `:182`).
  Sleeping occupies a bounded Roc slot (`bws/platform/Sleep.roc:5-6`).

**Server: no.** The response path rejects every 1xx status ("ordinary responses
cannot be informational", `bws/src/response.rs:255-258`) and rejects an
`Upgrade` or `Connection` header (`bws/src/response.rs:20-27`, checked at
`:276-280`). `Outcome` has only `Respond | Stream(Sse.Source) | ServeFile |
StopAfter` (`bws/platform/Server.roc:1194-1207`). The design says
"Application-defined WebSockets ... are outside the platform's scope"
(`bws/design.md:877-883`) and lists them as a non-goal (`:942`), and says a
host-owned messaging facility "requires new design justification" (`:886-890`).

**Client: yes, with limits.** Over `Tcp` with the pure core, plain `ws://`
only, and only inside one request: either to completion inside `respond!`, or
as an SSE relay where each transition reads one message (probe `bws/app.roc`).
A quiet upstream longer than 30 s makes a read fail with a timeout; with
`read_up_to!` and a Roc-side buffer that is "no message yet" and the transition
returns `Wait`. Each blocked transition holds a Roc worker slot for up to 30 s
(inference from the slot model in `Sleep.roc:5-6`).

Smallest platform changes, all upstream and each needing maintainer approval
under `bws/design.md:886-890`:
1. `Random` (getrandom) for the client masks. Small, uncontroversial.
2. A host-parked WebSocket outcome modelled on SSE:
   `Server.websocket : Ws.Source -> Outcome` with
   `Ws.unfold! : state, (state, [Opened, Message(Message), Closed(Closure), Woke] => Try({ send : List(Message), state : state, wake : Wake, close : [Keep, Close(U16, Str)] }, err)) => Source`.
   The host (hyper upgrade + tungstenite) owns framing, ping/pong, backpressure
   and cancellation; Roc is called once per event, like an SSE transition. This
   is the push model of section 3.4 and maps onto `Handlers` directly. It is the
   "constrained host-owned messaging facility" the design asks to justify.
3. TLS on Tcp for `wss://` clients.

### 6.3 cloudflare-workers (the user's platform)

Already built (more than the earlier read suggested):
- `WebSocket` module: `accept!` (WebSocketPair + accept + 101,
  `cfw/platform/WebSocket.roc:42`), `connect`/`connect_with` with headers and
  `protocols` (`:64`), `send!` (`:90`), `receive`/`receive!` with no deadline and
  race-safe (`:103`, `cfw/js/helpers.js:382-408`), `close!` (`:119`),
  `Message := [Text(Str), Bytes(List(U8))]` with `json` (`:19`), `Closed`
  (`:30`), `ws://`→`http://` rewrite (`:132`).
- JS glue: `wsPair`, `wsAccept`, `wsReceive` (`cfw/js/helpers.js:365,373,382`),
  a per-socket queue and waiter list (`:136-160`), `binaryType = 'arraybuffer'`
  (`:143`).
- Durable Object hibernation: `self.accept!`/`accept_with!` tags
  (`cfw/platform/Object.roc:330,338`, `:730-745`), `sockets!`/`sockets_with!`
  (`:342,346`), `broadcast!`/`broadcast_with!` (`:351-373`),
  `set_auto_response!`/`clear_auto_response!`/`auto_response_ms!`
  (`:386,393,182`), `Socket.tags!` (`:169`), typed CBOR `Attachment` (`:549`),
  handlers `web_socket_message!`/`close!`/`error!` (`:412-414`).
- Edge-verified: a Worker socket stays open with no traffic for 40 s, a
  hibernating object leaves memory after 90 s and its attachment reads back,
  `wss://` client works (`cfw/MODULES.md` 12.4 last paragraph).

The cloudflare-workers adapter to the proposed `Conn` type-checks today with no platform
change (probe `cloudflare-workers/app.roc`). So the core needs nothing new from cloudflare-workers. What
would make the adapter complete:

| Gap | Where | Smallest change |
| --- | --- | --- |
| Negotiated subprotocol of a client is not exposed | `wsAccept` returns only `ws` (`cfw/js/helpers.js:373-377`) | `wsAccept` returns `[ws, ws.protocol ?? '']`; `connect_with` gives `{ socket, protocol }`, or a `WebSocket.protocol!` that reads `ws.protocol` with one `Get` op |
| Server cannot see which subprotocols the client offered, except by reading the request header | `accept!` takes no options (`WebSocket.roc:42`) | `accept_with!(req, { protocol ?: Str })` that sets `Sec-WebSocket-Protocol` on the 101 (`Response.with_header` exists, `cfw/platform/Response.roc:68`; inference that workerd forwards it) |
| `send!` collapses every throw into `Closed` | `cfw/platform/Remote.roc:46-50` | keep `Closed` for "after close()", map other throws (size) to `TooLarge`/`Failed` |
| `close!` drops errors | `cfw/platform/Remote.roc:53-57`; reason documented at MODULES.md 12.4 | fine for the core (`close!` returning `Ok` always), but report an invalid code as `Err(BadCode)` instead of dropping it |
| Inbound queue is unbounded | `st.queue.push(v)` (`cfw/js/helpers.js:155`) | a `max_queued` option; above it, `ws.close(1008)` (inference: Workers has no read-side flow control, so closing is the only defence) |
| No outbound buffer view | — | none possible (inference: workerd's WebSocket has no `bufferedAmount`); `backpressure: Unbounded` |
| `Closed` has no "who closed" | `closed_of` (`WebSocket.roc:143-158`) | record `closeCalled` in `acceptSocket` state, add `by` |
| DO socket is good for one event only | `cfw/platform/Object.roc:146-147` | none needed; `Handlers` gets a fresh `Sender` per event |
| Hibernatable event timeout, `serializeAttachment` of bytes | — | optional: `Object.Socket.attachment_bytes!` so the package's untyped `hibernation` feature needs no CBOR type at the adapter |

Not possible on Cloudflare, by the runtime: raw frames, protocol ping/pong,
fragment control, a WebSocket over `Tcp` (connect to an HTTP port is refused,
MODULES.md 12.3 edge table). These are absent fields, not gaps.

---

## 7. Adapters (sketches; the probes are the real code)

### 7.1 basic-cli
`ByteLink` from `Tcp.Connection` + `Random.seed_u64!`, as `surreal/watch.roc:235-261`
does. Probe `cli.roc` builds a full `Conn` from the existing `Ws` core,
answers pings, and exposes `features.ping` (the superseded record form; the
field form is `probes/fields/`).

### 7.2 basic-webserver
Same `ByteLink`, with `write!` instead of `write_bytes!`, `read_up_to!` with a
Roc-side buffer, and entropy from a future `Random` (6.2). Probe `bws/app.roc`
relays a WebSocket upstream to an SSE response.

### 7.3 cloudflare-workers
A `Core` record from `WebSocket`: map `Text`/`Bytes` to `Text`/`Binary`,
`Closed(c)` to `Closed(c)` (probe `cloudflare-workers/app.roc`, an echo Worker with
`response.after`). A `Sender` record from `Object.Socket` per event, with the
`Hibernation` and `AutoResponse` fields present.

---

## 8. Open questions for the user

Settled by the field-based decision and removed: feature list and granularity
(old Q4: a feature is an alias, a platform has it or has no field; DO-only
features are aliases that only the DO adapter instantiates), and the
SurrealDB-transport-as-`Conn` question (old Q7: the ORM's WebSocket/HTTP choice
is two values of one Surreal Transport type, not modelled here).

- **Q1. Where do adapters live?** (a) copy-in source files under
  `adapters/` of this repo, (b) separate tiny packages per platform that take
  the platform functions as a record, (c) for cloudflare-workers, inside the platform
  (cloudflare-workers depends on roc-websocket). (c) couples cloudflare-workers releases to this package.
- **Q2. basic-webserver server support.** It needs an upstream platform
  change that its design currently rules out (`bws/design.md:877-890`). Pursue
  the SSE-style host-parked proposal (6.2 item 2) with the maintainers, or
  declare basic-webserver client-only?
- **Q3. State in push handlers.** On a hibernating DO, state cannot live in Roc
  between events. Should `Handlers` take an explicit `state` with a codec
  (portable, the package serialises it into the attachment on Cloudflare), or
  stay stateless and leave state to each platform?
- **Q4. Randomness.** Per-frame platform randomness (simple) or one seed per
  connection expanded with builtin BLAKE3 (fewer effects, needs a review of the
  construction)? basic-webserver has no entropy source either way.
- **Q5. Scope of the first version.** Suggested order: message core + cloudflare-workers
  adapter (no pure core needed) and basic-cli client (pure core extracted from
  `surreal/Ws.roc`); then `Sha1` + server handshake for basic-cli; then the
  basic-webserver client; basic-webserver server only if Q2 goes ahead.
- **Q6. Error row convention.** Is `Closed` as the one mandatory shared tag, with
  every alias taking a single `e` and each adapter using one row for all its
  aliases (3.6), acceptable? The alternative is a closed shared `Err` with a
  `Platform(Str)` escape, which loses typed platform errors.
- **Q7. Type-level cost.** Every signature that mentions an alias carries `e`
  and `r`. Is that acceptable to the packages that wrap the API, or should the
  package ship a few pre-composed aliases (for example `Basic(e)` = `Core(e, {})`)?

---

## 9. Probes

Checked with a local debug build of the compiler (`reify` branch, befc71f7),
`roc check`, 0 errors each (one warning: the `echo!` loop's unreachable `Ok({})`).

| File | Proves |
| --- | --- |
| `probes/fields/features_ok.roc`, `features_reject.roc` | field-based features: `Core(Ping({}))` accepted and `Core({})` rejected by a function that needs `ping!` |
| `probes/fields/errors_ok.roc` | shared aliases with an error row `e`; platforms add tags; one generic consumer over two adapters (1 warning: unreachable `Ok({})` after the loop) |
| `probes/fields/errors_narrow_fails.roc` | expected failure: a consumer cannot narrow `Closed` out of `..e` |
| `probes/fields/errors_closed_consumer.roc`, `_reject.roc` | a closed consumer spelling the row accepts one adapter and rejects another; per-alias rows may differ |
| `probes/fields/closed_pick_reject.roc`, `closed_pick_ok.roc` | a closed consumer record rejects an adapter with extra fields; picking fields is accepted |
| `probes/pkg/Socket.roc` (superseded) | the earlier `Conn` / `Features` records, `[Supported(..), Unsupported]` fields, `Stream.custom` over a record of closures |
| `probes/pkg/Ws.roc` | copy of `surreal/Ws.roc`, the pure core it reuses |
| `probes/where_clause.roc` + `probes/pkg/Conn.roc` | a package `where` clause on effectful methods accepts basic-cli `Tcp.Connection`; also ran (exit 1, connection refused, as expected) |
| `probes/cli.roc` | basic-cli `Conn` over the pure core with `features.ping` Supported |
| `probes/cloudflare-workers/app.roc` | the platform's `WebSocket` adapted to `Conn`, echo Worker; the platform path is a sibling checkout of the cloudflare-workers platform |
| `probes/bws/app.roc` | basic-webserver WebSocket client relayed as SSE. Platform path expects a 0.19.0 checkout at `../../basic-webserver-0.19.0`; it was checked against a clone elsewhere |

No probe opened a real WebSocket: no local echo server was available (Python
`websockets` is not installed). The client wire path is proven by the existing
SurrealDB example, not by these probes.
