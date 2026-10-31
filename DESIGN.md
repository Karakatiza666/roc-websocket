# roc-websocket: design and platform analysis

Status: design only. Nothing here is implemented except the probes in `probes/`,
which type-check the proposed surface against all three platforms (section 9).

Citations are `file:line`. Paths are abbreviated:

| Short | Full path / source |
| --- | --- |
| `surreal/` | `/home/george/dev/Karakatiza666/roc/examples/reifying/surreal/` |
| `cli/` | basic-cli 0.26.0 bundle, `~/.cache/roc/packages/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t/` |
| `bws/` | basic-webserver tag 0.19.0 (commit `1654ae3f7f`), cloned read-only |
| `talon/` | `/home/george/dev/Karakatiza666/talon/cloudflare-workers/` |
| `Builtin.roc` | `/home/george/dev/Karakatiza666/roc/src/build/roc/Builtin.roc` |

"Inference" marks a claim that was not read in code or verified by a probe.

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
   Roc sees whole messages only (`talon/platform/WebSocket.roc:19`,
   `talon/js/helpers.js:151-156`) and the runtime answers pings itself.
2. **Who drives the loop.** basic-cli is pull (blocking reads). Talon is *also*
   pull for a Worker-accepted socket and for a client socket (`receive!`,
   `talon/platform/WebSocket.roc:103`), and push only for a Durable Object with
   hibernation (`web_socket_message!` handler, `talon/platform/Object.roc:412`).
   basic-webserver can only pull, and only as a client.
3. **Server role at all.** basic-cli: possible (Tcp.listen!/accept!,
   `cli/Tcp.roc:95,120`), single-threaded. Talon: yes, two forms. basic-webserver:
   no, by design and by code (section 6.2).

So Cloudflare is not the lowest common denominator in a harmful sense: its
message model *is* the common denominator, and it is also the richest platform
for server features (hibernation, tags, attachments, auto-response, broadcast).
What it lacks (raw frames, protocol-level ping, explicit pong) are things most
applications never need. The right shape is a message-level core that every
platform implements, plus a **capability record on the connection value** whose
fields are `[Supported(ops), Unsupported]`.

Pull vs push: **pull for connections, push for servers**, with a pure adapter
from pull to push so one handler record runs everywhere (section 3.4). Push
cannot be turned into pull on a hibernating Durable Object (there is no
`receive!` and no Roc state across events, `talon/platform/Object.roc:146-147`),
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
   +-- message API: Message, Closure, Conn, Peer, Features, Handlers
   +-- pure core (sans-IO): Frame, Handshake, Sha1, Base64, Assembler, CloseCode, Protocol
   +-- Ws.over_bytes : ByteLink -> Conn   (drives Protocol over a byte link)
   |
 adapters (thin, app-side or platform-side; a package cannot import a platform)
   +-- basic-cli:        Tcp.Connection + Random  -> ByteLink -> Conn
   +-- basic-webserver:  Tcp.Connection + entropy -> ByteLink -> Conn   (client only)
   +-- talon Worker:     pf.WebSocket            -> Conn                (no pure core)
   +-- talon DO:         Object.Socket events    -> Peer + Handlers     (no pure core)
