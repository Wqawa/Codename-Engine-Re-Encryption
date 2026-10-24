package funkin.backend.assets;

import funkin.backend.assets.ZipPassword;
import funkin.backend.assets.ZipPassword.ZipEntry;
import funkin.backend.scripting.crypto.Aes;
import funkin.backend.scripting.crypto.HmacSha1;
import funkin.backend.scripting.crypto.Pbkdf2;
#if sys
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.FileSystem;
import sys.io.File;
import sys.io.FileInput;
#end

/**
 * WinZip AES support ("AES-256" in 7-Zip / WinRAR), method 99.
 *
 * Entries carry a 0x9901 extra field that says which key size was used and
 * which compression method sits underneath the encryption. The payload is
 *   salt (8/12/16) + password verification (2) + AES-CTR ciphertext + auth (10)
 * with keys from PBKDF2-HMAC-SHA1 (1000 iterations) and a truncated HMAC-SHA1
 * over the ciphertext as the integrity check.
 *
 * This class both reads such archives (so a password protected zip can be
 * dropped into the mods folder) and writes them (the "standard password zip"
 * export of the encryption tool, readable by 7-Zip, WinRAR, Bandizip, ...).
 */
class ZipAes {
	static inline var EXTRA_ID:Int = 0x9901;
	static inline var AUTH_LEN:Int = 10;

	static var SALT_FOR_STRENGTH:Array<Int> = [0, 8, 12, 16];
	static var KEY_FOR_STRENGTH:Array<Int> = [0, 16, 24, 32];

	// ------------------------------------------------------------------ reading

	public static function aesInfo(e:ZipEntry):AesInfo {
		if (e == null || e.extra == null) return null;
		var extra = e.extra;
		var p = 0;
		while (p + 4 <= extra.length) {
			var id = ZipPassword.u16(extra, p);
			var size = ZipPassword.u16(extra, p + 2);
			if (id == EXTRA_ID) {
				if (size < 7 || p + 4 + 7 > extra.length) return null;
				var version = ZipPassword.u16(extra, p + 4);
				var strength = extra.get(p + 8);
				if (strength < 1 || strength > 3) return null;
				return {
					version: version,
					strength: strength,
					saltLen: SALT_FOR_STRENGTH[strength],
					keyLen: KEY_FOR_STRENGTH[strength],
					method: ZipPassword.u16(extra, p + 9)
				};
			}
			p += 4 + size;
		}
		return null;
	}

	/** Cheap check: derives the keys and compares the 2 byte password value. */
	public static function checkPassword(f:FileInput, e:ZipEntry, pass:String):Bool {
		var info = aesInfo(e);
		if (info == null) return false;
		f.seek(ZipPassword.dataOffset(f, e), SeekBegin);
		var raw = f.read(info.saltLen + 2);
		if (raw == null || raw.length < info.saltLen + 2) return false;
		var salt = raw.sub(0, info.saltLen);
		var keys = deriveKeys(pass, salt, info.keyLen);
		var pv = raw.sub(info.saltLen, 2);
		return keys.pv.get(0) == pv.get(0) && keys.pv.get(1) == pv.get(1);
	}

	/** Decrypts one AES entry; returns the plain (deflated) bytes and the real method. */
	public static function decryptEntry(raw:Bytes, e:ZipEntry, pass:String):{data:Bytes, method:Int} {
		var info = aesInfo(e);
		if (info == null) throw "ZipAes: entry has no AES header";

		var overhead = info.saltLen + 2 + AUTH_LEN;
		if (raw.length < overhead) throw "ZipAes: truncated AES entry";

		var salt = raw.sub(0, info.saltLen);
		var keys = deriveKeys(pass, salt, info.keyLen);

		var pv = raw.sub(info.saltLen, 2);
		if (keys.pv.get(0) != pv.get(0) || keys.pv.get(1) != pv.get(1))
			throw "ZipPassword: wrong password";

		var cipherLen = raw.length - overhead;
		var cipher = raw.sub(info.saltLen + 2, cipherLen);
		var auth = raw.sub(info.saltLen + 2 + cipherLen, AUTH_LEN);

		var tag = HmacSha1.hash(keys.mac, cipher);
		var diff = 0;
		for (i in 0...AUTH_LEN) diff |= tag.get(i) ^ auth.get(i);
		if (diff != 0) throw "ZipPassword: wrong password or corrupted AES entry";

		return {data: Aes.ctrCrypt(keys.enc, cipher), method: info.method};
	}

