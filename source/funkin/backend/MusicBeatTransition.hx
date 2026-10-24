package funkin.backend;

import flixel.FlxState;
import flixel.graphics.FlxGraphic;
import flixel.tweens.FlxTween;
import funkin.backend.scripting.Script;
import funkin.backend.scripting.events.CancellableEvent;
import funkin.backend.scripting.events.ResizeEvent;
import funkin.backend.scripting.events.TransitionCreationEvent;
import funkin.backend.utils.FunkinParentDisabler;
import funkin.editors.ui.UIState;
import openfl.display.BitmapData;

class MusicBeatTransition extends MusicBeatSubstate {
	public static var script:String = Flags.DEFAULT_TRANSITION_SCRIPT;
	public var transitionScript:Script;

	var nextFrameSkip:Bool = false;

	public var transitionTween:FlxTween = null;
	public var transitionCamera:FlxCamera;
	public var newState:FlxState;
	public var transOut:Bool = false;

	public var allowSkip:Bool = true;

	public var blackSpr:FlxSprite;
	public var transitionSprite:FunkinSprite;

	// Tile transition: the screen is covered with black squares instead of the sliding sheet.
	// Set tileTransition to false to get the old slide back.
	public static var tileTransition:Bool = true;
	/** Side of one tile, as a fraction of the camera width. */
	public static var tileFactor:Float = 0.05;
	/** Delay between two tiles of the wave, in seconds (row-major: left to right, top to bottom). */
	public static var tileStagger:Float = 0.05;
	/** Grow/shrink time of a single tile. */
	public static var tileDuration:Float = 0.3;
	/** Length of the whole wave. A literal tileStagger would take many seconds on a full grid,
		so it is compressed to fit this; set it to 0 to use tileStagger as-is. */
	public static var tileTotal:Float = 2 / 3;

	var tiles:Array<FlxSprite> = [];
	var tileDelays:Array<Float> = [];
	var tileWaveTime:Float = 0;

	public function new(?newState:FlxState) {
		super();
		this.newState = newState;
	}

	public override function create() {
		if (newState != null)
			add(new FunkinParentDisabler(true, false));

		transitionCamera = new FlxCamera();
		transitionCamera.bgColor = 0;
		FlxG.cameras.add(transitionCamera, false);

		cameras = [transitionCamera];

		transitionScript = Script.create(Paths.script(script));
		transitionScript.setParent(this);
		transitionScript.load();

		var event = EventManager.get(TransitionCreationEvent).recycle(newState != null, newState);
		transitionScript.call('create', [event]);

		transOut = event.transOut;
		newState = event.newState;

		if (event.cancelled) {
			super.create();
			return;
		}

		add(blackSpr = new FlxSprite(0, transOut ? -transitionCamera.height : transitionCamera.height).makeGraphic(1, 1, -1));
		blackSpr.color = 0xFF000000;
		add(transitionSprite = new FunkinSprite().loadSprite(Paths.image('menus/transitionSpr')));
		resizeDefaultSprites();

		if (tileTransition) {
			// the tile wave covers the screen on its own, the sliding sheet would double it up
			blackSpr.visible = false;
			transitionSprite.visible = false;
			startTileTransition();
		} else {
			transitionCamera.flipY = !transOut;
			transitionCamera.scroll.y = transitionCamera.height;
			transitionTween = FlxTween.tween(transitionCamera.scroll, {y: -transitionCamera.height}, 2/3, {
				ease: FlxEase.sineOut,
				onComplete: function(_) {
					finish();
				}
			});
		}

		super.create();
		transitionScript.call('postCreate', [event]);
	}

	public override function update(elapsed:Float) {
		transitionScript.call('update', [elapsed]);
		super.update(elapsed);

		if (nextFrameSkip) {
			var event = new CancellableEvent();
			transitionScript.call('onSkip', [event]);
			if (!event.cancelled) {
				skipToEnd();
				finish();
				return;
			}
		}

		if (allowSkip && !parent.persistentUpdate && FlxG.keys.pressed.SHIFT) {
			// skip
			if (newState != null) {
				nextFrameSkip = true;
				parent.persistentDraw = false;
			} else {
				var event = new CancellableEvent();
				transitionScript.call('onSkip', [event]);
				if (!event.cancelled) {
					skipToEnd();
					finish();
				}
			}
		}
		transitionScript.call('postUpdate', [elapsed]);
	}

