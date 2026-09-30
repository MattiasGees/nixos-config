return {
  black = 0xff181819,
  white = 0xffe2e2e3,
  red = 0xfffc5d7c,
  green = 0xff9ed072,
  blue = 0xff76cce0,
  yellow = 0xffe7c664,
  orange = 0xfff39660,
  magenta = 0xffb39df3,
  grey = 0xff7f8490,
  transparent = 0x00000000,

  bar = {
    bg = 0xf02c2e34,
    border = 0xff2c2e34,
  },
  -- macOS-style dark menu material (semantic label colours, system accents)
  popup = {
    bg = 0xeb1e1e21,
    border = 0x2effffff,
    separator = 0x1fffffff,
    hover = 0x1fffffff,
    text = 0xfff2f2f7,
    secondary = 0x9aebebf5,
    tertiary = 0x66ebebf5,
    accent = 0xff0a84ff,
    green = 0xff30d158,
    red = 0xffff453a,
  },
  bg1 = 0xff363944,
  bg2 = 0xff414550,

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