```

Why adapters live outside the package: a Roc package cannot import a platform's
modules, so the package can only describe the shape of what it needs. Two ways
were checked:

- **A record of functions** (`ByteLink`, `Conn`), as `Surreal.Transport` does
  today (`surreal/Surreal.roc:2460-2465`, built in `surreal/watch.roc:235-241`).
  Works on every platform. Probes `cli.roc`, `bws/app.roc`, `talon/app.roc`.
- **A `where` clause on effectful methods**: `of : c -> Link where
  [c.write_bytes! : c, List(U8) => Try({}, ew), c.read_exactly! : c, U64 =>
  Try(List(U8), er)]` accepts basic-cli's `Tcp.Connection` directly (probe
  `where_clause.roc`, type-checks and runs). It does not generalise: basic-webserver
  names the write `write!` (`bws/platform/Tcp.roc:60`), and talon's message type
  is a nominal `WebSocket.Message := [Text(Str), Bytes(List(U8))]`
  (`talon/platform/WebSocket.roc:19`) that the package cannot construct.
  Also, a `where` clause cannot ask for `to_inspect` on a structural error union
  (probe finding: "does not have a method named to_inspect" for
  `[Interrupted, TcpErr(IOErr)]`). So the record is the primary mechanism; the
  `where` form is an optional convenience for basic-cli only.

Recommendation: ship the adapters as source files in this repo under
`adapters/<platform>/` that an app copies or imports as a local module, and
(talon only, since it is the user's platform) optionally have talon itself
depend on roc-websocket and expose `WebSocket.conn` / `Object.Socket.peer`
(talon's platform header already takes package dependencies,
`talon/platform/main.roc:7-10`). Open question Q1.

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

`by` is new relative to talon's `Closed : { code, reason, clean }`
(`talon/platform/WebSocket.roc:30`); talon can fill it from whether `close!` was
called first (inference: the JS `close` event does not say who started it).

### 3.2 The connection value

```roc
## What every connection can do, on every platform. A server-side peer in a
## push model (a hibernating Durable Object) is a Peer and has no receive!.
Peer : {
	send! : Message => Try({}, Err),
	close! : U16, Str => Try({}, Err),
	protocol : Str,             # negotiated subprotocol, "" when none
	features : Features,
}

## A Peer that can also be read from: pull model.
Conn : {
	send! : Message => Try({}, Err),
	receive! : {} => Try(Message, Err),
	close! : U16, Str => Try({}, Err),
	protocol : Str,
	features : Features,
}

## The messages until the close: `Err(NoMore)` at a clean close, a `Failed`
## item for an error, as `Surreal.messages` does (surreal/Surreal.roc:3767-3782).
messages : Conn -> Stream(Try(Message, Err))
```

Records, not opaque types, so an adapter is just a record literal and the
dispatch is on the value, the same strategy as the SurrealDB transports.

### 3.3 Capability record

```roc
Features : {
	## Protocol-level ping. basic-cli, basic-webserver: Supported. Cloudflare:
	## Unsupported (the runtime answers pings; Roc never sees a frame).
	ping : [Supported({ ping! : List(U8) => Try({}, Err), last_pong_ms! : {} => Try(U64, [None]) }), Unsupported],

	## Frame-level access: send fragments and control frames, read raw frames.
	frames : [Supported({ send_frame! : Frame => Try({}, Err), receive_frame! : {} => Try(Frame, Err) }), Unsupported],

	## A receive that gives up after a deadline without losing a message.
	## basic-cli: Connection.with_timeout (cli/Tcp.roc:157-170). talon: Io.timeout
	## (talon/MODULES.md 12.2 "Timeout"). basic-webserver: only with a Roc-side buffer (6.2).
	receive_within : [Supported({ receive_within! : U64 => Try(Message, [TimedOut, ..Err]) }), Unsupported],

	## A text request the platform answers with no wake (Cloudflare DO only,
	## talon/platform/Object.roc:386). App-level ping, not protocol ping.
	auto_response : [Supported({ set! : { request : Str, response : Str } => Try({}, [TooLarge]), clear! : {} => {}, last_ms! : {} => Try(U64, [NotFound]) }), Unsupported],

	## Survives the server leaving memory (Cloudflare DO only): tags and a
	## bytes attachment (talon/platform/Object.roc:169, 549).
	hibernation : [Supported({ tags! : {} => List(Str), attachment! : {} => Try(List(U8), [NotFound]), set_attachment! : List(U8) => Try({}, [TooLarge]) }), Unsupported],

	## Outbound flow control. None of the three platforms exposes a buffered
	## amount today; basic-cli writes block (implicit backpressure).
	backpressure : [Blocking, Unbounded, Supported({ buffered! : {} => U64 })],
}

none : Features   # everything Unsupported, backpressure Unbounded
```

Rules: an app matches on a field and degrades; the core API never depends on a
feature. A feature is `Supported` only when the platform does it exactly, never
emulated (for example `ping` is not emulated on Cloudflare by a text message;
that is `auto_response`, a different feature).

### 3.4 Servers: push handlers

```roc
Handlers(e) : {
	on_open! : Peer => Try({}, e),
	on_message! : Peer, Message => Try({}, e),
	on_close! : Peer, Closure => Try({}, e),
}

