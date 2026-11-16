// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Sinks.Seq;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  System.DateUtils,
  System.Net.HttpClient,
  System.Net.URLClient,
  System.NetConsts,
  DevFormel.Trace.Types,
  DevFormel.Trace.Hub;

type
  /// <summary>
  /// Sends events to a Seq server.
  /// </summary>
  /// <remarks>
  /// Tags and extra values become top-level properties of the Seq event, with numbers and
  /// booleans keeping their type, so a filter can read DurationMS > 1000. Names already set by
  /// the sink (EventID, ThreadID, Logger, Application, Environment, AppVersion, ExceptionType,
  /// Breadcrumbs) take precedence; of several entries with the same name, tags first, only the
  /// first is sent. A name starting with @ is sent with a second @, as CLEF requires.
  /// Events are sent after scrubbing (see TDFTraceHub.EnablePIIScrubbing). Scrubbing is
  /// based on patterns and does not guarantee that all personal data is removed. With every
  /// request the server also receives the IP address of the sending computer; whether it is
  /// stored depends on the server settings. Use https for a server outside the local network,
  /// otherwise events and the API key are sent unencrypted.
  /// </remarks>
  // Only Windows is tested so far
  [ComponentPlatformsAttribute(pidWin32 or pidWin64)]
  TDFSeqSink = class(TComponent, IDFTraceSink)
  private
    FHub: TDFTraceHub;
    FEnabled: Boolean;
    FMinLevel: TDFLogLevel;
    FServerUrl: string;
    FApiKey: string;
    FLock: TCriticalSection;
    FPauseAfterErrorSeconds: Integer;
    FFollowRedirects: Boolean;
    FPausedUntil: UInt64;
    FDroppedCount: UInt64;

    procedure SetHub(const AValue: TDFTraceHub);
    function LevelToSeqString(ALevel: TDFLogLevel): string;
    function BuildClefPayload(const AEvent: TDFTraceEvent): string;
    function ResolveIngestionUrl: string;
    function GetEnabled: Boolean;
    function GetMinLevel: TDFLogLevel;
    function GetDroppedCount: UInt64;
    function SkipWhilePaused: Boolean;
    procedure RegisterFailure(APauseSeconds: Integer);
    procedure HandleResponse(const AResponse: IHTTPResponse);
    procedure Emit(const AEvent: TDFTraceEvent);
  protected
    /// <summary>Clears Hub when the hub is freed.</summary>
    /// <param name="AComponent">Component that is inserted or removed.</param>
    /// <param name="Operation">opInsert or opRemove.</param>
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;

    /// <summary>Converts a Retry-After header into the seconds to pause.</summary>
    /// <param name="AHeaderValue">Value of the header; may be empty.</param>
    /// <param name="ADefaultSeconds">Pause used when the header is missing or is not a number
    /// of seconds, for example a date.</param>
    /// <returns>The seconds from the header, at most 3600, or the default.</returns>
    class function PauseFromRetryAfter(const AHeaderValue: string; ADefaultSeconds: Integer): Integer; static;
  public
    /// <summary>Creates the sink. It receives events once Hub is set.</summary>
    /// <param name="AOwner">Component that frees the sink, usually the form or data module
    /// that holds the hub.</param>
    constructor Create(AOwner: TComponent); override;
    /// <summary>Passes the queued events to all sinks, for at most Hub.ShutdownTimeoutMS, and
    /// removes the sink from the hub.</summary>
    destructor Destroy; override;

    /// <summary>Number of events not delivered since start: failed to send, rejected by the
    /// server, or skipped during a pause after an error.</summary>
    property DroppedCount: UInt64 read GetDroppedCount;
  published
    /// <summary>Hub that passes events to this sink. Setting it registers the sink with the
    /// hub.</summary>
    property Hub: TDFTraceHub read FHub write SetHub;
    /// <summary>Turns the sink on or off.</summary>
    property Enabled: Boolean read FEnabled write FEnabled default True;
    /// <summary>Lowest level that is sent; events below it are ignored.</summary>
    property MinLevel: TDFLogLevel read FMinLevel write FMinLevel default TDFLogLevel.Info;
    /// <summary>Address of the Seq server, for example http://localhost:5341.</summary>
    /// <remarks>The path /api/events/raw is added if it is missing.
    /// Unless FollowRedirects is True, redirects are not followed: if the server answers
    /// with one, for example from http to https, the event is counted in <c>DroppedCount</c>,
    /// so enter the address the server finally uses. With https, Windows checks the
    /// certificate of the server; a server whose certificate Windows does not trust receives
    /// no events.</remarks>
    property ServerUrl: string read FServerUrl write FServerUrl;
    /// <summary>API key, sent in the X-Seq-ApiKey header. Leave it empty if the server
    /// accepts events without a key.</summary>
    /// <remarks>A key set here is stored in the form file and ends up in the executable, as
    /// does a key set in code. Create a key in Seq that only has the Ingest permission, so that
    /// someone who extracts it can at most send events.</remarks>
    property ApiKey: string read FApiKey write FApiKey;
    /// <summary>Seconds without sending attempts after a failed request.</summary>
    /// <remarks>Without a pause, every event would wait for the connection timeout while the
    /// server is unreachable, which delays all other sinks. Events during the pause are counted
    /// in <c>DroppedCount</c>. 0 disables the pause; while the server is unreachable, closing the
    /// application can then take several connection timeouts. A Retry-After header from the
    /// server takes precedence, up to one hour.</remarks>
    property PauseAfterErrorSeconds: Integer read FPauseAfterErrorSeconds write FPauseAfterErrorSeconds default 30;
    /// <summary>Follows redirects of the server. Off by default.</summary>
    /// <remarks>If True, the event and the API key are sent to the address the server names in
    /// its answer, which can be another host or an address without TLS. Turn it on only for
    /// a server you control, for example to keep installed applications reporting after the
    /// server has moved; a changed DNS entry does the same without a redirect. The request
    /// stays a POST, except after status 303. If a redirect ends at a page that answers with
    /// 200, such as a login page, the event counts as sent although it is lost.</remarks>
    property FollowRedirects: Boolean read FFollowRedirects write FFollowRedirects default False;
  end;

