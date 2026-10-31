## A byte link from any value that has `write_bytes!` and `read_exactly!`.
Conn :: {}.{
	Link : {
		write! : List(U8) => Try({}, Str),
		read_exactly! : U64 => Try(List(U8), Str),
	}

	of : c -> Conn.Link where [c.write_bytes! : c, List(U8) => Try({}, ew), c.read_exactly! : c, U64 => Try(List(U8), er)]
	of = |c| {
		write!: |bytes| c.write_bytes!(bytes).map_err(Str.inspect),
		read_exactly!: |n| c.read_exactly!(n).map_err(Str.inspect),
	}

	Features : { ping : [Supported({ ping! : List(U8) => Try({}, Str) }), Unsupported] }
}
