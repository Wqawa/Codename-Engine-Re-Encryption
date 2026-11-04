package funkin.backend.assets;

import funkin.backend.scripting.crypto.ScriptCrypto;
import funkin.backend.system.MemoryGuard;
import funkin.backend.system.RuntimeDirs;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.Path;
#if sys
import funkin.backend.utils.CoolUtil;
import funkin.backend.utils.NativeAPI;
import sys.FileSystem;
import sys.io.File;
#end

/** A container that passed its header check, with the payload still encrypted. */
typedef OpenedPack = {
	var cipher:Bytes;
	var enc:Bytes;
	var nonce:Bytes;
	var chunkSize:Int;
	var chunkTags:Bytes;
	var chunkCount:Int;
	var mac:Bytes;
}

/**
 * Entry point for encrypted mod packs: keys, in-memory copies and cleanup.
 *
 * The container itself lives in `CnezV2`; nothing here parses bytes. This class decides
 * which key opens a pack, hands the loader a readable `SysZip`, and wipes everything
 * when the player leaves.
 */
class ModPackCrypto {
	/** Where a pack's own key file is copied to (`RuntimeDirs.KEYS`). */
	public static var cacheFolder:String = RuntimeDirs.KEYS;

	/** Prefix every copied key gets: `.CNE_<pack>_key.txt`. */
	public static inline var CACHE_PREFIX:String = '.CNE_';

	/** Cache folders earlier builds used; swept on sight. */
	public static var legacyCacheFolders:Array<String> = ['./.CNE_mods/', './.cne_mods/'];

	/** Keys typed this session, per pack path. Wrapped, see MemoryGuard. */
	static var sessionKeys:Map<String, Bytes> = new Map();

	/** Set when the player chose "play without mods" after a bad key. */
	public static var disableMods:Bool = false;

	// ------------------------------------------------------------------ paths

	public static function normalizePath(path:String):String {
		if (path == null) return "";
		return StringTools.replace(StringTools.trim(path.toLowerCase()), "\\", "/");
	}

	// -------------------------------------------------------------- detection

	/** True for a CNEZ container. */
	public static function isEncryptedPack(data:Bytes):Bool {
		return CnezV2.isV2(data);
	}

	/** Same, for a file: reads five bytes instead of loading it. */
	public static function isEncryptedPackFile(path:String):Bool {
		#if sys
		try {
			if (!FileSystem.exists(path) || FileSystem.isDirectory(path)) return false;
			var handle = File.read(path, true);
			var head = handle.read(5);
			handle.close();
			if (head == null || head.length < 5) return false;
			for (i in 0...4)
				if (head.get(i) != CnezV2.MAGIC[i]) return false;
			return head.get(4) == CnezV2.VERSION;
		} catch (e:Dynamic) {}
		#end
		return false;
	}

	/** A raw zip starts with "PK". */
	public static function looksLikeZip(data:Bytes):Bool {
		return data != null && data.length >= 4 && data.get(0) == 0x50 && data.get(1) == 0x4B;
	}

	/**
	 * True when the pack cannot be read without a password: a CNEZ container, or a zip
	 * whose entries are password protected.
	 */
	public static function needsKey(zipPath:String):Bool {
		if (isEncryptedPackFile(zipPath)) return true;
		return ZipPassword.isProtected(zipPath);
	}

	/** True when this mod's own file is an encrypted pack. */
	public static function isEncryptedMod(mod:String):Bool {
		#if sys
		if (mod == null) return false;
		for (ext in Flags.ALLOWED_ZIP_EXTENSIONS) {
			var path = ModsFolder.modsPath + mod + "." + ext;
			try {
				if (FileSystem.exists(path) && !FileSystem.isDirectory(path) && needsKey(path)) return true;
			} catch (e:Dynamic) {}
		}
		#end
		return false;
	}

	// -------------------------------------------------------------- container

