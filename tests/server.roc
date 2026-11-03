app [] { pkg: "../src/main.roc" }

import pkg.Ws
import pkg.Client
import pkg.Server
import pkg.Frame
import pkg.Handshake

## The server over a scripted link: each read takes the next chunk, so every
## test controls how the client's bytes are split across reads. `asked` keeps
## the size of each read, to check that the request read is bounded.
Chunk : [Data(List(U8)), End, TimedOut]

Fake : { chunks : List(Chunk), written : List(List(U8)), asked : List(U64), fail_writes : Bool }

fake : List(Chunk) -> Fake
fake = |chunks| { chunks, written: [], asked: [], fail_writes: Bool.False }

## What a write gave when the link was set to fail its writes: a test sees
## the bytes of a call that ends in an error (a refusal before `NotUpgrade`,
## a Close before `Closed`), since an error drops the connection value.
Wrote : { bytes : List(U8), asked : List(U64) }

## Every error in these tests.
E : Server.Error([Wrote(Wrote)])

fake_ops : Server.Transport(Fake, [Wrote(Wrote)])
fake_ops = {
	write_bytes!: |f, bytes|
		if f.fail_writes {
			Err(Wrote({ bytes, asked: f.asked }))
		} else {
			Ok({ ..f, written: f.written.append(bytes) })
		},
	read_up_to!: |f0, n| {
		f = { ..f0, asked: f0.asked.append(n) }
		match f.chunks {
			[] => Ok((f, End))
			[Data(bytes), .. as rest] =>
				if bytes.len() > n {
					Ok(({ ..f, chunks: [Data(bytes.drop_first(n))].concat(rest) }, Data(bytes.take_first(n))))
				} else {
					Ok(({ ..f, chunks: rest }, Data(bytes)))
				}
			[other, .. as rest] => Ok(({ ..f, chunks: rest }, other))
		}
	},
}

## What `read_request!` wrote before failing, or how it failed with nothing
## written.
refused_with! : List(Chunk) => [Wrote(Wrote), NotUpgrade(Str), Other]
refused_with! = |chunks| match Server.read_request!(fake_ops, { ..fake(chunks), fail_writes: Bool.True }) {
	Err(Wrote(w)) => Wrote(w)
	Err(NotUpgrade(why)) => NotUpgrade(why)
	_ => Other
}

## The text a refusal wrote.
refusal_text : [Wrote(Wrote), NotUpgrade(Str), Other] -> Str
refusal_text = |result| match result {
	Wrote(w) => Str.from_utf8(w.bytes) ?? "not UTF-8"
	_ => "nothing written"
}

## The status line of a refusal that was written.
status_line : [Wrote(Wrote), NotUpgrade(Str), Other] -> Str
status_line = |result| {
	text = refusal_text(result)
	text.split_first("\r\n").map_ok(|parts| parts.before) ?? text
}

## The frame a call wrote before it ended, read as a client reads it
## (unmasked), with the link set to fail its writes.
wrote_frame : Try(x, E) -> Try(Frame, [NoFrame])
wrote_frame = |result| match result {
	Err(Wrote(w)) =>
		match Frame.decode(w.bytes, ExpectUnmasked) {
			Ok({ frame, .. }) => Ok(frame)
			Err(_) => Err(NoFrame)
		}
	_ => Err(NoFrame)
}

key : Str
key = "dGhlIHNhbXBsZSBub25jZQ=="

## An upgrade request with `extra` header lines.
request_text : Str -> Str
request_text = |extra| "GET /chat HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n${extra}\r\n"

request : Str -> List(U8)
request = |extra| request_text(extra).to_utf8()

## A frame as a client sends it, masked.
client : Frame -> List(U8)
client = |f| Frame.encode(f, Masked([1, 2, 3, 4])) ?? []

close_frame : List(U8) -> Frame
close_frame = |payload| { fin: Bool.True, opcode: Close, payload }

## The frames the server wrote after its 101 response, read as a client
## reads them: unmasked, or the decode fails.
sent : Fake -> List(Frame)
sent = |f| f.written.drop_first(1).map(
	|bytes| match Frame.decode(bytes, ExpectUnmasked) {
		Ok({ frame, .. }) => frame
		Err(_) => crash "the server wrote a frame that is masked or bad"
	},
)

## The first thing the server wrote, as text.
first_written : Fake -> Str
first_written = |f| Str.from_utf8(f.written.first() ?? []) ?? "not UTF-8"

