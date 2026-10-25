package funkin.backend.scripting.bytecode;

import hscript.Expr;
import hscript.Expr.ExprDef;
import hscript.Expr.Const;
import hscript.Tools;

/**
 * Compiles an hscript AST into the CNE script bytecode chunk (see Chunk/Op/A/BinOp).
 * Any syntax we cannot express safely throws CompileError so the caller can fall back
 * to the AST interpreter instead of breaking the script.
 */
class Compiler
{
	var chunk:Chunk;
	var proto:FunctionProto;
	var code:BytesOut;
	var scopes:Array<Map<String, Int>>;
	var captures:Map<String, Int>;
	var slotCount:Int;
	var loopStack:Array<LoopCtx>;
	var fileName:String;
	/** optional opcode permutation, so the emitted bytes are file specific */
	var opMap:OpMap;
	/** true for the script top-level compiler: its vars/functions live in interp.variables like the AST interpreter */
	var isMain:Bool = false;

	// --- temp slot recycling (#10) ---
	var freeTempSlots:Array<Int> = [];

	// --- try nesting depth (#4) ---
	var tryDepth:Int = 0;

	public static function compile(parser:hscript.Parser, source:String, fileName:String, ?opMap:OpMap):Chunk
	{
		var root:Expr = parser.parseString(source, fileName);
		var chunk = new Chunk();
		var main = new FunctionProto("<main>", [], 0, 0);
		chunk.functions.push(main);
		chunk.mainProto = 0;

		var c = new Compiler(chunk, main, fileName, opMap);
		c.isMain = true;
		c.pushScope();
		c.compileStatements(root);
		c.emit(Op.PUSH_NULL);
		c.emit(Op.HALT);
		main.code = c.code.toBytes();
		main.nlocals = c.slotCount;

		return chunk;
	}

	function new(chunk:Chunk, proto:FunctionProto, fileName:String, ?opMap:OpMap)
	{
		this.chunk = chunk;
		this.proto = proto;
		this.fileName = fileName;
		this.opMap = opMap;
		this.code = new BytesOut();
		this.scopes = [];
		this.slotCount = 0;
		this.loopStack = [];
	}

	// ------------------------------------------------------------------ helpers

	/** Maps a real opcode to the byte stored in the chunk (identity unless a permutation is active). */
	inline function opByte(op:Int):Int
	{
		return opMap == null ? op : opMap.encode[op];
	}

	inline function emit(op:Int):Void
	{
		code.u8(opByte(op));
	}

	inline function emitI(op:Int, a:Int):Void
	{
		code.u8(opByte(op));
		code.i32(a);
	}

	inline function emitII(op:Int, a:Int, b:Int):Void
	{
		code.u8(opByte(op));
		code.i32(a);
		code.i32(b);
	}

	// STORE_GLOBAL flag bits, see VM.defineGlobal().
	static inline var GLOBAL_PUBLIC = 1;
	static inline var GLOBAL_STATIC = 2;
	static inline var GLOBAL_FUNCTION = 4;

	/**
	 * Emits a top-level declaration. The AST interpreter files top-level declarations into
	 * interp.variables / publicVariables / staticVariables (Interp.EVar and Interp.EFunction);
	 * STORE_NAME goes through Interp.assign instead, which is assignment semantics.
	 */
	inline function emitStoreGlobal(name:String, isPublic:Bool, isStatic:Bool, isFunction:Bool):Void
	{
		emit(Op.STORE_GLOBAL);
		code.i32(chunk.addString(name));
		code.u8((isPublic ? GLOBAL_PUBLIC : 0) | (isStatic ? GLOBAL_STATIC : 0) | (isFunction ? GLOBAL_FUNCTION : 0));
	}

	/** Emits a jump with a placeholder offset; returns the operand position for patchJump. */
	function emitJump(op:Int):Int
	{
		code.u8(opByte(op));
		var pos = code.length;
		code.i32(0);
		return pos;
	}

	/** offset is relative to the end of the i32 operand */
	function patchJump(pos:Int):Void
	{
		code.patchI32(pos, code.length - (pos + 4));
	}

	function jumpTo(target:Int):Void
	{
		var pos = code.length;
		code.u8(opByte(Op.JUMP));
		code.i32(target - (pos + 5));
	}

	function pushScope():Void
	{
		scopes.push(new Map<String, Int>());
	}

	function popScope():Void
	{
		scopes.pop();
	}

