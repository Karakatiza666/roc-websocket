import Ws
import Frame
import Handshake
import Protocol
import Session

## A WebSocket client over a byte stream, for platforms where Roc owns the
## wire (TCP). The platform adapter connects the stream and gives
## `Client.open!` its `Client.Transport` operations and link value `b`; the
## client does the handshake, framing, masking, fragment assembly, Ping
## replies and the closing handshake.
##
## A `Client.Conn` is a value: each call returns the updated connection, which
## keeps the bytes read past the current frame, a half-received message, the
## messages of one read not yet delivered, and a pending close.
Client :: [].{

	## The tags the client adds to the platform's row `e`.
	Errors(e) : [Refused(Str), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e]

	## Every error of a client call: `Closed`, `Closing` and `Client.Errors(e)`.
	Error(e) : Ws.Error(Client.Errors(e))

	## What `Client.open!` needs: a byte stream and randomness over one link
	## value `b`, whose errors are the platform's row with the client's tags.
	Transport(b, e) : Ws.Transport(b, Client.Errors(e))

	## The operations of a client connection as a record, for code generic
	## over features: the core, ping, pong, frames and poll.
	Ops(b, e) : Ws.Core(Client.Conn(b, e), Client.Errors(e), Ws.Ping(Client.Conn(b, e), Client.Errors(e), Ws.Pong(Client.Conn(b, e), Client.Errors(e), Ws.Frames(Client.Conn(b, e), Client.Errors(e), Ws.Poll(Client.Conn(b, e), Client.Errors(e), {})))))

	## An open client connection over the link value `b`, from `Client.open!`.
	Conn(b, e) :: { session : Session(b, [Refused(Str), ..e]) }.{

		## The link value as the last call left it, for an adapter that needs
		## its stream back (to close it, for example).
		link : Client.Conn(b, e) -> b
		link = |conn| conn.session.link()

		## The same connection with its link value changed by `change`, for an
		## adapter that adjusts its stream between calls (a read timeout for
		## one call, for example). The protocol state is untouched, so bytes
		## already read and a half-received message are kept.
		map_link : Client.Conn(b, e), (b -> b) -> Client.Conn(b, e)
		map_link = |conn, change| { ..conn, session: conn.session.map_link(change) }

		## Send one message, in one frame.
		send! : Client.Conn(b, e), Ws.Message => Try(Client.Conn(b, e), Client.Error(e))
		send! = |conn, message| match conn.session.send!(message) {
			Ok(session) => Ok({ ..conn, session })
			Err(err) => Err(err)
		}

		## The next message. A platform read deadline passing is not reported:
		## `receive!` keeps waiting (see `poll!`). After `close!`, it delivers
		## the messages on their way and ends with `Closed({ by: Us, .. })`.
		receive! : Client.Conn(b, e) => Try((Client.Conn(b, e), Ws.Message), Client.Error(e))
		receive! = |conn| match conn.session.receive!() {
			Ok((session, m)) => Ok(({ ..conn, session }, m))
			Err(err) => Err(err)
		}

		## An idle deadline: the next message, or `TimedOut` only when one read
		## passes the platform's read deadline with no bytes. Any frame, a Ping
		## included, restarts it, so it cannot bound the wait for a data message.
		## Nothing is lost.
		poll! : Client.Conn(b, e) => Try((Client.Conn(b, e), [Message(Ws.Message), TimedOut]), Client.Error(e))
		poll! = |conn| match conn.session.poll!() {
			Ok((session, got)) => Ok(({ ..conn, session }, got))
			Err(err) => Err(err)
		}

		## Start the closing handshake: send Close and return. A code that may
		## not be sent or a reason over 123 bytes is `InvalidClose`.
		close! : Client.Conn(b, e), U16, Str => Try(Client.Conn(b, e), Client.Error(e))
		close! = |conn, code, reason| match conn.session.close!(code, reason) {
			Ok(session) => Ok({ ..conn, session })
			Err(err) => Err(err)
		}

		## Send a Ping, payload at most 125 bytes.
		ping! : Client.Conn(b, e), List(U8) => Try(Client.Conn(b, e), Client.Error(e))
		ping! = |conn, payload| match conn.session.ping!(payload) {
			Ok(session) => Ok({ ..conn, session })
			Err(err) => Err(err)
		}

		## Send an unsolicited Pong, payload at most 125 bytes.
		pong! : Client.Conn(b, e), List(U8) => Try(Client.Conn(b, e), Client.Error(e))
		pong! = |conn, payload| match conn.session.pong!(payload) {
			Ok(session) => Ok({ ..conn, session })
			Err(err) => Err(err)
		}

		## Send any frame, masked. A frame that breaks RFC 6455 is `BadFrame`.
		send_frame! : Client.Conn(b, e), Frame => Try(Client.Conn(b, e), Client.Error(e))
		send_frame! = |conn, frame| match conn.session.send_frame!(frame) {
			Ok(session) => Ok({ ..conn, session })
			Err(err) => Err(err)
		}

		## The next frame as it arrives: no assembly, no reply. Do not mix it
		## with `receive!` inside a fragmented message.
		receive_frame! : Client.Conn(b, e) => Try((Client.Conn(b, e), Frame), Client.Error(e))
		receive_frame! = |conn| match conn.session.receive_frame!() {
			Ok((session, frame)) => Ok(({ ..conn, session }, frame))
			Err(err) => Err(err)
		}
	}

	## The largest message accepted when the request does not say: 16 MiB.
	default_max_message : U64
	default_max_message = Session.default_max_message

	## The operations as a record, for code generic over features.
	ops : {} -> Client.Ops(b, e)
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

	## Do the opening handshake over a connected link and return the
	## connection. `request.url` gives the `Host` header and the resource; the
	## adapter has already connected to its host and port (and done TLS for
	## `wss://`). A refused upgrade, the stream ending during it, or no answer
	## before the platform's read deadline is `Refused`.
	open! : Client.Transport(b, e), b, Ws.ConnectRequest => Try(Ws.Opened(Client.Conn(b, e)), Client.Error(e))
	open! = |transport, link0, request| {
		url = Handshake.parse_url(request.url).map_err(|BadUrl(why)| Refused(why))?
		max_message = request.?max_message ?? Client.default_max_message
		(link1, key) = (transport.random_bytes!)(link0, 16)?
		client_request = {
			url,
			key,
			protocols: request.?protocols ?? [],
			headers: request.?headers ?? [],
		}
		head = match Handshake.client_request(client_request) {
			Ok(text) => text
			Err(BadKey(n)) => crash "Client.open!: random_bytes!(16) gave ${n.to_str()} bytes"
		}
		link2 = (transport.write_bytes!)(link1, head.to_utf8())?
		(link3, response, rest) = read_head!(transport, link2)?
		agreed = Handshake.check_response(response, client_request)?
		bytes = { write_bytes!: transport.write_bytes!, read_up_to!: transport.read_up_to! }
		mask! = |link| match (transport.random_bytes!)(link, 4) {
			Ok((next, mask_key)) => Ok((next, Masked(mask_key)))
			Err(err) => Err(err)
		}
		session = Session.start!(bytes, mask!, link3, Protocol.new(Client, max_message), rest)?
		conn = Conn.{ session }
		Ok({ conn, protocol: agreed.protocol, extensions: Reported(agreed.extensions) })
	}
}

## The bytes asked for in one read of the response head.
read_size : U64
read_size = 65536

## The largest response head accepted.
max_head : U64
max_head = 16384

## The response head, and the bytes read after it.
read_head! : Client.Transport(b, e), b => Try((b, Str, List(U8)), Client.Error(e))
read_head! = |transport, link| {
	var $link = link
	var $have = []
	while Bool.True {
		match Handshake.head_end($have, 0) {
			Ok(end) =>
				match Str.from_utf8($have.take_first(end)) {
					Ok(head) => return Ok(($link, head, $have.drop_first(end)))
					Err(_) => return Err(Refused("a response head that is not UTF-8"))
				}
			Err(NotFound) => {}
		}
		if $have.len() > max_head {
			return Err(Refused("a response head of more than ${max_head.to_str()} bytes"))
		}
		(next, got) = (transport.read_up_to!)($link, read_size)?
		$link = next
		match got {
			Data(bytes) => {
				$have = $have.concat(bytes)
			}
			End => return Err(Refused("the server ended the connection during the handshake"))
			TimedOut => return Err(Refused("no handshake response before the platform's read deadline"))
		}
	}
}