## Run handlers over a pull connection until it closes (pure Roc).
drive! : Conn, Handlers(e) => Try({}, [Handler(e), ..Err])
```

- talon DO: the app's `web_socket_message!`/`web_socket_close!` call
  `on_message!`/`on_close!` with `peer_of(socket)` (an adapter, 7.3). Roc keeps no
  state across events (`talon/MODULES.md` 12.1 "Hibernation"), so per-socket state
  goes through `features.hibernation` or object storage, not a closure.
- talon Worker accept, basic-cli server: `drive!` over a `Conn`.
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
client! : ByteLink, Connect => Try(Conn, [Refused(Str), ..Err])

## Server side over raw bytes (basic-cli): read the HTTP upgrade request,
## validate, answer 101 with Sec-WebSocket-Accept, return a Conn.
accept! : ByteLink, { protocols : List(Str), max_message : U64 } => Try(Conn, [NotUpgrade(Str), ..Err])
```

`read_up_to!`, not `read_exactly!`: basic-webserver drops the bytes of a
`read_exactly!` that times out midway (`bws/src/tcp.rs:400-420`: the partial
`buffer` is local), so the core must keep its own buffer. Cloudflare needs none
of this: `WebSocket.connect_with!` and `accept!` already exist
(`talon/platform/WebSocket.roc:42,64`).

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
keepalive ping is the app's choice through `features.ping`.

Randomness: RFC 6455 10.3 requires unpredictable masks. Option (inference, Q5):
take one 32-byte seed from the platform and derive masks with
`Crypto.BLAKE3.hash(seed ++ counter)` from the builtins, so the adapter needs
entropy once per connection, not per frame.

Not in scope: extensions (permessage-deflate). The handshake must refuse to
offer them.

---

## 5. Per-platform mapping

| | basic-cli 0.26.0 | basic-webserver 0.19.0 | talon Worker / client | talon Durable Object |
| --- | --- | --- | --- | --- |
| Client | Yes, today (Surreal) | Yes, over Tcp, with limits | Yes, `WebSocket.connect_with!` | Yes, but a client socket does not hibernate (MODULES.md 12.2) |
| Server | Possible: `Tcp.listen!`/`accept!` + pure handshake + Sha1 | **No** | Yes, `WebSocket.accept!` + `response.after` | Yes, `self.accept!`, hibernation |
| `wss://` (TLS) | No: Tcp has no TLS (no TLS in `cli/Tcp.roc`; TLS only in `Http`, `cli/Http.roc:27`) | No: rustls only for `Http.send!` (`bws/Cargo.toml:42-45`) | Yes (MODULES.md 12.3 edge table) | Yes |
| Model | Pull | Pull, inside one handler or one SSE transition | Pull (`receive!`), `Io.race!` | Push (handler record) |
| Needs pure core | Yes | Yes | No | No |
| Randomness | `Random.seed_u64!` (`cli/Random.roc:8`) | **None** (no random effect in the hosted list, `bws/platform/Host.roc:115-189`) | `WebCrypto.random!` (not needed) | not needed |
| ping | Supported | Supported | Unsupported (runtime) | Unsupported; `auto_response` Supported |
| frames | Supported | Supported | Unsupported | Unsupported |
| receive_within | Supported (`with_timeout`) | Partial: fixed 30 s host timeout (`bws/src/tcp.rs:22`) | Supported (`Io.timeout`) | n/a (push) |
| hibernation | Unsupported | Unsupported | Unsupported | Supported |
| backpressure | Blocking writes | Blocking writes (30 s) | Unbounded (`send` returns at once; inbound queue unbounded, `talon/js/helpers.js:151-156`) | Unbounded |
| Size limit | none in platform | 8 MiB per read (`bws/src/tcp.rs:23`) | Cloudflare limit (inference: 32 MiB per message per current Cloudflare docs; not in talon code) | same |
| Concurrent use | one thread; shared buffer | `StreamBusy` on concurrent use (`bws/src/tcp.rs:221-222`, `bws/platform/Tcp.roc:12-15`) | one task (ref, MC13) | one event (`talon/platform/Object.roc:146-147`) |

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

