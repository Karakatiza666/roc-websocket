app [event!] {
	pf: platform "../../../cloudflare-workers-ws/platform/main.roc",
	ws: "../pkg/main.roc",
}

import pf.Worker
import pf.Request
import pf.Response
import pf.WebSocket
import ws.Socket

## The cloudflare-workers adapter: a `WebSocket` of the platform as a `Socket.Conn` of the package.
conn_of : WebSocket -> Socket.Conn
conn_of = |sock| {
	send!: |msg| {
		frame = match msg {
			Text(s) => Text(s)
			Binary(b) => Bytes(b)
		}
		sock.send!(frame).map_err(|Closed| Closed({ code: 1006, reason: "", clean: Bool.False }))
	},
	receive!: |{}| match sock.receive!() {
		Ok(Text(s)) => Ok(Text(s))
		Ok(Bytes(b)) => Ok(Binary(b))
		Err(Closed(c)) => Err(Closed(c))
	},
	close!: |code, reason| Ok(sock.close!(code, reason)),
	features: Socket.none,
}

fetch! : Request => Try(Response, _)
fetch! = |req| match WebSocket.accept!(req) {
	Ok({ socket, response }) => Ok(response.after(|| Socket.echo!(conn_of(socket)).map_err(|e| Str.inspect(e))))
	Err(NotUpgrade) => Ok(Response.from_status(426))
}

worker = Worker.new({ fetch!: fetch!, bindings: [] })

event! = |e| worker.event!(e)
