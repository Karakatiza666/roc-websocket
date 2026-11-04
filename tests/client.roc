app [] { pkg: "../src/main.roc" }

import pkg.Ws
import pkg.Client
import pkg.Frame
import pkg.Handshake
import pkg.Base64

## Client over a scripted link: each read takes the next chunk, so every
## test controls how the server's bytes are split across reads.
Chunk : [Data(List(U8)), End, TimedOut]

Fake : { chunks : List(Chunk), written : List(List(U8)) }

fake_ops : Client.Transport(Fake, [])
fake_ops = {
	write_bytes!: |f, bytes| Ok({ ..f, written: f.written.append(bytes) }),
	read_up_to!: |f, n| match f.chunks {
		[] => Ok((f, End))
		[Data(bytes), .. as rest] =>
			if bytes.len() > n {
				Ok(({ ..f, chunks: [Data(bytes.drop_first(n))].concat(rest) }, Data(bytes.take_first(n))))
			} else {
				Ok(({ ..f, chunks: rest }, Data(bytes)))
			}
		[other, .. as rest] => Ok(({ ..f, chunks: rest }, other))
	},
	random_bytes!: |f, n| Ok((f, List.repeat(7, n))),
}

## A link whose peer answers the handshake and then sends a Ping per read,
## one second of a fake clock each, and never a data message. `until` is the
## adapter-style total deadline kept in the link (the package has no clock of
## its own, so the clock is a counter the link advances).
Pinger : { now : U64, until : [At(U64), None], handshake_done : Bool, reads : U64 }

pinger_ops : Client.Transport(Pinger, [])
pinger_ops = {
	write_bytes!: |p, _| Ok(p),
	read_up_to!: |p, _| {
		if !p.handshake_done {
			return Ok(({ ..p, handshake_done: Bool.True }, Data(response(""))))
		}
		timed_out = match p.until {
			At(t) => p.now >= t
			None => Bool.False
		}
		if timed_out {
			Ok((p, TimedOut))
		} else if p.reads >= 10 {
			Ok((p, End))
		} else {
			Ok(({ ..p, now: p.now + 1000, reads: p.reads + 1 }, Data(server(Frame.ping([1])))))
		}
	},
	random_bytes!: |p, n| Ok((p, List.repeat(7, n))),
}

key : List(U8)
key = List.repeat(7, 16)

response : Str -> List(U8)
response = |protocol| {
	extra = if (protocol == "") "" else "Sec-WebSocket-Protocol: ${protocol}\r\n"
	"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${Handshake.accept_key(Base64.encode(key))}\r\n${extra}\r\n".to_utf8()
}

server : Frame -> List(U8)
server = |f| Frame.encode(f, Unmasked) ?? []

## The frames the client wrote after the handshake, unmasked.
sent : Fake -> List(Frame)
sent = |f| f.written.drop_first(1).map(
	|bytes| match Frame.decode(bytes, ExpectMasked) {
		Ok({ frame, .. }) => frame
		Err(_) => crash "the client wrote a bad frame"
	},
)

open! : List(Chunk) => Client.Conn(Fake, [])
open! = |chunks| match Client.open!(fake_ops, { chunks, written: [] }, { url: "ws://example.com/chat", protocols: ["chat"] }) {
	Ok(opened) => opened.conn
	Err(e) => crash "open failed: ${Str.inspect(e)}"
}

## Whether a result is `Err(Closing)`.
is_closing : Try(x, Client.Error([])) -> Bool
is_closing = |result| match result {
	Err(Closing) => Bool.True
	_ => Bool.False
}

## The closure of a result that is `Err(Closed(_))`.
closed_with : Try(x, Client.Error([])) -> Try(Ws.Closure, [NotClosed])
closed_with = |result| match result {
	Err(Closed(c)) => Ok(c)
	_ => Err(NotClosed)
}

## The value of a result that must be `Ok`. (Used instead of `?`, which hits
## a compiler panic here; see DESIGN.md, section 0.9.)
ok : Try(a, Client.Error([])) -> a
ok = |result| match result {
	Ok(value) => value
	Err(e) => crash "unexpected error: ${Str.inspect(e)}"
}

## Generic over any adapter: a closed record of the two fields it needs, as
## the README shows.
exchange! : { send! : c, Ws.Message => Try(c, Ws.Error(e)), receive! : c => Try((c, Ws.Message), Ws.Error(e)) }, c, Ws.Message => Try((c, Ws.Message), Ws.Error(e))
exchange! = |ws, conn, message| {
	after = (ws.send!)(conn, message)?
	(ws.receive!)(after)
}

check! : Str, Bool => {}
check! = |name, passed|
	if passed {
		echo!("ok   ${name}\n")
	} else {
		crash "FAIL ${name}"
	}

