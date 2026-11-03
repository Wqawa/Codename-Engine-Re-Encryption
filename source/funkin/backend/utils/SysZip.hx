package funkin.backend.utils;

#if sys
import funkin.backend.assets.CnezV2;
import funkin.backend.assets.CnezV2.FileOpenedV2;
import funkin.backend.scripting.crypto.ChaCha20;
import funkin.backend.scripting.crypto.ScriptCrypto;
import funkin.backend.scripting.protect.ProtectedBuffer;
import funkin.backend.scripting.protect.SecureBytes;
import sys.io.File;
import sys.io.FileInput;

import haxe.io.Bytes;

/**
 * Zip reader that indexes an archive without loading all of it, so a mod pack can be
 * read straight out of memory or out of a CNEZ payload.
 *
 * Three sources, all behind the same `readBytes`:
 *
 *   file    a plain .zip on disk
 *   buffer  a readable zip already in memory (password protected packs)
 *   cipher  a CNEZ payload, decrypted per range as it is read
 */
class SysZip {
	var fileInput:FileInput;
	var filePath:String;
	/** Set in buffer mode; null when the zip is read from a file. */
	var buffer:ProtectedBuffer;

	/** ChaCha20 block size; a range read starts on a multiple of it. */
	static inline var BLOCK:Int = 64;

	// cipher mode: the payload stays in the file, only the ranges that are read are
	// decrypted, so the pack never occupies RAM
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
	 * Opens a zip from a path.
	 * @param path Path to the zip file, extension included.
	 */
	public static function openFromFile(path:String):SysZip return new SysZip(path); // kept for compatibility

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
	 * Reads a zip that is still a ChaCha20 ciphertext: the central directory is decrypted
	 * to index the entries, and each asset is decrypted when something asks for it.
	 */
	public static function fromChunked(cipher:Bytes, cipherKey:Bytes, cipherNonce:Bytes, chunkSize:Int, chunkTags:Bytes,
			chunkCount:Int, macKey:Bytes):SysZip {
		var zip = new SysZip(null);
		zip.buffer = ProtectedBuffer.fromChunkedCipher(cipher, cipherKey, cipherNonce, chunkSize, chunkTags, chunkCount, macKey);
		zip.updateEntries();
		return zip;
	}

	/** Creates a SysZip from a path. `null` is only used by the factories above. */
	public function new(path:String) {
		if (path == null) return;
		this.filePath = path;
		fileInput = File.read(path, true);
		updateEntries();
	}

	/**
	 * Reads a zip straight out of an encrypted file, decrypting only the ranges that are
	 * actually read. Nothing of the payload is copied into memory; the cost is a seek and
	 * a decryption per read.
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
		zip.chunkVerified = [for (i in 0...opened.count) false];
		zip.updateEntries();
		return zip;
	}

	/** Total bytes of the archive, in whichever mode this instance uses. */
	function size():Int {
		if (buffer != null) return buffer.length;
		if (cipherKey != null) return cipherLength;
		if (fileInput == null) return 0;
		try return Std.int(sys.FileSystem.stat(filePath).size) catch (e:Dynamic) {}
		return 0;
	}

	/**
	 * Bytes `[pos, pos + len)` of the archive.
	 *
	 * A released zip has neither a buffer nor a handle. That used to be a null dereference
	 * on the next read, which hxcpp turns into a dead process - so a late reader now gets
	 * no bytes and one warning instead.
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
	 * Decrypts `[pos, pos + len)` out of the pack file.
	 *
	 * Starts on a 64 byte boundary so the keystream lines up, and verifies every chunk
	 * the range touches by reading that chunk whole - a tag needs all of it. The chunk is
	 * checked and dropped, not kept: this mode exists so nothing stays in memory.
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

	/** True once dispose() released the archive; reading it is pointless from then on. */
	public var released(default, null):Bool = false;
	var warnedRelease:Bool = false;

	/**
	 * Set when the file behind this archive was rewritten (a merge) and the copy in memory
	 * no longer matches it.
	 *
	 * The buffer stays usable for whatever reads through it right now, but the pack must
	 * not be handed out as "already decrypted" again, and it is disposed with the next load.
	 */
	public var stale:Bool = false;

	/** Bytes this archive holds, for the cleanup summary. */
	public function dataSize():Int return size();

