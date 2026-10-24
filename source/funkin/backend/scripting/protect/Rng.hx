package funkin.backend.scripting.protect;

import haxe.io.Bytes;

/**
 * Small PRNG shared by the script protection layers.
 *
 * Everything is deterministic for a given seed: the packer and the game have to
 * derive the same split points, chaff lengths, permutations and opcode tables
 * from the numbers stored in the container header, so the algorithms cannot
 * depend on any hidden state.
 */
class Rng {
	var state:Int;

	public function new(seed:Int) {
		// xorshift state must never be zero, and a raw seed is a poor start
		var s = seed;
		if (s == 0) s = 0x2545F491;
		s ^= (s << 13);
		s ^= (s >>> 7);
		s *= 0x2545F491;
		if (s == 0) s = 0x13579BDF;
		state = s;
	}

	public function next():Int {
		var x = state;
		x ^= (x << 13);
		x ^= (x >>> 17);
		x ^= (x << 5);
		state = x;
		return x;
	}

	public inline function nextByte():Int {
		return next() & 0xFF;
	}

	/** Uniform-looking value in [0, n). */
	public function range(n:Int):Int {
		if (n <= 0) return 0;
		return (next() & 0x7FFFFFFF) % n;
	}

	/** Fills a buffer with pseudo random bytes drawn from this stream. */
	public function fill(target:Bytes):Void {
		var i = 0;
		while (i < target.length) {
			var v = next();
			var n = target.length - i;
			if (n > 4) n = 4;
			for (j in 0...n) target.set(i + j, (v >>> (j * 8)) & 0xFF);
			i += n;
		}
	}
}
