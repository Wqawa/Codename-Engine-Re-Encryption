package funkin.backend.scripting.crypto;

import haxe.io.Bytes;

/**
 * AES block cipher (128 / 192 / 256 bit keys) and the counter mode WinZip uses
 * for its "AES-256" zip encryption.
 *
 * The rounds run on four 32 bit words with the usual T-tables, which keeps a
 * 100 MB zip entry at a sane speed; only the forward direction is implemented,
 * because CTR mode - like any stream cipher - encrypts and decrypts with the
 * same keystream.
 */
class Aes {
	static var SBOX:Array<Int>;
	static var RCON:Array<Int>;

	/** MixColumns tables: row r, contribution of one byte to the four output bytes. */
	static var U0:Array<Int>;
	static var U1:Array<Int>;
	static var U2:Array<Int>;
	static var U3:Array<Int>;

	/** Last round tables (no MixColumns). */
	static var F0:Array<Int>;
	static var F1:Array<Int>;
	static var F2:Array<Int>;
	static var F3:Array<Int>;

	static inline function m2(a:Int):Int
		return ((a << 1) ^ ((a & 0x80) != 0 ? 0x1B : 0)) & 0xFF;

	static inline function m3(a:Int):Int
		return m2(a) ^ a;

	/** GF(2^8) multiply, reduction polynomial 0x11B. */
	static function gfMul(a:Int, b:Int):Int {
		var res = 0;
		var x = a & 0xFF;
		var y = b & 0xFF;
		while (y != 0) {
			if ((y & 1) != 0) res ^= x;
			x = ((x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0)) & 0xFF;
			y >>>= 1;
		}
		return res;
	}

	static function gfPow(a:Int, n:Int):Int {
		var res = 1;
		var base = a & 0xFF;
		var e = n;
		while (e > 0) {
			if ((e & 1) != 0) res = gfMul(res, base);
			base = gfMul(base, base);
			e >>>= 1;
		}
		return res;
	}

	static inline function rotl8(v:Int, n:Int):Int
		return ((v << n) | (v >>> (8 - n))) & 0xFF;

	static function initTables():Void {
		if (SBOX != null) return;

		var sbox = new Array<Int>();
		for (i in 0...256) sbox.push(0);
		// 0 has no inverse; the affine step maps it to 0x63
		sbox[0] = 0x63;
		for (a in 1...256) {
			var b = gfPow(a, 254);
			sbox[a] = (b ^ rotl8(b, 1) ^ rotl8(b, 2) ^ rotl8(b, 3) ^ rotl8(b, 4) ^ 0x63) & 0xFF;
		}

		var u0 = new Array<Int>();
		var u1 = new Array<Int>();
		var u2 = new Array<Int>();
		var u3 = new Array<Int>();
		var f0 = new Array<Int>();
		var f1 = new Array<Int>();
		var f2 = new Array<Int>();
		var f3 = new Array<Int>();

		for (i in 0...256) {
			var s = sbox[i];
			var two = m2(s);
			var three = m3(s);
			u0.push((two << 24) | (s << 16) | (s << 8) | three);
			u1.push((three << 24) | (two << 16) | (s << 8) | s);
			u2.push((s << 24) | (three << 16) | (two << 8) | s);
			u3.push((s << 24) | (s << 16) | (three << 8) | two);
			f0.push(s << 24);
			f1.push(s << 16);
			f2.push(s << 8);
			f3.push(s);
		}

		var rcon = [0];
		var c = 1;
		for (i in 1...11) {
			rcon.push(c << 24);
			c = m2(c);
		}

		SBOX = sbox;
		RCON = rcon;
		U0 = u0;
		U1 = u1;
		U2 = u2;
		U3 = u3;
		F0 = f0;
		F1 = f1;
		F2 = f2;
		F3 = f3;
	}

	// ------------------------------------------------------------ key schedule

	/** Expanded round keys; 4 words per round, Nr + 1 rounds. */
	public static function expandKey(key:Bytes):Array<Int> {
		initTables();
		if (key == null) throw "Aes: missing key";
		var nk = key.length >> 2;
		if (nk != 4 && nk != 6 && nk != 8)
			throw "Aes: key must be 16, 24 or 32 bytes (got " + key.length + ")";

		var nr = nk + 6;
		var total = 4 * (nr + 1);
		var w = new Array<Int>();
		for (i in 0...total) w.push(0);
		for (i in 0...nk) w[i] = readBE32(key, i * 4);

		for (i in nk...total) {
			var temp = w[i - 1];
			if (i % nk == 0) {
				temp = subWord(rotWord(temp)) ^ RCON[Std.int(i / nk)];
			} else if (nk > 6 && i % nk == 4) {
				temp = subWord(temp);
			}
			w[i] = w[i - nk] ^ temp;
		}
		return w;
	}

	public static function rounds(key:Bytes):Int
		return (key.length >> 2) + 6;