	function warnReleased():Void {
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
		var out = Bytes.alloc(f.fileSize);
		var r = c.execute(data, 0, out, 0);
		c.close();

		if (!r.done || r.read != data.length || r.write != f.fileSize)
			throw 'Invalid compressed data for ${f.fileName} | ${f.compressedSize} -> ${f.fileSize}';
		return out;
	}

	/**
	 * Rebuilds `entries` from the central directory.
	 *
	 * Called once when the archive is opened; call it again only if the file changed
	 * underneath. It seeks through the archive instead of reading it whole, but a very
	 * large pack still takes a moment.
	 */
	public function updateEntries():Void {
		entries = new List();
		var total = size();
		if (total <= 22) return;

		var eocd = findEndOfCentralDirectory(total);
		if (eocd == null) return;
		readCentralDirectory(eocd.cdOffset, eocd.cdSize);
	}

	/** Where the central directory sits and how big it is, or null when the tail makes no sense. */
	function findEndOfCentralDirectory(total:Int):{cdOffset:Int, cdSize:Int} {
		var scanSize = 65535 < total ? 65535 : total;
		var buf = readBytes(total - scanSize, scanSize);
		if (buf == null || buf.length < 22) return null;

		// scanned backwards so an archive with a comment still resolves
		var at = -1;
		var i = buf.length - 22;
		while (i >= 0) {
			if (buf.get(i) == 0x50 && buf.get(i + 1) == 0x4B && buf.get(i + 2) == 0x05 && buf.get(i + 3) == 0x06) {
				at = i;
				break;
			}
			i--;
		}
		if (at < 0) return null;

		var tail = new haxe.io.BytesInput(buf);
		tail.position = at + 12;
		var cdSize = tail.readInt32();
		var cdOffset = tail.readInt32();
		if (cdSize <= 0 || cdOffset <= 0 || cdOffset + cdSize > total) return null;
		return {cdOffset: cdOffset, cdSize: cdSize};
	}

	/** Walks the central directory and turns every file header into a `SysZipEntry`. */
	function readCentralDirectory(cdOffset:Int, cdSize:Int):Void {
		var cd = new haxe.io.BytesInput(readBytes(cdOffset, cdSize));
		while (cd.position + 46 <= cdSize) {
			if (cd.readInt32() != 0x02014b50) break; // central dir header signature

			cd.position += 6; // version made by / version needed
			var method = cd.readUInt16();
			cd.position += 8; // time/date + CRC32
			var compressedSize = cd.readInt32();
			var uncompressedSize = cd.readInt32();
			var nameLen = cd.readUInt16();
			var extraLen = cd.readUInt16();
			var commentLen = cd.readUInt16();
			cd.position += 8; // disk number / internal + external attributes
			var localOffset = cd.readInt32();

			var name = cd.read(nameLen).toString();
			cd.position += extraLen + commentLen;

			// folders are zero sized in every archive worth reading, so they are skipped
			if (name.endsWith("/")) continue;

			// the local header carries its own name/extra lengths; the payload follows them
			var head = readBytes(localOffset, 30);
			if (head == null || head.length < 30) continue;
			var local = new haxe.io.BytesInput(head);
			local.position = 26;
			var localNameLen = local.readUInt16();
			var localExtraLen = local.readUInt16();

			entries.add({
				fileName: name,
				fileSize: uncompressedSize,
				seekPos: localOffset + 30 + localNameLen + localExtraLen,
				compressedSize: compressedSize,
				compressed: method == 8
			});
		}
	}

	/**
	 * Closes the file handle of a low-memory pack so the file can be replaced on disk.
	 *
	 * Windows refuses to rename over a file that is still open, and a merge has to put the
	 * new pack in its place. The archive is marked released, so the loader opens it again
	 * next load. Only cipher mode is affected - a memory pack never keeps the file open.
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
	 * Frees the file handle and wipes an in-memory pack so the decrypted bytes do not
	 * outlive it. The entries stay readable, but reads return nothing.
	 */
	public function dispose():Void {
		released = true;
		if (fileInput != null) {
			try fileInput.close() catch (e:Dynamic) {}
			fileInput = null;
		}
		if (buffer != null) {
			buffer.wipe();
			buffer = null;
		}
		// cipher mode holds keys instead of data; they go too
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
