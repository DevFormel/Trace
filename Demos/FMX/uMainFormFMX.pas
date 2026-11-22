// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit uMainFormFMX;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls,
  FMX.Layouts, FMX.Edit, FMX.Memo, FMX.TabControl, FMX.Controls.Presentation,
  FMX.Memo.Types, FMX.ScrollBox, FMX.ListBox,
  // DevFormel Trace Units
  DevFormel.Trace.Types,
  DevFormel.Trace.Hub,
  DevFormel.Trace.Sinks.Memo,
  DevFormel.Trace.Sinks.LogFile,
  DevFormel.Trace.Sinks.Seq,
  DevFormel.Trace.Sinks.Sentry,
  DevFormel.Trace.Sinks.WinEvent;

type
  /// <summary>
  /// FireMonkey demonstration application for DevFormel.Trace.
  /// Demonstrates cross-platform telemetry logging capabilities.
  /// </summary>
  TFormMainFMX = class(TForm)
    pnlHeader: TPanel;
    lblProductTitle: TLabel;
    btnWebsiteLink: TButton;
    pnlTop: TPanel;
    grpGlobalActions: TGroupBox;
    btnTrackInfo: TButton;
    btnTrackWarning: TButton;
    btnTrackException: TButton;
    btnTrackSystemInfo: TButton;
    btnTrackPerformance: TButton;
    btnAddBreadcrumb: TButton;
    btnRaiseUnhandled: TButton;
    edtBreadcrumbText: TEdit;
    chkHubEnabled: TCheckBox;
    chkPIIScrubbing: TCheckBox;
    lblConsent: TLabel;
    cbxConsent: TComboBox;
    tbcSinks: TTabControl;
    
    // Memo Sink Controls
    tiMemo: TTabItem;
    pnlMemoHeader: TPanel;
    lblMemoInfo: TLabel;
    pnlMemoConfig: TPanel;
    chkMemoEnabled: TCheckBox;
    chkMemoAutoScroll: TCheckBox;
    lblMemoMaxLines: TLabel;
    edtMemoMaxLines: TEdit;
    btnMemoClear: TButton;
    mmoLogOutput: TMemo;
    
    // LogFile Sink Controls
    tiLogFile: TTabItem;
    pnlFileHeader: TPanel;
    lblFileInfo: TLabel;
    pnlFileConfig: TPanel;
    chkFileEnabled: TCheckBox;
    lblFileName: TLabel;
    edtFileName: TEdit;
    lblMaxFileSize: TLabel;
    edtMaxFileSize: TEdit;
    btnOpenLogDir: TButton;
    
    // Seq Sink Controls
    tiSeq: TTabItem;
    pnlSeqHeader: TPanel;
    lblSeqInfo: TLabel;
    pnlSeqConfig: TPanel;
    chkSeqEnabled: TCheckBox;
    lblSeqServerUrl: TLabel;
    edtSeqServerUrl: TEdit;
    lblSeqApiKey: TLabel;
    edtSeqApiKey: TEdit;
    
    // Sentry Sink Controls
    tiSentry: TTabItem;
    pnlSentryHeader: TPanel;
    lblSentryInfo: TLabel;
    pnlSentryConfig: TPanel;
    chkSentryEnabled: TCheckBox;
    lblSentryDSN: TLabel;
    edtSentryDSN: TEdit;
    
    // WinEvent Sink Controls
    tiWinEvent: TTabItem;
    pnlWinEventHeader: TPanel;
    lblWinEventInfo: TLabel;
    pnlWinEventConfig: TPanel;
    chkWinEventEnabled: TCheckBox;
    lblWinEventSource: TLabel;
    edtWinEventSource: TEdit;

    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnTrackInfoClick(Sender: TObject);
    procedure btnTrackWarningClick(Sender: TObject);
    procedure btnTrackExceptionClick(Sender: TObject);
    procedure btnTrackSystemInfoClick(Sender: TObject);
    procedure btnTrackPerformanceClick(Sender: TObject);
    procedure btnAddBreadcrumbClick(Sender: TObject);
    procedure btnRaiseUnhandledClick(Sender: TObject);
    procedure chkHubEnabledChange(Sender: TObject);
    procedure chkPIIScrubbingChange(Sender: TObject);
    procedure cbxConsentChange(Sender: TObject);
    procedure btnVisitWebsiteClick(Sender: TObject);
    procedure chkMemoEnabledChange(Sender: TObject);
    procedure chkMemoAutoScrollChange(Sender: TObject);
    procedure edtMemoMaxLinesChange(Sender: TObject);
    procedure btnMemoClearClick(Sender: TObject);
    procedure chkFileEnabledChange(Sender: TObject);
    procedure edtFileNameChange(Sender: TObject);
    procedure edtMaxFileSizeChange(Sender: TObject);
    procedure btnOpenLogDirClick(Sender: TObject);
    procedure chkSeqEnabledChange(Sender: TObject);
    procedure edtSeqServerUrlChange(Sender: TObject);
    procedure edtSeqApiKeyChange(Sender: TObject);
    procedure chkSentryEnabledChange(Sender: TObject);
    procedure edtSentryDSNChange(Sender: TObject);
    procedure chkWinEventEnabledChange(Sender: TObject);
    procedure edtWinEventSourceChange(Sender: TObject);
  private
    FHub: TDFTraceHub;
    FMemoSink: TDFMemoSink;
    FFileSink: TDFFileSink;
    FSeqSink: TDFSeqSink;
    FSentrySink: TDFSentrySink;
    FWinEventSink: TDFWinEventSink;

    procedure InitializeTelemetryPipeline;
    procedure SynchronizeUI;
    procedure OpenURL(const AURL: string);
  public
  end;