	function declare(name:String):Int
	{
		var slot = slotCount++;
		scopes[scopes.length - 1].set(name, slot);
		return slot;
	}

	function tempSlot():Int
	{
		if (freeTempSlots.length > 0)
			return freeTempSlots.pop();
		return slotCount++;
	}

	inline function releaseTempSlot(slot:Int):Void
	{
		if (slot >= 0)
			freeTempSlots.push(slot);
	}

	function findLocal(name:String):Int
	{
		var i = scopes.length;
		while (--i >= 0)
		{
			var s = scopes[i];
			if (s.exists(name)) return s.get(name);
		}
		return -1;
	}

	function findCapture(name:String):Int
	{
		if (captures == null) return -1;
		return captures.exists(name) ? captures.get(name) : -1;
	}

	function fail(msg:String):Void
	{
		throw new CompileError((fileName == null ? "<script>" : fileName) + ": " + msg);
	}

	// ------------------------------------------------------------------ bodies

	function compileStatements(expr:Expr):Void
	{
		switch (Tools.expr(expr))
		{
			case EBlock(el):
				for (e in el)
					compileStatement(e);
			default:
				compileStatement(expr);
		}
	}

	function compileStatement(expr:Expr):Void
	{
		switch (Tools.expr(expr))
		{
			case EReturn(_) | EBreak | EContinue | EThrow(_):
				compileExpr(expr);
			case EBlock(el):
				pushScope();
				for (e in el)
					compileStatement(e);
				popScope();
			default:
				compileExpr(expr);
				emit(Op.POP);
		}
	}

	function compileFunctionBody(body:Expr):Void
	{
		switch (Tools.expr(body))
		{
			case EBlock(el):
				if (el.length == 0)
				{
					emit(Op.PUSH_NULL);
					emit(Op.RETURN);
					return;
				}
				for (i in 0...el.length - 1)
					compileStatement(el[i]);
				compileExpr(el[el.length - 1]);
				emit(Op.RETURN);
			default:
				compileExpr(body);
				emit(Op.RETURN);
		}
	}

	/** truthiness like Interp: value == true */
	function compileCond(expr:Expr):Void
	{
		compileExpr(expr);
		emitI(Op.BINOP, BinOp.EQTRUE);
	}

	// ------------------------------------------------------------------ expressions