	/** Wraps a zip into a CNEZ container. Layout and costs live in `CnezV2`. */
	public static function pack(zipBytes:Bytes, ?pass:String, ?onProgress:Float->Void):Bytes {
		if (pass == null) pass = ScriptCrypto.getPassword();
		return CnezV2.pack(zipBytes, ScriptCrypto.resolveKeyValue(pass), onProgress);
	}

	/**
	 * Checks the container and returns its payload **still encrypted**, with the key
	 * needed to decrypt it. Lets the loader verify without a full decryption pass.
	 */
	public static function openEncrypted(data:Bytes, ?pass:String):OpenedPack {
		if (pass == null) pass = ScriptCrypto.getPassword();
		pass = ScriptCrypto.resolveKeyValue(pass);

		if (pass == null) throw "ModPackCrypto: no key";
		if (!isEncryptedPack(data)) throw "ModPackCrypto: not an encrypted mod pack";

		var opened = CnezV2.open(data, pass);
		return {
			cipher: opened.payload,
			enc: opened.enc,
			nonce: opened.nonce,
			chunkSize: opened.chunkSize,
			chunkTags: opened.table,
			chunkCount: opened.count,
			mac: opened.mac
		};
	}

	public static function unpack(data:Bytes, ?pass:String, ?onProgress:Float->Void):Bytes {
		if (pass == null) pass = ScriptCrypto.getPassword();
		if (!CnezV2.isV2(data))
			throw "ModPackCrypto: not a CNEZ container of the current version";
		return CnezV2.unpack(data, pass, onProgress);
	}

	// ------------------------------------------------------------- key lookup

	public static function setSessionKey(zipPath:String, key:String):Void {
		sessionKeys.set(normalizePath(zipPath), MemoryGuard.sealString(key));
		// a freshly typed key deserves a new attempt; the memo is derived from passwords,
		// so dropping it keeps fewer of them around
		failedPacks.remove(normalizePath(zipPath));
		keyCheckCache = new Map();
		keyCheckEntries = 0;
	}

	public static function clearSessionKey(zipPath:String):Void {
		sessionKeys.remove(normalizePath(zipPath));
	}

	public static function getSessionKey(zipPath:String):String {
		return MemoryGuard.openString(sessionKeys.get(normalizePath(zipPath)));
	}

	public static function clearSessionKeys():Void {
		sessionKeys = new Map();
		keyCheckCache = new Map();
		keyCheckEntries = 0;
	}

	/** Records that a full decryption attempt for this pack already failed. */
	public static function markFailed(zipPath:String):Void {
		failedPacks.set(normalizePath(zipPath), true);
	}

	public static function hasFailedBefore(zipPath:String):Bool {
		return failedPacks.exists(normalizePath(zipPath));
	}

	public static function clearFailure(zipPath:String):Void {
		failedPacks.remove(normalizePath(zipPath));
	}

	/** Packs that already failed a full attempt, so they are not retried in a loop. */
	static var failedPacks:Map<String, Bool> = new Map();

	/** True when at least one key (typed, script_key.txt or built-in) is known. */
	public static function hasKnownKey(zipPath:String):Bool {
		return candidateKeys(zipPath).length > 0;
	}

	/** Memo for keyWorks(): never run a KDF twice for the same pack and key. */
	static var keyCheckCache:Map<String, Bool> = new Map();
	static var keyCheckEntries:Int = 0;

	/**
	 * Cheap "does this key really open the pack" check, so a wrong password is rejected
	 * on the prompt instead of after a pointless loading screen.
	 *
	 * A CNEZ container only needs its root tag checked, which costs one KDF and a few KB
	 * of reads; a password protected zip goes through ZipPassword.
	 */
	public static function keyWorks(zipPath:String, key:String):Bool {
		#if sys
		if (key == null) return false;
		var id = normalizePath(zipPath) + '|' + packStamp(zipPath) + '|' + keyId(key);
		if (keyCheckCache.exists(id)) return keyCheckCache.get(id);
		var ok = keyWorksUncached(zipPath, key);
		// the memo must not grow for a whole session of wrong passwords; Map has no size
		// in Haxe 4.2, so entries are counted on the side
		keyCheckEntries++;
		if (keyCheckEntries > 256) {
			keyCheckCache = new Map();
			keyCheckEntries = 1;
		}
		keyCheckCache.set(id, ok);
		return ok;
		#else
		return false;
		#end
	}