main! = |_args| {
	# The handshake response and two frames arrive in one read.
	c1 = open!([Data(response("chat").concat(server(Frame.text("one"))).concat(server(Frame.binary([2]))))])
	(c2, m1) = ok(c1.receive!())
	(c3, m2) = ok(c2.receive!())
	check!("frames after the head in the same read", m1 == Text("one") and m2 == Binary([2]))
	check!("then the end of the stream", closed_with(c3.receive!()) == Ok(Ws.dropped))

	# A frame split across a timeout loses nothing.
	hello = server(Frame.text("Hello"))
	c4 = open!([Data(response("")), Data(hello.take_first(3)), TimedOut, Data(hello.drop_first(3))])
	(_, m3) = ok(c4.receive!())
	check!("a timeout inside a frame keeps its bytes", m3 == Text("Hello"))

	# poll! reports a timeout between messages as TimedOut, and keeps the state.
	c5 = open!([Data(response("")), TimedOut, Data(server(Frame.text("late")))])
	(c6, first) = ok(c5.poll!())
	(_, second) = ok(c6.poll!())
	check!("poll! gives TimedOut, then the message", first == TimedOut and second == Message(Text("late")))

	# A fragmented message with a Ping between fragments, over three reads.
	c7 = open!([Data(response("")), Data(server({ fin: Bool.False, opcode: Text, payload: "frag".to_utf8() })), Data(server(Frame.ping([9]))), Data(server({ fin: Bool.True, opcode: Continuation, payload: "ments".to_utf8() }))])
	(c8, m4) = ok(c7.receive!())
	check!("fragments assembled across reads", m4 == Text("fragments"))
	check!("the Ping was answered", sent(c8.link()) == [Frame.pong([9])])

	# close! returns at once; receive! delivers what is on its way, then the end.
	c9 = open!([Data(response("")), Data(server(Frame.text("in flight")).concat(server({ fin: Bool.True, opcode: Close, payload: [0x03, 0xE8] })))])
	c10 = ok(c9.close!(1000, "bye"))
	check!("send! after close! is Closing", is_closing(c10.send!(Text("x"))))
	check!("close! after close! is Closing", is_closing(c10.close!(1000, "again")))
	(c11, m5) = ok(c10.receive!())
	check!("a message after close!", m5 == Text("in flight"))
	check!("the closing handshake ends by us", closed_with(c11.receive!()) == Ok({ code: 1000, reason: "", clean: Bool.True, by: Us }))
	check!("close! wrote Close 1000 bye", sent(c10.link()) == [{ fin: Bool.True, opcode: Close, payload: [0x03, 0xE8].concat("bye".to_utf8()) }])

	# The peer closes; later calls keep reporting the same closure.
	c12 = open!([Data(response("")), Data(server({ fin: Bool.True, opcode: Close, payload: [0x0F, 0xA0, 104, 105] }))])
	peer = { code: 4000, reason: "hi", clean: Bool.True, by: Peer }
	check!("closed by the peer", closed_with(c12.receive!()) == Ok(peer))
	match c12.poll!() {
		Err(Closed(again)) => {
			# poll! from the same value reads the Close again; the closure is the same.
			check!("the closure again", again == peer)
		}
		_ => check!("the closure again", Bool.False)
	}

	# The handshake: the client offers no extension, so it reports none.
	match Client.open!(fake_ops, { chunks: [Data(response(""))], written: [] }, { url: "ws://example.com/" }) {
		Ok(opened) => check!("the extensions are reported, none", opened.extensions == Reported([]))
		Err(_) => check!("the extensions are reported, none", Bool.False)
	}

	# Generic code over the ops record: close_and_wait! and drive!.
	c13 = open!([Data(response("")), Data(server(Frame.text("a")).concat(server(Frame.text("b"))).concat(server({ fin: Bool.True, opcode: Close, payload: [0x03, 0xE8] })))])
	ops = Client.ops({})
	handlers = {
		on_open!: |s, c| Ok((s, c)),
		on_message!: |s, c, m| Ok((s.append(m), c)),
		on_close!: |s, _, closure| Ok(s.append(Text("closed ${closure.code.to_str()}"))),
	}
	(seen, drive_end) = Ws.drive!(ops, c13, [], handlers)
	c17 = open!([Data(response("")), Data(server(Frame.text("reply")))])
	(c18, reply) = ok(exchange!({ send!: ops.send!, receive!: ops.receive! }, c17, Text("ask")))
	check!("generic code typed with Ws.Error", reply == Text("reply") and sent(c18.link()) == [Frame.text("ask")])
	c19 = open!([Data(response("")), Data(server(Frame.text("m1")).concat(server({ fin: Bool.True, opcode: Close, payload: [0x03, 0xE8] })))])
	streamed = Stream.collect!(Ws.messages(ops, c19))
	check!("messages ends with the closure", streamed == [Ok(Text("m1")), Err(Closed({ code: 1000, reason: "", clean: Bool.True, by: Peer }))])
	check!("drive! threads the state", seen == [Text("a"), Text("b"), Text("closed 1000")] and ok(drive_end) == { code: 1000, reason: "", clean: Bool.True, by: Peer })

	# The server's last messages and its Close in one read: the echo waits,
	# so replies are sent, and on_close! gets the state and the connection.
	h0 = open!([Data(response("")), Data(server(Frame.text("one")).concat(server(Frame.text("two"))).concat(server({ fin: Bool.True, opcode: Close, payload: [0x03, 0xE8] })))])
	(h1, one) = ok(h0.receive!())
	h2 = ok(h1.send!(one))
	check!("held echo: a reply to a message read with the Close is sent", sent(h2.link()) == [Frame.text("one")])
	echo_handlers = {
		on_open!: |s, c| Ok((s, c)),
		on_message!: |s, c, m| match c.send!(m) {
			Ok(replied) => Ok(({ ..s, count: s.count + 1 }, replied))
			Err(err) => Err(err)
		},
		on_close!: |s, c, closure| Ok({ ..s, replies: sent(c.link()), by: Str.inspect(closure.by) }),
	}
	(held, held_end) = Ws.drive!(ops, h0, { count: 0.U64, replies: [], by: "" }, echo_handlers)
	check!("held echo: drive! replies to each message, then on_close!", held.count == 2 and held.replies == [Frame.text("one"), Frame.text("two")] and held.by == "Peer")
	check!("held echo: drive! ends with the peer's clean close", ok(held_end) == { code: 1000, reason: "", clean: Bool.True, by: Peer })

	# A message over max_message fails the connection with 1009, by us.
	big = match Client.open!(fake_ops, { chunks: [Data(response("").concat(server(Frame.binary([1, 2, 3, 4]))))], written: [] }, { url: "ws://example.com/", max_message: 3 }) {
		Ok(opened) => opened.conn
		Err(e) => crash "open failed: ${Str.inspect(e)}"
	}
	check!("a message over max_message closes with 1009, by us, not clean", closed_with(big.receive!()) == Ok({ code: 1009, reason: "a message of more than 3 bytes", clean: Bool.False, by: Us }))
	c14 = open!([Data(response("")), Data(server(Frame.text("dropped")).concat(server({ fin: Bool.True, opcode: Close, payload: [0x03, 0xE8] })))])
	check!("close_and_wait!", Ws.close_and_wait!(ops, c14, 1000, "") == Ok({ code: 1000, reason: "", clean: Bool.True, by: Us }))
	c15 = open!([Data(response("")), Data(server({ fin: Bool.True, opcode: Close, payload: [0x03, 0xE8] }))])
	c16 = ok(c15.close!(4000, "first"))
	check!("close_and_wait! of a closing connection waits for it", Ws.close_and_wait!(ops, c16, 1000, "") == Ok({ code: 1000, reason: "", clean: Bool.True, by: Us }))

	# Refusals.
	refused = Client.open!(fake_ops, { chunks: [Data("HTTP/1.1 403 Forbidden\r\n\r\n".to_utf8())], written: [] }, { url: "ws://example.com/" })
	check!(
		"a refused upgrade",
		match refused {
			Err(Refused(_)) => Bool.True
			_ => Bool.False
		},
	)
	check!(
		"an invalid close code",
		match c4.close!(1006, "") {
			Err(InvalidClose(_)) => Bool.True
			_ => Bool.False
		},
	)
	check!(
		"a ping over 125 bytes",
		match c4.ping!(List.repeat(0, 126)) {
			Err(ControlTooLong(126)) => Bool.True
			_ => Bool.False
		},
	)
	# map_link changes only the link: the connection still works over it.
	ml0 = open!([Data(response(""))])
	ml1 = ml0.map_link(|f| { ..f, chunks: [Data(server(Frame.text("late")))] })
	(ml2, late) = ok(ml1.receive!())
	ml3 = ml2.map_link(|f| { ..f, written: f.written.append([]) })
	check!("map_link changes the link and keeps the connection", late == Text("late") and ml3.link().written.len() == 2)
	# A deadline kept in the link bounds the whole call: Ping frames count as
	# progress for poll!, but the link's read gives TimedOut once the (fake)
	# clock passes the deadline, so poll! gives TimedOut after three pings.
	# This is how an adapter implements Ws.ReceiveWithin (map_link, poll!, map_link).
	pinger = match Client.open!(pinger_ops, { now: 0, until: None, handshake_done: Bool.False, reads: 0 }, { url: "ws://example.com/" }) {
		Ok(opened) => opened.conn
		Err(e) => crash "open failed: ${Str.inspect(e)}"
	}
	limited = pinger.map_link(|p| { ..p, until: At(p.now + 3000) })
	(after_limit, timed) = ok(limited.poll!())
	check!("a link deadline gives TimedOut though Pings keep arriving", timed == TimedOut and after_limit.link().now == 3000)
	check!("the call made three reads, one per Ping", after_limit.link().reads == 3)
	# Without the deadline, the pings never produce a TimedOut: poll! runs to the end of the stream.
	check!("without the deadline, Pings are progress and poll! does not time out", closed_with(pinger.poll!()) == Ok(Ws.dropped))
	(_, raw) = ok(open!([Data(response("")), Data(server(Frame.pong([5])))]).receive_frame!())
	check!("receive_frame! gives a Pong", raw == Frame.pong([5]))
	Ok({})
}