	function compileExpr(e:Expr):Void
	{
		switch (Tools.expr(e))
		{
			case EConst(c):
				switch (c)
				{
					case CInt(v):
						emit(Op.PUSH_CONST);
						code.i32(chunk.addConst(v));
					case CFloat(f):
						emit(Op.PUSH_CONST);
						code.i32(chunk.addConst(f));
					case CString(s):
						emit(Op.PUSH_CONST);
						code.i32(chunk.addConst(s));
				}
			case EIdent(id):
				switch (id)
				{
					case "null":
						emit(Op.PUSH_NULL);
					case "true":
						emit(Op.PUSH_TRUE);
					case "false":
						emit(Op.PUSH_FALSE);
					default:
						var slot = findLocal(id);
						if (slot >= 0)
							emitI(Op.LOAD_LOCAL, slot);
						else
						{
							var cap = findCapture(id);
							if (cap >= 0)
								emitI(Op.LOAD_CAPTURE, cap);
							else
								emitI(Op.LOAD_NAME, chunk.addString(id));
						}
				}
			case EParent(inner):
				compileExpr(inner);
			case EBlock(el):
				// EBlock as an expression returns the value of its last statement,
				// matching hscript's Interp.eval(EBlock).
				pushScope();
				if (el.length == 0)
				{
					popScope();
					emit(Op.PUSH_NULL);
				}
				else
				{
					for (i in 0...el.length - 1)
					{
						compileExpr(el[i]);
						emit(Op.POP);
					}
					compileExpr(el[el.length - 1]);
					popScope();
				}
			case EVar(n, t, initE, isPublic, isStatic, isPrivate, isFinal, isInline, getter, setter, isVar):
				if (getter != null || setter != null) fail("property accessor var '" + n + "'");
				if (isMain)
				{
					// Top-level script vars are globals in the AST interpreter (Interp.variables),
					// so scripts can expose/tweak them through set()/get() and every function sees
					// the same cell. Keep that: storing them in locals would silently turn them
					// into per-closure copies that external code can no longer change.
					if (initE != null)
						compileExpr(initE);
					else
						emit(Op.PUSH_NULL);
					emit(Op.DUP);
					// Declarations use STORE_GLOBAL: Interp.assign would treat them as writes
					// to the script object's fields, which breaks for names like `update`.
					emitStoreGlobal(n, isPublic == true, isStatic == true, false);
				}
				else
				{
					var slot = declare(n);
					if (initE != null)
						compileExpr(initE);
					else
						emit(Op.PUSH_NULL);
					emit(Op.DUP);
					// Fresh cell: the AST interpreter makes a new DeclaredVar each time
					// the declaration runs, so closures keep the value of their own pass.
					emitI(Op.STORE_LOCAL_NEW, slot);
				}
			case EField(inner, field, safe):
				compileExpr(inner);
				if (safe == true)
				{
					emit(Op.DUP);
					var jNull = emitJump(Op.JUMP_IF_NULL);
					emitI(Op.GET_FIELD, chunk.addString(field));
					var jEnd = emitJump(Op.JUMP);
					patchJump(jNull);
					emit(Op.POP);
					emit(Op.PUSH_NULL);
					patchJump(jEnd);
				}
				else
					emitI(Op.GET_FIELD, chunk.addString(field));
			case EBinop(op, e1, e2):
				compileBinop(op, e1, e2);
			case EUnop(op, prefix, inner):
				compileUnop(op, prefix, inner);
			case ECall(callee, params):
				compileCall(callee, params);
			case EIf(cond, e1, e2):
				var endJumps = [];
				compileCond(cond);
				var jFalse = emitJump(Op.JUMP_IF_FALSE);
				compileExpr(e1);
				if (e2 != null)
					endJumps.push(emitJump(Op.JUMP));
				patchJump(jFalse);
				if (e2 != null)
					compileExpr(e2);
				else
					emit(Op.PUSH_NULL);
				for (p in endJumps)
					patchJump(p);
			case EWhile(cond, body):
				compileWhile(cond, body);
			case EDoWhile(cond, body):
				compileDoWhile(cond, body);
			case EFor(v, it, body, ithv):
				compileFor(v, it, body, ithv);
			case EBreak:
				if (loopStack.length == 0) fail("break outside of a loop");
				var ctx = loopStack[loopStack.length - 1];
				// #4: close any try blocks we are jumping out of so the VM's
				// handler stack stays in sync with the interpreter's.
				var d = tryDepth;
				while (d > ctx.tryDepth)
				{
					emit(Op.TRY_END);
					d--;
				}
				ctx.breakJumps.push(emitJump(Op.JUMP));
			case EContinue:
				if (loopStack.length == 0) fail("continue outside of a loop");
				var ctx = loopStack[loopStack.length - 1];
				var d = tryDepth;
				while (d > ctx.tryDepth)
				{
					emit(Op.TRY_END);
					d--;
				}
				if (ctx.continueTarget >= 0)
					jumpTo(ctx.continueTarget);
				else
					ctx.continueJumps.push(emitJump(Op.JUMP));
			case EFunction(args, body, name, ret, isPublic, isStatic, isOverride, isPrivate, isFinal, isInline):
				compileFunction(args, body, name, isPublic, isStatic);
			case EReturn(v):
				if (v != null)
					compileExpr(v);
				else
					emit(Op.PUSH_NULL);
				emit(Op.RETURN);
			case EArray(arrE, idxE):
				compileExpr(arrE);
				compileExpr(idxE);
				emit(Op.GET_INDEX);
			case EArrayDecl(items, wantedType):
				compileArrayDecl(items, wantedType);
			case ENew(cl, params, paramType):
				for (p in params)
					compileExpr(p);
				emitII(Op.NEW, chunk.addString(cl), params.length);
			case EThrow(inner):
				compileExpr(inner);
				emit(Op.THROW);
			case ETry(body, n, t, ecatch):
				compileTry(body, n, ecatch);
			case EObject(fl):
				for (f in fl)
				{
					emit(Op.PUSH_CONST);
					code.i32(chunk.addConst(f.name));
					compileExpr(f.e);
				}
				emitI(Op.MAKE_OBJECT, fl.length);
			case ETernary(cond, e1, e2):
				compileExpr(cond);
				var jFalse = emitJump(Op.JUMP_IF_FALSE);
				compileExpr(e1);
				var jEnd = emitJump(Op.JUMP);
				patchJump(jFalse);
				compileExpr(e2);
				patchJump(jEnd);
			case ESwitch(subj, cases, def):
				compileSwitch(subj, cases, def);
			case EMeta(name, args, inner):
				compileExpr(inner);
			case ECheckType(inner, t):
				compileExpr(inner);
			case ECast(inner, t):
				compileExpr(inner);
			case EImport(c, asname, isUsing):
				// Imports register a class in the interpreter globals at runtime, so they
				// are replayed through the AST interpreter instead of being dropped.
				if (c == null)
					emit(Op.PUSH_NULL);
				else
				{
					var stmt = (isUsing ? "using " : "import ") + c + (asname == null ? "" : " as " + asname) + ";";
					emitI(Op.EXEC_IMPORT, chunk.addString(stmt));
				}
			case EPackage(n):
				emit(Op.PUSH_NULL);
			case EClass(name, fields, extend, interfaces, isFinal, isPrivate):
				fail("class declarations are not supported by the bytecode compiler");
			case EEnum(en, isAbstract):
				fail("enum declarations are not supported by the bytecode compiler");
			case ERegex(re, flags):
				// EReg values are opaque to the bytecode VM; the AST interpreter handles them.
				fail("regular expression literals are not supported by the bytecode compiler");
		}
	}

