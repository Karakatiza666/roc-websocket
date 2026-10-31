import Frame

## The shared WebSocket types: messages, how a connection ends, and each
## feature a platform may have, as an extensible record alias.
##
## An adapter is a record of the fields its platform supports, typed as the
## composition of these aliases: `Ws.Core(e, Ws.Ping(e, {}))`. A feature the
## platform lacks has no field, so code that needs it does not compile with
## that adapter. In every alias `e` is the platform's extra error tags, and
## `r` the rest of the record. `Closed` is the one error tag every adapter
## shares.
Ws :: [].{

	## One whole message.
	Message : [Text(Str), Binary(List(U8))]

	## How a connection ended (RFC 6455 section 7). `code` is 1005 when the
	## Close frame had no code and 1006 when the connection dropped with no
	## Close frame. `clean` is whether both Close frames were exchanged. `by`
	## is who started the close: the peer, this endpoint (by `close!` or by
	## failing the connection after a protocol error), or the transport.
	Closure : { code : U16, reason : Str, clean : Bool, by : [Peer, Us, Transport] }

	## A request to open a client connection. `protocols` are the
	## subprotocols offered in order (default none), `headers` extra request
	## headers (default none), `max_message` the largest message accepted, in
	## bytes; a bigger one fails the connection with 1009.
	Request : { url : Str, protocols ?: List(Str), headers ?: List((Str, Str)), max_message ?: U64 }

	## An open connection `conn`, with what the handshake settled: the chosen
	## subprotocol (`""` for none) and extensions.
	Opened(c) : { conn : c, protocol : Str, extensions : List(Str) }

	## Options of a server accepting an upgrade: the subprotocols it supports,
	## in order of preference.
	AcceptOptions : { protocols ?: List(Str), max_message ?: U64 }

	# ---------------------------------------------------------------- features
	#
	# The error rule: every effectful field returns `[Closed(Ws.Closure), ..e]`,
	# the same row in every field. A failure a feature adds is a tag of `e`,
	# named below, rather than a fixed tag of one field, because a row
	# variable cannot be widened by code generic in it: a field with its own
	# fixed tags could not share the adapter's one row.
	#
	# Tags of `e` with a shared meaning:
	# - `InvalidClose(Str)`: `close!` got a code that may not be sent or a
	#   reason over 123 bytes.
	# - `ControlTooLong(U64)`: a Ping, Pong or Close payload over 125 bytes.
	# - `BadFrame(Str)`: `send_frame!` got a frame that breaks RFC 6455.
	# - `TooLarge(U64)`: a value over a platform limit.
	# - `TimedOut`: a platform deadline passed; the connection stays usable.
	# - `Refused(Str)`, `NotUpgrade(Str)`: opening a connection failed.

	## What every connection can do on every platform.
	##
	## - `send!` sends one message.
	## - `receive!` waits for the next message. `Err(Closed(_))` once the
	##   connection has ended; the connection is then done.
	## - `close!` runs the closing handshake to its end and returns how the
	##   connection closed; messages the peer sends meanwhile are dropped.
	Core(e, r) : { send! : Ws.Message => Try({}, [Closed(Ws.Closure), ..e]), receive! : {} => Try(Ws.Message, [Closed(Ws.Closure), ..e]), close! : U16, Str => Try(Ws.Closure, [Closed(Ws.Closure), ..e]), ..r }

	## The sending half alone, for a push-model server whose messages arrive
	## in callbacks (`Handlers`) rather than by `receive!`. `close!` starts
	## the closing handshake; its end arrives as a callback.
	Sender(e, r) : { send! : Ws.Message => Try({}, [Closed(Ws.Closure), ..e]), close! : U16, Str => Try({}, [Closed(Ws.Closure), ..e]), ..r }

	## Send a protocol-level Ping (RFC 6455 section 5.5.2), payload at most
	## 125 bytes. The peer's Pong is not reported by `receive!`; read it with
	## `Frames`.
	Ping(e, r) : { ping! : List(U8) => Try({}, [Closed(Ws.Closure), ..e]), ..r }

	## Send an unsolicited Pong, a one-way heartbeat (RFC 6455 section 5.5.3).
	Pong(e, r) : { pong! : List(U8) => Try({}, [Closed(Ws.Closure), ..e]), ..r }

	## Frame-level access: send any frame (fragments, control frames) and read
	## the next frame as it arrives, with no assembly and no automatic reply.
	## A received frame that breaks the protocol fails the connection
	## (`Closed`).
	Frames(e, r) : { send_frame! : Frame => Try({}, [Closed(Ws.Closure), ..e]), receive_frame! : {} => Try(Frame, [Closed(Ws.Closure), ..e]), ..r }

	## A receive that waits at most `ms` milliseconds. `TimedOut` loses
	## nothing and leaves the connection usable.
	ReceiveWithin(e, r) : { receive_within! : U64 => Try([Message(Ws.Message), TimedOut], [Closed(Ws.Closure), ..e]), ..r }

	## The bytes queued for sending and not yet handed to the network.
	Buffered(e, r) : { buffered_amount! : {} => Try(U64, [Closed(Ws.Closure), ..e]), ..r }

	## A fixed text reply that the runtime sends to a fixed text request by
	## itself, without running application code (an application-level
	## heartbeat that does not wake the server).
	AutoResponse(e, r) : { set_auto_response! : { request : Str, response : Str } => Try({}, [Closed(Ws.Closure), ..e]), clear_auto_response! : {} => Try({}, [Closed(Ws.Closure), ..e]), ..r }

	## Per-connection state kept by the runtime, which survives the server
	## leaving memory while the connection stays open (hibernation).
	Persist(e, r) : { saved! : {} => Try([Saved(List(U8)), Nothing], [Closed(Ws.Closure), ..e]), save! : List(U8) => Try({}, [Closed(Ws.Closure), ..e]), ..r }

	## Named groups of connections, with one send to every member
	## (publish/subscribe).
	Topics(e, r) : { subscribe! : Str => Try({}, [Closed(Ws.Closure), ..e]), unsubscribe! : Str => Try({}, [Closed(Ws.Closure), ..e]), publish! : Str, Ws.Message => Try({}, [Closed(Ws.Closure), ..e]), ..r }

	## Open a client connection `c`. A server that refuses the upgrade is
	## `Refused(Str)` in `e`.
	Dial(c, e, r) : { connect! : Ws.Request => Try(Ws.Opened(c), [Closed(Ws.Closure), ..e]), ..r }

	## Accept an upgrade of an incoming request `q` into a server connection
	## `c`. A request that is not a valid upgrade is `NotUpgrade(Str)` in `e`.
	Accept(q, c, e, r) : { accept! : q, Ws.AcceptOptions => Try(Ws.Opened(c), [Closed(Ws.Closure), ..e]), ..r }

	## Callbacks of a push-model server, where the runtime delivers events. `p`
	## is what each callback gets to act on the connection, often a `Sender`.
	Handlers(p, e) : {
		on_open! : p => Try({}, e),
		on_message! : p, Ws.Message => Try({}, e),
		on_close! : p, Ws.Closure => Try({}, e),
	}

	# ------------------------------------------- what the pure core needs

	## A byte stream, for a platform where Roc owns the wire (TCP).
	## `read_up_to!(n)` returns 1 to `n` bytes, or `[]` at the end of the
	## stream. A read that gives up on a deadline (`TimedOut` in `e`) must
	## consume nothing, so a later read gets every byte.
	Bytes(e, r) : { write_bytes! : List(U8) => Try({}, [Closed(Ws.Closure), ..e]), read_up_to! : U64 => Try(List(U8), [Closed(Ws.Closure), ..e]), ..r }

	## Unpredictable bytes (RFC 6455 section 10.3) for the client's key and
	## masks: `random_bytes!(n)` gives exactly `n` bytes.
	Random(e, r) : { random_bytes! : U64 => Try(List(U8), [Closed(Ws.Closure), ..e]), ..r }

	# ------------------------------------------------ pre-composed aliases

	## A connection with only the core.
	Basic(e) : Ws.Core(e, {})

	## A connection over raw bytes, as `Client.open!` gives: the core, ping,
	## pong and frames.
	Raw(e) : Ws.Core(e, Ws.Ping(e, Ws.Pong(e, Ws.Frames(e, {}))))

	## A connection with the core and a receive with a deadline.
	Timed(e) : Ws.Core(e, Ws.ReceiveWithin(e, {}))

	## A push-model server connection: sending only, events by callback.
	Push(e) : Ws.Sender(e, {})

	## What `Client.open!` needs from a platform: a byte stream and randomness.
	Transport(e) : Ws.Bytes(e, Ws.Random(e, {}))

	# ------------------------------------------------------------ helpers

	## The messages of a connection as a stream, until it closes. An error
	## other than `Closed` is an `Err` item, after which the stream ends.
	messages : { receive! : {} => Try(Ws.Message, [Closed(Ws.Closure), ..e]), .. } -> Stream(Try(Ws.Message, [Closed(Ws.Closure), ..e]))
	messages = |conn| Stream.custom(
		Bool.True,
		Unknown,
		|going| if going {
			match (conn.receive!)({}) {
				Ok(m) => Ok((Ok(m), Bool.True))
				Err(Closed(_)) => Err(NoMore)
				Err(other) => Ok((Err(other), Bool.False))
			}
		} else {
			Err(NoMore)
		},
	)

	## The closure of a connection that dropped with no Close frame.
	dropped : Ws.Closure
	dropped = { code: 1006, reason: "", clean: Bool.False, by: Transport }
}
