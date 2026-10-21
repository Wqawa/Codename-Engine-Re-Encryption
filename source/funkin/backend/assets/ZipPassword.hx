package funkin.backend.assets;

#if sys
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.FileInput;
import sys.io.FileOutput;
#end

/**
 * Reader for zips whose entries were protected with a password (the classic
 * "ZipCrypto" / traditional PKWARE encryption most zip tools use by default).
 *
 * Codename Engine's zip loader cannot read such entries: the entry flags carry
 * the "encrypted" bit and the standard reader refuses them. This class checks
 * the password cheaply (only the 12 byte encryption header is decrypted), then
 * rebuilds a readable copy of the archive inside the mod cache folder. The copy
 * is stored uncompressed, which costs disk space but keeps the rewrite fast and
 * streaming (no whole-archive buffer in memory).
 *
 * AES protected zips (method 99, what 7-Zip uses for "AES-256") are detected but
 * not supported yet.
 */
class ZipPassword {
	/** Folder the decrypted copies are written to. */
	public static var cacheFolder:String = './.cne_mods/';

	public static inline var FLAG_ENCRYPTED:Int = 0x1;

	/** True when at least one entry of the zip needs a password. */
	public static function isProtected(path:String):Bool {
		#if sys
		var entries = readCentral(path);
		if (entries == null) return false;
		for (e in entries)
			if ((e.flags & FLAG_ENCRYPTED) != 0) return true;
		#end
		return false;
	}

	/** True when the archive uses AES entries (method 99) instead of ZipCrypto. */
	public static function usesAES(path:String):Bool {
		#if sys
		var entries = readCentral(path);
		if (entries == null) return false;
		for (e in entries)
			if ((e.flags & FLAG_ENCRYPTED) != 0 && e.method == 99) return true;
		#end
		return false;
	}

	/** Cheap password check: decrypts the 12 byte header of the first encrypted entry. */
	public static function checkPassword(path:String, pass:String):Bool {
		#if sys
		if (pass == null) return false;
		var entries = readCentral(path);
		if (entries == null) return false;
		try {
			var f = File.read(path, true);
			for (e in entries) {
				if ((e.flags & FLAG_ENCRYPTED) == 0 || e.method == 99) continue;
				var start = dataOffset(f, e);
				f.seek(start, SeekBegin);
				var head = f.read(12);
				f.close();
				if (head == null || head.length < 12) return false;
				var keys = new ZipCryptoKeys(pass);
				var last = 0;
				for (i in 0...12) {
					last = head.get(i) ^ keys.decryptByte();
					keys.update(last);
				}
				return last == verifyByte(e);
			}
			f.close();
		} catch (err:Dynamic) {}
		#end
		return false;
	}

	/** Cache file a decrypted copy of this zip would live in. */
	public static function cachePath(zipPath:String, key:String):String {
		var stamp = '';
		#if sys
		try {
			var st = FileSystem.stat(zipPath);
			stamp = Std.string(st.size) + ":" + Std.string(st.mtime);
		} catch (err:Dynamic) {}
		#end
		var digest = Sha256.encode(normalizePath(zipPath) + "|" + key + "|" + stamp);
		var stem = Path.withoutExtension(Path.withoutDirectory(zipPath));
		return cacheFolder + stem + "_pw_" + digest.substr(0, 20) + ".zip";
	}

	public static function hasCache(zipPath:String, key:String):Bool {
		#if sys
		try {
			return FileSystem.exists(cachePath(zipPath, key));
		} catch (err:Dynamic) {}
		#end
		return false;
	}

