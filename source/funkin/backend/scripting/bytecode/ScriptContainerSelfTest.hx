package funkin.backend.scripting.bytecode;

import funkin.backend.scripting.HScript;
import haxe.io.Bytes;
import hscript.Interp;
#if sys
import sys.io.File;
#end

/**
 * Round-trip check for the CNX2 script container (ScriptContainer) and for the
 * bytecode compiler/VM pair behind it.
 *
 * It is meant to be run on a real build, because the container, the crypto and
 * the VM only exist inside the engine:
 *
 *   CodenameEngine.exe --cne-selftest
 *
 * writes logs/container-selftest.log and closes the game again. The editor also
 * offers it under Tools -> "Self test: script container", which puts the same
 * summary on screen. Nothing here ships in a normal play session unless the
 * flag or the menu entry is used.
 */
class ScriptContainerSelfTest {
	public static inline var FLAG:String = "--cne-selftest";
	public static inline var LOG_PATH:String = "logs/container-selftest.log";

	static var passed:Int = 0;
	static var failed:Int = 0;
	static var lines:Array<String> = [];

	/** Sample script: variables, a function, loops, a condition and a trace. */
	public static var SOURCE:String = [
		"var result = 0;",
		"function add(a, b) return a + b;",
		"for (i in 0...5) result = add(result, i);",
		"var text = 'done';",
		"if (result == 10) text = 'correct';"
	].join("\n");

	/** Runs the whole suite and returns a one line summary, e.g. "24 passed, 0 failed". */
	public static function run():String {
		passed = 0;
		failed = 0;
		lines = [];

		for (useVM in [false, true]) {
			var fallbacks:Array<Bool> = useVM ? [false, true] : [false];
			for (fallback in fallbacks) {
				for (key in [false, true]) {
					for (offset in [false, true]) {
						for (split in [false, true]) {
							var label = (useVM ? (fallback ? "vm+fallback" : "vm") : "source")
								+ (key ? " key" : " raw")
								+ (offset ? " offset" : "")
								+ (split ? " split" : "");
							try {
								roundTrip(useVM, fallback, key, offset, split, label);
							} catch (e:Dynamic) {
								fail(label, "threw " + Std.string(e));
							}
						}
					}
				}
			}
		}

		try {
			vmRuns();
		} catch (e:Dynamic) {
			fail("vm execution", "threw " + Std.string(e));
		}
		try {
			rejections();
		} catch (e:Dynamic) {
			fail("rejections", "threw " + Std.string(e));
		}

		var summary = passed + " passed, " + failed + " failed";
		lines.push(summary);
		return summary;
	}

	/** True when this process was started with the self test flag. */
	public static function runIfRequested():Bool {
		#if sys
		if (Sys.args().indexOf(FLAG) < 0) return false;
		var summary = run();
		// the log folder is not guaranteed to exist, and CoolUtil creates it
		funkin.backend.utils.CoolUtil.safeSaveFile(LOG_PATH, lines.join("\n") + "\n", false);
		for (line in lines) Sys.println(line);
		return true;
		#else
		return false;
		#end
	}

	/** Full detail of the last run, for the editor status line. */
	public static function getLines():Array<String> return lines;

	// ------------------------------------------------------------------- checks

	static function roundTrip(useVM:Bool, fallback:Bool, key:Bool, offset:Bool, split:Bool, label:String) {
		var opts:ScriptContainer.PackOptions = {
			useKey: key,
			useVM: useVM,
			fallbackSource: fallback,
			useOffset: offset,
			offsetBits: 8,
			useSplit: split,
			splitCount: 4,
			pass: key ? "selftest-passphrase" : null,
			scriptName: "selftest.hx"
		};

		var packed = ScriptContainer.pack(SOURCE, "selftest.hx", opts);
		if (!ScriptContainer.isContainer(packed)) {
			fail(label, "packed data is not a container");
			return;
		}

		var back = ScriptContainer.unpack(packed, key ? "selftest-passphrase" : null, "selftest.hx");

		if (useVM) {
			if (back.chunk == null) {
				fail(label, "no chunk came back");
				return;
			}
			if (back.mode != ScriptContainer.MODE_BYTECODE) {
				fail(label, "mode is not bytecode");
				return;
			}
			// recompile with the seed stored in the header: same seed, same chunk
			var map = new OpMap(back.opcodeSeed);
			var recompiled = Compiler.compile(HScript.initParser(), SOURCE, "selftest.hx", map);
			var a = back.chunk.serialize(), b = recompiled.serialize();
			if (a.length != b.length) {
				fail(label, "chunk length " + a.length + " instead of " + b.length);
				return;
			}
			for (i in 0...a.length)
				if (a.get(i) != b.get(i)) {
					fail(label, "chunk differs at byte " + i);
					return;
				}
			if (fallback) {
				if (back.source != SOURCE) {
					fail(label, "fallback source differs");
					return;
				}
			} else if (back.source != null) {
				fail(label, "source kept although there is no fallback");
				return;
			}
		} else {
			if (back.chunk != null) {
				fail(label, "unexpected bytecode");
				return;
			}
			if (back.source != SOURCE) {
				fail(label, "source differs");
				return;
			}
		}

		if (key != ((back.flags & ScriptContainer.FLAG_KEY) != 0)) {
			fail(label, "FLAG_KEY does not match");
			return;
		}
		if (useVM != ((back.flags & ScriptContainer.FLAG_VM) != 0)) {
			fail(label, "FLAG_VM does not match");
			return;
		}
		if (fallback != ((back.flags & ScriptContainer.FLAG_FALLBACK) != 0)) {
			fail(label, "FLAG_FALLBACK does not match");
			return;
		}
		if (offset != ((back.flags & ScriptContainer.FLAG_OFFSET) != 0)) {
			fail(label, "FLAG_OFFSET does not match");
			return;
		}
		if (split != ((back.flags & ScriptContainer.FLAG_SPLIT) != 0)) {
			fail(label, "FLAG_SPLIT does not match");
			return;
		}

		// salt, nonce and the header tail are random: two packs must differ
		var again = ScriptContainer.pack(SOURCE, "selftest.hx", opts);
		var same = again.length == packed.length;
		if (same) for (i in 0...packed.length)
			if (packed.get(i) != again.get(i)) {
				same = false;
				break;
			}
		if (same) {
			fail(label, "two packs of the same script are byte identical");
			return;
		}

		pass(label);
	}

