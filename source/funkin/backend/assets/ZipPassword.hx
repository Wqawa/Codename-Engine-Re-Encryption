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
 * keeps every entry's original compression and its already deflated bytes - only
 * the encryption header is stripped - so it is about the size of the pack itself
 * and no decompression happens while it is written.
 *
 * AES protected zips (method 99, what 7-Zip and WinRAR write for "AES-256") are
 * handled by ZipAes.
 */
class ZipPassword {
	/** Folder the decrypted copies are written to (shared with ModPackCrypto). */
	public static var cacheFolder(get, never):String;

	static inline function get_cacheFolder():String return ModPackCrypto.cacheFolder;

	public static inline var FLAG_ENCRYPTED:Int = 0x1;

	/**
	 * Entries up to this size are inflated once while the copy is written, purely to
	 * check their CRC. Scripts, charts and configs live in that range; the large media
	 * files, which are most of the bytes, are copied without ever being decompressed.
	 */
	static inline var VERIFY_MAX_USIZE:Int = 1048576;

	/** True when at least one entry of the zip needs a password. */
	public static function isProtected(path:String):Bool {
		#if sys
		var entries = readCentral(path);
		if (entries == null) {
			// The central directory may be unreadable (zip64 variations, a tool that
			// rewrote offsets); fall back to the flags of the first local header so a
			// password protected zip is still recognised instead of being handed to
			// the plain zip reader, which would crash on its encrypted entries.
			return (localHeaderFlags(path) & FLAG_ENCRYPTED) != 0;
		}
		for (e in entries)
			if ((e.flags & FLAG_ENCRYPTED) != 0) return true;
		#end
		return false;
	}

	/** General purpose flags of the first local file header (0 when there is none). */
	public static function localHeaderFlags(path:String):Int {
		#if sys
		try {
			if (!FileSystem.exists(path) || FileSystem.isDirectory(path)) return 0;
			var f = File.read(path, true);
			var head = f.read(10);
			f.close();
			if (head == null || head.length < 10) return 0;
			if (head.get(0) != 0x50 || head.get(1) != 0x4B || head.get(2) != 0x03 || head.get(3) != 0x04) return 0;
			return u16(head, 6);
		} catch (err:Dynamic) {}
		#end
		return 0;
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
				if ((e.flags & FLAG_ENCRYPTED) == 0) continue;
				if (e.method == 99) {
					var ok = ZipAes.checkPassword(f, e, pass);
					f.close();
					return ok;
				}
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
		return cacheFolder + ModPackCrypto.CACHE_PREFIX + stem + "_pw_" + digest.substr(0, 20) + ".zip";
	}

	public static function hasCache(zipPath:String, key:String):Bool {
		#if sys
		try {
			ModPackCrypto.initCache();
			return FileSystem.exists(cachePath(zipPath, key));
		} catch (err:Dynamic) {}
		#end
		return false;
	}