	/**
	 * Decrypts the archive into the cache folder and returns the readable copy.
	 * Throws when the password is wrong or the archive cannot be rewritten.
	 */
	public static function extractToCache(zipPath:String, pass:String):String {
		#if sys
		if (usesAES(zipPath)) throw "ZipPassword: AES encrypted archives are not supported";
		if (!checkPassword(zipPath, pass)) throw "ZipPassword: wrong password";

		var out = cachePath(zipPath, pass);
		if (FileSystem.exists(out)) return out;

		var entries = readCentral(zipPath);
		if (entries == null) throw "ZipPassword: cannot read the zip index";

		if (!FileSystem.exists(cacheFolder)) FileSystem.createDirectory(cacheFolder);

		var tmp = out + ".part";
		var input = File.read(zipPath, true);
		var output = File.write(tmp, true);
		var central = new BytesBuffer();
		var pos = 0;
		var count = 0;

		for (e in entries) {
			var data = readEntryData(input, e, pass);
			var crc = crc32(data);
			if (data.length > 0 && (e.flags & 0x8) == 0) {
				if (crc != e.crc) throw "ZipPassword: corrupted entry " + e.name;
			}

			var name = Bytes.ofString(e.name);
			var size = data.length;

			var local = new BytesBuffer();
			writeU32(local, 0x04034B50);
			writeU16(local, 20);
			writeU16(local, 0);
			writeU16(local, 0);
			writeU16(local, e.time);
			writeU16(local, e.date);
			writeU32(local, crc);
			writeU32(local, size);
			writeU32(local, size);
			writeU16(local, name.length);
			writeU16(local, 0);
			local.add(name);

			output.write(local.getBytes());
			if (size > 0) output.write(data);

			var head = new BytesBuffer();
			writeU32(head, 0x02014B50);
			writeU16(head, 20);
			writeU16(head, 20);
			writeU16(head, 0);
			writeU16(head, 0);
			writeU16(head, e.time);
			writeU16(head, e.date);
			writeU32(head, crc);
			writeU32(head, size);
			writeU32(head, size);
			writeU16(head, name.length);
			writeU16(head, 0);
			writeU16(head, 0);
			writeU16(head, 0);
			writeU16(head, 0);
			writeU32(head, 0);
			writeU32(head, pos);
			head.add(name);
			central.add(head.getBytes());

			pos += 30 + name.length + size;
			count++;
		}

		var cd = central.getBytes();
		var eocd = new BytesBuffer();
		writeU32(eocd, 0x06054B50);
		writeU16(eocd, 0);
		writeU16(eocd, 0);
		writeU16(eocd, count);
		writeU16(eocd, count);
		writeU32(eocd, cd.length);
		writeU32(eocd, pos);
		writeU16(eocd, 0);

		output.write(cd);
		output.write(eocd.getBytes());
		output.close();
		input.close();

		if (FileSystem.exists(out)) FileSystem.deleteFile(out);
		FileSystem.rename(tmp, out);
		return out;
		#else
		return null;
		#end
	}

	// ------------------------------------------------------------------- zip io

	static function readEntryData(f:FileInput, e:ZipEntry, pass:String):Bytes {
		#if sys
		f.seek(dataOffset(f, e), SeekBegin);
		var raw = e.csize > 0 ? f.read(e.csize) : Bytes.alloc(0);

		if ((e.flags & FLAG_ENCRYPTED) != 0) {
			if (e.method == 99) throw "ZipPassword: AES encrypted entries are not supported";
			raw = decryptEntry(raw, e, pass);
		}

		if (e.method == 0) return raw;
		if (e.method == 8) return inflate(raw, e.usize);
		throw "ZipPassword: unsupported compression method " + e.method;
		#else
		return null;
		#end
	}

	static function dataOffset(f:FileInput, e:ZipEntry):Int {
		f.seek(e.offset, SeekBegin);
		var head = f.read(30);
		if (head == null || head.length < 30) throw "ZipPassword: truncated local header";
		if (u32(head, 0) != 0x04034B50) throw "ZipPassword: bad local header";
		return e.offset + 30 + u16(head, 26) + u16(head, 28);
	}

	static function decryptEntry(raw:Bytes, e:ZipEntry, pass:String):Bytes {
		var keys = new ZipCryptoKeys(pass);
		var payload = Bytes.alloc(raw.length - 12);
		var last = 0;
		var i = 0;
		while (i < 12) {
			last = raw.get(i) ^ keys.decryptByte();
			keys.update(last);
			i++;
		}
		if (last != verifyByte(e)) throw "ZipPassword: wrong password";

		var out = 0;
		while (i < raw.length) {
			var c = raw.get(i) ^ keys.decryptByte();
			keys.update(c);
			payload.set(out++, c);
			i++;
		}
		return payload;
	}

	static function verifyByte(e:ZipEntry):Int {
		// with a data descriptor the time stamp stands in for the crc
		return ((e.flags & 0x8) != 0) ? ((e.time >>> 8) & 0xFF) : ((e.crc >>> 24) & 0xFF);
	}

	static function inflate(raw:Bytes, size:Int):Bytes {
		if (size <= 0) return Bytes.alloc(0);
		var out = Bytes.alloc(size);
		var c = new haxe.zip.Uncompress(-15);
		var r = c.execute(raw, 0, out, 0);
		c.close();
		if (!r.done || r.write != size) throw "ZipPassword: invalid compressed data";
		return out;
	}

