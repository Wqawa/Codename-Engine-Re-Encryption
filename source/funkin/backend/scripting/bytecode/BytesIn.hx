package funkin.backend.scripting.bytecode;

import haxe.io.Bytes;

/**
 * Little-endian byte reader, counterpart of `BytesOut`.
 */
class BytesIn {
	public var data:Bytes;
	public var pos:Int = 0;

	public function new(data:Bytes) {
		this.data = data;
	}

	public function eof():Bool
		return pos >= data.length;

	public function u8():Int {
		if (pos >= data.length) throw "Bytecode: unexpected end of data";
		return data.get(pos++);
	}

	public function i32():Int {
		var b0 = u8();
		var b1 = u8();
		var b2 = u8();
		var b3 = u8();
		return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
	}

	public function f64():Float {
		var tmp = Bytes.alloc(8);
		for (i in 0...8)
			tmp.set(i, u8());
		return tmp.getDouble(0);
	}

	public function str():String {
		var len = i32();
		if (len < 0 || pos + len > data.length) throw "Bytecode: corrupted string";
		var b = Bytes.alloc(len);
		for (i in 0...len)
			b.set(i, u8());
		return b.toString();
	}

	public function raw(len:Int):Bytes {
		if (len < 0 || pos + len > data.length) throw "Bytecode: corrupted blob";
		var b = Bytes.alloc(len);
		for (i in 0...len)
			b.set(i, u8());
		return b;
	}
}
