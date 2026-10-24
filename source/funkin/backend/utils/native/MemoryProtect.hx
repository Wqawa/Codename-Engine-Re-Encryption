package funkin.backend.utils.native;

/**
 * Small set of Windows APIs used by the script protection code.
 *
 * Everything here is advisory: it raises the cost of casual memory inspection,
 * it does not stop a determined attacker. No pointer into the Haxe heap is
 * passed to the OS, so nothing here can corrupt the GC.
 */
#if windows
@:cppFileCode('#include <Windows.h>')
@:dox(hide)
final class MemoryProtect {
	/** True when a user mode debugger is attached to this process. */
	@:functionCode('
		int present = 0;
		if (CheckRemoteDebuggerPresent(GetCurrentProcess(), &present) && present) return true;
		return IsDebuggerPresent() != 0;
	')
	public static function isBeingDebugged():Bool {
		return false;
	}

	/** Marks the current thread as hidden from user mode debuggers (NtSetInformationThread). */
	@:functionCode('
		typedef LONG (WINAPI *pfnNtSetInformationThread)(HANDLE, ULONG, PVOID, ULONG);
		HMODULE ntdll = GetModuleHandleA("ntdll.dll");
		if (ntdll == NULL) return false;
		pfnNtSetInformationThread setInfo = (pfnNtSetInformationThread)GetProcAddress(ntdll, "NtSetInformationThread");
		if (setInfo == NULL) return false;
		// ThreadHideFromDebugger = 17, current thread pseudo handle = -2
		return setInfo((HANDLE)-2, 17, NULL, 0) == 0;
	')
	public static function hideThreadFromDebugger():Bool {
		return false;
	}
}
#else
@:dox(hide)
final class MemoryProtect {
	public static function isBeingDebugged():Bool {
		return false;
	}

	public static function hideThreadFromDebugger():Bool {
		return false;
	}
}
#end
