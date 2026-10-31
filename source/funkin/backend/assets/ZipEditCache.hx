package funkin.backend.assets;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Path;
#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * Staging folder for edits made to a mod that is loaded from a zip.
 *
 * A zip cannot be written in place, so anything the editors save for such a mod used
 * to land in `mods/<name>/` next to the pack. That folder is easy to lose track of and
 * has nothing to do with the pack it belongs to, so those edits go to `[zip]temp/<name>/`
 * instead - one folder, next to the executable, holding only unsaved work.
 *
 * The engine reads through this folder (see OverlayZipFolderLibrary), and when the game
 * closes with files still in it, the save warning asks whether they should be merged into
 * the pack. Merging rewrites the archive: entries present in the staging folder replace
 * the one in the pack, everything else is copied over untouched, and the result is
 * re-encrypted with the same scheme and key the pack already used.
 *
 * Nothing here runs for folder mods: they are written directly.
 */
class ZipEditCache {
	/** Root of the staging area, relative to the executable (the engine sets that as cwd). */
	public static var root:String = './[zip]temp/';

	/** Name the engine gives the pack of a mod, or null when the mod is a folder. */
	public static function packPath(mod:String):String {
		#if sys
		if (mod == null) return null;
		for (ext in Flags.ALLOWED_ZIP_EXTENSIONS) {
			var path = ModsFolder.modsPath + mod + "." + ext;
			if (FileSystem.exists(path) && !FileSystem.isDirectory(path)) return path;
		}
		#end
		return null;
	}

	/** True when this mod is loaded from a pack rather than from a folder. */
	public static function isPackedMod(mod:String):Bool {
		return packPath(mod) != null;
	}

	/** Staging folder of a mod, with a trailing slash. Created on demand. */
	public static function folder(mod:String, create:Bool = true):String {
		if (mod == null) return null;
		var dir = root + sanitize(mod) + '/';
		#if sys
		if (create) {
			try {
				if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
			} catch (e:Dynamic) {}
		}
		#end
		return dir;
	}

	static function sanitize(mod:String):String {
		return mod.split("/").join("_").split("\\").join("_").split(":").join("_");
	}

	// ------------------------------------------------------------ contents

	/** Relative paths of every file staged for this mod (empty when there is none). */
	public static function listFiles(mod:String):Array<String> {
		var out:Array<String> = [];
		#if sys
		if (mod == null) return out;
		var base = folder(mod, false);
		if (base == null || !FileSystem.exists(base) || !FileSystem.isDirectory(base)) return out;
		collect(base, "", out);
		#end
		return out;
	}

	#if sys
	static function collect(base:String, prefix:String, out:Array<String>):Void {
		try {
			for (entry in FileSystem.readDirectory(base + prefix)) {
				var rel = prefix + entry;
				if (FileSystem.isDirectory(base + rel)) collect(base, rel + "/", out);
				else out.push(rel);
			}
		} catch (e:Dynamic) {}
	}
	#end

	/** True when the mod has at least one staged file. */
	public static function hasChanges(mod:String):Bool {
		return listFiles(mod).length > 0;
	}

	/** The mod currently loaded from a pack that has staged edits, or null. */
	public static function pendingMod():String {
		var mod = ModsFolder.currentModFolder;
		if (mod == null || !isPackedMod(mod)) return null;
		return hasChanges(mod) ? mod : null;
	}

	// ------------------------------------------------------------ close prompt

	static var installed:Bool = false;
	/** True while the save warning is showing because of the staged files, not an editor. */
	static var ownsWarning:Bool = false;

