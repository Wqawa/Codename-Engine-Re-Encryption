package funkin.backend.scripting.bytecode;

import funkin.backend.scripting.crypto.ChaCha20;
import funkin.backend.scripting.crypto.ScriptCrypto;
import funkin.backend.scripting.protect.Rng;
import funkin.backend.scripting.protect.SecureBytes;
import haxe.io.Bytes;

/**
 * The protected script container ("CNX2").
 *
 * A script can be protected by up to four independent layers, chosen per file:
 *
 *  - KEY     ChaCha20 encryption plus an HMAC-SHA256 tag (needs the password /
 *            key token at runtime);
 *  - VM      the source is compiled to bytecode and every opcode byte is
 *            replaced by a file specific number (see OpMap);
 *  - OFFSET  the whole payload is rotated by a random number of bits, so it is
 *            not byte aligned with whatever the reader expects;
 *  - SPLIT   the payload is cut into N pieces, the pieces are shuffled and
 *            random padding is inserted between them.
 *
 * The layers are applied in this order when packing:
 *   payload -> [SPLIT] -> [OFFSET] is applied last, key+tag first, i.e.
 *   encrypt -> split -> rotate. Unpacking undoes them in reverse order.
 *
 * Everything the reader needs (except the key) lives in the fixed 64 byte
 * header. Nothing here replaces a real AEAD; the tag detects corruption and
 * tampering, it is not a substitute for a hardened native protector.
 */
class ScriptContainer {
	public static inline var EXTENSION:String = "hxb";

	public static inline var VERSION:Int = 2;
	/**
	 * Revision of the bytecode compiler that produced a container, stored in header byte 10.
	 * Revision 0 are all packs written before this byte existed: their compiler dropped the
	 * map type hint on empty literals ("var m:Map<String, T> = []" became an Array), which
	 * makes the VM die with "Null Function Pointer". Such packs are run from their source
	 * fallback instead. Bump this whenever the emitted bytecode semantics change.
	 */
	public static inline var CODE_REV:Int = 1;
	public static inline var HEADER_SIZE:Int = 64;
	public static inline var TAG_SIZE:Int = 32;
	public static inline var SALT_SIZE:Int = 16;
	public static inline var NONCE_SIZE:Int = 12;
	public static inline var MAX_CHAFF:Int = 24;

	public static inline var FLAG_KEY:Int = 1;
	public static inline var FLAG_VM:Int = 2;
	public static inline var FLAG_OFFSET:Int = 4;
	public static inline var FLAG_SPLIT:Int = 8;
	/**
	 * Bytecode plus a copy of the source, run when the VM cannot. The copy sits inside
	 * the payload, so it is only encrypted when FLAG_KEY is set as well.
	 *
	 * Writer side is reachable only through PackOptions.fallbackSource, which the editor
	 * deliberately leaves off: the protection modes are exclusive now, and a VM pack has
	 * no key to seal a source copy with. The reader keeps honouring the flag because
	 * containers built before that change still carry it, and ignoring it would make
	 * those scripts fall back to nothing at all.
	 */
	public static inline var FLAG_FALLBACK:Int = 16;

	static inline var KNOWN_FLAGS:Int = FLAG_KEY | FLAG_VM | FLAG_OFFSET | FLAG_SPLIT | FLAG_FALLBACK;

	public static inline var MODE_SOURCE:Int = 0;
	public static inline var MODE_BYTECODE:Int = 1;

	public static inline var MIN_OFFSET_BITS:Int = 1;
	public static inline var MAX_OFFSET_BITS:Int = 16;
	public static inline var MIN_SPLIT:Int = 2;
	public static inline var MAX_SPLIT:Int = 16;

	static var MAGIC:Array<Int> = [0x43, 0x4E, 0x58, 0x32]; // "CNX2"

	public static function isContainer(data:Bytes):Bool {
		if (data == null || data.length < HEADER_SIZE) return false;
		for (i in 0...4)
			if (data.get(i) != MAGIC[i]) return false;
		return true;
	}

	/** Human readable layer summary, used by the editor. */
	public static function describe(data:Bytes):String {
		if (!isContainer(data)) return "not a protected script";
		var flags = data.get(5);
		var parts:Array<String> = [];
		if (flags & FLAG_VM != 0) parts.push("VM bytecode");
		if (flags & FLAG_KEY != 0) parts.push("key");
		if (flags & FLAG_OFFSET != 0) parts.push("offset " + data.get(6) + " bit");
		if (flags & FLAG_SPLIT != 0) parts.push("split x" + data.get(7));
		if (flags & FLAG_FALLBACK != 0) parts.push("source fallback");
		return "CNX2 v" + data.get(4) + (parts.length == 0 ? " (no layer)" : " (" + parts.join(" + ") + ")");
	}

