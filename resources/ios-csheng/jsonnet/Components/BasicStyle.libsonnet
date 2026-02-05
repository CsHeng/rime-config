local colors = import '../Constants/Colors.libsonnet';
local fonts = import '../Constants/Fonts.libsonnet';
local keyboardParams = import '../Constants/Keyboard.libsonnet';
local utils = import 'Utils.libsonnet';

local buttonCornerRadius = 8.5;

local getKeyboardActionText(params={}, key='action', isUppercase=false) =
  if std.objectHas(params, 'text') then
    { text: params.text }
  else if std.objectHas(params, key) then
    local action = params[key];
    if std.type(action) == 'object' then
      if std.objectHas(action, 'character') then
        local text = if isUppercase then std.asciiUpper(action.character) else action.character;
        { text: text }
      else if std.objectHas(action, 'symbol') then
        local text = if isUppercase then std.asciiUpper(action.symbol) else action.symbol;
        { text: text }
      else
        {}
    else
      {}
  else
    {};


local newSwipeHintForegroundStyle(isDark=false, params={}, key='swipeUpAction', center={ x: 0.25, y: 0.28 }) =
  utils.newTextStyle({
    normalColor: colors.labelColor.tertiary,
    highlightColor: colors.labelColor.tertiary,
    fontSize: 10,
    center: center,
  }, isDark)
  + getKeyboardActionText(params, key=key);

local holdSymbolsBackgroundStyleName = 'holdSymbolsBackgroundStyle';
local holdSymbolsSelectedBackgroundStyleName = 'holdSymbolsSelectedBackgroundStyle';

local newHoldSymbolsSharedStyles(isDark=false) = {
  [holdSymbolsBackgroundStyleName]: utils.newFileImageStyle({
    normalImage: { file: 'hold_back', image: 'IMG1' },
    highlightImage: { file: 'hold_back', image: 'IMG1' },
  }, isDark),
  [holdSymbolsSelectedBackgroundStyleName]: utils.newGeometryStyle({
    normalColor: colors.standardCalloutSelectedBackgroundColor,
    highlightColor: colors.standardCalloutSelectedBackgroundColor,
    cornerRadius: buttonCornerRadius,
  }, isDark),
};

// 通用键盘背景样式
local keyboardBackgroundStyleName = 'keyboardBackgroundStyle';
local newKeyboardBackgroundStyle(isDark=false, params={}) = {
  [keyboardBackgroundStyleName]: utils.newGeometryStyle({
    normalColor: colors.keyboardBackgroundColor,
  } + params, isDark),
};

// 字母键按钮背景样式
local alphabeticButtonBackgroundStyleName = 'alphabeticButtonBackgroundStyle';
local newAlphabeticButtonBackgroundStyle(isDark=false, params={}) = {
  [alphabeticButtonBackgroundStyleName]: utils.newGeometryStyle({
    insets: keyboardParams.keyboard.button.backgroundInsets.iPhone.portrait,
    normalColor: colors.standardButtonBackgroundColor,
    highlightColor: colors.standardButtonHighlightedBackgroundColor,
    cornerRadius: buttonCornerRadius,
    //normalLowerEdgeColor: colors.lowerEdgeOfButtonNormalColor,
    //highlightLowerEdgeColor: colors.lowerEdgeOfButtonHighlightColor,
  } + params, isDark),
};

//
local T9buttonBackgroundStyleName = 'T9buttonBackgroundStyle';
local newT9ButtonBackgroundStyle(isDark=false, params={}) = {
  [T9buttonBackgroundStyleName]: utils.newGeometryStyle({
    insets: keyboardParams.keyboard.T9button.backgroundInsets.iPhone.portrait,
    normalColor: colors.standardButtonBackgroundColor,
    highlightColor: colors.standardButtonHighlightedBackgroundColor,
    cornerRadius: buttonCornerRadius,
    //normalLowerEdgeColor: colors.lowerEdgeOfButtonNormalColor,
    //highlightLowerEdgeColor: colors.lowerEdgeOfButtonHighlightColor,
  } + params, isDark),
	};

// 字母键按钮前景样式
local newAlphabeticButtonForegroundStyle(isDark=false, params={}) =
  if std.objectHas(params, 'systemImageName') then
    utils.newSystemImageStyle({
      normalColor: colors.standardButtonForegroundColor,
      highlightColor: colors.standardButtonHighlightedForegroundColor,
      fontSize: fonts.standardButtonImageFontSize,
    } + params, isDark)
  else
    utils.newTextStyle({
      normalColor: colors.standardButtonForegroundColor,
      highlightColor: colors.standardButtonHighlightedForegroundColor,
      fontSize: fonts.standardButtonTextFontSize,
    } + params, isDark) + getKeyboardActionText(params, isUppercase=false);

