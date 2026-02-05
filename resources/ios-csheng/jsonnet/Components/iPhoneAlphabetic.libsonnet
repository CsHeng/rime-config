// 英文字母键盘 - 使用 symbol 直接上屏（不经过 rime 引擎）
local params = import '../Constants/Keyboard.libsonnet';
local basicStyle = import 'BasicStyle.libsonnet';
local preedit = import 'Preedit.libsonnet';
local toolbar = import 'Toolbar.libsonnet';
local utils = import 'Utils.libsonnet';
local colors = import '../Constants/Colors.libsonnet';

local portraitNormalButtonSize = {
  size: { width: '112.5/1125' },
};

local hintStyle = {
  hintStyle: {
    size: { width: 50, height: 50 },
  },
};

// 将 character 转换为 symbol 的辅助函数
local toSymbol(buttonParams) =
  local newAction = if std.objectHas(buttonParams, 'action') && std.type(buttonParams.action) == 'object' && std.objectHas(buttonParams.action, 'character') then
    { action: { symbol: buttonParams.action.character } }
  else
    {};
  local newUpperAction = if std.objectHas(buttonParams, 'uppercasedStateAction') && std.type(buttonParams.uppercasedStateAction) == 'object' && std.objectHas(buttonParams.uppercasedStateAction, 'character') then
    { uppercasedStateAction: { symbol: buttonParams.uppercasedStateAction.character } }
  else
    {};
  buttonParams + newAction + newUpperAction;

// 标准26键布局
local alphabeticKeyboardLayout = {
  keyboardLayout: [
    {
      HStack: {
        subviews: [
          { Cell: params.keyboard.qButton.name },
          { Cell: params.keyboard.wButton.name },
          { Cell: params.keyboard.eButton.name },
          { Cell: params.keyboard.rButton.name },
          { Cell: params.keyboard.tButton.name },
          { Cell: params.keyboard.yButton.name },
          { Cell: params.keyboard.uButton.name },
          { Cell: params.keyboard.iButton.name },
          { Cell: params.keyboard.oButton.name },
          { Cell: params.keyboard.pButton.name },
        ],
      },
    },
    {
      HStack: {
        subviews: [
          { Cell: params.keyboard.aButton.name },
          { Cell: params.keyboard.sButton.name },
          { Cell: params.keyboard.dButton.name },
          { Cell: params.keyboard.fButton.name },
          { Cell: params.keyboard.gButton.name },
          { Cell: params.keyboard.hButton.name },
          { Cell: params.keyboard.jButton.name },
          { Cell: params.keyboard.kButton.name },
          { Cell: params.keyboard.lButton.name },
        ],
      },
    },
    {
      HStack: {
        subviews: [
          { Cell: params.keyboard.shiftButton.name },
          { Cell: params.keyboard.zButton.name },
          { Cell: params.keyboard.xButton.name },
          { Cell: params.keyboard.cButton.name },
          { Cell: params.keyboard.vButton.name },
          { Cell: params.keyboard.bButton.name },
          { Cell: params.keyboard.nButton.name },
          { Cell: params.keyboard.mButton.name },
          { Cell: params.keyboard.backspaceButton.name },
        ],
      },
    },
    {
      HStack: {
        subviews: [
          { Cell: params.keyboard.numericButton.name },
          { Cell: 'enSemicolonButton' },
          { Cell: params.keyboard.spaceButton.name },
          { Cell: 'en2cnButton' },
          { Cell: params.keyboard.enterButton.name },
        ],
      },
    },
  ],
};


