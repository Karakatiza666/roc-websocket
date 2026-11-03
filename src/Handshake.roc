import Base64
import Sha1

## The opening handshake (RFC 6455 section 4) for both roles, as pure
## functions over the HTTP head: the text up to and including the empty line.
##
## No extension is offered or accepted (no `permessage-deflate`).
Handshake :: [].{

	## A parsed `ws://` or `wss://` URL. `resource` is the path and query,
	## `/` when the URL has none.
	Url : { secure : Bool, host : Str, port : U16, resource : Str }

	## A header, its name as received.
	Header : (Str, Str)

	## What a client asks for. `key` is 16 random bytes.
	ClientRequest : {
		url : Handshake.Url,
		key : List(U8),
		protocols : List(Str),
		headers : List(Handshake.Header),
	}

	## What the server agreed to. `protocol` is `""` when the server chose no
	## subprotocol.
	Agreed : { protocol : Str, extensions : List(Str), headers : List(Handshake.Header) }

	## A request head a server received, validated as a WebSocket upgrade.
	## `key` is the client's `Sec-WebSocket-Key` text.
	Upgrade : { resource : Str, host : Str, key : Str, protocols : List(Str), headers : List(Handshake.Header) }

	## The GUID that RFC 6455 section 1.3 appends to the key.
	guid : Str
	guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

	## `Sec-WebSocket-Accept` for a `Sec-WebSocket-Key`: Base64 of the SHA-1 of
	## the key and the GUID.
	##
	## ```roc
	## expect Handshake.accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
	## ```
	accept_key : Str -> Str
	accept_key = |key| Base64.encode(Sha1.hash("${key}${Handshake.guid}".to_utf8()))

	## Parse `ws://host[:port][/path][?query]` or `wss://...`. The default port is
	## 80 for `ws` and 443 for `wss`. A fragment (`#...`) is not allowed
	## (RFC 6455 section 3). An IPv6 host is written in brackets.
	parse_url : Str -> Try(Handshake.Url, [BadUrl(Str)])
	parse_url = |text| {
		(secure, rest) =
			if text.with_ascii_lowercased().starts_with("ws://") {
				(Bool.False, text.drop_prefix(text.split_first("://").map_ok(|p| "${p.before}://") ?? ""))
			} else if text.with_ascii_lowercased().starts_with("wss://") {
				(Bool.True, text.drop_prefix(text.split_first("://").map_ok(|p| "${p.before}://") ?? ""))
			} else {
				return Err(BadUrl("the scheme is not ws:// or wss://: ${text}"))
			}
		if rest.contains("#") {
			return Err(BadUrl("a WebSocket URL has no fragment: ${text}"))
		}
		(authority, resource) =
			match rest.split_first("/") {
				Ok({ before, after }) =>
					match before.split_first("?") {
						Ok(q) => (q.before, "/?${q.after}/${after}")
						Err(_) => (before, "/${after}")
					}
				Err(_) =>
					match rest.split_first("?") {
						Ok({ before, after }) => (before, "/?${after}")
						Err(_) => (rest, "/")
					}
			}
		default_port = if (secure) 443 else 80
		(host, port_text) =
			if authority.starts_with("[") {
				match authority.split_first("]") {
					Ok({ before, after }) => ("${before}]", after.drop_prefix(":"))
					Err(_) => return Err(BadUrl("an IPv6 host without `]`: ${text}"))
				}
			} else {
				match authority.split_first(":") {
					Ok({ before, after }) => (before, after)
					Err(_) => (authority, "")
				}
			}
		if host.is_empty() or host.contains("@") {
			return Err(BadUrl("no host, or user info in the URL: ${text}"))
		}
		port =
			if port_text.is_empty() {
				default_port
			} else {
				U16.from_str(port_text).map_err(|_| BadUrl("a bad port `${port_text}`: ${text}"))?
			}
		Ok({ secure, host, port, resource })
	}

	## The request head a client sends: an HTTP/1.1 `GET` with the upgrade
	## headers, then `headers`. The `Host` header has the port when it is not
	## the default one.
	client_request : Handshake.ClientRequest -> Try(Str, [BadKey(U64)])
	client_request = |request| {
		if request.key.len() != 16 {
			return Err(BadKey(request.key.len()))
		}
		url = request.url
		default_port = if (url.secure) 443 else 80
		host = if (url.port == default_port) url.host else "${url.host}:${url.port.to_str()}"
		protocol_lines =
			if request.protocols.is_empty() {
				[]
			} else {
				["Sec-WebSocket-Protocol: ${Str.join_with(request.protocols, ", ")}"]
			}
		lines = [
			"GET ${url.resource} HTTP/1.1",
			"Host: ${host}",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Key: ${Base64.encode(request.key)}",
			"Sec-WebSocket-Version: 13",
		]
			.concat(protocol_lines)
			.concat(request.headers.map(|(name, value)| "${name}: ${value}"))
		Ok("${Str.join_with(lines, "\r\n")}\r\n\r\n")
	}

	## Check the server's response head against the request (RFC 6455
	## section 4.1, the client's checks): status 101, `Upgrade: websocket`,
	## `Connection: Upgrade`, the right `Sec-WebSocket-Accept`, no extension,
	## and a subprotocol only if it is one the client offered.
	check_response : Str, Handshake.ClientRequest -> Try(Handshake.Agreed, [Refused(Str)])
	check_response = |head, request| {
		lines = head_lines(head)
		status = lines.first() ?? ""
		headers = parse_headers(lines.drop_first(1)).map_err(|why| Refused(why))?
		status_parts = status.split_on(" ")
		if status_parts.get(1) != Ok("101") or !(status.starts_with("HTTP/1.1 ")) {
			return Err(Refused("the server answered `${status}`, not 101 Switching Protocols"))
		}
		if !has_token(headers, "upgrade", "websocket") {
			return Err(Refused("no `Upgrade: websocket` in the response"))
		}
		if !has_token(headers, "connection", "upgrade") {
			return Err(Refused("no `Connection: Upgrade` in the response"))
		}
		expected = Handshake.accept_key(Base64.encode(request.key))
		accept = header_value(headers, "sec-websocket-accept")
		if accept != Ok(expected) {
			return Err(Refused("Sec-WebSocket-Accept is `${accept ?? "missing"}`, not `${expected}`"))
		}
		extensions = tokens(headers, "sec-websocket-extensions")
		if !extensions.is_empty() {
			return Err(Refused("the server chose extensions the client did not offer: ${Str.join_with(extensions, ", ")}"))
		}
		protocol = header_value(headers, "sec-websocket-protocol") ?? ""
		if protocol != "" and !request.protocols.contains(protocol) {
			return Err(Refused("the server chose the subprotocol `${protocol}`, which the client did not offer"))
		}
		Ok({ protocol, extensions, headers })
	}

	## Validate a request head as a WebSocket upgrade (RFC 6455 section
	## 4.2.1, the server's checks). `Err(Rejected({ status, why }))` gives
	## the status to answer with (400, 405, or 426 for a wrong version) and
	## `Handshake.rejection` writes that answer.
	parse_upgrade : Str -> Try(Handshake.Upgrade, [Rejected({ status : U16, why : Str })])
	parse_upgrade = |head| {
		lines = head_lines(head)
		request_line = lines.first() ?? ""
		headers = parse_headers(lines.drop_first(1)).map_err(|why| Rejected({ status: 400, why }))?
		(method, resource, version) =
			match request_line.split_on(" ") {
				[m, r, v] => (m, r, v)
				_ => return Err(Rejected({ status: 400, why: "a bad request line `${request_line}`" }))
			}
		if method != "GET" {
			return Err(Rejected({ status: 405, why: "the method is ${method}, not GET" }))
		}
		if version != "HTTP/1.1" {
			return Err(Rejected({ status: 400, why: "the version is ${version}, not HTTP/1.1" }))
		}
		host = header_value(headers, "host").map_err(|_| Rejected({ status: 400, why: "no Host header" }))?
		if !has_token(headers, "upgrade", "websocket") {
			return Err(Rejected({ status: 400, why: "no `Upgrade: websocket`" }))
		}
		if !has_token(headers, "connection", "upgrade") {
			return Err(Rejected({ status: 400, why: "no `Connection: Upgrade`" }))
		}
		if header_value(headers, "sec-websocket-version") != Ok("13") {
			return Err(Rejected({ status: 426, why: "Sec-WebSocket-Version is not 13" }))
		}
		key = header_value(headers, "sec-websocket-key").map_err(|_| Rejected({ status: 400, why: "no Sec-WebSocket-Key" }))?
		match Base64.decode(key) {
			Ok(bytes) if bytes.len() == 16 => {}
			_ => return Err(Rejected({ status: 400, why: "Sec-WebSocket-Key is not 16 bytes of Base64" }))
		}
		Ok({ resource, host, key, protocols: tokens(headers, "sec-websocket-protocol"), headers })
	}

	## The server's 101 response to a valid upgrade, with the subprotocol it
	## chose (`""` for none; it must be one the client offered) and extra
	## headers.
	accept_response : Handshake.Upgrade, Str, List(Handshake.Header) -> Try(Str, [NotOffered(Str)])
	accept_response = |upgrade, protocol, headers| {
		if protocol != "" and !upgrade.protocols.contains(protocol) {
			return Err(NotOffered(protocol))
		}
		protocol_lines = if (protocol == "") [] else ["Sec-WebSocket-Protocol: ${protocol}"]
		lines = [
			"HTTP/1.1 101 Switching Protocols",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Accept: ${Handshake.accept_key(upgrade.key)}",
		]
			.concat(protocol_lines)
			.concat(headers.map(|(name, value)| "${name}: ${value}"))
		Ok("${Str.join_with(lines, "\r\n")}\r\n\r\n")
	}

	## The first protocol of the client's offer that the server supports, or
	## `""`.
	choose_protocol : Handshake.Upgrade, List(Str) -> Str
	choose_protocol = |upgrade, supported| upgrade.protocols.find_first(|p| supported.contains(p)) ?? ""

	## A refusal of an upgrade: the status, `Sec-WebSocket-Version: 13` for a
	## 426, and `why` as the body.
	rejection : U16, Str -> Str
	rejection = |status, why| Handshake.refusal(status, [], why)

	## A response refusing an upgrade: the status line, `Sec-WebSocket-Version: 13`
	## for a 426 (RFC 6455 section 4.4), the extra `headers`, and `body` as
	## plain text. It ends with `Connection: close`.
	refusal : U16, List(Handshake.Header), Str -> Str
	refusal = |status, headers, body| {
		reason = match status {
			400 => "Bad Request"
			401 => "Unauthorized"
			403 => "Forbidden"
			404 => "Not Found"
			405 => "Method Not Allowed"
			408 => "Request Timeout"
			426 => "Upgrade Required"
			429 => "Too Many Requests"
			431 => "Request Header Fields Too Large"
			500 => "Internal Server Error"
			503 => "Service Unavailable"
			_ => "Error"
		}
		version = if (status == 426) ["Sec-WebSocket-Version: 13"] else []
		lines = ["HTTP/1.1 ${status.to_str()} ${reason}"]
			.concat(version)
			.concat(headers.map(|(name, value)| "${name}: ${value}"))
			.concat(["Content-Type: text/plain; charset=utf-8", "Content-Length: ${body.count_utf8_bytes().to_str()}", "Connection: close"])
		"${Str.join_with(lines, "\r\n")}\r\n\r\n${body}"
	}

	## The index just after the first `\r\n\r\n` that starts at or after
	## `from`: the end of an HTTP head and the start of the bytes after it.
	## A reader that appends bytes searches from 3 before the new ones.
	head_end : List(U8), U64 -> Try(U64, [NotFound])
	head_end = |bytes, from| {
		n = bytes.len()
		var $i = from
		while $i + 4 <= n {
			if bytes.sublist({ start: $i, len: 4 }) == [13, 10, 13, 10] {
				return Ok($i + 4)
			}
			$i = $i + 1
		}
		Err(NotFound)
	}

	## How many more bytes a reader can read without passing the end of an
	## HTTP head (`\r\n\r\n`), given the bytes read so far: 0 when `bytes`
	## already ends the head. A reader that reads at most this many bytes
	## never takes bytes of the first frame.
	head_wanted : List(U8) -> U64
	head_wanted = |bytes|
		if bytes.ends_with([13, 10, 13, 10]) {
			0
		} else if bytes.ends_with([13, 10, 13]) {
			1
		} else if bytes.ends_with([13, 10]) {
			2
		} else if bytes.ends_with([13]) {
			3
		} else {
			4
		}
}

