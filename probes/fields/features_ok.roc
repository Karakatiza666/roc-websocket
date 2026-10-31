## Field-based features: each feature is an extensible alias; an adapter is a record of only what it supports.
Message : [Text(Str), Binary(List(U8))]

Core(r) : { send! : Message => Try({}, [Closed]), receive! : {} => Try(Message, [Closed]), ..r }
Ping(r) : { ping! : List(U8) => Try({}, [Closed]), ..r }

cli_adapter : Core(Ping({}))
cli_adapter = {
	send!: |_m| Ok({}),
	receive!: |_| Ok(Text("hi")),
	ping!: |_p| Ok({}),
}

worker_adapter : Core({})
worker_adapter = {
	send!: |_m| Ok({}),
	receive!: |_| Ok(Text("hi")),
}

keepalive! : { ping! : List(U8) => Try({}, [Closed]), .. } => Try({}, [Closed])
keepalive! = |c| (c.ping!)([])

main! = |_args| {
	keepalive!(cli_adapter)?
	Ok({})
}