	/**
	 * Asks about the staged files when the window closes.
	 *
	 * The prompt is the engine's own save warning, not a second dialog: the close veto
	 * keeps the window open, `SaveWarning.showWarning` makes the existing onClosing hook
	 * pop the warning, and its "save and exit" button runs `saveFunc`, which is where the
	 * merge goes. Editors keep working through the same mechanism.
	 */
	public static function installClosingPrompt():Void {
		if (installed) return;
		installed = true;
		funkin.backend.utils.WindowUtils.addCloseVeto(function() {
			// the cleanup screen owns this close while it runs; nothing may be merged
			// into a pack that is already being torn down
			if (ModPackCrypto.cleaningUp || ModPackCrypto.cleanupDone) return false;

			var mod = pendingMod();
			if (mod == null) {
				releaseWarning();
				#if sys
				if (FileSystem.exists(root))
					Logs.trace('zip edits: nothing staged for "${Std.string(ModsFolder.currentModFolder)}"', VERBOSE);
				#end
				return false;
			}
			// An editor that already asked owns the prompt: its save writes into
			// [zip]temp, and the merge is offered on the next close.
			if (funkin.editors.SaveWarning.showWarning) return false;

			funkin.editors.SaveWarning.selectionClass = null;
			funkin.editors.SaveWarning.saveFunc = function() mergeStaged(mod);
			funkin.editors.SaveWarning.showWarning = true; // also keeps preventClosing on
			ownsWarning = true;
			return true;
		});
	}

	/** Merges and clears the warning state, so the exit that follows is not held up. */
	static function mergeStaged(mod:String):Void {
		try {
			Logs.trace(merge(mod), INFO);
		} catch (e:Dynamic) {
			// left staged on purpose: a failed merge must not lose the work
			Logs.error('Could not merge the staged changes into "$mod": ' + e);
		}
		releaseWarning();
	}

	/** Hands the save warning back when it was only on because of the staged files. */
	static function releaseWarning():Void {
		if (!ownsWarning) return;
		ownsWarning = false;
		funkin.editors.SaveWarning.showWarning = false;
		funkin.editors.SaveWarning.saveFunc = null;
	}

	// -------------------------------------------------------------- merging

	/**
	 * Writes every staged file of `mod` into its pack.
	 *
	 * The pack is rewritten entry by entry (existing entries are copied as they are,
	 * staged files replace or extend them) and only then put in place of the original,
	 * so a failure halfway cannot leave a half written mod behind. Returns a one line
	 * summary for the caller to show; throws when the merge could not happen.
	 */
	public static function merge(mod:String):String {
		#if sys
		var pack = packPath(mod);
		if (pack == null) throw 'not a packed mod: $mod';
		var files = listFiles(mod);
		if (files.length == 0) return 'nothing to merge';

		var plain = plainCopyOf(pack);
		var merged = plain + '.merged';
		try {
			writeMerged(plain, folder(mod, false), files, merged);
			replaceWith(pack, merged);
		} catch (e:Dynamic) {
			try if (FileSystem.exists(merged)) FileSystem.deleteFile(merged) catch (e2:Dynamic) {}
			throw e;
		}

		// only drop what really made it into the pack
		for (file in files) {
			try FileSystem.deleteFile(folder(mod, false) + file) catch (e:Dynamic) {}
		}
		return 'merged ${files.length} file(s) into ${Path.withoutDirectory(pack)}';
		#else
		return 'not supported on this target';
		#end
	}

	#if sys
	/**
	 * Path of a plain (readable) zip holding the pack's current contents. An encrypted
	 * pack is unwrapped into the cache folder first, with the key it is already unlocked
	 * with; a plain pack is used as it is.
	 */
	static function plainCopyOf(pack:String):String {
		if (ModPackCrypto.isEncryptedPackFile(pack)) {
			var key = ModPackCrypto.resolveKey(pack);
			if (key == null) throw 'the pack is locked: no key opens ${Path.withoutDirectory(pack)}';
			var zip = ModPackCrypto.unpack(File.getBytes(pack), key);
			var out = ModPackCrypto.cacheFolder + ModPackCrypto.CACHE_PREFIX + 'merge_' + Path.withoutExtension(Path.withoutDirectory(pack)) + '.zip';
			ModPackCrypto.ensureCacheFolder();
			File.saveBytes(out, zip);
			return out;
		}
		if (ZipPassword.isProtected(pack)) {
			var key = ModPackCrypto.resolveKey(pack);
			if (key == null) throw 'the pack is locked: no password opens ${Path.withoutDirectory(pack)}';
			return ZipPassword.extractToCache(pack, key);
		}
		return pack;
	}

