package funkin.backend.scripting;

import hscript.*;
import hscript.Expr.Error;
import hscript.Parser;
import openfl.Assets;
import haxe.io.Path;
import funkin.backend.scripting.bytecode.Chunk;
import funkin.backend.scripting.bytecode.OpMap;
import funkin.backend.scripting.bytecode.ScriptContainer;
import funkin.backend.scripting.bytecode.VM;
import funkin.backend.scripting.crypto.ScriptCrypto;

class HScript extends Script {
	public var interp:Interp;
	public var parser:Parser;
	public var expr:Expr;
	public var code:String = null;
	/** Bytecode payload, set while reading a protected .hxb script (null for plain scripts). */
	public var bytecode:Chunk = null;
	/** Opcode permutation belonging to [bytecode]; null means the chunk uses real opcodes. */
	public var opMap:OpMap = null;
	/** Interpreter used while running [bytecode]. */
	public var vm:VM = null;
	/** Layer flags of the container this script came from; 0 for plain scripts. */
	public var containerFlags:Int = 0;
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

		try {
			if(Assets.exists(rawPath)) {
				if(Path.extension(rawPath).toLowerCase() == ScriptContainer.EXTENSION) {
					// Protected container: the password comes from the key files / the resolved CNEK1- token.
					var packed = ScriptContainer.unpack(Assets.getBytes(rawPath), null, fileName);
					code = packed.source;
					containerFlags = packed.flags;
					bytecode = packed.chunk;
					opMap = packed.map;
				} else code = Assets.getText(rawPath);
			}
		} catch(e) Logs.error('Error while reading $path: ${Std.string(e)}');

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
		// Bytecode scripts are not parsed: the source is only kept as a VM fallback.
		if (bytecode == null) loadFromString(code);
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
		// A module shipped inside an encrypted mod is named "name_protected.hxb"; without this
		// the import of such a module fails and the whole addon/mod script silently dies.
		for(suffix in ["", ScriptCrypto.PROTECTED_SUFFIX])
		for(hxExt in ["hx", "hscript", "hsc", "hxs", ScriptContainer.EXTENSION]) {
			var p = '$assetsPath$suffix.$hxExt';
			if (__importedPaths.exists(p))
				return true; // no need to reimport again
			if (Assets.exists(p)) {
				var code = _importSource(p);
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

	/**
	 * Source of a module that an "import" pulled in: a plain script is just its text, a
	 * protected container has to be unpacked first. Only source-mode containers can be
	 * imported (bytecode has no module-level expression to hand to the interpreter).
	 */
	private function _importSource(p:String):String {
		if (Path.extension(p).toLowerCase() != ScriptContainer.EXTENSION) return Assets.getText(p);
		try {
			var packed = ScriptContainer.unpack(Assets.getBytes(p), null, p);
			if (packed.source == null || packed.source.length == 0)
				Logs.warn('Cannot import "$p": the container holds bytecode only');
			return packed.source;
		} catch (e:Dynamic) {
			Logs.error('Error while reading $p: ${Std.string(e)}');
		}
		return null;
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
		if (bytecode != null) {
			try {
				vm = new VM(bytecode, interp, parser, opMap);
				vm.origin = fileName;
				vm.runMain();
				// the bytecode is self sufficient: drop the plaintext source so it is not kept around
				if ((containerFlags & ScriptContainer.FLAG_FALLBACK) == 0) code = null;
				call("new", []);
			} catch(e:Dynamic) {
				Logs.error('Bytecode failed in $fileName: ${Std.string(e)}');
				vm = null;
				// the container may still carry the source, which is the point of the fallback layer
				if (code != null && code.length > 0) loadFromString(code);
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
		vm = null;
		bytecode = null;
		opMap = null;
		super.destroy();
	}
}
