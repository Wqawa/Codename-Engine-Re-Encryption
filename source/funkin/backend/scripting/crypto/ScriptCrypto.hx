package funkin.backend.scripting.crypto;

import haxe.crypto.Base64;
import haxe.crypto.Hmac;
import haxe.crypto.Hmac.HashMethod;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * Key handling and crypto helpers for encrypted mod packs.
 *
 * It resolves the password/key a mod pack is protected with and provides the
 * primitives the pack container needs (iterated SHA-256 KDF, HMAC-SHA256, SHA-256,
 * random bytes, key tokens). The key defaults to a built-in constant but can be
 * overridden at runtime by placing a file named `script_key.txt` next to the
 * executable, or by calling `ScriptCrypto.setPassword()` at start up.
 *
 * What this protects against (read before relying on it):
 *   - STATIC protection only. The pack is not readable on disk, cannot be opened
 *     by an archive tool, and the HMAC-SHA256 tag detects any tampering.
 *   - NOT runtime protection. The engine has to decrypt the pack to load it, so
 *     the files are readable in the cache folder while the game runs.
 *   - DEFAULT_PASSWORD is compiled into the executable, so anyone with the engine
 *     and a disassembler can read it. It stops casual browsing and nothing more;
 *     ship a real key with script_key.txt or setPassword().
 *
 * KDF note: deriveKeys() is a custom iterated SHA-256 construction, not PBKDF2 or
 * Argon2, and it has not been cryptographically audited. It is fine for keeping
 * scripts unreadable to casual users; switch to a standard KDF if the key has to
 * resist offline brute force.
 */
class ScriptCrypto {
	/** Nonce size of the counter based DRBG that randomBytes() uses. */
	static inline var NONCE_SIZE:Int = 12;
	static inline var KDF_ROUNDS:Int = 2048;
	static inline var DEFAULT_PASSWORD:String = "CNE::script::v1::d0nt_t0uch_th3_sky";

	/** Set by setPassword(); overrides every key file. */
	public static var password:String = null;

	/** Single key read from a key file that has no "name = key" lines. */
	static var singleKey:String = null;
	/** Per-script keys read from the "name = key" lines ("*" = fallback). */
	static var scriptKeys:Map<String, String> = null;
	static var keyFilesLoaded:Bool = false;

	static var KEY_FILE_CANDIDATES:Array<String> = ["script_key.txt", "./script_key.txt", "assets/data/script_key.txt"];

	/**
	 * Extra key files the engine registers at runtime (a mod's own data folder,
	 * a portable install layout, ...). They are searched after the defaults, so a
	 * mod can override the key of a single script without touching the engine one.
	 */
	static var extraKeyPaths:Array<String> = [];

	/**
	 * Signature (path + mtime + size) of the key files seen last time. Editing,
	 * adding or deleting a key file changes it, which makes the keys reload
	 * without restarting the game.
	 */
	static var keySnapshot:String = null;

	/** Seconds between two stats of the key files; keeps getPassword() cheap. */
	static inline var RESCAN_INTERVAL:Float = 0.35;
	static var lastScan:Float = -1;

	/**
	 * Resolves the key used for one script. Lookup order:
	 *   1. setPassword() override
	 *   2. the "name = key" entry of script_key.txt matching `scriptName`
	 *      (full path, file name, or the name without its extension)
	 *   3. the "*" (or "default") entry of that mapping
	 *   4. the whole content of script_key.txt, when the file is a single key
	 *   5. DEFAULT_PASSWORD
	 */
	public static function getPassword(?scriptName:String):String {
		if (password != null) return resolveKeyValue(password);
		refreshKeys();
		if (scriptKeys != null) {
			var mapped = resolveKeyValue(findScriptKey(scriptName));
			if (mapped != null) return mapped;
		}
		if (singleKey != null) return resolveKeyValue(singleKey);
		return DEFAULT_PASSWORD;
	}

	// ------------------------------------------------------------- key tokens

	/**
	 * A "key token" is a password that has been turned into a different short
	 * piece of text that can be turned back into the same password. Publishers
	 * hand out the token, players paste it into the key prompt, and the original
	 * password is only reassembled in memory. It is obfuscation, not new
	 * cryptography: anyone with the engine can reverse a token.
	 */
	public static inline var TOKEN_PREFIX:String = "CNEK1-";