	/**
	 * The memo is keyed by a digest: a map full of plaintext passwords would be the
	 * easiest place in the process to find them.
	 */
	static function keyId(key:String):String {
		return Sha256.make(Bytes.ofString(key)).toHex().substr(0, 32);
	}

	/** size:mtime of the pack, so a replaced file is never answered from a stale memo. */
	static function packStamp(zipPath:String):String {
		#if sys
		try {
			var st = FileSystem.stat(zipPath);
			return '${st.size}:${st.mtime}';
		} catch (e:Dynamic) {}
		#end
		return "";
	}

	static function keyWorksUncached(zipPath:String, key:String):Bool {
		#if sys
		var pass = ScriptCrypto.resolveKeyValue(key);
		if (pass == null) return false;
		try {
			if (isEncryptedPackFile(zipPath)) return CnezV2.verifyKeyFile(zipPath, pass);
			if (ZipPassword.isProtected(zipPath)) return ZipPassword.checkPassword(zipPath, pass);
		} catch (e:Dynamic) {}
		#end
		return false;
	}

	/** True when one of the known keys really opens the pack. */
	public static function hasWorkingKey(zipPath:String):Bool {
		for (key in candidateKeys(zipPath))
			if (keyWorks(zipPath, key)) return true;
		return false;
	}

	/** Keys worth trying: typed first, then script_key.txt, then the built-in one. */
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

	/** First known key that actually opens the pack, or null. */
	public static function resolveKey(zipPath:String):String {
		for (key in candidateKeys(zipPath))
			if (keyWorks(zipPath, key)) return key;
		return null;
	}

	// ---------------------------------------------------------- cache hygiene
	// The only thing decryption leaves on disk is a copied key file; the packs themselves
	// stay in RAM. Copies are hidden, deleted on exit, and swept on the next start after
	// a crash.

	static var __cacheSwept:Bool = false;
	static var __exitHooked:Bool = false;

	#if sys
	/** Hides a path from Explorer (Windows; the dot prefix covers the rest). */
	static function hidePath(path:String):Void {
		#if windows
		try CoolUtil.safeAddAttributes(path, NativeAPI.FileAttribute.HIDDEN) catch (e:Dynamic) {}
		#end
	}

	public static function ensureCacheFolder():Void {
		RuntimeDirs.ensure(cacheFolder);
	}

	/** Hides one decrypted copy. */
	public static function hideCacheFile(path:String):Void hidePath(path);

