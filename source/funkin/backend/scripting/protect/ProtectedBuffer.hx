package funkin.backend.scripting.protect;

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

	/** Plaintext copy of `[offset, offset + length)`. */
	public function read(offset:Int, length:Int):Bytes {
		if (length <= 0) return Bytes.alloc(0);
		if (offset < 0) offset = 0;
		if (offset + length > this.length) length = this.length - offset;
		if (length <= 0) return Bytes.alloc(0);

		if (!wrapped) return data.sub(offset, length);

		// start on a block boundary so the keystream lines up with the ciphertext
		var start = offset - (offset % BLOCK);
		var head = offset - start;
		var plain = ChaCha20.xorBytes(key, nonce, 1 + Std.int(start / BLOCK), data.sub(start, length + head));
		var out = plain.sub(head, length);
		SecureBytes.wipe(plain);
		return out;
	}

	/** Overwrites the buffer and its keys; the object is unusable afterwards. */
	public function wipe():Void {
		SecureBytes.wipe(data);
		SecureBytes.wipe(key);
		SecureBytes.wipe(nonce);
		length = 0;
		wrapped = false;
	}
}
