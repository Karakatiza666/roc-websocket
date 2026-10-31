## Error rows (a consumer cannot narrow `Closed` away from `..e`, see errors_narrow_fails.roc): a shared feature alias takes an error row `e`; platforms add their own tags.
Message : [Text(Str), Binary(List(U8))]

Core(e, r) : { send! : Message => Try({}, [Closed, ..e]), receive! : {} => Try(Message, [Closed, ..e]), ..r }
Ping(e, r) : { ping! : List(U8) => Try({}, [Closed, ..e]), ..r }

# basic-cli: adds Io; has ping. One row `[Io(Str)]` is shared by every field.
cli_adapter : Core([Io(Str)], Ping([Io(Str)], {}))
cli_adapter = {
	send!: |_m| Err(Io("broken pipe")),
	receive!: |_| Ok(Text("hi")),
	ping!: |_p| Ok({}),
}

# Cloudflare: adds TooLarge; no ping.
worker_adapter : Core([TooLarge(U64)], {})
worker_adapter = {
	send!: |_m| Err(TooLarge(9)),
	receive!: |_| Ok(Text("hi")),
}

# Consumer handles Closed, passes every other tag through. The tags stay open (`..e`).
relay! : { send! : Message => Try({}, [Closed, ..e]), receive! : {} => Try(Message, [Closed, ..e]) } => Try({}, [Closed, ..e])
relay! = |c| {
	while Bool.True {
		r = (c.receive!)({})
		match r {
			Err(Closed) => return Ok({})
			Err(other) => return Err(other)
			Ok(m) => match (c.send!)(m) {
				Ok(_) => {}
				Err(Closed) => return Ok({})
				Err(other) => return Err(other)
			}
		}
	}
	Ok({})
}

# One consumer, two adapters with different extra tags.
main! = |_args| {
	a = relay!({ send!: cli_adapter.send!, receive!: cli_adapter.receive! })
	b = relay!({ send!: worker_adapter.send!, receive!: worker_adapter.receive! })
	match a {
		Ok(_) => {}
		Err(Closed) => {}
		Err(Io(s)) => echo!(s)
	}
	match b {
		Ok(_) => {}
		Err(Closed) => {}
		Err(TooLarge(n)) => echo!(n.to_str())
	}
	Ok({})
}
