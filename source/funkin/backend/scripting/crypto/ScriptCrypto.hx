package funkin.backend.scripting.crypto;

import haxe.crypto.Base64;
import haxe.crypto.Hmac;
import haxe.crypto.Hmac.HashMethod;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * Encrypted script container shared by the packer (editor) and the runtime.
 *
 * Layout (little endian):
 *   0..3    magic "CNES"
 *   4       format version (1)
 *   5       payload mode (0 = plain source text, 1 = bytecode chunk)
 *   6..7    reserved
 *   8..23   random salt (16)
 *   24..35  random nonce (12)
 *   36..39  ciphertext length
 *   40..    ChaCha20 ciphertext
 *   ...     HMAC-SHA256 over everything above (32 bytes)
 *
 * Keys are derived from a password with an iterated SHA-256 KDF. The password
 * defaults to a built-in constant but can be overridden at runtime by placing
 * a file named `script_key.txt` next to the executable, or by calling
 * `ScriptCrypto.setPassword()` before scripts are loaded.
 *
 * What this protects against (read before relying on it):
 *   - STATIC protection only. The script is not plain text on disk, cannot be
 *     edited by accident, and the HMAC-SHA256 tag detects any tampering.
 *   - NOT runtime protection. The engine must execute the script, so in memory it
 *     is plain again and can be dumped from the process.
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
	public static var MAGIC:Array<Int> = [0x43, 0x4E, 0x45, 0x53]; // "CNES"
	public static inline var VERSION:Int = 1;
	public static inline var MODE_SOURCE:Int = 0;
	public static inline var MODE_BYTECODE:Int = 1;
	/**
	 * Bytecode followed by an encrypted copy of the original source. The VM runs
	 * the bytecode; the source is only used when the VM cannot execute the script,
	 * so an encrypted script can never lose behaviour it had as plain text.
	 */
	public static inline var MODE_BOTH:Int = 2;

	static inline var HEADER_SIZE:Int = 40;
	static inline var TAG_SIZE:Int = 32;
	static inline var SALT_SIZE:Int = 16;
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
		loadKeyFiles();
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
		loadKeyFiles();
		if (scriptKeys != null) {
			var count = 0;
			for (_ in scriptKeys.keys()) count++;
			if (count > 0) return count + " per-script key(s) from script_key.txt";
		}
		if (singleKey != null) return "single key from script_key.txt";
		return "no script_key.txt found, using the built-in key";
	}

	/** Forget every cached key, so an edited key file is picked up again. */
	public static function reloadKeys():Void {
		password = null;
		singleKey = null;
		scriptKeys = null;
		keyFilesLoaded = false;
	}

	public static function setPassword(p:String):Void {
		password = p;
	}

	static function loadKeyFiles():Void {
		if (keyFilesLoaded) return;
		keyFilesLoaded = true;
		#if sys
		for (path in KEY_FILE_CANDIDATES) {
			try {
				if (!sys.FileSystem.exists(path) || sys.FileSystem.isDirectory(path)) continue;
				var content = sys.io.File.getContent(path);
				if (content == null) continue;
				parseKeyFile(content);
				if (singleKey != null || scriptKeys != null) return;
			} catch (e:Dynamic) {}
		}
		#end
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

		var map = new Map<String, String>();
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
		var buf = new BytesBuffer();
		buf.add(a);
		buf.add(b);
		return buf.getBytes();
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

	public static function isContainer(data:Bytes):Bool {
		if (data == null || data.length < HEADER_SIZE + TAG_SIZE) return false;
		for (i in 0...4)
			if (data.get(i) != MAGIC[i]) return false;
		return true;
	}

	public static function pack(payload:Bytes, mode:Int, ?pass:String, ?scriptName:String):Bytes {
		if (pass == null) pass = getPassword(scriptName);
		var salt = randomBytes(SALT_SIZE);
		var nonce = randomBytes(NONCE_SIZE);
		var keys = deriveKeys(pass, salt);
		var cipher = ChaCha20.xorBytes(keys.enc, nonce, 1, payload);

		var buf = new BytesBuffer();
		for (v in MAGIC) buf.addByte(v);
		buf.addByte(VERSION);
		buf.addByte(mode);
		buf.addByte(0);
		buf.addByte(0);
		buf.add(salt);
		buf.add(nonce);
		var len = cipher.length;
		buf.addByte(len & 0xFF);
		buf.addByte((len >>> 8) & 0xFF);
		buf.addByte((len >>> 16) & 0xFF);
		buf.addByte((len >>> 24) & 0xFF);
		buf.add(cipher);
		var body = buf.getBytes();

		var tag = hmacTag(keys.mac, body);
		var out = new BytesBuffer();
		out.add(body);
		out.add(tag);
		return out.getBytes();
	}

	public static function unpack(data:Bytes, ?pass:String, ?scriptName:String):{mode:Int, payload:Bytes} {
		if (pass == null) pass = getPassword(scriptName);
		if (!isContainer(data))
			throw "ScriptCrypto: not an encrypted script container";
		if (data.get(4) != VERSION)
			throw 'ScriptCrypto: unsupported container version ' + data.get(4);

		var salt = Bytes.alloc(SALT_SIZE);
		for (i in 0...SALT_SIZE) salt.set(i, data.get(8 + i));
		var nonce = Bytes.alloc(NONCE_SIZE);
		for (i in 0...NONCE_SIZE) nonce.set(i, data.get(24 + i));

		var len = data.get(36) | (data.get(37) << 8) | (data.get(38) << 16) | (data.get(39) << 24);
		if (len < 0 || HEADER_SIZE + len + TAG_SIZE != data.length)
			throw "ScriptCrypto: corrupted container (bad length)";

		var body = Bytes.alloc(HEADER_SIZE + len);
		for (i in 0...(HEADER_SIZE + len)) body.set(i, data.get(i));
		var tagBytes = Bytes.alloc(TAG_SIZE);
		for (i in 0...TAG_SIZE) tagBytes.set(i, data.get(HEADER_SIZE + len + i));

		var keys = deriveKeys(pass, salt);
		var expected = hmacTag(keys.mac, body);
		if (!constantTimeEquals(expected, tagBytes))
			throw "ScriptCrypto: integrity check failed (wrong key or corrupted file)";

		var cipher = Bytes.alloc(len);
		for (i in 0...len) cipher.set(i, data.get(HEADER_SIZE + i));
		return {
			mode: data.get(5),
			payload: ChaCha20.xorBytes(keys.enc, nonce, 1, cipher)
		};
	}

	static function constantTimeEquals(a:Bytes, b:Bytes):Bool {
		if (a.length != b.length) return false;
		var diff = 0;
		for (i in 0...a.length) diff |= a.get(i) ^ b.get(i);
		return diff == 0;
	}
}
