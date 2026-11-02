package funkin.backend.assets;

import funkin.backend.scripting.crypto.ScriptCrypto;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/** A parsed protection mark: the salt it was made with and the digest to compare. */
typedef ProtectionData = {
	var salt:Bytes;
	var hash:Bytes;
}

/**
 * The marker a protected pack carries at `data/cne_protect.dat`.
 *
 * Stores the salt and a digest of the password, never the password, so an unlock can be
 * checked after the marker is read out of the archive.
 *
 * A speed bump, not a boundary: whoever edits the marker or the exe walks past it.
 */
class ProtectionMark {
	public static inline var PATH:String = 'data/cne_protect.dat';
	static inline var HEADER:String = 'CNEZ-PROTECT 1';
	static inline var SALT_SIZE:Int = 16;

	/** Builds the file content for a password the pack author typed. */
	public static function create(pass:String):Bytes {
		if (pass == null || pass.length == 0) throw "ProtectionMark: empty password";
		var salt = ScriptCrypto.randomBytes(SALT_SIZE);
		var text = HEADER + '\nsalt ' + salt.toHex() + '\nhash ' + digest(salt, pass).toHex() + '\n';
		return Bytes.ofString(text);
	}

	/** Reads a mark back, or null when the bytes are not one. */
	public static function parse(data:Bytes):ProtectionData {
		if (data == null || data.length == 0) return null;
		var text = StringTools.trim(data.toString());
		var lines = text.split('\n');
		if (lines.length < 3 || StringTools.trim(lines[0]) != HEADER) return null;

		var salt:String = null;
		var hash:String = null;
		for (i in 1...lines.length) {
			var line = StringTools.trim(lines[i]);
			if (StringTools.startsWith(line, 'salt ')) salt = line.substr(5);
			else if (StringTools.startsWith(line, 'hash ')) hash = line.substr(5);
		}
		if (salt == null || hash == null) return null;

		try {
			return {salt: Bytes.ofHex(StringTools.trim(salt)), hash: Bytes.ofHex(StringTools.trim(hash))};
		} catch (e:Dynamic) {
			return null;
		}
	}

	/** True when `pass` is the password this mark was made from. */
	public static function matches(mark:ProtectionData, pass:String):Bool {
		if (mark == null || pass == null || pass.length == 0) return false;
		return CnezV2.same(digest(mark.salt, pass), mark.hash);
	}

	static function digest(salt:Bytes, pass:String):Bytes {
		// two rounds so a short password is not a single hash away from the salt alone
		var first = ScriptCrypto.sha256(concat(salt, Bytes.ofString('|' + pass)));
		return ScriptCrypto.sha256(concat(first, salt));
	}

	static function concat(a:Bytes, b:Bytes):Bytes {
		var out = new BytesBuffer();
		out.add(a);
		out.add(b);
		return out.getBytes();
	}
}
