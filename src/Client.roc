import Ws
import Frame
import Handshake
import Protocol

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
	Conn(b, e) :: { transport : Client.Transport(b, e), link : b, protocol : Protocol, inbox : List(Ws.Message) }.{

		## The link value as the last call left it, for an adapter that needs
		## its stream back (to close it, for example).
		link : Client.Conn(b, e) -> b
		link = |conn| conn.link

		## Send one message, in one frame.
		send! : Client.Conn(b, e), Ws.Message => Try(Client.Conn(b, e), Client.Error(e))
		send! = |conn, message| {
			usable(conn)?
			write_frame!(
				conn,
				match message {
					Text(s) => Frame.text(s)
					Binary(b) => Frame.binary(b)
				},
			)
		}

		## The next message. A platform read deadline passing is not reported:
		## `receive!` keeps waiting (see `poll!`). After `close!`, it delivers
		## the messages on their way and ends with `Closed({ by: Us, .. })`.
		receive! : Client.Conn(b, e) => Try((Client.Conn(b, e), Ws.Message), Client.Error(e))
		receive! = |conn| {
			var $c = conn
			while Bool.True {
				match next_ready($c) {
					Ok((ready, m)) => return Ok((ready, m))
					Err(Ended(closure)) => return Err(Closed(closure))
					Err(Empty) => {}
				}
				(after, _) = step!($c)?
				$c = after
			}
		}

		## The next message, or `TimedOut` when the platform's read deadline
		## passed with no message. Nothing is lost.
		poll! : Client.Conn(b, e) => Try((Client.Conn(b, e), [Message(Ws.Message), TimedOut]), Client.Error(e))
		poll! = |conn| {
			var $c = conn
			while Bool.True {
				match next_ready($c) {
					Ok((ready, m)) => return Ok((ready, Message(m)))
					Err(Ended(closure)) => return Err(Closed(closure))
					Err(Empty) => {}
				}
				(after, progress) = step!($c)?
				if progress == TimedOut {
					return Ok((after, TimedOut))
				}
				$c = after
			}
		}

		## Start the closing handshake: send Close and return. A code that may
		## not be sent or a reason over 123 bytes is `InvalidClose`.
		close! : Client.Conn(b, e), U16, Str => Try(Client.Conn(b, e), Client.Error(e))
		close! = |conn, code, reason| {
			usable(conn)?
			match conn.protocol.close(code, reason) {
				Ok((protocol, frame)) => write_frame!({ ..conn, protocol }, frame)
				Err(InvalidCode(c)) => Err(InvalidClose("the close code ${c.to_str()} may not be sent"))
				Err(ReasonTooLong(n)) => Err(InvalidClose("a close reason of ${n.to_str()} bytes; at most 123"))
				Err(NotOpen) => crash "Client.close!: usable checked that the connection is open"
			}
		}

		## Send a Ping, payload at most 125 bytes.
		ping! : Client.Conn(b, e), List(U8) => Try(Client.Conn(b, e), Client.Error(e))
		ping! = |conn, payload| {
			usable(conn)?
			write_frame!(conn, Frame.ping(payload))
		}

		## Send an unsolicited Pong, payload at most 125 bytes.
		pong! : Client.Conn(b, e), List(U8) => Try(Client.Conn(b, e), Client.Error(e))
		pong! = |conn, payload| {
			usable(conn)?
			write_frame!(conn, Frame.pong(payload))
		}

		## Send any frame, masked. A frame that breaks RFC 6455 is `BadFrame`.
		send_frame! : Client.Conn(b, e), Frame => Try(Client.Conn(b, e), Client.Error(e))
		send_frame! = |conn, frame| {
			usable(conn)?
			write_frame!(conn, frame)
		}

		## The next frame as it arrives: no assembly, no reply. Do not mix it
		## with `receive!` inside a fragmented message.
		receive_frame! : Client.Conn(b, e) => Try((Client.Conn(b, e), Frame), Client.Error(e))
		receive_frame! = |conn| {
			var $c = conn
			while Bool.True {
				match $c.protocol.closure() {
					Ok(closure) => return Err(Closed(closure))
					Err(NotDone) => {}
				}
				match $c.protocol.take_frame() {
					Ok((protocol, frame)) => return Ok(({ ..$c, protocol }, frame))
					Err(Invalid(why)) => {
						$c = apply_events!($c, $c.protocol.fail(1002, why))?
					}
					Err(Incomplete(_)) => {
						max = $c.protocol.max_message()
						too_big = match Frame.header($c.protocol.pending_bytes(), ExpectUnmasked) {
							Ok(h) => h.length > max
							Err(_) => Bool.False
						}
						if too_big {
							$c = apply_events!($c, $c.protocol.fail(1009, "a frame of more than ${max.to_str()} bytes"))?
						} else {
							(after, got) = ($c.transport.read_up_to!)($c.link, read_size)?
							match got {
								Data(bytes) => {
									$c = { ..$c, link: after, protocol: $c.protocol.push(bytes) }
								}
								End => {
									$c = { ..$c, link: after, protocol: $c.protocol.ended().0 }
								}
								TimedOut => {
									$c = { ..$c, link: after }
								}
							}
						}
					}
				}
			}
		}
	}

	## The largest message accepted when the request does not say: 16 MiB.
	default_max_message : U64
	default_max_message = 16 * 1024 * 1024

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
		start = Conn.{ transport, link: link3, protocol: Protocol.new(Client, max_message), inbox: [] }
		conn = apply_events!(start, start.protocol.receive(rest))?
		Ok({ conn, protocol: agreed.protocol, extensions: Reported(agreed.extensions) })
	}
}