	/** The bytecode, once unwrapped from the container, has to run and to give the same answer. */
	static function vmRuns() {
		var packed = ScriptContainer.pack(SOURCE, "selftest.hx", {useVM: true, useKey: true, pass: "selftest-passphrase", useOffset: true, useSplit: true});
		var back = ScriptContainer.unpack(packed, "selftest-passphrase", "selftest.hx");
		if (back.chunk == null) {
			fail("vm execution", "no bytecode came back");
			return;
		}

		var interp = new Interp();
		var parser = HScript.initParser();
		var vm = new VM(back.chunk, interp, parser, back.map);
		vm.origin = "selftest.hx";
		vm.runMain();

		if (interp.variables.get("result") != 10) {
			fail("vm execution", "result is " + Std.string(interp.variables.get("result")) + " instead of 10");
			return;
		}
		if (interp.variables.get("text") != "correct") {
			fail("vm execution", "text is " + Std.string(interp.variables.get("text")) + " instead of correct");
			return;
		}
		pass("vm execution");
	}

	/** A damaged or wrongly keyed container must be refused, not silently decoded. */
	static function rejections() {
		// no SPLIT here: the padding between the pieces is random filler the reader is
		// meant to skip, so flipping a byte there is not supposed to be detected
		var opts:ScriptContainer.PackOptions = {useKey: true, pass: "selftest-passphrase"};
		var packed = ScriptContainer.pack(SOURCE, "selftest.hx", opts);

		var flipped = packed.sub(0, packed.length);
		flipped.set(ScriptContainer.HEADER_SIZE + 5, flipped.get(ScriptContainer.HEADER_SIZE + 5) ^ 0xFF);
		expectFailure("tampered body", function() return ScriptContainer.unpack(flipped, "selftest-passphrase"));

		var rotated = ScriptContainer.pack(SOURCE, "selftest.hx", {useKey: true, pass: "selftest-passphrase", useOffset: true, offsetBits: 8});
		var rotatedFlipped = rotated.sub(0, rotated.length);
		rotatedFlipped.set(ScriptContainer.HEADER_SIZE + 7, rotatedFlipped.get(ScriptContainer.HEADER_SIZE + 7) ^ 0xFF);
		expectFailure("tampered rotated body", function() return ScriptContainer.unpack(rotatedFlipped, "selftest-passphrase"));
		expectFailure("wrong passphrase", function() return ScriptContainer.unpack(packed, "not-the-passphrase"));
		expectFailure("not a container", function() return ScriptContainer.unpack(Bytes.ofString("this is a plain text file, not a CNX2 container at all")));

		var raw = ScriptContainer.pack(SOURCE, "selftest.hx", {});
		var rawFlipped = raw.sub(0, raw.length);
		rawFlipped.set(ScriptContainer.HEADER_SIZE + 1, rawFlipped.get(ScriptContainer.HEADER_SIZE + 1) ^ 0xFF);
		expectFailure("tampered raw body", function() return ScriptContainer.unpack(rawFlipped));

		var described = ScriptContainer.describe(packed);
		if (described.indexOf("CNX2") < 0 || described.indexOf("key") < 0) fail("describe", "unexpected text: " + described);
		else pass("describe");
	}

	static function expectFailure(label:String, run:Void->Dynamic) {
		try {
			run();
		} catch (e:Dynamic) {
			pass(label);
			return;
		}
		fail(label, "no error was raised");
	}

	static function pass(label:String) {
		passed++;
		lines.push("PASS " + label);
	}

	static function fail(label:String, reason:String) {
		failed++;
		lines.push("FAIL " + label + ": " + reason);
	}
}
