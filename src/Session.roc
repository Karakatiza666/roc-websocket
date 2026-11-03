import Ws
import Frame
import Protocol

## Frame I/O over a byte link after the opening handshake, for either role.
## `Client.Conn` and `Server.Conn` each hold one and forward their methods to
## it. Not exposed by the package.
##
## The roles differ only in `mask!` (a client masks each frame it sends with 4
## random bytes, a server does not mask) and in the `Protocol`'s role, which
## sets the masking a received frame must have.
##
## The peer's Close is answered once the messages read with it are delivered:
## when one read brings messages and the Close, the echo is held (`held`)
## until a call finds the inbox empty, so replies to those messages are sent
## before it (RFC 6455 section 5.5.1 lets an endpoint delay its echo).
Session(b, e) :: {
	bytes : Ws.Bytes(b, Session.Errors(e), {}),
	mask! : b => Try((b, Frame.Masking), Ws.Error(Session.Errors(e))),
	link : b,
	protocol : Protocol,
	inbox : List(Ws.Message),
	held : List(Frame),
}.{

	## The tags frame I/O adds to the row `e` of its role.
	Errors(e) : [InvalidClose(Str), ControlTooLong(U64), BadFrame(Str), ..e]

	## Every error of a session call.
	Error(e) : Ws.Error(Session.Errors(e))

	## A session over a link the handshake has just finished on, fed the
	## bytes read after the handshake head. The frames those bytes provoke (a
	## Pong, a Close) are written.
	start! : Ws.Bytes(b, Session.Errors(e), {}), (b => Try((b, Frame.Masking), Session.Error(e))), b, Protocol, List(U8) => Try(Session(b, e), Session.Error(e))
	start! = |bytes, mask!, link, protocol, rest| {
		session = { bytes: bytes, mask!: mask!, link: link, protocol: protocol, inbox: [], held: [] }
		apply_events!(session, protocol.receive(rest))
	}

	## The link value as the last call left it.
	link : Session(b, e) -> b
	link = |s| s.link

	## The same session with its link value changed by `change`.
	map_link : Session(b, e), (b -> b) -> Session(b, e)
	map_link = |s, change| { ..s, link: change(s.link) }

	send! : Session(b, e), Ws.Message => Try(Session(b, e), Session.Error(e))
	send! = |s, message| {
		usable(s)?
		write_frame!(
			s,
			match message {
				Text(t) => Frame.text(t)
				Binary(b) => Frame.binary(b)
			},
		)
	}

	receive! : Session(b, e) => Try((Session(b, e), Ws.Message), Session.Error(e))
	receive! = |s| {
		var $s = release!(s)?
		while Bool.True {
			match next_ready($s) {
				Ok((ready, m)) => return Ok((ready, m))
				Err(Ended(closure)) => return Err(Closed(closure))
				Err(Empty) => {}
			}
			(after, _) = step!($s)?
			$s = after
		}
	}

	poll! : Session(b, e) => Try((Session(b, e), [Message(Ws.Message), TimedOut]), Session.Error(e))
	poll! = |s| {
		var $s = release!(s)?
		while Bool.True {
			match next_ready($s) {
				Ok((ready, m)) => return Ok((ready, Message(m)))
				Err(Ended(closure)) => return Err(Closed(closure))
				Err(Empty) => {}
			}
			(after, progress) = step!($s)?
			if progress == TimedOut {
				return Ok((after, TimedOut))
			}
			$s = after
		}
	}

	close! : Session(b, e), U16, Str => Try(Session(b, e), Session.Error(e))
	close! = |s, code, reason| {
		if !s.held.is_empty() {
			# The peer has closed: the held echo is the answer.
			return write_held!(s)
		}
		usable(s)?
		match s.protocol.close(code, reason) {
			Ok((protocol, frame)) => write_frame!({ ..s, protocol }, frame)
			Err(InvalidCode(c)) => Err(InvalidClose("the close code ${c.to_str()} may not be sent"))
			Err(ReasonTooLong(n)) => Err(InvalidClose("a close reason of ${n.to_str()} bytes; at most 123"))
			Err(NotOpen) => crash "Session.close!: usable checked that the connection is open"
		}
	}

	ping! : Session(b, e), List(U8) => Try(Session(b, e), Session.Error(e))
	ping! = |s, payload| {
		usable(s)?
		write_frame!(s, Frame.ping(payload))
	}

	pong! : Session(b, e), List(U8) => Try(Session(b, e), Session.Error(e))
	pong! = |s, payload| {
		usable(s)?
		write_frame!(s, Frame.pong(payload))
	}

	send_frame! : Session(b, e), Frame => Try(Session(b, e), Session.Error(e))
	send_frame! = |s, frame| {
		usable(s)?
		write_frame!(s, frame)
	}

	receive_frame! : Session(b, e) => Try((Session(b, e), Frame), Session.Error(e))
	receive_frame! = |s| {
		var $s = release!(s)?
		while Bool.True {
			match $s.protocol.closure() {
				Ok(closure) => return Err(Closed(closure))
				Err(NotDone) => {}
			}
			match $s.protocol.take_frame() {
				Ok((protocol, frame)) => return Ok(({ ..$s, protocol }, frame))
				Err(Invalid(why)) => {
					$s = apply_events!($s, $s.protocol.fail(1002, why))?
				}
				Err(Incomplete(_)) => {
					max = $s.protocol.max_message()
					too_big = match Frame.header($s.protocol.pending_bytes(), $s.protocol.expects()) {
						Ok(h) => h.length > max
						Err(_) => Bool.False
					}
					if too_big {
						$s = apply_events!($s, $s.protocol.fail(1009, "a frame of more than ${max.to_str()} bytes"))?
					} else {
						(after, got) = ($s.bytes.read_up_to!)($s.link, read_size)?
						match got {
							Data(bytes) => {
								$s = { ..$s, link: after, protocol: $s.protocol.push(bytes) }
							}
							End => {
								$s = { ..$s, link: after, protocol: $s.protocol.ended().0 }
							}
							TimedOut => {
								$s = { ..$s, link: after }
							}
						}
					}
				}
			}
		}
	}

	## The largest message accepted when the request or the options do not
	## say: 16 MiB.
	default_max_message : U64
	default_max_message = 16 * 1024 * 1024
}

