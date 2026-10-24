package funkin.backend.scripting.bytecode;

import hscript.Expr;
import hscript.Expr.ExprDef;
import hscript.Interp;
import hscript.Parser;
import hscript.utils.UnsafeReflect;
import haxe.io.Bytes;

/**
 * Stack based virtual machine executing a Chunk produced by Compiler.
 *
 * The VM reuses the host Interp for name resolution and reflection so scripts
 * keep exactly the same capabilities as in interpreted mode. Locals, captures
 * and temporaries live in a per-frame array; the operand stack is separate.
 */
class VM
{
	static inline var ASSIGN_VALUE = "__cne_vm_assign_value";

	/** Optional opcode permutation; pass the same OpMap the chunk was compiled with. */
	public var opMap:OpMap;

	public var chunk:Chunk;
	public var interp:Interp;
	public var parser:Parser;

	/**
	 * Script path reported by Interp.error(). The owner (HScript) sets it right
	 * after construction; the VM only uses it to tag the placeholder expression
	 * that keeps error() from dereferencing a null curExpr.
	 */
	public var origin:String = null;

	/** Cached placeholder handed to interp.curExpr (reused, never reallocated per call). */
	var placeholder:Expr;

	var assignCache:Map<String, Expr>;

	public function new(chunk:Chunk, interp:Interp, parser:Parser, ?opMap:OpMap)
	{
		this.opMap = opMap;
		this.chunk = chunk;
		this.interp = interp;
		this.parser = parser;
		this.assignCache = new Map<String, Expr>();
	}

	public function runMain():Dynamic
	{
		setCurrentExpr();
		return runProto(chunk.mainProto, [], null);
	}

	function setCurrentExpr():Void
	{
		// Interp.error() dereferences curExpr.pmin / pmax / origin, so anything that
		// can run a VM frame has to hand it a non-null expression. The placeholder is
		// allocated once and reused: a fresh EBlock per call would just be garbage.
		if (placeholder == null)
			placeholder = @:privateAccess parser.mk(EBlock([]), 0, 0);
		#if hscriptPos
		placeholder.origin = origin == null ? "<bytecode>" : origin;
		#end
		@:privateAccess interp.curExpr = placeholder;
	}

	static inline function rdI32(b:Bytes, p:Int):Int
	{
		return b.get(p) | (b.get(p + 1) << 8) | (b.get(p + 2) << 16) | (b.get(p + 3) << 24);
	}