## The bytes asked for in one read.
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
		match head_end($have) {
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

## The index just after the first `\r\n\r\n`.
head_end : List(U8) -> Try(U64, [NotFound])
head_end = |bytes| {
	n = bytes.len()
	var $i = 0
	while $i + 4 <= n {
		if bytes.sublist({ start: $i, len: 4 }) == [13, 10, 13, 10] {
			return Ok($i + 4)
		}
		$i = $i + 1
	}
	Err(NotFound)
}

## Fail when the connection has ended or this endpoint already sent Close.
usable : Client.Conn(b, e) -> Try({}, Client.Error(e))
usable = |conn| match conn.protocol.closure() {
	Ok(closure) => Err(Closed(closure))
	Err(NotDone) =>
		match conn.protocol.closing() {
			Ok(_) => Err(Closing)
			Err(NotClosing) => Ok({})
		}
}

## A message already received, or why there is none.
next_ready : Client.Conn(b, e) -> Try((Client.Conn(b, e), Ws.Message), [Ended(Ws.Closure), Empty])
next_ready = |conn| match conn.inbox {
	[m, .. as rest] => Ok(({ ..conn, inbox: rest }, m))
	[] =>
		match conn.protocol.closure() {
			Ok(closure) => Err(Ended(closure))
			Err(NotDone) => Err(Empty)
		}
}

## One read, fed to the protocol.
step! : Client.Conn(b, e) => Try((Client.Conn(b, e), [Progress, TimedOut]), Client.Error(e))
step! = |conn| {
	(link, got) = (conn.transport.read_up_to!)(conn.link, read_size)?
	read = { ..conn, link }
	match got {
		Data(bytes) => {
			done = apply_events!(read, read.protocol.receive(bytes))?
			Ok((done, Progress))
		}
		End => Ok(({ ..read, protocol: read.protocol.ended().0 }, Progress))
		TimedOut => Ok((read, TimedOut))
	}
}

## Write the frames the protocol asked for and keep its messages.
apply_events! : Client.Conn(b, e), (Protocol, List(Protocol.Event)) => Try(Client.Conn(b, e), Client.Error(e))
apply_events! = |conn, (protocol, events)| {
	var $c = { ..conn, protocol }
	for event in events {
		match event {
			Write(frame) => {
				$c = write_frame!($c, frame)?
			}
			Message(m) => {
				$c = { ..$c, inbox: $c.inbox.append(m) }
			}
			Closed(_) => {}
			Ping(_) => {}
			Pong(_) => {}
		}
	}
	Ok($c)
}

## Mask and write one frame.
write_frame! : Client.Conn(b, e), Frame => Try(Client.Conn(b, e), Client.Error(e))
write_frame! = |conn, frame| {
	(link1, key) = (conn.transport.random_bytes!)(conn.link, 4)?
	bytes = match Frame.encode(frame, Masked(key)) {
		Ok(b) => b
		Err(BadMask(n)) => crash "Client: random_bytes!(4) gave ${n.to_str()} bytes"
		Err(ControlTooLong(n)) => return Err(ControlTooLong(n))
		Err(FragmentedControl) => return Err(BadFrame("a fragmented control frame"))
	}
	link2 = (conn.transport.write_bytes!)(link1, bytes)?
	Ok({ ..conn, link: link2 })
}