	#if MOD_SUPPORT
	/** Releases the open zip handles; a copy cannot be deleted while it is still read. */
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
		// staged edits from an older build are the player's work: they move into
		// .cne/mods/ before the old folders are deleted
		RuntimeDirs.migrateLegacy();
		cleanCache();
		RuntimeDirs.clearVideos();
		RuntimeDirs.clearTemp();
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
				releaseZips();
				cleanCache();
			});
		} catch (e:Dynamic) {}
	}
	#end

	// ------------------------------------------------------- decrypted packs
	// A decrypted pack is never written to disk: the loader gets an in-memory SysZip and
	// the buffer is wiped when the pack is unloaded or the game closes.

	/** Decrypted packs held in RAM, keyed by normalized pack path. */
	static var loadedZips:Map<String, SysZip> = new Map();

	/**
	 * Decrypts the pack into memory and returns it, or null when the pack is unprotected
	 * or no known key opens it. Repeated calls return the same copy.
	 */
	public static function zipFor(packPath:String, ?onProgress:Float->Void):SysZip {
		#if sys
		if (packPath == null) return null;
		var id = normalizePath(packPath);
		var known = loadedZips.get(id);
		if (known != null) {
			// a released copy looks loaded but reads nothing; a stale one belongs to a file
			// a merge replaced. Neither can be handed out.
			if (!known.released && !known.stale) return known;
			loadedZips.remove(id);
			// never wipe a buffer a library still reads from; the next load disposes it
			if (!known.released && !heldByLibrary(known)) try known.dispose() catch (e:Dynamic) {}
		}

		var packed = isEncryptedPackFile(packPath);
		var protectedZip = !packed && ZipPassword.isProtected(packPath);
		if (!packed && !protectedZip) return null;
		// a pack that already failed a full attempt must not run again on this thread
		if (hasFailedBefore(packPath)) return null;

		var key = resolveKey(packPath);
		if (key == null) return null;

		try {
			initCache();
			// the progress screen names each step, so progress is reported where the cost
			// actually is: reading the file, checking the tag, the cipher pass, indexing
			var wrapped:Null<Float->Void> = onProgress == null ? null : function(p:Float) {
				waitWhilePaused();
				onProgress(p);
			};
			var zip:SysZip;
			if (packed) {
				if (Options.wrapDecryptedPacks) {
					// memory mode: read once, stay ciphertext, decrypt each asset on read
					if (wrapped != null) wrapped(0.15);
					var raw = File.getBytes(packPath);
					var opened = openEncrypted(raw, key);
					if (wrapped != null) wrapped(0.75);
					zip = SysZip.fromChunked(opened.cipher, opened.enc, opened.nonce, opened.chunkSize, opened.chunkTags,
						opened.chunkCount, opened.mac);
					if (wrapped != null) wrapped(1);
				} else {
					// low-memory mode: only header and table are read; ranges are decrypted,
					// verified and dropped on demand, so a large pack costs no RAM
					if (wrapped != null) wrapped(0.3);
					var openedFile = CnezV2.openFile(packPath, key);
					if (wrapped != null) wrapped(0.9);
					zip = SysZip.fromCipherFile(packPath, openedFile);
					if (wrapped != null) wrapped(1);
				}
			} else {
				// a password protected zip has no stream to seek in, so it is rebuilt in
				// memory; it stays wrapped so a scanner sees nothing readable
				var bytes = ZipPassword.readableCopyBytes(packPath, key, wrapped);
				if (bytes == null || !looksLikeZip(bytes)) return null;
				zip = SysZip.fromBytes(bytes, true);
			}
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
		if (packPath == null) return false;
		var zip = loadedZips.get(normalizePath(packPath));
		// released means wiped, stale means the file was rewritten under it
		return zip != null && !zip.released && !zip.stale;
	}

	/**
	 * Marks the in-memory copy as outdated because its file was rewritten.
	 *
	 * The copy stays alive for whatever still reads through it, but it is never handed
	 * out again: the next load decrypts the new file.
	 */
	public static function invalidatePack(packPath:String):Void {
		if (packPath == null) return;
		var zip = loadedZips.get(normalizePath(packPath));
		if (zip == null || zip.released) return;
		zip.stale = true;
		Logs.trace('The decrypted copy of "${Path.withoutDirectory(packPath)}" is outdated after the merge; it will be read again on the next load.', INFO);
	}

	/** Wipes every decrypted pack (game exit, or everything being unloaded). */
	public static function releaseZips():Void {
		for (zip in loadedZips)
			try zip.dispose() catch (e:Dynamic) {}
		loadedZips = new Map();
	}

	/**
	 * Drops the decrypted packs that are not part of `libPaths`, and keeps the rest.
	 *
	 * The loader re-enters MainState right after the progress screen: releasing
	 * everything there threw away the copy that had just been built and sent the loader
	 * back to decrypting it, round after round. An empty list (the "play without mods"
	 * pick) releases everything.
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
		for (id in loadedZips.keys()) {
			var zip = loadedZips.get(id);
			// a pack a merge rewrote no longer matches the copy made from the old bytes
			if (zip != null && zip.stale) {
				drop.push(id);
				continue;
			}
			if (!keep.exists(id)) drop.push(id);
		}

		for (id in drop) {
			var zip = loadedZips.get(id);
			if (zip == null) {
				loadedZips.remove(id);
				continue;
			}
			// disposing a zip a library still reads from turns the next asset lookup into a
			// dead process; the entry stays so the exit wipe still knows about it
			if (heldByLibrary(zip)) {
				Logs.warn('"$id" is still held by an asset library, so its decrypted copy is kept for now.');
				continue;
			}
			loadedZips.remove(id);
			try zip.dispose() catch (e:Dynamic) {}
			// the key file copied out of that pack has no owner any more
			dropKeyFileFor(id);
		}
	}

	/** True when a library in the current asset tree still reads from this archive. */
	static function heldByLibrary(zip:SysZip):Bool {
		#if MOD_SUPPORT
		try {
			if (Paths.assetsTree == null) return false;
			for (lib in Paths.assetsTree.libraries) {
				var clean = AssetsLibraryList.getCleanLibrary(lib);
				if (clean is ZipFolderLibrary && (cast clean : ZipFolderLibrary).zip == zip) return true;
			}
		} catch (e:Dynamic) {}
		#end
		return false;
	}

	/**
	 * Lets go of a low-memory pack's file handle so the file can be replaced.
	 *
	 * Only that mode keeps the pack open. Windows refuses to rename over an open file,
	 * and a merge has to put the rebuilt pack in place of the old one.
	 */
	public static function releaseFileHandle(packPath:String):Void {
		if (packPath == null) return;
		var zip = loadedZips.get(normalizePath(packPath));
		if (zip == null) return;
		try zip.closeHandle() catch (e:Dynamic) {}
	}

	/** Removes the `*_key.txt` a pack's own key file was copied to, if there is one. */
	static function dropKeyFileFor(packPath:String):Void {
		#if sys
		try {
			var name = Path.withoutExtension(Path.withoutDirectory(packPath));
			var file = cacheFolder + CACHE_PREFIX + RuntimeDirs.sanitize(name) + "_key.txt";
			if (FileSystem.exists(file)) FileSystem.deleteFile(file);
		} catch (e:Dynamic) {}
		#end
	}

	// --------------------------------------------------------------- prepare
	// Decrypting a big pack takes seconds, so the loading screen starts the work on a
	// worker thread and polls these fields from the render loop.

	/** 0..1 progress of the pack currently being prepared. */
	public static var progress:Float = 0;
	/** True while the prepare thread is held back because a prompt is open. */
	public static var preparePaused:Bool = false;
	/** File name of the pack being prepared. */
	public static var progressLabel:String = "";
	/** True while the worker thread is still running. */
	public static var preparing:Bool = false;
	/** Set by the worker when it finished, successfully or not. */
	public static var prepareDone:Bool = false;
	/** Packs none of the known keys could open. */
	public static var prepareFailed:Array<String> = [];

	/** Blocks the prepare thread while the player is answering a prompt. */
	static function waitWhilePaused():Void {
		#if sys
		// the cipher reports every 128 KB, so this reacts quickly without busy waiting
		while (preparePaused) Sys.sleep(0.02);
		#end
	}

	/**
	 * Starts decrypting the given packs on a worker thread. The loading screen polls
	 * preparing / progress / prepareDone and then reads prepareFailed.
	 */
	public static function startPrepare(packs:Array<String>):Void {
		// two passes would both write loadedZips and prepareFailed from their own threads
		if (preparing) {
			Logs.warn('A decryption pass is already running - not starting a second one.');
			return;
		}
		prepareFailed = [];
		prepareDone = false;
		preparing = true;
		progress = 0;
		progressLabel = "";
		preparePaused = false;

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
				var zip = zipFor(pack, function(p:Float) progress = base + span * p);
				if (zip == null) {
					prepareFailed.push(pack);
					failedPacks.set(normalizePath(pack), true);
				} else {
					failedPacks.remove(normalizePath(pack));
				}
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

	// ------------------------------------------------------------ close veto

	/**
	 * Asks before the window closes while a pack is still being decrypted.
	 *
	 * The pass runs on a worker thread, so without this the window would vanish
	 * mid-decryption. The thread is paused first so the screen cannot finish on its own
	 * while the player is still deciding.
	 */
	static var __closeVetoInstalled:Bool = false;
	static var __closePromptQueued:Bool = false;

	public static function installCloseVeto():Void {
		if (__closeVetoInstalled) return;
		__closeVetoInstalled = true;
		WindowUtils.addCloseVeto(function() {
			if (!preparing) return false;
			if (flixel.FlxG.state == null) return false;
			if (__closePromptQueued) return true;
			__closePromptQueued = true;
			preparePaused = true;
			// the window event fires outside the update loop, so the prompt opens on the next
			// frame; if that frame never comes (a window closed from the taskbar is not
			// focused), the game exits instead of staying vetoed with nothing on screen
			WindowUtils.runOnNextFrameOrExit(function() {
				__closePromptQueued = false;
				var state = flixel.FlxG.state;
				if (state == null) {
					preparePaused = false;
					openfl.system.System.exit(0);
					return;
				}
				state.openSubState(new funkin.editors.ui.UIWarningSubstate(
					"Still unlocking",
					"The pack is still being decrypted. Closing now throws that work away.\n"
					+ "Decryption is paused while this is open.",
					[
						{
							label: "Exit Game",
							color: 0xFF6B6B,
							onClick: function(_) {
								preparePaused = false;
								openfl.system.System.exit(0);
							}
						},
						{
							label: "Keep Decrypting",
							color: 0x969533,
							onClick: function(_) preparePaused = false
						}
					],
					funkin.editors.ui.UIWarningSubstate.UIWarningKind.WARNING));
			});
			return true;
		});
	}

	// --------------------------------------------------------------- cleanup
	// A decrypted pack exists only while the game runs: the buffers in loadedZips, the zip
	// handles the libraries hold, the key files copied out of packs and the videos in the
	// cache. Closing has to wipe that, and the window close waits for the wipe (see
	// Main.loadGameSettings and ModPackCleanupState).

	/** True once a pack was decrypted in this session. */
	public static var sessionDecrypted:Bool = false;
	public static var cleaningUp:Bool = false;
	public static var cleanupDone:Bool = false;
	public static var cleanupProgress:Float = 0;
	public static var cleanupLabel:String = "";
	/** What was actually removed, one line per kind. */
	public static var cleanupSummary:String = "";
	/** One line per finished step, so the screen can list everything it touched. */
	public static var cleanupLines:Array<String> = [];

	/**
	 * The encrypted pack of the mod that was loaded before the current one, or null.
	 *
	 * Set by ModsFolder.switchMod before it changes the mod. What the engine lifted out
	 * of that pack (its videos) is decrypted content on disk, so it goes with the pack.
	 */
	public static var outgoingEncryptedPack:String = null;
	/** The mod a finished cleanup pass should switch to, when it was not closing. */
	static var queuedSwitch:String = null;
	/**
	 * Whether a switch is queued, kept apart from its value.
	 *
	 * `null` is a real target - the mod list ends with a null entry for "no mod" - so the
	 * old check `queuedSwitch != null` could not tell a queued switch to nothing from no
	 * switch at all, and completing the first one did nothing and left the screen waiting.
	 */
	static var switchQueued:Bool = false;
	static var runningQueuedSwitch:Bool = false;
	/** Switch mode keeps the copied keys; closing the game removes them. */
	public static var cleanupKeepsKeys:Bool = false;
	/** Mod whose extracted videos this pass is about, null when it wipes them all. */
	public static var cleanupScopeMod:String = null;

	/** Remembers whether the mod being left owned an encrypted pack. */
	public static function noteOutgoingMod(mod:String):Void {
		outgoingEncryptedPack = null;
		#if sys
		if (mod == null) return;
		for (ext in Flags.ALLOWED_ZIP_EXTENSIONS) {
			var path = ModsFolder.modsPath + mod + "." + ext;
			try {
				if (!FileSystem.exists(path) || FileSystem.isDirectory(path)) continue;
				if (needsKey(path)) {
					outgoingEncryptedPack = path;
					return;
				}
			} catch (e:Dynamic) {}
		}
		#end
	}

	/**
	 * Takes over a switch that leaves an encrypted pack, so the wipe runs on the cleanup
	 * screen instead of behind a frozen frame. Returns true when the caller must stop:
	 * the switch continues from completeSwitchCleanup().
	 */
	public static function beginSwitchCleanup(target:String):Bool {
		// the continuation below re-enters ModsFolder.switchMod; let it through this once
		if (runningQueuedSwitch) {
			runningQueuedSwitch = false;
			return false;
		}
		if (cleaningUp || switchQueued) return false;
		if (!sessionDecrypted) return false;
		if (target != null && target == ModsFolder.currentModFolder) return false;
		if (!isEncryptedMod(ModsFolder.currentModFolder)) return false;
		if (flixel.FlxG.state == null) return false;

		queuedSwitch = target;
		switchQueued = true;
		// a switch wipes what the pack left on disk and in memory, but keeps the copied
		// key: switching back should not ask for the password again. Closing does remove it.
		cleanupKeepsKeys = true;
		cleanupScopeMod = ModsFolder.currentModFolder;
		flixel.FlxG.switchState(new funkin.menus.ModPackCleanupState(true));
		return true;
	}

	/**
	 * Runs the switch that was waiting for the wipe. Called by the cleanup screen.
	 *
	 * Returns false when nothing was queued, which is the one case where the screen has
	 * to leave by itself: waiting for a continuation that is not coming is a freeze.
	 */
	public static function completeSwitchCleanup():Bool {
		if (!switchQueued) return false;
		switchQueued = false;
		var target = queuedSwitch;
		queuedSwitch = null;
		runningQueuedSwitch = true;
		ModsFolder.switchMod(target);
		return true;
	}

	static var cleanupStep:Int = 0;
	static var removedCount:Int = 0;

	/**
	 * True while closing the window would leave decrypted data or keys behind.
	 *
	 * Asked every time a close is vetoed, so it has to answer about the state right now.
	 * `cleanupDone` must not take part: it only says that a pass finished, and a pack
	 * decrypted *after* that pass (switching back to the encrypted mod) has to be wiped
	 * again. Letting it short-circuit this made the second close exit without a pass,
	 * while switching away still worked because that path never looked at the flag.
	 */
	public static function needsCleanup():Bool {
		if (sessionDecrypted) return true;
		return loadedZips.keys().hasNext();
	}

	/** Starts the wipe; ModPackCleanupState calls stepCleanup() once per frame. */
	public static function beginCleanup():Void {
		if (cleaningUp) return;
		cleaningUp = true;
		cleanupDone = false;
		cleanupStep = 0;
		removedCount = 0;
		cleanupProgress = 0;
		cleanupSummary = "";
		cleanupLines = [];
		cleanupLabel = "Releasing the pack handles";
	}

	/**
	 * Runs one cleanup step and returns true once everything is done.
	 *
	 * One step per frame, on the main thread. Running this on a worker thread disposed
	 * buffers the main thread still referenced and killed the game on close.
	 */
	public static function stepCleanup():Bool {
		if (cleanupDone) return true;

		try {
			switch (cleanupStep) {
				case 0:
					// the libraries hold the very handles the wipe is about to release
					#if MOD_SUPPORT
					var handles = countPackHandles();
					closePackHandles();
					if (handles > 0) cleanupLines.push('Released $handles pack handle(s)');
					#end
					cleanupLabel = "Wiping the decrypted packs";
					cleanupProgress = 0.2;
					cleanupStep = 1;
				case 1:
					var packs = 0;
					var bytes = 0;
					for (zip in loadedZips) {
						packs++;
						if (zip != null) bytes += zip.dataSize();
					}
					releaseZips();
					if (packs > 0) cleanupLines.push('Wiped $packs decrypted pack(s) from memory (' + humanSize(bytes) + ')');
					cleanupLabel = "Removing the copied keys";
					cleanupProgress = 0.55;
					cleanupStep = 2;
				case 2:
					removedCount = countCacheFiles();
					if (cleanupKeepsKeys) {
						// a switch keeps them: the player may come back to this pack in the
						// same session, and the password was never written to disk anyway
						cleanupLines.push(removedCount == 0
							? 'No copied key files were on disk'
							: 'Kept $removedCount copied key file(s) for this session');
					} else {
						cleanCache();
						cleanupLines.push(removedCount == 0
							? 'No copied key files were on disk'
							: 'Removed $removedCount copied key file(s)');
					}
					cleanupLabel = "Removing the video cache";
					cleanupProgress = 0.75;
					cleanupStep = 3;
				case 3:
					var videos = cleanupScopeMod == null
						? RuntimeDirs.clearVideos()
						: RuntimeDirs.clearVideos(cleanupScopeMod);
					if (videos > 0) cleanupLines.push('Removed $videos extracted video(s)');
					var temp = RuntimeDirs.countFiles(RuntimeDirs.TEMP);
					RuntimeDirs.clearTemp();
					if (temp > 0) cleanupLines.push('Removed $temp scratch file(s) from .cne/temp');
					cleanupProgress = 0.9;
					cleanupStep = 4;
				default:
					finishCleanup();
					return true;
			}
		} catch (e:Dynamic) {
			finishCleanup("the cleanup stopped early: " + Std.string(e));
			return true;
		}
		return false;
	}

	static function finishCleanup(?problem:String):Void {
		cleanupProgress = 1;
		cleanupLabel = "Done";
		if (problem != null) cleanupLines.push(problem);
		if (cleanupLines.length == 0) cleanupLines.push('Nothing had reached the disk');
		cleanupSummary = cleanupLines.join("\n");
		cleaningUp = false;
		cleanupDone = true;
		sessionDecrypted = false;
		// the close path runs with the defaults: wiping everything, keys included
		cleanupKeepsKeys = false;
		cleanupScopeMod = null;
	}

	/** Short byte size, for the cleanup summary. */
	static function humanSize(bytes:Int):String {
		if (bytes < 1024 * 1024) return Std.string(Math.round(bytes / 102.4) / 10) + " KB";
		return Std.string(Math.round(bytes / (1024 * 1024) * 10) / 10) + " MB";
	}

	/** Packs the current asset tree still reads through, for the summary. */
	static function countPackHandles():Int {
		#if MOD_SUPPORT
		var n = 0;
		try {
			if (Paths.assetsTree == null) return 0;
			for (lib in Paths.assetsTree.libraries) {
				var clean = AssetsLibraryList.getCleanLibrary(lib);
				if (clean is ZipFolderLibrary && (cast clean : ZipFolderLibrary).zip != null) n++;
			}
		} catch (e:Dynamic) {}
		return n;
		#else
		return 0;
		#end
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

	// -------------------------------------------------- loader entry points

	/** True when the pack is already decrypted in memory. */
	public static function hasPrepared(zipPath:String):Bool {
		return hasLoaded(zipPath);
	}

	/**
	 * Libraries (the `mods/Name` path, without extension) whose pack still has to be
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
	 * Zip of a mod library (the `mods/Name` base path) that is encrypted and that no
	 * known key can open, or null.
	 *
	 * Only libraries the engine actually loads are asked about: a zip that merely sits in
	 * the mods folder must not interrupt a session playing a different mod.
	 */
	public static function pendingPackFor(libPath:String):String {
		#if sys
		if (libPath == null) return null;
		try {
			var zip = libPath + ".zip";
			if (!FileSystem.exists(zip) || FileSystem.isDirectory(zip)) return null;
			if (!needsKey(zip)) return null;
			// never decrypt here: this runs on the main thread from the startup check, so
			// only ask for a key when none of the known ones works
			if (hasWorkingKey(zip)) return null;
			return zip;
		} catch (e:Dynamic) {}
		#end
		return null;
	}
}
