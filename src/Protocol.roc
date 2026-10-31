import Frame
import CloseCode
import Ws

## The receiving side of RFC 6455 as a state machine with no I/O: feed it
## bytes, get events. It checks every frame, assembles fragments into
## messages, answers Ping and Close, fails the connection on a protocol error,
## and tracks the closing handshake.
##
## A driver keeps the `Protocol` between reads: it reads any number of
## bytes, calls `receive`, writes each `Write` frame (masked with
## `Protocol.masking` for a client), and acts on the other events. Bytes after
## the last whole frame stay in the state until more arrive.
Protocol :: {
	role : [Client, Server],
	max_message : U64,
	phase : [Open, Closing({ code : U16, reason : Str }), Done(Ws.Closure)],
	pending : List(U8),
	partial : [Idle, Partial({ kind : [Text, Binary], bytes : List(U8) })],
}.{

	## What one call of `receive` produced, in order.
	## - `Message`: a whole message.
	## - `Write`: a frame to send now (a Pong, the Close echo, or the Close that
	##   fails the connection).
	## - `Ping`, `Pong`: a control frame arrived (a Ping is answered by a
	##   `Write` already).
	## - `Closed`: the connection has ended; nothing more follows.
	Event : [Message(Ws.Message), Write(Frame), Ping(List(U8)), Pong(List(U8)), Closed(Ws.Closure)]

	## A protocol in the open state, for an endpoint of `role`, accepting
	## messages of at most `max_message` bytes.
	new : [Client, Server], U64 -> Protocol
	new = |role, max_message| { role, max_message, phase: Open, pending: [], partial: Idle }

	## Whether messages may still be sent: no Close was sent or received.
	is_open : Protocol -> Bool
	is_open = |p| p.phase == Open

	## Whether the connection has ended.
	is_done : Protocol -> Bool
	is_done = |p| match p.phase {
		Done(_) => Bool.True
		_ => Bool.False
	}

	## How the connection ended, once it has.
	closure : Protocol -> Try(Ws.Closure, [NotDone])
	closure = |p| match p.phase {
		Done(c) => Ok(c)
		_ => Err(NotDone)
	}

	## The Close this endpoint sent and is waiting to see answered.
	closing : Protocol -> Try({ code : U16, reason : Str }, [NotClosing])
	closing = |p| match p.phase {
		Closing(sent) => Ok(sent)
		_ => Err(NotClosing)
	}

	## Whether no frame or message is half received.
	is_idle : Protocol -> Bool
	is_idle = |p| p.pending.is_empty() and p.partial == Idle

	## How many bytes the current frame still needs at least. Reading at most
	## this many never reads past the frame. 0 once the connection has ended.
	wanted : Protocol -> U64
	wanted = |p|
		if Protocol.is_done(p) {
			0
		} else {
			match Frame.header(p.pending, expected(p)) {
				Ok(h) => h.size + h.length - p.pending.len()
				Err(Incomplete(n)) => n - p.pending.len()
				Err(Invalid(_)) => 1
			}
		}

	## The masking for a frame this endpoint sends: a client masks with `key`,
	## 4 random bytes; a server does not mask.
	masking : Protocol, List(U8) -> Frame.Masking
	masking = |p, key| match p.role {
		Client => Masked(key)
		Server => Unmasked
	}

	## Feed received bytes, any number of them.
	receive : Protocol, List(U8) -> (Protocol, List(Protocol.Event))
	receive = |p, bytes| {
		var $p = { ..p, pending: p.pending.concat(bytes) }
		var $events = []
		while !Protocol.is_done($p) {
			match Frame.header($p.pending, expected($p)) {
				Err(Incomplete(_)) => break
				Err(Invalid(why)) => {
					(next, failed) = fail_with($p, CloseCode.protocol_error, why)
					$p = next
					$events = $events.concat(failed)
				}
				Ok(h) => {
					so_far = match $p.partial {
						Partial({ bytes: b, .. }) => b.len()
						Idle => 0
					}
					data = !Frame.is_control(h.opcode)
					if data and so_far + h.length > $p.max_message {
						(next, failed) = fail_with($p, CloseCode.too_big, "a message of more than ${$p.max_message.to_str()} bytes")
						$p = next
						$events = $events.concat(failed)
					} else {
						match Frame.decode($p.pending, expected($p)) {
							Ok({ frame, rest }) => {
								(next, produced) = on_frame({ ..$p, pending: rest }, frame)
								$p = next
								$events = $events.concat(produced)
							}
							Err(_) => break
						}
					}
				}
			}
		}
		($p, $events)
	}

	## Start the closing handshake: the Close frame to send. Afterwards
	## `receive` still delivers messages until the peer's Close arrives, which
	## ends the connection with `Closed({ by: Us, .. })`.
	close : Protocol, U16, Str -> Try((Protocol, Frame), [NotOpen, InvalidCode(U16), ReasonTooLong(U64)])
	close = |p, code, reason|
		if p.phase != Open {
			Err(NotOpen)
		} else {
			payload = CloseCode.payload(code, reason)?
			Ok(({ ..p, phase: Closing({ code, reason }) }, close_frame(payload)))
		}

	## Fail the connection (RFC 6455 section 7.1.7): the Close with `code` to
	## send (unless a Close was sent already) and the `Closed` event.
	fail : Protocol, U16, Str -> (Protocol, List(Protocol.Event))
	fail = |p, code, why| fail_with(p, code, why)

	## The received bytes not yet consumed: the start of the next frame.
	pending_bytes : Protocol -> List(U8)
	pending_bytes = |p| p.pending

	## The largest message accepted, in bytes.
	max_message : Protocol -> U64
	max_message = |p| p.max_message

	## Add received bytes without processing them, for a driver that reads
	## raw frames with `take_frame`.
	push : Protocol, List(U8) -> Protocol
	push = |p, bytes| { ..p, pending: p.pending.concat(bytes) }

	## The next whole frame of the received bytes as it is: no assembly, no
	## reply, no state change but removing its bytes.
	take_frame : Protocol -> Try((Protocol, Frame), [Incomplete(U64), Invalid(Str)])
	take_frame = |p| {
		{ frame, rest } = Frame.decode(p.pending, expected(p))?
		Ok(({ ..p, pending: rest }, frame))
	}

	## The transport ended with no Close frame (the peer closed the TCP
	## connection, or a read failed for good): the connection is done, with
	## code 1006.
	ended : Protocol -> (Protocol, Ws.Closure)
	ended = |p| match p.phase {
		Done(c) => (p, c)
		_ => ({ ..p, phase: Done(Ws.dropped), pending: [], partial: Idle }, Ws.dropped)
	}
}