head_lines : Str -> List(Str)
head_lines = |head| head.split_on("\r\n").keep_if(|line| !line.is_empty())

## Headers with lowercased names. A line with no colon is an error.
parse_headers : List(Str) -> Try(List((Str, Str)), Str)
parse_headers = |lines|
	lines.map_try(
		|line| match line.split_first(":") {
			Ok({ before, after }) => Ok((before.trim().with_ascii_lowercased(), after.trim()))
			Err(_) => Err("a header line without a colon: `${line}`")
		},
	)

## The value of a header (several lines joined with `, `).
header_value : List((Str, Str)), Str -> Try(Str, [Missing])
header_value = |headers, name| {
	values = headers.keep_if(|(n, _)| n == name).map(|(_, v)| v)
	if (values.is_empty()) Err(Missing) else Ok(Str.join_with(values, ", "))
}

## The comma-separated tokens of a header.
tokens : List((Str, Str)), Str -> List(Str)
tokens = |headers, name| match header_value(headers, name) {
	Ok(value) => value.split_on(",").map(|t| t.trim()).keep_if(|t| !t.is_empty())
	Err(Missing) => []
}

## Whether a header has the token, ASCII case-insensitively.
has_token : List((Str, Str)), Str, Str -> Bool
has_token = |headers, name, token| tokens(headers, name).any(|t| t.with_ascii_lowercased() == token)

