// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Hub;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  System.TypInfo,
  DevFormel.Trace.Types,
  DevFormel.Trace.Engine;

type
  /// <summary>Signature of Application.OnException in VCL and FMX; holds the handler that was
  /// assigned before the hub hooked the event.</summary>
  /// <exclude/>
  TDFGUIExceptionEvent = procedure(Sender: TObject; E: Exception) of object;

  /// <summary>
  /// Collects events, exceptions and breadcrumbs and passes them to the connected sinks in a
  /// background thread.
  /// </summary>
  /// <remarks>
  /// One hub per application is usual. Sinks are connected through their Hub property.
  /// Before an event reaches the sinks, Consent decides which sinks receive it, and personal
  /// data is removed if EnablePIIScrubbing is True. Track methods return at once and never
  /// raise an exception, so they can be called from any thread and from except blocks.
  /// A message, an exception message and each tag or extra value is cut after 8,000
  /// characters and then ends with [truncated]. Stack traces are not cut.
  /// </remarks>
  // Only Windows is tested so far
  [ComponentPlatformsAttribute(pidWin32 or pidWin64)]
  TDFTraceHub = class(TComponent)
  private
    FAppName: string;
    FEngine: TDFTraceEngine;
    FEnabled: Boolean;
    FAutoHookExceptions: Boolean;
    FShowGUIExceptionDialog: Boolean;
    FConsent: TDFConsent;
    FEnablePIIScrubbing: Boolean;
    FEnvironment: string;
    FAppVersion: string;
    // File version of the executable, used while AppVersion is empty
    FExeVersion: string;
    FMaxQueueSize: Integer;
    FMaxBreadcrumbs: Integer;
    FShutdownTimeoutMS: Integer;
    FBreadcrumbs: TList<TDFBreadcrumb>;
    FTags: TArray<TDFKeyValuePair>;
    // Guards breadcrumbs and tags, which any thread may change
    FContextLock: TCriticalSection;
    FOldGUIExceptionEvent: TDFGUIExceptionEvent;
    FGUIHookInstalled: Boolean;

    procedure SetAutoHookExceptions(const AValue: Boolean);
    procedure SetMaxQueueSize(const AValue: Integer);
    procedure SetMaxBreadcrumbs(const AValue: Integer);
    procedure SetConsent(const AValue: TDFConsent);
    procedure InstallExceptionHooks;
    procedure UninstallExceptionHooks;
    procedure InstallGUIExceptionHook;
    procedure UninstallGUIExceptionHook;
    procedure GUIExceptionEvent(Sender: TObject; E: Exception);
    function GetQueueCount: Integer;
    function GetDroppedCount: UInt64;
  protected
    /// <summary>Hooks unhandled exceptions once the properties have been read from the form
    /// file, so that AutoHookExceptions set to False in the Object Inspector takes effect.</summary>
    procedure Loaded; override;

    /// <summary>
    /// Single entry point for all events. Checks Enabled and Consent, fills in the application
    /// context and queues the event.
    /// </summary>
    /// <param name="AEvent">The event to submit. AppName, Environment, AppVersion and, if requested,
    /// Breadcrumbs are overwritten. The tags of the hub are appended to the tags of the event.</param>
    /// <param name="AAttachBreadcrumbs">True to attach a copy of the current breadcrumbs if the
    /// event has level Error or Fatal.</param>
    /// <remarks>
    /// Personal data is removed later in the worker thread, depending on <c>EnablePIIScrubbing</c>
    /// at the time of this call; <c>Consent</c> at the time of this call decides which sinks
    /// receive the event. Never raises an exception.
    /// </remarks>
    procedure SubmitEvent(var AEvent: TDFTraceEvent; AAttachBreadcrumbs: Boolean);
  public
    /// <summary>Creates the hub. At runtime it starts the background thread and, if
    /// AutoHookExceptions is True, hooks unhandled exceptions.</summary>
    /// <param name="AOwner">Component that frees the hub, usually a form or data module.
    /// nil if the application frees the hub itself.</param>
    constructor Create(AOwner: TComponent); override;
    /// <summary>Removes the exception hooks and passes the queued events to the sinks, for at
    /// most ShutdownTimeoutMS.</summary>
    destructor Destroy; override;

    /// <summary>
    /// Sends a message to the sinks.
    /// </summary>
    /// <param name="AMessage">Text of the event.</param>
    /// <param name="ALevel">Level of the event. Sinks with a higher MinLevel ignore it.</param>
    procedure TrackEvent(const AMessage: string; ALevel: TDFLogLevel = TDFLogLevel.Info); overload;

    /// <summary>
    /// Sends a message with additional values to the sinks.
    /// </summary>
    /// <param name="AMessage">Text of the event.</param>
    /// <param name="AExtra">Values that belong to this event, such as an order number.</param>
    /// <param name="ALevel">Level of the event. Sinks with a higher MinLevel ignore it.</param>
    procedure TrackEvent(const AMessage: string; const AExtra: array of TDFKeyValuePair;
      ALevel: TDFLogLevel = TDFLogLevel.Info); overload;

    /// <summary>
    /// Sends an exception with class name, message and stack trace to the sinks, at level
    /// Error or Fatal with the current breadcrumbs.
    /// </summary>
    /// <param name="AException">The exception, usually from an except block. The hub reads it
    /// during the call and does not keep or free it. nil is ignored.</param>
    /// <param name="ALevel">Level of the event.</param>
    procedure TrackException(const AException: Exception; ALevel: TDFLogLevel = TDFLogLevel.Error); overload;

    /// <summary>
    /// Sends an exception with additional values to the sinks.
    /// </summary>
    /// <param name="AException">The exception, usually from an except block. The hub reads it
    /// during the call and does not keep or free it. nil is ignored.</param>
    /// <param name="AExtra">Values that belong to this event, such as the record being saved.</param>
    /// <param name="ALevel">Level of the event.</param>
    procedure TrackException(const AException: Exception; const AExtra: array of TDFKeyValuePair;
      ALevel: TDFLogLevel = TDFLogLevel.Error); overload;

    /// <summary>
    /// Starts a time measurement that sends one event when it ends.
    /// </summary>
    /// <param name="AOperationName">Name of the measured operation, sent as extra value Operation.</param>
    /// <param name="ALevel">Level of the event.</param>
    /// <returns>The running measurement. It ends when Stop is called or the last reference
    /// is released.</returns>
    function TrackScope(const AOperationName: string;
      ALevel: TDFLogLevel = TDFLogLevel.Info): IDFTraceScope; overload;

    /// <summary>
    /// Starts a time measurement with additional values that sends one event when it ends.
    /// </summary>
    /// <param name="AOperationName">Name of the measured operation, sent as extra value Operation.</param>
    /// <param name="AExtra">Values sent with the event in addition to DurationMS and Operation.</param>
    /// <param name="ALevel">Level of the event.</param>
    /// <returns>The running measurement. It ends when Stop is called or the last reference
    /// is released.</returns>
    function TrackScope(const AOperationName: string; const AExtra: array of TDFKeyValuePair;
      ALevel: TDFLogLevel = TDFLogLevel.Info): IDFTraceScope; overload;

    /// <summary>
    /// Sets a tag that is attached to every following event, including unhandled exceptions.
    /// </summary>
    /// <param name="AKey">Name of the tag. An existing tag with the same name, ignoring case,
    /// is replaced. Empty names are ignored.</param>
    /// <param name="AValue">Value of the tag.</param>
    /// <remarks>Tags are meant for values that hold for a longer time, such as tenant or
    /// module. They apply to the whole hub, not to the calling thread, so they do not fit
    /// a server that handles requests for different tenants at the same time.</remarks>
    procedure SetTag(const AKey, AValue: string);

    /// <summary>Removes a tag set with SetTag.</summary>
    /// <param name="AKey">Name of the tag, ignoring case.</param>
    procedure RemoveTag(const AKey: string);

    /// <summary>
    /// Sends one event with the version of the operating system, the processor architecture
    /// and the number of CPU cores.
    /// </summary>
    /// <remarks>User and computer name identify a person and are only included when
    /// <c>EnablePIIScrubbing</c> is False.</remarks>
    /// <param name="ALevel">Level of the event.</param>
    procedure TrackSystemInfo(ALevel: TDFLogLevel = TDFLogLevel.Info);

    /// <summary>
    /// Records a step, such as a button click, that is sent with the following errors.
    /// </summary>
    /// <remarks>
    /// Breadcrumbs stay in memory and are attached to every following event of level Error or
    /// Fatal, so an error report shows what happened before. When MaxBreadcrumbs is reached,
    /// the oldest is removed. Nothing is recorded while Consent is None. Message and
    /// category are cut after 1,000 characters and then end with [truncated].
    /// </remarks>
    /// <param name="AMessage">What happened, for example 'Invoice dialog opened'.</param>
    /// <param name="ACategory">Free text for grouping, for example 'ui' or 'db'.</param>
    /// <param name="ALevel">Level of the breadcrumb.</param>
    /// <param name="ACrumbType">Kind of step. Only the Sentry sink uses it.</param>
    procedure AddBreadcrumb(const AMessage: string; const ACategory: string = 'app';
      ALevel: TDFLogLevel = TDFLogLevel.Info; ACrumbType: TDFBreadcrumbType = TDFBreadcrumbType.Default);

    /// <summary>Removes all breadcrumbs.</summary>
    procedure ClearBreadcrumbs;

    /// <summary>Adds a sink that receives events from now on.</summary>
    /// <param name="ASink">The sink. Registering a sink twice has no effect.</param>
    /// <remarks>The sink components of DevFormel Trace call this themselves when their Hub
    /// property is set. Call it for own sinks that implement IDFTraceSink, and call
    /// UnregisterSink before such a sink is freed.</remarks>
    procedure RegisterSink(const ASink: IDFTraceSink);

    /// <summary>Removes a sink, so that it receives no further events.</summary>
    /// <param name="ASink">The sink.</param>
    /// <remarks>Waits until an event currently being written has been passed to all sinks.
    /// With an unreachable server this can take up to the HTTP timeout of the sink.</remarks>
    procedure UnregisterSink(const ASink: IDFTraceSink);

    /// <summary>Waits until all queued events have been passed to the sinks, up to the specified timeout.</summary>
    /// <param name="ATimeoutMS">Maximum wait time in milliseconds.</param>
    /// <returns>True if all events were passed to the sinks within the timeout.</returns>
    /// <remarks>Passed means that Emit of each sink has returned, not that a server has
    /// accepted the event; the HTTP sinks count failed events in their DroppedCount.
    /// Flush blocks the calling thread. Called from the main thread, the user interface does
    /// not respond while it waits, so use a short timeout there.</remarks>
    function Flush(ATimeoutMS: Integer = 2000): Boolean;

    /// <summary>Number of events waiting to be passed to the sinks.</summary>
    property QueueCount: Integer read GetQueueCount;
    /// <summary>Number of events discarded since start because the queue was full.</summary>
    property DroppedCount: UInt64 read GetDroppedCount;
  published
    /// <summary>Name of the application, sent with every event.</summary>
    /// <remarks>Default: the file name of the executable, for example MyApp.exe. In the
    /// Object Inspector the field stays empty unless a name is entered.</remarks>
    property AppName: string read FAppName write FAppName;
    /// <summary>Turns the hub on or off. While False, the hub records neither events nor
    /// breadcrumbs.</summary>
    property Enabled: Boolean read FEnabled write FEnabled default True;
    /// <summary>Reports unhandled exceptions, both those that end the program and those in
    /// event handlers of a VCL or FMX application.</summary>
    /// <remarks>
    /// Only the first hub with AutoHookExceptions reports unhandled exceptions; when it is freed,
    /// no other hub takes over. Exceptions that end the program are sent as Fatal and flushed
    /// before the program ends; exceptions in event handlers of a VCL or FMX application are
    /// sent as Error, and the application keeps running.
    /// Application.OnException is replaced, and a handler assigned before is still called. A
    /// handler assigned later, for example by a TApplicationEvents created after the hub,
    /// replaces the hook.
    /// Exceptions raised in TThread.Execute are caught by the thread and kept in its
    /// FatalException; they never reach the hub. Catch them in Execute and call TrackException.
    /// </remarks>
    property AutoHookExceptions: Boolean read FAutoHookExceptions write SetAutoHookExceptions default True;
    /// <summary>Shows the usual exception dialog of the application after reporting an
    /// unhandled exception in an event handler.</summary>
    /// <remarks>Only applies if Application.OnException had no handler when the hub hooked it.
    /// Otherwise that handler is called and decides itself whether to show a dialog.</remarks>
    property ShowGUIExceptionDialog: Boolean read FShowGUIExceptionDialog write FShowGUIExceptionDialog default True;
    /// <summary>What the user has agreed to: no recording, only sinks that keep events where
    /// the application runs, or all sinks.</summary>
    /// <remarks>
    /// LocalOnly passes events to the log file, memo and Windows event log sinks, and to own
    /// sinks that implement IDFLocalSink. Seq, Sentry and all other sinks receive nothing.
    /// A log file in a network folder still counts as local.
    /// The value at the time of the call applies to each event; events queued before a change
    /// are passed on as before. Every change clears the breadcrumbs, so that breadcrumbs from a
    /// LocalOnly phase do not reach Sentry with the first event after a change to Full.
    /// </remarks>
    property Consent: TDFConsent read FConsent write SetConsent default TDFConsent.Full;
    /// <summary>Removes personal data and secrets from events before they reach the sinks.</summary>
    /// <remarks>Covers e-mail addresses, IPv4 addresses, the current user and computer name,
    /// user names in paths such as C:\Users\name, passwords and tokens written as key=value,
    /// and Bearer tokens. See TDFPIISanitizer for what is not detected and how to add rules.
    /// The value at the time of the call applies to each event.
    /// Detection is based on patterns, so there is no guarantee that all personal data and
    /// secrets are removed. Names of other people, postal addresses or customer numbers in
    /// free text are not detected. Check what your application passes to the hub.
    /// A text that is cut because of its length is cut at the end of a word where one lies
    /// within the last 200 characters. A longer word without spaces is cut in the middle,
    /// and a part of an address at its end is then not detected.</remarks>
    property EnablePIIScrubbing: Boolean read FEnablePIIScrubbing write FEnablePIIScrubbing default True;
    /// <summary>Name of the environment, sent with every event, for example 'Production' or
    /// 'Staging'.</summary>
    property Environment: string read FEnvironment write FEnvironment;
    /// <summary>Application version attached to all events; Sentry uses it as release.</summary>
    /// <remarks>If empty, the file version of the executable is used (Windows only), for
    /// example 2.3.1.140, as set in the project options under version information.</remarks>
    property AppVersion: string read FAppVersion write FAppVersion;
    /// <summary>Maximum number of events waiting to be passed to the sinks.</summary>
    /// <remarks>When the queue is full, a new event below Error is discarded, and an Error or
    /// Fatal event replaces the oldest waiting event; both are counted in DroppedCount.
    /// Can be changed at any time; when reduced, the oldest waiting events are discarded.
    /// Values below 1 are treated as 1. Each waiting event holds a copy of the breadcrumbs,
    /// so with a stalled sink a large queue can use tens of megabytes.</remarks>
    property MaxQueueSize: Integer read FMaxQueueSize write SetMaxQueueSize default 10000;
    /// <summary>Maximum number of breadcrumbs kept; the oldest is removed when a new one is added.</summary>
    /// <remarks>0 or less: no breadcrumbs are recorded.</remarks>
    property MaxBreadcrumbs: Integer read FMaxBreadcrumbs write SetMaxBreadcrumbs default 100;
    /// <summary>Maximum time in milliseconds spent passing queued events to the sinks when the
    /// hub or a sink is freed.</summary>
    /// <remarks>Events still queued after this time are discarded and counted in
    /// <c>DroppedCount</c>. A sink call already in progress, such as an HTTP request to an
    /// unreachable server, cannot be interrupted and may exceed the limit.</remarks>
    property ShutdownTimeoutMS: Integer read FShutdownTimeoutMS write FShutdownTimeoutMS default 2000;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.Math,
  System.Rtti,
  System.Diagnostics,
  DevFormel.Trace.StackWalker;

