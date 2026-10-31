## A closed consumer record that spells the error type out. It accepts exactly the adapters whose row matches.
Message : [Text(Str), Binary(List(U8))]

Core(e, r) : { send! : Message => Try({}, [Closed, ..e]), receive! : {} => Try(Message, [Closed, ..e]), ..r }
Ping(e, r) : { ping! : List(U8) => Try({}, [Closed, ..e]), ..r }

# Ping has its own row parameter: it may differ from Core's within one adapter.
cli_adapter : Core([Io(Str)], Ping([Pong], {}))
cli_adapter = {
	send!: |_m| Ok({}),
	receive!: |_| Ok(Text("hi")),
	ping!: |_p| Err(Pong),
}

worker_adapter : Core([TooLarge(U64)], {})
worker_adapter = {
	send!: |_m| Ok({}),
	receive!: |_| Ok(Text("hi")),
}

# Spells the error row: only adapters whose Core row is exactly [Io(Str)].
send_only! : { send! : Message => Try({}, [Closed, Io(Str)]) } => Try({}, [Closed, Io(Str)])
send_only! = |c| (c.send!)(Text("x"))

main! = |_args| {
	_ = send_only!({ send!: cli_adapter.send! })
	Ok({})
}
