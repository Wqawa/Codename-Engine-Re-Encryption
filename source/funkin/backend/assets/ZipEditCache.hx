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
 * has nothing to do with the pack it belongs to, so those edits go to
 * `.cne/mods/<name>/` instead - inside the one hidden folder the engine owns (see
 * RuntimeDirs), next to the videos it lifts out of the same pack.
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
	public static var root:String = funkin.backend.system.RuntimeDirs.MODS;

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
		return create ? funkin.backend.system.RuntimeDirs.modAssets(mod) : funkin.backend.system.RuntimeDirs.modAssets(mod, false);
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
				// Videos lifted out of the pack live in the same folder, but they are a read
				// cache: merging them back would copy every cutscene into the pack for nothing.
				if (prefix.length == 0 && entry == "videos") continue;
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
		if (!hasChanges(mod)) return null;
		// a merge that kept the staged copies (see keepStaged) leaves files that are
		// already in the pack; pruneUnchanged cannot tell, because the pack's decrypted
		// copy is stale by then and reopening it just to compare costs a full decrypt
		if (unchangedSinceMerge(mod)) return null;
		// files that are byte for byte what the pack already holds are not edits: they are
		// what the editor's old unconditional autosave left behind
		if (pruneUnchanged(mod)) return null;
		Logs.trace('zip edits: "$mod" still has staged files: ' + listFiles(mod).join(" | "), VERBOSE);
		return mod;
	}

	// ------------------------------------------------------------ merge memory

	/** Fingerprint of the staged files as they were right after a merge that kept them. */
	static var mergedPrints:Map<String, String> = [];

	/** Records that the staging folder and the pack now hold the same files. Main thread. */
	public static function markMerged(mod:String):Void {
		if (mod == null) return;
		var print = fingerprint(mod);
		if (print == "") mergedPrints.remove(mod);
		else mergedPrints.set(mod, print);
	}

	/**
	 * True when the staging folder still holds exactly what was merged into the pack.
	 *
	 * Cheap on purpose: it reads the staged files' size and modification time, where
	 * proving the same thing from the pack would mean decrypting the whole archive again.
	 * A file saved after the merge changes both, so new work still asks for a merge.
	 */
	static function unchangedSinceMerge(mod:String):Bool {
		var print = mergedPrints.get(mod);
		return print != null && print == fingerprint(mod);
	}

	/** Size and modification time of every staged file, in a stable order. */
	static function fingerprint(mod:String):String {
		#if sys
		var buf = new StringBuf();
		for (file in listFiles(mod)) {
			var info = null;
			try info = FileSystem.stat(folder(mod, false) + file) catch (e:Dynamic) {}
			// an unreadable file must not look unchanged
			if (info == null) return "";
			buf.add(file);
			buf.add(':');
			buf.add(info.size);
			buf.add(':');
			buf.add(info.mtime.getTime());
			buf.add('|');
		}
		return buf.toString();
		#else
		return "";
		#end
	}

	/**
	 * Deletes staged files that are identical to the pack entry they would replace.
	 *
	 * A file in the staging folder is what the engine reads as "unsaved work", so a copy
	 * that never changed made the merge prompt appear on every switch. Dropping the
	 * identical ones costs one comparison per file and makes the prompt mean what it
	 * says. Returns true when nothing is left staged.
	 *
	 * Nothing is deleted when the pack cannot be read right now (an encrypted pack that is
	 * not the loaded one): guessing would throw work away.
	 */
	public static function pruneUnchanged(mod:String):Bool {
		#if sys
		if (mod == null) return false;
		var files = listFiles(mod);
		if (files.length == 0) return true;
		var pack = packPath(mod);
		if (pack == null) return false;

		var owned = false;
		var zip:funkin.backend.utils.SysZip = null;
		try {
			if (ModPackCrypto.hasLoaded(pack)) zip = ModPackCrypto.zipFor(pack);
			else if (!ModPackCrypto.needsKey(pack)) {
				zip = new funkin.backend.utils.SysZip(pack);
				owned = true;
			}
		} catch (e:Dynamic) {
			Logs.warn('Could not open ${Path.withoutDirectory(pack)} to compare the staged files: ' + e);
		}
		if (zip == null) return false;

		var left = 0;
		try {
			for (file in files) {
				var entry = null;
				for (e in zip.entries)
					if (entryKey(e.fileName) == entryKey(file)) { entry = e; break; }
				// a staged file the pack does not have is a new file: always an edit
				if (entry == null) { left++; continue; }

				var staged = null;
				try staged = File.getBytes(folder(mod, false) + file) catch (e:Dynamic) {}
				if (staged == null) { left++; continue; }

				var packed = null;
				try packed = zip.unzipEntry(entry) catch (e:Dynamic) {}
				if (packed != null && packed.length == staged.length && packed.compare(staged) == 0) {
					try FileSystem.deleteFile(folder(mod, false) + file) catch (e:Dynamic) left++;
					continue;
				}
				left++;
			}
		} catch (e:Dynamic) {
			Logs.warn('Could not compare the staged files of "$mod": ' + e);
		}
		if (owned) try zip.dispose() catch (e:Dynamic) {}
		return left == 0;
		#else
		return false;
		#end
	}

	/**
	 * Short description of what is staged, for the prompt and the log: the first few
	 * file names, then how many more. The player is being asked about files they cannot
	 * see, so the dialog has to name at least some of them.
	 */
	public static function filesSummary(mod:String, maxNames:Int = 2, nameLength:Int = 46):String {
		var files = listFiles(mod);
		if (files.length == 0) return "";
		var names:Array<String> = [];
		for (i in 0...Std.int(Math.min(maxNames, files.length))) {
			var name = files[i];
			// keep the end of the path: the file name says more than songs/<song>/...
			if (name.length > nameLength) name = "..." + name.substr(name.length - (nameLength - 3));
			names.push(name);
		}
		var text = names.join("\n");
		var rest = files.length - names.length;
		if (rest > 0) text += '\n... and $rest more';
		return text;
	}

	/**
	 * Throws the staged files away. The pack itself is not touched.
	 *
	 * The prompt used to be all or nothing - merge, or leave it for next time - so a
	 * staging folder that got filled by a bug (a save on a timer that never checked for
	 * changes) could only be silenced by merging files the player never edited.
	 */
	public static function discard(mod:String):String {
		#if sys
		if (mod == null) return 'nothing to discard';
		var dir = folder(mod, false);
		if (dir == null || !FileSystem.exists(dir)) return 'nothing to discard';
		var count = listFiles(mod).length;
		try funkin.backend.utils.CoolUtil.deleteFolder(dir) catch (e:Dynamic) {
			Logs.error('Could not delete the staged files of "$mod": ' + e);
			return 'could not discard the staged files';
		}
		return 'discarded $count staged file(s) of "$mod"';
		#else
		return 'not supported on this target';
		#end
	}

	// ------------------------------------------------------------ async merge

	/**
	 * Merging rewrites the whole pack - copying every entry, re-encrypting it if the pack
	 * is encrypted - which takes seconds on a big mod. Run on the caller's thread that is
	 * seconds of a frozen window, so the screen that offers the merge starts it here and
	 * keeps drawing (see ModPackMergeState).
	 */
	public static var merging:Bool = false;
	public static var mergeDone:Bool = false;
	public static var mergeFailed:Bool = false;
	public static var mergeMessage:String = "";
	/** 0..1 progress of the merge pass, for the screen that reports it. */
	public static var mergeProgress:Float = 0;

	public static function startMergeAsync(mod:String, keepStaged:Bool = false):Void {
		if (merging) return;
		merging = true;
		mergeDone = false;
		mergeFailed = false;
		mergeProgress = 0;
		mergeMessage = "Reading the staged files";
		#if target.threaded
		sys.thread.Thread.create(function() runMerge(mod, keepStaged));
		#else
		runMerge(mod, keepStaged);
		#end
	}

	static function runMerge(mod:String, keepStaged:Bool = false):Void {
		try {
			mergeMessage = merge(mod, keepStaged);
		} catch (e:Dynamic) {
			mergeFailed = true;
			mergeMessage = 'could not merge the staged files: $e';
			Logs.error('Could not merge the staged changes into "$mod": ' + e);
		}
		merging = false;
		mergeDone = true;
	}

	/**
	 * Drops the in-memory copy of a pack whose file was just rewritten.
	 *
	 * The copy was decrypted from the bytes the merge replaced, so handing it to the loader
	 * as "already decrypted" showed the pack as it was before the merge. The copy stays
	 * alive for whatever still reads through it and is disposed with the next load
	 * (ModPackCrypto.retainZips), while hasLoaded/zipFor stop reporting it.
	 *
	 * Call it from the main thread: it touches the map the prepare thread writes.
	 */
	public static function forgetDecryptedCopy(mod:String):Void {
		var pack = packPath(mod);
		if (pack != null) ModPackCrypto.invalidatePack(pack);
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
			// a pack that is still being decrypted has not been loaded, so its staged edits
			// are not being read yet; ModPackCrypto's own veto owns that close
			if (ModPackCrypto.preparing) return false;

			var mod = pendingMod();
			if (mod == null) {
				releaseWarning();
				#if sys
				if (FileSystem.exists(root))
					Logs.trace('zip edits: nothing staged for "${Std.string(ModsFolder.currentModFolder)}"', VERBOSE);
				#end
				return false;
			}
			// An editor that already asked owns the prompt: its save writes into the
			// staging folder, and the merge is offered on the next close.
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
			// the pack was rewritten: the copy decrypted from the old bytes is useless now
			forgetDecryptedCopy(mod);
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
	 *
	 * `keepStaged` leaves the copies in the staging folder after a successful merge. The
	 * game keeps reading the current mod through that folder, so a merge that does not
	 * end the session (save and return to the editor) has to leave it in place - see
	 * markMerged() for how the next close knows the files are already in the pack.
	 */
	public static function merge(mod:String, keepStaged:Bool = false):String {
		#if sys
		var pack = packPath(mod);
		if (pack == null) throw 'not a packed mod: $mod';
		var files = listFiles(mod);
		if (files.length == 0) return 'nothing to merge';

		// Everything written on the way lives in .cne/temp/ and is removed afterwards: the
		// merge used to leave a plain .CNE_merge_*.zip in the key folder and a .old next to
		// the pack, and a failed run never cleaned either up.
		var work = funkin.backend.system.RuntimeDirs.TEMP;
		funkin.backend.system.RuntimeDirs.ensure(work);

		var stem = funkin.backend.system.RuntimeDirs.sanitize(mod);
		var merged = work + 'merge_' + stem + '.zip';
		var plain = pack;
		var plainIsCopy = false;

		try {
			mergeProgress = 0.02;
			if (ModPackCrypto.isEncryptedPackFile(pack) || ZipPassword.isProtected(pack)) {
				plain = plainCopyOf(pack, work + 'source_' + stem + '.zip');
				plainIsCopy = true;
			}
			mergeProgress = 0.25;
			writeMerged(plain, folder(mod, false), files, merged);
			mergeProgress = 0.55;
			replaceWith(pack, merged);
			mergeProgress = 1;
		} catch (e:Dynamic) {
			dropTempFiles(plain, plainIsCopy, merged);
			throw e;
		}
		dropTempFiles(plain, plainIsCopy, merged);

		// only drop what really made it into the pack - and only when the session is done
		// with these files: a merge that keeps running (save and return to the editor)
		// leaves the libraries reading through this folder
		if (!keepStaged)
			for (file in files) {
				try FileSystem.deleteFile(folder(mod, false) + file) catch (e:Dynamic) {}
			}
		return 'merged ${files.length} file(s) into ${Path.withoutDirectory(pack)}';
		#else
		return 'not supported on this target';
		#end
	}

	#if sys
	/** Removes the intermediate files a merge wrote, whatever happened to the merge. */
	static function dropTempFiles(plain:String, plainIsCopy:Bool, merged:String):Void {
		if (plainIsCopy && plain != null) {
			try if (FileSystem.exists(plain)) FileSystem.deleteFile(plain) catch (e:Dynamic) {}
		}
		for (file in [merged, merged + '.cnez', merged + '.aes']) {
			try if (FileSystem.exists(file)) FileSystem.deleteFile(file) catch (e:Dynamic) {}
		}
	}

	/**
	 * Writes a plain (readable) zip holding the pack's current contents to `out` and
	 * returns its path, with the key the pack is already unlocked with. A pack that is
	 * neither wrapped nor password protected is returned as it is, without a copy.
	 */
	static function plainCopyOf(pack:String, out:String):String {
		if (ModPackCrypto.isEncryptedPackFile(pack)) {
			var key = ModPackCrypto.resolveKey(pack);
			if (key == null) throw 'the pack is locked: no key opens ${Path.withoutDirectory(pack)}';
			File.saveBytes(out, ModPackCrypto.unpack(File.getBytes(pack), key));
			return out;
		}
		if (ZipPassword.isProtected(pack)) {
			var key = ModPackCrypto.resolveKey(pack);
			if (key == null) throw 'the pack is locked: no password opens ${Path.withoutDirectory(pack)}';
			File.saveBytes(out, ZipPassword.readableCopyBytes(pack, key));
			return out;
		}
		return pack;
	}

	/** Rewrites `source` into `out`, replacing and appending everything listed in `files`. */
	static function writeMerged(source:String, overlay:String, files:Array<String>, out:String):Void {
		var entries = ZipPassword.readCentral(source);
		if (entries == null) throw 'cannot read the zip index of ${Path.withoutDirectory(source)}';

		// archive names may use either separator and any casing; the staging folder uses '/'
		// and the casing of the file the editor saved. Key on the normalised name, but keep
		// the staged path itself so the bytes are read from the file that actually exists.
		var staged = new Map<String, String>();
		for (file in files) staged.set(entryKey(file), file);

		var input = File.read(source, true);
		var output = File.write(out, true);
		var central = new BytesBuffer();
		var pos = 0;
		var count = 0;

		try {
			for (e in entries) {
				var name = e.name;
				var key = entryKey(name);
				var stagedPath = staged.get(key);
				if (stagedPath != null) staged.remove(key);

				// A staged file can disappear between the scan and the merge (a cleanup pass,
				// the player emptying the folder by hand). Keep the pack's own copy then,
				// instead of throwing away the whole merge.
				var plain = stagedPath != null ? readStaged(overlay, stagedPath) : null;

				var raw:Bytes;
				var method:Int;
				var crc:Int;
				var usize:Int;
				if (plain != null) {
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
				if (!staged.exists(entryKey(file))) continue;
				var plain = readStaged(overlay, file);
				if (plain == null) continue;
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


	/** Reads a staged file, or null when it disappeared since the folder was scanned. */
	static function readStaged(overlay:String, name:String):Bytes {
		try {
			var path = overlay + name;
			if (!FileSystem.exists(path)) return null;
			return File.getBytes(path);
		} catch (e:Dynamic) {
			return null;
		}
	}

	/** Archive name normalised for comparison: forward slashes, lower case. */
	static function entryKey(name:String):String {
		return StringTools.replace(name, "\\", "/").toLowerCase();
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
		// the low-memory mode keeps the pack open, and Windows will not rename over an
		// open file; let go of the handle first (a memory pack never holds one)
		ModPackCrypto.releaseFileHandle(pack);

		var out = merged;
		if (ModPackCrypto.isEncryptedPackFile(pack)) {
			var key = ModPackCrypto.resolveKey(pack);
			if (key == null) throw 'the pack is locked: no key opens ${Path.withoutDirectory(pack)}';
			out = merged + '.cnez';
			// re-encrypting the rewritten archive is the slow half of the merge, and it is
			// the only step that can report its own progress
			File.saveBytes(out, ModPackCrypto.pack(File.getBytes(merged), key,
				function(p:Float) mergeProgress = 0.55 + p * 0.4));
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