	function runProto(protoIdx:Int, args:Array<Dynamic>, captures:Array<Dynamic>):Dynamic
	{
		// Every entry point resets curExpr: closures are called through a varargs
		// wrapper (and through Script.call -> Interp.fcall), which would otherwise
		// leave error() pointing at whatever the previous frame last touched - or at
		// nothing at all, when the closure is the first thing a script runs.
		// The bytecode has no position info, so line numbers are not precise here;
		// what matters is that a throw from inside a closure reports a file at all.
		setCurrentExpr();

		var proto = chunk.functions[protoIdx];
		var code = proto.code;
		// Every slot is a one element cell. Closures capture the cells instead of the
		// values, so a variable shared between two closures (or between a closure and
		// its parent) stays one single mutable variable, exactly like Interp's
		// DeclaredVar objects in the AST interpreter.
		var vars:Array<Array<Dynamic>> = [];
		var i = 0;
		while (i < proto.nlocals)
		{
			vars.push([null]);
			i++;
		}
		if (args.length < proto.minParams)
			throw "Bytecode: not enough parameters for " + proto.name + " (expected at least " + proto.minParams + ", got " + args.length + ")";

		i = 0;
		while (i < args.length)
		{
			if (i < vars.length) vars[i][0] = args[i];
			i++;
		}

		var stack:Array<Dynamic> = [];
		var handlers:Array<Handler> = [];
		var pc = 0;

		while (true)
		{
			try
			{
				while (true)
				{
					var op = code.get(pc);
					pc++;
					if (opMap != null) op = opMap.decode[op];

					switch (op)
					{
						case Op.HALT:
							return stack.length > 0 ? stack[stack.length - 1] : null;
						case Op.PUSH_NULL:
							stack.push(null);
						case Op.PUSH_TRUE:
							stack.push(true);
						case Op.PUSH_FALSE:
							stack.push(false);
						case Op.PUSH_CONST:
							stack.push(chunk.constants[rdI32(code, pc)]);
							pc += 4;
						case Op.POP:
							stack.pop();
						case Op.DUP:
							stack.push(stack[stack.length - 1]);
						case Op.SWAP:
							var b = stack.pop();
							var a = stack.pop();
							stack.push(b);
							stack.push(a);
						case Op.LOAD_LOCAL:
							stack.push(vars[rdI32(code, pc)][0]);
							pc += 4;
						case Op.STORE_LOCAL:
							vars[rdI32(code, pc)][0] = stack.pop();
							pc += 4;
						case Op.STORE_LOCAL_NEW:
							vars[rdI32(code, pc)] = [stack.pop()];
							pc += 4;
						case Op.LOAD_CAPTURE:
							stack.push(captures == null ? null : captures[rdI32(code, pc)][0]);
							pc += 4;
						case Op.STORE_CAPTURE:
							if (captures != null) captures[rdI32(code, pc)][0] = stack.pop();
							else stack.pop();
							pc += 4;
						case Op.LOAD_NAME:
							// Interp.resolve is public; the other Interp helpers below are
							// private, which is why they carry @:privateAccess.
							stack.push(interp.resolve(chunk.strings[rdI32(code, pc)]));
							pc += 4;
						case Op.STORE_NAME:
							assignName(chunk.strings[rdI32(code, pc)], stack.pop());
							pc += 4;
						case Op.STORE_GLOBAL:
							defineGlobal(chunk.strings[rdI32(code, pc)], stack.pop(), code.get(pc + 4));
							pc += 5;
						case Op.LOAD_TEMP:
							stack.push(vars[rdI32(code, pc)][0]);
							pc += 4;
						case Op.STORE_TEMP:
							vars[rdI32(code, pc)][0] = stack.pop();
							pc += 4;
						case Op.GET_FIELD:
							var obj = stack.pop();
							// Same semantics as the AST interpreter: reading a field of null
							// raises instead of silently producing null. "?." is already
							// guarded by the compiler around this opcode, so a plain "." that
							// used to be swallowed now errors like interpreted code does.
							stack.push(@:privateAccess interp.get(obj, chunk.strings[rdI32(code, pc)]));
							pc += 4;
						case Op.SET_FIELD:
							var fname = chunk.strings[rdI32(code, pc)];
							var val = stack.pop();
							var target = stack.pop();
							@:privateAccess interp.set(target, fname, val);
							stack.push(val);
							pc += 4;
						case Op.STORE_FIELD:
							var fname = chunk.strings[rdI32(code, pc)];
							var val = stack.pop();
							var target = stack.pop();
							@:privateAccess interp.set(target, fname, val);
							pc += 4;
						case Op.GET_INDEX:
							var idx = stack.pop();
							var arr = stack.pop();
							stack.push(getIndex(arr, idx));
						case Op.SET_INDEX:
							var val = stack.pop();
							var idx = stack.pop();
							var arr = stack.pop();
							setIndex(arr, idx, val);
							stack.push(val);
						case Op.STORE_INDEX:
							var val = stack.pop();
							var idx = stack.pop();
							var arr = stack.pop();
							setIndex(arr, idx, val);
						case Op.BINOP:
							var bop = rdI32(code, pc);
							pc += 4;
							if (bop == BinOp.EQTRUE)
							{
								// unary truthiness check used by conditions
								stack.push(stack.pop() == true);
							}
							else
							{
								var rhs = stack.pop();
								var lhs = stack.pop();
								stack.push(binop(bop, lhs, rhs));
							}
						/**
						 * IS_MAP / IS_CLASS / SWAP are implemented here but never emitted by
						 * Compiler, so no fresh bytecode contains them. They stay for
						 * backwards compatibility with existing bytecode (Chunk.VERSION is
						 * still 1, so older .hxb files must keep loading).
						 */
						case Op.IS_MAP:
							stack.push(isMap(stack.pop()));
						case Op.IS_CLASS:
							var cls = stack.pop();
							var v = stack.pop();
							stack.push(cls == null ? false : Std.isOfType(v, cls));
						case Op.NEG:
							stack.push(-(stack.pop()));
						case Op.NOT:
							stack.push(stack.pop() != true);
						case Op.JUMP:
							var rel = rdI32(code, pc);
							pc += 4 + rel;
						case Op.JUMP_IF_FALSE:
							var rel = rdI32(code, pc);
							pc += 4;
							if (stack.pop() != true) pc += rel;
						case Op.JUMP_IF_TRUE:
							var rel = rdI32(code, pc);
							pc += 4;
							if (stack.pop() == true) pc += rel;
						case Op.JUMP_IF_NULL:
							var rel = rdI32(code, pc);
							pc += 4;
							if (stack.pop() == null) pc += rel;
						case Op.JUMP_IF_NOT_NULL_KEEP:
							var rel = rdI32(code, pc);
							pc += 4;
							if (stack.length > 0 && stack[stack.length - 1] != null)
								pc += rel;
							else
								stack.pop();
						case Op.CALL:
							var argc = rdI32(code, pc);
							pc += 4;
							stack.push(callValue(stack, argc));
						case Op.CALL_METHOD:
							var mname = chunk.strings[rdI32(code, pc)];
							var argc = rdI32(code, pc + 4);
							pc += 8;
							var callArgs:Array<Dynamic> = [];
							var k = 0;
							while (k < argc)
							{
								callArgs.unshift(stack.pop());
								k++;
							}
							var recv = stack.pop();
							stack.push(@:privateAccess interp.fcall(recv, mname, callArgs));
						case Op.NEW:
							var cname = chunk.strings[rdI32(code, pc)];
							var argc = rdI32(code, pc + 4);
							pc += 8;
							var newArgs:Array<Dynamic> = [];
							var k = 0;
							while (k < argc)
							{
								newArgs.unshift(stack.pop());
								k++;
							}
							stack.push(@:privateAccess interp.cnew(cname, newArgs));
						case Op.MAKE_ARRAY:
							var n = rdI32(code, pc);
							pc += 4;
							var arr:Array<Dynamic> = [];
							var k = n;
							while (k > 0)
							{
								k--;
								arr.unshift(stack.pop());
							}
							stack.push(arr);
						case Op.MAKE_OBJECT:
							var n = rdI32(code, pc);
							pc += 4;
							var obj:Dynamic = {};
							var k = 0;
							while (k < n)
							{
								var v = stack.pop();
								var name = stack.pop();
								UnsafeReflect.setField(obj, name, v);
								k++;
							}
							stack.push(obj);
						case Op.MAKE_MAP:
							var n = rdI32(code, pc);
							pc += 4;
							var keys:Array<Dynamic> = [];
							var values:Array<Dynamic> = [];
							var k = 0;
							while (k < n)
							{
								values.unshift(stack.pop());
								keys.unshift(stack.pop());
								k++;
							}
							stack.push(makeMap(keys, values));
						case Op.CLOSURE:
							var pIdx = rdI32(code, pc);
							var ncap = rdI32(code, pc + 4);
							pc += 8;
							var caps:Array<Dynamic> = [];
							var k = 0;
							while (k < ncap)
							{
								var kind = code.get(pc);
								var index = rdI32(code, pc + 1);
								pc += 5;
								if (kind == 0) caps.push(vars[index]);
								else caps.push(captures == null ? [null] : captures[index]);
								k++;
							}
							stack.push(makeClosure(pIdx, caps));
						case Op.RETURN:
							return stack.pop();
						case Op.THROW:
							throw stack.pop();
						case Op.TRY_BEGIN:
							var rel = rdI32(code, pc);
							var relEnd = pc + 4;
							var slot = rdI32(code, pc + 4);
							pc += 8;
							// depth = operand stack size on entering the try, so the catch
							// clause below can unwind everything the failing body pushed.
							handlers.push({catchPc: relEnd + rel, slot: slot, depth: stack.length});
						case Op.TRY_END:
							if (handlers.length > 0) handlers.pop();
						case Op.EXEC_IMPORT:
							var stmt = chunk.strings[rdI32(code, pc)];
							pc += 4;
							if (stmt != null) {
								@:privateAccess interp.expr(@:privateAccess parser.parseString(stmt, origin == null ? "<bytecode>" : origin));
								// Keep later errors attributed to the running script, not to the import line.
								if (placeholder != null) @:privateAccess interp.curExpr = placeholder;
							}
							stack.push(null);
						case Op.ITER_INIT_KV:
							stack.push(toKeyValueIterator(stack.pop()));
						case Op.ITER_INIT:
							stack.push(toIterator(stack.pop()));
						case Op.ITER_HAS:
							// ITER_INIT/ITER_INIT_KV either return an iterator or throw, so this
							// is never null and needs no quiet "false" fallback.
							stack.push(stack.pop().hasNext());
						case Op.ITER_NEXT:
							stack.push(stack.pop().next());
						default:
							throw "Bytecode: unknown opcode " + op + " at " + (pc - 1);
					}
				}
			}
			catch (err:Dynamic)
			{
				var handler = handlers.length > 0 ? handlers[handlers.length - 1] : null;
				if (handler == null) throw err;
				handlers.pop();
				while (stack.length > handler.depth)
					stack.pop();
				while (stack.length < handler.depth)
					stack.push(null);
				stack.push(err);
				pc = handler.catchPc;
			}
		}
	}

