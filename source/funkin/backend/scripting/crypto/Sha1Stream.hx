package funkin.backend.scripting.crypto;

import haxe.io.Bytes;

/**
 * Incremental SHA-1. The stdlib only offers whole-buffer hashes, which would
 * copy a 100 MB zip entry into a word array just to authenticate it; this one
 * keeps a single 64 byte block and a small state.
 */
class Sha1Stream {
	static inline var BLOCK:Int = 64;

	var h0:Int = 0x67452301;
	var h1:Int = 0xEFCDAB89;
	var h2:Int = 0x98BADCFE;
	var h3:Int = 0x10325476;
	var h4:Int = 0xC3D2E1F0;

	var block:Bytes;
	var blockLen:Int = 0;
	/** Message length in bytes, as a float so it never wraps at 4 GiB. */
	var total:Float = 0;
	var w = [for (i in 0...80) 0];

	public function new() {
		block = Bytes.alloc(BLOCK);
	}

	public function update(data:Bytes, ?pos:Int = 0, ?len:Int = -1):Sha1Stream {
		if (data == null) return this;
		var p = pos;
		var end = len < 0 ? data.length : pos + len;
		total += (end - p);
		while (p < end) {
			var take = BLOCK - blockLen;
			if (take > end - p) take = end - p;
			block.blit(blockLen, data, p, take);
			blockLen += take;
			p += take;
			if (blockLen == BLOCK) {
				compress(block, 0);
				blockLen = 0;
			}
		}
		return this;
	}

	public function digest():Bytes {
		var bits = total * 8.0;
		var pad = Bytes.alloc(64);
		pad.set(0, 0x80);
		var padLen = (blockLen < 56) ? (56 - blockLen) : (120 - blockLen);
		update(pad, 0, padLen);

		var tail = Bytes.alloc(8);
		var v = bits;
		for (i in 0...8) {
			var byte = Std.int(v % 256.0);
			tail.set(7 - i, byte);
			v = (v - byte) / 256.0;
		}
		// length bytes without touching the byte counter semantics of update
		block.blit(blockLen, tail, 0, 8);
		blockLen += 8;
		compress(block, 0);
		blockLen = 0;

		var out = Bytes.alloc(20);
		writeBE32(out, 0, h0);
		writeBE32(out, 4, h1);
		writeBE32(out, 8, h2);
		writeBE32(out, 12, h3);
		writeBE32(out, 16, h4);
		return out;
	}

	public static function make(data:Bytes):Bytes
		return new Sha1Stream().update(data).digest();

	static inline function writeBE32(b:Bytes, p:Int, v:Int):Void {
		b.set(p, (v >>> 24) & 0xFF);
		b.set(p + 1, (v >>> 16) & 0xFF);
		b.set(p + 2, (v >>> 8) & 0xFF);
		b.set(p + 3, v & 0xFF);
	}

	static inline function rotl(v:Int, n:Int):Int
		return (v << n) | (v >>> (32 - n));

	function compress(src:Bytes, pos:Int):Void {
		var ww = w;
		for (i in 0...16) {
			var p = pos + i * 4;
			ww[i] = (src.get(p) << 24) | (src.get(p + 1) << 16) | (src.get(p + 2) << 8) | src.get(p + 3);
		}
		for (i in 16...80) {
			var v = ww[i - 3] ^ ww[i - 8] ^ ww[i - 14] ^ ww[i - 16];
			ww[i] = rotl(v, 1);
		}

		var a = h0, b = h1, c = h2, d = h3, e = h4;
		for (i in 0...80) {
			var f:Int;
			var k:Int;
			if (i < 20) {
				f = (b & c) | (~b & d);
				k = 0x5A827999;
			} else if (i < 40) {
				f = b ^ c ^ d;
				k = 0x6ED9EBA1;
			} else if (i < 60) {
				f = (b & c) | (b & d) | (c & d);
				k = 0x8F1BBCDC;
			} else {
				f = b ^ c ^ d;
				k = 0xCA62C1D6;
			}
			var temp = rotl(a, 5) + f + e + k + ww[i];
			e = d;
			d = c;
			c = rotl(b, 30);
			b = a;
			a = temp;
		}
		h0 += a;
		h1 += b;
		h2 += c;
		h3 += d;
		h4 += e;
	}
}
