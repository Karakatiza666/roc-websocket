app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	ws: "pkg/main.roc",
}

import pf.Tcp
import pf.Duration
import pf.Stdout
import ws.Conn

main! = |_args| {
	conn = Tcp.connect!("127.0.0.1", 1, { connect_timeout: Duration.seconds(1), io_timeout: Duration.seconds(1) }).map_err(|_| Exit(1))?
	link = Conn.of(conn)
	features : Conn.Features
	features = { ping: Unsupported }
	match features.ping {
		Supported(p) => (p.ping!)([]) ?? {}
		Unsupported => {}
	}
	(link.write!)([1, 2]).map_err(|_| Exit(2))?
	Stdout.line!("ok").map_err(|_| Exit(3))?
	Ok({})
}
