object FormMain: TFormMain
  Left = 0
  Top = 0
  Caption = 'DevFormel Trace - Telemetry & Logging Demo'
  ClientHeight = 600
  ClientWidth = 850
  Color = clBtnFace
  Constraints.MinHeight = 639
  Constraints.MinWidth = 866
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object pnlHeader: TPanel
    Left = 0
    Top = 0
    Width = 850
    Height = 40
    Align = alTop
    BevelOuter = bvNone
    Color = clWindow
    ParentBackground = False
    TabOrder = 2
    ExplicitWidth = 848
    DesignSize = (
      850
      40)
    object lblProductTitle: TLabel
      Left = 16
      Top = 10
      Width = 177
      Height = 21
      Caption = 'DevFormel Trace Demo'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -16
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object lblWebsiteLink: TLinkLabel
      Left = 528
      Top = 9
      Width = 298
      Height = 25
      Alignment = taRightJustify
      Anchors = [akTop, akRight]
      Caption = 
        '<a href="https://www.devformel.com">www.devformel.com</a> | <a h' +
        'ref="https://docs.devformel.com">docs.devformel.com</a>'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clHighlight
      Font.Height = -16
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
      TabOrder = 0
      OnLinkClick = lblWebsiteLinkLinkClick
      ExplicitLeft = 526
    end
  end
  object pnlTop: TPanel
    Left = 0
    Top = 40
    Width = 850
    Height = 140
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    ExplicitWidth = 848
    object grpGlobalActions: TGroupBox
      Left = 9
      Top = 10
      Width = 834
      Height = 124
      Caption = ' Global Telemetry Actions && Hub Config '
      TabOrder = 0
      object btnTrackInfo: TButton
        Left = 16
        Top = 28
        Width = 120
        Height = 30
        Caption = 'Track Info'
        TabOrder = 0
        OnClick = btnTrackInfoClick
      end
      object btnTrackWarning: TButton
        Left = 144
        Top = 28
        Width = 120
        Height = 30
        Caption = 'Track Warning'
        TabOrder = 1
        OnClick = btnTrackWarningClick
      end
      object btnTrackException: TButton
        Left = 272
        Top = 28
        Width = 120
        Height = 30
        Caption = 'Track Exception'
        TabOrder = 2
        OnClick = btnTrackExceptionClick
      end
      object btnTrackSystemInfo: TButton
        Left = 400
        Top = 28
        Width = 120
        Height = 30
        Caption = 'Track System'
        TabOrder = 3
        OnClick = btnTrackSystemInfoClick
      end
      object btnTrackPerformance: TButton
        Left = 528
        Top = 28
        Width = 130
        Height = 30
        Caption = 'Track Performance'
        TabOrder = 4
        OnClick = btnTrackPerformanceClick
      end
      object chkHubEnabled: TCheckBox
        Left = 672
        Top = 28
        Width = 120
        Height = 20
        Caption = 'Hub Enabled'
        TabOrder = 5
        OnClick = chkHubEnabledClick
      end
      object chkPIIScrubbing: TCheckBox
        Left = 672
        Top = 50
        Width = 140
        Height = 20
        Caption = 'PII Scrubbing'
        TabOrder = 6
        OnClick = chkPIIScrubbingClick
      end
      object edtBreadcrumbText: TEdit
        Left = 16
        Top = 72
        Width = 248
        Height = 23
        TabOrder = 7
        Text = 'User opened settings dialog'
      end
      object btnAddBreadcrumb: TButton
        Left = 272
        Top = 70
        Width = 120
        Height = 26
        Caption = 'Add Breadcrumb'
        TabOrder = 8
        OnClick = btnAddBreadcrumbClick
      end
      object btnRaiseUnhandled: TButton
        Left = 400
        Top = 70
        Width = 130
        Height = 26
        Caption = 'Raise Unhandled'
        TabOrder = 9
        OnClick = btnRaiseUnhandledClick
      end
      object lblConsent: TLabel
        Left = 614
        Top = 76
        Width = 49
        Height = 15
        Caption = 'Consent:'
      end
      object cbxConsent: TComboBox
        Left = 672
        Top = 72
        Width = 140
        Height = 23
        Style = csDropDownList
        TabOrder = 10
        OnChange = cbxConsentChange
      end
    end
  end
  object pgcSinks: TPageControl
    Left = 0
    Top = 180
    Width = 850
    Height = 420
    ActivePage = tsMemo
    Align = alClient
    TabOrder = 1
    ExplicitWidth = 848
    ExplicitHeight = 412
    object tsMemo: TTabSheet
      Caption = 'UI Memo Sink'
      object pnlMemoHeader: TPanel
        Left = 0
        Top = 0
        Width = 842
        Height = 36
        Align = alTop
        BevelOuter = bvNone
        Color = clWhitesmoke
        ParentBackground = False
        TabOrder = 0
        ExplicitWidth = 840
        object lblMemoInfo: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 3
          Width = 836
          Height = 30
          Align = alClient
          Caption = 
            'Thread-safe UI logging destination. Synchronizes incoming worker' +
            '-thread events to the GUI main thread via TThread.Queue.'
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clGrayText
          Font.Height = -12
          Font.Name = 'Segoe UI'
          Font.Style = [fsItalic]
          ParentFont = False
          WordWrap = True
          ExplicitWidth = 651
          ExplicitHeight = 15
        end
      end
      object pnlMemoConfig: TPanel
        Left = 0
        Top = 36
        Width = 842
        Height = 45
        Align = alTop
        BevelOuter = bvNone
        TabOrder = 1
        ExplicitWidth = 840
        object lblMemoMaxLines: TLabel
          Left = 240
          Top = 14
          Width = 55
          Height = 15
          Caption = 'Max Lines:'
        end
        object chkMemoEnabled: TCheckBox
          Left = 16
          Top = 13
          Width = 90
          Height = 17
          Caption = 'Sink Enabled'
          TabOrder = 0
          OnClick = chkMemoEnabledClick
        end
        object chkMemoAutoScroll: TCheckBox
          Left = 120
          Top = 13
          Width = 100
          Height = 17
          Caption = 'Auto Scroll'
          TabOrder = 1
          OnClick = chkMemoAutoScrollClick
        end
        object edtMemoMaxLines: TEdit
          Left = 305
          Top = 11
          Width = 60
          Height = 23
          TabOrder = 2
          OnChange = edtMemoMaxLinesChange
        end
        object btnMemoClear: TButton
          Left = 385
          Top = 10
          Width = 90
          Height = 25
          Caption = 'Clear Output'
          TabOrder = 3
          OnClick = btnMemoClearClick
        end
      end
      object mmoLogOutput: TMemo
        Left = 0
        Top = 81
        Width = 842
        Height = 309
        Align = alClient
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -12
        Font.Name = 'Consolas'
        Font.Style = []
        ParentFont = False
        ReadOnly = True
        ScrollBars = ssVertical
        TabOrder = 2
        ExplicitWidth = 840
        ExplicitHeight = 301
      end
    end
    object tsLogFile: TTabSheet
      Caption = 'Log File Sink'
      ImageIndex = 1
      object pnlFileHeader: TPanel
        Left = 0
        Top = 0
        Width = 842
        Height = 36
        Align = alTop
        BevelOuter = bvNone
        Color = clWhitesmoke
        ParentBackground = False
        TabOrder = 0
        object lblFileInfo: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 3
          Width = 676
          Height = 15
          Align = alClient
          Caption = 
            'High-performance local file logger. Supports size-based log file' +
            ' rotation, automatic directory creation, and retention archive l' +
            'imits.'
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clGrayText
          Font.Height = -12
          Font.Name = 'Segoe UI'
          Font.Style = [fsItalic]
          ParentFont = False
          WordWrap = True
        end
      end
      object pnlFileConfig: TPanel
        Left = 0
        Top = 36
        Width = 842
        Height = 354
        Align = alClient
        BevelOuter = bvNone
        TabOrder = 1
        object lblFileName: TLabel
          Left = 16
          Top = 50
          Width = 84
          Height = 15
          Caption = 'Target File Path:'
        end
        object lblMaxFileSize: TLabel
          Left = 16
          Top = 95
          Width = 98
          Height = 15
          Caption = 'Max File Size (MB):'
        end
        object chkFileEnabled: TCheckBox
          Left = 16
          Top = 16
          Width = 120
          Height = 17
          Caption = 'Sink Enabled'
          TabOrder = 0
          OnClick = chkFileEnabledClick
        end
        object edtFileName: TEdit
          Left = 130
          Top = 47
          Width = 350
          Height = 23
          TabOrder = 1
          OnChange = edtFileNameChange
        end
        object edtMaxFileSize: TEdit
          Left = 130
          Top = 92
          Width = 80
          Height = 23
          TabOrder = 2
          OnChange = edtMaxFileSizeChange
        end
        object btnOpenLogDir: TButton
          Left = 16
          Top = 140
          Width = 160
          Height = 30
          Caption = 'Open Log Directory'
          TabOrder = 3
          OnClick = btnOpenLogDirClick
        end
        object btnTargetFile: TButton
          Left = 486
          Top = 44
          Width = 38
          Height = 30
          Caption = '...'
          TabOrder = 4
          OnClick = btnTargetFileClick
        end
      end
    end
    object tsSeq: TTabSheet
      Caption = 'Seq Ingestion Sink'
      ImageIndex = 2
      object pnlSeqHeader: TPanel
        Left = 0
        Top = 0
        Width = 842
        Height = 36
        Align = alTop
        BevelOuter = bvNone
        Color = clWhitesmoke
        ParentBackground = False
        TabOrder = 0
        object lblSeqInfo: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 3
          Width = 692
          Height = 15
          Align = alClient
          Caption = 
            'Structured logging sink emitting CLEF (Compact Log Event Format)' +
            ' JSON payloads via HTTP/HTTPS directly to a Datalust Seq server.'
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clGrayText
          Font.Height = -12
          Font.Name = 'Segoe UI'
          Font.Style = [fsItalic]
          ParentFont = False
          WordWrap = True
        end
      end
      object pnlSeqConfig: TPanel
        Left = 0
        Top = 36
        Width = 842
        Height = 354
        Align = alClient
        BevelOuter = bvNone
        TabOrder = 1
        object lblSeqServerUrl: TLabel
          Left = 16
          Top = 50
          Width = 81
          Height = 15
          Caption = 'Seq Server URL:'
        end
        object lblSeqApiKey: TLabel
          Left = 16
          Top = 95
          Width = 43
          Height = 15
          Caption = 'API Key:'
        end
        object chkSeqEnabled: TCheckBox
          Left = 16
          Top = 16
          Width = 120
          Height = 17
          Caption = 'Sink Enabled'
          TabOrder = 0
          OnClick = chkSeqEnabledClick
        end
        object edtSeqServerUrl: TEdit
          Left = 120
          Top = 47
          Width = 350
          Height = 23
          TabOrder = 1
          OnChange = edtSeqServerUrlChange
        end
        object edtSeqApiKey: TEdit
          Left = 120
          Top = 92
          Width = 350
          Height = 23
          TabOrder = 2
          OnChange = edtSeqApiKeyChange
        end
      end
    end
    object tsSentry: TTabSheet
      Caption = 'Sentry Sink'
      ImageIndex = 3
      object pnlSentryHeader: TPanel
        Left = 0
        Top = 0
        Width = 842
        Height = 36
        Align = alTop
        BevelOuter = bvNone
        Color = clWhitesmoke
        ParentBackground = False
        TabOrder = 0
        object lblSentryInfo: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 3
          Width = 699
          Height = 15
          Align = alClient
          Caption = 
            'Error-tracking sink transmitting application exceptions, stack t' +
            'races, and active breadcrumbs using the Sentry Envelope JSON pro' +
            'tocol.'
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clGrayText
          Font.Height = -12
          Font.Name = 'Segoe UI'
          Font.Style = [fsItalic]
          ParentFont = False
          WordWrap = True
        end
      end
      object pnlSentryConfig: TPanel
        Left = 0
        Top = 36
        Width = 842
        Height = 354
        Align = alClient
        BevelOuter = bvNone
        TabOrder = 1
        object lblSentryDSN: TLabel
          Left = 16
          Top = 50
          Width = 62
          Height = 15
          Caption = 'Sentry DSN:'
        end
        object chkSentryEnabled: TCheckBox
          Left = 16
          Top = 16
          Width = 120
          Height = 17
          Caption = 'Sink Enabled'
          TabOrder = 0
          OnClick = chkSentryEnabledClick
        end
        object edtSentryDSN: TEdit
          Left = 100
          Top = 47
          Width = 450
          Height = 23
          TabOrder = 1
          OnChange = edtSentryDSNChange
        end
      end
    end
    object tsWinEvent: TTabSheet
      Caption = 'Windows Event Sink'
      ImageIndex = 4
      object pnlWinEventHeader: TPanel
        Left = 0
        Top = 0
        Width = 842
        Height = 36
        Align = alTop
        BevelOuter = bvNone
        Color = clWhitesmoke
        ParentBackground = False
        TabOrder = 0
        object lblWinEventInfo: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 3
          Width = 642
          Height = 15
          Align = alClient
          Caption = 
            'Native Windows Event Log integration utilizing WinAPI ReportEven' +
            't. Automatically maps trace log levels to OS event types.'
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clGrayText
          Font.Height = -12
          Font.Name = 'Segoe UI'
          Font.Style = [fsItalic]
          ParentFont = False
          WordWrap = True
        end
      end
      object pnlWinEventConfig: TPanel
        Left = 0
        Top = 36
        Width = 842
        Height = 354
        Align = alClient
        BevelOuter = bvNone
        TabOrder = 1
        object lblWinEventSource: TLabel
          Left = 16
          Top = 50
          Width = 71
          Height = 15
          Caption = 'Event Source:'
        end
        object chkWinEventEnabled: TCheckBox
          Left = 16
          Top = 16
          Width = 120
          Height = 17
          Caption = 'Sink Enabled'
          TabOrder = 0
          OnClick = chkWinEventEnabledClick
        end
        object edtWinEventSource: TEdit
          Left = 110
          Top = 47
          Width = 250
          Height = 23
          TabOrder = 1
          OnChange = edtWinEventSourceChange
        end
      end
    end
  end
  object SaveDialog1: TSaveDialog
    DefaultExt = 'txt'
    FileName = 'logfile.txt'
    Left = 44
    Top = 502
  end
end
