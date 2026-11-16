// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Sinks.Sentry;

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
  /// Sends events to Sentry or a compatible server such as GlitchTip.
  /// </summary>
  /// <remarks>
  /// Tags are sent as text, extra values keep their type. The sink adds the tag app with the
  /// application name; of several entries with the same name, only the first is sent.
  /// Stack trace lines are sent as frames with function, module and line number. Sentry groups
  /// issues by function, so an error stays the same issue when lines move between releases.
  /// Frames in System, Vcl, FMX, Winapi and Data units are marked as not part of the
  /// application.
  /// Events are sent after scrubbing (see TDFTraceHub.EnablePIIScrubbing). Scrubbing is
  /// based on patterns and does not guarantee that all personal data is removed. With every
  /// request the server also receives the IP address of the sending computer; whether it is
  /// stored depends on the server settings. Use https for a server outside the local network,
  /// otherwise events and the key in the DSN are sent unencrypted.
  /// </remarks>
  // Only Windows is tested so far
  [ComponentPlatformsAttribute(pidWin32 or pidWin64)]
  TDFSentrySink = class(TComponent, IDFTraceSink)
  private
    FHub: TDFTraceHub;
    FEnabled: Boolean;
    FMinLevel: TDFLogLevel;
    FDSN: string;
    FParsedEndpoint: string;
    FParsedPublicKey: string;
    FLock: TCriticalSection;
    FPauseAfterErrorSeconds: Integer;
    FFollowRedirects: Boolean;
    FPausedUntil: UInt64;
    FDroppedCount: UInt64;

    procedure SetHub(const AValue: TDFTraceHub);
    procedure SetDSN(const AValue: string);
    function FormatGuid(const AGUID: TGUID): string;
    function LevelToSentryString(ALevel: TDFLogLevel): string;
    function BuildEventJson(const AEvent: TDFTraceEvent): TJSONObject;
    function BuildEnvelopePayload(const AEvent: TDFTraceEvent; out AEventID: string): string;
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

    /// <summary>Splits a DSN into the envelope endpoint and the public key.</summary>
    /// <param name="ADSN">DSN as shown in the project settings, for example
    /// https://key@host/42, or https://key@host/sentry/42 for a server below a path.</param>
    /// <param name="AEndpoint">Receives the URL that events are posted to.</param>
    /// <param name="APublicKey">Receives the public key.</param>
    /// <returns>False if the DSN has no key or no project ID; both outputs are empty then.</returns>
    class function ParseDSN(const ADSN: string; out AEndpoint, APublicKey: string): Boolean; static;

    /// <summary>Turns one line of a stack trace into a Sentry stack frame.</summary>
    /// <param name="ALine">A line as written by TDFStackWalker, for example
    /// "at Unit1.TForm1.Button1Click in Unit1:line 42" or "at user32.dll+$1A2B".</param>
    /// <returns>A new JSON object owned by the caller. Lines in another format are sent
    /// unchanged as function.</returns>
    class function BuildStackFrame(const ALine: string): TJSONObject; static;

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
    /// <remarks>Default Error: Sentry turns every distinct message into an issue, so lower
    /// levels quickly fill the issue list.</remarks>
    property MinLevel: TDFLogLevel read FMinLevel write FMinLevel default TDFLogLevel.Error;
    /// <summary>Address of the Sentry project, as shown under Client Keys (DSN) in the project
    /// settings.</summary>
    /// <remarks>The DSN is stored in the form file and ends up in the executable. It only allows
    /// sending events to the project, not reading data; rate limits in Sentry restrict misuse.
    /// Unless FollowRedirects is True, redirects are not followed: if the server answers
    /// with one, for example from http to https, the event is counted in <c>DroppedCount</c>,
    /// so enter the address the server finally uses. With https, Windows checks the
    /// certificate of the server; a server whose certificate Windows does not trust receives
    /// no events.</remarks>
    property DSN: string read FDSN write SetDSN;
    /// <summary>Seconds without sending attempts after a failed request.</summary>
    /// <remarks>Without a pause, every event would wait for the connection timeout while the
    /// server is unreachable, which delays all other sinks. Events during the pause are counted
    /// in <c>DroppedCount</c>. 0 disables the pause; while the server is unreachable, closing the
    /// application can then take several connection timeouts. A Retry-After header from the
    /// server takes precedence, up to one hour.</remarks>
    property PauseAfterErrorSeconds: Integer read FPauseAfterErrorSeconds write FPauseAfterErrorSeconds default 30;
    /// <summary>Follows redirects of the server. Off by default.</summary>
    /// <remarks>If True, the event and the key of the DSN are sent to the address the server names in
    /// its answer, which can be another host or an address without TLS. Turn it on only for
    /// a server you control, for example to keep installed applications reporting after the
    /// server has moved; a changed DNS entry does the same without a redirect. The request
    /// stays a POST, except after status 303. If a redirect ends at a page that answers with
    /// 200, such as a login page, the event counts as sent although it is lost.</remarks>
    property FollowRedirects: Boolean read FFollowRedirects write FFollowRedirects default False;
  end;

