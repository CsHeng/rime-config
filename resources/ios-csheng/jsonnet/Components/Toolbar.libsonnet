local colors = import '../Constants/Colors.libsonnet';
local keyboardParams = import '../Constants/Keyboard.libsonnet';
local basicStyle = import 'BasicStyle.libsonnet';
local utils = import 'Utils.libsonnet';
local Fonts = import '../Constants/Fonts.libsonnet';


local newCandidateStyle(param={}, isDark=false) =
  utils.extractProperties(
    param,
    [
      'insets',
      'indexFontSize',
      'textFontSize',
      'commentFontSize',
    ]
  )
  + utils.extractColors(
    param,
    [
      'backgroundColor',
      'separatorColor',
      'highlightBackgroundColor',
      'preferredBackgroundColor',
      'preferredIndexColor',
      'preferredTextColor',
      'preferredCommentColor',
      'indexColor',
      'textColor',
      'commentColor',
    ],
    isDark
  );

local toolbarBackgroundStyleName = basicStyle.keyboardBackgroundStyleName;
local horizontalCandidateBackgroundStyleName = basicStyle.keyboardBackgroundStyleName;
local verticalCandidateBackgroundStyleName = basicStyle.keyboardBackgroundStyleName;

// MARK: - 横排候选字

local horizontalCandidatesCollectionViewName = 'horizontalCandidates';
local expandButtonName = 'expandButton';
local horizontalCandidatesLayout = [
  {
    HStack: {
      subviews: [
        {
          Cell: horizontalCandidatesCollectionViewName,
        },
        {
          Cell: expandButtonName,
        },
      ],
    },
  },
];

local newHorizontalCandidatesCollectionView(isDark=false) = {
  [horizontalCandidatesCollectionViewName]: {
    type: 'horizontalCandidates',
    candidateStyle: 'horizontalCandidateStyle',
  },
  horizontalCandidateStyle: newCandidateStyle(keyboardParams.candidateStyle, isDark),
};

local newExpandButton(isDark) = {
  [expandButtonName]:
    {
      size: { width: 44 },
      action: { shortcut: '#candidatesBarStateToggle' },
    }
    + utils.newForegroundStyle(style=expandButtonName + 'ForegroundStyle'),
  [expandButtonName + 'ForegroundStyle']:
    utils.newSystemImageStyle(keyboardParams.horizontalCandidateStyle.expandButton, isDark),
};


// MARK: - 纵排候选字

local verticalCandidateCollectionViewName = 'verticalCandidates';
local verticalLastRowStyleName = 'verticalLastRowStyle';
local verticalCandidatePageUpButtonStyleName = 'verticalPageUpButtonStyle';
local verticalCandidatePageDownButtonStyleName = 'verticalPageDownButtonStyle';
local verticalCandidateReturnButtonStyleName = 'verticalReturnButtonStyle';
local verticalCandidateBackspaceButtonStyleName = 'verticalBackspaceButtonStyle';

local verticalCandidatesLayout = [
  {
    HStack: {
      subviews: [
        {
          Cell: verticalCandidateCollectionViewName,
        },
      ],
    },
  },
  {
    HStack: {
      style: verticalLastRowStyleName,
      subviews: [
        {
          Cell: verticalCandidatePageUpButtonStyleName,
        },
        {
          Cell: verticalCandidatePageDownButtonStyleName,
        },
        {
          Cell: verticalCandidateReturnButtonStyleName,
        },
        {
          Cell: verticalCandidateBackspaceButtonStyleName,
        },
      ],
    },
  },
];


local newVerticalCandidateCollectionStyle(isDark) = {
  [verticalCandidateCollectionViewName]:
    {
      type: 'verticalCandidates',
      insets: keyboardParams.verticalCandidateStyle.candidateCollectionStyle.insets,
      maxRows: keyboardParams.verticalCandidateStyle.candidateCollectionStyle.maxRows,
      maxColumns: keyboardParams.verticalCandidateStyle.candidateCollectionStyle.maxColumns,
      candidateStyle: 'verticalCandidateStyle',
    } +
    utils.extractColors(
      keyboardParams.verticalCandidateStyle.candidateCollectionStyle,
      [
        'separatorColor',
      ],
      isDark
    ),
  verticalCandidateStyle: newCandidateStyle(keyboardParams.candidateStyle { insets: { left: 6, right: 6, top: 4, bottom: 4 } }, isDark),
};

local verticalLastRowStyle = {
  [verticalLastRowStyleName]:
    {
      size: { height: keyboardParams.verticalCandidateStyle.bottomRowHeight },
    },
};

