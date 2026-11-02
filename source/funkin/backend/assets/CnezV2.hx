package funkin.backend.assets;

import funkin.backend.scripting.crypto.ChaCha20;
import funkin.backend.scripting.crypto.ScriptCrypto;
import haxe.crypto.Hmac;
import haxe.crypto.Hmac.HashMethod;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * CNEZ container. Payload is cut into 1 MiB chunks, one HMAC each, in a table after
 * the header and covered by a root tag.
 *
 * Why chunks: a single tag over the whole file means hashing every byte before the
 * first asset loads, which measured several times the cost of decrypting that same
 * file. Opening a pack now checks the header and table only; a chunk gets checked
 * when something reads through it.
 *
 * The price is that damage shows up when the damaged chunk is read, not on open.
 *
 * Layout (little endian):
 *   0..3    magic "CNEZ"
 *   4       format version (2)
 *   5..7    reserved
 *   8..23   random salt (16)
 *   24..35  random nonce (12)
 *   36..39  payload length (ciphertext)
 *   40..43  chunk size in bytes
 *   44..47  chunk count
 *   48..    chunk table: count x 32 byte HMAC-SHA256, one per ciphertext chunk
 *   ...     root tag: HMAC-SHA256 over bytes 0 .. end of table
 *   ...     ChaCha20 ciphertext of the raw .zip bytes
 *
 * There used to be a single-tag layout while this was being built. It never shipped
 * and is gone; VERSION stays 2 because the number is already inside every packed file.
 */

/** What `open` hands out: everything needed to verify and read chunks lazily. */
typedef OpenedV2 = {
	var payload:Bytes; // still ciphertext
	var enc:Bytes; // ChaCha20 key for the payload
	var mac:Bytes; // key for the chunk tags
	var nonce:Bytes;
	var chunkSize:Int;
	var count:Int;
	var table:Bytes; // count * TAG_SIZE
}

/**
 * What `openFile` hands out: the same keys and table, but the payload is left where it
 * is. A reader seeks to `payloadOffset + position` instead of holding the pack in RAM.
 */
typedef FileOpenedV2 = {
	var enc:Bytes;
	var mac:Bytes;
	var nonce:Bytes;
	var chunkSize:Int;
	var count:Int;
	var table:Bytes;
	var payloadOffset:Int;
	var payloadLength:Int;
}

class CnezV2 {
	public static var MAGIC:Array<Int> = [0x43, 0x4E, 0x45, 0x5A]; // "CNEZ"
	/**
	 * Format version written into every container.
	 *
	 * Kept at 2 rather than renumbered to 1: the value is part of the bytes on disk and
	 * of anything already packed, and renumbering a format that only has this one
	 * revision would buy nothing.
	 */
	public static inline var VERSION:Int = 2;

	public static inline var HEADER_SIZE:Int = 48;
	public static inline var TAG_SIZE:Int = 32;
	static inline var SALT_SIZE:Int = 16;
	static inline var NONCE_SIZE:Int = 12;

	/** One chunk per megabyte: a 100 MB pack becomes 100 tags, 3.2 KB of table. */
	public static inline var CHUNK_SIZE:Int = 1024 * 1024;

	/** Anything smaller than this in a header is a broken or hostile container. */
	static inline var MIN_CHUNK_SIZE:Int = 64 * 1024;

	public static function isV2(data:Bytes):Bool {
		if (data == null || data.length < HEADER_SIZE + TAG_SIZE) return false;
		for (i in 0...4)
			if (data.get(i) != MAGIC[i]) return false;
		return data.get(4) == VERSION;
	}

	public static function pack(zipBytes:Bytes, pass:String, ?onProgress:Float->Void):Bytes {
		pass = ScriptCrypto.resolveKeyValue(pass);
		var salt = ScriptCrypto.randomBytes(SALT_SIZE);
		var nonce = ScriptCrypto.randomBytes(NONCE_SIZE);
		var keys = ScriptCrypto.deriveKeys(pass, salt);

		// the cipher pass is the slow half, so it reports the progress it makes
		var cipher = onProgress == null
			? ChaCha20.xorBytes(keys.enc, nonce, 1, zipBytes)
			: ChaCha20.xorBytes(keys.enc, nonce, 1, zipBytes, function(p:Float) onProgress(0.05 + 0.85 * p));

		var chunkSize = CHUNK_SIZE;
		var count = countFor(cipher.length, chunkSize);
		var table = new BytesBuffer();
		for (i in 0...count) {
			var start = i * chunkSize;
			var len = chunkSize;
			if (start + len > cipher.length) len = cipher.length - start;
			table.add(ScriptCrypto.hmacTag(keys.mac, cipher.sub(start, len)));
		}
		var tableBytes = table.getBytes();
		var head = header(salt, nonce, cipher.length, chunkSize, count);
		var root = ScriptCrypto.hmacTag(keys.mac, concat(head, tableBytes));

		var out = new BytesBuffer();
		out.add(head);
		out.add(tableBytes);
		out.add(root);
		out.add(cipher);
		if (onProgress != null) onProgress(1);
		return out.getBytes();
	}

