// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit uMainForm;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.ExtCtrls,
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
  /// Demonstration application for the DevFormel.Trace logging and telemetry suite.
  /// </summary>
  TFormMain = class(TForm)
    pnlHeader: TPanel;
    lblProductTitle: TLabel;
    lblWebsiteLink: TLinkLabel;
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
    pgcSinks: TPageControl;
    
    // Memo Sink Controls
    tsMemo: TTabSheet;
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
    tsLogFile: TTabSheet;
    pnlFileHeader: TPanel;
    lblFileInfo: TLabel;
    pnlFileConfig: TPanel;
    chkFileEnabled: TCheckBox;
    lblFileName: TLabel;
    edtFileName: TEdit;
    btnTargetFile: TButton;
    lblMaxFileSize: TLabel;
    edtMaxFileSize: TEdit;
    btnOpenLogDir: TButton;
    SaveDialog1: TSaveDialog;
    
    // Seq Sink Controls
    tsSeq: TTabSheet;
    pnlSeqHeader: TPanel;
    lblSeqInfo: TLabel;
    pnlSeqConfig: TPanel;
    chkSeqEnabled: TCheckBox;
    lblSeqServerUrl: TLabel;
    edtSeqServerUrl: TEdit;
    lblSeqApiKey: TLabel;
    edtSeqApiKey: TEdit;
    
    // Sentry Sink Controls
    tsSentry: TTabSheet;
    pnlSentryHeader: TPanel;
    lblSentryInfo: TLabel;
    pnlSentryConfig: TPanel;
    chkSentryEnabled: TCheckBox;
    lblSentryDSN: TLabel;
    edtSentryDSN: TEdit;
    
    // WinEvent Sink Controls
    tsWinEvent: TTabSheet;
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
    procedure chkHubEnabledClick(Sender: TObject);
    procedure chkPIIScrubbingClick(Sender: TObject);
    procedure cbxConsentChange(Sender: TObject);
    procedure chkMemoEnabledClick(Sender: TObject);
    procedure chkMemoAutoScrollClick(Sender: TObject);
    procedure edtMemoMaxLinesChange(Sender: TObject);
    procedure btnMemoClearClick(Sender: TObject);
    procedure chkFileEnabledClick(Sender: TObject);
    procedure edtFileNameChange(Sender: TObject);
    procedure edtMaxFileSizeChange(Sender: TObject);
    procedure btnOpenLogDirClick(Sender: TObject);
    procedure btnTargetFileClick(Sender: TObject);
    procedure chkSeqEnabledClick(Sender: TObject);
    procedure edtSeqServerUrlChange(Sender: TObject);
    procedure edtSeqApiKeyChange(Sender: TObject);
    procedure chkSentryEnabledClick(Sender: TObject);
    procedure edtSentryDSNChange(Sender: TObject);
    procedure chkWinEventEnabledClick(Sender: TObject);
    procedure edtWinEventSourceChange(Sender: TObject);
    procedure lblWebsiteLinkLinkClick(Sender: TObject; const Link: string;
        LinkType: TSysLinkType);
  private
    { Core telemetry components }
    FHub: TDFTraceHub;
    FMemoSink: TDFMemoSink;
    FFileSink: TDFFileSink;
    FSeqSink: TDFSeqSink;
    FSentrySink: TDFSentrySink;
    FWinEventSink: TDFWinEventSink;

    procedure InitializeTelemetryPipeline;
    procedure SynchronizeUI;
    procedure SimulateDatabaseQuery;
  public
    { Public declarations }
  end;

var
  FormMain: TFormMain;

implementation

{$R *.dfm}

uses
  System.IOUtils, Winapi.ShellAPI;

{ TFormMain }

procedure TFormMain.FormCreate(Sender: TObject);
begin
  // Same order as TDFConsent, so that ItemIndex converts directly
  cbxConsent.Items.Add('None');
  cbxConsent.Items.Add('LocalOnly');
  cbxConsent.Items.Add('Full');
  InitializeTelemetryPipeline;
  SynchronizeUI;

  // FileName stays empty, so the sink uses its default path; shown as a hint in the field
  edtFileName.TextHint := FFileSink.ActiveFileName;
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  if Assigned(FHub) then
    FHub.Flush(2000);
end;