	public static function isKeyToken(value:String):Bool {
		if (value == null) return false;
		return StringTools.startsWith(StringTools.trim(value), TOKEN_PREFIX);
	}

	/** Turns a key into its printable token (reverse with decodeKeyToken). */
	public static function encodeKeyToken(key:String):String {
		if (key == null) return null;
		return TOKEN_PREFIX + Base64.urlEncode(xorKeyToken(Bytes.ofString(key)), false);
	}

	/** Turns a token back into the key; returns null when the token is broken. */
	public static function decodeKeyToken(token:String):String {
		if (token == null) return null;
		var t = StringTools.trim(token);
		if (!StringTools.startsWith(t, TOKEN_PREFIX)) return null;
		try {
			var data = Base64.urlDecode(t.substr(TOKEN_PREFIX.length), false);
			if (data == null) return null;
			return xorKeyToken(data).toString();
		} catch (e:Dynamic) {
			return null;
		}
	}

	/** Resolves a token to its key, leaving normal keys untouched. */
	public static function resolveKeyValue(value:String):String {
		if (value == null) return null;
		if (!isKeyToken(value)) return value;
		var decoded = decodeKeyToken(value);
		return decoded == null ? value : decoded;
	}

	/** XOR with a stream derived from a fixed token key, so tokens are not plain Base64. */
	static function xorKeyToken(data:Bytes):Bytes {
		var salt = Bytes.ofString("CNE-Key-Token-V1");
		var keys = deriveKeys("CNE::key::token::stream", salt);
		var nonce = Bytes.ofString("CNEKEYTOKEN1");
		return ChaCha20.xorBytes(keys.enc, nonce, 1, data);
	}

	/** True when the resolved key is not the built-in one. */
	public static function hasCustomKey(?scriptName:String):Bool {
		return getPassword(scriptName) != DEFAULT_PASSWORD;
	}

	/** Human readable description of where the current keys come from (editor UI). */
	public static function keyFileSummary():String {
		if (password != null) return "using the password set by ScriptCrypto.setPassword()";
		refreshKeys();
		var count = 0;
		if (scriptKeys != null)
			for (_ in scriptKeys.keys()) count++;
		if (count > 0) return count + " per-script key(s) from script_key.txt";
		if (singleKey != null) return "single key from script_key.txt";
		return "no script_key.txt found, using the built-in key";
	}

	/** Forget every cached key, so an edited key file is picked up again. */
	public static function reloadKeys():Void {
		password = null;
		singleKey = null;
		scriptKeys = null;
		keyFilesLoaded = false;
		keySnapshot = null;
		lastScan = -1;
	}

	public static function setPassword(p:String):Void {
		password = p;
	}

	/** Adds a key file to search (the engine calls this for mod data folders). */
	public static function addKeyFile(path:String):Void {
		if (path == null || path.length == 0) return;
		for (existing in extraKeyPaths) if (existing == path) return;
		extraKeyPaths.push(path);
		keySnapshot = null; // force a rescan on the next lookup
	}

	/**
	 * Re-checks the key files and reparses them when they changed. Called on every
	 * key lookup, but the stat pass itself is throttled to RESCAN_INTERVAL so it
	 * stays cheap; an edited or newly added script_key.txt is picked up within a
	 * fraction of a second, no restart needed.
	 */
	public static function refreshKeys():Void {
		#if sys
		var now = Sys.time();
		if (lastScan >= 0 && now - lastScan < RESCAN_INTERVAL) return;
		lastScan = now;
		var snapshot = buildKeySnapshot();
		if (keyFilesLoaded && snapshot == keySnapshot) return;
		keySnapshot = snapshot;
		parseAllKeyFiles();
		#else
		loadKeyFiles();
		#end
	}

	/** Every place a script_key.txt may live, defaults first, mod folders last. */
	static function candidatePaths():Array<String> {
		var list:Array<String> = KEY_FILE_CANDIDATES.copy();
		for (path in extraKeyPaths) list.push(path);
		#if sys
		for (root in ["./mods/", "./addons/"]) {
			try {
				if (!sys.FileSystem.exists(root) || !sys.FileSystem.isDirectory(root)) continue;
				for (dir in sys.FileSystem.readDirectory(root)) {
					var base = root + dir + "/";
					if (!sys.FileSystem.isDirectory(base)) continue;
					// "data/script_key.txt" mirrors the mod asset layout; the flat one
					// is what most packs have used so far.
					list.push(base + "data/script_key.txt");
					list.push(base + "script_key.txt");
				}
			} catch (e:Dynamic) {}
		}
		#end
		return list;
	}

