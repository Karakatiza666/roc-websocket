import Frame

## The shared WebSocket types: messages, how a connection ends, and each
## feature a platform may have, as an extensible record alias.
##
## A connection is a value `c`. Each effectful call takes it and returns the
## updated value with its result, so protocol state (buffered bytes, a
## fragment, a pending close) carries from one call to the next. A platform
## whose host keeps the state returns the same handle unchanged.
##
## An adapter gives the operations as a record of the fields its platform
## supports, typed as the composition of these aliases:
## `Ws.Core(c, e, Ws.Ping(c, e, {}))`. A feature the platform lacks has no
## field, so code that needs it does not compile with that adapter. In every
## alias `c` is the connection, `e` the platform's extra error tags, and `r`
## the rest of the record.
##
## The error rule: every effectful field returns `[Closed(Ws.Closure), ..e]`,
## with one `e` for all the fields of an adapter. `Closed` is the one tag every
## adapter shares. A failure that a feature adds is a tag of `e`, because code
## generic in a row variable cannot widen it. Tags of `e` with a shared meaning:
## - `InvalidClose(Str)`: `close!` got a code that may not be sent or a reason
##   over 123 bytes.
## - `ControlTooLong(U64)`: a Ping or Pong payload over 125 bytes.
## - `BadFrame(Str)`: `send_frame!` got a frame that breaks RFC 6455.
## - `TooLarge(U64)`: a value over a platform limit.
## - `Refused(Str)`, `NotUpgrade(Str)`: opening a connection failed.
## An outcome that is not a failure is in the `Ok` side (`TimedOut`, `Idle`).
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

	## What every connection can do on every platform.
	##
	## - `send!` sends one message.
	## - `receive!` waits for the next message. `Err(Closed(_))` once the
	##   connection has ended.
	## - `close!` starts the closing handshake: it sends Close and returns at
	##   once. `receive!` then delivers the messages already on their way and
	##   ends with `Closed({ by: Us, .. })` when the peer answers.
	##   `Ws.close_and_wait!` does both.
	Core(c, e, r) : { send! : c, Ws.Message => Try(c, [Closed(Ws.Closure), ..e]), receive! : c => Try((c, Ws.Message), [Closed(Ws.Closure), ..e]), close! : c, U16, Str => Try(c, [Closed(Ws.Closure), ..e]), ..r }

	## The sending half alone, for a push-model server whose messages arrive
	## as `Handlers` calls rather than by `receive!`.
	Sender(c, e, r) : { send! : c, Ws.Message => Try(c, [Closed(Ws.Closure), ..e]), close! : c, U16, Str => Try(c, [Closed(Ws.Closure), ..e]), ..r }

	## Send a protocol-level Ping (RFC 6455 section 5.5.2), payload at most 125
	## bytes. The peer's Pong is not reported by `receive!`; read it with
	## `Frames`.
	Ping(c, e, r) : { ping! : c, List(U8) => Try(c, [Closed(Ws.Closure), ..e]), ..r }

	## Send an unsolicited Pong, a one-way heartbeat (RFC 6455 section 5.5.3).
	Pong(c, e, r) : { pong! : c, List(U8) => Try(c, [Closed(Ws.Closure), ..e]), ..r }

	## Frame-level access: send any frame (fragments, control frames) and read
	## the next frame as it arrives, with no assembly and no automatic reply.
	## A received frame that breaks the protocol fails the connection.
	Frames(c, e, r) : { send_frame! : c, Frame => Try(c, [Closed(Ws.Closure), ..e]), receive_frame! : c => Try((c, Frame), [Closed(Ws.Closure), ..e]), ..r }

	## A receive that waits at most `ms` milliseconds. `TimedOut` loses
	## nothing.
	ReceiveWithin(c, e, r) : { receive_within! : c, U64 => Try((c, [Message(Ws.Message), TimedOut]), [Closed(Ws.Closure), ..e]), ..r }

	## A receive that waits only as long as the platform's own read deadline
	## (a fixed time the application does not choose), then gives `Idle`.
	## `Idle` loses nothing.
	Poll(c, e, r) : { poll! : c => Try((c, [Message(Ws.Message), Idle]), [Closed(Ws.Closure), ..e]), ..r }

	## The bytes queued for sending and not yet handed to the network.
	Buffered(c, e, r) : { buffered_amount! : c => Try(U64, [Closed(Ws.Closure), ..e]), ..r }

	## A fixed text reply that the runtime sends to a fixed text request by
	## itself, without running application code (an application-level
	## heartbeat that does not wake the server).
	AutoResponse(c, e, r) : { set_auto_response! : c, { request : Str, response : Str } => Try(c, [Closed(Ws.Closure), ..e]), clear_auto_response! : c => Try(c, [Closed(Ws.Closure), ..e]), ..r }

	## Per-connection state kept by the runtime, which survives the server
	## leaving memory while the connection stays open (hibernation).
	Persist(c, e, r) : { saved! : c => Try([Saved(List(U8)), Nothing], [Closed(Ws.Closure), ..e]), save! : c, List(U8) => Try(c, [Closed(Ws.Closure), ..e]), ..r }

	## Named groups of connections, with one send to every member
	## (publish/subscribe).
	Topics(c, e, r) : { subscribe! : c, Str => Try(c, [Closed(Ws.Closure), ..e]), unsubscribe! : c, Str => Try(c, [Closed(Ws.Closure), ..e]), publish! : c, Str, Ws.Message => Try(c, [Closed(Ws.Closure), ..e]), ..r }

	## Open a client connection `c`. A server that refuses the upgrade is
	## `Refused(Str)` in `e`.
	Dial(c, e, r) : { connect! : Ws.Request => Try(Ws.Opened(c), [Closed(Ws.Closure), ..e]), ..r }

	## Accept an upgrade of an incoming request `q` into a server connection
	## `c`. A request that is not a valid upgrade is `NotUpgrade(Str)` in `e`.
	Accept(q, c, e, r) : { accept! : q, Ws.AcceptOptions => Try(Ws.Opened(c), [Closed(Ws.Closure), ..e]), ..r }

	## Callbacks of a push-model server, where the runtime delivers events.
	## `s` is the application's state, threaded from call to call, and `c` the
	## connection, used with the adapter's `Sender` fields. On a runtime that
	## does not keep the server in memory between events, the adapter stores
	## `s` (for example through `Persist`) or the application keeps `s` as `{}`.
	Handlers(s, c, e) : {
		on_open! : s, c => Try((s, c), [Closed(Ws.Closure), ..e]),
		on_message! : s, c, Ws.Message => Try((s, c), [Closed(Ws.Closure), ..e]),
		on_close! : s, Ws.Closure => Try(s, [Closed(Ws.Closure), ..e]),
	}

	# ------------------------------------------- what the pure core needs

	## A byte stream `b`, for a platform where Roc owns the wire (TCP).
	## `read_up_to!(b, n)` gives `Data` of 1 to `n` bytes, `End` at the end of
	## the stream, or `TimedOut` when a platform deadline passed with nothing
	## to read (it consumes nothing).
	Bytes(b, e, r) : { write_bytes! : b, List(U8) => Try(b, [Closed(Ws.Closure), ..e]), read_up_to! : b, U64 => Try((b, [Data(List(U8)), End, TimedOut]), [Closed(Ws.Closure), ..e]), ..r }

	## Unpredictable bytes (RFC 6455 section 10.3) for the client's key and
	## masks: `random_bytes!(b, n)` gives exactly `n` bytes. `b` may carry a
	## generator's state.
	Random(b, e, r) : { random_bytes! : b, U64 => Try((b, List(U8)), [Closed(Ws.Closure), ..e]), ..r }

	# ------------------------------------------------ pre-composed aliases

	## A connection with only the core.
	Basic(c, e) : Ws.Core(c, e, {})

	## A connection over raw bytes: the core, ping, pong and frames.
	Raw(c, e) : Ws.Core(c, e, Ws.Ping(c, e, Ws.Pong(c, e, Ws.Frames(c, e, {}))))

	## A connection with the core and a receive with a deadline.
	Timed(c, e) : Ws.Core(c, e, Ws.ReceiveWithin(c, e, {}))

	## A push-model server connection: sending only, events by callback.
	Push(c, e) : Ws.Sender(c, e, {})

	## What the pure client needs from a platform: a byte stream and
	## randomness over one link state `b`.
	Transport(b, e) : Ws.Bytes(b, e, Ws.Random(b, e, {}))

	# ------------------------------------------------------------ helpers

	## The messages of a connection as a stream, until it closes. An error
	## other than `Closed` is an `Err` item, after which the stream ends.
	messages : { receive! : c => Try((c, Ws.Message), [Closed(Ws.Closure), ..e]), .. }, c -> Stream(Try(Ws.Message, [Closed(Ws.Closure), ..e]))
	messages = |ops, conn| Stream.custom(
		Going(conn),
		Unknown,
		|state| match state {
			Going(c) =>
				match (ops.receive!)(c) {
					Ok((next, m)) => Ok((Ok(m), Going(next)))
					Err(Closed(_)) => Err(NoMore)
					Err(other) => Ok((Err(other), Stopped))
				}
			Stopped => Err(NoMore)
		},
	)

	## Close and wait for the end of the closing handshake, dropping the
	## messages that arrive meanwhile.
	close_and_wait! : { close! : c, U16, Str => Try(c, [Closed(Ws.Closure), ..e]), receive! : c => Try((c, Ws.Message), [Closed(Ws.Closure), ..e]), .. }, c, U16, Str => Try(Ws.Closure, [Closed(Ws.Closure), ..e])
	close_and_wait! = |ops, conn, code, reason| {
		var $c = (ops.close!)(conn, code, reason)?
		while Bool.True {
			match (ops.receive!)($c) {
				Ok((next, _)) => {
					$c = next
				}
				Err(Closed(closure)) => return Ok(closure)
				Err(other) => return Err(other)
			}
		}
	}

	## Run push handlers over a pull connection until it closes: `on_open!`,
	## `on_message!` for each message, then `on_close!`, whose state is the
	## result.
	drive! : { receive! : c => Try((c, Ws.Message), [Closed(Ws.Closure), ..e]), .. }, c, s, Ws.Handlers(s, c, e) => Try(s, [Closed(Ws.Closure), ..e])
	drive! = |ops, conn, state, handlers| {
		(s0, c0) = (handlers.on_open!)(state, conn)?
		var $s = s0
		var $c = c0
		while Bool.True {
			match (ops.receive!)($c) {
				Ok((next, m)) => {
					(s1, c1) = (handlers.on_message!)($s, next, m)?
					$s = s1
					$c = c1
				}
				Err(Closed(closure)) => return (handlers.on_close!)($s, closure)
				Err(other) => return Err(other)
			}
		}
	}

	## The closure of a connection that dropped with no Close frame.
	dropped : Ws.Closure
	dropped = { code: 1006, reason: "", clean: Bool.False, by: Transport }
}
