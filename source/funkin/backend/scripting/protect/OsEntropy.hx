package funkin.backend.scripting.protect;

import haxe.io.Bytes;
#if sys
import sys.io.File;
#end

/**
 * System entropy for salts and nonces.
 *
 * Salts and nonces do not have to be secret, but they must not be predictable:
 * a repeated nonce under the same key breaks ChaCha20 outright, and a guessable
 * salt weakens the KDF. `ScriptCrypto.randomBytes()` used the OS pool on unix
 * only, because plain Haxe has no portable Windows equivalent - and Windows is
 * the platform this engine ships on most. This class fills that gap through
 * RtlGenRandom (see utils/native/Windows.hx), and keeps the unix path for the
 * other targets.
 *
 * Every method returns false instead of a partly filled buffer: the caller then
 * falls back to the ChaCha20 DRBG, which is at least self consistent.
 */
class OsEntropy {
	/**
	 * Fills `out` from the best source the platform has. Returns false when no
	 * OS source is available, in which case `out` is left untouched.
	 */
	public static function fill(out:Bytes):Bool {
		if (out == null) return false;
		if (out.length == 0) return true;

		#if (cpp && windows)
		try {
			if (funkin.backend.utils.native.Windows.fillRandomBytes(out)) return true;
		} catch (e:Dynamic) {}
		return false;
		#elseif sys
		// No /dev/urandom on Windows, so the native path above is the only one there.
		return readUrandom(out);
		#else
		return false;
		#end
	}

	#if sys
	/**
	 * Fills `out` from /dev/urandom; false on platforms that do not have it
	 * (Windows, and any target without a device file system).
	 */
	static function readUrandom(out:Bytes):Bool {
		var handle = null;
		try {
			handle = File.read("/dev/urandom", true);
			var got = 0;
			while (got < out.length) {
				var chunk = handle.read(out.length - got);
				if (chunk == null || chunk.length == 0) break;
				out.blit(got, chunk, 0, chunk.length);
				got += chunk.length;
			}
			handle.close();
			return got == out.length;
		} catch (e:Dynamic) {
			try if (handle != null) handle.close() catch (e2:Dynamic) {}
			return false;
		}
	}
	#end
}
