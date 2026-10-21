package funkin.backend.scripting.bytecode;

/**
 * Opcodes of the Codename Engine script VM.
 * Operands are little-endian: i32 unless noted otherwise.
 */
class Op {
	public static inline var HALT:Int = 0;
	public static inline var PUSH_NULL:Int = 1;
	public static inline var PUSH_TRUE:Int = 2;
	public static inline var PUSH_FALSE:Int = 3;
	public static inline var PUSH_CONST:Int = 4; // i32 constant index
	public static inline var POP:Int = 5;
	public static inline var DUP:Int = 6;
	/** Reserved: implemented in the VM but never emitted by Compiler (kept for old bytecode). */
	public static inline var SWAP:Int = 7;

	public static inline var LOAD_LOCAL:Int = 8; // i32 slot
	public static inline var STORE_LOCAL:Int = 9; // i32 slot
	public static inline var LOAD_CAPTURE:Int = 10; // i32 capture index
	public static inline var STORE_CAPTURE:Int = 11; // i32 capture index
	public static inline var LOAD_NAME:Int = 12; // i32 string index
	public static inline var STORE_NAME:Int = 13; // i32 string index
	public static inline var LOAD_TEMP:Int = 14; // i32 temp slot
	public static inline var STORE_TEMP:Int = 15; // i32 temp slot

	public static inline var GET_FIELD:Int = 16; // i32 string index (obj -> value)
	public static inline var SET_FIELD:Int = 17; // i32 string index (obj, value -> value)
	public static inline var STORE_FIELD:Int = 18; // i32 string index (obj, value ->)
	public static inline var GET_INDEX:Int = 19; // arr, index -> value
	public static inline var SET_INDEX:Int = 20; // arr, index, value -> value
	public static inline var STORE_INDEX:Int = 21; // arr, index, value ->

	public static inline var BINOP:Int = 22; // i32 BinOp code
	/** Reserved: implemented in the VM but never emitted by Compiler (kept for old bytecode). */
	public static inline var IS_MAP:Int = 23; // value -> Bool
	/** Reserved: implemented in the VM but never emitted by Compiler (kept for old bytecode). */
	public static inline var IS_CLASS:Int = 24; // value -> Bool
	public static inline var NEG:Int = 25; // value -> -value
	public static inline var NOT:Int = 26; // value -> value != true

	public static inline var JUMP:Int = 27; // i32 relative offset
	public static inline var JUMP_IF_FALSE:Int = 28; // pops
	public static inline var JUMP_IF_TRUE:Int = 29; // pops
	public static inline var JUMP_IF_NULL:Int = 30; // pops
	public static inline var JUMP_IF_NOT_NULL_KEEP:Int = 31; // peeks

	public static inline var CALL:Int = 32; // i32 argc (callee below args)
	public static inline var CALL_METHOD:Int = 33; // i32 string index, i32 argc (obj below args)
	public static inline var NEW:Int = 34; // i32 string index, i32 argc

	public static inline var MAKE_ARRAY:Int = 35; // i32 count (values on stack)
	public static inline var MAKE_OBJECT:Int = 36; // i32 field count (name,value pairs on stack)
	public static inline var MAKE_MAP:Int = 37; // i32 entry count (key,value pairs on stack)

	public static inline var CLOSURE:Int = 38; // i32 proto, i32 captures, then per capture: u8 kind, i32 index
	public static inline var RETURN:Int = 39;
	public static inline var THROW:Int = 40;
	public static inline var TRY_BEGIN:Int = 41; // i32 relative catch offset, i32 temp slot
	public static inline var TRY_END:Int = 42;
	public static inline var ITER_INIT:Int = 43; // iterable -> iterator
	public static inline var ITER_HAS:Int = 44; // iterator -> Bool
	public static inline var ITER_NEXT:Int = 45; // iterator -> value

	/**
	 * Like STORE_LOCAL, but the slot gets a brand new variable cell instead of
	 * overwriting the current one. The AST interpreter creates a fresh
	 * DeclaredVar every time an EVar runs and on every loop iteration, so
	 * closures made in a loop capture that iteration's value; reusing one cell
	 * would make them all see the last value.
	 */
	public static inline var STORE_LOCAL_NEW:Int = 46; // i32 slot

	/** Like ITER_INIT, but the iterator yields {key, value} objects ("for (k => v in x)"). */
	public static inline var ITER_INIT_KV:Int = 47; // iterable -> key/value iterator

	/**
	 * Re-runs an "import ...;" / "using ...;" statement through the AST interpreter,
	 * which registers the class in the interpreter globals. Reimplementing hscript's
	 * import resolution by hand would silently drift from the interpreter, and mods
	 * do rely on imports (they resolve type names at runtime).
	 */
	public static inline var EXEC_IMPORT:Int = 48; // i32 string index (statement text)
}