local newKeyLayout(isDark=false, isPortrait=true) =
  local keyboardHeight = if isPortrait then params.keyboard.height.iPhone.portrait else params.keyboard.height.iPhone.landscape;
  {
    keyboardHeight: keyboardHeight,
    keyboardStyle: utils.newBackgroundStyle(style=basicStyle.keyboardBackgroundStyleName)
    +{
      insets:{ left:3, right:3 }
    },
  }
  + alphabeticKeyboardLayout
  // First Row - 使用原有参数，但把 character 改成 symbol
  + basicStyle.newAlphabeticButton(
    params.keyboard.qButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.qButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.wButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.wButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.eButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.eButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.rButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.rButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.tButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.tButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.yButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.yButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.uButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.uButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.iButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.iButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.oButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.oButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.pButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.pButton.params) + hintStyle
  )

  // Second Row
  + basicStyle.newAlphabeticButton(
    params.keyboard.aButton.name,
    isDark,
    {
      size:
        { width: '168.75/1125' },
      bounds:
        { width: '111/168.75', alignment: 'right' },
    } + toSymbol(params.keyboard.aButton.params) + hintStyle,
  )
  + basicStyle.newAlphabeticButton(params.keyboard.sButton.name, isDark, portraitNormalButtonSize + toSymbol(params.keyboard.sButton.params) + hintStyle)
  + basicStyle.newAlphabeticButton(params.keyboard.dButton.name, isDark, portraitNormalButtonSize + toSymbol(params.keyboard.dButton.params) + hintStyle)
  + basicStyle.newAlphabeticButton(params.keyboard.fButton.name, isDark, portraitNormalButtonSize + toSymbol(params.keyboard.fButton.params) + hintStyle)
  + basicStyle.newAlphabeticButton(params.keyboard.gButton.name, isDark, portraitNormalButtonSize + toSymbol(params.keyboard.gButton.params) + hintStyle)
  + basicStyle.newAlphabeticButton(params.keyboard.hButton.name, isDark, portraitNormalButtonSize + toSymbol(params.keyboard.hButton.params) + hintStyle)
  + basicStyle.newAlphabeticButton(params.keyboard.jButton.name, isDark, portraitNormalButtonSize + toSymbol(params.keyboard.jButton.params) + hintStyle)
  + basicStyle.newAlphabeticButton(params.keyboard.kButton.name, isDark, portraitNormalButtonSize + toSymbol(params.keyboard.kButton.params) + hintStyle)
  + basicStyle.newAlphabeticButton(
    params.keyboard.lButton.name,
    isDark,
    {
      size:
        { width: '168.75/1125' },
      bounds:
        { width: '111/168.75', alignment: 'left' },
    } + toSymbol(params.keyboard.lButton.params) + hintStyle
  )

  // Third Row
  + basicStyle.newSystemButton(
    params.keyboard.shiftButton.name,
    isDark,
    {
      size:
        { width: '168.75/1125' },
      bounds:
        { width: '151/168.75', alignment: 'left' },
    }
    + params.keyboard.shiftButton.params
    + {
      uppercasedStateForegroundStyle: params.keyboard.shiftButton.name + 'UppercasedForegroundStyle',
    }
    + {
      capsLockedStateForegroundStyle: params.keyboard.shiftButton.name + 'CapsLockedForegroundStyle',
    }
  )
  + {
    [params.keyboard.shiftButton.name + 'UppercasedForegroundStyle']:
      basicStyle.newImageSystemButtonForegroundStyle(isDark, params.keyboard.shiftButton.uppercasedParams),
    [params.keyboard.shiftButton.name + 'CapsLockedForegroundStyle']:
      basicStyle.newImageSystemButtonForegroundStyle(isDark, params.keyboard.shiftButton.capsLockedParams),
  }

  + basicStyle.newAlphabeticButton(
    params.keyboard.zButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.zButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.xButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.xButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.cButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.cButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.vButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.vButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.bButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.bButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.nButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.nButton.params) + hintStyle
  )
  + basicStyle.newAlphabeticButton(
    params.keyboard.mButton.name,
    isDark,
    portraitNormalButtonSize + toSymbol(params.keyboard.mButton.params) + hintStyle
  )
  + basicStyle.newSystemButton(
    params.keyboard.backspaceButton.name,
    isDark,
    {
      size:
        { width: '168.75/1125' },
      bounds:
        { width: '151/168.75', alignment: 'right' },
    } + params.keyboard.backspaceButton.params,
  )

  // Fourth Row
  + basicStyle.newSystemButton(
    params.keyboard.numericButton.name,
    isDark,
    {
      size:
        { width: '160/1125' },
    } + params.keyboard.numericButton.params
  )
  // 英文标点按钮 - 使用英文逗号和句号
  + basicStyle.newAlphabeticButton(
    'enSemicolonButton',
    isDark,
    {
      size: { width: '110/1125' },
      backgroundStyle: 'semicolonBG',
      action: { symbol: ',' },
      swipeUpAction: { symbol: '.' },
      showSwipeHints: true,
      foregroundStyleName: [
        'enSemicolonButtonForegroundStyle',
        'enSemicolonButtonSwipeUpHintForegroundStyle',
      ],
    },
    needHint=false
  )
  + {
    local primaryColor = if isDark then colors.standardButtonForegroundColor.dark else colors.standardButtonForegroundColor.light,
    local hintColor = if isDark then colors.labelColor.tertiary.dark else colors.labelColor.tertiary.light,
    enSemicolonButtonForegroundStyle: {
      buttonStyleType: 'text',
      text: ',',
      fontSize: 22.5,
      normalColor: primaryColor,
      highlightColor: primaryColor,
      center: { x: 0.5, y: 0.45 },
    },
    enSemicolonButtonSwipeUpHintForegroundStyle: {
      buttonStyleType: 'text',
      text: '.',
      fontSize: 10,
      normalColor: hintColor,
      highlightColor: hintColor,
      center: { x: 0.5, y: 0.28 },
    },
  }
  + basicStyle.newAlphabeticButton(
    params.keyboard.spaceButton.name,
    isDark,
    params.keyboard.spaceButton.params,
    needHint=false
  )
  // 英文键盘的中英切换按钮 - 切换回 pinyin 键盘
  + basicStyle.newSystemButton(
    'en2cnButton',
    isDark,
    {
      size: { width: '110/1125' },
      action: { keyboardType: 'pinyin' },
    }
  )
  + {
    local primaryColor = if isDark then colors.standardButtonForegroundColor.dark else colors.standardButtonForegroundColor.light,
    en2cnButtonForegroundStyle: {
      buttonStyleType: 'text',
      text: 'En',
      fontSize: 18,
      normalColor: primaryColor,
      highlightColor: primaryColor,
      center: { x: 0.5, y: 0.5 },
    },
  }
  + basicStyle.newSystemButton(
    params.keyboard.enterButton.name,
    isDark,
    {
      size: { width: '240/1125' },
      backgroundStyle: basicStyle.enterButtonBackgroundStyle,
      foregroundStyle: basicStyle.enterButtonForegroundStyle,
    } + params.keyboard.enterButton.params
  )
