//local iPhoneNumeric = import 'Components/NumericPortrait.libsonnet';
local iPhonePinyin = import 'Components/iPhonePinyin.libsonnet';
local iPhoneAlphabetic = import 'Components/iPhoneAlphabetic.libsonnet';
local iPhoneSymbolic = import 'Components/iPhoneSymbolic.libsonnet';
local iPadPinyin = import 'Components/iPadPinyin.libsonnet';
local iPadNumeric = import 'Components/iPadNumeric.libsonnet';
local panel = import 'Components/panel.libsonnet';

local lightPanelPortrait = panel.new('light', 'portrait');
local darkPanelPortrait = panel.new('dark', 'portrait');
local lightPanelLandscape = panel.new('light', 'landscape');
local darkPanelLandscape = panel.new('dark', 'landscape');

local pinyinPortraitFileName = 'pinyinPortrait';
local lightPinyinPortraitFileContent = iPhonePinyin.new(isDark=false, isPortrait=true);
local darkPinyinPortraitFileContent = iPhonePinyin.new(isDark=true, isPortrait=true);

local pinyinLandscapeFileName = 'pinyinLandscape';
local lightPinyinLandscapeFileContent = iPhonePinyin.new(isDark=false, isPortrait=false);
local darkPinyinLandscapeFileContent = iPhonePinyin.new(isDark=true, isPortrait=false);

// 英文字母键盘
local alphabeticPortraitFileName = 'alphabeticPortrait';
local lightAlphabeticPortraitFileContent = iPhoneAlphabetic.new(isDark=false, isPortrait=true);
local darkAlphabeticPortraitFileContent = iPhoneAlphabetic.new(isDark=true, isPortrait=true);

local alphabeticLandscapeFileName = 'alphabeticLandscape';
local lightAlphabeticLandscapeFileContent = iPhoneAlphabetic.new(isDark=false, isPortrait=false);
local darkAlphabeticLandscapeFileContent = iPhoneAlphabetic.new(isDark=true, isPortrait=false);

//local numericPortraitFileName = 'numericPortrait';
//local lightNumericPortraitFileContent = iPhoneNumeric.new(isDark=false, isPortrait=true);
//local darkNumericPortraitFileContent = iPhoneNumeric.new(isDark=true, isPortrait=true);

//local numericLandscapeName = 'numericLandscape';
//local lightNumericLandscapeFileContent = iPhoneNumeric.new(isDark=false, isPortrait=false);
//local darkNumericLandscapeFileContent = iPhoneNumeric.new(isDark=true, isPortrait=false);

local symbolicPortraitFileName = 'symbolicPortrait';
local lightSymbolicPortraitFileContent = iPhoneSymbolic.new(isDark=false, isPortrait=true);
local darkSymbolicPortraitFileContent = iPhoneSymbolic.new(isDark=true, isPortrait=true);

local symbolicLandscapeName = 'symbolicLandscape';
local lightSymbolicLandscapeFileContent = iPhoneSymbolic.new(isDark=false, isPortrait=false);
local darkSymbolicLandscapeFileContent = iPhoneSymbolic.new(isDark=true, isPortrait=false);

local iPadPinyinPortraitName = 'iPadPinyinPortrait';
local lightIpadPinyinPortraitContent = iPadPinyin.new(isDark=false, isPortrait=true);
local darkIpadPinyinPortraitContent = iPadPinyin.new(isDark=true, isPortrait=true);

local iPadPinyinLandscapeName = 'iPadPinyinLandscape';
local lightIpadPinyinLandscapeContent = iPadPinyin.new(isDark=false, isPortrait=false);
local darkIpadPinyinLandscapeContent = iPadPinyin.new(isDark=true, isPortrait=false);

local iPadNumericPortraitName = 'iPadNumericPortrait';
local lightIpadNumericPortraitContent = iPadNumeric.new(isDark=false, isPortrait=true);
local darkIpadNumericPortraitContent = iPadNumeric.new(isDark=true, isPortrait=true);

local iPadNumericLandscapeName = 'iPadNumericLandscape';
local lightIpadNumericLandscapeContent = iPadNumeric.new(isDark=false, isPortrait=false);
local darkIpadNumericLandscapeContent = iPadNumeric.new(isDark=true, isPortrait=false);

local portraitNumeric = import 'Components/NumericPortrait.libsonnet';
local portraitNumericFileName = 'portraitNumeric';
local lightPortraitNumericFileContent = portraitNumeric.new(isDark=false, isPortrait=true);
local darkPortraitNumericFileContent = portraitNumeric.new(isDark=true, isPortrait=true);

