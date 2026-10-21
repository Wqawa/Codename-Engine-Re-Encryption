package funkin.backend.scripting.crypto;

import haxe.io.Bytes;

/**
 * Pure Haxe implementation of the ChaCha20 stream cipher (RFC 8439).
 * 32-byte key, 12-byte nonce, 32-bit block counter.
 * Used by `ScriptCrypto` to encrypt script payloads.
 */
class ChaCha20 {
	static inline var SIGMA0:Int = 0x61707865; // "expa"
	static inline var SIGMA1:Int = 0x3320646E; // "nd 3"
	static inline var SIGMA2:Int = 0x79622D32; // "2-by"
	static inline var SIGMA3:Int = 0x6B206574; // "te k"

	public static function xorBytes(key:Bytes, nonce:Bytes, counter:Int, input:Bytes, ?onProgress:Float->Void):Bytes {
		if (key == null || key.length < 32)
			throw "ChaCha20: key must be at least 32 bytes";
		if (nonce == null || nonce.length < 12)
			throw "ChaCha20: nonce must be at least 12 bytes";

		var state = new Array<Int>();
		for (i in 0...16) state.push(0);

		state[0] = SIGMA0;
		state[1] = SIGMA1;
		state[2] = SIGMA2;
		state[3] = SIGMA3;
		for (i in 0...8) state[4 + i] = readLE(key, i * 4);
		state[12] = 0;
		state[13] = readLE(nonce, 0);
		state[14] = readLE(nonce, 4);
		state[15] = readLE(nonce, 8);

		var output = Bytes.alloc(input.length);
		var block = Bytes.alloc(64);
		var offset = 0;
		var ctr = counter;
		var total = input.length;
		var step = 0;
		while (offset < total) {
			state[12] = ctr;
			blockFunction(state, block);
			var n = total - offset;
			if (n > 64) n = 64;
			for (i in 0...n)
				output.set(offset + i, input.get(offset + i) ^ block.get(i));
			offset += n;
			ctr++;
			// reporting every few blocks keeps the callback cheap on big payloads
			if (onProgress != null && ++step % 2048 == 0) onProgress(offset / total);
		}
		if (onProgress != null) onProgress(1.0);
		return output;
	}

	static function readLE(b:Bytes, o:Int):Int {
		return (b.get(o)) | (b.get(o + 1) << 8) | (b.get(o + 2) << 16) | (b.get(o + 3) << 24);
	}

	static inline function rotl(v:Int, n:Int):Int {
		return (v << n) | (v >>> (32 - n));
	}

	/**
	 * One 64-byte ChaCha20 block. The 16 working words live in local variables so
	 * that hashing a large payload does not allocate an Array per 64-byte block
	 * (a 132 MB mod pack is roughly two million blocks).
	 */
	static function blockFunction(state:Array<Int>, out:Bytes):Void {
		var s0 = state[0], s1 = state[1], s2 = state[2], s3 = state[3];
		var s4 = state[4], s5 = state[5], s6 = state[6], s7 = state[7];
		var s8 = state[8], s9 = state[9], s10 = state[10], s11 = state[11];
		var s12 = state[12], s13 = state[13], s14 = state[14], s15 = state[15];
		var x0 = s0, x1 = s1, x2 = s2, x3 = s3;
		var x4 = s4, x5 = s5, x6 = s6, x7 = s7;
		var x8 = s8, x9 = s9, x10 = s10, x11 = s11;
		var x12 = s12, x13 = s13, x14 = s14, x15 = s15;

		for (r in 0...10) {
			// column rounds
			x0 += x4; x12 = rotl(x12 ^ x0, 16); x8 += x12; x4 = rotl(x4 ^ x8, 12);
			x0 += x4; x12 = rotl(x12 ^ x0, 8); x8 += x12; x4 = rotl(x4 ^ x8, 7);
			x1 += x5; x13 = rotl(x13 ^ x1, 16); x9 += x13; x5 = rotl(x5 ^ x9, 12);
			x1 += x5; x13 = rotl(x13 ^ x1, 8); x9 += x13; x5 = rotl(x5 ^ x9, 7);
			x2 += x6; x14 = rotl(x14 ^ x2, 16); x10 += x14; x6 = rotl(x6 ^ x10, 12);
			x2 += x6; x14 = rotl(x14 ^ x2, 8); x10 += x14; x6 = rotl(x6 ^ x10, 7);
			x3 += x7; x15 = rotl(x15 ^ x3, 16); x11 += x15; x7 = rotl(x7 ^ x11, 12);
			x3 += x7; x15 = rotl(x15 ^ x3, 8); x11 += x15; x7 = rotl(x7 ^ x11, 7);
			// diagonal rounds
			x0 += x5; x15 = rotl(x15 ^ x0, 16); x10 += x15; x5 = rotl(x5 ^ x10, 12);
			x0 += x5; x15 = rotl(x15 ^ x0, 8); x10 += x15; x5 = rotl(x5 ^ x10, 7);
			x1 += x6; x12 = rotl(x12 ^ x1, 16); x11 += x12; x6 = rotl(x6 ^ x11, 12);
			x1 += x6; x12 = rotl(x12 ^ x1, 8); x11 += x12; x6 = rotl(x6 ^ x11, 7);
			x2 += x7; x13 = rotl(x13 ^ x2, 16); x8 += x13; x7 = rotl(x7 ^ x8, 12);
			x2 += x7; x13 = rotl(x13 ^ x2, 8); x8 += x13; x7 = rotl(x7 ^ x8, 7);
			x3 += x4; x14 = rotl(x14 ^ x3, 16); x9 += x14; x4 = rotl(x4 ^ x9, 12);
			x3 += x4; x14 = rotl(x14 ^ x3, 8); x9 += x14; x4 = rotl(x4 ^ x9, 7);
		}

		x0 += s0; x1 += s1; x2 += s2; x3 += s3;
		x4 += s4; x5 += s5; x6 += s6; x7 += s7;
		x8 += s8; x9 += s9; x10 += s10; x11 += s11;
		x12 += s12; x13 += s13; x14 += s14; x15 += s15;

		writeLE(out, 0, x0); writeLE(out, 4, x1); writeLE(out, 8, x2); writeLE(out, 12, x3);
		writeLE(out, 16, x4); writeLE(out, 20, x5); writeLE(out, 24, x6); writeLE(out, 28, x7);
		writeLE(out, 32, x8); writeLE(out, 36, x9); writeLE(out, 40, x10); writeLE(out, 44, x11);
		writeLE(out, 48, x12); writeLE(out, 52, x13); writeLE(out, 56, x14); writeLE(out, 60, x15);
	}

	static inline function writeLE(b:Bytes, o:Int, v:Int):Void {
		b.set(o, v & 0xFF);
		b.set(o + 1, (v >>> 8) & 0xFF);
		b.set(o + 2, (v >>> 16) & 0xFF);
		b.set(o + 3, (v >>> 24) & 0xFF);
	}
}
