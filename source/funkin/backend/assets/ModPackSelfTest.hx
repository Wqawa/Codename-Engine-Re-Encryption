package funkin.backend.assets;

import funkin.backend.utils.SysZip;
import haxe.crypto.Crc32;
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.zip.Entry;
import haxe.zip.Writer;

/**
 * Round trip checks for both CNEZ container versions, run from the editor's Tools menu.
 *
 * The container is the one part of this feature that cannot be judged by looking at
 * the screen: a pack that decrypts to the wrong bytes still opens, it just plays the
 * wrong thing. Everything here is built in memory and asserted on bytes, so a change
 * to the layout, the keystream or the key derivation shows up as a FAIL line instead
 * of as a broken mod.
 *
 * Version 2 gets its own block because its guarantee is weaker by design: the header
 * and the chunk table are checked on open, and a payload chunk is checked when it is
 * first read. The check below damages a payload byte and asserts exactly that - open
 * still succeeds, reading does not.
 *
 * Output shape matches ScriptContainerSelfTest: one "ok"/"FAIL" line per check plus a
 * "N passed, M failed" summary the editor can test with indexOf.
 */
class ModPackSelfTest {
	/** Long enough that the first keystream block is a meaningful probe. */
	static inline var SAMPLE:String = "CnezSelfTestPayload::0123456789abcdefghijklmnopqrstuvwxyz::"
		+ "the quick brown fox jumps over the lazy dog, twice over, to pass one ChaCha20 block";

	static var lines:Array<String> = [];

	public static function getLines():Array<String> {
		return lines;
	}

	public static function run():String {
		lines = [];
		var passed = 0;
		var failed = 0;

		function check(name:String, ok:Bool, ?detail:String) {
			if (ok) {
				passed++;
				lines.push("ok   " + name);
			} else {
				failed++;
				lines.push("FAIL " + name + (detail == null ? "" : " - " + detail));
			}
		}

		var payload = sampleZip();
		var key = "self-test-key";

		// ============================================================ version 1
		var v1:Bytes = null;
		try {
			v1 = ModPackCrypto.packV1(payload, key);
		} catch (e:Dynamic) {
			check("v1: packV1() builds a container", false, Std.string(e));
			return summarize(passed, failed);
		}

		var v1Size = payload.length + ModPackCrypto.HEADER_SIZE + ModPackCrypto.TAG_SIZE;
		check("v1: layout is header + payload + tag", v1.length == v1Size, v1.length + " bytes, expected " + v1Size);
		check("v1: carries the CNEZ magic", ModPackCrypto.isEncryptedPack(v1));
		check("v1: a plain zip is not mistaken for a container", !ModPackCrypto.isEncryptedPack(payload));
		check("v1: is not reported as version 2", !CnezV2.isV2(v1));

		var restored:Bytes = null;
		var restoreError:String = null;
		try restored = ModPackCrypto.unpack(v1, key) catch (e:Dynamic) restoreError = Std.string(e);
		check("v1: unpack() restores the payload", restored != null && sameBytes(restored, payload),
			restoreError != null ? restoreError : "bytes differ");

		var wrongRejected = false;
		try ModPackCrypto.unpack(v1, "definitely-not-the-key") catch (e:Dynamic) wrongRejected = true;
		check("v1: a wrong key is rejected", wrongRejected);

		var tamperedV1 = v1.sub(0, v1.length);
		var v1At = ModPackCrypto.HEADER_SIZE + 3;
		tamperedV1.set(v1At, tamperedV1.get(v1At) ^ 0xFF);
		var v1TamperRejected = false;
		try ModPackCrypto.unpack(tamperedV1, key) catch (e:Dynamic) v1TamperRejected = true;
		check("v1: a flipped payload byte is rejected", v1TamperRejected);

		var openedV1:ModPackCrypto.OpenedPack = null;
		try openedV1 = ModPackCrypto.openEncrypted(v1, key) catch (e:Dynamic) {
			check("v1: openEncrypted() verifies without decrypting", false, Std.string(e));
		}
		if (openedV1 != null) {
			check("v1: openEncrypted() reports no chunk table", openedV1.chunkCount == 0);
			checkLazyRead(check, "v1", openedV1);
		}

		// ============================================================ version 2
		var v2:Bytes = null;
		try {
			v2 = ModPackCrypto.pack(payload, key);
		} catch (e:Dynamic) {
			check("v2: pack() builds a container", false, Std.string(e));
			return summarize(passed, failed);
		}

		check("v2: pack() produces version 2 by default", CnezV2.isV2(v2));
		// one chunk for a payload this small: header + one chunk tag + root tag + payload
		var v2Size = payload.length + CnezV2.HEADER_SIZE + 2 * CnezV2.TAG_SIZE;
		check("v2: layout is header + chunk table + root tag + payload", v2.length == v2Size,
			v2.length + " bytes, expected " + v2Size);

		var restoredV2:Bytes = null;
		var restoreV2Error:String = null;
		try restoredV2 = ModPackCrypto.unpack(v2, key) catch (e:Dynamic) restoreV2Error = Std.string(e);
		check("v2: unpack() restores the payload", restoredV2 != null && sameBytes(restoredV2, payload),
			restoreV2Error != null ? restoreV2Error : "bytes differ");

		var v2WrongRejected = false;
		try CnezV2.open(v2, "definitely-not-the-key") catch (e:Dynamic) v2WrongRejected = true;
		check("v2: a wrong key is rejected", v2WrongRejected);

		// the chunk table is covered by the root tag, so flipping a tag must fail
		var flippedTable = v2.sub(0, v2.length);
		var tableAt = CnezV2.HEADER_SIZE;
		flippedTable.set(tableAt, flippedTable.get(tableAt) ^ 0xFF);
		var tableRejected = false;
		try CnezV2.open(flippedTable, key) catch (e:Dynamic) tableRejected = true;
		check("v2: a flipped chunk tag is rejected", tableRejected);

		var openedV2:ModPackCrypto.OpenedPack = null;
		try openedV2 = ModPackCrypto.openEncrypted(v2, key) catch (e:Dynamic) {
			check("v2: openEncrypted() verifies the header", false, Std.string(e));
		}

		if (openedV2 != null) {
			check("v2: openEncrypted() reports the chunk table", openedV2.chunkCount > 0, "chunks " + openedV2.chunkCount);
			checkLazyRead(check, "v2", openedV2);

			// --- the whole point of version 2: a payload byte is not checked on open,
			// --- only when a read lands in its chunk
			var damaged = v2.sub(0, v2.length);
			var payloadAt = CnezV2.HEADER_SIZE + openedV2.chunkCount * CnezV2.TAG_SIZE + CnezV2.TAG_SIZE + 8;
			damaged.set(payloadAt, damaged.get(payloadAt) ^ 0xFF);

			var stillOpens = true;
			try CnezV2.open(damaged, key) catch (e:Dynamic) stillOpens = false;
			check("v2: a damaged payload still passes the header check", stillOpens,
				"the payload was still hashed up front, so version 2 bought nothing");

			// reading that chunk has to fail: the archive index of this fixture sits in it
			var badOpen = ModPackCrypto.openEncrypted(damaged, key);
			var badZip = SysZip.fromChunked(badOpen.cipher, badOpen.enc, badOpen.nonce, badOpen.chunkSize,
				badOpen.chunkTags, badOpen.chunkCount, badOpen.mac);
			check("v2: reading a damaged chunk yields no entries", badZip.entries.length == 0,
				"entries " + badZip.entries.length + " - the chunk check did not fire");
			badZip.dispose();
		}

		return summarize(passed, failed);
	}

