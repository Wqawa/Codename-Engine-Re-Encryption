package funkin.backend.utils;

#if sys
import funkin.backend.assets.CnezV2;
import funkin.backend.assets.CnezV2.FileOpenedV2;
import funkin.backend.scripting.crypto.ChaCha20;
import funkin.backend.scripting.crypto.ScriptCrypto;
import funkin.backend.scripting.protect.ProtectedBuffer;
import funkin.backend.scripting.protect.SecureBytes;
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

	/** Size of one ChaCha20 block; a range read starts at a multiple of this. */
	static inline var BLOCK:Int = 64;

	// --- low-memory mode: the payload stays in the file and only the ranges being read
	// --- are decrypted, so a pack never occupies RAM
	var cipherKey:Bytes;
	var cipherNonce:Bytes;
	var cipherOffset:Int = 0;
	var cipherLength:Int = 0;
	var chunkSize:Int = 0;
	var chunkCount:Int = 0;
	var chunkTags:Bytes;
	var chunkMac:Bytes;
	var chunkVerified:Array<Bool>;

	/** Set when a chunk failed its tag check; reads return nothing from then on. */
	public var integrityFailed(default, null):Bool = false;

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
	 * Reads a zip that is still a ChaCha20 ciphertext, decrypting only the ranges that
	 * are actually read and verifying each chunk the first time a read touches it.
	 *
	 * A CNEZ pack arrives here already encrypted under its own key, so no full pass is
	 * needed before the archive becomes usable: the central directory is decrypted to
	 * index the entries, and each asset is decrypted when something asks for it
	 * (`CnezV2` explains what that costs in detection, and `ProtectedBuffer` how a
	 * range is decoded).
	 */
	public static function fromChunked(cipher:Bytes, cipherKey:Bytes, cipherNonce:Bytes, chunkSize:Int, chunkTags:Bytes, chunkCount:Int,
			macKey:Bytes):SysZip {
		var zip = new SysZip(null);
		zip.buffer = ProtectedBuffer.fromChunkedCipher(cipher, cipherKey, cipherNonce, chunkSize, chunkTags, chunkCount, macKey);
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
		if (cipherKey != null) return cipherLength;
		if (fileInput == null) return 0;
		try return Std.int(sys.FileSystem.stat(filePath).size) catch (e:Dynamic) {}
		return 0;
	}

	/**
	 * Bytes `[pos, pos + len)` of the archive, from the file or from the buffer.
	 *
	 * A released zip (see dispose) has neither a buffer nor a handle. That used to be
	 * a null dereference on the next read, which hxcpp turns into a dead process
	 * instead of a failed asset - so anything that still holds the archive after it
	 * was released now gets no bytes and one warning instead of a crash.
	 */
	function readBytes(pos:Int, len:Int):Bytes {
		if (len <= 0 || pos < 0) return Bytes.alloc(0);
		if (buffer != null) return buffer.read(pos, len);
		if (fileInput == null) {
			warnReleased();
			return Bytes.alloc(0);
		}
		if (cipherKey != null) return readCipherRange(pos, len);
		fileInput.seek(pos, SeekBegin);
		return fileInput.read(len);
	}

	/**
	 * Reads a zip straight out of an encrypted file, decrypting only the ranges that are
	 * actually read. Nothing of the payload is copied into memory - that is what the
	 * low-memory option buys; the cost is a seek and a decryption per read.
	 */
	public static function fromCipherFile(path:String, opened:FileOpenedV2):SysZip {
		var zip = new SysZip(null);
		zip.filePath = path;
		zip.fileInput = File.read(path, true);
		zip.cipherKey = opened.enc;
		zip.cipherNonce = opened.nonce;
		zip.cipherOffset = opened.payloadOffset;
		zip.cipherLength = opened.payloadLength;
		zip.chunkSize = opened.chunkSize;
		zip.chunkCount = opened.count;
		zip.chunkTags = opened.table;
		zip.chunkMac = opened.mac;
		zip.chunkVerified = [];
		for (i in 0...opened.count) zip.chunkVerified.push(false);
		zip.updateEntries();
		return zip;
	}

	/**
	 * Decrypts `[pos, pos + len)` out of the pack file.
	 *
	 * Starts on a 64 byte boundary so the keystream lines up, and verifies every chunk
	 * the range touches by reading that chunk whole - a tag needs all of it. The chunk
	 * is checked and dropped, not kept: this mode exists so nothing stays in memory.
	 */
	function readCipherRange(pos:Int, len:Int):Bytes {
		if (integrityFailed) return Bytes.alloc(0);
		if (pos + len > cipherLength) len = cipherLength - pos;
		if (len <= 0) return Bytes.alloc(0);

		var start = pos - (pos % BLOCK);
		var head = pos - start;
		var need = len + head;

		var first = Std.int(start / chunkSize);
		var last = Std.int((start + need - 1) / chunkSize);
		if (last >= chunkCount) last = chunkCount - 1;
		for (i in first...last + 1) {
			if (chunkVerified[i]) continue;
			var cStart = i * chunkSize;
			var cLen = chunkSize;
			if (cStart + cLen > cipherLength) cLen = cipherLength - cStart;
			fileInput.seek(cipherOffset + cStart, SeekBegin);
			var whole = fileInput.read(cLen);
			if (whole == null || whole.length < cLen
				|| !CnezV2.same(ScriptCrypto.hmacTag(chunkMac, whole), chunkTags.sub(i * CnezV2.TAG_SIZE, CnezV2.TAG_SIZE))) {
				integrityFailed = true;
				Logs.error('A mod pack chunk ($i of $chunkCount) failed its integrity check; '
					+ 'the pack was modified after it was packed. Reads stop here.');
				return Bytes.alloc(0);
			}
			chunkVerified[i] = true;
		}

		fileInput.seek(cipherOffset + start, SeekBegin);
		var raw = fileInput.read(need);
		if (raw == null || raw.length < need) return Bytes.alloc(0);
		var plain = ChaCha20.xorBytes(cipherKey, cipherNonce, 1 + Std.int(start / BLOCK), raw);
		var out = plain.sub(head, len);
		SecureBytes.wipe(plain);
		return out;
	}

	/**
	 * True once dispose() released the archive; reading it is pointless from then on.
	 */
	public var released(default, null):Bool = false;
	var warnedRelease:Bool = false;

	/**
	 * Set when the file behind this archive was rewritten (a merge) and the copy in memory
	 * no longer matches it.
	 *
	 * The buffer stays usable for whatever is reading through it right now - the libraries
	 * of the running load still do - but the pack must not be handed out as "already
	 * decrypted" again, and it is disposed with the next load.
	 */
	public var stale:Bool = false;

	/** Bytes this archive holds, for the cleanup summary (buffer length in memory mode). */
	public function dataSize():Int return size();

	function warnReleased() {
		if (warnedRelease) return;
		warnedRelease = true;
		Logs.warn('A mod pack was read after it had been released ($filePath). '
			+ 'The read returns nothing instead of taking the game down; the pack has to be decrypted again.');
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
	 * Closes the file handle of a low-memory pack so the file can be replaced on disk.
	 *
	 * The entries stay readable, but further reads return nothing: Windows refuses to
	 * rename over a file that is still open, and a merge has to put the new pack in its
	 * place. The archive is marked released, so the loader opens it again next load.
	 *
	 * Only the low-memory mode is affected - a memory pack never keeps the file open.
	 */
	public function closeHandle():Void {
		if (cipherKey == null) return;
		if (fileInput != null) {
			try fileInput.close() catch (e:Dynamic) {}
			fileInput = null;
		}
		released = true;
	}

	/**
	 * calling `dispose` doesn't actually kill the class, you can still access the entries.
	 * disposing of SysZip will free the compressed file from being used by the engine,
	 * and wipes an in-memory pack so the decrypted bytes do not outlive it.
	 */
	public function dispose() {
		released = true;
		if (fileInput != null) {
			try fileInput.close() catch (e:Dynamic) {}
			fileInput = null;
		}
		if (buffer != null) {
			buffer.wipe();
			buffer = null;
		}
		// the low-memory mode holds keys instead of data; they go too
		if (chunkTags != null) {
			SecureBytes.wipe(chunkTags);
			chunkTags = null;
		}
		if (chunkMac != null) {
			SecureBytes.wipe(chunkMac);
			chunkMac = null;
		}
		if (cipherKey != null) {
			SecureBytes.wipe(cipherKey);
			cipherKey = null;
		}
		if (chunkVerified != null) {
			for (i in 0...chunkVerified.length) chunkVerified[i] = false;
			chunkVerified = null;
		}
		cipherNonce = null;
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