	// ------------------------------------------------------------------ operators

	function compileBinop(op:hscript.Expr.Binop, e1:Expr, e2:Expr):Void
	{
		var opS = op.toString();
		switch (opS)
		{
			case "=":
				compileAssign(e1, e2, -1);
			case "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", ">>>=", "??=":
				var base = opS.substr(0, opS.length - 1);
				var bop = BinOp.fromString(base);
				if (bop < 0) fail("unsupported compound operator " + opS);
				compileAssign(e1, e2, bop);
			case "&&":
				compileCond(e1);
				var jFalse = emitJump(Op.JUMP_IF_FALSE);
				compileCond(e2);
				var jEnd = emitJump(Op.JUMP);
				patchJump(jFalse);
				emit(Op.PUSH_FALSE);
				patchJump(jEnd);
			case "||":
				compileCond(e1);
				var jTrue = emitJump(Op.JUMP_IF_TRUE);
				compileCond(e2);
				var jEnd = emitJump(Op.JUMP);
				patchJump(jTrue);
				emit(Op.PUSH_TRUE);
				patchJump(jEnd);
			case "??":
				compileExpr(e1);
				var jNotNull = emitJump(Op.JUMP_IF_NOT_NULL_KEEP);
				compileExpr(e2);
				patchJump(jNotNull);
			case "is":
				compileExpr(e1);
				compileExpr(e2);
				emitI(Op.BINOP, BinOp.IS);
			case "...":
				compileExpr(e1);
				compileExpr(e2);
				emitI(Op.BINOP, BinOp.RANGE);
			default:
				var bop = BinOp.fromString(opS);
				if (bop < 0) fail("unsupported binary operator " + opS);
				compileExpr(e1);
				compileExpr(e2);
				emitI(Op.BINOP, bop);
		}
	}

	function compileUnop(op:hscript.Expr.Unop, prefix:Bool, inner:Expr):Void
	{
		var opS = op.toString();
		switch (opS)
		{
			case "!":
				compileExpr(inner);
				emit(Op.NOT);
			case "-":
				compileExpr(inner);
				emit(Op.NEG);
			case "~":
				compileExpr(inner);
				emit(Op.PUSH_CONST);
				code.i32(chunk.addConst(-1));
				emitI(Op.BINOP, BinOp.BXOR);
			case "++":
				compileIncDec(inner, prefix, 1);
			case "--":
				compileIncDec(inner, prefix, -1);
			default:
				fail("unsupported unary operator " + opS);
		}
	}

