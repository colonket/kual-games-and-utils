local S = require("simlib")
local calc = require("apps.calculator")
return {
  S.check(function() return calc.evaluate("2+3×4") == 14 end, "precedence"),
  S.check(function() return calc.evaluate("(1+2)×(3+4)") == 21 end, "parens"),
  S.check(function() return calc.evaluate("−5+2") == -3 end, "unary minus"),
  S.check(function() return calc.evaluate("2^10") == 1024 end, "power"),
  S.check(function() return calc.evaluate("50%×8") == 4 end, "percent"),
  S.check(function() return calc.evaluate("1÷0") == nil end, "div0"),
  S.tap_text("1"), S.tap_text("2"), S.tap_text("×"), S.tap_text("("), S.tap_text("3"), S.tap_text("+"), S.tap_text("4"), S.tap_text(")"), S.tap_text("="),
  S.check(function() return require("core.ui").top().result == "84" end, "12×(3+4)=84 via keypad"),
  S.tap_text("÷"), S.tap_text("8"), S.tap_text("="),
  S.snap("calculator"),
}
