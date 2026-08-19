      (function () {
        var fit = document.getElementById('fit');
        if (!fit) { return 0; }
        fit.style.transform = '';
        fit.style.width = '';
        fit.style.paddingLeft = '';
        fit.style.paddingRight = '';

        var available = document.documentElement.clientWidth;
        var content = fit.scrollWidth;
        // Padding is the first thing to go, before any shrinking. A message
        // laid out for 600-700px would otherwise pay for our margins twice:
        // once in lost width and again in being scaled down to fit what was
        // left. Text mail keeps the margins because it never needs the room.
        if (available > 0 && content > available) {
          fit.style.paddingLeft = '0';
          fit.style.paddingRight = '0';
          content = fit.scrollWidth;
        }
        // A width of zero means the view has not been laid out yet. Dividing
        // by it would scale every message to the 0.5 floor below and shrink a
        // perfectly ordinary message to half size.
        if (!(available > 0) || !(content > 0)) { return 0; }
        var scale = content > available ? available / content : 1;
        // Below this the message is unreadable and fitting it is not a
        // kindness; let it clip rather than shrink to nothing.
        if (scale < 0.5) { scale = 0.5; }
        if (scale < 1) {
          fit.style.transformOrigin = 'top left';
          fit.style.transform = 'scale(' + scale + ')';
          // Keep the PRE-scale layout width, or the content reflows into the
          // narrower box and the scale is computed against a moving target.
          fit.style.width = (100 / scale) + '%';
        }
        // `getBoundingClientRect`, NOT `scrollHeight`.
        //
        // The old code measured `scrollHeight` and carried a hard-won comment
        // saying not to scale the result again, because `scrollHeight` already
        // reflected `zoom`. That fact INVERTS here: `scrollHeight` is a layout
        // property and `transform` is a paint-time operation, so under a
        // transform `scrollHeight` reports the UNSCALED height and would
        // over-report by 1/scale. The bounding rect is the one that reflects
        // the transform, which is why it replaces it.
        return Math.ceil(fit.getBoundingClientRect().height);
      })()
      