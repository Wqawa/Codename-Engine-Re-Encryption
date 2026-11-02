package funkin.backend.assets;

import funkin.backend.utils.SysZip;
import haxe.crypto.Crc32;
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.zip.Entry;
import haxe.zip.Writer;

/**
 * Round trip checks for the CNEZ container, run from the editor's Tools menu.
 *
 * The container is the one part of this feature that cannot be judged by looking at
 * the screen: a pack that decrypts to the wrong bytes still opens, it just plays the
 * wrong thing. Everything here is built in memory and asserted on bytes, so a change
 * to the layout, the keystream or the key derivation shows up as a FAIL line instead
 * of as a broken mod.
 *
 * The container checks its header and chunk table on open and verifies a payload chunk
 * when it is first read, so one check below damages a payload byte and asserts exactly
 * that: open still succeeds, reading does not.
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
		var container:Bytes = null;

		try {
			container = ModPackCrypto.pack(payload, key);
		} catch (e:Dynamic) {
			check("pack() builds a container", false, Std.string(e));
			return summarize(passed, failed);
		}

		// the fixture is far smaller than one chunk: header + one chunk tag + root tag
		var expectedSize = payload.length + CnezV2.HEADER_SIZE + 2 * CnezV2.TAG_SIZE;
		check("layout is header + chunk table + root tag + payload", container.length == expectedSize,
			container.length + " bytes, expected " + expectedSize);
		check("carries the CNEZ magic", ModPackCrypto.isEncryptedPack(container));
		check("a plain zip is not mistaken for a container", !ModPackCrypto.isEncryptedPack(payload));

		var restored:Bytes = null;
		var restoreError:String = null;
		try restored = ModPackCrypto.unpack(container, key) catch (e:Dynamic) restoreError = Std.string(e);
		check("unpack() restores the payload", restored != null && sameBytes(restored, payload),
			restoreError != null ? restoreError : "bytes differ");

		var wrongRejected = false;
		try ModPackCrypto.unpack(container, "definitely-not-the-key") catch (e:Dynamic) wrongRejected = true;
		check("a wrong key is rejected", wrongRejected);

		// the chunk table is covered by the root tag, so flipping a tag must fail
		var flippedTable = container.sub(0, container.length);
		var tableAt = CnezV2.HEADER_SIZE;
		flippedTable.set(tableAt, flippedTable.get(tableAt) ^ 0xFF);
		var tableRejected = false;
		try CnezV2.open(flippedTable, key) catch (e:Dynamic) tableRejected = true;
		check("a flipped chunk tag is rejected", tableRejected);

		var opened:ModPackCrypto.OpenedPack = null;
		try opened = ModPackCrypto.openEncrypted(container, key) catch (e:Dynamic) {
			check("openEncrypted() verifies the header", false, Std.string(e));
		}

		if (opened != null) {
			check("openEncrypted() reports the chunk table", opened.chunkCount > 0, "chunks " + opened.chunkCount);
			checkLazyRead(check, opened);

			// --- a payload byte is not checked on open, only when a read lands in it
			var damaged = container.sub(0, container.length);
			var payloadAt = CnezV2.HEADER_SIZE + opened.chunkCount * CnezV2.TAG_SIZE + CnezV2.TAG_SIZE + 8;
			damaged.set(payloadAt, damaged.get(payloadAt) ^ 0xFF);

			var stillOpens = true;
			try CnezV2.open(damaged, key) catch (e:Dynamic) stillOpens = false;
			check("a damaged payload still passes the header check", stillOpens,
				"the payload is being hashed up front, which the chunk table exists to avoid");

			// reading that chunk has to fail: the archive index of this fixture sits in it
			var badOpen = ModPackCrypto.openEncrypted(damaged, key);
			var badZip = SysZip.fromChunked(badOpen.cipher, badOpen.enc, badOpen.nonce, badOpen.chunkSize,
				badOpen.chunkTags, badOpen.chunkCount, badOpen.mac);
			check("reading a damaged chunk yields no entries", badZip.entries.length == 0,
				"entries " + badZip.entries.length + " - the chunk check did not fire");
			badZip.dispose();
		}

		return summarize(passed, failed);
	}

	// ------------------------------------------------------------------ helpers

	/** Indexes the archive through the lazy reader and reads the one entry back. */
	static function checkLazyRead(check:String->Bool->?String->Void, opened:ModPackCrypto.OpenedPack):Void {
		var zip:SysZip = null;
		try {
			zip = SysZip.fromChunked(opened.cipher, opened.enc, opened.nonce, opened.chunkSize, opened.chunkTags,
				opened.chunkCount, opened.mac);
		} catch (e:Dynamic) {
			check("the lazy reader indexes the archive", false, Std.string(e));
			return;
		}

		check("the lazy reader indexes the archive", zip.entries.length == 1, "entries " + zip.entries.length);
		if (zip.entries.length == 1) {
			var asset = zip.unzipEntry(zip.entries.first());
			check("the lazy reader returns the asset bytes", sameBytes(asset, Bytes.ofString(SAMPLE)),
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