accept! : List(Chunk), Ws.AcceptOptions => Ws.Opened(Server.Conn(Fake, [Wrote(Wrote)]))
accept! = |chunks, options| match Server.accept!(fake_ops, fake(chunks), options) {
	Ok(opened) => opened
	Err(e) => crash "accept failed: ${Str.inspect(e)}"
}

## The connection after a request with `chunks` of frames behind it.
conn! : List(Chunk) => Server.Conn(Fake, [Wrote(Wrote)])
conn! = |chunks| accept!([Data(request(""))].concat(chunks), {}).conn

## The value of a result that must be `Ok`. (Used instead of `?`, which hits
## a compiler panic in an app with a closed error row; see DESIGN.md, section
## 0.9.)
ok : Try(a, E) -> a
ok = |result| match result {
	Ok(value) => value
	Err(e) => crash "unexpected error: ${Str.inspect(e)}"
}

closed_with : Try(x, E) -> Try(Ws.Closure, [NotClosed])
closed_with = |result| match result {
	Err(Closed(c)) => Ok(c)
	_ => Err(NotClosed)
}

is_closing : Try(x, E) -> Bool
is_closing = |result| match result {
	Err(Closing) => Bool.True
	_ => Bool.False
}

check! : Str, Bool => {}
check! = |name, passed|
	if passed {
		echo!("ok   ${name}\n")
	} else {
		crash "FAIL ${name}"
	}

# ------------------------------------------------ a client and a server in memory

## One end of an in-memory stream: the bytes not read yet, and the bytes
## written. A read with nothing to read gives `TimedOut`, consuming nothing.
Pipe : { incoming : List(U8), written : List(U8), fail_writes : Bool }

pipe_ops : Server.Transport(Pipe, [Wrote(Wrote)])
pipe_ops = {
	write_bytes!: |p, bytes|
		if p.fail_writes {
			Err(Wrote({ bytes, asked: [] }))
		} else {
			Ok({ ..p, written: p.written.concat(bytes) })
		},
	read_up_to!: |p, n|
		if p.incoming.is_empty() {
			Ok((p, TimedOut))
		} else {
			Ok(({ ..p, incoming: p.incoming.drop_first(n) }, Data(p.incoming.take_first(n))))
		},
}

## The client's end. The server lives in it during the handshake: the
## client's first read with nothing to read runs `Server.accept!` on what the
## client wrote, so `Client.open!` reads the server's own answer.
ClientLink : { incoming : List(U8), written : List(U8), fail_writes : Bool, server : [Waiting, Accepted(Ws.Opened(Server.Conn(Pipe, [Wrote(Wrote)]))), Taken] }

client_ops : Client.Transport(ClientLink, [Wrote(Wrote)])
client_ops = {
	write_bytes!: |l, bytes|
		if l.fail_writes {
			Err(Wrote({ bytes, asked: [] }))
		} else {
			Ok({ ..l, written: l.written.concat(bytes) })
		},
	read_up_to!: |l, n|
		if !l.incoming.is_empty() {
			Ok(({ ..l, incoming: l.incoming.drop_first(n) }, Data(l.incoming.take_first(n))))
		} else {
			match l.server {
				Waiting =>
					match Server.accept!(pipe_ops, { incoming: l.written, written: [], fail_writes: Bool.False }, { protocols: ["superchat"] }) {
						Ok(opened) => {
							answer = opened.conn.link().written
							conn = opened.conn.map_link(|p| { ..p, written: [] })
							Ok(({ incoming: answer.drop_first(n), written: [], fail_writes: Bool.False, server: Accepted({ ..opened, conn }) }, Data(answer.take_first(n))))
						}
						Err(e) => crash "the server refused: ${Str.inspect(e)}"
					}
				_ => Ok((l, TimedOut))
			}
		},
	random_bytes!: |l, n| Ok((l, List.repeat(7, n))),
}

ClientConn : Client.Conn(ClientLink, [Wrote(Wrote)])

ServerConn : Server.Conn(Pipe, [Wrote(Wrote)])

## Move what the client wrote to the server.
to_server : ClientConn, ServerConn -> (ClientConn, ServerConn)
to_server = |c, s| {
	bytes = c.link().written
	(c.map_link(|l| { ..l, written: [] }), s.map_link(|p| { ..p, incoming: p.incoming.concat(bytes) }))
}

