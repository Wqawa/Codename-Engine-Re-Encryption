package funkin.backend.system.framerate;

#if TRANSLATIONS_SUPPORT
import funkin.backend.assets.TranslatedAssetLibrary;
#end
import funkin.backend.assets.AssetsLibraryList;
import funkin.backend.assets.IModsAssetLibrary;
import funkin.backend.assets.ScriptedAssetLibrary;
import funkin.backend.system.macros.StringMacro;

class AssetTreeInfo extends FramerateCategory {
	public function new() {
		super("Asset Libraries Tree Info");
		visible = Options.fpsCounterAssets;
		// the tree only changes when a mod is loaded or released
		refreshInterval = 1;
	}

	public override function __enterFrame(t:Float) {
		if (alpha <= 0.05 || !visible) return;

		if (!shouldRefresh()) return;

		var text = "Not initialized yet\n";
		if (Paths.assetsTree != null){
			text = "";
			var buf = new StringBuf();
			for(l in Paths.assetsTree.libraries) {
				var l = AssetsLibraryList.getCleanLibrary(l);

				var tag = l.tag.toString().toUpperCase();

				StringMacro.addLine(buf, '[${tag}] ');

				var className = Type.getClassName(Type.getClass(l));
				className = className.substr(className.lastIndexOf(".") + 1);

				#if TRANSLATIONS_SUPPORT
				if (l is TranslatedAssetLibrary) {
					StringMacro.addLine(buf, '${className} - ${cast(l, TranslatedAssetLibrary).langFolder} for (${cast(l, TranslatedAssetLibrary).forLibrary.modName})\n');
				} else #end if (l is ScriptedAssetLibrary) {
					StringMacro.addLine(buf, '${className} - ${cast(l, ScriptedAssetLibrary).scriptName} (${cast(l, ScriptedAssetLibrary).modName} | ${cast(l, ScriptedAssetLibrary).libName} | ${cast(l, ScriptedAssetLibrary).prefix})\n');
				} else if (l is IModsAssetLibrary) {
					StringMacro.addLine(buf, '${className} - ${cast(l, IModsAssetLibrary).modName} - ${cast(l, IModsAssetLibrary).libName} (${cast(l, IModsAssetLibrary).prefix})\n');
				} else {
					StringMacro.addLine(buf, '${Std.string(l)}\n');
				}
			}
			text = buf.toString();
			if (text != "")
				text = text.substr(0, text.length-1);
		}

		setText(text);
		super.__enterFrame(t);
	}
}