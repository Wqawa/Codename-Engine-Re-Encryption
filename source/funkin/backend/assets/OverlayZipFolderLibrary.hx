package funkin.backend.assets;

import lime.graphics.Image;
import lime.media.AudioBuffer;
import lime.text.Font;
import lime.utils.Bytes;

#if MOD_SUPPORT
/**
 * A zip mod pack with the writable folder of the same name laid on top of it.
 *
 * Vanilla 1.1.0 only ever loads one of the two: as soon as `mods/Name.zip` exists
 * the sibling `mods/Name/` folder is ignored, so anything the editors write next
 * to a pack could never be read back. This subclass makes the folder win whenever
 * it really holds the requested file and falls back to the archive otherwise.
 *
 * ZipFolderLibrary itself is left untouched (it is official code) and every
 * `is ZipFolderLibrary` check in the engine keeps working, because this is a
 * subclass of it.
 */
class OverlayZipFolderLibrary extends ZipFolderLibrary {
	/** Folder laid on top of the archive, `mods/Name`. */
	public var overlayPath:String;
	/** Read access to `overlayPath`; null when there is no folder next to the pack. */
	var overlay:ModsFolderLibrary;

	public function new(basePath:String, libName:String, ?modName:String, ?overlayFolder:String, ?memoryZip:SysZip) {
		super(basePath, libName, modName, true, memoryZip);
		if (overlayFolder != null) {
			overlayPath = overlayFolder;
			overlay = new ModsFolderLibrary(overlayFolder, libName, modName);
			// asset ids always arrive as "assets/..." once prepareModLibrary ran
			overlay.prefix = 'assets/';
		}
	}

	/** True when the writable folder really contains this asset. */
	inline function inOverlay(id:String):Bool {
		return overlay != null && overlay.exists(id, "");
	}

	public override function exists(asset:String, type:String):Bool {
		return inOverlay(asset) || super.exists(asset, type);
	}

	public override function getBytes(id:String):Bytes {
		return inOverlay(id) ? overlay.getBytes(id) : super.getBytes(id);
	}

	public override function getImage(id:String):Image {
		return inOverlay(id) ? overlay.getImage(id) : super.getImage(id);
	}

	public override function getAudioBuffer(id:String):AudioBuffer {
		return inOverlay(id) ? overlay.getAudioBuffer(id) : super.getAudioBuffer(id);
	}

	public override function getFont(id:String):Font {
		return inOverlay(id) ? overlay.getFont(id) : super.getFont(id);
	}

	public override function getPath(id:String):String {
		if (!__parseAsset(id)) return null;
		if (inOverlay(id)) return overlay.getPath(id);
		// same as the parent's private getAssetPath(), including the video remap
		return getVideoRemap('$basePath/$_parsedAsset');
	}

	public override function getFiles(folder:String):Array<String> {
		var out = super.getFiles(folder);
		for (file in overlayFiles(folder, false))
			if (!out.contains(file)) out.push(file);
		return out;
	}

	public override function getFolders(folder:String):Array<String> {
		var out = super.getFolders(folder);
		for (dir in overlayFiles(folder, true))
			if (!out.contains(dir)) out.push(dir);
		return out;
	}

	/** Direct listing of one folder in the writable overlay (files or folders). */
	function overlayFiles(folder:String, folders:Bool):Array<String> {
		if (overlay == null) return [];
		if (!folder.endsWith("/")) folder += "/";
		var path = overlayPath + "/" + folder.substr(prefix.length);
		var out:Array<String> = [];
		try {
			for (entry in sys.FileSystem.readDirectory(path))
				if (sys.FileSystem.isDirectory('$path$entry') == folders) out.push(entry);
		} catch (e:Dynamic) {}
		return out;
	}
}
#end
