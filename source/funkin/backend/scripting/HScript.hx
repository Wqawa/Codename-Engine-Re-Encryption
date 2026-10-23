package funkin.backend.scripting;

import funkin.backend.scripting.bytecode.Chunk;
import funkin.backend.scripting.bytecode.ScriptPackager;
import funkin.backend.scripting.bytecode.VM;
import funkin.backend.scripting.crypto.ScriptCrypto;
import haxe.io.Bytes;
import hscript.*;
import hscript.Expr.Error;
import hscript.Parser;
import openfl.Assets;

class HScript extends Script {
	public var interp:Interp;
	public var parser:Parser;
	public var expr:Expr;
	public var code:String = null;

	/**
	 * Set when the script was loaded from an encrypted CNES container.
	 */
	public var encrypted:Bool = false;
	/**
	 * Mode of the encrypted container (see ScriptCrypto.MODE_*), -1 when the script is a plain file.
	 */
	public var payloadMode:Int = -1;
	/**
	 * Bytecode chunk when the script is an encrypted bytecode script (runs on the VM), null otherwise.
	 */
	public var bytecode:Chunk = null;
	/**
	 * Virtual machine used to execute `bytecode`.
	 */
	public var vm:VM = null;
	//public var folderlessPath:String;
	var __importedPaths:Map<String, Bool>;

	public static function initParser() {
		var parser = new Parser();
		parser.allowJSON = parser.allowMetadata = parser.allowTypes = true;
		parser.preprocessorValues = Script.getDefaultPreprocessors();
		return parser;
	}

	/** Pool of idle parsers, reused across script instances to avoid repeated Parser construction. **/
	private static var __parserPool:Array<Parser> = [];

	private static function getParser():Parser {
		var parser = __parserPool.pop();
		if (parser == null)
			return initParser();
		parser.line = 1; // reusing a parser only requires resetting `line`; all other vars get reset on parse
		return parser;
	}

	private static function returnParser(parser:Parser) {
		if (parser != null)
			__parserPool.push(parser);
	}

	public override function onCreate(path:String) {
		super.onCreate(path);

		interp = new Interp();
		bytecode = null;
		vm = null;
		encrypted = false;
		payloadMode = -1;

		if(extension == ScriptPackager.EXTENSION && Assets.exists(rawPath)) {
			try {
				var data:Bytes = Assets.getBytes(rawPath);
				if(ScriptPackager.isContainer(data)) {
					// The script name lets script_key.txt pick a per-script key; the
					// keyless "CNEV" container needs no key at all.
					var packed = ScriptPackager.unpack(data, null, fileName);
					encrypted = ScriptPackager.isEncrypted(data);
					payloadMode = packed.mode;
					if(packed.mode == ScriptPackager.MODE_OBFUSCATED) {
						bytecode = packed.chunk;
					} else if(packed.mode == ScriptCrypto.MODE_BYTECODE) {
						bytecode = packed.chunk;
					} else if(packed.mode == ScriptCrypto.MODE_BOTH) {
						// Bytecode plus an encrypted copy of the source: the VM runs it,
						// the source only kicks in if the VM cannot execute the script.
						bytecode = packed.chunk;
						if(packed.source != null && packed.source.length > 0)
							code = packed.source;
					} else {
						code = packed.source;
					}
				} else {
					code = data == null ? null : data.toString();
				}
			} catch(e) {
				Logs.error('Error while decrypting $path: ${Std.string(e)}');
			}
		} else {
			try {
				if(Assets.exists(rawPath)) code = Assets.getText(rawPath);
			} catch(e) Logs.error('Error while reading $path: ${Std.string(e)}');
		}

		parser = getParser();
		//folderlessPath = Path.directory(path);
		__importedPaths = [path => true];

		interp.errorHandler = _errorHandler;
		interp.warnHandler = _warnHandler;
		interp.importFailedCallback = importFailedCallback;
		interp.staticVariables = Script.staticVariables;
		interp.allowStaticVariables = interp.allowPublicVariables = true;

		interp.variables.set("trace", Reflect.makeVarArgs((args) -> {
			var v:String = Std.string(args.shift());
			for (a in args) v += ", " + Std.string(a);
			this.trace(v);
		}));

		#if GLOBAL_SCRIPT
		funkin.backend.scripting.GlobalScript.call("onScriptCreated", [this, "hscript"]);
		#end
		loadFromString(code);
	}

	public override function loadFromString(code:String) {
		try {
			if (code != null && code.length > 0)
				expr = parser.parseString(code, fileName);
		} catch(e:Error) {
			_errorHandler(e);
		} catch(e) {
			_errorHandler(new Error(ECustom(e.toString()), 0, 0, fileName, 0));
		}

		return this;
	}