## Move what the server wrote to the client.
to_client : ServerConn, ClientConn -> (ServerConn, ClientConn)
to_client = |s, c| {
	bytes = s.link().written
	(s.map_link(|p| { ..p, written: [] }), c.map_link(|l| { ..l, incoming: l.incoming.concat(bytes) }))
}

client_ok : Try(a, Client.Error([Wrote(Wrote)])) -> a
client_ok = |result| match result {
	Ok(value) => value
	Err(e) => crash "unexpected client error: ${Str.inspect(e)}"
}

client_closed_with : Try(x, Client.Error([Wrote(Wrote)])) -> Try(Ws.Closure, [NotClosed])
client_closed_with = |result| match result {
	Err(Closed(c)) => Ok(c)
	_ => Err(NotClosed)
}

## Open a client offering `protocols`, and take the server's half out of its
## link.
handshake! : List(Str) => (Ws.Opened(ClientConn), Ws.Opened(ServerConn))
handshake! = |protocols| {
	opened = client_ok(Client.open!(client_ops, { incoming: [], written: [], fail_writes: Bool.False, server: Waiting }, { url: "ws://example.com/chat", protocols }))
	match opened.conn.link().server {
		Accepted(server) => ({ ..opened, conn: opened.conn.map_link(|l| { ..l, server: Taken }) }, server)
		_ => crash "the server did not accept"
	}
}

## A whole exchange: the handshake, a message each way, a Ping from the
## server, and a close by the client.
client_closes! : {} => {}
client_closes! = |{}| {
	(client_side, server_side) = handshake!(["chat", "superchat"])
	check!("in memory: both ends agree on the subprotocol", client_side.protocol == "superchat" and server_side.protocol == "superchat")
	check!("in memory: no extensions at either end", client_side.extensions == Reported([]) and server_side.extensions == Reported([]))

	c1 = client_ok(client_side.conn.send!(Text("hello")))
	(c2, s1) = to_server(c1, server_side.conn)
	(s2, heard) = ok(s1.receive!())
	s3 = ok(s2.send!(Binary([1, 2, 3])))
	(s4, c3) = to_client(s3, c2)
	(c4, answer) = client_ok(c3.receive!())
	check!("in memory: a message each way", heard == Text("hello") and answer == Binary([1, 2, 3]))

	s5 = ok(s4.ping!([42]))
	(s6, c5) = to_client(s5, c4)
	(c6, idle) = client_ok(c5.poll!())
	(c7, s7) = to_server(c6, s6)
	(s8, pong) = ok(s7.receive_frame!())
	check!("in memory: the client answers the server's Ping", idle == TimedOut and pong == Frame.pong([42]))

	c8 = client_ok(c7.close!(1000, "bye"))
	(c9, s9) = to_server(c8, s8)
	check!("in memory: a close by the client, at the server", closed_with(s9.receive!()) == Ok({ code: 1000, reason: "bye", clean: Bool.True, by: Peer }))
	# That receive! wrote the echo; read the same bytes again with writes
	# failing, to carry the echo to the client.
	echo = match s9.map_link(|p| { ..p, fail_writes: Bool.True }).receive!() {
		Err(Wrote(w)) => w.bytes
		_ => crash "the server did not echo the Close"
	}
	c10 = c9.map_link(|l| { ..l, incoming: l.incoming.concat(echo) })
	check!("in memory: a close by the client, at the client", client_closed_with(c10.receive!()) == Ok({ code: 1000, reason: "", clean: Bool.True, by: Us }))
}

## The server closes; the client answers.
server_closes! : {} => {}
server_closes! = |{}| {
	(client_side, server_side) = handshake!([])
	check!("in memory: no subprotocol when none is offered", client_side.protocol == "" and server_side.protocol == "")
	s1 = ok(server_side.conn.close!(1001, "restart"))
	(s2, c1) = to_client(s1, client_side.conn)
	check!("in memory: a close by the server, at the client", client_closed_with(c1.receive!()) == Ok({ code: 1001, reason: "restart", clean: Bool.True, by: Peer }))
	# The client's echo, read again with writes failing, as above.
	echo = match c1.map_link(|l| { ..l, fail_writes: Bool.True }).receive!() {
		Err(Wrote(w)) => w.bytes
		_ => crash "the client did not echo the Close"
	}
	s3 = s2.map_link(|p| { ..p, incoming: p.incoming.concat(echo) })
	check!("in memory: a close by the server, at the server", closed_with(s3.receive!()) == Ok({ code: 1001, reason: "", clean: Bool.True, by: Us }))
}