### 6.3 talon/cloudflare-workers (the user's platform)

Already built (more than the earlier read suggested):
- `WebSocket` module: `accept!` (WebSocketPair + accept + 101,
  `talon/platform/WebSocket.roc:42`), `connect`/`connect_with` with headers and
  `protocols` (`:64`), `send!` (`:90`), `receive`/`receive!` with no deadline and
  race-safe (`:103`, `talon/js/helpers.js:382-408`), `close!` (`:119`),
  `Message := [Text(Str), Bytes(List(U8))]` with `json` (`:19`), `Closed`
  (`:30`), `ws://`→`http://` rewrite (`:132`).
- JS glue: `wsPair`, `wsAccept`, `wsReceive` (`talon/js/helpers.js:365,373,382`),
  a per-socket queue and waiter list (`:136-160`), `binaryType = 'arraybuffer'`
  (`:143`).
- Durable Object hibernation: `self.accept!`/`accept_with!` tags
  (`talon/platform/Object.roc:330,338`, `:730-745`), `sockets!`/`sockets_with!`
  (`:342,346`), `broadcast!`/`broadcast_with!` (`:351-373`),
  `set_auto_response!`/`clear_auto_response!`/`auto_response_ms!`
  (`:386,393,182`), `Socket.tags!` (`:169`), typed CBOR `Attachment` (`:549`),
  handlers `web_socket_message!`/`close!`/`error!` (`:412-414`).
- Edge-verified: a Worker socket stays open with no traffic for 40 s, a
  hibernating object leaves memory after 90 s and its attachment reads back,
  `wss://` client works (`talon/MODULES.md` 12.4 last paragraph).

The talon adapter to the proposed `Conn` type-checks today with no platform
change (probe `talon/app.roc`). So the core needs nothing new from talon. What
would make the adapter complete:

| Gap | Where | Smallest change |
| --- | --- | --- |
| Negotiated subprotocol of a client is not exposed | `wsAccept` returns only `ws` (`talon/js/helpers.js:373-377`) | `wsAccept` returns `[ws, ws.protocol ?? '']`; `connect_with` gives `{ socket, protocol }`, or a `WebSocket.protocol!` that reads `ws.protocol` with one `Get` op |
| Server cannot see which subprotocols the client offered, except by reading the request header | `accept!` takes no options (`WebSocket.roc:42`) | `accept_with!(req, { protocol ?: Str })` that sets `Sec-WebSocket-Protocol` on the 101 (`Response.with_header` exists, `talon/platform/Response.roc:68`; inference that workerd forwards it) |
| `send!` collapses every throw into `Closed` | `talon/platform/Remote.roc:46-50` | keep `Closed` for "after close()", map other throws (size) to `TooLarge`/`Failed` |
| `close!` drops errors | `talon/platform/Remote.roc:53-57`; reason documented at MODULES.md 12.4 | fine for the core (`close!` returning `Ok` always), but report an invalid code as `Err(BadCode)` instead of dropping it |
| Inbound queue is unbounded | `st.queue.push(v)` (`talon/js/helpers.js:155`) | a `max_queued` option; above it, `ws.close(1008)` (inference: Workers has no read-side flow control, so closing is the only defence) |
| No outbound buffer view | — | none possible (inference: workerd's WebSocket has no `bufferedAmount`); `backpressure: Unbounded` |
| `Closed` has no "who closed" | `closed_of` (`WebSocket.roc:143-158`) | record `closeCalled` in `acceptSocket` state, add `by` |
| DO socket is good for one event only | `talon/platform/Object.roc:146-147` | none needed; `Handlers` gets a fresh `Peer` per event |
| Hibernatable event timeout, `serializeAttachment` of bytes | — | optional: `Object.Socket.attachment_bytes!` so the package's untyped `hibernation` feature needs no CBOR type at the adapter |

Not possible on Cloudflare, by the runtime: raw frames, protocol ping/pong,
fragment control, a WebSocket over `Tcp` (connect to an HTTP port is refused,
MODULES.md 12.3 edge table). These are `Unsupported`, not gaps.

---

## 7. Adapters (sketches; the probes are the real code)

### 7.1 basic-cli
`ByteLink` from `Tcp.Connection` + `Random.seed_u64!`, as `surreal/watch.roc:235-261`
does. Probe `cli.roc` builds a full `Conn` from the existing `Ws` core,
answers pings, and exposes `features.ping`.

### 7.2 basic-webserver
Same `ByteLink`, with `write!` instead of `write_bytes!`, `read_up_to!` with a
Roc-side buffer, and entropy from a future `Random` (6.2). Probe `bws/app.roc`
relays a WebSocket upstream to an SSE response.

### 7.3 talon
`Conn` from `WebSocket`: map `Text`/`Bytes` to `Text`/`Binary`,
`Closed(c)` to `Closed(c)` (probe `talon/app.roc`, an echo Worker with
`response.after`). `Peer` from `Object.Socket` per event, with
`features.hibernation` and `features.auto_response` Supported.

---

## 8. Open questions for the user

- **Q1. Where do adapters live?** (a) copy-in source files under
  `adapters/` of this repo, (b) separate tiny packages per platform that take
  the platform functions as a record, (c) for talon, inside the platform
  (talon depends on roc-websocket). (c) couples talon releases to this package.
- **Q2. basic-webserver server support.** It needs an upstream platform
  change that its design currently rules out (`bws/design.md:877-890`). Pursue
  the SSE-style host-parked proposal (6.2 item 2) with the maintainers, or
  declare basic-webserver client-only?
- **Q3. State in push handlers.** On a hibernating DO, state cannot live in Roc
  between events. Should `Handlers` take an explicit `state` with a codec
  (portable, the package serialises it into the attachment on Cloudflare), or
  stay stateless and leave state to each platform?
- **Q4. Feature granularity.** Is the capability list in 3.3 right? In
  particular: should `frames` exist at all (it lets an app break the protocol),
  and should the DO-only features (`hibernation`, `auto_response`, broadcast)
  be in the shared record or stay talon-only API?
- **Q5. Randomness.** Per-frame platform randomness (simple) or one seed per
  connection expanded with builtin BLAKE3 (fewer effects, needs a review of the
  construction)? basic-webserver has no entropy source either way.
- **Q6. Scope of the first version.** Suggested order: message core + talon
  adapter (no pure core needed) and basic-cli client (pure core extracted from
  `surreal/Ws.roc`); then `Sha1` + server handshake for basic-cli; then the
  basic-webserver client; basic-webserver server only if Q2 goes ahead.
- **Q7. Relationship to the SurrealDB ORM.** Should `Surreal.Transport` become
  a `Ws.Conn` (so the ORM runs on talon with no change), with the HTTP transport
  as the other strategy value?

---

## 9. Probes

Checked with `/home/george/dev/Karakatiza666/roc/zig-out/bin/roc` (debug-befc71f7),
`roc check`, 0 errors each (one warning: the `echo!` loop's unreachable `Ok({})`).

| File | Proves |
| --- | --- |
| `probes/pkg/Socket.roc` | the `Conn` / `Features` records, `[Supported(..), Unsupported]` fields, `Stream.custom` over a record of closures |
| `probes/pkg/Ws.roc` | copy of `surreal/Ws.roc`, the pure core it reuses |
| `probes/where_clause.roc` + `probes/pkg/Conn.roc` | a package `where` clause on effectful methods accepts basic-cli `Tcp.Connection`; also ran (exit 1, connection refused, as expected) |
| `probes/cli.roc` | basic-cli `Conn` over the pure core with `features.ping` Supported |
| `probes/talon/app.roc` | talon `WebSocket` adapted to `Conn`, echo Worker; platform path is relative to this repo's sibling `talon/` |
| `probes/bws/app.roc` | basic-webserver WebSocket client relayed as SSE. Platform path expects a 0.19.0 checkout at `../../basic-webserver-0.19.0`; it was checked against a clone elsewhere |

No probe opened a real WebSocket: no local echo server was available (Python
`websockets` is not installed). The client wire path is proven by the existing
SurrealDB example, not by these probes.
