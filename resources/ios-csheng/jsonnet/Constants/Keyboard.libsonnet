local colors = import 'Colors.libsonnet';
local fonts = import 'Fonts.libsonnet';

{
  local root = self,

  preedit: {
    height: 20,
    insets: {
      top: 0,
      left: 10,
    },
    fontSize: fonts.preeditFontSize,
  },

  toolbar: {
    height: 35,
  },

  candidateStyle: {
    highlightBackgroundColor: colors.candidateHighlightColor,
    preferredBackgroundColor: colors.candidateHighlightColor,
    preferredIndexColor: colors.candidateForegroundColor,
    preferredTextColor: colors.candidateForegroundColor,
    preferredCommentColor: colors.candidateForegroundColor,
    indexColor: colors.candidateForegroundColor,
    textColor: colors.candidateForegroundColor,
    commentColor: colors.candidateForegroundColor,
    indexFontSize: fonts.candidateIndexFontSize,
    textFontSize: fonts.candidateTextFontSize,
    commentFontSize: fonts.candidateCommentFontSize,
  },

  horizontalCandidateStyle:
    {
      insets: {
        top: 5,
        left: 16,
        bottom: 3,
      },
      expandButton: {
        systemImageName: 'chevron.forward',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: fonts.candidateStateButtonFontSize,
      },
    },

  verticalCandidateStyle:
    {
      // insets 用于展开候选字后的区域内边距
      // insets: { top: 3, bottom: 3, left: 4, right: 4 },
      bottomRowHeight: 45,
      candidateCollectionStyle: {
        insets: { top: 8, bottom: 8, left: 8, right: 8 },
        backgroundColor: colors.keyboardBackgroundColor,
        maxRows: 5,
        maxColumns: 6,
        separatorColor: colors.candidateSeparatorColor,
      },
      pageUpButton: {
        action: { shortcut: '#verticalCandidatesPageUp' },
        systemImageName: 'chevron.up',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: fonts.candidateStateButtonFontSize,
      },
      pageDownButton: {
        action: { shortcut: '#verticalCandidatesPageDown' },
        systemImageName: 'chevron.down',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: fonts.candidateStateButtonFontSize,
      },
      returnButton: {
        action: { shortcut: '#candidatesBarStateToggle' },
        systemImageName: 'return',
        normalColor: colors.toolbarButtonForegroundColor,
        highlightColor: colors.toolbarButtonHighlightedForegroundColor,
        fontSize: fonts.candidateStateButtonFontSize,
      },
    },

  keyboard: {
    height: {
      iPhone: {
        portrait: 204,  // 54 * 4
        landscape: 152,  // 40 * 4
      },
      iPad: {
        portrait: 311,  // 64 * 4 + 55
        landscape: 414,  // 86 * 4 + 70
      },
    },

    button: {
      backgroundInsets: {
        iPhone: {
          portrait: { top: 3, left: 2, bottom: 3, right: 2 },
          landscape: { top: 2, left: 2, bottom: 2, right: 2 },
        },
        ipad: {
          portrait: { top: 3, left: 3, bottom: 3, right: 3 },
          landscape: { top: 4, left: 6, bottom: 4, right: 6 },
        },
      },
    },
    //
    T9button: {
      backgroundInsets: {
        iPhone: {
          portrait: { top: 3, left: 3, bottom: 3, right: 3 },
          landscape: { top: 2, left: 2, bottom: 2, right: 2 },
        },
        ipad: {
          portrait: { top: 3, left: 3, bottom: 3, right: 3 },
          landscape: { top: 4, left: 6, bottom: 4, right: 6 },
        },
      },
			},

    // 按键定义
    qButton: {
      name: 'qButton',
      params: {
        action: { character: 'q' },
        swipeUpAction: { symbol: '!' },
        swipeDownAction: { symbol: '1' },
        uppercasedStateAction: { character: 'Q' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    wButton: {
      name: 'wButton',
      params: {
        action: { character: 'w' },
        swipeUpAction: { symbol: '@' },
        swipeDownAction: { symbol: '2' },
        uppercasedStateAction: { character: 'W' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    eButton: {
      name: 'eButton',
      params: {
        action: { character: 'e' },
        swipeUpAction: { symbol: '#' },
        swipeDownAction: { symbol: '3' },
        uppercasedStateAction: { character: 'E' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    rButton: {
      name: 'rButton',
      params: {
        action: { character: 'r' },
        swipeUpAction: { symbol: '$' },
        swipeDownAction: { symbol: '4' },
        uppercasedStateAction: { character: 'R' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    tButton: {
      name: 'tButton',
      params: {
        action: { character: 't' },
        swipeUpAction: { symbol: '%' },
        swipeDownAction: { symbol: '5' },
        uppercasedStateAction: { character: 'T' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    yButton: {
      name: 'yButton',
      params: {
        action: { character: 'y' },
        swipeUpAction: { symbol: '^' },
        swipeDownAction: { symbol: '6' },
        uppercasedStateAction: { character: 'Y' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    uButton: {
      name: 'uButton',
      params: {
        action: { character: 'u' },
        swipeUpAction: { symbol: '&' },
        swipeDownAction: { symbol: '7' },
        uppercasedStateAction: { character: 'U' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    iButton: {
      name: 'iButton',
      params: {
        action: { character: 'i' },
        swipeUpAction: { symbol: '*' },
        swipeDownAction: { symbol: '8' },
        uppercasedStateAction: { character: 'I' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    oButton: {
      name: 'oButton',
      params: {
        action: { character: 'o' },
        swipeUpAction: { symbol: '(' },
        swipeDownAction: { symbol: '9' },
        uppercasedStateAction: { character: 'O' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    pButton: {
      name: 'pButton',
      params: {
        action: { character: 'p' },
        swipeUpAction: { symbol: ')' },
        swipeDownAction: { symbol: '0' },
        uppercasedStateAction: { character: 'P' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },

    // 第二行字母键
    aButton: {
      name: 'aButton',
      params: {
        action: { character: 'a' },
        swipeUpAction: { symbol: '~' },
        swipeDownAction: { symbol: '`' },
        uppercasedStateAction: { character: 'A' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    sButton: {
      name: 'sButton',
      params: {
        action: { character: 's' },
        swipeUpAction: { symbol: '_' },
        swipeDownAction: { symbol: '-' },
        uppercasedStateAction: { character: 'S' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    dButton: {
      name: 'dButton',
      params: {
        action: { character: 'd' },
        swipeUpAction: { symbol: '+' },
        swipeDownAction: { symbol: '=' },
        uppercasedStateAction: { character: 'D' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    fButton: {
      name: 'fButton',
      params: {
        action: { character: 'f' },
        swipeUpAction: { symbol: '{' },
        swipeDownAction: { symbol: '[' },
        uppercasedStateAction: { character: 'F' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    gButton: {
      name: 'gButton',
      params: {
        action: { character: 'g' },
        swipeUpAction: { symbol: '}' },
        swipeDownAction: { symbol: ']' },
        uppercasedStateAction: { character: 'G' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    hButton: {
      name: 'hButton',
      params: {
        action: { character: 'h' },
        swipeUpAction: { symbol: '|' },
        swipeDownAction: { symbol: '\u005C' },
        uppercasedStateAction: { character: 'H' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    jButton: {
      name: 'jButton',
      params: {
        action: { character: 'j' },
        uppercasedStateAction: { character: 'J' },
      },
    },
    kButton: {
      name: 'kButton',
      params: {
        action: { character: 'k' },
        swipeUpAction: { symbol: ':' },
        swipeDownAction: { symbol: ';' },
        uppercasedStateAction: { character: 'K' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    lButton: {
      name: 'lButton',
      params: {
        action: { character: 'l' },
        swipeUpAction: { symbol: '"' },
        swipeDownAction: { symbol: "'" },
        uppercasedStateAction: { character: 'L' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },

// 第三行字母键 (ZXCV)
    zButton: {
      name: 'zButton',
      params: {
        action: { character: 'z' },
        uppercasedStateAction: { character: 'Z' },
        // swipeUpAction: { shortcut: '#undo' },
        // swipeDownAction: { shortcut: '#redo' },
      },
    },
    xButton: {
      name: 'xButton',
      params: {
        action: { character: 'x' },
        uppercasedStateAction: { character: 'X' },
        // swipeUpAction: { shortcut: '#cut' },
      },
    },
    cButton: {
      name: 'cButton',
      params: {
        action: { character: 'c' },
        uppercasedStateAction: { character: 'C' },
        // swipeUpAction: { shortcut: '#copy' },
      },
    },
    vButton: {
      name: 'vButton',
      params: {
        action: { character: 'v' },
        uppercasedStateAction: { character: 'V' },
        // swipeDownAction: { shortcut: '#paste' },
      },
    },
    bButton: {
      name: 'bButton',
      params: {
        action: { character: 'b' },
        swipeUpAction: { symbol: '<' },
        swipeDownAction: { symbol: ',' },
        uppercasedStateAction: { character: 'B' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    nButton: {
      name: 'nButton',
      params: {
        action: { character: 'n' },
        swipeUpAction: { symbol: '>' },
        swipeDownAction: { symbol: '.' },
        uppercasedStateAction: { character: 'N' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },
    mButton: {
      name: 'mButton',
      params: {
        action: { character: 'm' },
        swipeUpAction: { symbol: '?' },
        swipeDownAction: { symbol: '/' },
        uppercasedStateAction: { character: 'M' },
        showSwipeHints: true,
        showHoldSymbols: true,
      },
    },

    // 数字键
    oneButton: {
      name: 'oneButton',
      params: {
        action: { symbol: '1' },
      },
    },
    twoButton: {
      name: 'twoButton',
      params: {
        action: { symbol: '2' },
      },
    },
    threeButton: {
      name: 'threeButton',
      params: {
        action: { symbol: '3' },
      },
    },
    fourButton: {
      name: 'fourButton',
      params: {
        action: { symbol: '4' },
      },
    },
    fiveButton: {
      name: 'fiveButton',
      params: {
        action: { symbol: '5' },
      },
    },
    sixButton: {
      name: 'sixButton',
      params: {
        action: { symbol: '6' },
      },
    },
    sevenButton: {
      name: 'sevenButton',
      params: {
        action: { symbol: '7' },
      },
    },
    eightButton: {
      name: 'eightButton',
      params: {
        action: { symbol: '8' },
      },
    },
    nineButton: {
      name: 'nineButton',
      params: {
        action: { symbol: '9' },
      },
    },
    zeroButton: {
      name: 'zeroButton',
      params: {
        action: { symbol: '0' },
      },
    },

    // 特殊功能键
    spaceButton: {
      name: 'spaceButton',
      params: {
        action: 'space',
        systemImageName: 'space',
        notification: [
          'preeditChangedForSpaceButtonNotification',
        ],
      },
    },
    // 中英切换按键 - 切换到 alphabetic 键盘
    cn2enButton: {
      name: 'cn2enButton',
      params: {
        // 切换到英文键盘
        action: { keyboardType: 'alphabetic' },
      },
      // 动态生成样式：根据中英文模式显示不同状态
      foregroundStyle(isDark=false):: {
        local primaryColor = if isDark then colors.standardButtonForegroundColor.dark else colors.standardButtonForegroundColor.light,
        cn2enButtonChineseForegroundStyle: {
          buttonStyleType: 'text',
          text: '中',
          fontSize: 18,
          normalColor: primaryColor,
          highlightColor: primaryColor,
          center: { x: 0.5, y: 0.5 },
        },
        cn2enButtonEnglishForegroundStyle: {
          buttonStyleType: 'text',
          text: 'En',
          fontSize: 18,
          normalColor: primaryColor,
          highlightColor: primaryColor,
          center: { x: 0.5, y: 0.5 },
        },
      },
    },
    // 切换符号
    spaceLeftButton: {
      name: 'spaceLeftButton',
      params: {
        action: { keyboardType: 'symbolic' },
				//swipeUpAction: { symbol: '，' },
        text: '#+=',
      },
    },
    tabButton: {
      name: 'tabButton',
      params: {
        action: 'tab',
        systemImageName: 'arrow.right.to.line',
      },
    },

    backspaceButton: {
      name: 'backspaceButton',
      params: {
        action: 'backspace',
        repeatAction: 'backspace',
        systemImageName: 'delete.left',
        highlightSystemImageName: 'delete.left.fill',
      },
    },

    shiftButton: {
      name: 'shiftButton',
      params: {
        systemImageName: 'shift',
        action: 'shift',
      },
      uppercasedParams: {
        systemImageName: 'shift.fill',
      },
      capsLockedParams: {
        systemImageName: 'capslock.fill',
      },
    },

    asciiModeButton: {
      name: 'asciiModeButton',
      params: {
        action: { shortcut: '#中英切换' },
        text: '中/英',
      },
    },

    dismissButton: {
      name: 'dismissButton',
      params: {
        action: 'dismissKeyboard',
        systemImageName: 'keyboard.chevron.compact.down',
      },
    },

    enterButton: {
      name: 'enterButton',
      params: {
        action: 'enter',
				//center: { x:0.5, y:0.47 },  //
				swipeUpAction: { 'shortcut': '#换行'}, //
        text: '$returnKeyType',
        notification: [
          'returnKeyTypeChangedNotification',
          'preeditChangedForEnterButtonNotification',
        ],
      },
    },

    symbolicButton: {
      name: 'symbolicButton',
      params: {
        action: { keyboardType: 'symbolic' },
        text: '#+=',
      },
    },

    numericButton: {
      name: 'numericButton',
      params: {
        action: { keyboardType: 'numeric' },
        swipeDownAction: { shortcut: '#方案切换' },//
        text: '123',
      },
    },

    pinyinButton: {
      name: 'pinyinButton',
      params: {
        action: { keyboardType: 'pinyin' },
        text: '拼音',
      },
    },

    otherKeyboardButton: {
      name: 'otherKeyboardButton',
      params: {
        action: 'nextKeyboard',
        systemImageName: 'globe',
      },
    },

    // 标点符号键

    // 连接号(减号)
    hyphenButton: {
      name: 'hyphenButton',
      params: {
        action: { character: '-' },
        swipeDownAction: { character: '——' },
				swipeUpAction: { character: '+' }, //
      },
    },
    // 斜杠
    forwardSlashButton: {
      name: 'forwardSlashButton',
      params: {
        action: { character: '/' },
        swipeUpAction: { character: '*' },//
      },
    },
    // 冒号
    colonButton: {
      name: 'colonButton',
      params: {
        action: { character: ':' },
      },
    },

    // 中文冒号
    chineseColonButton: {
      name: 'chineseColonButton',
      params: {
        action: { symbol: '：' },
				swipeUpAction: { character: '=' }, //
      },
    },

    // 分号
    semicolonButton: {
      name: 'semicolonButton',
      params: {
        action: { character: ',' },
        swipeUpAction: { character: '.' },

        foregroundStyleName: [
          {
            conditionKey: 'rime$ascii_mode',
            styleName: [
              'semicolonButtonAsciiForegroundStyle',
              'semicolonButtonAsciiSwipeUpHintForegroundStyle',
            ],
          },
          {
            conditionKey: 'rime$ascii_mode',
            conditionValue: false,
            styleName: [
              'semicolonButtonCJKForegroundStyle',
              'semicolonButtonCJKSwipeUpHintForegroundStyle',
            ],
          },
        ],
      },
      // 动态生成样式的函数
      foregroundStyle(isDark=false):: {
        local primaryColor = if isDark then colors.standardButtonForegroundColor.dark else colors.standardButtonForegroundColor.light,
        local hintColor = if isDark then colors.labelColor.tertiary.dark else colors.labelColor.tertiary.light,

        semicolonButtonAsciiForegroundStyle: {
          buttonStyleType: 'text',
          fontSize: 22.5,
          normalColor: primaryColor,
          highlightColor: primaryColor,
          center: { x: 0.5, y: 0.45 },
          text: ',',
        },
        semicolonButtonCJKForegroundStyle: {
          buttonStyleType: 'text',
          fontSize: 22.5,
          normalColor: primaryColor,
          highlightColor: primaryColor,
          center: { x: 0.5, y: 0.45 },
          text: '，',
        },
        semicolonButtonAsciiSwipeUpHintForegroundStyle: {
          buttonStyleType: 'text',
          text: '.',
          fontSize: 10,
          normalColor: hintColor,
          highlightColor: hintColor,
          center: { x: 0.5, y: 0.28 },
        },
        semicolonButtonCJKSwipeUpHintForegroundStyle: {
          buttonStyleType: 'text',
          text: '。',
          fontSize: 10,
          normalColor: hintColor,
          highlightColor: hintColor,
          center: { x: 0.5, y: 0.28 },
        },
      },
    },

    // 中文分号
    chineseSemicolonButton: {
      name: 'chineseSemicolonButton',
      params: {
        action: { symbol: '；' },
        swipeUpAction: { symbol: '：' },
      },
    },

    // 左括号
    leftParenthesisButton: {
      name: 'leftParenthesisButton',
      params: {
        action: { symbol: '(' },
      },
    },

    // 右括号
    rightParenthesisButton: {
      name: 'rightParenthesisButton',
      params: {
        action: { symbol: ')' },
      },
    },

    // 中文左括号
    leftChineseParenthesisButton: {
      name: 'leftChineseParenthesisButton',
      params: {
        action: { symbol: '（' },
      },
    },

    // 中文右括号
    rightChineseParenthesisButton: {
      name: 'rightChineseParenthesisButton',
      params: {
        action: { symbol: '）' },
      },
    },

    // 美元符号
    dollarButton: {
      name: 'dollarButton',
      params: {
        action: { symbol: '$' },
      },
    },

    // 地址符号
    atButton: {
      name: 'atButton',
      params: {
        action: { symbol: '@' },
      },
    },

    // “ 双引号(有方向性的引号)
    leftCurlyQuoteButton: {
      name: 'leftCurlyQuoteButton',
      params: {
        action: { symbol: '“' },
      },
    },
    // ” 双引号(有方向性的引号)
    rightCurlyQuoteButton: {
      name: 'rightCurlyQuoteButton',
      params: {
        action: { symbol: '”' },
      },
    },
    // " 直引号(没有方向性的引号)
    straightQuoteButton: {
      name: 'straightQuoteButton',
      params: {
        action: { symbol: '"' },
      },
    },
    chineseCommaButton: {
      name: 'chineseCommaButton',
      params: {
        action: { symbol: '，' },
        swipeUpAction: { symbol: '《' },
      },
    },
    commaButton: {
      name: 'commaButton',
      params: {
        action: { symbol: ',' },
      },
    },
    chinesePeriodButton: {
      name: 'chinesePeriodButton',
      params: {
        action: { symbol: '。' },
        swipeUpAction: { symbol: '》' },
      },
    },
    periodButton: {
      name: 'periodButton',
      params: {
        action: { symbol: '.' },
      },
    },
    // 顿号(只在中文中使用)
    ideographicCommaButton: {
      name: 'ideographicCommaButton',
      params: {
        action: { symbol: '、' },
        swipeUpAction: { symbol: '|' },
      },
    },
    // 中文问号
    chineseQuestionMarkButton: {
      name: 'questionMarkButton',
      params: {
        action: { symbol: '？' },
      },
    },
    // 英文问号
    questionMarkButton: {
      name: 'questionMarkEnButton',
      params: {
        action: { symbol: '?' },
      },
    },
    // 中文感叹号
    chineseExclamationMarkButton: {
      name: 'chineseExclamationMarkButton',
      params: {
        action: { symbol: '！' },
      },
    },
    // 英文感叹号
    exclamationMarkButton: {
      name: 'exclamationMarkButton',
      params: {
        action: { symbol: '!' },
      },
    },
    // ' 直撇号(单引号)
    apostropheButton: {
      name: 'apostropheButton',
      params: {
        action: { symbol: "'" },
      },
    },
    // 中文左单引号(有方向性的单引号)
    leftSingleQuoteButton: {
      name: 'leftSingleQuoteButton',
      params: {
        action: { symbol: '‘' },
        swipeUpAction: { symbol: '“' },
      },
    },
    // 中文右单引号(有方向性的单引号)
    rightSingleQuoteButton: {
      name: 'rightSingleQuoteButton',
      params: {
        action: { symbol: '’' },
      },
    },
    // 等号
    equalButton: {
      name: 'equalButton',
      params: {
        action: { character: '=' },
        swipeUpAction: { character: '+' },
      },
    },
    leftBracketButton: {
      name: 'leftBracketButton',
      params: {
        action: { symbol: '[' },
      },
    },
    rightBracketButton: {
      name: 'rightBracketButton',
      params: {
        action: { symbol: ']' },
      },
    },

    // 中文左中括号
    leftChineseBracketButton: {
      name: 'leftChineseBracketButton',
      params: {
        action: { symbol: '【' },
        swipeUpAction: { symbol: '「' },
      },
    },

    // 中文右中括号
    rightChineseBracketButton: {
      name: 'rightChineseBracketButton',
      params: {
        action: { symbol: '】' },
        swipeUpAction: { symbol: '」' },
      },
    },

    // 英文左大括号
    leftBraceButton: {
      name: 'leftBraceButton',
      params: {
        action: { symbol: '{' },
      },
    },

    // 英文右大括号
    rightBraceButton: {
      name: 'rightBraceButton',
      params: {
        action: { symbol: '}' },
      },
    },

    // 中文左大括号
    leftChineseBraceButton: {
      name: 'leftChineseBraceButton',
      params: {
        action: { symbol: '｛' },
      },
    },

    // 中文右大括号
    rightChineseBraceButton: {
      name: 'rightChineseBraceButton',
      params: {
        action: { symbol: '｝' },
      },
    },


    // 井号
    hashButton: {
      name: 'hashButton',
      params: {
        action: { symbol: '#' },
      },
    },

    // 百分号
    percentButton: {
      name: 'percentButton',
      params: {
        action: { symbol: '%' },
      },
    },

    // ^符号
    caretButton: {
      name: 'caretButton',
      params: {
        action: { symbol: '^' },
      },
    },

    // '*' 符号
    asteriskButton: {
      name: 'asteriskButton',
      params: {
        action: { character: '*' },
      },
    },

    // + 符号
    plusButton: {
      name: 'plusButton',
      params: {
        action: { character: '+' },
      },
    },

    // _ 符号(下划线)
    underscoreButton: {
      name: 'underscoreButton',
      params: {
        action: { symbol: '_' },
      },
    },

    // —— 符号(破折号)
    emDashButton: {
      name: 'emDashButton',
      params: {
        action: { character: '=' },
      },
    },

    // \ 符号(反斜杠)
    backslashButton: {
      name: 'backslashButton',
      params: {
        action: { symbol: '\\' },
      },
    },

    // | 符号(竖线)
    verticalBarButton: {
      name: 'verticalBarButton',
      params: {
        action: { symbol: '|' },
      },
    },

    // ~ 符号
    tildeButton: {
      name: 'tildeButton',
      params: {
        action: { symbol: '~' },
      },
    },

    // < 符号(小于号)
    lessThanButton: {
      name: 'lessThanButton',
      params: {
        action: { symbol: '<' },
      },
    },

    // > 符号(大于号)
    greaterThanButton: {
      name: 'greaterThanButton',
      params: {
        action: { symbol: '>' },
      },
    },

    // 中文左书名号
    leftBookTitleMarkButton: {
      name: 'leftBookTitleMarkButton',
      params: {
        action: { symbol: '《' },
      },
    },

    // 中文右书名号
    rightBookTitleMarkButton: {
      name: 'rightBookTitleMarkButton',
      params: {
        action: { symbol: '》' },
      },
    },

    // € 符号(欧元符号)
    euroButton: {
      name: 'euroButton',
      params: {
        action: { symbol: '€' },
      },
    },

    // £ 符号(英镑符号)
    poundButton: {
      name: 'poundButton',
      params: {
        action: { symbol: '£' },
      },
    },

    // 人民币符号
    rmbButton: {
      name: 'rmbButton',
      params: {
        action: { symbol: '¥' },
      },
    },

    // & 符号(和号)
    ampersandButton: {
      name: 'ampersandButton',
      params: {
        action: { symbol: '&' },
      },
    },

    // · 中点符号
    middleDotButton: {
      name: 'middleDotButton',
      params: {
        action: { symbol: '·' },
      },
    },

    // …… 符号(省略号)
    ellipsisButton: {
      name: 'ellipsisButton',
      params: {
        action: { symbol: '…' },
      },
    },

    // ` 符号(重音符)
    graveButton: {
      name: 'graveButton',
      params: {
        action: { character: '`' },
        swipeUpAction: { character: '~' },
      },
    },

    // ± 符号(正负号)
    plusMinusButton: {
      name: 'plusMinusButton',
      params: {
        action: { symbol: '±' },
      },
    },

    // 「 中文左引号
    leftChineseAngleQuoteButton: {
      name: 'leftChineseAngleQuoteButton',
      params: {
        action: { symbol: '「' },
      },
    },

    // 数字键盘符号列表
    numericSymbolsCollection: {
      name: 'numericSymbolsCollection',
      params: {
        type: 'numericSymbols',
        insets: { top: 8, left: 4, bottom: 4, right: 4 },
        backgroundStyle: 'systemButtonBackgroundStyle',
      },
    },

    // 数字键盘横向时全部部分视图
    numericCategorySymbolCollection: {
      name: 'numericCategorySymbolCollection',
      params: {
        type: 'categorySymbols',
        insets: { top: 4, left: 4, bottom: 4, right: 4 },
        backgroundStyle: 'systemButtonBackgroundStyle',
      },
    },
    
    // 返回上一个使用的键盘
    returnLastKeyboardButton: {
      name: 'returnLastKeyboardButton',
      params: {
        text: '返回',
        action: 'returnLastKeyboard',
      },
    },
    
    // 」 中文右引号
    rightChineseAngleQuoteButton: {
      name: 'rightChineseAngleQuoteButton',
      params: {
        action: { symbol: '」' },
      },
    },
  },
}
