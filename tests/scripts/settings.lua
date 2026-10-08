local S = require("simlib")
return { S.snap("settings"), S.tap_text("Touch test"), S.tap(300, 900), S.snap("touch") }
