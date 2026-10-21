package funkin.backend.scripting.bytecode;

import haxe.io.Bytes;

/**
 * Growable little-endian byte writer used by the bytecode compiler.
 */
class BytesOut {
	public var bytes:Array<Int> = [];
	public var length(get, never):Int;

	public function new() {}

	inline function get_length():Int
		return bytes.length;

	public inline function u8(v:Int):Void {
		bytes.push(v & 0xFF);
	}

	public function i32(v:Int):Void {
		u8(v);
		u8(v >>> 8);
		u8(v >>> 16);
		u8(v >>> 24);
	}

	public function f64(v:Float):Void {
		var tmp = Bytes.alloc(8);
		tmp.setDouble(0, v);
		for (i in 0...8)
			u8(tmp.get(i));
	}

	public function str(s:String):Void {
		var b = Bytes.ofString(s == null ? "" : s);
		i32(b.length);
		raw(b);
	}

	public function raw(b:Bytes):Void {
		for (i in 0...b.length)
			u8(b.get(i));
	}

	public function patchI32(pos:Int, v:Int):Void {
		bytes[pos] = v & 0xFF;
		bytes[pos + 1] = (v >>> 8) & 0xFF;
		bytes[pos + 2] = (v >>> 16) & 0xFF;
		bytes[pos + 3] = (v >>> 24) & 0xFF;
	}

	public function toBytes():Bytes {
		var b = Bytes.alloc(bytes.length);
		for (i in 0...bytes.length)
			b.set(i, bytes[i]);
		return b;
	}
}