	/** Rewrites `source` into `out`, replacing/appending everything listed in `files`. */
	static function writeMerged(source:String, overlay:String, files:Array<String>, out:String):Void {
		var entries = ZipPassword.readCentral(source);
		if (entries == null) throw 'cannot read the zip index of ${Path.withoutDirectory(source)}';

		var staged = new Map<String, Bool>();
		for (file in files) staged.set(file.toLowerCase(), true);

		var input = File.read(source, true);
		var output = File.write(out, true);
		var central = new BytesBuffer();
		var pos = 0;
		var count = 0;

		try {
			for (e in entries) {
				var name = e.name;
				var isStaged = staged.exists(name.toLowerCase());
				staged.remove(name.toLowerCase());

				var raw:Bytes;
				var method:Int;
				var crc:Int;
				var usize:Int;
				if (isStaged) {
					var plain = File.getBytes(overlay + name);
					var packed = deflate(plain);
					raw = packed.data;
					method = packed.method;
					crc = ZipPassword.crc32(plain);
					usize = plain.length;
				} else {
					// the source is always a plain copy, so no password is needed here
					var entry = ZipPassword.readRawEntry(input, e, "");
					raw = entry.data;
					method = entry.method;
					crc = e.crc;
					usize = e.usize;
				}

				pos += ZipPassword.writeEntry(output, central, name, e.time, e.date, method, crc, raw, usize, pos);
				count++;
			}

			// staged files the pack does not have yet
			for (file in files) {
				if (!staged.exists(file.toLowerCase())) continue;
				var plain = File.getBytes(overlay + file);
				var packed = deflate(plain);
				var crc = ZipPassword.crc32(plain);
				var time = 0, date = 0x21; // 1980-01-01, the zip epoch
				pos += ZipPassword.writeEntry(output, central, file, time, date, packed.method, crc, packed.data, plain.length, pos);
				count++;
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
		} catch (e:Dynamic) {
			try output.close() catch (e2:Dynamic) {}
			try input.close() catch (e2:Dynamic) {}
			throw e;
		}
	}


	/** Deflates a staged file; falls back to storing it when that does not help. */
	static function deflate(data:Bytes):{data:Bytes, method:Int} {
		if (data.length == 0) return {data: Bytes.alloc(0), method: 0};
		try {
			var out = Bytes.alloc(data.length + 64);
			var c = new haxe.zip.Compress(-15);
			var r = c.execute(data, 0, out, 0);
			c.close();
			if (r.done && r.write > 0 && r.write < data.length) return {data: out.sub(0, r.write), method: 8};
		} catch (e:Dynamic) {}
		return {data: data, method: 0};
	}

	/** Puts the merged zip in place of the pack, re-encrypting it the way it came. */
	static function replaceWith(pack:String, merged:String):Void {
		var out = merged;
		if (ModPackCrypto.isEncryptedPackFile(pack)) {
			var key = ModPackCrypto.resolveKey(pack);
			if (key == null) throw 'the pack is locked: no key opens ${Path.withoutDirectory(pack)}';
			out = merged + '.cnez';
			File.saveBytes(out, ModPackCrypto.pack(File.getBytes(merged), key));
		} else if (ZipPassword.isProtected(pack)) {
			var key = ModPackCrypto.resolveKey(pack);
			if (key == null) throw 'the pack is locked: no password opens ${Path.withoutDirectory(pack)}';
			out = merged + '.aes';
			ZipAes.encryptZip(merged, out, key);
		}

		// The pack is moved aside instead of deleted, so a failed rename cannot leave the
		// player without a mod: the original goes back and the staged files stay staged.
		var backup = pack + '.old';
		try if (FileSystem.exists(backup)) FileSystem.deleteFile(backup) catch (e:Dynamic) {}
		FileSystem.rename(pack, backup);
		try {
			FileSystem.rename(out, pack);
		} catch (e:Dynamic) {
			try FileSystem.rename(backup, pack) catch (e2:Dynamic) {}
			throw e;
		}
		try FileSystem.deleteFile(backup) catch (e:Dynamic) {}
	}
	#end
}
