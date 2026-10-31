## Base64 with padding (RFC 4648 section 4), as the WebSocket handshake uses
## for `Sec-WebSocket-Key` and `Sec-WebSocket-Accept`.
Base64 :: [].{

	## The Base64 text of `bytes`, padded with `=` to a multiple of 4.
	##
	## ```roc
	## expect Base64.encode("foobar".to_utf8()) == "Zm9vYmFy"
	## ```
	encode : List(U8) -> Str
	encode = |bytes| {
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
			Err(_) => crash "Base64 digits are ASCII"
		}
	}

	## The bytes of padded Base64 text. Text whose length is not a multiple of 4,
	## a character outside the alphabet, or padding anywhere but the end is
	## `Err(InvalidBase64)`.
	##
	## ```roc
	## expect Base64.decode("Zm9vYg==") == Ok("foob".to_utf8())
	## ```
	decode : Str -> Try(List(U8), [InvalidBase64])
	decode = |text| {
		chars = text.to_utf8()
		if chars.len() % 4 != 0 {
			return Err(InvalidBase64)
		}
		groups = chars.chunks_of(4)
		last = groups.len()
		var $out = List.with_capacity(chars.len() // 4 * 3)
		var $index = 0
		for group in groups {
			$index = $index + 1
			padding = group.count_if(|c| c == 61)
			if padding > 2 or (padding > 0 and $index != last) {
				return Err(InvalidBase64)
			}
			# Padding must be the tail of the group.
			if group.take_first(4 - padding).any(|c| c == 61) {
				return Err(InvalidBase64)
			}
			values = group.take_first(4 - padding).map_try(value)?
			v0 = values.get(0) ?? 0
			v1 = values.get(1) ?? 0
			v2 = values.get(2) ?? 0
			v3 = values.get(3) ?? 0
			bytes = [v0 * 4 + v1 // 16, (v1 % 16) * 16 + v2 // 4, (v2 % 4) * 64 + v3]
			$out = $out.concat(bytes.take_first(3 - padding))
		}
		Ok($out)
	}
}

digit : U8 -> U8
digit = |n|
	if n < 26 {
		65 + n
	} else if n < 52 {
		97 + n - 26
	} else if n < 62 {
		48 + n - 52
	} else if n == 62 {
		43
	} else {
		47
	}

value : U8 -> Try(U8, [InvalidBase64])
value = |c|
	if c >= 65 and c <= 90 {
		Ok(c - 65)
	} else if c >= 97 and c <= 122 {
		Ok(c - 97 + 26)
	} else if c >= 48 and c <= 57 {
		Ok(c - 48 + 52)
	} else if c == 43 {
		Ok(62)
	} else if c == 47 {
		Ok(63)
	} else {
		Err(InvalidBase64)
	}

# RFC 4648 section 10 test vectors.
expect Base64.encode([]) == ""
expect Base64.encode("f".to_utf8()) == "Zg=="
expect Base64.encode("fo".to_utf8()) == "Zm8="
expect Base64.encode("foo".to_utf8()) == "Zm9v"
expect Base64.encode("foob".to_utf8()) == "Zm9vYg=="
expect Base64.encode("fooba".to_utf8()) == "Zm9vYmE="
expect Base64.encode("foobar".to_utf8()) == "Zm9vYmFy"
expect Base64.encode([251, 255, 191]) == "+/+/"
expect Base64.decode("") == Ok([])
expect Base64.decode("Zg==") == Ok("f".to_utf8())
expect Base64.decode("Zm8=") == Ok("fo".to_utf8())
expect Base64.decode("Zm9vYmFy") == Ok("foobar".to_utf8())
expect Base64.decode("+/+/") == Ok([251, 255, 191])
expect Base64.decode("Zm9") == Err(InvalidBase64)
expect Base64.decode("Zm=v") == Err(InvalidBase64)
expect Base64.decode("Zg==Zg==") == Err(InvalidBase64)
expect Base64.decode("Zm9*") == Err(InvalidBase64)
# The RFC 6455 section 1.3 handshake key is 16 bytes.
expect Base64.decode("dGhlIHNhbXBsZSBub25jZQ==") == Ok("the sample nonce".to_utf8())