	// ------------------------------------------------------------------ packing

	public static function pack(source:String, ?fileName:String = "script.hx", ?opts:PackOptions):Bytes {
		if (opts == null) opts = {};
		if (source == null) source = "";

		var flags:Int = 0;
		var opcodeSeed:Int = 0;
		var payload:Bytes;

		// the layer switches of PackOptions used to be ignored here, so a caller that
		// asked for a key/offset/split still got a plain container (only the editor's
		// packBytes path applied them). Keep them together with the VM flag below.
		if (opts.useKey) flags |= FLAG_KEY;
		if (opts.useOffset) flags |= FLAG_OFFSET;
		if (opts.useSplit) flags |= FLAG_SPLIT;

		if (opts.useVM) {
			var seed = SecureBytes.randomInt();
			var map = new OpMap(seed);
			var chunk = Compiler.compile(funkin.backend.scripting.HScript.initParser(), source, fileName, map);
			var code = chunk.serialize();
			if (opts.fallbackSource) {
				var fallback = Bytes.ofString(source);
				var buf = Bytes.alloc(4 + code.length + fallback.length);
				buf.set(0, code.length & 0xFF);
				buf.set(1, (code.length >>> 8) & 0xFF);
				buf.set(2, (code.length >>> 16) & 0xFF);
				buf.set(3, (code.length >>> 24) & 0xFF);
				buf.blit(4, code, 0, code.length);
				buf.blit(4 + code.length, fallback, 0, fallback.length);
				payload = buf;
				flags |= FLAG_FALLBACK;
			} else {
				payload = code;
			}
			flags |= FLAG_VM;
			opcodeSeed = seed;
		} else {
			payload = Bytes.ofString(source);
		}

		return build(payload, flags, opcodeSeed, opts);
	}

	/**
	 * Wraps an already prepared payload (bytecode chunk or source text).
	 * Separated from pack() so the editor can reuse the exact same code path for
	 * a precompiled chunk and for plain source.
	 */
	public static function packBytes(payload:Bytes, flags:Int, ?opts:PackOptions):Bytes {
		return build(payload, flags, 0, opts);
	}

	static function build(payload:Bytes, flags:Int, opcodeSeed:Int, ?opts:PackOptions, ?codeRev:Int):Bytes {
		if (opts == null) opts = {};

		var salt = ScriptCrypto.randomBytes(SALT_SIZE);
		var nonce = ScriptCrypto.randomBytes(NONCE_SIZE);
		var splitSeed = SecureBytes.randomInt();

		var body:Bytes;
		if (flags & FLAG_KEY != 0) {
			var password = opts.pass != null ? opts.pass : ScriptCrypto.getPassword(opts.scriptName);
			var keys = ScriptCrypto.deriveKeys(ScriptCrypto.resolveKeyValue(password == null ? "" : password), salt);
			var cipher = ChaCha20.xorBytes(keys.enc, nonce, 1, payload);
			var tag = ScriptCrypto.hmacTag(keys.mac, cipher);
			body = SecureBytes.concat(cipher, tag);
			SecureBytes.wipe(keys.enc);
			SecureBytes.wipe(keys.mac);
		} else {
			body = SecureBytes.concat(payload, ScriptCrypto.sha256(payload));
		}

		var splitCount = 1;
		if (flags & FLAG_SPLIT != 0) {
			splitCount = opts.splitCount == null ? 4 : opts.splitCount;
			var maxParts = Std.int(body.length / 8);
			if (splitCount > MAX_SPLIT) splitCount = MAX_SPLIT;
			if (splitCount > maxParts) splitCount = maxParts;
			if (splitCount < MIN_SPLIT) splitCount = 1;
			if (splitCount < 2) flags &= ~FLAG_SPLIT;
		}
		if (splitCount >= 2) body = splitBody(body, splitSeed, splitCount);

		var offsetBits = 0;
		var offset = 0;
		if (flags & FLAG_OFFSET != 0) {
			offsetBits = opts.offsetBits == null ? 8 : opts.offsetBits;
			if (offsetBits < MIN_OFFSET_BITS) offsetBits = MIN_OFFSET_BITS;
			if (offsetBits > MAX_OFFSET_BITS) offsetBits = MAX_OFFSET_BITS;
			var maxOffset = (1 << offsetBits) - 1;
			var rng = new Rng(splitSeed ^ 0x0BADF00D);
			offset = 1 + rng.range(maxOffset);
			body = SecureBytes.rotateBits(body, offset);
		}

		var header = Bytes.alloc(HEADER_SIZE);
		for (i in 0...4) header.set(i, MAGIC[i]);
		header.set(4, VERSION);
		header.set(5, flags);
		header.set(6, offsetBits);
		header.set(7, splitCount);
		header.set(8, offset & 0xFF);
		header.set(9, (offset >>> 8) & 0xFF);
		header.set(10, codeRev == null ? CODE_REV : codeRev);
		putI32(header, 12, opcodeSeed);
		putI32(header, 16, splitSeed);
		header.blit(20, salt, 0, salt.length);
		header.blit(36, nonce, 0, nonce.length);
		putI32(header, 48, payload.length);
		// unused header tail: random bytes, so two containers of the same script
		// do not share a constant 12 byte run
		var pad = header.sub(52, 12);
		new Rng(opcodeSeed ^ splitSeed).fill(pad);
		header.blit(52, pad, 0, pad.length);

		return SecureBytes.concat(header, body);
	}