	function compileIncDec(target:Expr, prefix:Bool, delta:Int):Void
	{
		switch (Tools.expr(target))
		{
			case EIdent(id):
				loadIdent(id);
				if (prefix)
				{
					emit(Op.PUSH_CONST);
					code.i32(chunk.addConst(delta));
					emitI(Op.BINOP, BinOp.ADD);
					emit(Op.DUP);
					storeIdent(id);
				}
				else
				{
					emit(Op.DUP);
					emit(Op.PUSH_CONST);
					code.i32(chunk.addConst(delta));
					emitI(Op.BINOP, BinOp.ADD);
					storeIdent(id);
				}
			case EField(objE, field, safe):
				compileExpr(objE);
				emit(Op.DUP);
				emitI(Op.GET_FIELD, chunk.addString(field));
				if (prefix)
				{
					emit(Op.PUSH_CONST);
					code.i32(chunk.addConst(delta));
					emitI(Op.BINOP, BinOp.ADD);
					emitI(Op.SET_FIELD, chunk.addString(field));
				}
				else
				{
					var t = tempSlot();
					emitI(Op.STORE_TEMP, t);
					emitI(Op.LOAD_TEMP, t);
					emit(Op.PUSH_CONST);
					code.i32(chunk.addConst(delta));
					emitI(Op.BINOP, BinOp.ADD);
					emitI(Op.STORE_FIELD, chunk.addString(field));
					emitI(Op.LOAD_TEMP, t);
					releaseTempSlot(t);
				}
			case EArray(arrE, idxE):
				var ta = tempSlot();
				var ti = tempSlot();
				compileExpr(arrE);
				emitI(Op.STORE_TEMP, ta);
				compileExpr(idxE);
				emitI(Op.STORE_TEMP, ti);
				if (prefix)
				{
					emitI(Op.LOAD_TEMP, ta);
					emitI(Op.LOAD_TEMP, ti);
					emit(Op.GET_INDEX);
					emit(Op.PUSH_CONST);
					code.i32(chunk.addConst(delta));
					emitI(Op.BINOP, BinOp.ADD);
					var tn = tempSlot();
					emitI(Op.STORE_TEMP, tn);
					emitI(Op.LOAD_TEMP, ta);
					emitI(Op.LOAD_TEMP, ti);
					emitI(Op.LOAD_TEMP, tn);
					emit(Op.SET_INDEX);
					releaseTempSlot(tn);
				}
				else
				{
					var told = tempSlot();
					emitI(Op.LOAD_TEMP, ta);
					emitI(Op.LOAD_TEMP, ti);
					emit(Op.GET_INDEX);
					emitI(Op.STORE_TEMP, told);
					emit(Op.PUSH_CONST);
					code.i32(chunk.addConst(delta));
					emitI(Op.BINOP, BinOp.ADD);
					var tn = tempSlot();
					emitI(Op.STORE_TEMP, tn);
					emitI(Op.LOAD_TEMP, ta);
					emitI(Op.LOAD_TEMP, ti);
					emitI(Op.LOAD_TEMP, tn);
					emit(Op.SET_INDEX);
					emitI(Op.LOAD_TEMP, told);
					releaseTempSlot(told);
					releaseTempSlot(tn);
				}
				releaseTempSlot(ta);
				releaseTempSlot(ti);
			default:
				fail("unsupported ++/-- target");
		}
	}

	function loadIdent(id:String):Void
	{
		var slot = findLocal(id);
		if (slot >= 0)
			emitI(Op.LOAD_LOCAL, slot);
		else
		{
			var cap = findCapture(id);
			if (cap >= 0)
				emitI(Op.LOAD_CAPTURE, cap);
			else
				emitI(Op.LOAD_NAME, chunk.addString(id));
		}
	}

	function storeIdent(id:String):Void
	{
		var slot = findLocal(id);
		if (slot >= 0)
			emitI(Op.STORE_LOCAL, slot);
		else
		{
			var cap = findCapture(id);
			if (cap >= 0)
				emitI(Op.STORE_CAPTURE, cap);
			else
				emitI(Op.STORE_NAME, chunk.addString(id));
		}
	}

	// ------------------------------------------------------------------ assignment

	function compileAssign(target:Expr, valueE:Expr, compoundOp:Int):Void
	{
		switch (Tools.expr(target))
		{
			case EIdent(id):
				if (compoundOp >= 0)
				{
					loadIdent(id);
					compileExpr(valueE);
					emitI(Op.BINOP, compoundOp);
				}
				else
					compileExpr(valueE);
				emit(Op.DUP);
				storeIdent(id);
			case EField(objE, field, safe):
				compileExpr(objE);
				if (compoundOp >= 0)
				{
					emit(Op.DUP);
					emitI(Op.GET_FIELD, chunk.addString(field));
					compileExpr(valueE);
					emitI(Op.BINOP, compoundOp);
				}
				else
					compileExpr(valueE);
				emitI(Op.SET_FIELD, chunk.addString(field));
			case EArray(arrE, idxE):
				var ta = tempSlot();
				var ti = tempSlot();
				compileExpr(arrE);
				emitI(Op.STORE_TEMP, ta);
				compileExpr(idxE);
				emitI(Op.STORE_TEMP, ti);
				if (compoundOp >= 0)
				{
					emitI(Op.LOAD_TEMP, ta);
					emitI(Op.LOAD_TEMP, ti);
					emit(Op.GET_INDEX);
					compileExpr(valueE);
					emitI(Op.BINOP, compoundOp);
				}
				else
					compileExpr(valueE);
				var tv = tempSlot();
				emitI(Op.STORE_TEMP, tv);
				emitI(Op.LOAD_TEMP, ta);
				emitI(Op.LOAD_TEMP, ti);
				emitI(Op.LOAD_TEMP, tv);
				emit(Op.SET_INDEX);
				releaseTempSlot(ta);
				releaseTempSlot(ti);
				releaseTempSlot(tv);
			default:
				fail("unsupported assignment target");
		}
	}