local newVerticalCandidatePageUpButtonStyle(isDark) = {
  [verticalCandidatePageUpButtonStyleName]:
    utils.newBackgroundStyle(style=basicStyle.systemButtonBackgroundStyleName)
    + utils.newForegroundStyle(style=verticalCandidatePageUpButtonStyleName + 'ForegroundStyle')
    + {
      action: keyboardParams.verticalCandidateStyle.pageUpButton.action,
    },
  [verticalCandidatePageUpButtonStyleName + 'ForegroundStyle']:
    utils.newSystemImageStyle(keyboardParams.verticalCandidateStyle.pageUpButton, isDark),
};

local newVerticalCandidatePageDownButtonStyle(isDark) = {
  [verticalCandidatePageDownButtonStyleName]:
    utils.newBackgroundStyle(style=basicStyle.systemButtonBackgroundStyleName)
    + utils.newForegroundStyle(style=verticalCandidatePageDownButtonStyleName + 'ForegroundStyle')
    + {
      action: keyboardParams.verticalCandidateStyle.pageDownButton.action,
    },
  [verticalCandidatePageDownButtonStyleName + 'ForegroundStyle']:
    utils.newSystemImageStyle(keyboardParams.verticalCandidateStyle.pageDownButton, isDark),
};


local newVerticalCandidateReturnButtonStyle(isDark) = {
  [verticalCandidateReturnButtonStyleName]:
    utils.newBackgroundStyle(style=basicStyle.systemButtonBackgroundStyleName)
    + utils.newForegroundStyle(style=verticalCandidateReturnButtonStyleName + 'ForegroundStyle')
    + {
      action: keyboardParams.verticalCandidateStyle.returnButton.action,
    },
  [verticalCandidateReturnButtonStyleName + 'ForegroundStyle']:
    utils.newSystemImageStyle(keyboardParams.verticalCandidateStyle.returnButton, isDark),
};

local newVerticalCandidateBackspaceButtonStyle(isDark) = {
  [verticalCandidateBackspaceButtonStyleName]:
    utils.newBackgroundStyle(style=basicStyle.systemButtonBackgroundStyleName)
    + utils.newForegroundStyle(style=verticalCandidateBackspaceButtonStyleName + 'ForegroundStyle')
    + {
      action: 'backspace',
    },
  [verticalCandidateBackspaceButtonStyleName + 'ForegroundStyle']:
    utils.newSystemImageStyle(
      {
        systemImageName: 'delete.left',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: keyboardParams.verticalCandidateStyle.pageUpButton.fontSize,
      },
      isDark
    ),
};

local toolbarButtonLayout = [
  {
    HStack: {
      subviews: [
          { Cell: 'toolbarMenuButton' },
          { Cell: 'toolbarTranslateButton' },
          { Cell: 'toolbarScriptButton' },
          { Cell: 'toolbarEmojiButton' },
          { Cell: 'toolbarPhraseButton' },
          { Cell: 'toolbarPasteboardButton' },
          { Cell: 'toolbarPasteButton' },
          { Cell: 'toolbarCloseButton' },
      ],
    },
  },
];

local newtoolbarMenuButtonStyle(isDark) = {
  'toolbarMenuButton':
     utils.newForegroundStyle(style='toolbarMenuButton' + 'ForegroundStyle')
    + {
      action: { floatKeyboardType: 'panel' },
    },
  ['toolbarMenuButton' + 'ForegroundStyle']:
    utils.newSystemImageStyle(
      {
        systemImageName: 'slider.horizontal.3',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: Fonts.toolbarButtonImageFontSize,
      },
      isDark),
};

//toolbarTranslateButton
local newtoolbarTranslateButtonStyle(isDark) = {
  'toolbarTranslateButton':
     utils.newForegroundStyle(style='toolbarTranslateButton' + 'ForegroundStyle')
    + {
      action: { runScript: 'Qwen-MT-Turbo' },
    },
  ['toolbarTranslateButton' + 'ForegroundStyle']:
    utils.newSystemImageStyle(
      {
        systemImageName: 'translate',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: Fonts.toolbarButtonImageFontSize,
      },
      isDark),
};

//toolbarScriptButton
local newtoolbarScriptButtonStyle(isDark) = {
  'toolbarScriptButton':
     utils.newForegroundStyle(style='toolbarScriptButton' + 'ForegroundStyle')
    + {
      action: { shortcut: '#toggleScriptView' },
    },
  ['toolbarScriptButton' + 'ForegroundStyle']:
    utils.newSystemImageStyle(
      {
        systemImageName: 'chevron.left.forwardslash.chevron.right',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: Fonts.toolbarButtonImageFontSize,
      },
      isDark),
};