expected : Protocol -> Frame.Expect
expected = |p| match p.role {
	Client => ExpectUnmasked
	Server => ExpectMasked
}

close_frame : List(U8) -> Frame
close_frame = |payload| { fin: Bool.True, opcode: Close, payload }

## Fail the connection (RFC 6455 section 7.1.7): send a Close with `code`
## unless one was sent already, and end.
fail_with : Protocol, U16, Str -> (Protocol, List(Protocol.Event))
fail_with = |p, code, why| {
	reason = clip(why, 123)
	closure = { code, reason, clean: Bool.False, by: Us }
	writes =
		if Protocol.is_open(p) {
			match CloseCode.payload(code, reason) {
				Ok(payload) => [Write(close_frame(payload))]
				Err(_) => crash "Protocol.fail: an invalid close code"
			}
		} else {
			[]
		}
	({ ..p, phase: Done(closure), pending: [], partial: Idle }, writes.append(Closed(closure)))
}

## At most `n` bytes of `text`, cut at a character boundary.
clip : Str, U64 -> Str
clip = |text, n| {
	bytes = text.to_utf8()
	if bytes.len() <= n {
		text
	} else {
		var $cut = n
		var $out = ""
		while $cut > 0 {
			match Str.from_utf8(bytes.take_first($cut)) {
				Ok(s) => {
					$out = s
					break
				}
				Err(_) => {
					$cut = $cut - 1
				}
			}
		}
		$out
	}
}

deliver : Protocol, [Text, Binary], List(U8) -> (Protocol, List(Protocol.Event))
deliver = |p, kind, bytes| {
	idle = { ..p, partial: Idle }
	match kind {
		Binary => (idle, [Message(Binary(bytes))])
		Text =>
			match Str.from_utf8(bytes) {
				Ok(s) => (idle, [Message(Text(s))])
				Err(_) => fail_with(idle, CloseCode.invalid_payload, "a text message that is not UTF-8")
			}
	}
}