// 大写字母键按钮前景样式
local newAlphabeticButtonUppercaseForegroundStyle(isDark=false, params={}) =
  utils.newTextStyle({
    normalColor: colors.standardButtonForegroundColor,
    highlightColor: colors.standardButtonHighlightedForegroundColor,
    fontSize: fonts.standardButtonUppercasedTextFontSize,
  } + params, isDark);

// 字母提示背景样式
local alphabeticHintBackgroundStyleName = 'alphabeticHintBackgroundStyle';
local newAlphabeticHintBackgroundStyle(isDark=false, params={}) = {
  [alphabeticHintBackgroundStyleName]: utils.newGeometryStyle({
    normalColor: colors.standardButtonHighlightedBackgroundColor,
    borderColor: colors.standardCalloutBorderColor,
    borderSize: 0.5,
  } + params, isDark),
};

// 字母提示前景样式
local newAlphabeticButtonHintStyle(isDark=false, params={}) =
  utils.newTextStyle({
    normalColor: colors.standardCalloutForegroundColor,
    fontSize: fonts.hintTextFontSize,
  } + params, isDark);

// 系统功能键按钮背景样式
local systemButtonBackgroundStyleName = 'systemButtonBackgroundStyle';
local newSystemButtonBackgroundStyle(isDark=false, params={}) = {
  [systemButtonBackgroundStyleName]: utils.newGeometryStyle({
    insets: keyboardParams.keyboard.button.backgroundInsets.iPhone.portrait,
    normalColor: colors.systemButtonBackgroundColor,
    highlightColor: colors.systemButtonHighlightedBackgroundColor,
    cornerRadius: buttonCornerRadius,
    //normalLowerEdgeColor: colors.lowerEdgeOfButtonNormalColor,
    //highlightLowerEdgeColor: colors.lowerEdgeOfButtonHighlightColor,
  } + params, isDark),
};

local enterButtonForegroundStyleName = 'enterButtonForegroundStyle';
local newEnterButtonForegroundStyle(isDark=false, params={}) = {
  [enterButtonForegroundStyleName]: utils.newTextStyle({
    normalColor: colors.systemButtonForegroundColor,
    highlightColor: colors.systemButtonHighlightedForegroundColor,
    fontSize: fonts.systemButtonTextFontSize,
  } + params, isDark) + getKeyboardActionText(params),
};


// 蓝色功能键按钮背景样式
local blueButtonBackgroundStyleName = 'blueButtonBackgroundStyle';
local newBlueButtonBackgroundStyle(isDark=false, params={}) = {
  [blueButtonBackgroundStyleName]: utils.newGeometryStyle({
    insets: keyboardParams.keyboard.button.backgroundInsets.iPhone.portrait,
    normalColor: colors.blueButtonBackgroundColor,
    highlightColor: colors.blueButtonHighlightedBackgroundColor,
    cornerRadius: buttonCornerRadius,
    //normalLowerEdgeColor: colors.lowerEdgeOfButtonNormalColor,
    //highlightLowerEdgeColor: colors.lowerEdgeOfButtonHighlightColor,
  } + params, isDark),
};

local blueButtonForegroundStyleName = 'blueButtonForegroundStyle';
local newBlueButtonForegroundStyle(isDark=false, params={}) = {
  [blueButtonForegroundStyleName]: utils.newTextStyle({
    normalColor: colors.blueButtonForegroundColor,
    highlightColor: colors.blueButtonHighlightedForegroundColor,
    fontSize: fonts.systemButtonTextFontSize,
  } + params, isDark) + getKeyboardActionText(params),
};

local enterButtonBackgroundStyle = [
  {
    styleName: systemButtonBackgroundStyleName,
    conditionKey: '$returnKeyType',
    conditionValue: [0, 2, 3, 5, 6, 8, 11],
  },
  {
    styleName: blueButtonBackgroundStyleName,
    conditionKey: '$returnKeyType',
    conditionValue: [1, 4, 7, 9, 10],
  },
];

local enterButtonForegroundStyle = [
  {
    styleName: enterButtonForegroundStyleName,
    conditionKey: '$returnKeyType',
    conditionValue: [0, 2, 3, 5, 6, 8, 11],
  },
  {
    styleName: blueButtonForegroundStyleName,
    conditionKey: '$returnKeyType',
    conditionValue: [1, 4, 7, 9, 10],
  },
];