	/** Reads the central directory (names, sizes, offsets) of the archive. */
	static function readCentral(path:String):Array<ZipEntry> {
		#if sys
		try {
			if (!FileSystem.exists(path) || FileSystem.isDirectory(path)) return null;
			var size = Std.int(FileSystem.stat(path).size);
			if (size < 22) return null;

			var f = File.read(path, true);
			var tailLen = size > 66560 ? 66560 : size;
			f.seek(size - tailLen, SeekBegin);
			var tail = f.read(tailLen);

			var eocd = -1;
			var i = tailLen - 4;
			while (i >= 0) {
				if (tail.get(i) == 0x50 && tail.get(i + 1) == 0x4B && tail.get(i + 2) == 0x05 && tail.get(i + 3) == 0x06) {
					eocd = i;
					break;
				}
				i--;
			}
			if (eocd < 0) {
				f.close();
				return null;
			}

			var cdSize = u32(tail, eocd + 12);
			var cdOffset = u32(tail, eocd + 16);
			if (cdSize <= 0 || cdOffset <= 0 || cdOffset + cdSize > size) {
				f.close();
				return null;
			}

			f.seek(cdOffset, SeekBegin);
			var cd = f.read(cdSize);
			f.close();

			var entries:Array<ZipEntry> = [];
			var p = 0;
			while (p + 46 <= cdSize && u32(cd, p) == 0x02014B50) {
				var flags = u16(cd, p + 8);
				var method = u16(cd, p + 10);
				var time = u16(cd, p + 12);
				var date = u16(cd, p + 14);
				var crc = u32(cd, p + 16);
				var csize = u32(cd, p + 20);
				var usize = u32(cd, p + 24);
				var nlen = u16(cd, p + 28);
				var elen = u16(cd, p + 30);
				var clen = u16(cd, p + 32);
				var offset = u32(cd, p + 42);
				var name = cd.getString(p + 46, nlen);
				entries.push({
					name: name,
					flags: flags,
					method: method,
					time: time,
					date: date,
					crc: crc,
					csize: csize,
					usize: usize,
					offset: offset
				});
				p += 46 + nlen + elen + clen;
			}
			return entries;
		} catch (err:Dynamic) {}
		#end
		return null;
	}

	static function normalizePath(path:String):String {
		if (path == null) return "";
		return StringTools.replace(StringTools.trim(path.toLowerCase()), "\\", "/");
	}

	// ---------------------------------------------------------------- byte utils

	static inline function u16(b:Bytes, p:Int):Int
		return b.get(p) | (b.get(p + 1) << 8);

	static inline function u32(b:Bytes, p:Int):Int
		return b.get(p) | (b.get(p + 1) << 8) | (b.get(p + 2) << 16) | (b.get(p + 3) << 24);

	static inline function writeU16(b:BytesBuffer, v:Int) {
		b.addByte(v & 0xFF);
		b.addByte((v >>> 8) & 0xFF);
	}

	static inline function writeU32(b:BytesBuffer, v:Int) {
		b.addByte(v & 0xFF);
		b.addByte((v >>> 8) & 0xFF);
		b.addByte((v >>> 16) & 0xFF);
		b.addByte((v >>> 24) & 0xFF);
	}

	static var crcTable:Array<Int> = null;

	static function makeCrcTable():Array<Int> {
		var table = [];
		for (n in 0...256) {
			var c = n;
			for (k in 0...8) c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
			table.push(c);
		}
		return table;
	}

	public static function crcUpdate(crc:Int, byte:Int):Int {
		if (crcTable == null) crcTable = makeCrcTable();
		return crcTable[(crc ^ byte) & 0xFF] ^ (crc >>> 8);
	}

	public static function crc32(data:Bytes):Int {
		if (crcTable == null) crcTable = makeCrcTable();
		var crc = -1;
		for (i in 0...data.length)
			crc = crcTable[(crc ^ data.get(i)) & 0xFF] ^ (crc >>> 8);
		return ~crc;
	}
}

typedef ZipEntry = {
	var name:String;
	var flags:Int;
	var method:Int;
	var time:Int;
	var date:Int;
	var crc:Int;
	var csize:Int;
	var usize:Int;
	var offset:Int;
}

/** Traditional PKWARE ("ZipCrypto") key schedule. */
class ZipCryptoKeys {
	var k0:Int = 0x12345678;
	var k1:Int = 0x23456789;
	var k2:Int = 0x34567890;

	public function new(password:String) {
		if (password != null) {
			for (i in 0...password.length)
				update(password.charCodeAt(i) & 0xFF);
		}
	}

	public function update(byte:Int) {
		k0 = ZipPassword.crcUpdate(k0, byte);
		k1 = mulStep(k1, k0);
		k2 = ZipPassword.crcUpdate(k2, (k1 >>> 24) & 0xFF);
	}

	public function decryptByte():Int {
		var t = (k2 | 2) & 0xFFFF;
		// multiplied as floats: the product can pass 2^31 and must not overflow
		var p:Float = t * 1.0 * (t ^ 1);
		return Std.int(p / 256.0) & 0xFF;
	}

	static function mulStep(k1:Int, k0:Int):Int {
		// k1 = (k1 + (k0 & 0xFF)) * 134775813 + 1, all modulo 2^32.
		// Float math keeps every intermediate exact (each product stays below 2^53),
		// which avoids relying on 32 bit multiplication overflow.
		var v:Float = k1 < 0 ? k1 + 4294967296.0 : k1;
		v += (k0 & 0xFF);
		if (v >= 4294967296.0) v -= 4294967296.0;

		var low:Float = v % 65536.0;
		var high:Float = Math.floor(v / 65536.0);

		var product:Float = (low * 134775813.0) % 4294967296.0;
		product += ((high * 134775813.0) % 65536.0) * 65536.0;
		product = (product + 1.0) % 4294967296.0;

		return product >= 2147483648.0 ? Std.int(product - 4294967296.0) : Std.int(product);
	}
}
