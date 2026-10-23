package funkin.backend.scripting.bytecode;

import haxe.io.Bytes;

/**
 * A compiled script: constant/string pools plus function prototypes.
 * Serialized with `serialize()`, restored with `Chunk.deserialize()`.
 */
class Chunk {
	public static inline var VERSION:Int = 1;

	public var strings:Array<String> = [];
	public var constants:Array<Dynamic> = [];
	public var functions:Array<FunctionProto> = [];
	public var mainProto:Int = 0;

	var stringMap:Map<String, Int>;

	public function new() {
		stringMap = new Map<String, Int>();
	}

	public function addString(s:String):Int {
		if (s == null) s = "";
		var idx = stringMap.get(s);
		if (idx != null) return idx;
		idx = strings.length;
		strings.push(s);
		stringMap.set(s, idx);
		return idx;
	}

	public function addConst(v:Dynamic):Int {
		var idx = constants.length;
		constants.push(v);
		return idx;
	}

	public function serialize():Bytes {
		// The string pool is written before the constants and the prototypes, so every
		// string they reference has to be registered in a first pass. Otherwise those
		// late addString() calls would append entries after the pool was serialized and
		// the indices would point past the end of the pool after deserialization.
		for (c in constants) {
			if (c == null) continue;
			if (Std.isOfType(c, Bool) || Std.isOfType(c, Int) || Std.isOfType(c, Float)) continue;
			if (Std.isOfType(c, String)) {
				addString(cast c);
				continue;
			}
			throw "Bytecode: unsupported constant type " + Std.string(c);
		}
		for (proto in functions) {
			if (proto.name != null) addString(proto.name);
			for (p in proto.params) addString(p);
		}

		var w = new BytesOut();
		w.u8(0x43); // C
		w.u8(0x4E); // N
		w.u8(0x56); // V
		w.u8(0x4D); // M
		w.u8(VERSION);

		w.i32(strings.length);
		for (s in strings) w.str(s);

		w.i32(constants.length);
		for (c in constants) {
			if (c == null) {
				w.u8(0);
			} else if (Std.isOfType(c, Bool)) {
				w.u8(3);
				w.u8((c:Bool) ? 1 : 0);
			} else if (Std.isOfType(c, Int)) {
				w.u8(1);
				w.i32(cast(c, Int));
			} else if (Std.isOfType(c, Float)) {
				w.u8(2);
				w.f64(cast(c, Float));
			} else if (Std.isOfType(c, String)) {
				w.u8(4);
				w.i32(addString(cast c));
			} else {
				throw "Bytecode: unsupported constant type " + Std.string(c);
			}
		}

		w.i32(functions.length);
		for (proto in functions) {
			w.i32(proto.name == null ? -1 : addString(proto.name));
			w.i32(proto.params.length);
			for (p in proto.params) w.i32(addString(p));
			w.i32(proto.minParams);
			w.i32(proto.nlocals);
			w.i32(proto.code.length);
			w.raw(proto.code);
		}
		w.i32(mainProto);
		return w.toBytes();
	}

	public static function deserialize(data:Bytes):Chunk {
		var r = new BytesIn(data);
		if (r.u8() != 0x43 || r.u8() != 0x4E || r.u8() != 0x56 || r.u8() != 0x4D)
			throw "Bytecode: bad magic";
		var version = r.u8();
		if (version != VERSION)
			throw "Bytecode: unsupported version " + version;

		var chunk = new Chunk();
		var stringCount = r.i32();
		for (i in 0...stringCount)
			chunk.addString(r.str());

		var constCount = r.i32();
		for (i in 0...constCount) {
			var tag = r.u8();
			chunk.constants.push(switch (tag) {
				case 0: null;
				case 1: r.i32();
				case 2: r.f64();
				case 3: r.u8() == 1;
				case 4: chunk.strings[r.i32()];
				default: throw "Bytecode: bad constant tag " + tag;
			});
		}

		var protoCount = r.i32();
		for (i in 0...protoCount) {
			var nameIdx = r.i32();
			var proto = new FunctionProto(nameIdx < 0 ? null : chunk.strings[nameIdx], [], 0, 0);
			var paramCount = r.i32();
			for (p in 0...paramCount)
				proto.params.push(chunk.strings[r.i32()]);
			proto.minParams = r.i32();
			proto.nlocals = r.i32();
			var codeLen = r.i32();
			proto.code = r.raw(codeLen);
			chunk.functions.push(proto);
		}
		chunk.mainProto = r.i32();
		return chunk;
	}
}
