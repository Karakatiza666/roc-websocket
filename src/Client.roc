import Ws
import Frame
import Handshake
import Protocol

## A WebSocket client over a byte stream, for platforms where Roc owns the
## wire (TCP). The platform adapter connects the stream and gives
## `Client.open!` a `Ws.Transport`-shaped record; the client does the
## handshake, framing, masking, fragment assembly, Ping replies and the
## closing handshake.
##
## The connection keeps no state between calls: every read takes exactly
## the bytes of the current frame, so nothing is left over between
## messages. As a result, once `receive!` has returned `Closed`, a later
## call sees the end of the stream and returns `Closed` with code 1006.
Client :: [].{

	## The tags the client adds to the platform's row `e`. `TimedOut` comes
	## from the link: a read that gave up on a deadline. Between messages the
	## client returns it; inside a frame or a fragmented message it keeps
	## reading, since the partial state would be lost.
	Errors(e) : [TimedOut, Refused(Str), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e]

	## A connection from `Client.open!`.
	Conn(e) : Ws.Raw(Client.Errors(e))

	## What `Client.open!` needs: a connected byte stream and randomness, whose
	## errors are the platform's row with the client's tags.
	Link(e) : Ws.Transport(Client.Errors(e))

	## The largest message accepted when the request does not say: 16 MiB.
	default_max_message : U64
	default_max_message = 16 * 1024 * 1024

	## Do the opening handshake over a connected byte stream and return the
	## connection. `request.url` gives the `Host` header and the resource; the
	## adapter has already connected to its host and port (and done TLS for
	## `wss://`). The server refusing the upgrade, or ending the stream during
	## it, is `Refused`.
	open! : Client.Link(e), Ws.Request => Try(Ws.Opened(Client.Conn(e)), [Closed(Ws.Closure), TimedOut, Refused(Str), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e])
	open! = |link, request| {
		url = Handshake.parse_url(request.url).map_err(|BadUrl(why)| Refused(why))?
		max_message = request.?max_message ?? Client.default_max_message
		key = (link.random_bytes!)(16)?
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
		(link.write_bytes!)(head.to_utf8())?
		response = read_head!(link)?
		agreed = Handshake.check_response(response, client_request)?
		conn = {
			send!: |message| write_frame!(
				link,
				match message {
					Text(s) => Frame.text(s)
					Binary(b) => Frame.binary(b)
				},
			),
			receive!: |{}| receive!(link, max_message),
			close!: |code, reason| close!(link, max_message, code, reason),
			ping!: |payload| control!(link, Frame.ping(payload)),
			pong!: |payload| control!(link, Frame.pong(payload)),
			send_frame!: |frame| match Frame.encode(frame, Masked([0, 0, 0, 0])) {
				Ok(_) => write_frame!(link, frame)
				Err(ControlTooLong(n)) => Err(BadFrame("a control frame of ${n.to_str()} bytes"))
				Err(FragmentedControl) => Err(BadFrame("a fragmented control frame"))
				Err(BadMask(_)) => crash "Client: a 4-byte mask"
			},
			receive_frame!: |{}| receive_frame!(link, max_message),
		}
		Ok({ conn, protocol: agreed.protocol, extensions: agreed.extensions })
	}
}

## The largest response head accepted.
max_head : U64
max_head = 16384

## The response head, read without taking any byte after it.
read_head! : Client.Link(e) => Try(Str, [Closed(Ws.Closure), TimedOut, Refused(Str), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e])
read_head! = |link| {
	var $head = []
	while Bool.True {
		n = Handshake.head_wanted($head)
		if n == 0 {
			break
		}
		if $head.len() > max_head {
			return Err(Refused("a response head of more than ${max_head.to_str()} bytes"))
		}
		bytes = (link.read_up_to!)(n)?
		if bytes.is_empty() {
			return Err(Refused("the server ended the connection during the handshake"))
		}
		$head = $head.concat(bytes)
	}
	Str.from_utf8($head).map_err(|_| Refused("a response head that is not UTF-8"))
}

## Mask and write one frame. The frame is valid (checked by the caller).
write_frame! : Client.Link(e), Frame => Try({}, [Closed(Ws.Closure), TimedOut, Refused(Str), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e])
write_frame! = |link, frame| {
	key = (link.random_bytes!)(4)?
	match Frame.encode(frame, Masked(key)) {
		Ok(bytes) => (link.write_bytes!)(bytes)
		Err(BadMask(n)) => crash "Client: random_bytes!(4) gave ${n.to_str()} bytes"
		Err(ControlTooLong(n)) => Err(ControlTooLong(n))
		Err(FragmentedControl) => Err(BadFrame("a fragmented control frame"))
	}
}

