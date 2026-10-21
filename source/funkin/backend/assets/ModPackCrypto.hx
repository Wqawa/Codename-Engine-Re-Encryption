package funkin.backend.assets;

import funkin.backend.scripting.crypto.ChaCha20;
import funkin.backend.scripting.crypto.ScriptCrypto;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Path;
#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * Encrypted container for zip mod packs.
 *
 * Layout (little endian), identical in spirit to the script container but with
 * its own magic so a script can never be mistaken for a mod pack:
 *   0..3    magic "CNEZ"
 *   4       format version (1)
 *   5..7    reserved
 *   8..23   random salt (16)
 *   24..35  random nonce (12)
 *   36..39  payload length
 *   40..    ChaCha20 ciphertext of the raw .zip bytes
 *   ...     HMAC-SHA256 over everything above (32 bytes)
 *
 * The key is the same kind of key the script encryption uses, so a publisher
 * can hand out either the key itself or a key token (see ScriptCrypto).
 */
class ModPackCrypto {
	public static var MAGIC:Array<Int> = [0x43, 0x4E, 0x45, 0x5A]; // "CNEZ"
	public static inline var VERSION:Int = 1;

	static inline var HEADER_SIZE:Int = 40;
	static inline var TAG_SIZE:Int = 32;
	static inline var SALT_SIZE:Int = 16;
	static inline var NONCE_SIZE:Int = 12;

	/** Folder the decrypted copies are written to. */
	public static var cacheFolder:String = './.cne_mods/';

	/** Key typed by the player this session, per pack path. */
	static var sessionKeys:Map<String, String> = new Map<String, String>();

	/** Set when the player chose "play without mods" after a bad key. */
	public static var disableMods: Bool = false;

	public static function normalizePath(path:String):String {
		if (path == null) return "";
		return StringTools.replace(StringTools.trim(path.toLowerCase()), "\\", "/");
	}

	// ------------------------------------------------------------- detection

	public static function isEncryptedPack(data:Bytes):Bool {
		if (data == null || data.length < HEADER_SIZE + TAG_SIZE) return false;
		for (i in 0...4)
			if (data.get(i) != MAGIC[i]) return false;
		return true;
	}

	public static function isEncryptedPackFile(path:String):Bool {
		#if sys
		try {
			if (!FileSystem.exists(path) || FileSystem.isDirectory(path)) return false;
			var handle = File.read(path, true);
			var head = handle.read(4);
			handle.close();
			if (head == null || head.length < 4) return false;
			for (i in 0...4)
				if (head.get(i) != MAGIC[i]) return false;
			return true;
		} catch (e:Dynamic) {}
		#end
		return false;
	}

	/** A raw zip starts with "PK". */
	public static function looksLikeZip(data:Bytes):Bool {
		if (data == null || data.length < 4) return false;
		return data.get(0) == 0x50 && data.get(1) == 0x4B;
	}

	/**
	 * True when the pack cannot be read without a password: either a CNEZ
	 * container or a plain zip whose entries were password protected.
	 */
	public static function needsKey(zipPath:String):Bool {
		if (isEncryptedPackFile(zipPath)) return true;
		return ZipPassword.isProtected(zipPath);
	}

	/** True when the pack uses a protection scheme this engine cannot open at all. */
	public static function usesUnsupportedEncryption(zipPath:String):Bool {
		if (isEncryptedPackFile(zipPath)) return false;
		return ZipPassword.usesAES(zipPath);
	}

	/** Human readable reason why a pack will never load, or null when a key helps. */
	public static function packProblem(zipPath:String):String {
		if (usesUnsupportedEncryption(zipPath))
			return "This zip uses AES encryption, which the engine cannot read. Ask the author for a CNEZ pack or a zip using classic (ZipCrypto) password protection.";
		return null;
	}

	// ------------------------------------------------------------ container

