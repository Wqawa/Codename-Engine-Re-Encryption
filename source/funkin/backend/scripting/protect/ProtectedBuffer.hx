package funkin.backend.scripting.protect;

import funkin.backend.assets.CnezV2;
import funkin.backend.scripting.crypto.ChaCha20;
import funkin.backend.scripting.crypto.ScriptCrypto;
import haxe.io.Bytes;

/**
 * Holds a decrypted mod pack in RAM, so nothing readable ever lands on disk.
 *
 * Two modes, because the trade is speed against how much a memory scanner gets to
 * see:
 *
 *  - PLAIN    the bytes sit there as they are. Reading a range is a copy, which is
 *             what the file based reader did anyway. The buffer is overwritten when
 *             the game closes.
 *  - WRAPPED  the whole buffer is XORed with a per session ChaCha20 stream. Reading
 *             decrypts just the requested range: the keystream is positional, so the
 *             block containing the offset is reproduced and the rest is skipped. A
 *             scanner finds no zip header, no file names and no audio in the process.
 *
 * Wrapped mode costs one ChaCha20 pass over the bytes that are actually read; the
 * pack is never decoded as a whole.
 */
class ProtectedBuffer {
	public static inline var KEY_SIZE:Int = 32;
	public static inline var NONCE_SIZE:Int = 12;

	/** Size of one ChaCha20 block; a range read starts at a multiple of this. */
	static inline var BLOCK:Int = 64;

	public var wrapped(default, null):Bool;
	public var length(default, null):Int;

	var data:Bytes;
	var key:Bytes;
	var nonce:Bytes;

	// --- chunked mode (CNEZ version 2): the payload is verified per chunk on first
	// --- read instead of all at once, see CnezV2 for why that is affordable
	var chunkSize:Int = 0;
	var chunkCount:Int = 0;
	var chunkTags:Bytes;
	var chunkMac:Bytes;
	var chunkVerified:Array<Bool>;

	/** Set when a chunk failed its tag check; reads return nothing from then on. */
	public var integrityFailed(default, null):Bool = false;

	public function new(bytes:Bytes, wrapped:Bool) {
		this.data = bytes == null ? Bytes.alloc(0) : bytes;
		this.length = this.data.length;
		this.wrapped = wrapped && this.length > 0;
		if (this.wrapped) {
			key = ScriptCrypto.randomBytes(KEY_SIZE);
			nonce = ScriptCrypto.randomBytes(NONCE_SIZE);
			data = ChaCha20.xorBytes(key, nonce, 1, data);
			// The buffer handed in is still the plaintext: it was just copied into the
			// wrapped one above, so overwrite it now rather than leaving it for the
			// collector - that copy is exactly what a memory scanner looks for. Callers
			// must not touch their buffer after this.
			SecureBytes.wipe(bytes);
		}
	}

	/**
	 * Wraps a buffer that is **already** a ChaCha20 ciphertext under `cipherKey`/`cipherNonce`.
	 *
	 * This is the case for a CNEZ pack: its payload leaves `ModPackCrypto` as ciphertext
	 * already, under the key derived from the pack's salt. Re-encrypting it with a fresh
	 * session key (what `new ProtectedBuffer(plain, true)` does) therefore cost a second
	 * full pass over the whole pack and bought nothing - the bytes in RAM were secret
	 * before that pass and after it. Reading decrypts a range with the pack's own
	 * keystream instead, so the pass never happens and the buffer is never plaintext
	 * in memory either.
	 *
	 * The caller keeps ownership of `cipher` and must not touch it afterwards.
	 */
	public static function fromCipher(cipher:Bytes, cipherKey:Bytes, cipherNonce:Bytes):ProtectedBuffer {
		var b = new ProtectedBuffer(cipher, false);
		if (b.length > 0) {
			b.wrapped = true;
			b.key = cipherKey;
			b.nonce = cipherNonce;
		}
		return b;
	}

	/**
	 * Same as `fromCipher`, plus a tag per chunk that is checked the first time a read
	 * touches that chunk (CNEZ version 2).
	 *
	 * Why not verify everything up front: the whole pack would have to be hashed
	 * before the first asset could load, which is exactly the cost version 2 exists to
	 * avoid. The header and this table were already checked by `CnezV2.open` - the root
	 * tag covers every entry here, so a swapped tag fails there, not here.
	 */
	public static function fromChunkedCipher(cipher:Bytes, cipherKey:Bytes, cipherNonce:Bytes, size:Int, tags:Bytes, count:Int,
			macKey:Bytes):ProtectedBuffer {
		var b = fromCipher(cipher, cipherKey, cipherNonce);
		if (size <= 0 || count <= 0 || tags == null) return b;
		b.chunkSize = size;
		b.chunkCount = count;
		b.chunkTags = tags;
		b.chunkMac = macKey;
		b.chunkVerified = [];
		for (i in 0...count) b.chunkVerified.push(false);
		return b;
	}

	/** Plaintext copy of `[offset, offset + length)`. */
	public function read(offset:Int, length:Int):Bytes {
		if (length <= 0) return Bytes.alloc(0);
		if (offset < 0) offset = 0;
		if (offset + length > this.length) length = this.length - offset;
		if (length <= 0) return Bytes.alloc(0);
		if (integrityFailed) return Bytes.alloc(0);

		if (chunkSize > 0) {
			ensureChunks(offset, length);
			if (integrityFailed) return Bytes.alloc(0);
		}

		if (!wrapped) return data.sub(offset, length);

		// start on a block boundary so the keystream lines up with the ciphertext
		var start = offset - (offset % BLOCK);
		var head = offset - start;
		var plain = ChaCha20.xorBytes(key, nonce, 1 + Std.int(start / BLOCK), data.sub(start, length + head));
		var out = plain.sub(head, length);
		SecureBytes.wipe(plain);
		return out;
	}

	/** Verifies every chunk the range `[offset, offset + length)` touches, once each. */
	function ensureChunks(offset:Int, length:Int):Void {
		var first = Std.int(offset / chunkSize);
		var last = Std.int((offset + length - 1) / chunkSize);
		if (last >= chunkCount) last = chunkCount - 1;
		if (first < 0) first = 0;

		for (i in first...last + 1) {
			if (chunkVerified[i]) continue;
			var start = i * chunkSize;
			var len = chunkSize;
			if (start + len > data.length) len = data.length - start;
			var chunk = data.sub(start, len);
			var expected = chunkTags.sub(i * CnezV2.TAG_SIZE, CnezV2.TAG_SIZE);
			if (!CnezV2.same(ScriptCrypto.hmacTag(chunkMac, chunk), expected)) {
				integrityFailed = true;
				Logs.error('A mod pack chunk ($i of $chunkCount) failed its integrity check; '
					+ 'the pack was modified after it was packed. Reads stop here.');
				return;
			}
			chunkVerified[i] = true;
		}
	}

	/** Overwrites the buffer and its keys; the object is unusable afterwards. */
	public function wipe():Void {
		SecureBytes.wipe(data);
		SecureBytes.wipe(key);
		SecureBytes.wipe(nonce);
		SecureBytes.wipe(chunkTags);
		SecureBytes.wipe(chunkMac);
		if (chunkVerified != null) for (i in 0...chunkVerified.length) chunkVerified[i] = false;
		length = 0;
		chunkSize = 0;
		chunkCount = 0;
		wrapped = false;
	}
}
