## SHA-1 (FIPS 180-4), for `Sec-WebSocket-Accept` (RFC 6455 section 4.2.2).
## The builtins have SHA-256 and BLAKE3 but not SHA-1. SHA-1 is broken for
## collision resistance; the handshake uses it only to prove that the server
## read the key, not for security.
Sha1 :: [].{

	## The 20-byte digest of `bytes`.
	hash : List(U8) -> List(U8)
	hash = |bytes| {
		bit_length = bytes.len() * 8
		zeros = (119 - (bytes.len() % 64)) % 64
		padded = bytes.append(128).concat(List.repeat(0, zeros)).concat(be64(bit_length))
		var $h = [0x67452301.U32, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
		for block in padded.chunks_of(64) {
			$h = compress($h, block)
		}
		$h.join_map(|word| [word.shr_zf_wrap(24).to_u8_wrap(), word.shr_zf_wrap(16).to_u8_wrap(), word.shr_zf_wrap(8).to_u8_wrap(), word.to_u8_wrap()])
	}

	## The digest as 40 lowercase hex digits.
	hex : List(U8) -> Str
	hex = |bytes| {
		digits = "0123456789abcdef".to_utf8()
		out = bytes.join_map(|b| [digits.get((b // 16).to_u64()) ?? 48, digits.get((b % 16).to_u64()) ?? 48])
		match Str.from_utf8(out) {
			Ok(s) => s
			Err(_) => crash "hex digits are ASCII"
		}
	}
}

be64 : U64 -> List(U8)
be64 = |n| [56, 48, 40, 32, 24, 16, 8, 0].map(|shift| n.shr_zf_wrap(shift).to_u8_wrap())

rotl : U32, U8 -> U32
rotl = |x, n| x.shl_wrap(n).bitwise_or(x.shr_zf_wrap(32 - n))

at : List(U32), U64 -> U32
at = |list, i| match list.get(i) {
	Ok(v) => v
	Err(_) => crash "SHA-1 index in range"
}

compress : List(U32), List(U8) -> List(U32)
compress = |h, block| {
	var $w = List.with_capacity(80)
	for i in 0.U64..<16 {
		byte = |k| (block.get(i * 4 + k) ?? 0).to_u32()
		$w = $w.append(byte(0).shl_wrap(24).bitwise_or(byte(1).shl_wrap(16)).bitwise_or(byte(2).shl_wrap(8)).bitwise_or(byte(3)))
	}
	for i in 16.U64..<80 {
		mixed = at($w, i - 3).bitwise_xor(at($w, i - 8)).bitwise_xor(at($w, i - 14)).bitwise_xor(at($w, i - 16))
		$w = $w.append(rotl(mixed, 1))
	}
	var $a = at(h, 0)
	var $b = at(h, 1)
	var $c = at(h, 2)
	var $d = at(h, 3)
	var $e = at(h, 4)
	for i in 0.U64..<80 {
		(f, k) =
			if i < 20 {
				($b.bitwise_and($c).bitwise_or($b.bitwise_not().bitwise_and($d)), 0x5A827999.U32)
			} else if i < 40 {
				($b.bitwise_xor($c).bitwise_xor($d), 0x6ED9EBA1)
			} else if i < 60 {
				($b.bitwise_and($c).bitwise_or($b.bitwise_and($d)).bitwise_or($c.bitwise_and($d)), 0x8F1BBCDC)
			} else {
				($b.bitwise_xor($c).bitwise_xor($d), 0xCA62C1D6)
			}
		temp = rotl($a, 5).plus_wrap(f).plus_wrap($e).plus_wrap(k).plus_wrap(at($w, i))
		$e = $d
		$d = $c
		$c = rotl($b, 30)
		$b = $a
		$a = temp
	}
	[at(h, 0).plus_wrap($a), at(h, 1).plus_wrap($b), at(h, 2).plus_wrap($c), at(h, 3).plus_wrap($d), at(h, 4).plus_wrap($e)]
}

# FIPS 180-2 appendix A and common vectors.
expect Sha1.hex(Sha1.hash([])) == "da39a3ee5e6b4b0d3255bfef95601890afd80709"
expect Sha1.hex(Sha1.hash("abc".to_utf8())) == "a9993e364706816aba3e25717850c26c9cd0d89d"
expect Sha1.hex(Sha1.hash("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".to_utf8())) == "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
expect Sha1.hex(Sha1.hash("The quick brown fox jumps over the lazy dog".to_utf8())) == "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12"
# 55, 56 and 64 bytes: the padding edges.
expect Sha1.hex(Sha1.hash(List.repeat(97, 55))) == "c1c8bbdc22796e28c0e15163d20899b65621d65a"
expect Sha1.hex(Sha1.hash(List.repeat(97, 56))) == "c2db330f6083854c99d4b5bfb6e8f29f201be699"
expect Sha1.hex(Sha1.hash(List.repeat(97, 64))) == "0098ba824b5c16427bd7a1122a5a442a25ec644d"
expect Sha1.hex(Sha1.hash(List.repeat(97, 1000))) == "291e9a6c66994949b57ba5e650361e98fc36b1ba"
