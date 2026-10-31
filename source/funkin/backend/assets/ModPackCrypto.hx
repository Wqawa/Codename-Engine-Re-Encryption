package funkin.backend.assets;

import funkin.backend.scripting.crypto.ChaCha20;
import funkin.backend.scripting.crypto.ScriptCrypto;
import funkin.backend.system.MemoryGuard;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Path;
#if sys
import funkin.backend.utils.CoolUtil;
import funkin.backend.utils.NativeAPI;
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

	/**
	 * Where a pack's own key file is copied to. Everything the engine writes while it
	 * runs lives under one hidden folder now (see RuntimeDirs); the key side of it is
	 * this one.
	 */
	public static var cacheFolder:String = funkin.backend.system.RuntimeDirs.KEYS;

	/** Prefix every copied key gets (".CNE_<pack>_key.txt"). */
	public static inline var CACHE_PREFIX:String = '.CNE_';

	/** Cache folders used by earlier builds; swept on sight. */
	public static var legacyCacheFolders:Array<String> = ['./.CNE_mods/', './.cne_mods/'];

	/** Key typed by the player this session, per pack path. */
	// passwords are kept wrapped (see MemoryGuard) so a memory scan does not find them as plain strings
	static var sessionKeys:Map<String, Bytes> = new Map<String, Bytes>();

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

	// ------------------------------------------------------------ container

	public static function pack(zipBytes:Bytes, ?pass:String, ?onProgress:Float->Void):Bytes {
		if (pass == null) pass = ScriptCrypto.getPassword();
		pass = ScriptCrypto.resolveKeyValue(pass);

		var salt = ScriptCrypto.randomBytes(SALT_SIZE);
		var nonce = ScriptCrypto.randomBytes(NONCE_SIZE);
		var keys = ScriptCrypto.deriveKeys(pass, salt);
		// the cipher pass is the slow half, so it reports the progress it makes
		var cipher = onProgress == null
			? ChaCha20.xorBytes(keys.enc, nonce, 1, zipBytes)
			: ChaCha20.xorBytes(keys.enc, nonce, 1, zipBytes, function(p:Float) onProgress(0.05 + 0.9 * p));

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
		if (onProgress != null) onProgress(1);
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
		sessionKeys.set(normalizePath(zipPath), MemoryGuard.sealString(key));
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
		return MemoryGuard.openString(sessionKeys.get(normalizePath(zipPath)));
	}

	public static function clearSessionKeys():Void {
		sessionKeys = new Map<String, Bytes>();
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


	// ------------------------------------------------------- cache hygiene
	// Everything decrypted lands on disk as a readable zip. It stays hidden and
	// prefixed while the game runs, is deleted when the game closes, and a crashed
	// run (taskkill, power loss) is swept the next time the game reaches the cache.

	static var __cacheSwept:Bool = false;
	static var __exitHooked:Bool = false;

	#if sys
	/** Hides a path from Explorer (Windows; elsewhere the dot prefix already does it). */
	static function hidePath(path:String):Void {
		#if windows
		try CoolUtil.safeAddAttributes(path, NativeAPI.FileAttribute.HIDDEN) catch (e:Dynamic) {}
		#end
	}

	/** Creates the key folder when missing and hides it. */
	public static function ensureCacheFolder():Void {
		funkin.backend.system.RuntimeDirs.ensure(cacheFolder);
	}

	/** Hides one decrypted copy. */
	public static function hideCacheFile(path:String):Void hidePath(path);

	#if MOD_SUPPORT
	/** Releases the open zip handles: a decrypted copy cannot be deleted while
	 *  the library still reads from it. Only used right before the exit cleanup. */
	static function closePackHandles():Void {
		try {
			if (Paths.assetsTree == null) return;
			for (lib in Paths.assetsTree.libraries) {
				try {
					var clean = AssetsLibraryList.getCleanLibrary(lib);
					if (clean is ZipFolderLibrary) {
						var zip = (cast clean : ZipFolderLibrary).zip;
						if (zip != null) zip.dispose();
					}
				} catch (e:Dynamic) {}
			}
		} catch (e:Dynamic) {}
	}
	#end

	/** Deletes every decrypted copy (current and legacy folders), best effort. */
	public static function cleanCache():Void {
		for (folder in [cacheFolder].concat(legacyCacheFolders)) {
			try {
				if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) continue;
				for (file in FileSystem.readDirectory(folder)) {
					var path = folder + file;
					try {
						if (FileSystem.isDirectory(path)) continue;
						FileSystem.deleteFile(path);
					} catch (e:Dynamic) {}
				}
			} catch (e:Dynamic) {}
		}
	}

	/** Removes what a previous run left behind; runs once per start. */
	public static function sweepCache():Void {
		if (__cacheSwept) return;
		__cacheSwept = true;
		// edits an earlier build staged in [zip]temp/ are the player's unmerged work:
		// they are moved into .cne/mods/ first, and only then do the old folders go
		funkin.backend.system.RuntimeDirs.migrateLegacy();
		cleanCache();
		funkin.backend.system.RuntimeDirs.clearVideos();
		funkin.backend.system.RuntimeDirs.clearTemp();
		ensureCacheFolder();
		hookExit();
	}

	/** Entry point used by the cache readers and writers. */
	public static function initCache():Void {
		if (!__cacheSwept) sweepCache();
		else hookExit();
	}

	/** Registers the exit cleanup; retried until the application exists. */
	static function hookExit():Void {
		if (__exitHooked) return;
		try {
			var app = openfl.Lib.application;
			if (app == null) return; // too early, a later call will do it
			__exitHooked = true;
			app.onExit.add(function(_) {
				#if MOD_SUPPORT
				closePackHandles();
				#end
				// the decrypted packs only exist in RAM now; wipe them on the way out
				releaseZips();
				cleanCache();
			});
		} catch (e:Dynamic) {}
	}
	#end

	// ------------------------------------------------------- decrypted packs
	// A decrypted pack is never written to disk: it is handed to the asset library
	// as an in-memory SysZip and wiped when the pack is unloaded or the game closes.

	/** Decrypted packs held in RAM, keyed by normalized pack path. */
	static var loadedZips:Map<String, SysZip> = new Map();

	/**
	 * First known key that actually opens the pack, or null.
	 *
	 * Cheap by design: it only probes a few bytes per candidate (see keyWorks), so it
	 * runs on the main thread without decrypting the whole pack.
	 */
	public static function resolveKey(zipPath:String):String {
		for (key in candidateKeys(zipPath))
			if (keyWorks(zipPath, key)) return key;
		return null;
	}

	/**
	 * Decrypts the pack into memory and returns it, or null when the pack is not
	 * protected at all or no known key opens it. Repeated calls return the same copy.
	 */
	public static function zipFor(packPath:String, ?onProgress:Float->Void):SysZip {
		#if sys
		if (packPath == null) return null;
		var id = normalizePath(packPath);
		var known = loadedZips.get(id);
		if (known != null) return known;

		var packed = isEncryptedPackFile(packPath);
		var protectedZip = !packed && ZipPassword.isProtected(packPath);
		if (!packed && !protectedZip) return null;
		// a pack that failed a full attempt must not be decrypted again on the main thread
		if (hasFailedBefore(packPath)) return null;

		var key = resolveKey(packPath);
		if (key == null) return null;

		try {
			initCache();
			var bytes = packed
				? unpack(File.getBytes(packPath), key, onProgress)
				: ZipPassword.readableCopyBytes(packPath, key, onProgress);
			if (bytes == null || !looksLikeZip(bytes)) return null;

			var zip = SysZip.fromBytes(bytes, Options.wrapDecryptedPacks);
			if (zip.entries.length == 0) return null;
			loadedZips.set(id, zip);
			sessionDecrypted = true;
			return zip;
		} catch (e:Dynamic) {
			Logs.warn('Could not decrypt "$packPath": ' + e);
		}
		#end
		return null;
	}

	/** True when this pack is already decrypted and readable in memory. */
	public static function hasLoaded(packPath:String):Bool {
		return packPath != null && loadedZips.exists(normalizePath(packPath));
	}

	/** Wipes every decrypted pack (game exit, or everything being unloaded). */
	public static function releaseZips():Void {
		for (zip in loadedZips) {
			try zip.dispose() catch (e:Dynamic) {}
		}
		loadedZips = new Map<String, SysZip>();
	}

	/**
	 * Drops the decrypted packs that are not part of `libPaths` and keeps the rest.
	 *
	 * The loader re-enters MainState right after the progress screen, so a plain
	 * releaseZips() there threw away the copy that had just been built and sent the
	 * loader straight back to decrypting it - an endless loop, with a fresh multi
	 * hundred megabyte buffer allocated and dropped every round. Only what this load
	 * does not use is let go, which is the mod switch case.
	 *
	 * An empty list (the "play without mods" pick) releases everything.
	 */
	public static function retainZips(libPaths:Array<String>):Void {
		var keep = new Map<String, Bool>();
		if (libPaths != null) {
			for (lib in libPaths) {
				if (lib == null) continue;
				keep.set(normalizePath(lib), true);
				keep.set(normalizePath(lib + ".zip"), true);
			}
		}

		var drop:Array<String> = [];
		for (id in loadedZips.keys())
			if (!keep.exists(id)) drop.push(id);

		for (id in drop) {
			var zip = loadedZips.get(id);
			if (zip != null) try zip.dispose() catch (e:Dynamic) {}
			loadedZips.remove(id);
			// the key file copied out of that pack has no owner any more
			dropKeyFileFor(id);
		}
	}

	/** Removes the `*_key.txt` a pack's own key file was copied to, if there is one. */
	static function dropKeyFileFor(packPath:String):Void {
		#if sys
		try {
			var name = Path.withoutExtension(Path.withoutDirectory(packPath));
			var safeName = name.split("/").join("_").split(":").join("_");
			var file = cacheFolder + CACHE_PREFIX + safeName + "_key.txt";
			if (FileSystem.exists(file)) FileSystem.deleteFile(file);
		} catch (e:Dynamic) {}
		#end
	}

	// --------------------------------------------------------------- cleanup
	// A decrypted pack exists only while the game runs: the buffers in loadedZips,
	// the zip handles the libraries hold, the key files copied out of packs and the
	// videos in the video cache. None of it is written to disk on purpose, so closing has to
	// wipe it instead of leaving it to the next start - and that wipe is what the
	// window close waits for (see Main.loadGameSettings and ModPackCleanupState).

	/** True once a pack was decrypted in this session. */
	public static var sessionDecrypted:Bool = false;
	public static var cleaningUp:Bool = false;
	public static var cleanupDone:Bool = false;
	public static var cleanupProgress:Float = 0;
	public static var cleanupLabel:String = "";
	/** What was actually removed, shown on the cleanup screen. */
	public static var cleanupSummary:String = "";

	/** True while closing the window would leave decrypted data or keys behind. */
	public static function needsCleanup():Bool {
		if (cleanupDone) return false;
		if (sessionDecrypted) return true;
		for (_ in loadedZips.keys()) return true;
		return false;
	}

	/** Runs the wipe on a worker thread; ModPackCleanupState polls the fields above. */
	public static function beginCleanup():Void {
		if (cleaningUp) return;
		cleaningUp = true;
		cleanupDone = false;
		cleanupProgress = 0;
		cleanupSummary = "";
		cleanupLabel = "Wiping the decrypted packs";
		#if target.threaded
		sys.thread.Thread.create(runCleanup);
		#else
		runCleanup();
		#end
	}

	static function runCleanup():Void {
		var removed:Array<String> = [];
		try {
			// the big one: every decrypted buffer is overwritten twice and read back
			releaseZips();
			cleanupProgress = 0.4;

			#if MOD_SUPPORT
			cleanupLabel = "Releasing the pack handles";
			closePackHandles();
			#end
			cleanupProgress = 0.55;

			#if sys
			cleanupLabel = "Removing the copied keys";
			var keys = countCacheFiles();
			cleanCache();
			if (keys > 0) removed.push('$keys key file(s)');
			cleanupProgress = 0.8;

			cleanupLabel = "Removing the video cache";
			// .cne/mods/<mod>/ holds the edits the player has not merged yet, so it stays:
			// only what the engine produced (videos, undo scratch) goes here.
			try {
				var videos = 0;
				for (mod in FileSystem.readDirectory(funkin.backend.system.RuntimeDirs.MODS)) {
					var dir = funkin.backend.system.RuntimeDirs.MODS + mod + "/videos/";
					if (FileSystem.exists(dir) && FileSystem.isDirectory(dir)) videos++;
				}
				funkin.backend.system.RuntimeDirs.clearVideos();
				funkin.backend.system.RuntimeDirs.clearTemp();
				if (videos > 0) removed.push('$videos video cache folder(s)');
			} catch (e:Dynamic) {}
			#end

			cleanupProgress = 0.95;
			cleanupSummary = removed.length == 0 ? "nothing had reached the disk" : removed.join(" and ") + " removed";
		} catch (e:Dynamic) {
			cleanupSummary = "the cleanup hit an error: " + Std.string(e);
		}
		cleanupLabel = "Done";
		cleanupProgress = 1;
		cleaningUp = false;
		cleanupDone = true;
	}

	/** How many files the cache folder currently holds, for the summary line. */
	static function countCacheFiles():Int {
		#if sys
		var n = 0;
		for (folder in [cacheFolder].concat(legacyCacheFolders)) {
			try {
				if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) continue;
				for (file in FileSystem.readDirectory(folder))
					if (!FileSystem.isDirectory(folder + file)) n++;
			} catch (e:Dynamic) {}
		}
		return n;
		#else
		return 0;
		#end
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

	/** True when the pack is already decrypted in memory. */
	public static function hasPrepared(zipPath:String):Bool {
		return hasLoaded(zipPath);
	}

	/**
	 * Libraries (the mods/Name path, without .zip) whose pack still has to be
	 * decrypted before the loader can read it. Cheap: it only asks what is in memory.
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
				if (hasLoaded(zip)) continue;
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
				// decrypting into memory is the expensive step, so it happens here and the
				// loader later finds the pack already readable
				var zip = zipFor(pack, function(p:Float) progress = base + span * p);
				if (zip == null) {
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