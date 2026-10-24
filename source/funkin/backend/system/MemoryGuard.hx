package funkin.backend.system;

import funkin.backend.scripting.crypto.ChaCha20;
import funkin.backend.scripting.crypto.ScriptCrypto;
import funkin.backend.scripting.protect.SecureBytes;
import funkin.backend.utils.native.MemoryProtect;
import haxe.io.Bytes;

/**
 * Best effort memory hygiene for protected content.
 *
 * What this can do: keep secrets wrapped in a per-session ChaCha20 stream so a
 * memory scan never sees a plaintext password or source sitting in a static
 * field, wipe buffers once they are no longer needed, and make the main thread
 * invisible to user mode debuggers.
 *
 * What this cannot do: stop a dumper that reads another process' memory or a
 * kernel mode debugger. Haxe has no way to lock pages or to protect the heap,
 * so treat this as "raises the bar", not as a guarantee.
 */
class MemoryGuard {
	static inline var NONCE_SIZE:Int = 12;

	/** Per session key for the wrapping stream; created on first use. */
	static var sessionKey:Bytes = null;
	static var hardened:Bool = false;
	static var debuggerSeen:Bool = false;

	static function keyBytes():Bytes {
		if (sessionKey == null) sessionKey = ScriptCrypto.randomBytes(32);
		return sessionKey;
	}

	/** Wraps a secret into a self contained blob: [nonce][cipher]. */
	public static function seal(data:Bytes):Bytes {
		if (data == null) return null;
		var nonce = ScriptCrypto.randomBytes(NONCE_SIZE);
		var cipher = ChaCha20.xorBytes(keyBytes(), nonce, 1, data);
		return SecureBytes.concat(nonce, cipher);
	}

	/** Reverses seal(); the returned buffer is plaintext and has to be wiped by the caller. */
	public static function open(sealed:Bytes):Bytes {
		if (sealed == null || sealed.length <= NONCE_SIZE) return null;
		var nonce = sealed.sub(0, NONCE_SIZE);
		var cipher = sealed.sub(NONCE_SIZE, sealed.length - NONCE_SIZE);
		var plain = ChaCha20.xorBytes(keyBytes(), nonce, 1, cipher);
		SecureBytes.wipe(nonce);
		SecureBytes.wipe(cipher);
		return plain;
	}

	public static function sealString(value:String):Bytes {
		if (value == null) return null;
		return seal(Bytes.ofString(value));
	}

	public static function openString(sealed:Bytes):String {
		var plain = open(sealed);
		if (plain == null) return null;
		var value = plain.toString();
		SecureBytes.wipe(plain);
		return value;
	}

	/** True when a user mode debugger is attached right now. */
	public static function hasDebugger():Bool {
		var attached = MemoryProtect.isBeingDebugged();
		if (attached) debuggerSeen = true;
		return attached;
	}

	/** True when a debugger was detected at any point during this session. */
	public static function wasDebugged():Bool {
		return debuggerSeen;
	}

	/** One shot process hardening, called from Main(). */
	public static function harden():Void {
		if (hardened) return;
		hardened = true;
		#if windows
		MemoryProtect.hideThreadFromDebugger();
		if (hasDebugger()) Logs.warn("[MemoryGuard] Debugger detected: decrypted scripts are visible to it.");
		#end
	}

	public static function wipe(data:Bytes):Void {
		SecureBytes.wipe(data);
	}
}
