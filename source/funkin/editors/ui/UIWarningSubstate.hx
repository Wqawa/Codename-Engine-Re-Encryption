package funkin.editors.ui;

import openfl.display.ShaderParameter;
import openfl.display.ShaderInput;
import openfl.events.KeyboardEvent;
import openfl.filters.ShaderFilter;
import openfl.Lib;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import funkin.backend.shaders.CustomShader;
import openfl.filters.ShaderFilter;

class UIWarningSubstate extends MusicBeatSubstate {
	var camShaders:Array<FlxCamera> = [];
	var blurShader:CustomShader = {
		var _ = new CustomShader(Options.intensiveBlur ? "engine/editorBlur" : "engine/editorBlurFast");
		if(!Options.intensiveBlur) {
			var noiseTexture:ShaderInput<openfl.display.BitmapData> = _.data.noiseTexture;
			noiseTexture.input = Assets.getBitmapData("assets/shaders/noise256.png");
			noiseTexture.wrap = REPEAT;
			var noiseTextureSize:ShaderParameter<Float> = _.data.noiseTextureSize;
			noiseTextureSize.value = [noiseTexture.input.width, noiseTexture.input.height];
		}
		_;
	};

	public var bHeight:Int = 232;

	var title:String;
	var message:String;
	var buttons:Array<WarningButton>;
	var isError:Bool = true;

	// Optional text field. Null onSubmit keeps the dialog exactly as it was: a message
	// and buttons, no input, no key listeners.
	var onSubmit:String->Void;
	/** What has been typed so far; masked on screen, plain here for the caller. */
	public var entered:String = "";
	var inputText:UIText;
	var inputHint:UIText;
	var keyHandler:KeyboardEvent->Void;
	var textHandler:String->Void;

	/** A button can set this to stay open, for input that failed its check. */
	public var keepOpen:Bool = false;

	var titleSpr:UIText;
	var messageSpr:UIText;

	var warnCam:FlxCamera;

	public override function onSubstateOpen() {
		super.onSubstateOpen();
		parent.persistentUpdate = false;
		parent.persistentDraw = true;
	}