	/**
	 * Decrypts the archive into the cache folder and returns the readable copy.
	 * Throws when the password is wrong or the archive cannot be rewritten.
	 */
	public static function extractToCache(zipPath:String, pass:String, ?onProgress:Float->Void):String {
		#if sys
		if (!checkPassword(zipPath, pass)) throw "ZipPassword: wrong password";

		var out = cachePath(zipPath, pass);
		if (FileSystem.exists(out)) return out;

		var entries = readCentral(zipPath);
		if (entries == null) throw "ZipPassword: cannot read the zip index";

		ModPackCrypto.ensureCacheFolder();

		var tmp = out + ".part";
		var input = File.read(zipPath, true);
		var output = File.write(tmp, true);
		try {
			var central = new BytesBuffer();
			var pos = 0;
			var count = 0;

			var done = 0;
			var entryCount = entries.length;
			for (e in entries) {
				if (onProgress != null) onProgress(done / entryCount);
				done++;
				// Only the encryption header is stripped: the entry keeps its original
				// compression method and its already deflated bytes, so nothing is
				// re-compressed and the copy is about the size of the pack itself.
				var entry = readRawEntry(input, e, pass);
				var method = entry.method;
				var payload = entry.data;
				var crc = e.crc;
				var usize = e.usize;

				// The copy keeps the entry's method, so only what this reader can hand to
				// the engine (stored or deflated) may end up in it.
				if (method != 0 && method != 8)
					throw "ZipPassword: unsupported compression method " + method;

				if (e.method == 99 || crc == 0) {
					// WinZip AE-2 writes 0 in the crc field (its auth code covers the data),
					// so a copy that other tools can read needs a real crc: inflate once.
					var plain = method == 8 ? inflate(payload, usize) : payload;
					crc = crc32(plain);
					usize = plain.length;
				} else if (method == 8 && usize <= VERIFY_MAX_USIZE) {
					// Sanity check while it is still cheap: scripts, charts and configs are
					// small, and catching a bad entry here beats an obscure failure later when
					// the engine reads the cached copy. Big media is left to the CRC stored in
					// the archive - inflating it here is exactly what this rewrite avoids.
					if (crc32(inflate(payload, usize)) != crc) throw "ZipPassword: corrupted entry " + e.name;
				} else if (method == 0 && payload.length != usize) {
					throw "ZipPassword: corrupted entry " + e.name;
				}

				var name = Bytes.ofString(e.name);
				var size = payload.length;
				// Keep the UTF-8 name flag of the original archive, and set it for a name
				// that needs it: the bytes written below are always UTF-8, so dropping the
				// flag made non-ASCII file names unreadable. The data descriptor flag (0x8)
				// is not needed any more because sizes are written into the header.
				var flags = ((e.flags & 0x800) != 0 || !isAscii(e.name)) ? 0x800 : 0;

				var local = new BytesBuffer();
				writeU32(local, 0x04034B50);
				writeU16(local, 20);
				writeU16(local, flags);
				writeU16(local, method);
				writeU16(local, e.time);
				writeU16(local, e.date);
				writeU32(local, crc);
				writeU32(local, size);
				writeU32(local, usize);
				writeU16(local, name.length);
				writeU16(local, 0);
				local.add(name);

				output.write(local.getBytes());
				if (size > 0) output.write(payload);

				var head = new BytesBuffer();
				writeU32(head, 0x02014B50);
				writeU16(head, 20);
				writeU16(head, 20);
				writeU16(head, flags);
				writeU16(head, method);
				writeU16(head, e.time);
				writeU16(head, e.date);
				writeU32(head, crc);
				writeU32(head, size);
				writeU32(head, usize);
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
		} catch (err:Dynamic) {
			// a half written .part file and two open handles used to be left behind
			try { output.close(); } catch (e2:Dynamic) {}
			try { input.close(); } catch (e2:Dynamic) {}
			try { if (FileSystem.exists(tmp)) FileSystem.deleteFile(tmp); } catch (e2:Dynamic) {}
			throw err;
		}

		if (FileSystem.exists(out)) FileSystem.deleteFile(out);
		FileSystem.rename(tmp, out);
		ModPackCrypto.hideCacheFile(out);
		return out;
		#else
		return null;
		#end
	}

	// ------------------------------------------------------------------- zip io

	/**
	 * Reads one entry and strips its encryption, leaving the payload exactly as the
	 * archive stores it: still deflated, not yet inflated. `method` is the compression
	 * method the payload actually uses, which differs from the entry's own method for
	 * WinZip AES entries (they report 99 and carry the real method in the extra field).
	 */
	public static function readRawEntry(f:FileInput, e:ZipEntry, pass:String):{data:haxe.io.Bytes, method:Int} {
		#if sys
		f.seek(dataOffset(f, e), SeekBegin);
		var raw = e.csize > 0 ? f.read(e.csize) : Bytes.alloc(0);

		var method = e.method;
		if ((e.flags & FLAG_ENCRYPTED) != 0) {
			if (e.method == 99) {
				var plain = ZipAes.decryptEntry(raw, e, pass);
				raw = plain.data;
				method = plain.method;
			} else {
				raw = decryptEntry(raw, e, pass);
			}
		}

		return {data: raw, method: method};
		#else
		return null;
		#end
	}

	public static function dataOffset(f:FileInput, e:ZipEntry):Int {
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
	public static function readCentral(path:String):Array<ZipEntry> {
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

			if (cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
				// zip64: the real values live in the zip64 end of central directory record
				var rec = readZip64End(f, tail, eocd);
				if (rec != null) {
					cdSize = rec.cdSize;
					cdOffset = rec.cdOffset;
				}
			}

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
				var extra = elen > 0 ? cd.sub(p + 46 + nlen, elen) : null;
				entries.push({
					name: name,
					flags: flags,
					method: method,
					time: time,
					date: date,
					crc: crc,
					csize: csize,
					usize: usize,
					offset: offset,
					extra: extra
				});
				p += 46 + nlen + elen + clen;
			}
			return entries;
		} catch (err:Dynamic) {}
		#end
		return null;
	}

