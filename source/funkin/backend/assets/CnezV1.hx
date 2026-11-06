package funkin.backend.assets;

import funkin.backend.scripting.crypto.ChaCha20;
import funkin.backend.scripting.crypto.ScriptCrypto;
import haxe.io.Bytes;
#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * Reader for the version 1 pack container, the format the 1.0.1 build wrote.
 *
 * Layout (little endian):
 *   0..3    magic "CNEZ"
 *   4       format version (1)
 *   5..7    reserved
 *   8..23   salt (16)
 *   24..35  nonce (12)
 *   36..39  payload length
 *   40..    ChaCha20 ciphertext of the raw .zip
 *   last 32 HMAC-SHA256 over everything above
 *
 * Version 2 replaced the single cipher stream with per-chunk tags and version 3
 * replaced the iterated SHA-256 key with PBKDF2, so packs published with the 1.0.1
 * build cannot be opened by the version 2/3 code. This class reads those packs and
 * nothing else: no writer, no upgrade path.
 */
class CnezV1 {
	public static inline var VERSION:Int = 1;

	public static inline var HEADER_SIZE:Int = 40;
	public static inline var TAG_SIZE:Int = 32;
	public static inline var SALT_SIZE:Int = 16;
	public static inline var NONCE_SIZE:Int = 12;

	/** Checks the magic and the version byte of an already loaded file. */
	public static function isV1(data:Bytes):Bool {
		if (data == null || data.length < HEADER_SIZE + TAG_SIZE) return false;
		return hasHeader(data);
	}

	#if sys
	/** Same test as isV1 but reads only the first bytes of a file. */
	public static function isV1File(path:String):Bool {
		if (path == null || !FileSystem.exists(path) || FileSystem.isDirectory(path)) return false;
		var head:Bytes = null;
		var handle = File.read(path, true);
		try {
			head = handle.read(5);
		} catch (e:Dynamic) {
			head = null;
		}
		handle.close();
		return head != null && head.length >= 5 && hasHeader(head);
	}

	/**
	 * Cheap key test: a wrong key decrypts to noise, a right one starts with "PK".
	 * Only the first cipher block is touched, so this stays fast on a 100 MB pack.
	 */
	public static function verifyKeyFile(path:String, pass:String):Bool {
		if (pass == null || !FileSystem.exists(path) || FileSystem.isDirectory(path)) return false;
		var head:Bytes = null;
		var handle = File.read(path, true);
		try {
			head = handle.read(HEADER_SIZE + 4);
		} catch (e:Dynamic) {
			head = null;
		}
		handle.close();
		if (head == null || head.length < HEADER_SIZE + 4 || !hasHeader(head)) return false;
		var keys = ScriptCrypto.deriveKeys(pass, head.sub(8, SALT_SIZE));
		var probe = ChaCha20.xorBytes(keys.enc, head.sub(24, NONCE_SIZE), 1, head.sub(HEADER_SIZE, 4));
		return probe.get(0) == 0x50 && probe.get(1) == 0x4B;
	}

	/**
	 * Decrypts a whole version 1 pack.
	 *
	 * The tag covers the header *and* the ciphertext, so the length has to be exact
	 * before anything is verified; the compare itself does not short-circuit.
	 */
	public static function unpack(data:Bytes, pass:String, ?onProgress:Float->Void):Bytes {
		if (!isV1(data)) throw "CnezV1: not a version 1 pack";
		if (pass == null) throw "CnezV1: no key given";
		var length = readInt(data, 36);
		if (length < 0 || HEADER_SIZE + length + TAG_SIZE != data.length)
			throw 'CnezV1: payload length $length does not match the file size ' + data.length;

		var body = data.sub(0, HEADER_SIZE + length);
		var tag = data.sub(HEADER_SIZE + length, TAG_SIZE);
		var keys = ScriptCrypto.deriveKeys(pass, data.sub(8, SALT_SIZE));
		var expected = ScriptCrypto.hmacTag(keys.mac, body);
		var diff = 0;
		for (i in 0...TAG_SIZE)
			diff |= expected.get(i) ^ tag.get(i);
		if (diff != 0) throw "CnezV1: wrong key or corrupted pack";

		if (onProgress != null) onProgress(0.2);
		var cipher = data.sub(HEADER_SIZE, length);
		var plain = onProgress == null
			? ChaCha20.xorBytes(keys.enc, data.sub(24, NONCE_SIZE), 1, cipher)
			: ChaCha20.xorBytes(keys.enc, data.sub(24, NONCE_SIZE), 1, cipher, function(p:Float) onProgress(0.2 + 0.8 * p));
		if (onProgress != null) onProgress(1);
		return plain;
	}
	#end

	static function hasHeader(head:Bytes):Bool {
		if (head == null || head.length < 5) return false;
		for (i in 0...4)
			if (head.get(i) != CnezV2.MAGIC[i]) return false;
		return head.get(4) == VERSION;
	}

	/** Little-endian 32-bit read; the container stores lengths that way. */
	static function readInt(data:Bytes, pos:Int):Int {
		return data.get(pos) | (data.get(pos + 1) << 8) | (data.get(pos + 2) << 16) | (data.get(pos + 3) << 24);
	}
}
