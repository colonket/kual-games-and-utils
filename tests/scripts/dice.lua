local S = require("simlib")
return { S.snap("dice_d6"), S.tap_text("+"), S.tap_text("Roll"), S.snap("dice_d6b"), S.tap_text("Arrow"), S.tap_text("Spin"), S.snap("dice_arrow"),
  S.tap_text("D20"), S.tap_text("Roll D20"), S.snap("dice_d20"), S.tap_text("8-Ball"), S.tap_text("Shake"), S.snap("dice_8ball"), S.tap_text("Coin"), S.snap("dice_coin") }
