package funkin.backend.utils;

#if sys
import funkin.backend.scripting.protect.ProtectedBuffer;
import haxe.io.Input;
import haxe.zip.Reader;
import sys.io.File;
import sys.io.FileInput;

import haxe.io.Bytes;

/**
 * Class that extends Reader allowing you to load ZIP entries without blowing your RAM up!!
 * ~~Half of the code is taken from haxe libraries btw~~ Reworked by ItsLJcool to actually work for zip files.
 *
 * Two sources: a file on disk (`new SysZip(path)`) and a buffer already in memory
 * (`SysZip.fromBytes(...)`). The second one is what an encrypted pack uses - it is
 * decrypted once into RAM and read from there, so no readable copy is ever written to
 * disk. Everything below goes through `readBytes`, so entry offsets and the central
 * directory are handled the same way for both.
 */
class SysZip {
	var fileInput:FileInput;
	var filePath:String;
	/** Set in memory mode; null when the zip is read from a file. */
	var buffer:ProtectedBuffer;

	public var entries:List<SysZipEntry> = new List();

	/**
	 * Opens a zip from a specified path.
	 * @param path Path to the zip file. (With the extension)
	 */
	public static function openFromFile(path:String) { return new SysZip(path); } // keeping for compatibility.

	/**
	 * Reads a zip that is already in memory. `wrapped` keeps the buffer encrypted with a
	 * per session stream and decodes only the ranges that are actually read.
	 */
	public static function fromBytes(bytes:Bytes, wrapped:Bool = false):SysZip {
		var zip = new SysZip(null);
		zip.buffer = new ProtectedBuffer(bytes, wrapped);
		zip.updateEntries();
		return zip;
	}

	/**
	 * Creates a new SysZip from a specified path.
	 * @param path Path to the zip file. (With the extension)
	 */
	public function new(path:String) {
		// null only happens through fromBytes, which fills the buffer itself
		if (path == null) return;
		this.filePath = path;
		fileInput = File.read(path, true);

		updateEntries(); // automatic but if you feel like you don't want it to be automatic, you can remove this.
	}

	function size():Int {
		if (buffer != null) return buffer.length;
		try return Std.int(sys.FileSystem.stat(filePath).size) catch (e:Dynamic) {}
		return 0;
	}

	/** Bytes `[pos, pos + len)` of the archive, from the file or from the buffer. */
	function readBytes(pos:Int, len:Int):Bytes {
		if (len <= 0 || pos < 0) return Bytes.alloc(0);
		if (buffer != null) return buffer.read(pos, len);
		fileInput.seek(pos, SeekBegin);
		return fileInput.read(len);
	}

	/**
	 * Unzips and returns all of the data present in an entry.
	 * @param f Entry to read from.
	 */
	public function unzipEntry(f:SysZipEntry):Bytes {
		if (f.fileSize <= 0) return Bytes.alloc(0);

		var data = readBytes(f.seekPos, f.compressedSize);
		if (data == null) return Bytes.alloc(0);

		if (!f.compressed) return data;

		var c = new haxe.zip.Uncompress(-15);
		var s = Bytes.alloc(f.fileSize);
		var r = c.execute(data, 0, s, 0);
		c.close();

		if (!r.done || r.read != data.length || r.write != f.fileSize) throw 'Invalid compressed data for ${f.fileName} | ${f.compressedSize} -> ${f.fileSize}';
		return s;
	}

	/**
	 * Updates the `entries` list with the current contents of the zip file.
	 * This is done when the zip is read from SysZip the first time, but if you REALLY need to re-update the entries, you can call this again.
	 *
	 * Note: Calling this function will hold up the game as it has to read the ENTIRE zip, so if it's large like 1GiB or more, it might take a second or more.
	 */
	public function updateEntries() {
		if (entries.length > 0) {
			entries.clear();
			entries = new List();
		}

		var total = size();
		if (total <= 22) return;

		// --- locate End of Central Directory (EOCD) ---
		var scanSize:Int = (65535 < total) ? 65535 : total;
		var buf = readBytes(total - scanSize, scanSize);
		if (buf == null || buf.length < 22) return;

		// scanned backwards instead of assuming the record sits on the last 22 bytes, so
		// an archive with a comment still resolves
		var eocd = -1;
		var i = buf.length - 22;
		while (i >= 0) {
			if (buf.get(i) == 0x50 && buf.get(i + 1) == 0x4B && buf.get(i + 2) == 0x05 && buf.get(i + 3) == 0x06) {
				eocd = i;
				break;
			}
			i--;
		}
		if (eocd < 0) return;

		var tail = new haxe.io.BytesInput(buf);
		tail.position = eocd + 12;
		var cdSize = tail.readInt32();
		var cdOffset = tail.readInt32();
		if (cdSize <= 0 || cdOffset <= 0 || cdOffset + cdSize > total) return;

		// --- read central directory ---
		var cd = new haxe.io.BytesInput(readBytes(cdOffset, cdSize));
		while (true) {
			if (cd.position + 46 > cdSize) break;
			if (cd.readInt32() != 0x02014b50) break; // central dir file header signature

			cd.position += 6; // version made by / version needed
			var compression_method = cd.readUInt16();
			cd.position += 8; // time/date + CRC32
			var compressed_size = cd.readInt32();
			var uncompressed_size = cd.readInt32();
			var nameLen = cd.readUInt16();
			var extraLen = cd.readUInt16();
			var commentLen = cd.readUInt16();
			cd.position += 8; // disk number / internal+external attributes
			var localHeaderOffset = cd.readInt32();

			var name = cd.read(nameLen).toString();

			// skip central directory extra/comment
			cd.position += extraLen + commentLen;

			// --- compute correct seekPos using local header ---
			var head = readBytes(localHeaderOffset, 30);
			if (head == null || head.length < 30) continue;
			var local = new haxe.io.BytesInput(head);
			local.position = 26;
			var localNameLen = local.readUInt16();
			var localExtraLen = local.readUInt16();

			// the folders are labeled as 0 bytes anyways so this will save on storing non-required data.
			if (name.endsWith("/")) continue;

			var zipEntry:SysZipEntry = {
				fileName: name,
				fileSize: uncompressed_size,
				seekPos: (localHeaderOffset + 30 + localNameLen + localExtraLen),
				compressedSize: compressed_size,
				compressed: (compression_method == 8),
			};
			entries.add(zipEntry);
		}
	}

	/**
	 * calling `dispose` doesn't actually kill the class, you can still access the entries.
	 * disposing of SysZip will free the compressed file from being used by the engine,
	 * and wipes an in-memory pack so the decrypted bytes do not outlive it.
	 */
	public function dispose() {
		if (fileInput != null) fileInput.close();
		if (buffer != null) {
			buffer.wipe();
			buffer = null;
		}
	}
}

typedef SysZipEntry = {
	var fileName:String;
	var fileSize:Int;
	var seekPos:Int;
	var compressedSize:Int;
	var compressed:Bool;
}
#end