implementation

const
  // Reported to Sentry in the event and in the X-Sentry-Auth header
  SdkName = 'devformel.trace';
  SdkVersion = '1.0.0';

{ TDFSentrySink }

constructor TDFSentrySink.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FEnabled := True;
  FMinLevel := TDFLogLevel.Error;
  FDSN := '';
  FParsedEndpoint := '';
  FParsedPublicKey := '';
  FLock := TCriticalSection.Create;
  FPauseAfterErrorSeconds := 30;
  FFollowRedirects := False;
  FPausedUntil := 0;
  FDroppedCount := 0;
end;

destructor TDFSentrySink.Destroy;
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

procedure TDFSentrySink.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FHub) then
    FHub := nil;
end;

procedure TDFSentrySink.SetHub(const AValue: TDFTraceHub);
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

procedure TDFSentrySink.SetDSN(const AValue: string);
begin
  if FDSN <> AValue then
  begin
    FLock.Enter;
    try
      FDSN := AValue.Trim;
      ParseDSN(FDSN, FParsedEndpoint, FParsedPublicKey);
    finally
      FLock.Leave;
    end;
  end;
end;

function TDFSentrySink.GetEnabled: Boolean;
begin
  Result := FEnabled;
end;

function TDFSentrySink.GetMinLevel: TDFLogLevel;
begin
  Result := FMinLevel;
end;

class function TDFSentrySink.ParseDSN(const ADSN: string; out AEndpoint, APublicKey: string): Boolean;
var
  URI: TURI;
  PathParts: TArray<string>;
  ProjectID, PathPrefix, HostPart: string;
  I: Integer;
begin
  AEndpoint := '';
  APublicKey := '';

  if ADSN.IsEmpty then
    Exit(False);

  try
    URI := TURI.Create(ADSN);

    // The project ID is the last path segment; anything before it is the path the
    // server runs below, which a self-hosted Sentry or GlitchTip may use
    PathParts := URI.Path.Split(['/'], TStringSplitOptions.ExcludeEmpty);
    if Length(PathParts) > 0 then
    begin
      ProjectID := PathParts[High(PathParts)];
      for I := 0 to High(PathParts) - 1 do
        PathPrefix := PathPrefix + '/' + PathParts[I];
    end;

    HostPart := URI.Host;
    if (URI.Port > 0) and
      not (SameText(URI.Scheme, 'http') and (URI.Port = 80)) and
      not (SameText(URI.Scheme, 'https') and (URI.Port = 443)) then
      HostPart := HostPart + ':' + URI.Port.ToString;

    if not URI.Username.IsEmpty and not ProjectID.IsEmpty then
    begin
      APublicKey := URI.Username;
      AEndpoint := Format('%s://%s%s/api/%s/envelope/', [URI.Scheme, HostPart, PathPrefix, ProjectID]);
    end;
  except
    AEndpoint := '';
    APublicKey := '';
  end;
  Result := not AEndpoint.IsEmpty;
