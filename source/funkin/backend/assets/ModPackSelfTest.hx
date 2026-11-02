package funkin.backend.assets;

import funkin.backend.scripting.crypto.ChaCha20;
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

		var expectedSize = payload.length + ModPackCrypto.HEADER_SIZE + ModPackCrypto.TAG_SIZE;
		check("pack() builds a container", container.length == expectedSize,
			container.length + " bytes, expected " + expectedSize);
		check("the container carries the CNEZ magic", ModPackCrypto.isEncryptedPack(container));
		check("a plain zip is not mistaken for a container", !ModPackCrypto.isEncryptedPack(payload));

		// --- round trip
		var restored:Bytes = null;
		var restoreError:String = null;
		try restored = ModPackCrypto.unpack(container, key) catch (e:Dynamic) restoreError = Std.string(e);
		check("unpack() restores the payload", restored != null && sameBytes(restored, payload),
			restoreError != null ? restoreError : "bytes differ");

		// --- a wrong key has to fail loudly, never decrypt into garbage
		var wrongRejected = false;
		try ModPackCrypto.unpack(container, "definitely-not-the-key") catch (e:Dynamic) wrongRejected = true;
		check("a wrong key is rejected", wrongRejected);

		// --- the tag has to cover the payload, not just the header
		var tampered = container.sub(0, container.length);
		var at = ModPackCrypto.HEADER_SIZE + 3;
		tampered.set(at, tampered.get(at) ^ 0xFF);
		var tamperRejected = false;
		try ModPackCrypto.unpack(tampered, key) catch (e:Dynamic) tamperRejected = true;
		check("a flipped payload byte is rejected", tamperRejected);

		// --- the lazy path the loader actually uses: verify, then read ranges
		var opened:{cipher:Bytes, enc:Bytes, nonce:Bytes} = null;
		try opened = ModPackCrypto.openEncrypted(container, key) catch (e:Dynamic) {
			check("openEncrypted() verifies without decrypting", false, Std.string(e));
		}

		if (opened != null) {
			check("openEncrypted() returns the payload still encrypted", opened.cipher.length == payload.length,
				opened.cipher.length + " bytes, expected " + payload.length);

			var probeLen = opened.cipher.length < 64 ? opened.cipher.length : 64;
			var probe = ChaCha20.xorBytes(opened.enc, opened.nonce, 1, opened.cipher.sub(0, probeLen));
			check("the returned key decrypts the first block", sameBytes(probe, payload.sub(0, probeLen)));

			// this is the check that would have caught the double pass being removable:
			// the zip layer indexes ciphertext directly and still sees the entry table
			var zip:SysZip = null;
			try zip = SysZip.fromCipher(opened.cipher, opened.enc, opened.nonce) catch (e:Dynamic) {
				check("the lazy reader indexes the archive", false, Std.string(e));
			}
			if (zip != null) {
				check("the lazy reader indexes the archive", zip.entries.length == 1, "entries " + zip.entries.length);
				if (zip.entries.length == 1) {
					var asset = zip.unzipEntry(zip.entries.first());
					check("the lazy reader returns the asset bytes", sameBytes(asset, Bytes.ofString(SAMPLE)),
						asset == null ? "null" : asset.length + " bytes, expected " + SAMPLE.length);
				}
				zip.dispose();
			}
		}

		return summarize(passed, failed);
	}

	// ------------------------------------------------------------------ helpers

	static function summarize(passed:Int, failed:Int):String {
		return passed + " passed, " + failed + " failed";
	}

	static function sameBytes(a:Bytes, b:Bytes):Bool {
		if (a == null || b == null || a.length != b.length) return false;
		var diff = 0;
		for (i in 0...a.length) diff |= a.get(i) ^ b.get(i);
		return diff == 0;
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