type
  TDFExceptProc = procedure(ExceptObject: TObject; ExceptAddr: Pointer);

  // Created only by TDFTraceHub.TrackScope. Lives in this unit to reach the protected
  // SubmitEvent, so scope events take the same path as all other events.
  TDFTraceScope = class(TInterfacedObject, IDFTraceScope)
  private
    FHub: TDFTraceHub;
    FOperationName: string;
    FLevel: TDFLogLevel;
    FExtra: TArray<TDFKeyValuePair>;
    FStopwatch: TStopwatch;
    FStopped: Boolean;
  public
    constructor Create(AHub: TDFTraceHub; const AOperationName: string;
      const AExtra: TArray<TDFKeyValuePair>; ALevel: TDFLogLevel);
    destructor Destroy; override;
    procedure Stop;
  end;

var
  FOldExceptProc: Pointer = nil;
  FGlobalHub: TDFTraceHub = nil;
  // A record without heap memory: nothing to free, so a hub that is freed after the
  // finalization of this unit can still use it
  FHookLock: TLightweightMREW;

function ReadExeFileVersion: string;
{$IFDEF MSWINDOWS}
var
  FileName: string;
  Handle, Size: DWORD;
  Buffer: TBytes;
  Info: PVSFixedFileInfo;
  InfoSize: UINT;
