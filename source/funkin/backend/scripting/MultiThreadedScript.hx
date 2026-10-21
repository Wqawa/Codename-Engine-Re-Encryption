package funkin.backend.scripting;

#if ALLOW_MULTITHREADING
import sys.thread.Thread;
#end

import hscript.IHScriptCustomBehaviour;

class MultiThreadedScript implements IFlxDestroyable implements IHScriptCustomBehaviour {
	var thread:#if ALLOW_MULTITHREADING Thread #else Dynamic #end;

	/**
	 * Script being ran.
	 */
	public var script:Script;

	private var __variables:Array<String>;

	/**
	 * Return value of the last call.
	 */
	public var returnValue:Dynamic = null;

	/**
	 * Whenever the current call has ended.
	 */
	public var callEnded:Bool = true;



	public function new(path:String, ?parentScript:Script) {
		script = Script.create(path);

		if (parentScript != null) {
			if (script is HScript && parentScript is HScript) {
				var hscript:HScript = cast script;
				var parentHScript:HScript = cast parentScript;

				hscript.interp.variables = parentHScript.interp.variables;
				hscript.interp.publicVariables = parentHScript.interp.publicVariables;
				hscript.interp.staticVariables = parentHScript.interp.staticVariables;

				script.setParent(parentHScript.interp.scriptObject);
			}
		}

		script.load();

		#if ALLOW_MULTITHREADING
		thread = Thread.createWithEventLoop(function() {
			// Prevent the thread from being auto deleted
			Thread.current().events.promise();
		});
		#end

		__variables = Type.getInstanceFields(Type.getClass(this));
	}

	public function hget(name:String):Dynamic
		return __variables.contains(name) ? Reflect.getProperty(this, name) : script.get(name);

	public function hset(name:String, val:Dynamic):Dynamic {
		if (__variables.contains(name))
			Reflect.setProperty(this, name, val);
		else
			script.set(name, val);
		return val;
	}

	/**
	 * Runs a function of the script on its worker thread.
	 *
	 * Threading note: the call is posted to the thread's event loop and returns
	 * immediately, so `returnValue` / `callEnded` are only meaningful once the
	 * worker has run the queue. `callEnded` is written by the worker and read by
	 * whoever polls it; overlapping calls from several threads are not serialized
	 * by this class. Call it from one place at a time (the usual pattern: from a
	 * single update callback and read the result on the next frame) instead of
	 * relying on it being thread safe. The engine itself only creates these
	 * through EngineUtil.startMultithreadedScript().
	 */
	public function call(func:String, args:Array<Dynamic>) {
		#if ALLOW_MULTITHREADING
		thread.events.run(function() {
			callEnded = false;
			returnValue = script.call(func, args);
			callEnded = true;
		});
		#else
		returnValue = script.call(func, args);
		callEnded = true;
		#end
	}

	public function destroy() {
		if (script != null) {
			script.call("destroy");
			script.destroy();
		}

		#if ALLOW_MULTITHREADING
		if (thread != null) {
			thread.events.runPromised(function() {
				// close the thing
			});
		}
		#end
	}
}