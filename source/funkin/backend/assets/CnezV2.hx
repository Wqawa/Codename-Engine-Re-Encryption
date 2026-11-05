package funkin.backend.assets;

import funkin.backend.scripting.crypto.ChaCha20;
import funkin.backend.scripting.crypto.ScriptCrypto;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * CNEZ container. The payload is cut into 1 MiB chunks with one HMAC each, held in a
 * table after the header and covered by a root tag.
 *
 * Chunking is what makes opening cheap: a single tag over the whole file would mean
 * hashing every byte before the first asset loads. Opening now checks the header and
 * the table; a chunk is checked the first time something reads through it. The trade
 * is that damage to the payload surfaces at read time, not on open.
 *
 * Layout, little endian:
 *   0..3    magic "CNEZ"
 *   4       format version (3 written, 2 and 3 read)
 *   5..7    reserved
 *   8..23   salt (16)
 *   24..35  nonce (12)
 *   36..39  payload length, ciphertext
 *   40..43  chunk size
 *   44..47  chunk count
 *   48..    chunk table: count * 32 byte HMAC-SHA256 tags
 *   ...     root tag: HMAC-SHA256 over bytes 0 .. end of table
 *   ...     ChaCha20 ciphertext of the raw .zip
 *
 * The layout never changed; the version byte says which key derivation the header's
 * salt was fed to. Version 2 used a 2048-round SHA-256 loop, version 3 uses
 * PBKDF2-HMAC-SHA256 - same header, same chunk table, one different number in it.
 */

/** What `open` returns: keys and table, with the payload still encrypted in memory. */
typedef OpenedV2 = {
	var payload:Bytes; // ciphertext
	var enc:Bytes;
	var mac:Bytes;
	var nonce:Bytes;
	var chunkSize:Int;
	var count:Int;
	var table:Bytes; // count * TAG_SIZE
}

/**
 * What `openFile` returns: the same keys and table, but the payload stays where it is.
 * A reader seeks to `payloadOffset + position` instead of holding the pack in RAM.
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

/** The fields between the magic and the chunk table. */
typedef HeaderV2 = {
	/** 2 = iterated SHA-256, 3 = PBKDF2-HMAC-SHA256. It is part of the root tag. */
	var version:Int;
	var salt:Bytes;
	var nonce:Bytes;
	var length:Int;
	var chunkSize:Int;
	var count:Int;
}

class CnezV2 {
	public static var MAGIC:Array<Int> = [0x43, 0x4E, 0x45, 0x5A]; // "CNEZ"
	/** Version written for new packs; 3 moved the KDF to PBKDF2. */
	public static inline var VERSION:Int = 3;
	/** Oldest version still readable. Version 2 packs keep opening forever. */
	public static inline var VERSION_MIN:Int = 2;

	public static inline var HEADER_SIZE:Int = 48;
	public static inline var TAG_SIZE:Int = 32;
	static inline var SALT_SIZE:Int = 16;
	static inline var NONCE_SIZE:Int = 12;

	/** One chunk per megabyte: a 100 MB pack becomes 100 tags, 3.2 KB of table. */
	public static inline var CHUNK_SIZE:Int = 1024 * 1024;

	/**
	 * Lower bound for a chunk size read from a header. A hostile file could otherwise
	 * ask for millions of tiny chunks.
	 */
	static inline var MIN_CHUNK_SIZE:Int = 64 * 1024;

	/** ChaCha20 block. Every chunk has to start on one, see `parseHeader`. */
	static inline var BLOCK:Int = 64;

	public static function isV2(data:Bytes):Bool {
		if (data == null || data.length < HEADER_SIZE + TAG_SIZE) return false;
		return magicProblem(data) == null;
	}

