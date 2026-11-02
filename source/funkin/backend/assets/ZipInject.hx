package funkin.backend.assets;

import haxe.crypto.Crc32;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * Appends one file to a zip. Existing entries are not read, touched or re-compressed.
 *
 * Rebuilding an archive from a folder costs a full inflate/deflate pass. For dropping a
 * few hundred bytes of marker into a 200 MB pack that is a waste of both time and
 * memory. The new entry goes in where the central directory starts, so nothing already
 * in the file moves.
 *
 * Archives with an end-of-directory comment are refused rather than guessed at.
 */
class ZipInject {
	public static function addFile(zip:Bytes, name:String, content:Bytes, ?time:Date):Bytes {
		if (zip == null || zip.length < 22) throw "ZipInject: not a zip";
		var nameBytes = Bytes.ofString(name);
		if (nameBytes.length > 0xFFFF) throw "ZipInject: name too long";

		// --- end of central directory, scanned back so a comment cannot fool us
		var eocd = -1;
		var floor = zip.length - 22 - 0xFFFF;
		if (floor < 0) floor = 0;
		var i = zip.length - 22;
		while (i >= floor) {
			if (zip.get(i) == 0x50 && zip.get(i + 1) == 0x4B && zip.get(i + 2) == 0x05 && zip.get(i + 3) == 0x06) {
				eocd = i;
				break;
			}
			i--;
		}
		if (eocd < 0) throw "ZipInject: no end of central directory";

		var count = readU16(zip, eocd + 10);
		var cdSize = readU32(zip, eocd + 12);
		var cdOffset = readU32(zip, eocd + 16);
		// anything left over would be a trailing comment; appending to one is not worth
		// the guessing, and a mod pack has no reason to carry one
		if (cdOffset + cdSize != eocd) throw "ZipInject: unexpected layout (comment or trailing data)";

		var dt = time == null ? Date.now() : time;
		var dosTime = (dt.getHours() << 11) | (dt.getMinutes() << 5) | Std.int(dt.getSeconds() / 2);
		var dosDate = ((dt.getFullYear() - 1980) << 9) | ((dt.getMonth() + 1) << 5) | dt.getDate();
		var crc = Crc32.make(content);

		// --- local header + stored data
		var local = new BytesBuffer();
		writeU32(local, 0x04034B50);
		writeU16(local, 20); // version needed
		writeU16(local, 0); // flags
		writeU16(local, 0); // stored
		writeU16(local, dosTime);
		writeU16(local, dosDate);
		writeU32(local, crc);
		writeU32(local, content.length);
		writeU32(local, content.length);
		writeU16(local, nameBytes.length);
		writeU16(local, 0); // extra
		local.add(nameBytes);
		local.add(content);

		// --- one more central directory record, pointing at that header
		var cd = new BytesBuffer();
		writeU32(cd, 0x02014B50);
		writeU16(cd, 20); // version made by
		writeU16(cd, 20); // version needed
		writeU16(cd, 0); // flags
		writeU16(cd, 0); // stored
		writeU16(cd, dosTime);
		writeU16(cd, dosDate);
		writeU32(cd, crc);
		writeU32(cd, content.length);
		writeU32(cd, content.length);
		writeU16(cd, nameBytes.length);
		writeU16(cd, 0); // extra len
		writeU16(cd, 0); // comment len
		writeU16(cd, 0); // disk number
		writeU16(cd, 0); // internal attributes
		writeU32(cd, 0); // external attributes
		writeU32(cd, cdOffset); // local header offset
		cd.add(nameBytes);

		var localBytes = local.getBytes();
		var cdBytes = cd.getBytes();

		var out = new BytesBuffer();
		out.add(zip.sub(0, cdOffset)); // headers and data, untouched
		out.add(localBytes); // the new entry, right where the directory used to start
		out.add(zip.sub(cdOffset, cdSize)); // the original directory
		out.add(cdBytes); // its new record

		// --- rewritten EOCD
		writeU32(out, 0x06054B50);
		writeU16(out, 0); // disk
		writeU16(out, 0); // directory disk
		writeU16(out, count + 1);
		writeU16(out, count + 1);
		writeU32(out, cdSize + cdBytes.length);
		writeU32(out, cdOffset + localBytes.length);
		writeU16(out, 0); // comment length
		return out.getBytes();
	}

	// ------------------------------------------------------------------ helpers

	static function readU16(b:Bytes, o:Int):Int {
		return b.get(o) | (b.get(o + 1) << 8);
	}

	static function readU32(b:Bytes, o:Int):Int {
		return b.get(o) | (b.get(o + 1) << 8) | (b.get(o + 2) << 16) | (b.get(o + 3) << 24);
	}

	static function writeU16(b:BytesBuffer, v:Int):Void {
		b.addByte(v & 0xFF);
		b.addByte((v >>> 8) & 0xFF);
	}

	static function writeU32(b:BytesBuffer, v:Int):Void {
		b.addByte(v & 0xFF);
		b.addByte((v >>> 8) & 0xFF);
		b.addByte((v >>> 16) & 0xFF);
		b.addByte((v >>> 24) & 0xFF);
	}
}
