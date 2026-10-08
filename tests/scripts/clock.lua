local S = require("simlib")
return { S.snap("clock_digital"), S.tap_text("Analog"), S.snap("clock_analog"), S.tap_text("Flip"), S.snap("clock_flip"), S.tap(500, 700), S.snap("clock_bare") }
