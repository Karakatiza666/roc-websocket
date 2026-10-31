# roc-websocket

WebSocket (RFC 6455) for Roc, independent of any platform:

- **Shared types** (`Ws`): messages, how a connection closed, and each feature a
  platform may offer, as an extensible record alias. An adapter for a platform is
  a record of the fields that platform supports, so code that needs a feature
  does not compile with an adapter that lacks it.
- **A pure core with no I/O**: frame encoding and decoding with masking
  (`Frame`), close codes (`CloseCode`), the opening handshake for both roles,
  `Sec-WebSocket-Accept` included (`Handshake`, `Sha1`, `Base64`), and a protocol
  state machine that assembles fragments, answers pings and runs the closing
  handshake (`Protocol`).
- **A client over bytes** (`Client`) for platforms where Roc owns the TCP
  connection. The platform adapter supplies a byte stream and randomness.

Adapters are separate packages, such as
[roc-basic-webserver-websocket](../roc-basic-webserver-websocket). A platform
that hands out whole messages (Cloudflare Workers) implements `Ws.Core` directly
and uses none of the pure core.

## Use

```roc
app [...] {
	pf: platform "...",
	ws: "../roc-websocket/src/main.roc", # a release URL once published
}

import ws.Ws

## Works with any adapter: a connection with at least the core fields.
echo_once! : Ws.Core(e, r) => Try({}, [Closed(Ws.Closure), ..e])
echo_once! = |conn| {
	message = (conn.receive!)({})?
	(conn.send!)(message)
}
```

### Features

Every effectful field returns `Try(_, [Closed(Ws.Closure), ..e])`: `Closed` is
the one tag every adapter shares; `e` holds the platform's own tags and the
tags a feature adds (`TimedOut`, `InvalidClose(Str)`, `ControlTooLong(U64)`,
`BadFrame(Str)`, `Refused(Str)`, ...). One adapter uses one `e` for all of its
fields.

| Alias | Fields |
| --- | --- |
| `Core(e, r)` | `send!`, `receive!`, `close!` (runs the closing handshake, returns the `Closure`) |
| `Sender(e, r)` | `send!`, `close!`, for push-model servers |
| `Ping(e, r)`, `Pong(e, r)` | `ping!`, `pong!` (payload at most 125 bytes) |
| `Frames(e, r)` | `send_frame!`, `receive_frame!` |
| `ReceiveWithin(e, r)` | `receive_within!(ms)`, `Ok(TimedOut)` loses nothing |
| `Buffered(e, r)` | `buffered_amount!` |
| `AutoResponse(e, r)` | a fixed text reply the runtime sends by itself |
| `Persist(e, r)` | per-connection state that survives the server leaving memory |
| `Topics(e, r)` | `subscribe!`, `unsubscribe!`, `publish!` |
| `Dial(c, e, r)`, `Accept(q, c, e, r)` | open a client connection, accept an upgrade |
| `Handlers(p, e)` | push-model callbacks |
| `Bytes(e, r)`, `Random(e, r)` | what the pure client needs from a platform |

Pre-composed: `Basic(e)`, `Raw(e)` (core + ping + pong + frames), `Timed(e)`,
`Push(e)`, `Transport(e)`, and `Client.Conn(e)`, `Client.Link(e)`.

### The pure core

```roc
expect Handshake.accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

(protocol, events) = Protocol.new(Server, 1024).receive(bytes_from_the_wire)
# events: [Message(Text("...")), Write(pong_frame), Closed(closure), ...]
```

`examples/sans_io.roc` runs a server handshake and a few frames through the
state machine with no platform.

## Status

Version 0.1: client side complete, server-side handshake and protocol done but
no server driver yet. No extensions (`permessage-deflate` is never offered and a
server that picks one is refused). `DESIGN.md` has the design, the platform
analysis and what is left.

## Checks

```sh
ROC=/path/to/roc scripts/all_tests.sh
```

121 `expect`s: RFC 6455 vectors (the handshake key, the section 5.7 frames,
fragmentation, close codes), RFC 4648 Base64 vectors, and SHA-1 vectors.
`roc bundle main.roc <modules>` in `src/` bundles the package.
