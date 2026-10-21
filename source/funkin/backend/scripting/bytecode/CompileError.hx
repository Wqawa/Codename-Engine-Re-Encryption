package funkin.backend.scripting.bytecode;

/**
 * Thrown when a script cannot be compiled to bytecode.
 * The script system catches this and falls back to the AST interpreter.
 */
class CompileError
{
	public var msg:String;

	public function new(msg:String)
	{
		this.msg = msg;
	}

	public function toString():String
	{
		return "CompileError: " + msg;
	}
}
