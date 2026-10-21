package funkin.backend.scripting.bytecode;

import funkin.backend.scripting.HScript;
import funkin.backend.scripting.crypto.ScriptCrypto;
import haxe.io.Bytes;

/**
 * Result of unpacking a script container: exactly one of `source` / `chunk` is set.
 */
typedef PackedScript = {
	var mode:Int;
	var ?source:String;
	var ?chunk:Chunk;
}

/**
 * Bridges the HScript source code, the bytecode compiler and the encrypted
 * CNES container (see ScriptCrypto).
 *
 * Encoding a script is done once, offline (the Script Encryption editor), while
 * the game only has to unpack and run it, which keeps a plain text copy of the
 * code from being shipped inside the build.
 */
class ScriptPackager {
	public static inline var EXTENSION:String = "hxb";

	/** Magic of a "VM obfuscated" container: bytecode without any key. */
	public static var MAGIC_OBFUSCATED:Array<Int> = [0x43, 0x4E, 0x45, 0x56]; // "CNEV"
	/** Payload mode of the obfuscated container (no password needed). */
	public static inline var MODE_OBFUSCATED:Int = 3;

	/**
	 * Returns true if `data` starts with the CNES magic ("CNES").
	 */
	public static function isEncrypted(data:Bytes):Bool {
		return data != null && ScriptCrypto.isContainer(data);
	}

	/** Returns true if `data` is a keyless bytecode container ("CNEV"). */
	public static function isObfuscated(data:Bytes):Bool {
		if (data == null || data.length < 12) return false;
		for (i in 0...4)
			if (data.get(i) != MAGIC_OBFUSCATED[i]) return false;
		return true;
	}

	/** True for every container this packager understands. */
	public static function isContainer(data:Bytes):Bool {
		return isEncrypted(data) || isObfuscated(data);
	}

	/**
	 * Compiles HScript source into a bytecode chunk.
	 * Throws CompileError when the source uses a construct the VM cannot run.
	 */
	public static function compile(source:String, ?fileName:String = "script.hx"):Chunk {
		return Compiler.compile(HScript.initParser(), source, fileName);
	}

	/**
	 * Packs plain source text into an encrypted container (decrypted by the
	 * interpreter at runtime, still hides the plain text on disk).
	 */
	public static function packSource(source:String, ?pass:String, ?scriptName:String):Bytes {
		if (source == null) source = "";
		return ScriptCrypto.pack(Bytes.ofString(source), ScriptCrypto.MODE_SOURCE, pass, scriptName);
	}

	/**
	 * Packs a compiled chunk into an encrypted container (run by the bytecode VM).
	 */
	public static function packChunk(chunk:Chunk, ?pass:String, ?scriptName:String):Bytes {
		return ScriptCrypto.pack(chunk.serialize(), ScriptCrypto.MODE_BYTECODE, pass, scriptName);
	}

	/**
	 * Packs compiled bytecode followed by the original source. The VM runs the
	 * bytecode; the source copy is a safety net used if the VM cannot execute it,
	 * so behaviour is always preserved.
	 */
	public static function packBoth(chunk:Chunk, source:String, ?pass:String, ?scriptName:String):Bytes {
		var code = chunk.serialize();
		var buf = new haxe.io.BytesBuffer();
		buf.addByte(code.length & 0xFF);
		buf.addByte((code.length >> 8) & 0xFF);
		buf.addByte((code.length >> 16) & 0xFF);
		buf.addByte((code.length >>> 24) & 0xFF);
		buf.add(code);
		if (source != null && source.length > 0)
			buf.add(Bytes.ofString(source));
		return ScriptCrypto.pack(buf.getBytes(), ScriptCrypto.MODE_BOTH, pass, scriptName);
	}

	/**
	 * Compiles then packs a source script into bytecode form (with source backup).
	 */
	public static function packBytecode(source:String, ?fileName:String = "script.hx", ?pass:String):Bytes {
		return packBoth(compile(source, fileName), source, pass, fileName);
	}

	/**
	 * Packs a compiled chunk into a keyless container. The engine executes the
	 * bytecode directly, so no password prompt is needed, while the file still
	 * contains no readable source text.
	 */
	public static function packObfuscated(chunk:Chunk):Bytes {
		var code = chunk.serialize();
		var buf = new haxe.io.BytesBuffer();
		for (v in MAGIC_OBFUSCATED) buf.addByte(v);
		buf.addByte(1); // format version
		buf.addByte(MODE_OBFUSCATED);
		buf.addByte(0);
		buf.addByte(0);
		var len = code.length;
		buf.addByte(len & 0xFF);
		buf.addByte((len >>> 8) & 0xFF);
		buf.addByte((len >>> 16) & 0xFF);
		buf.addByte((len >>> 24) & 0xFF);
		buf.add(code);
		return buf.getBytes();
	}

	/** Compiles then packs a script into a keyless bytecode container. */
	public static function packObfuscatedSource(source:String, ?fileName:String = "script.hx"):Bytes {
		return packObfuscated(compile(source, fileName));
	}

	/**
	 * Unpacks a container, encrypted ("CNES") or keyless bytecode ("CNEV").
	 */
	public static function unpack(data:Bytes, ?pass:String, ?scriptName:String):PackedScript {
		if (isObfuscated(data)) {
			var len = data.get(8) | (data.get(9) << 8) | (data.get(10) << 16) | (data.get(11) << 24);
			if (len <= 0 || 12 + len > data.length)
				throw "ScriptPackager: corrupted obfuscated container (bad length)";
			return {mode: MODE_OBFUSCATED, chunk: Chunk.deserialize(data.sub(12, len))};
		}

		var result = ScriptCrypto.unpack(data, pass, scriptName);
		if (result.mode == ScriptCrypto.MODE_BYTECODE)
			return {mode: result.mode, chunk: Chunk.deserialize(result.payload)};
		if (result.mode == ScriptCrypto.MODE_BOTH) {
			var payload = result.payload;
			var len = payload.get(0) | (payload.get(1) << 8) | (payload.get(2) << 16) | (payload.get(3) << 24);
			var chunk = Chunk.deserialize(payload.sub(4, len));
			var source = payload.length > 4 + len ? payload.sub(4 + len, payload.length - 4 - len).toString() : "";
			return {mode: result.mode, chunk: chunk, source: source};
		}
		return {mode: result.mode, source: result.payload.toString()};
	}

	/**
	 * Short human readable description of a script file, used by the editor.
	 */
	public static function describe(data:Bytes, ?pass:String, ?scriptName:String):String {
		if (data == null) return "empty";
		if (isObfuscated(data)) return 'VM bytecode, no key (' + data.length + ' bytes)';
		if (!isEncrypted(data))
			return 'plain script (' + data.length + ' bytes)';
		try {
			var packed = unpack(data, pass, scriptName);
			var kind = switch(packed.mode) {
				case MODE_OBFUSCATED: "VM bytecode, no key";
				case ScriptCrypto.MODE_BYTECODE: "encrypted bytecode";
				case ScriptCrypto.MODE_BOTH: "encrypted bytecode (" + Std.string(packed.source == null ? 0 : packed.source.length) + " byte source backup)";
				default: "encrypted source";
			}
			return kind + ' (' + data.length + ' bytes)';
		} catch(e:Dynamic) {
			return 'encrypted script (' + data.length + ' bytes, cannot decode: ' + Std.string(e) + ')';
		}
	}
}