	function makeClosure(protoIdx:Int, caps:Array<Dynamic>):Dynamic
	{
		return Reflect.makeVarArgs(function(callArgs:Array<Dynamic>) return runProto(protoIdx, callArgs, caps));
	}

	function callValue(stack:Array<Dynamic>, argc:Int):Dynamic
	{
		var args:Array<Dynamic> = [];
		var k = 0;
		while (k < argc)
		{
			args.unshift(stack.pop());
			k++;
		}
		var f = stack.pop();
		if (f == null) throw "Bytecode: cannot call null";
		return UnsafeReflect.callMethodSafe(null, f, args);
	}

	function getIndex(arr:Dynamic, idx:Dynamic):Dynamic
	{
		if (arr == null) return null;
		if (isMap(arr)) return @:privateAccess interp.getMapValue(arr, idx);
		return arr[idx];
	}

	function setIndex(arr:Dynamic, idx:Dynamic, v:Dynamic):Void
	{
		if (arr == null) return;
		if (isMap(arr))
			@:privateAccess interp.setMapValue(arr, idx, v);
		else
			arr[idx] = v;
	}

	function isMap(o:Dynamic):Bool
	{
		return @:privateAccess interp.isMap(o);
	}

	/**
	 * Builds the map flavour the AST interpreter would have picked for these keys.
	 * Mixed key types (e.g. Int + String) fall back to ObjectMap, which can differ
	 * from haxe.ds.Map for edge cases like 1 vs "1"; no change is made here, the
	 * divergence is documented rather than "fixed", because the interpreter has the
	 * same ObjectMap fallback.
	 */
	function makeMap(keys:Array<Dynamic>, values:Array<Dynamic>):Dynamic
	{
		var allInt = true;
		var allString = true;
		var allEnum = true;
		var allObject = true;
		for (k in keys)
		{
			allInt = allInt && (k is Int);
			allString = allString && (k is String);
			allEnum = allEnum && Reflect.isEnumValue(k);
			allObject = allObject && Reflect.isObject(k);
		}

		var map:Dynamic = if (allInt)
			new haxe.ds.IntMap<Dynamic>()
		else if (allString)
			new haxe.ds.StringMap<Dynamic>()
		else if (allEnum)
			new haxe.ds.EnumValueMap<Dynamic, Dynamic>()
		else
			new haxe.ds.ObjectMap<Dynamic, Dynamic>();

		var i = 0;
		while (i < keys.length)
		{
			@:privateAccess interp.setMapValue(map, keys[i], values[i]);
			i++;
		}
		return map;
	}