procedure TFormMain.InitializeTelemetryPipeline;
begin
  // 1. Create central telemetry Hub
  FHub := TDFTraceHub.Create(Self);
  FHub.AppName := 'DevFormel.Trace.Demo';
  FHub.Environment := 'Development';
  // AppVersion stays empty: the hub then uses the file version from the project options
  FHub.AutoHookExceptions := True;
  FHub.EnablePIIScrubbing := True;
  // Attached to every event, including unhandled exceptions
  FHub.SetTag('Module', 'Demo');

  // 2. Setup UI Memo Sink
  FMemoSink := TDFMemoSink.Create(Self);
  FMemoSink.Hub := FHub;
  FMemoSink.TargetMemo := mmoLogOutput;
  FMemoSink.MinLevel := TDFLogLevel.Debug;
  FMemoSink.MaxLines := 500;
  FMemoSink.AutoScroll := True;

  // 3. Setup File Logging Sink
  FFileSink := TDFFileSink.Create(Self);
  FFileSink.Hub := FHub;
  FFileSink.MinLevel := TDFLogLevel.Debug;
  FFileSink.MaxFileSizeMB := 5;
  FFileSink.MaxArchivedFiles := 3;

  // 4. Setup Datalust Seq Sink
  FSeqSink := TDFSeqSink.Create(Self);
  FSeqSink.Hub := FHub;
  FSeqSink.ServerUrl := 'http://localhost:5341';
  FSeqSink.MinLevel := TDFLogLevel.Info;
  FSeqSink.Enabled := False;

  // 5. Setup Sentry Sink
  FSentrySink := TDFSentrySink.Create(Self);
  FSentrySink.Hub := FHub;
  FSentrySink.MinLevel := TDFLogLevel.Info;
  FSentrySink.Enabled := False;

  // 6. Setup Windows Event Log Sink
  FWinEventSink := TDFWinEventSink.Create(Self);
  FWinEventSink.Hub := FHub;
  FWinEventSink.Source := 'DevFormelTraceDemo';
  FWinEventSink.MinLevel := TDFLogLevel.Warning;
  FWinEventSink.Enabled := False;
end;

procedure TFormMain.SynchronizeUI;
begin
  chkHubEnabled.Checked := FHub.Enabled;
  chkPIIScrubbing.Checked := FHub.EnablePIIScrubbing;
  cbxConsent.ItemIndex := Ord(FHub.Consent);

  // Memo Sink UI
  chkMemoEnabled.Checked := FMemoSink.Enabled;
  chkMemoAutoScroll.Checked := FMemoSink.AutoScroll;
  edtMemoMaxLines.Text := FMemoSink.MaxLines.ToString;

  // File Sink UI
  chkFileEnabled.Checked := FFileSink.Enabled;
  edtFileName.Text := FFileSink.FileName;
  edtMaxFileSize.Text := FFileSink.MaxFileSizeMB.ToString;

  // Seq Sink UI
  chkSeqEnabled.Checked := FSeqSink.Enabled;
  edtSeqServerUrl.Text := FSeqSink.ServerUrl;
  edtSeqApiKey.Text := FSeqSink.ApiKey;

  // Sentry Sink UI
  chkSentryEnabled.Checked := FSentrySink.Enabled;
  edtSentryDSN.Text := FSentrySink.DSN;

  // WinEvent Sink UI
  chkWinEventEnabled.Checked := FWinEventSink.Enabled;
  edtWinEventSource.Text := FWinEventSink.Source;
end;

procedure TFormMain.btnTrackInfoClick(Sender: TObject);
begin
  FHub.TrackEvent('User initiated standard processing action.', TDFLogLevel.Info);
end;

procedure TFormMain.btnTrackWarningClick(Sender: TObject);
begin
  FHub.TrackEvent('Database connection pool reached 85% capacity. Admin contact: admin@company.local (IP: 192.168.1.100)', TDFLogLevel.Warning);
end;

procedure TFormMain.btnTrackExceptionClick(Sender: TObject);
begin
  try
    var LZero := 0;
    var LVal := 42 div LZero;
    Caption := LVal.ToString;
  except
    on E: Exception do
      FHub.TrackException(E, [TDFKeyValuePair.Create('Divisor', 0)]);
  end;
end;

procedure TFormMain.btnTrackSystemInfoClick(Sender: TObject);
begin
  FHub.TrackSystemInfo(TDFLogLevel.Info);
end;

procedure TFormMain.SimulateDatabaseQuery;
begin
  var IScope := FHub.TrackScope('Execute_Customer_Query', [
    TDFKeyValuePair.Create('Table', 'Customers'),
    TDFKeyValuePair.Create('RowsFetched', 1250)
  ]);

  Sleep(180);
end;

procedure TFormMain.btnTrackPerformanceClick(Sender: TObject);
begin
  SimulateDatabaseQuery;
end;