// 文本文字系统功能键按钮前景样式
local newTextSystemButtonForegroundStyle(isDark=false, params={}) =
  utils.newTextStyle({
    normalColor: colors.systemButtonForegroundColor,
    highlightColor: colors.systemButtonHighlightedForegroundColor,
    fontSize: fonts.systemButtonTextFontSize,
  } + params, isDark);

local newImageSystemButtonForegroundStyle(isDark=false, params={}) =
  utils.newSystemImageStyle({
    normalColor: colors.systemButtonForegroundColor,
    highlightColor: colors.systemButtonHighlightedForegroundColor,
    fontSize: fonts.systemButtonImageFontSize,
  } + params, isDark);


local newAlphabeticButton(name, isDark=false, params={}, needHint=true) =
  local swipeHintsEnabled =
    std.objectHas(params, 'showSwipeHints')
    && params.showSwipeHints
    && std.objectHas(params, 'swipeUpAction')
    && std.objectHas(params, 'swipeDownAction');

  local holdSymbolsEnabled =
    std.objectHas(params, 'showHoldSymbols')
    && params.showHoldSymbols
    && std.type(params.action) == 'object'
    && std.objectHas(params, 'swipeUpAction')
    && std.objectHas(params, 'swipeDownAction');

  local defaultForegroundStyle =
    if swipeHintsEnabled then
      [
        name + 'ForegroundStyle',
        name + 'SwipeUpHintForegroundStyle',
        name + 'SwipeDownHintForegroundStyle',
      ]
    else
      name + 'ForegroundStyle';

  local defaultUppercasedForegroundStyle =
    if swipeHintsEnabled then
      [
        name + 'UppercaseForegroundStyle',
        name + 'SwipeUpHintForegroundStyle',
        name + 'SwipeDownHintForegroundStyle',
      ]
    else
      name + 'UppercaseForegroundStyle';

  {
    [name]:
      utils.newBackgroundStyle(style=alphabeticButtonBackgroundStyleName)
      + (
        if std.objectHas(params, 'foregroundStyleName') then
          { foregroundStyle: params.foregroundStyleName }
        else
          { foregroundStyle: defaultForegroundStyle }
      )
      + (
        if std.objectHas(params, 'uppercasedStateAction') then
          if std.objectHas(params, 'uppercasedStateForegroundStyleName') then
            { uppercasedStateForegroundStyle: params.uppercasedStateForegroundStyleName }
          else
            { uppercasedStateForegroundStyle: defaultUppercasedForegroundStyle }
        else {}
      )
      + (
        if needHint then
          utils.newForegroundStyle('hintStyle', name + 'HintStyle')
        else {}
      )
      + (
        if holdSymbolsEnabled && !std.objectHas(params, 'hintSymbolsStyle') then
          { hintSymbolsStyle: name + 'HintSymbolsStyle' }
        else {}
      )
      + utils.extractProperties(
        params,
        [
          'size',
          'bounds',
          'action',
          'uppercasedStateAction',
          'repeatAction',
          'preeditStateAction',
          'swipeUpAction',
          'swipeDownAction',
          'swipeLeftAction',
          'swipeRightAction',
          'capsLockedStateForegroundStyle',
          'preeditStateForegroundStyle',
          'notification',
          'hintSymbolsStyle',
        ]
      ),
  }
  + (
    if std.objectHas(params, 'foregroundStyle') then
      params.foregroundStyle
    else
      { [name + 'ForegroundStyle']: newAlphabeticButtonForegroundStyle(isDark, params) }
  )
  + (
    if swipeHintsEnabled then
      {
        [name + 'SwipeUpHintForegroundStyle']:
          newSwipeHintForegroundStyle(isDark, params, 'swipeUpAction', { x: 0.25, y: 0.28 }),
        [name + 'SwipeDownHintForegroundStyle']:
          newSwipeHintForegroundStyle(isDark, params, 'swipeDownAction', { x: 0.25, y: 0.72 }),
      }
    else {}
  )
  + (
    if std.objectHas(params, 'uppercasedStateAction') then
      {
        [name + 'UppercaseForegroundStyle']:
          newAlphabeticButtonUppercaseForegroundStyle(isDark, params)
          + getKeyboardActionText(params, 'uppercasedStateAction'),
      }
    else {}
  )
  + (
    if needHint then
      {
        [name + 'HintStyle']:
          (
            if std.objectHas(params, 'hintStyle') then
              params.hintStyle
            else {}
          )
          + utils.newBackgroundStyle(style=alphabeticHintBackgroundStyleName)
          + utils.newForegroundStyle(style=name + 'HintForegroundStyle'),
        [name + 'HintForegroundStyle']:
          newAlphabeticButtonHintStyle(isDark, params)
          + getKeyboardActionText(params, isUppercase=true),
      }
    else {}
  )
  + (
    if holdSymbolsEnabled then
      newHoldSymbolsSharedStyles(isDark)
      + {
        [name + 'HintSymbolsSwipeUpForegroundStyle']:
          utils.newTextStyle({
            normalColor: colors.standardButtonForegroundColor,
            highlightColor: colors.blueButtonForegroundColor,
            fontSize: fonts.standardButtonTextFontSize,
          }, isDark)
          + getKeyboardActionText(params, key='swipeUpAction'),

        [name + 'HintSymbolsSwipeDownForegroundStyle']:
          utils.newTextStyle({
            normalColor: colors.standardButtonForegroundColor,
            highlightColor: colors.blueButtonForegroundColor,
            fontSize: fonts.standardButtonTextFontSize,
          }, isDark)
          + getKeyboardActionText(params, key='swipeDownAction'),

        [name + 'HintSymbolsSwipeDownStyle']: {
          foregroundStyle: name + 'HintSymbolsSwipeDownForegroundStyle',
          action: params.swipeDownAction,
        },
        [name + 'HintSymbolsSwipeUpStyle']: {
          foregroundStyle: name + 'HintSymbolsSwipeUpForegroundStyle',
          action: params.swipeUpAction,
        },

        [name + 'HintSymbolsStyle']: {
          size: { width: 50, height: 50 },
          insets: { top: 4, bottom: 4, left: 4, right: 4 },
          backgroundStyle: holdSymbolsBackgroundStyleName,
          selectedBackgroundStyle: holdSymbolsSelectedBackgroundStyleName,
          selectedIndex: 0,
          symbolStyles: [
            name + 'HintSymbolsSwipeUpStyle',
            name + 'HintSymbolsSwipeDownStyle',
          ],
        },
      }
    else {}
  );


