package funkin.backend.system.framerate;

import openfl.display.Bitmap;
import openfl.display.Sprite;
import openfl.text.TextField;
import openfl.text.TextFormat;

class FramerateCategory extends Sprite {
	public var title:TextField;
	public var text:TextField;

	public var bgSprite:Bitmap;

	private var _text:String = "";

	/**
	 * Seconds between two readout rebuilds.
	 *
	 * A TextField re-shapes its glyphs and re-uploads its texture whenever the string it
	 * holds changes, and these panels were rebuilding at the full frame rate: the memory
	 * counter changes on almost every frame, so the debug overlay alone cost a handful of
	 * text layout passes per frame. A readout at 10-15 Hz reads the same and costs a
	 * fraction of that.
	 */
	public var refreshInterval:Float = 1 / 15;

	private var __sinceRefresh:Float = 1;

	public function new(title:String, text:String = "") {
		super();

		x = 10;
		this.title = new TextField();
		this.text = new TextField();

		bgSprite = new Bitmap(Framerate.__bitmap);
		bgSprite.alpha = 0.5;
		addChild(bgSprite);

		for(label in [this.title, this.text]) {
			label.autoSize = LEFT;
			label.x = 0;
			label.y = 0;
			label.defaultTextFormat = new TextFormat(Framerate.fontName, label == this.title ? 18 : 12, -1);
			label.selectable = false;
			addChild(label);
		}
		this.title.text = title;
		this.title.multiline = this.title.wordWrap = false;
		this.text.multiline = true;

		this.text.y = this.title.y + this.title.height + 2;
	}

	/** True when this frame should rebuild the readout, and starts the next interval. */
	public inline function shouldRefresh():Bool {
		if ((__sinceRefresh += FlxG.rawElapsed) < refreshInterval) return false;
		__sinceRefresh = 0;
		return true;
	}

	/** Writes the readout, but only when the string really changed. */
	public function setText(value:String):Void {
		if (value == _text) return;
		_text = value;
		text.text = value;
	}

	public function reload() {
		for(label in [this.title, this.text]) label.defaultTextFormat = new TextFormat(Framerate.fontName, label == this.title ? 18 : 12, -1);
	}

	public override function __enterFrame(t:Float) {
		if (alpha <= 0.05 || !visible) return;
		super.__enterFrame(t);

		var width = Math.max(this.title.width, this.text.width) + (Framerate.instance.x * 2);
		var height = this.text.height + this.text.y;
		bgSprite.x = -Framerate.instance.x;
		bgSprite.scaleX = width;
		bgSprite.scaleY = height;
	}

	public static inline function addLine(buf:StringBuf, ...values:Array<Dynamic>):Void {
		for (v in values) buf.add(v);
	}
}