var
  FormMainFMX: TFormMainFMX;

implementation

{$R *.fmx}

uses
  System.IOUtils,
  {$IFDEF MSWINDOWS}
  Winapi.ShellAPI, Winapi.Windows;
  {$ELSE}
  {$IFDEF POSIX}
  Posix.Stdlib;
  {$ENDIF}
  {$ENDIF}

procedure TFormMainFMX.FormCreate(Sender: TObject);
begin
  // Same order as TDFConsent, so that ItemIndex converts directly
  cbxConsent.Items.Add('None');
  cbxConsent.Items.Add('LocalOnly');
  cbxConsent.Items.Add('Full');
  InitializeTelemetryPipeline;
  SynchronizeUI;
  // FileName stays empty, so the sink uses its default path; shown as a hint in the field
  edtFileName.TextPrompt := FFileSink.ActiveFileName;
end;

procedure TFormMainFMX.FormDestroy(Sender: TObject);
begin
  if Assigned(FHub) then
    FHub.Flush(2000);
end;

procedure TFormMainFMX.InitializeTelemetryPipeline;
begin
  FHub := TDFTraceHub.Create(Self);
  FHub.AppName := 'DevFormel.Trace.FMXDemo';
  FHub.Environment := 'Development';
  // AppVersion stays empty: the hub then uses the file version from the project options
  FHub.AutoHookExceptions := True;
  FHub.EnablePIIScrubbing := True;

  FMemoSink := TDFMemoSink.Create(Self);
  FMemoSink.Hub := FHub;
  FMemoSink.TargetMemo := mmoLogOutput;
  FMemoSink.MinLevel := TDFLogLevel.Debug;
  FMemoSink.MaxLines := 500;
  FMemoSink.AutoScroll := True;

  FFileSink := TDFFileSink.Create(Self);
  FFileSink.Hub := FHub;
  FFileSink.MinLevel := TDFLogLevel.Debug;
  FFileSink.MaxFileSizeMB := 5;
  FFileSink.MaxArchivedFiles := 3;

  FSeqSink := TDFSeqSink.Create(Self);
  FSeqSink.Hub := FHub;
  FSeqSink.ServerUrl := 'http://localhost:5341';
  FSeqSink.MinLevel := TDFLogLevel.Info;
  FSeqSink.Enabled := False;

  FSentrySink := TDFSentrySink.Create(Self);
  FSentrySink.Hub := FHub;
  FSentrySink.MinLevel := TDFLogLevel.Error;
  FSentrySink.Enabled := False;

  FWinEventSink := TDFWinEventSink.Create(Self);
  FWinEventSink.Hub := FHub;
  FWinEventSink.Source := 'DevFormelTraceFMXDemo';
  FWinEventSink.MinLevel := TDFLogLevel.Warning;
  FWinEventSink.Enabled := False;
