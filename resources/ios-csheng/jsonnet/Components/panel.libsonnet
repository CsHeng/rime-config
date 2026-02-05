// local animation = import '../lib/animation.libsonnet';
// local center = import '../lib/center.libsonnet';
local color = import  '../Constants/Colors.libsonnet';
local fontSize = import '../lib/fontSize.libsonnet';
local fonts = import '../Constants/Fonts.libsonnet';

local animation = {
      animationType: 'scale',
      isAutoReverse: true,
      scale: 0.87,
      pressDuration: 60,
      releaseDuration: 80,
      };

local center = {
  'panel键盘按键sf符号前景偏移': { x: 0.5, y: 0.4 },
  'panel键盘按键文字前景偏移': { x: 0.5, y: 0.75 },
};

// key: 按键名称
local createButton(key, action, sf_symbol, text, theme) = {
  [key + 'Button']: {
    size: {
      height: '1/4',
    },
    backgroundStyle: 'ButtonBackgroundStyle',
    foregroundStyle: [
      key + 'ButtonForegroundStyle',
      key + 'ButtonForegroundStyle2',
    ],
    action: action,
  },
  [key + 'ButtonForegroundStyle']: {
    buttonStyleType: 'systemImage',
    systemImageName: sf_symbol,
    fontSize: fonts['panelbutton_fore_sfsymbolSize'],
    normalColor: color['toolbarButtonForegroundColor'][theme],
    highlightColor: color['standardButtonHighlightedForegroundColor'][theme],
    center: center['panel键盘按键sf符号前景偏移'],
  },
  [key + 'ButtonForegroundStyle2']: {
    buttonStyleType: 'text',
    text: text,
    fontSize: fonts['panelbutton_fore_textSize'],
    normalColor: color['toolbarButtonForegroundColor'][theme],
    highlightColor: color['toolbarButtonHighlightedForegroundColor'][theme],
    center: center['panel键盘按键文字前景偏移'],
  },
  animation: [
    'ButtonScaleAnimation',
  ],
};
local keyboard(theme, orientation) =
  createButton(
    'Hamster',
    { openURL: 'hamster3://com.ihsiao.apps.hamster3/' },
    'keyboard',
    '元书',
    theme
  ) +

  createButton(
    'Switcher',
    { shortcut: '#RimeSwitcher' },
    'switch.2',
    'Switcher',
    theme
  ) +
  createButton(
    'KBPerformance',
    { shortcut: '#keyboardPerformance' },
    'speedometer',
    '键盘性能',
    theme
  ) +
  createButton(
    'HamsterSkin',
    { openURL: 'hamster3://com.ihsiao.apps.hamster3/keyboardSkins' },
    'tshirt',
    '皮肤设置',
    theme
  ) +
  createButton(
    'Upload',
    { openURL: 'hamster3://com.ihsiao.apps.hamster3/wifi' },
    'square.and.arrow.up',
    '方案上传',
    theme
  ) +
  createButton(
    'Deploy',
    { openURL: 'hamster3://com.ihsiao.apps.hamster3/rime?action=deploy' },
    'command.circle',
    '部署',
    theme
  ) +
  createButton(
    'Finder',
    { openURL: 'hamster3://com.ihsiao.apps.hamster3/finder' },
    'folder',
    '文件',
    theme
  ) +
  createButton(
    'toogleEmbedded',
    { shortcut: '#toggleEmbeddedInputMode' },
    'square.and.pencil',
    '内嵌开关',
    theme
  ) +
  {
    keyboardLayout: [
      {
        HStack: {
          subviews: [
            { Cell: 'HamsterButton' },
            { Cell: 'SwitcherButton' },
            { Cell: 'KBPerformanceButton' },
            { Cell: 'FinderButton' },
          ],
        },
      },
      {
        HStack: {
          subviews: [
            { Cell: 'HamsterSkinButton' },
            { Cell: 'UploadButton' },
            { Cell: 'DeployButton' },
            { Cell: 'toogleEmbeddedButton' },
          ],
        },
      },
    ],
    floatTargetScale:
      if orientation == 'portrait' then
        { x: 0.75, y: 0.6 }
      else
        { x: 0.45, y: 0.8 }
    ,
    keyboardStyle: {
      insets: {
        top: 24,
        left: 24,
        bottom: 24,
        right: 24,
      },
      backgroundStyle: 'keyboardBackgroundStyle',
    },
    keyboardBackgroundStyle: {
      buttonStyleType: 'fileImage',
      normalImage: {
        file: 'float_back',
        image: 'IMG1',
      },
      highlightImage: {
        file: 'float_back',
        image: 'IMG1',
      },
      // "type": "original",
      // "normalColor": color[theme]["键盘背景颜色"],
      // "cornerRadius": 15,
      // "normalShadowColor": "000000",
      // "shadowRadius": 8
    },

    ButtonBackgroundStyle: {
      buttonStyleType: 'geometry',
      insets: { top: 5, left: 3, bottom: 5, right: 3 },
      normalColor: color['standardButtonBackgroundColor'][theme],
      highlightColor: color['standardButtonHighlightedBackgroundColor'][theme],
      cornerRadius: 5,
      normalLowerEdgeColor: color['lowerEdgeOfButtonNormalColor'][theme],
      highlightLowerEdgeColor: color['lowerEdgeOfButtonHighlightColor'][theme],
    },
    ButtonScaleAnimation: animation,
  };

{
  new(theme, orientation):
    keyboard(theme, orientation),
}
