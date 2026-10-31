## Close codes and the payload of a `Close` frame (RFC 6455 sections 5.5.1
## and 7.4).
CloseCode :: [].{

	## 1000: the purpose of the connection is fulfilled.
	normal : U16
	normal = 1000

	## 1001: the endpoint goes away (server shutdown, page left).
	going_away : U16
	going_away = 1001

	## 1002: the peer broke the protocol.
	protocol_error : U16
	protocol_error = 1002

	## 1003: a kind of data the endpoint cannot accept.
	unsupported_data : U16
	unsupported_data = 1003

	## 1005: the Close frame had no code. Reported, never sent.
	no_status : U16
	no_status = 1005

	## 1006: the connection dropped with no Close frame. Reported, never sent.
	abnormal : U16
	abnormal = 1006

	## 1007: a text message was not UTF-8.
	invalid_payload : U16
	invalid_payload = 1007

	## 1008: the message breaks the endpoint's policy.
	policy_violation : U16
	policy_violation = 1008

	## 1009: a message too big to process.
	too_big : U16
	too_big = 1009

	## 1010: the client expected an extension the server did not negotiate.
	mandatory_extension : U16
	mandatory_extension = 1010

	## 1011: the server hit an unexpected condition.
	internal_error : U16
	internal_error = 1011

	## Whether an endpoint may put `code` in a Close frame: 1000-1003,
	## 1007-1014 (1012-1014 registered with IANA after RFC 6455), and
	## 3000-4999 (libraries and applications). 1004, 1005, 1006 and 1015 are
	## reserved and never sent.
	is_sendable : U16 -> Bool
	is_sendable = |code|
		(code >= 1000 and code <= 1003) or (code >= 1007 and code <= 1014) or (code >= 3000 and code <= 4999)

	## The payload of a Close frame: the code, big-endian, then the reason as
	## UTF-8, at most 123 bytes so the frame stays within 125.
	payload : U16, Str -> Try(List(U8), [InvalidCode(U16), ReasonTooLong(U64)])
	payload = |code, reason| {
		text = reason.to_utf8()
		if !CloseCode.is_sendable(code) {
			Err(InvalidCode(code))
		} else if text.len() > 123 {
			Err(ReasonTooLong(text.len()))
		} else {
			Ok([code.shr_zf_wrap(8).to_u8_wrap(), code.to_u8_wrap()].concat(text))
		}
	}

	## The code and reason of a received Close payload. An empty payload is
	## code 1005 and no reason. A 1-byte payload, a code that may not be sent,
	## or a reason that is not UTF-8 is `Err`, with the code to fail the
	## connection with (1002 or 1007).
	parse : List(U8) -> Try({ code : U16, reason : Str, has_code : Bool }, [Invalid({ code : U16, why : Str })])
	parse = |bytes| match bytes {
		[] => Ok({ code: 1005, reason: "", has_code: Bool.False })
		[_] => Err(Invalid({ code: 1002, why: "a Close payload of 1 byte" }))
		[high, low, .. as rest] => {
			code = high.to_u16().shl_wrap(8).bitwise_or(low.to_u16())
			if !CloseCode.is_sendable(code) {
				Err(Invalid({ code: 1002, why: "the close code ${code.to_str()} may not be sent" }))
			} else {
				match Str.from_utf8(rest) {
					Ok(reason) => Ok({ code, reason, has_code: Bool.True })
					Err(_) => Err(Invalid({ code: 1007, why: "a close reason that is not UTF-8" }))
				}
			}
		}
	}
}

expect CloseCode.payload(1000, "bye") == Ok([0x03, 0xE8, 98, 121, 101])
expect CloseCode.payload(4000, "") == Ok([0x0F, 0xA0])
expect CloseCode.payload(1005, "") == Err(InvalidCode(1005))
expect CloseCode.payload(1006, "") == Err(InvalidCode(1006))
expect CloseCode.payload(1015, "") == Err(InvalidCode(1015))
expect CloseCode.payload(2999, "") == Err(InvalidCode(2999))
expect CloseCode.payload(5000, "") == Err(InvalidCode(5000))
expect CloseCode.payload(1000, Str.join_with(List.repeat("x", 124), "")) == Err(ReasonTooLong(124))
expect CloseCode.payload(1000, Str.join_with(List.repeat("x", 123), "")).is_ok()
expect CloseCode.parse([]) == Ok({ code: 1005, reason: "", has_code: Bool.False })
expect CloseCode.parse([0x03, 0xE8, 98, 121, 101]) == Ok({ code: 1000, reason: "bye", has_code: Bool.True })
expect CloseCode.parse([0x03]) == Err(Invalid({ code: 1002, why: "a Close payload of 1 byte" }))
expect CloseCode.parse([0x03, 0xED]) == Err(Invalid({ code: 1002, why: "the close code 1005 may not be sent" }))
expect CloseCode.parse([0x03, 0xE8, 0xFF]) == Err(Invalid({ code: 1007, why: "a close reason that is not UTF-8" }))
expect CloseCode.is_sendable(1012) and CloseCode.is_sendable(3000) and CloseCode.is_sendable(4999)
expect !CloseCode.is_sendable(1004) and !CloseCode.is_sendable(999)
