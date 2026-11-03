import Ws
import Frame
import Handshake
import Protocol
import Session

## A WebSocket server over a byte stream, for platforms where Roc owns the
## wire and accepts TCP connections itself. The platform adapter accepts the
## TCP connection and gives `Server.accept!` its `Server.Transport` operations
## and link value `b`; the server reads the HTTP upgrade request, answers it,
## and then does framing, fragment assembly, Ping replies and the closing
## handshake. Frames it sends are unmasked; a client frame that is not masked
## fails the connection with 1002. No randomness is needed.
##
## `Server.read_request!` stops after reading the request, for an application
## that looks at it before it accepts or refuses.
##
## A `Server.Conn` is a value with the methods of `Client.Conn`: each call
## returns the updated connection.
Server :: [].{

	## The tags the server adds to the platform's row `e`: `NotUpgrade(why)`
	## for a request that is not a valid upgrade (answered with a refusal
	## already), `InvalidStatus(status)` for a refusal status that is not a
	## final HTTP status (200-599, so never 101), and the frame tags of
	## `Client.Errors`.
	Errors(e) : [NotUpgrade(Str), InvalidStatus(U16), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e]

	## Every error of a server call: `Closed`, `Closing` and `Server.Errors(e)`.
	Error(e) : Ws.Error(Server.Errors(e))

	## What the server needs: a byte stream over a link value `b`, whose
	## errors are the platform's row with the server's tags. No randomness.
	Transport(b, e) : Ws.Bytes(b, Server.Errors(e), {})

	## The operations of a server connection as a record, for code generic
	## over features: the core, ping, pong, frames and poll.
	Ops(b, e) : Ws.Core(Server.Conn(b, e), Server.Errors(e), Ws.Ping(Server.Conn(b, e), Server.Errors(e), Ws.Pong(Server.Conn(b, e), Server.Errors(e), Ws.Frames(Server.Conn(b, e), Server.Errors(e), Ws.Poll(Server.Conn(b, e), Server.Errors(e), {})))))

	## An open server connection over the link value `b`, from
	## `Server.accept!` or `request.accept!`.
	Conn(b, e) :: { session : Session(b, [NotUpgrade(Str), InvalidStatus(U16), ..e]) }.{

		## The link value as the last call left it, for an adapter that needs
		## its stream back (to close it, for example).
		link : Server.Conn(b, e) -> b
		link = |conn| conn.session.link()

		## The same connection with its link value changed by `change` (a
		## read timeout for one call, for example). The protocol state is
		## untouched.
		map_link : Server.Conn(b, e), (b -> b) -> Server.Conn(b, e)
		map_link = |conn, change| { ..conn, session: conn.session.map_link(change) }

		## Send one message, in one unmasked frame.
		send! : Server.Conn(b, e), Ws.Message => Try(Server.Conn(b, e), Server.Error(e))
		send! = |conn, message| match conn.session.send!(message) {
			Ok(session) => Ok({ ..conn, session })
			Err(err) => Err(err)
		}

		## The next message. A platform read deadline passing is not reported:
		## `receive!` keeps waiting (see `poll!`). After `close!`, it delivers
		## the messages on their way and ends with `Closed({ by: Us, .. })`.
		receive! : Server.Conn(b, e) => Try((Server.Conn(b, e), Ws.Message), Server.Error(e))
		receive! = |conn| match conn.session.receive!() {
			Ok((session, m)) => Ok(({ ..conn, session }, m))
			Err(err) => Err(err)
		}

		## The next message, or `TimedOut` when the platform's read deadline
		## passed with no message. Nothing is lost.
		poll! : Server.Conn(b, e) => Try((Server.Conn(b, e), [Message(Ws.Message), TimedOut]), Server.Error(e))
		poll! = |conn| match conn.session.poll!() {
			Ok((session, got)) => Ok(({ ..conn, session }, got))
			Err(err) => Err(err)
		}

		## Start the closing handshake: send Close and return. A code that may
		## not be sent or a reason over 123 bytes is `InvalidClose`. Once
		## `receive!` gives `Closed`, the adapter closes the stream (RFC 6455
		## section 7.1.1: the server closes the TCP connection first).
		close! : Server.Conn(b, e), U16, Str => Try(Server.Conn(b, e), Server.Error(e))
		close! = |conn, code, reason| match conn.session.close!(code, reason) {
			Ok(session) => Ok({ ..conn, session })
			Err(err) => Err(err)
		}

		## Send a Ping, payload at most 125 bytes.
		ping! : Server.Conn(b, e), List(U8) => Try(Server.Conn(b, e), Server.Error(e))
		ping! = |conn, payload| match conn.session.ping!(payload) {
			Ok(session) => Ok({ ..conn, session })
			Err(err) => Err(err)
		}

		## Send an unsolicited Pong, payload at most 125 bytes.
		pong! : Server.Conn(b, e), List(U8) => Try(Server.Conn(b, e), Server.Error(e))
		pong! = |conn, payload| match conn.session.pong!(payload) {
			Ok(session) => Ok({ ..conn, session })
			Err(err) => Err(err)
		}

		## Send any frame, unmasked. A frame that breaks RFC 6455 is `BadFrame`.
		send_frame! : Server.Conn(b, e), Frame => Try(Server.Conn(b, e), Server.Error(e))
		send_frame! = |conn, frame| match conn.session.send_frame!(frame) {
			Ok(session) => Ok({ ..conn, session })
			Err(err) => Err(err)
		}

		## The next frame as it arrives, unmasked: no assembly, no reply. Do
		## not mix it with `receive!` inside a fragmented message.
		receive_frame! : Server.Conn(b, e) => Try((Server.Conn(b, e), Frame), Server.Error(e))
		receive_frame! = |conn| match conn.session.receive_frame!() {
			Ok((session, frame)) => Ok(({ ..conn, session }, frame))
			Err(err) => Err(err)
		}
	}

	## An upgrade request read from the link and validated, not answered
	## yet, from `Server.read_request!`. It keeps the bytes the client sent
	## after the request head, the start of its first frames.
	Request(b, e) :: { transport : Server.Transport(b, e), link : b, upgrade : Handshake.Upgrade, rest : List(U8) }.{

		## The same request with its link value changed by `change`, for an
		## adapter that reads the request with one deadline and runs the
		## connection with another (a short handshake timeout, for example).
		map_link : Server.Request(b, e), (b -> b) -> Server.Request(b, e)
		map_link = |request, change| { ..request, link: change(request.link) }

		## The request: its resource, `Host`, the subprotocols the client
		## offered in order, and every header (names lowercased).
		upgrade : Server.Request(b, e) -> Ws.Upgrade
		upgrade = |request| {
			u = request.upgrade
			{ resource: u.resource, host: u.host, protocols: u.protocols, headers: u.headers }
		}

		## Accept the upgrade: write the 101 response with the first
		## subprotocol of `options.protocols` that the client offered (the
		## server's order of preference; none when nothing matches), and
		## return the connection. No
		## extension is accepted, so `extensions` is `Reported([])`. Bytes the
		## client sent after its request are then read as frames.
		##
		## To choose a subprotocol another way, pick one from
		## `request.upgrade().protocols` and pass `protocols: [chosen]`.
		accept! : Server.Request(b, e), Ws.AcceptOptions => Try(Ws.Opened(Server.Conn(b, e)), Server.Error(e))
		accept! = |request, options| {
			offer = request.upgrade
			protocol = Handshake.choose_protocol(offer, options.?protocols ?? [])
			response = match Handshake.accept_response(offer, protocol, []) {
				Ok(text) => text
				Err(NotOffered(p)) => crash "Server.accept!: choose_protocol gave `${p}`, which the client did not offer"
			}
			link = (request.transport.write_bytes!)(request.link, response.to_utf8())?
			mask! = |l| Ok((l, Unmasked))
			max_message = options.?max_message ?? Server.default_max_message
			session = Session.start!(request.transport, mask!, link, Protocol.new(Server, max_message), request.rest)?
			Ok({ conn: Server.Conn.{ session }, protocol, extensions: Reported([]) })
		}

		## Refuse the upgrade: write a response with `refusal.status`, its
		## headers and body, and give the link back for the adapter to close.
		## Any final status is allowed (a 3xx with a `Location` header, a 401
		## with `WWW-Authenticate`, a 4xx or 5xx). A status outside 200-599
		## (a 1xx, 101 among them, which ends no exchange, or no HTTP status)
		## is `InvalidStatus` and writes nothing.
		##
		## ```roc
		## link = request.refuse!({ status: 403, body: "no access to ${request.upgrade().resource}" })?
		## ```
		refuse! : Server.Request(b, e), Ws.Refusal => Try(b, Server.Error(e))
		refuse! = |request, refusal| {
			status = refusal.status
			if status < 200 or status > 599 {
				return Err(InvalidStatus(status))
			}
			response = Handshake.refusal(status, refusal.?headers ?? [], refusal.?body ?? "")
			(request.transport.write_bytes!)(request.link, response.to_utf8())
		}
	}

	## The largest message accepted when the options do not say: 16 MiB.
	default_max_message : U64
	default_max_message = Session.default_max_message

	## The largest request head accepted, `\r\n\r\n` included: 16 KiB. A
	## longer one is answered with 431.
	max_request_head : U64
	max_request_head = 16384

	## The operations as a record, for code generic over features
	## (`Ws.drive!`, `Ws.close_and_wait!`, `Ws.messages`).
	ops : {} -> Server.Ops(b, e)
	ops = |{}| {
		send!: |c, m| c.send!(m),
		receive!: |c| c.receive!(),
		close!: |c, code, reason| c.close!(code, reason),
		ping!: |c, p| c.ping!(p),
		pong!: |c, p| c.pong!(p),
		send_frame!: |c, f| c.send_frame!(f),
		receive_frame!: |c| c.receive_frame!(),
		poll!: |c| c.poll!(),
	}

	## Read the upgrade request from a link the adapter has accepted, and
	## validate it (RFC 6455 section 4.2.1). Each read asks for at most the
	## bytes still allowed by `max_request_head`, and bytes after the head are
	## kept in the request.
	##
	## A request that is not a valid upgrade is answered (400, 405, 426, or
	## 431 for a head over `max_request_head`) and gives `NotUpgrade(why)`;
	## the stream ending, or the platform's read deadline passing, before the
	## end of the head gives `NotUpgrade(why)` with nothing written.
	read_request! : Server.Transport(b, e), b => Try(Server.Request(b, e), Server.Error(e))
	read_request! = |transport, link0| {
		var $link = link0
		var $have = []
		while Bool.True {
			allowed = Server.max_request_head - $have.len()
			if allowed == 0 {
				return refuse_bad!(transport, $link, 431, "a request head of more than ${Server.max_request_head.to_str()} bytes")
			}
			(next, got) = (transport.read_up_to!)($link, allowed)?
			$link = next
			match got {
				Data(bytes) => {
					from = $have.len().minus_saturated(3)
					$have = $have.concat(bytes)
					match Handshake.head_end($have, from) {
						Ok(end) => return validate!(transport, $link, $have, end)
						Err(NotFound) => {}
					}
				}
				End => return Err(NotUpgrade("the client ended the connection before the end of its request"))
				TimedOut => return Err(NotUpgrade("no whole request before the platform's read deadline"))
			}
		}
	}

	## Read the request and accept it with `options`: `read_request!`, then
	## `request.accept!(options)`.
	accept! : Server.Transport(b, e), b, Ws.AcceptOptions => Try(Ws.Opened(Server.Conn(b, e)), Server.Error(e))
	accept! = |transport, link, options| {
		request = Server.read_request!(transport, link)?
		request.accept!(options)
	}
}

## Validate a whole request head and keep the bytes after it.
validate! : Server.Transport(b, e), b, List(U8), U64 => Try(Server.Request(b, e), Server.Error(e))
validate! = |transport, link, have, end| {
	head = match Str.from_utf8(have.take_first(end)) {
		Ok(text) => text
		Err(_) => return refuse_bad!(transport, link, 400, "a request head that is not UTF-8")
	}
	match Handshake.parse_upgrade(head) {
		Ok(upgrade) => Ok(Server.Request.{ transport, link, upgrade, rest: have.drop_first(end) })
		Err(Rejected({ status, why })) => refuse_bad!(transport, link, status, why)
	}
}

## Answer a request that is not a valid upgrade, and fail with `NotUpgrade`.
refuse_bad! : Server.Transport(b, e), b, U16, Str => Try(x, Server.Error(e))
refuse_bad! = |transport, link, status, why| {
	_ = (transport.write_bytes!)(link, Handshake.rejection(status, why).to_utf8())?
	Err(NotUpgrade(why))
}