	// ------------------------------------------------------------------ calls

	function compileCall(callee:Expr, params:Array<Expr>):Void
	{
		switch (Tools.expr(callee))
		{
			case EField(objE, field, safe):
				compileExpr(objE);
				if (safe == true)
				{
					emit(Op.DUP);
					var jNull = emitJump(Op.JUMP_IF_NULL);
					for (p in params)
						compileExpr(p);
					emitII(Op.CALL_METHOD, chunk.addString(field), params.length);
					var jEnd = emitJump(Op.JUMP);
					patchJump(jNull);
					emit(Op.POP);
					emit(Op.PUSH_NULL);
					patchJump(jEnd);
				}
				else
				{
					for (p in params)
						compileExpr(p);
					emitII(Op.CALL_METHOD, chunk.addString(field), params.length);
				}
			default:
				compileExpr(callee);
				for (p in params)
					compileExpr(p);
				emitI(Op.CALL, params.length);
		}
	}

	// ------------------------------------------------------------------ arrays/objects

	/**
	 * hscript's interpreter builds a real Map when an array literal carries a map type hint
	 * (`var m:Map<String, T> = []`), because the parser stores that hint on EArrayDecl.
	 * Without honouring it here the literal becomes an Array and later map calls die with
	 * "Null Function Pointer", so an empty hinted literal is emitted as the matching
	 * haxe.ds map class instead (Op.NEW keeps the bytecode format unchanged).
	 */
	static function mapClassForHint(wantedType:hscript.Expr.CType):String
	{
		if (wantedType == null)
			return null;
		return switch (wantedType)
		{
			case CTPath(["Map"], params) if (params != null && params.length > 0):
				switch (params[0])
				{
					case CTPath(["String"], _): "haxe.ds.StringMap";
					case CTPath(["Int"], _): "haxe.ds.IntMap";
					case _: "haxe.ds.ObjectMap";
				}
			case CTPath(["StringMap"], _): "haxe.ds.StringMap";
			case CTPath(["IntMap"], _): "haxe.ds.IntMap";
			case CTPath(["ObjectMap"], _): "haxe.ds.ObjectMap";
			case CTPath(["EnumMap" | "EnumValueMap"], _): "haxe.ds.EnumValueMap";
			case _: null;
		}
	}

	function compileArrayDecl(items:Array<Expr>, ?wantedType:hscript.Expr.CType):Void
	{
		if (items.length == 0)
		{
			var mapClass = mapClassForHint(wantedType);
			if (mapClass != null)
			{
				emitII(Op.NEW, chunk.addString(mapClass), 0);
				return;
			}
		}

		var isMap = false;
		if (items.length > 0)
		{
			switch (Tools.expr(items[0]))
			{
				case EBinop(op, _, _) if (op.toString() == "=>"):
					isMap = true;
				default:
			}
		}

		if (isMap)
		{
			for (it in items)
			{
				switch (Tools.expr(it))
				{
					case EBinop(op, k, v) if (op.toString() == "=>"):
						compileExpr(k);
						compileExpr(v);
					default:
						fail("mixed map/array literal");
				}
			}
			emitI(Op.MAKE_MAP, items.length);
		}
		else
		{
			for (it in items)
				compileExpr(it);
			emitI(Op.MAKE_ARRAY, items.length);
		}
	}

	// ------------------------------------------------------------------ control flow

	function compileWhile(cond:Expr, body:Expr):Void
	{
		var start = code.length;
		compileCond(cond);
		var jFalse = emitJump(Op.JUMP_IF_FALSE);
		loopStack.push({continueTarget: start, continueJumps: [], breakJumps: [], tryDepth: tryDepth});
		compileStatement(body);
		var ctx = loopStack.pop();
		jumpTo(start);
		patchJump(jFalse);
		for (p in ctx.breakJumps)
			patchJump(p);
		emit(Op.PUSH_NULL);
	}

