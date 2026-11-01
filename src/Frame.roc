## One WebSocket frame (RFC 6455 section 5.2), with its payload unmasked.
##
## Extensions are not supported, so the RSV bits are always 0: a frame with
## one set is invalid.
Frame := { fin : Bool, opcode : Frame.Opcode, payload : List(U8) }.{

	is_eq : _

	## What a frame carries. `Continuation` continues a fragmented message;
	## `Close`, `Ping` and `Pong` are control frames.
	Opcode : [Continuation, Text, Binary, Close, Ping, Pong]

	## Whether frames are masked. A client masks every frame it sends with
	## 4 unpredictable bytes; a server never masks (RFC 6455 section 5.3).
	Masking : [Masked(List(U8)), Unmasked]

	## Which masking the receiver requires: a server requires masked frames, a
	## client unmasked ones.
	Expect : [ExpectMasked, ExpectUnmasked]

	## The fixed part of a frame, read before its payload.
	Header : {
		fin : Bool,
		opcode : Frame.Opcode,
		mask : Frame.Masking,
		length : U64,

		## Bytes of the header: 2 to 14.
		size : U64,
	}

	## A whole text message in one frame.
	text : Str -> Frame
	text = |s| { fin: Bool.True, opcode: Text, payload: s.to_utf8() }

	## A whole binary message in one frame.
	binary : List(U8) -> Frame
	binary = |bytes| { fin: Bool.True, opcode: Binary, payload: bytes }

	## A ping. The payload is at most 125 bytes.
	ping : List(U8) -> Frame
	ping = |bytes| { fin: Bool.True, opcode: Ping, payload: bytes }

	## A pong. The payload is at most 125 bytes.
	pong : List(U8) -> Frame
	pong = |bytes| { fin: Bool.True, opcode: Pong, payload: bytes }

	## Whether the opcode is a control opcode.
	is_control : Frame.Opcode -> Bool
	is_control = |opcode| match opcode {
		Close | Ping | Pong => Bool.True
		Continuation | Text | Binary => Bool.False
	}

	## The 4-bit code of an opcode.
	code : Frame.Opcode -> U8
	code = |opcode| match opcode {
		Continuation => 0
		Text => 1
		Binary => 2
		Close => 8
		Ping => 9
		Pong => 10
	}

	## XOR `bytes` with the 4-byte `key`, repeated (RFC 6455 section 5.3).
	## Masking twice with one key gives the original bytes.
	mask : List(U8), List(U8) -> List(U8)
	mask = |bytes, key|
		if key.len() != 4 {
			crash "Frame.mask: a masking key has 4 bytes"
		} else {
			bytes.map_with_index(|b, i| b.bitwise_xor(key.get(i % 4) ?? 0))
		}

	## The bytes of a frame on the wire. A control frame payload must be at most
	## 125 bytes and a control frame must be final; a mask must be 4 bytes.
	encode : Frame, Frame.Masking -> Try(List(U8), [ControlTooLong(U64), FragmentedControl, BadMask(U64)])
	encode = |frame, masking| {
		size = frame.payload.len()
		control = Frame.is_control(frame.opcode)
		if control and size > 125 {
			return Err(ControlTooLong(size))
		}
		if control and !frame.fin {
			return Err(FragmentedControl)
		}
		first = (if (frame.fin) 128 else 0) + Frame.code(frame.opcode)
		mask_bit = match masking {
			Masked(_) => 128.U8
			Unmasked => 0
		}
		length =
			if size < 126 {
				[mask_bit + size.to_u8_wrap()]
			} else if size < 65536 {
				[mask_bit + 126].concat(big_endian(size, 2))
			} else {
				[mask_bit + 127].concat(big_endian(size, 8))
			}
		head = [first].concat(length)
		match masking {
			Unmasked => Ok(head.concat(frame.payload))
			Masked(key) =>
				if key.len() != 4 {
					Err(BadMask(key.len()))
				} else {
					Ok(head.concat(key).concat(Frame.mask(frame.payload, key)))
				}
		}
	}

	## The header at the start of `bytes`. `Incomplete(n)` means the header
	## needs `n` bytes in all. `Invalid` names the RFC rule the frame breaks.
	header : List(U8), Frame.Expect -> Try(Frame.Header, [Incomplete(U64), Invalid(Str)])
	header = |bytes, wanted| match bytes {
		[first, second, .. as after] => {
			opcode = match first.bitwise_and(15) {
				0 => Continuation
				1 => Text
				2 => Binary
				8 => Close
				9 => Ping
				10 => Pong
				other => return Err(Invalid("reserved opcode ${other.to_str()}"))
			}
			fin = first.bitwise_and(128) != 0
			if first.bitwise_and(112) != 0 {
				return Err(Invalid("a reserved bit is set with no extension negotiated"))
			}
			masked = second.bitwise_and(128) != 0
			match (wanted, masked) {
				(ExpectMasked, Bool.False) => return Err(Invalid("a client frame is not masked"))
				(ExpectUnmasked, Bool.True) => return Err(Invalid("a server frame is masked"))
				_ => {}
			}
			(extra, length) = match second.bitwise_and(127) {
				126 => (2, from_big_endian(after.take_first(2)))
				127 => (8, from_big_endian(after.take_first(8)))
				short => (0, short.to_u64())
			}
			key_size = if (masked) 4 else 0
			size = 2 + extra + key_size
			if bytes.len() < size {
				return Err(Incomplete(size))
			}
			if extra == 8 and (after.get(0) ?? 0) >= 128 {
				return Err(Invalid("the most significant bit of a 64-bit length is set"))
			}
			control = Frame.is_control(opcode)
			if control and length > 125 {
				return Err(Invalid("a control frame of more than 125 bytes"))
			}
			if control and !fin {
				return Err(Invalid("a fragmented control frame"))
			}
			masking = if (masked) Masked(after.sublist({ start: extra, len: 4 })) else Unmasked
			Ok({ fin, opcode, mask: masking, length, size })
		}
		_ => Err(Incomplete(2))
	}

	## The first frame of `bytes`, unmasked, and the bytes after it.
	## `Incomplete(n)` means the frame needs `n` bytes in all, so a reader
	## that reads `n - bytes.len()` more bytes never reads past the frame.
	decode : List(U8), Frame.Expect -> Try({ frame : Frame, rest : List(U8) }, [Incomplete(U64), Invalid(Str)])
	decode = |bytes, wanted| {
		h = Frame.header(bytes, wanted)?
		total = h.size + h.length
		if bytes.len() < total {
			Err(Incomplete(total))
		} else {
			raw = bytes.sublist({ start: h.size, len: h.length })
			payload = match h.mask {
				Masked(key) => Frame.mask(raw, key)
				Unmasked => raw
			}
			Ok({ frame: { fin: h.fin, opcode: h.opcode, payload }, rest: bytes.drop_first(total) })
		}
	}

	## The frames of one message, each payload at most `size` bytes (at least 1).
	## The first frame has the message's opcode, the others are
	## `Continuation`, and only the last is final.
	fragments : [Text(Str), Binary(List(U8))], U64 -> List(Frame)
	fragments = |message, size| {
		(opcode, bytes) = match message {
			Text(s) => (Text, s.to_utf8())
			Binary(b) => (Binary, b)
		}
		chunks = if (bytes.is_empty()) [[]] else bytes.chunks_of(if (size == 0) 1 else size)
		count = chunks.len()
		chunks.map_with_index(|payload, i| { fin: i + 1 == count, opcode: if (i == 0) opcode else Continuation, payload })
	}
}