	public static function pack(zipBytes:Bytes, pass:String, ?onProgress:Float->Void, ?allowBuiltInKey:Bool = false):Bytes {
		pass = ScriptCrypto.resolveKeyValue(pass);
		// sealing with the key that ships in the executable protects nothing; only a
		// re-seal of an existing pack (which already used it) is allowed to pass
		if (!allowBuiltInKey && ScriptCrypto.isBuiltInKey(pass))
			throw "CnezV2: refusing to seal a pack with the built-in fallback key, set a real one";
		var salt = ScriptCrypto.randomBytes(SALT_SIZE);
		var nonce = ScriptCrypto.randomBytes(NONCE_SIZE);
		var keys = ScriptCrypto.deriveKeys(pass, salt, 2);

		// the cipher pass is the slow half, so it is the one that reports progress
		var cipher = onProgress == null
			? ChaCha20.xorBytes(keys.enc, nonce, 1, zipBytes)
			: ChaCha20.xorBytes(keys.enc, nonce, 1, zipBytes, function(p:Float) onProgress(0.05 + 0.85 * p));

		var chunkSize = CHUNK_SIZE;
		var count = countFor(cipher.length, chunkSize);
		var table = new BytesBuffer();
		for (i in 0...count) {
			var start = i * chunkSize;
			table.add(ScriptCrypto.hmacTag(keys.mac, cipher.sub(start, chunkLength(i, chunkSize, cipher.length))));
		}

		var tableBytes = table.getBytes();
		var head = buildHeader(VERSION, salt, nonce, cipher.length, chunkSize, count);
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
	 * Checks the header and the chunk table and hands the payload back as ciphertext.
	 * No payload byte is read here - that is the point of version 2.
	 */
	public static function open(data:Bytes, ?pass:String):OpenedV2 {
		var key = requireKey(pass, "CnezV2: no key");
		if (!isV2(data)) throw "CnezV2: not a version 2 container";

		var header = parseHeader(data);
		if (header == null) throw "CnezV2: corrupted container (header)";

		var tableSize = header.count * TAG_SIZE;
		var rootAt = HEADER_SIZE + tableSize;
		if (rootAt + TAG_SIZE + header.length != data.length)
			throw "CnezV2: corrupted container (bad length)";

		var keys = ScriptCrypto.deriveKeys(key, header.salt, kdfFor(header.version));
		var head = data.sub(0, HEADER_SIZE + tableSize);
		if (!same(ScriptCrypto.hmacTag(keys.mac, head), data.sub(rootAt, TAG_SIZE)))
			throw "CnezV2: integrity check failed (wrong key or corrupted header)";

		return {
			payload: data.sub(rootAt + TAG_SIZE, header.length),
			enc: keys.enc,
			mac: keys.mac,
			nonce: header.nonce,
			chunkSize: header.chunkSize,
			count: header.count,
			table: data.sub(HEADER_SIZE, tableSize)
		};
	}

	/**
	 * Same checks as `open`, minus reading the payload: the caller gets the keys, the
	 * table and where the ciphertext starts, so it can seek and decrypt one range at a
	 * time. This is the low-memory mode - no part of the pack is held in RAM.
	 */
	public static function openFile(path:String, ?pass:String):FileOpenedV2 {
		#if sys
		var key = requireKey(pass, "CnezV2.openFile: no key");
		var handle = sys.io.File.read(path, true);
		var header:HeaderV2 = null;
		var table:Bytes = null;
		var root:Bytes = null;
		var why:String = null;

		try {
			var head = handle.read(HEADER_SIZE);
			why = magicProblem(head);
			if (why == null) {
				header = parseHeader(head);
				if (header == null) why = "corrupted header";
			}
			if (why == null) {
				var tableSize = header.count * TAG_SIZE;
				table = handle.read(tableSize);
				root = handle.read(TAG_SIZE);
				if (table == null || table.length < tableSize || root == null || root.length < TAG_SIZE)
					why = "truncated chunk table";
			}
		} catch (e:Dynamic) {
			why = "could not read the container (" + e + ")";
		}
		handle.close();

		if (why != null) throw "CnezV2.openFile: " + why;

		var payloadOffset = HEADER_SIZE + header.count * TAG_SIZE + TAG_SIZE;
		if (payloadOffset + header.length > sys.FileSystem.stat(path).size)
			throw "CnezV2.openFile: corrupted container (bad length)";

		var keys = ScriptCrypto.deriveKeys(key, header.salt, kdfFor(header.version));
		var headerBytes = buildHeader(header.version, header.salt, header.nonce, header.length, header.chunkSize, header.count);
		if (!same(ScriptCrypto.hmacTag(keys.mac, concat(headerBytes, table)), root))
			throw "CnezV2.openFile: integrity check failed (wrong key or corrupted header)";

		return {
			enc: keys.enc,
			mac: keys.mac,
			nonce: header.nonce,
			chunkSize: header.chunkSize,
			count: header.count,
			table: table,
			payloadOffset: payloadOffset,
			payloadLength: header.length
		};
		#else
		throw "CnezV2.openFile: file access is not available on this target";
		#end
	}

	/**
	 * Full decryption, verifying every chunk on the way. Used by the editor's "decrypt
	 * to a plain zip"; the loader never calls it.
	 */
	public static function unpack(data:Bytes, ?pass:String, ?onProgress:Float->Void):Bytes {
		var o = open(data, pass);
		var out = Bytes.alloc(o.payload.length);
		for (i in 0...o.count) {
			var start = i * o.chunkSize;
			var len = chunkLength(i, o.chunkSize, o.payload.length);
			var chunk = o.payload.sub(start, len);
			if (!verifyChunk(o, i, chunk)) throw 'CnezV2: chunk $i failed its integrity check';
			// the chunk size is a multiple of the block, so one ChaCha20 call per chunk
			// lines up with the keystream
			out.blit(start, ChaCha20.xorBytes(o.enc, o.nonce, 1 + Std.int(start / BLOCK), chunk), 0, len);
			if (onProgress != null) onProgress(0.2 + 0.8 * ((i + 1) / o.count));
		}
		return out;
	}

	/** True when `chunk` (ciphertext of chunk `index`) matches its tag. */
	public static function verifyChunk(o:OpenedV2, index:Int, chunk:Bytes):Bool {
		if (index < 0 || index >= o.count) return false;
		return same(ScriptCrypto.hmacTag(o.mac, chunk), o.table.sub(index * TAG_SIZE, TAG_SIZE));
	}

	/**
	 * Cheap "does this key open that file" check, without loading the pack.
	 *
	 * Reads the header, the table and the root tag - a few KB - and checks the root tag.
	 * Decrypting a fixed offset is not an option here: the payload sits behind a table
	 * whose size depends on the pack, so a fixed offset lands in the table.
	 */
	public static function verifyKeyFile(path:String, ?pass:String):Bool {
		#if sys
		if (pass == null) return false;
		try {
			var handle = sys.io.File.read(path, true);
			var head = handle.read(HEADER_SIZE);
			var header = magicProblem(head) == null ? parseHeader(head) : null;
			if (header == null) {
				handle.close();
				return false;
			}

			var tableSize = header.count * TAG_SIZE;
			var table = handle.read(tableSize);
			var root = handle.read(TAG_SIZE);
			handle.close();
			if (table == null || table.length < tableSize || root == null || root.length < TAG_SIZE) return false;

			var keys = ScriptCrypto.deriveKeys(pass, header.salt, kdfFor(header.version));
			var headerBytes = buildHeader(header.version, header.salt, header.nonce, header.length, header.chunkSize, header.count);
			return same(ScriptCrypto.hmacTag(keys.mac, concat(headerBytes, table)), root);
		} catch (e:Dynamic) {}
		#end
		return false;
	}

	// ------------------------------------------------------------------ header

	/**
	 * Reason the first bytes cannot be a CNEZ header, or null.
	 *
	 * Shared with `openFile` so a damaged file produces one sentence instead of five
	 * nested conditions.
	 */
	static function magicProblem(head:Bytes):String {
		if (head == null || head.length < HEADER_SIZE) return "truncated container";
		for (i in 0...4)
			if (head.get(i) != MAGIC[i]) return "not a CNEZ container";
		var version = head.get(4);
		if (version < VERSION_MIN || version > VERSION) return "unsupported container version " + version;
		return null;
	}

	/** Reads and validates the header fields, or null when one of them is impossible. */
	static function parseHeader(head:Bytes):HeaderV2 {
		if (head == null || head.length < HEADER_SIZE) return null;
		var length = readInt32(head, 36);
		var chunkSize = readInt32(head, 40);
		var count = readInt32(head, 44);

		if (length < 0) return null;
		if (chunkSize < MIN_CHUNK_SIZE) return null;
		// the keystream counter of a chunk is start / 64, so the chunk size has to be a
		// multiple of the block or every chunk after the first decrypts shifted
		if (chunkSize % BLOCK != 0) return null;
		if (count <= 0 || count != countFor(length, chunkSize)) return null;
		// guard the multiplication below before anything is allocated from a hostile header
		if (count > Std.int(length / MIN_CHUNK_SIZE) + 1) return null;

		return {
			version: head.get(4),
			salt: head.sub(8, SALT_SIZE),
			nonce: head.sub(24, NONCE_SIZE),
			length: length,
			chunkSize: chunkSize,
			count: count
		};
	}

	static function buildHeader(version:Int, salt:Bytes, nonce:Bytes, length:Int, chunkSize:Int, count:Int):Bytes {
		var b = new BytesBuffer();
		for (v in MAGIC) b.addByte(v);
		b.addByte(version);
		b.addByte(0);
		b.addByte(0);
		b.addByte(0);
		b.add(salt);
		b.add(nonce);
		writeInt32(b, length);
		writeInt32(b, chunkSize);
		writeInt32(b, count);
		return b.getBytes();
	}

	// ----------------------------------------------------------------- helpers

	/** Bytes in chunk `index`, clamped to the payload. */
	static inline function chunkLength(index:Int, chunkSize:Int, payloadLength:Int):Int {
		var start = index * chunkSize;
		return start + chunkSize > payloadLength ? payloadLength - start : chunkSize;
	}

	static function countFor(length:Int, chunkSize:Int):Int {
		if (length <= 0) return 0;
		return Std.int((length + chunkSize - 1) / chunkSize);
	}

	/** KDF selector for a container version, see ScriptCrypto.deriveKeys. */
	static inline function kdfFor(version:Int):Int
		return version >= 3 ? 2 : 1;

	static function requireKey(?pass:String, error:String):String {
		if (pass == null) pass = ScriptCrypto.getPassword();
		var key = ScriptCrypto.resolveKeyValue(pass);
		if (key == null) throw error;
		return key;
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

	/** Constant-time compare: no early exit. */
	public static function same(a:Bytes, b:Bytes):Bool {
		if (a == null || b == null || a.length != b.length) return false;
		var diff = 0;
		for (i in 0...a.length) diff |= a.get(i) ^ b.get(i);
		return diff == 0;
	}
}