end;

procedure TFormMainFMX.SynchronizeUI;
begin
  chkHubEnabled.IsChecked := FHub.Enabled;
  chkPIIScrubbing.IsChecked := FHub.EnablePIIScrubbing;
  cbxConsent.ItemIndex := Ord(FHub.Consent);

  chkMemoEnabled.IsChecked := FMemoSink.Enabled;
  chkMemoAutoScroll.IsChecked := FMemoSink.AutoScroll;
  edtMemoMaxLines.Text := FMemoSink.MaxLines.ToString;

  chkFileEnabled.IsChecked := FFileSink.Enabled;
  edtFileName.Text := FFileSink.FileName;
  edtMaxFileSize.Text := FFileSink.MaxFileSizeMB.ToString;

  chkSeqEnabled.IsChecked := FSeqSink.Enabled;
  edtSeqServerUrl.Text := FSeqSink.ServerUrl;
  edtSeqApiKey.Text := FSeqSink.ApiKey;

  chkSentryEnabled.IsChecked := FSentrySink.Enabled;
  edtSentryDSN.Text := FSentrySink.DSN;

  chkWinEventEnabled.IsChecked := FWinEventSink.Enabled;
  edtWinEventSource.Text := FWinEventSink.Source;
end;

procedure TFormMainFMX.OpenURL(const AURL: string);
begin
  {$IFDEF MSWINDOWS}
  ShellExecute(0, 'open', PChar(AURL), nil, nil, SW_SHOWNORMAL);
  {$ELSE}
  {$IFDEF POSIX}
  _system(PAnsiChar(AnsiString('open "' + AURL + '"')));
  {$ENDIF}
  {$ENDIF}
end;

procedure TFormMainFMX.btnTrackInfoClick(Sender: TObject);
begin
  FHub.TrackEvent('User triggered FMX standard action.', TDFLogLevel.Info);
end;

procedure TFormMainFMX.btnTrackWarningClick(Sender: TObject);
begin
  FHub.TrackEvent('FMX memory pool warning. Contact: dev@example.com (IP: 10.0.0.15)', TDFLogLevel.Warning);
end;

procedure TFormMainFMX.btnTrackExceptionClick(Sender: TObject);
begin
  try
    var LZero := 0;
    var LVal := 100 div LZero;
    Caption := LVal.ToString;
  except
    on E: Exception do
      FHub.TrackException(E, TDFLogLevel.Error);
  end;
end;

procedure TFormMainFMX.btnTrackSystemInfoClick(Sender: TObject);
begin
  FHub.TrackSystemInfo(TDFLogLevel.Info);
end;

procedure TFormMainFMX.btnTrackPerformanceClick(Sender: TObject);
begin
  var IScope := FHub.TrackScope('FMX_Render_Pipeline', [
    TDFKeyValuePair.Create('Framework', 'FireMonkey')
  ]);
  Sleep(120);
end;

procedure TFormMainFMX.btnRaiseUnhandledClick(Sender: TObject);
begin
  // Deliberately not caught: the hub reports it through Application.OnException
  raise Exception.Create('Unhandled exception raised by the FMX demo');
end;

procedure TFormMainFMX.btnAddBreadcrumbClick(Sender: TObject);
begin
  if Trim(edtBreadcrumbText.Text).IsEmpty then Exit;

  FHub.AddBreadcrumb(Trim(edtBreadcrumbText.Text), 'fmx-ui', TDFLogLevel.Info, TDFBreadcrumbType.User);
  FHub.TrackEvent(Format('Breadcrumb added: "%s"', [Trim(edtBreadcrumbText.Text)]), TDFLogLevel.Debug);