## The bytes asked for in one read.
read_size : U64
read_size = 65536

## Fail when the connection has ended or this endpoint already sent Close.
## While the echo of the peer's Close is held, sending is still allowed.
usable : Session(b, e) -> Try({}, Session.Error(e))
usable = |s| if (!s.held.is_empty()) Ok({}) else match s.protocol.closure() {
	Ok(closure) => Err(Closed(closure))
	Err(NotDone) =>
		match s.protocol.closing() {
			Ok(_) => Err(Closing)
			Err(NotClosing) => Ok({})
		}
}

## A message already received, or why there is none.
next_ready : Session(b, e) -> Try((Session(b, e), Ws.Message), [Ended(Ws.Closure), Empty])
next_ready = |s| match s.inbox {
	[m, .. as rest] => Ok(({ ..s, inbox: rest }, m))
	[] =>
		match s.protocol.closure() {
			Ok(closure) => Err(Ended(closure))
			Err(NotDone) => Err(Empty)
		}
}

## One read, fed to the protocol.
step! : Session(b, e) => Try((Session(b, e), [Progress, TimedOut]), Session.Error(e))
step! = |s| {
	(link, got) = (s.bytes.read_up_to!)(s.link, read_size)?
	read = { ..s, link }
	match got {
		Data(bytes) => {
			done = apply_events!(read, read.protocol.receive(bytes))?
			Ok((done, Progress))
		}
		End => Ok(({ ..read, protocol: read.protocol.ended().0 }, Progress))
		TimedOut => Ok((read, TimedOut))
	}
}

## Write the frames the protocol asked for and keep its messages. The echo
## of the peer's Close is held while messages wait in the inbox.
apply_events! : Session(b, e), (Protocol, List(Protocol.Event)) => Try(Session(b, e), Session.Error(e))
apply_events! = |s, (protocol, events)| {
	var $s = { ..s, protocol }
	by_peer = match protocol.closure() {
		Ok(c) => c.by == Peer
		Err(NotDone) => Bool.False
	}
	for event in events {
		match event {
			Write(frame) =>
				if by_peer and frame.opcode == Close and !$s.inbox.is_empty() {
					$s = { ..$s, held: $s.held.append(frame) }
				} else {
					$s = write_frame!($s, frame)?
				}
			Message(m) => {
				$s = { ..$s, inbox: $s.inbox.append(m) }
			}
			Closed(_) => {}
			Ping(_) => {}
			Pong(_) => {}
		}
	}
	Ok($s)
}

## Write the held echo once the inbox is empty.
release! : Session(b, e) => Try(Session(b, e), Session.Error(e))
release! = |s| if (s.held.is_empty() or !s.inbox.is_empty()) Ok(s) else write_held!(s)

## Write the held echo now.
write_held! : Session(b, e) => Try(Session(b, e), Session.Error(e))
write_held! = |s| {
	var $s = { ..s, held: [] }
	for frame in s.held {
		$s = write_frame!($s, frame)?
	}
	Ok($s)
}

## Write one frame, masked as `mask!` says.
write_frame! : Session(b, e), Frame => Try(Session(b, e), Session.Error(e))
write_frame! = |s, frame| {
	(link1, masking) = (s.mask!)(s.link)?
	bytes = match Frame.encode(frame, masking) {
		Ok(b) => b
		Err(BadMask(n)) => crash "Session: a masking key of ${n.to_str()} bytes, not 4"
		Err(ControlTooLong(n)) => return Err(ControlTooLong(n))
		Err(FragmentedControl) => return Err(BadFrame("a fragmented control frame"))
	}
	link2 = (s.bytes.write_bytes!)(link1, bytes)?
	Ok({ ..s, link: link2 })
}