on_frame : Protocol, Frame -> (Protocol, List(Protocol.Event))
on_frame = |p, frame| {
	kind_of = |opcode| match opcode {
		Text => Ok(Text)
		Binary => Ok(Binary)
		_ => Err(NotData)
	}
	match frame.opcode {
		Text | Binary =>
			match (p.partial, kind_of(frame.opcode)) {
				(Partial(_), _) => fail_with(p, CloseCode.protocol_error, "a new message before the last one ended")
				(Idle, Ok(kind)) =>
					if frame.fin {
						deliver(p, kind, frame.payload)
					} else {
						({ ..p, partial: Partial({ kind, bytes: frame.payload }) }, [])
					}
				(Idle, Err(NotData)) => crash "Protocol.on_frame: Text or Binary is data"
			}
		Continuation =>
			match p.partial {
				Idle => fail_with(p, CloseCode.protocol_error, "a continuation frame with no message")
				Partial({ kind, bytes }) => {
					all = bytes.concat(frame.payload)
					if frame.fin {
						deliver(p, kind, all)
					} else {
						({ ..p, partial: Partial({ kind, bytes: all }) }, [])
					}
				}
			}
		Ping =>
			if Protocol.is_open(p) {
				(p, [Ping(frame.payload), Write(Frame.pong(frame.payload))])
			} else {
				(p, [Ping(frame.payload)])
			}
		Pong => (p, [Pong(frame.payload)])
		Close =>
			match CloseCode.parse(frame.payload) {
				Err(Invalid({ code, why })) => fail_with(p, code, why)
				Ok({ code, reason, has_code }) => {
					if Protocol.is_open(p) {
						echo = if (has_code) frame.payload.take_first(2) else []
						c = { code, reason, clean: Bool.True, by: Peer }
						({ ..p, phase: Done(c), pending: [], partial: Idle }, [Write(close_frame(echo)), Closed(c)])
					} else {
						c = { code, reason, clean: Bool.True, by: Us }
						({ ..p, phase: Done(c), pending: [], partial: Idle }, [Closed(c)])
					}
				}
			}
	}
}

# ---------------------------------------------------------------- tests

client : Protocol
client = Protocol.new(Client, 1000)

server : Protocol
server = Protocol.new(Server, 1000)

events : Protocol, List(U8) -> List(Protocol.Event)
events = |p, bytes| p.receive(bytes).1

enc : Frame -> List(U8)
enc = |f| Frame.encode(f, Unmasked) ?? []

masked : Frame -> List(U8)
masked = |f| Frame.encode(f, Masked([1, 2, 3, 4])) ?? []