control! : Client.Link(e), Frame => Try({}, [Closed(Ws.Closure), TimedOut, Refused(Str), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e])
control! = |link, frame|
	if frame.payload.len() > 125 {
		Err(ControlTooLong(frame.payload.len()))
	} else {
		write_frame!(link, frame)
	}

## The next message. A timeout between messages is `Err(TimedOut)` and loses
## nothing; a timeout inside a frame or a fragmented message keeps waiting,
## since the partial state would be lost.
receive! : Client.Link(e), U64 => Try(Ws.Message, [Closed(Ws.Closure), TimedOut, Refused(Str), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e])
receive! = |link, max_message| {
	var $p = Protocol.new(Client, max_message)
	while Bool.True {
		match (link.read_up_to!)($p.wanted()) {
			Ok([]) => return Err(Closed(Ws.dropped))
			Ok(bytes) => {
				(next, events) = $p.receive(bytes)
				$p = next
				for event in events {
					match event {
						Write(frame) => write_frame!(link, frame)?
						Message(m) => return Ok(m)
						Closed(c) => return Err(Closed(c))
						Ping(_) => {}
						Pong(_) => {}
					}
				}
			}
			Err(TimedOut) =>
				if $p.is_idle() {
					return Err(TimedOut)
				}
			Err(other) => return Err(other)
		}
	}
}

## Send a Close and read until the peer's Close, dropping messages. A
## timeout or the end of the stream before the peer's Close ends it as
## unclean (1006).
close! : Client.Link(e), U64, U16, Str => Try(Ws.Closure, [Closed(Ws.Closure), TimedOut, Refused(Str), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e])
close! = |link, max_message, code, reason| {
	(started, frame) = match Protocol.new(Client, max_message).close(code, reason) {
		Ok(pair) => pair
		Err(InvalidCode(c)) => return Err(InvalidClose("the close code ${c.to_str()} may not be sent"))
		Err(ReasonTooLong(n)) => return Err(InvalidClose("a close reason of ${n.to_str()} bytes; at most 123"))
		Err(NotOpen) => crash "Client.close!: a new protocol is open"
	}
	write_frame!(link, frame)?
	unclean = { code: 1006, reason: "", clean: Bool.False, by: Us }
	var $p = started
	while Bool.True {
		match (link.read_up_to!)($p.wanted()) {
			Ok([]) => return Ok(unclean)
			Ok(bytes) => {
				(next, events) = $p.receive(bytes)
				$p = next
				for event in events {
					match event {
						Write(f) => write_frame!(link, f)?
						Closed(c) => return Ok(c)
						Message(_) => {}
						Ping(_) => {}
						Pong(_) => {}
					}
				}
			}
			Err(TimedOut) => return Ok(unclean)
			Err(other) => return Err(other)
		}
	}
}

## The next frame as it is, with no assembly and no reply. A frame that
## breaks the protocol fails the connection with 1002.
receive_frame! : Client.Link(e), U64 => Try(Frame, [Closed(Ws.Closure), TimedOut, Refused(Str), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e])
receive_frame! = |link, max_message| {
	var $have = []
	while Bool.True {
		match Frame.decode($have, ExpectUnmasked) {
			Ok({ frame, .. }) => return Ok(frame)
			Err(Invalid(why)) => return fail_frames!(link, 1002, why)
			Err(Incomplete(n)) => {
				match Frame.header($have, ExpectUnmasked) {
					Ok(h) if h.length > max_message => return fail_frames!(link, 1009, "a frame of more than ${max_message.to_str()} bytes")
					_ => {}
				}
				match (link.read_up_to!)(n - $have.len()) {
					Ok([]) => return Err(Closed(Ws.dropped))
					Ok(bytes) => {
						$have = $have.concat(bytes)
					}
					Err(TimedOut) =>
						if $have.is_empty() {
							return Err(TimedOut)
						}
					Err(other) => return Err(other)
				}
			}
		}
	}
}

fail_frames! : Client.Link(e), U16, Str => Try(Frame, [Closed(Ws.Closure), TimedOut, Refused(Str), InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e])
fail_frames! = |link, code, why| {
	(_, frame) = match Protocol.new(Client, 0).close(code, why) {
		Ok(pair) => pair
		Err(_) => crash "Client: a valid failure code"
	}
	write_frame!(link, frame)?
	Err(Closed({ code, reason: why, clean: Bool.False, by: Us }))
}
