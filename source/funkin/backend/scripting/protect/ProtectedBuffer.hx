package funkin.backend.scripting.protect;

import funkin.backend.assets.CnezV2;
import funkin.backend.scripting.crypto.ChaCha20;
import funkin.backend.scripting.crypto.ScriptCrypto;
import haxe.io.Bytes;

/**
 * Holds a decrypted mod pack in RAM, so nothing readable lands on disk.
 *
 * Two modes:
 *
 *   plain    the bytes sit there as they are; reading is a copy. Wiped on exit.
 *   wrapped  the whole buffer is a ChaCha20 ciphertext. Reading decrypts only the
 *            requested range, because the keystream is positional: the block containing
 *            the offset is reproduced and the rest is skipped. A scanner finds no zip
 *            header, no file names and no audio.
 *
 * Wrapped mode costs one ChaCha20 pass over the bytes that are actually read; the pack is
 * never decoded as a whole.
 */
class ProtectedBuffer {
	public static inline var KEY_SIZE:Int = 32;
	public static inline var NONCE_SIZE:Int = 12;

	/** ChaCha20 block size; a range read starts on a multiple of it. */
	static inline var BLOCK:Int = 64;

	public var wrapped(default, null):Bool;
	public var length(default, null):Int;

	var data:Bytes;
	var key:Bytes;
	var nonce:Bytes;

	// chunked mode (CNEZ v2): each chunk is verified the first time a read touches it,
	// instead of hashing the whole payload on open
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
			// the buffer handed in is still plaintext; the caller must not touch it after
			// this, and leaving that copy for the collector is what a scanner looks for
			SecureBytes.wipe(bytes);
		}
	}

	/**
	 * Wraps a buffer that is **already** a ChaCha20 ciphertext under `cipherKey`.
	 *
	 * A CNEZ payload arrives here encrypted under the pack's own key, so re-encrypting it
	 * with a fresh session key would be a second full pass for nothing. Reading decrypts
	 * with the pack's keystream instead, and the buffer is never plaintext in memory.
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
	 * Same as `fromCipher`, plus a tag per chunk checked on first read.
	 *
	 * The tags are not verified up front: that would hash the whole payload before the
	 * first asset could load. The header and the table were already covered by the root
	 * tag in `CnezV2.open`, so a swapped tag fails there, not here.
	 */
	public static function fromChunkedCipher(cipher:Bytes, cipherKey:Bytes, cipherNonce:Bytes, chunkSize:Int, tags:Bytes,
			count:Int, macKey:Bytes):ProtectedBuffer {
		var b = fromCipher(cipher, cipherKey, cipherNonce);
		if (chunkSize <= 0 || count <= 0 || tags == null) return b;
		b.chunkSize = chunkSize;
		b.chunkCount = count;
		b.chunkTags = tags;
		b.chunkMac = macKey;
		b.chunkVerified = [for (i in 0...count) false];
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
			verifyChunks(offset, length);
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
	function verifyChunks(offset:Int, length:Int):Void {
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