procedure TFormMain.btnRaiseUnhandledClick(Sender: TObject);
begin
  // Deliberately not caught: the hub reports it through Application.OnException
  raise EInvalidOperation.Create('Unhandled exception raised by the demo');
end;

procedure TFormMain.btnAddBreadcrumbClick(Sender: TObject);
begin
  if Trim(edtBreadcrumbText.Text).IsEmpty then Exit;

  FHub.AddBreadcrumb(Trim(edtBreadcrumbText.Text), 'user-interface', TDFLogLevel.Info, TDFBreadcrumbType.User);
  FHub.TrackEvent(Format('Breadcrumb added: "%s"', [Trim(edtBreadcrumbText.Text)]), TDFLogLevel.Debug);
end;

procedure TFormMain.chkHubEnabledClick(Sender: TObject);
begin
  FHub.Enabled := chkHubEnabled.Checked;
end;

procedure TFormMain.chkPIIScrubbingClick(Sender: TObject);
begin
  FHub.EnablePIIScrubbing := chkPIIScrubbing.Checked;
end;

procedure TFormMain.cbxConsentChange(Sender: TObject);
begin
  // -1 while nothing is selected, which is not a valid TDFConsent
  if cbxConsent.ItemIndex < 0 then
    Exit;
  // Changing the level also clears the breadcrumbs
  FHub.Consent := TDFConsent(cbxConsent.ItemIndex);
end;

procedure TFormMain.chkMemoEnabledClick(Sender: TObject);
begin
  FMemoSink.Enabled := chkMemoEnabled.Checked;
end;

procedure TFormMain.chkMemoAutoScrollClick(Sender: TObject);
begin
  FMemoSink.AutoScroll := chkMemoAutoScroll.Checked;
end;

procedure TFormMain.edtMemoMaxLinesChange(Sender: TObject);
begin
  FMemoSink.MaxLines := StrToIntDef(edtMemoMaxLines.Text, 1000);
end;

procedure TFormMain.btnMemoClearClick(Sender: TObject);
begin
  mmoLogOutput.Clear;
  FHub.ClearBreadcrumbs;
end;

procedure TFormMain.chkFileEnabledClick(Sender: TObject);
begin
  FFileSink.Enabled := chkFileEnabled.Checked;
end;

procedure TFormMain.edtFileNameChange(Sender: TObject);
begin
  FFileSink.FileName := Trim(edtFileName.Text);
end;

procedure TFormMain.edtMaxFileSizeChange(Sender: TObject);
begin
  FFileSink.MaxFileSizeMB := StrToIntDef(edtMaxFileSize.Text, 5);
end;

procedure TFormMain.btnOpenLogDirClick(Sender: TObject);
var
  LDir: string;
begin
  LDir := TPath.GetDirectoryName(FFileSink.ActiveFileName);
  if TDirectory.Exists(LDir) then
    ShellExecute(0, 'open', PChar(LDir), nil, nil, SW_SHOWNORMAL)
  else
    ShowMessage('Log directory does not exist yet. Emit a log event first.');
end;

procedure TFormMain.btnTargetFileClick(Sender: TObject);
begin
  if SaveDialog1.Execute then
    edtFileName.Text := SaveDialog1.FileName;
end;

procedure TFormMain.chkSeqEnabledClick(Sender: TObject);
begin
  FSeqSink.Enabled := chkSeqEnabled.Checked;
end;

procedure TFormMain.edtSeqServerUrlChange(Sender: TObject);
begin
  FSeqSink.ServerUrl := Trim(edtSeqServerUrl.Text);
end;

procedure TFormMain.edtSeqApiKeyChange(Sender: TObject);
begin
  FSeqSink.ApiKey := Trim(edtSeqApiKey.Text);
end;

procedure TFormMain.chkSentryEnabledClick(Sender: TObject);
begin
  FSentrySink.Enabled := chkSentryEnabled.Checked;
end;

procedure TFormMain.edtSentryDSNChange(Sender: TObject);
begin
  FSentrySink.DSN := Trim(edtSentryDSN.Text);
end;

procedure TFormMain.chkWinEventEnabledClick(Sender: TObject);
begin
  FWinEventSink.Enabled := chkWinEventEnabled.Checked;
end;

procedure TFormMain.edtWinEventSourceChange(Sender: TObject);
begin
  FWinEventSink.Source := Trim(edtWinEventSource.Text);
end;

procedure TFormMain.lblWebsiteLinkLinkClick(Sender: TObject; const Link:
    string; LinkType: TSysLinkType);
begin
  ShellExecute(0, 'open', PChar(Link), nil, nil, SW_SHOWNORMAL);
end;

end.