	function binop(op:Int, a:Dynamic, b:Dynamic):Dynamic
	{
		switch (op)
		{
			case BinOp.ADD:
				return a + b;
			case BinOp.SUB:
				return a - b;
			case BinOp.MUL:
				return a * b;
			case BinOp.DIV:
				return a / b;
			case BinOp.MOD:
				return a % b;
			case BinOp.BAND:
				return Std.int(a) & Std.int(b);
			case BinOp.BOR:
				return Std.int(a) | Std.int(b);
			case BinOp.BXOR:
				return Std.int(a) ^ Std.int(b);
			case BinOp.SHL:
				return Std.int(a) << Std.int(b);
			case BinOp.SHR:
				return Std.int(a) >> Std.int(b);
			case BinOp.USHR:
				return Std.int(a) >>> Std.int(b);
			case BinOp.EQ:
				return a == b;
			case BinOp.NEQ:
				return a != b;
			case BinOp.GTE:
				return a >= b;
			case BinOp.LTE:
				return a <= b;
			case BinOp.GT:
				return a > b;
			case BinOp.LT:
				return a < b;
			case BinOp.EQTRUE:
				return a == true;
			case BinOp.IS:
				return isType(a, b);
			case BinOp.RANGE:
				return new IntIterator(Std.int(a), Std.int(b));
			default:
				throw "Bytecode: unknown binary operator " + op;
		}
	}