	private function importFailedCallback(cl:Array<String>, ?asName:String):Bool {
		if(_importFailedCallback(cl, "source/") || _importFailedCallback(cl, "")) {
			return true;
		}
		return false;
	}
	private function _importFailedCallback(cl:Array<String>, prefix:String):Bool {
		var assetsPath = 'assets/$prefix${cl.join("/")}';
		for(hxExt in ["hx", "hscript", "hsc", "hxs"]) {
			var p = '$assetsPath.$hxExt';
			if (__importedPaths.exists(p))
				return true; // no need to reimport again
			if (Assets.exists(p)) {
				var code = Assets.getText(p);
				var expr:Expr = null;
				try {
					if (code != null && code.length > 0) {
						parser.line = 1; // fun fact: this is all you need to reuse a parser without issues. all the other vars get reset on parse.
						expr = parser.parseString(code, cl.join("/") + "." + hxExt);
					}
				} catch(e:Error) {
					_errorHandler(e);
				} catch(e) {
					_errorHandler(new Error(ECustom(e.toString()), 0, 0, fileName, 0));
				}
				if (expr != null) {
					@:privateAccess
					interp.exprReturn(expr);
					__importedPaths.set(p, true);
				}
				return true;
			}
		}
		return false;
	}

	private function _errorHandler(error:Error) {
		var fileName = error.origin;
		var oldfn = '$fileName:${error.line}: ';
		if(remappedNames.exists(fileName))
			fileName = remappedNames.get(fileName);
		var fn = '$fileName:${error.line}: ';
		var err = error.toString();
		while(err.startsWith(oldfn) || err.startsWith(fn)) {
			if (err.startsWith(oldfn)) err = err.substr(oldfn.length);
			if (err.startsWith(fn)) err = err.substr(fn.length);
		}

		Logs.traceColored([
			Logs.logText(fn, GREEN),
			Logs.logText(err, RED)
		], ERROR);
	}

	private function _warnHandler(error:Error) {
		var fileName = error.origin;
		var oldfn = '$fileName:${error.line}: ';
		if(remappedNames.exists(fileName))
			fileName = remappedNames.get(fileName);
		var fn = '$fileName:${error.line}: ';
		var err = error.toString();
		while(err.startsWith(oldfn) || err.startsWith(fn)) {
			if (err.startsWith(oldfn)) err = err.substr(oldfn.length);
			if (err.startsWith(fn)) err = err.substr(fn.length);
		}

		Logs.traceColored([
			Logs.logText(fn, GREEN),
			Logs.logText(err, YELLOW)
		], WARNING);
	}

	public override function setParent(parent:Dynamic) {
		interp.scriptObject = parent;
	}

	public override function onLoad() {
		@:privateAccess
		interp.execute(parser.mk(EBlock([]), 0, 0));

		if(bytecode != null) {
			try {
				vm = new VM(bytecode, interp, parser);
				// Only used to tag VM errors; the bytecode itself has no positions.
				vm.origin = fileName;
				vm.runMain();
				call("new", []);

				#if GLOBAL_SCRIPT
				funkin.backend.scripting.GlobalScript.call("onScriptSetup", [this, "hscript"]);
				#end
				return;
			} catch(e) {
				Logs.error('Error while running bytecode script $fileName: ${Std.string(e)}');
				vm = null;
				bytecode = null;
				// Never let an encrypted script behave worse than its plain text version:
				// fall back to interpreting the source stored next to the bytecode.
				if(code != null && code.trim() != "") {
					Logs.warn('Falling back to the source interpreter for $fileName');
					loadFromString(code);
				}
			}
		}

		if (expr != null) {
			interp.execute(expr);
			call("new", []);
		}

		#if GLOBAL_SCRIPT
		funkin.backend.scripting.GlobalScript.call("onScriptSetup", [this, "hscript"]);
		#end
	}

	public override function reload() {
		// save variables

		interp.allowStaticVariables = interp.allowPublicVariables = false;
		var savedVariables:Map<String, Dynamic> = [];
		var defaultVars = Script.getDefaultVariables(this);
		for(k=>e in interp.variables) {
			if (!Reflect.isFunction(e) && !defaultVars.exists(k)) {
				savedVariables[k] = e;
			}
		}
		var oldParent = interp.scriptObject;
		returnParser(parser);
		onCreate(path);

		for(k=>e in defaultVars)
			set(k, e);

		load();
		setParent(oldParent);

		for(k=>e in savedVariables)
			interp.variables.set(k, e);

		interp.allowStaticVariables = interp.allowPublicVariables = true;
	}

	private override function onCall(funcName:String, parameters:Array<Dynamic>):Dynamic {
		if (interp == null) return null;

		var func = interp.variables.get(funcName);
		if (func != null && Reflect.isFunction(func))
			return Reflect.callMethod(null, func, parameters == null ? Script._EMPTY_ARGS : parameters);

		return null;
	}

	public override function get(val:String):Dynamic {
		return interp.variables.get(val);
	}

	public override function set(val:String, value:Dynamic) {
		interp.variables.set(val, value);
		// A runtime-injected variable may shadow a previously-cached VNotFound/type-resolve result, so drop stale cache entries.
		interp.invalidateCache();
	}

	public override function trace(v:Dynamic) {
		var posInfo = interp.posInfos();
		Logs.traceColored([
			Logs.logText('${fileName}:${posInfo.lineNumber}: ', GREEN),
			Logs.logText(Std.isOfType(v, String) ? v : Std.string(v))
		], TRACE);
	}

	public override function setPublicMap(map:Map<String, Dynamic>) {
		this.interp.publicVariables = map;
	}

	override public function destroy() {
		returnParser(parser);
		parser = null;
		interp = null;
		super.destroy();
	}
}
