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

	public static function xorBytes(key:Bytes, nonce:Bytes, counter:Int, input:Bytes):Bytes {
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
		while (offset < input.length) {
			state[12] = ctr;
			blockFunction(state, block);
			var n = input.length - offset;
			if (n > 64) n = 64;
			for (i in 0...n)
				output.set(offset + i, input.get(offset + i) ^ block.get(i));
			offset += n;
			ctr++;
		}
		return output;
	}

	static function readLE(b:Bytes, o:Int):Int {
		return (b.get(o)) | (b.get(o + 1) << 8) | (b.get(o + 2) << 16) | (b.get(o + 3) << 24);
	}

	static inline function rotl(v:Int, n:Int):Int {
		return (v << n) | (v >>> (32 - n));
	}

	static inline function qr(x:Array<Int>, a:Int, b:Int, c:Int, d:Int):Void {
		x[a] += x[b];
		x[d] = rotl(x[d] ^ x[a], 16);
		x[c] += x[d];
		x[b] = rotl(x[b] ^ x[c], 12);
		x[a] += x[b];
		x[d] = rotl(x[d] ^ x[a], 8);
		x[c] += x[d];
		x[b] = rotl(x[b] ^ x[c], 7);
	}

	static function blockFunction(state:Array<Int>, out:Bytes):Void {
		var x = state.copy();
		for (r in 0...10) {
			qr(x, 0, 4, 8, 12);
			qr(x, 1, 5, 9, 13);
			qr(x, 2, 6, 10, 14);
			qr(x, 3, 7, 11, 15);
			qr(x, 0, 5, 10, 15);
			qr(x, 1, 6, 11, 12);
			qr(x, 2, 7, 8, 13);
			qr(x, 3, 4, 9, 14);
		}
		for (i in 0...16) {
			var v = x[i] + state[i];
			out.set(i * 4, v & 0xFF);
			out.set(i * 4 + 1, (v >>> 8) & 0xFF);
			out.set(i * 4 + 2, (v >>> 16) & 0xFF);
			out.set(i * 4 + 3, (v >>> 24) & 0xFF);
		}
	}
}
