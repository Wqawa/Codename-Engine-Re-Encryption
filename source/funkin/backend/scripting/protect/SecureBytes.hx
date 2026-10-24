package funkin.backend.scripting.protect;

import haxe.io.Bytes;

class SecureBytes {
	/** Number of overwrite passes used when a secret buffer is released. */
	static inline var WIPE_PASSES:Int = 2;

	/**
	 * Overwrites a secret buffer. Haxe cannot guarantee the compiler keeps the
	 * writes (a dead store is legal to remove), so a value is read back and a
	 * cheap branch keeps the reads alive.
	 */
	public static function wipe(b:Bytes):Void {
		if (b == null || b.length == 0) return;
		for (pass in 0...WIPE_PASSES) b.fill(0, b.length, 0);
		var sanity = 0;
		for (i in 0...b.length) sanity |= b.get(i);
		if (sanity != 0) b.fill(0, b.length, 0);
	}

	public static function wipeInts(values:Array<Int>):Void {
		if (values == null) return;
		for (i in 0...values.length) values[i] = 0;
	}

	public static function equalConstantTime(a:Bytes, b:Bytes):Bool {
		if (a == null || b == null || a.length != b.length) return false;
		var diff = 0;
		for (i in 0...a.length) diff |= a.get(i) ^ b.get(i);
		return diff == 0;
	}

	/**
	 * Circular bit rotation of the whole buffer (left by "bits"). Used by the
	 * offset layer: the payload is no longer byte aligned to whatever the file
	 * header says, so naive extraction yields garbage.
	 */
	public static function rotateBits(b:Bytes, bits:Int):Bytes {
		if (b == null || b.length == 0) return b;
		var total = b.length * 8;
		var k = bits % total;
		if (k < 0) k += total;
		if (k == 0) return b.sub(0, b.length);

		var n = b.length;
		var byteShift = k >>> 3;
		var bitShift = k & 7;
		var out = Bytes.alloc(n);
		for (i in 0...n) {
			var a = b.get((i + byteShift) % n);
			var c = b.get((i + byteShift + 1) % n);
			var v = bitShift == 0 ? a : ((a << bitShift) | (c >>> (8 - bitShift))) & 0xFF;
			out.set(i, v);
		}
		return out;
	}

	public static function concat(a:Bytes, b:Bytes):Bytes {
		if (a == null) return b;
		if (b == null) return a;
		var out = Bytes.alloc(a.length + b.length);
		out.blit(0, a, 0, a.length);
		out.blit(a.length, b, 0, b.length);
		return out;
	}

	public static function randomInt():Int {
		var b = funkin.backend.scripting.crypto.ScriptCrypto.randomBytes(4);
		var v = b.get(0) | (b.get(1) << 8) | (b.get(2) << 16) | (b.get(3) << 24);
		return v == 0 ? 0x13579BDF : v;
	}
}
