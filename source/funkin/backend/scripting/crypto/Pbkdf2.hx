package funkin.backend.scripting.crypto;

import haxe.io.Bytes;

/**
 * PBKDF2 with HMAC-SHA1, the key derivation the WinZip AES zip format uses
 * (1000 iterations by specification).
 */
class Pbkdf2 {
	public static inline var WINZIP_ITERATIONS:Int = 1000;

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
}