	function isType(v:Dynamic, t:Dynamic):Bool
	{
		if (Std.isOfType(v, hscript.CustomClass) && Std.isOfType(t, hscript.CustomClassHandler))
		{
			var cc:hscript.CustomClass = cast v;
			var handler:hscript.CustomClassHandler = cast t;
			return cc.className == handler.name;
		}
		if (t == null) return false;
		return Std.isOfType(v, t);
	}

	/**
	 * Declares a top-level script name the same way Interp.EVar / Interp.EFunction do:
	 * static names go to interp.staticVariables, public ones to publicVariables, everything
	 * else to interp.variables. Keeping declarations out of Interp.assign matters because
	 * assign() writes a field on the script's parent object when the name is not a variable
	 * yet, and hxcpp throws "Invalid field:update" for names like update/create/stepHit.
	 */
	function defineGlobal(name:String, v:Dynamic, flags:Int):Void
	{
		var isPublic = (flags & 1) != 0;
		var isStatic = (flags & 2) != 0;
		var isFunction = (flags & 4) != 0;
		if (isStatic && interp.allowStaticVariables)
		{
			// Interp keeps only the first value of a static *variable*, but a static
			// *function* declaration always overwrites (Interp.EVar vs Interp.EFunction).
			if (isFunction || !interp.staticVariables.exists(name))
				interp.staticVariables.set(name, v);
		}
		else if (isPublic && interp.allowPublicVariables)
			interp.publicVariables.set(name, v);
		else
		{
			interp.variables.set(name, v);
			// A new global can invalidate a cached VNotFound/type-resolution result.
			interp.invalidateCache();
		}
	}

	/**
	 * Replicates Interp.assign() for a bare identifier. Using a cached AST
	 * expression keeps every scriptObject/property accessor branch intact.
	 */
	function assignName(name:String, v:Dynamic):Void
	{
		var e = assignCache.get(name);
		if (e == null)
		{
			e = parser.parseString(name + " = " + ASSIGN_VALUE, origin == null ? "<bytecode>" : origin);
			assignCache.set(name, e);
		}
		interp.variables.set(ASSIGN_VALUE, v);
		interp.expr(e);
		// interp.expr() leaves curExpr on the cached assignment node, which would make
		// the next error() report that node's (empty) position. Put the frame
		// placeholder back so errors stay attributed to the running script.
		if (placeholder != null) @:privateAccess interp.curExpr = placeholder;
	}