	/**
	 * Checks the header and the chunk table, and hands the payload back as ciphertext.
	 * No payload byte is read here - that is the whole point of version 2.
	 */
	public static function open(data:Bytes, ?pass:String):OpenedV2 {
		if (pass == null) pass = ScriptCrypto.getPassword();
		pass = ScriptCrypto.resolveKeyValue(pass);
		if (pass == null) throw "CnezV2: no key";

		if (!isV2(data)) throw "CnezV2: not a version 2 container";
		if (data.length < HEADER_SIZE + TAG_SIZE) throw "CnezV2: truncated container";

		var salt = data.sub(8, SALT_SIZE);
		var nonce = data.sub(24, NONCE_SIZE);
		var len = readInt32(data, 36);
		var chunkSize = readInt32(data, 40);
		var count = readInt32(data, 44);

		if (len < 0) throw "CnezV2: corrupted container (negative length)";
		if (chunkSize < MIN_CHUNK_SIZE) throw "CnezV2: corrupted container (chunk size)";
		// the keystream counter for a chunk is start / 64, which only lands on a block
		// boundary when the chunk size is a multiple of the block - otherwise every
		// chunk after the first decrypts against a shifted keystream
		if (chunkSize % 64 != 0) throw "CnezV2: corrupted container (chunk size is not block aligned)";
		if (count <= 0 || count != countFor(len, chunkSize))
			throw "CnezV2: corrupted container (chunk count)";
		// guard the multiplication before allocating anything from a hostile header
		if (count > Std.int(len / MIN_CHUNK_SIZE) + 1) throw "CnezV2: corrupted container (chunk count)";

		var tableSize = count * TAG_SIZE;
		var rootAt = HEADER_SIZE + tableSize;
		if (rootAt + TAG_SIZE + len != data.length)
			throw "CnezV2: corrupted container (bad length)";

		var keys = ScriptCrypto.deriveKeys(pass, salt);
		var head = data.sub(0, HEADER_SIZE + tableSize);
		var root = data.sub(rootAt, TAG_SIZE);
		var expected = ScriptCrypto.hmacTag(keys.mac, head);
		if (!same(expected, root))
			throw "CnezV2: integrity check failed (wrong key or corrupted header)";

		return {
			payload: data.sub(rootAt + TAG_SIZE, len),
			enc: keys.enc,
			mac: keys.mac,
			nonce: nonce,
			chunkSize: chunkSize,
			count: count,
			table: data.sub(HEADER_SIZE, tableSize)
		};
	}

	/**
	 * Checks the header and the chunk table, and leaves the payload on disk.
	 *
	 * Same checks as `open`, minus reading the payload: the caller gets the keys, the
	 * table and where the ciphertext starts, so it can seek to a range and decrypt just
	 * that. This is what the low-memory mode uses - nothing of the pack is held in RAM.
	 */
	public static function openFile(path:String, ?pass:String):FileOpenedV2 {
		#if sys
		if (pass == null) pass = ScriptCrypto.getPassword();
		pass = ScriptCrypto.resolveKeyValue(pass);
		if (pass == null) throw "CnezV2.openFile: no key";

		var handle = sys.io.File.read(path, true);
		var head = handle.read(HEADER_SIZE);
		var len = 0;
		var chunkSize = 0;
		var count = 0;
		var table:Bytes = null;
		var root:Bytes = null;
		var why:String = null;

		if (head == null || head.length < HEADER_SIZE) {
			why = "truncated container";
		} else {
			for (i in 0...4)
				if (head.get(i) != MAGIC[i]) why = "not a CNEZ container";
			if (why == null && head.get(4) != VERSION)
				why = "unsupported container version " + head.get(4);
		}

		if (why == null) {
			len = readInt32(head, 36);
			chunkSize = readInt32(head, 40);
			count = readInt32(head, 44);
			if (len < 0 || chunkSize < MIN_CHUNK_SIZE || chunkSize % 64 != 0)
				why = "corrupted header";
			else if (count <= 0 || count != countFor(len, chunkSize))
				why = "corrupted chunk table";
		}

		if (why == null) {
			var tableSize = count * TAG_SIZE;
			table = handle.read(tableSize);
			root = handle.read(TAG_SIZE);
			if (table == null || table.length < tableSize || root == null || root.length < TAG_SIZE)
				why = "truncated chunk table";
		}
		handle.close();

		if (why != null) throw "CnezV2.openFile: " + why;

		var payloadOffset = HEADER_SIZE + count * TAG_SIZE + TAG_SIZE;
		if (payloadOffset + len > sys.FileSystem.stat(path).size)
			throw "CnezV2.openFile: corrupted container (bad length)";

		var keys = ScriptCrypto.deriveKeys(pass, head.sub(8, SALT_SIZE));
		if (!same(ScriptCrypto.hmacTag(keys.mac, concat(head, table)), root))
			throw "CnezV2.openFile: integrity check failed (wrong key or corrupted header)";

		return {
			enc: keys.enc,
			mac: keys.mac,
			nonce: head.sub(24, NONCE_SIZE),
			chunkSize: chunkSize,
			count: count,
			table: table,
			payloadOffset: payloadOffset,
			payloadLength: len
		};
		#else
		throw "CnezV2.openFile: file access is not available on this target";
		#end
	}