	static function buildKeySnapshot():String {
		#if sys
		var parts:Array<String> = [];
		for (path in candidatePaths()) {
			try {
				if (!sys.FileSystem.exists(path) || sys.FileSystem.isDirectory(path)) continue;
				var stat = sys.FileSystem.stat(path);
				parts.push(path + ":" + stat.mtime + ":" + stat.size);
			} catch (e:Dynamic) {}
		}
		return parts.join("|");
		#else
		return null;
		#end
	}

	/**
	 * Reparses every key file that exists. Mapping lines merge, later files winning,
	 * and a file that is a single key overrides the single key of an earlier one -
	 * so "engine key file + mod key file" behaves like the mod extends the engine.
	 */
	static function parseAllKeyFiles():Void {
		keyFilesLoaded = true;
		singleKey = null;
		scriptKeys = null;
		#if sys
		for (path in candidatePaths()) {
			try {
				if (!sys.FileSystem.exists(path) || sys.FileSystem.isDirectory(path)) continue;
				var content = sys.io.File.getContent(path);
				if (content == null || StringTools.trim(content).length == 0) continue;
				parseKeyFile(content);
			} catch (e:Dynamic) {}
		}
		#end
	}

	/** Kept for older callers: makes sure the keys are loaded at least once. */
	static function loadKeyFiles():Void {
		if (!keyFilesLoaded) refreshKeys();
	}

	/**
	 * Two formats are accepted:
	 *   - the whole file is one key (classic behaviour)
	 *   - one "name = key" per line, where name may be a file name, a name
	 *     without its extension, a path inside the mod folder, or "*" for the
	 *     fallback key. Lines starting with # or // are comments.
	 */
	static function parseKeyFile(content:String):Void {
		var lines = content.split("\n");
		var hasMapping = false;
		for (line in lines) {
			var t = StringTools.trim(line);
			if (t.length == 0 || StringTools.startsWith(t, "#") || StringTools.startsWith(t, "//")) continue;
			if (t.indexOf("=") > 0) {
				hasMapping = true;
				break;
			}
		}

		if (!hasMapping) {
			var single = StringTools.trim(content);
			if (single.length > 0) singleKey = single;
			return;
		}

		var map = scriptKeys != null ? scriptKeys : new Map<String, String>();
		for (line in lines) {
			var t = StringTools.trim(line);
			if (t.length == 0 || StringTools.startsWith(t, "#") || StringTools.startsWith(t, "//")) continue;
			var i = t.indexOf("=");
			if (i <= 0) continue;
			var name = StringTools.trim(t.substr(0, i));
			var key = StringTools.trim(t.substr(i + 1));
			if (name.length == 0 || key.length == 0) continue;
			map.set(normalizeKeyName(name), key);
		}
		if (map.keys().hasNext()) scriptKeys = map;
	}

	static function findScriptKey(scriptName:String):String {
		var map = scriptKeys;
		if (map == null) return null;

		if (scriptName != null && scriptName.length > 0) {
			var full = normalizeKeyName(scriptName);
			var slash = full.lastIndexOf("/");
			var base = slash >= 0 ? full.substr(slash + 1) : full;
			var dot = base.lastIndexOf(".");
			var stem = dot > 0 ? base.substr(0, dot) : base;

			var candidates = [full, base, stem, stem + ".hx", stem + ".hxb", stem + ".hscript"];
			// "_encrypted" / "_decrypted" copies made by the editor still map to the
			// key of the script they came from.
			for (suffix in ["_encrypted", "_decrypted"]) {
				if (StringTools.endsWith(stem, suffix)) {
					var bare = stem.substr(0, stem.length - suffix.length);
					candidates.push(bare);
					candidates.push(bare + ".hx");
					candidates.push(bare + ".hxb");
				}
			}

			for (c in candidates) {
				var v = map.get(c);
				if (v != null) return v;
			}

			// Keys written as a mod-relative path, e.g. "songs/test/scripts/camfollow.hxb".
			for (key in map.keys()) {
				if (key.indexOf("/") < 0 && key != "*" && key != "default") continue;
				if (key == "*" || key == "default") continue;
				if (StringTools.endsWith(full, "/" + key) || StringTools.endsWith(full, "/" + key + ".hxb") || StringTools.endsWith(full, "/" + key + ".hx"))
					return map.get(key);
			}
		}

		var fallback = map.get("*");
		if (fallback == null) fallback = map.get("default");
		return fallback;
	}