implementation

{ TDFSeqSink }

constructor TDFSeqSink.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FEnabled := True;
  FMinLevel := TDFLogLevel.Info;
  FServerUrl := '';
  FApiKey := '';
  FLock := TCriticalSection.Create;
  FPauseAfterErrorSeconds := 30;
  FFollowRedirects := False;
  FPausedUntil := 0;
  FDroppedCount := 0;
end;

destructor TDFSeqSink.Destroy;
begin
  if Assigned(FHub) then
  begin
    // Forms free their sinks before the hub. Flushing here passes queued events to all
    // sinks while they still exist.
    FHub.Flush(FHub.ShutdownTimeoutMS);
    FHub.UnregisterSink(Self);
  end;

  FreeAndNil(FLock);
  inherited Destroy;
end;

procedure TDFSeqSink.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FHub) then
    FHub := nil;
end;

procedure TDFSeqSink.SetHub(const AValue: TDFTraceHub);
begin
  if FHub <> AValue then
  begin
    if Assigned(FHub) then
    begin
      FHub.UnregisterSink(Self);
      FHub.RemoveFreeNotification(Self);
    end;

    FHub := AValue;

    if Assigned(FHub) then
    begin
      FHub.FreeNotification(Self);
      FHub.RegisterSink(Self);
    end;
  end;
end;

function TDFSeqSink.GetEnabled: Boolean;
begin
  Result := FEnabled;
end;

function TDFSeqSink.GetMinLevel: TDFLogLevel;
begin
  Result := FMinLevel;
end;