	static inline function readBE32(b:Bytes, p:Int):Int
		return (b.get(p) << 24) | (b.get(p + 1) << 16) | (b.get(p + 2) << 8) | b.get(p + 3);

	static inline function writeBE32(b:Bytes, p:Int, v:Int):Void {
		b.set(p, (v >>> 24) & 0xFF);
		b.set(p + 1, (v >>> 16) & 0xFF);
		b.set(p + 2, (v >>> 8) & 0xFF);
		b.set(p + 3, v & 0xFF);
	}

	static inline function subWord(w:Int):Int
		return (SBOX[(w >>> 24) & 0xFF] << 24) | (SBOX[(w >>> 16) & 0xFF] << 16) | (SBOX[(w >>> 8) & 0xFF] << 8) | SBOX[w & 0xFF];

	static inline function rotWord(w:Int):Int
		return (w << 8) | (w >>> 24);

	// -------------------------------------------------------------- block cipher

	public static function encryptBlock(roundKeys:Array<Int>, nr:Int, input:Bytes, inPos:Int, output:Bytes, outPos:Int):Void {
		var rk = roundKeys;

		var t0 = readBE32(input, inPos) ^ rk[0];
		var t1 = readBE32(input, inPos + 4) ^ rk[1];
		var t2 = readBE32(input, inPos + 8) ^ rk[2];
		var t3 = readBE32(input, inPos + 12) ^ rk[3];

		var round = 1;
		while (round < nr) {
			var base = round << 2;
			var u0 = U0[t0 >>> 24] ^ U1[(t1 >>> 16) & 0xFF] ^ U2[(t2 >>> 8) & 0xFF] ^ U3[t3 & 0xFF] ^ rk[base];
			var u1 = U0[t1 >>> 24] ^ U1[(t2 >>> 16) & 0xFF] ^ U2[(t3 >>> 8) & 0xFF] ^ U3[t0 & 0xFF] ^ rk[base + 1];
			var u2 = U0[t2 >>> 24] ^ U1[(t3 >>> 16) & 0xFF] ^ U2[(t0 >>> 8) & 0xFF] ^ U3[t1 & 0xFF] ^ rk[base + 2];
			var u3 = U0[t3 >>> 24] ^ U1[(t0 >>> 16) & 0xFF] ^ U2[(t1 >>> 8) & 0xFF] ^ U3[t2 & 0xFF] ^ rk[base + 3];
			t0 = u0;
			t1 = u1;
			t2 = u2;
			t3 = u3;
			round++;
		}

		var last = nr << 2;
		writeBE32(output, outPos, F0[t0 >>> 24] ^ F1[(t1 >>> 16) & 0xFF] ^ F2[(t2 >>> 8) & 0xFF] ^ F3[t3 & 0xFF] ^ rk[last]);
		writeBE32(output, outPos + 4, F0[t1 >>> 24] ^ F1[(t2 >>> 16) & 0xFF] ^ F2[(t3 >>> 8) & 0xFF] ^ F3[t0 & 0xFF] ^ rk[last + 1]);
		writeBE32(output, outPos + 8, F0[t2 >>> 24] ^ F1[(t3 >>> 16) & 0xFF] ^ F2[(t0 >>> 8) & 0xFF] ^ F3[t1 & 0xFF] ^ rk[last + 2]);
		writeBE32(output, outPos + 12, F0[t3 >>> 24] ^ F1[(t0 >>> 16) & 0xFF] ^ F2[(t1 >>> 8) & 0xFF] ^ F3[t2 & 0xFF] ^ rk[last + 3]);
	}

	// ------------------------------------------------------------------ CTR mode

	/**
	 * Encrypts (or decrypts) data with AES-CTR. The counter block is 16 bytes,
	 * little endian, starting at the given value and incrementing per block -
	 * exactly what WinZip AES expects.
	 */
	public static function ctrCrypt(key:Bytes, data:Bytes, ?counterStart:Float):Bytes {
		var counter = counterStart == null ? 1.0 : counterStart;
		initTables();
		var rk = expandKey(key);
		var nr = rounds(key);

		var out = Bytes.alloc(data.length);
		var ctrBlock = Bytes.alloc(16);
		var stream = Bytes.alloc(16);

		var offset = 0;
		while (offset < data.length) {
			writeCounter(ctrBlock, counter);
			encryptBlock(rk, nr, ctrBlock, 0, stream, 0);

			var n = data.length - offset;
			if (n > 16) n = 16;
			var i = 0;
			while (i < n) {
				out.set(offset + i, data.get(offset + i) ^ stream.get(i));
				i++;
			}

			offset += n;
			counter += 1.0;
		}
		return out;
	}

	/** 128 bit little endian counter blocks, as the WinZip AES spec requires. */
	static function writeCounter(target:Bytes, value:Float):Void {
		var v = value;
		var i = 0;
		while (i < 16) {
			var byte = Std.int(v % 256.0);
			if (byte < 0) byte += 256;
			target.set(i, byte);
			v = (v - byte) / 256.0;
			i++;
		}
	}
}