end;

function TDFSentrySink.FormatGuid(const AGUID: TGUID): string;
begin
  Result := AGUID.ToString.Replace('{', '').Replace('}', '').Replace('-', '').ToLower;
end;

class function TDFSentrySink.BuildStackFrame(const ALine: string): TJSONObject;
const
  // Delphi's own units. Sentry groups by the frames of the application, so these must not count.
  FrameworkPrefixes: array[0..4] of string = ('System.', 'Vcl.', 'FMX.', 'Winapi.', 'Data.');
var
  Text, ProcName, UnitName, ModuleName, Prefix: string;
  InPos, LinePos, PlusPos, LineNo: Integer;
  InApp: Boolean;
begin
  Result := TJSONObject.Create;
  try
    Text := ALine.Trim;
    if not Text.StartsWith('at ') then
    begin
      Result.AddPair('function', Text);
      Exit;
    end;
    Text := Text.Substring(3).Trim;

    // Not resolved: "module+$offset", or "$address" outside any module
    PlusPos := Text.IndexOf('+$');
    if Text.StartsWith('$') or (PlusPos > 0) then
    begin
      Result.AddPair('function', Text);
      if PlusPos > 0 then
      begin
        ModuleName := Text.Substring(0, PlusPos);
        Result.AddPair('package', ModuleName);
        Result.AddPair('in_app', TJSONBool.Create(SameText(ModuleName, ExtractFileName(ParamStr(0)))));
      end;
      Exit;
    end;

    // Resolved with the MAP file: "proc in unit:line n", unit and line are optional
    ProcName := Text;
    UnitName := '';
    LineNo := 0;
    InPos := Text.IndexOf(' in ');
    if InPos > 0 then
    begin
      ProcName := Text.Substring(0, InPos);
      UnitName := Text.Substring(InPos + 4);
      LinePos := UnitName.IndexOf(':line ');
      if LinePos >= 0 then
      begin
        LineNo := StrToIntDef(UnitName.Substring(LinePos + 6), 0);
        UnitName := UnitName.Substring(0, LinePos);
      end;
    end;

    Result.AddPair('function', ProcName);
    if not UnitName.IsEmpty then
      Result.AddPair('module', UnitName);
    if LineNo > 0 then
      Result.AddPair('lineno', TJSONNumber.Create(LineNo));

    // The unit System itself has no dot, so the unit is checked with one appended
    InApp := True;
    for Prefix in FrameworkPrefixes do
      if ProcName.StartsWith(Prefix, True) or (UnitName + '.').StartsWith(Prefix, True) then
        InApp := False;
    Result.AddPair('in_app', TJSONBool.Create(InApp));
  except
    Result.Free;
    raise;
  end;
end;

// Sentry shows breadcrumbs of type http, navigation and user with their own icon
function CrumbTypeToSentryString(ACrumbType: TDFBreadcrumbType): string;
begin
  case ACrumbType of
    TDFBreadcrumbType.Navigation: Result := 'navigation';
    TDFBreadcrumbType.Http:       Result := 'http';
    TDFBreadcrumbType.User:       Result := 'user';
  else
    // Sentry has no type for system events
    Result := 'default';
  end;
end;

function TDFSentrySink.LevelToSentryString(ALevel: TDFLogLevel): string;
begin
  case ALevel of
    TDFLogLevel.Debug:   Result := 'debug';
    TDFLogLevel.Info:    Result := 'info';
    TDFLogLevel.Warning: Result := 'warning';
    TDFLogLevel.Error:   Result := 'error';
    TDFLogLevel.Fatal:   Result := 'fatal';
  else
    Result := 'error';
  end;
end;

function TDFSentrySink.BuildEventJson(const AEvent: TDFTraceEvent): TJSONObject;
var
  EventObj, SdkObj, MsgObj, ExObj, ValueObj, StackObj: TJSONObject;
  ValuesArray, BreadcrumbsArray, FramesArray: TJSONArray;
  TagsObj, ExtraObj: TJSONObject;
  CrumbObj: TJSONObject;
  I: Integer;
  Lines: TArray<string>;
  ISOStamp: string;