main! = |_args| {
	# The request split across three reads, the end of the head split between
	# two, and the first frame in the same read as the end of the head.
	whole = request("")
	cut = whole.len() - 2
	o1 = accept!([Data(whole.take_first(20)), Data(whole.sublist({ start: 20, len: cut - 20 })), Data(whole.drop_first(cut).concat(client(Frame.text("early"))))], {})
	check!("a split request is read", first_written(o1.conn.link()).starts_with("HTTP/1.1 101 Switching Protocols\r\n"))
	check!("the 101 has the accept key", first_written(o1.conn.link()).contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
	check!("each read asks for at most what the head may still hold", o1.conn.link().asked == [16384, 16364, 16384 - cut])
	(o1c, early) = ok(o1.conn.receive!())
	check!("a frame behind the head, in the same read, is kept", early == Text("early"))
	check!("then the end of the stream", closed_with(o1c.receive!()) == Ok(Ws.dropped))

	# A head that never ends is cut at max_request_head and answered with 431.
	huge = refused_with!([Data("GET / HTTP/1.1\r\nX: ${Str.repeat("a", 20000)}".to_utf8())])
	check!("a head over max_request_head is answered with 431", status_line(huge) == "HTTP/1.1 431 Request Header Fields Too Large")
	check!(
		"and no more than max_request_head bytes are read",
		match huge {
			Wrote(w) => w.asked.sum() == Server.max_request_head
			_ => Bool.False
		},
	)
	check!(
		"which is NotUpgrade",
		match Server.read_request!(fake_ops, fake([Data(Str.repeat("a", 20000).to_utf8())])) {
			Err(NotUpgrade(why)) => why == "a request head of more than 16384 bytes"
			_ => Bool.False
		},
	)

	# Bad upgrades are answered, then NotUpgrade.
	check!("a POST is answered with 405", status_line(refused_with!([Data(request_text("").replace_first("GET", "POST").to_utf8())])) == "HTTP/1.1 405 Method Not Allowed")
	old = refused_with!([Data(request_text("").replace_first("Version: 13", "Version: 8").to_utf8())])
	check!(
		"a version other than 13 is answered with 426 and the version",
		match old {
			Wrote(_) => refusal_text(old).starts_with("HTTP/1.1 426 Upgrade Required\r\nSec-WebSocket-Version: 13\r\n")
			_ => Bool.False
		},
	)
	check!("no Upgrade header is answered with 400", status_line(refused_with!([Data(request_text("").replace_first("Upgrade: websocket\r\n", "").to_utf8())])) == "HTTP/1.1 400 Bad Request")
	check!("a head that is not UTF-8 is answered with 400", status_line(refused_with!([Data([0xFF, 13, 10, 13, 10])])) == "HTTP/1.1 400 Bad Request")
	check!(
		"a bad upgrade is NotUpgrade",
		match Server.accept!(fake_ops, fake([Data(request_text("").replace_first("GET", "POST").to_utf8())]), {}) {
			Err(NotUpgrade(why)) => why == "the method is POST, not GET"
			_ => Bool.False
		},
	)
	check!(
		"the stream ending before the head is NotUpgrade, nothing written",
		match refused_with!([Data(whole.take_first(10)), End]) {
			NotUpgrade(_) => Bool.True
			_ => Bool.False
		},
	)
	check!(
		"a deadline before the head is NotUpgrade, nothing written",
		match refused_with!([TimedOut]) {
			NotUpgrade(_) => Bool.True
			_ => Bool.False
		},
	)

	# The application looks at the request and refuses it.
	pending = ok(Server.read_request!(fake_ops, fake([Data(request("Sec-WebSocket-Protocol: chat, superchat\r\n"))])))
	check!("the request is readable before answering", pending.upgrade().resource == "/chat" and pending.upgrade().protocols == ["chat", "superchat"])
	check!(
		"a refusal status outside 400-599 is InvalidStatus",
		match pending.refuse!({ status: 200 }) {
			Err(InvalidStatus(200)) => Bool.True
			_ => Bool.False
		},
	)
	refused_link = ok(pending.refuse!({ status: 403, headers: [("X-Why", "test")], body: "no" }))
	check!("a refusal writes its status, headers and body", refused_link.written == [Handshake.refusal(403, [("X-Why", "test")], "no").to_utf8()])
	check!("a refusal starts with 403 Forbidden", first_written(refused_link).starts_with("HTTP/1.1 403 Forbidden\r\nX-Why: test\r\n"))

	# The subprotocol: the first of the client's offer that the server has.
	offered = Data(request("Sec-WebSocket-Protocol: chat, superchat\r\n"))
	chose = accept!([offered], { protocols: ["superchat", "other"] })
	check!("the server chooses an offered subprotocol", chose.protocol == "superchat" and first_written(chose.conn.link()).contains("\r\nSec-WebSocket-Protocol: superchat\r\n"))
	none = accept!([offered], { protocols: ["other"] })
	check!("none in common: no subprotocol, still accepted", none.protocol == "" and !first_written(none.conn.link()).contains("Sec-WebSocket-Protocol"))
	own = ok(Server.read_request!(fake_ops, fake([offered])))
	own_choice = own.upgrade().protocols.last() ?? ""
	check!("a choice of the application's own", ok(own.accept!({ protocols: [own_choice] })).protocol == "superchat")

	# Extensions are refused by leaving them out of the 101.
	ext = accept!([Data(request("Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n"))], {})
	check!("an offered extension is not accepted", ext.extensions == Reported([]) and !first_written(ext.conn.link()).contains("Extensions"))

	# A client frame without a mask fails the connection with 1002.
	bad = conn!([Data(Frame.encode(Frame.text("plain"), Unmasked) ?? [])])
	check!("an unmasked client frame fails with 1002", closed_with(bad.receive!()) == Ok({ code: 1002, reason: "a client frame is not masked", clean: Bool.False, by: Us }))
	check!("and the server writes Close 1002, unmasked", wrote_frame(bad.map_link(|f| { ..f, fail_writes: Bool.True }).receive!()) == Ok(close_frame([0x03, 0xEA].concat("a client frame is not masked".to_utf8()))))

	# Ping and Pong: the server answers a Ping unmasked, and sends its own.
	p1 = conn!([Data(client(Frame.ping([9])).concat(client(Frame.text("after"))))])
	(p2, after_ping) = ok(p1.receive!())
	check!("the server answers a Ping with an unmasked Pong", after_ping == Text("after") and sent(p2.link()) == [Frame.pong([9])])
	p3 = ok(p2.ping!([1, 2]))
	p4 = ok(p3.pong!([3]))
	check!("ping! and pong! write unmasked frames", sent(p4.link()) == [Frame.pong([9]), Frame.ping([1, 2]), Frame.pong([3])])
	check!(
		"a Pong is read with receive_frame!",
		match conn!([Data(client(Frame.pong([5])))]).receive_frame!() {
			Ok((_, f)) => f == Frame.pong([5])
			Err(_) => Bool.False
		},
	)

	# The client closes.
	k1 = conn!([Data(client(close_frame([0x03, 0xE8, 98, 121, 101])))])
	check!("a close by the client ends by the peer", closed_with(k1.receive!()) == Ok({ code: 1000, reason: "bye", clean: Bool.True, by: Peer }))
	check!("and the server echoes the code, unmasked", wrote_frame(k1.map_link(|f| { ..f, fail_writes: Bool.True }).receive!()) == Ok(close_frame([0x03, 0xE8])))
	# A message in the same read as the client's Close is delivered, but the
	# Messages read with the client's Close: the echo waits until they are
	# delivered, so replies to them go out first.
	e0 = conn!([Data(client(Frame.text("one")).concat(client(Frame.text("two"))).concat(client(close_frame([0x03, 0xE8]))))])
	check!("the echo is held while messages read with the Close wait", sent(e0.link()) == [])
	(e1, first) = ok(e0.receive!())
	e2 = ok(e1.send!(first))
	(e3, second) = ok(e2.receive!())
	e4 = ok(e3.send!(second))
	check!("messages read with the client's Close are delivered, and replies to them are sent", first == Text("one") and second == Text("two") and sent(e4.link()) == [Frame.text("one"), Frame.text("two")])
	check!("then the next receive! echoes the Close and ends by the peer", closed_with(e4.receive!()) == Ok({ code: 1000, reason: "", clean: Bool.True, by: Peer }))
	check!("the echo is written after the replies", wrote_frame(e4.map_link(|f| { ..f, fail_writes: Bool.True }).receive!()) == Ok(close_frame([0x03, 0xE8])))
	(e5, _) = ok(conn!([Data(client(Frame.text("one")).concat(client(close_frame([0x03, 0xE8]))))]).receive!())
	check!("close! while the echo is held writes the echo", sent(ok(e5.close!(1000, "")).link()) == [close_frame([0x03, 0xE8])])
	d0 = conn!([Data(client(Frame.text("a")).concat(client(close_frame([0x03, 0xE8]))))])
	echo_handlers = {
		on_open!: |n, c| Ok((n, c)),
		on_message!: |n, c, m| match c.send!(m) {
			Ok(c2) => Ok((n + 1, c2))
			Err(err) => Err(err)
		},
		on_close!: |n, _| Ok(n),
	}
	# A message and then an unmasked frame in one read: the message is
	# delivered, the connection has failed with 1002, so a reply is Closed;
	# drive! still reaches on_close! with that closure.
	failed! = |{}| conn!([Data(client(Frame.text("a")).concat(Frame.encode(Frame.text("b"), Unmasked) ?? []))])
	(x1, _) = ok(failed!({}).receive!())
	check!("a reply after the connection failed is Closed", closed_with(x1.send!(Text("a"))) == Ok({ code: 1002, reason: "a client frame is not masked", clean: Bool.False, by: Us }))
	codes_handlers = {
		on_open!: |n, c| Ok((n, c)),
		on_message!: |n, c, m| match c.send!(m) {
			Ok(c2) => Ok((n, c2))
			Err(err) => Err(err)
		},
		on_close!: |_, closure| Ok(closure.code),
	}
	check!("Ws.drive! reaches on_close! after a handler's Closed", ok(Ws.drive!(Server.ops({}), failed!({}), 0.U16, codes_handlers)) == 1002)
	check!("Ws.drive! echoes a message read with the Close and reaches on_close!", ok(Ws.drive!(Server.ops({}), d0, 0.U64, echo_handlers)) == 1)

	# The server closes: Closing meanwhile, a message on its way, then the echo.
	s1 = conn!([Data(client(Frame.text("in flight"))), Data(client(close_frame([0x03, 0xE9])))])
	s2 = ok(s1.close!(1001, "going"))
	check!("send! after close! is Closing", is_closing(s2.send!(Text("x"))))
	check!("close! wrote Close 1001 going, unmasked", sent(s2.link()) == [close_frame([0x03, 0xE9].concat("going".to_utf8()))])
	(s3, late) = ok(s2.receive!())
	check!("a message after close!", late == Text("in flight"))
	check!("a close by the server ends by us", closed_with(s3.receive!()) == Ok({ code: 1001, reason: "", clean: Bool.True, by: Us }))
	r0 = ok(Server.read_request!(fake_ops, fake([Data(request(""))])))
	r1 = r0.map_link(|f| { ..f, written: [[42]] })
	check!("Request.map_link changes the link the connection gets", (ok(r1.accept!({})).conn.link().written.first() ?? []) == [42])
	check!("close_and_wait! over Server.ops", Ws.close_and_wait!(Server.ops({}), conn!([Data(client(close_frame([0x03, 0xE8])))]), 1000, "") == Ok({ code: 1000, reason: "", clean: Bool.True, by: Us }))

	# max_message from the options.
	big = accept!([Data(request("").concat(client(Frame.binary([1, 2, 3, 4]))))], { max_message: 3 }).conn
	check!(
		"a message over max_message fails with 1009",
		match big.receive!() {
			Err(Closed({ code: 1009, .. })) => Bool.True
			_ => Bool.False
		},
	)

	# Push handlers over a server connection; a handler closes.
	d1 = conn!([Data(client(Frame.text("one"))), Data(client(Frame.text("quit"))), Data(client(close_frame([0x0F, 0xA0])))])
	ops = Server.ops({})
	handlers = {
		on_open!: |seen, c| Ok((seen.append("open"), c)),
		on_message!: |seen, c, message| match message {
			Text("quit") =>
				match (ops.close!)(c, 4000, "asked") {
					Ok(closing) => Ok((seen.append("quit"), closing))
					Err(e) => Err(e)
				}
			Text(t) => Ok((seen.append(t), c))
			Binary(_) => Ok((seen, c))
		},
		on_close!: |seen, closure| Ok(seen.append("closed ${closure.code.to_str()} by ${Str.inspect(closure.by)}")),
	}
	check!("Ws.drive! runs handlers over a server connection", ok(Ws.drive!(ops, d1, [], handlers)) == ["open", "one", "quit", "closed 4000 by Us"])

	client_closes!({})
	server_closes!({})
	Ok({})
}
