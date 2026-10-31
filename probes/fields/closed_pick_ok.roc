## A consumer takes a closed record of the fields it needs; the app picks them.
Message : [Text(Str), Binary(List(U8))]
Core(r) : { send! : Message => Try({}, [Closed]), receive! : {} => Try(Message, [Closed]), ..r }
Ping(r) : { ping! : List(U8) => Try({}, [Closed]), ..r }

adapter : Core(Ping({}))
adapter = { send!: |_m| Ok({}), receive!: |_| Ok(Text("hi")), ping!: |_p| Ok({}) }

session! : { send! : Message => Try({}, [Closed]), receive! : {} => Try(Message, [Closed]) } => Try({}, [Closed])
session! = |c| (c.send!)(Text("x"))

main! = |_args| {
	_ = session!({ send!: adapter.send!, receive!: adapter.receive! })
	Ok({})
}