	function compileDoWhile(cond:Expr, body:Expr):Void
	{
		var start = code.length;
		loopStack.push({continueTarget: -1, continueJumps: [], breakJumps: [], tryDepth: tryDepth});
		compileStatement(body);
		var ctx = loopStack.pop();
		var condStart = code.length;
		for (p in ctx.continueJumps)
			code.patchI32(p, condStart - (p + 4));
		compileCond(cond);
		var jTrue = emitJump(Op.JUMP_IF_TRUE);
		var end = code.length;
		code.patchI32(jTrue, start - (jTrue + 4));
		for (p in ctx.breakJumps)
			code.patchI32(p, end - (p + 4));
		emit(Op.PUSH_NULL);
	}

	function compileFor(v:String, it:Expr, body:Expr, ithv:String):Void
	{
		var iterSlot = tempSlot();
		compileExpr(it);
		emit(ithv == null ? Op.ITER_INIT : Op.ITER_INIT_KV);
		emitI(Op.STORE_TEMP, iterSlot);

		var start = code.length;
		emitI(Op.LOAD_TEMP, iterSlot);
		emit(Op.ITER_HAS);
		var jFalse = emitJump(Op.JUMP_IF_FALSE);
		loopStack.push({continueTarget: start, continueJumps: [], breakJumps: [], tryDepth: tryDepth});
		pushScope();
		emitI(Op.LOAD_TEMP, iterSlot);
		emit(Op.ITER_NEXT);
		if (ithv != null)
		{
			// Pair on the stack: store the value first, then the key.
			emit(Op.DUP);
			emitI(Op.GET_FIELD, chunk.addString("value"));
			var vSlot = declare(v);
			emitI(Op.STORE_LOCAL_NEW, vSlot);
			emitI(Op.GET_FIELD, chunk.addString("key"));
			var kSlot = declare(ithv);
			emitI(Op.STORE_LOCAL_NEW, kSlot);
		}
		else
		{
			var slot = declare(v);
			// New cell per iteration, exactly like Interp.forLoop's locals.set(..., {r: next}).
			emitI(Op.STORE_LOCAL_NEW, slot);
		}
		compileStatement(body);
		popScope();
		var ctx = loopStack.pop();
		jumpTo(start);
		patchJump(jFalse);
		for (p in ctx.breakJumps)
			patchJump(p);
		emit(Op.PUSH_NULL);
		releaseTempSlot(iterSlot);
	}

	function compileSwitch(subj:Expr, cases:Array<hscript.Expr.SwitchCase>, def:Expr):Void
	{
		var t = tempSlot();
		compileExpr(subj);
		emitI(Op.STORE_TEMP, t);

		var caseJumps:Array<Array<Int>> = [];
		for (c in cases)
		{
			var jumps = [];
			for (v in c.values)
			{
				// #8: only reject calls that look like enum constructor patterns
				// (callee is an uppercase identifier). Ordinary function calls
				// used as case values are left to the runtime.
				switch (Tools.expr(v))
				{
					case ECall(callee, _):
						var isEnumPattern = false;
						switch (Tools.expr(callee))
						{
							case EIdent(name):
								if (name.length > 0)
								{
									var c0 = name.charCodeAt(0);
									if (c0 >= 65 && c0 <= 90) isEnumPattern = true;
								}
							default:
						}
						if (isEnumPattern)
							fail("enum pattern matching in switch is not supported by the bytecode compiler");
					default:
				}
				emitI(Op.LOAD_TEMP, t);
				compileExpr(v);
				emitI(Op.BINOP, BinOp.EQ);
				jumps.push(emitJump(Op.JUMP_IF_TRUE));
			}
			caseJumps.push(jumps);
		}

		var defJump = emitJump(Op.JUMP);
		var endJumps = [];
		var i = 0;
		for (c in cases)
		{
			for (p in caseJumps[i])
				patchJump(p);
			compileExpr(c.expr);
			endJumps.push(emitJump(Op.JUMP));
			i++;
		}
		patchJump(defJump);
		if (def != null)
			compileExpr(def);
		else
			emit(Op.PUSH_NULL);
		for (p in endJumps)
			patchJump(p);
		releaseTempSlot(t);
	}