end;

procedure TFormMainFMX.chkHubEnabledChange(Sender: TObject);
begin
  FHub.Enabled := chkHubEnabled.IsChecked;
end;

procedure TFormMainFMX.chkPIIScrubbingChange(Sender: TObject);
begin
  FHub.EnablePIIScrubbing := chkPIIScrubbing.IsChecked;
end;

procedure TFormMainFMX.cbxConsentChange(Sender: TObject);
begin
  // -1 while nothing is selected, which is not a valid TDFConsent
  if cbxConsent.ItemIndex < 0 then
    Exit;
  // Changing the level also clears the breadcrumbs
  FHub.Consent := TDFConsent(cbxConsent.ItemIndex);
end;

procedure TFormMainFMX.btnVisitWebsiteClick(Sender: TObject);
begin
  OpenURL('https://devformel.com/');
end;

procedure TFormMainFMX.chkMemoEnabledChange(Sender: TObject);
begin
  FMemoSink.Enabled := chkMemoEnabled.IsChecked;
end;

procedure TFormMainFMX.chkMemoAutoScrollChange(Sender: TObject);
begin
  FMemoSink.AutoScroll := chkMemoAutoScroll.IsChecked;
end;

procedure TFormMainFMX.edtMemoMaxLinesChange(Sender: TObject);
begin
  FMemoSink.MaxLines := StrToIntDef(edtMemoMaxLines.Text, 1000);
end;

procedure TFormMainFMX.btnMemoClearClick(Sender: TObject);
begin
  mmoLogOutput.Lines.Clear;
  FHub.ClearBreadcrumbs;
end;

procedure TFormMainFMX.chkFileEnabledChange(Sender: TObject);
begin
  FFileSink.Enabled := chkFileEnabled.IsChecked;
end;

procedure TFormMainFMX.edtFileNameChange(Sender: TObject);
begin
  FFileSink.FileName := Trim(edtFileName.Text);
end;

procedure TFormMainFMX.edtMaxFileSizeChange(Sender: TObject);
begin
  FFileSink.MaxFileSizeMB := StrToIntDef(edtMaxFileSize.Text, 5);
end;

procedure TFormMainFMX.btnOpenLogDirClick(Sender: TObject);
var
  LDir: string;
begin
  LDir := TPath.GetDirectoryName(FFileSink.ActiveFileName);
  if TDirectory.Exists(LDir) then
    OpenURL(LDir)
  else
    ShowMessage('Log directory does not exist yet. Emit a log event first.');
end;

procedure TFormMainFMX.chkSeqEnabledChange(Sender: TObject);
begin
  FSeqSink.Enabled := chkSeqEnabled.IsChecked;
end;

procedure TFormMainFMX.edtSeqServerUrlChange(Sender: TObject);
begin
  FSeqSink.ServerUrl := Trim(edtSeqServerUrl.Text);
end;

procedure TFormMainFMX.edtSeqApiKeyChange(Sender: TObject);
begin
  FSeqSink.ApiKey := Trim(edtSeqApiKey.Text);
end;

procedure TFormMainFMX.chkSentryEnabledChange(Sender: TObject);
begin
  FSentrySink.Enabled := chkSentryEnabled.IsChecked;
end;

procedure TFormMainFMX.edtSentryDSNChange(Sender: TObject);
begin
  FSentrySink.DSN := Trim(edtSentryDSN.Text);
end;

procedure TFormMainFMX.chkWinEventEnabledChange(Sender: TObject);
begin
  FWinEventSink.Enabled := chkWinEventEnabled.IsChecked;
end;

procedure TFormMainFMX.edtWinEventSourceChange(Sender: TObject);
begin
  FWinEventSink.Source := Trim(edtWinEventSource.Text);
end;

end.