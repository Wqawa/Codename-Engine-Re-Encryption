package funkin.backend.scripting.bytecode;

import haxe.io.Bytes;

/**
 * A compiled script function: its parameters, local slot count and bytecode.
 */
class FunctionProto {
	public var name:String;
	public var params:Array<String>;
	public var minParams:Int;
	public var nlocals:Int;
	public var code:Bytes;

	public function new(?name:String, ?params:Array<String>, ?minParams:Int = 0, ?nlocals:Int = 0) {
		this.name = name;
		this.params = params == null ? [] : params;
		this.minParams = minParams;
		this.nlocals = nlocals;
	}
}