	// ------------------------------------------------------------------ writing

	/**
	 * Rewrites a plain zip as an AES-256 (WinZip AE-2) password zip. The
	 * compressed bytes are carried over untouched, so nothing is re-compressed
	 * and the output can be opened by any tool that knows WinZip AES.
	 */
	public static function encryptZip(srcPath:String, outPath:String, pass:String, ?onProgress:Float->Void):Void {
		#if sys
		if (pass == null || pass.length == 0) throw "ZipAes: missing password";

		var entries = ZipPassword.readCentral(srcPath);
		if (entries == null) throw "ZipAes: cannot read the zip index";

		var input = File.read(srcPath, true);
		var tmp = outPath + ".part";
		var output = File.write(tmp, true);
		try {
			var central = new BytesBuffer();
			var pos = 0;
			var count = 0;

			for (e in entries) {
				var name = Bytes.ofString(e.name);
				var isDir = e.name.length > 0 && StringTools.endsWith(e.name, "/");
				var local = new BytesBuffer();
				var data:Bytes;
				// Always mark a non-ASCII name as UTF-8: the bytes below are UTF-8,
				// and a missing 0x800 flag made such names unreadable when unzipped.
				var flags = ((e.flags & 0x0800) != 0 || !ZipPassword.isAscii(e.name)) ? 0x0800 : 0;

				if (isDir) {
					data = Bytes.alloc(0);
					writeLocalHeader(local, e, 20, flags, 0, 0, 0, name, null);
				} else {
					input.seek(ZipPassword.dataOffset(input, e), SeekBegin);
					var raw = e.csize > 0 ? input.read(e.csize) : Bytes.alloc(0);

					var salt = randomBytes(16);
					var keys = deriveKeys(pass, salt, 32);
					var cipher = Aes.ctrCrypt(keys.enc, raw);
					var tag = HmacSha1.hash(keys.mac, cipher);

					data = Bytes.alloc(salt.length + 2 + cipher.length + AUTH_LEN);
					data.blit(0, salt, 0, salt.length);
					data.set(salt.length, keys.pv.get(0));
					data.set(salt.length + 1, keys.pv.get(1));
					data.blit(salt.length + 2, cipher, 0, cipher.length);
					data.blit(salt.length + 2 + cipher.length, tag, 0, AUTH_LEN);

					var extra = aesExtra(2, 3, e.method);
					// AE-2 stores 0 in the crc fields; the AES auth code replaces it
					writeLocalHeader(local, e, 51, flags | 0x1, 99, 0, data.length, name, extra);
				}

				output.write(local.getBytes());
				if (data.length > 0) output.write(data);

				var head = new BytesBuffer();
				ZipPassword.writeU32(head, 0x02014B50);
				ZipPassword.writeU16(head, 20);
				ZipPassword.writeU16(head, isDir ? 20 : 51);
				ZipPassword.writeU16(head, isDir ? flags : (flags | 0x1));
				ZipPassword.writeU16(head, isDir ? 0 : 99);
				ZipPassword.writeU16(head, e.time);
				ZipPassword.writeU16(head, e.date);
				ZipPassword.writeU32(head, 0);
				ZipPassword.writeU32(head, data.length);
				ZipPassword.writeU32(head, isDir ? 0 : e.usize);
				ZipPassword.writeU16(head, name.length);
				var extra = isDir ? null : aesExtra(2, 3, e.method);
				ZipPassword.writeU16(head, extra == null ? 0 : extra.length);
				ZipPassword.writeU16(head, 0);
				ZipPassword.writeU16(head, 0);
				ZipPassword.writeU16(head, 0);
				ZipPassword.writeU32(head, 0);
				ZipPassword.writeU32(head, pos);
				head.add(name);
				if (extra != null) head.add(extra);
				central.add(head.getBytes());

				pos += 30 + name.length + (isDir ? 0 : (extra == null ? 0 : extra.length)) + data.length;
				count++;
				// one entry per call: a pack has hundreds of them, so the bar moves
				if (onProgress != null && entries.length > 0) onProgress(count / entries.length);
			}

			var cd = central.getBytes();
			var eocd = new BytesBuffer();
			ZipPassword.writeU32(eocd, 0x06054B50);
			ZipPassword.writeU16(eocd, 0);
			ZipPassword.writeU16(eocd, 0);
			ZipPassword.writeU16(eocd, count);
			ZipPassword.writeU16(eocd, count);
			ZipPassword.writeU32(eocd, cd.length);
			ZipPassword.writeU32(eocd, pos);
			ZipPassword.writeU16(eocd, 0);

			output.write(cd);
			output.write(eocd.getBytes());
			output.close();
			input.close();
		} catch (err:Dynamic) {
			try { output.close(); } catch (e2:Dynamic) {}
			try { input.close(); } catch (e2:Dynamic) {}
			try { if (FileSystem.exists(tmp)) FileSystem.deleteFile(tmp); } catch (e2:Dynamic) {}
			throw err;
		}

		if (FileSystem.exists(outPath)) FileSystem.deleteFile(outPath);
		FileSystem.rename(tmp, outPath);
		if (onProgress != null) onProgress(1);
		#end
	}