	static function normalizeKeyName(name:String):String {
		if (name == null) return "";
		return StringTools.replace(StringTools.trim(name.toLowerCase()), "\\", "/");
	}

	public static function sha256(data:Bytes):Bytes {
		return Sha256.make(data);
	}

	public static function concat(a:Bytes, b:Bytes):Bytes {
		// Allocation + two native blits; this sits in the 2048 round KDF loop, so
		// avoiding the BytesBuffer wrapper measurably shortens every unlock.
		var out = Bytes.alloc(a.length + b.length);
		out.blit(0, a, 0, a.length);
		out.blit(a.length, b, 0, b.length);
		return out;
	}

	/**
	 * Random bytes for salts and nonces.
	 *
	 * Preferred source is the OS entropy pool (/dev/urandom). Windows has no
	 * portable equivalent in plain Haxe, and neither do HTML5 targets, so those use
	 * a ChaCha20 DRBG seeded once from several independent time / environment /
	 * Std.random sources. Salts and nonces do not need to be secret, only
	 * unpredictable, which both paths provide.
	 */
	public static function randomBytes(n:Int):Bytes {
		var out = Bytes.alloc(n);
		#if sys
		if (readOsEntropy(out)) return out;
		#end
		fillFromDrbg(out);
		return out;
	}

	#if sys
	/** Fills `out` from the OS entropy source; false when this platform has none. */
	static function readOsEntropy(out:Bytes):Bool {
		if (Sys.systemName() == "Windows") return false;
		var handle = null;
		try {
			handle = sys.io.File.read("/dev/urandom", true);
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

	static var drbgKey:Bytes = null;
	static var drbgNonce:Bytes = null;
	static var drbgCounter:Int = 0;

	/** ChaCha20 keystream with a counter nonce, so every call gets fresh bytes. */
	static function fillFromDrbg(out:Bytes):Void {
		if (drbgKey == null) {
			drbgKey = seedDrbg();
			drbgNonce = Bytes.alloc(NONCE_SIZE);
		}
		drbgCounter++;
		drbgNonce.set(0, drbgCounter & 0xFF);
		drbgNonce.set(1, (drbgCounter >>> 8) & 0xFF);
		drbgNonce.set(2, (drbgCounter >>> 16) & 0xFF);
		drbgNonce.set(3, (drbgCounter >>> 24) & 0xFF);
		var stream = ChaCha20.xorBytes(drbgKey, drbgNonce, 1, Bytes.alloc(out.length));
		out.blit(0, stream, 0, out.length);
	}

	/** Mixes unrelated entropy sources into a 32 byte DRBG seed. */
	static function seedDrbg():Bytes {
		var parts:Array<String> = [];
		parts.push(Std.string(Date.now().getTime()));
		#if sys
		parts.push(Std.string(Sys.time()));
		parts.push(Std.string(Sys.cpuTime()));
		parts.push(Std.string(Sys.getEnv("COMPUTERNAME")) + Std.string(Sys.getEnv("USERNAME")));
		parts.push(Std.string(Sys.getEnv("PROCESSOR_IDENTIFIER")));
		parts.push(Std.string(Sys.programPath));
		#end
		var i = 0;
		while (i < 32) {
			parts.push(Std.string(Math.random()) + ":" + Std.string(Std.random(0x7FFFFFFF)));
			i++;
		}
		var h = sha256(Bytes.ofString(parts.join("|")));
		i = 0;
		while (i < 64) {
			h = sha256(concat(h, Bytes.ofString(parts[i % parts.length] + "#" + i)));
			i++;
		}
		return h;
	}

	public static function deriveKeys(pass:String, salt:Bytes):{enc:Bytes, mac:Bytes} {
		var h = sha256(Bytes.ofString(pass + "|" + salt.toHex()));
		for (i in 0...KDF_ROUNDS)
			h = sha256(concat(h, salt));
		return {
			enc: sha256(concat(h, Bytes.ofString("cne-enc"))),
			mac: sha256(concat(h, Bytes.ofString("cne-mac")))
		};
	}

	public static function hmacTag(macKey:Bytes, data:Bytes):Bytes {
		return new Hmac(SHA256).make(macKey, data);
	}

}
