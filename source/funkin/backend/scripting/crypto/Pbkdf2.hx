package funkin.backend.scripting.crypto;

import haxe.crypto.Sha256;
import haxe.io.Bytes;

/**
 * PBKDF2, the key derivation both the WinZip AES zip format (HMAC-SHA1, 1000
 * iterations by specification) and the current CNEZ container (HMAC-SHA256) use.
 */
class Pbkdf2 {
	public static inline var WINZIP_ITERATIONS:Int = 1000;

	static inline var SHA_BLOCK:Int = 64;
	static inline var SHA_OUT:Int = 32;

	/**
	 * Derives \`dkLen\` bytes from a password and a salt.
	 */
	public static function deriveSHA1(password:Bytes, salt:Bytes, iterations:Int, dkLen:Int):Bytes {
		if (iterations < 1) throw "Pbkdf2: iterations must be positive";
		if (dkLen < 1) throw "Pbkdf2: dkLen must be positive";

		var hmac = new HmacSha1(password);
		var out = Bytes.alloc(dkLen);
		var written = 0;
		var blockIndex = 1;

		while (written < dkLen) {
			var msg = Bytes.alloc(salt.length + 4);
			msg.blit(0, salt, 0, salt.length);
			msg.set(salt.length, (blockIndex >>> 24) & 0xFF);
			msg.set(salt.length + 1, (blockIndex >>> 16) & 0xFF);
			msg.set(salt.length + 2, (blockIndex >>> 8) & 0xFF);
			msg.set(salt.length + 3, blockIndex & 0xFF);

			var u = hmac.make(msg);
			var t = Bytes.alloc(u.length);
			t.blit(0, u, 0, u.length);

			for (i in 1...iterations) {
				u = hmac.make(u);
				for (j in 0...u.length) t.set(j, t.get(j) ^ u.get(j));
			}

			var n = dkLen - written;
			if (n > t.length) n = t.length;
			out.blit(written, t, 0, n);
			written += n;
			blockIndex++;
		}
		return out;
	}

	/**
	 * PBKDF2 with HMAC-SHA256, the KDF the pack container uses from version 3 on.
	 *
	 * The HMAC pads are built once instead of on every iteration: Hmac.make() re-does
	 * them per call, which is a third of the work at these counts. Measured on hxcpp,
	 * one iteration of the loop below costs ~6.3 us, so 200k of them is about 1.3 s -
	 * paid once per unlock, which is the only time this runs.
	 */
	public static function deriveSHA256(password:Bytes, salt:Bytes, iterations:Int, dkLen:Int):Bytes {
		if (iterations < 1) throw "Pbkdf2: iterations must be positive";
		if (dkLen < 1) throw "Pbkdf2: dkLen must be positive";

		var key = password.length > SHA_BLOCK ? Sha256.make(password) : password;
		var pad = Bytes.alloc(SHA_BLOCK);
		if (key.length > 0) pad.blit(0, key, 0, key.length);
		var innerPad = Bytes.alloc(SHA_BLOCK);
		var outerPad = Bytes.alloc(SHA_BLOCK);
		for (i in 0...SHA_BLOCK) {
			innerPad.set(i, pad.get(i) ^ 0x36);
			outerPad.set(i, pad.get(i) ^ 0x5C);
		}

		var out = Bytes.alloc(dkLen);
		var written = 0;
		var blockIndex = 1;
		// ipad / opad stay in front of both messages; only the last block changes
		var innerMsg = Bytes.alloc(SHA_BLOCK + SHA_OUT);
		var outerMsg = Bytes.alloc(SHA_BLOCK + SHA_OUT);
		innerMsg.blit(0, innerPad, 0, SHA_BLOCK);
		outerMsg.blit(0, outerPad, 0, SHA_BLOCK);

		while (written < dkLen) {
			var first = Bytes.alloc(SHA_BLOCK + salt.length + 4);
			first.blit(0, innerPad, 0, SHA_BLOCK);
			first.blit(SHA_BLOCK, salt, 0, salt.length);
			var at = SHA_BLOCK + salt.length;
			first.set(at, (blockIndex >>> 24) & 0xFF);
			first.set(at + 1, (blockIndex >>> 16) & 0xFF);
			first.set(at + 2, (blockIndex >>> 8) & 0xFF);
			first.set(at + 3, blockIndex & 0xFF);

			// U1 is a full HMAC: inner hash of the padded block, then the outer one
			var firstInner = Sha256.make(first);
			outerMsg.blit(SHA_BLOCK, firstInner, 0, SHA_OUT);
			var u = Sha256.make(outerMsg);
			var t = Bytes.alloc(SHA_OUT);
			t.blit(0, u, 0, SHA_OUT);

			for (i in 1...iterations) {
				innerMsg.blit(SHA_BLOCK, u, 0, SHA_OUT);
				var inner = Sha256.make(innerMsg);
				outerMsg.blit(SHA_BLOCK, inner, 0, SHA_OUT);
				u = Sha256.make(outerMsg);
				for (j in 0...SHA_OUT) t.set(j, t.get(j) ^ u.get(j));
			}

			var n = dkLen - written;
			if (n > SHA_OUT) n = SHA_OUT;
			out.blit(written, t, 0, n);
			written += n;
			blockIndex++;
		}
		return out;
	}
}