	function compileTry(body:Expr, n:String, ecatch:Expr):Void
	{
		var errSlot = tempSlot();
		emit(Op.TRY_BEGIN);
		var relPos = code.length;
		code.i32(0);
		code.i32(errSlot);
		tryDepth++;
		compileTryBody(body);
		tryDepth--;
		emit(Op.TRY_END);
		var jEnd = emitJump(Op.JUMP);

		var catchStart = code.length;
		code.patchI32(relPos, catchStart - (relPos + 4));
		pushScope();
		// #9: `catch { ... }` without a variable name is legal in hscript.
		if (n != null)
			scopes[scopes.length - 1].set(n, errSlot);
		emitI(Op.STORE_LOCAL_NEW, errSlot);
		compileExpr(ecatch);
		popScope();
		patchJump(jEnd);
		releaseTempSlot(errSlot);
	}

	/**
	 * Compiles the body of a try block, keeping the value of its last expression
	 * on the stack so `try { ... }` can be used as an expression (#2).
	 */
	function compileTryBody(body:Expr):Void
	{
		switch (Tools.expr(body))
		{
			case EBlock(el):
				if (el.length == 0)
				{
					emit(Op.PUSH_NULL);
					return;
				}
				for (i in 0...el.length - 1)
					compileStatement(el[i]);
				compileExpr(el[el.length - 1]);
			default:
				compileExpr(body);
		}
	}

	// ------------------------------------------------------------------ functions

	function compileFunction(args:Array<hscript.Expr.Argument>, body:Expr, name:String, isPublic:Bool, isStatic:Bool):Void
	{
		var paramNames:Array<String> = [];
		var minParams = 0;
		for (a in args)
		{
			paramNames.push(a.name);
			if (a.opt == true)
			{
				// optional, no default enforcement
			}
			else
				minParams++;
		}

		var rawNames:Array<String> = [];
		collectIdents(body, rawNames);

		var captureNames:Array<String> = [];
		for (n in rawNames)
		{
			if (paramNames.contains(n)) continue;
			if (findLocal(n) >= 0 || findCapture(n) >= 0)
				if (!captureNames.contains(n)) captureNames.push(n);
		}

		var fnName = name == null ? "<closure>" : name;
		var fnProto = new FunctionProto(fnName, paramNames, minParams, 0);
		var protoIdx = chunk.functions.length;
		chunk.functions.push(fnProto);

		emit(Op.CLOSURE);
		code.i32(protoIdx);
		code.i32(captureNames.length);
		for (n in captureNames)
		{
			var slot = findLocal(n);
			if (slot >= 0)
			{
				code.u8(0);
				code.i32(slot);
			}
			else
			{
				code.u8(1);
				code.i32(findCapture(n));
			}
		}

		var sub = new Compiler(chunk, fnProto, fileName, opMap);
		sub.captures = new Map<String, Int>();
		for (i in 0...captureNames.length)
			sub.captures.set(captureNames[i], i);
		sub.slotCount = paramNames.length;
		sub.pushScope();
		for (i in 0...paramNames.length)
			sub.scopes[sub.scopes.length - 1].set(paramNames[i], i);
		sub.compileFunctionBody(body);
		fnProto.code = sub.code.toBytes();
		fnProto.nlocals = sub.slotCount;

		// #1: hscript binds a function declaration to the enclosing locals when
		// one exists, and to the globals only at top level. Mirror that.
		if (name != null)
		{
			if (isMain)
			{
				emit(Op.DUP);
				emitStoreGlobal(name, isPublic, isStatic, true);
			}
			else
			{
				var slot = declare(name);
				emit(Op.DUP);
				emitI(Op.STORE_LOCAL_NEW, slot);
			}
		}
	}

	/**
	 * Collects the identifiers a closure body mentions, to decide what it captures.
	 *
	 * Limitation: only EIdent nodes are collected, so a variable reached through a
	 * string, e.g. Reflect.setProperty(__parent__, "someVar", v) or
	 * scriptObject.hget("someVar"), is not captured. That is the same blind spot
	 * hscript itself has (capture is lexical), and the VM cannot fix it without
	 * changing the language; keep it in mind when a closure mixes with reflection.
	 */
	static function collectIdents(e:Expr, out:Array<String>):Void
	{
		switch (Tools.expr(e))
		{
			case EIdent(n):
				if (!out.contains(n)) out.push(n);
			default:
		}
		Tools.iter(e, function(child) collectIdents(child, out));
	}
}

typedef LoopCtx = {
	var continueTarget:Int;
	var continueJumps:Array<Int>;
	var breakJumps:Array<Int>;
	var tryDepth:Int;
}