## Probe of the message-level surface: a connection is a record value, and its optional features are fields.
Socket :: {}.{
	Message : [Text(Str), Binary(List(U8))]

	Closed : { code : U16, reason : Str, clean : Bool }

	Err : [Closed(Socket.Closed), Failed(Str)]

	Features : {
		ping : [Supported({ ping! : List(U8) => Try({}, Socket.Err) }), Unsupported],
		pong_seen : [Supported({ last_pong_ms! : {} => Try(U64, [NotFound]) }), Unsupported],
	}

	Conn : {
		send! : Socket.Message => Try({}, Socket.Err),
		receive! : {} => Try(Socket.Message, Socket.Err),
		close! : U16, Str => Try({}, Socket.Err),
		features : Socket.Features,
	}

	none : Socket.Features
	none = { ping: Unsupported, pong_seen: Unsupported }

	messages : Socket.Conn -> Stream(Try(Socket.Message, Str))
	messages = |conn| Stream.custom(conn, Err(Unknown), |c| match (c.receive!)({}) {
		Ok(m) => Ok((Ok(m), c))
		Err(Closed(_)) => Err(NoMore)
		Err(Failed(why)) => Ok((Err(why), c))
	})

	echo! : Socket.Conn => Try({}, Socket.Err)
	echo! = |conn| {
		while Bool.True {
			msg = (conn.receive!)({})?
			(conn.send!)(msg)?
		}
		Ok({})
	}
}