	static function writeLocalHeader(buf:BytesBuffer, e:ZipEntry, version:Int, flags:Int, method:Int, crc:Int, csize:Int, name:Bytes,
			extra:Bytes):Void {
		ZipPassword.writeU32(buf, 0x04034B50);
		ZipPassword.writeU16(buf, version);
		ZipPassword.writeU16(buf, flags);
		ZipPassword.writeU16(buf, method);
		ZipPassword.writeU16(buf, e.time);
		ZipPassword.writeU16(buf, e.date);
		ZipPassword.writeU32(buf, crc);
		ZipPassword.writeU32(buf, csize);
		ZipPassword.writeU32(buf, e.usize);
		ZipPassword.writeU16(buf, name.length);
		ZipPassword.writeU16(buf, extra == null ? 0 : extra.length);
		buf.add(name);
		if (extra != null) buf.add(extra);
	}

	/** 0x9901 field: AE version (2), vendor "AE", strength (3 = AES-256), method. */
	public static function aesExtra(version:Int, strength:Int, method:Int):Bytes {
		var buf = new BytesBuffer();
		ZipPassword.writeU16(buf, EXTRA_ID);
		ZipPassword.writeU16(buf, 7);
		ZipPassword.writeU16(buf, version);
		buf.addByte(0x41); // 'A'
		buf.addByte(0x45); // 'E'
		buf.addByte(strength);
		ZipPassword.writeU16(buf, method);
		return buf.getBytes();
	}

	// ------------------------------------------------------------------ keys

	static var saltSeed:Float = -1;

	/** Salt only has to be unique, not secret; a time seeded generator is enough. */
	static function randomBytes(n:Int):Bytes {
		var out = Bytes.alloc(n);
		if (saltSeed < 0) saltSeed = Date.now().getTime() + Math.random() * 65536.0;
		for (i in 0...n) {
			saltSeed = (saltSeed * 1103515245.0 + 12345.0) % 2147483648.0;
			out.set(i, Std.int(saltSeed / 65536.0) & 0xFF);
		}
		return out;
	}

	static function deriveKeys(pass:String, salt:Bytes, keyLen:Int):AesKeys {
		var material = Pbkdf2.deriveSHA1(Bytes.ofString(pass == null ? "" : pass), salt,
			Pbkdf2.WINZIP_ITERATIONS, keyLen * 2 + 2);
		return {
			enc: material.sub(0, keyLen),
			mac: material.sub(keyLen, keyLen),
			pv: material.sub(keyLen * 2, 2)
		};
	}
}

typedef AesInfo = {
	var version:Int;
	var strength:Int;
	var saltLen:Int;
	var keyLen:Int;
	var method:Int;
}

typedef AesKeys = {
	var enc:Bytes;
	var mac:Bytes;
	var pv:Bytes;
}