function TDFSeqSink.LevelToSeqString(ALevel: TDFLogLevel): string;
begin
  case ALevel of
    TDFLogLevel.Debug:   Result := 'Debug';
    TDFLogLevel.Info:    Result := 'Information';
    TDFLogLevel.Warning: Result := 'Warning';
    TDFLogLevel.Error:   Result := 'Error';
    TDFLogLevel.Fatal:   Result := 'Fatal';
  else
    Result := 'Information';
  end;
end;

function TDFSeqSink.ResolveIngestionUrl: string;
var
  CleanUrl: string;
begin
  CleanUrl := FServerUrl.TrimRight(['/']);
  if CleanUrl.EndsWith('/api/events/raw', True) then
    Result := CleanUrl
  else
    Result := CleanUrl + '/api/events/raw';
end;

function TDFSeqSink.BuildClefPayload(const AEvent: TDFTraceEvent): string;
var
  Root, CrumbObj: TJSONObject;
  BreadcrumbsArray: TJSONArray;
  I: Integer;
  ExDetails: string;

  procedure AddUserProperty(const APair: TDFKeyValuePair);
  var
    PropName: string;
  begin
    if APair.Key.IsEmpty then
      Exit;

    // CLEF reserves names starting with @ for its own fields; @@ stands for a literal @
    if APair.Key.StartsWith('@') then
      PropName := '@' + APair.Key
    else
      PropName := APair.Key;

    // A JSON object must not repeat a name. The first value wins, so the properties the
    // sink sets itself cannot be overwritten by a tag or extra entry.
    if Root.GetValue(PropName) = nil then
      Root.AddPair(PropName, APair.ToJSONValue);
  end;

begin
  Root := TJSONObject.Create;
  try
    // Mandatory CLEF attributes (@t, @l, @m/@mt)
    Root.AddPair('@t', DateToISO8601(AEvent.TimestampUtc, True));
    Root.AddPair('@l', LevelToSeqString(AEvent.Level));

    if not AEvent.Message.IsEmpty then
      Root.AddPair('@m', AEvent.Message)
    else if not AEvent.ExceptionMessage.IsEmpty then
      Root.AddPair('@m', AEvent.ExceptionMessage);

    // Exception details (@x)
    if not AEvent.ExceptionClassName.IsEmpty then
    begin
      ExDetails := Format('%s: %s', [AEvent.ExceptionClassName, AEvent.ExceptionMessage]);
      if not AEvent.StackTrace.IsEmpty then
        ExDetails := ExDetails + sLineBreak + AEvent.StackTrace;

      Root.AddPair('@x', ExDetails);
      Root.AddPair('ExceptionType', AEvent.ExceptionClassName);
    end;

    // First-class context properties
    Root.AddPair('EventID', AEvent.EventID.ToString);
    Root.AddPair('ThreadID', TJSONNumber.Create(AEvent.ThreadID));
    Root.AddPair('Logger', AEvent.LoggerName);

    if not AEvent.AppName.IsEmpty then
      Root.AddPair('Application', AEvent.AppName);

    if not AEvent.Environment.IsEmpty then
      Root.AddPair('Environment', AEvent.Environment);

    if not AEvent.AppVersion.IsEmpty then
      Root.AddPair('AppVersion', AEvent.AppVersion);

    // Breadcrumb trace array
    if Length(AEvent.Breadcrumbs) > 0 then
    begin
      BreadcrumbsArray := TJSONArray.Create;
      for I := 0 to High(AEvent.Breadcrumbs) do
      begin
        CrumbObj := TJSONObject.Create;
        CrumbObj.AddPair('Timestamp', DateToISO8601(AEvent.Breadcrumbs[I].TimestampUtc, True));
        CrumbObj.AddPair('Message', AEvent.Breadcrumbs[I].Message);
        CrumbObj.AddPair('Category', AEvent.Breadcrumbs[I].Category);
        BreadcrumbsArray.AddElement(CrumbObj);
      end;
      Root.AddPair('Breadcrumbs', BreadcrumbsArray);
    end;

    // Top-level properties, as Seq expects them: a filter reads DurationMS > 1000
    // instead of Extra.DurationMS > 1000. Added last, after all properties of the sink.
    for I := 0 to High(AEvent.Tags) do
      AddUserProperty(AEvent.Tags[I]);
    for I := 0 to High(AEvent.Extra) do
      AddUserProperty(AEvent.Extra[I]);

    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function TDFSeqSink.GetDroppedCount: UInt64;