begin
  TagsObj := nil;

  EventObj := TJSONObject.Create;
  try
    ISOStamp := DateToISO8601(AEvent.TimestampUtc, True);

    EventObj.AddPair('event_id', FormatGuid(AEvent.EventID));
    EventObj.AddPair('timestamp', ISOStamp);
    EventObj.AddPair('platform', 'native');
    EventObj.AddPair('level', LevelToSentryString(AEvent.Level));
    EventObj.AddPair('logger', AEvent.LoggerName);

    if not AEvent.Environment.IsEmpty then
      EventObj.AddPair('environment', AEvent.Environment);

    if not AEvent.AppVersion.IsEmpty then
      EventObj.AddPair('release', AEvent.AppVersion);

    if not AEvent.AppName.IsEmpty then
    begin
      EventObj.AddPair('server_name', AEvent.AppName);

      // Sentry filters and groups by tags, not by server_name.
      if not Assigned(TagsObj) then
        TagsObj := TJSONObject.Create;
      TagsObj.AddPair('app', AEvent.AppName);
    end;

    SdkObj := TJSONObject.Create;
    SdkObj.AddPair('name', SdkName);
    SdkObj.AddPair('version', SdkVersion);
    EventObj.AddPair('sdk', SdkObj);

    if not AEvent.Message.IsEmpty then
    begin
      MsgObj := TJSONObject.Create;
      MsgObj.AddPair('formatted', AEvent.Message);
      EventObj.AddPair('message', MsgObj);
    end;

    if not AEvent.ExceptionClassName.IsEmpty then
    begin
      ExObj := TJSONObject.Create;
      ValuesArray := TJSONArray.Create;

      ValueObj := TJSONObject.Create;
      ValueObj.AddPair('type', AEvent.ExceptionClassName);
      ValueObj.AddPair('value', AEvent.ExceptionMessage);

      if not AEvent.StackTrace.IsEmpty then
      begin
        StackObj := TJSONObject.Create;
        FramesArray := TJSONArray.Create;

        // Sentry expects the outermost caller first
        Lines := AEvent.StackTrace.Split([sLineBreak, #10]);
        for I := High(Lines) downto 0 do
          if not Lines[I].Trim.IsEmpty then
            FramesArray.AddElement(BuildStackFrame(Lines[I]));

        StackObj.AddPair('frames', FramesArray);
        ValueObj.AddPair('stacktrace', StackObj);
      end;

      ValuesArray.AddElement(ValueObj);
      ExObj.AddPair('values', ValuesArray);
      EventObj.AddPair('exception', ExObj);
    end;

    if Length(AEvent.Breadcrumbs) > 0 then
    begin
      BreadcrumbsArray := TJSONArray.Create;
      for I := 0 to High(AEvent.Breadcrumbs) do
      begin
        CrumbObj := TJSONObject.Create;
        CrumbObj.AddPair('timestamp', DateToISO8601(AEvent.Breadcrumbs[I].TimestampUtc, True));
        CrumbObj.AddPair('message', AEvent.Breadcrumbs[I].Message);
        CrumbObj.AddPair('category', AEvent.Breadcrumbs[I].Category);
        CrumbObj.AddPair('type', CrumbTypeToSentryString(AEvent.Breadcrumbs[I].CrumbType));
        CrumbObj.AddPair('level', LevelToSentryString(AEvent.Breadcrumbs[I].Level));
        BreadcrumbsArray.AddElement(CrumbObj);
      end;
      EventObj.AddPair('breadcrumbs', BreadcrumbsArray);
    end;

    for I := 0 to High(AEvent.Tags) do
    begin
      if AEvent.Tags[I].Key.IsEmpty then
        Continue;
      if not Assigned(TagsObj) then
        TagsObj := TJSONObject.Create;
      // Sentry only accepts text as tag values. A JSON object must not repeat a name; the
      // first value wins, so a tag named app cannot overwrite the one set above.
      if TagsObj.GetValue(AEvent.Tags[I].Key) = nil then
        TagsObj.AddPair(AEvent.Tags[I].Key, AEvent.Tags[I].Value);
    end;

    if Assigned(TagsObj) then
    begin
      EventObj.AddPair('tags', TagsObj);
      // EventObj owns it now; nil prevents a double free in the except block.
      TagsObj := nil;
    end;

    if Length(AEvent.Extra) > 0 then
    begin
      ExtraObj := TJSONObject.Create;
      // Owned by EventObj from here on, so it is freed if a value below raises
      EventObj.AddPair('extra', ExtraObj);
      for I := 0 to High(AEvent.Extra) do
        if not AEvent.Extra[I].Key.IsEmpty and (ExtraObj.GetValue(AEvent.Extra[I].Key) = nil) then
          ExtraObj.AddPair(AEvent.Extra[I].Key, AEvent.Extra[I].ToJSONValue);
    end;

    Result := EventObj;
  except
    TagsObj.Free;
    FreeAndNil(EventObj);
    raise;
  end;
end;

function TDFSentrySink.BuildEnvelopePayload(const AEvent: TDFTraceEvent; out AEventID: string): string;
var
  EnvelopeHeader, ItemHeader, EventObj: TJSONObject;
  EventJsonStr: string;
begin
  AEventID := FormatGuid(AEvent.EventID);

  EnvelopeHeader := TJSONObject.Create;
  ItemHeader := TJSONObject.Create;
  EventObj := BuildEventJson(AEvent);
  try
    EnvelopeHeader.AddPair('event_id', AEventID);

    ItemHeader.AddPair('type', 'event');
    ItemHeader.AddPair('content_type', 'application/json');

    EventJsonStr := EventObj.ToJSON;

    Result := EnvelopeHeader.ToJSON + #10 +
              ItemHeader.ToJSON + #10 +
              EventJsonStr + #10;
  finally
    FreeAndNil(EnvelopeHeader);
    FreeAndNil(ItemHeader);
    FreeAndNil(EventObj);
  end;
end;

function TDFSentrySink.GetDroppedCount: UInt64;
begin
  FLock.Enter;
  try
    Result := FDroppedCount;
  finally
    FLock.Leave;
  end;
end;

function TDFSentrySink.SkipWhilePaused: Boolean;
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

procedure TDFSentrySink.RegisterFailure(APauseSeconds: Integer);
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

class function TDFSentrySink.PauseFromRetryAfter(const AHeaderValue: string; ADefaultSeconds: Integer): Integer;
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

procedure TDFSentrySink.HandleResponse(const AResponse: IHTTPResponse);
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

procedure TDFSentrySink.Emit(const AEvent: TDFTraceEvent);
var
  HTTP: THTTPClient;
  RequestStream: TStringStream;
  Response: IHTTPResponse;
  Payload, EventID, Endpoint, PublicKey: string;
  AuthHeader: string;
begin
  if not FEnabled then Exit;

  FLock.Enter;
  try
    Endpoint := FParsedEndpoint;
    PublicKey := FParsedPublicKey;
  finally
    FLock.Leave;
  end;

  if Endpoint.IsEmpty or PublicKey.IsEmpty then Exit;
  if SkipWhilePaused then Exit;

  try
    Payload := BuildEnvelopePayload(AEvent, EventID);

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
      HTTP.ContentType := 'application/x-sentry-envelope';

      AuthHeader := Format('Sentry sentry_version=7, sentry_client=%s/%s, sentry_key=%s', [SdkName, SdkVersion, PublicKey]);
      HTTP.CustomHeaders['X-Sentry-Auth'] := AuthHeader;

      RequestStream := TStringStream.Create(Payload, TEncoding.UTF8);
      try
        Response := HTTP.Post(Endpoint, RequestStream);
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