;

{
  new(isDark, isPortrait):
    local insets = if isPortrait then params.keyboard.button.backgroundInsets.iPhone.portrait else params.keyboard.button.backgroundInsets.iPhone.landscape;

    local extraParams = {
      insets: insets,
    };

    preedit.new(isDark)
    + toolbar.new(isDark)
    + basicStyle.newKeyboardBackgroundStyle(isDark)
    + basicStyle.newAlphabeticButtonBackgroundStyle(isDark, extraParams)
    + basicStyle.newAlphabeticButtonHintStyle(isDark)
    + basicStyle.newSystemButtonBackgroundStyle(isDark, extraParams)
    + basicStyle.newBlueButtonBackgroundStyle(isDark, extraParams)
    + basicStyle.newBlueButtonForegroundStyle(isDark, params.keyboard.enterButton.params)
    + basicStyle.newAlphabeticHintBackgroundStyle(isDark, { cornerRadius: 10 })
    + newKeyLayout(isDark, isPortrait)
    + basicStyle.newEnterButtonForegroundStyle(isDark, params.keyboard.enterButton.params)
    + basicStyle.newCommitCandidateForegroundStyle(isDark, { systemImageName: 'minus', fontWeight: 'medium', fontSize: 19 })
    // Notifications
    + basicStyle.returnKeyboardTypeChangedNotification
    + basicStyle.preeditChangedForEnterButtonNotification
    + basicStyle.preeditChangedForSpaceButtonNotification,
}
