package funkin.backend.scripting.bytecode;

/**
 * Binary operator codes used by the BINOP instruction.
 */
class BinOp {
	public static inline var ADD:Int = 0;
	public static inline var SUB:Int = 1;
	public static inline var MUL:Int = 2;
	public static inline var DIV:Int = 3;
	public static inline var MOD:Int = 4;
	public static inline var BAND:Int = 5;
	public static inline var BOR:Int = 6;
	public static inline var BXOR:Int = 7;
	public static inline var SHL:Int = 8;
	public static inline var SHR:Int = 9;
	public static inline var USHR:Int = 10;
	public static inline var EQ:Int = 11;
	public static inline var NEQ:Int = 12;
	public static inline var GTE:Int = 13;
	public static inline var LTE:Int = 14;
	public static inline var GT:Int = 15;
	public static inline var LT:Int = 16;
	public static inline var EQTRUE:Int = 17;
	public static inline var IS:Int = 18;
	public static inline var RANGE:Int = 19;

	public static function fromString(op:String):Int {
		return switch (op) {
			case "+": ADD;
			case "-": SUB;
			case "*": MUL;
			case "/": DIV;
			case "%": MOD;
			case "&": BAND;
			case "|": BOR;
			case "^": BXOR;
			case "<<": SHL;
			case ">>": SHR;
			case ">>>": USHR;
			case "==": EQ;
			case "!=": NEQ;
			case ">=": GTE;
			case "<=": LTE;
			case ">": GT;
			case "<": LT;
			case "...": RANGE;
			default: -1;
		}
	}
}