local landscapeNumeric = import 'Components/NumericLandscape.libsonnet';
local landscapeNumericFileName = 'landscapeNumeric';
local lightLandscapeNumericFileContent = landscapeNumeric.new(isDark=false, isPortrait=false);
local darkLandscapeNumericFileContent = landscapeNumeric.new(isDark=true, isPortrait=true);

local config = {
  author: 'CsHeng',
  name: 'iOS-CsHeng',
  version: '1.0.0',
  description: 'ANSI排列，配色参考iOS26',
  pinyin: {
    iPhone: {
      portrait: pinyinPortraitFileName,
      landscape: pinyinLandscapeFileName,
    },
  },
  // 英文字母键盘
  alphabetic: {
    iPhone: {
      portrait: alphabeticPortraitFileName,
      landscape: alphabeticLandscapeFileName,
    },
  },
  panel: {
    iPhone: {
      portrait: 'panel_portrait',
      landscape: 'panel_landscape',
    },
  },
  numeric: {
    iPhone: {
      portrait: portraitNumericFileName,
      landscape: landscapeNumericFileName,
	    },
	    },
	};

local fastYaml = std.toString;

{
  'config.yaml': std.manifestYamlDoc(config, indent_array_in_object=true, quote_keys=false),

  // 拼音键盘
  ['light/' + pinyinPortraitFileName + '.yaml']: fastYaml(lightPinyinPortraitFileContent),
  ['dark/' + pinyinPortraitFileName + '.yaml']: fastYaml(darkPinyinPortraitFileContent),
  ['light/' + pinyinLandscapeFileName + '.yaml']: fastYaml(lightPinyinLandscapeFileContent),
  ['dark/' + pinyinLandscapeFileName + '.yaml']: fastYaml(darkPinyinLandscapeFileContent),

  // 英文字母键盘
  ['light/' + alphabeticPortraitFileName + '.yaml']: fastYaml(lightAlphabeticPortraitFileContent),
  ['dark/' + alphabeticPortraitFileName + '.yaml']: fastYaml(darkAlphabeticPortraitFileContent),
  ['light/' + alphabeticLandscapeFileName + '.yaml']: fastYaml(lightAlphabeticLandscapeFileContent),
  ['dark/' + alphabeticLandscapeFileName + '.yaml']: fastYaml(darkAlphabeticLandscapeFileContent),

  'light/panel_portrait.yaml': fastYaml(lightPanelPortrait),
  'dark/panel_portrait.yaml': fastYaml(darkPanelPortrait),
  'light/panel_landscape.yaml': fastYaml(lightPanelLandscape),
  'dark/panel_landscape.yaml': fastYaml(darkPanelLandscape),

  // 数字键盘
  ['light/' + portraitNumericFileName + '.yaml']: fastYaml(lightPortraitNumericFileContent),
  ['dark/' + portraitNumericFileName + '.yaml']: fastYaml(darkPortraitNumericFileContent),
  ['light/' + landscapeNumericFileName + '.yaml']: fastYaml(lightLandscapeNumericFileContent),
  ['dark/' + landscapeNumericFileName + '.yaml']: fastYaml(darkLandscapeNumericFileContent),

  // 符号键盘
  //['light/' + symbolicPortraitFileName + '.yaml']: fastYaml(lightSymbolicPortraitFileContent),
  //['dark/' + symbolicPortraitFileName + '.yaml']: fastYaml(darkSymbolicPortraitFileContent),
  //['light/' + symbolicLandscapeName + '.yaml']: fastYaml(lightSymbolicLandscapeFileContent),
  //['dark/' + symbolicLandscapeName + '.yaml']: fastYaml(darkSymbolicLandscapeFileContent),

  // iPad 拼音键盘
  // ['light/' + iPadPinyinPortraitName + '.yaml']: std.toString(lightIpadPinyinPortraitContent),
  // ['dark/' + iPadPinyinPortraitName + '.yaml']: std.toString(darkIpadPinyinPortraitContent),
  // ['light/' + iPadPinyinLandscapeName + '.yaml']: std.toString(lightIpadPinyinLandscapeContent),
  // ['dark/' + iPadPinyinLandscapeName + '.yaml']: std.toString(darkIpadPinyinLandscapeContent),

  // // iPad 数字键盘
  // ['light/' + iPadNumericPortraitName + '.yaml']: std.toString(lightIpadNumericPortraitContent),
  // ['dark/' + iPadNumericPortraitName + '.yaml']: std.toString(darkIpadNumericPortraitContent),
  // ['light/' + iPadNumericLandscapeName + '.yaml']: std.toString(lightIpadNumericLandscapeContent),
  // ['dark/' + iPadNumericLandscapeName + '.yaml']: std.toString(darkIpadNumericLandscapeContent),
}