	/**
	 * Reads the zip64 end of central directory record, located through the zip64
	 * locator that sits right before the normal EOCD.
	 */
	#if sys
	static function readZip64End(f:FileInput, tail:Bytes, eocd:Int):{cdSize:Int, cdOffset:Int} {
		var loc = -1;
		var i = eocd - 20;
		while (i >= 0) {
			if (tail.get(i) == 0x50 && tail.get(i + 1) == 0x4B && tail.get(i + 2) == 0x06 && tail.get(i + 3) == 0x07) {
				loc = i;
				break;
			}
			i--;
		}
		if (loc < 0) return null;
		var offset = u32(tail, loc + 8);
		if (offset < 0) return null;
		try {
			// read just the fields we need: 56 byte record
			f.seek(offset, SeekBegin);
			var rec = f.read(56);
			if (rec == null || rec.length < 56) return null;
			if (!(rec.get(0) == 0x50 && rec.get(1) == 0x4B && rec.get(2) == 0x06 && rec.get(3) == 0x06)) return null;
			return {cdSize: u32(rec, 40), cdOffset: u32(rec, 48)};
		} catch (err:Dynamic) {}
		return null;
	}
	#end

	/** True when the name only needs the ASCII subset, so no UTF-8 flag is required. */
	public static function isAscii(name:String):Bool {
		if (name == null) return true;
		for (i in 0...name.length)
			if (name.charCodeAt(i) > 0x7F) return false;
		return true;
	}

	static function normalizePath(path:String):String {
		if (path == null) return "";
		return StringTools.replace(StringTools.trim(path.toLowerCase()), "\\", "/");
	}

	// ---------------------------------------------------------------- byte utils

	public static inline function u16(b:Bytes, p:Int):Int
		return b.get(p) | (b.get(p + 1) << 8);

	public static inline function u32(b:Bytes, p:Int):Int
		return b.get(p) | (b.get(p + 1) << 8) | (b.get(p + 2) << 16) | (b.get(p + 3) << 24);

	public static inline function writeU16(b:BytesBuffer, v:Int) {
		b.addByte(v & 0xFF);
		b.addByte((v >>> 8) & 0xFF);
	}

	public static inline function writeU32(b:BytesBuffer, v:Int) {
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
	/** Raw central directory extra field, needed for the WinZip AES header. */
	var extra:Bytes;
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
		var other = t ^ 1;
		// Byte 1 of t * other, computed from the four 8 bit halves so no product
		// ever exceeds 32 bits. About twice as fast as the float division, and it
		// behaves identically on every target (including JS, where >> is 32 bit).
		var al = t & 0xFF, ah = t >>> 8;
		var bl = other & 0xFF, bh = other >>> 8;
		return (al * bh + ah * bl + ((al * bl) >>> 8)) & 0xFF;
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