	/**
	 * Normalizes any value used in a for loop into something exposing
	 * hasNext / next. Range (a...b), Array and String iterators are
	 * wrapped explicitly because their std implementations use inline
	 * methods, which reflection cannot see on every target.
	 */
	/**
	 * Iterator of {key, value} pairs, used by "for (key => value in iterable)".
	 * The AST interpreter delegates this to Interp.makeIterator(v, true), but on
	 * targets where the std iterators use inline methods (eval) reflection cannot
	 * reach hasNext, so arrays and maps are wrapped by hand here.
	 */
	function toKeyValueIterator(v:Dynamic):Dynamic
	{
		if (Std.isOfType(v, Array))
		{
			var arr:Array<Dynamic> = cast v;
			var i = 0;
			return new NativeIter(function() return i < arr.length,
				function() return {key: i, value: arr[i++]});
		}
		if (Std.isOfType(v, String))
		{
			var s:String = cast v;
			var i = 0;
			return new NativeIter(function() return i < s.length,
				function() return {key: i, value: s.charAt(i++)});
		}

		var keysFn = Reflect.field(v, "keys");
		var getFn = Reflect.field(v, "get");
		if (keysFn != null && getFn != null)
		{
			var keys:Dynamic = Reflect.callMethod(v, keysFn, []);
			var hasFn = keys == null ? null : Reflect.field(keys, "hasNext");
			var nextFn = keys == null ? null : Reflect.field(keys, "next");
			if (hasFn != null && nextFn != null)
				return new NativeIter(function() return Reflect.callMethod(keys, hasFn, []),
					function() {
						var k = Reflect.callMethod(keys, nextFn, []);
						return {key: k, value: Reflect.callMethod(v, getFn, [k])};
					});
		}

		if (v.hasNext != null && v.next != null) return v;

		// Nothing else iterated: let the interpreter's "invalid iterator" error
		// through instead of returning null, which used to make "for (k => v in x)"
		// silently do nothing on a non iterable value.
		return @:privateAccess interp.makeIterator(v, true);
	}

	function toIterator(v:Dynamic):Dynamic
	{
		if (Std.isOfType(v, IntIterator))
		{
			var it:IntIterator = cast v;
			return new NativeIter(function() return it.hasNext(), function() return it.next());
		}
		if (Std.isOfType(v, Array))
		{
			var arr:Array<Dynamic> = cast v;
			var i = 0;
			return new NativeIter(function() return i < arr.length, function() return arr[i++]);
		}
		if (Std.isOfType(v, String))
		{
			var s:String = cast v;
			var i = 0;
			return new NativeIter(function() return i < s.length, function() return s.charAt(i++));
		}
		if (v.hasNext != null && v.next != null) return v;
		// Throws like the interpreter for values that are not iterable ("for (x in 123)"),
		// null included, instead of silently yielding an empty loop. Anything that
		// loops over a maybe-null value already has to guard against it in
		// interpreted mode, so both modes now fail the same way.
		return @:privateAccess interp.makeIterator(v);
	}
}

/**
 * Reflection-friendly iterator wrapper. Its methods are not inline, so
 * Dynamic dispatch works on every target.
 */
private class NativeIter
{
	var has:Void->Bool;
	var nxt:Void->Dynamic;

	public function new(has:Void->Bool, nxt:Void->Dynamic)
	{
		this.has = has;
		this.nxt = nxt;
	}

	public function hasNext():Bool
		return has();

	public function next():Dynamic
		return nxt();
}

typedef Handler = {
	var catchPc:Int;
	var slot:Int;
	var depth:Int;
}