## The last `width` bytes of a number, most significant first.
big_endian : U64, U64 -> List(U8)
big_endian = |n, width| (0.U64).until(width).map(|i| n.shr_zf_wrap(((width - 1 - i) * 8).to_u8_wrap()).to_u8_wrap()).collect()

from_big_endian : List(U8) -> U64
from_big_endian = |bytes| bytes.fold(0, |acc, b| acc.shl_wrap(8).bitwise_or(b.to_u64()))

hello : List(U8)
hello = "Hello".to_utf8()

key : List(U8)
key = [0x37, 0xfa, 0x21, 0x3d]

# RFC 6455 section 5.7 examples.
expect Frame.encode(Frame.text("Hello"), Unmasked) == Ok([0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f])
expect Frame.encode(Frame.text("Hello"), Masked(key)) == Ok([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58])
expect Frame.decode([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58], ExpectMasked) == Ok({ frame: Frame.text("Hello"), rest: [] })
expect Frame.decode([0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x99], ExpectUnmasked) == Ok({ frame: Frame.text("Hello"), rest: [0x99] })
# A fragmented unmasked text message: "Hel" then "lo".
expect Frame.decode([0x01, 0x03, 0x48, 0x65, 0x6c], ExpectUnmasked) == Ok({ frame: { fin: Bool.False, opcode: Text, payload: "Hel".to_utf8() }, rest: [] })
expect Frame.decode([0x80, 0x02, 0x6c, 0x6f], ExpectUnmasked) == Ok({ frame: { fin: Bool.True, opcode: Continuation, payload: "lo".to_utf8() }, rest: [] })
expect Frame.fragments(Text("Hello"), 3) == [{ fin: Bool.False, opcode: Text, payload: "Hel".to_utf8() }, { fin: Bool.True, opcode: Continuation, payload: "lo".to_utf8() }]
expect Frame.fragments(Binary([]), 3) == [Frame.binary([])]
# Unmasked ping with "Hello", and the masked pong reply.
expect Frame.encode(Frame.ping(hello), Unmasked) == Ok([0x89, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f])
expect Frame.encode(Frame.pong(hello), Masked(key)) == Ok([0x8a, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58])
# 256 bytes and 65536 bytes binary messages in a single unmasked frame.
expect Frame.encode(Frame.binary(List.repeat(0, 256)), Unmasked).map_ok(|b| b.take_first(4)) == Ok([0x82, 0x7E, 0x01, 0x00])
expect Frame.encode(Frame.binary(List.repeat(0, 65536)), Unmasked).map_ok(|b| b.take_first(10)) == Ok([0x82, 0x7F, 0, 0, 0, 0, 0, 1, 0, 0])
expect Frame.decode(Frame.encode(Frame.binary(List.repeat(7, 65536)), Unmasked) ?? [], ExpectUnmasked).map_ok(|d| d.frame.payload.len()) == Ok(65536)
expect Frame.decode(Frame.encode(Frame.binary(List.repeat(7, 300)), Masked(key)) ?? [], ExpectMasked) == Ok({ frame: Frame.binary(List.repeat(7, 300)), rest: [] })
# Incomplete input says how much the frame needs.
expect Frame.decode([], ExpectUnmasked) == Err(Incomplete(2))
expect Frame.decode([0x82, 0x7E], ExpectUnmasked) == Err(Incomplete(4))
expect Frame.decode([0x82, 0x7E, 0x01, 0x00], ExpectUnmasked) == Err(Incomplete(260))
expect Frame.decode([0x81, 0x85, 0x37], ExpectMasked) == Err(Incomplete(6))
# Rule violations.
expect Frame.decode([0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f], ExpectMasked) == Err(Invalid("a client frame is not masked"))
expect Frame.decode([0x81, 0x85, 0, 0, 0, 0, 0, 0, 0, 0, 0], ExpectUnmasked) == Err(Invalid("a server frame is masked"))
expect Frame.decode([0xC1, 0x00], ExpectUnmasked) == Err(Invalid("a reserved bit is set with no extension negotiated"))
expect Frame.decode([0x83, 0x00], ExpectUnmasked) == Err(Invalid("reserved opcode 3"))
expect Frame.decode([0x09, 0x00], ExpectUnmasked) == Err(Invalid("a fragmented control frame"))
expect Frame.decode([0x89, 0x7E, 0x00, 0x7E], ExpectUnmasked) == Err(Invalid("a control frame of more than 125 bytes"))
expect Frame.encode(Frame.ping(List.repeat(0, 126)), Unmasked) == Err(ControlTooLong(126))
expect Frame.encode(Frame.text("x"), Masked([1])) == Err(BadMask(1))