	public override function create() {
		// a row for the input field, above the buttons
		if (onSubmit != null) bHeight += 72;

		for(c in FlxG.cameras.list) {
			// Prevent adding a shader if it already has one
			@:privateAccess if(c._filters != null) {
				var shouldSkip = false;
				for(filter in c._filters) {
					if(filter is ShaderFilter) {
						var filter:ShaderFilter = cast filter;
						if(filter.shader is CustomShader) {
							var shader:CustomShader = cast filter.shader;

							if(shader.path == blurShader.path) {
								shouldSkip = true;
								break;
							}
						}
					}
				}
				if(shouldSkip)
					continue;
			}
			camShaders.push(c);
			c.addShader(blurShader);
		}

		camera = warnCam = new FlxCamera();
		warnCam.bgColor = 0;
		warnCam.alpha = 0;
		warnCam.zoom = 0.1;
		FlxG.cameras.add(warnCam, false);


		var spr = new UISliceSprite(0, 0, CoolUtil.maxInt(560, 30 + (170 * buttons.length)), bHeight, 'editors/ui/${isError ? "normal" : "grayscale"}-popup');

		var sprIcon:FlxSprite = new FlxSprite(spr.x + 18, spr.y + 28 + 26).loadGraphic(Paths.image('editors/warnings/${isError ? "error" : "warning"}'));
		sprIcon.scale.set(1.4, 1.4);
		sprIcon.updateHitbox();

		messageSpr = new UIText(0,0, spr.bWidth - 100 - (26 * 2), message);
		spr.bHeight = Std.int(bHeight + Math.abs(Math.min(sprIcon.height-messageSpr.height, 0)));

		spr.x = (FlxG.width - spr.bWidth) / 2;
		spr.y = (FlxG.height - spr.bHeight) / 2;
		spr.color = isError ? 0xFFFF0000 : 0xFFFFFF00;
		add(spr);

		if(title != null) {
			add(titleSpr = new UIText(spr.x + 25, spr.y, spr.bWidth - 50, title, 15, -1));
			titleSpr.y = spr.y + ((30 - titleSpr.height) / 2);
		}

		var sprIcon:FlxSprite = new FlxSprite(spr.x + 18, spr.y + 28 + 26).loadGraphic(Paths.image('editors/warnings/${isError ? "error" : "warning"}'));
		sprIcon.scale.set(1.4, 1.4);
		sprIcon.updateHitbox();
		sprIcon.antialiasing = true;
		add(sprIcon);

		messageSpr.x = sprIcon.x + 70 + 16 + 20;
		messageSpr.y = sprIcon.y;
		add(messageSpr);

		if (onSubmit != null) {
			var boxY = spr.y + spr.bHeight - (36 + 16) - 58;
			var boxW = Std.int(spr.bWidth - 200);
			add(new FlxSprite(spr.x + 100, boxY).makeGraphic(boxW, 36, 0xFF111119));

			inputText = new UIText(spr.x + 112, boxY + 9, boxW - 24, "", 14, 0xFFFFFFFF, false);
			add(inputText);

			inputHint = new UIText(spr.x + 100, boxY + 40, spr.bWidth - 200, "Enter to confirm, Esc to cancel", 11, 0xFF8A8A96, false);
			add(inputHint);

			// characters come from lime's text input: charCode on key events is empty on
			// native, so a key listener would never receive anything printable
			keyHandler = onKey;
			textHandler = onText;
			Lib.application.window.onTextInput.add(textHandler);
			FlxG.stage.addEventListener(KeyboardEvent.KEY_DOWN, keyHandler);
		}

		var xPos = (FlxG.width - (30 + (170 * buttons.length))) / 2;
		for(k=>b in buttons) {
			var button = new UIButton(xPos + 20 + (170 * k), spr.y + spr.bHeight - (36 + 16), b.label, function() {
				b.onClick(this);
				// a button that rejected the input keeps the dialog up
				if (!keepOpen) close();
				keepOpen = false;
			}, 160, 30);
			if (b.color != null) {
				button.frames = Paths.getFrames("editors/ui/grayscale-button");
				button.color = b.color;
			}
			add(button);
		}

		FlxTween.tween(camera, {alpha: 1}, 0.25, {ease: FlxEase.cubeOut});
		FlxTween.tween(camera, {zoom: 1}, 0.66, {ease: FlxEase.elasticOut});

		CoolUtil.playMenuSFX(WARNING);
	}

	function onKey(e:KeyboardEvent):Void {
		if (e == null) return;
		switch (e.keyCode) {
			case 8: // backspace
				if (entered.length > 0) entered = entered.substr(0, entered.length - 1);
			case 13: // enter
				if (onSubmit != null) onSubmit(entered);
			case 27: // escape
				close();
		}
		refresh();
		e.stopPropagation();
	}

	function onText(text:String):Void {
		if (text == null) return;
		entered += text;
		refresh();
	}

	function refresh():Void {
		if (inputText == null) return;
		var masked = "";
		for (i in 0...entered.length) masked += "*";
		inputText.text = masked;
	}

	public override function destroy() {
		super.destroy();
		for(e in camShaders)
			e.removeShader(blurShader);

		FlxTween.cancelTweensOf(warnCam);
		FlxG.cameras.remove(warnCam);

		// removing by the stored references, not by `this.onText`: evaluated inline, those
		// produce new closures and the listeners would outlive the dialog
		if (textHandler != null) Lib.application.window.onTextInput.remove(textHandler);
		if (keyHandler != null) FlxG.stage.removeEventListener(KeyboardEvent.KEY_DOWN, keyHandler);
	}

	public function new(title:String, message:String, buttons:Array<WarningButton>, ?isError:Bool = true, ?onSubmit:String->Void = null) {
		super();
		this.title = title;
		this.message = message;
		this.buttons = buttons;
		this.isError = isError;
		this.onSubmit = onSubmit;
	}
}

typedef WarningButton = {
	var label:String;
	var ?color:Int;
	var onClick:UIWarningSubstate->Void;
}