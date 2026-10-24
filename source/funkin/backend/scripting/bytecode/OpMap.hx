package funkin.backend.scripting.bytecode;

import funkin.backend.scripting.protect.Rng;

/**
 * Per-file opcode permutation (the "VM virtualization" layer).
 *
 * The compiler writes encode[real] instead of the real opcode, and the VM maps
 * decode[virtual] back before dispatching. A dumped chunk therefore does not
 * look like CNE bytecode at all: every opcode byte is a different, file specific
 * number, so a generic disassembler or a hand written script cannot walk it
 * without this table.
 */
class OpMap {
	/** Real opcodes are 0..COUNT-1 (see Op.STORE_GLOBAL = 49). */
	public static inline var COUNT:Int = 50;

	public var encode:Array<Int>;
	public var decode:Array<Int>;

	public function new(seed:Int) {
		var perm:Array<Int> = [];
		for (i in 0...COUNT) perm.push(i);

		var rng = new Rng(seed);
		var i = COUNT - 1;
		while (i > 0) {
			var j = rng.range(i + 1);
			var t = perm[i];
			perm[i] = perm[j];
			perm[j] = t;
			i--;
		}

		encode = perm;
		decode = [];
		for (v in 0...COUNT) decode.push(0);
		for (real in 0...COUNT) decode[perm[real]] = real;
	}

	/** Table for containers written without the virtualization layer (seed 0). */
	public static function identity():OpMap {
		var m = new OpMap(1);
		for (i in 0...COUNT) {
			m.encode[i] = i;
			m.decode[i] = i;
		}
		return m;
	}
}