//toolbarEmojiButton
local newtoolbarEmojiButtonStyle(isDark) = {
  'toolbarEmojiButton':
     utils.newForegroundStyle(style='toolbarEmojiButton' + 'ForegroundStyle')
    + {
      action: { keyboardType: 'emojis' },
    },
  ['toolbarEmojiButton' + 'ForegroundStyle']:
    utils.newSystemImageStyle(
      {
        systemImageName: 'faceid',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: Fonts.toolbarButtonImageFontSize,
      },
      isDark),
};

//toolbarPhraseButton
local newtoolbarPhraseButtonStyle(isDark) = {
  'toolbarPhraseButton':
     utils.newForegroundStyle(style='toolbarPhraseButton' + 'ForegroundStyle')
    + {
      action: { shortcut: '#showPhraseView' },
    },
  ['toolbarPhraseButton' + 'ForegroundStyle']:
    utils.newSystemImageStyle(
      {
        systemImageName: 'text.bubble',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: Fonts.toolbarButtonImageFontSize,
      },
      isDark),
};

//toolbarPasteboardButton
local newtoolbarPasteboardButtonStyle(isDark) = {
  'toolbarPasteboardButton':
     utils.newForegroundStyle(style='toolbarPasteboardButton' + 'ForegroundStyle')
    + {
      action: { shortcut: '#showPasteboardView' },
    },
  ['toolbarPasteboardButton' + 'ForegroundStyle']:
    utils.newSystemImageStyle(
      {
        systemImageName: 'list.clipboard',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: Fonts.toolbarButtonImageFontSize,
      },
      isDark),
};

//toolbarPasteButton
local newtoolbarPasteButtonStyle(isDark) = {
  'toolbarPasteButton':
    utils.newForegroundStyle(style='toolbarPasteButton' + 'ForegroundStyle')
    + {
      action: { shortcut: '#paste' },
    },
  ['toolbarPasteButton' + 'ForegroundStyle']:
    utils.newSystemImageStyle(
      {
        systemImageName: 'doc.on.doc',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: Fonts.toolbarButtonImageFontSize,
      },
      isDark),
};

//toolbarCloseButton
local newtoolbarCloseButtonStyle(isDark) = {
  'toolbarCloseButton':
     utils.newForegroundStyle(style='toolbarCloseButton' + 'ForegroundStyle')
    + {
      action: 'dismissKeyboard',
    },
  ['toolbarCloseButton' + 'ForegroundStyle']:
    utils.newSystemImageStyle(
      {
        systemImageName: 'chevron.down.circle',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: Fonts.toolbarButtonImageFontSize,
      },
      isDark),
};

local newToolbar(isDark=false, params={}) =
  {
    toolbarHeight: keyboardParams.toolbar.height,
    toolbarStyle: utils.newBackgroundStyle(style=toolbarBackgroundStyleName),
    toolbarLayout: {},
    horizontalCandidatesStyle:
      utils.extractProperties(keyboardParams.horizontalCandidateStyle + params, ['insets'])
      {
        backgroundStyle: horizontalCandidateBackgroundStyleName,
      },
    horizontalCandidatesLayout: horizontalCandidatesLayout,
    verticalCandidatesStyle:
      utils.extractProperties(keyboardParams.verticalCandidateStyle + params, ['insets'])
      {
        backgroundStyle: verticalCandidateBackgroundStyleName,
      },
    verticalCandidatesLayout: verticalCandidatesLayout,
    candidateContextMenu: [
      // TODO: 长按候选字菜单
      // {
      //   name: '空格',
      //   action: 'space',
      // },
    ],
  }
  + {
    toolbarLayout: toolbarButtonLayout,
  }
  + newtoolbarMenuButtonStyle(isDark)
  + newtoolbarTranslateButtonStyle(isDark)
  + newtoolbarScriptButtonStyle(isDark)
  + newtoolbarEmojiButtonStyle(isDark)
  + newtoolbarPhraseButtonStyle(isDark)
  + newtoolbarPasteboardButtonStyle(isDark)
  + newtoolbarPasteButtonStyle(isDark)
  + newtoolbarCloseButtonStyle(isDark)
  + utils.newBackgroundStyle(style=toolbarBackgroundStyleName)
  + newHorizontalCandidatesCollectionView(isDark)
  + newExpandButton(isDark)
  + newVerticalCandidateCollectionStyle(isDark)
  + verticalLastRowStyle
  + newVerticalCandidatePageUpButtonStyle(isDark)
  + newVerticalCandidatePageDownButtonStyle(isDark)
  + newVerticalCandidateReturnButtonStyle(isDark)
  + newVerticalCandidateBackspaceButtonStyle(isDark);

// 导出
{
  new: newToolbar,
}