# A whole unmasked "Hello" (RFC 6455 5.7).
expect events(client, [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]) == [Message(Text("Hello"))]
# The masked one, at a server.
expect events(server, [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]) == [Message(Text("Hello"))]
# A server fails a client that does not mask.
expect events(server, [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]) == [Write(close_frame([0x03, 0xEA].concat("a client frame is not masked".to_utf8()))), Closed({ code: 1002, reason: "a client frame is not masked", clean: Bool.False, by: Us })]
# Fragmented "Hel" + "lo", fed one byte at a time.
expect {
	bytes = [0x01, 0x03, 0x48, 0x65, 0x6c, 0x80, 0x02, 0x6c, 0x6f]
	(_, all) = bytes.fold(
		(client, []),
		|(p, acc), b| {
			(next, evs) = p.receive([b])
			(next, acc.concat(evs))
		},
	)
	all == [Message(Text("Hello"))]
}
# A Ping between fragments is answered at once, and the message still assembles.
expect events(client, [0x01, 0x03, 0x48, 0x65, 0x6c, 0x89, 0x01, 0x21, 0x80, 0x02, 0x6c, 0x6f]) == [Ping([0x21]), Write(Frame.pong([0x21])), Message(Text("Hello"))]
# A Pong is reported, not answered.
expect events(client, enc(Frame.pong([7]))) == [Pong([7])]
# Two frames in one read.
expect events(client, enc(Frame.text("a")).concat(enc(Frame.binary([1, 2])))) == [Message(Text("a")), Message(Binary([1, 2]))]
# Partial input waits, and `wanted` says how much more the frame needs.
expect {
	(p, evs) = client.receive([0x82, 0x7E, 0x01])
	evs == [] and p.wanted() == 1 and !p.is_idle()
}
expect {
	(p, _) = client.receive([0x82, 0x7E, 0x01, 0x00])
	p.wanted() == 256
}
expect client.wanted() == 2 and client.is_idle()
# Fragmentation errors.
expect events(client, [0x80, 0x01, 0x41]) == [Write(close_frame([0x03, 0xEA].concat("a continuation frame with no message".to_utf8()))), Closed({ code: 1002, reason: "a continuation frame with no message", clean: Bool.False, by: Us })]
expect events(client, [0x01, 0x01, 0x41, 0x81, 0x01, 0x41]).len() == 2
# Invalid UTF-8 text fails with 1007.
expect events(client, [0x81, 0x01, 0xFF]) == [Write(close_frame([0x03, 0xEF].concat("a text message that is not UTF-8".to_utf8()))), Closed({ code: 1007, reason: "a text message that is not UTF-8", clean: Bool.False, by: Us })]
# UTF-8 split across fragments is fine.
expect events(client, [0x01, 0x01, 0xC3, 0x80, 0x01, 0xA9]) == [Message(Text("é"))]
# Too big: header alone fails with 1009, before the payload arrives.
expect events(Protocol.new(Client, 3), [0x82, 0x04]) == [Write(close_frame([0x03, 0xF1].concat("a message of more than 3 bytes".to_utf8()))), Closed({ code: 1009, reason: "a message of more than 3 bytes", clean: Bool.False, by: Us })]
expect events(Protocol.new(Client, 3), [0x02, 0x02, 1, 2, 0x80, 0x02]).len() == 2
# The peer closes: echo the code, end cleanly.
expect events(client, enc(close_frame([0x03, 0xE8, 98, 121, 101]))) == [Write(close_frame([0x03, 0xE8])), Closed({ code: 1000, reason: "bye", clean: Bool.True, by: Peer })]
expect events(client, enc(close_frame([]))) == [Write(close_frame([])), Closed({ code: 1005, reason: "", clean: Bool.True, by: Peer })]
# Bad close payloads.
expect events(client, enc(close_frame([0x03]))).len() == 2
expect events(client, enc(close_frame([0x03, 0xEE]))) == [Write(close_frame([0x03, 0xEA].concat("the close code 1006 may not be sent".to_utf8()))), Closed({ code: 1002, reason: "the close code 1006 may not be sent", clean: Bool.False, by: Us })]
# We close: messages still arrive, then the peer's echo ends cleanly, by us.
expect
	match client.close(1000, "done") {
		Ok((p, frame)) => {
			(p2, evs) = p.receive(enc(Frame.text("late")).concat(enc(close_frame([0x03, 0xE8]))))
			frame == close_frame([0x03, 0xE8, 100, 111, 110, 101]) and !p.is_open() and evs == [Message(Text("late")), Closed({ code: 1000, reason: "", clean: Bool.True, by: Us })] and p2.is_done() and p2.wanted() == 0
		}
		Err(_) => Bool.False
	}
# No Pong after our Close.
expect
	match client.close(1000, "") {
		Ok((p, _)) => events(p, enc(Frame.ping([1]))) == [Ping([1])]
		Err(_) => Bool.False
	}
expect
	match client.close(1006, "") {
		Err(InvalidCode(1006)) => Bool.True
		_ => Bool.False
	}
# After the end, bytes are ignored.
expect {
	(p, _) = client.receive(enc(close_frame([])))
	events(p, enc(Frame.text("x"))) == []
}
# A server accepts a masked fragmented binary message.
expect events(server, masked({ fin: Bool.False, opcode: Binary, payload: [1] }).concat(masked({ fin: Bool.True, opcode: Continuation, payload: [2] }))) == [Message(Binary([1, 2]))]
expect clip("héllo", 2) == "h"

# Raw frames.
expect
	match client.push([0x89, 0x01, 0x21, 0x81]).take_frame() {
		Ok((p, f)) =>
			f
				== Frame.ping([0x21])
				and (
					match p.take_frame() {
						Err(Incomplete(2)) => Bool.True
						_ => Bool.False
					}
				)
		Err(_) => Bool.False
	}
expect {
	(p, _) = client.receive(enc(close_frame([0x03, 0xE8])))
	p.closure() == Ok({ code: 1000, reason: "", clean: Bool.True, by: Peer }) and p.ended().1 == (p.closure() ?? Ws.dropped)
}
expect
	match client.close(4000, "x") {
		Ok((p, _)) => p.closing() == Ok({ code: 4000, reason: "x" })
		Err(_) => Bool.False
	}