local newSystemButton(name, isDark=false, params={}) =
  {
    [name]: (
              if std.objectHas(params, 'backgroundStyle') then
                { backgroundStyle: params.backgroundStyle }
              else
                utils.newBackgroundStyle(style=systemButtonBackgroundStyleName)

            )
            + (
              if std.objectHas(params, 'foregroundStyle') then
                { foregroundStyle: params.foregroundStyle }
              else
                utils.newForegroundStyle(style=name + 'ForegroundStyle')
            )
            + utils.extractProperties(
              params,
              [
                'size',
                'bounds',
                'action',
                'uppercasedStateAction',
                'repeatAction',
                'preeditStateAction',
                'swipeUpAction',
                'swipeDownAction',
                'swipeLeftAction',
                'swipeRightAction',
                'uppercasedStateForegroundStyle',
                'capsLockedStateForegroundStyle',
                'preeditStateForegroundStyle',
                'notification',
              ]
            ),
  }
  + {
    [name + 'ForegroundStyle']: (
      if std.objectHas(params, 'systemImageName') then
        newImageSystemButtonForegroundStyle(isDark, params)
      else
        newTextSystemButtonForegroundStyle(isDark, params) + getKeyboardActionText(params)
    ),
		};

		//
  local newT9Button(name, isDark=false, params={}, needHint=true) =
  {
    [name]: utils.newBackgroundStyle(style=T9buttonBackgroundStyleName)
            + (
              if std.objectHas(params, 'foregroundStyleName') then
                { foregroundStyle: params.foregroundStyleName }
              else
                utils.newForegroundStyle(style=name + 'ForegroundStyle')
            )
            + (
              if std.objectHas(params, 'uppercasedStateAction') then
                utils.newForegroundStyle('uppercasedStateForegroundStyle', name + 'UppercaseForegroundStyle')
              else {}
            )
            + (
              if needHint then
                utils.newForegroundStyle('hintStyle', name + 'HintStyle')
              else {

              }
            )
            + utils.extractProperties(
              params,
              [
                'size',
                'bounds',
                'action',
                'uppercasedStateAction',
                'repeatAction',
                'preeditStateAction',
                'swipeUpAction',
                'swipeDownAction',
                'swipeLeftAction',
                'swipeRightAction',
                'capsLockedStateForegroundStyle',
                'preeditStateForegroundStyle',
                'notification',
              ]
            ),
  }
  + (
    if std.objectHas(params, 'foregroundStyle') then
      params.foregroundStyle
    else
      { [name + 'ForegroundStyle']: newAlphabeticButtonForegroundStyle(isDark, params) }
  )
  + (
    if std.objectHas(params, 'uppercasedStateAction') then
      {

        [name + 'UppercaseForegroundStyle']: newAlphabeticButtonUppercaseForegroundStyle(isDark, params) + getKeyboardActionText(params, 'uppercasedStateAction'),
      }
    else {}
  )
  + (
    if needHint then
      {

        [name + 'HintStyle']:
          (
            if std.objectHas(params, 'hintStyle') then
              params.hintStyle
            else
              {}
          )
          + utils.newBackgroundStyle(style=alphabeticHintBackgroundStyleName)
          + utils.newForegroundStyle(style=name + 'HintForegroundStyle'),
        [name + 'HintForegroundStyle']: newAlphabeticButtonHintStyle(isDark, params) + getKeyboardActionText(params, isUppercase=true),
      }
    else
      {}
			);

