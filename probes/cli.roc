app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	ws: "pkg/main.roc",
}

import pf.Tcp
import pf.Duration
import pf.Random
import ws.Socket
import ws.Ws

random! : U64 => Try(List(U8), Str)
random! = |count| {
	var $bytes = []
	while $bytes.len() < count {
		seed = Random.seed_u64!().map_err(Str.inspect)?
		$bytes = $bytes.concat((0.U64).until(8).map(|i| seed.shr_zf_wrap((i * 8).to_u8_wrap()).to_u8_wrap()).collect())
	}
	Ok($bytes.take_first(count))
}

failed : e -> Socket.Err
failed = |e| Failed(Str.inspect(e))

send_frame! : Tcp.Connection, Ws.Opcode, List(U8) => Try({}, Socket.Err)
send_frame! = |tcp, opcode, payload| {
	mask = random!(4).map_err(|e| Failed(e))?
	bytes = Ws.frame(opcode, payload, mask).map_err(failed)?
	tcp.write_bytes!(bytes).map_err(failed)
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
		Close => {
			send_frame!(tcp, Close, frame.payload.take_first(2))?
			Err(Closed({ code: 1000, reason: "", clean: Bool.True }))
		}
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
	features: { ..Socket.none, ping: Supported({ ping!: |payload| send_frame!(tcp, Ping, payload) }) },
}

main! = |_args| {
	tcp = Tcp.connect!("127.0.0.1", 1, { connect_timeout: Duration.seconds(1), io_timeout: Duration.seconds(1) }).map_err(|_| Exit(1))?
	conn = conn_of(tcp)
	match conn.features.ping {
		Supported(p) => (p.ping!)([]).map_err(|_| Exit(2))?
		Unsupported => {}
	}
	Socket.echo!(conn).map_err(|_| Exit(3))
}