	/**
	 * Full decryption, verifying every chunk on the way. This is what the editor's
	 * "decrypt to a plain zip" needs; the loader never calls it.
	 */
	public static function unpack(data:Bytes, ?pass:String, ?onProgress:Float->Void):Bytes {
		var o = open(data, pass);
		var out = Bytes.alloc(o.payload.length);
		for (i in 0...o.count) {
			var start = i * o.chunkSize;
			var len = o.chunkSize;
			if (start + len > o.payload.length) len = o.payload.length - start;
			var chunk = o.payload.sub(start, len);
			if (!verifyChunk(o, i, chunk))
				throw 'CnezV2: chunk $i failed its integrity check';
			// chunkSize is a multiple of the 64 byte block, so a chunk starts on a
			// keystream boundary and one ChaCha20 call per chunk lines up
			var plain = ChaCha20.xorBytes(o.enc, o.nonce, 1 + Std.int(start / 64), chunk);
			out.blit(start, plain, 0, len);
			if (onProgress != null) onProgress(0.2 + 0.8 * ((i + 1) / o.count));
		}
		return out;
	}

	/** True when `chunk` (the ciphertext of chunk `index`) matches its tag. */
	public static function verifyChunk(o:OpenedV2, index:Int, chunk:Bytes):Bool {
		if (index < 0 || index >= o.count) return false;
		var tag = o.table.sub(index * TAG_SIZE, TAG_SIZE);
		return same(ScriptCrypto.hmacTag(o.mac, chunk), tag);
	}

	/**
	 * Cheap "does this key open that file" check, without loading the pack.
	 *
	 * Reads the header, the chunk table and the root tag - a few KB - and checks the
	 * root tag. Version 1 could get away with decrypting four bytes at a fixed offset,
	 * because its payload starts right after a 40 byte header; in version 2 the payload
	 * sits behind a table whose size depends on the pack, so a fixed offset lands in
	 * that table and decrypts a header field instead of zip data. The root tag is both
	 * the cheapest and the strongest thing to look at here.
	 */
	public static function verifyKeyFile(path:String, ?pass:String):Bool {
		#if sys
		if (pass == null) return false;
		try {
			var handle = sys.io.File.read(path, true);
			var head = handle.read(HEADER_SIZE);
			if (head == null || head.length < HEADER_SIZE || head.get(4) != VERSION) {
				handle.close();
				return false;
			}

			var count = readInt32(head, 44);
			// a table larger than this cannot belong to a real pack; refuse before allocating
			if (count <= 0 || count > 1 << 20) {
				handle.close();
				return false;
			}

			var tableSize = count * TAG_SIZE;
			var table = handle.read(tableSize);
			var root = handle.read(TAG_SIZE);
			handle.close();
			if (table == null || table.length < tableSize || root == null || root.length < TAG_SIZE) return false;

			var keys = ScriptCrypto.deriveKeys(pass, head.sub(8, SALT_SIZE));
			return same(ScriptCrypto.hmacTag(keys.mac, concat(head, table)), root);
		} catch (e:Dynamic) {}
		#end
		return false;
	}

	// ------------------------------------------------------------------ helpers

	static function countFor(length:Int, chunkSize:Int):Int {
		if (length <= 0) return 0;
		return Std.int((length + chunkSize - 1) / chunkSize);
	}

	static function header(salt:Bytes, nonce:Bytes, len:Int, chunkSize:Int, count:Int):Bytes {
		var b = new BytesBuffer();
		for (v in MAGIC) b.addByte(v);
		b.addByte(VERSION);
		b.addByte(0);
		b.addByte(0);
		b.addByte(0);
		b.add(salt);
		b.add(nonce);
		writeInt32(b, len);
		writeInt32(b, chunkSize);
		writeInt32(b, count);
		return b.getBytes();
	}

	static function readInt32(b:Bytes, o:Int):Int {
		return b.get(o) | (b.get(o + 1) << 8) | (b.get(o + 2) << 16) | (b.get(o + 3) << 24);
	}

	static function writeInt32(b:BytesBuffer, v:Int):Void {
		b.addByte(v & 0xFF);
		b.addByte((v >>> 8) & 0xFF);
		b.addByte((v >>> 16) & 0xFF);
		b.addByte((v >>> 24) & 0xFF);
	}

	static function concat(a:Bytes, b:Bytes):Bytes {
		var out = new BytesBuffer();
		out.add(a);
		out.add(b);
		return out.getBytes();
	}

	/** Constant-time compare, same reason as everywhere else: no early exit. */
	public static function same(a:Bytes, b:Bytes):Bool {
		if (a == null || b == null || a.length != b.length) return false;
		var diff = 0;
		for (i in 0...a.length) diff |= a.get(i) ^ b.get(i);
		return diff == 0;
	}
}