begin
  Result := '';
  FileName := ParamStr(0);
  Size := GetFileVersionInfoSize(PChar(FileName), Handle);
  if Size = 0 then
    Exit;

  SetLength(Buffer, Size);
  if GetFileVersionInfo(PChar(FileName), 0, Size, Pointer(Buffer)) and
    VerQueryValue(Pointer(Buffer), '\', Pointer(Info), InfoSize) and
    (InfoSize >= SizeOf(TVSFixedFileInfo)) then
    Result := Format('%d.%d.%d.%d', [HiWord(Info.dwFileVersionMS), LoWord(Info.dwFileVersionMS),
      HiWord(Info.dwFileVersionLS), LoWord(Info.dwFileVersionLS)]);
end;
{$ELSE}
begin
  Result := '';
end;
{$ENDIF}

// VCL and FMX register Application.HandleException in System.Classes, so the object of that
// method is the application, whatever owns the hub
function FindApplication: TObject;
begin
  if Assigned(System.Classes.ApplicationHandleException) then
    Result := TObject(TMethod(System.Classes.ApplicationHandleException).Data)
  else
    Result := nil;
end;

function PairsToArray(const APairs: array of TDFKeyValuePair): TArray<TDFKeyValuePair>;
var
  I: Integer;
begin
  SetLength(Result, Length(APairs));
  for I := 0 to High(APairs) do
    Result[I] := APairs[I];
end;

{ TDFTraceScope }

constructor TDFTraceScope.Create(AHub: TDFTraceHub; const AOperationName: string;
  const AExtra: TArray<TDFKeyValuePair>; ALevel: TDFLogLevel);
begin
  inherited Create;
  FHub := AHub;
  FOperationName := AOperationName;
  FExtra := AExtra;
  FLevel := ALevel;
  FStopwatch := TStopwatch.StartNew;
end;

destructor TDFTraceScope.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TDFTraceScope.Stop;
var
  ElapsedMS: Int64;
  Event: TDFTraceEvent;
  Measured: TArray<TDFKeyValuePair>;
begin
  if FStopped then
    Exit;
  FStopped := True;

  try
    FStopwatch.Stop;
    ElapsedMS := FStopwatch.ElapsedMilliseconds;

    Event := TDFTraceEvent.Create(FLevel, Format('Performance [%s]: %d ms', [FOperationName, ElapsedMS]));
    // Measured values first: with several entries of the same name, sinks keep the first
    Measured := [TDFKeyValuePair.Create('DurationMS', ElapsedMS),
      TDFKeyValuePair.Create('Operation', FOperationName)];
    Event.Extra := Measured + FExtra;
    FHub.SubmitEvent(Event, False);
  except
    // Stop also runs in the destructor, which must not raise
  end;
end;

procedure CustomExceptProc(ExceptObject: TObject; ExceptAddr: Pointer);
begin
  if Assigned(FGlobalHub) and FGlobalHub.Enabled and (ExceptObject is Exception) then
  begin
    try
      // The program ends after this handler, so this is the last chance to send the event
      FGlobalHub.TrackException(Exception(ExceptObject), TDFLogLevel.Fatal);
      FGlobalHub.Flush(FGlobalHub.ShutdownTimeoutMS);
    except
      // The previous handler below has to run in any case
    end;
  end;

  if Assigned(FOldExceptProc) then
    TDFExceptProc(FOldExceptProc)(ExceptObject, ExceptAddr);
end;

{ TDFTraceHub }

constructor TDFTraceHub.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FEnabled := True;
  FAutoHookExceptions := True;
  FShowGUIExceptionDialog := True;
  FConsent := TDFConsent.Full;
  FEnablePIIScrubbing := True;
  FEnvironment := 'Production';
  FAppVersion := '';
  FMaxQueueSize := 10000;
  FMaxBreadcrumbs := 100;
  FShutdownTimeoutMS := 2000;
  FGUIHookInstalled := False;
  FOldGUIExceptionEvent := nil;

  // No worker thread inside the IDE when the hub is placed on a form; all methods check FEngine
  if not (csDesigning in ComponentState) then
  begin
    FEngine := TDFTraceEngine.Create(FMaxQueueSize);
    FExeVersion := ReadExeFileVersion;
    // Not in the designer: there ParamStr(0) is bds.exe, and the form file would store it
    FAppName := ExtractFileName(ParamStr(0));
  end;
  FBreadcrumbs := TList<TDFBreadcrumb>.Create;
  FContextLock := TCriticalSection.Create;

  if not (csDesigning in ComponentState) and not (csLoading in ComponentState) and FAutoHookExceptions then
    InstallExceptionHooks;

  // Exception.StackTrace then shows where an exception was raised, not where it was reported
  if not (csDesigning in ComponentState) then
    TDFStackWalker.InstallExceptionStackHooks;
end;

destructor TDFTraceHub.Destroy;
begin
  UninstallExceptionHooks;

  // Destroy passes remaining events to the sinks, limited by ShutdownTimeoutMS
  if Assigned(FEngine) then
    FEngine.ShutdownTimeoutMS := FShutdownTimeoutMS;
  FreeAndNil(FEngine);
  FreeAndNil(FBreadcrumbs);
  FreeAndNil(FContextLock);

  inherited Destroy;
end;

procedure TDFTraceHub.Loaded;
begin
  inherited Loaded;
  if not (csDesigning in ComponentState) and FAutoHookExceptions then
    InstallExceptionHooks;
end;

procedure TDFTraceHub.SetAutoHookExceptions(const AValue: Boolean);
begin
  if FAutoHookExceptions <> AValue then
  begin
    FAutoHookExceptions := AValue;
    if not (csDesigning in ComponentState) then
    begin
      if FAutoHookExceptions then
        InstallExceptionHooks
      else
        UninstallExceptionHooks;
    end;
  end;
end;

procedure TDFTraceHub.SetMaxQueueSize(const AValue: Integer);
begin
  FMaxQueueSize := Max(1, AValue);
  if Assigned(FEngine) then
    FEngine.MaxQueueSize := FMaxQueueSize;
end;

procedure TDFTraceHub.SetMaxBreadcrumbs(const AValue: Integer);
begin
  FContextLock.Enter;
  try
    FMaxBreadcrumbs := AValue;
    // Otherwise a reduced limit would only take effect after enough new breadcrumbs
    if FBreadcrumbs.Count > Max(0, AValue) then
      FBreadcrumbs.DeleteRange(0, FBreadcrumbs.Count - Max(0, AValue));
  finally
    FContextLock.Leave;
  end;
end;

procedure TDFTraceHub.InstallExceptionHooks;
begin
  FHookLock.BeginWrite;
  try
    // Only one hub handles unhandled exceptions. A second hub that hooked the application as
    // well would later restore the handler of a hub that may already be freed.
    if FGlobalHub = nil then
    begin
      FGlobalHub := Self;
      FOldExceptProc := ExceptProc;
      ExceptProc := @CustomExceptProc;
      InstallGUIExceptionHook;
    end;
  finally
    FHookLock.EndWrite;
  end;
end;

procedure TDFTraceHub.UninstallExceptionHooks;
begin
  FHookLock.BeginWrite;
  try
    if FGlobalHub = Self then
    begin
      UninstallGUIExceptionHook;
      ExceptProc := FOldExceptProc;
      FOldExceptProc := nil;
      FGlobalHub := nil;
    end;
  finally
    FHookLock.EndWrite;
  end;
end;

procedure TDFTraceHub.InstallGUIExceptionHook;
var
  Ctx: TRttiContext;
  AppObj: TObject;
  AppType: TRttiType;
  OnExProp: TRttiProperty;
  CurrentVal, ValueToSet: TValue;
  M: TMethod;
  HandlerMethod: TDFGUIExceptionEvent;
begin
  if FGUIHookInstalled then Exit;

  AppObj := FindApplication;
  if Assigned(AppObj) then
  begin
    AppType := Ctx.GetType(AppObj.ClassType);
    if Assigned(AppType) then
    begin
      OnExProp := AppType.GetProperty('OnException');
      if Assigned(OnExProp) and OnExProp.IsWritable then
      begin
        CurrentVal := OnExProp.GetValue(AppObj);
        if not CurrentVal.IsEmpty then
        begin
          M.Code := nil;
          M.Data := nil;
          CurrentVal.ExtractRawData(@M);
          if (M.Code <> nil) and (M.Code <> @TDFTraceHub.GUIExceptionEvent) then
            FOldGUIExceptionEvent := TDFGUIExceptionEvent(M)
          else
            FOldGUIExceptionEvent := nil;
        end
        else
          FOldGUIExceptionEvent := nil;

        HandlerMethod := Self.GUIExceptionEvent;
        M := TMethod(HandlerMethod);
        TValue.Make(@M, OnExProp.PropertyType.Handle, ValueToSet);
        OnExProp.SetValue(AppObj, ValueToSet);

        FGUIHookInstalled := True;
      end;
    end;
  end;
end;

procedure TDFTraceHub.UninstallGUIExceptionHook;
var
  Ctx: TRttiContext;
  AppObj: TObject;
  AppType: TRttiType;
  OnExProp: TRttiProperty;
  ValueToSet: TValue;
  M: TMethod;
  OldMethod: TDFGUIExceptionEvent;
begin
  if not FGUIHookInstalled then Exit;

  AppObj := FindApplication;
  if Assigned(AppObj) then
  begin
    AppType := Ctx.GetType(AppObj.ClassType);
    if Assigned(AppType) then
    begin
      OnExProp := AppType.GetProperty('OnException');
      if Assigned(OnExProp) and OnExProp.IsWritable then
      begin
        OldMethod := FOldGUIExceptionEvent;
        M := TMethod(OldMethod);
        TValue.Make(@M, OnExProp.PropertyType.Handle, ValueToSet);
        OnExProp.SetValue(AppObj, ValueToSet);
      end;
    end;
  end;

  FGUIHookInstalled := False;
  FOldGUIExceptionEvent := nil;
end;

procedure TDFTraceHub.GUIExceptionEvent(Sender: TObject; E: Exception);
var
  Ctx: TRttiContext;
  AppObj: TObject;
  AppType: TRttiType;
  ShowExMethod: TRttiMethod;
begin
  if FEnabled and Assigned(E) then
  begin
    try
      // The application keeps running after this handler, so Error rather than Fatal
      TrackException(E, TDFLogLevel.Error);
    except
      // The previous handler or the dialog below has to run in any case
    end;
  end;

  if Assigned(FOldGUIExceptionEvent) then
  begin
    FOldGUIExceptionEvent(Sender, E);
  end
  else if FShowGUIExceptionDialog then
  begin
    // Without a handler of its own, the application would have shown the exception itself
    AppObj := FindApplication;
    if Assigned(AppObj) then
    begin
      AppType := Ctx.GetType(AppObj.ClassType);
      if Assigned(AppType) then
      begin
        ShowExMethod := AppType.GetMethod('ShowException');
        if Assigned(ShowExMethod) then
        begin
          try
            ShowExMethod.Invoke(AppObj, [E]);
          except
            // An exception raised here would escape from Application.OnException
          end;
        end;
      end;
    end;
  end;
end;

procedure TDFTraceHub.AddBreadcrumb(const AMessage, ACategory: string; ALevel: TDFLogLevel;
  ACrumbType: TDFBreadcrumbType);
var
  Crumb: TDFBreadcrumb;
begin
  if not FEnabled or (FMaxBreadcrumbs <= 0) then Exit;

  try
    // Up to MaxBreadcrumbs of them stay in memory and are sent with every error
    Crumb := TDFBreadcrumb.Create(
      TDFTraceEngine.LimitText(AMessage, TDFTraceEngine.MaxBreadcrumbLength),
      TDFTraceEngine.LimitText(ACategory, TDFTraceEngine.MaxBreadcrumbLength), ALevel, ACrumbType);

    FContextLock.Enter;
    try
      // Checked under the lock, so that no breadcrumb slips in after SetConsent cleared the list
      if FConsent = TDFConsent.None then
        Exit;

      if FBreadcrumbs.Count >= FMaxBreadcrumbs then
        FBreadcrumbs.Delete(0);

      FBreadcrumbs.Add(Crumb);
    finally
      FContextLock.Leave;
    end;
  except
    // Telemetry must never break the calling code
  end;
end;

procedure TDFTraceHub.ClearBreadcrumbs;
begin
  FContextLock.Enter;
  try
    FBreadcrumbs.Clear;
  finally
    FContextLock.Leave;
  end;
end;

procedure TDFTraceHub.SetConsent(const AValue: TDFConsent);
begin
  FContextLock.Enter;
  try
    if FConsent = AValue then
      Exit;
    FConsent := AValue;
    // Breadcrumbs collected under one level must not travel with events of another
    FBreadcrumbs.Clear;
  finally
    FContextLock.Leave;
  end;
end;

procedure TDFTraceHub.SetTag(const AKey, AValue: string);
var
  I: Integer;
begin
  if AKey.IsEmpty then
    Exit;

  FContextLock.Enter;
  try
    for I := 0 to High(FTags) do
      if SameText(FTags[I].Key, AKey) then
      begin
        FTags[I] := TDFKeyValuePair.Create(AKey, AValue);
        Exit;
      end;
    FTags := FTags + [TDFKeyValuePair.Create(AKey, AValue)];
  finally
    FContextLock.Leave;
  end;
end;

procedure TDFTraceHub.RemoveTag(const AKey: string);
var
  I: Integer;
begin
  FContextLock.Enter;
  try
    for I := High(FTags) downto 0 do
      if SameText(FTags[I].Key, AKey) then
        Delete(FTags, I, 1);
  finally
    FContextLock.Leave;
  end;
end;

procedure TDFTraceHub.TrackEvent(const AMessage: string; ALevel: TDFLogLevel);
begin
  TrackEvent(AMessage, [], ALevel);
end;

procedure TDFTraceHub.TrackEvent(const AMessage: string; const AExtra: array of TDFKeyValuePair;
  ALevel: TDFLogLevel);
var
  Event: TDFTraceEvent;
begin
  if not FEnabled or (FConsent = TDFConsent.None) then Exit;

  try
    Event := TDFTraceEvent.Create(ALevel, AMessage);
    Event.Extra := PairsToArray(AExtra);
    SubmitEvent(Event, True);
  except
    // Telemetry must never break the calling code
  end;
end;

procedure TDFTraceHub.TrackException(const AException: Exception; ALevel: TDFLogLevel);
begin
  TrackException(AException, [], ALevel);
end;

procedure TDFTraceHub.TrackException(const AException: Exception;
  const AExtra: array of TDFKeyValuePair; ALevel: TDFLogLevel);
var
  Event: TDFTraceEvent;
begin
  // Checked here as well, to save the stack trace when nothing is recorded
  if not FEnabled or (FConsent = TDFConsent.None) or not Assigned(AException) then Exit;

  try
    Event := TDFTraceEvent.CreateException(AException, ALevel);
    Event.Extra := PairsToArray(AExtra);
    SubmitEvent(Event, True);
  except
    // Telemetry must never break the calling code
  end;
end;

function TDFTraceHub.TrackScope(const AOperationName: string; ALevel: TDFLogLevel): IDFTraceScope;
begin
  Result := TrackScope(AOperationName, [], ALevel);
end;

function TDFTraceHub.TrackScope(const AOperationName: string;
  const AExtra: array of TDFKeyValuePair; ALevel: TDFLogLevel): IDFTraceScope;
begin
  Result := TDFTraceScope.Create(Self, AOperationName, PairsToArray(AExtra), ALevel);
end;

procedure TDFTraceHub.TrackSystemInfo(ALevel: TDFLogLevel);
var
  Event: TDFTraceEvent;
  ExtraData: TArray<TDFKeyValuePair>;
  ArchStr, UserName, ComputerName: string;
begin
  if not FEnabled or (FConsent = TDFConsent.None) then Exit;

  try
    case TOSVersion.Architecture of
      arIntelX86: ArchStr := 'x86';
      arIntelX64: ArchStr := 'x64';
      arARM32:    ArchStr := 'ARM32';
      arARM64:    ArchStr := 'ARM64';
    else
      ArchStr := 'Unknown';
    end;

    Event := TDFTraceEvent.Create(ALevel, 'System info');

    SetLength(ExtraData, 3);
    ExtraData[0] := TDFKeyValuePair.Create('OS', TOSVersion.ToString);
    ExtraData[1] := TDFKeyValuePair.Create('CPU_Cores', CPUCount);
    ExtraData[2] := TDFKeyValuePair.Create('Architecture', ArchStr);

    // With scrubbing, the sanitizer would replace both names anyway. Without it, the
    // application has decided to send personal data, and support often needs the machine.
    if not FEnablePIIScrubbing then
    begin
      {$IFDEF MSWINDOWS}
      // Qualified: Winapi.Windows declares a GetEnvironmentVariable with other parameters
      UserName := System.SysUtils.GetEnvironmentVariable('USERNAME');
      ComputerName := System.SysUtils.GetEnvironmentVariable('COMPUTERNAME');
      {$ELSE}
      UserName := System.SysUtils.GetEnvironmentVariable('USER');
      ComputerName := System.SysUtils.GetEnvironmentVariable('HOSTNAME');
      {$ENDIF}
      ExtraData := ExtraData + [TDFKeyValuePair.Create('UserName', UserName),
        TDFKeyValuePair.Create('ComputerName', ComputerName)];
    end;

    Event.Extra := ExtraData;
    SubmitEvent(Event, True);
  except
    // Telemetry must never break the calling code
  end;
end;

procedure TDFTraceHub.RegisterSink(const ASink: IDFTraceSink);
begin
  if Assigned(FEngine) then
    FEngine.RegisterSink(ASink);
end;

procedure TDFTraceHub.UnregisterSink(const ASink: IDFTraceSink);
begin
  if Assigned(FEngine) then
    FEngine.UnregisterSink(ASink);
end;

procedure TDFTraceHub.SubmitEvent(var AEvent: TDFTraceEvent; AAttachBreadcrumbs: Boolean);
var
  CurrentConsent: TDFConsent;
begin
  if not FEnabled or not Assigned(FEngine) then Exit;

  try
    // Consent and breadcrumbs are read under one lock. Otherwise a change of Consent between
    // the two could send breadcrumbs from a LocalOnly phase with an event for all sinks.
    FContextLock.Enter;
    try
      CurrentConsent := FConsent;
      if CurrentConsent = TDFConsent.None then
        Exit;
      // Only errors: the log file and the event log write all breadcrumbs with each event,
      // and for other events the order of the events already shows what happened
      if AAttachBreadcrumbs and (AEvent.Level >= TDFLogLevel.Error) then
        AEvent.Breadcrumbs := FBreadcrumbs.ToArray;
      // Tags of the event first: sinks keep the first entry of a name, and the event is more
      // specific. Copy, because SetTag changes elements in place and dynamic arrays are not
      // copy-on-write.
      AEvent.Tags := AEvent.Tags + Copy(FTags);
    finally
      FContextLock.Leave;
    end;

    AEvent.AppName := FAppName;
    AEvent.Environment := FEnvironment;
    if FAppVersion.IsEmpty then
      AEvent.AppVersion := FExeVersion
    else
      AEvent.AppVersion := FAppVersion;

    FEngine.PostEvent(AEvent, FEnablePIIScrubbing, CurrentConsent = TDFConsent.LocalOnly);
  except
    // Telemetry must never break the calling code
  end;
end;

function TDFTraceHub.Flush(ATimeoutMS: Integer): Boolean;
begin
  Result := Assigned(FEngine) and FEngine.Flush(ATimeoutMS);
end;

function TDFTraceHub.GetQueueCount: Integer;
begin
  if Assigned(FEngine) then
    Result := FEngine.QueueCount
  else
    Result := 0;
end;

function TDFTraceHub.GetDroppedCount: UInt64;
begin
  if Assigned(FEngine) then
    Result := FEngine.DroppedCount
  else
    Result := 0;
end;

end.