	public override function onResize(w:Int, h:Int) {
		super.onResize(w, h);
		if (FlxG.state is UIState && UIState.resolutionAware) resizeDefaultSprites();
		transitionScript.call('onResize', [EventManager.get(ResizeEvent).recycle(w, h, null, null)]);
	}

	public function resizeDefaultSprites() {
		if (blackSpr != null) {
			blackSpr.scale.set(transitionCamera.width, transitionCamera.height);
			blackSpr.updateHitbox();
		}

		if (transitionSprite != null) {
			transitionSprite.setGraphicSize(transitionCamera.width, transitionCamera.height);
			transitionSprite.updateHitbox();
		}
	}

	/** Builds the grid of black squares and runs the wave that fills (transOut) or clears (transIn) the screen. */
	function startTileTransition() {
		final width = transitionCamera.width;
		final height = transitionCamera.height;
		final size:Int = Std.int(Math.max(4, Math.floor(width * tileFactor)));
		final cols = Math.ceil(width / size);
		final rows = Math.ceil(height / size);
		final count = cols * rows;

		// A literal tileStagger would take many seconds on a full grid, so it is compressed
		// to fit tileTotal; set tileTotal to 0 to keep the raw delay.
		final stagger = tileTotal > 0
			? Math.min(tileStagger, Math.max(0, (tileTotal - tileDuration) / Math.max(1, count - 1)))
			: tileStagger;
		tileWaveTime = (count - 1) * stagger + tileDuration;

		// one shared solid-black graphic for every tile
		final graphic = FlxGraphic.fromBitmapData(new BitmapData(size, size, true, 0xFF000000), false, 'cneTransitionTile$size', true);

		for (row in 0...rows) {
			for (col in 0...cols) {
				var tile = new FlxSprite(col * size, row * size, graphic);
				tile.centerOrigin();
				tile.antialiasing = true;
				tile.visible = false;
				add(tile);
				tiles.push(tile);
				tileDelays.push((row * cols + col) * stagger);
			}
		}

		var progress = {v: 0.0};
		transitionTween = FlxTween.tween(progress, {v: 1.0}, tileWaveTime, {
			ease: FlxEase.linear,
			onUpdate: function(_) applyTileProgress(progress.v),
			onComplete: function(_) finish()
		});
		applyTileProgress(0);
	}

	/** `global` runs from 0 (nothing yet) to 1 (wave finished); every tile eases its own slice of it. */
	function applyTileProgress(global:Float) {
		final time = global * tileWaveTime;
		for (i in 0...tiles.length) {
			var local = (time - tileDelays[i]) / tileDuration;
			if (local < 0) local = 0;
			else if (local > 1) local = 1;
			final eased = FlxEase.cubeOut(local); // fast at first, then slow
			final scaleFactor = transOut ? eased : 1 - eased;
			final tile = tiles[i];
			tile.scale.set(scaleFactor, scaleFactor);
			tile.angle = 45 * (1 - scaleFactor);
			tile.visible = scaleFactor > 0.002;
		}
	}

	/** Called when the player skips: snap the wave to its final frame before the state switch. */
	function skipToEnd() {
		if (!tileTransition || tiles.length == 0) return;
		if (transitionTween != null) {
			transitionTween.cancel();
			transitionTween = null;
		}
		applyTileProgress(1);
	}

	public function finish() {
		var event = new CancellableEvent();
		transitionScript.call('onFinish', [event]);
		if (event.cancelled) return;

		if (newState != null)
			FlxG.switchState(newState);
		close();

		transitionScript.call('onPostFinish');
	}

	public override function destroy() {
		transitionScript.call('destroy');

		if (transitionTween != null) transitionTween.cancel();
		transitionTween = FlxDestroyUtil.destroy(transitionTween);
		if (newState == null && FlxG.cameras.list.contains(transitionCamera)) FlxG.cameras.remove(transitionCamera);
		else transitionCamera.bgColor = 0xFF000000;

		transitionScript.destroy();
		super.destroy();
	}
}