	public static function pack(zipBytes:Bytes, ?pass:String):Bytes {
		if (pass == null) pass = ScriptCrypto.getPassword();
		pass = ScriptCrypto.resolveKeyValue(pass);

		var salt = ScriptCrypto.randomBytes(SALT_SIZE);
		var nonce = ScriptCrypto.randomBytes(NONCE_SIZE);
		var keys = ScriptCrypto.deriveKeys(pass, salt);
		var cipher = ChaCha20.xorBytes(keys.enc, nonce, 1, zipBytes);

		var buf = new BytesBuffer();
		for (v in MAGIC) buf.addByte(v);
		buf.addByte(VERSION);
		buf.addByte(0);
		buf.addByte(0);
		buf.addByte(0);
		buf.add(salt);
		buf.add(nonce);
		var len = cipher.length;
		buf.addByte(len & 0xFF);
		buf.addByte((len >>> 8) & 0xFF);
		buf.addByte((len >>> 16) & 0xFF);
		buf.addByte((len >>> 24) & 0xFF);
		buf.add(cipher);
		var body = buf.getBytes();

		var out = new BytesBuffer();
		out.add(body);
		out.add(ScriptCrypto.hmacTag(keys.mac, body));
		return out.getBytes();
	}

	public static function unpack(data:Bytes, ?pass:String):Bytes {
		if (pass == null) pass = ScriptCrypto.getPassword();
		pass = ScriptCrypto.resolveKeyValue(pass);

		if (!isEncryptedPack(data))
			throw "ModPackCrypto: not an encrypted mod pack";
		if (data.get(4) != VERSION)
			throw 'ModPackCrypto: unsupported container version ' + data.get(4);

		var salt = Bytes.alloc(SALT_SIZE);
		for (i in 0...SALT_SIZE) salt.set(i, data.get(8 + i));
		var nonce = Bytes.alloc(NONCE_SIZE);
		for (i in 0...NONCE_SIZE) nonce.set(i, data.get(24 + i));

		var len = data.get(36) | (data.get(37) << 8) | (data.get(38) << 16) | (data.get(39) << 24);
		if (len < 0 || HEADER_SIZE + len + TAG_SIZE != data.length)
			throw "ModPackCrypto: corrupted container (bad length)";

		var body = Bytes.alloc(HEADER_SIZE + len);
		for (i in 0...(HEADER_SIZE + len)) body.set(i, data.get(i));
		var tag = Bytes.alloc(TAG_SIZE);
		for (i in 0...TAG_SIZE) tag.set(i, data.get(HEADER_SIZE + len + i));

		var keys = ScriptCrypto.deriveKeys(pass, salt);
		var expected = ScriptCrypto.hmacTag(keys.mac, body);
		if (expected.length != tag.length) throw "ModPackCrypto: bad tag";
		var diff = 0;
		for (i in 0...tag.length) diff |= expected.get(i) ^ tag.get(i);
		if (diff != 0)
			throw "ModPackCrypto: integrity check failed (wrong key or corrupted file)";

		var cipher = Bytes.alloc(len);
		for (i in 0...len) cipher.set(i, data.get(HEADER_SIZE + i));
		return ChaCha20.xorBytes(keys.enc, nonce, 1, cipher);
	}

	// ------------------------------------------------------------ key lookup

	public static function setSessionKey(zipPath:String, key:String):Void {
		sessionKeys.set(normalizePath(zipPath), key);
	}

	public static function clearSessionKey(zipPath:String):Void {
		sessionKeys.remove(normalizePath(zipPath));
	}

	public static function getSessionKey(zipPath:String):String {
		return sessionKeys.get(normalizePath(zipPath));
	}

	public static function clearSessionKeys():Void {
		sessionKeys = new Map<String, String>();
	}

	/** Keys worth trying for a pack: the typed one first, then script_key.txt, then the built-in. */
	public static function candidateKeys(zipPath:String):Array<String> {
		var list:Array<String> = [];
		function push(k:String) {
			if (k == null) return;
			var v = ScriptCrypto.resolveKeyValue(k);
			if (v == null) return;
			for (e in list) if (e == v) return;
			list.push(v);
		}

		push(getSessionKey(zipPath));

		var stem = Path.withoutExtension(Path.withoutDirectory(zipPath));
		push(ScriptCrypto.getPassword(stem));
		push(ScriptCrypto.getPassword(Path.withoutExtension(zipPath)));
		push(ScriptCrypto.getPassword());
		return list;
	}

