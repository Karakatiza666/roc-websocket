app [Context, program] {
	pf: platform "../../basic-webserver-0.19.0/platform/main.roc", # a checkout of the 0.19.0 tag
	ws: "../pkg/main.roc",
}

import pf.Server
import pf.Sse
import pf.Tcp
import pf.File
import ws.Socket
import ws.Ws

Context : {}

program = { init!, respond!, shutdown! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || Ok({ config: Server.default_config, context: {} })

shutdown! = |_reason, _context| Ok({})

failed : e -> Socket.Err
failed = |e| Failed(Str.inspect(e))

## basic-webserver has no Random: entropy from /dev/urandom (an inference that the File API reads it).
random! : U64 => Try(List(U8), Socket.Err)
random! = |count| {
	reader = File.open_reader!("/dev/urandom").map_err(failed)?
	var $bytes = []
	while $bytes.len() < count {
		$bytes = $bytes.concat(reader.read_line!().map_err(failed)?)
	}
	Ok($bytes.take_first(count))
}

send_frame! : Tcp.Connection, Ws.Opcode, List(U8) => Try({}, Socket.Err)
send_frame! = |tcp, opcode, payload| {
	mask = random!(4)?
	bytes = Ws.frame(opcode, payload, mask).map_err(failed)?
	tcp.write!(bytes).map_err(failed)
}

read_frame! : Tcp.Connection, List(U8) => Try(Ws.Frame, Socket.Err)
read_frame! = |tcp, have| match Ws.decode(have) {
	Ok({ frame, rest: [] }) => Ok(frame)
	Ok(_) => Err(Failed("over-read"))
	Err(Incomplete(need)) => {
		more = tcp.read_exactly!(need - have.len()).map_err(failed)?
		read_frame!(tcp, have.concat(more))
	}
	Err(BadFrame(why)) => Err(Failed(why))
}

receive! : Tcp.Connection => Try(Socket.Message, Socket.Err)
receive! = |tcp| {
	frame = read_frame!(tcp, [])?
	match frame.opcode {
		Text => Str.from_utf8(frame.payload).map_ok(|s| Text(s)).map_err(failed)
		Binary => Ok(Binary(frame.payload))
		Ping => {
			send_frame!(tcp, Pong, frame.payload)?
			receive!(tcp)
		}
		Pong => receive!(tcp)
		Close => Err(Closed({ code: 1000, reason: "", clean: Bool.True }))
	}
}

conn_of : Tcp.Connection -> Socket.Conn
conn_of = |tcp| {
	send!: |msg| match msg {
		Text(s) => send_frame!(tcp, Text, s.to_utf8())
		Binary(b) => send_frame!(tcp, Binary, b)
	},
	receive!: |{}| receive!(tcp),
	close!: |code, reason| send_frame!(tcp, Close, Ws.big_endian(code.to_u64(), 2).concat(reason.to_utf8())),
	features: Socket.none,
}

## A WebSocket client relayed to the browser as SSE: each transition reads one message (a blocking read).
relay! : Socket.Conn => Try(Sse.Step(Socket.Conn), [StreamFailed(Str)])
relay! = |conn| match (conn.receive!)({}) {
	Ok(Text(s)) => Ok(Emit({ event: Sse.Event.data(s), state: conn, wake: Immediately }))
	Ok(Binary(_)) => Ok(Wait({ state: conn, wake: Immediately }))
	Err(Closed(_)) => Ok(End)
	Err(Failed(why)) => Err(StreamFailed(why))
}

respond! : Server.Request, Context => Try(Server.Outcome, [ServerErr(Str)])
respond! = |_request, _context| {
	tcp = Tcp.connect!("127.0.0.1", 9001).map_err(|e| ServerErr(Str.inspect(e)))?
	Ok(Server.stream(Sse.unfold!(conn_of(tcp), relay!)))
}