local returnKeyboardTypeChangedNotification = {
  returnKeyTypeChangedNotification: {
    notificationType: 'returnKeyType',
    returnKeyType: [1, 4, 7],
    backgroundStyle: blueButtonBackgroundStyleName,
    foregroundStyle: blueButtonForegroundStyleName,
  },
};

local preeditChangedForEnterButtonNotification = {
  preeditChangedForEnterButtonNotification: {
    notificationType: 'preeditChanged',
    backgroundStyle: enterButtonBackgroundStyle,
    foregroundStyle: enterButtonForegroundStyle,
  },
};

local commitCandidateForegroundStyleName = 'commitCandidateForegroundStyle';
local preeditChangedForSpaceButtonNotification = {
  preeditChangedForSpaceButtonNotification: {
    notificationType: 'preeditChanged',
    backgroundStyle: alphabeticButtonBackgroundStyleName,
    foregroundStyle: commitCandidateForegroundStyleName,
  },
};

local newCommitCandidateForegroundStyle(isDark=false, params={}) = {
  [commitCandidateForegroundStyleName]: utils.newSystemImageStyle({
    normalColor: colors.spacepreColor,
    highlightColor: colors.spacepreColor,
    fontSize: fonts.systemButtonTextFontSize,
  } + params, isDark) + params,
};


{
  keyboardBackgroundStyleName: keyboardBackgroundStyleName,
  newKeyboardBackgroundStyle: newKeyboardBackgroundStyle,

  alphabeticButtonBackgroundStyleName: alphabeticButtonBackgroundStyleName,
  newAlphabeticButtonBackgroundStyle: newAlphabeticButtonBackgroundStyle,
  //
  newT9ButtonBackgroundStyle: newT9ButtonBackgroundStyle,

  newAlphabeticButtonForegroundStyle: newAlphabeticButtonForegroundStyle,

  newAlphabeticButtonUppercaseForegroundStyle: newAlphabeticButtonUppercaseForegroundStyle,

  alphabeticHintBackgroundStyleName: alphabeticHintBackgroundStyleName,
  newAlphabeticHintBackgroundStyle: newAlphabeticHintBackgroundStyle,

  newAlphabeticButtonHintStyle: newAlphabeticButtonHintStyle,

  systemButtonBackgroundStyleName: systemButtonBackgroundStyleName,
  newSystemButtonBackgroundStyle: newSystemButtonBackgroundStyle,

  blueButtonBackgroundStyleName: blueButtonBackgroundStyleName,
  newBlueButtonBackgroundStyle: newBlueButtonBackgroundStyle,

  blueButtonForegroundStyleName: blueButtonForegroundStyleName,
  newBlueButtonForegroundStyle: newBlueButtonForegroundStyle,

  newTextSystemButtonForegroundStyle: newTextSystemButtonForegroundStyle,
  newImageSystemButtonForegroundStyle: newImageSystemButtonForegroundStyle,

  newAlphabeticButton: newAlphabeticButton,
	newT9Button: newT9Button,

  newSystemButton: newSystemButton,

  enterButtonBackgroundStyle: enterButtonBackgroundStyle,
  enterButtonForegroundStyle: enterButtonForegroundStyle,
  newEnterButtonForegroundStyle: newEnterButtonForegroundStyle,
  newCommitCandidateForegroundStyle: newCommitCandidateForegroundStyle,

  // notification
  returnKeyboardTypeChangedNotification: returnKeyboardTypeChangedNotification,
  preeditChangedForEnterButtonNotification: preeditChangedForEnterButtonNotification,
  preeditChangedForSpaceButtonNotification: preeditChangedForSpaceButtonNotification,
}