	// -------------------------------------------------------------- cache

	static function cachePath(zipPath:String, key:String):String {
		var stamp = '';
		#if sys
		try {
			var st = FileSystem.stat(zipPath);
			stamp = Std.string(st.size) + ":" + Std.string(st.mtime);
		} catch (e:Dynamic) {}
		#end
		var digest = ScriptCrypto.sha256(Bytes.ofString(normalizePath(zipPath) + "|" + key + "|" + stamp)).toHex();
		var stem = Path.withoutExtension(Path.withoutDirectory(zipPath));
		return cacheFolder + stem + "_" + digest.substr(0, 20) + ".zip";
	}

	static function cacheExistsFor(zipPath:String, key:String):Bool {
		#if sys
		try {
			return FileSystem.exists(cachePath(zipPath, key));
		} catch (e:Dynamic) {}
		#end
		return false;
	}

	/**
	 * Finds a key that actually opens the pack, decrypting it into the cache on
	 * the way. Returns null when none of the known keys work.
	 */
	public static function resolveKey(zipPath:String):String {
		#if sys
		var packed = isEncryptedPackFile(zipPath);
		var protectedZip = !packed && ZipPassword.isProtected(zipPath);
		if (!packed && !protectedZip) return null;
		if (protectedZip && ZipPassword.usesAES(zipPath)) return null;

		for (key in candidateKeys(zipPath)) {
			if (protectedZip) {
				// decrypting into the cache is the expensive step, so reuse it
				if (ZipPassword.hasCache(zipPath, key)) return key;
				try {
					ZipPassword.extractToCache(zipPath, key);
					return key;
				} catch (e:Dynamic) {}
			} else {
				if (cacheExistsFor(zipPath, key)) return key;
				try {
					var raw = File.getBytes(zipPath);
					var zip = unpack(raw, key);
					if (!looksLikeZip(zip)) continue;
					writeCache(zipPath, key, zip);
					return key;
				} catch (e:Dynamic) {}
			}
		}
		#end
		return null;
	}

	static function writeCache(zipPath:String, key:String, zip:Bytes):Void {
		#if sys
		var out = cachePath(zipPath, key);
		try {
			if (!FileSystem.exists(cacheFolder)) FileSystem.createDirectory(cacheFolder);
			File.saveBytes(out, zip);
		} catch (e:Dynamic) {}
		#end
	}

	/**
	 * Path that should be handed to ZipFolderLibrary: the decrypted copy for an
	 * encrypted pack, the pack itself otherwise. Returns null when the key is
	 * missing or wrong.
	 */
	public static function zipPathToLoad(zipPath:String):String {
		if (isEncryptedPackFile(zipPath)) {
			var key = resolveKey(zipPath);
			if (key == null) return null;
			return cachePath(zipPath, key);
		}
		if (ZipPassword.isProtected(zipPath)) {
			var key = resolveKey(zipPath);
			if (key == null) return null;
			return ZipPassword.cachePath(zipPath, key);
		}
		return zipPath;
	}

	/**
	 * Zip of a mod library (the "mods/Name" base path, without extension) that is
	 * encrypted and that no known key can open, or null.
	 *
	 * Only libraries the engine actually loads are asked about: a zip that merely
	 * sits in the mods folder must never interrupt a session that plays a different,
	 * unencrypted mod.
	 */
	public static function pendingPackFor(libPath:String):String {
		#if sys
		if (libPath == null) return null;
		try {
			var zip = libPath + ".zip";
			if (!FileSystem.exists(zip) || FileSystem.isDirectory(zip)) return null;
			if (!needsKey(zip)) return null;
			if (resolveKey(zip) == null) return zip;
		} catch (e:Dynamic) {}
		#end
		return null;
	}
}