	// ---------------------------------------------------------------- unpacking

	public static function unpack(data:Bytes, ?pass:String, ?scriptName:String):PackedScript {
		if (!isContainer(data)) throw "Script container: bad magic (not a CNX2 file)";

		var version = data.get(4);
		if (version != VERSION) throw "Script container: unsupported version " + version;

		var flags = data.get(5);
		if (flags & ~KNOWN_FLAGS != 0) throw "Script container: unknown layers 0x" + StringTools.hex(flags);

		var codeRev = data.get(10);

		var offsetBits = data.get(6);
		var splitCount = data.get(7);
		var offset = data.get(8) | (data.get(9) << 8);
		var opcodeSeed = getI32(data, 12);
		var splitSeed = getI32(data, 16);
		var salt = data.sub(20, SALT_SIZE);
		var nonce = data.sub(36, NONCE_SIZE);
		var payloadLen = getI32(data, 48);

		var body = data.sub(HEADER_SIZE, data.length - HEADER_SIZE);

		if (flags & FLAG_OFFSET != 0 && offset > 0)
			body = SecureBytes.rotateBits(body, body.length * 8 - (offset % (body.length * 8)));

		var contentLen = payloadLen + TAG_SIZE;
		if (splitCount >= 2) {
			body = joinBody(body, splitSeed, splitCount, contentLen);
		}
		if (body.length != contentLen)
			throw "Script container: corrupted (payload length mismatch)";

		var content = body.sub(0, contentLen - TAG_SIZE);
		var tag = body.sub(contentLen - TAG_SIZE, TAG_SIZE);

		var payload:Bytes;
		if (flags & FLAG_KEY != 0) {
			var password = pass != null ? pass : ScriptCrypto.getPassword(scriptName);
			var keys = ScriptCrypto.deriveKeys(ScriptCrypto.resolveKeyValue(password == null ? "" : password), salt);
			var expected = ScriptCrypto.hmacTag(keys.mac, content);
			if (!SecureBytes.equalConstantTime(expected, tag)) {
				SecureBytes.wipe(keys.enc);
				SecureBytes.wipe(keys.mac);
				throw "Script container: wrong key or corrupted file";
			}
			payload = ChaCha20.xorBytes(keys.enc, nonce, 1, content);
			SecureBytes.wipe(keys.enc);
			SecureBytes.wipe(keys.mac);
		} else {
			var expected = ScriptCrypto.sha256(content);
			if (!SecureBytes.equalConstantTime(expected, tag))
				throw "Script container: corrupted file";
			payload = content.sub(0, content.length);
		}

		var result:PackedScript = {flags: flags, mode: MODE_SOURCE, opcodeSeed: opcodeSeed, codeRev: codeRev, map: null};
		if (flags & FLAG_VM != 0) {
			var map = new OpMap(opcodeSeed);
			var chunkLen = payload.length;
			var fallback:Bytes = null;
			if (flags & FLAG_FALLBACK != 0) {
				if (payload.length < 4) throw "Script container: corrupted bytecode length";
				chunkLen = getI32(payload, 0);
				if (chunkLen < 0 || 4 + chunkLen > payload.length)
					throw "Script container: corrupted bytecode block";
				fallback = payload.sub(4 + chunkLen, payload.length - 4 - chunkLen);
			}
			result.mode = MODE_BYTECODE;
			result.chunk = Chunk.deserialize(payload.sub(flags & FLAG_FALLBACK != 0 ? 4 : 0, chunkLen));
			result.map = map;
			if (fallback != null) result.source = fallback.toString();
		} else {
			result.source = payload.toString();
		}

		SecureBytes.wipe(payload);
		return result;
	}

