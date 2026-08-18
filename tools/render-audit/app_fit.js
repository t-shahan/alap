      (function () {
        var body = document.body;
        if (!body) { return 0; }
        body.style.zoom = '';
        var available = document.documentElement.clientWidth;
        var content = body.scrollWidth;
        // A width of zero means the view has not been laid out yet. Dividing
        // by it would scale every message to the 0.5 floor below and shrink a
        // perfectly ordinary message to half size.
        if (!(available > 0) || !(content > 0)) { return 0; }
        var scale = content > available ? available / content : 1;
        // Below this the message is unreadable and fitting it is not a
        // kindness; let it clip rather than shrink to nothing.
        if (scale < 0.5) { scale = 0.5; }
        if (scale < 1) { body.style.zoom = scale; }
        // Read the height AFTER applying the scale, and do NOT scale it again.
        // `scrollHeight` already reflects `zoom` — multiplying a second time
        // reported 982px for a 1303px message and silently cut a quarter of it
        // off, which looked like images failing to load. Measured across 30
        // real messages before this was believed.
        return Math.ceil(document.documentElement.scrollHeight);
      })()
      