begin
  FLock.Enter;
  try
    Result := FDroppedCount;
  finally
    FLock.Leave;
  end;
end;

function TDFSeqSink.SkipWhilePaused: Boolean;
begin
  FLock.Enter;
  try
    Result := TThread.GetTickCount64 < FPausedUntil;
    if Result then
      Inc(FDroppedCount);
  finally
    FLock.Leave;
  end;
end;

procedure TDFSeqSink.RegisterFailure(APauseSeconds: Integer);
begin
  FLock.Enter;
  try
    Inc(FDroppedCount);
    if APauseSeconds > 0 then
      FPausedUntil := TThread.GetTickCount64 + UInt64(APauseSeconds) * 1000;
  finally
    FLock.Leave;
  end;
end;

class function TDFSeqSink.PauseFromRetryAfter(const AHeaderValue: string; ADefaultSeconds: Integer): Integer;
const
  // One hour: a server must not be able to silence the sink for the rest of the run
  MaxSeconds = 3600;
begin
  Result := StrToIntDef(AHeaderValue.Trim, -1);
  if Result < 0 then
    Result := ADefaultSeconds
  else if Result > MaxSeconds then
    Result := MaxSeconds;
end;

procedure TDFSeqSink.HandleResponse(const AResponse: IHTTPResponse);
var
  StatusCode: Integer;
begin
  StatusCode := AResponse.StatusCode;
  if StatusCode < 300 then Exit;

  if (StatusCode = 429) or (StatusCode >= 500) then
    RegisterFailure(PauseFromRetryAfter(AResponse.HeaderValue['Retry-After'], FPauseAfterErrorSeconds))
  else if StatusCode < 400 then
    // A redirect that was not followed. Every further event would get the same answer.
    RegisterFailure(FPauseAfterErrorSeconds)
  else
    // Other 4xx (e.g. invalid key): the server rejects this event, a pause would not help
    RegisterFailure(0);
end;

procedure TDFSeqSink.Emit(const AEvent: TDFTraceEvent);
var
  HTTP: THTTPClient;
  RequestStream: TStringStream;
  Response: IHTTPResponse;
  Payload, Url, Key: string;
begin
  if not FEnabled then Exit;

  FLock.Enter;
  try
    Url := FServerUrl;
    Key := FApiKey;
  finally
    FLock.Leave;
  end;

  if Url.Trim.IsEmpty then Exit;
  if SkipWhilePaused then Exit;

  try
    Url := ResolveIngestionUrl;
    Payload := BuildClefPayload(AEvent);

    HTTP := THTTPClient.Create;
    try
      HTTP.ConnectionTimeout := 3000;
      HTTP.ResponseTimeout := 5000;
      // Following a redirect sends the event and the key to an address other than the
      // configured one, possibly without TLS, so the application has to ask for it
      HTTP.HandleRedirects := FFollowRedirects;
      // By default the client turns a POST into a GET after 301 and 302, which would drop
      // the event. 303 asks for a GET by definition.
      HTTP.RedirectsWithGET := [THTTPRedirectWithGET.Post303];
      HTTP.ContentType := 'application/vnd.serilog.clef';

      if not Key.IsEmpty then
        HTTP.CustomHeaders['X-Seq-ApiKey'] := Key;

      RequestStream := TStringStream.Create(Payload, TEncoding.UTF8);
      try
        Response := HTTP.Post(Url, RequestStream);
      finally
        RequestStream.Free;
      end;
      HandleResponse(Response);
    finally
      HTTP.Free;
    end;
  except
    // Counts as a failed request and starts the pause, so that an unreachable server does
    // not delay every following event
    RegisterFailure(FPauseAfterErrorSeconds);
  end;
end;

end.
