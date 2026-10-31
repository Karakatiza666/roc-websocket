# The WebSocket protocol (RFC 6455) of a client, as pure functions over
# bytes. A live query needs a session on SurrealDB's `/rpc`, and the platform
# gives only a TCP connection, so the package writes the opening request and
# the frames, and reads the frames the server sends. The platform supplies
# the random bytes of the key and of each mask.
Ws :: {}.{

	## What a frame carries. A message of SurrealDB is one `Binary` frame
	## of CBOR; the others hold the session.
	Opcode : [Text, Binary, Close, Ping, Pong]

	## One frame from the server, unmasked and whole.
	Frame : { opcode : Opcode, payload : List(U8) }

	## The opening request of a session: an HTTP `GET` that asks for the
	## WebSocket protocol and the subprotocol (`cbor` for SurrealDB). `key`
	## is 16 random bytes.
	upgrade : { host : Str, path : Str, key : List(U8), protocol : Str } -> Try(Str, [BadKey])
	upgrade = |request|
		if request.key.len() != 16 {
			Err(BadKey)
		} else {
			lines = [
				"GET ${request.path} HTTP/1.1",
				"Host: ${request.host}",
				"Upgrade: websocket",
				"Connection: Upgrade",
				"Sec-WebSocket-Key: ${Ws.base64(request.key)}",
				"Sec-WebSocket-Version: 13",
				"Sec-WebSocket-Protocol: ${request.protocol}",
			]
			Ok("${Str.join_with(lines, "\r\n")}\r\n\r\n")
		}

	## Whether the head of the server's reply, the text before the empty
	## line, accepts the upgrade with the subprotocol. It does not check
	## `Sec-WebSocket-Accept`, which needs SHA-1.
	accepted : Str, Str -> Try({}, [Refused(Str)])
	accepted = |head, protocol| {
		lines = head.split_on("\r\n")
		status = lines.first() ?? ""
		chosen = lines.drop_first(1).any(
			|line| match line.split_on(":") {
				[name, value] => name.with_ascii_lowercased() == "sec-websocket-protocol" and value.trim() == protocol
				_ => Bool.False
			},
		)
		if !status.starts_with("HTTP/1.1 101 ") {
			Err(Refused(status))
		} else if !chosen {
			Err(Refused("the server did not choose the subprotocol `${protocol}`"))
		} else {
			Ok({})
		}
	}

	## A whole frame from the client, masked with the 4 bytes of `mask`, as
	## a client must.
	frame : Opcode, List(U8), List(U8) -> Try(List(U8), [BadMask])
	frame = |opcode, payload, mask|
		if mask.len() != 4 {
			Err(BadMask)
		} else {
			size = payload.len()
			length =
				if size < 126 {
					[128 + size.to_u8_wrap()]
				} else if size < 65536 {
					[254].concat(Ws.big_endian(size, 2))
				} else {
					[255].concat(Ws.big_endian(size, 8))
				}
			masked = payload.map_with_index(
				|b, i| match mask.get(i % 4) {
					Ok(m) => b.bitwise_xor(m)
					Err(_) => crash "a mask has 4 bytes"
				},
			)
			Ok([128 + Ws.code(opcode)].concat(length).concat(mask).concat(masked))
		}

	## The first frame of `bytes`, and the bytes after it. `Incomplete(n)`
	## says that the frame needs `n` bytes at least, so a reader reads more.
	## A frame that a server must not send is `BadFrame`: a masked frame, a
	## fragment, a reserved bit, an unknown opcode, or a control frame of
	## more than 125 bytes.
	decode : List(U8) -> Try({ frame : Frame, rest : List(U8) }, [Incomplete(U64), BadFrame(Str)])
	decode = |bytes| match bytes {
		[first, second, .. as after] => {
			opcode = match first.bitwise_and(15) {
				1 => Text
				2 => Binary
				8 => Close
				9 => Ping
				10 => Pong
				0 => return Err(BadFrame("a fragment of a message"))
				other => return Err(BadFrame("the unknown opcode ${other.to_str()}"))
			}
			if first.bitwise_and(128) == 0 {
				return Err(BadFrame("a fragment of a message"))
			}
			if first.bitwise_and(112) != 0 {
				return Err(BadFrame("a reserved bit is set"))
			}
			if second.bitwise_and(128) != 0 {
				return Err(BadFrame("a frame from the server is masked"))
			}
			(extra, size) = match second.bitwise_and(127) {
				126 => (2, Ws.from_big_endian(after.take_first(2)))
				127 => (8, Ws.from_big_endian(after.take_first(8)))
				short => (0, short.to_u64())
			}
			control = opcode == Close or opcode == Ping or opcode == Pong
			if control and size > 125 {
				Err(BadFrame("a control frame of more than 125 bytes"))
			} else if after.len() < extra {
				Err(Incomplete(2 + extra))
			} else if after.len() < extra + size {
				Err(Incomplete(2 + extra + size))
			} else {
				payload = after.sublist({ start: extra, len: size })
				Ok({ frame: { opcode, payload }, rest: after.drop_first(extra + size) })
			}
		}
		_ => Err(Incomplete(2))
	}

	## What the client does with a frame from the server: read a message,
	## answer a `Ping` with a `Pong` of the same payload, answer a `Close`
	## with a `Close` and end the session, or nothing for a `Pong`. `mask`
	## masks the answer.
	receive : Frame, List(U8) -> Try([Message(List(U8)), Reply(List(U8)), Closed(List(U8)), Nothing], [BadMask])
	receive = |received, mask| match received.opcode {
		Text | Binary => Ok(Message(received.payload))
		Ping => Ws.frame(Pong, received.payload, mask).map_ok(|bytes| Reply(bytes))
		Close => Ws.frame(Close, received.payload.take_first(2), mask).map_ok(|bytes| Closed(bytes))
		Pong => Ok(Nothing)
	}

	code : Opcode -> U8
	code = |opcode| match opcode {
		Text => 1
		Binary => 2
		Close => 8
		Ping => 9
		Pong => 10
	}

	## The last `width` bytes of a number, most significant first.
	big_endian : U64, U64 -> List(U8)
	big_endian = |n, width| (0.U64).until(width).map(|i| n.shr_zf_wrap(((width - 1 - i) * 8).to_u8_wrap()).to_u8_wrap()).collect()

	from_big_endian : List(U8) -> U64
	from_big_endian = |bytes| bytes.fold(0, |acc, b| acc * 256 + b.to_u64())

	## Base64 with padding, as the key of the opening request.
	base64 : List(U8) -> Str
	base64 = |bytes| {
		alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_utf8()
		digit = |n| match alphabet.get(n.to_u64()) {
			Ok(d) => d
			Err(_) => crash "a base64 digit is below 64"
		}
		out = bytes.chunks_of(3).join_map(
			|chunk| {
				# A missing byte of the last group is 0, and its digits are `=`.
				b0 = chunk.get(0) ?? 0
				b1 = chunk.get(1) ?? 0
				b2 = chunk.get(2) ?? 0
				all = [digit(b0 // 4), digit((b0 % 4) * 16 + b1 // 16), digit((b1 % 16) * 4 + b2 // 64), digit(b2 % 64)]
				all.take_first(chunk.len() + 1).concat(List.repeat(61, 3 - chunk.len()))
			},
		)
		match Str.from_utf8(out) {
			Ok(s) => s
			Err(_) => crash "base64 digits are ASCII"
		}
	}
}
