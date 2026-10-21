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

	// ---------------------------------------------------- background prepare
	// Decrypting a big pack takes seconds, so the loading screen starts the work
	// on a worker thread and only polls these fields from the render loop.

	/** 0..1 progress of the pack currently being prepared. */
	public static var progress:Float = 0;
	/** File name of the pack being prepared (shown on the loading screen). */
	public static var progressLabel:String = "";
	/** True while the worker thread is still running. */
	public static var preparing:Bool = false;
	/** Set by the worker when it finished (success or not). */
	public static var prepareDone:Bool = false;
	/** Packs none of the known keys could open. */
	public static var prepareFailed:Array<String> = [];
	/**
	 * Packs whose prepare pass did not produce a cache file. They are skipped by
	 * packsNeedingWork so a broken pack cannot bounce between the loader and the
	 * progress screen forever; typing a new key clears the mark (see setSessionKey).
	 */
	static var failedPacks:Map<String, Bool> = new Map<String, Bool>();

	public static function hasFailedBefore(zipPath:String):Bool {
		return failedPacks.exists(normalizePath(zipPath));
	}

	public static function clearFailure(zipPath:String):Void {
		failedPacks.remove(normalizePath(zipPath));
	}

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

	/**
	 * True when the pack uses a protection scheme this engine cannot open at all.
	 * Both classic ZipCrypto and WinZip AES password zips are supported now, so
	 * only a container that is not a container at all ends up here.
	 */
	public static function usesUnsupportedEncryption(zipPath:String):Bool {
		return false;
	}

	/** Human readable reason why a pack will never load, or null when a key helps. */
	public static function packProblem(zipPath:String):String {
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

	public static function unpack(data:Bytes, ?pass:String, ?onProgress:Float->Void):Bytes {
		if (pass == null) pass = ScriptCrypto.getPassword();
		pass = ScriptCrypto.resolveKeyValue(pass);

		if (!isEncryptedPack(data))
			throw "ModPackCrypto: not an encrypted mod pack";
		if (data.get(4) != VERSION)
			throw 'ModPackCrypto: unsupported container version ' + data.get(4);

		// Bytes.sub() copies in one native call instead of a per-byte Haxe loop;
		// a large pack is copied twice here, so the loop was measurably slow.
		var salt = data.sub(8, SALT_SIZE);
		var nonce = data.sub(24, NONCE_SIZE);

		var len = data.get(36) | (data.get(37) << 8) | (data.get(38) << 16) | (data.get(39) << 24);
		if (len < 0 || HEADER_SIZE + len + TAG_SIZE != data.length)
			throw "ModPackCrypto: corrupted container (bad length)";

		var body = data.sub(0, HEADER_SIZE + len);
		var tag = data.sub(HEADER_SIZE + len, TAG_SIZE);

		var keys = ScriptCrypto.deriveKeys(pass, salt);
		var expected = ScriptCrypto.hmacTag(keys.mac, body);
		if (expected.length != tag.length) throw "ModPackCrypto: bad tag";
		var diff = 0;
		for (i in 0...tag.length) diff |= expected.get(i) ^ tag.get(i);
		if (diff != 0)
			throw "ModPackCrypto: integrity check failed (wrong key or corrupted file)";

		var cipher = data.sub(HEADER_SIZE, len);
		if (onProgress == null) return ChaCha20.xorBytes(keys.enc, nonce, 1, cipher);
		return ChaCha20.xorBytes(keys.enc, nonce, 1, cipher, function(p:Float) onProgress(0.2 + 0.8 * p));
	}

	// ------------------------------------------------------------ key lookup

	public static function setSessionKey(zipPath:String, key:String):Void {
		sessionKeys.set(normalizePath(zipPath), key);
		// a freshly typed key deserves a new attempt on the progress screen
		failedPacks.remove(normalizePath(zipPath));
	}

	/** Records that a full decryption attempt for this pack already failed. */
	public static function markFailed(zipPath:String):Void {
		failedPacks.set(normalizePath(zipPath), true);
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

	/** True when at least one key (typed, script_key.txt or built-in) is known. */
	public static function hasKnownKey(zipPath:String):Bool {
		return candidateKeys(zipPath).length > 0;
	}

	/** Memo for keyWorks(): decryption is never repeated for the same pack + key. */
	static var keyCheckCache:Map<String, Bool> = new Map<String, Bool>();
	static var keyCheckEntries:Int = 0;

	/**
	 * Cheap "does this key actually open the pack" check, so a wrong password can
	 * be rejected on the prompt itself instead of after a pointless loading screen.
	 *
	 * A CNEZ container only needs the first four bytes of the payload decrypted (a
	 * zip always starts with "PK"), so this costs a KDF run and nothing else; a
	 * password protected zip is verified through ZipPassword (12 byte entry header,
	 * or the AES password verifier).
	 */
	public static function keyWorks(zipPath:String, key:String):Bool {
		#if sys
		if (key == null) return false;
		var id = normalizePath(zipPath) + "|" + packStamp(zipPath) + "|" + key;
		if (keyCheckCache.exists(id)) return keyCheckCache.get(id);
		var ok = keyWorksUncached(zipPath, key);
		// The memo is not supposed to grow for the whole session: a player who
		// types a lot of wrong passwords should not leak one entry per try.
		// (Map has no size in Haxe 4.2, so the entries are counted on the side.)
		keyCheckEntries++;
		if (keyCheckEntries > 256) {
			keyCheckCache = new Map<String, Bool>();
			keyCheckEntries = 1;
		}
		keyCheckCache.set(id, ok);
		return ok;
		#else
		return false;
		#end
	}

	/** size:mtime of the pack, so a replaced file is never answered from a stale memo. */
	static function packStamp(zipPath:String):String {
		#if sys
		try {
			var st = FileSystem.stat(zipPath);
			return Std.string(st.size) + ":" + Std.string(st.mtime);
		} catch (e:Dynamic) {}
		#end
		return "";
	}

	static function keyWorksUncached(zipPath:String, key:String):Bool {
		#if sys
		var pass = ScriptCrypto.resolveKeyValue(key);
		if (pass == null) return false;
		try {
			if (isEncryptedPackFile(zipPath)) {
				var handle = File.read(zipPath, true);
				var head = handle.read(HEADER_SIZE);
				var probe = handle.read(4);
				handle.close();
				if (head == null || head.length < HEADER_SIZE || probe == null || probe.length < 4)
					return false;
				var keys = ScriptCrypto.deriveKeys(pass, head.sub(8, SALT_SIZE));
				var plain = ChaCha20.xorBytes(keys.enc, head.sub(24, NONCE_SIZE), 1, probe);
				// every zip magic (local header, empty archive, spanning marker) starts with "PK"
				return plain.get(0) == 0x50 && plain.get(1) == 0x4B;
			}
			if (ZipPassword.isProtected(zipPath)) return ZipPassword.checkPassword(zipPath, pass);
		} catch (e:Dynamic) {}
		#end
		return false;
	}

	/** True when one of the known keys really opens the pack (cheap check). */
	public static function hasWorkingKey(zipPath:String):Bool {
		for (key in candidateKeys(zipPath))
			if (keyWorks(zipPath, key)) return true;
		return false;
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
	public static function resolveKey(zipPath:String, ?onProgress:Float->Void):String {
		#if sys
		var packed = isEncryptedPackFile(zipPath);
		var protectedZip = !packed && ZipPassword.isProtected(zipPath);
		if (!packed && !protectedZip) return null;

		for (key in candidateKeys(zipPath)) {
			if (protectedZip) {
				// decrypting into the cache is the expensive step, so reuse it
				if (ZipPassword.hasCache(zipPath, key)) return key;
				try {
					ZipPassword.extractToCache(zipPath, key, onProgress);
					return key;
				} catch (e:Dynamic) {}
			} else {
				if (cacheExistsFor(zipPath, key)) return key;
				try {
					var raw = File.getBytes(zipPath);
					var zip = unpack(raw, key, onProgress);
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
		// A pack the prepare pass already failed on must not be decrypted again
		// synchronously on the main thread; typing a new key clears the mark.
		if (hasFailedBefore(zipPath)) return null;
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
			// Never decrypt here: this runs on the main thread from the startup
			// check, so only ask for a key when none of the known keys works.
			// A pack with a working key is prepared by the loading screen instead.
			if (hasWorkingKey(zip)) return null;
			return zip;
		} catch (e:Dynamic) {}
		#end
		return null;
	}

	// -------------------------------------------------- loader entry points

	/** True when one of the known keys already has a decrypted copy on disk. */
	public static function hasCacheForKey(zipPath:String):Bool {
		#if sys
		var packed = isEncryptedPackFile(zipPath);
		for (key in candidateKeys(zipPath)) {
			if (packed) {
				if (cacheExistsFor(zipPath, key)) return true;
			} else if (ZipPassword.hasCache(zipPath, key)) return true;
		}
		#end
		return false;
	}

	/**
	 * Libraries (the mods/Name path, without .zip) whose pack still has to be
	 * decrypted before the loader can read it. Cheap: only stats the cache files.
	 */
	public static function packsNeedingWork(libPaths:Array<String>):Array<String> {
		var out:Array<String> = [];
		#if sys
		for (lib in libPaths) {
			if (lib == null) continue;
			var zip = lib + ".zip";
			try {
				if (!FileSystem.exists(zip) || FileSystem.isDirectory(zip)) continue;
				if (!needsKey(zip)) continue;
				if (hasCacheForKey(zip)) continue;
				if (hasFailedBefore(zip)) continue;
				out.push(zip);
			} catch (e:Dynamic) {}
		}
		#end
		return out;
	}

	/**
	 * Starts decrypting the given packs on a worker thread. The loading screen polls
	 * preparing / progress / prepareDone and then reads prepareFailed.
	 */
	public static function startPrepare(packs:Array<String>):Void {
		prepareFailed = [];
		prepareDone = false;
		preparing = true;
		progress = 0;
		progressLabel = "";

		#if target.threaded
		sys.thread.Thread.create(function() runPrepare(packs));
		#else
		runPrepare(packs);
		#end
	}

	static function runPrepare(packs:Array<String>):Void {
		var total = packs.length;
		try {
			for (i in 0...total) {
				var pack = packs[i];
				progressLabel = Path.withoutExtension(Path.withoutDirectory(pack));
				var base = i / total;
				var span = 1 / total;
				progress = base;
				var key = resolveKey(pack, function(p:Float) progress = base + span * p);
				// a pack only counts as done when the cache file is really there:
				// otherwise the loader would start the very same pass again
				if (key == null || !hasCacheForKey(pack)) {
					prepareFailed.push(pack);
					failedPacks.set(normalizePath(pack), true);
				} else
					failedPacks.remove(normalizePath(pack));
				progress = (i + 1) / total;
			}
		} catch (e:Dynamic) {
			prepareFailed = packs.copy();
			for (pack in packs)
				failedPacks.set(normalizePath(pack), true);
		}
		preparing = false;
		prepareDone = true;
	}
}