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
## The error rule: every effectful field returns `Ws.Error(e)`, that is
## `[Closed(Ws.Closure), Closing, ..e]`, with one `e` for all the fields of an
## adapter. `Closed` and `Closing` are the tags every adapter shares. A failure
## that a feature adds is a tag of `e`, because code generic in a row variable
## cannot widen it. Tags of `e` with a shared meaning:
## - `InvalidClose(Str)`: `close!` got a code that may not be sent or a reason
##   over 123 bytes.
## - `ControlTooLong(U64)`: a Ping or Pong payload over 125 bytes.
## - `BadFrame(Str)`: `send_frame!` got a frame that breaks RFC 6455.
## - `TooLarge(U64)`: a value over a platform limit.
## - `Refused(Str)`, `NotUpgrade(Str)`: opening a connection failed.
## An outcome that is not a failure is in the `Ok` side (`TimedOut`, `Nothing`).
##
## Naming: a module's `Errors` is its row of extra tags (the `e` it passes to
## these aliases) and its `Error` the whole union, `Ws.Error(Errors)`.
Ws :: [].{

	## Every error of an effectful field: the connection has ended
	## (`Closed`), this endpoint can no longer send and does not know the
	## closure yet (`Closing`), or a tag of the adapter's row `e`.
	Error(e) : [Closed(Ws.Closure), Closing, ..e]

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
	## bytes. With no `max_message` the adapter's own limit applies (16 MiB
	## over bytes, `Client.default_max_message`). A bigger message fails the
	## connection with 1009: `receive!` gives
	## `Closed({ code: 1009, by: Us, clean: Bool.False, .. })`.
	ConnectRequest : { url : Str, protocols ?: List(Str), headers ?: List((Str, Str)), max_message ?: U64 }

	## An open connection `conn`, with what the handshake settled: the chosen
	## subprotocol (`""` for none) and the extensions, `Reported(list)` (an
	## empty list for none) or `NotReported` where the platform does not tell
	## (a runtime that negotiates and applies an extension by itself).
	Opened(c) : { conn : c, protocol : Str, extensions : [Reported(List(Str)), NotReported] }

	## Options of a server accepting an upgrade: the subprotocols it supports,
	## in order of preference (default none), and `max_message`, the largest
	## message accepted, in bytes. The chosen subprotocol is the first of
	## `protocols` that the client offered, whatever the order of its offer;
	## none when nothing matches. With no `max_message` the adapter's own
	## limit applies (16 MiB over bytes, `Server.default_max_message`). A
	## bigger message fails the connection with 1009: `receive!` gives
	## `Closed({ code: 1009, by: Us, clean: Bool.False, .. })`.
	AcceptOptions : { protocols ?: List(Str), max_message ?: U64 }

	## An upgrade request as a server sees it before it accepts or refuses:
	## the resource (path and query), `Host`, the subprotocols the client
	## offered in its order, and every header, its name lowercased.
	Upgrade : { resource : Str, host : Str, protocols : List(Str), headers : List((Str, Str)) }

	## How a server refuses an upgrade: a final HTTP status, 200 to 599 (RFC
	## 6455 section 4.2.2 allows any status but 101), such as 401 with a
	## `WWW-Authenticate` header or a 3xx with a `Location`; extra response
	## headers (default none); a plain-text body (default none). How a refusal is sent is the platform's: a byte
	## server writes it, a request handler returns it as its response.
	Refusal : { status : U16, headers ?: List((Str, Str)), body ?: Str }

	# ---------------------------------------------------------------- features

	## What every connection can do on every platform.
	##
	## - `send!` sends one message.
	## - `receive!` waits for the next message. `Err(Closed(_))` once the
	##   connection has ended.
	## - `close!` starts the closing handshake: it sends Close and returns at
	##   once. `receive!` then delivers the messages already on their way and
	##   ends with `Closed({ by: Us, .. })` when the peer answers. Until then,
	##   `send!` and a second `close!` give `Closing`.
	##   `Ws.close_and_wait!` does both.
	Core(c, e, r) : { send! : c, Ws.Message => Try(c, Ws.Error(e)), receive! : c => Try((c, Ws.Message), Ws.Error(e)), close! : c, U16, Str => Try(c, Ws.Error(e)), ..r }

	## The sending half alone, for a push-model server whose messages arrive
	## as `Handlers` calls rather than by `receive!`.
	Sender(c, e, r) : { send! : c, Ws.Message => Try(c, Ws.Error(e)), close! : c, U16, Str => Try(c, Ws.Error(e)), ..r }

	## Send a protocol-level Ping (RFC 6455 section 5.5.2), payload at most 125
	## bytes. The peer's Pong is not reported by `receive!`; read it with
	## `Frames`.
	Ping(c, e, r) : { ping! : c, List(U8) => Try(c, Ws.Error(e)), ..r }

	## Send an unsolicited Pong, a one-way heartbeat (RFC 6455 section 5.5.3).
	Pong(c, e, r) : { pong! : c, List(U8) => Try(c, Ws.Error(e)), ..r }

	## Frame-level access: send any frame (fragments, control frames) and read
	## the next frame as it arrives, with no assembly and no automatic reply.
	## A received frame that breaks the protocol fails the connection.
	Frames(c, e, r) : { send_frame! : c, Frame => Try(c, Ws.Error(e)), receive_frame! : c => Try((c, Frame), Ws.Error(e)), ..r }

	## The next message, or `TimedOut` when `ms` milliseconds have passed
	## since the call. The deadline bounds the whole call: Ping, Pong and
	## partial frames do not extend it. An adapter that cannot bound the whole
	## call leaves the field out. `TimedOut` loses nothing.
	ReceiveWithin(c, e, r) : { receive_within! : c, U64 => Try((c, [Message(Ws.Message), TimedOut]), Ws.Error(e)), ..r }

	## An idle deadline: the next message, or `TimedOut` only when one read
	## passes the platform's read deadline with no bytes. Any frame, a Ping
	## included, restarts it, so `poll!` cannot be used to build a deadline for
	## data messages (use `ReceiveWithin`). `TimedOut` loses nothing.
	Poll(c, e, r) : { poll! : c => Try((c, [Message(Ws.Message), TimedOut]), Ws.Error(e)), ..r }

	## The bytes queued for sending and not yet handed to the network.
	Buffered(c, e, r) : { buffered_amount! : c => Try(U64, Ws.Error(e)), ..r }

	## A fixed text reply that the runtime sends to a fixed text request by
	## itself, without running application code (an application-level
	## heartbeat that does not wake the server). `c` is the scope the runtime
	## sets it for: a connection, or a whole server (every connection it
	## holds) on a runtime that keeps one reply per server.
	AutoResponse(c, e, r) : { set_auto_response! : c, { request : Str, response : Str } => Try(c, Ws.Error(e)), clear_auto_response! : c => Try(c, Ws.Error(e)), ..r }

	## Per-connection state kept by the runtime, which survives the server
	## leaving memory while the connection stays open (hibernation).
	Persist(c, e, r) : { saved! : c => Try([Saved(List(U8)), Nothing], Ws.Error(e)), save! : c, List(U8) => Try(c, Ws.Error(e)), ..r }

	## Named groups of connections, with one send to every member
	## (publish/subscribe).
	Topics(c, e, r) : { subscribe! : c, Str => Try(c, Ws.Error(e)), unsubscribe! : c, Str => Try(c, Ws.Error(e)), publish! : c, Str, Ws.Message => Try(c, Ws.Error(e)), ..r }

	## Open a client connection `c`. A server that refuses the upgrade is
	## `Refused(Str)` in `e`.
	Connect(c, e, r) : { connect! : Ws.ConnectRequest => Try(Ws.Opened(c), Ws.Error(e)), ..r }

	## Accept an upgrade of an incoming request `q` into a server connection
	## `c`. `response` is the handshake response `p` that the application
	## hands back to its runtime, on a platform where the request handler
	## returns the 101 response (the connection then lives in work that runs
	## after it); `{}` where `accept!` writes the response itself. A request
	## that is not a valid upgrade is `NotUpgrade(Str)` in `e`.
	Accept(q, p, c, e, r) : { accept! : q, Ws.AcceptOptions => Try({ response : p, opened : Ws.Opened(c) }, Ws.Error(e)), ..r }

	## Callbacks of a push-model server, where the runtime delivers events.
	## `s` is the application's state, threaded from call to call, and `c` the
	## connection, used with the adapter's `Sender` fields. On a runtime that
	## does not keep the server in memory between events, the adapter stores
	## `s` (for example through `Persist`) or the application keeps `s` as `{}`.
	##
	## `on_close!` gets the connection too, after it has ended: for what the
	## value holds (an adapter's link to close, a connection id to forget, a
	## `Persist` attachment to read). Sending on it gives `Closed`. It returns
	## no connection, since nothing follows it.
	Handlers(s, c, e) : {
		on_open! : s, c => Try((s, c), Ws.Error(e)),
		on_message! : s, c, Ws.Message => Try((s, c), Ws.Error(e)),
		on_close! : s, c, Ws.Closure => Try(s, Ws.Error(e)),
	}

	# ------------------------------------------- what the pure core needs

	## A byte stream `b`, for a platform where Roc owns the wire (TCP).
	## `read_up_to!(b, n)` gives `Data` of 1 to `n` bytes, `End` at the end of
	## the stream, or `TimedOut` when a platform deadline passed with nothing
	## to read (it consumes nothing).
	Bytes(b, e, r) : { write_bytes! : b, List(U8) => Try(b, Ws.Error(e)), read_up_to! : b, U64 => Try((b, [Data(List(U8)), End, TimedOut]), Ws.Error(e)), ..r }

	## Unpredictable bytes (RFC 6455 section 10.3) for the client's key and
	## masks: `random_bytes!(b, n)` gives exactly `n` bytes. `b` may carry a
	## generator's state.
	Random(b, e, r) : { random_bytes! : b, U64 => Try((b, List(U8)), Ws.Error(e)), ..r }

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

	## The messages of a connection as a stream. The last item is the `Err`
	## that ended it: `Err(Closed(closure))` once the connection has ended, or
	## another error of `receive!`.
	messages : { receive! : c => Try((c, Ws.Message), Ws.Error(e)), .. }, c -> Stream(Try(Ws.Message, Ws.Error(e)))
	messages = |ops, conn| Stream.custom(
		Going(conn),
		Err(Unknown),
		|state| match state {
			Going(c) =>
				match (ops.receive!)(c) {
					Ok((next, m)) => Ok((Ok(m), Going(next)))
					Err(err) => Ok((Err(err), Stopped))
				}
			Stopped => Err(NoMore)
		},
	)

	## Close and wait for the end of the closing handshake, dropping the
	## messages that arrive meanwhile. A connection that is closing already
	## (`close!` gives `Closing`) is waited for as it is.
	close_and_wait! : { close! : c, U16, Str => Try(c, Ws.Error(e)), receive! : c => Try((c, Ws.Message), Ws.Error(e)), .. }, c, U16, Str => Try(Ws.Closure, Ws.Error(e))
	close_and_wait! = |ops, conn, code, reason| {
		var $c = match (ops.close!)(conn, code, reason) {
			Ok(closing) => closing
			Err(Closing) => conn
			Err(other) => return Err(other)
		}
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
	## `on_message!` for each message, then `on_close!` with the connection
	## as the last call left it and the closure.
	##
	## The result is the state and how the run ended, both ways: `(s,
	## Ok(closure))` after `on_close!`, whose state it is, or `(s, Err(err))`
	## with the state as the last handler that succeeded left it (the initial
	## state when `on_open!` fails). So an error does not lose the state:
	##
	## ```roc
	## (count, ended) = Ws.drive!(ops, conn, 0, handlers)
	## save!(count)
	## closure = ended?
	## ```
	##
	## A handler that fails with `Closed` (it sent on a connection that had
	## ended, such as one whose stream dropped with messages still to deliver)
	## does not end the run: the messages left are delivered from the
	## connection as it was before that call, then `on_close!` runs. Any other
	## handler error, or an error of `receive!` other than `Closed`, ends the
	## run with that error and no `on_close!`.
	drive! : { receive! : c => Try((c, Ws.Message), Ws.Error(e)), .. }, c, s, Ws.Handlers(s, c, e) => (s, Try(Ws.Closure, Ws.Error(e)))
	drive! = |ops, conn, state, handlers| {
		(s0, c0) = match (handlers.on_open!)(state, conn) {
			Ok(opened) => opened
			Err(err) => return (state, Err(err))
		}
		var $s = s0
		var $c = c0
		while Bool.True {
			match (ops.receive!)($c) {
				Ok((next, m)) =>
					match (handlers.on_message!)($s, next, m) {
						Ok((s1, c1)) => {
							$s = s1
							$c = c1
						}
						Err(Closed(_)) => {
							$c = next
						}
						Err(other) => return ($s, Err(other))
					}
				Err(Closed(closure)) =>
					return match (handlers.on_close!)($s, $c, closure) {
						Ok(closed) => (closed, Ok(closure))
						Err(err) => ($s, Err(err))
					}
				Err(other) => return ($s, Err(other))
			}
		}
	}

	## The closure of a connection that dropped with no Close frame.
	dropped : Ws.Closure
	dropped = { code: 1006, reason: "", clean: Bool.False, by: Transport }
}