	// ------------------------------------------------------------------ layers

	static function splitBody(body:Bytes, seed:Int, count:Int):Bytes {
		var n = body.length;
		var rng = new Rng(seed);
		var cuts = cutPoints(n, count, rng);
		var order = permutation(count, rng);

		var chaffLens:Array<Int> = [];
		for (k in 0...count) chaffLens.push(1 + rng.range(MAX_CHAFF));

		var total = n;
		for (l in chaffLens) total += l;

		var chaff = new Rng(seed ^ 0x2545F491);
		var out = Bytes.alloc(total);
		var p = 0;
		for (k in 0...count) {
			var len = chaffLens[k];
			var noise = Bytes.alloc(len);
			chaff.fill(noise);
			out.blit(p, noise, 0, len);
			p += len;
			var idx = order[k];
			var size = cuts[idx + 1] - cuts[idx];
			out.blit(p, body, cuts[idx], size);
			p += size;
		}
		return out;
	}

	static function joinBody(assembled:Bytes, seed:Int, count:Int, contentLen:Int):Bytes {
		var rng = new Rng(seed);
		var cuts = cutPoints(contentLen, count, rng);
		var order = permutation(count, rng);

		var chaffLens:Array<Int> = [];
		for (k in 0...count) chaffLens.push(1 + rng.range(MAX_CHAFF));

		var total = contentLen;
		for (l in chaffLens) total += l;
		if (assembled.length != total)
			throw "Script container: corrupted split payload";

		var out = Bytes.alloc(contentLen);
		var p = 0;
		for (k in 0...count) {
			p += chaffLens[k];
			var idx = order[k];
			var size = cuts[idx + 1] - cuts[idx];
			out.blit(cuts[idx], assembled, p, size);
			p += size;
		}
		return out;
	}

	/** Strictly increasing cut points 0 = cuts[0] < ... < cuts[count] = n. */
	static function cutPoints(n:Int, count:Int, rng:Rng):Array<Int> {
		var cuts:Array<Int> = [0];
		for (i in 1...count) {
			var lo = cuts[i - 1] + 1;
			var hi = n - (count - i);
			cuts.push(lo + rng.range(hi - lo + 1));
		}
		cuts.push(n);
		return cuts;
	}

	static function permutation(count:Int, rng:Rng):Array<Int> {
		var order:Array<Int> = [];
		for (i in 0...count) order.push(i);
		var i = count - 1;
		while (i > 0) {
			var j = rng.range(i + 1);
			var t = order[i];
			order[i] = order[j];
			order[j] = t;
			i--;
		}
		return order;
	}

	// ------------------------------------------------------------------ helpers

	static inline function putI32(b:Bytes, pos:Int, v:Int):Void {
		b.set(pos, v & 0xFF);
		b.set(pos + 1, (v >>> 8) & 0xFF);
		b.set(pos + 2, (v >>> 16) & 0xFF);
		b.set(pos + 3, (v >>> 24) & 0xFF);
	}

	static inline function getI32(b:Bytes, pos:Int):Int {
		return b.get(pos) | (b.get(pos + 1) << 8) | (b.get(pos + 2) << 16) | (b.get(pos + 3) << 24);
	}
}

/** Layers to apply while packing. Every field is optional. */
typedef PackOptions = {
	?useKey:Bool,
	?useVM:Bool,
	?useOffset:Bool,
	?offsetBits:Int,
	?useSplit:Bool,
	?splitCount:Int,
	?fallbackSource:Bool,
	?pass:String,
	?scriptName:String
}

typedef PackedScript = {
	var flags:Int;
	var mode:Int;
	var opcodeSeed:Int;
	/** Bytecode compiler revision that produced the container, 0 for legacy packs. */
	var codeRev:Int;
	var ?chunk:Chunk;
	var ?source:String;
	var ?map:OpMap;
}