# RFC 6455 section 1.3.
expect Handshake.accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

sample_url : Handshake.Url
sample_url = { secure: Bool.False, host: "server.example.com", port: 80, resource: "/chat" }

sample : Handshake.ClientRequest
sample = { url: sample_url, key: "the sample nonce".to_utf8(), protocols: ["chat", "superchat"], headers: [("Origin", "http://example.com")] }

expect
	Handshake.client_request(sample)
		== Ok(
			"GET /chat HTTP/1.1\r\nHost: server.example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: chat, superchat\r\nOrigin: http://example.com\r\n\r\n",
		)
expect Handshake.client_request({ ..sample, key: [1, 2] }) == Err(BadKey(2))
expect Handshake.client_request({ ..sample, url: { ..sample_url, port: 8000 }, protocols: [], headers: [] }) == Ok("GET /chat HTTP/1.1\r\nHost: server.example.com:8000\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")

rfc_response : Str
rfc_response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSec-WebSocket-Protocol: chat\r\n\r\n"

expect Handshake.check_response(rfc_response, sample).map_ok(|a| a.protocol) == Ok("chat")
expect Handshake.check_response(rfc_response.replace_first("s3pP", "XXXX"), sample).is_err()
expect Handshake.check_response(rfc_response.replace_first("101 Switching Protocols", "403 Forbidden"), sample) == Err(Refused("the server answered `HTTP/1.1 403 Forbidden`, not 101 Switching Protocols"))
expect Handshake.check_response(rfc_response.replace_first("chat", "other"), sample) == Err(Refused("the server chose the subprotocol `other`, which the client did not offer"))
expect Handshake.check_response(rfc_response.replace_first("Connection: Upgrade", "connection: keep-alive, UPGRADE"), sample).is_ok()
expect Handshake.check_response(rfc_response.replace_first("Sec-WebSocket-Protocol: chat\r\n", "Sec-WebSocket-Extensions: permessage-deflate\r\n"), sample).is_err()