	// ------------------------------------------------------------------ helpers

	/** Indexes the archive through the lazy reader and reads the one entry back. */
	static function checkLazyRead(check:String->Bool->?String->Void, label:String, opened:ModPackCrypto.OpenedPack):Void {
		var zip:SysZip = null;
		try {
			zip = opened.chunkCount > 0
				? SysZip.fromChunked(opened.cipher, opened.enc, opened.nonce, opened.chunkSize, opened.chunkTags,
					opened.chunkCount, opened.mac)
				: SysZip.fromCipher(opened.cipher, opened.enc, opened.nonce);
		} catch (e:Dynamic) {
			check('$label: the lazy reader indexes the archive', false, Std.string(e));
			return;
		}

		check('$label: the lazy reader indexes the archive', zip.entries.length == 1, "entries " + zip.entries.length);
		if (zip.entries.length == 1) {
			var asset = zip.unzipEntry(zip.entries.first());
			check('$label: the lazy reader returns the asset bytes', sameBytes(asset, Bytes.ofString(SAMPLE)),
				asset == null ? "null" : asset.length + " bytes, expected " + SAMPLE.length);
		}
		zip.dispose();
	}

	static function summarize(passed:Int, failed:Int):String {
		return passed + " passed, " + failed + " failed";
	}

	static function sameBytes(a:Bytes, b:Bytes):Bool {
		if (a == null || b == null || a.length != b.length) return false;
		return CnezV2.same(a, b);
	}

	/** One stored entry, written by the std zip writer so the fixture is a real archive. */
	static function sampleZip():Bytes {
		var data = Bytes.ofString(SAMPLE);
		var entry:Entry = {
			fileName: "a.txt",
			fileSize: data.length,
			fileTime: Date.now(),
			compressed: false,
			dataSize: data.length,
			data: data,
			crc32: Crc32.make(data)
		};
		var files = new List<Entry>();
		files.add(entry);
		var out = new BytesOutput();
		new Writer(out).write(files);
		return out.getBytes();
	}
}
