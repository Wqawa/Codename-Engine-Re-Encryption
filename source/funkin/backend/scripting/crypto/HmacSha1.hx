package funkin.backend.scripting.crypto;

import haxe.io.Bytes;

/** HMAC-SHA1 that can be fed in chunks and never buffers the whole message. */
class HmacSha1 {
	static inline var BLOCK:Int = 64;

	var innerPad:Bytes;
	var outerPad:Bytes;

	public function new(key:Bytes) {
		var k = key == null ? Bytes.alloc(0) : key;
		if (k.length > BLOCK) {
			k = Sha1Stream.make(k);
		}
		var pad = Bytes.alloc(BLOCK);
		for (i in 0...k.length) pad.set(i, k.get(i));

		innerPad = Bytes.alloc(BLOCK);
		outerPad = Bytes.alloc(BLOCK);
		for (i in 0...BLOCK) {
			innerPad.set(i, pad.get(i) ^ 0x36);
			outerPad.set(i, pad.get(i) ^ 0x5C);
		}
	}

	/** Starts hashing the message; feed this stream with the payload chunks. */
	public function start():Sha1Stream
		return new Sha1Stream().update(innerPad);

	public function finish(inner:Sha1Stream):Bytes {
		var innerDigest = inner.digest();
		var outer = new Sha1Stream().update(outerPad).update(innerDigest);
		return outer.digest();
	}

	public function make(msg:Bytes):Bytes
		return finish(start().update(msg));

	public static function hash(key:Bytes, msg:Bytes):Bytes
		return new HmacSha1(key).make(msg);
}