rfc_request : Str
rfc_request = Handshake.client_request(sample) ?? ""

expect
	match Handshake.parse_upgrade(rfc_request) {
		Ok(u) => u.resource == "/chat" and u.key == "dGhlIHNhbXBsZSBub25jZQ==" and u.protocols == ["chat", "superchat"] and Handshake.choose_protocol(u, ["superchat"]) == "superchat"
		Err(_) => Bool.False
	}
expect
	match Handshake.parse_upgrade(rfc_request) {
		Ok(u) => Handshake.accept_response(u, "chat", []) == Ok(rfc_response)
		Err(_) => Bool.False
	}
expect Handshake.parse_upgrade(rfc_request.replace_first("Version: 13", "Version: 8")) == Err(Rejected({ status: 426, why: "Sec-WebSocket-Version is not 13" }))
expect Handshake.parse_upgrade(rfc_request.replace_first("GET", "POST")) == Err(Rejected({ status: 405, why: "the method is POST, not GET" }))
expect Handshake.parse_upgrade(rfc_request.replace_first("dGhlIHNhbXBsZSBub25jZQ==", "c2hvcnQ=")) == Err(Rejected({ status: 400, why: "Sec-WebSocket-Key is not 16 bytes of Base64" }))

expect Handshake.parse_url("ws://127.0.0.1:8000/rpc") == Ok({ secure: Bool.False, host: "127.0.0.1", port: 8000, resource: "/rpc" })
expect Handshake.parse_url("wss://example.com") == Ok({ secure: Bool.True, host: "example.com", port: 443, resource: "/" })
expect Handshake.parse_url("ws://example.com?x=1") == Ok({ secure: Bool.False, host: "example.com", port: 80, resource: "/?x=1" })
expect Handshake.parse_url("ws://example.com/a/b?x=1") == Ok({ secure: Bool.False, host: "example.com", port: 80, resource: "/a/b?x=1" })
expect Handshake.parse_url("ws://[::1]:9001/") == Ok({ secure: Bool.False, host: "[::1]", port: 9001, resource: "/" })
expect Handshake.parse_url("http://example.com").is_err()
expect Handshake.parse_url("ws://example.com/#frag").is_err()
expect Handshake.parse_url("ws://example.com:99999/").is_err()

expect Handshake.head_wanted("HTTP/1.1 101 OK".to_utf8()) == 4
expect Handshake.head_wanted("x\r\n".to_utf8()) == 2
expect Handshake.head_wanted("x\r\n\r".to_utf8()) == 1
expect Handshake.head_wanted("x\r\n\r\n".to_utf8()) == 0
expect Handshake.head_end("ab\r\n\r\ncd".to_utf8(), 0) == Ok(6)
expect Handshake.head_end("ab\r\n\r\ncd".to_utf8(), 3) == Err(NotFound)
expect Handshake.head_end("ab\r\n".to_utf8(), 0) == Err(NotFound)
expect Handshake.rejection(426, "v") == "HTTP/1.1 426 Upgrade Required\r\nSec-WebSocket-Version: 13\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 1\r\nConnection: close\r\n\r\nv"
expect Handshake.refusal(401, [("WWW-Authenticate", "Bearer")], "") == "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
